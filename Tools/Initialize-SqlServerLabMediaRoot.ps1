#Requires -Version 7.2
<#
.SYNOPSIS
    Erstellt und pflegt den externen Media Root fuer SQL_Server_Lab.
.DESCRIPTION
    Erstellt eine versionierte, aber nicht im Git-Checkout liegende
    Verzeichnisstruktur fuer Betriebssystem-, SQL-Server- und VHDX-Medien.
    Vorhandene Medien koennen optional anhand ihres Pfads und Dateinamens
    einsortiert werden. Bestehende Zieldateien werden nie ueberschrieben.

    Fuer die angelegten Medienordner werden lokale README.md-Dateien mit
    offiziellen Downloadquellen, Zielpfaden und Verwendungshinweisen erzeugt.
    Bestehende abweichende README-Dateien werden nicht ueberschrieben.

    Optional werden SHA-256-Sidecars unterhalb von Hashes erzeugt. Das Skript
    kopiert keine Medien in das Repository und akzeptiert den Repository-Root
    oder einen Unterordner davon nicht als Media Root.
.PARAMETER RootPath
    Verpflichtender externer Root. Beispiel: D:\Lab_Base
.PARAMETER OrganizeExisting
    Sortiert bekannte, bereits vorhandene ISO-, VHDX- und SQL-Installer-Dateien
    in die kanonische Struktur ein.
.PARAMETER GenerateSha256
    Erzeugt fuer alle Medien SHA-256-Sidecars unterhalb von Hashes. Bereits
    vorhandene abweichende Sidecars brechen ab und werden nicht ueberschrieben.
.PARAMETER ShowHelp
    Zeigt diese Hilfeseite an.
.EXAMPLE
    .\Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath 'D:\Lab_Base'
.EXAMPLE
    .\Tools\Initialize-SqlServerLabMediaRoot.ps1 `
        -RootPath 'D:\Lab_Base' `
        -OrganizeExisting `
        -WhatIf
.EXAMPLE
    .\Tools\Initialize-SqlServerLabMediaRoot.ps1 `
        -RootPath 'D:\Lab_Base' `
        -OrganizeExisting `
        -GenerateSha256
.EXAMPLE
    .\Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath 'D:\Lab_Base' -ShowHelp
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('h', 'help', '?')][switch]$ShowHelp,
    [ValidateNotNullOrEmpty()]
    [string]$RootPath,
 
    [switch]$OrganizeExisting,
 
    [switch]$GenerateSha256,
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
    [string]$ScriptName = 'Initialize-SqlServerLabMediaRoot.ps1'
)
    Write-Host "$ScriptName" -ForegroundColor Cyan
    Write-Host 'Funktion:' -ForegroundColor Magenta
    Write-Host '  Erstellt und pflegt den externen Media Root fuer SQL_Server_Lab.' -ForegroundColor Cyan
    Write-Host '  Erzeugt READMEs, optional bestehende Medien zuordnen und Sidecars erstellen.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Aufruf:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName -RootPath <Pfad> [-OrganizeExisting] [-GenerateSha256] [-ShowHelp]" -ForegroundColor Cyan
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameter:' -ForegroundColor Magenta
    Write-Host '  -RootPath <string>     Externer Root-Ordner fuer ISO/VHDX/Installer.' -ForegroundColor Cyan
    Write-Host '  -OrganizeExisting      Vorhandene Medien automatisch einsortieren.' -ForegroundColor Cyan
    Write-Host '  -GenerateSha256        SHA-256-Sidecars fuer Medien erzeugen.' -ForegroundColor Cyan
    Write-Host '  -ShowHelp              Zeigt diese Hilfe.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Beispiele:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName -RootPath 'D:\\Lab_Media'" -ForegroundColor Cyan
    Write-Host '  -> Richtet die Standard-Media-Struktur ein.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -RootPath 'D:\\Lab_Media' -OrganizeExisting" -ForegroundColor Cyan
    Write-Host '  -> Sortiert vorhandene Dateien in die Zielstruktur ein.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -RootPath 'D:\\Lab_Media' -GenerateSha256" -ForegroundColor Cyan
    Write-Host '  -> Erzeugt SHA-256-Dateien unterhalb von Hashes.' -ForegroundColor Green
}

