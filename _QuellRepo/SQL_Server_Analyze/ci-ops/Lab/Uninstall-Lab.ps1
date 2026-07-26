[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
    [string] $ScopeName = 'sql-analyze-quicktest',

    [Parameter()]
    [string] $StateRoot = (Join-Path $PSScriptRoot '.state/quick-test'),

    [Parameter()]
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'QuickTest/QuickTestLab.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

if (-not $Force) {
    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Destroy all registered quick-test resources and local data'
        )) {
        [pscustomobject] @{
            Status = 'DESTROY_CONFIRMATION_REQUIRED'
            ScopeName = $ScopeName
        }
        return
    }
}

Remove-QuickTestLab `
    -ScopeName $ScopeName `
    -StateRoot $StateRoot `
    -Confirm:$false
