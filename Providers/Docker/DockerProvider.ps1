<#
.SYNOPSIS
    Docker-Provider fuer SQL_Server_Lab.
.DESCRIPTION
    Implementiert Verfuegbarkeit, Portsuche, Provisionierung, Status und
    scopegebundenen Lifecycle fuer Docker Engine oder Docker Desktop.
#>

function Test-DockerAvailable {
    [CmdletBinding()]
    param([string]$StateRoot)

    if ($StateRoot -and (((Test-Path (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))) {
        $null=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
        try {
            $probe=Invoke-LabOwnedHostPinnedCommand -StateRoot $StateRoot -Provider docker -Arguments @('info','--format','{{.ServerVersion}}')
            return [pscustomobject]@{Available=($probe.ExitCode -eq 0);Version=$probe.Stdout.Trim();Message=if($probe.ExitCode -eq 0){''}else{'OWNED_HOST_RUNTIME_UNREACHABLE'}}
        } catch {
            return [pscustomobject]@{Available=$false;Version=$null;Message='OWNED_HOST_RUNTIME_PROBE_FAILED'}
        }
    }

    try {
        $dockerInvocation = Get-LabHostToolInvocation -Name docker
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Version   = $null
            Message   = "Docker-CLI konnte nicht aufgeloest werden: $($_.Exception.Message)"
        }
    }

    function Invoke-DockerClientProbe {
        param(
            [Parameter(Mandatory)][string]$Invocation,
            [Parameter(Mandatory)][string[]]$Arguments
        )

        $originalConfig = if (Test-Path Env:DOCKER_CONFIG) { $env:DOCKER_CONFIG } else { $null }
        $fallbackConfig = Join-Path $env:TEMP ("sql-lab-docker-config-{0}" -f [System.Guid]::NewGuid().ToString('N'))
        $fallbackConfigCreated = $false
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
                    $fallbackConfigCreated = $true
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
            if ($fallbackConfigCreated) {
                Remove-Item -LiteralPath $fallbackConfig -Recurse -Force -ErrorAction Stop
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
        [AllowNull()]$RuntimeBinding,
        [ValidatePattern('^$|^(EXTERNAL_LANGUAGES|EXTERNAL_LIBRARIES)$')][string]$PersistentStorageRole,
        [string]$Persistence,
        [ValidateRange(1,8)][int]$SaPasswordMinimumLength = 8,
        [switch]$SyncImageContent
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }

    if ($SaPasswordMinimumLength -lt 8) {
        Assert-LabSaPasswordVolumeSeedScope -VersionId $VersionId -Provider docker -ContainerPath $ContainerPath `
            -Persistence $Persistence -SyncImageContent ([bool]$SyncImageContent) -RuntimeBinding $RuntimeBinding
    }
    if ($ownedHostPolicy) {
        return Initialize-LabOwnedHostSqlVolume -StateRoot $StateRoot -RunId $RunId -ScopeId $ScopeId -Provider docker `
            -VolumeName $VolumeName -Image $Image -InstanceId $InstanceId -VersionId $VersionId -ContainerPath $ContainerPath `
            -PersistentStorageId $PersistentStorageId -PersistentStorageRole $PersistentStorageRole -Persistence $Persistence `
            -SyncImageContent:$SyncImageContent -RuntimeBinding $RuntimeBinding -SaPasswordMinimumLength $SaPasswordMinimumLength
    }


    if ($RuntimeBinding) {
        $observed=Get-LabContainerInstanceStoreRuntimeInspection -Provider docker -VolumeName $VolumeName
        $boundStore=[pscustomobject]@{Provider='docker';PersistentStorageId=$PersistentStorageId;LocationBinding=[pscustomobject]@{ProviderResourceId=$VolumeName};RuntimeBinding=$RuntimeBinding}
        if ($observed.Status -cne 'AVAILABLE' -or @($observed.AttachedContainers).Count -ne 0 -or
            $observed.Labels.'sql-server-lab.persistent-storage-id' -cne $PersistentStorageId -or
            $observed.Labels.'sql-server-lab.sql-major-version' -cne $VersionId.Substring(0,4) -or
            -not (Test-LabContainerInstanceStoreRuntimeBinding -Store $boundStore -RuntimeInspection $observed)) { throw 'RECOVERED_CONTAINER_STORE_INITIALIZATION_BLOCKED' }
        # A bound existing store is never recreated or initialized through this path.
        return $false
    }
    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $inspectionOutput = @($(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('volume', 'inspect', $VolumeName) } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('volume')+@('inspect')+@($VolumeName))  }) 2>$null)
    $volumeExists = $LASTEXITCODE -eq 0
    if ($volumeExists -and $SaPasswordMinimumLength -lt 8) { throw 'SA_PASSWORD_POLICY_EXISTING_VOLUME_FORBIDDEN' }

    if ($volumeExists -and $PersistentStorageId) {
        try { $inspection = @($inspectionOutput | ConvertFrom-Json -Depth 30 -ErrorAction Stop)[0] }
        catch { throw "DOCKER_SQL_VOLUME_INSPECT_INVALID: $VolumeName" }
        if ([string]$inspection.Labels.'sql-server-lab.persistent-storage-id' -ne $PersistentStorageId -or
            [string]$inspection.Labels.'sql-server-lab.sql-major-version' -ne $VersionId.Substring(0,4)) {
            throw "DOCKER_SQL_VOLUME_STABLE_ID_MISMATCH: $VolumeName"
        }
        if ($PersistentStorageRole -and
            [string]$inspection.Labels.'sql-server-lab.storage-role' -ne $PersistentStorageRole) {
            throw "DOCKER_SQL_VOLUME_STORAGE_ROLE_MISMATCH: $VolumeName"
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
        if ($PersistentStorageRole) { $labelArguments += @('--label', "sql-server-lab.storage-role=$PersistentStorageRole") }
        $volumeCreate = Invoke-LabProviderOperation -Provider docker -Phase 'volume-create' -RunId $RunId -NativeResult `
            -Command "docker volume create $(@($labelArguments) -join ' ') $VolumeName" `
            -Action { $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('volume', 'create', $labelArguments, $VolumeName) -NativeResult -TimeoutSeconds 60 } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('volume')+@('create')+@($labelArguments)+@($VolumeName)) -NativeResult -TimeoutSeconds 60  }) 2>&1 }
        if (-not $volumeCreate.Succeeded) {
            throw "DOCKER_SQL_VOLUME_CREATE_FAILED: $VolumeName - $(@($volumeCreate.Output) -join ' ')"
        }
    }
    if ($volumeExists -and -not $SyncImageContent) { return $false }

    $initializationCommand = if ($SyncImageContent) {
        "if [ ! -d '$ContainerPath' ]; then exit 1; fi; cp -a '$ContainerPath'/. /sql-lab-volume-init/; chown --reference='$ContainerPath' /sql-lab-volume-init && chmod --reference='$ContainerPath' /sql-lab-volume-init"
    }
    else {
        'chown -R 10001:0 /sql-lab-volume-init && chmod 0770 /sql-lab-volume-init'
    }
    if ($SaPasswordMinimumLength -lt 8) {
        $initializationCommand += ' && ' + (Get-LabSaPasswordConfigSeedCommand -MinimumLength $SaPasswordMinimumLength)
    }
    $volumeInitialize = Invoke-LabProviderOperation -Provider docker -Phase 'volume-initialize' -RunId $RunId -NativeResult `
        -Command "docker run --rm --user 0:0 --entrypoint /bin/sh -v ${VolumeName}:/sql-lab-volume-init $Image -c <volume-initialization>" `
        -Action { $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('run', '--rm', '--user', '0:0', '--entrypoint', '/bin/sh', '-v', "${VolumeName}:/sql-lab-volume-init", $Image, '-c', $initializationCommand) -NativeResult -TimeoutSeconds 600 } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('run')+@('--rm')+@('--user')+@('0:0')+@('--entrypoint')+@('/bin/sh')+@('-v')+@("${VolumeName}:/sql-lab-volume-init")+@($Image)+@('-c')+@($initializationCommand)) -NativeResult -TimeoutSeconds 600  }) 2>&1 }
    if (-not $volumeInitialize.Succeeded) {
        if ($SaPasswordMinimumLength -lt 8) { throw 'SA_PASSWORD_POLICY_CONFIG_SEED_FAILED' }
        throw "DOCKER_SQL_VOLUME_INITIALIZATION_FAILED: $VolumeName - $(@($volumeInitialize.Output) -join ' ')"
    }
    return (-not $volumeExists)
}

