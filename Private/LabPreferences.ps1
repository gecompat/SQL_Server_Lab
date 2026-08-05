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
    $preferencePath = Get-LabProjectPreferencesPath
    if ($preferencePath) {
        $directory = Split-Path -Parent $preferencePath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        Write-LabArtifactJsonAtomic -Path $preferencePath -InputObject ([PSCustomObject]@{
            schemaVersion = 1
            mediaRoot = $resolved
            updatedAt = Get-LabTimestamp
        })
    }
    return $resolved
}
