#Requires -Version 7.2
<#
.SYNOPSIS
    Erstellt den zentralen persistenten Daten-Root fuer SQL_Server_Lab.
.DESCRIPTION
    Trennt langlebige Datenbank-Backups und versionsgebundene Datendateien von
    austauschbaren Evaluation-Images, Run-State und Git-Checkout. Das Skript
    ist idempotent und ueberschreibt keine abweichenden README-Dateien.
.PARAMETER RootPath
    Verpflichtender Root ausserhalb des Repository. Beispiel: D:\Lab_Data
.PARAMETER LabId
    Optionaler stabiler logischer Lab-Name. Erzeugt die zugehoerige
    versionsgetrennte Daten- und Backupstruktur.
.PARAMETER ShowHelp
    Zeigt diese Hilfeseite an.
.EXAMPLE
    .\Tools\Initialize-SqlServerLabDataRoot.ps1 -RootPath 'D:\Lab_Data' -LabId 'training'
.EXAMPLE
    .\Tools\Initialize-SqlServerLabDataRoot.ps1 -RootPath 'D:\Lab_Data' -LabId 'training' -ShowHelp
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('h', 'help', '?')][switch]$ShowHelp,
    [ValidateNotNullOrEmpty()][string]$RootPath,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$LabId,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ControllerId,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$helpTokens = @('/?', '-?', '-h', '--help', '-help')
$showHelpRequested = $ShowHelp.IsPresent -or
    @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or
    @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help' -or
    # Hilfemodus kann auch als Positionsargument in RootPath landen.
    ($null -ne $RootPath -and $RootPath -in $helpTokens)

function Show-Usage {
param(
    [string]$ScriptName = 'Initialize-SqlServerLabDataRoot.ps1'
)
    Write-Host "$ScriptName" -ForegroundColor Cyan
    Write-Host 'Funktion:' -ForegroundColor Magenta
    Write-Host '  Erstellt und validiert den persistenten Daten-Root fuer SQL_Server_Lab.' -ForegroundColor Cyan
    Write-Host '  Trennung von Daten, Backups und Git-Checkout.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Aufruf:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName -RootPath <Pfad> [-LabId <Name>] [-ShowHelp]" -ForegroundColor Cyan
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameter:' -ForegroundColor Magenta
    Write-Host '  -RootPath <string>    Pfad fuer den Daten-Root (ausserehalb des Repos).' -ForegroundColor Cyan
    Write-Host '  -LabId <string>       Optionaler stabiler Lab-Name fuer versionierte Unterverzeichnisse.' -ForegroundColor Cyan
    Write-Host '  -ShowHelp             Zeigt diese Hilfe.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Beispiele:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName -RootPath 'D:\\Lab_Data'" -ForegroundColor Cyan
    Write-Host '  -> Legt den Basispfad fuer langlebige Daten an.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -RootPath 'D:\\Lab_Data' -LabId 'training'" -ForegroundColor Cyan
    Write-Host '  -> Erstellt strukturierte Unterordner fuer ein stabil benanntes Lab.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
}

if ($showHelpRequested) {
    Show-Usage -ScriptName (Split-Path -Leaf $PSCommandPath)
    return
}

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    throw 'Parameter RootPath ist erforderlich. Beispiel: .\Tools\Initialize-SqlServerLabDataRoot.ps1 -RootPath D:\Lab_Data'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-DataPathWithin {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ParentPath)
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
    return $candidate.Equals($parent, $comparison) -or
        $candidate.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Add-DataRootReadme {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $body = "<!-- SQL_SERVER_LAB_DATA_ROOT_README v1 -->`n`n$($Content.Trim())`n"
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ((Get-Content -LiteralPath $Path -Raw -Encoding utf8) -ne $body) {
            $script:skippedReadmes.Add($Path)
        }
        return
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Daten-Root-README erstellen')) {
        Set-Content -LiteralPath $Path -Value $body -Encoding utf8NoBOM -NoNewline
        $script:createdReadmes.Add($Path)
    }
}

