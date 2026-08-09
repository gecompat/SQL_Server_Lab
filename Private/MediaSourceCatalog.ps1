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
            Id = 'windows-server-evaluation'; Category = 'Windows Server'; DisplayName = 'Windows Server Evaluation'
            Url = 'https://www.microsoft.com/evalcenter/evaluate-windows-server'
            Acquisition = 'MANUAL_PORTAL_SELECTION'; TargetRelativePath = 'WindowsServer/<Version>/Eval/ISO (empfohlen; freie Unterordner sind zulässig)'
            BootInteraction = [PSCustomObject]@{ InitialMediaKey = 'space' }
            Note = 'Im Evaluation Center ISO, Version und Sprache auswählen. Die Erkennung ist nicht an WindowsServer gebunden und bietet die ISO unabhängig vom Unterordner automatisch an.'
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
