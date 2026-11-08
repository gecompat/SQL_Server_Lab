function Get-UiEnvironmentGroupsView {
    [CmdletBinding()]
    param()

    $groups = @(Get-SqlServerLabEnvironmentGroup -IncludeBindingStatus)
    $projectedGroups = @(
        foreach ($group in $groups) {
            $operation = $null
            if ($null -ne $group.operation) {
                $operation = [ordered]@{
                    action = [string]$group.operation.action
                    state = [string]$group.operation.state
                    startedAt = [string]$group.operation.startedAt
                    updatedAt = [string]$group.operation.updatedAt
                    members = @(
                        foreach ($memberOperation in @($group.operation.members)) {
                            [ordered]@{
                                runId = [string]$memberOperation.runId
                                action = [string]$memberOperation.action
                                status = [string]$memberOperation.status
                            }
                        }
                    )
                }
            }
            [ordered]@{
                groupId = [string]$group.groupId
                name = [string]$group.name
                createdAt = [string]$group.createdAt
                lifecycleState = [string]$group.lifecycleState
                operation = $operation
                members = @(
                    foreach ($member in @($group.members)) {
                        [ordered]@{
                            runId = [string]$member.runId
                            instanceIds = @($member.instanceIds | ForEach-Object { [string]$_ })
                            assignedAt = [string]$member.assignedAt
                            bindingStatus = [string]$member.bindingStatus
                        }
                    }
                )
            }
        }
    )

    [ordered]@{
        contractVersion = 'SqlServerLab.EnvironmentGroups.BrowserView/1.2'
        groups = $projectedGroups
    }
}

function Get-LabEnvironmentGroupRunStateFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$RunState)

    try {
        $json = ConvertTo-Json -InputObject $RunState -Depth 40 -Compress -ErrorAction Stop
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
        return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
    }
    catch {
        return $null
    }
}

function Get-LabEnvironmentGroupRuntimeObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GroupId, [Parameter(Mandatory)][string]$RunId, [string]$StateRoot)

    $groupGuid = [guid]::Empty
    $runGuid = [guid]::Empty
    if (-not [guid]::TryParse($GroupId, [ref]$groupGuid) -or -not [guid]::TryParse($RunId, [ref]$runGuid)) {
        throw 'ENVIRONMENT_GROUP_RUNTIME_REQUEST_INVALID'
    }
    $groupId = $groupGuid.ToString('D')
    $runId = $runGuid.ToString('D')
    $stateRoot = if ($StateRoot) { $StateRoot } else { Get-LabStateRoot }
    $groupParameters = @{ GroupId = $groupId; StateRoot = $stateRoot; IncludeBindingStatus = $true }
    $group = Get-SqlServerLabEnvironmentGroup @groupParameters
    if ($null -eq $group) { throw 'ENVIRONMENT_GROUP_NOT_FOUND' }
    $members = @($group.members | Where-Object { [string]$_.runId -ieq $runId })
    if ($members.Count -ne 1) { throw 'ENVIRONMENT_GROUP_MEMBER_NOT_FOUND' }
    $member = $members[0]
    $memberScopeId = [string]$member.scopeId
    $memberConnectionInfoSha256 = [string]$member.connectionInfoSha256
    $memberIds = @($member.instanceIds | ForEach-Object { [string]$_ } | Sort-Object)
    $observedAt = [datetime]::UtcNow.ToString('o')
    $savedState = 'UNKNOWN'
    $runtimeState = 'UNKNOWN'
    $reconciliation = 'INDETERMINATE'
    $instanceResults = @()

    if ([string]$member.bindingStatus -ceq 'CURRENT') {
        $runs = @(Get-LabRunState -RunId $runId -StateRoot $stateRoot)
        if ($runs.Count -eq 1 -and [string]$runs[0].runId -ceq $runId) {
            $run = $runs[0]
            $runStateFingerprint = Get-LabEnvironmentGroupRunStateFingerprint -RunState $run
            $savedState = if ([string]$run.state -in @('RUNNING', 'STOPPED')) { [string]$run.state } else { 'OTHER' }
            $connectionPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $runId) 'connection-info.json'
            if ($runStateFingerprint -and ([string]$run.scopeId -ceq $memberScopeId) -and (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
                try {
                    $connectionBytes = [System.IO.File]::ReadAllBytes($connectionPath)
                    $connectionHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($connectionBytes))
                    $connection = [System.Text.Encoding]::UTF8.GetString($connectionBytes) | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                    $connectionIds = @($connection.instances | ForEach-Object { [string]$_.id } | Sort-Object)
                    if ($connectionHash -ceq $memberConnectionInfoSha256 -and (@($connectionIds) -join '|') -ceq (@($memberIds) -join '|')) {
                        $runtimeObservationDeadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds(30)
                        foreach ($instance in @($connection.instances | Sort-Object id)) {
                            $provider = ([string]$instance.provider).ToLowerInvariant()
                            try {
                                $status = switch ($provider) {
                                    'docker' {
                                        if ([DateTimeOffset]::UtcNow -lt $runtimeObservationDeadlineUtc) { Get-DockerInstanceStatus -ContainerIdOrName ([string]$instance.containerId) -StateRoot $stateRoot -TimeoutSeconds 30 -DeadlineUtc $runtimeObservationDeadlineUtc }
                                        else { $null }
                                    }
                                    'podman' {
                                        if ([DateTimeOffset]::UtcNow -lt $runtimeObservationDeadlineUtc) { Get-PodmanInstanceStatus -ContainerIdOrName ([string]$instance.containerId) -StateRoot $stateRoot -TimeoutSeconds 30 -DeadlineUtc $runtimeObservationDeadlineUtc }
                                        else { $null }
                                    }
                                    'hyperv' { Get-HyperVInstanceStatus -VMName ([string]$instance.vmName) -ExpectedRunId $runId -ExpectedScopeId ([string]$run.scopeId) }
                                    default { $null }
                                }
                                $instanceState = if ($null -eq $status) { 'UNAVAILABLE' }
                                    elseif ($status.PSObject.Properties['Available'] -and -not [bool]$status.Available) { 'UNAVAILABLE' }
                                    elseif (-not [bool]$status.Exists) { 'MISSING' }
                                    elseif ($provider -eq 'hyperv') {
                                        if ([string]$status.State -ceq 'Running') { 'RUNNING' }
                                        elseif ([string]$status.State -ceq 'Off') { 'STOPPED' }
                                        else { 'OTHER' }
                                    }
                                    elseif ([string]$status.Raw -ceq 'running') { 'RUNNING' }
                                    elseif ([string]$status.Raw -ceq 'exited') { 'STOPPED' }
                                    else { 'OTHER' }
                            }
                            catch { $instanceState = 'UNAVAILABLE' }
                            $instanceResults += [ordered]@{ instanceId=[string]$instance.id; provider=$provider; state=$instanceState }
                        }
                        $states = @($instanceResults | ForEach-Object { [string]$_.state })
                        if ($states.Count -eq 0) { $runtimeState = 'UNKNOWN' }
                        elseif ($states -contains 'UNAVAILABLE') { $runtimeState = 'UNAVAILABLE' }
                        elseif ($states -contains 'MISSING') { $runtimeState = 'MISSING' }
                        elseif ($states -contains 'OTHER') { $runtimeState = 'OTHER' }
                        elseif (@($states | Where-Object { $_ -eq 'RUNNING' }).Count -eq $states.Count) { $runtimeState = 'RUNNING' }
                        elseif (@($states | Where-Object { $_ -eq 'STOPPED' }).Count -eq $states.Count) { $runtimeState = 'STOPPED' }
                        else { $runtimeState = 'PARTIAL' }
                        if ($savedState -in @('RUNNING', 'STOPPED') -and $runtimeState -in @('RUNNING', 'STOPPED')) {
                            $reconciliation = if ($savedState -ceq $runtimeState) { 'CURRENT' } else { 'DRIFT' }
                        }
                        else { $reconciliation = 'INDETERMINATE' }

                        $bindingStillCurrent = $false
                        $runStateStillCurrent = $false
                        try {
                            $latestGroup = Get-SqlServerLabEnvironmentGroup @groupParameters
                            $latestMembers = @($latestGroup.members | Where-Object { [string]$_.runId -ieq $runId })
                            if ($latestMembers.Count -eq 1) {
                                $latestMember = $latestMembers[0]
                                $latestRuns = @(Get-LabRunState -RunId $runId -StateRoot $stateRoot)
                                if ($latestRuns.Count -eq 1 -and [string]$latestRuns[0].runId -ceq $runId -and
                                    [string]$latestRuns[0].scopeId -ceq [string]$run.scopeId -and
                                    [string]$latestMember.scopeId -ceq $memberScopeId -and
                                    [string]$latestMember.connectionInfoSha256 -ceq $memberConnectionInfoSha256 -and
                                    (@($latestMember.instanceIds | ForEach-Object { [string]$_ } | Sort-Object) -join '|') -ceq (@($member.instanceIds | ForEach-Object { [string]$_ } | Sort-Object) -join '|')) {
                                    $latestBytes = [System.IO.File]::ReadAllBytes($connectionPath)
                                    $latestHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($latestBytes))
                                    $latestConnection = [System.Text.Encoding]::UTF8.GetString($latestBytes) | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                                    $latestIds = @($latestConnection.instances | ForEach-Object { [string]$_.id } | Sort-Object)
                                    $bindingStillCurrent = $latestHash -ceq $connectionHash -and
                                        [string]$latestConnection.runId -ieq $runId -and
                                        [string]$latestConnection.scopeId -ceq [string]$run.scopeId -and
                                        (@($latestIds) -join '|') -ceq (@($memberIds) -join '|')
                                    $latestRunStateFingerprint = Get-LabEnvironmentGroupRunStateFingerprint -RunState (Get-LabRunState -RunId $runId -StateRoot $stateRoot)
                                    $runStateStillCurrent = $latestRunStateFingerprint -and $latestRunStateFingerprint -ceq $runStateFingerprint
                                }
                            }
                        }
                        catch { $bindingStillCurrent = $false }
                        if (-not $bindingStillCurrent) {
                            $savedState = 'UNKNOWN'
                            $runtimeState = 'STALE_BINDING'
                            $reconciliation = 'INDETERMINATE'
                            $instanceResults = @()
                        }
                        elseif (-not $runStateStillCurrent) {
                            $savedState = 'UNKNOWN'
                            $runtimeState = 'UNKNOWN'
                            $reconciliation = 'INDETERMINATE'
                            $instanceResults = @()
                        }
                    }
                    else { $runtimeState = 'STALE_BINDING' }
                }
                catch { $runtimeState = 'STALE_BINDING' }
            }
            else { $runtimeState = 'STALE_BINDING' }
        }
        else { $runtimeState = 'MISSING' }
    }
    else { $runtimeState = 'STALE_BINDING' }

    $observedAt = [datetime]::UtcNow.ToString('o')
    [ordered]@{
        contractVersion = 'SqlServerLab.EnvironmentGroups.RuntimeObservation/1.0'
        groupId = $groupId
        runId = $runId
        observedAt = $observedAt
        savedState = $savedState
        runtimeState = $runtimeState
        reconciliation = $reconciliation
        instances = @($instanceResults)
    }
}
