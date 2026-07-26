USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : Analytische Vertiefung des WaitTypeCatalog
Stand        : 2026-07-20
Zweck        : Klassifiziert alle Framework-Waits für System- und
               Performanceanalysen. Interne, nicht öffentlich dokumentierte
               Details bleiben ausdrücklich als begrenzte Evidenz markiert.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

/* Der alte Sammelwert OTHER_OR_NEW wird zuerst konservativ auf ENGINE_INTERNAL
   abgebildet. Nachfolgende Regeln ordnen fachlich erkennbare Komponenten zu. */
UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'ENGINE_INTERNAL'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'OTHER_OR_NEW';

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'AUDIT_SECURITY'
WHERE [IsFrameworkDefault]=1
  AND ([WaitType] LIKE N'AUDIT[_]%' OR [WaitType] IN (N'SECURITY_MUTEX',N'SEC_DROP_TEMP_KEY'));

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'COLUMNSTORE'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'COLUMNSTORE_BUILD_THROTTLE';

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'DATABASE_LIFECYCLE'
WHERE [IsFrameworkDefault]=1
  AND [WaitType] IN
      (N'CLEAR_DB',N'DAC_INIT',N'DISABLE_VERSIONING',N'ENABLE_VERSIONING',
       N'RECOVER_CHANGEDB',N'SHUTDOWN',N'SRVPROC_SHUTDOWN');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'DIAGNOSTICS_INTERNAL'
WHERE [IsFrameworkDefault]=1
  AND [WaitType] IN
      (N'CHECK_PRINT_RECORD',N'DEADLOCK_ENUM_MUTEX',N'DEADLOCK_TASK_SEARCH',N'DEBUG',
       N'DUMPTRIGGER',N'DUMP_LOG_COORDINATOR',N'ERROR_REPORTING_MANAGER',
       N'PRINT_ROLLBACK_PROGRESS');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'DISTRIBUTED_TRANSACTION'
WHERE [IsFrameworkDefault]=1
  AND ([WaitType] LIKE N'DTC%'
       OR [WaitType] LIKE N'KTM[_]%'
       OR [WaitType] LIKE N'MSQL[_]XACT%'
       OR [WaitType] LIKE N'XACT%'
       OR [WaitType] LIKE N'TRAN[_]MARKLATCH%'
       OR [WaitType]=N'TRANSACTION_MUTEX');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'FILESTREAM'
WHERE [IsFrameworkDefault]=1
  AND ([WaitType] LIKE N'FS[_]%' OR [WaitType] LIKE N'FSA[_]%' OR [WaitType] LIKE N'FSTR[_]%');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'HA_REPLICATION'
WHERE [IsFrameworkDefault]=1
  AND [WaitType] IN (N'FCB_REPLICA_READ',N'FCB_REPLICA_WRITE',N'REPLICA_WRITES');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'LOG_ENGINE'
WHERE [IsFrameworkDefault]=1
  AND [WaitType] IN (N'LOGGENERATION',N'LOGMGR',N'LOGMGR_FLUSH',N'LOGMGR_RESERVE_APPEND');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'MEMORY'
WHERE [IsFrameworkDefault]=1
  AND [WaitType] IN
      (N'LOWFAIL_MEMMGR_QUEUE',N'QRY_MEM_GRANT_INFO_MUTEX',N'SOS_LOCALALLOCATORLIST',
       N'SOS_OBJECT_STORE_DESTROY_MUTEX',N'SOS_RESERVEDMEMBLOCKLIST',N'SOS_SMALL_PAGE_ALLOC',
       N'UTIL_PAGE_ALLOC');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'NETWORK_PROTOCOL'
WHERE [IsFrameworkDefault]=1
  AND ([WaitType] LIKE N'HTTP[_]%'
       OR [WaitType] LIKE N'SNI[_]%'
       OR [WaitType] LIKE N'SOAP[_]%'
       OR [WaitType]=N'VIA_ACCEPT');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'QUERY_EXECUTION'
WHERE [IsFrameworkDefault]=1
  AND [WaitType] IN
      (N'EC',N'EXECUTION_PIPE_EVENT_INTERNAL',N'HTDELETE',N'MSQL_DQ',
       N'QUERY_ERRHDL_SERVICE_DONE',N'QUERY_EXECUTION_INDEX_SORT_EVENT_OPEN',
       N'QUERY_OPTIMIZER_PRINT_MUTEX',N'QUERY_WAIT_ERRHDL_SERVICE',
       N'SQLSORT_NORMMUTEX',N'SQLSORT_SORTMUTEX');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'QUERY_NOTIFICATIONS'
