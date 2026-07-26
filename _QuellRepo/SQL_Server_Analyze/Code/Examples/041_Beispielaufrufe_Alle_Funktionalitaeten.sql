USE [DeineDatenbank];
GO

/* Vollständiger, sicherer Beispielkatalog. Sämtliche Aufrufe sind auskommentiert. */
USE [DeineDatenbank];
GO

-- EXEC [monitor].[USP_AnalysisNavigator] @Hilfe = 1;
-- EXEC [monitor].[USP_AnalysisNavigator] @Suchbegriff=N'query regression', @MaxZeilen=8, @ResultSetArt='CONSOLE';
-- EXEC [monitor].[USP_AnalysisNavigator] @Bereich='PLAN', @Navigationsrolle='TARGETED', @NurInstallierte=1, @ResultSetArt='RAW';

-- EXEC [monitor].[USP_CheckAnalyseAccess] @Hilfe = 1;

-- EXEC [monitor].[USP_CheckFrameworkCapabilities] @Hilfe = 1;

-- EXEC [monitor].[USP_PrepareDatabaseCandidates] @Hilfe = 1;

-- EXEC [monitor].[USP_PrepareNameFilters] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentSessions] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentRequests] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentBlocking] @Hilfe = 1;

-- Ressourcenschonende Auflösung der bereits sichtbaren Wait-Ressourcen:
-- EXEC [monitor].[USP_CurrentBlocking] @BlockingObjektTiefe='STANDARD', @MaxObjektAufloesungen=100, @ResultSetArt='RAW';

-- Vollständige Locktypsicht für beteiligte Sessions; benötigt LOCKS_DEEP-Freigabe:
-- EXEC [monitor].[USP_CurrentBlocking] @BlockingObjektTiefe='DEEP', @MaxObjektAufloesungen=500, @HighImpactConfirmed=1, @ResultSetArt='RAW';

-- Tool-Hintergrundabfragen einschließlich Object Explorer, Copilot und SQL Prompt bewusst einblenden:
-- EXEC [monitor].[USP_CurrentBlocking] @ToolHintergrundabfragenEinbeziehen=1, @ResultSetArt='CONSOLE';
-- SELECT * FROM [monitor].[ToolBackgroundQueryPattern] WITH (NOLOCK) WHERE [IsEnabled]=1 ORDER BY [Priority] DESC,[RuleCode];

-- EXEC [monitor].[USP_CurrentWaits] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentTransactions] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentMemoryGrants] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentTempDB] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentIO] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentLog] @Hilfe = 1;

-- EXEC [monitor].[USP_CurrentOverview] @Hilfe = 1;

-- DECLARE @OverviewJson nvarchar(max);
-- EXEC [monitor].[USP_CurrentOverview] @BlockingObjektTiefe='DEEP', @MaxObjektAufloesungen=500, @HighImpactConfirmed=1, @ResultSetArt='NONE', @JsonErzeugen=1, @Json=@OverviewJson OUTPUT;
-- SELECT JSON_QUERY(@OverviewJson,'$.blocking.locks') AS [BlockingLocks];

-- EXEC [monitor].[USP_ObjectInventory] @Hilfe = 1;

-- EXEC [monitor].[USP_IndexUsage] @Hilfe = 1;

-- EXEC [monitor].[USP_IndexOperationalStats] @Hilfe = 1;

-- EXEC [monitor].[USP_MissingIndexes] @Hilfe = 1;

-- EXEC [monitor].[USP_Statistics] @Hilfe = 1;

-- EXEC [monitor].[USP_StatisticsDistributionAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_Partitions] @Hilfe = 1;

-- EXEC [monitor].[USP_Columnstore] @Hilfe = 1;

-- EXEC [monitor].[USP_IndexPhysicalStats] @Hilfe = 1;

-- EXEC [monitor].[USP_ObjectAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_SchemaDesignAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStats] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryHashAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_PlanCacheHealth] @Hilfe = 1;

-- EXEC [monitor].[USP_PlanDetails] @Hilfe = 1;

-- EXEC [monitor].[USP_ShowplanAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_PlanCacheAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStoreStatus] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStoreRuntimeStats] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStoreWaitStats] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStorePlanChanges] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStoreRegressions] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStoreForcedPlans] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStoreHints] @Hilfe = 1;

