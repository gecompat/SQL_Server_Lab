<#
.SYNOPSIS
    Prueft Client und Provider ohne Setup, Runtime-Start oder Konfigurationsschreibzugriff.
.DESCRIPTION
    Funktioniert ohne KI-Skill. Nur der aktuelle Prozess darf beim Modulimport
    seine Werkzeugpfade initialisieren. READY ist ein Bootstrap-Nachweis;
    Run-Ownership und konkrete Ressourcen werden erst am Operationseinstieg geprueft.
.PARAMETER Provider
    Der lokal zu pruefende Provider.
.PARAMETER Operation
    Inspect/Validate pruefen den Bootstrap; Create verlangt zusaetzlich Storage.
    PrepareImage verlangt unter Hyper-V ein erhoehtes Token fuer Offline-VHDX-Zugriff.
    Start/Stop/Remove behalten die rungebundenen Pruefungen der Fachcmdlets.
.EXAMPLE
    ./Tools/Test-SqlServerLabClientReadiness.ps1 -Provider docker -Operation Create
.OUTPUTS
    SqlServerLab.ClientReadiness/1.0 mit Status, Checks, MissingPrerequisites,
    Warnings und NextSteps. Keine Hostpfade oder nativen Rohfehler.
#>
[CmdletBinding()]
param(
    [ValidateSet('docker','podman','hyperv')][string]$Provider='docker',
    [ValidateSet('Inspect','Validate','Create','Start','Stop','Remove','PrepareImage')][string]$Operation='Inspect'
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'Private/ClientReadiness.ps1')
Test-LabClientReadiness -RepositoryRoot $repoRoot -Provider $Provider -Operation $Operation
