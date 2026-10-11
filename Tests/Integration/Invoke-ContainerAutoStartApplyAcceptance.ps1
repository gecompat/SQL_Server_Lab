#Requires -Version 7.2
# Owned-host-only native acceptance for the direct in-place container autostart executor.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][string]$DataRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$ParentOperationId
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'Tests/Common/OwnedHostTestScope.ps1')
. (Join-Path $repo 'Tests/Common/ContainerPortPreviewAcceptance.ps1')
$root=Assert-PortPreviewAcceptanceLayout -DataRoot $DataRoot -RepositoryRoot $repo
$mutex=$null;$locked=$false;$module=$null;$scope=$null;$custody=$null;$unreturnedCreation=$false
$completed=$false;$primaryError=$null;$cleanupError=$null;$cleanup=$null;$evidence=$null;$readiness=$null;$observations=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
try {
    $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
    $locked=$mutex.WaitOne([TimeSpan]::FromMinutes(10));if(-not $locked){throw 'AUTOSTART_APPLY_ACCEPTANCE_MUTEX_TIMEOUT'}
    $resolution=@(& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available){throw 'AUTOSTART_APPLY_ACCEPTANCE_TOOL_UNAVAILABLE'}
    $module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru
    $evidence=New-PortPreviewAcceptanceEvidenceDirectory -Module $module -RepositoryRoot $repo
    $scope=New-PortPreviewAcceptanceScope -Module $module -DataRoot $root -Provider $Provider -ParentOperationId $ParentOperationId
    $env:SQL_SERVER_LAB_STATE=$scope.StateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$scope.DataRoot
    $readiness=Test-SqlServerLabPrerequisite -Provider $Provider -StateRoot $scope.StateRoot
    if($readiness.Status -cne 'RESOURCE_OK'){throw 'AUTOSTART_APPLY_ACCEPTANCE_READINESS_BLOCKED'}
    $password=[Security.SecureString]::new();foreach($character in ('AutoStartApply!aA7_'+[guid]::NewGuid().ToString('N')).ToCharArray()){$password.AppendChar($character)};$password.MakeReadOnly()
    $unreturnedCreation=$true
    try {$lab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2560 -LabName autostart-apply -AutoStart off -StateRoot $scope.StateRoot -SaPassword $password -SkipAssessment} finally {$password.Dispose()}
    $custody=Get-PortPreviewAcceptanceCustody -Module $module -Scope $scope -RunId $lab.RunId -Provider $Provider;$unreturnedCreation=$false
    if($lab.State -cne 'Running'){throw 'AUTOSTART_APPLY_ACCEPTANCE_INSTALLATION_NOT_RUNNING'}
    $observations=& $module {
        param($RunId,$StateRoot,$Provider,$EvidenceRoot)
        $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
        [pscustomobject]@{RuntimePinsType=$policy.RuntimePins.GetType().FullName;RuntimePinsIsArray=($policy.RuntimePins -is [array]);RuntimePinsCount=@($policy.RuntimePins).Count}|ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $EvidenceRoot 'direct-autostart-policy-read.private.json') -Encoding utf8
        $before=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $StateRoot
        $identity=[string]$before.ContainerId;$running=[bool]$before.WasRunning
        $noOp=Get-SqlServerLabContainerAutoStartPlan -RunId $RunId -InstanceId primary -AutoStart off -StateRoot $StateRoot
        if(-not $noOp.NoChange -or $noOp.MutationAllowed -or $noOp.ChangeClass -cne 'no-op'){throw 'AUTOSTART_APPLY_ACCEPTANCE_INITIAL_NOOP'}
        $on=Get-SqlServerLabContainerAutoStartPlan -RunId $RunId -InstanceId primary -AutoStart on -StateRoot $StateRoot
        if($on.NoChange -or -not $on.MutationAllowed -or $on.ChangeClass -cne 'live'){throw 'AUTOSTART_APPLY_ACCEPTANCE_ON_PLAN'}
        $onResult=Set-SqlServerLabContainerAutoStart -RunId $RunId -InstanceId primary -AutoStart on -ExpectedAutoStartPlanKey $on.PlanKey -StateRoot $StateRoot -Confirm:$false
        $afterOn=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $StateRoot
        if($onResult.Status -cne 'SUCCEEDED' -or $afterOn.ContainerId -cne $identity -or $afterOn.WasRunning -ne $running -or $afterOn.CurrentAutoStart -cne 'on'){throw 'AUTOSTART_APPLY_ACCEPTANCE_ON_READBACK'}
        $off=Get-SqlServerLabContainerAutoStartPlan -RunId $RunId -InstanceId primary -AutoStart off -StateRoot $StateRoot
        $offResult=Set-SqlServerLabContainerAutoStart -RunId $RunId -InstanceId primary -AutoStart off -ExpectedAutoStartPlanKey $off.PlanKey -StateRoot $StateRoot -Confirm:$false
        $afterOff=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $StateRoot
        if($offResult.Status -cne 'SUCCEEDED' -or $afterOff.ContainerId -cne $identity -or $afterOff.WasRunning -ne $running -or $afterOff.CurrentAutoStart -cne 'off'){throw 'AUTOSTART_APPLY_ACCEPTANCE_OFF_READBACK'}
        $desired=Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
        if($desired.Status -cne 'VALID'){throw 'AUTOSTART_APPLY_ACCEPTANCE_DESIRED_STATE'}
        [pscustomobject]@{Provider=$Provider;IdentityPreserved=$true;PowerStatePreserved=$true;On='SUCCEEDED';Off='SUCCEEDED';FinalDesiredState='VALID'}
    } $lab.RunId $scope.StateRoot $Provider $evidence
    $observations|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $evidence 'direct-autostart-observation.private.json') -Encoding utf8
    $completed=$true
} catch {
    $primaryError=$_
    if($evidence){
        [pscustomobject]@{Message=$_.Exception.Message;Type=$_.Exception.GetType().FullName;Stack=$_.ScriptStackTrace}|ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $evidence 'direct-autostart-failure.private.json') -Encoding utf8
    }
}
finally {
    try {$cleanup=Remove-PortPreviewAcceptanceScope -Module $module -Scope $scope -Custody $custody -Provider $Provider -UnreturnedCreation $unreturnedCreation -Completed $completed -EvidenceRoot $evidence} catch {$cleanupError=$_}
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    try{if($module){Remove-Module $module -Force -ErrorAction Stop}}catch{if(-not $cleanupError){$cleanupError=$_}}
    try{if($locked){$mutex.ReleaseMutex()}}catch{if(-not $cleanupError){$cleanupError=$_}}
    try{if($mutex){$mutex.Dispose()}}catch{if(-not $cleanupError){$cleanupError=$_}}
}
$status=if($primaryError -or $cleanupError -or -not $completed -or $cleanup.Status -cne 'CLEANED'){'RECOVERY_REQUIRED'}else{'PASS'}
if($primaryError){throw $primaryError};if($cleanupError){throw $cleanupError};if($status -cne 'PASS'){throw 'AUTOSTART_APPLY_ACCEPTANCE_RECOVERY_REQUIRED'}
Write-Host "PASS: owned $Provider direct container autostart on/off acceptance and receipt-bound cleanup."
