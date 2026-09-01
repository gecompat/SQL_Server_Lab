#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den eigentumsgebundenen Hyper-V-Netzwerk-Reconcile ohne Hostmutation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Hyper-V Network Reconcile Checks' -ForegroundColor Cyan
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-hyperv-network-reconcile-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $module = Get-Module SqlServerLab
    $evidence = & $module {
        param($Root)

        function New-TestContext {
            param(
                [string]$AdapterMode='matched',
                [string[]]$InfrastructureActions=@(),
                [string]$GuestAddressStatus='MATCHED',
                [string]$RunDirectory=(Join-Path $Root ([guid]::NewGuid().ToString('D')))
            )
            New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
            $runId = Split-Path -Leaf $RunDirectory
            $adapters = switch ($AdapterMode) {
                'missing' { @() }
                'multiple' { @(
                    [PSCustomObject]@{ Id='adapter-a'; SwitchName='SQL_LAB_HYPERV' },
                    [PSCustomObject]@{ Id='adapter-b'; SwitchName='SQL_LAB_HYPERV' }
                ) }
                'disconnected' { @([PSCustomObject]@{ Id='adapter-a'; SwitchName=$null }) }
                'wrong' { @([PSCustomObject]@{ Id='adapter-a'; SwitchName='FOREIGN_SWITCH' }) }
                default { @([PSCustomObject]@{ Id='adapter-a'; SwitchName='SQL_LAB_HYPERV' }) }
            }
            [PSCustomObject]@{
                Run=[PSCustomObject]@{ runId=$runId; scopeId=[guid]::NewGuid().ToString('D'); state='RUNNING' }
                RunId=$runId; ScopeId=$null; RunDirectory=$RunDirectory; StateRoot=$Root
                DesiredInstance=[PSCustomObject]@{
                    Id='primary'; Provider='hyperv'
                    Network=[PSCustomObject]@{ Intent='hostOnly'; Binding='internal-switch' }
                }
                ExpectedSwitchName='SQL_LAB_HYPERV'
                VM=[PSCustomObject]@{ Id=[guid]::NewGuid().ToString('D'); Name='host-value-must-not-leak' }
                Adapters=$adapters
                BoundPlan=[PSCustomObject]@{ Status='READY'; Actions=@($InfrastructureActions); Blockers=@() }
                TestGuestAddressStatus=$GuestAddressStatus
            }
        }

        function Update-TestContextActual {
            param($Context)
            if (-not $Context.ScopeId) { $Context.ScopeId=[string]$Context.Run.scopeId }
            $reasons=[Collections.Generic.List[string]]::new()
            $attachment='MATCHED'
            if (@($Context.Adapters).Count -eq 0 -or
                (@($Context.Adapters).Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$Context.Adapters[0].SwitchName))) {
                $attachment='DRIFT'; $reasons.Add('HYPERV_NETWORK_ADAPTER_MISSING')
            }
            elseif (@($Context.Adapters).Count -gt 1) {
                $attachment='DRIFT'; $reasons.Add('HYPERV_NETWORK_ADAPTER_COUNT_DRIFT')
            }
            elseif ([string]$Context.Adapters[0].SwitchName -ne [string]$Context.ExpectedSwitchName) {
                $attachment='DRIFT'; $reasons.Add('HYPERV_NETWORK_SWITCH_BINDING_DRIFT')
            }
            $infrastructure=if (@($Context.BoundPlan.Actions).Count) {
                $reasons.Add('HYPERV_NETWORK_INFRASTRUCTURE_DRIFT'); 'DRIFT'
            } else { 'MATCHED' }
            if ([string]$Context.TestGuestAddressStatus -eq 'DRIFT') {
                $reasons.Add('HYPERV_NETWORK_GUEST_ADDRESS_DRIFT')
            }
            $status=if ($attachment -eq 'DRIFT' -or $infrastructure -eq 'DRIFT' -or
                [string]$Context.TestGuestAddressStatus -eq 'DRIFT') { 'DRIFT' } else { 'MATCHED' }
            $Context | Add-Member -NotePropertyName Actual -NotePropertyValue ([PSCustomObject]@{
                Status=$status; AttachmentStatus=$attachment; InfrastructureStatus=$infrastructure
                GuestAddressStatus=[string]$Context.TestGuestAddressStatus; ReasonCodes=@($reasons)
            }) -Force
            return $Context
        }

        $script:networkContext=$null
        $script:infrastructureCalls=0
        $script:connectCalls=0
        function Get-LabHyperVNetworkReconcileContext {
            param($RunId,$InstanceId,$StateRoot)
            Update-TestContextActual -Context $script:networkContext
        }
        function Invoke-LabHyperVNetworkBoundPlan {
            param($Plan)
            $script:infrastructureCalls++
            $script:networkContext.BoundPlan.Actions=@()
            return $Plan
        }
        function Connect-VMNetworkAdapter {
            param($VMNetworkAdapter,$SwitchName,$ErrorAction)
            $script:connectCalls++
            $VMNetworkAdapter.SwitchName=$SwitchName
        }

        $script:networkContext=New-TestContext
        $noOp=Get-SqlServerLabReconcilePlan -RunId $script:networkContext.RunId -HyperVNetwork -InstanceId primary -StateRoot $Root

        $script:networkContext=New-TestContext -AdapterMode disconnected -InfrastructureActions @('create-internal-switch','assign-host-address')
        $live=Get-SqlServerLabReconcilePlan -RunId $script:networkContext.RunId -HyperVNetwork -InstanceId primary -StateRoot $Root
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $script:networkContext.RunId -RepairHyperVNetwork -InstanceId primary -StateRoot $Root -WhatIf
        $callsBeforeAction=@($script:infrastructureCalls,$script:connectCalls)
        $action=Invoke-SqlServerLabReconcileAction -RunId $script:networkContext.RunId -RepairHyperVNetwork -InstanceId primary -StateRoot $Root -Confirm:$false
        $completedJournal=Get-Content -LiteralPath (Get-LabHyperVNetworkReconcileJournalPath -RunDirectory $script:networkContext.RunDirectory) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        $afterActionPlan=Get-SqlServerLabReconcilePlan -RunId $script:networkContext.RunId -HyperVNetwork -InstanceId primary -StateRoot $Root

        $script:networkContext=New-TestContext -AdapterMode missing
        $missing=New-LabHyperVNetworkReconcilePlan -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root
        $script:networkContext=New-TestContext -AdapterMode multiple
        $multiple=New-LabHyperVNetworkReconcilePlan -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root
        $script:networkContext=New-TestContext -AdapterMode wrong
        $wrong=New-LabHyperVNetworkReconcilePlan -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root
        $script:networkContext=New-TestContext -GuestAddressStatus DRIFT
        $guestDrift=New-LabHyperVNetworkReconcilePlan -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root

        $script:networkContext=New-TestContext -InfrastructureActions @('create-external-switch')
        $externalPlan=New-LabHyperVNetworkReconcilePlan -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root
        $externalFailure=$null
        try { Invoke-LabHyperVNetworkReconcileRepair -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root }
        catch { $externalFailure=$_.Exception.Message }
        $externalCallsBeforeAllow=@($script:infrastructureCalls,$script:connectCalls)
        $externalAction=Invoke-SqlServerLabReconcileAction -RunId $script:networkContext.RunId `
            -RepairHyperVNetwork -InstanceId primary -AllowExternalSwitchCreation -StateRoot $Root -Confirm:$false

        $script:networkContext=New-TestContext -AdapterMode disconnected
        $identityJournalPath=Get-LabHyperVNetworkReconcileJournalPath -RunDirectory $script:networkContext.RunDirectory
        $identityJournal=[PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVNetworkReconcileJournal/1.0'; OperationId=[guid]::NewGuid().ToString('D')
            RunId=$script:networkContext.RunId; ScopeId=[guid]::NewGuid().ToString('D'); InstanceId='primary'; Provider='hyperv'
            ChangeClass='live'; Status='PREPARED'
            Target=[PSCustomObject]@{ Intent='hostOnly'; ExpectedSwitchName='SQL_LAB_HYPERV'; ReconnectAdapter=$true; InfrastructureActions=@() }
            Runtime=[PSCustomObject]@{ VMId=[string]$script:networkContext.VM.Id; AdapterId='adapter-a' }
            Recovery=[PSCustomObject]@{ Status='RETRY_NETWORK_RECONCILE'; Attempts=0; ErrorCode=$null; Errors=@() }
            UpdatedAt=Get-LabTimestamp
        }
        Write-LabArtifactJsonAtomic -Path $identityJournalPath -InputObject $identityJournal
        $callsBeforeIdentity=@($script:infrastructureCalls,$script:connectCalls)
        $identityFailure=$null
        try { Invoke-LabHyperVNetworkReconcileRepair -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root }
        catch { $identityFailure=$_.Exception.Message }

        $script:networkContext=New-TestContext
        $recoveryPath=Get-LabHyperVNetworkReconcileJournalPath -RunDirectory $script:networkContext.RunDirectory
        $recoveryJournal=[PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVNetworkReconcileJournal/1.0'; OperationId=[guid]::NewGuid().ToString('D')
            RunId=$script:networkContext.RunId; ScopeId=[string]$script:networkContext.Run.scopeId; InstanceId='primary'; Provider='hyperv'
            ChangeClass='live'; Status='RECOVERY_REQUIRED'
            Target=[PSCustomObject]@{ Intent='hostOnly'; ExpectedSwitchName='SQL_LAB_HYPERV'; ReconnectAdapter=$true; InfrastructureActions=@() }
            Runtime=[PSCustomObject]@{ VMId=[string]$script:networkContext.VM.Id; AdapterId='adapter-a' }
            Recovery=[PSCustomObject]@{ Status='RETRY_NETWORK_RECONCILE'; Attempts=1; ErrorCode='SIMULATED_INTERRUPTION'; Errors=@('SIMULATED_INTERRUPTION') }
            UpdatedAt=Get-LabTimestamp
        }
        Write-LabArtifactJsonAtomic -Path $recoveryPath -InputObject $recoveryJournal
        $recoveryPlan=New-LabHyperVNetworkReconcilePlan -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root
        $callsBeforeRecovery=@($script:infrastructureCalls,$script:connectCalls)
        $recoveryResult=Invoke-LabHyperVNetworkReconcileRepair -RunId $script:networkContext.RunId -InstanceId primary -StateRoot $Root
        $recoveryAfter=Get-Content -LiteralPath $recoveryPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30

        [PSCustomObject]@{
            NoOp=$noOp; Live=$live; WhatIf=$whatIf; CallsBeforeAction=$callsBeforeAction; Action=$action
            CompletedJournal=$completedJournal; AfterActionPlan=$afterActionPlan
            Missing=$missing; Multiple=$multiple; Wrong=$wrong; GuestDrift=$guestDrift
            ExternalPlan=$externalPlan; ExternalFailure=$externalFailure
            ExternalAction=$externalAction; ExternalCallsBeforeAllow=$externalCallsBeforeAllow
            IdentityFailure=$identityFailure; CallsBeforeIdentity=$callsBeforeIdentity
            CallsAfterIdentity=@($script:infrastructureCalls,$script:connectCalls)
            RecoveryPlan=$recoveryPlan; RecoveryResult=$recoveryResult; RecoveryAfter=$recoveryAfter
            CallsBeforeRecovery=$callsBeforeRecovery; CallsAfterRecovery=@($script:infrastructureCalls,$script:connectCalls)
            FinalInfrastructureCalls=$script:infrastructureCalls; FinalConnectCalls=$script:connectCalls
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Semantisch passende Hyper-V-Netzbindung bleibt No-op' -Success (
        $evidence.NoOp.IsNoOp -and $evidence.NoOp.HighestChangeClass -eq 'no-op' -and @($evidence.NoOp.Actions).Count -eq 0
    )
    Add-CheckResult -Name 'Additive Infrastruktur und genau ein getrennter Adapter werden live geplant' -Success (
        $evidence.Live.HighestChangeClass -eq 'live' -and @($evidence.Live.Actions).Count -eq 1 -and
        $evidence.Live.Actions[0].RepairKinds -contains 'infrastructure' -and
        $evidence.Live.Actions[0].RepairKinds -contains 'adapter-reconnect'
    )
    Add-CheckResult -Name 'WhatIf mutiert weder Infrastruktur noch Adapter' -Success (
        $evidence.WhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and
        $evidence.CallsBeforeAction[0] -eq 0 -and $evidence.CallsBeforeAction[1] -eq 0
    )
    Add-CheckResult -Name 'Bestätigte Reparatur journalisiert, verifiziert und wird danach No-op' -Success (
        $evidence.Action.ExecutionSummary.Status -eq 'SUCCEEDED' -and $evidence.Action.MutationAllowed -and
        $evidence.CompletedJournal.Status -eq 'COMPLETED' -and $evidence.CompletedJournal.Recovery.Status -eq 'NOT_REQUIRED' -and
        $evidence.AfterActionPlan.IsNoOp
    )
    Add-CheckResult -Name 'Fehlende, mehrere und falsch gebundene Adapter bleiben fail-closed' -Success (
        $evidence.Missing.HighestChangeClass -eq 'unsupported' -and $evidence.Missing.Actual.ReasonCodes -contains 'HYPERV_NETWORK_ADAPTER_OBJECT_MISSING' -and
        $evidence.Multiple.HighestChangeClass -eq 'unsupported' -and $evidence.Multiple.Actual.ReasonCodes -contains 'HYPERV_NETWORK_ADAPTER_COUNT_DRIFT' -and
        $evidence.Wrong.HighestChangeClass -eq 'unsupported' -and $evidence.Wrong.Actual.ReasonCodes -contains 'HYPERV_NETWORK_SWITCH_BINDING_DRIFT'
    )
    Add-CheckResult -Name 'Gastadressdrift bleibt ohne automatischen Gastzugriff unsupported' -Success (
        $evidence.GuestDrift.HighestChangeClass -eq 'unsupported' -and
        $evidence.GuestDrift.Actual.ReasonCodes -contains 'HYPERV_NETWORK_GUEST_ADDRESS_DRIFT'
    )
    Add-CheckResult -Name 'External-Switch-Erstellung verlangt eine explizite Action-Freigabe' -Success (
        $evidence.ExternalPlan.Actions[0].RequiresExternalSwitchApproval -and
        $evidence.ExternalFailure -eq 'HYPERV_NETWORK_RECONCILE_EXTERNAL_SWITCH_APPROVAL_REQUIRED' -and
        $evidence.ExternalAction.ExecutionSummary.Status -eq 'SUCCEEDED' -and
        $evidence.ExternalCallsBeforeAllow[0] -lt $evidence.CallsBeforeIdentity[0]
    )
    Add-CheckResult -Name 'Journal-Identity-Mismatch blockiert vor jeder weiteren Provider-Mutation' -Success (
        $evidence.IdentityFailure -eq 'HYPERV_NETWORK_RECONCILE_JOURNAL_IDENTITY_MISMATCH' -and
        $evidence.CallsBeforeIdentity[0] -eq $evidence.CallsAfterIdentity[0] -and
        $evidence.CallsBeforeIdentity[1] -eq $evidence.CallsAfterIdentity[1]
    )
    Add-CheckResult -Name 'Bereits erfüllte Postcondition schließt ein Recovery-Journal ohne Hostmutation ab' -Success (
        $evidence.RecoveryPlan.HighestChangeClass -eq 'live' -and
        $evidence.RecoveryPlan.Actions[0].RepairKinds -contains 'recovery-finalize' -and
        -not $evidence.RecoveryResult.Changed -and $evidence.RecoveryAfter.Status -eq 'COMPLETED' -and
        $evidence.CallsBeforeRecovery[0] -eq $evidence.CallsAfterRecovery[0] -and
        $evidence.CallsBeforeRecovery[1] -eq $evidence.CallsAfterRecovery[1]
    )
    $publicPayload=@($evidence.NoOp,$evidence.Live,$evidence.WhatIf,$evidence.Action,$evidence.AfterActionPlan,$evidence.ExternalPlan,$evidence.ExternalAction,$evidence.RecoveryPlan,$evidence.RecoveryResult) | ConvertTo-Json -Depth 30
    Add-CheckResult -Name 'Öffentliche Verträge bleiben frei von VM-, Switch-, Adapter- und Adresswerten' -Success (
        $publicPayload -notmatch 'host-value-must-not-leak|SQL_LAB_HYPERV|FOREIGN_SWITCH|adapter-a|172\.28\.|VMId|AdapterId|ExpectedSwitchName'
    )
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
