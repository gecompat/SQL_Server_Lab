#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedPlanKey)
$ErrorActionPreference='Stop'
try {
    $module=Import-Module (Join-Path $PSScriptRoot '../SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
    $result=& $module {param($Key)Invoke-LabCmsInspectionWorkerCore -ExpectedPlanKey $Key} $ExpectedPlanKey
    $result|ConvertTo-Json -Depth 5 -Compress
} catch {[Console]::Error.WriteLine('CMS_INSPECTION_WORKER_FAILED');exit 1}
