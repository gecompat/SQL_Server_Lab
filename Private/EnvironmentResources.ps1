function Assert-LabResourceChangeAllowed {
    param([string]$RunId, [string]$StateRoot)
    if (Test-LabAutomatedTestEnvironmentRun -RunId $RunId) { throw 'RESOURCE_CHANGE_PROTECTED_GROUP' }
    $cms = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    if ($cms -and [string]$cms.RunId -eq $RunId) { throw 'RESOURCE_CHANGE_SYSTEM_SERVICE' }
}

function Get-LabResourceChangeTargets {
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)
    $context = Get-LabEnvironmentResourceContext -RunId $RunId -StateRoot $StateRoot
    Assert-LabResourceChangeAllowed -RunId $RunId -StateRoot $context.StateRoot
    @($context.Connection.instances | ForEach-Object {
        [pscustomobject]@{ InstanceId=[string]$_.id; Provider=[string]$_.provider }
    })
}

function Get-LabResourceChangePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv')][string]$Provider,
        [Nullable[decimal]]$Cpu, [Nullable[int]]$MemoryMB, [string]$StateRoot
    )
    $environment = Get-LabEnvironmentResourceContext -RunId $RunId -StateRoot $StateRoot
    Assert-LabResourceChangeAllowed -RunId $RunId -StateRoot $environment.StateRoot
    $targets = @($environment.Connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq $Provider })
    if ($targets.Count -ne 1) { throw 'RESOURCE_CHANGE_TARGET_MISMATCH' }
    $actualCpu = $null; $actualMemory = $null; $reason = ''; $binding = $null
    if ($Provider -eq 'hyperv') {
        $managed = Get-HyperVManagedVM -VMName ([string]$targets[0].vmName) -ExpectedRunId $RunId -ExpectedScopeId ([string]$environment.Run.scopeId)
        if (-not $managed -or [string]$managed.VM.Id -ne [string]$targets[0].vmId) { throw 'RESOURCE_CHANGE_TARGET_MISMATCH' }
        $actualCpu = [decimal]$managed.VM.ProcessorCount
        $actualMemory = [int]([long]$managed.VM.MemoryStartup / 1MB)
        $reason = 'Hyper-V: Apply nicht verfügbar. Dauerhafte Sollzustandsautorität und journalisierte Recovery für neue Ressourcenwerte sind noch offen; DynamicMemory und Min/Max bleiben unverändert.'
    }
    else {
        $context = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $environment.StateRoot
        $subRuns = @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $environment.StateRoot | Where-Object { [string]$_.provider -eq $Provider })
        if ([string]$context.Run.state -notin @('RUNNING','STOPPED') -or $subRuns.Count -ne 1 -or
            [string]$subRuns[0].state -notin @('RUNNING','STOPPED')) { throw 'RESOURCE_CHANGE_LIFECYCLE_BLOCKED' }
        if ([string]$context.Provider -ne $Provider -or -not $context.ContainerId -or
            [string]$context.Inspect.Config.Labels.'sql-server-lab.instance-id' -ne $InstanceId) { throw 'RESOURCE_CHANGE_TARGET_MISMATCH' }
        # Never substitute stored or reconcile fallback limits for measured values.
        $bytes = [long]$context.Inspect.HostConfig.Memory
        if ($bytes -gt 0 -and $bytes % 1MB -eq 0) { $actualMemory = [int]($bytes / 1MB) }
        $actualCpu = Get-LabContainerMeasuredCpu -Inspect $context.Inspect
        if ($null -eq $actualMemory -or $null -eq $actualCpu) { $reason = 'Istlimit unbekannt, unbegrenzt oder widersprüchlich. Apply nicht verfügbar; Runtime-Limits prüfen.' }
        $journalPath = Get-LabContainerReconcileJournalPath -RunDirectory $context.RunDirectory
        $journalKey = 'absent'
        if (Test-Path -LiteralPath $journalPath) {
            $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -Depth 50
            $null = Assert-LabContainerReconcileJournal -Journal $journal
            if ([string]$journal.RunId -ne $RunId -or [string]$journal.ScopeId -ne [string]$context.Run.scopeId -or
                [string]$journal.InstanceId -ne $InstanceId -or [string]$journal.Provider -ne $Provider -or
                [string]$journal.Status -notin @('COMPLETED','ROLLED_BACK')) { throw 'RESOURCE_CHANGE_JOURNAL_BLOCKED' }
            $journalKey = (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash
        }
        $binding = [ordered]@{
            Root=(Get-LabCanonicalResourceRoot -StateRoot $context.StateRoot); Run=$RunId; Scope=[string]$context.Run.scopeId
            RunState=[string]$context.Run.state; ProviderState=[string]$subRuns[0].state
            Instance=$InstanceId; Provider=$Provider; RuntimeId=[string]$context.ContainerId
            Cpu=$actualCpu; MemoryMB=$actualMemory; Port=[int]$context.CurrentPort
            Ports=$context.Inspect.NetworkSettings.Ports; RestartPolicy=$context.Inspect.HostConfig.RestartPolicy
            AutoStartLabel=[string]$context.CurrentAutoStartLabel; Mounts=[string]$context.MountFingerprint
            Running=[bool]$context.WasRunning; Journal=$journalKey
        }
    }
    $desiredCpu = if ($null -ne $Cpu) { $Cpu } else { $actualCpu }
    $desiredMemory = if ($null -ne $MemoryMB) { $MemoryMB } else { $actualMemory }
    if ($null -ne $desiredCpu -and ($desiredCpu -lt 1 -or $desiredCpu -gt 64 -or [math]::Round($desiredCpu,2) -ne $desiredCpu)) { throw 'RESOURCE_CHANGE_CPU_RANGE: 1 bis 64, höchstens zwei Nachkommastellen.' }
    if ($null -ne $desiredMemory -and ($desiredMemory -lt 512 -or $desiredMemory -gt 1048576)) { throw 'RESOURCE_CHANGE_MEMORY_RANGE: 512 bis 1048576 MB.' }
    $noOp = $null -ne $actualCpu -and $null -ne $actualMemory -and $desiredCpu -eq $actualCpu -and $desiredMemory -eq $actualMemory
    $key = $null
    if ($binding) {
        $binding.DesiredCpu = $desiredCpu; $binding.DesiredMemoryMB = $desiredMemory
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($binding | ConvertTo-Json -Depth 12 -Compress)))).ToLowerInvariant()
    }
    [pscustomobject]@{
        RunId=$RunId; InstanceId=$InstanceId; Provider=$Provider
        Actual=[pscustomobject]@{ Cpu=$actualCpu; MemoryMB=$actualMemory }
        Desired=[pscustomobject]@{ Cpu=$desiredCpu; MemoryMB=$desiredMemory }
        NoChange=$noOp; ChangeClass=$(if ($noOp) {'no-op'} elseif ($reason) {'unsupported'} else {'live'})
        CanApply=([string]::IsNullOrEmpty($reason)); Reason=$reason; PlanKey=$key
        NextStep=$(if ($reason) {$reason} elseif ($noOp) {'Keine Änderung erforderlich.'} elseif (-not $context.WasRunning) {'Limits für den nächsten Start ändern; kein Start, keine Port-, Autostart- oder SQL-Speicheränderung.'} else {'CPU/RAM live ändern; kein Neustart, keine Port-, Autostart- oder SQL-Speicheränderung.'})
    }
}

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
