# [monitor].[USP_Statistics]

**Bereich:** Object und Index<br>
**Zweck:** Inventarisiert Statistikdefinition, Materialisierung, Sample, Änderungen, inkrementelle Details und auf SQL Server 2025 die Herkunft persistierter Statistiken auf lesbaren Replikaten.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Wie aktuell und repräsentativ sind die Statistiken, die der Cardinality Estimator für Schätzungen verwendet, und aus welcher Replikatrolle stammt ihr aktuell gespeicherter Stand?** Sie unterstützt die Entscheidung, ob ein Struktur- oder Metadatensignal eine workloadbezogene Gegenprüfung rechtfertigt, nicht ob automatisch DDL ausgeführt werden soll.

## Nicht beantwortete Fragen

Die Procedure beantwortet keinen Geschäftsnutzen einer Strukturänderung, keine repräsentative Workload und keine automatische Aussage über den optimalen Index- oder Statistikzustand. Die Replikatherkunft ist insbesondere kein Verwendungsnachweis für einen Queryplan und nicht mit der aktuellen Datenbankrolle gleichzusetzen. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_Statistics]
      @DatabaseNames = N'[ExampleDatabase]',
      @FullObjectNames = N'[ExampleSchema].[ExampleTable]',
      @MitIncrementellenDetails = 0,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

`GEZIELT` verlangt einen Schema-/Objektfilter; nur eine Datenbank anzugeben ist
kein gültiger gezielter Lauf. Inkrementelle Partitionsdetails werden erst nach
der Hauptsicht und mit zusätzlichem Deep-Gate aktiviert.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `statistics` in Schema-Version 2. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

Die SQL-Server-2025-Erweiterung ergänzt sieben Spalten:

| Feld | Leserichtung |
|---|---|
| `IsTemporary` | Temporäre Statistik gemäß `sys.stats.is_temporary` |
| `CurrentReplicaRole` | Aktuelle Datenbankrolle: `HADR_DISABLED`, `PRIMARY`, `SECONDARY` oder `NOT_IN_AG_OR_UNKNOWN` |
| `CurrentReplicaRoleStatus` | Verfügbarkeit der separaten Rollenprüfung |
| `ReplicaRoleId`, `ReplicaRoleDesc` | Herkunft beziehungsweise letzte Aktualisierungsrolle der Statistik |
| `ReplicaName` | Ursprungsreplikat; bei Primary-Herkunft regulär `NULL` |
| `ReplicaMetadataStatus` | Verfügbarkeit und Konsistenz der Herkunftsevidenz |

## Eine Zeile bedeutet

Im Hauptresultset beschreibt eine Zeile eine Statistik. Inkrementelle Details besitzen eine zusätzliche Partitionsgranularität.

## So lesen

Berücksichtigen Sie Rows, Rows Sampled, Modification Counter, führende Spalte, Filter und letzten Updatezeitpunkt gemeinsam. Lesen Sie `CurrentReplicaRole` und `ReplicaRole*` getrennt: Das erste Feld beschreibt den Erfassungsort, die anderen Felder den gespeicherten Statistikursprung.

## Warum kann das problematisch sein?

Unpassendes Sample oder relevante Datenänderungen können Kardinalitätsschätzungen und dadurch Joinart, Grant und Zugriffspfad verschlechtern.

## Wann ist es kein Problem?

Eine alte Statistik kann korrekt bleiben, wenn sich relevante Daten kaum ändern. Niedriger Sample-Prozentsatz kann bei sehr großen Tabellen ausreichend sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Zehn Jahre alt plus Modification Counter 0 ist nicht automatisch schlecht. Eine gestern aktualisierte Statistik kann einen neu entstandenen Tail dennoch schlecht abbilden. Prüfen Sie Histogramm und betroffene Pläne.

**Ähnlich aussehender Gegenfall:** Eine alte Statistik kann korrekt bleiben, wenn sich relevante Daten kaum ändern. Niedriger Sample-Prozentsatz kann bei sehr großen Tabellen ausreichend sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Katalogpfaden sind Featureabwesenheit, Filter, Offline-/Permission-Scope und tatsächlich fehlende Objekte getrennte Erklärungen.

