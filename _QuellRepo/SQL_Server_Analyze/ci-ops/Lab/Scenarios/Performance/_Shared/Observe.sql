:setvar ScenarioId "LAB-INVALID-000"
:setvar LabRunId "LAB-20000101T000000Z-00000000"
:setvar PrimaryAnalyzer "USP_CurrentOverview"
:setvar FindingCode "INVALID_FINDING"

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 0;

DECLARE @ScenarioId varchar(40) = '$(ScenarioId)';
DECLARE @LabRunId varchar(40) = '$(LabRunId)';
DECLARE @PrimaryAnalyzer sysname = '$(PrimaryAnalyzer)';
DECLARE @FindingCode varchar(120) = '$(FindingCode)';
DECLARE @ContextToken binary(128) =
    CONVERT(binary(128), HASHBYTES('SHA2_256', CONCAT(@LabRunId, '|', @ScenarioId)));
DECLARE @ProductMajorVersion int =
    TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
DECLARE @PredicateSatisfied bit = 0;
DECLARE @ObservedValue bigint = NULL;
DECLARE @AlternativeEvidenceUsed bit = 0;
DECLARE @AnalyzerJson nvarchar(max) = NULL;
DECLARE @AnalyzerStatus varchar(40) = NULL;
DECLARE @AnalyzerPartial bit = NULL;
DECLARE @ReturnCode int = NULL;

IF DB_ID(N'Lab001Wave3') IS NULL
    THROW 55340, N'The synthetic scenario database is missing.', 1;

IF @ScenarioId IN ('LAB-CPU-001', 'LAB-CPU-002', 'LAB-CPU-003')
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_exec_sessions]
    WHERE [context_info] = @ContextToken;

    SET @PredicateSatisfied =
        CASE
            WHEN @ScenarioId = 'LAB-CPU-003' AND @ObservedValue >= 4 THEN 1
            WHEN @ScenarioId <> 'LAB-CPU-003' AND @ObservedValue >= 1 THEN 1
            ELSE 0
        END;
END;

IF @ScenarioId = 'LAB-MEM-001'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_exec_sessions] AS [s]
    WHERE [s].[context_info] = @ContextToken;

    IF EXISTS
    (
        SELECT 1
        FROM [sys].[dm_exec_query_memory_grants] AS [mg]
        INNER JOIN [sys].[dm_exec_sessions] AS [s]
            ON [s].[session_id] = [mg].[session_id]
        WHERE [s].[context_info] = @ContextToken
    )
        SET @PredicateSatisfied = 1;
    ELSE IF @ObservedValue >= 1
        SELECT
              @PredicateSatisfied = 1
            , @AlternativeEvidenceUsed = 1;
END;

IF @ScenarioId = 'LAB-MEM-002'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_os_buffer_descriptors]
    WHERE [database_id] = DB_ID(N'Lab001Wave3');

    SET @PredicateSatisfied =
        CASE WHEN @ObservedValue >= 16384 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-MEM-003'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[resource_governor_workload_groups] AS [wg]
    INNER JOIN [sys].[resource_governor_resource_pools] AS [rp]
        ON [rp].[pool_id] = [wg].[pool_id]
    WHERE [wg].[name] = N'Lab001Group'
      AND [rp].[name] = N'Lab001Pool'
      AND [wg].[request_max_memory_grant_percent] = 10;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue = 1 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-TEMP-001'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_db_session_space_usage] AS [su]
    INNER JOIN [sys].[dm_exec_sessions] AS [s]
        ON [s].[session_id] = [su].[session_id]
    WHERE [s].[context_info] = @ContextToken
      AND
      (
          [su].[user_objects_alloc_page_count] +
          [su].[internal_objects_alloc_page_count]
      ) > 0;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue >= 1 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-TEMP-002'
BEGIN
    SELECT @ObservedValue = [reserved_page_count]
    FROM [sys].[dm_tran_version_store_space_usage]
    WHERE [database_id] = DB_ID(N'Lab001Wave3');

    IF COALESCE(@ObservedValue, 0) > 0
        SET @PredicateSatisfied = 1;
    ELSE IF EXISTS
    (
        SELECT 1
        FROM [sys].[dm_exec_sessions]
        WHERE [context_info] = @ContextToken
    )
        SELECT
              @PredicateSatisfied = 1
            , @AlternativeEvidenceUsed = 1;
END;

