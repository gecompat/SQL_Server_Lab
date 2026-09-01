<#
.SYNOPSIS
    Plant und repariert eng begrenzte Hyper-V-Netzwerkdrift.
.DESCRIPTION
    Der oeffentliche Plan bleibt hostwertfrei. Die lokale Ausfuehrung bindet
    Run, Scope, VM und den bereits persistierten Network Bound Plan erneut,
    journalisiert additive Infrastrukturaktionen und verbindet hoechstens
    einen vorhandenen, getrennten VM-Adapter wieder mit dem erwarteten Switch.
    Rebinding, Adapter-Neuanlage und Gastadressreparatur bleiben fail-closed.
#>

function Get-LabHyperVNetworkReconcileJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    Join-Path $RunDirectory 'hyperv-network-reconcile.local.journal.json'
}

function Assert-LabHyperVNetworkReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-network-reconcile-journal.schema.json'
    if (-not (($Journal | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_NETWORK_RECONCILE_JOURNAL_SCHEMA_INVALID'
    }
    return $true
}

function Write-LabHyperVNetworkReconcileJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    $null = Assert-LabHyperVNetworkReconcileJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVNetworkReconcileJournalStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet(
            'PREPARED','INFRASTRUCTURE_READY','ATTACHMENT_READY','VERIFIED',
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
    elseif ($Status -eq 'RECOVERY_REQUIRED') { $Journal.Recovery.Status = 'RETRY_NETWORK_RECONCILE' }
    return Write-LabHyperVNetworkReconcileJournal -Journal $Journal -Path $Path
}

function Read-LabHyperVNetworkReconcileJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Context
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $null = Assert-LabHyperVNetworkReconcileJournal -Journal $journal
    if ([string]$journal.RunId -ne [string]$Context.RunId -or
        [string]$journal.ScopeId -ne [string]$Context.ScopeId -or
        [string]$journal.InstanceId -ne [string]$Context.DesiredInstance.Id -or
        [string]$journal.Runtime.VMId -ne [string]$Context.VM.Id) {
        throw 'HYPERV_NETWORK_RECONCILE_JOURNAL_IDENTITY_MISMATCH'
    }
    if ([string]$journal.Status -notin @(
        'COMPLETED','RECOVERY_REQUIRED','PREPARED','INFRASTRUCTURE_READY','ATTACHMENT_READY','VERIFIED'
    )) {
        throw 'HYPERV_NETWORK_RECONCILE_JOURNAL_STATUS_INVALID'
    }
    return $journal
}

