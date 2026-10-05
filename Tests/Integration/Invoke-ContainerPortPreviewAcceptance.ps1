#Requires -Version 7.2
<#
.SYNOPSIS
    Owned-host-only native port PLAN_ONLY acceptance for one fresh SQL run.
.DESCRIPTION
    Requires an already reachable Docker or Podman runtime and a fresh external
    sql-lab-port-preview-<full GUID N> parent. Creates separate exact parent and
    State policies, one nonpersistent modern run, and exercises public core,
    actual console menu routing and the exact in-process HTTP server route.
    No listener/rendered browser or Apply is exercised. Failed/unreturned
    creation or unconfirmed cleanup retains all custody under the parent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$ParentOperationId,
    [switch]$RuntimeMutexAlreadyHeld
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'Tests/Common/OwnedHostTestScope.ps1')
. (Join-Path $repo 'Tests/Common/ContainerPortPreviewAcceptance.ps1')
$root=Assert-PortPreviewAcceptanceLayout -DataRoot $DataRoot -RepositoryRoot $repo
$mutex=$null;$locked=$false;$module=$null;$scope=$null;$custody=$null
$unreturnedCreation=$false;$completed=$false;$primaryError=$null;$cleanupError=$null;$cleanup=$null;$observations=$null
$readiness=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
$evidence=$null
try {
    if(-not $RuntimeMutexAlreadyHeld){
        $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
        $locked=$mutex.WaitOne([TimeSpan]::FromMinutes(10))
        if(-not $locked){throw 'PORT_ACCEPTANCE_MUTEX_TIMEOUT'}
    }
    $resolution=@(& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available){throw 'PORT_ACCEPTANCE_TOOL_UNAVAILABLE'}
    $module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
    # Existing evidence ancestors must pass the actual no-reparse guard before
    # this first local write and before any runtime mutation/own arrangement.
    $evidence=New-PortPreviewAcceptanceEvidenceDirectory -Module $module -RepositoryRoot $repo
    # Initializer pins and checks existing runtime; never starts a provider/machine.
    $scope=New-PortPreviewAcceptanceScope -Module $module -DataRoot $root -Provider $Provider -ParentOperationId $ParentOperationId
    $env:SQL_SERVER_LAB_STATE=$scope.StateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$scope.DataRoot
    $readiness=Test-SqlServerLabPrerequisite -Provider $Provider -StateRoot $scope.StateRoot
    if($readiness.Status -cne 'RESOURCE_OK'){throw 'PORT_ACCEPTANCE_READINESS_BLOCKED'}
    $password=[Security.SecureString]::new()
    foreach($character in ('PortPreview!aA7_'+[guid]::NewGuid().ToString('N')).ToCharArray()){$password.AppendChar($character)}
    $password.MakeReadOnly()
    & $module {param($Path)$null=Assert-LabOwnedHostPath $Path} $evidence
    $unreturnedCreation=$true
    try {
        $lab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName port-preview -StateRoot $scope.StateRoot -SaPassword $password -SkipAssessment
    } finally {$password.Dispose()}
    $parsed=[guid]::Empty
    if(-not [guid]::TryParseExact([string]$lab.RunId,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw 'PORT_ACCEPTANCE_RETURNED_RUN_INVALID'}
    $custody=Get-PortPreviewAcceptanceCustody -Module $module -Scope $scope -RunId $lab.RunId -Provider $Provider
    $unreturnedCreation=$false
    if($lab.State -cne 'Running'){throw 'PORT_ACCEPTANCE_INSTALLATION_NOT_RUNNING'}
    $before=Get-PortPreviewAcceptanceFileBinding -DataRoot $root
    $observations=Invoke-PortPreviewAcceptanceObservations -Module $module -Scope $scope -RunId $lab.RunId -Provider $Provider -RepositoryRoot $repo
    $after=Get-PortPreviewAcceptanceFileBinding -DataRoot $root
    if(($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'PORT_ACCEPTANCE_PREVIEW_STATE_WRITE'}
    $custody|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence custody.private.json) -Encoding utf8
    [pscustomobject]@{Before=$before;After=$after;Equal=$true}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence state-bindings.private.json) -Encoding utf8
    $completed=$true
} catch {$primaryError=$_}
finally {
    try {$cleanup=Remove-PortPreviewAcceptanceScope -Module $module -Scope $scope -Custody $custody -Provider $Provider -UnreturnedCreation $unreturnedCreation -Completed $completed -EvidenceRoot $evidence}
    catch {$cleanupError=$_}
    finally {
        $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
        try {if($module){Remove-Module $module -Force -ErrorAction Stop}}catch{if(-not $cleanupError){$cleanupError=$_}}
        try {if($locked){$mutex.ReleaseMutex()}}catch{if(-not $cleanupError){$cleanupError=$_}}
        try {if($mutex){$mutex.Dispose()}}catch{if(-not $cleanupError){$cleanupError=$_}}
    }
}
$status=if($primaryError -or $cleanupError -or -not $completed -or $cleanup.Status -cne 'CLEANED'){'RECOVERY_REQUIRED'}else{'PASS'}
$result=[pscustomobject]@{Contract='SqlServerLab.ContainerPortNativeAcceptance/1.0';Provider=$Provider;Status=$status;
    Installation=$(if($custody){'OWN_RUNNING_RUN_OBSERVED'}else{'NOT_CONFIRMED'});Readiness=$(if($readiness){$readiness.Status}else{'NOT_EXECUTED'});
    Observations=$observations;Cleanup=$cleanup;UnreturnedCreation=$unreturnedCreation;
    SQLDuringPreview='NOT_CHECKED';RenderedBrowser='NOT_EXECUTED';HttpNetworkTransport='NOT_EXECUTED';AtomicFilesystemProof=$false;
    PrimaryFailure=[bool]$primaryError;CleanupFailure=[bool]$cleanupError}
if($evidence){
    try {& $module {param($Path)$null=Assert-LabOwnedHostPath $Path} $evidence;$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence result.private.json) -Encoding utf8}
    catch {if(-not $primaryError){$primaryError=$_}}
}
if($primaryError){if($cleanupError){$primaryError.Exception.Data['PortPreviewCleanupRecoveryRequired']=$true};throw $primaryError}
if($status -cne 'PASS'){throw 'PORT_ACCEPTANCE_RECOVERY_REQUIRED'}
Write-Host 'PASS: owned ContainerPortPreview core/console/in-process HTTP acceptance and receipt-bound cleanup.'
