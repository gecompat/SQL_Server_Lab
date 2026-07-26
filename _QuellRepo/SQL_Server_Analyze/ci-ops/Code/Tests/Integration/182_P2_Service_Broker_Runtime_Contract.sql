USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 182_P2_Service_Broker_Runtime_Contract.sql
Zweck        : Automatisiert die 15 P2-Service-Broker-Verträge.
Datenschutz  : Keine Nachrichtenkörper, Handles oder Queue-Nutzdaten.
Nebenwirkung : Disposable Datenbanken und generische Queue-/Serviceobjekte.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@Definition nvarchar(max),@Sql nvarchar(max);
DECLARE @NoneDb sysname=N'ExampleBrokerNoneDatabase';
DECLARE @ConfigDb sysname=N'ExampleBrokerConfigDatabase';
DECLARE @DisabledDb sysname=N'ExampleBrokerDisabledDatabase';
DECLARE @DeniedDb sysname=N'ExampleBrokerDeniedDatabase';
DECLARE @Impersonating bit=0;

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_ServiceBrokerAnalysis';
IF @Definition IS NULL THROW 55600,N'Broker-Proceduredefinition ist nicht sichtbar.',1;

BEGIN TRY
    DROP TABLE IF EXISTS [dbo].[ExampleBrokerMarker];
    IF EXISTS(SELECT 1 FROM [sys].[services] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerServiceOff') DROP SERVICE [ExampleBrokerServiceOff];
    IF EXISTS(SELECT 1 FROM [sys].[services] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerServiceRetention') DROP SERVICE [ExampleBrokerServiceRetention];
    IF EXISTS(SELECT 1 FROM [sys].[service_queues] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerQueueOff') DROP QUEUE [dbo].[ExampleBrokerQueueOff];
    IF EXISTS(SELECT 1 FROM [sys].[service_queues] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerQueueRetention') DROP QUEUE [dbo].[ExampleBrokerQueueRetention];

    DECLARE @Db sysname;
    DECLARE [DropCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [name] FROM [sys].[databases] WITH (NOLOCK)
        WHERE [name] IN(@NoneDb,@ConfigDb,@DisabledDb,@DeniedDb);
    OPEN [DropCursor]; FETCH NEXT FROM [DropCursor] INTO @Db;
    WHILE @@FETCH_STATUS=0
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@Db)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@Db)+N';';
        EXEC [sys].[sp_executesql] @Sql;
        FETCH NEXT FROM [DropCursor] INTO @Db;
    END;
    CLOSE [DropCursor]; DEALLOCATE [DropCursor];

    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@NoneDb)+N';';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@NoneDb)+N' SET DISABLE_BROKER WITH ROLLBACK IMMEDIATE;';
    EXEC [sys].[sp_executesql] @Sql;

    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@ConfigDb)+N';';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@ConfigDb)+N' SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;';
    EXEC [sys].[sp_executesql] @Sql;

    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@DisabledDb)+N';';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DisabledDb)+N' SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'USE '+QUOTENAME(@DisabledDb)+N'; CREATE QUEUE [dbo].[ExampleDisabledQueue]; CREATE SERVICE [ExampleDisabledService] ON QUEUE [dbo].[ExampleDisabledQueue] ([DEFAULT]);';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@DisabledDb)+N' SET DISABLE_BROKER WITH ROLLBACK IMMEDIATE;';
    EXEC [sys].[sp_executesql] @Sql;
    /* BROKER-NONE */
    EXEC [monitor].[USP_ServiceBrokerAnalysis]
         @DatabaseNames=N'[ExampleBrokerNoneDatabase]',@MaxZeilen=10,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status NOT IN('NOT_APPLICABLE','AVAILABLE_LIMITED')
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.queues'))<>0
        THROW 55601,N'P2-Vertrag BROKER-NONE fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-NONE');

    /* BROKER-CONFIG-ONLY */
    SET @Json=NULL;
    EXEC [monitor].[USP_ServiceBrokerAnalysis]
         @DatabaseNames=N'[ExampleBrokerConfigDatabase]',@MaxZeilen=10,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_LIMITED')
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.queues'))<>0
        THROW 55602,N'P2-Vertrag BROKER-CONFIG-ONLY fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-CONFIG-ONLY');

    /* BROKER-DISABLED-OBJECTS */
    SET @Json=NULL;
    EXEC [monitor].[USP_ServiceBrokerAnalysis]
         @DatabaseNames=N'[ExampleBrokerDisabledDatabase]',@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF NOT EXISTS
       (
           SELECT 1 FROM OPENJSON(@Json,N'$.findings')
           WITH ([FindingCode] varchar(120) N'$.FindingCode')
           WHERE [FindingCode]='BROKER_DISABLED_WITH_VISIBLE_OBJECTS'
       )
        THROW 55603,N'P2-Vertrag BROKER-DISABLED-OBJECTS fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-DISABLED-OBJECTS');

    CREATE QUEUE [dbo].[ExampleBrokerQueueOff]
        WITH STATUS=OFF,RETENTION=OFF,POISON_MESSAGE_HANDLING(STATUS=OFF);
    CREATE SERVICE [ExampleBrokerServiceOff]
        ON QUEUE [dbo].[ExampleBrokerQueueOff] ([DEFAULT]);
    CREATE QUEUE [dbo].[ExampleBrokerQueueRetention]
        WITH STATUS=ON,RETENTION=ON;
    CREATE SERVICE [ExampleBrokerServiceRetention]
        ON QUEUE [dbo].[ExampleBrokerQueueRetention] ([DEFAULT]);

    SET @Json=NULL;
    EXEC [monitor].[USP_ServiceBrokerAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNamePattern=N'like:ExampleBrokerQueue%',
         @QueueRowsWarn=0,@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.queues'))<>2
        THROW 55604,N'Broker-Queuefixtures wurden nicht vollständig erkannt.',1;

    IF NOT EXISTS
       (
           SELECT 1 FROM OPENJSON(@Json,N'$.queues')
           WITH ([QueueName] sysname N'$.QueueName',[IsReceiveEnabled] bit N'$.IsReceiveEnabled',[IsPoisonMessageHandlingEnabled] bit N'$.IsPoisonMessageHandlingEnabled')
           WHERE [QueueName]=N'ExampleBrokerQueueOff' AND [IsReceiveEnabled]=0 AND [IsPoisonMessageHandlingEnabled]=0
       )
        THROW 55605,N'P2-Vertrag BROKER-QUEUE-SWITCHES fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-QUEUE-SWITCHES');

    IF NOT EXISTS
       (
           SELECT 1 FROM OPENJSON(@Json,N'$.findings')
           WITH ([ObjectName] sysname N'$.ObjectName',[FindingCode] varchar(120) N'$.FindingCode')
           WHERE [ObjectName]=N'ExampleBrokerQueueOff' AND [FindingCode]='POISON_HANDLING_DISABLED_CONTEXT'
       )
        THROW 55606,N'P2-Vertrag BROKER-POISON-LIMIT fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-POISON-LIMIT');

    IF NOT EXISTS
       (
           SELECT 1 FROM OPENJSON(@Json,N'$.queues')
           WITH ([QueueName] sysname N'$.QueueName',[IsRetentionEnabled] bit N'$.IsRetentionEnabled')
           WHERE [QueueName]=N'ExampleBrokerQueueRetention' AND [IsRetentionEnabled]=1
       )
        THROW 55607,N'P2-Vertrag BROKER-RETENTION fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-RETENTION');

    /* BROKER-FILTER */
    SET @Json=NULL;
    EXEC [monitor].[USP_ServiceBrokerAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNames=N'ExampleBrokerQueueRetention',
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.queues'))<>1
       OR JSON_VALUE(@Json,N'$.queues[0].QueueName')<>N'ExampleBrokerQueueRetention'
        THROW 55608,N'P2-Vertrag BROKER-FILTER fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-FILTER');

    /* BROKER-BOUNDED */
    SET @Json=NULL;
    EXEC [monitor].[USP_ServiceBrokerAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@ObjectNamePattern=N'like:ExampleBrokerQueue%',
         @MaxZeilen=1,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.queues'))>1
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.databaseStatus'))<>1
        THROW 55609,N'P2-Vertrag BROKER-BOUNDED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('BROKER-BOUNDED');

    /* Nicht portabel erzeugbare Laufzeitzustände bleiben an konkrete Quellen und Codes gebunden. */
    DECLARE @StaticCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY,[Token1] nvarchar(200) NOT NULL,[Token2] nvarchar(200) NULL);
    INSERT @StaticCases VALUES
          ('BROKER-QUEUE-CAPACITY',N'''QUEUE_BACKLOG_CONTEXT''',N'[sys].[dm_db_partition_stats]')
        , ('BROKER-ACTIVATION',N'''INTERNAL_ACTIVATION_PROGRESS_REVIEW''',N'[sys].[dm_broker_activated_tasks]')
        , ('BROKER-TRANSMISSION-AGE',N'''AGED_TRANSMISSION_REVIEW''',N'@TransmissionAgeWarnMinutes')
        , ('BROKER-TRANSMISSION-STATUS',N'''TRANSMISSION_STATUS_REPORTED''',N'[transmission_status]')
        , ('BROKER-CONVERSATION',N'''CONVERSATION_ERROR_STATE''',N'''EXPIRED_CONVERSATION_LIFETIME_REVIEW''')
        , ('BROKER-DENIED',N'''SERVICE_BROKER_EVIDENCE_GAP''',N'''AVAILABLE_LIMITED''');
    IF EXISTS
       (
           SELECT 1 FROM @StaticCases
           WHERE CHARINDEX([Token1],@Definition)=0
              OR ([Token2] IS NOT NULL AND CHARINDEX([Token2],@Definition)=0)
       )
        THROW 55610,N'Mindestens ein Broker-Laufzeit- oder Denied-Vertrag fehlt.',1;
    INSERT @ExecutedCases SELECT [CaseId] FROM @StaticCases;

    /* BROKER-PAYLOAD-GATE */
    IF CHARINDEX(N'[message_body]',LOWER(@Definition))>0
       OR CHARINDEX(N'receive top (',LOWER(@Definition))>0
       OR CHARINDEX(N'alter queue [',LOWER(@Definition))>0
       OR CHARINDEX(N'end conversation [',LOWER(@Definition))>0
       OR CHARINDEX(N'end conversation @',LOWER(@Definition))>0
        THROW 55611,N'P2-Vertrag BROKER-PAYLOAD-GATE fehlgeschlagen.',1;
    IF CHARINDEX(N'[sys].[transmission_queue]',@Definition)=0
       OR CHARINDEX(N'[sys].[conversation_endpoints]',@Definition)=0
        THROW 55612,N'Erwartete Broker-Metadatenquellen fehlen.',1;
    INSERT @ExecutedCases VALUES('BROKER-PAYLOAD-GATE');

    DROP SERVICE [ExampleBrokerServiceOff];
    DROP SERVICE [ExampleBrokerServiceRetention];
    DROP QUEUE [dbo].[ExampleBrokerQueueOff];
    DROP QUEUE [dbo].[ExampleBrokerQueueRetention];

    DECLARE [CleanupCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [name] FROM [sys].[databases] WITH (NOLOCK)
        WHERE [name] IN(@NoneDb,@ConfigDb,@DisabledDb,@DeniedDb);
    OPEN [CleanupCursor]; FETCH NEXT FROM [CleanupCursor] INTO @Db;
    WHILE @@FETCH_STATUS=0
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@Db)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@Db)+N';';
        EXEC [sys].[sp_executesql] @Sql;
        FETCH NEXT FROM [CleanupCursor] INTO @Db;
    END;
    CLOSE [CleanupCursor]; DEALLOCATE [CleanupCursor];
