# [monitor].[USP_BackupRecovery]

**Bereich:** Infrastruktur<br>
**Zweck:** Bewertet Backupalter, Recovery Model, Logbackupbedarf und Restorehistorie.<br>
**Beobachtungsart:** persistierte, retentionbegrenzte Historie<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Existieren im sichtbaren Fenster die erwarteten Full-, Differential- und Logbackups für das Recoverymodell?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_BackupRecovery]
      @DatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `freshness`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Hauptzeile beschreibt den Backup-/Recoveryzustand einer Datenbank; Historienresultsets enthalten einzelne Backup- oder Restoreereignisse.

## So lesen

Berücksichtigen Sie Recovery Model, Alter von Full/Diff/Log, letzte erfolgreiche Sicherung, Copy-only und Restorehistorie gemeinsam.

## Warum kann das problematisch sein?

Alte oder fehlende Logbackups vergrößern möglichen Datenverlust und können bei FULL/BULK_LOGGED die Log-Wiederverwendung verhindern.

## Wann ist es kein Problem?

In SIMPLE Recovery sind Logbackups nicht vorgesehen. Eine fehlende Differential-Sicherung kann durch die Backupstrategie abgedeckt sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** FULL Recovery, letztes Logbackup vor sechs Stunden, RPO 30 Minuten: kritisch. SIMPLE plus kein Logbackup: erwartbar. Prüfen Sie Backupkette und echten Restore-Test.

**Ähnlich aussehender Gegenfall:** In SIMPLE Recovery sind Logbackups nicht vorgesehen. Eine fehlende Differential-Sicherung kann durch die Backupstrategie abgedeckt sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_BackupRecovery` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine `ExampleDatabase` mit Freshnessbewertung, bis zu 5000 Backupzeilen und optionaler Restorehistory. Die Warnschwellen sind Bewertungsgrenzen, kein History-Cutoff. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, `@MaxZeilen = 0` und Restorehistory aktiv auf einer msdb mit sehr umfangreicher Backup-/Restorehistorie. |
| Haupttreiber | Zahl ausgewählter Datenbanken sowie Backupset-, Medien- und Restore-Historyzeilen im Lookback. Lange Aufbewahrung und häufige Logbackups vergrößern die msdb-Quellen deutlich stärker als die aktuelle Datenbankzahl allein. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_BackupRecovery ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU und I/O auf Katalogen beziehungsweise msdb-Historie; TempDB für Korrelation und Transfer bei langen Meldungen. |
| Begrenzungswirkung | Datenbankliste/-pattern begrenzen alle msdb-Joins. `@MitRestoreHistory = 0` lässt diesen Pfad aus. `@MaxZeilen` wird auf Backup- und Restoreausgabe angewandt; die Freshnessaggregation über Backupset kann zuvor mehr Zeilen prüfen. Warnstunden/-minuten verändern nur Klassifikation. |
| Locking und Nebenwirkungen | Read-only; kurze Schema-Stability-Zugriffe auf msdb/Systemkataloge. Jobs, Backups oder Wartung laufen parallel weiter, daher ist das Ergebnis nicht atomar. |
| Schutzmechanismus | `@AnalysisClass = NULL`; `@HighImpactConfirmed` schaltet keinen Deep-Pfad frei. Die wirksamen Grenzen sind Datenbankscope, endliches Zeilenlimit und der Restorehistory-Schalter. |
| Sicherer Einsatz | Eine `ExampleDatabase`, endliches Limit und nur benötigte Restorehistory. Auf msdb mit langer Retention zunächst Freshness/Summary lesen, bevor Detailmengen erweitert werden. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierte, retentionbegrenzte Historie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Existieren im sichtbaren Fenster die erwarteten Full-, Differential- und Logbackups für das Recoverymodell?

### Technischer Hintergrund

`msdb` speichert Backup Sets, Medien-/Dateiinformation, Type, LSNs, Start/Finish, Size/Compression/Checksum und Damageindikatoren. Recovery Model bestimmt, ob eine kontinuierliche Logkette erwartet wird.

### Datenkette

`msdb.dbo.backupmediafamily`, `msdb.dbo.backupset`, `msdb.dbo.restorehistory`.

### Source Select

Backupsets werden über `media_set_id` mit den physischen Medien und optional über `backup_set_id` mit Restores verbunden:

```sql
SELECT
      [bs].[database_name]
    , [bs].[type]
    , [bs].[backup_finish_date]
    , [bmf].[physical_device_name]
    , [rh].[restore_date]
FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
LEFT JOIN [msdb].[dbo].[backupmediafamily] AS [bmf] WITH (NOLOCK)
  ON [bmf].[media_set_id] = [bs].[media_set_id]
LEFT JOIN [msdb].[dbo].[restorehistory] AS [rh] WITH (NOLOCK)
  ON [rh].[backup_set_id] = [bs].[backup_set_id]
WHERE [bs].[database_name] = N'ExampleDatabase'
  AND [bs].[backup_finish_date] >= DATEADD(DAY, -30, GETDATE());
```

**Wichtig für die Eigenlast:** Begrenzen Sie zuerst `backupset` nach Datenbank und Zeit. Binden Sie Medien- und Restorezeilen erst anschließend an; ein Backupset kann mehrere Media-Family-Zeilen besitzen.

### Zeit- und Scope-Modell

Die Auswertung berücksichtigt die Historie innerhalb der `msdb`-Retention; Datenträger und Dateien werden nicht geöffnet.

### Bewertung und Gegenprobe

Prüfen Sie die letzten Backupzeiten gegen RPO und Policy. Berücksichtigen Sie außerdem Recovery Model, CopyOnly, Checksum, Damage, Größe, Dauer und Logbackupkontinuität. SIMPLE benötigt keine Logbackups; FULL ohne regelmäßige Logbackups verhindert die Logtruncation.

### Typische Fehlinterpretation

Eine erfolgreiche Backup-Historyzeile beweist weder Dateiexistenz noch erfolgreichen Restore. `RESTORE VERIFYONLY` ist ebenfalls kein vollständiger Restoretest.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_BackupChainAnalysis`, Database Integrity und regelmäßiger echter Restoretest.

## Primärquellen

- [Backup und Restore](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/back-up-and-restore-of-sql-server-databases?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: SQL Server Backup – betriebliche Backup-Praxis](https://ola.hallengren.com/sql-server-backup.html)

[Technische Detailbeschreibung](../07_Infrastructure.md#5-monitorusp_backuprecovery)
