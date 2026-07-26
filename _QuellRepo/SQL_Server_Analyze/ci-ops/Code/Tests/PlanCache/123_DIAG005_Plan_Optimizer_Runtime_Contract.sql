USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 123_DIAG005_Plan_Optimizer_Runtime_Contract.sql
Zweck        : Prüft die fünf kanonischen DIAG-005-Resultsets für Einplan-,
               Mehrplan-, JSON- und TABLE-Ausgabe auf SQL Server 2019+.
Datenschutz  : Ausschließlich synthetische Example-Werte und ein nicht
               auflösbares synthetisches Planhandle.
===============================================================================
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @ExamplePlan xml=N'
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.600" Build="17.0.1000.1">
  <BatchSequence><Batch><Statements>
    <StmtSimple StatementId="1" StatementCompId="1" StatementType="SELECT"
      StatementText="SELECT ExampleValue FROM ExampleSchema.ExampleObject"
      StatementSubTreeCost="2.5" StatementEstRows="10" StatementOptmLevel="FULL"
      StatementOptmEarlyAbortReason="TimeOut" RetrievedFromCache="true"
      QueryVariantID="1" QueryHash="0x0303030303030303" QueryPlanHash="0x3333333333333333">
      <QueryPlan CardinalityEstimationModelVersion="170" CompileTime="5" CompileCPU="4"
        CompileMemory="256" DegreeOfParallelism="4" NonParallelPlanReason="">
        <MemoryGrantInfo RequestedMemory="8192" GrantedMemory="8192" MaxUsedMemory="2048"
          GrantWaitTime="0" IsMemoryGrantFeedbackAdjusted="Yes: Adjusting" />
        <ParameterSensitivePredicate />
        <RelOp NodeId="0" PhysicalOp="Select" LogicalOp="Select" EstimateRows="10"
          EstimatedTotalSubtreeCost="2.5">
          <Warnings NoJoinPredicate="1" />
          <RunTimeInformation>
            <RunTimeCountersPerThread Thread="0" ActualRows="100" ActualRowsRead="100"
              ActualExecutions="1" ActualLogicalReads="12" ActualCPUms="2" ActualElapsedms="3" />
          </RunTimeInformation>
          <Select>
            <RelOp NodeId="1" PhysicalOp="Adaptive Join" LogicalOp="Inner Join"
              EstimateRows="10" EstimatedExecutionMode="Batch" ActualExecutionMode="Batch"
              EstimatedTotalSubtreeCost="2.0">
              <RunTimeInformation>
                <RunTimeCountersPerThread Thread="0" ActualRows="100" ActualRowsRead="120"
                  ActualExecutions="1" ActualLogicalReads="10" ActualCPUms="1" ActualElapsedms="2" />
              </RunTimeInformation>
              <AdaptiveJoin />
            </RelOp>
          </Select>
        </RelOp>
      </QueryPlan>
    </StmtSimple>
  </Statements></Batch></BatchSequence>
</ShowPlanXML>';

DECLARE
      @Json nvarchar(max)
    , @Status varchar(40)
    , @Partial bit
    , @ErrorNumber int
    , @ErrorMessage nvarchar(2048);

EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@ExamplePlan
    , @EvidenzDatenschutzModus='DERIVED_ONLY'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Status OUTPUT
    , @IsPartialOut=@Partial OUTPUT
    , @ErrorNumberOut=@ErrorNumber OUTPUT
    , @ErrorMessageOut=@ErrorMessage OUTPUT;

