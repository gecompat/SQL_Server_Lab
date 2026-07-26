USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_PlanCacheAnalysis
Version      : 2.1.0
Stand        : 2026-07-19
Zweck        : Orchestriert Plan-Cache- und Showplan-Module mit einheitlichen
               Listen-, Pattern-, Limit- und Ausgabeparametern.
Änderungen   : 2.1.0 - dm_exec_query_stats bei mehreren Consumern einmalig
                         laufgebunden materialisiert und wiederverwendet.
               2.0.1 - IF/TRY/CATCH-Blöcke syntaktisch eindeutig strukturiert.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_PlanCacheAnalysis]
      @MitQueryStats                    bit            = 1
    , @MitQueryHashAnalysis             bit            = 0
    , @MitPlanCacheHealth               bit            = 0
    , @MitShowplanAnalysis              bit            = 0
    , @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @QueryHash                        binary(8)      = NULL
    , @QueryPlanHash                    binary(8)      = NULL
    , @PlanHandle                       varbinary(64)  = NULL
    , @TextPattern                      nvarchar(4000) = NULL
    , @Sortierung                       varchar(32)    = 'CPU_TOTAL'
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MaxAnalyseobjekte                int            = 20
    , @MaxDurationSeconds               int            = 30
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'moduleStatus',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Mode varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus, 'TOP'))));
    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @Detail nvarchar(2000) = N'Aktivierte Phase-3-Module werden nacheinander ausgeführt.';
    DECLARE @HealthMode varchar(16) = CASE WHEN @Mode = 'VOLL' THEN 'VOLL' ELSE 'SUMMARY' END;
    DECLARE @MitDbVerteilung bit = CASE WHEN @Mode = 'VOLL' THEN 1 ELSE 0 END;
    DECLARE @ShowplanMode varchar(16) = CASE WHEN @Mode = 'VOLL' THEN 'VOLL' ELSE 'GEZIELT' END;
    DECLARE @QueryStatsSnapshotConsumerCount tinyint =
        CONVERT(tinyint, CONVERT(tinyint,COALESCE(@MitQueryStats,0))
            + CONVERT(tinyint,COALESCE(@MitQueryHashAnalysis,0))
            + CASE WHEN @MitShowplanAnalysis=1 AND @PlanHandle IS NULL THEN 1 ELSE 0 END);
    DECLARE @QueryStatsSnapshotAvailable bit = 0;
    DECLARE @QueryStatsSnapshotAllowed bit = 1;
    DECLARE @ShowplanUsesQueryStatsSnapshot bit = 0;
    DECLARE @QueryStatsJson nvarchar(max);
    DECLARE @HashJson nvarchar(max);
    DECLARE @HealthJson nvarchar(max);
    DECLARE @ShowplanJson nvarchar(max);

    DECLARE @Errors TABLE
    (
          [ExecutionOrdinal] tinyint        NOT NULL
        , [ModuleName]       sysname        NOT NULL
        , [InvocationStatus] varchar(40)    NOT NULL
        , [ErrorNumber]      int            NULL
        , [ErrorMessage]     nvarchar(2048) NULL
    );
    CREATE TABLE [#PlanCacheAnalysis_QueryStatsSnapshot]
    (
          [sql_handle] varbinary(64) NULL
        , [statement_start_offset] int NULL
        , [statement_end_offset] int NULL
        , [plan_generation_num] bigint NULL
        , [plan_handle] varbinary(64) NULL
        , [creation_time] datetime NULL
        , [last_execution_time] datetime NULL
        , [execution_count] bigint NULL
        , [total_worker_time] bigint NULL
        , [last_worker_time] bigint NULL
        , [min_worker_time] bigint NULL
        , [max_worker_time] bigint NULL
        , [total_physical_reads] bigint NULL
        , [last_physical_reads] bigint NULL
        , [total_logical_writes] bigint NULL
        , [last_logical_writes] bigint NULL
        , [total_logical_reads] bigint NULL
        , [last_logical_reads] bigint NULL
        , [total_elapsed_time] bigint NULL
        , [last_elapsed_time] bigint NULL
        , [min_elapsed_time] bigint NULL
        , [max_elapsed_time] bigint NULL
        , [query_hash] binary(8) NULL
        , [query_plan_hash] binary(8) NULL
        , [total_rows] bigint NULL
        , [last_rows] bigint NULL
        , [min_rows] bigint NULL
        , [max_rows] bigint NULL
        , [last_dop] bigint NULL
        , [min_dop] bigint NULL
        , [max_dop] bigint NULL
        , [max_grant_kb] bigint NULL
        , [last_grant_kb] bigint NULL
        , [last_used_grant_kb] bigint NULL
        , [last_ideal_grant_kb] bigint NULL
        , [total_spills] bigint NULL
        , [last_spills] bigint NULL
    );

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_PlanCacheAnalysis';
        PRINT N'Datenbank- und Textfilter folgen den zentralen Listen-/Patternverträgen.';
        PRINT N'@ResultSetArt = RAW, CONSOLE, TABLE oder NONE; optional JSON über @Json OUTPUT.';
        RETURN;
    END;

    IF @MaxZeilen < 0
       OR @MaxAnalyseobjekte < 0

       OR @MaxDurationSeconds NOT BETWEEN 1 AND 3600
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR @Mode NOT IN ('TOP', 'VOLL')
       OR (@MitQueryStats = 0 AND @MitQueryHashAnalysis = 0
           AND @MitPlanCacheHealth = 0 AND @MitShowplanAnalysis = 0)
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @Detail = N'Ungültiger Parameter oder kein Teilmodul aktiviert.';
    END;

    IF @StatusCode = 'AVAILABLE'
       AND @QueryStatsSnapshotConsumerCount >= 2
       AND
       (
           @QueryHash IS NULL
           OR @Mode = 'VOLL'
           OR @MaxZeilen IS NULL
           OR @MaxZeilen = 0
           OR @MaxZeilen > 1000
       )
    BEGIN
        EXEC [monitor].[InternalCheckAnalysisPath]
              @AnalysisClass='PLAN_CACHE_DEEP'
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@Detail OUTPUT;
        SET @QueryStatsSnapshotAllowed=CONVERT(bit,CASE WHEN @StatusCode='AVAILABLE' THEN 1 ELSE 0 END);
    END;

    IF @StatusCode = 'AVAILABLE'
       AND @QueryStatsSnapshotConsumerCount >= 2
       AND @QueryStatsSnapshotAllowed = 1
    BEGIN TRY
        INSERT [#PlanCacheAnalysis_QueryStatsSnapshot]
        SELECT
              [sql_handle], [statement_start_offset], [statement_end_offset], [plan_generation_num]
            , [plan_handle], [creation_time], [last_execution_time], [execution_count]
            , [total_worker_time], [last_worker_time], [min_worker_time], [max_worker_time]
            , [total_physical_reads], [last_physical_reads]
            , [total_logical_writes], [last_logical_writes]
            , [total_logical_reads], [last_logical_reads]
            , [total_elapsed_time], [last_elapsed_time], [min_elapsed_time], [max_elapsed_time]
            , [query_hash], [query_plan_hash]
            , [total_rows], [last_rows], [min_rows], [max_rows]
            , [last_dop], [min_dop], [max_dop]
            , [max_grant_kb], [last_grant_kb], [last_used_grant_kb], [last_ideal_grant_kb]
            , [total_spills], [last_spills]
        FROM [sys].[dm_exec_query_stats] WITH (NOLOCK)
        WHERE @QueryHash IS NULL OR [query_hash]=@QueryHash;

        SET @QueryStatsSnapshotAvailable = 1;
        SET @ShowplanUsesQueryStatsSnapshot = CASE WHEN @MitShowplanAnalysis=1 AND @PlanHandle IS NULL THEN 1 ELSE 0 END;
        SET @Detail = N'dm_exec_query_stats wurde einmalig für die aktivierten Consumer materialisiert.';
    END TRY
    BEGIN CATCH
        DELETE FROM [#PlanCacheAnalysis_QueryStatsSnapshot];
        SET @QueryStatsSnapshotAvailable = 0;
        SET @ShowplanUsesQueryStatsSnapshot = 0;
        SET @Detail = N'Der gemeinsame dm_exec_query_stats-Snapshot war nicht verfügbar; aktivierte Children lesen mit eigenem Fehlerstatus frisch.';
    END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitQueryStats = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStats]
                  @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @QueryHash = @QueryHash
                , @QueryPlanHash = @QueryPlanHash
                , @PlanHandle = @PlanHandle
                , @TextPattern = @TextPattern
                , @Sortierung = @Sortierung
                , @AnalyseModus = @Mode
                , @MaxZeilen = @MaxZeilen
                , @ParentQueryStatsSnapshot = @QueryStatsSnapshotAvailable
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @QueryStatsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @Errors VALUES (1, N'USP_QueryStats',
                CASE WHEN @QueryStatsSnapshotAvailable=1 THEN 'REUSED_PARENT_SNAPSHOT' ELSE 'EXECUTED' END, NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @Errors VALUES (1, N'USP_QueryStats', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitQueryHashAnalysis = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryHashAnalysis]
                  @QueryHash = @QueryHash
                , @Sortierung = @Sortierung
                , @AnalyseModus = @Mode
                , @MaxZeilen = @MaxZeilen
                , @HighImpactConfirmed = @HighImpactConfirmed
                , @ParentQueryStatsSnapshot = @QueryStatsSnapshotAvailable
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @HashJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @Errors VALUES (2, N'USP_QueryHashAnalysis',
                CASE WHEN @QueryStatsSnapshotAvailable=1 THEN 'REUSED_PARENT_SNAPSHOT' ELSE 'EXECUTED' END, NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @Errors VALUES (2, N'USP_QueryHashAnalysis', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitPlanCacheHealth = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_PlanCacheHealth]
                  @AnalyseModus = @HealthMode
                , @MitDatenbankVerteilung = @MitDbVerteilung
                , @MaxZeilen = @MaxZeilen
                , @HighImpactConfirmed = @HighImpactConfirmed
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @HealthJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @Errors VALUES (3, N'USP_PlanCacheHealth', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @Errors VALUES (3, N'USP_PlanCacheHealth', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitShowplanAnalysis = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_ShowplanAnalysis]
                  @PlanHandle = @PlanHandle
                , @QueryHash = @QueryHash
                , @QueryPlanHash = @QueryPlanHash
                , @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @TextPattern = @TextPattern
                , @AnalyseModus = @ShowplanMode
                , @Sortierung = @Sortierung
                , @MaxAnalyseobjekte = @MaxAnalyseobjekte
                , @MaxZeilen = @MaxZeilen
                , @MaxDurationSeconds = @MaxDurationSeconds
                , @ParentQueryStatsSnapshot = @ShowplanUsesQueryStatsSnapshot
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @ShowplanJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @Errors VALUES (4, N'USP_ShowplanAnalysis',
                CASE WHEN @ShowplanUsesQueryStatsSnapshot=1 THEN 'REUSED_PARENT_SNAPSHOT' ELSE 'EXECUTED' END, NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @Errors VALUES (4, N'USP_ShowplanAnalysis', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF EXISTS (SELECT 1 FROM @Errors WHERE [InvocationStatus] NOT IN ('EXECUTED','REUSED_PARENT_SNAPSHOT'))
       AND @StatusCode = 'AVAILABLE'
    BEGIN
        SET @StatusCode = 'AVAILABLE_LIMITED';
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT
              N'USP_PlanCacheAnalysis' AS [ModuleName]
            , @Now                    AS [CollectionTimeUtc]
            , @StatusCode             AS [StatusCode]
            , CONVERT(bit, CASE WHEN @StatusCode = 'AVAILABLE' THEN 0 ELSE 1 END) AS [IsPartial]
            , @Detail                 AS [Detail];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT * FROM @Errors ORDER BY [ExecutionOrdinal];
        END
        ELSE
        BEGIN
            SELECT
                  N'Plan-Cache Teilmodul' AS [Ergebnis]
                , [ExecutionOrdinal]      AS [Reihenfolge]
                , [ModuleName]            AS [Modul]
                , [InvocationStatus]      AS [Status]
                , [ErrorMessage]          AS [Fehler]
            FROM @Errors
            ORDER BY [ExecutionOrdinal];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @Meta nvarchar(max);
        DECLARE @Modules nvarchar(max);
        DECLARE @Warnings nvarchar(max);

        SELECT @Meta =
        (
            SELECT
                  N'PlanCacheAnalysis' AS [resultName]
                , 1                    AS [schemaVersion]
                , @Now                 AS [generatedAtUtc]
                , @StatusCode          AS [statusCode]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        SELECT @Modules =
        (
            SELECT *
            FROM @Errors
            ORDER BY [ExecutionOrdinal]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        SELECT @Warnings =
        (
            SELECT *
            FROM @Errors
            WHERE [InvocationStatus] NOT IN ('EXECUTED','REUSED_PARENT_SNAPSHOT')
            ORDER BY [ExecutionOrdinal]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@Meta, N'{}')
            , N',"queryStats":', COALESCE(JSON_QUERY(@QueryStatsJson), N'null')
            , N',"queryHashes":', COALESCE(JSON_QUERY(@HashJson), N'null')
            , N',"planCacheHealth":', COALESCE(JSON_QUERY(@HealthJson), N'null')
            , N',"showplan":', COALESCE(JSON_QUERY(@ShowplanJson), N'null')
            , N',"modules":', COALESCE(@Modules, N'[]')
            , N',"warnings":', COALESCE(@Warnings, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#PlanCacheAnalysis_MonitorTableResult'
            , @ResultLabel=N'PlanCacheAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        SELECT * INTO [#PlanCacheAnalysis_MonitorTableResult] FROM @Errors;
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#PlanCacheAnalysis_MonitorTableResult'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