WHERE [IsFrameworkDefault]=1
  AND ([WaitType] LIKE N'QUERY[_]NOTIFICATION%' OR [WaitType]=N'WAIT_FOR_RESULTS');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'RESOURCE_GOVERNOR'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'RESMGR_THROTTLED';

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'SQLCLR'
WHERE [IsFrameworkDefault]=1
  AND ([WaitType] LIKE N'SQLCLR[_]%' OR [WaitType] IN (N'ASSEMBLY_LOAD',N'CLRHOST_STATE_ACCESS',N'MSQL_XP'));

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'TEMPDB_OBJECTS'
WHERE [IsFrameworkDefault]=1 AND [WaitType] IN (N'DROPTEMP',N'TEMPOBJ',N'WORKTBL_DROP');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'TRACING_XEVENTS'
WHERE [IsFrameworkDefault]=1 AND [WaitType] IN (N'TIMEPRIV_TIMEPERIOD',N'TRACEWRITE');

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'BACKUP_RESTORE'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'PARALLEL_BACKUP_QUEUE';

UPDATE [monitor].[WaitTypeCatalog]
SET [WaitGroup]=N'STORAGE_DATA_IO'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'WRITE_COMPLETION';

/* Gemeinsamer Messvertrag. Er verhindert, dass Startzeitkumulation, Häufigkeit
   oder ein einzelner aktiver Snapshot als Ursachennachweis missverstanden wird. */
UPDATE [c]
SET [DefaultAssessment]=CASE
        WHEN [c].[IsGenerallyBenign]=1 THEN 'EXPECTED_OR_IDLE'
        WHEN [c].[Severity]>=4 THEN 'ACTIONABLE_WHEN_ACTIVE'
        ELSE 'CONTEXT_DEPENDENT' END,
    [AssessmentBasis]=CASE
        WHEN [c].[IsGenerallyBenign]=1
          THEN N'Als Idle-, Queue-, Timer- oder Synchronisationszustand grundsätzlich erwartbar. Nur bei einer passenden Funktionsstörung und gleichzeitig fehlendem Fortschritt untersuchen.'
        ELSE N'Der Wait benennt die Ressource oder Synchronisationsstelle, nicht automatisch die Root Cause. Erst ein reproduzierbares Delta unter der betroffenen Last und aktive wartende Tasks machen ihn handlungsrelevant.' END,
    [CommonCauses]=[c].[TypicalOccurrence],
    [PerformanceImpact]=[c].[HighWaitImpact],
    [Mitigation]=CASE
        WHEN [c].[IsGenerallyBenign]=1
          THEN N'Nicht entfernen oder künstlich reduzieren. Nur die zugehörige Komponente korrigieren, wenn deren Fortschritt, SLA oder Funktionszustand tatsächlich beeinträchtigt ist.'
        ELSE N'Nicht den Wait Type selbst unterdrücken. Zuerst Ressource, verursachende Requests und Lastkorrelation bestätigen; danach Query, Transaktion, Konfiguration, Komponente oder Infrastruktur gezielt ändern und gegen eine Baseline nachmessen.' END,
    [CounterEvidence]=CASE
        WHEN [c].[IsGenerallyBenign]=1
          THEN N'Keine aktiven betroffenen Benutzerrequests, normaler Komponentenfortschritt und nur seit Start akkumulierte Zeit sprechen für erwartetes Verhalten.'
        ELSE N'Kein belastungsbezogenes Delta, keine aktiven Tasks dieses Typs oder unveränderte Benutzerlatenz trotz Wait-Anstieg sprechen gegen diesen Wait als dominanten Engpass.' END,
    [RelatedWaitTypes]=NULL,
    [MeasurementGuidance]=N'Mindestens zwei Messpunkte unter vergleichbarer Last verwenden. WaitingTasksCount, WaitTimeMs, ResourceWaitTimeMs, SignalWaitTimeMs, Durchschnitt, Anteil und aktive sys.dm_os_waiting_tasks gemeinsam prüfen. Neustart, DBCC SQLPERF-Reset und Rollenwechsel begrenzen die Vergleichbarkeit.',
    [AnalysisConfidence]=CASE
        WHEN [c].[WaitGroup] IN (N'ENGINE_INTERNAL',N'DIAGNOSTICS_INTERNAL') THEN 'INTERNAL_LIMITED'
        ELSE 'FAMILY_RESEARCHED' END,
    [LastUpdatedUtc]=SYSUTCDATETIME()
FROM [monitor].[WaitTypeCatalog] AS [c]
WHERE [c].[IsFrameworkDefault]=1;

