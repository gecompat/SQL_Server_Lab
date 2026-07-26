# Recherchequellen und Referenzlösungen

**Recherche-/Prüfstand:** 21. Juli 2026
**Verwendung:** fachliche Referenz, Abgleich von Semantik, Berechtigungen, Versionsunterschieden, Overhead und bekannten Risiken. Community-Code wird nicht ungeprüft übernommen.

Die versionsabhängigen Kernaussagen der Analysis Guides sind zusätzlich in `Documentation/Analysis_Guides/Version_Primary_Source_Matrix.md` den unterstützten Zielversionen, betroffenen Bereichen und noch erforderlichen Laufzeitnachweisen zugeordnet. Der externe Linkvalidator prüft diese Datei und die Analysis Guides auf dauerhaft verlorene Ziele.

## 1. Primärquellen – Microsoft SQL Server

1. Microsoft (2026): *System dynamic management views*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/system-dynamic-management-views?view=sql-server-ver17 (Zugriff: 14.07.2026).
2. Microsoft (2025): *Extended Events overview*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver17 (Zugriff: 14.07.2026).
3. Microsoft (2025): *Use the system_health session*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/use-the-system-health-session?view=sql-server-ver17 (Zugriff: 14.07.2026).
4. Microsoft (2025): *SELECTs and JOINs from System Views for Extended Events*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/selects-and-joins-from-system-views-for-extended-events-in-sql-server?view=sql-server-ver17 (Zugriff: 14.07.2026).
5. Microsoft (2025): *Monitor performance by using the Query Store*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17 (Zugriff: 14.07.2026).
6. Microsoft (2026): *Best practices for monitoring workloads with Query Store*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/performance/best-practice-with-the-query-store?view=sql-server-ver17 (Zugriff: 14.07.2026).
7. Microsoft (2026): *sys.dm_exec_query_stats*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-stats-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
8. Microsoft (2026): *sys.dm_exec_query_plan*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-plan-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
9. Microsoft (2025): *sys.dm_exec_query_statistics_xml*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-statistics-xml-transact-sql?view=azuresqldb-current (Zugriff: 14.07.2026).
10. Microsoft (2026): *Live Query Statistics*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/performance/live-query-statistics?view=sql-server-ver17 (Zugriff: 14.07.2026).
11. Microsoft (2026): *Query Profiling Infrastructure*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-profiling-infrastructure?view=sql-server-ver17 (Zugriff: 14.07.2026).
12. Microsoft (2026): *sys.dm_db_index_physical_stats*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-physical-stats-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
13. Microsoft (2025): *sys.dm_db_column_store_row_group_physical_stats*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-column-store-row-group-physical-stats-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
14. Microsoft (2026): *sp_server_diagnostics*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-server-diagnostics-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
15. Microsoft (2025): *Blocked Process Report Event Class*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/event-classes/blocked-process-report-event-class?view=sql-server-ver17 (Zugriff: 14.07.2026).
16. Microsoft (2025): *blocked process threshold Server Configuration Option*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/blocked-process-threshold-server-configuration-option?view=sql-server-ver17 (Zugriff: 14.07.2026).
17. Microsoft (2026): *Performance Monitoring and Tuning Tools*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/performance/performance-monitoring-and-tuning-tools?view=sql-server-ver17 (Zugriff: 14.07.2026).


18. Microsoft (2026): *sys.login_token*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-login-token-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
19. Microsoft (2025): *IS_MEMBER*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/t-sql/functions/is-member-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
20. Microsoft (2025): *HAS_PERMS_BY_NAME*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/t-sql/functions/has-perms-by-name-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
21. Microsoft (2026): *sys.dm_db_log_stats*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-log-stats-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
22. Microsoft (2026): *sys.dm_db_log_info*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-log-info-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).
23. Microsoft (2025): *ADD SIGNATURE*. Verfügbar unter: https://learn.microsoft.com/en-us/sql/t-sql/statements/add-signature-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).

24. Microsoft (2025): *CREATE PROCEDURE (Transact-SQL)*. `CREATE OR ALTER` gilt für SQL Server ab 2016 SP1. Verfügbar unter: https://learn.microsoft.com/de-de/sql/t-sql/statements/create-procedure-transact-sql?view=sql-server-ver17 (Zugriff: 14.07.2026).