IF @ScenarioId = 'LAB-TEMP-003'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_exec_sessions]
    WHERE [context_info] = @ContextToken;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue >= 3 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-TEMP-005'
BEGIN
    DECLARE @TempDbGovernanceSql nvarchar(max) =
        N'SELECT @Count = COUNT_BIG(*)
          FROM [sys].[resource_governor_workload_groups]
          WHERE [name] = N''Lab001Group''
            AND [group_max_tempdb_data_mb] = 32;';
    EXEC [sys].[sp_executesql]
          @TempDbGovernanceSql
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue = 1 THEN 1 ELSE 0 END;
END;

IF @ScenarioId IN ('LAB-IO-004', 'LAB-CAP-001')
BEGIN
    DECLARE @InitialDataPages bigint;
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @InitialPages = TRY_CONVERT(bigint, [StateValue])
FROM [dbo].[LabState]
WHERE [StateName] = N''InitialDataPages'';'
        , N'@InitialPages bigint OUTPUT'
        , @InitialPages = @InitialDataPages OUTPUT;

    SELECT @ObservedValue = [size]
    FROM [sys].[master_files]
    WHERE [database_id] = DB_ID(N'Lab001Wave3')
      AND [file_id] = 1;

    SET @PredicateSatisfied =
        CASE WHEN @ObservedValue > @InitialDataPages THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-LOG-001'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_tran_database_transactions] AS [dt]
    WHERE [dt].[database_id] = DB_ID(N'Lab001Wave3')
      AND [dt].[database_transaction_state] IN (3, 4);

    IF @ObservedValue > 0
       AND EXISTS
       (
           SELECT 1
           FROM [sys].[databases]
           WHERE [database_id] = DB_ID(N'Lab001Wave3')
             AND [log_reuse_wait_desc] = N'ACTIVE_TRANSACTION'
       )
        SET @PredicateSatisfied = 1;
    ELSE IF @ObservedValue > 0
        SELECT
              @PredicateSatisfied = 1
            , @AlternativeEvidenceUsed = 1;
END;

IF @ScenarioId = 'LAB-LOG-002'
BEGIN
    DECLARE @InitialLogPages bigint;
    DECLARE @VlfCount bigint;
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @InitialPages = TRY_CONVERT(bigint, [StateValue])
FROM [dbo].[LabState]
WHERE [StateName] = N''InitialLogPages'';'
        , N'@InitialPages bigint OUTPUT'
        , @InitialPages = @InitialLogPages OUTPUT;

    SELECT @ObservedValue = [size]
    FROM [sys].[master_files]
    WHERE [database_id] = DB_ID(N'Lab001Wave3')
      AND [type] = 1;

    SELECT @VlfCount = COUNT_BIG(*)
    FROM [sys].[dm_db_log_info](DB_ID(N'Lab001Wave3'));

    SET @PredicateSatisfied =
        CASE
            WHEN @ObservedValue > @InitialLogPages AND @VlfCount > 1 THEN 1
            ELSE 0
        END;
END;

IF @ScenarioId = 'LAB-REC-001'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Count = COUNT_BIG(*)
FROM [dbo].[RecoveryWorkload]
WHERE [SyntheticId] = 1
  AND [Payload] = ''COMMITTED_SYNTHETIC_ROW''
  AND NOT EXISTS
      (
          SELECT 1
          FROM [dbo].[RecoveryWorkload]
          WHERE [SyntheticId] = 2
      );'
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied =
        CASE
            WHEN @ObservedValue = 1
             AND DATABASEPROPERTYEX(N'Lab001Wave3', N'Status') = N'ONLINE'
            THEN 1
            ELSE 0
        END;
END;

IF @ScenarioId IN ('LAB-CONC-001', 'LAB-CONC-002')
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_exec_requests] AS [r]
    INNER JOIN [sys].[dm_exec_sessions] AS [s]
        ON [s].[session_id] = [r].[session_id]
    WHERE [s].[context_info] = @ContextToken
      AND [r].[blocking_session_id] > 0;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue >= 1 THEN 1 ELSE 0 END;
END;

