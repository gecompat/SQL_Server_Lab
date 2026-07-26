# Draft: technische Vertiefung – Object/Index/Statistics und Plan Cache

**Stand:** 19. Juli 2026
**Status:** integriertes Authoring-Archiv; nicht kanonisch
**Abdeckung:** 17 Procedures aus `03_ObjectIndex` und `04_PlanCache`

> Der Draft beschreibt Engine- und Datenstrukturhintergrund. Er formuliert keine automatische DDL-Empfehlung. Index-, Statistik-, Missing-Index- und Showplanbefunde sind zunächst Evidenz und benötigen Workload-, Größen-, Risiko- und Abhängigkeitskontext.

## 1. Gemeinsames Strukturmodell

Eine Tabelle ist physisch als Heap, B-Tree-/Rowstore-Index, Columnstore oder Sonderstruktur organisiert. Katalogsichten beschreiben Definition und aktuellen Metadatenzustand. Usage- und Operational-DMVs akkumulieren Nutzung beziehungsweise interne Operationen über begrenzte Lebenszyklen. Physical-Stats-DMFs untersuchen Strukturen beim Aufruf und können deutlich teurer sein. Der Plan Cache zeigt, wie der Optimizer aktuell gecachte Statements ausführen wollte und welche Runtimezähler seit Entstehung des Cacheeintrags anfielen.

## 2. Object, Index und Statistics

### `[monitor].[USP_ObjectInventory]`

**Leitfrage:** Welche Objekte und physischen Zugriffsstrukturen existieren, wie groß sind sie und welche Eigenschaften besitzen sie?

**Technischer Hintergrund:** Tabellen, Views, Indizes, Spalten, Partitionen, Kompression und Allocation Units bilden mehrere Katalogebenen. Rowcount und reservierte/benutzte Seiten kommen typischerweise aus Partition Stats; Definition und Schutzmerkmale aus Objekt-/Indexkatalogen. Ein Unique Constraint oder Primary Key ist fachlich/relational geschützt, auch wenn ein Index technisch ähnlich zu einem anderen wirkt.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.allocation_units`, `sys.columns`, `sys.data_spaces`, `sys.index_columns`, `sys.indexes`, `sys.objects`, `sys.partitions`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Metadaten- und Größenstand. Rowcounts aus DMVs sind für Diagnosezwecke geeignet, aber keine transaktional exakte `COUNT_BIG(*)`-Messung.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Größe, Zeilen, Indexart, Schlüssel/Includes, Filter, Partitionierung, Kompression und Schutzmerkmale zusammen lesen. Ähnliche Schlüsselreihenfolgen können unterschiedliche Coverage, Sortierung oder Constraints bedienen.

**Typische Fehlinterpretation:** Inventar zeigt Existenz, nicht Nutzen, Nutzung oder Redundanz. Eine kleine Tabelle mit vielen Indizes kann andere Trade-offs haben als eine große schreibintensive Tabelle.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_IndexUsage`, `USP_IndexOperationalStats`, Query Store/Plan Cache und Abhängigkeitsprüfung.

### `[monitor].[USP_IndexUsage]`

**Leitfrage:** Welche sichtbaren Reads und Writes wurden einem Index seit dem DMV-Reset zugerechnet?

**Technischer Hintergrund:** `sys.dm_db_index_usage_stats` zählt user/system seeks, scans, lookups und updates sowie letzte Zeitpunkte. Ein einzelnes DML-Statement kann mehrere Indexupdates verursachen. Der Zähler erfasst nicht jede semantische Abhängigkeit, etwa Constraintwirkung oder seltene saisonale Reports.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_db_index_usage_stats`, `sys.dm_db_xtp_index_stats`, `sys.dm_os_sys_info`, `sys.hash_indexes`, `sys.indexes`, `sys.objects`, `sys.partitions`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Kumulativ seit Engine-/Datenbank-/DMV-Lebenszyklus. Restart, Detach/Attach, Offline/Online und andere Ereignisse können den Beobachtungszeitraum verkürzen.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Reads, Updates, letzte Nutzung, Uptime/Resetzeit, Indexgröße und Schutzstatus kombinieren. Viele Updates ohne Reads über ein ausreichend langes repräsentatives Fenster sind ein Reviewkandidat, kein Dropbefehl.

**Typische Fehlinterpretation:** `0 Reads` bedeutet nur keine in dieser DMV sichtbare Nutzung im Fenster. Planforcing, Query Store, Wartung, FK/Unique/PK und Monats-/Jahresworkloads gegenprüfen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_IndexOperationalStats`, Query Store, Dependency-/Constraintreview.

