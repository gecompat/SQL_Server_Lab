USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_DataCaptureStatus
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Inventarisiert CDC und Change Tracking für eine bracket-aware
               Datenbankliste oder alle zulässigen Datenbanken.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : master.sys.databases, sys.change_tracking_databases,
               database-lokale sys.tables/sys.schemas/
               sys.change_tracking_tables/cdc.change_tables, msdb CDC-Jobs.
Parameter    : @DatabaseNames, @DatabaseNamePattern,
               @SystemdatenbankenEinbeziehen, @MaxZeilen,
               @ResultSetArt, @JsonErzeugen, @Json OUTPUT,
               @PrintMeldungen, @Hilfe.
Semantik     : @DatabaseNames=N'[Db1]|[Db2]'; NULL=alle zulässigen
               Datenbanken; N''=INVALID_PARAMETER. Exakte Liste und Pattern
               sind exklusiv. Die Datenbankauswahl wird nicht vorab begrenzt.
Ausgabe      : RAW/CONSOLE/NONE; JSON mit meta, databases, cdcTables,
               changeTrackingTables, cdcJobs und warnings.
Berechtigung : Cross-Database wird über CROSS_DATABASE_DEEP geprüft.
Eigenlast    : Mittel; lokale Kandidaten werden je Datenbank auf N+1 begrenzt,
               anschließend erfolgt ein globales TOP je fachlichem Resultset.
