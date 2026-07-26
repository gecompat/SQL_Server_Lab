# [monitor].[USP_BackupChainAnalysis]

**Bereich:** Infrastruktur<br>
**Zweck:** Prüft Full-/Diff-/Log-Beziehungen, LSN-Folgen und optionale Restoreevidenz.<br>
**Beobachtungsart:** persistierte, retentionbegrenzte Historie<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Ist aus sichtbaren Backupsets eine technisch konsistente Restorekette mit passender Full-/Diff-/Log-LSN-Folge rekonstruierbar?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_BackupChainAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @HistoryDays = 35,
      @MitRestoreEvidence = 1,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `summary`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile ein Backup, eine Kettenbeziehung, ein LSN-Segment, Restoreevidenz oder ein Finding.

## So lesen

Berücksichtigen Sie Full-Basis, Differential Base, Log-LSN-Folge und Gaps in zeitlicher Reihenfolge.

## Warum kann das problematisch sein?

Eine unterbrochene LSN-Kette kann Point-in-Time-Restore verhindern. Vorhandene Dateien garantieren keine wiederherstellbare Folge.

## Wann ist es kein Problem?

Copy-only Full verändert die Differential Base nicht und darf nicht als Kettenbruch bewertet werden.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Full und viele Logbackups vorhanden, aber ein LSN-Segment fehlt: Restore bis zum Ende nicht möglich. Testen Sie Medien und echten Restore.

**Ähnlich aussehender Gegenfall:** Copy-only Full verändert die Differential Base nicht und darf nicht als Kettenbruch bewertet werden. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_BackupChainAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine `ExampleDatabase`, 35 Tage Backuphistorie, Restoreevidenz aktiv und endliches Limit; der letzte nicht-copy-only Full vor dem Fenster wird als Kettenanker zusätzlich gelesen. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, `@HistoryDays = 3650`, Restoreevidenz und unbegrenzte Ausgabe auf einer msdb mit sehr langer Backup-/Restore-Retention. |
| Haupttreiber | Zahl ausgewählter Datenbanken sowie Full-/Diff-/Log-Backupsets und optionaler Restore-Historyzeilen im Lookback. Häufige Logbackups vergrößern LSN-Sortierung und Kettenkorrelation besonders stark. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_BackupChainAnalysis ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU und I/O auf Katalogen beziehungsweise msdb-Historie; TempDB für Korrelation und Transfer bei langen Meldungen. |
| Begrenzungswirkung | Datenbankscope und `@HistoryDays` begrenzen Backupquellen, wobei der letzte Full vor dem Fenster bewusst zusätzlich gesucht wird. `@MitRestoreEvidence = 0` lässt Restorehistory aus. `@MaxZeilen` wirkt erst je fertigem Summary-/Backupresultset. |
| Locking und Nebenwirkungen | Read-only; kurze Schema-Stability-Zugriffe auf msdb/Systemkataloge. Jobs, Backups oder Wartung laufen parallel weiter, daher ist das Ergebnis nicht atomar. |
| Schutzmechanismus | Der Datenbankkandidatenpfad verwendet `@AnalysisClass = NULL`; `@HighImpactConfirmed` aktiviert hier keinen Deep-Pfad. Schutz bieten explizite Datenbank, Historyfenster und optional ausgelassene Restoreevidenz. |
| Sicherer Einsatz | Eine `ExampleDatabase`, 35 Tage und endliches Limit; Restoreevidenz nur auslassen, wenn die Entscheidung sie nachweislich nicht benötigt. Lange Retentionen datenbankweise prüfen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierte, retentionbegrenzte Historie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Ist aus sichtbaren Backupsets eine technisch konsistente Restorekette mit passender Full-/Diff-/Log-LSN-Folge rekonstruierbar?

### Technischer Hintergrund

Fullbackups definieren Database Backup LSN/Checkpoint; Differentials basieren auf Differential Base; Logbackups decken First/Last LSN und Recovery Forks ab. CopyOnly beeinflusst Differential Base beziehungsweise Logkette unterschiedlich. Restorefolge muss LSN- und Forkkonsistenz wahren.

### Datenkette

`msdb.dbo.backupset`, `msdb.dbo.restorehistory`.

### Source Select

Die Kette beginnt bei `backupset`; Restorehistorie wird über `backup_set_id` korreliert:

```sql
SELECT
      [bs].[database_name]
    , [bs].[backup_set_id]
    , [bs].[type]
    , [bs].[backup_start_date]
    , [bs].[backup_finish_date]
    , [rh].[restore_date]
FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
LEFT JOIN [msdb].[dbo].[restorehistory] AS [rh] WITH (NOLOCK)
  ON [rh].[backup_set_id] = [bs].[backup_set_id]
WHERE [bs].[database_name] = N'ExampleDatabase'
  AND [bs].[backup_finish_date] >= DATEADD(DAY, -30, GETDATE());
```

**Wichtig für die Eigenlast:** Datenbank und Zeitfenster gehören in die erste `backupset`-Abfrage. Ohne diese Einschränkungen wachsen Sortierung und Kettenbildung mit der gesamten `msdb`-Historie.

### Zeit- und Scope-Modell

Die Auswertung verwendet `msdb`-Metadaten aus dem gewählten Fenster; ein zu kurzes Fenster kann die notwendige Basis ausblenden.

### Bewertung und Gegenprobe

Prüfen Sie Recovery Fork, Full-Basis, Differential Base, Log First und Last LSN, Gap- und Overlapindikatoren, CopyOnly und Backupzeiten. Bewerten Sie die Kette für den gewünschten Restorezeitpunkt.

### Typische Fehlinterpretation

Metadatenkonsistenz beweist nicht, dass Medien vorhanden, unbeschädigt, entschlüsselbar oder zugreifbar sind. Ein vermeintliches Gap kann durch außerhalb des Fensters liegende Sets entstehen.

### Folgeanalyse

Führen Sie für die weitere Analyse einen echten Restoretest durch und verwenden Sie `USP_BackupRecovery` sowie die Encryption- und Certificate-Governance.

## Primärquellen

- [Backup history and header information](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-history-and-header-information-sql-server?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: SQL Server Backup – betriebliche Backup-Praxis](https://ola.hallengren.com/sql-server-backup.html)

[Technische Detailbeschreibung](../07_Infrastructure.md#9-monitorusp_backupchainanalysis)
