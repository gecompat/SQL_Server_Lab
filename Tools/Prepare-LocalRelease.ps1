#Requires -Version 7.2
<#
.SYNOPSIS
    Bereitet eine lokal reproduzierbare Release-Artefaktkopie vor.

.DESCRIPTION
    Das Skript erstellt einen versionierten Release-Ordner mit einem
    projektspezifischen Release-Manifest und optionaler Archiv-/Hash-Option.
    Es nutzt ausschließlich versionierte Repository-Dateien, damit keine
    lokalen States, Caches, Secrets oder Runtime-Evidence in den Release-Kandidaten
    gelangen.

.PARAMETER Version
    Release-Version (Fallback: Modulversion aus SqlServerLab.psd1).

.PARAMETER OutputRoot
    Zielordner für die Release-Kopie (Standard: .artifacts\release).

.PARAMETER CreateArchive
    Erstellt ein zusätzliches ZIP-Archiv im OutputRoot.

.PARAMETER IncludeHashManifest
    Erstellt eine SHA-256-Manifestdatei für Dateien im Release (und optional im Archive).

.PARAMETER SkipReadinessChecks
    Überspringt die lokale Release-Readiness-Prüfung. Standard ist die Prüfung.

.EXAMPLE
    .\Tools\Prepare-LocalRelease.ps1

.EXAMPLE
    .\Tools\Prepare-LocalRelease.ps1 -Version 0.1.0 -CreateArchive -IncludeHashManifest
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Version = '',
    [string]$OutputRoot = '.artifacts/release',
    [switch]$CreateArchive,
    [switch]$IncludeHashManifest,
    [switch]$SkipReadinessChecks
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $repoRoot 'SqlServerLab.psd1'
$moduleManifest = Import-PowerShellDataFile $manifestPath
$manifestVersion = $moduleManifest.ModuleVersion
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $manifestVersion
}

$outputRoot = Join-Path $repoRoot $OutputRoot
if (-not (Test-Path -LiteralPath $outputRoot)) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
}

if (-not $SkipReadinessChecks) {
    Write-Host 'Pruefe Release-Readiness vor Packaging...' -ForegroundColor Cyan
    & (Join-Path $repoRoot 'Tests\Static\Invoke-ReleaseReadinessChecks.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Release-Readiness-Pruefung fehlgeschlagen.'
    }
}

$releaseDate = Get-Date -Format 'yyyyMMdd'
$releaseTime = Get-Date -Format 'HHmmss'
$releaseId = "sqlserverlab-v{0}-{1}-{2}" -f $Version, $releaseDate, $releaseTime
$releaseRoot = Join-Path $outputRoot $releaseId

if (Test-Path -LiteralPath $releaseRoot) {
    throw "Release-Ziel {0} existiert bereits. Bitte Zeitstempel anpassen oder Ordner entfernen." -f $releaseRoot
}

if ($PSCmdlet.ShouldProcess($releaseRoot, 'Create release artifact root')) {
    New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null
}

