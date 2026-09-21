#Requires -Version 7.2
<# Private bounded child; invoked only by the own-run acceptance supervisor. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$OperationId,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [switch]$CleanupOnly
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/PointInTimeRecoverySupervisor.ps1')
$record=Get-Content -LiteralPath (Join-Path $EvidenceRoot 'operation.json') -Raw | ConvertFrom-Json
Assert-PitrChildBinding -Record $record -Provider $Provider -OperationId $OperationId -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot
$env:SQL_SERVER_LAB_STATE=$StateRoot
$env:SQL_SERVER_LAB_DATA_ROOT=Join-Path $EvidenceRoot 'Lab_Data'
$resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
if (-not $resolution.Available) { throw 'PITR_RUNTIME_TOOL_UNAVAILABLE' }
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$observed=@(& $module {
    param($Repo,$Provider,$OperationId,$StateRoot,$EvidenceRoot,$Cleanup)
    . (Join-Path $Repo 'Tests/Common/PointInTimeRecoveryScenario.ps1')
    if ($Cleanup) { Remove-PitrOwnRun -Provider $Provider -OperationId $OperationId -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot }
    else { Invoke-PitrArrange -Provider $Provider -OperationId $OperationId -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot }
} $repoRoot $Provider $OperationId $StateRoot $EvidenceRoot $CleanupOnly)
if (-not $CleanupOnly) {
    if ($observed.Count -ne 1 -or $observed[0].Status -cne 'VERIFIED' -or $observed[0].SqlMajor -ne 17 -or
        $observed[0].RecoveryMilliseconds -le 0) { throw 'PITR_SQL_RECEIPT_INVALID' }
    [ordered]@{
        OperationId=$OperationId; Provider=$Provider; Status='VERIFIED'; SqlMajor=17
        RecoveryMilliseconds=[double]$observed[0].RecoveryMilliseconds
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'sql-receipt.json')
}
