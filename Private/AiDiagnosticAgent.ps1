<#
.SYNOPSIS
    Fail-closed read-only Diagnose-Agent über katalogisierte SQL-Abfragen.
#>

function Get-LabAiDiagnosticToolCatalog {
    [CmdletBinding()]
    param()
    @(
        [PSCustomObject]@{Id='server-summary';Sql="SELECT TOP (1) CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion, cpu_count AS CpuCount, physical_memory_kb AS PhysicalMemoryKb FROM sys.dm_os_sys_info;";MaxRows=1}
        [PSCustomObject]@{Id='database-capacity';Sql="SELECT TOP (20) DB_NAME(database_id) AS DatabaseName, type_desc AS FileType, SUM(size)*8 AS SizeKb FROM sys.master_files GROUP BY database_id,type_desc ORDER BY SizeKb DESC,DatabaseName;";MaxRows=20}
        [PSCustomObject]@{Id='wait-statistics';Sql="SELECT TOP (10) wait_type AS WaitType, waiting_tasks_count AS WaitingTasks, wait_time_ms AS WaitTimeMs FROM sys.dm_os_wait_stats WHERE wait_type NOT LIKE 'SLEEP%' ORDER BY wait_time_ms DESC,wait_type;";MaxRows=10}
        [PSCustomObject]@{Id='active-requests';Sql="SELECT TOP (20) session_id AS SessionId, status AS Status, command AS Command, cpu_time AS CpuTimeMs, reads AS Reads, writes AS Writes, wait_type AS WaitType FROM sys.dm_exec_requests WHERE session_id<>@@SPID ORDER BY cpu_time DESC,session_id;";MaxRows=20}
    )
}

function New-LabAiDiagnosticAgentPlan {
    [CmdletBinding()]
    param([string]$RunId,[string]$InstanceId,[string]$Question,[string[]]$ToolId,[string]$GenerationModelKey,[int]$LocalPort)
    if([string]::IsNullOrWhiteSpace($Question)-or$Question.Length-gt8192){throw 'AI_AGENT_QUESTION_INVALID'}
    $selected=@($ToolId|ForEach-Object{[string]$_})
    if($selected.Count-lt1-or$selected.Count-gt4){throw 'AI_AGENT_TOOL_COUNT_INVALID'}
    if(@($selected|Select-Object -Unique).Count-ne$selected.Count){throw 'AI_AGENT_TOOL_DUPLICATE'}
    $catalog=@(Get-LabAiDiagnosticToolCatalog)
    foreach($id in $selected){if($id-notin@($catalog.Id)){throw "AI_AGENT_TOOL_NOT_ALLOWED: $id"}}
    $modelPlan=New-LabAiEndpointPlan -ModelKey $GenerationModelKey -EndpointRef ollama-local -Lane local -LocalPort $LocalPort -MaximumRequests 2 -MaximumOutputTokens 256 -TimeoutSeconds 180 -RetryCount 1
    if($modelPlan.Purpose-ne'generation'-or$modelPlan.Status-eq'BLOCKED'){throw 'AI_AGENT_MODEL_INVALID'}
    $identity=[ordered]@{Contract='SqlServerLab.AiDiagnosticAgentPlan/1.0';RunId=$RunId;InstanceId=$InstanceId;QuestionHash=Get-LabAiSha256Text -Text $Question;ToolIds=$selected;GenerationPlanKey=$modelPlan.PlanKey}
    [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiDiagnosticAgentPlan';Version='1.0'};Status='READY';RunId=$RunId;InstanceId=$InstanceId;ScenarioId='diagnostic-agent-readonly';ToolIds=$selected;GenerationModelKey=$GenerationModelKey;PlanKey=Get-LabAiPlanKey -InputObject $identity;InternalTools=@($catalog|Where-Object Id -in $selected);GenerationPlan=$modelPlan}
}

function Invoke-LabAiSqlCommand {
    [CmdletBinding()]
    param([string]$HostName,[int]$Port,[PSCredential]$Credential,[string]$Sql,[switch]$NonQuery)
    $plain=ConvertFrom-LabSecureString -SecureString $Credential.Password
    $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new();$builder['Data Source']="$HostName,$Port";$builder['Initial Catalog']='master';$builder['User ID']=$Credential.UserName;$builder['Password']=$plain;$builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Connect Timeout']=30;$builder['Pooling']=$false
    $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString);$command=$null
    try{$connection.Open();$command=$connection.CreateCommand();$command.CommandText=$Sql;$command.CommandTimeout=30;if($NonQuery){$null=$command.ExecuteNonQuery();return @()};$reader=$command.ExecuteReader();try{$rows=[Collections.Generic.List[object]]::new();while($reader.Read()){$row=[ordered]@{};for($i=0;$i-lt$reader.FieldCount;$i++){$value=$reader.GetValue($i);$row[$reader.GetName($i)]=if($value-is[DBNull]){$null}else{$value}};$rows.Add([PSCustomObject]$row)};return @($rows)}finally{$reader.Dispose()}}
    finally{$plain=$null;if($command){$command.Dispose()};$connection.Dispose()}
}