function Wait-DockerSqlPortBinding {
    <#
    .SYNOPSIS
        Wartet begrenzt auf die nach einem erfolgreichen Docker-Start sichtbare SQL-Portbindung.
    .DESCRIPTION
        Docker Desktop kann die Container-ID bereits zurückgeben, bevor der
        Inspect-Endpoint die NAT-Bindung enthält. Der Container bleibt während
        dieser kurzen Abfrage bestehen: ein sofortiges Entfernen würde bei
        gemountetem SQL-Datenvolume eine unvollständige Systemdatenbank
        hinterlassen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DockerInvocation,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{12,64}$')][string]$ContainerId,
        [Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,
        [ValidateRange(1,15)][int]$TimeoutSeconds = 5
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }


    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $inspect = $null
        try {
            $raw = @($(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $DockerInvocation -ArgumentList @('inspect', $ContainerId) } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $DockerInvocation -ArgumentList (@('inspect')+@($ContainerId))  }) 2>$null)
            if ($raw) {
                $inspect = @($raw | ConvertFrom-Json -Depth 30 -ErrorAction Stop)[0]
            }
        }
        catch {
            $inspect = $null
        }

        $publishedBindings = if ($inspect -and $inspect.NetworkSettings -and $inspect.NetworkSettings.Ports) {
            @($inspect.NetworkSettings.Ports.'1433/tcp')
        }
        else { @() }
        $expectedBinding = @($publishedBindings | Where-Object {
            [string]$_.HostPort -eq [string]$Port -and [string]$_.HostIp -eq '127.0.0.1'
        })
        if ($publishedBindings.Count -eq 1 -and $expectedBinding.Count -eq 1) {
            return $true
        }
        if ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 200
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    return $false
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
        [ValidateRange(1,8)][int]$SaPasswordMinimumLength = 8,
        [ValidateSet('compact', 'standard', 'performance')]
        [string]$Profile = 'standard',
        [array]$Drives = @(),
        [string]$NetworkName,
        [ValidateRange(0,64)][decimal]$Cpu = 0,
        [ValidateRange(0,1048576)][int]$MemoryMB = 0,
        [ValidateSet('on', 'off')][string]$AutoStart = 'off',
        [ValidatePattern('^[A-Za-z0-9_]{1,128}$')][string]$Collation = 'SQL_Latin1_General_CP1_CI_AS',
        [string]$ResolvedImage,
        [ValidateSet('none', 'sql2019-namespace-v1', 'sql2022-namespace-v1', 'sql2025-namespace-v1','sql2025-shared-user-v2')][string]$ExternalRuntimeLaunchMode = 'none',
        [switch]$AllowStandardLaunchResolvedImage
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }


    if ($SaPasswordMinimumLength -lt 8) {
        Assert-LabSaPasswordContainerSeedScope -VersionId $VersionId -Provider docker -Drives $Drives `
            -ResolvedImage $ResolvedImage -LaunchMode $ExternalRuntimeLaunchMode
    }
    if ($ResolvedImage -and $ResolvedImage -notmatch '^[a-z0-9][a-z0-9./_-]+:[a-z0-9][a-z0-9._-]+$') {
        throw 'DOCKER_RESOLVED_IMAGE_INVALID'
    }
    if ($ExternalRuntimeLaunchMode -ne 'none' -and -not $ResolvedImage) {
        throw 'DOCKER_EXTERNAL_RUNTIME_IMAGE_REQUIRED'
    }
    if ($ResolvedImage -and $ExternalRuntimeLaunchMode -eq 'none' -and -not $AllowStandardLaunchResolvedImage) {
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
    if ($ownedHostPolicy) {
        $imageObservation=Get-LabOwnedHostImageObservation -StateRoot $StateRoot -Provider docker -Image $image
        if (-not $imageObservation) {throw 'OWNED_HOST_RUN_IMAGE_PREREQUISITE_REQUIRED'}
        $image=[string]$imageObservation.Id
    }
    $labNetwork = Ensure-LabDockerNetwork -Name $NetworkName -StateRoot $StateRoot

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
                -ContainerPath ([string]$drive.containerPath) -StateRoot $StateRoot `
                -PersistentStorageId ([string]$drive.persistentStorageId) -RuntimeBinding $drive.runtimeBinding -Persistence ([string]$drive.persistence) `
                -PersistentStorageRole ([string]$drive.persistentStorageRole) `
                -SaPasswordMinimumLength $(if ([string]$drive.containerPath -ceq '/var/opt/mssql') { $SaPasswordMinimumLength } else { 8 }) `
                -SyncImageContent:($ExternalRuntimeLaunchMode -in @('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1','sql2025-shared-user-v2') -and
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
    $externalRuntimeArguments = if ($ExternalRuntimeLaunchMode -in @('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1','sql2025-shared-user-v2')) {
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
            $(if ($ExternalRuntimeLaunchMode -eq 'sql2025-shared-user-v2') { '--cgroupns=private' } else { '--volume'; '/sys/fs/cgroup:/sys/fs/cgroup:rw' })
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
            $containerId = $null
            $bindingVerificationRetries = 0

            Write-LabInfo 'Docker lädt ein lokal fehlendes Image beim ersten Start; der erste Containerstart kann deshalb mehrere Minuten dauern.'

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

                $lifecycleArguments = @()
                if ($env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE -eq 'test') {
                    $expiresAt = if ($env:SQL_SERVER_LAB_RESOURCE_EXPIRES_AT) { $env:SQL_SERVER_LAB_RESOURCE_EXPIRES_AT } else { (Get-Date).ToUniversalTime().AddHours(24).ToString('o') }
                    $lifecycleArguments = @('--label','sql-server-lab.lifecycle=test','--label',"sql-server-lab.expires-at=$expiresAt")
                    if ($env:SQL_SERVER_LAB_TEST_OPERATION_ID) { $lifecycleArguments += @('--label',"sql-server-lab.test-operation-id=$($env:SQL_SERVER_LAB_TEST_OPERATION_ID)") }
                }
                $ownedContainerIntent = if ($ownedHostPolicy) {
                    New-LabOwnedHostContainerIntent -StateRoot $StateRoot -RunId $RunId -ScopeId $ScopeId -InstanceId $InstanceId -Provider docker -ContainerName $containerName
                } else { $null }
                $ownedContainerLabels = if ($ownedContainerIntent) { @(Get-LabOwnedHostContainerLabels $ownedContainerIntent) } else { @() }
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
                ) + $collationArguments + $restartArguments + $externalRuntimeArguments + $lifecycleArguments + $ownedContainerLabels + @(
                    '--memory', $memoryLimit,
                    '--cpus', $cpuLimit,
                    '--label', "sql-server-lab.run-id=$RunId",
                    '--label', "sql-server-lab.scope-id=$ScopeId",
                    '--label', "sql-server-lab.instance-id=$InstanceId",
                    '--label', "sql-server-lab.version=$VersionId",
                    '--label', 'sql-server-lab.provider=docker',
                    '--label', "sql-server-lab.autostart=$AutoStart",
                    '--label', "sql-server-lab.created-at=$(Get-LabTimestamp)",
                    '--health-cmd', '/opt/mssql-tools*/bin/sqlcmd -S localhost -U sa -P"$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b',
                    '--health-interval', '5s',
                    '--health-timeout', '3s',
                    '--health-retries', '30'
                ) + @($volumeArguments) + @($image)

                Write-LabInfo "Container erstellen: $containerName (Port $selectedPort, Image $image) [Docker]"
                foreach ($boundDrive in @($Drives | Where-Object { $_.runtimeBinding })) { Assert-LabContainerStoreRuntimeScope -Provider docker -RuntimeBinding $boundDrive.runtimeBinding -StateRoot $StateRoot }
                $providerOperation = Invoke-LabProviderOperation -Provider docker -Phase 'container-create' -RunId $RunId -NativeResult `
                    -Command "docker $(@($dockerArguments | ForEach-Object { $_ }) -join ' ')" `
                    -Action { $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @($dockerArguments) -NativeResult -TimeoutSeconds 600 } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@($dockerArguments)) -NativeResult -TimeoutSeconds 600  }) 2>&1 }
                $output = @($providerOperation.Output)
                $exitCode = $providerOperation.ExitCode
                $providerLogPath = $providerOperation.LogPath
                if ($exitCode -eq 0) {
                    $containerId = $output |
                        ForEach-Object { ([string]$_).Trim() } |
                        Where-Object { $_ -match '^[0-9a-f]{12,64}$' } |
                        Select-Object -Last 1
                    if (-not $containerId) {
                        if ($ownedHostPolicy) { Remove-LabOwnedHostFailedContainer -StateRoot $StateRoot -Intent $ownedContainerIntent }
                        else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('rm')+@('-f')+@($containerName)) 1>$null 2>$null }
                        $logHint = if ($providerLogPath) { " Diagnoselog: $providerLogPath" } else { '' }
                        throw "Docker lieferte keine gueltige Container-ID: $(($output | Out-String).Trim())$logHint"
                    }

                    if ($ownedHostPolicy) {
                        $createdReceipt = Register-LabOwnedHostContainer -StateRoot $StateRoot -Intent $ownedContainerIntent -ContainerIdOrName $containerId
                        $containerId = $createdReceipt.ContainerId
                    }
                    if (Wait-DockerSqlPortBinding -DockerInvocation $dockerInvocation -ContainerId $containerId -Port $selectedPort -StateRoot $StateRoot) {
                        break
                    }

                    if ($ownedHostPolicy) { Remove-LabOwnedHostFailedContainer -StateRoot $StateRoot -Intent $ownedContainerIntent }
                    else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('rm')+@('-f')+@($containerName)) 1>$null 2>$null }
                    $bindingVerificationRetries++
                    if ($bindingVerificationRetries -gt 1) {
                        throw "DOCKER_PORT_BINDING_NOT_PUBLISHED: Docker hat 1433/tcp nicht auf 127.0.0.1:$selectedPort veröffentlicht. Docker Desktop bzw. die Container-Runtime prüfen und den Start erneut ausführen."
                    }
                    if ($automaticPort) { $nextPort = $selectedPort + 1 }
                    Write-LabWarning "Docker meldete den Containerstart erfolgreich, veröffentlichte Port $selectedPort aber nicht. Der Start wird einmal kontrolliert wiederholt."
                    continue
                }

                $outputText = ($output | Out-String).Trim()
                if ($ownedHostPolicy) { Remove-LabOwnedHostFailedContainer -StateRoot $StateRoot -Intent $ownedContainerIntent }
                $bindConflict = $outputText -match '(?i)(address already in use|port is already allocated|failed programming external connectivity)'
                if (-not $automaticPort -or -not $bindConflict -or $selectedPort -ge 14399) {
                    throw "Docker-Container konnte nicht erstellt werden: $outputText"
                }

                if (-not $ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('rm')+@('-f')+@($containerName)) 1>$null 2>$null }
                $nextPort = $selectedPort + 1
                Write-LabWarning "Port $selectedPort wurde beim Runtime-Bindungsschritt belegt. Docker versucht Port $nextPort."
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
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }


    try {
        $dockerInvocation = Get-LabHostToolInvocation -Name docker
        $inspect = $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('inspect', $ContainerIdOrName) } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('inspect')+@($ContainerIdOrName))  }) 2>$null | ConvertFrom-Json -Depth 30
        if ($LASTEXITCODE -ne 0 -or -not $inspect) {
            $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('info') } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('info'))  }) 1>$null 2>$null
            $runtimeAvailable = $LASTEXITCODE -eq 0
            return [PSCustomObject]@{
                Available = $runtimeAvailable
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
            Available = $true
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
            Available = $false
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
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [string]$RunId
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }


    if ($ownedHostPolicy) {
        $ContainerIdOrName = Resolve-LabOwnedHostContainerEffect -StateRoot $StateRoot -Provider docker -ContainerIdOrName $ContainerIdOrName -RunId $RunId
    }
    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $operation = Invoke-LabProviderOperation -Provider docker -Phase 'container-start' -RunId $RunId -NativeResult `
        -Command "docker start $ContainerIdOrName" -Action { $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('start', $ContainerIdOrName) -NativeResult -TimeoutSeconds 600 } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('start')+@($ContainerIdOrName)) -NativeResult -TimeoutSeconds 600  }) 2>&1 }
    if (-not $operation.Succeeded) {
        throw "Docker-Container konnte nicht gestartet werden: $ContainerIdOrName"
    }
}

