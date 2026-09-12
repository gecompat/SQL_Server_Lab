<#
.SYNOPSIS
    Vergleicht eng begrenzte relationale SQL-Inhalte read-only.
.DESCRIPTION
    RELATIONAL_CORE/1.0 ist absichtlich kein Transfermechanismus. Er akzeptiert
    ausschließlich Run-/Instanz-/Datenbank-Identitäten, löst das lokale
    Run-Secret nur als SecureString auf und öffnet getrennte SqlCredential-
    gebundene Verbindungen. Ergebnisse enthalten keine Endpunkte, Credentials,
    Objekt- oder Datenwerte.
#>

function New-LabRelationalCoreIssue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Code,[int]$TableOrdinal = 0)
    [PSCustomObject][ordered]@{ Code=$Code; TableOrdinal=$TableOrdinal }
}

function Get-LabRelationalCoreSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot)
    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    $runDirectory=Join-Path (Join-Path $StateRoot 'runs') $RunId
    foreach($name in @('generated-sql-sa-password','sa-password')) {
        $secret=Get-LabSecret -Path $runDirectory -Name $name
        if($secret) { return $secret }
    }
    throw 'RELATIONAL_CORE_MANAGED_SQL_SECRET_UNAVAILABLE'
}

function Get-LabRelationalCoreLiveBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if([string]$run.state -ne 'RUNNING') { throw 'RELATIONAL_CORE_RUN_NOT_RUNNING' }
    $target=Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    if([string]$target.Provider -notin @('docker','podman')) { throw 'RELATIONAL_CORE_CONTAINER_PROVIDER_REQUIRED' }
    $scope=Get-LabContainerRuntimeScope -Provider ([string]$target.Provider)
    if([string]$scope.Status -ne 'AVAILABLE' -or [string]::IsNullOrWhiteSpace([string]$scope.RuntimeId)) { throw 'RELATIONAL_CORE_RUNTIME_SCOPE_UNAVAILABLE' }
    $invocation=Get-LabHostToolInvocation -Name ([string]$target.Provider)
    $inspection=@(& $invocation inspect --format '{{.Id}}|{{.State.Running}}' ([string]$target.ContainerName) 2>$null)
    if($LASTEXITCODE -ne 0 -or $inspection.Count -ne 1 -or $inspection[0] -notmatch '^([a-f0-9]{12,64})\|true$') { throw 'RELATIONAL_CORE_LIVE_CONTAINER_BINDING_UNVERIFIABLE' }
    [PSCustomObject]@{ Provider=[string]$target.Provider; RuntimeScopeId=[string]$scope.RuntimeId; ContainerId=$Matches[1].ToLowerInvariant(); HostName=[string]$target.HostName; Port=[int]$target.Port }
}

function New-LabRelationalCoreConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][string]$DatabaseName,[Parameter(Mandatory)][SecureString]$Secret)
    if(-not $Secret.IsReadOnly()){ $Secret.MakeReadOnly() }
    $credential=[System.Data.SqlClient.SqlCredential]::new('sa',$Secret)
    $connection=[System.Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString="Data Source=$($Binding.HostName),$($Binding.Port);Initial Catalog=$DatabaseName;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15;Application Name=SqlServerLab.RelationalCoreComparison"
    $connection.Credential=$credential
    return $connection
}

function Invoke-LabRelationalCoreReader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,[Parameter(Mandatory)][string]$Query)
    $command=$Connection.CreateCommand();$command.CommandText=$Query;$command.CommandTimeout=60
    try { return @($command,$command.ExecuteReader([System.Data.CommandBehavior]::SequentialAccess)) }
    catch { $command.Dispose(); throw 'RELATIONAL_CORE_SQL_READ_FAILED' }
}

function Get-LabRelationalCoreTableInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection)
    $query=@'
