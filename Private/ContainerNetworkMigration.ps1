function Get-LabContainerNetworkMigrationJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
    return (Join-Path (Join-Path $StateRoot 'catalog') "container-network-migration-$Provider.json")
}

function New-LabContainerNetworkMigrationBlockedPlan {
    param([string]$Provider, [string]$Reason, $Recovery)

    [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}
        Provider=$Provider; Status='MIGRATION_BLOCKED'; IsNoOp=$true; Actions=@(); Warnings=@($Reason); Reason=$Reason
        Recovery=$Recovery
    }
}

function Get-LabContainerNetworkMigrationRecoveryView {
    param($Journal, [string]$Provider)

    $phases = @('PREPARED','TEMPORARY_NETWORK_READY','MANAGED_CONTAINERS_DETACHED','CANONICAL_NETWORK_READY')
    $phase = 'UNKNOWN'
    $code = 'UNKNOWN'
    if ($Journal -and $Journal.PSObject.Properties['ContractVersion'] -and
        $Journal.PSObject.Properties['Provider'] -and $Journal.PSObject.Properties['Status'] -and
        $Journal.ContractVersion -is [string] -and $Journal.ContractVersion -ceq 'SqlServerLab.ContainerNetworkMigrationJournal/1.0' -and
        $Journal.Provider -is [string] -and $Journal.Provider -ceq $Provider -and $Journal.Status -is [string]) {
        if ($Journal.Status -cin $phases) {
            $phase = $Journal.Status
        } elseif ($Journal.Status -ceq 'RECOVERY_REQUIRED') {
            if ($Journal.PSObject.Properties['LastRecordedPhase'] -and $Journal.LastRecordedPhase -is [string] -and
                $Journal.LastRecordedPhase -cin $phases) {
                $phase = $Journal.LastRecordedPhase
            }
            $knownFailures = @(
                'TEMPORARY_NETWORK_CREATE_FAILED','CREATE_UNCONFIRMED','STOP_FAILED','CONNECT_FAILED',
                'DISCONNECT_FAILED','OLD_NETWORK_REMOVE_FAILED','CANONICAL_NETWORK_CREATE_FAILED',
                'RECONNECT_FAILED','TEMPORARY_DISCONNECT_FAILED','START_FAILED','TEMPORARY_NETWORK_REMOVE_FAILED',
                'POSTCONDITION_UNCONFIRMED','CONTAINER_LIST_FAILED','MEMBER_CHANGED','MEMBERSHIP_INVALID',
                'UNVERIFIED_MEMBER','PROTECTED_MEMBER','PENDING_RECOVERY','STATIC_ADDRESS','UNCONFIRMED'
            ) | ForEach-Object { "LAB_NETWORK_MIGRATION_$_" }
            if ($Journal.PSObject.Properties['Error'] -and $Journal.Error -is [string] -and $Journal.Error -cin $knownFailures) {
                $code = $Journal.Error
            }
        }
    }
    [pscustomobject]@{ LastRecordedPhase=$phase; FailureCode=$code }
}

