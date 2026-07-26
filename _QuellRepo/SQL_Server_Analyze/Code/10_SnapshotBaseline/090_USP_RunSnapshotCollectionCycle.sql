USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_RunSnapshotCollectionCycle
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Stellt den schedulerneutralen SC-023-Einstieg für genau einen
               leichten Performance-Counter-Sammler und seine persistente
               Evidenz bereit.
Concurrency  : Benannte Session-Applock, Wartezeit 0; Parallelaufrufe lesen
               keine Quelle und enden als SKIPPED_CONCURRENT.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_RunSnapshotCollectionCycle]
      @SchedulerType     varchar(16)    = 'EXTERNAL'
    , @RunEvenIfNotDue   bit            = 0
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson  nvarchar(max)  = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
    , @CaptureRunIdOut   bigint         = NULL OUTPUT
    , @StatusCodeOut     varchar(40)    = NULL OUTPUT
    , @IsPartialOut      bit            = NULL OUTPUT
    , @ErrorNumberOut    int            = NULL OUTPUT
    , @ErrorMessageOut   nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    CREATE TABLE [#RunSnapshotCollectionCycle_Run]
    (
          [CaptureRunId] bigint NULL
        , [TargetDatabaseName] sysname NULL
        , [CollectorCode] varchar(64) NULL
        , [SchedulerType] varchar(16) NULL
        , [StartedAtUtc] datetime2(3) NULL
        , [EndedAtUtc] datetime2(3) NULL
        , [SqlServerStartTimeUtc] datetime2(3) NULL
        , [ResetEpochId] uniqueidentifier NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [MetricSampleCount] bigint NOT NULL
        , [PayloadCount] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#RunSnapshotCollectionCycle_Modules]
    (
          [ModuleStatusId] bigint NULL
        , [CaptureRunId] bigint NULL
        , [ModuleName] sysname NOT NULL
        , [CollectionTimeUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NULL
    );
    CREATE TABLE [#RunSnapshotCollectionCycle_TableMap]
    ([ResultName] sysname NOT NULL,[TargetTable] sysname NOT NULL);

    SET @Json=NULL;
    SELECT @CaptureRunIdOut=NULL,@StatusCodeOut='AVAILABLE',@IsPartialOut=0,
           @ErrorNumberOut=NULL,@ErrorMessageOut=NULL;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_RunSnapshotCollectionCycle';
        PRINT N'MANUAL, EXTERNAL und SQL_AGENT verwenden denselben Einstieg; der Scheduler enthält keine Sammellogik.';
        PRINT N'Im ersten Slice wird ausschließlich monitor.USP_PerformanceCounters mit @SampleSeconds=0 ausgeführt.';
        PRINT N'@RunEvenIfNotDue=1 umgeht nur das Intervall, niemals Concurrency, Retention oder Größenbudget.';
        RETURN;
    END;

    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,'')))),
            @TableStatus varchar(40),@TableMessage nvarchar(2048),
            @RunTarget sysname,@ModulesTarget sysname;
    SET @SchedulerType=UPPER(LTRIM(RTRIM(COALESCE(@SchedulerType,''))));

    IF @OutputMode NOT IN ('CONSOLE','RAW','TABLE','JSON','NONE')
       OR @SchedulerType NOT IN ('MANUAL','EXTERNAL','SQL_AGENT')
       OR @RunEvenIfNotDue IS NULL OR @RunEvenIfNotDue NOT IN (0,1)
       OR @JsonErzeugen IS NULL OR @JsonErzeugen NOT IN (0,1)
       OR (@OutputMode<>'TABLE' AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL)
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Ungültiger Scheduler-, Ausgabe- oder Force-Parameter.';
        GOTO EmitResults;
    END;

    IF @OutputMode='TABLE'
    BEGIN
        EXEC [monitor].[InternalPrepareResultTables]
             @ResultTablesJson=@ResultTablesJson,@AllowedResultNames=N'run|modules',
             @MappingTable=N'#RunSnapshotCollectionCycle_TableMap',
             @StatusCode=@TableStatus OUTPUT,@ErrorMessage=@TableMessage OUTPUT,@ThrowOnError=1;
        SELECT @RunTarget=MAX(CASE WHEN [ResultName]=N'run' THEN [TargetTable] END),
               @ModulesTarget=MAX(CASE WHEN [ResultName]=N'modules' THEN [TargetTable] END)
        FROM [#RunSnapshotCollectionCycle_TableMap];
    END;

    DECLARE @TargetDatabaseName sysname,@IsEnabled bit,@DefaultSchedulerType varchar(16),
            @TargetQuoted nvarchar(258),@SourceDatabaseName sysname,
            @Sql nvarchar(max),@AppLockResult int,@AppLockHeld bit=0,
            @ShouldCollect bit=0,@PrepareStatus varchar(40),@PrepareMessage nvarchar(2048),
            @CollectorJson nvarchar(max),@CollectorStatus varchar(40),@CollectorPartial bit,
            @CollectorError int,@CollectorMessage nvarchar(2048),@MaxRows int,
            @PurgeRunId bigint,@PurgeStatus varchar(40),@BudgetExceeded bit,
            @PurgeError int,@PurgeMessage nvarchar(2048);

    SELECT @TargetDatabaseName=[TargetDatabaseName],@IsEnabled=[IsEnabled],
           @DefaultSchedulerType=[DefaultSchedulerType]
    FROM [monitor].[SnapshotTargetConfiguration]
    WHERE [ConfigurationId]=1;

    IF COALESCE(@IsEnabled,0)<>1
    BEGIN
        SELECT @StatusCodeOut='DISABLED',@IsPartialOut=1,
               @ErrorMessageOut=N'Das optionale Snapshotpaket ist nicht aktiviert.';
        GOTO EmitResults;
    END;

    SELECT @SourceDatabaseName=[name]
    FROM [master].[sys].[databases] WITH (NOLOCK)
    WHERE [database_id]=DB_ID();

    IF NOT EXISTS
    (
        SELECT 1
        FROM [master].[sys].[databases] WITH (NOLOCK)
        WHERE [name]=@TargetDatabaseName AND [state]=0 AND [is_read_only]=0
    )
    BEGIN
        SELECT @StatusCodeOut='TARGET_UNAVAILABLE',@IsPartialOut=1,
               @ErrorMessageOut=N'Die konfigurierte Snapshot-Datenbank ist nicht online und schreibbar.';
        GOTO EmitResults;
    END;
    SET @TargetQuoted=QUOTENAME(@TargetDatabaseName);

    EXEC @AppLockResult=[sys].[sp_getapplock]
         @Resource=N'SQL_Server_Analyze.SC023.CollectionCycle',@LockMode='Exclusive',
         @LockOwner='Session',@LockTimeout=0,@DbPrincipal=N'public';
    IF @AppLockResult<0
    BEGIN
        SELECT @StatusCodeOut='SKIPPED_CONCURRENT',@IsPartialOut=1,
               @ErrorMessageOut=N'Ein anderer Snapshotlauf oder Purge besitzt bereits die Paket-Applock.';
        GOTO EmitResults;
    END;
    SET @AppLockHeld=1;

    BEGIN TRY
        SET @Sql=N'EXEC '+@TargetQuoted+N'.[snapshot].[InternalPurgeExpiredData]
             @MaxBatches=10,@Force=0,@PurgeRunIdOut=@r OUTPUT,@StatusCodeOut=@s OUTPUT,
             @BudgetExceededOut=@b OUTPUT,@ErrorNumberOut=@e OUTPUT,@ErrorMessageOut=@m OUTPUT;';
        EXEC [sys].[sp_executesql] @Sql,
             N'@r bigint OUTPUT,@s varchar(40) OUTPUT,@b bit OUTPUT,@e int OUTPUT,@m nvarchar(2048) OUTPUT',
             @r=@PurgeRunId OUTPUT,@s=@PurgeStatus OUTPUT,@b=@BudgetExceeded OUTPUT,
             @e=@PurgeError OUTPUT,@m=@PurgeMessage OUTPUT;

        SET @Sql=N'SELECT @MaxRows=[MaxRows] FROM '+@TargetQuoted+N'.[snapshot].[CollectorPolicy] WHERE [CollectorCode]=''PERFORMANCE_COUNTERS'';
EXEC '+@TargetQuoted+N'.[snapshot].[InternalPrepareCollectionCycle]
     @SourceDatabaseName=@Source,@SchedulerType=@Scheduler,@RunEvenIfNotDue=@Force,
     @CaptureRunIdOut=@RunId OUTPUT,@ShouldCollectOut=@Collect OUTPUT,
     @StatusCodeOut=@Status OUTPUT,@ErrorMessageOut=@Message OUTPUT;';
        EXEC [sys].[sp_executesql] @Sql,
             N'@Source sysname,@Scheduler varchar(16),@Force bit,@MaxRows int OUTPUT,@RunId bigint OUTPUT,@Collect bit OUTPUT,@Status varchar(40) OUTPUT,@Message nvarchar(2048) OUTPUT',
             @Source=@SourceDatabaseName,@Scheduler=@SchedulerType,@Force=@RunEvenIfNotDue,
             @MaxRows=@MaxRows OUTPUT,@RunId=@CaptureRunIdOut OUTPUT,@Collect=@ShouldCollect OUTPUT,
             @Status=@PrepareStatus OUTPUT,@Message=@PrepareMessage OUTPUT;

        IF @ShouldCollect=1
        BEGIN
            EXEC [monitor].[USP_PerformanceCounters]
                 @SampleSeconds=0,@MaxZeilen=@MaxRows,@ResultSetArt='NONE',
                 @JsonErzeugen=1,@Json=@CollectorJson OUTPUT,@PrintMeldungen=0,
                 @StatusCodeOut=@CollectorStatus OUTPUT,@IsPartialOut=@CollectorPartial OUTPUT,
                 @ErrorNumberOut=@CollectorError OUTPUT,@ErrorMessageOut=@CollectorMessage OUTPUT;

            SET @Sql=N'EXEC '+@TargetQuoted+N'.[snapshot].[InternalCompletePerformanceCounterCycle]
                 @CaptureRunId=@RunId,@CollectorJson=@Json,@SourceStatusCode=@SourceStatus,
                 @SourceIsPartial=@SourcePartial,@SourceErrorNumber=@SourceError,
                 @SourceErrorMessage=@SourceMessage,@StatusCodeOut=@Status OUTPUT,
                 @IsPartialOut=@Partial OUTPUT,@ErrorNumberOut=@Error OUTPUT,
                 @ErrorMessageOut=@Message OUTPUT;';
            EXEC [sys].[sp_executesql] @Sql,
                 N'@RunId bigint,@Json nvarchar(max),@SourceStatus varchar(40),@SourcePartial bit,@SourceError int,@SourceMessage nvarchar(2048),@Status varchar(40) OUTPUT,@Partial bit OUTPUT,@Error int OUTPUT,@Message nvarchar(2048) OUTPUT',
                 @RunId=@CaptureRunIdOut,@Json=@CollectorJson,@SourceStatus=@CollectorStatus,
                 @SourcePartial=@CollectorPartial,@SourceError=@CollectorError,@SourceMessage=@CollectorMessage,
                 @Status=@StatusCodeOut OUTPUT,@Partial=@IsPartialOut OUTPUT,
                 @Error=@ErrorNumberOut OUTPUT,@Message=@ErrorMessageOut OUTPUT;

            IF @PurgeStatus IN ('DENIED_PERMISSION','ERROR_HANDLED') AND @StatusCodeOut='AVAILABLE'
                SELECT @StatusCodeOut='PARTIAL',@IsPartialOut=1,
                       @ErrorMessageOut=N'Die Messung wurde gespeichert; der vorgelagerte Retentionlauf war partiell.';

            SET @Sql=N'EXEC '+@TargetQuoted+N'.[snapshot].[InternalFinalizeCollectionCycle]
                 @CaptureRunId=@RunId,@StatusCode=@Status,@IsPartial=@Partial,
                 @ErrorNumber=@Error,@ErrorMessage=@Message;';
            EXEC [sys].[sp_executesql] @Sql,
                 N'@RunId bigint,@Status varchar(40),@Partial bit,@Error int,@Message nvarchar(2048)',
                 @RunId=@CaptureRunIdOut,@Status=@StatusCodeOut,@Partial=@IsPartialOut,
                 @Error=@ErrorNumberOut,@Message=@ErrorMessageOut;
        END
        ELSE
            SELECT @StatusCodeOut=@PrepareStatus,@IsPartialOut=1,
                   @ErrorMessageOut=@PrepareMessage;

        SET @Sql=N'INSERT [#RunSnapshotCollectionCycle_Run]
([CaptureRunId],[TargetDatabaseName],[CollectorCode],[SchedulerType],[StartedAtUtc],[EndedAtUtc],[SqlServerStartTimeUtc],[ResetEpochId],[StatusCode],[IsPartial],[MetricSampleCount],[PayloadCount],[ErrorNumber],[ErrorMessage])
SELECT [CaptureRunId],@Target,[CollectorCode],[SchedulerType],[StartedAtUtc],[EndedAtUtc],[SqlServerStartTimeUtc],[ResetEpochId],[StatusCode],[IsPartial],[MetricSampleCount],[PayloadCount],[ErrorNumber],[ErrorMessage]
FROM '+@TargetQuoted+N'.[snapshot].[CaptureRun] WHERE [CaptureRunId]=@RunId;
INSERT [#RunSnapshotCollectionCycle_Modules]
([ModuleStatusId],[CaptureRunId],[ModuleName],[CollectionTimeUtc],[StatusCode],[IsPartial],[ErrorNumber],[ErrorMessage],[EvidenceLimit])
SELECT [ModuleStatusId],[CaptureRunId],[ModuleName],[CollectionTimeUtc],[StatusCode],[IsPartial],[ErrorNumber],[ErrorMessage],[EvidenceLimit]
FROM '+@TargetQuoted+N'.[snapshot].[ModuleStatus] WHERE [CaptureRunId]=@RunId;';
        EXEC [sys].[sp_executesql] @Sql,N'@Target sysname,@RunId bigint',@Target=@TargetDatabaseName,@RunId=@CaptureRunIdOut;
    END TRY
    BEGIN CATCH
        SELECT @StatusCodeOut=CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371)
                                   THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
               @IsPartialOut=1,@ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
        IF @CaptureRunIdOut IS NOT NULL
        BEGIN TRY
            SET @Sql=N'EXEC '+@TargetQuoted+N'.[snapshot].[InternalFinalizeCollectionCycle]
                 @CaptureRunId=@RunId,@StatusCode=@Status,@IsPartial=1,
                 @ErrorNumber=@Error,@ErrorMessage=@Message;';
            EXEC [sys].[sp_executesql] @Sql,
                 N'@RunId bigint,@Status varchar(40),@Error int,@Message nvarchar(2048)',
                 @RunId=@CaptureRunIdOut,@Status=@StatusCodeOut,@Error=@ErrorNumberOut,@Message=@ErrorMessageOut;
        END TRY
        BEGIN CATCH
        END CATCH;
    END CATCH;

    IF @AppLockHeld=1
    BEGIN
        EXEC [sys].[sp_releaseapplock]
             @Resource=N'SQL_Server_Analyze.SC023.CollectionCycle',@LockOwner='Session',@DbPrincipal=N'public';
        SET @AppLockHeld=0;
    END;

EmitResults:
    IF NOT EXISTS (SELECT 1 FROM [#RunSnapshotCollectionCycle_Run])
        INSERT [#RunSnapshotCollectionCycle_Run]
        ([CaptureRunId],[TargetDatabaseName],[StatusCode],[IsPartial],[MetricSampleCount],[PayloadCount],[ErrorNumber],[ErrorMessage])
        VALUES (@CaptureRunIdOut,@TargetDatabaseName,@StatusCodeOut,COALESCE(@IsPartialOut,1),0,0,@ErrorNumberOut,@ErrorMessageOut);

    IF @JsonErzeugen=1 OR @OutputMode='JSON'
    BEGIN
        DECLARE @RunJson nvarchar(max)=(SELECT * FROM [#RunSnapshotCollectionCycle_Run] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),
                @ModulesJson nvarchar(max)=(SELECT * FROM [#RunSnapshotCollectionCycle_Modules] ORDER BY [ModuleStatusId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":{"contractVersion":1,"resultName":"SnapshotCollectionCycle"},"run":',COALESCE(@RunJson,N'{}'),N',"modules":',COALESCE(@ModulesJson,N'[]'),N'}');
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT * FROM [#RunSnapshotCollectionCycle_Run];
        SELECT * FROM [#RunSnapshotCollectionCycle_Modules] ORDER BY [ModuleStatusId];
    END
    ELSE IF @OutputMode='CONSOLE'
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult] @SourceTable=N'#RunSnapshotCollectionCycle_Run',
             @ResultLabel=N'Snapshot Collection Cycle',@EmptyMessage=N'Kein Snapshotlauf',
             @StatusCode=@StatusCodeOut,@StatusMessage=@ErrorMessageOut;
        EXEC [monitor].[InternalEmitConsoleResult] @SourceTable=N'#RunSnapshotCollectionCycle_Modules',
             @ResultLabel=N'Snapshot Module Status',@EmptyMessage=N'Keine Modulstatuszeile',
             @StatusCode=@StatusCodeOut,@StatusMessage=@ErrorMessageOut;
    END
    ELSE IF @OutputMode='TABLE'
    BEGIN
        EXEC [monitor].[InternalWriteResultTable] @SourceTable=N'#RunSnapshotCollectionCycle_Run',@TargetTable=@RunTarget,@ThrowOnError=1;
        EXEC [monitor].[InternalWriteResultTable] @SourceTable=N'#RunSnapshotCollectionCycle_Modules',@TargetTable=@ModulesTarget,@ThrowOnError=1;
    END;

    IF @PrintMeldungen=1 AND @StatusCodeOut NOT IN ('AVAILABLE','PARTIAL','SKIPPED_NOT_DUE')
    BEGIN
        DECLARE @PrintMessage nvarchar(2048)=COALESCE(@ErrorMessageOut,CONVERT(nvarchar(2048),@StatusCodeOut));
        RAISERROR(N'USP_RunSnapshotCollectionCycle: %s',10,1,@PrintMessage) WITH NOWAIT;
    END;
END;
GO