IF @Status NOT IN ('AVAILABLE','PARTIAL')
   OR ISJSON(@Json)<>1
   OR TRY_CONVERT(int,JSON_VALUE(@Json,N'$.meta.schemaVersion'))<>3
   OR JSON_QUERY(@Json,N'$.planWarnings') IS NULL
   OR JSON_QUERY(@Json,N'$.optimizerContext') IS NULL
   OR JSON_QUERY(@Json,N'$.runtimeFeedback') IS NULL
   OR JSON_QUERY(@Json,N'$.queryStoreContext') IS NULL
   OR JSON_QUERY(@Json,N'$.feedbackAndVariants') IS NULL
    THROW 53660,N'Der kanonische DIAG-005-JSON-Vertrag ist nicht verfügbar.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.planWarnings')
    WITH
    (
          [WarningCode] varchar(100) N'$.WarningCode'
        , [EvidenceKind] varchar(40) N'$.EvidenceKind'
        , [PlanSource] varchar(24) N'$.PlanSource'
        , [FalsePositiveGuard] nvarchar(2000) N'$.FalsePositiveGuard'
        , [StatusCode] varchar(40) N'$.StatusCode'
    )
    WHERE [WarningCode]='OPTIMIZER_TIMEOUT'
      AND [EvidenceKind]='COMPILE_WARNING'
      AND [PlanSource]='IMPORTED'
      AND [FalsePositiveGuard] IS NOT NULL
      AND [StatusCode]='AVAILABLE'
)
    THROW 53661,N'planWarnings normalisiert die explizite Compilewarnung nicht korrekt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.optimizerContext')
    WITH
    (
          [EarlyAbortReason] nvarchar(256) N'$.EarlyAbortReason'
        , [PlanDegreeOfParallelism] int N'$.PlanDegreeOfParallelism'
        , [EvidenceMeasurement] varchar(40) N'$.EvidenceMeasurement'
        , [StatusCode] varchar(40) N'$.StatusCode'
        , [FalsePositiveGuard] nvarchar(1000) N'$.FalsePositiveGuard'
    )
    WHERE [EarlyAbortReason]=N'TimeOut'
      AND [PlanDegreeOfParallelism]=4
      AND [EvidenceMeasurement]='PLAN_MEASURED'
      AND [StatusCode]='PLAN_ONLY'
      AND [FalsePositiveGuard] IS NOT NULL
)
    THROW 53662,N'optimizerContext trennt Plan- und Cacheevidenz nicht korrekt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.runtimeFeedback')
    WITH
    (
          [FeedbackType] varchar(40) N'$.FeedbackType'
        , [ObservedValue] decimal(38,4) N'$.ObservedValue'
        , [BaselineValue] decimal(38,4) N'$.BaselineValue'
        , [RuntimeCounterScope] varchar(32) N'$.RuntimeCounterScope'
        , [IsMeasured] bit N'$.IsMeasured'
        , [IsDerived] bit N'$.IsDerived'
        , [StatusCode] varchar(40) N'$.StatusCode'
    )
    WHERE [FeedbackType]='CARDINALITY_OBSERVATION'
      AND [ObservedValue]=100
      AND [BaselineValue]=10
      AND [RuntimeCounterScope]='IMPORTED_ACTUAL'
      AND [IsMeasured]=1
      AND [IsDerived]=1
      AND [StatusCode]='AVAILABLE'
)
    THROW 53663,N'runtimeFeedback bewahrt Messung, Ableitung und Runtime-Scope nicht.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.queryStoreContext')
    WITH
    (
          [StatusCode] varchar(40) N'$.StatusCode'
        , [IsCurrent] bit N'$.IsCurrent'
        , [IsLastKnown] bit N'$.IsLastKnown'
    )
    WHERE [StatusCode]='NOT_APPLICABLE'
      AND [IsCurrent]=0
      AND [IsLastKnown]=0
)
    THROW 53664,N'queryStoreContext trennt eine nicht angeforderte Quelle nicht explizit.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.feedbackAndVariants')
    WITH
    (
          [FeatureType] varchar(60) N'$.FeatureType'
        , [DataHandlingStatus] varchar(40) N'$.DataHandlingStatus'
        , [EvidenceSource] varchar(40) N'$.EvidenceSource'
        , [FeatureData] nvarchar(max) N'$.FeatureData'
        , [StatusCode] varchar(40) N'$.StatusCode'
    )
    WHERE [FeatureType]='PARAMETER_SENSITIVE_PLAN'
      AND [DataHandlingStatus]='NO_SENSITIVE_PAYLOAD'
      AND [EvidenceSource]='PLAN_XML'
      AND [FeatureData] IS NULL
      AND [StatusCode]='AVAILABLE'
)
OR NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.feedbackAndVariants')
    WITH ([FeatureType] varchar(60) N'$.FeatureType',[StatusCode] varchar(40) N'$.StatusCode')
    WHERE [FeatureType] IN ('MEMORY_GRANT_FEEDBACK','ADAPTIVE_JOIN','BATCH_MODE')
      AND [StatusCode]='AVAILABLE'
)
    THROW 53665,N'feedbackAndVariants erkennt unterstützte Planmerkmale nicht.',1;

DECLARE @FilteredWarningsJson nvarchar(max);
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@ExamplePlan
    , @MinSchweregrad='CRITICAL'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@FilteredWarningsJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Status OUTPUT
    , @IsPartialOut=@Partial OUTPUT
    , @ErrorNumberOut=@ErrorNumber OUTPUT
    , @ErrorMessageOut=@ErrorMessage OUTPUT;

IF JSON_VALUE(@FilteredWarningsJson,N'$.planWarnings[0].WarningCode')
   <>N'NO_WARNING_AT_OR_ABOVE_THRESHOLD'
   OR JSON_VALUE(@FilteredWarningsJson,N'$.planWarnings[0].StatusCode')<>N'AVAILABLE'
    THROW 53670,N'Der Warnungsfilter wird fälschlich als fehlende Planquelle klassifiziert.',1;