/* Locking: Wartezeit gehört zum Opfer; die Ursache liegt regelmäßig beim
   Lockbesitzer beziehungsweise der Transaktion am Kopf der Blocking-Kette. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'Kurzes Blocking ist Teil lockbasierter Konsistenz. Problematisch wird es bei hoher aktiver Dauer, langen Blocking-Ketten, Timeouts oder wiederkehrender SLA-Verletzung. Der wartende Request ist meist nicht die Ursache.',
    [CommonCauses]=N'Lange oder offene Transaktionen, große Änderungsmengen, ungünstige Zugriffsreihenfolge, fehlende selektive Indizes, Lock Escalation, hohe Isolation, DDL bei Schema-Locks oder langsames Client-Fetching mit gehaltenen Locks.',
    [PerformanceImpact]=N'Betroffene Requests stehen still; Locks und Worker bleiben länger gebunden. Ketten können Durchsatz einbrechen lassen, Timeouts und Deadlocks begünstigen.',
    [Mitigation]=N'Head Blocker und dessen vollständigen Transaktionsweg beheben: Transaktionen verkürzen, Zugriffsreihenfolge vereinheitlichen, passende Indizes und SARG-fähige Prädikate schaffen, Batchgrößen prüfen und Row-Versioning nur nach fachlicher Bewertung erwägen. Keine pauschalen NOLOCK- oder Lock-Hints als Symptombehandlung.',
    [CounterEvidence]=N'Kurze, schnell wechselnde Blockierungen ohne Benutzerlatenz sind normal. Ein hoher kumulativer LCK-Wert ohne aktuelle Blocking-Kette beweist keinen gegenwärtigen Konflikt.',
    [RelatedWaitTypes]=N'LCK_M_*,DEADLOCK_TASK_SEARCH,TRANSACTION_MUTEX,ASYNC_NETWORK_IO',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'LOCKING';

/* Daten-I/O und Page-I/O. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'PAGEIOLATCH und verwandte I/O-Waits zeigen Wartezeit im Datenpfad. Sie trennen noch nicht zwischen langsamer Einzel-I/O, überfahrener Kapazität und unnötig hoher I/O-Menge der Workload.',
    [CommonCauses]=N'Langsame oder ausgelastete Volumes, Filtertreiber, Backup-/Snapshotkonkurrenz, große Scans, Planregressionen, fehlende Indizes, geringer Buffer-Pool-Treffergrad oder I/O-intensive Wartungsoperationen.',
    [PerformanceImpact]=N'Lese- oder Schreibfortschritt stockt; Abfrage-, Recovery-, DBCC- oder Wartungsdauer steigt. Viele schnelle I/Os können hohen Wait erzeugen, ohne dass die Einzel-I/O langsam ist.',
    [Mitigation]=N'Dateilatenz und I/O-Menge getrennt reduzieren: sys.dm_io_virtual_file_stats und Betriebssystemlatenz korrelieren, Queries/Indizes gegen unnötige Reads optimieren, Speicher- und Dateilayout prüfen sowie Storage-, Treiber- und Filterprobleme mit der Infrastruktur beheben.',
    [CounterEvidence]=N'Niedrige durchschnittliche Dateilatenz bei gleichzeitig sehr hoher I/O-Menge spricht eher für Workload-/Planoptimierung als für langsames Storage. Backup- oder DBCC-korrelierte ASYNC_IO_COMPLETION-Werte sind nicht automatisch ein OLTP-Problem.',
    [RelatedWaitTypes]=N'PAGEIOLATCH_*,IO_COMPLETION,ASYNC_IO_COMPLETION,BACKUPIO,WRITELOG',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'STORAGE_DATA_IO';

/* In-Memory-Seitenlatches. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'PAGELATCH schützt eine bereits im Buffer Pool befindliche Seite und ist kein physischer Datenträger-Wait. Erst mehrere gleichzeitig auf dieselbe wait_resource wartende Sessions belegen einen Hotspot.',
    [CommonCauses]=N'Last-page insert contention bei sequenziellen Indexschlüsseln, TempDB-Allokationsseiten, kleine Zahl heißer Daten- oder Metadatenseiten sowie hohe konkurrierende Änderungsrate.',
    [PerformanceImpact]=N'Kurze serialisierte Seitenzugriffe begrenzen die Skalierung; mit wachsender Parallelität steigt Latenz trotz schneller I/O-Infrastruktur.',
    [Mitigation]=N'wait_resource zu Datenbank, Datei, Seite, Objekt und Index auflösen. Bei letzter Indexseite OPTIMIZE_FOR_SEQUENTIAL_KEY und alternatives Schlüssel-/Indexdesign testen; bei TempDB-Verteilung, Dateizahl, gleichmäßiges Wachstum und workloadbedingte Objektanlage prüfen.',
    [CounterEvidence]=N'Verschiedene Seitenressourcen mit sehr kurzen Waits sprechen gegen einen einzelnen Hotspot. Storage-Aufrüstung behebt PAGELATCH ohne zusätzlichen I/O-Nachweis normalerweise nicht.',
    [RelatedWaitTypes]=N'PAGELATCH_EX,PAGELATCH_UP,PAGELATCH_SH,PAGEIOLATCH_*,LATCH_*',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'IN_MEMORY_LATCH';

/* Transaktionslog. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'Log-Waits sind im Commit- und Write-Ahead-Logging-Pfad zu lesen. Entscheidend ist, ob Logerzeugung, Logbuffer, Flushlatenz, VLF-/Growth-Zustand oder synchrone Replikation den Fortschritt begrenzen.',
    [CommonCauses]=N'Hohe Logerzeugungsrate, viele sehr kleine Commits, langsame Log-Flushes, Autogrowth, ungeeignete VLF-Struktur, Logvolume-Konkurrenz, CPU-Scheduling des Logwriters oder synchrone Availability-Group-Latenz.',
    [PerformanceImpact]=N'Commit-Latenz und Schreibdurchsatz steigen; Transaktionen halten Ressourcen länger. LOGBUFFER weist eher auf Erzeugung beziehungsweise Bufferdruck, WRITELOG auf den Flushpfad.',
    [Mitigation]=N'Log Bytes Flushed/sec, Flushes/sec, Bytes/Flush, sys.dm_io_virtual_file_stats, sys.dm_db_log_stats, Growth und Commitmuster korrelieren. Logvolume und Write-Cache-Garantien prüfen; Transaktionen nur kontrolliert bündeln und lange Transaktionen vermeiden.',
    [CounterEvidence]=N'Gute Logdateilatenz bei hoher Flushrate spricht eher für viele kleine Transaktionen als für langsames Storage. HADR_SYNC_COMMIT muss separat vom lokalen WRITELOG-Anteil betrachtet werden.',
    [RelatedWaitTypes]=N'WRITELOG,LOGBUFFER,LOGMGR_QUEUE,HADR_SYNC_COMMIT,LOG_RATE_GOVERNOR',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup] IN (N'TRANSACTION_LOG',N'LOG_ENGINE');

/* Query Memory und interne Memory-Manager. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'Memory-Waits haben unterschiedliche Ebenen. RESOURCE_SEMAPHORE betrifft Ausführungsspeicher, RESOURCE_SEMAPHORE_QUERY_COMPILE Compilespeicher; interne Allocator-Waits dürfen nicht automatisch wie fehlende Query Grants behandelt werden.',
    [CommonCauses]=N'Überschätzte Kardinalitäten und Grants, viele gleichzeitige Sort-/Hashabfragen, geringe verfügbare Workspace-Memory, Resource-Governor-Limits, Compile-Sturm, große Pläne oder interner Allocator-/Cache-Contention.',
    [PerformanceImpact]=N'Abfragen oder Compiles starten verspätet; Warteschlangen, Timeouts, reduzierte Parallelität und sekundäre I/O-Spills können entstehen.',
    [Mitigation]=N'sys.dm_exec_query_memory_grants, Granted Workspace Memory, Memory Grants Pending, Pläne, Kardinalität und Spills prüfen. Statistiken, Query-/Indexdesign, Parallelität, Concurrency und Resource Governor korrigieren; max server memory oder Hardware erst nach bestätigter Gesamtspeicheranalyse ändern.',
    [CounterEvidence]=N'Interne Memory-Waits ohne Pending Grants oder betroffene aktive Queries beweisen keinen Grant-Engpass. Einzelne große Grants können korrekt sein; entscheidend sind Warteschlange, Dauer und Workloadwirkung.',
    [RelatedWaitTypes]=N'RESOURCE_SEMAPHORE,RESOURCE_SEMAPHORE_QUERY_COMPILE,RESOURCE_SEMAPHORE_SMALL_QUERY,SOS_VIRTUALMEMORY_LOW,CMEMTHREAD',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'MEMORY';

/* Scheduler und Worker. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'SOS_SCHEDULER_YIELD zeigt kooperative CPU-Abgabe nach verbrauchtem Quantum; THREADPOOL zeigt fehlende freie Worker. Beide brauchen Scheduler-, CPU-, Blocking- und Parallelitätskontext und sind nicht durch bloßes Erhöhen eines Grenzwerts erklärt.',
    [CommonCauses]=N'CPU-intensive Pläne, hohe logische Reads, Compilelast, Spin-/Allocator-Contention, zu viele parallele Worker, lange blockierte Requests, externe Warteketten oder ungeeignete max-worker-threads-Konfiguration.',
    [PerformanceImpact]=N'Bei CPU-Druck wächst die Runnable Queue; bei Worker-Erschöpfung können neue Requests, Logins und interne Tasks nicht starten und die Instanz wirkt eingefroren.',
    [Mitigation]=N'Runnable Tasks je Scheduler, CPU je NUMA-Knoten, aktive Requests, Blocking-Ketten, DOP und Worker-Auslastung prüfen. Teure Pläne und Blocking beheben, Concurrency begrenzen und Parallelitätskonfiguration workloadbezogen testen; max worker threads nicht reflexartig erhöhen.',
    [CounterEvidence]=N'SOS_SCHEDULER_YIELD bei niedriger Runnable Queue und ohne CPU-Sättigung kann normale Abgabe sein. THREADPOOL ist erst mit Workerknappheit und verzögertem Requeststart bestätigt.',
    [RelatedWaitTypes]=N'SOS_SCHEDULER_YIELD,THREADPOOL,CXPACKET,CXCONSUMER,CMEMTHREAD,LCK_M_*',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'CPU_SCHEDULER';

/* Parallelismus. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'Parallelism-Waits entstehen bei Austausch und Synchronisation paralleler Zweige. CXCONSUMER ist häufig erwartete Konsumentenwartezeit; CXPACKET wird erst mit Skew, langer Requestdauer, hoher CPU oder einem ungeeigneten Plan handlungsrelevant.',
    [CommonCauses]=N'Unterschiedliche Arbeit je Thread, falsche Kardinalität, Scans, Spills, Blocking eines Zweigs, ungeeigneter DOP, sehr viele kleine parallele Abfragen oder ein langsamer serieller Bereich.',
    [PerformanceImpact]=N'Unausgeglichene Zweige verlängern die Gesamtdauer und können CPU sowie Worker überproportional binden. Reine Synchronisationszeit ist nicht gleich verlorene CPU-Zeit.',
    [Mitigation]=N'Aktuellen oder tatsächlichen Plan, Thread-/Operator-WaitStats, Zeilenverteilung, Spills, CPU und Worker prüfen. Query und Schätzungen zuerst verbessern; MAXDOP und Cost Threshold anschließend gegen repräsentative Last testen, nicht pauschal Parallelität deaktivieren.',
    [CounterEvidence]=N'CXCONSUMER ohne lange Requestdauer oder CPU-/Skew-Symptom ist regelmäßig erwartbar. Ein hoher instanzweweiter Anteil kann schlicht den Parallelitätsgrad der normalen Workload spiegeln.',
    [RelatedWaitTypes]=N'CXPACKET,CXCONSUMER,CXROWSET_SYNC,EXCHANGE,THREADPOOL,SOS_SCHEDULER_YIELD',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'PARALLELISM';

/* Client- und Netzwerkabnahme. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'ASYNC_NETWORK_IO bedeutet primär, dass SQL Server fertige Ergebnisdaten nicht schnell genug an den Client abgeben kann. Der Name beweist kein physisches Netzwerkproblem.',
    [CommonCauses]=N'Große Resultsets, langsames oder pausiertes Client-Fetching, Row-by-row-Verarbeitung, Client-CPU-/Memory-/I/O-Druck, Netzwerkverlust oder eine Anwendung, die Ergebnisse nicht vollständig konsumiert.',
    [PerformanceImpact]=N'Die Requestdauer steigt und Worker sowie bereits gehaltene Locks können länger gebunden bleiben; dadurch kann sekundäres Blocking entstehen.',
    [Mitigation]=N'Resultset serverseitig begrenzen und nur benötigte Spalten/Zeilen senden, Client asynchron beziehungsweise zügig lesen lassen, Applikationsressourcen und Fetchmuster messen und erst danach Netzwerk-Trace auf Retransmits oder Resets prüfen.',
    [CounterEvidence]=N'Normale Client-Fetchrate, kleine Resultsets und nachgewiesene Retransmits lenken zur Netzwerkschicht; ohne Paketbefund ist die Anwendung wahrscheinlicher als das Netzwerk.',
    [RelatedWaitTypes]=N'ASYNC_NETWORK_IO,NET_WAITFOR_PACKET,LCK_M_*',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup] IN (N'NETWORK_CLIENT',N'NETWORK_PROTOCOL');

/* HA, Mirroring und Replikapipeline. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'HA-Waits umfassen Idle-Queues, interne Synchronisation und echte Send-, Flow-Control-, Redo- oder synchrone Commitlatenz. Der konkrete Wait und die Replikarolle entscheiden; die Summe über die Wait Group ist nicht als einzelner Engpass zu lesen.',
    [CommonCauses]=N'Erwartete Worker-/Timerleere, lokale Log-Flushlatenz, Netzwerk-RTT oder Durchsatz, Flow Control, große Logerzeugung, Log-Send-Queue, langsames Harden/Redo auf Secondary, Rollenwechsel oder ausgesetzter Datentransport.',
    [PerformanceImpact]=N'Je Stufe steigen Commitlatenz, RPO-/RTO-Risiko, Send-/Redo-Queue und Synchronisationsdauer. Idle-Waits besitzen dagegen keine negative Benutzerwirkung.',
    [Mitigation]=N'Replikarolle und Synchronisationsmodus feststellen; sys.dm_hadr_database_replica_states, log_send_queue_size, redo_queue_size, send/redo rate, last_commit_time, lokale WRITELOG-Latenz und Netzwerk-RTT zeitgleich messen. Die tatsächlich limitierende Pipeline-Stufe beheben.',
    [CounterEvidence]=N'HADR_WORK_QUEUE, HADR_TIMER_TASK und vergleichbare Idle-Waits sind bei gesunden Replikas erwartbar. SYNCHRONIZED allein beweist umgekehrt keine niedrige Commitlatenz.',
    [RelatedWaitTypes]=N'HADR_SYNC_COMMIT,HADR_DATABASE_FLOW_CONTROL,HADR_TRANSPORT_FLOW_CONTROL,HADR_LOGCAPTURE_WAIT,WRITELOG,DBMIRROR_SEND',
    [AnalysisConfidence]='PRIMARY_AND_SPECIALIST'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'HA_REPLICATION';

/* Komponentengruppen: Erst Komponentenzustand und Fortschritt nachweisen. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'Der Wait gehört zu einer optionalen SQL-Server-Komponente. Idle- und Koordinationswaits können normal sein; relevant wird er erst bei gleichzeitigem Funktionsfehler, Rückstau oder fehlendem Fortschritt dieser Komponente.',
    [CommonCauses]=CONCAT([TypicalOccurrence],N' Zusätzlich kommen Komponentenstart/-stopp, interne Synchronisation, Rückstau, externe Abhängigkeiten und eingeschränkte Ressourcen infrage.'),
    [PerformanceImpact]=N'Mögliche Wirkung ist zunächst auf die zugehörige Komponente begrenzt. Eine Instanzwirkung entsteht erst durch Worker-, CPU-, Memory-, I/O- oder Blocking-Folgen.',
    [Mitigation]=N'Featurezustand, Queue beziehungsweise Backlog, Fortschrittszähler, Fehlerprotokoll und abhängige Infrastruktur prüfen. Erst die bestätigte Komponentenursache beheben; Idle-Worker und Timer nicht deaktivieren.',
    [CounterEvidence]=N'Kein Rückstau, normaler Fortschritt und keine betroffenen Benutzeroperationen sprechen für erwartete interne Koordination.',
    [AnalysisConfidence]=CASE WHEN [Meaning] LIKE N'%not supported%' OR [Meaning] LIKE N'%nicht unterstützt%' THEN 'INTERNAL_LIMITED' ELSE 'FAMILY_RESEARCHED' END
WHERE [IsFrameworkDefault]=1
  AND [WaitGroup] IN
      (N'SERVICE_BROKER',N'FULLTEXT',N'CLR',N'SQLCLR',N'FILESTREAM',
       N'TRACING_XEVENTS',N'QUERY_NOTIFICATIONS',N'AUDIT_SECURITY',N'REPLICATION',
       N'COLUMNSTORE',N'RESOURCE_GOVERNOR');

/* Lebenszyklus, DTC, TempDB und interne Engine-Waits. */
UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'Diese Waits gehören zu Zustandswechseln, Recovery, Shutdown oder Datenbankinitialisierung. Sie sind außerhalb eines passenden Betriebsereignisses auffällig; während des erwarteten Ereignisses zählt primär der Fortschritt.',
    [CommonCauses]=N'Datenbankstart/-stopp, Recovery, Versionszustandswechsel, Failover, exklusiver Metadatenzugriff oder wartende interne Aufräumarbeiten.',
    [PerformanceImpact]=N'Die betroffene Datenbank oder Funktion bleibt länger in einem Übergangszustand und kann eingeschränkt oder nicht verfügbar sein.',
    [Mitigation]=N'Aktuelle Datenbankzustände, Recovery-Fortschritt, Errorlog, I/O, Blocking und das auslösende Betriebsereignis korrelieren. Keinen Zustandswechsel abbrechen, bevor Fortschritt und Rückfallweg bewertet sind.',
    [CounterEvidence]=N'Kurze Waits unmittelbar bei geplantem Start, Stop, Restore oder Failover mit erkennbarem Fortschritt sind erwartbar.',
    [RelatedWaitTypes]=N'RECOVER_CHANGEDB,CLEAR_DB,SHUTDOWN,ASYNC_IO_COMPLETION,IO_COMPLETION',
    [AnalysisConfidence]='FAMILY_RESEARCHED'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'DATABASE_LIFECYCLE';

UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'DTC- und Transaktionskoordinationswaits zeigen Ownership-, Enlistment-, Prepare-, Commit-, Rollback- oder Recovery-Synchronisation. Sie erfordern den Status der verteilten Transaktion und von MSDTC; ein lokaler Queryplan allein reicht nicht.',
    [CommonCauses]=N'Lang laufende verteilte Transaktionen, nicht erreichbarer MSDTC, Netzwerk-/Firewall-/Namensauflösungsprobleme, in-doubt Recovery, konkurrierende Batches auf derselben Transaktion oder langsames Commit/Rollback.',
    [PerformanceImpact]=N'Commit oder Recovery bleibt ausstehend; Locks und Log können gehalten werden und nachgelagerte Sessions blockieren.',
    [Mitigation]=N'Transaktions-UOW, sys.dm_tran_*, MSDTC-Dienst und -Logs, Netzwerkpfad, Partnerstatus und Head Blocker prüfen. Verteilte Transaktionsgrenzen verkürzen und Fehlerbehandlung idempotent gestalten; in-doubt Entscheidungen nur nach Recovery-Runbook.',
    [CounterEvidence]=N'Kurze Prepare-/Commit-Synchronisation ohne offene oder in-doubt Transaktion ist normal. Alte kumulative DTC-Werte belegen keinen aktuellen MSDTC-Ausfall.',
    [RelatedWaitTypes]=N'DTC*,KTM_*,TRANSACTION_MUTEX,XACT*,LCK_M_*',
    [AnalysisConfidence]='FAMILY_RESEARCHED'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'DISTRIBUTED_TRANSACTION';

