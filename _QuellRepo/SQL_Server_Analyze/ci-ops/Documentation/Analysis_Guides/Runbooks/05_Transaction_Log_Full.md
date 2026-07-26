# Runbook: Transaktionslog läuft voll

## Erstaufrufe

```sql
EXEC [monitor].[USP_CurrentLog] @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_CurrentTransactions] @MinAlterSekunden=60, @ResultSetArt='CONSOLE';
```

## Auswertung

Lesen Sie Used Percent und absolute Größe zusammen mit `log_reuse_wait_desc`, offenen Transaktionen, dem Alter des letzten Logbackups sowie dem AG-, Replikations- und CDC-Kontext.

## Interpretation

Hohe Nutzung ist Symptom. Der Wiederverwendungswartegrund zeigt, warum Platz nicht freigegeben wird.

## Gegenprobe

Wählen Sie abhängig vom Wiederverwendungswartegrund `USP_BackupRecovery`, `USP_AvailabilityGroups`, `USP_ReplicationStatus` oder `USP_DataCaptureStatus` als Gegenprobe.

## Nicht ableiten

Vergrößern Sie nicht ausschließlich das Log und ändern Sie nicht ohne Ursachenprüfung das Recovery Model. Berücksichtigen Sie RPO und Backupkette.
