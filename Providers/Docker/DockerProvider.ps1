<#
.SYNOPSIS
    Docker-Provider fuer SQL_Server_Lab.
.DESCRIPTION
    Implementiert Verfuegbarkeit, Portsuche, Provisionierung, Status und
    scopegebundenen Lifecycle fuer Docker Engine oder Docker Desktop.
#>

function Test-DockerAvailable {
    [CmdletBinding()]
    param()

    try {
        $dockerInvocation = Get-LabHostToolInvocation -Name docker
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Version   = $null
            Message   = 'Docker ist nicht installiert oder konnte nicht aufgeloest werden.'
        }
    }

    function Invoke-DockerClientProbe {
        param(
            [Parameter(Mandatory)][string]$Invocation,
            [Parameter(Mandatory)][string[]]$Arguments
        )

        $originalConfig = if (Test-Path Env:DOCKER_CONFIG) { $env:DOCKER_CONFIG } else { $null }
        $fallbackConfig = Join-Path $env:TEMP ("sql-lab-docker-config-{0}" -f [System.Guid]::NewGuid().ToString('N'))
        $attempts = @(
            @{ Config = $originalConfig; Label = 'Primary' },
            @{ Config = $fallbackConfig; Label = 'Fallback' }
        )
        $lastResult = [PSCustomObject]@{
            Success  = $false
            Output   = ''
            ExitCode = $null
            Message  = ''
        }

        try {
            foreach ($attempt in $attempts) {
                if ($attempt.Label -eq 'Fallback') {
                    New-Item -Path $attempt.Config -ItemType Directory -Force | Out-Null
                }

                if ($null -eq $attempt.Config) {
                    if (Test-Path Env:DOCKER_CONFIG) { Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue }
                }
                else {
                    $env:DOCKER_CONFIG = $attempt.Config
                }

                $output = & $Invocation @Arguments 2>&1
                $exitCode = $LASTEXITCODE
                $text = ($output | Out-String).Trim()
                $lastResult = [PSCustomObject]@{
                    Success  = ($exitCode -eq 0)
                    Output   = $text
                    ExitCode = $exitCode
                    Message  = $text
                }

                if ($exitCode -eq 0) {
                    return $lastResult
                }

                if (
                    $attempt.Label -eq 'Primary' -and
                    $text -match '(?i)Error loading config file|Zugriff verweigert|Permission denied'
                ) {
                    continue
                }
                return $lastResult
            }
            return $lastResult
        }
        finally {
            if ($null -eq $originalConfig) {
                if (Test-Path Env:DOCKER_CONFIG) { Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue }
            }
            else {
                $env:DOCKER_CONFIG = $originalConfig
            }
        }
    }

    try {
        $probe = Invoke-DockerClientProbe -Invocation $dockerInvocation -Arguments @('info', '--format', '{{.ServerVersion}}')
        if (-not $probe.Success) {
            return [PSCustomObject]@{
                Available = $false
                Version   = $null
                Message   = "Docker nicht erreichbar: $($probe.Message)"
            }
        }

        return [PSCustomObject]@{
            Available = $true
            Version   = ([string]$probe.Output).Trim()
            Message   = ''
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Version   = $null
            Message   = "Docker-Befehl fehlgeschlagen: $($_.Exception.Message)"
        }
    }
}

function Find-AvailablePort {
    [CmdletBinding()]
    param(
        [int]$RangeStart = 14330,
        [int]$RangeEnd = 14399
    )

    return Find-LabAvailablePort -RangeStart $RangeStart -RangeEnd $RangeEnd
}

