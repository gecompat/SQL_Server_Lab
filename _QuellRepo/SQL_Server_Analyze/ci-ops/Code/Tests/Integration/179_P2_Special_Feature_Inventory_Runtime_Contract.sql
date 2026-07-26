USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 179_P2_Special_Feature_Inventory_Runtime_Contract.sql
Zweck        : Automatisiert die 21 P2-Fälle der Spezialfeature-Inventur.
Datenschutz  : Ausschließlich generische synthetische Objekte; keine Locations,
               Credentials, Payloads, Binaries, Definitionen oder Nutzdaten.
Nebenwirkung : Kurzlebige Katalogfixtures; alle Änderungen werden auch im
               Fehlerpfad entfernt. Keine externe Verbindung wird aufgebaut.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@ErrorNumber int,@ErrorMessage nvarchar(2048);
DECLARE @Definition nvarchar(max),@Sql nvarchar(max);
DECLARE @DatabaseName sysname=(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
DECLARE @DeniedDatabase sysname=N'ExampleFeatureDeniedDatabase';
DECLARE @Impersonating bit=0;
DECLARE @ChangeTrackingWasEnabled bit=
(
    SELECT CONVERT(bit,CASE WHEN EXISTS
    (
        SELECT 1 FROM [sys].[change_tracking_databases] WITH (NOLOCK)
        WHERE [database_id]=DB_ID()
    ) THEN 1 ELSE 0 END)
);

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_SpecialFeatureInventory';

IF @Definition IS NULL
    THROW 55300,N'Proceduredefinition für die P2-Feature-Inventur ist nicht sichtbar.',1;

BEGIN TRY
    /* FEATURE-ABSENT: leerer sichtbarer Scope bleibt ein Inventar, kein Abwesenheitsbeweis. */
    EXEC [monitor].[USP_SpecialFeatureInventory]
         @DatabaseNames=N'[DeineDatenbank]',@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT,
         @HighImpactConfirmed=1;

    IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_LIMITED')
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.features'))<>18
       OR EXISTS
          (
              SELECT 1
              FROM OPENJSON(@Json,N'$.features')
              WITH ([DetectionStatus] varchar(40) N'$.DetectionStatus',[DetectedItemCount] bigint N'$.DetectedItemCount')
              WHERE [DetectionStatus]='DETECTED' AND COALESCE([DetectedItemCount],0)=0
          )
        THROW 55301,N'P2-Vertrag FEATURE-ABSENT fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('FEATURE-ABSENT');

    IF EXISTS(SELECT 1 FROM [sys].[tables] WITH (NOLOCK) WHERE [name]=N'ExampleFeatureTemporal' AND [temporal_type]=2)
        ALTER TABLE [dbo].[ExampleFeatureTemporal] SET (SYSTEM_VERSIONING=OFF);
    DROP TABLE IF EXISTS [dbo].[ExampleFeatureTemporal];
    DROP TABLE IF EXISTS [dbo].[ExampleFeatureTemporalHistory];
    DROP TABLE IF EXISTS [dbo].[ExampleFeatureCt];
    DROP TABLE IF EXISTS [dbo].[ExampleFeatureGraphNode];
    DROP TABLE IF EXISTS [dbo].[ExampleFeatureTypes];
    IF EXISTS(SELECT 1 FROM [sys].[services] WITH (NOLOCK) WHERE [name]=N'ExampleFeatureService')
        DROP SERVICE [ExampleFeatureService];
    IF EXISTS(SELECT 1 FROM [sys].[service_queues] WITH (NOLOCK) WHERE [name]=N'ExampleFeatureQueue')
        DROP QUEUE [dbo].[ExampleFeatureQueue];
    IF EXISTS(SELECT 1 FROM [sys].[types] WITH (NOLOCK) WHERE [is_user_defined]=1 AND [name]=N'ExampleFeatureType')
        DROP TYPE [dbo].[ExampleFeatureType];

    IF @ChangeTrackingWasEnabled=0
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);';
        EXEC [sys].[sp_executesql] @Sql;
    END;

    CREATE TABLE [dbo].[ExampleFeatureCt]
    (
        [Id] int NOT NULL CONSTRAINT [PK_ExampleFeatureCt] PRIMARY KEY,
        [Value] int NULL
    );
    ALTER TABLE [dbo].[ExampleFeatureCt] ENABLE CHANGE_TRACKING;

    CREATE TABLE [dbo].[ExampleFeatureTemporal]
    (
        [Id] int NOT NULL CONSTRAINT [PK_ExampleFeatureTemporal] PRIMARY KEY,
        [ValidFrom] datetime2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
        [ValidTo] datetime2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL,
        PERIOD FOR SYSTEM_TIME([ValidFrom],[ValidTo])
    )
    WITH
    (
        SYSTEM_VERSIONING=ON
        (
            HISTORY_TABLE=[dbo].[ExampleFeatureTemporalHistory],
            DATA_CONSISTENCY_CHECK=OFF
        )
    );

    CREATE TABLE [dbo].[ExampleFeatureGraphNode]
    (
        [Id] int NOT NULL CONSTRAINT [PK_ExampleFeatureGraphNode] PRIMARY KEY
    ) AS NODE;
    CREATE TYPE [dbo].[ExampleFeatureType] FROM int NOT NULL;
    SET @Sql=N'CREATE TABLE [dbo].[ExampleFeatureTypes]
    (
        [Id] int NOT NULL,
        [SpatialGeometry] geometry NULL,
        [SpatialGeography] geography NULL,
        [XmlValue] xml NULL,
        [TypedValue] [dbo].[ExampleFeatureType] NOT NULL
    );';
    EXEC [sys].[sp_executesql] @Sql;
    CREATE QUEUE [dbo].[ExampleFeatureQueue] WITH STATUS=ON,RETENTION=OFF;
    CREATE SERVICE [ExampleFeatureService]
        ON QUEUE [dbo].[ExampleFeatureQueue] ([DEFAULT]);

    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_SpecialFeatureInventory]
         @DatabaseNames=N'[DeineDatenbank]',@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;

    IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_LIMITED')
        THROW 55302,N'P2-Feature-Inventur lieferte für synthetische Fixtures keinen gültigen Vertrag.',1;

    DECLARE @RequiredDetected TABLE([CaseId] varchar(64) NOT NULL,[FeatureCode] varchar(64) NOT NULL);
    INSERT @RequiredDetected VALUES
          ('FEATURE-TEMPORAL','TEMPORAL')
        , ('FEATURE-BROKER','SERVICE_BROKER')
        , ('FEATURE-CT','CHANGE_TRACKING')
        , ('FEATURE-GRAPH','GRAPH')
        , ('FEATURE-SPATIAL','SPATIAL')
        , ('FEATURE-XML','XML')
        , ('FEATURE-UDT','USER_DEFINED_TYPES');

    IF EXISTS
    (
        SELECT 1
        FROM @RequiredDetected [r]
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM OPENJSON(@Json,N'$.features')
            WITH ([FeatureCode] varchar(64) N'$.FeatureCode',[DetectionStatus] varchar(40) N'$.DetectionStatus',[DetectedItemCount] bigint N'$.DetectedItemCount') [f]
            WHERE [f].[FeatureCode]=[r].[FeatureCode]
              AND [f].[DetectionStatus]='DETECTED'
              AND COALESCE([f].[DetectedItemCount],0)>0
        )
    )
        THROW 55303,N'Mindestens ein real erzeugbares Spezialfeature wurde nicht erkannt.',1;

    INSERT @ExecutedCases SELECT [CaseId] FROM @RequiredDetected;

    /* Version-/Komponentenverträge: dieselbe Proceduredefinition muss alle Codes und Grenzen enthalten. */
    DECLARE @StaticCases TABLE
    (
          [CaseId] varchar(64) NOT NULL PRIMARY KEY
        , [RequiredToken1] nvarchar(200) NOT NULL
        , [RequiredToken2] nvarchar(200) NULL
    );
    INSERT @StaticCases VALUES
          ('FEATURE-XTP',N'''IN_MEMORY_OLTP''',N'[is_memory_optimized]')
        , ('FEATURE-FULLTEXT',N'''FULL_TEXT''',N'[sys].[fulltext_catalogs]')
        , ('FEATURE-CDC',N'''CDC''',N'[is_tracked_by_cdc]')
        , ('FEATURE-ENCRYPTION',N'''ENCRYPTION''',N'[encryption_type]')
        , ('FEATURE-CLR',N'''CLR''',N'[sys].[assemblies]')
        , ('FEATURE-EXTERNAL-TABLE',N'''EXTERNAL_TABLES''',N'[sys].[external_tables]')
        , ('FEATURE-EXTERNAL-RUNTIME',N'''EXTERNAL_RUNTIME''',N'[sys].[external_languages]')
        , ('FEATURE-EXTERNAL-SCRIPTS',N'''EXTERNAL_SCRIPTS''',N'''CONFIGURED_ONLY''')
        , ('FEATURE-FILESTREAM',N'''FILESTREAM_FILETABLE''',N'[is_filestream]')
        , ('FEATURE-JSON',N'''JSON_NATIVE''',N'''UNAVAILABLE_VERSION''')
        , ('FEATURE-VECTOR',N'''VECTOR''',N'''UNAVAILABLE_VERSION''');

    IF EXISTS
    (
        SELECT 1 FROM @StaticCases
        WHERE CHARINDEX([RequiredToken1],@Definition)=0
           OR ([RequiredToken2] IS NOT NULL AND CHARINDEX([RequiredToken2],@Definition)=0)
    )
        THROW 55304,N'Mindestens ein version- oder komponentenabhängiger Featurevertrag fehlt in der Procedure.',1;
    INSERT @ExecutedCases SELECT [CaseId] FROM @StaticCases;

    /* FEATURE-BOUNDED */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_SpecialFeatureInventory]
         @DatabaseNames=N'[DeineDatenbank]',@MaxZeilen=1,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.features'))>1
       OR TRY_CONVERT(int,JSON_VALUE(@Json,N'$.meta.featureRowCount'))<>18
        THROW 55305,N'P2-Vertrag FEATURE-BOUNDED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('FEATURE-BOUNDED');

    /* FEATURE-DENIED: zweite Datenbank bleibt für den synthetischen User unzugänglich. */
    IF EXISTS
       (
           SELECT 1
           FROM [master].[sys].[databases] WITH (NOLOCK)
           WHERE [name]=@DeniedDatabase COLLATE SQL_Latin1_General_CP1_CS_AS
       )
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DeniedDatabase)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@DeniedDatabase)+N';';
        EXEC [sys].[sp_executesql] @Sql;
    END;
    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@DeniedDatabase)+N';';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'USE '+QUOTENAME(@DeniedDatabase)+N'; CREATE USER [ExampleFeatureRestrictedUser] WITHOUT LOGIN; DENY CONNECT TO [ExampleFeatureRestrictedUser];';
    EXEC [sys].[sp_executesql] @Sql;

    IF USER_ID(N'ExampleFeatureRestrictedUser') IS NOT NULL
        DROP USER [ExampleFeatureRestrictedUser];
    CREATE USER [ExampleFeatureRestrictedUser] WITHOUT LOGIN;
    GRANT EXECUTE ON OBJECT::[monitor].[USP_SpecialFeatureInventory] TO [ExampleFeatureRestrictedUser];
    GRANT EXECUTE ON OBJECT::[monitor].[USP_PrepareDatabaseCandidates] TO [ExampleFeatureRestrictedUser];

    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXECUTE AS USER=N'ExampleFeatureRestrictedUser';
    SET @Impersonating=1;
    EXEC [monitor].[USP_SpecialFeatureInventory]
         @DatabaseNames=N'[DeineDatenbank]|[ExampleFeatureDeniedDatabase]',@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    REVERT;
    SET @Impersonating=0;

    IF ISJSON(@Json)<>1 OR @Partial<>1 OR @Status NOT IN('AVAILABLE_LIMITED','DENIED_PERMISSION','DATABASE_UNAVAILABLE')
       OR NOT EXISTS
          (
              SELECT 1 FROM OPENJSON(@Json,N'$.databaseStatus')
              WITH ([DatabaseName] sysname N'$.DatabaseName',[StatusCode] varchar(40) N'$.StatusCode',[IsPartial] bit N'$.IsPartial')
              WHERE [DatabaseName]=@DeniedDatabase AND [IsPartial]=1
          )
        THROW 55306,N'P2-Vertrag FEATURE-DENIED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('FEATURE-DENIED');

    ALTER TABLE [dbo].[ExampleFeatureTemporal] SET (SYSTEM_VERSIONING=OFF);
    DROP TABLE [dbo].[ExampleFeatureTemporal];
    DROP TABLE [dbo].[ExampleFeatureTemporalHistory];
    ALTER TABLE [dbo].[ExampleFeatureCt] DISABLE CHANGE_TRACKING;
    DROP TABLE [dbo].[ExampleFeatureCt];
    DROP TABLE [dbo].[ExampleFeatureGraphNode];
    DROP TABLE [dbo].[ExampleFeatureTypes];
    DROP TYPE [dbo].[ExampleFeatureType];
    DROP SERVICE [ExampleFeatureService];
    DROP QUEUE [dbo].[ExampleFeatureQueue];
    DROP USER [ExampleFeatureRestrictedUser];
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DeniedDatabase)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@DeniedDatabase)+N';';
    EXEC [sys].[sp_executesql] @Sql;
    IF @ChangeTrackingWasEnabled=0
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET CHANGE_TRACKING = OFF;';
        EXEC [sys].[sp_executesql] @Sql;
    END;
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
        IF EXISTS(SELECT 1 FROM [sys].[tables] WITH (NOLOCK) WHERE [name]=N'ExampleFeatureTemporal' AND [temporal_type]=2)
            ALTER TABLE [dbo].[ExampleFeatureTemporal] SET (SYSTEM_VERSIONING=OFF);
        DROP TABLE IF EXISTS [dbo].[ExampleFeatureTemporal];
        DROP TABLE IF EXISTS [dbo].[ExampleFeatureTemporalHistory];
        IF EXISTS(SELECT 1 FROM [sys].[change_tracking_tables] WITH (NOLOCK) WHERE [object_id]=(SELECT TOP(1) [object_id] FROM [sys].[tables] WITH (NOLOCK) WHERE [name]=N'ExampleFeatureCt'))
            ALTER TABLE [dbo].[ExampleFeatureCt] DISABLE CHANGE_TRACKING;
        DROP TABLE IF EXISTS [dbo].[ExampleFeatureCt];
        DROP TABLE IF EXISTS [dbo].[ExampleFeatureGraphNode];
        DROP TABLE IF EXISTS [dbo].[ExampleFeatureTypes];
        IF EXISTS(SELECT 1 FROM [sys].[services] WITH (NOLOCK) WHERE [name]=N'ExampleFeatureService') DROP SERVICE [ExampleFeatureService];
        IF EXISTS(SELECT 1 FROM [sys].[service_queues] WITH (NOLOCK) WHERE [name]=N'ExampleFeatureQueue') DROP QUEUE [dbo].[ExampleFeatureQueue];
        IF EXISTS(SELECT 1 FROM [sys].[types] WITH (NOLOCK) WHERE [is_user_defined]=1 AND [name]=N'ExampleFeatureType') DROP TYPE [dbo].[ExampleFeatureType];
        IF USER_ID(N'ExampleFeatureRestrictedUser') IS NOT NULL DROP USER [ExampleFeatureRestrictedUser];
        IF EXISTS
           (
               SELECT 1
               FROM [master].[sys].[databases] WITH (NOLOCK)
               WHERE [name]=@DeniedDatabase COLLATE SQL_Latin1_General_CP1_CS_AS
           )
        BEGIN
            SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DeniedDatabase)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@DeniedDatabase)+N';';
            EXEC [sys].[sp_executesql] @Sql;
        END;
        IF @ChangeTrackingWasEnabled=0 AND EXISTS(SELECT 1 FROM [sys].[change_tracking_databases] WITH (NOLOCK) WHERE [database_id]=DB_ID())
        BEGIN
            SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DatabaseName)+N' SET CHANGE_TRACKING = OFF;';
            EXEC [sys].[sp_executesql] @Sql;
        END;
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW;
END CATCH;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>21
    THROW 55307,N'Der P2-Feature-Inventurvertrag hat nicht alle 21 Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'21 P2-Feature-Inventurfälle wurden mit realen und version-adaptiven Verträgen geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
