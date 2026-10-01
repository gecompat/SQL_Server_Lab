#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$')][string]$LocationId)
$ErrorActionPreference='Stop'
try {
    $module=Import-Module (Join-Path $PSScriptRoot '../SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop -WarningAction SilentlyContinue
    $result=& $module {param($SelectedId) Get-LabInitialSetupCapacityWorkerCore -LocationId $SelectedId} $LocationId
    $result|ConvertTo-Json -Depth 5 -Compress
} catch {
    [Console]::Error.WriteLine('INITIAL_SETUP_CAPACITY_WORKER_FAILED')
    exit 1
}
