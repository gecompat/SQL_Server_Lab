<#
.SYNOPSIS
    Erstellt einen strikt blockierten Mehrdatenbank-Transfer-Preflight.
.DESCRIPTION
    DatabaseTransfers enthält die explizit ausgewählten Datenbanken und ihre
    BackupSetIds. Es gibt keinen Restore, keine Credentials im Ergebnis und keine
    Ausführung, bis die gesamte Menge atomar geprüft und wiederherstellbar ist.
.PARAMETER SourceRunId
    Lauf-ID der bestehenden Quellinstanz.
.PARAMETER SourceInstanceId
    Instanz-ID der Quelle.
.PARAMETER TargetRunId
    Lauf-ID der bestehenden Zielinstanz.
.PARAMETER TargetInstanceId
    Instanz-ID des Ziels.
.PARAMETER DataRoot
    Lokaler Lab_Data-Root der Backup-Bibliothek.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.PARAMETER DatabaseTransfers
    Explizite Auswahl mit SourceDatabaseName, TargetDatabaseName und BackupSetId.
.OUTPUTS
    SqlServerLab.PortableContainerTransferExecutorBatchPlan/1.0 mit einer
    expliziten Auswahl, BLOCKED-Status und geheimnisfreien Einzelplanprojektionen.
#>
function Get-SqlServerLabPortableContainerTransferExecutorPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRunId,[Parameter(Mandatory)][string]$SourceInstanceId,[Parameter(Mandatory)][string]$TargetRunId,[Parameter(Mandatory)][string]$TargetInstanceId,[Parameter(Mandatory)][string]$DataRoot,[string]$StateRoot,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$DatabaseTransfers)
    $blockers=[Collections.Generic.List[string]]::new();$transfers=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $DatabaseTransfers){$sourceName=[string]$entry.SourceDatabaseName;$targetName=[string]$entry.TargetDatabaseName;$backupSetId=[string]$entry.BackupSetId;if($sourceName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or $targetName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or $backupSetId -notmatch '^[0-9a-fA-F-]{36}$'){throw 'PORTABLE_CONTAINER_TRANSFER_DATABASE_SELECTION_INVALID'};if(-not $seen.Add($targetName)){throw 'PORTABLE_CONTAINER_TRANSFER_TARGET_DATABASE_DUPLICATE'};$primitive=Get-LabPortableContainerTransferExecutorPlan -SourceRunId $SourceRunId -SourceInstanceId $SourceInstanceId -TargetRunId $TargetRunId -TargetInstanceId $TargetInstanceId -BackupSetId $backupSetId -TargetDatabaseName $targetName -DataRoot $DataRoot -StateRoot $StateRoot;$transfers += [PSCustomObject][ordered]@{SourceDatabaseName=$sourceName;TargetDatabaseName=$targetName;BackupSetId=$backupSetId.ToLowerInvariant();Plan=$primitive}}
    [PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferExecutorBatchPlan/1.0';OperationId=[guid]::NewGuid().ToString('D');SelectionMode='EXPLICIT';Status='BLOCKED';ExecutionImplemented=$false;Transfers=@($transfers);Blockers=@($blockers + @($transfers|ForEach-Object {$_.Plan.Blockers})|Sort-Object -Unique);ExecutionGate='FULL_SELECTION_PREVALIDATION_AND_ATOMIC_ROLLBACK_UNAVAILABLE';PlannedAt=Get-LabTimestamp}
}
