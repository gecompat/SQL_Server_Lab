function Get-LabEnvironmentResourceContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        throw "LAB_ENVIRONMENT_CONNECTION_INFO_NOT_FOUND: $RunId"
    }

    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    [pscustomobject]@{
        Run = $run
        StateRoot = $StateRoot
        RunDirectory = $runDirectory
        ConnectionPath = $connectionPath
        Connection = $connection
    }
}

function Get-LabContainerResourceValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)]$Instance
    )

    $container = if ($Instance.containerId) { [string]$Instance.containerId } else { [string]$Instance.containerName }
    if ([string]::IsNullOrWhiteSpace($container)) { throw 'LAB_ENVIRONMENT_CONTAINER_ID_MISSING' }
    $status = if ($Provider -eq 'docker') {
        Get-DockerInstanceStatus -ContainerIdOrName $container
    }
    else {
        Get-PodmanInstanceStatus -ContainerIdOrName $container
    }
    $raw = if ($status -and $status.PSObject.Properties['Inspect']) { @($status.Inspect)[0] } else { $null }
    if (-not $status -or -not $status.Exists -or -not $raw) {
        return [pscustomobject]@{
            Available = $false
            Container = $container
            Status = $status
            Raw = $raw
            RuntimeState = 'MISSING'
            MemoryLimitMB = 0
            ProcessorCount = 0
        }
    }

    $memoryBytes = if ($raw.HostConfig -and $raw.HostConfig.Memory) { [long]$raw.HostConfig.Memory } else { 0L }
    $processorCount = [decimal]0
    if ($raw.HostConfig -and [long]$raw.HostConfig.NanoCpus -gt 0) {
        $processorCount = [decimal]$raw.HostConfig.NanoCpus / [decimal]1000000000
    }
    elseif ($raw.HostConfig -and [long]$raw.HostConfig.CpuQuota -gt 0 -and [long]$raw.HostConfig.CpuPeriod -gt 0) {
        $processorCount = [decimal]$raw.HostConfig.CpuQuota / [decimal]$raw.HostConfig.CpuPeriod
    }
    if ($memoryBytes -le 0 -and $Instance.resourceSettings) {
        $storedMemory = if ($Instance.resourceSettings.memoryMB) { $Instance.resourceSettings.memoryMB } else { $Instance.resourceSettings.memoryLimitMB }
        if ($storedMemory) { $memoryBytes = [long]$storedMemory * 1MB }
    }
    if ($processorCount -le 0 -and $Instance.resourceSettings -and $Instance.resourceSettings.processorCount) {
        $processorCount = [decimal]$Instance.resourceSettings.processorCount
    }

    $runtimeState = if ($raw.State -and $raw.State.Status) { [string]$raw.State.Status } elseif ($status.Running) { 'running' } else { 'stopped' }
    [pscustomobject]@{
        Available = $true
        Container = $container
        Status = $status
        Raw = $raw
        RuntimeState = $runtimeState
        MemoryLimitMB = [int][Math]::Round(([decimal]$memoryBytes / 1MB), 0)
        ProcessorCount = $processorCount
    }
}

function Get-LabEnvironmentResources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    $context = Get-LabEnvironmentResourceContext -RunId $RunId -StateRoot $StateRoot
    $items = foreach ($instance in @($context.Connection.instances)) {
        $provider = ([string]$instance.provider).ToLowerInvariant()
        try {
            if ($provider -eq 'hyperv') {
                $managed = Get-HyperVManagedVM -VMName ([string]$instance.vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$context.Run.scopeId
                )
                if (-not $managed) {
                    [pscustomobject]@{ InstanceId=[string]$instance.id; Provider=$provider; Available=$false; RuntimeState='MISSING'; MemoryStartupMB=0; MemoryLimitMB=0; ProcessorCount=0 }
                    continue
                }
                [pscustomobject]@{
                    InstanceId = [string]$instance.id
                    Provider = $provider
                    RuntimeName = [string]$instance.vmName
                    Available = $true
                    RuntimeState = [string]$managed.VM.State
                    MemoryStartupMB = [int][Math]::Round(([decimal][long]$managed.VM.MemoryStartup / 1MB), 0)
                    MemoryLimitMB = 0
                    ProcessorCount = [decimal]$managed.VM.ProcessorCount
                }
                continue
            }
            if ($provider -in @('docker', 'podman')) {
                $values = Get-LabContainerResourceValues -Provider $provider -Instance $instance
                [pscustomobject]@{
                    InstanceId = [string]$instance.id
                    Provider = $provider
                    RuntimeName = [string]$values.Container
                    Available = [bool]$values.Available
                    RuntimeState = [string]$values.RuntimeState
                    MemoryStartupMB = 0
                    MemoryLimitMB = [int]$values.MemoryLimitMB
                    ProcessorCount = [decimal]$values.ProcessorCount
                }
                continue
            }
            [pscustomobject]@{ InstanceId=[string]$instance.id; Provider=$provider; Available=$false; RuntimeState='UNSUPPORTED'; MemoryStartupMB=0; MemoryLimitMB=0; ProcessorCount=0 }
        }
        catch {
            [pscustomobject]@{ InstanceId=[string]$instance.id; Provider=$provider; Available=$false; RuntimeState='UNAVAILABLE'; MemoryStartupMB=0; MemoryLimitMB=0; ProcessorCount=0; Error=$_.Exception.Message }
        }
    }

    [pscustomobject]@{
        RunId = $RunId
        Name = [string]$context.Run.metadata.name
        Instances = @($items)
    }
}

