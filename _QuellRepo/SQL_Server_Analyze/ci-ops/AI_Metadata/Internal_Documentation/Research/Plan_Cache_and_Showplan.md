# Recherche Phase 3 – Plan Cache und Showplan

Stand: 2026-07-14

## Microsoft-Dokumentation

- Microsoft (o. J.): *sys.dm_exec_query_stats (Transact-SQL)*. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-stats-transact-sql?view=sql-server-ver17
- Microsoft (o. J.): *sys.dm_exec_cached_plans (Transact-SQL)*. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-cached-plans-transact-sql?view=sql-server-ver17
- Microsoft (o. J.): *sys.dm_exec_plan_attributes (Transact-SQL)*. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-plan-attributes-transact-sql?view=sql-server-ver17
- Microsoft (o. J.): *sys.dm_exec_query_plan (Transact-SQL)*. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-plan-transact-sql?view=sql-server-ver17
- Microsoft (o. J.): *sys.dm_exec_text_query_plan (Transact-SQL)*. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-text-query-plan-transact-sql?view=sql-server-ver17
- Microsoft (o. J.): *sys.dm_exec_query_plan_stats (Transact-SQL)*. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-plan-stats-transact-sql?view=sql-server-ver17
- Microsoft (o. J.): *sys.dm_exec_query_statistics_xml (Transact-SQL)*. https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-statistics-xml-transact-sql?view=sql-server-ver17
- Microsoft (o. J.): *ALTER DATABASE SCOPED CONFIGURATION*. https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql?view=sql-server-ver17

**Abrufdatum aller Onlinequellen:** 14. Juli 2026.

## Open-Source-Vergleich

- Brent Ozar Unlimited: *SQL Server First Responder Kit / sp_BlitzCache*. https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit
- Erik Darling Data: *DarlingData / Quickie Cache*. https://github.com/erikdarlingdata/DarlingData
- Eitan Blumin: *Find Top Exec Plans to Optimize*. https://gist.github.com/EitanBlumin/e3a3ad4893365def500d0cdbb8d58872

Die externen Werkzeuge dienten dem Funktionsvergleich: Top-N-Ressourcendimensionen, Single-use- und Duplicate-Plan-Analyse sowie planbasierte Findings. Es wurde kein fremder Quellcode übernommen.

## Abgeleitete Implementierungsregeln

- `sys.dm_exec_query_stats` enthält nur abgeschlossene Statements und nur solange der Plan im Cache liegt.
- SQL-Text und Showplan dürfen bei Standardaufrufen nicht über den gesamten Cache `CROSS APPLY`-geschreddert werden.
- `sys.dm_exec_text_query_plan` ist als gezielte Alternative vorzusehen, weil es nicht der XML-Nesting-Grenze unterliegt und Statement-Offets unterstützt.
- Last Actual Plan ist opt-in und kann trotz gültigem Planhandle NULL liefern.
- Live Query Plan ist transient und kann zwischen Sessionermittlung und DMV-Aufruf verschwinden. `ParameterRuntimeValue` kann auf SQL Server 2019 ab CU12 fehlen, da Microsoft dieses Attribut wegen eines möglichen Access-Violation-Problems aus dieser DMV-Ausgabe entfernt hat.
- Planhandles und Query-Stats-Zeilen sind flüchtig; Partial Results sind daher normales, dokumentiertes Verhalten.