Für `USP_Statistics` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. Für `ReplicaName` ist `NULL` bei Primary-Herkunft ausdrücklich regulär. `ReplicaMetadataStatus=NOT_RECORDED` bedeutet, dass keine Herkunft aufgezeichnet ist; `PARTIAL_METADATA` markiert inkonsistente oder unvollständige Herkunftsfelder. Auf SQL Server 2019/2022 bleiben die typisierten Felder erhalten und melden `UNAVAILABLE_VERSION`. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Eine gezielte Abfrage besitzt eine moderate Eigenlast; VOLL und inkrementelle Details sind durch `CATALOG_DEEP` beziehungsweise den Cross-Database-Pfad geschützt und begrenzt.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | `GEZIELT` erfordert Schema-/Objektfilter, liest Definition/Spalten und `sys.dm_db_stats_properties` für passende Statistiken; inkrementelle Partitionsdetails sind aus. Auf SQL Server 2025 wird das Herkunftsschema einmal capability-geprüft. |
| Teuerster Pfad | `VOLL` und `@MitIncrementellenDetails = 1` über alle sichtbaren Datenbanken, ohne Schwellen und mit `@MaxZeilen = 0`: jede Statistik plus jede inkrementelle Partition wird materialisiert. |
| Haupttreiber | Zahl passender Statistiken und Statistikspalten; für inkrementelle Statistiken zusätzlich Partitionen. Tabellenzeilenzahl wirkt nur auf zurückgegebene Properties, nicht als gescannte Nutzdatenmenge. |
| Skalierung | Pro Kandidatendatenbank wird dynamisches Katalog-SQL kompiliert. `sys.stats` wird je Aufruf und Datenbank höchstens einmal gelesen; inkrementelle Details verwenden die bereits materialisierten Statistik-IDs. Cross-Database-Kosten addieren sich pro Datenbank. |
| Ressourcen | Katalogseiten, `dm_db_stats_properties`/`dm_db_incremental_stats_properties`, auf SQL Server 2025 eine kleine Spalten-Capability-Prüfung und bei aktiviertem HADR höchstens ein Aufruf von `sys.fn_hadr_is_primary_replica`; dazu CPU für Filter/Joins und TempDB/Transfer. Histogramme selbst werden hier nicht gelesen. |
| Begrenzungswirkung | Objekt-/Statistikfilter und Modification-/Altersschwellen reduzieren fachliche Zeilen. `@MaxZeilen` ist TOP je Datenbank und je Haupt-/Detailquery, kein globales Parentlimit; Gesamtzeilen können bei mehreren Datenbanken darüber liegen. |
| Locking und Nebenwirkungen | Read-only; Katalogabfragen nehmen üblicherweise kurze Schema-Stability-Zugriffe und können mit gleichzeitigem DDL oder Datenbankstatuswechseln konkurrieren. `@LockTimeoutMs` gilt nur in isolierten dynamischen Datenbankbatches; der äußere `LOCK_TIMEOUT` bleibt unverändert. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`, `STATISTICS_TARGETED`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, ein `ExampleSchema.ExampleTable`, 100 Zeilen und keine inkrementellen Details. Danach eine konkrete Statistik oder Partition vertiefen. |
| Aussagegrenze | Properties sind Metadaten zum letzten Update, nicht Histogrammqualität oder aktuelle Kardinalitätsgenauigkeit. Replikatherkunft belegt weder Statistiknutzung noch aktuelle Datenbankrolle. Modification Counter und Alter müssen mit Zeilenzahl, Filterstatistik, Partition und Planverhalten interpretiert werden. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Wie aktuell und repräsentativ sind die Statistiken, die der Cardinality Estimator für Schätzungen verwendet?

### Technischer Hintergrund

Statistiken enthalten Header, Dichteinformationen und ein Histogramm für die führende Statistikspalte mit maximal 200 Steps. Auto-/User-Created, Filter, Persisted Sample und `dm_db_stats_properties` liefern Aktualisierungs-, Row-, Sample- und Modification-Kontext. SQL Server 2025 kann auf einer lesbaren Secondary erzeugte Statistiken auf dem Primary persistieren und kennzeichnet deren Herkunft in `sys.stats`. Ein späteres Update auf dem Primary überträgt diese Herkunft; temporäre und permanente Fassungen können bis Recompilation oder Neustart nebeneinander bestehen.

### Datenkette

`sys.all_columns`, `sys.all_views`, `sys.columns`, `sys.dm_db_incremental_stats_properties`, `sys.dm_db_stats_properties`, `sys.fn_hadr_is_primary_replica`, `sys.indexes`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`, `sys.stats`, `sys.stats_columns`, `sys.tables`.

