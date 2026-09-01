<#
.SYNOPSIS
    Plant und repariert manifestgebundene Hyper-V-vCPU- und RAM-Drift.
.DESCRIPTION
    Der oeffentliche Plan enthaelt nur portable Ressourcenwerte. Der Executor
    revalidiert Run-, Scope-, Instanz- und VM-Identitaet, journalisiert jeden
    Zustandswechsel und fuehrt CPU-, RAM-Modus- oder Startup-Aenderungen bei
    laufenden VMs ueber Stop, Apply und Start aus. Bei dynamischem RAM duerfen
    ausschliessliche Min-/Max-Aenderungen live erfolgen.
#>

function Get-LabHyperVResourceReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-resource-reconcile.local.journal.json'
}

function Assert-LabHyperVResourceReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-resource-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_RESOURCE_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVResourceReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVResourceReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVResourceReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet(
            'PREPARED','STOPPED','RESOURCES_APPLIED','RESTARTED','VERIFIED',
            'COMPLETED','RECOVERY_REQUIRED'
        )][string]$Status,
        [string]$ErrorCode
    )
    $Journal.Status = $Status
    if ($ErrorCode) {
        $Journal.Recovery.ErrorCode = $ErrorCode
        $Journal.Recovery.Errors = @($Journal.Recovery.Errors) + @($ErrorCode)
    }
    if ($Status -eq 'COMPLETED') { $Journal.Recovery.Status = 'NOT_REQUIRED' }
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_RESOURCE_RECONCILE' }
    return Write-LabHyperVResourceReconcileJournal -Journal $Journal -Path $Path
}

function ConvertTo-LabHyperVResourceValues {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VM)

    foreach ($property in @('ProcessorCount','DynamicMemoryEnabled','MemoryStartup','State')) {
        if (-not $VM.PSObject.Properties[$property]) { throw "HYPERV_RESOURCE_RECONCILE_ACTUAL_PROPERTY_MISSING: $property" }
    }
    $dynamic = [bool]$VM.DynamicMemoryEnabled
    $startupMB = [int][Math]::Round(([decimal][long]$VM.MemoryStartup / 1MB), 0)
    $minimumMB = if ($dynamic -and $VM.PSObject.Properties['MemoryMinimum']) {
        [int][Math]::Round(([decimal][long]$VM.MemoryMinimum / 1MB), 0)
    }
    else { $startupMB }
    $maximumMB = if ($dynamic -and $VM.PSObject.Properties['MemoryMaximum']) {
        [int][Math]::Round(([decimal][long]$VM.MemoryMaximum / 1MB), 0)
    }
    else { $startupMB }
    [PSCustomObject]@{
        ProcessorCount=[int]$VM.ProcessorCount; DynamicMemoryEnabled=$dynamic
        MemoryMinimumMB=$minimumMB; MemoryStartupMB=$startupMB; MemoryMaximumMB=$maximumMB
        RuntimeState=[string]$VM.State
    }
}

