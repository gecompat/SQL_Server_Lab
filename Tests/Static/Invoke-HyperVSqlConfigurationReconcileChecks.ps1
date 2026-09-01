$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVSqlConfigurationReconcile.ps1') -Raw -Encoding utf8
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-sql-configuration-reconcile-' + [Guid]::NewGuid().ToString('N'))
$runId = [Guid]::NewGuid().ToString('D')
$scopeId = [Guid]::NewGuid().ToString('D')
$runDirectory = Join-Path (Join-Path $testRoot 'runs') $runId
New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru

try {
    $result = & $module {
        param($Root,$RunId,$ScopeId)
        $providerCapability=[PSCustomObject]@{Capabilities=@([PSCustomObject]@{SourceKey='hyperv-sql-configuration-reconcile'})}
        $intent=New-LabSqlConfigurationIntentSnapshot -Instance ([PSCustomObject]@{
            provider='hyperv'
            serverConfig=[PSCustomObject]@{
                memory=[PSCustomObject]@{minMB=512;maxMB=4096};maxDop=4;costThreshold=25;traceFlags=@(3226,3226)
                spConfigure=[PSCustomObject]@{'optimize for ad hoc workloads'=1}
            }
        }) -ProviderCapability $providerCapability

        $script:configurationDesired=$intent
        $script:configurationContext=[PSCustomObject]@{
            RunId=$RunId;ScopeId=$ScopeId;InstanceId='primary';StateRoot=$Root
            RunDirectory=(Join-Path (Join-Path $Root 'runs') $RunId)
            ConnectionInstance=[PSCustomObject]@{vmName='private-vm-name'}
            VM=[PSCustomObject]@{Id='private-vm-id';State='Running'}
            Desired=$script:configurationDesired;CredentialAvailable=$true
        }
        $script:configurationActual=[PSCustomObject]@{
            Status='AVAILABLE';ServiceName='MSSQLSERVER';ServiceStatus='Running'
            Configurations=@($intent.Configurations | ForEach-Object {[PSCustomObject]@{Name=$_.Name;ValueInUse=[long]$_.Value;ConfiguredValue=[long]$_.Value;IsDynamic=$true}})
            TraceFlags=@(3226)
        }
        $script:configurationApplyCount=0;$script:configurationTargetApplyCount=0
        $script:configurationTraceFlagApplyCount=0;$script:configurationRestartCount=0
        $script:configurationFailOnce=$false;$script:configurationRestartFailOnce=$false
        function Get-LabHyperVSqlConfigurationReconcileContext {
            $script:configurationContext.Desired=$script:configurationDesired
            return $script:configurationContext
        }
        function Get-LabHyperVSqlConfigurationReconcileCredentials { [PSCustomObject]@{GuestCredential=$null;SqlSaPassword=$null} }
        function Get-LabHyperVSqlConfigurationActualState { return $script:configurationActual }
        function Set-LabHyperVSqlConfigurationValues {
            param($Context,$Access,[bool]$ApplyConfigurations=$true,[bool]$ApplyTraceFlags=$true)
            $null=$Context;$null=$Access
            $script:configurationApplyCount++
            if($ApplyConfigurations){
                $script:configurationTargetApplyCount++
                foreach($target in @($script:configurationDesired.Configurations)){
                    $current=$script:configurationActual.Configurations|Where-Object Name -eq $target.Name
                    $current.ConfiguredValue=[long]$target.Value
                    if($current.IsDynamic){$current.ValueInUse=[long]$target.Value}
                }
            }
            if($ApplyTraceFlags){
                $script:configurationTraceFlagApplyCount++
                $script:configurationActual.TraceFlags=@($script:configurationActual.TraceFlags)+@($script:configurationDesired.TraceFlags)|Sort-Object -Unique
            }
            if($script:configurationFailOnce){$script:configurationFailOnce=$false;throw 'SYNTHETIC_CONFIG_FAILURE'}
        }
        function Invoke-LabHyperVSqlConfigurationServiceRestart {
            param($Context,$Access)
            $null=$Context;$null=$Access
            $script:configurationRestartCount++
            if($script:configurationRestartFailOnce){$script:configurationRestartFailOnce=$false;throw 'SYNTHETIC_RESTART_FAILURE'}
            foreach($current in @($script:configurationActual.Configurations|Where-Object{-not $_.IsDynamic})){
                $current.ValueInUse=[long]$current.ConfiguredValue
            }
            $script:configurationActual.TraceFlags=@()
            [PSCustomObject]@{Status='RESTARTED';ServiceName='MSSQLSERVER';ServiceStatus='Running'}
        }

        $noOp=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root
        $sanitized=($noOp|ConvertTo-Json -Depth 30) -notmatch 'private-vm-name|private-vm-id'

        ($script:configurationActual.Configurations|Where-Object Name -eq 'max server memory (MB)').ValueInUse=2048
        $script:configurationActual.TraceFlags=@()
        $live=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -WhatIf
        $journalPath=Get-LabHyperVSqlConfigurationReconcileJournalPath -RunDirectory $script:configurationContext.RunDirectory
        $whatIfSafe=$script:configurationApplyCount -eq 0 -and -not(Test-Path -LiteralPath $journalPath)
        $apply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -Confirm:$false
        $firstJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $applied=$apply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:configurationApplyCount -eq 1 -and $firstJournal.Status -eq 'COMPLETED'

        ($script:configurationActual.Configurations|Where-Object Name -eq 'max server memory (MB)').ValueInUse=3072
        $repeat=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -Confirm:$false
        $secondJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $repeatJournal=$repeat.ExecutionSummary.Status -eq 'SUCCEEDED' -and [string]$secondJournal.OperationId -ne [string]$firstJournal.OperationId

        ($script:configurationDesired.Configurations|Where-Object Name -eq 'max degree of parallelism').Value=8
        $script:configurationFailOnce=$true
        $failed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -Confirm:$false
        $failedJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $resumePlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root
        $resumed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -Confirm:$false
        $resumedJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json

        $desiredDop=$script:configurationDesired.Configurations|Where-Object Name -eq 'max degree of parallelism'
        $desiredDop.Value=12
        $actualDop=$script:configurationActual.Configurations|Where-Object Name -eq 'max degree of parallelism'
        $actualDop.IsDynamic=$false;$actualDop.ConfiguredValue=8;$actualDop.ValueInUse=8
        $targetApplyCountBeforeRestart=$script:configurationTargetApplyCount
        $traceApplyCountBeforeRestart=$script:configurationTraceFlagApplyCount
        $restartPlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root
        $restartApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -Confirm:$false
        $restartJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $restartNoOp=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root
        $restartAppliedExactlyOnce=$script:configurationRestartCount -eq 1 -and
            $script:configurationTargetApplyCount -eq ($targetApplyCountBeforeRestart+1) -and
            $script:configurationTraceFlagApplyCount -eq ($traceApplyCountBeforeRestart+1)
        $traceFlagsRestored=@($script:configurationActual.TraceFlags) -contains 3226

        $desiredDop.Value=16
        $targetApplyCountBeforeFailure=$script:configurationTargetApplyCount
        $script:configurationRestartFailOnce=$true
        $restartFailed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -Confirm:$false
        $restartFailedJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $restartResumePlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root
        $configuredBeforeResume=[long]$actualDop.ConfiguredValue -eq 16 -and [long]$actualDop.ValueInUse -eq 12
        $restartResumed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -InstanceId primary -StateRoot $Root -Confirm:$false
        $restartResumedJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json

        $script:configurationActual.Configurations=@($script:configurationActual.Configurations|Where-Object Name -ne 'cost threshold for parallelism')
        $unsupported=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root

        [PSCustomObject]@{
            Intent=$intent.Contract.Name -eq 'SqlServerLab.SqlConfigurationIntent' -and $intent.CapabilityStatus -eq 'DECLARED_SUPPORTED' -and
                @($intent.Configurations).Count -eq 5 -and @($intent.TraceFlags).Count -eq 1
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op';Sanitized=$sanitized
            Live=$live.HighestChangeClass -eq 'live' -and @($live.Actions).Count -eq 1 -and -not $live.Actions[0].RequiresRestart
            WhatIf=$whatIfSafe -and $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE';Apply=$applied;RepeatJournal=$repeatJournal
            Recovery=$failed.ExecutionSummary.Status -eq 'FAILED' -and $failedJournal.Status -eq 'RECOVERY_REQUIRED' -and $resumePlan.Actions[0].Operation -eq 'ResumeHyperVSqlConfiguration' -and @($resumePlan.Actions[0].RepairKinds) -contains 'recovery-finalize'
            Resume=$resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $resumedJournal.Status -eq 'COMPLETED'
            RestartPlan=$restartPlan.HighestChangeClass -eq 'restart' -and $restartPlan.Actions[0].RequiresServiceRestart -and -not $restartPlan.Actions[0].RequiresVmRestart
            RestartApply=$restartApply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $restartJournal.ChangeClass -eq 'restart' -and $restartJournal.Status -eq 'COMPLETED' -and
                $restartAppliedExactlyOnce -and $traceFlagsRestored -and $restartNoOp.IsNoOp
            RestartRecovery=$restartFailed.ExecutionSummary.Status -eq 'FAILED' -and $restartFailedJournal.Status -eq 'RECOVERY_REQUIRED' -and
                $restartResumePlan.Actions[0].Operation -eq 'ResumeHyperVSqlConfiguration' -and $restartResumePlan.HighestChangeClass -eq 'restart' -and
                @($restartResumePlan.Actions[0].RepairKinds) -contains 'configuration-restart-pending' -and $configuredBeforeResume -and
                $script:configurationTargetApplyCount -eq ($targetApplyCountBeforeFailure+1) -and
                $restartResumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $restartResumedJournal.Status -eq 'COMPLETED' -and [long]$actualDop.ValueInUse -eq 16
            Unsupported=$unsupported.HighestChangeClass -eq 'unsupported' -and @($unsupported.Actions).Count -eq 0 -and @($unsupported.Diff.Kind) -contains 'configuration-missing'
        }
    } $testRoot $runId $scopeId

    $checks=[ordered]@{
        'Persistierter SQL-Konfigurationsintent ist dedupliziert und capability-gebunden'=$result.Intent
        'Semantisch passende SQL-Konfiguration bleibt No-op'=$result.NoOp
        'Oeffentlicher SQL-Konfigurationsplan enthaelt keine VM-Namen oder IDs'=$result.Sanitized
        'Dynamische Konfigurations- und additive Trace-Flag-Drift ist live'=$result.Live
        'WhatIf mutiert weder SQL noch Journal'=$result.WhatIf
        'Live-Reparatur journalisiert und erfuellt die Postcondition'=$result.Apply
        'Wiederkehrende Drift erhaelt ein neues Operationsjournal'=$result.RepeatJournal
        'Fehlgeschlagene Live-Reparatur bleibt als Recovery sichtbar'=$result.Recovery
        'Recovery setzt denselben Sollzustand idempotent fort'=$result.Resume
        'Nicht dynamische Konfiguration wird als SQL-Dienstrestart ohne VM-Restart geplant'=$result.RestartPlan
        'Restart-Reparatur stellt Trace Flags wieder her und erfuellt die Postcondition'=$result.RestartApply
        'Fehler vor dem SQL-Dienstrestart bleibt fortsetzbar und mutiert den Zielwert nicht doppelt'=$result.RestartRecovery
        'Fehlende oder mehrdeutige Konfiguration bleibt fail-closed'=$result.Unsupported
        'Gastmutation parametrisiert sp_configure und startet ausschliesslich MSSQLSERVER neu'=($source -match "Parameters\.Add\('@name'" -and $source -match "Parameters\.Add\('@value'" -and $source -match "Restart-Service -Name 'MSSQLSERVER'" -and $source -notmatch 'Restart-VM|Stop-VM|Start-VM')
    }
    $failedChecks=@($checks.GetEnumerator()|Where-Object{-not $_.Value})
    foreach($check in $checks.GetEnumerator()){$color=if($check.Value){'Green'}else{'Red'};Write-Host("  {0}  {1}" -f $(if($check.Value){'PASS'}else{'FAIL'}),$check.Key)-ForegroundColor $color}
    if($failedChecks.Count){throw "Hyper-V SQL configuration reconcile checks failed: $($failedChecks.Key -join ', ')"}
    Write-Host "Hyper-V SQL Configuration Reconcile Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