function Stop-DockerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [int]$TimeoutSeconds = 30,
        [string]$RunId
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }


    if ($ownedHostPolicy) {
        $ContainerIdOrName = Resolve-LabOwnedHostContainerEffect -StateRoot $StateRoot -Provider docker -ContainerIdOrName $ContainerIdOrName -RunId $RunId
    }
    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $operation = Invoke-LabProviderOperation -Provider docker -Phase 'container-stop' -RunId $RunId -NativeResult `
        -Command "docker stop -t $TimeoutSeconds $ContainerIdOrName" `
        -Action { $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('stop', '-t', $TimeoutSeconds, $ContainerIdOrName) -NativeResult -TimeoutSeconds ($TimeoutSeconds+30) } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('stop')+@('-t')+@($TimeoutSeconds)+@($ContainerIdOrName)) -NativeResult -TimeoutSeconds ($TimeoutSeconds+30)  }) 2>&1 }
    if (-not $operation.Succeeded) {
        throw "Docker-Container konnte nicht gestoppt werden: $ContainerIdOrName"
    }
}

function Remove-DockerInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }


    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $inspect = $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('inspect', $ContainerIdOrName) } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('inspect')+@($ContainerIdOrName))  }) 2>$null | ConvertFrom-Json -Depth 30
    if ($LASTEXITCODE -ne 0 -or -not $inspect) {
        Write-LabWarning "Container nicht gefunden: $ContainerIdOrName (bereits entfernt?)"
        return
    }

    $item = @($inspect)[0]
    $scopeId = [string]$item.Config.Labels.'sql-server-lab.scope-id'
    if ($scopeId -ne $ExpectedScopeId) {
        throw "SCOPE_MISMATCH: Container gehoert zu Scope '$scopeId', erwartet '$ExpectedScopeId'. Entfernung verweigert."
    }

    $runId = [string]$item.Config.Labels.'sql-server-lab.run-id'
    if ($item.Config.Labels.'sql-server-lab.owned-host-policy-id' -and -not $ownedHostPolicy) {
        throw 'OWNED_HOST_CONTEXT_REQUIRED'
    }
    if ($ownedHostPolicy) {
        Assert-LabOwnedHostContainerEffect -StateRoot $StateRoot -RunId $runId -Provider docker -ContainerId ([string]$item.Id)
        $ContainerIdOrName = [string]$item.Id
    }
    $operation = Invoke-LabProviderOperation -Provider docker -Phase 'container-remove' -RunId $runId -NativeResult `
        -Command "docker rm -f $ContainerIdOrName" -Action { $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('rm', '-f', $ContainerIdOrName) -NativeResult -TimeoutSeconds 60 } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('rm')+@('-f')+@($ContainerIdOrName)) -NativeResult -TimeoutSeconds 60  }) 2>&1 }
    if (-not $operation.Succeeded) {
        throw "Docker-Container konnte nicht entfernt werden: $ContainerIdOrName"
    }

    Write-LabSuccess "Container entfernt: $ContainerIdOrName"
    if ($ownedHostPolicy) { Remove-LabOwnedHostAutoStartIfUnused -StateRoot $StateRoot -RunId $runId -Provider docker }
    if (-not $ownedHostPolicy -and (Get-Command Remove-LabContainerAutoStartCoordinatorIfUnused -ErrorAction SilentlyContinue)) {
        Remove-LabContainerAutoStartCoordinatorIfUnused -Provider docker
    }
}

function Get-DockerLabContainers {
    [CmdletBinding()]
    param(
        [string]$RunId,
        [string]$ScopeId
    , [string]$StateRoot)
    $ownedHostPolicy = if ($StateRoot -and (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json')) -or (((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))))) { Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required } else { $null }


    $filters = @('--filter', 'label=sql-server-lab.run-id')
    if ($RunId) {
        $filters = @('--filter', "label=sql-server-lab.run-id=$RunId")
    }
    elseif ($ScopeId) {
        $filters = @('--filter', "label=sql-server-lab.scope-id=$ScopeId")
    }

    $dockerInvocation = Get-LabHostToolInvocation -Name docker
    $containerIds = $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('ps', '-a', '--no-trunc', '-q') + $filters) } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('ps')+@('-a')+@('-q')+@($filters))  }) 2>$null
    if ($ownedHostPolicy -and $LASTEXITCODE -ne 0) { throw 'OWNED_HOST_CONTAINER_INVENTORY_FAILED' }
    if ($LASTEXITCODE -ne 0 -or -not $containerIds) {
        return @()
    }

    $results = @()
    foreach ($containerIdValue in @($containerIds)) {
        $containerId = ([string]$containerIdValue).Trim()
        if (-not $containerId) {
            continue
        }

        if ($ownedHostPolicy -and $containerId -cnotmatch '^[a-f0-9]{64}$') { throw 'OWNED_HOST_CONTAINER_INVENTORY_ID_INVALID' }
        $inspect = $(if ($ownedHostPolicy) { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList @('inspect', $containerId) } else { Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $StateRoot -Invocation $dockerInvocation -ArgumentList (@('inspect')+@($containerId))  }) 2>$null | ConvertFrom-Json -Depth 30
        if ($ownedHostPolicy -and ($LASTEXITCODE -ne 0 -or -not $inspect)) { throw 'OWNED_HOST_CONTAINER_INVENTORY_INSPECT_FAILED' }
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
