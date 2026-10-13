function Get-LabContainerAutoStartApplyPlan {
    <#
    .SYNOPSIS
    Binds a direct container restart-policy change to one measured runtime.
    .DESCRIPTION
    This is intentionally an internal plan. Its hash is executor input, not a
    public diagnostic DTO: it includes the full runtime identity and therefore
    must never be returned by a browser or general plan endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('on','off')][string]$AutoStart,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $StateRoot = Get-LabCanonicalResourceRoot -StateRoot $StateRoot
    Assert-LabResourceChangeAllowed -RunId $RunId -StateRoot $StateRoot
    $context = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $subRuns = @(Get-LabProviderSubRuns -RunId $RunId -StateRoot $StateRoot | Where-Object {
        [string]$_.provider -eq [string]$context.Provider
    })
    if ([string]$context.Run.state -notin @('RUNNING','STOPPED') -or $subRuns.Count -ne 1 -or
        [string]$subRuns[0].state -notin @('RUNNING','STOPPED')) {
        throw 'AUTOSTART_APPLY_LIFECYCLE_BLOCKED'
    }
    if ([string]$context.ContainerId -notmatch '^[a-f0-9]{64}$' -or
        [string]$context.Inspect.Id -cne [string]$context.ContainerId -or
        [string]$context.Inspect.Config.Labels.'sql-server-lab.instance-id' -cne $InstanceId) {
        throw 'AUTOSTART_APPLY_RUNTIME_BINDING_INVALID'
    }
    if ([string]$context.CurrentAutoStart -notin @('on','off')) {
        throw 'AUTOSTART_APPLY_POLICY_UNKNOWN'
    }
    $persisted = Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot
    if ([string]$persisted.Status -ne 'VALID') { throw 'AUTOSTART_APPLY_DESIRED_STATE_INVALID' }
    $desiredInstances = @($persisted.Snapshot.Instances | Where-Object {
        [string]$_.Id -ceq $InstanceId -and [string]$_.Provider -ceq [string]$context.Provider
    })
    if ($desiredInstances.Count -ne 1 -or [string]$desiredInstances[0].AutoStart -notin @('on','off')) {
        throw 'AUTOSTART_APPLY_DESIRED_INSTANCE_INVALID'
    }
    $reconcileJournalPath = Get-LabContainerReconcileJournalPath -RunDirectory $context.RunDirectory
    if (Test-Path -LiteralPath $reconcileJournalPath -PathType Leaf) {
        $journal = Get-Content -LiteralPath $reconcileJournalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
        $null = Assert-LabContainerReconcileJournal -Journal $journal
        if ([string]$journal.Status -notin @('COMPLETED','ROLLED_BACK')) { throw 'AUTOSTART_APPLY_RECONCILE_JOURNAL_BLOCKED' }
    }
    $autoStartJournalPath = Get-LabContainerAutoStartJournalPath -RunDirectory $context.RunDirectory
    if (Test-Path -LiteralPath $autoStartJournalPath -PathType Leaf) {
        $journal = Get-Content -LiteralPath $autoStartJournalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
        Assert-LabContainerAutoStartJournal -Journal $journal
        if ([string]$journal.RunId -ne $RunId -or [string]$journal.ScopeId -ne [string]$context.Run.scopeId -or
            [string]$journal.InstanceId -ne $InstanceId -or [string]$journal.Provider -ne [string]$context.Provider -or
            [string]$journal.Status -notin @('COMPLETED')) { throw 'AUTOSTART_APPLY_JOURNAL_BLOCKED' }
    }
    $targetPolicy = if ($AutoStart -eq 'on') { 'unless-stopped' } else { 'no' }
    $binding = [ordered]@{
        Root = $StateRoot; Run = $RunId; Scope = [string]$context.Run.scopeId
        Instance = $InstanceId; Provider = [string]$context.Provider; RuntimeId = [string]$context.ContainerId
        WasRunning = [bool]$context.WasRunning; RunState = [string]$context.Run.state
        ProviderState = [string]$subRuns[0].state; CurrentAutoStart = [string]$context.CurrentAutoStart
        CurrentRestartPolicy = [string]$context.CurrentRestartPolicy; PersistedAutoStart = [string]$desiredInstances[0].AutoStart
        DesiredAutoStart = $AutoStart; TargetRestartPolicy = $targetPolicy
    }
    $planKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes(($binding | ConvertTo-Json -Depth 12 -Compress)))).ToLowerInvariant()
    return [pscustomobject]@{
        Context = $context; DesiredInstance = $desiredInstances[0]; TargetAutoStart = $AutoStart
        TargetRestartPolicy = $targetPolicy; RuntimeMutationRequired = ([string]$context.CurrentAutoStart -ne $AutoStart)
        StateMutationRequired = ([string]$desiredInstances[0].AutoStart -ne $AutoStart)
        NoChange = ([string]$context.CurrentAutoStart -eq $AutoStart -and [string]$desiredInstances[0].AutoStart -eq $AutoStart)
        PlanKey = $planKey
    }
}
function Get-LabContainerAutoStartJournalPath {
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'container-autostart-journal.json'
}

function Assert-LabContainerAutoStartJournal {
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'container-autostart-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 60) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'AUTOSTART_APPLY_JOURNAL_SCHEMA_INVALID'
    }
}

function Write-LabContainerAutoStartJournal {
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    Assert-LabContainerAutoStartJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    $Journal
}

function New-LabContainerAutoStartJournal {
    param([Parameter(Mandatory)]$Plan)
    $context = $Plan.Context
    $journal = [pscustomobject]@{
        ContractVersion = 'SqlServerLab.ContainerAutoStartJournal/1.0'; OperationId = [guid]::NewGuid().ToString('D')
        RunId = [string]$context.RunId; ScopeId = [string]$context.Run.scopeId; InstanceId = [string]$context.InstanceId
        Provider = [string]$context.Provider; Status = 'PREPARED'
        Before = [pscustomobject]@{ AutoStart=[string]$context.CurrentAutoStart; RestartPolicy=[string]$context.CurrentRestartPolicy; Running=[bool]$context.WasRunning; PersistedAutoStart=[string]$Plan.DesiredInstance.AutoStart }
        Target = [pscustomobject]@{ AutoStart=[string]$Plan.TargetAutoStart; RestartPolicy=[string]$Plan.TargetRestartPolicy }
        Runtime = [pscustomobject]@{ OriginalId=[string]$context.ContainerId }
        PreviousConnection = $context.Connection; PreviousDesiredState = $context.Run.metadata.desiredState
        Recovery = [pscustomobject]@{ Status='RESUME_STATE_COMMIT'; Attempts=0; ErrorCode=$null }
        UpdatedAt = Get-LabTimestamp
    }
    $path = Get-LabContainerAutoStartJournalPath -RunDirectory $context.RunDirectory
    $null = Write-LabContainerAutoStartJournal -Journal $journal -Path $path
    [pscustomobject]@{ Journal=$journal; Path=$path }
}
