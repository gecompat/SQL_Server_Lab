#Requires -Version 7.2
<#
.SYNOPSIS
Vergleicht den SQL Server Versionskatalog mit den offiziellen Microsoft CU-Informationen.

.DESCRIPTION
Das Tool lädt die offizielle Microsoft-Übersichtsseite für SQL Server-Updates
und ermittelt die aktuellen CU-Builds für die im Katalog gepflegten SQL-Versionen.
Es meldet zurück, ob der lokale Katalog neue CU/Build-Einträge vermisst.

.PARAMETER CatalogPath
Pfad zur Katalogdatei mit SQL Server Builds.

.PARAMETER SourceUrl
Microsoft-Quelle für aktuelle SQL Server-Updates.

.PARAMETER Version
Optionale Begrenzung auf bestimmte Hauptversionen (z. B. 2019, 2022, 2025).

.PARAMETER MaxMissingEntries
Maximale Anzahl der auszugebenden fehlenden CU-Einträge pro Version.

.PARAMETER AsJson
Gibt die Auswertung als JSON zurück.
#>
[CmdletBinding()]
param(
    [string]$CatalogPath = 'Catalogs/sql-server-versions.json',
    [string]$SourceUrl = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates',
    [string[]]$Version = @(),
    [int]$MaxMissingEntries = 5,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

function Convert-PlainTextFromHtml {
    param([string]$Html)

    $clean = [regex]::Replace($Html, '(?is)<(script|style).*?</\1>', ' ')
    $clean = [regex]::Replace($clean, '<[^>]+>', ' ')
    try {
        Add-Type -AssemblyName System.Web | Out-Null
        $clean = [System.Web.HttpUtility]::HtmlDecode($clean)
    }
    catch { }

    $clean = $clean -replace '&nbsp;', ' '
    $clean = $clean -replace "`r`n", "`n"
    $clean = $clean -replace "`r", "`n"
    $clean = [regex]::Replace($clean, '[\t ]+', ' ')
    return $clean
}

function Get-CatalogCUs {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Katalog nicht gefunden: $Path"
    }

    $catalog = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 12
    $result = @{}

    foreach ($entry in @($catalog.versions)) {
        $versionId = [string]$entry.id
        $builds = @()
        foreach ($build in @($entry.docker.builds)) {
            $builds += [PSCustomObject]@{
                Tag = [string]$build.tag
                Cu = if ($build.cu) { [string]$build.cu } else { '' }
                Kb = if ($build.kb) { [string]$build.kb.ToString().ToUpperInvariant() } else { '' }
                Released = if ($build.released) { [string]$build.released } else { '' }
            }
        }

        $result[$versionId] = [PSCustomObject]@{
            VersionId = $versionId
            Builds = $builds
        }
    }

    return $result
}

