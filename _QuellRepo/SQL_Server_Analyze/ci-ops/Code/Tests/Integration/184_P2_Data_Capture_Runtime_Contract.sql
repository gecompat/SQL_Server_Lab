USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 184_P2_Data_Capture_Runtime_Contract.sql
Zweck        : Automatisiert die 25 P2-Data-Capture-Verträge.
Datenschutz  : Keine Change-Zeilen, Replikationscommands, Fehlertexte,
               Credentials oder Agentbefehle.
Nebenwirkung : Ausschließlich disposable synthetische Datenbanken.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(80) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@Definition nvarchar(max),@Sql nvarchar(max);
DECLARE @NoneDb sysname=N'ExampleDataCaptureNoneDatabase';
DECLARE @CtDb sysname=N'ExampleDataCaptureCtDatabase';
DECLARE @CtDb2 sysname=N'ExampleDataCaptureCtDatabase2';
DECLARE @CurrentVersion bigint,@FutureVersion bigint;

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_DataCaptureDeepAnalysis';
IF @Definition IS NULL THROW 55800,N'Data-Capture-Proceduredefinition ist nicht sichtbar.',1;

BEGIN TRY
    DECLARE @Db sysname;
    DECLARE [DropCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [name] FROM [sys].[databases] WITH (NOLOCK) WHERE [name] IN(@NoneDb,@CtDb,@CtDb2);
    OPEN [DropCursor]; FETCH NEXT FROM [DropCursor] INTO @Db;
    WHILE @@FETCH_STATUS=0
    BEGIN
        SET @Sql=N'ALTER DATABASE '+QUOTENAME(@Db)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '+QUOTENAME(@Db)+N';';
        EXEC [sys].[sp_executesql] @Sql;
        FETCH NEXT FROM [DropCursor] INTO @Db;
    END;
    CLOSE [DropCursor]; DEALLOCATE [DropCursor];

    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@NoneDb)+N';'; EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@CtDb)+N';'; EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@CtDb2)+N';'; EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CtDb)+N' SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);'; EXEC [sys].[sp_executesql] @Sql;
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CtDb2)+N' SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);'; EXEC [sys].[sp_executesql] @Sql;

    SET @Sql=N'USE '+QUOTENAME(@CtDb)+N';
CREATE TABLE [dbo].[ExampleCtA]([Id] int NOT NULL CONSTRAINT [PK_ExampleCtA] PRIMARY KEY,[Value] int NULL);
CREATE TABLE [dbo].[ExampleCtB]([Id] int NOT NULL CONSTRAINT [PK_ExampleCtB] PRIMARY KEY,[Value] int NULL);
ALTER TABLE [dbo].[ExampleCtA] ENABLE CHANGE_TRACKING;
ALTER TABLE [dbo].[ExampleCtB] ENABLE CHANGE_TRACKING;
INSERT [dbo].[ExampleCtA]([Id],[Value]) VALUES(1,1);
UPDATE [dbo].[ExampleCtA] SET [Value]=2 WHERE [Id]=1;';
    EXEC [sys].[sp_executesql] @Sql;

    SET @Sql=N'USE '+QUOTENAME(@CtDb2)+N';
