#Requires -Version 7.2
<#
.SYNOPSIS
Erstellt eine geprüfte Windows-Server-2016+-Evaluation als OS_SEALED-Vorlage.

.DESCRIPTION
Installiert Windows unbeaufsichtigt aus dem hashgebundenen ISO, prüft Edition
und Evaluationsstatus im Gast, entfernt das temporäre Credential-Medium, führt
Sysprep aus und veröffentlicht erst danach das immutable Parent-Artefakt.

.PARAMETER Version
Windows Server 2008 R2, 2012 R2, 2016, 2019, 2022 oder 2025.

.PARAMETER MediaRoot
Kanonischer externer Media Root.

.PARAMETER ExternalSwitchName
Optionaler verbundener External-Switch für die einmalige Evaluation-Aktivierung.

.PARAMETER KeepOnFailure
Behält einen fehlgeschlagenen Builder ausdrücklich zur Diagnose.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('2008R2','2012R2','2016','2019','2022','2025')]
    [string[]]$Version,
    [string]$MediaRoot='D:\Lab1_Base',
    [string]$StateRoot,
    [string]$ExternalSwitchName,
    [ValidateRange(300,3600)][int]$TimeoutSeconds=1800,
    [switch]$KeepOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
foreach($item in @($Version | Select-Object -Unique)) {
    if (-not $PSCmdlet.ShouldProcess("Windows Server $item", 'unbeaufsichtigt installieren, generalisieren und als OS_SEALED veröffentlichen')) {
        [pscustomobject]@{Status='PLANNED';Version=$item;MediaRoot=$MediaRoot}
        continue
    }
    & $module {
        param($Version,$MediaRoot,$StateRoot,$ExternalSwitchName,$TimeoutSeconds,$KeepOnFailure)
        if ($Version -in @('2008R2','2012R2')) {
            if (-not $ExternalSwitchName) { throw 'HYPERV_LEGACY_TEMPLATE_EXTERNAL_SWITCH_REQUIRED' }
            Invoke-HyperVLegacyWindowsEvaluationTemplateBuild -Version $Version -MediaRoot $MediaRoot `
                -StateRoot $StateRoot -ExternalSwitchName $ExternalSwitchName `
                -TimeoutSeconds $TimeoutSeconds -KeepOnFailure:$KeepOnFailure -Confirm:$false
        }
        else {
            Invoke-HyperVWindowsEvaluationTemplateBuild -Version $Version -MediaRoot $MediaRoot `
                -StateRoot $StateRoot -ExternalSwitchName $ExternalSwitchName `
                -TimeoutSeconds $TimeoutSeconds -KeepOnFailure:$KeepOnFailure -Confirm:$false
        }
    } $item $MediaRoot $StateRoot $ExternalSwitchName $TimeoutSeconds $KeepOnFailure.IsPresent
}
