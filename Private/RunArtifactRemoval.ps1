# Run metadata removal is deliberately separate from provider cleanup. No native
# resource is deleted here. Missing or ambiguous evidence never authorizes purge.
function Get-LabRunArtifactRuntimeContext {
    param([string]$Provider,[string]$StateRoot)
    $discovered=Get-LabRetainedStoreRuntimeContext -Provider $Provider -StateRoot $StateRoot
    $machineName=$null; $identity=''; $identityHash=''
    if ($discovered.PSObject.Properties['StateRoot']) {
        $policy=Get-LabOwnedHostPolicy -StateRoot $StateRoot -Required
        $pins=@($policy.RuntimePins | Where-Object Provider -CEQ $Provider)
        if ($pins.Count -ne 1) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $endpoint=$pins[0].Endpoint; $identity=$pins[0].IdentityPath; $identityHash=$pins[0].IdentitySha256
    }
    elseif ($Provider -ceq 'docker') {
        $native=Invoke-LabRetainedStoreNative -Provider docker -Arguments @('context','inspect',$discovered.Arguments[1])
        if ($native.ExitCode -ne 0) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $documents=@(($native.Output -join "`n") | ConvertFrom-Json -Depth 40 -ErrorAction Stop)
        if ($documents.Count -ne 1) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $endpoint=[string]$documents[0].Endpoints.docker.Host
        if ($endpoint -cnotmatch '^(npipe|unix)://') { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
    }
    else {
        $native=Invoke-LabRetainedStoreNative -Provider podman -Arguments @('system','connection','list','--format','json')
        if ($native.ExitCode -ne 0) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $connections=@(($native.Output -join "`n") | ConvertFrom-Json -Depth 40 -ErrorAction Stop | Where-Object Name -CEQ $discovered.Arguments[1])
        if ($connections.Count -ne 1 -or -not $connections[0].IsMachine) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $endpoint=[string]$connections[0].URI
        if ($endpoint -cnotmatch '^ssh://[^/@]+@(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/') { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $identity=Assert-LabRunArtifactPath ([string]$connections[0].Identity)
        $identityHash=(Get-FileHash -LiteralPath $identity -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $native=Invoke-LabRetainedStoreNative -Provider podman -Arguments @('machine','list','--format','json')
        if ($native.ExitCode -ne 0) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $machines=@(($native.Output -join "`n") | ConvertFrom-Json -Depth 40 -ErrorAction Stop | Where-Object { $connections[0].Name -cin @($_.Name,($_.Name+'-root')) })
        if ($machines.Count -ne 1) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $machineName=$machines[0].Name
    }
    [pscustomobject]@{Provider=$Provider;RuntimeScopeId=$discovered.RuntimeScopeId;Endpoint=$endpoint;
        IdentityPath=$identity;IdentitySha256=$identityHash;MachineName=$machineName;
        RoutingKey=(Get-LabRetainedStoreHash @($Provider,$endpoint,$identityHash));
        StateRoot=if ($discovered.PSObject.Properties['StateRoot']) {$StateRoot} else {$null}}
}

function Invoke-LabRunArtifactPinnedProcess {
    param($Context,[string[]]$Arguments,[int]$TimeoutSeconds=20)
    if ($Context.IdentityPath) {
        $null=Assert-LabRunArtifactPath $Context.IdentityPath
        if ((Get-FileHash -LiteralPath $Context.IdentityPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $Context.IdentitySha256) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
    }
    if ($Context.StateRoot) {
        $native=Invoke-LabOwnedHostPinnedCommand -StateRoot $Context.StateRoot -Provider $Context.Provider -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    }
    else {
        $start=[Diagnostics.ProcessStartInfo]::new((Get-LabHostToolInvocation -Name $Context.Provider))
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach ($name in @('DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH',
            'CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY','PODMAN_SSHKEY','PODMAN_CONNECTIONS_CONF','SSH_AUTH_SOCK','SSH_AGENT_PID')) { $null=$start.Environment.Remove($name) }
        $prefix=if ($Context.Provider -ceq 'docker') {@('--host',$Context.Endpoint)} else {@('--remote','--url',$Context.Endpoint,'--identity',$Context.IdentityPath)}
        foreach ($argument in @($prefix)+$Arguments) { $start.ArgumentList.Add($argument) }
        $native=Invoke-LabOwnedHostNativeProcess -StartInfo $start -TimeoutSeconds $TimeoutSeconds
    }
    $native
}

function Invoke-LabRunArtifactNative {
    param($Context,[string[]]$Arguments)
    $native=Invoke-LabRunArtifactPinnedProcess -Context $Context -Arguments $Arguments
    if ($native.Stderr -match '\S') { throw 'RUN_ARTIFACT_RUNTIME_UNVERIFIABLE' }
    [pscustomobject]@{ExitCode=$native.ExitCode;Output=@($native.Stdout -split '\r?\n' | Where-Object {$_})}
}

function New-LabRunArtifactCreationBinding {
    param([string[]]$Provider,[string]$StateRoot)
    $contexts=@{}; $records=@(foreach ($name in @($Provider | Sort-Object -Unique)) {
        try {
            $context=Get-LabRunArtifactRuntimeContext -Provider $name -StateRoot $StateRoot
            $incarnation=Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $StateRoot
            # The creation bridge only supports a fixed non-owned endpoint.
            # Owned-host has its independent custody contract and is protected.
            if ($context.StateRoot) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
            $contexts[$name]=$context
            [pscustomobject]@{Provider=$name;Status='AVAILABLE';OriginStatus='PINNED_CREATION';RuntimeScopeId=$context.RuntimeScopeId;RoutingKey=$context.RoutingKey;IncarnationKey=$incarnation}
        }
        catch { [pscustomobject]@{Provider=$name;Status='UNAVAILABLE';OriginStatus='UNVERIFIABLE'} }
    })
    [pscustomobject]@{Contexts=$contexts;Records=$records;StateRoot=$StateRoot}
}

function Get-LabRunArtifactRuntimeIncarnation {
    param($Context,[string]$StateRoot)
    if ($Context.Provider -ceq 'docker') {
        $native=Invoke-LabRunArtifactNative -Context $Context -Arguments @('info','--format','{{json .ID}}')
        if ($native.ExitCode -ne 0) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        $identity=($native.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$identity)) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
        return Get-LabRetainedStoreHash @('docker',$identity)
    }
    # Remote/non-machine Podman contexts need their own durable incarnation
    # contract. A context name or endpoint alone cannot authorize removal.
    if (-not $Context.MachineName) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
    $native=Invoke-LabRunArtifactNative -Context $Context -Arguments @('machine','inspect',$Context.MachineName)
    if ($native.ExitCode -ne 0) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
    $machines=@(($native.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop)
    if ($machines.Count -ne 1 -or -not $machines[0].Created -or $machines[0].Name -cne $Context.MachineName) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
    Get-LabRetainedStoreHash @('podman',$machines[0].Name,$machines[0].Created,$machines[0].ConfigDir)
}

function Assert-LabRunArtifactPath {
    param([Parameter(Mandatory)][string]$Path)
    $pathValue=[IO.Path]::GetFullPath($Path)
    $ancestor=$pathValue
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item=Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'RUN_ARTIFACT_REPARSE_PATH' }
        }
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    $pathValue
}

function Get-LabRunArtifactTree {
    param([Parameter(Mandatory)][string]$Root)
    $rootValue=Assert-LabRunArtifactPath $Root
    if (-not (Test-Path -LiteralPath $rootValue)) { return @() }
    $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($rootValue)
    $items=[Collections.Generic.List[object]]::new()
    while ($queue.Count) {
        $directory=$queue.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($items.Count -ge 8192) { throw 'RUN_ARTIFACT_INVENTORY_LIMIT' }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'RUN_ARTIFACT_REPARSE_PATH' }
            $items.Add($item)
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
        }
    }
    @($items)
}

