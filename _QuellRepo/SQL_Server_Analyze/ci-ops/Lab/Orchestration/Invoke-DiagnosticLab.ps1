[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'Preflight',
        'Status',
        'Up',
        'Run',
        'Validate',
        'RunVersionMatrix',
        'Down',
        'RecoveryCleanup'
    )]
    [string] $Action,

    [Parameter()]
    [ValidatePattern('^LAB-[0-9]{8}T[0-9]{6}Z-[0-9A-F]{8}$')]
    [string] $LabRunId,

    [Parameter()]
    [ValidateSet('AUTO', 'WINDOWS_SINGLE_HOST', 'LINUX_NATIVE', 'DISTRIBUTED')]
    [string] $ExecutionMode,

    [Parameter()]
    [string] $ConfigPath,

    [Parameter()]
    [ValidateSet('DOCKER', 'PODMAN')]
    [string] $Engine = 'DOCKER',

    [Parameter()]
    [ValidateSet('CTR-SINGLE', 'CTR-PAIR', 'CTR-TRIPLE')]
    [string] $Topology = 'CTR-SINGLE',

    [Parameter()]
    [ValidateSet(2019, 2022, 2025)]
    [int] $SqlVersion = 2025,

    [Parameter()]
    [ValidateSet('Compact', 'Standard')]
    [string] $ResourceProfile = 'Compact',

    [Parameter()]
    [ValidatePattern('^LAB-[A-Z0-9]+-[0-9]{3}$')]
    [string] $ScenarioId,

    [Parameter()]
    [switch] $AllowRemoteExecution
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'Modules/DiagnosticLab/DiagnosticLab.psd1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

switch ($Action) {
    'Preflight' {
        $arguments = @{
            AllowRemoteExecution = $AllowRemoteExecution
        }
        if ($PSBoundParameters.ContainsKey('LabRunId')) {
            $arguments.LabRunId = $LabRunId
        }
        if ($PSBoundParameters.ContainsKey('ExecutionMode')) {
            $arguments.ExecutionMode = $ExecutionMode
        }
        if ($PSBoundParameters.ContainsKey('ConfigPath')) {
            $arguments.ConfigPath = $ConfigPath
        }

        if ($WhatIfPreference) {
            [pscustomobject] @{
                Action = 'Preflight'
                Status = 'WHATIF'
                MutationBoundary = 'LOCAL_IGNORED_STATE_ONLY'
            }
        }
        else {
            Invoke-LabPreflight @arguments
        }
        break
    }

    'Status' {
        if (-not $PSBoundParameters.ContainsKey('LabRunId')) {
            throw 'Status requires -LabRunId.'
        }
        Get-LabStatus -LabRunId $LabRunId
        break
    }

    'Up' {
        if ($Topology -eq 'CTR-SINGLE' -and $ResourceProfile -ne 'Compact') {
            throw 'CTR-SINGLE currently requires the Compact resource profile.'
        }
        if ($Topology -in @('CTR-PAIR', 'CTR-TRIPLE') -and $ResourceProfile -ne 'Standard') {
            throw 'CTR-PAIR and CTR-TRIPLE require the Standard resource profile.'
        }
        $arguments = @{
            ContainerEngine = $Engine
            TopologyId = $Topology
            SqlVersion = $SqlVersion
            ResourceProfile = $ResourceProfile
            AllowRemoteExecution = $AllowRemoteExecution
            Confirm = $false
            WhatIf = $WhatIfPreference
        }
        if ($PSBoundParameters.ContainsKey('LabRunId')) {
            $arguments.LabRunId = $LabRunId
        }
        if ($PSBoundParameters.ContainsKey('ExecutionMode')) {
            $arguments.ExecutionMode = $ExecutionMode
        }
        if ($PSBoundParameters.ContainsKey('ConfigPath')) {
            $arguments.ConfigPath = $ConfigPath
        }
        if ($Topology -eq 'CTR-SINGLE') {
            Invoke-LabUp @arguments
        }
        else {
            Invoke-LabMultiContainerUp @arguments
        }
        break
    }

    'Run' {
        if (
            -not $PSBoundParameters.ContainsKey('LabRunId') -or
            -not $PSBoundParameters.ContainsKey('ScenarioId')
        ) {
            throw 'Run requires -LabRunId and -ScenarioId.'
        }
        Invoke-LabScenario -LabRunId $LabRunId -ScenarioId $ScenarioId
        break
    }

    'Validate' {
        if (
            -not $PSBoundParameters.ContainsKey('LabRunId') -or
            -not $PSBoundParameters.ContainsKey('ScenarioId')
        ) {
            throw 'Validate requires -LabRunId and -ScenarioId.'
        }
        Test-LabScenario -LabRunId $LabRunId -ScenarioId $ScenarioId
        break
    }

    'RunVersionMatrix' {
        if (-not $PSBoundParameters.ContainsKey('ConfigPath')) {
            throw 'RunVersionMatrix requires -ConfigPath.'
        }
        $matrixArguments = @{
            ConfigPath = $ConfigPath
            ExecutionMode = if (
                $PSBoundParameters.ContainsKey('ExecutionMode')
            ) {
                $ExecutionMode
            }
            else {
                'AUTO'
            }
            ScenarioId = if (
                $PSBoundParameters.ContainsKey('ScenarioId')
            ) {
                $ScenarioId
            }
            else {
                'LAB-VERSION-001'
            }
            Confirm = $false
            WhatIf = $WhatIfPreference
        }
        Invoke-LabVersionMatrix @matrixArguments
        break
    }

    { $_ -in @('Down', 'RecoveryCleanup') } {
        if (-not $PSBoundParameters.ContainsKey('LabRunId')) {
            throw "$Action requires -LabRunId."
        }

        if ($PSCmdlet.ShouldProcess(
                "registered resources owned by $LabRunId",
                $Action
            )) {
            Invoke-LabCleanup `
                -LabRunId $LabRunId `
                -Recovery:($Action -eq 'RecoveryCleanup') `
                -Confirm:$false
        }
        break
    }
}
