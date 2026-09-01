<#
.SYNOPSIS
    Plant und journalisiert kontrollierte Docker-/Podman-Ressourcenaenderungen.
.DESCRIPTION
    Der read-only Plan trennt No-op, Live-Update und Recreate. Das lokale
    Operationsjournal bindet die Mutation an Run, Scope und echte Runtime-IDs
    und liefert einen idempotenten Rollback-/Resume-Einstieg.
#>

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
    $inspect = @(& $runtimeInvocation inspect $identity 2>$null | ConvertFrom-Json -Depth 50)[0]
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
    $currentCpu = if ([long]$inspect.HostConfig.NanoCpus -gt 0) { [decimal]([long]$inspect.HostConfig.NanoCpus / 1000000000) } else { 2 }
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
            DataImpact='managed mounts and volumes preserved'
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
            $null = Assert-LabContainerReconcileRuntimeIdentity -Provider $provider -Identity ([string]$journal.Runtime.ContainerName) -RunId ([string]$journal.RunId) -ScopeId ([string]$journal.ScopeId)
            $cpu = ([decimal]$journal.Before.Cpu).ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)
            $null = Invoke-LabContainerReconcileCommand -Provider $provider -Arguments @('update','--cpus',$cpu,'--memory',"$([int]$journal.Before.MemoryMB)m",[string]$journal.Runtime.ContainerName) -ErrorCode 'CONTAINER_RECONCILE_LIVE_ROLLBACK_FAILED'
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
