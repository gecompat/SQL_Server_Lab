USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 120_ExecutionPlanAnalysis_Runtime_Contract.sql
Zweck        : Prüft die eigenständige Plananalyse ausschließlich mit einem
               synthetischen Plan-XML und synthetischer Ausführungsevidenz.
Datenschutz  : Keine realen SQL-, Objekt-, Parameter- oder Histogrammwerte.
===============================================================================
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @Plan xml=N'
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.600" Build="17.0.1000.1">
  <BatchSequence><Batch><Statements>
    <StmtSimple StatementId="1" StatementCompId="1" StatementType="SELECT" StatementText="SELECT ExampleColumn FROM ExampleSchema.ExampleObject" StatementSubTreeCost="1.0" StatementEstRows="10" StatementOptmLevel="FULL" QueryHash="0x0101010101010101" QueryPlanHash="0x1111111111111111">
      <QueryPlan CardinalityEstimationModelVersion="170" CompileTime="2" CompileCPU="2" CompileMemory="128">
        <MemoryGrantInfo RequestedMemory="20480" GrantedMemory="20480" MaxUsedMemory="1024" GrantWaitTime="0" />
        <OptimizerStatsUsage><StatisticsInfo Database="[ExampleDatabase]" Schema="[ExampleSchema]" Table="[ExampleObject]" Statistics="[ExampleStatistics]" LastUpdate="2026-01-01T00:00:00" ModificationCount="0" SamplingPercent="100" /></OptimizerStatsUsage>
        <RelOp NodeId="0" PhysicalOp="Select" LogicalOp="Select" EstimateRows="10" EstimatedTotalSubtreeCost="1.0">
          <OutputList><ColumnReference Database="[ExampleDatabase]" Schema="[ExampleSchema]" Table="[ExampleObject]" Column="[ExampleColumn]" /></OutputList>
          <Select>
            <RelOp NodeId="1" PhysicalOp="Index Seek" LogicalOp="Index Seek" EstimateRows="10" EstimatedRowsRead="100" EstimateExecutions="1" EstimatedTotalSubtreeCost="0.9">
              <RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="10" ActualRowsRead="100" ActualExecutions="1" ActualLogicalReads="8" ActualCPUms="1" ActualElapsedms="2" /></RunTimeInformation>
              <IndexScan Ordered="1" ScanDirection="FORWARD"><Object Database="[ExampleDatabase]" Schema="[ExampleSchema]" Table="[ExampleObject]" Index="[ExampleIndex]" Storage="RowStore" /></IndexScan>
            </RelOp>
          </Select>
        </RelOp>
        <ParameterList><ColumnReference Column="@ExampleParameter" ParameterDataType="int" ParameterCompiledValue="(7)" ParameterRuntimeValue="(9)" /></ParameterList>
      </QueryPlan>
    </StmtSimple>
    <StmtSimple StatementId="2" StatementCompId="2" StatementType="SELECT" StatementText="SELECT ExampleOtherColumn FROM ExampleSchema.ExampleOtherObject" StatementSubTreeCost="0.1" StatementEstRows="1" StatementOptmLevel="TRIVIAL" QueryHash="0x0202020202020202" QueryPlanHash="0x2222222222222222">
      <QueryPlan CardinalityEstimationModelVersion="170" CompileTime="1" CompileCPU="1" CompileMemory="64">
        <RelOp NodeId="0" PhysicalOp="Select" LogicalOp="Select" EstimateRows="1" EstimatedTotalSubtreeCost="0.1">
          <Select><RelOp NodeId="1" PhysicalOp="Constant Scan" LogicalOp="Constant Scan" EstimateRows="1" EstimatedTotalSubtreeCost="0.0"><RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="1" ActualExecutions="1" /></RunTimeInformation><ConstantScan /></RelOp></Select>
        </RelOp>
      </QueryPlan>
    </StmtSimple>
  </Statements></Batch></BatchSequence>
</ShowPlanXML>';

DECLARE @AnalysisJson nvarchar(max),@Status varchar(40),@Partial bit,@Error int,@Message nvarchar(2048);
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@Plan
    , @WorkloadProfil='BALANCED'
    , @MitThreadRuntime=1
    , @MitSqlText=0
    , @IdentifierDatenschutzModus='RAW'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@AnalysisJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Status OUTPUT
    , @IsPartialOut=@Partial OUTPUT
    , @ErrorNumberOut=@Error OUTPUT
    , @ErrorMessageOut=@Message OUTPUT;