UPDATE [monitor].[WaitTypeCatalog]
SET [AssessmentBasis]=N'Tempobjekt-Waits betreffen Anlage, Nutzung oder verzögertes Löschen interner beziehungsweise expliziter temporärer Objekte. Sie sind von PAGELATCH-TempDB-Allokationscontention und von Spill-I/O zu trennen.',
    [CommonCauses]=N'Hohe Frequenz temporärer Objekte, noch referenzierte Tempobjekte, parallele Nutzung, verzögerter Drop, Plan-/Worktable-Spills oder interner Cleanup.',
    [PerformanceImpact]=N'Compile-/Ausführungsende, Tempobjektwiederverwendung oder Cleanup kann verzögert werden; bei hoher Frequenz steigt TempDB- und Metadatenlast.',
    [Mitigation]=N'Objektlebensdauer, TempDB-Space, Task Space Usage, Spill-Warnungen, Erstell-/Droprate und betroffene Pläne prüfen. Tempobjektmuster und Queries optimieren; Memory-Optimized TempDB Metadata nur nach versions- und workloadbezogenem Test bewerten.',
    [CounterEvidence]=N'Keine TempDB-Kapazitäts-, Latch-, Spill- oder Metadatenprobleme und nur seltene Drops sprechen gegen einen relevanten Engpass.',
    [RelatedWaitTypes]=N'TEMPOBJ,DROPTEMP,WORKTBL_DROP,PAGELATCH_*,IO_COMPLETION',
    [AnalysisConfidence]='FAMILY_RESEARCHED'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup]=N'TEMPDB_OBJECTS';

