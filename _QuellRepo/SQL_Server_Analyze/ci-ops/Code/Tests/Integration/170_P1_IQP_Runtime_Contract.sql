USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 170_P1_IQP_Runtime_Contract.sql
Zweck        : Prüft versionsadaptive, rücksetzbare Laufzeitverträge für die
               ersten vier P1-Fälle der Intelligent-Query-Processing-Analyse.
Datenschutz  : Ausschließlich technische Zustände der disposable synthetischen
               Actions-Datenbank; keine Laufzeitausgabe wird persistiert.
Nebenwirkung : Compatibility Level und Query-Store-Zustand werden kontrolliert
               verändert und im selben Lauf wiederhergestellt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
DECLARE @DatabaseNames nvarchar(max)=QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()));
DECLARE @OriginalCompatibility tinyint=(SELECT [compatibility_level] FROM [sys].[databases] WITH (NOLOCK) WHERE [database_id]=DB_ID());
DECLARE @OriginalQueryStoreDesired nvarchar(60)=
    (SELECT TOP(1) [desired_state_desc] FROM [sys].[database_query_store_options] WITH (NOLOCK));
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @Sql nvarchar(max);
DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);

/* IQP-2019: neuere Kataloge bleiben vor Version 16 explizit unverfügbar. */
IF @Major=15
BEGIN
    EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis]
         @DatabaseNames=@DatabaseNames,@MaxZeilen=100,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;

    IF ISJSON(@Json)<>1
       OR EXISTS
          (SELECT 1 FROM OPENJSON(@Json,N'$.databaseState')
           WITH ([PspEligible] bit N'$.PspEligible',[OppoEligible] bit N'$.OppoEligible')
           WHERE [PspEligible]<>0 OR [OppoEligible]<>0)
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.signals')
           WITH ([SignalCode] varchar(80) N'$.SignalCode',[IsSourceAvailable] bit N'$.IsSourceAvailable')
           WHERE [SignalCode] IN('QUERY_VARIANTS','PLAN_FEEDBACK') AND [IsSourceAvailable]=0)<>2
        THROW 54400,N'P1-Vertrag IQP-2019 fehlgeschlagen.',1;
END;
INSERT @ExecutedCases VALUES('IQP-2019');

/* IQP-PSP: Product Major 16+ und Compatibility Level 160. */
IF @Major>=16
BEGIN
    SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' SET COMPATIBILITY_LEVEL = 160;';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis]
         @DatabaseNames=@DatabaseNames,@MaxZeilen=100,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR NOT EXISTS
       (SELECT 1 FROM OPENJSON(@Json,N'$.databaseState')
        WITH ([CompatibilityLevel] int N'$.CompatibilityLevel',[PspEligible] bit N'$.PspEligible')
        WHERE [CompatibilityLevel]=160 AND [PspEligible]=1)
        THROW 54401,N'P1-Vertrag IQP-PSP fehlgeschlagen.',1;
END;
INSERT @ExecutedCases VALUES('IQP-PSP');

/* IQP-OPPO: Product Major 17+ und Compatibility Level 170. */
IF @Major>=17
BEGIN
    SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' SET COMPATIBILITY_LEVEL = 170;';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis]
         @DatabaseNames=@DatabaseNames,@MaxZeilen=100,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR NOT EXISTS
       (SELECT 1 FROM OPENJSON(@Json,N'$.databaseState')
        WITH ([CompatibilityLevel] int N'$.CompatibilityLevel',[OppoEligible] bit N'$.OppoEligible')
        WHERE [CompatibilityLevel]=170 AND [OppoEligible]=1)
        THROW 54402,N'P1-Vertrag IQP-OPPO fehlgeschlagen.',1;
END;
INSERT @ExecutedCases VALUES('IQP-OPPO');

/* Compatibility vor dem Query-Store-Fall wiederherstellen. */
SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' SET COMPATIBILITY_LEVEL = '
        +CONVERT(nvarchar(3),@OriginalCompatibility)+N';';
EXEC [sys].[sp_executesql] @Sql;

/* IQP-QSOFF: Query Store OFF ist ein ausdrücklicher Befund, keine leere Erfolgsevidenz. */
IF COALESCE(@OriginalQueryStoreDesired,N'OFF')<>N'OFF'
BEGIN
    SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' SET QUERY_STORE = OFF;';
    EXEC [sys].[sp_executesql] @Sql;
END;

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis]
     @DatabaseNames=@DatabaseNames,@MaxZeilen=100,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;

IF ISJSON(@Json)<>1 OR NOT EXISTS
   (SELECT 1 FROM OPENJSON(@Json,N'$.databaseState')
    WITH ([FindingCode] varchar(80) N'$.FindingCode') WHERE [FindingCode]='QUERY_STORE_OFF')
    THROW 54403,N'P1-Vertrag IQP-QSOFF fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('IQP-QSOFF');

IF @OriginalQueryStoreDesired=N'READ_WRITE'
BEGIN
    SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);';
    EXEC [sys].[sp_executesql] @Sql;
END
ELSE IF @OriginalQueryStoreDesired=N'READ_ONLY'
BEGIN
    SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' SET QUERY_STORE = ON (OPERATION_MODE = READ_ONLY);';
    EXEC [sys].[sp_executesql] @Sql;
END;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 54404,N'Der P1-IQP-Vertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier versionsadaptive P1-IQP-Fälle wurden mit rückgesetztem Datenbankzustand ausgeführt.' AS [Detail]
FROM @ExecutedCases;
GO