function Get-TrackedFiles {
    $files = & git -C $repoRoot -c core.quotepath=false ls-files --cached --others --exclude-standard -z
    if ($LASTEXITCODE -ne 0) {
        throw 'git ls-files konnte nicht ausgefuehrt werden.'
    }

    $pattern = '(?:^|/)\\.(?:state|runtime|secrets|artifacts|cache|local)(?:/|$)|(?:^|/)\\.vscode(?:/|$)'
    $normalized = [Text.RegularExpressions.Regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($files -is [byte[]]) {
        $raw = [System.Text.Encoding]::UTF8.GetString($files)
    }
    else {
        $raw = [string]$files
    }
    $items = $raw -split [char]0
    $items = $items | Where-Object { $_ -and -not $normalized.IsMatch($_) }
    return $items
}

$trackedFiles = Get-TrackedFiles
if (-not $trackedFiles -or $trackedFiles.Count -eq 0) {
    throw 'Es wurden keine versionierten Dateien für den Release-Export gefunden.'
}

foreach ($relativeFile in $trackedFiles) {
    $from = Join-Path $repoRoot $relativeFile
    $to = Join-Path $releaseRoot $relativeFile

    if (Test-Path -LiteralPath $from -PathType Container) {
        New-Item -ItemType Directory -Path $to -Force | Out-Null
        continue
    }

    $parentDir = Split-Path -Path $to -Parent
    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    Copy-Item -LiteralPath $from -Destination $to -Force
}

$releaseNotesPath = Join-Path $releaseRoot 'ReleaseNotes.md'
$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
$changelogText = if (Test-Path -LiteralPath $changelogPath) { Get-Content -LiteralPath $changelogPath -Raw -Encoding utf8 } else { '' }
$releaseNotesSection = [regex]::Match(
    $changelogText,
    '(?ms)^##\s+{0}\s*$.*?(?=^##\s+\d{{4}}-\d{{2}}-\d{{2}}|\z)' -f [regex]::Escape($releaseDate)
)

$changelogDate = 'Nicht gefunden'
if ($releaseNotesSection.Success) {
    $changelogDate = $releaseDate
}

$releaseCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
$releaseBranch = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim()
$isDirty = ((git -C $repoRoot status --short).Trim().Length -gt 0)

$releaseText = @(
    '# Release Notes',
    '',
    "Version: $Version",
    "Release-ID: $releaseId",
    "Erstellungszeit (UTC): $((Get-Date).ToUniversalTime().ToString('u'))",
    "Source Commit: $releaseCommit",
    "Branch: $releaseBranch",
    "Repository-dirty: $isDirty",
    "Changelog-Datum: $changelogDate",
    '',
    '## Release-Inhalt',
    '',
    '```text',
    "ModuleVersion: $manifestVersion",
    "ModuleManifest: $manifestPath",
    "Release-Root: $releaseRoot",
    '```',
    '',
    '```text',
    $(if ($releaseNotesSection.Success) { $releaseNotesSection.Value } else { 'Kein passender Changelog-Eintrag gefunden.' }),
    '```'
) -join [Environment]::NewLine

$releaseText | Out-File -LiteralPath $releaseNotesPath -Encoding utf8

function Get-FileArtifactRows {
param(
    [string]$Root
)
    Get-ChildItem -Path $Root -Recurse -File | ForEach-Object {
        $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        [PSCustomObject]@{
            Path = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
            Size = $_.Length
            HashAlgorithm = 'SHA256'
            Hash = $hash.Hash.ToLowerInvariant()
            ModifiedUtc = $_.LastWriteTimeUtc.ToString('o')
        }
    } | Sort-Object Path
}

$artifacts = Get-FileArtifactRows -Root $releaseRoot
$manifest = [ordered]@{
    Name = 'SqlServerLab'
    ReleaseVersion = $Version
    ModuleVersion = $manifestVersion
    CreatedUtc = (Get-Date).ToUniversalTime().ToString('u')
    SourceCommit = $releaseCommit
    SourceBranch = $releaseBranch
    RepositoryDirty = $isDirty
    ReleaseReadinessCheck = $SkipReadinessChecks.ToString()
    ChangelogDate = $changelogDate
    ArtifactCount = $artifacts.Count
    IncludedFiles = $artifacts
}

$releaseManifestPath = Join-Path $releaseRoot 'ReleaseManifest.json'
$manifest | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $releaseManifestPath -Encoding utf8

$hashPath = Join-Path $releaseRoot 'ReleaseHashes.txt'
if ($IncludeHashManifest) {
    $hashLines = foreach ($entry in $artifacts) {
        ('{0}  {1}' -f $entry.Hash, $entry.Path)
    }
    $hashLines | Out-File -LiteralPath $hashPath -Encoding utf8
}

$archivePath = ''
if ($CreateArchive) {
    $archivePath = Join-Path $outputRoot ($releaseId + '.zip')
    if ($PSCmdlet.ShouldProcess($archivePath, 'Create release archive')) {
        Compress-Archive -Path (Join-Path $releaseRoot '*') -DestinationPath $archivePath -CompressionLevel Optimal -Force
    }

    if ($IncludeHashManifest) {
        $archiveHash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
        "$($archiveHash.Hash.ToLowerInvariant())  $($releaseId).zip" | Out-File -LiteralPath "$archivePath.sha256" -Encoding utf8
        $hashLines = @(
            (Get-Content -LiteralPath $hashPath -ErrorAction SilentlyContinue)
            "$($archiveHash.Hash.ToLowerInvariant())  $($releaseId).zip"
        ) | Where-Object { $_ }
        $hashLines | Out-File -LiteralPath $hashPath -Encoding utf8
    }
}

Write-Host "Release-Artefakt erstellt: $releaseRoot" -ForegroundColor Green
if ($CreateArchive) {
    Write-Host "Archive erstellt: $archivePath" -ForegroundColor Green
}
if ($IncludeHashManifest) {
    Write-Host "Hash-Manifest: $hashPath" -ForegroundColor Green
}

[PSCustomObject]@{
    ReleaseVersion = $Version
    ReleaseId = $releaseId
    ReleaseRoot = $releaseRoot
    Archive = $archivePath
    HashManifest = if ($IncludeHashManifest) { $hashPath } else { '' }
}