UPDATE [monitor].[WaitTypeCatalog]
SET [DefaultAssessment]='INTERNAL_CONTEXT_ONLY',
    [AssessmentBasis]=N'Microsoft kennzeichnet diesen Wait als intern, informationsbezogen oder nur eingeschränkt unterstützt. Der Name darf nicht in eine konkrete Root Cause oder Konfigurationsänderung übersetzt werden.',
    [CommonCauses]=N'Interne Engine-Synchronisation, Initialisierung, Test-/Failpointpfad oder nicht öffentlich stabil dokumentierter Implementierungszustand.',
    [PerformanceImpact]=N'Ohne aktive betroffene Requests, reproduzierbares Delta und zusätzliche Engine-Evidenz ist keine belastbare Performancewirkung ableitbar.',
    [Mitigation]=N'Build und bekannte Fixes prüfen, aktive Tasks und Nachbarwaits erfassen und bei reproduzierbarer hoher Wirkung einen Microsoft-Supportfall mit PSSDiag/SQL LogScout erwägen. Keine undokumentierten Trace Flags oder Serveroptionen ableiten.',
    [CounterEvidence]=N'Nur kumulatives Auftreten, keine aktiven Tasks und kein korrelierter SLA-Effekt sprechen gegen Handlungsbedarf.',
    [RelatedWaitTypes]=NULL,
    [AnalysisConfidence]='INTERNAL_LIMITED'
