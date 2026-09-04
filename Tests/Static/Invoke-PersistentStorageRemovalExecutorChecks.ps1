#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft Journal, Backup-Resume und fail-closed Policy-Grenzen des PSR-004-Executors.
#>
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-removal-executor-$([Guid]::NewGuid().ToString('N'))"
$failures=[Collections.Generic.List[string]]::new();$passed=0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

Write-Host '';Write-Host 'SQL_Server_Lab - Persistent Storage Removal Executor Checks' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop
$module=Get-Module SqlServerLab
try {
    $evidence=& $module {
        param($Root)
        $runId=[Guid]::NewGuid().ToString('D');$scopeId=[Guid]::NewGuid().ToString('D');$storageId=[Guid]::NewGuid().ToString('D')
        $referenceOne=[Guid]::NewGuid().ToString('D');$referenceTwo=[Guid]::NewGuid().ToString('D')
        $selection=@([PSCustomObject]@{PersistentStorageId=$storageId;Policy='BACKUP_ON_REMOVE';DatabaseReferenceIds=@($referenceOne,$referenceTwo)})
        $plan=[PSCustomObject]@{
            ContractVersion='SqlServerLab.PersistentStorageRemovalPlan/1.0';IntentId=[Guid]::NewGuid().ToString('D')
            RunId=$runId;CatalogRevision=4;Status='READY';Stores=@([PSCustomObject]@{
                PersistentStorageId=$storageId;StorageClass='INSTANCE_STORE';Provider='docker';Policy='BACKUP_ON_REMOVE'
                Destructive=$false;RequiresSeparateStorageDelete=$true;DatabaseReferenceIds=@($referenceOne,$referenceTwo)
            })
        }
        $syntheticPassword=[Security.SecureString]::new()
        foreach($character in 'Synthetic!123'.ToCharArray()){$syntheticPassword.AppendChar($character)}
        $syntheticPassword.MakeReadOnly()
        $context=[PSCustomObject]@{
            Run=[PSCustomObject]@{state='RUNNING'};RunDirectory=(Join-Path $Root 'backup-resume');ScopeId=$scopeId
            Configuration=[PSCustomObject]@{ControllerId=[Guid]::NewGuid().ToString('D')};DataRoot=(Join-Path $Root 'Lab_Data')
            StateRoot=(Join-Path $Root 'state');Selection=$selection;SaPassword=$syntheticPassword
            BackupTasks=@(
                [PSCustomObject][ordered]@{PersistentStorageId=$storageId;DatabaseReferenceId=$referenceOne;InstanceId='primary';DatabaseName='ApplicationOne';Status='PENDING';BackupSetId=$null;ArtifactPersistentStorageId=$null;Sha256=$null;Bytes=$null},
                [PSCustomObject][ordered]@{PersistentStorageId=$storageId;DatabaseReferenceId=$referenceTwo;InstanceId='primary';DatabaseName='ApplicationTwo';Status='PENDING';BackupSetId=$null;ArtifactPersistentStorageId=$null;Sha256=$null;Bytes=$null}
            )
        }
        New-Item -ItemType Directory -Path $context.RunDirectory -Force | Out-Null
        $script:removalBackupCalls=@{};$script:removalFailSecond=$true;$script:removalReceipts=@{}
        $backupAction={
            param($ActionRunId,$ActionInstanceId,$ActionDatabaseName,$ActionDataRoot,$ActionStateRoot,$ActionPassword)
            $null=$ActionRunId,$ActionInstanceId,$ActionDataRoot,$ActionStateRoot,$ActionPassword
            if(-not $script:removalBackupCalls.ContainsKey($ActionDatabaseName)){$script:removalBackupCalls[$ActionDatabaseName]=0}
            $script:removalBackupCalls[$ActionDatabaseName]++
            if($ActionDatabaseName -eq 'ApplicationTwo' -and $script:removalFailSecond){throw 'SYNTHETIC_SECOND_BACKUP_FAILURE'}
            $receipt=[PSCustomObject]@{Status='BACKUP_REUSABLE';BackupSetId=[Guid]::NewGuid().ToString('D');PersistentStorageId=[Guid]::NewGuid().ToString('D');DatabaseName=$ActionDatabaseName;Sha256=('a'*64);Bytes=4096}
            $script:removalReceipts[$receipt.BackupSetId]=[PSCustomObject]@{Record=[PSCustomObject]@{DatabaseName=$ActionDatabaseName;Artifact=[PSCustomObject]@{Sha256=('a'*64)}}}
            $receipt
        }
        $verifyAction={param($BackupSetId,$ActionDataRoot)$null=$ActionDataRoot;if(-not $script:removalReceipts.ContainsKey($BackupSetId)){throw 'SYNTHETIC_BACKUP_MISSING'};$script:removalReceipts[$BackupSetId]}
        $packageAction={param($ActionRunId,$ActionInstanceId,$ActionDatabaseName,$ActionDataRoot,$ActionStateRoot)$null=$ActionRunId,$ActionInstanceId,$ActionDatabaseName,$ActionDataRoot,$ActionStateRoot;throw 'SYNTHETIC_PACKAGE_UNEXPECTED'}
        $packageVerifyAction={param($DatabasePackageId,$ActionDataRoot)$null=$DatabasePackageId,$ActionDataRoot;throw 'SYNTHETIC_PACKAGE_UNEXPECTED'}
        $replanAction={param($ActionRunId,$ActionSelection)$null=$ActionRunId,$ActionSelection;$plan}
        $removeAction={param($ActionRunId,$ActionStateRoot)$null=$ActionRunId,$ActionStateRoot;[PSCustomObject]@{Status='REMOVED';Errors=0;Cleanup='CLEANUP_SUCCEEDED'}}
        $postAction={param($ActionRunId,$ActionSelection,$ActionConfiguration)$null=$ActionRunId,$ActionSelection,$ActionConfiguration;$true}
        $firstFailure=$null
        try{$null=Invoke-LabPersistentStorageRemovalExecutor -Plan $plan -Selection $selection -Context $context -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -ReplanAction $replanAction -RemoveAction $removeAction -PostconditionAction $postAction}catch{$firstFailure=$_.Exception.Message}
        $failedJournal=Read-LabPersistentStorageRemovalJournal -Path (Get-LabPersistentStorageRemovalJournalPath -RunDirectory $context.RunDirectory)
        $script:removalFailSecond=$false
        $completed=Invoke-LabPersistentStorageRemovalExecutor -Plan $plan -Selection $selection -Context $context -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -ReplanAction $replanAction -RemoveAction $removeAction -PostconditionAction $postAction
        $completedAgain=Invoke-LabPersistentStorageRemovalExecutor -Plan $plan -Selection $selection -Context $context -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -ReplanAction $replanAction -RemoveAction $removeAction -PostconditionAction $postAction
        $legacyJournal=$completed|ConvertTo-Json -Depth 40|ConvertFrom-Json -Depth 40
        $legacyJournal.PSObject.Properties.Remove('Packages')
        $legacyJournalPath=Join-Path $Root 'legacy-removal-journal.json'
        Write-LabArtifactJsonAtomic -Path $legacyJournalPath -InputObject $legacyJournal
        $legacyRead=Read-LabPersistentStorageRemovalJournal -Path $legacyJournalPath
        $backupCalls=@{};foreach($key in $script:removalBackupCalls.Keys){$backupCalls[$key]=$script:removalBackupCalls[$key]}

        $retainRoot=Join-Path $Root 'remove-resume';New-Item -ItemType Directory -Path $retainRoot -Force | Out-Null
        $retainSelection=@([PSCustomObject]@{PersistentStorageId=$storageId;Policy='RETAIN_INSTANCE_STORE';DatabaseReferenceIds=@()})
        $retainPlan=[PSCustomObject]@{
            ContractVersion='SqlServerLab.PersistentStorageRemovalPlan/1.0';IntentId=[Guid]::NewGuid().ToString('D');RunId=$runId;CatalogRevision=8;Status='READY'
            Stores=@([PSCustomObject]@{PersistentStorageId=$storageId;StorageClass='INSTANCE_STORE';Provider='podman';Policy='RETAIN_INSTANCE_STORE';Destructive=$false;RequiresSeparateStorageDelete=$true;DatabaseReferenceIds=@()})
        }
        $retainContext=[PSCustomObject]@{Run=[PSCustomObject]@{state='RUNNING'};RunDirectory=$retainRoot;ScopeId=$scopeId;Configuration=$context.Configuration;DataRoot=$context.DataRoot;StateRoot=$context.StateRoot;Selection=$retainSelection;SaPassword=$null;BackupTasks=@()}
        $script:removalRemoveCalls=0;$script:removalReplanCalls=0;$script:removalFailRemove=$true
        $retainReplan={param($ActionRunId,$ActionSelection)$null=$ActionRunId,$ActionSelection;$script:removalReplanCalls++;$retainPlan}
        $retainRemove={param($ActionRunId,$ActionStateRoot)$null=$ActionRunId,$ActionStateRoot;$script:removalRemoveCalls++;if($script:removalFailRemove){throw 'SYNTHETIC_REMOVE_FAILURE'};[PSCustomObject]@{Status='REMOVED';Errors=0;Cleanup='CLEANUP_SUCCEEDED'}}
        $removeFailure=$null
        try{$null=Invoke-LabPersistentStorageRemovalExecutor -Plan $retainPlan -Selection $retainSelection -Context $retainContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -ReplanAction $retainReplan -RemoveAction $retainRemove -PostconditionAction $postAction}catch{$removeFailure=$_.Exception.Message}
        $removeFailedJournal=Read-LabPersistentStorageRemovalJournal -Path (Get-LabPersistentStorageRemovalJournalPath -RunDirectory $retainRoot)
        $script:removalFailRemove=$false;$retainContext.Run.state='RECOVERY_REQUIRED'
        $removeCompleted=Invoke-LabPersistentStorageRemovalExecutor -Plan $retainPlan -Selection $retainSelection -Context $retainContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -ReplanAction $retainReplan -RemoveAction $retainRemove -PostconditionAction $postAction

        $deleteRoot=Join-Path $Root 'delete-resume';New-Item -ItemType Directory -Path $deleteRoot -Force | Out-Null
        $deleteSelection=@([PSCustomObject]@{PersistentStorageId=$storageId;Policy='DELETE_WITH_RUN';DatabaseReferenceIds=@()})
        $deletePlan=[PSCustomObject]@{
            ContractVersion='SqlServerLab.PersistentStorageRemovalPlan/1.0';IntentId=[Guid]::NewGuid().ToString('D');RunId=$runId;CatalogRevision=11;Status='READY'
            Stores=@([PSCustomObject]@{PersistentStorageId=$storageId;StorageClass='INSTANCE_STORE';Provider='docker';Policy='DELETE_WITH_RUN';Destructive=$true;RequiresSeparateStorageDelete=$false;DatabaseReferenceIds=@()})
        }
        $deleteContext=[PSCustomObject]@{Run=[PSCustomObject]@{state='RUNNING'};RunDirectory=$deleteRoot;ScopeId=$scopeId;Configuration=$context.Configuration;DataRoot=$context.DataRoot;StateRoot=$context.StateRoot;Selection=$deleteSelection;SaPassword=$null;BackupTasks=@();PackageTasks=@();ExternalBindings=@();DeleteStores=@([PSCustomObject]@{PersistentStorageId=$storageId;Provider='docker';VolumeName='sql-lab-synthetic-runtime-mssql';Status='PENDING';StartCatalogRevision=$null;CompletionCatalogRevision=$null})}
        $script:deleteStartCalls=0;$script:deleteCompleteCalls=0;$script:deleteRemoveCalls=0;$script:deleteFailRemove=$true
        $deleteReplan={param($ActionRunId,$ActionSelection)$null=$ActionRunId,$ActionSelection;$deletePlan}
        $deleteStart={param($ActionStorageId,$ExpectedRevision)$null=$ActionStorageId;$script:deleteStartCalls++;[PSCustomObject]@{CatalogRevision=($ExpectedRevision+1)}}
        $deleteRemove={param($ActionRunId,$ActionStateRoot)$null=$ActionRunId,$ActionStateRoot;$script:deleteRemoveCalls++;if($script:deleteFailRemove){throw 'SYNTHETIC_DELETE_REMOVE_FAILURE'};[PSCustomObject]@{Status='REMOVED';Errors=0;Cleanup='DELETE_CLEANUP_SUCCEEDED'}}
        $deleteComplete={param($ActionStorageId,$ActionProvider,$ActionVolumeName,$ExpectedRevision)$null=$ActionStorageId,$ActionProvider,$ActionVolumeName;$script:deleteCompleteCalls++;[PSCustomObject]@{CatalogRevision=($ExpectedRevision+1)}}
        $deleteFailure=$null
        try{$null=Invoke-LabPersistentStorageRemovalExecutor -Plan $deletePlan -Selection $deleteSelection -Context $deleteContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -StartDeleteAction $deleteStart -CompleteDeleteAction $deleteComplete -ReplanAction $deleteReplan -RemoveAction $deleteRemove -PostconditionAction $postAction}catch{$deleteFailure=$_.Exception.Message}
        $deleteFailedJournal=Read-LabPersistentStorageRemovalJournal -Path (Get-LabPersistentStorageRemovalJournalPath -RunDirectory $deleteRoot)
        $script:deleteFailRemove=$false;$deleteContext.Run.state='RECOVERY_REQUIRED'
        $deleteCompleted=Invoke-LabPersistentStorageRemovalExecutor -Plan $deletePlan -Selection $deleteSelection -Context $deleteContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -StartDeleteAction $deleteStart -CompleteDeleteAction $deleteComplete -ReplanAction $deleteReplan -RemoveAction $deleteRemove -PostconditionAction $postAction
        $deleteCompletedAgain=Invoke-LabPersistentStorageRemovalExecutor -Plan $deletePlan -Selection $deleteSelection -Context $deleteContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -StartDeleteAction $deleteStart -CompleteDeleteAction $deleteComplete -ReplanAction $deleteReplan -RemoveAction $deleteRemove -PostconditionAction $postAction

        $unsupported=$false
        $unsupportedPlan=$retainPlan|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20;$unsupportedPlan.Stores[0].Policy='DELETE_WITH_RUN'
        try{$null=Assert-LabPersistentStorageRemovalExecutablePlan -Plan $unsupportedPlan}catch{$unsupported=$_.Exception.Message -match 'PERSISTENT_STORAGE_REMOVAL_EXECUTION_STORE_UNSUPPORTED'}
        $deleteContextAccepted=$false;$deleteContextRejected=$false
        $deleteContextRoot=Join-Path $Root 'delete-context-revalidation';$deleteContextRunDirectory=Join-Path (Join-Path $deleteContextRoot 'runs') $runId
        New-Item -ItemType Directory -Path $deleteContextRunDirectory -Force | Out-Null
        Write-LabArtifactJsonAtomic -Path (Join-Path $deleteContextRunDirectory 'connection-info.json') -InputObject ([PSCustomObject]@{runId=$runId;scopeId=$scopeId;instances=@()})
        $script:deleteContextRunId=$runId;$script:deleteContextScopeId=$scopeId;$script:deleteContextStore=[PSCustomObject]@{
            PersistentStorageId=$storageId;StorageClass='INSTANCE_STORE';Provider='docker';State='IN_USE';Retention='RUN_SCOPED';CleanupDisposition='RUN_CLEANUP'
            Lease=[PSCustomObject]@{RunId=$runId;ScopeId=$scopeId};LocationBinding=[PSCustomObject]@{Residency='NATIVE_RUNTIME';ProviderResourceId='sql-lab-synthetic-runtime-mssql'};References=@()
        }
        $originalGetLabRunState=${function:Get-LabRunState};$originalGetLabStorageConfiguration=${function:Get-LabStorageConfiguration};$originalGetLabPersistentStorageCatalog=${function:Get-LabPersistentStorageCatalog}
        try {
            Set-Item -LiteralPath Function:\Get-LabRunState -Value { param($RunId,$StateRoot)$null=$RunId,$StateRoot;[PSCustomObject]@{scopeId=$script:deleteContextScopeId} }
            Set-Item -LiteralPath Function:\Get-LabStorageConfiguration -Value { param($DataRoot)$null=$DataRoot;[PSCustomObject]@{ControllerId=[Guid]::NewGuid().ToString('D')} }
            Set-Item -LiteralPath Function:\Get-LabPersistentStorageCatalog -Value { param($Configuration)$null=$Configuration;[PSCustomObject]@{Status='AVAILABLE';Document=[PSCustomObject]@{Revision=11;Stores=@($script:deleteContextStore)}} }
            $deleteContext=New-LabPersistentStorageRemovalExecutionContext -Plan $deletePlan -Selection $deleteSelection -StateRoot $deleteContextRoot -DataRoot $context.DataRoot
            $deleteContextAccepted=@($deleteContext.DeleteStores).Count -eq 1 -and @($deleteContext.BackupTasks).Count -eq 0 -and @($deleteContext.PackageTasks).Count -eq 0
            $script:deleteContextStore.Retention='RETAINED';$script:deleteContextStore.CleanupDisposition='PRESERVE'
            try { $null=New-LabPersistentStorageRemovalExecutionContext -Plan $deletePlan -Selection $deleteSelection -StateRoot $deleteContextRoot -DataRoot $context.DataRoot } catch { $deleteContextRejected=$_.Exception.Message -eq 'PERSISTENT_STORAGE_REMOVAL_DELETE_STORE_UNRESOLVED' }
        }
        finally {
            Set-Item -LiteralPath Function:\Get-LabRunState -Value $originalGetLabRunState
            Set-Item -LiteralPath Function:\Get-LabStorageConfiguration -Value $originalGetLabStorageConfiguration
            Set-Item -LiteralPath Function:\Get-LabPersistentStorageCatalog -Value $originalGetLabPersistentStorageCatalog
            Remove-Variable deleteContextRunId,deleteContextScopeId,deleteContextStore -Scope Script -ErrorAction SilentlyContinue
        }
        $externalRoot=Join-Path $Root 'external-release';New-Item -ItemType Directory -Path $externalRoot -Force | Out-Null
        $externalSelection=@([PSCustomObject]@{PersistentStorageId=$storageId;Policy='EXTERNAL_UNMANAGED';DatabaseReferenceIds=@()})
        $externalPlan=[PSCustomObject]@{
            ContractVersion='SqlServerLab.PersistentStorageRemovalPlan/1.0';IntentId=[Guid]::NewGuid().ToString('D');RunId=$runId;CatalogRevision=10;Status='READY'
            Stores=@([PSCustomObject]@{PersistentStorageId=$storageId;StorageClass='INSTANCE_STORE';Provider='external';Policy='EXTERNAL_UNMANAGED';Destructive=$false;RequiresSeparateStorageDelete=$true;DatabaseReferenceIds=@()})
        }
        $externalContext=[PSCustomObject]@{Run=[PSCustomObject]@{state='RUNNING'};RunDirectory=$externalRoot;ScopeId=$scopeId;Configuration=$context.Configuration;DataRoot=$context.DataRoot;StateRoot=$context.StateRoot;Selection=$externalSelection;SaPassword=$null;BackupTasks=@();PackageTasks=@();ExternalBindings=@([PSCustomObject]@{PersistentStorageId=$storageId;Status='PENDING';CatalogRevision=$null;SourceMutated=$false})}
        $script:externalReleaseCalls=0;$script:externalRemoveCalls=0
        $externalRelease={param($StorageId,$ActionRunId,$ActionConfiguration,$ExpectedRevision)$null=$StorageId,$ActionRunId,$ActionConfiguration;$script:externalReleaseCalls++;[PSCustomObject]@{Released=$true;SourceMutated=$false;CatalogRevision=($ExpectedRevision+1)}}
        $externalVerify={param($StorageId,$ActionRunId,$ActionConfiguration)$null=$StorageId,$ActionRunId,$ActionConfiguration;$true}
        $externalRemove={param($ActionRunId,$ActionStateRoot)$null=$ActionRunId,$ActionStateRoot;$script:externalRemoveCalls++;[PSCustomObject]@{Status='REMOVED';Errors=0;Cleanup='EXTERNAL_BINDING_RELEASED'}}
        $externalReplan={param($ActionRunId,$ActionSelection)$null=$ActionRunId,$ActionSelection;$externalPlan}
        $externalCompleted=Invoke-LabPersistentStorageRemovalExecutor -Plan $externalPlan -Selection $externalSelection -Context $externalContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -ExternalBindingReleaseAction $externalRelease -ExternalBindingVerificationAction $externalVerify -ReplanAction $externalReplan -RemoveAction $externalRemove -PostconditionAction $postAction
        $externalCompletedAgain=Invoke-LabPersistentStorageRemovalExecutor -Plan $externalPlan -Selection $externalSelection -Context $externalContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -PackageAction $packageAction -PackageVerificationAction $packageVerifyAction -ExternalBindingReleaseAction $externalRelease -ExternalBindingVerificationAction $externalVerify -ReplanAction $externalReplan -RemoveAction $externalRemove -PostconditionAction $postAction
        $removeCalls=$script:removalRemoveCalls;$replanCalls=$script:removalReplanCalls
        $externalReleaseCalls=$script:externalReleaseCalls;$externalRemoveCalls=$script:externalRemoveCalls
        $deleteStartCalls=$script:deleteStartCalls;$deleteCompleteCalls=$script:deleteCompleteCalls;$deleteRemoveCalls=$script:deleteRemoveCalls
        Remove-Variable removalBackupCalls,removalFailSecond,removalReceipts,removalRemoveCalls,removalReplanCalls,removalFailRemove,deleteStartCalls,deleteCompleteCalls,deleteRemoveCalls,deleteFailRemove,externalReleaseCalls,externalRemoveCalls -Scope Script -ErrorAction SilentlyContinue
        [PSCustomObject]@{FirstFailure=$firstFailure;FailedJournal=$failedJournal;Completed=$completed;CompletedAgain=$completedAgain;LegacyRead=$legacyRead;BackupCalls=$backupCalls;RemoveFailure=$removeFailure;RemoveFailedJournal=$removeFailedJournal;RemoveCompleted=$removeCompleted;RemoveCalls=$removeCalls;ReplanCalls=$replanCalls;DeleteFailure=$deleteFailure;DeleteFailedJournal=$deleteFailedJournal;DeleteCompleted=$deleteCompleted;DeleteCompletedAgain=$deleteCompletedAgain;DeleteStartCalls=$deleteStartCalls;DeleteCompleteCalls=$deleteCompleteCalls;DeleteRemoveCalls=$deleteRemoveCalls;Unsupported=$unsupported;DeleteContextAccepted=$deleteContextAccepted;DeleteContextRejected=$deleteContextRejected;ExternalCompleted=$externalCompleted;ExternalCompletedAgain=$externalCompletedAgain;ExternalReleaseCalls=$externalReleaseCalls;ExternalRemoveCalls=$externalRemoveCalls}
    } $temporaryRoot

    Add-CheckResult -Name 'Fehler nach erstem Backup bleibt mit einzeln persistierter Evidence wiederaufnehmbar' -Success (
        $evidence.FirstFailure -match '^PERSISTENT_STORAGE_REMOVAL_RECOVERY_REQUIRED: SYNTHETIC_SECOND_BACKUP_FAILURE' -and
        $evidence.FailedJournal.Status -eq 'RECOVERY_REQUIRED' -and @($evidence.FailedJournal.Backups|Where-Object Status -eq 'COMPLETED').Count -eq 1)
    Add-CheckResult -Name 'Resume verifiziert fertige Backups und erzeugt kein doppeltes Artefakt' -Success (
        $evidence.Completed.Status -eq 'COMPLETED' -and $evidence.CompletedAgain.OperationId -eq $evidence.Completed.OperationId -and
        $evidence.BackupCalls.ApplicationOne -eq 1 -and $evidence.BackupCalls.ApplicationTwo -eq 2)
    Add-CheckResult -Name 'Bestehende 1.0-Journale ohne Packages-Array bleiben sicher resumierbar' -Success (
        @($evidence.LegacyRead.Packages).Count -eq 0 -and $evidence.LegacyRead.OperationId -eq $evidence.Completed.OperationId)
    Add-CheckResult -Name 'Erfolg enthält ausschließlich stabile Backup- und Storage-IDs mit Hash-Postcondition' -Success (
        @($evidence.Completed.Backups).Count -eq 2 -and @($evidence.Completed.Backups|Where-Object {$_.BackupSetId -match '^[0-9a-f-]{36}$' -and $_.ArtifactPersistentStorageId -match '^[0-9a-f-]{36}$' -and $_.Sha256 -match '^[a-f0-9]{64}$'}).Count -eq 2)
    Add-CheckResult -Name 'Begonnener Cleanup wird ohne erneute Planung journalisiert fortgesetzt' -Success (
        $evidence.RemoveFailure -match '^PERSISTENT_STORAGE_REMOVAL_RECOVERY_REQUIRED: SYNTHETIC_REMOVE_FAILURE' -and
        $evidence.RemoveFailedJournal.Removal.Status -eq 'STARTED' -and $evidence.RemoveCompleted.Status -eq 'COMPLETED' -and
        $evidence.RemoveCalls -eq 2 -and $evidence.ReplanCalls -eq 2)
    Add-CheckResult -Name 'DELETE_WITH_RUN journalisiert Lease-Freigabe vor Cleanup und finalisiert sie nach Resume genau einmal' -Success (
        $evidence.DeleteFailure -match '^PERSISTENT_STORAGE_REMOVAL_RECOVERY_REQUIRED: SYNTHETIC_DELETE_REMOVE_FAILURE' -and
        $evidence.DeleteFailedJournal.Status -eq 'RECOVERY_REQUIRED' -and $evidence.DeleteFailedJournal.Removal.Status -eq 'STARTED' -and
        @($evidence.DeleteFailedJournal.DeleteStores | Where-Object { $_.Status -eq 'DELETE_PENDING' -and $_.StartCatalogRevision -eq 12 -and $null -eq $_.CompletionCatalogRevision }).Count -eq 1 -and
        $evidence.DeleteCompleted.Status -eq 'COMPLETED' -and $evidence.DeleteCompletedAgain.OperationId -eq $evidence.DeleteCompleted.OperationId -and
        @($evidence.DeleteCompleted.DeleteStores | Where-Object { $_.Status -eq 'COMPLETED' -and $_.StartCatalogRevision -eq 12 -and $_.CompletionCatalogRevision -eq 13 }).Count -eq 1 -and
        $evidence.DeleteStartCalls -eq 1 -and $evidence.DeleteCompleteCalls -eq 1 -and $evidence.DeleteRemoveCalls -eq 2)
    Add-CheckResult -Name 'Unsicher modelliertes DELETE_WITH_RUN bleibt vor jeder Executor-Mutation blockiert' -Success $evidence.Unsupported
    Add-CheckResult -Name 'DELETE_WITH_RUN benötigt keine persistente Instanzbindung ohne SQL-Artefaktaktion' -Success $evidence.DeleteContextAccepted
    Add-CheckResult -Name 'DELETE_WITH_RUN revalidiert RUN_SCOPED/RUN_CLEANUP gegen den aktuellen Katalog' -Success $evidence.DeleteContextRejected
    Add-CheckResult -Name 'EXTERNAL_UNMANAGED loest nur die journalisierte Katalogbindung und ist idempotent' -Success (
        $evidence.ExternalCompleted.Status -eq 'COMPLETED' -and $evidence.ExternalCompletedAgain.OperationId -eq $evidence.ExternalCompleted.OperationId -and
        @($evidence.ExternalCompleted.ExternalBindings | Where-Object { $_.Status -eq 'COMPLETED' -and -not $_.SourceMutated -and $_.CatalogRevision -eq 11 }).Count -eq 1 -and
        $evidence.ExternalReleaseCalls -eq 1 -and $evidence.ExternalRemoveCalls -eq 1)
    Add-CheckResult -Name 'Journal erfüllt striktes Schema und enthält keine Secrets oder Hostpfade' -Success (
        (& $module {param($Journal)Test-LabPersistentStorageRemovalJournal -Journal $Journal} $evidence.Completed) -and
        (($evidence.Completed|ConvertTo-Json -Depth 30) -notmatch '(?i)password|secret|credential|[A-Z]:\\'))
}
finally{Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host '';Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1};exit 0
