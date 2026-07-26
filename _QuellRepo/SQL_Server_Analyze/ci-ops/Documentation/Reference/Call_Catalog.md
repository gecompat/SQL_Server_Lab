# Aufrufkatalog aller dokumentierten Procedures

Stand: 2026-07-25 — 98 Procedures

Die Hilfeaufrufe führen keine fachliche Analyse aus. Weitere typische Querschnittsbeispiele stehen am Dokumentanfang.

## Querschnittsbeispiele

```sql
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff = N'Benutzer warten'
    , @MaxZeilen = 8;

DECLARE @Json nvarchar(max);
EXEC [monitor].[USP_DiagnosticFindings]
      @DatabaseNames = N''
    , @MitSchemaDesign = 0
    , @MitStatistikverteilung = 0
    , @MitIQP = 0
    , @MitContention = 0
    , @MaxZeilen = 100
    , @ResultSetArt = 'NONE'
    , @JsonErzeugen = 1
    , @Json = @Json OUTPUT;
SELECT @Json AS [Json];

CREATE TABLE #CurrentRequests_Result ([Dummy] int NULL);
EXEC [monitor].[USP_CurrentRequests]
      @MaxZeilen = 100
    , @ResultSetArt = 'TABLE'
    , @ResultTablesJson = N'{"requests":"#CurrentRequests_Result"}';
SELECT * FROM #CurrentRequests_Result ORDER BY [SessionId],[RequestId];

EXEC [monitor].[USP_DatabaseIntegrityAnalysis] @DatabaseNames=N'',@MitPageDetails=0,@MaxZeilen=100;
EXEC [monitor].[USP_PerformanceCounters] @SampleSeconds=5,@MaxZeilen=100;
EXEC [monitor].[USP_StatisticsDistributionAnalysis] @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',@AnalyseModus='GEZIELT',@MaxVerteilungsStatistiken=25,@MaxZeilen=100;
EXEC [monitor].[USP_SpecialFeatureInventory] @DatabaseNames=N'',@NurErkannteFeatures=1,@MaxZeilen=100;
EXEC [monitor].[USP_InMemoryOltpAnalysis] @DatabaseNames=N'',@MitHashIndexStats=0,@MaxZeilen=100;
EXEC [monitor].[USP_TemporalAnalysis] @DatabaseNames=N'',@HistorySizeWarnMb=10240,@MaxZeilen=100;
EXEC [monitor].[USP_ServiceBrokerAnalysis] @DatabaseNames=N'',@TransmissionAgeWarnMinutes=60,@MaxZeilen=100;
EXEC [monitor].[USP_FullTextAnalysis] @DatabaseNames=N'',@PopulationAgeWarnMinutes=60,@QueryableFragmentWarn=30,@MaxZeilen=100;
EXEC [monitor].[USP_DataCaptureDeepAnalysis] @DatabaseNames=N'',@CdcLatencyWarnSeconds=300,@ReplicationPendingCommandWarn=10000,@MaxZeilen=100;
EXEC [monitor].[USP_ObjectInventory] @DatabaseNames=N'[DeineDatenbank]|[BeispielDatenbankB]',@SchemaNames=N'dbo|monitor',@ObjectNamePattern=N'regexi:^usp_',@MaxZeilen=200;
```

## `[monitor].[USP_AgentJobs]`

```sql
EXEC [monitor].[USP_AgentJobs] @Hilfe = 1;
```

## `[monitor].[USP_AgentMonitoringAnalysis]`

```sql
EXEC [monitor].[USP_AgentMonitoringAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_AgentStatus]`

```sql
EXEC [monitor].[USP_AgentStatus] @Hilfe = 1;
```

## `[monitor].[USP_AnalysisNavigator]`

```sql
EXEC [monitor].[USP_AnalysisNavigator] @Hilfe = 1;
```

## `[monitor].[USP_AvailabilityDeepAnalysis]`

