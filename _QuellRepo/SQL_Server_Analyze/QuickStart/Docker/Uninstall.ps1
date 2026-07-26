[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$setupPath = Join-Path $PSScriptRoot 'Setup.ps1'
$envPath = Join-Path $PSScriptRoot '.env'

if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
    throw 'Setup.ps1 wurde nicht gefunden; die QuickStart-Deinstallation kann nicht sicher ausgeführt werden.'
}

if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    Write-Host 'Keine lokale QuickStart-Konfiguration gefunden. Es ist keine verwaltete Umgebung registriert.'
    return
}

& $setupPath -Action Remove
