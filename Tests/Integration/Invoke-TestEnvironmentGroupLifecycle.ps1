#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den öffentlichen Start-/Stop-Lifecycle der geschützten Testgruppe.
.DESCRIPTION
    Startet alle registrierten Docker-, Podman- und Hyper-V-Mitglieder, fordert
    einen vollständigen READY-Export, prüft den nicht-destruktiven Gruppenstopp
    und stellt die persistente Testgruppe im garantierten Cleanup wieder
    vollständig bereit. Runs, Registrierungen und Secrets dürfen sich nicht
    ändern; der Abschlusszustand muss READY bleiben.
#>
[CmdletBinding()]
param(
    [string]$StateRoot,
    [ValidateRange(10, 600)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop

$before = & $module {
    param($RequestedStateRoot)
    $registry = Get-LabTestEnvironmentRegistry
    $status = Get-LabAutomatedTestEnvironmentStatus -StateRoot $RequestedStateRoot
    [PSCustomObject]@{
        Bindings=@($registry.environments | ForEach-Object { "$($_.key)|$($_.runId)|$($_.platform)" } | Sort-Object)
        Providers=@($status.Entries | ForEach-Object { "$($_.Key)|$($_.Provider)" } | Sort-Object)
        MemberCount=@($registry.environments | Where-Object { [string]$_.runId }).Count
    }
} $StateRoot
if ($before.MemberCount -eq 0) { throw 'TEST_ENVIRONMENT_TARGETS_NOT_FOUND' }

$start = $null
$stop = $null
$restore = $null
$startValidated = $false
$testFailure = $null
$restoreFailure = $null
try {
    $start = Start-SqlServerLabAutomatedTestEnvironment -StateRoot $StateRoot `
        -TimeoutSeconds $TimeoutSeconds -Force -Confirm:$false
    if ([string]$start.Status -ne 'READY' -or [int]$start.Errors -ne 0 -or
        [string]$start.Export.GroupStatus -ne 'READY' -or [int]$start.Export.Ready -ne [int]$start.Export.Entries) {
        throw "TEST_ENVIRONMENT_GROUP_START_NOT_READY: Status=$($start.Status), Group=$($start.Export.GroupStatus)"
    }
    $startValidated = $true

    $stop = Stop-SqlServerLabAutomatedTestEnvironment -StateRoot $StateRoot -Force -Confirm:$false
    if ([string]$stop.Status -ne 'STOPPED' -or [int]$stop.Errors -ne 0) {
        throw "TEST_ENVIRONMENT_GROUP_STOP_FAILED: Status=$($stop.Status), Errors=$($stop.Errors)"
    }
    $stopped = & $module {
        param($RequestedStateRoot)
        Get-LabAutomatedTestEnvironmentStatus -StateRoot $RequestedStateRoot
    } $StateRoot
    $stoppedStates = @($stopped.Entries | ForEach-Object StatusCode | Sort-Object -Unique)
    if ($stoppedStates.Count -ne 1 -or [string]$stoppedStates[0] -ne 'STOPPED') {
        throw "TEST_ENVIRONMENT_STOPPED_POSTCONDITION_FAILED: $($stoppedStates -join ',')"
    }
    if ([string]$stop.Export.GroupStatus -ne 'INCOMPLETE' -or [string]$stopped.GroupStatus -ne 'INCOMPLETE') {
        throw 'TEST_ENVIRONMENT_STOP_EXPORT_NOT_FAIL_CLOSED'
    }
}
catch {
    $testFailure = $_
}
finally {
    try {
        $restore = Start-SqlServerLabAutomatedTestEnvironment -StateRoot $StateRoot `
            -TimeoutSeconds $TimeoutSeconds -Force -Confirm:$false
        if ([string]$restore.Status -ne 'READY' -or [int]$restore.Errors -ne 0 -or
            [string]$restore.Export.GroupStatus -ne 'READY' -or
            [int]$restore.Export.Ready -ne [int]$restore.Export.Entries) {
            throw "TEST_ENVIRONMENT_GROUP_RESTORE_NOT_READY: Status=$($restore.Status), Group=$($restore.Export.GroupStatus)"
        }
    }
    catch { $restoreFailure = $_ }
}

if ($restoreFailure) {
    if ($testFailure) {
        throw "TEST_ENVIRONMENT_GROUP_TEST_AND_RESTORE_FAILED: $($testFailure.Exception.Message) / $($restoreFailure.Exception.Message)"
    }
    throw $restoreFailure
}

$after = & $module {
    param($RequestedStateRoot)
    $registry = Get-LabTestEnvironmentRegistry
    $status = Get-LabAutomatedTestEnvironmentStatus -StateRoot $RequestedStateRoot
    [PSCustomObject]@{
        Bindings=@($registry.environments | ForEach-Object { "$($_.key)|$($_.runId)|$($_.platform)" } | Sort-Object)
        Providers=@($status.Entries | ForEach-Object { "$($_.Key)|$($_.Provider)" } | Sort-Object)
        MemberStates=@($status.Entries | ForEach-Object StatusCode | Sort-Object -Unique)
        GroupStatus=[string]$status.GroupStatus
    }
} $StateRoot

if ((Compare-Object $before.Bindings $after.Bindings) -or (Compare-Object $before.Providers $after.Providers)) {
    throw 'TEST_ENVIRONMENT_GROUP_LIFECYCLE_SCOPE_CHANGED'
}
if ($after.MemberStates.Count -ne 1 -or [string]$after.MemberStates[0] -ne 'READY') {
    throw "TEST_ENVIRONMENT_READY_POSTCONDITION_FAILED: $($after.MemberStates -join ',')"
}
if ([string]$after.GroupStatus -ne 'READY') {
    throw 'TEST_ENVIRONMENT_RESTORE_EXPORT_NOT_READY'
}
if ($testFailure) { throw $testFailure }

[PSCustomObject]@{
    Status='PASS'; StartValidated=$startValidated; MembersReady=[int]$start.Ready
    StartGroupStatus=[string]$start.Export.GroupStatus; MembersStopped=[int]$stop.Stopped
    StopGroupStatus=[string]$stop.Export.GroupStatus; MembersRestored=[int]$restore.Ready
    FinalGroupStatus=[string]$restore.Export.GroupStatus; BindingsPreserved=$true; ProvidersPreserved=$true
}
