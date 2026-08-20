#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
$selector = Join-Path $repoRoot 'Tools/Get-CiTestSelection.ps1'

$docs = & $selector -ChangedPath @('Documentation/User/Getting_Started.md')
Add-CheckResult -Name 'Dokumentation loest keinen Runtime-Smoke aus' -Success (
    $docs.DocumentationOnly -and -not $docs.Docker -and -not $docs.Podman -and -not $docs.Mixed -and -not $docs.HyperV -and -not $docs.Adapter
)

$docker = & $selector -ChangedPath @('Providers/Docker/DockerProvider.ps1')
Add-CheckResult -Name 'Docker-Aenderung bleibt auf Docker begrenzt' -Success (
    $docker.Docker -and -not $docker.Podman -and -not $docker.Mixed -and -not $docker.HyperV -and -not $docker.Adapter
)

$hyperV = & $selector -ChangedPath @('Private/HyperVLabEnvironment.ps1')
Add-CheckResult -Name 'Hyper-V-Aenderung aktiviert Hyper-V-Vertraege und Runtime' -Success (
    $hyperV.HyperV -and 'Invoke-HyperVLabEnvironmentChecks.ps1' -in $hyperV.StaticChecks -and -not $hyperV.Docker
)

$shared = & $selector -ChangedPath @('Private/Common.ps1')
Add-CheckResult -Name 'Unbekannte produktive Aenderung faellt sicher auf Docker zurueck' -Success $shared.Docker

$crossProvider = & $selector -ChangedPath @('Private/ProviderCapability.ps1')
Add-CheckResult -Name 'Provideruebergreifende Aenderung verwendet Mixed-Smoke' -Success $crossProvider.Mixed

$batchWorkflow = & $selector -ChangedPath @('Private/BatchWorkflow.ps1')
Add-CheckResult -Name 'Batch-Aenderung aktiviert Batch-Vertrag und repraesentativen Docker-Smoke' -Success (
    $batchWorkflow.Docker -and 'Invoke-BatchWorkflowChecks.ps1' -in $batchWorkflow.StaticChecks
)

$ci = & $selector -ChangedPath @('.github/workflows/static-contracts.yml')
Add-CheckResult -Name 'CI-Infrastruktur prueft einmalig alle Runtime-Gates' -Success (
    $ci.Docker -and $ci.Podman -and $ci.Mixed -and $ci.HyperV -and $ci.Adapter
)

$outputPath = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-ci-output-$([guid]::NewGuid().ToString('N')).txt"
try {
    $env:GITHUB_OUTPUT = $outputPath
    $null = & $selector -ChangedPath @('.github/workflows/static-contracts.yml') -WriteGitHubOutput
    $outputText = Get-Content -LiteralPath $outputPath -Raw -Encoding utf8
    Add-CheckResult -Name 'GitHub-Outputs verwenden exakte boolesche Kleinbuchstabenwerte' -Success (
        $outputText -match '(?m)^docker=true\r?$' -and $outputText -match '(?m)^hyperv=true\r?$' -and
        $outputText -notmatch 'ToLowerInvariant'
    )
}
finally {
    Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
}

$allChecksText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-AllChecks.ps1') -Raw -Encoding utf8
Add-CheckResult -Name 'CI-Strategievertrag ist Teil der Vollregression' -Success ($allChecksText -match 'Invoke-CiStrategyChecks\.ps1')

$runtimeWorkflows = @(
    'runtime-smoke-docker.yml', 'runtime-smoke-podman.yml',
    'runtime-smoke-mixed-providers.yml', 'runtime-smoke-hyperv.yml'
)
$duplicates = @()
foreach ($workflow in $runtimeWorkflows) {
    $text = Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/$workflow") -Raw -Encoding utf8
    if ($text -match 'Invoke-AllChecks\.ps1|name:\s*Static contracts') { $duplicates += $workflow }
}
Add-CheckResult -Name 'Runtime-Workflows wiederholen keine statische Vollregression' -Success ($duplicates.Count -eq 0) -Message ($duplicates -join ', ')

$dockerWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-docker.yml') -Raw -Encoding utf8
$podmanWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-podman.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'Docker- und Podman-Gates enthalten den realen Batch-Smoke' -Success (
    $dockerWorkflow -match 'Invoke-BatchWorkflowSmokeTest\.ps1\s+`?\s*-Provider docker' -and
    $podmanWorkflow -match 'Invoke-BatchWorkflowSmokeTest\.ps1\s+`?\s*-Provider podman'
)

$prWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/static-contracts.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'PR-Gate laeuft nicht erneut bei Push auf main' -Success ($prWorkflow -notmatch '(?m)^\s*push:\s*$')
Add-CheckResult -Name 'PR-Gate besitzt stabilen Abschlusscheck' -Success ($prWorkflow -match 'name:\s*PR Gate')
Add-CheckResult -Name 'PR-Gate schützt Self-hosted Runner vor Fork-Code' -Success (
    $prWorkflow -match 'pull_request\.head\.repo\.full_name == github\.repository'
)

$nightly = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/nightly-regression.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'Nightly enthaelt Vollregression und taeglichen Zeitplan' -Success (
    $nightly -match 'Invoke-AllChecks\.ps1' -and $nightly -match '(?m)^\s*schedule:\s*$'
)

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
