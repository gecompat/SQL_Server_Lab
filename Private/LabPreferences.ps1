<#
.SYNOPSIS
    Lokale Einstellungen fuer interaktive Lab-Aktionen.
#>

function Get-LabProjectPreferencesPath {
    [CmdletBinding()]
    param()

    if (-not $script:ModuleRoot) { return $null }
    return Join-Path (Join-Path $script:ModuleRoot '.local') 'preferences.json'
}

function Get-LabProjectMediaRootDefault {
    [CmdletBinding()]
    param()

    $path = Get-LabProjectPreferencesPath
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $preferences = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 5
        $mediaRoot = [string]$preferences.mediaRoot
        if ($mediaRoot -and (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
            return (Resolve-Path -LiteralPath $mediaRoot -ErrorAction Stop).Path
        }
    }
    catch { }
    return $null
}

function Get-LabProjectPreferenceValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $path = Get-LabProjectPreferencesPath
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $preferences = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
        return [string]$preferences.$Name
    }
    catch { return $null }
}

function Set-LabProjectPreferenceValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)

    $preferencePath = Get-LabProjectPreferencesPath
    if (-not $preferencePath) { return }
    $directory = Split-Path -Parent $preferencePath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    $preferences = [ordered]@{ schemaVersion = 1; updatedAt = Get-LabTimestamp }
    if (Test-Path -LiteralPath $preferencePath -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $preferencePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
            foreach ($property in @($existing.PSObject.Properties)) { $preferences[$property.Name] = $property.Value }
        }
        catch { }
    }
    $preferences[$Name] = $Value
    $preferences.updatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $preferencePath -InputObject ([PSCustomObject]$preferences)
}

function Get-LabMediaRootDefault {
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_MEDIA_ROOT,
        (Get-LabProjectMediaRootDefault),
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', 'User')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }
    return $null
}

function Set-LabMediaRootDefault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaRoot)

    $resolved = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $env:SQL_SERVER_LAB_MEDIA_ROOT = $resolved
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', $resolved, 'User')
    Set-LabProjectPreferenceValue -Name mediaRoot -Value $resolved
    return $resolved
}

function Get-LabDataRootDefault {
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_DATA_ROOT,
        (Get-LabProjectPreferenceValue -Name dataRoot),
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }
    return $null
}

function Set-LabDataRootDefault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $resolved = (Resolve-Path -LiteralPath $DataRoot -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'Labs') -PathType Container)) {
        throw 'LAB_DATA_ROOT_LAYOUT_REQUIRED: Data Root zuerst mit Initialize-SqlServerLabDataRoot.ps1 initialisieren.'
    }
    $env:SQL_SERVER_LAB_DATA_ROOT = $resolved
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', $resolved, 'User')
    Set-LabProjectPreferenceValue -Name dataRoot -Value $resolved
    return $resolved
}
