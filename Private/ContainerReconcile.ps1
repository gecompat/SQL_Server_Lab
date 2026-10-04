<#
.SYNOPSIS
    Plant und journalisiert kontrollierte Docker-/Podman-Ressourcenaenderungen.
.DESCRIPTION
    Der read-only Plan trennt No-op, Live-Update und Recreate. Das lokale
    Operationsjournal bindet die Mutation an Run, Scope und echte Runtime-IDs
    und liefert einen idempotenten Rollback-/Resume-Einstieg.
#>

function Get-LabCanonicalResourceRoot {
    param([Parameter(Mandatory)][string]$StateRoot)
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($StateRoot))
    if ([OperatingSystem]::IsWindows()) { $root = $root.ToLowerInvariant() }
    return $root
}

function Get-LabContainerResourceLockName {
    param([string]$StateRoot, [string]$RunId)
    $key = (Get-LabCanonicalResourceRoot -StateRoot $StateRoot) + '|' + $RunId.ToLowerInvariant()
    return 'SQL_Server_Lab_Container_Reconcile_' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
}

function Get-LabContainerMeasuredCpu {
    <# Returns only a measured CPU limit; absent, unlimited or contradictory evidence remains unknown. #>
    param([Parameter(Mandatory)]$Inspect)
    $values = @{}
    foreach ($name in @('NanoCpus','CpuQuota','CpuPeriod')) {
        $value = [decimal]0
        $property = $Inspect.HostConfig.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and
            -not [decimal]::TryParse([string]$property.Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
        $values[$name] = $value
    }
    $nanoCpu = if ($values.NanoCpus -gt 0) { $values.NanoCpus / [decimal]1000000000 } else { $null }
    $quotaCpu = if ($values.CpuQuota -gt 0 -and $values.CpuPeriod -gt 0) { $values.CpuQuota / $values.CpuPeriod } else { $null }
    if ($values.NanoCpus -lt 0 -or $values.CpuPeriod -lt 0 -or ($values.CpuQuota -gt 0 -and $values.CpuPeriod -le 0)) { return $null }
    if ($null -ne $nanoCpu -and $null -ne $quotaCpu -and $nanoCpu -ne $quotaCpu) { return $null }
    if ($null -ne $nanoCpu) { return [decimal]$nanoCpu }
    return $quotaCpu
}

function Get-LabContainerReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    return (Join-Path $RunDirectory 'container-reconcile-journal.json')
}

function Assert-LabContainerReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'container-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 50) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'CONTAINER_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabContainerReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabContainerReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabContainerReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet(
            'PREPARED','LIVE_MUTATED','ORIGINAL_RENAMED','REPLACEMENT_CREATED',
            'VERIFIED','STATE_COMMITTED','COMPLETED','ROLLED_BACK','RECOVERY_REQUIRED'
        )][string]$Status,
        [string]$ErrorCode
    )
    $Journal.Status = $Status
    if ($ErrorCode) { $Journal.Recovery.ErrorCode = $ErrorCode }
    if ($Status -in @('COMPLETED','ROLLED_BACK')) { $Journal.Recovery.Status = 'NOT_REQUIRED' }
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_CONTAINER_RECONCILE' }
    return Write-LabContainerReconcileJournal -Journal $Journal -Path $Path
}

function Get-LabContainerMountFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Mounts)
    $canonical = @($Mounts | ForEach-Object {
        $sourceIdentity = if ([string]$_.Type -eq 'volume') { [string]$_.Name } else { [string]$_.Source }
        "$([string]$_.Type)|$sourceIdentity|$([string]$_.Destination)|$([bool]$_.RW)"
    } | Sort-Object) -join "`n"
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Get-LabContainerReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$InstanceId,
        [string]$StateRoot
    )
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $ownedHostPolicy = if ($run.metadata.ownedHostIntegration -or (((Test-Path (Join-Path $StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))))) {
        Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $StateRoot
    } else { $null }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'CONTAINER_RECONCILE_CONNECTION_INFO_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $instances = @($connection.instances | Where-Object {
        [string]$_.provider -in @('docker','podman') -and (-not $InstanceId -or [string]$_.id -eq $InstanceId)
    })
    if ($instances.Count -ne 1) { throw "CONTAINER_RECONCILE_INSTANCE_NOT_UNIQUE: $($instances.Count)" }
    $instance = $instances[0]
    $runtime = [string]$instance.provider
    try { $runtimeInvocation = Get-LabHostToolInvocation -Name $runtime }
    catch { throw "CONTAINER_RECONCILE_RUNTIME_NOT_AVAILABLE: $runtime" }
    $identity = @(
        [string]$instance.containerId, [string]$instance.runtimeId,
        [string]$instance.containerName, [string]$instance.name, [string]$instance.id
    ) | Where-Object { $_ } | Select-Object -First 1
    if (-not $identity) { throw 'CONTAINER_RECONCILE_IDENTITY_MISSING' }
    if ($ownedHostPolicy) {
        $identity=Resolve-LabOwnedHostContainerEffect -StateRoot $StateRoot -RunId $RunId -Provider $runtime -ContainerIdOrName $identity
        $inspect=@(Invoke-LabContainerRuntimeCommand -Provider $runtime -StateRoot $StateRoot -RunId $RunId -Invocation $runtimeInvocation -ArgumentList @('inspect',$identity) | ConvertFrom-Json -Depth 50)[0]
    } else {
        $inspect = @(& $runtimeInvocation inspect $identity 2>$null | ConvertFrom-Json -Depth 50)[0]
    }
    if (-not $inspect) { throw "CONTAINER_RECONCILE_CONTAINER_NOT_FOUND: $identity" }
    if ([string]$inspect.Config.Labels.'sql-server-lab.run-id' -ne $RunId -or
        [string]$inspect.Config.Labels.'sql-server-lab.scope-id' -ne [string]$run.scopeId -or
        ([string]$inspect.Config.Labels.'sql-server-lab.instance-id' -and
         [string]$inspect.Config.Labels.'sql-server-lab.instance-id' -ne [string]$instance.id)) {
        throw 'CONTAINER_RECONCILE_SCOPE_MISMATCH'
    }
    $portBinding = @($inspect.NetworkSettings.Ports.'1433/tcp' | Select-Object -First 1)
    if ($portBinding.Count -ne 1 -or -not $portBinding[0].HostPort) { throw 'CONTAINER_RECONCILE_SQL_PORT_BINDING_REQUIRED' }
    $currentPort = [int]$portBinding[0].HostPort
    $currentMemoryMB = if ([long]$inspect.HostConfig.Memory -gt 0) { [int]([long]$inspect.HostConfig.Memory / 1MB) } else { 2048 }
    $measuredCpu = Get-LabContainerMeasuredCpu -Inspect $inspect
    $currentCpu = if ($null -ne $measuredCpu) { $measuredCpu } else { 2 }
    $configuredSqlMemory = @($inspect.Config.Env | Where-Object { [string]$_ -match '^MSSQL_MEMORY_LIMIT_MB=' } | Select-Object -First 1)
    $healthCommand = [string](@($inspect.Config.Healthcheck.Test) -join ' ')
    $restartPolicy = [string]$inspect.HostConfig.RestartPolicy.Name
    $autoStartLabel = [string]$inspect.Config.Labels.'sql-server-lab.autostart'
    $currentAutoStart = if ($restartPolicy -in @('always','unless-stopped') -and $autoStartLabel -eq 'on') {
        'on'
    }
    elseif (($restartPolicy -in @('','no')) -and $autoStartLabel -in @('','off')) {
        'off'
    }
    else { 'DRIFTED' }
    return [PSCustomObject]@{
        Run=$run; RunId=$RunId; RunDirectory=$runDirectory; StateRoot=$StateRoot
        Connection=$connection; ConnectionPath=$connectionPath; Instance=$instance
        InstanceId=[string]$instance.id; Provider=$runtime; Inspect=$inspect
        ContainerName=([string]$inspect.Name).TrimStart('/'); ContainerId=[string]$inspect.Id
        WasRunning=[bool]$inspect.State.Running; CurrentPort=$currentPort
        CurrentMemoryMB=$currentMemoryMB; CurrentCpu=$currentCpu
        ConfiguredSqlMemory=$configuredSqlMemory; HealthCommand=$healthCommand
        CurrentRestartPolicy=$restartPolicy; CurrentAutoStartLabel=$autoStartLabel
        CurrentAutoStart=$currentAutoStart
        MountFingerprint=Get-LabContainerMountFingerprint -Mounts @($inspect.Mounts)
    }
}

