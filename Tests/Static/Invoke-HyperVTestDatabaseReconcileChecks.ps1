$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVTestDatabaseReconcile.ps1') -Raw -Encoding utf8
$publicPlanSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Get-SqlServerLabReconcilePlan.ps1') -Raw -Encoding utf8
$publicActionSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLabReconcileAction.ps1') -Raw -Encoding utf8
$provisionSource=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-test-database-'+[Guid]::NewGuid().ToString('N'))
$runId=[Guid]::NewGuid().ToString('D');$scopeId=[Guid]::NewGuid().ToString('D');$runDirectory=Join-Path (Join-Path $testRoot 'runs') $runId
New-Item -Path $runDirectory -ItemType Directory -Force|Out-Null
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try{
    $result=&$module{
        param($Root,$RunId,$ScopeId)
        $hashA='a'*64;$hashB='b'*64;$hashC='c'*64;$artifactHash='d'*64
        $providerCapability=[PSCustomObject]@{Capabilities=@([PSCustomObject]@{SourceKey='hyperv-test-database-reconcile'})}
        $restoreA=[PSCustomObject]@{sampleId='sample-a';sampleVariant='full';source='https://example.invalid/sample-a.bak';artifactType='backup';handlerContractVersion='1';expectedSha256=$hashA;expectedOutputs=@([PSCustomObject]@{kind='database';name='SampleA'})}
        $restoreB=[PSCustomObject]@{sampleId='sample-b';sampleVariant='full';source='https://example.invalid/sample-b.bak';artifactType='backup';handlerContractVersion='1';expectedSha256=$hashB;expectedOutputs=@([PSCustomObject]@{kind='database';name='SampleB'})}
        $restoreC=[PSCustomObject]@{sampleId='sample-c';sampleVariant='full';source='https://example.invalid/sample-c.bak';artifactType='backup';handlerContractVersion='1';expectedSha256=$hashC;expectedOutputs=@([PSCustomObject]@{kind='database';name='SampleC'})}
        $intent=New-LabDatabaseIntentSnapshot -Instance ([PSCustomObject]@{provider='hyperv';databases=@([PSCustomObject]@{name='SampleA';restore=$restoreA})}) -ProviderCapability $providerCapability
        $intentValid=$intent.Contract.Name -eq 'SqlServerLab.DatabaseIntent' -and $intent.CapabilityStatus -eq 'DECLARED_SUPPORTED' -and $intent.Items[0].PlanKey -match '^[a-f0-9]{64}$'
        $path=Join-Path (Join-Path $Root 'runs') $RunId
        $entryA=[PSCustomObject]@{PlanKey=Get-LabTestDatabasePlanKey $restoreA;SampleId='sample-a';SampleVariant='full';DatabaseNames=@('SampleA');ArtifactSha256=$artifactHash;HandlerContractVersion='1';InstalledAt=Get-LabTimestamp}
        $script:dbOwnership=[PSCustomObject]@{ContractVersion='SqlServerLab.HyperVTestDatabaseOwnership/1.0';RunId=$RunId;ScopeId=$ScopeId;InstanceId='primary';Provider='hyperv';VMId='private-db-vm-id';Entries=@($entryA);UpdatedAt=Get-LabTimestamp}
        $script:dbDesired=@([PSCustomObject]@{PlanKey=Get-LabTestDatabasePlanKey $restoreB;SampleId='sample-b';SampleVariant='full';DatabaseNames=@('SampleB');RestoreDefinition=$restoreB;TrustStatus='catalog-verified'})
        $script:dbActual=[PSCustomObject]@{Status='AVAILABLE';Databases=@([PSCustomObject]@{Name='SampleA';State='ONLINE'},[PSCustomObject]@{Name='PrivateUserDb';State='ONLINE'})}
        $script:dbRemoveCount=0;$script:dbInstallCount=0;$script:dbPartialCleanupCount=0;$script:dbBackupCleanupCount=0;$script:dbSyncCount=0;$script:dbFailOnce=$false
        function Get-LabHyperVTestDatabaseReconcileContext{
            [PSCustomObject]@{RunId=$RunId;ScopeId=$ScopeId;InstanceId='primary';StateRoot=$Root;RunDirectory=$path;ConnectionInstance=[PSCustomObject]@{vmName='private-db-vm';vmId='private-db-vm-id';host='private-host';port=1433};VM=[PSCustomObject]@{Id='private-db-vm-id';State='Running'};Ownership=$script:dbOwnership;OwnershipPath=(Get-LabHyperVTestDatabaseOwnershipPath $path);DesiredSamples=$script:dbDesired;TargetHash=(Get-LabHyperVTestDatabaseTargetHash -Samples $script:dbDesired);ResolvedInstance=[PSCustomObject]@{version='2022'};DesiredSnapshot=[PSCustomObject]@{};Connection=[PSCustomObject]@{instances=@()};ConnectionPath=(Join-Path $path 'connection-info.json');Run=[PSCustomObject]@{metadata=[PSCustomObject]@{};updatedAt=$null}}
        }
        function Get-LabHyperVTestDatabaseCredentials{
            $syntheticPassword=New-Object System.Security.SecureString
            foreach($character in 'Synthetic-Passw0rd!'.ToCharArray()){$syntheticPassword.AppendChar($character)}
            $syntheticPassword.MakeReadOnly()
            return [PSCustomObject]@{GuestCredential=$null;SqlSaPassword=$syntheticPassword}
        }
        function Get-LabHyperVTestDatabaseActualState{return $script:dbActual}
        function Invoke-LabHyperVTestDatabaseRemoval{param($Context,$Credential,$OperationId,$DatabaseNames);$script:dbRemoveCount++;$script:dbActual.Databases=@($script:dbActual.Databases|Where-Object{[string]$_.Name -notin @($DatabaseNames)});[PSCustomObject]@{Status='APPLIED'}}
        function Remove-LabHyperVTestDatabasePartialOutputs{param($Context,$Credential,$DatabaseNames);$script:dbPartialCleanupCount++;$script:dbActual.Databases=@($script:dbActual.Databases|Where-Object{[string]$_.Name -notin @($DatabaseNames)})}
        function Remove-LabHyperVTestDatabaseRecoveryBackups{$script:dbBackupCleanupCount++}
        function Install-LabSampleDatabase{
            param($Provider,$HostName,$Port,$SaPassword,$RunId,$InstanceId,$GuestCredential,$RestoreDefinition,$SqlVersion,$RunDirectory,$StateRoot,[switch]$NonInteractive)
            $script:dbInstallCount++;$names=@($RestoreDefinition.expectedOutputs|ForEach-Object{[string]$_.name});foreach($name in $names){$script:dbActual.Databases+=@([PSCustomObject]@{Name=$name;State='ONLINE'})}
            if($script:dbFailOnce){$script:dbFailOnce=$false;throw 'SYNTHETIC_DATABASE_INSTALL_FAILURE'}
            [PSCustomObject]@{Success=$true;Status='DATASET_READY';DatabaseNames=$names;Artifact=[PSCustomObject]@{Sha256=$artifactHash}}
        }
        function Sync-LabHyperVTestDatabaseState{$script:dbSyncCount++}

        $plan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -WhatIf
        $journalPath=Get-LabHyperVTestDatabaseReconcileJournalPath $path;$whatIfSafe=$script:dbRemoveCount -eq 0 -and $script:dbInstallCount -eq 0 -and -not(Test-Path $journalPath)
        $applied=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $journal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
        $privatePreserved=@($script:dbActual.Databases.Name) -contains 'PrivateUserDb'
        $noOp=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root

        $script:dbDesired=@([PSCustomObject]@{PlanKey=Get-LabTestDatabasePlanKey $restoreC;SampleId='sample-c';SampleVariant='full';DatabaseNames=@('SampleC');RestoreDefinition=$restoreC;TrustStatus='catalog-verified'})
        $script:dbFailOnce=$true
        $failed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $failedJournal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
        $resumePlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root
        $resumed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $resumedJournal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
        $script:dbDesired=@([PSCustomObject]@{PlanKey='e'*64;SampleId='foreign';SampleVariant='full';DatabaseNames=@('PrivateUserDb');RestoreDefinition=$restoreC;TrustStatus='catalog-verified'})
        $unsupported=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVTestDatabases -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root
        [PSCustomObject]@{
            Intent=$intentValid;Plan=$plan.HighestChangeClass -eq 'live' -and @($plan.Diff.Kind) -contains 'add-sample' -and @($plan.Diff.Kind) -contains 'remove-owned-sample'
            WhatIf=$whatIfSafe -and $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE'
            Apply=$applied.ExecutionSummary.Status -eq 'SUCCEEDED' -and $journal.Status -eq 'COMPLETED' -and $script:dbRemoveCount -ge 1 -and $script:dbInstallCount -ge 1 -and $script:dbSyncCount -ge 1 -and $privatePreserved
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op'
            Recovery=$failed.ExecutionSummary.Status -eq 'FAILED' -and $failedJournal.Status -eq 'RECOVERY_REQUIRED' -and $resumePlan.Actions[0].Operation -eq 'ResumeHyperVTestDatabases'
            Resume=$resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $resumedJournal.Status -eq 'COMPLETED' -and $script:dbPartialCleanupCount -eq 1 -and $script:dbBackupCleanupCount -ge 2
            Unsupported=$unsupported.HighestChangeClass -eq 'unsupported' -and @($unsupported.Actions).Count -eq 0
        }
    } $testRoot $runId $scopeId
    $ownershipSchema=Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/hyperv-test-database-ownership.schema.json') -Raw|ConvertFrom-Json -Depth 40
    $journalSchema=Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/hyperv-test-database-reconcile-journal.schema.json') -Raw|ConvertFrom-Json -Depth 40
    $checks=[ordered]@{
        'Datenbankintent bindet katalogisierte Hyper-V-Samples an einen stabilen PlanKey'=$result.Intent
        'Read-only Plan klassifiziert Addition und eigentumsgebundene Entfernung als live'=$result.Plan
        'WhatIf schreibt weder Journal noch SQL-Zustand'=$result.WhatIf
        'Apply entfernt nur eigenes Sample, installiert das Ziel und erhaelt fremde Datenbanken'=$result.Apply
        'Konvergierter Sample-Satz bleibt No-op'=$result.NoOp
        'Fehler nach partieller Installation bleibt als Recovery sichtbar'=$result.Recovery
        'Resume entfernt nur journalgebundene partielle Outputs und vollendet denselben Zielvertrag'=$result.Resume
        'Kollision mit einer nicht eigentumsgebundenen Datenbank bleibt fail-closed'=$result.Unsupported
        'Ownership- und Journalvertraege sind streng versioniert'=($ownershipSchema.title -eq 'SqlServerLab.HyperVTestDatabaseOwnership/1.0' -and $journalSchema.title -eq 'SqlServerLab.HyperVTestDatabaseReconcileJournal/1.0' -and $ownershipSchema.additionalProperties -eq $false -and $journalSchema.additionalProperties -eq $false)
        'Removal erstellt CHECKSUM-Backup, prueft RESTORE VERIFYONLY und droppt erst danach'=($source -match 'BACKUP DATABASE' -and $source -match 'COPY_ONLY,CHECKSUM' -and $source -match 'RESTORE VERIFYONLY' -and $source.IndexOf('RESTORE VERIFYONLY') -lt $source.IndexOf('DROP DATABASE'))
        'Actual State und Postcondition lesen sys.databases ueber PowerShell Direct'=($source -match 'Invoke-HyperVPowerShellDirect' -and ([regex]::Matches($source,'sys\.databases')).Count -ge 2 -and $source -match 'POSTCONDITION_MISSING')
        'Erstbereitstellung persistiert Ownership erst nach erfolgreicher Sample-Verifikation'=($provisionSource -match 'New-LabHyperVTestDatabaseOwnershipEntry' -and $provisionSource -match 'Add-LabHyperVTestDatabaseOwnershipEntry')
        'Oeffentliche CLI bindet Zielmanifest, Plan, WhatIf und optionales SecureString-Passwort'=($publicPlanSource -match 'HyperVTestDatabases' -and $publicActionSource -match 'RepairHyperVTestDatabases' -and $publicActionSource -match '\[SecureString\]\$SqlSaPassword' -and $publicActionSource -match 'ShouldProcess')
        'Executor mutiert weder VM-Zustand noch fremde Datenbanken'=($source -notmatch 'Stop-VM|Start-VM|Restart-VM' -and $source -match 'OWNERSHIP_IDENTITY_MISMATCH' -and $source -match 'unowned-output-conflict')
    }
    $failedChecks=@($checks.GetEnumerator()|Where-Object{-not$_.Value});foreach($check in $checks.GetEnumerator()){$color=if($check.Value){'Green'}else{'Red'};Write-Host("  {0}  {1}" -f $(if($check.Value){'PASS'}else{'FAIL'}),$check.Key)-ForegroundColor $color};if($failedChecks.Count){throw "Hyper-V test database reconcile checks failed: $($failedChecks.Key -join ', ')"};Write-Host "Hyper-V Test Database Reconcile Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
}
finally{Remove-Module $module.Name -Force -ErrorAction SilentlyContinue;$resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath());if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}}
