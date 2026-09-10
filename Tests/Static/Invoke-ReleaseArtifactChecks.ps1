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
        $unpacked = Join-Path $fixtureRoot 'unpacked'
        [IO.Compression.ZipFile]::ExtractToDirectory($release.Archive, $unpacked)
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
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $_.Hash -or (Get-Item -LiteralPath $file).Length -ne $_.Size
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