IF @Status NOT IN ('AVAILABLE','PARTIAL') OR ISJSON(@AnalysisJson)<>1
    THROW 53600,N'Die eigenständige Plananalyse lieferte keinen gültigen Vertrag.',1;
IF TRY_CONVERT(int,JSON_VALUE(@AnalysisJson,N'$.meta.schemaVersion'))<>3
   OR JSON_VALUE(@AnalysisJson,N'$.meta.resultName')<>N'ExecutionPlanAnalysis'
   OR JSON_VALUE(@AnalysisJson,N'$.meta.evidencePrivacyMode')<>N'DERIVED_ONLY'
   OR JSON_VALUE(@AnalysisJson,N'$.meta.identifierPrivacyMode')<>N'RAW'
   OR JSON_QUERY(@AnalysisJson,N'$.capabilities') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.planDocuments') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.statements') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.operatorTree') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.operatorRuntime') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.parameters') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.planWarnings') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.optimizerContext') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.runtimeFeedback') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.queryStoreContext') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.feedbackAndVariants') IS NULL
   OR JSON_QUERY(@AnalysisJson,N'$.findings') IS NULL
    THROW 53610,N'Das ExecutionPlanAnalysis-JSON verletzt den eingefrorenen Top-Level-Vertrag.',1;
IF (SELECT COUNT(*) FROM OPENJSON(@AnalysisJson,N'$.statements'))<>2
    THROW 53601,N'Der Mehrstatementplan wurde nicht statementgenau zerlegt.',1;
IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@AnalysisJson,N'$.statements')
    WITH
    (
          [StatementOrdinal] int N'$.StatementOrdinal'
        , [StatementType] nvarchar(128) N'$.StatementType'
        , [StatementQueryHash] nvarchar(130) N'$.StatementQueryHash'
        , [StatementSubTreeCost] decimal(38,8) N'$.StatementSubTreeCost'
        , [OptimizationLevel] nvarchar(128) N'$.OptimizationLevel'
    )
    WHERE [StatementOrdinal]=1
      AND [StatementType]=N'SELECT'
      AND [StatementQueryHash]=N'0x0101010101010101'
      AND [StatementSubTreeCost]=CONVERT(decimal(38,8),1)
      AND [OptimizationLevel]=N'FULL'
)
    THROW 53609,N'Direkte Attribute des materialisierten StmtSimple-Elements wurden nicht korrekt gelesen.',1;
IF (SELECT COUNT(*) FROM OPENJSON(@AnalysisJson,N'$.operatorTree') WITH ([StatementOrdinal] int N'$.StatementOrdinal',[NodeId] int N'$.NodeId') WHERE [NodeId]=1)<>2
    THROW 53602,N'Gleiche NodeIds verschiedener Statements wurden nicht getrennt erhalten.',1;
IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@AnalysisJson,N'$.operatorRuntime')
    WITH
    (
          [StatementOrdinal] int N'$.StatementOrdinal'
        , [NodeId] int N'$.NodeId'
        , [PairedActualRows] decimal(38,4) N'$.PairedActualRows'
        , [PairedActualRowsRead] decimal(38,4) N'$.PairedActualRowsRead'
        , [RowsReadNotReturnedPercent] decimal(19,6) N'$.RowsReadNotReturnedPercent'
        , [RuntimeMetricStatus] varchar(40) N'$.RuntimeMetricStatus'
    )
    WHERE [StatementOrdinal]=1 AND [NodeId]=1
      AND [PairedActualRows]=10 AND [PairedActualRowsRead]=100
      AND [RowsReadNotReturnedPercent]=90
      AND [RuntimeMetricStatus]='AVAILABLE'
)
    THROW 53603,N'ActualRows und ActualRowsRead wurden nicht korrekt gepaart oder berechnet.',1;
IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@AnalysisJson,N'$.parametersAndVariants')
    WITH ([CompiledValue] nvarchar(4000) N'$.CompiledValue',[RuntimeValue] nvarchar(4000) N'$.RuntimeValue')
    WHERE [CompiledValue] IS NOT NULL OR [RuntimeValue] IS NOT NULL
)
    THROW 53604,N'DERIVED_ONLY hat konkrete Parameterwerte ausgegeben.',1;
IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@AnalysisJson,N'$.parameters')
    WITH
    (
          [EvidenceKind] varchar(24) N'$.EvidenceKind'
        , [ParameterName] nvarchar(256) N'$.ParameterName'
        , [CompiledValuePresent] bit N'$.CompiledValuePresent'
        , [RuntimeValuePresent] bit N'$.RuntimeValuePresent'
        , [CompiledValueIsSqlNull] bit N'$.CompiledValueIsSqlNull'
        , [RuntimeValueIsSqlNull] bit N'$.RuntimeValueIsSqlNull'
        , [CompiledValue] nvarchar(4000) N'$.CompiledValue'
        , [RuntimeValue] nvarchar(4000) N'$.RuntimeValue'
        , [CompiledValueStatus] varchar(40) N'$.CompiledValueStatus'
        , [RuntimeValueStatus] varchar(40) N'$.RuntimeValueStatus'
        , [ValueStatus] varchar(40) N'$.ValueStatus'
        , [ValueSource] varchar(40) N'$.ValueSource'
        , [SourceObservedAtUtc] datetime2(3) N'$.SourceObservedAtUtc'
        , [ValueCapturedAtUtc] datetime2(3) N'$.ValueCapturedAtUtc'
        , [IsCurrentExecution] bit N'$.IsCurrentExecution'
        , [IsLastKnownExecution] bit N'$.IsLastKnownExecution'
        , [IsComplete] bit N'$.IsComplete'
    )
    WHERE [EvidenceKind]='PARAMETER'
      AND [ParameterName]=N'@ExampleParameter'
      AND [CompiledValuePresent]=1
      AND [RuntimeValuePresent]=1
      AND [CompiledValueIsSqlNull]=0
      AND [RuntimeValueIsSqlNull]=0
      AND [CompiledValue] IS NULL
      AND [RuntimeValue] IS NULL
      AND [CompiledValueStatus]='AVAILABLE'
      AND [RuntimeValueStatus]='AVAILABLE'
      AND [ValueStatus]='AVAILABLE'
      AND [ValueSource]='IMPORTED_PLAN'
      AND [SourceObservedAtUtc] IS NOT NULL
      AND [ValueCapturedAtUtc] IS NULL
      AND [IsCurrentExecution] IS NULL
      AND [IsLastKnownExecution] IS NULL
      AND [IsComplete]=1
)
    THROW 53639,N'Der kanonische DIAG-003-Parametervertrag ist für vorhandene Compile-/Runtimewerte unvollständig.',1;
IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@AnalysisJson,N'$.parameters')
    WITH
    (
          [EvidenceKind] varchar(24) N'$.EvidenceKind'
        , [ValueStatus] varchar(40) N'$.ValueStatus'
        , [IsComplete] bit N'$.IsComplete'
    )
    WHERE [EvidenceKind]='SOURCE_BOUNDARY'
      AND [ValueStatus]='LOCAL_VARIABLE_NOT_EXPOSED'
      AND [IsComplete]=0
)
    THROW 53640,N'Die dokumentierte Grenze für lokale Variablen fehlt im DIAG-003-Vertrag.',1;
IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@AnalysisJson,N'$.statements')
    WITH ([StatementText] nvarchar(max) N'$.StatementText')
    WHERE [StatementText] IS NOT NULL
)
    THROW 53611,N'Der Default von @MitSqlText hat StatementText unerwartet ausgegeben.',1;