SET NOCOUNT ON;
SELECT t.object_id, s.name, t.name,
       CASE WHEN EXISTS (SELECT 1 FROM sys.security_predicates p WHERE p.target_object_id=t.object_id) THEN 1 ELSE 0 END AS HasRls,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id=t.object_id AND i.is_primary_key=1 AND i.has_filter=0 AND i.is_disabled=0) THEN 1 ELSE 0 END AS HasPrimaryKey,
       STUFF((SELECT N',' + QUOTENAME(c.name) FROM sys.index_columns ic JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id JOIN sys.indexes i ON i.object_id=ic.object_id AND i.index_id=ic.index_id WHERE ic.object_id=t.object_id AND i.is_primary_key=1 AND i.has_filter=0 AND i.is_disabled=0 AND ic.key_ordinal>0 ORDER BY ic.key_ordinal FOR XML PATH(''), TYPE).value('.','nvarchar(max)'),1,1,N'') AS PrimaryKeyOrder,
       STUFF((SELECT N'|' + c.name + N':' + ty.name + N':' + CONVERT(nvarchar(12),c.max_length) + N':' + CONVERT(nvarchar(12),c.precision) + N':' + CONVERT(nvarchar(12),c.scale) + N':' + CONVERT(nvarchar(1),c.is_nullable) FROM sys.columns c JOIN sys.types ty ON ty.user_type_id=c.user_type_id WHERE c.object_id=t.object_id ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.','nvarchar(max)'),1,1,N'') AS Signature,
       STUFF((SELECT N'|' + ty.name FROM sys.columns c JOIN sys.types ty ON ty.user_type_id=c.user_type_id WHERE c.object_id=t.object_id AND ty.name NOT IN (N'bit',N'tinyint',N'smallint',N'int',N'bigint',N'decimal',N'numeric',N'money',N'smallmoney',N'uniqueidentifier',N'date',N'datetime',N'datetime2',N'datetimeoffset',N'time',N'char',N'varchar',N'nchar',N'nvarchar',N'binary',N'varbinary') ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.','nvarchar(max)'),1,1,N'') AS UnsupportedTypes
FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
WHERE t.is_ms_shipped=0 AND t.temporal_type=0 AND t.is_filetable=0 AND t.is_external=0
  AND t.is_memory_optimized=0 AND t.is_node=0 AND t.is_edge=0 AND t.ledger_type=0
ORDER BY s.name,t.name;
'@
    $command=$null;$reader=$null;$tables=[Collections.Generic.List[object]]::new()
    try {
        $readerPair=@(Invoke-LabRelationalCoreReader -Connection $Connection -Query $query);$command=$readerPair[0];$reader=$readerPair[1]
        while($reader.Read()) { $tables.Add([PSCustomObject]@{ ObjectId=$reader.GetInt32(0); Schema=$reader.GetString(1); Name=$reader.GetString(2); HasRls=$reader.GetInt32(3)-eq 1; HasPrimaryKey=$reader.GetInt32(4)-eq 1; PrimaryKeyOrder=if($reader.IsDBNull(5)){$null}else{$reader.GetString(5)}; Signature=if($reader.IsDBNull(6)){$null}else{$reader.GetString(6)}; UnsupportedTypes=if($reader.IsDBNull(7)){$null}else{$reader.GetString(7)} }) }
    } finally { if($reader){$reader.Dispose()};if($command){$command.Dispose()} }
    return @($tables)
}

function Test-LabRelationalCoreTableSupported {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Table)
    return -not $Table.HasRls -and $Table.HasPrimaryKey -and $Table.PrimaryKeyOrder -and -not $Table.UnsupportedTypes
}

function ConvertTo-LabRelationalCoreSelect {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Table)
    $schema=[string]$Table.Schema;$name=[string]$Table.Name
    if($schema -match "[\x00-\x1f]" -or $name -match "[\x00-\x1f]") { throw 'RELATIONAL_CORE_IDENTIFIER_INVALID' }
    return "SELECT * FROM ["+$schema.Replace(']',']]')+"] .["+$name.Replace(']',']]')+"] ORDER BY "+[string]$Table.PrimaryKeyOrder
}

function ConvertTo-LabRelationalCoreFieldBytes {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if($null -eq $Value -or $Value -is [DBNull]) { return [byte[]]@(0) }
    $prefix=[byte[]]@(1)
    $payload=switch($Value.GetType().FullName) {
        'System.Byte[]' { [byte[]]$Value; break }
        'System.String' { [Text.Encoding]::UTF8.GetBytes([string]$Value); break }
        'System.Boolean' { [byte[]]@([byte][bool]$Value); break }
        'System.Byte' { [byte[]]@([byte]$Value); break }
        'System.Int16' { [BitConverter]::GetBytes([int16]$Value); break }
        'System.Int32' { [BitConverter]::GetBytes([int]$Value); break }
        'System.Int64' { [BitConverter]::GetBytes([long]$Value); break }
        'System.Decimal' { $bits=[decimal]::GetBits([decimal]$Value); [byte[]]($bits|ForEach-Object{[BitConverter]::GetBytes([int]$_)}|ForEach-Object{$_}); break }
        'System.Guid' { ([guid]$Value).ToByteArray(); break }
        'System.DateTime' { [BitConverter]::GetBytes(([datetime]$Value).Ticks); break }
        'System.DateTimeOffset' { $candidate=[datetimeoffset]$Value; [byte[]]([BitConverter]::GetBytes($candidate.Ticks)+[BitConverter]::GetBytes([int]$candidate.Offset.TotalMinutes)); break }
        'System.TimeSpan' { [BitConverter]::GetBytes(([timespan]$Value).Ticks); break }
        default { throw 'RELATIONAL_CORE_VALUE_TYPE_UNEXPECTED' }
    }
    return [byte[]]($prefix+$payload)
}

function Test-LabRelationalCoreFieldEqual {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlDataReader]$Source,[Parameter(Mandatory)][System.Data.SqlClient.SqlDataReader]$Target,[Parameter(Mandatory)][int]$Ordinal)
    $left=ConvertTo-LabRelationalCoreFieldBytes -Value $(if($Source.IsDBNull($Ordinal)){$null}else{$Source.GetValue($Ordinal)})
    $right=ConvertTo-LabRelationalCoreFieldBytes -Value $(if($Target.IsDBNull($Ordinal)){$null}else{$Target.GetValue($Ordinal)})
    if($left.Length -ne $right.Length) { return $false }
    for($i=0;$i -lt $left.Length;$i++){if($left[$i] -ne $right[$i]){return $false}}
    return $true
}