-- EXEC [monitor].[USP_QueryStoreAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_ExtendedEventsSessions] @Hilfe = 1;

-- EXEC [monitor].[USP_ExtendedEventsReadEvents] @Hilfe = 1;

-- EXEC [monitor].[USP_ExtendedEventsDeadlocks] @Hilfe = 1;

-- EXEC [monitor].[USP_ExtendedEventsBlockedProcesses] @Hilfe = 1;

-- EXEC [monitor].[USP_ExtendedEventsTargetRuntime] @Hilfe = 1;

-- EXEC [monitor].[USP_ExtendedEventsAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_AgentStatus] @Hilfe = 1;

-- EXEC [monitor].[USP_AgentJobs] @Hilfe = 1;

-- EXEC [monitor].[USP_ResourceGovernorAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_AvailabilityGroups] @Hilfe = 1;

-- EXEC [monitor].[USP_BackupRecovery] @Hilfe = 1;

-- EXEC [monitor].[USP_LogShippingStatus] @Hilfe = 1;

-- EXEC [monitor].[USP_ReplicationStatus] @Hilfe = 1;

-- EXEC [monitor].[USP_DataCaptureStatus] @Hilfe = 1;

-- EXEC [monitor].[USP_InfrastructureAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_BackupChainAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_AvailabilityDeepAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_AgentMonitoringAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_MaintenanceOperations] @Hilfe = 1;

-- EXEC [monitor].[USP_ErrorLogAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_ServerCpuTopology] @Hilfe = 1;

-- EXEC [monitor].[USP_ServerNuma] @Hilfe = 1;

-- EXEC [monitor].[USP_ServerMemory] @Hilfe = 1;

-- EXEC [monitor].[USP_TempDBConfiguration] @Hilfe = 1;

-- EXEC [monitor].[USP_ServerConfiguration] @Hilfe = 1;

-- EXEC [monitor].[USP_TraceFlags] @Hilfe = 1;

-- EXEC [monitor].[USP_StartupParameters] @Hilfe = 1;

-- EXEC [monitor].[USP_OSInformation] @Hilfe = 1;

-- EXEC [monitor].[USP_ServerSecurityConfiguration] @Hilfe = 1;

-- EXEC [monitor].[USP_ServerHealthAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_DatabaseIntegrityAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_DatabaseCapacityAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_PerformanceCounters] @Hilfe = 1;

-- EXEC [monitor].[USP_CriticalEngineEvents] @Hilfe = 1;

-- EXEC [monitor].[USP_InternalContentionAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_BufferPoolAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_DiagnosticFindings] @Hilfe = 1;

-- EXEC [monitor].[USP_WorkerPressureAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_DatabaseConfigurationAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_ServerFeatureCapabilities] @Hilfe = 1;

-- EXEC [monitor].[USP_SpecialFeatureInventory] @Hilfe = 1;

-- EXEC [monitor].[USP_InMemoryOltpAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_TemporalAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_ServiceBrokerAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_FullTextAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_DataCaptureDeepAnalysis] @Hilfe = 1;

-- EXEC [monitor].[USP_EncryptionAnalysis] @Hilfe = 1;


-- BEGIN CURRENTREQUESTS-STATEMENT-KONTEXT
-- EXEC [monitor].[USP_CurrentRequests];
-- EXEC [monitor].[USP_CurrentRequests] @GesamtenSqlTextEinbeziehen=1,@InputBufferEinbeziehen=1,@MaxSqlTextZeichen=0;
-- EXEC [monitor].[USP_CurrentRequests] @ResultSetArt='RAW';
-- DECLARE @CurrentRequestsJson nvarchar(max);
-- EXEC [monitor].[USP_CurrentRequests] @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@CurrentRequestsJson OUTPUT;
-- SELECT @CurrentRequestsJson AS [Json];
-- END CURRENTREQUESTS-STATEMENT-KONTEXT

-- PLAN-001: eigenständig installierbare Execution-Plan- und Evidence-Analyse.
EXEC [monitor].[USP_ExecutionPlanAnalysis] @Hilfe=1;
EXEC [monitor].[USP_CreateExecutionEvidenceJson] @Hilfe=1;