```sql
EXEC [monitor].[USP_AvailabilityDeepAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_AvailabilityGroups]`

```sql
EXEC [monitor].[USP_AvailabilityGroups] @Hilfe = 1;
```

## `[monitor].[USP_BackupChainAnalysis]`

```sql
EXEC [monitor].[USP_BackupChainAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_BackupRecovery]`

```sql
EXEC [monitor].[USP_BackupRecovery] @Hilfe = 1;
```

## `[monitor].[USP_BufferPoolAnalysis]`

```sql
EXEC [monitor].[USP_BufferPoolAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_CheckAnalyseAccess]`

```sql
EXEC [monitor].[USP_CheckAnalyseAccess] @Hilfe = 1;
```

## `[monitor].[USP_CheckFrameworkCapabilities]`

```sql
EXEC [monitor].[USP_CheckFrameworkCapabilities] @Hilfe = 1;
```

## `[monitor].[USP_Columnstore]`

```sql
EXEC [monitor].[USP_Columnstore] @Hilfe = 1;
```

## `[monitor].[USP_CriticalEngineEvents]`

```sql
EXEC [monitor].[USP_CriticalEngineEvents] @Hilfe = 1;
```

## `[monitor].[USP_CurrentBlocking]`

```sql
EXEC [monitor].[USP_CurrentBlocking] @Hilfe = 1;
```

## `[monitor].[USP_CurrentIO]`

```sql
EXEC [monitor].[USP_CurrentIO] @Hilfe = 1;
```

## `[monitor].[USP_CurrentLog]`

```sql
EXEC [monitor].[USP_CurrentLog] @Hilfe = 1;
```

## `[monitor].[USP_CurrentMemoryGrants]`

```sql
EXEC [monitor].[USP_CurrentMemoryGrants] @Hilfe = 1;
```

## `[monitor].[USP_CurrentOverview]`

```sql
EXEC [monitor].[USP_CurrentOverview] @Hilfe = 1;
```

## `[monitor].[USP_CurrentRequests]`

```sql
EXEC [monitor].[USP_CurrentRequests] @Hilfe = 1;
```

## `[monitor].[USP_CurrentSessions]`

```sql
EXEC [monitor].[USP_CurrentSessions] @Hilfe = 1;
```

## `[monitor].[USP_CurrentTempDB]`

```sql
EXEC [monitor].[USP_CurrentTempDB] @Hilfe = 1;
```

## `[monitor].[USP_CurrentTransactions]`

```sql
EXEC [monitor].[USP_CurrentTransactions] @Hilfe = 1;
```

## `[monitor].[USP_CurrentWaits]`

```sql
EXEC [monitor].[USP_CurrentWaits] @Hilfe = 1;
```

## `[monitor].[USP_DatabaseCapacityAnalysis]`

```sql
EXEC [monitor].[USP_DatabaseCapacityAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_DatabaseIntegrityAnalysis]`

```sql
EXEC [monitor].[USP_DatabaseIntegrityAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_DataCaptureStatus]`

```sql
EXEC [monitor].[USP_DataCaptureStatus] @Hilfe = 1;
```

## `[monitor].[USP_DataCaptureDeepAnalysis]`

```sql
EXEC [monitor].[USP_DataCaptureDeepAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_DiagnosticFindings]`

```sql
EXEC [monitor].[USP_DiagnosticFindings] @Hilfe = 1;
```

## `[monitor].[USP_ExtendedEventsAnalysis]`

```sql
EXEC [monitor].[USP_ExtendedEventsAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ExtendedEventsBlockedProcesses]`

```sql
EXEC [monitor].[USP_ExtendedEventsBlockedProcesses] @Hilfe = 1;
```

## `[monitor].[USP_ExtendedEventsDeadlocks]`

```sql
EXEC [monitor].[USP_ExtendedEventsDeadlocks] @Hilfe = 1;
```

## `[monitor].[USP_ExtendedEventsReadEvents]`

