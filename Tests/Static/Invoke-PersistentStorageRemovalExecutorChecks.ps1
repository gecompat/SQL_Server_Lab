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
        $replanAction={param($ActionRunId,$ActionSelection)$null=$ActionRunId,$ActionSelection;$plan}
        $removeAction={param($ActionRunId,$ActionStateRoot)$null=$ActionRunId,$ActionStateRoot;[PSCustomObject]@{Status='REMOVED';Errors=0;Cleanup='CLEANUP_SUCCEEDED'}}
        $postAction={param($ActionRunId,$ActionSelection,$ActionConfiguration)$null=$ActionRunId,$ActionSelection,$ActionConfiguration;$true}
        $firstFailure=$null
        try{$null=Invoke-LabPersistentStorageRemovalExecutor -Plan $plan -Selection $selection -Context $context -BackupAction $backupAction -BackupVerificationAction $verifyAction -ReplanAction $replanAction -RemoveAction $removeAction -PostconditionAction $postAction}catch{$firstFailure=$_.Exception.Message}
        $failedJournal=Read-LabPersistentStorageRemovalJournal -Path (Get-LabPersistentStorageRemovalJournalPath -RunDirectory $context.RunDirectory)
        $script:removalFailSecond=$false
        $completed=Invoke-LabPersistentStorageRemovalExecutor -Plan $plan -Selection $selection -Context $context -BackupAction $backupAction -BackupVerificationAction $verifyAction -ReplanAction $replanAction -RemoveAction $removeAction -PostconditionAction $postAction
        $completedAgain=Invoke-LabPersistentStorageRemovalExecutor -Plan $plan -Selection $selection -Context $context -BackupAction $backupAction -BackupVerificationAction $verifyAction -ReplanAction $replanAction -RemoveAction $removeAction -PostconditionAction $postAction
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
        try{$null=Invoke-LabPersistentStorageRemovalExecutor -Plan $retainPlan -Selection $retainSelection -Context $retainContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -ReplanAction $retainReplan -RemoveAction $retainRemove -PostconditionAction $postAction}catch{$removeFailure=$_.Exception.Message}
        $removeFailedJournal=Read-LabPersistentStorageRemovalJournal -Path (Get-LabPersistentStorageRemovalJournalPath -RunDirectory $retainRoot)
        $script:removalFailRemove=$false;$retainContext.Run.state='RECOVERY_REQUIRED'
        $removeCompleted=Invoke-LabPersistentStorageRemovalExecutor -Plan $retainPlan -Selection $retainSelection -Context $retainContext -BackupAction $backupAction -BackupVerificationAction $verifyAction -ReplanAction $retainReplan -RemoveAction $retainRemove -PostconditionAction $postAction

        $unsupported=$false
        $unsupportedPlan=$retainPlan|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20;$unsupportedPlan.Stores[0].Policy='PACKAGE_ON_REMOVE'
        try{$null=Assert-LabPersistentStorageRemovalExecutablePlan -Plan $unsupportedPlan}catch{$unsupported=$_.Exception.Message -match 'PERSISTENT_STORAGE_REMOVAL_POLICY_NOT_EXECUTABLE'}
        $removeCalls=$script:removalRemoveCalls;$replanCalls=$script:removalReplanCalls
        Remove-Variable removalBackupCalls,removalFailSecond,removalReceipts,removalRemoveCalls,removalReplanCalls,removalFailRemove -Scope Script -ErrorAction SilentlyContinue
        [PSCustomObject]@{FirstFailure=$firstFailure;FailedJournal=$failedJournal;Completed=$completed;CompletedAgain=$completedAgain;BackupCalls=$backupCalls;RemoveFailure=$removeFailure;RemoveFailedJournal=$removeFailedJournal;RemoveCompleted=$removeCompleted;RemoveCalls=$removeCalls;ReplanCalls=$replanCalls;Unsupported=$unsupported}
    } $temporaryRoot

    Add-CheckResult -Name 'Fehler nach erstem Backup bleibt mit einzeln persistierter Evidence wiederaufnehmbar' -Success (
        $evidence.FirstFailure -match '^PERSISTENT_STORAGE_REMOVAL_RECOVERY_REQUIRED: SYNTHETIC_SECOND_BACKUP_FAILURE' -and
        $evidence.FailedJournal.Status -eq 'RECOVERY_REQUIRED' -and @($evidence.FailedJournal.Backups|Where-Object Status -eq 'COMPLETED').Count -eq 1)
    Add-CheckResult -Name 'Resume verifiziert fertige Backups und erzeugt kein doppeltes Artefakt' -Success (
        $evidence.Completed.Status -eq 'COMPLETED' -and $evidence.CompletedAgain.OperationId -eq $evidence.Completed.OperationId -and
        $evidence.BackupCalls.ApplicationOne -eq 1 -and $evidence.BackupCalls.ApplicationTwo -eq 2)
    Add-CheckResult -Name 'Erfolg enthält ausschließlich stabile Backup- und Storage-IDs mit Hash-Postcondition' -Success (
        @($evidence.Completed.Backups).Count -eq 2 -and @($evidence.Completed.Backups|Where-Object {$_.BackupSetId -match '^[0-9a-f-]{36}$' -and $_.ArtifactPersistentStorageId -match '^[0-9a-f-]{36}$' -and $_.Sha256 -match '^[a-f0-9]{64}$'}).Count -eq 2)
    Add-CheckResult -Name 'Begonnener Cleanup wird ohne erneute Planung journalisiert fortgesetzt' -Success (
        $evidence.RemoveFailure -match '^PERSISTENT_STORAGE_REMOVAL_RECOVERY_REQUIRED: SYNTHETIC_REMOVE_FAILURE' -and
        $evidence.RemoveFailedJournal.Removal.Status -eq 'STARTED' -and $evidence.RemoveCompleted.Status -eq 'COMPLETED' -and
        $evidence.RemoveCalls -eq 2 -and $evidence.ReplanCalls -eq 2)
    Add-CheckResult -Name 'Package, Delete und externe Policies bleiben vor jeder Executor-Mutation blockiert' -Success $evidence.Unsupported
    Add-CheckResult -Name 'Journal erfüllt striktes Schema und enthält keine Secrets oder Hostpfade' -Success (
        (& $module {param($Journal)Test-LabPersistentStorageRemovalJournal -Journal $Journal} $evidence.Completed) -and
        (($evidence.Completed|ConvertTo-Json -Depth 30) -notmatch '(?i)password|secret|credential|[A-Z]:\\'))
}
finally{Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host '';Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if($failures.Count){exit 1};exit 0