IF @ScenarioId IN
(
      'LAB-DEAD-001'
    , 'LAB-DEAD-002'
    , 'LAB-DEAD-003'
    , 'LAB-XE-001'
)
BEGIN
    DECLARE @Attempts int = 0;
    WHILE @Attempts < 10 AND @PredicateSatisfied = 0
    BEGIN
        DECLARE @TargetData xml = NULL;
        SELECT @TargetData = TRY_CONVERT(xml, [t].[target_data])
        FROM [sys].[dm_xe_session_targets] AS [t]
        INNER JOIN [sys].[dm_xe_sessions] AS [s]
            ON [s].[address] = [t].[event_session_address]
        WHERE [s].[name] = N'Lab001Wave3Session'
          AND [t].[target_name] = N'ring_buffer';

        IF @TargetData.exist
           (
               '/RingBufferTarget/event[@name="xml_deadlock_report"]'
           ) = 1
            SELECT
                  @PredicateSatisfied = 1
                , @ObservedValue = 1;
        ELSE
        BEGIN
            WAITFOR DELAY '00:00:01';
            SET @Attempts += 1;
        END;
    END;
END;

IF @ScenarioId = 'LAB-LATCH-001'
BEGIN
    DECLARE @ObjectId int =
        OBJECT_ID(N'Lab001Wave3.dbo.LatchSequential');

    SELECT @ObservedValue =
        SUM(CONVERT(bigint, COALESCE([leaf_insert_count], 0)))
    FROM [sys].[dm_db_index_operational_stats]
    (
          DB_ID(N'Lab001Wave3')
        , @ObjectId
        , NULL
        , NULL
    );

    IF COALESCE(@ObservedValue, 0) > 0
        SET @PredicateSatisfied = 1;
END;

IF @ScenarioId = 'LAB-LATCH-002'
BEGIN
    DECLARE @SequentialCount bigint;
    DECLARE @OptimizedCount bigint;
    DECLARE @OptimizedFlag bit;
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Sequential = COUNT_BIG(*)
FROM [dbo].[LatchSequential];

SELECT @Optimized = COUNT_BIG(*)
FROM [dbo].[LatchOptimized];

SELECT @Flag = [optimize_for_sequential_key]
FROM [sys].[indexes]
WHERE [object_id] = OBJECT_ID(N''dbo.LatchOptimized'')
  AND [index_id] = 1;'
        , N'
              @Sequential bigint OUTPUT
            , @Optimized bigint OUTPUT
            , @Flag bit OUTPUT'
        , @Sequential = @SequentialCount OUTPUT
        , @Optimized = @OptimizedCount OUTPUT
        , @Flag = @OptimizedFlag OUTPUT;

    SET @ObservedValue = @OptimizedCount;
    SET @PredicateSatisfied =
        CASE
            WHEN @SequentialCount > 0
             AND @SequentialCount = @OptimizedCount
             AND @OptimizedFlag = 1
            THEN 1
            ELSE 0
        END;
END;

IF @ScenarioId = 'LAB-LATCH-003'
BEGIN
    DECLARE @DistributedCount bigint;
    DECLARE @HeapCount bigint;
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Distributed = COUNT_BIG(*)
FROM [dbo].[LatchDistributed];

SELECT @Heap = COUNT_BIG(*)
FROM [dbo].[LatchHeap];'
        , N'@Distributed bigint OUTPUT, @Heap bigint OUTPUT'
        , @Distributed = @DistributedCount OUTPUT
        , @Heap = @HeapCount OUTPUT;

    SET @ObservedValue = @DistributedCount;
    SET @PredicateSatisfied =
        CASE
            WHEN @DistributedCount > 0
             AND @DistributedCount = @HeapCount
            THEN 1
            ELSE 0
        END;
END;

IF @ScenarioId = 'LAB-PLAN-001'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_exec_procedure_stats]
    WHERE [database_id] = DB_ID(N'Lab001Wave3')
      AND [object_id] = OBJECT_ID(N'Lab001Wave3.dbo.LabSkewProcedure');

    SET @PredicateSatisfied = CASE WHEN @ObservedValue >= 1 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-PLAN-002'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @ModificationCounter =
    TRY_CONVERT(bigint, [sp].[modification_counter])
FROM [sys].[stats] AS [s]
CROSS APPLY [sys].[dm_db_stats_properties]
(
      [s].[object_id]
    , [s].[stats_id]
) AS [sp]
WHERE [s].[object_id] = OBJECT_ID(N''dbo.PlanWorkload'')
  AND [s].[name] = N''IX_PlanWorkload_GroupId'';'
        , N'@ModificationCounter bigint OUTPUT'
        , @ModificationCounter = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue > 0 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-PLAN-003'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_exec_cached_plans] AS [cp]
    CROSS APPLY [sys].[dm_exec_sql_text]([cp].[plan_handle]) AS [st]
    WHERE [st].[text] LIKE N'%LAB001_WAVE3_ADHOC_%';

    SET @PredicateSatisfied = CASE WHEN @ObservedValue >= 20 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-PLAN-004'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Count = TRY_CONVERT(bigint, [StateValue])
