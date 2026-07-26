USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 120_SQL25_Vector_Index_Runtime_Contract.sql
Zweck        : Prüft SQL25-001 auf SQL Server 2019, 2022 und 2025:
               versionssichere Nichtverfügbarkeit, aktiven Katalog- und
               Wartungszustand, leere und begrenzte Ausgabe, Cross-Database,
               verweigerte DMV-Berechtigung, TABLE/JSON und ObjectAnalysis.
Datenschutz  : Ausschließlich kurzlebige generische Example*-Objekte und
               deterministische synthetische Vector-Werte. Keine produktiven
               Werte, Querytexte, Pläne, Buildparameter oder externe Systeme.
Nebenwirkung : Auf SQL Server 2025 werden PREVIEW_FEATURES und gegebenenfalls
               Compatibility Level 170 temporär aktiviert und im Erfolgs- wie
               im Fehlerpfad auf den vorherigen Stand zurückgesetzt.
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
DECLARE @EmptyDatabaseName sysname=N'ExampleVectorEmptyDatabase';
DECLARE @Json nvarchar(max),@ObjectJson nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @ErrorNumber int,@ErrorMessage nvarchar(2048),@Sql nvarchar(max);
DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);

CREATE TABLE [#SQL25VectorIndexRuntimeContract_ModuleStatus]([Seed] bit NULL);
CREATE TABLE [#SQL25VectorIndexRuntimeContract_VectorIndexes]([Seed] bit NULL);
CREATE TABLE [#SQL25VectorIndexRuntimeContract_Maintenance]([Seed] bit NULL);
CREATE TABLE [#SQL25VectorIndexRuntimeContract_Findings]([Seed] bit NULL);
CREATE TABLE [#SQL25VectorIndexRuntimeContract_SourceStatus]([Seed] bit NULL);
CREATE TABLE [#SQL25VectorIndexRuntimeContract_Warnings]([Seed] bit NULL);

EXEC [monitor].[USP_VectorIndexAnalysis]
      @DatabaseNames=N'[DeineDatenbank]'
    , @MaxZeilen=10
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"moduleStatus":"#SQL25VectorIndexRuntimeContract_ModuleStatus","vectorIndexes":"#SQL25VectorIndexRuntimeContract_VectorIndexes","maintenance":"#SQL25VectorIndexRuntimeContract_Maintenance","findings":"#SQL25VectorIndexRuntimeContract_Findings","sourceStatus":"#SQL25VectorIndexRuntimeContract_SourceStatus","warnings":"#SQL25VectorIndexRuntimeContract_Warnings"}'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@Status OUTPUT
    , @IsPartialOut=@Partial OUTPUT
    , @ErrorNumberOut=@ErrorNumber OUTPUT
    , @ErrorMessageOut=@ErrorMessage OUTPUT;

IF ISJSON(@Json)<>1
   OR (SELECT COUNT_BIG(*) FROM [#SQL25VectorIndexRuntimeContract_ModuleStatus])<>1
   OR (SELECT COUNT_BIG(*) FROM [#SQL25VectorIndexRuntimeContract_SourceStatus])<>2
    THROW 55700,N'SQL25-001 TABLE-/JSON-Grundvertrag fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('NAMED-TABLE-OUTPUT');

SET @ObjectJson=NULL;
EXEC [monitor].[USP_ObjectAnalysis]
      @DatabaseNames=N'[DeineDatenbank]'
    , @MitObjectInventory=0
    , @MitIndexUsage=0
    , @MitMissingIndexes=0
    , @MitVectorIndexes=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@ObjectJson OUTPUT
    , @PrintMeldungen=0;
IF ISJSON(@ObjectJson)<>1 OR JSON_QUERY(@ObjectJson,N'$.vectorIndexAnalysis') IS NULL
    THROW 55701,N'SQL25-001 ObjectAnalysis-Routing fehlt.',1;
INSERT @ExecutedCases VALUES('OBJECT-ANALYSIS-ROUTING');

IF @ProductMajorVersion IS NULL OR @ProductMajorVersion<17
BEGIN
    IF @Status<>'UNAVAILABLE_VERSION' OR @Partial<>0
       OR EXISTS
          (
              SELECT 1
              FROM [#SQL25VectorIndexRuntimeContract_SourceStatus]
              WHERE [StatusCode]<>'UNAVAILABLE_VERSION'
          )
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.vectorIndexes'))<>0
        THROW 55702,N'SQL25-001 Versionsgrenze auf SQL Server 2019/2022 fehlgeschlagen.',1;

    INSERT @ExecutedCases VALUES('UNAVAILABLE-VERSION');
    SELECT CAST('AVAILABLE' AS varchar(40)) [StatusCode],CAST(0 AS bit) [IsPartial],
           @ProductMajorVersion [ProductMajorVersion],
           (SELECT COUNT_BIG(*) FROM @ExecutedCases) [ExecutedCases],
           N'SQL25-001 Versions-, TABLE- und Orchestratorvertrag bestanden.' [Detail];
    RETURN;
END;

DECLARE @HasVectorCatalog bit=0,@HasVectorRuntime bit=0;
DECLARE @OriginalCompatibilityLevel tinyint=
(
    SELECT [compatibility_level]
    FROM [master].[sys].[databases] WITH (NOLOCK)
    WHERE [database_id]=DB_ID()
);
DECLARE @PreviewWasEnabled bit=
(
    SELECT TRY_CONVERT(bit,[value])
    FROM [sys].[database_scoped_configurations] WITH (NOLOCK)
    WHERE [name]=N'PREVIEW_FEATURES'
);
DECLARE @Impersonating bit=0;

BEGIN TRY
    IF @OriginalCompatibilityLevel<170
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CurrentDatabaseName)+N' SET COMPATIBILITY_LEVEL=170;';
        EXEC [sys].[sp_executesql] @Sql;
    END;
    IF COALESCE(@PreviewWasEnabled,0)=0
        EXEC [sys].[sp_executesql] N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=ON;';

    SELECT @HasVectorCatalog=CONVERT(bit,CASE WHEN EXISTS
    (
        SELECT 1
        FROM [sys].[all_objects] AS [o] WITH (NOLOCK)
        INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
        WHERE [s].[name]=N'sys' AND [o].[name]=N'vector_indexes'
    ) THEN 1 ELSE 0 END);
    SELECT @HasVectorRuntime=CONVERT(bit,CASE WHEN EXISTS
    (
        SELECT 1
        FROM [sys].[all_objects] AS [o] WITH (NOLOCK)
        INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
        WHERE [s].[name]=N'sys' AND [o].[name]=N'dm_db_vector_indexes'
    ) THEN 1 ELSE 0 END);

    IF @HasVectorCatalog<>1 OR @HasVectorRuntime<>1
    BEGIN
        SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
        EXEC [monitor].[USP_VectorIndexAnalysis]
              @DatabaseNames=N'[DeineDatenbank]'
            , @ResultSetArt='NONE'
            , @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0
            , @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
        IF ISJSON(@Json)<>1
           OR @Status IS NULL
           OR @Status NOT IN('UNAVAILABLE_FEATURE','UNAVAILABLE_SOURCE_SCHEMA','AVAILABLE_LIMITED','NOT_APPLICABLE')
           OR COALESCE(CONVERT(int,@Partial),-1)<>CASE WHEN @Status IN('UNAVAILABLE_SOURCE_SCHEMA','AVAILABLE_LIMITED') THEN 1 ELSE 0 END
           OR NOT EXISTS
              (
                  SELECT 1
                  FROM OPENJSON(@Json,N'$.sourceStatus')
                  WITH ([StatusCode] varchar(40) N'$.StatusCode')
                  WHERE [StatusCode] IN('UNAVAILABLE_FEATURE','UNAVAILABLE_SOURCE_SCHEMA')
              )
        BEGIN
            DECLARE @CapabilityDetail nvarchar(2048)=
            (
                SELECT CONCAT
                (
                      N'SQL25-001 Capability-Status unerwartet: module=',COALESCE(@Status,'NULL')
                    , N'; partial=',COALESCE(CONVERT(varchar(1),@Partial),'NULL')
                    , N'; catalogObject=',CONVERT(varchar(1),@HasVectorCatalog)
                    , N'; runtimeObject=',CONVERT(varchar(1),@HasVectorRuntime)
                    , N'; sources='
                    , COALESCE
                      (
                          STRING_AGG
                          (
                              CONCAT
                              (
                                    [SourceName],N'/',[StatusCode],N'/',CONVERT(varchar(1),[IsPartial])
                                  , N'/error=',COALESCE(CONVERT(varchar(12),[ErrorNumber]),'NULL')
                                  , N':',COALESCE(LEFT([ErrorMessage],512),N'NULL')
                              ),
                              N','
                          ),
                          N'NONE'
                      )
                )
                FROM OPENJSON(@Json,N'$.sourceStatus')
                WITH
                (
                      [SourceName] sysname N'$.SourceName'
                    , [StatusCode] varchar(40) N'$.StatusCode'
                    , [IsPartial] bit N'$.IsPartial'
                    , [ErrorNumber] int N'$.ErrorNumber'
                    , [ErrorMessage] nvarchar(2048) N'$.ErrorMessage'
                )
            );
            THROW 55703,@CapabilityDetail,1;
        END;

        INSERT @ExecutedCases VALUES('FEATURE-UNAVAILABLE-EXPLICIT');
        IF COALESCE(@PreviewWasEnabled,0)=0
            EXEC [sys].[sp_executesql] N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=OFF;';
        IF @OriginalCompatibilityLevel<170
        BEGIN
            SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CurrentDatabaseName)+N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(3),@OriginalCompatibilityLevel)+N';';
            EXEC [sys].[sp_executesql] @Sql;
        END;

        SELECT CAST(@Status AS varchar(40)) [StatusCode],@Partial [IsPartial],
               @ProductMajorVersion [ProductMajorVersion],
               (SELECT COUNT_BIG(*) FROM @ExecutedCases) [ExecutedCases],
               N'SQL25-001 Featuregrenze, TABLE/JSON und Orchestratorvertrag bestanden; der Build stellt den optionalen Previewpfad nicht bereit.' [Detail];
        RETURN;
    END;

    DROP TABLE IF EXISTS [dbo].[ExampleVectorRuntimeA];
    DROP TABLE IF EXISTS [dbo].[ExampleVectorRuntimeB];
    IF USER_ID(N'ExampleVectorRestrictedUser') IS NOT NULL DROP USER [ExampleVectorRestrictedUser];
    IF EXISTS
       (
           SELECT 1 FROM [master].[sys].[databases] WITH (NOLOCK)
           WHERE [name]=@EmptyDatabaseName COLLATE SQL_Latin1_General_CP1_CS_AS
       )
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@EmptyDatabaseName)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@EmptyDatabaseName)+N';';
        EXEC [sys].[sp_executesql] @Sql;
    END;

    SET @Sql=N'
CREATE TABLE [dbo].[ExampleVectorRuntimeA]
(
      [Id] int NOT NULL CONSTRAINT [PK_ExampleVectorRuntimeA] PRIMARY KEY CLUSTERED
    , [Embedding] vector(5) NOT NULL
);
CREATE TABLE [dbo].[ExampleVectorRuntimeB]
(
      [Id] int NOT NULL CONSTRAINT [PK_ExampleVectorRuntimeB] PRIMARY KEY CLUSTERED
    , [Embedding] vector(5) NOT NULL
);
;WITH [n] AS
(
    SELECT TOP(100) ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) [n]
    FROM [sys].[all_objects] AS [a] WITH (NOLOCK)
    CROSS JOIN [sys].[all_objects] AS [b] WITH (NOLOCK)
)
INSERT [dbo].[ExampleVectorRuntimeA]([Id],[Embedding])
SELECT [n],CAST(JSON_ARRAY(CONVERT(float,[n])*0.001,CONVERT(float,[n])*0.002,
                           CONVERT(float,[n])*0.003,CONVERT(float,[n])*0.004,
                           CONVERT(float,[n])*0.005) AS vector(5))
FROM [n];
;WITH [n] AS
(
    SELECT TOP(100) ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) [n]
    FROM [sys].[all_objects] AS [a] WITH (NOLOCK)
    CROSS JOIN [sys].[all_objects] AS [b] WITH (NOLOCK)
)
INSERT [dbo].[ExampleVectorRuntimeB]([Id],[Embedding])
SELECT [n],CAST(JSON_ARRAY(CONVERT(float,[n])*0.006,CONVERT(float,[n])*0.007,
                           CONVERT(float,[n])*0.008,CONVERT(float,[n])*0.009,
                           CONVERT(float,[n])*0.010) AS vector(5))
FROM [n];
CREATE VECTOR INDEX [IX_ExampleVectorRuntimeA] ON [dbo].[ExampleVectorRuntimeA]([Embedding])
WITH (METRIC=''cosine'',TYPE=''diskann'',MAXDOP=1);
CREATE VECTOR INDEX [IX_ExampleVectorRuntimeB] ON [dbo].[ExampleVectorRuntimeB]([Embedding])
WITH (METRIC=''cosine'',TYPE=''diskann'',MAXDOP=1);';
    EXEC [sys].[sp_executesql] @Sql;

    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@EmptyDatabaseName)+N' COLLATE SQL_Latin1_General_CP1_CS_AS;';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@EmptyDatabaseName)+N' SET COMPATIBILITY_LEVEL=170;';
    EXEC [sys].[sp_executesql] @Sql;

    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_VectorIndexAnalysis]
          @DatabaseNames=N'[DeineDatenbank]'
        , @FullObjectNames=N'[dbo].[ExampleVectorRuntimeA]'
        , @IndexNames=N'[IX_ExampleVectorRuntimeA]'
        , @ResultSetArt='NONE'
        , @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0
        , @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
    IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING')
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.vectorIndexes'))<>1
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.vectorIndexes')
              WITH ([IndexName] sysname N'$.IndexName',[CatalogStatusCode] varchar(40) N'$.CatalogStatusCode')
              WHERE [IndexName]=N'IX_ExampleVectorRuntimeA' AND [CatalogStatusCode]='AVAILABLE'
          )
        THROW 55704,N'SQL25-001 aktiver Katalogvertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('FEATURE-ACTIVE');

    IF NOT EXISTS
       (
           SELECT 1
           FROM OPENJSON(@Json,N'$.maintenance')
           WITH ([IndexName] sysname N'$.IndexName',[StatusCode] varchar(40) N'$.StatusCode')
           WHERE [IndexName]=N'IX_ExampleVectorRuntimeA' AND [StatusCode]='AVAILABLE'
       )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.sourceStatus')
              WITH ([SourceName] sysname N'$.SourceName',[StatusCode] varchar(40) N'$.StatusCode')
              WHERE [SourceName]=N'vectorRuntime' AND [StatusCode]='AVAILABLE'
          )
        THROW 55705,N'SQL25-001 aktiver Wartungsvertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('MAINTENANCE-VISIBLE');

    SET @Json=NULL; SET @Status=NULL;
    EXEC [monitor].[USP_VectorIndexAnalysis]
          @DatabaseNames=N'[DeineDatenbank]'
        , @IndexNames=N'[IX_ExampleVectorDoesNotExist]'
        , @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0
        , @StatusCodeOut=@Status OUTPUT;
    IF ISJSON(@Json)<>1 OR @Status<>'NOT_APPLICABLE'
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.vectorIndexes'))<>0
        THROW 55706,N'SQL25-001 Empty-Filtervertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('EMPTY-FILTER');

    SET @Json=NULL; SET @Status=NULL;
    EXEC [monitor].[USP_VectorIndexAnalysis]
          @DatabaseNames=N'[DeineDatenbank]'
        , @MaxZeilen=1
        , @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0
        , @StatusCodeOut=@Status OUTPUT;
    IF ISJSON(@Json)<>1
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.vectorIndexes'))<>1
       OR LOWER(JSON_VALUE(@Json,N'$.meta.hasMoreVectorIndexRows'))<>N'true'
        THROW 55707,N'SQL25-001 Begrenzungsvertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BOUNDED-OUTPUT');

    DECLARE @CrossDatabaseNames nvarchar(max)=CONCAT(QUOTENAME(@CurrentDatabaseName),N'|',QUOTENAME(@EmptyDatabaseName));
    SET @Json=NULL; SET @Status=NULL;
    EXEC [monitor].[USP_VectorIndexAnalysis]
          @DatabaseNames=@CrossDatabaseNames
        , @HighImpactConfirmed=1
        , @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0
        , @StatusCodeOut=@Status OUTPUT;
    IF ISJSON(@Json)<>1
       OR (SELECT COUNT(DISTINCT [DatabaseName])
           FROM OPENJSON(@Json,N'$.sourceStatus')
           WITH ([DatabaseName] sysname N'$.DatabaseName'))<>2
        THROW 55708,N'SQL25-001 Cross-Database-Vertrag fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('CROSS-DATABASE');

    IF NOT EXISTS
       (
           SELECT 1
           FROM OPENJSON(@Json,N'$.sourceStatus')
           WITH ([DatabaseName] sysname N'$.DatabaseName',[SourceName] sysname N'$.SourceName',[StatusCode] varchar(40) N'$.StatusCode')
           WHERE [DatabaseName]=@EmptyDatabaseName AND [SourceName]=N'vectorCatalog'
             AND [StatusCode] IN('NOT_ENABLED','AVAILABLE_EMPTY')
       )
        THROW 55709,N'SQL25-001 Nicht-aktivierter Featurevertrag fehlt.',1;
    INSERT @ExecutedCases VALUES('FEATURE-NOT-ENABLED');

    CREATE USER [ExampleVectorRestrictedUser] WITHOUT LOGIN;
    GRANT EXECUTE ON SCHEMA::[monitor] TO [ExampleVectorRestrictedUser];
    GRANT SELECT ON OBJECT::[dbo].[ExampleVectorRuntimeA] TO [ExampleVectorRestrictedUser];
    GRANT SELECT ON OBJECT::[dbo].[ExampleVectorRuntimeB] TO [ExampleVectorRestrictedUser];

    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXECUTE AS USER=N'ExampleVectorRestrictedUser';
    SET @Impersonating=1;
    EXEC [monitor].[USP_VectorIndexAnalysis]
          @DatabaseNames=N'[DeineDatenbank]'
        , @FullObjectNames=N'[dbo].[ExampleVectorRuntimeA]'
        , @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0
        , @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
    REVERT;
    SET @Impersonating=0;

    IF ISJSON(@Json)<>1 OR @Partial<>1 OR @Status<>'AVAILABLE_LIMITED'
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.sourceStatus')
              WITH ([SourceName] sysname N'$.SourceName',[StatusCode] varchar(40) N'$.StatusCode')
              WHERE [SourceName]=N'vectorCatalog' AND [StatusCode]='AVAILABLE'
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.sourceStatus')
              WITH ([SourceName] sysname N'$.SourceName',[StatusCode] varchar(40) N'$.StatusCode')
              WHERE [SourceName]=N'vectorRuntime' AND [StatusCode]='DENIED_PERMISSION'
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.maintenance')
              WITH ([StatusCode] varchar(40) N'$.StatusCode')
              WHERE [StatusCode]='DENIED_PERMISSION'
          )
        THROW 55710,N'SQL25-001 Berechtigungsgrenze fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('DENIED-RUNTIME');

    DROP USER [ExampleVectorRestrictedUser];
    DROP TABLE [dbo].[ExampleVectorRuntimeA];
    DROP TABLE [dbo].[ExampleVectorRuntimeB];
    IF COALESCE(@PreviewWasEnabled,0)=0
        EXEC [sys].[sp_executesql] N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=OFF;';
    IF @OriginalCompatibilityLevel<170
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CurrentDatabaseName)+N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(3),@OriginalCompatibilityLevel)+N';';
        EXEC [sys].[sp_executesql] @Sql;
    END;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@EmptyDatabaseName)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@EmptyDatabaseName)+N';';
    EXEC [sys].[sp_executesql] @Sql;
