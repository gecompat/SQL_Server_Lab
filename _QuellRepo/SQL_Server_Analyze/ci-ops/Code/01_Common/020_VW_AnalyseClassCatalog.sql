USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.VW_AnalyseClassCatalog
Version      : 1.9.0
Stand        : 2026-07-22
Typ          : View
Zweck        : Definiert Analyseklassen, Kostenniveau und Pflicht zur
               AD-Gruppenprüfung für ressourcenintensive Module.
Parameter    : Keine.
Resultset    : AnalysisClass, AnalysisLevel, RequiresGroupGate,
               DefaultMaxRows, DefaultTimeoutSeconds, Description.
Berechtigung : SELECT auf der View; keine Rechtevergabe durch das Framework.
Policy       : Keine aktive Gruppendefinition = alle Klassen erlaubt; sobald
               Definitionen vorhanden sind, gelten die Regeln aus
               monitor.VW_AnalyseAccessPolicy. sysadmin besitzt Bypass.
Eigenlast    : Konstant.
Locking      : Keine fachlichen Tabellenzugriffe.
Aufruf       : SELECT * FROM monitor.VW_AnalyseClassCatalog;
Änderungen   : 1.9.0 - EXTERNAL_RUNTIME_CURRENT und CLR_CURRENT ergänzt.
               1.8.0 - SERVER_HEALTH_CURRENT, SERVER_CONFIGURATION_CURRENT und SECURITY_CONFIGURATION_CURRENT ergänzt.
               1.7.0 - SQL_AGENT_CURRENT, RESOURCE_GOVERNOR_CURRENT, HA_DR_CURRENT und ENTERPRISE_TOPOLOGY_DEEP ergänzt.
               1.6.0 - EXTENDED_EVENTS_CURRENT für leichte reine Sessioninventarisierung ergänzt.
               1.5.0 - QUERY_STORE_CURRENT für gezielte lesende Query-Store-Analysen ergänzt.
               1.4.0 - PLAN_CACHE_CURRENT und SHOWPLAN_TARGETED ergänzt.
               1.3.0 - INDEX_OPERATIONAL_DEEP ergänzt.
               1.2.0 - Zielgerichtete Phase-2-Analyseklassen ergänzt.
               1.1.0 - LOCKS_DEEP und LOG_VLF_DEEP ergänzt.
               1.0.0 - Erstfassung Phase 1A.
