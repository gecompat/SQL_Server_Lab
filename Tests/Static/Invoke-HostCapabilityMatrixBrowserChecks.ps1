#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/HostCapabilityMatrixHttpChecks.ps1')
& (Join-Path $PSScriptRoot 'Fixtures/HostCapabilityMatrixBrowserAcceptanceChecks.ps1')
$node=(Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
& $node (Join-Path $PSScriptRoot 'Fixtures/HostCapabilityMatrixUiChecks.cjs')
if($LASTEXITCODE -ne 0) {throw 'HOST_MATRIX_BROWSER_UI_FAILED'}
