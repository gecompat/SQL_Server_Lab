USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_QueryStoreRuntimeStats
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Liefert Query-Store-Runtime-Statistiken aus einer oder mehreren
               Query-Store-Quelldatenbanken mit exaktem globalem Top-N.
SQL-Version  : SQL Server 2019 oder neuer.
Quelldatenbanken: @QueryStoreDatabaseNames bracket-aware Pipe-Liste;
               NULL/N'' = alle zulässigen Datenbanken.
Referenzfilter: @ReferencedDatabaseNames beziehungsweise
               @ReferencedDatabaseNamePattern filtern auf Datenbanken, die in
               gespeicherten Showplans referenziert werden.
Pattern      : LIKE (Default/like:), regex:, regexi:. Regex benötigt SQL Server
               2025 und Compatibility Level 170 der jeweils ausgewerteten DB.
Top-N        : Je Quelldatenbank werden höchstens N+1 lokale Kandidaten gelesen;
               anschließend wird daraus das exakte globale Top N gebildet.
Ausgabe      : RAW, CONSOLE, TABLE oder NONE; optionales JSON mit meta, runtimeStats
               und warnings.
Änderungen   : 2.0.0 - Quell-/Referenzdatenbanken getrennt, @AlleDatenbanken
                         entfernt, globale Top-N-Logik, Pattern und JSON.
               1.0.0 - Erstfassung Phase 4.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_QueryStoreRuntimeStats]
      @QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @QueryId                          bigint         = NULL
    , @QueryHash                        binary(8)      = NULL
    , @TextPattern                      nvarchar(4000) = NULL
    , @VonUtc                           datetime2(7)   = NULL
    , @BisUtc                           datetime2(7)   = NULL
    , @Sortierung                       varchar(32)    = 'CPU_TOTAL'
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MitPlanXml                       bit            = 0
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @EffectiveMaxZeilen bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen)
             ELSE CONVERT(bigint, 0) END;
    DECLARE @LocalCandidateRows bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             WHEN @MaxZeilen > 0 AND @MaxZeilen < 2147483647
             THEN CONVERT(bigint, @MaxZeilen) + 1
             WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen)
             ELSE CONVERT(bigint, 0) END;
    DECLARE @ResultSetArtNormalisiert varchar(16) =
        UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'runtimeStats',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    SET @Sortierung = UPPER(LTRIM(RTRIM(COALESCE(@Sortierung, 'CPU_TOTAL'))));
    SET @AnalyseModus = UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus, 'TOP'))));

    DECLARE @TextPatternMode varchar(8);
    DECLARE @TextPatternValue nvarchar(4000);
    DECLARE @TextRegexFlags varchar(8);
    DECLARE @TextPatternIsValid bit;
    DECLARE @ReferencedPatternMode varchar(8);
    DECLARE @ReferencedPatternValue nvarchar(4000);
    DECLARE @ReferencedRegexFlags varchar(8);
    DECLARE @ReferencedPatternIsValid bit;

    SELECT
          @TextPatternMode = [PatternMode]
        , @TextPatternValue = [PatternValue]
        , @TextRegexFlags = [RegexFlags]
        , @TextPatternIsValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@TextPattern);

    SELECT
          @ReferencedPatternMode = [PatternMode]
        , @ReferencedPatternValue = [PatternValue]
        , @ReferencedRegexFlags = [RegexFlags]
        , @ReferencedPatternIsValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@ReferencedDatabaseNamePattern);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_QueryStoreRuntimeStats';
        PRINT N'@QueryStoreDatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle; N'''' = keine Einschränkung.';
        PRINT N'@QueryStoreDatabaseNamePattern: alternatives LIKE-/Regex-Pattern für Quelldatenbanken.';
        PRINT N'@ReferencedDatabaseNames/@ReferencedDatabaseNamePattern: Filter auf in Showplans referenzierte Datenbanken; Deep-Analyse.';
        PRINT N'@TextPattern akzeptiert LIKE (Default/like:), regex: oder regexi:.';
        PRINT N'@Sortierung: CPU_TOTAL, DURATION_TOTAL, READS_TOTAL, WRITES_TOTAL, EXECUTIONS, MEMORY_MAX, TEMPDB_TOTAL, LOG_BYTES_TOTAL, LAST_EXECUTION.';
        PRINT N'@MaxZeilen ist global über alle Quelldatenbanken; NULL/0 = unbegrenzt.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE case-insensitiv; @JsonErzeugen=1 setzt @Json OUTPUT.';
        RETURN;
    END;

    IF @BisUtc IS NULL SET @BisUtc = SYSUTCDATETIME();
    IF @VonUtc IS NULL SET @VonUtc = DATEADD(HOUR, -1, @BisUtc);

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Allowed bit = 1;
    DECLARE @Db sysname;
    DECLARE @DbCompatibilityLevel tinyint;
    DECLARE @Sql nvarchar(max);
    DECLARE @Order sysname;
    DECLARE @CandidateRowCount bigint = 0;
    DECLARE @RowCount bigint = 0;
    DECLARE @HasMoreRows bit = 0;
    DECLARE @Deep bit = 0;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @MonitorPrintMessage nvarchar(2048);
    DECLARE @TextPredicate nvarchar(max) = N'';
    DECLARE @ReferencedPredicate nvarchar(max) = N'';

    CREATE TABLE [#QueryStoreRuntimeStats_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );

    CREATE TABLE [#QueryStoreRuntimeStats_Result]
    (
          [QueryStoreDatabaseId] int NULL
        , [QueryStoreDatabaseName] sysname NOT NULL
        , [QueryId] bigint NOT NULL
        , [PlanId] bigint NOT NULL
        , [QueryHash] binary(8) NULL
        , [QueryPlanHash] binary(8) NULL
        , [ObjectId] bigint NULL
        , [ObjectName] nvarchar(517) NULL
        , [ExecutionTypeDesc] nvarchar(60) NULL
        , [FirstExecutionTimeUtc] datetimeoffset NULL
        , [LastExecutionTimeUtc] datetimeoffset NULL
        , [ExecutionCount] bigint NULL
        , [TotalDurationMs] decimal(38,3) NULL
        , [AverageDurationMs] decimal(38,3) NULL
        , [TotalCpuMs] decimal(38,3) NULL
        , [AverageCpuMs] decimal(38,3) NULL
        , [TotalLogicalReads] decimal(38,3) NULL
        , [AverageLogicalReads] decimal(38,3) NULL
        , [TotalLogicalWrites] decimal(38,3) NULL
        , [AverageLogicalWrites] decimal(38,3) NULL
        , [TotalPhysicalReads] decimal(38,3) NULL
        , [TotalMemoryGrantKb] decimal(38,3) NULL
        , [MaxMemoryGrantKb] decimal(38,3) NULL
        , [TotalRowCount] decimal(38,3) NULL
        , [TotalLogBytes] decimal(38,3) NULL
        , [TotalTempdbKb] decimal(38,3) NULL
        , [SourceType] varchar(32) NULL
        , [SourceObject] nvarchar(256) NULL
        , [CapturedAtUtc] datetime2(3) NULL
        , [EvidenceScope] varchar(40) NULL
        , [QuerySqlTextCharacters] bigint NULL
        , [QuerySqlTextBytes] bigint NULL
        , [QuerySqlTextIsTruncated] bit NULL
        , [QuerySqlText] nvarchar(max) NULL
        , [QueryPlanStatus] varchar(40) NULL
        , [QueryPlanCharacters] bigint NULL
        , [QueryPlanBytes] bigint NULL
        , [QueryPlan] xml NULL
        , [QueryPlanTextFallback] nvarchar(max) NULL
        , [EvidenceLimit] nvarchar(1000) NULL
    );

    CREATE TABLE [#QueryStoreRuntimeStats_Errors]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    SET @Order = CASE @Sortierung
        WHEN 'CPU_TOTAL' THEN N'TotalCpuMs'
        WHEN 'DURATION_TOTAL' THEN N'TotalDurationMs'
        WHEN 'READS_TOTAL' THEN N'TotalLogicalReads'
        WHEN 'WRITES_TOTAL' THEN N'TotalLogicalWrites'
        WHEN 'EXECUTIONS' THEN N'ExecutionCount'
        WHEN 'MEMORY_MAX' THEN N'MaxMemoryGrantKb'
        WHEN 'TEMPDB_TOTAL' THEN N'TotalTempdbKb'
        WHEN 'LOG_BYTES_TOTAL' THEN N'TotalLogBytes'
        WHEN 'LAST_EXECUTION' THEN N'LastExecutionTimeUtc'
    END;

    IF @AnalyseModus NOT IN ('TOP', 'VOLL')
       OR @Order IS NULL
       OR @MaxZeilen < 0

       OR @MaxSqlTextZeichen < 0
       OR @VonUtc >= @BisUtc
       OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR @TextPatternIsValid = 0
       OR @ReferencedPatternIsValid = 0
       OR (@ReferencedDatabaseNames IS NOT NULL AND EXISTS
          (
              SELECT 1
              FROM [monitor].[TVF_ParseSqlNameList](@ReferencedDatabaseNames)
              WHERE [IsValid] = 0
          ))
       OR (@ReferencedDatabaseNames IS NOT NULL
           AND @ReferencedDatabaseNamePattern IS NOT NULL)
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültiger Parameter oder Zeitraum.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @QueryStoreDatabaseNames
            , @SystemdatenbankenEinbeziehen = 0
            , @DatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass='QUERY_STORE_CURRENT'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#QueryStoreRuntimeStats_DatabaseCandidates';
    END;

    SET @Deep = CONVERT
    (
        bit,
        CASE WHEN @AnalyseModus = 'VOLL'
               OR @MitPlanXml = 1
               OR @EffectiveMaxZeilen > 1000
               OR DATEDIFF(HOUR, @VonUtc, @BisUtc) > 24
               OR @ReferencedDatabaseNames IS NOT NULL
               OR @ReferencedDatabaseNamePattern IS NOT NULL
               OR @TextPatternMode IN ('REGEX', 'REGEXI')
             THEN 1 ELSE 0 END
    );

    IF @StatusCode = 'AVAILABLE' AND @Deep = 1
    BEGIN
        EXEC [monitor].[InternalCheckAnalysisPath]
              @AnalysisClass='QUERY_STORE_DEEP'
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT;
    END;

    IF @TextPatternMode = 'LIKE'
        SET @TextPredicate = N' AND [qt].[query_sql_text] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @TextPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS';
    ELSE IF @TextPatternMode IN ('REGEX', 'REGEXI')
        SET @TextPredicate = N' AND REGEXP_LIKE([qt].[query_sql_text], @TextPatternValue, @TextRegexFlags)';

    IF @ReferencedDatabaseNames IS NOT NULL
        SET @ReferencedPredicate = N'
 AND EXISTS
 (
     SELECT 1
     FROM (SELECT CONVERT(xml, [p].[query_plan]) AS [PlanXml]) AS [px]
     CROSS APPLY [px].[PlanXml].nodes(''declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //Object[@Database]'') AS [n]([ObjectNode])
     JOIN [monitor].[TVF_ParseSqlNameList](@ReferencedDatabaseNames) AS [rf]
       ON [rf].[IsValid] = 1
      AND [rf].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS
        = PARSENAME([n].[ObjectNode].value(''@Database'', ''nvarchar(776)''), 1) COLLATE SQL_Latin1_General_CP1_CS_AS
 )';
    ELSE IF @ReferencedPatternMode = 'LIKE'
        SET @ReferencedPredicate = N'
 AND EXISTS
 (
     SELECT 1
     FROM (SELECT CONVERT(xml, [p].[query_plan]) AS [PlanXml]) AS [px]
     CROSS APPLY [px].[PlanXml].nodes(''declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //Object[@Database]'') AS [n]([ObjectNode])
     WHERE PARSENAME([n].[ObjectNode].value(''@Database'', ''nvarchar(776)''), 1) COLLATE SQL_Latin1_General_CP1_CS_AS
           LIKE @ReferencedPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS
 )';
    ELSE IF @ReferencedPatternMode IN ('REGEX', 'REGEXI')
        SET @ReferencedPredicate = N'
 AND EXISTS
 (
     SELECT 1
     FROM (SELECT CONVERT(xml, [p].[query_plan]) AS [PlanXml]) AS [px]
     CROSS APPLY [px].[PlanXml].nodes(''declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //Object[@Database]'') AS [n]([ObjectNode])
     WHERE REGEXP_LIKE(PARSENAME([n].[ObjectNode].value(''@Database'', ''nvarchar(776)''), 1), @ReferencedPatternValue, @ReferencedRegexFlags)
 )';

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE [c] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName], [CompatibilityLevel]
            FROM [#QueryStoreRuntimeStats_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal], [DatabaseId]), [DatabaseId];

        OPEN [c];
        FETCH NEXT FROM [c] INTO @Db, @DbCompatibilityLevel;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF (@TextPatternMode IN ('REGEX', 'REGEXI')
                OR @ReferencedPatternMode IN ('REGEX', 'REGEXI'))
               AND
               (
                   TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) < 17
                   OR @DbCompatibilityLevel < 170
               )
            BEGIN
                INSERT [#QueryStoreRuntimeStats_Errors]
                VALUES
                (
                      @Db
                    , 'UNAVAILABLE_FEATURE'
                    , NULL
                    , N'Regex benötigt SQL Server 2025 und Compatibility Level 170 in der Query-Store-Quelldatenbank.'
                );
                SET @IsPartial = 1;
            END
            ELSE
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
IF EXISTS
(
    SELECT 1
    FROM [sys].[database_query_store_options] WITH (NOLOCK)
    WHERE [actual_state] IN (1, 2, 4)
)
BEGIN
    ;WITH [RI] AS
    (
        SELECT
              [rs].[plan_id]
            , [rs].[execution_type]
            , [rs].[execution_type_desc]
            , [rs].[runtime_stats_interval_id]
            , MIN([rs].[first_execution_time]) AS [first_execution_time]
            , MAX([rs].[last_execution_time]) AS [last_execution_time]
            , SUM([rs].[count_executions]) AS [count_executions]
            , SUM(CONVERT(float, [rs].[avg_duration]) * [rs].[count_executions]) AS [duration_weighted]
            , SUM(CONVERT(float, [rs].[avg_cpu_time]) * [rs].[count_executions]) AS [cpu_weighted]
            , SUM(CONVERT(float, [rs].[avg_logical_io_reads]) * [rs].[count_executions]) AS [reads_weighted]
            , SUM(CONVERT(float, [rs].[avg_logical_io_writes]) * [rs].[count_executions]) AS [writes_weighted]
            , SUM(CONVERT(float, [rs].[avg_physical_io_reads]) * [rs].[count_executions]) AS [physical_weighted]
            , SUM(CONVERT(float, [rs].[avg_query_max_used_memory]) * [rs].[count_executions]) AS [memory_weighted]
            , MAX(CONVERT(float, [rs].[max_query_max_used_memory])) AS [max_memory_pages]
            , SUM(CONVERT(float, [rs].[avg_rowcount]) * [rs].[count_executions]) AS [rows_weighted]
            , SUM(CONVERT(float, [rs].[avg_log_bytes_used]) * [rs].[count_executions]) AS [log_weighted]
            , SUM(CONVERT(float, [rs].[avg_tempdb_space_used]) * [rs].[count_executions]) AS [tempdb_weighted]
        FROM [sys].[query_store_runtime_stats] AS [rs] WITH (NOLOCK)
        JOIN [sys].[query_store_runtime_stats_interval] AS [rsi] WITH (NOLOCK)
          ON [rsi].[runtime_stats_interval_id] = [rs].[runtime_stats_interval_id]
        WHERE [rsi].[end_time] > @FromUtc
          AND [rsi].[start_time] < @ToUtc
        GROUP BY [rs].[plan_id], [rs].[execution_type],
                 [rs].[execution_type_desc], [rs].[runtime_stats_interval_id]
    ),
    [A] AS
    (
        SELECT
              [q].[query_id]
            , [p].[plan_id]
            , [q].[query_hash]
            , [p].[query_plan_hash]
            , [q].[object_id]
            , [RI].[execution_type_desc]
            , MIN([RI].[first_execution_time]) AS [first_execution_time]
            , MAX([RI].[last_execution_time]) AS [last_execution_time]
            , SUM([RI].[count_executions]) AS [executions]
            , SUM([RI].[duration_weighted]) AS [duration_weighted]
            , SUM([RI].[cpu_weighted]) AS [cpu_weighted]
            , SUM([RI].[reads_weighted]) AS [reads_weighted]
            , SUM([RI].[writes_weighted]) AS [writes_weighted]
            , SUM([RI].[physical_weighted]) AS [physical_weighted]
            , SUM([RI].[memory_weighted]) AS [memory_weighted]
            , MAX([RI].[max_memory_pages]) AS [max_memory_pages]
            , SUM([RI].[rows_weighted]) AS [rows_weighted]
            , SUM([RI].[log_weighted]) AS [log_weighted]
            , SUM([RI].[tempdb_weighted]) AS [tempdb_weighted]
            , [qt].[query_sql_text]
            , [p].[query_plan]
        FROM [RI]
        JOIN [sys].[query_store_plan] AS [p] WITH (NOLOCK)
          ON [p].[plan_id] = [RI].[plan_id]
        JOIN [sys].[query_store_query] AS [q] WITH (NOLOCK)
          ON [q].[query_id] = [p].[query_id]
        JOIN [sys].[query_store_query_text] AS [qt] WITH (NOLOCK)
          ON [qt].[query_text_id] = [q].[query_text_id]
        WHERE (@QueryId IS NULL OR [q].[query_id] = @QueryId)
          AND (@QueryHash IS NULL OR [q].[query_hash] = @QueryHash)' + @TextPredicate + @ReferencedPredicate + N'
        GROUP BY [q].[query_id], [p].[plan_id], [q].[query_hash],
                 [p].[query_plan_hash], [q].[object_id],
                 [RI].[execution_type_desc], [qt].[query_sql_text], [p].[query_plan]
    )
    INSERT [#QueryStoreRuntimeStats_Result]
    (
          [QueryStoreDatabaseId], [QueryStoreDatabaseName], [QueryId], [PlanId]
        , [QueryHash], [QueryPlanHash], [ObjectId], [ObjectName]
        , [ExecutionTypeDesc], [FirstExecutionTimeUtc], [LastExecutionTimeUtc]
        , [ExecutionCount], [TotalDurationMs], [AverageDurationMs]
        , [TotalCpuMs], [AverageCpuMs], [TotalLogicalReads]
        , [AverageLogicalReads], [TotalLogicalWrites], [AverageLogicalWrites]
        , [TotalPhysicalReads], [TotalMemoryGrantKb], [MaxMemoryGrantKb]
        , [TotalRowCount], [TotalLogBytes], [TotalTempdbKb]
        , [QuerySqlText], [QueryPlanTextFallback]
    )
    SELECT TOP (@TopRows)
          DB_ID()
        , (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID())
        , [query_id]
        , [plan_id]
        , [query_hash]
        , [query_plan_hash]
        , [object_id]
        , CASE WHEN [A].[object_id] > 0
               THEN QUOTENAME([os].[name]) + N''.'' + QUOTENAME([oo].[name]) END
        , [execution_type_desc]
        , [first_execution_time]
        , [last_execution_time]
        , [executions]
        , CONVERT(decimal(38,3), [duration_weighted] / 1000.0)
        , CONVERT(decimal(38,3), [duration_weighted] / NULLIF([executions], 0) / 1000.0)
        , CONVERT(decimal(38,3), [cpu_weighted] / 1000.0)
        , CONVERT(decimal(38,3), [cpu_weighted] / NULLIF([executions], 0) / 1000.0)
        , CONVERT(decimal(38,3), [reads_weighted])
        , CONVERT(decimal(38,3), [reads_weighted] / NULLIF([executions], 0))
        , CONVERT(decimal(38,3), [writes_weighted])
        , CONVERT(decimal(38,3), [writes_weighted] / NULLIF([executions], 0))
        , CONVERT(decimal(38,3), [physical_weighted])
        , CONVERT(decimal(38,3), [memory_weighted] * 8.0)
        , CONVERT(decimal(38,3), [max_memory_pages] * 8.0)
        , CONVERT(decimal(38,3), [rows_weighted])
        , CONVERT(decimal(38,3), [log_weighted])
        , CONVERT(decimal(38,3), [tempdb_weighted] * 8.0)
        , [query_sql_text]
        , CASE WHEN @IncludePlan = 1 THEN [query_plan] END
    FROM [A]
    LEFT JOIN [sys].[objects] AS [oo] WITH (NOLOCK)
      ON [oo].[object_id] = [A].[object_id]
    LEFT JOIN [sys].[schemas] AS [os] WITH (NOLOCK)
      ON [os].[schema_id] = [oo].[schema_id]
    ORDER BY ' + QUOTENAME(@Order) + N' DESC, [last_execution_time] DESC;
END;';

                EXEC [sys].[sp_executesql]
                      @Sql
                    , N'@FromUtc datetime2(7), @ToUtc datetime2(7), @QueryId bigint,
                        @QueryHash binary(8), @TopRows bigint, @TextChars int,
                        @IncludePlan bit, @TextPatternValue nvarchar(4000),
                        @TextRegexFlags varchar(8), @ReferencedDatabaseNames nvarchar(max),
                        @ReferencedPatternValue nvarchar(4000), @ReferencedRegexFlags varchar(8)'
                    , @FromUtc = @VonUtc
                    , @ToUtc = @BisUtc
                    , @QueryId = @QueryId
                    , @QueryHash = @QueryHash
                    , @TopRows = @LocalCandidateRows
                    , @TextChars = @MaxSqlTextZeichen
                    , @IncludePlan = @MitPlanXml
                    , @TextPatternValue = @TextPatternValue
                    , @TextRegexFlags = @TextRegexFlags
                    , @ReferencedDatabaseNames = @ReferencedDatabaseNames
                    , @ReferencedPatternValue = @ReferencedPatternValue
                    , @ReferencedRegexFlags = @ReferencedRegexFlags;
            END TRY
            BEGIN CATCH
                INSERT [#QueryStoreRuntimeStats_Errors]
                VALUES
                (
                      @Db
                    , CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                           WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                           ELSE 'ERROR_HANDLED' END
                    , ERROR_NUMBER()
                    , ERROR_MESSAGE()
                );
                SET @IsPartial = 1;

                IF @PrintMeldungen = 1
                BEGIN
                    SET @MonitorPrintMessage = FORMATMESSAGE
                    (
                        N'WARNUNG USP_QueryStoreRuntimeStats [%s]: %s',
                        @Db,
                        ERROR_MESSAGE()
                    );
                    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
                END;
            END CATCH;

            FETCH NEXT FROM [c] INTO @Db, @DbCompatibilityLevel;
        END;

        CLOSE [c];
        DEALLOCATE [c];

        UPDATE [r]
        SET [SourceType]='QUERY_STORE',
            [SourceObject]=N'sys.query_store_runtime_stats|sys.query_store_plan|sys.query_store_query_text',
            [CapturedAtUtc]=@CollectionTimeUtc,
            [EvidenceScope]='DATABASE_QUERY_PLAN_INTERVAL',
            [QuerySqlTextCharacters]=[projection].[OriginalCharacters],
            [QuerySqlTextBytes]=[projection].[OriginalBytes],
            [QuerySqlTextIsTruncated]=[projection].[IsTruncated],
            [QuerySqlText]=[projection].[ProjectedValue],
            [QueryPlanStatus]=CASE WHEN @MitPlanXml=0 THEN 'NOT_REQUESTED' ELSE 'PENDING' END,
            [EvidenceLimit]=N'Query Store liefert aggregierte Intervallwerte und den gespeicherten Plan; keine aktuelle Einzelausführung und keine vollständigen Runtimeparameter.'
        FROM [#QueryStoreRuntimeStats_Result] AS [r]
        CROSS APPLY [monitor].[TVF_ProjectUnicodeText]([r].[QuerySqlText],@MaxSqlTextZeichen) AS [projection];

        DECLARE @PlanDatabaseId int,@PlanQueryId bigint,@PlanId bigint,@PlanText nvarchar(max);
        DECLARE @PlanXml xml,@PlanStatus varchar(40),@PlanErrorNumber int,@PlanErrorMessage nvarchar(2048);
        DECLARE [PlanCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [QueryStoreDatabaseId],[QueryId],[PlanId],[QueryPlanTextFallback]
            FROM [#QueryStoreRuntimeStats_Result]
            WHERE @MitPlanXml=1
            ORDER BY [QueryStoreDatabaseId],[QueryId],[PlanId];
        OPEN [PlanCursor];
        FETCH NEXT FROM [PlanCursor] INTO @PlanDatabaseId,@PlanQueryId,@PlanId,@PlanText;
        WHILE @@FETCH_STATUS=0
        BEGIN
            EXEC [monitor].[InternalParseXmlText]
                  @XmlText=@PlanText,@XmlValue=@PlanXml OUTPUT,@StatusCode=@PlanStatus OUTPUT,
                  @ErrorNumber=@PlanErrorNumber OUTPUT,@ErrorMessage=@PlanErrorMessage OUTPUT;
            UPDATE [#QueryStoreRuntimeStats_Result]
            SET [QueryPlanStatus]=@PlanStatus,
                [QueryPlanCharacters]=CASE WHEN @PlanText IS NULL THEN NULL ELSE CONVERT(bigint,LEN((@PlanText+NCHAR(1)) COLLATE Latin1_General_100_CI_AS_SC)-1) END,
                [QueryPlanBytes]=CONVERT(bigint,DATALENGTH(@PlanText)),
                [QueryPlan]=@PlanXml,
                [QueryPlanTextFallback]=CASE WHEN @PlanStatus IN('AVAILABLE','XML_EMPTY','SOURCE_NULL') THEN NULL ELSE @PlanText END
            WHERE [QueryStoreDatabaseId]=@PlanDatabaseId AND [QueryId]=@PlanQueryId AND [PlanId]=@PlanId;
            IF @PlanStatus IN('XML_INVALID','XML_UNAVAILABLE_LIMIT')
            BEGIN
                INSERT [#QueryStoreRuntimeStats_Errors]
                VALUES((SELECT TOP(1) [QueryStoreDatabaseName] FROM [#QueryStoreRuntimeStats_Result] WHERE [QueryStoreDatabaseId]=@PlanDatabaseId),@PlanStatus,@PlanErrorNumber,@PlanErrorMessage);
                SET @IsPartial=1;
            END;
            FETCH NEXT FROM [PlanCursor] INTO @PlanDatabaseId,@PlanQueryId,@PlanId,@PlanText;
        END;
        CLOSE [PlanCursor];
        DEALLOCATE [PlanCursor];

        DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
        SELECT @TruncatedValueCount=COUNT_BIG(*),@LargestRequiredCharacters=MAX([QuerySqlTextCharacters])
        FROM [#QueryStoreRuntimeStats_Result]
        WHERE [QuerySqlTextIsTruncated]=1;
        EXEC [monitor].[InternalEmitTruncationWarning]
              @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen',
              @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters,
              @PrintMeldungen=@PrintMeldungen;

        SELECT @CandidateRowCount = COUNT_BIG(*) FROM [#QueryStoreRuntimeStats_Result];
        SET @HasMoreRows = CONVERT(bit, CASE WHEN @CandidateRowCount > @EffectiveMaxZeilen THEN 1 ELSE 0 END);
        SET @RowCount = CASE WHEN @CandidateRowCount > @EffectiveMaxZeilen
                             THEN @EffectiveMaxZeilen ELSE @CandidateRowCount END;

        IF @RowCount = 0 AND EXISTS (SELECT 1 FROM [#QueryStoreRuntimeStats_Errors])
        BEGIN
            SET @StatusCode = 'AVAILABLE_LIMITED';
            SELECT TOP (1)
                  @ErrorNumber = [ErrorNumber]
                , @ErrorMessage = [ErrorMessage]
            FROM [#QueryStoreRuntimeStats_Errors]
            ORDER BY [DatabaseName];
        END
        ELSE IF @IsPartial = 1
            SET @StatusCode = 'AVAILABLE_LIMITED';
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  N'QueryStoreRuntimeStats' AS [resultName]
                , 1 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @IsPartial AS [isPartial]
                , @MaxZeilen AS [requestedMaxRows]
                , @RowCount AS [returnedRows]
                , @HasMoreRows AS [resultLimited]
                , @HasMoreRows AS [hasMoreRows]
                , @VonUtc AS [fromUtc]
                , @BisUtc AS [toUtc]
                , @Sortierung AS [sort]
                , @ErrorNumber AS [errorNumber]
                , @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @DataJson nvarchar(max) =
        (
            SELECT *
            FROM
            (
                SELECT TOP (@EffectiveMaxZeilen)
                      [r].[QueryStoreDatabaseId],[r].[QueryStoreDatabaseName],[r].[QueryId],[r].[PlanId]
                    , [r].[QueryHash],[r].[QueryPlanHash],[r].[ObjectId],[r].[ObjectName]
                    , [r].[ExecutionTypeDesc],[r].[FirstExecutionTimeUtc],[r].[LastExecutionTimeUtc]
                    , [r].[ExecutionCount],[r].[TotalDurationMs],[r].[AverageDurationMs]
                    , [r].[TotalCpuMs],[r].[AverageCpuMs],[r].[TotalLogicalReads],[r].[AverageLogicalReads]
                    , [r].[TotalLogicalWrites],[r].[AverageLogicalWrites],[r].[TotalPhysicalReads]
                    , [r].[TotalMemoryGrantKb],[r].[MaxMemoryGrantKb],[r].[TotalRowCount]
                    , [r].[TotalLogBytes],[r].[TotalTempdbKb],[r].[SourceType],[r].[SourceObject]
                    , [r].[CapturedAtUtc],[r].[EvidenceScope],[r].[QuerySqlTextCharacters]
                    , [r].[QuerySqlTextBytes],[r].[QuerySqlTextIsTruncated],[r].[QuerySqlText]
                    , [r].[QueryPlanStatus],[r].[QueryPlanCharacters],[r].[QueryPlanBytes]
                    , CONVERT(nvarchar(max),[r].[QueryPlan]) AS [QueryPlan]
                    , [r].[QueryPlanTextFallback],[r].[EvidenceLimit]
                FROM [#QueryStoreRuntimeStats_Result] AS [r]
                ORDER BY
                      CASE WHEN @Sortierung = 'LAST_EXECUTION' THEN [LastExecutionTimeUtc] END DESC
                    , CASE WHEN @Sortierung = 'CPU_TOTAL' THEN [TotalCpuMs]
                           WHEN @Sortierung = 'DURATION_TOTAL' THEN [TotalDurationMs]
                           WHEN @Sortierung = 'READS_TOTAL' THEN [TotalLogicalReads]
                           WHEN @Sortierung = 'WRITES_TOTAL' THEN [TotalLogicalWrites]
                           WHEN @Sortierung = 'EXECUTIONS' THEN [ExecutionCount]
                           WHEN @Sortierung = 'MEMORY_MAX' THEN [MaxMemoryGrantKb]
                           WHEN @Sortierung = 'TEMPDB_TOTAL' THEN [TotalTempdbKb]
                           WHEN @Sortierung = 'LOG_BYTES_TOTAL' THEN [TotalLogBytes] END DESC
                    , [LastExecutionTimeUtc] DESC
                    , [QueryStoreDatabaseName]
                    , [QueryId]
                    , [PlanId]
            ) AS [x]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT [DatabaseName] AS [databaseName], [StatusCode] AS [code],
                    [ErrorNumber] AS [errorNumber], [ErrorMessage] AS [message]
             FROM [#QueryStoreRuntimeStats_Errors] ORDER BY [DatabaseName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"runtimeStats":', COALESCE(@DataJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;

    IF @ResultSetArtNormalisiert = 'RAW'
    BEGIN
        SELECT
              N'USP_QueryStoreRuntimeStats' AS [ModuleName]
            , @CollectionTimeUtc AS [CollectionTimeUtc]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , @RowCount AS [RowCount]
            , @HasMoreRows AS [ResultLimited]
            , CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
                   THEN N'VIEW DATABASE PERFORMANCE STATE'
                   ELSE N'VIEW DATABASE STATE' END AS [RequiredPermission]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage]
            , CONCAT(N'Zeitraum UTC: ', CONVERT(nvarchar(30), @VonUtc, 126),
                     N' bis ', CONVERT(nvarchar(30), @BisUtc, 126),
                     N'; Deep=', @Deep) AS [Detail];

        SELECT TOP (@EffectiveMaxZeilen) [r].*
        FROM [#QueryStoreRuntimeStats_Result] AS [r]
        ORDER BY
              CASE WHEN @Sortierung = 'LAST_EXECUTION' THEN [LastExecutionTimeUtc] END DESC
            , CASE WHEN @Sortierung = 'CPU_TOTAL' THEN [TotalCpuMs]
                   WHEN @Sortierung = 'DURATION_TOTAL' THEN [TotalDurationMs]
                   WHEN @Sortierung = 'READS_TOTAL' THEN [TotalLogicalReads]
                   WHEN @Sortierung = 'WRITES_TOTAL' THEN [TotalLogicalWrites]
                   WHEN @Sortierung = 'EXECUTIONS' THEN [ExecutionCount]
                   WHEN @Sortierung = 'MEMORY_MAX' THEN [MaxMemoryGrantKb]
                   WHEN @Sortierung = 'TEMPDB_TOTAL' THEN [TotalTempdbKb]
                   WHEN @Sortierung = 'LOG_BYTES_TOTAL' THEN [TotalLogBytes] END DESC
            , [LastExecutionTimeUtc] DESC
            , [QueryStoreDatabaseName]
            , [QueryId]
            , [PlanId];

        SELECT * FROM [#QueryStoreRuntimeStats_Errors] ORDER BY [DatabaseName];
    END
    ELSE IF @ResultSetArtNormalisiert = 'CONSOLE'
    BEGIN
        SELECT
              N'Query Store Runtime Stats' AS [Ergebnis]
            , @CollectionTimeUtc AS [Stand_UTC]
            , @StatusCode AS [Status]
            , @RowCount AS [Zeilen]
            , @HasMoreRows AS [Ergebnis_begrenzt]
            , @VonUtc AS [Von_UTC]
            , @BisUtc AS [Bis_UTC]
            , @ErrorMessage AS [Hinweis];

        SELECT TOP (@EffectiveMaxZeilen)
              N'Query-Store-Abfrage' AS [Ergebnis]
            , [r].[QueryStoreDatabaseName] AS [QueryStore_Datenbank]
            , [r].[QueryId] AS [Query_ID]
            , [r].[PlanId] AS [Plan_ID]
            , [r].[ObjectName] AS [Objekt]
            , [r].[ExecutionTypeDesc] AS [Execution_Type]
            , [r].[ExecutionCount] AS [Ausführungen]
            , CONCAT(CONVERT(varchar(50), [r].[TotalCpuMs]), N' ms') AS [CPU_gesamt]
            , CONCAT(CONVERT(varchar(50), [r].[AverageCpuMs]), N' ms') AS [CPU_durchschnitt]
            , CONCAT(CONVERT(varchar(50), [r].[TotalDurationMs]), N' ms') AS [Dauer_gesamt]
            , CONCAT(CONVERT(varchar(50), [r].[AverageDurationMs]), N' ms') AS [Dauer_durchschnitt]
            , [r].[TotalLogicalReads] AS [Logical_Reads_gesamt]
            , [r].[AverageLogicalReads] AS [Logical_Reads_durchschnitt]

            , [r].[QueryId] AS [Query_ID_Memory]
            , CONCAT(CONVERT(varchar(50), [r].[MaxMemoryGrantKb] / 1024.0), N' MB') AS [Max_Memory_Grant]
            , CONCAT(CONVERT(varchar(50), [r].[TotalTempdbKb] / 1024.0), N' MB') AS [TempDB_gesamt]
            , [r].[LastExecutionTimeUtc] AS [Letzte_Ausführung_UTC]
            , [r].[QuerySqlText] AS [SQL_Text]
            , [r].[QueryPlan] AS [Query_Plan]
        FROM [#QueryStoreRuntimeStats_Result] AS [r]
        ORDER BY
              CASE WHEN @Sortierung = 'LAST_EXECUTION' THEN [LastExecutionTimeUtc] END DESC
            , CASE WHEN @Sortierung = 'CPU_TOTAL' THEN [TotalCpuMs]
                   WHEN @Sortierung = 'DURATION_TOTAL' THEN [TotalDurationMs]
                   WHEN @Sortierung = 'READS_TOTAL' THEN [TotalLogicalReads]
                   WHEN @Sortierung = 'WRITES_TOTAL' THEN [TotalLogicalWrites]
                   WHEN @Sortierung = 'EXECUTIONS' THEN [ExecutionCount]
                   WHEN @Sortierung = 'MEMORY_MAX' THEN [MaxMemoryGrantKb]
                   WHEN @Sortierung = 'TEMPDB_TOTAL' THEN [TotalTempdbKb]
                   WHEN @Sortierung = 'LOG_BYTES_TOTAL' THEN [TotalLogBytes] END DESC
            , [LastExecutionTimeUtc] DESC
            , [QueryStoreDatabaseName]
            , [QueryId]
            , [PlanId];

        SELECT
              N'Query-Store-Warnung' AS [Ergebnis]
            , [DatabaseName] AS [Datenbank]
            , [StatusCode] AS [Status]
            , [ErrorNumber] AS [Fehlernummer]
            , [ErrorMessage] AS [Meldung]
        FROM [#QueryStoreRuntimeStats_Errors]
        ORDER BY [DatabaseName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#QueryStoreRuntimeStats_Result'
            , @ResultLabel=N'QueryStoreRuntimeStats'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#QueryStoreRuntimeStats_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
