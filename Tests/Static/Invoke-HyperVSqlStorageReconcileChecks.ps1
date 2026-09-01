$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVSqlStorageReconcile.ps1') -Raw -Encoding utf8
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try{
    $result=& $module {
        $script:sqlStorageRunId=[Guid]::NewGuid().ToString('D')
        $script:sqlStoragePlanId=[Guid]::NewGuid().ToString('D')
        $script:sqlStorageApplyCount=0;$script:sqlStorageFailOnce=$true;$script:sqlStorageHostPending=$false
        $script:sqlStorageDesired=@(
            [PSCustomObject]@{Role='default-data';LogicalName='DefaultData';SqlPhysicalPath='D:\SQLData';SizeMB=$null;Growth=$null},
            [PSCustomObject]@{Role='default-log';LogicalName='DefaultLog';SqlPhysicalPath='L:\SQLLog';SizeMB=$null;Growth=$null},
            [PSCustomObject]@{Role='backup';LogicalName='BackupDirectory';SqlPhysicalPath='B:\SQLBackup';SizeMB=$null;Growth=$null},
            [PSCustomObject]@{Role='tempdb-data';LogicalName='tempdev';SqlPhysicalPath='T:\TempDB\tempdev.mdf';SizeMB=256;Growth='64MB'},
            [PSCustomObject]@{Role='tempdb-log';LogicalName='templog';SqlPhysicalPath='U:\TempDBLog\templog.ldf';SizeMB=128;Growth='64MB'}
        )
        $script:sqlStorageActual=[PSCustomObject]@{
            Status='AVAILABLE';SqlService='Running';ObservedAt=[datetime]::UtcNow.ToString('o')
            Defaults=@(
                [PSCustomObject]@{Role='default-data';Path='C:\OldData'},
                [PSCustomObject]@{Role='default-log';Path='C:\OldLog'},
                [PSCustomObject]@{Role='backup';Path='C:\OldBackup'}
            )
            TempDb=@(
                [PSCustomObject]@{LogicalName='tempdev';Path='C:\OldTemp\tempdev.mdf';SizeMB=64;Growth='8MB';Type=0},
                [PSCustomObject]@{LogicalName='templog';Path='C:\OldTemp\templog.ldf';SizeMB=64;Growth='8MB';Type=1}
            )
        }
        $script:sqlStorageContext=[PSCustomObject]@{
            RunId=$script:sqlStorageRunId;InstanceId='primary';StateRoot='C:\private-state';RunDirectory='C:\private-state\runs\private-run'
            ScopeId=[Guid]::NewGuid().ToString('D');VM=[PSCustomObject]@{Id='private-vm-id';State='Running'}
            Managed=[PSCustomObject]@{};ConnectionInstance=[PSCustomObject]@{vmName='private-vm-name'}
            BoundPlan=[PSCustomObject]@{PlanId=$script:sqlStoragePlanId;RunId=$script:sqlStorageRunId;InstanceId='primary';Provider='hyperv';Status='READY'}
            Runtime=[PSCustomObject]@{SqlFiles=$script:sqlStorageDesired};ManagedSqlFiles=$script:sqlStorageDesired
            RuntimeReceipt=$null;ReceiptPath='C:\private-state\runs\private-run\storage-runtime-receipt.json';CredentialAvailable=$true
        }
        function Get-LabHyperVSqlStorageReconcileContext{if($script:sqlStorageHostPending){throw 'HYPERV_SQL_STORAGE_RECONCILE_HOST_DRIFT_PENDING'};$script:sqlStorageContext}
        function Get-LabHyperVSqlStorageReconcileCredentials{
            $secret=[Security.SecureString]::new();foreach($character in 'Synthetic_42!'.ToCharArray()){$secret.AppendChar($character)};$secret.MakeReadOnly()
            [PSCustomObject]@{GuestCredential=[PSCredential]::new('Administrator',$secret);SqlSaPassword=$secret}
        }
        function Get-LabHyperVSqlStorageActualState{$script:sqlStorageActual}
        function Invoke-HyperVLabStoragePlan{
            $script:sqlStorageApplyCount++
            if($script:sqlStorageFailOnce){
                $script:sqlStorageFailOnce=$false
                $script:sqlStorageContext.RuntimeReceipt=[PSCustomObject]@{PlanId=$script:sqlStoragePlanId;Status='RECOVERY_REQUIRED';Recovery=[PSCustomObject]@{Status='RETRY_APPLY'}}
                throw 'SQL_STORAGE_TEMPDB_POSTCONDITION_FAILED'
            }
            $script:sqlStorageActual.Defaults=@(
                [PSCustomObject]@{Role='default-data';Path='D:\SQLData'},[PSCustomObject]@{Role='default-log';Path='L:\SQLLog'},[PSCustomObject]@{Role='backup';Path='B:\SQLBackup'})
            $script:sqlStorageActual.TempDb=@(
                [PSCustomObject]@{LogicalName='tempdev';Path='T:\TempDB\tempdev.mdf';SizeMB=256;Growth='64MB';Type=0},
                [PSCustomObject]@{LogicalName='templog';Path='U:\TempDBLog\templog.ldf';SizeMB=128;Growth='64MB';Type=1})
            $script:sqlStorageContext.RuntimeReceipt=[PSCustomObject]@{PlanId=$script:sqlStoragePlanId;Status='VERIFIED';Recovery=[PSCustomObject]@{Status='NOT_REQUIRED'}}
            [PSCustomObject]@{Status='VERIFIED'}
        }

        $plan=Get-SqlServerLabReconcilePlan -RunId $script:sqlStorageRunId -HyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state'
        $sanitized=($plan|ConvertTo-Json -Depth 20) -notmatch 'private-vm|private-state|OldData|SQLData|TempDB\\'
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $script:sqlStorageRunId -RepairHyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state' -WhatIf
        $afterWhatIf=$script:sqlStorageApplyCount
        $failed=Invoke-SqlServerLabReconcileAction -RunId $script:sqlStorageRunId -RepairHyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state' -Confirm:$false
        $resumePlan=Get-SqlServerLabReconcilePlan -RunId $script:sqlStorageRunId -HyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state'
        $resumed=Invoke-SqlServerLabReconcileAction -RunId $script:sqlStorageRunId -RepairHyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state' -Confirm:$false
        $noOp=Get-SqlServerLabReconcilePlan -RunId $script:sqlStorageRunId -HyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state'
        $script:sqlStorageActual.TempDb+=@([PSCustomObject]@{LogicalName='templog2';Path='Z:\templog2.ldf';SizeMB=64;Growth='64MB';Type=1})
        $extraLog=Get-SqlServerLabReconcilePlan -RunId $script:sqlStorageRunId -HyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state'
        $script:sqlStorageHostPending=$true
        $hostPending=Get-SqlServerLabReconcilePlan -RunId $script:sqlStorageRunId -HyperVSqlStorage -InstanceId primary -StateRoot 'C:\private-state'
        [PSCustomObject]@{
            Restart=$plan.HighestChangeClass -eq 'restart' -and @($plan.Actions).Count -eq 1 -and $plan.Actions[0].RequiresSqlServiceRestart
            Sanitized=$sanitized
            WhatIf=$whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and $afterWhatIf -eq 0
            Recovery=$failed.ExecutionSummary.Status -eq 'FAILED' -and $resumePlan.Actions[0].Operation -eq 'ResumeHyperVSqlStorage'
            Resume=$resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:sqlStorageApplyCount -eq 2
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op'
            ExtraLog=$extraLog.HighestChangeClass -eq 'unsupported' -and @($extraLog.Actions).Count -eq 0
            HostPending=$hostPending.HighestChangeClass -eq 'unsupported' -and 'HYPERV_SQL_STORAGE_RECONCILE_HOST_DRIFT_PENDING' -in @($hostPending.ReasonCodes)
        }
    }
    $checks=[ordered]@{
        'Default- und TempDB-Drift wird als SQL-Restart geplant'=$result.Restart
        'Oeffentlicher SQL-Storageplan enthaelt keine Host-, VM- oder Gastpfade'=$result.Sanitized
        'WhatIf fuehrt keinen SQL-Storage-Apply aus'=$result.WhatIf
        'Fehler bleibt ueber Runtime-Receipt als Resume sichtbar'=$result.Recovery
        'Resume verifiziert denselben Bound Plan erfolgreich'=$result.Resume
        'Erfuellte SQL-Dateiplatzierung ist No-op'=$result.NoOp
        'Zusaetzliches TempDB-Logfile bleibt fail-closed unsupported'=$result.ExtraLog
        'Host-/Gast-Storage-Drift blockiert SQL-Mutation'=$result.HostPending
        'Executor verschiebt weder User- noch Systemdatenbankdateien automatisch'=($source -notmatch 'ALTER\s+DATABASE\s+(master|model|msdb)' -and $source -notmatch 'database-data|database-log')
    }
    $failedChecks=@($checks.GetEnumerator()|Where-Object{-not $_.Value})
    foreach($check in $checks.GetEnumerator()){Write-Host ("  {0}  {1}" -f $(if($check.Value){'PASS'}else{'FAIL'}),$check.Key) -ForegroundColor $(if($check.Value){'Green'}else{'Red'})}
    if($failedChecks.Count){throw "Hyper-V SQL storage reconcile checks failed: $($failedChecks.Key -join ', ')"}
    Write-Host "Hyper-V SQL Storage Reconcile Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
}finally{Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
