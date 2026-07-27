<#
.SYNOPSIS
    Ergaenzt die neustartfaehige TempDB-Konfiguration um Provider-Erkennung.
.DESCRIPTION
    New-SqlServerLab uebergibt derzeit den Container-Namen, aber nicht explizit
    den Provider an Set-LabServerConfig. Der Wrapper ermittelt ihn eindeutig
    anhand des vorhandenen Containers und ruft danach die restartfaehige
    Implementierung auf.
#>

$script:RestartAwareSetLabServerConfig = ${function:Set-LabServerConfig}

function Set-LabServerConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$ContainerName,
        [ValidateSet('docker', 'podman')][string]$Provider
    )

    $effectiveProvider = $Provider
    if ($Config.tempdb -and -not $effectiveProvider) {
        if (-not $ContainerName) {
            throw 'TempDB-Pfadkonfiguration erfordert einen ContainerName.'
        }
        $effectiveProvider = Resolve-LabContainerProvider -ContainerName $ContainerName
    }

    & $script:RestartAwareSetLabServerConfig `
        -Config $Config `
        -HostName $HostName `
        -Port $Port `
        -SaPassword $SaPassword `
        -ContainerName $ContainerName `
        -Provider $effectiveProvider
}
