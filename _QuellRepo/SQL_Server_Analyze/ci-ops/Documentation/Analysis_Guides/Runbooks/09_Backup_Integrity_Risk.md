# Runbook: Backup- oder Integritätsrisiko

## Erstaufrufe

```sql
EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
      @DatabaseNames=N'[ExampleDatabase]',
      @MitPageDetails=0,
      @ResultSetArt='CONSOLE';
EXEC [monitor].[USP_BackupChainAnalysis]
      @DatabaseNames=N'[ExampleDatabase]',
      @ResultSetArt='CONSOLE';
```

## Auswertung

Lesen Sie Datenbankstatus, PAGE_VERIFY, CHECKDB-Alter, Suspect Pages, Backupchecksums, LSN-Gaps, Restoreevidenz und HADR-Reparaturen gemeinsam.

## Interpretation

Negative Evidenz kann auf Schaden oder nicht wiederherstellbare Ketten hinweisen. Fehlende negative Evidenz ist kein Integritätsbeweis.

## Gegenprobe

Prüfen Sie die vollständige CHECKDB-Strategie, die Backupmedien und einen real ausgeführten Restore-Test als Gegenproben.

## Nicht ableiten

Leiten Sie weder Repair noch ein Datenverlust akzeptierendes Vorgehen allein aus einem Analysefinding ab.
