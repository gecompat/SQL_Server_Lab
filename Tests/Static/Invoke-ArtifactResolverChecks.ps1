#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Trust Store, inhaltsadressierten Cache, Quarantaene und Artifact Lock.
.DESCRIPTION
    Der Test verwendet ausschliesslich temporaere, synthetische Dateien und
    startet keinen Download, keine Container-Runtime und keinen SQL Server.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Artifact Resolver Checks' -ForegroundColor Cyan

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-artifact-check-$([guid]::NewGuid().ToString('N'))"
try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    $result = & $module {
        param($StateRoot)

        $paths = Initialize-LabArtifactStore -StateRoot $StateRoot
        $payloadPath = Join-Path $StateRoot 'synthetic-artifact.bak'
        [System.IO.File]::WriteAllBytes($payloadPath, [byte[]](0x53, 0x51, 0x4C, 0x2D, 0x4C, 0x41, 0x42))
        $sha256 = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $source = 'https://example.invalid/samples/synthetic-artifact.bak'

        $trust = Register-LabArtifactTrustRecord `
            -Source $source `
            -Sha256 $sha256 `
            -SampleId 'synthetic-sample' `
            -SampleVariant 'unit' `
            -StateRoot $StateRoot
        $resolvedTrust = Get-LabArtifactTrustRecord `
            -Source $source `
            -SampleId 'synthetic-sample' `
            -SampleVariant 'unit' `
            -StateRoot $StateRoot

        $cacheDirectory = Join-Path $paths.CacheRoot $sha256
        New-Item -Path $cacheDirectory -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $payloadPath -Destination (Join-Path $cacheDirectory 'artifact.bak')
        Write-LabArtifactJsonAtomic -Path (Join-Path $cacheDirectory 'metadata.json') -InputObject ([PSCustomObject]@{
            formatVersion = '1'
            source = $source
            sha256 = $sha256
            integrityOrigin = 'user-trusted-generated'
        })
        $cache = Get-LabArtifactCacheEntry -Sha256 $sha256 -StateRoot $StateRoot

        $runDirectory = Join-Path $StateRoot 'runs/test-run'
        New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
        $artifact = [PSCustomObject]@{
            Source = $source
            Sha256 = $sha256
            IntegrityOrigin = 'user-trusted-generated'
            ArtifactType = 'backup'
            SampleId = 'synthetic-sample'
            SampleVariant = 'unit'
            HandlerContractVersion = '1'
            Compatibility = 170
            ExpectedOutputs = @([PSCustomObject]@{ name = 'SyntheticSample'; kind = 'database' })
        }
        $lockPath = Add-LabArtifactManifestLockEntry -RunDirectory $runDirectory -Artifact $artifact
        $portableLockPath = Join-Path $StateRoot 'portable-manifest.lock.json'
        Export-LabPortableArtifactLock -RunDirectory $runDirectory -Path $portableLockPath | Out-Null
        $portableLock = Get-Content -LiteralPath $portableLockPath -Raw -Encoding utf8

        $nonInteractive = Resolve-LabArtifact `
            -Source 'https://example.invalid/samples/unknown.bak' `
            -NonInteractive `
            -StateRoot $StateRoot
        $cachedResolution = Resolve-LabArtifact `
            -Source $source `
            -SampleId 'synthetic-sample' `
            -SampleVariant 'unit' `
            -NonInteractive `
            -StateRoot $StateRoot
        $sevenZipTrust = Resolve-LabArtifact `
            -Source 'https://example.invalid/samples/unknown.7z' `
            -ArtifactType 'archive-backup' `
            -NonInteractive `
            -StateRoot $StateRoot

        [PSCustomObject]@{
            StoreCreated = (Test-Path -LiteralPath $paths.TrustStorePath -PathType Leaf)
            TrustMatches = $trust.sha256 -eq $resolvedTrust.sha256 -and $trust.integrityOrigin -eq 'user-trusted-generated'
            CacheMatches = $cache -and $cache.Sha256 -eq $sha256
            LockCreated = (Test-Path -LiteralPath $lockPath -PathType Leaf)
            PortableLockSafe = $portableLock -notmatch '(?i)(stateRoot|runDirectory|connectionString|password|hostPath)'
            TrustRequired = $nonInteractive.Status -eq 'TRUST_REQUIRED'
            CacheResolutionReady = $cachedResolution.Status -eq 'ARTIFACT_READY' -and $cachedResolution.CacheStatus -eq 'HIT'
            SevenZipTrustRequired = $sevenZipTrust.Status -eq 'TRUST_REQUIRED'
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Trust Store wird lokal und versioniert angelegt' -Success $result.StoreCreated
    Add-CheckResult -Name 'Expliziter Trust Record behaelt SHA-256 und Origin' -Success $result.TrustMatches
    Add-CheckResult -Name 'Inhaltsadressierter Cache wird gegen seinen Digest validiert' -Success $result.CacheMatches
    Add-CheckResult -Name 'Run Lock wird vor Installationsschritten erzeugt' -Success $result.LockCreated
    Add-CheckResult -Name 'Portables Lock enthaelt keine Runtime- oder Secretfelder' -Success $result.PortableLockSafe
    Add-CheckResult -Name 'Nicht interaktive Aufloesung ohne Hash endet mit TRUST_REQUIRED' -Success $result.TrustRequired
    Add-CheckResult -Name 'Bekannter Trust nutzt den verifizierten Content Cache' -Success $result.CacheResolutionReady
    Add-CheckResult -Name 'Katalogisierte .7z-Archive passieren den sicheren Artifact-Vertrag' -Success $result.SevenZipTrustRequired
}
catch {
    Add-CheckResult -Name 'Artifact Resolver Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