function Get-MicrosoftRows {
    param([string]$SourceUrl)

    try {
        $response = Invoke-WebRequest -Uri $SourceUrl -UseBasicParsing -TimeoutSec 90 -Headers @{
            'User-Agent' = 'sql-server-lab-cuwatcher/1.0 (+https://github.com)'
        }
        $plain = Convert-PlainTextFromHtml -Html $response.Content
    }
    catch {
        throw "Microsoft-Quelle konnte nicht geladen werden: $($_.Exception.Message)"
    }

    $rows = @()
    $sectionPattern = '(?ms)^###\s*SQL Server\s+(?<version>\d{4}(?:\s*R2)?)\s*\n(?<body>.*?)(?=^###\s*SQL Server\s+\d{4}(?:\s*R2)?|$)'
    $sectionMatches = [regex]::Matches(
        $plain,
        $sectionPattern,
        [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    foreach ($section in $sectionMatches) {
        $label = [string]$section.Groups['version'].Value
        $majorMatch = [regex]::Match($label, '\d{4}')
        if (-not $majorMatch.Success) {
            continue
        }
        $majorVersion = $majorMatch.Value
        $body = [string]$section.Groups['body'].Value

        $rowPattern = '(?m)^\s*(?<build>\d+\.\d+\.\d+\.\d+)\s*\|\s*(?<sp>[^|]+?)\s*\|\s*(?<update>[^|]+?)\s*\|\s*(?<kb>KB\d+|NA)\s*\|\s*(?<released>[A-Za-z]+\s+\d{1,2},\s+\d{4})\s*$'
        $rowMatches = [regex]::Matches(
            $body,
            $rowPattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
        )

        foreach ($match in $rowMatches) {
            $kb = [string]$match.Groups['kb'].Value.ToUpperInvariant().Trim()
            $updateText = [string]$match.Groups['update'].Value
            if (-not $updateText.ToUpperInvariant().Contains('CU')) {
                continue
            }

            $rows += [PSCustomObject]@{
                Version = $majorVersion
                Build = [string]$match.Groups['build'].Value
                Update = $updateText.Trim()
                Kb = if ($kb -eq 'NA') { '' } else { $kb }
                Released = [string]$match.Groups['released'].Value
            }
        }
    }

    return $rows
}

$catalogPathAbsolute = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path $CatalogPath
$catalogData = Get-CatalogCUs -Path $catalogPathAbsolute
$catalogVersions = $catalogData.Keys
$targetVersions = if ($Version -and $Version.Count -gt 0) {
    @($Version | ForEach-Object { $_.ToString().Trim() })
}
else {
    @($catalogVersions)
}

$checkResult = @()
$overallStatus = 'NO CHANGE'
$unclearReason = $null

try {
    $msRows = Get-MicrosoftRows -SourceUrl $SourceUrl
}
catch {
    $overallStatus = 'UNCLEAR'
    $unclearReason = $_.Exception.Message
    $msRows = @()
}

if (-not $msRows -and $overallStatus -ne 'UNCLEAR') {
    $overallStatus = 'UNCLEAR'
    $unclearReason = 'Microsoft-Quelle lieferte keine auswertbaren CU-Zeilen.'
}

foreach ($target in $targetVersions) {
    $versionId = $target.Trim()
    if (-not $catalogData.ContainsKey($versionId)) {
        $checkResult += [PSCustomObject]@{
            Version = $versionId
            Status = 'UNCLEAR'
            LatestCatalogKb = ''
            LatestMicrosoft = $null
            MissingCount = 0
            Missing = @()
            Note = 'Version ist im Katalog nicht vorhanden.'
        }
        $overallStatus = 'UNCLEAR'
        continue
    }

    if ($overallStatus -eq 'UNCLEAR') {
        $checkResult += [PSCustomObject]@{
            Version = $versionId
            Status = 'UNCLEAR'
            LatestCatalogKb = ''
            LatestMicrosoft = $null
            MissingCount = 0
            Missing = @()
            Note = if ($unclearReason) { $unclearReason } else { 'Quelle nicht auswertbar.' }
        }
        continue
    }

    $catalogVersionsForVersion = @($catalogData[$versionId].Builds)
    $catalogKbSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($catalogBuild in $catalogVersionsForVersion) {
        if ($catalogBuild.Kb) {
            [void]$catalogKbSet.Add($catalogBuild.Kb)
        }
    }

    $knownLatestKb = $null
    if ($catalogVersionsForVersion.Count -gt 0) {
        $latestCatalog = $catalogVersionsForVersion | Where-Object { $_.Kb } | Select-Object -First 1
        if (-not $latestCatalog) {
            $latestCatalog = $catalogVersionsForVersion | Select-Object -First 1
        }
        $knownLatestKb = $latestCatalog.Kb
    }

    $rowsForVersion = @($msRows | Where-Object { $_.Version -eq $versionId } | Sort-Object -Property { [Version]$_.Build } -Descending)
    if ($rowsForVersion.Count -eq 0) {
        $checkResult += [PSCustomObject]@{
            Version = $versionId
            Status = 'UNCLEAR'
            LatestCatalogKb = $knownLatestKb
            LatestMicrosoft = $null
            MissingCount = 0
            Missing = @()
            Note = 'Keine CU-Zeilen in Microsoft-Quelle für diese Version gefunden.'
        }
        $overallStatus = 'UNCLEAR'
        continue
    }

    $latestMicrosoft = $rowsForVersion[0]
    $missing = @()
    foreach ($row in $rowsForVersion) {
        if ([string]::IsNullOrWhiteSpace($row.Kb)) {
            continue
        }
        if (-not $catalogKbSet.Contains($row.Kb)) {
            $missing += $row
        }
        else {
            break
        }
    }

    if ($missing.Count -gt $MaxMissingEntries) {
        $missing = $missing | Select-Object -First $MaxMissingEntries
    }

    $status = if ($missing.Count -gt 0) { 'NEW' } else { 'NO CHANGE' }
    if ($status -eq 'NEW' -and $overallStatus -eq 'NO CHANGE') {
        $overallStatus = 'NEW'
    }

    $checkResult += [PSCustomObject]@{
        Version = $versionId
        Status = $status
        LatestCatalogKb = $knownLatestKb
        LatestMicrosoft = $latestMicrosoft
        MissingCount = $missing.Count
        Missing = $missing
        Note = if ($missing.Count -gt 0) { 'Katalog enthält diese KBs nicht.' } else { 'Katalog ist auf dem Stand der Quelle.' }
    }
}

$output = [PSCustomObject]@{
    Status = $overallStatus
    CheckedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceUrl = $SourceUrl
    CatalogPath = $CatalogPath
    Versions = $checkResult
}

if ($AsJson) {
    $output | ConvertTo-Json -Depth 12
    return
}

if ($overallStatus -eq 'UNCLEAR') {
    Write-Host "A) Gesamtstatus: UNCLEAR" -ForegroundColor Yellow
    if ($unclearReason) {
        Write-Host "Ursache: $unclearReason"
    }
}
else {
    Write-Host ("A) Gesamtstatus: {0}" -f $overallStatus)
}

Write-Host "`nB) CU-Diff je Version"
foreach ($entry in $checkResult) {
    Write-Host ("- SQL {0} [{1}]" -f $entry.Version, $entry.Status)
    if ($entry.LatestMicrosoft) {
        Write-Host ("  - Microsoft: {0} / {1} / {2} / {3}" -f $entry.LatestMicrosoft.Build, $entry.LatestMicrosoft.Update, $entry.LatestMicrosoft.Kb, $entry.LatestMicrosoft.Released)
    }
    else {
        Write-Host "  - Microsoft: keine Daten"
    }
    Write-Host ("  - Katalog-Latest-KB: {0}" -f $entry.LatestCatalogKb)
    if ($entry.MissingCount -gt 0) {
        Write-Host ("  - Fehlend: {0} Eintrag(e)" -f $entry.MissingCount)
        foreach ($missing in $entry.Missing) {
            Write-Host ("    - {0} {1} {2} ({3})" -f $missing.Build, $missing.Update, $missing.Kb, $missing.Released)
        }
    }
    else {
        Write-Host "  - Fehlend: 0"
    }

    if ($entry.Note) {
        Write-Host ("  - Hinweis: {0}" -f $entry.Note)
    }
}

Write-Host "`nNächster Check: $((Get-Date).AddMonths(1).ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
