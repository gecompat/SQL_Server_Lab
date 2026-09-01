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
        function Get-LabRunState { param($RunId,$StateRoot) $script:resourceTestRun }
        function Get-LabHyperVResourceMigrationLifecycleGuard { [PSCustomObject]@{Allowed=$true;ReasonCode=$null} }
        function New-LabDesiredState {
            [PSCustomObject]@{IsValid=$true;Instances=@([PSCustomObject]@{Id='primary';Provider='hyperv';Resources=$script:resourceTestDesired})}
        }
        function Get-HyperVManagedVM { param($VMName,$ExpectedRunId,$ExpectedScopeId) [PSCustomObject]@{VM=$script:resourceTestVm;Identity=[PSCustomObject]@{runId=$ExpectedRunId;scopeId=$ExpectedScopeId;instanceId='primary'}} }
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
        $live=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVResources -InstanceId primary -StateRoot $Root
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -WhatIf
        $journalPath=Get-LabHyperVResourceReconcileJournalPath -RunDirectory (Join-Path (Join-Path $Root 'runs') $RunId)
        $whatIfSafe=$script:resourceSetCount -eq 0 -and -not (Test-Path -LiteralPath $journalPath)
        $liveApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $Root -Confirm:$false
        $liveSucceeded=$liveApply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:resourceTestVm.MemoryMinimum -eq 2048MB -and $script:resourceStopCount -eq 0
        if(-not $liveSucceeded){throw "Live resource reconcile failed: $($liveApply | ConvertTo-Json -Depth 20 -Compress); journal=$(Get-Content $journalPath -Raw)"}
        $liveJournalStatus=[string](Get-Content $journalPath -Raw | ConvertFrom-Json).Status
        if($liveJournalStatus -ne 'COMPLETED'){throw "Live resource journal incomplete: $liveJournalStatus; $(Get-Content $journalPath -Raw)"}
        $firstOperationId=[string](Get-Content $journalPath -Raw | ConvertFrom-Json).OperationId
        $script:resourceTestVm.MemoryMinimum=[long](1024MB)
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
            Live=$live.HighestChangeClass -eq 'live' -and -not $live.Actions[0].RequiresRestart
            WhatIf=$whatIfSafe -and $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE'
            LiveApply=$liveSucceeded
            RepeatJournal=$repeatUsesNewJournal
            Restart=$restart.HighestChangeClass -eq 'restart' -and $restart.Actions[0].RequiresRestart
            Recovery=$recoveryWritten;Resume=$resumeSucceeded
            Unsupported=$unsupported.HighestChangeClass -eq 'unsupported' -and @($unsupported.Actions).Count -eq 0
        }
    } $testRoot $runId $scopeId

    $checks = [ordered]@{
        'Restart verwendet gastgesteuertes Stop-VM ohne harte Abschaltschalter'=($resourceSource -match 'Stop-VM\s+-VM\s+\$context\.VM\s+-Confirm:\$false' -and $resourceSource -notmatch 'Stop-VM[^\r\n]*-(Force|TurnOff|Save|Shutdown)')
        'Semantisch passende vCPU-/RAM-Werte bleiben No-op'=$result.NoOp
        'Oeffentlicher Ressourcenplan enthaelt keine VM-Namen oder IDs'=$result.Sanitized
        'Reine Dynamic-Min-/Max-Drift einer laufenden VM ist live'=$result.Live
        'WhatIf mutiert weder VM noch Journal'=$result.WhatIf
        'Live-Reparatur journalisiert und erfuellt die Postcondition'=$result.LiveApply
        'Wiederkehrende Drift erhaelt ein neues Operationsjournal'=$result.RepeatJournal
        'CPU-, Modus- und Startup-Drift einer laufenden VM erfordert restart'=$result.Restart
        'Fehlgeschlagener Restart bleibt als Recovery sichtbar'=$result.Recovery
        'Recovery setzt Stop-Apply-Start idempotent fort'=$result.Resume
        'Nicht steuerbarer VM-Zustand bleibt unsupported'=$result.Unsupported
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
