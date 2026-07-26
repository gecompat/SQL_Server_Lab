USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CurrentLog
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Liefert den aktuellen Transaktionslogzustand einer expliziten
               Datenbankliste oder aller zulässigen Datenbanken. Fehler einer
               Datenbank brechen die übrigen Abfragen nicht ab.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : master.sys.databases, sys.dm_db_log_space_usage,
               sys.dm_db_log_stats, optional sys.dm_db_log_info,
               optional sys.dm_tran_persistent_version_store_stats.
Parameter    : @DatabaseNames, @DatabaseNamePattern,
               @SystemdatenbankenEinbeziehen, @MinUsedPercent,
               @MitVlfInformationen, @MitPersistentVersionStore,
               @MaxZeilen, @ResultSetArt,
               @JsonErzeugen, @Json OUTPUT, @PrintMeldungen, @Hilfe.
Semantik     : @DatabaseNames enthält eine bracket-aware Pipe-Liste exakter
               Namen. NULL bedeutet alle zulässigen Datenbanken; N'' ist
               absichtlich ungültig. Exakte Liste und Pattern sind exklusiv.
Ausgabe      : RAW = stabiler technischer Vertrag; CONSOLE = formatierte
               Darstellung; NONE = kein Resultset. JSON enthält meta, logs,
               databaseStatus und warnings als benannte Arrays.
Berechtigung : Je Datenquelle VIEW SERVER STATE/VIEW SERVER PERFORMANCE STATE
               bzw. VIEW DATABASE PERFORMANCE STATE ab SQL Server 2022.
Gruppengate  : Cross-Database über CROSS_DATABASE_DEEP; VLF über LOG_VLF_DEEP.
Eigenlast    : Standard moderat; automatische Datenbankauswahl ist durch
               keine Datenbank-Vorabbegrenzung.
Locking      : Datenbankliste READUNCOMMITTED; System-DMVs je Datenbank.
Beispiele    : EXEC [monitor].[USP_CurrentLog]
                    @DatabaseNames=N'[DeineDatenbank]|[BeispielDatenbankB]';
               EXEC [monitor].[USP_CurrentLog]
                    @DatabaseNames=NULL,@DatabaseNamePattern=N'like:Database_%';
               DECLARE @J nvarchar(max);
               EXEC [monitor].[USP_CurrentLog] @DatabaseNames=N'[DeineDatenbank]',
                    @ResultSetArt='none',@JsonErzeugen=1,@Json=@J OUTPUT;
               SELECT @J AS [Json];
