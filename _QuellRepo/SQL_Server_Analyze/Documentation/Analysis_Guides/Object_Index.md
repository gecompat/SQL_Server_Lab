# Objektindex der eigenständigen Analysebeschreibungen

**Stand:** 23. Juli 2026
**Abdeckung:** alle 97 inventarisierten `USP_*`-Procedures des Frameworks einschließlich der optionalen Pakete

Jeder Link führt zu einer in sich geschlossenen Procedure-Seite. Dort stehen sicherer Einstieg, Zeilengranularität, Leserichtung, technische Problembegründung, unkritischer Gegenkontext, synthetisches Beispiel, Folgeanalyse und der Link zur vollständigen technischen Spaltenreferenz.

Für einen Einstieg nach beobachtetem Problem verwenden Sie [Hier beginnen](Start_Here.md) oder den installierten `USP_AnalysisNavigator`. Unbekannte Begriffe erklärt das [Glossar](Glossary.md). Die ergänzende [detaillierte Referenz der 68 unterstützenden Frameworkobjekte](../Reference/Object_Reference.md) führt jede View, TVF, interne Procedure und Tabelle einzeln auf und beschreibt Aufgabe, Schnittstelle, Verwendung, Last-/Sperrverhalten sowie Stabilitätsgrenze. Scalar-Valued Functions (SVFs) sind im aktuellen Inventory nicht vorhanden.

## Common

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_AnalysisNavigator]` | [Symptom-, Ziel- und metadatenorientierte Auswahl](Procedures/USP_AnalysisNavigator.md) |
| `[monitor].[USP_CheckAnalyseAccess]` | [Policy, Gruppenmatch und technische Abgrenzung](Procedures/USP_CheckAnalyseAccess.md) |
| `[monitor].[USP_CheckFrameworkCapabilities]` | [Version, Rechte, Abfragbarkeit und Featurestatus](Procedures/USP_CheckFrameworkCapabilities.md) |
| `[monitor].[USP_PrepareDatabaseCandidates]` | [Interner Datenbank-Auswahlvertrag](Procedures/USP_PrepareDatabaseCandidates.md) |
| `[monitor].[USP_PrepareNameFilters]` | [Interner Namensfiltervertrag](Procedures/USP_PrepareNameFilters.md) |

## Current State

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_CurrentSessions]` | [Sessions, Verbindung und offene Transaktionen](Procedures/USP_CurrentSessions.md) |
| `[monitor].[USP_CurrentRequests]` | [Aktive Requests, CPU, I/O, Waits, Blocking und Grants](Procedures/USP_CurrentRequests.md) |
| `[monitor].[USP_CurrentBlocking]` | [Blockingketten und Root Blocker](Procedures/USP_CurrentBlocking.md) |
| `[monitor].[USP_CurrentWaits]` | [Live- und Sample-Waits](Procedures/USP_CurrentWaits.md) |
| `[monitor].[USP_CurrentTransactions]` | [Offene und alte Transaktionen](Procedures/USP_CurrentTransactions.md) |
| `[monitor].[USP_CurrentMemoryGrants]` | [Angeforderte, gewährte und genutzte Grants](Procedures/USP_CurrentMemoryGrants.md) |
| `[monitor].[USP_CurrentTempDB]` | [TempDB-Verbrauch nach Ursache und Session](Procedures/USP_CurrentTempDB.md) |
| `[monitor].[USP_CurrentIO]` | [Datei-I/O und Sample-Latenz](Procedures/USP_CurrentIO.md) |
| `[monitor].[USP_ErrorLogAnalysis]` | [Begrenzte Errorlog-Kategorien und Quellenstatus](Procedures/USP_ErrorLogAnalysis.md) |
| `[monitor].[USP_CurrentLog]` | [Logauslastung und Wiederverwendungsgrund](Procedures/USP_CurrentLog.md) |
| `[monitor].[USP_CurrentOverview]` | [Orchestrierter Live-Überblick](Procedures/USP_CurrentOverview.md) |

