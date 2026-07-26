USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_DatabaseIntegrityAnalysis
Version      : 1.0.2
Stand        : 2026-07-18
Zweck        : Liefert korrelierte, rein lesende Integritätsevidenz je
               Datenbank.
Datenquellen : master.sys.databases, DATABASEPROPERTYEX,
               msdb.dbo.suspect_pages, msdb.dbo.backupset,
               sys.dm_hadr_auto_page_repair und optional sys.dm_db_page_info.
Grenzen      : Leere Indikatoren beweisen keine Integrität. Die Procedure führt
               weder DBCC CHECKDB noch Restore, Reparatur oder Konfiguration aus.
Kosten       : Metadaten LOW; gezielte Seitenauflösung MEDIUM und opt-in.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_DatabaseIntegrityAnalysis]
      @DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @CheckdbWarnHours             int            = 168
    , @BackupHistoryDays            int            = 35
    , @MitPageDetails               bit            = 0
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

    DECLARE @OutputMode varchar(16) =
        UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'integrity',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_DatabaseIntegrityAnalysis';
        PRINT N'Die Procedure liefert rein lesende Evidenz und führt weder DBCC CHECKDB noch Restore oder Reparatur aus.';
        PRINT N'@DatabaseNames: bracket-aware Pipe-Liste; N''''/NULL = keine Datenbankeinschränkung.';
        PRINT N'@CheckdbWarnHours=168; @MitPageDetails=0 löst verdächtige Seiten nicht auf.';
        PRINT N'@BackupHistoryDays=35 begrenzt die Backupmetadaten-Evidenz.';
        PRINT N'@MaxZeilen positiv; NULL/0 = unbegrenzt. @ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @MonitorPrintMessage nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @RequiredServerPermission sysname =
        CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
             THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END;
    DECLARE @HasRequiredServerPermission bit =
        CASE WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 1
             ELSE COALESCE(HAS_PERMS_BY_NAME(NULL, N'SERVER', @RequiredServerPermission), 0) END;

    CREATE TABLE [#DatabaseIntegrityAnalysis_DatabaseCandidates]
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

    CREATE TABLE [#DatabaseIntegrityAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    CREATE TABLE [#DatabaseIntegrityAnalysis_Suspect]
    (
          [DatabaseId] int NOT NULL
        , [FileId] int NOT NULL
        , [PageId] bigint NOT NULL
        , [EventType] int NOT NULL
        , [ErrorCount] int NULL
        , [LastUpdateDate] datetime NULL
    );

    CREATE TABLE [#DatabaseIntegrityAnalysis_HadrRepair]
    (
          [DatabaseId] int NOT NULL
        , [FileId] int NOT NULL
        , [PageId] bigint NOT NULL
        , [ErrorType] int NULL
        , [PageStatus] int NULL
        , [ModificationTime] datetime NULL
    );

    CREATE TABLE [#DatabaseIntegrityAnalysis_Integrity]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [PageVerifyOptionDesc] nvarchar(60) NULL
        , [LastGoodCheckDbTime] datetime2(3) NULL
        , [CheckdbAgeHours] bigint NULL
        , [SuspectPageCount] bigint NOT NULL
        , [LatestSuspectPageUtc] datetime NULL
        , [DamagedBackupCount] bigint NOT NULL
        , [BackupWithoutChecksumCount] bigint NOT NULL
        , [HadrPageRepairCount] bigint NOT NULL
        , [HadrPageRepairPendingCount] bigint NOT NULL
        , [FindingCode] varchar(80) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    CREATE TABLE [#DatabaseIntegrityAnalysis_PageDetails]
    (
          [DatabaseName] sysname NULL
        , [FileId] int NULL
        , [PageId] bigint NULL
        , [EventType] int NULL
        , [LastUpdateDate] datetime NULL
        , [ObjectId] int NULL
        , [IndexId] int NULL
        , [PartitionId] bigint NULL
        , [PageTypeDesc] nvarchar(64) NULL
        , [AllocUnitId] bigint NULL
    );

    IF @CheckdbWarnHours < 1
       OR @BackupHistoryDays < 1
       OR @BackupHistoryDays > 3650
       OR @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER',
               @IsPartial = 1,
               @ErrorMessage = N'Ungültige Datenbank-, Zeit-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
       AND @HasRequiredServerPermission = 0
    BEGIN
        SELECT @IsPartial = 1,
               @ErrorMessage = CONCAT(N'Für vollständige serverweite Integritätsevidenz fehlt ',
                                      @RequiredServerPermission, N'.');
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
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#DatabaseIntegrityAnalysis_DatabaseCandidates',@WarningTable=N'#DatabaseIntegrityAnalysis_DatabaseCandidateWarnings';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            INSERT [#DatabaseIntegrityAnalysis_Suspect]
            (
                  [DatabaseId], [FileId], [PageId], [EventType]
                , [ErrorCount], [LastUpdateDate]
            )
            SELECT
                  [sp].[database_id], [sp].[file_id], [sp].[page_id]
                , [sp].[event_type], [sp].[error_count], [sp].[last_update_date]
            FROM [msdb].[dbo].[suspect_pages] AS [sp] WITH (NOLOCK)
            JOIN [#DatabaseIntegrityAnalysis_DatabaseCandidates] AS [c]
              ON [c].[DatabaseId] = [sp].[database_id];
        END TRY
        BEGIN CATCH
            SELECT @IsPartial = 1,
                   @ErrorNumber = ERROR_NUMBER(),
                   @ErrorMessage = CONCAT(N'suspect_pages nicht lesbar: ', ERROR_MESSAGE());
        END CATCH;

        BEGIN TRY
            INSERT [#DatabaseIntegrityAnalysis_HadrRepair]
            (
                  [DatabaseId], [FileId], [PageId], [ErrorType]
                , [PageStatus], [ModificationTime]
            )
            SELECT
                  [r].[database_id], [r].[file_id], [r].[page_id]
                , [r].[error_type], [r].[page_status], [r].[modification_time]
            FROM [sys].[dm_hadr_auto_page_repair] AS [r] WITH (NOLOCK)
            JOIN [#DatabaseIntegrityAnalysis_DatabaseCandidates] AS [c]
              ON [c].[DatabaseId] = [r].[database_id];
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            IF @ErrorNumber IS NULL
            BEGIN
                SELECT @ErrorNumber = ERROR_NUMBER(),
                       @ErrorMessage = CONCAT(N'HADR-Seitenreparaturstatus nicht lesbar: ', ERROR_MESSAGE());
            END;
        END CATCH;

        BEGIN TRY
            ;WITH [BackupEvidence] AS
            (
                SELECT
                      [bs].[database_name]
                    , SUM(CONVERT(bigint, CASE WHEN [bs].[is_damaged] = 1 THEN 1 ELSE 0 END)) AS [DamagedCount]
                    , SUM(CONVERT(bigint, CASE WHEN COALESCE([bs].[has_backup_checksums], 0) = 0 THEN 1 ELSE 0 END)) AS [NoChecksumCount]
                FROM [msdb].[dbo].[backupset] AS [bs] WITH (NOLOCK)
                JOIN [#DatabaseIntegrityAnalysis_DatabaseCandidates] AS [c]
                  ON [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
                   = [bs].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                WHERE [bs].[backup_finish_date] >= DATEADD(DAY, -@BackupHistoryDays, GETDATE())
                GROUP BY [bs].[database_name]
            ),
            [SuspectEvidence] AS
            (
                SELECT [DatabaseId], COUNT_BIG(*) AS [PageCount],
                       MAX([LastUpdateDate]) AS [LatestDate]
                FROM [#DatabaseIntegrityAnalysis_Suspect]
                GROUP BY [DatabaseId]
            ),
            [RepairEvidence] AS
            (
                SELECT [DatabaseId], COUNT_BIG(*) AS [RepairCount],
                       SUM(CONVERT(bigint, CASE WHEN [PageStatus] <> 5 THEN 1 ELSE 0 END)) AS [PendingCount]
                FROM [#DatabaseIntegrityAnalysis_HadrRepair]
                GROUP BY [DatabaseId]
            )
            INSERT [#DatabaseIntegrityAnalysis_Integrity]
            SELECT
                  [c].[DatabaseId]
                , [c].[DatabaseName]
                , [c].[StateDesc]
                , [d].[page_verify_option_desc]
                , CONVERT(datetime2(3), NULL)
                , CONVERT(int, NULL)
                , COALESCE([s].[PageCount], 0)
                , [s].[LatestDate]
                , COALESCE([b].[DamagedCount], 0)
                , COALESCE([b].[NoChecksumCount], 0)
                , COALESCE([r].[RepairCount], 0)
                , COALESCE([r].[PendingCount], 0)
                , CASE
                      WHEN COALESCE([s].[PageCount], 0) > 0 THEN 'SUSPECT_PAGES_PRESENT'
                      WHEN COALESCE([b].[DamagedCount], 0) > 0 THEN 'DAMAGED_BACKUP_METADATA'
                      WHEN COALESCE([r].[PendingCount], 0) > 0 THEN 'HADR_PAGE_REPAIR_PENDING'
                      WHEN [d].[page_verify_option_desc] <> N'CHECKSUM' THEN 'PAGE_VERIFY_NOT_CHECKSUM'
                      WHEN COALESCE([b].[NoChecksumCount], 0) > 0 THEN 'BACKUP_WITHOUT_CHECKSUM_IN_VISIBLE_HISTORY'
                      ELSE 'CHECKDB_EVIDENCE_UNAVAILABLE'
                  END
                , CONCAT(N'Diese Metadaten sind Indizien; Backupmetadaten-Sichtfenster ', @BackupHistoryDays,
                         N' Tage. LastGoodCheckDbTime wird bewusst nicht über DATABASEPROPERTYEX gelesen, ',
                         N'da diese Metadatenfunktion blockieren kann. Auch CHECKDB_EVIDENCE_UNAVAILABLE ',
                         N'beweist weder logische noch physische Integrität.')
            FROM [#DatabaseIntegrityAnalysis_DatabaseCandidates] AS [c]
            JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
              ON [d].[database_id] = [c].[DatabaseId]
            LEFT JOIN [BackupEvidence] AS [b]
              ON [b].[database_name] COLLATE SQL_Latin1_General_CP1_CS_AS
               = [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
            LEFT JOIN [SuspectEvidence] AS [s]
              ON [s].[DatabaseId] = [c].[DatabaseId]
            LEFT JOIN [RepairEvidence] AS [r]
              ON [r].[DatabaseId] = [c].[DatabaseId];
        END TRY
        BEGIN CATCH
            SELECT @StatusCode =
                       CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371)
                            THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                   @IsPartial = 1,
                   @ErrorNumber = ERROR_NUMBER(),
                   @ErrorMessage = ERROR_MESSAGE();
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitPageDetails = 1
    BEGIN
        BEGIN TRY
            INSERT [#DatabaseIntegrityAnalysis_PageDetails]
            SELECT TOP (@Limit)
                  [c].[DatabaseName]
                , [s].[FileId]
                , [s].[PageId]
                , [s].[EventType]
                , [s].[LastUpdateDate]
                , [p].[object_id]
                , [p].[index_id]
                , [p].[partition_id]
                , [p].[page_type_desc]
                , [p].[alloc_unit_id]
            FROM [#DatabaseIntegrityAnalysis_Suspect] AS [s]
            JOIN [#DatabaseIntegrityAnalysis_DatabaseCandidates] AS [c]
              ON [c].[DatabaseId] = [s].[DatabaseId]
            OUTER APPLY [sys].[dm_db_page_info]
            (
                  [s].[DatabaseId], [s].[FileId], [s].[PageId], 'LIMITED'
            ) AS [p]
            ORDER BY [s].[LastUpdateDate] DESC, [s].[DatabaseId], [s].[FileId], [s].[PageId];
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            IF @ErrorNumber IS NULL
            BEGIN
                SELECT @ErrorNumber = ERROR_NUMBER(),
                       @ErrorMessage = CONCAT(N'Seitenmetadaten nicht lesbar: ', ERROR_MESSAGE());
            END;
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE'
       AND (@IsPartial = 1 OR EXISTS (SELECT 1 FROM [#DatabaseIntegrityAnalysis_DatabaseCandidateWarnings]))
        SET @StatusCode = 'AVAILABLE_LIMITED';
    ELSE IF @StatusCode = 'AVAILABLE'
        AND EXISTS (SELECT 1 FROM [#DatabaseIntegrityAnalysis_Integrity] WHERE [FindingCode] <> 'NO_INDICATOR_FOUND')
        SET @StatusCode = 'AVAILABLE_WITH_FINDING';

    SELECT @StatusCodeOut = @StatusCode,
           @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber,
           @ErrorMessageOut = @ErrorMessage;

    IF @PrintMeldungen = 1 AND @StatusCode <> 'AVAILABLE'
    BEGIN
        SET @MonitorPrintMessage = COALESCE(@ErrorMessage, CONVERT(nvarchar(2048), @StatusCode));
        RAISERROR(N'USP_DatabaseIntegrityAnalysis: %s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT
              CAST('1.0' AS varchar(16)) AS [ContractVersion]
            , @Now AS [CollectionTimeUtc]
            , N'monitor.USP_DatabaseIntegrityAnalysis' AS [ModuleName]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT * FROM [#DatabaseIntegrityAnalysis_Integrity]
            ORDER BY CASE WHEN [FindingCode] = 'NO_INDICATOR_FOUND' THEN 1 ELSE 0 END,
                     [DatabaseName];
            SELECT * FROM [#DatabaseIntegrityAnalysis_PageDetails]
            ORDER BY [LastUpdateDate] DESC, [DatabaseName], [FileId], [PageId];
            SELECT * FROM [#DatabaseIntegrityAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName];
        END
        ELSE
        BEGIN
            SELECT
                  N'Integritätsevidenz' AS [Ergebnis]
                , [DatabaseName] AS [Datenbank]
                , [FindingCode] AS [Bewertung]
                , [PageVerifyOptionDesc] AS [Page Verify]
                , [LastGoodCheckDbTime] AS [Letzter erfolgreicher CHECKDB-Nachweis]
                , [CheckdbAgeHours] AS [Nachweisalter Stunden]
                , [SuspectPageCount] AS [Verdächtige Seiten]
                , [DamagedBackupCount] AS [Beschädigte Backupmetadaten]
                , [BackupWithoutChecksumCount] AS [Backups ohne Checksum]
                , [HadrPageRepairPendingCount] AS [Offene HADR-Seitenreparaturen]
                , [EvidenceLimit] AS [Aussagegrenze]
            FROM [#DatabaseIntegrityAnalysis_Integrity]
            ORDER BY CASE WHEN [FindingCode] = 'NO_INDICATOR_FOUND' THEN 1 ELSE 0 END,
                     [DatabaseName];

            SELECT N'Seitenmetadaten' AS [Ergebnis], [p].*
            FROM [#DatabaseIntegrityAnalysis_PageDetails] AS [p]
            ORDER BY [LastUpdateDate] DESC, [DatabaseName], [FileId], [PageId];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT N'DatabaseIntegrityAnalysis' AS [resultName], 1 AS [schemaVersion],
                   @Now AS [generatedAtUtc], @StatusCode AS [statusCode],
                   @IsPartial AS [isPartial], @ErrorNumber AS [errorNumber],
                   @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @IntegrityJson nvarchar(max) =
            (SELECT * FROM [#DatabaseIntegrityAnalysis_Integrity] ORDER BY [DatabaseName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @PagesJson nvarchar(max) =
            (SELECT * FROM [#DatabaseIntegrityAnalysis_PageDetails] ORDER BY [LastUpdateDate] DESC FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT * FROM [#DatabaseIntegrityAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName] FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"integrity":', COALESCE(@IntegrityJson, N'[]')
            , N',"pageDetails":', COALESCE(@PagesJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#DatabaseIntegrityAnalysis_Integrity'
            , @ResultLabel=N'DatabaseIntegrityAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#DatabaseIntegrityAnalysis_Integrity'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
