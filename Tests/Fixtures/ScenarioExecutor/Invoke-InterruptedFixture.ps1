#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputPath)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'Private/ScenarioExecutor.ps1')
$inputData = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
$null = Invoke-LabSyntheticScenario -Contract $inputData.Contract -Plan $inputData.Plan -JournalDirectory $inputData.Directory -OwnerId $inputData.Owner -OperationId $inputData.Operation -OwnershipKey ([Convert]::FromBase64String($inputData.Key))
