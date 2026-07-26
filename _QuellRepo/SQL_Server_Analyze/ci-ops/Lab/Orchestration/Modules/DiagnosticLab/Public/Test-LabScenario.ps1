function Test-LabScenario {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [ValidatePattern('^LAB-[A-Z0-9]+-[0-9]{3}$')]
        [string] $ScenarioId,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $contract = Get-LabScenarioContract -ScenarioId $ScenarioId
    $runDirectory = Get-LabRunDirectory `
        -LabRunId $LabRunId `
        -StateRoot $StateRoot
    $statePath = Join-Path $runDirectory 'run-state.json'
    $resultPath = Join-Path $runDirectory "scenario-$ScenarioId.json"
    $result = Read-LabJsonFile -Path $resultPath
    $expectation = @($contract.Definition.ExpectedFindings) |
        Select-Object -First 1
    if ($null -eq $expectation) {
        throw 'The scenario has no finding expectation.'
    }

    $expectedStatuses = @($expectation.ExpectedStatuses)
    $expectedFindingCodes = @($expectation.ExpectedFindingCodes)
    $cleanupIsValid = if ($contract.Category -eq 'PERFORMANCE') {
        if ($contract.Runbook.RuntimeAction -eq 'CONTRACT_FIXTURE') {
            $result.CleanupStatus -eq 'NOT_REQUIRED'
        }
        else {
            $result.CleanupStatus -eq 'PASS'
        }
    }
    else {
        $result.CleanupStatus -eq 'NOT_REQUIRED'
    }

    $validationStatus = if (
        $result.ScenarioId -eq $ScenarioId -and
        $result.Status -eq 'PASS' -and
        $result.AnalyzerStatus -in $expectedStatuses -and
        @(
            $expectedFindingCodes |
                Where-Object { $_ -notin @($result.FindingCodes) }
        ).Count -eq 0 -and
        $cleanupIsValid
    ) {
        'PASS'
    }
    else {
        'FAIL'
    }
    if ($validationStatus -ne 'PASS') {
        throw 'Scenario result does not satisfy its finding expectation.'
    }
    Set-LabRunState -StatePath $statePath -Changes @{
        LifecycleStatus = 'SCENARIO_VALIDATED'
        ScenarioId = $ScenarioId
        ValidationStatus = $validationStatus
    }
    return [pscustomobject] @{
        LabRunId = $LabRunId
        ScenarioId = $ScenarioId
        ValidationStatus = $validationStatus
        AnalyzerStatus = $result.AnalyzerStatus
        FindingCodes = @($result.FindingCodes)
        CleanupStatus = $result.CleanupStatus
    }
}