function Test-LabSettledContainerNetworkMigration {
    param([string]$Provider, [string]$StateRoot, $ConfiguredNetwork, $ObservedNetwork, [string]$ObservedSubnet)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $path = Get-LabContainerNetworkMigrationJournalPath -StateRoot $StateRoot -Provider $Provider
    if (-not (Test-LabPathWithinRoot -Root $StateRoot -Path $path).Valid -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try { $journal = Read-LabWorkflowJson -Path $path }
    catch { return $false }
    return (
        $journal.ContractVersion -ceq 'SqlServerLab.ContainerNetworkMigrationJournal/1.0' -and
        $journal.Status -ceq 'COMPLETED' -and $journal.Provider -ceq $Provider -and
        [string]$journal.OperationId -cmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -and
        [string]$journal.OldNetwork.Id -cmatch '^[a-f0-9]{64}$' -and
        [string]$journal.NewNetwork.Id -cmatch '^[a-f0-9]{64}$' -and
        $journal.OldNetwork.Id -cne $journal.NewNetwork.Id -and
        $journal.OldNetwork.Name -ceq $ConfiguredNetwork.Name -and
        $journal.NewNetwork.Name -ceq $ConfiguredNetwork.Name -and
        $journal.ConfiguredSubnet -ceq $ConfiguredNetwork.Subnet -and
        $journal.NewNetwork.Subnet -ceq $ObservedSubnet -and
        [string]$ObservedNetwork.Name -ceq $ConfiguredNetwork.Name -and
        [string]$ObservedNetwork.Id -ceq $journal.NewNetwork.Id -and
        [string]$ObservedNetwork.Labels.'sql-server-lab.network' -ceq 'managed' -and
        [string]$ObservedNetwork.Labels.'sql-server-lab.migration-id' -ceq [string]$journal.OperationId
    )
}

function Set-LabMigratedContainerNetworkSubnet {
    param($Network, [string]$Subnet)

    $parsed = ConvertTo-LabIpv4Subnet -Subnet $Subnet
    $Network.Subnet = $parsed.Cidr
    $Network.PrefixLength = $parsed.PrefixLength
    $Network.HostAddress = (ConvertFrom-LabIpv4UInt32 -Value ([uint32]($parsed.Network + 1))).ToString()
}

function Get-LabManagedContainersOnNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$NetworkName,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][hashtable]$Route
    )

    $listing = Invoke-LabContainerNetworkMigrationStep -Route $Route -Arguments @('ps','-a','--no-trunc','-q','--filter',"network=$NetworkName") `
        -FailureCode 'LAB_NETWORK_MIGRATION_CONTAINER_LIST_FAILED'
    $ids = @(($listing.Stdout -join "`n") -split '\r?\n' | Where-Object { $_ })
    if (@($ids | Where-Object { $_ -cnotmatch '^[a-f0-9]{64}$' }).Count -or
        @($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw 'LAB_NETWORK_MIGRATION_MEMBERSHIP_INVALID' }
    if (-not $ids.Count) { return }
    $groups = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
    $cms = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    $dataRoot = Get-LabDataRootDefault
    $protectedRuns = @(if ($dataRoot) {
        (Get-LabTestEnvironmentRegistry -OutputDirectory (Join-Path $dataRoot 'Exports')).environments.runId
    })
    $containers = @()
    foreach ($id in $ids) {
        $read = Invoke-LabContainerNetworkMigrationStep -Route $Route -Arguments @('inspect',$id) -FailureCode 'LAB_NETWORK_MIGRATION_MEMBER_CHANGED'
        $raw = $read.Stdout -join [Environment]::NewLine
        if (-not $raw) { throw 'LAB_NETWORK_MIGRATION_MEMBER_CHANGED' }
        $inspections = @($raw | ConvertFrom-Json -Depth 50 -ErrorAction Stop)
        if ($inspections.Count -ne 1 -or [string]$inspections[0].Id -cne $id) { throw 'LAB_NETWORK_MIGRATION_MEMBER_CHANGED' }
        $inspect = $inspections[0]
        $labels = $inspect.Config.Labels
        $runId = [string]$labels.'sql-server-lab.run-id'
        $scopeId = [string]$labels.'sql-server-lab.scope-id'
        $instanceId = [string]$labels.'sql-server-lab.instance-id'
        $networks = @($inspect.NetworkSettings.Networks.PSObject.Properties.Name)
        if ($NetworkName -cnotin $networks) { throw 'LAB_NETWORK_MIGRATION_MEMBER_CHANGED' }
        if ($runId -cnotmatch '^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
            -not $scopeId -or -not $instanceId) { throw 'LAB_NETWORK_MIGRATION_UNVERIFIED_MEMBER' }
        $statePath = Join-Path $StateRoot "runs/$runId/run-state.json"
        $connectionPath = Join-Path $StateRoot "runs/$runId/connection-info.json"
        if (-not (Test-LabPathWithinRoot -Root $StateRoot -Path $statePath).Valid -or
            -not (Test-LabPathWithinRoot -Root $StateRoot -Path $connectionPath).Valid -or
            -not (Test-Path -LiteralPath $statePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'LAB_NETWORK_MIGRATION_UNVERIFIED_MEMBER' }
        $state = Read-LabWorkflowJson -Path $statePath
        $connection = Read-LabWorkflowJson -Path $connectionPath
        $instances = @($connection.instances | Where-Object id -CEQ $instanceId)
        if ([string]$state.runId -cne $runId -or [string]$state.scopeId -cne $scopeId -or
            [string]$state.state -cnotin @('RUNNING','STOPPED') -or $instances.Count -ne 1 -or
            [string]$instances[0].provider -cne $Provider -or [string]$instances[0].containerId -cne $id -or
            $inspect.State.Running -isnot [bool]) { throw 'LAB_NETWORK_MIGRATION_UNVERIFIED_MEMBER' }
        if ([string]$cms.RunId -ceq $runId -or [string]$state.metadata.systemService -or
            $runId -iin $protectedRuns -or
            @($groups.groups.members | Where-Object runId -IEQ $runId).Count) { throw 'LAB_NETWORK_MIGRATION_PROTECTED_MEMBER' }
        try {
            Assert-LabEnvironmentGroupRunJournalsSettled -RunId $runId -StateRoot $StateRoot -Connection $connection
        } catch { throw 'LAB_NETWORK_MIGRATION_PENDING_RECOVERY' }
        $endpoint = $inspect.NetworkSettings.Networks.PSObject.Properties[$NetworkName].Value
        if ($endpoint.IPAMConfig.IPv4Address -or $endpoint.IPAMConfig.IPv6Address) { throw 'LAB_NETWORK_MIGRATION_STATIC_ADDRESS' }
        $aliases = @($endpoint.Aliases | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        if (@($aliases | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$' }).Count) {
            throw 'LAB_NETWORK_MIGRATION_MEMBERSHIP_INVALID'
        }
        $containers += [PSCustomObject]@{
            Id=$id; Name=([string]$inspect.Name).TrimStart('/'); RunId=$runId; ScopeId=$scopeId
            InstanceId=$instanceId; WasRunning=[bool]$inspect.State.Running; Aliases=$aliases
        }
    }
    return @($containers | Sort-Object RunId, Name)
}

function Get-LabContainerNetworkMigrationRoute {
    param([string]$Provider,[string]$StateRoot)

    $context = Get-LabRunArtifactRuntimeContext -Provider $Provider -StateRoot $StateRoot
    if ($context.StateRoot) { throw 'LAB_NETWORK_MIGRATION_OWNED_HOST_BLOCKED' }
    $invocation = Get-LabHostToolInvocation -Name $Provider
    $incarnation = Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $StateRoot -Invocation $invocation
    @{
        Provider=$Provider; StateRoot=$StateRoot; Context=$context; Invocation=$invocation; Incarnation=$incarnation
        Binding=Get-LabWorkflowHash -Text (($context.RuntimeScopeId,$context.RoutingKey,$incarnation) -join '|') -Length 64
    }
}

function New-LabContainerNetworkMigrationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider, [string]$StateRoot, [string]$TargetSubnet, [hashtable]$Route, [ref]$MemberBindings)

    if ($TargetSubnet) {
        try { $TargetSubnet = (ConvertTo-LabIpv4Subnet -Subnet $TargetSubnet).Cidr }
        catch { throw 'LAB_NETWORK_MIGRATION_TARGET_INVALID' }
    }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $journalPath = Get-LabContainerNetworkMigrationJournalPath -StateRoot $StateRoot -Provider $Provider
    if (-not (Test-LabPathWithinRoot -Root $StateRoot -Path $journalPath).Valid) {
        return New-LabContainerNetworkMigrationBlockedPlan -Provider $Provider -Reason 'LAB_NETWORK_MIGRATION_JOURNAL_PATH_UNSAFE'
    }
    if (Test-Path -LiteralPath $journalPath) {
        try { $journal = Read-LabWorkflowJson -Path $journalPath }
        catch { $journal = $null }
        if (-not $journal -or -not $journal.PSObject.Properties['ContractVersion'] -or
            -not $journal.PSObject.Properties['Provider'] -or -not $journal.PSObject.Properties['Status'] -or
            $journal.ContractVersion -isnot [string] -or $journal.Provider -isnot [string] -or $journal.Status -isnot [string] -or
            $journal.ContractVersion -cne 'SqlServerLab.ContainerNetworkMigrationJournal/1.0' -or
            $journal.Provider -cne $Provider -or $journal.Status -cne 'COMPLETED') {
            $recovery = Get-LabContainerNetworkMigrationRecoveryView -Journal $journal -Provider $Provider
            return New-LabContainerNetworkMigrationBlockedPlan -Provider $Provider -Reason 'LAB_NETWORK_MIGRATION_PENDING_RECOVERY' -Recovery $recovery
        }
    }
    $network = Get-LabRuntimeNetwork -Provider $Provider
    $runtime = Get-LabHostToolInvocation -Name $Provider
    $names = @(& $runtime network ls --format '{{.Name}}' 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_NETWORK_LIST_FAILED: $Provider" }
    if ($network.Name -cnotin $names) { return [PSCustomObject]@{ Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider; Status='NO_NETWORK'; IsNoOp=$true; Actions=@(); Warnings=@() } }
    $inspectJson = @(& $runtime network inspect $network.Name 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $inspectJson) { throw "LAB_NETWORK_MIGRATION_NETWORK_INSPECT_FAILED: $Provider" }
    $inspections = @($inspectJson | ConvertFrom-Json -Depth 50 -ErrorAction Stop)
    if ($inspections.Count -ne 1 -or -not $inspections[0]) { throw "LAB_NETWORK_MIGRATION_NETWORK_INSPECT_FAILED: $Provider" }
    $inspect = $inspections[0]
    $actualSubnet = if ($Provider -eq 'docker') { [string]@($inspect.IPAM.Config)[0].Subnet } else { [string](Get-LabPodmanNetworkContractFromInspect -Inspect $inspect).Subnet }
    $actual = [PSCustomObject]@{ Provider=$Provider; Name=$network.Name; Subnet=$actualSubnet; Intent='nat'; NatName=$null; Id=[string]$inspect.Id }
    $otherSubnets = @(Get-LabKnownIpv4Subnets -Provider $Provider -ExcludeNetworkId $actual.Id)
    try {
        Assert-LabRuntimeNetworkAvailable -Network $actual -KnownSubnets $otherSubnets
        return [PSCustomObject]@{ Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider; Status='NO_CONFLICT'; IsNoOp=$true; Actions=@(); Warnings=@() }
    }
    catch {
        if ($_.Exception.Message -notmatch '^LAB_NETWORK_SUBNET_CONFLICT:') { throw }
    }
    $blocker = $null
    $containers = @()
    if ($actual.Id -cnotmatch '^[a-f0-9]{64}$' -or [string]$inspect.Name -cne $network.Name -or
        [string]$inspect.Labels.'sql-server-lab.network' -cne 'managed' -or
        [string]$inspect.Driver -cne 'bridge' -or [bool]$inspect.Internal) {
        $blocker = 'LAB_NETWORK_MIGRATION_UNVERIFIED_NETWORK'
    } elseif ($actualSubnet -cne $network.Subnet -and
        -not (Test-LabSettledContainerNetworkMigration -Provider $Provider -StateRoot $StateRoot -ConfiguredNetwork $network -ObservedNetwork $inspect -ObservedSubnet $actualSubnet)) {
        $blocker = 'LAB_NETWORK_MIGRATION_UNVERIFIED_NETWORK'
    } elseif ((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or
        (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))) {
        $blocker = 'LAB_NETWORK_MIGRATION_OWNED_HOST_BLOCKED'
    } else {
        try {
            if (-not $Route) { $Route = Get-LabContainerNetworkMigrationRoute -Provider $Provider -StateRoot $StateRoot }
            $bound = Invoke-LabContainerNetworkMigrationStep -Route $Route -Arguments @('network','inspect',$actual.Id) -FailureCode 'LAB_NETWORK_MIGRATION_RUNTIME_UNVERIFIED'
            $boundNetwork = @(($bound.Stdout -join "`n") | ConvertFrom-Json -Depth 30)
            if ($boundNetwork.Count -ne 1 -or $boundNetwork[0].Id -cne $actual.Id -or $boundNetwork[0].Name -cne $network.Name) {
                throw 'LAB_NETWORK_MIGRATION_RUNTIME_UNVERIFIED'
            }
        }
        catch { return New-LabContainerNetworkMigrationBlockedPlan -Provider $Provider -Reason 'LAB_NETWORK_MIGRATION_RUNTIME_UNVERIFIED' }
        try { $containers = @(Get-LabManagedContainersOnNetwork -Provider $Provider -NetworkName $network.Name -StateRoot $StateRoot -Route $Route) }
        catch {
            if ($_.Exception.Message -cnotmatch '^LAB_NETWORK_MIGRATION_(UNVERIFIED_MEMBER|MEMBER_CHANGED|MEMBERSHIP_INVALID|PROTECTED_MEMBER|PENDING_RECOVERY|STATIC_ADDRESS)$') { throw }
            $blocker = $_.Exception.Message
        }
    }
    if ($blocker) {
        return New-LabContainerNetworkMigrationBlockedPlan -Provider $Provider -Reason $blocker
    }
    $target = if ($TargetSubnet) {
        $desired = [pscustomobject]@{Name=$network.Name;Subnet=$TargetSubnet}
        try { Assert-LabRuntimeNetworkAvailable -Network $desired -KnownSubnets ($otherSubnets + @($actualSubnet)) }
        catch {
            if ($_.Exception.Message -notmatch '^LAB_NETWORK_SUBNET_CONFLICT:') { throw }
            throw 'LAB_NETWORK_MIGRATION_TARGET_CONFLICT'
        }
        $desired
    } else { Resolve-LabAvailableContainerNetwork -Provider $Provider -Network $network -PlanOnly }
    $binding = [ordered]@{Root=(Get-LabCanonicalResourceRoot -StateRoot $StateRoot);DataRoot=(Get-LabDataRootDefault)
        Provider=$Provider;RuntimeBinding=$Route.Binding;NetworkId=$actual.Id;Name=$network.Name
        ConfiguredSubnet=$network.Subnet;OldSubnet=$actualSubnet;NewSubnet=$target.Subnet
        Members=@($containers | Select-Object Id,RunId,ScopeId,InstanceId,WasRunning,Aliases)}
    if ($null -ne $MemberBindings) {
        $MemberBindings.Value = @($containers | Select-Object Id,Name,RunId,ScopeId,InstanceId,WasRunning,Aliases)
    }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider
        Status='MIGRATION_REQUIRED'; IsNoOp=$false; Actions=@([PSCustomObject]@{Operation='MigrateManagedContainers';Provider=$Provider})
        PlanKey=Get-LabWorkflowHash -Text ($binding | ConvertTo-Json -Depth 8 -Compress) -Length 64
        RuntimeBinding=$Route.Binding
        ConfiguredSubnet=$network.Subnet
        Actual=[PSCustomObject]@{Name=$network.Name;Subnet=$actualSubnet;Id=$actual.Id}; Desired=[PSCustomObject]@{Name=$network.Name;Subnet=$target.Subnet}
        ManagedContainers=@($containers | Select-Object RunId,Name,WasRunning,Id,Aliases)
        Warnings=@('Das verwaltete Container-Netz wird mit kurzer SQL-Downtime neu erstellt. Fremde Container werden nicht verändert und können die Migration blockieren.')
    }
}

function Resolve-LabTemporaryContainerNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$DesiredNetwork
    )

    $knownSubnets = @((Get-LabKnownIpv4Subnets -Provider $Provider) + @($DesiredNetwork.Subnet))
    $providerOffset = if ($Provider -eq 'docker') { 0 } else { 256 }
    foreach ($index in 0..255) {
        $candidateSubnet = "198.$([int](18 + [math]::Floor(($providerOffset + $index) / 256))).$([int](($providerOffset + $index) % 256)).0/24"
        $candidate = [PSCustomObject]@{
            Provider=$Provider; Name=$Name; Subnet=$candidateSubnet; PrefixLength=24
            HostAddress=(ConvertFrom-LabIpv4UInt32 -Value ([uint32]((ConvertTo-LabIpv4Subnet -Subnet $candidateSubnet).Network + 1))).ToString()
            Intent='nat'; NatName=$null
        }
        try {
            Assert-LabRuntimeNetworkAvailable -Network $candidate -KnownSubnets $knownSubnets
            return $candidate
        }
        catch { }
    }
    throw "LAB_NETWORK_MIGRATION_NO_TEMPORARY_SUBNET: $Provider"
}

