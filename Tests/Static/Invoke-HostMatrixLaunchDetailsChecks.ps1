#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/HostMatrixLaunchDetailsConsoleChecks.ps1')
& (Join-Path $PSScriptRoot 'Fixtures/HostMatrixLaunchDetailsBrowserChecks.ps1')
$node=(Get-Command node -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
& $node (Join-Path $PSScriptRoot 'Fixtures/HostMatrixLaunchDetailsUiChecks.cjs')
if($LASTEXITCODE -ne 0){throw 'HOST_MATRIX_LAUNCH_DETAILS_UI_FAILED'}