```sql
EXEC [monitor].[USP_ExtendedEventsReadEvents] @Hilfe = 1;
```

## `[monitor].[USP_ExtendedEventsSessions]`

```sql
EXEC [monitor].[USP_ExtendedEventsSessions] @Hilfe = 1;
```

## `[monitor].[USP_ExtendedEventsTargetRuntime]`

```sql
EXEC [monitor].[USP_ExtendedEventsTargetRuntime] @Hilfe = 1;
```

## `[monitor].[USP_FullTextAnalysis]`

```sql
EXEC [monitor].[USP_FullTextAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_IndexOperationalStats]`

```sql
EXEC [monitor].[USP_IndexOperationalStats] @Hilfe = 1;
```

## `[monitor].[USP_IndexPhysicalStats]`

```sql
EXEC [monitor].[USP_IndexPhysicalStats] @Hilfe = 1;
```

## `[monitor].[USP_IndexUsage]`

```sql
EXEC [monitor].[USP_IndexUsage] @Hilfe = 1;
```

## `[monitor].[USP_InfrastructureAnalysis]`

```sql
EXEC [monitor].[USP_InfrastructureAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_InMemoryOltpAnalysis]`

```sql
EXEC [monitor].[USP_InMemoryOltpAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_IntelligentQueryProcessingAnalysis]`

```sql
EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_InternalContentionAnalysis]`

```sql
EXEC [monitor].[USP_InternalContentionAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_LogShippingStatus]`

```sql
EXEC [monitor].[USP_LogShippingStatus] @Hilfe = 1;
```

## `[monitor].[USP_MissingIndexes]`

```sql
EXEC [monitor].[USP_MissingIndexes] @Hilfe = 1;
```

## `[monitor].[USP_ObjectAnalysis]`

```sql
EXEC [monitor].[USP_ObjectAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ObjectInventory]`

```sql
EXEC [monitor].[USP_ObjectInventory] @Hilfe = 1;
```

## `[monitor].[USP_OSInformation]`

```sql
EXEC [monitor].[USP_OSInformation] @Hilfe = 1;
```

## `[monitor].[USP_Partitions]`

```sql
EXEC [monitor].[USP_Partitions] @Hilfe = 1;
```

## `[monitor].[USP_PerformanceCounters]`

```sql
EXEC [monitor].[USP_PerformanceCounters] @Hilfe = 1;
```

## `[monitor].[USP_PlanCacheAnalysis]`

```sql
EXEC [monitor].[USP_PlanCacheAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_PlanCacheHealth]`

```sql
EXEC [monitor].[USP_PlanCacheHealth] @Hilfe = 1;
```

## `[monitor].[USP_PlanDetails]`

```sql
EXEC [monitor].[USP_PlanDetails] @Hilfe = 1;
```

## `[monitor].[USP_PrepareDatabaseCandidates]`

```sql
EXEC [monitor].[USP_PrepareDatabaseCandidates] @Hilfe = 1;
```

## `[monitor].[USP_PrepareNameFilters]`

```sql
EXEC [monitor].[USP_PrepareNameFilters] @Hilfe = 1;
```

## `[monitor].[USP_QueryHashAnalysis]`

```sql
EXEC [monitor].[USP_QueryHashAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_QueryStats]`

```sql
EXEC [monitor].[USP_QueryStats] @Hilfe = 1;
```

## `[monitor].[USP_QueryStoreAnalysis]`

```sql
EXEC [monitor].[USP_QueryStoreAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_QueryStoreForcedPlans]`

```sql
EXEC [monitor].[USP_QueryStoreForcedPlans] @Hilfe = 1;
```

## `[monitor].[USP_QueryStoreHints]`

```sql
EXEC [monitor].[USP_QueryStoreHints] @Hilfe = 1;
```

## `[monitor].[USP_QueryStorePlanChanges]`

```sql
EXEC [monitor].[USP_QueryStorePlanChanges] @Hilfe = 1;
```