if ($showHelpRequested) {
    Show-Usage -ScriptName (Split-Path -Leaf $PSCommandPath)
    return
}

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    throw 'Parameter RootPath ist erforderlich. Beispiel: .\Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath D:\Lab_Media'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-MediaPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ParentPath
    )

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedParent = [System.IO.Path]::GetFullPath($ParentPath)
    $parentWithSeparator = $resolvedParent.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    return $resolvedPath.Equals($resolvedParent, $comparison) -or
        $resolvedPath.StartsWith($parentWithSeparator, $comparison)
}

function Add-MediaMovePlan {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    $source = [System.IO.Path]::GetFullPath($SourcePath)
    $destination = Join-Path $DestinationDirectory (Split-Path -Leaf $source)
    if ($source -eq [System.IO.Path]::GetFullPath($destination)) {
        return
    }

    $script:movePlans.Add([PSCustomObject]@{
        Source      = $source
        Destination = [System.IO.Path]::GetFullPath($destination)
    })
}

function Add-MediaReadmeDefinition {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Content
    )

    $script:readmeDefinitions.Add([PSCustomObject]@{
        RelativePath = $RelativePath
        Content      = "<!-- SQL_SERVER_LAB_MEDIA_ROOT_README v1 -->`n`n$($Content.Trim())`n"
    })
}

$mediaRoot = [System.IO.Path]::GetFullPath($RootPath)
$volumeRoot = [System.IO.Path]::GetPathRoot($mediaRoot)
if ($mediaRoot.TrimEnd('\', '/') -eq $volumeRoot.TrimEnd('\', '/')) {
    throw 'MEDIA_ROOT_TOO_BROAD: Ein Laufwerks- oder Dateisystemroot ist nicht zulaessig.'
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (Test-MediaPathWithin -Path $mediaRoot -ParentPath $repositoryRoot) {
    throw 'MEDIA_ROOT_INSIDE_REPOSITORY: Medien muessen ausserhalb des Git-Checkouts liegen.'
}

$relativeDirectories = @(
    'Incoming',
    'Linux/ISO',
    'Linux/VHDX',
    'SQL/Installers/2019',
    'SQL/Installers/2022',
    'SQL/Installers/2025',
    'SQL/2019/Eval/ISO',
    'SQL/2022/Eval/ISO',
    'SQL/2025/Eval/ISO',
    'SQL/2025/Enterprise/ISO',
    'SQL/2025/Standard/ISO',
    'WindowsServer/2022/Eval/ISO',
    'WindowsServer/2022/Eval/VHDX',
    'WindowsServer/2025/Eval/ISO',
    'WindowsServer/2025/Eval/VHDX',
    'WindowsClient/11/Eval/ISO',
    'Testdaten',
    'Hashes',
    'Evidence',
    'Exports'
)

$createdDirectories = [System.Collections.Generic.List[string]]::new()
$movedFiles = [System.Collections.Generic.List[string]]::new()
$hashFiles = [System.Collections.Generic.List[string]]::new()
$createdReadmeFiles = [System.Collections.Generic.List[string]]::new()
$skippedReadmeFiles = [System.Collections.Generic.List[string]]::new()

foreach ($path in @($mediaRoot) + @($relativeDirectories | ForEach-Object { Join-Path $mediaRoot $_ })) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($path, 'Verzeichnis erstellen')) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
            $createdDirectories.Add($path)
        }
    }
}

$readmeDefinitions = [System.Collections.Generic.List[object]]::new()

$rootReadme = @'
# SQL_Server_Lab Media Root

Dieser Ordner ist der lokale, nicht versionierte Media Root für SQL_Server_Lab.

## Schnellstart