### `[monitor].[USP_IndexOperationalStats]`

**Leitfrage:** Welche internen Zugriffsmuster, Allocations, Locks und Latches erzeugt ein Index?

**Technischer Hintergrund:** `sys.dm_db_index_operational_stats` liefert Blatt-/Nichtblattoperationen, Range-/Singleton-Lookups, Page Allocations, Lock-/Latch-Waits und weitere Low-Level-Zähler. Diese Zähler spiegeln physische Arbeitsweise wider und ergänzen die gröbere Usage-Sicht.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_db_index_operational_stats`, `sys.indexes`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Kumulativ im Lebenszyklus der internen Struktur/Instanz. Werte können bei Neustart oder Strukturänderung zurückgesetzt werden.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Zähler durch passende Aktivität normieren: Page Allocations pro Insert, Lockwaitzeit pro Lockwait, Latchwaitzeit pro Zugriff. Hohe absolute Werte sind bei stark genutzten Indizes erwartbar.

**Typische Fehlinterpretation:** `leaf_allocation_count` ist nicht identisch mit dokumentiertem Page Split jeder Art. Eine Korrelation mit Fragmentierung/Fillfactor und DML-Muster ist nötig.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_IndexPhysicalStats`, Current Blocking/Waits und konkrete DML-Pläne.

### `[monitor].[USP_MissingIndexes]`

**Leitfrage:** Welche zusätzlichen Nonclustered-Indexstrukturen hat der Optimizer während Kompilierungen als potenziell kostensenkend eingeschätzt?

**Technischer Hintergrund:** Missing-Index-DMVs sammeln Gleichheits-, Ungleichheits- und Include-Spalten aus Optimizerentscheidungen. Der oft verwendete Improvement-Wert kombiniert geschätzte Kosten, Impact und Nutzungshäufigkeit; er ist eine Priorisierungsheuristik. Die Engine konsolidiert Vorschläge nicht automatisch mit bestehenden Indizes.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_db_missing_index_details`, `sys.dm_db_missing_index_group_stats`, `sys.dm_db_missing_index_groups`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`, `sys.tables`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Flüchtig/kumulativ seit Restart/Reset und begrenzt in der Zahl gespeicherter Gruppen. Vorschläge können nach Plan Cache-/Metadatenänderungen verschwinden.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Queryhäufigkeit, Kosten, tatsächliche Reads, vorhandene Präfixe/Includes, Selectivity, DML-Kosten, Speicher und Locking prüfen. Mehrere Vorschläge häufig zu einem tragfähigen Indexdesign konsolidieren.

**Typische Fehlinterpretation:** Ein hoher Improvement-Wert ist keine gemessene Einsparung. Der Vorschlag kennt Write Amplification, andere Queries, Filtered Indexes und vollständige Datenverteilung nur begrenzt.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Betroffene Pläne/Query Store, `USP_ObjectInventory`, `USP_IndexUsage`; DDL nur nach Test und Rollbackplan.

### `[monitor].[USP_Statistics]`

**Leitfrage:** Wie aktuell und repräsentativ sind die Statistiken, die der Cardinality Estimator für Schätzungen verwendet?