function New-LabContainerPortPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateRange(1024,65535)][int]$Port,
        [string]$StateRoot
    )
    # This DTO deliberately projects categories instead of local host ports.
    # Its content hash is observation evidence, never an executable plan key.
    $result = [pscustomobject]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.ContainerPortPreview';Version='1.0'}
        Mode='CONTAINER_PORT_PREVIEW_PLAN_ONLY'; Status='BLOCKED'; Reason='PORT_PREVIEW_BINDING_UNAVAILABLE'
        Provider=$null; CanApply=$false; MutationAllowed=$false; Actions=@(); ObservationKey=$null
        Actual=[pscustomobject]@{Evidence='UNKNOWN';SqlBinding='UNKNOWN';Lifecycle='UNKNOWN'}
        Desired=[pscustomobject]@{PortChange='UNKNOWN'}; NoChange=$null; ChangeClass='unsupported'
        Preview=[pscustomobject]@{Downtime='UNKNOWN';Endpoint='NOT_CHECKED';Sql='NOT_CHECKED';Backup='NOT_CHECKED';Mounts=$null;DataImpact='NOT_VERIFIED'}
    }
    try {
        if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
        $root=Assert-LabDiagnosticPath -Path $StateRoot
        if ([IO.Path]::GetFileName($root) -cne 'State') { return $result }
        $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId $InstanceId -DataRoot ([IO.Path]::GetDirectoryName($root))
        if ($binding.Provider -cnotin @('docker','podman')) {
            $result.Status='UNSUPPORTED'; $result.Reason='PORT_PREVIEW_PROVIDER_UNSUPPORTED'; return $result
        }
        try { Assert-LabResourceChangeAllowed -RunId $RunId -StateRoot $root }
        catch { $result.Reason='PORT_PREVIEW_PROTECTED_TARGET'; return $result }
        $sub=@($binding.Run.providerSubRuns | Where-Object provider -CEQ $binding.Provider)
        if ($binding.Run.state -cne 'RUNNING' -or $sub.Count -ne 1 -or $sub[0].state -cne 'RUNNING') {
            $result.Reason='PORT_PREVIEW_RUNNING_REQUIRED'; return $result
        }
        $connection=Read-LabDiagnosticJson -Path (Join-Path $binding.Directory 'connection-info.json')
        $rows=@($connection.instances | Where-Object { $_.id -ceq $InstanceId -and $_.provider -ceq $binding.Provider })
        if ($connection.instances -isnot [array] -or $rows.Count -ne 1 -or
            $rows[0].containerId -isnot [string] -or $rows[0].containerId -cnotmatch '^[a-f0-9]{64}$') { return $result }
        $journalPath=Get-LabContainerReconcileJournalPath -RunDirectory $binding.Directory
        $journal=Read-LabDiagnosticJson -Path $journalPath -Optional
        $journalDigest='absent'
        if ($journal) {
            $null=Assert-LabContainerReconcileJournal -Journal $journal
            if ($journal.RunId -cne $RunId -or $journal.ScopeId -cne $binding.Run.scopeId -or
                $journal.InstanceId -cne $InstanceId -or $journal.Provider -cne $binding.Provider -or
                $journal.Status -cnotin @('COMPLETED','ROLLED_BACK')) {
                $result.Reason='PORT_PREVIEW_JOURNAL_BLOCKED'; return $result
            }
            $journalDigest=Get-LabWorkflowHash -Text ($journal | ConvertTo-Json -Depth 50 -Compress) -Length 64
        }
        # The existing custody-aware reader performs the sole native inspect.
        # Never use its legacy fallback limits or first-port projection here.
        $context=Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $root
        $inspect=$context.Inspect
        if ($context.Provider -cne $binding.Provider -or $context.ContainerId -cne $rows[0].containerId -or
            $context.Run.scopeId -cne $binding.Run.scopeId -or $context.Run.state -cne 'RUNNING' -or
            $inspect.Id -cne $rows[0].containerId -or $inspect.State.Running -isnot [bool] -or -not $inspect.State.Running -or
            $inspect.Config.Labels.'sql-server-lab.run-id' -cne $RunId -or
            $inspect.Config.Labels.'sql-server-lab.scope-id' -cne $binding.Run.scopeId -or
            $inspect.Config.Labels.'sql-server-lab.instance-id' -cne $InstanceId) { return $result }
        $ports=$inspect.NetworkSettings.Ports
        $configuredPorts=$inspect.HostConfig.PortBindings
        $networks=$inspect.NetworkSettings.Networks
        $sqlPorts=@($ports.'1433/tcp')
        $configuredSql=@($configuredPorts.'1433/tcp')
        if ($ports -isnot [pscustomobject] -or $configuredPorts -isnot [pscustomobject] -or $networks -isnot [pscustomobject] -or
            $ports.'1433/tcp' -isnot [array] -or $configuredPorts.'1433/tcp' -isnot [array] -or
            @($ports.PSObject.Properties).Count -ne 1 -or @($configuredPorts.PSObject.Properties).Count -ne 1 -or
            @($networks.PSObject.Properties).Count -ne 1 -or $sqlPorts.Count -ne 1 -or $configuredSql.Count -ne 1 -or
            $sqlPorts[0].HostIp -cne '127.0.0.1' -or $configuredSql[0].HostIp -cne '127.0.0.1' -or
            $sqlPorts[0].HostPort -isnot [string] -or $sqlPorts[0].HostPort -cnotmatch '^[1-9][0-9]{0,4}$' -or
            $configuredSql[0].HostPort -cne $sqlPorts[0].HostPort -or [int]$sqlPorts[0].HostPort -gt 65535) {
            $result.Status='UNSUPPORTED'; $result.Reason='PORT_PREVIEW_TOPOLOGY_UNSUPPORTED'; return $result
        }
        $network=@($networks.PSObject.Properties)[0].Value
        # Additional aliases, fixed IP requests or host/container networking are
        # not equivalent to the current single-network recreate path.
        if ([string]::IsNullOrWhiteSpace([string]$inspect.HostConfig.NetworkMode) -or
            $inspect.HostConfig.NetworkMode -cin @('host','none') -or
            [string]$inspect.HostConfig.NetworkMode -like 'container:*' -or
            @($inspect.HostConfig.Dns | Where-Object { $_ }).Count -or
            @($inspect.HostConfig.ExtraHosts | Where-Object { $_ }).Count -or
            @($inspect.HostConfig.Links | Where-Object { $_ }).Count -or $inspect.HostConfig.PublishAllPorts -eq $true -or
            @($inspect.Config.ExposedPorts.PSObject.Properties | Where-Object { $_ -and $_.Name -cne '1433/tcp' }).Count -or
            @($network.Aliases | Where-Object { $_ -cnotin @($context.ContainerName,$context.ContainerId,$context.ContainerId.Substring(0,12)) }).Count -or
            ($network.IPAMConfig -and ($network.IPAMConfig | ConvertTo-Json -Compress) -cne '{}')) {
            $result.Status='UNSUPPORTED'; $result.Reason='PORT_PREVIEW_TOPOLOGY_UNSUPPORTED'; return $result
        }
        $cpu=Get-LabContainerMeasuredCpu -Inspect $inspect
        if ($null -eq $cpu -or $cpu -lt 1 -or $cpu -gt 64 -or [long]$inspect.HostConfig.Memory -lt 512MB -or
            [long]$inspect.HostConfig.Memory % 1MB -ne 0 -or [long]$inspect.HostConfig.Memory -gt 1048576MB) {
            $result.Reason='PORT_PREVIEW_LIMITS_UNKNOWN'; return $result
        }
        try { $null=@(Get-LabContainerRecreateMountArguments -Inspect $inspect -Provider $binding.Provider) }
        catch { $result.Status='UNSUPPORTED'; $result.Reason='PORT_PREVIEW_MOUNTS_UNSUPPORTED'; return $result }
        $currentPort=[int]$sqlPorts[0].HostPort
        $same=$Port -eq $currentPort
        $observed=[ordered]@{
            Root=$root; Run=$RunId; Scope=$binding.Run.scopeId; Instance=$InstanceId; Provider=$binding.Provider
            RuntimeId=$context.ContainerId; RunState=$binding.Run.state; ProviderState=$sub[0].state
            Config=$inspect.Config; HostConfig=$inspect.HostConfig; Image=$inspect.Image
            Ports=$ports; Networks=$networks
            Mounts=(Get-LabContainerMountFingerprint -Mounts @($inspect.Mounts)); Journal=$journalDigest; DesiredPort=$Port
        }
        $result.ObservationKey=Get-LabWorkflowHash -Text ($observed | ConvertTo-Json -Depth 50 -Compress) -Length 64
        $result.Provider=$binding.Provider; $result.Status='PLAN_ONLY'; $result.Reason='PORT_PREVIEW_APPLY_NOT_IMPLEMENTED'
        $result.Actual=[pscustomobject]@{Evidence='MEASURED';SqlBinding='SINGLE_LOOPBACK_1433_TCP';Lifecycle='RUNNING'}
        $result.Desired.PortChange=if($same){'SAME_PORT'}else{'DIFFERENT_PORT'}
        $result.NoChange=$same; $result.ChangeClass=if($same){'no-op'}else{'recreate'}
        $result.Preview.Downtime=if($same){'NONE'}else{'REQUIRED'}
        $result.Preview.Mounts=Get-LabContainerMountPreview -Inspect $inspect
        return $result
    }
    catch {
        # Raw diagnostic/runtime exceptions can contain host paths or identities.
        # Return the fixed unavailable DTO rather than forwarding that text.
        return $result
    }
}

