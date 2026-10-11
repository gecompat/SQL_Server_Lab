function Get-LabHyperVAutoStartJournalPath { param([Parameter(Mandatory)][string]$RunDirectory) Join-Path $RunDirectory 'hyperv-autostart-journal.json' }
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
