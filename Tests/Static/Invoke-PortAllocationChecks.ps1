#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = [int]$listener.LocalEndpoint.Port
try {
    $occupied = & $module { param($candidatePort) Test-LabEndpointBinding -Port $candidatePort } $port
}
finally {
    $listener.Stop()
}
$released = & $module { param($candidatePort) Test-LabEndpointBinding -Port $candidatePort } $port

Add-CheckResult -Name 'Explizite Portpruefung erkennt einen echten lokalen Listener mit Besitzer und Grund' -Success (
    -not $occupied.Available -and $occupied.Port -eq $port -and
    -not [string]::IsNullOrWhiteSpace([string]$occupied.Owner) -and
    -not [string]::IsNullOrWhiteSpace([string]$occupied.Reason)
)
Add-CheckResult -Name 'Explizite Portpruefung mutiert nicht und gibt den Port nach Ende des Listeners frei' -Success (
    $released.Available -and $released.Port -eq $port -and $null -eq $released.Owner
)

$dockerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Docker\DockerProvider.ps1') -Raw -Encoding utf8
$podmanSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers\Podman\PodmanProvider.ps1') -Raw -Encoding utf8
$menuSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Invoke-SqlServerLab.ps1') -Raw -Encoding utf8

Add-CheckResult -Name 'Docker prueft explizite Ports innerhalb des Allokations-Locks direkt vor der Runtime-Bindung' -Success (
    $dockerSource -match 'Invoke-LabPortAllocationLock[\s\S]+Test-LabEndpointBinding\s+-Port\s+\$selectedPort[\s\S]+docker\s+@dockerArguments'
)
Add-CheckResult -Name 'Podman prueft explizite Ports innerhalb des Allokations-Locks direkt vor der Runtime-Bindung' -Success (
    $podmanSource -match 'Invoke-LabPortAllocationLock[\s\S]+Test-LabEndpointBinding\s+-Port\s+\$selectedPort[\s\S]+podman\s+@podmanArguments'
)
Add-CheckResult -Name 'Intent-Review meldet bei expliziter Portkollision Besitzer und Grund' -Success (
    $menuSource -match "hostPort[\s\S]+Test-LabEndpointBinding[\s\S]+Besitzer:[\s\S]+Grund:"
)

if ($failures.Count -gt 0) {
    Write-Host "Port Allocation Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Port Allocation Checks: $passed PASS" -ForegroundColor Green
