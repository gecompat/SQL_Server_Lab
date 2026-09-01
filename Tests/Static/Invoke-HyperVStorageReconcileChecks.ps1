$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVStorageReconcile.ps1') -Raw -Encoding utf8
$providerSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/HyperV/HyperVProvider.ps1') -Raw -Encoding utf8
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-storage-reconcile-'+[Guid]::NewGuid().ToString('N'))
$runId=[Guid]::NewGuid().ToString('D');$scopeId=[Guid]::NewGuid().ToString('D')
$runDirectory=Join-Path (Join-Path $testRoot 'runs') $runId;$resourceRoot=Join-Path $runDirectory 'resources/hyperv'
New-Item -Path $resourceRoot -ItemType Directory -Force|Out-Null
New-Item -Path (Join-Path $runDirectory 'secrets') -ItemType Directory -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $runDirectory 'secrets/guest-administrator-password.secret'),'synthetic')
$connection=[PSCustomObject]@{schemaVersion=1;instances=@([PSCustomObject]@{id='primary';provider='hyperv';vmName='private-storage-vm';vmId='private-storage-vm-id';additionalDrives=@()})}
$connection|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Encoding utf8
$cleanup=[PSCustomObject]@{runId=$runId;scopeId=$scopeId;createdAt=[datetime]::UtcNow.ToString('o');providerSubRuns=@([PSCustomObject]@{id='provider-hyperv';provider='hyperv';stepOrders=@();state='PENDING';updatedAt=[datetime]::UtcNow.ToString('o');errors=0});steps=@();status='PENDING'}
$cleanup|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $runDirectory 'cleanup-plan.json') -Encoding utf8
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try{
    $result=& $module {
        param($Root,$RunId,$ScopeId,$ResourceRoot)
        $dataPath=Join-Path $ResourceRoot 'private-storage-vm-data.vhdx'
        [IO.File]::WriteAllBytes($dataPath,[byte[]](0))
        $dataDiskId=[Guid]::NewGuid().ToString('D').ToUpperInvariant()
        $script:storageRun=[PSCustomObject]@{runId=$RunId;scopeId=$ScopeId;state='RUNNING';metadata=[PSCustomObject]@{workflowKind='hyperv-lab';name='Storage reconcile'}}
        $script:storageDesiredDrives=@(
            [PSCustomObject]@{Id='data';Role='sqlData';GuestPath='D:\SQLData';SizeGB=16;CapabilityStatus='DECLARED_SUPPORTED'},
            [PSCustomObject]@{Id='log';Role='sqlLog';GuestPath='L:\SQLLog';SizeGB=8;CapabilityStatus='DECLARED_SUPPORTED'}
        )
        $script:storageVm=[PSCustomObject]@{Id='private-storage-vm-id';Name='private-storage-vm';State='Running'}
        $script:storageManaged=[PSCustomObject]@{VM=$script:storageVm;Identity=[PSCustomObject]@{
            runId=$RunId;scopeId=$ScopeId;instanceId='primary';childVhdxPath=(Join-Path $ResourceRoot 'private-storage-vm.vhdx')
            additionalVhdxPaths=@($dataPath);additionalDrives=@([PSCustomObject]@{
                id='data';role='sqlData';sizeBytes=[long](8GB);vhdType='dynamic';path=$dataPath;diskIdentifier=$dataDiskId
                controllerNumber=0;controllerLocation=1;guestPath='D:\SQLData';driveLetter='D';fileSystem='NTFS';allocationUnitKB=64
                volumeLabel='SQLLAB_DATA';maximumIops=0;hostRoot=$null;locationId=$null;selector=$null
            });guestDriveInitialization=@()
        }}
        $script:vhd=@{};$script:vhd[$dataPath]=[PSCustomObject]@{Path=$dataPath;Size=[long](8GB);VhdType='dynamic';DiskIdentifier=$dataDiskId}
        $script:attachments=@([PSCustomObject]@{Path=$dataPath;ControllerNumber=0;ControllerLocation=1;MaximumIOPS=0})
        $script:newCount=0;$script:resizeCount=0;$script:addCount=0;$script:guestCount=0;$script:startCount=0;$script:stopCount=0;$script:failGuestOnce=$true
        function Get-LabRunState{$script:storageRun}
        function Get-LabHyperVResourceMigrationLifecycleGuard{[PSCustomObject]@{Allowed=$true;ReasonCode=$null}}
        function New-LabDesiredState{[PSCustomObject]@{IsValid=$true;Instances=@([PSCustomObject]@{Id='primary';Provider='hyperv';Profile='standard';Drives=@($script:storageDesiredDrives);Storage=$null})}}
        function Test-HyperVPathWithinRunDirectory{$true}
        function Assert-LabStorageBoundPlan{$true}
        function ConvertTo-LabHyperVStorageDrivePlan{param($Plan) @([PSCustomObject]@{id='sfp-01';role='sqlData';sizeBytes=[long](32GB);vhdType='dynamic';guestPath='T:\SQLLab';allocationUnitKB=64;fileSystem='NTFS';volumeLabel='SQLLAB_SFP_01';maximumIops=0;hostRoot=$null;hostPath=$null;locationId=$null;selector='default'})}
        function Get-HyperVManagedVM{$script:storageManaged}
        function Get-VMHardDiskDrive{param($VM,$ErrorAction) @($script:attachments)}
        function Get-VHD{param($Path,$ErrorAction) if(-not $script:vhd.ContainsKey([string]$Path)){throw 'SYNTHETIC_VHD_MISSING'};$script:vhd[[string]$Path]}
        function New-VHD{
            param($Path,$SizeBytes,[switch]$Dynamic,[switch]$Fixed,$ErrorAction)
            $script:newCount++;[IO.File]::WriteAllBytes($Path,[byte[]](0));$script:vhd[$Path]=[PSCustomObject]@{Path=$Path;Size=[long]$SizeBytes;VhdType=if($Fixed){'fixed'}else{'dynamic'};DiskIdentifier=[Guid]::NewGuid().ToString('D').ToUpperInvariant()}
        }
        function Resize-VHD{param($Path,$SizeBytes,$ErrorAction)$script:resizeCount++;$script:vhd[$Path].Size=[long]$SizeBytes}
        function Add-VMHardDiskDrive{
            param($VM,$ControllerType,$ControllerNumber,$ControllerLocation,$Path,$ErrorAction)
            $script:addCount++;$drive=[PSCustomObject]@{Path=$Path;ControllerNumber=$ControllerNumber;ControllerLocation=$ControllerLocation;MaximumIOPS=0};$script:attachments+=@($drive);$drive
        }
        function Set-VMHardDiskDrive{param($VMHardDiskDrive,$MaximumIOPS,$ErrorAction)$VMHardDiskDrive.MaximumIOPS=$MaximumIOPS}
        function Set-VM{param($VM,$Notes,$ErrorAction)}
        function Get-LabSecret{$secure=[Security.SecureString]::new();foreach($character in 'Synthetic_42!'.ToCharArray()){$secure.AppendChar($character)};$secure.MakeReadOnly();$secure}
        function Start-VM{param($VM,$ErrorAction)$script:startCount++;$VM.State='Running'}
        function Stop-VM{[CmdletBinding(SupportsShouldProcess)]param($VM)$script:stopCount++;$VM.State='Off'}
        function Initialize-HyperVWindowsGuestDrives{
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential)
            $script:guestCount++;if($script:failGuestOnce){$script:failGuestOnce=$false;throw 'SYNTHETIC_GUEST_FAILURE'}
            $receipts=@($script:storageManaged.Identity.additionalDrives|ForEach-Object{[PSCustomObject]@{
                id=[string]$_.id;diskIdentifier=[string]$_.diskIdentifier;guestPath=[string]$_.guestPath;driveLetter=([string]$_.guestPath).Substring(0,1)
                fileSystem='NTFS';allocationUnitSize=[long](64KB);volumeLabel=[string]$_.volumeLabel;status='VERIFIED';diskSizeBytes=[long]$_.sizeBytes;partitionSizeBytes=[long]$_.sizeBytes-1MB
            }})
            $script:storageManaged.Identity|Add-Member -NotePropertyName guestDriveInitialization -NotePropertyValue $receipts -Force
            [PSCustomObject]@{Status='GUEST_DRIVES_READY';Drives=$receipts}
        }

        $plan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVStorage -InstanceId primary -StateRoot $Root
        $sanitized=($plan|ConvertTo-Json -Depth 30) -notmatch 'private-storage-vm|private-storage-vm-id|resources[\\/]hyperv|\.vhdx'
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVStorage -InstanceId primary -StateRoot $Root -WhatIf
        $whatIfSafe=$script:newCount -eq 0 -and $script:resizeCount -eq 0 -and -not(Test-Path -LiteralPath (Get-LabHyperVStorageReconcileJournalPath -RunDirectory (Join-Path (Join-Path $Root 'runs') $RunId)))
        $failed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVStorage -InstanceId primary -StateRoot $Root -Confirm:$false
        $journalPath=Get-LabHyperVStorageReconcileJournalPath -RunDirectory (Join-Path (Join-Path $Root 'runs') $RunId)
        $recovery=$failed.ExecutionSummary.Status -eq 'FAILED' -and (Get-Content $journalPath -Raw|ConvertFrom-Json).Status -eq 'RECOVERY_REQUIRED' -and $script:resizeCount -eq 1 -and $script:newCount -eq 1 -and $script:addCount -eq 1
        $resumed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVStorage -InstanceId primary -StateRoot $Root -Confirm:$false
        $completed=Get-Content $journalPath -Raw|ConvertFrom-Json
        $resume=$resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $completed.Status -eq 'COMPLETED' -and $script:resizeCount -eq 1 -and $script:newCount -eq 1
        $noOp=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVStorage -InstanceId primary -StateRoot $Root
        $cleanup=Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $Root 'runs') $RunId) 'cleanup-plan.json') -Raw|ConvertFrom-Json
        $cleanupBound=@($cleanup.steps|Where-Object resourceType -eq 'vhdx').Count -eq 1
        $firstOperation=[string]$completed.OperationId
        $script:vhd[$dataPath].Size=[long](8GB);$script:storageManaged.Identity.guestDriveInitialization=@($script:storageManaged.Identity.guestDriveInitialization|Where-Object id -ne 'data')
        $repeat=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVStorage -InstanceId primary -StateRoot $Root -Confirm:$false
        $repeatJournal=Get-Content $journalPath -Raw|ConvertFrom-Json
        $freshJournal=$repeat.ExecutionSummary.Status -eq 'SUCCEEDED' -and [string]$repeatJournal.OperationId -ne $firstOperation
        $script:storageVm.State='Off';$script:storageManaged.Identity.guestDriveInitialization=@($script:storageManaged.Identity.guestDriveInitialization|Where-Object id -ne 'log')
        $restartPlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVStorage -InstanceId primary -StateRoot $Root
        $restartApply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVStorage -InstanceId primary -StateRoot $Root -Confirm:$false
        $restart=$restartPlan.HighestChangeClass -eq 'restart' -and $restartPlan.Actions[0].RequiresTemporaryStart -and $restartApply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:storageVm.State -eq 'Off' -and $script:startCount -eq 1 -and $script:stopCount -eq 1
        $script:storageVm.State='Running'
        $script:vhd[$dataPath].Size=[long](32GB)
        $shrink=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVStorage -InstanceId primary -StateRoot $Root
        $script:vhd[$dataPath].Size=[long](16GB)
        $script:storageManaged.Identity.additionalDrives+=@([PSCustomObject]@{id='foreign';role='general';sizeBytes=[long](1GB)})
        $remove=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVStorage -InstanceId primary -StateRoot $Root
        $portableIntent=[PSCustomObject]@{contractVersion='SqlServerLab.StorageIntent/1.0';placementPolicy='explicit';physicalIsolation='preferred';roles=[PSCustomObject]@{defaultData=[PSCustomObject]@{selector='default'}};tempDb=[PSCustomObject]@{distribution='round-robin'};databaseFiles=@();restoreRules=@()}
        $bound=[PSCustomObject]@{RunId=$RunId;InstanceId='primary';Provider='hyperv';Status='READY';IntentSha256=(Get-LabStorageIntentSha256 -StorageIntent $portableIntent)}
        [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $Root 'runs') $RunId) 'storage-bound-plan.json'),($bound|ConvertTo-Json -Depth 10))
        $storageDesired=[PSCustomObject]@{Profile='standard';Drives=@();Storage=[PSCustomObject]@{ContractVersion=$portableIntent.contractVersion;PlacementPolicy=$portableIntent.placementPolicy;PhysicalIsolation=$portableIntent.physicalIsolation;Roles=$portableIntent.roles;TempDb=$portableIntent.tempDb;DatabaseFiles=@();RestoreRules=@()}}
        $boundDrives=@(Get-LabHyperVStorageReconcileDesiredDrives -DesiredInstance $storageDesired -Managed $script:storageManaged -RunDirectory (Join-Path (Join-Path $Root 'runs') $RunId) -RunId $RunId -InstanceId primary)
        $boundIntent=$boundDrives.Count -eq 1 -and $boundDrives[0].Id -eq 'sfp-01' -and $boundDrives[0].SizeBytes -eq 32GB
        [PSCustomObject]@{
            Live=$plan.HighestChangeClass -eq 'live' -and @($plan.Diff.Kind|Sort-Object -Unique) -join ',' -eq 'add,grow';Sanitized=$sanitized
            WhatIf=$whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and $whatIfSafe;Recovery=$recovery;Resume=$resume
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op';Cleanup=$cleanupBound;FreshJournal=$freshJournal
            Restart=$restart
            Shrink=$shrink.HighestChangeClass -eq 'unsupported' -and @($shrink.Actions).Count -eq 0
            Removal=$remove.HighestChangeClass -eq 'unsupported' -and @($remove.Actions).Count -eq 0
            BoundIntent=$boundIntent
        }
    } $testRoot $runId $scopeId $resourceRoot
    $checks=[ordered]@{
        'Fehlende Zusatz-VHDX und Grow-only-Drift werden live geplant'=$result.Live
        'Oeffentlicher Storageplan enthaelt keine VM-IDs oder Hostpfade'=$result.Sanitized
        'WhatIf mutiert weder VHDX noch Journal'=$result.WhatIf
        'Gastfehler bleibt nach hostseitiger Mutation als Recovery sichtbar'=$result.Recovery
        'Resume wiederholt keine abgeschlossene Hostmutation und verifiziert den Gast'=$result.Resume
        'Erfuellter Host-/Gastvertrag ist No-op'=$result.NoOp
        'Neue VHDX wird vor Mutation genau einmal in Cleanup gebunden'=$result.Cleanup
        'Wiederkehrende Drift erhaelt ein frisches Operationsjournal'=$result.FreshJournal
        'Ausgeschaltete VM wird zur Gastverifikation gestartet und wieder ausgeschaltet'=$result.Restart
        'Shrink bleibt ohne automatische Mutation unsupported'=$result.Shrink
        'Entfernen zusaetzlicher Datentraeger bleibt fail-closed unsupported'=$result.Removal
        'Persistierter StorageIntent bindet ueber denselben kanonischen Intent-Hash'=$result.BoundIntent
        'Guest-Resize verwendet Get-PartitionSupportedSize und keinen automatischen Detach'=($providerSource -match 'Get-PartitionSupportedSize' -and $providerSource -match 'Resize-Partition' -and $source -notmatch 'Remove-VMHardDiskDrive')
    }
    $failedChecks=@($checks.GetEnumerator()|Where-Object{-not $_.Value})
    foreach($check in $checks.GetEnumerator()){Write-Host ("  {0}  {1}" -f $(if($check.Value){'PASS'}else{'FAIL'}),$check.Key) -ForegroundColor $(if($check.Value){'Green'}else{'Red'})}
    if($failedChecks.Count){throw "Hyper-V storage reconcile checks failed: $($failedChecks.Key -join ', ')"}
    Write-Host "Hyper-V Storage Reconcile Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
}finally{
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath());if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
