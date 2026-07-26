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
    # Provider-Skripte aus Unterordnern laden
    $providerDirs = Get-ChildItem -Path $script:ProvidersPath -Directory
    foreach ($dir in $providerDirs) {
        # Alle .ps1/.psm1 Dateien im Provider-Ordner laden
        $scripts = Get-ChildItem -Path $dir.FullName -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }
        foreach ($s in $scripts) {
            try {
                . $s.FullName
                Write-Host "  [LOAD] Provider: $($s.Name)" -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "Provider-Skript fehlgeschlagen: $($s.FullName) - $_"
            }
        }

        # Metadaten registrieren
        $providerJson = Join-Path $dir.FullName 'provider.json'
        if (Test-Path $providerJson) {
            try {
                $providerDef = Get-Content $providerJson -Raw | ConvertFrom-Json
                $script:RegisteredProviders[$providerDef.name] = @{
                    Definition = $providerDef
                    Path       = $dir.FullName
                    Loaded     = $true
                }
            }
            catch {
                Write-Warning "Provider-Metadaten fehlgeschlagen: $($dir.Name) - $_"
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

Write-Host "  [LOAD] SqlServerLab geladen. Provider: $($script:RegisteredProviders.Keys -join ', ')" -ForegroundColor DarkGray
