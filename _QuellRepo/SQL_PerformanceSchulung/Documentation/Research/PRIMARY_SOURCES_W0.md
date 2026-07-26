# Primärquellenregister für W0-003 und W0-004

**Status:** VALIDATED  
**Prüfdatum:** 2026-07-24  
**Geltungsbereich:** SQL Server 2019 (15.x), 2022 (16.x), 2025 (17.x); Datenbank-Kompatibilitätsstufen 140 bis 170, soweit in der jeweiligen Quelle ausgewiesen  
**Quellengrundsatz:** ausschließlich offizielle, öffentlich erreichbare Produktdokumentation  
**Projektweite Pflege:** [Projektweites Quellenregister](SOURCE_REGISTER.md)

## Zweck und Abgrenzung

Dieses Dokument ist der validierte Welle-0-Snapshot für:

- das folienbezogene Aussagenregister aus `W0-003`;
- die vertiefte Prüfung kritischer Aussagen aus `W0-004`;
- die Trennung dokumentierter Produkteigenschaften von empirischen Empfehlungen.

Das projektweite Literatur- und Quellenkonzept aus `W0-006` ist inzwischen in `SOURCE_REGISTER.md` umgesetzt. Dort werden zusätzlich Aktualisierungsdatum, Abrufdatum, Aussagebezug, Gültigkeitsbereich, Status und Review-Trigger je Quelle gepflegt. Bei widersprüchlichen Pflegeinformationen ist das projektweite Register maßgeblich; die nachfolgende Liste bleibt als nachvollziehbarer Quellenstand der Welle 0 erhalten.

Abrufdatum aller nachfolgenden Quellen ist der 24. Juli 2026. Der Parameter `view=sql-server-ver17` bezeichnet die Dokumentationssicht für SQL Server 2025; abweichende Versions- und Kompatibilitätsgrenzen werden im Aussagenregister ausdrücklich erfasst.

## Quellen