function Get-LabRunArtifactManifest {
    param([string]$Directory)
    $tree=@(Get-LabRunArtifactTree $Directory | Sort-Object FullName)
    foreach ($item in @($tree | Where-Object {-not $_.PSIsContainer -and $_.Extension -ieq '.json'})) {
        if ($item.Length -gt 16MB) { throw 'RUN_ARTIFACT_INVENTORY_LIMIT' }
        $document=Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ($document.cleanupStatus -cin @('RECOVERY_REQUIRED','FAILED','PENDING') -or
            ($item.Name -match 'journal|diagnostic' -and $document.Status -cnotin @('COMPLETED','ROLLED_BACK'))) { throw 'RUN_ARTIFACT_RECOVERY_REQUIRED' }
    }
    $allowed=@('run-state.json','cleanup-plan.json','connection-info.json','manifest.lock.json',
        'hyperv-resource-binding.local.json','network-bound-plan.json','storage-bound-plan.json',
        'storage-runtime-receipt.json','windows-activation-network.json','windows-locale-receipt.json',
        'software-installation-receipts.json','container-reconcile-journal.json')
    $entries=@(foreach ($item in $tree) {
        $relative=[IO.Path]::GetRelativePath($Directory,$item.FullName).Replace('\','/')
        if (($item.PSIsContainer -and $relative -cne 'log') -or
            (-not $item.PSIsContainer -and $relative -cnotin $allowed -and $relative -cne 'log/provider.log')) { throw 'RUN_ARTIFACT_UNKNOWN_PAYLOAD' }
        if (-not $item.PSIsContainer -and $item.Length -gt 16MB) { throw 'RUN_ARTIFACT_INVENTORY_LIMIT' }
        [pscustomobject]@{Name=[IO.Path]::GetRelativePath($Directory,$item.FullName); Directory=[bool]$item.PSIsContainer;
            Sha256=if ($item.PSIsContainer) {$null} else {(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}}
    })
    $entries
}

function Get-LabRunArtifactReferences {
    param($Configuration,[string]$StateRoot,[string]$RunId,[string]$ScopeId,[string[]]$Exclude)
    $evidence=[Collections.Generic.List[object]]::new()
    foreach ($location in @($Configuration.LabDataLocations | Sort-Object LocationId)) {
        if (-not (Test-LabDataRootOwnership -DataRoot $location.LabDataRoot -ControllerId $Configuration.ControllerId)) { throw 'RUN_ARTIFACT_LOCATION_UNVERIFIABLE' }
        $registry=Get-LabTestEnvironmentRegistry -OutputDirectory (Join-Path $location.LabDataRoot 'Exports')
        if ($registry.environments -isnot [array]) { throw 'RUN_ARTIFACT_REGISTRY_UNVERIFIABLE' }
        if (@($registry.environments | Where-Object runId -EQ $RunId).Count) { throw 'RUN_ARTIFACT_PROTECTED_GROUP' }
    }
    $catalog=Get-LabPersistentStorageCatalog -Configuration $Configuration
    if ($catalog.Status -cnotin @('AVAILABLE','EMPTY')) { throw 'RUN_ARTIFACT_CATALOG_UNVERIFIABLE' }
    $roots=@($StateRoot)+@($Configuration.LabDataLocations | ForEach-Object LabDataRoot)
    $seen=@{}
    foreach ($root in @($roots | Sort-Object -Unique)) {
        foreach ($item in @(Get-LabRunArtifactTree $root)) {
            if ($item.PSIsContainer -or $item.Extension -ine '.json' -or $seen.ContainsKey($item.FullName)) { continue }
            $seen[$item.FullName]=$true
            $excluded=$false
            foreach ($boundary in $Exclude) {
                if ($item.FullName -eq $boundary -or $item.FullName.StartsWith($boundary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { $excluded=$true; break }
            }
            if ($excluded) { continue }
            if ($item.Length -gt 16MB -or $seen.Count -gt 8192) { throw 'RUN_ARTIFACT_REFERENCE_LIMIT' }
            $raw=Get-Content -LiteralPath $item.FullName -Raw -Encoding utf8 -ErrorAction Stop
            # Parse too: corrupt registries/journals are not evidence of absence.
            $null=$raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
            if ($raw.IndexOf($RunId,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $raw.IndexOf($ScopeId,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'RUN_ARTIFACT_REFERENCED_OR_RETAINED' }
            $evidence.Add(@($item.FullName,(Get-FileHash -LiteralPath $item.FullName).Hash))
        }
    }
    Get-LabRetainedStoreHash @($evidence)
}

function Get-LabRunArtifactRuntimeEvidence {
    param($Binding,[string]$StateRoot,[string]$DataRoot)
    $result=@()
    foreach ($provider in @($Binding.Providers)) {
        if ($provider -cin @('docker','podman')) {
            $context=Get-LabRunArtifactRuntimeContext -Provider $provider -StateRoot $StateRoot
            $incarnation=Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $StateRoot
            foreach ($kind in @('container','volume','network')) {
                $recorded=@($Binding.RuntimeScopes | Where-Object Provider -CEQ $provider)
                if ($recorded.Count -ne 1 -or $recorded[0].Status -cne 'AVAILABLE' -or $recorded[0].OriginStatus -cne 'PINNED_CREATION' -or $recorded[0].RuntimeScopeId -cne $context.RuntimeScopeId -or $recorded[0].IncarnationKey -cne $incarnation -or $recorded[0].RoutingKey -cne $context.RoutingKey) { throw 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' }
                $args=if ($kind -ceq 'container') {@('ps','-a','--no-trunc','--format','{{.Names}}')} else {@($kind,'ls','--format','{{.Name}}')}
                $listing=Invoke-LabRunArtifactNative -Context $context -Arguments $args
                if ($listing.ExitCode -ne 0) { throw 'RUN_ARTIFACT_RUNTIME_UNVERIFIABLE' }
                $names=@($listing.Output | ForEach-Object {$_.Trim()} | Where-Object {$_})
                foreach ($resource in @($Binding.Resources | Where-Object { $_.provider -ceq $provider -and $_.resourceType -ceq $kind })) {
                    if ($resource.resourceId -cin $names) { throw 'RUN_ARTIFACT_RESOURCE_PRESENT' }
                }
                if ($kind -ceq 'container') {
                    $ids=Invoke-LabRunArtifactNative -Context $context -Arguments @('ps','-a','--no-trunc','--format','{{.ID}}')
                    if ($ids.ExitCode -ne 0) { throw 'RUN_ARTIFACT_RUNTIME_UNVERIFIABLE' }
                    foreach ($instance in @($Binding.Instances | Where-Object provider -CEQ $provider)) {
                        if ($instance.containerId -and $instance.containerId -cin @($ids.Output | ForEach-Object {$_.Trim()})) { throw 'RUN_ARTIFACT_RESOURCE_PRESENT' }
                    }
                }
                foreach ($label in @("sql-server-lab.run-id=$($Binding.RunId)","sql-server-lab.scope-id=$($Binding.ScopeId)")) {
                    $scoped=Invoke-LabRunArtifactNative -Context $context -Arguments ($args+@('--filter',"label=$label"))
                    if ($scoped.ExitCode -ne 0) { throw 'RUN_ARTIFACT_RUNTIME_UNVERIFIABLE' }
                    if (@($scoped.Output | Where-Object {$_ -match '\S'}).Count) { throw 'RUN_ARTIFACT_RESOURCE_PRESENT' }
                }
            }
            $again=Get-LabRunArtifactRuntimeContext -Provider $provider -StateRoot $StateRoot
            if ($again.RuntimeScopeId -cne $context.RuntimeScopeId -or $again.RoutingKey -cne $context.RoutingKey -or (Get-LabRunArtifactRuntimeIncarnation -Context $context -StateRoot $StateRoot) -cne $incarnation) { throw 'RUN_ARTIFACT_RUNTIME_CHANGED' }
            $result+=@($provider,$context.RuntimeScopeId,$incarnation)
        }
        elseif ($provider -ceq 'hyperv') {
            # Path-based cleanup cannot prove that a VHDX was deleted rather
            # than relocated. Preserve its recovery evidence until that
            # provider has a durable physical absence contract.
            throw 'RUN_ARTIFACT_HYPERV_ABSENCE_UNVERIFIABLE'
        }
        else { throw 'RUN_ARTIFACT_PROVIDER_UNSUPPORTED' }
    }
    Get-LabRetainedStoreHash $result
}

function Get-LabRunArtifactRemovalContext {
    param([string]$RunId,[string]$StateRoot,[string]$DataRoot)
    $stateRootValue=Assert-LabRunArtifactPath (Get-LabStateRoot -ExplicitPath $StateRoot)
    Assert-LabWindowsPoolRootSupport -StateRoot $stateRootValue
    $dataRootValue=Assert-LabRunArtifactPath (Resolve-LabDataRootForUse -DataRoot $DataRoot)
    $configuration=Get-LabStorageConfiguration -DataRoot $dataRootValue
    if (-not $configuration.ControllerId -or -not @($configuration.LabDataLocations).Count -or
        -not (Test-LabDataRootOwnership -DataRoot $dataRootValue -ControllerId $configuration.ControllerId)) { throw 'RUN_ARTIFACT_CONTROLLER_REQUIRED' }
    if (-not @($configuration.LabDataLocations | Where-Object { [IO.Path]::GetFullPath((Join-Path $_.LabDataRoot 'State')) -eq $stateRootValue }).Count) { throw 'RUN_ARTIFACT_REGISTERED_STATE_REQUIRED' }
    $locations=@($configuration.LabDataLocations | Sort-Object LocationId | Select-Object LocationId,LabDataRoot,VolumeId)
    foreach ($location in $locations) {
        $null=Assert-LabRunArtifactPath $location.LabDataRoot
        $marker=Get-LabDataRootMarker -DataRoot $location.LabDataRoot
        $volume=Get-LabVolumeIdentity -Path $location.LabDataRoot
        if (-not $marker -or $marker.VolumeId -cne $volume.VolumeId -or $location.VolumeId -cne $volume.VolumeId) { throw 'RUN_ARTIFACT_LOCATION_UNVERIFIABLE' }
    }
    $runDirectory=Join-Path (Join-Path $stateRootValue 'runs') $RunId
    $ledgerRoot=Join-Path $stateRootValue 'run-artifact-removals'
    $operationDirectory=Join-Path $ledgerRoot $RunId
    $journalPath=Join-Path $operationDirectory 'journal.json'
    $payload=Join-Path $operationDirectory 'payload'
    foreach ($path in @($runDirectory,$operationDirectory,$journalPath,$payload)) { $null=Assert-LabRunArtifactPath $path }
    $journal=$null
    if (Test-Path -LiteralPath $journalPath) {
        $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ($journal.ContractVersion -cne 'SqlServerLab.RunArtifactRemoval/1.0' -or $journal.RunId -cne $RunId -or
            $journal.ControllerId -cne $configuration.ControllerId -or $journal.StateRoot -cne $stateRootValue -or
            $journal.DataRoot -cne $dataRootValue -or $journal.PlanKey -cne (Get-LabRetainedStoreHash $journal.Authorization)) { throw 'RUN_ARTIFACT_JOURNAL_INVALID' }
        if ((Get-LabRetainedStoreHash $locations) -cne (Get-LabRetainedStoreHash $journal.Authorization.Locations)) { throw 'RUN_ARTIFACT_LOCATIONS_CHANGED' }
        if ($journal.Status -ceq 'REMOVED') {
            $removedMarker=Join-Path (Join-Path $stateRootValue 'scope-markers') ($journal.Authorization.Binding.ScopeId+'.json')
            if ((Test-Path -LiteralPath $runDirectory) -or (Test-Path -LiteralPath $payload) -or (Test-Path -LiteralPath $removedMarker)) { throw 'RUN_ARTIFACT_TOMBSTONE_CONFLICT' }
            return [pscustomobject]@{Status='REMOVED';RunId=$RunId;PlanKey=$journal.PlanKey;CanApply=$false;FileCount=0}
        }
        if ($journal.Status -cnotin @('PREPARED','DELETING','RECOVERY_REQUIRED')) { throw 'RUN_ARTIFACT_JOURNAL_INVALID' }
        $authorization=$journal.Authorization
        $binding=$authorization.Binding
        if ($binding.RunId -cne $RunId -or $binding.ScopeId -cnotmatch '^[0-9a-f-]{36}$') { throw 'RUN_ARTIFACT_JOURNAL_INVALID' }
        if ((Test-Path -LiteralPath $runDirectory) -and (Test-Path -LiteralPath $payload)) { throw 'RUN_ARTIFACT_STAGE_CONFLICT' }
        $directory=if (Test-Path -LiteralPath $runDirectory) {$runDirectory} else {$payload}
        $current=@(Get-LabRunArtifactManifest $directory)
        foreach ($entry in $current) {
            $original=@($authorization.Manifest | Where-Object Name -CEQ $entry.Name)
            if ($original.Count -ne 1 -or $original[0].Directory -ne $entry.Directory -or $original[0].Sha256 -cne $entry.Sha256) { throw 'RUN_ARTIFACT_CONTENT_CHANGED' }
        }
        if (Test-Path -LiteralPath $runDirectory) {
            if ((Get-LabRetainedStoreHash $current) -cne (Get-LabRetainedStoreHash $authorization.Manifest)) { throw 'RUN_ARTIFACT_CONTENT_CHANGED' }
        }
    }
    else {
        if (Test-Path -LiteralPath $operationDirectory) { throw 'RUN_ARTIFACT_UNJOURNALED_STAGE' }
        $directory=$runDirectory
        $manifest=@(Get-LabRunArtifactManifest $directory)
        $state=Get-LabRunState -RunId $RunId -StateRoot $stateRootValue
        if ($state.contractVersion -cne 'SqlServerLab.RunState/1.0' -or $state.runId -cne $RunId -or
            $state.scopeId -cnotmatch '^[0-9a-f-]{36}$' -or $state.state -cne 'REMOVED') { throw 'RUN_ARTIFACT_REMOVED_STATE_REQUIRED' }
        $retainedDrives=@($state.metadata.desiredState.Instances.Drives | Where-Object { $_ -and ($_.Binding -ceq 'host-mount' -or $_.Persistence -cnotin @('run-scoped','run-scoped-runtime-volume')) })
        if ($state.metadata.persistentData -or $state.metadata.ownedHostIntegration -or $retainedDrives.Count -or $state.metadata.windowsPool -or $state.metadata.windowsPoolMember -or
            $state.metadata.automatedTestEnvironment -or $state.metadata.testGroupId -or $state.metadata.workflowOperationId -or
            @($state.providerSubRuns | Where-Object { $_.state -cnotin @('REMOVED','CLEANED_UP') }).Count) { throw 'RUN_ARTIFACT_RETAINED_OR_PROTECTED' }
        $cleanup=Get-Content -LiteralPath (Join-Path $directory 'cleanup-plan.json') -Raw | ConvertFrom-Json -Depth 100
        if ($cleanup.runId -cne $RunId -or $cleanup.scopeId -cne $state.scopeId -or $cleanup.status -cne 'COMPLETED' -or
            @($cleanup.steps | Where-Object state -CNE 'COMPLETED').Count) { throw 'RUN_ARTIFACT_CLEANUP_INCOMPLETE' }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*journal*.json' -File)) {
            $document=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100
            if ($document.Status -cnotin @('COMPLETED','ROLLED_BACK')) { throw 'RUN_ARTIFACT_RECOVERY_REQUIRED' }
        }
        $providers=@($cleanup.steps | ForEach-Object provider | Where-Object {$_} | Sort-Object -Unique)
        if (-not $providers.Count -or @($cleanup.steps | Where-Object { $_.action -cne 'remove' -or $_.provider -cnotin @('docker','podman','hyperv') }).Count) { throw 'RUN_ARTIFACT_RESOURCE_UNSUPPORTED' }
        foreach ($step in @($cleanup.steps)) {
            if (($step.provider -cin @('docker','podman') -and $step.resourceType -cnotin @('container','volume','network')) -or
                ($step.provider -ceq 'hyperv' -and $step.resourceType -cnotin @('vm','vhdx','ipam-lease'))) { throw 'RUN_ARTIFACT_RESOURCE_UNSUPPORTED' }
        }
        $binding=[pscustomobject]@{RunId=$RunId;ScopeId=$state.scopeId;Providers=$providers;Resources=@($cleanup.steps | Select-Object provider,resourceType,resourceId);
            Instances=if (Test-Path -LiteralPath (Join-Path $directory 'connection-info.json')) {@((Get-Content -LiteralPath (Join-Path $directory 'connection-info.json') -Raw | ConvertFrom-Json -Depth 100).instances | Select-Object provider,containerId,vmId)} else {@()};
            RuntimeScopes=@($state.metadata.artifactRemovalRuntimeScopes)}
        $authorization=[pscustomobject]@{ControllerId=$configuration.ControllerId;StateRoot=$stateRootValue;DataRoot=$dataRootValue;Locations=$locations;Binding=$binding;Manifest=$manifest}
    }
    $markerPath=Join-Path (Join-Path $stateRootValue 'scope-markers') ($binding.ScopeId+'.json')
    $null=Assert-LabRunArtifactPath $markerPath
    if (Test-Path -LiteralPath $markerPath) {
        $marker=Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($marker.runId -cne $RunId -or $marker.scopeId -cne $binding.ScopeId) { throw 'RUN_ARTIFACT_SCOPE_MARKER_CHANGED' }
        $markerHash=(Get-FileHash -LiteralPath $markerPath).Hash
        if ($journal -and $markerHash -cne $authorization.MarkerHash) { throw 'RUN_ARTIFACT_SCOPE_MARKER_CHANGED' }
    }
    elseif (-not $journal) { throw 'RUN_ARTIFACT_SCOPE_MARKER_REQUIRED' }
    if (-not $journal) { $authorization | Add-Member MarkerHash $markerHash }
    $runtime=Get-LabRunArtifactRuntimeEvidence -Binding $binding -StateRoot $stateRootValue -DataRoot $dataRootValue
    $references=Get-LabRunArtifactReferences -Configuration $configuration -StateRoot $stateRootValue -RunId $RunId -ScopeId $binding.ScopeId -Exclude @($runDirectory,$operationDirectory,$markerPath)
    if (-not $journal) { $authorization | Add-Member RuntimeKey $runtime; $authorization | Add-Member ReferenceKey $references }
    elseif ($runtime -cne $authorization.RuntimeKey) { throw 'RUN_ARTIFACT_RUNTIME_CHANGED' }
    $key=Get-LabRetainedStoreHash $authorization
    # Rehash after potentially long native/reference reads.
    $last=@(Get-LabRunArtifactManifest $directory)
    $expected=@(if ($journal) {$current} else {$manifest})
    if ((Get-LabRetainedStoreHash $last) -cne (Get-LabRetainedStoreHash $expected)) { throw 'RUN_ARTIFACT_CONTENT_CHANGED' }
    [pscustomobject]@{RunId=$RunId;Status=if ($journal) {'RECOVERY_REQUIRED'} else {'READY'};CanApply=$true;PlanKey=$key;
        FileCount=@($last | Where-Object {-not $_.Directory}).Count;Configuration=$configuration;Authorization=$authorization;
        Directory=$directory;RunDirectory=$runDirectory;OperationDirectory=$operationDirectory;JournalPath=$journalPath;Payload=$payload;
        MarkerPath=$markerPath;Journal=$journal;ReferenceKey=$references;StateRoot=$stateRootValue;DataRoot=$dataRootValue}
}

function Invoke-LabRunArtifactLibraryLocks {
    param([string[]]$Roots,[int]$Index=0,[scriptblock]$Body)
    if ($Index -ge $Roots.Count) { return & $Body }
    Invoke-LabBackupLibraryLock -LibraryRoot (Join-Path $Roots[$Index] 'Backups') -ScriptBlock {
        Invoke-LabDatabasePackageLock -LibraryRoot (Join-Path $Roots[$Index] 'DatabasePackages') -ScriptBlock {
            Invoke-LabRunArtifactLibraryLocks -Roots $Roots -Index ($Index+1) -Body $Body
        }
    }
}

function Invoke-LabRunArtifactRemoval {
    param([string]$RunId,[string]$StateRoot,[string]$DataRoot,[string]$ExpectedPlanKey)
    $initial=Get-LabRunArtifactRemovalContext -RunId $RunId -StateRoot $StateRoot -DataRoot $DataRoot
    if ($initial.PlanKey -cne $ExpectedPlanKey) { throw 'RUN_ARTIFACT_PREVIEW_STALE' }
    if ($initial.Status -ceq 'REMOVED') { return [pscustomobject]@{RunId=$RunId;Status='REMOVED';Changed=$false} }
    $locks=[Collections.Generic.List[object]]::new()
    try {
        foreach ($location in @($initial.Configuration.LabDataLocations | Sort-Object LabDataRoot)) {
            $locks.Add((Enter-LabTestGroupLock -OutputDirectory (Join-Path $location.LabDataRoot 'Exports')))
        }
        Invoke-LabRunArtifactLibraryLocks -Roots @($initial.Configuration.LabDataLocations | Sort-Object LabDataRoot | ForEach-Object LabDataRoot) -Body {
        Invoke-LabArtifactStoreLock -StateRoot $initial.StateRoot -ScriptBlock {
        Invoke-LabPersistentStorageCatalogLock -ControllerId $initial.Configuration.ControllerId -ScriptBlock {
        Invoke-WithLabWindowsPoolLock -StateRoot $initial.StateRoot -Body {
        $fresh=Get-LabRunArtifactRemovalContext -RunId $RunId -StateRoot $StateRoot -DataRoot $DataRoot
        if ($fresh.PlanKey -cne $ExpectedPlanKey -or $fresh.ReferenceKey -cne $initial.ReferenceKey) { throw 'RUN_ARTIFACT_PREVIEW_STALE' }
        if (-not $fresh.Journal) {
            $null=New-Item -Path $fresh.OperationDirectory -ItemType Directory
            $fresh.Journal=[pscustomobject]@{ContractVersion='SqlServerLab.RunArtifactRemoval/1.0';RunId=$RunId;ControllerId=$fresh.Configuration.ControllerId;
                StateRoot=$fresh.StateRoot;DataRoot=$fresh.DataRoot;Authorization=$fresh.Authorization;PlanKey=$fresh.PlanKey;Status='PREPARED'}
            Write-LabArtifactJsonAtomic -Path $fresh.JournalPath -InputObject $fresh.Journal
        }
        try {
            if (Test-Path -LiteralPath $fresh.RunDirectory) { [IO.Directory]::Move($fresh.RunDirectory,$fresh.Payload) }
            $fresh.Journal.Status='DELETING'; Write-LabArtifactJsonAtomic -Path $fresh.JournalPath -InputObject $fresh.Journal
            # Every leaf remains manifest-bound. Never use recursive removal:
            # an unexpected new leaf must keep the directory and recovery record.
            foreach ($entry in @($fresh.Authorization.Manifest | Where-Object {-not $_.Directory})) {
                $path=Join-Path $fresh.Payload $entry.Name
                $null=Assert-LabRunArtifactPath $path
                if (-not (Test-LabPathWithinRoot -Root $fresh.Payload -Path $path).Valid) { throw 'RUN_ARTIFACT_PATH_ESCAPE' }
                if (Test-Path -LiteralPath $path) {
                    if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $entry.Sha256) { throw 'RUN_ARTIFACT_CONTENT_CHANGED' }
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
            }
            foreach ($entry in @($fresh.Authorization.Manifest | Where-Object Directory | Sort-Object {$_.Name.Length} -Descending)) {
                $path=Join-Path $fresh.Payload $entry.Name
                $null=Assert-LabRunArtifactPath $path
                if (-not (Test-LabPathWithinRoot -Root $fresh.Payload -Path $path).Valid) { throw 'RUN_ARTIFACT_PATH_ESCAPE' }
                if (Test-Path -LiteralPath $path) { [IO.Directory]::Delete($path,$false) }
            }
            if (Test-Path -LiteralPath $fresh.Payload) { [IO.Directory]::Delete($fresh.Payload,$false) }
            if (Test-Path -LiteralPath $fresh.MarkerPath) {
                if ((Get-FileHash -LiteralPath $fresh.MarkerPath).Hash -cne $fresh.Authorization.MarkerHash) { throw 'RUN_ARTIFACT_SCOPE_MARKER_CHANGED' }
                $null=Assert-LabRunArtifactPath $fresh.MarkerPath
                Remove-Item -LiteralPath $fresh.MarkerPath -Force -ErrorAction Stop
            }
            if ((Test-Path -LiteralPath $fresh.RunDirectory) -or (Test-Path -LiteralPath $fresh.Payload) -or (Test-Path -LiteralPath $fresh.MarkerPath)) { throw 'RUN_ARTIFACT_ABSENCE_UNVERIFIED' }
            $fresh.Journal.Status='REMOVED'; Write-LabArtifactJsonAtomic -Path $fresh.JournalPath -InputObject $fresh.Journal
            [pscustomobject]@{RunId=$RunId;Status='REMOVED';Changed=$true}
        }
        catch {
            $fresh.Journal.Status='RECOVERY_REQUIRED'; Write-LabArtifactJsonAtomic -Path $fresh.JournalPath -InputObject $fresh.Journal
            throw 'RUN_ARTIFACT_RECOVERY_REQUIRED'
        }
        }
        }
        }
        }
    }
    finally { for ($index=$locks.Count-1;$index -ge 0;$index--) {Exit-LabTestGroupLock -Mutex $locks[$index]} }
}
