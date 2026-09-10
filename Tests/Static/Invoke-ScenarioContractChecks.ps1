#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$schemaPath = Join-Path $repoRoot 'Schemas/scenario-contract.schema.json'
$examplePath = Join-Path $repoRoot 'Schemas/scenario-contract.example.json'
$schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8
$exampleJson = Get-Content -LiteralPath $examplePath -Raw -Encoding utf8

function Assert-ScenarioContract {
    param([Parameter(Mandatory)]$Contract)

    foreach ($collectionName in @('Steps', 'Evidence', 'Outcomes')) {
        $ids = @($Contract.$collectionName | ForEach-Object { [string]$_.Id })
        if ($ids.Count -ne @($ids | Select-Object -Unique).Count) { throw "SCENARIO_CONTRACT_DUPLICATE_ID: $collectionName" }
    }
    $evidenceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($evidence in @($Contract.Evidence)) { [void]$evidenceIds.Add([string]$evidence.Id) }
    $outcomeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($outcome in @($Contract.Outcomes)) {
        [void]$outcomeIds.Add([string]$outcome.Id)
        foreach ($evidenceId in @($outcome.EvidenceIds)) {
            if (-not $evidenceIds.Contains([string]$evidenceId)) { throw "SCENARIO_CONTRACT_OUTCOME_EVIDENCE_UNKNOWN: $evidenceId" }
        }
    }
    foreach ($step in @($Contract.Steps)) {
        foreach ($evidenceId in @($step.EvidenceIds)) {
            if (-not $evidenceIds.Contains([string]$evidenceId)) { throw "SCENARIO_CONTRACT_STEP_EVIDENCE_UNKNOWN: $evidenceId" }
        }
        foreach ($outcomeId in @($step.OutcomeIds)) {
            if (-not $outcomeIds.Contains([string]$outcomeId)) { throw "SCENARIO_CONTRACT_STEP_OUTCOME_UNKNOWN: $outcomeId" }
        }
    }
}

if (-not ($schema | Test-Json -ErrorAction SilentlyContinue)) { throw 'SCENARIO_CONTRACT_SCHEMA_JSON_INVALID' }
if (-not ($exampleJson | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'SCENARIO_CONTRACT_EXAMPLE_SCHEMA_INVALID' }
$example = $exampleJson | ConvertFrom-Json -Depth 50
Assert-ScenarioContract -Contract $example

$providerAttempt = $exampleJson | ConvertFrom-Json -Depth 50
$providerAttempt.Scenario | Add-Member -NotePropertyName Provider -NotePropertyValue docker
if (($providerAttempt | ConvertTo-Json -Depth 50) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) { throw 'SCENARIO_CONTRACT_PROVIDER_BINDING_ACCEPTED' }
$executorAttempt = $exampleJson | ConvertFrom-Json -Depth 50
$executorAttempt.Steps[0] | Add-Member -NotePropertyName Command -NotePropertyValue 'Invoke-Anything'
if (($executorAttempt | ConvertTo-Json -Depth 50) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) { throw 'SCENARIO_CONTRACT_EXECUTOR_FIELD_ACCEPTED' }
$unresolvedEvidenceAttempt = $exampleJson | ConvertFrom-Json -Depth 50
$unresolvedEvidenceAttempt.Steps[0].EvidenceIds = @('missing-evidence')
$unresolvedRejected = $false
try { Assert-ScenarioContract -Contract $unresolvedEvidenceAttempt } catch { $unresolvedRejected = $_.Exception.Message -eq 'SCENARIO_CONTRACT_STEP_EVIDENCE_UNKNOWN: missing-evidence' }
if (-not $unresolvedRejected) { throw 'SCENARIO_CONTRACT_UNRESOLVED_EVIDENCE_ACCEPTED' }

Write-Host 'SCENARIO CONTRACT CHECKS: PASS' -ForegroundColor Green
