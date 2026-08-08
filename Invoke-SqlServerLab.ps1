#Requires -Version 7.2
<#
.SYNOPSIS
    Standalone-Einstiegspunkt fuer SQL_Server_Lab.
.DESCRIPTION
    Importiert das Modul automatisch und startet den interaktiven Modus
    oder fuehrt eine Direkt-Aktion aus.
.PARAMETER Action
    Optionale Direkt-Aktion: New, Status, Start, Stop, Restart, Remove, Clear, Script, Database, Image.
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
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
    [ValidateSet('New', 'Status', 'Start', 'Stop', 'Restart', 'Remove', 'Clear', 'Script', 'Database', 'Image')]
    [string]$Action,

    [string]$Manifest
)

$showHelpRequested = $ShowHelp.IsPresent -or
    @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or
    @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help' -or
    $Action -eq '/?' -or
    $Action -eq '-?' -or
    $Action -eq '-h' -or
    $Action -eq '--help'

function Show-Usage {
param(
    [string]$ScriptName = 'Invoke-SqlServerLab.ps1'
)
    Write-Host "$ScriptName" -ForegroundColor Cyan
    Write-Host 'Funktion:' -ForegroundColor Magenta
    Write-Host '  Standalone-Einstiegspunkt fuer SQL_Server_Lab.' -ForegroundColor Cyan
    Write-Host '  Importiert das Modul automatisch und startet den interaktiven Modus' -ForegroundColor Cyan
    Write-Host '  oder fuehrt eine Direkt-Aktion aus.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Aufruf:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName [--ShowHelp]" -ForegroundColor Cyan
    Write-Host "  .\$ScriptName -Action <Action> [-Manifest <Pfad>]" -ForegroundColor Cyan
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameter:' -ForegroundColor Magenta
    Write-Host '  -Action <string>      Direkt-Aktion (New, Status, Start, Stop, Restart, Remove, Clear, Script, Database, Image).' -ForegroundColor Cyan
    Write-Host '  -Manifest <string>    Optionaler Pfad zu Manifest fuer New-SqlServerLab.' -ForegroundColor Cyan
    Write-Host '  -ShowHelp             Zeigt diese Hilfe.' -ForegroundColor Cyan
    Write-Host '  -RemainingArgs         Intern fuer unbekannte Hilfeschalter.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Beispiele:' -ForegroundColor Magenta
    Write-Host "  .\$ScriptName" -ForegroundColor Cyan
    Write-Host '  -> Startet das interaktive Menue.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -Action Status" -ForegroundColor Cyan
    Write-Host '  -> Zeigt direkt den aktuellen Status an.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -Manifest .\\scenarios\\my-lab.json" -ForegroundColor Cyan
    Write-Host '  -> Startet ein Lab aus einer Manifest-Datei.' -ForegroundColor Green
    Write-Host "  .\$ScriptName -ShowHelp" -ForegroundColor Cyan
    Write-Host '  -> Zeigt diese Hilfe und beendet den Aufruf.' -ForegroundColor Green
}

if ($showHelpRequested) {
    Show-Usage -ScriptName (Split-Path -Leaf $PSCommandPath)
    return
}

if ($Action) {
    $validActions = @('New', 'Status', 'Start', 'Stop', 'Restart', 'Remove', 'Clear', 'Script', 'Database', 'Image')
    if ($Action -notin $validActions) {
        throw "Ungueltige Action '$Action'. Gültige Werte: $($validActions -join ', ')."
    }
}


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


