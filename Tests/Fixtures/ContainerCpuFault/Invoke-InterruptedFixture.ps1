param([Parameter(Mandatory)][string]$InputPath)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'Private/ContainerCpuFault.ps1')
. (Join-Path $PSScriptRoot 'FakeProvider.ps1')
$inputData=Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
$inputData.Target.CreatedAfterUtc=([DateTimeOffset]$inputData.Target.CreatedAfterUtc).ToUniversalTime().ToString('o')
$script:providerPath=$inputData.ProviderPath
$script:faultMode=''
$script:LabCpuFaultTestCheckpointPause=$true
$secret=[Security.SecureString]::new()
$secret.AppendChar('x'); $secret.MakeReadOnly()
$null=Invoke-LabContainerCpuFault -Target $inputData.Target -JournalDirectory $inputData.Directory -OwnershipKey ([Convert]::FromBase64String($inputData.Key)) -Password $secret
