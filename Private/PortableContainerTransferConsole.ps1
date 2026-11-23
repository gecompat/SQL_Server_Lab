function Invoke-LabPortableContainerTransferInteractive {
    param([switch]$Preflight)

    try {
        $dataRoot = Get-LabDataRootDefault
        if (-not $dataRoot) {
            Write-LabInfo 'Richte zuerst den Lab_Data-Speicher für die Backupbibliothek ein.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $targets = @(Get-LabContainerSqlConsoleTargets)
        $backups = @(Get-LabDatabaseBackupSelection -DataRoot $dataRoot | Where-Object {
            $_.Availability -ceq 'SELECTABLE' -and $_.SourceSqlMajorVersion -ceq '17' -and
            -not $_.HasFileStream -and -not $_.IsEncrypted -and
            $_.DatabaseName -cmatch '^[A-Za-z][A-Za-z0-9_]{0,127}\z' -and
            $_.DatabaseName -notin @('master','model','msdb','tempdb') -and
            ($Preflight -or $_.Bytes -le 256MB)
        })
        $eligible = @(foreach ($backup in $backups) {
            $source = @($targets | Where-Object { $_.RunId -eq $backup.SourceRunId -and
                $_.InstanceId -eq $backup.SourceInstanceId -and $_.Provider -eq $backup.SourceProvider })
            if ($source.Count -eq 1) {
                New-LabConsoleItem -Id $backup.BackupSetId -Label ('{0} · {1}' -f $backup.DatabaseName, $source[0].Label) `
                    -Value $backup.CreatedAt -Data $backup
            }
        })
        if (-not $eligible.Count) {
            Write-LabInfo 'Kein passendes registriertes SQL-2025-Backup eines laufenden Container-Runs gefunden.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $backup = Select-LabConsoleDataItem -ScreenId 'portable-transfer-backup' -Title 'Verifiziertes Backup wählen' -Items $eligible
        if (-not $backup) { return }
        $target = $null
        if ($Preflight) {
            $choices = @(for ($index = 0; $index -lt $targets.Count; $index++) {
                if ($targets[$index].RunId -eq $backup.SourceRunId -and $targets[$index].InstanceId -eq $backup.SourceInstanceId) { continue }
                New-LabConsoleItem -Id "target-$index" -Label $targets[$index].Label -Data $targets[$index]
            })
            if (-not $choices.Count) {
                Write-LabInfo 'Die Vorprüfung benötigt einen weiteren laufenden Container mit gebundenem Backup-Mount.'
                $null = Wait-LabConsoleAcknowledgement
                return
            }
            $target = Select-LabConsoleDataItem -ScreenId 'portable-transfer-target' -Title 'Vorhandene Zielinstanz wählen' -Items $choices
            if (-not $target) { return }
        }
        do {
            $name = Read-LabConsoleTextInput -Prompt 'Zieldatenbankname' -Default $backup.DatabaseName
            if ($name.Status -ne 'Confirmed') { return }
            $valid = $name.Value -cmatch '^[A-Za-z][A-Za-z0-9_]{0,127}\z' -and $name.Value -notin @('master','model','msdb','tempdb')
            if (-not $valid) { Write-LabError 'Gültigen Namen einer Benutzerdatenbank eingeben.' }
        } until ($valid)
        $parameters = @{ DataRoot=$dataRoot; SourceRunId=$backup.SourceRunId; SourceInstanceId=$backup.SourceInstanceId }
        $selection = "$($backup.DatabaseName) · Backup $($backup.BackupSetId)"
        if ($Preflight) {
            if (-not (Read-LabConfirm -Prompt "$selection für $($target.Label) temporär bereitstellen und SQL-Medien prüfen?" -Default $false)) { return }
            $result = Invoke-SqlServerLabPortableContainerTransferPreflight @parameters -TargetRunId $target.RunId -TargetInstanceId $target.InstanceId `
                -DatabaseTransfers @([pscustomobject]@{SourceDatabaseName=$backup.DatabaseName;TargetDatabaseName=$name.Value;BackupSetId=$backup.BackupSetId}) -Confirm:$false -ErrorAction Stop
            Write-LabInfo ('Vorprüfung: {0} · Befunde: {1}' -f $result.Status, ($result.Blockers -join ', '))
        }
        else {
            $intent = Read-LabConsoleTextInput -Prompt 'Vorgangs-ID für Wiederaufnahme oder neue ID übernehmen' -Default ([guid]::NewGuid().ToString('D'))
            if ($intent.Status -ne 'Confirmed') { return }
            $operationId = [guid]::Empty
            if (-not [guid]::TryParseExact($intent.Value, 'D', [ref]$operationId) -or $operationId -eq [guid]::Empty) { throw 'TRANSFER_GUID_INVALID' }
            Write-LabInfo "Vorgangs-ID: $operationId"
            if (-not (Read-LabConfirm -Prompt "Neuen eigenen $($backup.SourceProvider)-SQL-2025-Run erstellen und $selection als $($name.Value) übertragen? Quelldatenbank muss ONLINE und READ_ONLY sein." -Default $false)) { return }
            $result = Invoke-SqlServerLabPortableContainerTransfer @parameters -SourceDatabaseName $backup.DatabaseName -BackupSetId $backup.BackupSetId `
                -TargetDatabaseName $name.Value -OperationId $operationId -Confirm:$false -ErrorAction Stop
            Write-LabInfo ('Transfer: {0} · Vergleich: {1} · Cleanup: {2} · Ziel-Run: {3} · Fehlercode: {4}' -f $result.Status, $result.Comparison, $result.CleanupStatus, $result.TargetRunId, $result.FailureCode)
        }
    }
    catch { Write-LabError 'Der Auftrag konnte nicht bestätigt werden. Prüfe den Befund und verwende bei Wiederaufnahme dieselbe Vorgangs-ID.' }
    $null = Wait-LabConsoleAcknowledgement
}