function Invoke-LabAiDiagnosticAgent {
    [CmdletBinding()]
    param($Plan,[SecureString]$SaPassword,$Target,[string]$Question,[string]$StateRoot,[scriptblock]$GenerationTransport,[scriptblock]$SqlExecutor)
    if(($Target.Version-split'-',2)[0]-ne'2025'){throw 'AI_AGENT_SQL_VERSION_UNSUPPORTED'}
    if($Target.Provider-notin@('docker','podman')){throw 'AI_AGENT_PROVIDER_UNSUPPORTED'}
    if(-not$StateRoot){$StateRoot=Get-LabStateRoot}
    $journalDirectory=Join-Path (Join-Path (Join-Path $StateRoot 'runs') $Plan.RunId) 'ai-agent';$journalPath=Join-Path $journalDirectory "diagnostic-$($Plan.InstanceId)-$($Plan.PlanKey.Substring(0,12)).json"
    $journal=[PSCustomObject]@{contract=[PSCustomObject]@{name='SqlServerLab.AiRuntimeJournal';version='1.0'};operationId=[Guid]::NewGuid().ToString();runId=$Plan.RunId;instanceId=$Plan.InstanceId;planKey=$Plan.PlanKey;status='PENDING';lane='local';modelKeys=@($Plan.GenerationModelKey);steps=@($Plan.ToolIds|ForEach-Object{[PSCustomObject]@{id=$_;status='PENDING';reasonCode=$null}});cleanupStatus='NOT_STARTED';startedAt=Get-LabTimestamp;completedAt=$null}
    Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
    $loginName="sql_lab_ai_$([Guid]::NewGuid().ToString('N').Substring(0,12))";$bytes=[byte[]]::new(24);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes);$loginPassword="Aa1!$([Convert]::ToBase64String($bytes))";[Array]::Clear($bytes,0,$bytes.Length)
    $loginSecret=[SecureString]::new();foreach($character in $loginPassword.ToCharArray()){$loginSecret.AppendChar($character)};$loginSecret.MakeReadOnly()
    $saCredential=[PSCredential]::new('sa',$SaPassword);$loginCredential=[PSCredential]::new($loginName,$loginSecret);$created=$false;$timer=[Diagnostics.Stopwatch]::StartNew()
    $executeSql={param($credential,$sql,$nonQuery)if($SqlExecutor){return @(& $SqlExecutor $credential $sql $nonQuery)};return @(Invoke-LabAiSqlCommand -HostName $Target.HostName -Port $Target.Port -Credential $credential -Sql $sql -NonQuery:$nonQuery)}
    try{
        $escaped=$loginPassword.Replace("'","''");$setup="CREATE LOGIN [$loginName] WITH PASSWORD=N'$escaped',CHECK_POLICY=OFF,CHECK_EXPIRATION=OFF; GRANT VIEW SERVER STATE TO [$loginName]; GRANT VIEW SERVER PERFORMANCE STATE TO [$loginName]; GRANT VIEW ANY DATABASE TO [$loginName];"
        & $executeSql $saCredential $setup $true|Out-Null;$created=$true;$loginPassword=$null;$escaped=$null;$setup=$null
        $evidence=[ordered]@{};$executions=[Collections.Generic.List[object]]::new()
        foreach($tool in $Plan.InternalTools){$rows=@(& $executeSql $loginCredential $tool.Sql $false);if($rows.Count-gt$tool.MaxRows){throw 'AI_AGENT_TOOL_ROW_LIMIT_EXCEEDED'};$evidence[$tool.Id]=$rows;$executions.Add([PSCustomObject]@{ToolId=$tool.Id;Status='SUCCEEDED';RowCount=$rows.Count})}
        $payload=$evidence|ConvertTo-Json -Depth 8 -Compress;if($payload.Length-gt32768){throw 'AI_AGENT_CONTEXT_SIZE_EXCEEDED'}
        $prompt="Du bist ein read-only SQL-Diagnoseassistent. Nutze ausschließlich die gelieferten Metriken, erfinde keine Befunde und schlage keine automatisch ausgeführten Änderungen vor. Frage: $Question`nMetriken: $payload"
        $answer=Invoke-LabAiEndpointRequest -Plan $Plan.GenerationPlan -InputText $prompt -Transport $GenerationTransport;$timer.Stop();$journal.status='SUCCEEDED';foreach($step in $journal.steps){$step.status='SUCCEEDED'};$journal.completedAt=Get-LabTimestamp
        [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiQueryResult';Version='1.0'};Status='SUCCEEDED';Mode='DiagnosticAgent';RunId=$Plan.RunId;InstanceId=$Plan.InstanceId;ScenarioId=$Plan.ScenarioId;PlanKey=$Plan.PlanKey;ModelKey=$Plan.GenerationModelKey;Answer=$answer.Text;Citations=@($Plan.ToolIds);ToolExecutions=@($executions);Metrics=[PSCustomObject]@{RequestCount=$answer.Attempts;LatencyMilliseconds=[int]$timer.ElapsedMilliseconds}}
    }
    catch{$journal.status='FAILED';$journal.completedAt=Get-LabTimestamp;throw}
    finally{
        try{if($created){& $executeSql $saCredential "DROP LOGIN [$loginName];" $true|Out-Null};$journal.cleanupStatus='SUCCEEDED'}catch{$journal.cleanupStatus='RECOVERY_REQUIRED';if($journal.status-eq'SUCCEEDED'){throw}}finally{$loginPassword=$null;$loginSecret=$null;$loginCredential=$null;$saCredential=$null;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal}
    }
}