**Technischer Hintergrund:** Statistiken enthalten Header, Dichteinformationen und ein Histogramm für die führende Statistikspalte mit maximal 200 Steps. Auto-/User-Created, Filter, Persisted Sample und `dm_db_stats_properties` liefern Aktualisierungs-, Row-, Sample- und Modification-Kontext.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.columns`, `sys.dm_db_incremental_stats_properties`, `sys.dm_db_stats_properties`, `sys.indexes`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`, `sys.stats`, `sys.stats_columns`, `sys.tables`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller gespeicherter Statistikstand seit letztem Update. Modification Counter beschreibt Änderungen seitdem, nicht deren genaue Verteilungswirkung.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Rows, Rows Sampled, Samplingrate, Last Updated, Modifications, führende Spalte, Filter und betroffene Queryprädikate zusammen lesen. Eine alte unveränderte Statistik kann korrekt sein; eine junge stark gesampelte Statistik bei Skew kann problematisch sein.

**Typische Fehlinterpretation:** Alter oder Modification Counter allein beweist keinen Schätzfehler. Auto-Update-Schwellen und asynchrones Update sind kontextabhängig.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_StatisticsDistributionAnalysis`, Showplan Estimated/Actual Rows und Query Store Regression.

### `[monitor].[USP_StatisticsDistributionAnalysis]`

**Leitfrage:** Welche Datenverteilung bildet das Histogramm ab, und wo können Skew, dominante Werte oder grobe Rangeannahmen Schätzungen erschweren?

**Technischer Hintergrund:** Histogrammsteps speichern `RANGE_HI_KEY`, `EQ_ROWS`, `RANGE_ROWS`, `DISTINCT_RANGE_ROWS` und `AVG_RANGE_ROWS`. Gleichheitsprädikate auf Stepgrenzen und Werte innerhalb einer Range werden unterschiedlich geschätzt. Skew- und Konzentrationskennzahlen des Frameworks sind abgeleitete Prüfwerte.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.columns`, `sys.databases`, `sys.dm_db_stats_histogram`, `sys.sp_executesql`, `sys.stats_columns`, `sys.types`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktuelles Histogramm der letzten Statistikaktualisierung; maximal 200 Steps und gegebenenfalls Sample statt Vollscan.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Dominante EQ-Werte, große Ranges, geringe Distinctanzahl, Samplequote, Modification Counter und konkrete Parameterwerte verbinden. Verteilung ist besonders relevant bei Parameter Sensitivity und stark unterschiedlichen Selectivities.

**Typische Fehlinterpretation:** Ein Skew-Score ist kein Produktfehler und kein universeller Threshold. Gute Pläne können trotz Skew entstehen; schlechte Schätzungen können ohne sichtbaren starken Skew vorkommen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Showplan, Query Store PlanChanges/Regressions, gezieltes Statistikupdate nur nach Test.

### `[monitor].[USP_Partitions]`

**Leitfrage:** Wie verteilen Partition Function und Scheme Daten über Partitionen und Storage, und sind Grenzen/Lebenszyklus plausibel?

