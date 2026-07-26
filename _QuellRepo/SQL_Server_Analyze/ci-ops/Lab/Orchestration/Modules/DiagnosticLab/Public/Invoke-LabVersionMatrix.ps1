function Invoke-LabVersionMatrix {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath,

        [Parameter()]
        [ValidateSet('AUTO', 'LINUX_NATIVE')]
        [string] $ExecutionMode = 'AUTO',

        [Parameter()]
        [ValidatePattern('^LAB-[A-Z0-9]+-[0-9]{3}$')]
        [string] $ScenarioId = 'LAB-VERSION-001',

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $configuration = Resolve-LabConfiguration `
        -ConfigPath $ConfigPath `
        -ExecutionMode $ExecutionMode
    $requiredVersions = @(2019, 2022, 2025)
    if (
        @(
            $requiredVersions |
                Where-Object {
                    $_ -notin @($configuration.SqlVersionPriority)
                }
        ).Count -gt 0
    ) {
        throw 'The Welle 3 version matrix requires 2019, 2022, and 2025.'
    }
    if (-not $PSCmdlet.ShouldProcess(
            'three sequential digest-bound CTR-SINGLE runs',
            'RunVersionMatrix'
        )) {
        return [pscustomobject] @{
            ScenarioId = $ScenarioId
            Status = 'WHATIF'
            SqlVersions = $requiredVersions
        }
    }

    $results = [Collections.Generic.List[object]]::new()
    foreach ($sqlVersion in $requiredVersions) {
        $labRunId = New-LabRunId
        $topologyReady = $false
        try {
            $up = Invoke-LabUp `
                -LabRunId $labRunId `
                -ExecutionMode $ExecutionMode `
                -ConfigPath $ConfigPath `
                -ContainerEngine DOCKER `
                -TopologyId CTR-SINGLE `
                -SqlVersion $sqlVersion `
                -ResourceProfile Compact `
                -StateRoot $StateRoot `
                -Confirm:$false
            if ($up.Status -ne 'READY') {
                $results.Add([pscustomobject] @{
                        LabRunId = $labRunId
                        ScenarioId = $ScenarioId
                        SqlVersion = $sqlVersion
                        Status = 'NOT_EXECUTED'
                        ReasonCode = $up.ReasonCode
                    })
                continue
            }

            $topologyReady = $true
            Invoke-LabScenario `
                -LabRunId $labRunId `
                -ScenarioId $ScenarioId `
                -StateRoot $StateRoot |
                Out-Null
            $validation = Test-LabScenario `
                -LabRunId $labRunId `
                -ScenarioId $ScenarioId `
                -StateRoot $StateRoot
            $results.Add([pscustomobject] @{
                    LabRunId = $labRunId
                    ScenarioId = $ScenarioId
                    SqlVersion = $sqlVersion
                    Status = $validation.ValidationStatus
                    ReasonCode = ''
                })
        }
        finally {
            if ($topologyReady) {
                Invoke-LabCleanup `
                    -LabRunId $labRunId `
                    -StateRoot $StateRoot `
                    -Recovery `
                    -Confirm:$false |
                    Out-Null
            }
        }
    }
    return $results.ToArray()
}