Locking      : LOCK_TIMEOUT 0; Systemkataloge READUNCOMMITTED.
Änderungen   : 2.0.0 - @AlleDatenbanken entfernt; Listen-/Patternvertrag,
                         globale Mengenbegrenzung und Ausgabevertrag ergänzt.
               1.0.0 - Erstfassung Phase 6.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_DataCaptureStatus]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MaxZeilen                        int            = 10000
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
    SET LOCK_TIMEOUT 0;

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'databases',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807) WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen) ELSE CONVERT(bigint, 0) END;
    DECLARE @LocalCandidateRows bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807) WHEN @MaxZeilen BETWEEN 1 AND 2147483646 THEN CONVERT(bigint, @MaxZeilen) + 1 WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen) ELSE CONVERT(bigint, 0) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_DataCaptureStatus';
        PRINT N'@DatabaseNames=N''[Db1]|[Db2]''; NULL=alle; N'''' bedeutet keine Einschränkung.';
        PRINT N'@DatabaseNamePattern=like:...|regex:...|regexi:...; ein Pattern, keine Pipe-Liste.';
        PRINT N'Die Datenbankauswahl wird nicht vorab begrenzt; @MaxZeilen gilt global je fachlichem Resultset.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE (case-insensitiv); @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @Db sysname;
    DECLARE @Sql nvarchar(max);

    CREATE TABLE [#DataCaptureStatus_DatabaseCandidates]
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

    CREATE TABLE [#DataCaptureStatus_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );

    CREATE TABLE [#DataCaptureStatus_Db]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [IsCdcEnabled] bit NULL
        , [IsChangeTrackingEnabled] bit NULL
        , [RetentionPeriod] bigint NULL
        , [RetentionPeriodUnitsDesc] nvarchar(60) NULL
        , [IsAutoCleanupOn] bit NULL
        , [CurrentCtVersion] bigint NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    CREATE TABLE [#DataCaptureStatus_Cdc]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [CaptureInstance] sysname NULL
        , [SourceSchema] sysname NULL
        , [SourceTable] sysname NULL
        , [ObjectId] int NULL
        , [StartLsn] binary(10) NULL
        , [SupportsNetChanges] bit NULL
        , [RoleName] sysname NULL
        , [IndexName] sysname NULL
        , [CreateDate] datetime NULL
        , [PartitionSwitch] bit NULL
    );

    CREATE TABLE [#DataCaptureStatus_Ct]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [SchemaName] sysname NULL
        , [TableName] sysname NULL
        , [ObjectId] int NULL
        , [IsTrackColumnsUpdatedOn] bit NULL
        , [BeginVersion] bigint NULL
        , [CleanupVersion] bigint NULL
        , [MinValidVersion] bigint NULL
    );

    CREATE TABLE [#DataCaptureStatus_Jobs]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [JobType] nvarchar(20) NULL
        , [JobName] sysname NULL
        , [Enabled] bit NULL
        , [LastRunOutcome] int NULL
        , [LastRunDateTime] datetime NULL
        , [LastMessage] nvarchar(4000) NULL
    );

    CREATE TABLE [#DataCaptureStatus_Warnings]
    (
          [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [SourceName] varchar(40) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @MaxZeilen < 0 OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültige Mengen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = 'HA_DR_CURRENT'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#DataCaptureStatus_DatabaseCandidates',@WarningTable=N'#DataCaptureStatus_DatabaseCandidateWarnings';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [DatabaseName]
        FROM [#DataCaptureStatus_DatabaseCandidates]
        WHERE [DatabaseName] <> N'tempdb'
        ORDER BY COALESCE([RequestedOrdinal], [DatabaseId]), [DatabaseId];

        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @Db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
INSERT [#DataCaptureStatus_Db]
(
      [DatabaseName], [StateDesc], [IsCdcEnabled], [IsChangeTrackingEnabled]
    , [RetentionPeriod], [RetentionPeriodUnitsDesc], [IsAutoCleanupOn]
    , [CurrentCtVersion], [StatusCode], [ErrorMessage]
)
SELECT
      [d].[name]
    , [d].[state_desc]
    , [d].[is_cdc_enabled]
    , CONVERT(bit, CASE WHEN [ctd].[database_id] IS NULL THEN 0 ELSE 1 END)
    , [ctd].[retention_period]
    , [ctd].[retention_period_units_desc]
    , [ctd].[is_auto_cleanup_on]
    , CHANGE_TRACKING_CURRENT_VERSION()
    , ''AVAILABLE''
    , NULL
FROM [sys].[databases] AS [d] WITH (NOLOCK)
LEFT JOIN [sys].[change_tracking_databases] AS [ctd] WITH (NOLOCK)
  ON [ctd].[database_id] = [d].[database_id]
WHERE [d].[database_id] = DB_ID();

IF EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N''cdc'' AND [t].[name] = N''change_tables''
)
BEGIN
    EXEC(N''INSERT [#DataCaptureStatus_Cdc]
    SELECT TOP('' + CONVERT(nvarchar(30), @LocalRows) + N'')
          (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID())
        , [ct].[capture_instance]
        , [s].[name]
        , [t].[name]
        , [ct].[source_object_id]
        , [ct].[start_lsn]
        , [ct].[supports_net_changes]
        , [ct].[role_name]
        , [ct].[index_name]
        , [ct].[create_date]
        , [ct].[partition_switch]
    FROM [cdc].[change_tables] AS [ct] WITH (NOLOCK)
    LEFT JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [ct].[source_object_id]
    LEFT JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    ORDER BY [ct].[capture_instance];'');
END;

INSERT [#DataCaptureStatus_Ct]
SELECT TOP (@LocalRows)
      (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID())
    , [s].[name]
    , [t].[name]
    , [ct].[object_id]
    , [ct].[is_track_columns_updated_on]
    , [ct].[begin_version]
    , [ct].[cleanup_version]
    , CHANGE_TRACKING_MIN_VALID_VERSION([ct].[object_id])
FROM [sys].[change_tracking_tables] AS [ct] WITH (NOLOCK)
INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
  ON [t].[object_id] = [ct].[object_id]
INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [t].[schema_id]
ORDER BY [s].[name], [t].[name];';

                EXEC [sys].[sp_executesql]
                      @Sql
                    , N'@LocalRows bigint'
                    , @LocalRows = @LocalCandidateRows;

                INSERT [#DataCaptureStatus_Jobs]
                SELECT TOP (@LocalCandidateRows)
                      @Db
                    , CASE WHEN [j].[name] LIKE N'cdc.' + @Db + N'_capture%' THEN N'CAPTURE' ELSE N'CLEANUP' END
                    , [j].[name]
                    , [j].[enabled]
                    , [h].[run_status]
                    , CASE WHEN [h].[run_date] > 0 THEN [msdb].[dbo].[agent_datetime]([h].[run_date], [h].[run_time]) END
                    , [h].[message]
                FROM [msdb].[dbo].[sysjobs] AS [j] WITH (NOLOCK)
                OUTER APPLY
                (
                    SELECT TOP (1) [x].[run_status], [x].[run_date], [x].[run_time], [x].[message]
                    FROM [msdb].[dbo].[sysjobhistory] AS [x] WITH (NOLOCK)
                    WHERE [x].[job_id] = [j].[job_id] AND [x].[step_id] = 0
                    ORDER BY [x].[instance_id] DESC
                ) AS [h]
                WHERE [j].[name] LIKE N'cdc.' + @Db + N'[_]%'
                ORDER BY [j].[name];
            END TRY
            BEGIN CATCH
                INSERT [#DataCaptureStatus_Db] VALUES(@Db, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                    CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                         WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
                    ERROR_MESSAGE());
                INSERT [#DataCaptureStatus_Warnings] VALUES(@Db, 'DATABASE_CAPTURE',
                    CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                         WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
                    ERROR_NUMBER(), ERROR_MESSAGE());
                SET @IsPartial = 1;
            END CATCH;

            FETCH NEXT FROM [DatabaseCursor] INTO @Db;
        END;

        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];

        INSERT [#DataCaptureStatus_Warnings]([DatabaseName],[SourceName],[StatusCode],[ErrorNumber],[ErrorMessage])
        SELECT [RequestedName], 'DATABASE_SELECTION', [StatusCode], NULL, [ErrorMessage]
        FROM [#DataCaptureStatus_DatabaseCandidateWarnings];

        IF EXISTS(SELECT 1 FROM [#DataCaptureStatus_Warnings])
        BEGIN
            SET @StatusCode = CASE WHEN EXISTS(SELECT 1 FROM [#DataCaptureStatus_Db] WHERE [StatusCode] = 'AVAILABLE') THEN 'PARTIAL_RESULT' ELSE 'ERROR_HANDLED' END;
            SET @IsPartial = 1;
        END;
    END;

    IF @StatusCode <> 'AVAILABLE' AND @PrintMeldungen = 1
    BEGIN
        SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_DataCaptureStatus %s: %s', @StatusCode, COALESCE(@ErrorMessage, N'Teilergebnis.'));
        RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @JsonMeta nvarchar(max) =
        (
            SELECT N'DataCaptureStatus' AS [resultName], 1 AS [schemaVersion],
                   @CollectionTimeUtc AS [generatedAtUtc], @StatusCode AS [statusCode],
                   @IsPartial AS [isPartial], @MaxZeilen AS [requestedMaxRows],
                   @ErrorNumber AS [errorNumber], @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @JsonDb nvarchar(max) = (SELECT * FROM [#DataCaptureStatus_Db] ORDER BY [DatabaseName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @JsonCdc nvarchar(max) = (SELECT TOP (@EffectiveMaxZeilen) * FROM [#DataCaptureStatus_Cdc] ORDER BY [DatabaseName], [CaptureInstance] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @JsonCt nvarchar(max) = (SELECT TOP (@EffectiveMaxZeilen) * FROM [#DataCaptureStatus_Ct] ORDER BY [DatabaseName], [SchemaName], [TableName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @JsonJobs nvarchar(max) = (SELECT TOP (@EffectiveMaxZeilen) * FROM [#DataCaptureStatus_Jobs] ORDER BY [DatabaseName], [JobType], [JobName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @JsonWarnings nvarchar(max) = (SELECT * FROM [#DataCaptureStatus_Warnings] ORDER BY [DatabaseName], [SourceName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@JsonMeta,N'{}'), N',"databases":', COALESCE(@JsonDb,N'[]'), N',"cdcTables":', COALESCE(@JsonCdc,N'[]'), N',"changeTrackingTables":', COALESCE(@JsonCt,N'[]'), N',"cdcJobs":', COALESCE(@JsonJobs,N'[]'), N',"warnings":', COALESCE(@JsonWarnings,N'[]'), N'}');
    END;

    IF @ResultSetArtNormalisiert = 'RAW'
    BEGIN
        SELECT @CollectionTimeUtc AS [CollectionTimeUtc], N'monitor.USP_DataCaptureStatus' AS [ModuleName], @StatusCode AS [StatusCode], @IsPartial AS [IsPartial], @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage];
        SELECT * FROM [#DataCaptureStatus_Db] ORDER BY [DatabaseName];
        SELECT TOP (@EffectiveMaxZeilen) * FROM [#DataCaptureStatus_Cdc] ORDER BY [DatabaseName], [CaptureInstance];
        SELECT TOP (@EffectiveMaxZeilen) * FROM [#DataCaptureStatus_Ct] ORDER BY [DatabaseName], [SchemaName], [TableName];
        SELECT TOP (@EffectiveMaxZeilen) * FROM [#DataCaptureStatus_Jobs] ORDER BY [DatabaseName], [JobType], [JobName];
        SELECT * FROM [#DataCaptureStatus_Warnings] ORDER BY [DatabaseName], [SourceName];
    END
    ELSE IF @ResultSetArtNormalisiert = 'CONSOLE'
    BEGIN
        SELECT N'Data-Capture-Analyse' AS [Ergebnis], @CollectionTimeUtc AS [Stand_UTC], @StatusCode AS [Status], @IsPartial AS [Teilergebnis], @ErrorMessage AS [Hinweis];
        SELECT N'Datenbankstatus CDC/Change Tracking' AS [Ergebnis], [DatabaseName] AS [Datenbank], [IsCdcEnabled] AS [CDC_aktiv], [IsChangeTrackingEnabled] AS [Change_Tracking_aktiv], [RetentionPeriod] AS [Retention], [RetentionPeriodUnitsDesc] AS [Retention_Einheit], [IsAutoCleanupOn] AS [Auto_Cleanup], [CurrentCtVersion] AS [CT_Version], [StatusCode] AS [Status], [ErrorMessage] AS [Fehler] FROM [#DataCaptureStatus_Db] ORDER BY [DatabaseName];
        SELECT TOP (@EffectiveMaxZeilen) N'CDC-Tabelle' AS [Ergebnis], [DatabaseName] AS [Datenbank], [CaptureInstance] AS [Capture_Instance], [SourceSchema] AS [Schema], [SourceTable] AS [Tabelle], [SupportsNetChanges] AS [Net_Changes], [RoleName] AS [Rolle], [IndexName] AS [Index], [CreateDate] AS [Erstellt] FROM [#DataCaptureStatus_Cdc] ORDER BY [DatabaseName], [CaptureInstance];
        SELECT TOP (@EffectiveMaxZeilen) N'Change-Tracking-Tabelle' AS [Ergebnis], [DatabaseName] AS [Datenbank], [SchemaName] AS [Schema], [TableName] AS [Tabelle], [IsTrackColumnsUpdatedOn] AS [Spaltenänderungen_aufzeichnen], [BeginVersion] AS [Beginn_Version], [CleanupVersion] AS [Cleanup_Version], [MinValidVersion] AS [Min_gültige_Version] FROM [#DataCaptureStatus_Ct] ORDER BY [DatabaseName], [SchemaName], [TableName];
        SELECT TOP (@EffectiveMaxZeilen) N'CDC-Agentjob' AS [Ergebnis], [DatabaseName] AS [Datenbank], [JobType] AS [Job_Typ], [JobName] AS [Job], [Enabled] AS [Aktiv], [LastRunOutcome] AS [Letzter_Status], [LastRunDateTime] AS [Letzter_Lauf], [LastMessage] AS [Meldung] FROM [#DataCaptureStatus_Jobs] ORDER BY [DatabaseName], [JobType], [JobName];
        SELECT N'Data-Capture-Warnung' AS [Ergebnis], [DatabaseName] AS [Datenbank], [SourceName] AS [Quelle], [StatusCode] AS [Status], [ErrorNumber] AS [Fehlernummer], [ErrorMessage] AS [Fehlermeldung] FROM [#DataCaptureStatus_Warnings] ORDER BY [DatabaseName], [SourceName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#DataCaptureStatus_Db'
            , @ResultLabel=N'DataCaptureStatus'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#DataCaptureStatus_Db'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
