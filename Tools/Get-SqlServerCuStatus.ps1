#Requires -Version 7.2
<#
.SYNOPSIS
    Zeigt den dynamischen Microsoft-Abgleich für SQL-Server-CUs an.

.DESCRIPTION
    Kompatibler Konsolenwrapper für Get-SqlServerLabCuStatus. Die effektive
    Microsoft-Learn-Quelle steht im wartbaren Katalog
    Catalogs/sql-server-cu-status-sources.json. Der Abgleich ist read-only:
    neue CUs werden niemals automatisch in den Versionskatalog oder Lab_Base
    übernommen.
#>
[CmdletBinding()]
param(
    [string[]]$Version = @(),
    [string]$SourceUrl,
    [ValidateRange(1, 100)][int]$MaxMissingEntries = 5,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'SqlServerLab.psd1'
Import-Module $modulePath -Force -ErrorAction Stop

$arguments = @{ Version=$Version; MaxMissingEntries=$MaxMissingEntries }
if (-not [string]::IsNullOrWhiteSpace($SourceUrl)) { $arguments.SourceUrl = $SourceUrl }
$result = Get-SqlServerLabCuStatus @arguments

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
    return
}

Write-Host ("A) Gesamtstatus: {0}" -f $result.Status) -ForegroundColor $(if ($result.Status -eq 'UNCLEAR') { 'Yellow' } elseif ($result.Status -eq 'NEW') { 'Cyan' } else { 'Green' })
Write-Host "`nB) CU-Diff je Version"
foreach ($entry in @($result.Versions)) {
    Write-Host ("- SQL {0} [{1}]" -f $entry.Version, $entry.Status)
    if ($entry.LatestMicrosoft) {
        Write-Host ("  - Microsoft: {0} / {1} / {2} / {3}" -f $entry.LatestMicrosoft.Build, $entry.LatestMicrosoft.Update, $entry.LatestMicrosoft.Kb, $entry.LatestMicrosoft.Released)
    }
    if ($entry.LatestCatalog) {
        Write-Host ("  - Katalog:   {0} / {1} / {2}" -f $entry.LatestCatalog.build, $entry.LatestCatalog.cu, $entry.LatestCatalog.kb)
    }
    foreach ($missing in @($entry.Missing)) {
        Write-Host ("  - Neu:       {0} / {1} / {2} / {3}" -f $missing.Build, $missing.Update, $missing.Kb, $missing.Released) -ForegroundColor Cyan
    }
    if ($entry.Note) { Write-Host ("  - Hinweis: {0}" -f $entry.Note) }
}
if ($result.Reason) { Write-Host ("`nUrsache: {0}" -f $result.Reason) -ForegroundColor Yellow }
Write-Host ("`nHinweis: {0}" -f $result.Guidance) -ForegroundColor Cyan
