<#
.SYNOPSIS
    Docker-Provider fuer SQL_Server_Lab.
.DESCRIPTION
    Implementiert das Provider-Interface fuer Docker Engine/Desktop.
    Verwaltet Container-Lifecycle, Labels, Ports und Health-Checks.
    HINWEIS: Diese Datei muss .ps1 sein (nicht .psm1), damit
    dot-source im Modul-Kontext korrekt funktioniert.
#>

# =============================================================================
# Provider-Verfuegbarkeit
# =============================================================================

function Test-DockerAvailable {
    <#
    .SYNOPSIS Prueft ob Docker verfuegbar und funktional ist.
    .OUTPUTS PSCustomObject mit Available (bool), Version, Message.
    #>
    [CmdletBinding()]
    param()

    try {
        $info = docker info --format '{{.ServerVersion}}' 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ Available = $false; Version = $null; Message = "Docker nicht erreichbar: $info" }
        }
        return [PSCustomObject]@{ Available = $true; Version = $info.Trim(); Message = '' }
    }
    catch {
        return [PSCustomObject]@{ Available = $false; Version = $null; Message = "Docker-Befehl fehlgeschlagen: $_" }
    }
}

# =============================================================================
# Port-Management
# =============================================================================

function Find-AvailablePort {
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
        $containers = docker ps --filter 'label=sql-server-lab.run-id' --format '{{.Ports}}' 2>$null
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

function New-DockerInstance {
    <#
    .SYNOPSIS Erzeugt einen neuen SQL-Server-Container.
    .PARAMETER VersionId SQL-Server-Version (2019, 2022, 2025).
    .PARAMETER RunId Die Run-ID fuer Labels.
    .PARAMETER ScopeId Die Scope-ID fuer Labels.
    .PARAMETER InstanceId Logische Instanz-ID.
    .PARAMETER Port Externer Port (oder auto).
    .PARAMETER SaPassword SecureString mit SA-Passwort.
    .PARAMETER Profile Ressourcenprofil (compact, standard, performance).
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
        [string]$Profile = 'standard',

        [array]$Drives = @()
    )

    # Image ermitteln
    $image = Get-SqlServerDockerImage -VersionId $VersionId

    # Port zuweisen
    if ($Port -eq 0) { $Port = Find-AvailablePort }

    # Passwort als Klartext (nur fuer docker run)
    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    # Ressourcen-Limits
    $profileDef = Get-LabResourceProfile -Name $Profile
    $memoryLimit = "$($profileDef.maxMemoryMB)m"
    $cpuLimit = $profileDef.maxCpus

    # Container-Name
    $containerName = "sql-lab-$InstanceId-$($RunId.Substring(0,8))"

    # Volume-Mounts fuer Drives
    $volumeArgs = @()
    foreach ($drv in $Drives) {
        if ($drv -and $drv.containerPath) {
            if ($drv.hostPath) {
                $volumeArgs += '-v'
                $volumeArgs += "$($drv.hostPath):$($drv.containerPath)"
            }
            else {
                # Named Volume (Docker verwaltet)
                $volName = "sql-lab-${containerName}-$($drv.id)"
                $volumeArgs += '-v'
                $volumeArgs += "${volName}:$($drv.containerPath)"
            }
        }
    }

    # Docker run
    $dockerArgs = @(
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
        '--label', "sql-server-lab.created-at=$(Get-LabTimestamp)",
        '--health-cmd', '/opt/mssql-tools*/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" -b',
        '--health-interval', '5s',
        '--health-timeout', '3s',
        '--health-retries', '30',
        @volumeArgs
        $image
    )

    # Passwort sofort loeschen
    $saPlain = $null

    Write-LabInfo "Container erstellen: $containerName (Port $Port, Image $image)"
    $containerId = docker @dockerArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Docker-Container konnte nicht erstellt werden: $containerId"
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

function Get-DockerInstanceStatus {
    <#
    .SYNOPSIS Status eines Lab-Containers abfragen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ContainerIdOrName)

    $info = docker inspect $ContainerIdOrName --format '{{.State.Status}}|{{.State.Health.Status}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Exists = $false; Running = $false; Healthy = $false; Raw = $info }
    }

    $parts = $info.Trim().Split('|')
    return [PSCustomObject]@{
        Exists  = $true
        Running = $parts[0] -eq 'running'
        Healthy = $parts[1] -eq 'healthy'
        Raw     = $info.Trim()
    }
}

function Start-DockerInstance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ContainerIdOrName)
    docker start $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Container konnte nicht gestartet werden: $ContainerIdOrName" }
}

function Stop-DockerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [int]$TimeoutSeconds = 30
    )
    docker stop -t $TimeoutSeconds $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Container konnte nicht gestoppt werden: $ContainerIdOrName" }
}

function Remove-DockerInstance {
    <#
    .SYNOPSIS Entfernt einen Lab-Container (mit Scope-Pruefung).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    # Scope verifizieren
    $scopeLabel = docker inspect $ContainerIdOrName --format '{{index .Config.Labels "sql-server-lab.scope-id"}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-LabWarning "Container nicht gefunden: $ContainerIdOrName (bereits entfernt?)"
        return
    }

    if ($scopeLabel.Trim() -ne $ExpectedScopeId) {
        throw "SCOPE_MISMATCH: Container gehoert zu Scope '$($scopeLabel.Trim())', erwartet '$ExpectedScopeId'. Entfernung verweigert."
    }

    # Stoppen falls laufend
    $status = Get-DockerInstanceStatus -ContainerIdOrName $ContainerIdOrName
    if ($status.Running) {
        docker stop -t 10 $ContainerIdOrName | Out-Null
    }

    # Entfernen
    docker rm -f $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Container konnte nicht entfernt werden: $ContainerIdOrName"
    }

    Write-LabSuccess "Container entfernt: $ContainerIdOrName"
}

function Get-DockerLabContainers {
    <#
    .SYNOPSIS Listet alle Lab-Container (optional gefiltert nach RunId/ScopeId).
    #>
    [CmdletBinding()]
    param(
        [string]$RunId,
        [string]$ScopeId
    )

    $filter = @('--filter', 'label=sql-server-lab.run-id')
    if ($RunId)   { $filter = @('--filter', "label=sql-server-lab.run-id=$RunId") }
    if ($ScopeId) { $filter = @('--filter', "label=sql-server-lab.scope-id=$ScopeId") }

    $format = '{{.ID}}|{{.Names}}|{{.Status}}|{{index .Labels "sql-server-lab.instance-id"}}|{{index .Labels "sql-server-lab.version"}}'
    $output = docker ps -a @filter --format $format 2>&1

    if ($LASTEXITCODE -ne 0 -or -not $output) { return @() }

    $output | ForEach-Object {
        $parts = $_.Split('|')
        [PSCustomObject]@{
            ContainerId = $parts[0]
            Name        = $parts[1]
            Status      = $parts[2]
            InstanceId  = $parts[3]
            Version     = $parts[4]
        }
    }
}