END TRY
BEGIN CATCH
    IF @Impersonating=1 BEGIN TRY REVERT; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY
        IF EXISTS(SELECT 1 FROM [sys].[services] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerServiceOff') DROP SERVICE [ExampleBrokerServiceOff];
        IF EXISTS(SELECT 1 FROM [sys].[services] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerServiceRetention') DROP SERVICE [ExampleBrokerServiceRetention];
        IF EXISTS(SELECT 1 FROM [sys].[service_queues] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerQueueOff') DROP QUEUE [dbo].[ExampleBrokerQueueOff];
        IF EXISTS(SELECT 1 FROM [sys].[service_queues] WITH (NOLOCK) WHERE [name]=N'ExampleBrokerQueueRetention') DROP QUEUE [dbo].[ExampleBrokerQueueRetention];
        DECLARE [ErrorCleanupCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [name] FROM [sys].[databases] WITH (NOLOCK)
            WHERE [name] IN(@NoneDb,@ConfigDb,@DisabledDb,@DeniedDb);
        OPEN [ErrorCleanupCursor]; FETCH NEXT FROM [ErrorCleanupCursor] INTO @Db;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @Sql=N'ALTER DATABASE '+QUOTENAME(@Db)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@Db)+N';';
            EXEC [sys].[sp_executesql] @Sql;
            FETCH NEXT FROM [ErrorCleanupCursor] INTO @Db;
        END;
        CLOSE [ErrorCleanupCursor]; DEALLOCATE [ErrorCleanupCursor];
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW;
END CATCH;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>15
    THROW 55613,N'Der P2-Broker-Vertrag hat nicht alle 15 Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'15 P2-Broker-Fälle wurden ohne Queue-Payload oder Conversation-Änderung geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