## 2. Referenzimplementierungen und Community-Lösungen

1. Machanic, A. (2026): *sp_WhoIsActive*. GitHub Repository. Verfügbar unter: https://github.com/amachanic/sp_whoisactive (Zugriff: 14.07.2026).
2. Brent Ozar Unlimited (2026): *SQL Server First Responder Kit*. GitHub Repository. Verfügbar unter: https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit (Zugriff: 14.07.2026).
3. Berry, G. (2026): *SQL Server Diagnostic Information Queries*. Verfügbar unter: https://glennsqlperformance.com/resources/ (Zugriff: 14.07.2026).
4. dbatools (o. J.): *Install-DbaWhoIsActive*. Verfügbar unter: https://dbatools.io/Install-DbaWhoIsActive/ (Zugriff: 14.07.2026).
5. dbatools (o. J.): *Install-DbaFirstResponderKit*. Verfügbar unter: https://dbatools.io/Install-DbaFirstResponderKit/ (Zugriff: 14.07.2026).

## 3. Ableitungen für das Framework

### Dokumentiert

- DMVs/DMFs liefern aktuellen Server- und Datenbankzustand, besitzen aber je nach Version unterschiedliche Berechtigungsanforderungen.
- `sys.dm_exec_query_stats` ist an die Lebensdauer des jeweiligen gecachten Plans gebunden und daher keine vollständige Historie.
- Query Store persistiert Query-, Plan-, Runtime- und ab SQL Server 2017 Wait-Historie in Zeitintervallen.
- `system_health` ist eine standardmäßig vorhandene Extended-Events-Session und enthält unter anderem erkannte Deadlock-Graphen; ihre Lesbarkeit hängt dennoch von Berechtigungen und Plattform ab.
- `sys.dm_db_index_physical_stats` kann Locks verursachen und auf lesbaren AG-Secondaries REDO blockieren. Es darf deshalb nicht unkritisch in Standardläufen verwendet werden.
- Live Query Statistics beziehungsweise Query Profiling kann messbaren Overhead erzeugen und gehört in einen gezielten Troubleshooting-Modus.


- `sys.login_token` liefert eine Zeile je Serverprincipal im aktuellen Login-Token und weist Windows-Gruppen als `WINDOWS GROUP` aus.
- `IS_MEMBER` prüft Windows-Gruppen anhand des beim Verbindungsaufbau erzeugten Access Tokens; Änderungen an Gruppenmitgliedschaften werden erst nach neuem Login sichtbar. Bei SQL Logins oder Application Roles ist eine Windows-Gruppenprüfung nicht möglich.
- Eine Modulsignatur kann vollständig per T-SQL hinzugefügt werden; jede Änderung am Modul entfernt die Signatur. Das vollständige Berechtigungsmodell benötigt jedoch Zertifikatsprincipals und Rechtezuweisungen und bleibt deshalb außerhalb des Frameworks.
- Allgemeines `CREATE OR ALTER PROCEDURE` steht in SQL Server ab 2016 SP1 zur Verfügung; ältere Zielversionen benötigen eine idempotente Alternative.

### Architekturentscheidung

- Standarddiagnose: zustandslose DMV-/DMF- und Systemtabellen-`SELECT`s. Eigene Persistenz ist ein späteres, explizites Zusatzpaket.
- Query Store: bevorzugte persistente Query-/Plan-Historie, sofern verfügbar.
- Extended Events: optionale Ergänzung für Forensik und Ereignisse, nicht Voraussetzung für den Standardpfad.
- Ressourcenschwere Module: zusätzliche AD-Gruppenpolicy über den aktuellen Login-Token; keine Rechtevergabe durch das Framework.
- Community-Lösungen dienen als Funktions- und UX-Benchmark; Code, Lizenz und Seiteneffekte werden separat geprüft.

## 4. Lizenz- und Übernahmehinweis

Die genannten Community-Projekte werden in diesem Stand nur referenziert. Es wurde kein fremder Quellcode aus dem Internet in das Projekt kopiert. Vor einer späteren Übernahme einzelner Algorithmen oder Codebestandteile sind Lizenz, Attribution, Versionsstand und Kompatibilität zu prüfen.


