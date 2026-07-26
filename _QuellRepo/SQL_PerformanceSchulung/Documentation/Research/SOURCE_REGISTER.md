# Projektweites Quellenregister

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W0-006` |
| Status | `VALIDATED` |
| Registerversion | 1.0 |
| Stand | 2026-07-24 |
| Primärer Geltungsbereich | SQL Server 2019, 2022 und 2025 |
| Kanonische Quellenklasse | öffentlich erreichbare Primärdokumentation des Produktherstellers |

## 1. Zweck

Dieses Register ist die kanonische Quellenbasis für technische Aussagen, Folien, Sprecherhinweise, Teilnehmerunterlagen, Demo-Designs und Tests. Es ergänzt das folienbezogene Aussagenregister um Pflegeinformationen und einen eindeutigen Gültigkeitsbereich.

Eine Quelle belegt nur die in ihrem Aussagebezug benannten Produkteigenschaften. Aus einer allgemeinen Featureübersicht darf keine unbelegte Detailaussage über jede Unterfunktion, Edition oder Compatibility Level abgeleitet werden.

## 2. Verbindliches Metadatenmodell

Jeder Eintrag besitzt mindestens folgende Felder:

| Feld | Bedeutung |
|---|---|
| `ID` | stabile projektweite Kennung; IDs werden nicht wiederverwendet |
| `Klasse` | `PRIMARY`, `SUPPORTING`, `EMPIRICAL_METHOD` oder `RETIRED` |
| `Quelle` | Titel und direkt aufrufbarer Verweis |
| `Aussagebezug` | Produkteigenschaft, Claim-Gruppe oder Demo, für die die Quelle verwendet werden darf |
| `Gültigkeitsbereich` | Engine-Version, Compatibility Level, Konfiguration, Edition oder Plattformgrenze |
| `Aktualisiert` | Datum der letzten Änderung der Registerinterpretation oder Zuordnung |
| `Abgerufen` | Datum der letzten erfolgreichen fachlichen Prüfung der referenzierten Quelle |
| `Status` | `ACTIVE`, `REVIEW_REQUIRED` oder `RETIRED` |
| `Review-Trigger` | Ereignis, das eine erneute Prüfung erzwingt |

`Aktualisiert` bezeichnet nicht ungeprüft das Veröffentlichungsdatum einer Webseite. Viele Dokumentationsseiten besitzen revisionsabhängige oder nicht stabil ausgewiesene Änderungsdaten. Maßgeblich ist deshalb das Datum, an dem der Registereintrag und seine projektseitige Interpretation zuletzt fachlich geändert wurden. Ein von der Quelle verlässlich ausgewiesener Revisionsstand kann ergänzend in Notes dokumentiert werden.

## 3. Evidenzklassen

| Kennzeichnung | Verwendung |
|---|---|
| `DOCUMENTED` | Aussage wird unmittelbar durch mindestens eine aktive Primärquelle getragen. |
| `EMPIRICAL` | konkrete Wirkung, Bandbreite oder Schwelle muss im jeweiligen Workload gemessen werden; die Quelle belegt nur Mechanismus und Messgrößen. |
| `METHOD` | Diagnose-, Mess- oder Unterrichtsablauf; keine Produktgarantie. |
| `DIDACTIC` | Navigation, Lernziel, Transfer oder Zusammenfassung ohne eigenständige technische Produkteigenschaft. |
| `INFERENCE` | logisch hergeleitete Aussage aus mehreren Quellen; Herleitung und Grenzen müssen ausdrücklich genannt werden. |

## 4. Aktive Primärquellen

Alle nachfolgenden Einträge wurden am 24. Juli 2026 abgerufen und fachlich geprüft. Der URL-Parameter `view=sql-server-ver17` bezeichnet die Dokumentationssicht für SQL Server 2025; abweichende Versions- und Compatibility-Level-Grenzen sind im Feld `Gültigkeitsbereich` benannt.

| ID | Klasse | Quelle | Aussagebezug | Gültigkeitsbereich | Aktualisiert | Abgerufen | Status | Review-Trigger |
|---|---|---|---|---|---|---|---|---|
| `SRC-001` | PRIMARY | [Query processing architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/query-processing-architecture-guide?view=sql-server-ver17) | Verarbeitungskette, Optimierer, Plan Cache, Parallelität, Workers und Tasks; Claims zu M02 und M06 | SQL Server 2019–2025; Detailverhalten versionsabhängig | 2026-07-24 | 2026-07-24 | ACTIVE | neue Engine-Version oder geänderte Cache-/Parallelitätsdokumentation |
| `SRC-002` | PRIMARY | [Pages and extents architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/pages-and-extents-architecture-guide?view=sql-server-ver17) | Pages, Extents, Row Layout und grundlegende Speicherorganisation; M01 | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Änderung der Storage-Engine-Dokumentation |
| `SRC-003` | PRIMARY | [Database files and filegroups](https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-files-and-filegroups?view=sql-server-ver17) | Data Files, Log Files, Filegroups, proportional fill und Autogrowth; `STL-005` | SQL Server 2019–2025; physische Wirkung umgebungsabhängig | 2026-07-24 | 2026-07-24 | ACTIVE | Änderung der Filegrowth- oder Filegroup-Semantik |
| `SRC-004` | PRIMARY | [Transaction locking and row versioning guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide?view=sql-server-ver17) | Locking, Isolation, RCSI, SNAPSHOT, Konflikte und Row Versioning; M05 | SQL Server 2019–2025; Datenbankoptionen beachten | 2026-07-24 | 2026-07-24 | ACTIVE | neue Locking-/Versioning-Funktion oder geänderte Konfliktsemantik |
| `SRC-005` | PRIMARY | [Statistics](https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics?view=sql-server-ver17) | Histogramm, Density, Sampling, Statistikaktualität und Schätzungsgrundlagen; `OPT-002` bis `OPT-005` | SQL Server 2019–2025; CL und Konfiguration beachten | 2026-07-24 | 2026-07-24 | ACTIVE | neue Statistikfunktion oder geänderte Auto-Update-Regel |
| `SRC-006` | PRIMARY | [Cardinality estimation](https://learn.microsoft.com/en-us/sql/relational-databases/performance/cardinality-estimation-sql-server?view=sql-server-ver17) | CE-Modelle und Modellgrenzen; `OPT-006` | SQL Server 2019–2025; Compatibility Level entscheidend | 2026-07-24 | 2026-07-24 | ACTIVE | neues CE-Modell oder neue CL-Zuordnung |
| `SRC-007` | PRIMARY | [Intelligent query processing](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing?view=sql-server-ver17) | IQP-Funktionsmatrix, Deferred Compilation, Interleaved Execution, PSP, Batch Mode und Feedbackfunktionen | SQL Server 2019–2025; jeweilige CL- und Konfigurationsgrenzen | 2026-07-24 | 2026-07-24 | ACTIVE | neue IQP-Funktion oder geänderte Voraussetzung |
| `SRC-008` | PRIMARY | [Intelligent query processing features in detail](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing-details?view=sql-server-ver17) | Detailgrenzen einzelner IQP-Funktionen; Claims 34, 42 und 43 | versions- und CL-abhängig | 2026-07-24 | 2026-07-24 | ACTIVE | Detailänderung einer referenzierten IQP-Funktion |
| `SRC-009` | PRIMARY | [Memory grant feedback](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing-memory-grant-feedback?view=sql-server-ver17) | Overgrant, Undergrant, Feedbackvarianten, Perzentilmodus und Persistenz; `OPT-014` | SQL Server 2019–2025; Persistenz SQL Server 2022+, CL 140+, Query Store `READ_WRITE` | 2026-07-24 | 2026-07-24 | ACTIVE | Änderung der MGF-Voraussetzungen oder Persistenz |
| `SRC-010` | PRIMARY | [sys.dm_exec_query_memory_grants](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-memory-grants-transact-sql?view=sql-server-ver17) | Requested, Granted und Used Memory sowie wartende Grants; `OPT-014`, `RES-003` | SQL Server 2019–2025; Rechte versionsabhängig | 2026-07-24 | 2026-07-24 | ACTIVE | DMV-Spalten- oder Berechtigungsänderung |
| `SRC-011` | PRIMARY | [WITH common_table_expression](https://learn.microsoft.com/en-us/sql/t-sql/queries/with-common-table-expression-transact-sql?view=sql-server-ver17) | CTE-Semantik und fehlende Materialisierungsgarantie; `QRY-008` | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Änderung der CTE-Semantik oder Dokumentation |
| `SRC-012` | PRIMARY | [SQL Server index design guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-index-design-guide?view=sql-server-ver17) | Indexstruktur, Key-Reihenfolge, INCLUDE, Filter und Row Locator; M04 | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | neue Indexfunktion oder geänderte Designgrenze |
| `SRC-013` | PRIMARY | [Heaps](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/heaps-tables-without-clustered-indexes?view=sql-server-ver17) | RID Lookup, Forwarded Records und geeignete Heap-Szenarien; `STL-003`, `IDX-001` | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Änderung der Heap- oder Forwarded-Record-Dokumentation |
| `SRC-014` | PRIMARY | [Specify fill factor for an index](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/specify-fill-factor-for-an-index?view=sql-server-ver17) | Fill Factor, Page Splits und Ressourcentrade-offs; `IDX-006` | SQL Server 2019–2025; Wirkung empirisch | 2026-07-24 | 2026-07-24 | ACTIVE | geänderte Empfehlung oder Produktsemantik |
| `SRC-015` | PRIMARY | [Optimize index maintenance](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes?view=sql-server-ver17) | Fragmentation, Page Density, Reorganize/Rebuild und Columnstore-Maintenance | SQL Server 2019–2025; Maßnahmenschwellen workloadabhängig | 2026-07-24 | 2026-07-24 | ACTIVE | neue Maintenance-Funktion oder geänderte Messgrößen |
| `SRC-016` | PRIMARY | [Columnstore indexes overview](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/columnstore-indexes-overview?view=sql-server-ver17) | Rowgroups, Delta Store, Delete Bitmap und Background Merge; `IDX-009`, `IDX-010` | SQL Server 2019–2025; Edition und Featureumfang prüfen | 2026-07-24 | 2026-07-24 | ACTIVE | neue Columnstore-Funktion oder Editionsänderung |
| `SRC-017` | PRIMARY | [Columnstore query performance](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/columnstore-indexes-query-performance?view=sql-server-ver17) | Batch Mode, Segment Elimination und Rowgroup-Qualität; `IDX-010` | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | geänderte Batch-/Segment-Verhaltensbeschreibung |
| `SRC-018` | PRIMARY | [Partitioned tables and indexes](https://learn.microsoft.com/en-us/sql/relational-databases/partitions/partitioned-tables-and-indexes?view=sql-server-ver17) | Partitionierung, Alignment und Partition Elimination; `QRY-012` | SQL Server 2019–2025; Edition/Limit prüfen | 2026-07-24 | 2026-07-24 | ACTIVE | Funktions- oder Editionsänderung |
| `SRC-019` | PRIMARY | [sys.partitions](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-partitions-transact-sql?view=sql-server-ver17) | Partition-Metadaten und `index_id`-Semantik; `STL-004` | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Katalogspalten- oder Semantikänderung |
| `SRC-020` | PRIMARY | [Create linked servers](https://learn.microsoft.com/en-us/sql/relational-databases/linked-servers/create-linked-servers-sql-server-database-engine?view=sql-server-ver17) | Provider-, Collation- und Pushdown-Grenzen; `QRY-012` | provider- und versionsabhängig | 2026-07-24 | 2026-07-24 | ACTIVE | Provider- oder Sicherheitsänderung |
| `SRC-021` | PRIMARY | [sp_addlinkedserver](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-addlinkedserver-transact-sql?view=sql-server-ver17) | Providerparameter und SQL-Server-2025-Verschlüsselungsanforderung | SQL Server 2019–2025; OLE DB Driver beachten | 2026-07-24 | 2026-07-24 | ACTIVE | Treiber-, Provider- oder Verschlüsselungsänderung |
| `SRC-022` | PRIMARY | [Breaking changes in SQL Server 2025](https://learn.microsoft.com/en-us/sql/database-engine/breaking-changes-to-database-engine-features-in-sql-server-2025?view=sql-server-ver17) | migrationskritische Grenzen von SQL Server 2025 | SQL Server 2025 | 2026-07-24 | 2026-07-24 | ACTIVE | neue Breaking-Change-Dokumentation oder CU-bedingte Korrektur |
| `SRC-023` | PRIMARY | [HASHBYTES](https://learn.microsoft.com/en-us/sql/t-sql/functions/hashbytes-transact-sql?view=sql-server-ver17) | Hashalgorithmen und endliche Hashausgabe; Hash-Eindeutigkeitsinferenz | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Algorithmus- oder Deprecation-Änderung |
| `SRC-024` | PRIMARY | [Create unique indexes](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/create-unique-indexes?view=sql-server-ver17) | Eindeutigkeitsgarantie des Indexschlüssels; Hash-Eindeutigkeitsinferenz | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Änderung der Unique-Index-Semantik |
| `SRC-025` | PRIMARY | [Optimized locking](https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-locking?view=sql-server-ver17) | TID Locking, LAQ, ADR-/RCSI-Voraussetzungen und Grenzen; `CON-008` | SQL Server 2025; Datenbankkonfiguration | 2026-07-24 | 2026-07-24 | ACTIVE | Featureänderung, neue Plattform oder geänderte Voraussetzung |
| `SRC-026` | PRIMARY | [Optional parameter plan optimization](https://learn.microsoft.com/en-us/sql/relational-databases/performance/optional-parameter-optimization?view=sql-server-ver17) | OPPO, Dispatcher- und Variant Plans; `QRY-004`, `OPT-010` | SQL Server 2025, CL 170, Datenbankkonfiguration | 2026-07-24 | 2026-07-24 | ACTIVE | Eligibility- oder Defaultänderung |
| `SRC-027` | PRIMARY | [Monitor performance by using the Query Store](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17) | Query-/Plan-/Runtime-Historie, Waits, Regressionen und Plansteuerung; `DGN-003` | SQL Server 2019–2025; Konfiguration und Read/Write-Status | 2026-07-24 | 2026-07-24 | ACTIVE | Default-, Schema- oder Retention-Änderung |
| `SRC-028` | PRIMARY | [Performance monitoring and tuning tools](https://learn.microsoft.com/en-us/sql/relational-databases/performance/performance-monitoring-and-tuning-tools?view=sql-server-ver17) | Abgrenzung von DMVs, Extended Events und weiteren Beobachtungsquellen; Diagnosemethode | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Werkzeug- oder Scopeänderung |
| `SRC-029` | PRIMARY | [tempdb database](https://learn.microsoft.com/en-us/sql/relational-databases/databases/tempdb-database?view=sql-server-ver17) | temporäre Objekte, Worktables, Spills, Version Store und TempDB-Funktionen; `CON-009` | SQL Server 2019–2025; versionsabhängige Funktionen | 2026-07-24 | 2026-07-24 | ACTIVE | neue TempDB-Funktion oder Setupempfehlung |
| `SRC-030` | PRIMARY | [Data type precedence](https://learn.microsoft.com/en-us/sql/t-sql/data-types/data-type-precedence-transact-sql?view=sql-server-ver17) | Implicit Conversion und Type Precedence; `QRY-002` | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Datentyp- oder Präzedenzänderung |
| `SRC-031` | PRIMARY | [Display an actual execution plan](https://learn.microsoft.com/en-us/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17) | Runtime-Information im Actual Execution Plan; `OPT-001`, `FWK-005` | SQL Server 2019–2025; Clientdarstellung beachten | 2026-07-24 | 2026-07-24 | ACTIVE | Planattribut- oder Tooländerung |
| `SRC-032` | PRIMARY | [Tune nonclustered indexes with missing index suggestions](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/tune-nonclustered-missing-index-suggestions?view=sql-server-ver17) | Grenzen optimizerbasierter Indexvorschläge; `IDX-005` | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | neue Limitierung oder geänderte DMV-Dokumentation |
| `SRC-033` | PRIMARY | [The transaction log](https://learn.microsoft.com/en-us/sql/relational-databases/logs/the-transaction-log-sql-server?view=sql-server-ver17) | Write-ahead logging, Log Flush, Recovery und VLF-Kontext; `STL-007` bis `STL-009` | SQL Server 2019–2025 | 2026-07-24 | 2026-07-24 | ACTIVE | Logarchitektur- oder Recoveryänderung |
| `SRC-034` | PRIMARY | [Database instant file initialization](https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-instant-file-initialization?view=sql-server-ver17) | unterschiedliche Behandlung von Data- und Log-File-Growth; `STL-005` | SQL Server 2019–2025; Plattform und Berechtigung beachten | 2026-07-24 | 2026-07-24 | ACTIVE | Plattform-, Berechtigungs- oder Log-IFI-Änderung |
| `SRC-035` | PRIMARY | [sys.dm_os_wait_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-wait-stats-transact-sql?view=sql-server-ver17) | instanzweite kumulative Wait Stats und Delta-Bildung; `RES-007` | SQL Server 2019–2025; Rechte versionsabhängig | 2026-07-24 | 2026-07-24 | ACTIVE | DMV-Spalten-, Scope- oder Rechteänderung |
| `SRC-036` | PRIMARY | [sys.dm_os_waiting_tasks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-waiting-tasks-transact-sql?view=sql-server-ver17) | aktuelle wartende Tasks, Ressourcen und Blocking-Evidenz; `CON-004`, `RES-007` | SQL Server 2019–2025; Rechte versionsabhängig | 2026-07-24 | 2026-07-24 | ACTIVE | DMV-Spalten-, Scope- oder Rechteänderung |

## 5. Pflegeprozess

Eine Quelle wird erneut geprüft, wenn mindestens eines der folgenden Ereignisse eintritt:

- Aufnahme einer neuen SQL-Server-Hauptversion oder eines neuen Compatibility Levels,
- Änderung eines aktiven Claims, Lernziels oder Demo-Vertrags,
- Änderung der referenzierten Herstellerdokumentation,
- neue oder geänderte Feature-Voraussetzung,
- Runtime-Ergebnis, das der dokumentierten Erwartung widerspricht,
- nicht mehr erreichbarer, umgeleiteter oder als veraltet gekennzeichneter Verweis.

Bei einer inhaltlichen Änderung wird `Aktualisiert` gesetzt und der betroffene Aussagebezug geprüft. Ein nicht erreichbarer Link wird nicht stillschweigend ersetzt. Der Eintrag erhält zunächst `REVIEW_REQUIRED`; Ersatzquelle, geänderte Interpretation und betroffene Claims werden im Konflikt- und Entscheidungslog dokumentiert.

## 6. Abnahme von W0-006

Alle in Welle 0 verwendeten 36 Primärquellen besitzen eine stabile ID, einen Aussagebezug, einen Gültigkeitsbereich, ein Aktualisierungs- und Abrufdatum, einen Status und einen Review-Trigger. Die Traceability-Matrix referenziert ausschließlich IDs dieses Registers. Damit ist `W0-006` abgeschlossen.

Weitere Quellen werden fortlaufend in diesem Register ergänzt. Das frühere Dokument `PRIMARY_SOURCES_W0.md` bleibt als validierter Welle-0-Snapshot erhalten; bei widersprüchlichen Pflegeinformationen ist dieses projektweite Register maßgeblich.