#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Menu', 'Setup', 'Start', 'Status', 'Stop', 'Remove')]
    [string] $Action = 'Menu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:QuickStartRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:EnvPath = Join-Path $PSScriptRoot '.env'
$script:MarkerFileName = '.sql-server-analyze-hyperv-quickstart.json'
$script:MarkerOwner = 'SQL_SERVER_ANALYZE_HYPERV_QUICKSTART'
$script:SwitchName = 'SQL_Server_Analyze_Lab'
$script:NatName = 'SQL_Server_Analyze_Lab_NAT'
$script:SubnetPrefix = '172.30.0'
$script:SubnetCIDR = '172.30.0.0/24'
$script:GatewayIP = '172.30.0.1'
$script:GatewayAddress = '172.30.0.1'
$script:PrefixLength = 24
$script:NatSubnet = '172.30.0.0/24'
$script:PathComparison = [StringComparison]::OrdinalIgnoreCase

# VM name mapping (legacy compatibility)
$script:VmNames = @{
    '2019' = 'SQL_Analyze_Win_2019'
    '2022' = 'SQL_Analyze_Win_2022'
    '2025' = 'SQL_Analyze_Win_2025'
}
$script:VmIpAddresses = @{
    '2019' = '172.30.0.19'
    '2022' = '172.30.0.22'
    '2025' = '172.30.0.25'
}

# VM IP assignments
$script:VmIpMap = @{
    'win-2019'   = '172.30.0.19'
    'win-2022'   = '172.30.0.22'
    'win-2025'   = '172.30.0.25'
    'linux-2019' = '172.30.0.119'
    'linux-2022' = '172.30.0.122'
    'linux-2025' = '172.30.0.125'
}

# Resource profiles
$script:ResourceProfiles = @{
    'Compact' = @{ MinMemory = 4GB; MaxMemory = 6GB; vCPUs = 2; VhdMaxGB = 60 }
    'Standard' = @{ MinMemory = 8GB; MaxMemory = 12GB; vCPUs = 4; VhdMaxGB = 80 }
    'Performance' = @{ MinMemory = 16GB; MaxMemory = 24GB; vCPUs = 8; VhdMaxGB = 120 }
}

# Network simulation profiles (Linux only)
$script:NetworkProfiles = @{
    'LAN'          = @{ Delay = '0ms'; Rate = $null; Loss = '0%'; Description = 'Lokale Entwicklung' }
    'WAN'          = @{ Delay = '15ms 3ms'; Rate = '100mbit'; Loss = '0.1%'; Description = 'Remote-Standort' }
    'Schlecht'     = @{ Delay = '80ms 20ms'; Rate = '10mbit'; Loss = '2%'; Description = 'Stresstest' }
    'AG'           = @{ Delay = '2ms 0.5ms'; Rate = '1gbit'; Loss = '0%'; Description = 'AG-Synchronisation' }
}

# I/O simulation profiles (Linux only)
$script:IoProfiles = @{
    'SSD'          = @{ ReadIOPS = 0; WriteIOPS = 0; ReadMBs = 0; WriteMBs = 0; Description = 'Unbegrenzt' }
    'HDD'          = @{ ReadIOPS = 150; WriteIOPS = 100; ReadMBs = 120; WriteMBs = 80; Description = 'Standard HDD' }
    'Stressed'     = @{ ReadIOPS = 50; WriteIOPS = 30; ReadMBs = 40; WriteMBs = 20; Description = 'Extremer I/O-Druck' }
    'LogBottleneck' = @{ ReadIOPS = 0; WriteIOPS = 40; ReadMBs = 0; WriteMBs = 30; Description = 'Log-Write-Engpass' }
}

# Load internal modules
$internalRoot = Join-Path $PSScriptRoot 'Internal'
foreach ($internalScript in @(
        'Common.ps1',
        'PathSafety.ps1',
        'Configuration.ps1',
        'VmProvisioning.ps1',
        'SqlInstall.ps1',
        'NetworkSimulation.ps1',
        'Runtime.ps1',
        'Lifecycle.ps1'
    )) {
    $scriptPath = Join-Path $internalRoot $internalScript
    if (Test-Path -LiteralPath $scriptPath) {
        . $scriptPath
    }
}

Write-Host ''
Write-Host 'SQL_Server_Analyze Hyper-V QuickStart'
Write-Host "Quelle: $script:QuickStartRoot"

switch ($Action) {
    'Menu'   { Invoke-Menu }
    'Setup'  { Invoke-Setup }
    'Start'  { Start-Environment }
    'Status' { Show-Status }
    'Stop'   { Stop-Environment }
    'Remove' { Remove-Environment }
}
