function Get-LabEnvironmentGroupsRegistryPath {
    [CmdletBinding()]
    param([string]$StateRoot)

    $root = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-LabStateRoot } else { $StateRoot }
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'LAB_STATE_ROOT_REQUIRED' }
    return (Join-Path ([IO.Path]::GetFullPath($root)) 'EnvironmentGroups.registry.json')
}

function Enter-LabEnvironmentGroupsLock {
    [CmdletBinding()]
    param([string]$StateRoot)

    $path = Get-LabEnvironmentGroupsRegistryPath -StateRoot $StateRoot
    $root = Get-LabCanonicalResourceRoot -StateRoot ([IO.Path]::GetDirectoryName($path))
    $cursor = $path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'LAB_ENVIRONMENT_GROUPS_REPARSE_POINT' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $name = 'SqlServerLab.EnvironmentGroups.' + (Get-LabWorkflowHash -Text $root -Length 64)
    if ($IsWindows) { $name = 'Global\' + $name }
    $mutex = [Threading.Mutex]::new($false,$name)
    try {
        # Registry critical sections are brief; wait through independent run transactions
        # instead of failing a peer merely because it won the mutex by a few milliseconds.
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'LAB_ENVIRONMENT_GROUPS_BUSY' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-LabEnvironmentGroupsLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mutex)
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}

function Enter-LabEnvironmentGroupLifecycleLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GroupId,[string]$StateRoot)

    $groupGuid = [guid]::Empty
    if (-not [guid]::TryParse($GroupId,[ref]$groupGuid)) { throw 'LAB_ENVIRONMENT_GROUP_ID_INVALID' }
    $path = Get-LabEnvironmentGroupsRegistryPath -StateRoot $StateRoot
    $root = Get-LabCanonicalResourceRoot -StateRoot ([IO.Path]::GetDirectoryName($path))
    $name = 'SqlServerLab.EnvironmentGroups.Lifecycle.' + (Get-LabWorkflowHash -Text $root -Length 64) + '.' + $groupGuid.ToString('N')
    if ($IsWindows) { $name = 'Global\' + $name }
    $mutex = [Threading.Mutex]::new($false,$name)
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'LAB_ENVIRONMENT_GROUPS_BUSY' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-LabEnvironmentGroupLifecycleLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mutex)
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}

function Enter-LabEnvironmentGroupRunResourceLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot)

    $mutexes = [Collections.Generic.List[Threading.Mutex]]::new()
    try {
        foreach ($name in @((Get-LabContainerResourceLockName -StateRoot $StateRoot -RunId $RunId),('SqlServerLab.HyperVMigration.' + $RunId))) {
            $mutex = [Threading.Mutex]::new($false,$name)
            try {
                try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
                if (-not $acquired) { throw 'LAB_ENVIRONMENT_GROUP_RUN_BUSY' }
                $mutexes.Add($mutex)
            }
            catch { $mutex.Dispose(); throw }
        }
        return [PSCustomObject]@{Mutexes=@($mutexes.ToArray())}
    }
    catch {
        for ($index = $mutexes.Count - 1; $index -ge 0; $index--) {
            try { $mutexes[$index].ReleaseMutex() } finally { $mutexes[$index].Dispose() }
        }
        throw
    }
}

function Exit-LabEnvironmentGroupRunResourceLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mutex)
    for ($index = @($Mutex.Mutexes).Count - 1; $index -ge 0; $index--) {
        $Mutex.Mutexes[$index].ReleaseMutex()
        $Mutex.Mutexes[$index].Dispose()
    }
}

function Get-LabEnvironmentGroupMemberProtectionReason {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot)

    if (Test-LabAutomatedTestEnvironmentRun -RunId $RunId) { return 'PROTECTED_TEST_RUN' }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ($run.metadata.windowsPoolMember) { return 'WINDOWS_POOL_MEMBER' }
    try { Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $StateRoot }
    catch {
        if ([string]$_.Exception.Message -eq 'WINDOWS_POOL_MEMBER_RESERVED') { return 'WINDOWS_POOL_MEMBER_RESERVED' }
        throw
    }
    return $null
}

function Assert-LabEnvironmentGroupMemberBindingCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Member,[string]$StateRoot,[switch]$AllowRecoveryState)

    $current = Get-LabEnvironmentGroupMemberBinding -RunId ([string]$Member.runId) -StateRoot $StateRoot -AllowRecoveryState:$AllowRecoveryState
    if ($current.scopeId -cne [string]$Member.scopeId -or $current.connectionInfoSha256 -cne [string]$Member.connectionInfoSha256 -or
        (@($current.instanceIds) -join '|') -cne (@($Member.instanceIds) -join '|')) {
        throw 'LAB_ENVIRONMENT_GROUP_MEMBER_BINDING_STALE'
    }
}

