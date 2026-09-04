#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Planung, lokalen Import und WhatIf des Resource-Set-Vertrags.
.DESCRIPTION
    Verwendet nur synthetische temporaere Dateien. Es findet kein
    Netzwerkdownload und keine Provider- oder SQL-Mutation statt.
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-resource-set-$([guid]::NewGuid().ToString('N'))"
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Resource Set Checks' -ForegroundColor Cyan
try {
    $mediaRoot = Join-Path $temporaryRoot 'target-media'
    $testDataRoot = Join-Path $mediaRoot 'Testdaten'
    $stateRoot = Join-Path $temporaryRoot 'state'
    $sourceRoot = Join-Path $temporaryRoot 'source-media'
    New-Item -Path $sourceRoot -ItemType Directory -Force | Out-Null

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $plans = @(Get-SqlServerLabResourcePlan -ResourceId @(
        'sample:northwind:script',
        'software:sql-python:sql2022-python-windows-hyperv'
    ) -MediaRoot $mediaRoot -TestDataRoot $testDataRoot -StateRoot $stateRoot)
    Add-CheckResult -Name 'Read-only Plan löst Sample und Windows-External-Runtime kataloggebunden auf' -Success (
        $plans.Count -eq 2 -and @($plans | Where-Object Contract -eq 'SqlServerLab.ResourcePlan/1.0').Count -eq 2 -and
        @($plans | Where-Object { $_.ResourceId -eq 'sample:northwind:script' -and $_.Acquisition -eq 'DOWNLOAD' -and $_.TrustStatus -eq 'catalog-verified' }).Count -eq 1 -and
        @($plans | Where-Object { $_.ResourceId -eq 'software:sql-python:sql2022-python-windows-hyperv' -and $_.ArtifactCount -eq 11 }).Count -eq 1
    )
    Add-CheckResult -Name 'Read-only Plan erzeugt weder Media-, Testdaten- noch State-Root' -Success (
        -not (Test-Path -LiteralPath $mediaRoot) -and -not (Test-Path -LiteralPath $stateRoot)
    )

    $repositoryRejected = $false
    try { $null = Get-SqlServerLabResourcePlan -ResourceId 'sample:northwind:script' -MediaRoot $repoRoot }
    catch { $repositoryRejected = $_.Exception.Message -like 'RESOURCE_SET_MEDIA_ROOT_UNSAFE:*' }
    Add-CheckResult -Name 'Repository und breite Roots bleiben als Resource-Ziel gesperrt' -Success $repositoryRejected

    $whatIf = Save-SqlServerLabResourceSet -ResourceId 'sample:northwind:script' -MediaRoot $mediaRoot `
        -TestDataRoot $testDataRoot -StateRoot $stateRoot -WhatIf
    Add-CheckResult -Name 'Save unterstützt WhatIf ohne Dateisystemmutation' -Success (
        $whatIf.Status -eq 'PLANNED' -and -not (Test-Path -LiteralPath $mediaRoot) -and -not (Test-Path -LiteralPath $stateRoot)
    )

    $trustRequired = Save-SqlServerLabResourceSet -ResourceId 'sample:adventureworks-2019:lightweight' `
        -MediaRoot $mediaRoot -TestDataRoot $testDataRoot -StateRoot $stateRoot
    Add-CheckResult -Name 'Sample ohne Kataloghash bleibt ohne Freigabe mutationsfrei TRUST_REQUIRED' -Success (
        $trustRequired.Status -eq 'TRUST_REQUIRED' -and -not (Test-Path -LiteralPath $mediaRoot) -and
        -not (Test-Path -LiteralPath $stateRoot)
    )

    $importResult = & $module {
        param($StateRoot,$TestDataRoot,$SourceRoot)
        $payload = Join-Path $SourceRoot 'synthetic.bak'
        [IO.File]::WriteAllBytes($payload, [byte[]](0x53,0x51,0x4c,0x4c,0x41,0x42))
        $sha = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
        $import = Import-LabArtifact -SourcePath $payload -Source 'https://example.invalid/synthetic.bak' `
            -ArtifactType backup -ExpectedSha256 $sha -SampleId synthetic -SampleVariant small `
            -Category test -StateRoot $StateRoot -TestDataRoot $TestDataRoot
        $replay = Resolve-LabArtifact -Source 'https://example.invalid/synthetic.bak' -ArtifactType backup `
            -ExpectedSha256 $sha -SampleId synthetic -SampleVariant small -Category test -NonInteractive `
            -StateRoot $StateRoot -TestDataRoot $TestDataRoot
        [PSCustomObject]@{ Import=$import; Replay=$replay; Sha=$sha }
    } $stateRoot $testDataRoot $sourceRoot
    Add-CheckResult -Name 'Lokaler Sample-Import hasht, veröffentlicht und bleibt cache-idempotent' -Success (
        $importResult.Import.Status -eq 'ARTIFACT_READY' -and $importResult.Import.CacheStatus -eq 'IMPORTED' -and
        $importResult.Replay.Status -eq 'ARTIFACT_READY' -and $importResult.Replay.CacheStatus -eq 'HIT' -and
        $importResult.Import.Sha256 -eq $importResult.Sha -and (Test-Path -LiteralPath $importResult.Import.Path -PathType Leaf)
    )

    $externalResult = & $module {
        param($TargetRoot,$SourceRoot)
        $bytes = [byte[]](0x45,0x58,0x54,0x45,0x52,0x4e,0x41,0x4c)
        $temporary = Join-Path $SourceRoot 'payload.bin'
        [IO.File]::WriteAllBytes($temporary, $bytes)
        $sha = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        $sourceDirectory = Join-Path $SourceRoot "ExternalLanguages/Windows/$sha"
        New-Item -Path $sourceDirectory -ItemType Directory -Force | Out-Null
        Move-Item -LiteralPath $temporary -Destination (Join-Path $sourceDirectory 'payload.bin')
        function script:Get-LabExternalRuntimeWindowsCatalogVariant {
            param($SoftwarePlan)
            [PSCustomObject]@{
                id='synthetic-windows-hyperv'; operatingSystem='windows'; providers=@('hyperv')
                artifacts=@([PSCustomObject]@{
                    id='synthetic-external'; version='1'; sourceType='download'
                    source='https://example.invalid/payload.bin'; sha256=$sha; integrityOrigin='catalog-verified'
                })
            }
        }
        $plan = [PSCustomObject]@{ Status='RESOLVED'; Provider='hyperv'; OperatingSystem='windows'; SoftwareId='synthetic'; VariantId='synthetic-windows-hyperv' }
        $imported = @(Import-LabExternalRuntimeWindowsMedia -SoftwarePlans @($plan) -MediaRoot $TargetRoot -SourceMediaRoot $SourceRoot)
        function script:Invoke-WebRequest { throw 'NETWORK_MUST_NOT_BE_USED' }
        $artifact = @(Resolve-LabExternalRuntimeWindowsMedia -SoftwarePlans @($plan) -MediaRoot $TargetRoot -Acquire)[0]
        [PSCustomObject]@{ Artifact=$artifact; Imported=$imported.Count; Actual=(Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash.ToLowerInvariant(); Sha=$sha }
    } (Join-Path $temporaryRoot 'external-target') $sourceRoot
    Add-CheckResult -Name 'Windows-External-Runtime importiert lokal atomar ohne Netzwerk und prüft SHA-256' -Success (
        $externalResult.Imported -eq 1 -and $externalResult.Actual -eq $externalResult.Sha
    )

    $exports = @(Get-Command Get-SqlServerLabResourcePlan,Save-SqlServerLabResourceSet -Module SqlServerLab)
    Add-CheckResult -Name 'Beide Resource-Set-Cmdlets sind exportiert und besitzen Hilfe' -Success (
        $exports.Count -eq 2 -and (Get-Help Get-SqlServerLabResourcePlan).Synopsis -and (Get-Help Save-SqlServerLabResourceSet).Synopsis
    )
}
catch {
    Add-CheckResult -Name 'Resource Set Testausführung' -Success $false -Message $_.Exception.Message
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "RESOURCE SET CHECKS: FAIL ($($failures.Count))" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "RESOURCE SET CHECKS: PASS ($passed)" -ForegroundColor Green
exit 0
