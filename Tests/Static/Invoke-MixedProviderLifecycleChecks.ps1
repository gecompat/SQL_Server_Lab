#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den statischen Vertrag des gemischten Container-Provider-Lifecycles.
.DESCRIPTION
    Validiert ohne Runtime-Mutation das Beispielmanifest sowie die verbindlichen
    ProviderSubRun-, Lifecycle- und Cleanup-Anknuepfungspunkte.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$schemaPath = Join-Path $repoRoot 'Schemas\lab-manifest.schema.json'
$manifestPath = Join-Path $repoRoot 'Schemas\example-mixed-provider-lab.json'
$stateMachinePath = Join-Path $repoRoot 'Private\StateMachine.ps1'
$cleanupPath = Join-Path $repoRoot 'Private\CleanupEngine.ps1'
$resourceAssessmentPath = Join-Path $repoRoot 'Private\ResourceAssessment.ps1'
$newLabPath = Join-Path $repoRoot 'Public\New-SqlServerLab.ps1'
$getLabPath = Join-Path $repoRoot 'Public\Get-SqlServerLab.ps1'
$startLabPath = Join-Path $repoRoot 'Public\Start-SqlServerLab.ps1'
$stopLabPath = Join-Path $repoRoot 'Public\Stop-SqlServerLab.ps1'
$removeLabPath = Join-Path $repoRoot 'Public\Remove-SqlServerLab.ps1'

$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Condition) {
        $failures.Add($Description)
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Description
    )

    Assert-True -Condition ($Content -match $Pattern) -Description $Description
}

foreach ($path in @(
    $schemaPath,
    $manifestPath,
    $stateMachinePath,
    $cleanupPath,
    $resourceAssessmentPath,
    $newLabPath,
    $getLabPath,
    $startLabPath,
    $stopLabPath,
    $removeLabPath
)) {
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Description "Datei fehlt: $path"
}

if ($failures.Count -eq 0) {
    $manifestJson = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8
    $schemaValid = Test-Json -Json $manifestJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue
    Assert-True -Condition $schemaValid -Description 'Mixed-Provider-Beispiel verletzt das Manifest-Schema.'

    $manifest = $manifestJson | ConvertFrom-Json -Depth 30
    $providers = @($manifest.instances | ForEach-Object { $_.provider } | Sort-Object -Unique)
    Assert-True -Condition ($providers -join ',' -eq 'docker,podman') -Description 'Mixed-Provider-Beispiel muss Docker und Podman enthalten.'
    Assert-True -Condition (@($manifest.instances | ForEach-Object { $_.profile } | Where-Object { $_ -eq 'compact' }).Count -eq 2) -Description 'Mixed-Provider-Beispiel muss fuer einen kleinen Smoke-Test compact verwenden.'

    $stateMachine = Get-Content -LiteralPath $stateMachinePath -Raw -Encoding utf8
    $cleanup = Get-Content -LiteralPath $cleanupPath -Raw -Encoding utf8
    $resourceAssessment = Get-Content -LiteralPath $resourceAssessmentPath -Raw -Encoding utf8
    $newLab = Get-Content -LiteralPath $newLabPath -Raw -Encoding utf8
    $getLab = Get-Content -LiteralPath $getLabPath -Raw -Encoding utf8
    $startLab = Get-Content -LiteralPath $startLabPath -Raw -Encoding utf8
    $stopLab = Get-Content -LiteralPath $stopLabPath -Raw -Encoding utf8
    $removeLab = Get-Content -LiteralPath $removeLabPath -Raw -Encoding utf8

    Assert-Contains $stateMachine 'function\s+Get-LabProviderSubRuns' 'StateMachine liest keine ProviderSubRuns.'
    Assert-Contains $stateMachine 'function\s+Set-LabProviderSubRunState' 'StateMachine setzt keine ProviderSubRun-States.'
    Assert-Contains $stateMachine 'providerSubRuns' 'Run-State persistiert keine ProviderSubRuns.'
    Assert-Contains $cleanup 'providerSubRuns' 'Cleanup-Plan trennt ProviderSubRuns nicht.'
    Assert-Contains $resourceAssessment '\[string\[\]\]\$Provider' 'Resource Assessment akzeptiert keine mehreren Provider.'
    Assert-Contains $newLab 'Group-Object\s+-Property\s+provider' 'New-SqlServerLab bildet keine ProviderSubRuns.'
    Assert-Contains $newLab 'Set-LabProviderSubRunsState' 'New-SqlServerLab setzt keine ProviderSubRun-States.'
    Assert-Contains $getLab 'Group-Object\s+-Property\s+provider' 'Get-SqlServerLab gruppiert Live-Status nicht nach Provider.'
    Assert-Contains $startLab 'ProviderSubRun' 'Start-SqlServerLab behandelt ProviderSubRuns nicht.'
    Assert-Contains $startLab '\[string\]\$StateRoot' 'Start-SqlServerLab akzeptiert keinen expliziten StateRoot.'
    Assert-Contains $stopLab 'ProviderSubRun' 'Stop-SqlServerLab behandelt ProviderSubRuns nicht.'
    Assert-Contains $stopLab '\[string\]\$StateRoot' 'Stop-SqlServerLab akzeptiert keinen expliziten StateRoot.'
    Assert-Contains $removeLab 'ProviderSubRun' 'Remove-SqlServerLab behandelt ProviderSubRuns nicht.'

    foreach ($lifecycleSource in @($newLab, $getLab, $startLab, $stopLab)) {
        Assert-True `
            -Condition ($lifecycleSource -notmatch 'Gemischte Provider.*noch nicht implementiert') `
            -Description 'Ein Lifecycle-Cmdlet weist gemischte Containerprovider weiterhin pauschal ab.'
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Fehlgeschlagene Mixed-Provider-Vertraege:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'Alle Mixed-Provider-Lifecycle-Vertraege waren erfolgreich.' -ForegroundColor Green
exit 0



