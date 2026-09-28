#Requires -Version 7.2
<#
.SYNOPSIS
    Beobachtet SSIS-Voraussetzungen eines vorhandenen eigenen Hyper-V-SQL-2025-Runs.
.DESCRIPTION
    Interner Diagnoseeinstieg. Startet keine VM, installiert nichts und führt kein Package aus.
    Reale Ergebnisse bleiben lokal; fehlende Standarddateien beweisen keine fehlende Installation.
.PARAMETER RunId
    Expliziter eigener RUNNING-Run.
.PARAMETER InstanceId
    Registrierte SQL-Instanz im Run.
.PARAMETER TimeoutSeconds
    Begrenzung des Gasttransports in Sekunden.
.EXAMPLE
    ./Tools/Test-SqlServerLabSsisPrerequisite.ps1 -RunId $runId
.OUTPUTS
    Sanitisierte interne Beobachtung, keine Ausführungsfreigabe.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$RunId,[string]$InstanceId='primary',[ValidateRange(10,120)][int]$TimeoutSeconds=60)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
& $module {
    param($Id,$Instance,$Timeout)
    if (-not $IsWindows) { return ConvertTo-LabSsisPrerequisiteResult -Observation $null -FailureCode 'SSIS_TARGET_UNAVAILABLE' }
    Invoke-LabSsisPrerequisite -RunId $Id -InstanceId $Instance -StateRoot (Get-LabStateRoot) -TimeoutSeconds $Timeout
} $RunId $InstanceId $TimeoutSeconds
