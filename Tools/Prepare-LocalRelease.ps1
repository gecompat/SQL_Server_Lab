#Requires -Version 7.2
<#
.SYNOPSIS
    Erstellt ein geprüftes Release-Paket aus einem festen Git-Commit.
.DESCRIPTION
    Verlangt einen sauberen Quellstand einschließlich nicht ignorierter neuer
    Dateien. Exportiert ausschließlich den ausgewählten HEAD-Snapshot, filtert
    lokale Daten und blockiert Symlinks. Erst das vollständige Paket wird aus
    einem eigenen Staging-Verzeichnis veröffentlicht. WhatIf schreibt nichts.
    Eine atomare Abschlussquittung bindet die vollständige Veröffentlichung.
    InspectReleaseId prüft genau eine Veröffentlichung ohne Schreiben oder Cleanup.
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
.PARAMETER InspectReleaseId
    Prüft Intent, Abschlussquittung und aktuelle Paketbytes rein lesend. Fehlende
    Quittung ergibt INCOMPLETE; dies unterscheidet keinen laufenden von einem
    abgebrochenen Prozess und autorisiert weder Retry noch Entfernung.
.EXAMPLE
    ./Tools/Prepare-LocalRelease.ps1 -CreateArchive -IncludeHashManifest
.EXAMPLE
    ./Tools/Prepare-LocalRelease.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Create')]
param(
    [Parameter(ParameterSetName = 'Create')]
    [string]$Version = '',
    [string]$OutputRoot = '.artifacts/release',
    [Parameter(ParameterSetName = 'Create')]
    [switch]$CreateArchive,
    [Parameter(ParameterSetName = 'Create')]
    [switch]$IncludeHashManifest,
    [Parameter(ParameterSetName = 'Create')]
    [switch]$SkipReadinessChecks,
    [Parameter(Mandatory, ParameterSetName = 'Inspect')]
    [ValidatePattern('^sqlserverlab-v\d+(?:\.\d+){1,3}(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?-\d{8}-\d{6}-[a-f0-9]{8}$')]
    [string]$InspectReleaseId
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
    Assert-ReleasePath $Root
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Root)
    $rows = [Collections.Generic.List[object]]::new()
    $count = 0
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        Assert-ReleasePath $directory
        foreach ($item in (Get-ChildItem -LiteralPath $directory -Force)) {
            if (++$count -gt 10000) { throw 'RELEASE_FILE_LIMIT' }
            Assert-ReleasePath $item.FullName $Root
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName); continue }
            $rows.Add([PSCustomObject]@{
                Path = [IO.Path]::GetRelativePath($Root, $item.FullName).Replace('\', '/')
                Size = $item.Length
                HashAlgorithm = 'SHA256'
                Hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
    }
    $rows | Sort-Object Path -CaseSensitive
}

function Write-ReleaseRecord {
    param([string]$Path, [string]$Stage, $Record)
    Assert-ReleasePath $Path $outputDirectory
    Assert-ReleasePath $Stage $outputDirectory
    $temporary = Join-Path $Stage ('publication-' + [guid]::NewGuid().ToString('N') + '.json')
    Assert-ReleasePath $temporary $Stage
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 8))
    if ($bytes.Length -gt 4MB) { throw 'RELEASE_RECORD_LIMIT' }
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    Assert-ReleasePath $Path $outputDirectory
    [IO.File]::Move($temporary, $Path)
}

function Read-ReleaseRecord {
    param([string]$Path)
    Assert-ReleasePath $Path $outputDirectory
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'RELEASE_RECORD_INVALID' }
    # Die Grenze gilt fuer den gehaltenen Readstream, auch bei Dateiwachstum.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = [byte[]]::new(4MB + 1)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt 4MB) { throw 'RELEASE_RECORD_LIMIT' }
        $bytes = [byte[]]::new($count)
        [Buffer]::BlockCopy($buffer, 0, $bytes, 0, $count)
    }
    finally { $stream.Dispose() }
    $value = ConvertFrom-Json -InputObject ([Text.UTF8Encoding]::new($false, $true).GetString($bytes)) -Depth 12 -NoEnumerate
    if ($value -isnot [pscustomobject]) { throw 'RELEASE_RECORD_INVALID' }
    [PSCustomObject]@{ Value = $value; Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
}

