<#
.SYNOPSIS
    Podman-Provider fuer SQL_Server_Lab.
.DESCRIPTION
    Implementiert das Provider-Interface fuer Podman (rootless containers).
    CLI weitgehend Docker-kompatibel. Verwaltet Container-Lifecycle,
    Labels, Ports und Health-Checks.
    HINWEIS: Diese Datei muss .ps1 sein (nicht .psm1), damit
    dot-source im Modul-Kontext korrekt funktioniert.
#>

# =============================================================================
# Provider-Verfuegbarkeit
# =============================================================================

function Test-PodmanAvailable {
    <#
    .SYNOPSIS Prueft ob Podman verfuegbar und funktional ist.
    .OUTPUTS PSCustomObject mit Available (bool), Version, Message.
    #>
    [CmdletBinding()]
    param()

    try {
        $versionOutput = podman version --format '{{.Client.Version}}' 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ Available = $false; Version = $null; Message = "Podman nicht erreichbar: $versionOutput" }
        }
        $version = $versionOutput.Trim()

        # Pruefen ob podman machine laeuft (Windows/Mac) oder native (Linux)
        if (-not $IsLinux) {
            $machineInfo = podman machine info 2>&1
            if ($LASTEXITCODE -ne 0) {
                return [PSCustomObject]@{ Available = $false; Version = $version; Message = "Podman Machine nicht gestartet. Bitte 'podman machine start' ausfuehren." }
            }
        }

        return [PSCustomObject]@{ Available = $true; Version = $version; Message = '' }
    }
    catch {
        return [PSCustomObject]@{ Available = $false; Version = $null; Message = "Podman-Befehl fehlgeschlagen: $_" }
    }
}

# =============================================================================
# Port-Management
# =============================================================================

function Find-PodmanAvailablePort {
    <#
    .SYNOPSIS Findet einen freien Port im Lab-Bereich (14330-14399).
    #>
    [CmdletBinding()]
    param(
        [int]$RangeStart = 14330,
        [int]$RangeEnd = 14399
    )

    # Bereits belegte Ports durch Lab-Container
    $usedPorts = @()
    try {
        $containers = podman ps --filter 'label=sql-server-lab.run-id' --format '{{.Ports}}' 2>$null
        if ($containers) {
            $usedPorts = $containers | ForEach-Object {
                if ($_ -match ':(\d+)->1433') { [int]$Matches[1] }
            } | Where-Object { $_ }
        }
    } catch { }

    for ($port = $RangeStart; $port -le $RangeEnd; $port++) {
        if ($port -notin $usedPorts) {
            # TCP-Pruefung
            try {
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
                $listener.Start()
                $listener.Stop()
                return $port
            } catch { continue }
        }
    }

    throw "Kein freier Port im Bereich $RangeStart-$RangeEnd gefunden."
}

# =============================================================================
# Container-Lifecycle
# =============================================================================

function New-PodmanInstance {
    <#
    .SYNOPSIS Erzeugt einen neuen SQL-Server-Container via Podman.
    .OUTPUTS PSCustomObject mit ContainerId, Port, Name, Status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [int]$Port = 0,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidateSet('compact','standard','performance')]
        [string]$Profile = 'standard'
    )

    # Image ermitteln
    $image = Get-SqlServerDockerImage -VersionId $VersionId

    # Port zuweisen
    if ($Port -eq 0) { $Port = Find-PodmanAvailablePort }

    # Passwort als Klartext (nur fuer podman run)
    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    # Ressourcen-Limits
    $profileDef = Get-LabResourceProfile -Name $Profile
    $memoryLimit = "$($profileDef.maxMemoryMB)m"
    $cpuLimit = $profileDef.maxCpus

    # Container-Name
    $containerName = "sql-lab-$InstanceId-$($RunId.Substring(0,8))"

    # Podman run (CLI weitgehend Docker-kompatibel)
    $podmanArgs = @(
        'run', '-d',
        '--name', $containerName,
        '-p', "${Port}:1433",
        '-e', 'ACCEPT_EULA=Y',
        '-e', "MSSQL_SA_PASSWORD=$saPlain",
        '-e', 'MSSQL_PID=Developer',
        '--memory', $memoryLimit,
        '--cpus', $cpuLimit.ToString(),
        '--label', "sql-server-lab.run-id=$RunId",
        '--label', "sql-server-lab.scope-id=$ScopeId",
        '--label', "sql-server-lab.instance-id=$InstanceId",
        '--label', "sql-server-lab.version=$VersionId",
        '--label', "sql-server-lab.provider=podman",
        '--label', "sql-server-lab.created-at=$(Get-LabTimestamp)",
        '--health-cmd', '/opt/mssql-tools*/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" -b',
        '--health-interval', '5s',
        '--health-timeout', '3s',
        '--health-retries', '30',
        $image
    )

    # Passwort sofort loeschen
    $saPlain = $null

    Write-LabInfo "Container erstellen: $containerName (Port $Port, Image $image) [Podman]"
    $containerId = podman @podmanArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Podman-Container konnte nicht erstellt werden: $containerId"
    }

    $containerId = $containerId.Trim()

    return [PSCustomObject]@{
        ContainerId   = $containerId
        ContainerName = $containerName
        Port          = $Port
        InstanceId    = $InstanceId
        VersionId     = $VersionId
        Image         = $image
        Status        = 'Created'
    }
}