1. Öffne das README im gewünschten Zielordner.
2. Lade ausschließlich von der dort verlinkten offiziellen Herstellerseite.
3. Behalte den Originaldateinamen bei und speichere die Datei direkt im beschriebenen Ordner.
4. Erzeuge nach dem Download optional SHA-256-Sidecars mit dem Initialisierer.

Konfigurierter Root: `{{ROOT_PATH}}`

## Navigation

- `Linux\ISO` – Ubuntu-Server-Installationsmedien.
- `Linux\VHDX` – vorbereitete Linux-Basisdatenträger; derzeit kein automatischer Buildpfad.
- `SQL\Installers\<Version>` – kleine Microsoft-Bootstrap-Installer.
- `SQL\<Version>\<Edition>\ISO` – vollständige SQL-Server-Installationsmedien.
- `WindowsServer\<Version>\Eval\ISO` – Windows-Server-Installationsmedien.
- `WindowsServer\<Version>\Eval\VHDX` – von Microsoft gelieferte oder vorbereitete virtuelle Datenträger.
- `WindowsClient\11\Eval\ISO` – Windows-11-Evaluation-Installationsmedien; die automatische Erkennung akzeptiert auch andere Unterordner.
- `Testdaten` – sichtbare, wiederverwendbare Bibliothek für verifizierte Testdatenbanken, Archive und T-SQL-Skripte.
- `Incoming` – noch nicht klassifizierte Medien.
- `Hashes` – automatisch erzeugte SHA-256-Sidecars.
- `Evidence` – lokale Build- und Generalisierungsnachweise.
- `Exports` – bewusst erzeugte lokale Übergabeartefakte.

Große Medien, Lizenzschlüssel und Zugangsdaten gehören nicht in Git.
'@.Replace('{{ROOT_PATH}}', $mediaRoot)
Add-MediaReadmeDefinition -RelativePath 'README.md' -Content $rootReadme

Add-MediaReadmeDefinition -RelativePath 'Incoming/README.md' -Content @'
# Incoming

Hier dürfen noch nicht klassifizierte ISO-, VHD- und VHDX-Dateien vorübergehend abgelegt werden.

Anschließend aus dem Repository ausführen:

```powershell
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath '<MediaRoot>' -OrganizeExisting -WhatIf
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath '<MediaRoot>' -OrganizeExisting
```

Unbekannte Root-Medien werden nicht geraten, sondern hier gesammelt. Prüfe Dateiname, Herkunft, Edition und Lizenz vor einer manuellen Zuordnung.
'@

Add-MediaReadmeDefinition -RelativePath 'Testdaten/README.md' -Content @'
# SQL_Server_Lab Testdaten-Bibliothek

Dieser Ordner enthält wiederverwendbare, lokal verifizierte Testdaten-Artefakte.
Sie werden erst beim bewussten Installieren einer Testdatenbank heruntergeladen.

- `Sammlungen\<Kategorie>\<Sample>\<Variante>` enthält die sichtbar abgelegten Backups, ZIP-/7z-Archive und T-SQL-Skripte sowie deren `artifact.json`.
- `_verified` ist der technische SHA-256-Speicher. Dateien in `Sammlungen` verweisen darauf oder werden bei Bedarf kopiert.
- Die jeweilige `artifact.json` dokumentiert Quelle, SHA-256, Art des Artefakts und Zeitpunkt der Übernahme.

Lösche Artefakte nicht während eine Installation läuft. Eine manuell hinzugefügte Datei wird erst nach einem passenden Katalogeintrag und einer SHA-256-Prüfung automatisch verwendet.
'@

Add-MediaReadmeDefinition -RelativePath 'Linux/ISO/README.md' -Content @'
# Ubuntu Server ISO

