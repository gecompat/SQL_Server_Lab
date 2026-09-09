<#
.SYNOPSIS
    Prüft ein portables Container-Lab-Paket vor einem späteren Import.
.DESCRIPTION
    Liest ein pfad- und secretfreies SqlServerLab.PortableLabPackage/1.0 und
    prüft dessen Datenbankpaket-Referenzen gegen explizit bekannte Paket-IDs.
    Das Cmdlet erzeugt keinen Run, schreibt keine Dateien und führt keinen
    Import aus. Secret-Referenzen bleiben als Rebind-Blocker anonymisiert.
.PARAMETER PackagePath
    Pfad zu einem portablen Paketvertrag.
.PARAMETER TargetProvider
    Zielprovider für einen späteren Container-Import.
.PARAMETER AvailableDatabasePackageId
    Explizit verfügbare stabile Datenbankpaket-IDs für den Preflight.
.OUTPUTS
    SqlServerLab.PortableLabImportPlan/1.0. ExecutionImplemented ist immer false.
.EXAMPLE
    Get-SqlServerLabPortableLabImportPlan -PackagePath .\portable-lab.json -TargetProvider docker -AvailableDatabasePackageId $packageId
#>
function Get-SqlServerLabPortableLabImportPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})][string]$PackagePath,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$TargetProvider,
        [string[]]$AvailableDatabasePackageId=@()
    )
    try { $package=Get-Content -LiteralPath $PackagePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
    catch { throw "PORTABLE_LAB_PACKAGE_READ_FAILED: $($_.Exception.Message)" }
    Get-LabPortableLabImportPlan -Package $package -TargetProvider $TargetProvider -AvailableDatabasePackageId $AvailableDatabasePackageId
}