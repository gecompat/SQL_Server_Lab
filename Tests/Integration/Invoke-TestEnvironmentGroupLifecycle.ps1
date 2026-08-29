#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den öffentlichen Start-/Stop-Lifecycle der geschützten Testgruppe.
.DESCRIPTION
    Startet die registrierten Windows-Mitglieder, fordert einen vollständigen
    READY-Export, prüft den nicht-destruktiven Gruppenstopp und stellt die
    persistente Testgruppe im garantierten Cleanup wieder vollständig bereit.
    Runs, Registrierungen, Secrets und Linux-Mitglieder dürfen sich nicht ändern;
    der Abschlusszustand muss READY bleiben.
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
        Linux=@($status.Entries | Where-Object Platform -eq 'linux' | ForEach-Object { "$($_.Key)|$($_.StatusCode)" } | Sort-Object)
        WindowsCount=@($registry.environments | Where-Object platform -eq 'windows').Count
    }
} $StateRoot
if ($before.WindowsCount -eq 0) { throw 'TEST_ENVIRONMENT_WINDOWS_TARGETS_NOT_FOUND' }

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
    $stoppedWindowsStates = @($stopped.Entries | Where-Object Platform -eq 'windows' | ForEach-Object StatusCode | Sort-Object -Unique)
    if ($stoppedWindowsStates.Count -ne 1 -or [string]$stoppedWindowsStates[0] -ne 'STOPPED') {
        throw "TEST_ENVIRONMENT_WINDOWS_STOPPED_POSTCONDITION_FAILED: $($stoppedWindowsStates -join ',')"
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
        Linux=@($status.Entries | Where-Object Platform -eq 'linux' | ForEach-Object { "$($_.Key)|$($_.StatusCode)" } | Sort-Object)
        WindowsStates=@($status.Entries | Where-Object Platform -eq 'windows' | ForEach-Object StatusCode | Sort-Object -Unique)
        GroupStatus=[string]$status.GroupStatus
    }
} $StateRoot

if ((Compare-Object $before.Bindings $after.Bindings) -or (Compare-Object $before.Linux $after.Linux)) {
    throw 'TEST_ENVIRONMENT_GROUP_LIFECYCLE_SCOPE_CHANGED'
}
if ($after.WindowsStates.Count -ne 1 -or [string]$after.WindowsStates[0] -ne 'READY') {
    throw "TEST_ENVIRONMENT_WINDOWS_READY_POSTCONDITION_FAILED: $($after.WindowsStates -join ',')"
}
if ([string]$after.GroupStatus -ne 'READY') {
    throw 'TEST_ENVIRONMENT_RESTORE_EXPORT_NOT_READY'
}
if ($testFailure) { throw $testFailure }

[PSCustomObject]@{
    Status='PASS'; StartValidated=$startValidated; WindowsReady=[int]$start.Ready
    StartGroupStatus=[string]$start.Export.GroupStatus; WindowsStopped=[int]$stop.Stopped
    StopGroupStatus=[string]$stop.Export.GroupStatus; WindowsRestored=[int]$restore.Ready
    FinalGroupStatus=[string]$restore.Export.GroupStatus; BindingsPreserved=$true; LinuxPreserved=$true
}
