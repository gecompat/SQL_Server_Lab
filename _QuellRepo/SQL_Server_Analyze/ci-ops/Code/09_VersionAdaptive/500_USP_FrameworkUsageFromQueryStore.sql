USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_FrameworkUsageFromQueryStore
Version      : 1.0.0
Stand        : 2026-07-25
Typ          : Stored Procedure
Zweck        : Liest aus dem Query Store der Installationsdatenbank die
               tatsächlich ausgeführten monitor.*-Procedures mit Ausführungs-
               häufigkeit, Laufzeitstatistiken und letztem Ausführungszeitpunkt.
               Zero-Footprint: kein Schreiben, keine zusätzlichen Objekte,
               nutzt ausschließlich vorhandene Query-Store-Daten.
Voraussetzung: Query Store muss in der Installationsdatenbank aktiviert sein.
               Mindestens READ_ONLY-Zugriff auf Query Store Views.
SQL-Version  : SQL Server 2019 oder neuer.
Parameter    : @MaxZeilen int = 100 (0/NULL = alle)
               @MinAusfuehrungen bigint = 1
               @ZeitraumTage int = NULL (NULL = gesamter Query-Store-Inhalt)
               @ResultSetArt varchar(16) = 'CONSOLE'
               @Json nvarchar(max) OUTPUT
Resultset    : ProcedureName, ExecutionCount, LastExecutionTime,
               AvgDurationMs, AvgCpuMs, AvgLogicalReads, AvgMemoryGrantKB,
               PlanCount, QueryCount, FirstSeen, LastSeen.
Collation    : Vergleiche verwenden SQL_Latin1_General_CP1_CS_AS.
Eigenlast    : Leichtgewichtig; liest Query-Store-Katalogsichten.
Locking      : Keine Schreiboperationen; keine Lock-Eskalation.
Aufruf       : EXEC [monitor].[USP_FrameworkUsageFromQueryStore];
               EXEC [monitor].[USP_FrameworkUsageFromQueryStore]
                     @ZeitraumTage = 30, @MinAusfuehrungen = 5;
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_FrameworkUsageFromQueryStore]
      @MaxZeilen         int            = 100
    , @MinAusfuehrungen  bigint         = 1
    , @ZeitraumTage      int            = NULL
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @Json              nvarchar(max)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @ModuleName sysname = N'USP_FrameworkUsageFromQueryStore';
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));

    -- Query Store aktiviert?
    DECLARE @QsState smallint;
    SELECT @QsState = TRY_CONVERT(smallint, [actual_state])
    FROM [sys].[database_query_store_options];

    IF @QsState IS NULL OR @QsState = 0
    BEGIN
        SET @StatusCode = 'UNAVAILABLE_FEATURE';
        SET @ErrorMessage = N'Query Store ist in dieser Datenbank nicht aktiviert oder nicht lesbar.';
        IF @ResultSetArtNormalisiert IN ('CONSOLE', 'RAW')
            SELECT
                  @StatusCode  AS [StatusCode]
                , @ErrorMessage AS [ErrorMessage]
                , CAST(NULL AS sysname) AS [ProcedureName]
                , CAST(NULL AS bigint)  AS [ExecutionCount]
            WHERE 1 = 0;
        RETURN;
    END;

    -- Zeitraumfilter
    DECLARE @CutoffUtc datetime2(3) = NULL;
    IF @ZeitraumTage IS NOT NULL AND @ZeitraumTage > 0
        SET @CutoffUtc = DATEADD(DAY, -@ZeitraumTage, SYSUTCDATETIME());

    -- Zeilenlimit
    DECLARE @EffectiveMaxRows bigint = CASE
        WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN 2147483647
        WHEN @MaxZeilen < 0 THEN 0
        ELSE @MaxZeilen
    END;

    IF @EffectiveMaxRows = 0
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@MaxZeilen darf nicht negativ sein.';
        IF @ResultSetArtNormalisiert IN ('CONSOLE', 'RAW')
            SELECT @StatusCode AS [StatusCode], @ErrorMessage AS [ErrorMessage]
            WHERE 1 = 0;
        RETURN;
    END;

    ;WITH [FrameworkQueries] AS
    (
        SELECT
              [o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS AS [ProcedureName]
            , [q].[query_id]
            , [q].[object_id]
        FROM [sys].[query_store_query] AS [q] WITH (NOLOCK)
        INNER JOIN [sys].[objects] AS [o] WITH (NOLOCK)
            ON [q].[object_id] = [o].[object_id]
        INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
            ON [o].[schema_id] = [s].[schema_id]
        WHERE [s].[name] = N'monitor' COLLATE SQL_Latin1_General_CP1_CS_AS
          AND [o].[type] IN ('P', 'FN', 'IF', 'TF')
    ),
    [RuntimeStats] AS
    (
        SELECT
              [fq].[ProcedureName]
            , SUM([rs].[count_executions])                   AS [ExecutionCount]
            , MAX([rs].[last_execution_time])                 AS [LastExecutionTime]
            , AVG([rs].[avg_duration]) / 1000.0              AS [AvgDurationMs]
            , AVG([rs].[avg_cpu_time]) / 1000.0              AS [AvgCpuMs]
            , AVG([rs].[avg_logical_io_reads])                AS [AvgLogicalReads]
            , AVG([rs].[avg_query_max_used_memory]) * 8.0    AS [AvgMemoryGrantKB]
            , COUNT(DISTINCT [p].[plan_id])                   AS [PlanCount]
            , COUNT(DISTINCT [fq].[query_id])                 AS [QueryCount]
            , MIN([rs].[first_execution_time])                AS [FirstSeen]
            , MAX([rs].[last_execution_time])                 AS [LastSeen]
        FROM [FrameworkQueries] AS [fq]
        INNER JOIN [sys].[query_store_plan] AS [p] WITH (NOLOCK)
            ON [fq].[query_id] = [p].[query_id]
        INNER JOIN [sys].[query_store_runtime_stats] AS [rs] WITH (NOLOCK)
            ON [p].[plan_id] = [rs].[plan_id]
        WHERE (@CutoffUtc IS NULL OR [rs].[last_execution_time] >= @CutoffUtc)
        GROUP BY [fq].[ProcedureName]
        HAVING SUM([rs].[count_executions]) >= @MinAusfuehrungen
    )
    SELECT TOP (@EffectiveMaxRows)
          [ProcedureName]
        , [ExecutionCount]
        , [LastExecutionTime]
        , CAST([AvgDurationMs] AS decimal(18,2))      AS [AvgDurationMs]
        , CAST([AvgCpuMs] AS decimal(18,2))           AS [AvgCpuMs]
        , CAST([AvgLogicalReads] AS decimal(18,2))    AS [AvgLogicalReads]
        , CAST([AvgMemoryGrantKB] AS decimal(18,2))   AS [AvgMemoryGrantKB]
        , [PlanCount]
        , [QueryCount]
        , [FirstSeen]
        , [LastSeen]
    FROM [RuntimeStats]
    ORDER BY [ExecutionCount] DESC;
END;
GO
