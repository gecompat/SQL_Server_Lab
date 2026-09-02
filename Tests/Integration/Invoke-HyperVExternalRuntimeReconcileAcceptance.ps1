#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fuehrt den nativen oeffentlichen Hyper-V-External-Runtime-Reconcile-Nachweis aus.
.DESCRIPTION
    Verwendet den bestehenden isolierten SQL-2022-Hyper-V-Acceptance-Aufbau,
    persistiert einen softwarefreien Desired State und prueft danach den
    oeffentlichen Plan/WhatIf/Apply/No-op/Removal-Blockade-Pfad. Die eigentliche
    Gastinstallation, SQL-Postconditions, Cold-Start-Probes und der optionale
    scopegebundene Cleanup bleiben identisch zum direkten Runtime-Nachweis.
#>
[CmdletBinding()]
param(
    [string]$RunId,
    [string]$CloneSourceRunId,
    [string]$MediaRoot = 'D:\Lab_Base',
    [string]$ArtifactId = 'hyperv-os-sealed-01f5d9a11f91ee9641eb2cde936431b4d6258333b4f7a0e6e51032df74878be5',
    [switch]$CleanupOnSuccess
)

$runner = Join-Path $PSScriptRoot 'Invoke-ExternalRuntimeHyperVAcceptance.ps1'
& $runner -RunId $RunId -CloneSourceRunId $CloneSourceRunId -MediaRoot $MediaRoot `
    -ArtifactId $ArtifactId -ReconcileAcceptance -CleanupOnSuccess:$CleanupOnSuccess