**Technischer Hintergrund:** Partition Functions übersetzen Boundary Values in Partitionsnummern; RANGE LEFT/RIGHT bestimmt Grenzwertzuordnung. Schemes ordnen Partitionen Filegroups zu. Indizes müssen für Alignment dieselbe Partitionierungslogik passend verwenden.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.allocation_units`, `sys.data_spaces`, `sys.destination_data_spaces`, `sys.dm_db_partition_stats`, `sys.indexes`, `sys.objects`, `sys.partition_functions`, `sys.partition_range_values`, `sys.partition_schemes`, `sys.partitions`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Katalog- und Rowcount-/Spacezustand.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Boundary-Reihenfolge, leere Randpartitionen, Größenverteilung, Kompression, Filegroups, aligned/non-aligned Indizes und Sliding-Window-Prozess prüfen. Skew kann fachlich erwartbar sein.

**Typische Fehlinterpretation:** Viele oder ungleiche Partitionen sind nicht automatisch schlecht. Partitionierung garantiert weder schnellere Queries noch Partition Elimination; Prädikat und Plan entscheiden.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Showplan Partition Elimination, Wartungs-/Switchprozess und Capacityanalyse.

### `[monitor].[USP_Columnstore]`

**Leitfrage:** Welchen Lebenszyklus und Qualitätszustand besitzen Columnstore-Rowgroups?

**Technischer Hintergrund:** Rows gelangen zunächst in Delta Stores oder direkt in komprimierte Rowgroups. Tuple Mover komprimiert geschlossene Delta Stores. Deletes markieren Rows logisch; Reorganization/Rebuild kann bereinigen. Trim Reasons und State erklären, warum Rowgroups kleiner als das Ziel sein können.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.column_store_dictionaries`, `sys.column_store_row_groups`, `sys.column_store_segments`, `sys.columns`, `sys.dm_db_column_store_row_group_physical_stats`, `sys.indexes`, `sys.objects`, `sys.partitions`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Rowgroupzustand; verändert sich durch Loads, Deletes, Tuple Mover und Wartung.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Total/Deleted Rows, Deleted-Prozent, State, Alter, Größe, Trim Reason, offene/geschlossene Delta Stores und Workloadmuster kombinieren. Viele kleine Rowgroups verschlechtern Segmentelimination/Kompression eher als ein isolierter Prozentwert.

**Typische Fehlinterpretation:** 20 Prozent Deleted Rows in einer kleinen kalten Rowgroup ist nicht automatisch relevant. Direkte DML- und Bulkloadmuster sowie Partitionstrategie entscheiden.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Querypläne/Segmentelimination, Ladebatchgröße, Tuple-Mover-/Wartungskontext.

### `[monitor].[USP_IndexPhysicalStats]`

**Leitfrage:** Wie sehen Page Count, Fragmentierung, Seitendichte und Strukturebenen eines Rowstore-Indexes beim Aufruf aus?

**Technischer Hintergrund:** `sys.dm_db_index_physical_stats` traversiert je Modus Allocation/Pages unterschiedlich tief. LIMITED liest weniger, SAMPLED schätzt bei größeren Strukturen, DETAILED untersucht alle Ebenen/Pages und ist teurer. Fragmentierung beschreibt logische Seitenreihenfolge; Page Space Used die Dichte.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_db_index_physical_stats`, `sys.indexes`, `sys.objects`, `sys.schemas`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aufrufbezogene Messung. Währenddessen können DML und Wartung den Zustand verändern; Modus bestimmt Genauigkeit/Kosten.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Page Count zuerst, dann Dichte, Fragmentierung, Scanlast, Storageart und Wartungsfolgen bewerten. Niedrige Dichte kann mehr I/O/Memory verursachen; Fragmentierung ist bei kleinen Indizes oft bedeutungslos.

**Typische Fehlinterpretation:** Pauschale 5/30-Prozent-Regeln sind keine universelle Produktgrenze. Rebuild erzeugt Log, Locks, TempDB-/I/O-Last und kann Statistiken beeinflussen.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_IndexUsage`, Operational Stats, Querypläne und geplantes Wartungsfenster.

### `[monitor].[USP_ObjectAnalysis]`

**Leitfrage:** Welche objektbezogenen Evidenzpfade sollen für einen Scope gemeinsam ausgeführt werden?

**Technischer Hintergrund:** Der Orchestrator kombiniert Definition, Usage, Operations, Missing Indexes, Statistics, Partitions, Columnstore und optional Physical Stats. Jedes Child behält eigene Quelle, Kosten und Resetsemantik.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung; Quellen liegen in den aufgerufenen Childmodulen.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nicht atomarer Mix aus Metadaten, kumulativen Zählern und aufrufbezogenen physischen Scans.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Zuerst Childstatus und Kostenoptionen, danach Befunde nach Objekt/Index korrelieren. Widersprüche sind möglich, etwa Missing-Index-Evidenz neben einem ähnlichen ungenutzten Index.