function Get-LabContainerSqlMaxMemoryMB {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.WasRunning) { throw 'CONTAINER_RECONCILE_SQL_LIVE_REQUIRES_RUNNING' }
    $password = Get-LabSecret -Path $Context.RunDirectory -Name 'sa-password'
    if (-not $password) { throw 'CONTAINER_RECONCILE_SA_SECRET_MISSING' }
    $plain = ConvertFrom-LabSecureString -SecureString $password
    try {
        $output = @(Invoke-SqlQuery -HostName $(if($Context.Instance.host){[string]$Context.Instance.host}else{'127.0.0.1'}) `
            -Port ([int]$Context.CurrentPort) -SaPlain $plain -Database master -TimeoutSeconds 30 `
            -Query "SET NOCOUNT ON; SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name=N'max server memory (MB)';")
    }
    finally { $plain = $null }
    $value = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    if ($value.Count -ne 1) { throw 'CONTAINER_RECONCILE_SQL_MAX_MEMORY_READ_FAILED' }
    return [int]$value[0]
}

function Set-LabContainerSqlMaxMemoryMB {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][int]$SqlMaxMemoryMB)
    $password = Get-LabSecret -Path $Context.RunDirectory -Name 'sa-password'
    if (-not $password) { throw 'CONTAINER_RECONCILE_SA_SECRET_MISSING' }
    $null = Set-LabServerConfig -Config ([PSCustomObject]@{ memory=[PSCustomObject]@{ minMB=0; maxMB=$SqlMaxMemoryMB } }) `
        -HostName $(if($Context.Instance.host){[string]$Context.Instance.host}else{'127.0.0.1'}) `
        -Port ([int]$Context.CurrentPort) -SaPassword $password -ContainerName ([string]$Context.ContainerName) -Provider ([string]$Context.Provider)
    $actual = Get-LabContainerSqlMaxMemoryMB -Context $Context
    if ($actual -ne $SqlMaxMemoryMB) { throw 'CONTAINER_RECONCILE_SQL_MAX_MEMORY_POSTCONDITION_FAILED' }
    return $actual
}