## Phase 1A – zusätzlich verifizierte offizielle Quellen

- Microsoft Learn: `sys.dm_tran_persistent_version_store_stats` – DMV für ADR/PVS, SQL Server 2019+, keine parametrisierte DMF. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-tran-persistent-version-store-stats
- Microsoft Learn: `sys.dm_db_log_stats` – DMF mit `database_id`; SQL Server 2019 `VIEW SERVER STATE`, SQL Server 2022+ `VIEW SERVER PERFORMANCE STATE`. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-log-stats-transact-sql
- Microsoft Learn: `sys.dm_db_log_info` – versionsabhängige Permission-Semantik. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-log-info-transact-sql
- Microsoft Learn: `sys.dm_db_index_physical_stats` – Objekt-/Datenbank-/Server-Wildcard und zugehörige Permission-Unterschiede. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-physical-stats-transact-sql
- Microsoft Learn: `sys.dm_db_column_store_row_group_physical_stats` – CONTROL-/VIEW-DATABASE-STATE-Anforderungen und SQL-Server-2022-Änderung. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-column-store-row-group-physical-stats-transact-sql


## Ergänzungen Phase 1B – offizielle Microsoft-Dokumentation

- Microsoft: `sys.dm_exec_requests` – Current Requests und Berechtigungswechsel ab SQL Server 2022: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-requests-transact-sql
- Microsoft: `sys.dm_exec_query_memory_grants` – aktuelle Memory Grants: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-memory-grants-transact-sql
- Microsoft: `sys.dm_tran_locks` – Live-Lockmanager, mögliche Materialisierungskosten, keine Historie: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-tran-locks-transact-sql
- Microsoft: `sys.dm_io_virtual_file_stats` – kumulative Datei-I/O-Zähler und Berechtigungen: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-io-virtual-file-stats-transact-sql
- Microsoft: `sys.dm_db_log_space_usage`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-log-space-usage-transact-sql
- Microsoft: `sys.dm_db_log_stats`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-log-stats-transact-sql
- Microsoft: `sys.dm_tran_persistent_version_store_stats`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-persistent-version-store-stats?view=sql-server-ver17
- Microsoft: `SET LOCK_TIMEOUT` – verbindungsweiter Zustand; deshalb nicht ungesichert im Framework setzen: https://learn.microsoft.com/en-us/sql/t-sql/statements/set-lock-timeout-transact-sql


## Ergänzungen Phase 2 – offizielle Microsoft-Dokumentation

- Microsoft: `sys.dm_db_index_usage_stats` – kumulative Indexnutzung; memory-optimized und Spatial-Indizes werden nicht unterstützt: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-index-usage-stats-transact-sql
- Microsoft: `sys.dm_db_xtp_index_stats` – Indexnutzung für memory-optimized Tabellen: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-xtp-index-stats-transact-sql
- Microsoft: `sys.dm_db_index_operational_stats` – kumulative Zugriffs-, Lock-, Latch-, I/O-Latch-, Allocation- und Eskalationszähler; NULL-Parameter wirken als Wildcards: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-operational-stats-transact-sql
- Microsoft: `sys.dm_db_index_physical_stats` – Physical Stats, Scanmodi, Locks und Einschränkungen: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-physical-stats-transact-sql
- Microsoft: `sys.dm_db_missing_index_details` – flüchtige Missing-Index-Metadaten und begrenzte DMV-Kapazität: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-missing-index-details-transact-sql
- Microsoft: `sys.dm_db_stats_properties` – Statistikzeitpunkt, Zeilen, Sample und Modification Counter: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-stats-properties-transact-sql?view=sql-server-ver17
- Microsoft: `sys.partitions` – Partitionen und Datenkompression: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-partitions-transact-sql
- Microsoft: `sys.column_store_row_groups` – Columnstore-Rowgroup-Metadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-column-store-row-groups-transact-sql
- Microsoft: `sys.dm_db_column_store_row_group_physical_stats` – aktuelle Rowgroup-Physical-Stats: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-column-store-row-group-physical-stats-transact-sql
- Microsoft: `sys.column_store_segments` und `sys.column_store_dictionaries` – opt-in Segment-/Dictionary-Metadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-column-store-segments-transact-sql und https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-column-store-dictionaries-transact-sql


