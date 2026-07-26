USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ExecutionPlanAnalysis
Version      : 1.2.0
Stand        : 2026-07-23
Typ          : Stored Procedure
Zweck        : Analysiert genau ein direkt übergebenes oder gezielt beschafftes
               Showplan-XML. Der direkte @PlanXml-Pfad ist eigenständig nutzbar.
Planquellen  : IMPORTED, COMPILE, LAST_ACTUAL, CURRENT_ACTUAL, QUERY_STORE.
Evidenz      : Optional bereits strukturiertes Evidence JSON oder bereits
               erfasste SET STATISTICS IO/TIME-Meldungen. Es wird kein fremdes
               SQL ausgeführt und keine Erfassungsoption aktiviert.
Datenschutz  : Parameter-/Histogrammwerte standardmäßig DERIVED_ONLY. SQL-Text
               wird nur mit @MitSqlText=1 ausgegeben. Query-Store-Hint- und
               Feedbackpayloads folgen demselben expliziten Datenschutzmodus.
SQL-Version  : SQL Server 2019 oder neuer.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml                        xml             = NULL
    , @PlanHandle                     varbinary(64)   = NULL
    , @SessionIds                     nvarchar(max)   = NULL
    , @RequestId                      int             = NULL
    , @QueryStoreDatabaseName         sysname         = NULL
    , @QueryStorePlanId               bigint          = NULL
    , @PlanQuelle                     varchar(24)      = 'AUTO'
    , @StatementId                    int             = NULL
    , @StatementQueryHash             binary(8)       = NULL
    , @StatementQueryPlanHash         binary(8)       = NULL
    , @EvidenzJson                    nvarchar(max)   = NULL
    , @StatisticsIoText               nvarchar(max)   = NULL
    , @StatisticsTimeText             nvarchar(max)   = NULL
    , @StatisticsLanguage             varchar(16)     = 'AUTO'
    , @StatistikEvidenzModus          varchar(16)     = 'PLAN_ONLY'
    , @HistogrammModus                varchar(16)     = 'NONE'
    , @MetadatenQuellenmodus          varchar(16)     = 'EVIDENCE_ONLY'
    , @QuellumgebungBestaetigt        bit             = 0
    , @MitPredicateHistogramMap       bit             = 1
    , @AnalyseTiefe                   varchar(16)      = 'STANDARD'
    , @WorkloadProfil                 varchar(32)      = 'AUTO'
    , @Regelsatz                      varchar(32)      = 'DEFAULT'
    , @MinSchweregrad                 varchar(16)      = 'INFO'
    , @MitThreadRuntime               bit             = 0
    , @MitSqlText                     bit             = 0
    , @EvidenzDatenschutzModus        varchar(24)      = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus     varchar(16)      = 'RAW'
    , @SensitiveDataConfirmed         bit             = 0
    , @MaxOperatoren                  int             = 50000
    , @MaxFindings                    int             = 5000
    , @MaxStatistiken                 int             = 100
    , @MaxHistogrammSchritte          int             = 20000
    , @MaxDurationSeconds             int             = 30
    , @LockTimeoutMs                  int             = 0
    , @HighImpactConfirmed            bit             = 0
    , @ResultSetArt                   varchar(16)      = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max)   = NULL
    , @JsonErzeugen                   bit             = 0
    , @Json                           nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                 bit             = 1
    , @Hilfe                          bit             = 0
    , @StatusCodeOut                  varchar(40)     = NULL OUTPUT
    , @IsPartialOut                   bit             = NULL OUTPUT
    , @ErrorNumberOut                 int             = NULL OUTPUT
    , @ErrorMessageOut                nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json=NULL;

    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @ConsoleResultRequested bit=CONVERT(bit,CASE WHEN @OutputMode='CONSOLE' THEN 1 ELSE 0 END);
    DECLARE @TableRequested bit=CONVERT(bit,CASE WHEN @OutputMode='TABLE' THEN 1 ELSE 0 END);
    DECLARE @RequestedPlanSource varchar(24)=UPPER(LTRIM(RTRIM(COALESCE(@PlanQuelle,'AUTO'))));
    DECLARE @Depth varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseTiefe,'STANDARD'))));
    DECLARE @Profile varchar(32)=UPPER(LTRIM(RTRIM(COALESCE(@WorkloadProfil,'AUTO'))));
    DECLARE @RuleSet varchar(32)=UPPER(LTRIM(RTRIM(COALESCE(@Regelsatz,'DEFAULT'))));
    DECLARE @MinSeverity varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@MinSchweregrad,'INFO'))));
    DECLARE @PrivacyMode varchar(24)=UPPER(LTRIM(RTRIM(COALESCE(@EvidenzDatenschutzModus,'DERIVED_ONLY'))));
    DECLARE @IdentifierMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@IdentifierDatenschutzModus,'RAW'))));
    DECLARE @StatisticsMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@StatistikEvidenzModus,'PLAN_ONLY'))));
    DECLARE @HistogramMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@HistogrammModus,'NONE'))));
    DECLARE @MetadataMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@MetadatenQuellenmodus,'EVIDENCE_ONLY'))));
    DECLARE @EffectivePlanSource varchar(24)=NULL;
    DECLARE @RuntimeScope varchar(32)='NONE';
    DECLARE @EffectivePlanXml xml=NULL;
    DECLARE @EvidenceForAnalysis nvarchar(max)=@EvidenzJson;
    DECLARE @Deadline datetime2(3)=DATEADD(SECOND,@MaxDurationSeconds,@Now);
    DECLARE @TokenSalt varbinary(32)=CRYPT_GEN_RANDOM(32);
    DECLARE @EffectiveSessionId smallint=NULL;
    DECLARE @EffectiveRequestId int=@RequestId;
    DECLARE @ServerMajorVersion int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));

    SELECT @StatusCodeOut='AVAILABLE',@IsPartialOut=0,@ErrorNumberOut=NULL,@ErrorMessageOut=NULL;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ExecutionPlanAnalysis';
        PRINT N'Genau eine Planquelle: @PlanXml, @PlanHandle, genau ein Wert in @SessionIds oder @QueryStoreDatabaseName+@QueryStorePlanId.';
        PRINT N'Der direkte @PlanXml-Pfad benötigt weder Plan Cache noch Query Store. Es wird niemals übergebenes SQL ausgeführt.';
        PRINT N'@PlanQuelle gilt für @PlanHandle: AUTO|COMPILE|LAST_ACTUAL. AUTO fällt kontrolliert auf COMPILE zurück.';
        PRINT N'Optional: @EvidenzJson oder bereits erfasste @StatisticsIoText/@StatisticsTimeText.';
        PRINT N'@StatistikEvidenzModus NONE|PLAN_ONLY|USED|RELEVANT|OBJECT_ALL; @HistogrammModus NONE|SUMMARY|STEPS.';
        PRINT N'@EvidenzDatenschutzModus DERIVED_ONLY|TOKENIZED|STRUCTURE_ONLY|RAW; RAW benötigt @SensitiveDataConfirmed=1.';
        PRINT N'@MitSqlText=1 benötigt @SensitiveDataConfirmed=1, weil StatementText Literale enthalten kann.';
        PRINT N'DIAG-005 liefert planWarnings, optimizerContext, runtimeFeedback, queryStoreContext und feedbackAndVariants; Query-Store-Payloads sind standardmäßig ausgelassen.';
        PRINT N'@ResultSetArt CONSOLE|RAW|TABLE|NONE; CONSOLE liefert Findings, TABLE verwendet benannte Ziele.';
        RETURN;
    END;

    CREATE TABLE [#ExecutionPlanAnalysis_TableMap]
    (
          [ResultName] sysname NOT NULL
        , [TargetTable] sysname NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_ModuleStatus]
    (
          [ModuleName] sysname NOT NULL
        , [CollectionTimeUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [PlanSource] varchar(24) NULL
        , [RuntimeCounterScope] varchar(32) NULL
        , [WorkloadProfile] varchar(32) NULL
        , [StatementCount] int NOT NULL
        , [OperatorCount] int NOT NULL
        , [FindingCount] int NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_Capabilities]
    (
          [AnalysisObjectId] int NOT NULL
        , [FeatureCode] varchar(80) NOT NULL
        , [IsAvailable] bit NOT NULL
        , [AvailabilityReason] varchar(80) NOT NULL
        , [EvidenceSource] varchar(40) NOT NULL
        , [Detail] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_PlanDocuments]
    (
          [AnalysisObjectId] int NOT NULL
        , [PlanSource] varchar(24) NOT NULL
        , [RuntimeCounterScope] varchar(32) NOT NULL
        , [ShowplanVersion] nvarchar(64) NULL
        , [ShowplanBuild] nvarchar(64) NULL
        , [SourceProductVersion] nvarchar(128) NULL
        , [SourceCompatibilityLevel] smallint NULL
        , [CardinalityEstimationModelVersion] int NULL
        , [IsPlanComplete] bit NOT NULL
        , [PlanDocumentHash] varbinary(32) NULL
        , [StatementCount] int NOT NULL
        , [OperatorCount] int NOT NULL
        , [HasRuntimeCounters] bit NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_Statements]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [StatementCompId] int NULL
        , [StatementType] nvarchar(128) NULL
        , [StatementText] nvarchar(max) NULL
        , [StatementQueryHash] nvarchar(130) NULL
        , [StatementQueryPlanHash] nvarchar(130) NULL
        , [StatementSubTreeCost] decimal(38,8) NULL
        , [StatementEstimatedRows] decimal(38,4) NULL
        , [OptimizationLevel] nvarchar(128) NULL
        , [EarlyAbortReason] nvarchar(256) NULL
        , [CardinalityEstimationModelVersion] int NULL
        , [CompileTimeMs] bigint NULL
        , [CompileCpuMs] bigint NULL
        , [CompileMemoryKb] bigint NULL
        , [RetrievedFromCache] bit NULL
        , [NonParallelPlanReason] nvarchar(256) NULL
        , PRIMARY KEY ([AnalysisObjectId],[StatementOrdinal])
    );
    CREATE TABLE [#ExecutionPlanAnalysis_Operators]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [NodeId] int NOT NULL
        , [ParentNodeId] int NULL
        , [ChildOrdinal] int NULL
        , [Depth] int NULL
        , [OperatorPath] nvarchar(1000) NULL
        , [PhysicalOp] nvarchar(128) NULL
        , [LogicalOp] nvarchar(128) NULL
        , [EstimateRows] decimal(38,4) NULL
        , [EstimatedRowsRead] decimal(38,4) NULL
        , [EstimatedExecutions] decimal(38,4) NULL
        , [EstimateRebinds] decimal(38,4) NULL
        , [EstimateRewinds] decimal(38,4) NULL
        , [EstimatedCpu] decimal(38,8) NULL
        , [EstimatedIo] decimal(38,8) NULL
        , [AverageRowSize] decimal(38,4) NULL
        , [EstimatedTotalSubtreeCost] decimal(38,8) NULL
        , [Parallel] bit NULL
        , [EstimatedExecutionMode] nvarchar(60) NULL
        , [ActualExecutionMode] nvarchar(60) NULL
        , [Ordered] bit NULL
        , [ScanDirection] nvarchar(60) NULL
        , [ObjectDatabaseName] nvarchar(256) NULL
        , [ObjectSchemaName] nvarchar(256) NULL
        , [ObjectName] nvarchar(256) NULL
        , [IndexName] nvarchar(256) NULL
        , PRIMARY KEY ([AnalysisObjectId],[StatementOrdinal],[NodeId])
    );
    CREATE TABLE [#ExecutionPlanAnalysis_OperatorThreadRuntime]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [NodeId] int NOT NULL
        , [ThreadId] int NULL
        , [BrickId] int NULL
        , [ActualRows] decimal(38,4) NULL
        , [ActualRowsRead] decimal(38,4) NULL
        , [ActualExecutions] bigint NULL
        , [ActualRebinds] bigint NULL
        , [ActualRewinds] bigint NULL
        , [ActualEndOfScans] bigint NULL
        , [ActualScans] bigint NULL
        , [ActualLogicalReads] bigint NULL
        , [ActualPhysicalReads] bigint NULL
        , [ActualReadAheads] bigint NULL
        , [ActualCpuMs] bigint NULL
        , [ActualElapsedMs] bigint NULL
        , [ActualLobLogicalReads] bigint NULL
        , [ActualLobPhysicalReads] bigint NULL
        , [IsRowsReadPaired] bit NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_OperatorRuntime]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [NodeId] int NOT NULL
        , [RuntimeCounterCount] int NOT NULL
        , [RowsReadCounterCount] int NOT NULL
        , [RowsReadCounterCoveragePercent] decimal(9,4) NULL
        , [ActualRows] decimal(38,4) NULL
        , [ActualRowsRead] decimal(38,4) NULL
        , [PairedActualRows] decimal(38,4) NULL
        , [PairedActualRowsRead] decimal(38,4) NULL
        , [ActualExecutions] bigint NULL
        , [ActualRebinds] bigint NULL
        , [ActualRewinds] bigint NULL
        , [ActualLogicalReads] bigint NULL
        , [ActualPhysicalReads] bigint NULL
        , [ActualReadAheads] bigint NULL
        , [ActualCpuMs] bigint NULL
        , [ActualElapsedMs] bigint NULL
        , [EstimatedRowsTotal] decimal(38,4) NULL
        , [ActualToEstimatedRatio] decimal(38,8) NULL
        , [CardinalityLog10Error] decimal(19,6) NULL
        , [RowsReadNotReturned] decimal(38,4) NULL
        , [RowsReadNotReturnedPercent] decimal(19,6) NULL
        , [RuntimeMetricStatus] varchar(40) NOT NULL
        , PRIMARY KEY ([AnalysisObjectId],[StatementOrdinal],[NodeId])
    );
    CREATE TABLE [#ExecutionPlanAnalysis_AccessPaths]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [NodeId] int NOT NULL
        , [PhysicalOp] nvarchar(128) NULL
        , [LogicalOp] nvarchar(128) NULL
        , [DatabaseName] nvarchar(256) NULL
        , [SchemaName] nvarchar(256) NULL
        , [ObjectName] nvarchar(256) NULL
        , [IndexName] nvarchar(256) NULL
        , [StorageType] nvarchar(128) NULL
        , [IsLookup] bit NOT NULL
        , [Ordered] bit NULL
        , [ScanDirection] nvarchar(60) NULL
        , [EstimateRows] decimal(38,4) NULL
        , [EstimatedRowsRead] decimal(38,4) NULL
        , [ActualRows] decimal(38,4) NULL
        , [ActualRowsRead] decimal(38,4) NULL
        , [ActualExecutions] bigint NULL
        , [RowsReadNotReturned] decimal(38,4) NULL
        , [RowsReadNotReturnedPercent] decimal(19,6) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_StatisticsUsage]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatisticsUsageOrdinal] bigint NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [StatementCompId] int NULL
        , [DatabaseName] sysname NULL
        , [SchemaName] sysname NULL
        , [ObjectName] sysname NULL
        , [StatisticsName] sysname NULL
        , [LastUpdateAtCompile] datetime2(7) NULL
        , [ModificationCountAtCompile] bigint NULL
        , [SamplingPercentAtCompile] decimal(19,6) NULL
        , [CurrentLastUpdated] datetime2(7) NULL
        , [CurrentRows] bigint NULL
        , [CurrentRowsSampled] bigint NULL
        , [CurrentModificationCounter] bigint NULL
        , [CurrentSamplePercent] decimal(19,6) NULL
        , [StatisticsChangedSinceCompile] bit NULL
        , [MetadataMatchStatus] varchar(40) NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_Parameters]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [ParameterName] nvarchar(256) NULL
        , [ParameterDataType] nvarchar(256) NULL
        , [CompiledValue] nvarchar(4000) NULL
        , [RuntimeValue] nvarchar(4000) NULL
        , [CompiledValueToken] varbinary(32) NULL
        , [RuntimeValueToken] varbinary(32) NULL
        , [CompiledValueLength] int NULL
        , [RuntimeValueLength] int NULL
        , [ValueHandlingStatus] varchar(40) NOT NULL
        , [ValueSource] varchar(40) NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_ParameterEvidence]
    (
          [CandidateId] int NOT NULL
        , [SessionId] smallint NULL
        , [RequestId] int NULL
        , [StatementOrdinal] int NULL
        , [StatementId] int NULL
        , [StatementQueryHash] nvarchar(130) NULL
        , [StatementQueryPlanHash] nvarchar(130) NULL
        , [PlanHandle] varbinary(64) NULL
        , [QueryStoreDatabaseName] sysname NULL
        , [QueryStorePlanId] bigint NULL
        , [PlanDocumentHash] nvarchar(66) NULL
        , [EvidenceKind] varchar(24) NOT NULL
        , [ParameterName] nvarchar(256) NULL
        , [ParameterDataType] nvarchar(256) NULL
        , [CompiledValuePresent] bit NOT NULL
        , [RuntimeValuePresent] bit NOT NULL
        , [CompiledValueIsSqlNull] bit NULL
        , [RuntimeValueIsSqlNull] bit NULL
        , [CompiledValue] nvarchar(4000) NULL
        , [RuntimeValue] nvarchar(4000) NULL
        , [CompiledValueToken] nvarchar(66) NULL
        , [RuntimeValueToken] nvarchar(66) NULL
        , [CompiledValueLength] int NULL
        , [RuntimeValueLength] int NULL
        , [CompiledValueStatus] varchar(40) NOT NULL
        , [RuntimeValueStatus] varchar(40) NOT NULL
        , [ValueStatus] varchar(40) NOT NULL
        , [ValueHandlingStatus] varchar(40) NOT NULL
        , [ValueSource] varchar(40) NOT NULL
        , [SourceObservedAtUtc] datetime2(3) NOT NULL
        , [ValueCapturedAtUtc] datetime2(3) NULL
        , [IsCurrentExecution] bit NULL
        , [IsLastKnownExecution] bit NULL
        , [IsComplete] bit NOT NULL
        , [EvidenceLimit] nvarchar(1000) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_SourceContext]
    (
          [AnalysisObjectId] int NOT NULL
        , [PlanHandle] varbinary(64) NULL
        , [SourceCapturedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [DatabaseId] int NULL
        , [SetOptions] bigint NULL
        , [CompileUserId] int NULL
        , [PlanGenerationNum] bigint NULL
        , [CacheCreationTime] datetime NULL
        , [CacheLastExecutionTime] datetime NULL
        , [ExecutionCount] bigint NULL
        , [CacheObjectType] nvarchar(34) NULL
        , [CacheObjectClass] nvarchar(16) NULL
        , [CacheUseCounts] int NULL
        , [CacheRefCounts] int NULL
        , [CacheSizeBytes] bigint NULL
        , [CachePoolId] int NULL
        , [EvidenceLimit] nvarchar(1000) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_PlanWarnings]
    (
          [WarningOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NULL
        , [StatementId] int NULL
        , [NodeId] int NULL
        , [WarningCode] varchar(100) NOT NULL
        , [WarningCategory] varchar(40) NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [EvidenceKind] varchar(40) NOT NULL
        , [EvidenceSource] varchar(40) NOT NULL
        , [PlanSource] varchar(24) NULL
        , [SourceObservedAtUtc] datetime2(3) NOT NULL
        , [IsCurrent] bit NULL
        , [IsLastKnown] bit NULL
        , [IsMeasured] bit NOT NULL
        , [IsInferred] bit NOT NULL
        , [MetricName] varchar(80) NULL
        , [MetricValue] decimal(38,4) NULL
        , [MetricUnit] nvarchar(40) NULL
        , [Detail] nvarchar(2000) NOT NULL
        , [FalsePositiveGuard] nvarchar(2000) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , PRIMARY KEY ([WarningOrdinal])
    );
    CREATE TABLE [#ExecutionPlanAnalysis_OptimizerContext]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NULL
        , [StatementId] int NULL
        , [PlanSource] varchar(24) NULL
        , [RuntimeCounterScope] varchar(32) NULL
        , [SourceObservedAtUtc] datetime2(3) NOT NULL
        , [IsCurrent] bit NULL
        , [IsLastKnown] bit NULL
        , [OptimizationLevel] nvarchar(128) NULL
        , [EarlyAbortReason] nvarchar(256) NULL
        , [CardinalityEstimationModelVersion] int NULL
        , [StatementSubTreeCost] decimal(38,8) NULL
        , [StatementEstimatedRows] decimal(38,4) NULL
        , [CompileTimeMs] bigint NULL
        , [CompileCpuMs] bigint NULL
        , [CompileMemoryKb] bigint NULL
        , [RetrievedFromCache] bit NULL
        , [NonParallelPlanReason] nvarchar(256) NULL
        , [PlanDegreeOfParallelism] int NULL
        , [PlanGenerationNum] bigint NULL
        , [CacheCreationTime] datetime NULL
        , [CacheLastExecutionTime] datetime NULL
        , [CacheExecutionCount] bigint NULL
        , [CacheObjectType] nvarchar(34) NULL
        , [CacheObjectClass] nvarchar(16) NULL
        , [CacheUseCounts] int NULL
        , [CacheRefCounts] int NULL
        , [CacheSizeBytes] bigint NULL
        , [CachePoolId] int NULL
        , [SetOptions] bigint NULL
        , [CompileUserId] int NULL
        , [DatabaseId] int NULL
        , [EvidenceMeasurement] varchar(40) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [FalsePositiveGuard] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_RuntimeFeedback]
    (
          [FeedbackOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NULL
        , [StatementId] int NULL
        , [NodeId] int NULL
        , [FeedbackType] varchar(40) NOT NULL
        , [FeedbackState] nvarchar(128) NULL
        , [MetricName] varchar(80) NULL
        , [ObservedValue] decimal(38,4) NULL
        , [BaselineValue] decimal(38,4) NULL
        , [DeltaRatio] decimal(38,8) NULL
        , [MetricUnit] nvarchar(40) NULL
        , [RuntimeCounterScope] varchar(32) NULL
        , [EvidenceSource] varchar(40) NOT NULL
        , [SourceObservedAtUtc] datetime2(3) NOT NULL
        , [IsCurrent] bit NULL
        , [IsLastKnown] bit NULL
        , [IsMeasured] bit NOT NULL
        , [IsDerived] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY ([FeedbackOrdinal])
    );
    CREATE TABLE [#ExecutionPlanAnalysis_QueryStoreContext]
    (
          [AnalysisObjectId] int NOT NULL
        , [QueryStoreDatabaseName] sysname NULL
        , [QueryStorePlanId] bigint NULL
        , [QueryStoreQueryId] bigint NULL
        , [PlanGroupId] bigint NULL
        , [EngineVersion] nvarchar(32) NULL
        , [CompatibilityLevel] smallint NULL
        , [QueryPlanHash] binary(8) NULL
        , [IsTrivialPlan] bit NULL
        , [IsParallelPlan] bit NULL
        , [IsForcedPlan] bit NULL
        , [PlanForcingTypeDesc] nvarchar(60) NULL
        , [ForceFailureCount] bigint NULL
        , [LastForceFailureReason] int NULL
        , [LastForceFailureReasonDesc] nvarchar(128) NULL
        , [CountCompiles] bigint NULL
        , [InitialCompileStartTime] datetimeoffset(7) NULL
        , [LastCompileStartTime] datetimeoffset(7) NULL
        , [LastExecutionTime] datetimeoffset(7) NULL
        , [AvgCompileDurationUs] float NULL
        , [LastCompileDurationUs] bigint NULL
        , [ContextSettingsId] bigint NULL
        , [ObjectId] bigint NULL
        , [QueryHash] binary(8) NULL
        , [QueryParameterizationTypeDesc] nvarchar(60) NULL
        , [AvgOptimizeDurationUs] float NULL
        , [AvgCompileMemoryKb] float NULL
        , [HasCompileReplayScript] bit NULL
        , [IsOptimizedPlanForcingDisabled] bit NULL
        , [PlanType] int NULL
        , [PlanTypeDesc] nvarchar(120) NULL
        , [RuntimeExecutionCount] bigint NULL
        , [RuntimeLastExecutionTime] datetimeoffset(7) NULL
        , [AvgDurationUs] decimal(38,4) NULL
        , [AvgCpuTimeUs] decimal(38,4) NULL
        , [AvgLogicalIoReads] decimal(38,4) NULL
        , [AvgLogicalIoWrites] decimal(38,4) NULL
        , [QueryHintCount] int NOT NULL
        , [QueryHintFailureCount] bigint NOT NULL
        , [PersistedFeedbackCount] int NOT NULL
        , [VariantRelationCount] int NOT NULL
        , [SourceObservedAtUtc] datetime2(3) NOT NULL
        , [IsCurrent] bit NOT NULL
        , [IsLastKnown] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_QueryStorePlanSource]
    (
          [AnalysisObjectId] int NOT NULL
        , [QueryStoreDatabaseName] sysname NOT NULL
        , [QueryStorePlanId] bigint NOT NULL
        , [QueryStoreQueryId] bigint NOT NULL
        , [PlanGroupId] bigint NULL
        , [EngineVersion] nvarchar(32) NULL
        , [CompatibilityLevel] smallint NULL
        , [QueryPlanHash] binary(8) NULL
        , [QueryPlanXml] xml NULL
        , [IsTrivialPlan] bit NULL
        , [IsParallelPlan] bit NULL
        , [IsForcedPlan] bit NULL
        , [PlanForcingTypeDesc] nvarchar(60) NULL
        , [ForceFailureCount] bigint NULL
        , [LastForceFailureReason] int NULL
        , [LastForceFailureReasonDesc] nvarchar(128) NULL
        , [CountCompiles] bigint NULL
        , [InitialCompileStartTime] datetimeoffset(7) NULL
        , [LastCompileStartTime] datetimeoffset(7) NULL
        , [LastExecutionTime] datetimeoffset(7) NULL
        , [AvgCompileDurationUs] float NULL
        , [LastCompileDurationUs] bigint NULL
        , [ContextSettingsId] bigint NULL
        , [ObjectId] bigint NULL
        , [QueryHash] binary(8) NULL
        , [QueryParameterizationTypeDesc] nvarchar(60) NULL
        , [AvgOptimizeDurationUs] float NULL
        , [AvgCompileMemoryKb] float NULL
        , [HasCompileReplayScript] bit NULL
        , [IsOptimizedPlanForcingDisabled] bit NULL
        , [PlanType] int NULL
        , [PlanTypeDesc] nvarchar(120) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_FeedbackAndVariants]
    (
          [RecordOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [AnalysisObjectId] int NOT NULL
        , [RecordType] varchar(40) NOT NULL
        , [FeatureType] varchar(60) NOT NULL
        , [StatementOrdinal] int NULL
        , [StatementId] int NULL
        , [NodeId] int NULL
        , [QueryStorePlanId] bigint NULL
        , [QueryStoreQueryId] bigint NULL
        , [ParentQueryId] bigint NULL
        , [DispatcherPlanId] bigint NULL
        , [QueryVariantQueryId] bigint NULL
        , [QueryVariantId] int NULL
        , [FeatureState] nvarchar(128) NULL
        , [FeatureData] nvarchar(max) NULL
        , [FeatureDataToken] varbinary(32) NULL
        , [FeatureDataLength] int NULL
        , [DataHandlingStatus] varchar(40) NOT NULL
        , [EvidenceSource] varchar(40) NOT NULL
        , [SourceObservedAtUtc] datetime2(3) NOT NULL
        , [IsCurrent] bit NULL
        , [IsLastKnown] bit NULL
        , [IsMeasured] bit NOT NULL
        , [IsDerived] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY ([RecordOrdinal])
    );
    CREATE TABLE [#ExecutionPlanAnalysis_MemoryAndSpills]
    (
          [AnalysisObjectId] int NOT NULL
        , [StatementOrdinal] int NOT NULL
        , [StatementId] int NULL
        , [NodeId] int NULL
        , [RecordType] varchar(24) NOT NULL
        , [SpillKind] nvarchar(128) NULL
        , [SpillLevel] int NULL
        , [SpilledDataSize] bigint NULL
        , [WritesToTempDb] bigint NULL
        , [ReadsFromTempDb] bigint NULL
        , [RequestedMemoryKb] bigint NULL
        , [GrantedMemoryKb] bigint NULL
        , [MaxUsedMemoryKb] bigint NULL
        , [GrantWaitTimeMs] bigint NULL
        , [MemoryGrantFeedbackState] nvarchar(128) NULL
        , [Detail] nvarchar(1000) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_ExecutionEvidence]
    (
          [AnalysisObjectId] int NOT NULL
        , [EvidenceType] varchar(40) NOT NULL
        , [StatementOrdinal] int NULL
        , [ScopeName] nvarchar(512) NULL
        , [MetricName] varchar(80) NOT NULL
        , [MetricValue] decimal(38,4) NULL
        , [MetricUnit] nvarchar(40) NULL
        , [EvidenceStatus] varchar(40) NOT NULL
        , [SameExecutionConfidence] varchar(40) NOT NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_Findings]
    (
          [FindingOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [AnalysisObjectId] int NOT NULL
        , [FindingCode] varchar(100) NOT NULL
        , [Category] varchar(40) NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [Confidence] varchar(32) NOT NULL
        , [EvidenceLevel] varchar(40) NOT NULL
        , [StatementOrdinal] int NULL
        , [StatementId] int NULL
        , [NodeId] int NULL
        , [PhysicalOp] nvarchar(128) NULL
        , [LogicalOp] nvarchar(128) NULL
        , [MetricName] varchar(80) NULL
        , [MetricValue] decimal(38,4) NULL
        , [MetricUnit] nvarchar(40) NULL
        , [ThresholdValue] decimal(38,4) NULL
        , [ThresholdSource] varchar(80) NULL
        , [WorkloadProfile] varchar(32) NOT NULL
        , [Summary] nvarchar(1000) NOT NULL
        , [Evidence] nvarchar(2000) NOT NULL
        , [EvidenceLimit] nvarchar(2000) NOT NULL
        , [CounterEvidence] nvarchar(1000) NULL
        , [RecommendedNextCheck] nvarchar(1000) NOT NULL
        , PRIMARY KEY ([FindingOrdinal])
    );
    CREATE TABLE [#ExecutionPlanAnalysis_HistogramSummaries]
    (
          [DatabaseName] sysname NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL
        , [StatisticsName] sysname NULL,[StatisticsId] int NULL,[LeadingColumnName] sysname NULL
        , [HistogramSteps] int NULL,[HistogramEstimatedRows] float NULL,[MaxEqualRows] float NULL
        , [MaxRangeRows] float NULL,[MaxStepRows] float NULL,[DominantStepPercent] decimal(19,6) NULL
        , [TailStepRows] float NULL,[TailStepPercent] decimal(19,6) NULL,[CollectionStatus] varchar(40) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_HistogramSteps]
    (
          [DatabaseName] sysname NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL
        , [StatisticsName] sysname NULL,[StatisticsId] int NULL,[LeadingColumnName] sysname NULL
        , [StepOrdinal] int NULL,[RangeHighKey] nvarchar(4000) NULL,[RangeHighKeyToken] varbinary(32) NULL
        , [RangeRows] float NULL,[EqualRows] float NULL,[DistinctRangeRows] bigint NULL,[AverageRangeRows] float NULL
        , [IsPredicateTarget] bit NULL,[PredicateMatchCount] int NULL,[SensitiveValueStatus] varchar(40) NULL
    );
    CREATE TABLE [#ExecutionPlanAnalysis_PredicateHistogramMappings]
    (
          [PredicateReferenceId] bigint NULL,[StatementOrdinal] int NULL,[NodeId] int NULL
        , [DatabaseName] sysname NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL,[ColumnName] sysname NULL
        , [StatisticsName] sysname NULL,[PredicateKind] varchar(40) NULL,[ValueSource] varchar(32) NULL
        , [MappingStatus] varchar(48) NULL,[MappingConfidence] varchar(16) NULL,[MatchedStepOrdinal] int NULL
        , [MatchesRangeHighKey] bit NULL,[IsBelowHistogram] bit NULL,[IsAboveHistogram] bit NULL
        , [SensitiveValueStatus] varchar(40) NULL
    );

    IF @OutputMode NOT IN ('CONSOLE','RAW','TABLE','NONE')
       OR @RequestedPlanSource NOT IN ('AUTO','COMPILE','LAST_ACTUAL')
       OR @Depth NOT IN ('SUMMARY','STANDARD','FULL')
       OR @RuleSet<>'DEFAULT'
       OR @MinSeverity NOT IN ('INFO','LOW','MEDIUM','HIGH','CRITICAL')
       OR @MitThreadRuntime NOT IN (0,1) OR @MitSqlText NOT IN (0,1)
       OR @PrivacyMode NOT IN ('DERIVED_ONLY','TOKENIZED','RAW','STRUCTURE_ONLY')
       OR @IdentifierMode NOT IN ('RAW','TOKENIZED','OMIT')
       OR @StatisticsMode NOT IN ('NONE','PLAN_ONLY','USED','RELEVANT','OBJECT_ALL')
       OR @HistogramMode NOT IN ('NONE','SUMMARY','STEPS')
       OR @MetadataMode NOT IN ('EVIDENCE_ONLY','CURRENT_SERVER')
       OR @MitPredicateHistogramMap NOT IN (0,1)
       OR @MaxOperatoren IS NULL OR @MaxOperatoren<1
       OR @MaxFindings IS NULL OR @MaxFindings<1
       OR @MaxStatistiken IS NULL OR @MaxStatistiken NOT BETWEEN 1 AND 1000
       OR @MaxHistogrammSchritte IS NULL OR @MaxHistogrammSchritte NOT BETWEEN 0 AND 200000
       OR @MaxDurationSeconds IS NULL OR @MaxDurationSeconds NOT BETWEEN 1 AND 3600
       OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
       OR @HighImpactConfirmed NOT IN (0,1)
       OR @JsonErzeugen NOT IN (0,1)
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Ungültiger Modus-, Grenzwert-, Planquellen-, Ausgabe- oder Datenschutzparameter.';
    END;

    IF @StatusCodeOut='AVAILABLE'
       AND NULLIF(LTRIM(RTRIM(COALESCE(@SessionIds,N''))),N'') IS NOT NULL
    BEGIN
        IF EXISTS
           (
               SELECT 1
               FROM [monitor].[TVF_ParseBigintList](@SessionIds)
               WHERE [IsValid]<>1
                  OR [NumberValue] NOT BETWEEN 1 AND 32767
           )
           OR 1<>(SELECT COUNT(*) FROM [monitor].[TVF_ParseBigintList](@SessionIds))
        BEGIN
            SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
                   @ErrorMessageOut=N'@SessionIds muss für diese Ein-Plan-Analyse genau eine gültige smallint-Session-ID enthalten.';
        END
        ELSE
        BEGIN
            SELECT @EffectiveSessionId=CONVERT(smallint,[NumberValue])
            FROM [monitor].[TVF_ParseBigintList](@SessionIds);
        END;
    END;

    DECLARE @PlanSourceGroupCount int=
          CASE WHEN @PlanXml IS NOT NULL THEN 1 ELSE 0 END
        + CASE WHEN @PlanHandle IS NOT NULL THEN 1 ELSE 0 END
        + CASE WHEN @EffectiveSessionId IS NOT NULL THEN 1 ELSE 0 END
        + CASE WHEN @QueryStoreDatabaseName IS NOT NULL OR @QueryStorePlanId IS NOT NULL THEN 1 ELSE 0 END;

    IF @StatusCodeOut='AVAILABLE' AND @PlanSourceGroupCount<>1
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Genau eine Planquelle muss angegeben werden.';
    END;
    IF @StatusCodeOut='AVAILABLE'
       AND ((@QueryStoreDatabaseName IS NULL AND @QueryStorePlanId IS NOT NULL)
         OR (@QueryStoreDatabaseName IS NOT NULL AND @QueryStorePlanId IS NULL))
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Query Store benötigt @QueryStoreDatabaseName und @QueryStorePlanId gemeinsam.';
    END;
    IF @StatusCodeOut='AVAILABLE' AND @PrivacyMode='RAW' AND @SensitiveDataConfirmed<>1
    BEGIN
        SELECT @StatusCodeOut='SENSITIVE_DATA_CONFIRMATION_REQUIRED',@IsPartialOut=1,
               @ErrorMessageOut=N'RAW-Parameter- oder Histogrammwerte benötigen @SensitiveDataConfirmed=1.';
    END;
    IF @StatusCodeOut='AVAILABLE' AND @MitSqlText=1 AND @SensitiveDataConfirmed<>1
    BEGIN
        SELECT @StatusCodeOut='SENSITIVE_DATA_CONFIRMATION_REQUIRED',@IsPartialOut=1,
               @ErrorMessageOut=N'StatementText kann Literale und proprietären SQL-Text enthalten. @MitSqlText=1 benötigt @SensitiveDataConfirmed=1.';
    END;
    IF @StatusCodeOut='AVAILABLE' AND @MetadataMode='CURRENT_SERVER' AND @QuellumgebungBestaetigt<>1
    BEGIN
        SELECT @StatusCodeOut='SOURCE_ENVIRONMENT_CONFIRMATION_REQUIRED',@IsPartialOut=1,
               @ErrorMessageOut=N'CURRENT_SERVER-Anreicherung benötigt @QuellumgebungBestaetigt=1.';
    END;

    IF @StatusCodeOut='AVAILABLE' AND @TableRequested=1
    BEGIN
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'moduleStatus|capabilities|planDocuments|statements|operatorTree|operatorRuntime|operatorThreadRuntime|accessPaths|statisticsUsage|parametersAndVariants|parameters|planWarnings|optimizerContext|runtimeFeedback|queryStoreContext|feedbackAndVariants|memoryAndSpills|executionEvidence|histogramSummaries|histogramSteps|predicateHistogramMappings|findings'
            , @MappingTable=N'#ExecutionPlanAnalysis_TableMap'
            , @ThrowOnError=1;
        SET @OutputMode='NONE';
    END
    ELSE IF @StatusCodeOut='AVAILABLE' AND @ResultTablesJson IS NOT NULL
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.';
    END;
    IF @ConsoleResultRequested=1 SET @OutputMode='NONE';

    /*
      Cachekontext wird je Aufruf genau einmal materialisiert. Ein
      USP_ShowplanAnalysis-Parent stellt seinen bereits gelesenen Kandidaten-
      Snapshot über eine lokale Temp-Tabelle bereit; ein direkter Planhandle-
      Aufruf verwendet einen gezielten Einzelread.
    */
    IF @StatusCodeOut='AVAILABLE' AND @PlanHandle IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC [sys].[sp_executesql]
                  N'INSERT [#ExecutionPlanAnalysis_SourceContext]
                    (
                          [AnalysisObjectId],[PlanHandle],[SourceCapturedAtUtc],[StatusCode]
                        , [DatabaseId],[SetOptions],[CompileUserId],[PlanGenerationNum]
                        , [CacheCreationTime],[CacheLastExecutionTime],[ExecutionCount]
                        , [CacheObjectType],[CacheObjectClass],[CacheUseCounts],[CacheRefCounts]
                        , [CacheSizeBytes],[CachePoolId],[EvidenceLimit]
                    )
                    SELECT
                          1,[PlanHandle],[SourceCapturedAtUtc],[StatusCode]
                        , [DatabaseId],[SetOptions],[CompileUserId],[PlanGenerationNum]
                        , [CacheCreationTime],[CacheLastExecutionTime],[ExecutionCount]
                        , [CacheObjectType],[CacheObjectClass],[CacheUseCounts],[CacheRefCounts]
                        , [CacheSizeBytes],[CachePoolId],[EvidenceLimit]
                    FROM [#ShowplanAnalysis_ExecutionPlanSourceContext]
                    WHERE [PlanHandle]=@RequestedPlanHandle;'
                , N'@RequestedPlanHandle varbinary(64)'
                , @RequestedPlanHandle=@PlanHandle;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER()<>208
            BEGIN
                SET @IsPartialOut=1;
                IF @ErrorMessageOut IS NULL
                    SET @ErrorMessageOut=N'Der bereitgestellte Parent-Cachekontext konnte nicht übernommen werden.';
            END;
        END CATCH;

        IF NOT EXISTS
           (
               SELECT 1
               FROM [#ExecutionPlanAnalysis_SourceContext]
               WHERE [PlanHandle]=@PlanHandle
           )
        BEGIN TRY
            INSERT [#ExecutionPlanAnalysis_SourceContext]
            (
                  [AnalysisObjectId],[PlanHandle],[SourceCapturedAtUtc],[StatusCode]
                , [DatabaseId],[SetOptions],[CompileUserId],[PlanGenerationNum]
                , [CacheCreationTime],[CacheLastExecutionTime],[ExecutionCount]
                , [CacheObjectType],[CacheObjectClass],[CacheUseCounts],[CacheRefCounts]
                , [CacheSizeBytes],[CachePoolId],[EvidenceLimit]
            )
            SELECT
                  1,@PlanHandle,@Now
                , CASE WHEN [cp].[plan_handle] IS NULL THEN 'PLAN_CACHE_CONTEXT_UNAVAILABLE' ELSE 'AVAILABLE' END
                , [pa].[DatabaseId],[pa].[SetOptions],[pa].[CompileUserId]
                , [qs].[PlanGenerationNum],[qs].[CacheCreationTime],[qs].[CacheLastExecutionTime],[qs].[ExecutionCount]
                , [cp].[cacheobjtype],[cp].[objtype],[cp].[usecounts],[cp].[refcounts]
                , CONVERT(bigint,[cp].[size_in_bytes]),[cp].[pool_id]
                , N'Cachewerte sind eine flüchtige, nicht transaktional mit dem Plan-XML atomare Momentaufnahme.'
            FROM [sys].[dm_exec_cached_plans] AS [cp] WITH (NOLOCK)
            OUTER APPLY
            (
                SELECT
                      MAX([qs0].[plan_generation_num]) AS [PlanGenerationNum]
                    , MIN([qs0].[creation_time]) AS [CacheCreationTime]
                    , MAX([qs0].[last_execution_time]) AS [CacheLastExecutionTime]
                    , SUM([qs0].[execution_count]) AS [ExecutionCount]
                FROM [sys].[dm_exec_query_stats] AS [qs0] WITH (NOLOCK)
                WHERE [qs0].[plan_handle]=@PlanHandle
            ) AS [qs]
            OUTER APPLY
            (
                SELECT
                      MAX(CASE WHEN [a].[attribute]='dbid' THEN TRY_CONVERT(int,[a].[value]) END) AS [DatabaseId]
                    , MAX(CASE WHEN [a].[attribute]='set_options' THEN TRY_CONVERT(bigint,[a].[value]) END) AS [SetOptions]
                    , MAX(CASE WHEN [a].[attribute]='user_id' THEN TRY_CONVERT(int,[a].[value]) END) AS [CompileUserId]
                FROM [sys].[dm_exec_plan_attributes](@PlanHandle) AS [a]
            ) AS [pa]
            WHERE [cp].[plan_handle]=@PlanHandle;

            IF NOT EXISTS
               (
                   SELECT 1
                   FROM [#ExecutionPlanAnalysis_SourceContext]
                   WHERE [PlanHandle]=@PlanHandle
               )
                INSERT [#ExecutionPlanAnalysis_SourceContext]
                (
                      [AnalysisObjectId],[PlanHandle],[SourceCapturedAtUtc],[StatusCode]
                    , [EvidenceLimit]
                )
                VALUES
                (
                      1,@PlanHandle,@Now,'PLAN_CACHE_CONTEXT_UNAVAILABLE'
                    , N'Der Planhandle war beim gezielten Cachekontext-Read nicht mehr in sys.dm_exec_cached_plans sichtbar.'
                );
        END TRY
        BEGIN CATCH
            INSERT [#ExecutionPlanAnalysis_SourceContext]
            (
                  [AnalysisObjectId],[PlanHandle],[SourceCapturedAtUtc],[StatusCode]
                , [EvidenceLimit]
            )
            VALUES
            (
                  1,@PlanHandle,@Now
                , CASE WHEN ERROR_NUMBER() IN (229,371,262,297,300,916)
                       THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END
                , N'Der gezielte Cachekontext-Read ist fehlgeschlagen; die Plan-XML-Analyse bleibt davon getrennt.'
            );
            SET @IsPartialOut=1;
            IF @ErrorNumberOut IS NULL
                SELECT @ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
        END CATCH;
    END;

    /* Planbeschaffung. Direkt übergebenes XML bleibt vollständig standalone. */
    IF @StatusCodeOut='AVAILABLE'
    BEGIN TRY
        IF @PlanXml IS NOT NULL
        BEGIN
            SET @EffectivePlanXml=@PlanXml;
            SET @EffectivePlanSource='IMPORTED';
            SET @RuntimeScope=CASE WHEN @PlanXml.exist('//*[local-name(.)="RunTimeCountersPerThread"]')=1
                                   THEN 'IMPORTED_ACTUAL' ELSE 'NONE' END;
        END
        ELSE IF @PlanHandle IS NOT NULL
        BEGIN
            IF @RequestedPlanSource IN ('AUTO','LAST_ACTUAL')
            BEGIN
                SELECT @EffectivePlanXml=[query_plan]
                FROM [sys].[dm_exec_query_plan_stats](@PlanHandle);
                IF @EffectivePlanXml IS NOT NULL
                BEGIN
                    SET @EffectivePlanSource='LAST_ACTUAL';
                    SET @RuntimeScope='LAST_COMPLETED_EXECUTION';
                END;
            END;
            IF @EffectivePlanXml IS NULL AND @RequestedPlanSource IN ('AUTO','COMPILE')
            BEGIN
                SELECT @EffectivePlanXml=[query_plan]
                FROM [sys].[dm_exec_query_plan](@PlanHandle);
                IF @EffectivePlanXml IS NOT NULL
                BEGIN
                    SET @EffectivePlanSource='COMPILE';
                    SET @RuntimeScope='NONE';
                END;
            END;
        END
        ELSE IF @EffectiveSessionId IS NOT NULL
        BEGIN
            DECLARE @RequestCount int;
            SELECT @RequestCount=COUNT(*)
            FROM [sys].[dm_exec_query_statistics_xml](@EffectiveSessionId)
            WHERE @RequestId IS NULL OR [request_id]=@RequestId;
            IF @RequestCount>1 AND @RequestId IS NULL
                THROW 51031,N'Die Sitzung besitzt mehrere aktive Requests; @RequestId ist erforderlich.',1;
            SELECT TOP (1)
                  @EffectivePlanXml=[query_plan]
                , @EffectiveRequestId=[request_id]
            FROM [sys].[dm_exec_query_statistics_xml](@EffectiveSessionId)
            WHERE @RequestId IS NULL OR [request_id]=@RequestId
            ORDER BY [request_id];
            IF @EffectivePlanXml IS NOT NULL
            BEGIN
                SET @EffectivePlanSource='CURRENT_ACTUAL';
                SET @RuntimeScope='CURRENT_PARTIAL_EXECUTION';
            END;
        END
        ELSE
        BEGIN
            DECLARE @QueryStoreVersionColumns nvarchar(max)=CASE
                WHEN @ServerMajorVersion>=16 THEN
                    N',[p].[has_compile_replay_script],[p].[is_optimized_plan_forcing_disabled],[p].[plan_type],[p].[plan_type_desc]'
                ELSE
                    N',CONVERT(bit,NULL),CONVERT(bit,NULL),CONVERT(int,NULL),CONVERT(nvarchar(120),NULL)'
                END;
            DECLARE @QueryStoreSql nvarchar(max)=N'USE '+QUOTENAME(@QueryStoreDatabaseName)+N';
INSERT [#ExecutionPlanAnalysis_QueryStorePlanSource]
(
      [AnalysisObjectId],[QueryStoreDatabaseName],[QueryStorePlanId],[QueryStoreQueryId]
    , [PlanGroupId],[EngineVersion],[CompatibilityLevel],[QueryPlanHash],[QueryPlanXml]
    , [IsTrivialPlan],[IsParallelPlan],[IsForcedPlan],[PlanForcingTypeDesc]
    , [ForceFailureCount],[LastForceFailureReason],[LastForceFailureReasonDesc]
    , [CountCompiles],[InitialCompileStartTime],[LastCompileStartTime],[LastExecutionTime]
    , [AvgCompileDurationUs],[LastCompileDurationUs],[ContextSettingsId],[ObjectId]
    , [QueryHash],[QueryParameterizationTypeDesc],[AvgOptimizeDurationUs],[AvgCompileMemoryKb]
    , [HasCompileReplayScript],[IsOptimizedPlanForcingDisabled],[PlanType],[PlanTypeDesc]
)
SELECT
      1,@QueryStoreDatabaseName,[p].[plan_id],[p].[query_id]
    , [p].[plan_group_id],[p].[engine_version],[p].[compatibility_level],[p].[query_plan_hash]
    , TRY_CONVERT(xml,[p].[query_plan])
    , [p].[is_trivial_plan],[p].[is_parallel_plan],[p].[is_forced_plan],[p].[plan_forcing_type_desc]
    , [p].[force_failure_count],[p].[last_force_failure_reason],[p].[last_force_failure_reason_desc]
    , [p].[count_compiles],[p].[initial_compile_start_time],[p].[last_compile_start_time],[p].[last_execution_time]
    , [p].[avg_compile_duration],[p].[last_compile_duration],[q].[context_settings_id],[q].[object_id]
    , [q].[query_hash],[q].[query_parameterization_type_desc],[q].[avg_optimize_duration],[q].[avg_compile_memory_kb]'
    +@QueryStoreVersionColumns+N'
FROM [sys].[query_store_plan] AS [p] WITH (NOLOCK)
JOIN [sys].[query_store_query] AS [q] WITH (NOLOCK)
  ON [q].[query_id]=[p].[query_id]
WHERE [p].[plan_id]=@PlanId;';
            EXEC [sys].[sp_executesql]
                  @QueryStoreSql
                , N'@PlanId bigint,@QueryStoreDatabaseName sysname'
                , @PlanId=@QueryStorePlanId
                , @QueryStoreDatabaseName=@QueryStoreDatabaseName;
            SELECT @EffectivePlanXml=[QueryPlanXml]
            FROM [#ExecutionPlanAnalysis_QueryStorePlanSource]
            WHERE [QueryStorePlanId]=@QueryStorePlanId;
            IF @EffectivePlanXml IS NOT NULL
            BEGIN
                SET @EffectivePlanSource='QUERY_STORE';
                SET @RuntimeScope='NONE';
            END;
        END;

        IF @EffectivePlanXml IS NULL
        BEGIN
            SELECT @StatusCodeOut='UNAVAILABLE_OBJECT',@IsPartialOut=1,
                   @ErrorMessageOut=N'Die angeforderte Planquelle lieferte kein Showplan-XML.';
        END;
    END TRY
    BEGIN CATCH
        SELECT @StatusCodeOut=CASE
                   WHEN ERROR_NUMBER()=569 AND @PlanHandle IS NOT NULL THEN 'UNAVAILABLE_OBJECT'
                   WHEN ERROR_NUMBER() IN (229,371,262,297,300,916) THEN 'DENIED_PERMISSION'
                   ELSE 'ERROR_HANDLED' END,
               @IsPartialOut=1,@ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
    END CATCH;

    /*
      Eine angeforderte, aber nicht mehr verfügbare Quelle erhält eine eigene
      DIAG-003-Evidenzzeile. Dadurch bleibt PLAN_EVICTED beziehungsweise
      REQUEST_FINISHED von SQL-NULL und einem fehlenden XML-Attribut getrennt.
    */
    IF @EffectivePlanXml IS NULL
       AND @PlanSourceGroupCount=1
       AND @StatusCodeOut IN ('UNAVAILABLE_OBJECT','DENIED_PERMISSION','ERROR_HANDLED')
    BEGIN
        DECLARE @UnavailableValueStatus varchar(40)=CASE
            WHEN @StatusCodeOut='DENIED_PERMISSION' THEN 'DENIED_PERMISSION'
            WHEN @StatusCodeOut='ERROR_HANDLED' THEN 'ERROR_HANDLED'
            WHEN @EffectiveSessionId IS NOT NULL THEN 'REQUEST_FINISHED'
            WHEN @PlanHandle IS NOT NULL THEN 'PLAN_EVICTED'
            ELSE 'NOT_COLLECTED' END;
        DECLARE @AttemptedValueSource varchar(40)=CASE
            WHEN @EffectiveSessionId IS NOT NULL THEN 'LIVE_PLAN'
            WHEN @QueryStorePlanId IS NOT NULL THEN 'QUERY_STORE_PLAN'
            WHEN @PlanHandle IS NOT NULL AND @RequestedPlanSource='COMPILE' THEN 'COMPILE_PLAN'
            WHEN @PlanHandle IS NOT NULL AND @RequestedPlanSource='LAST_ACTUAL' THEN 'LAST_ACTUAL_PLAN'
            WHEN @PlanHandle IS NOT NULL THEN 'PLAN_CACHE_ATTEMPT'
            ELSE 'IMPORTED_PLAN' END;

        INSERT [#ExecutionPlanAnalysis_ParameterEvidence]
        (
              [CandidateId],[SessionId],[RequestId],[StatementOrdinal],[StatementId]
            , [StatementQueryHash],[StatementQueryPlanHash],[PlanHandle]
            , [QueryStoreDatabaseName],[QueryStorePlanId],[PlanDocumentHash]
            , [EvidenceKind],[ParameterName],[ParameterDataType]
            , [CompiledValuePresent],[RuntimeValuePresent]
            , [CompiledValueIsSqlNull],[RuntimeValueIsSqlNull]
            , [CompiledValue],[RuntimeValue],[CompiledValueToken],[RuntimeValueToken]
            , [CompiledValueLength],[RuntimeValueLength]
            , [CompiledValueStatus],[RuntimeValueStatus],[ValueStatus]
            , [ValueHandlingStatus],[ValueSource]
            , [SourceObservedAtUtc],[ValueCapturedAtUtc]
            , [IsCurrentExecution],[IsLastKnownExecution],[IsComplete],[EvidenceLimit]
        )
        VALUES
        (
              1,@EffectiveSessionId,@EffectiveRequestId,NULL,NULL,NULL,NULL,@PlanHandle
            , @QueryStoreDatabaseName,@QueryStorePlanId,NULL
            , 'SOURCE_STATUS',NULL,NULL,0,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
            , 'NOT_COLLECTED','NOT_COLLECTED',@UnavailableValueStatus
            , CASE @PrivacyMode WHEN 'RAW' THEN 'AVAILABLE_RAW'
                   WHEN 'TOKENIZED' THEN 'TOKENIZED_CAPTURE_LOCAL'
                   WHEN 'STRUCTURE_ONLY' THEN 'OMITTED_STRUCTURE_ONLY'
                   ELSE 'OMITTED_DERIVED_ONLY' END
            , @AttemptedValueSource,@Now,NULL
            , CASE WHEN @EffectiveSessionId IS NOT NULL THEN CONVERT(bit,1) END
            , CASE WHEN @RequestedPlanSource='LAST_ACTUAL' THEN CONVERT(bit,1)
                   WHEN @RequestedPlanSource='COMPILE' OR @EffectiveSessionId IS NOT NULL THEN CONVERT(bit,0) END
            , 0
            , CASE @UnavailableValueStatus
                  WHEN 'PLAN_EVICTED' THEN N'Das angeforderte Planhandle war beim gezielten Abruf nicht mehr auflösbar.'
                  WHEN 'REQUEST_FINISHED' THEN N'Der angeforderte Request lieferte beim gezielten Live-Plan-Abruf keine laufende Ausführung mehr.'
                  WHEN 'DENIED_PERMISSION' THEN N'Die Planquelle war mit dem aktuellen Sicherheitskontext nicht lesbar.'
                  ELSE N'Die angeforderte Planquelle lieferte keine auswertbare Parameterevidenz.' END
        );
    END;

    IF @StatusCodeOut='AVAILABLE'
       AND (@Depth='FULL' OR @StatisticsMode IN ('RELEVANT','OBJECT_ALL') OR @HistogramMode='STEPS')
    BEGIN
        IF @HighImpactConfirmed<>1
        BEGIN
            SELECT @StatusCodeOut='HIGH_IMPACT_CONFIRMATION_REQUIRED',@IsPartialOut=1,
                   @ErrorMessageOut=N'Der angeforderte FULL-/breite Statistik-/Histogrammpfad benötigt @HighImpactConfirmed=1.';
        END;
        ELSE IF EXISTS
        (
            SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK)
            JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id]
            WHERE [s].[name]=N'monitor' AND [p].[name]=N'InternalCheckAnalysisPath'
        )
        BEGIN
            DECLARE @GateStatus varchar(40),@GateMessage nvarchar(2048);
            EXEC [sys].[sp_executesql]
                  N'EXEC [monitor].[InternalCheckAnalysisPath]
                          @AnalysisClass=''SHOWPLAN_XML_DEEP'',
                          @HighImpactConfirmed=@Confirmed,
                          @StatusCode=@Status OUTPUT,
                          @ErrorMessage=@Message OUTPUT;'
                , N'@Confirmed bit,@Status varchar(40) OUTPUT,@Message nvarchar(2048) OUTPUT'
                , @Confirmed=@HighImpactConfirmed,@Status=@GateStatus OUTPUT,@Message=@GateMessage OUTPUT;
            IF @GateStatus<>'AVAILABLE'
                SELECT @StatusCodeOut=@GateStatus,@IsPartialOut=1,@ErrorMessageOut=@GateMessage;
        END;
    END;

    /* AUTO-Profil: explizite lokale Zuordnung, sonst BALANCED. */
    IF @StatusCodeOut='AVAILABLE'
    BEGIN
        IF @Profile='AUTO'
        BEGIN
            SELECT TOP (1) @Profile=[a].[ProfileCode]
            FROM [monitor].[PlanAnalysisProfileAssignment] AS [a] WITH (NOLOCK)
            JOIN [monitor].[PlanAnalysisProfile] AS [p] WITH (NOLOCK)
              ON [p].[ProfileCode]=[a].[ProfileCode] AND [p].[IsEnabled]=1
            WHERE [a].[IsEnabled]=1
              AND (@StatementId IS NULL OR [a].[StatementId] IS NULL OR [a].[StatementId]=@StatementId)
              AND (@StatementQueryHash IS NULL OR [a].[QueryHash] IS NULL OR [a].[QueryHash]=@StatementQueryHash)
              AND ([a].[QueryStoreQueryId] IS NULL)
              AND ([a].[DatabaseNamePattern] IS NULL OR @QueryStoreDatabaseName LIKE [a].[DatabaseNamePattern])
            ORDER BY [a].[Priority],[a].[AssignmentId];
            SET @Profile=COALESCE(@Profile,'BALANCED');
        END;
        IF NOT EXISTS(SELECT 1 FROM [monitor].[PlanAnalysisProfile] WHERE [ProfileCode]=@Profile AND [IsEnabled]=1)
            SET @Profile='BALANCED';
    END;

    /* Public contract: Jede externe oder intern erzeugte Evidenz wird vor der
       Analyse erneut normalisiert. Dadurch gelten Datenschutz-, Shape- und
       Versionsregeln auch für direkt übergebenes @EvidenzJson. */
    IF @StatusCodeOut='AVAILABLE'
    BEGIN
        DECLARE @EvidenceStatus varchar(40),@EvidencePartial bit,@EvidenceError int,@EvidenceMessage nvarchar(2048);
        EXEC [monitor].[USP_CreateExecutionEvidenceJson]
              @PlanXml=@EffectivePlanXml
            , @StatisticsIoText=@StatisticsIoText
            , @StatisticsTimeText=@StatisticsTimeText
            , @StatisticsLanguage=@StatisticsLanguage
            , @StatistikEvidenzModus=@StatisticsMode
            , @HistogrammModus=@HistogramMode
            , @MetadatenQuellenmodus=@MetadataMode
            , @QuellumgebungBestaetigt=@QuellumgebungBestaetigt
            , @EvidenzDatenschutzModus=@PrivacyMode
            , @IdentifierDatenschutzModus='RAW'
            , @SensitiveDataConfirmed=@SensitiveDataConfirmed
            , @MitPredicateHistogramMap=@MitPredicateHistogramMap
            , @StatementId=@StatementId
            , @ExistingEvidenceJson=@EvidenceForAnalysis
            , @MaxStatistiken=@MaxStatistiken
            , @MaxHistogrammSchritte=@MaxHistogrammSchritte
            , @LockTimeoutMs=@LockTimeoutMs
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @RawTextHandling='HASH_ONLY'
            , @StrictValidation=1
            , @ResultSetArt='NONE'
            , @JsonErzeugen=1
            , @Json=@EvidenceForAnalysis OUTPUT
            , @PrintMeldungen=0
            , @StatusCodeOut=@EvidenceStatus OUTPUT
            , @IsPartialOut=@EvidencePartial OUTPUT
            , @ErrorNumberOut=@EvidenceError OUTPUT
            , @ErrorMessageOut=@EvidenceMessage OUTPUT;
        IF COALESCE(@EvidencePartial,0)=1 OR @EvidenceStatus='PARTIAL'
            SET @IsPartialOut=1;
        IF @EvidenceStatus NOT IN ('AVAILABLE','PARTIAL')
        BEGIN
            SET @IsPartialOut=1;
            IF @ErrorMessageOut IS NULL SET @ErrorMessageOut=CONCAT(N'Evidenzanreicherung: ',COALESCE(@EvidenceMessage,@EvidenceStatus));
        END;
    END;

    IF @StatusCodeOut='AVAILABLE'
    BEGIN
        DECLARE @AnalyzerStatus varchar(40),@AnalyzerPartial bit,@AnalyzerError int,@AnalyzerMessage nvarchar(2048);
        EXEC [monitor].[InternalAnalyzeExecutionPlan]
              @AnalysisObjectId=1
            , @PlanXml=@EffectivePlanXml
            , @PlanSource=@EffectivePlanSource
            , @RuntimeCounterScope=@RuntimeScope
            , @WorkloadProfile=@Profile
            , @MinSeverity=@MinSeverity
            , @EvidenceJson=@EvidenceForAnalysis
            , @MitThreadRuntime=@MitThreadRuntime
            , @EvidenzDatenschutzModus=@PrivacyMode
            , @IdentifierDatenschutzModus=@IdentifierMode
            , @SourceObservedAtUtc=@Now
            , @ParameterEvidenceSessionId=@EffectiveSessionId
            , @ParameterEvidenceRequestId=@EffectiveRequestId
            , @PlanHandle=@PlanHandle
            , @QueryStoreDatabaseName=@QueryStoreDatabaseName
            , @QueryStorePlanId=@QueryStorePlanId
            , @StatusCodeOut=@AnalyzerStatus OUTPUT
            , @IsPartialOut=@AnalyzerPartial OUTPUT
            , @ErrorNumberOut=@AnalyzerError OUTPUT
            , @ErrorMessageOut=@AnalyzerMessage OUTPUT;
        IF COALESCE(@AnalyzerPartial,0)=1 OR @AnalyzerStatus='PARTIAL'
            SET @IsPartialOut=1;
        IF @AnalyzerStatus<>'AVAILABLE'
        BEGIN
            SET @StatusCodeOut=@AnalyzerStatus;
            SET @IsPartialOut=1;
            SET @ErrorNumberOut=@AnalyzerError;
            SET @ErrorMessageOut=@AnalyzerMessage;
        END;
    END;

    /*
      DIAG-005: Query Store wird nur für die ausdrücklich angeforderte
      Query-Store-Planquelle gelesen. Plan, Query und Runtimeaggregation werden
      gezielt materialisiert; 2022+-Feedback, Hints und Varianten bleiben
      versionsadaptiv hinter Dynamic SQL. Querytexte werden nicht gelesen.
    */
    IF EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_QueryStorePlanSource])
    BEGIN
        BEGIN TRY
            DECLARE @QueryStoreContextSql nvarchar(max)=N'USE '+QUOTENAME(@QueryStoreDatabaseName)+N';
INSERT [#ExecutionPlanAnalysis_QueryStoreContext]
(
      [AnalysisObjectId],[QueryStoreDatabaseName],[QueryStorePlanId],[QueryStoreQueryId]
    , [PlanGroupId],[EngineVersion],[CompatibilityLevel],[QueryPlanHash]
    , [IsTrivialPlan],[IsParallelPlan],[IsForcedPlan],[PlanForcingTypeDesc]
    , [ForceFailureCount],[LastForceFailureReason],[LastForceFailureReasonDesc]
    , [CountCompiles],[InitialCompileStartTime],[LastCompileStartTime],[LastExecutionTime]
    , [AvgCompileDurationUs],[LastCompileDurationUs],[ContextSettingsId],[ObjectId]
    , [QueryHash],[QueryParameterizationTypeDesc],[AvgOptimizeDurationUs],[AvgCompileMemoryKb]
    , [HasCompileReplayScript],[IsOptimizedPlanForcingDisabled],[PlanType],[PlanTypeDesc]
    , [RuntimeExecutionCount],[RuntimeLastExecutionTime],[AvgDurationUs],[AvgCpuTimeUs]
    , [AvgLogicalIoReads],[AvgLogicalIoWrites]
    , [QueryHintCount],[QueryHintFailureCount],[PersistedFeedbackCount],[VariantRelationCount]
    , [SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[StatusCode],[EvidenceLimit]
)
SELECT
      [s].[AnalysisObjectId],[s].[QueryStoreDatabaseName],[s].[QueryStorePlanId],[s].[QueryStoreQueryId]
    , [s].[PlanGroupId],[s].[EngineVersion],[s].[CompatibilityLevel],[s].[QueryPlanHash]
    , [s].[IsTrivialPlan],[s].[IsParallelPlan],[s].[IsForcedPlan],[s].[PlanForcingTypeDesc]
    , [s].[ForceFailureCount],[s].[LastForceFailureReason],[s].[LastForceFailureReasonDesc]
    , [s].[CountCompiles],[s].[InitialCompileStartTime],[s].[LastCompileStartTime],[s].[LastExecutionTime]
    , [s].[AvgCompileDurationUs],[s].[LastCompileDurationUs],[s].[ContextSettingsId],[s].[ObjectId]
    , [s].[QueryHash],[s].[QueryParameterizationTypeDesc],[s].[AvgOptimizeDurationUs],[s].[AvgCompileMemoryKb]
    , [s].[HasCompileReplayScript],[s].[IsOptimizedPlanForcingDisabled],[s].[PlanType],[s].[PlanTypeDesc]
    , [r].[RuntimeExecutionCount],[r].[RuntimeLastExecutionTime]
    , [r].[AvgDurationUs],[r].[AvgCpuTimeUs],[r].[AvgLogicalIoReads],[r].[AvgLogicalIoWrites]
    , 0,0,0,0,@ObservedAtUtc,0,1,''AVAILABLE''
    , N''Query-Store-Werte sind persistierte Aggregate über das vorhandene Erfassungsfenster; Intervalle, Bereinigungen und Capture-Modus begrenzen Vergleiche.''
FROM [#ExecutionPlanAnalysis_QueryStorePlanSource] AS [s]
OUTER APPLY
(
    SELECT
          [RuntimeExecutionCount]=SUM(CONVERT(bigint,[rs].[count_executions]))
        , [RuntimeLastExecutionTime]=MAX([rs].[last_execution_time])
        , [AvgDurationUs]=CONVERT(decimal(38,4),
              SUM(CONVERT(decimal(38,8),[rs].[avg_duration])*CONVERT(decimal(38,8),[rs].[count_executions]))
              /NULLIF(SUM(CONVERT(decimal(38,8),[rs].[count_executions])),0))
        , [AvgCpuTimeUs]=CONVERT(decimal(38,4),
              SUM(CONVERT(decimal(38,8),[rs].[avg_cpu_time])*CONVERT(decimal(38,8),[rs].[count_executions]))
              /NULLIF(SUM(CONVERT(decimal(38,8),[rs].[count_executions])),0))
        , [AvgLogicalIoReads]=CONVERT(decimal(38,4),
              SUM(CONVERT(decimal(38,8),[rs].[avg_logical_io_reads])*CONVERT(decimal(38,8),[rs].[count_executions]))
              /NULLIF(SUM(CONVERT(decimal(38,8),[rs].[count_executions])),0))
        , [AvgLogicalIoWrites]=CONVERT(decimal(38,4),
              SUM(CONVERT(decimal(38,8),[rs].[avg_logical_io_writes])*CONVERT(decimal(38,8),[rs].[count_executions]))
              /NULLIF(SUM(CONVERT(decimal(38,8),[rs].[count_executions])),0))
    FROM [sys].[query_store_runtime_stats] AS [rs] WITH (NOLOCK)
    WHERE [rs].[plan_id]=[s].[QueryStorePlanId]
) AS [r];';
            EXEC [sys].[sp_executesql]
                  @QueryStoreContextSql
                , N'@ObservedAtUtc datetime2(3)'
                , @ObservedAtUtc=@Now;

            INSERT [#ExecutionPlanAnalysis_RuntimeFeedback]
            (
                  [AnalysisObjectId],[FeedbackType],[FeedbackState],[MetricName]
                , [ObservedValue],[BaselineValue],[MetricUnit],[RuntimeCounterScope]
                , [EvidenceSource],[SourceObservedAtUtc],[IsCurrent],[IsLastKnown]
                , [IsMeasured],[IsDerived],[StatusCode],[EvidenceLimit]
            )
            SELECT
                  [AnalysisObjectId],'QUERY_STORE_AGGREGATE','PERSISTED_AGGREGATE'
                , 'AVERAGE_DURATION_US',[AvgDurationUs],[AvgCpuTimeUs],'microseconds'
                , 'QUERY_STORE_AGGREGATE','QUERY_STORE_RUNTIME_STATS',[SourceObservedAtUtc]
                , 0,1,1,1,'AVAILABLE'
                , N'Die gewichteten Query-Store-Mittelwerte stammen aus dem sichtbaren Retentionfenster und sind keine einzelne aktuelle Ausführung.'
            FROM [#ExecutionPlanAnalysis_QueryStoreContext]
            WHERE [RuntimeExecutionCount] IS NOT NULL;

            IF @ServerMajorVersion>=16
            BEGIN
                DECLARE @QueryStoreFeedbackSql nvarchar(max)=N'USE '+QUOTENAME(@QueryStoreDatabaseName)+N';
INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
(
      [AnalysisObjectId],[RecordType],[FeatureType],[QueryStorePlanId],[QueryStoreQueryId]
    , [FeatureState],[FeatureData],[FeatureDataToken],[FeatureDataLength],[DataHandlingStatus]
    , [EvidenceSource],[SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
    , [StatusCode],[EvidenceLimit]
)
SELECT
      1,''PERSISTED_FEEDBACK'',CONVERT(varchar(60),[f].[feature_desc])
    , [f].[plan_id],[s].[QueryStoreQueryId],CONVERT(nvarchar(128),[f].[state_desc])
    , CASE WHEN @EvidencePrivacyMode=''RAW'' AND @Confirmed=1 THEN [f].[feedback_data] END
    , CASE WHEN @EvidencePrivacyMode=''TOKENIZED'' AND [f].[feedback_data] IS NOT NULL
           THEN HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),[f].[feedback_data])) END
    , DATALENGTH([f].[feedback_data])/2
    , CASE WHEN @EvidencePrivacyMode=''RAW'' AND @Confirmed=1 THEN ''AVAILABLE_RAW''
           WHEN @EvidencePrivacyMode=''TOKENIZED'' THEN ''TOKENIZED''
           WHEN @EvidencePrivacyMode=''STRUCTURE_ONLY'' THEN ''OMITTED_STRUCTURE_ONLY''
           ELSE ''OMITTED_DERIVED_ONLY'' END
    , ''QUERY_STORE_PLAN_FEEDBACK'',@ObservedAtUtc,0,1,1,0,''AVAILABLE''
    , N''Persistiertes Feedback ist versions-, zustands- und bereinigungsabhängig; FeatureData kann sensitive oder proprietäre Inhalte enthalten.''
FROM [sys].[query_store_plan_feedback] AS [f] WITH (NOLOCK)
JOIN [#ExecutionPlanAnalysis_QueryStorePlanSource] AS [s]
  ON [s].[QueryStorePlanId]=[f].[plan_id];

INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
(
      [AnalysisObjectId],[RecordType],[FeatureType],[QueryStorePlanId],[QueryStoreQueryId]
    , [ParentQueryId],[DispatcherPlanId],[QueryVariantQueryId]
    , [FeatureState],[DataHandlingStatus],[EvidenceSource],[SourceObservedAtUtc]
    , [IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived],[StatusCode],[EvidenceLimit]
)
SELECT
      1,''QUERY_VARIANT_RELATION'',''PARAMETER_SENSITIVE_PLAN''
    , [s].[QueryStorePlanId],[s].[QueryStoreQueryId]
    , [v].[parent_query_id],[v].[dispatcher_plan_id],[v].[query_variant_query_id]
    , N''PERSISTED_RELATION'',''NO_SENSITIVE_PAYLOAD'',''QUERY_STORE_QUERY_VARIANT'',@ObservedAtUtc
    , 0,1,1,0,''AVAILABLE''
    , N''Die Relation belegt Dispatcher und Queryvariante, nicht deren relative Leistungsqualität.''
FROM [sys].[query_store_query_variant] AS [v] WITH (NOLOCK)
JOIN [#ExecutionPlanAnalysis_QueryStorePlanSource] AS [s]
  ON [s].[QueryStoreQueryId] IN ([v].[query_variant_query_id],[v].[parent_query_id]);

INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
(
      [AnalysisObjectId],[RecordType],[FeatureType],[QueryStorePlanId],[QueryStoreQueryId]
    , [FeatureState],[FeatureData],[FeatureDataToken],[FeatureDataLength],[DataHandlingStatus]
    , [EvidenceSource],[SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
    , [StatusCode],[EvidenceLimit]
)
SELECT
      1,''QUERY_STORE_HINT'',''QUERY_STORE_HINT'',[s].[QueryStorePlanId],[h].[query_id]
    , CASE WHEN COALESCE([h].[query_hint_failure_count],0)>0 THEN N''FAILURE_RECORDED'' ELSE N''CONFIGURED'' END
    , CASE WHEN @EvidencePrivacyMode=''RAW'' AND @Confirmed=1 THEN [h].[query_hint_text] END
    , CASE WHEN @EvidencePrivacyMode=''TOKENIZED'' AND [h].[query_hint_text] IS NOT NULL
           THEN HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),[h].[query_hint_text])) END
    , DATALENGTH([h].[query_hint_text])/2
    , CASE WHEN @EvidencePrivacyMode=''RAW'' AND @Confirmed=1 THEN ''AVAILABLE_RAW''
           WHEN @EvidencePrivacyMode=''TOKENIZED'' THEN ''TOKENIZED''
           WHEN @EvidencePrivacyMode=''STRUCTURE_ONLY'' THEN ''OMITTED_STRUCTURE_ONLY''
           ELSE ''OMITTED_DERIVED_ONLY'' END
    , ''QUERY_STORE_QUERY_HINTS'',@ObservedAtUtc,0,1,1,0,''AVAILABLE''
    , N''Hinttext kann sensitive oder proprietäre Inhalte enthalten; die Zeile bewertet weder Korrektheit noch Nutzen des Hints.''
FROM [sys].[query_store_query_hints] AS [h] WITH (NOLOCK)
JOIN [#ExecutionPlanAnalysis_QueryStorePlanSource] AS [s]
  ON [s].[QueryStoreQueryId]=[h].[query_id];

UPDATE [q]
SET [QueryHintFailureCount]=COALESCE([h].[QueryHintFailureCount],0)
FROM [#ExecutionPlanAnalysis_QueryStoreContext] AS [q]
OUTER APPLY
(
    SELECT
          [QueryHintFailureCount]=SUM(CONVERT(bigint,[h0].[query_hint_failure_count]))
    FROM [sys].[query_store_query_hints] AS [h0] WITH (NOLOCK)
    JOIN [#ExecutionPlanAnalysis_QueryStorePlanSource] AS [s0]
      ON [s0].[QueryStoreQueryId]=[h0].[query_id]
    WHERE [s0].[AnalysisObjectId]=[q].[AnalysisObjectId]
) AS [h];';
                EXEC [sys].[sp_executesql]
                      @QueryStoreFeedbackSql
                    , N'@ObservedAtUtc datetime2(3),@EvidencePrivacyMode varchar(24),@Confirmed bit'
                    , @ObservedAtUtc=@Now,@EvidencePrivacyMode=@PrivacyMode,@Confirmed=@SensitiveDataConfirmed;

                IF NOT EXISTS
                   (
                       SELECT 1
                       FROM [#ExecutionPlanAnalysis_FeedbackAndVariants]
                       WHERE [EvidenceSource] IN
                             ('QUERY_STORE_PLAN_FEEDBACK','QUERY_STORE_QUERY_HINTS','QUERY_STORE_QUERY_VARIANT')
                   )
                    INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
                    (
                          [AnalysisObjectId],[RecordType],[FeatureType],[FeatureState]
                        , [DataHandlingStatus],[EvidenceSource],[SourceObservedAtUtc]
                        , [IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
                        , [StatusCode],[EvidenceLimit]
                    )
                    VALUES
                    (
                          1,'SOURCE_STATUS','QUERY_STORE_OPTIONAL_CONTEXT',N'NO_PERSISTED_ROWS'
                        , 'NO_SENSITIVE_PAYLOAD','QUERY_STORE_OPTIONAL_SOURCES',@Now
                        , 0,1,1,0,'AVAILABLE'
                        , N'Die unterstützten Query-Store-Feedback-, Hint- und Variantenquellen wurden gezielt gelesen und enthielten für den Plan keine Zeile.'
                    );
            END;
            ELSE
                INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
                (
                      [AnalysisObjectId],[RecordType],[FeatureType],[FeatureState]
                    , [DataHandlingStatus],[EvidenceSource],[SourceObservedAtUtc]
                    , [IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
                    , [StatusCode],[EvidenceLimit]
                )
                VALUES
                (
                      1,'SOURCE_STATUS','QUERY_STORE_OPTIONAL_CONTEXT',N'REQUIRES_SQL_SERVER_2022'
                    , 'NO_SENSITIVE_PAYLOAD','QUERY_STORE_OPTIONAL_SOURCES',@Now
                    , 0,1,0,0,'NOT_APPLICABLE'
                    , N'Persistiertes Planfeedback, Query-Store-Hints und Queryvarianten werden erst auf SQL Server 2022 oder neuer gelesen.'
                );

            UPDATE [q]
            SET
                  [QueryHintCount]=[a].[QueryHintCount]
                , [PersistedFeedbackCount]=[a].[PersistedFeedbackCount]
                , [VariantRelationCount]=[a].[VariantRelationCount]
            FROM [#ExecutionPlanAnalysis_QueryStoreContext] AS [q]
            CROSS APPLY
            (
                SELECT
                      [QueryHintCount]=COUNT(CASE WHEN [RecordType]='QUERY_STORE_HINT' THEN 1 END)
                    , [PersistedFeedbackCount]=COUNT(CASE WHEN [RecordType]='PERSISTED_FEEDBACK' THEN 1 END)
                    , [VariantRelationCount]=COUNT(CASE WHEN [RecordType]='QUERY_VARIANT_RELATION' THEN 1 END)
                FROM [#ExecutionPlanAnalysis_FeedbackAndVariants]
                WHERE [AnalysisObjectId]=[q].[AnalysisObjectId]
            ) AS [a];
        END TRY
        BEGIN CATCH
            SET @IsPartialOut=1;
            UPDATE [#ExecutionPlanAnalysis_QueryStoreContext]
            SET
                  [StatusCode]=CASE WHEN ERROR_NUMBER() IN (229,371,262,297,300,916)
                                    THEN 'DENIED_PERMISSION' ELSE 'PARTIAL' END
                , [EvidenceLimit]=N'Der Plan blieb analysierbar; zusätzliche Query-Store-Kontextquellen waren nicht vollständig verfügbar.'
            WHERE [AnalysisObjectId]=1;

            INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
            (
                  [AnalysisObjectId],[RecordType],[FeatureType],[FeatureState]
                , [DataHandlingStatus],[EvidenceSource],[SourceObservedAtUtc]
                , [IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
                , [StatusCode],[EvidenceLimit]
            )
            VALUES
            (
                  1,'SOURCE_STATUS','QUERY_STORE_OPTIONAL_CONTEXT',N'READ_FAILED'
                , 'NO_SENSITIVE_PAYLOAD','QUERY_STORE_OPTIONAL_SOURCES',@Now
                , 0,1,0,0
                , CASE WHEN ERROR_NUMBER() IN (229,371,262,297,300,916)
                       THEN 'DENIED_PERMISSION' ELSE 'PARTIAL' END
                , N'Der Plan blieb analysierbar; mindestens eine zusätzliche Query-Store-Kontextquelle war nicht vollständig verfügbar.'
            );

            INSERT [#ExecutionPlanAnalysis_QueryStoreContext]
            (
                  [AnalysisObjectId],[QueryStoreDatabaseName],[QueryStorePlanId]
                , [QueryHintCount],[QueryHintFailureCount],[PersistedFeedbackCount],[VariantRelationCount]
                , [SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[StatusCode],[EvidenceLimit]
            )
            SELECT
                  1,@QueryStoreDatabaseName,@QueryStorePlanId,0,0,0,0,@Now,0,1
                , CASE WHEN ERROR_NUMBER() IN (229,371,262,297,300,916) THEN 'DENIED_PERMISSION' ELSE 'PARTIAL' END
                , N'Der Plan blieb analysierbar; zusätzliche Query-Store-Kontextquellen waren nicht vollständig verfügbar.'
            WHERE NOT EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_QueryStoreContext]);
            IF @ErrorNumberOut IS NULL
                SELECT @ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
        END CATCH;
    END
    ELSE
        INSERT [#ExecutionPlanAnalysis_QueryStoreContext]
        (
              [AnalysisObjectId],[QueryStoreDatabaseName],[QueryStorePlanId]
            , [QueryHintCount],[QueryHintFailureCount],[PersistedFeedbackCount],[VariantRelationCount]
            , [SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[StatusCode],[EvidenceLimit]
        )
        VALUES
        (
              1,@QueryStoreDatabaseName,@QueryStorePlanId,0,0,0,0,@Now,0
            , CASE WHEN @QueryStorePlanId IS NOT NULL THEN 1 ELSE 0 END
            , CASE WHEN @QueryStorePlanId IS NULL THEN 'NOT_APPLICABLE'
                   WHEN @StatusCodeOut='DENIED_PERMISSION' THEN 'DENIED_PERMISSION'
                   ELSE 'NOT_COLLECTED' END
            , CASE WHEN @QueryStorePlanId IS NULL
                   THEN N'Für diese Planquelle wurde kein Query-Store-Plan angefordert.'
                   ELSE N'Die angeforderte Query-Store-Quelle lieferte keinen materialisierbaren Kontext.' END
        );

    /* Jede kanonische DIAG-005-Ausgabe besitzt auch bei Quellfehlern eine
       eindeutige Statuszeile. */
    IF NOT EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_PlanWarnings])
        INSERT [#ExecutionPlanAnalysis_PlanWarnings]
        (
              [AnalysisObjectId],[WarningCode],[WarningCategory],[Severity],[EvidenceKind]
            , [EvidenceSource],[PlanSource],[SourceObservedAtUtc],[IsMeasured],[IsInferred]
            , [Detail],[FalsePositiveGuard],[StatusCode]
        )
        VALUES
        (
              1,'SOURCE_UNAVAILABLE','SOURCE_STATUS','INFO','SOURCE_STATUS'
            , 'PLAN_SOURCE',@EffectivePlanSource,@Now,0,0
            , N'Die Planquelle lieferte keine normalisierbare Warnungsevidenz.'
            , N'Ein Quellfehler darf nicht als warnungsfreier Plan interpretiert werden.'
            , CASE WHEN @StatusCodeOut='DENIED_PERMISSION' THEN 'DENIED_PERMISSION' ELSE 'NOT_COLLECTED' END
        );
    IF NOT EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_OptimizerContext])
        INSERT [#ExecutionPlanAnalysis_OptimizerContext]
        (
              [AnalysisObjectId],[PlanSource],[RuntimeCounterScope],[SourceObservedAtUtc]
            , [EvidenceMeasurement],[StatusCode],[FalsePositiveGuard]
        )
        VALUES
        (
              1,@EffectivePlanSource,@RuntimeScope,@Now,'NOT_MEASURED'
            , CASE WHEN @StatusCodeOut='DENIED_PERMISSION' THEN 'DENIED_PERMISSION' ELSE 'NOT_COLLECTED' END
            , N'Fehlender Optimizerkontext darf nicht als optimale oder triviale Kompilierung interpretiert werden.'
        );
    IF NOT EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_RuntimeFeedback])
        INSERT [#ExecutionPlanAnalysis_RuntimeFeedback]
        (
              [AnalysisObjectId],[FeedbackType],[RuntimeCounterScope],[EvidenceSource]
            , [SourceObservedAtUtc],[IsMeasured],[IsDerived],[StatusCode],[EvidenceLimit]
        )
        VALUES
        (
              1,'SOURCE_STATUS',@RuntimeScope,'PLAN_SOURCE',@Now,0,0
            , CASE WHEN @StatusCodeOut='DENIED_PERMISSION' THEN 'DENIED_PERMISSION' ELSE 'NOT_COLLECTED' END
            , N'Ohne Runtimeevidenz werden keine Laufzeitaussagen abgeleitet.'
        );
    IF NOT EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_FeedbackAndVariants])
        INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
        (
              [AnalysisObjectId],[RecordType],[FeatureType],[FeatureState]
            , [DataHandlingStatus],[EvidenceSource],[SourceObservedAtUtc]
            , [IsMeasured],[IsDerived],[StatusCode],[EvidenceLimit]
        )
        VALUES
        (
              1,'SOURCE_STATUS','SOURCE_UNAVAILABLE',N'NOT_COLLECTED'
            , 'NO_SENSITIVE_PAYLOAD','PLAN_SOURCE',@Now,0,0
            , CASE WHEN @StatusCodeOut='DENIED_PERMISSION' THEN 'DENIED_PERMISSION' ELSE 'NOT_COLLECTED' END
            , N'Ohne Plan- oder Katalogevidenz werden keine Feedback- oder Variantenmerkmale behauptet.'
        );

    /* Current-Statistics- und Histogrammteile aus normalisierter Evidenz ergänzen. */
    IF @EvidenceForAnalysis IS NOT NULL AND ISJSON(@EvidenceForAnalysis)=1
    BEGIN
        ;WITH [CurrentStats] AS
        (
            SELECT *
            FROM OPENJSON(@EvidenceForAnalysis,N'$.statistics.currentSnapshot')
            WITH
            (
                  [DatabaseName] sysname N'$.databaseName'
                , [SchemaName] sysname N'$.schemaName'
                , [ObjectName] sysname N'$.objectName'
                , [StatisticsName] sysname N'$.statisticsName'
                , [LastUpdated] datetime2(7) N'$.lastUpdated'
                , [Rows] bigint N'$.rows'
                , [RowsSampled] bigint N'$.rowsSampled'
                , [ModificationCounter] bigint N'$.modificationCounter'
                , [SamplePercent] decimal(19,6) N'$.samplePercent'
            )
        )
        UPDATE [u]
        SET
              [u].[CurrentLastUpdated]=[c].[LastUpdated]
            , [u].[CurrentRows]=[c].[Rows]
            , [u].[CurrentRowsSampled]=[c].[RowsSampled]
            , [u].[CurrentModificationCounter]=[c].[ModificationCounter]
            , [u].[CurrentSamplePercent]=[c].[SamplePercent]
            , [u].[StatisticsChangedSinceCompile]=CONVERT(bit,CASE
                  WHEN [u].[LastUpdateAtCompile] IS NULL OR [c].[LastUpdated] IS NULL THEN 0
                  WHEN [u].[LastUpdateAtCompile]<>[c].[LastUpdated] THEN 1 ELSE 0 END)
            , [u].[MetadataMatchStatus]='AVAILABLE'
        FROM [#ExecutionPlanAnalysis_StatisticsUsage] AS [u]
        JOIN [CurrentStats] AS [c]
          ON [c].[DatabaseName]=[u].[DatabaseName]
         AND [c].[SchemaName]=[u].[SchemaName]
         AND [c].[ObjectName]=[u].[ObjectName]
         AND [c].[StatisticsName]=[u].[StatisticsName];

        INSERT [#ExecutionPlanAnalysis_HistogramSummaries]
        SELECT *
        FROM OPENJSON(@EvidenceForAnalysis,N'$.statistics.histogramSummaries')
        WITH
        (
              [DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
            , [ObjectName] sysname N'$.objectName',[StatisticsName] sysname N'$.statisticsName'
            , [StatisticsId] int N'$.statisticsId',[LeadingColumnName] sysname N'$.leadingColumnName'
            , [HistogramSteps] int N'$.histogramSteps',[HistogramEstimatedRows] float N'$.histogramEstimatedRows'
            , [MaxEqualRows] float N'$.maxEqualRows',[MaxRangeRows] float N'$.maxRangeRows'
            , [MaxStepRows] float N'$.maxStepRows',[DominantStepPercent] decimal(19,6) N'$.dominantStepPercent'
            , [TailStepRows] float N'$.tailStepRows',[TailStepPercent] decimal(19,6) N'$.tailStepPercent'
            , [CollectionStatus] varchar(40) N'$.collectionStatus'
        );
        INSERT [#ExecutionPlanAnalysis_HistogramSteps]
        SELECT *
        FROM OPENJSON(@EvidenceForAnalysis,N'$.statistics.histogramSteps')
        WITH
        (
              [DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
            , [ObjectName] sysname N'$.objectName',[StatisticsName] sysname N'$.statisticsName'
            , [StatisticsId] int N'$.statisticsId',[LeadingColumnName] sysname N'$.leadingColumnName'
            , [StepOrdinal] int N'$.stepOrdinal',[RangeHighKey] nvarchar(4000) N'$.rangeHighKey'
            , [RangeHighKeyToken] varbinary(32) N'$.rangeHighKeyToken'
            , [RangeRows] float N'$.rangeRows',[EqualRows] float N'$.equalRows'
            , [DistinctRangeRows] bigint N'$.distinctRangeRows',[AverageRangeRows] float N'$.averageRangeRows'
            , [IsPredicateTarget] bit N'$.isPredicateTarget',[PredicateMatchCount] int N'$.predicateMatchCount'
            , [SensitiveValueStatus] varchar(40) N'$.sensitiveValueStatus'
        );
        INSERT [#ExecutionPlanAnalysis_PredicateHistogramMappings]
        SELECT *
        FROM OPENJSON(@EvidenceForAnalysis,N'$.predicateHistogramMappings')
        WITH
        (
              [PredicateReferenceId] bigint N'$.predicateReferenceId',[StatementOrdinal] int N'$.statementOrdinal'
            , [NodeId] int N'$.nodeId',[DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
            , [ObjectName] sysname N'$.objectName',[ColumnName] sysname N'$.columnName'
            , [StatisticsName] sysname N'$.statisticsName',[PredicateKind] varchar(40) N'$.predicateKind'
            , [ValueSource] varchar(32) N'$.valueSource',[MappingStatus] varchar(48) N'$.mappingStatus'
            , [MappingConfidence] varchar(16) N'$.mappingConfidence',[MatchedStepOrdinal] int N'$.matchedStepOrdinal'
            , [MatchesRangeHighKey] bit N'$.matchesRangeHighKey',[IsBelowHistogram] bit N'$.isBelowHistogram'
            , [IsAboveHistogram] bit N'$.isAboveHistogram',[SensitiveValueStatus] varchar(40) N'$.sensitiveValueStatus'
        );
    END;

    IF @StatementId IS NOT NULL
    BEGIN
        DELETE FROM [#ExecutionPlanAnalysis_PlanWarnings]
        WHERE [StatementOrdinal] IS NOT NULL AND ([StatementId]<>@StatementId OR [StatementId] IS NULL);
        DELETE FROM [#ExecutionPlanAnalysis_OptimizerContext]
        WHERE [StatementOrdinal] IS NOT NULL AND ([StatementId]<>@StatementId OR [StatementId] IS NULL);
        DELETE FROM [#ExecutionPlanAnalysis_RuntimeFeedback]
        WHERE [StatementOrdinal] IS NOT NULL AND ([StatementId]<>@StatementId OR [StatementId] IS NULL);
        DELETE FROM [#ExecutionPlanAnalysis_FeedbackAndVariants]
        WHERE [StatementOrdinal] IS NOT NULL AND ([StatementId]<>@StatementId OR [StatementId] IS NULL);
        DELETE FROM [#ExecutionPlanAnalysis_Findings] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_ExecutionEvidence] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementId]=@StatementId);
        DELETE FROM [#ExecutionPlanAnalysis_MemoryAndSpills] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_Parameters] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_ParameterEvidence]
        WHERE [EvidenceKind]='PARAMETER'
          AND ([StatementId]<>@StatementId OR [StatementId] IS NULL);
        DELETE FROM [#ExecutionPlanAnalysis_StatisticsUsage] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_AccessPaths] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_Operators] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
        DELETE FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementId]<>@StatementId OR [StatementId] IS NULL;
    END;

    IF @StatementQueryHash IS NOT NULL
    BEGIN
        DECLARE @QueryHashText nvarchar(130)=CONVERT(nvarchar(130),@StatementQueryHash,1);
        DELETE FROM [#ExecutionPlanAnalysis_PlanWarnings] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_OptimizerContext] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_RuntimeFeedback] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_FeedbackAndVariants] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Findings] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_MemoryAndSpills] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Parameters] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_ParameterEvidence]
        WHERE [EvidenceKind]='PARAMETER'
          AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_StatisticsUsage] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_AccessPaths] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Operators] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]=@QueryHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryHash]<>@QueryHashText OR [StatementQueryHash] IS NULL;
    END;

    IF @StatementQueryPlanHash IS NOT NULL
    BEGIN
        DECLARE @QueryPlanHashText nvarchar(130)=CONVERT(nvarchar(130),@StatementQueryPlanHash,1);
        DELETE FROM [#ExecutionPlanAnalysis_PlanWarnings] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_OptimizerContext] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_RuntimeFeedback] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_FeedbackAndVariants] WHERE [StatementOrdinal] IS NOT NULL AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Findings] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_MemoryAndSpills] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Parameters] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_ParameterEvidence]
        WHERE [EvidenceKind]='PARAMETER'
          AND [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_StatisticsUsage] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_AccessPaths] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Operators] WHERE [StatementOrdinal] NOT IN
            (SELECT [StatementOrdinal] FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]=@QueryPlanHashText);
        DELETE FROM [#ExecutionPlanAnalysis_Statements] WHERE [StatementQueryPlanHash]<>@QueryPlanHashText OR [StatementQueryPlanHash] IS NULL;
    END;

    IF @MitSqlText=0 UPDATE [#ExecutionPlanAnalysis_Statements] SET [StatementText]=NULL;

    /* Sensitive Histogrammwerte nochmals am öffentlichen Ausgaberand sichern.
       Der Evidence-Generator hat sie bereits normalisiert; diese Projektion ist
       bewusst Defense in Depth für spätere interne Integrationspfade. */
    IF @PrivacyMode<>'RAW'
        UPDATE [#ExecutionPlanAnalysis_HistogramSteps] SET [RangeHighKey]=NULL;
    IF @PrivacyMode<>'TOKENIZED'
        UPDATE [#ExecutionPlanAnalysis_HistogramSteps] SET [RangeHighKeyToken]=NULL;

    /* Histogramm- und Predicate-Identifier passieren unabhängig vom Modus
       immer diese Ausgaberandprojektion. Die fachliche Korrelation ist zu
       diesem Zeitpunkt abgeschlossen. */
    UPDATE [#ExecutionPlanAnalysis_HistogramSummaries]
    SET [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1)) END,
        [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1)) END,
        [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1)) END,
        [StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[StatisticsName])),1)) END,
        [LeadingColumnName]=CASE @IdentifierMode WHEN 'RAW' THEN [LeadingColumnName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[LeadingColumnName])),1)) END;
    UPDATE [#ExecutionPlanAnalysis_HistogramSteps]
    SET [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1)) END,
        [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1)) END,
        [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1)) END,
        [StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[StatisticsName])),1)) END,
        [LeadingColumnName]=CASE @IdentifierMode WHEN 'RAW' THEN [LeadingColumnName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[LeadingColumnName])),1)) END;
    UPDATE [#ExecutionPlanAnalysis_PredicateHistogramMappings]
    SET [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1)) END,
        [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1)) END,
        [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1)) END,
        [ColumnName]=CASE @IdentifierMode WHEN 'RAW' THEN [ColumnName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ColumnName])),1)) END,
        [StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[StatisticsName])),1)) END;

    /* Weitere Identifikatoren erst nach fachlicher Korrelation schützen. */
    IF @IdentifierMode IN ('TOKENIZED','OMIT')
    BEGIN
        UPDATE [#ExecutionPlanAnalysis_Operators]
        SET [ObjectDatabaseName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [ObjectDatabaseName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectDatabaseName])),1) END,
            [ObjectSchemaName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [ObjectSchemaName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectSchemaName])),1) END,
            [ObjectName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [ObjectName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1) END,
            [IndexName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [IndexName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[IndexName])),1) END;
        UPDATE [#ExecutionPlanAnalysis_AccessPaths]
        SET [DatabaseName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [DatabaseName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1) END,
            [SchemaName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [SchemaName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1) END,
            [ObjectName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [ObjectName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1) END,
            [IndexName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [IndexName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[IndexName])),1) END;
        UPDATE [#ExecutionPlanAnalysis_StatisticsUsage]
        SET [DatabaseName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [DatabaseName] IS NOT NULL THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1)) END,
            [SchemaName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [SchemaName] IS NOT NULL THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1)) END,
            [ObjectName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [ObjectName] IS NOT NULL THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1)) END,
            [StatisticsName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [StatisticsName] IS NOT NULL THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[StatisticsName])),1)) END;
        UPDATE [#ExecutionPlanAnalysis_Parameters]
        SET [ParameterName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [ParameterName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ParameterName])),1) END;
        UPDATE [#ExecutionPlanAnalysis_ParameterEvidence]
        SET [ParameterName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [ParameterName] IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ParameterName])),1) END,
            [QueryStoreDatabaseName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [QueryStoreDatabaseName] IS NOT NULL THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[QueryStoreDatabaseName])),1)) END;
        UPDATE [#ExecutionPlanAnalysis_QueryStoreContext]
        SET [QueryStoreDatabaseName]=CASE WHEN @IdentifierMode='TOKENIZED' AND [QueryStoreDatabaseName] IS NOT NULL
            THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[QueryStoreDatabaseName])),1)) END;
    END;

    IF (SELECT COUNT(*) FROM [#ExecutionPlanAnalysis_Operators])>@MaxOperatoren
    BEGIN
        CREATE TABLE [#ExecutionPlanAnalysis_RetainedOperators]
        (
              [AnalysisObjectId] int NOT NULL
            , [StatementOrdinal] int NOT NULL
            , [NodeId] int NOT NULL
            , PRIMARY KEY ([AnalysisObjectId],[StatementOrdinal],[NodeId])
        );
        INSERT [#ExecutionPlanAnalysis_RetainedOperators]([AnalysisObjectId],[StatementOrdinal],[NodeId])
        SELECT TOP (@MaxOperatoren) [AnalysisObjectId],[StatementOrdinal],[NodeId]
        FROM [#ExecutionPlanAnalysis_Operators]
        ORDER BY [StatementOrdinal],[NodeId];

        DELETE [o]
        FROM [#ExecutionPlanAnalysis_Operators] AS [o]
        WHERE NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[o].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[o].[StatementOrdinal]
              AND [k].[NodeId]=[o].[NodeId]
        );
        DELETE [r]
        FROM [#ExecutionPlanAnalysis_OperatorRuntime] AS [r]
        WHERE NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[r].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[r].[StatementOrdinal]
              AND [k].[NodeId]=[r].[NodeId]
        );
        DELETE [r]
        FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime] AS [r]
        WHERE NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[r].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[r].[StatementOrdinal]
              AND [k].[NodeId]=[r].[NodeId]
        );
        DELETE [a]
        FROM [#ExecutionPlanAnalysis_AccessPaths] AS [a]
        WHERE [a].[NodeId] IS NOT NULL
          AND NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[a].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[a].[StatementOrdinal]
              AND [k].[NodeId]=[a].[NodeId]
        );
        DELETE [m]
        FROM [#ExecutionPlanAnalysis_MemoryAndSpills] AS [m]
        WHERE [m].[NodeId] IS NOT NULL
          AND NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[m].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[m].[StatementOrdinal]
              AND [k].[NodeId]=[m].[NodeId]
        );
        DELETE [f]
        FROM [#ExecutionPlanAnalysis_Findings] AS [f]
        WHERE [f].[NodeId] IS NOT NULL
          AND NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[f].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[f].[StatementOrdinal]
              AND [k].[NodeId]=[f].[NodeId]
        );
        DELETE [w]
        FROM [#ExecutionPlanAnalysis_PlanWarnings] AS [w]
        WHERE [w].[NodeId] IS NOT NULL
          AND NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[w].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[w].[StatementOrdinal]
              AND [k].[NodeId]=[w].[NodeId]
        );
        DELETE [r]
        FROM [#ExecutionPlanAnalysis_RuntimeFeedback] AS [r]
        WHERE [r].[NodeId] IS NOT NULL
          AND NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[r].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[r].[StatementOrdinal]
              AND [k].[NodeId]=[r].[NodeId]
        );
        DELETE [v]
        FROM [#ExecutionPlanAnalysis_FeedbackAndVariants] AS [v]
        WHERE [v].[NodeId] IS NOT NULL
          AND NOT EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_RetainedOperators] AS [k]
            WHERE [k].[AnalysisObjectId]=[v].[AnalysisObjectId]
              AND [k].[StatementOrdinal]=[v].[StatementOrdinal]
              AND [k].[NodeId]=[v].[NodeId]
        );
        SET @IsPartialOut=1;
        IF @StatusCodeOut='AVAILABLE' SET @StatusCodeOut='PARTIAL';
    END;
    IF (SELECT COUNT(*) FROM [#ExecutionPlanAnalysis_Findings])>@MaxFindings
    BEGIN
        DELETE [f]
        FROM [#ExecutionPlanAnalysis_Findings] AS [f]
        WHERE [f].[FindingOrdinal] NOT IN
        (
            SELECT TOP (@MaxFindings) [FindingOrdinal]
            FROM [#ExecutionPlanAnalysis_Findings]
            ORDER BY CASE [Severity] WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 4 ELSE 5 END,
                     [FindingOrdinal]
        );
        SET @IsPartialOut=1;
        IF @StatusCodeOut='AVAILABLE' SET @StatusCodeOut='PARTIAL';
    END;
    IF SYSUTCDATETIME()>@Deadline
    BEGIN
        SET @IsPartialOut=1;
        IF @StatusCodeOut='AVAILABLE' SET @StatusCodeOut='PARTIAL';
        IF @ErrorMessageOut IS NULL SET @ErrorMessageOut=N'Das kooperative Zeitbudget wurde während der Verarbeitung überschritten.';
    END;

    INSERT [#ExecutionPlanAnalysis_ModuleStatus]
    SELECT N'USP_ExecutionPlanAnalysis',@Now,@StatusCodeOut,@IsPartialOut,@EffectivePlanSource,@RuntimeScope,@Profile,
           (SELECT COUNT(*) FROM [#ExecutionPlanAnalysis_Statements]),(SELECT COUNT(*) FROM [#ExecutionPlanAnalysis_Operators]),(SELECT COUNT(*) FROM [#ExecutionPlanAnalysis_Findings]),
           @ErrorNumberOut,@ErrorMessageOut;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'ExecutionPlanAnalysis' [resultName],3 [schemaVersion],@Now [generatedAtUtc],@StatusCodeOut [statusCode],@IsPartialOut [isPartial],@EffectivePlanSource [planSource],@RuntimeScope [runtimeCounterScope],@Profile [workloadProfile],@PrivacyMode [evidencePrivacyMode],@IdentifierMode [identifierPrivacyMode] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @CapabilitiesJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_Capabilities] ORDER BY [FeatureCode] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @PlanJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_PlanDocuments] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @StatementsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_Statements] ORDER BY [StatementOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @OperatorsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_Operators] ORDER BY [StatementOrdinal],[NodeId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @RuntimeJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_OperatorRuntime] ORDER BY [StatementOrdinal],[NodeId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @ThreadsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime] ORDER BY [StatementOrdinal],[NodeId],[ThreadId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @AccessJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_AccessPaths] ORDER BY [StatementOrdinal],[NodeId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @StatsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_StatisticsUsage] ORDER BY [StatementOrdinal],[StatisticsUsageOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @ParametersJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_Parameters] ORDER BY [StatementOrdinal],[ParameterName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @ParameterEvidenceJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_ParameterEvidence] ORDER BY [CandidateId],[StatementOrdinal],[EvidenceKind],[ParameterName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @PlanWarningsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_PlanWarnings] ORDER BY [WarningOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @OptimizerContextJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_OptimizerContext] ORDER BY [StatementOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @RuntimeFeedbackJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_RuntimeFeedback] ORDER BY [FeedbackOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @QueryStoreContextJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_QueryStoreContext] ORDER BY [QueryStorePlanId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @FeedbackAndVariantsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_FeedbackAndVariants] ORDER BY [RecordOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @MemoryJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_MemoryAndSpills] ORDER BY [StatementOrdinal],[NodeId],[RecordType] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @EvidenceJsonOut nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_ExecutionEvidence] ORDER BY [StatementOrdinal],[EvidenceType],[MetricName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @HistogramSummaryJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_HistogramSummaries] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @HistogramStepsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_HistogramSteps] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @MappingsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_PredicateHistogramMappings] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @FindingsJson nvarchar(max)=(SELECT * FROM [#ExecutionPlanAnalysis_Findings] ORDER BY CASE [Severity] WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 4 ELSE 5 END,[FindingOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"capabilities":',COALESCE(@CapabilitiesJson,N'[]'),N',"planDocuments":',COALESCE(@PlanJson,N'[]'),N',"statements":',COALESCE(@StatementsJson,N'[]'),N',"operatorTree":',COALESCE(@OperatorsJson,N'[]'),N',"operatorRuntime":',COALESCE(@RuntimeJson,N'[]'),N',"operatorThreadRuntime":',COALESCE(@ThreadsJson,N'[]'),N',"accessPaths":',COALESCE(@AccessJson,N'[]'),N',"statisticsUsage":',COALESCE(@StatsJson,N'[]'),N',"parametersAndVariants":',COALESCE(@ParametersJson,N'[]'),N',"parameters":',COALESCE(@ParameterEvidenceJson,N'[]'),N',"planWarnings":',COALESCE(@PlanWarningsJson,N'[]'),N',"optimizerContext":',COALESCE(@OptimizerContextJson,N'[]'),N',"runtimeFeedback":',COALESCE(@RuntimeFeedbackJson,N'[]'),N',"queryStoreContext":',COALESCE(@QueryStoreContextJson,N'[]'),N',"feedbackAndVariants":',COALESCE(@FeedbackAndVariantsJson,N'[]'),N',"memoryAndSpills":',COALESCE(@MemoryJson,N'[]'),N',"executionEvidence":',COALESCE(@EvidenceJsonOut,N'[]'),N',"histogramSummaries":',COALESCE(@HistogramSummaryJson,N'[]'),N',"histogramSteps":',COALESCE(@HistogramStepsJson,N'[]'),N',"predicateHistogramMappings":',COALESCE(@MappingsJson,N'[]'),N',"findings":',COALESCE(@FindingsJson,N'[]'),N'}');
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT * FROM [#ExecutionPlanAnalysis_ModuleStatus];
        SELECT * FROM [#ExecutionPlanAnalysis_Capabilities] ORDER BY [FeatureCode];
        SELECT * FROM [#ExecutionPlanAnalysis_PlanDocuments];
        SELECT * FROM [#ExecutionPlanAnalysis_Statements] ORDER BY [StatementOrdinal];
        SELECT * FROM [#ExecutionPlanAnalysis_Operators] ORDER BY [StatementOrdinal],[NodeId];
        SELECT * FROM [#ExecutionPlanAnalysis_OperatorRuntime] ORDER BY [StatementOrdinal],[NodeId];
        SELECT * FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime] ORDER BY [StatementOrdinal],[NodeId],[ThreadId];
        SELECT * FROM [#ExecutionPlanAnalysis_AccessPaths] ORDER BY [StatementOrdinal],[NodeId];
        SELECT * FROM [#ExecutionPlanAnalysis_StatisticsUsage] ORDER BY [StatementOrdinal],[StatisticsUsageOrdinal];
        SELECT * FROM [#ExecutionPlanAnalysis_Parameters] ORDER BY [StatementOrdinal],[ParameterName];
        SELECT * FROM [#ExecutionPlanAnalysis_ParameterEvidence] ORDER BY [CandidateId],[StatementOrdinal],[EvidenceKind],[ParameterName];
        SELECT * FROM [#ExecutionPlanAnalysis_PlanWarnings] ORDER BY [WarningOrdinal];
        SELECT * FROM [#ExecutionPlanAnalysis_OptimizerContext] ORDER BY [StatementOrdinal];
        SELECT * FROM [#ExecutionPlanAnalysis_RuntimeFeedback] ORDER BY [FeedbackOrdinal];
        SELECT * FROM [#ExecutionPlanAnalysis_QueryStoreContext] ORDER BY [QueryStorePlanId];
        SELECT * FROM [#ExecutionPlanAnalysis_FeedbackAndVariants] ORDER BY [RecordOrdinal];
        SELECT * FROM [#ExecutionPlanAnalysis_MemoryAndSpills] ORDER BY [StatementOrdinal],[NodeId],[RecordType];
        SELECT * FROM [#ExecutionPlanAnalysis_ExecutionEvidence] ORDER BY [StatementOrdinal],[EvidenceType],[MetricName];
        SELECT * FROM [#ExecutionPlanAnalysis_HistogramSummaries];
        SELECT * FROM [#ExecutionPlanAnalysis_HistogramSteps];
        SELECT * FROM [#ExecutionPlanAnalysis_PredicateHistogramMappings];
        SELECT * FROM [#ExecutionPlanAnalysis_Findings] ORDER BY CASE [Severity] WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 4 ELSE 5 END,[FindingOrdinal];
    END;

    IF @ConsoleResultRequested=1
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ExecutionPlanAnalysis_Findings'
            , @ResultLabel=N'Execution Plan Finding'
            , @EmptyMessage=N'Keine Findings im gewählten Scope'
            , @StatusCode=@StatusCodeOut
            , @StatusMessage=@ErrorMessageOut;

    IF @TableRequested=1
    BEGIN
        DECLARE @ResultName sysname,@TargetTable sysname,@SourceTable sysname;
        DECLARE [OutputCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [ResultName],[TargetTable] FROM [#ExecutionPlanAnalysis_TableMap] ORDER BY [ResultName];
        OPEN [OutputCursor];
        FETCH NEXT FROM [OutputCursor] INTO @ResultName,@TargetTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @SourceTable=CASE @ResultName
                WHEN N'moduleStatus' THEN N'#ExecutionPlanAnalysis_ModuleStatus'
                WHEN N'capabilities' THEN N'#ExecutionPlanAnalysis_Capabilities'
                WHEN N'planDocuments' THEN N'#ExecutionPlanAnalysis_PlanDocuments'
                WHEN N'statements' THEN N'#ExecutionPlanAnalysis_Statements'
                WHEN N'operatorTree' THEN N'#ExecutionPlanAnalysis_Operators'
                WHEN N'operatorRuntime' THEN N'#ExecutionPlanAnalysis_OperatorRuntime'
                WHEN N'operatorThreadRuntime' THEN N'#ExecutionPlanAnalysis_OperatorThreadRuntime'
                WHEN N'accessPaths' THEN N'#ExecutionPlanAnalysis_AccessPaths'
                WHEN N'statisticsUsage' THEN N'#ExecutionPlanAnalysis_StatisticsUsage'
                WHEN N'parametersAndVariants' THEN N'#ExecutionPlanAnalysis_Parameters'
                WHEN N'parameters' THEN N'#ExecutionPlanAnalysis_ParameterEvidence'
                WHEN N'planWarnings' THEN N'#ExecutionPlanAnalysis_PlanWarnings'
                WHEN N'optimizerContext' THEN N'#ExecutionPlanAnalysis_OptimizerContext'
                WHEN N'runtimeFeedback' THEN N'#ExecutionPlanAnalysis_RuntimeFeedback'
                WHEN N'queryStoreContext' THEN N'#ExecutionPlanAnalysis_QueryStoreContext'
                WHEN N'feedbackAndVariants' THEN N'#ExecutionPlanAnalysis_FeedbackAndVariants'
                WHEN N'memoryAndSpills' THEN N'#ExecutionPlanAnalysis_MemoryAndSpills'
                WHEN N'executionEvidence' THEN N'#ExecutionPlanAnalysis_ExecutionEvidence'
                WHEN N'histogramSummaries' THEN N'#ExecutionPlanAnalysis_HistogramSummaries'
                WHEN N'histogramSteps' THEN N'#ExecutionPlanAnalysis_HistogramSteps'
                WHEN N'predicateHistogramMappings' THEN N'#ExecutionPlanAnalysis_PredicateHistogramMappings'
                WHEN N'findings' THEN N'#ExecutionPlanAnalysis_Findings' END;
            EXEC [monitor].[InternalWriteResultTable]
                  @SourceTable=@SourceTable,@TargetTable=@TargetTable,@ThrowOnError=1;
            FETCH NEXT FROM [OutputCursor] INTO @ResultName,@TargetTable;
        END;
        CLOSE [OutputCursor];DEALLOCATE [OutputCursor];
    END;

    IF @PrintMeldungen=1 AND @StatusCodeOut NOT IN ('AVAILABLE')
    BEGIN
        DECLARE @Message nvarchar(2048)=FORMATMESSAGE(N'WARNUNG USP_ExecutionPlanAnalysis: %s - %s',@StatusCodeOut,COALESCE(@ErrorMessageOut,N'partielle Analyse'));
        RAISERROR(N'%s',10,1,@Message) WITH NOWAIT;
    END;
END;
GO
