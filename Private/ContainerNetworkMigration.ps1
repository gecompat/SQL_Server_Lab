function Get-LabContainerNetworkMigrationJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
    return (Join-Path (Join-Path $StateRoot 'catalog') "container-network-migration-$Provider.json")
}

function Get-LabManagedContainersOnNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [Parameter(Mandatory)][string]$NetworkName,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $runtime = Get-LabHostToolInvocation -Name $Provider
    $ids = @(& $runtime ps -a --no-trunc -q --filter "network=$NetworkName" 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_CONTAINER_LIST_FAILED: $Provider" }
    if (@($ids | Where-Object { $_ -cnotmatch '^[a-f0-9]{64}$' }).Count -or
        @($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw 'LAB_NETWORK_MIGRATION_MEMBERSHIP_INVALID' }
    if (-not $ids.Count) { return }
    $groups = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
    $cms = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
    $containers = @()
    foreach ($id in $ids) {
        $raw = @(& $runtime inspect $id 2>$null) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'LAB_NETWORK_MIGRATION_MEMBER_CHANGED' }
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
            (Test-LabAutomatedTestEnvironmentRun -RunId $runId) -or
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

function New-LabContainerNetworkMigrationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
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
    try {
        Assert-LabRuntimeNetworkAvailable -Network $actual -KnownSubnets (Get-LabKnownIpv4Subnets -Provider $Provider)
        return [PSCustomObject]@{ Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider; Status='NO_CONFLICT'; IsNoOp=$true; Actions=@(); Warnings=@() }
    }
    catch {
        if ($_.Exception.Message -notmatch '^LAB_NETWORK_SUBNET_CONFLICT:') { throw }
    }
    $blocker = $null
    $containers = @()
    $journal = Get-LabContainerNetworkMigrationJournalPath -StateRoot $StateRoot -Provider $Provider
    if ($actual.Id -cnotmatch '^[a-f0-9]{64}$' -or [string]$inspect.Name -cne $network.Name -or
        [string]$inspect.Labels.'sql-server-lab.network' -cne 'managed' -or
        [string]$inspect.Driver -cne 'bridge' -or [bool]$inspect.Internal) {
        $blocker = 'LAB_NETWORK_MIGRATION_UNVERIFIED_NETWORK'
    } elseif ((Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-required')) -or
        (Test-Path -LiteralPath (Join-Path $StateRoot 'owned-host-policy.json'))) {
        $blocker = 'LAB_NETWORK_MIGRATION_OWNED_HOST_BLOCKED'
    } elseif ((Test-Path -LiteralPath $journal) -and
        (Read-LabWorkflowJson -Path $journal).Status -cne 'COMPLETED') {
        $blocker = 'LAB_NETWORK_MIGRATION_PENDING_RECOVERY'
    } else {
        try { $containers = @(Get-LabManagedContainersOnNetwork -Provider $Provider -NetworkName $network.Name -StateRoot $StateRoot) }
        catch {
            if ($_.Exception.Message -cnotmatch '^LAB_NETWORK_MIGRATION_(UNVERIFIED_MEMBER|MEMBER_CHANGED|MEMBERSHIP_INVALID|PROTECTED_MEMBER|PENDING_RECOVERY|STATIC_ADDRESS)$') { throw }
            $blocker = $_.Exception.Message
        }
    }
    if ($blocker) {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}
            Provider=$Provider; Status='MIGRATION_BLOCKED'; IsNoOp=$true; Actions=@(); Warnings=@($blocker); Reason=$blocker
        }
    }
    $target = Resolve-LabAvailableContainerNetwork -Provider $Provider -Network $network
    $binding = [ordered]@{Root=[IO.Path]::GetFullPath($StateRoot);Provider=$Provider;NetworkId=$actual.Id;Name=$network.Name
        OldSubnet=$actualSubnet;NewSubnet=$target.Subnet;Members=@($containers | Select-Object Id,RunId,ScopeId,InstanceId,WasRunning,Aliases)}
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider
        Status='MIGRATION_REQUIRED'; IsNoOp=$false; Actions=@([PSCustomObject]@{Operation='MigrateManagedContainers';Provider=$Provider})
        PlanKey=Get-LabWorkflowHash -Text ($binding | ConvertTo-Json -Depth 8 -Compress) -Length 64
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
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $plan = New-LabContainerNetworkMigrationPlan -Provider $Provider -StateRoot $StateRoot
    if ($plan.IsNoOp -or $plan.PlanKey -cne $ExpectedPlanKey) { throw 'LAB_NETWORK_MIGRATION_PREVIEW_CHANGED' }
    $runtime = Get-LabHostToolInvocation -Name $Provider
    $journalPath = Get-LabContainerNetworkMigrationJournalPath -StateRoot $StateRoot -Provider $Provider
    $temporaryName = "$($plan.Actual.Name)-migration-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $temporaryNetwork = Resolve-LabTemporaryContainerNetwork -Provider $Provider -Name $temporaryName -DesiredNetwork $plan.Desired
    $journal = [PSCustomObject]@{ ContractVersion='SqlServerLab.ContainerNetworkMigrationJournal/1.0'; OperationId=[guid]::NewGuid().ToString('D'); Provider=$Provider; Status='PREPARED'; OldNetwork=$plan.Actual; NewNetwork=$plan.Desired; TemporaryNetwork=$temporaryNetwork; Containers=$plan.ManagedContainers; UpdatedAt=Get-LabTimestamp; Error=$null }
    Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
    try {
        $null = & $runtime network create --subnet $temporaryNetwork.Subnet --label sql-server-lab.network=managed $temporaryNetwork.Name
        if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_TEMPORARY_NETWORK_CREATE_FAILED: $Provider" }
        $journal.Status='TEMPORARY_NETWORK_READY';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        foreach ($container in @($plan.ManagedContainers)) {
            if ($container.WasRunning) { $null=& $runtime stop $container.Id; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_STOP_FAILED: $($container.Name)"} }
            $null=& $runtime network connect $temporaryNetwork.Name $container.Id; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_CONNECT_FAILED: $($container.Name)"}
            $null=& $runtime network disconnect $plan.Actual.Name $container.Id; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_DISCONNECT_FAILED: $($container.Name)"}
        }
        $journal.Status='MANAGED_CONTAINERS_DETACHED';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        $null=& $runtime network rm $plan.Actual.Id
        if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_OLD_NETWORK_REMOVE_FAILED: Fremde Container oder Runtime-Objekte verwenden $($plan.Actual.Name)." }
        $null=& $runtime network create --subnet $plan.Desired.Subnet --label sql-server-lab.network=managed $plan.Desired.Name
        if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_CANONICAL_NETWORK_CREATE_FAILED: $Provider" }
        foreach ($container in @($plan.ManagedContainers)) {
            $connect = @('network','connect')
            foreach ($alias in $container.Aliases) { $connect += @('--alias',$alias) }
            $null=& $runtime @connect $plan.Desired.Name $container.Id; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_RECONNECT_FAILED: $($container.Name)"}
            $null=& $runtime network disconnect $temporaryNetwork.Name $container.Id; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_TEMPORARY_DISCONNECT_FAILED: $($container.Name)"}
            if ($container.WasRunning) { $null=& $runtime start $container.Id; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_START_FAILED: $($container.Name)"} }
        }
        $null=& $runtime network rm $temporaryNetwork.Name
        if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_TEMPORARY_NETWORK_REMOVE_FAILED: $Provider" }
        $journal.Status='COMPLETED';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        return [PSCustomObject]@{Status='SUCCEEDED';Provider=$Provider;Changed=$true;MigratedContainers=@($plan.ManagedContainers).Count;Plan=$plan}
    }
    catch {
        $journal.Status='RECOVERY_REQUIRED';$journal.Error=$_.Exception.Message;$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        throw
    }
}
