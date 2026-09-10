#Requires -Version 7.2
<#
.SYNOPSIS
    Erstellt ein geprüftes Release-Paket aus einem festen Git-Commit.
.DESCRIPTION
    Verlangt einen sauberen Quellstand einschließlich nicht ignorierter neuer
    Dateien. Exportiert ausschließlich den ausgewählten HEAD-Snapshot, filtert
    lokale Daten und blockiert Symlinks. Erst das vollständige Paket wird aus
    einem eigenen Staging-Verzeichnis veröffentlicht. WhatIf schreibt nichts.
.PARAMETER Version
    Release-Version; standardmäßig die ModuleVersion.
.PARAMETER OutputRoot
    Lokales Zielverzeichnis; relativ zum Repository oder absolut.
.PARAMETER CreateArchive
    Erstellt zusätzlich eine ZIP-Datei einschließlich versteckter Nutzdateien.
.PARAMETER IncludeHashManifest
    Erstellt SHA-256-Listen für das Paket und gegebenenfalls das fertige Archiv.
.PARAMETER SkipReadinessChecks
    Überspringt die lokale Release-Readiness-Prüfung; Status bleibt SKIPPED.
.EXAMPLE
    ./Tools/Prepare-LocalRelease.ps1 -CreateArchive -IncludeHashManifest
.EXAMPLE
    ./Tools/Prepare-LocalRelease.ps1 -WhatIf
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

function Invoke-ReleaseGit {
    param([string[]]$Arguments)
    $result = & git -C $repoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'RELEASE_GIT_FAILED' }
    return $result
}

function Assert-ReleasePath {
    param([string]$Path, [string]$Parent)
    $full = [IO.Path]::GetFullPath($Path)
    if ($Parent) {
        $prefix = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'RELEASE_PATH_OUTSIDE_SCOPE' }
    }
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'RELEASE_REPARSE_PATH_BLOCKED' }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}

function Test-ReleaseExcludedPath {
    param([string]$Path)
    if ($Path -match '(?i)(?:^|/)\.(?:state|runtime|secrets|artifacts|cache|local|vscode|git|idea|vs|venv)(?:/|$)') { return $true }
    if ($Path -match '(?i)(?:^|/)(?:PackageRegistry|Media|Images)/local(?:/|$)') { return $true }
    if ($Path -match '(?i)(?:^|/)\.env(?:\..+)?$' -and $Path -notmatch '(?i)(?:^|/)\.env\.example$') { return $true }
    if ($Path -match '(?i)\.(?:secret|secrets|key|pem|pfx|p12|cer|crt|kdbx|bak|trn|mdf|ndf|ldf|xel|sqlaudit|sqlplan|showplan|dmp|mdmp|vhd|vhdx|avhd|avhdx|iso|qcow2?|img|ova|ovf|log|trace|etl|zip|7z|rar|tar|tar\.gz|tgz|oci)$') { return $true }
    return $false
}

function Get-ReleaseFileRows {
    param([string]$Root)
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        [PSCustomObject]@{
            Path = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
            Size = $_.Length
            HashAlgorithm = 'SHA256'
            Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } | Sort-Object Path
}