CREATE TABLE [#120_ExecutionPlanAnalysis_Runtime_Contract_ModuleStatus]
(
    [SeedColumn] bit NULL
);
CREATE TABLE [#120_ExecutionPlanAnalysis_Runtime_Contract_Parameters]
(
    [SeedColumn] bit NULL
);
SET @Status=NULL;SET @Partial=NULL;SET @Error=NULL;SET @Message=NULL;
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@Plan
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"moduleStatus":"#120_ExecutionPlanAnalysis_Runtime_Contract_ModuleStatus","parameters":"#120_ExecutionPlanAnalysis_Runtime_Contract_Parameters"}'
    , @JsonErzeugen=0
    , @PrintMeldungen=0
    , @StatusCodeOut=@Status OUTPUT
    , @IsPartialOut=@Partial OUTPUT
    , @ErrorNumberOut=@Error OUTPUT
    , @ErrorMessageOut=@Message OUTPUT;
IF @Status NOT IN ('AVAILABLE','PARTIAL')
   OR NOT EXISTS(SELECT 1 FROM [#120_ExecutionPlanAnalysis_Runtime_Contract_ModuleStatus])
   OR EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#120_ExecutionPlanAnalysis_Runtime_Contract_ModuleStatus%'
            AND [c].[name]=N'SeedColumn'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#120_ExecutionPlanAnalysis_Runtime_Contract_ModuleStatus%'
            AND [c].[name]=N'StatusCode'
      )
    THROW 53634,N'Der TABLE-Ausgabevertrag der eigenständigen Plananalyse ist fehlgeschlagen.',1;
IF NOT EXISTS
(
    SELECT 1
    FROM [#120_ExecutionPlanAnalysis_Runtime_Contract_Parameters]
    WHERE [EvidenceKind]='PARAMETER'
      AND [CompiledValuePresent]=1
      AND [RuntimeValuePresent]=1
)
   OR EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#120_ExecutionPlanAnalysis_Runtime_Contract_Parameters%'
            AND [c].[name]=N'SeedColumn'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#120_ExecutionPlanAnalysis_Runtime_Contract_Parameters%'
            AND [c].[name]=N'ValueStatus'
      )
    THROW 53641,N'Der TABLE-Vertrag des kanonischen DIAG-003-Resultsets ist fehlgeschlagen.',1;
GO

DECLARE @EvidenceJson nvarchar(max),@EvidenceStatus varchar(40),@EvidencePartial bit;
EXEC [monitor].[USP_CreateExecutionEvidenceJson]
      @StatisticsIoText=N'Table ''ExampleObject''. Scan count 1, logical reads 8, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.'
    , @StatisticsTimeText=N'SQL Server Execution Times: CPU time = 1 ms, elapsed time = 2 ms.'
    , @ResultSetArt='NONE'
    , @Json=@EvidenceJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@EvidenceStatus OUTPUT
    , @IsPartialOut=@EvidencePartial OUTPUT;
IF @EvidenceStatus NOT IN ('AVAILABLE','PARTIAL') OR ISJSON(@EvidenceJson)<>1
    THROW 53605,N'Der Evidence-Generator lieferte kein gültiges JSON.',1;
IF TRY_CONVERT(int,JSON_VALUE(@EvidenceJson,N'$.meta.schemaVersion'))<>1
   OR JSON_VALUE(@EvidenceJson,N'$.meta.resultName')<>N'ExecutionEvidence'
   OR JSON_QUERY(@EvidenceJson,N'$.statistics') IS NULL
   OR JSON_QUERY(@EvidenceJson,N'$.predicateHistogramMappings') IS NULL
   OR JSON_QUERY(@EvidenceJson,N'$.warnings') IS NULL
    THROW 53612,N'Das ExecutionEvidence-JSON verletzt den eingefrorenen Top-Level-Vertrag.',1;
IF TRY_CONVERT(bigint,JSON_VALUE(@EvidenceJson,N'$.statisticsIo[0].logicalReads'))<>8
    THROW 53606,N'STATISTICS IO wurde nicht strukturiert erkannt.',1;
IF TRY_CONVERT(bigint,JSON_VALUE(@EvidenceJson,N'$.statisticsTime[0].elapsedMs'))<>2
    THROW 53607,N'STATISTICS TIME wurde nicht strukturiert erkannt.',1;
IF JSON_VALUE(@EvidenceJson,N'$.statisticsIo[0].rawLine') IS NOT NULL
    THROW 53608,N'DERIVED_ONLY hat den Rohtext unerwartet ausgegeben.',1;

CREATE TABLE [#120_ExecutionPlanAnalysis_Runtime_Contract_CaptureStatus]
(
    [SeedColumn] bit NULL
);
SET @EvidenceStatus=NULL;SET @EvidencePartial=NULL;
EXEC [monitor].[USP_CreateExecutionEvidenceJson]
      @StatisticsIoText=N'Table ''ExampleObject''. Scan count 1, logical reads 8, physical reads 0, page server reads 0, read-ahead reads 0, page server read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob page server reads 0, lob read-ahead reads 0, lob page server read-ahead reads 0.'
    , @StatisticsTimeText=N'SQL Server Execution Times: CPU time = 1 ms, elapsed time = 2 ms.'
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"captureStatus":"#120_ExecutionPlanAnalysis_Runtime_Contract_CaptureStatus"}'
    , @JsonErzeugen=0
    , @PrintMeldungen=0
    , @StatusCodeOut=@EvidenceStatus OUTPUT
    , @IsPartialOut=@EvidencePartial OUTPUT;
IF @EvidenceStatus NOT IN ('AVAILABLE','PARTIAL')
   OR NOT EXISTS(SELECT 1 FROM [#120_ExecutionPlanAnalysis_Runtime_Contract_CaptureStatus])
   OR EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#120_ExecutionPlanAnalysis_Runtime_Contract_CaptureStatus%'
            AND [c].[name]=N'SeedColumn'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#120_ExecutionPlanAnalysis_Runtime_Contract_CaptureStatus%'
            AND [c].[name]=N'StatusCode'
      )
    THROW 53635,N'Der TABLE-Ausgabevertrag des eigenständigen Evidenzerzeugers ist fehlgeschlagen.',1;
GO

/* Öffentliche Datenschutzgrenzen und erneute Normalisierung importierter Evidenz. */
DECLARE @GuardPlan xml=N'
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.600" Build="17.0.1000.1">
  <BatchSequence><Batch><Statements>
    <StmtSimple StatementId="1" StatementCompId="1" StatementType="SELECT" StatementText="SELECT ExampleColumn FROM ExampleSchema.ExampleObject WHERE ExampleColumn = 7" StatementSubTreeCost="0.1" StatementEstRows="1" StatementOptmLevel="TRIVIAL">
      <QueryPlan CardinalityEstimationModelVersion="170">
        <RelOp NodeId="0" PhysicalOp="Constant Scan" LogicalOp="Constant Scan" EstimateRows="1" EstimatedTotalSubtreeCost="0.1"><ConstantScan /></RelOp>
      </QueryPlan>
    </StmtSimple>
  </Statements></Batch></BatchSequence>
</ShowPlanXML>';

DECLARE @GuardStatus varchar(40),@GuardPartial bit;
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@GuardPlan
    , @MitSqlText=1
    , @ResultSetArt='NONE'
    , @PrintMeldungen=0
    , @StatusCodeOut=@GuardStatus OUTPUT
    , @IsPartialOut=@GuardPartial OUTPUT;
IF @GuardStatus<>'SENSITIVE_DATA_CONFIRMATION_REQUIRED'
    THROW 53613,N'@MitSqlText=1 wurde ohne Sensitive-Data-Bestätigung nicht abgelehnt.',1;

SET @GuardStatus=NULL;
EXEC [monitor].[USP_CreateExecutionEvidenceJson]
      @StatisticsIoText=N'Table ''ExampleObject''. Scan count 1, logical reads 1, physical reads 0, read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.'
    , @RawTextHandling='INCLUDE'
    , @ResultSetArt='NONE'
    , @PrintMeldungen=0
    , @StatusCodeOut=@GuardStatus OUTPUT
    , @IsPartialOut=@GuardPartial OUTPUT;
IF @GuardStatus<>'SENSITIVE_DATA_CONFIRMATION_REQUIRED'
    THROW 53614,N'RawTextHandling INCLUDE wurde ohne Sensitive-Data-Bestätigung nicht abgelehnt.',1;

DECLARE @ImportedEvidence nvarchar(max)=N'{
  "statistics": {
    "currentSnapshot": [{
      "databaseName":"ExampleDatabase","schemaName":"ExampleSchema","objectName":"ExampleObject","objectId":1,
      "statisticsName":"ExampleStatistics","statisticsId":1,"isIndexStatistics":true,"isFiltered":true,
      "filterDefinition":"ExampleColumn = 7","leadingColumnName":"ExampleColumn","collectionStatus":"AVAILABLE"
    }],
    "histogramSummaries": [{
      "databaseName":"ExampleDatabase","schemaName":"ExampleSchema","objectName":"ExampleObject",
      "statisticsName":"ExampleStatistics","statisticsId":1,"leadingColumnName":"ExampleColumn",
      "histogramSteps":1,"histogramEstimatedRows":10,"maxEqualRows":5,"maxRangeRows":5,
      "maxStepRows":10,"dominantStepPercent":100,"tailStepRows":10,"tailStepPercent":100,
      "collectionStatus":"AVAILABLE"
    }],
    "histogramSteps": [{
      "databaseName":"ExampleDatabase","schemaName":"ExampleSchema","objectName":"ExampleObject",
      "statisticsName":"ExampleStatistics","statisticsId":1,"leadingColumnName":"ExampleColumn",
      "stepOrdinal":1,"rangeHighKey":"ExampleSensitiveBoundary","rangeRows":5,"equalRows":5,
      "distinctRangeRows":1,"averageRangeRows":5,"isPredicateTarget":true,"predicateMatchCount":1
    }]
  },
  "predicateHistogramMappings": [{
    "predicateReferenceId":1,"statementOrdinal":1,"nodeId":0,
    "databaseName":"ExampleDatabase","schemaName":"ExampleSchema","objectName":"ExampleObject",
    "columnName":"ExampleColumn","statisticsName":"ExampleStatistics","predicateKind":"EQUALITY",
    "valueSource":"COMPILED","mappingStatus":"MATCHED_STEP","mappingConfidence":"HIGH",
    "matchedStepOrdinal":1,"matchesRangeHighKey":true,"isBelowHistogram":false,"isAboveHistogram":false,
    "sensitiveValueStatus":"IMPORTED_RAW"
  }]
}';
DECLARE @SanitizedJson nvarchar(max);
SET @GuardStatus=NULL;
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@GuardPlan
    , @EvidenzJson=@ImportedEvidence
    , @IdentifierDatenschutzModus='OMIT'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@SanitizedJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@GuardStatus OUTPUT
    , @IsPartialOut=@GuardPartial OUTPUT;
IF @GuardStatus NOT IN ('AVAILABLE','PARTIAL') OR ISJSON(@SanitizedJson)<>1
    THROW 53615,N'Die erneute Normalisierung importierter Evidenz ist fehlgeschlagen.',1;
IF JSON_VALUE(@SanitizedJson,N'$.meta.evidencePrivacyMode')<>N'DERIVED_ONLY'
   OR JSON_VALUE(@SanitizedJson,N'$.meta.identifierPrivacyMode')<>N'OMIT'
    THROW 53638,N'Die Plananalyse weist nicht die angeforderten Datenschutzmodi aus.',1;
IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@SanitizedJson,N'$.histogramSteps') AS [j]
    WHERE JSON_VALUE([j].[value],N'$.DatabaseName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.SchemaName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.ObjectName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.StatisticsName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.LeadingColumnName') IS NOT NULL
)
    THROW 53616,N'OMIT hat Histogrammidentifikatoren ausgegeben.',1;
IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@SanitizedJson,N'$.histogramSteps')
    WITH ([RangeHighKey] nvarchar(4000) N'$.RangeHighKey')
    WHERE [RangeHighKey] IS NOT NULL
)
    THROW 53636,N'DERIVED_ONLY hat einen Histogrammgrenzwert ausgegeben.',1;
IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@SanitizedJson,N'$.histogramSteps')
    WITH ([RangeHighKeyToken] varbinary(32) N'$.RangeHighKeyToken')
    WHERE [RangeHighKeyToken] IS NOT NULL
)
    THROW 53637,N'DERIVED_ONLY hat einen Histogrammgrenzwert-Token ausgegeben.',1;
IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@SanitizedJson,N'$.predicateHistogramMappings') AS [j]
    WHERE JSON_VALUE([j].[value],N'$.DatabaseName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.SchemaName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.ObjectName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.ColumnName') IS NOT NULL
       OR JSON_VALUE([j].[value],N'$.StatisticsName') IS NOT NULL
)
    THROW 53617,N'OMIT hat Predicate-Histogramm-Identifikatoren ausgegeben.',1;
IF CHARINDEX(N'ExampleSensitiveBoundary',@SanitizedJson)>0
   OR CHARINDEX(N'ExampleDatabase',@SanitizedJson)>0
   OR CHARINDEX(N'ExampleStatistics',@SanitizedJson)>0
    THROW 53618,N'Die normalisierte Plananalyse enthält einen synthetischen Rohwert oder Rohidentifikator.',1;