**Typische Fehlinterpretation:** Die Zusammenfassung ist keine DDL-Liste. Ein Childfehler darf nicht als unauffälliges Objekt gelten.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Je Befund das spezialisierte Child mit engem Scope erneut ausführen.

### `[monitor].[USP_SchemaDesignAnalysis]`

**Leitfrage:** Welche Schemamuster verdienen ein fachliches Designreview?

**Technischer Hintergrund:** Die Procedure leitet normalisierte Findings aus Katalogmerkmalen ab, etwa Datentyp-, Schlüssel-, Index-, Nullable-, LOB- oder Constraintkonstellationen. Solche Regeln erkennen technische Gerüche, nicht die vollständige fachliche Semantik.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.check_constraints`, `sys.foreign_key_columns`, `sys.foreign_keys`, `sys.identity_columns`, `sys.index_columns`, `sys.indexes`, `sys.objects`, `sys.schemas`, `sys.sequences`, `sys.sp_executesql`, `sys.tables`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Metadatenstand; keine Runtime-/Workloadhistorie, sofern nicht explizit angereichert.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Severity/Confidence, Objektgröße, Workload, Datenqualität, Abhängigkeiten und Migrationsaufwand zusammen betrachten. Ein Finding mit hoher technischer Plausibilität kann fachlich bewusst sein.

**Typische Fehlinterpretation:** Heuristik ist kein Beweis. Breite Spalten, fehlender PK oder bestimmter Datentyp können durch externe Verträge oder Stagingzweck begründet sein.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Object Inventory, Querypläne, Datenprofiling und fachliches Schemaowner-Review.

## 3. Plan Cache

### Cache- und Planmodell

Ein Cacheeintrag entsteht durch Kompilierung und kann mehrere Statements/Pläne repräsentieren. Runtimewerte in `sys.dm_exec_query_stats` gelten seit Erstellung des jeweiligen Eintrags. `query_hash` gruppiert strukturell ähnliche Statements; `query_plan_hash` ähnliche physische Planformen. Beide sind Korrelationshilfen, keine dauerhaft global eindeutigen Business-IDs.

### `[monitor].[USP_QueryStats]`

**Leitfrage:** Welche aktuell gecachten Statements verursachten kumulativ oder durchschnittlich CPU, Dauer, Reads und Writes?

**Technischer Hintergrund:** `sys.dm_exec_query_stats` liefert pro gecachtem Statement Ausführungszahl und Total-/Last-/Min-/Maxwerte. SQL Text und Statementoffsets identifizieren den Ausschnitt; Planhandle/Plan XML beschreiben die gecachte Planform.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_exec_cached_plans`, `sys.dm_exec_plan_attributes`, `sys.dm_exec_query_stats`, `sys.dm_exec_sql_text`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Kumulativ seit Cacheeintrag. Erstellung/letzte Ausführung und Engine-Start begrenzen das Fenster.

**Bewertung und Gegenprobe:** Totalwerte zeigen die Gesamtkosten, während Durchschnittswerte teure Einzelausführungen sichtbar machen. Berücksichtigen Sie immer auch Execution Count, Cachealter, Rowcount und Last Execution.

**Typische Fehlinterpretation:** Ein kleiner Totalwert kann nur kurzen Cachelebenszyklus bedeuten. Durchschnitt verdeckt Ausreißer und Parameter Sensitivity.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Query Hash, Showplan und Query Store für persistierte Historie.

### `[monitor].[USP_QueryHashAnalysis]`

**Leitfrage:** Welche Varianten derselben normalisierten Queryform und welche Planformen liegen aktuell im Cache?