function Initialize-DockerSqlNamedVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$VolumeName,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidatePattern('^/[A-Za-z0-9._/-]+$')][string]$ContainerPath,
        [string]$PersistentStorageId,
        [string]$Persistence,
        [switch]$SyncImageContent
    )

    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $inspectionOutput = @(& $dockerInvocation volume inspect $VolumeName 2>$null)
    $volumeExists = $LASTEXITCODE -eq 0

    if ($volumeExists -and $PersistentStorageId) {
        try { $inspection = @($inspectionOutput | ConvertFrom-Json -Depth 30 -ErrorAction Stop)[0] }
        catch { throw "DOCKER_SQL_VOLUME_INSPECT_INVALID: $VolumeName" }
        if ([string]$inspection.Labels.'sql-server-lab.persistent-storage-id' -ne $PersistentStorageId -or
            [string]$inspection.Labels.'sql-server-lab.sql-major-version' -ne $VersionId.Substring(0,4)) {
            throw "DOCKER_SQL_VOLUME_STABLE_ID_MISMATCH: $VolumeName"
        }
    }

    if (-not $volumeExists) {
        $labelArguments = @(
            '--label', "sql-server-lab.run-id=$RunId",
            '--label', "sql-server-lab.scope-id=$ScopeId",
            '--label', "sql-server-lab.instance-id=$InstanceId",
            '--label', "sql-server-lab.sql-major-version=$($VersionId.Substring(0,4))"
        )
        if ($Persistence) { $labelArguments += @('--label', "sql-server-lab.persistence=$Persistence") }
        if ($PersistentStorageId) { $labelArguments += @('--label', "sql-server-lab.persistent-storage-id=$PersistentStorageId") }
        $created = & $dockerInvocation volume create @labelArguments $VolumeName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "DOCKER_SQL_VOLUME_CREATE_FAILED: $VolumeName - $(@($created) -join ' ')"
        }
    }
    if ($volumeExists -and -not $SyncImageContent) { return $false }

    $initializationCommand = if ($SyncImageContent) {
        "if [ ! -d '$ContainerPath' ]; then exit 1; fi; cp -a '$ContainerPath'/. /sql-lab-volume-init/; chown --reference='$ContainerPath' /sql-lab-volume-init && chmod --reference='$ContainerPath' /sql-lab-volume-init"
    }
    else {
        'chown -R 10001:0 /sql-lab-volume-init && chmod 0770 /sql-lab-volume-init'
    }
    $initialized = & $dockerInvocation run --rm --user 0:0 --entrypoint /bin/sh `
        -v "${VolumeName}:/sql-lab-volume-init" $Image `
        -c $initializationCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "DOCKER_SQL_VOLUME_INITIALIZATION_FAILED: $VolumeName - $(@($initialized) -join ' ')"
    }
    return (-not $volumeExists)
}

