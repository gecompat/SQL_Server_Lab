#Requires -Version 7.2
<#
.SYNOPSIS
    Standalone-Einstiegspunkt fuer SQL_Server_Lab.
.DESCRIPTION
    Importiert das Modul automatisch und startet den interaktiven Modus
    oder fuehrt eine Direkt-Aktion aus.
.PARAMETER Action
    Optionale Direkt-Aktion: New, Status, Start, Stop, Restart, Remove, Clear, Script, Database.
    Ohne Angabe startet das interaktive Menue.
.PARAMETER Manifest
    Pfad zu einer Manifest-JSON-Datei fuer New-SqlServerLab.
.EXAMPLE
    ./Invoke-SqlServerLab.ps1
    # Startet interaktives Menue
.EXAMPLE
    ./Invoke-SqlServerLab.ps1 -Action Status
    # Zeigt direkt den Status aller Labs
.EXAMPLE
    ./Invoke-SqlServerLab.ps1 -Manifest ./scenarios/my-lab.json
    # Erstellt Lab aus Manifest
#>
[CmdletBinding()]
param(
    [ValidateSet('New', 'Status', 'Start', 'Stop', 'Restart', 'Remove', 'Clear', 'Script', 'Database')]
    [string]$Action,

    [string]$Manifest
)

$ErrorActionPreference = 'Stop'

# Modul aus demselben Verzeichnis laden
$modulePath = Join-Path $PSScriptRoot 'SqlServerLab.psd1'
Import-Module $modulePath -Force

# Dispatch
if ($Manifest) {
    New-SqlServerLab -Manifest $Manifest
}
elseif ($Action) {
    Invoke-SqlServerLab -Action $Action
}
else {
    Invoke-SqlServerLab
}
