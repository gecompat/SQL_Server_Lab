$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resourceSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVResourceReconcile.ps1') -Raw -Encoding utf8
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-resource-reconcile-' + [Guid]::NewGuid().ToString('N'))
$runId = [Guid]::NewGuid().ToString('D')
$scopeId = [Guid]::NewGuid().ToString('D')
$runDirectory = Join-Path (Join-Path $testRoot 'runs') $runId
New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null

$connection = [PSCustomObject]@{
    schemaVersion=1
    instances=@([PSCustomObject]@{id='primary';provider='hyperv';vmName='private-vm-name';vmId='private-vm-id'})
}
$connection | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Encoding utf8
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru

try {
    $result = & $module {
        param($Root,$RunId,$ScopeId)
        $script:resourceTestRoot=$Root
        $script:resourceTestRun=[PSCustomObject]@{runId=$RunId;scopeId=$ScopeId;state='RUNNING';metadata=[PSCustomObject]@{workflowKind='hyperv-lab';name='Resource reconcile'}}
        $script:resourceTestDesired=[PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVResourceIntent';Version='1.0'}
            ProcessorCount=4;DynamicMemoryEnabled=$true;MemoryMinimumMB=2048;MemoryStartupMB=4096;MemoryMaximumMB=8192
            RequiredCapability='hyperv-resource-reconcile';CapabilityStatus='DECLARED_SUPPORTED'
        }
        $script:resourceTestVm=[PSCustomObject]@{
            Id='private-vm-id';Name='private-vm-name';State='Running';ProcessorCount=4;DynamicMemoryEnabled=$true
            MemoryMinimum=[long](2048MB);MemoryStartup=[long](4096MB);MemoryMaximum=[long](8192MB)
        }
        $script:resourceSetCount=0;$script:resourceStopCount=0;$script:resourceStartCount=0;$script:resourceFailStartOnce=$false
        $script:resourceManagedVmReadCount=0;$script:resourceFlipLiveDirectionAt=0
        function Get-LabRunState { param($RunId,$StateRoot) $script:resourceTestRun }
        function Get-LabHyperVResourceMigrationLifecycleGuard { [PSCustomObject]@{Allowed=$true;ReasonCode=$null} }
        function New-LabDesiredState {
            [PSCustomObject]@{IsValid=$true;Instances=@([PSCustomObject]@{Id='primary';Provider='hyperv';Resources=$script:resourceTestDesired})}
        }
        function Get-HyperVManagedVM {
            param($VMName,$ExpectedRunId,$ExpectedScopeId)
            $script:resourceManagedVmReadCount++
            if($script:resourceFlipLiveDirectionAt -gt 0 -and $script:resourceManagedVmReadCount -eq $script:resourceFlipLiveDirectionAt){
                $script:resourceTestVm.MemoryMinimum=[long](1024MB)
                $script:resourceTestVm.MemoryMaximum=[long](9216MB)
                $script:resourceFlipLiveDirectionAt=0
            }
            [PSCustomObject]@{VM=$script:resourceTestVm;Identity=[PSCustomObject]@{runId=$ExpectedRunId;scopeId=$ExpectedScopeId;instanceId='primary'}}
        }
        function Set-VMProcessor { param($VM,$Count,$ErrorAction) $script:resourceSetCount++;$VM.ProcessorCount=$Count }
        function Set-VMMemory {
            param($VM,$DynamicMemoryEnabled,$MinimumBytes,$StartupBytes,$MaximumBytes,$ErrorAction)
            $script:resourceSetCount++;$VM.DynamicMemoryEnabled=[bool]$DynamicMemoryEnabled
            if($null -ne $StartupBytes){$VM.MemoryStartup=[long]$StartupBytes}
            if($DynamicMemoryEnabled){$VM.MemoryMinimum=[long]$MinimumBytes;$VM.MemoryMaximum=[long]$MaximumBytes}else{$VM.MemoryMinimum=[long]$StartupBytes;$VM.MemoryMaximum=[long]$StartupBytes}
        }
        function Stop-VM {
            [CmdletBinding(SupportsShouldProcess)]
            param($VM)
            $script:resourceStopCount++
            $VM.State='Off'
        }
        function Start-VM {
            param($VM,$ErrorAction)
            $script:resourceStartCount++
            if($script:resourceFailStartOnce){$script:resourceFailStartOnce=$false;throw 'SYNTHETIC_RESTART_FAILURE'}
            $VM.State='Running'
        }

        $noOp=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVResources -InstanceId primary -StateRoot $Root
        $sanitized=($noOp | ConvertTo-Json -Depth 30) -notmatch 'private-vm-name|private-vm-id'

        $script:resourceTestVm.MemoryMinimum=[long](1024MB)
        $script:resourceTestVm.MemoryMaximum=[long](9216MB)
        $forbiddenLive=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVResources -InstanceId primary -StateRoot $Root
        $script:resourceTestVm.MemoryMinimum=[long](3072MB)
        $script:resourceTestVm.MemoryMaximum=[long](7168MB)
        $live=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVResources -InstanceId primary -StateRoot $Root
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -WhatIf
        $journalPath=Get-LabHyperVResourceReconcileJournalPath -RunDirectory (Join-Path (Join-Path $Root 'runs') $RunId)
        $whatIfSafe=$script:resourceSetCount -eq 0 -and -not (Test-Path -LiteralPath $journalPath)
        # Der oeffentliche Vorplan, der Repair-Kontext und der innere Plan lesen
        # die VM vor dem persistierten Live-Journal. Erst die anschliessende
        # Revalidierung darf die gegenteilige Drift sehen.
        $script:resourceManagedVmReadCount=0;$script:resourceFlipLiveDirectionAt=4
        $setCountBeforePendingLive=$script:resourceSetCount
        $pendingLiveApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -Confirm:$false
        $pendingLiveJournal=Get-Content $journalPath -Raw | ConvertFrom-Json
        $pendingLiveProtected=$pendingLiveApply.ExecutionSummary.Status -eq 'FAILED' -and $pendingLiveApply.ExecutionSummary.Errors -match 'HYPERV_RESOURCE_RECONCILE_LIVE_DIRECTION_PRECONDITION_FAILED' -and $script:resourceSetCount -eq $setCountBeforePendingLive -and $script:resourceStopCount -eq 0 -and $pendingLiveJournal.Status -eq 'RECOVERY_REQUIRED'
        $script:resourceTestVm.MemoryMinimum=[long](3072MB)
        $script:resourceTestVm.MemoryMaximum=[long](7168MB)
        $liveApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -Confirm:$false
        $liveSucceeded=$liveApply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:resourceTestVm.MemoryMinimum -eq 2048MB -and $script:resourceTestVm.MemoryMaximum -eq 8192MB -and $script:resourceStopCount -eq 0
        if(-not $liveSucceeded){throw "Live resource reconcile failed: $($liveApply | ConvertTo-Json -Depth 20 -Compress); journal=$(Get-Content $journalPath -Raw)"}
        $liveJournalStatus=[string](Get-Content $journalPath -Raw | ConvertFrom-Json).Status
        if($liveJournalStatus -ne 'COMPLETED'){throw "Live resource journal incomplete: $liveJournalStatus; $(Get-Content $journalPath -Raw)"}
        $firstOperationId=[string](Get-Content $journalPath -Raw | ConvertFrom-Json).OperationId
        $script:resourceTestVm.MemoryMinimum=[long](3072MB)
        $script:resourceTestVm.MemoryMaximum=[long](7168MB)
        $repeatApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -Confirm:$false
        $secondOperationId=[string](Get-Content $journalPath -Raw | ConvertFrom-Json).OperationId
        $repeatUsesNewJournal=$repeatApply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $secondOperationId -ne $firstOperationId

        $script:resourceTestDesired=[PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.HyperVResourceIntent';Version='1.0'}
            ProcessorCount=6;DynamicMemoryEnabled=$false;MemoryMinimumMB=6144;MemoryStartupMB=6144;MemoryMaximumMB=6144
            RequiredCapability='hyperv-resource-reconcile';CapabilityStatus='DECLARED_SUPPORTED'
        }
        $restart=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVResources -InstanceId primary -StateRoot $Root
        $script:resourceFailStartOnce=$true
        $failed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -Confirm:$false
        $recoveryWritten=$failed.ExecutionSummary.Status -eq 'FAILED' -and $script:resourceTestVm.State -eq 'Off' -and ((Get-Content $journalPath -Raw | ConvertFrom-Json).Status -eq 'RECOVERY_REQUIRED')
        $resumed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -Confirm:$false
        $resumeSucceeded=$resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:resourceTestVm.State -eq 'Running' -and $script:resourceTestVm.ProcessorCount -eq 6 -and -not $script:resourceTestVm.DynamicMemoryEnabled -and ((Get-Content $journalPath -Raw | ConvertFrom-Json).Status -eq 'COMPLETED')

        $script:resourceTestVm.State='Paused';$script:resourceTestDesired.ProcessorCount=8
        $unsupported=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVResources -InstanceId primary -StateRoot $Root

        [PSCustomObject]@{
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op';Sanitized=$sanitized
            ForbiddenLive=$forbiddenLive.HighestChangeClass -eq 'restart' -and $forbiddenLive.Actions[0].RequiresRestart -and @($forbiddenLive.ReasonCodes) -contains 'HYPERV_RESOURCE_RECONCILE_LIVE_DIRECTION_RESTART_REQUIRED'
            Live=$live.HighestChangeClass -eq 'live' -and -not $live.Actions[0].RequiresRestart
            WhatIf=$whatIfSafe -and $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE'
            PendingLive=$pendingLiveProtected
            LiveApply=$liveSucceeded
            RepeatJournal=$repeatUsesNewJournal
            Restart=$restart.HighestChangeClass -eq 'restart' -and $restart.Actions[0].RequiresRestart
            Recovery=$recoveryWritten;Resume=$resumeSucceeded
            Unsupported=$unsupported.HighestChangeClass -eq 'unsupported' -and @($unsupported.Actions).Count -eq 0
        }
    } $testRoot $runId $scopeId

    # Die spezialisierte Ressourcenroute darf bei einem ungueltigen, bereits
    # persistierten Intent nicht erst die VM-/Hostidentitaet lesen.  Der
    # allgemeine Reconcile-Vertrag prueft die Persistenzgrenze bereits breit;
    # dieser Fall bindet sie zusaetzlich an den konkreten Hyper-V-Executor.
    $invalidPersistedIntent = & $module {
        param($Root)
        $resources = [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name='SqlServerLab.HyperVResourceIntent'; Version='1.0' }
            ProcessorCount = [long]0; DynamicMemoryEnabled = $true
            MemoryMinimumMB = [long]2048; MemoryStartupMB = [long]4096; MemoryMaximumMB = [long]8192
            RequiredCapability='hyperv-resource-reconcile'; CapabilityStatus='DECLARED_SUPPORTED'
        }
        $snapshot = [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.RunDesiredState';Version='1.0'}
            ProvisioningMode='manifest';PersistentData=$false;LabName='invalid persisted resource intent'
            Instances=@([PSCustomObject]@{
                Id='primary';Provider='hyperv';Profile='standard'
                Intents=[PSCustomObject]@{
                    Contract=[PSCustomObject]@{Name='SqlServerLab.InstanceIntent';Version='1.0'}
                    Resources=$resources
                }
            })
        }
        $run = New-LabRunState -StateRoot $Root -Metadata @{
            workflowKind='hyperv-lab'; name='invalid persisted resource intent'; desiredState=$snapshot
        } -ProviderSubRuns @([PSCustomObject]@{provider='hyperv';instanceIds=@('primary')})
        $connectionPath = Join-Path $run.RunDir 'connection-info.json'
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject ([PSCustomObject]@{
            schemaVersion=1; instances=@([PSCustomObject]@{id='primary';provider='hyperv';vmName='must-not-read.invalid';vmId='must-not-read'})
        })
        $beforeState = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $run.RunDir 'run-state.json')))
        $beforeConnection = [Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath))
        $script:invalidPersistedResourceManagedVmReads = 0
        function Get-HyperVManagedVM {
            $script:invalidPersistedResourceManagedVmReads++
            throw 'HYPERV_MUST_NOT_BE_READ_FOR_INVALID_PERSISTED_RESOURCE_INTENT'
        }
        $plan = Get-SqlServerLabReconcilePlan -RunId $run.RunId -HyperVResources -InstanceId primary -StateRoot $Root
        [PSCustomObject]@{
            Plan=$plan; ManagedVmReads=$script:invalidPersistedResourceManagedVmReads
            StateUnchanged=($beforeState -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $run.RunDir 'run-state.json'))))
            ConnectionUnchanged=($beforeConnection -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($connectionPath)))
        }
    } $testRoot

    $checks = [ordered]@{
        'Restart verwendet gastgesteuertes Stop-VM ohne harte Abschaltschalter'=($resourceSource -match 'Stop-VM\s+-VM\s+\$context\.VM\s+-Confirm:\$false' -and $resourceSource -notmatch 'Stop-VM[^\r\n]*-(Force|TurnOff|Save|Shutdown)')
        'Semantisch passende vCPU-/RAM-Werte bleiben No-op'=$result.NoOp
        'Oeffentlicher Ressourcenplan enthaelt keine VM-Namen oder IDs'=$result.Sanitized
        'Einengende Dynamic-Min-/Max-Drift einer laufenden VM erfordert restart'=$result.ForbiddenLive
        'Nur bereichserweiternde Dynamic-Min-/Max-Drift einer laufenden VM ist live'=$result.Live
        'WhatIf mutiert weder VM noch Journal'=$result.WhatIf
        'Pending-Live-Journal bricht bei zwischenzeitlicher Richtungsumkehr fail-closed ab'=$result.PendingLive
        'Live-Reparatur journalisiert und erfuellt die Postcondition'=$result.LiveApply
        'Wiederkehrende Drift erhaelt ein neues Operationsjournal'=$result.RepeatJournal
        'CPU-, Modus- und Startup-Drift einer laufenden VM erfordert restart'=$result.Restart
        'Fehlgeschlagener Restart bleibt als Recovery sichtbar'=$result.Recovery
        'Recovery setzt Stop-Apply-Start idempotent fort'=$result.Resume
        'Nicht steuerbarer VM-Zustand bleibt unsupported'=$result.Unsupported
        'Ungueltiger persistierter Ressourcen-Intent blockiert die spezialisierte Hyper-V-Route vor Hostzugriff'=($invalidPersistedIntent.ManagedVmReads -eq 0 -and $invalidPersistedIntent.Plan.HighestChangeClass -eq 'unsupported' -and @($invalidPersistedIntent.Plan.Actions).Count -eq 0 -and -not $invalidPersistedIntent.Plan.MutationAllowed -and @($invalidPersistedIntent.Plan.ReasonCodes) -ceq @('HYPERV_RESOURCE_RECONCILE_DESIRED_STATE_INVALID'))
        'Ungueltiger persistierter Ressourcen-Intent erhaelt State- und Connection-Bytes'=($invalidPersistedIntent.StateUnchanged -and $invalidPersistedIntent.ConnectionUnchanged)
    }
    $failedChecks=@($checks.GetEnumerator() | Where-Object {-not $_.Value})
    foreach($check in $checks.GetEnumerator()){
        $color=if($check.Value){'Green'}else{'Red'};Write-Host ("  {0}  {1}" -f $(if($check.Value){'PASS'}else{'FAIL'}),$check.Key) -ForegroundColor $color
    }
    if($failedChecks.Count){throw "Hyper-V resource reconcile checks failed: $($failedChecks.Key -join ', ')"}
    Write-Host "Hyper-V Resource Reconcile Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
