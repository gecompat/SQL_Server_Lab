<#
.SYNOPSIS
    Prüft Backup-Referenzen eines portablen Container-Lab-Pakets für einen bestehenden Ziel-Run.
.DESCRIPTION
    Liest ein pfad- und secretfreies SqlServerLab.PortableLabPackage/1.1. Der
    Preflight bindet ausschließlich stabile BackupSetId-Referenzen samt
    CHECKSUM-, VERIFYONLY-, SHA-256- und Größen-Evidence an einen bereits
    vorhandenen Docker- oder Podman-Ziel-Run. Das Cmdlet erzeugt keinen Run,
    schreibt keine Dateien, liest keine Credentials und führt keinen Transfer
    oder Import aus.
.PARAMETER PackagePath
    Pfad zu einem portablen Paketvertrag.
.PARAMETER TargetProvider
    Zielprovider für einen späteren Container-Import.
.PARAMETER TargetRunId
    Stabile ID des bereits vorhandenen verwalteten Container-Ziel-Runs.
.PARAMETER StateRoot
    Optionaler lokaler State-Root, aus dem der Ziel-Run read-only gelesen wird.
.OUTPUTS
    SqlServerLab.PortableContainerTransferPlan/1.0. ExecutionImplemented ist immer false.
.EXAMPLE
    Get-SqlServerLabPortableLabImportPlan -PackagePath .\portable-lab.json -TargetProvider docker -TargetRunId $runId
#>
function Get-SqlServerLabPortableLabImportPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})][string]$PackagePath,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$TargetProvider,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetRunId,
        [string]$StateRoot
    )
    try { $package=Get-Content -LiteralPath $PackagePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
    catch { throw "PORTABLE_LAB_PACKAGE_READ_FAILED: $($_.Exception.Message)" }
    Get-LabPortableLabImportPlan -Package $package -TargetProvider $TargetProvider -TargetRunId $TargetRunId -StateRoot $StateRoot
}