function Get-LabContainerMountPreview {
    [CmdletBinding()]
    param([AllowNull()]$Inspect)

    # Inspect is private. Project only counts; names, source/destination paths
    # and native identities never become part of the public preview.
    $preview = [pscustomobject]@{
        Status='UNKNOWN'; TotalMountCount=$null; VolumeMountCount=$null
        HostBindCount=$null; WritableHostBindCount=$null; OtherMountCount=$null
        VolumeOwnership='NOT_CHECKED'
    }
    if ($null -eq $Inspect -or $null -eq $Inspect.PSObject.Properties['Mounts'] -or
        $Inspect.Mounts -isnot [array] -or $Inspect.Mounts.Count -gt 1024) { return $preview }
    $volumes=0; $binds=0; $writable=0; $other=0
    foreach ($mount in $Inspect.Mounts) {
        if ($null -eq $mount -or $mount.Type -isnot [string] -or
            [string]::IsNullOrWhiteSpace($mount.Type) -or $mount.RW -isnot [bool]) { return $preview }
        switch -CaseSensitive ($mount.Type) {
            'volume' { $volumes++ }
            'bind' { $binds++; if ($mount.RW) { $writable++ } }
            default { $other++ }
        }
    }
    $preview.Status='MEASURED'
    $preview.TotalMountCount=$Inspect.Mounts.Count
    $preview.VolumeMountCount=$volumes; $preview.HostBindCount=$binds
    $preview.WritableHostBindCount=$writable; $preview.OtherMountCount=$other
    return $preview
}

