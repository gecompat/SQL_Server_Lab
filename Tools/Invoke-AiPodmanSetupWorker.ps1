#Requires -Version 7.2
<# Internal bounded worker. The interactive parent owns confirmation and durable handoff. #>
[CmdletBinding()]
param(
    [ValidateSet('podman')][string]$Provider='podman',
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$OperationId,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [switch]$CleanupOnly,[switch]$CollectionCleanupOnly
)
$ErrorActionPreference='Stop'
if ($CleanupOnly -and $CollectionCleanupOnly) { throw 'AI_PODMAN_SETUP_STAGE_INVALID' }
$repoRoot=Split-Path $PSScriptRoot -Parent
$env:SQL_SERVER_LAB_STATE=$StateRoot
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
& $module {
    param($Root,$Operation,$Evidence,$Cleanup,$CollectionCleanup)
    $directory=Get-LabAiPodmanSetupDirectory -StateRoot $Root -OperationId $Operation
    if ([IO.Path]::GetFullPath($Evidence) -cne $directory) { throw 'AI_PODMAN_SETUP_WORKER_BINDING_INVALID' }
    $null=Read-LabAiPodmanSetupRecord -StateRoot $Root -OperationId $Operation
    if ($Cleanup) { Remove-LabAiPodmanSetupOwnedRun -StateRoot $Root -OperationId $Operation }
    elseif ($CollectionCleanup) { Remove-LabAiPodmanSetupCollection -StateRoot $Root -OperationId $Operation }
    else { Invoke-LabAiPodmanSetupApply -StateRoot $Root -OperationId $Operation }
} $StateRoot $OperationId $EvidenceRoot $CleanupOnly $CollectionCleanupOnly