**Technischer Hintergrund:** Grouping nach Query Hash konsolidiert ähnliche Statementtexte; Plan Hash trennt physische Planformen. Aggregationen zeigen Planvielfalt, Lastverteilung und mögliche Ad-hoc-/Parameterisierungsvarianten.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_exec_query_stats`, `sys.dm_exec_sql_text`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nur aktuell gecachte Einträge; verschiedene Creation Times und Evictions.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Plananzahl, Execution Count, Total/Avg-Kosten, Text-/Parameterkontext und Creation Time vergleichen. Mehrere Plan Hashes können legitime Recompile-/SET-/Compatibilitykontexte oder Parameter Sensitivity zeigen.

**Typische Fehlinterpretation:** Gleicher Hash garantiert keine fachliche Gleichheit; Hashkollisionen sind theoretisch möglich. Ein fehlender alter Plan ist keine Stabilitätsevidenz.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Query Store PlanChanges/RuntimeStats und Showplanvergleich.

### `[monitor].[USP_PlanCacheHealth]`

**Leitfrage:** Wie viel Memory bindet der Plan Cache und welche Planarten/Use-Count-Muster dominieren?

**Technischer Hintergrund:** Cache Stores und Cached Plans zeigen Planarten, Objekt-/Ad-hoc-Pläne, Größen und Use Counts. Viele Single-Use-Ad-hoc-Pläne können Kompilierungs-/Memorydruck erzeugen; Clock Hands und Memory Pressure steuern Eviction.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.configurations`, `sys.dm_exec_cached_plans`, `sys.dm_exec_plan_attributes`, `sys.dm_exec_sql_text`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Aktueller Cachebestand; flüchtig und durch Workload/Memorydruck verändert.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Cachegröße relativ zu Servermemory, Single-Use-Anteil in Bytes und Count, Ad-hoc-Workload, Compile/sec und Parameterisierungsstrategie bewerten.