function Assert-LabEnvironmentGroupRunJournalsSettled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)]$Connection,[string]$StateRoot)

    $root = if ($StateRoot) { $StateRoot } else { Get-LabStateRoot }
    $runDirectory = Join-Path (Join-Path $root 'runs') $RunId
    $journals = @(Get-ChildItem -LiteralPath $runDirectory -Filter '*journal*.json' -File -ErrorAction Stop)
    $providers = @($Connection.instances | Select-Object -ExpandProperty provider -Unique)
    if ($providers.Count -ne 1) { throw 'LAB_ENVIRONMENT_GROUP_PROVIDER_SET_UNSUPPORTED' }
    $provider = [string]$providers[0]
    if ($provider -ceq 'hyperv') {
        $null = Assert-LabHyperVResourceMigrationLifecycleAllowed -RunId $RunId -Operation 'GroupLifecycle' -StateRoot $StateRoot
        if ($journals.Count -gt 0) { throw 'LAB_ENVIRONMENT_GROUP_RECOVERY_REVIEW_REQUIRED' }
        return
    }
    if ($provider -cnotin @('docker','podman')) { throw 'LAB_ENVIRONMENT_GROUP_PROVIDER_SET_UNSUPPORTED' }
    $reconcilePath = Get-LabContainerReconcileJournalPath -RunDirectory $runDirectory
    if (@($journals | Where-Object { -not [string]::Equals($_.FullName,$reconcilePath,[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw 'LAB_ENVIRONMENT_GROUP_RECOVERY_REVIEW_REQUIRED'
    }
    if (Test-Path -LiteralPath $reconcilePath -PathType Leaf) {
        $journal = Get-Content -LiteralPath $reconcilePath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        $null = Assert-LabContainerReconcileJournal -Journal $journal
        $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
        $instanceIds = @($Connection.instances | ForEach-Object { [string]$_.id })
        if ([string]$journal.Status -cnotin @('COMPLETED','ROLLED_BACK') -or
            [string]$journal.RunId -cne $RunId -or [string]$journal.ScopeId -cne [string]$run.scopeId -or
            [string]$journal.Provider -cne $provider -or [string]$journal.InstanceId -cnotin $instanceIds) {
            throw 'LAB_ENVIRONMENT_GROUP_RECOVERY_BLOCKED'
        }
    }
}

function Get-LabEnvironmentGroupsRegistry {
    [CmdletBinding()]
    param([string]$StateRoot)

    $path = Get-LabEnvironmentGroupsRegistryPath -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [PSCustomObject][ordered]@{
            contractVersion = 'SqlServerLab.EnvironmentGroups/1.0'
            updatedAt = Get-LabTimestamp
            groups = @()
        }
    }
    $json = Get-Content -LiteralPath $path -Raw -Encoding utf8 -ErrorAction Stop
    $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Schemas/environment-groups.schema.json'
    if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID' }
    $registry = $json | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    if ([string]$registry.contractVersion -cne 'SqlServerLab.EnvironmentGroups/1.0' -or
        $null -eq $registry.groups -or $registry.groups -is [string]) {
        throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
    }

    $expectedStateRootKey = Get-LabEnvironmentGroupStateRootKey -StateRoot $StateRoot
    $groupIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $identityByRun = @{}
    foreach ($group in @($registry.groups)) {
        $groupGuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$group.groupId, [ref]$groupGuid) -or
            -not $groupIds.Add($groupGuid.ToString('D')) -or
            [string]::IsNullOrWhiteSpace([string]$group.name) -or
            [string]$group.name -cne ([string]$group.name).Trim() -or
            ([string]$group.name).Length -gt 80 -or [string]$group.name -match '[\x00-\x1F\x7F]' -or
            [string]$group.stateRootKey -cnotmatch '^[A-Fa-f0-9]{64}$' -or
            [string]$group.stateRootKey -cne $expectedStateRootKey -or
            $null -eq $group.members -or $group.members -is [string]) {
            throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
        }
        $memberRuns = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($member in @($group.members)) {
            $runGuid = [guid]::Empty
            $scopeGuid = [guid]::Empty
            if (-not [guid]::TryParse([string]$member.runId, [ref]$runGuid) -or
                -not [guid]::TryParse([string]$member.scopeId, [ref]$scopeGuid) -or
                -not $memberRuns.Add($runGuid.ToString('D')) -or
                [string]$member.connectionInfoSha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace([string]$member.assignedAt) -or
                $null -eq $member.instanceIds -or $member.instanceIds -is [string]) {
                throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
            }
            $instanceIds = @($member.instanceIds)
            if ($instanceIds.Count -eq 0 -or @($instanceIds | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' }).Count -gt 0 -or
                @($instanceIds | Sort-Object -Unique).Count -ne $instanceIds.Count) {
                throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
            }
            $identity = '{0}|{1}|{2}' -f $group.stateRootKey,$scopeGuid.ToString('D'),([string]$member.connectionInfoSha256).ToUpperInvariant()
            $runKey = $runGuid.ToString('D')
            if ($identityByRun.ContainsKey($runKey) -and $identityByRun[$runKey] -cne $identity) {
                throw 'LAB_ENVIRONMENT_GROUPS_RUN_IDENTITY_CONFLICT'
            }
            $identityByRun[$runKey] = $identity
        }
        $lifecycleState = [string]$group.lifecycleState
        $operation = $group.operation
        if ($lifecycleState -eq 'STOPPED' -and $null -eq $operation) { continue }
        if ($null -eq $operation) { throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID' }
        $expectedAction = switch ($lifecycleState) {
            { $_ -in @('STARTING','ACTIVE') } { 'Start'; break }
            { $_ -in @('STOPPING','STOPPED') } { 'Stop'; break }
            'RECOVERY_REQUIRED' {
                if ([string]$operation.action -notin @('Start','Stop')) { throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID' }
                [string]$operation.action
            }
            default { throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID' }
        }
        $expectedOperationState = switch ($lifecycleState) {
            'STARTING' { 'IN_PROGRESS' }
            'ACTIVE' { 'COMPLETED' }
            'STOPPING' { 'IN_PROGRESS' }
            'RECOVERY_REQUIRED' { 'RECOVERY_REQUIRED' }
            'STOPPED' { 'COMPLETED' }
            default { throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID' }
        }
        if ([string]$operation.action -cne $expectedAction -or [string]$operation.state -cne $expectedOperationState) {
            throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
        }
        $operationRuns = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($operationMember in @($operation.members)) {
            $operationRunGuid = [guid]::Empty
            if (-not [guid]::TryParse([string]$operationMember.runId,[ref]$operationRunGuid) -or
                -not $operationRuns.Add($operationRunGuid.ToString('D')) -or
                -not $memberRuns.Contains($operationRunGuid.ToString('D')) -or
                [string]$operationMember.action -notin @('START','STOP','RETAIN')) {
                throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
            }
            if (($expectedAction -eq 'Start' -and [string]$operationMember.action -cne 'START') -or
                ($expectedAction -eq 'Stop' -and [string]$operationMember.action -notin @('STOP','RETAIN'))) {
                throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
            }
            if ([string]$operationMember.action -eq 'RETAIN' -and [string]$operationMember.status -cne 'RETAINED_SHARED') {
                throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
            }
            if (($lifecycleState -eq 'ACTIVE' -and [string]$operationMember.status -notin @('STARTED','UNCHANGED')) -or
                ($lifecycleState -eq 'STOPPED' -and [string]$operationMember.status -notin @('STOPPED','RETAINED_SHARED'))) {
                throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID'
            }
        }
        if ($operationRuns.Count -ne $memberRuns.Count) { throw 'LAB_ENVIRONMENT_GROUPS_REGISTRY_INVALID' }
    }
    return $registry
}

function Write-LabEnvironmentGroupsRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Registry,[string]$StateRoot)

    $path = Get-LabEnvironmentGroupsRegistryPath -StateRoot $StateRoot
    $Registry.updatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $path -InputObject $Registry
    Protect-LabTestEnvironmentSecretFile -Path $path
}

function Get-LabEnvironmentGroupRunClaims {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)]$Registry,[string]$ExcludeGroupId)

    $activeStates = @('STARTING','ACTIVE','STOPPING','RECOVERY_REQUIRED')
    foreach ($group in @($Registry.groups | Where-Object {
        [string]$_.groupId -ine $ExcludeGroupId -and [string]$_.lifecycleState -in $activeStates
    })) {
        foreach ($member in @($group.members | Where-Object { [string]$_.runId -ieq $RunId })) {
            # A STOPPING group has atomically relinquished this run when it
            # records RETAINED_SHARED while holding the run-resource mutex.
            # Ignoring that released claim lets the next serialized stopper
            # make progress instead of both groups retaining the run.
            $operationMember = @($group.operation.members | Where-Object { [string]$_.runId -ieq $RunId }) | Select-Object -First 1
            if ([string]$group.lifecycleState -eq 'STOPPING' -and $operationMember -and
                [string]$operationMember.action -ceq 'RETAIN' -and [string]$operationMember.status -ceq 'RETAINED_SHARED') {
                continue
            }
            [PSCustomObject]@{ GroupId=[string]$group.groupId; GroupName=[string]$group.name; State=[string]$group.lifecycleState }
        }
    }
}

function Assert-LabEnvironmentGroupOperationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('Start','Stop')][string]$Action,
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)]$Context
    )

    $groupId = [string]$Context.GroupId
    $operationId = [string]$Context.OperationId
    if ([string]$Context.Action -cne $Action -or [string]$Context.RunId -cne $RunId) {
        throw 'LAB_ENVIRONMENT_GROUP_OPERATION_CONTEXT_INVALID'
    }
    $group = @($Registry.groups | Where-Object { [string]$_.groupId -ceq $groupId }) | Select-Object -First 1
    if (-not $group -or [string]$group.operation.operationId -cne $operationId -or
        [string]$group.operation.action -cne $Action -or [string]$group.operation.state -cne 'IN_PROGRESS' -or
        [string]$group.lifecycleState -cne $(if ($Action -eq 'Start') {'STARTING'} else {'STOPPING'})) {
        throw 'LAB_ENVIRONMENT_GROUP_OPERATION_CONTEXT_INVALID'
    }
    $member = @($group.operation.members | Where-Object { [string]$_.runId -ieq $RunId -and [string]$_.action -ceq $Action.ToUpperInvariant() -and [string]$_.status -ceq 'IN_PROGRESS' }) | Select-Object -First 1
    if (-not $member) { throw 'LAB_ENVIRONMENT_GROUP_OPERATION_CONTEXT_INVALID' }
}

function Assert-LabEnvironmentGroupRunMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('Start','Stop','Restart','Remove')][string]$Action,
        [Parameter(Mandatory)]$Registry,
        $GroupOperationContext
    )

    $runGuid = [guid]::Empty
    if (-not [guid]::TryParse($RunId,[ref]$runGuid)) { throw 'LAB_ENVIRONMENT_GROUP_RUN_ID_INVALID' }
    $RunId = $runGuid.ToString('D')
    $claims = @(Get-LabEnvironmentGroupRunClaims -RunId $RunId -Registry $Registry)
    if ($Action -eq 'Stop' -and $GroupOperationContext) {
        Assert-LabEnvironmentGroupOperationContext -RunId $RunId -Action Stop -Registry $Registry -Context $GroupOperationContext
        return
    }
    if ($Action -eq 'Start' -and $GroupOperationContext) {
        Assert-LabEnvironmentGroupOperationContext -RunId $RunId -Action Start -Registry $Registry -Context $GroupOperationContext
        return
    }
    if ($Action -in @('Start','Stop','Restart','Remove') -and $claims.Count -gt 0) {
        $claim = $claims[0]
        throw "LAB_ENVIRONMENT_GROUP_RUN_CLAIMED: Run '$RunId' wird von Gruppe '$($claim.GroupId)' beansprucht ($($claim.State)); Lifecycle über die Gruppe ausführen."
    }
    if ($Action -eq 'Remove') {
        $references = @($Registry.groups | Where-Object { @($_.members | Where-Object { [string]$_.runId -ieq $RunId }).Count -gt 0 })
        if ($references.Count -gt 0) { throw "LAB_ENVIRONMENT_GROUP_RUN_REFERENCED: Run '$RunId' zuerst aus allen Gruppen lösen." }
    }
}

function Assert-LabEnvironmentGroupStoppedForMembershipChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Group)
    if ([string]$Group.lifecycleState -ne 'STOPPED') { throw 'LAB_ENVIRONMENT_GROUP_MUST_BE_STOPPED' }
}

function Set-LabEnvironmentGroupOperationMemberState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Status,
        [AllowNull()][string]$ReasonCode,
        [ValidateSet('START','STOP','RETAIN')][string]$MemberAction,
        [string]$StateRoot
    )

    $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
    try {
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        $group = @($registry.groups | Where-Object { [string]$_.groupId -ceq $GroupId }) | Select-Object -First 1
        if (-not $group -or -not $group.operation -or [string]$group.operation.operationId -cne $OperationId -or
            [string]$group.operation.state -cne 'IN_PROGRESS') { throw 'LAB_ENVIRONMENT_GROUP_OPERATION_SUPERSEDED' }
        $member = @($group.operation.members | Where-Object { [string]$_.runId -ieq $RunId }) | Select-Object -First 1
        if (-not $member) { throw 'LAB_ENVIRONMENT_GROUP_OPERATION_MEMBER_MISSING' }
        if ($PSBoundParameters.ContainsKey('MemberAction')) { $member.action = $MemberAction }
        $member.status = $Status
        $member.reasonCode = $ReasonCode
        $group.operation.updatedAt = Get-LabTimestamp
        Write-LabEnvironmentGroupsRegistry -Registry $registry -StateRoot $StateRoot
        return $registry
    }
    finally { Exit-LabEnvironmentGroupsLock -Mutex $lock }
}

function Set-LabEnvironmentGroupLifecycleResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][ValidateSet('ACTIVE','STOPPED','RECOVERY_REQUIRED')][string]$LifecycleState,
        [Parameter(Mandatory)][ValidateSet('COMPLETED','RECOVERY_REQUIRED')][string]$OperationState,
        [string]$StateRoot
    )

    $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
    try {
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        $group = @($registry.groups | Where-Object { [string]$_.groupId -ceq $GroupId }) | Select-Object -First 1
        if (-not $group -or -not $group.operation -or [string]$group.operation.operationId -cne $OperationId -or
            [string]$group.operation.state -cne 'IN_PROGRESS') { throw 'LAB_ENVIRONMENT_GROUP_OPERATION_SUPERSEDED' }
        $group.lifecycleState = $LifecycleState
        $group.operation.state = $OperationState
        $group.operation.updatedAt = Get-LabTimestamp
        Write-LabEnvironmentGroupsRegistry -Registry $registry -StateRoot $StateRoot
        return $registry
    }
    finally { Exit-LabEnvironmentGroupsLock -Mutex $lock }
}