$dataRoot = [System.IO.Path]::GetFullPath($RootPath)
$dataRoot = $dataRoot.TrimEnd('\', '/')
if (-not [string]::Equals((Split-Path -Leaf $dataRoot), 'Lab_Data', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'LAB_DATA_ROOT_NAME_REQUIRED: RootPath muss auf einen Ordner namens Lab_Data zeigen.'
}
$volumeRoot = [System.IO.Path]::GetPathRoot($dataRoot)
if ($dataRoot.TrimEnd('\', '/') -eq $volumeRoot.TrimEnd('\', '/')) {
    throw 'DATA_ROOT_TOO_BROAD: Ein Laufwerks- oder Dateisystemroot ist nicht zulaessig.'
}
$volumeId = $volumeRoot
if ($IsWindows -and $volumeRoot -match '^[A-Za-z]:' -and (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
    try {
        $volume = Get-Volume -DriveLetter $volumeRoot.Substring(0, 1) -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$volume.UniqueId)) {
            $volumeId = [string]$volume.UniqueId
        }
    }
    catch { $volumeId = $volumeRoot }
}
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (Test-DataPathWithin -Path $dataRoot -ParentPath $repositoryRoot) {
    throw 'DATA_ROOT_INSIDE_REPOSITORY: Daten muessen ausserhalb des Git-Checkouts liegen.'
}

$relativeDirectories = @('Backups/Incoming', 'Backups/Verified', 'Labs', 'Catalog', 'Exports', 'State', 'Temp')
if ($LabId) {
    $relativeDirectories += @(
        "Labs/$LabId/Backups/Full", "Labs/$LabId/Backups/Differential", "Labs/$LabId/Backups/Log",
        "Labs/$LabId/Manifests", "Labs/$LabId/Transfer"
    )
    foreach ($version in @('2019', '2022', '2025')) {
        $relativeDirectories += @(
            "Labs/$LabId/Versions/$version/Data",
            "Labs/$LabId/Versions/$version/Log",
            "Labs/$LabId/Versions/$version/TempDb"
        )
    }
}

$createdDirectories = [System.Collections.Generic.List[string]]::new()
$createdReadmes = [System.Collections.Generic.List[string]]::new()
$skippedReadmes = [System.Collections.Generic.List[string]]::new()
foreach ($path in @($dataRoot) + @($relativeDirectories | ForEach-Object { Join-Path $dataRoot $_ })) {
    if (-not (Test-Path -LiteralPath $path -PathType Container) -and $PSCmdlet.ShouldProcess($path, 'Verzeichnis erstellen')) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        $createdDirectories.Add($path)
    }
}

$markerPath = Join-Path $dataRoot '.sql-server-lab-root.json'
$existingMarker = $null
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    $existingMarker = Get-Content -LiteralPath $markerPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
    if ([string]$existingMarker.ManagedBy -ne 'SQL_Server_Lab') { throw 'LAB_DATA_ROOT_FOREIGN_OWNER' }
    if ($ControllerId -and [string]$existingMarker.ControllerId -ne $ControllerId) { throw 'LAB_DATA_ROOT_CONTROLLER_MISMATCH' }
    $ControllerId = [string]$existingMarker.ControllerId
}
if (-not $ControllerId) { $ControllerId = [Guid]::NewGuid().ToString('D') }
$marker = [PSCustomObject]@{
    ContractVersion = 'SqlServerLab.DataRoot/2.0'
    ManagedBy = 'SQL_Server_Lab'
    ControllerId = $ControllerId
    VolumeId = $volumeId
    CreatedAt = if ($existingMarker -and $existingMarker.CreatedAt) { [string]$existingMarker.CreatedAt } else { (Get-Date).ToUniversalTime().ToString('o') }
    DataRoot = $dataRoot
}
if ($PSCmdlet.ShouldProcess($markerPath, 'Data-Root-Marker schreiben')) {
    $marker | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $markerPath -Encoding utf8NoBOM
}

$rootReadme = @"
# SQL_Server_Lab Data Root

Dieser Ordner enthaelt langlebige Daten ausserhalb von Git, Run-State und austauschbaren Evaluation-Images.

Konfigurierter Root: ``$dataRoot``

- ``Backups\Verified``: gepruefte, instanzunabhaengige SQL-Backups.
- ``Labs\<LabId>\Backups``: Full-, Differential- und Log-Backups pro logischem Lab.
- ``Labs\<LabId>\Versions\<Version>``: versionsgebundene Data-, Log- und TempDb-Dateien.
- ``Transfer``: kontrollierte Uebergabe beim Neuaufbau.
- ``Catalog``: kuenftige maschinenlesbare Backup-Receipts; keine Secrets.

## Evaluation und Neuaufbau

Evaluation-OS und Evaluation-SQL duerfen ablaufen. Vor dem Ablauf wird ein verifiziertes Full-Backup erzeugt. Danach wird die austauschbare VM aus aktuellen Medien neu aufgebaut und das Backup in dieselbe oder eine neuere SQL-Hauptversion restauriert.

MDF/LDF-Dateien werden nicht als versionsneutrale Sicherung behandelt. Nach einem Upgrade auf eine neuere SQL-Version ist ein Downgrade durch Attach oder Restore nicht unterstuetzt. Fuer jede SQL-Hauptversion existiert deshalb ein getrennter Dateibereich; ``Backups`` ist die kanonische Uebergabeebene.

Kennwoerter, PATs, Zertifikat-Private-Keys und Lizenzschluessel gehoeren nicht in diesen Root.
"@
Add-DataRootReadme -Path (Join-Path $dataRoot 'README.md') -Content $rootReadme

if ($LabId) {
    $labReadme = @"
# Lab $LabId

Stabile logische Identitaet: ``$LabId``

1. Vor einem Image-Refresh Full-Backup nach ``Backups\Full`` schreiben.
2. Backup mit ``RESTORE VERIFYONLY`` und SHA-256 pruefen.
3. Neue Evaluation-VM aus einem gueltigen Image erstellen.
4. In dieselbe oder eine neuere SQL-Version restaurieren.
5. Anwendungstest ausfuehren; alte VM erst danach entfernen.

``Versions`` enthaelt bewusst getrennte Dateibereiche fuer SQL Server 2019, 2022 und 2025. ``TempDb`` ist fluechtig und wird nicht migriert.
"@
    Add-DataRootReadme -Path (Join-Path $dataRoot "Labs/$LabId/README.md") -Content $labReadme
}

[PSCustomObject]@{
    ContractVersion = 'SqlServerLab.DataRoot/2.0'
    ControllerId = $ControllerId
    MarkerPath = $markerPath
    DataRoot = $dataRoot
    LabId = if ($LabId) { $LabId } else { $null }
    CreatedDirectories = @($createdDirectories)
    CreatedReadmeFiles = @($createdReadmes)
    SkippedReadmeFiles = @($skippedReadmes)
    RebuildModel = 'verified-backup-restore'
}