END TRY
BEGIN CATCH
    IF @Impersonating=1
    BEGIN
        BEGIN TRY
            REVERT;
        END TRY
        BEGIN CATCH
        END CATCH;
    END;
    BEGIN TRY
        IF USER_ID(N'ExampleVectorRestrictedUser') IS NOT NULL DROP USER [ExampleVectorRestrictedUser];
        DROP TABLE IF EXISTS [dbo].[ExampleVectorRuntimeA];
        DROP TABLE IF EXISTS [dbo].[ExampleVectorRuntimeB];
        IF COALESCE(@PreviewWasEnabled,0)=0
            EXEC [sys].[sp_executesql] N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES=OFF;';
        IF @OriginalCompatibilityLevel<170
        BEGIN
            SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CurrentDatabaseName)+N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(3),@OriginalCompatibilityLevel)+N';';
            EXEC [sys].[sp_executesql] @Sql;
        END;
        IF EXISTS
           (
               SELECT 1 FROM [master].[sys].[databases] WITH (NOLOCK)
               WHERE [name]=@EmptyDatabaseName COLLATE SQL_Latin1_General_CP1_CS_AS
           )
        BEGIN
            SET @Sql=N'ALTER DATABASE '+QUOTENAME(@EmptyDatabaseName)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@EmptyDatabaseName)+N';';
            EXEC [sys].[sp_executesql] @Sql;
        END;
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW;
END CATCH;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>9
    THROW 55711,N'SQL25-001 hat nicht alle neun SQL-Server-2025-Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) [StatusCode],CAST(0 AS bit) [IsPartial],
       @ProductMajorVersion [ProductMajorVersion],
       (SELECT COUNT_BIG(*) FROM @ExecutedCases) [ExecutedCases],
       N'SQL25-001 Vector-Index-Laufzeitvertrag vollständig bestanden.' [Detail];
GO
