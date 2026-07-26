USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : Quellen-Seed für [monitor].[WaitTypeCatalogSource]
Stand        : 2026-07-20
Vertrag      : Definition, Messmethodik, wait-spezifische Fachreferenz und
               Diagnosequelle je Wait Group werden getrennt ausgewiesen.
               SQLskills-Inhalte werden nur verlinkt und nicht übernommen.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DELETE FROM [monitor].[WaitTypeCatalogSource]
WHERE [IsFrameworkDefault]=1;

/* 1: Offizielle Namens- und Kurzdefinitionsquelle. */
INSERT [monitor].[WaitTypeCatalogSource]
(
 [WaitType],[SourceOrdinal],[SourceType],[Publisher],[SourceTitle],[SourceUrl],
 [SupportsFields],[EvidenceLevel],[SourceNotes],[IsFrameworkDefault]
)
SELECT [c].[WaitType],1,'DEFINITION',N'Microsoft',
       N'sys.dm_os_wait_stats – Types of Waits',
       N'https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-wait-stats-transact-sql?view=sql-server-ver17',
       N'WaitType, Meaning, Versionshinweise',
       'PRIMARY_VENDOR',
       N'Gemeinsame Microsoft-Primärreferenz für Name und dokumentierte Kurzdefinition; belegt nicht automatisch Frameworkinterpretation oder Gegenmaßnahme.',1
FROM [monitor].[WaitTypeCatalog] AS [c] WITH (NOLOCK)
WHERE [c].[IsFrameworkDefault]=1;

/* 2: Offizielle Mess- und Abgrenzungsmethodik für runner/waiter, Delta,
      aktive Requests und Plan-WaitStats. */
INSERT [monitor].[WaitTypeCatalogSource]
(
 [WaitType],[SourceOrdinal],[SourceType],[Publisher],[SourceTitle],[SourceUrl],
 [SupportsFields],[EvidenceLevel],[SourceNotes],[IsFrameworkDefault]
)
SELECT [c].[WaitType],2,'MEASUREMENT',N'Microsoft',
       N'Troubleshoot slow-running queries – diagnose waits or bottlenecks',
       N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-slow-running-queries',
       N'AssessmentBasis, MeasurementGuidance, CounterEvidence, RecommendedChecks',
       'PRIMARY_VENDOR',
       N'Allgemeine Methodik; die konkrete Ursache und Lösung bleibt wait- und workloadabhängig.',1
FROM [monitor].[WaitTypeCatalog] AS [c] WITH (NOLOCK)
WHERE [c].[IsFrameworkDefault]=1;

/* 3: Wait-spezifische Spezialistenreferenz. Der Katalog verlinkt nur. Die
      unterschiedliche Detailtiefe der externen Seiten wird nicht als
      Microsoft-Produktvertrag behandelt. */
INSERT [monitor].[WaitTypeCatalogSource]
(
 [WaitType],[SourceOrdinal],[SourceType],[Publisher],[SourceTitle],[SourceUrl],
 [SupportsFields],[EvidenceLevel],[SourceNotes],[IsFrameworkDefault]
)
SELECT [c].[WaitType],3,'INTERPRETATION',N'SQLskills',
       CONCAT(N'SQL Server Wait Types Library: ',[c].[WaitType]),
       N'https://www.sqlskills.com/help/waits/'+[c].[WaitType],
       N'TypicalOccurrence, AssessmentBasis, RelatedWaitTypes',
       'SPECIALIST_REFERENCE',
       N'Wait-spezifische Fachreferenz; Inhalt wird aus Lizenz- und Provenienzgründen nicht in das Repository kopiert.',1
FROM [monitor].[WaitTypeCatalog] AS [c] WITH (NOLOCK)
WHERE [c].[IsFrameworkDefault]=1;

DECLARE @FamilySource TABLE
(
 [WaitGroup] nvarchar(64) NOT NULL PRIMARY KEY,
 [SourceTitle] nvarchar(400) NOT NULL,
 [SourceUrl] nvarchar(1000) NOT NULL,
 [SupportsFields] nvarchar(500) NOT NULL,
 [EvidenceLevel] varchar(30) NOT NULL,
 [SourceNotes] nvarchar(1000) NULL
);

