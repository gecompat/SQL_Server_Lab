<#
.SYNOPSIS
    Podman-Provider fuer SQL_Server_Lab.
.DESCRIPTION
    Implementiert Verfuegbarkeit, Portsuche, Provisionierung, Status und
    scopegebundenen Lifecycle fuer Podman, einschliesslich rootless Betrieb.
#>

function Test-PodmanAvailable {
    [CmdletBinding()]
    param()

    try {
        $versionOutput = podman version --format '{{.Client.Version}}' 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{
                Available = $false
                Version   = $null
                Message   = "Podman nicht erreichbar: $(($versionOutput | Out-String).Trim())"
            }
        }

        podman info 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{
                Available = $false
                Version   = ([string]$versionOutput).Trim()
                Message   = 'Podman ist installiert, aber die Runtime ist nicht erreichbar.'
            }
        }

        return [PSCustomObject]@{
            Available = $true
            Version   = ([string]$versionOutput).Trim()
            Message   = ''
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Version   = $null
            Message   = "Podman-Befehl fehlgeschlagen: $($_.Exception.Message)"
        }
    }
}

function Find-PodmanAvailablePort {
    [CmdletBinding()]
    param(
        [int]$RangeStart = 14330,
        [int]$RangeEnd = 14399
    )

    return Find-LabAvailablePort -RangeStart $RangeStart -RangeEnd $RangeEnd
}

function New-PodmanInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [int]$Port = 0,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidateSet('compact', 'standard', 'performance')]
        [string]$Profile = 'standard',
        [array]$Drives = @()
    )

    $image = Get-SqlServerDockerImage -VersionId $VersionId
    $profileDefinition = Get-LabResourceProfile -Name $Profile
    $memoryLimit = "$($profileDefinition.maxMemoryMB)m"
    $cpuLimit = [string]$profileDefinition.maxCpus
    $containerName = "sql-lab-$InstanceId-$($RunId.Substring(0, 8))"

    $volumeArguments = @()
    foreach ($drive in @($Drives)) {
        if (-not $drive -or -not $drive.containerPath) {
            continue
        }

        $volumeSource = if ($drive.hostPath) {
            [string]$drive.hostPath
        }
        else {
            "sql-lab-${containerName}-$($drive.id)"
        }

        $volumeArguments += '-v'
        $volumeArguments += "${volumeSource}:$($drive.containerPath)"
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        return Invoke-LabPortAllocationLock -Action {
            $automaticPort = $Port -eq 0
            $nextPort = if ($automaticPort) { 14330 } else { $Port }
            $selectedPort = $null
            $output = $null

            while ($true) {
                $selectedPort = if ($automaticPort) {
                    Find-PodmanAvailablePort -RangeStart $nextPort -RangeEnd 14399
                }
                else {
                    $Port
                }

                $podmanArguments = @(
                    'run', '-d',
                    '--name', $containerName,
                    '-p', "${selectedPort}:1433",
                    '-e', 'ACCEPT_EULA=Y',
                    '-e', "MSSQL_SA_PASSWORD=$saPlain",
                    '-e', 'MSSQL_PID=Developer',
                    '-e', 'MSSQL_AGENT_ENABLED=true',
                    '--memory', $memoryLimit,
                    '--cpus', $cpuLimit,
                    '--label', "sql-server-lab.run-id=$RunId",
                    '--label', "sql-server-lab.scope-id=$ScopeId",
                    '--label', "sql-server-lab.instance-id=$InstanceId",
                    '--label', "sql-server-lab.version=$VersionId",
                    '--label', 'sql-server-lab.provider=podman',
                    '--label', "sql-server-lab.created-at=$(Get-LabTimestamp)",
                    '--health-cmd', '/opt/mssql-tools*/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" -b',
                    '--health-interval', '5s',
                    '--health-timeout', '3s',
                    '--health-retries', '30',
                    $volumeArguments,
                    $image
                )

                Write-LabInfo "Container erstellen: $containerName (Port $selectedPort, Image $image) [Podman]"
                $output = podman @podmanArguments 2>&1
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0) {
                    break
                }

                $outputText = ($output | Out-String).Trim()
                $bindConflict = $outputText -match '(?i)(address already in use|port is already allocated|cannot bind tcp port)'
                if (-not $automaticPort -or -not $bindConflict -or $selectedPort -ge 14399) {
                    throw "Podman-Container konnte nicht erstellt werden: $outputText"
                }

                podman rm -f $containerName 1>$null 2>$null
                $nextPort = $selectedPort + 1
                Write-LabWarning "Port $selectedPort wurde beim Runtime-Bindungsschritt belegt. Podman versucht Port $nextPort."
            }

            $containerId = $output |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ -match '^[0-9a-f]{12,64}$' } |
                Select-Object -Last 1
            if (-not $containerId) {
                throw "Podman lieferte keine gueltige Container-ID: $(($output | Out-String).Trim())"
            }

            [PSCustomObject]@{
                ContainerId   = $containerId
                ContainerName = $containerName
                Port          = $selectedPort
                InstanceId    = $InstanceId
                VersionId     = $VersionId
                Provider      = 'podman'
                Image         = $image
                Status        = 'Created'
            }
        }
    }
    finally {
        $saPlain = $null
    }
}

