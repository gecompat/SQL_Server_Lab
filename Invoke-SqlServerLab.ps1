#Requires -Version 7.2
<#
.SYNOPSIS
    Standalone-Einstiegspunkt fuer SQL_Server_Lab.
.DESCRIPTION
    Importiert das Modul automatisch und startet den interaktiven oder
    manifest-basierten Workflow.
.PARAMETER Manifest
    Pfad zu einer Manifest-JSON-Datei. Ohne Angabe startet der interaktive Modus.
.PARAMETER Action
    Explizite Aktion: New, Status, Start, Stop, Remove, Cleanup.
.EXAMPLE
    ./Invoke-SqlServerLab.ps1
    ./Invoke-SqlServerLab.ps1 -Manifest ./scenarios/my-lab.json
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Manifest,

    [Parameter()]
    [ValidateSet('New', 'Status', 'Start', 'Stop', 'Remove', 'Cleanup')]
    [string]$Action = 'New'
)

$ErrorActionPreference = 'Stop'

# Modul aus demselben Verzeichnis laden
$modulePath = Join-Path $PSScriptRoot 'SqlServerLab.psd1'
if (-not (Get-Module SqlServerLab)) {
    Import-Module $modulePath -Force
}

# Dispatch
switch ($Action) {
    'New' {
        if ($Manifest) {
            Invoke-SqlServerLab -Manifest $Manifest
        }
        else {
            Invoke-SqlServerLab
        }
    }
    'Status'  { Get-SqlServerLab }
    'Start'   { Start-SqlServerLab }
    'Stop'    { Stop-SqlServerLab }
    'Remove'  { Remove-SqlServerLab }
    'Cleanup' { Invoke-LabCleanup }
}