**Typische Fehlinterpretation:** Viele Single-Use-Pläne sind nicht automatisch Hauptproblem. `optimize for ad hoc workloads` reduziert zunächst Stubgröße, behebt aber keine Querygenerierung oder Compileursache.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_ServerMemory`, Performance Counters, Query Hash und Anwendung/Parameterisierung.

### `[monitor].[USP_PlanDetails]`

**Leitfrage:** Welche Attribute, Texte, Statements und Planinformationen gehören zu einem konkreten Handle?

**Technischer Hintergrund:** SQL-/Planhandles referenzieren flüchtige Cacheobjekte. Plan Attributes enthalten DBID, Set Options, User-/Languagekontext und weitere Cachekeyeinflüsse. Unterschiedliche SET Options können separate Pläne derselben Textform erzeugen.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `sys.dm_exec_plan_attributes`, `sys.dm_exec_query_plan`, `sys.dm_exec_query_plan_stats`, `sys.dm_exec_query_statistics_xml`, `sys.dm_exec_query_stats`, `sys.dm_exec_requests`, `sys.dm_exec_sql_text`, `sys.dm_exec_text_query_plan`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Momentaufnahme eines Cacheeintrags. Handle kann zwischen Auswahl und Detailabruf evicted werden.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Plan Attributes, Statementoffset, Creation/Last Execution, Use Count und XML gemeinsam lesen. Set-Option-Unterschiede können scheinbare Planverdoppelung erklären.

**Typische Fehlinterpretation:** Ein Handle ist keine persistente Referenz und darf nicht langfristig gespeichert werden, ohne Gültigkeitsprüfung.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: `USP_ShowplanAnalysis`; Query Store IDs für dauerhaftere Korrelation.

### `[monitor].[USP_ShowplanAnalysis]`

**Leitfrage:** Welche Operatoren, Schätzungen, Warnungen, Objekte, Statistiken und Optimizerhinweise enthält ein Showplan?

**Technischer Hintergrund:** Showplan XML modelliert RelOp-Baum, Estimated Rows/Cost, Predicate, Object/Index, Statistics, Memory Grant, Parallelism und Warnings. Cached/Query-Store-Pläne sind typischerweise Estimated-/Compilepläne; Actual Rows existieren nur in tatsächlichen Ausführungsplänen beziehungsweise entsprechenden Runtimefeatures.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: `master.sys.databases`, `sys.dm_exec_plan_attributes`, `sys.dm_exec_query_plan`, `sys.dm_exec_query_plan_stats`, `sys.dm_exec_query_stats`, `sys.dm_exec_sql_text`, `sys.sp_executesql`.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Planstand zum Compile-/Capturezeitpunkt; zugrunde liegende Daten/Statistiken können inzwischen geändert sein.

**Bewertung und Gegenprobe:** Berücksichtigen Sie den Operatorfluss von unten nach oben, Estimated und Actual, sofern vorhanden, Join- und Accessmethode, Predicate, Spills, Conversions, Missing Index sowie Memory und Parallelism gemeinsam. Priorisieren Sie eine Warnung zusammen mit ihrer Runtimewirkung.

**Typische Fehlinterpretation:** Estimated Cost ist keine gemessene Zeit und zwischen unabhängigen Servern/CE-Kontexten nicht absolut vergleichbar. Missing-Index-XML ist keine fertige DDL.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Statistics Distribution, Query Store Runtime/Regression und reale Laufzeitmessung.

### `[monitor].[USP_PlanCacheAnalysis]`

**Leitfrage:** Welche Plan-Cache-Perspektiven sollen gemeinsam für Triage oder Deep Analysis ausgeführt werden?

**Technischer Hintergrund:** Der Wrapper orchestriert Query Stats, Hashgruppen, Cache Health, Details und Showplanpfade. Plan-XML und breite Cache-Scans erhöhen CPU, Memorytransfer und Resultsetgröße.

**Datenquellen:** Die Analyse verwendet folgende Datenquellen und Ausführungspfade: Frameworkinterne Orchestrierung; Quellen liegen in den aufgerufenen Childmodulen.

**Zeit- und Scopemodell:** Die zeitliche und fachliche Aussage ist wie folgt begrenzt: Nicht atomarer Snapshot des flüchtigen Cache; Children können unterschiedliche Kandidatenmengen sehen.

**Bewertung und Gegenprobe:** Für die Bewertung und Gegenprobe gelten folgende Prüfschritte: Status/Partial zuerst, dann von Gesamtkosten zu Hash/Plan und erst danach XML-Deep-Dive. Scope und MaxRows eng halten.

**Typische Fehlinterpretation:** Ein leerer Detailpfad kann durch Eviction zwischen Childaufrufen entstehen, nicht durch fehlende frühere Ausführung.

**Weiterführende Analyse:** Für die weiterführende Analyse gelten folgende Schritte und Quellen: Historische Fragen mit Query Store; aktuelle Ressourcenauswirkung mit Current State.

## 4. Offizielle Primärquellen

- [SQL Server index architecture and design guide](https://learn.microsoft.com/sql/relational-databases/sql-server-index-design-guide)
- [sys.dm_db_index_usage_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-index-usage-stats-transact-sql)
- [sys.dm_db_index_operational_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-operational-stats-transact-sql?view=sql-server-ver17)
- [Tune nonclustered indexes with missing index suggestions](https://learn.microsoft.com/sql/relational-databases/indexes/tune-nonclustered-missing-index-suggestions)
- [Statistics](https://learn.microsoft.com/sql/relational-databases/statistics/statistics)
- [sys.dm_db_stats_histogram](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-stats-histogram-transact-sql)
- [Partitioned tables and indexes](https://learn.microsoft.com/sql/relational-databases/partitions/partitioned-tables-and-indexes)
- [Columnstore indexes overview](https://learn.microsoft.com/sql/relational-databases/indexes/columnstore-indexes-overview)
- [sys.dm_db_index_physical_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-physical-stats-transact-sql?view=sql-server-ver17)
- [sys.dm_exec_query_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-stats-transact-sql)
- [Showplan logical and physical operators reference](https://learn.microsoft.com/sql/relational-databases/showplan-logical-and-physical-operators-reference)