function Resolve-LabHyperVNetworkReconcileBoundPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$ConnectionInstance,
        [Parameter(Mandatory)][ValidateSet('hostOnly','nat','lan')][string]$Intent
    )

    if (-not $ConnectionInstance.labNetwork -or
        [string]::IsNullOrWhiteSpace([string]$ConnectionInstance.labNetwork.name)) {
        throw 'HYPERV_NETWORK_RECONCILE_BOUND_PLAN_MISSING'
    }
    if ($Intent -eq 'lan') {
        $boundPlanPath = Join-Path $RunDirectory 'network-bound-plan.json'
        if (-not (Test-Path -LiteralPath $boundPlanPath -PathType Leaf)) {
            throw 'HYPERV_NETWORK_RECONCILE_BOUND_PLAN_MISSING'
        }
        $persisted = Get-Content -LiteralPath $boundPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        if ([string]$persisted.Name -ne [string]$ConnectionInstance.labNetwork.name) {
            throw 'HYPERV_NETWORK_RECONCILE_BOUND_PLAN_MISMATCH'
        }
        return Resolve-LabHyperVNetworkBoundPlan -Intent lan `
            -LanSwitchName ([string]$persisted.Name) -LanAdapterId ([string]$persisted.AdapterId)
    }
    return Resolve-LabHyperVNetworkBoundPlan -Intent $Intent `
        -SwitchName ([string]$ConnectionInstance.labNetwork.name) `
        -Subnet ([string]$ConnectionInstance.labNetwork.subnet)
}

function Get-LabHyperVNetworkReconcileContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ([string]$run.metadata.workflowKind -ne 'hyperv-lab') {
        throw 'HYPERV_NETWORK_RECONCILE_HYPERV_RUN_REQUIRED'
    }
    $migrationGuard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $migrationGuard.Allowed) {
        throw "HYPERV_NETWORK_RECONCILE_MIGRATION_BLOCKED: $([string]$migrationGuard.ReasonCode)"
    }
    $targetState = if ([string]$run.state -eq 'STOPPED') { 'STOPPED' } else { 'RUNNING' }
    $desired = New-LabDesiredState -Run $run -TargetState $targetState -StateRoot $StateRoot
    if (-not $desired.IsValid) { throw 'HYPERV_NETWORK_RECONCILE_DESIRED_STATE_INVALID' }
    $desiredInstances = @($desired.Instances | Where-Object {
        [string]$_.Id -eq $InstanceId -and [string]$_.Provider -eq 'hyperv'
    })
    if ($desiredInstances.Count -ne 1 -or -not $desiredInstances[0].Network) {
        throw 'HYPERV_NETWORK_RECONCILE_INSTANCE_NOT_UNIQUE'
    }
    $desiredInstance = $desiredInstances[0]
    if ([string]$desiredInstance.Network.PlanStatus -ne 'RESOLVED' -or
        [string]$desiredInstance.Network.CapabilityStatus -eq 'DECLARED_UNSUPPORTED' -or
        [string]$desiredInstance.Network.Intent -notin @('hostOnly','nat','lan')) {
        throw 'HYPERV_NETWORK_RECONCILE_INTENT_UNSUPPORTED'
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        throw 'HYPERV_NETWORK_RECONCILE_CONNECTION_INFO_MISSING'
    }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $connectionInstances = @($connection.instances | Where-Object {
        [string]$_.id -eq $InstanceId -and [string]$_.provider -eq 'hyperv'
    })
    if ($connectionInstances.Count -ne 1) { throw 'HYPERV_NETWORK_RECONCILE_INSTANCE_BINDING_INVALID' }
    $connectionInstance = $connectionInstances[0]
    $expectedSwitchName = [string]$connectionInstance.labNetwork.name
    if ([string]::IsNullOrWhiteSpace($expectedSwitchName)) {
        throw 'HYPERV_NETWORK_RECONCILE_BOUND_PLAN_MISSING'
    }

    $workflow = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed = Get-HyperVManagedVM -VMName ([string]$workflow.Instance.vmName) `
        -ExpectedRunId ([string]$run.runId) -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed -or -not $managed.VM) { throw 'HYPERV_NETWORK_RECONCILE_MANAGED_VM_REQUIRED' }
    $adapters = @(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop)
    $boundPlan = Resolve-LabHyperVNetworkReconcileBoundPlan -RunDirectory $runDirectory `
        -ConnectionInstance $connectionInstance -Intent ([string]$desiredInstance.Network.Intent)
    $actual = Get-LabHyperVNetworkReconcileActual -Run $run -DesiredInstance $desiredInstance -StateRoot $StateRoot

    return [PSCustomObject]@{
        Run=$run; RunId=$RunId; ScopeId=[string]$run.scopeId; RunDirectory=$runDirectory
        StateRoot=$StateRoot; DesiredInstance=$desiredInstance; ConnectionInstance=$connectionInstance
        Workflow=$workflow; Managed=$managed; VM=$managed.VM; Adapters=$adapters
        ExpectedSwitchName=$expectedSwitchName; BoundPlan=$boundPlan; Actual=$actual
        MigrationGuard=$migrationGuard
    }
}

function New-LabHyperVNetworkReconcilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    $context = $null
    $reasonCodes = [Collections.Generic.List[string]]::new()
    try { $context = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'HYPERV_NETWORK_RECONCILE_CONTEXT_UNAVAILABLE' }
        $reasonCodes.Add($code)
    }

    $repairKinds = [Collections.Generic.List[string]]::new()
    $requiresExternalSwitchApproval = $false
    $changeClass = 'unsupported'
    $actualStatus = 'UNAVAILABLE'
    $actualAttachment = 'UNAVAILABLE'
    $actualInfrastructure = 'UNAVAILABLE'
    $actualGuestAddress = 'UNOBSERVED'
    $intent = $null
    $binding = $null
    if ($context) {
        $intent = [string]$context.DesiredInstance.Network.Intent
        $binding = [string]$context.DesiredInstance.Network.Binding
        $actualStatus = [string]$context.Actual.Status
        $actualAttachment = [string]$context.Actual.AttachmentStatus
        $actualInfrastructure = [string]$context.Actual.InfrastructureStatus
        $actualGuestAddress = [string]$context.Actual.GuestAddressStatus
        foreach ($code in @($context.Actual.ReasonCodes)) { if ($code) { $reasonCodes.Add([string]$code) } }

        if ([string]$context.BoundPlan.Status -ne 'READY') {
            foreach ($code in @($context.BoundPlan.Blockers)) { if ($code) { $reasonCodes.Add([string]$code) } }
        }
        else {
            $infrastructureActions = @($context.BoundPlan.Actions)
            if ($infrastructureActions.Count -gt 0) {
                $repairKinds.Add('infrastructure')
                $requiresExternalSwitchApproval = $infrastructureActions -contains 'create-external-switch'
            }

            if ($context.Adapters.Count -eq 0) {
                $reasonCodes.Add('HYPERV_NETWORK_ADAPTER_OBJECT_MISSING')
            }
            elseif ($context.Adapters.Count -gt 1) {
                $reasonCodes.Add('HYPERV_NETWORK_ADAPTER_COUNT_DRIFT')
            }
            else {
                $adapterSwitch = [string]$context.Adapters[0].SwitchName
                if ([string]::IsNullOrWhiteSpace($adapterSwitch)) { $repairKinds.Add('adapter-reconnect') }
                elseif (-not [string]::Equals($adapterSwitch, [string]$context.ExpectedSwitchName, [StringComparison]::OrdinalIgnoreCase)) {
                    $reasonCodes.Add('HYPERV_NETWORK_SWITCH_BINDING_DRIFT')
                }
            }
            if ($actualGuestAddress -eq 'DRIFT') { $reasonCodes.Add('HYPERV_NETWORK_GUEST_ADDRESS_DRIFT') }

            if ($repairKinds.Count -eq 0 -and $actualStatus -eq 'MATCHED') {
                $journalPath = Get-LabHyperVNetworkReconcileJournalPath -RunDirectory $context.RunDirectory
                try {
                    $existingJournal = Read-LabHyperVNetworkReconcileJournal -Path $journalPath -Context $context
                    if ($existingJournal -and [string]$existingJournal.Status -ne 'COMPLETED') {
                        $repairKinds.Add('recovery-finalize')
                        $reasonCodes.Add('HYPERV_NETWORK_RECONCILE_RECOVERY_PENDING')
                    }
                }
                catch {
                    $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') {
                        [string]$Matches[0]
                    } else { 'HYPERV_NETWORK_RECONCILE_JOURNAL_INVALID' }
                    $reasonCodes.Add($code)
                }
            }
        }

        $hardReasons = @($reasonCodes | Where-Object {
            $_ -notin @(
                'HYPERV_NETWORK_ADAPTER_MISSING','HYPERV_NETWORK_INFRASTRUCTURE_DRIFT',
                'HYPERV_NETWORK_RECONCILE_RECOVERY_PENDING'
            )
        } | Sort-Object -Unique)
        if ($hardReasons.Count -eq 0 -and $repairKinds.Count -gt 0) { $changeClass = 'live' }
        elseif ($hardReasons.Count -eq 0 -and $actualStatus -eq 'MATCHED') { $changeClass = 'no-op' }
    }

    $actions = if ($changeClass -eq 'live') {
        @([PSCustomObject]@{
            Operation='RepairNetwork'; Provider='hyperv'; InstanceId=$InstanceId
            RepairKinds=@($repairKinds | Sort-Object -Unique)
            RequiresExternalSwitchApproval=$requiresExternalSwitchApproval
        })
    } else { @() }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVNetworkReconcilePlan'; Version='1.0' }
        RunId=$RunId; InstanceId=$InstanceId
        Desired=[PSCustomObject]@{ Intent=$intent; Binding=$binding }
        Actual=[PSCustomObject]@{
            Status=$actualStatus; AttachmentStatus=$actualAttachment
            InfrastructureStatus=$actualInfrastructure; GuestAddressStatus=$actualGuestAddress
            ReasonCodes=@($reasonCodes | Sort-Object -Unique)
        }
        Diff=@([PSCustomObject]@{
            Kind='network'; ChangeClass=$changeClass
            ReasonCodes=@($reasonCodes | Sort-Object -Unique)
        })
        Actions=$actions; HighestChangeClass=$changeClass; IsNoOp=$changeClass -eq 'no-op'
        MutationAllowed=$false
        Warnings=if ($changeClass -eq 'live') {
            @('Nur additive Hostinfrastruktur und ein vorhandener getrennter Adapter werden repariert; der Executor revalidiert Run, Scope und VM erneut.')
        } elseif ($changeClass -eq 'unsupported') {
            @('Die erkannte Netzwerkdrift ist nicht automatisch reparierbar und bleibt unverändert.')
        } else { @() }
    }
}

function Invoke-LabHyperVNetworkReconcileRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [switch]$AllowExternalSwitchCreation,
        [string]$StateRoot
    )

    $mutex = [Threading.Mutex]::new($false, "Global\SQL_Server_Lab_HyperV_Network_Reconcile_$($RunId.Replace('-', ''))")
    $acquired = $false
    $journal = $null
    $journalPath = $null
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(5))
        if (-not $acquired) { throw 'HYPERV_NETWORK_RECONCILE_LOCK_TIMEOUT' }
        $plan = New-LabHyperVNetworkReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($plan.IsNoOp) {
            return [PSCustomObject]@{ Status='NO_OP'; RunId=$RunId; InstanceId=$InstanceId; Changed=$false; RepairKinds=@() }
        }
        if ([string]$plan.HighestChangeClass -ne 'live' -or @($plan.Actions).Count -ne 1) {
            throw "HYPERV_NETWORK_RECONCILE_UNSUPPORTED: $(@($plan.Actual.ReasonCodes) -join ',')"
        }
        if ([bool]$plan.Actions[0].RequiresExternalSwitchApproval -and -not $AllowExternalSwitchCreation) {
            throw 'HYPERV_NETWORK_RECONCILE_EXTERNAL_SWITCH_APPROVAL_REQUIRED'
        }

        $context = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if (@($context.BoundPlan.Actions) -contains 'create-external-switch' -and -not $AllowExternalSwitchCreation) {
            throw 'HYPERV_NETWORK_RECONCILE_EXTERNAL_SWITCH_APPROVAL_REQUIRED'
        }
        $journalPath = Get-LabHyperVNetworkReconcileJournalPath -RunDirectory $context.RunDirectory
        $existing = Read-LabHyperVNetworkReconcileJournal -Path $journalPath -Context $context
        if ($existing) {
            if ([string]$existing.Status -ne 'COMPLETED') {
                $journal = $existing
                $journal.Recovery.Attempts = [int]$journal.Recovery.Attempts + 1
            }
        }
        if (-not $journal) {
            $adapter = if ($context.Adapters.Count -eq 1) { $context.Adapters[0] } else { $null }
            $journal = [PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVNetworkReconcileJournal/1.0'
                OperationId=[Guid]::NewGuid().ToString('D'); RunId=$RunId; ScopeId=[string]$context.ScopeId
                InstanceId=$InstanceId; Provider='hyperv'; ChangeClass='live'; Status='PREPARED'
                Target=[PSCustomObject]@{
                    Intent=[string]$context.DesiredInstance.Network.Intent
                    ExpectedSwitchName=[string]$context.ExpectedSwitchName
                    ReconnectAdapter=@($plan.Actions[0].RepairKinds) -contains 'adapter-reconnect'
                    InfrastructureActions=@($context.BoundPlan.Actions)
                }
                Runtime=[PSCustomObject]@{
                    VMId=[string]$context.VM.Id
                    AdapterId=if ($adapter -and $adapter.PSObject.Properties['Id']) { [string]$adapter.Id } else { $null }
                }
                Recovery=[PSCustomObject]@{ Status='RETRY_NETWORK_RECONCILE'; Attempts=0; ErrorCode=$null; Errors=@() }
                UpdatedAt=Get-LabTimestamp
            }
            $null = Write-LabHyperVNetworkReconcileJournal -Journal $journal -Path $journalPath
        }

        $context = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ([string]$journal.Target.Intent -ne [string]$context.DesiredInstance.Network.Intent -or
            [string]$journal.Target.ExpectedSwitchName -ne [string]$context.ExpectedSwitchName) {
            throw 'HYPERV_NETWORK_RECONCILE_JOURNAL_TARGET_MISMATCH'
        }
        $unexpectedInfrastructureActions = @($context.BoundPlan.Actions | Where-Object {
            [string]$_ -notin @($journal.Target.InfrastructureActions)
        })
        if ($unexpectedInfrastructureActions.Count -gt 0) {
            throw 'HYPERV_NETWORK_RECONCILE_INFRASTRUCTURE_PRECONDITION_CHANGED'
        }
        if ([string]$context.Actual.Status -eq 'MATCHED') {
            $null = Set-LabHyperVNetworkReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
            $null = Set-LabHyperVNetworkReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
            return [PSCustomObject]@{
                Status='SUCCEEDED'; RunId=$RunId; InstanceId=$InstanceId; Changed=$false
                RepairKinds=@($plan.Actions[0].RepairKinds); JournalStatus='COMPLETED'
            }
        }
        if ([bool]$journal.Target.ReconnectAdapter) {
            if ($context.Adapters.Count -ne 1 -or -not [string]::IsNullOrWhiteSpace([string]$context.Adapters[0].SwitchName)) {
                throw 'HYPERV_NETWORK_RECONCILE_ADAPTER_PRECONDITION_CHANGED'
            }
            if ($journal.Runtime.AdapterId -and $context.Adapters[0].PSObject.Properties['Id'] -and
                [string]$journal.Runtime.AdapterId -ne [string]$context.Adapters[0].Id) {
                throw 'HYPERV_NETWORK_RECONCILE_ADAPTER_IDENTITY_MISMATCH'
            }
        }

        $null = Invoke-LabHyperVNetworkBoundPlan -Plan $context.BoundPlan
        $null = Set-LabHyperVNetworkReconcileJournalStatus -Journal $journal -Path $journalPath -Status INFRASTRUCTURE_READY
        if ([bool]$journal.Target.ReconnectAdapter) {
            Connect-VMNetworkAdapter -VMNetworkAdapter $context.Adapters[0] `
                -SwitchName ([string]$context.ExpectedSwitchName) -ErrorAction Stop
        }
        $null = Set-LabHyperVNetworkReconcileJournalStatus -Journal $journal -Path $journalPath -Status ATTACHMENT_READY

        $context = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ([string]$context.Actual.Status -ne 'MATCHED' -or
            [string]$context.Actual.AttachmentStatus -ne 'MATCHED' -or
            [string]$context.Actual.InfrastructureStatus -notin @('MATCHED','NOT_APPLICABLE')) {
            throw 'HYPERV_NETWORK_RECONCILE_POSTCONDITION_FAILED'
        }
        $null = Set-LabHyperVNetworkReconcileJournalStatus -Journal $journal -Path $journalPath -Status VERIFIED
        $null = Set-LabHyperVNetworkReconcileJournalStatus -Journal $journal -Path $journalPath -Status COMPLETED
        return [PSCustomObject]@{
            Status='SUCCEEDED'; RunId=$RunId; InstanceId=$InstanceId; Changed=$true
            RepairKinds=@($plan.Actions[0].RepairKinds); JournalStatus='COMPLETED'
        }
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'HYPERV_NETWORK_RECONCILE_FAILED' }
        if ($journal -and $journalPath) {
            try { $null = Set-LabHyperVNetworkReconcileJournalStatus -Journal $journal -Path $journalPath -Status RECOVERY_REQUIRED -ErrorCode $code }
            catch { }
        }
        if ($journal -and $journalPath) {
            throw "HYPERV_NETWORK_RECONCILE_RECOVERY_REQUIRED: $code"
        }
        throw
    }
    finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}
