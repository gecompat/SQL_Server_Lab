[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Run', 'Validate')]
    [string] $Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^LAB-[0-9]{8}T[0-9]{6}Z-[0-9A-F]{8}$')]
    [string] $LabRunId,

    [Parameter()]
    [ValidateSet('LAB-LS-001')]
    [string] $ScenarioId = 'LAB-LS-001',

    [Parameter()]
    [string] $StateRoot = (Join-Path $PSScriptRoot '.state')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

switch ($Action) {
    'Run' {
        if (-not $PSCmdlet.ShouldProcess(
                "$ScenarioId on CTR-PAIR run $LabRunId",
                'Create, observe, and clean the bounded synthetic Log Shipping scenario'
            )) {
            return [pscustomobject] @{
                LabRunId = $LabRunId
                ScenarioId = $ScenarioId
                Status = 'WHATIF'
            }
        }
        Invoke-LabLogShippingScenario `
            -LabRunId $LabRunId `
            -ScenarioId $ScenarioId `
            -StateRoot $StateRoot
        break
    }
    'Validate' {
        Test-LabLogShippingScenario `
            -LabRunId $LabRunId `
            -ScenarioId $ScenarioId `
            -StateRoot $StateRoot
        break
    }
}