function Get-PodmanInstanceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName
    )

    try {
        $inspect = podman inspect $ContainerIdOrName 2>$null | ConvertFrom-Json -Depth 30
        if ($LASTEXITCODE -ne 0 -or -not $inspect) {
            return [PSCustomObject]@{
                Exists  = $false
                Running = $false
                Healthy = $false
                Raw     = $null
            }
        }

        $item = @($inspect)[0]
        $health = if ($item.State.Health) { [string]$item.State.Health.Status } else { $null }
        return [PSCustomObject]@{
            Exists  = $true
            Running = $item.State.Status -eq 'running'
            Healthy = $health -eq 'healthy'
            Raw     = [string]$item.State.Status
        }
    }
    catch {
        return [PSCustomObject]@{
            Exists  = $false
            Running = $false
            Healthy = $false
            Raw     = $_.Exception.Message
        }
    }
}

function Start-PodmanInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName
    )

    podman start $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Podman-Container konnte nicht gestartet werden: $ContainerIdOrName"
    }
}

function Stop-PodmanInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [int]$TimeoutSeconds = 30
    )

    podman stop -t $TimeoutSeconds $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Podman-Container konnte nicht gestoppt werden: $ContainerIdOrName"
    }
}

function Remove-PodmanInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    $inspect = podman inspect $ContainerIdOrName 2>$null | ConvertFrom-Json -Depth 30
    if ($LASTEXITCODE -ne 0 -or -not $inspect) {
        Write-LabWarning "Container nicht gefunden: $ContainerIdOrName (bereits entfernt?)"
        return
    }

    $item = @($inspect)[0]
    $scopeId = [string]$item.Config.Labels.'sql-server-lab.scope-id'
    if ($scopeId -ne $ExpectedScopeId) {
        throw "SCOPE_MISMATCH: Container gehoert zu Scope '$scopeId', erwartet '$ExpectedScopeId'. Entfernung verweigert."
    }

    podman rm -f $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Podman-Container konnte nicht entfernt werden: $ContainerIdOrName"
    }

    Write-LabSuccess "Container entfernt: $ContainerIdOrName"
}

function Get-PodmanLabContainers {
    [CmdletBinding()]
    param(
        [string]$RunId,
        [string]$ScopeId
    )

    $filters = @('--filter', 'label=sql-server-lab.run-id')
    if ($RunId) {
        $filters = @('--filter', "label=sql-server-lab.run-id=$RunId")
    }
    elseif ($ScopeId) {
        $filters = @('--filter', "label=sql-server-lab.scope-id=$ScopeId")
    }

    $containerIds = podman ps -a -q @filters 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $containerIds) {
        return @()
    }

    $results = @()
    foreach ($containerIdValue in @($containerIds)) {
        $containerId = ([string]$containerIdValue).Trim()
        if (-not $containerId) {
            continue
        }

        $inspect = podman inspect $containerId 2>$null | ConvertFrom-Json -Depth 30
        if ($LASTEXITCODE -ne 0 -or -not $inspect) {
            continue
        }

        $item = @($inspect)[0]
        $labels = $item.Config.Labels
        $results += [PSCustomObject]@{
            Provider    = 'podman'
            ContainerId = $containerId
            Name        = ([string]$item.Name).TrimStart('/')
            Status      = [string]$item.State.Status
            RunId       = [string]$labels.'sql-server-lab.run-id'
            ScopeId     = [string]$labels.'sql-server-lab.scope-id'
            InstanceId  = [string]$labels.'sql-server-lab.instance-id'
            Version     = [string]$labels.'sql-server-lab.version'
        }
    }

    return $results
}
