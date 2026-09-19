#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Adapter-Reconnect ausschliesslich an einem operationseigenen Test-Run.
.DESCRIPTION
    Innerhalb des SqlServerLab-Modulscopes laden. Der aufrufende native Runner
    erzeugt und entfernt den SQL-Test-Run und prueft SQL vor/nach diesem Schritt.
    Dieser Helfer erzeugt weder VM noch Switch, NAT oder Host-IP-Konfiguration.
    Bei Fehlern wird ausschliesslich die vorher verifizierte Adapterbindung
    wiederhergestellt; eine fremde Bindung bleibt unveraendert.
#>
function Invoke-HyperVNetworkReconnectAcceptanceStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$InstanceId = 'primary'
    )
    $ErrorActionPreference = 'Stop'
    $owned = Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
    if (-not $owned -or [string]$owned.runId -ne $RunId) {
        throw 'HYPERV_NETWORK_ACCEPTANCE_OPERATION_OWNERSHIP_REQUIRED'
    }
    $context = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    if ($context.Adapters.Count -ne 1 -or @($context.BoundPlan.Actions).Count -ne 0 -or
        [string]$context.BoundPlan.Status -ne 'READY' -or [string]$context.Actual.Status -ne 'MATCHED' -or
        [string]$context.DesiredInstance.Network.Intent -ne 'hostOnly') {
        throw 'HYPERV_NETWORK_ACCEPTANCE_MATCHED_HOSTONLY_REQUIRED'
    }
    $vmId = [string]$context.VM.Id
    $adapterId = [string]$context.Adapters[0].Id
    $switchName = [string]$context.ExpectedSwitchName
    if (-not $vmId -or -not $adapterId -or -not $switchName -or
        [string]$context.Adapters[0].SwitchName -ne $switchName) {
        throw 'HYPERV_NETWORK_ACCEPTANCE_INITIAL_BINDING_INVALID'
    }
    $journalPath = Get-LabHyperVNetworkReconcileJournalPath -RunDirectory $context.RunDirectory
    if (Test-Path -LiteralPath $journalPath) { throw 'HYPERV_NETWORK_ACCEPTANCE_FRESH_RUN_REQUIRED' }
    $disconnected = $false
    $primaryFailure = $null
    try {
        # Der Caller muss den exklusiven Runtime-Testlock bereits halten.
        $disconnected = $true
        Disconnect-VMNetworkAdapter -VMNetworkAdapter $context.Adapters[0] -ErrorAction Stop
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVNetwork -InstanceId $InstanceId -StateRoot $StateRoot
        if ($plan.HighestChangeClass -ne 'live' -or @($plan.Actions).Count -ne 1 -or
            @($plan.Actions[0].RepairKinds).Count -ne 1 -or $plan.Actions[0].RepairKinds[0] -ne 'adapter-reconnect') {
            throw 'HYPERV_NETWORK_ACCEPTANCE_RECONNECT_ONLY_REQUIRED'
        }
        $preview = Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVNetwork -InstanceId $InstanceId -StateRoot $StateRoot -WhatIf
        $observed = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ([string]$observed.VM.Id -ne $vmId -or $observed.Adapters.Count -ne 1 -or
            [string]$observed.Adapters[0].Id -ne $adapterId -or [string]$observed.ExpectedSwitchName -ne $switchName) {
            throw 'HYPERV_NETWORK_ACCEPTANCE_PRE_APPLY_IDENTITY_CHANGED'
        }
        if ($preview.ExecutionSummary.Status -ne 'WOULD_EXECUTE' -or (Test-Path -LiteralPath $journalPath) -or
            $observed.Adapters.Count -ne 1 -or [string]$observed.Adapters[0].SwitchName) {
            throw 'HYPERV_NETWORK_ACCEPTANCE_WHATIF_MUTATED'
        }
        $result = Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVNetwork -InstanceId $InstanceId -StateRoot $StateRoot -Confirm:$false
        $after = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -Depth 30
        $noOp = Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVNetwork -InstanceId $InstanceId -StateRoot $StateRoot
        if ($result.ExecutionSummary.Status -ne 'SUCCEEDED' -or $journal.Status -ne 'COMPLETED' -or
            [string]$after.VM.Id -ne $vmId -or $after.Adapters.Count -ne 1 -or
            [string]$after.Adapters[0].Id -ne $adapterId -or [string]$after.Adapters[0].SwitchName -ne $switchName -or
            -not $noOp.IsNoOp -or @($noOp.Actions).Count -ne 0) {
            throw 'HYPERV_NETWORK_ACCEPTANCE_POSTCONDITION_FAILED'
        }
        $disconnected = $false
        [pscustomobject]@{ Status='PASS'; Scope='HOST_ADAPTER_RECONNECT'; SqlEvidence='NOT_EXECUTED'; JournalStatus='COMPLETED' }
    }
    catch {
        $primaryFailure = $_.Exception
        throw
    }
    finally {
        if ($disconnected) {
            try {
                $recovery = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
                if ([string]$recovery.VM.Id -ne $vmId -or $recovery.Adapters.Count -ne 1 -or
                    [string]$recovery.Adapters[0].Id -ne $adapterId -or [string]$recovery.ExpectedSwitchName -ne $switchName) {
                    throw 'HYPERV_NETWORK_ACCEPTANCE_RECOVERY_IDENTITY_CHANGED'
                }
                if (-not [string]$recovery.Adapters[0].SwitchName) {
                    Connect-VMNetworkAdapter -VMNetworkAdapter $recovery.Adapters[0] -SwitchName $switchName -ErrorAction Stop
                }
                elseif ([string]$recovery.Adapters[0].SwitchName -ne $switchName) {
                    throw 'HYPERV_NETWORK_ACCEPTANCE_RECOVERY_FOREIGN_BINDING'
                }
                $verified = Get-LabHyperVNetworkReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
                if ([string]$verified.VM.Id -ne $vmId -or $verified.Adapters.Count -ne 1 -or
                    [string]$verified.Adapters[0].Id -ne $adapterId -or [string]$verified.Adapters[0].SwitchName -ne $switchName) {
                    throw 'HYPERV_NETWORK_ACCEPTANCE_RECOVERY_POSTCONDITION_FAILED'
                }
            }
            catch {
                if ($primaryFailure) {
                    throw [AggregateException]::new('HYPERV_NETWORK_ACCEPTANCE_AND_RECOVERY_FAILED', [Exception[]]@($primaryFailure, $_.Exception))
                }
                throw
            }
        }
    }
}
