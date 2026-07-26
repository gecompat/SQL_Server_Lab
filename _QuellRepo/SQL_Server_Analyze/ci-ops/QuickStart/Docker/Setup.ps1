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
$script:ComposePath = Join-Path $PSScriptRoot 'docker-compose.yml'
$script:SlowIoComposePath = Join-Path $PSScriptRoot 'docker-compose.slow-io.yml'
$script:MarkerFileName = '.sql-server-analyze-quickstart.json'
$script:MarkerOwner = 'SQL_SERVER_ANALYZE_QUICKSTART'
$script:IsWindowsHost = if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $true
}
else {
    [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}
$script:PathComparison = if ($script:IsWindowsHost) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}

$internalRoot = Join-Path $PSScriptRoot 'Internal'
foreach ($internalScript in @(
        'Common.ps1',
        'PathSafety.ps1',
        'Configuration.ps1',
        'Runtime.ps1',
        'Lifecycle.ps1'
    )) {
    . (Join-Path $internalRoot $internalScript)
}

Write-Host 'SQL_Server_Analyze Docker QuickStart'
Write-Host "Quelle: $script:QuickStartRoot"

switch ($Action) {
    'Menu' { Invoke-Menu }
    'Setup' { Invoke-Setup }
    'Start' { Start-Environment }
    'Status' { Show-Status }
    'Stop' { Stop-Environment }
    'Remove' { Remove-Environment }
}