## Object und Index

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_ObjectInventory]` | [Objekt-, Index- und Größeninventar](Procedures/USP_ObjectInventory.md) |
| `[monitor].[USP_IndexUsage]` | [Nutzung, Resetgrenzen und Löschungsfehlschlüsse](Procedures/USP_IndexUsage.md) |
| `[monitor].[USP_IndexOperationalStats]` | [DML, Allocations, Locks und Latches je Partition](Procedures/USP_IndexOperationalStats.md) |
| `[monitor].[USP_MissingIndexes]` | [Optimizer-Evidenz und unverbindlicher Indexentwurf](Procedures/USP_MissingIndexes.md) |
| `[monitor].[USP_Statistics]` | [Sample, Änderungen und Statistikzustand](Procedures/USP_Statistics.md) |
| `[monitor].[USP_StatisticsDistributionAnalysis]` | [Histogramm, Skew, Tail und Partitionsvariation](Procedures/USP_StatisticsDistributionAnalysis.md) |
| `[monitor].[USP_Partitions]` | [Partitionsgrenzen, Größe und Ablage](Procedures/USP_Partitions.md) |
| `[monitor].[USP_Columnstore]` | [Rowgroups, Deleted Rows, Segmente und Dictionaries](Procedures/USP_Columnstore.md) |
| `[monitor].[USP_IndexPhysicalStats]` | [Fragmentierung, Seitendichte und Page Count](Procedures/USP_IndexPhysicalStats.md) |
| `[monitor].[USP_VectorIndexAnalysis]` | [Vector-Index-Katalog und Hintergrundwartung](Procedures/USP_VectorIndexAnalysis.md) |
| `[monitor].[USP_SchemaDesignAnalysis]` | [Constraints, FKs, Indizes und Identity-Risiken](Procedures/USP_SchemaDesignAnalysis.md) |
| `[monitor].[USP_ObjectAnalysis]` | [Orchestrierte Objekt- und Indextiefenanalyse](Procedures/USP_ObjectAnalysis.md) |

## Plan Cache und Showplan

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_QueryStats]` | [Cachebasierte Ressourcen- und Ausführungsanalyse](Procedures/USP_QueryStats.md) |
| `[monitor].[USP_QueryHashAnalysis]` | [Query-Hash-Gruppen und Planvarianten](Procedures/USP_QueryHashAnalysis.md) |
| `[monitor].[USP_PlanCacheHealth]` | [Cachegröße und Single-Use-Anteil](Procedures/USP_PlanCacheHealth.md) |
| `[monitor].[USP_PlanDetails]` | [Planattribute und Planquellen](Procedures/USP_PlanDetails.md) |
| `[monitor].[USP_CreateExecutionEvidenceJson]` | [Normalisierte IO-, TIME-, Statistik- und Histogrammevidenz](Procedures/USP_CreateExecutionEvidenceJson.md) |
| `[monitor].[USP_ExecutionPlanAnalysis]` | [Eigenständige statement- und operatorbezogene Plananalyse](Procedures/USP_ExecutionPlanAnalysis.md) |

| `[monitor].[USP_ShowplanAnalysis]` | [Operatoren, Schätzfehler, Grants und Parameter](Procedures/USP_ShowplanAnalysis.md) |
| `[monitor].[USP_PlanCacheAnalysis]` | [Orchestrierte Plan-Cache-Analyse](Procedures/USP_PlanCacheAnalysis.md) |

## Query Store

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_QueryStoreStatus]` | [Zustand, Capture, Retention und Speicher](Procedures/USP_QueryStoreStatus.md) |
| `[monitor].[USP_QueryStoreRuntimeStats]` | [Historische Query-/Plan-Aggregate](Procedures/USP_QueryStoreRuntimeStats.md) |
| `[monitor].[USP_QueryStoreWaitStats]` | [Historische Waitkategorien](Procedures/USP_QueryStoreWaitStats.md) |
| `[monitor].[USP_QueryStorePlanChanges]` | [Planwechsel und Compilekontext](Procedures/USP_QueryStorePlanChanges.md) |
| `[monitor].[USP_QueryStoreRegressions]` | [Baseline-/Vergleichsfenster und Regression](Procedures/USP_QueryStoreRegressions.md) |
| `[monitor].[USP_QueryStoreForcedPlans]` | [Forced Plans und Force-Fehler](Procedures/USP_QueryStoreForcedPlans.md) |
| `[monitor].[USP_QueryStoreHints]` | [Hints, Fehler und Governance](Procedures/USP_QueryStoreHints.md) |
| `[monitor].[USP_IntelligentQueryProcessingAnalysis]` | [IQP-Eignung, Konfiguration und Signale](Procedures/USP_IntelligentQueryProcessingAnalysis.md) |
| `[monitor].[USP_QueryStoreAnalysis]` | [Orchestrierte Query-Store-Analyse](Procedures/USP_QueryStoreAnalysis.md) |

## Extended Events

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_ExtendedEventsSessions]` | [Sessions, Events, Actions und Targets](Procedures/USP_ExtendedEventsSessions.md) |
| `[monitor].[USP_ExtendedEventsReadEvents]` | [Event Files, Ring Buffer und Retention](Procedures/USP_ExtendedEventsReadEvents.md) |
| `[monitor].[USP_ExtendedEventsDeadlocks]` | [Deadlockgraph, Prozesse und Ressourcen](Procedures/USP_ExtendedEventsDeadlocks.md) |
| `[monitor].[USP_ExtendedEventsBlockedProcesses]` | [Historische Blocked-Process-Reports](Procedures/USP_ExtendedEventsBlockedProcesses.md) |
| `[monitor].[USP_ExtendedEventsTargetRuntime]` | [Targetzustand und Evidenzverlust](Procedures/USP_ExtendedEventsTargetRuntime.md) |
| `[monitor].[USP_ExtendedEventsAnalysis]` | [Orchestrierte XE-Analyse](Procedures/USP_ExtendedEventsAnalysis.md) |

