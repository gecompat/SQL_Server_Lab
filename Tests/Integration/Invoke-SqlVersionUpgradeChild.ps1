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
. (Join-Path $repoRoot 'Tests/Common/SqlVersionUpgradeSupervisor.ps1')
$record=Get-Content -LiteralPath (Join-Path $EvidenceRoot 'operation.json') -Raw | ConvertFrom-Json
Assert-SqlUpgradeChildBinding -Record $record -Provider $Provider -OperationId $OperationId -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot
$env:SQL_SERVER_LAB_STATE=$StateRoot
$env:SQL_SERVER_LAB_DATA_ROOT=Join-Path $EvidenceRoot 'Lab_Data'
$resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
if (-not $resolution.Available) { throw 'SQL_UPGRADE_RUNTIME_TOOL_UNAVAILABLE' }
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$observed=@(& $module {
    param($Repo,$Provider,$OperationId,$StateRoot,$EvidenceRoot,$Cleanup)
    . (Join-Path $Repo 'Tests/Common/SqlVersionUpgradeScenario.ps1')
    if ($Cleanup) { Remove-SqlUpgradeOwnRuns -Provider $Provider -OperationId $OperationId -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot }
    else { Invoke-SqlUpgradeArrange -Provider $Provider -OperationId $OperationId -StateRoot $StateRoot -EvidenceRoot $EvidenceRoot }
} $repoRoot $Provider $OperationId $StateRoot $EvidenceRoot $CleanupOnly)
if (-not $CleanupOnly) {
    if ($observed.Count -ne 1 -or $observed[0].Status -cne 'VERIFIED' -or
        $observed[0].SourceMajor -ne 16 -or $observed[0].TargetMajor -ne 17 -or
        $observed[0].PreservedCompatibility -ne 160 -or $observed[0].ChangedCompatibility -ne 170) {
        throw 'SQL_UPGRADE_SQL_RECEIPT_INVALID'
    }
    $queryStore=$observed[0].QueryStore
    if (-not $queryStore -or $queryStore.Assessment -cne 'OBSERVED_ONLY_NO_PERFORMANCE_THRESHOLD' -or
        $queryStore.SourceBaseline.Status -cne 'OBSERVED' -or $queryStore.SourceBaseline.Marker -cne ($OperationId+'_SOURCE_COMPAT160') -or
        $queryStore.TargetCompatibility160.Status -cne 'OBSERVED' -or $queryStore.TargetCompatibility160.Marker -cne ($OperationId+'_TARGET_COMPAT160') -or
        $queryStore.TargetCompatibility170.Status -cne 'OBSERVED' -or $queryStore.TargetCompatibility170.Marker -cne ($OperationId+'_TARGET_COMPAT170')) {
        throw 'SQL_UPGRADE_SQL_RECEIPT_INVALID'
    }
    $receipt=[ordered]@{
        OperationId=$OperationId; Provider=$Provider; Status='VERIFIED'
        SourceMajor=16; TargetMajor=17; PreservedCompatibility=160; ChangedCompatibility=170
    }
    foreach ($field in @('SourceMilliseconds','RestoreMilliseconds','Compatibility160Milliseconds',
        'Compatibility170Milliseconds','SourceAfterMilliseconds')) {
        $value=[double]$observed[0].$field
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0) { throw 'SQL_UPGRADE_SQL_RECEIPT_INVALID' }
        $receipt[$field]=$value
    }
    $queryStoreReceipt=[ordered]@{Assessment='OBSERVED_ONLY_NO_PERFORMANCE_THRESHOLD';AverageDurationDeltaMicroseconds=$null;AverageDurationDeltaPercent=$null}
    foreach ($entry in @(
        @{Name='SourceBaseline';ExpectedMarker=($OperationId+'_SOURCE_COMPAT160')},
        @{Name='TargetCompatibility160';ExpectedMarker=($OperationId+'_TARGET_COMPAT160')},
        @{Name='TargetCompatibility170';ExpectedMarker=($OperationId+'_TARGET_COMPAT170')}
    )) {
        $sample=$queryStore.($entry.Name)
        $average=[double]$sample.AverageDurationMicroseconds
        if ($sample.Marker -cne $entry.ExpectedMarker -or $sample.QueryHash -cnotmatch '^[a-f0-9]{16,64}$' -or
            [long]$sample.ExecutionCount -lt 5 -or [int]$sample.PlanCount -lt 1 -or
            [double]::IsNaN($average) -or [double]::IsInfinity($average) -or $average -lt 0) { throw 'SQL_UPGRADE_SQL_RECEIPT_INVALID' }
        $queryStoreReceipt[$entry.Name]=[ordered]@{
            Status='OBSERVED';Marker=$entry.ExpectedMarker;QueryHash=[string]$sample.QueryHash
            ExecutionCount=[long]$sample.ExecutionCount;AverageDurationMicroseconds=$average;PlanCount=[int]$sample.PlanCount
        }
    }
    $delta=[double]$queryStore.AverageDurationDeltaMicroseconds
    if ([double]::IsNaN($delta) -or [double]::IsInfinity($delta)) { throw 'SQL_UPGRADE_SQL_RECEIPT_INVALID' }
    $queryStoreReceipt['AverageDurationDeltaMicroseconds']=$delta
    $percent=$queryStore.AverageDurationDeltaPercent
    if ($null -ne $percent) {
        $percent=[double]$percent
        if ([double]::IsNaN($percent) -or [double]::IsInfinity($percent)) { throw 'SQL_UPGRADE_SQL_RECEIPT_INVALID' }
    }
    $queryStoreReceipt['AverageDurationDeltaPercent']=$percent
    $receipt['QueryStore']=$queryStoreReceipt
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'sql-receipt.json')
}
