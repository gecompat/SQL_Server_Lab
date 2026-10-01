# Existing ReconcilePlan family: proposed relations remain memory-only and never executable.
function Assert-LabComponentRelationShape {
    param($Value,[string[]]$Fields)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [array] -or $Value -is [ValueType] -or
        (@($Value.PSObject.Properties.Name | Sort-Object) -join '|') -cne (@($Fields | Sort-Object) -join '|')) {
        throw 'COMPONENT_RELATION_INPUT_INVALID'
    }
}

function Read-LabComponentRelationBinding {
    param([string]$RunId,[string]$StateRoot)
    $root=Assert-LabDiagnosticPath -Path $StateRoot
    if ([IO.Path]::GetFileName($root) -cne 'State' -or -not (Test-LabDiagnosticGuid $RunId)) { throw 'COMPONENT_RELATION_ROOT_INVALID' }
    $dataRoot=[IO.Path]::GetDirectoryName($root)
    $runPath=Join-Path (Join-Path (Join-Path $root 'runs') $RunId) 'run-state.json'
    $run=Read-LabDiagnosticJson -Path $runPath
    $instances=@($run.metadata.desiredState.Instances)
    if ($instances.Count -lt 1 -or $instances.Count -gt 2) { throw 'COMPONENT_RELATION_SCOPE_UNSUPPORTED' }
    $initialRun=$run
    $initialDesired=$run.metadata.desiredState | ConvertTo-Json -Depth 64 -Compress
    $initialSubRuns=$run.providerSubRuns | ConvertTo-Json -Depth 64 -Compress
    # Existing diagnostic authority checks registered controller/location/volume,
    # scope marker and exact desired-instance/provider-subrun membership without writes.
    foreach ($instance in $instances) {
        $binding=Get-LabDiagnosticBinding -RunId $RunId -InstanceId ([string]$instance.Id) -DataRoot $dataRoot
        if ($binding.Run.runId -cne $initialRun.runId -or $binding.Run.scopeId -cne $initialRun.scopeId -or
            $binding.Run.state -cne $initialRun.state -or
            ($binding.Run.providerSubRuns | ConvertTo-Json -Depth 64 -Compress) -cne $initialSubRuns -or
            ($binding.Run.metadata.desiredState | ConvertTo-Json -Depth 64 -Compress) -cne $initialDesired) {
            throw 'COMPONENT_RELATION_BINDING_CHANGED'
        }
        if ($binding.Provider -cnotin @('docker','podman')) { throw 'COMPONENT_RELATION_PROVIDER_UNSUPPORTED' }
    }
    $persisted=Get-LabPersistedDesiredState -RunId $RunId -StateRoot $root
    if ($persisted.Status -cne 'VALID') { throw 'COMPONENT_RELATION_DESIRED_INVALID' }
    $run=$binding.Run
    if ($run.metadata.desiredState.PSObject.Properties['Relations'] -or
        ($persisted.Snapshot | ConvertTo-Json -Depth 64 -Compress) -cne ($run.metadata.desiredState | ConvertTo-Json -Depth 64 -Compress)) {
        throw 'COMPONENT_RELATION_DESIRED_INVALID'
    }
    $instances=@($persisted.Snapshot.Instances)
    if ($instances.Count -lt 1 -or $instances.Count -gt 2) { throw 'COMPONENT_RELATION_SCOPE_UNSUPPORTED' }
    if (($persisted.Snapshot | ConvertTo-Json -Depth 64 -Compress) -cne $initialDesired) { throw 'COMPONENT_RELATION_BINDING_CHANGED' }
    $connection=Read-LabDiagnosticJson -Path (Join-Path ([IO.Path]::GetDirectoryName($runPath)) 'connection-info.json')
    if ($connection.instances -isnot [array] -or @($connection.instances).Count -ne $instances.Count) { throw 'COMPONENT_RELATION_CONNECTION_INVALID' }
    $projection=@(foreach ($instance in $instances | Sort-Object Id) {
        $rows=@($connection.instances | Where-Object { $_.id -ceq $instance.Id })
        if ($rows.Count -ne 1 -or $rows[0].provider -cne $instance.Provider -or
            $rows[0].containerId -isnot [string] -or $rows[0].containerId -cnotmatch '^[a-f0-9]{64}$' -or
            $rows[0].containerName -isnot [string] -or [string]::IsNullOrWhiteSpace($rows[0].containerName) -or
            $rows[0].host -isnot [string] -or $rows[0].host -cnotin @('127.0.0.1','localhost','::1') -or
            $rows[0].port -isnot [long] -and $rows[0].port -isnot [int] -or $rows[0].port -lt 1 -or $rows[0].port -gt 65535) {
            throw 'COMPONENT_RELATION_CONNECTION_INVALID'
        }
        [ordered]@{Instance=$instance;ProviderSubRun=@($run.providerSubRuns | Where-Object provider -CEQ $instance.Provider | ForEach-Object {
            [ordered]@{Id=$_.id;Provider=$_.provider;State=$_.state;InstanceIds=@($_.instanceIds | Sort-Object)}
        });Connection=[ordered]@{Id=$rows[0].id;Provider=$rows[0].provider;ContainerId=$rows[0].containerId;ContainerName=$rows[0].containerName;Host=$rows[0].host;Port=$rows[0].port}}
    })
    $marker=Read-LabDiagnosticJson -Path (Join-Path $dataRoot '.sql-server-lab-root.json') -MaximumBytes 16384 -MaximumDepth 8
    $catalog=Read-LabDiagnosticJson -Path (Join-Path $dataRoot 'Catalog/storage-locations.json') -MaximumBytes 65536 -MaximumDepth 12
    $document=[ordered]@{RunId=$run.runId;ScopeId=$run.scopeId;Instances=$projection;RootMarker=$marker;LocationCatalog=$catalog}
    # Observed content binding, not a revision counter, lease or CAS authority.
    $digest=Get-LabWorkflowHash -Text ($document | ConvertTo-Json -Depth 64 -Compress) -Length 64
    [pscustomobject]@{Run=$run;Instances=$instances;Digest=$digest}
}

