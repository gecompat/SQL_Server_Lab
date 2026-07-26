USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_BackupRecovery
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Bewertet Backup-Aktualität und Restore-Historie je ausgewählter
               sichtbarer Datenbank.
SQL-Version  : SQL Server 2019 oder neuer.
Filter       : @DatabaseNames als bracket-aware Pipe-Liste oder alternativ
               @DatabaseNamePattern mit LIKE/regex/regexi.
Resultsets   : RAW oder CONSOLE: Modulstatus, Datenbankstatus, Backup-Aktualität,
               Backup-Historie und Restore-Historie. NONE: keine Resultsets.
JSON         : meta, databaseStatus, freshness, backups, restores, warnings.
Änderungen   : 2.0.0 - Mehrfachfilter, Patternvertrag und Ausgabeadapter.
               1.0.0 - Erstfassung Phase 6.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_BackupRecovery]
      @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @FullWarnHours                  int            = 48
    , @DiffWarnHours                  int            = 24
    , @LogWarnMinutes                 int            = 30
    , @MitRestoreHistory              bit            = 1
    , @MaxZeilen                      int            = 5000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @Json = NULL;

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'freshness',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_BackupRecovery';
        PRINT N'@DatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken.';
        PRINT N'@DatabaseNamePattern: alternatives LIKE-/Regex-Pattern; Liste und Pattern sind gegenseitig exklusiv.';
        PRINT N'Die Datenbankauswahl wird nicht vorab begrenzt.';
        PRINT N'@FullWarnHours=48; @DiffWarnHours=24; @LogWarnMinutes=30; @MitRestoreHistory=1.';
        PRINT N'@MaxZeilen: positive Werte begrenzen; NULL/0 = unbegrenzt.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE case-insensitiv; @JsonErzeugen=1 setzt @Json OUTPUT.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;

    CREATE TABLE [#BackupRecovery_DatabaseCandidates]
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

    CREATE TABLE [#BackupRecovery_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    CREATE TABLE [#BackupRecovery_Fresh]
    (
          [DatabaseName] sysname
        , [StateDesc] nvarchar(60)
        , [RecoveryModelDesc] nvarchar(60)
        , [LastFullFinish] datetime
        , [FullAgeMinutes] int
        , [LastDiffFinish] datetime
        , [DiffAgeMinutes] int
        , [LastLogFinish] datetime
        , [LogAgeMinutes] int
        , [LastCopyOnlyFullFinish] datetime
        , [BackupStatus] varchar(100)
    );

    CREATE TABLE [#BackupRecovery_Backups]
    (
          [DatabaseName] sysname
        , [BackupType] char(1)
        , [BackupTypeDesc] nvarchar(60)
        , [BackupStartDate] datetime
        , [BackupFinishDate] datetime
        , [DurationSeconds] int
        , [BackupSizeMb] decimal(19,2)
        , [CompressedSizeMb] decimal(19,2)
        , [IsCopyOnly] bit
        , [IsSnapshot] bit
        , [HasBackupChecksums] bit
        , [IsDamaged] bit
        , [MediaPath] nvarchar(4000)
    );

    CREATE TABLE [#BackupRecovery_Restores]
    (
          [DestinationDatabaseName] sysname
        , [RestoreDate] datetime
        , [UserName] sysname
        , [RestoreType] char(1)
        , [Replace] bit
        , [Recovery] bit
        , [Restart] bit
        , [SourceDatabaseName] sysname
        , [BackupFinishDate] datetime
    );

    IF @MaxZeilen < 0

       OR @FullWarnHours < 1
       OR @DiffWarnHours < 1
       OR @LogWarnMinutes < 1
       OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @IsPartial = 1;
        SET @ErrorMessage = N'Ungültige Grenzwert- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = NULL
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#BackupRecovery_DatabaseCandidates',@WarningTable=N'#BackupRecovery_DatabaseCandidateWarnings';
    END;

    IF @StatusCode <> 'AVAILABLE'
        SET @IsPartial = 1;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN TRY
        ;WITH [LastBackups] AS
        (
            SELECT
                  [bs].[database_name]
                , MAX(CASE WHEN [bs].[type] = 'D' AND [bs].[is_copy_only] = 0 THEN [bs].[backup_finish_date] END) AS [FullFinish]
                , MAX(CASE WHEN [bs].[type] = 'I' THEN [bs].[backup_finish_date] END) AS [DiffFinish]
                , MAX(CASE WHEN [bs].[type] = 'L' THEN [bs].[backup_finish_date] END) AS [LogFinish]
                , MAX(CASE WHEN [bs].[type] = 'D' AND [bs].[is_copy_only] = 1 THEN [bs].[backup_finish_date] END) AS [CopyOnlyFinish]
            FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
            JOIN [#BackupRecovery_DatabaseCandidates] AS [c]
              ON [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
               = [bs].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
            GROUP BY [bs].[database_name]
        )
        INSERT [#BackupRecovery_Fresh]
        SELECT
              [c].[DatabaseName]
            , [c].[StateDesc]
            , [c].[RecoveryModelDesc]
            , [x].[FullFinish]
            , DATEDIFF(MINUTE, [x].[FullFinish], GETDATE())
            , [x].[DiffFinish]
            , DATEDIFF(MINUTE, [x].[DiffFinish], GETDATE())
            , [x].[LogFinish]
            , DATEDIFF(MINUTE, [x].[LogFinish], GETDATE())
            , [x].[CopyOnlyFinish]
            , CASE
                  WHEN [c].[DatabaseId] = 2 THEN 'TEMPDB_NO_BACKUP'
                  WHEN [x].[FullFinish] IS NULL THEN 'NO_FULL_BACKUP'
                  WHEN DATEDIFF(HOUR, [x].[FullFinish], GETDATE()) > @FullWarnHours THEN 'FULL_TOO_OLD'
                  WHEN [c].[RecoveryModelDesc] IN (N'FULL', N'BULK_LOGGED') AND [x].[LogFinish] IS NULL THEN 'NO_LOG_BACKUP'
                  WHEN [c].[RecoveryModelDesc] IN (N'FULL', N'BULK_LOGGED')
                   AND DATEDIFF(MINUTE, [x].[LogFinish], GETDATE()) > @LogWarnMinutes THEN 'LOG_TOO_OLD'
                  WHEN [x].[DiffFinish] IS NOT NULL
                   AND DATEDIFF(HOUR, [x].[DiffFinish], GETDATE()) > @DiffWarnHours THEN 'DIFF_OLD_INFORMATIONAL'
                  ELSE 'OK'
              END
        FROM [#BackupRecovery_DatabaseCandidates] AS [c]
        LEFT JOIN [LastBackups] AS [x]
          ON [x].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
           = [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS;

        INSERT [#BackupRecovery_Backups]
        SELECT TOP (@EffectiveMaxZeilen)
              [bs].[database_name]
            , [bs].[type]
            , CASE [bs].[type] WHEN 'D' THEN N'DATABASE' WHEN 'I' THEN N'DIFFERENTIAL'
                   WHEN 'L' THEN N'LOG' WHEN 'F' THEN N'FILE_OR_FILEGROUP'
                   WHEN 'G' THEN N'DIFF_FILE' WHEN 'P' THEN N'PARTIAL'
                   WHEN 'Q' THEN N'DIFF_PARTIAL' END
            , [bs].[backup_start_date]
            , [bs].[backup_finish_date]
            , DATEDIFF(SECOND, [bs].[backup_start_date], [bs].[backup_finish_date])
            , CONVERT(decimal(19,2), [bs].[backup_size] / 1048576.0)
            , CONVERT(decimal(19,2), [bs].[compressed_backup_size] / 1048576.0)
            , [bs].[is_copy_only]
            , CAST(NULL AS bit)
            , [bs].[has_backup_checksums]
            , [bs].[is_damaged]
            , [bmf].[physical_device_name]
        FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
        JOIN [#BackupRecovery_DatabaseCandidates] AS [c]
          ON [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
           = [bs].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
        LEFT JOIN [msdb].[dbo].[backupmediafamily] AS [bmf] WITH (NOLOCK)
          ON [bmf].[media_set_id] = [bs].[media_set_id]
        ORDER BY [bs].[backup_finish_date] DESC, [bs].[backup_set_id] DESC;

        IF @MitRestoreHistory = 1
        BEGIN
            INSERT [#BackupRecovery_Restores]
            SELECT TOP (@EffectiveMaxZeilen)
                  [rh].[destination_database_name]
                , [rh].[restore_date]
                , [rh].[user_name]
                , [rh].[restore_type]
                , [rh].[replace]
                , [rh].[recovery]
                , [rh].[restart]
                , [bs].[database_name]
                , [bs].[backup_finish_date]
            FROM [msdb].[dbo].[restorehistory] AS [rh] WITH (NOLOCK)
            JOIN [#BackupRecovery_DatabaseCandidates] AS [c]
              ON [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
               = [rh].[destination_database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
            LEFT JOIN [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
              ON [bs].[backup_set_id] = [rh].[backup_set_id]
            ORDER BY [rh].[restore_date] DESC, [rh].[restore_history_id] DESC;
        END;

        IF EXISTS (SELECT 1 FROM [#BackupRecovery_DatabaseCandidateWarnings])
        BEGIN
            SET @StatusCode = 'AVAILABLE_LIMITED';
            SET @IsPartial = 1;
        END;
    END TRY
    BEGIN CATCH
        SELECT
              @StatusCode = 'ERROR_HANDLED'
            , @IsPartial = 1
            , @ErrorNumber = ERROR_NUMBER()
            , @ErrorMessage = ERROR_MESSAGE();

        IF @PrintMeldungen = 1
            RAISERROR(N'Backup-/Restore-Historie konnte nicht vollständig gelesen werden: %s', 10, 1, @ErrorMessage) WITH NOWAIT;
    END CATCH;

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        SELECT
              @CollectionTimeUtc AS [CollectionTimeUtc]
            , CAST(N'monitor.USP_BackupRecovery' AS nvarchar(256)) AS [ModuleName]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage];

        SELECT
              [RequestedName], [StatusCode], [ErrorMessage]
        FROM [#BackupRecovery_DatabaseCandidateWarnings]
        ORDER BY [RequestedName];

        IF @ResultSetArtNormalisiert = 'RAW'
        BEGIN
            SELECT * FROM [#BackupRecovery_Fresh] ORDER BY CASE WHEN [BackupStatus] = 'OK' THEN 1 ELSE 0 END, [DatabaseName];
            SELECT * FROM [#BackupRecovery_Backups] ORDER BY [BackupFinishDate] DESC, [DatabaseName];
            SELECT * FROM [#BackupRecovery_Restores] ORDER BY [RestoreDate] DESC, [DestinationDatabaseName];
        END;
        ELSE
        BEGIN
            SELECT
                  N'Backup-Aktualität' AS [Ergebnis]
                , [DatabaseName] AS [Datenbank]
                , [RecoveryModelDesc] AS [Recovery Model]
                , [BackupStatus] AS [Bewertung]
                , [LastFullFinish] AS [Letztes Full]
                , CASE WHEN [FullAgeMinutes] IS NULL THEN NULL ELSE CONCAT([FullAgeMinutes], N' min') END AS [Full-Alter]
                , [LastDiffFinish] AS [Letztes Diff]
                , CASE WHEN [DiffAgeMinutes] IS NULL THEN NULL ELSE CONCAT([DiffAgeMinutes], N' min') END AS [Diff-Alter]
                , [LastLogFinish] AS [Letztes Log]
                , CASE WHEN [LogAgeMinutes] IS NULL THEN NULL ELSE CONCAT([LogAgeMinutes], N' min') END AS [Log-Alter]
            FROM [#BackupRecovery_Fresh]
            ORDER BY CASE WHEN [BackupStatus] = 'OK' THEN 1 ELSE 0 END, [DatabaseName];

            SELECT N'Backup-Historie' AS [Ergebnis], [x].* FROM [#BackupRecovery_Backups] AS [x] ORDER BY [BackupFinishDate] DESC, [DatabaseName];
            SELECT N'Restore-Historie' AS [Ergebnis], [x].* FROM [#BackupRecovery_Restores] AS [x] ORDER BY [RestoreDate] DESC, [DestinationDatabaseName];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  N'BackupRecovery' AS [resultName]
                , 1 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @IsPartial AS [isPartial]
                , @MaxZeilen AS [requestedMaxRows]
                , @ErrorNumber AS [errorNumber]
                , @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @FreshJson nvarchar(max) =
            (SELECT * FROM [#BackupRecovery_Fresh] ORDER BY CASE WHEN [BackupStatus] = 'OK' THEN 1 ELSE 0 END, [DatabaseName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @BackupsJson nvarchar(max) =
            (SELECT * FROM [#BackupRecovery_Backups] ORDER BY [BackupFinishDate] DESC, [DatabaseName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @RestoresJson nvarchar(max) =
            (SELECT * FROM [#BackupRecovery_Restores] ORDER BY [RestoreDate] DESC, [DestinationDatabaseName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT * FROM [#BackupRecovery_DatabaseCandidateWarnings] ORDER BY [RequestedName] FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"freshness":', COALESCE(@FreshJson, N'[]')
            , N',"backups":', COALESCE(@BackupsJson, N'[]')
            , N',"restores":', COALESCE(@RestoresJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#BackupRecovery_Fresh'
            , @ResultLabel=N'BackupRecovery'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#BackupRecovery_Fresh'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
