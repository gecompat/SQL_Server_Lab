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
$script:ModuleLoadErrors = [System.Collections.Generic.List[string]]::new()
$script:HyperVResourceLocationHandoff = $null

# --- Versionskatalog laden (wird von Providern und Private benoetigt) ---
$script:VersionCatalog = $null
$catalogFile = Join-Path $script:CatalogsPath 'sql-server-versions.json'
if (Test-Path $catalogFile) {
    try {
        $script:VersionCatalog = Get-Content $catalogFile -Raw | ConvertFrom-Json
    }
    catch {
        $message = "Versionskatalog konnte nicht geladen werden: $_"
        $script:ModuleLoadErrors.Add($message)
        Write-Warning $message
    }
}

# --- Provider-Funktionen laden (vor Private, da Private sie referenziert) ---
$script:RegisteredProviders = @{}
if (Test-Path $script:ProvidersPath) {
    # Provider-Skripte aus Unterordnern laden
    $providerDirs = Get-ChildItem -Path $script:ProvidersPath -Directory
    foreach ($dir in $providerDirs) {
        # Alle .ps1/.psm1 Dateien im Provider-Ordner laden
        # NUR .ps1 laden — .psm1 erzeugt Nested-Module-Scope und isoliert Funktionen!
        $scripts = Get-ChildItem -Path $dir.FullName -Filter '*.ps1' -File
        foreach ($s in $scripts) {
            try {
                . $s.FullName
                Write-Verbose "[LOAD] Provider: $($s.Name)"
            }
            catch {
                $message = "Provider-Skript fehlgeschlagen: $($s.FullName) - $_"
                $script:ModuleLoadErrors.Add($message)
                Write-Warning $message
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
                $message = "Provider-Metadaten fehlgeschlagen: $($dir.Name) - $_"
                $script:ModuleLoadErrors.Add($message)
                Write-Warning $message
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
            $message = "Fehler beim Laden von $($file.FullName): $_"
            $script:ModuleLoadErrors.Add($message)
            Write-Warning $message
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
            $message = "Fehler beim Laden von $($file.FullName): $_"
            $script:ModuleLoadErrors.Add($message)
            Write-Warning $message
        }
    }
}

if ($script:ModuleLoadErrors.Count -gt 0) {
    throw "SQL_SERVER_LAB_MODULE_LOAD_FAILED:`n$($script:ModuleLoadErrors -join "`n")"
}

$requiredInternalFunctions = @(
    'Get-LabEnvironmentResources'
    'Set-LabEnvironmentResources'
)
$missingInternalFunctions = @($requiredInternalFunctions | Where-Object {
    -not (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue)
})
if ($missingInternalFunctions.Count -gt 0) {
    throw "SQL_SERVER_LAB_MODULE_CONTRACT_INCOMPLETE: $($missingInternalFunctions -join ', ')"
}

Write-Verbose "[LOAD] SqlServerLab geladen. Provider: $($script:RegisteredProviders.Keys -join ', ')"