function New-DockerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$ContainerName,
        [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$EndpointBindingIgnoreContainerName,
        [int]$Port = 0,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidateSet('compact', 'standard', 'performance')]
        [string]$Profile = 'standard',
        [array]$Drives = @(),
        [string]$NetworkName,
        [ValidateRange(0,64)][decimal]$Cpu = 0,
        [ValidateRange(0,1048576)][int]$MemoryMB = 0,
        [ValidateSet('on', 'off')][string]$AutoStart = 'off',
        [ValidatePattern('^[A-Za-z0-9_]{1,128}$')][string]$Collation = 'SQL_Latin1_General_CP1_CI_AS',
        [string]$ResolvedImage,
        [ValidateSet('none', 'sql2019-namespace-v1', 'sql2022-namespace-v1', 'sql2025-namespace-v1')][string]$ExternalRuntimeLaunchMode = 'none'
    )

    if ($ResolvedImage -and $ResolvedImage -notmatch '^[a-z0-9][a-z0-9./_-]+:[a-z0-9][a-z0-9._-]+$') {
        throw 'DOCKER_RESOLVED_IMAGE_INVALID'
    }
    if ($ExternalRuntimeLaunchMode -ne 'none' -and -not $ResolvedImage) {
        throw 'DOCKER_EXTERNAL_RUNTIME_IMAGE_REQUIRED'
    }
    if ($ResolvedImage -and $ExternalRuntimeLaunchMode -eq 'none') {
        throw 'DOCKER_RESOLVED_IMAGE_LAUNCH_MODE_REQUIRED'
    }
    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $image = if ($ResolvedImage) { $ResolvedImage } else { Get-SqlServerDockerImage -VersionId $VersionId }
    $profileDefinition = Get-LabResourceProfile -Name $Profile
    $effectiveMemoryMB = if ($MemoryMB -gt 0) { $MemoryMB } else { [int]$profileDefinition.maxMemoryMB }
    $effectiveCpu = if ($Cpu -gt 0) { $Cpu } else { [decimal]$profileDefinition.maxCpus }
    $memoryLimit = "${effectiveMemoryMB}m"
    # SQL Server 2019 erkennt cgroup-v2-Grenzen nicht zuverlaessig. Das eigene
    # SQL-Linux-Limit bleibt deshalb explizit unter dem harten Containerlimit
    # und reserviert 20 Prozent fuer SQLPAL, Agent und weitere Gastprozesse.
    $sqlMemoryLimitMB = [math]::Max(1024, [math]::Floor($effectiveMemoryMB * 0.8))
    $cpuLimit = $effectiveCpu.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    $containerName = if ($ContainerName) { $ContainerName } elseif ($LabName) { Get-LabContainerRuntimeName -LabName $LabName -InstanceId $InstanceId -RunId $RunId } else { "sql-lab-$InstanceId-$($RunId.Substring(0, 8))" }
    $containerHostname = Get-LabContainerRuntimeHostname -RuntimeName $containerName
    $labNetwork = Ensure-LabDockerNetwork -Name $NetworkName

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
            $null = Initialize-DockerSqlNamedVolume -VolumeName $volumeSource -Image $image -RunId $RunId -ScopeId $ScopeId -VersionId $VersionId -InstanceId $InstanceId `
                -ContainerPath ([string]$drive.containerPath) `
                -PersistentStorageId ([string]$drive.persistentStorageId) -Persistence ([string]$drive.persistence) `
                -SyncImageContent:($ExternalRuntimeLaunchMode -in @('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1') -and
                    [string]$drive.containerPath -in @('/var/opt/mssql-extensibility/externallanguages','/var/opt/mssql-extensibility/externallibraries'))
        }

        $volumeArguments += '-v'
        $volumeTarget = "${volumeSource}:$($drive.containerPath)"
        if ($drive.hostPath -and $drive.readOnly -eq $true) {
            $volumeTarget = "${volumeTarget}:ro"
        }
        $volumeArguments += $volumeTarget
    }

    $collationArguments = @()
    if ($Collation -ne 'SQL_Latin1_General_CP1_CI_AS') {
        $collationArguments = @('-e', "MSSQL_COLLATION=$Collation")
    }
    $restartArguments = if ($AutoStart -eq 'on') { @('--restart', 'unless-stopped') } else { @() }
    $externalRuntimeArguments = if ($ExternalRuntimeLaunchMode -in @('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1')) {
        @(
            '--user', '0:0',
            '--cap-add', 'CHOWN',
            '--cap-add', 'DAC_OVERRIDE',
            '--cap-add', 'KILL',
            '--cap-add', 'SETGID',
            '--cap-add', 'SETUID',
            '--cap-add', 'SYS_ADMIN',
            '--cap-add', 'MKNOD',
            '--cap-add', 'SETPCAP',
            '--cap-add', 'NET_ADMIN',
            '--cap-add', 'NET_RAW',
            '--cap-add', 'SYS_PTRACE',
            '--security-opt', 'apparmor=unconfined',
            '--security-opt', 'seccomp=unconfined',
            '--volume', '/sys/fs/cgroup:/sys/fs/cgroup:rw'
        )
    }
    else { @() }

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
                    Find-AvailablePort -RangeStart $nextPort -RangeEnd 14399
                }
                else {
                    $Port
                }

                if (-not $automaticPort) {
                    $binding = Test-LabEndpointBinding -Port $selectedPort
                    $ignoredBackup = $EndpointBindingIgnoreContainerName -and
                        ([string]$binding.Owner).StartsWith("docker:$EndpointBindingIgnoreContainerName (", [StringComparison]::Ordinal)
                    if (-not $binding.Available -and -not $ignoredBackup) {
                        throw "LAB_ENDPOINT_BINDING_CONFLICT: Port $selectedPort ist belegt. Besitzer: $($binding.Owner). Grund: $($binding.Reason)"
                    }
                }

                $dockerArguments = @(
                    'run', '-d',
                    '--name', $containerName,
                    '--hostname', $containerHostname,
                    '--network', $labNetwork.Name,
                    '-p', "127.0.0.1:${selectedPort}:1433",
                    '-e', 'ACCEPT_EULA=Y',
                    '-e', "MSSQL_SA_PASSWORD=$saPlain",
                    '-e', 'MSSQL_PID=Developer',
                    '-e', "MSSQL_MEMORY_LIMIT_MB=$sqlMemoryLimitMB",
                    '-e', 'MSSQL_AGENT_ENABLED=true'
                ) + $collationArguments + $restartArguments + $externalRuntimeArguments + @(
                    '--memory', $memoryLimit,
                    '--cpus', $cpuLimit,
                    '--label', "sql-server-lab.run-id=$RunId",
                    '--label', "sql-server-lab.scope-id=$ScopeId",
                    '--label', "sql-server-lab.instance-id=$InstanceId",
                    '--label', "sql-server-lab.version=$VersionId",
                    '--label', 'sql-server-lab.provider=docker',
                    '--label', "sql-server-lab.autostart=$AutoStart",
                    '--label', "sql-server-lab.created-at=$(Get-LabTimestamp)",
                    '--health-cmd', '/opt/mssql-tools*/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b',
                    '--health-interval', '5s',
                    '--health-timeout', '3s',
                    '--health-retries', '30',
                    $volumeArguments,
                    $image
                )

                Write-LabInfo "Container erstellen: $containerName (Port $selectedPort, Image $image) [Docker]"
                $output = & $dockerInvocation @dockerArguments 2>&1
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0) {
                    break
                }

                $outputText = ($output | Out-String).Trim()
                $bindConflict = $outputText -match '(?i)(address already in use|port is already allocated|failed programming external connectivity)'
                if (-not $automaticPort -or -not $bindConflict -or $selectedPort -ge 14399) {
                    throw "Docker-Container konnte nicht erstellt werden: $outputText"
                }

                & $dockerInvocation rm -f $containerName 1>$null 2>$null
                $nextPort = $selectedPort + 1
                Write-LabWarning "Port $selectedPort wurde beim Runtime-Bindungsschritt belegt. Docker versucht Port $nextPort."
            }

            $containerId = $output |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ -match '^[0-9a-f]{12,64}$' } |
                Select-Object -Last 1
            if (-not $containerId) {
                throw "Docker lieferte keine gueltige Container-ID: $(($output | Out-String).Trim())"
            }

            [PSCustomObject]@{
                ContainerId   = $containerId
                ContainerName = $containerName
                Port          = $selectedPort
                InstanceId    = $InstanceId
                VersionId     = $VersionId
                Provider      = 'docker'
                Image         = $image
                AutoStart     = $AutoStart
                ExternalRuntimeLaunchMode = $ExternalRuntimeLaunchMode
                Status        = 'Created'
            }
        }
    }
    finally {
        $saPlain = $null
    }
}

function Get-DockerInstanceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName
    )

    try {
        $dockerInvocation = Get-LabHostToolInvocation -Name docker
        $inspect = & $dockerInvocation inspect $ContainerIdOrName 2>$null | ConvertFrom-Json -Depth 30
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

function Start-DockerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName
    )

    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    & $dockerInvocation start $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker-Container konnte nicht gestartet werden: $ContainerIdOrName"
    }
}

function Stop-DockerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [int]$TimeoutSeconds = 30
    )

    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    & $dockerInvocation stop -t $TimeoutSeconds $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker-Container konnte nicht gestoppt werden: $ContainerIdOrName"
    }
}

function Remove-DockerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $inspect = & $dockerInvocation inspect $ContainerIdOrName 2>$null | ConvertFrom-Json -Depth 30
    if ($LASTEXITCODE -ne 0 -or -not $inspect) {
        Write-LabWarning "Container nicht gefunden: $ContainerIdOrName (bereits entfernt?)"
        return
    }

    $item = @($inspect)[0]
    $scopeId = [string]$item.Config.Labels.'sql-server-lab.scope-id'
    if ($scopeId -ne $ExpectedScopeId) {
        throw "SCOPE_MISMATCH: Container gehoert zu Scope '$scopeId', erwartet '$ExpectedScopeId'. Entfernung verweigert."
    }

    & $dockerInvocation rm -f $ContainerIdOrName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker-Container konnte nicht entfernt werden: $ContainerIdOrName"
    }

    Write-LabSuccess "Container entfernt: $ContainerIdOrName"
    if (Get-Command Remove-LabContainerAutoStartCoordinatorIfUnused -ErrorAction SilentlyContinue) {
        Remove-LabContainerAutoStartCoordinatorIfUnused -Provider docker
    }
}

function Get-DockerLabContainers {
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

    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $containerIds = & $dockerInvocation ps -a -q @filters 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $containerIds) {
        return @()
    }

    $results = @()
    foreach ($containerIdValue in @($containerIds)) {
        $containerId = ([string]$containerIdValue).Trim()
        if (-not $containerId) {
            continue
        }

        $inspect = & $dockerInvocation inspect $containerId 2>$null | ConvertFrom-Json -Depth 30
        if ($LASTEXITCODE -ne 0 -or -not $inspect) {
            continue
        }

        $item = @($inspect)[0]
        $labels = $item.Config.Labels
        $results += [PSCustomObject]@{
            Provider    = 'docker'
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
