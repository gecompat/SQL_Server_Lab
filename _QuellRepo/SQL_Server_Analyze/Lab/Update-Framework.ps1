[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
    [string] $ScopeName = 'sql-analyze-quicktest',

    [Parameter()]
    [string] $StateRoot = (Join-Path $PSScriptRoot '.state/quick-test')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'QuickTest/QuickTestLab.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

$arguments = @{
    ScopeName = $ScopeName
    StateRoot = $StateRoot
    Confirm = $false
}
if ($WhatIfPreference) {
    $arguments.WhatIf = $true
}
Update-QuickTestFramework @arguments