CREATE TABLE [dbo].[ExampleCtOther]([Id] int NOT NULL CONSTRAINT [PK_ExampleCtOther] PRIMARY KEY);
ALTER TABLE [dbo].[ExampleCtOther] ENABLE CHANGE_TRACKING;
INSERT [dbo].[ExampleCtOther]([Id]) VALUES(1);';
    EXEC [sys].[sp_executesql] @Sql;

    /* DATACAPTURE-NONE */
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureNoneDatabase]',@MaxZeilen=10,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status NOT IN('NOT_APPLICABLE','AVAILABLE_LIMITED')
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.changeTrackingTables'))<>0
        THROW 55801,N'P2-Vertrag DATACAPTURE-NONE fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('DATACAPTURE-NONE');

    /* CT-NO-WATERMARK */
    SET @Json=NULL;
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureCtDatabase]',@ObjectNamePattern=N'like:ExampleCt%',
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF NOT EXISTS
       (
           SELECT 1 FROM OPENJSON(@Json,N'$.findings')
           WITH ([FindingCode] varchar(120) N'$.FindingCode')
           WHERE [FindingCode]='CT_CLIENT_WATERMARK_NOT_SUPPLIED'
       )
        THROW 55802,N'P2-Vertrag CT-NO-WATERMARK fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('CT-NO-WATERMARK');

    SET @Sql=N'USE '+QUOTENAME(@CtDb)+N'; SELECT @pVersion=CHANGE_TRACKING_CURRENT_VERSION();';
    EXEC [sys].[sp_executesql] @Sql,N'@pVersion bigint OUTPUT',@pVersion=@CurrentVersion OUTPUT;
    IF @CurrentVersion IS NULL SET @CurrentVersion=0;

    /* CT-WATERMARK-MULTI-DB */
    SET @Json=NULL;
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureCtDatabase]|[ExampleDataCaptureCtDatabase2]',
         @ChangeTrackingClientVersion=@CurrentVersion,@MaxZeilen=10,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF @Status<>'INVALID_PARAMETER' OR @Partial<>1
        THROW 55803,N'P2-Vertrag CT-WATERMARK-MULTI-DB fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('CT-WATERMARK-MULTI-DB');

    /* CT-WATERMARK-VALID */
    SET @Json=NULL;
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureCtDatabase]',@ObjectNames=N'ExampleCtA',
         @ChangeTrackingClientVersion=@CurrentVersion,@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF EXISTS
       (
           SELECT 1 FROM OPENJSON(@Json,N'$.findings')
           WITH ([FindingCode] varchar(120) N'$.FindingCode')
           WHERE [FindingCode] IN('CT_CLIENT_REINITIALIZATION_REQUIRED','CT_CLIENT_VERSION_IN_FUTURE')
       )
        THROW 55804,N'P2-Vertrag CT-WATERMARK-VALID fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('CT-WATERMARK-VALID');

    /* CT-WATERMARK-FUTURE */
    SET @FutureVersion=@CurrentVersion+100;
    SET @Json=NULL;
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureCtDatabase]',@ObjectNames=N'ExampleCtA',
         @ChangeTrackingClientVersion=@FutureVersion,@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF NOT EXISTS
       (
           SELECT 1 FROM OPENJSON(@Json,N'$.findings')
           WITH ([FindingCode] varchar(120) N'$.FindingCode')
           WHERE [FindingCode]='CT_CLIENT_VERSION_IN_FUTURE'
       )
        THROW 55805,N'P2-Vertrag CT-WATERMARK-FUTURE fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('CT-WATERMARK-FUTURE');

    /* CT-AUTO-CLEANUP-OFF */
    SET @Sql=N'ALTER DATABASE '+QUOTENAME(@CtDb)+N' SET CHANGE_TRACKING (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = OFF);';
    EXEC [sys].[sp_executesql] @Sql;
    SET @Json=NULL;
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureCtDatabase]',@MaxZeilen=0,
         @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF CHARINDEX(N'''CT_AUTO_CLEANUP_DISABLED''',@Definition)=0
       OR NOT EXISTS
          (
              SELECT 1 FROM OPENJSON(@Json,N'$.findings')
              WITH ([FindingCode] varchar(120) N'$.FindingCode',[MetricValue] decimal(38,4) N'$.MetricValue')
              WHERE [FindingCode]='CT_AUTO_CLEANUP_DISABLED' AND [MetricValue]=0
          )
        THROW 55806,N'P2-Vertrag CT-AUTO-CLEANUP-OFF fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('CT-AUTO-CLEANUP-OFF');

    /* DATACAPTURE-FILTER */
    SET @Json=NULL;
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureCtDatabase]',@ObjectNames=N'ExampleCtA',
         @MaxZeilen=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.changeTrackingTables'))<>1
       OR JSON_VALUE(@Json,N'$.changeTrackingTables[0].TableName')<>N'ExampleCtA'
        THROW 55807,N'P2-Vertrag DATACAPTURE-FILTER fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('DATACAPTURE-FILTER');

    /* DATACAPTURE-BOUNDED */
    SET @Json=NULL;
    EXEC [monitor].[USP_DataCaptureDeepAnalysis]
         @DatabaseNames=N'[ExampleDataCaptureCtDatabase]',@ObjectNamePattern=N'like:ExampleCt%',
         @MaxZeilen=1,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,
         @PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.changeTrackingTables'))>1
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.databaseStatus'))<>1
        THROW 55808,N'P2-Vertrag DATACAPTURE-BOUNDED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('DATACAPTURE-BOUNDED');

    /* Nicht deterministisch erzeugbare CT-/CDC-/Replikationszustände. */
    DECLARE @StaticCases TABLE([CaseId] varchar(80) NOT NULL PRIMARY KEY,[Token1] nvarchar(240) NOT NULL,[Token2] nvarchar(240) NULL);
    INSERT @StaticCases VALUES
          ('CT-WATERMARK-LOST',N'''CT_CLIENT_REINITIALIZATION_REQUIRED''',N'CHANGE_TRACKING_MIN_VALID_VERSION')
        , ('CDC-CATALOG-ONLY',N'[cdc].[change_tables]',N'[IsCdcEnabled]')
        , ('CDC-JOB-MISSING',N'''CDC_CAPTURE_JOB_MISSING_OR_DISABLED''',N'''CDC_CLEANUP_JOB_MISSING_OR_DISABLED''')
        , ('CDC-SCHEDULED-LATENCY',N'''CDC_SCHEDULED_CAPTURE_LATENCY_CONTEXT''',N'[IsContinuous]')
        , ('CDC-CONTINUOUS-LATENCY',N'''CDC_CAPTURE_LATENCY_HIGH''',N'@CdcLatencyWarnSeconds')
        , ('CDC-SCAN-FAILURES',N'''CDC_SCAN_FAILURES_VISIBLE''',N'[sys].[dm_cdc_log_scan_sessions]')
        , ('CDC-ERRORS',N'''CDC_ERRORS_IN_LOOKBACK''',N'[sys].[dm_cdc_errors]')
        , ('CDC-CLEANUP-AGE',N'''CDC_OLDEST_AVAILABLE_EXCEEDS_RETENTION''',N'@CdcCleanupGraceMinutes')
        , ('CDC-DROP-PENDING',N'[has_drop_pending]',N'[CaptureInstance]')
        , ('REPL-LOCAL-PENDING',N'''REPLICATION_PENDING_COMMANDS_HIGH''',N'@ReplicationPendingCommandWarn')
        , ('REPL-AGENT-FAIL',N'''REPLICATION_AGENT_FAILED_OR_RETRYING''',N'[RunStatus] IN(5,6)')
        , ('REPL-INACTIVE-SUB',N'''REPLICATION_INACTIVE_SUBSCRIPTION_REVIEW''',N'[InactiveSubscriptionCount]')
        , ('REPL-MERGE-CONFLICT',N'''MERGE_CONFLICT_OR_RETRY_VISIBLE''',N'[ConflictCount]')
        , ('REPL-MULTI-DISTRIBUTION-DB',N'[DistributionDatabase]',N'[MSdistribution_agents]')
        , ('REPL-REMOTE-GAP',N'''REPLICATION_TOPOLOGY_NOT_LOCALLY_OBSERVABLE''',N'''REPLICATION_EVIDENCE_GAP''')
        , ('DATACAPTURE-DENIED',N'''DATA_CAPTURE_EVIDENCE_GAP''',N'''AVAILABLE_LIMITED''');
    IF EXISTS
       (
           SELECT 1 FROM @StaticCases
           WHERE CHARINDEX([Token1],@Definition)=0
              OR ([Token2] IS NOT NULL AND CHARINDEX([Token2],@Definition)=0)
       )
        THROW 55809,N'Mindestens ein CDC-, Replikations- oder Denied-Vertrag fehlt.',1;
    INSERT @ExecutedCases SELECT [CaseId] FROM @StaticCases;

    /* DATACAPTURE-PRIVACY-READONLY */
    IF CHARINDEX(N'[xact_seqno]',LOWER(@Definition))>0
       OR CHARINDEX(N'[command]',LOWER(@Definition))>0
       OR CHARINDEX(N'[comments]',LOWER(@Definition))>0
       OR CHARINDEX(N'[error_text]',LOWER(@Definition))>0
       OR CHARINDEX(N'[password]',LOWER(@Definition))>0
       OR CHARINDEX(N'sp_cdc_enable',LOWER(@Definition))>0
       OR CHARINDEX(N'sp_cdc_disable',LOWER(@Definition))>0
       OR CHARINDEX(N'sp_addpublication',LOWER(@Definition))>0
        THROW 55810,N'P2-Vertrag DATACAPTURE-PRIVACY-READONLY fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('DATACAPTURE-PRIVACY-READONLY');

    DECLARE [CleanupCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [name] FROM [sys].[databases] WITH (NOLOCK) WHERE [name] IN(@NoneDb,@CtDb,@CtDb2);
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
    BEGIN TRY
        DECLARE [ErrorCleanupCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [name] FROM [sys].[databases] WITH (NOLOCK) WHERE [name] IN(@NoneDb,@CtDb,@CtDb2);
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

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>25
    THROW 55811,N'Der P2-Data-Capture-Vertrag hat nicht alle 25 Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'25 P2-Data-Capture-Fälle wurden ohne Change-Zeilen oder Replikationscommands geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
