#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$runner=Join-Path $repoRoot 'Tests/Integration/Invoke-AiComputeBenchmarkAcceptance.ps1'
$schema=Join-Path $repoRoot 'Schemas/ai-compute-benchmark-acceptance.schema.json'
$source=Get-Content -LiteralPath $runner -Raw
Add-CheckResult 'Acceptance-Schema ist eigenständig und gültiges JSON' ((Get-Content $schema -Raw|ConvertFrom-Json).'$schema' -eq 'https://json-schema.org/draft/2020-12/schema')
$hash='0'*64
$example=[ordered]@{Contract='SqlServerLab.AiComputeBenchmarkAcceptance/1.0';Status='PASSED';ExecutedAtUtc='2026-09-24T00:00:00Z';Platform='Windows';InventorySha256=$hash;CapabilitySetSha256=$hash;CandidateSetSha256=$hash;EligibleCandidateCount=1;BenchmarkCount=1;SelectionKey=$hash;SelectedCandidateId='cpu-candidate';SelectedBackend='LlamaCppCpu';SelectedDevices=@([ordered]@{Kind='CPU';DeviceId='cpu0'});SelectedThroughputPerSecond=10.0;SelectedP95LatencyMilliseconds=100.0;SelectedPeakWorkingSetBytes=4096;RankedCandidates=@([ordered]@{CandidateId='cpu-candidate';ThroughputPerSecond=10.0;P95LatencyMilliseconds=100.0;PeakWorkingSetBytes=4096})}
Add-CheckResult 'Beispielreceipt erfüllt den pfadfreien Acceptance-Vertrag' (($example|ConvertTo-Json -Depth 10)|Test-Json -SchemaFile $schema)
foreach($command in @('Get-SqlServerLabAiComputeInventory','Get-SqlServerLabLlamaCppRuntime','Get-SqlServerLabAiRuntimeCapability','Get-SqlServerLabAiComputeCandidate','Measure-SqlServerLabAiComputeCandidateSet')){Add-CheckResult "Acceptance bindet $command" ($source -match [regex]::Escape($command))}
Add-CheckResult 'Acceptance prüft Coverage, Rangfolge, Maximaldurchsatz und Bindung' ((@('AI_COMPUTE_ACCEPTANCE_COVERAGE_MISMATCH','AI_COMPUTE_ACCEPTANCE_RANKING_MISMATCH','AI_COMPUTE_ACCEPTANCE_FASTEST_MISMATCH','AI_COMPUTE_ACCEPTANCE_BINDING_MISMATCH')|Where-Object {$source -notmatch $_}|Measure-Object).Count -eq 0)
$preview=@(& $runner -RuntimeDirectory Z:\definitely-missing-runtime -ModelPath Z:\missing.gguf -WorkloadKey sql-ai-generation -EvidencePath Z:\missing\evidence.json -WhatIf)
Add-CheckResult 'WhatIf validiert keine lokalen Pfade und erzeugt kein Receipt' ($preview.Count -eq 0)
Add-CheckResult 'Receipt enthält keine lokalen Eingabepfade' ($source -notmatch "(?m)^\s*(RuntimeDirectory|ModelPath|EvidencePath)\s*=")
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI COMPUTE BENCHMARK ACCEPTANCE CONTRACT: PASS ($passed)"
