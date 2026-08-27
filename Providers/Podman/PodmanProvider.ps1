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

function Initialize-PodmanSqlNamedVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$VolumeName,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId
    )

    $null = podman volume inspect $VolumeName 2>$null
    if ($LASTEXITCODE -eq 0) { return $false }

    $created = podman volume create `
        --label "sql-server-lab.run-id=$RunId" `
        --label "sql-server-lab.scope-id=$ScopeId" `
        $VolumeName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "PODMAN_SQL_VOLUME_CREATE_FAILED: $VolumeName - $(@($created) -join ' ')"
    }

    $initialized = podman run --rm --user 0:0 --entrypoint /bin/sh `
        -v "${VolumeName}:/sql-lab-volume-init" $Image `
        -c 'chown -R 10001:0 /sql-lab-volume-init && chmod 0770 /sql-lab-volume-init' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "PODMAN_SQL_VOLUME_INITIALIZATION_FAILED: $VolumeName - $(@($initialized) -join ' ')"
    }
    return $true
}

function New-PodmanInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [int]$Port = 0,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidateSet('compact', 'standard', 'performance')]
        [string]$Profile = 'standard',
        [array]$Drives = @(),
        [string]$NetworkName,
        [ValidateRange(0,64)][decimal]$Cpu = 0,
        [ValidateRange(0,1048576)][int]$MemoryMB = 0,
        [ValidateSet('on', 'off')][string]$AutoStart = 'off',
        [ValidatePattern('^[A-Za-z0-9_]{1,128}$')][string]$Collation = 'SQL_Latin1_General_CP1_CI_AS'
    )

    $image = Get-SqlServerDockerImage -VersionId $VersionId
    $profileDefinition = Get-LabResourceProfile -Name $Profile
    $effectiveMemoryMB = if ($MemoryMB -gt 0) { $MemoryMB } else { [int]$profileDefinition.maxMemoryMB }
    $effectiveCpu = if ($Cpu -gt 0) { $Cpu } else { [decimal]$profileDefinition.maxCpus }
    $memoryLimit = "${effectiveMemoryMB}m"
    $cpuLimit = $effectiveCpu.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    $containerName = if ($LabName) { Get-LabContainerRuntimeName -LabName $LabName -InstanceId $InstanceId -RunId $RunId } else { "sql-lab-$InstanceId-$($RunId.Substring(0, 8))" }
    $labNetwork = Ensure-LabPodmanNetwork -Name $NetworkName

    $volumeArguments = @()
    foreach ($drive in @($Drives)) {
        if (-not $drive -or -not $drive.containerPath) {
            continue
        }

        $volumeSource = if ($drive.hostPath) {
            [string]$drive.hostPath
        }
        elseif ($drive.volumeName) {
            [string]$drive.volumeName
        }
        else {
            "sql-lab-${containerName}-$($drive.id)"
        }

        if (-not $drive.hostPath) {
            $null = Initialize-PodmanSqlNamedVolume -VolumeName $volumeSource -Image $image -RunId $RunId -ScopeId $ScopeId
        }

        $volumeArguments += '-v'
        $volumeTarget = "${volumeSource}:$($drive.containerPath)"
        $volumeOptions = @()
        if (-not $drive.hostPath) { $volumeOptions += 'U' }
        if ($drive.readOnly -eq $true) { $volumeOptions += 'ro' }
        if ($volumeOptions.Count -gt 0) {
            $volumeTarget = "${volumeTarget}:$($volumeOptions -join ',')"
        }
        $volumeArguments += $volumeTarget
    }

    $collationArguments = @()
    if ($Collation -ne 'SQL_Latin1_General_CP1_CI_AS') {
        $collationArguments = @('-e', "MSSQL_COLLATION=$Collation")
    }
    $restartArguments = if ($AutoStart -eq 'on') { @('--restart', 'unless-stopped') } else { @() }

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
                    '--network', $labNetwork.Name,
                    '-p', "${selectedPort}:1433",
                    '-e', 'ACCEPT_EULA=Y',
                    '-e', "MSSQL_SA_PASSWORD=$saPlain",
                    '-e', 'MSSQL_PID=Developer',
                    '-e', 'MSSQL_AGENT_ENABLED=true'
                ) + $collationArguments + $restartArguments + @(
                    '--memory', $memoryLimit,
                    '--cpus', $cpuLimit,
                    '--label', "sql-server-lab.run-id=$RunId",
                    '--label', "sql-server-lab.scope-id=$ScopeId",
                    '--label', "sql-server-lab.instance-id=$InstanceId",
                    '--label', "sql-server-lab.version=$VersionId",
                    '--label', 'sql-server-lab.provider=podman',
                    '--label', "sql-server-lab.autostart=$AutoStart",
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
                AutoStart     = $AutoStart
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
                AutoStart = $false
                Inspect  = $null
                Raw     = $null
            }
        }

        $item = @($inspect)[0]
        $health = if ($item.State.Health) { [string]$item.State.Health.Status } else { $null }
        return [PSCustomObject]@{
            Exists  = $true
            Running = $item.State.Status -eq 'running'
            Healthy = $health -eq 'healthy'
            AutoStart = [string]$item.HostConfig.RestartPolicy.Name -in @('always', 'unless-stopped')
            Inspect  = $item
            Raw     = [string]$item.State.Status
        }
    }
    catch {
        return [PSCustomObject]@{
            Exists  = $false
            Running = $false
            Healthy = $false
            AutoStart = $false
            Inspect  = $null
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
    if (Get-Command Remove-LabContainerAutoStartCoordinatorIfUnused -ErrorAction SilentlyContinue) {
        Remove-LabContainerAutoStartCoordinatorIfUnused -Provider podman
    }
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
            AutoStart   = [string]$labels.'sql-server-lab.autostart' -eq 'on'
        }
    }

    return $results
}