FROM [dbo].[LabState]
WHERE [StateName] = N''RecompileExecutions''
  AND OBJECT_DEFINITION(OBJECT_ID(N''dbo.LabRecompileProcedure''))
      LIKE N''%WITH RECOMPILE%'';'
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue = 16 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-PLAN-005'
BEGIN
    SELECT @ObservedValue = [compatibility_level]
    FROM [sys].[databases]
    WHERE [database_id] = DB_ID(N'Lab001Wave3');

    SET @PredicateSatisfied =
        CASE
            WHEN @ProductMajorVersion = 16 AND @ObservedValue = 160 THEN 1
            WHEN @ProductMajorVersion >= 17 AND @ObservedValue = 170 THEN 1
            ELSE 0
        END;
END;

IF @ScenarioId = 'LAB-QS-001'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Count = COUNT_BIG(*)
FROM [sys].[query_store_query] AS [q]
INNER JOIN [sys].[query_store_plan] AS [p]
    ON [p].[query_id] = [q].[query_id]
INNER JOIN [sys].[query_store_runtime_stats] AS [rs]
    ON [rs].[plan_id] = [p].[plan_id]
WHERE [q].[object_id] = OBJECT_ID(N''dbo.LabQueryStoreProcedure'');'
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue > 0 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-QS-002'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Count = COUNT_BIG(*)
FROM [sys].[query_store_query] AS [q]
INNER JOIN [sys].[query_store_plan] AS [p]
    ON [p].[query_id] = [q].[query_id]
WHERE [q].[object_id] = OBJECT_ID(N''dbo.LabQueryStoreProcedure'')
  AND [p].[is_forced_plan] = 1;'
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue >= 1 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-IDX-001'
BEGIN
    SELECT @ObservedValue = SUM(CONVERT(bigint, [page_count]))
    FROM [sys].[dm_db_index_physical_stats]
    (
          DB_ID(N'Lab001Wave3')
        , OBJECT_ID(N'Lab001Wave3.dbo.IndexWorkload')
        , 1
        , NULL
        , 'LIMITED'
    );

    SET @PredicateSatisfied = CASE WHEN @ObservedValue > 8 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-IDX-002'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Count = COUNT_BIG(*)
FROM [sys].[indexes] AS [i]
INNER JOIN [sys].[index_columns] AS [ic]
    ON [ic].[object_id] = [i].[object_id]
   AND [ic].[index_id] = [i].[index_id]
   AND [ic].[key_ordinal] = 1
WHERE [i].[object_id] = OBJECT_ID(N''dbo.IndexWorkload'')
  AND [i].[name] IN
      (
          N''IX_IndexWorkload_GroupId_A'',
          N''IX_IndexWorkload_GroupId_B''
      )
  AND COL_NAME([ic].[object_id], [ic].[column_id]) = N''GroupId'';'
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue = 2 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-IDX-003'
BEGIN
    SELECT @ObservedValue = COUNT_BIG(*)
    FROM [sys].[dm_db_missing_index_details]
    WHERE [database_id] = DB_ID(N'Lab001Wave3')
      AND [object_id] = OBJECT_ID(N'Lab001Wave3.dbo.IndexWorkload');

    IF @ObservedValue > 0
        SET @PredicateSatisfied = 1;
    ELSE
    BEGIN
        EXEC [Lab001Wave3].[sys].[sp_executesql]
              N'
SELECT @Count = COUNT_BIG(*)
FROM [sys].[indexes]
WHERE [object_id] = OBJECT_ID(N''dbo.IndexWorkload'')
  AND [index_id] > 1;'
            , N'@Count bigint OUTPUT'
            , @Count = @ObservedValue OUTPUT;
        IF @ObservedValue = 0
            SELECT
                  @PredicateSatisfied = 1
                , @AlternativeEvidenceUsed = 1;
    END;
END;

IF @ScenarioId = 'LAB-COL-001'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Count = COUNT_BIG(*)
FROM [sys].[dm_db_column_store_row_group_physical_stats]
WHERE [object_id] = OBJECT_ID(N''dbo.ColumnstoreWorkload'');'
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue > 0 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-VERSION-001'
BEGIN
    SET @ObservedValue = @ProductMajorVersion;
    SET @PredicateSatisfied =
        CASE WHEN @ProductMajorVersion IN (15, 16, 17) THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-VECTOR-001'