function Assert-ReleaseRows {
    param($Rows)
    if ($Rows -isnot [array] -or $Rows.Count -gt 10000) { throw 'RELEASE_RECORD_ROWS_INVALID' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Rows) {
        if ($row -isnot [pscustomobject] -or @($row.PSObject.Properties).Count -ne 4 -or
            $row.Path -isnot [string] -or $row.Path -match '(^[/\\]|\\|:|(^|/)\.\.?(/|$)|//|/$)' -or -not $row.Path -or
            -not $seen.Add($row.Path) -or ($row.Size -isnot [long] -and $row.Size -isnot [int]) -or $row.Size -lt 0 -or
            $row.HashAlgorithm -cne 'SHA256' -or $row.Hash -isnot [string] -or $row.Hash -cnotmatch '^[a-f0-9]{64}$') { throw 'RELEASE_RECORD_ROWS_INVALID' }
    }
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'RELEASE_OUTPUT_REQUIRED' }
$outputDirectory = [IO.Path]::GetFullPath($OutputRoot, $repoRoot)
Assert-ReleasePath $outputDirectory
if ((Test-Path -LiteralPath $outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw 'RELEASE_OUTPUT_NOT_DIRECTORY' }
if ($PSCmdlet.ParameterSetName -ceq 'Inspect') {
    $intentPath = Join-Path $outputDirectory ($InspectReleaseId + '.publication.json')
    $receiptPath = Join-Path $outputDirectory ($InspectReleaseId + '.completed.json')
    foreach ($path in @($intentPath, $receiptPath)) { Assert-ReleasePath $path $outputDirectory }
    $status = 'NOT_ATTESTED'
    $stagePresent = $null
    if (Test-Path -LiteralPath $intentPath) {
        $boundIntent = Read-ReleaseRecord $intentPath
        $intent = $boundIntent.Value
        foreach ($field in @('Contract','Status','ReleaseId','SourceCommit','StageDirectory')) {
            if ($intent.$field -isnot [string]) { throw 'RELEASE_INTENT_INVALID' }
        }
        if (@($intent.PSObject.Properties).Count -ne 7 -or $intent.Contract -cne 'SqlServerLab.ReleasePublication/1.0' -or
            $intent.Status -cne 'PENDING' -or $intent.ReleaseId -cne $InspectReleaseId -or
            $intent.SourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $intent.StageDirectory -cnotmatch '^\.release-stage-[a-f0-9]{32}$' -or
            $intent.CreateArchive -isnot [bool] -or $intent.IncludeHashManifest -isnot [bool]) { throw 'RELEASE_INTENT_INVALID' }
        $stagePath = Join-Path $outputDirectory $intent.StageDirectory
        Assert-ReleasePath $stagePath $outputDirectory
        $stagePresent = Test-Path -LiteralPath $stagePath
        $status = 'INCOMPLETE'
        if (Test-Path -LiteralPath $receiptPath) {
            $boundReceipt = Read-ReleaseRecord $receiptPath
            $receipt = $boundReceipt.Value
            foreach ($field in @('Contract','Status','ReleaseId','SourceCommit','StageDirectory','IntentSha256')) {
                if ($receipt.$field -isnot [string]) { throw 'RELEASE_RECEIPT_INVALID' }
            }
            if (@($receipt.PSObject.Properties).Count -ne 10 -or $receipt.Status -cne 'COMPLETED' -or $receipt.IntentSha256 -cne $boundIntent.Hash -or
                $receipt.CreateArchive -isnot [bool] -or $receipt.IncludeHashManifest -isnot [bool]) { throw 'RELEASE_RECEIPT_INVALID' }
            foreach ($field in @('Contract','ReleaseId','SourceCommit','StageDirectory','CreateArchive','IncludeHashManifest')) {
                if ($receipt.$field -cne $intent.$field) { throw 'RELEASE_RECEIPT_INVALID' }
            }
            Assert-ReleaseRows $receipt.PackageFiles
            Assert-ReleaseRows $receipt.ArchiveFiles
            if ($receipt.PackageFiles.Count -lt 1) { throw 'RELEASE_RECORD_ROWS_INVALID' }
            $expectedArchivePaths = @()
            if ($intent.CreateArchive) {
                $expectedArchivePaths += ($InspectReleaseId + '.zip')
                if ($intent.IncludeHashManifest) { $expectedArchivePaths += ($InspectReleaseId + '.zip.sha256') }
            }
            if ((@($receipt.ArchiveFiles.Path | Sort-Object -CaseSensitive) -join '|') -cne (($expectedArchivePaths | Sort-Object -CaseSensitive) -join '|')) { throw 'RELEASE_RECEIPT_ARCHIVE_SET_INVALID' }
            $package = Join-Path $outputDirectory $InspectReleaseId
            Assert-ReleasePath $package $outputDirectory
            if (-not (Test-Path -LiteralPath $package -PathType Container)) { throw 'RELEASE_PUBLICATION_BYTES_CHANGED' }
            $currentRows = @(Get-ReleaseFileRows $package)
            if (($currentRows | ConvertTo-Json -Depth 4 -Compress) -cne (@($receipt.PackageFiles | Sort-Object Path -CaseSensitive) | ConvertTo-Json -Depth 4 -Compress)) { throw 'RELEASE_PUBLICATION_BYTES_CHANGED' }
            foreach ($row in $receipt.ArchiveFiles) {
                $path = Join-Path $outputDirectory $row.Path
                Assert-ReleasePath $path $outputDirectory
                if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path -Force).Length -ne $row.Size -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $row.Hash) { throw 'RELEASE_PUBLICATION_BYTES_CHANGED' }
            }
            if ((Read-ReleaseRecord $receiptPath).Hash -cne $boundReceipt.Hash) { throw 'RELEASE_RECORD_CHANGED_DURING_INSPECTION' }
            $status = 'COMPLETED'
        }
        if ((Read-ReleaseRecord $intentPath).Hash -cne $boundIntent.Hash) { throw 'RELEASE_RECORD_CHANGED_DURING_INSPECTION' }
    }
    elseif (Test-Path -LiteralPath $receiptPath) { throw 'RELEASE_PUBLICATION_INTENT_MISSING' }
    [PSCustomObject]@{ ReleaseId = $InspectReleaseId; PublicationStatus = $status; StagePresent = $stagePresent; Mutation = $false; Actions = @(); ProcessStatus = 'NOT_CHECKED' }
    return
}

