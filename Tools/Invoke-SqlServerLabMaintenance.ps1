#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft und korrigiert den lokalen SQL_Server_Lab-Zustand ohne KI.
.DESCRIPTION
    Erstellt einen deterministischen Maintenance-Plan. Ohne -Apply wird nur
    geplant. -Apply führt sichere State-Korrekturen aus; -Cleanup ergänzt
    scopegebundene Orphan- und Run-Bereinigung. Legacy-Testartefakte ohne
    vollständige Run-/Scope-Identität werden nur zusammen mit
    -AllowLegacyTestArtifactRemoval entfernt. Fremde Ressourcen bleiben immer
    unangetastet.
.PARAMETER Apply
    Führt den Plan aus. Ohne diesen Schalter bleibt der Aufruf read-only.
.PARAMETER Cleanup
    Führt zusätzlich scopegebundene Cleanup-Aktionen aus.
.PARAMETER AllowLegacyTestArtifactRemoval
    Erlaubt zusammen mit -Cleanup die eng revalidierte Entfernung alter
    SQL_Server_Lab-Testartefakte ohne vollständige Run-/Scope-Identität.
.PARAMETER Full
    Ergänzt den langsameren Storage- und Cleanup-Audit.
.PARAMETER StaleAfterMinutes
    Mindestalter unvollständiger Runs vor einem Cleanup-Vorschlag.
.PARAMETER AsJson
    Gibt das Ergebnis maschinenlesbar als JSON aus.
.EXAMPLE
    .\Tools\Invoke-SqlServerLabMaintenance.ps1
.EXAMPLE
    .\Tools\Invoke-SqlServerLabMaintenance.ps1 -Apply -Cleanup
.EXAMPLE
    .\Tools\Invoke-SqlServerLabMaintenance.ps1 -Apply -Cleanup -AllowLegacyTestArtifactRemoval -AsJson
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$RemainingArgs,
    [switch]$Apply,
    [switch]$Cleanup,
    [switch]$AllowLegacyTestArtifactRemoval,
    [switch]$Full,
    [ValidateRange(5,10080)][int]$StaleAfterMinutes=60,
    [string]$StateRoot,
    [switch]$AsJson
)

$showHelpRequested=$ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'
if($showHelpRequested){Get-Help -Full -Name $PSCommandPath|Out-Host;return}
$ErrorActionPreference='Stop'
$unknownArguments=@($RemainingArgs|Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)})
if($unknownArguments.Count -gt 0){throw "UNKNOWN_ARGUMENTS: $($unknownArguments -join ', ')"}
if($AllowLegacyTestArtifactRemoval -and (-not $Apply -or -not $Cleanup)){throw 'ALLOW_LEGACY_REQUIRES_APPLY_AND_CLEANUP'}
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop

$planArgs=@{
    Mode=if($Full){'Full'}else{'Runtime'}
    StaleAfterMinutes=$StaleAfterMinutes
}
if($StateRoot){$planArgs.StateRoot=$StateRoot}
$plan=Get-SqlServerLabMaintenancePlan @planArgs

if(-not $Apply){
    if($AsJson){$plan|ConvertTo-Json -Depth 20;return}
    $plan.Actions|Select-Object Disposition,ActionType,Provider,Name,RunId,ReasonCode|Format-Table -AutoSize
    Write-Host ("Status: {0}; Aktionen: {1}; fremde Ressourcen: {2}" -f $plan.Status,@($plan.Actions).Count,$plan.Summary.ForeignResources)
    return
}

$invokeArgs=@{
    Plan=$plan
    Mode=if($Cleanup){'Cleanup'}else{'Safe'}
    AllowLegacyTestArtifactRemoval=$AllowLegacyTestArtifactRemoval
    Confirm=$false
    WhatIf=[bool]$WhatIfPreference
}
if($StateRoot){$invokeArgs.StateRoot=$StateRoot}
$result=Invoke-SqlServerLabMaintenance @invokeArgs
if($AsJson){$result|ConvertTo-Json -Depth 24;return}
$result.Actions|Select-Object Status,ActionType,Name,RunId,Error|Format-Table -AutoSize
Write-Host ("Status: {0}; abgeschlossen: {1}; übersprungen: {2}; fehlgeschlagen: {3}; verbleibend: {4}" -f $result.Status,$result.Completed,$result.Skipped,$result.Failed,@($result.RemainingPlan.Actions).Count)
if($result.Failed -gt 0){exit 1}