$releaseCommit = ([string](Invoke-ReleaseGit @('rev-parse','--verify','HEAD'))).Trim()
$sourceStatus = @(Invoke-ReleaseGit @('status','--porcelain=v1','--untracked-files=all'))
if ($sourceStatus.Count -gt 0) { throw 'RELEASE_SOURCE_NOT_CLEAN' }
$releaseBranch = ([string](Invoke-ReleaseGit @('rev-parse','--abbrev-ref','HEAD'))).Trim()
$moduleManifest = Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
$manifestVersion = [string]$moduleManifest.ModuleVersion
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $manifestVersion }
if ($Version -notmatch '^\d+(?:\.\d+){1,3}(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$') { throw 'RELEASE_VERSION_INVALID' }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'RELEASE_OUTPUT_REQUIRED' }
$outputDirectory = [IO.Path]::GetFullPath($OutputRoot, $repoRoot)
Assert-ReleasePath $outputDirectory
if ((Test-Path -LiteralPath $outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw 'RELEASE_OUTPUT_NOT_DIRECTORY' }
$createdAt = Get-Date
$releaseId = 'sqlserverlab-v{0}-{1}-{2}' -f $Version, $createdAt.ToString('yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0,8)
$releaseRoot = Join-Path $outputDirectory $releaseId
$archivePath = Join-Path $outputDirectory ($releaseId + '.zip')
$stageRoot = Join-Path $outputDirectory ('.release-stage-' + [guid]::NewGuid().ToString('N'))
foreach ($target in @($releaseRoot, $archivePath, ($archivePath + '.sha256'), $stageRoot)) {
    Assert-ReleasePath $target $outputDirectory
    if (Test-Path -LiteralPath $target) { throw 'RELEASE_TARGET_EXISTS' }
}

# Eine Entscheidung umfasst die komplette Transaktion; vor ihr wird nichts angelegt.
if (-not $PSCmdlet.ShouldProcess($releaseRoot, 'Create and publish verified release artifacts')) { return }
if (-not $SkipReadinessChecks) {
    & pwsh -NoProfile -File (Join-Path $repoRoot 'Tests/Static/Invoke-ReleaseReadinessChecks.ps1') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'RELEASE_READINESS_FAILED' }
}

$outputCreated = -not (Test-Path -LiteralPath $outputDirectory)
$publishedPaths = [Collections.Generic.List[string]]::new()
$completed = $false
$operationFailure = $null
try {
    Assert-ReleasePath $outputDirectory
    Assert-ReleasePath $stageRoot $outputDirectory
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
    $packageRoot = Join-Path $stageRoot 'package'
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    $sourceArchive = Join-Path $stageRoot 'source.zip'
    Invoke-ReleaseGit @('archive','--format=zip',('--output=' + $sourceArchive),$releaseCommit) | Out-Null
    $snapshot = [IO.Compression.ZipFile]::OpenRead($sourceArchive)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $snapshot.Entries) {
            $name = $entry.FullName
            if ($name.EndsWith('/')) { continue }
            if ($name -match '(^/|\\|:|(^|/)\.\.?(/|$))' -or -not $seen.Add($name)) { throw 'RELEASE_ARCHIVE_PATH_INVALID' }
            if (Test-ReleaseExcludedPath $name) { continue }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -eq 0xA000) { throw 'RELEASE_SOURCE_SYMLINK_BLOCKED' }
            $destination = Join-Path $packageRoot $name
            Assert-ReleasePath $destination $packageRoot
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
        }
    }
    finally { $snapshot.Dispose() }

    $snapshotManifest = Import-PowerShellDataFile (Join-Path $packageRoot 'SqlServerLab.psd1')
    if ([string]$snapshotManifest.ModuleVersion -ne $manifestVersion) { throw 'RELEASE_SOURCE_CHANGED' }
    $changelogPath = Join-Path $packageRoot 'CHANGELOG.md'
    $changelog = if (Test-Path -LiteralPath $changelogPath) { Get-Content -LiteralPath $changelogPath -Raw -Encoding utf8 } else { '' }
    $changelogDay = $createdAt.ToString('yyyy-MM-dd')
    $section = [regex]::Match($changelog, ('(?ms)^##\s+{0}\s*$.*?(?=^##\s+\d{{4}}-\d{{2}}-\d{{2}}|\z)' -f [regex]::Escape($changelogDay)))
    $changelogDate = if ($section.Success) { $changelogDay } else { 'Nicht gefunden' }
    $releaseText = @(
        '# Release Notes', '',
        "Version: $Version", "Release-ID: $releaseId",
        "Erstellungszeit (UTC): $($createdAt.ToUniversalTime().ToString('u'))",
        "Source Commit: $releaseCommit", "Branch: $releaseBranch",
        'Repository-dirty: False', "Changelog-Datum: $changelogDate", '',
        'ModuleManifest: SqlServerLab.psd1', "ModuleVersion: $manifestVersion", '',
        $(if ($section.Success) { $section.Value } else { 'Kein passender Changelog-Eintrag gefunden.' })
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $packageRoot 'ReleaseNotes.md'), $releaseText)
    $artifacts = @(Get-ReleaseFileRows $packageRoot)
    $manifest = [ordered]@{
        Name = 'SqlServerLab'
        ReleaseVersion = $Version
        ModuleVersion = $manifestVersion
        CreatedUtc = $createdAt.ToUniversalTime().ToString('u')
        SourceCommit = $releaseCommit
        SourceBranch = $releaseBranch
        RepositoryDirty = $false
        ReleaseReadinessCheck = $(if ($SkipReadinessChecks) { 'SKIPPED' } else { 'PASSED' })
        ChangelogDate = $changelogDate
        ArtifactCount = $artifacts.Count
        IncludedFiles = $artifacts
    }
    [IO.File]::WriteAllText((Join-Path $packageRoot 'ReleaseManifest.json'), ($manifest | ConvertTo-Json -Depth 20))
    if ($IncludeHashManifest) {
        $hashLines = @(Get-ReleaseFileRows $packageRoot | ForEach-Object { '{0}  {1}' -f $_.Hash, $_.Path })
        [IO.File]::WriteAllLines((Join-Path $packageRoot 'ReleaseHashes.txt'), [string[]]$hashLines)
    }
    $stagedArchive = Join-Path $stageRoot ($releaseId + '.zip')
    if ($CreateArchive) {
        [IO.Compression.ZipFile]::CreateFromDirectory($packageRoot, $stagedArchive, [IO.Compression.CompressionLevel]::Optimal, $false)
        if ($IncludeHashManifest) {
            $archiveHash = (Get-FileHash -LiteralPath $stagedArchive -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText(($stagedArchive + '.sha256'), "$archiveHash  $releaseId.zip")
        }
    }

    # Nach fertigem Inhalt erneut gegen Pfadwechsel pruefen; niemals ueberschreiben.
    Assert-ReleasePath $packageRoot $stageRoot
    Assert-ReleasePath $releaseRoot $outputDirectory
    if ($CreateArchive) {
        Assert-ReleasePath $archivePath $outputDirectory
        [IO.File]::Move($stagedArchive, $archivePath)
        $publishedPaths.Add($archivePath)
        if ($IncludeHashManifest) {
            Assert-ReleasePath ($archivePath + '.sha256') $outputDirectory
            [IO.File]::Move(($stagedArchive + '.sha256'), ($archivePath + '.sha256'))
            $publishedPaths.Add($archivePath + '.sha256')
        }
    }
    [IO.Directory]::Move($packageRoot, $releaseRoot)
    $publishedPaths.Add($releaseRoot)
    $completed = $true
}
catch { $operationFailure = $_.Exception; throw }
finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    $cleanupTargets = @($stageRoot)
    if (-not $completed) { $cleanupTargets += @($publishedPaths) }
    foreach ($target in $cleanupTargets) {
        try {
            Assert-ReleasePath $target $outputDirectory
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -Confirm:$false }
        }
        catch { $cleanupFailures.Add('RELEASE_ARTIFACT_CLEANUP_FAILED') }
    }
    if (-not $completed -and $outputCreated -and (Test-Path -LiteralPath $outputDirectory)) {
        try {
            Assert-ReleasePath $outputDirectory
            if (@(Get-ChildItem -LiteralPath $outputDirectory -Force).Count -eq 0) { [IO.Directory]::Delete($outputDirectory) }
        }
        catch { $cleanupFailures.Add('RELEASE_OUTPUT_CLEANUP_FAILED') }
    }
    if ($cleanupFailures.Count -gt 0) {
        throw [InvalidOperationException]::new(('RELEASE_RECOVERY_REQUIRED: ' + ($cleanupFailures -join ', ')), $operationFailure)
    }
}

Write-Host "Release-Artefakt erstellt: $releaseRoot" -ForegroundColor Green
[PSCustomObject]@{
    ReleaseVersion = $Version
    ReleaseId = $releaseId
    ReleaseRoot = $releaseRoot
    Archive = $(if ($CreateArchive) { $archivePath } else { '' })
    HashManifest = $(if ($IncludeHashManifest) { Join-Path $releaseRoot 'ReleaseHashes.txt' } else { '' })
}
