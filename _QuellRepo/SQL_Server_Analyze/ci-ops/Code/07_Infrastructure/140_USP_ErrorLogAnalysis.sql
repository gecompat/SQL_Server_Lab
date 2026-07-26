USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ErrorLogAnalysis
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Liest SQL-Server- und optional Agent-Errorlogs über dokumentierte
               sp_readerrorlog-Filter in Kategorien, Summary und Source-Status.
Default      : Aktuelles SQL-Server-Log, letzte 24 Stunden Serverlokalzeit,
               kuratierte High-Signal-Filter, kein Meldungsvolltext.
Grenzen      : sp_readerrorlog besitzt keinen dokumentierten Zeitparameter.
               Deshalb wird serverseitig nach Keywords und anschließend nach
               LogDate begrenzt. Sehr große Treffer werden AVAILABLE_LIMITED.
Nebenwirkung : Kein Logwechsel, keine Konfiguration, keine Persistenz.
Datenschutz  : Meldungstext und ProcessInfo nur opt-in; Laufzeitausgabe darf
               reale Diagnosewerte enthalten, Repositoryartefakte niemals.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ErrorLogAnalysis]
      @AgentEinbeziehen          bit             = 0
    , @MaxArchivNummer           tinyint         = 0
    , @SeitServerlokalzeit       datetime2(3)    = NULL
    , @Suchtext1                 nvarchar(4000)  = NULL
    , @Suchtext2                 nvarchar(4000)  = NULL
    , @MeldungstextEinbeziehen   bit             = 0
    , @MaxMeldungszeichen        int             = 4000
    , @MaxQuellzeilen            int             = 10000
    , @MaxZeilen                 int             = 1000
    , @ResultSetArt              varchar(16)     = 'CONSOLE'
    , @ResultTablesJson          nvarchar(max)   = NULL
    , @JsonErzeugen              bit             = 0
    , @Json                       nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen            bit             = 1
    , @Hilfe                     bit             = 0
    , @StatusCodeOut             varchar(40)     = NULL OUTPUT
    , @IsPartialOut              bit             = NULL OUTPUT
    , @ErrorNumberOut            int             = NULL OUTPUT
    , @ErrorMessageOut           nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;

    DECLARE @CapturedAtUtc datetime2(3)=SYSUTCDATETIME();
    DECLARE @EffectiveSince datetime2(3)=COALESCE(@SeitServerlokalzeit,DATEADD(HOUR,-24,CONVERT(datetime2(3),SYSDATETIME())));
    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @ConsoleResultRequested bit=CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))))='CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @SourceLimit bigint=CASE WHEN @MaxQuellzeilen IS NULL OR @MaxQuellzeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxQuellzeilen) END;
    DECLARE @SourceCandidateLimit bigint=@SourceLimit;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ErrorLogAnalysis';
        PRINT N'Standardmäßig liest die Procedure das aktuelle SQL-Server-Errorlog für die letzten 24 Stunden in der vom Errorlog gelieferten Serverlokalzeit und erstellt eine kategorisierte Zusammenfassung.';
        PRINT N'@MaxArchivNummer=0 liest nur das aktuelle Log; höhere Werte lesen Archive 0..n. Kein Logwechsel wird ausgeführt.';
        PRINT N'@Suchtext1/@Suchtext2 ersetzen die kuratierten Defaultfilter durch einen benutzerdefinierten dokumentierten sp_readerrorlog-Filter.';
        PRINT N'@MeldungstextEinbeziehen=1 aktiviert Details. @MaxMeldungszeichen=0 ist unbegrenzt; Kürzung erzeugt genau eine Warning.';
        PRINT N'@MaxQuellzeilen begrenzt materialisierte Treffer; 0 ist explizit unbegrenzt. Sehr große Logs können trotz Keywordfilter Last erzeugen.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE-Namen: moduleStatus, summary, details, sourceStatus, warnings.';
        RETURN;
    END;

    CREATE TABLE [#ErrorLogAnalysis_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );
    CREATE TABLE [#ErrorLogAnalysis_SearchRules]
    (
          [RuleOrdinal] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [ProductCode] int NOT NULL
        , [RuleCategory] varchar(80) NOT NULL
        , [SearchText1] nvarchar(4000) NULL
        , [SearchText2] nvarchar(4000) NULL
    );
    CREATE TABLE [#ErrorLogAnalysis_ReadBuffer]
    (
          [LogDate] datetime NULL
        , [ProcessInfo] nvarchar(50) NULL
        , [MessageText] nvarchar(max) NULL
    );
    CREATE TABLE [#ErrorLogAnalysis_Events]
    (
          [EventOrdinal] bigint IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [ProductCode] int NOT NULL
        , [ProductName] varchar(32) NOT NULL
        , [ArchiveNumber] int NOT NULL
        , [RuleCategory] varchar(80) NOT NULL
        , [LogDateServerLocal] datetime NOT NULL
        , [ProcessInfo] nvarchar(50) NULL
        , [MessageText] nvarchar(max) NOT NULL
        , [MessageHash] binary(32) NOT NULL
    );
    CREATE INDEX [IX_ErrorLog_Events_Time] ON [#ErrorLogAnalysis_Events]([LogDateServerLocal],[ProductCode],[ArchiveNumber]);
    CREATE TABLE [#ErrorLogAnalysis_SourceStatus]
    (
          [SourceOrdinal] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [ProductName] varchar(32) NOT NULL
        , [ArchiveNumber] int NOT NULL
        , [RuleCategory] varchar(80) NOT NULL
        , [SourceObject] nvarchar(256) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [ReadRowCount] bigint NOT NULL
        , [AcceptedRowCount] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ErrorLogAnalysis_Classified]
    (
          [EventOrdinal] bigint NOT NULL PRIMARY KEY
        , [ProductName] varchar(32) NOT NULL
        , [ArchiveNumber] int NOT NULL
        , [Category] varchar(80) NOT NULL
        , [LogDateServerLocal] datetime NOT NULL
        , [ProcessInfo] nvarchar(50) NULL
        , [MessageText] nvarchar(max) NOT NULL
    );
    CREATE TABLE [#ErrorLogAnalysis_Summary]
    (
          [ProductName] varchar(32) NOT NULL
        , [Category] varchar(80) NOT NULL
        , [EventCount] bigint NOT NULL
        , [FirstOccurrenceServerLocal] datetime NOT NULL
        , [LastOccurrenceServerLocal] datetime NOT NULL
        , [ArchiveCount] int NOT NULL
        , [HighestArchiveNumber] int NOT NULL
        , [TimeSemantics] varchar(64) NOT NULL
        , [FindingCode] varchar(80) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ErrorLogAnalysis_Details]
    (
          [ProductName] varchar(32) NOT NULL
        , [ArchiveNumber] int NOT NULL
        , [Category] varchar(80) NOT NULL
        , [LogDateServerLocal] datetime NOT NULL
        , [TimeSemantics] varchar(64) NOT NULL
        , [ProcessInfo] nvarchar(50) NULL
        , [MessageCharacters] bigint NULL
        , [MessageBytes] bigint NULL
        , [MessageIsTruncated] bit NOT NULL
        , [MessageText] nvarchar(max) NULL
    );
    CREATE TABLE [#ErrorLogAnalysis_Warnings]
    (
          [WarningOrdinal] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [SourceName] sysname NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [Message] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#ErrorLogAnalysis_ModuleStatus]
    (
          [ModuleName] sysname NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [SinceServerLocalTime] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [AgentRequested] bit NOT NULL
        , [HighestArchiveRequested] tinyint NOT NULL
        , [SourceRowLimit] int NULL
        , [AcceptedSourceRows] bigint NOT NULL
        , [SummaryRowCount] bigint NOT NULL
        , [DetailRowCount] bigint NOT NULL
        , [HasMoreSourceRows] bit NOT NULL
        , [HasMoreDetailRows] bit NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @AgentEinbeziehen IS NULL OR @MeldungstextEinbeziehen IS NULL OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @MaxArchivNummer IS NULL OR @MaxArchivNummer>20
       OR @MaxMeldungszeichen IS NULL OR @MaxMeldungszeichen<0 OR @MaxQuellzeilen<0 OR @MaxZeilen<0
       OR @OutputMode NOT IN('CONSOLE','RAW','TABLE','NONE')
       OR (@Suchtext1 IS NULL AND @Suchtext2 IS NOT NULL)
       OR (@Suchtext1 IS NOT NULL AND NULLIF(LTRIM(RTRIM(@Suchtext1)),N'') IS NULL)
       OR (@Suchtext2 IS NOT NULL AND NULLIF(LTRIM(RTRIM(@Suchtext2)),N'') IS NULL)
       OR (@OutputMode<>'TABLE' AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL)
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungültiger Archiv-, Zeit-, Such-, Text-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode='AVAILABLE' AND @OutputMode='TABLE'
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'moduleStatus|summary|details|sourceStatus|warnings'
            , @MappingTable=N'#ErrorLogAnalysis_ResultTableMap'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @ThrowOnError=1;

    IF @StatusCode='AVAILABLE'
    BEGIN
        IF @Suchtext1 IS NOT NULL
        BEGIN
            INSERT [#ErrorLogAnalysis_SearchRules]([ProductCode],[RuleCategory],[SearchText1],[SearchText2])
            VALUES(1,'CUSTOM_FILTER',@Suchtext1,@Suchtext2);
            IF @AgentEinbeziehen=1
                INSERT [#ErrorLogAnalysis_SearchRules]([ProductCode],[RuleCategory],[SearchText1],[SearchText2])
                VALUES(2,'CUSTOM_FILTER',@Suchtext1,@Suchtext2);
        END
        ELSE
        BEGIN
            INSERT [#ErrorLogAnalysis_SearchRules]([ProductCode],[RuleCategory],[SearchText1],[SearchText2])
            VALUES
              (1,'IO_ERROR',N'Error: 823',NULL),(1,'IO_ERROR',N'Error: 824',NULL),(1,'IO_ERROR',N'Error: 825',NULL)
            , (1,'LONG_IO',N'taking longer than 15 seconds',NULL)
            , (1,'BACKUP_RESTORE',N'Backup',N'failed'),(1,'BACKUP_RESTORE',N'Restore',N'failed')
            , (1,'CACHE_FLUSH',N'cachestore flush',NULL),(1,'CACHE_FLUSH',N'FlushCache',NULL)
            , (1,'AUTOGROWTH',N'Autogrow',NULL)
            , (1,'DUMP_ASSERTION',N'Stack Dump',NULL),(1,'DUMP_ASSERTION',N'Assertion',NULL)
            , (1,'LOGIN_CONNECTIVITY',N'Login failed',NULL),(1,'LOGIN_CONNECTIVITY',N'17830',NULL)
            , (1,'REPLICATION',N'Replication',N'failed'),(1,'LOG_SHIPPING',N'Log Shipping',N'failed');
            IF @AgentEinbeziehen=1
                INSERT [#ErrorLogAnalysis_SearchRules]([ProductCode],[RuleCategory],[SearchText1],[SearchText2])
                VALUES(2,'AGENT_ERROR',N'failed',NULL),(2,'AGENT_ERROR',N'error',NULL);
        END;
    END;

    SET LOCK_TIMEOUT 0;

    DECLARE @ProductCode int,@RuleCategory varchar(80),@Search1 nvarchar(4000),@Search2 nvarchar(4000);
    DECLARE @ArchiveNumber int,@CurrentAccepted bigint,@Remaining bigint,@ReadRows bigint,@AcceptedRows bigint;
    DECLARE @HasMoreSourceRows bit=0;

    IF @StatusCode='AVAILABLE'
    BEGIN
        DECLARE [RuleCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [ProductCode],[RuleCategory],[SearchText1],[SearchText2]
            FROM [#ErrorLogAnalysis_SearchRules] ORDER BY [ProductCode],[RuleOrdinal];
        OPEN [RuleCursor]; FETCH NEXT FROM [RuleCursor] INTO @ProductCode,@RuleCategory,@Search1,@Search2;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @ArchiveNumber=0;
            WHILE @ArchiveNumber<=@MaxArchivNummer
            BEGIN
                SELECT @CurrentAccepted=COUNT_BIG(*) FROM [#ErrorLogAnalysis_Events];
                IF @CurrentAccepted>=@SourceCandidateLimit
                BEGIN
                    SET @HasMoreSourceRows=1;
                    INSERT [#ErrorLogAnalysis_SourceStatus]
                    VALUES(CASE @ProductCode WHEN 1 THEN 'SQL_SERVER' ELSE 'SQL_AGENT' END,@ArchiveNumber,@RuleCategory,N'master.sys.sp_readerrorlog',@CapturedAtUtc,
                           'NOT_EXECUTED_ROW_LIMIT',1,0,0,NULL,N'@MaxQuellzeilen wurde vor diesem Filter erreicht.',
                           N'Weitere Filter/Archive wurden nicht gelesen; der Gesamtbefund ist partiell.');
                END
                ELSE
                BEGIN
                    TRUNCATE TABLE [#ErrorLogAnalysis_ReadBuffer];
                    BEGIN TRY
                        INSERT [#ErrorLogAnalysis_ReadBuffer]([LogDate],[ProcessInfo],[MessageText])
                        EXEC [master].[sys].[sp_readerrorlog] @ArchiveNumber,@ProductCode,@Search1,@Search2;
                        SELECT @ReadRows=COUNT_BIG(*) FROM [#ErrorLogAnalysis_ReadBuffer] WHERE [LogDate]>=@EffectiveSince;
                        SET @Remaining=CASE WHEN @SourceCandidateLimit=9223372036854775807 THEN @SourceCandidateLimit ELSE @SourceCandidateLimit-@CurrentAccepted END;

                        INSERT [#ErrorLogAnalysis_Events]([ProductCode],[ProductName],[ArchiveNumber],[RuleCategory],[LogDateServerLocal],[ProcessInfo],[MessageText],[MessageHash])
                        SELECT TOP(@Remaining) @ProductCode,CASE @ProductCode WHEN 1 THEN 'SQL_SERVER' ELSE 'SQL_AGENT' END,
                               @ArchiveNumber,@RuleCategory,[b].[LogDate],[b].[ProcessInfo],[b].[MessageText],HASHBYTES('SHA2_256',[b].[MessageText])
                        FROM [#ErrorLogAnalysis_ReadBuffer] AS [b]
                        WHERE [b].[LogDate]>=@EffectiveSince AND [b].[MessageText] IS NOT NULL
                          AND NOT EXISTS
                          (
                              SELECT 1 FROM [#ErrorLogAnalysis_Events] AS [e]
                              WHERE [e].[ProductCode]=@ProductCode AND [e].[ArchiveNumber]=@ArchiveNumber
                                AND [e].[LogDateServerLocal]=[b].[LogDate]
                                AND ISNULL([e].[ProcessInfo],N'')=ISNULL([b].[ProcessInfo],N'')
                                AND [e].[MessageHash]=HASHBYTES('SHA2_256',[b].[MessageText])
                          )
                        ORDER BY [b].[LogDate] DESC;
                        SET @AcceptedRows=@@ROWCOUNT;
                        IF @ReadRows>@Remaining SET @HasMoreSourceRows=1;
                        INSERT [#ErrorLogAnalysis_SourceStatus]
                        VALUES(CASE @ProductCode WHEN 1 THEN 'SQL_SERVER' ELSE 'SQL_AGENT' END,@ArchiveNumber,@RuleCategory,N'master.sys.sp_readerrorlog',@CapturedAtUtc,
                               CASE WHEN @ReadRows>@Remaining THEN 'AVAILABLE_LIMITED' ELSE 'AVAILABLE' END,
                               CONVERT(bit,CASE WHEN @ReadRows>@Remaining THEN 1 ELSE 0 END),@ReadRows,@AcceptedRows,NULL,NULL,
                               N'Dokumentierter Keywordfilter im gewählten Archiv; LogDate wird danach als Serverlokalzeit begrenzt. Doppelte Treffer mehrerer Regeln werden entfernt.');
                    END TRY
                    BEGIN CATCH
                        INSERT [#ErrorLogAnalysis_SourceStatus]
                        VALUES(CASE @ProductCode WHEN 1 THEN 'SQL_SERVER' ELSE 'SQL_AGENT' END,@ArchiveNumber,@RuleCategory,N'master.sys.sp_readerrorlog',@CapturedAtUtc,
                               CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
                               1,0,0,ERROR_NUMBER(),ERROR_MESSAGE(),N'Andere Filter und Archive werden weiter verarbeitet.');
                    END CATCH;
                END;
                SET @ArchiveNumber+=1;
            END;
            FETCH NEXT FROM [RuleCursor] INTO @ProductCode,@RuleCategory,@Search1,@Search2;
        END;
        CLOSE [RuleCursor]; DEALLOCATE [RuleCursor];
    END;

    INSERT [#ErrorLogAnalysis_Classified]
    SELECT [EventOrdinal],[ProductName],[ArchiveNumber],[classification].[Category],
           [LogDateServerLocal],[ProcessInfo],[MessageText]
    FROM [#ErrorLogAnalysis_Events]
    CROSS APPLY [monitor].[TVF_ClassifyErrorLogEvent]([ProductName],[RuleCategory],[MessageText]) AS [classification];

    INSERT [#ErrorLogAnalysis_Summary]
    SELECT [ProductName],[Category],COUNT_BIG(*),MIN([LogDateServerLocal]),MAX([LogDateServerLocal]),
           COUNT(DISTINCT [ArchiveNumber]),MAX([ArchiveNumber]),'SERVER_LOCAL_TIME_FROM_ERRORLOG','EVENT_CATEGORY_REVIEW',
           N'Keywordgefilterte Errorlog-Evidenz. Häufigkeit und Zeitnähe erhöhen Relevanz, beweisen aber ohne korrelierte Engine-, OS-, Storage- oder Workloaddaten keine Ursache.'
    FROM [#ErrorLogAnalysis_Classified]
    GROUP BY [ProductName],[Category];

    IF @MeldungstextEinbeziehen=1
        INSERT [#ErrorLogAnalysis_Details]
        SELECT [c].[ProductName],[c].[ArchiveNumber],[c].[Category],[c].[LogDateServerLocal],
               'SERVER_LOCAL_TIME_FROM_ERRORLOG',[c].[ProcessInfo],
               [p].[OriginalCharacters],[p].[OriginalBytes],[p].[IsTruncated],[p].[ProjectedValue]
        FROM [#ErrorLogAnalysis_Classified] AS [c]
        CROSS APPLY [monitor].[TVF_ProjectUnicodeText]([c].[MessageText],@MaxMeldungszeichen) AS [p];

    INSERT [#ErrorLogAnalysis_Warnings]([SourceName],[StatusCode],[ErrorNumber],[Message])
    SELECT N'sp_readerrorlog',[StatusCode],[ErrorNumber],COALESCE([ErrorMessage],N'Quelle oder Teilquelle nicht vollständig gelesen.')
    FROM [#ErrorLogAnalysis_SourceStatus] WHERE [IsPartial]=1;

    IF @HasMoreSourceRows=1 AND NOT EXISTS(SELECT 1 FROM [#ErrorLogAnalysis_Warnings] WHERE [StatusCode]='SOURCE_ROW_LIMIT')
        INSERT [#ErrorLogAnalysis_Warnings]([SourceName],[StatusCode],[ErrorNumber],[Message])
        VALUES(N'sp_readerrorlog','SOURCE_ROW_LIMIT',NULL,N'@MaxQuellzeilen begrenzt die materialisierte Errorlog-Evidenz; Summary und Details sind partiell.');

    IF @StatusCode='AVAILABLE' AND NOT EXISTS(SELECT 1 FROM [#ErrorLogAnalysis_SourceStatus] WHERE [StatusCode]='AVAILABLE')
       AND EXISTS(SELECT 1 FROM [#ErrorLogAnalysis_SourceStatus] WHERE [IsPartial]=1)
    BEGIN
        SELECT TOP(1) @StatusCode=[StatusCode],@ErrorNumber=[ErrorNumber],@ErrorMessage=[ErrorMessage],@IsPartial=1
        FROM [#ErrorLogAnalysis_SourceStatus] WHERE [IsPartial]=1 ORDER BY [SourceOrdinal];
    END;
    ELSE IF @StatusCode='AVAILABLE' AND EXISTS(SELECT 1 FROM [#ErrorLogAnalysis_SourceStatus] WHERE [IsPartial]=1)
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;

    IF @StatusCode NOT IN('AVAILABLE','AVAILABLE_LIMITED') SET @IsPartial=1;
    IF @ErrorMessage IS NULL
        SELECT TOP(1) @ErrorNumber=[ErrorNumber],@ErrorMessage=[Message]
        FROM [#ErrorLogAnalysis_Warnings] ORDER BY [WarningOrdinal];

    DECLARE @AcceptedSourceRows bigint=(SELECT COUNT_BIG(*) FROM [#ErrorLogAnalysis_Classified]);
    DECLARE @SummaryRows bigint=(SELECT COUNT_BIG(*) FROM [#ErrorLogAnalysis_Summary]);
    DECLARE @DetailRows bigint=(SELECT COUNT_BIG(*) FROM [#ErrorLogAnalysis_Details]);
    INSERT [#ErrorLogAnalysis_ModuleStatus]
    VALUES(N'USP_ErrorLogAnalysis',@CapturedAtUtc,@EffectiveSince,@StatusCode,@IsPartial,@AgentEinbeziehen,@MaxArchivNummer,
           @MaxQuellzeilen,@AcceptedSourceRows,@SummaryRows,
           CASE WHEN @DetailRows>@Limit THEN @Limit ELSE @DetailRows END,@HasMoreSourceRows,
           CONVERT(bit,CASE WHEN @Limit<9223372036854775807 AND @DetailRows>@Limit THEN 1 ELSE 0 END),
           @ErrorNumber,@ErrorMessage);

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'ErrorLogAnalysis' [resultName],1 [schemaVersion],@CapturedAtUtc [generatedAtUtc],@EffectiveSince [sinceServerLocalTime],N'SERVER_LOCAL_TIME_FROM_ERRORLOG' [timeSemantics],@StatusCode [statusCode],@IsPartial [isPartial],@MeldungstextEinbeziehen [messageTextIncluded],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @SummaryJson nvarchar(max)=(SELECT * FROM [#ErrorLogAnalysis_Summary] ORDER BY [LastOccurrenceServerLocal] DESC,[ProductName],[Category] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @DetailsJson nvarchar(max)=(SELECT TOP(@Limit) * FROM [#ErrorLogAnalysis_Details] ORDER BY [LogDateServerLocal] DESC,[ProductName],[ArchiveNumber],[Category] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @SourceJson nvarchar(max)=(SELECT * FROM [#ErrorLogAnalysis_SourceStatus] ORDER BY [SourceOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max)=(SELECT * FROM [#ErrorLogAnalysis_Warnings] ORDER BY [WarningOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"summary":',COALESCE(@SummaryJson,N'[]'),N',"details":',COALESCE(@DetailsJson,N'[]'),N',"sourceStatus":',COALESCE(@SourceJson,N'[]'),N',"warnings":',COALESCE(@WarningsJson,N'[]'),N'}');
    END;

    IF @ConsoleResultRequested=1
        EXEC [monitor].[InternalEmitConsoleResult] @SourceTable=N'#ErrorLogAnalysis_Summary',@ResultLabel=N'Errorlog-Kategorien',@EmptyMessage=N'Keine Treffer in Zeit-, Archiv- und Keyword-Scope';
    ELSE IF @OutputMode='RAW'
    BEGIN
        SELECT * FROM [#ErrorLogAnalysis_ModuleStatus];
        SELECT * FROM [#ErrorLogAnalysis_Summary] ORDER BY [LastOccurrenceServerLocal] DESC,[ProductName],[Category];
        SELECT TOP(@Limit) * FROM [#ErrorLogAnalysis_Details] ORDER BY [LogDateServerLocal] DESC,[ProductName],[ArchiveNumber],[Category];
        SELECT * FROM [#ErrorLogAnalysis_SourceStatus] ORDER BY [SourceOrdinal];
        SELECT * FROM [#ErrorLogAnalysis_Warnings] ORDER BY [WarningOrdinal];
    END
    ELSE IF @OutputMode='TABLE'
    BEGIN
        DECLARE @ResultName sysname,@TargetTable sysname,@SourceTable sysname;
        DECLARE [ResultCursor] CURSOR LOCAL FAST_FORWARD FOR SELECT [ResultName],[TargetTable] FROM [#ErrorLogAnalysis_ResultTableMap] ORDER BY [ResultName];
        OPEN [ResultCursor]; FETCH NEXT FROM [ResultCursor] INTO @ResultName,@TargetTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @SourceTable=CASE @ResultName WHEN N'moduleStatus' THEN N'#ErrorLogAnalysis_ModuleStatus' WHEN N'summary' THEN N'#ErrorLogAnalysis_Summary' WHEN N'details' THEN N'#ErrorLogAnalysis_Details' WHEN N'sourceStatus' THEN N'#ErrorLogAnalysis_SourceStatus' WHEN N'warnings' THEN N'#ErrorLogAnalysis_Warnings' END;
            EXEC [monitor].[InternalWriteResultTable] @SourceTable=@SourceTable,@TargetTable=@TargetTable,@ThrowOnError=1;
            FETCH NEXT FROM [ResultCursor] INTO @ResultName,@TargetTable;
        END;
        CLOSE [ResultCursor]; DEALLOCATE [ResultCursor];
    END;

    IF @MeldungstextEinbeziehen=1
    BEGIN
        DECLARE @TruncatedCount bigint=(SELECT COUNT_BIG(*) FROM [#ErrorLogAnalysis_Details] WHERE [MessageIsTruncated]=1);
        DECLARE @LargestRequired bigint=(SELECT MAX([MessageCharacters]) FROM [#ErrorLogAnalysis_Details] WHERE [MessageIsTruncated]=1);
        EXEC [monitor].[InternalEmitTruncationWarning] @TruncatedValueCount=@TruncatedCount,@ParameterName=N'@MaxMeldungszeichen',@ParameterValue=@MaxMeldungszeichen,@LargestRequiredCharacters=@LargestRequired,@PrintMeldungen=@PrintMeldungen;
    END;

    IF @PrintMeldungen=1 AND @StatusCode<>'AVAILABLE'
    BEGIN
        DECLARE @PrintMessage nvarchar(2048)=LEFT(CONCAT(N'USP_ErrorLogAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe warnings-Resultset.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;
    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,@ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
END;
GO