function Invoke-LabContainerNetworkMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$ExpectedPlanKey,
        [string]$TargetSubnet,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $name = "SqlServerLab.ContainerNetworkMigration.$Provider"
    if ($IsWindows) { $name = 'Global\' + $name }
    $migrationLock = [Threading.Mutex]::new($false,$name)
    $acquired = $false
    $testGroupLock = $null
    $groupsLock = $null
    $runLocks = [Collections.Generic.List[object]]::new()
    try {
        try { $acquired = $migrationLock.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true; throw 'LAB_NETWORK_MIGRATION_PREVIEW_CHANGED' }
        if (-not $acquired) { throw 'LAB_NETWORK_MIGRATION_BUSY' }
        $dataRoot = Get-LabDataRootDefault
        if ($dataRoot) { $testGroupLock = Enter-LabTestGroupLock -OutputDirectory (Join-Path $dataRoot 'Exports') }
        $groupsLock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
        $route = Get-LabContainerNetworkMigrationRoute -Provider $Provider -StateRoot $StateRoot
        $plan = New-LabContainerNetworkMigrationPlan -Provider $Provider -StateRoot $StateRoot -TargetSubnet $TargetSubnet -Route $route
        if ($plan.IsNoOp -or $plan.PlanKey -cne $ExpectedPlanKey) { throw 'LAB_NETWORK_MIGRATION_PREVIEW_CHANGED' }
        foreach ($runId in @($plan.ManagedContainers.RunId | Sort-Object -Unique)) {
            $runLocks.Add((Enter-LabEnvironmentGroupRunResourceLock -RunId $runId -StateRoot $StateRoot))
        }
        $members = @()
        $plan = New-LabContainerNetworkMigrationPlan -Provider $Provider -StateRoot $StateRoot -TargetSubnet $TargetSubnet -Route $route -MemberBindings ([ref]$members)
        if ($plan.IsNoOp -or $plan.PlanKey -cne $ExpectedPlanKey) { throw 'LAB_NETWORK_MIGRATION_PREVIEW_CHANGED' }
        if ((Get-LabRunArtifactRuntimeIncarnation -Context $route.Context -StateRoot $StateRoot -Invocation $route.Invocation) -cne $route.Incarnation) {
            throw 'LAB_NETWORK_MIGRATION_RUNTIME_UNVERIFIED'
        }
        Exit-LabEnvironmentGroupsLock -Mutex $groupsLock
        $groupsLock = $null
        Invoke-LabBoundContainerNetworkMigration -Route $route -Plan $plan -Members $members
    }
    finally {
        for ($index = $runLocks.Count - 1; $index -ge 0; $index--) {
            Exit-LabEnvironmentGroupRunResourceLock -Mutex $runLocks[$index]
        }
        if ($groupsLock) { Exit-LabEnvironmentGroupsLock -Mutex $groupsLock }
        if ($testGroupLock) { Exit-LabTestGroupLock -Mutex $testGroupLock }
        if ($acquired) { $migrationLock.ReleaseMutex() }
        $migrationLock.Dispose()
    }
}

