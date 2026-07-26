# Betrieb des optionalen Snapshot-/Baseline-Pakets SC-023

Stand: 2026-07-21
Status: `IMPLEMENTED_ACTIONS_GATE`

## Paketgrenze

SC-023 ist absichtlich kein Bestandteil von `Install_All.sql`. Ohne die beiden separaten Installer bleibt der Frameworkkern zustandslos. Der erste vertikale Slice besitzt genau einen Collector: `monitor.USP_PerformanceCounters` mit `@SampleSeconds=0`. Wait-, I/O-, Datenbank-, Query-, Plan-, Rollup-, Export- und Agentjob-Pakete gehören nicht zu diesem Stand.

Die Snapshot-Datenbank darf im autorisierten Betrieb reale Laufzeitwerte speichern. Exporte, Berichte und weitergegebene Auszüge benötigen einen eigenen Datenschutz-, Empfänger- und Aufbewahrungsvertrag.

## Installation

1. Frameworkdatenbank wie üblich mit `Install_All.sql` installieren.
2. Eine eigene Ziel-Datenbank ausdrücklich anlegen. Beispielname ausschließlich für Dokumentation:

```sql
USE [master];
GO
CREATE DATABASE [ExampleSnapshotDatabase]
COLLATE SQL_Latin1_General_CP1_CS_AS;
GO
ALTER DATABASE [ExampleSnapshotDatabase] SET RECOVERY SIMPLE;
ALTER DATABASE [ExampleSnapshotDatabase] SET READ_COMMITTED_SNAPSHOT ON;
GO
```

3. Einen Installationsweg wählen:
   - SQLCMD: die beiden `Code/Install/Install_SnapshotBaseline_*.sql` aus einer vollständigen Repositorykopie verwenden;
   - Standalone: in `Code/Install` mit `./Build-SnapshotBaselineInstallers.ps1` zwei eingebettete Dateien unter `generated/` erzeugen.
4. Mit SSMS/ADS auf `ExampleSnapshotDatabase` wechseln und den Target-Installer vollständig ausführen. Beim SQLCMD-Weg muss der SQLCMD-Modus aktiv sein; das generierte Artefakt benötigt ihn nicht. Der Installer bricht in `master`, `model`, `msdb`, `tempdb`, einer offline oder read-only Datenbank ab.
5. Im Framework-Installer `[DeineDatenbank]` durch den lokalen Frameworkdatenbanknamen ersetzen und ihn anschließend vollständig ausführen. Der SQLCMD-Weg benötigt den SQLCMD-Modus; das generierte Artefakt nicht.
6. Erst danach das Ziel explizit konfigurieren:

```sql
DECLARE @Status varchar(40), @Partial bit, @Error int, @Message nvarchar(2048);
EXEC [monitor].[USP_ConfigureSnapshotTarget]
     @TargetDatabaseName = N'ExampleSnapshotDatabase',
     @IsEnabled = 1,
     @SchedulerType = 'EXTERNAL',
     @CollectionIntervalSeconds = 30,
     @MaxRows = 1000,
     @PayloadEnabled = 0,
     @RawRetentionDays = 14,
     @PayloadRetentionDays = 7,
     @RollupRetentionDays = 180,
     @SoftBudgetMB = 10240,
     @PurgeIntervalMinutes = 60,
     @PurgeBatchRows = 10000,
     @StatusCodeOut = @Status OUTPUT,
     @IsPartialOut = @Partial OUTPUT,
     @ErrorNumberOut = @Error OUTPUT,
     @ErrorMessageOut = @Message OUTPUT;
```

Beide Installer sind idempotent. Frameworkdefaults werden nur angelegt, wenn sie fehlen; lokale Nicht-Default-Policies und vorhandene Historie bleiben erhalten.

## Rechte

Das Paket erstellt keine Logins, Benutzer, Rollenmitgliedschaften oder `GRANT`-Anweisungen. Die Betriebsstelle muss getrennt entscheiden und vergeben:

