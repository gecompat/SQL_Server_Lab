USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CheckAnalyseAccess
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Prüft die effektive Analyseklassen- und AD-Gruppenpolicy.
Ausgabe      : RAW, CONSOLE, TABLE oder NONE; optional JSON mit access und policies.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CheckAnalyseAccess]
      @AnalyseKlasse   varchar(64)    = NULL
    , @NurGesperrte    bit            = 0
    , @ResultSetArt    varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen    bit             = 0
    , @Json             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen  bit             = 1
    , @Hilfe            bit             = 0
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'access',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CheckAnalyseAccess';
        PRINT N'@AnalyseKlasse=NULL liefert alle Analyseklassen; sonst exakter case-sensitiver Code.';
        PRINT N'@ResultSetArt=RAW, CONSOLE, TABLE oder NONE; Wert wird case-insensitiv verarbeitet.';
        PRINT N'@JsonErzeugen=1 liefert @Json mit meta, access, policies und warnings.';
        RETURN;
    END;

    CREATE TABLE [#CheckAnalyseAccess_Access]
    (
          [AnalysisClass] varchar(64) NOT NULL
        , [AnalysisLevel] varchar(16) NOT NULL
        , [RequiresGroupGate] bit NOT NULL
        , [OriginalLoginName] sysname NULL
        , [EffectiveLoginName] sysname NULL
        , [IsSysadmin] bit NULL
        , [ActivePolicyCount] bigint NULL
        , [RelevantPolicyCount] bigint NULL
        , [IsAllowed] bit NOT NULL
        , [AccessReason] varchar(20) NULL
        , [MatchedGroupCount] bigint NULL
        , [StatusCode] varchar(40) NOT NULL
    );

    CREATE TABLE [#CheckAnalyseAccess_Policies]
    (
          [AnalysisClass] varchar(64) NOT NULL
        , [ADGroupName] nvarchar(256) NOT NULL
        , [Priority] int NOT NULL
        , [ValidFromUtc] datetime2(3) NULL
        , [ValidToUtc] datetime2(3) NULL
        , [MatchesLoginToken] bit NOT NULL
        , [MatchesIsMember] bit NOT NULL
        , [Comment] nvarchar(1000) NULL
    );

    CREATE TABLE [#CheckAnalyseAccess_Warnings]
    (
          [WarningCode] varchar(40) NOT NULL
        , [WarningMessage] nvarchar(2048) NOT NULL
    );

    IF @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
    END;
    ELSE IF @AnalyseKlasse IS NOT NULL
        AND NOT EXISTS
        (
            SELECT 1
            FROM [monitor].[VW_AnalyseClassCatalog] AS [c]
            WHERE [c].[AnalysisClass] = @AnalyseKlasse
        )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Die Analyseklasse ist nicht in monitor.VW_AnalyseClassCatalog definiert.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN TRY
        INSERT [#CheckAnalyseAccess_Access]
        (
              [AnalysisClass], [AnalysisLevel], [RequiresGroupGate]
            , [OriginalLoginName], [EffectiveLoginName], [IsSysadmin]
            , [ActivePolicyCount], [RelevantPolicyCount], [IsAllowed]
            , [AccessReason], [MatchedGroupCount], [StatusCode]
        )
        SELECT
              [a].[AnalysisClass], [a].[AnalysisLevel], [a].[RequiresGroupGate]
            , [a].[OriginalLoginName], [a].[EffectiveLoginName], [a].[IsSysadmin]
            , [a].[ActivePolicyCount], [a].[RelevantPolicyCount], [a].[IsAllowed]
            , [a].[AccessReason], [a].[MatchedGroupCount]
            , CASE WHEN [a].[IsAllowed] = 1 THEN 'AVAILABLE' ELSE 'DENIED_GROUP' END
        FROM [monitor].[VW_AnalyseAccessCurrent] AS [a]
        WHERE (@AnalyseKlasse IS NULL OR [a].[AnalysisClass] = @AnalyseKlasse)
          AND (@NurGesperrte = 0 OR [a].[IsAllowed] = 0);

        ;WITH [ActivePolicy] AS
        (
            SELECT
                  [p].[AnalysisClass], [p].[ADGroupName], [p].[Priority]
                , [p].[ValidFromUtc], [p].[ValidToUtc], [p].[Comment]
            FROM [monitor].[VW_AnalyseAccessPolicy] AS [p]
            WHERE [p].[IsEnabled] = 1
              AND ([p].[ValidFromUtc] IS NULL OR [p].[ValidFromUtc] <= SYSUTCDATETIME())
              AND ([p].[ValidToUtc] IS NULL OR [p].[ValidToUtc] > SYSUTCDATETIME())
              AND (@AnalyseKlasse IS NULL OR [p].[AnalysisClass] IN (@AnalyseKlasse, '*'))
        )
        INSERT [#CheckAnalyseAccess_Policies]
        (
              [AnalysisClass], [ADGroupName], [Priority], [ValidFromUtc]
            , [ValidToUtc], [MatchesLoginToken], [MatchesIsMember], [Comment]
        )
        SELECT
              [p].[AnalysisClass], [p].[ADGroupName], [p].[Priority]
            , [p].[ValidFromUtc], [p].[ValidToUtc]
            , CONVERT(bit, CASE WHEN EXISTS
              (
                  SELECT 1
                  FROM [sys].[login_token] AS [lt] WITH (NOLOCK)
                  WHERE [lt].[type] = N'WINDOWS GROUP'
                    AND UPPER(CONVERT(nvarchar(256), [lt].[name])) COLLATE Latin1_General_100_CI_AS
                      = UPPER([p].[ADGroupName]) COLLATE Latin1_General_100_CI_AS
              ) THEN 1 ELSE 0 END)
            , CONVERT(bit, CASE WHEN IS_MEMBER([p].[ADGroupName]) = 1 THEN 1 ELSE 0 END)
            , [p].[Comment]
        FROM [ActivePolicy] AS [p];

        IF EXISTS (SELECT 1 FROM [#CheckAnalyseAccess_Access] WHERE [IsAllowed] = 0)
        BEGIN
            INSERT [#CheckAnalyseAccess_Warnings] VALUES ('DENIED_GROUP', N'Mindestens eine Analyseklasse ist durch die aktuelle Gruppenpolicy gesperrt.');
            SET @StatusCode = 'AVAILABLE_LIMITED';
        END;
    END TRY
    BEGIN CATCH
        SET @StatusCode = 'ERROR_HANDLED';
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();
        INSERT [#CheckAnalyseAccess_Warnings] VALUES (@StatusCode, @ErrorMessage);
    END CATCH;

    IF @PrintMeldungen = 1 AND @ErrorMessage IS NOT NULL
    BEGIN
        DECLARE @PrintMessage nvarchar(2048) = FORMATMESSAGE(N'%s: %s', @StatusCode, @ErrorMessage);
        RAISERROR(N'%s', 10, 1, @PrintMessage) WITH NOWAIT;
    END;

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        SELECT
              CAST('2.0' AS varchar(16)) AS [ContractVersion]
            , @CollectionTimeUtc AS [CollectionTimeUtc]
            , N'monitor.USP_CheckAnalyseAccess' AS [ModuleName]
            , @StatusCode AS [StatusCode]
            , CONVERT(bit, CASE WHEN @StatusCode = 'AVAILABLE' THEN 0 ELSE 1 END) AS [IsPartial]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage];

        IF @ResultSetArtNormalisiert = 'RAW'
        BEGIN
            SELECT * FROM [#CheckAnalyseAccess_Access] ORDER BY [RequiresGroupGate], [AnalysisLevel], [AnalysisClass];
            SELECT * FROM [#CheckAnalyseAccess_Policies] ORDER BY [Priority], [AnalysisClass], [ADGroupName];
            SELECT * FROM [#CheckAnalyseAccess_Warnings] ORDER BY [WarningCode], [WarningMessage];
        END;
        ELSE
        BEGIN
            SELECT
                  N'Analysezugriff' AS [Ergebnis]
                , [AnalysisClass] AS [Analyseklasse]
                , [AnalysisLevel] AS [Stufe]
                , [IsAllowed] AS [erlaubt]
                , [AccessReason] AS [Begründung]
                , [MatchedGroupCount] AS [passende Gruppen]
                , [StatusCode] AS [Status]
            FROM [#CheckAnalyseAccess_Access]
            ORDER BY [RequiresGroupGate], [AnalysisLevel], [AnalysisClass];

            SELECT
                  N'Aktive Zugriffspolicy' AS [Ergebnis]
                , [AnalysisClass] AS [Analyseklasse]
                , [ADGroupName] AS [AD-Gruppe]
                , [Priority] AS [Priorität]
                , [MatchesLoginToken] AS [im Login-Token]
                , [MatchesIsMember] AS [IS_MEMBER]
                , [Comment] AS [Kommentar]
            FROM [#CheckAnalyseAccess_Policies]
            ORDER BY [Priority], [AnalysisClass], [ADGroupName];

            SELECT N'Warnung' AS [Ergebnis], [WarningCode] AS [Code], [WarningMessage] AS [Meldung]
            FROM [#CheckAnalyseAccess_Warnings]
            ORDER BY [WarningCode], [WarningMessage];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  N'CheckAnalyseAccess' AS [resultName]
                , 1 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @ErrorNumber AS [errorNumber]
                , @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @AccessJson nvarchar(max) = (SELECT * FROM [#CheckAnalyseAccess_Access] ORDER BY [RequiresGroupGate], [AnalysisLevel], [AnalysisClass] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @PoliciesJson nvarchar(max) = (SELECT * FROM [#CheckAnalyseAccess_Policies] ORDER BY [Priority], [AnalysisClass], [ADGroupName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max) = (SELECT * FROM [#CheckAnalyseAccess_Warnings] ORDER BY [WarningCode], [WarningMessage] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'), N',"access":', COALESCE(@AccessJson, N'[]'), N',"policies":', COALESCE(@PoliciesJson, N'[]'), N',"warnings":', COALESCE(@WarningsJson, N'[]'), N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CheckAnalyseAccess_Access'
            , @ResultLabel=N'CheckAnalyseAccess'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#CheckAnalyseAccess_Access'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
