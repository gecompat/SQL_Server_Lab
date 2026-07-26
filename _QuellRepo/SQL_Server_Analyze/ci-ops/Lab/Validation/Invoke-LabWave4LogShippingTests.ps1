[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$parsePaths = @(
    'Lab/Run-LogShipping-Lab.ps1'
    'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
    'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psm1'
    'Lab/Orchestration/Modules/DiagnosticLab/Private/InfrastructureScenarioRuntime.ps1'
    'Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabLogShippingScenario.ps1'
    'Lab/Validation/Invoke-LabWave4LogShippingTests.ps1'
)
foreach ($relativePath in $parsePaths) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepositoryRoot $relativePath),
        [ref] $tokens,
        [ref] $errors
    ) | Out-Null
    if (@($errors).Count -gt 0) {
        $summary = @($errors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell parser reported an error for ${relativePath}: $summary"
    }
}

$scenarioRoot = Join-Path $RepositoryRoot 'Lab/Scenarios/Infrastructure/LAB-LS-001'
foreach ($contract in @(
        @{
            Path = Join-Path $scenarioRoot 'scenario.json'
            Schema = Join-Path $RepositoryRoot 'Lab/Contracts/scenario.schema.json'
        }
        @{
            Path = Join-Path $scenarioRoot 'runbook.json'
            Schema = Join-Path $RepositoryRoot 'Lab/Contracts/scenario-runbook.schema.json'
        }
    )) {
    $json = Get-Content -LiteralPath $contract.Path -Raw -Encoding utf8
    if (-not (Test-Json -Json $json -SchemaFile $contract.Schema -ErrorAction Stop)) {
        throw "Invalid LAB-LS-001 JSON contract: $($contract.Path)"
    }
}

$modulePath = Join-Path (
    $RepositoryRoot
) 'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
try {
    foreach ($functionName in @(
            'Invoke-LabLogShippingScenario'
            'Test-LabLogShippingScenario'
        )) {
        if ($null -eq (Get-Command $functionName -ErrorAction SilentlyContinue)) {
            throw "Required LAB-LS-001 function is not exported: $functionName"
        }
    }

    $module = Get-Module DiagnosticLab
    $contract = & $module {
        Get-LabLogShippingScenarioContract -ScenarioId LAB-LS-001
    }
    if (
        $contract.Category -ne 'INFRASTRUCTURE' -or
        $contract.Definition.TopologyId -ne 'CTR-PAIR' -or
        $contract.Definition.ResourceProfile -ne 'Standard' -or
        $contract.Runbook.RuntimeAction -ne 'MULTI_CONTAINER_LOG_SHIPPING' -or
        $contract.Runbook.PrimaryAnalyzer -ne 'USP_LogShippingStatus'
    ) {
        throw 'LAB-LS-001 module contract is invalid.'
    }

    $runtimeSource = [IO.File]::ReadAllText(
        (Join-Path $RepositoryRoot 'Lab/Orchestration/Modules/DiagnosticLab/Private/InfrastructureScenarioRuntime.ps1'),
        [Text.Encoding]::UTF8
    )
    $healthyIndex = $runtimeSource.IndexOf(
        "ScenarioPhase = 'HEALTHY_BACKUP_COPY_RESTORE'",
        [StringComparison]::Ordinal
    )
    $lagIndex = $runtimeSource.IndexOf(
        "ScenarioPhase = 'VISIBLE_LAG_BACKUP_ONLY'",
        [StringComparison]::Ordinal
    )
    $cleanupIndex = $runtimeSource.IndexOf(
        "ScenarioPhase = 'CLEANUP'",
        [StringComparison]::Ordinal
    )
    if (
        -1 -in @($healthyIndex, $lagIndex, $cleanupIndex) -or
        -not ($healthyIndex -lt $lagIndex -and $lagIndex -lt $cleanupIndex)
    ) {
        throw 'LAB-LS-001 phase ordering is invalid.'
    }
    foreach ($forbidden in @(
            'ForEach-Object -Parallel'
            'Invoke-LabWave4DockerCompose'
            'tc netem'
            'iptables'
            'Remove-Item'
        )) {
        if ($runtimeSource.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "LAB-LS-001 runtime contains forbidden operation: $forbidden"
        }
    }

    $testRoot = Join-Path (
        [IO.Path]::GetTempPath()
    ) ('lab001-ls001-' + [Guid]::NewGuid().ToString('N'))
    $labRunId = 'LAB-20000101T000000Z-00000041'
    try {
        [IO.Directory]::CreateDirectory($testRoot) | Out-Null
        $paths = & $module {
            param($Id, $Root)
            Initialize-LabRunState -LabRunId $Id -StateRoot $Root
        } $labRunId $testRoot
        & $module {
            param($Path)
            Set-LabRunState -StatePath $Path -Changes @{
                LifecycleStatus = 'SCENARIO_COMPLETED'
                ScenarioId = 'LAB-LS-001'
                ScenarioStatus = 'PASS'
                ScenarioCleanupStatus = 'PASS'
            }
        } $paths.StatePath
        & $module {
            param($Path)
            Write-LabJsonFile -Path $Path -InputObject ([ordered] @{
                    SchemaVersion = '1.0'
                    DataClassification = 'LOCAL_RUNTIME_STATE'
                    ScenarioId = 'LAB-LS-001'
                    Status = 'PASS'
                    AnalyzerStatus = 'AVAILABLE'
                    PrimaryAnalyzer = 'USP_LogShippingStatus'
                    FindingCodes = @(
                        'LOG_SHIPPING_HEALTHY_CYCLE_OBSERVED'
                        'LOG_SHIPPING_LAG_VISIBLE'
                        'BACKUP_CHAIN_VISIBLE'
                    )
                    ObservedValue = [ordered] @{
                        HealthyCycleFileMatched = $true
                        LaterBackupPending = $true
                    }
                    AlternativeEvidenceUsed = $false
                    ProductMajorVersion = 17
                    CleanupStatus = 'PASS'
                    CompletedAtUtc = '2000-01-01T00:00:00.000Z'
                })
        } (Join-Path $paths.RunDirectory 'scenario-LAB-LS-001.json')

        $validation = Test-LabLogShippingScenario `
            -LabRunId $labRunId `
            -StateRoot $testRoot
        if (
            $validation.ValidationStatus -ne 'PASS' -or
            $validation.CleanupStatus -ne 'PASS' -or
            'LOG_SHIPPING_LAG_VISIBLE' -notin @($validation.FindingCodes)
        ) {
            throw 'LAB-LS-001 synthetic result validation failed.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $testRoot -PathType Container) {
            [IO.Directory]::Delete($testRoot, $true)
        }
    }

    $validatorPath = Join-Path (
        $RepositoryRoot
    ) 'Code/Tests/Static/Validate_LAB001_Wave4_LogShipping.py'
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        $python = Get-Command python -ErrorAction Stop
    }
    & $python.Source $validatorPath --repository-root $RepositoryRoot
    if ($LASTEXITCODE -ne 0) {
        throw "LAB-LS-001 static validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Module -Name DiagnosticLab -Force -ErrorAction SilentlyContinue
}

Write-Output 'LAB-LS-001 Log Shipping contracts passed.'