function Invoke-LabContainerNetworkMigrationStep {
    param([hashtable]$Route, [string[]]$Arguments, [string]$FailureCode)

    $result = Invoke-LabRunArtifactPinnedProcess -Context $Route.Context -Invocation $Route.Invocation -Arguments $Arguments -TimeoutSeconds 90
    if ($result.ExitCode -ne 0) { throw $FailureCode }
    $result
}

function Get-LabCreatedContainerMigrationNetwork {
    param([hashtable]$Route, $Network, [string]$OperationId)

    $read = Invoke-LabContainerNetworkMigrationStep -Route $Route -Arguments @('network','inspect',$Network.Name) -FailureCode 'LAB_NETWORK_MIGRATION_CREATE_UNCONFIRMED'
    $rows = @(($read.Stdout -join [Environment]::NewLine) | ConvertFrom-Json -Depth 30 -ErrorAction Stop)
    if ($rows.Count -ne 1) { throw 'LAB_NETWORK_MIGRATION_CREATE_UNCONFIRMED' }
    $actual = $rows[0]
    $subnet = if ($Route.Provider -ceq 'docker') { [string]@($actual.IPAM.Config)[0].Subnet }
        else { [string](Get-LabPodmanNetworkContractFromInspect -Inspect $actual).Subnet }
    if ([string]$actual.Id -cnotmatch '^[a-f0-9]{64}$' -or [string]$actual.Name -cne $Network.Name -or
        [string]$actual.Labels.'sql-server-lab.network' -cne 'managed' -or
        [string]$actual.Labels.'sql-server-lab.migration-id' -cne $OperationId -or $subnet -cne $Network.Subnet) {
        throw 'LAB_NETWORK_MIGRATION_CREATE_UNCONFIRMED'
    }
    [pscustomobject]@{ Id=[string]$actual.Id; Name=[string]$actual.Name; Subnet=$subnet }
}