CREATE TABLE [#123_DIAG005_Plan_Optimizer_Runtime_Contract_PlanWarnings]([SeedColumn] bit NULL);
CREATE TABLE [#123_DIAG005_Plan_Optimizer_Runtime_Contract_OptimizerContext]([SeedColumn] bit NULL);
CREATE TABLE [#123_DIAG005_Plan_Optimizer_Runtime_Contract_RuntimeFeedback]([SeedColumn] bit NULL);
CREATE TABLE [#123_DIAG005_Plan_Optimizer_Runtime_Contract_QueryStoreContext]([SeedColumn] bit NULL);
CREATE TABLE [#123_DIAG005_Plan_Optimizer_Runtime_Contract_FeedbackAndVariants]([SeedColumn] bit NULL);

EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@ExamplePlan
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{
        "planWarnings":"#123_DIAG005_Plan_Optimizer_Runtime_Contract_PlanWarnings",
        "optimizerContext":"#123_DIAG005_Plan_Optimizer_Runtime_Contract_OptimizerContext",
        "runtimeFeedback":"#123_DIAG005_Plan_Optimizer_Runtime_Contract_RuntimeFeedback",
        "queryStoreContext":"#123_DIAG005_Plan_Optimizer_Runtime_Contract_QueryStoreContext",
        "feedbackAndVariants":"#123_DIAG005_Plan_Optimizer_Runtime_Contract_FeedbackAndVariants"
      }'
    , @JsonErzeugen=0
    , @PrintMeldungen=0
    , @StatusCodeOut=@Status OUTPUT
    , @IsPartialOut=@Partial OUTPUT
    , @ErrorNumberOut=@ErrorNumber OUTPUT
    , @ErrorMessageOut=@ErrorMessage OUTPUT;

IF NOT EXISTS(SELECT 1 FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_PlanWarnings])
   OR NOT EXISTS(SELECT 1 FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_OptimizerContext])
   OR NOT EXISTS(SELECT 1 FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_RuntimeFeedback])
   OR NOT EXISTS(SELECT 1 FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_QueryStoreContext])
   OR NOT EXISTS(SELECT 1 FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_FeedbackAndVariants])
    THROW 53666,N'Der TABLE-Vertrag liefert nicht alle fünf DIAG-005-Resultsets.',1;

IF EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#123_DIAG005_Plan_Optimizer_Runtime_Contract_%'
      AND [c].[name]=N'SeedColumn'
)
OR NOT EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#123_DIAG005_Plan_Optimizer_Runtime_Contract_OptimizerContext%'
      AND [c].[name]=N'FalsePositiveGuard'
)
    THROW 53667,N'Die DIAG-005-TABLE-Schemas stimmen nicht mit dem Inventar überein.',1;

DECLARE @MissingPlanHandle varbinary(64)=CONVERT(varbinary(64),REPLICATE('04',64),2);
DECLARE @ShowplanJson nvarchar(max);
EXEC [monitor].[USP_ShowplanAnalysis]
      @PlanHandle=@MissingPlanHandle
    , @PlanQuelle='COMPILE'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@ShowplanJson OUTPUT
    , @PrintMeldungen=0;

IF ISJSON(@ShowplanJson)<>1
   OR TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.meta.schemaVersion'))<>4
   OR JSON_QUERY(@ShowplanJson,N'$.planWarnings') IS NULL
   OR COALESCE(JSON_VALUE(@ShowplanJson,N'$.planWarnings[0].StatusCode'),N'')<>N'NOT_COLLECTED'
   OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.planWarnings[0].CandidateId')),0)<>1
   OR JSON_QUERY(@ShowplanJson,N'$.optimizerContext') IS NULL
   OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.optimizerContext[0].CandidateId')),0)<>1
   OR JSON_QUERY(@ShowplanJson,N'$.runtimeFeedback') IS NULL
   OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.runtimeFeedback[0].CandidateId')),0)<>1
   OR JSON_QUERY(@ShowplanJson,N'$.queryStoreContext') IS NULL
   OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.queryStoreContext[0].CandidateId')),0)<>1
   OR JSON_QUERY(@ShowplanJson,N'$.feedbackAndVariants') IS NULL
   OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.feedbackAndVariants[0].CandidateId')),0)<>1
    THROW 53668,N'USP_ShowplanAnalysis aggregiert den DIAG-005-Statusvertrag nicht kandidatengenau.',1;

DECLARE @MissingQueryStoreJson nvarchar(max),@ExampleDatabase sysname=N'DeineDatenbank';
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @QueryStoreDatabaseName=@ExampleDatabase
    , @QueryStorePlanId=-1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@MissingQueryStoreJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Status OUTPUT
    , @IsPartialOut=@Partial OUTPUT
    , @ErrorNumberOut=@ErrorNumber OUTPUT
    , @ErrorMessageOut=@ErrorMessage OUTPUT;

IF ISJSON(@MissingQueryStoreJson)<>1
   OR JSON_VALUE(@MissingQueryStoreJson,N'$.queryStoreContext[0].StatusCode') NOT IN
      (N'NOT_COLLECTED',N'DENIED_PERMISSION')
    THROW 53669,N'Der versionsadaptive Query-Store-Planpfad liefert keinen expliziten Quellstatus.',1;

SELECT
      N'DIAG005PlanOptimizerContext' AS [ContractName]
    , N'PASS' AS [StatusCode]
    , (SELECT COUNT_BIG(*) FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_PlanWarnings]) AS [WarningRowCount]
    , (SELECT COUNT_BIG(*) FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_RuntimeFeedback]) AS [RuntimeFeedbackRowCount]
    , (SELECT COUNT_BIG(*) FROM [#123_DIAG005_Plan_Optimizer_Runtime_Contract_FeedbackAndVariants]) AS [FeatureRowCount];
GO