Änderungen   : 2.0.0 - @AlleDatenbanken entfernt; Listen-/Patternvertrag,
                         RAW/CONSOLE/NONE und JSON-Envelope eingeführt.
               1.0.0 - Erstfassung Phase 1B.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CurrentLog]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MinUsedPercent                   decimal(5,2)   = NULL
    , @MitVlfInformationen              bit            = 0
    , @MitPersistentVersionStore        bit            = 0
    , @MaxZeilen                        int            = 1000
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

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'logs',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807)
             WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen)
             ELSE CONVERT(bigint, 0) END;
    DECLARE @CandidateMaxZeilen bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807)
             WHEN @MaxZeilen BETWEEN 1 AND 2147483646 THEN CONVERT(bigint, @MaxZeilen) + 1
             WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen)
             ELSE CONVERT(bigint, 0) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CurrentLog';
        PRINT N'@DatabaseNames=N''[Db1]|[Db2]''; NULL=alle zulässigen Datenbanken; N'''' bedeutet keine Einschränkung.';
        PRINT N'@DatabaseNamePattern: ein Pattern mit like:, regex: oder regexi:; exklusiv zu @DatabaseNames.';
        PRINT N'Die Datenbankauswahl wird nicht vorab begrenzt.';
        PRINT N'@MaxZeilen: positiv begrenzt; NULL/0=unbegrenzt; negativ=INVALID_PARAMETER.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE (case-insensitiv); @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        PRINT N'@MitVlfInformationen=1 erfordert LOG_VLF_DEEP.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @RowCount bigint = 0;
    DECLARE @CandidateRowCount bigint = 0;
    DECLARE @HasMoreRows bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Detail nvarchar(2000) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @VlfAllowed bit = 0;
    DECLARE @VlfStatus varchar(40) = 'SKIPPED';
    DECLARE @RequiredPermission nvarchar(256) =
        CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
             THEN N'VIEW SERVER PERFORMANCE STATE / VIEW DATABASE PERFORMANCE STATE'
             ELSE N'VIEW SERVER STATE' END;

    CREATE TABLE [#CurrentLog_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );

    CREATE TABLE [#CurrentLog_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );

    CREATE TABLE [#CurrentLog_Result]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [RecoveryModel] nvarchar(60) NULL
        , [LogReuseWaitDesc] nvarchar(60) NULL
        , [TotalLogSizeMb] decimal(19,2) NULL
        , [UsedLogSizeMb] decimal(19,2) NULL
        , [UsedLogPercent] decimal(19,4) NULL
        , [LogSinceLastBackupMb] decimal(19,2) NULL
        , [ActiveVlfCount] bigint NULL
        , [TotalVlfCount] bigint NULL
        , [LogTruncationHoldupReason] nvarchar(60) NULL
        , [LogBackupTime] datetime NULL
        , [LogRecoverySizeMb] decimal(19,2) NULL
        , [IsAdrEnabled] bit NULL
        , [PersistentVersionStoreMb] decimal(19,2) NULL
        , [SpaceStatus] varchar(40) NOT NULL
        , [StatsStatus] varchar(40) NOT NULL
        , [VlfStatus] varchar(40) NOT NULL
        , [PvsStatus] varchar(40) NOT NULL
    );

    CREATE TABLE [#CurrentLog_Errors]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [SubModule] varchar(40) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @MaxZeilen < 0
       OR (@MinUsedPercent IS NOT NULL AND (@MinUsedPercent < 0 OR @MinUsedPercent > 100))
       OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültige Mengen-, Prozent- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = 'STANDARD_CURRENT'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#CurrentLog_DatabaseCandidates',@WarningTable=N'#CurrentLog_DatabaseCandidateWarnings';
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitVlfInformationen = 1
    BEGIN
        EXEC [monitor].[InternalCheckAnalysisPath]
              @AnalysisClass='LOG_VLF_DEEP'
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT;
        SET @VlfStatus=@StatusCode;
        SET @VlfAllowed=CONVERT(bit,CASE WHEN @StatusCode='AVAILABLE' THEN 1 ELSE 0 END);
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        INSERT [#CurrentLog_Result]
        (
              [DatabaseId], [DatabaseName], [RecoveryModel], [LogReuseWaitDesc]
            , [IsAdrEnabled], [SpaceStatus], [StatsStatus], [VlfStatus], [PvsStatus]
        )
        SELECT
              [d].[database_id]
            , [d].[name]
            , [d].[recovery_model_desc]
            , [d].[log_reuse_wait_desc]
            , [d].[is_accelerated_database_recovery_on]
            , 'PENDING'
            , 'PENDING'
            , CASE WHEN @MitVlfInformationen = 0 THEN 'SKIPPED' ELSE @VlfStatus END
            , CASE WHEN @MitPersistentVersionStore = 0 THEN 'SKIPPED' ELSE 'PENDING' END
        FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
        INNER JOIN [#CurrentLog_DatabaseCandidates] AS [c]
          ON [c].[DatabaseId] = [d].[database_id];

        DECLARE @DbName sysname;
        DECLARE @DbId int;
        DECLARE @Sql nvarchar(max);
        DECLARE @Total decimal(19,2);
        DECLARE @Used decimal(19,2);
        DECLARE @Pct decimal(19,4);
        DECLARE @Since decimal(19,2);
        DECLARE @ActiveVlf bigint;
        DECLARE @TotalVlf bigint;
        DECLARE @Holdup nvarchar(60);
        DECLARE @Backup datetime;
        DECLARE @Recovery decimal(19,2);
        DECLARE @Cnt bigint;

        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [DatabaseId], [DatabaseName]
        FROM [#CurrentLog_DatabaseCandidates]
        ORDER BY COALESCE([RequestedOrdinal], [DatabaseId]), [DatabaseId];

        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DbId, @DbName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Total = NULL; SET @Used = NULL; SET @Pct = NULL; SET @Since = NULL;
                SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
SELECT
      @Total = CONVERT(decimal(19,2), [total_log_size_in_bytes] / 1048576.0)
    , @Used  = CONVERT(decimal(19,2), [used_log_space_in_bytes] / 1048576.0)
    , @Pct   = CONVERT(decimal(19,4), [used_log_space_in_percent])
    , @Since = CONVERT(decimal(19,2), [log_space_in_bytes_since_last_backup] / 1048576.0)
FROM [sys].[dm_db_log_space_usage] WITH (NOLOCK);';
                EXEC [sys].[sp_executesql] @Sql,
                    N'@Total decimal(19,2) OUTPUT,@Used decimal(19,2) OUTPUT,@Pct decimal(19,4) OUTPUT,@Since decimal(19,2) OUTPUT',
                    @Total OUTPUT, @Used OUTPUT, @Pct OUTPUT, @Since OUTPUT;
                UPDATE [#CurrentLog_Result]
                SET [TotalLogSizeMb] = @Total, [UsedLogSizeMb] = @Used,
                    [UsedLogPercent] = @Pct, [LogSinceLastBackupMb] = @Since,
                    [SpaceStatus] = 'AVAILABLE'
                WHERE [DatabaseId] = @DbId;
            END TRY
            BEGIN CATCH
                UPDATE [#CurrentLog_Result]
                SET [SpaceStatus] = CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                                         WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END
                WHERE [DatabaseId] = @DbId;
                INSERT [#CurrentLog_Errors] VALUES(@DbName, 'LOG_SPACE',
                    CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                         WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
                    ERROR_NUMBER(), ERROR_MESSAGE());
                SET @IsPartial = 1;
            END CATCH;

            BEGIN TRY
                SET @ActiveVlf = NULL; SET @TotalVlf = NULL; SET @Holdup = NULL;
                SET @Backup = NULL; SET @Recovery = NULL;
                SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
SELECT
      @ActiveVlf = [active_vlf_count]
    , @TotalVlf = [total_vlf_count]
    , @Holdup = [log_truncation_holdup_reason]
    , @Backup = [log_backup_time]
    , @Recovery = CONVERT(decimal(19,2), [log_recovery_size_mb])
FROM [sys].[dm_db_log_stats](DB_ID());';
                EXEC [sys].[sp_executesql] @Sql,
                    N'@ActiveVlf bigint OUTPUT,@TotalVlf bigint OUTPUT,@Holdup nvarchar(60) OUTPUT,@Backup datetime OUTPUT,@Recovery decimal(19,2) OUTPUT',
                    @ActiveVlf OUTPUT, @TotalVlf OUTPUT, @Holdup OUTPUT, @Backup OUTPUT, @Recovery OUTPUT;
                UPDATE [#CurrentLog_Result]
                SET [ActiveVlfCount] = @ActiveVlf, [TotalVlfCount] = @TotalVlf,
                    [LogTruncationHoldupReason] = @Holdup, [LogBackupTime] = @Backup,
                    [LogRecoverySizeMb] = @Recovery, [StatsStatus] = 'AVAILABLE'
                WHERE [DatabaseId] = @DbId;
            END TRY
            BEGIN CATCH
                UPDATE [#CurrentLog_Result]
                SET [StatsStatus] = CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                                         WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END
                WHERE [DatabaseId] = @DbId;
                INSERT [#CurrentLog_Errors] VALUES(@DbName, 'LOG_STATS',
                    CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                         WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
                    ERROR_NUMBER(), ERROR_MESSAGE());
                SET @IsPartial = 1;
            END CATCH;

            IF @MitVlfInformationen = 1 AND @VlfAllowed = 1
            BEGIN
                BEGIN TRY
                    SET @Cnt = NULL;
                    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
SELECT @Cnt = COUNT_BIG(*) FROM [sys].[dm_db_log_info](DB_ID());';
                    EXEC [sys].[sp_executesql] @Sql, N'@Cnt bigint OUTPUT', @Cnt OUTPUT;
                    UPDATE [#CurrentLog_Result]
                    SET [TotalVlfCount] = COALESCE([TotalVlfCount], @Cnt), [VlfStatus] = 'AVAILABLE'
                    WHERE [DatabaseId] = @DbId;
                END TRY
                BEGIN CATCH
                    UPDATE [#CurrentLog_Result]
                    SET [VlfStatus] = CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                                           WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END
                    WHERE [DatabaseId] = @DbId;
                    INSERT [#CurrentLog_Errors] VALUES(@DbName, 'LOG_INFO',
                        CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                             WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
                        ERROR_NUMBER(), ERROR_MESSAGE());
                    SET @IsPartial = 1;
                END CATCH;
            END;

            FETCH NEXT FROM [DatabaseCursor] INTO @DbId, @DbName;
        END;

        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];

        IF @MitPersistentVersionStore = 1
        BEGIN
            BEGIN TRY
                ;WITH [Pvs] AS
                (
                    SELECT [database_id], SUM([persistent_version_store_size_kb]) AS [PersistentVersionStoreSizeKb]
                    FROM [sys].[dm_tran_persistent_version_store_stats] WITH (NOLOCK)
                    GROUP BY [database_id]
                )
                UPDATE [r]
                SET [PersistentVersionStoreMb] = CONVERT(decimal(19,2), COALESCE([p].[PersistentVersionStoreSizeKb], 0) / 1024.0),
                    [PvsStatus] = 'AVAILABLE'
                FROM [#CurrentLog_Result] AS [r]
                LEFT JOIN [Pvs] AS [p] ON [p].[database_id] = [r].[DatabaseId]
                WHERE [r].[IsAdrEnabled] = 1;

                UPDATE [#CurrentLog_Result]
                SET [PvsStatus] = 'NOT_APPLICABLE'
                WHERE [IsAdrEnabled] = 0 AND [PvsStatus] = 'PENDING';
            END TRY
            BEGIN CATCH
                INSERT [#CurrentLog_Errors] VALUES(NULL, 'ADR_PVS',
                    CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                    ERROR_NUMBER(), ERROR_MESSAGE());
                UPDATE [#CurrentLog_Result]
                SET [PvsStatus] = CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END
                WHERE [PvsStatus] = 'PENDING';
                SET @IsPartial = 1;
            END CATCH;
        END;

        DELETE FROM [#CurrentLog_Result]
        WHERE @MinUsedPercent IS NOT NULL
          AND COALESCE([UsedLogPercent], -1) < @MinUsedPercent;

        SELECT @CandidateRowCount = COUNT_BIG(*) FROM [#CurrentLog_Result];
        SET @HasMoreRows = CONVERT(bit, CASE WHEN @CandidateRowCount > @EffectiveMaxZeilen THEN 1 ELSE 0 END);
        SET @RowCount = CASE WHEN @CandidateRowCount > @EffectiveMaxZeilen THEN @EffectiveMaxZeilen ELSE @CandidateRowCount END;

        IF EXISTS(SELECT 1 FROM [#CurrentLog_Errors]) OR EXISTS(SELECT 1 FROM [#CurrentLog_DatabaseCandidateWarnings]) OR @VlfStatus = 'DENIED_GROUP'
        BEGIN
            SET @StatusCode = CASE WHEN @RowCount > 0 THEN 'PARTIAL_RESULT' ELSE 'ERROR_HANDLED' END;
            SET @IsPartial = 1;
        END;

        SET @Detail = CONCAT
        (
              N'Datenbanken=', (SELECT COUNT(*) FROM [#CurrentLog_DatabaseCandidates])
            , N'; Ergebniszeilen=', @RowCount
            , N'; Fehler=', (SELECT COUNT(*) FROM [#CurrentLog_Errors])
            , N'; nicht verfügbare explizite Datenbanken=', (SELECT COUNT(*) FROM [#CurrentLog_DatabaseCandidateWarnings])
            , N'; VLF=', CASE WHEN @MitVlfInformationen = 0 THEN N'aus' ELSE @VlfStatus END
            , N'.'
        );
    END;

    IF @StatusCode <> 'AVAILABLE' AND @PrintMeldungen = 1
    BEGIN
        SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_CurrentLog %s: %s', @StatusCode, COALESCE(@ErrorMessage, @Detail));
        RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @JsonMeta nvarchar(max) =
        (
            SELECT
                  N'CurrentLog' AS [resultName]
                , 1 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @IsPartial AS [isPartial]
                , @MaxZeilen AS [requestedMaxRows]
                , @RowCount AS [returnedRows]
                , @HasMoreRows AS [resultLimited]
                , @HasMoreRows AS [hasMoreRows]
                , @RequiredPermission AS [requiredPermission]
                , @ErrorNumber AS [errorNumber]
                , @ErrorMessage AS [errorMessage]
                , @Detail AS [detail]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @JsonLogs nvarchar(max) =
        (
            SELECT TOP (@EffectiveMaxZeilen) [r].*
            FROM [#CurrentLog_Result] AS [r]
            ORDER BY [r].[UsedLogPercent] DESC, [r].[DatabaseName]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        DECLARE @JsonStatus nvarchar(max) =
        (
            SELECT [DatabaseName], [SubModule], [StatusCode], [ErrorNumber], [ErrorMessage]
            FROM [#CurrentLog_Errors]
            ORDER BY [DatabaseName], [SubModule]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        DECLARE @JsonWarnings nvarchar(max) =
        (
            SELECT [RequestedName] AS [databaseName], [StatusCode] AS [code], [ErrorMessage] AS [message]
            FROM [#CurrentLog_DatabaseCandidateWarnings]
            ORDER BY [RequestedName]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@JsonMeta, N'{}')
            , N',"logs":', COALESCE(@JsonLogs, N'[]')
            , N',"databaseStatus":', COALESCE(@JsonStatus, N'[]')
            , N',"warnings":', COALESCE(@JsonWarnings, N'[]')
            , N'}'
        );
    END;

    IF @ResultSetArtNormalisiert = 'RAW'
    BEGIN
        SELECT
              N'USP_CurrentLog' AS [ModuleName]
            , @CollectionTimeUtc AS [CollectionTimeUtc]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , @RowCount AS [RowCount]
            , @HasMoreRows AS [ResultLimited]
            , @RequiredPermission AS [RequiredPermission]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage]
            , @Detail AS [Detail];

        SELECT TOP (@EffectiveMaxZeilen) [r].*
        FROM [#CurrentLog_Result] AS [r]
        ORDER BY [r].[UsedLogPercent] DESC, [r].[DatabaseName];

        SELECT [DatabaseName], [SubModule], [StatusCode], [ErrorNumber], [ErrorMessage]
        FROM [#CurrentLog_Errors]
        ORDER BY [DatabaseName], [SubModule];
    END
    ELSE IF @ResultSetArtNormalisiert = 'CONSOLE'
    BEGIN
        SELECT
              N'Transaktionslog-Analyse' AS [Ergebnis]
            , @CollectionTimeUtc AS [Stand_UTC]
            , @StatusCode AS [Status]
            , @RowCount AS [Zeilen]
            , @HasMoreRows AS [Ergebnis_begrenzt]
            , @Detail AS [Hinweis];

        SELECT TOP (@EffectiveMaxZeilen)
              N'Transaktionslog' AS [Ergebnis]
            , [r].[DatabaseName] AS [Datenbank]
            , [r].[RecoveryModel] AS [Recovery_Model]
            , [r].[LogReuseWaitDesc] AS [Log_Reuse_Wait]
            , CONCAT(CONVERT(varchar(40), [r].[TotalLogSizeMb]), N' MB') AS [Loggröße]
            , CONCAT(CONVERT(varchar(40), [r].[UsedLogSizeMb]), N' MB') AS [Verwendet]
            , CONCAT(CONVERT(varchar(40), [r].[UsedLogPercent]), N' %') AS [Verwendet_Prozent]
            , [r].[LogTruncationHoldupReason] AS [Truncation_Holdup]
            , [r].[ActiveVlfCount] AS [Aktive_VLF]
            , [r].[TotalVlfCount] AS [VLF_Gesamt]
            , CASE WHEN [r].[PersistentVersionStoreMb] IS NULL THEN NULL
                   ELSE CONCAT(CONVERT(varchar(40), [r].[PersistentVersionStoreMb]), N' MB') END AS [Persistent_Version_Store]
            , [r].[SpaceStatus] AS [Space_Status]
            , [r].[StatsStatus] AS [Stats_Status]
            , [r].[VlfStatus] AS [VLF_Status]
            , [r].[PvsStatus] AS [PVS_Status]
        FROM [#CurrentLog_Result] AS [r]
        ORDER BY [r].[UsedLogPercent] DESC, [r].[DatabaseName];

        SELECT
              N'Datenbank-/Teilmodulwarnung' AS [Ergebnis]
            , [DatabaseName] AS [Datenbank]
            , [SubModule] AS [Teilmodul]
            , [StatusCode] AS [Status]
            , [ErrorNumber] AS [Fehlernummer]
            , [ErrorMessage] AS [Fehlermeldung]
        FROM [#CurrentLog_Errors]
        ORDER BY [DatabaseName], [SubModule];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CurrentLog_Result'
            , @ResultLabel=N'Transaktionsprotokolle'
            , @EmptyMessage=N'Keine Protokollergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#CurrentLog_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
