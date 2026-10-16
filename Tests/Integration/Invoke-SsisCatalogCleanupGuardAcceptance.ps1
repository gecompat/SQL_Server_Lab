#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den Fremdobjektschutz an einer eigenen aktiven SSISDB-Fixture.
.DESCRIPTION
    Legt genau eine eigene synthetische Umgebung als fremdes Objekt relativ
    zur Fixture an. Erwartet Cleanup-Abbruch ohne Projekt-/Umgebungsverlust
    und entfernt anschließend ausschließlich diese identitätsgebundene Umgebung.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$context=& $module {param($Id,$Root) Get-LabSsisPrerequisiteContext -RunId $Id -InstanceId primary -StateRoot $Root} $RunId $StateRoot
$receipt=Get-Content -LiteralPath (Join-Path $context.Directory 'ssis-fixture-receipt.json') -Raw|ConvertFrom-Json
if([string]$receipt.RunId -ne $RunId.ToString() -or [int64]$receipt.FolderId -lt 1 -or [string]$receipt.FolderName -cnotmatch '^LabFixture_[a-f0-9]{12}$'){throw 'SSIS_GUARD_FIXTURE_BINDING_INVALID'}
& $module {param($Root,$Repo) Assert-LabSsisEvidenceLocation -StateRoot $Root -RepositoryRoot $Repo} $StateRoot $repoRoot
$diagnostics=Join-Path $StateRoot 'diagnostics';$null=New-Item -ItemType Directory -Path $diagnostics -Force
$name='LabGuard_'+[guid]::NewGuid().ToString('N')
$recordPath=Join-Path $diagnostics ('ssis-cleanup-guard-'+[guid]::NewGuid().ToString('N')+'.json')
$record=[pscustomobject]@{RunId=$RunId.ToString();ScopeId=[string]$context.Run.scopeId;FolderId=$receipt.FolderId;EnvironmentName=$name;EnvironmentId=0;Status='PREPARING'}
function Save-SsisGuardRecord {& $module {param($Path,$Record) Write-LabArtifactJsonAtomic -Path $Path -InputObject $Record} $recordPath $record}
function Invoke-SsisGuardGuest {
    param([string]$Action,[int64]$EnvironmentId=0)
    & $module {
        param($Context,$Folder,$FolderId,$Name,$Action,$EnvironmentId)
        $secret=Get-LabSecret -Path $Context.Directory -Name 'guest-administrator-password'
        try {
            Invoke-HyperVPowerShellDirect -VMName $Context.Instance.vmName -ExpectedRunId $Context.Run.runId -ExpectedScopeId $Context.Run.scopeId -ExpectedVmId ([guid]$Context.Instance.vmId) -Credential ([PSCredential]::new('Administrator',$secret)) -TimeoutSeconds 90 -ArgumentList @($Folder,[int64]$FolderId,$Name,$Action,$EnvironmentId) -ScriptBlock {
                param($Folder,[int64]$FolderId,$Name,$Action,[int64]$EnvironmentId)
                $connection=[Data.SqlClient.SqlConnection]::new('Data Source=localhost;Initial Catalog=SSISDB;Integrated Security=SSPI;Connect Timeout=15;Encrypt=False;Pooling=False')
                try {
                    $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=30
                    try {
                        foreach($key in @('folder','name')){$null=$command.Parameters.Add('@'+$key,[Data.SqlDbType]::NVarChar,128)}
                        $command.Parameters['@folder'].Value=$Folder;$command.Parameters['@name'].Value=$Name
                        $null=$command.Parameters.Add('@folderId',[Data.SqlDbType]::BigInt);$command.Parameters['@folderId'].Value=$FolderId
                        $null=$command.Parameters.Add('@environmentId',[Data.SqlDbType]::BigInt);$command.Parameters['@environmentId'].Value=$EnvironmentId
                        $guard="IF NOT EXISTS(SELECT 1 FROM catalog.folders WHERE name=@folder AND folder_id=@folderId) THROW 51000,'SSIS_GUARD_FOLDER_CHANGED',1; "
                        switch($Action){
                            create{$command.CommandText=$guard+'EXEC catalog.create_environment @folder_name=@folder,@environment_name=@name; SELECT environment_id FROM catalog.environments WHERE folder_id=@folderId AND name=@name;'}
                            observe{$command.CommandText=$guard+'SELECT (SELECT COUNT(*) FROM catalog.projects WHERE folder_id=@folderId)+(SELECT COUNT(*) FROM catalog.environments WHERE folder_id=@folderId AND name=@name AND environment_id=@environmentId);'}
                            remove{$command.CommandText=$guard+"IF NOT EXISTS(SELECT 1 FROM catalog.environments WHERE folder_id=@folderId AND name=@name AND environment_id=@environmentId) THROW 51000,'SSIS_GUARD_ENVIRONMENT_CHANGED',1; EXEC catalog.delete_environment @folder_name=@folder,@environment_name=@name; SELECT CONVERT(bigint,0);"}
                            default{throw 'SSIS_GUARD_ACTION_INVALID'}
                        }
                        $command.ExecuteScalar()
                    } finally {$command.Dispose()}
                } finally {$connection.Dispose()}
            }
        } finally {if($secret){$secret.Dispose()}}
    } $context $receipt.FolderName ([int64]$receipt.FolderId) $name $Action $EnvironmentId
}
$primary=$null;$passed=$false
Save-SsisGuardRecord
try {
    $record.EnvironmentId=[int64](Invoke-SsisGuardGuest -Action create)
    if($record.EnvironmentId -lt 1){throw 'SSIS_GUARD_ENVIRONMENT_NOT_BOUND'}
    $record.Status='SYNTHETIC_ENVIRONMENT_CREATED';Save-SsisGuardRecord
    $blocked=$false
    try {$null=SqlServerLab\Remove-SqlServerLabSsisCatalogFixture -RunId $RunId -StateRoot $StateRoot -Confirm:$false}
    catch {if($_.Exception.Message -notmatch 'SSIS_FIXTURE_FOREIGN_RESOURCES_RETAINED'){throw};$blocked=$true}
    if(-not $blocked -or [int](Invoke-SsisGuardGuest -Action observe -EnvironmentId $record.EnvironmentId) -ne 2){throw 'SSIS_GUARD_PRESERVATION_FAILED'}
    $passed=$true
} catch {$primary=$_}
finally {
    if($record.EnvironmentId -gt 0){
        try {$null=Invoke-SsisGuardGuest -Action remove -EnvironmentId $record.EnvironmentId;$record.Status='SYNTHETIC_ENVIRONMENT_REMOVED'}
        catch {if(-not $primary){$primary=$_};$record.Status='RECOVERY_REQUIRED'}
    }
    elseif($primary){$record.Status='REVIEW_CREATION_OUTCOME'}
    Save-SsisGuardRecord
}
if($primary){
    $primary.Exception.ToString()|Add-Content -LiteralPath ($recordPath+'.private.log')
    throw 'SSIS_CLEANUP_GUARD_ACCEPTANCE_FAILED: own diagnostic record retained.'
}
if(-not $passed){throw 'SSIS_CLEANUP_GUARD_NOT_EXECUTED'}
[pscustomobject]@{Status='FOREIGN_RESOURCE_GUARD_PASSED';ProjectPreserved=$true;SyntheticEnvironmentPreserved=$true;SyntheticEnvironmentCleanup='SUCCEEDED'}
