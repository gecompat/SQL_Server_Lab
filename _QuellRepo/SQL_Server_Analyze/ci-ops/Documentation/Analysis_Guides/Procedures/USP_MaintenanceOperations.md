# [monitor].[USP_MaintenanceOperations]

**Bereich:** Infrastruktur<br>
**Zweck:** Korrelierte read-only Sicht auf resumierbare Indexoperationen, technische Wartungsrequests, ADR/PVS und ausdrücklich ausgewählte Agent-Jobs.<br>
**Beobachtungsart:** Runtime-Snapshot + persistierter Operationszustand<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Wartungsoperationen laufen, sind pausiert/resumable oder blockiert, und wie belastbar ist ihre Fortschrittsanzeige?** Sie unterstützt die Entscheidung, ob Betriebsbereitschaft, Wiederherstellbarkeit oder verteilte Datenbewegung auffällig ist und welcher zuständige Teilprozess geprüft werden muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen erfolgreichen Restore, Failover oder End-to-End-Datenfluss nur aus Konfigurations- und Historymetadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_MaintenanceOperations]
      @DatabaseNames = N'[ExampleDatabase]',
      @NurProblematisch = 1,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `resumableOperations`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer resumierbaren Indexoperation, einem laufenden Wartungsrequest, dem ADR/PVS-Zustand einer Datenbank, einem ausdrücklich gefilterten Job oder einem Quellenstatus.

## So lesen

Prüfen Sie zuerst Quellenstatus und Versionsgrenze. Ein pausierter resumierbarer Vorgang wird mit Alter und Fortschritt gelesen. Bewerten Sie bei Requests Blockierung, Wait, Fortschritt und Engine-Schätzung gemeinsam. PVS ist eine Momentaufnahme. Ohne `@JobNames` oder `@JobNamePattern` ist die Jobquelle absichtlich `NOT_REQUESTED`.

## Warum kann das problematisch sein?

Lange pausierte Indexoperationen, blockierte Wartung oder eine große PVS mit abgebrochenen Transaktionen können Ressourcen binden und geplante Wartungsziele verfehlen. Überlappende ausdrücklich gewählte Jobs können konkurrieren.

## Wann ist es kein Problem?

Eine Pause, eine lange Dauer, ein hoher I/O-Zähler oder ein laufender Rollback können beabsichtigt beziehungsweise arbeitsmengenbedingt sein. Ein einzelner PVS-Wert beweist keine Bereinigungsstörung. Jobnamen werden ohne explizite Auswahl nicht gelesen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Lange pausierte Indexoperationen, blockierte Wartung oder eine große PVS mit abgebrochenen Transaktionen können Ressourcen binden und geplante Wartungsziele verfehlen. Überlappende ausdrücklich gewählte Jobs können konkurrieren.

**Ähnlich aussehender Gegenfall:** Eine Pause, eine lange Dauer, ein hoher I/O-Zähler oder ein laufender Rollback können beabsichtigt beziehungsweise arbeitsmengenbedingt sein. Ein einzelner PVS-Wert beweist keine Bereinigungsstörung. Jobnamen werden ohne explizite Auswahl nicht gelesen. Derselbe Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei einer zeitgleichen SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Ein leerer Historypfad kann Retention/Cleanup, deaktivierte Komponente oder falschen Scope bedeuten; er beweist keine erfolgreiche Ausführung.

Für `USP_MaintenanceOperations` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

