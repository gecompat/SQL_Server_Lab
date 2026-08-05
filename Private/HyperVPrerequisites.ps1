<#
.SYNOPSIS
    Erkennt und installiert die fuer lokale Hyper-V-Labs erforderlichen Windows-Komponenten.
.DESCRIPTION
    Die Installation wird nie ungefragt gestartet und fuehrt keinen automatischen
    Neustart aus. Nach einer erfolgreich installierten Rolle meldet der Aufrufer
    einen notwendigen Neustart klar, damit kein laufender Runner unerwartet
    unterbrochen wird.
#>

function Test-LabHyperVInstallCapability {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { return [PSCustomObject]@{ Supported = $false; Kind = $null; Message = 'Hyper-V ist nur unter Windows installierbar.' } }
    if (-not (Test-LabAdministrator)) { return [PSCustomObject]@{ Supported = $false; Kind = $null; Message = 'Hyper-V-Installation benoetigt eine erhöhte PowerShell-Sitzung.' } }
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        return [PSCustomObject]@{ Supported = $true; Kind = 'server'; Message = '' }
    }
    if (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        return [PSCustomObject]@{ Supported = $true; Kind = 'client'; Message = '' }
    }
    return [PSCustomObject]@{ Supported = $false; Kind = $null; Message = 'Weder ServerManager noch WindowsOptionalFeature ist verfuegbar.' }
}

function Install-LabHyperVPrerequisites {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $capability = Test-LabHyperVInstallCapability
    if (-not $capability.Supported) { throw "HYPERV_INSTALL_NOT_AVAILABLE: $($capability.Message)" }
    if ($capability.Kind -eq 'server') {
        if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Hyper-V-Rolle inklusive Management Tools installieren')) { return }
        $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -ErrorAction Stop
        return [PSCustomObject]@{
            Platform = 'WindowsServer'; Succeeded = [bool]$result.Success
            RestartRequired = ([string]$result.RestartNeeded -match 'Yes|True')
            Details = [string]$result.ExitCode
        }
    }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Hyper-V-Plattform inklusive Management Tools installieren')) { return }
    $result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop
    return [PSCustomObject]@{
        Platform = 'WindowsClient'; Succeeded = ([string]$result.State -in @('Enabled', 'EnablePending'))
        RestartRequired = [bool]$result.RestartNeeded; Details = [string]$result.State
    }
}