function Get-LabContainerRecreateMountArguments {
    [CmdletBinding()]
    param([AllowNull()]$Inspect, [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

    if ((Get-LabContainerMountPreview -Inspect $Inspect).Status -ne 'MEASURED') {
        throw 'CONTAINER_RECONCILE_MOUNT_EVIDENCE_INVALID: Recreate benötigt eine vollständige Mountliste mit typisierten Schreibrechten.'
    }
    $arguments = @()
    foreach ($mount in $Inspect.Mounts) {
        if ($mount.Type -cnotin @('bind','volume')) {
            throw 'CONTAINER_RECONCILE_MOUNT_TYPE_UNSUPPORTED: Recreate unterstützt nur Bind-Mounts und benannte Volumes; vorhandenen Container beibehalten.'
        }
        if ($mount.Destination -isnot [string] -or [string]::IsNullOrWhiteSpace($mount.Destination) -or
            -not $mount.Destination.StartsWith('/') -or $mount.Destination -match '[:\x00\r\n]') {
            throw 'CONTAINER_RECONCILE_MOUNT_EVIDENCE_INVALID: Recreate benötigt einen eindeutigen absoluten Container-Zielpfad.'
        }
        if ($mount.Type -ceq 'bind') {
            if ($mount.Source -isnot [string] -or [string]::IsNullOrWhiteSpace($mount.Source) -or $mount.Source -match '[\x00\r\n]') {
                throw 'CONTAINER_RECONCILE_MOUNT_EVIDENCE_INVALID: Recreate benötigt die vollständige Bind-Mount-Quelle.'
            }
            $windowsDrivePath = $mount.Source -match '^[A-Za-z]:[\\/][^:]*$'
            $absolutePath = $mount.Source.StartsWith('/') -or $mount.Source.StartsWith('\\') -or $windowsDrivePath
            if (-not $absolutePath -or ($mount.Source.Contains(':') -and -not $windowsDrivePath)) {
                throw 'CONTAINER_RECONCILE_MOUNT_EVIDENCE_INVALID: Recreate benötigt einen eindeutigen absoluten Bind-Mount-Quellpfad.'
            }
            $suffix = if (-not $mount.RW) { ':ro' } else { '' }
            $arguments += @('-v',"$($mount.Source):$($mount.Destination)$suffix")
        }
        else {
            if ($mount.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($mount.Name) -or $mount.Name -match '[:/\\\x00\r\n]') {
                throw 'CONTAINER_RECONCILE_MOUNT_EVIDENCE_INVALID: Recreate benötigt den eindeutigen Namen des vorhandenen Volumes.'
            }
            $options = @()
            if ($Provider -eq 'podman') { $options += 'U' }
            if (-not $mount.RW) { $options += 'ro' }
            $suffix = if ($options.Count -gt 0) { ":$($options -join ',')" } else { '' }
            $arguments += @('-v',"$($mount.Name):$($mount.Destination)$suffix")
        }
    }
    return $arguments
}

function New-LabContainerReconcilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$InstanceId,
        [Nullable[decimal]]$Cpu,
        [Nullable[int]]$MemoryMB,
        [Nullable[int]]$Port,
        [Nullable[int]]$SqlMaxMemoryMB,
        [ValidateSet('on','off')][string]$AutoStart,
        [switch]$RepairSqlRuntimeContract,
        [string]$StateRoot
    )
    $context = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $mountPreview = Get-LabContainerMountPreview -Inspect $context.Inspect
    $targetCpu = if ($null -ne $Cpu) { [decimal]$Cpu } else { [decimal]$context.CurrentCpu }
    $targetMemory = if ($null -ne $MemoryMB) { [int]$MemoryMB } else { [int]$context.CurrentMemoryMB }
    $targetPort = if ($null -ne $Port) { [int]$Port } else { [int]$context.CurrentPort }
    $targetAutoStart = if ($PSBoundParameters.ContainsKey('AutoStart')) {
        $AutoStart
    }
    elseif ([string]$context.CurrentAutoStart -eq 'on' -or
        [string]$context.CurrentRestartPolicy -in @('always','unless-stopped') -or
        [string]$context.CurrentAutoStartLabel -eq 'on') {
        'on'
    }
    else { 'off' }
    if ($targetCpu -lt 1 -or $targetCpu -gt 64) { throw 'CONTAINER_RECONCILE_CPU_OUT_OF_RANGE' }
    if ($targetMemory -lt 512 -or $targetMemory -gt 1048576) { throw 'CONTAINER_RECONCILE_MEMORY_OUT_OF_RANGE' }
    if ($targetPort -lt 1024 -or $targetPort -gt 65535) { throw 'CONTAINER_RECONCILE_PORT_OUT_OF_RANGE' }
    if ($null -ne $SqlMaxMemoryMB -and ($SqlMaxMemoryMB -lt 128 -or $SqlMaxMemoryMB -gt 2147483647)) { throw 'CONTAINER_RECONCILE_SQL_MAX_MEMORY_OUT_OF_RANGE' }
    $currentSqlMaxMemory = if ($null -ne $SqlMaxMemoryMB) { Get-LabContainerSqlMaxMemoryMB -Context $context } else { $null }
    $targetSqlMaxMemory = if ($null -ne $SqlMaxMemoryMB) { [int]$SqlMaxMemoryMB } else { $null }
    $sqlMemoryLimit = [int][math]::Max(1024, [math]::Floor($targetMemory * 0.8))
    $runtimeContractCurrent = $context.ConfiguredSqlMemory -eq "MSSQL_MEMORY_LIMIT_MB=$sqlMemoryLimit" -and
        $context.HealthCommand -match '(?:^|\s)-C(?:\s|$)'
    $cpuChanged = $targetCpu -ne [decimal]$context.CurrentCpu
    $memoryChanged = $targetMemory -ne [int]$context.CurrentMemoryMB
    $portChanged = $targetPort -ne [int]$context.CurrentPort
    $contractRepair = $RepairSqlRuntimeContract -and -not $runtimeContractCurrent
    $autoStartChanged = ($PSBoundParameters.ContainsKey('AutoStart') -and [string]$context.CurrentAutoStart -ne $targetAutoStart) -or
        ($RepairSqlRuntimeContract -and [string]$context.CurrentAutoStart -eq 'DRIFTED')
    $sqlMemoryChanged = $null -ne $targetSqlMaxMemory -and $targetSqlMaxMemory -ne $currentSqlMaxMemory
    $changeClass = if ($portChanged -or $contractRepair -or $autoStartChanged) { 'recreate' } elseif ($cpuChanged -or $memoryChanged -or $sqlMemoryChanged) { 'live' } else { 'no-op' }
    $diff = @(
        [PSCustomObject]@{ Field='Cpu'; Current=[decimal]$context.CurrentCpu; Desired=$targetCpu; Changed=$cpuChanged; ChangeClass=if($cpuChanged){'live'}else{'no-op'} },
        [PSCustomObject]@{ Field='MemoryMB'; Current=[int]$context.CurrentMemoryMB; Desired=$targetMemory; Changed=$memoryChanged; ChangeClass=if($memoryChanged){'live'}else{'no-op'} },
        [PSCustomObject]@{ Field='Port'; Current=[int]$context.CurrentPort; Desired=$targetPort; Changed=$portChanged; ChangeClass=if($portChanged){'recreate'}else{'no-op'} },
        [PSCustomObject]@{ Field='SqlRuntimeContract'; Current=if($runtimeContractCurrent){'CURRENT'}else{'DRIFTED'}; Desired=if($RepairSqlRuntimeContract){'CURRENT'}else{'UNCHANGED'}; Changed=$contractRepair; ChangeClass=if($contractRepair){'recreate'}else{'no-op'} },
        [PSCustomObject]@{ Field='AutoStart'; Current=[string]$context.CurrentAutoStart; Desired=$targetAutoStart; Changed=$autoStartChanged; ChangeClass=if($autoStartChanged){'recreate'}else{'no-op'} },
        [PSCustomObject]@{ Field='SqlMaxMemoryMB'; Current=$currentSqlMaxMemory; Desired=$targetSqlMaxMemory; Changed=$sqlMemoryChanged; ChangeClass=if($sqlMemoryChanged){'live'}else{'no-op'} }
    )
    $actions = if ($changeClass -eq 'no-op') { @() } else { @([PSCustomObject]@{
        Operation=if($changeClass -eq 'live'){'UpdateContainerResources'}else{'RecreateContainer'}
        Provider=[string]$context.Provider; InstanceId=[string]$context.InstanceId; ChangeClass=$changeClass
    }) }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{ Name='SqlServerLab.ContainerReconcilePlan'; Version='1.0' }
        RunId=$RunId; InstanceId=[string]$context.InstanceId; Provider=[string]$context.Provider
        Actual=[PSCustomObject]@{ Cpu=[decimal]$context.CurrentCpu; MemoryMB=[int]$context.CurrentMemoryMB; Port=[int]$context.CurrentPort; SqlRuntimeContract=if($runtimeContractCurrent){'CURRENT'}else{'DRIFTED'}; AutoStart=[string]$context.CurrentAutoStart; SqlMaxMemoryMB=$currentSqlMaxMemory }
        Desired=[PSCustomObject]@{ Cpu=$targetCpu; MemoryMB=$targetMemory; Port=$targetPort; SqlMemoryLimitMB=$sqlMemoryLimit; SqlMaxMemoryMB=$targetSqlMaxMemory; AutoStart=$targetAutoStart; RepairSqlRuntimeContract=[bool]$RepairSqlRuntimeContract }
        Diff=$diff; Actions=$actions; HighestChangeClass=$changeClass; IsNoOp=$changeClass -eq 'no-op'; MutationAllowed=$false
        Preview=[PSCustomObject]@{
            Downtime=if($changeClass -eq 'recreate'){'brief'}else{'none'}
            DataImpact=if($changeClass -ne 'recreate'){'mount configuration unchanged'}elseif($mountPreview.Status -ne 'MEASURED'){'mount preservation unconfirmed'}else{'mount preservation is not independently verified; only bind mounts and named volumes have a recreate path'}
            Mounts=$mountPreview
            Recovery=if($changeClass -eq 'recreate'){'rename rollback with original container'}elseif($changeClass -eq 'live'){'resource rollback to captured limits'}else{'not required'}
        }
        Warnings=if($changeClass -eq 'recreate'){@('SQL ist während des kontrollierten Container-Recreate kurz nicht erreichbar.')}else{@()}
    }
}

