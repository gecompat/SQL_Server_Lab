USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CheckFrameworkCapabilities
Version      : 2.0.1
Stand        : 2026-07-16
Zweck        : Prüft Framework-Capabilities serverweit und je ausgewählter DB.
Datenbanken  : @DatabaseNames bracket-aware Pipe-Liste; NULL/N''=alle.
Ausgabe      : RAW, CONSOLE, TABLE oder NONE; optional JSON mit capabilities, summary,
               databaseStatus und warnings.
Änderungen   : 2.0.1 - SQL-Literal-Escaping für Datenbanknamen korrigiert.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @AnalyseKlasse                    varchar(64)     = NULL
    , @NurNichtVerfuegbar               bit            = 0
    , @MitGruppenpruefung               bit            = 1
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                             bit             = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'capabilities',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @Major int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @ProductVersion nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY(N'ProductVersion'));
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @OverallStatus varchar(40) = 'AVAILABLE';
    DECLARE @OverallError nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CheckFrameworkCapabilities';
        PRINT N'@DatabaseNames: bracket-aware Pipe-Liste; NULL/leer=alle sichtbaren Online-Benutzerdatenbanken.';
        PRINT N'@DatabaseNamePattern: like:, regex: oder regexi:; exakte Liste und Pattern sind exklusiv.';
        PRINT N'@ResultSetArt=RAW, CONSOLE, TABLE oder NONE; optional JSON.';
        RETURN;
    END;

    CREATE TABLE [#CheckFrameworkCapabilities_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NOT NULL
        , [RequestedOrdinal] int NULL
    );
    CREATE TABLE [#CheckFrameworkCapabilities_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#CheckFrameworkCapabilities_Capabilities]
    (
          [FeatureOrdinal] smallint NOT NULL
        , [FeatureCode] varchar(64) NOT NULL
        , [FeatureName] nvarchar(200) NOT NULL
        , [ScopeType] varchar(16) NOT NULL
        , [AnalysisClass] varchar(64) NOT NULL
        , [AnalysisLevel] varchar(16) NOT NULL
        , [IsResourceIntensive] bit NOT NULL
        , [DatabaseName] sysname NULL
        , [ServerMajorVersion] int NULL
        , [ServerProductVersion] nvarchar(128) NULL
        , [MinimumMajorVersion] tinyint NOT NULL
        , [VersionSupported] bit NOT NULL
        , [GroupCheckApplied] bit NOT NULL
        , [GroupAccessAllowed] bit NULL
        , [AccessReason] varchar(20) NULL
        , [RequiredPermissionScope] varchar(16) NOT NULL
        , [PermissionCheckType] varchar(24) NOT NULL
        , [RequiredPermission] sysname NULL
        , [PermissionDisplayText] nvarchar(128) NULL
        , [HasRequiredPermission] bit NULL
        , [IsQueryable] bit NOT NULL
        , [IsFeatureEnabled] bit NULL
        , [IsUsable] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Description] nvarchar(1000) NULL
    );

    IF @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SET @OverallStatus = 'INVALID_PARAMETER';
        SET @OverallError = N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
    END;
    ELSE IF @AnalyseKlasse IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM [monitor].[VW_AnalyseClassCatalog] WHERE [AnalysisClass] = @AnalyseKlasse)
    BEGIN
        SET @OverallStatus = 'INVALID_PARAMETER';
        SET @OverallError = N'Unbekannte Analyseklasse.';
    END;

    IF @OverallStatus = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = NULL
            , @StatusCode = @OverallStatus OUTPUT
            , @ErrorMessage = @OverallError OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#CheckFrameworkCapabilities_DatabaseCandidates',@WarningTable=N'#CheckFrameworkCapabilities_DatabaseCandidateWarnings';
    END;

    DECLARE @Features TABLE
    (
          [RowNo] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [FeatureOrdinal] smallint NOT NULL
        , [FeatureCode] varchar(64) NOT NULL
        , [FeatureName] nvarchar(200) NOT NULL
        , [ScopeType] varchar(16) NOT NULL
        , [AnalysisClass] varchar(64) NOT NULL
        , [AnalysisLevel] varchar(16) NOT NULL
        , [IsResourceIntensive] bit NOT NULL
        , [MinimumMajorVersion] tinyint NOT NULL
        , [RequiredPermissionScope] varchar(16) NOT NULL
        , [PermissionCheckType] varchar(24) NOT NULL
        , [RequiredPermission] sysname NULL
        , [PermissionDisplayText] nvarchar(128) NULL
        , [ExpectedWithoutPermission] varchar(32) NULL
        , [ProbeSqlTemplate] nvarchar(2000) NOT NULL
        , [EnablementSqlTemplate] nvarchar(2000) NULL
        , [Description] nvarchar(1000) NULL
        , [DatabaseName] sysname NULL
    );

    /* Eigene tempdb-/Tabellenvariablen-DDL bleibt außerhalb des No-Wait-Vertrags. */
    SET LOCK_TIMEOUT 0;

    IF @OverallStatus = 'AVAILABLE'
    BEGIN
        INSERT @Features
        (
              [FeatureOrdinal], [FeatureCode], [FeatureName], [ScopeType]
            , [AnalysisClass], [AnalysisLevel], [IsResourceIntensive]
            , [MinimumMajorVersion], [RequiredPermissionScope]
            , [PermissionCheckType], [RequiredPermission], [PermissionDisplayText]
            , [ExpectedWithoutPermission], [ProbeSqlTemplate]
            , [EnablementSqlTemplate], [Description], [DatabaseName]
        )
        SELECT
              [f].[FeatureOrdinal], [f].[FeatureCode], [f].[FeatureName], [f].[ScopeType]
            , [f].[AnalysisClass], [f].[AnalysisLevel], [f].[IsResourceIntensive]
            , [f].[MinimumMajorVersion]
            , CASE WHEN @Major >= 16 THEN [f].[PermissionScopeFromSql2022] ELSE [f].[PermissionScopeBeforeSql2022] END
            , CASE WHEN @Major >= 16 THEN [f].[PermissionCheckTypeFromSql2022] ELSE [f].[PermissionCheckTypeBeforeSql2022] END
            , CASE WHEN @Major >= 16 THEN [f].[PermissionNameFromSql2022] ELSE [f].[PermissionNameBeforeSql2022] END
            , CASE WHEN @Major >= 16 THEN [f].[PermissionDisplayTextFromSql2022] ELSE [f].[PermissionDisplayTextBeforeSql2022] END
            , [f].[ExpectedWithoutPermission], [f].[ProbeSqlTemplate]
            , [f].[EnablementSqlTemplate], [f].[Description], NULL
        FROM [monitor].[VW_FrameworkFeatureCatalog] AS [f]
        WHERE [f].[ScopeType] = 'SERVER'
          AND (@AnalyseKlasse IS NULL OR [f].[AnalysisClass] = @AnalyseKlasse)
        UNION ALL
        SELECT
              [f].[FeatureOrdinal], [f].[FeatureCode], [f].[FeatureName], [f].[ScopeType]
            , [f].[AnalysisClass], [f].[AnalysisLevel], [f].[IsResourceIntensive]
            , [f].[MinimumMajorVersion]
            , CASE WHEN @Major >= 16 THEN [f].[PermissionScopeFromSql2022] ELSE [f].[PermissionScopeBeforeSql2022] END
            , CASE WHEN @Major >= 16 THEN [f].[PermissionCheckTypeFromSql2022] ELSE [f].[PermissionCheckTypeBeforeSql2022] END
            , CASE WHEN @Major >= 16 THEN [f].[PermissionNameFromSql2022] ELSE [f].[PermissionNameBeforeSql2022] END
            , CASE WHEN @Major >= 16 THEN [f].[PermissionDisplayTextFromSql2022] ELSE [f].[PermissionDisplayTextBeforeSql2022] END
            , [f].[ExpectedWithoutPermission], [f].[ProbeSqlTemplate]
            , [f].[EnablementSqlTemplate], [f].[Description], [d].[DatabaseName]
        FROM [monitor].[VW_FrameworkFeatureCatalog] AS [f]
        CROSS JOIN [#CheckFrameworkCapabilities_DatabaseCandidates] AS [d]
        WHERE [f].[ScopeType] = 'DATABASE'
          AND (@AnalyseKlasse IS NULL OR [f].[AnalysisClass] = @AnalyseKlasse);
    END;

    DECLARE
          @i int = 1
        , @n int = (SELECT MAX([RowNo]) FROM @Features)
        , @FeatureOrdinal smallint
        , @FeatureCode varchar(64)
        , @FeatureName nvarchar(200)
        , @ScopeType varchar(16)
        , @Class varchar(64)
        , @Level varchar(16)
        , @Intensive bit
        , @MinVersion tinyint
        , @PermissionScope varchar(16)
        , @PermissionCheckType varchar(24)
        , @Permission sysname
        , @PermissionText nvarchar(128)
        , @Expected varchar(32)
        , @Probe nvarchar(2000)
        , @Enable nvarchar(2000)
        , @Description nvarchar(1000)
        , @DatabaseName sysname
        , @QuotedDatabaseName nvarchar(258)
        , @DatabaseLiteral nvarchar(260)
        , @GroupAllowed bit
        , @AccessReason varchar(20)
        , @HasPermission bit
        , @Queryable bit
        , @Enabled bit
        , @Usable bit
        , @Status varchar(40)
        , @ErrorNumber int
        , @ErrorMessage nvarchar(2048)
        , @Sql nvarchar(max);

    WHILE @OverallStatus = 'AVAILABLE' AND @i <= COALESCE(@n, 0)
    BEGIN
        SELECT
              @FeatureOrdinal = [FeatureOrdinal], @FeatureCode = [FeatureCode]
            , @FeatureName = [FeatureName], @ScopeType = [ScopeType]
            , @Class = [AnalysisClass], @Level = [AnalysisLevel]
            , @Intensive = [IsResourceIntensive], @MinVersion = [MinimumMajorVersion]
            , @PermissionScope = [RequiredPermissionScope]
            , @PermissionCheckType = [PermissionCheckType]
            , @Permission = [RequiredPermission], @PermissionText = [PermissionDisplayText]
            , @Expected = [ExpectedWithoutPermission], @Probe = [ProbeSqlTemplate]
            , @Enable = [EnablementSqlTemplate], @Description = [Description]
            , @DatabaseName = [DatabaseName]
        FROM @Features
        WHERE [RowNo] = @i;

        SELECT
              @QuotedDatabaseName = CASE WHEN @DatabaseName IS NULL THEN NULL ELSE QUOTENAME(@DatabaseName) END
            , @DatabaseLiteral = CASE WHEN @DatabaseName IS NULL THEN NULL ELSE REPLACE(@DatabaseName, N'''', N'''''') END
            , @GroupAllowed = 1, @AccessReason = 'OPEN', @HasPermission = NULL
            , @Queryable = 0, @Enabled = NULL, @Usable = 0
            , @Status = 'ERROR_HANDLED', @ErrorNumber = NULL, @ErrorMessage = NULL;

        IF @MitGruppenpruefung = 1
        BEGIN TRY
            SELECT @GroupAllowed = [IsAllowed], @AccessReason = [AccessReason]
            FROM [monitor].[VW_AnalyseAccessCurrent]
            WHERE [AnalysisClass] = @Class;
        END TRY
        BEGIN CATCH
            SELECT @GroupAllowed = 0, @AccessReason = 'CHECK_ERROR', @ErrorNumber = ERROR_NUMBER(), @ErrorMessage = ERROR_MESSAGE();
        END CATCH;

        IF @Major < @MinVersion
            SELECT @Status = 'UNAVAILABLE_VERSION', @ErrorMessage = CONCAT(N'Mindest-Major-Version ', @MinVersion, N'; erkannt ', COALESCE(CONVERT(nvarchar(20), @Major), N'unbekannt'), N'.');
        ELSE IF COALESCE(@GroupAllowed, 0) = 0
            SELECT @Status = 'DENIED_GROUP', @ErrorMessage = COALESCE(@ErrorMessage, N'Analyseklasse nicht freigegeben.');
        ELSE
        BEGIN
            IF @PermissionCheckType = 'HAS_PERMS_BY_NAME' AND @Permission IS NOT NULL
            BEGIN TRY
                IF @PermissionScope = 'SERVER'
                    SELECT @HasPermission = CONVERT(bit, HAS_PERMS_BY_NAME(NULL, NULL, @Permission));
                ELSE IF @PermissionScope = 'DATABASE'
                BEGIN
                    SET @Sql = N'USE ' + @QuotedDatabaseName + N'; SELECT @x=CONVERT(bit,HAS_PERMS_BY_NAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),N''DATABASE'',@p));';
                    EXEC [sys].[sp_executesql] @Sql, N'@p sysname,@x bit OUTPUT', @p = @Permission, @x = @HasPermission OUTPUT;
                END;
            END TRY
            BEGIN CATCH
                SELECT @HasPermission = NULL, @ErrorNumber = ERROR_NUMBER(), @ErrorMessage = CONCAT(N'Berechtigungsprobe: ', ERROR_MESSAGE());
            END CATCH;

            BEGIN TRY
                SET @Sql = REPLACE(@Probe, N'' + N'$' + N'(DATABASE)', COALESCE(@QuotedDatabaseName, QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))));
                EXEC [sys].[sp_executesql] @Sql;
                SET @Queryable = 1;

                IF @Enable IS NOT NULL
                BEGIN
                    SET @Sql = REPLACE(REPLACE(@Enable, N'' + N'$' + N'(DATABASE)', COALESCE(@QuotedDatabaseName, QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID())))), N'' + N'$' + N'(DATABASENAME)', COALESCE(@DatabaseLiteral, REPLACE((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()), N'''', N'''''')));
                    EXEC [sys].[sp_executesql] @Sql, N'@IsEnabledOut bit OUTPUT', @IsEnabledOut = @Enabled OUTPUT;
                END;

                IF @Enabled = 0
                    SELECT @Status = 'AVAILABLE_DISABLED', @Usable = 0;
                ELSE IF @PermissionCheckType = 'PROBE_ONLY'
                    SELECT @Status = 'AVAILABLE_UNVERIFIED', @Usable = 1;
                ELSE IF @HasPermission = 0
                    SELECT @Status = CASE WHEN @Expected = 'LIMITED' THEN 'AVAILABLE_LIMITED' ELSE 'AVAILABLE_UNVERIFIED' END, @Usable = 1;
                ELSE
                    SELECT @Status = 'AVAILABLE', @Usable = 1;
            END TRY
            BEGIN CATCH
                SELECT
                      @Queryable = 0, @Usable = 0
                    , @ErrorNumber = ERROR_NUMBER(), @ErrorMessage = ERROR_MESSAGE()
                    , @Status = CASE
                        WHEN ERROR_NUMBER() IN (229,230,297,300,371,916,15151) THEN 'DENIED_PERMISSION'
                        WHEN ERROR_NUMBER() IN (911,924,927,942,976,978) THEN 'DATABASE_UNAVAILABLE'
                        WHEN ERROR_NUMBER() IN (207,208,195,2812,4121) THEN 'UNAVAILABLE_OBJECT'
                        WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                        ELSE 'ERROR_HANDLED' END;
            END CATCH;
        END;

        INSERT [#CheckFrameworkCapabilities_Capabilities]
        (
              [FeatureOrdinal], [FeatureCode], [FeatureName], [ScopeType]
            , [AnalysisClass], [AnalysisLevel], [IsResourceIntensive]
            , [DatabaseName], [ServerMajorVersion], [ServerProductVersion]
            , [MinimumMajorVersion], [VersionSupported], [GroupCheckApplied]
            , [GroupAccessAllowed], [AccessReason], [RequiredPermissionScope]
            , [PermissionCheckType], [RequiredPermission], [PermissionDisplayText]
            , [HasRequiredPermission], [IsQueryable], [IsFeatureEnabled]
            , [IsUsable], [StatusCode], [ErrorNumber], [ErrorMessage], [Description]
        )
        VALUES
        (
              @FeatureOrdinal, @FeatureCode, @FeatureName, @ScopeType
            , @Class, @Level, @Intensive, @DatabaseName, @Major, @ProductVersion
            , @MinVersion, CONVERT(bit, CASE WHEN @Major >= @MinVersion THEN 1 ELSE 0 END)
            , @MitGruppenpruefung, @GroupAllowed, @AccessReason, @PermissionScope
            , @PermissionCheckType, @Permission, @PermissionText, @HasPermission
            , @Queryable, @Enabled, @Usable, @Status, @ErrorNumber, @ErrorMessage
            , @Description
        );

        SET @i += 1;
    END;

    IF @OverallStatus = 'AVAILABLE'
       AND EXISTS (SELECT 1 FROM [#CheckFrameworkCapabilities_Capabilities] WHERE [IsUsable] = 0)
        SET @OverallStatus = 'AVAILABLE_LIMITED';

    IF @PrintMeldungen = 1 AND (@OverallError IS NOT NULL OR EXISTS (SELECT 1 FROM [#CheckFrameworkCapabilities_Capabilities] WHERE [IsUsable] = 0))
    BEGIN
        DECLARE @PrintMessage nvarchar(2048) = COALESCE(@OverallError, N'Mindestens eine Capability ist nicht vollständig nutzbar.');
        RAISERROR(N'%s', 10, 1, @PrintMessage) WITH NOWAIT;
    END;

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        SELECT
              CAST('2.0' AS varchar(16)) AS [ContractVersion]
            , @CollectionTimeUtc AS [CollectionTimeUtc]
            , N'monitor.USP_CheckFrameworkCapabilities' AS [ModuleName]
            , @OverallStatus AS [StatusCode]
            , CONVERT(bit, CASE WHEN @OverallStatus = 'AVAILABLE' THEN 0 ELSE 1 END) AS [IsPartial]
            , @OverallError AS [ErrorMessage];

        IF @ResultSetArtNormalisiert = 'RAW'
        BEGIN
            SELECT * FROM [#CheckFrameworkCapabilities_Capabilities]
            WHERE @NurNichtVerfuegbar = 0 OR [IsUsable] = 0
            ORDER BY [FeatureOrdinal], [DatabaseName];
            SELECT [StatusCode], COUNT_BIG(*) AS [FeatureCount], SUM(CONVERT(bigint,[IsQueryable])) AS [QueryableCount], SUM(CONVERT(bigint,[IsUsable])) AS [UsableCount]
            FROM [#CheckFrameworkCapabilities_Capabilities] GROUP BY [StatusCode] ORDER BY [StatusCode];
            SELECT * FROM [#CheckFrameworkCapabilities_DatabaseCandidateWarnings] ORDER BY [RequestedName];
        END;
        ELSE
        BEGIN
            SELECT
                  N'Framework-Capability' AS [Ergebnis]
                , [FeatureCode] AS [Feature]
                , [DatabaseName] AS [Datenbank]
                , [StatusCode] AS [Status]
                , [IsUsable] AS [nutzbar]
                , [PermissionDisplayText] AS [Berechtigung]
                , [ErrorMessage] AS [Hinweis]
            FROM [#CheckFrameworkCapabilities_Capabilities]
            WHERE @NurNichtVerfuegbar = 0 OR [IsUsable] = 0
            ORDER BY [FeatureOrdinal], [DatabaseName];

            SELECT N'Capability-Status' AS [Ergebnis], [StatusCode] AS [Status], COUNT_BIG(*) AS [Anzahl]
            FROM [#CheckFrameworkCapabilities_Capabilities] GROUP BY [StatusCode] ORDER BY [StatusCode];

            SELECT N'Datenbankwarnung' AS [Ergebnis], [RequestedName] AS [Datenbank], [StatusCode] AS [Status], [ErrorMessage] AS [Meldung]
            FROM [#CheckFrameworkCapabilities_DatabaseCandidateWarnings] ORDER BY [RequestedName];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) = (SELECT N'CheckFrameworkCapabilities' AS [resultName], 1 AS [schemaVersion], @CollectionTimeUtc AS [generatedAtUtc], @OverallStatus AS [statusCode], @OverallError AS [errorMessage] FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
        DECLARE @CapabilitiesJson nvarchar(max) = (SELECT * FROM [#CheckFrameworkCapabilities_Capabilities] WHERE @NurNichtVerfuegbar = 0 OR [IsUsable] = 0 ORDER BY [FeatureOrdinal], [DatabaseName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @SummaryJson nvarchar(max) = (SELECT [StatusCode], COUNT_BIG(*) AS [FeatureCount], SUM(CONVERT(bigint,[IsQueryable])) AS [QueryableCount], SUM(CONVERT(bigint,[IsUsable])) AS [UsableCount] FROM [#CheckFrameworkCapabilities_Capabilities] GROUP BY [StatusCode] ORDER BY [StatusCode] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max) = (SELECT * FROM [#CheckFrameworkCapabilities_DatabaseCandidateWarnings] ORDER BY [RequestedName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson,N'{}'), N',"capabilities":', COALESCE(@CapabilitiesJson,N'[]'), N',"summary":', COALESCE(@SummaryJson,N'[]'), N',"warnings":', COALESCE(@WarningsJson,N'[]'), N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CheckFrameworkCapabilities_Capabilities'
            , @ResultLabel=N'CheckFrameworkCapabilities'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#CheckFrameworkCapabilities_Capabilities'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
