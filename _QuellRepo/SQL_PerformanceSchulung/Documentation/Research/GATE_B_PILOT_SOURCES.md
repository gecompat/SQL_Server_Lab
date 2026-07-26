# Primärquellen der Gate-B-Pilotdemos

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Geltungsbereich | `QRY-001`, `OPT-002`, `CON-004`, `OPT-013` |
| Zielversionen | SQL Server 2019, 2022 und 2025 |

## 1. Zweck

Dieses Register dokumentiert die Primärquellen, die für Mechanismus, Messschnittstelle und Gültigkeitsgrenze der vier Gate-B-Piloten verwendet werden. Runtime-Effekte wie konkrete Read-Verhältnisse, Lock-Wartezeiten, Grants und Spill-Seitenzahlen werden nicht aus der Dokumentation abgeleitet, sondern in der synthetischen Matrix empirisch geprüft.

## 2. Quellen

| ID | Primärquelle | Pilotbezug | Aussagegrenze |
|---|---|---|---|
| `GBSRC-001` | [SQL Server index design guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-index-design-guide?view=sql-server-ver17) | `QRY-001` | Zugriffspfade und Indexdesign; kein allgemeines Seek-versus-Scan-Werturteil |
| `GBSRC-002` | [Troubleshoot high-CPU-usage issues in SQL Server](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-high-cpu-usage-issues) | `QRY-001` | Funktionen auf Prädikatspalten können Indexnutzung einschränken; konkrete Wirkung bleibt workloadabhängig |
| `GBSRC-003` | [Statistics](https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics?view=sql-server-ver17) | `OPT-002` | Statistikstruktur, Sampling, Histogramm und Density; CE- und Konfigurationskontext beachten |
| `GBSRC-004` | [DBCC SHOW_STATISTICS](https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-show-statistics-transact-sql?view=sql-server-ver17) | `OPT-002` | Header, Density Vector und Histogramm; Histogramm auf erster Schlüsselspalte |
| `GBSRC-005` | [sys.dm_db_stats_properties](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-stats-properties-transact-sql?view=sql-server-ver17) | `OPT-002` | Zeilen, Stichprobenzeilen, Schritte und Modification Counter |
| `GBSRC-006` | [sys.dm_db_stats_histogram](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-stats-histogram-transact-sql?view=sql-server-ver17) | `OPT-002` | programmatischer Histogrammzugriff; führende Statistikspalte |
| `GBSRC-007` | [Understand and resolve SQL Server blocking problems](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/understand-resolve-blocking) | `CON-004` | Blocking Chains, Head Blocker und methodischer Diagnosepfad |
| `GBSRC-008` | [sys.dm_exec_requests](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-requests-transact-sql?view=sql-server-ver17) | `CON-004` | `blocking_session_id`, `wait_type` und `wait_time` aktueller Requests; Rechte versionsabhängig |
| `GBSRC-009` | [sys.dm_tran_locks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-tran-locks-transact-sql?view=sql-server-ver17) | `CON-004` | aktuelle Lock-Requests und Grantzustände; Momentaufnahme, keine Historie |
| `GBSRC-010` | [Intelligent query processing](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing?view=sql-server-ver17) | `OPT-013` | Table Variable Deferred Compilation ab SQL Server 2019 und Compatibility Level 150 |
| `GBSRC-011` | [Query hints](https://learn.microsoft.com/en-us/sql/t-sql/queries/hints-transact-sql-query?view=sql-server-ver17) | `OPT-013` | `USE HINT('DISABLE_DEFERRED_COMPILATION_TV')`; querylokale Steuerung, keine globale Konfiguration |
| `GBSRC-012` | [sys.dm_exec_query_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-stats-transact-sql?view=sql-server-ver17) | `QRY-001`, `OPT-013` | statementbezogene `last_logical_reads`, Grant- und Spillzähler abgeschlossener Cacheeinträge |
| `GBSRC-013` | [Display an actual execution plan](https://learn.microsoft.com/en-us/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17) | `QRY-001`, `OPT-013` | Planoperatoren und Runtime-Warnings sind Evidenz, aber kein alleiniger Ursachenbeweis |

## 3. Evidenzklassen

`QRY-001` kombiniert dokumentierte Zugriffspfadmechanismen mit empirischer Plan- und Read-Evidenz. `OPT-002` kombiniert dokumentierte Statistiksemantik mit deterministischen Histogramminvarianten. `CON-004` kombiniert dokumentierte DMV-Beziehungen mit einer kontrolliert erzeugten Echtzeitkette. `OPT-013` kombiniert dokumentierte Deferred-Compilation- und DMV-Schnittstellen mit einem empirisch validierten Undergrant- und Spillpfad.

## 4. Review-Trigger

Eine erneute fachliche Prüfung ist erforderlich bei:

- einer neuen SQL-Server-Hauptversion oder einem neuen Compatibility Level,
- Änderungen an Table Variable Deferred Compilation oder dem Hint-Katalog,
- Änderungen der Berechtigungen für `sys.dm_exec_requests`, `sys.dm_exec_query_stats` oder Planfunktionen,
- Änderungen der Statistik-DMVs beziehungsweise `DBCC SHOW_STATISTICS`,
- einer Anpassung des synthetischen Datenmodells oder der Assertions eines Piloten.

## 5. Abnahme

Die Quellenzuordnung ist vollständig. Der Workflowlauf `30108023315` bestätigte die vier Piloten auf SQL Server 2019, 2022 und 2025 jeweils zweimal. Die Dokumentation belegt Mechanismus und Messschnittstelle; die konkrete Runtime-Wirkung wird ausschließlich aus der validierten synthetischen Matrix abgeleitet.
