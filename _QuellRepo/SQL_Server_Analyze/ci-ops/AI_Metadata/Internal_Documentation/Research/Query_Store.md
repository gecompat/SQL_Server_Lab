# Recherche Phase 4 – Query Store

Primärquellen: Microsoft Learn, Stand 2026-07-14.

- `sys.database_query_store_options`: Status, Readonly-Gründe, Speicher-, Flush-, Capture- und Cleanup-Konfiguration.
- `sys.query_store_runtime_stats`: aktive Intervalle können mehrere Zeilen für denselben Schlüssel enthalten; Werte sind vor Auswertung zu aggregieren. Laufzeit/CPU in Mikrosekunden, I/O und Memory überwiegend in 8-KB-Seiten.
- `sys.query_store_wait_stats`: Wait-Kategorien ab SQL Server 2017; auch hier können aktive Intervalle mehrere Zeilen enthalten.
- `sys.query_store_plan`: Force-Status, Failure Count und Failure Reason; SQL-Server-2022-Zusatzspalten werden nicht statisch in der 2019-Baseline verwendet.
- `sys.query_store_query_hints`: erst ab SQL Server 2022; read-only Diagnose, keine Set-/Clear-Aufrufe.

URLs:
- https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql
- https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-runtime-stats-transact-sql
- https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-wait-stats-transact-sql
- https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-plan-transact-sql
- https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-query-hints-transact-sql
