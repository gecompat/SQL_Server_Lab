function Get-LabHyperVAutoStartJournalPath { param([Parameter(Mandatory)][string]$RunDirectory) Join-Path $RunDirectory 'hyperv-autostart-journal.json' }
function Read-LabHyperVAutoStartJournal {
    param([Parameter(Mandatory)]$Lab)
    $path = Get-LabHyperVAutoStartJournalPath -RunDirectory $Lab.RunDirectory
    if (-not (Test-Path -LiteralPath $path)) { return }
    $journal = Read-LabDiagnosticJson -Path $path -MaximumBytes 16384 -MaximumDepth 12
    if (-not (($journal | ConvertTo-Json -Depth 12) | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'hyperv-autostart-journal.schema.json') -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_AUTOSTART_JOURNAL_SCHEMA_INVALID'
    }
    if ([string]$journal.RunId -cne [string]$Lab.Run.runId -or [string]$journal.ScopeId -cne [string]$Lab.Run.scopeId -or
        [string]$journal.InstanceId -cne [string]$Lab.Instance.id) {
        throw 'HYPERV_AUTOSTART_RECOVERY_JOURNAL_INVALID'
    }
    $journal
}

function Get-LabHyperVAutoStartRecoveryPlan {
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot,[guid]$ExpectedRecoveryOperationId)
    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $journal = Read-LabHyperVAutoStartJournal -Lab $lab
    if (-not $journal) { throw 'HYPERV_AUTOSTART_RECOVERY_JOURNAL_MISSING' }
    if ($PSBoundParameters.ContainsKey('ExpectedRecoveryOperationId') -and
        $ExpectedRecoveryOperationId.ToString('D') -cne [string]$journal.OperationId) {
        throw 'HYPERV_AUTOSTART_RECOVERY_SELECTION_CHANGED'
    }
    if ($journal.Status -cnotin @('PREPARED', 'POLICY_MUTATED', 'STATE_COMMITTED', 'RECOVERY_REQUIRED')) {
        throw 'HYPERV_AUTOSTART_RECOVERY_JOURNAL_INVALID'
    }
    $plan = Get-LabHyperVAutoStartApplyPlan -RunId $RunId -AutoStart ([string]$journal.Target.AutoStart) -StateRoot $lab.StateRoot
    if ([string]$plan.Managed.VM.Id -cne [string]$journal.Runtime.VMId -or
        [string]$plan.Managed.VM.State -cne [string]$journal.Before.State -or
        [string]$plan.Managed.VM.AutomaticStartAction -cne [string]$journal.Target.AutomaticStartAction) {
        throw 'HYPERV_AUTOSTART_RECOVERY_READBACK_CHANGED'
    }
    $null = Assert-LabHyperVResourceMigrationLifecycleAllowed -RunId $RunId -Operation 'SET_AUTOSTART' -StateRoot $lab.StateRoot
    Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $lab.StateRoot
    [pscustomobject]@{ Plan = $plan; Journal = $journal }
}

function Write-LabHyperVAutoStartJournal {
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp
    if(-not(($Journal|ConvertTo-Json -Depth 30)|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'hyperv-autostart-journal.schema.json') -ErrorAction SilentlyContinue)){throw 'HYPERV_AUTOSTART_JOURNAL_SCHEMA_INVALID'}
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal;$Journal
}
function Complete-LabHyperVAutoStartState {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Journal)
    $lab=Get-HyperVLabWorkflowRun -RunId ([string]$Journal.RunId) -StateRoot $Plan.Lab.StateRoot
    $managed=Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if(-not $managed -or [string]$managed.VM.Id -ne [string]$Journal.Runtime.VMId -or [string]$managed.VM.State -ne [string]$Journal.Before.State -or [string]$managed.VM.AutomaticStartAction -ne [string]$Journal.Target.AutomaticStartAction){throw 'HYPERV_AUTOSTART_POSTCONDITION_FAILED'}
    $desired=@($lab.Run.metadata.desiredState.Instances|Where-Object{[string]$_.Id -eq [string]$lab.Instance.id -and [string]$_.Provider -eq 'hyperv'})
    if($desired.Count-ne1){throw 'HYPERV_LAB_AUTOSTART_DESIRED_STATE_INVALID'}
    $lab.Instance|Add-Member -NotePropertyName autostart -NotePropertyValue ([string]$Journal.Target.AutoStart) -Force
    $lab.Run.metadata|Add-Member -NotePropertyName autostart -NotePropertyValue ([string]$Journal.Target.AutoStart) -Force
    $desired[0].AutoStart=[string]$Journal.Target.AutoStart;$lab.Run.updatedAt=Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'connection-info.json') -InputObject $lab.Connection
    Write-LabArtifactJsonAtomic -Path (Join-Path $lab.RunDirectory 'run-state.json') -InputObject $lab.Run
}
