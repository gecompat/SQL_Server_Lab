function Get-LabLogShippingScenarioContract {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LAB-LS-001')]
        [string] $ScenarioId
    )

    $directory = Join-Path (
        $script:DiagnosticLabRoot
    ) "Scenarios/Infrastructure/$ScenarioId"
    $definitionPath = Join-Path $directory 'scenario.json'
    $runbookPath = Join-Path $directory 'runbook.json'
    foreach ($path in @($definitionPath, $runbookPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'The bounded Log Shipping scenario contract is incomplete.'
        }
    }
    return [pscustomobject] @{
        Category = 'INFRASTRUCTURE'
        Directory = $directory
        DefinitionPath = $definitionPath
        Definition = Get-Content -LiteralPath $definitionPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 100
        RunbookPath = $runbookPath
        Runbook = Get-Content -LiteralPath $runbookPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 100
    }
}

function Invoke-LabLogShippingScenario {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter()]
        [ValidateSet('LAB-LS-001')]
        [string] $ScenarioId = 'LAB-LS-001',

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $contract = Get-LabLogShippingScenarioContract -ScenarioId $ScenarioId
    return Invoke-LabInfrastructureScenario `
        -LabRunId $LabRunId `
        -ScenarioId $ScenarioId `
        -Contract $contract `
        -StateRoot $StateRoot
}

function Test-LabLogShippingScenario {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter()]
        [ValidateSet('LAB-LS-001')]
        [string] $ScenarioId = 'LAB-LS-001',

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $contract = Get-LabLogShippingScenarioContract -ScenarioId $ScenarioId
    $runDirectory = Get-LabRunDirectory `
        -LabRunId $LabRunId `
        -StateRoot $StateRoot
    $statePath = Join-Path $runDirectory 'run-state.json'
    $resultPath = Join-Path $runDirectory "scenario-$ScenarioId.json"
    $result = Read-LabJsonFile -Path $resultPath
    $expectation = @($contract.Definition.ExpectedFindings) | Select-Object -First 1
    if ($null -eq $expectation) {
        throw 'LAB-LS-001 has no finding expectation.'
    }

    $missingFindingCodes = @(
        @($expectation.ExpectedFindingCodes) |
            Where-Object { $_ -notin @($result.FindingCodes) }
    )
    if (
        $result.ScenarioId -ne $ScenarioId -or
        $result.Status -ne 'PASS' -or
        $result.AnalyzerStatus -notin @($expectation.ExpectedStatuses) -or
        $missingFindingCodes.Count -gt 0 -or
        $result.CleanupStatus -ne 'PASS'
    ) {
        throw 'LAB-LS-001 result does not satisfy its bounded finding expectation.'
    }

    Set-LabRunState -StatePath $statePath -Changes @{
        LifecycleStatus = 'SCENARIO_VALIDATED'
        ScenarioId = $ScenarioId
        ValidationStatus = 'PASS'
    }
    return [pscustomobject] @{
        LabRunId = $LabRunId
        ScenarioId = $ScenarioId
        ValidationStatus = 'PASS'
        AnalyzerStatus = $result.AnalyzerStatus
        FindingCodes = @($result.FindingCodes)
        CleanupStatus = $result.CleanupStatus
    }
}
