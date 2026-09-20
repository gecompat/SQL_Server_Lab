#Requires -Version 7.2
param([Parameter(Mandatory)][string]$InputPath)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'Private/HostToolResolution.ps1')
. (Join-Path $repoRoot 'Private/ContainerCpuFault.ps1')
$inputData=Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
$inputData.Target.CreatedAfterUtc=([DateTimeOffset]$inputData.Target.CreatedAfterUtc).ToUniversalTime().ToString('o')
$resolution=@(Initialize-LabHostToolPath -Name $inputData.Target.Provider)[0]
if (-not $resolution.Available) { throw 'CPU_FAULT_CHILD_CLI_UNAVAILABLE' }
# The parent already performed native SQL preflight. No SA secret crosses this
# process boundary. Only this fixture substitutes SQL; all CPU calls are native.
$script:sqlCalls=0
function Test-LabCpuFaultSql {
    param($Binding,$Target,[Security.SecureString]$Password,[int]$TimeoutMilliseconds=5000)
    $script:sqlCalls++
    if ($script:sqlCalls -ne 1) { throw 'CPU_FAULT_CHILD_CHECKPOINT_MISSED' }
}
$script:LabCpuFaultTestCheckpointPause=$true
$dummy=[Security.SecureString]::new()
$dummy.AppendChar('x'); $dummy.MakeReadOnly()
try {
    $null=Invoke-LabContainerCpuFault -Target $inputData.Target -JournalDirectory $inputData.Directory -OwnershipKey ([Convert]::FromBase64String($inputData.Key)) -Password $dummy
    throw 'CPU_FAULT_CHILD_NOT_INTERRUPTED'
}
finally { $dummy.Dispose() }
