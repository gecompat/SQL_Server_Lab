#Requires -Version 7.2
<#
.SYNOPSIS
    SQL_Server_Lab Modul-Loader.
.DESCRIPTION
    Laedt alle Private- und Public-Funktionen sowie Provider-Module.
#>

$script:ModuleRoot = $PSScriptRoot
$script:CatalogsPath = Join-Path $script:ModuleRoot 'Catalogs'
$script:ProvidersPath = Join-Path $script:ModuleRoot 'Providers'
$script:SchemasPath = Join-Path $script:ModuleRoot 'Schemas'

# --- Versionskatalog laden (wird von Providern und Private benoetigt) ---
$script:VersionCatalog = $null
$catalogFile = Join-Path $script:CatalogsPath 'sql-server-versions.json'
if (Test-Path $catalogFile) {
    try {
        $script:VersionCatalog = Get-Content $catalogFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Versionskatalog konnte nicht geladen werden: $_"
    }
}

# --- Provider-Funktionen laden (vor Private, da Private sie referenziert) ---
$script:RegisteredProviders = @{}
if (Test-Path $script:ProvidersPath) {
    $providerDirs = Get-ChildItem -Path $script:ProvidersPath -Directory
    foreach ($dir in $providerDirs) {
        $providerJson = Join-Path $dir.FullName 'provider.json'
        if (Test-Path $providerJson) {
            try {
                $providerDef = Get-Content $providerJson -Raw | ConvertFrom-Json
                $provModulePath = Join-Path $dir.FullName $providerDef.module
                $script:RegisteredProviders[$providerDef.name] = @{
                    Definition = $providerDef
                    Path       = $dir.FullName
                    Module     = $provModulePath
                    Loaded     = $false
                }
                if (Test-Path $provModulePath) {
                    . $provModulePath
                    $script:RegisteredProviders[$providerDef.name].Loaded = $true
                    Write-Verbose "Provider geladen: $($providerDef.name) ($($providerDef.module))"
                }
                else {
                    Write-Warning "Provider-Modul nicht gefunden: $provModulePath"
                }
            }
            catch {
                Write-Warning "Provider-Registrierung fehlgeschlagen: $($dir.Name) - $_"
            }
        }
    }
}

# --- Private Funktionen laden ---
$privatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $privatePath) {
    $privateFiles = Get-ChildItem -Path $privatePath -Filter '*.ps1' -Recurse
    foreach ($file in $privateFiles) {
        try {
            . $file.FullName
        }
        catch {
            Write-Warning "Fehler beim Laden von $($file.Name): $_"
        }
    }
}

# --- Public Funktionen laden ---
$publicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $publicPath) {
    $publicFiles = Get-ChildItem -Path $publicPath -Filter '*.ps1' -Recurse
    foreach ($file in $publicFiles) {
        try {
            . $file.FullName
        }
        catch {
            Write-Warning "Fehler beim Laden von $($file.Name): $_"
        }
    }
}

Write-Verbose "SqlServerLab v$((Get-Module SqlServerLab).Version) geladen. Provider: $($script:RegisteredProviders.Keys -join ', ')"
