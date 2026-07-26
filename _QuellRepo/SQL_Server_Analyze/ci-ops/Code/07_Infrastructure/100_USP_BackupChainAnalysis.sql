USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_BackupChainAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Zweck        : Bewertet Backupketten und Wiederherstellbarkeitsevidenz aus msdb.
Datenquellen : msdb.dbo.backupset und msdb.dbo.restorehistory.
Methodik     : Prüft Full-/Differentialbasis, Log-LSN-Übergänge,
               Recovery-Fork-Wechsel, Prüfsummen, Schadensflags und Restorebeleg.
Grenzen      : msdb-Historie kann bereinigt oder unvollständig sein. Nur ein
               erfolgreicher Test-Restore beweist die Wiederherstellbarkeit.
Datenschutz  : Liest keine Medienpfade, Benutzernamen oder Backupinhalte.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_BackupChainAnalysis]
      @DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @HistoryDays                  int            = 35
    , @MitRestoreEvidence           bit            = 1
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'summary',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
                                 THEN CONVERT(bigint, 9223372036854775807)
                                 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_BackupChainAnalysis';
        PRINT N'Prüft ausschließlich msdb-Metadaten; Medienpfade und Benutzernamen werden nicht gelesen.';
        PRINT N'@DatabaseNames: bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken.';
        PRINT N'@HistoryDays begrenzt die Kettenevidenz; der letzte nicht-copy-only Full wird zusätzlich einbezogen.';
        PRINT N'Nur ein erfolgreicher Test-Restore beweist Wiederherstellbarkeit.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;

    CREATE TABLE [#BackupChainAnalysis_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL PRIMARY KEY
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
    CREATE TABLE [#BackupChainAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#BackupChainAnalysis_Backups]
    (
          [DatabaseName] sysname NOT NULL
        , [BackupSetId] int NOT NULL
        , [BackupType] char(1) NOT NULL
        , [BackupTypeDesc] nvarchar(40) NOT NULL
        , [BackupStartDate] datetime NULL
        , [BackupFinishDate] datetime NULL
        , [FirstLsn] numeric(25,0) NULL
        , [LastLsn] numeric(25,0) NULL
        , [CheckpointLsn] numeric(25,0) NULL
        , [DatabaseBackupLsn] numeric(25,0) NULL
        , [DifferentialBaseLsn] numeric(25,0) NULL
        , [FirstRecoveryForkGuid] uniqueidentifier NULL
        , [LastRecoveryForkGuid] uniqueidentifier NULL
        , [IsCopyOnly] bit NULL
        , [HasBackupChecksums] bit NULL
        , [IsDamaged] bit NULL
        , [IsEncrypted] bit NULL
        , [PreviousLogLastLsn] numeric(25,0) NULL
        , [LogGapDetected] bit NOT NULL DEFAULT (0)
    );
    CREATE TABLE [#BackupChainAnalysis_Summary]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [LatestFullFinish] datetime NULL
        , [LatestMatchingDifferentialFinish] datetime NULL
        , [LatestLogFinish] datetime NULL
        , [LogBackupCountInWindow] bigint NOT NULL
        , [LogGapCountInWindow] bigint NOT NULL
        , [RecoveryForkTransitionCount] bigint NOT NULL
        , [DamagedBackupCount] bigint NOT NULL
        , [BackupWithoutChecksumCount] bigint NOT NULL
        , [LatestRestoreDate] datetime NULL
        , [FindingCode] varchar(100) NOT NULL
        , [FindingSeverity] varchar(16) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    IF @HistoryDays < 1 OR @HistoryDays > 3650
       OR @MaxZeilen < 0 OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Datenbank-, Historien-, Zeilen- oder Ausgabeparameter.';
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
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#BackupChainAnalysis_DatabaseCandidates',@WarningTable=N'#BackupChainAnalysis_DatabaseCandidateWarnings';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            ;WITH [LatestFull] AS
            (
                SELECT [bs].[database_name], [bs].[backup_set_id] AS [BackupSetId],
                       ROW_NUMBER() OVER
                       (
                           PARTITION BY [bs].[database_name]
                           ORDER BY [bs].[backup_finish_date] DESC, [bs].[backup_set_id] DESC
                       ) AS [rn]
                FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
                JOIN [#BackupChainAnalysis_DatabaseCandidates] AS [c]
                  ON [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                   = [bs].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                WHERE [bs].[type] = 'D' AND [bs].[is_copy_only] = 0
            ),
            [Selected] AS
            (
                SELECT [bs].*
                FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
                JOIN [#BackupChainAnalysis_DatabaseCandidates] AS [c]
                  ON [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                   = [bs].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                LEFT JOIN [LatestFull] AS [f]
                  ON [f].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                   = [bs].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                 AND [f].[rn] = 1
                WHERE [bs].[type] IN ('D', 'I', 'L')
                  AND ([bs].[backup_finish_date] >= DATEADD(DAY, -@HistoryDays, GETDATE())
                       OR [bs].[backup_set_id] = [f].[BackupSetId])
            ),
            [WithPreviousLog] AS
            (
                SELECT [s].*,
                       CASE WHEN [s].[type] = 'L'
                            THEN LAG(CASE WHEN [s].[type] = 'L' THEN [s].[last_lsn] END)
                                 OVER (PARTITION BY [s].[database_name], [s].[type]
                                       ORDER BY [s].[backup_start_date], [s].[backup_set_id]) END AS [PreviousLogLastLsn]
                FROM [Selected] AS [s]
            )
            INSERT [#BackupChainAnalysis_Backups]
            (
                  [DatabaseName], [BackupSetId], [BackupType], [BackupTypeDesc]
                , [BackupStartDate], [BackupFinishDate], [FirstLsn], [LastLsn]
                , [CheckpointLsn], [DatabaseBackupLsn], [DifferentialBaseLsn]
                , [FirstRecoveryForkGuid], [LastRecoveryForkGuid]
                , [IsCopyOnly], [HasBackupChecksums], [IsDamaged], [IsEncrypted]
                , [PreviousLogLastLsn], [LogGapDetected]
            )
            SELECT
                  [database_name], [backup_set_id], [type]
                , CASE [type] WHEN 'D' THEN N'FULL' WHEN 'I' THEN N'DIFFERENTIAL' ELSE N'LOG' END
                , [backup_start_date], [backup_finish_date], [first_lsn], [last_lsn]
                , [checkpoint_lsn], [database_backup_lsn], [differential_base_lsn]
                , [first_recovery_fork_guid], [last_recovery_fork_guid]
                , [is_copy_only], [has_backup_checksums], [is_damaged]
                , CONVERT(bit, CASE WHEN [key_algorithm] IS NULL THEN 0 ELSE 1 END)
                , [PreviousLogLastLsn]
                , CONVERT(bit, CASE WHEN [type] = 'L' AND [PreviousLogLastLsn] IS NOT NULL
                                      AND [first_lsn] > [PreviousLogLastLsn] THEN 1 ELSE 0 END)
            FROM [WithPreviousLog];

            ;WITH [LatestFull] AS
            (
                SELECT [b].*, ROW_NUMBER() OVER
                       (PARTITION BY [DatabaseName] ORDER BY [BackupFinishDate] DESC, [BackupSetId] DESC) AS [rn]
                FROM [#BackupChainAnalysis_Backups] AS [b]
                WHERE [BackupType] = 'D' AND [IsCopyOnly] = 0
            ),
            [LatestMatchingDiff] AS
            (
                SELECT [d].[DatabaseName], MAX([d].[BackupFinishDate]) AS [FinishDate]
                FROM [#BackupChainAnalysis_Backups] AS [d]
                JOIN [LatestFull] AS [f]
                  ON [f].[DatabaseName] = [d].[DatabaseName] AND [f].[rn] = 1
                 AND [d].[DifferentialBaseLsn] = [f].[CheckpointLsn]
                WHERE [d].[BackupType] = 'I'
                  AND [d].[BackupFinishDate] >= [f].[BackupFinishDate]
                GROUP BY [d].[DatabaseName]
            ),
            [Forks] AS
            (
                SELECT [x].[DatabaseName],
                       SUM(CONVERT(bigint, CASE WHEN [x].[PreviousFork] IS NOT NULL
                                                AND [x].[LastRecoveryForkGuid] <> [x].[PreviousFork]
                                               THEN 1 ELSE 0 END)) AS [Transitions]
                FROM
                (
                    SELECT [b].[DatabaseName], [b].[LastRecoveryForkGuid],
                           LAG([b].[LastRecoveryForkGuid]) OVER
                           (PARTITION BY [b].[DatabaseName]
                            ORDER BY [b].[BackupStartDate], [b].[BackupSetId]) AS [PreviousFork]
                    FROM [#BackupChainAnalysis_Backups] AS [b]
                ) AS [x]
                GROUP BY [x].[DatabaseName]
            ),
            [RestoreEvidence] AS
            (
                SELECT [rh].[destination_database_name] AS [DatabaseName],
                       MAX([rh].[restore_date]) AS [LatestRestoreDate]
                FROM [msdb].[dbo].[restorehistory] AS [rh] WITH (NOLOCK)
                JOIN [#BackupChainAnalysis_DatabaseCandidates] AS [c]
                  ON [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                   = [rh].[destination_database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                WHERE @MitRestoreEvidence = 1
                GROUP BY [rh].[destination_database_name]
            ),
            [Aggregated] AS
            (
                SELECT [c].[DatabaseId], [c].[DatabaseName], [c].[RecoveryModelDesc],
                       MAX(CASE WHEN [f].[rn] = 1 THEN [f].[BackupFinishDate] END) AS [LatestFullFinish],
                       MAX([d].[FinishDate]) AS [LatestDiffFinish],
                       MAX(CASE WHEN [b].[BackupType] = 'L' THEN [b].[BackupFinishDate] END) AS [LatestLogFinish],
                       SUM(CONVERT(bigint, CASE WHEN [b].[BackupType] = 'L' THEN 1 ELSE 0 END)) AS [LogCount],
                       SUM(CONVERT(bigint, CASE WHEN [b].[LogGapDetected] = 1 THEN 1 ELSE 0 END)) AS [GapCount],
                       MAX(COALESCE([k].[Transitions], 0)) AS [ForkTransitions],
                       SUM(CONVERT(bigint, CASE WHEN [b].[IsDamaged] = 1 THEN 1 ELSE 0 END)) AS [DamagedCount],
                       SUM(CONVERT(bigint, CASE WHEN [b].[BackupSetId] IS NOT NULL
                                                AND COALESCE([b].[HasBackupChecksums], 0) = 0
                                               THEN 1 ELSE 0 END)) AS [NoChecksumCount],
                       MAX([r].[LatestRestoreDate]) AS [LatestRestoreDate]
                FROM [#BackupChainAnalysis_DatabaseCandidates] AS [c]
                LEFT JOIN [#BackupChainAnalysis_Backups] AS [b] ON [b].[DatabaseName] = [c].[DatabaseName]
                LEFT JOIN [LatestFull] AS [f] ON [f].[DatabaseName] = [c].[DatabaseName] AND [f].[rn] = 1
                LEFT JOIN [LatestMatchingDiff] AS [d] ON [d].[DatabaseName] = [c].[DatabaseName]
                LEFT JOIN [Forks] AS [k] ON [k].[DatabaseName] = [c].[DatabaseName]
                LEFT JOIN [RestoreEvidence] AS [r] ON [r].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                                                   = [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                GROUP BY [c].[DatabaseId], [c].[DatabaseName], [c].[RecoveryModelDesc]
            )
            INSERT [#BackupChainAnalysis_Summary]
            SELECT
                  [DatabaseId], [DatabaseName], [RecoveryModelDesc]
                , [LatestFullFinish], [LatestDiffFinish], [LatestLogFinish]
                , COALESCE([LogCount], 0), COALESCE([GapCount], 0), COALESCE([ForkTransitions], 0)
                , COALESCE([DamagedCount], 0), COALESCE([NoChecksumCount], 0), [LatestRestoreDate]
                , CASE WHEN [DatabaseId] = 2 THEN 'TEMPDB_NOT_APPLICABLE'
                       WHEN [LatestFullFinish] IS NULL THEN 'FULL_BACKUP_EVIDENCE_MISSING'
                       WHEN [DamagedCount] > 0 THEN 'DAMAGED_BACKUP_METADATA'
                       WHEN [GapCount] > 0 THEN 'LOG_CHAIN_GAP_IN_VISIBLE_HISTORY'
                       WHEN [RecoveryModelDesc] IN (N'FULL', N'BULK_LOGGED') AND [LatestLogFinish] IS NULL
                            THEN 'LOG_BACKUP_EVIDENCE_MISSING'
                       WHEN [NoChecksumCount] > 0 THEN 'BACKUP_WITHOUT_CHECKSUM_IN_VISIBLE_HISTORY'
                       WHEN @MitRestoreEvidence = 1 AND [LatestRestoreDate] IS NULL THEN 'RESTORE_EVIDENCE_MISSING'
                       ELSE 'CHAIN_METADATA_CONSISTENT' END
                , CASE WHEN [DatabaseId] = 2 THEN 'INFO'
                       WHEN [LatestFullFinish] IS NULL OR [DamagedCount] > 0 OR [GapCount] > 0 THEN 'HIGH'
                       WHEN ([RecoveryModelDesc] IN (N'FULL', N'BULK_LOGGED') AND [LatestLogFinish] IS NULL)
                         OR [NoChecksumCount] > 0 THEN 'MEDIUM' ELSE 'INFO' END
                , CONCAT(N'msdb-Sichtfenster ', @HistoryDays,
                         N' Tage; bereinigte Historie kann scheinbare Lücken erzeugen. Test-Restore bleibt erforderlich.')
            FROM [Aggregated];

            IF EXISTS (SELECT 1 FROM [#BackupChainAnalysis_DatabaseCandidateWarnings])
                SELECT @StatusCode = 'AVAILABLE_LIMITED', @IsPartial = 1;
            ELSE IF EXISTS
                    (SELECT 1 FROM [#BackupChainAnalysis_Summary]
                     WHERE [FindingCode] NOT IN ('CHAIN_METADATA_CONSISTENT', 'TEMPDB_NOT_APPLICABLE'))
                SET @StatusCode = 'AVAILABLE_WITH_FINDING';
        END TRY
        BEGIN CATCH
            SELECT @StatusCode = CASE WHEN ERROR_NUMBER() IN (229, 371, 916)
                                      THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                   @IsPartial = 1, @ErrorNumber = ERROR_NUMBER(), @ErrorMessage = ERROR_MESSAGE();
        END CATCH;
    END;

    SELECT @StatusCodeOut = @StatusCode, @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber, @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
            (SELECT N'BackupChainAnalysis' AS [resultName], 1 AS [schemaVersion],
                    @Now AS [generatedAtUtc], @StatusCode AS [statusCode], @IsPartial AS [isPartial],
                    @HistoryDays AS [historyDays]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @SummaryJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#BackupChainAnalysis_Summary] ORDER BY [DatabaseId]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @BackupJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#BackupChainAnalysis_Backups]
             ORDER BY [BackupFinishDate] DESC, [BackupSetId] DESC
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningJson nvarchar(max) =
            (SELECT * FROM [#BackupChainAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'),
                           N',"summary":', COALESCE(@SummaryJson, N'[]'),
                           N',"backups":', COALESCE(@BackupJson, N'[]'),
                           N',"warnings":', COALESCE(@WarningJson, N'[]'), N'}');
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_BackupChainAnalysis' AS [ModuleName], @Now AS [CollectionTimeUtc],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial], @HistoryDays AS [HistoryDays],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'msdb-Metadaten; Test-Restore erforderlich.' AS [Detail];
        SELECT TOP (@Limit) * FROM [#BackupChainAnalysis_Summary] ORDER BY [DatabaseId];
        SELECT TOP (@Limit) * FROM [#BackupChainAnalysis_Backups]
        ORDER BY [BackupFinishDate] DESC, [BackupSetId] DESC;
        SELECT * FROM [#BackupChainAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName];
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Backupketten' AS [Ergebnis], @Now AS [Stand_UTC], @StatusCode AS [Status],
               @HistoryDays AS [Historie_Tage], @ErrorMessage AS [Hinweis];
        SELECT TOP (@Limit) N'Wiederherstellbarkeitsevidenz' AS [Ergebnis],
               [DatabaseName] AS [Datenbank], [RecoveryModelDesc] AS [Recovery_Model],
               [LatestFullFinish] AS [Letztes_Full],
               [LatestMatchingDifferentialFinish] AS [Passendes_Differential],
               [LatestLogFinish] AS [Letztes_Log], [LogGapCountInWindow] AS [Log_Luecken],
               [RecoveryForkTransitionCount] AS [Fork_Wechsel],
               [DamagedBackupCount] AS [Beschaedigte_Backups],
               [BackupWithoutChecksumCount] AS [Ohne_Checksum],
               [LatestRestoreDate] AS [Letzter_Restorebeleg],
               [FindingCode] AS [Befund], [FindingSeverity] AS [Prioritaet], [EvidenceLimit] AS [Grenze]
        FROM [#BackupChainAnalysis_Summary]
        ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END, [DatabaseId];
        SELECT N'Backupketten-Warnung' AS [Ergebnis], [RequestedName] AS [Datenbank],
               [StatusCode] AS [Status], [ErrorMessage] AS [Meldung]
        FROM [#BackupChainAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#BackupChainAnalysis_Summary'
            , @ResultLabel=N'BackupChainAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#BackupChainAnalysis_Summary'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
