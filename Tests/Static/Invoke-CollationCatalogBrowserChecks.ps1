#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/CollationCatalogHttpChecks.ps1')
$node=(Get-Command node -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
& $node (Join-Path $PSScriptRoot 'Fixtures/CollationCatalogUiChecks.cjs')
if($LASTEXITCODE -ne 0){throw 'COLLATION_BROWSER_UI_CHECK_FAILED'}
