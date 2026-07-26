USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_DatabaseCapacityAnalysis
Version      : 1.0.1
Stand        : 2026-07-18
Zweck        : Trennt Datei- und Volumefreiraum und bewertet das nächste
               Autogrowth je ausgewählter Datenbank.
Datenquellen : sys.database_files, FILEPROPERTY, sys.dm_os_volume_stats.
Grenzen      : Eine Zeit-bis-voll-Prognose wird ohne persistente Historie nicht
               erzeugt. Alle Bewertungen sind Momentaufnahmen.
Nebenwirkung : rein lesend; keine Datei- oder Datenbankänderung.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_DatabaseCapacityAnalysis]
      @DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MinVolumeFreePercent         decimal(9,2)   = 10.00
    , @NurProblematisch             bit            = 0
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'capacity',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_DatabaseCapacityAnalysis';
        PRINT N'Trennt Dateifreiraum und Volumefreiraum; erzeugt ohne Historie keine Zeit-bis-voll-Prognose.';
        PRINT N'@DatabaseNames: bracket-aware Pipe-Liste; N''''/NULL = keine Datenbankeinschränkung.';
        PRINT N'@MinVolumeFreePercent=10; @NurProblematisch=0; @MaxZeilen NULL/0 = unbegrenzt.';
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

    CREATE TABLE [#DatabaseCapacityAnalysis_DatabaseCandidates]
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

    CREATE TABLE [#DatabaseCapacityAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    CREATE TABLE [#DatabaseCapacityAnalysis_Capacity]
    (
          [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [FileId] int NULL
        , [LogicalFileName] sysname NULL
        , [FileTypeDesc] nvarchar(60) NULL
        , [PhysicalName] nvarchar(260) NULL
        , [FileSizeMb] decimal(19,2) NULL
        , [UsedInFileMb] decimal(19,2) NULL
        , [FreeInFileMb] decimal(19,2) NULL
        , [FreeInFilePercent] decimal(9,2) NULL
        , [GrowthDescription] nvarchar(80) NULL
        , [NextGrowthMb] decimal(19,2) NULL
        , [MaxSizeMb] decimal(19,2) NULL
        , [VolumeMountPoint] nvarchar(512) NULL
        , [LogicalVolumeName] nvarchar(512) NULL
        , [VolumeTotalMb] decimal(19,2) NULL
        , [VolumeAvailableMb] decimal(19,2) NULL
        , [VolumeFreePercent] decimal(9,2) NULL
        , [FindingCode] varchar(80) NULL
        , [EvidenceLimit] nvarchar(500) NOT NULL
    );

    IF @MaxZeilen < 0
       OR @MinVolumeFreePercent < 0
       OR @MinVolumeFreePercent > 100
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER',
               @IsPartial = 1,
               @ErrorMessage = N'Ungültige Datenbank-, Prozent-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
       AND @HasRequiredServerPermission = 0
    BEGIN
        SELECT @IsPartial = 1,
               @ErrorMessage = CONCAT(N'Für vollständige serverweite Volumenevidenz fehlt ',
                                      @RequiredServerPermission, N'.');
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = 'SERVER_HEALTH_CURRENT'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#DatabaseCapacityAnalysis_DatabaseCandidates',@WarningTable=N'#DatabaseCapacityAnalysis_DatabaseCandidateWarnings';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE @DatabaseId int;
        DECLARE @DatabaseName sysname;
        DECLARE @Sql nvarchar(max);

        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseId], [DatabaseName]
            FROM [#DatabaseCapacityAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal], [DatabaseId]), [DatabaseId];

        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DatabaseId, @DatabaseName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@DatabaseName) + N';
INSERT [#DatabaseCapacityAnalysis_Capacity]
(
      [DatabaseId], [DatabaseName], [FileId], [LogicalFileName]
    , [FileTypeDesc], [PhysicalName], [FileSizeMb], [UsedInFileMb]
    , [FreeInFileMb], [FreeInFilePercent], [GrowthDescription]
    , [NextGrowthMb], [MaxSizeMb], [VolumeMountPoint], [LogicalVolumeName]
    , [VolumeTotalMb], [VolumeAvailableMb], [VolumeFreePercent]
    , [FindingCode], [EvidenceLimit]
)
SELECT
      DB_ID(), (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()), [f].[file_id], [f].[name], [f].[type_desc], [f].[physical_name]
    , CONVERT(decimal(19,2), [f].[size] * 8.0 / 1024.0)
    , CONVERT(decimal(19,2), COALESCE(FILEPROPERTY([f].[name], ''SpaceUsed''), 0) * 8.0 / 1024.0)
    , CONVERT(decimal(19,2), ([f].[size] - COALESCE(FILEPROPERTY([f].[name], ''SpaceUsed''), 0)) * 8.0 / 1024.0)
    , CONVERT(decimal(9,2), 100.0 * ([f].[size] - COALESCE(FILEPROPERTY([f].[name], ''SpaceUsed''), 0)) / NULLIF([f].[size], 0))
    , CASE WHEN [f].[growth] = 0 THEN N''DISABLED''
           WHEN [f].[is_percent_growth] = 1 THEN CONCAT([f].[growth], N'' percent'')
           ELSE CONCAT(CONVERT(decimal(19,2), [f].[growth] * 8.0 / 1024.0), N'' MB'') END
    , CASE WHEN [f].[growth] = 0 THEN NULL
           WHEN [f].[is_percent_growth] = 1
               THEN CONVERT(decimal(19,2), CEILING([f].[size] * [f].[growth] / 100.0) * 8.0 / 1024.0)
           ELSE CONVERT(decimal(19,2), [f].[growth] * 8.0 / 1024.0) END
    , CASE WHEN [f].[max_size] = -1 THEN NULL
           ELSE CONVERT(decimal(19,2), [f].[max_size] * 8.0 / 1024.0) END
    , [v].[volume_mount_point], [v].[logical_volume_name]
    , CONVERT(decimal(19,2), [v].[total_bytes] / 1048576.0)
    , CONVERT(decimal(19,2), [v].[available_bytes] / 1048576.0)
    , CONVERT(decimal(9,2), 100.0 * [v].[available_bytes] / NULLIF([v].[total_bytes], 0))
    , CASE
          WHEN [f].[growth] = 0 THEN ''GROWTH_DISABLED''
          WHEN [f].[max_size] <> -1 AND [f].[size] >= [f].[max_size] THEN ''FILE_MAX_SIZE_REACHED''
          WHEN [v].[available_bytes] IS NOT NULL
           AND (CASE WHEN [f].[is_percent_growth] = 1
                     THEN CEILING([f].[size] * [f].[growth] / 100.0) * 8192.0
                     ELSE [f].[growth] * 8192.0 END) > [v].[available_bytes]
              THEN ''NEXT_GROWTH_EXCEEDS_VOLUME_FREE''
          WHEN [v].[total_bytes] > 0
           AND 100.0 * [v].[available_bytes] / [v].[total_bytes] < @pMinVolumeFreePercent
              THEN ''LOW_VOLUME_FREE_PERCENT''
          WHEN [f].[is_percent_growth] = 1 THEN ''PERCENT_GROWTH_REVIEW''
          ELSE ''NO_CAPACITY_INDICATOR''
      END
    , N''Momentaufnahme; ohne persistente Messpunkte wird keine Zeit-bis-voll-Prognose erzeugt.''
FROM [sys].[database_files] AS [f] WITH (NOLOCK)
OUTER APPLY [sys].[dm_os_volume_stats](DB_ID(), [f].[file_id]) AS [v];';

                EXEC [sys].[sp_executesql]
                      @Sql
                    , N'@pMinVolumeFreePercent decimal(9,2)'
                    , @pMinVolumeFreePercent = @MinVolumeFreePercent;
            END TRY
            BEGIN CATCH
                SET @IsPartial = 1;
                INSERT [#DatabaseCapacityAnalysis_DatabaseCandidateWarnings]
                VALUES
                (
                      @DatabaseName
                    , CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371)
                           THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END
                    , ERROR_MESSAGE()
                );
            END CATCH;

            FETCH NEXT FROM [DatabaseCursor] INTO @DatabaseId, @DatabaseName;
        END;
        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];
    END;

    IF @StatusCode = 'AVAILABLE'
       AND (@IsPartial = 1 OR EXISTS (SELECT 1 FROM [#DatabaseCapacityAnalysis_DatabaseCandidateWarnings]))
        SET @StatusCode = 'AVAILABLE_LIMITED';
    ELSE IF @StatusCode = 'AVAILABLE'
        AND EXISTS (SELECT 1 FROM [#DatabaseCapacityAnalysis_Capacity] WHERE [FindingCode] <> 'NO_CAPACITY_INDICATOR')
        SET @StatusCode = 'AVAILABLE_WITH_FINDING';

    SELECT @StatusCodeOut = @StatusCode,
           @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber,
           @ErrorMessageOut = @ErrorMessage;

    IF @PrintMeldungen = 1 AND @StatusCode <> 'AVAILABLE'
    BEGIN
        SET @MonitorPrintMessage = COALESCE(@ErrorMessage, CONVERT(nvarchar(2048), @StatusCode));
        RAISERROR(N'USP_DatabaseCapacityAnalysis: %s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT CAST('1.0' AS varchar(16)) AS [ContractVersion], @Now AS [CollectionTimeUtc],
               N'monitor.USP_DatabaseCapacityAnalysis' AS [ModuleName],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT TOP (@Limit) *
            FROM [#DatabaseCapacityAnalysis_Capacity]
            WHERE @NurProblematisch = 0 OR [FindingCode] <> 'NO_CAPACITY_INDICATOR'
            ORDER BY CASE WHEN [FindingCode] = 'NO_CAPACITY_INDICATOR' THEN 1 ELSE 0 END,
                     [VolumeFreePercent], [DatabaseName], [FileId];
            SELECT * FROM [#DatabaseCapacityAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName];
        END
        ELSE
        BEGIN
            SELECT TOP (@Limit)
                  N'Kapazität' AS [Ergebnis]
                , [DatabaseName] AS [Datenbank]
                , [LogicalFileName] AS [Datei]
                , [FileTypeDesc] AS [Typ]
                , [FindingCode] AS [Bewertung]
                , [FileSizeMb] AS [Dateigröße MB]
                , [FreeInFileMb] AS [Frei in Datei MB]
                , [GrowthDescription] AS [Wachstum]
                , [NextGrowthMb] AS [Nächstes Wachstum MB]
                , [VolumeAvailableMb] AS [Frei auf Volume MB]
                , [VolumeFreePercent] AS [Frei auf Volume Prozent]
                , [VolumeMountPoint] AS [Volume]
                , [EvidenceLimit] AS [Aussagegrenze]
            FROM [#DatabaseCapacityAnalysis_Capacity]
            WHERE @NurProblematisch = 0 OR [FindingCode] <> 'NO_CAPACITY_INDICATOR'
            ORDER BY CASE WHEN [FindingCode] = 'NO_CAPACITY_INDICATOR' THEN 1 ELSE 0 END,
                     [VolumeFreePercent], [DatabaseName], [FileId];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT N'DatabaseCapacityAnalysis' AS [resultName], 1 AS [schemaVersion],
                   @Now AS [generatedAtUtc], @StatusCode AS [statusCode],
                   @IsPartial AS [isPartial], @ErrorNumber AS [errorNumber],
                   @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @CapacityJson nvarchar(max) =
        (
            SELECT TOP (@Limit) *
            FROM [#DatabaseCapacityAnalysis_Capacity]
            WHERE @NurProblematisch = 0 OR [FindingCode] <> 'NO_CAPACITY_INDICATOR'
            ORDER BY CASE WHEN [FindingCode] = 'NO_CAPACITY_INDICATOR' THEN 1 ELSE 0 END,
                     [VolumeFreePercent], [DatabaseName], [FileId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT * FROM [#DatabaseCapacityAnalysis_DatabaseCandidateWarnings] ORDER BY [RequestedName] FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"capacity":', COALESCE(@CapacityJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#DatabaseCapacityAnalysis_Capacity'
            , @ResultLabel=N'DatabaseCapacityAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#DatabaseCapacityAnalysis_Capacity'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