function Invoke-LabEnvironmentGroupLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][ValidateSet('Start','Stop')][string]$Action,
        [string]$StateRoot,
        [int]$TimeoutSeconds = 60,
        [switch]$SkipReadyCheck,
        [switch]$Force,
        [switch]$SkipHostMemoryRelease
    )

    $groupGuid = [guid]::Empty
    if (-not [guid]::TryParse($GroupId,[ref]$groupGuid)) { throw 'LAB_ENVIRONMENT_GROUP_ID_INVALID' }
    $normalizedGroupId = $groupGuid.ToString('D')
    $lifecycleLock = Enter-LabEnvironmentGroupLifecycleLock -GroupId $normalizedGroupId -StateRoot $StateRoot
    $lock = $null
    $groupOperationContext = $null
    try {
        $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        $matches = @($registry.groups | Where-Object { [string]$_.groupId -ceq $normalizedGroupId })
        if ($matches.Count -ne 1) { throw 'LAB_ENVIRONMENT_GROUP_NOT_FOUND' }
        $group = $matches[0]
        $members = @($group.members | Sort-Object runId)
        $initialLifecycleState = [string]$group.lifecycleState
        $initialOperationId = if ($group.operation) { [string]$group.operation.operationId } else { $null }
        Exit-LabEnvironmentGroupsLock -Mutex $lock
        $lock = $null
        if ($Action -eq 'Stop' -and [string]$group.lifecycleState -eq 'STOPPED') {
            return [PSCustomObject]@{Status='ALREADY_STOPPED';GroupId=$normalizedGroupId;OperationId=$(if($group.operation){[string]$group.operation.operationId}else{$null})}
        }
        if ($members.Count -eq 0) { throw 'LAB_ENVIRONMENT_GROUP_EMPTY' }

        foreach ($member in $members) {
            $current = Get-LabEnvironmentGroupMemberBinding -RunId ([string]$member.runId) -StateRoot $StateRoot -AllowRecoveryState:($Action -eq 'Stop')
            if ($current.scopeId -cne [string]$member.scopeId -or $current.connectionInfoSha256 -cne [string]$member.connectionInfoSha256 -or
                (@($current.instanceIds) -join '|') -cne (@($member.instanceIds) -join '|')) { throw 'LAB_ENVIRONMENT_GROUP_MEMBER_BINDING_STALE' }
        }
        if ($Action -eq 'Start') {
            if ([string]$group.lifecycleState -eq 'ACTIVE') {
                foreach ($member in $members) {
                    $protectionReason = Get-LabEnvironmentGroupMemberProtectionReason -RunId ([string]$member.runId) -StateRoot $StateRoot
                    if ($protectionReason) { throw "LAB_ENVIRONMENT_GROUP_MEMBER_PROTECTED: $($member.runId) ($protectionReason)" }
                    $runResourceLock = Enter-LabEnvironmentGroupRunResourceLock -RunId ([string]$member.runId) -StateRoot $StateRoot
                    try {
                        Assert-LabEnvironmentGroupMemberBindingCurrent -Member $member -StateRoot $StateRoot
                        $connectionPath = Join-Path (Join-Path (Join-Path $(if($StateRoot){$StateRoot}else{Get-LabStateRoot}) 'runs') ([string]$member.runId)) 'connection-info.json'
                        $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                        Assert-LabEnvironmentGroupRunJournalsSettled -RunId ([string]$member.runId) -Connection $connection -StateRoot $StateRoot
                        $memberRuntime = Sync-LabEnvironmentGroupMemberRuntime -RunId ([string]$member.runId) -Action Start -StateRoot $StateRoot
                        if ([string]$memberRuntime.Runtime.State -cne 'RUNNING' -or [string]$memberRuntime.Run.state -cne 'RUNNING') {
                            throw "LAB_ENVIRONMENT_GROUP_ACTIVE_MEMBER_NOT_RUNNING: $($member.runId) ($($memberRuntime.Runtime.State)/$($memberRuntime.Run.state))"
                        }
                    }
                    finally { Exit-LabEnvironmentGroupRunResourceLock -Mutex $runResourceLock }
                }
                return [PSCustomObject]@{Status='ALREADY_ACTIVE';GroupId=$normalizedGroupId;OperationId=[string]$group.operation.operationId}
            }
            if ([string]$group.lifecycleState -ne 'STOPPED') { throw 'LAB_ENVIRONMENT_GROUP_RECOVERY_REQUIRED: zuerst Stop zur kontrollierten Wiederherstellung ausführen.' }
        }
        else {
            if ([string]$group.lifecycleState -notin @('ACTIVE','STARTING','STOPPING','RECOVERY_REQUIRED')) { throw 'LAB_ENVIRONMENT_GROUP_STATE_INVALID' }
        }

        foreach ($member in $members) {
            $runId = [string]$member.runId
            $protectionReason = Get-LabEnvironmentGroupMemberProtectionReason -RunId $runId -StateRoot $StateRoot
            if ($protectionReason) {
                if ($Action -eq 'Start') { throw "LAB_ENVIRONMENT_GROUP_MEMBER_PROTECTED: $runId ($protectionReason)" }
                continue
            }
            $connectionPath = Join-Path (Join-Path (Join-Path $(if($StateRoot){$StateRoot}else{Get-LabStateRoot}) 'runs') $runId) 'connection-info.json'
            $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop
            Assert-LabEnvironmentGroupRunJournalsSettled -RunId $runId -Connection $connection -StateRoot $StateRoot
        }

        $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
        $freshRegistry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        $freshMatches = @($freshRegistry.groups | Where-Object { [string]$_.groupId -ceq $normalizedGroupId })
        if ($freshMatches.Count -ne 1) { throw 'LAB_ENVIRONMENT_GROUP_OPERATION_SUPERSEDED' }
        $freshGroup = $freshMatches[0]
        $initialMemberKey = ConvertTo-Json -InputObject @($members | Sort-Object runId | ForEach-Object {
            [ordered]@{runId=[string]$_.runId;scopeId=[string]$_.scopeId;connectionInfoSha256=[string]$_.connectionInfoSha256;instanceIds=@($_.instanceIds)}
        }) -Depth 10 -Compress
        $freshMemberKey = ConvertTo-Json -InputObject @($freshGroup.members | Sort-Object runId | ForEach-Object {
            [ordered]@{runId=[string]$_.runId;scopeId=[string]$_.scopeId;connectionInfoSha256=[string]$_.connectionInfoSha256;instanceIds=@($_.instanceIds)}
        }) -Depth 10 -Compress
        $freshOperationId = if ($freshGroup.operation) { [string]$freshGroup.operation.operationId } else { $null }
        if ([string]$freshGroup.lifecycleState -cne $initialLifecycleState -or $freshOperationId -cne $initialOperationId -or
            $freshMemberKey -cne $initialMemberKey) { throw 'LAB_ENVIRONMENT_GROUP_OPERATION_SUPERSEDED' }
        $registry = $freshRegistry
        $group = $freshGroup
        $members = @($group.members | Sort-Object runId)
        $operationId = [guid]::NewGuid().ToString('D')
        $memberOperations = foreach ($member in $members) {
            $memberAction = if ($Action -eq 'Start') { 'START' } else { 'STOP' }
            [PSCustomObject][ordered]@{runId=[string]$member.runId;action=$memberAction;status='PENDING';reasonCode=$null}
        }
        $group.lifecycleState = if ($Action -eq 'Start') { 'STARTING' } else { 'STOPPING' }
        $group.operation = [PSCustomObject][ordered]@{
            operationId=$operationId;action=$Action;state='IN_PROGRESS';startedAt=Get-LabTimestamp;updatedAt=Get-LabTimestamp;members=@($memberOperations)
        }
        Write-LabEnvironmentGroupsRegistry -Registry $registry -StateRoot $StateRoot
        Exit-LabEnvironmentGroupsLock -Mutex $lock
        $lock = $null

        try {
        foreach ($member in $members) {
            $runId = [string]$member.runId
                $protectionReason = Get-LabEnvironmentGroupMemberProtectionReason -RunId $runId -StateRoot $StateRoot
                if ($Action -eq 'Stop' -and $protectionReason) {
                    $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'RETAINED_SHARED' -ReasonCode $protectionReason -MemberAction RETAIN -StateRoot $StateRoot
                    continue
                }
                if ($Action -eq 'Start' -and $protectionReason) { throw "LAB_ENVIRONMENT_GROUP_MEMBER_PROTECTED: $runId ($protectionReason)" }
                $runResourceLock = Enter-LabEnvironmentGroupRunResourceLock -RunId $runId -StateRoot $StateRoot
                try {
                $connectionPath = Join-Path (Join-Path (Join-Path $(if($StateRoot){$StateRoot}else{Get-LabStateRoot}) 'runs') $runId) 'connection-info.json'
                $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                Assert-LabEnvironmentGroupRunJournalsSettled -RunId $runId -Connection $connection -StateRoot $StateRoot
                Assert-LabEnvironmentGroupMemberBindingCurrent -Member $member -StateRoot $StateRoot -AllowRecoveryState:($Action -eq 'Stop')
                if ($Action -eq 'Start') {
                    $memberRuntime = Sync-LabEnvironmentGroupMemberRuntime -RunId $runId -Action Start -StateRoot $StateRoot
                    $run = $memberRuntime.Run
                    if ([string]$run.state -eq 'RUNNING') {
                        $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'UNCHANGED' -ReasonCode 'ALREADY_RUNNING' -StateRoot $StateRoot
                        continue
                    }
                    if ([string]$run.state -ne 'STOPPED') { throw "LAB_ENVIRONMENT_GROUP_MEMBER_NOT_STARTABLE: $runId ($($run.state))" }
                    $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'IN_PROGRESS' -ReasonCode $null -StateRoot $StateRoot
                    $groupOperationContext = [PSCustomObject]@{GroupId=$normalizedGroupId;OperationId=$operationId;Action='Start';RunId=$runId}
                    $script:LabEnvironmentGroupOperationContext = $groupOperationContext
                    try { $result = Start-SqlServerLab -RunId $runId -TimeoutSeconds $TimeoutSeconds -SkipReadyCheck:$SkipReadyCheck -StateRoot $StateRoot }
                    finally { $script:LabEnvironmentGroupOperationContext = $null; $groupOperationContext = $null }
                    $after = Get-LabRunState -RunId $runId -StateRoot $StateRoot
                    $afterRuntime = Get-LabRunRuntimeStatus -Run $after -StateRoot $StateRoot
                    if ([string]$after.state -cne 'RUNNING' -or [string]$afterRuntime.State -cne 'RUNNING' -or [string]$result.Status -in @('FAILED','ERROR') -or [int]$result.Errors -gt 0) { throw "LAB_ENVIRONMENT_GROUP_MEMBER_START_UNCONFIRMED: $runId ($($afterRuntime.State))" }
                    $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'STARTED' -ReasonCode $null -StateRoot $StateRoot
                }
                else {
                    $memberRuntime = Sync-LabEnvironmentGroupMemberRuntime -RunId $runId -Action Stop -StateRoot $StateRoot
                    $freshRegistry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
                    $claims = @(Get-LabEnvironmentGroupRunClaims -RunId $runId -Registry $freshRegistry -ExcludeGroupId $normalizedGroupId)
                    if ($claims.Count -gt 0) {
                        if ([string]$memberRuntime.Runtime.State -cne 'RUNNING') { throw "LAB_ENVIRONMENT_GROUP_SHARED_MEMBER_NOT_RUNNING: $runId ($($memberRuntime.Runtime.State))" }
                        $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'RETAINED_SHARED' -ReasonCode 'OTHER_ACTIVE_GROUP_CLAIM' -MemberAction RETAIN -StateRoot $StateRoot
                        continue
                    }
                    $run = $memberRuntime.Run
                    if ([string]$run.state -eq 'STOPPED') {
                        $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'STOPPED' -ReasonCode 'ALREADY_STOPPED' -StateRoot $StateRoot
                        continue
                    }
                    if ([string]$run.state -ne 'RUNNING') { throw "LAB_ENVIRONMENT_GROUP_MEMBER_NOT_STOPPABLE: $runId ($($run.state))" }
                    $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'IN_PROGRESS' -ReasonCode $null -StateRoot $StateRoot
                    $groupOperationContext = [PSCustomObject]@{GroupId=$normalizedGroupId;OperationId=$operationId;Action='Stop';RunId=$runId}
                    $script:LabEnvironmentGroupOperationContext = $groupOperationContext
                    try { $result = Stop-SqlServerLab -RunId $runId -Force:$Force -SkipHostMemoryRelease:$SkipHostMemoryRelease -StateRoot $StateRoot -Confirm:$false }
                    finally { $script:LabEnvironmentGroupOperationContext = $null; $groupOperationContext = $null }
                    $after = Get-LabRunState -RunId $runId -StateRoot $StateRoot
                    $afterRuntime = Get-LabRunRuntimeStatus -Run $after -StateRoot $StateRoot
                    if ([string]$after.state -cne 'STOPPED' -or [string]$afterRuntime.State -cne 'STOPPED' -or [string]$result.Action -cne 'STOPPED' -or [int]$result.Errors -gt 0) { throw "LAB_ENVIRONMENT_GROUP_MEMBER_STOP_UNCONFIRMED: $runId ($($afterRuntime.State))" }
                    $null = Set-LabEnvironmentGroupOperationMemberState -GroupId $normalizedGroupId -OperationId $operationId -RunId $runId -Status 'STOPPED' -ReasonCode $null -StateRoot $StateRoot
                }
                }
                finally { Exit-LabEnvironmentGroupRunResourceLock -Mutex $runResourceLock }
            }
            $finalLifecycleState = if ($Action -eq 'Start') { 'ACTIVE' } else { 'STOPPED' }
            $registry = Set-LabEnvironmentGroupLifecycleResult -GroupId $normalizedGroupId -OperationId $operationId `
                -LifecycleState $finalLifecycleState -OperationState COMPLETED -StateRoot $StateRoot
            $group = @($registry.groups | Where-Object { [string]$_.groupId -ceq $normalizedGroupId }) | Select-Object -First 1
            return [PSCustomObject]@{Status=if($Action -eq 'Start'){'STARTED'}else{'STOPPED'};GroupId=$normalizedGroupId;OperationId=$operationId;Members=@($group.operation.members)}
        }
        catch {
            try { $null = Set-LabEnvironmentGroupLifecycleResult -GroupId $normalizedGroupId -OperationId $operationId `
                -LifecycleState RECOVERY_REQUIRED -OperationState RECOVERY_REQUIRED -StateRoot $StateRoot } catch { }
            throw
        }
    }
    finally {
        $script:LabEnvironmentGroupOperationContext = $null
        if ($null -ne $lock) { Exit-LabEnvironmentGroupsLock -Mutex $lock }
        Exit-LabEnvironmentGroupLifecycleLock -Mutex $lifecycleLock
    }
}