DECLARE @TokenizedJson nvarchar(max);
SET @GuardStatus=NULL;
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@GuardPlan
    , @EvidenzJson=@ImportedEvidence
    , @EvidenzDatenschutzModus='TOKENIZED'
    , @IdentifierDatenschutzModus='TOKENIZED'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@TokenizedJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@GuardStatus OUTPUT
    , @IsPartialOut=@GuardPartial OUTPUT;
IF @GuardStatus NOT IN ('AVAILABLE','PARTIAL') OR ISJSON(@TokenizedJson)<>1
   OR JSON_VALUE(@TokenizedJson,N'$.meta.evidencePrivacyMode')<>N'TOKENIZED'
   OR JSON_VALUE(@TokenizedJson,N'$.meta.identifierPrivacyMode')<>N'TOKENIZED'
   OR JSON_VALUE(@TokenizedJson,N'$.histogramSteps[0].RangeHighKey') IS NOT NULL
   OR JSON_VALUE(@TokenizedJson,N'$.histogramSteps[0].RangeHighKeyToken') IS NULL
   OR JSON_VALUE(@TokenizedJson,N'$.histogramSteps[0].DatabaseName') IS NULL
   OR CHARINDEX(N'ExampleSensitiveBoundary',@TokenizedJson)>0
   OR CHARINDEX(N'ExampleDatabase',@TokenizedJson)>0
    THROW 53619,N'TOKENIZED hat Rohdaten ausgegeben oder keinen Capture-Token erzeugt.',1;

