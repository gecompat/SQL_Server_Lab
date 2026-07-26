# [monitor].[USP_PurgeSnapshotData]

**Bereich:** Optionales Snapshot-/Baseline-Paket SC-023
**Zweck:** Entfernt ausschließlich abgelaufene Snapshotdaten in begrenzten Child-first-Batches.

```sql
EXEC [monitor].[USP_PurgeSnapshotData]
     @MaxBatches = 10,
     @Force = 0,
     @ResultSetArt = 'CONSOLE';
```

## Eine Zeile bedeutet

Eine `purge`-Zeile beschreibt einen technischen Löschlauf: Batches, gelöschte Zeilenzahlen, Größenbezug, Budgetstatus und Fehlergrenze. Sie enthält keine Kopie gelöschter Payloads.

## So lesen

`AVAILABLE_LIMITED` bedeutet, dass das Batchbudget vor vollständigem Abarbeiten erreicht wurde; der nächste Lauf setzt fort. `BudgetExceeded=1` kann trotz erfolgreichem Löschen bestehen, weil nicht abgelaufene Evidenz geschützt bleibt.

## Warum kann das problematisch sein?

Unbegrenzte Deletes erhöhen Log, Locks und Wiederherstellungszeit. Ein Löschverfahren, das beim Größenlimit auch frische Daten entfernt, würde die interpretierbare Baseline ohne ausdrückliche Entscheidung zerstören.

## Wann ist es kein Problem?

`SKIPPED_NOT_DUE` ist bei noch nicht erreichtem Purgeintervall normal. Null gelöschte Zeilen sind korrekt, wenn keine Evidenz abgelaufen ist; sie beweisen nicht, dass die Datenbank unter dem Softbudget liegt.

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wurden nur abgelaufene Daten in kontrollierter Menge entfernt, ohne frische Evidenz oder Historie bei Deinstallation anzutasten?

### Technischer Hintergrund

Der Purge löscht MetricSample und PayloadSnapshot zuerst, anschließend ModuleStatus, leere CaptureRuns und verwaiste Nicht-Server-Scopes. Jede Schleife besitzt eine konfigurierte Zeilen- und eine aufrufbezogene Batchgrenze.

### Datenkette

RetentionPolicy → Ablaufgrenzen → child-first Deletes → PurgeRun-Summen → erneute Größenbewertung.

### Source Select

Der Purge liest zuerst die aktive Retentionpolicy im Ziel und leitet daraus die Ablaufgrenzen für die Child-Tabellen ab:

```sql
SELECT
      [p].[RetentionPolicyCode]
    , [p].[RawRetentionDays]
    , [p].[PayloadRetentionDays]
    , [p].[RollupRetentionDays]
    , [p].[PurgeBatchRows]
    , [p].[SoftBudgetMB]
FROM [ExampleSnapshotDatabase].[snapshot].[RetentionPolicy] AS [p] WITH (NOLOCK)
WHERE [p].[IsFrameworkDefault] = 1;
```

**Wichtig für die Eigenlast:** Der eigentliche Pfad ist schreibend: abhängige Payload-, Metric-, Module- und Runzeilen werden child-first in kleinen Batches gelöscht. Ablaufzeit und Batchgröße begrenzen Log, Locks und Laufzeit; `@MaxBatches` ist der operative Schutz. `ExampleSnapshotDatabase` ist synthetisch.

### Zeit- und Scope-Modell

Ablaufgrenzen werden aus `SYSUTCDATETIME()` berechnet. Raw- und Payloadretention sind getrennt; Rollupretention ist bereits reserviert, Rollups gehören aber nicht zum ersten Slice.

### Bewertung und Gegenprobe

Vergleichen Sie vor und nach dem Lauf nur technische Summen und weisen Sie stichprobenartig nach, dass ein neuer synthetischer Run bestehen blieb. Die Datenbankdateigröße kann trotz logischer Löschung allokiert bleiben.

### Typische Fehlinterpretation

Ein erfolgreiches Purge schrumpft keine Datei und ist kein Auftrag zu `DBCC SHRINK*`. Softbudget und physische Dateigröße sind unterschiedliche Betriebsgrößen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: RetentionPolicy, CaptureRun-Status, Datenbankkapazität und Backup-/Recoveryplanung der Snapshot-Datenbank.

[Technische Detailbeschreibung](../../Operations/Snapshot_Baseline_Operations.md)