function Get-LabEnvironmentGroupStateRootKey {
    [CmdletBinding()]
    param([string]$StateRoot)

    $root = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-LabStateRoot } else { $StateRoot }
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'LAB_STATE_ROOT_REQUIRED' }
    $canonical = Get-LabCanonicalResourceRoot -StateRoot $root
    return (Get-LabWorkflowHash -Text $canonical -Length 64).ToUpperInvariant()
}

function Get-LabEnvironmentGroupMemberBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot,[switch]$AllowRecoveryState)

    $runGuid = [guid]::Empty
    if (-not [guid]::TryParse($RunId, [ref]$runGuid)) { throw 'LAB_ENVIRONMENT_GROUP_RUN_ID_INVALID' }
    $normalizedRunId = $runGuid.ToString('D')
    $run = Get-LabRunState -RunId $normalizedRunId -StateRoot $StateRoot
    $scopeGuid = [guid]::Empty
    $allowedStates = @('RUNNING','STOPPED')
    if ($AllowRecoveryState) { $allowedStates += @('PROVISION_FAILED','CLEANUP_PENDING','CLEANUP_RUNNING','CLEANED_UP','RECOVERY_REQUIRED') }
    if ([string]$run.runId -cne $normalizedRunId -or -not [guid]::TryParse([string]$run.scopeId,[ref]$scopeGuid) -or
        [string]$run.state -notin $allowedStates) {
        throw 'LAB_ENVIRONMENT_GROUP_RUN_UNAVAILABLE'
    }
    $stateRootPath = if ($StateRoot) { $StateRoot } else { Get-LabStateRoot }
    $connectionPath = Join-Path (Join-Path (Join-Path $stateRootPath 'runs') $normalizedRunId) 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'LAB_ENVIRONMENT_GROUP_RUN_BINDING_MISSING' }
    $connectionBinding = Read-LabEnvironmentGroupConnectionInfo -Path $connectionPath
    $connection = $connectionBinding.Connection
    $instances = @($connection.instances)
    if ([string]$connection.runId -cne $normalizedRunId -or [string]$connection.scopeId -cne $scopeGuid.ToString('D') -or $instances.Count -eq 0) { throw 'LAB_ENVIRONMENT_GROUP_RUN_BINDING_INVALID' }
    $instanceIds = @($instances | ForEach-Object { [string]$_.id })
    if (@($instanceIds | Where-Object { $_ -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' }).Count -gt 0 -or
        @($instanceIds | Sort-Object -Unique).Count -ne $instanceIds.Count) { throw 'LAB_ENVIRONMENT_GROUP_RUN_BINDING_INVALID' }
    $freshRun = Get-LabRunState -RunId $normalizedRunId -StateRoot $StateRoot
    if ([string]$freshRun.scopeId -cne $scopeGuid.ToString('D')) {
        throw 'LAB_ENVIRONMENT_GROUP_RUN_BINDING_CHANGED'
    }
    return [PSCustomObject][ordered]@{
        runId = $normalizedRunId
        scopeId = $scopeGuid.ToString('D')
        instanceIds = @($instanceIds | Sort-Object)
        connectionInfoSha256 = $connectionBinding.Sha256
        assignedAt = Get-LabTimestamp
    }
}

function Sync-LabEnvironmentGroupMemberRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][ValidateSet('Start','Stop')][string]$Action,[string]$StateRoot)

    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $runtime = Get-LabRunRuntimeStatus -Run $run -StateRoot $StateRoot
    $instances = @($runtime.Instances)
    if ($instances.Count -eq 0 -or @($instances | Where-Object { [string]$_.State -in @('UNKNOWN','UNAVAILABLE') }).Count -gt 0) {
        throw "LAB_ENVIRONMENT_GROUP_MEMBER_RUNTIME_UNCONFIRMED: $RunId ($($runtime.State))"
    }
    $unsupportedStates = @($instances | Where-Object { [string]$_.State -notin @('RUNNING','STOPPED') })
    if ($unsupportedStates.Count -gt 0) {
        $details = @($unsupportedStates | ForEach-Object { '{0}:{1}' -f $_.Id,$_.State }) -join ','
        throw "LAB_ENVIRONMENT_GROUP_MEMBER_RUNTIME_UNSUPPORTED: $RunId ($details)"
    }
    $hasRunning = @($instances | Where-Object { [string]$_.State -eq 'RUNNING' }).Count -gt 0
    $hasStopped = @($instances | Where-Object { [string]$_.State -eq 'STOPPED' }).Count -gt 0
    if ($Action -eq 'Start' -and $hasRunning -and $hasStopped) {
        throw "LAB_ENVIRONMENT_GROUP_MEMBER_RUNTIME_PARTIAL: $RunId ($($runtime.State))"
    }
    $targetState = if ($hasRunning) { 'RUNNING' } else { 'STOPPED' }
    if ([string]$run.state -notin @('RUNNING','STOPPED')) {
        $current = [string]$run.state
        if ($current -eq 'PROVISION_FAILED') {
            $null = Set-LabRunState -RunId $RunId -NewState 'CLEANUP_PENDING' -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
            $current = 'CLEANUP_PENDING'
        }
        if ($current -eq 'CLEANUP_PENDING') {
            $null = Set-LabRunState -RunId $RunId -NewState 'CLEANUP_RUNNING' -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
            $current = 'CLEANUP_RUNNING'
        }
        if ($current -eq 'CLEANUP_RUNNING') {
            $null = Set-LabRunState -RunId $RunId -NewState 'RECOVERY_REQUIRED' -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
            $current = 'RECOVERY_REQUIRED'
        }
        if ($current -eq 'CLEANED_UP') {
            $null = Set-LabRunState -RunId $RunId -NewState 'RECOVERY_REQUIRED' -Reason 'Runtimeressourcen nach Gruppen-Recovery-Inventur vorhanden' -StateRoot $StateRoot
            $current = 'RECOVERY_REQUIRED'
        }
        if ($current -ne 'RECOVERY_REQUIRED') { throw "LAB_ENVIRONMENT_GROUP_MEMBER_STATE_UNRECOVERABLE: $RunId ($current)" }
        $null = Set-LabRunState -RunId $RunId -NewState $targetState -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
    }
    elseif ([string]$run.state -cne $targetState) {
        $null = Set-LabRunState -RunId $RunId -NewState $targetState -Reason 'Gruppen-Lifecycle nach Live-Runtimeinventur' -StateRoot $StateRoot
    }

    foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot)) {
        $providerInstances = @($instances | Where-Object { [string]$_.Provider -ieq [string]$providerSubRun.provider })
        if ($providerInstances.Count -eq 0 -or @($providerInstances | Where-Object { [string]$_.State -in @('UNKNOWN','UNAVAILABLE') }).Count -gt 0) {
            throw "LAB_ENVIRONMENT_GROUP_PROVIDER_RUNTIME_UNCONFIRMED: $RunId/$($providerSubRun.provider)"
        }
        if (@($providerInstances | Where-Object { [string]$_.State -notin @('RUNNING','STOPPED') }).Count -gt 0) {
            throw "LAB_ENVIRONMENT_GROUP_PROVIDER_RUNTIME_UNSUPPORTED: $RunId/$($providerSubRun.provider)"
        }
        $providerTarget = if (@($providerInstances | Where-Object { [string]$_.State -eq 'RUNNING' }).Count -gt 0) { 'RUNNING' } else { 'STOPPED' }
        $current = [string]$providerSubRun.state
        if ($current -in @('RUNNING','STOPPED')) {
            if ($current -cne $providerTarget) {
                Set-LabProviderSubRunState -RunId $RunId -Provider ([string]$providerSubRun.provider) -NewState $providerTarget -Reason 'Gruppen-Lifecycle nach Live-Runtimeinventur' -StateRoot $StateRoot
            }
            continue
        }
        if ($current -eq 'PROVISION_FAILED') {
            Set-LabProviderSubRunState -RunId $RunId -Provider ([string]$providerSubRun.provider) -NewState 'CLEANUP_PENDING' -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
            $current = 'CLEANUP_PENDING'
        }
        if ($current -eq 'CLEANUP_PENDING') {
            Set-LabProviderSubRunState -RunId $RunId -Provider ([string]$providerSubRun.provider) -NewState 'CLEANUP_RUNNING' -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
            $current = 'CLEANUP_RUNNING'
        }
        if ($current -eq 'CLEANUP_RUNNING') {
            Set-LabProviderSubRunState -RunId $RunId -Provider ([string]$providerSubRun.provider) -NewState 'RECOVERY_REQUIRED' -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
            $current = 'RECOVERY_REQUIRED'
        }
        if ($current -eq 'CLEANED_UP') {
            Set-LabProviderSubRunState -RunId $RunId -Provider ([string]$providerSubRun.provider) -NewState 'RECOVERY_REQUIRED' -Reason 'Runtimeressourcen nach Gruppen-Recovery-Inventur' -StateRoot $StateRoot
            $current = 'RECOVERY_REQUIRED'
        }
        if ($current -ne 'RECOVERY_REQUIRED') { throw "LAB_ENVIRONMENT_GROUP_PROVIDER_STATE_UNRECOVERABLE: $RunId/$($providerSubRun.provider) ($current)" }
        Set-LabProviderSubRunState -RunId $RunId -Provider ([string]$providerSubRun.provider) -NewState $providerTarget -Reason 'Gruppen-Recovery nach bestätigter Runtimeinventur' -StateRoot $StateRoot
    }
    return [PSCustomObject]@{Run=(Get-LabRunState -RunId $RunId -StateRoot $StateRoot);Runtime=$runtime}
}

function Read-LabEnvironmentGroupConnectionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $stream = [IO.MemoryStream]::new($bytes)
    $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
    try { $json = $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
    $connection = $json | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    return [PSCustomObject]@{Connection=$connection;Sha256=$hash}
}

<#
.SYNOPSIS
    Liest wiederverwendbare Lab-Umgebungsgruppen.
.DESCRIPTION
    Listet Gruppen oder liest eine Gruppe anhand ihrer stabilen GroupId. Beim
    Lesen einer einzelnen Gruppe wird jede gespeicherte Run-Bindung als
    CURRENT oder STALE ausgewiesen. Es werden keine Runtimeaktionen ausgeführt.
.PARAMETER GroupId
    Optionale GUID der zu lesenden Gruppe. Ohne Angabe werden alle Gruppen gelistet.
.PARAMETER StateRoot
    State-Root der Gruppen-Registry; ohne Angabe gilt der konfigurierte Standard.
.EXAMPLE
    Get-SqlServerLabEnvironmentGroup
.EXAMPLE
    Get-SqlServerLabEnvironmentGroup -GroupId $group.GroupId -StateRoot $stateRoot
.OUTPUTS
    System.Management.Automation.PSCustomObject. Gruppen-Metadaten und gebundene Mitglieder.
#>
function Get-SqlServerLabEnvironmentGroup {
    [CmdletBinding()]
    param([string]$GroupId,[string]$StateRoot)

    $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
    try {
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        if ([string]::IsNullOrWhiteSpace($GroupId)) { return @($registry.groups | Sort-Object name,groupId) }
        $id = [guid]::Empty
        if (-not [guid]::TryParse($GroupId, [ref]$id)) { throw 'LAB_ENVIRONMENT_GROUP_ID_INVALID' }
        $matches = @($registry.groups | Where-Object { [string]$_.groupId -ieq $id.ToString('D') })
        if ($matches.Count -ne 1) { throw 'LAB_ENVIRONMENT_GROUP_NOT_FOUND' }
        $group = $matches[0]
        foreach ($member in @($group.members)) {
            try {
                $current = Get-LabEnvironmentGroupMemberBinding -RunId ([string]$member.runId) -StateRoot $StateRoot
                $member | Add-Member -NotePropertyName bindingStatus -NotePropertyValue $(if ($current.scopeId -ceq [string]$member.scopeId -and $current.connectionInfoSha256 -ceq [string]$member.connectionInfoSha256 -and
                    (@($current.instanceIds) -join '|') -ceq (@($member.instanceIds) -join '|')) { 'CURRENT' } else { 'STALE' }) -Force
            }
            catch { $member | Add-Member -NotePropertyName bindingStatus -NotePropertyValue 'STALE' -Force }
        }
        return $group
    }
    finally { Exit-LabEnvironmentGroupsLock -Mutex $lock }
}