INSERT @FamilySource
([WaitGroup],[SourceTitle],[SourceUrl],[SupportsFields],[EvidenceLevel],[SourceNotes])
VALUES
(N'LOCKING',N'Understand and resolve SQL Server blocking problems',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/understand-resolve-blocking',N'CommonCauses, PerformanceImpact, Mitigation, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Blocking ist normal; Dauer, Head Blocker und Transaktionskontext bestimmen die Wirkung.'),
(N'STORAGE_DATA_IO',N'Troubleshoot slow SQL Server performance caused by I/O issues',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance',N'CommonCauses, PerformanceImpact, Mitigation, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Trennt I/O-Latenz, I/O-Menge, Betriebssystempfad und Workloadursachen.'),
(N'IN_MEMORY_LATCH',N'Resolve PAGELATCH_EX last-page insert contention',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/resolve-pagelatch-ex-contention',N'CommonCauses, Mitigation, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Belegt die Abgrenzung PAGELATCH zu PAGEIOLATCH und den häufigen Last-page-insert-Fall; nicht jeder PAGELATCH ist dieser Fall.'),
(N'TRANSACTION_LOG',N'Troubleshoot SQL Server I/O performance – WRITELOG',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance',N'CommonCauses, PerformanceImpact, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Behandelt Loglatenz, viele kleine Transaktionen, VLFs und Schedulerabgrenzung.'),
(N'LOG_ENGINE',N'SQL Server Transaction Log Architecture and Management Guide',N'https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-log-architecture-and-management-guide?view=sql-server-ver17',N'AssessmentBasis, CommonCauses, Mitigation, RelatedWaitTypes','PRIMARY_VENDOR',N'Architekturquelle für WAL, Flush, VLFs, Growth und Logverwaltung.'),
(N'MEMORY',N'Troubleshoot slow performance or low memory caused by memory grants',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-memory-grant-issues',N'CommonCauses, PerformanceImpact, Mitigation, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Primär für RESOURCE_SEMAPHORE und Query-Execution-Memory; interne Allocator-Waits benötigen zusätzliche Evidenz.'),
(N'CPU_SCHEDULER',N'Troubleshoot query performance between servers – runner, waiter and workers',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-query-perf-between-servers',N'AssessmentBasis, CommonCauses, Mitigation, MeasurementGuidance','PRIMARY_VENDOR',N'Allgemeine CPU-/Wait-Abgrenzung; THREADPOOL-Definition zusätzlich aus Types of Waits.'),
(N'PARALLELISM',N'Making parallelism waits actionable',N'https://techcommunity.microsoft.com/blog/sqlserver/making-parallelism-waits-actionable/385691',N'AssessmentBasis, CommonCauses, Mitigation, CounterEvidence, RelatedWaitTypes','VENDOR_ENGINEERING',N'Microsoft SQL Server Engineering Blog; CXPACKET und CXCONSUMER nicht isoliert bewerten.'),
(N'NETWORK_CLIENT',N'Troubleshoot queries with ASYNC_NETWORK_IO',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-query-async-network-io',N'CommonCauses, PerformanceImpact, Mitigation, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Trennt Resultset-, Client- und Netzwerkursachen.'),
(N'NETWORK_PROTOCOL',N'SQL Server network configuration',N'https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/sql-server-network-configuration?view=sql-server-ver17',N'CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Protokoll- und Verbindungsgrundlage; interne SNI-Waits benötigen aktiven Verbindungskontext.'),
(N'HA_REPLICATION',N'Monitor performance for Always On availability groups',N'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/monitor-performance-for-always-on-availability-groups?view=sql-server-ver17',N'CommonCauses, PerformanceImpact, Mitigation, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Beschreibt Logerzeugungs-, Send-, Harden- und Redo-Pipeline sowie RPO/RTO-Metriken.'),
(N'BACKUP_RESTORE',N'Backup overview for SQL Server',N'https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-overview-sql-server?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, PerformanceImpact, RecommendedChecks','PRIMARY_VENDOR',N'Operationskontext; I/O-Diagnose wird zusätzlich durch die allgemeine Messquelle gestützt.'),
(N'SERVICE_BROKER',N'Service Broker documentation',N'https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/sql-server-service-broker?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Komponentenquelle; Idle- und Queue-Waits gegen Transmission- und Queuezustand abgrenzen.'),
(N'FULLTEXT',N'Full-text search',N'https://learn.microsoft.com/en-us/sql/relational-databases/search/full-text-search?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Katalog-, Population- und Suchkontext.'),
(N'CLR',N'CLR integration programming concepts',N'https://learn.microsoft.com/en-us/sql/relational-databases/clr-integration/common-language-runtime-clr-integration-programming-concepts?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'CLR-Laufzeitkontext; interne Synchronisationsdetails bleiben eingeschränkt.'),
(N'SQLCLR',N'CLR integration programming concepts',N'https://learn.microsoft.com/en-us/sql/relational-databases/clr-integration/common-language-runtime-clr-integration-programming-concepts?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Assembly- und AppDomainkontext.'),
(N'FILESTREAM',N'FILESTREAM overview',N'https://learn.microsoft.com/en-us/sql/relational-databases/blob/filestream-sql-server?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'FILESTREAM-Komponentenkontext; interne Manager-Waits zusätzlich aktiv korrelieren.'),
(N'TRACING_XEVENTS',N'Extended Events overview',N'https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Eventsession-, Buffer- und Targetkontext; SQL Trace ist separat als veraltet zu berücksichtigen.'),
(N'QUERY_NOTIFICATIONS',N'Working with query notifications',N'https://learn.microsoft.com/en-us/sql/relational-databases/native-client/features/working-with-query-notifications?view=sql-server-ver15',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Komponentenquelle für Subscription- und Notification-Zustände.'),
(N'AUDIT_SECURITY',N'SQL Server Audit',N'https://learn.microsoft.com/en-us/sql/relational-databases/security/auditing/sql-server-audit-database-engine?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Audit- und Targetkontext; interne Cache-Locks bleiben implementierungsabhängig.'),
(N'REPLICATION',N'Monitor replication',N'https://learn.microsoft.com/en-us/sql/relational-databases/replication/monitor/monitoring-replication?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, PerformanceImpact, RecommendedChecks','PRIMARY_VENDOR',N'Replikationsagenten, Latenz, Fehler und Rückstau gemeinsam prüfen.'),
(N'COLUMNSTORE',N'Columnstore indexes overview',N'https://learn.microsoft.com/en-us/sql/relational-databases/indexes/columnstore-indexes-overview?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Columnstore-Build- und Segmentkontext.'),
(N'RESOURCE_GOVERNOR',N'Resource Governor',N'https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/resource-governor?view=sql-server-ver17',N'AssessmentBasis, CommonCauses, PerformanceImpact, Mitigation','PRIMARY_VENDOR',N'Throttling gegen Pool-, Workload-Group- und Klassifizierungszustand prüfen.'),
(N'DATABASE_LIFECYCLE',N'Database states',N'https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-states?view=sql-server-ver17',N'TypicalOccurrence, AssessmentBasis, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Status- und Übergangskontext; konkrete Recovery-/Versioningpfade benötigen zusätzliche Laufzeitevidenz.'),
(N'DISTRIBUTED_TRANSACTION',N'Transactions with availability groups and database mirroring',N'https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/transactions-always-on-availability-and-database-mirroring?view=sql-server-ver17',N'CommonCauses, PerformanceImpact, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'DTC- und Cross-Database-Kontext; MSDTC-Dienstzustand separat prüfen.'),
(N'TEMPDB_OBJECTS',N'tempdb database',N'https://learn.microsoft.com/en-us/sql/relational-databases/databases/tempdb-database?view=sql-server-ver17',N'CommonCauses, PerformanceImpact, Mitigation, RelatedWaitTypes','PRIMARY_VENDOR',N'Tempobjekte, interne Worktables, Space und Metadaten; nicht mit physischem I/O gleichsetzen.'),
(N'QUERY_EXECUTION',N'Troubleshoot slow-running queries',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-slow-running-queries',N'AssessmentBasis, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Plan-, CPU-, Wait- und Laufzeitabgrenzung; interne Operatorwaits bleiben kontextabhängig.'),
(N'STATISTICS',N'Statistics',N'https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics?view=sql-server-ver17',N'TypicalOccurrence, CommonCauses, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Statistikerstellung und -aktualisierung im Plan- und Wartungskontext.'),
(N'EXTERNAL_OR_PREEMPTIVE',N'sys.dm_os_waiting_tasks',N'https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-waiting-tasks-transact-sql?view=sql-server-ver17',N'AssessmentBasis, MeasurementGuidance, RecommendedChecks','PRIMARY_VENDOR',N'Aktive Task- und resource_description-Evidenz; Provider- oder Betriebssystemquelle zusätzlich untersuchen.'),
(N'INTERNAL_SYNCHRONIZATION',N'How It Works: CMemThread and debugging them',N'https://techcommunity.microsoft.com/blog/sqlserversupport/how-it-works-cmemthread-and-debugging-them/317488',N'AssessmentBasis, CommonCauses, Mitigation, RecommendedChecks','VENDOR_ENGINEERING',N'Spezifisch für CMEMTHREAD; andere Latches benötigen die konkrete Latchklasse.'),
(N'ENGINE_INTERNAL',N'SQL LogScout diagnostic collection',N'https://github.com/microsoft/SQL_LogScout',N'MeasurementGuidance, CounterEvidence, RecommendedChecks','VENDOR_TOOLING',N'Keine Semantikerweiterung undokumentierter Waits; dient der reproduzierbaren Evidenzerhebung für Supportfälle.'),
(N'DIAGNOSTICS_INTERNAL',N'SQL LogScout diagnostic collection',N'https://github.com/microsoft/SQL_LogScout',N'MeasurementGuidance, CounterEvidence, RecommendedChecks','VENDOR_TOOLING',N'Interne Diagnosewaits nicht ohne reproduzierbaren Fehler- und Buildkontext bewerten.'),
(N'BENIGN_BACKGROUND',N'sys.dm_os_wait_stats – benign and queue waits',N'https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-wait-stats-transact-sql?view=sql-server-ver17',N'DefaultAssessment, CounterEvidence, MeasurementGuidance','PRIMARY_VENDOR',N'Hohe kumulative Idle-Zeit ist ohne Funktionsstörung regelmäßig erwartbar.');

INSERT [monitor].[WaitTypeCatalogSource]
(
 [WaitType],[SourceOrdinal],[SourceType],[Publisher],[SourceTitle],[SourceUrl],
 [SupportsFields],[EvidenceLevel],[SourceNotes],[IsFrameworkDefault]
)
SELECT [c].[WaitType],4,'DIAGNOSTIC_MITIGATION',N'Microsoft',
       [f].[SourceTitle],[f].[SourceUrl],[f].[SupportsFields],
       [f].[EvidenceLevel],[f].[SourceNotes],1
FROM [monitor].[WaitTypeCatalog] AS [c] WITH (NOLOCK)
JOIN @FamilySource AS [f] ON [f].[WaitGroup]=[c].[WaitGroup]
WHERE [c].[IsFrameworkDefault]=1;

/* Exakte zusätzliche Engineeringquellen für besonders häufige Entscheidungen. */
DECLARE @ExactSource TABLE
(
 [WaitType] nvarchar(120) NOT NULL PRIMARY KEY,
 [SourceTitle] nvarchar(400) NOT NULL,
 [SourceUrl] nvarchar(1000) NOT NULL,
 [SupportsFields] nvarchar(500) NOT NULL,
 [EvidenceLevel] varchar(30) NOT NULL,
 [SourceNotes] nvarchar(1000) NULL
);

INSERT @ExactSource
([WaitType],[SourceTitle],[SourceUrl],[SupportsFields],[EvidenceLevel],[SourceNotes])
VALUES
(N'HADR_SYNC_COMMIT',N'Troubleshooting high HADR_SYNC_COMMIT with Always On availability groups',N'https://techcommunity.microsoft.com/blog/sqlserver/troubleshooting-high-hadr-sync-commit-wait-type-with-always-on-availability-grou/385369',N'AssessmentBasis, CommonCauses, Mitigation, CounterEvidence','VENDOR_ENGINEERING',N'Trennt lokalen Log Flush, Transport und Remote Harden.'),
(N'CMEMTHREAD',N'How It Works: CMemThread and debugging them',N'https://techcommunity.microsoft.com/blog/sqlserversupport/how-it-works-cmemthread-and-debugging-them/317488',N'AssessmentBasis, CommonCauses, Mitigation, RecommendedChecks','VENDOR_ENGINEERING',N'Memory-object-spezifische Diagnose statt pauschaler Memory-Grant-Deutung.'),
(N'CXPACKET',N'Making parallelism waits actionable',N'https://techcommunity.microsoft.com/blog/sqlserver/making-parallelism-waits-actionable/385691',N'AssessmentBasis, CommonCauses, Mitigation, CounterEvidence','VENDOR_ENGINEERING',N'Gemeinsam mit CXCONSUMER, Plan, Skew und CPU bewerten.'),
(N'CXCONSUMER',N'Making parallelism waits actionable',N'https://techcommunity.microsoft.com/blog/sqlserver/making-parallelism-waits-actionable/385691',N'DefaultAssessment, AssessmentBasis, CounterEvidence','VENDOR_ENGINEERING',N'Erwarteten Konsumentenanteil nicht isoliert optimieren.'),
(N'ASYNC_NETWORK_IO',N'Troubleshoot queries with ASYNC_NETWORK_IO',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-query-async-network-io',N'CommonCauses, PerformanceImpact, Mitigation, CounterEvidence','PRIMARY_VENDOR',N'Client-Fetching ist häufiger als ein physisches Netzwerkproblem.'),
(N'WRITELOG',N'Troubleshoot SQL Server I/O performance – WRITELOG causes',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance',N'CommonCauses, PerformanceImpact, Mitigation, RecommendedChecks','PRIMARY_VENDOR',N'Loglatenz, VLFs, kleine Transaktionen und Scheduling getrennt prüfen.'),
(N'PAGELATCH_EX',N'Resolve PAGELATCH_EX last-page insert contention',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/resolve-pagelatch-ex-contention',N'CommonCauses, Mitigation, CounterEvidence, RecommendedChecks','PRIMARY_VENDOR',N'Last-page insert ist ein wichtiger, aber nicht der einzige PAGELATCH_EX-Fall.'),
(N'RESOURCE_SEMAPHORE',N'Troubleshoot memory grant issues',N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-memory-grant-issues',N'CommonCauses, PerformanceImpact, Mitigation, CounterEvidence','PRIMARY_VENDOR',N'Execution Grants, Pending Queue, Plan und Cardinality gemeinsam prüfen.');

INSERT [monitor].[WaitTypeCatalogSource]
(
 [WaitType],[SourceOrdinal],[SourceType],[Publisher],[SourceTitle],[SourceUrl],
 [SupportsFields],[EvidenceLevel],[SourceNotes],[IsFrameworkDefault]
)
SELECT [e].[WaitType],5,'EXACT_DIAGNOSTIC',N'Microsoft',
       [e].[SourceTitle],[e].[SourceUrl],[e].[SupportsFields],
       [e].[EvidenceLevel],[e].[SourceNotes],1
FROM @ExactSource AS [e]
WHERE EXISTS
(
 SELECT 1
 FROM [monitor].[WaitTypeCatalog] AS [c] WITH (NOLOCK)
 WHERE [c].[WaitType]=[e].[WaitType] AND [c].[IsFrameworkDefault]=1
);
GO
