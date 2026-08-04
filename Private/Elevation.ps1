<#
.SYNOPSIS
    Stellt den interaktiven UAC-Uebergang fuer Hyper-V-Aktionen bereit.
.DESCRIPTION
    Hyper-V-Switches, virtuelle Maschinen und deren Hostadapter duerfen nur
    in einer erhöhten Windows-Sitzung geaendert werden. Der interaktive
    Einstieg oeffnet bei Bedarf einen separaten, sichtbaren UAC-Prozess und
    uebergibt ihm die gewaehlte Lab-Aktion.
#>

function Test-LabAdministrator {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-LabElevatedAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Image')]
        [string]$Action
    )

    if (-not $IsWindows) { throw 'LAB_ELEVATION_WINDOWS_REQUIRED' }
    if (Test-LabAdministrator) {
        return [PSCustomObject]@{ Started = $false; Reason = 'ALREADY_ELEVATED' }
    }

    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pwsh) { throw 'LAB_ELEVATION_PWSH_NOT_FOUND' }
    $modulePath = Join-Path $script:ModuleRoot 'SqlServerLab.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'LAB_ELEVATION_MODULE_NOT_FOUND' }

    $escapedModulePath = $modulePath.Replace("'", "''")
    # Import-Module besitzt keinen -LiteralPath-Parameter. Der einzeln
    # quotierte, zuvor maskierte Pfad verhindert weiterhin eine Auswertung
    # von Leerzeichen oder Sonderzeichen im Modulpfad.
    $command = "Import-Module '$escapedModulePath' -Force; Invoke-SqlServerLab -Action $Action"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath $pwsh.Source -Verb RunAs -ArgumentList @('-NoProfile', '-NoExit', '-EncodedCommand', $encodedCommand) -ErrorAction Stop
    return [PSCustomObject]@{ Started = $true; Reason = 'UAC_PROMPTED'; Action = $Action }
}