function Get-PodmanInstanceStatus {
    <#
    .SYNOPSIS Status eines Lab-Containers abfragen (Podman).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ContainerIdOrName)

    $info = podman inspect $ContainerIdOrName --format '{{.State.Status}}|{{.State.Health.Status}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Exists = $false; Running = $false; Healthy = $false; Raw = $info }
    }

    $parts = $info.Trim().Split('|')
    return [PSCustomObject]@{
        Exists  = $true
        Running = $parts[0] -eq 'running'
        Healthy = if ($parts.Count -gt 1) { $parts[1] -eq 'healthy' } else { $false }
        Raw     = $info.Trim()
    }
}

function Start-PodmanInstance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ContainerIdOrName)
    podman start $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Podman-Container konnte nicht gestartet werden: $ContainerIdOrName" }
}

function Stop-PodmanInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [int]$TimeoutSeconds = 10
    )
    podman stop -t $TimeoutSeconds $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Podman-Container konnte nicht gestoppt werden: $ContainerIdOrName" }
}

function Remove-PodmanInstance {
    <#
    .SYNOPSIS Entfernt einen Lab-Container (mit Scope-Pruefung) via Podman.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    # Scope verifizieren via podman inspect (JSON-basiert, keine Quote-Probleme)
    $inspectJson = podman inspect $ContainerIdOrName 2>$null | ConvertFrom-Json
    if (-not $inspectJson) {
        Write-LabWarning "Container nicht gefunden: $ContainerIdOrName (bereits entfernt?)"
        return
    }

    $scopeLabel = $inspectJson[0].Config.Labels.'sql-server-lab.scope-id'
    if ($scopeLabel -ne $ExpectedScopeId) {
        throw "SCOPE_MISMATCH: Container gehoert zu Scope '$scopeLabel', erwartet '$ExpectedScopeId'. Entfernung verweigert."
    }

    # Stoppen falls laufend
    $status = Get-PodmanInstanceStatus -ContainerIdOrName $ContainerIdOrName
    if ($status.Running) {
        podman stop -t 10 $ContainerIdOrName | Out-Null
    }

    # Entfernen
    podman rm -f $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Podman-Container konnte nicht entfernt werden: $ContainerIdOrName"
    }

    Write-LabSuccess "Container entfernt: $ContainerIdOrName"
}

function Get-PodmanLabContainers {
    <#
    .SYNOPSIS Listet alle Lab-Container via Podman (optional gefiltert).
    #>
    [CmdletBinding()]
    param(
        [string]$RunId,
        [string]$ScopeId
    )

    $filter = @('--filter', 'label=sql-server-lab.run-id')
    if ($RunId)   { $filter = @('--filter', "label=sql-server-lab.run-id=$RunId") }
    if ($ScopeId) { $filter = @('--filter', "label=sql-server-lab.scope-id=$ScopeId") }

    # JSON-basiert statt format-String (vermeidet Quote-Probleme auf Windows)
    $containerIds = podman ps -a -q @filter 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $containerIds) { return @() }

    $results = @()
    @($containerIds) | ForEach-Object {
        $id = $_.Trim()
        if (-not $id) { return }
        $inspectJson = podman inspect $id 2>$null | ConvertFrom-Json
        if ($inspectJson) {
            $labels = $inspectJson[0].Config.Labels
            $results += [PSCustomObject]@{
                ContainerId = $id.Substring(0, [Math]::Min(12, $id.Length))
                Name        = $inspectJson[0].Name
                Status      = $inspectJson[0].State.Status
                InstanceId  = $labels.'sql-server-lab.instance-id'
                Version     = $labels.'sql-server-lab.version'
                RunId       = $labels.'sql-server-lab.run-id'
            }
        }
    }
    return $results
}
