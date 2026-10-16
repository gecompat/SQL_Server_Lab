#Requires -Version 7.2
<#
.SYNOPSIS
    Nimmt den Windows-Consumerzugang an einem expliziten bestehenden Run ab.
.DESCRIPTION
    Keine Lab-Neuerstellung, Fixtureerneuerung oder Dienst-/Loggingaenderung.
    Verwendet nur Invoke-SqlServerLabScript fuer SQL. Ein eigenes synthetisches
    Projekt nutzt den bestehenden ISPAC-Writer; Cleanup nutzt den bestehenden
    transaktionalen ID-/Versionsguard. Vorbestehende Source-IDs bleiben erhalten.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$RunId,[string]$InstanceId='primary',[string]$StateRoot,
    [long[]]$ProtectedExecutionId=@(10,11,12),[string]$EvidencePath)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
& $module {param($Root,$Repository) Assert-LabSsisEvidenceLocation -StateRoot $Root -RepositoryRoot $Repository} $StateRoot $repoRoot
$context=& $module {param($Id,$Instance,$Root) Get-LabSsisPrerequisiteContext -RunId $Id -InstanceId $Instance -StateRoot $Root} $RunId $InstanceId $StateRoot
if($context.ExpectedMajor -ne 17 -or $ProtectedExecutionId.Count -ne 3 -or @($ProtectedExecutionId|Select-Object -Unique).Count -ne 3 -or @($ProtectedExecutionId|Where-Object {$_ -lt 1}).Count){throw 'CONSUMER_ACCEPTANCE_TARGET_INVALID'}
$operation=[guid]::NewGuid().ToString('N')
$workspace=Join-Path $StateRoot ('diagnostics/windows-sql-consumer-'+$operation)
$null=New-Item -ItemType Directory -Path $workspace
$recoveryPath=Join-Path $workspace 'consumer-recovery.json'
$folder='AnalyzeAccessSmoke_'+$operation; $project='AnalyzeAccessProject_'+$operation
$folderId=0L;$projectId=0L;$projectVersion=0L;$executionId=0L;$serial=0
$apiOperations=[Collections.Generic.List[string]]::new();$schemes=[Collections.Generic.HashSet[string]]::new()
$metadata=@{}
foreach($name in @('run-state.json','connection-info.json','ssis-fixture-receipt.json','ssis-fixture-operation.json')){
    $path=Join-Path $context.Directory $name
    if(Test-Path -LiteralPath $path){$metadata[$name]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
function Save-ConsumerRecovery {
    [ordered]@{RunId=$RunId.ToString();InstanceId=$InstanceId;Folder=$folder;FolderId=$folderId;Project=$project;ProjectId=$projectId;ProjectVersion=$projectVersion;ExecutionId=$executionId;Status=$script:cleanupStatus} |
        ConvertTo-Json | Set-Content -LiteralPath $recoveryPath -Encoding utf8
}
function Invoke-ConsumerSql {
    param([string]$Text,[hashtable]$Values=@{},[switch]$AllowFailure)
    $script:serial++;$path=Join-Path $workspace ($script:serial.ToString('000')+'.sql')
    [IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($false))
    $result=SqlServerLab\Invoke-SqlServerLabScript -RunId $RunId.ToString() -InstanceId $InstanceId -StateRoot $StateRoot `
        -WindowsAuthentication -Database SSISDB -ScriptPath $path -Parameters $Values -KeepConnection -TimeoutSeconds 240 -Confirm:$false
    $apiOperations.Add([string]$result.OperationId)
    if($result.Success){$null=$schemes.Add([string]$result.AuthScheme)}
    if(-not $result.Success -and -not $AllowFailure){throw 'CONSUMER_ACCEPTANCE_SQL_FAILED'}
    return $result
}
$protectedParameters=@{p0=$ProtectedExecutionId[0];p1=$ProtectedExecutionId[1];p2=$ProtectedExecutionId[2]}
$inventorySql=@'
SELECT
 (SELECT COUNT(*) FROM catalog.executions WHERE execution_id IN(@p0,@p1,@p2)) AS ProtectedCount,
 CONVERT(varchar(64),HASHBYTES('SHA2_256',(SELECT * FROM catalog.executions WHERE execution_id IN(@p0,@p1,@p2) ORDER BY execution_id FOR JSON PATH,INCLUDE_NULL_VALUES)),2) AS ExecutionsHash,
 CONVERT(varchar(64),HASHBYTES('SHA2_256',(SELECT * FROM catalog.event_messages WHERE operation_id IN(@p0,@p1,@p2) ORDER BY event_message_id FOR JSON PATH,INCLUDE_NULL_VALUES)),2) AS EventsHash,
 CONVERT(varchar(64),HASHBYTES('SHA2_256',CONCAT(
   (SELECT * FROM catalog.folders ORDER BY folder_id FOR JSON PATH,INCLUDE_NULL_VALUES),
   (SELECT * FROM catalog.projects ORDER BY project_id FOR JSON PATH,INCLUDE_NULL_VALUES),
   (SELECT * FROM catalog.environments ORDER BY environment_id FOR JSON PATH,INCLUDE_NULL_VALUES))),2) AS ActiveInventoryHash,
 CONVERT(varchar(64),HASHBYTES('SHA2_256',(SELECT * FROM catalog.catalog_properties ORDER BY property_name FOR JSON PATH,INCLUDE_NULL_VALUES)),2) AS PropertiesHash,
 CONVERT(varchar(64),HASHBYTES('SHA2_256',(SELECT database_id,name,state FROM sys.databases ORDER BY database_id FOR JSON PATH,INCLUDE_NULL_VALUES)),2) AS DatabasesHash;
'@
$cleanupSql=& $module {Get-LabSsisFixtureCleanupSql}
$cleanupStatus='NOT_ARRANGED';$primaryFailure=$false;$cleanupFailure=$false;$guardVerified=$false;$executionStatus=0
try {
    $before=Invoke-ConsumerSql $inventorySql $protectedParameters
    if($before.ResultSets[0].Rows[0][0] -ne 3){throw 'CONSUMER_ACCEPTANCE_PROTECTED_IDS_MISSING'}
    $baseline=ConvertTo-Json -InputObject $before.ResultSets -Depth 10 -Compress
    $cleanupStatus='ARRANGE_PLANNED';Save-ConsumerRecovery
    $created=Invoke-ConsumerSql @'
IF EXISTS(SELECT 1 FROM catalog.folders WHERE name=@folder) THROW 51000,'CONSUMER_FOLDER_ALREADY_EXISTS',1;
DECLARE @id bigint;
EXEC catalog.create_folder @folder_name=@folder,@folder_id=@id OUTPUT;
SELECT @id AS FolderId;
'@ @{folder=$folder}
    $folderId=[long]$created.ResultSets[0].Rows[0][0]
    if($folderId -lt 1){throw 'CONSUMER_ACCEPTANCE_FOLDER_ID_MISSING'}
    $cleanupParameters=@{folder=$folder;folderId=$folderId;project=$project;projectId=0L;projectVersion=0L;success=0L;failure=0L;incomplete=0L;freshClaim=0}
    $cleanupStatus='OWN_FOLDER_CREATED';Save-ConsumerRecovery
    $wrong=@{};foreach($key in $cleanupParameters.Keys){$wrong[$key]=$cleanupParameters[$key]};$wrong.folderId=$folderId+1
    $guard=Invoke-ConsumerSql $cleanupSql $wrong -AllowFailure
    $exists=Invoke-ConsumerSql 'SELECT COUNT(*) FROM catalog.folders WHERE folder_id=@id AND name=@folder;' @{id=$folderId;folder=$folder}
    $guardVerified=(-not $guard.Success -and $guard.SqlErrorNumber -eq 51000 -and $exists.ResultSets[0].Rows[0][0] -eq 1)
    if(-not $guardVerified){throw 'CONSUMER_ACCEPTANCE_ID_GUARD_FAILED'}
    # Reuse the same actual Writer already exercised by the format acceptance.
    $writer=& $module {(Get-LabSsisCatalogFixtureGuestProbe).Ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-SsisFixtureProject'},$true).Extent.Text}
    if(-not $writer){throw 'CONSUMER_ACCEPTANCE_EXISTING_WRITER_REQUIRED'}
    . ([scriptblock]::Create($writer))
    $ispac=Write-SsisFixtureProject -Directory $workspace -ProjectName $project
    $deployed=Invoke-ConsumerSql @'
DECLARE @operation bigint;
EXEC catalog.deploy_project @folder_name=@folder,@project_name=@project,@project_stream=@stream,@operation_id=@operation OUTPUT;
SELECT project_id,object_version_lsn FROM catalog.projects WHERE folder_id=@folderId AND name=@project;
'@ @{folder=$folder;folderId=$folderId;project=$project;stream=[IO.File]::ReadAllBytes($ispac)}
    $projectId=[long]$deployed.ResultSets[0].Rows[0][0];$projectVersion=[long]$deployed.ResultSets[0].Rows[0][1]
    if($projectId -lt 1 -or $projectVersion -lt 1){throw 'CONSUMER_ACCEPTANCE_PROJECT_ID_MISSING'}
    $cleanupParameters.projectId=$projectId;$cleanupParameters.projectVersion=$projectVersion
    $cleanupStatus='OWN_PROJECT_DEPLOYED';Save-ConsumerRecovery
    $execution=Invoke-ConsumerSql @'
DECLARE @id bigint;
EXEC catalog.create_execution @folder_name=@folder,@project_name=@project,@package_name=N'Success.dtsx',@use32bitruntime=0,@reference_id=NULL,@execution_id=@id OUTPUT;
SELECT @id AS ExecutionId;
'@ @{folder=$folder;project=$project}
    $executionId=[long]$execution.ResultSets[0].Rows[0][0]
    if($executionId -lt 1 -or $executionId -in $ProtectedExecutionId){throw 'CONSUMER_ACCEPTANCE_EXECUTION_ID_INVALID'}
    $cleanupParameters.success=$executionId;$cleanupStatus='OWN_EXECUTION_CREATED';Save-ConsumerRecovery
    $null=Invoke-ConsumerSql @'
DECLARE @level smallint=1;
EXEC catalog.set_execution_parameter_value @execution_id=@id,@object_type=50,@parameter_name=N'LOGGING_LEVEL',@parameter_value=@level;
EXEC catalog.start_execution @execution_id=@id;
'@ @{id=$executionId}
    $deadline=[datetime]::UtcNow.AddSeconds(180)
    do {
        $state=Invoke-ConsumerSql 'SELECT status FROM catalog.executions WHERE execution_id=@id AND project_lsn=@version;' @{id=$executionId;version=$projectVersion}
        $executionStatus=[int]$state.ResultSets[0].Rows[0][0]
        if($executionStatus -notin @(1,2,5,8)){break}
        if([datetime]::UtcNow -ge $deadline){throw 'CONSUMER_ACCEPTANCE_EXECUTION_TIMEOUT'}
        Start-Sleep -Seconds 2
    } while($true)
    if($executionStatus -ne 7){throw 'CONSUMER_ACCEPTANCE_EXECUTION_FAILED'}
    $null=Invoke-ConsumerSql 'SELECT COUNT(*) AS EventCount FROM catalog.event_messages WHERE operation_id=@id;' @{id=$executionId}
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $workspace 'failure.private.log')
    $primaryFailure=$true
} finally {
    if($folderId -gt 0) {
        try {
            $null=Invoke-ConsumerSql $cleanupSql $cleanupParameters
            $absent=Invoke-ConsumerSql 'SELECT COUNT(*) FROM catalog.folders WHERE folder_id=@id OR name=@folder;' @{id=$folderId;folder=$folder}
            if($absent.ResultSets[0].Rows[0][0] -ne 0){throw 'CONSUMER_ACCEPTANCE_FOLDER_RETAINED'}
            $cleanupStatus='OWN_PROJECT_AND_FOLDER_REMOVED'
        } catch {
            $_ | Out-String | Set-Content -LiteralPath (Join-Path $workspace 'cleanup.private.log')
            $cleanupFailure=$true;$cleanupStatus='RECOVERY_REQUIRED'
        }
    } elseif($cleanupStatus -eq 'ARRANGE_PLANNED') {$cleanupFailure=$true;$cleanupStatus='CREATE_OUTCOME_UNCONFIRMED'}
    Save-ConsumerRecovery
}
$unchanged=$false;$metadataUnchanged=$true
try {
    $after=Invoke-ConsumerSql $inventorySql $protectedParameters
    $unchanged=($baseline -ceq (ConvertTo-Json -InputObject $after.ResultSets -Depth 10 -Compress))
    foreach($name in $metadata.Keys){if((Get-FileHash -LiteralPath (Join-Path $context.Directory $name) -Algorithm SHA256).Hash -cne $metadata[$name]){$metadataUnchanged=$false}}
} catch {$primaryFailure=$true}
$passed=(-not $primaryFailure -and -not $cleanupFailure -and $unchanged -and $metadataUnchanged -and $guardVerified -and $executionStatus -eq 7 -and $schemes.Count -gt 0)
$evidence=[ordered]@{ContractVersion='SqlServerLab.WindowsSqlConsumerAcceptance/1.0';Status=$(if($passed){'PASSED'}else{'FAILED'});
    RunId=$RunId.ToString();InstanceId=$InstanceId;Authentication='Windows';AuthSchemes=@($schemes|Sort-Object);
    ProtectedExecutionIds=$ProtectedExecutionId;ProtectedExecutionsAndEventsUnchanged=$unchanged;SourceMetadataUnchanged=$metadataUnchanged;
    ExistingActiveCatalogAndDatabaseInventoryUnchanged=$unchanged;CatalogPropertiesUnchanged=$unchanged;
    OwnFolderId=$folderId;OwnProjectId=$projectId;OwnProjectVersion=$projectVersion;OwnExecutionId=$executionId;OwnExecutionStatus=$executionStatus;
    MismatchedFolderIdRejected=$guardVerified;Cleanup=$cleanupStatus;PublicApiOperationIds=$apiOperations.ToArray();
    GlobalConfigurationMutations=0;SourceFixtureApiCalls=0;HistoryCleanup='UNCHANGED_MANUFACTURER_RETENTION'}
if($EvidencePath){& $module {param($Path) $null=Assert-LabDiagnosticPath -Path $Path} $EvidencePath;$evidence|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $EvidencePath -Encoding utf8}
$evidence|ConvertTo-Json -Depth 8
if(-not $passed){throw 'WINDOWS_SQL_CONSUMER_ACCEPTANCE_FAILED: Private recovery evidence remains local.'}
