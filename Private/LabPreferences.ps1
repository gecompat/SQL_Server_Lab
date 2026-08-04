<#
.SYNOPSIS
    Lokale, benutzerbezogene Einstellungen fuer interaktive Lab-Aktionen.
#>

function Get-LabMediaRootDefault {
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_MEDIA_ROOT,
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
    return $resolved
}
