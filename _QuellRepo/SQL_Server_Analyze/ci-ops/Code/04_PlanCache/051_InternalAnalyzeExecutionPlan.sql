USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalAnalyzeExecutionPlan
Version      : 1.2.0
Stand        : 2026-07-23
Typ          : Interne Stored Procedure
Zweck        : Zerlegt genau ein Showplan-XML einmalig in statementgenaue,
               relationale Plan-, Operator-, Runtime-, Statistik-, Parameter-,
               Warnungs-, Optimizer-, Feedback- und Findingtabellen des Aufrufers.
Voraussetzung: Der Aufrufer legt die lokalen #ExecutionPlanAnalysis_*-Temp-Tabellen entsprechend
               dem Resultsetinventar an. Keine Benutzertabellenzugriffe.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalAnalyzeExecutionPlan]
      @AnalysisObjectId          int
    , @PlanXml                   xml
    , @PlanSource                varchar(24)
    , @RuntimeCounterScope       varchar(32)
    , @WorkloadProfile           varchar(32) = 'BALANCED'
    , @MinSeverity               varchar(16) = 'INFO'
    , @EvidenceJson              nvarchar(max) = NULL
    , @MitThreadRuntime          bit = 0
    , @EvidenzDatenschutzModus   varchar(24) = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus varchar(16) = 'RAW'
    , @SourceObservedAtUtc         datetime2(3) = NULL
    , @ParameterEvidenceSessionId                  smallint = NULL
    , @ParameterEvidenceRequestId                  int = NULL
    , @PlanHandle                 varbinary(64) = NULL
    , @QueryStoreDatabaseName     sysname = NULL
    , @QueryStorePlanId           bigint = NULL
    , @StatusCodeOut             varchar(40) = NULL OUTPUT
    , @IsPartialOut              bit = NULL OUTPUT
    , @ErrorNumberOut            int = NULL OUTPUT
    , @ErrorMessageOut           nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    SELECT
          @WorkloadProfile=UPPER(LTRIM(RTRIM(COALESCE(@WorkloadProfile,'BALANCED'))))
        , @MinSeverity=UPPER(LTRIM(RTRIM(COALESCE(@MinSeverity,'INFO'))))
        , @EvidenzDatenschutzModus=UPPER(LTRIM(RTRIM(COALESCE(@EvidenzDatenschutzModus,'DERIVED_ONLY'))))
        , @IdentifierDatenschutzModus=UPPER(LTRIM(RTRIM(COALESCE(@IdentifierDatenschutzModus,'RAW'))))
        , @SourceObservedAtUtc=COALESCE(@SourceObservedAtUtc,SYSUTCDATETIME())
        , @StatusCodeOut='AVAILABLE'
        , @IsPartialOut=0
        , @ErrorNumberOut=NULL
        , @ErrorMessageOut=NULL;

    IF @AnalysisObjectId IS NULL OR @AnalysisObjectId<1 OR @PlanXml IS NULL
       OR @PlanSource NOT IN ('IMPORTED','COMPILE','LAST_ACTUAL','CURRENT_ACTUAL','QUERY_STORE')
       OR @RuntimeCounterScope NOT IN ('NONE','LAST_COMPLETED_EXECUTION','CURRENT_PARTIAL_EXECUTION','IMPORTED_ACTUAL','QUERY_STORE_AGGREGATE','UNKNOWN')
       OR @MinSeverity NOT IN ('INFO','LOW','MEDIUM','HIGH','CRITICAL')
       OR @MitThreadRuntime NOT IN (0,1)
       OR @EvidenzDatenschutzModus NOT IN ('DERIVED_ONLY','TOKENIZED','RAW','STRUCTURE_ONLY')
       OR @IdentifierDatenschutzModus NOT IN ('RAW','TOKENIZED','OMIT')
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Ungültige Plan-, Quell-, Scope-, Severity- oder Datenschutzparameter.';
        RETURN;
    END;

    IF NOT EXISTS
    (
        SELECT 1 FROM [monitor].[PlanAnalysisProfile]
        WHERE [ProfileCode]=@WorkloadProfile AND [IsEnabled]=1
    )
        SET @WorkloadProfile='BALANCED';

    BEGIN TRY
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_Capabilities];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_PlanDocuments];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_Statements];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_Operators];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_OperatorRuntime];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_AccessPaths];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_StatisticsUsage];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_Parameters];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_ParameterEvidence];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_SourceContext];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_PlanWarnings];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_OptimizerContext];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_RuntimeFeedback];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_QueryStoreContext];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_FeedbackAndVariants];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_MemoryAndSpills];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_ExecutionEvidence];
        SELECT TOP (0) * FROM [#ExecutionPlanAnalysis_Findings];
    END TRY
    BEGIN CATCH
        SELECT @StatusCodeOut='INTERNAL_ERROR',@IsPartialOut=1,
               @ErrorNumberOut=ERROR_NUMBER(),
               @ErrorMessageOut=N'Die erwarteten lokalen #ExecutionPlanAnalysis_*-Temp-Tabellen fehlen oder besitzen ein unpassendes Schema.';
        RETURN;
    END CATCH;

    CREATE TABLE [#InternalAnalyzeExecutionPlan_StatementXml]
    (
          [StatementOrdinal] int NOT NULL PRIMARY KEY
        , [StatementId] int NULL
        , [StatementCompId] int NULL
        , [StatementXml] xml NOT NULL
    );
    CREATE TABLE [#InternalAnalyzeExecutionPlan_Edges]
    (
          [StatementOrdinal] int NOT NULL
        , [ParentNodeId] int NOT NULL
        , [ChildNodeId] int NOT NULL
        , [ChildOrdinal] int NOT NULL
        , PRIMARY KEY ([StatementOrdinal],[ParentNodeId],[ChildNodeId])
    );

    BEGIN TRY
        ;WITH [StatementBase] AS
        (
            SELECT
                  [StatementXml]=[s].[n].query('.')
                , [StatementId]=TRY_CONVERT(int,NULLIF([s].[n].value('string((@StatementId)[1])','nvarchar(50)'),N''))
                , [StatementCompId]=TRY_CONVERT(int,NULLIF([s].[n].value('string((@StatementCompId)[1])','nvarchar(50)'),N''))
                , [StatementText]=NULLIF([s].[n].value('string((@StatementText)[1])','nvarchar(4000)'),N'')
            FROM @PlanXml.nodes('//*[local-name(.)="StmtSimple"]') AS [s]([n])
        )
        INSERT [#InternalAnalyzeExecutionPlan_StatementXml]
        ([StatementOrdinal],[StatementId],[StatementCompId],[StatementXml])
        SELECT
              CONVERT(int,ROW_NUMBER() OVER
                (ORDER BY COALESCE([StatementId],2147483647),COALESCE([StatementCompId],2147483647),COALESCE([StatementText],N'')))
            , [StatementId],[StatementCompId],[StatementXml]
        FROM [StatementBase];

        IF NOT EXISTS(SELECT 1 FROM [#InternalAnalyzeExecutionPlan_StatementXml])
        BEGIN
            INSERT [#ExecutionPlanAnalysis_Capabilities]
            VALUES(@AnalysisObjectId,'STATEMENTS',0,'NO_STMT_SIMPLE','PLAN_XML',N'Das Plan-XML enthält kein unterstütztes StmtSimple-Element.');
            SELECT @StatusCodeOut='UNAVAILABLE_OBJECT',@IsPartialOut=1,
                   @ErrorMessageOut=N'Das Plan-XML enthält keine analysierbaren StmtSimple-Elemente.';
            RETURN;
        END;

        INSERT [#ExecutionPlanAnalysis_Statements]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[StatementCompId]
            , [StatementType],[StatementText],[StatementQueryHash],[StatementQueryPlanHash]
            , [StatementSubTreeCost],[StatementEstimatedRows],[OptimizationLevel]
            , [EarlyAbortReason],[CardinalityEstimationModelVersion]
            , [CompileTimeMs],[CompileCpuMs],[CompileMemoryKb]
            , [RetrievedFromCache],[NonParallelPlanReason]
        )
        SELECT
              @AnalysisObjectId,[x].[StatementOrdinal],[x].[StatementId],[x].[StatementCompId]
            , NULLIF([x].[StatementXml].value('string((/*/@StatementType)[1])','nvarchar(128)'),N'')
            , NULLIF([x].[StatementXml].value('string((/*/@StatementText)[1])','nvarchar(max)'),N'')
            , NULLIF([x].[StatementXml].value('string((/*/@QueryHash)[1])','nvarchar(130)'),N'')
            , NULLIF([x].[StatementXml].value('string((/*/@QueryPlanHash)[1])','nvarchar(130)'),N'')
            , TRY_CONVERT(decimal(38,8),NULLIF([x].[StatementXml].value('string((/*/@StatementSubTreeCost)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([x].[StatementXml].value('string((/*/@StatementEstRows)[1])','nvarchar(100)'),N''))
            , NULLIF([x].[StatementXml].value('string((/*/@StatementOptmLevel)[1])','nvarchar(128)'),N'')
            , NULLIF([x].[StatementXml].value('string((/*/@StatementOptmEarlyAbortReason)[1])','nvarchar(256)'),N'')
            , TRY_CONVERT(int,NULLIF([x].[StatementXml].value('string((.//*[local-name(.)="QueryPlan"]/@CardinalityEstimationModelVersion)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([x].[StatementXml].value('string((.//*[local-name(.)="QueryPlan"]/@CompileTime)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([x].[StatementXml].value('string((.//*[local-name(.)="QueryPlan"]/@CompileCPU)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([x].[StatementXml].value('string((.//*[local-name(.)="QueryPlan"]/@CompileMemory)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bit,NULLIF([x].[StatementXml].value('string((/*/@RetrievedFromCache)[1])','nvarchar(20)'),N''))
            , NULLIF([x].[StatementXml].value('string((.//*[local-name(.)="QueryPlan"]/@NonParallelPlanReason)[1])','nvarchar(256)'),N'')
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [x];

        INSERT [#ExecutionPlanAnalysis_Operators]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [ParentNodeId],[ChildOrdinal],[Depth],[OperatorPath]
            , [PhysicalOp],[LogicalOp],[EstimateRows],[EstimatedRowsRead]
            , [EstimatedExecutions],[EstimateRebinds],[EstimateRewinds]
            , [EstimatedCpu],[EstimatedIo],[AverageRowSize],[EstimatedTotalSubtreeCost]
            , [Parallel],[EstimatedExecutionMode],[ActualExecutionMode]
            , [Ordered],[ScanDirection]
            , [ObjectDatabaseName],[ObjectSchemaName],[ObjectName],[IndexName]
        )
        SELECT
              @AnalysisObjectId,[st].[StatementOrdinal],[st].[StatementId]
            , TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , NULL,NULL,NULL,NULL
            , NULLIF([r].[n].value('string((@PhysicalOp)[1])','nvarchar(128)'),N'')
            , NULLIF([r].[n].value('string((@LogicalOp)[1])','nvarchar(128)'),N'')
            , TRY_CONVERT(decimal(38,4),NULLIF([r].[n].value('string((@EstimateRows)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([r].[n].value('string((@EstimatedRowsRead)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([r].[n].value('string((@EstimateExecutions)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([r].[n].value('string((@EstimateRebinds)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([r].[n].value('string((@EstimateRewinds)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,8),NULLIF([r].[n].value('string((@EstimateCPU)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,8),NULLIF([r].[n].value('string((@EstimateIO)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([r].[n].value('string((@AvgRowSize)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,8),NULLIF([r].[n].value('string((@EstimatedTotalSubtreeCost)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bit,NULLIF([r].[n].value('string((@Parallel)[1])','nvarchar(20)'),N''))
            , NULLIF([r].[n].value('string((@EstimatedExecutionMode)[1])','nvarchar(60)'),N'')
            , NULLIF([r].[n].value('string((@ActualExecutionMode)[1])','nvarchar(60)'),N'')
            , TRY_CONVERT(bit,NULLIF([r].[n].value('string((./*/*/@Ordered)[1])','nvarchar(20)'),N''))
            , NULLIF([r].[n].value('string((./*/*/@ScanDirection)[1])','nvarchar(60)'),N'')
            , NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Database)[1])','nvarchar(256)'),N'')
            , NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Schema)[1])','nvarchar(256)'),N'')
            , NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Table)[1])','nvarchar(256)'),N'')
            , NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Index)[1])','nvarchar(256)'),N'')
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"]') AS [r]([n]);

        INSERT [#InternalAnalyzeExecutionPlan_Edges]
        ([StatementOrdinal],[ParentNodeId],[ChildNodeId],[ChildOrdinal])
        SELECT
              [st].[StatementOrdinal]
            , TRY_CONVERT(int,NULLIF([p].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , TRY_CONVERT(int,NULLIF([c].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , CONVERT(int,ROW_NUMBER() OVER
                (PARTITION BY [st].[StatementOrdinal],TRY_CONVERT(int,NULLIF([p].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
                 ORDER BY TRY_CONVERT(int,NULLIF([c].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))))
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"]') AS [p]([n])
        CROSS APPLY [p].[n].nodes('./*/*[local-name(.)="RelOp"]') AS [c]([n])
        WHERE NULLIF([p].[n].value('string((@NodeId)[1])','nvarchar(50)'),N'') IS NOT NULL
          AND NULLIF([c].[n].value('string((@NodeId)[1])','nvarchar(50)'),N'') IS NOT NULL;

        UPDATE [o]
        SET [o].[ParentNodeId]=[e].[ParentNodeId],
            [o].[ChildOrdinal]=[e].[ChildOrdinal]
        FROM [#ExecutionPlanAnalysis_Operators] AS [o]
        JOIN [#InternalAnalyzeExecutionPlan_Edges] AS [e]
          ON [e].[StatementOrdinal]=[o].[StatementOrdinal]
         AND [e].[ChildNodeId]=[o].[NodeId]
        WHERE [o].[AnalysisObjectId]=@AnalysisObjectId;

        UPDATE [#ExecutionPlanAnalysis_Operators]
        SET [Depth]=0,
            [OperatorPath]=CONCAT(N'/',CONVERT(nvarchar(20),[NodeId]))
        WHERE [AnalysisObjectId]=@AnalysisObjectId
          AND [ParentNodeId] IS NULL;

        DECLARE @Depth int=0,@Changed int=1;
        WHILE @Changed>0 AND @Depth<256
        BEGIN
            SET @Depth+=1;
            UPDATE [c]
            SET [c].[Depth]=@Depth,
                [c].[OperatorPath]=CONCAT([p].[OperatorPath],N'/',CONVERT(nvarchar(20),[c].[NodeId]))
            FROM [#ExecutionPlanAnalysis_Operators] AS [c]
            JOIN [#ExecutionPlanAnalysis_Operators] AS [p]
              ON [p].[AnalysisObjectId]=[c].[AnalysisObjectId]
             AND [p].[StatementOrdinal]=[c].[StatementOrdinal]
             AND [p].[NodeId]=[c].[ParentNodeId]
            WHERE [c].[AnalysisObjectId]=@AnalysisObjectId
              AND [c].[Depth] IS NULL
              AND [p].[Depth]=@Depth-1;
            SET @Changed=@@ROWCOUNT;
        END;

        IF EXISTS
        (
            SELECT 1 FROM [#ExecutionPlanAnalysis_Operators]
            WHERE [AnalysisObjectId]=@AnalysisObjectId AND [Depth] IS NULL
        )
        BEGIN
            SET @IsPartialOut=1;
            INSERT [#ExecutionPlanAnalysis_Capabilities]
            VALUES(@AnalysisObjectId,'OPERATOR_TREE',0,'UNRESOLVED_PARENT_PATH','PLAN_XML',N'Mindestens ein Operator konnte nicht in einen eindeutigen Parentpfad eingeordnet werden.');
        END
        ELSE
            INSERT [#ExecutionPlanAnalysis_Capabilities]
            VALUES(@AnalysisObjectId,'OPERATOR_TREE',1,'AVAILABLE','PLAN_XML',N'Parent, Child-Ordinal, Tiefe und Operatorpfad wurden relational ermittelt.');

        INSERT [#ExecutionPlanAnalysis_OperatorThreadRuntime]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [ThreadId],[BrickId],[ActualRows],[ActualRowsRead],[ActualExecutions]
            , [ActualRebinds],[ActualRewinds],[ActualEndOfScans],[ActualScans]
            , [ActualLogicalReads],[ActualPhysicalReads],[ActualReadAheads]
            , [ActualCpuMs],[ActualElapsedMs]
            , [ActualLobLogicalReads],[ActualLobPhysicalReads],[IsRowsReadPaired]
        )
        SELECT
              @AnalysisObjectId,[st].[StatementOrdinal],[st].[StatementId]
            , TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , TRY_CONVERT(int,NULLIF([t].[n].value('string((@Thread)[1])','nvarchar(50)'),N''))
            , TRY_CONVERT(int,NULLIF([t].[n].value('string((@BrickId)[1])','nvarchar(50)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([t].[n].value('string((@ActualRows)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(decimal(38,4),NULLIF([t].[n].value('string((@ActualRowsRead)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualExecutions)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualRebinds)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualRewinds)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualEndOfScans)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualScans)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualLogicalReads)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualPhysicalReads)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualReadAheads)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualCPUms)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualElapsedms)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualLobLogicalReads)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([t].[n].value('string((@ActualLobPhysicalReads)[1])','nvarchar(100)'),N''))
            , CONVERT(bit,CASE WHEN NULLIF([t].[n].value('string((@ActualRowsRead)[1])','nvarchar(100)'),N'') IS NOT NULL
                               THEN 1 ELSE 0 END)
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"]') AS [r]([n])
        CROSS APPLY [r].[n].nodes('./*[local-name(.)="RunTimeInformation"]/*[local-name(.)="RunTimeCountersPerThread"]') AS [t]([n]);

        INSERT [#ExecutionPlanAnalysis_OperatorRuntime]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [RuntimeCounterCount],[RowsReadCounterCount],[RowsReadCounterCoveragePercent]
            , [ActualRows],[ActualRowsRead],[PairedActualRows],[PairedActualRowsRead]
            , [ActualExecutions],[ActualRebinds],[ActualRewinds]
            , [ActualLogicalReads],[ActualPhysicalReads],[ActualReadAheads]
            , [ActualCpuMs],[ActualElapsedMs]
            , [EstimatedRowsTotal],[ActualToEstimatedRatio],[CardinalityLog10Error]
            , [RowsReadNotReturned],[RowsReadNotReturnedPercent],[RuntimeMetricStatus]
        )
        SELECT
              [o].[AnalysisObjectId],[o].[StatementOrdinal],[o].[StatementId],[o].[NodeId]
            , COUNT([t].[NodeId])
            , SUM(CONVERT(int,COALESCE([t].[IsRowsReadPaired],0)))
            , CONVERT(decimal(9,4),100.0*SUM(CONVERT(int,COALESCE([t].[IsRowsReadPaired],0)))/NULLIF(COUNT([t].[NodeId]),0))
            , SUM([t].[ActualRows])
            , SUM([t].[ActualRowsRead])
            , SUM(CASE WHEN [t].[IsRowsReadPaired]=1 THEN [t].[ActualRows] END)
            , SUM(CASE WHEN [t].[IsRowsReadPaired]=1 THEN [t].[ActualRowsRead] END)
            , SUM([t].[ActualExecutions]),SUM([t].[ActualRebinds]),SUM([t].[ActualRewinds])
            , SUM([t].[ActualLogicalReads]),SUM([t].[ActualPhysicalReads]),SUM([t].[ActualReadAheads])
            , SUM([t].[ActualCpuMs]),MAX([t].[ActualElapsedMs])
            , TRY_CONVERT(decimal(38,4),CONVERT(float,[o].[EstimateRows])*
                CONVERT(float,CASE WHEN [o].[EstimateRebinds] IS NOT NULL OR [o].[EstimateRewinds] IS NOT NULL
                                   THEN 1+COALESCE([o].[EstimateRebinds],0)+COALESCE([o].[EstimateRewinds],0)
                                   ELSE COALESCE(NULLIF([o].[EstimatedExecutions],0),1) END))
            , NULL,NULL,NULL,NULL
            , CASE WHEN COUNT([t].[NodeId])=0 THEN 'NO_RUNTIME_INFORMATION'
                   WHEN SUM(CONVERT(int,COALESCE([t].[IsRowsReadPaired],0)))=0 THEN 'ACTUAL_ROWS_READ_NOT_AVAILABLE'
                   WHEN SUM(CONVERT(int,COALESCE([t].[IsRowsReadPaired],0)))<COUNT([t].[NodeId]) THEN 'PARTIAL_COUNTER_COVERAGE'
                   ELSE 'AVAILABLE' END
        FROM [#ExecutionPlanAnalysis_Operators] AS [o]
        LEFT JOIN [#ExecutionPlanAnalysis_OperatorThreadRuntime] AS [t]
          ON [t].[AnalysisObjectId]=[o].[AnalysisObjectId]
         AND [t].[StatementOrdinal]=[o].[StatementOrdinal]
         AND [t].[NodeId]=[o].[NodeId]
        WHERE [o].[AnalysisObjectId]=@AnalysisObjectId
        GROUP BY
              [o].[AnalysisObjectId],[o].[StatementOrdinal],[o].[StatementId],[o].[NodeId]
            , [o].[EstimateRows],[o].[EstimateRebinds],[o].[EstimateRewinds],[o].[EstimatedExecutions];

        UPDATE [r]
        SET
              [ActualToEstimatedRatio]=CASE
                  WHEN [r].[ActualRows] IS NOT NULL AND [r].[EstimatedRowsTotal]>0
                  THEN TRY_CONVERT(decimal(38,8),CONVERT(decimal(38,12),[r].[ActualRows])
                       /NULLIF(CONVERT(decimal(38,12),[r].[EstimatedRowsTotal]),CONVERT(decimal(38,12),0))) END
            , [CardinalityLog10Error]=CASE
                  WHEN [r].[ActualRows] IS NOT NULL AND [r].[EstimatedRowsTotal] IS NOT NULL
                  THEN TRY_CONVERT(decimal(19,6),ABS(LOG10
                       ((CONVERT(float,[r].[ActualRows])+1.0)/(CONVERT(float,[r].[EstimatedRowsTotal])+1.0)))) END
            , [RowsReadNotReturned]=CASE
                  WHEN [r].[PairedActualRowsRead] IS NOT NULL AND [r].[PairedActualRows] IS NOT NULL
                   AND [r].[PairedActualRowsRead]>=[r].[PairedActualRows]
                  THEN TRY_CONVERT(decimal(38,4),CONVERT(decimal(38,4),[r].[PairedActualRowsRead])-CONVERT(decimal(38,4),[r].[PairedActualRows])) END
            , [RowsReadNotReturnedPercent]=CASE
                  WHEN [r].[PairedActualRowsRead] IS NULL OR [r].[PairedActualRows] IS NULL THEN NULL
                  WHEN [r].[PairedActualRowsRead]<=0 THEN NULL
                  WHEN [r].[PairedActualRows]<0 OR [r].[PairedActualRows]>[r].[PairedActualRowsRead] THEN NULL
                  ELSE CONVERT(decimal(19,6),CONVERT(decimal(38,12),100)*
                       (CONVERT(decimal(38,12),[r].[PairedActualRowsRead])-CONVERT(decimal(38,12),[r].[PairedActualRows]))
                       /CONVERT(decimal(38,12),[r].[PairedActualRowsRead])) END
            , [RuntimeMetricStatus]=CASE
                  WHEN [r].[RuntimeCounterCount]=0 THEN 'NO_RUNTIME_INFORMATION'
                  WHEN [r].[RowsReadCounterCount]=0 THEN 'ACTUAL_ROWS_READ_NOT_AVAILABLE'
                  WHEN [r].[PairedActualRowsRead]<[r].[PairedActualRows] THEN 'INCONSISTENT_COUNTERS'
                  WHEN [r].[RowsReadCounterCount]<[r].[RuntimeCounterCount] THEN 'PARTIAL_COUNTER_COVERAGE'
                  WHEN [r].[PairedActualRowsRead]=0 THEN 'ZERO_ROWS_READ'
                  ELSE 'AVAILABLE' END
        FROM [#ExecutionPlanAnalysis_OperatorRuntime] AS [r]
        WHERE [r].[AnalysisObjectId]=@AnalysisObjectId;

        INSERT [#ExecutionPlanAnalysis_AccessPaths]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[DatabaseName],[SchemaName],[ObjectName]
            , [IndexName],[StorageType],[IsLookup],[Ordered],[ScanDirection]
            , [EstimateRows],[EstimatedRowsRead],[ActualRows],[ActualRowsRead]
            , [ActualExecutions],[RowsReadNotReturned],[RowsReadNotReturnedPercent]
        )
        SELECT
              [o].[AnalysisObjectId],[o].[StatementOrdinal],[o].[StatementId],[o].[NodeId]
            , [o].[PhysicalOp],[o].[LogicalOp],[o].[ObjectDatabaseName]
            , [o].[ObjectSchemaName],[o].[ObjectName],[o].[IndexName],NULL
            , CONVERT(bit,CASE WHEN [o].[PhysicalOp] IN (N'Key Lookup',N'RID Lookup') THEN 1 ELSE 0 END)
            , [o].[Ordered],[o].[ScanDirection],[o].[EstimateRows],[o].[EstimatedRowsRead]
            , [r].[ActualRows],[r].[ActualRowsRead],[r].[ActualExecutions]
            , [r].[RowsReadNotReturned],[r].[RowsReadNotReturnedPercent]
        FROM [#ExecutionPlanAnalysis_Operators] AS [o]
        LEFT JOIN [#ExecutionPlanAnalysis_OperatorRuntime] AS [r]
          ON [r].[AnalysisObjectId]=[o].[AnalysisObjectId]
         AND [r].[StatementOrdinal]=[o].[StatementOrdinal]
         AND [r].[NodeId]=[o].[NodeId]
        WHERE [o].[AnalysisObjectId]=@AnalysisObjectId
          AND
          (
              [o].[PhysicalOp] LIKE N'%Scan%'
              OR [o].[PhysicalOp] LIKE N'%Seek%'
              OR [o].[PhysicalOp] IN (N'Key Lookup',N'RID Lookup')
          );

        INSERT [#ExecutionPlanAnalysis_StatisticsUsage]
        (
              [AnalysisObjectId],[StatisticsUsageOrdinal],[StatementOrdinal]
            , [StatementId],[StatementCompId],[DatabaseName],[SchemaName]
            , [ObjectName],[StatisticsName],[LastUpdateAtCompile]
            , [ModificationCountAtCompile],[SamplingPercentAtCompile]
            , [CurrentLastUpdated],[CurrentRows],[CurrentRowsSampled]
            , [CurrentModificationCounter],[CurrentSamplePercent]
            , [StatisticsChangedSinceCompile],[MetadataMatchStatus]
        )
        SELECT
              @AnalysisObjectId,[StatisticsUsageOrdinal],[StatementOrdinal]
            , [StatementId],[StatementCompId],[DatabaseName],[SchemaName]
            , [ObjectName],[StatisticsName],[LastUpdateAtCompile]
            , [ModificationCountAtCompile],[SamplingPercentAtCompile]
            , NULL,NULL,NULL,NULL,NULL,NULL,'PLAN_ONLY'
        FROM [monitor].[TVF_ExecutionPlanStatisticsUsage](@PlanXml,NULL);

        DECLARE @TokenSalt varbinary(32)=CRYPT_GEN_RANDOM(32);

        /*
          DIAG-003: Das Showplan-Parameterelement wird genau einmal zerlegt.
          Der kanonische Vertrag bewahrt Attributpräsenz, SQL-NULL-Semantik,
          Quellzeit und Ausführungsscope; das Legacy-Resultset wird anschließend
          ausschließlich aus derselben Materialisierung projiziert.
        */
        INSERT [#ExecutionPlanAnalysis_ParameterEvidence]
        (
              [CandidateId],[SessionId],[RequestId],[StatementOrdinal],[StatementId]
            , [StatementQueryHash],[StatementQueryPlanHash],[PlanHandle]
            , [QueryStoreDatabaseName],[QueryStorePlanId],[PlanDocumentHash]
            , [EvidenceKind],[ParameterName],[ParameterDataType]
            , [CompiledValuePresent],[RuntimeValuePresent]
            , [CompiledValueIsSqlNull],[RuntimeValueIsSqlNull]
            , [CompiledValue],[RuntimeValue]
            , [CompiledValueToken],[RuntimeValueToken]
            , [CompiledValueLength],[RuntimeValueLength]
            , [CompiledValueStatus],[RuntimeValueStatus],[ValueStatus]
            , [ValueHandlingStatus],[ValueSource]
            , [SourceObservedAtUtc],[ValueCapturedAtUtc]
            , [IsCurrentExecution],[IsLastKnownExecution],[IsComplete],[EvidenceLimit]
        )
        SELECT
              @AnalysisObjectId,@ParameterEvidenceSessionId,@ParameterEvidenceRequestId,[st].[StatementOrdinal],[st].[StatementId]
            , [q].[StatementQueryHash],[q].[StatementQueryPlanHash],@PlanHandle
            , @QueryStoreDatabaseName,@QueryStorePlanId,NULL
            , 'PARAMETER'
            , NULLIF([p].[n].value('string((@Column)[1])','nvarchar(256)'),N'')
            , NULLIF([p].[n].value('string((@ParameterDataType)[1])','nvarchar(256)'),N'')
            , [v].[CompiledValuePresent],[v].[RuntimeValuePresent]
            , CONVERT(bit,CASE WHEN [v].[CompiledValuePresent]=1
                                    AND UPPER(LTRIM(RTRIM(COALESCE([v].[CompiledValueText],N'')))) IN (N'NULL',N'(NULL)')
                               THEN 1 WHEN [v].[CompiledValuePresent]=1 THEN 0 END)
            , CONVERT(bit,CASE WHEN [v].[RuntimeValuePresent]=1
                                    AND UPPER(LTRIM(RTRIM(COALESCE([v].[RuntimeValueText],N'')))) IN (N'NULL',N'(NULL)')
                               THEN 1 WHEN [v].[RuntimeValuePresent]=1 THEN 0 END)
            , CASE WHEN @EvidenzDatenschutzModus='RAW' THEN [v].[CompiledValueText] END
            , CASE WHEN @EvidenzDatenschutzModus='RAW' THEN [v].[RuntimeValueText] END
            , CASE WHEN @EvidenzDatenschutzModus='TOKENIZED'
                         AND [v].[CompiledValuePresent]=1
                         AND UPPER(LTRIM(RTRIM(COALESCE([v].[CompiledValueText],N'')))) NOT IN (N'NULL',N'(NULL)')
                   THEN CONVERT(nvarchar(66),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([v].[CompiledValueText],N''))),1) END
            , CASE WHEN @EvidenzDatenschutzModus='TOKENIZED'
                         AND [v].[RuntimeValuePresent]=1
                         AND UPPER(LTRIM(RTRIM(COALESCE([v].[RuntimeValueText],N'')))) NOT IN (N'NULL',N'(NULL)')
                   THEN CONVERT(nvarchar(66),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([v].[RuntimeValueText],N''))),1) END
            , CASE WHEN [v].[CompiledValuePresent]=1 THEN LEN([v].[CompiledValueText]) END
            , CASE WHEN [v].[RuntimeValuePresent]=1 THEN LEN([v].[RuntimeValueText]) END
            , CASE WHEN [v].[CompiledValuePresent]=0 THEN 'NOT_COLLECTED'
                   WHEN UPPER(LTRIM(RTRIM(COALESCE([v].[CompiledValueText],N'')))) IN (N'NULL',N'(NULL)') THEN 'SQL_NULL'
                   ELSE 'AVAILABLE' END
            , CASE WHEN [v].[RuntimeValuePresent]=0 THEN 'NOT_COLLECTED'
                   WHEN UPPER(LTRIM(RTRIM(COALESCE([v].[RuntimeValueText],N'')))) IN (N'NULL',N'(NULL)') THEN 'SQL_NULL'
                   ELSE 'AVAILABLE' END
            , CASE WHEN @RuntimeCounterScope IN ('CURRENT_PARTIAL_EXECUTION','LAST_COMPLETED_EXECUTION','IMPORTED_ACTUAL')
                   THEN CASE WHEN [v].[RuntimeValuePresent]=0 THEN 'NOT_COLLECTED'
                             WHEN UPPER(LTRIM(RTRIM(COALESCE([v].[RuntimeValueText],N'')))) IN (N'NULL',N'(NULL)') THEN 'SQL_NULL'
                             ELSE 'AVAILABLE' END
                   ELSE CASE WHEN [v].[CompiledValuePresent]=0 THEN 'NOT_COLLECTED'
                             WHEN UPPER(LTRIM(RTRIM(COALESCE([v].[CompiledValueText],N'')))) IN (N'NULL',N'(NULL)') THEN 'SQL_NULL'
                             ELSE 'AVAILABLE' END END
            , CASE @EvidenzDatenschutzModus WHEN 'RAW' THEN 'AVAILABLE_RAW'
                   WHEN 'TOKENIZED' THEN 'TOKENIZED_CAPTURE_LOCAL'
                   WHEN 'STRUCTURE_ONLY' THEN 'OMITTED_STRUCTURE_ONLY'
                   ELSE 'OMITTED_DERIVED_ONLY' END
            , CASE @PlanSource WHEN 'COMPILE' THEN 'COMPILE_PLAN'
                   WHEN 'CURRENT_ACTUAL' THEN 'LIVE_PLAN'
                   WHEN 'LAST_ACTUAL' THEN 'LAST_ACTUAL_PLAN'
                   WHEN 'QUERY_STORE' THEN 'QUERY_STORE_PLAN'
                   ELSE 'IMPORTED_PLAN' END
            , @SourceObservedAtUtc
            , CASE WHEN @PlanSource='CURRENT_ACTUAL' THEN @SourceObservedAtUtc END
            , CASE WHEN @PlanSource='CURRENT_ACTUAL' THEN CONVERT(bit,1)
                   WHEN @PlanSource='IMPORTED' THEN CONVERT(bit,NULL) ELSE CONVERT(bit,0) END
            , CASE WHEN @PlanSource='LAST_ACTUAL' THEN CONVERT(bit,1)
                   WHEN @PlanSource='IMPORTED' THEN CONVERT(bit,NULL) ELSE CONVERT(bit,0) END
            , CONVERT(bit,CASE
                  WHEN @RuntimeCounterScope IN ('CURRENT_PARTIAL_EXECUTION','LAST_COMPLETED_EXECUTION','IMPORTED_ACTUAL')
                      THEN [v].[RuntimeValuePresent]
                  ELSE [v].[CompiledValuePresent] END)
            , N'Showplan stellt nur die im gewählten Plan vorhandenen Parameterattribute bereit; lokale T-SQL-Variablenwerte sind nicht allgemein über eine DMV verfügbar.'
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        JOIN [#ExecutionPlanAnalysis_Statements] AS [q]
          ON [q].[AnalysisObjectId]=@AnalysisObjectId
         AND [q].[StatementOrdinal]=[st].[StatementOrdinal]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="ParameterList"]/*[local-name(.)="ColumnReference"]') AS [p]([n])
        CROSS APPLY
        (
            SELECT
                  [CompiledValuePresent]=CONVERT(bit,[p].[n].exist('@ParameterCompiledValue'))
                , [RuntimeValuePresent]=CONVERT(bit,[p].[n].exist('@ParameterRuntimeValue'))
                , [CompiledValueText]=CASE WHEN [p].[n].exist('@ParameterCompiledValue')=1
                      THEN [p].[n].value('string((@ParameterCompiledValue)[1])','nvarchar(4000)') END
                , [RuntimeValueText]=CASE WHEN [p].[n].exist('@ParameterRuntimeValue')=1
                      THEN [p].[n].value('string((@ParameterRuntimeValue)[1])','nvarchar(4000)') END
        ) AS [v];

        /* Dokumentierte Systemgrenze: lokale Variablen sind keine Showplan-Parameter. */
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
              @AnalysisObjectId,@ParameterEvidenceSessionId,@ParameterEvidenceRequestId,NULL,NULL,NULL,NULL,@PlanHandle
            , @QueryStoreDatabaseName,@QueryStorePlanId,NULL
            , 'SOURCE_BOUNDARY',NULL,NULL,0,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
            , 'NOT_COLLECTED','NOT_COLLECTED','LOCAL_VARIABLE_NOT_EXPOSED'
            , CASE @EvidenzDatenschutzModus WHEN 'RAW' THEN 'AVAILABLE_RAW'
                   WHEN 'TOKENIZED' THEN 'TOKENIZED_CAPTURE_LOCAL'
                   WHEN 'STRUCTURE_ONLY' THEN 'OMITTED_STRUCTURE_ONLY'
                   ELSE 'OMITTED_DERIVED_ONLY' END
            , CASE @PlanSource WHEN 'COMPILE' THEN 'COMPILE_PLAN'
                   WHEN 'CURRENT_ACTUAL' THEN 'LIVE_PLAN'
                   WHEN 'LAST_ACTUAL' THEN 'LAST_ACTUAL_PLAN'
                   WHEN 'QUERY_STORE' THEN 'QUERY_STORE_PLAN'
                   ELSE 'IMPORTED_PLAN' END
            , @SourceObservedAtUtc,NULL
            , CASE WHEN @PlanSource='CURRENT_ACTUAL' THEN CONVERT(bit,1)
                   WHEN @PlanSource='IMPORTED' THEN CONVERT(bit,NULL) ELSE CONVERT(bit,0) END
            , CASE WHEN @PlanSource='LAST_ACTUAL' THEN CONVERT(bit,1)
                   WHEN @PlanSource='IMPORTED' THEN CONVERT(bit,NULL) ELSE CONVERT(bit,0) END
            , 0
            , N'Lokale T-SQL-Variablenwerte sind über die ausgewerteten Plan- und DMV-Quellen nicht vollständig zugänglich.'
        );

        INSERT [#ExecutionPlanAnalysis_Parameters]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId]
            , [ParameterName],[ParameterDataType]
            , [CompiledValue],[RuntimeValue]
            , [CompiledValueToken],[RuntimeValueToken]
            , [CompiledValueLength],[RuntimeValueLength]
            , [ValueHandlingStatus],[ValueSource]
        )
        SELECT
              [CandidateId],[StatementOrdinal],[StatementId]
            , [ParameterName],[ParameterDataType],[CompiledValue],[RuntimeValue]
            , CONVERT(varbinary(32),[CompiledValueToken],1)
            , CONVERT(varbinary(32),[RuntimeValueToken],1)
            , [CompiledValueLength],[RuntimeValueLength],[ValueHandlingStatus]
            , CASE WHEN [RuntimeValuePresent]=1 THEN 'COMPILE_AND_RUNTIME_PLAN' ELSE 'COMPILE_PLAN' END
        FROM [#ExecutionPlanAnalysis_ParameterEvidence]
        WHERE [CandidateId]=@AnalysisObjectId
          AND [EvidenceKind]='PARAMETER';

        INSERT [#ExecutionPlanAnalysis_MemoryAndSpills]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [RecordType],[SpillKind],[SpillLevel],[SpilledDataSize]
            , [WritesToTempDb],[ReadsFromTempDb]
            , [RequestedMemoryKb],[GrantedMemoryKb],[MaxUsedMemoryKb]
            , [GrantWaitTimeMs],[MemoryGrantFeedbackState],[Detail]
        )
        SELECT
              @AnalysisObjectId,[st].[StatementOrdinal],[st].[StatementId],NULL
            , 'MEMORY_GRANT',NULL,NULL,NULL,NULL,NULL
            , TRY_CONVERT(bigint,NULLIF([m].[n].value('string((@RequestedMemory)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([m].[n].value('string((@GrantedMemory)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([m].[n].value('string((@MaxUsedMemory)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([m].[n].value('string((@GrantWaitTime)[1])','nvarchar(100)'),N''))
            , NULLIF([m].[n].value('string((@IsMemoryGrantFeedbackAdjusted)[1])','nvarchar(128)'),N'')
            , N'Statementbezogene MemoryGrantInfo aus dem Plan.'
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="MemoryGrantInfo"]') AS [m]([n]);

        INSERT [#ExecutionPlanAnalysis_MemoryAndSpills]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [RecordType],[SpillKind],[SpillLevel],[SpilledDataSize]
            , [WritesToTempDb],[ReadsFromTempDb]
            , [RequestedMemoryKb],[GrantedMemoryKb],[MaxUsedMemoryKb]
            , [GrantWaitTimeMs],[MemoryGrantFeedbackState],[Detail]
        )
        SELECT
              @AnalysisObjectId,[st].[StatementOrdinal],[st].[StatementId]
            , TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , 'SPILL',[sp].[n].value('local-name(.)','nvarchar(128)')
            , TRY_CONVERT(int,NULLIF([sp].[n].value('string((@SpillLevel)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([sp].[n].value('string((@SpilledDataSize)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([sp].[n].value('string((@WritesToTempDb)[1])','nvarchar(100)'),N''))
            , TRY_CONVERT(bigint,NULLIF([sp].[n].value('string((@ReadsFromTempDb)[1])','nvarchar(100)'),N''))
            , NULL,NULL,NULL,NULL,NULL
            , N'Operatorbezogene Spillinformation aus dem Actual Plan.'
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"]') AS [r]([n])
        CROSS APPLY [r].[n].nodes('./*[local-name(.)="Warnings"]/*[local-name(.)="SpillToTempDb" or local-name(.)="HashSpillDetails" or local-name(.)="SortSpillDetails" or local-name(.)="ExchangeSpillDetails"]') AS [sp]([n]);

        /* Optionale strukturierte zusätzliche Ausführungsevidenz. */
        IF @EvidenceJson IS NOT NULL AND ISJSON(@EvidenceJson)=1
        BEGIN
            INSERT [#ExecutionPlanAnalysis_ExecutionEvidence]
            (
                  [AnalysisObjectId],[EvidenceType],[StatementOrdinal]
                , [ScopeName],[MetricName],[MetricValue],[MetricUnit]
                , [EvidenceStatus],[SameExecutionConfidence]
            )
            SELECT
                  @AnalysisObjectId,'STATISTICS_IO',TRY_CONVERT(int,[j].[StatementOrdinal])
                , CASE @IdentifierDatenschutzModus WHEN 'RAW' THEN [j].[ObjectDisplayName]
                       WHEN 'TOKENIZED' THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([j].[ObjectDisplayName],N''))),1)
                       ELSE NULL END
                , [v].[MetricName],[v].[MetricValue],N'pages',[j].[ParseStatus]
                , COALESCE(JSON_VALUE(@EvidenceJson,N'$.capture.sameExecutionConfidence'),N'UNCONFIRMED')
            FROM OPENJSON(@EvidenceJson,N'$.statisticsIo')
            WITH
            (
                  [StatementOrdinal] int N'$.statementOrdinal'
                , [ObjectDisplayName] nvarchar(512) N'$.objectDisplayName'
                , [LogicalReads] decimal(38,4) N'$.logicalReads'
                , [PhysicalReads] decimal(38,4) N'$.physicalReads'
                , [ReadAheadReads] decimal(38,4) N'$.readAheadReads'
                , [ScanCount] decimal(38,4) N'$.scanCount'
                , [ParseStatus] varchar(40) N'$.parseStatus'
            ) AS [j]
            CROSS APPLY
            (
                VALUES
                  ('LOGICAL_READS',[j].[LogicalReads])
                , ('PHYSICAL_READS',[j].[PhysicalReads])
                , ('READ_AHEAD_READS',[j].[ReadAheadReads])
                , ('SCAN_COUNT',[j].[ScanCount])
            ) AS [v]([MetricName],[MetricValue])
            WHERE [v].[MetricValue] IS NOT NULL;

            INSERT [#ExecutionPlanAnalysis_ExecutionEvidence]
            (
                  [AnalysisObjectId],[EvidenceType],[StatementOrdinal]
                , [ScopeName],[MetricName],[MetricValue],[MetricUnit]
                , [EvidenceStatus],[SameExecutionConfidence]
            )
            SELECT
                  @AnalysisObjectId,'STATISTICS_TIME',TRY_CONVERT(int,[j].[StatementOrdinal])
                , [j].[TimeCategory],[v].[MetricName],[v].[MetricValue],N'ms',[j].[ParseStatus]
                , COALESCE(JSON_VALUE(@EvidenceJson,N'$.capture.sameExecutionConfidence'),N'UNCONFIRMED')
            FROM OPENJSON(@EvidenceJson,N'$.statisticsTime')
            WITH
            (
                  [StatementOrdinal] int N'$.statementOrdinal'
                , [TimeCategory] varchar(24) N'$.timeCategory'
                , [CpuMs] decimal(38,4) N'$.cpuMs'
                , [ElapsedMs] decimal(38,4) N'$.elapsedMs'
                , [ParseStatus] varchar(40) N'$.parseStatus'
            ) AS [j]
            CROSS APPLY (VALUES('CPU_MS',[j].[CpuMs]),('ELAPSED_MS',[j].[ElapsedMs])) AS [v]([MetricName],[MetricValue])
            WHERE [v].[MetricValue] IS NOT NULL;
        END
        ELSE IF @EvidenceJson IS NOT NULL
        BEGIN
            SET @IsPartialOut=1;
            INSERT [#ExecutionPlanAnalysis_Capabilities]
            VALUES(@AnalysisObjectId,'EXECUTION_EVIDENCE_JSON',0,'INVALID_JSON','EXTERNAL_EVIDENCE',N'Übergebene Ausführungsevidenz ist kein gültiges JSON.');
        END;

        /* Capabilitymodell ausschließlich nach tatsächlich vorhandenen Elementen. */
        INSERT [#ExecutionPlanAnalysis_Capabilities]
        SELECT @AnalysisObjectId,'ACTUAL_RUNTIME',CONVERT(bit,CASE WHEN EXISTS
            (SELECT 1 FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RuntimeCounterCount]>0) THEN 1 ELSE 0 END),
            CASE WHEN EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RuntimeCounterCount]>0) THEN 'AVAILABLE' ELSE 'ATTRIBUTE_NOT_PRESENT' END,
            'PLAN_XML',N'Runtimecounter werden nur als verfügbar ausgewiesen, wenn entsprechende XML-Elemente vorhanden sind.';
        INSERT [#ExecutionPlanAnalysis_Capabilities]
        SELECT @AnalysisObjectId,'ACTUAL_ROWS_READ',CONVERT(bit,CASE WHEN EXISTS
            (SELECT 1 FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RowsReadCounterCount]>0) THEN 1 ELSE 0 END),
            CASE WHEN EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RowsReadCounterCount]>0) THEN 'AVAILABLE' ELSE 'ATTRIBUTE_NOT_PRESENT' END,
            'PLAN_XML',N'ActualRowsRead wird threadweise gepaart und fehlende Attribute werden nicht als 0 interpretiert.';
        INSERT [#ExecutionPlanAnalysis_Capabilities]
        SELECT @AnalysisObjectId,'THREAD_RUNTIME',CONVERT(bit,CASE WHEN @MitThreadRuntime=1 AND EXISTS
            (SELECT 1 FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RuntimeCounterCount]>1) THEN 1 ELSE 0 END),
            CASE WHEN @MitThreadRuntime=0 THEN 'NOT_REQUESTED'
                 WHEN EXISTS(SELECT 1 FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RuntimeCounterCount]>1) THEN 'AVAILABLE'
                 ELSE 'THREAD_DETAIL_NOT_PRESENT' END,
            'PLAN_XML',N'Threaddetails werden nur bei expliziter Anforderung ausgegeben.';
        INSERT [#ExecutionPlanAnalysis_Capabilities]
        SELECT @AnalysisObjectId,'PSP_VARIANT',CONVERT(bit,CASE WHEN (@PlanXml.exist('//*[@QueryVariantID]')=1 OR @PlanXml.exist('//*[@QueryVariantId]')=1) THEN 1 ELSE 0 END),
            CASE WHEN (@PlanXml.exist('//*[@QueryVariantID]')=1 OR @PlanXml.exist('//*[@QueryVariantId]')=1) THEN 'AVAILABLE' ELSE 'ELEMENT_NOT_PRESENT' END,
            'PLAN_XML',N'PSP-/Multiplanmerkmale werden anhand vorhandener XML-Attribute erkannt.';
        INSERT [#ExecutionPlanAnalysis_Capabilities]
        SELECT @AnalysisObjectId,'OPPO_VARIANT',CONVERT(bit,CASE WHEN @PlanXml.exist('//*[local-name(.)="OptionalPredicate"]')=1 THEN 1 ELSE 0 END),
            CASE WHEN @PlanXml.exist('//*[local-name(.)="OptionalPredicate"]')=1 THEN 'AVAILABLE' ELSE 'ELEMENT_NOT_PRESENT' END,
            'PLAN_XML',N'OPPO wird nur bei tatsächlich vorhandenem OptionalPredicate-Element ausgewiesen.';

        /* Explizite Planwarnungen. */
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT
              @AnalysisObjectId
            , CASE WHEN [EarlyAbortReason]=N'TimeOut' THEN 'OPTIMIZER_TIMEOUT' ELSE 'OPTIMIZER_EARLY_ABORT' END
            , 'COMPILE'
            , CASE WHEN [EarlyAbortReason]=N'TimeOut' THEN 'HIGH' ELSE 'INFO' END
            , 'COMPILE_WARNING','PLAN_XML',[StatementOrdinal],[StatementId],NULL,NULL,NULL
            , 'EARLY_ABORT_REASON',NULL,NULL,NULL,'EXPLICIT_PLAN_ATTRIBUTE',@WorkloadProfile
            , N'Die Optimierung wurde vor Abschluss des vollständigen Suchraums beendet.'
            , CONCAT(N'Reason=',[EarlyAbortReason])
            , N'GoodEnoughPlanFound kann normal sein; TimeOut ist ein Vertiefungshinweis, aber kein Beweis eines schlechten Plans.'
            , NULL,N'Compilezeit, Joinkomplexität und Query-Store-Historie prüfen.'
        FROM [#ExecutionPlanAnalysis_Statements]
        WHERE [AnalysisObjectId]=@AnalysisObjectId AND [EarlyAbortReason] IS NOT NULL;

        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT
              @AnalysisObjectId,'NO_JOIN_PREDICATE','JOIN','HIGH','COMPILE_WARNING','PLAN_XML'
            , [st].[StatementOrdinal],[st].[StatementId]
            , TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , NULLIF([r].[n].value('string((@PhysicalOp)[1])','nvarchar(128)'),N'')
            , NULLIF([r].[n].value('string((@LogicalOp)[1])','nvarchar(128)'),N'')
            , NULL,NULL,NULL,NULL,'EXPLICIT_PLAN_WARNING',@WorkloadProfile
            , N'Ein Joinoperator besitzt laut Plan keine Joinbedingung.'
            , N'Warnings/@NoJoinPredicate=1.'
            , N'Ein fachlich beabsichtigtes kartesisches Produkt ist möglich.'
            , NULL,N'Querytext und erwartete Ergebnismenge prüfen.'
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"]') AS [r]([n])
        WHERE [r].[n].exist('./*[local-name(.)="Warnings"][@NoJoinPredicate="1"]')=1;

        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT
              @AnalysisObjectId,'PLAN_AFFECTING_CONVERT','PREDICATE','HIGH','COMPILE_WARNING','PLAN_XML'
            , [st].[StatementOrdinal],[st].[StatementId],NULL,NULL,NULL,NULL,NULL,NULL,NULL
            , 'EXPLICIT_PLAN_WARNING',@WorkloadProfile
            , N'Eine implizite Konvertierung kann Seek- oder Kardinalitätsentscheidungen beeinflussen.'
            , LEFT(CONCAT(N'Issue=',[p].[n].value('string((@ConvertIssue)[1])','nvarchar(256)'),N'; Expression=',[p].[n].value('string((@Expression)[1])','nvarchar(3000)')),4000)
            , N'Nicht jede implizite Konvertierung beeinflusst den Zugriff; die PlanAffectingConvert-Warnung besitzt höhere Evidenz als ein bloßer ScalarString-Treffer.'
            , NULL,N'Datentypen auf Spalten- und Parameterseite vergleichen.'
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="PlanAffectingConvert"]') AS [p]([n]);

        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT
              @AnalysisObjectId,'COLUMN_WITHOUT_STATISTICS','STATISTICS','HIGH','COMPILE_WARNING','PLAN_XML'
            , [st].[StatementOrdinal],[st].[StatementId],NULL,NULL,NULL,NULL,NULL,NULL,NULL
            , 'EXPLICIT_PLAN_WARNING',@WorkloadProfile
            , N'Der Plan meldet eine Spaltenreferenz ohne verfügbare Statistik.'
            , N'ColumnsWithNoStatistics wurde im Plan gespeichert.'
            , N'Die Ursache kann Sichtbarkeit, temporäre Struktur oder Featuresemantik sein; ein Statistik-Create ist keine automatische Folgerung.'
            , NULL,N'Objektart, Spaltenrolle und aktuelle Statistikmetadaten prüfen.'
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        WHERE [st].[StatementXml].exist('.//*[local-name(.)="ColumnsWithNoStatistics"]')=1;

        /* Spills sind explizite Runtimeevidenz. */
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT
              @AnalysisObjectId
            , CASE WHEN [SpillKind] LIKE '%Hash%' THEN 'HASH_SPILL'
                   WHEN [SpillKind] LIKE '%Sort%' THEN 'SORT_SPILL'
                   WHEN [SpillKind] LIKE '%Exchange%' THEN 'EXCHANGE_SPILL'
                   ELSE 'TEMPDB_SPILL' END
            , 'TEMPDB','HIGH','EXPLICIT_RUNTIME_WARNING','PLAN_XML'
            , [m].[StatementOrdinal],[m].[StatementId],[m].[NodeId]
            , [o].[PhysicalOp],[o].[LogicalOp]
            , 'SPILLED_DATA_SIZE',[m].[SpilledDataSize],'source unit',NULL,'EXPLICIT_PLAN_WARNING',@WorkloadProfile
            , N'Ein Operator hat während der erfassten Ausführung nach tempdb ausgelagert.'
            , CONCAT(N'SpillKind=',[m].[SpillKind],N'; SpillLevel=',COALESCE(CONVERT(nvarchar(30),[m].[SpillLevel]),N'<NULL>'))
            , N'Ein kleiner einmaliger Spill muss nicht die Hauptursache sein; Menge, Wiederholung, Grant und Gesamtlaufzeit gemeinsam bewerten.'
            , NULL,N'Memory Grant, Kardinalität und STATISTICS IO/TIME korrelieren.'
        FROM [#ExecutionPlanAnalysis_MemoryAndSpills] AS [m]
        LEFT JOIN [#ExecutionPlanAnalysis_Operators] AS [o]
          ON [o].[AnalysisObjectId]=[m].[AnalysisObjectId]
         AND [o].[StatementOrdinal]=[m].[StatementOrdinal]
         AND [o].[NodeId]=[m].[NodeId]
        WHERE [m].[AnalysisObjectId]=@AnalysisObjectId AND [m].[RecordType]='SPILL';

        /* Workloadabhängige Cardinality-, Rows-Read-, Lookup- und Scanregeln. */
        ;WITH [Candidate] AS
        (
            SELECT [r].*,[o].[PhysicalOp],[o].[LogicalOp]
            FROM [#ExecutionPlanAnalysis_OperatorRuntime] AS [r]
            JOIN [#ExecutionPlanAnalysis_Operators] AS [o]
              ON [o].[AnalysisObjectId]=[r].[AnalysisObjectId]
             AND [o].[StatementOrdinal]=[r].[StatementOrdinal]
             AND [o].[NodeId]=[r].[NodeId]
            WHERE [r].[AnalysisObjectId]=@AnalysisObjectId
              AND [r].[ActualToEstimatedRatio] IS NOT NULL
        ),
        [Matched] AS
        (
            SELECT [c].*,[t].[Severity],[t].[MinRatio],[t].[MinAbsoluteRows],
                   ROW_NUMBER() OVER
                   (PARTITION BY [c].[StatementOrdinal],[c].[NodeId]
                    ORDER BY CASE [t].[Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END DESC) [rn]
            FROM [Candidate] AS [c]
            JOIN [monitor].[PlanAnalysisRuleThreshold] AS [t]
              ON [t].[RuleCode]='CARDINALITY_UNDERESTIMATE'
             AND [t].[ProfileCode]=@WorkloadProfile AND [t].[IsEnabled]=1
             AND [c].[ActualToEstimatedRatio]>=[t].[MinRatio]
             AND ABS(COALESCE([c].[ActualRows],0)-COALESCE([c].[EstimatedRowsTotal],0))>=COALESCE([t].[MinAbsoluteRows],0)
        )
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'CARDINALITY_UNDERESTIMATE','CARDINALITY',[Severity],'RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],[NodeId],[PhysicalOp],[LogicalOp],
               'ACTUAL_TO_ESTIMATED_RATIO',[ActualToEstimatedRatio],'ratio',[MinRatio],'PlanAnalysisRuleThreshold',@WorkloadProfile,
               N'Der Operator lieferte wesentlich mehr Zeilen als für seine gesamte Ausführungszahl geschätzt.',
               CONCAT(N'EstimatedTotal=',[EstimatedRowsTotal],N'; Actual=',[ActualRows]),
               N'Die Gesamtabschätzung verwendet EstimateExecutions beziehungsweise Rebind-/Rewind-Angaben als dokumentierte Näherung.',
               NULL,N'Ersten ursächlichen Schätzfehler im Datenfluss, Statistiken und Parameterverteilung prüfen.'
        FROM [Matched] WHERE [rn]=1;

        ;WITH [Candidate] AS
        (
            SELECT [r].*,[o].[PhysicalOp],[o].[LogicalOp]
            FROM [#ExecutionPlanAnalysis_OperatorRuntime] AS [r]
            JOIN [#ExecutionPlanAnalysis_Operators] AS [o]
              ON [o].[AnalysisObjectId]=[r].[AnalysisObjectId]
             AND [o].[StatementOrdinal]=[r].[StatementOrdinal]
             AND [o].[NodeId]=[r].[NodeId]
            WHERE [r].[AnalysisObjectId]=@AnalysisObjectId
              AND [r].[ActualToEstimatedRatio] IS NOT NULL
        ),
        [Matched] AS
        (
            SELECT [c].*,[t].[Severity],[t].[MaxRatio],[t].[MinAbsoluteRows],
                   ROW_NUMBER() OVER
                   (PARTITION BY [c].[StatementOrdinal],[c].[NodeId]
                    ORDER BY CASE [t].[Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END DESC) [rn]
            FROM [Candidate] AS [c]
            JOIN [monitor].[PlanAnalysisRuleThreshold] AS [t]
              ON [t].[RuleCode]='CARDINALITY_OVERESTIMATE'
             AND [t].[ProfileCode]=@WorkloadProfile AND [t].[IsEnabled]=1
             AND [c].[ActualToEstimatedRatio]<=[t].[MaxRatio]
             AND ABS(COALESCE([c].[ActualRows],0)-COALESCE([c].[EstimatedRowsTotal],0))>=COALESCE([t].[MinAbsoluteRows],0)
        )
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'CARDINALITY_OVERESTIMATE','CARDINALITY',[Severity],'RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],[NodeId],[PhysicalOp],[LogicalOp],
               'ACTUAL_TO_ESTIMATED_RATIO',[ActualToEstimatedRatio],'ratio',[MaxRatio],'PlanAnalysisRuleThreshold',@WorkloadProfile,
               N'Der Operator lieferte wesentlich weniger Zeilen als für seine gesamte Ausführungszahl geschätzt.',
               CONCAT(N'EstimatedTotal=',[EstimatedRowsTotal],N'; Actual=',[ActualRows]),
               N'Die Gesamtabschätzung verwendet EstimateExecutions beziehungsweise Rebind-/Rewind-Angaben als dokumentierte Näherung.',
               NULL,N'Memory Grant, Joinwahl, Statistiken und Parameterverteilung prüfen.'
        FROM [Matched] WHERE [rn]=1;

        ;WITH [Matched] AS
        (
            SELECT [a].*,[t].[Severity],[t].[MinRowsRead],[t].[MinRowsNotReturned],[t].[MinRowsNotReturnedPercent],
                   ROW_NUMBER() OVER
                   (PARTITION BY [a].[StatementOrdinal],[a].[NodeId]
                    ORDER BY CASE [t].[Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END DESC) [rn]
            FROM [#ExecutionPlanAnalysis_AccessPaths] AS [a]
            JOIN [monitor].[PlanAnalysisRuleThreshold] AS [t]
              ON [t].[RuleCode]='ROWS_READ_NOT_RETURNED'
             AND [t].[ProfileCode]=@WorkloadProfile AND [t].[IsEnabled]=1
             AND [a].[ActualRowsRead]>=COALESCE([t].[MinRowsRead],0)
             AND [a].[RowsReadNotReturned]>=COALESCE([t].[MinRowsNotReturned],0)
             AND [a].[RowsReadNotReturnedPercent]>=COALESCE([t].[MinRowsNotReturnedPercent],0)
            WHERE [a].[AnalysisObjectId]=@AnalysisObjectId
        )
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'ROWS_READ_NOT_RETURNED','ACCESS_PATH',[Severity],'RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],[NodeId],[PhysicalOp],[LogicalOp],
               'ROWS_READ_NOT_RETURNED_PERCENT',[RowsReadNotReturnedPercent],'percent',[MinRowsNotReturnedPercent],
               'PlanAnalysisRuleThreshold',@WorkloadProfile,
               N'Der Access-Operator las wesentlich mehr Zeilen als er weitergab.',
               CONCAT(N'RowsRead=',[ActualRowsRead],N'; RowsReturned=',[ActualRows],N'; NotReturned=',[RowsReadNotReturned]),
               N'Nur gepaarte ActualRows-/ActualRowsRead-Counter werden verwendet. Das Finding heißt nur bei nachgewiesenem Predicate ResidualDiscard.',
               NULL,N'Seek- und Residual-Predicate, Indexschlüsselreihenfolge und Selektivität prüfen.'
        FROM [Matched] WHERE [rn]=1;

        ;WITH [Matched] AS
        (
            SELECT [a].*,[t].[Severity],[t].[MinExecutionCount],
                   ROW_NUMBER() OVER
                   (PARTITION BY [a].[StatementOrdinal],[a].[NodeId]
                    ORDER BY CASE [t].[Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END DESC) [rn]
            FROM [#ExecutionPlanAnalysis_AccessPaths] AS [a]
            JOIN [monitor].[PlanAnalysisRuleThreshold] AS [t]
              ON [t].[RuleCode]='LOOKUP_HIGH_EXECUTIONS'
             AND [t].[ProfileCode]=@WorkloadProfile AND [t].[IsEnabled]=1
             AND [a].[ActualExecutions]>=COALESCE([t].[MinExecutionCount],0)
            WHERE [a].[AnalysisObjectId]=@AnalysisObjectId AND [a].[IsLookup]=1
        )
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'LOOKUP_HIGH_EXECUTIONS','ACCESS_PATH',[Severity],'RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],[NodeId],[PhysicalOp],[LogicalOp],
               'ACTUAL_EXECUTIONS',CONVERT(decimal(38,4),[ActualExecutions]),'executions',CONVERT(decimal(38,4),[MinExecutionCount]),
               'PlanAnalysisRuleThreshold',@WorkloadProfile,
               N'Ein Lookup wurde in der erfassten Ausführung sehr häufig aufgerufen.',
               CONCAT(N'ActualExecutions=',[ActualExecutions],N'; ActualRowsRead=',[ActualRowsRead]),
               N'Lookupexistenz allein ist kein Problem; die Bewertung erfordert tatsächliche Wiederholung und Arbeit.',
               NULL,N'Coverage, Indexbreite, DML-Kosten und alternative Joinformen prüfen.'
        FROM [Matched] WHERE [rn]=1;

        ;WITH [Matched] AS
        (
            SELECT [a].*,[t].[Severity],[t].[MinRowsRead],
                   ROW_NUMBER() OVER
                   (PARTITION BY [a].[StatementOrdinal],[a].[NodeId]
                    ORDER BY CASE [t].[Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END DESC) [rn]
            FROM [#ExecutionPlanAnalysis_AccessPaths] AS [a]
            JOIN [monitor].[PlanAnalysisRuleThreshold] AS [t]
              ON [t].[RuleCode]='LARGE_SCAN'
             AND [t].[ProfileCode]=@WorkloadProfile AND [t].[IsEnabled]=1
             AND [a].[ActualRowsRead]>=COALESCE([t].[MinRowsRead],0)
            WHERE [a].[AnalysisObjectId]=@AnalysisObjectId AND [a].[PhysicalOp] LIKE N'%Scan%'
        )
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'LARGE_SCAN_HIGH_WORK','ACCESS_PATH',[Severity],'RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],[NodeId],[PhysicalOp],[LogicalOp],
               'ACTUAL_ROWS_READ',[ActualRowsRead],'rows',[MinRowsRead],
               'PlanAnalysisRuleThreshold',@WorkloadProfile,
               N'Ein Scan verarbeitete eine für das Workloadprofil relevante Datenmenge.',
               CONCAT(N'ActualRowsRead=',[ActualRowsRead],N'; ActualRows=',[ActualRows]),
               N'Ein großer Scan kann bei Batch-, Reporting- oder Wartungsworkloads optimal sein.',
               NULL,N'STATISTICS IO, Rückgabeanteil, Partition Elimination und Columnstore-Eignung prüfen.'
        FROM [Matched] WHERE [rn]=1;

        /* Memory Grant: Vollauslastung allein ist kein Undergrantbeweis. */
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'MEMORY_GRANT_WAIT','MEMORY','HIGH','RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],NULL,NULL,NULL,'GRANT_WAIT_MS',CONVERT(decimal(38,4),[GrantWaitTimeMs]),'ms',0,
               'EXPLICIT_RUNTIME_VALUE',@WorkloadProfile,
               N'Die erfasste Ausführung wartete auf den Memory Grant.',
               CONCAT(N'GrantWaitMs=',[GrantWaitTimeMs],N'; RequestedKB=',[RequestedMemoryKb],N'; GrantedKB=',[GrantedMemoryKb]),
               N'Ein isolierter kurzer Wait muss mit gleichzeitigem Server-Memorydruck korreliert werden.',
               NULL,N'Current Memory Grants, Resource Semaphore und Konkurrenzsituation prüfen.'
        FROM [#ExecutionPlanAnalysis_MemoryAndSpills]
        WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RecordType]='MEMORY_GRANT' AND COALESCE([GrantWaitTimeMs],0)>0;

        ;WITH [Matched] AS
        (
            SELECT [m].*,[t].[Severity],[t].[MinRatio],[t].[MinMemoryKb],
                   [GrantWasteRatio]=CONVERT(decimal(38,8),CONVERT(decimal(38,12),[m].[GrantedMemoryKb])
                      /NULLIF(CONVERT(decimal(38,12),[m].[MaxUsedMemoryKb]),CONVERT(decimal(38,12),0))),
                   ROW_NUMBER() OVER
                   (PARTITION BY [m].[StatementOrdinal]
                    ORDER BY CASE [t].[Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END DESC) [rn]
            FROM [#ExecutionPlanAnalysis_MemoryAndSpills] AS [m]
            JOIN [monitor].[PlanAnalysisRuleThreshold] AS [t]
              ON [t].[RuleCode]='MEMORY_GRANT_OVER'
             AND [t].[ProfileCode]=@WorkloadProfile AND [t].[IsEnabled]=1
             AND [m].[GrantedMemoryKb]>=COALESCE([t].[MinMemoryKb],0)
             AND [m].[MaxUsedMemoryKb]>0
             AND CONVERT(decimal(38,8),CONVERT(decimal(38,12),[m].[GrantedMemoryKb])
                 /NULLIF(CONVERT(decimal(38,12),[m].[MaxUsedMemoryKb]),CONVERT(decimal(38,12),0)))>=[t].[MinRatio]
            WHERE [m].[AnalysisObjectId]=@AnalysisObjectId AND [m].[RecordType]='MEMORY_GRANT'
        )
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'MEMORY_GRANT_OVER','MEMORY',[Severity],'RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],NULL,NULL,NULL,'GRANTED_TO_USED_RATIO',[GrantWasteRatio],'ratio',[MinRatio],
               'PlanAnalysisRuleThreshold',@WorkloadProfile,
               N'Der gewährte Memory Grant lag deutlich über der maximal gemessenen Nutzung.',
               CONCAT(N'GrantedKB=',[GrantedMemoryKb],N'; MaxUsedKB=',[MaxUsedMemoryKb]),
               N'Ein einzelner Last-Actual-Plan bildet nur eine Ausführung ab; Memory Grant Feedback und Parameterstreuung können den Befund erklären.',
               NULL,N'Query-Store-Verteilung und Memory Grant Feedback prüfen.'
        FROM [Matched] WHERE [rn]=1;

        /* Parallel Thread Skew bei verfügbarer Threadverteilung. */
        ;WITH [ThreadStats] AS
        (
            SELECT
                  [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
                , [ThreadCount]=COUNT(*)
                , [TotalRows]=SUM(COALESCE([ActualRows],0))
                , [MaxRows]=MAX(COALESCE([ActualRows],0))
                , [AverageRows]=AVG(CONVERT(decimal(38,8),COALESCE([ActualRows],0)))
            FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime]
            WHERE [AnalysisObjectId]=@AnalysisObjectId
            GROUP BY [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
        ),
        [Matched] AS
        (
            SELECT [s].*,[o].[PhysicalOp],[o].[LogicalOp],[t].[Severity],[t].[MinRatio],[t].[MinAbsoluteRows],
                   [SkewRatio]=CONVERT(decimal(38,8),[s].[MaxRows]/NULLIF([s].[AverageRows],0)),
                   ROW_NUMBER() OVER
                   (PARTITION BY [s].[StatementOrdinal],[s].[NodeId]
                    ORDER BY CASE [t].[Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END DESC) [rn]
            FROM [ThreadStats] AS [s]
            JOIN [#ExecutionPlanAnalysis_Operators] AS [o]
              ON [o].[AnalysisObjectId]=[s].[AnalysisObjectId]
             AND [o].[StatementOrdinal]=[s].[StatementOrdinal]
             AND [o].[NodeId]=[s].[NodeId]
            JOIN [monitor].[PlanAnalysisRuleThreshold] AS [t]
              ON [t].[RuleCode]='PARALLEL_THREAD_SKEW'
             AND [t].[ProfileCode]=@WorkloadProfile AND [t].[IsEnabled]=1
             AND [s].[ThreadCount]>=COALESCE(TRY_CONVERT(int,JSON_VALUE([t].[AdditionalConfigurationJson],'$.minimumThreads')),4)
             AND [s].[TotalRows]>=COALESCE([t].[MinAbsoluteRows],0)
             AND CONVERT(decimal(38,8),[s].[MaxRows]/NULLIF([s].[AverageRows],0))>=[t].[MinRatio]
        )
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'PARALLEL_THREAD_SKEW','PARALLELISM',[Severity],'RUNTIME_MEASURED','PLAN_XML',
               [StatementOrdinal],[StatementId],[NodeId],[PhysicalOp],[LogicalOp],
               'MAX_TO_AVERAGE_THREAD_ROWS',[SkewRatio],'ratio',[MinRatio],
               'PlanAnalysisRuleThreshold',@WorkloadProfile,
               N'Die Zeilenarbeit war zwischen parallelen Workerthreads stark ungleich verteilt.',
               CONCAT(N'Threads=',[ThreadCount],N'; TotalRows=',[TotalRows],N'; MaxRows=',[MaxRows],N'; AverageRows=',[AverageRows]),
               N'Threadwerte können bei kurzen oder partiellen Live-Plänen unvollständig sein.',
               NULL,N'Partitionierungs-/Hashverteilung, Predicate-Skew und Exchange-Operatoren prüfen.'
        FROM [Matched] WHERE [rn]=1;

        /* Sortoperatoren werden als Review, nicht als automatischer Indexfehler bewertet. */
        INSERT [#ExecutionPlanAnalysis_Findings]
        (
              [AnalysisObjectId],[FindingCode],[Category],[Severity],[Confidence]
            , [EvidenceLevel],[StatementOrdinal],[StatementId],[NodeId]
            , [PhysicalOp],[LogicalOp],[MetricName],[MetricValue],[MetricUnit]
            , [ThresholdValue],[ThresholdSource],[WorkloadProfile]
            , [Summary],[Evidence],[EvidenceLimit],[CounterEvidence],[RecommendedNextCheck]
        )
        SELECT @AnalysisObjectId,'INDEX_ORDER_REVIEW','INDEX_ORDER',
               CASE WHEN COALESCE([r].[ActualRows],[o].[EstimateRows])>=1000000 THEN 'MEDIUM' ELSE 'INFO' END,
               CASE WHEN [r].[ActualRows] IS NULL THEN 'COMPILE_HEURISTIC' ELSE 'RUNTIME_INFERRED' END,
               CASE WHEN [r].[ActualRows] IS NULL THEN 'PLAN_XML_ESTIMATE' ELSE 'PLAN_XML_RUNTIME' END,
               [o].[StatementOrdinal],[o].[StatementId],[o].[NodeId],[o].[PhysicalOp],[o].[LogicalOp],
               'SORT_ROWS',COALESCE([r].[ActualRows],[o].[EstimateRows]),'rows',NULL,'STRUCTURAL_REVIEW',@WorkloadProfile,
               N'Ein Sortoperator zeigt eine benötigte Reihenfolge, die vom direkten Eingabepfad nicht garantiert wurde.',
               CONCAT(N'Rows=',COALESCE(CONVERT(nvarchar(100),[r].[ActualRows]),CONVERT(nvarchar(100),[o].[EstimateRows]))),
               N'Daraus folgt nicht automatisch, dass ein Index falsch sortiert ist; Gleichheitspräfix, ASC/DESC, Backward Scan, andere Workloads und DML-Kosten fehlen möglicherweise.',
               NULL,N'Sort Keys mit Indexschlüsselreihenfolge und ScanDirection vergleichen.'
        FROM [#ExecutionPlanAnalysis_Operators] AS [o]
        LEFT JOIN [#ExecutionPlanAnalysis_OperatorRuntime] AS [r]
          ON [r].[AnalysisObjectId]=[o].[AnalysisObjectId]
         AND [r].[StatementOrdinal]=[o].[StatementOrdinal]
         AND [r].[NodeId]=[o].[NodeId]
        WHERE [o].[AnalysisObjectId]=@AnalysisObjectId AND [o].[PhysicalOp]=N'Sort';

        IF @MitThreadRuntime=0
            DELETE FROM [#ExecutionPlanAnalysis_OperatorThreadRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId;

        /*
          DIAG-005: Die normalisierten Resultsets werden ausschließlich aus
          bereits materialisierter Plan-, Runtime- und Cacheevidenz abgeleitet.
          Der Plan wird hier weder erneut beschafft noch erneut als Ganzes
          zerlegt; die Statement-XML-Fragmente sind Teil desselben Shreddinglaufs.
        */
        INSERT [#ExecutionPlanAnalysis_PlanWarnings]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [WarningCode],[WarningCategory],[Severity],[EvidenceKind],[EvidenceSource]
            , [PlanSource],[SourceObservedAtUtc],[IsCurrent],[IsLastKnown]
            , [IsMeasured],[IsInferred],[MetricName],[MetricValue],[MetricUnit]
            , [Detail],[FalsePositiveGuard],[StatusCode]
        )
        SELECT
              @AnalysisObjectId,[f].[StatementOrdinal],[f].[StatementId],[f].[NodeId]
            , [f].[FindingCode],[f].[Category],[f].[Severity],[f].[Confidence],[f].[EvidenceLevel]
            , @PlanSource,@SourceObservedAtUtc
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END)
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END)
            , CONVERT(bit,CASE WHEN [f].[Confidence]='EXPLICIT_RUNTIME_WARNING' THEN 1 ELSE 0 END)
            , CONVERT(bit,CASE WHEN [f].[Confidence]='EXPLICIT_RUNTIME_WARNING' THEN 0 ELSE 1 END)
            , [f].[MetricName],[f].[MetricValue],[f].[MetricUnit]
            , [f].[Evidence],[f].[EvidenceLimit],'AVAILABLE'
        FROM [#ExecutionPlanAnalysis_Findings] AS [f]
        WHERE [f].[AnalysisObjectId]=@AnalysisObjectId
          AND [f].[Confidence] IN ('COMPILE_WARNING','EXPLICIT_RUNTIME_WARNING');

        IF NOT EXISTS
           (
               SELECT 1
               FROM [#ExecutionPlanAnalysis_PlanWarnings]
               WHERE [AnalysisObjectId]=@AnalysisObjectId
           )
            INSERT [#ExecutionPlanAnalysis_PlanWarnings]
            (
                  [AnalysisObjectId],[WarningCode],[WarningCategory],[Severity]
                , [EvidenceKind],[EvidenceSource],[PlanSource],[SourceObservedAtUtc]
                , [IsCurrent],[IsLastKnown],[IsMeasured],[IsInferred]
                , [Detail],[FalsePositiveGuard],[StatusCode]
            )
            VALUES
            (
                  @AnalysisObjectId,'NO_EXPLICIT_WARNING','SOURCE_STATUS','INFO'
                , 'SOURCE_STATUS','PLAN_XML',@PlanSource,@SourceObservedAtUtc
                , CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END
                , CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END
                , 0,0
                , N'Das analysierte Plan-XML enthält keine unterstützte explizite Warnung.'
                , N'Keine Warnung bedeutet nicht, dass der Plan optimal ist; nur explizite und eng belegte Warnungsmuster werden hier normalisiert.'
                , 'AVAILABLE'
            );

        INSERT [#ExecutionPlanAnalysis_OptimizerContext]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[PlanSource],[RuntimeCounterScope]
            , [SourceObservedAtUtc],[IsCurrent],[IsLastKnown]
            , [OptimizationLevel],[EarlyAbortReason],[CardinalityEstimationModelVersion]
            , [StatementSubTreeCost],[StatementEstimatedRows]
            , [CompileTimeMs],[CompileCpuMs],[CompileMemoryKb]
            , [RetrievedFromCache],[NonParallelPlanReason],[PlanDegreeOfParallelism]
            , [PlanGenerationNum],[CacheCreationTime],[CacheLastExecutionTime],[CacheExecutionCount]
            , [CacheObjectType],[CacheObjectClass],[CacheUseCounts],[CacheRefCounts]
            , [CacheSizeBytes],[CachePoolId],[SetOptions],[CompileUserId],[DatabaseId]
            , [EvidenceMeasurement],[StatusCode],[FalsePositiveGuard]
        )
        SELECT
              @AnalysisObjectId,[s].[StatementOrdinal],[s].[StatementId],@PlanSource,@RuntimeCounterScope
            , @SourceObservedAtUtc
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END)
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END)
            , [s].[OptimizationLevel],[s].[EarlyAbortReason],[s].[CardinalityEstimationModelVersion]
            , [s].[StatementSubTreeCost],[s].[StatementEstimatedRows]
            , [s].[CompileTimeMs],[s].[CompileCpuMs],[s].[CompileMemoryKb]
            , [s].[RetrievedFromCache],[s].[NonParallelPlanReason]
            , TRY_CONVERT(int,NULLIF([x].[StatementXml].value(
                  'string((.//*[local-name(.)="QueryPlan"]/@DegreeOfParallelism)[1])','nvarchar(100)'),N''))
            , [c].[PlanGenerationNum],[c].[CacheCreationTime],[c].[CacheLastExecutionTime],[c].[ExecutionCount]
            , [c].[CacheObjectType],[c].[CacheObjectClass],[c].[CacheUseCounts],[c].[CacheRefCounts]
            , [c].[CacheSizeBytes],[c].[CachePoolId],[c].[SetOptions],[c].[CompileUserId],[c].[DatabaseId]
            , CASE WHEN [c].[StatusCode]='AVAILABLE' THEN 'PLAN_AND_CACHE_MEASURED' ELSE 'PLAN_MEASURED' END
            , CASE WHEN [c].[StatusCode] IS NULL THEN 'PLAN_ONLY'
                   WHEN [c].[StatusCode]='AVAILABLE' THEN 'AVAILABLE'
                   ELSE [c].[StatusCode] END
            , N'Optimizer- und Cacheattribute beschreiben die beobachtete Kompilierung beziehungsweise einen flüchtigen Cachezustand; sie beweisen allein keine Regressionsursache.'
        FROM [#ExecutionPlanAnalysis_Statements] AS [s]
        JOIN [#InternalAnalyzeExecutionPlan_StatementXml] AS [x]
          ON [x].[StatementOrdinal]=[s].[StatementOrdinal]
        OUTER APPLY
        (
            SELECT TOP (1) *
            FROM [#ExecutionPlanAnalysis_SourceContext]
            WHERE [AnalysisObjectId]=@AnalysisObjectId
            ORDER BY [SourceCapturedAtUtc] DESC
        ) AS [c]
        WHERE [s].[AnalysisObjectId]=@AnalysisObjectId;

        INSERT [#ExecutionPlanAnalysis_RuntimeFeedback]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [FeedbackType],[FeedbackState],[MetricName],[ObservedValue],[BaselineValue]
            , [DeltaRatio],[MetricUnit],[RuntimeCounterScope],[EvidenceSource]
            , [SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
            , [StatusCode],[EvidenceLimit]
        )
        SELECT
              @AnalysisObjectId,[r].[StatementOrdinal],[r].[StatementId],[r].[NodeId]
            , 'CARDINALITY_OBSERVATION',[r].[RuntimeMetricStatus]
            , 'ACTUAL_TO_ESTIMATED_ROWS',[r].[ActualRows],[r].[EstimatedRowsTotal]
            , [r].[ActualToEstimatedRatio],'ratio',@RuntimeCounterScope,'PLAN_XML_RUNTIME'
            , @SourceObservedAtUtc
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END)
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END)
            , 1,1,'AVAILABLE'
            , N'Die Abweichung gilt nur für den erfassten Runtime-Scope und wird nicht als dauerhafte Kardinalitätsregression verallgemeinert.'
        FROM [#ExecutionPlanAnalysis_OperatorRuntime] AS [r]
        WHERE [r].[AnalysisObjectId]=@AnalysisObjectId
          AND [r].[RuntimeCounterCount]>0
          AND [r].[ActualRows] IS NOT NULL
          AND [r].[EstimatedRowsTotal] IS NOT NULL;

        INSERT [#ExecutionPlanAnalysis_RuntimeFeedback]
        (
              [AnalysisObjectId],[StatementOrdinal],[StatementId],[NodeId]
            , [FeedbackType],[FeedbackState],[MetricName],[ObservedValue],[BaselineValue]
            , [DeltaRatio],[MetricUnit],[RuntimeCounterScope],[EvidenceSource]
            , [SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
            , [StatusCode],[EvidenceLimit]
        )
        SELECT
              @AnalysisObjectId,[m].[StatementOrdinal],[m].[StatementId],[m].[NodeId]
            , CASE WHEN [m].[RecordType]='MEMORY_GRANT' THEN 'MEMORY_GRANT_OBSERVATION' ELSE 'SPILL_OBSERVATION' END
            , COALESCE([m].[MemoryGrantFeedbackState],[m].[SpillKind])
            , CASE WHEN [m].[RecordType]='MEMORY_GRANT' THEN 'GRANTED_MEMORY_KB' ELSE 'SPILLED_DATA_SIZE' END
            , CONVERT(decimal(38,4),CASE WHEN [m].[RecordType]='MEMORY_GRANT' THEN [m].[GrantedMemoryKb] ELSE [m].[SpilledDataSize] END)
            , CONVERT(decimal(38,4),CASE WHEN [m].[RecordType]='MEMORY_GRANT' THEN [m].[MaxUsedMemoryKb] END)
            , CASE WHEN [m].[RecordType]='MEMORY_GRANT' AND COALESCE([m].[MaxUsedMemoryKb],0)>0
                   THEN CONVERT(decimal(38,8),CONVERT(decimal(38,12),[m].[GrantedMemoryKb])
                        /NULLIF(CONVERT(decimal(38,12),[m].[MaxUsedMemoryKb]),0)) END
            , CASE WHEN [m].[RecordType]='MEMORY_GRANT' THEN 'KB' ELSE 'source unit' END
            , @RuntimeCounterScope,'PLAN_XML_RUNTIME',@SourceObservedAtUtc
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END)
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END)
            , 1,CONVERT(bit,CASE WHEN [m].[RecordType]='MEMORY_GRANT' THEN 1 ELSE 0 END)
            , 'AVAILABLE'
            , N'Memory-Grant- und Spillwerte gelten nur für den erfassten Plan; Wiederholung und Workloadverteilung bleiben außerhalb dieser Evidenz.'
        FROM [#ExecutionPlanAnalysis_MemoryAndSpills] AS [m]
        WHERE [m].[AnalysisObjectId]=@AnalysisObjectId;

        IF NOT EXISTS
           (
               SELECT 1
               FROM [#ExecutionPlanAnalysis_RuntimeFeedback]
               WHERE [AnalysisObjectId]=@AnalysisObjectId
           )
            INSERT [#ExecutionPlanAnalysis_RuntimeFeedback]
            (
                  [AnalysisObjectId],[FeedbackType],[FeedbackState],[RuntimeCounterScope]
                , [EvidenceSource],[SourceObservedAtUtc],[IsCurrent],[IsLastKnown]
                , [IsMeasured],[IsDerived],[StatusCode],[EvidenceLimit]
            )
            VALUES
            (
                  @AnalysisObjectId,'SOURCE_STATUS','NO_RUNTIME_COUNTERS',@RuntimeCounterScope
                , 'PLAN_XML',@SourceObservedAtUtc
                , CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END
                , CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END
                , 0,0,CASE WHEN @RuntimeCounterScope='NONE' THEN 'NOT_COLLECTED' ELSE 'AVAILABLE' END
                , N'Ohne passende Runtimecounter werden keine Laufzeitdeltas abgeleitet.'
            );

        INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
        (
              [AnalysisObjectId],[RecordType],[FeatureType],[StatementOrdinal],[StatementId],[NodeId]
            , [QueryVariantId],[FeatureState],[DataHandlingStatus],[EvidenceSource]
            , [SourceObservedAtUtc],[IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived]
            , [StatusCode],[EvidenceLimit]
        )
        SELECT
              @AnalysisObjectId,'PLAN_FEATURE',[v].[FeatureType],[st].[StatementOrdinal],[st].[StatementId],[v].[NodeId]
            , [v].[QueryVariantId],[v].[FeatureState],'NO_SENSITIVE_PAYLOAD','PLAN_XML'
            , @SourceObservedAtUtc
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END)
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END)
            , 1,0,'AVAILABLE'
            , N'Die Zeile belegt nur das im Plan sichtbare Feature beziehungsweise dessen Zustand; Wirksamkeit und Nutzen müssen über mehrere Ausführungen geprüft werden.'
        FROM [#InternalAnalyzeExecutionPlan_StatementXml] AS [st]
        CROSS APPLY
        (
            SELECT
                  'PARAMETER_SENSITIVE_PLAN' AS [FeatureType]
                , TRY_CONVERT(int,NULLIF([st].[StatementXml].value(
                    'string((.//*[@QueryVariantID][1]/@QueryVariantID)[1])','nvarchar(100)'),N'')) AS [QueryVariantId]
                , CONVERT(nvarchar(128),N'DISPATCHER_OR_VARIANT') AS [FeatureState]
                , CONVERT(int,NULL) AS [NodeId]
            WHERE [st].[StatementXml].exist('.//*[local-name(.)="ParameterSensitivePredicate" or @QueryVariantID]')=1
            UNION ALL
            SELECT 'MEMORY_GRANT_FEEDBACK',NULL,
                   NULLIF([st].[StatementXml].value(
                     'string((.//*[local-name(.)="MemoryGrantInfo"]/@IsMemoryGrantFeedbackAdjusted)[1])','nvarchar(128)'),N''),NULL
            WHERE [st].[StatementXml].exist('.//*[local-name(.)="MemoryGrantInfo"][@IsMemoryGrantFeedbackAdjusted]')=1
            UNION ALL
            SELECT 'ADAPTIVE_JOIN',NULL,N'PRESENT',
                   TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(100)'),N''))
            FROM [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"][@PhysicalOp="Adaptive Join"]') AS [r]([n])
            UNION ALL
            SELECT 'BATCH_MODE',NULL,N'PRESENT',
                   TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(100)'),N''))
            FROM [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"][@EstimatedExecutionMode="Batch" or @ActualExecutionMode="Batch"]') AS [r]([n])
        ) AS [v];

        IF NOT EXISTS
           (
               SELECT 1
               FROM [#ExecutionPlanAnalysis_FeedbackAndVariants]
               WHERE [AnalysisObjectId]=@AnalysisObjectId
           )
            INSERT [#ExecutionPlanAnalysis_FeedbackAndVariants]
            (
                  [AnalysisObjectId],[RecordType],[FeatureType],[FeatureState]
                , [DataHandlingStatus],[EvidenceSource],[SourceObservedAtUtc]
                , [IsCurrent],[IsLastKnown],[IsMeasured],[IsDerived],[StatusCode],[EvidenceLimit]
            )
            VALUES
            (
                  @AnalysisObjectId,'SOURCE_STATUS','NO_SUPPORTED_FEATURE',N'NOT_PRESENT'
                , 'NO_SENSITIVE_PAYLOAD','PLAN_XML',@SourceObservedAtUtc
                , CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END
                , CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END
                , 0,0,'AVAILABLE'
                , N'Nicht vorhandene Featuremarker schließen versions- oder kontextabhängige Optimizerfunktionen außerhalb dieses Plans nicht aus.'
            );

        DECLARE @MinSeverityRank int=CASE @MinSeverity WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END;
        DELETE FROM [#ExecutionPlanAnalysis_PlanWarnings]
        WHERE [AnalysisObjectId]=@AnalysisObjectId
          AND [WarningCode]<>'NO_EXPLICIT_WARNING'
          AND CASE [Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END<@MinSeverityRank;
        DELETE FROM [#ExecutionPlanAnalysis_Findings]
        WHERE [AnalysisObjectId]=@AnalysisObjectId
          AND CASE [Severity] WHEN 'CRITICAL' THEN 5 WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END<@MinSeverityRank;

        IF NOT EXISTS
           (
               SELECT 1
               FROM [#ExecutionPlanAnalysis_PlanWarnings]
               WHERE [AnalysisObjectId]=@AnalysisObjectId
           )
            INSERT [#ExecutionPlanAnalysis_PlanWarnings]
            (
                  [AnalysisObjectId],[WarningCode],[WarningCategory],[Severity]
                , [EvidenceKind],[EvidenceSource],[PlanSource],[SourceObservedAtUtc]
                , [IsCurrent],[IsLastKnown],[IsMeasured],[IsInferred]
                , [Detail],[FalsePositiveGuard],[StatusCode]
            )
            VALUES
            (
                  @AnalysisObjectId,'NO_WARNING_AT_OR_ABOVE_THRESHOLD','SOURCE_STATUS','INFO'
                , 'SOURCE_STATUS','PLAN_XML',@PlanSource,@SourceObservedAtUtc
                , CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 1 ELSE 0 END
                , CASE WHEN @RuntimeCounterScope='LAST_COMPLETED_EXECUTION' THEN 1 ELSE 0 END
                , 0,0
                , CONCAT(N'Unterhalb der angeforderten Mindestschwere ',@MinSeverity,N' vorhandene Warnungen wurden nicht ausgegeben.')
                , N'Ein gefiltertes Warnungsresultset beweist weder einen optimalen Plan noch eine fehlende Planquelle.'
                , 'AVAILABLE'
            );

        DECLARE @ShowplanVersion nvarchar(64)=NULLIF(@PlanXml.value('string((/*[local-name(.)="ShowPlanXML"]/@Version)[1])','nvarchar(64)'),N'');
        DECLARE @ShowplanBuild nvarchar(64)=NULLIF(@PlanXml.value('string((/*[local-name(.)="ShowPlanXML"]/@Build)[1])','nvarchar(64)'),N'');
        DECLARE @HasRuntime bit=CONVERT(bit,CASE WHEN EXISTS
            (SELECT 1 FROM [#ExecutionPlanAnalysis_OperatorRuntime] WHERE [AnalysisObjectId]=@AnalysisObjectId AND [RuntimeCounterCount]>0) THEN 1 ELSE 0 END);
        DECLARE @StatementCount int=(SELECT COUNT(*) FROM [#ExecutionPlanAnalysis_Statements] WHERE [AnalysisObjectId]=@AnalysisObjectId);
        DECLARE @OperatorCount int=(SELECT COUNT(*) FROM [#ExecutionPlanAnalysis_Operators] WHERE [AnalysisObjectId]=@AnalysisObjectId);
        DECLARE @CeVersion int=(SELECT MAX([CardinalityEstimationModelVersion]) FROM [#ExecutionPlanAnalysis_Statements] WHERE [AnalysisObjectId]=@AnalysisObjectId);
        DECLARE @PlanHash varbinary(32)=HASHBYTES('SHA2_256',CONVERT(varbinary(max),CONVERT(nvarchar(max),@PlanXml)));

        UPDATE [#ExecutionPlanAnalysis_ParameterEvidence]
        SET [PlanDocumentHash]=CONVERT(nvarchar(66),@PlanHash,1)
        WHERE [CandidateId]=@AnalysisObjectId;

        INSERT [#ExecutionPlanAnalysis_PlanDocuments]
        (
              [AnalysisObjectId],[PlanSource],[RuntimeCounterScope]
            , [ShowplanVersion],[ShowplanBuild],[SourceProductVersion]
            , [SourceCompatibilityLevel],[CardinalityEstimationModelVersion]
            , [IsPlanComplete],[PlanDocumentHash],[StatementCount]
            , [OperatorCount],[HasRuntimeCounters]
        )
        VALUES
        (
              @AnalysisObjectId,@PlanSource,@RuntimeCounterScope
            , @ShowplanVersion,@ShowplanBuild,NULL,NULL,@CeVersion
            , CONVERT(bit,CASE WHEN @RuntimeCounterScope='CURRENT_PARTIAL_EXECUTION' THEN 0 ELSE 1 END)
            , @PlanHash,@StatementCount,@OperatorCount,@HasRuntime
        );

        IF @IsPartialOut=1 AND @StatusCodeOut='AVAILABLE' SET @StatusCodeOut='PARTIAL';
    END TRY
    BEGIN CATCH
        SELECT @StatusCodeOut='ERROR_HANDLED',@IsPartialOut=1,
               @ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
    END CATCH;
END;
GO
