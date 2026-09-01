<#
.SYNOPSIS
    Entfernt einen Run nach bestätigter persistenter Retention-Policy.
.DESCRIPTION
    Führt `RETAIN_INSTANCE_STORE` und `BACKUP_ON_REMOVE` über den gemeinsamen
    Removal-Plan aus. Backups werden mit CHECKSUM und RESTORE VERIFYONLY in der
    Lab_Data-Bibliothek veröffentlicht. Ein lokales Journal ermöglicht sichere
    Wiederaufnahme. Package, externe Freigabe und endgültige Store-Löschung
    bleiben vor jeder Mutation blockiert.
.PARAMETER RunId
    Stabile Run-ID der zu entfernenden Umgebung.
.PARAMETER Selection
    Auswahl per PersistentStorageId, Policy und optionalen DatabaseReferenceIds.
.PARAMETER StateRoot
    Optionaler State-Root.
.PARAMETER DataRoot
    Ziel für verifizierte Backup-Artefakte.
.PARAMETER Force
    Überspringt die zusätzliche interaktive Bestätigung.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert Status, RunId,
    OperationId, Journalstatus, stabile BackupSetIds und Cleanup-Ergebnis.
.EXAMPLE
    Invoke-SqlServerLabPersistentStorageRemoval -RunId $runId -Selection @(
        @{ PersistentStorageId=$storageId; Policy='BACKUP_ON_REMOVE'; DatabaseReferenceIds=@($databaseReferenceId) }
    ) -Force
#>
function Invoke-SqlServerLabPersistentStorageRemoval {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [Parameter(Mandatory)][Alias('Selections')][ValidateNotNull()][object[]]$Selection,
        [string]$StateRoot,
        [string]$DataRoot,
        [switch]$Force
    )

    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    if (-not $DataRoot) { $DataRoot=Get-LabDataRootDefault }
    $DataRoot=Resolve-LabDataRootForUse -DataRoot $DataRoot
    $normalizedSelections=@(ConvertTo-LabPersistentStorageRemovalSelection -Selection $Selection)
    $runDirectory=Join-Path (Join-Path $StateRoot 'runs') $RunId
    $journalPath=Get-LabPersistentStorageRemovalJournalPath -RunDirectory $runDirectory
    $existingJournal=Read-LabPersistentStorageRemovalJournal -Path $journalPath
    if($existingJournal -and [string]$existingJournal.RunId -ne $RunId){throw 'PERSISTENT_STORAGE_REMOVAL_JOURNAL_IDENTITY_CONFLICT'}
    if($existingJournal -and [string]$existingJournal.Removal.Status -in @('STARTED','COMPLETED')){
        $plan=[PSCustomObject]@{
            ContractVersion='SqlServerLab.PersistentStorageRemovalPlan/1.0';IntentId=[string]$existingJournal.IntentId
            RunId=$RunId;CatalogRevision=[int]$existingJournal.CatalogRevision;Status='BLOCKED';Stores=@()
        }
        $context=New-LabPersistentStorageRemovalResumeContext -Journal $existingJournal -Selection $normalizedSelections `
            -StateRoot $StateRoot -DataRoot $DataRoot
    }
    else{
        $plan=Get-SqlServerLabPersistentStorageRemovalPlan -RunId $RunId -Selection $normalizedSelections -StateRoot $StateRoot -DataRoot $DataRoot
        $null=Assert-LabPersistentStorageRemovalExecutablePlan -Plan $plan
        $context=New-LabPersistentStorageRemovalExecutionContext -Plan $plan -Selection $normalizedSelections `
            -StateRoot $StateRoot -DataRoot $DataRoot
    }

    if(-not $PSCmdlet.ShouldProcess($RunId,'verifizierte Retention ausführen und Run entfernen')){
        return [PSCustomObject]@{Status='CANCELLED';RunId=$RunId;Plan=$plan}
    }
    if(-not $Force -and -not (Read-LabConfirm -Prompt 'Retention ausführen und Umgebung anschließend entfernen?')){
        return [PSCustomObject]@{Status='CANCELLED';RunId=$RunId;Plan=$plan}
    }

    $backupAction={
        param($RemovalRunId,$RemovalInstanceId,$RemovalDatabaseName,$RemovalDataRoot,$RemovalStateRoot,$RemovalSaPassword)
        Backup-SqlServerLabDatabase -RunId $RemovalRunId -InstanceId $RemovalInstanceId -DatabaseName $RemovalDatabaseName `
            -SaPassword $RemovalSaPassword -DataRoot $RemovalDataRoot -StateRoot $RemovalStateRoot
    }
    $backupVerificationAction={ param($BackupSetId,$RemovalDataRoot) Get-LabDatabaseBackup -BackupSetId $BackupSetId -DataRoot $RemovalDataRoot }
    $replanAction={ param($RemovalRunId,$RemovalSelection) Get-SqlServerLabPersistentStorageRemovalPlan -RunId $RemovalRunId -Selection $RemovalSelection -StateRoot $StateRoot -DataRoot $DataRoot }
    $removeAction={ param($RemovalRunId,$RemovalStateRoot) Remove-SqlServerLab -RunId $RemovalRunId -StateRoot $RemovalStateRoot -Force -Confirm:$false }
    $postconditionAction={ param($RemovalRunId,$RemovalSelection,$RemovalConfiguration) Assert-LabPersistentStorageRemovalPostcondition -RunId $RemovalRunId -Selection $RemovalSelection -Configuration $RemovalConfiguration }

    $journal=Invoke-LabPersistentStorageRemovalExecutor -Plan $plan -Selection $normalizedSelections -Context $context `
        -BackupAction $backupAction -BackupVerificationAction $backupVerificationAction -ReplanAction $replanAction `
        -RemoveAction $removeAction -PostconditionAction $postconditionAction
    [PSCustomObject]@{
        Status=if([string]$journal.Status -eq 'COMPLETED'){'REMOVED'}else{[string]$journal.Status}
        RunId=$RunId;OperationId=[string]$journal.OperationId;JournalStatus=[string]$journal.Status
        BackupSetIds=@($journal.Backups | ForEach-Object {[string]$_.BackupSetId});Cleanup=[string]$journal.Removal.Cleanup
    }
}