## Infrastruktur

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_AgentStatus]` | [Agentdienst und Plattformstatus](Procedures/USP_AgentStatus.md) |
| `[monitor].[USP_AgentJobs]` | [Jobs, Schritte, Historie und Laufzeit](Procedures/USP_AgentJobs.md) |
| `[monitor].[USP_ResourceGovernorAnalysis]` | [Pools, Gruppen, Limits und Sessions](Procedures/USP_ResourceGovernorAnalysis.md) |
| `[monitor].[USP_AvailabilityGroups]` | [AG-, Replica-, Datenbank- und Routingstatus](Procedures/USP_AvailabilityGroups.md) |
| `[monitor].[USP_BackupRecovery]` | [Backupalter, Recovery Model und Restoreevidenz](Procedures/USP_BackupRecovery.md) |
| `[monitor].[USP_LogShippingStatus]` | [Backup-, Copy- und Restorepipeline](Procedures/USP_LogShippingStatus.md) |
| `[monitor].[USP_ReplicationStatus]` | [Agents, Latenz und Backlog](Procedures/USP_ReplicationStatus.md) |
| `[monitor].[USP_DataCaptureStatus]` | [CDC, Change Tracking und Jobs](Procedures/USP_DataCaptureStatus.md) |
| `[monitor].[USP_InfrastructureAnalysis]` | [Orchestrierter Infrastrukturüberblick](Procedures/USP_InfrastructureAnalysis.md) |
| `[monitor].[USP_BackupChainAnalysis]` | [LSN-Kette und Restorefähigkeit](Procedures/USP_BackupChainAnalysis.md) |
| `[monitor].[USP_AvailabilityDeepAnalysis]` | [Send-/Redo-Queues und Lag](Procedures/USP_AvailabilityDeepAnalysis.md) |
| `[monitor].[USP_AgentMonitoringAnalysis]` | [Jobs, Alerts, Operatoren und Mailpfad](Procedures/USP_AgentMonitoringAnalysis.md) |
| `[monitor].[USP_MaintenanceOperations]` | [Laufende, pausierte und versionsadaptive Wartungsoperationen](Procedures/USP_MaintenanceOperations.md) |

## Server Health

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_ServerCpuTopology]` | [CPU-, Scheduler- und Topologiekontext](Procedures/USP_ServerCpuTopology.md) |
| `[monitor].[USP_ServerNuma]` | [NUMA- und Memory-Node-Verteilung](Procedures/USP_ServerNuma.md) |
| `[monitor].[USP_ServerMemory]` | [OS-/SQL-Memory und Pressure](Procedures/USP_ServerMemory.md) |
| `[monitor].[USP_TempDBConfiguration]` | [TempDB-Dateien, Größen und Wachstum](Procedures/USP_TempDBConfiguration.md) |
| `[monitor].[USP_ServerConfiguration]` | [Konfigurierte und aktive Serveroptionen](Procedures/USP_ServerConfiguration.md) |
| `[monitor].[USP_TraceFlags]` | [Aktive Trace Flags und Scope](Procedures/USP_TraceFlags.md) |
| `[monitor].[USP_StartupParameters]` | [Startparameter, Pfade und persistente Flags](Procedures/USP_StartupParameters.md) |
| `[monitor].[USP_OSInformation]` | [OS, Virtualisierung, Speicher und Uptime](Procedures/USP_OSInformation.md) |
| `[monitor].[USP_ServerSecurityConfiguration]` | [Sicherheitsrelevante Konfiguration](Procedures/USP_ServerSecurityConfiguration.md) |
| `[monitor].[USP_ServerHealthAnalysis]` | [Orchestrierter Server-Health-Überblick](Procedures/USP_ServerHealthAnalysis.md) |
| `[monitor].[USP_DatabaseIntegrityAnalysis]` | [Integritätsevidenz und Aussagegrenzen](Procedures/USP_DatabaseIntegrityAnalysis.md) |
| `[monitor].[USP_DatabaseCapacityAnalysis]` | [Datei-, Volume- und Wachstumsrisiko](Procedures/USP_DatabaseCapacityAnalysis.md) |
| `[monitor].[USP_PerformanceCounters]` | [Countertypen, Delta und Normalisierung](Procedures/USP_PerformanceCounters.md) |
| `[monitor].[USP_CriticalEngineEvents]` | [Schwere Engine-Ereignisse](Procedures/USP_CriticalEngineEvents.md) |
| `[monitor].[USP_InternalContentionAnalysis]` | [Spinlocks, Latches und Hot Pages](Procedures/USP_InternalContentionAnalysis.md) |
| `[monitor].[USP_BufferPoolAnalysis]` | [Buffer Pool, Clerks und Pressure](Procedures/USP_BufferPoolAnalysis.md) |
| `[monitor].[USP_DiagnosticFindings]` | [Severity, Confidence und SourceModule](Procedures/USP_DiagnosticFindings.md) |
| `[monitor].[USP_WorkerPressureAnalysis]` | [Worker- und Scheduler-Druck](Procedures/USP_WorkerPressureAnalysis.md) |
| `[monitor].[USP_DatabaseConfigurationAnalysis]` | [Datenbankkonfiguration und explizite Driftprofile](Procedures/USP_DatabaseConfigurationAnalysis.md) |