WHERE [IsFrameworkDefault]=1 AND [WaitGroup] IN (N'ENGINE_INTERNAL',N'DIAGNOSTICS_INTERNAL');

/* Exakte, häufig handlungsrelevante Gegenbeispiele und Abgrenzungen. */
UPDATE [monitor].[WaitTypeCatalog]
SET [DefaultAssessment]='CRITICAL_WHEN_CONFIRMED',
    [AssessmentBasis]=N'THREADPOOL bedeutet, dass kein freier Worker für neue Arbeit verfügbar war. Schon ein kleines Delta kann kritisch sein, wenn Login, Monitoring oder interne Tasks nicht starten.',
    [Mitigation]=N'Zuerst lange Blocking-Ketten, sehr hohe Connection-/Request-Concurrency und parallele Worker je Request reduzieren. max worker threads nur nach Scheduler-/NUMA- und Stack-Memory-Prüfung ändern.',
    [CounterEvidence]=N'Ohne aktuelles Workerdefizit kann ein alter kumulativer THREADPOOL-Wert von einem vergangenen Lastspike stammen.',
    [AnalysisConfidence]='EXACT_PRIMARY_GUIDANCE'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'THREADPOOL';

UPDATE [monitor].[WaitTypeCatalog]
SET [DefaultAssessment]='EXPECTED_COMPANION',
    [AssessmentBasis]=N'CXCONSUMER ist der erwartete Konsumentenanteil paralleler Exchange-Synchronisation. Nicht isoliert als Fehlkonfiguration oder CPU-Problem bewerten.',
    [CounterEvidence]=N'Kurze parallele Requests mit gleichmäßiger Arbeit und ohne CPU-/Worker-Sättigung sind ein klarer Gegenbeweis gegen Handlungsbedarf.',
    [AnalysisConfidence]='EXACT_PRIMARY_GUIDANCE'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'CXCONSUMER';