$releaseCommit = ([string](Invoke-ReleaseGit @('rev-parse','--verify','HEAD'))).Trim()
$sourceStatus = @(Invoke-ReleaseGit @('status','--porcelain=v1','--untracked-files=all'))
if ($sourceStatus.Count -gt 0) { throw 'RELEASE_SOURCE_NOT_CLEAN' }
$releaseBranch = ([string](Invoke-ReleaseGit @('rev-parse','--abbrev-ref','HEAD'))).Trim()
$moduleManifest = Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
$manifestVersion = [string]$moduleManifest.ModuleVersion
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $manifestVersion }
if ($Version -notmatch '^\d+(?:\.\d+){1,3}(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$') { throw 'RELEASE_VERSION_INVALID' }
$createdAt = Get-Date
$releaseId = 'sqlserverlab-v{0}-{1}-{2}' -f $Version, $createdAt.ToString('yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0,8)
$releaseRoot = Join-Path $outputDirectory $releaseId
$archivePath = Join-Path $outputDirectory ($releaseId + '.zip')
$stageRoot = Join-Path $outputDirectory ('.release-stage-' + [guid]::NewGuid().ToString('N'))
$intentPath = Join-Path $outputDirectory ($releaseId + '.publication.json')
$receiptPath = Join-Path $outputDirectory ($releaseId + '.completed.json')
foreach ($target in @($releaseRoot, $archivePath, ($archivePath + '.sha256'), $stageRoot, $intentPath, $receiptPath)) {
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
    $intent = [ordered]@{
        Contract = 'SqlServerLab.ReleasePublication/1.0'; Status = 'PENDING'; ReleaseId = $releaseId; SourceCommit = $releaseCommit
        StageDirectory = [IO.Path]::GetFileName($stageRoot); CreateArchive = [bool]$CreateArchive; IncludeHashManifest = [bool]$IncludeHashManifest
    }
    Write-ReleaseRecord $intentPath $stageRoot $intent
    $publishedPaths.Add($intentPath)
    $intentHash = (Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant()
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

    $packageRows = @(Get-ReleaseFileRows $packageRoot)
    $archiveRows = @()
    if ($CreateArchive) {
        foreach ($path in @($stagedArchive, $(if ($IncludeHashManifest) { $stagedArchive + '.sha256' })) | Where-Object { $_ }) {
            $archiveRows += [PSCustomObject]@{ Path = [IO.Path]::GetFileName($path); Size = (Get-Item -LiteralPath $path -Force).Length; HashAlgorithm = 'SHA256'; Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
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
    if ((@(Get-ReleaseFileRows $releaseRoot) | ConvertTo-Json -Depth 4 -Compress) -cne ($packageRows | ConvertTo-Json -Depth 4 -Compress)) { throw 'RELEASE_PUBLICATION_BYTES_CHANGED' }
    foreach ($row in $archiveRows) {
        $path = Join-Path $outputDirectory $row.Path
        Assert-ReleasePath $path $outputDirectory
        if ((Get-Item -LiteralPath $path -Force).Length -ne $row.Size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $row.Hash) { throw 'RELEASE_PUBLICATION_BYTES_CHANGED' }
    }
    if ((Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $intentHash) { throw 'RELEASE_PUBLICATION_INTENT_CHANGED' }
    $receipt = [ordered]@{
        Contract = $intent.Contract; Status = 'COMPLETED'; ReleaseId = $releaseId; SourceCommit = $releaseCommit; StageDirectory = $intent.StageDirectory
        CreateArchive = [bool]$CreateArchive; IncludeHashManifest = [bool]$IncludeHashManifest; IntentSha256 = $intentHash; PackageFiles = $packageRows; ArchiveFiles = $archiveRows
    }
    Write-ReleaseRecord $receiptPath $stageRoot $receipt
    $publishedPaths.Add($receiptPath)
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
    PublicationStatus = 'COMPLETED'
    PublicationReceipt = $receiptPath
}
