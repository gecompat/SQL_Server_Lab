USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_IntelligentQueryProcessingAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Zweck        : Dokumentiert IQP-Voraussetzungen, Query-Store-Feedback,
               Query-Varianten und Automatic-Tuning-Evidenz je Datenbank.
Datenquellen : sys.database_query_store_options,
               sys.database_scoped_configurations,
               sys.query_store_query_variant,
               sys.query_store_plan_feedback,
               sys.database_automatic_tuning_options und
               sys.dm_db_tuning_recommendations.
Datenschutz  : Liest weder Query-Text noch Showplan, Objekt- oder Benutzerdaten.
Grenzen      : Vorhandene oder fehlende Feedbackzeilen beweisen weder Nutzen
               noch Fehler. Verfügbarkeit wird versionsadaptiv ausgewiesen.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_IntelligentQueryProcessingAnalysis]
      @DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'signals',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_IntelligentQueryProcessingAnalysis';
        PRINT N'Liest nur IQP-Konfiguration und aggregierte Evidenz; niemals Query-Text oder Showplan.';
        PRINT N'@DatabaseNames: bracket-aware Pipe-Liste; N''''/NULL = keine Datenbankeinschränkung.';
        PRINT N'@MaxZeilen positiv; NULL/0 = unbegrenzt. @ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @Db sysname;
    DECLARE @Sql nvarchar(max);
    DECLARE @ProductMajorVersion int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));

    CREATE TABLE [#IntelligentQueryProcessingAnalysis_DatabaseCandidates]
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

    CREATE TABLE [#IntelligentQueryProcessingAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    CREATE TABLE [#IntelligentQueryProcessingAnalysis_DatabaseState]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [CompatibilityLevel] tinyint NULL
        , [QueryStoreActualStateDesc] nvarchar(60) NULL
        , [QueryStoreDesiredStateDesc] nvarchar(60) NULL
        , [QueryStoreReadonlyReason] bigint NULL
        , [PspEligible] bit NOT NULL
        , [OppoEligible] bit NOT NULL
        , [FindingCode] varchar(80) NOT NULL
        , [FindingSeverity] varchar(16) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    CREATE TABLE [#IntelligentQueryProcessingAnalysis_Configuration]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [ConfigurationName] sysname NOT NULL
        , [ConfigurationValue] nvarchar(4000) NULL
        , [IsValueDefault] bit NULL
    );

    CREATE TABLE [#IntelligentQueryProcessingAnalysis_AutomaticTuning]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [OptionName] nvarchar(60) NOT NULL
        , [DesiredStateDesc] nvarchar(60) NULL
        , [ActualStateDesc] nvarchar(60) NULL
        , [ReasonDesc] nvarchar(120) NULL
    );

    CREATE TABLE [#IntelligentQueryProcessingAnalysis_Signals]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [SignalCode] varchar(80) NOT NULL
        , [IsSourceAvailable] bit NOT NULL
        , [EvidenceCount] bigint NULL
        , [Interpretation] nvarchar(1000) NOT NULL
    );

    CREATE TABLE [#IntelligentQueryProcessingAnalysis_Errors]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER',
               @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Datenbank-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = 'CATALOG_DEEP'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#IntelligentQueryProcessingAnalysis_DatabaseCandidates',@WarningTable=N'#IntelligentQueryProcessingAnalysis_DatabaseCandidateWarnings';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE [database_cursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName]
            FROM [#IntelligentQueryProcessingAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal], [DatabaseId]), [DatabaseId];

        OPEN [database_cursor];
        FETCH NEXT FROM [database_cursor] INTO @Db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
DECLARE @DatabaseId int = DB_ID();
DECLARE @DatabaseName sysname = (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
DECLARE @CompatibilityLevel tinyint =
    (SELECT [compatibility_level] FROM [sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
DECLARE @ActualStateDesc nvarchar(60) = NULL;
DECLARE @DesiredStateDesc nvarchar(60) = NULL;
DECLARE @ReadonlyReason bigint = NULL;

SELECT TOP (1)
      @ActualStateDesc = [actual_state_desc]
    , @DesiredStateDesc = [desired_state_desc]
    , @ReadonlyReason = [readonly_reason]
FROM [sys].[database_query_store_options] WITH (NOLOCK);

INSERT [#IntelligentQueryProcessingAnalysis_DatabaseState]
(
      [DatabaseId], [DatabaseName], [CompatibilityLevel]
    , [QueryStoreActualStateDesc], [QueryStoreDesiredStateDesc]
    , [QueryStoreReadonlyReason], [PspEligible], [OppoEligible]
    , [FindingCode], [FindingSeverity], [EvidenceLimit]
)
SELECT
      @DatabaseId, @DatabaseName, @CompatibilityLevel
    , @ActualStateDesc, @DesiredStateDesc, @ReadonlyReason
    , CONVERT(bit, CASE WHEN @ProductMajorVersion >= 16 AND @CompatibilityLevel >= 160 THEN 1 ELSE 0 END)
    , CONVERT(bit, CASE WHEN @ProductMajorVersion >= 17 AND @CompatibilityLevel >= 170 THEN 1 ELSE 0 END)
    , CASE WHEN COALESCE(@ActualStateDesc, N''OFF'') = N''OFF'' THEN ''QUERY_STORE_OFF''
           WHEN @ActualStateDesc = N''READ_ONLY'' AND @DesiredStateDesc = N''READ_WRITE'' THEN ''QUERY_STORE_READ_ONLY''
           WHEN @CompatibilityLevel < 150 THEN ''IQP_COMPATIBILITY_BELOW_150''
           ELSE ''IQP_EVIDENCE_AVAILABLE'' END
    , CASE WHEN COALESCE(@ActualStateDesc, N''OFF'') = N''OFF'' THEN ''HIGH''
           WHEN @ActualStateDesc = N''READ_ONLY'' AND @DesiredStateDesc = N''READ_WRITE'' THEN ''MEDIUM''
           ELSE ''INFO'' END
    , N''Feature-Eignung folgt Version und Compatibility Level; Evidenzmengen allein bewerten keine Wirksamkeit.'';

INSERT [#IntelligentQueryProcessingAnalysis_Configuration]
(
      [DatabaseId], [DatabaseName], [ConfigurationName]
    , [ConfigurationValue], [IsValueDefault]
)
SELECT
      @DatabaseId, @DatabaseName, [name]
    , CONVERT(nvarchar(4000), [value]), [is_value_default]
FROM [sys].[database_scoped_configurations] WITH (NOLOCK)
WHERE [name] IN
(
      N''PARAMETER_SENSITIVE_PLAN_OPTIMIZATION''
    , N''OPTIONAL_PARAMETER_OPTIMIZATION''
    , N''MEMORY_GRANT_FEEDBACK_PERSISTENCE''
    , N''MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT''
    , N''DOP_FEEDBACK''
    , N''CE_FEEDBACK''
    , N''BATCH_MODE_MEMORY_GRANT_FEEDBACK''
    , N''ROW_MODE_MEMORY_GRANT_FEEDBACK''
    , N''BATCH_MODE_ADAPTIVE_JOINS''
    , N''INTERLEAVED_EXECUTION_TVF''
    , N''DEFERRED_COMPILATION_TV''
);';

                IF @ProductMajorVersion >= 16
                BEGIN
                    SET @Sql += N'
    INSERT [#IntelligentQueryProcessingAnalysis_Signals]
    SELECT @DatabaseId, @DatabaseName, ''QUERY_VARIANTS'', 1, COUNT_BIG(*),
           N''Aggregierte PSP-/OPPO-Varianten; null Zeilen sind kein Fehlerbeweis.''
    FROM [sys].[query_store_query_variant] WITH (NOLOCK);

    INSERT [#IntelligentQueryProcessingAnalysis_Signals]
    SELECT @DatabaseId, @DatabaseName, ''PLAN_FEEDBACK'', 1, COUNT_BIG(*),
           N''Aggregierte CE-, Memory-Grant-, DOP- oder LAQ-Feedbackevidenz; keine Query-Texte.''
    FROM [sys].[query_store_plan_feedback] WITH (NOLOCK);';
                END
                ELSE
                BEGIN
                    SET @Sql += N'
INSERT [#IntelligentQueryProcessingAnalysis_Signals] VALUES
(@DatabaseId, @DatabaseName, ''QUERY_VARIANTS'', 0, NULL,
 N''Katalogsicht ist vor SQL Server 2022 nicht verfügbar.''),
(@DatabaseId, @DatabaseName, ''PLAN_FEEDBACK'', 0, NULL,
 N''Katalogsicht ist vor SQL Server 2022 nicht verfügbar.'');';
                END;

                SET @Sql += N'
    INSERT [#IntelligentQueryProcessingAnalysis_AutomaticTuning]
    (
          [DatabaseId], [DatabaseName], [OptionName]
        , [DesiredStateDesc], [ActualStateDesc], [ReasonDesc]
    )
    SELECT @DatabaseId, @DatabaseName, [name], [desired_state_desc],
           [actual_state_desc], [reason_desc]
    FROM [sys].[database_automatic_tuning_options] WITH (NOLOCK);

    INSERT [#IntelligentQueryProcessingAnalysis_Signals]
    SELECT @DatabaseId, @DatabaseName, ''TUNING_RECOMMENDATIONS'', 1, COUNT_BIG(*),
           N''Anzahl aktueller Automatic-Tuning-Empfehlungen; Details und SQL-Texte werden nicht gelesen.''
    FROM [sys].[dm_db_tuning_recommendations] WITH (NOLOCK);';

                EXEC [sys].[sp_executesql]
                      @Sql
                    , N'@ProductMajorVersion int'
                    , @ProductMajorVersion = @ProductMajorVersion;
            END TRY
            BEGIN CATCH
                INSERT [#IntelligentQueryProcessingAnalysis_Errors]
                VALUES
                (
                      @Db
                    , CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371, 916)
                           THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END
                    , ERROR_NUMBER()
                    , ERROR_MESSAGE()
                );
                SET @IsPartial = 1;
            END CATCH;

            FETCH NEXT FROM [database_cursor] INTO @Db;
        END;

        CLOSE [database_cursor];
        DEALLOCATE [database_cursor];

        INSERT [#IntelligentQueryProcessingAnalysis_Errors]
        SELECT [RequestedName], [StatusCode], NULL, [ErrorMessage]
        FROM [#IntelligentQueryProcessingAnalysis_DatabaseCandidateWarnings];

        IF EXISTS (SELECT 1 FROM [#IntelligentQueryProcessingAnalysis_Errors])
            SET @IsPartial = 1;

        IF NOT EXISTS (SELECT 1 FROM [#IntelligentQueryProcessingAnalysis_DatabaseState])
        BEGIN
            SELECT @StatusCode = CASE WHEN EXISTS
                   (SELECT 1 FROM [#IntelligentQueryProcessingAnalysis_Errors] WHERE [StatusCode] = 'DENIED_PERMISSION')
                   THEN 'DENIED_PERMISSION' ELSE 'DATABASE_UNAVAILABLE' END,
                   @IsPartial = 1;
        END
        ELSE IF @IsPartial = 1
            SET @StatusCode = 'AVAILABLE_LIMITED';
        ELSE IF EXISTS
                (SELECT 1 FROM [#IntelligentQueryProcessingAnalysis_DatabaseState] WHERE [FindingCode] <> 'IQP_EVIDENCE_AVAILABLE')
            SET @StatusCode = 'AVAILABLE_WITH_FINDING';
    END;

    SELECT @StatusCodeOut = @StatusCode,
           @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber,
           @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT N'IntelligentQueryProcessingAnalysis' AS [resultName],
                   1 AS [schemaVersion], @Now AS [generatedAtUtc],
                   @StatusCode AS [statusCode], @IsPartial AS [isPartial]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );
        DECLARE @StateJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_DatabaseState]
             ORDER BY [DatabaseId] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @ConfigurationJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_Configuration]
             ORDER BY [DatabaseId], [ConfigurationName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @AutomaticTuningJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_AutomaticTuning]
             ORDER BY [DatabaseId], [OptionName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @SignalsJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_Signals]
             ORDER BY [DatabaseId], [SignalCode]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT * FROM [#IntelligentQueryProcessingAnalysis_Errors] ORDER BY [DatabaseName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"databaseState":', COALESCE(@StateJson, N'[]')
            , N',"configuration":', COALESCE(@ConfigurationJson, N'[]')
            , N',"automaticTuning":', COALESCE(@AutomaticTuningJson, N'[]')
            , N',"signals":', COALESCE(@SignalsJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]'), N'}'
        );
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_IntelligentQueryProcessingAnalysis' AS [ModuleName],
               @Now AS [CollectionTimeUtc], @StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial], @ProductMajorVersion AS [ProductMajorVersion],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'Read-only; keine Query-Texte oder Showplans.' AS [Detail];
        SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_DatabaseState] ORDER BY [DatabaseId];
        SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_Configuration] ORDER BY [DatabaseId], [ConfigurationName];
        SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_AutomaticTuning] ORDER BY [DatabaseId], [OptionName];
        SELECT TOP (@Limit) * FROM [#IntelligentQueryProcessingAnalysis_Signals] ORDER BY [DatabaseId], [SignalCode];
        SELECT * FROM [#IntelligentQueryProcessingAnalysis_Errors] ORDER BY [DatabaseName];
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Intelligent Query Processing' AS [Ergebnis], @Now AS [Stand_UTC],
               @StatusCode AS [Status], @IsPartial AS [Teilweise],
               (SELECT COUNT_BIG(*) FROM [#IntelligentQueryProcessingAnalysis_DatabaseState]) AS [Datenbanken],
               N'Aggregierte Evidenz ohne Query-Text oder Showplan.' AS [Hinweis];

        SELECT TOP (@Limit)
               N'IQP-Datenbankstatus' AS [Ergebnis], [DatabaseName] AS [Datenbank],
               [CompatibilityLevel] AS [Compatibility_Level],
               [QueryStoreActualStateDesc] AS [Query_Store],
               [PspEligible] AS [PSP_geeignet], [OppoEligible] AS [OPPO_geeignet],
               [FindingCode] AS [Befund], [FindingSeverity] AS [Prioritaet],
               [EvidenceLimit] AS [Grenze]
        FROM [#IntelligentQueryProcessingAnalysis_DatabaseState]
        ORDER BY [DatabaseId];

        SELECT TOP (@Limit)
               N'IQP-Signal' AS [Ergebnis], [DatabaseName] AS [Datenbank],
               [SignalCode] AS [Signal], [IsSourceAvailable] AS [Quelle_verfuegbar],
               [EvidenceCount] AS [Anzahl], [Interpretation]
        FROM [#IntelligentQueryProcessingAnalysis_Signals]
        ORDER BY [DatabaseId], [SignalCode];

        SELECT N'IQP-Warnung' AS [Ergebnis], [DatabaseName] AS [Datenbank],
               [StatusCode] AS [Status], [ErrorNumber] AS [Fehlernummer],
               [ErrorMessage] AS [Meldung]
        FROM [#IntelligentQueryProcessingAnalysis_Errors]
        ORDER BY [DatabaseName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#IntelligentQueryProcessingAnalysis_Signals'
            , @ResultLabel=N'IntelligentQueryProcessingAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#IntelligentQueryProcessingAnalysis_Signals'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