| ID | Primärquelle | Fachlicher Einsatz |
|---|---|---|
| SRC-001 | [Query processing architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/query-processing-architecture-guide?view=sql-server-ver17) | Verarbeitungskette, Optimierer, Plan-Cache, Parallelität, Worker und Tasks |
| SRC-002 | [Pages and extents architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/pages-and-extents-architecture-guide?view=sql-server-ver17) | Seiten, Extents und grundlegende Speicherorganisation |
| SRC-003 | [Database files and filegroups](https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-files-and-filegroups?view=sql-server-ver17) | Daten-/Logdateien, Filegroups und proportional fill |
| SRC-004 | [Transaction locking and row versioning guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide?view=sql-server-ver17) | Sperren, Isolation, RCSI, SNAPSHOT, Konflikte und Zeilenversionen |
| SRC-005 | [Statistics](https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics?view=sql-server-ver17) | Histogramm, Dichte, Schätzungen und Statistikaktualität |
| SRC-006 | [Cardinality estimation](https://learn.microsoft.com/en-us/sql/relational-databases/performance/cardinality-estimation-sql-server?view=sql-server-ver17) | CE-Modelle, Modellgrenzen und Kompatibilitätsstufen |
| SRC-007 | [Intelligent query processing](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing?view=sql-server-ver17) | Funktions- und Versionsmatrix für IQP |
| SRC-008 | [Intelligent query processing features in detail](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing-details?view=sql-server-ver17) | Voraussetzungen und Grenzen einzelner IQP-Funktionen |
| SRC-009 | [Memory grant feedback](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing-memory-grant-feedback?view=sql-server-ver17) | Über-/Unterreservierung, Feedbackvarianten und Persistenz |
| SRC-010 | [sys.dm_exec_query_memory_grants](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-memory-grants-transact-sql?view=sql-server-ver17) | Angeforderter, gewährter und genutzter Abfragespeicher |
| SRC-011 | [WITH common_table_expression](https://learn.microsoft.com/en-us/sql/t-sql/queries/with-common-table-expression-transact-sql?view=sql-server-ver17) | CTE-Semantik und fehlende Materialisierungsgarantie |
| SRC-012 | [SQL Server index design guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-index-design-guide?view=sql-server-ver17) | Indexstruktur, Schlüsselreihenfolge, INCLUDE und Filter |
| SRC-013 | [Heaps](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/heaps-tables-without-clustered-indexes?view=sql-server-ver17) | RID-Lookups, Forwarded Records und Heap-Einsatz |
| SRC-014 | [Specify fill factor for an index](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/specify-fill-factor-for-an-index?view=sql-server-ver17) | Fill Factor, Page Splits und Ressourcentrade-offs |
| SRC-015 | [Optimize index maintenance](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes?view=sql-server-ver17) | Fragmentierung, Seitendichte, Reorganize/Rebuild und Messlogik |
| SRC-016 | [Columnstore indexes overview](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/columnstore-indexes-overview?view=sql-server-ver17) | Rowgroups, Delta Store, Delete Bitmap und Hintergrund-Merge |
| SRC-017 | [Columnstore query performance](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/columnstore-indexes-query-performance?view=sql-server-ver17) | Batch Mode, Segment Elimination und Rowgroup-Qualität |
| SRC-018 | [Partitioned tables and indexes](https://learn.microsoft.com/en-us/sql/relational-databases/partitions/partitioned-tables-and-indexes?view=sql-server-ver17) | Partitionierung, Ausrichtung und Elimination |
| SRC-019 | [sys.partitions](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-partitions-transact-sql?view=sql-server-ver17) | Partition-Metadaten und `index_id`-Semantik |
| SRC-020 | [Create linked servers](https://learn.microsoft.com/en-us/sql/relational-databases/linked-servers/create-linked-servers-sql-server-database-engine?view=sql-server-ver17) | Provider-, Collation- und Pushdown-Grenzen |
| SRC-021 | [sp_addlinkedserver](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-addlinkedserver-transact-sql?view=sql-server-ver17) | Providerparameter und SQL-Server-2025-Verschlüsselungsänderung |
| SRC-022 | [Breaking changes in SQL Server 2025](https://learn.microsoft.com/en-us/sql/database-engine/breaking-changes-to-database-engine-features-in-sql-server-2025?view=sql-server-ver17) | Versionskritische Migrationsgrenzen |
| SRC-023 | [HASHBYTES](https://learn.microsoft.com/en-us/sql/t-sql/functions/hashbytes-transact-sql?view=sql-server-ver17) | Hashalgorithmen und endliche Hashausgabe |
| SRC-024 | [Create unique indexes](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/create-unique-indexes?view=sql-server-ver17) | Garantierter Eindeutigkeitsumfang eines Indexschlüssels |
| SRC-025 | [Optimized locking](https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-locking?view=sql-server-ver17) | TID Locking, LAQ, ADR/RCSI-Voraussetzungen und Grenzen |
| SRC-026 | [Optional parameter plan optimization](https://learn.microsoft.com/en-us/sql/relational-databases/performance/optional-parameter-optimization?view=sql-server-ver17) | OPPO, Dispatcher/Varianten, SQL Server 2025 und Stufe 170 |
| SRC-027 | [Monitor performance by using the Query Store](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17) | Laufzeithistorie, Pläne, Waits, Regressionen und Plansteuerung |
| SRC-028 | [Performance monitoring and tuning tools](https://learn.microsoft.com/en-us/sql/relational-databases/performance/performance-monitoring-and-tuning-tools?view=sql-server-ver17) | Abgrenzung von DMVs, Extended Events und weiteren Beobachtungsquellen |
| SRC-029 | [tempdb database](https://learn.microsoft.com/en-us/sql/relational-databases/databases/tempdb-database?view=sql-server-ver17) | Temporäre Objekte, Worktables, Spills und Versionsspeicher |
| SRC-030 | [Data type precedence](https://learn.microsoft.com/en-us/sql/t-sql/data-types/data-type-precedence-transact-sql?view=sql-server-ver17) | Implizite Konvertierungen und Präzedenz |
| SRC-031 | [Display an actual execution plan](https://learn.microsoft.com/en-us/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17) | Laufzeitinformationen im tatsächlichen Ausführungsplan |
| SRC-032 | [Tune nonclustered indexes with missing index suggestions](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/tune-nonclustered-missing-index-suggestions?view=sql-server-ver17) | Grenzen optimizerbasierter Indexvorschläge |
| SRC-033 | [The transaction log](https://learn.microsoft.com/en-us/sql/relational-databases/logs/the-transaction-log-sql-server?view=sql-server-ver17) | Write-ahead logging, Log Flush und Wiederherstellung |
| SRC-034 | [Database instant file initialization](https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-instant-file-initialization?view=sql-server-ver17) | Unterschiedliche Behandlung von Daten- und Logwachstum |
| SRC-035 | [sys.dm_os_wait_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-wait-stats-transact-sql?view=sql-server-ver17) | Instanzweite kumulative Wait-Statistiken |
| SRC-036 | [sys.dm_os_waiting_tasks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-waiting-tasks-transact-sql?view=sql-server-ver17) | Aktuelle wartende Tasks und Ressourcen |

## Evidenzregeln

1. `DOCUMENTED` bezeichnet eine Aussage, die unmittelbar durch mindestens eine Quelle dieses Registers getragen wird.
2. `EMPIRICAL` bezeichnet eine Empfehlung, deren konkrete Schwelle oder Wirkung aus Messung im jeweiligen Workload abzuleiten ist. Die Quelle belegt nur den Mechanismus und die Messgrößen.
3. `METHOD` bezeichnet einen Diagnose- oder Unterrichtsablauf, nicht eine Produktgarantie.
4. `DIDACTIC` bezeichnet Navigation, Lernziel, Transfer oder Zusammenfassung ohne eigenständige technische Produktbehauptung.
5. Versionsangaben werden als Kombination aus Engine-Version, Datenbank-Kompatibilitätsstufe und gegebenenfalls Datenbankkonfiguration behandelt.
6. Eine Quelle für eine Funktionsfamilie darf nicht als Beleg für alle Unterfunktionen oder alle Kompatibilitätsstufen verallgemeinert werden.
