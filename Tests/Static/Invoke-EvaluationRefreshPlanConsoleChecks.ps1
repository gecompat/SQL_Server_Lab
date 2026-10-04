#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Fixtures/EvaluationRefreshPlanConsoleChecks.ps1')