## Phase 5 – Extended Events

Siehe `AI_Metadata/Internal_Documentation/Research/Extended_Events.md`. Verwendet wurden ausschließlich offizielle Microsoft-Learn-Primärquellen zu system_health, XE-Katalog-/Runtimeviews, Eventfile-Leser, Deadlockgraphen und blocked process threshold.


## Ergänzung Migration – zentrale offizielle Quellen

- Microsoft Learn: System Dynamic Management Views and Functions – Scope, Versionskompatibilität und Berechtigungswechsel ab SQL Server 2022: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/system-dynamic-management-objects?view=sql-server-ver17
- Microsoft Learn: Extended-Events-Systemviews und Joinbeziehungen: https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/selects-and-joins-from-system-views-for-extended-events-in-sql-server?view=sql-server-ver17
- Microsoft Learn: Signieren von Stored Procedures mit Zertifikaten: https://learn.microsoft.com/en-us/sql/relational-databases/tutorial-signing-stored-procedures-with-a-certificate?view=sql-server-ver17
- Microsoft Learn: ADD SIGNATURE: https://learn.microsoft.com/en-us/sql/t-sql/statements/add-signature-transact-sql?view=sql-server-ver17

## Ergänzung Spezialfallanalyse – 17. Juli 2026

### Offizielle Primärquellen

