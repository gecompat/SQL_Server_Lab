# [monitor].[USP_InMemoryOltpAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Analysiert XTP-Tabellen, Hashindizes, Checkpoints, Transaktionen und Resource Pools.<br>
**Beobachtungsart:** Runtime- und Katalogsnapshot<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie sind Memory-Optimized-Objekte, Indizes, Memoryverbrauch und Persistenz-/Checkpointpfade konfiguriert und belastet?** Sie unterstützt die Entscheidung, ob das Spezialfeature vorhanden und in einem auffälligen Zustand ist und welches featureeigene Diagnoseverfahren als Nächstes gebraucht wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Korrektheit der Featurekonfiguration, keine geschützten Inhalte und keine End-to-End-Funktionsprüfung außerhalb sichtbarer Metadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_InMemoryOltpAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @MitHashIndexStats = 0,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `findings`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer XTP-Tabelle, einem Index, Hashstatistik, Checkpointzustand, Transaktionssignal, Pool oder Finding.

## So lesen

Berücksichtigen Sie Tabellenmemory, Bucket Count, Chainlängen, leere Buckets, Checkpointfiles, aktive Transaktionen und Poolauslastung gemeinsam.

## Warum kann das problematisch sein?

Lange Hashketten verursachen mehr Vergleiche; wartende Checkpointdaten oder hohe Poolauslastung können Persistenz-/Memorydruck anzeigen.

## Wann ist es kein Problem?

Große Memorynutzung ist bei bewusst großen XTP-Tabellen normal. Absolute Größe allein genügt nicht.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Average Chain 20, Max 500, kaum leere Buckets und viele Equality Lookups: Bucketzahl wahrscheinlich zu klein. Prüfen Sie Workload, Indexart, Pool und Checkpoints.

**Ähnlich aussehender Gegenfall:** Große Memorynutzung ist bei bewusst großen XTP-Tabellen normal. Absolute Größe allein genügt nicht. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Nicht installiert, nicht aktiviert, in der gewählten Datenbank nicht verwendet und nicht abfragbar sind vier verschiedene Zustände.

Für `USP_InMemoryOltpAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, Problemscope, Objektfilter und `@MitHashIndexStats = 0`; gelesen werden Kataloge und die übrigen XTP-Snapshot-DMVs. |
| Teuerster Pfad | Alle sichtbaren Datenbanken ohne Objektfilter, unbegrenzte Ausgabe und `@MitHashIndexStats = 1`. Die Hashindex-DMV kann nach Produktdokumentation vollständige In-Memory-Tabellen scannen. |
| Haupttreiber | Zahl gewählter Datenbanken, speicheroptimierter Tabellen/Indizes, XTP-Memory-Consumer, Checkpointdateien und aktueller XTP-Transaktionszeilen. Nutzdatenzeilen werden nicht gelesen, doch große Checkpoint-/Consumerinventare verbreitern den Runtimepfad. |
| Skalierung | Basispfad wächst mit In-Memory-Tabellen, Speicherconsumern, Checkpointdateien und aktiven XTP-Transaktionen. Der opt-in Hashpfad wächst zusätzlich mit den zu scannenden Tabellen-/Indexstrukturen und kann dominant werden. |
| Ressourcen | CPU und Speicher für XTP-DMVs, Katalog-/Checkpointmetadaten, dynamisches SQL und temporäre Resultate; der Hashpfad kann erhebliche CPU-/Speicherzugriffe in In-Memory-Tabellen verursachen. |
| Begrenzungswirkung | Datenbank-/Objektfilter begrenzen viele Katalog- und Basispfade. `@MaxZeilen` wird erst je fertigem Resultset angewandt. Insbesondere begrenzt es den Tabellenvollscan von `sys.dm_db_xtp_hash_index_stats` nicht. |
| Locking und Nebenwirkungen | Rein lesend; keine XTP-DDL oder Datenänderung. Runtime-DMVs sind flüchtig und nicht atomar. Der Hashindexscan kann trotz fehlender Benutzerlocks spürbare Konkurrenz um CPU/Speicher erzeugen. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`, `OBJECT_ANALYSIS_CURRENT`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine bekannte `ExampleDatabase`, enger Objektfilter und Hashstatistik aus. Den Hashpfad erst nach Baseline, außerhalb der Lastspitze und mit `@HighImpactConfirmed = 1` aktivieren. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Runtime- und Katalogsnapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie sind Memory-Optimized-Objekte, Indizes, Memoryverbrauch und Persistenz-/Checkpointpfade konfiguriert und belastet?

### Technischer Hintergrund

In-Memory OLTP speichert Rows in Memory und nutzt MVCC statt klassischer Page Locks/Latches. Hashindizes verteilen Schlüssel auf Buckets; Rangeindizes verwenden Bw-Trees. Durable Tabellen schreiben Log und Checkpoint File Pairs; SCHEMA_ONLY nicht. Garbage Collection entfernt nicht mehr sichtbare Versionen.

### Datenkette

`sys.databases`, `sys.dm_db_xtp_checkpoint_files`, `sys.dm_db_xtp_hash_index_stats`, `sys.dm_db_xtp_memory_consumers`, `sys.dm_db_xtp_table_memory_stats`, `sys.dm_db_xtp_transactions`, `sys.dm_resource_governor_resource_pools`, `sys.filegroups`, `sys.hash_indexes`, `sys.schemas`, `sys.sp_executesql`, `sys.table_types`, `sys.tables`.

### Source Select

Der Speicherpfad verbindet Memory-Optimized-Tabellen mit den XTP-Tabellenstatistiken:

```sql
SELECT
      [s].[name] AS [SchemaName]
    , [t].[name] AS [TableName]
    , [m].[memory_allocated_for_table_kb]
    , [m].[memory_used_by_table_kb]
    , [m].[memory_allocated_for_indexes_kb]
    , [m].[memory_used_by_indexes_kb]
FROM [sys].[tables] AS [t] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [t].[schema_id]
LEFT JOIN [sys].[dm_db_xtp_table_memory_stats] AS [m] WITH (NOLOCK)
  ON [m].[object_id] = [t].[object_id]
WHERE [t].[is_memory_optimized] = 1
  AND [s].[name] = N'ExampleSchema'
  AND [t].[name] = N'ExampleObject';
```

**Wichtig für die Eigenlast:** Objekt vor Hash-Index-, Checkpoint-File- und Transaction-DMVs bestimmen. Der breite Checkpoint- und Consumerpfad ist nur bei bestätigtem XTP-Symptom erforderlich.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Katalog- und Runtimezustand. Memory-, Transaction- und Checkpointwerte gelten teilweise seit dem Start; der Objektbestand ist aktuell.

### Bewertung und Gegenprobe

Berücksichtigen Sie Table Durability, Rows/Memory, Hash Bucket Count, Empty/Chainverteilung, Indexart, GC/Transactionalter, Checkpointstorage und Database Memoryquota gemeinsam. Hashketten benötigen Datenverteilungs-/Lookupkontext.

### Typische Fehlinterpretation

Viele Empty Buckets allein sind nicht automatisch schlecht; lange Chains sind besonders bei häufigen Equality Lookups relevant. Memory-Optimized heißt nicht logfrei oder ohne Capacitygrenze.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Current Transactions/Memory, Querypläne, XTP DMVs und Checkpoint-/Logstorage.

## Primärquellen

- [In-Memory OLTP](https://learn.microsoft.com/en-us/sql/relational-databases/in-memory-oltp/overview-and-usage-scenarios?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md#3-monitorusp_inmemoryoltpanalysis)
