#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den öffentlichen Start-/Stop-Lifecycle der geschützten Testgruppe.
.DESCRIPTION
    Startet die registrierten Windows-Mitglieder, fordert einen vollständigen
    READY-Export und stoppt sie im garantierten Cleanup wieder. Danach müssen
    alle Windows-Ziele live STOPPED und der Gruppenexport fail-closed sein.
    Runs, Registrierungen, Secrets und Linux-Mitglieder dürfen sich nicht ändern.
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
$startValidated = $false
$startFailure = $null
try {
    $start = Start-SqlServerLabAutomatedTestEnvironment -StateRoot $StateRoot `
        -TimeoutSeconds $TimeoutSeconds -Force -Confirm:$false
    if ([string]$start.Status -ne 'READY' -or [int]$start.Errors -ne 0 -or
        [string]$start.Export.GroupStatus -ne 'READY' -or [int]$start.Export.Ready -ne [int]$start.Export.Entries) {
        throw "TEST_ENVIRONMENT_GROUP_START_NOT_READY: Status=$($start.Status), Group=$($start.Export.GroupStatus)"
    }
    $startValidated = $true
}
catch {
    $startFailure = $_
}
finally {
    $stop = Stop-SqlServerLabAutomatedTestEnvironment -StateRoot $StateRoot -Force -Confirm:$false
}

if ([string]$stop.Status -ne 'STOPPED' -or [int]$stop.Errors -ne 0) {
    throw "TEST_ENVIRONMENT_GROUP_STOP_FAILED: Status=$($stop.Status), Errors=$($stop.Errors)"
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
if ($after.WindowsStates.Count -ne 1 -or [string]$after.WindowsStates[0] -ne 'STOPPED') {
    throw "TEST_ENVIRONMENT_WINDOWS_STOPPED_POSTCONDITION_FAILED: $($after.WindowsStates -join ',')"
}
if ([string]$stop.Export.GroupStatus -ne 'INCOMPLETE' -or [string]$after.GroupStatus -ne 'INCOMPLETE') {
    throw 'TEST_ENVIRONMENT_STOP_EXPORT_NOT_FAIL_CLOSED'
}
if ($startFailure) { throw $startFailure }

[PSCustomObject]@{
    Status='PASS'; StartValidated=$startValidated; WindowsReady=[int]$start.Ready
    StartGroupStatus=[string]$start.Export.GroupStatus; WindowsStopped=[int]$stop.Stopped
    StopGroupStatus=[string]$stop.Export.GroupStatus; BindingsPreserved=$true; LinuxPreserved=$true
}
