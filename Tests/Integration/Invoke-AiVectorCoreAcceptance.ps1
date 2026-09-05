#Requires -Version 7.2
<#
.SYNOPSIS
    Führt die native SQL-2025-Vector-Core-Abnahme für Docker oder Podman aus.
.DESCRIPTION
    Initialisiert den ausgewählten Host-Provider, provisioniert das deklarative
    KI-Beispielmanifest, führt das katalogisierte Szenario vector-core-ci aus,
    prüft die sanitisierte Evidence und entfernt den Lab-Run im finally-Block.
    Das Szenario verwendet ausschließlich synthetische Dokumente und feste
    Vektoren; Modell-Download und Internetzugriff sind nicht erforderlich.
.PARAMETER Provider
    Der getrennt nachzuweisende Containerprovider: docker oder podman.
.PARAMETER SaPassword
    Optionales synthetisches SA-Testpasswort als SecureString.
.PARAMETER StateRoot
    Optionaler Test-State-Root. Standard ist ein run-spezifischer Ordner unter
    .artifacts/test-state.
.PARAMETER KeepOnFailure
    Behält den Lab-Run bei einem Fehler für die lokale Diagnose bei.
.EXAMPLE
    .\Tests\Integration\Invoke-AiVectorCoreAcceptance.ps1 -Provider docker
.EXAMPLE
    .\Tests\Integration\Invoke-AiVectorCoreAcceptance.ps1 -Provider podman
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('docker', 'podman')]
    [string]$Provider,
    [SecureString]$SaPassword,
    [string]$StateRoot,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$sourceManifestPath = Join-Path $repoRoot 'Schemas\example-ai-vector-core.json'
$runToken = [Guid]::NewGuid().ToString('N')
$temporaryManifestPath = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-ai-$Provider-$runToken.json"
if (-not $StateRoot) {
    $StateRoot = Join-Path $repoRoot ".artifacts\test-state\ai-vector-$Provider-$runToken"
}

$lab = $null
$succeeded = $false
try {
    $tool = @(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if (-not $tool.Available -or [string]::IsNullOrWhiteSpace([string]$tool.Invocation)) {
        throw "AI_VECTOR_PROVIDER_UNAVAILABLE: $Provider"
    }
    & $tool.Invocation info *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "AI_VECTOR_PROVIDER_UNREACHABLE: $Provider"
    }

    Import-Module $modulePath -Force
    if (-not $SaPassword) {
        $randomBytes = [byte[]]::new(24)
        [Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
        $generatedPassword = "Aa1!$([Convert]::ToBase64String($randomBytes))"
        $SaPassword = [SecureString]::new()
        foreach ($character in $generatedPassword.ToCharArray()) {
            $SaPassword.AppendChar($character)
        }
        $SaPassword.MakeReadOnly()
        [Array]::Clear($randomBytes, 0, $randomBytes.Length)
        $generatedPassword = $null
    }

    $manifest = Get-Content -LiteralPath $sourceManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $manifest.name = "ai-vector-$Provider-$($runToken.Substring(0, 8))"
    $manifest.instances[0].provider = $Provider
    $manifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $temporaryManifestPath -Encoding utf8

    $lab = New-SqlServerLab -Manifest $temporaryManifestPath -SaPassword $SaPassword -StateRoot $StateRoot -NonInteractive -SkipAssessment
    if (-not $lab -or [string]$lab.State -ne 'Running') {
        throw "AI_VECTOR_PROVISION_FAILED: $Provider"
    }

    $result = Invoke-SqlServerLabAiScenario -RunId $lab.RunId -InstanceId primary `
        -ScenarioId vector-core-ci -Version '1.0' -SaPassword $SaPassword -StateRoot $StateRoot -Force -Confirm:$false
    if ([string]$result.Status -ne 'SUCCEEDED' -or [string]$result.CleanupStatus -ne 'SUCCEEDED') {
        throw "AI_VECTOR_SCENARIO_FAILED: Status=$($result.Status); Cleanup=$($result.CleanupStatus)"
    }

    $evidence = Get-SqlServerLabAiScenario -ScenarioId vector-core-ci -Version '1.0' `
        -RunId $lab.RunId -InstanceId primary -StateRoot $StateRoot
    if ([string]$evidence.LastEvidence.Status -ne 'SUCCEEDED' -or
        [string]$evidence.LastEvidence.PlanKey -ne [string]$result.PlanKey -or
        [int]$evidence.LastEvidence.StepCount -ne 3) {
        throw 'AI_VECTOR_EVIDENCE_INVALID'
    }

    $succeeded = $true
    [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.AiVectorCoreAcceptance'; Version = '1.0' }
        Status = 'PASSED'
        Provider = $Provider
        ScenarioId = 'vector-core-ci'
        ScenarioVersion = '1.0'
        PlanKey = [string]$result.PlanKey
        EvidenceStatus = [string]$evidence.LastEvidence.Status
        CleanupStatus = [string]$result.CleanupStatus
    }
}
finally {
    if ($lab -and ($succeeded -or -not $KeepOnFailure.IsPresent)) {
        Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null
    }
    if (Test-Path -LiteralPath $temporaryManifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryManifestPath -Force
    }
}
