USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 121_SQL25_JSON_Index_Inventory_Runtime_Contract.sql
Zweck        : Prüft SQL25-002 auf SQL Server 2019, 2022 und 2025:
               Versions- und Capabilitygrenze, sichtbare JSON-Indizes und
               SQL/JSON-Pfade, leeren beziehungsweise eingeschränkt sichtbaren
               Scope, Begrenzung, TABLE/JSON, ObjectAnalysis und das
               bestehende Spezialindex-Inventar.
Datenschutz  : Ausschließlich kurzlebige generische Example*-Objekte und
               synthetische Schemapfade. JSON-Dokumentwerte, Querytexte,
               Pläne, Zugangsdaten und externe Systeme werden nicht verwendet.
Nebenwirkung : Auf SQL Server 2025 werden PREVIEW_FEATURES und gegebenenfalls
               Compatibility Level 170 temporär aktiviert und im Erfolgs- wie
               im Fehlerpfad zurückgesetzt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ProductMajorVersion int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
DECLARE @CurrentDatabaseName sysname=
(
    SELECT [name]
    FROM [master].[sys].[databases] WITH (NOLOCK)
    WHERE [database_id]=DB_ID()
);
DECLARE @Json nvarchar(max),@ObjectJson nvarchar(max),@CapabilityJson nvarchar(max);
DECLARE @SpecialFeatureJson nvarchar(max);
DECLARE @Sql nvarchar(max);
DECLARE @OriginalCompatibilityLevel tinyint=
(
    SELECT [compatibility_level]
    FROM [master].[sys].[databases] WITH (NOLOCK)
    WHERE [database_id]=DB_ID()
);
DECLARE @PreviewConfigurationExists bit=0,@PreviewWasEnabled bit=0;
DECLARE @HasJsonIndexes bit=0,@HasJsonIndexPaths bit=0;
DECLARE @JsonIndexesSchemaValid bit=0,@JsonIndexPathsSchemaValid bit=0;
DECLARE @JsonTypeAvailable bit=0;
DECLARE @Impersonating bit=0;
DECLARE @InitialLockTimeout int=@@LOCK_TIMEOUT;
DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);

CREATE TABLE [#SQL25JSONIndexInventoryRuntimeContract_Objects]([Seed] bit NULL);

EXEC [monitor].[USP_ObjectInventory]
      @DatabaseNames=N'[DeineDatenbank]'
    , @FullObjectNames=N'[monitor].[FrameworkVersion]'
    , @ObjectType='TABLE'
    , @MitIndizes=1
    , @MaxZeilen=10
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"objects":"#SQL25JSONIndexInventoryRuntimeContract_Objects"}'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;

IF @@LOCK_TIMEOUT<>@InitialLockTimeout
    THROW 55732,N'SQL25-002 ObjectInventory stellt LOCK_TIMEOUT nicht wieder her.',1;
