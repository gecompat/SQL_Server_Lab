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
        $script:configurationCurrentDesired=$intent
        $script:configurationDesiredStateChanged=$false
        $script:configurationDesiredSnapshot=[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.DesiredState';Version='1.0'};Instances=@()}
        $script:configurationRun=[PSCustomObject]@{runId=$RunId;scopeId=$ScopeId;metadata=[PSCustomObject]@{desiredState=$script:configurationDesiredSnapshot};updatedAt=Get-LabTimestamp}
        $script:configurationContext=[PSCustomObject]@{
            RunId=$RunId;ScopeId=$ScopeId;InstanceId='primary';StateRoot=$Root
            RunDirectory=(Join-Path (Join-Path $Root 'runs') $RunId)
            ConnectionInstance=[PSCustomObject]@{vmName='private-vm-name'}
            VM=[PSCustomObject]@{Id='private-vm-id';State='Running'}
            Run=$script:configurationRun;PersistedSnapshot=$script:configurationDesiredSnapshot;DesiredSnapshot=$script:configurationDesiredSnapshot
            CurrentDesired=$script:configurationCurrentDesired;Desired=$script:configurationDesired;DesiredStateChanged=$false
            OwnershipPath=(Join-Path (Join-Path (Join-Path $Root 'runs') $RunId) 'hyperv-sql-configuration-ownership.local.json')
            Ownership=(ConvertTo-LabHyperVSqlConfigurationOwnershipReceipt -RunId $RunId -ScopeId $ScopeId -InstanceId primary -VMId private-vm-id -TraceFlags @(3226))
            CredentialAvailable=$true
        }
        $script:configurationActual=[PSCustomObject]@{
            Status='AVAILABLE';ServiceName='MSSQLSERVER';ServiceStatus='Running'
            Configurations=@($intent.Configurations | ForEach-Object {[PSCustomObject]@{Name=$_.Name;ValueInUse=[long]$_.Value;ConfiguredValue=[long]$_.Value;IsDynamic=$true}})
            TraceFlags=@(3226);StartupTraceFlags=@()
        }
        $script:configurationApplyCount=0;$script:configurationTargetApplyCount=0
        $script:configurationTraceFlagApplyCount=0;$script:configurationRestartCount=0
        $script:configurationTraceFlagRemovalCount=0;$script:configurationOwnershipFailOnce=$false
        $script:configurationFailOnce=$false;$script:configurationRestartFailOnce=$false
        function Get-LabHyperVSqlConfigurationReconcileContext {
            $script:configurationContext.Desired=$script:configurationDesired
            $script:configurationContext.CurrentDesired=$script:configurationCurrentDesired
            $script:configurationContext.DesiredStateChanged=$script:configurationDesiredStateChanged
            return $script:configurationContext
        }
        function Get-LabHyperVSqlConfigurationReconcileCredentials { [PSCustomObject]@{GuestCredential=$null;SqlSaPassword=$null} }
        function Get-LabHyperVSqlConfigurationActualState { return $script:configurationActual }
        function Set-LabHyperVSqlConfigurationValues {
            param($Context,$Access,[bool]$ApplyConfigurations=$true,[bool]$ApplyTraceFlags=$true,[int[]]$TraceFlags)
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
                $script:configurationActual.TraceFlags=@($script:configurationActual.TraceFlags)+@($TraceFlags)|Sort-Object -Unique
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
        function Invoke-LabHyperVSqlConfigurationTraceFlagRemoval {
            param($Context,$Access,[int[]]$TraceFlags)
            $null=$Context;$null=$Access
            $script:configurationTraceFlagRemovalCount++
            $script:configurationActual.TraceFlags=@($script:configurationActual.TraceFlags|Where-Object{[int]$_ -notin @($TraceFlags)})
            [PSCustomObject]@{Status='REMOVED';TraceFlags=@($TraceFlags)}
        }
        $script:configurationOwnershipWriter=${function:Write-LabHyperVSqlConfigurationOwnershipReceipt}
        function Write-LabHyperVSqlConfigurationOwnershipReceipt {
            param($Receipt,$Path)
            if($script:configurationOwnershipFailOnce){$script:configurationOwnershipFailOnce=$false;throw 'SYNTHETIC_OWNERSHIP_FAILURE'}
            & $script:configurationOwnershipWriter -Receipt $Receipt -Path $Path
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

        $script:configurationCurrentDesired=($script:configurationDesired|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $script:configurationDesired=($script:configurationCurrentDesired|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $script:configurationDesired.TraceFlags=@()
        $script:configurationDesiredStateChanged=$true
        $script:configurationContext.DesiredSnapshot=[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.DesiredState';Version='1.0'};Instances=@('trace-removal-target')}
        $script:configurationActual.TraceFlags=@(3226,4199);$script:configurationActual.StartupTraceFlags=@()
        $script:configurationContext.Ownership.TraceFlags=@(3226)
        $removalPlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -ManifestPath 'target-remove.json' -InstanceId primary -StateRoot $Root
        $removalCountBeforeWhatIf=$script:configurationTraceFlagRemovalCount
        $removalWhatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -ManifestPath 'target-remove.json' -InstanceId primary -StateRoot $Root -WhatIf
        $removalWhatIfSafe=$script:configurationTraceFlagRemovalCount -eq $removalCountBeforeWhatIf -and $removalWhatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE'
        $removalApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -ManifestPath 'target-remove.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $removalJournal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
        $ownedRemoval=$removalPlan.HighestChangeClass -eq 'live' -and @($removalPlan.Diff.Kind) -contains 'trace-flag-remove' -and
            $removalApply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:configurationTraceFlagRemovalCount -eq ($removalCountBeforeWhatIf+1) -and
            3226 -notin @($script:configurationActual.TraceFlags) -and 4199 -in @($script:configurationActual.TraceFlags) -and
            @($script:configurationContext.Ownership.TraceFlags).Count -eq 0 -and @($removalJournal.TraceFlagRemovals) -contains 3226

        $script:configurationActual.TraceFlags=@(3226,4199);$script:configurationActual.StartupTraceFlags=@(3226)
        $script:configurationContext.Ownership.TraceFlags=@(3226)
        $startupBlocked=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -ManifestPath 'target-startup.json' -InstanceId primary -StateRoot $Root
        $startupFailClosed=$startupBlocked.HighestChangeClass -eq 'unsupported' -and @($startupBlocked.Diff.Kind) -contains 'trace-flag-remove-startup'

        $script:configurationActual.StartupTraceFlags=@();$script:configurationContext.Ownership.TraceFlags=@()
        $foreignBlocked=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -ManifestPath 'target-foreign.json' -InstanceId primary -StateRoot $Root
        $foreignFailClosed=$foreignBlocked.HighestChangeClass -eq 'unsupported' -and @($foreignBlocked.Diff.Kind) -contains 'trace-flag-remove-unowned'

        $script:configurationCurrentDesired=($script:configurationDesired|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $script:configurationDesired=($script:configurationCurrentDesired|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $script:configurationDesired.TraceFlags=@(1117);$script:configurationActual.TraceFlags=@(4199)
        $script:configurationContext.Ownership.TraceFlags=@();$script:configurationActual.StartupTraceFlags=@()
        $script:configurationContext.DesiredSnapshot=[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.DesiredState';Version='1.0'};Instances=@('trace-add-target')}
        $additionApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -ManifestPath 'target-add.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $additionOwned=$additionApply.ExecutionSummary.Status -eq 'SUCCEEDED' -and 1117 -in @($script:configurationActual.TraceFlags) -and 1117 -in @($script:configurationContext.Ownership.TraceFlags)

        $script:configurationCurrentDesired=($script:configurationDesired|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $script:configurationDesired=($script:configurationCurrentDesired|ConvertTo-Json -Depth 30|ConvertFrom-Json);$script:configurationDesired.TraceFlags=@()
        $script:configurationContext.DesiredSnapshot=[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.DesiredState';Version='1.0'};Instances=@('trace-recovery-target')}
        $script:configurationActual.TraceFlags=@(1117,4199);$script:configurationContext.Ownership.TraceFlags=@(1117)
        $removalCountBeforeRecovery=$script:configurationTraceFlagRemovalCount;$script:configurationOwnershipFailOnce=$true
        $removalFailed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -ManifestPath 'target-recovery.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $removalFailedJournal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
        $removalResumePlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -ManifestPath 'target-recovery.json' -InstanceId primary -StateRoot $Root
        $removalResumed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlConfiguration -ManifestPath 'target-recovery.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $removalRecovery=$removalFailed.ExecutionSummary.Status -eq 'FAILED' -and $removalFailedJournal.Status -eq 'RECOVERY_REQUIRED' -and
            $removalResumePlan.Actions[0].Operation -eq 'ResumeHyperVSqlConfiguration' -and $removalResumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and
            $script:configurationTraceFlagRemovalCount -eq ($removalCountBeforeRecovery+1) -and 1117 -notin @($script:configurationActual.TraceFlags)

        $script:configurationActual.Configurations=@($script:configurationActual.Configurations|Where-Object Name -ne 'cost threshold for parallelism')
        $unsupported=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root

        $fingerprintInstance=[PSCustomObject]@{
            Id='primary';Provider='hyperv';Version='2025';Profile='standard';AutoStart='off';DatabaseNames=@('db')
            Intents=[PSCustomObject]@{Drives=@();Network=[PSCustomObject]@{Mode='hostOnly'};Resources=$null;SqlEndpoint=$null;Databases=$null;Software=$null;Storage=$null;SqlConfiguration=[PSCustomObject]@{TraceFlags=@(1117)}}
        }
        $configurationOnlyClone=$fingerprintInstance|ConvertTo-Json -Depth 20|ConvertFrom-Json
        $configurationOnlyClone.Intents.SqlConfiguration.TraceFlags=@(3226)
        $networkClone=$fingerprintInstance|ConvertTo-Json -Depth 20|ConvertFrom-Json
        $networkClone.Intents.Network.Mode='nat'
        $targetIsolation=(Get-LabHyperVSqlConfigurationInstanceFingerprint -Instance $fingerprintInstance|ConvertTo-Json -Depth 20 -Compress) -ceq
            (Get-LabHyperVSqlConfigurationInstanceFingerprint -Instance $configurationOnlyClone|ConvertTo-Json -Depth 20 -Compress) -and
            (Get-LabHyperVSqlConfigurationInstanceFingerprint -Instance $fingerprintInstance|ConvertTo-Json -Depth 20 -Compress) -cne
            (Get-LabHyperVSqlConfigurationInstanceFingerprint -Instance $networkClone|ConvertTo-Json -Depth 20 -Compress)
        $foreignReceipt=ConvertTo-LabHyperVSqlConfigurationOwnershipReceipt -RunId $RunId -ScopeId $ScopeId -InstanceId primary -VMId foreign-vm -TraceFlags @(3226)
        $foreignReceiptPath=Join-Path $script:configurationContext.RunDirectory 'foreign-ownership.json'
        $null=Write-LabHyperVSqlConfigurationOwnershipReceipt -Receipt $foreignReceipt -Path $foreignReceiptPath
        $ownershipIdentityBlocked=$false
        try{$null=Read-LabHyperVSqlConfigurationOwnershipReceipt -Path $foreignReceiptPath -Context $script:configurationContext}catch{$ownershipIdentityBlocked=$_.Exception.Message -match 'HYPERV_SQL_CONFIGURATION_OWNERSHIP_IDENTITY_MISMATCH'}

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
            RemovalWhatIf=$removalWhatIfSafe;OwnedRemoval=$ownedRemoval;StartupBlocked=$startupFailClosed;ForeignBlocked=$foreignFailClosed
            AdditionOwnership=$additionOwned;RemovalRecovery=$removalRecovery;TargetIsolation=$targetIsolation;OwnershipIdentity=$ownershipIdentityBlocked
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
        'Trace-Flag-Entfernung bleibt unter WhatIf mutationsfrei'=$result.RemovalWhatIf
        'Nur run-eigene Runtime-Trace-Flags werden entfernt und fremde Flags bleiben aktiv'=$result.OwnedRemoval
        'SQL-Startup-Trace-Flags bleiben bei Zielentfernung fail-closed'=$result.StartupBlocked
        'Nicht run-eigene aktive Trace-Flags bleiben bei Zielentfernung fail-closed'=$result.ForeignBlocked
        'Neu aktivierte Trace-Flags werden VM-gebunden als run-eigen erfasst'=$result.AdditionOwnership
        'Recovery nach Trace-Flag-Entfernung wiederholt TRACEOFF nicht'=$result.RemovalRecovery
        'Zielmanifest-Fingerprint erlaubt nur SQL-Konfiguration und blockiert Netzwerkdrift'=$result.TargetIsolation
        'Ownership-Receipt ist fail-closed an die konkrete VM-Identitaet gebunden'=$result.OwnershipIdentity
        'Fehlende oder mehrdeutige Konfiguration bleibt fail-closed'=$result.Unsupported
        'Gastmutation parametrisiert sp_configure, schuetzt Startup-Flags und startet ausschliesslich MSSQLSERVER neu'=($source -match "Parameters\.Add\('@name'" -and $source -match "Parameters\.Add\('@value'" -and $source -match 'DBCC TRACEOFF' -and $source -match 'SQLArg\*' -and $source -match "Restart-Service -Name 'MSSQLSERVER'" -and $source -notmatch 'Restart-VM|Stop-VM|Start-VM')
        'Initiale SQL-Konfiguration initialisiert den Trace-Flag-Besitznachweis'=((Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw) -match 'Initialize-LabHyperVSqlConfigurationOwnershipReceipt')
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