<#
.SYNOPSIS
    Erstellt eine leere Lab-Umgebungsgruppe.
.DESCRIPTION
    Registriert eine neue Gruppe getrennt von der geschützten automatisierten
    Testgruppe. Das Erstellen startet, stoppt oder löscht keine Umgebung.
.PARAMETER Name
    Eindeutiger Gruppenname mit 1 bis 80 Zeichen.
.PARAMETER StateRoot
    State-Root, an den die Gruppe gebunden wird; ohne Angabe gilt der Standard.
.EXAMPLE
    $group = (New-SqlServerLabEnvironmentGroup -Name 'Linked Server Demo').Group
.OUTPUTS
    System.Management.Automation.PSCustomObject. Status und neu angelegte Gruppe.
#>
function New-SqlServerLabEnvironmentGroup {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$Name,[string]$StateRoot)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -cne $Name.Trim() -or $Name.Length -gt 80 -or $Name -match '[\x00-\x1F\x7F]') {
        throw 'LAB_ENVIRONMENT_GROUP_NAME_INVALID'
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Lab-Umgebungsgruppe registrieren')) { return [PSCustomObject]@{Status='CANCELLED';Group=$null} }
    $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
    try {
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        if (@($registry.groups | Where-Object { [string]::Equals([string]$_.name,$Name,[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw 'LAB_ENVIRONMENT_GROUP_NAME_EXISTS' }
        $group = [PSCustomObject][ordered]@{
            groupId = [guid]::NewGuid().ToString('D')
            name = $Name
            stateRootKey = Get-LabEnvironmentGroupStateRootKey -StateRoot $StateRoot
            createdAt = Get-LabTimestamp
            lifecycleState = 'STOPPED'
            operation = $null
            members = @()
        }
        $registry.groups = @(@($registry.groups) + $group | Sort-Object name,groupId)
        Write-LabEnvironmentGroupsRegistry -Registry $registry -StateRoot $StateRoot
        return [PSCustomObject]@{Status='CREATED';Group=$group}
    }
    finally { Exit-LabEnvironmentGroupsLock -Mutex $lock }
}

<#
.SYNOPSIS
    Ordnet einen vorhandenen Lab-Run einer Gruppe zu.
.DESCRIPTION
    Bindet RunId, ScopeId, Instanz-IDs und den SHA-256-Hash der exakt gelesenen
    connection-info-Bytes. Derselbe Run darf mehreren Gruppen angehören.
    Diese Zuordnung ändert keinen Runtimezustand.
.PARAMETER GroupId
    GUID der Zielgruppe.
.PARAMETER RunId
    GUID eines vorhandenen RUNNING- oder STOPPED-Runs.
.PARAMETER StateRoot
    State-Root des Runs und der Gruppen-Registry; ohne Angabe gilt der Standard.
.EXAMPLE
    Add-SqlServerLabEnvironmentGroupMember -GroupId $group.GroupId -RunId $lab.RunId
.OUTPUTS
    System.Management.Automation.PSCustomObject. Ergebnis der Zuordnung und gebundener Member.
#>
function Add-SqlServerLabEnvironmentGroupMember {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$GroupId,[Parameter(Mandatory)][string]$RunId,[string]$StateRoot)

    $member = Get-LabEnvironmentGroupMemberBinding -RunId $RunId -StateRoot $StateRoot
    $stateRootKey = Get-LabEnvironmentGroupStateRootKey -StateRoot $StateRoot
    if (-not $PSCmdlet.ShouldProcess($member.runId, 'Run der Lab-Umgebungsgruppe zuordnen')) { return [PSCustomObject]@{Status='CANCELLED';Member=$null} }
    $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
    $runResourceLock = $null
    try {
        $runResourceLock = Enter-LabEnvironmentGroupRunResourceLock -RunId $member.runId -StateRoot $StateRoot
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        $id = [guid]::Empty
        if (-not [guid]::TryParse($GroupId, [ref]$id)) { throw 'LAB_ENVIRONMENT_GROUP_ID_INVALID' }
        $groups = @($registry.groups | Where-Object { [string]$_.groupId -ieq $id.ToString('D') })
        if ($groups.Count -ne 1) { throw 'LAB_ENVIRONMENT_GROUP_NOT_FOUND' }
        $group = $groups[0]
        Assert-LabEnvironmentGroupStoppedForMembershipChange -Group $group
        if ([string]$group.stateRootKey -cne $stateRootKey) { throw 'LAB_ENVIRONMENT_GROUP_STATE_ROOT_MISMATCH' }
        if (@($group.members | Where-Object { [string]$_.runId -ieq $member.runId }).Count -gt 0) { throw 'LAB_ENVIRONMENT_GROUP_MEMBER_EXISTS' }
        $freshMember = Get-LabEnvironmentGroupMemberBinding -RunId $member.runId -StateRoot $StateRoot
        if ($freshMember.scopeId -cne $member.scopeId -or $freshMember.connectionInfoSha256 -cne $member.connectionInfoSha256 -or
            (@($freshMember.instanceIds) -join '|') -cne (@($member.instanceIds) -join '|')) { throw 'LAB_ENVIRONMENT_GROUP_RUN_BINDING_CHANGED' }
        $protectionReason = Get-LabEnvironmentGroupMemberProtectionReason -RunId $member.runId -StateRoot $StateRoot
        if ($protectionReason) { throw "LAB_ENVIRONMENT_GROUP_MEMBER_PROTECTED: $($member.runId) ($protectionReason)" }
        $connectionPath = Join-Path (Join-Path (Join-Path $(if($StateRoot){$StateRoot}else{Get-LabStateRoot}) 'runs') $member.runId) 'connection-info.json'
        $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        Assert-LabEnvironmentGroupRunJournalsSettled -RunId $member.runId -Connection $connection -StateRoot $StateRoot
        $existingReferences = @($registry.groups | ForEach-Object {
            $registeredGroup = $_
            foreach ($registeredMember in @($registeredGroup.members | Where-Object { [string]$_.runId -ieq $member.runId })) {
                [PSCustomObject]@{StateRootKey=[string]$registeredGroup.stateRootKey;ScopeId=[string]$registeredMember.scopeId;ConnectionInfoSha256=[string]$registeredMember.connectionInfoSha256;InstanceIds=@($registeredMember.instanceIds)}
            }
        })
        foreach ($reference in $existingReferences) {
            if ($reference.StateRootKey -cne $stateRootKey -or $reference.ScopeId -cne $freshMember.scopeId -or
                $reference.ConnectionInfoSha256 -cne $freshMember.connectionInfoSha256 -or
                (@($reference.InstanceIds) -join '|') -cne (@($freshMember.instanceIds) -join '|')) {
                throw 'LAB_ENVIRONMENT_GROUP_RUN_IDENTITY_CONFLICT'
            }
        }
        $group.members = @(@($group.members) + $member | Sort-Object runId)
        $group.operation = $null
        Write-LabEnvironmentGroupsRegistry -Registry $registry -StateRoot $StateRoot
        return [PSCustomObject]@{Status='ADDED';GroupId=$group.groupId;Member=$member}
    }
    finally {
        if ($runResourceLock) { Exit-LabEnvironmentGroupRunResourceLock -Mutex $runResourceLock }
        Exit-LabEnvironmentGroupsLock -Mutex $lock
    }
}

<#
.SYNOPSIS
    Entfernt eine Run-Zuordnung aus einer Gruppe.
.DESCRIPTION
    Löst ausschließlich die Zuordnung. Der Run wird weder gestoppt noch entfernt.
.PARAMETER GroupId
    GUID der Gruppe.
.PARAMETER RunId
    GUID des zu lösenden Run-Mitglieds.
.PARAMETER StateRoot
    State-Root der Gruppen-Registry; ohne Angabe gilt der Standard.
.EXAMPLE
    Remove-SqlServerLabEnvironmentGroupMember -GroupId $group.GroupId -RunId $lab.RunId
.OUTPUTS
    System.Management.Automation.PSCustomObject. Ergebnis der Zuordnungsänderung.
#>
function Remove-SqlServerLabEnvironmentGroupMember {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$GroupId,[Parameter(Mandatory)][string]$RunId,[string]$StateRoot)

    $runGuid = [guid]::Empty
    $groupGuid = [guid]::Empty
    if (-not [guid]::TryParse($RunId,[ref]$runGuid)) { throw 'LAB_ENVIRONMENT_GROUP_RUN_ID_INVALID' }
    if (-not [guid]::TryParse($GroupId,[ref]$groupGuid)) { throw 'LAB_ENVIRONMENT_GROUP_ID_INVALID' }
    if (-not $PSCmdlet.ShouldProcess($runGuid.ToString('D'), 'Run-Zuordnung aus Lab-Umgebungsgruppe entfernen')) { return [PSCustomObject]@{Status='CANCELLED'} }
    $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
    $runResourceLock = $null
    try {
        $runResourceLock = Enter-LabEnvironmentGroupRunResourceLock -RunId $runGuid.ToString('D') -StateRoot $StateRoot
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        $groups = @($registry.groups | Where-Object { [string]$_.groupId -ieq $groupGuid.ToString('D') })
        if ($groups.Count -ne 1) { throw 'LAB_ENVIRONMENT_GROUP_NOT_FOUND' }
        $group = $groups[0]
        Assert-LabEnvironmentGroupStoppedForMembershipChange -Group $group
        $before = @($group.members).Count
        $group.members = @($group.members | Where-Object { [string]$_.runId -ine $runGuid.ToString('D') })
        if (@($group.members).Count -eq $before) { throw 'LAB_ENVIRONMENT_GROUP_MEMBER_NOT_FOUND' }
        $group.operation = $null
        Write-LabEnvironmentGroupsRegistry -Registry $registry -StateRoot $StateRoot
        return [PSCustomObject]@{Status='REMOVED';GroupId=$group.groupId;RunId=$runGuid.ToString('D')}
    }
    finally {
        if ($runResourceLock) { Exit-LabEnvironmentGroupRunResourceLock -Mutex $runResourceLock }
        Exit-LabEnvironmentGroupsLock -Mutex $lock
    }
}

<#
.SYNOPSIS
    Entfernt eine Lab-Umgebungsgruppe.
.DESCRIPTION
    Entfernt die Gruppe und alle ihre Zuordnungen. Zugeordnete Runs werden
    ausdrücklich nicht gestoppt oder gelöscht.
.PARAMETER GroupId
    GUID der zu entfernenden Gruppe.
.PARAMETER StateRoot
    State-Root der Gruppen-Registry; ohne Angabe gilt der Standard.
.EXAMPLE
    Remove-SqlServerLabEnvironmentGroup -GroupId $group.GroupId
.OUTPUTS
    System.Management.Automation.PSCustomObject. Entfernte Gruppen-ID und gelöste Run-IDs.
#>
function Remove-SqlServerLabEnvironmentGroup {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$GroupId,[string]$StateRoot)

    $groupGuid = [guid]::Empty
    if (-not [guid]::TryParse($GroupId,[ref]$groupGuid)) { throw 'LAB_ENVIRONMENT_GROUP_ID_INVALID' }
    if (-not $PSCmdlet.ShouldProcess($groupGuid.ToString('D'), 'Lab-Umgebungsgruppe und ihre Zuordnungen entfernen')) { return [PSCustomObject]@{Status='CANCELLED'} }
    $lock = Enter-LabEnvironmentGroupsLock -StateRoot $StateRoot
    try {
        $registry = Get-LabEnvironmentGroupsRegistry -StateRoot $StateRoot
        $matches = @($registry.groups | Where-Object { [string]$_.groupId -ieq $groupGuid.ToString('D') })
        if ($matches.Count -ne 1) { throw 'LAB_ENVIRONMENT_GROUP_NOT_FOUND' }
        Assert-LabEnvironmentGroupStoppedForMembershipChange -Group $matches[0]
        $registry.groups = @($registry.groups | Where-Object { [string]$_.groupId -ine $groupGuid.ToString('D') })
        Write-LabEnvironmentGroupsRegistry -Registry $registry -StateRoot $StateRoot
        return [PSCustomObject]@{Status='REMOVED';GroupId=$groupGuid.ToString('D');DetachedMembers=@($matches[0].members | ForEach-Object { [string]$_.runId })}
    }
    finally { Exit-LabEnvironmentGroupsLock -Mutex $lock }
}

<#
.SYNOPSIS
    Startet alle Mitglieder einer Lab-Umgebungsgruppe.
.DESCRIPTION
    Startet die eindeutigen, aktuell gebundenen Run-Mitglieder seriell. Die
    Aktivitätsansprüche werden vor Runtimeaktionen gespeichert. Teilfehler
    verbleiben fail-closed in RECOVERY_REQUIRED; Start wiederholt sie nicht.
.PARAMETER GroupId
    GUID der zu startenden Gruppe.
.PARAMETER StateRoot
    State-Root der Gruppe und Runs; ohne Angabe gilt der konfigurierte Standard.
.PARAMETER TimeoutSeconds
    Maximale SQL-Readiness-Wartezeit je Mitglied.
.PARAMETER SkipReadyCheck
    Überspringt die SQL-Readiness-Prüfung bei gestarteten Mitgliedern.
.EXAMPLE
    Start-SqlServerLabEnvironmentGroup -GroupId $group.GroupId
.OUTPUTS
    System.Management.Automation.PSCustomObject. Gruppenoperation und Mitgliederstatus.
#>
function Start-SqlServerLabEnvironmentGroup {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$GroupId,[string]$StateRoot,[int]$TimeoutSeconds=60,[switch]$SkipReadyCheck)
    if (-not $PSCmdlet.ShouldProcess($GroupId,'Lab-Umgebungsgruppe starten')) { return [PSCustomObject]@{Status='CANCELLED';GroupId=$GroupId} }
    Invoke-LabEnvironmentGroupLifecycle -GroupId $GroupId -Action Start -StateRoot $StateRoot -TimeoutSeconds $TimeoutSeconds -SkipReadyCheck:$SkipReadyCheck
}

