USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.VW_AnalysisRelation
Version      : 1.1.0
Stand        : 2026-07-23
Typ          : View
Zweck        : Beschreibt fachlich begründete Übergänge zwischen öffentlichen
               Analyse-Procedures für priorisierte nächste Schritte.
Semantik     : REFINE_WITH vertieft ein vorhandenes Signal, CONFIRM_WITH liefert
               eine unabhängige Gegenprobe, ALTERNATIVE_TO nutzt einen anderen
               Evidenzpfad und PREPARE_WITH stellt eine Voraussetzung her.
               RelationPriority gilt je Ausgangs-Procedure und Relationstyp.
Eigenlast    : Konstante Frameworkmetadaten; keine fachlichen Datenzugriffe.
===============================================================================
*/
CREATE OR ALTER VIEW [monitor].[VW_AnalysisRelation]
AS
    SELECT
          CONVERT(sysname, [v].[FromProcedureName]) AS [FromProcedureName]
        , CONVERT(varchar(24), [v].[RelationType]) AS [RelationType]
        , CONVERT(sysname, [v].[ToProcedureName]) AS [ToProcedureName]
        , CONVERT(tinyint, [v].[RelationPriority]) AS [RelationPriority]
        , CONVERT(nvarchar(700), [v].[ConditionSummary]) AS [ConditionSummary]
    FROM
    (
        VALUES
          (N'USP_CheckAnalyseAccess','CONFIRM_WITH',N'USP_CheckFrameworkCapabilities',1,N'Wenn eine Analyseklasse nicht freigegeben ist, zusätzlich Version, Berechtigungen, Featurefähigkeit und Policygrenze prüfen.')
        , (N'USP_CheckFrameworkCapabilities','CONFIRM_WITH',N'USP_CheckAnalyseAccess',1,N'Bei einer Policy- oder Gruppenabweichung den effektiven Sicherheitskontext und die Analyseklasse separat prüfen.')

        , (N'USP_CurrentSessions','REFINE_WITH',N'USP_CurrentRequests',1,N'Aktive oder auffällige Sessions auf laufende Requests, Waits und Ressourcenverbrauch eingrenzen.')
        , (N'USP_CurrentSessions','CONFIRM_WITH',N'USP_CurrentTransactions',1,N'Offene Transaktionen unabhängig vom aktuellen Requestzustand gegenprüfen.')
        , (N'USP_CurrentRequests','REFINE_WITH',N'USP_CurrentBlocking',1,N'Bei blockierten Requests die vollständige Blocking-Kette und den Head Blocker bestimmen.')
        , (N'USP_CurrentRequests','REFINE_WITH',N'USP_CurrentMemoryGrants',2,N'Bei Grant-Waits, großen Grants oder Spillverdacht die Memory-Grant-Sicht vertiefen.')
        , (N'USP_CurrentRequests','CONFIRM_WITH',N'USP_QueryStats',1,N'Ein Live-Signal gegen kumulierte Query- und Plan-Cache-Evidenz abgleichen.')
        , (N'USP_CurrentBlocking','REFINE_WITH',N'USP_CurrentTransactions',1,N'Head Blocker und offene Transaktionen samt Alter und Logbezug untersuchen.')
        , (N'USP_CurrentBlocking','CONFIRM_WITH',N'USP_ExtendedEventsBlockedProcesses',1,N'Für wiederkehrendes oder vergangenes Blocking eine zeitliche XE-Evidenz gegenprüfen.')
        , (N'USP_CurrentWaits','REFINE_WITH',N'USP_CurrentRequests',1,N'Instanzweite Wait-Signale auf aktuell verursachende Requests eingrenzen.')
        , (N'USP_CurrentWaits','CONFIRM_WITH',N'USP_PerformanceCounters',1,N'Waitverteilung mit begrenzten Performance-Counter-Deltas gegenprüfen.')
        , (N'USP_CurrentTransactions','REFINE_WITH',N'USP_CurrentBlocking',1,N'Bei wartenden oder lange offenen Transaktionen die Blocking-Beziehung bestimmen.')
        , (N'USP_CurrentTransactions','CONFIRM_WITH',N'USP_CurrentLog',1,N'Alter und Logverbrauch der Transaktionen mit dem aktuellen Logzustand abgleichen.')
        , (N'USP_CurrentMemoryGrants','REFINE_WITH',N'USP_ShowplanAnalysis',1,N'Bei bekanntem Plan Spill-, Sort-, Join- und Grantursachen im Showplan vertiefen.')
        , (N'USP_CurrentMemoryGrants','CONFIRM_WITH',N'USP_ServerMemory',1,N'Aktuelle Grants gegen Server-Memory-Konfiguration und Pressure-Evidenz prüfen.')
        , (N'USP_CurrentTempDB','REFINE_WITH',N'USP_CurrentRequests',1,N'Session- oder Taskverbrauch auf den verursachenden aktuellen Request zurückführen.')
        , (N'USP_CurrentTempDB','CONFIRM_WITH',N'USP_TempDBConfiguration',1,N'Aktuellen Verbrauch unabhängig gegen Dateilayout, Wachstum und Konfiguration prüfen.')
        , (N'USP_CurrentIO','REFINE_WITH',N'USP_CurrentRequests',1,N'Aktuelle I/O-Wartezeit mit den gegenwärtig laufenden Requests korrelieren.')
        , (N'USP_CurrentIO','CONFIRM_WITH',N'USP_PerformanceCounters',1,N'Datei- und Volume-Sicht mit einem kurzen Counter-Delta gegenprüfen.')
        , (N'USP_CurrentLog','REFINE_WITH',N'USP_CurrentTransactions',1,N'Log-Reuse-Blocker und aktive Transaktionen gemeinsam untersuchen.')
        , (N'USP_CurrentLog','CONFIRM_WITH',N'USP_BackupRecovery',1,N'Logzustand mit Recovery-Modell, Logbackup-Frische und Backupkette abgleichen.')
        , (N'USP_CurrentOverview','REFINE_WITH',N'USP_CurrentRequests',1,N'Auffällige aktive Requests aus der Übersicht gezielt vertiefen.')
        , (N'USP_CurrentOverview','REFINE_WITH',N'USP_CurrentBlocking',2,N'Bei Warteschlangen oder Blockern die Blocking-Kette separat ausgeben.')
        , (N'USP_CurrentOverview','CONFIRM_WITH',N'USP_DiagnosticFindings',1,N'Live-Snapshot durch priorisierte Betriebs-, Kapazitäts- und Konfigurationsbefunde ergänzen.')

        , (N'USP_ObjectInventory','REFINE_WITH',N'USP_ObjectAnalysis',1,N'Auffällige Objektgrößen oder Strukturen im konsolidierten Objektpfad vertiefen.')
        , (N'USP_IndexUsage','REFINE_WITH',N'USP_IndexOperationalStats',1,N'Bei auffälliger Nutzung die operative Indexbelastung und Latch-/Lockaktivität ergänzen.')
        , (N'USP_IndexUsage','CONFIRM_WITH',N'USP_QueryStats',1,N'Indexnutzung mit der tatsächlichen Query- und Plannutzung gegenprüfen.')
        , (N'USP_IndexOperationalStats','CONFIRM_WITH',N'USP_IndexPhysicalStats',1,N'Operative Belastung unabhängig von physischer Fragmentierung und Seitendichte prüfen.')
        , (N'USP_MissingIndexes','CONFIRM_WITH',N'USP_IndexUsage',1,N'Fehlindexhinweise gegen bestehende Indizes und deren reale Nutzung validieren.')
        , (N'USP_MissingIndexes','REFINE_WITH',N'USP_QueryStats',1,N'Kandidaten auf konkrete teure Query- und Planmuster zurückführen.')
        , (N'USP_Statistics','REFINE_WITH',N'USP_StatisticsDistributionAnalysis',1,N'Bei Skew- oder Kardinalitätsverdacht ausgewählte Histogramme gezielt untersuchen.')
        , (N'USP_Statistics','CONFIRM_WITH',N'USP_ShowplanAnalysis',1,N'Statistikstatus mit Estimate-/Actual-Abweichungen eines bekannten Plans abgleichen.')
        , (N'USP_StatisticsDistributionAnalysis','CONFIRM_WITH',N'USP_ShowplanAnalysis',1,N'Histogrammverteilung gegen die im Plan sichtbare Kardinalitätsschätzung prüfen.')
        , (N'USP_Partitions','CONFIRM_WITH',N'USP_IndexPhysicalStats',1,N'Partitionsgrößen und -grenzen mit physischem Indexzustand je Partition abgleichen.')
        , (N'USP_Columnstore','CONFIRM_WITH',N'USP_IndexOperationalStats',1,N'Rowgroupzustand mit operativer Änderungs- und Leseaktivität gegenprüfen.')
        , (N'USP_IndexPhysicalStats','CONFIRM_WITH',N'USP_IndexUsage',1,N'Physische Auffälligkeiten nur zusammen mit Nutzung und Workloadrelevanz bewerten.')
        , (N'USP_ObjectAnalysis','REFINE_WITH',N'USP_IndexUsage',1,N'Indexbezogene Signale auf Nutzung und Änderungsaktivität eingrenzen.')
        , (N'USP_ObjectAnalysis','REFINE_WITH',N'USP_Statistics',2,N'Statistiksignale auf Alter, Modifikationen und ausgewählte Objekte vertiefen.')
        , (N'USP_ObjectAnalysis','REFINE_WITH',N'USP_VectorIndexAnalysis',3,N'Bei SQL-Server-2025-Vector-Indizes den aktuellen Katalog- und Wartungszustand gezielt ergänzen.')
        , (N'USP_ObjectAnalysis','CONFIRM_WITH',N'USP_QueryStats',1,N'Objektbefunde gegen Query- und Plannutzung validieren.')
        , (N'USP_SchemaDesignAnalysis','CONFIRM_WITH',N'USP_ObjectAnalysis',1,N'Schemadesignhinweise mit Objektgröße, Nutzung, Indizes und Statistiken abgleichen.')

        , (N'USP_QueryStats','REFINE_WITH',N'USP_PlanDetails',1,N'Auffällige Query- oder Planhandles auf Details und begrenztes Plan-XML eingrenzen.')
        , (N'USP_QueryStats','CONFIRM_WITH',N'USP_QueryStoreRuntimeStats',1,N'Cache-Evidenz bei aktivem Query Store gegen ein explizites Zeitfenster prüfen.')
        , (N'USP_QueryHashAnalysis','REFINE_WITH',N'USP_PlanDetails',1,N'Abweichende Varianten eines Query Hash auf konkrete Planhandles und Planmerkmale zurückführen.')
        , (N'USP_QueryHashAnalysis','CONFIRM_WITH',N'USP_QueryStorePlanChanges',1,N'Cachevarianten gegen persistierte Planwechsel im gewählten Zeitraum prüfen.')
        , (N'USP_PlanCacheHealth','REFINE_WITH',N'USP_PlanCacheAnalysis',1,N'Bei Cache-Druck oder Ad-hoc-Bloat die planbezogene Detailanalyse ausführen.')
        , (N'USP_PlanCacheHealth','CONFIRM_WITH',N'USP_ServerMemory',1,N'Plan-Cache-Zustand im gesamten Server-Memory-Kontext bewerten.')
        , (N'USP_PlanDetails','REFINE_WITH',N'USP_ShowplanAnalysis',1,N'Ein bekanntes Plan-XML auf Operatoren, Estimates, Warnungen und Parallelität vertiefen.')
        , (N'USP_ShowplanAnalysis','CONFIRM_WITH',N'USP_QueryStoreRuntimeStats',1,N'Planbefunde bei aktivem Query Store gegen reale Laufzeitintervalle abgleichen.')
        , (N'USP_PlanCacheAnalysis','REFINE_WITH',N'USP_ShowplanAnalysis',1,N'Auffällige Cachepläne als begrenztes Plan-XML fachlich vertiefen.')
        , (N'USP_PlanCacheAnalysis','CONFIRM_WITH',N'USP_QueryStoreAnalysis',1,N'Flüchtige Cache-Evidenz gegen persistierte Query-Store-Evidenz prüfen.')
        , (N'USP_CreateExecutionEvidenceJson','REFINE_WITH',N'USP_ExecutionPlanAnalysis',1,N'Das erzeugte Evidenzartefakt zusammen mit der vollständigen Plananalyse interpretieren.')
        , (N'USP_ExecutionPlanAnalysis','CONFIRM_WITH',N'USP_QueryStoreRuntimeStats',1,N'Planstruktur bei verfügbarem Query Store gegen gemessene Laufzeitintervalle prüfen.')
        , (N'USP_ExecutionPlanAnalysis','ALTERNATIVE_TO',N'USP_ShowplanAnalysis',1,N'Für einen bereits in SQL Server verfügbaren Planhandle kann der integrierte Showplanpfad geeigneter sein.')

        , (N'USP_QueryStoreStatus','REFINE_WITH',N'USP_QueryStoreAnalysis',1,N'Bei verfügbarem und lesbarem Query Store die konsolidierte Analyse ausführen.')
        , (N'USP_QueryStoreRuntimeStats','CONFIRM_WITH',N'USP_QueryStoreWaitStats',1,N'Laufzeitabweichungen mit den zugehörigen Query-Store-Waitkategorien gegenprüfen.')
        , (N'USP_QueryStoreWaitStats','CONFIRM_WITH',N'USP_QueryStoreRuntimeStats',1,N'Waitverschiebungen nur zusammen mit Ausführungszahl, Dauer, CPU und Reads bewerten.')
        , (N'USP_QueryStorePlanChanges','REFINE_WITH',N'USP_ExecutionPlanAnalysis',1,N'Relevante alte und neue Plan-XMLs einzeln strukturell analysieren.')
        , (N'USP_QueryStorePlanChanges','CONFIRM_WITH',N'USP_QueryStoreRuntimeStats',1,N'Planwechsel gegen die gemessene Laufzeitwirkung im gleichen Zeitfenster prüfen.')
        , (N'USP_QueryStoreRegressions','REFINE_WITH',N'USP_QueryStorePlanChanges',1,N'Regressionen auf Planwechsel und konkrete Plan-IDs zurückführen.')
        , (N'USP_QueryStoreRegressions','CONFIRM_WITH',N'USP_QueryStoreWaitStats',1,N'Regressionssignale mit veränderten Waitkategorien gegenprüfen.')
        , (N'USP_QueryStoreForcedPlans','CONFIRM_WITH',N'USP_QueryStoreRuntimeStats',1,N'Erzwungene Pläne anhand ihrer tatsächlichen Laufzeitwirkung bewerten.')
        , (N'USP_QueryStoreHints','CONFIRM_WITH',N'USP_QueryStoreRuntimeStats',1,N'Query-Store-Hints gegen Ausführungszahl und Laufzeitentwicklung validieren.')
        , (N'USP_QueryStoreAnalysis','REFINE_WITH',N'USP_QueryStoreRegressions',1,N'Bei Performanceabweichungen den spezialisierten Regressionspfad nutzen.')
        , (N'USP_QueryStoreAnalysis','REFINE_WITH',N'USP_QueryStorePlanChanges',2,N'Bei Varianten oder Wechseln die Planhistorie gezielt untersuchen.')
        , (N'USP_IntelligentQueryProcessingAnalysis','CONFIRM_WITH',N'USP_ExecutionPlanAnalysis',1,N'IQP-Nutzung und Kandidaten anhand eines konkreten Ausführungsplans verifizieren.')

        , (N'USP_ExtendedEventsSessions','REFINE_WITH',N'USP_ExtendedEventsTargetRuntime',1,N'Aktive Sessions auf Targetzustand, Drops, Latenz und Dateipfade vertiefen.')
        , (N'USP_ExtendedEventsReadEvents','CONFIRM_WITH',N'USP_ExtendedEventsTargetRuntime',1,N'Fehlende oder unvollständige Ereignisse gegen Targetzustand und Drops prüfen.')
        , (N'USP_ExtendedEventsDeadlocks','CONFIRM_WITH',N'USP_CurrentBlocking',1,N'Historische Deadlocks bei aktuell reproduzierbarer Situation gegen den Live-Zustand prüfen.')
        , (N'USP_ExtendedEventsDeadlocks','ALTERNATIVE_TO',N'USP_ExtendedEventsReadEvents',1,N'Für andere Eventtypen oder eine bereits bekannte Session den generischen Lesepfad verwenden.')
        , (N'USP_ExtendedEventsBlockedProcesses','CONFIRM_WITH',N'USP_CurrentBlocking',1,N'Historische Blocked-Process-Ereignisse gegen eine aktuelle Blocking-Kette prüfen.')
        , (N'USP_ExtendedEventsTargetRuntime','REFINE_WITH',N'USP_ExtendedEventsReadEvents',1,N'Bei gesundem Target die begrenzten Ereignisse der ausgewählten Session lesen.')
        , (N'USP_ExtendedEventsAnalysis','REFINE_WITH',N'USP_ExtendedEventsSessions',1,N'Sessionkonfiguration und Zustand für auffällige XE-Befunde separat prüfen.')
        , (N'USP_ExtendedEventsAnalysis','REFINE_WITH',N'USP_ExtendedEventsDeadlocks',2,N'Bei Deadlocksignalen den spezialisierten Deadlockpfad verwenden.')

        , (N'USP_AgentStatus','REFINE_WITH',N'USP_AgentMonitoringAnalysis',1,N'Bei auffälligem Agentzustand Jobs, Verlauf, Dauer und Betriebsrisiken vertiefen.')
        , (N'USP_AgentJobs','REFINE_WITH',N'USP_AgentMonitoringAnalysis',1,N'Fehlerhafte, überfällige oder lang laufende Jobs im erweiterten Agentpfad untersuchen.')
        , (N'USP_ResourceGovernorAnalysis','CONFIRM_WITH',N'USP_CurrentRequests',1,N'Pool- oder Workload-Group-Signale mit aktuell laufenden Requests abgleichen.')
        , (N'USP_AvailabilityGroups','REFINE_WITH',N'USP_AvailabilityDeepAnalysis',1,N'Bei Queue, Synchronisation oder Healthsignalen die Replikazustände vertiefen.')
        , (N'USP_BackupRecovery','REFINE_WITH',N'USP_BackupChainAnalysis',1,N'Bei Lücken- oder Restoreverdacht die vollständige Backupkette gezielt analysieren.')
        , (N'USP_BackupRecovery','CONFIRM_WITH',N'USP_DatabaseIntegrityAnalysis',1,N'Wiederherstellbarkeit nicht nur über Backuphistorie, sondern auch über Integritätsevidenz bewerten.')
        , (N'USP_LogShippingStatus','CONFIRM_WITH',N'USP_BackupRecovery',1,N'Log-Shipping-Latenz gegen Logbackup-Frische und Recovery-Modell prüfen.')
        , (N'USP_ReplicationStatus','REFINE_WITH',N'USP_DataCaptureDeepAnalysis',1,N'Bei CDC-, CT- oder lokal sichtbaren Replikationssignalen den Data-Capture-Pfad vertiefen.')
        , (N'USP_DataCaptureStatus','REFINE_WITH',N'USP_DataCaptureDeepAnalysis',1,N'Erkannte CDC- oder Change-Tracking-Nutzung samt Retention und Latenz vertiefen.')
        , (N'USP_InfrastructureAnalysis','REFINE_WITH',N'USP_AvailabilityDeepAnalysis',1,N'HA/DR-Signale auf Replika-, Queue- und Synchronisationsdetails eingrenzen.')
        , (N'USP_InfrastructureAnalysis','REFINE_WITH',N'USP_AgentMonitoringAnalysis',2,N'Agent- oder Jobbefunde im spezialisierten Monitoringpfad untersuchen.')
        , (N'USP_InfrastructureAnalysis','CONFIRM_WITH',N'USP_BackupRecovery',1,N'Infrastrukturbefunde mit Backup- und Recovery-Evidenz gegenprüfen.')
        , (N'USP_BackupChainAnalysis','CONFIRM_WITH',N'USP_DatabaseIntegrityAnalysis',1,N'Eine formal lückenlose Kette durch Integritäts- und Restoretests ergänzen.')
        , (N'USP_AvailabilityDeepAnalysis','CONFIRM_WITH',N'USP_CurrentLog',1,N'Queue- und Sendesignale mit Logzustand und Reuse-Wait abgleichen.')
        , (N'USP_AgentMonitoringAnalysis','CONFIRM_WITH',N'USP_ErrorLogAnalysis',1,N'Agentfehler und Laufzeitabweichungen mit Engine- und Agent-Logsignalen abgleichen.')
        , (N'USP_MaintenanceOperations','CONFIRM_WITH',N'USP_AgentMonitoringAnalysis',1,N'Wartungsaktivität und Jobausführung gemeinsam bewerten.')
        , (N'USP_ErrorLogAnalysis','CONFIRM_WITH',N'USP_CriticalEngineEvents',1,N'Logmuster mit strukturierten kritischen Engine-Ereignissen gegenprüfen.')

        , (N'USP_ServerCpuTopology','REFINE_WITH',N'USP_ServerNuma',1,N'CPU-, Socket- und Schedulerhinweise auf NUMA- und Memory-Node-Zuordnung vertiefen.')
        , (N'USP_ServerCpuTopology','CONFIRM_WITH',N'USP_WorkerPressureAnalysis',1,N'Topologiehinweise gegen aktuelle Runnable- und Worker-Evidenz prüfen.')
        , (N'USP_ServerNuma','CONFIRM_WITH',N'USP_ServerMemory',1,N'NUMA-Verteilung zusammen mit Server- und Node-Memoryzustand bewerten.')
        , (N'USP_ServerMemory','REFINE_WITH',N'USP_BufferPoolAnalysis',1,N'Bei Pressure oder ungewöhnlicher Verteilung Clerks und Buffer Pool vertiefen.')
        , (N'USP_ServerMemory','CONFIRM_WITH',N'USP_CurrentMemoryGrants',1,N'Serverweiten Zustand gegen aktive und wartende Query Memory Grants prüfen.')
        , (N'USP_TempDBConfiguration','CONFIRM_WITH',N'USP_CurrentTempDB',1,N'Dateilayout und Wachstum mit aktuellem Session-, Task- und Versionsspeicherverbrauch abgleichen.')
        , (N'USP_ServerConfiguration','CONFIRM_WITH',N'USP_DatabaseConfigurationAnalysis',1,N'Instanzoptionen durch Datenbankoptionen und Driftkontext ergänzen.')
        , (N'USP_TraceFlags','CONFIRM_WITH',N'USP_StartupParameters',1,N'Aktive Trace Flags gegen persistente Startparameter und Servicekonfiguration prüfen.')
        , (N'USP_StartupParameters','CONFIRM_WITH',N'USP_TraceFlags',1,N'Startkonfiguration gegen zur Laufzeit aktive globale und Session-Trace-Flags abgleichen.')
        , (N'USP_OSInformation','CONFIRM_WITH',N'USP_ServerCpuTopology',1,N'Betriebssystem-, Virtualisierungs- und Hosthinweise mit SQL-CPU-Topologie abgleichen.')
        , (N'USP_ServerSecurityConfiguration','CONFIRM_WITH',N'USP_EncryptionAnalysis',1,N'Instanznahe Sicherheitskonfiguration durch Datenbank- und Backupverschlüsselungsstatus ergänzen.')
        , (N'USP_ServerHealthAnalysis','REFINE_WITH',N'USP_ServerMemory',1,N'Memorysignale im spezialisierten Server-Memory-Pfad vertiefen.')
        , (N'USP_ServerHealthAnalysis','REFINE_WITH',N'USP_WorkerPressureAnalysis',2,N'CPU-, Scheduler- oder THREADPOOL-Signale mit einem kurzen Delta untersuchen.')
        , (N'USP_ServerHealthAnalysis','CONFIRM_WITH',N'USP_DiagnosticFindings',1,N'Healthresultsets in normalisierte, priorisierte Findings mit Aussagegrenzen überführen.')
        , (N'USP_DatabaseIntegrityAnalysis','CONFIRM_WITH',N'USP_BackupRecovery',1,N'Integritätsevidenz mit Backupfrische, Recovery-Modell und Restorefähigkeit verbinden.')
        , (N'USP_DatabaseCapacityAnalysis','CONFIRM_WITH',N'USP_CurrentIO',1,N'Kapazität, Wachstum und freien Platz gegen aktuelle Datei- und Volume-I/O-Signale prüfen.')
        , (N'USP_PerformanceCounters','CONFIRM_WITH',N'USP_CurrentWaits',1,N'Counter-Deltas mit aktuellen Waitklassen und Requests einordnen.')
        , (N'USP_CriticalEngineEvents','CONFIRM_WITH',N'USP_ErrorLogAnalysis',1,N'Kritische Ringbuffer- und Systemsignale mit begrenzten Errorlogmustern abgleichen.')
        , (N'USP_InternalContentionAnalysis','CONFIRM_WITH',N'USP_CurrentWaits',1,N'Interne Latch-/Spinlocksignale gegen aktuelle Waitverteilung prüfen.')
        , (N'USP_BufferPoolAnalysis','CONFIRM_WITH',N'USP_ServerMemory',1,N'Clerk- und Buffer-Pool-Verteilung in den gesamten Memoryzustand einordnen.')
        , (N'USP_DiagnosticFindings','REFINE_WITH',N'USP_ServerHealthAnalysis',1,N'Serverbezogene Findings in den vollständigen Healthresultsets vertiefen.')
        , (N'USP_DiagnosticFindings','REFINE_WITH',N'USP_InfrastructureAnalysis',2,N'Betriebs-, Backup-, Agent- oder Availability-Findings im Infrastrukturpfad vertiefen.')
        , (N'USP_WorkerPressureAnalysis','REFINE_WITH',N'USP_CurrentRequests',1,N'Worker- oder Runnable-Signale auf verursachende Requests und Blocking eingrenzen.')
        , (N'USP_WorkerPressureAnalysis','CONFIRM_WITH',N'USP_ServerCpuTopology',1,N'Schedulerdruck gegen CPU-, Socket- und Soft-NUMA-Topologie prüfen.')
        , (N'USP_DatabaseConfigurationAnalysis','CONFIRM_WITH',N'USP_ServerConfiguration',1,N'Datenbankoptionen und Drift im Kontext der Instanzkonfiguration bewerten.')

        , (N'USP_ServerFeatureCapabilities','REFINE_WITH',N'USP_SpecialFeatureInventory',1,N'Technische Featurefähigkeit gegen tatsächlich sichtbare Featureverwendung prüfen.')
        , (N'USP_ServerVersionInformation','REFINE_WITH',N'USP_ServerFeatureCapabilities',1,N'Version, Edition und Plattform auf konkrete Framework- und Datenbankfähigkeiten abbilden.')
        , (N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_InMemoryOltpAnalysis',1,N'Bei sichtbarer In-Memory-OLTP-Nutzung den XTP-Pfad vertiefen.')
        , (N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_TemporalAnalysis',2,N'Bei sichtbaren Temporal Tables Beziehungen, Retention und Indizes vertiefen.')
        , (N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_DataCaptureDeepAnalysis',3,N'Bei CDC, Change Tracking oder Replikationshinweisen den Data-Capture-Pfad nutzen.')
        , (N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_EncryptionAnalysis',4,N'Bei sichtbaren Schutzfeatures den Verschlüsselungsstatus vertiefen.')
        , (N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_ExternalRuntimeAnalysis',5,N'Bei External Languages, Libraries oder aktivierter External-Scripts-Konfiguration den External-Runtime-Pfad vertiefen.')
        , (N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_ClrAnalysis',6,N'Bei sichtbaren benutzerdefinierten Assemblies den SQL-CLR-Pfad vertiefen.')
        , (N'USP_SpecialFeatureInventory','REFINE_WITH',N'USP_VectorIndexAnalysis',7,N'Bei sichtbaren nativen Vector-Spalten die Vector-Index- und Wartungsevidenz gezielt prüfen.')
        , (N'USP_VectorIndexAnalysis','CONFIRM_WITH',N'USP_ObjectAnalysis',1,N'Vector-Wartungshinweise gegen Objektgröße, Indexbestand und weitere Objektmetadaten abgleichen.')
        , (N'USP_InMemoryOltpAnalysis','CONFIRM_WITH',N'USP_ServerMemory',1,N'XTP-Memory- und Resource-Pool-Signale im gesamten Server-Memory-Kontext prüfen.')
        , (N'USP_TemporalAnalysis','CONFIRM_WITH',N'USP_DatabaseCapacityAnalysis',1,N'Historywachstum und Retention gegen Datenbankkapazität und Dateiwachstum prüfen.')
        , (N'USP_ServiceBrokerAnalysis','CONFIRM_WITH',N'USP_ErrorLogAnalysis',1,N'Queue-, Activation- oder Transmissionprobleme mit Engine-Logsignalen abgleichen.')
        , (N'USP_FullTextAnalysis','CONFIRM_WITH',N'USP_ErrorLogAnalysis',1,N'Population- und Fragmentzustände gegen Full-Text-bezogene Errorlogsignale prüfen.')
        , (N'USP_DataCaptureDeepAnalysis','CONFIRM_WITH',N'USP_AgentMonitoringAnalysis',1,N'Capture-, Cleanup- oder Replikationslatenz gegen die zugehörigen Agentjobs prüfen.')
        , (N'USP_EncryptionAnalysis','CONFIRM_WITH',N'USP_BackupRecovery',1,N'Backupverschlüsselung und Schutzstatus mit realer Backupkette und Restorevertrag verbinden.')
        , (N'USP_ExternalRuntimeAnalysis','CONFIRM_WITH',N'USP_CurrentRequests',1,N'Aktive External-Script-Requests in den gesamten Request-, Wait- und Blockingkontext einordnen.')
        , (N'USP_ExternalRuntimeAnalysis','CONFIRM_WITH',N'USP_ResourceGovernorAnalysis',2,N'External-Pool-Signale gegen die allgemeine Resource-Governor-Konfiguration prüfen.')
        , (N'USP_ExternalRuntimeAnalysis','CONFIRM_WITH',N'USP_PerformanceCounters',3,N'External-Scripts-Counter mit der allgemeinen typisierten Counteranalyse gegenprüfen.')
        , (N'USP_ExternalRuntimeAnalysis','CONFIRM_WITH',N'USP_ExtendedEventsSessions',4,N'Vorhandene Extended-Events-Evidenz im gleichen Zeitfenster prüfen.')
        , (N'USP_ExternalRuntimeAnalysis','CONFIRM_WITH',N'USP_ErrorLogAnalysis',5,N'Runtime- und Launchpad-Signale gegen Errorlog- und Hostevidenz prüfen.')
        , (N'USP_ClrAnalysis','CONFIRM_WITH',N'USP_CurrentRequests',1,N'Aktive Managed-Code-Requests in den gesamten Request-, Wait- und Blockingkontext einordnen.')
        , (N'USP_ClrAnalysis','CONFIRM_WITH',N'USP_ServerSecurityConfiguration',2,N'CLR-Konfiguration und Assemblyberechtigungen im Instanz-Sicherheitskontext bewerten.')
        , (N'USP_ClrAnalysis','CONFIRM_WITH',N'USP_PerformanceCounters',3,N'CLR-Counter mit der allgemeinen typisierten Counteranalyse gegenprüfen.')
        , (N'USP_ClrAnalysis','CONFIRM_WITH',N'USP_ExtendedEventsSessions',4,N'Vorhandene Extended-Events-Evidenz im gleichen Zeitfenster prüfen.')
        , (N'USP_ClrAnalysis','CONFIRM_WITH',N'USP_ErrorLogAnalysis',5,N'CLR-Host- und Ladeprobleme gegen Errorlogevidenz prüfen.')

        , (N'USP_ConfigureSnapshotTarget','PREPARE_WITH',N'USP_RunSnapshotCollectionCycle',1,N'Nach erfolgreicher Ziel- und Policykonfiguration kann ein begrenzter Collection Cycle geplant werden.')
        , (N'USP_RunSnapshotCollectionCycle','CONFIRM_WITH',N'USP_ConfigureSnapshotTarget',1,N'Bei Skip, Policy- oder Zielproblemen zuerst die wirksame Snapshotkonfiguration prüfen.')
        , (N'USP_PurgeSnapshotData','CONFIRM_WITH',N'USP_ConfigureSnapshotTarget',1,N'Vor dem Retentionlauf Zielbindung, Policy, Schutzschalter und Batchgrenzen verifizieren.')
        , (N'USP_FrameworkUsageFromQueryStore','CONFIRM_WITH',N'USP_QueryStoreStatus',1,N'Bei leerem Ergebnis den Query-Store-Zustand und die Capture-Konfiguration prüfen.')
        , (N'USP_FrameworkUsageFromQueryStore','CONFIRM_WITH',N'USP_CheckFrameworkCapabilities',2,N'Nutzungsdaten mit dem Capability-Status abgleichen: ungenutztes Modul vs. nicht verfügbar.')
        , (N'USP_FrameworkUsageFromQueryStore','CONFIRM_WITH',N'USP_ServerVersionInformation',3,N'Versionsspezifische Nutzungsmuster mit dem verfügbaren Funktionsumfang abgleichen.')
        , (N'USP_CheckFrameworkCapabilities','REFINE_WITH',N'USP_FrameworkUsageFromQueryStore',1,N'Nach dem Capability-Überblick die tatsächliche Nutzung aus dem Query Store verifizieren.')
    ) AS [v]
    (
          [FromProcedureName], [RelationType], [ToProcedureName]
        , [RelationPriority], [ConditionSummary]
    );
GO