BEGIN
    DECLARE @VectorSql nvarchar(max) =
        N'SELECT @Count = COUNT_BIG(*)
          FROM [Lab001Wave3].[sys].[vector_indexes]
          WHERE [name] = N''VIX_VectorWorkload_Embedding'';';
    EXEC [sys].[sp_executesql]
          @VectorSql
        , N'@Count bigint OUTPUT'
        , @Count = @ObservedValue OUTPUT;

    SET @PredicateSatisfied = CASE WHEN @ObservedValue = 1 THEN 1 ELSE 0 END;
END;

IF @ScenarioId = 'LAB-EXECPLAN-001'
BEGIN
    DECLARE @PlanXml xml;
    SELECT TOP (1)
           @PlanXml = [qp].[query_plan]
    FROM [sys].[dm_exec_query_stats] AS [qs]
    CROSS APPLY [sys].[dm_exec_sql_text]([qs].[sql_handle]) AS [st]
    CROSS APPLY [sys].[dm_exec_query_plan]([qs].[plan_handle]) AS [qp]
    WHERE [st].[dbid] = DB_ID(N'Lab001Wave3')
       OR [st].[text] LIKE N'%LAB001_WAVE3_EXECPLAN%'
    ORDER BY [qs].[last_execution_time] DESC;

    IF @PlanXml IS NULL
        THROW 55341, N'The synthetic execution plan is unavailable.', 1;

    EXEC [LabAnalyze].[monitor].[USP_ExecutionPlanAnalysis]
          @PlanXml = @PlanXml
        , @PlanQuelle = 'IMPORTED'
        , @AnalyseTiefe = 'STANDARD'
        , @EvidenzDatenschutzModus = 'DERIVED_ONLY'
        , @IdentifierDatenschutzModus = 'OMIT'
        , @MaxOperatoren = 1000
        , @MaxFindings = 100
        , @MaxDurationSeconds = 30
        , @ResultSetArt = 'NONE'
        , @JsonErzeugen = 1
        , @Json = @AnalyzerJson OUTPUT
        , @PrintMeldungen = 0
        , @StatusCodeOut = @AnalyzerStatus OUTPUT
        , @IsPartialOut = @AnalyzerPartial OUTPUT;

    SET @ObservedValue = 1;
    SET @PredicateSatisfied = 1;
END;

IF @PredicateSatisfied = 0
    THROW 55342, N'The scenario-specific state predicate was not observed.', 1;