function New-LabContainerReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Plan)
    $operationId = [guid]::NewGuid().ToString('D')
    $journal = [PSCustomObject]@{
        ContractVersion='SqlServerLab.ContainerReconcileJournal/1.0'; OperationId=$operationId
        RunId=[string]$Context.RunId; ScopeId=[string]$Context.Run.scopeId; InstanceId=[string]$Context.InstanceId
        Provider=[string]$Context.Provider; ChangeClass=[string]$Plan.HighestChangeClass; Status='PREPARED'
        Before=[PSCustomObject]@{ Cpu=[decimal]$Context.CurrentCpu; MemoryMB=[int]$Context.CurrentMemoryMB; Port=[int]$Context.CurrentPort; SqlMaxMemoryMB=$Plan.Actual.SqlMaxMemoryMB; AutoStart=[string]$Context.CurrentAutoStart; RestartPolicy=[string]$Context.CurrentRestartPolicy; AutoStartLabel=[string]$Context.CurrentAutoStartLabel; Running=[bool]$Context.WasRunning; RunState=[string]$Context.Run.state; MountFingerprint=[string]$Context.MountFingerprint }
        Target=[PSCustomObject]@{ Cpu=[decimal]$Plan.Desired.Cpu; MemoryMB=[int]$Plan.Desired.MemoryMB; Port=[int]$Plan.Desired.Port; SqlMemoryLimitMB=[int]$Plan.Desired.SqlMemoryLimitMB; SqlMaxMemoryMB=$Plan.Desired.SqlMaxMemoryMB; AutoStart=[string]$Plan.Desired.AutoStart; MountFingerprint=[string]$Context.MountFingerprint }
        Runtime=[PSCustomObject]@{ ContainerName=[string]$Context.ContainerName; OriginalId=[string]$Context.ContainerId; BackupName=$null; ReplacementId=$null }
        PreviousConnection=$Context.Connection
        Recovery=[PSCustomObject]@{ Status='ROLLBACK_AVAILABLE'; Attempts=0; ErrorCode=$null; Errors=@() }
        UpdatedAt=Get-LabTimestamp
    }
    $path = Get-LabContainerReconcileJournalPath -RunDirectory $Context.RunDirectory
    $null = Write-LabContainerReconcileJournal -Journal $journal -Path $path
    return [PSCustomObject]@{ Journal=$journal; Path=$path }
}

function Invoke-LabContainerReconcileCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ErrorCode
    )
    $runtimeInvocation = Get-LabHostToolInvocation -Name $Provider
    $output = @(& $runtimeInvocation @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "${ErrorCode}: $($output -join ' ')" }
    return @($output)
}

function Test-LabContainerReconcileRuntimeExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider, [string]$Identity)
    if (-not $Identity) { return $false }
    $runtimeInvocation = Get-LabHostToolInvocation -Name $Provider
    $null = & $runtimeInvocation inspect $Identity 2>$null
    return $LASTEXITCODE -eq 0
}

function Assert-LabContainerReconcileRuntimeIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId
    )
    $runtimeInvocation = Get-LabHostToolInvocation -Name $Provider
    $inspect = @(& $runtimeInvocation inspect $Identity 2>$null | ConvertFrom-Json -Depth 50)[0]
    if (-not $inspect -or [string]$inspect.Config.Labels.'sql-server-lab.run-id' -ne $RunId -or
        [string]$inspect.Config.Labels.'sql-server-lab.scope-id' -ne $ScopeId) {
        throw 'CONTAINER_RECONCILE_RECOVERY_SCOPE_MISMATCH'
    }
    return $inspect
}

