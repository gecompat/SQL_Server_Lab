<#
.SYNOPSIS
    Beschreibt die offiziellen Bezugsquellen fuer Lab-Medien.
.DESCRIPTION
    Die Quellenliste trennt absichtlich zwischen direkt beim Provisionieren
    ladbaren Testdatenbanken und Medien, die eine Herstellerseite oder einen
    Download-Bootstrapper erfordern. Dadurch wird eine Bootstrap-EXE nie als
    vermeintlich verwendbare ISO ausgegeben.
#>

function Get-LabMediaSourceCatalog {
    [CmdletBinding()]
    param([string]$MediaRoot, [string]$TestDataRoot)

    $root = $null
    if ($MediaRoot -and (Test-Path -LiteralPath $MediaRoot -PathType Container)) {
        $root = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    }

    $sources = @(
        [PSCustomObject]@{
            Id = 'windows-server-evaluation'; Category = 'Windows Server'; DisplayName = 'Windows Server 2025 Evaluation'
            Url = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025'
            Acquisition = 'MANUAL_PORTAL_SELECTION'; TargetRelativePath = 'WindowsServer/2025/Eval/ISO'
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'space' }
            Note = 'Im Evaluation Center ISO, 64-bit und Sprache auswählen. Für den ersten Windows-Builder wird English (United States) empfohlen.'
        }
        [PSCustomObject]@{
            Id = 'windows-server-2022-evaluation'; Category = 'Windows Server'; DisplayName = 'Windows Server 2022 Evaluation'
            Url = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022'
            Acquisition = 'MANUAL_PORTAL_SELECTION'; TargetRelativePath = 'WindowsServer/2022/Eval/ISO'
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'space' }
            Note = 'Im Evaluation Center ISO, 64-bit und Sprache auswählen. Die ISO mit Originaldateinamen in diesen Ordner ablegen.'
        }
        [PSCustomObject]@{
            Id = 'ubuntu-server'; Category = 'Linux'; DisplayName = 'Ubuntu Server'
            Url = 'https://ubuntu.com/download/server'
            Acquisition = 'MANUAL_PORTAL_SELECTION'; TargetRelativePath = 'Linux/ISO'
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'none' }
            Note = 'Linux-Medien erhalten standardmäßig keine synthetische Tastatureingabe beim ersten Boot.'
        }
        [PSCustomObject]@{
            Id = 'sql-server-downloads'; Category = 'SQL Server'; DisplayName = 'SQL Server Downloads'
            Url = 'https://www.microsoft.com/sql-server/sql-server-downloads'
            Acquisition = 'BOOTSTRAPPER_MANUAL_ISO'; TargetRelativePath = 'SQL/Installers/<Version> und SQL/<Version>/<Edition>/ISO'
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'none' }
            Note = 'Die kleine EXE ist nur ein Download-Bootstrapper. Sie lokal starten, „Download Media“ und „ISO“ wählen; erst die erzeugte ISO ist ein verwendbares Installationsmedium.'
        }
        [PSCustomObject]@{
            Id = 'windows-11-evaluation'; Category = 'Windows 11'; DisplayName = 'Windows 11 Enterprise Evaluation'
            Url = 'https://www.microsoft.com/evalcenter/evaluate-windows-11-enterprise'
            Acquisition = 'MANUAL_PORTAL_SELECTION'; TargetRelativePath = 'WindowsClient/11/Eval/ISO oder VHDX'
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'space' }
            Note = 'Evaluation-Medien sind zeitlich begrenzt (Microsoft nennt derzeit 90 Tage nach Aktivierung). Sie können als bewusst importierte Baseline dienen, sind aber keine automatisch freigegebene SQL-Prepared-Basis.'
        }
    )

    foreach ($source in $sources) {
        $target = if ($root) { Join-Path $root ($source.TargetRelativePath -replace '/', '\') } else { $null }
        $available = $false
        if ($target -and -not $target.Contains('<') -and (Test-Path -LiteralPath $target -PathType Container)) {
            $available = @(Get-ChildItem -LiteralPath $target -File -Force -ErrorAction SilentlyContinue).Count -gt 0
        }
        $source | Add-Member -NotePropertyName TargetPath -NotePropertyValue $target
        $source | Add-Member -NotePropertyName Available -NotePropertyValue $available
    }

    $catalogRoot = if ($script:CatalogsPath) {
        $script:CatalogsPath
    }
    else {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'Catalogs'
    }
    $sqlMediaCatalogPath = Join-Path $catalogRoot 'sql-server-media-sources.json'
    if (-not (Test-Path -LiteralPath $sqlMediaCatalogPath -PathType Leaf)) {
        throw "MEDIA_SOURCE_CATALOG_MISSING: $sqlMediaCatalogPath"
    }

    try {
        $sqlMediaCatalog = Get-Content -LiteralPath $sqlMediaCatalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    }
    catch {
        throw "MEDIA_SOURCE_CATALOG_INVALID: $($_.Exception.Message)"
    }

    $catalogIds = @($sqlMediaCatalog.entries | ForEach-Object { [string]$_.id })
    if (@($catalogIds | Sort-Object -Unique).Count -ne $catalogIds.Count) {
        throw 'MEDIA_SOURCE_CATALOG_INVALID: duplicate entry id'
    }

    foreach ($entry in @($sqlMediaCatalog.entries)) {
        $target = if ($root) { Join-Path $root ([string]$entry.targetRelativePath -replace '/', '\') } else { $null }
        $available = [bool]($target -and -not $target.Contains('<') -and (Test-Path -LiteralPath $target -PathType Leaf))
        $integrityStatus = if ($available) { 'PRESENT_UNVERIFIED' } else { 'MISSING' }
        if ($available -and $entry.expectedBytes -and (Get-Item -LiteralPath $target).Length -ne [long]$entry.expectedBytes) {
            $integrityStatus = 'SIZE_MISMATCH'
        }
        elseif ($available -and $entry.expectedSha256 -and $root) {
            $sidecarPath = Join-Path (Join-Path $root 'Hashes') (([string]$entry.targetRelativePath -replace '/', '\') + '.sha256')
            if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
                $sidecarHash = ((Get-Content -LiteralPath $sidecarPath -TotalCount 1 -Encoding ascii) -split '\s+')[0].ToLowerInvariant()
                $integrityStatus = if ($sidecarHash -eq ([string]$entry.expectedSha256).ToLowerInvariant()) {
                    'CATALOG_HASH_SIDECAR_MATCH'
                }
                else {
                    'HASH_SIDECAR_MISMATCH'
                }
            }
        }

        $effectiveUrl = if ($entry.downloadUrl) { [string]$entry.downloadUrl } else { [string]$entry.referenceUrl }
        $sources += [PSCustomObject]@{
            Id = [string]$entry.id
            Category = 'SQL Server'
            DisplayName = [string]$entry.displayName
            Url = $effectiveUrl
            DownloadUrl = if ($entry.downloadUrl) { [string]$entry.downloadUrl } else { $null }
            ReferenceUrl = if ($entry.referenceUrl) { [string]$entry.referenceUrl } else { $null }
            OriginalMicrosoftUrl = if ($entry.originalMicrosoftUrl) { [string]$entry.originalMicrosoftUrl } else { $null }
            Acquisition = [string]$entry.acquisition
            SourceStatus = [string]$entry.sourceStatus
            Version = [string]$entry.version
            Edition = [string]$entry.edition
            MediaKind = [string]$entry.mediaKind
            Architecture = if ($entry.architecture) { [string]$entry.architecture } else { $null }
            Language = if ($entry.language) { [string]$entry.language } else { $null }
            TargetRelativePath = [string]$entry.targetRelativePath
            TargetPath = $target
            Available = $available
            IntegrityStatus = $integrityStatus
            ExpectedBytes = if ($entry.expectedBytes) { [long]$entry.expectedBytes } else { $null }
            ExpectedSha256 = if ($entry.expectedSha256) { [string]$entry.expectedSha256 } else { $null }
            ExpectedSha1 = if ($entry.expectedSha1) { [string]$entry.expectedSha1 } else { $null }
            ProductVersion = if ($entry.productVersion) { [string]$entry.productVersion } else { $null }
            Automatable = [bool]$entry.automatable
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'none' }
            Note = [string]$entry.note
        }
    }

    foreach ($sample in @(Get-LabExecutableSampleVariant)) {
        $sources += [PSCustomObject]@{
            Id = "sample:$($sample.SampleId):$($sample.Variant)"; Category = 'Testdatenbank'; DisplayName = "$($sample.DisplayName) · $($sample.Variant)"
            Url = [string]$sample.Source; Acquisition = 'DOWNLOAD_ON_INSTALL'; TargetRelativePath = 'Testdaten-Bibliothek/Sammlungen/<Kategorie>/<Sample>/<Variante>'
            TargetPath = $TestDataRoot; Available = [bool]($TestDataRoot -and (Test-Path -LiteralPath $TestDataRoot -PathType Container))
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'none' }
            Note = if ($sample.ExpectedSha256) { 'Wird erst beim expliziten Anlegen geladen, gegen die Katalog-Prüfsumme verifiziert und sichtbar in der Testdaten-Bibliothek abgelegt.' } else { 'Wird erst beim expliziten Anlegen geladen. Vor dem ersten Download ist eine einmalige Vertrauensfreigabe erforderlich; danach liegt die verifizierte Datei sichtbar in der Testdaten-Bibliothek.' }
        }
    }
    return @($sources)
}