- `EXECUTE` auf den drei Public APIs im Framework;
- Quellrecht für Performance Counters: typischerweise SQL Server 2019 `VIEW SERVER STATE`, ab SQL Server 2022 `VIEW SERVER PERFORMANCE STATE`;
- Zugriff auf die Frameworkdatenbank und explizite Schreib-/EXECUTE-Rechte in der Snapshot-Datenbank;
- bei SQL Agent die notwendigen Jobbesitz- und Verbindungsrechte außerhalb dieses Pakets.

Es gibt kein `EXECUTE AS OWNER`, kein `TRUSTWORTHY`-Erfordernis und keine Abhängigkeit von Cross-Database Ownership Chaining. Fehlende Rechte werden als `DENIED_PERMISSION` oder partieller Lauf gespeichert, nicht automatisch erweitert.

## Schedulerneutraler Aufruf

MANUAL, EXTERNAL und SQL_AGENT sind ausschließlich Herkunftsmetadaten. Alle verwenden denselben fachlichen Einstieg:

```sql
EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType = 'EXTERNAL',
     @RunEvenIfNotDue = 0,
     @ResultSetArt = 'CONSOLE';
```

Ein Agentjob oder externer Scheduler ruft nur diese Procedure auf; Sammellogik gehört nicht in den Job. Eine benannte Session-Applock mit Wartezeit null verhindert parallele Cycles und Purges. `SKIPPED_CONCURRENT` und `SKIPPED_NOT_DUE` lesen keine Quell-DMV.

## Persistenz- und Resetvertrag

- `CaptureRun` und `ModuleStatus` bewahren Laufstatus, Partialität und Fehlergrenze.
- `Scope`, `MetricDefinition` und `MetricSample` bilden typisierte Raw- und abgeleitete Werte ab.
- `SqlServerStartTimeUtc` bindet alle Samples eines Engine-Starts an dieselbe `ResetEpochId`; über Epochwechsel werden keine Deltas behauptet.
- `PayloadSnapshot` wird nur mit `@PayloadEnabled=1` geschrieben. Der JSON-Vertrag bleibt verlustfrei, wird GZIP-komprimiert und per SHA-256 gebunden.
- Fehlende Evidenz erzeugt kein Sample mit erfundenem Nullwert.

## Retention und Budget

```sql
EXEC [monitor].[USP_PurgeSnapshotData]
     @MaxBatches = 10,
     @Force = 0,
     @ResultSetArt = 'CONSOLE';
```

Der Purge arbeitet child-first und begrenzt jede Löschschleife durch `PurgeBatchRows` sowie den Aufruf durch `@MaxBatches`. `PURGE_EXPIRED_THEN_STOP` ist im ersten Slice der einzige Budgetmodus. Bleibt das Budget nach dem Entfernen abgelaufener Evidenz überschritten, endet der nächste Collector als `STOPPED_SIZE_BUDGET`; frische Daten werden nicht gelöscht.

`UsedDataMbBefore`/`After` basieren im ersten Slice konservativ auf der allokierten ROWS-Dateigröße. Ein Delete verkleinert deshalb weder automatisch Dateien noch diesen Wert. Das Paket führt kein Shrink aus.

## Deaktivierung und Deinstallation

`@IsEnabled=0` verhindert neue Cycles, bewahrt aber Zielkonfiguration und Historie. Reinstallation löscht nichts. Es existiert bewusst kein automatischer Drop- oder Uninstallpfad. Das Entfernen der Snapshot-Datenbank ist ein eigener ausdrücklicher, extern autorisierter Betriebsakt mit Backup-, Retention- und Recoveryentscheidung.

## Abnahmegrenze

Der Paketvertrag ist für Installertrennung, Idempotenz, Collection, Reset-Epoche, optionale Payloadverlustfreiheit, Retention, Größenstopp und Zwei-Session-Concurrency auf SQL Server 2019, 2022 und 2025 nachgewiesen. Die Plattform- und Evidenzgrenzen stehen in der [Testmatrix](../Quality/Test_Matrix.md).
