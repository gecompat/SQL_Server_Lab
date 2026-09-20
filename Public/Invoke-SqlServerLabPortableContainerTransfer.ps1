function Invoke-SqlServerLabPortableContainerTransfer {
    <#
    .SYNOPSIS
        Überträgt eine read-only Datenbank in einen neuen eigenen SQL-2025-Run.
    .DESCRIPTION
        Akzeptiert genau ein registriertes, checksum-verifiziertes Backup einer
        bereits ONLINE/READ_ONLY geschalteten verwalteten SQL-2025-Linux-Quelle.
        Erstellt beim gleichen Docker-/Podman-Provider einen neuen Run mit eigenem
        SQL-Volume und generiert dessen verwaltetes Kennwort. Nach Restore ohne
        REPLACE, READ_ONLY und vollständigem RELATIONAL_CORE/1.0-MATCH bleibt der
        Ziel-Run erhalten. Vorhandene Ziel-Runs werden nicht übernommen.
        Grenzen: 256 MiB Backup, 16 Dateien, insgesamt 1 GiB restaurierte Dateigröße,
        512 MiB freie Reserve, 32 Tabellen und 100000 Zeilen. Unsupported Inhalte
        werden abgewiesen. Keine Serverobjekt-, Login-, Schlüssel- oder Labmigration.
        Dieselbe OperationId mit identischem Request liefert einen terminalen
        Nachweis zurück oder versucht ausschließlich sicheren Whole-Run-Cleanup.
        Ein begonnenes RESTORE wird niemals wiederholt. Unbestätigte SQL-Beendigung
        oder Ownership ergibt RECOVERY_REQUIRED. Laufzeitjournale bleiben lokal.
    .PARAMETER SourceRunId
        Bestehender verwalteter Quell-Run; wird ausschließlich gelesen.
    .PARAMETER SourceInstanceId
        SQL-2025-Linux-Instanz der Quelle.
    .PARAMETER SourceDatabaseName
        Bereits ONLINE/READ_ONLY geschaltete Benutzerdatenbank.
    .PARAMETER BackupSetId
        REUSABLE Backup dieser Quelle unter DataRoot; muss bereits read-only sein.
    .PARAMETER TargetDatabaseName
        Name der neuen Datenbank im ausschließlich eigenen Ziel-Run.
    .PARAMETER OperationId
        Stabile neue GUID; bei Wiederaufnahme unverändert wiederverwenden.
    .PARAMETER DataRoot
        Registrierter Lab_Data-Root der Backupbibliothek.
    .PARAMETER StateRoot
        Lokaler State-Root; Standard ist der konfigurierte Lab-State.
    .PARAMETER RestoreTimeoutSeconds
        SQL-RESTORE-Frist zwischen 30 und 900 Sekunden. Timeout ist kein Rollback.
    .EXAMPLE
        Invoke-SqlServerLabPortableContainerTransfer -SourceRunId $source.RunId -SourceInstanceId primary -SourceDatabaseName Demo -BackupSetId $backup.BackupSetId -TargetDatabaseName DemoCopy -OperationId $operationId -DataRoot 'D:\Lab_Data' -WhatIf
        Zeigt den gebündelten Zielerstellungs-/Transferauftrag ohne Mutation.
    .OUTPUTS
        PSCustomObject mit OperationId, Status, TargetRunId, TargetInstanceId,
        Comparison, CleanupStatus und FailureCode; keine Endpunkte oder Secrets.
    .NOTES
        Erfolg bedeutet MATCH und bereinigtes Staging bei bewusst erhaltenem
        Ziel-Run. Remove-SqlServerLab entfernt später dessen eigene Ressourcen.
    #>
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][guid]$SourceRunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$SourceInstanceId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$SourceDatabaseName,
        [Parameter(Mandatory)][guid]$BackupSetId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$TargetDatabaseName,
        [Parameter(Mandatory)][guid]$OperationId,
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$StateRoot,
        [ValidateRange(30,900)][int]$RestoreTimeoutSeconds=600
    )
    if($SourceRunId -eq [guid]::Empty -or $BackupSetId -eq [guid]::Empty -or $OperationId -eq [guid]::Empty -or
        $SourceDatabaseName -in @('master','model','msdb','tempdb') -or $TargetDatabaseName -in @('master','model','msdb','tempdb')){throw 'TRANSFER_REQUEST_INVALID'}
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $request=[pscustomobject][ordered]@{OperationId=$OperationId.ToString('D');SourceRunId=$SourceRunId.ToString('D');SourceInstanceId=$SourceInstanceId;SourceDatabaseName=$SourceDatabaseName;BackupSetId=$BackupSetId.ToString('D');TargetDatabaseName=$TargetDatabaseName;RestoreTimeoutSeconds=$RestoreTimeoutSeconds}
    if(-not $PSCmdlet.ShouldProcess("Operation $OperationId",'Neuen eigenen SQL-2025-Run erstellen, genau eine Datenbank übertragen; bei Fehler nur den eigenen Run bereinigen')){
        return [pscustomobject]@{ContractVersion='SqlServerLab.PortableContainerTransfer/1.0';OperationId=$request.OperationId;Status='WHATIF';TargetRunId=$null;TargetInstanceId='primary';Comparison='NOT_EXECUTED';CleanupStatus='NO_MUTATION_PERFORMED';FailureCode=$null}
    }
    try {Invoke-LabPortableContainerTransfer -Request $request -DataRoot $DataRoot -StateRoot $StateRoot}
    catch {if($_.Exception.Message -match '^TRANSFER_[A-Z_]+$'){throw $_.Exception.Message};throw 'TRANSFER_REQUEST_OR_PREFLIGHT_FAILED'}
}
