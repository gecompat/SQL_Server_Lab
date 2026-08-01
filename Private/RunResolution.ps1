<#
.SYNOPSIS
    Gemeinsame Aufloesung von RunId und InstanceId in ein Verbindungsziel.
.DESCRIPTION
    Liest runs/<RunId>/connection-info.json und liefert Host, Port, Provider,
    Containername und SQL-Version der gewuenschten Instanz. Wird von den
    run-basierten Cmdlets (Restore, Project Adapter) gemeinsam genutzt.
#>

function Resolve-LabRunInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$InstanceId = 'primary',
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $connectionInfoPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionInfoPath -PathType Leaf)) {
        throw "Connection-Info nicht gefunden fuer Run '$RunId'."
    }

    $connectionInfo = Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 20
    $instances = @($connectionInfo.instances | Where-Object { $_.id -eq $InstanceId })
    if ($instances.Count -eq 0) {
        throw "Instanz '$InstanceId' nicht in Run '$RunId' gefunden."
    }
    if ($instances.Count -gt 1) {
        throw "Instanz-ID '$InstanceId' ist in Run '$RunId' nicht eindeutig."
    }

    $instance = $instances[0]
    if ([string]::IsNullOrWhiteSpace([string]$instance.provider) -or
        [string]::IsNullOrWhiteSpace([string]$instance.containerName) -or
        -not $instance.port) {
        throw "Connection-Info fuer Instanz '$InstanceId' in Run '$RunId' ist unvollstaendig."
    }

    return [PSCustomObject]@{
        HostName      = if ($instance.host) { [string]$instance.host } else { '127.0.0.1' }
        Port          = [int]$instance.port
        Provider      = [string]$instance.provider
        ContainerName = [string]$instance.containerName
        Version       = [string]$instance.version
    }
}