function Get-LabHyperVResourceReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') { throw 'HYPERV_RESOURCE_RECONCILE_HYPERV_RUN_REQUIRED' }
    $guard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $guard.Allowed) { throw "HYPERV_RESOURCE_RECONCILE_MIGRATION_BLOCKED: $([string]$guard.ReasonCode)" }
    $targetState = if ([string]$run.state -eq 'STOPPED') { 'STOPPED' } else { 'RUNNING' }
    $desired = New-LabDesiredState -Run $run -TargetState $targetState -StateRoot $StateRoot
    if (-not $desired.IsValid) { throw 'HYPERV_RESOURCE_RECONCILE_DESIRED_STATE_INVALID' }
    $desiredInstances = @($desired.Instances | Where-Object { [string]$_.Id -eq $InstanceId -and [string]$_.Provider -eq 'hyperv' })
    if ($desiredInstances.Count -ne 1) { throw 'HYPERV_RESOURCE_RECONCILE_INSTANCE_NOT_UNIQUE' }
    $resourceIntent = $desiredInstances[0].Resources
    if (-not $resourceIntent -or -not $resourceIntent.Contract -or
        [string]$resourceIntent.Contract.Name -ne 'SqlServerLab.HyperVResourceIntent' -or
        [string]$resourceIntent.Contract.Version -ne '1.0') {
        throw 'HYPERV_RESOURCE_RECONCILE_INTENT_MISSING'
    }
    if ([string]$resourceIntent.CapabilityStatus -eq 'DECLARED_UNSUPPORTED') { throw 'HYPERV_RESOURCE_RECONCILE_INTENT_UNSUPPORTED' }
    if ([int]$resourceIntent.MemoryMinimumMB -gt [int]$resourceIntent.MemoryStartupMB -or
        [int]$resourceIntent.MemoryStartupMB -gt [int]$resourceIntent.MemoryMaximumMB) {
        throw 'HYPERV_RESOURCE_RECONCILE_INTENT_RANGE_INVALID'
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'HYPERV_RESOURCE_RECONCILE_CONNECTION_MISSING' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $instances = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv' })
    if ($instances.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$instances[0].vmName)) {
        throw 'HYPERV_RESOURCE_RECONCILE_CONNECTION_INSTANCE_NOT_UNIQUE'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$instances[0].vmName) `
        -ExpectedRunId $RunId -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed) { throw 'HYPERV_RESOURCE_RECONCILE_VM_NOT_FOUND' }
    if ($instances[0].vmId -and [string]$instances[0].vmId -ne [string]$managed.VM.Id) {
        throw 'HYPERV_RESOURCE_RECONCILE_VM_IDENTITY_MISMATCH'
    }
    [PSCustomObject]@{
        RunId=$RunId; ScopeId=[string]$run.scopeId; InstanceId=$InstanceId; StateRoot=$StateRoot
        Run=$run; RunDirectory=$runDirectory; Connection=$connection; ConnectionInstance=$instances[0]
        Desired=$resourceIntent; Managed=$managed; VM=$managed.VM; Actual=(ConvertTo-LabHyperVResourceValues -VM $managed.VM)
    }
}

function New-LabHyperVResourceReconcilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$InstanceId, [string]$StateRoot)

    try { $context = Get-LabHyperVResourceReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'HYPERV_RESOURCE_RECONCILE_UNAVAILABLE' }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVResourceReconcilePlan';Version='1.0'}
            RunId=$RunId; InstanceId=$InstanceId; Provider='hyperv'; Desired=$null; Actual=[PSCustomObject]@{Status='UNAVAILABLE';RuntimeState='UNAVAILABLE'}
            Diff=@(); Actions=@(); HighestChangeClass='unsupported'; IsNoOp=$false; MutationAllowed=$false
            Warnings=@('Der Hyper-V-Ressourcenzustand ist nicht eindeutig steuerbar.'); ReasonCodes=@($code)
        }
    }
    $fields = @('ProcessorCount','DynamicMemoryEnabled','MemoryMinimumMB','MemoryStartupMB','MemoryMaximumMB')
    $diff = @($fields | Where-Object { $context.Desired.$_ -ne $context.Actual.$_ } | ForEach-Object {
        [PSCustomObject]@{ Field=$_; Desired=$context.Desired.$_; Actual=$context.Actual.$_ }
    })
    $journalPath = Get-LabHyperVResourceReconcileJournalPath -RunDirectory $context.RunDirectory
    $pendingJournal = Read-LabHyperVResourceReconcileJournal -Path $journalPath -Context $context
    $recoveryPending = $pendingJournal -and [string]$pendingJournal.Status -ne 'COMPLETED'
    $state = [string]$context.Actual.RuntimeState
    $currentChangeClass = if ($diff.Count -eq 0) { 'no-op' }
        elseif ($state -eq 'Off') { 'live' }
        elseif ($state -eq 'Running' -and
            @($diff | Where-Object Field -notin @('MemoryMinimumMB','MemoryMaximumMB')).Count -eq 0 -and
            [bool]$context.Desired.DynamicMemoryEnabled -and [bool]$context.Actual.DynamicMemoryEnabled) { 'live' }
        elseif ($state -eq 'Running') { 'restart' }
        else { 'unsupported' }
    $changeClass = if (-not $recoveryPending) { $currentChangeClass }
        elseif ([string]$pendingJournal.ChangeClass -eq 'restart' -and $state -in @('Off','Running')) { 'restart' }
        elseif ([string]$pendingJournal.ChangeClass -eq 'live' -and $currentChangeClass -in @('no-op','live')) { 'live' }
        else { 'unsupported' }
    $repairKinds = @($diff | ForEach-Object {
        switch ([string]$_.Field) {
            'ProcessorCount' { 'processor-count' }
            'DynamicMemoryEnabled' { 'memory-mode' }
            'MemoryMinimumMB' { 'memory-minimum' }
            'MemoryStartupMB' { 'memory-startup' }
            'MemoryMaximumMB' { 'memory-maximum' }
        }
    } | Sort-Object -Unique)
    $actions = if ($changeClass -in @('live','restart')) {
        @([PSCustomObject]@{Operation=if($recoveryPending){'ResumeHyperVResources'}else{'RepairHyperVResources'};ChangeClass=$changeClass;RepairKinds=$repairKinds;RequiresRestart=($changeClass -eq 'restart');RecoveryPending=[bool]$recoveryPending})
    }
    else { @() }
    [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVResourceReconcilePlan';Version='1.0'}
        RunId=$RunId; InstanceId=$InstanceId; Provider='hyperv'
        Desired=[PSCustomObject]@{ProcessorCount=[int]$context.Desired.ProcessorCount;DynamicMemoryEnabled=[bool]$context.Desired.DynamicMemoryEnabled;MemoryMinimumMB=[int]$context.Desired.MemoryMinimumMB;MemoryStartupMB=[int]$context.Desired.MemoryStartupMB;MemoryMaximumMB=[int]$context.Desired.MemoryMaximumMB}
        Actual=[PSCustomObject]@{Status='AVAILABLE';RuntimeState=$state;ProcessorCount=[int]$context.Actual.ProcessorCount;DynamicMemoryEnabled=[bool]$context.Actual.DynamicMemoryEnabled;MemoryMinimumMB=[int]$context.Actual.MemoryMinimumMB;MemoryStartupMB=[int]$context.Actual.MemoryStartupMB;MemoryMaximumMB=[int]$context.Actual.MemoryMaximumMB}
        Diff=$diff; Actions=$actions; HighestChangeClass=$changeClass; IsNoOp=($changeClass -eq 'no-op'); MutationAllowed=$false
        Warnings=if($changeClass -eq 'restart'){@('CPU-, RAM-Modus- oder Startup-Drift erfordert Stop, Apply und Start.')}elseif($changeClass -eq 'unsupported'){@("VM-Zustand oder zwischenzeitliche Drift erlaubt keine sichere Ressourcenreparatur: '$state'.")}else{@()}
        ReasonCodes=@($(if($recoveryPending){'HYPERV_RESOURCE_RECONCILE_RECOVERY_PENDING'});$(if($changeClass -eq 'unsupported'){'HYPERV_RESOURCE_RECONCILE_VM_STATE_UNSUPPORTED'}))
    }
}

function Read-LabHyperVResourceReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $null = Assert-LabHyperVResourceReconcileJournal -Journal $journal
    if ([string]$journal.RunId -ne [string]$Context.RunId -or [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
        [string]$journal.InstanceId -ne [string]$Context.InstanceId -or [string]$journal.Runtime.VMId -ne [string]$Context.VM.Id) {
        throw 'HYPERV_RESOURCE_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    $targetChanged = @(@('ProcessorCount','DynamicMemoryEnabled','MemoryMinimumMB','MemoryStartupMB','MemoryMaximumMB') | Where-Object {
        $journal.Target.$_ -ne $Context.Desired.$_
    }).Count -gt 0
    if ($targetChanged) {
        if ([string]$journal.Status -eq 'COMPLETED') { return $null }
        throw 'HYPERV_RESOURCE_RECONCILE_JOURNAL_TARGET_MISMATCH'
    }
    return $journal
}

function Set-LabHyperVResourceConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $desired = $Context.Desired
    if ([int]$Context.Actual.ProcessorCount -ne [int]$desired.ProcessorCount) {
        $null = Set-VMProcessor -VM $Context.VM -Count ([int]$desired.ProcessorCount) -ErrorAction Stop
    }
    $memoryDrift = @(@('DynamicMemoryEnabled','MemoryMinimumMB','MemoryStartupMB','MemoryMaximumMB') | Where-Object {
        $Context.Actual.$_ -ne $desired.$_
    })
    if ($memoryDrift.Count -eq 0) { return }
    if ([string]$Context.Actual.RuntimeState -eq 'Running') {
        $null = Set-VMMemory -VM $Context.VM -DynamicMemoryEnabled $true `
            -MinimumBytes ([long][int]$desired.MemoryMinimumMB * 1MB) `
            -MaximumBytes ([long][int]$desired.MemoryMaximumMB * 1MB) -ErrorAction Stop
    }
    elseif ([bool]$desired.DynamicMemoryEnabled) {
        $null = Set-VMMemory -VM $Context.VM -DynamicMemoryEnabled $true `
            -MinimumBytes ([long][int]$desired.MemoryMinimumMB * 1MB) `
            -StartupBytes ([long][int]$desired.MemoryStartupMB * 1MB) `
            -MaximumBytes ([long][int]$desired.MemoryMaximumMB * 1MB) -ErrorAction Stop
    }
    else {
        $null = Set-VMMemory -VM $Context.VM -DynamicMemoryEnabled $false `
            -StartupBytes ([long][int]$desired.MemoryStartupMB * 1MB) -ErrorAction Stop
    }
}

function Wait-LabHyperVResourceReconcileVMState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][ValidateSet('Off','Running')][string]$ExpectedState,
        [ValidateRange(10, 300)][int]$TimeoutSeconds=120
    )
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $managed=Get-HyperVManagedVM -VMName $VMName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId
        if($managed -and [string]$managed.VM.State -eq $ExpectedState){return $managed}
        Start-Sleep -Seconds 2
    } while([DateTime]::UtcNow -lt $deadline)
    throw "HYPERV_RESOURCE_RECONCILE_VM_STATE_TIMEOUT: $ExpectedState"
}

function Invoke-LabHyperVResourceReconcileRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$InstanceId, [string]$StateRoot)

    $mutex = [Threading.Mutex]::new($false, "Global\SQL_Server_Lab_HyperV_Resource_Reconcile_$($RunId.Replace('-', ''))")
    $acquired=$false; $journal=$null; $journalPath=$null
    try {
        $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5)); if(-not $acquired){throw 'HYPERV_RESOURCE_RECONCILE_LOCK_TIMEOUT'}
        $context=Get-LabHyperVResourceReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $journalPath=Get-LabHyperVResourceReconcileJournalPath -RunDirectory $context.RunDirectory
        $journal=Read-LabHyperVResourceReconcileJournal -Path $journalPath -Context $context
        $plan=New-LabHyperVResourceReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        if($journal -and [string]$journal.Status -ne 'COMPLETED'){$journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED' -and $plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
        elseif($journal -and [string]$journal.Status -eq 'COMPLETED'){$journal=$null}
        if(-not $journal){
            if($plan.IsNoOp){return [PSCustomObject]@{Status='NO_OP';RunId=$RunId;InstanceId=$InstanceId;Changed=$false;RepairKinds=@()}}
            if([string]$plan.HighestChangeClass -notin @('live','restart') -or @($plan.Actions).Count -ne 1){throw 'HYPERV_RESOURCE_RECONCILE_UNSUPPORTED'}
            $journal=[PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVResourceReconcileJournal/1.0';OperationId=[Guid]::NewGuid().ToString('D')
                RunId=$RunId;ScopeId=[string]$context.ScopeId;InstanceId=$InstanceId;Provider='hyperv';ChangeClass=[string]$plan.HighestChangeClass;Status='PREPARED'
                Target=[PSCustomObject]@{ProcessorCount=[int]$context.Desired.ProcessorCount;DynamicMemoryEnabled=[bool]$context.Desired.DynamicMemoryEnabled;MemoryMinimumMB=[int]$context.Desired.MemoryMinimumMB;MemoryStartupMB=[int]$context.Desired.MemoryStartupMB;MemoryMaximumMB=[int]$context.Desired.MemoryMaximumMB}
                Runtime=[PSCustomObject]@{VMId=[string]$context.VM.Id;OriginalState=[string]$context.Actual.RuntimeState}
                Recovery=[PSCustomObject]@{Status='RETRY_RESOURCE_RECONCILE';Attempts=0;ErrorCode=$null;Errors=@()};UpdatedAt=Get-LabTimestamp
            }
            $null=Write-LabHyperVResourceReconcileJournal -Journal $journal -Path $journalPath
        }

        $requiresRestart=[string]$journal.ChangeClass -eq 'restart'
        $context=Get-LabHyperVResourceReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        $currentDrift=@(@('ProcessorCount','DynamicMemoryEnabled','MemoryMinimumMB','MemoryStartupMB','MemoryMaximumMB') | Where-Object {$context.Actual.$_ -ne $context.Desired.$_})
        if(-not $requiresRestart -and [string]$context.Actual.RuntimeState -eq 'Running' -and
            (@($currentDrift | Where-Object {$_ -notin @('MemoryMinimumMB','MemoryMaximumMB')}).Count -gt 0 -or
             -not [bool]$context.Desired.DynamicMemoryEnabled -or -not [bool]$context.Actual.DynamicMemoryEnabled)){
            throw 'HYPERV_RESOURCE_RECONCILE_LIVE_PRECONDITION_FAILED'
        }
        if($requiresRestart -and [string]$context.Actual.RuntimeState -eq 'Running'){
            $null=Stop-VM -VM $context.VM -Confirm:$false -ErrorAction Stop
            $null=Wait-LabHyperVResourceReconcileVMState -VMName ([string]$context.ConnectionInstance.vmName) -RunId $RunId -ScopeId ([string]$context.ScopeId) -ExpectedState Off
            $null=Set-LabHyperVResourceReconcileJournalStatus -Journal $journal -Path $journalPath -Status STOPPED
            $context=Get-LabHyperVResourceReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        }
        if($requiresRestart -and [string]$context.Actual.RuntimeState -ne 'Off'){throw 'HYPERV_RESOURCE_RECONCILE_STOP_POSTCONDITION_FAILED'}
        $currentDrift=@(@('ProcessorCount','DynamicMemoryEnabled','MemoryMinimumMB','MemoryStartupMB','MemoryMaximumMB') | Where-Object {$context.Actual.$_ -ne $context.Desired.$_})
        $currentMatches=$currentDrift.Count -eq 0
        if(-not $currentMatches){
            Set-LabHyperVResourceConfiguration -Context $context
            $null=Set-LabHyperVResourceReconcileJournalStatus -Journal $journal -Path $journalPath -Status RESOURCES_APPLIED
        }
        $context=Get-LabHyperVResourceReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
        $resourceDrift=@(@('ProcessorCount','DynamicMemoryEnabled','MemoryMinimumMB','MemoryStartupMB','MemoryMaximumMB') | Where-Object {$context.Actual.$_ -ne $context.Desired.$_})
        if($resourceDrift.Count -gt 0){throw "HYPERV_RESOURCE_RECONCILE_POSTCONDITION_FAILED: $($resourceDrift -join ',')"}
        if($requiresRestart -and [string]$journal.Runtime.OriginalState -eq 'Running' -and [string]$context.Actual.RuntimeState -ne 'Running'){
            $null=Start-VM -VM $context.VM -ErrorAction Stop
            $null=Wait-LabHyperVResourceReconcileVMState -VMName ([string]$context.ConnectionInstance.vmName) -RunId $RunId -ScopeId ([string]$context.ScopeId) -ExpectedState Running
            $null=Set-LabHyperVResourceReconcileJournalStatus -Journal $journal -Path $journalPath -Status RESTARTED
            $context=Get-LabHyperVResourceReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $context.StateRoot
            if([string]$context.Actual.RuntimeState -ne 'Running'){throw 'HYPERV_RESOURCE_RECONCILE_RESTART_POSTCONDITION_FAILED'}
        }
        $context.ConnectionInstance | Add-Member -NotePropertyName resourceSettings -NotePropertyValue ([PSCustomObject]@{
            contractVersion='SqlServerLab.HyperVResourceIntent/1.0';processorCount=[int]$context.Desired.ProcessorCount;dynamicMemoryEnabled=[bool]$context.Desired.DynamicMemoryEnabled
            memoryMinimumMB=[int]$context.Desired.MemoryMinimumMB;memoryStartupMB=[int]$context.Desired.MemoryStartupMB;memoryMaximumMB=[int]$context.Desired.MemoryMaximumMB;updatedAt=Get-LabTimestamp
        }) -Force
        Write-LabArtifactJsonAtomic -Path (Join-Path $context.RunDirectory 'connection-info.json') -InputObject $context.Connection
        $null=Set-LabHyperVResourceReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
        $null=Set-LabHyperVResourceReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        [PSCustomObject]@{Status='SUCCEEDED';RunId=$RunId;InstanceId=$InstanceId;Changed=$true;RepairKinds=if(@($plan.Actions).Count){@($plan.Actions[0].RepairKinds)}else{@()};JournalStatus='COMPLETED'}
    }
    catch{
        $code=if($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}'){[string]$Matches[0]}else{'HYPERV_RESOURCE_RECONCILE_FAILED'}
        if($journal -and $journalPath){try{$null=Set-LabHyperVResourceReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_REQUIRED -ErrorCode $code}catch{};throw "HYPERV_RESOURCE_RECONCILE_RECOVERY_REQUIRED: $code"}
        throw
    }
    finally{if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
}