function Compare-LabRelationalCoreTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Source,[Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Target,[Parameter(Mandatory)]$SourceTable,[Parameter(Mandatory)]$TargetTable,[Parameter(Mandatory)][int]$TableOrdinal)
    if([string]$SourceTable.Signature -cne [string]$TargetTable.Signature -or [string]$SourceTable.PrimaryKeyOrder -cne [string]$TargetTable.PrimaryKeyOrder) { return [PSCustomObject]@{ Status='DIFFERENT';RowsCompared=0;Issues=@((New-LabRelationalCoreIssue -Code 'TABLE_SCHEMA_OR_PRIMARY_KEY_MISMATCH' -TableOrdinal $TableOrdinal)) } }
    $sourceCommand=$null;$sourceReader=$null;$targetCommand=$null;$targetReader=$null;$rows=0;$issues=[Collections.Generic.List[object]]::new()
    try {
        $sourceReaderPair=@(Invoke-LabRelationalCoreReader -Connection $Source -Query (ConvertTo-LabRelationalCoreSelect -Table $SourceTable));$sourceCommand=$sourceReaderPair[0];$sourceReader=$sourceReaderPair[1]
        $targetReaderPair=@(Invoke-LabRelationalCoreReader -Connection $Target -Query (ConvertTo-LabRelationalCoreSelect -Table $TargetTable));$targetCommand=$targetReaderPair[0];$targetReader=$targetReaderPair[1]
        while($true) {
            $hasSource=$sourceReader.Read();$hasTarget=$targetReader.Read()
            if(-not $hasSource -and -not $hasTarget){break}
            if($hasSource -ne $hasTarget){$issues.Add((New-LabRelationalCoreIssue -Code 'TABLE_ROW_COUNT_MISMATCH' -TableOrdinal $TableOrdinal));break}
            $rows++
            if($sourceReader.FieldCount -ne $targetReader.FieldCount){$issues.Add((New-LabRelationalCoreIssue -Code 'TABLE_FIELD_COUNT_MISMATCH' -TableOrdinal $TableOrdinal));break}
            for($ordinal=0;$ordinal -lt $sourceReader.FieldCount;$ordinal++){if(-not (Test-LabRelationalCoreFieldEqual -Source $sourceReader -Target $targetReader -Ordinal $ordinal)){$issues.Add((New-LabRelationalCoreIssue -Code 'TABLE_ROW_VALUE_MISMATCH' -TableOrdinal $TableOrdinal));break}}
            if($issues.Count){break}
        }
    } finally { if($sourceReader){$sourceReader.Dispose()};if($targetReader){$targetReader.Dispose()};if($sourceCommand){$sourceCommand.Dispose()};if($targetCommand){$targetCommand.Dispose()} }
    [PSCustomObject]@{ Status=if($issues.Count){'DIFFERENT'}else{'MATCH'}; RowsCompared=$rows; Issues=@($issues) }
}