/* DIAG-003: SQL-NULL, Cache-Eviction und beendeter Request bleiben getrennt. */
DECLARE @NullPlan xml=N'
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.600" Build="17.0.1000.1">
  <BatchSequence><Batch><Statements>
    <StmtSimple StatementId="1" StatementCompId="1" StatementType="SELECT" StatementText="SELECT ExampleValue" StatementSubTreeCost="0.0" StatementEstRows="1" StatementOptmLevel="TRIVIAL">
      <QueryPlan CardinalityEstimationModelVersion="170">
        <RelOp NodeId="0" PhysicalOp="Constant Scan" LogicalOp="Constant Scan" EstimateRows="1" EstimatedTotalSubtreeCost="0.0"><ConstantScan /></RelOp>
        <ParameterList><ColumnReference Column="@ExampleNullableParameter" ParameterDataType="int" ParameterCompiledValue="(NULL)" ParameterRuntimeValue="(NULL)" /></ParameterList>
      </QueryPlan>
    </StmtSimple>
  </Statements></Batch></BatchSequence>
</ShowPlanXML>';
DECLARE @Diag003Json nvarchar(max),@Diag003Status varchar(40),@Diag003Partial bit,@Diag003Error int,@Diag003Message nvarchar(2048);
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@NullPlan
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Diag003Json OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Diag003Status OUTPUT
    , @IsPartialOut=@Diag003Partial OUTPUT
    , @ErrorNumberOut=@Diag003Error OUTPUT
    , @ErrorMessageOut=@Diag003Message OUTPUT;
IF @Diag003Status NOT IN ('AVAILABLE','PARTIAL')
   OR NOT EXISTS
      (
          SELECT 1
          FROM OPENJSON(@Diag003Json,N'$.parameters')
          WITH
          (
                [EvidenceKind] varchar(24) N'$.EvidenceKind'
              , [CompiledValuePresent] bit N'$.CompiledValuePresent'
              , [RuntimeValuePresent] bit N'$.RuntimeValuePresent'
              , [CompiledValueIsSqlNull] bit N'$.CompiledValueIsSqlNull'
              , [RuntimeValueIsSqlNull] bit N'$.RuntimeValueIsSqlNull'
              , [CompiledValueStatus] varchar(40) N'$.CompiledValueStatus'
              , [RuntimeValueStatus] varchar(40) N'$.RuntimeValueStatus'
              , [ValueStatus] varchar(40) N'$.ValueStatus'
          )
          WHERE [EvidenceKind]='PARAMETER'
            AND [CompiledValuePresent]=1
            AND [RuntimeValuePresent]=1
            AND [CompiledValueIsSqlNull]=1
            AND [RuntimeValueIsSqlNull]=1
            AND [CompiledValueStatus]='SQL_NULL'
            AND [RuntimeValueStatus]='SQL_NULL'
            AND [ValueStatus]='SQL_NULL'
      )
    THROW 53642,N'Erfasstes SQL-NULL wurde nicht von fehlender Parameterevidenz unterschieden.',1;