### Source Select

Zielstatistiken werden zuerst im Katalog bestimmt und erst dann an `dm_db_stats_properties` übergeben:

```sql
WITH [TargetStatistics] AS
(
    SELECT
          [st].[object_id]
        , [st].[stats_id]
        , [st].[name] AS [StatisticsName]
        , [s].[name] AS [SchemaName]
        , [o].[name] AS [ObjectName]
    FROM [sys].[stats] AS [st] WITH (NOLOCK)
    JOIN [sys].[objects] AS [o] WITH (NOLOCK)
      ON [o].[object_id] = [st].[object_id]
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [o].[schema_id]
    WHERE [s].[name] = N'ExampleSchema'
      AND [o].[name] = N'ExampleObject'
)
SELECT
      [t].[SchemaName]
    , [t].[ObjectName]
    , [t].[StatisticsName]
    , [p].[last_updated]
    , [p].[rows]
    , [p].[rows_sampled]
    , [p].[modification_counter]
FROM [TargetStatistics] AS [t]
OUTER APPLY [sys].[dm_db_stats_properties]
            ([t].[object_id], [t].[stats_id]) AS [p];
```

**Wichtig für die Eigenlast:** Objekt und Statistik vor den DMFs bestimmen. Inkrementelle Partitionsdetails nur für bereits materialisierte inkrementelle Statistiken lesen; `@MaxZeilen` nach der DMF spart deren Aufrufe nicht. Die SQL-Server-2025-Spalten werden erst nach Versions- und Capabilityprüfung in Dynamic SQL referenziert.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuell gespeicherten Statistikstand seit dem letzten Update. Der Modification Counter beschreibt Änderungen seitdem, aber nicht deren genaue Verteilungswirkung. `CurrentReplicaRole` ist ein Snapshot zum Erfassungszeitpunkt; die Herkunftsfelder sind der aktuell gespeicherte Katalogstand und keine unveränderliche Entstehungshistorie.

### Bewertung und Gegenprobe

Berücksichtigen Sie Rows, Rows Sampled, Samplingrate, Last Updated, Modifications, führende Spalte, Filter und betroffene Queryprädikate gemeinsam. Eine alte unveränderte Statistik kann korrekt sein; eine junge stark gesampelte Statistik bei Skew kann problematisch sein. Bei Secondary-Herkunft prüfen Sie die aktuelle Rolle separat und verwenden Query-/Plannachweise, bevor Sie einen Nutzen oder ein Problem unterstellen.

### Typische Fehlinterpretation

Alter oder Modification Counter allein beweist keinen Schätzfehler. Auto-Update-Schwellen und asynchrones Update sind kontextabhängig. `ReplicaRoleId=2` beweist weder, dass die aktuelle Verbindung auf einer Secondary läuft, noch dass eine konkrete Query diese Statistik verwendet. `ReplicaName=NULL` ist bei Primary-Herkunft kein Fehler.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_StatisticsDistributionAnalysis`, Showplan Estimated/Actual Rows und Query Store Regression.

## Primärquellen

- [sys.dm_db_stats_properties](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-stats-properties-transact-sql?view=sql-server-ver17)
- [sys.stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-stats-transact-sql?view=sql-server-ver17)
- [Persisted Statistics for Readable Secondary Replicas](https://learn.microsoft.com/en-us/sql/relational-databases/performance/persisted-stats-secondary-replicas?view=sql-server-ver17)
- [sys.fn_hadr_is_primary_replica](https://learn.microsoft.com/en-us/sql/relational-databases/system-functions/sys-fn-hadr-is-primary-replica-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [Ola Hallengren: Index and Statistics Maintenance – betriebliche Wartungsperspektive](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html)

[Technische Detailbeschreibung](../03_Object_Index.md#5-monitorusp_statistics)