## Versionsadaptive Spezialanalysen

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_ServerFeatureCapabilities]` | [Version, Plattform und Featurefähigkeit](Procedures/USP_ServerFeatureCapabilities.md) |
| `[monitor].[USP_ServerVersionInformation]` | [Build, Servicing-Zweig und Lifecycle](Procedures/USP_ServerVersionInformation.md) |
| `[monitor].[USP_SpecialFeatureInventory]` | [Spezialfeature-Inventar und Deep-Dive-Auswahl](Procedures/USP_SpecialFeatureInventory.md) |
| `[monitor].[USP_InMemoryOltpAnalysis]` | [XTP, Hashindizes, Checkpoints und Pools](Procedures/USP_InMemoryOltpAnalysis.md) |
| `[monitor].[USP_TemporalAnalysis]` | [Temporal History, Retention und Wachstum](Procedures/USP_TemporalAnalysis.md) |
| `[monitor].[USP_ServiceBrokerAnalysis]` | [Queues, Aktivierung, Transmission und Conversations](Procedures/USP_ServiceBrokerAnalysis.md) |
| `[monitor].[USP_FullTextAnalysis]` | [Kataloge, Populationen, Batches und Fragmente](Procedures/USP_FullTextAnalysis.md) |
| `[monitor].[USP_DataCaptureDeepAnalysis]` | [Change Tracking, CDC und lokale Replikation](Procedures/USP_DataCaptureDeepAnalysis.md) |
| `[monitor].[USP_EncryptionAnalysis]` | [TDE, Schutzobjekte, Backupverschlüsselung, Always Encrypted und Ledger](Procedures/USP_EncryptionAnalysis.md) |
| `[monitor].[USP_ExternalRuntimeAnalysis]` | [External Languages, Libraries, Launchpad, Requests, Pools und Counter](Procedures/USP_ExternalRuntimeAnalysis.md) |
| `[monitor].[USP_ClrAnalysis]` | [SQL CLR, Assemblies, AppDomains, Tasks, Requests, Speicher und Counter](Procedures/USP_ClrAnalysis.md) |

## Snapshot und Baseline

| Objekt | Eigenständige Beschreibung |
|---|---|
| `[monitor].[USP_ConfigureSnapshotTarget]` | [Explizites Ziel sowie Collector-, Retention- und Budgetpolicy](Procedures/USP_ConfigureSnapshotTarget.md) |
| `[monitor].[USP_RunSnapshotCollectionCycle]` | [Schedulerneutraler, begrenzter Performance-Counter-Snapshot](Procedures/USP_RunSnapshotCollectionCycle.md) |
| `[monitor].[USP_PurgeSnapshotData]` | [Child-first-Retention in begrenzten Batches](Procedures/USP_PurgeSnapshotData.md) |

## Vollständigkeit

| Bereich | Anzahl |
|---|---:|
| Common | 5 |
| Current State | 11 |
| Object und Index | 12 |
| Plan Cache und Showplan | 8 |
| Query Store | 9 |
| Extended Events | 6 |
| Infrastruktur | 13 |
| Server Health | 19 |
| Versionsadaptive Spezialanalysen | 11 |
| Snapshot und Baseline | 3 |
| **Gesamt** | **97** |

## Weitere Einstiege

- [Runbooks](Runbooks/README.md)
- [Hier beginnen](Start_Here.md)
- [Analysis-Navigator-Vertrag](../Reference/Analysis_Navigator.md)
- [Glossar](Glossary.md)
- [Parameter-Lesehilfe](Parameter_Reading_Guide.md)
- [Gemeinsame Verträge](Common_Contracts.md)
- [Technische Signaturen](../Reference/Procedure_Reference.md)
- [Unterstützende Frameworkobjekte](../Reference/Object_Reference.md)