===============================================================================
*/
CREATE OR ALTER VIEW [monitor].[VW_AnalyseClassCatalog]
AS
    SELECT
        [v].[AnalysisClass],
        [v].[AnalysisLevel],
        [v].[RequiresGroupGate],
        [v].[DefaultMaxRows],
        [v].[DefaultTimeoutSeconds],
        [v].[Description]
    FROM
    (
        VALUES
          (CAST('STANDARD_CURRENT'                 AS varchar(64)), CAST('STANDARD' AS varchar(16)), CAST(0 AS bit), CAST(1000 AS int), CAST(10 AS int), CAST(N'Leichtgewichtige Current-State-Abfragen für Sessions, Requests, Blocking, Waits, Memory, TempDB und I/O.' AS nvarchar(1000))),
          (CAST('EXTENDED_CURRENT'                 AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(2000 AS int), CAST(20 AS int), CAST(N'Gezielte Current-State-Vertiefung mit begrenzter SQL-Text-, Plan- und Objektauflösung.' AS nvarchar(1000))),
          (CAST('PLAN_CACHE_CURRENT'                AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(1000 AS int), CAST(30 AS int), CAST(N'Begrenzte Query-Stats- und Plan-Cache-Auswertungen ohne vollständiges XML-Shredding.' AS nvarchar(1000))),
          (CAST('SHOWPLAN_TARGETED'                 AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(100 AS int), CAST(30 AS int), CAST(N'Gezielte Showplan-Extraktion und XML-Analyse für konkret gefilterte Planhandles oder Query Hashes.' AS nvarchar(1000))),
          (CAST('OBJECT_ANALYSIS_CURRENT'           AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(30 AS int), CAST(N'Gezielte Objekt-, Index-, Partitions- und Columnstore-Kataloganalyse einer Datenbank.' AS nvarchar(1000))),
          (CAST('EXTERNAL_RUNTIME_CURRENT'          AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(2000 AS int), CAST(60 AS int), CAST(N'Lesende Konfigurations-, Katalog-, Request-, Pool- und Counteranalyse externer SQL-Server-Runtimes ohne Testausführung.' AS nvarchar(1000))),
          (CAST('CLR_CURRENT'                       AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(2000 AS int), CAST(60 AS int), CAST(N'Lesende SQL-CLR-Katalog-, Host-, AppDomain-, Task-, Request-, Speicher- und Counteranalyse ohne Assemblyausführung.' AS nvarchar(1000))),
          (CAST('MISSING_INDEX_CURRENT'            AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(30 AS int), CAST(N'Flüchtige Missing-Index-Hinweise mit begrenzter Ergebnismenge; keine automatische DDL-Ausführung.' AS nvarchar(1000))),
          (CAST('STATISTICS_TARGETED'              AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(30 AS int), CAST(N'Gezielte Statistik-Eigenschaftsanalyse für gefilterte Objekte.' AS nvarchar(1000))),
          (CAST('COLUMNSTORE_CURRENT'              AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(30 AS int), CAST(N'Gezielte Columnstore-Rowgroup-Analyse über Katalogsicht ohne Segment-/Dictionary-Vollscan.' AS nvarchar(1000))),
          (CAST('LOCKS_DEEP'                       AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(5000 AS int), CAST(60 AS int), CAST(N'Detaillierte Materialisierung von sys.dm_tran_locks für die aktuell relevante Sessionmenge.' AS nvarchar(1000))),
          (CAST('LOG_VLF_DEEP'                     AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(20000 AS int), CAST(90 AS int), CAST(N'Datenbankübergreifende VLF-Auswertung über sys.dm_db_log_info.' AS nvarchar(1000))),
          (CAST('PLAN_CACHE_DEEP'                  AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(5000 AS int), CAST(60 AS int), CAST(N'Breite oder vollständige Analyse von Query Stats und Plan Cache.' AS nvarchar(1000))),
          (CAST('SHOWPLAN_XML_DEEP'                AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(1000 AS int), CAST(90 AS int), CAST(N'XML-Analyse gecachter oder aktueller Showplans einschließlich Warnings, Spills, Objekten und Statistiken.' AS nvarchar(1000))),
          (CAST('CATALOG_DEEP'                     AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(10000 AS int), CAST(90 AS int), CAST(N'Breite Systemkatalog-, Objekt-, Index-, Statistik- und Partitionsanalyse.' AS nvarchar(1000))),
          (CAST('PHYSICAL_STATS_DEEP'              AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(10000 AS int), CAST(180 AS int), CAST(N'Explizite Auswertung von sys.dm_db_index_physical_stats in einem bewusst gewählten Modus.' AS nvarchar(1000))),
          (CAST('INDEX_OPERATIONAL_DEEP'           AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(10000 AS int), CAST(120 AS int), CAST(N'Breite kumulative Index-Operational-Stats mit Lock-, Latch-, I/O-Latch- und Page-Split-Zählern.' AS nvarchar(1000))),
          (CAST('QUERY_STORE_CURRENT'              AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(1000 AS int), CAST(30 AS int), CAST(N'Gezielte lesende Query-Store-Status-, Runtime-, Wait-, Plan- und Force-Auswertung mit engem Zeit- und Zeilenlimit.' AS nvarchar(1000))),
          (CAST('EXTENDED_EVENTS_CURRENT'           AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(30 AS int), CAST(N'Leichte Inventarisierung vorhandener Extended-Events-Definitionen und laufender Sessions ohne Targetdaten oder Eventhistorie.' AS nvarchar(1000))),
          (CAST('QUERY_STORE_DEEP'                 AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(10000 AS int), CAST(120 AS int), CAST(N'Breite Query-Store-Historie, Regressionen, Planwechsel und Wait-Auswertungen.' AS nvarchar(1000))),
          (CAST('CROSS_DATABASE_DEEP'              AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(20000 AS int), CAST(180 AS int), CAST(N'Datenbankübergreifende Inventarisierung und Diagnose.' AS nvarchar(1000))),
          (CAST('COLUMNSTORE_DEEP'                 AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(10000 AS int), CAST(120 AS int), CAST(N'Breite Columnstore-Analyse einschließlich Rowgroups, Deleted Rows, Dictionaries und Segmenten.' AS nvarchar(1000))),
          (CAST('EXTENDED_EVENTS_FORENSICS_DEEP'   AS varchar(64)), CAST('FORENSIK' AS varchar(16)), CAST(1 AS bit), CAST(5000 AS int), CAST(120 AS int), CAST(N'Optionale Auswertung vorhandener Extended-Events-Sessions und Event-Dateien; niemals Primärquelle des Standardlaufs.' AS nvarchar(1000))),
          (CAST('SERVER_HEALTH_CURRENT'             AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(2000 AS int), CAST(30 AS int), CAST(N'CPU-, NUMA-, Memory-, TempDB-, OS- und Dienstzustand der aktuellen Instanz.' AS nvarchar(1000))),
          (CAST('SERVER_CONFIGURATION_CURRENT'      AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(2000 AS int), CAST(30 AS int), CAST(N'Lesende Serverkonfiguration, Trace Flags und Startup-Parameter.' AS nvarchar(1000))),
          (CAST('SECURITY_CONFIGURATION_CURRENT'    AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(2000 AS int), CAST(30 AS int), CAST(N'Lesende sicherheits- und dienstbezogene Betriebsparameter.' AS nvarchar(1000))),
          (CAST('SQL_AGENT_CURRENT'                 AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(30 AS int), CAST(N'Lesende SQL-Server-Agent-Status-, Job-, Schedule- und Historienanalyse aus msdb.' AS nvarchar(1000))),
          (CAST('RESOURCE_GOVERNOR_CURRENT'           AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(30 AS int), CAST(N'Lesende Resource-Governor-Konfigurations- und Laufzeitanalyse.' AS nvarchar(1000))),
          (CAST('HA_DR_CURRENT'                       AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(5000 AS int), CAST(60 AS int), CAST(N'Begrenzte lesende Analyse von Availability Groups, Backup, Log Shipping, Replication, CDC und Change Tracking.' AS nvarchar(1000))),
          (CAST('ENTERPRISE_TOPOLOGY_DEEP'            AS varchar(64)), CAST('DEEP' AS varchar(16)), CAST(1 AS bit), CAST(10000 AS int), CAST(120 AS int), CAST(N'Vertiefte enterpriseweite Topologie- und Distribution-Analyse für HA/DR und Replication.' AS nvarchar(1000))),
          (CAST('DATA_PLATFORM_ADAPTER_CURRENT'          AS varchar(64)), CAST('ERWEITERT' AS varchar(16)), CAST(0 AS bit), CAST(1000 AS int), CAST(15 AS int), CAST(N'Optionale Current-State-Anreicherung aus kundenspezifischen Data-Platform-/ETL-Loggingobjekten mit isolierter Existenz- und Rechteprüfung.' AS nvarchar(1000)))
    ) AS [v]
    (
        [AnalysisClass],
        [AnalysisLevel],
        [RequiresGroupGate],
        [DefaultMaxRows],
        [DefaultTimeoutSeconds],
        [Description]
    );
GO