## `[monitor].[USP_QueryStoreRegressions]`

```sql
EXEC [monitor].[USP_QueryStoreRegressions] @Hilfe = 1;
```

## `[monitor].[USP_QueryStoreRuntimeStats]`

```sql
EXEC [monitor].[USP_QueryStoreRuntimeStats] @Hilfe = 1;
```

## `[monitor].[USP_QueryStoreStatus]`

```sql
EXEC [monitor].[USP_QueryStoreStatus] @Hilfe = 1;
```

## `[monitor].[USP_QueryStoreWaitStats]`

```sql
EXEC [monitor].[USP_QueryStoreWaitStats] @Hilfe = 1;
```

## `[monitor].[USP_ReplicationStatus]`

```sql
EXEC [monitor].[USP_ReplicationStatus] @Hilfe = 1;
```

## `[monitor].[USP_ResourceGovernorAnalysis]`

```sql
EXEC [monitor].[USP_ResourceGovernorAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_SchemaDesignAnalysis]`

```sql
EXEC [monitor].[USP_SchemaDesignAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ServerConfiguration]`

```sql
EXEC [monitor].[USP_ServerConfiguration] @Hilfe = 1;
```

## `[monitor].[USP_ServerCpuTopology]`

```sql
EXEC [monitor].[USP_ServerCpuTopology] @Hilfe = 1;
```

## `[monitor].[USP_ServerFeatureCapabilities]`

```sql
EXEC [monitor].[USP_ServerFeatureCapabilities] @Hilfe = 1;
```

## `[monitor].[USP_ServerVersionInformation]`

```sql
EXEC [monitor].[USP_ServerVersionInformation] @Hilfe = 1;
```

## `[monitor].[USP_ServerHealthAnalysis]`

```sql
EXEC [monitor].[USP_ServerHealthAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ServerMemory]`

```sql
EXEC [monitor].[USP_ServerMemory] @Hilfe = 1;
```

## `[monitor].[USP_ServerNuma]`

```sql
EXEC [monitor].[USP_ServerNuma] @Hilfe = 1;
```

## `[monitor].[USP_ServerSecurityConfiguration]`

```sql
EXEC [monitor].[USP_ServerSecurityConfiguration] @Hilfe = 1;
```

## `[monitor].[USP_ShowplanAnalysis]`

```sql
EXEC [monitor].[USP_ShowplanAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ServiceBrokerAnalysis]`

```sql
EXEC [monitor].[USP_ServiceBrokerAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_SpecialFeatureInventory]`

```sql
EXEC [monitor].[USP_SpecialFeatureInventory] @Hilfe = 1;
```

## `[monitor].[USP_StartupParameters]`

```sql
EXEC [monitor].[USP_StartupParameters] @Hilfe = 1;
```

## `[monitor].[USP_Statistics]`

```sql
EXEC [monitor].[USP_Statistics] @Hilfe = 1;
```

## `[monitor].[USP_StatisticsDistributionAnalysis]`

```sql
EXEC [monitor].[USP_StatisticsDistributionAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_TempDBConfiguration]`

```sql
EXEC [monitor].[USP_TempDBConfiguration] @Hilfe = 1;
```

## `[monitor].[USP_TemporalAnalysis]`

```sql
EXEC [monitor].[USP_TemporalAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_TraceFlags]`

```sql
EXEC [monitor].[USP_TraceFlags] @Hilfe = 1;
```

## `[monitor].[USP_EncryptionAnalysis]`

```sql
EXEC [monitor].[USP_EncryptionAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ExternalRuntimeAnalysis]`

```sql
EXEC [monitor].[USP_ExternalRuntimeAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ClrAnalysis]`

```sql
EXEC [monitor].[USP_ClrAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_MaintenanceOperations]`

```sql
EXEC [monitor].[USP_MaintenanceOperations] @Hilfe = 1;
```