function Invoke-LabBoundContainerNetworkMigration {
    param([hashtable]$Route, $Plan, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Members)

    $provider = $Route.Provider
    $stateRoot = $Route.StateRoot
    $journalPath = Get-LabContainerNetworkMigrationJournalPath -StateRoot $StateRoot -Provider $Provider
    if (-not (Test-LabPathWithinRoot -Root $StateRoot -Path $journalPath).Valid) { throw 'LAB_NETWORK_MIGRATION_JOURNAL_PATH_UNSAFE' }
    $temporaryName = "$($plan.Actual.Name)-migration-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $temporaryNetwork = Resolve-LabTemporaryContainerNetwork -Provider $Provider -Name $temporaryName -DesiredNetwork $plan.Desired
    $journal = [PSCustomObject]@{ ContractVersion='SqlServerLab.ContainerNetworkMigrationJournal/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Provider=$Provider; RuntimeBinding=$Route.Binding; Status='PREPARED'; ConfiguredSubnet=$plan.ConfiguredSubnet; OldNetwork=$plan.Actual; NewNetwork=$plan.Desired; TemporaryNetwork=$temporaryNetwork; Containers=$Members; UpdatedAt=Get-LabTimestamp; Error=$null }
    $labels = @('--label','sql-server-lab.network=managed','--label',"sql-server-lab.migration-id=$($journal.OperationId)")
    Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
    $lastRecordedPhase = 'PREPARED'
    try {
        $temporaryCreate = @('network','create','--driver','bridge','--subnet',$temporaryNetwork.Subnet) + $labels + @($temporaryNetwork.Name)
        $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments $temporaryCreate -FailureCode 'LAB_NETWORK_MIGRATION_TEMPORARY_NETWORK_CREATE_FAILED'
        $journal.TemporaryNetwork = Get-LabCreatedContainerMigrationNetwork -Route $route -Network $temporaryNetwork -OperationId $journal.OperationId
        $journal.Status='TEMPORARY_NETWORK_READY';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        $lastRecordedPhase = 'TEMPORARY_NETWORK_READY'
        foreach ($container in $Members) {
            if ($container.WasRunning) {
                $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments @('stop',$container.Id) -FailureCode 'LAB_NETWORK_MIGRATION_STOP_FAILED'
            }
            $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments @('network','connect',$journal.TemporaryNetwork.Id,$container.Id) -FailureCode 'LAB_NETWORK_MIGRATION_CONNECT_FAILED'
            $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments @('network','disconnect',$plan.Actual.Id,$container.Id) -FailureCode 'LAB_NETWORK_MIGRATION_DISCONNECT_FAILED'
        }
        $journal.Status='MANAGED_CONTAINERS_DETACHED';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        $lastRecordedPhase = 'MANAGED_CONTAINERS_DETACHED'
        $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments @('network','rm',$plan.Actual.Id) -FailureCode 'LAB_NETWORK_MIGRATION_OLD_NETWORK_REMOVE_FAILED'
        $canonicalCreate = @('network','create','--driver','bridge','--subnet',$plan.Desired.Subnet) + $labels + @($plan.Desired.Name)
        $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments $canonicalCreate -FailureCode 'LAB_NETWORK_MIGRATION_CANONICAL_NETWORK_CREATE_FAILED'
        $journal.NewNetwork = Get-LabCreatedContainerMigrationNetwork -Route $route -Network $plan.Desired -OperationId $journal.OperationId
        $journal.Status='CANONICAL_NETWORK_READY';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        $lastRecordedPhase = 'CANONICAL_NETWORK_READY'
        foreach ($container in $Members) {
            $connect = @('network','connect')
            foreach ($alias in $container.Aliases) { $connect += @('--alias',$alias) }
            $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments ($connect + @($journal.NewNetwork.Id,$container.Id)) -FailureCode 'LAB_NETWORK_MIGRATION_RECONNECT_FAILED'
            $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments @('network','disconnect',$journal.TemporaryNetwork.Id,$container.Id) -FailureCode 'LAB_NETWORK_MIGRATION_TEMPORARY_DISCONNECT_FAILED'
            if ($container.WasRunning) {
                $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments @('start',$container.Id) -FailureCode 'LAB_NETWORK_MIGRATION_START_FAILED'
            }
        }
        $null = Invoke-LabContainerNetworkMigrationStep -Route $route -Arguments @('network','rm',$journal.TemporaryNetwork.Id) -FailureCode 'LAB_NETWORK_MIGRATION_TEMPORARY_NETWORK_REMOVE_FAILED'
        $observedNetwork = Get-LabCreatedContainerMigrationNetwork -Route $route -Network $plan.Desired -OperationId $journal.OperationId
        $observedMembers = @(Get-LabManagedContainersOnNetwork -Provider $Provider -NetworkName $observedNetwork.Name -StateRoot $StateRoot -Route $Route)
        if ($observedNetwork.Id -cne $journal.NewNetwork.Id -or $observedMembers.Count -ne $Members.Count) {
            throw 'LAB_NETWORK_MIGRATION_POSTCONDITION_UNCONFIRMED'
        }
        foreach ($container in $Members) {
            $observed = @($observedMembers | Where-Object Id -CEQ $container.Id)
            if ($observed.Count -ne 1 -or $observed[0].RunId -cne $container.RunId -or
                $observed[0].ScopeId -cne $container.ScopeId -or $observed[0].InstanceId -cne $container.InstanceId -or
                $observed[0].WasRunning -ne $container.WasRunning -or
                @($container.Aliases | Where-Object { $_ -cnotin $observed[0].Aliases }).Count) {
                throw 'LAB_NETWORK_MIGRATION_POSTCONDITION_UNCONFIRMED'
            }
        }
        $journal.Status='COMPLETED';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        return [PSCustomObject]@{Status='SUCCEEDED';Provider=$Provider;Changed=$true;MigratedContainers=$Members.Count;SqlReadiness='NOT_CHECKED';Plan=$plan}
    }
    catch {
        $journal | Add-Member -NotePropertyName LastRecordedPhase -NotePropertyValue $lastRecordedPhase
        $journal.Status='RECOVERY_REQUIRED'
        $journal.Error=if ($_.Exception.Message -cmatch '^LAB_NETWORK_MIGRATION_[A-Z_]+$') { $_.Exception.Message }
            else { 'LAB_NETWORK_MIGRATION_UNCONFIRMED' }
        $journal.UpdatedAt=Get-LabTimestamp
        Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        throw
    }
}