function New-LabComponentRelationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProposedRelations,[string]$StateRoot)
    try {
        if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
        if ($ProposedRelations.Count -gt 4) { throw 'COMPONENT_RELATION_COUNT_LIMIT' }
        # Copy caller input before observations; subsequent caller edits cannot alter this plan.
        $relations=@($ProposedRelations | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12)
        if ($ProposedRelations.Count -eq 0) { $relations=@() }
        $own=Read-LabComponentRelationBinding -RunId $RunId -StateRoot $StateRoot
        $nodes=[ordered]@{};$bindings=[ordered]@{};$bindings[$RunId]=$own
        foreach ($instance in $own.Instances) {
            $key=$RunId+':'+$instance.Id
            $nodes[$key]=[pscustomobject]@{RunId=$RunId;ScopeId=$own.Run.scopeId;InstanceId=$instance.Id;Provider=$instance.Provider;ManagementMode='PROVISIONED';LifecycleState=$own.Run.state;ProviderSubRunState=($own.Run.providerSubRuns | Where-Object provider -CEQ $instance.Provider).state;SqlReadiness='NOT_CHECKED'}
        }
        $edges=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $sharedKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($relation in $relations) {
            Assert-LabComponentRelationShape $relation @('SourceInstanceId','Target','Type')
            Assert-LabComponentRelationShape $relation.Target @('RunId','ScopeId','InstanceId','ManagementMode')
            if ($relation.Type -isnot [string] -or $relation.Type -cne 'requires-sql' -or $relation.SourceInstanceId -isnot [string] -or
                $relation.Target.InstanceId -isnot [string] -or $relation.Target.InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or
                -not (Test-LabDiagnosticGuid $relation.Target.RunId) -or -not (Test-LabDiagnosticGuid $relation.Target.ScopeId)) {
                throw 'COMPONENT_RELATION_INPUT_INVALID'
            }
            $sourceKey=$RunId+':'+$relation.SourceInstanceId;$targetKey=$relation.Target.RunId+':'+$relation.Target.InstanceId
            if (-not $nodes.Contains($sourceKey) -or $sourceKey -ceq $targetKey -or -not $seen.Add($sourceKey+'>'+ $targetKey)) { throw 'COMPONENT_RELATION_TARGET_INVALID' }
            if ($relation.Target.RunId -ceq $RunId) {
                if ($relation.Target.ManagementMode -cne 'PROVISIONED' -or $relation.Target.ScopeId -cne $own.Run.scopeId -or -not $nodes.Contains($targetKey)) { throw 'COMPONENT_RELATION_TARGET_INVALID' }
            } else {
                if ($relation.Target.ManagementMode -cne 'EXTERNAL_READ_ONLY' -or $relation.Target.ScopeId -ceq $own.Run.scopeId) { throw 'COMPONENT_RELATION_TARGET_INVALID' }
                $null=$sharedKeys.Add($targetKey)
                if ($sharedKeys.Count -gt 1) { throw 'COMPONENT_RELATION_SCOPE_UNSUPPORTED' }
                if (-not $bindings.Contains($relation.Target.RunId)) { $bindings[$relation.Target.RunId]=Read-LabComponentRelationBinding -RunId $relation.Target.RunId -StateRoot $StateRoot }
                $shared=$bindings[$relation.Target.RunId];$target=@($shared.Instances | Where-Object Id -CEQ $relation.Target.InstanceId)
                if ($target.Count -ne 1 -or $shared.Run.scopeId -cne $relation.Target.ScopeId -or $shared.Run.state -ceq 'REMOVED') { throw 'COMPONENT_RELATION_TARGET_INVALID' }
                $nodes[$targetKey]=[pscustomobject]@{RunId=$relation.Target.RunId;ScopeId=$shared.Run.scopeId;InstanceId=$target[0].Id;Provider=$target[0].Provider;ManagementMode='EXTERNAL_READ_ONLY';LifecycleState=$shared.Run.state;ProviderSubRunState=($shared.Run.providerSubRuns | Where-Object provider -CEQ $target[0].Provider).state;SqlReadiness='NOT_CHECKED'}
            }
            $edges.Add([pscustomobject]@{Source=$sourceKey;Target=$targetKey})
        }
        $order=[Collections.Generic.List[object]]::new();$remaining=@($nodes.Keys | Sort-Object)
        while ($remaining.Count) {
            $available=@($remaining | Where-Object { $candidate=$_;@($edges | Where-Object { $_.Source -ceq $candidate -and $_.Target -cin $remaining }).Count -eq 0 })
            if (-not $available.Count) { throw 'COMPONENT_RELATION_CYCLE' }
            foreach ($key in $available) { $order.Add($nodes[$key]) }
            $remaining=@($remaining | Where-Object { $_ -cnotin $available })
        }
        # Fresh second read of every existing identity; never adopt or repair metadata.
        foreach ($id in @($bindings.Keys)) {
            $fresh=Read-LabComponentRelationBinding -RunId $id -StateRoot $StateRoot
            if ($fresh.Digest -cne $bindings[$id].Digest -or $fresh.Run.state -cne $bindings[$id].Run.state) { throw 'COMPONENT_RELATION_BINDING_CHANGED' }
        }
        $normalized=@($relations | Sort-Object SourceInstanceId,{ $_.Target.RunId },{ $_.Target.InstanceId } | ForEach-Object {
            [ordered]@{SourceInstanceId=$_.SourceInstanceId;Type='requires-sql';Target=[ordered]@{RunId=$_.Target.RunId;ScopeId=$_.Target.ScopeId;InstanceId=$_.Target.InstanceId;ManagementMode=$_.Target.ManagementMode}}
        })
        $content=[ordered]@{RunId=$RunId;ScopeId=$own.Run.scopeId;Relations=$normalized;References=@($bindings.Keys | Sort-Object | ForEach-Object { [ordered]@{RunId=$_;ObservedContentSha256=$bindings[$_].Digest} })}
        return [pscustomobject]@{
            Contract=[pscustomobject]@{Name='SqlServerLab.ReconcilePlan';Version='1.2'};Mode='COMPONENT_RELATIONS_PLAN_ONLY';RunId=$RunId
            SqlPurposeClass='INTEGRATION_SCENARIO'
            Desired=[pscustomobject]@{Source='explicit-proposed-relations';ProposedRelations=$normalized}
            Actual=[pscustomobject]@{Components=@($nodes.Values);SqlReadiness='NOT_CHECKED';Evidence='PERSISTED_BINDING_ONLY'}
            Diff=@($normalized | ForEach-Object { [pscustomobject]@{Kind='proposed-component-relation';SourceInstanceId=$_.SourceInstanceId;Target=$_.Target;ChangeClass='unsupported';Reason='COMPONENT_RELATION_EXECUTOR_UNAVAILABLE'} })
            Actions=@();ExecutionSupported=$false;MutationAllowed=$false;IsNoOp=($relations.Count -eq 0)
            Status=if(@($nodes.Values | Where-Object { $_.LifecycleState -cin @('PROVISION_FAILED','CLEANUP_PENDING','CLEANUP_RUNNING','RECOVERY_REQUIRED','REMOVED') -or $_.ProviderSubRunState -cin @('PROVISION_FAILED','CLEANUP_PENDING','CLEANUP_RUNNING','RECOVERY_REQUIRED','REMOVED') }).Count){'BLOCKED_COMPONENT_RECOVERY_REQUIRED'}elseif($relations.Count){'BLOCKED_SQL_READINESS_NOT_CHECKED'}else{'NO_RELATION_CHANGE'}
            PrerequisiteOrder=@($order);ObservedContentSha256=Get-LabWorkflowHash -Text ($content | ConvertTo-Json -Depth 32 -Compress) -Length 64
            ReferenceBindings=$content.References;SharedRemovalPolicy='PRESERVE';Warnings=@('Plan-only; keine Adoption, Lease, SQL-Prüfung oder Lifecycle-Ausführung.')
        }
    } catch {
        # Provider/host values and arbitrary exception messages never become public errors.
        $known=@('COMPONENT_RELATION_INPUT_INVALID','COMPONENT_RELATION_ROOT_INVALID','COMPONENT_RELATION_COUNT_LIMIT','COMPONENT_RELATION_SCOPE_UNSUPPORTED','COMPONENT_RELATION_PROVIDER_UNSUPPORTED','COMPONENT_RELATION_DESIRED_INVALID','COMPONENT_RELATION_CONNECTION_INVALID','COMPONENT_RELATION_TARGET_INVALID','COMPONENT_RELATION_CYCLE','COMPONENT_RELATION_BINDING_CHANGED')
        if ($_.Exception.Message -cin $known) { throw $_.Exception.Message }
        throw 'COMPONENT_RELATION_BINDING_UNAVAILABLE'
    }
}
