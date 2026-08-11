<#
.SYNOPSIS
    Lokale Einstellungen fuer interaktive Lab-Aktionen.
#>

function Get-LabProjectPreferencesPath {
    [CmdletBinding()]
    param()

    $configuredDataRoot = @(
        [string]$env:SQL_SERVER_LAB_DATA_ROOT,
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
    ) | Where-Object { $_ } | Select-Object -First 1
    if ($configuredDataRoot -and (Test-Path -LiteralPath $configuredDataRoot -PathType Container)) {
        return Join-Path (Join-Path $configuredDataRoot 'Catalog') 'preferences.json'
    }
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

function Get-LabTestDataRootDefault {
    <# Liefert die sichtbare, wiederverwendbare Testdaten-Bibliothek. #>
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_TEST_DATA_ROOT,
        (Get-LabProjectPreferenceValue -Name testDataRoot),
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_DATA_ROOT', 'User')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }

    $mediaRoot = Get-LabMediaRootDefault
    if ($mediaRoot) { return (Join-Path $mediaRoot 'Testdaten') }
    return $null
}

function Set-LabTestDataRootDefault {
    <# Speichert eine sichtbare Testdaten-Bibliothek außerhalb des Run-State. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TestDataRoot)

    $resolved = [System.IO.Path]::GetFullPath($TestDataRoot)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        New-Item -Path $resolved -ItemType Directory -Force | Out-Null
    }
    $resolved = (Resolve-Path -LiteralPath $resolved -ErrorAction Stop).Path
    $env:SQL_SERVER_LAB_TEST_DATA_ROOT = $resolved
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_TEST_DATA_ROOT', $resolved, 'User')
    Set-LabProjectPreferenceValue -Name testDataRoot -Value $resolved
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
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and (Test-LabDataRootOwnership -DataRoot $candidate)) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }
    return $null
}

function Set-LabDataRootDefault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    return Register-LabDataRoot -DataRoot $DataRoot -SetDefault
}

function Get-LabHyperVSwitchDefault {
    <# Liefert den zuletzt bewusst gewählten Hyper-V-Lab-Switch. #>
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_HYPERV_NETWORK,
        (Get-LabProjectPreferenceValue -Name hyperVSwitch),
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_HYPERV_NETWORK', 'User')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
            if (Get-VMSwitch -Name $candidate -ErrorAction SilentlyContinue) { return $candidate }
        }
    }
    return $null
}

function Set-LabHyperVSwitchDefault {
    <# Speichert einen vorhandenen Switch als Standard für neue Host-SSMS-fähige Labs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SwitchName)

    if (-not (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) -or -not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        throw "HYPERV_SWITCH_NOT_FOUND: $SwitchName"
    }
    $env:SQL_SERVER_LAB_HYPERV_NETWORK = $SwitchName
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_HYPERV_NETWORK', $SwitchName, 'User')
    Set-LabProjectPreferenceValue -Name hyperVSwitch -Value $SwitchName
    return $SwitchName
}
