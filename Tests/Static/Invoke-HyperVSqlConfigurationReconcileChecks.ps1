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
            Status='AVAILABLE'
            Configurations=@($intent.Configurations | ForEach-Object {[PSCustomObject]@{Name=$_.Name;ValueInUse=[long]$_.Value;ConfiguredValue=[long]$_.Value;IsDynamic=$true}})
            TraceFlags=@(3226)
        }
        $script:configurationApplyCount=0;$script:configurationFailOnce=$false
        function Get-LabHyperVSqlConfigurationReconcileContext {
            $script:configurationContext.Desired=$script:configurationDesired
            return $script:configurationContext
        }
        function Get-LabHyperVSqlConfigurationReconcileCredentials { [PSCustomObject]@{GuestCredential=$null;SqlSaPassword=$null} }
        function Get-LabHyperVSqlConfigurationActualState { return $script:configurationActual }
        function Set-LabHyperVSqlConfigurationValues {
            $script:configurationApplyCount++
            $script:configurationActual.Configurations=@($script:configurationDesired.Configurations | ForEach-Object {[PSCustomObject]@{Name=$_.Name;ValueInUse=[long]$_.Value;ConfiguredValue=[long]$_.Value;IsDynamic=$true}})
            $script:configurationActual.TraceFlags=@($script:configurationActual.TraceFlags)+@($script:configurationDesired.TraceFlags)|Sort-Object -Unique
            if($script:configurationFailOnce){$script:configurationFailOnce=$false;throw 'SYNTHETIC_CONFIG_FAILURE'}
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

        ($script:configurationDesired.Configurations|Where-Object Name -eq 'max degree of parallelism').Value=12
        $actualDop=$script:configurationActual.Configurations|Where-Object Name -eq 'max degree of parallelism'
        $actualDop.IsDynamic=$false
        $unsupported=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId primary -StateRoot $Root

        [PSCustomObject]@{
            Intent=$intent.Contract.Name -eq 'SqlServerLab.SqlConfigurationIntent' -and $intent.CapabilityStatus -eq 'DECLARED_SUPPORTED' -and
                @($intent.Configurations).Count -eq 5 -and @($intent.TraceFlags).Count -eq 1
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op';Sanitized=$sanitized
            Live=$live.HighestChangeClass -eq 'live' -and @($live.Actions).Count -eq 1 -and -not $live.Actions[0].RequiresRestart
            WhatIf=$whatIfSafe -and $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE';Apply=$applied;RepeatJournal=$repeatJournal
            Recovery=$failed.ExecutionSummary.Status -eq 'FAILED' -and $failedJournal.Status -eq 'RECOVERY_REQUIRED' -and $resumePlan.Actions[0].Operation -eq 'ResumeHyperVSqlConfiguration' -and @($resumePlan.Actions[0].RepairKinds) -contains 'recovery-finalize'
            Resume=$resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $resumedJournal.Status -eq 'COMPLETED'
            Unsupported=$unsupported.HighestChangeClass -eq 'unsupported' -and @($unsupported.Actions).Count -eq 0
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
        'Nicht dynamische oder fehlende Konfiguration bleibt fail-closed'=$result.Unsupported
        'Gastmutation verwendet parametrisierte sp_configure-Werte und keinen Dienstrestart'=($source -match "Parameters\.Add\('@name'" -and $source -match "Parameters\.Add\('@value'" -and $source -notmatch 'Restart-Service|Stop-Service|Start-Service')
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