Offizieller Download: [Ubuntu Server](https://ubuntu.com/download/server)

Für die aktuelle Referenzumgebung dieses Repository wird Ubuntu Server 24.04 LTS für AMD64 verwendet. Neuere LTS-Versionen können zusätzlich abgelegt werden, benötigen aber einen eigenen Kompatibilitätsnachweis.

1. Auf der offiziellen Seite die gewünschte Ubuntu-Server-LTS-Version und Intel/AMD 64-bit wählen.
2. Die Datei mit unverändertem Namen direkt in diesen Ordner speichern.
3. Optional den SHA-256-Nachweis über den Media-Root-Initialisierer erzeugen.

Diese ISO dient derzeit zur manuellen Installation eines Linux-Hosts oder Self-hosted Runners. Der Hyper-V-Image-Builder erzeugt daraus noch keine Linux-Baseline.
'@

Add-MediaReadmeDefinition -RelativePath 'Linux/VHDX/README.md' -Content @'
# Linux VHDX

Hier liegen ausschließlich bewusst vorbereitete Linux-VHDX-Baselines. Eine Ubuntu-ISO gehört stattdessen nach `Linux\ISO`.

Ubuntu stellt Images über die [offizielle Cloud-Image-Seite](https://cloud-images.ubuntu.com/) bereit. Übernimm jedoch kein Image ungeprüft: Für dieses Repository existiert derzeit weder ein freigegebener automatischer Linux-VHDX-Import noch ein Linux-Hyper-V-Image-Build.

Vor einer späteren Registrierung müssen Herkunft, SHA-256, Generalisierungszustand, Hyper-V-Kompatibilität und Metadaten explizit nachgewiesen werden.
'@

$sqlSources = @(
    [PSCustomObject]@{
        Version = '2019'
        Link = 'https://www.microsoft.com/en-us/evalcenter/download-sql-server-2019'
        SourceLabel = 'Microsoft Evaluation Center – SQL Server 2019'
        Editions = @('Eval')
    },
    [PSCustomObject]@{
        Version = '2022'
        Link = 'https://www.microsoft.com/en-us/evalcenter/download-sql-server-2022'
        SourceLabel = 'Microsoft Evaluation Center – SQL Server 2022'
        Editions = @('Eval')
    },
    [PSCustomObject]@{
        Version = '2025'
        Link = 'https://www.microsoft.com/en-us/sql-server/sql-server-downloads'
        SourceLabel = 'Microsoft SQL Server Downloads'
        Editions = @('Eval', 'Enterprise', 'Standard')
    }
)

foreach ($source in $sqlSources) {
    $installerTemplate = @'
# SQL Server {{VERSION}} Bootstrap-Installer

Offizielle Quelle: [{{SOURCE_LABEL}}]({{LINK}})

1. Den 64-bit-EXE-Download von Microsoft wählen.
2. Die Bootstrap-EXE mit unverändertem Namen in diesen Ordner speichern.
3. Für ein vollständiges Offline-Medium die EXE auf einem Windows-Host starten und **Download Media** sowie **ISO** wählen.
4. Die erzeugte ISO anschließend unter `SQL\{{VERSION}}\<Edition>\ISO` ablegen.

Die Evaluation- und Developer-Ausgaben sind nur gemäß den Microsoft-Lizenzbedingungen zu verwenden. Keine Lizenzschlüssel oder Registrierungsdaten in diesem Ordner speichern.
'@
    $installerContent = $installerTemplate.
        Replace('{{VERSION}}', $source.Version).
        Replace('{{SOURCE_LABEL}}', $source.SourceLabel).
        Replace('{{LINK}}', $source.Link)
    Add-MediaReadmeDefinition -RelativePath "SQL/Installers/$($source.Version)/README.md" -Content $installerContent

    foreach ($edition in $source.Editions) {
        $editionLink = $source.Link
        $editionLabel = $source.SourceLabel
        if ($source.Version -eq '2025' -and $edition -eq 'Eval') {
            $editionLink = 'https://www.microsoft.com/en-us/evalcenter/sql-server-2025-download'
            $editionLabel = 'Microsoft Evaluation Center – SQL Server 2025'
        }

        $isoTemplate = @'
# SQL Server {{VERSION}} {{EDITION}} ISO

Offizielle Quelle: [{{SOURCE_LABEL}}]({{LINK}})

1. Den offiziellen 64-bit-Bootstrap-Installer laden und starten.
2. **Download Media** und danach **ISO** auswählen.
3. Sprache und Edition prüfen; für reproduzierbare Lab-Builds den Originaldateinamen beibehalten.
4. Die fertige ISO direkt in diesen Ordner speichern.
5. Optional mit `-GenerateSha256` ein Sidecar unter `Hashes` erzeugen.

Dieses Medium wird lokal bereitgehalten. Der öffentliche Hyper-V-Pfad installiert SQL Server derzeit noch nicht automatisch. Evaluation- und Developer-Medien dürfen nur im Rahmen ihrer Microsoft-Lizenzbedingungen verwendet werden.
'@
        $isoContent = $isoTemplate.
            Replace('{{VERSION}}', $source.Version).
            Replace('{{EDITION}}', $edition).
            Replace('{{SOURCE_LABEL}}', $editionLabel).
            Replace('{{LINK}}', $editionLink)
        Add-MediaReadmeDefinition -RelativePath "SQL/$($source.Version)/$edition/ISO/README.md" -Content $isoContent
    }
}

$windowsSources = @(
    [PSCustomObject]@{
        Version = '2022'
        Link = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022'
    },
    [PSCustomObject]@{
        Version = '2025'
        Link = 'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025'
    }
)

foreach ($source in $windowsSources) {
    $isoTemplate = @'
# Windows Server {{VERSION}} Evaluation ISO

Offizieller Download: [Microsoft Evaluation Center – Windows Server {{VERSION}}]({{LINK}})

1. Registrierungsangaben auf der Microsoft-Seite ausfüllen.
2. **ISO**, **64-bit** und für den Referenzpfad **English (United States)** wählen.
3. Die ISO mit Originaldateinamen direkt in diesen Ordner speichern.
4. Optional mit `-GenerateSha256` einen lokalen SHA-256-Nachweis erzeugen.

Für den einfacheren ersten Diagnose-Build wird im Windows-Setup die Evaluation-Ausgabe mit Desktop Experience bevorzugt. Evaluationen sind zeitlich begrenzt und müssen gemäß Microsoft-Hinweisen aktiviert und aktualisiert werden.
'@
    $isoContent = $isoTemplate.
        Replace('{{VERSION}}', $source.Version).
        Replace('{{LINK}}', $source.Link)
    Add-MediaReadmeDefinition -RelativePath "WindowsServer/$($source.Version)/Eval/ISO/README.md" -Content $isoContent

    $vhdxTemplate = @'
# Windows Server {{VERSION}} Evaluation VHDX

Offizieller Download: [Microsoft Evaluation Center – Windows Server {{VERSION}}]({{LINK}})

1. Auf der Microsoft-Seite **VHD** beziehungsweise das angebotene virtuelle Festplattenformat wählen.
2. Archiv gegebenenfalls lokal entpacken und die VHD/VHDX mit Originaldateinamen hier ablegen.
3. Herkunft und SHA-256 dokumentieren.

Eine heruntergeladene Evaluation-VHDX ist nicht automatisch eine freigegebene SQL_Server_Lab-Baseline. Vor dem Registry-Import sind Read-only-Status, Generalisierung, SHA-256, Hyper-V-Startfähigkeit und Metadaten nachzuweisen. Der aktuelle Windows-Image-Builder verwendet für Neubauten eine ISO.
'@
    $vhdxContent = $vhdxTemplate.
        Replace('{{VERSION}}', $source.Version).
        Replace('{{LINK}}', $source.Link)
    Add-MediaReadmeDefinition -RelativePath "WindowsServer/$($source.Version)/Eval/VHDX/README.md" -Content $vhdxContent
}

Add-MediaReadmeDefinition -RelativePath 'Hashes/README.md' -Content @'
# Hashes

Dieser Ordner wird automatisch mit SHA-256-Sidecars befüllt. Die relative Medienstruktur wird gespiegelt.

```powershell
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath '<MediaRoot>' -GenerateSha256
```

Sidecars nicht manuell an andere Medien anpassen. Ein abweichender vorhandener Hash führt absichtlich zu `MEDIA_HASH_CONFLICT`.
'@

Add-MediaReadmeDefinition -RelativePath 'Evidence/README.md' -Content @'
# Evidence

Hier liegen lokale, ausdrücklich erzeugte Build-, Generalisierungs- und Prüfnachweise. Keine Passwörter, Tokens, Lizenzschlüssel oder unbereinigten Logs speichern.

Evidence ersetzt nicht die vom Image-Builder und von der Registry verlangten typisierten Nachweise. Inhalte dieses Ordners gehören nicht in Git.
'@

Add-MediaReadmeDefinition -RelativePath 'Exports/README.md' -Content @'
# Exports

Dieser Ordner ist für bewusst erzeugte lokale Übergabeartefakte vorgesehen, zum Beispiel bereinigte Build-Receipts oder exportierte Baselines.

Vor jeder Weitergabe Lizenz, Geheimnisse, personenbezogene Daten, Hostpfade und interne Netzwerkangaben prüfen. Inhalte werden nicht automatisch veröffentlicht oder in Git übernommen.
'@

foreach ($definition in $readmeDefinitions) {
    $readmePath = Join-Path $mediaRoot $definition.RelativePath
    if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
        $existingContent = (Get-Content -LiteralPath $readmePath -Raw -Encoding utf8) -replace "`r`n", "`n"
        $desiredContent = $definition.Content -replace "`r`n", "`n"
        if ($existingContent.TrimEnd() -ne $desiredContent.TrimEnd()) {
            $skippedReadmeFiles.Add($readmePath)
            Write-Warning "MEDIA_README_EXISTS: Bestehende abweichende Datei bleibt unveraendert: $readmePath"
        }
        continue
    }

    if ($PSCmdlet.ShouldProcess($readmePath, 'Download-README schreiben')) {
        Set-Content -LiteralPath $readmePath -Value $definition.Content.TrimEnd() -Encoding utf8NoBOM
        $createdReadmeFiles.Add($readmePath)
    }
}

$movePlans = [System.Collections.Generic.List[object]]::new()
if ($OrganizeExisting -and (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $mediaRoot -File -Force)) {
        if ($file.Name -match '(?i)^SQL(2019|2022|2025)-.*\.exe$') {
            Add-MediaMovePlan -SourcePath $file.FullName -DestinationDirectory (Join-Path $mediaRoot "SQL/Installers/$($Matches[1])")
        }
        elseif ($file.Extension -in @('.iso', '.vhd', '.vhdx')) {
            Add-MediaMovePlan -SourcePath $file.FullName -DestinationDirectory (Join-Path $mediaRoot 'Incoming')
        }
    }

    $linuxRoot = Join-Path $mediaRoot 'Linux'
    foreach ($file in @(Get-ChildItem -LiteralPath $linuxRoot -File -Force -ErrorAction SilentlyContinue)) {
        $targetKind = if ($file.Extension -eq '.iso') { 'ISO' } elseif ($file.Extension -in @('.vhd', '.vhdx')) { 'VHDX' } else { $null }
        if ($targetKind) {
            Add-MediaMovePlan -SourcePath $file.FullName -DestinationDirectory (Join-Path $linuxRoot $targetKind)
        }
    }

    $sqlRoot = Join-Path $mediaRoot 'SQL'
    foreach ($file in @(Get-ChildItem -LiteralPath $sqlRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $parentLeaf = Split-Path -Leaf $file.DirectoryName
        if ($file.Extension -eq '.iso' -and $parentLeaf -ne 'ISO') {
            Add-MediaMovePlan -SourcePath $file.FullName -DestinationDirectory (Join-Path $file.DirectoryName 'ISO')
        }
    }

    $windowsRoot = Join-Path $mediaRoot 'WindowsServer'
    foreach ($file in @(Get-ChildItem -LiteralPath $windowsRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $parentLeaf = Split-Path -Leaf $file.DirectoryName
        $targetKind = if ($file.Extension -eq '.iso') { 'ISO' } elseif ($file.Extension -in @('.vhd', '.vhdx')) { 'VHDX' } else { $null }
        if ($targetKind -and $parentLeaf -ne $targetKind) {
            Add-MediaMovePlan -SourcePath $file.FullName -DestinationDirectory (Join-Path $file.DirectoryName $targetKind)
        }
    }

    $duplicateDestinations = @(
        $movePlans |
            Group-Object Destination |
            Where-Object Count -gt 1
    )
    if ($duplicateDestinations.Count -gt 0) {
        throw "MEDIA_DESTINATION_AMBIGUOUS: $($duplicateDestinations.Name -join ', ')"
    }
    foreach ($plan in $movePlans) {
        if (Test-Path -LiteralPath $plan.Destination) {
            throw "MEDIA_DESTINATION_EXISTS: $($plan.Destination)"
        }
    }

    foreach ($plan in $movePlans) {
        $destinationDirectory = Split-Path -Parent $plan.Destination
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container) -and
            $PSCmdlet.ShouldProcess($destinationDirectory, 'Verzeichnis erstellen')) {
            New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
            $createdDirectories.Add($destinationDirectory)
        }
        if ($PSCmdlet.ShouldProcess($plan.Source, "Nach '$($plan.Destination)' verschieben")) {
            Move-Item -LiteralPath $plan.Source -Destination $plan.Destination
            $movedFiles.Add($plan.Destination)
        }
    }
}

