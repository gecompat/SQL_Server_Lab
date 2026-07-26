USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_QueryStoreStatus
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Prüft den Query-Store-Zustand je ausgewählter Quelldatenbank.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : monitor.TVF_DatabaseCandidates,
               monitor.TVF_ParseSqlNameList, monitor.TVF_ParsePattern,
               sys.database_query_store_options.
Parameter    : @QueryStoreDatabaseNames, @SystemdatenbankenEinbeziehen,
               @QueryStoreDatabaseNamePattern,
               @ResultSetArt, @JsonErzeugen, @Json OUTPUT,
               @PrintMeldungen, @Hilfe.
Semantik     : @QueryStoreDatabaseNames ist eine bracket-aware Pipe-Liste.
               NULL, N'' und Leerzeichen bedeuten keine Einschränkung.
               Die Datenbankauswahl wird nicht vorab begrenzt.
Ausgabe      : RAW, CONSOLE, TABLE oder NONE; optionales JSON mit meta,
               queryStoreStatus und warnings.
Berechtigung : SQL 2019 VIEW DATABASE STATE; SQL 2022+
               VIEW DATABASE PERFORMANCE STATE oder höher.
Eigenlast    : Sehr gering; eine Statuszeile je Datenbank.
Locking      : LOCK_TIMEOUT 0; keine Änderungen.
Änderungen   : 2.0.0 - @AlleDatenbanken entfernt; Listen-/Patternvertrag,
                         case-insensitive Steuerwerte und JSON eingeführt.
               1.0.0 - Erstfassung Phase 4.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_QueryStoreStatus]
      @QueryStoreDatabaseNames         nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen    bit            = 0
    , @QueryStoreDatabaseNamePattern   nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ResultSetArt                    varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                    bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                  bit            = 1
    , @Hilfe                           bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @ResultSetArtNormalisiert varchar(16) =
        UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'queryStoreStatus',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @PatternMode varchar(8);
    DECLARE @PatternValue nvarchar(4000);
    DECLARE @RegexFlags varchar(8);
    DECLARE @PatternIsValid bit;

    SELECT
          @PatternMode = [PatternMode]
        , @PatternValue = [PatternValue]
        , @RegexFlags = [RegexFlags]
        , @PatternIsValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@QueryStoreDatabaseNamePattern);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_QueryStoreStatus';
        PRINT N'@QueryStoreDatabaseNames: konkreter Name oder Pipe-Liste; NULL/N'''' = alle zulässigen Datenbanken.';
        PRINT N'Beispiel: @QueryStoreDatabaseNames=N''[DeineDatenbank]|[BeispielDatenbankB]''.';
        PRINT N'@QueryStoreDatabaseNamePattern akzeptiert LIKE (Default/like:), regex: oder regexi:; Pattern und exakte Liste sind gegenseitig exklusiv.';
        PRINT N'Ohne Query-Store-Datenbankfilter werden alle sichtbaren Online-Benutzerdatenbanken verarbeitet.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE wird case-insensitiv verarbeitet; @JsonErzeugen=1 setzt @Json OUTPUT.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Allowed bit = 1;
    DECLARE @Db sysname;
    DECLARE @Sql nvarchar(max);
    DECLARE @RowCount bigint = 0;
    DECLARE @DatabaseListCount int = 0;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    CREATE TABLE [#QueryStoreStatus_DatabaseCandidates]
    (
          [DatabaseId]         int            NOT NULL
        , [DatabaseName]       sysname        NOT NULL
        , [StateDesc]          nvarchar(60)   NULL
        , [UserAccessDesc]     nvarchar(60)   NULL
        , [IsReadOnly]         bit            NULL
        , [CompatibilityLevel] tinyint        NULL
        , [CollationName]      sysname        NULL
        , [RecoveryModelDesc]  nvarchar(60)   NULL
        , [IsSystemDatabase]   bit            NULL
        , [RequestedOrdinal]   int            NULL
    );

    CREATE TABLE [#QueryStoreStatus_Result]
    (
          [DatabaseId] int NULL
        , [DatabaseName] sysname NOT NULL
        , [DesiredState] smallint NULL
        , [DesiredStateDesc] nvarchar(60) NULL
        , [ActualState] smallint NULL
        , [ActualStateDesc] nvarchar(60) NULL
        , [ReadonlyReason] int NULL
        , [CurrentStorageSizeMb] bigint NULL
        , [MaxStorageSizeMb] bigint NULL
        , [StorageUsedPercent] decimal(9,2) NULL
        , [FlushIntervalSeconds] bigint NULL
        , [IntervalLengthMinutes] bigint NULL
        , [StaleQueryThresholdDays] bigint NULL
        , [MaxPlansPerQuery] bigint NULL
        , [QueryCaptureMode] smallint NULL
        , [QueryCaptureModeDesc] nvarchar(60) NULL
        , [SizeBasedCleanupMode] smallint NULL
        , [SizeBasedCleanupModeDesc] nvarchar(60) NULL
        , [WaitStatsCaptureMode] smallint NULL
        , [WaitStatsCaptureModeDesc] nvarchar(60) NULL
        , [CapturePolicyExecutionCount] int NULL
        , [CapturePolicyTotalCompileCpuTimeMs] bigint NULL
        , [CapturePolicyTotalExecutionCpuTimeMs] bigint NULL
        , [CapturePolicyStaleThresholdHours] int NULL
        , [IsEnabled] bit NULL
        , [IsWritable] bit NULL
        , [StatusHint] nvarchar(1000) NULL
    );

    CREATE TABLE [#QueryStoreStatus_Errors]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR @PatternIsValid = 0
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültiger Pattern-, Mengen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @QueryStoreDatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass='QUERY_STORE_CURRENT'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#QueryStoreStatus_DatabaseCandidates';
    END;

    IF @StatusCode = 'AVAILABLE' AND @QueryStoreDatabaseNames IS NOT NULL
    BEGIN
        INSERT [#QueryStoreStatus_Errors]
        (
              [DatabaseName], [StatusCode], [ErrorNumber], [ErrorMessage]
        )
        SELECT
              [n].[NameValue]
            , 'DATABASE_NOT_FOUND'
            , NULL
            , N'Die explizit angeforderte Datenbank ist nicht online, nicht sichtbar oder nicht zugreifbar.'
        FROM [monitor].[TVF_ParseSqlNameList](@QueryStoreDatabaseNames) AS [n]
        WHERE [n].[IsValid] = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM [#QueryStoreStatus_DatabaseCandidates] AS [c]
              WHERE [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                  = [n].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS
          );

        IF EXISTS (SELECT 1 FROM [#QueryStoreStatus_Errors])
            SET @IsPartial = 1;
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE [c] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName]
            FROM [#QueryStoreStatus_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal], [DatabaseId]), [DatabaseId];

        OPEN [c];
        FETCH NEXT FROM [c] INTO @Db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
INSERT [#QueryStoreStatus_Result]
SELECT
      DB_ID()
    , (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID())
    , [desired_state]
    , [desired_state_desc]
    , [actual_state]
    , [actual_state_desc]
    , [readonly_reason]
    , [current_storage_size_mb]
    , [max_storage_size_mb]
    , CONVERT(decimal(9,2), 100.0 * [current_storage_size_mb] / NULLIF([max_storage_size_mb], 0))
    , [flush_interval_seconds]
    , [interval_length_minutes]
    , [stale_query_threshold_days]
    , [max_plans_per_query]
    , [query_capture_mode]
    , [query_capture_mode_desc]
    , [size_based_cleanup_mode]
    , [size_based_cleanup_mode_desc]
    , [wait_stats_capture_mode]
    , [wait_stats_capture_mode_desc]
    , [capture_policy_execution_count]
    , [capture_policy_total_compile_cpu_time_ms]
    , [capture_policy_total_execution_cpu_time_ms]
    , [capture_policy_stale_threshold_hours]
    , CONVERT(bit, CASE WHEN [actual_state] IN (1, 2, 4) THEN 1 ELSE 0 END)
    , CONVERT(bit, CASE WHEN [actual_state] = 2 THEN 1 ELSE 0 END)
    , CASE WHEN [actual_state] = 0 THEN N''Query Store ist OFF.''
           WHEN [actual_state] = 3 THEN N''Query Store meldet ERROR.''
           WHEN [desired_state] = 2 AND [actual_state] = 1
                THEN N''Query Store ist trotz gewünschtem READ_WRITE nur READ_ONLY; readonly_reason prüfen.''
           WHEN [max_storage_size_mb] > 0
            AND [current_storage_size_mb] * 100.0 / [max_storage_size_mb] >= 90
                THEN N''Speichernutzung liegt bei mindestens 90 Prozent.''
           ELSE N''Query Store ist lesbar.'' END
FROM [sys].[database_query_store_options] WITH (NOLOCK);';

                EXEC [sys].[sp_executesql] @Sql;
            END TRY
            BEGIN CATCH
                INSERT [#QueryStoreStatus_Errors]
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
                        N'WARNUNG USP_QueryStoreStatus [%s]: %s',
                        @Db,
                        ERROR_MESSAGE()
                    );
                    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
                END;
            END CATCH;

            FETCH NEXT FROM [c] INTO @Db;
        END;

        CLOSE [c];
        DEALLOCATE [c];

        SELECT @RowCount = COUNT_BIG(*) FROM [#QueryStoreStatus_Result];

        IF @RowCount = 0
        BEGIN
            SET @StatusCode = CASE WHEN EXISTS
                 (SELECT 1 FROM [#QueryStoreStatus_Errors] WHERE [StatusCode] = 'DENIED_PERMISSION')
                 THEN 'DENIED_PERMISSION' ELSE 'DATABASE_UNAVAILABLE' END;
            SELECT TOP (1)
                  @ErrorNumber = [ErrorNumber]
                , @ErrorMessage = [ErrorMessage]
            FROM [#QueryStoreStatus_Errors]
            ORDER BY [DatabaseName];
        END
        ELSE IF @IsPartial = 1
            SET @StatusCode = 'AVAILABLE_LIMITED';
    END;

    IF @PrintMeldungen = 1
       AND @StatusCode NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED')
    BEGIN
        SET @MonitorPrintMessage = FORMATMESSAGE
        (
            N'WARNUNG USP_QueryStoreStatus: %s - %s',
            @StatusCode,
            COALESCE(@ErrorMessage, N'Keine Details.')
        );
        RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  N'QueryStoreStatus' AS [resultName]
                , 1 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @IsPartial AS [isPartial]
                , @RowCount AS [returnedRows]
                , @ErrorNumber AS [errorNumber]
                , @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @DataJson nvarchar(max) =
            (SELECT * FROM [#QueryStoreStatus_Result] ORDER BY [DatabaseId]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT [DatabaseName] AS [databaseName], [StatusCode] AS [code],
                    [ErrorNumber] AS [errorNumber], [ErrorMessage] AS [message]
             FROM [#QueryStoreStatus_Errors] ORDER BY [DatabaseName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"queryStoreStatus":', COALESCE(@DataJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;

    IF @ResultSetArtNormalisiert = 'RAW'
    BEGIN
        SELECT
              N'USP_QueryStoreStatus' AS [ModuleName]
            , @CollectionTimeUtc AS [CollectionTimeUtc]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , @RowCount AS [RowCount]
            , CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
                   THEN N'VIEW DATABASE PERFORMANCE STATE'
                   ELSE N'VIEW DATABASE STATE' END AS [RequiredPermission]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage]
            , N'Read-only Query-Store-Statusprüfung.' AS [Detail];
        SELECT * FROM [#QueryStoreStatus_Result] ORDER BY [DatabaseId];
        SELECT * FROM [#QueryStoreStatus_Errors] ORDER BY [DatabaseName];
    END
    ELSE IF @ResultSetArtNormalisiert = 'CONSOLE'
    BEGIN
        SELECT
              N'Query Store Status' AS [Ergebnis]
            , @CollectionTimeUtc AS [Stand_UTC]
            , @StatusCode AS [Status]
            , @RowCount AS [Datenbanken]
            , @ErrorMessage AS [Hinweis];

        SELECT
              N'Query Store einer Datenbank' AS [Ergebnis]
            , [DatabaseName] AS [Datenbank]
            , [ActualStateDesc] AS [Ist_Status]
            , [DesiredStateDesc] AS [Soll_Status]
            , CONCAT(CONVERT(varchar(40), [CurrentStorageSizeMb]), N' MB') AS [Belegt]
            , CONCAT(CONVERT(varchar(40), [MaxStorageSizeMb]), N' MB') AS [Maximum]
            , CONCAT(CONVERT(varchar(40), [StorageUsedPercent]), N' %') AS [Belegung]
            , [QueryCaptureModeDesc] AS [Capture_Mode]
            , [WaitStatsCaptureModeDesc] AS [Wait_Stats]
            , [StatusHint] AS [Hinweis]
        FROM [#QueryStoreStatus_Result]
        ORDER BY [DatabaseId];

        SELECT
              N'Query-Store-Warnung' AS [Ergebnis]
            , [DatabaseName] AS [Datenbank]
            , [StatusCode] AS [Status]
            , [ErrorNumber] AS [Fehlernummer]
            , [ErrorMessage] AS [Meldung]
        FROM [#QueryStoreStatus_Errors]
        ORDER BY [DatabaseName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#QueryStoreStatus_Result'
            , @ResultLabel=N'QueryStoreStatus'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#QueryStoreStatus_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