Die Procedure führt kein `RESUME`, `ABORT`, `KILL`, Cleanup, Job-Start oder Job-Stop aus. Sie liest keine SQL-Texte, Jobschritte, Jobbefehle, Meldungen, Konten, Clientdaten oder Wait-Ressourcen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Eine `ExampleDatabase`, Problemscope und ausdrücklich gewählte Agent-Jobs; aktueller Snapshot resumierbarer Operationen, Wartungsrequests und ADR/PVS. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, ungefilterte Jobauswahl, `@MaxZeilen = 0` und Problemscope aus bei vielen resumierbaren Indexoperationen, Requests, PVS-Zeilen und Jobs. Es gibt kein Historyfenster. |
| Haupttreiber | Zahl gewählter Datenbanken mit resumierbaren Indexoperationen/ADR-PVS-Kontext, aktuell passender technischer Requests und ausdrücklich ausgewählter Agent-Jobs samt Aktivität. Ohne Jobauswahl wird kein breites Jobinventar geöffnet. |
| Skalierung | Aufwand wächst mit Datenbanken, `sys.index_resumable_operations`, passenden Live-Requests, ADR/PVS-Metadaten und der gewählten Jobmenge. Teilquellen werden separat materialisiert und bewertet. |
| Ressourcen | CPU und Katalog-/DMV-/msdb-I/O sowie temporäre Tabellen für vier nicht atomare Snapshots; keine SQL-/Jobsteptexte oder Wait-Ressourcen. |
| Begrenzungswirkung | Datenbank- und Jobfilter begrenzen jeweilige Quellen. `@NurProblematisch` und `@MaxZeilen` wirken erst beim Ausgeben der bereits vollständig gesammelten Teilresultsets. |
| Locking und Nebenwirkungen | Read-only; kurze Schema-Stability-Zugriffe auf msdb/Systemkataloge. Jobs, Backups oder Wartung laufen parallel weiter, daher ist das Ergebnis nicht atomar. |
| Schutzmechanismus | Der Datenbankkandidatenpfad verwendet `@AnalysisClass = NULL`; `@HighImpactConfirmed` schaltet keinen Deep-Pfad frei. Schutz bieten Datenbank-/Jobscope, Problemscope und Locktimeout. |
| Sicherer Einsatz | Eine `ExampleDatabase`, kleine explizite Jobliste und `@NurProblematisch = 1`; Teilquellenstatus vor einer Korrelation lesen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Runtime-Snapshot + persistierter Operationszustand“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Wartungsoperationen laufen, sind pausiert/resumable oder blockiert, und wie belastbar ist ihre Fortschrittsanzeige?

### Technischer Hintergrund

Aktive BACKUP/RESTORE/DBCC/INDEX-Commands erscheinen in Requests; resumable Indexoperationen besitzen persistierte Katalogzeilen mit State, Start/Pause, Prozent und Ressourcenoptionen. Locks, Log, TempDB und I/O können die Laufzeit dominieren.

### Datenkette

`msdb.dbo.sysjobactivity`, `msdb.dbo.sysjobs`, `msdb.dbo.syssessions`, `sys.databases`, `sys.dm_exec_requests`, `sys.dm_tran_persistent_version_store_stats`, `sys.index_resumable_operations`.

### Source Select

Der aktuelle Requestpfad filtert Wartungsbefehle direkt an der DMV und ergänzt nur den Datenbanknamen:

```sql
SELECT
      [r].[session_id]
    , [r].[request_id]
    , [d].[name] AS [DatabaseName]
    , [r].[command]
    , [r].[percent_complete]
    , [r].[estimated_completion_time]
    , [r].[blocking_session_id]
    , [r].[wait_type]
FROM [sys].[dm_exec_requests] AS [r] WITH (NOLOCK)
LEFT JOIN [sys].[databases] AS [d] WITH (NOLOCK)
  ON [d].[database_id] = [r].[database_id]
WHERE [r].[session_id] <> @@SPID
  AND
  (
       [r].[command] LIKE N'ALTER INDEX%'
    OR [r].[command] LIKE N'DBCC%'
    OR [r].[command] LIKE N'BACKUP%'
    OR [r].[command] LIKE N'RESTORE%'
    OR [r].[command] LIKE N'ROLLBACK%'
  );
```

**Wichtig für die Eigenlast:** Setzen Sie Datenbankscope vor `sys.index_resumable_operations` und PVS-Statistiken. Agent-Jobaktivität nur bei angefordertem Jobfilter lesen; SQL- und Plantexte gehören bewusst nicht zu diesem Pfad.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Requestsnapshot sowie den persistierten Zustand resumierbarer Operationen.

### Bewertung und Gegenprobe

Berücksichtigen Sie Command, Status, Percent Complete, Estimated Completion, DOP, Wait und Blocker, den Log-, TempDB- und I/O-Kontext sowie Resume- und Pauseoptionen. Eine pausierte Operation kann weiterhin Speicher und Strukturzustand belegen.

### Typische Fehlinterpretation

Percent Complete ist nur für unterstützte Commands und nicht linear. Abbruch kann Rollback-/Cleanupkosten verursachen; `PAUSED` ist nicht erfolgreich abgeschlossen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Current Requests/Blocking/IO/Log und operationsspezifischer Runbook.

## Primärquellen

- [Resumable Index Operations](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/perform-index-operations-online?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)
- [Ola Hallengren: SQL Server Backup – betriebliche Backup-Praxis](https://ola.hallengren.com/sql-server-backup.html)

[Technische Detailbeschreibung](../07_Infrastructure.md)
