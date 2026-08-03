#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-hyperv-registry-$([guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $temporaryRoot 'state'
$runDirectory = Join-Path $temporaryRoot 'run'
$sourcePath = Join-Path $temporaryRoot 'synthetic.vhdx'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Hyper-V Image Registry Checks' -ForegroundColor Cyan

try {
    New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
    $payload = [byte[]]::new(4096)
    [System.Text.Encoding]::ASCII.GetBytes('vhdxfile').CopyTo($payload, 0)
    [System.IO.File]::WriteAllBytes($sourcePath, $payload)
    (Get-Item -LiteralPath $sourcePath).IsReadOnly = $true
    $sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    $result = & $module {
        param($SourcePath, $Sha256, $StateRoot, $RunDirectory)
        $artifact = Import-HyperVImageArtifact `
            -VhdxPath $SourcePath -ExpectedSha256 $Sha256 `
            -ArtifactState LIFECYCLE_TEST_ONLY `
            -OperatingSystemId synthetic-ci -OperatingSystemVersion 1 -Edition none `
            -InstallationType synthetic -LicenseType test-only -IntegrityOrigin synthetic-test `
            -StateRoot $StateRoot
        $again = Import-HyperVImageArtifact `
            -VhdxPath $SourcePath -ExpectedSha256 $Sha256 `
            -ArtifactState LIFECYCLE_TEST_ONLY `
            -OperatingSystemId synthetic-ci -OperatingSystemVersion 1 -Edition none `
            -InstallationType synthetic -LicenseType test-only -IntegrityOrigin synthetic-test `
            -StateRoot $StateRoot
        $selection = Resolve-HyperVImageArtifact `
            -OperatingSystemId synthetic-ci -OperatingSystemVersion 1 -Edition none `
            -InstallationType synthetic -StateRoot $StateRoot
        $lockPath = Add-HyperVImageManifestLockEntry -RunDirectory $RunDirectory -Artifact $artifact
        [PSCustomObject]@{ Artifact = $artifact; Again = $again; Selection = $selection; LockPath = $lockPath }
    } $sourcePath $sha256 $stateRoot $runDirectory

    Add-CheckResult -Name 'Artifact-ID ist inhaltsadressiert' -Success ($result.Artifact.artifactId -match $sha256.ToLowerInvariant())
    Add-CheckResult -Name 'Registry kopiert Parent in lokalen Store' -Success (Test-Path -LiteralPath $result.Artifact.Path -PathType Leaf)
    Add-CheckResult -Name 'Registry-Parent ist read-only' -Success ((Get-Item -LiteralPath $result.Artifact.Path).IsReadOnly)
    Add-CheckResult -Name 'Import ist idempotent' -Success ($result.Again.artifactId -eq $result.Artifact.artifactId)
    Add-CheckResult -Name 'Test-Artifact wird nie als reale Baseline gewaehlt' -Success ($result.Selection.Status -eq 'BASELINE_NOT_COMPATIBLE')
    Add-CheckResult -Name 'Resolver begruendet Test-Ausschluss' -Success ($result.Selection.Rejected[0].Reasons -contains 'test-only')

    $lock = Get-Content -LiteralPath $result.LockPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    Add-CheckResult -Name 'Manifest Lock speichert Artifact-ID' -Success ($lock.artifacts[0].artifactId -eq $result.Artifact.artifactId)
    Add-CheckResult -Name 'Manifest Lock enthaelt keinen Hostpfad' -Success (($lock | ConvertTo-Json -Depth 30) -notmatch [regex]::Escape($temporaryRoot))

    $generalizationRejected = $false
    try {
        & $module {
            param($SourcePath, $Sha256, $StateRoot)
            Import-HyperVImageArtifact -VhdxPath $SourcePath -ExpectedSha256 $Sha256 `
                -ArtifactState OS_SEALED -OperatingSystemId windows-server `
                -OperatingSystemVersion 2025 -Edition evaluation -LicenseType evaluation `
                -IntegrityOrigin user-verified-local -StateRoot $StateRoot
        } $sourcePath $sha256 (Join-Path $temporaryRoot 'reject-state') | Out-Null
    } catch { $generalizationRejected = $_.Exception.Message -match 'HYPERV_ARTIFACT_NOT_GENERALIZED' }
    Add-CheckResult -Name 'OS_SEALED erfordert Generalisierungsnachweis' -Success $generalizationRejected

    $metadataConflictRejected = $false
    try {
        & $module {
            param($SourcePath, $Sha256, $StateRoot)
            Import-HyperVImageArtifact -VhdxPath $SourcePath -ExpectedSha256 $Sha256 `
                -ArtifactState LIFECYCLE_TEST_ONLY -OperatingSystemId other `
                -OperatingSystemVersion 1 -Edition none -InstallationType synthetic `
                -LicenseType test-only -IntegrityOrigin synthetic-test -StateRoot $StateRoot
        } $sourcePath $sha256 $stateRoot | Out-Null
    } catch { $metadataConflictRejected = $_.Exception.Message -match 'HYPERV_ARTIFACT_METADATA_CONFLICT' }
    Add-CheckResult -Name 'Gleiche Bytes mit widerspruechlichen Metadaten werden abgelehnt' -Success $metadataConflictRejected
}
catch {
    Add-CheckResult -Name 'Hyper-V-Image-Registry-Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $sourcePath) { (Get-Item -LiteralPath $sourcePath).IsReadOnly = $false }
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) { exit 1 }
exit 0
