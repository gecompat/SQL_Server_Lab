#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt nur die von geaenderten Pfaden betroffenen statischen Suites aus.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ChangedPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$selector = Join-Path $repoRoot 'Tools/Get-CiTestSelection.ps1'
$selection = & $selector -ChangedPath $ChangedPath
$pwsh = Get-Command pwsh -ErrorAction Stop
$failures = [System.Collections.Generic.List[string]]::new()

Write-Host "Betroffene statische Suites: $($selection.StaticChecks -join ', ')" -ForegroundColor Cyan
foreach ($check in $selection.StaticChecks) {
    Write-Host "`n=== $check ===" -ForegroundColor Cyan
    & $pwsh.Source -NoLogo -NoProfile -File (Join-Path $PSScriptRoot $check)
    if ($LASTEXITCODE -ne 0) { $failures.Add("$check (Exitcode $LASTEXITCODE)") }
}

if ($failures.Count -gt 0) {
    throw "Betroffene statische Vertragspruefungen fehlgeschlagen: $($failures -join '; ')"
}

Write-Host "`nBETROFFENE STATISCHE VERTRAGSPRUEFUNGEN: PASS" -ForegroundColor Green