function Restore-LabContainerReconcileRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Journal)
    $target = [string]$Journal.Before.RunState
    if ($target -notin @('RUNNING','STOPPED')) { return }
    $current = Get-LabRunState -RunId ([string]$Context.RunId) -StateRoot $Context.StateRoot
    if ([string]$current.state -eq 'RECOVERY_REQUIRED') {
        $null = Set-LabRunState -RunId ([string]$Context.RunId) -NewState $target -Reason 'Container-Reconcile-Recovery abgeschlossen' -StateRoot $Context.StateRoot
    }
    $providerSubRun = @(Get-LabProviderSubRuns -RunId ([string]$Context.RunId) -StateRoot $Context.StateRoot | Where-Object { [string]$_.provider -eq [string]$Journal.Provider } | Select-Object -First 1)
    if ($providerSubRun.Count -eq 1 -and [string]$providerSubRun[0].state -eq 'RECOVERY_REQUIRED') {
        Set-LabProviderSubRunState -RunId ([string]$Context.RunId) -Provider ([string]$Journal.Provider) -NewState $target -Reason 'Container-Reconcile-Recovery abgeschlossen' -StateRoot $Context.StateRoot
    }
}

function Repair-LabContainerReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if (((Test-Path (Join-Path $Context.StateRoot 'owned-host-required')) -or (Test-Path -LiteralPath (Join-Path $Context.StateRoot 'owned-host-policy.json')))) {
        $null=Get-LabOwnedHostRunPolicy -RunId $Context.RunId -StateRoot $Context.StateRoot
        throw 'OWNED_HOST_CONTAINER_RECONCILE_MUTATION_UNSUPPORTED'
    }
    $path = Get-LabContainerReconcileJournalPath -RunDirectory $Context.RunDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $null = Assert-LabContainerReconcileJournal -Journal $journal
    if ([string]$journal.RunId -ne [string]$Context.RunId -or [string]$journal.ScopeId -ne [string]$Context.Run.scopeId -or
        [string]$journal.InstanceId -ne [string]$Context.InstanceId -or [string]$journal.Provider -ne [string]$Context.Provider) {
        throw 'CONTAINER_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    if ([string]$journal.Status -in @('COMPLETED','ROLLED_BACK')) { return $journal }
    $journal.Recovery.Attempts = [int]$journal.Recovery.Attempts + 1
    $provider = [string]$journal.Provider
    try {
        if ([string]$journal.Status -eq 'STATE_COMMITTED') {
            if (-not (Test-LabContainerReconcileRuntimeExists -Provider $provider -Identity ([string]$journal.Runtime.ContainerName))) {
                throw 'CONTAINER_RECONCILE_RECOVERY_REPLACEMENT_MISSING'
            }
            $replacement = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity ([string]$journal.Runtime.ContainerName) -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
            if ([string]$replacement.Id -ne [string]$journal.Runtime.ReplacementId) {
                throw 'CONTAINER_RECONCILE_RECOVERY_REPLACEMENT_ID_MISMATCH'
            }
            if ((Get-LabContainerMountFingerprint -Mounts @($replacement.Mounts)) -ne [string]$journal.Target.MountFingerprint) {
                throw 'CONTAINER_RECONCILE_RECOVERY_MOUNT_MISMATCH'
            }
            if ([long]$replacement.HostConfig.Memory -ne ([long][int]$journal.Target.MemoryMB * 1MB) -or
                [decimal]([long]$replacement.HostConfig.NanoCpus / 1000000000) -ne [decimal]$journal.Target.Cpu) {
                throw 'CONTAINER_RECONCILE_RECOVERY_RESOURCE_MISMATCH'
            }
            $replacementPort = @($replacement.NetworkSettings.Ports.'1433/tcp' | Select-Object -First 1)
            if ($replacementPort.Count -ne 1 -or [int]$replacementPort[0].HostPort -ne [int]$journal.Target.Port) {
                throw 'CONTAINER_RECONCILE_RECOVERY_PORT_MISMATCH'
            }
            $expectedMemoryEnvironment = "MSSQL_MEMORY_LIMIT_MB=$([int]$journal.Target.SqlMemoryLimitMB)"
            if ($expectedMemoryEnvironment -notin @($replacement.Config.Env) -or
                [string](@($replacement.Config.Healthcheck.Test) -join ' ') -notmatch '(?:^|\s)-C(?:\s|$)') {
                throw 'CONTAINER_RECONCILE_RECOVERY_SQL_RUNTIME_CONTRACT_MISMATCH'
            }
            if ($journal.Target.PSObject.Properties['AutoStart']) {
                $expectedAutoStart = [string]$journal.Target.AutoStart
                $actualAutoStart = if ([string]$replacement.HostConfig.RestartPolicy.Name -in @('always','unless-stopped') -and
                    [string]$replacement.Config.Labels.'sql-server-lab.autostart' -eq 'on') { 'on' }
                elseif ([string]$replacement.HostConfig.RestartPolicy.Name -in @('','no') -and
                    [string]$replacement.Config.Labels.'sql-server-lab.autostart' -in @('','off')) { 'off' }
                else { 'DRIFTED' }
                if ($actualAutoStart -ne $expectedAutoStart) {
                    throw 'CONTAINER_RECONCILE_RECOVERY_AUTOSTART_MISMATCH'
                }
            }
            if ($null -ne $journal.Target.SqlMaxMemoryMB) {
                $replacementSqlContext = $Context | Select-Object *
                $replacementSqlContext.CurrentPort = [int]$journal.Target.Port
                if ((Get-LabContainerSqlMaxMemoryMB -Context $replacementSqlContext) -ne [int]$journal.Target.SqlMaxMemoryMB) {
                    throw 'CONTAINER_RECONCILE_RECOVERY_SQL_MAX_MEMORY_MISMATCH'
                }
            }
            if (Test-LabContainerReconcileRuntimeExists -Provider $provider -Identity ([string]$journal.Runtime.BackupName)) {
                $null = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity ([string]$journal.Runtime.BackupName) -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
                $null = Invoke-LabContainerReconcileCommand -Provider $provider -Arguments @('rm','-f',[string]$journal.Runtime.BackupName) -ErrorCode 'CONTAINER_RECONCILE_RECOVERY_BACKUP_REMOVE_FAILED'
            }
            Restore-LabContainerReconcileRunState -Context $Context -Journal $journal
            return Set-LabContainerReconcileJournalStatus -Journal $journal -Path $path -Status COMPLETED
        }

        if ([string]$journal.ChangeClass -eq 'live') {
            $originalId = [string]$journal.Runtime.OriginalId
            $original = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity $originalId -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
            if ([string]$original.Id -ne $originalId -or [string]$original.Config.Labels.'sql-server-lab.instance-id' -ne [string]$journal.InstanceId) { throw 'CONTAINER_RECONCILE_RECOVERY_ORIGINAL_ID_MISMATCH' }
            $cpu = ([decimal]$journal.Before.Cpu).ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)
            $null = Invoke-LabContainerReconcileCommand -Provider $provider -Arguments @('update','--cpus',$cpu,'--memory',"$([int]$journal.Before.MemoryMB)m",$originalId) -ErrorCode 'CONTAINER_RECONCILE_LIVE_ROLLBACK_FAILED'
            if ($null -ne $journal.Before.SqlMaxMemoryMB) {
                $null = Set-LabContainerSqlMaxMemoryMB -Context $Context -SqlMaxMemoryMB ([int]$journal.Before.SqlMaxMemoryMB)
            }
            Write-LabArtifactJsonAtomic -Path $Context.ConnectionPath -InputObject $journal.PreviousConnection
            Restore-LabContainerReconcileRunState -Context $Context -Journal $journal
            return Set-LabContainerReconcileJournalStatus -Journal $journal -Path $path -Status ROLLED_BACK
        }

        $canonical = [string]$journal.Runtime.ContainerName
        $backup = [string]$journal.Runtime.BackupName
        $canonicalExists = Test-LabContainerReconcileRuntimeExists -Provider $provider -Identity $canonical
        $backupExists = Test-LabContainerReconcileRuntimeExists -Provider $provider -Identity $backup
        if ($canonicalExists -and $backupExists) {
            $candidateReplacement = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity $canonical -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
            if (-not $journal.Runtime.ReplacementId -or [string]$candidateReplacement.Id -ne [string]$journal.Runtime.ReplacementId) {
                throw 'CONTAINER_RECONCILE_RECOVERY_REPLACEMENT_ID_MISMATCH'
            }
            $candidateOriginal = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity $backup -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
            if ([string]$candidateOriginal.Id -ne [string]$journal.Runtime.OriginalId) {
                throw 'CONTAINER_RECONCILE_RECOVERY_ORIGINAL_ID_MISMATCH'
            }
            $null = Invoke-LabContainerReconcileCommand -Provider $provider -Arguments @('rm','-f',$canonical) -ErrorCode 'CONTAINER_RECONCILE_RECOVERY_REPLACEMENT_REMOVE_FAILED'
            $canonicalExists = $false
        }
        if ($backupExists) {
            $candidateOriginal = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity $backup -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
            if ([string]$candidateOriginal.Id -ne [string]$journal.Runtime.OriginalId) {
                throw 'CONTAINER_RECONCILE_RECOVERY_ORIGINAL_ID_MISMATCH'
            }
            $null = Invoke-LabContainerReconcileCommand -Provider $provider -Arguments @('rename',$backup,$canonical) -ErrorCode 'CONTAINER_RECONCILE_RECOVERY_RENAME_FAILED'
            $canonicalExists = $true
        }
        if (-not $canonicalExists) { throw 'CONTAINER_RECONCILE_RECOVERY_ORIGINAL_MISSING' }
        $restored = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity $canonical -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
        if ([string]$restored.Id -ne [string]$journal.Runtime.OriginalId) { throw 'CONTAINER_RECONCILE_RECOVERY_ORIGINAL_ID_MISMATCH' }
        if ([bool]$journal.Before.Running -and -not [bool]$restored.State.Running) {
            $null = Invoke-LabContainerReconcileCommand -Provider $provider -Arguments @('start',$canonical) -ErrorCode 'CONTAINER_RECONCILE_RECOVERY_START_FAILED'
        }
        elseif (-not [bool]$journal.Before.Running -and [bool]$restored.State.Running) {
            $null = Invoke-LabContainerReconcileCommand -Provider $provider -Arguments @('stop',$canonical) -ErrorCode 'CONTAINER_RECONCILE_RECOVERY_STOP_FAILED'
        }
        if ($null -ne $journal.Before.SqlMaxMemoryMB) {
            $password = Get-LabSecret -Path $Context.RunDirectory -Name 'sa-password'
            if (-not $password) { throw 'CONTAINER_RECONCILE_SA_SECRET_MISSING' }
            $hostName = if ($Context.Instance.host) { [string]$Context.Instance.host } else { '127.0.0.1' }
            $readiness = Wait-SqlReady -HostName $hostName -Port ([int]$journal.Before.Port) -SaPassword $password `
                -TimeoutSeconds 180 -Provider $provider -ContainerIdOrName $canonical
            if (-not $readiness.Ready) { throw 'CONTAINER_RECONCILE_RECOVERY_SQL_READINESS_FAILED' }
            $null = Set-LabContainerSqlMaxMemoryMB -Context $Context -SqlMaxMemoryMB ([int]$journal.Before.SqlMaxMemoryMB)
        }
        Write-LabArtifactJsonAtomic -Path $Context.ConnectionPath -InputObject $journal.PreviousConnection
        Restore-LabContainerReconcileRunState -Context $Context -Journal $journal
        return Set-LabContainerReconcileJournalStatus -Journal $journal -Path $path -Status ROLLED_BACK
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'CONTAINER_RECONCILE_RECOVERY_FAILED' }
        $journal.Recovery.Errors = @($journal.Recovery.Errors) + @($code)
        $null = Set-LabContainerReconcileJournalStatus -Journal $journal -Path $path -Status RECOVERY_REQUIRED -ErrorCode $code
        try {
            if ([string]$Context.Run.state -in @('RUNNING','STOPPED')) {
                $null = Set-LabRunState -RunId ([string]$Context.RunId) -NewState RECOVERY_REQUIRED -Reason $code -StateRoot $Context.StateRoot
                Set-LabProviderSubRunState -RunId ([string]$Context.RunId) -Provider $provider -NewState RECOVERY_REQUIRED -Reason $code -StateRoot $Context.StateRoot
            }
        } catch { }
        throw "CONTAINER_RECONCILE_RECOVERY_REQUIRED: $code"
    }
}