IF ISJSON(@Json)<>1
   OR NOT EXISTS(SELECT 1 FROM [#SQL25JSONIndexInventoryRuntimeContract_Objects])
   OR NOT EXISTS
      (
          SELECT 1
          FROM OPENJSON(@Json,N'$.objects')
          WITH
          (
                [IsJsonIndex] bit N'$.IsJsonIndex'
              , [JsonPaths] nvarchar(max) N'$.JsonPaths'
              , [JsonIndexStatusCode] varchar(40) N'$.JsonIndexStatusCode'
          )
          WHERE [IsJsonIndex] IS NOT NULL
            AND [JsonIndexStatusCode] IS NOT NULL
      )
    THROW 55720,N'SQL25-002 TABLE-/JSON-Grundvertrag fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('NAMED-TABLE-OUTPUT');

SET @ObjectJson=NULL;
EXEC [monitor].[USP_ObjectAnalysis]
      @DatabaseNames=N'[DeineDatenbank]'
    , @FullObjectNames=N'[monitor].[FrameworkVersion]'
    , @MitIndexUsage=0
    , @MitMissingIndexes=0
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@ObjectJson OUTPUT
    , @PrintMeldungen=0;

IF @@LOCK_TIMEOUT<>@InitialLockTimeout
    THROW 55733,N'SQL25-002 ObjectAnalysis stellt LOCK_TIMEOUT nicht wieder her.',1;
IF ISJSON(@ObjectJson)<>1
   OR JSON_QUERY(@ObjectJson,N'$.objectInventory.objects') IS NULL
    THROW 55721,N'SQL25-002 ObjectAnalysis-Routing fehlt.',1;
INSERT @ExecutedCases VALUES('OBJECT-ANALYSIS-ROUTING');

SET @CapabilityJson=NULL;
EXEC [monitor].[USP_ServerFeatureCapabilities]
      @DatabaseNames=N'[DeineDatenbank]'
    , @MitSpezialindizes=1
    , @MitQueryStoreReplicas=0
    , @MitPlattformdetails=0
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@CapabilityJson OUTPUT
    , @PrintMeldungen=0;

IF @@LOCK_TIMEOUT<>@InitialLockTimeout
    THROW 55734,N'SQL25-002 ServerFeatureCapabilities stellt LOCK_TIMEOUT nicht wieder her.',1;
IF ISJSON(@CapabilityJson)<>1
   OR NOT EXISTS
      (
          SELECT 1
          FROM OPENJSON(@CapabilityJson,N'$.databaseFeatures')
          WITH
          (
                [FeatureName] nvarchar(128) N'$.FeatureName'
              , [AvailabilityStatus] varchar(40) N'$.AvailabilityStatus'
          )
          WHERE [FeatureName]=N'JSON_INDEX_METADATA'
      )
    THROW 55722,N'SQL25-002 Capability-Inventar fehlt.',1;
INSERT @ExecutedCases VALUES('CAPABILITY-INVENTORY');

EXEC [monitor].[USP_SpecialFeatureInventory]
      @DatabaseNames=N'[DeineDatenbank]'
    , @NurErkannteFeatures=0
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@SpecialFeatureJson OUTPUT
    , @PrintMeldungen=0;

IF @@LOCK_TIMEOUT<>@InitialLockTimeout
    THROW 55735,N'SQL25-002 SpecialFeatureInventory stellt LOCK_TIMEOUT nicht wieder her.',1;
IF ISJSON(@SpecialFeatureJson)<>1
   OR NOT EXISTS
      (
          SELECT 1
          FROM OPENJSON(@SpecialFeatureJson,N'$.features')
          WITH
          (
                [FeatureCode] varchar(40) N'$.FeatureCode'
              , [RecommendedModule] sysname N'$.RecommendedModule'
              , [RecommendedModuleStatus] varchar(40) N'$.RecommendedModuleStatus'
          )
          WHERE [FeatureCode]='JSON_NATIVE'
            AND [RecommendedModule]=N'USP_ObjectInventory'
            AND [RecommendedModuleStatus]='IMPLEMENTED'
      )
    THROW 55736,N'SQL25-002 SpecialFeatureInventory-Routing fehlt.',1;
INSERT @ExecutedCases VALUES('SPECIAL-FEATURE-ROUTING');

IF @ProductMajorVersion IS NULL OR @ProductMajorVersion<17
BEGIN
    IF EXISTS
       (
           SELECT 1
           FROM [#SQL25JSONIndexInventoryRuntimeContract_Objects]
           WHERE [JsonIndexStatusCode]<>'UNAVAILABLE_VERSION'
       )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.databaseStatus')
              WITH ([JsonIndexStatusCode] varchar(40) N'$.JsonIndexStatusCode')
              WHERE [JsonIndexStatusCode]='UNAVAILABLE_VERSION'
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@CapabilityJson,N'$.databaseFeatures')
              WITH
              (
                    [FeatureName] nvarchar(128) N'$.FeatureName'
                  , [AvailabilityStatus] varchar(40) N'$.AvailabilityStatus'
              )
              WHERE [FeatureName]=N'JSON_INDEX_METADATA'
                AND [AvailabilityStatus]='UNAVAILABLE_VERSION'
          )
        THROW 55723,N'SQL25-002 Versionsgrenze auf SQL Server 2019/2022 fehlgeschlagen.',1;

    INSERT @ExecutedCases VALUES('UNAVAILABLE-VERSION');
    SELECT
          CAST('AVAILABLE' AS varchar(40)) [StatusCode]
        , CAST(0 AS bit) [IsPartial]
        , @ProductMajorVersion [ProductMajorVersion]
        , (SELECT COUNT_BIG(*) FROM @ExecutedCases) [ExecutedCases]
        , N'SQL25-002 Versions-, TABLE-, Capability- und Orchestratorvertrag bestanden.' [Detail];
    RETURN;
END;

BEGIN TRY
    IF @OriginalCompatibilityLevel<170
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CurrentDatabaseName)
                +N' SET COMPATIBILITY_LEVEL=170;';
        EXEC [sys].[sp_executesql] @Sql;
    END;

    SELECT @PreviewConfigurationExists=CONVERT(bit,CASE WHEN EXISTS
    (
        SELECT 1
        FROM [sys].[database_scoped_configurations] WITH (NOLOCK)
        WHERE [name]=N'PREVIEW_FEATURES'
    ) THEN 1 ELSE 0 END);
    IF @PreviewConfigurationExists=1
    BEGIN
        SELECT @PreviewWasEnabled=COALESCE(TRY_CONVERT(bit,[value]),0)
        FROM [sys].[database_scoped_configurations] WITH (NOLOCK)
        WHERE [name]=N'PREVIEW_FEATURES';
        IF @PreviewWasEnabled=0
            EXEC [sys].[sp_executesql]
                 N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=ON;';
    END;

    SELECT
          @HasJsonIndexes=CONVERT(bit,CASE WHEN EXISTS
          (
              SELECT 1
              FROM [sys].[all_objects] AS [o] WITH (NOLOCK)
              INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                 ON [s].[schema_id]=[o].[schema_id]
              WHERE [s].[name]=N'sys' AND [o].[name]=N'json_indexes'
          ) THEN 1 ELSE 0 END)
        , @HasJsonIndexPaths=CONVERT(bit,CASE WHEN EXISTS
          (
              SELECT 1
              FROM [sys].[all_objects] AS [o] WITH (NOLOCK)
              INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                 ON [s].[schema_id]=[o].[schema_id]
              WHERE [s].[name]=N'sys' AND [o].[name]=N'json_index_paths'
          ) THEN 1 ELSE 0 END);

    SELECT @JsonIndexesSchemaValid=CONVERT(bit,CASE
        WHEN @HasJsonIndexes=1 AND
             (
                 SELECT COUNT(DISTINCT [c].[name])
                 FROM [sys].[all_columns] AS [c] WITH (NOLOCK)
                 INNER JOIN [sys].[all_objects] AS [o] WITH (NOLOCK)
                    ON [o].[object_id]=[c].[object_id]
                 INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                    ON [s].[schema_id]=[o].[schema_id]
                 WHERE [s].[name]=N'sys' AND [o].[name]=N'json_indexes'
                   AND [c].[name] IN
                       (N'object_id',N'index_id',N'name',N'is_disabled',N'optimize_for_array_search')
             )=5 THEN 1 ELSE 0 END);

    SELECT @JsonIndexPathsSchemaValid=CONVERT(bit,CASE
        WHEN @HasJsonIndexPaths=1 AND
             (
                 SELECT COUNT(DISTINCT [c].[name])
                 FROM [sys].[all_columns] AS [c] WITH (NOLOCK)
                 INNER JOIN [sys].[all_objects] AS [o] WITH (NOLOCK)
                    ON [o].[object_id]=[c].[object_id]
                 INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                    ON [s].[schema_id]=[o].[schema_id]
                 WHERE [s].[name]=N'sys' AND [o].[name]=N'json_index_paths'
                   AND [c].[name] IN (N'object_id',N'index_id',N'path')
             )=3 THEN 1 ELSE 0 END);

    SELECT @JsonTypeAvailable=CONVERT(bit,CASE WHEN EXISTS
    (
        SELECT 1
        FROM [sys].[types] WITH (NOLOCK)
        WHERE [name]=N'json' AND [is_user_defined]=0
    ) THEN 1 ELSE 0 END);

    IF @HasJsonIndexes=0 OR @JsonIndexesSchemaValid=0
       OR @HasJsonIndexPaths=0 OR @JsonIndexPathsSchemaValid=0
       OR @JsonTypeAvailable=0
    BEGIN
        SET @Json=NULL;
        EXEC [monitor].[USP_ObjectInventory]
              @DatabaseNames=N'[DeineDatenbank]'
            , @FullObjectNames=N'[monitor].[FrameworkVersion]'
            , @ObjectType='TABLE'
            , @MitIndizes=1
            , @ResultSetArt='NONE'
            , @JsonErzeugen=1
            , @Json=@Json OUTPUT
            , @PrintMeldungen=0;
        IF ISJSON(@Json)<>1
           OR NOT EXISTS
              (
                  SELECT 1
                  FROM OPENJSON(@Json,N'$.databaseStatus')
                  WITH ([JsonIndexStatusCode] varchar(40) N'$.JsonIndexStatusCode')
                  WHERE [JsonIndexStatusCode] IN
                        ('UNAVAILABLE_FEATURE','UNAVAILABLE_SOURCE_SCHEMA','AVAILABLE_LIMITED')
              )
            THROW 55724,N'SQL25-002 fehlende Previewquelle wird nicht explizit ausgewiesen.',1;
        INSERT @ExecutedCases VALUES('FEATURE-UNAVAILABLE-EXPLICIT');
        GOTO SuccessfulCleanup;
    END;

    DROP TABLE IF EXISTS [dbo].[ExampleJsonIndexA];
    DROP TABLE IF EXISTS [dbo].[ExampleJsonIndexB];
    IF USER_ID(N'ExampleJsonRestrictedUser') IS NOT NULL
        DROP USER [ExampleJsonRestrictedUser];

    SET @Sql=N'