function Set-LabEnvironmentResources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateRange(512, 1048576)][int]$MemoryMB,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int]$ProcessorCount,
        [string]$StateRoot
    )

    $context = Get-LabEnvironmentResourceContext -RunId $RunId -StateRoot $StateRoot
    $current = Get-LabEnvironmentResources -RunId $RunId -StateRoot $context.StateRoot
    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($instance in @($context.Connection.instances)) {
        $provider = ([string]$instance.provider).ToLowerInvariant()
        $currentItem = @($current.Instances | Where-Object { [string]$_.InstanceId -eq [string]$instance.id }) | Select-Object -First 1
        if (-not $currentItem -or -not $currentItem.Available) {
            throw "LAB_ENVIRONMENT_RUNTIME_UNAVAILABLE: $provider/$($instance.id)"
        }

        if ($provider -eq 'hyperv') {
            $managed = Get-HyperVManagedVM -VMName ([string]$instance.vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$context.Run.scopeId)
            if (-not $managed) { throw "HYPERV_LAB_VM_NOT_FOUND: $($instance.vmName)" }
            if ([string]$managed.VM.State -ne 'Off') { throw "HYPERV_LAB_VM_MUST_BE_OFF_FOR_RESOURCE_CHANGE: $($instance.vmName)" }
            $targets.Add([pscustomobject]@{ Provider=$provider; Instance=$instance; Runtime=$managed; Current=$currentItem })
            continue
        }
        if ($provider -in @('docker', 'podman')) {
            $values = Get-LabContainerResourceValues -Provider $provider -Instance $instance
            $labels = $values.Raw.Config.Labels
            if ([string]$labels.'sql-server-lab.run-id' -ne $RunId -or [string]$labels.'sql-server-lab.scope-id' -ne [string]$context.Run.scopeId) {
                throw "LAB_ENVIRONMENT_RESOURCE_SCOPE_VIOLATION: $provider/$($values.Container)"
            }
            $targets.Add([pscustomobject]@{ Provider=$provider; Instance=$instance; Runtime=$values; Current=$currentItem })
            continue
        }
        throw "LAB_ENVIRONMENT_PROVIDER_UNSUPPORTED: $provider"
    }

    $changed = $false
    foreach ($target in $targets) {
        $currentMemory = if ($target.Provider -eq 'hyperv') { [int]$target.Current.MemoryStartupMB } else { [int]$target.Current.MemoryLimitMB }
        $currentCpu = [int][Math]::Ceiling([decimal]$target.Current.ProcessorCount)
        if ($currentMemory -eq $MemoryMB -and $currentCpu -eq $ProcessorCount) { continue }

        if ($target.Provider -eq 'hyperv') {
            $startupBytes = [long]$MemoryMB * 1MB
            $minimumBytes = [long][Math]::Max([double]512MB, [double]$startupBytes / 2)
            $maximumBytes = [long][Math]::Min([double]1TB, [double]$startupBytes * 2)
            $null = Set-VMProcessor -VM $target.Runtime.VM -Count $ProcessorCount -ErrorAction Stop
            $null = Set-VMMemory -VM $target.Runtime.VM -DynamicMemoryEnabled $true -MinimumBytes $minimumBytes -StartupBytes $startupBytes -MaximumBytes $maximumBytes -ErrorAction Stop
        }
        else {
            $arguments = @('update', '--memory', "${MemoryMB}m", '--cpus', [string]$ProcessorCount, [string]$target.Runtime.Container)
            $output = & $target.Provider @arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "$($target.Provider.ToUpperInvariant())_RESOURCE_UPDATE_FAILED: $(@($output) -join ' ')" }
        }
        $changed = $true
        $target.Instance | Add-Member -NotePropertyName resourceSettings -NotePropertyValue ([pscustomobject]@{
            memoryMB = $MemoryMB
            processorCount = $ProcessorCount
            updatedAt = Get-LabTimestamp
        }) -Force
    }

    if ($changed) {
        $context.Run.updatedAt = Get-LabTimestamp
        Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $context.Connection
        Write-LabArtifactJsonAtomic -Path (Join-Path $context.RunDirectory 'run-state.json') -InputObject $context.Run
    }
    $providers = @($targets | ForEach-Object { [string]$_.Provider } | Sort-Object -Unique)
    [pscustomobject]@{
        SchemaVersion = 'SqlServerLab.ActionResult/1.0'
        RunId = $RunId
        Provider = ($providers -join '/')
        Changed = $changed
        NoChange = -not $changed
        Cancelled = $false
        Failed = $false
        ConnectionCenterImpact = $false
        Instances = @((Get-LabEnvironmentResources -RunId $RunId -StateRoot $context.StateRoot).Instances)
    }
}
