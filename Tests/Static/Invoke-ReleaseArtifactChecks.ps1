#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $temporaryParent ('sql-lab-release-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $fixtureRoot 'synthetic'
$sourceTool = Join-Path $repoRoot 'Tools/Prepare-LocalRelease.ps1'

function Invoke-FixtureGit {
    param([string]$Root, [string[]]$Arguments)
    $result = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'SYNTHETIC_RELEASE_GIT_FAILED' }
    return $result
}

function Set-FixtureIdentity {
    param([string]$Root)
    Invoke-FixtureGit $Root @('config','user.name','Synthetic Release Test') | Out-Null
    Invoke-FixtureGit $Root @('config','user.email','synthetic-release') | Out-Null
    Invoke-FixtureGit $Root @('config','commit.gpgsign','false') | Out-Null
    Invoke-FixtureGit $Root @('config','core.hooksPath', (Join-Path $fixtureRoot 'empty-hooks')) | Out-Null
}

function Write-FixtureFile {
    param([string]$RelativePath, [string]$Content)
    $target = Join-Path $fixture $RelativePath
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
    [IO.File]::WriteAllText($target, $Content)
}

function Invoke-FixtureRelease {
    param([string]$Root, [string]$Output, [switch]$Preview, [switch]$NoArchive)
    try {
        $result = & (Join-Path $Root 'Tools/Prepare-LocalRelease.ps1') -OutputRoot $Output `
            -CreateArchive:(-not $NoArchive) -IncludeHashManifest -SkipReadinessChecks -WhatIf:$Preview -ErrorAction Stop
        [PSCustomObject]@{ Success = $true; Result = $result; ErrorId = '' }
    }
    catch { [PSCustomObject]@{ Success = $false; Result = $null; ErrorId = $_.FullyQualifiedErrorId } }
}

try {
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'Tools')) | Out-Null
    Invoke-FixtureGit $fixture @('init','--quiet') | Out-Null
    Set-FixtureIdentity $fixture
    Copy-Item -LiteralPath $sourceTool -Destination (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1')
    Write-FixtureFile '.gitignore' ".artifacts/`n"
    Write-FixtureFile 'SqlServerLab.psd1' "@{ RootModule = 'SqlServerLab.psm1'; ModuleVersion = '0.1.0'; FunctionsToExport = @('Get-SyntheticReleaseMarker') }"
    Write-FixtureFile 'SqlServerLab.psm1' "function Get-SyntheticReleaseMarker { 'synthetic-release' }"
    Write-FixtureFile 'Tests/Static/Invoke-ReleaseReadinessChecks.ps1' "Write-Host 'synthetic-readiness'; exit 0"
    Write-FixtureFile 'CHANGELOG.md' ("## {0}`n`nSynthetic release note.`n" -f (Get-Date -Format 'yyyy-MM-dd'))
    Write-FixtureFile '.hidden/payload.txt' 'synthetic-hidden-payload'
    $excluded = @('.state/value.json','.runtime/value.json','.secrets/value.json','.artifacts/value.json',
        '.cache/value.json','.local/value.json','.vscode/value.json','.env','.env.private','fixture.bak','fixture.pfx',
        '.idea/value.json','Media/local/value.json','fixture.crt','fixture.tar.gz')
    foreach ($path in $excluded) { Write-FixtureFile $path 'synthetic-private-marker' }
    Invoke-FixtureGit $fixture @('add','--force','.') | Out-Null
    Invoke-FixtureGit $fixture @('commit','--quiet','-m','Codex: Create synthetic release fixture') | Out-Null
    $sourceCommit = [string](Invoke-FixtureGit $fixture @('rev-parse','HEAD'))

    $preview = Invoke-FixtureRelease $fixture '.artifacts/preview' -Preview
    Add-CheckResult 'Release-WhatIf beendet sich erfolgreich ohne Zielverzeichnis' ($preview.Success -and -not (Test-Path (Join-Path $fixture '.artifacts/preview'))) -Message $preview.ErrorId
    Write-FixtureFile '.artifacts/output-file' 'synthetic-preserve'
    $fileTarget = Invoke-FixtureRelease $fixture '.artifacts/output-file'
    Add-CheckResult 'Datei statt Zielverzeichnis bleibt vor Mutation unveraendert' (-not $fileTarget.Success -and
        $fileTarget.ErrorId -match 'RELEASE_OUTPUT_NOT_DIRECTORY' -and
        [IO.File]::ReadAllText((Join-Path $fixture '.artifacts/output-file')) -eq 'synthetic-preserve')

    Write-FixtureFile 'untracked.txt' 'synthetic-untracked-payload'
    $untracked = Invoke-FixtureRelease $fixture '.artifacts/untracked'
    Add-CheckResult 'Nicht versionierte Quelldateien blockieren vor dem Schreiben' (-not $untracked.Success -and -not (Test-Path (Join-Path $fixture '.artifacts/untracked')))
    Remove-Item -LiteralPath (Join-Path $fixture 'untracked.txt')
    Write-FixtureFile 'SqlServerLab.psm1' 'synthetic-dirty-source'
    $dirty = Invoke-FixtureRelease $fixture '.artifacts/dirty'
    Add-CheckResult 'Geaenderte versionierte Quellen blockieren vor dem Schreiben' (-not $dirty.Success -and -not (Test-Path (Join-Path $fixture '.artifacts/dirty')))
    Invoke-FixtureGit $fixture @('restore','--source=HEAD','--','SqlServerLab.psm1') | Out-Null

    $clean = Invoke-FixtureRelease $fixture '.artifacts/clean'
    Add-CheckResult 'Sauberer Quellstand erzeugt ein Release mit Archiv' ($clean.Success -and (Test-Path -LiteralPath $clean.Result.Archive -PathType Leaf)) -Message $clean.ErrorId
    if ($clean.Success) {
        $release = $clean.Result
        $inspection = & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId
        Add-CheckResult 'Atomare Quittung attestiert Paket ZIP und Archivhash vollstaendig' ($release.PublicationStatus -ceq 'COMPLETED' -and
            (Test-Path -LiteralPath $release.PublicationReceipt -PathType Leaf) -and $inspection.PublicationStatus -ceq 'COMPLETED' -and
            -not $inspection.Mutation -and $inspection.Actions.Count -eq 0 -and -not $inspection.StagePresent -and $inspection.ProcessStatus -ceq 'NOT_CHECKED')
        $receiptBytes = [IO.File]::ReadAllBytes($release.PublicationReceipt)
        $receipt = [Text.UTF8Encoding]::new($false, $true).GetString($receiptBytes) | ConvertFrom-Json
        Add-CheckResult 'Quittung bindet saemtliche Paketdateien und exakt beide Archivdateien ohne Hostpfade' (
            $receipt.PackageFiles.Count -eq @(Get-ChildItem -LiteralPath $release.ReleaseRoot -Recurse -File -Force).Count -and
            $receipt.ArchiveFiles.Count -eq 2 -and [Text.UTF8Encoding]::new($false).GetString($receiptBytes) -notmatch [regex]::Escape($fixtureRoot))
        $savedReceipt = $release.PublicationReceipt + '.held'
        [IO.File]::Move($release.PublicationReceipt, $savedReceipt)
        try {
            $incomplete = & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId
            Add-CheckResult 'Vorhandene Paketbytes ohne Abschlussquittung bleiben INCOMPLETE' ($incomplete.PublicationStatus -ceq 'INCOMPLETE' -and -not $incomplete.Mutation -and $incomplete.Actions.Count -eq 0)
        }
        finally { [IO.File]::Move($savedReceipt, $release.PublicationReceipt) }
        $moduleFile = Join-Path $release.ReleaseRoot 'SqlServerLab.psm1'
        $moduleBytes = [IO.File]::ReadAllBytes($moduleFile)
        [IO.File]::WriteAllText($moduleFile, 'synthetic-changed-after-completion')
        try {
            $rejected = $false
            try { & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId | Out-Null }
            catch { $rejected = $_.FullyQualifiedErrorId -match 'RELEASE_PUBLICATION_BYTES_CHANGED' }
            Add-CheckResult 'Geaenderte Paketbytes verlieren ihre Abschlussattestierung' $rejected
        }
        finally { [IO.File]::WriteAllBytes($moduleFile, $moduleBytes) }
        $invalidReceipt = [Text.UTF8Encoding]::new($false).GetString($receiptBytes) | ConvertFrom-Json
        $invalidReceipt.PackageFiles[0].Path = '../outside-sentinel'
        [IO.File]::WriteAllText($release.PublicationReceipt, ($invalidReceipt | ConvertTo-Json -Depth 8))
        try {
            $rejected = $false
            try { & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId | Out-Null }
            catch { $rejected = $_.FullyQualifiedErrorId -match 'RELEASE_RECORD_ROWS_INVALID' }
            Add-CheckResult 'Traversal in einer Quittung blockiert vor Dateiinspektion' $rejected
        }
        finally { [IO.File]::WriteAllBytes($release.PublicationReceipt, $receiptBytes) }
        [IO.File]::WriteAllBytes($release.PublicationReceipt, [byte[]]::new(4MB + 1))
        try {
            $rejected = $false
            try { & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId | Out-Null }
            catch { $rejected = $_.FullyQualifiedErrorId -match 'RELEASE_RECORD_LIMIT' }
            Add-CheckResult 'Recordgroesse wird am begrenzten Readstream vor JSON-Interpretation abgefangen' $rejected
        }
        finally { [IO.File]::WriteAllBytes($release.PublicationReceipt, $receiptBytes) }
        $archiveBytes = [IO.File]::ReadAllBytes($release.Archive)
        $changedArchive = [byte[]]$archiveBytes.Clone()
        $changedArchive[0] = $changedArchive[0] -bxor 1
        [IO.File]::WriteAllBytes($release.Archive, $changedArchive)
        try {
            $rejected = $false
            try { & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId | Out-Null }
            catch { $rejected = $_.FullyQualifiedErrorId -match 'RELEASE_PUBLICATION_BYTES_CHANGED' }
            Add-CheckResult 'Archivdrift gleicher Laenge verliert die Abschlussattestierung' $rejected
        }
        finally { [IO.File]::WriteAllBytes($release.Archive, $archiveBytes) }
        $emptyTarget = Join-Path $fixtureRoot 'empty-inspection-target'
        [IO.Directory]::CreateDirectory($emptyTarget) | Out-Null
        $emptyLink = Join-Path $release.ReleaseRoot 'unknown-empty-link'
        New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $emptyLink -Target $emptyTarget | Out-Null
        try {
            $rejected = $false
            try { & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId | Out-Null }
            catch { $rejected = $_.FullyQualifiedErrorId -match 'RELEASE_REPARSE_PATH_BLOCKED' }
            Add-CheckResult 'Leerer Reparsepunkt im Paket blockiert ohne Folgen des Links' ($rejected -and @(Get-ChildItem -LiteralPath $emptyTarget -Force).Count -eq 0)
        }
        finally { Remove-Item -LiteralPath $emptyLink -Force }
        Write-FixtureFile 'untracked-inspection.txt' 'synthetic-dirty-source-without-release-effect'
        try {
            $inspection = & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/clean' -InspectReleaseId $release.ReleaseId
            Add-CheckResult 'Rein lesende Inspektion verlangt weder sauberes Git noch Readiness' ($inspection.PublicationStatus -ceq 'COMPLETED')
        }
        finally { Remove-Item -LiteralPath (Join-Path $fixture 'untracked-inspection.txt') }
        $unpacked = Join-Path $fixtureRoot 'unpacked'
        [IO.Compression.ZipFile]::ExtractToDirectory($release.Archive, $unpacked)
        if ($IsWindows) {
            # Windows bildet die implizit versteckte Unix-Dotdatei explizit nach.
            $hiddenFixture = Join-Path $unpacked '.gitignore'
            [IO.File]::SetAttributes($hiddenFixture, ([IO.File]::GetAttributes($hiddenFixture) -bor [IO.FileAttributes]::Hidden))
        }
        $manifest = Get-Content -LiteralPath (Join-Path $unpacked 'ReleaseManifest.json') -Raw | ConvertFrom-Json
        $notes = Get-Content -LiteralPath (Join-Path $unpacked 'ReleaseNotes.md') -Raw
        Add-CheckResult 'Paketmetadaten binden den Quellcommit ohne lokale Hostpfade' (
            $manifest.SourceCommit -eq $sourceCommit -and -not $manifest.RepositoryDirty -and $manifest.ReleaseReadinessCheck -eq 'SKIPPED' -and
            $notes -notmatch [regex]::Escape($fixtureRoot) -and
            ($manifest | ConvertTo-Json -Depth 20) -notmatch [regex]::Escape($fixtureRoot))
        Add-CheckResult 'Changelog-Datum ist vom Release-ID-Datumsformat getrennt' ($notes -match 'Synthetic release note' -and $manifest.ChangelogDate -match '^\d{4}-\d{2}-\d{2}$')
        Add-CheckResult 'Sensible Pfadklassen fehlen auch bei absichtlicher Versionierung' (@($excluded | Where-Object { Test-Path -LiteralPath (Join-Path $unpacked $_) }).Count -eq 0)
        Add-CheckResult 'Versionierte versteckte Nutzdateien bleiben im Archiv enthalten' ([IO.File]::ReadAllText((Join-Path $unpacked '.hidden/payload.txt')) -eq 'synthetic-hidden-payload')
        $invalidRows = @($manifest.IncludedFiles | Where-Object {
            $file = Join-Path $unpacked $_.Path
            -not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $_.Hash -or (Get-Item -LiteralPath $file -Force).Length -ne $_.Size
        })
        Add-CheckResult 'Jeder Manifest-Eintrag besitzt passende Groesse und SHA-256' ($invalidRows.Count -eq 0 -and $manifest.ArtifactCount -eq @($manifest.IncludedFiles).Count)
        $hashLines = @(Get-Content -LiteralPath (Join-Path $unpacked 'ReleaseHashes.txt'))
        $invalidHashes = @($hashLines | Where-Object {
            if ($_ -notmatch '^([a-f0-9]{64})  (.+)$') { return $true }
            $expected = $Matches[1]; $file = Join-Path $unpacked $Matches[2]
            -not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $expected
        })
        Add-CheckResult 'Hashliste stimmt im entpackten Paket einschliesslich ReleaseManifest' ($invalidHashes.Count -eq 0 -and @($hashLines | Where-Object { $_ -match '  ReleaseManifest.json$' }).Count -eq 1)
        $archiveHash = (Get-FileHash -LiteralPath $release.Archive -Algorithm SHA256).Hash.ToLowerInvariant()
        Add-CheckResult 'Archivhash bezieht sich auf die unveraenderte fertige ZIP-Datei' ((Get-Content -LiteralPath ($release.Archive + '.sha256') -Raw).StartsWith($archiveHash + '  '))
        $syntheticModule = Import-Module (Join-Path $unpacked 'SqlServerLab.psd1') -Force -PassThru
        try { Add-CheckResult 'Entpacktes synthetisches Modul ist ausfuehrbar' ((Get-SyntheticReleaseMarker) -eq 'synthetic-release') }
        finally { Remove-Module $syntheticModule.Name -Force }
    }

    $withoutArchive = Invoke-FixtureRelease $fixture '.artifacts/no-archive' -NoArchive
    Add-CheckResult 'Hashliste funktioniert auch ohne ZIP-Option' ($withoutArchive.Success -and $withoutArchive.Result.Archive -eq '' -and (Test-Path -LiteralPath $withoutArchive.Result.HashManifest))
    $inspection = & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/no-archive' -InspectReleaseId $withoutArchive.Result.ReleaseId
    Add-CheckResult 'Abschlussquittung ohne ZIP wird ohne erfundene Archivfiles geprueft' ($inspection.PublicationStatus -ceq 'COMPLETED' -and
        (Get-Content -LiteralPath $withoutArchive.Result.PublicationReceipt -Raw | ConvertFrom-Json).ArchiveFiles.Count -eq 0)
    $unattested = & (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/unregistered-release' -InspectReleaseId 'sqlserverlab-v0.1.0-20261007-000000-00000000'
    Add-CheckResult 'Unbekannte Legacy-Veröffentlichung bleibt NOT_ATTESTED ohne Zielanlage' ($unattested.PublicationStatus -ceq 'NOT_ATTESTED' -and
        -not (Test-Path -LiteralPath (Join-Path $fixture '.artifacts/unregistered-release')) -and -not $unattested.Mutation -and $unattested.Actions.Count -eq 0)
    $withReadiness = @(& (Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1') -OutputRoot '.artifacts/readiness')
    Add-CheckResult 'Readiness-Ausgabe veraendert das strukturierte Release-Ergebnis nicht' ($withReadiness.Count -eq 1 -and
        (Get-Content -LiteralPath (Join-Path $withReadiness[0].ReleaseRoot 'ReleaseManifest.json') -Raw | ConvertFrom-Json).ReleaseReadinessCheck -eq 'PASSED')

    $redirectTarget = Join-Path $fixtureRoot 'redirect-target'
    [IO.Directory]::CreateDirectory($redirectTarget) | Out-Null
    [IO.File]::WriteAllText((Join-Path $redirectTarget 'sentinel.txt'), 'synthetic-preserve')
    $redirectPath = Join-Path $fixture '.artifacts/redirect'
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $redirectPath -Target $redirectTarget | Out-Null
    $redirected = Invoke-FixtureRelease $fixture '.artifacts/redirect/release'
    Add-CheckResult 'Umgeleitetes Ziel wird vor Mutation abgelehnt' (-not $redirected.Success -and
        @(Get-ChildItem -LiteralPath $redirectTarget -Force).Count -eq 1 -and
        [IO.File]::ReadAllText((Join-Path $redirectTarget 'sentinel.txt')) -eq 'synthetic-preserve')
    Remove-Item -LiteralPath $redirectPath -Force

    # Fehler unmittelbar nach der Archivpublikation in der isolierten Kopie injizieren.
    $fixtureTool = Join-Path $fixture 'Tools/Prepare-LocalRelease.ps1'
    $toolText = [IO.File]::ReadAllText($fixtureTool)
    $publishCall = '[IO.Directory]::Move($packageRoot, $releaseRoot)'
    if (-not $toolText.Contains($publishCall)) { throw 'SYNTHETIC_RELEASE_FAULT_POINT_MISSING' }
    [IO.File]::WriteAllText($fixtureTool, $toolText.Replace($publishCall, "throw 'SYNTHETIC_RELEASE_PUBLISH_FAILURE'"))
    Invoke-FixtureGit $fixture @('add','Tools/Prepare-LocalRelease.ps1') | Out-Null
    Invoke-FixtureGit $fixture @('commit','--quiet','-m','Codex: Inject synthetic release publication failure') | Out-Null
    $partialRoot = Join-Path $fixture '.artifacts/partial'
    [IO.Directory]::CreateDirectory($partialRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $partialRoot 'sentinel.txt'), 'synthetic-preserve')
    $partial = Invoke-FixtureRelease $fixture '.artifacts/partial'
    Add-CheckResult 'Teilpublikation entfernt nur eigene Artefakte und erhaelt vorhandene Dateien' (-not $partial.Success -and
        $partial.ErrorId -match 'SYNTHETIC_RELEASE_PUBLISH_FAILURE' -and
        @(Get-ChildItem -LiteralPath $partialRoot -Force).Count -eq 1 -and
        [IO.File]::ReadAllText((Join-Path $partialRoot 'sentinel.txt')) -eq 'synthetic-preserve')
    Invoke-FixtureGit $fixture @('restore',('--source=' + $sourceCommit),'--','Tools/Prepare-LocalRelease.ps1') | Out-Null
    Invoke-FixtureGit $fixture @('add','Tools/Prepare-LocalRelease.ps1') | Out-Null
    Invoke-FixtureGit $fixture @('commit','--quiet','-m','Codex: Restore synthetic release fixture') | Out-Null

    # Der eigene Kindprozess wird hart beendet: finally kann keine Ruecknahme liefern.
    $crashPoints = @(
        @{ Name = 'before-archive'; Call = '[IO.File]::Move($stagedArchive, $archivePath)'; Archives = 0; Packages = 0; Receipts = 0; Status = 'INCOMPLETE' }
        @{ Name = 'before-package'; Call = '[IO.Directory]::Move($packageRoot, $releaseRoot)'; Archives = 1; Packages = 0; Receipts = 0; Status = 'INCOMPLETE' }
        @{ Name = 'before-receipt'; Call = 'Write-ReleaseRecord $receiptPath $stageRoot $receipt'; Archives = 1; Packages = 1; Receipts = 0; Status = 'INCOMPLETE' }
        @{ Name = 'after-receipt'; Call = '$completed = $true'; Archives = 1; Packages = 1; Receipts = 1; Status = 'COMPLETED' }
    )
    $originalTool = [IO.File]::ReadAllText($fixtureTool)
    $pwshPath = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    foreach ($point in $crashPoints) {
        if (([regex]::Matches($originalTool, [regex]::Escape($point.Call))).Count -ne 1) { throw 'SYNTHETIC_RELEASE_CRASH_POINT_NOT_UNIQUE' }
        [IO.File]::WriteAllText($fixtureTool, $originalTool.Replace($point.Call, ('[Diagnostics.Process]::GetCurrentProcess().Kill(); ' + $point.Call)))
        Invoke-FixtureGit $fixture @('add','Tools/Prepare-LocalRelease.ps1') | Out-Null
        Invoke-FixtureGit $fixture @('commit','--quiet','-m',('Codex: Inject own hard abort ' + $point.Name)) | Out-Null
        $crashOutput = '.artifacts/crash-' + $point.Name
        $childOutput = @(& $pwshPath -NoProfile -File $fixtureTool -OutputRoot $crashOutput -CreateArchive -IncludeHashManifest -SkipReadinessChecks 2>&1)
        $childExit = $LASTEXITCODE
        $crashRoot = Join-Path $fixture $crashOutput
        $entries = @(Get-ChildItem -LiteralPath $crashRoot -Force)
        $intents = @($entries | Where-Object Name -Like '*.publication.json')
        if ($intents.Count -ne 1) { throw 'SYNTHETIC_RELEASE_CRASH_INTENT_MISSING' }
        $intent = Get-Content -LiteralPath $intents[0].FullName -Raw | ConvertFrom-Json
        $beforeHashes = @(Get-ChildItem -LiteralPath $crashRoot -Recurse -File -Force | Get-FileHash -Algorithm SHA256 | Sort-Object Path | Select-Object Path, Hash) | ConvertTo-Json -Compress
        $inspection = & $fixtureTool -OutputRoot $crashOutput -InspectReleaseId $intent.ReleaseId
        $afterHashes = @(Get-ChildItem -LiteralPath $crashRoot -Recurse -File -Force | Get-FileHash -Algorithm SHA256 | Sort-Object Path | Select-Object Path, Hash) | ConvertTo-Json -Compress
        Add-CheckResult ('Harter Own-Abbruch ' + $point.Name + ' bindet den tatsaechlichen Quittungszustand') ($childExit -ne 0 -and
            @($entries | Where-Object Name -Like '*.completed.json').Count -eq $point.Receipts -and
            @($entries | Where-Object Name -Like '*.zip').Count -eq $point.Archives -and
            @($entries | Where-Object { $_.PSIsContainer -and $_.Name -like 'sqlserverlab-v*' }).Count -eq $point.Packages)
        Add-CheckResult ('Harter Own-Abbruch ' + $point.Name + ' wird rein lesend ohne behauptetes Prozesscleanup erkannt') ($inspection.PublicationStatus -ceq $point.Status -and
            $inspection.StagePresent -and $inspection.ProcessStatus -ceq 'NOT_CHECKED' -and -not $inspection.Mutation -and $inspection.Actions.Count -eq 0 -and $beforeHashes -ceq $afterHashes)
    }
    [IO.File]::WriteAllText($fixtureTool, $originalTool)
    Invoke-FixtureGit $fixture @('add','Tools/Prepare-LocalRelease.ps1') | Out-Null
    Invoke-FixtureGit $fixture @('commit','--quiet','-m','Codex: Restore tool after own hard aborts') | Out-Null

    # Git kann einen Symlink auch auf Hosts ohne native Symlink-Erzeugung abbilden.
    Invoke-FixtureGit $fixture @('config','core.symlinks','false') | Out-Null
    Write-FixtureFile 'synthetic-link' 'outside-synthetic-target'
    $linkBlob = [string](Invoke-FixtureGit $fixture @('hash-object','-w','synthetic-link'))
    Invoke-FixtureGit $fixture @('update-index','--add','--cacheinfo',"120000,$linkBlob,synthetic-link") | Out-Null
    Invoke-FixtureGit $fixture @('commit','--quiet','-m','Codex: Add synthetic symlink rejection fixture') | Out-Null
    $unsafe = Invoke-FixtureRelease $fixture '.artifacts/unsafe'
    $unsafeChildren = @(Get-ChildItem -LiteralPath (Join-Path $fixture '.artifacts/unsafe') -Force -ErrorAction SilentlyContinue)
    Add-CheckResult 'Symlink im Git-Snapshot blockiert und hinterlaesst kein Teilpaket' (-not $unsafe.Success -and $unsafeChildren.Count -eq 0)

    $realFixture = Join-Path $fixtureRoot 'module-source'
    & git clone --quiet --local --no-hardlinks $repoRoot $realFixture 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'SYNTHETIC_RELEASE_CLONE_FAILED' }
    Set-FixtureIdentity $realFixture
    Copy-Item -LiteralPath $sourceTool -Destination (Join-Path $realFixture 'Tools/Prepare-LocalRelease.ps1') -Force
    Invoke-FixtureGit $realFixture @('add','Tools/Prepare-LocalRelease.ps1') | Out-Null
    Invoke-FixtureGit $realFixture @('commit','--quiet','--allow-empty','-m','Codex: Bind release tool to local module fixture') | Out-Null
    $real = Invoke-FixtureRelease $realFixture '.artifacts/release'
    Add-CheckResult 'Realer Modulquellstand erzeugt ein portables Release-Archiv' $real.Success -Message $real.ErrorId
    if ($real.Success) {
        $modulePackage = Join-Path $fixtureRoot 'module-unpacked'
        [IO.Compression.ZipFile]::ExtractToDirectory($real.Result.Archive, $modulePackage)
        $expectedExports = @((Import-PowerShellDataFile (Join-Path $realFixture 'SqlServerLab.psd1')).FunctionsToExport)
        $packagedModule = Import-Module (Join-Path $modulePackage 'SqlServerLab.psd1') -Force -PassThru
        try { Add-CheckResult 'Reales entpacktes Modul importiert mit allen deklarierten Exporten' (@($expectedExports | Where-Object { -not $packagedModule.ExportedFunctions.ContainsKey($_) }).Count -eq 0) }
        finally { Remove-Module $packagedModule.Name -Force }
    }
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $prefix = $temporaryParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedFixture) -notmatch '^sql-lab-release-[a-f0-9]{32}$') { throw 'SYNTHETIC_RELEASE_CLEANUP_SCOPE_INVALID' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}

Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL"
if ($failures.Count -gt 0) { exit 1 }
exit 0