CREATE TABLE [dbo].[ExampleJsonIndexA]
(
      [Id] int NOT NULL CONSTRAINT [PK_ExampleJsonIndexA] PRIMARY KEY CLUSTERED
    , [Payload] json NOT NULL
);
CREATE TABLE [dbo].[ExampleJsonIndexB]
(
      [Id] int NOT NULL CONSTRAINT [PK_ExampleJsonIndexB] PRIMARY KEY CLUSTERED
    , [Payload] json NOT NULL
);
CREATE JSON INDEX [IX_ExampleJsonIndexA]
ON [dbo].[ExampleJsonIndexA]([Payload])
FOR (''$.propertyA'',''$.propertyB'')
WITH (OPTIMIZE_FOR_ARRAY_SEARCH=ON);
CREATE JSON INDEX [IX_ExampleJsonIndexB]
ON [dbo].[ExampleJsonIndexB]([Payload]);';
    EXEC [sys].[sp_executesql] @Sql;

    SET @Json=NULL;
    EXEC [monitor].[USP_ObjectInventory]
          @DatabaseNames=N'[DeineDatenbank]'
        , @FullObjectNames=N'[dbo].[ExampleJsonIndexA]'
        , @ObjectType='TABLE'
        , @MitIndizes=1
        , @MaxZeilen=10
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@Json OUTPUT
        , @PrintMeldungen=0;

    IF ISJSON(@Json)<>1
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.objects')
              WITH
              (
                    [IndexName] sysname N'$.IndexName'
                  , [IsJsonIndex] bit N'$.IsJsonIndex'
                  , [OptimizeForArraySearch] bit N'$.OptimizeForArraySearch'
                  , [JsonPathCount] bigint N'$.JsonPathCount'
                  , [JsonPaths] nvarchar(max) N'$.JsonPaths'
                  , [JsonIndexStatusCode] varchar(40) N'$.JsonIndexStatusCode'
              )
              WHERE [IndexName]=N'IX_ExampleJsonIndexA'
                AND [IsJsonIndex]=1
                AND [OptimizeForArraySearch]=1
                AND [JsonPathCount]=2
                AND [JsonPaths] LIKE N'%$.propertyA%'
                AND [JsonPaths] LIKE N'%$.propertyB%'
                AND [JsonIndexStatusCode]='AVAILABLE'
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.databaseStatus')
              WITH
              (
                    [JsonIndexStatusCode] varchar(40) N'$.JsonIndexStatusCode'
                  , [JsonIndexRowCount] bigint N'$.JsonIndexRowCount'
                  , [JsonPathRowCount] bigint N'$.JsonPathRowCount'
              )
              WHERE [JsonIndexStatusCode]='AVAILABLE'
                AND [JsonIndexRowCount]=1
                AND [JsonPathRowCount]=2
          )
        THROW 55726,N'SQL25-002 sichtbarer JSON-Index-/Pfadvertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('VISIBLE-INDEX-AND-PATHS');

    SET @Json=NULL;
    EXEC [monitor].[USP_ObjectInventory]
          @DatabaseNames=N'[DeineDatenbank]'
        , @FullObjectNames=N'[dbo].[ExampleJsonIndexA]|[dbo].[ExampleJsonIndexB]'
        , @ObjectType='TABLE'
        , @MitIndizes=1
        , @MaxZeilen=1
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@Json OUTPUT
        , @PrintMeldungen=0;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.objects'))<>1
        THROW 55727,N'SQL25-002 Begrenzungsvertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BOUNDED-OUTPUT');

    SET @CapabilityJson=NULL;
    EXEC [monitor].[USP_ServerFeatureCapabilities]
          @DatabaseNames=N'[DeineDatenbank]'
        , @MitSpezialindizes=1
        , @MitQueryStoreReplicas=0
        , @MitPlattformdetails=0
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@CapabilityJson OUTPUT
        , @PrintMeldungen=0;
    IF NOT EXISTS
       (
           SELECT 1
           FROM OPENJSON(@CapabilityJson,N'$.specialIndexes')
           WITH
           (
                 [IndexName] sysname N'$.IndexName'
               , [IndexFamily] nvarchar(60) N'$.IndexFamily'
               , [IndexDetails] nvarchar(2000) N'$.IndexDetails'
               , [AvailabilityStatus] varchar(40) N'$.AvailabilityStatus'
           )
           WHERE [IndexName]=N'IX_ExampleJsonIndexA'
             AND [IndexFamily]=N'JSON'
             AND [IndexDetails] LIKE N'%path_count=2%'
             AND [AvailabilityStatus]='AVAILABLE'
       )
        THROW 55728,N'SQL25-002 Spezialindex-Inventarvertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('SPECIAL-INDEX-INVENTORY');

    SET @Json=NULL;
    EXEC [monitor].[USP_ObjectInventory]
          @DatabaseNames=N'[DeineDatenbank]'
        , @FullObjectNames=N'[dbo].[ExampleJsonDoesNotExist]'
        , @ObjectType='TABLE'
        , @MitIndizes=1
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@Json OUTPUT
        , @PrintMeldungen=0;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.objects'))<>0
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.databaseStatus')
              WITH ([JsonIndexStatusCode] varchar(40) N'$.JsonIndexStatusCode')
              WHERE [JsonIndexStatusCode]='AVAILABLE_EMPTY_OR_RESTRICTED'
          )
        THROW 55729,N'SQL25-002 Leer-/Sichtbarkeitsgrenze fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('EMPTY-VISIBLE-SCOPE');

    CREATE USER [ExampleJsonRestrictedUser] WITHOUT LOGIN;
    GRANT EXECUTE ON [monitor].[USP_ObjectInventory] TO [ExampleJsonRestrictedUser];
    DENY VIEW DEFINITION TO [ExampleJsonRestrictedUser];
    SET @Json=NULL;
    EXECUTE AS USER=N'ExampleJsonRestrictedUser';
    SET @Impersonating=1;
    EXEC [monitor].[USP_ObjectInventory]
          @DatabaseNames=N'[DeineDatenbank]'
        , @FullObjectNames=N'[dbo].[ExampleJsonIndexA]'
        , @ObjectType='TABLE'
        , @MitIndizes=1
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1
        , @Json=@Json OUTPUT
        , @PrintMeldungen=0;
    REVERT;
    SET @Impersonating=0;

    IF ISJSON(@Json)<>1
       OR EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.objects')
              WITH ([IndexName] sysname N'$.IndexName')
              WHERE [IndexName]=N'IX_ExampleJsonIndexA'
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.databaseStatus')
              WITH
              (
                    [StatusCode] varchar(40) N'$.StatusCode'
                  , [JsonIndexStatusCode] varchar(40) N'$.JsonIndexStatusCode'
              )
              WHERE [StatusCode] IN
                    ('AVAILABLE','AVAILABLE_LIMITED','DENIED_PERMISSION','PARTIAL')
                AND [JsonIndexStatusCode] IN
                    ('AVAILABLE_EMPTY_OR_RESTRICTED','DENIED_PERMISSION',
                     'UNAVAILABLE_SOURCE_SCHEMA','ERROR_HANDLED')
          )
        THROW 55730,N'SQL25-002 eingeschränkte Metadata Visibility wird nicht explizit begrenzt.',1;
    INSERT @ExecutedCases VALUES('RESTRICTED-METADATA');