## `[monitor].[USP_ErrorLogAnalysis]`

```sql
EXEC [monitor].[USP_ErrorLogAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_VectorIndexAnalysis]`

```sql
EXEC [monitor].[USP_VectorIndexAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_WorkerPressureAnalysis]`

```sql
EXEC [monitor].[USP_WorkerPressureAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_FrameworkUsageFromQueryStore]`

```sql
-- Top 100 meistgenutzte Framework-Procedures
EXEC [monitor].[USP_FrameworkUsageFromQueryStore];

-- Letzte 30 Tage, mindestens 5 Ausführungen
EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
      @ZeitraumTage = 30
    , @MinAusfuehrungen = 5;

-- Alle Procedures mit Nutzungsdaten als JSON
DECLARE @UsageJson nvarchar(max);
EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
      @MaxZeilen = 0
    , @ResultSetArt = 'NONE'
    , @Json = @UsageJson OUTPUT;
SELECT @UsageJson;
```

## `[monitor].[USP_DatabaseConfigurationAnalysis]`

```sql
EXEC [monitor].[USP_DatabaseConfigurationAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_CreateExecutionEvidenceJson]`

```sql
EXEC [monitor].[USP_CreateExecutionEvidenceJson] @Hilfe = 1;
```

## `[monitor].[USP_ExecutionPlanAnalysis]`

```sql
EXEC [monitor].[USP_ExecutionPlanAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ConfigureSnapshotTarget]`

```sql
EXEC [monitor].[USP_ConfigureSnapshotTarget]
     @TargetDatabaseName = N'ExampleSnapshotDatabase',
     @Hilfe = 1;
```

## `[monitor].[USP_RunSnapshotCollectionCycle]`

```sql
EXEC [monitor].[USP_RunSnapshotCollectionCycle] @Hilfe = 1;
```

## `[monitor].[USP_PurgeSnapshotData]`

```sql
EXEC [monitor].[USP_PurgeSnapshotData] @Hilfe = 1;
```

## Eigenständige Execution-Plan-Analyse

```sql
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml = @ExamplePlanXml
    , @EvidenzDatenschutzModus = 'DERIVED_ONLY'
    , @ResultSetArt = 'CONSOLE';

DECLARE @EvidenceJson nvarchar(max);
EXEC [monitor].[USP_CreateExecutionEvidenceJson]
      @StatisticsIoText = @ExampleStatisticsIoText
    , @StatisticsTimeText = @ExampleStatisticsTimeText
    , @ResultSetArt = 'NONE'
    , @Json = @EvidenceJson OUTPUT;
```

## `[monitor].[USP_CreateExecutionEvidenceJson]`

```sql
EXEC [monitor].[USP_CreateExecutionEvidenceJson] @Hilfe = 1;
```

## `[monitor].[USP_DatabaseConfigurationAnalysis]`

```sql
EXEC [monitor].[USP_DatabaseConfigurationAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ErrorLogAnalysis]`

```sql
EXEC [monitor].[USP_ErrorLogAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_ExecutionPlanAnalysis]`

```sql
EXEC [monitor].[USP_ExecutionPlanAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_WorkerPressureAnalysis]`

```sql
EXEC [monitor].[USP_WorkerPressureAnalysis] @Hilfe = 1;
```

## `[monitor].[USP_FrameworkUsageFromQueryStore]`

```sql
-- Top 100 meistgenutzte Framework-Procedures
EXEC [monitor].[USP_FrameworkUsageFromQueryStore];

-- Letzte 30 Tage, mindestens 5 Ausführungen
EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
      @ZeitraumTage = 30
    , @MinAusfuehrungen = 5;

-- Alle Procedures mit Nutzungsdaten als JSON
DECLARE @UsageJson nvarchar(max);
EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
      @MaxZeilen = 0
    , @ResultSetArt = 'NONE'
    , @Json = @UsageJson OUTPUT;
SELECT @UsageJson;
```
