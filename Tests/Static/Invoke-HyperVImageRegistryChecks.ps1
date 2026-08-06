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
        $renamed = Rename-HyperVImageArtifact -ArtifactId $artifact.artifactId -DisplayName 'Umbenanntes Testimage' -StateRoot $StateRoot
        $selection = Resolve-HyperVImageArtifact `
            -OperatingSystemId synthetic-ci -OperatingSystemVersion 1 -Edition none `
            -InstallationType synthetic -StateRoot $StateRoot
        $lockPath = Add-HyperVImageManifestLockEntry -RunDirectory $RunDirectory -Artifact $artifact
        [PSCustomObject]@{ Artifact = $artifact; Again = $again; Renamed = $renamed; Selection = $selection; LockPath = $lockPath }
    } $sourcePath $sha256 $stateRoot $runDirectory

    Add-CheckResult -Name 'Artifact-ID ist inhaltsadressiert' -Success ($result.Artifact.artifactId -match $sha256.ToLowerInvariant())
    Add-CheckResult -Name 'Registry kopiert Parent in lokalen Store' -Success (Test-Path -LiteralPath $result.Artifact.Path -PathType Leaf)
    Add-CheckResult -Name 'Registry-Parent ist read-only' -Success ((Get-Item -LiteralPath $result.Artifact.Path).IsReadOnly)
    Add-CheckResult -Name 'Import ist idempotent' -Success ($result.Again.artifactId -eq $result.Artifact.artifactId)
    Add-CheckResult -Name 'Anzeigename ist nachträglich änderbar, ohne die Artifact-ID zu ändern' -Success (
        $result.Renamed.displayName -eq 'Umbenanntes Testimage' -and
        $result.Renamed.artifactId -eq $result.Artifact.artifactId -and
        $result.Renamed.sha256 -eq $result.Artifact.sha256
    )
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

    $evaluationExpiry = [datetime]::SpecifyKind([datetime]'2027-01-30T00:00:00', [DateTimeKind]::Utc)
    $evaluationArtifact = & $module {
        param($SourcePath, $Sha256, $StateRoot, $Expiry)
        Import-HyperVImageArtifact -VhdxPath $SourcePath -ExpectedSha256 $Sha256 `
            -ArtifactState OS_SEALED -OperatingSystemId windows-server-2025 `
            -OperatingSystemVersion 2025 -Edition standard-evaluation -InstallationType core `
            -LicenseType evaluation -IntegrityOrigin generated-by-runtime -Generalized `
            -EvaluationExpiresAt $Expiry -StateRoot $StateRoot
    } $sourcePath $sha256 (Join-Path $temporaryRoot 'evaluation-state') $evaluationExpiry
    Add-CheckResult -Name 'Evaluation-Ablaufdatum wird ohne Nullable-Laufzeitfehler registriert' -Success (
        $evaluationArtifact.artifactId -and
        $evaluationArtifact.license.evaluationExpiresAt.ToUniversalTime().ToString('o') -eq '2027-01-30T00:00:00.0000000Z'
    )

    $sqlEvaluationArtifact = & $module {
        param($SourcePath, $Sha256, $StateRoot, $Expiry)
        Import-HyperVImageArtifact -VhdxPath $SourcePath -ExpectedSha256 $Sha256 `
            -ArtifactState SQL_PREPARED_SEALED -OperatingSystemId windows-server-2025 `
            -OperatingSystemVersion 2025 -Edition datacenter-evaluation -InstallationType core `
            -LicenseType evaluation -IntegrityOrigin generated-by-runtime -Generalized -SqlPrepared `
            -SqlVersion 2019 -SqlEdition Evaluation -SqlBuild 15.0.2000.5 `
            -SqlFeatures SQLENGINE,FULLTEXT,REPLICATION -SqlLicenseType evaluation `
            -EvaluationExpiresAt $Expiry -StateRoot $StateRoot
    } $sourcePath $sha256 (Join-Path $temporaryRoot 'sql-evaluation-state') $evaluationExpiry
    Add-CheckResult -Name 'SQL- und OS-Evaluation werden getrennt registriert' -Success (
        $sqlEvaluationArtifact.license.evaluationExpiresAt -and
        $sqlEvaluationArtifact.sql.license.type -eq 'evaluation' -and
        $sqlEvaluationArtifact.sql.license.evaluationStartsAt -eq 'complete-image' -and
        -not $sqlEvaluationArtifact.sql.license.evaluationExpiresAt
    )

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

    $referenceBuildId = [guid]::NewGuid().ToString()
    $referenceDirectory = Join-Path (Join-Path (Join-Path $stateRoot 'image-builds') 'hyperv') $referenceBuildId
    New-Item -Path $referenceDirectory -ItemType Directory -Force | Out-Null
    [PSCustomObject]@{ buildId = $referenceBuildId; state = 'OS_SEALED'; artifact = [PSCustomObject]@{ artifactId = $result.Artifact.artifactId } } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $referenceDirectory 'build-state.json') -Encoding utf8
    $inUseRejected = $false
    try {
        & $module {
            param($ArtifactId, $StateRoot)
            Remove-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
        } $result.Artifact.artifactId $stateRoot | Out-Null
    } catch { $inUseRejected = $_.Exception.Message -match 'HYPERV_ARTIFACT_IN_USE' }
    Add-CheckResult -Name 'Referenziertes Artifact wird nicht geloescht' -Success $inUseRejected
    Remove-Item -LiteralPath $referenceDirectory -Recurse -Force

    $removal = & $module {
        param($ArtifactId, $StateRoot)
        Remove-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
    } $result.Artifact.artifactId $stateRoot
    Add-CheckResult -Name 'Explizites Artifact-Loeschen entfernt Registry-VHDX und Metadaten gemeinsam' -Success (
        $removal.Status -eq 'REMOVED' -and -not (Test-Path -LiteralPath $result.Artifact.Path)
    )
    $missingArtifact = & $module {
        param($ArtifactId, $StateRoot)
        Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck
    } $result.Artifact.artifactId $stateRoot
    Add-CheckResult -Name 'Geloeschtes Artifact ist nicht mehr aufloesbar' -Success (-not $missingArtifact)
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
