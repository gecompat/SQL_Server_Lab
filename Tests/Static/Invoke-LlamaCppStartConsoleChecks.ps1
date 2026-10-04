#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/LlamaCppStartConsoleChecks.ps1')

if ($LASTEXITCODE) { exit $LASTEXITCODE }