DECLARE @MissingPlanHandle varbinary(64)=CONVERT(varbinary(64),REPLICATE('01',64),2);
SET @Diag003Json=NULL;SET @Diag003Status=NULL;SET @Diag003Partial=NULL;SET @Diag003Error=NULL;SET @Diag003Message=NULL;
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanHandle=@MissingPlanHandle
    , @PlanQuelle='COMPILE'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Diag003Json OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Diag003Status OUTPUT
    , @IsPartialOut=@Diag003Partial OUTPUT
    , @ErrorNumberOut=@Diag003Error OUTPUT
    , @ErrorMessageOut=@Diag003Message OUTPUT;
DECLARE @Diag003EvictedValueStatus varchar(40)=JSON_VALUE(@Diag003Json,N'$.parameters[0].ValueStatus');
DECLARE @Diag003EvictedValueSource varchar(40)=JSON_VALUE(@Diag003Json,N'$.parameters[0].ValueSource');
IF @Diag003Status<>'UNAVAILABLE_OBJECT'
   OR @Diag003EvictedValueStatus<>N'PLAN_EVICTED'
   OR @Diag003EvictedValueSource<>N'COMPILE_PLAN'
BEGIN
    DECLARE @Diag003EvictedAssertMessage nvarchar(2048)=CONCAT
    (
          N'PLAN_EVICTED-Vertrag verletzt: status=',COALESCE(@Diag003Status,N'<NULL>')
        , N'; error=',COALESCE(CONVERT(nvarchar(20),@Diag003Error),N'<NULL>')
        , N'; valueStatus=',COALESCE(@Diag003EvictedValueStatus,N'<NULL>')
        , N'; valueSource=',COALESCE(@Diag003EvictedValueSource,N'<NULL>')
    );
    THROW 53643,@Diag003EvictedAssertMessage,1;
END;

DECLARE @MissingSessionId smallint=32767;
WHILE @MissingSessionId>1
  AND EXISTS
      (
          SELECT 1
          FROM [sys].[dm_exec_sessions] AS [s] WITH (NOLOCK)
          WHERE [s].[session_id]=@MissingSessionId
      )
    SET @MissingSessionId-=1;
IF EXISTS
(
    SELECT 1
    FROM [sys].[dm_exec_sessions] AS [s] WITH (NOLOCK)
    WHERE [s].[session_id]=@MissingSessionId
)
    THROW 53644,N'Für den REQUEST_FINISHED-Vertrag konnte keine freie synthetische Session-ID bestimmt werden.',1;

DECLARE @MissingSessionIdText nvarchar(10)=CONVERT(nvarchar(10),@MissingSessionId);
SET @Diag003Json=NULL;SET @Diag003Status=NULL;SET @Diag003Partial=NULL;SET @Diag003Error=NULL;SET @Diag003Message=NULL;
EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @SessionIds=@MissingSessionIdText
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Diag003Json OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Diag003Status OUTPUT
    , @IsPartialOut=@Diag003Partial OUTPUT
    , @ErrorNumberOut=@Diag003Error OUTPUT
    , @ErrorMessageOut=@Diag003Message OUTPUT;
IF @Diag003Status<>'UNAVAILABLE_OBJECT'
   OR JSON_VALUE(@Diag003Json,N'$.parameters[0].ValueStatus')<>N'REQUEST_FINISHED'
   OR TRY_CONVERT(int,JSON_VALUE(@Diag003Json,N'$.parameters[0].SessionId'))<>@MissingSessionId
    THROW 53645,N'Ein beendeter Request wurde nicht als REQUEST_FINISHED ausgewiesen.',1;
GO