function Invoke-LabRelationalCoreComparison {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$ComparisonPair,[string]$StateRoot)
    $pairResults=[Collections.Generic.List[object]]::new();$allIssues=[Collections.Generic.List[object]]::new()
    foreach($pair in $ComparisonPair) {
        $pairId=[string]$pair.PairId
        foreach($required in @('PairId','SourceRunId','SourceInstanceId','SourceDatabaseName','TargetRunId','TargetInstanceId','TargetDatabaseName')) { if(-not $pair.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$pair.$required)){throw "RELATIONAL_CORE_PAIR_PROPERTY_REQUIRED: $required"} }
        if($pairId -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or [string]$pair.SourceRunId -notmatch '^[0-9a-fA-F-]{36}$' -or [string]$pair.TargetRunId -notmatch '^[0-9a-fA-F-]{36}$' -or [string]$pair.SourceDatabaseName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or [string]$pair.TargetDatabaseName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$'){throw 'RELATIONAL_CORE_PAIR_INVALID'}
        $sourceSecret=$null;$targetSecret=$null;$sourceConnection=$null;$targetConnection=$null;$pairIssues=[Collections.Generic.List[object]]::new();$tablesCompared=0;$rowsCompared=0;$supported=$true;$sourceBinding=$null;$targetBinding=$null
        try {
            $sourceBinding=Get-LabRelationalCoreLiveBinding -RunId ([string]$pair.SourceRunId) -InstanceId ([string]$pair.SourceInstanceId) -StateRoot $StateRoot
            $targetBinding=Get-LabRelationalCoreLiveBinding -RunId ([string]$pair.TargetRunId) -InstanceId ([string]$pair.TargetInstanceId) -StateRoot $StateRoot
            if($sourceBinding.ContainerId -eq $targetBinding.ContainerId){throw 'RELATIONAL_CORE_SOURCE_TARGET_MUST_DIFFER'}
            $sourceSecret=Get-LabRelationalCoreSecret -RunId ([string]$pair.SourceRunId) -StateRoot $StateRoot;$targetSecret=Get-LabRelationalCoreSecret -RunId ([string]$pair.TargetRunId) -StateRoot $StateRoot
            $sourceConnection=New-LabRelationalCoreConnection -Binding $sourceBinding -DatabaseName ([string]$pair.SourceDatabaseName) -Secret $sourceSecret;$targetConnection=New-LabRelationalCoreConnection -Binding $targetBinding -DatabaseName ([string]$pair.TargetDatabaseName) -Secret $targetSecret
            $sourceConnection.Open();$targetConnection.Open();$sourceTables=Get-LabRelationalCoreTableInventory -Connection $sourceConnection;$targetTables=Get-LabRelationalCoreTableInventory -Connection $targetConnection
            $sourceMap=@{};foreach($table in $sourceTables){$sourceMap[($table.Schema+'|'+$table.Name)]=$table};$targetMap=@{};foreach($table in $targetTables){$targetMap[($table.Schema+'|'+$table.Name)]=$table}
            if($sourceMap.Count -ne $targetMap.Count -or @($sourceMap.Keys|Where-Object{$_ -notin $targetMap.Keys}).Count){$pairIssues.Add((New-LabRelationalCoreIssue -Code 'TABLE_SET_MISMATCH'));$supported=$false}
            $ordinal=0;foreach($key in @($sourceMap.Keys|Sort-Object)){$ordinal++;if(-not $targetMap.ContainsKey($key)){continue};if(-not (Test-LabRelationalCoreTableSupported -Table $sourceMap[$key]) -or -not (Test-LabRelationalCoreTableSupported -Table $targetMap[$key])){$pairIssues.Add((New-LabRelationalCoreIssue -Code 'TABLE_UNSUPPORTED_OR_POLICY_BLOCKED' -TableOrdinal $ordinal));$supported=$false;continue};$tableResult=Compare-LabRelationalCoreTable -Source $sourceConnection -Target $targetConnection -SourceTable $sourceMap[$key] -TargetTable $targetMap[$key] -TableOrdinal $ordinal;$tablesCompared++;$rowsCompared+=[long]$tableResult.RowsCompared;foreach($issue in @($tableResult.Issues)){$pairIssues.Add($issue)} }
        } catch { $pairIssues.Add((New-LabRelationalCoreIssue -Code 'RELATIONAL_CORE_COMPARISON_UNVERIFIABLE'));$supported=$false }
        finally { if($sourceConnection){$sourceConnection.Dispose()};if($targetConnection){$targetConnection.Dispose()};$sourceSecret=$null;$targetSecret=$null }
        $status=if(-not $supported){'UNSUPPORTED'}elseif($pairIssues.Count){'DIFFERENT'}else{'MATCH'}
        $pairResult=[PSCustomObject][ordered]@{ PairId=$pairId; Status=$status; Source=[PSCustomObject]@{RunId=([string]$pair.SourceRunId).ToLowerInvariant();InstanceId=[string]$pair.SourceInstanceId;RuntimeScopeId=if($sourceBinding){$sourceBinding.RuntimeScopeId}else{$null}}; Target=[PSCustomObject]@{RunId=([string]$pair.TargetRunId).ToLowerInvariant();InstanceId=[string]$pair.TargetInstanceId;RuntimeScopeId=if($targetBinding){$targetBinding.RuntimeScopeId}else{$null}}; TablesCompared=$tablesCompared;RowsCompared=$rowsCompared;Findings=@($pairIssues|Sort-Object TableOrdinal,Code) }
        $pairResults.Add($pairResult);foreach($issue in @($pairResult.Findings)){$allIssues.Add([PSCustomObject]@{PairId=$pairId;Code=$issue.Code;TableOrdinal=$issue.TableOrdinal})}
    }
    $result=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.RelationalCoreComparison/1.0';Profile='RELATIONAL_CORE/1.0';ExecutionImplemented=$false;MutationAllowed=$false;TransferExecutorStatus='BLOCKED';Status=if(@($pairResults|Where-Object Status -ne 'MATCH').Count){'DIFFERENT_OR_UNSUPPORTED'}else{'MATCH'};Pairs=@($pairResults);Findings=@($allIssues|Sort-Object PairId,TableOrdinal,Code);ComparedAt=Get-LabTimestamp}
    try{$valid=$result|ConvertTo-Json -Depth 30|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'relational-core-comparison.schema.json') -ErrorAction Stop}catch{throw 'RELATIONAL_CORE_COMPARISON_RESULT_SCHEMA_INVALID'};if(-not $valid){throw 'RELATIONAL_CORE_COMPARISON_RESULT_SCHEMA_INVALID'};return $result
}
