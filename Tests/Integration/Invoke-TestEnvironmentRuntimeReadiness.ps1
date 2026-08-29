#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft oder repariert die Laufzeitbereitschaft der registrierten Testgruppe.
.DESCRIPTION
    Verwendet für die Recovery ausschließlich den öffentlichen, gruppengebundenen
    SQL_Server_Lab-Lifecycle. Ohne Recover erfolgt eine secretfreie read-only
    Statusprüfung. Die geschützte Testgruppe wird weder neu provisioniert noch
    gelöscht.
#>
[CmdletBinding()]
param(
    [string]$StateRoot,
    [switch]$Recover,
    [ValidateRange(10, 600)][int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop

if ($Recover) {
    $result = Start-SqlServerLabAutomatedTestEnvironment -StateRoot $StateRoot `
        -TimeoutSeconds $TimeoutSeconds -Force -Confirm:$false
    if ([string]$result.Status -ne 'READY' -or [int]$result.Errors -ne 0) {
        throw "TEST_ENVIRONMENT_RECOVERY_FAILED: Status=$($result.Status), Errors=$($result.Errors)"
    }
    [PSCustomObject]@{
        Status=[string]$result.Status; MembersReady=[int]$result.Ready
        Started=[int]$result.Started; Unchanged=[int]$result.Unchanged
        ExportGroupStatus=[string]$result.Export.GroupStatus
    }
    return
}

$status = & $module {
    param($RequestedStateRoot)
    Get-LabAutomatedTestEnvironmentStatus -StateRoot $RequestedStateRoot
} $StateRoot
$members = @($status.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.RunId) })
if ($members.Count -eq 0) { throw 'TEST_ENVIRONMENT_TARGETS_NOT_FOUND' }
$notReady = @($members | Where-Object { [string]$_.StatusCode -ne 'READY' })
if ($notReady.Count -gt 0) {
    throw "TEST_ENVIRONMENT_NOT_READY: $($notReady.Count) von $($members.Count)"
}
[PSCustomObject]@{ Status='READY'; MembersReady=$members.Count; Started=0; Unchanged=$members.Count; ExportGroupStatus=[string]$status.GroupStatus }