UPDATE [monitor].[WaitTypeCatalog]
SET [DefaultAssessment]='ACTIONABLE_WHEN_ACTIVE',
    [AssessmentBasis]=N'HADR_SYNC_COMMIT entsteht auf der Primary, während ein synchrones Commit auf Harden-Bestätigung der synchronen Secondary wartet. Lokal WRITELOG, Transport und Remote-Harden getrennt messen.',
    [CounterEvidence]=N'Asynchroner Commitmodus oder fehlende aktive synchrone Commitrequests widerlegen HADR_SYNC_COMMIT als aktuelle Ursache; alte Werte können vor einem Rollenwechsel entstanden sein.',
    [AnalysisConfidence]='EXACT_PRIMARY_GUIDANCE'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'HADR_SYNC_COMMIT';

UPDATE [monitor].[WaitTypeCatalog]
SET [DefaultAssessment]='ACTIONABLE_WHEN_ACTIVE',
    [AssessmentBasis]=N'LCK_M_SCH_M wartet auf einen inkompatiblen Schema-Modification-Lock. Typische Besitzer sind DDL, Indexoperationen oder Metadatenänderungen; auch normale Queries benötigen Sch-S und können dadurch breit blockiert werden.',
    [Mitigation]=N'DDL-/Deployment- oder Indexoperation am Head Blocker identifizieren, Wartungsfenster und Onlinefähigkeit prüfen und Transaktionsumfang minimieren. Sch-M nicht durch NOLOCK zu umgehen versuchen.',
    [AnalysisConfidence]='EXACT_PRIMARY_GUIDANCE'
WHERE [IsFrameworkDefault]=1 AND [WaitType]=N'LCK_M_SCH_M';
GO