- Microsoft Learn: `suspect_pages` – persistierte Hinweise auf verdächtige Seiten, begrenzte Historie und Ereignistypen: https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/suspect-pages-transact-sql?view=sql-server-ver17
- Microsoft Learn: `DBCC CHECKDB` – logische und physische Integritätsprüfungen, enthaltene DBCC-Prüfungen und dokumentierte Grenzen: https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_os_performance_counters` – Countertypen, Basiszähler und erforderliche Berechnungssemantik: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-performance-counters-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sp_server_diagnostics` – Health-Komponenten, XML-Resultsets, Wiederholungsmodus und Zeitverhalten: https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-server-diagnostics-transact-sql?view=sql-server-ver17
- Microsoft Learn: `system_health` – standardmäßig erfasste kritische Engine-, Wait-, Deadlock- und Speicherereignisse: https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/use-the-system-health-session?view=sql-server-ver17
- Microsoft Learn: Intelligent Query Processing: https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing?view=sql-server-ver17
- Microsoft Learn: Intelligent Query Processing Details: https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing-details?view=sql-server-ver17
- Microsoft Learn: Parameter Sensitive Plan Optimization: https://learn.microsoft.com/en-us/sql/relational-databases/performance/parameter-sensitive-plan-optimization?view=sql-server-ver17
- Microsoft Learn: Optimized Plan Forcing mit Query Store: https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-plan-forcing-query-store?view=sql-server-ver17
- Microsoft Learn: Query Store Hints: https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-hints?view=sql-server-ver17
- Microsoft Learn: Neuerungen in SQL Server 2025: https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2025?view=sql-server-ver17
- Microsoft Learn: TempDB Space Resource Governance: https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/tempdb-space-resource-governance?view=sql-server-ver17
- Microsoft Learn: Optimized Locking: https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-locking?view=sql-server-ver17
- Microsoft Learn: `sys.dm_os_latch_stats`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-latch-stats-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_os_spinlock_stats`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-spinlock-stats-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_db_page_info` – gezielte Seitenmetadaten ab SQL Server 2019: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-page-info-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_os_volume_stats` – Volume-, Mountpoint- und Kapazitätsmetadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-volume-stats-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_os_buffer_descriptors`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-buffer-descriptors-transact-sql?view=sql-server-ver17
- Microsoft Learn: In-Memory-OLTP-Speicher überwachen und behandeln: https://learn.microsoft.com/en-us/sql/relational-databases/in-memory-oltp/monitor-and-troubleshoot-memory-usage?view=sql-server-ver17
- Microsoft Learn: `sys.dm_db_xtp_table_memory_stats`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-xtp-table-memory-stats-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_db_xtp_memory_consumers`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-xtp-memory-consumers-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_db_xtp_hash_index_stats` einschließlich Scan-Kostenhinweis: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-xtp-hash-index-stats-transact-sql?view=sql-server-ver17
- Microsoft Learn: Hashindex-Bucket- und Ketteninterpretation: https://learn.microsoft.com/en-us/sql/relational-databases/in-memory-oltp/hash-indexes-for-memory-optimized-tables?view=sql-server-ver17
- Microsoft Learn: `sys.dm_db_xtp_checkpoint_files`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-xtp-checkpoint-files-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_db_xtp_transactions`: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-xtp-transactions-transact-sql?view=sql-server-ver17
- Microsoft Learn: Datenbank an In-Memory-OLTP-Resource-Pool binden und Attributionsgrenzen: https://learn.microsoft.com/en-us/sql/relational-databases/in-memory-oltp/bind-a-database-with-memory-optimized-tables-to-a-resource-pool?view=sql-server-ver17
- Microsoft Learn: Temporal Tables: https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables?view=sql-server-ver17
- Microsoft Learn: Temporal-Tabellen – Einschränkungen und empfohlene History-Indexreihenfolge Periodenende/Periodenstart: https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-table-considerations-and-limitations?view=sql-server-ver17
- Microsoft Learn: Automatische Retention historischer Temporal-Daten einschließlich Datenbankschalter und Hintergrund-Cleanup: https://learn.microsoft.com/en-us/sql/relational-databases/tables/manage-retention-of-historical-data-in-system-versioned-temporal-tables?view=sql-server-ver17
- Microsoft Learn: `sys.periods` – Zuordnung der SYSTEM_TIME-Start-/Endspalten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-periods-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_db_partition_stats` – approximative Zeilen-/Seitenevidenz und Berechtigungen: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-partition-stats-transact-sql?view=sql-server-ver17
- Microsoft Learn: Temporal-Konsistenzprüfungen und Grenze einer reinen Metadatenanalyse: https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-table-system-consistency-checks?view=sql-server-ver17
- Microsoft Learn: `SYSTEM_VERSIONING=OFF` trennt Current- und History-Tabelle: https://learn.microsoft.com/en-us/sql/relational-databases/tables/stopping-system-versioning-on-a-system-versioned-temporal-table?view=sql-server-ver17
- Microsoft Learn: Full-Text-DDL, -Funktionen, -Procedures und -Views: https://learn.microsoft.com/en-us/sql/relational-databases/search/full-text-search-ddl-functions-stored-procedures-and-views?view=sql-server-ver17
- Microsoft Learn: `backupset` – LSN-, Damage-, Checksum-, Fork-, Verschlüsselungs- und Kompressionsmetadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/backupset-transact-sql?view=sql-server-ver17
- Microsoft Learn: `RESTORE VERIFYONLY` – Prüfung der Sicherung und deren Grenzen: https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.transmission_queue` – Service-Broker-Backlog und Übertragungsstatus: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-transmission-queue-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.service_queues` – Queue-Schalter, interne Aktivierung, Retention und Poison-Message-Handling: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-service-queues-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_broker_queue_monitors` – Queue-Monitorzustände, Aktivierungszeitpunkte und wartende Receiver: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-queue-monitors-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_broker_activated_tasks` – aktuell durch Service Broker aktivierte Prozeduren: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-broker-activated-tasks-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.conversation_endpoints` – Zustände und Lifetime sichtbarer Conversation Endpoints: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-conversation-endpoints-transact-sql?view=sql-server-ver17
- Microsoft Learn: automatische Poison-Message-Erkennung und Queue-Deaktivierung nach fünf Rollbacks: https://learn.microsoft.com/en-us/sql/database-engine/service-broker/removing-poison-messages?view=sql-server-ver17
- Microsoft Learn: Aktivierungsprobleme über Queue-Katalog, Queue-Monitor, aktivierte Tasks und Fehlerlog eingrenzen: https://learn.microsoft.com/en-us/sql/database-engine/service-broker/troubleshooting-activation-stored-procedures?view=sql-server-ver17
- Microsoft Learn: Transmission-Einträge sind nicht ausnahmslos Fehler und können während Zustellung oder Retention bestehen: https://learn.microsoft.com/en-us/sql/database-engine/service-broker/troubleshooting-tools?view=sql-server-ver17
- Microsoft Learn: `sys.tables` – unter anderem Temporal-, FILESTREAM/FileTable- und Graph-Metadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-tables-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.columns` – unter anderem Always-Encrypted-, FILESTREAM- und Graph-Spaltenmetadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-columns-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.types` – System- und benutzerdefinierte Typen: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-types-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.external_tables` und `sys.external_data_sources` – externe Tabellen und Datenquellen; sensible Standort- und Verbindungsfelder werden vom Framework nicht gelesen: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-tables-transact-sql?view=sql-server-ver17 und https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-data-sources-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.external_languages` und `sys.external_libraries` – externe Laufzeitmetadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-languages-transact-sql?view=sql-server-ver17 und https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-external-libraries-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.assemblies` – CLR-Assembly-Metadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-assemblies-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.fulltext_indexes` – Full-Text-Indexmetadaten: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-fulltext-indexes-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.fulltext_index_columns` – Full-Text-Spaltenzuordnung und STATISTICAL_SEMANTICS: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-fulltext-index-columns-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.fulltext_index_fragments` – Fragmentstatus, Größe und Zeilenzahl: https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-fulltext-index-fragments-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_fts_index_population` – ausschließlich aktuell laufende Populationen und Statussemantik: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-index-population-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_fts_outstanding_batches` – aktuelle Batches, Fehlercode, Retry und Dokumentfehler: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-outstanding-batches-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_fts_semantic_similarity_population` – zweite semantische Populationphase: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-semantic-similarity-population-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_fts_memory_pools` – gemeinsame Gatherer-Speicherpools: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-memory-pools-transact-sql?view=sql-server-ver17
- Microsoft Learn: `sys.dm_fts_fdhosts` – aktuelle Filter-Daemon-Hostaktivität: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-fts-fdhosts-transact-sql?view=sql-server-ver17
- Microsoft Learn: Full-Text-Indizes auffüllen – Populationmodi, NO POPULATION und Change Tracking: https://learn.microsoft.com/en-us/sql/relational-databases/search/populate-full-text-indexes?view=sql-server-ver17
- Microsoft Learn: Full-Text-Performance – Fragmentierung und Merge-Kontext: https://learn.microsoft.com/en-us/sql/relational-databases/search/improve-the-performance-of-full-text-indexes?view=sql-server-ver17
- Microsoft Learn: Full-Text-Indexierung behandeln – Dokumentfehler und Crawl-Logs: https://learn.microsoft.com/en-us/sql/relational-databases/search/troubleshoot-full-text-indexing?view=sql-server-ver17
- Microsoft Learn: nativer `vector`-Datentyp ab SQL Server 2025: https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type?view=sql-server-ver17

### Öffentliche Prüfkataloge als Funktionsbenchmark

- Microsoft SQL Tiger Toolbox, BPCheck: https://github.com/microsoft/tigertoolbox/blob/master/BPCheck/README.md
- SQL Server First Responder Kit, Checks by Priority: https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/blob/dev/Documentation/sp_Blitz_Checks_by_Priority.md

Diese Prüfkataloge wurden ausschließlich zum Abgleich von Vorfallklassen verwendet. Semantik, Berechtigungen, Versionen und Ausführungskosten wurden über Microsoft-Primärquellen bewertet; fremder Quellcode wurde nicht übernommen.

## Ergänzung Tool-Hintergrundabfragen – 21. Juli 2026

- Microsoft Learn: dokumentierte `client_app_name`-Werte für GitHub Copilot
  und Copilot Completions in SSMS:
  https://learn.microsoft.com/en-us/ssms/github-copilot/troubleshoot
- Microsoft Learn: Zweck und Arbeitsweise des SSMS Object Explorer; die Seite
  dokumentiert keinen stabilen `program_name`-Vertrag:
  https://learn.microsoft.com/en-us/ssms/object/open-and-configure-object-explorer
- Microsoft Learn: ein clientseitig gesetzter Application Name wird als
  `sys.dm_exec_sessions.program_name` sichtbar:
  https://learn.microsoft.com/en-us/fabric/data-warehouse/configure-custom-sql-pools-api
- Redgate: SQL Prompt verwaltet Verbindungen und lädt Metadaten für Vorschläge;
  ein stabiler Application Name wird nicht zugesichert:
  https://documentation.red-gate.com/sp11/managing-sql-prompt-behavior/managing-connections-and-memory

Die beiden Copilot-Namen werden als hoch-konfidente Herstellerangabe geführt.
Object-Explorer- und SQL-Prompt-Muster bleiben ausdrücklich konfigurierbare
Heuristiken. Das Ergebnis wird nur zur diagnostischen Sichtbarkeit verwendet.

## Ergänzung Wait-Type-Katalog – 20. Juli 2026

Die Quellenrevision trennt ausdrücklich vier verschiedene Behauptungsarten:
offizielle Definition, korrekte Messung, fachliche Interpretation sowie
komponentenbezogene Diagnose/Minderung. Ein Link darf nur die in
`SupportsFields` genannten Aussagen stützen. Der allgemeine Microsoft-Wait-
Katalog bleibt daher Definitionsquelle, ist aber kein pauschaler Beleg für alle
Ursachen- und Handlungstexte.

### Zentrale Primärquellen und Engineeringreferenzen

- Microsoft Learn: `sys.dm_os_wait_stats` – dokumentierte Wait-Namen,
  Kurzdefinitionen, kumulative Semantik und ausgeschlossene Idle-/Queue-Waits:
  https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-wait-stats-transact-sql?view=sql-server-ver17
- Microsoft Learn: Troubleshoot slow-running queries – methodischer Ablauf aus
  Wait-/Bottleneck-Erkennung, Request-, Plan- und Ressourcenanalyse:
  https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-slow-running-queries
- Microsoft Learn: Blocking verstehen und beheben – Root Blocker, offene
  Transaktionen, Isolation und Querydauer:
  https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/understand-resolve-blocking
- Microsoft Learn: SQL-I/O-Probleme – Korrelation von I/O-Waits, Datei-
  Latenzen, Betriebssystem und Storage:
  https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance
- Microsoft Learn: Memory-Grant-Probleme – Grantwarteschlange, Schätzungen,
  Pläne, Resource Governor und `RESOURCE_SEMAPHORE`:
  https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-memory-grant-issues
- Microsoft Learn: `ASYNC_NETWORK_IO` – langsamer Clientkonsum, große
  Resultsets und Netzwerk als getrennte Hypothesen:
  https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-query-async-network-io
- Microsoft Learn: `PAGELATCH_EX` – In-Memory-Latch-Contention und TempDB-
  Allocation als spezifischer, nicht allgemeingültiger Fall:
  https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/resolve-pagelatch-ex-contention
- Microsoft Learn: Always-On-Performance – Send-/Redo-Queues, Flusskontrolle,
  Transport und Replica-Kontext:
  https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/monitor-performance-for-always-on-availability-groups?view=sql-server-ver17
- Microsoft SQL Server Blog: `HADR_SYNC_COMMIT` – Commitpfad und
  Queranalyse von Log-, Netzwerk- und Replica-Latenz:
  https://techcommunity.microsoft.com/blog/sqlserver/troubleshooting-high-hadr-sync-commit-wait-type-with-always-on-availability-grou/385369
- Microsoft SQL Server Support Blog: `CMEMTHREAD` – partitionierte
  Speicherobjekte und diagnostische Grenzen:
  https://techcommunity.microsoft.com/blog/sqlserversupport/how-it-works-cmemthread-and-debugging-them/317488
- Microsoft SQL Server Blog: Parallelism waits – getrennte Bewertung von
  `CXPACKET` und `CXCONSUMER` im Plan-/Workloadkontext:
  https://techcommunity.microsoft.com/blog/sqlserver/making-parallelism-waits-actionable/385691
- Microsoft Learn: Transaktionslogarchitektur – Logblöcke, Flush,
  Abschneidung, VLFs und Recovery-Kontext für Log-Waits:
  https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-log-architecture-and-management-guide?view=sql-server-ver17

### Externe wait-spezifische Referenz

- SQLskills Wait Types Library: https://www.sqlskills.com/help/waits/

Die Bibliothek wird nur als wait-spezifischer Navigations- und
Interpretationshinweis verlinkt. Texte werden nicht kopiert. Bei Widerspruch,
Versionsunsicherheit oder Änderungsempfehlungen haben aktuelle Microsoft-
Primärdokumentation und reproduzierbare Laufzeitevidenz Vorrang.
