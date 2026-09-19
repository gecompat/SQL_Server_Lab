#Requires -Version 7.2
param([Parameter(Mandatory)][string]$InputPath,[switch]$Native)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'Private/ContainerCpuFault.ps1')
. (Join-Path $repoRoot 'Private/ContainerMemoryFault.ps1')
$inputData=Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
$inputData.Target.CreatedAfterUtc=([DateTimeOffset]$inputData.Target.CreatedAfterUtc).ToUniversalTime().ToString('o')
if ($Native) {
    . (Join-Path $repoRoot 'Private/HostToolResolution.ps1')
    $resolution=@(Initialize-LabHostToolPath -Name $inputData.Target.Provider)[0]
    if (-not $resolution.Available) { throw 'MEMORY_FAULT_CHILD_CLI_UNAVAILABLE' }
    # Parent performs real SQL preflight. Only this fixture substitutes SQL;
    # the child never receives the SA secret. Memory calls remain native.
    $script:sqlCalls=0
    function Test-LabMemoryFaultSql {
        param($Binding,$Target,[Security.SecureString]$Password,[int]$TimeoutMilliseconds=5000)
        $script:sqlCalls++
        if ($script:sqlCalls -ne 1) { throw 'MEMORY_FAULT_CHILD_CHECKPOINT_MISSED' }
    }
} else {
    $script:providerPath=$inputData.ProviderPath
    $script:faultMode=''
    . (Join-Path $PSScriptRoot 'FakeProvider.ps1')
}
$script:LabMemoryFaultTestCheckpointPause=$true
$dummy=[Security.SecureString]::new(); $dummy.AppendChar('x'); $dummy.MakeReadOnly()
try {
    $null=Invoke-LabContainerMemoryFault -Target $inputData.Target -JournalDirectory $inputData.Directory -OwnershipKey ([Convert]::FromBase64String($inputData.Key)) -Password $dummy
    throw 'MEMORY_FAULT_CHILD_NOT_INTERRUPTED'
} finally { $dummy.Dispose() }