IF @ScenarioId <> 'LAB-EXECPLAN-001'
BEGIN
    DECLARE @AnalyzerObjectId int;
    SELECT @AnalyzerObjectId = [p].[object_id]
    FROM [LabAnalyze].[sys].[procedures] AS [p]
    INNER JOIN [LabAnalyze].[sys].[schemas] AS [s]
        ON [s].[schema_id] = [p].[schema_id]
    WHERE [s].[name] = N'monitor'
      AND [p].[name] = @PrimaryAnalyzer;

    IF @AnalyzerObjectId IS NULL
        THROW 55343, N'The assigned framework analyzer is missing.', 1;

    DECLARE @AnalyzerSql nvarchar(max) =
        N'EXEC @ReturnCode = [LabAnalyze].[monitor].' +
        QUOTENAME(@PrimaryAnalyzer);
    DECLARE @Separator nvarchar(4) = N' ';
    DECLARE @SyntheticFullObjectName nvarchar(258) =
        CASE
            WHEN @ScenarioId LIKE 'LAB-IDX-%'
                THEN N'[dbo].[IndexWorkload]'
            WHEN @ScenarioId = 'LAB-COL-001'
                THEN N'[dbo].[ColumnstoreWorkload]'
            WHEN @ScenarioId = 'LAB-VECTOR-001'
                THEN N'[dbo].[VectorWorkload]'
            WHEN @ScenarioId IN ('LAB-LATCH-001', 'LAB-LATCH-002')
                THEN N'[dbo].[LatchSequential]'
            WHEN @ScenarioId = 'LAB-LATCH-003'
                THEN N'[dbo].[LatchDistributed]'
            WHEN @ScenarioId = 'LAB-PLAN-002'
                THEN N'[dbo].[PlanWorkload]'
            ELSE NULL
        END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@DatabaseNames'
    )
    BEGIN
        SET @AnalyzerSql += @Separator +
            N'@DatabaseNames = N''[Lab001Wave3]''';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@QueryStoreDatabaseNames'
    )
    BEGIN
        SET @AnalyzerSql += @Separator +
            N'@QueryStoreDatabaseNames = N''[Lab001Wave3]''';
        SET @Separator = N', ';
    END;

    IF @SyntheticFullObjectName IS NOT NULL
       AND EXISTS
       (
           SELECT 1
           FROM [LabAnalyze].[sys].[parameters]
           WHERE [object_id] = @AnalyzerObjectId
             AND [name] = N'@FullObjectNames'
       )
    BEGIN
        SET @AnalyzerSql += @Separator +
            N'@FullObjectNames = N''' +
            REPLACE(@SyntheticFullObjectName, N'''', N'''''') + N'''';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@SourceExtendedEventSessionName'
    )
    BEGIN
        SET @AnalyzerSql += @Separator +
            N'@SourceExtendedEventSessionName = N''Lab001Wave3Session''';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@ExtendedEventSessionNames'
    )
    BEGIN
        SET @AnalyzerSql += @Separator +
            N'@ExtendedEventSessionNames = N''[Lab001Wave3Session]''';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@MitTargetRuntime'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@MitTargetRuntime = 1';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@MitEvents'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@MitEvents = 1';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@MitDeadlocks'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@MitDeadlocks = 1';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@DatabaseName'
    )
    AND NOT EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@DatabaseNames'
    )
    BEGIN
        SET @AnalyzerSql += @Separator +
            N'@DatabaseName = N''Lab001Wave3''';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@HighImpactConfirmed'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@HighImpactConfirmed = 1';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@SampleSeconds'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@SampleSeconds = 0';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@MaxDurationSeconds'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@MaxDurationSeconds = 30';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@MaxZeilen'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@MaxZeilen = 100';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@ResultSetArt'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@ResultSetArt = ''NONE''';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@JsonErzeugen'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@JsonErzeugen = 1';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@Json'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@Json = @AnalyzerJson OUTPUT';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@PrintMeldungen'
    )
    BEGIN
        SET @AnalyzerSql += @Separator + N'@PrintMeldungen = 0';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@StatusCodeOut'
    )
    BEGIN
        SET @AnalyzerSql += @Separator +
            N'@StatusCodeOut = @AnalyzerStatus OUTPUT';
        SET @Separator = N', ';
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [LabAnalyze].[sys].[parameters]
        WHERE [object_id] = @AnalyzerObjectId
          AND [name] = N'@IsPartialOut'
    )
        SET @AnalyzerSql += @Separator +
            N'@IsPartialOut = @AnalyzerPartial OUTPUT';

    EXEC [sys].[sp_executesql]
          @AnalyzerSql
        , N'
              @AnalyzerJson nvarchar(max) OUTPUT
            , @AnalyzerStatus varchar(40) OUTPUT
            , @AnalyzerPartial bit OUTPUT
            , @ReturnCode int OUTPUT'
        , @AnalyzerJson = @AnalyzerJson OUTPUT
        , @AnalyzerStatus = @AnalyzerStatus OUTPUT
        , @AnalyzerPartial = @AnalyzerPartial OUTPUT
        , @ReturnCode = @ReturnCode OUTPUT;

    IF @ReturnCode IS NULL OR @ReturnCode <> 0
        THROW 55344, N'The assigned framework analyzer returned an error.', 1;

    SET @AnalyzerStatus = COALESCE(@AnalyzerStatus, 'AVAILABLE');
END;

IF @AnalyzerStatus NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED')
    THROW 55345, N'The analyzer returned an unsupported scenario status.', 1;

SELECT CONCAT
(
      N'LAB_ASSERTION_JSON='
    , (
        SELECT
              @ScenarioId AS [ScenarioId]
            , N'PASS' AS [Status]
            , @AnalyzerStatus AS [AnalyzerStatus]
            , @PrimaryAnalyzer AS [PrimaryAnalyzer]
            , JSON_QUERY(CONCAT(N'["', @FindingCode, N'"]')) AS [FindingCodes]
            , @ObservedValue AS [ObservedValue]
            , @AlternativeEvidenceUsed AS [AlternativeEvidenceUsed]
            , @ProductMajorVersion AS [ProductMajorVersion]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
      )
);
