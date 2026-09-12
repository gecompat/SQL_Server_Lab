function Get-LabContainerNetworkMigrationJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
    return (Join-Path (Join-Path $StateRoot 'catalog') "container-network-migration-$Provider.json")
}

function Get-LabManagedContainersOnNetwork {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider, [Parameter(Mandatory)][string]$NetworkName)

    $runtime = Get-LabHostToolInvocation -Name $Provider
    $ids = @(& $runtime ps -a -q --filter 'label=sql-server-lab.run-id' 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_CONTAINER_LIST_FAILED: $Provider" }
    $containers = @()
    foreach ($id in $ids) {
        $inspect = @(& $runtime inspect $id 2>$null | ConvertFrom-Json -Depth 50)[0]
        if (-not $inspect) { throw "LAB_NETWORK_MIGRATION_CONTAINER_INSPECT_FAILED: $Provider" }
        $labels = $inspect.Config.Labels
        if (-not $labels.'sql-server-lab.run-id' -or -not $labels.'sql-server-lab.scope-id') { continue }
        $networks = @($inspect.NetworkSettings.Networks.PSObject.Properties.Name)
        if ($NetworkName -notin $networks) { continue }
        $containers += [PSCustomObject]@{
            Id=[string]$inspect.Id; Name=([string]$inspect.Name).TrimStart('/'); RunId=[string]$labels.'sql-server-lab.run-id'
            ScopeId=[string]$labels.'sql-server-lab.scope-id'; WasRunning=[bool]$inspect.State.Running
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
    $inspect = @(& $runtime network inspect $network.Name 2>$null | ConvertFrom-Json -Depth 50)[0]
    if (-not $inspect) { return [PSCustomObject]@{ Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider; Status='NO_NETWORK'; IsNoOp=$true; Actions=@(); Warnings=@() } }
    $actualSubnet = if ($Provider -eq 'docker') { [string]@($inspect.IPAM.Config)[0].Subnet } else { [string](Get-LabPodmanNetworkContractFromInspect -Inspect $inspect).Subnet }
    $actual = [PSCustomObject]@{ Provider=$Provider; Name=$network.Name; Subnet=$actualSubnet; Intent='nat'; NatName=$null }
    try {
        Assert-LabRuntimeNetworkAvailable -Network $actual -KnownSubnets (Get-LabKnownIpv4Subnets -Provider $Provider)
        return [PSCustomObject]@{ Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider; Status='NO_CONFLICT'; IsNoOp=$true; Actions=@(); Warnings=@() }
    }
    catch {
        if ($_.Exception.Message -notmatch '^LAB_NETWORK_SUBNET_CONFLICT:') { throw }
    }
    $target = Resolve-LabAvailableContainerNetwork -Provider $Provider -Network $network
    $containers = @(Get-LabManagedContainersOnNetwork -Provider $Provider -NetworkName $network.Name)
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.ContainerNetworkMigrationPlan';Version='1.0'}; Provider=$Provider
        Status='MIGRATION_REQUIRED'; IsNoOp=$false; Actions=@([PSCustomObject]@{Operation='MigrateManagedContainers';Provider=$Provider})
        Actual=[PSCustomObject]@{Name=$network.Name;Subnet=$actualSubnet}; Desired=[PSCustomObject]@{Name=$network.Name;Subnet=$target.Subnet}
        ManagedContainers=@($containers | ForEach-Object { [PSCustomObject]@{RunId=$_.RunId;Name=$_.Name;WasRunning=$_.WasRunning} })
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
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $plan = New-LabContainerNetworkMigrationPlan -Provider $Provider -StateRoot $StateRoot
    if ($plan.IsNoOp) { return [PSCustomObject]@{Status=$plan.Status;Provider=$Provider;Changed=$false;Plan=$plan} }
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
            if ($container.WasRunning) { $null=& $runtime stop $container.Name; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_STOP_FAILED: $($container.Name)"} }
            $null=& $runtime network connect $temporaryNetwork.Name $container.Name; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_CONNECT_FAILED: $($container.Name)"}
            $null=& $runtime network disconnect $plan.Actual.Name $container.Name; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_DISCONNECT_FAILED: $($container.Name)"}
        }
        $journal.Status='MANAGED_CONTAINERS_DETACHED';$journal.UpdatedAt=Get-LabTimestamp;Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        $null=& $runtime network rm $plan.Actual.Name
        if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_OLD_NETWORK_REMOVE_FAILED: Fremde Container oder Runtime-Objekte verwenden $($plan.Actual.Name)." }
        $null=& $runtime network create --subnet $plan.Desired.Subnet --label sql-server-lab.network=managed $plan.Desired.Name
        if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_MIGRATION_CANONICAL_NETWORK_CREATE_FAILED: $Provider" }
        foreach ($container in @($plan.ManagedContainers)) {
            $null=& $runtime network connect $plan.Desired.Name $container.Name; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_RECONNECT_FAILED: $($container.Name)"}
            $null=& $runtime network disconnect $temporaryNetwork.Name $container.Name; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_TEMPORARY_DISCONNECT_FAILED: $($container.Name)"}
            if ($container.WasRunning) { $null=& $runtime start $container.Name; if($LASTEXITCODE -ne 0){throw "LAB_NETWORK_MIGRATION_START_FAILED: $($container.Name)"} }
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