if ($GenerateSha256 -and -not $WhatIfPreference) {
    $mediaExtensions = @('.exe', '.iso', '.vhd', '.vhdx')
    $files = @(
        Get-ChildItem -LiteralPath $mediaRoot -File -Recurse -Force |
            Where-Object {
                $_.Extension -in $mediaExtensions -and
                -not (Test-MediaPathWithin -Path $_.FullName -ParentPath (Join-Path $mediaRoot 'Hashes')) -and
                -not (Test-MediaPathWithin -Path $_.FullName -ParentPath (Join-Path $mediaRoot 'Exports'))
            }
    )
    foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($mediaRoot, $file.FullName)
        $hashPath = Join-Path (Join-Path $mediaRoot 'Hashes') ($relative + '.sha256')
        $hashDirectory = Split-Path -Parent $hashPath
        if (-not (Test-Path -LiteralPath $hashDirectory -PathType Container) -and
            $PSCmdlet.ShouldProcess($hashDirectory, 'Hash-Verzeichnis erstellen')) {
            New-Item -Path $hashDirectory -ItemType Directory -Force | Out-Null
            $createdDirectories.Add($hashDirectory)
        }

        $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $portableRelative = $relative.Replace('\', '/')
        $content = "$digest  $portableRelative"
        if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
            $existing = (Get-Content -LiteralPath $hashPath -Raw -Encoding utf8).Trim()
            if ($existing -ne $content) {
                throw "MEDIA_HASH_CONFLICT: $hashPath"
            }
            continue
        }
        if ($PSCmdlet.ShouldProcess($hashPath, 'SHA-256-Sidecar schreiben')) {
            Set-Content -LiteralPath $hashPath -Value $content -Encoding utf8NoBOM
            $hashFiles.Add($hashPath)
        }
    }
}

[PSCustomObject]@{
    ContractVersion     = '2'
    RootPath            = $mediaRoot
    CreatedDirectories  = @($createdDirectories)
    CreatedReadmeFiles  = @($createdReadmeFiles)
    SkippedReadmeFiles  = @($skippedReadmeFiles)
    MovedFiles          = @($movedFiles)
    HashFiles           = @($hashFiles)
}