<#
.SYNOPSIS
    Stoppt eine Lab-Umgebungsgruppe und gibt ihre Runtimeansprüche frei.
.DESCRIPTION
    Stoppt ein Mitglied nur, wenn keine andere aktive, startende, stoppende
    oder wiederherzustellende Gruppe es beansprucht. Gemeinsame Mitglieder
    bleiben laufen. Ungewisse Teilfehler behalten den Anspruch in RECOVERY_REQUIRED.
.PARAMETER GroupId
    GUID der zu stoppenden Gruppe.
.PARAMETER StateRoot
    State-Root der Gruppe und Runs; ohne Angabe gilt der konfigurierte Standard.
.PARAMETER Force
    Überspringt die CMS-Sicherheitsabfrage für betroffene Mitglieder.
.PARAMETER SkipHostMemoryRelease
    Unterdrückt die begrenzte WSL-Dateicache-Freigabe nach Container-Stop.
.EXAMPLE
    Stop-SqlServerLabEnvironmentGroup -GroupId $group.GroupId
.OUTPUTS
    System.Management.Automation.PSCustomObject. Gruppenoperation und Mitgliederstatus.
#>
function Stop-SqlServerLabEnvironmentGroup {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$GroupId,[string]$StateRoot,[switch]$Force,[switch]$SkipHostMemoryRelease)
    if (-not $PSCmdlet.ShouldProcess($GroupId,'Lab-Umgebungsgruppe stoppen')) { return [PSCustomObject]@{Status='CANCELLED';GroupId=$GroupId} }
    Invoke-LabEnvironmentGroupLifecycle -GroupId $GroupId -Action Stop -StateRoot $StateRoot -Force:$Force -SkipHostMemoryRelease:$SkipHostMemoryRelease
}
