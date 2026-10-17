#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den öffentlichen lesenden Diagnoseweg gegen ein eigenes vorhandenes Gastziel.
.DESCRIPTION
    Nur eigene vertrauenswürdige synthetische ISPACs verwenden. Keine Paketausführung,
    Bereitstellung oder Runtimeeinrichtung. Ausgabe ausschließlich lokal aufbewahren.
    LOAD_FAILED ist ein beobachteter Diagnosebefund, keine akzeptierte Consumerpipeline.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$RunId,
    [string]$InstanceId='primary',
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$IspacPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory)][ValidateCount(1,16)][string[]]$PackageName
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$ready=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider hyperv -Operation Inspect
if($ready.Status -cne 'READY'){throw 'SSIS_DIAGNOSTIC_ACCEPTANCE_READINESS_BLOCKED'}
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
$runDirectory=Join-Path (Join-Path $StateRoot 'runs') $RunId.ToString()
$stateFiles=@('run-state.json','connection-info.json')|ForEach-Object {Join-Path $runDirectory $_}
$before=@($stateFiles|ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash})
$results=@()
foreach($name in $PackageName) {
    $result=Get-SqlServerLabSsisPackageDiagnostic -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot `
        -IspacPath $IspacPath -PackageName $name -ExpectedSha256 $ExpectedSha256
    if($result.Status -cnotin @('OBSERVED','LOAD_FAILED') -or $result.ExecutionStatus -cne 'NOT_EXECUTED' -or
        $result.ArtifactSha256 -ine $ExpectedSha256 -or -not $result.Observation.Inventory.Complete -or
        $result.Observation.Runtime.ProcessBitness -ne 64 -or $result.Observation.LoadStatus -cnotin @('RETURNED','FAILED')) {
        throw 'SSIS_DIAGNOSTIC_ACCEPTANCE_INCONCLUSIVE'
    }
    $results+=$result
}
$after=@($stateFiles|ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash})
if(($before -join ',') -cne ($after -join ',')){throw 'SSIS_DIAGNOSTIC_ACCEPTANCE_STATE_CHANGED'}
[pscustomobject]@{Status='DIAGNOSTIC_OBSERVED';RunFilesUnchanged=$true;ExecutionStatus='NOT_EXECUTED';Results=$results}