SuccessfulCleanup:
    IF @Impersonating=1
    BEGIN
        REVERT;
        SET @Impersonating=0;
    END;
    IF USER_ID(N'ExampleJsonRestrictedUser') IS NOT NULL
        DROP USER [ExampleJsonRestrictedUser];
    DROP TABLE IF EXISTS [dbo].[ExampleJsonIndexA];
    DROP TABLE IF EXISTS [dbo].[ExampleJsonIndexB];
    IF @PreviewConfigurationExists=1 AND @PreviewWasEnabled=0
        EXEC [sys].[sp_executesql]
             N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=OFF;';
    IF @OriginalCompatibilityLevel<170
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CurrentDatabaseName)
                +N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(3),@OriginalCompatibilityLevel)+N';';
        EXEC [sys].[sp_executesql] @Sql;
    END;
END TRY
BEGIN CATCH
    DECLARE @CatchMessage nvarchar(2048)=ERROR_MESSAGE();
    IF @Impersonating=1
    BEGIN TRY
        REVERT;
        SET @Impersonating=0;
    END TRY
    BEGIN CATCH
    END CATCH;
    BEGIN TRY
        IF USER_ID(N'ExampleJsonRestrictedUser') IS NOT NULL
            DROP USER [ExampleJsonRestrictedUser];
        DROP TABLE IF EXISTS [dbo].[ExampleJsonIndexA];
        DROP TABLE IF EXISTS [dbo].[ExampleJsonIndexB];
        IF @PreviewConfigurationExists=1 AND @PreviewWasEnabled=0
            EXEC [sys].[sp_executesql]
                 N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=OFF;';
        IF @OriginalCompatibilityLevel<170
        BEGIN
            SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CurrentDatabaseName)
                    +N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(3),@OriginalCompatibilityLevel)+N';';
            EXEC [sys].[sp_executesql] @Sql;
        END;
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW 55731,@CatchMessage,1;
END CATCH;

SELECT
      CAST('AVAILABLE' AS varchar(40)) [StatusCode]
    , CAST(0 AS bit) [IsPartial]
    , @ProductMajorVersion [ProductMajorVersion]
    , (SELECT COUNT_BIG(*) FROM @ExecutedCases) [ExecutedCases]
    , CASE
          WHEN EXISTS(SELECT 1 FROM @ExecutedCases WHERE [CaseId]='VISIBLE-INDEX-AND-PATHS')
          THEN N'SQL25-002 aktiver JSON-Index-/Pfadvertrag bestanden.'
          ELSE N'SQL25-002 capability-adaptive Previewgrenze bestanden.'
      END [Detail];
GO
