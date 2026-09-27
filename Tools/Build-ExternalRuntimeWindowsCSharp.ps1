#Requires -Version 7.2
<#
.SYNOPSIS
    Baut das gesperrte CSharp/.NET-8-Quellpaket offline für lokale SQL-Labtests.
.DESCRIPTION
    Prüft vorhandene Archive und verwendet eine explizite Windows-x64-Toolchain.
    Downloads, Installationen, SQL-Registrierung und Katalogfreigabe sind nicht
    enthalten. OutputRoot muss neu sein; Ergebnisse und Fehlerlogs bleiben dort
    für Diagnose und gezieltes Cleanup erhalten. Keine erhöhten Rechte nötig.
.PARAMETER Inputs
    Lokaler Archivroot mit source.zip, dotnet-runtime-8.0.31-win-x64.zip und
    nuget/<id>/<version>/<id>.<version>.nupkg gemäß Tools/CSharpBuild.
.PARAMETER OutputRoot
    Neuer lokaler Buildroot außerhalb versionierter Dateien.
.PARAMETER Dotnet
    Absoluter Pfad zum vorhandenen dotnet.exe mit SDK 10.0.401.
.PARAMETER VcVars
    Absoluter Pfad zu vcvars64.bat mit VC Tools 14.51.36231 und SDK 10.0.26100.0.
.PARAMETER ValidateInputsOnly
    Prüft Hashes, Toolpfade und freien OutputRoot ohne Compiler oder Mutation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Inputs,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$Dotnet,
    [Parameter(Mandatory)][string]$VcVars,
    [switch]$ValidateInputsOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common/ExternalRuntimeWindowsCSharpBuild.ps1')
Invoke-LabCSharpPackageBuild @PSBoundParameters -RecipeRoot (Join-Path $PSScriptRoot 'CSharpBuild')
