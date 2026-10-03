#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/ExternalRuntimeCapabilityHttpChecks.ps1')
if($LASTEXITCODE -and $LASTEXITCODE -ne 0) {throw 'EXTERNAL_RUNTIME_BROWSER_HTTP_CHECK_FAILED'}
$node=(Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
& $node (Join-Path $PSScriptRoot 'Fixtures/ExternalRuntimeCapabilityUiChecks.cjs')
if($LASTEXITCODE -ne 0) {throw 'EXTERNAL_RUNTIME_BROWSER_UI_CHECK_FAILED'}
