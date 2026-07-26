USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_WorkerPressureAnalysis
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Korreliert Worker-Verfügbarkeit, Scheduler-Queues, THREADPOOL,
               Blocking und begrenzte laufende Requests in einem kurzen Sample.
Zeitvertrag  : Zwei Schedulerbeobachtungen bei @SampleSeconds>0; Worker, Waits
               und Requests sind flüchtige Snapshots am Sampleende.
Abgrenzung   : work_queue_count bedeutet fehlenden Worker; runnable_tasks_count
               bedeutet CPU-Warteschlange. Kein Befund empfiehlt automatisch
               eine Änderung von max worker threads.
Eigenlast    : Ein aggregierter Scan von dm_os_workers sowie kleine Scheduler-,
               Wait- und Request-Snapshots; keine SQL- oder Plantexte.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_WorkerPressureAnalysis]
      @SampleSeconds       tinyint         = 1
    , @MinRequestElapsedMs int             = 5000
    , @MaxZeilen           int             = 1000
    , @ResultSetArt        varchar(16)     = 'CONSOLE'
    , @ResultTablesJson    nvarchar(max)   = NULL
    , @JsonErzeugen        bit             = 0
    , @Json                nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen      bit             = 1
    , @Hilfe               bit             = 0
    , @StatusCodeOut       varchar(40)     = NULL OUTPUT
    , @IsPartialOut        bit             = NULL OUTPUT
    , @ErrorNumberOut      int             = NULL OUTPUT
    , @ErrorMessageOut     nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;

    DECLARE @CapturedAtUtc datetime2(3)=SYSUTCDATETIME();
    DECLARE @SampleStartUtc datetime2(3)=SYSUTCDATETIME();
    DECLARE @SampleEndUtc datetime2(3)=NULL;
    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @ConsoleResultRequested bit=CASE WHEN UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))))='CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @CandidateLimit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) WHEN @MaxZeilen BETWEEN 1 AND 2147483646 THEN CONVERT(bigint,@MaxZeilen)+1 ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @Delay char(8);

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_WorkerPressureAnalysis';
        PRINT N'@SampleSeconds=0 liefert einen Snapshot; 1..60 liefert Scheduler-Deltas und einen Snapshot am Sampleende.';
        PRINT N'@MinRequestElapsedMs begrenzt den Requestkontext; SQL-, Plan-, Login-, Host- und Programmnamen werden nicht gelesen.';
        PRINT N'work_queue_count/THREADPOOL zeigen Workerbedarf; runnable_tasks_count zeigt CPU-Warteschlange.';
        PRINT N'Kein Einzelindikator rechtfertigt automatisch eine Änderung von max worker threads.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE-Namen: moduleStatus, summary, schedulers, waits, requests, sourceStatus, warnings.';
        RETURN;
    END;

    CREATE TABLE [#WorkerPressureAnalysis_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );

    CREATE TABLE [#WorkerPressureAnalysis_SchedulerBefore]
    (
          [SchedulerAddress] varbinary(8) NOT NULL PRIMARY KEY
        , [SchedulerId] int NOT NULL
        , [ParentNodeId] int NOT NULL
        , [CpuId] smallint NOT NULL
        , [Status] nvarchar(60) NOT NULL
        , [CurrentTasks] int NOT NULL
        , [RunnableTasks] int NOT NULL
        , [CurrentWorkers] int NOT NULL
        , [ActiveWorkers] int NOT NULL
        , [WorkQueueCount] bigint NOT NULL
        , [PendingDiskIoCount] int NOT NULL
        , [ContextSwitches] int NOT NULL
        , [YieldCount] int NOT NULL
        , [TotalCpuUsageMs] bigint NOT NULL
        , [TotalSchedulerDelayMs] bigint NOT NULL
        , [FailedToCreateWorker] bit NULL
        , [IdealWorkersLimit] int NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_SchedulerAfter]
    (
          [SchedulerAddress] varbinary(8) NOT NULL PRIMARY KEY
        , [SchedulerId] int NOT NULL
        , [ParentNodeId] int NOT NULL
        , [CpuId] smallint NOT NULL
        , [Status] nvarchar(60) NOT NULL
        , [CurrentTasks] int NOT NULL
        , [RunnableTasks] int NOT NULL
        , [CurrentWorkers] int NOT NULL
        , [ActiveWorkers] int NOT NULL
        , [WorkQueueCount] bigint NOT NULL
        , [PendingDiskIoCount] int NOT NULL
        , [ContextSwitches] int NOT NULL
        , [YieldCount] int NOT NULL
        , [TotalCpuUsageMs] bigint NOT NULL
        , [TotalSchedulerDelayMs] bigint NOT NULL
        , [FailedToCreateWorker] bit NULL
        , [IdealWorkersLimit] int NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_Workers]
    (
          [SchedulerAddress] varbinary(8) NOT NULL PRIMARY KEY
        , [WorkerCount] int NOT NULL
        , [RunningWorkers] int NOT NULL
        , [RunnableWorkers] int NOT NULL
        , [SuspendedWorkers] int NOT NULL
        , [PreemptiveWorkers] int NOT NULL
        , [SickWorkers] int NOT NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_Schedulers]
    (
          [SchedulerId] int NOT NULL
        , [ParentNodeId] int NOT NULL
        , [CpuId] smallint NOT NULL
        , [Status] nvarchar(60) NOT NULL
        , [SampleSeconds] decimal(19,6) NOT NULL
        , [CurrentTasks] int NOT NULL
        , [RunnableTasks] int NOT NULL
        , [CurrentWorkers] int NOT NULL
        , [ActiveWorkers] int NOT NULL
        , [WorkQueueCount] bigint NOT NULL
        , [PendingDiskIoCount] int NOT NULL
        , [WorkerCountFromWorkerDmv] int NULL
        , [RunningWorkers] int NULL
        , [RunnableWorkers] int NULL
        , [SuspendedWorkers] int NULL
        , [PreemptiveWorkers] int NULL
        , [SickWorkers] int NULL
        , [WorkQueueDelta] bigint NULL
        , [RunnableTasksDelta] int NULL
        , [CurrentWorkersDelta] int NULL
        , [ActiveWorkersDelta] int NULL
        , [ContextSwitchDelta] bigint NULL
        , [YieldDelta] bigint NULL
        , [CpuUsageDeltaMs] bigint NULL
        , [SchedulerDelayDeltaMs] bigint NULL
        , [CounterResetDetected] bit NOT NULL
        , [FailedToCreateWorker] bit NULL
        , [IdealWorkersLimit] int NULL
        , [FindingCode] varchar(80) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_Waits]
    (
          [WaitType] nvarchar(60) NOT NULL
        , [WaitingTaskCount] bigint NOT NULL
        , [MaxWaitDurationMs] bigint NOT NULL
        , [BlockedTaskCount] bigint NOT NULL
        , [FindingCode] varchar(80) NOT NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_Requests]
    (
          [SessionId] smallint NOT NULL
        , [RequestId] int NOT NULL
        , [SchedulerId] int NULL
        , [RequestStatus] nvarchar(30) NOT NULL
        , [Command] nvarchar(32) NOT NULL
        , [ElapsedMs] int NOT NULL
        , [CpuMs] int NOT NULL
        , [LogicalReads] bigint NOT NULL
        , [Reads] bigint NOT NULL
        , [Writes] bigint NOT NULL
        , [Dop] smallint NULL
        , [BlockingSessionId] smallint NULL
        , [WaitType] nvarchar(60) NULL
        , [WaitTimeMs] int NOT NULL
        , [ContextReason] varchar(80) NOT NULL
        , PRIMARY KEY([SessionId],[RequestId])
    );

    CREATE TABLE [#WorkerPressureAnalysis_Summary]
    (
          [CapturedAtUtc] datetime2(3) NOT NULL
        , [SampleStartUtc] datetime2(3) NOT NULL
        , [SampleEndUtc] datetime2(3) NOT NULL
        , [SampleSeconds] decimal(19,6) NOT NULL
        , [VisibleOnlineSchedulers] int NULL
        , [ConfiguredMaxWorkerThreads] int NULL
        , [EffectiveMaxWorkers] int NULL
        , [CurrentWorkerCount] int NULL
        , [AvailableWorkerCapacity] int NULL
        , [WorkerOccupancyPercent] decimal(9,2) NULL
        , [TotalWorkQueueCount] bigint NULL
        , [TotalRunnableTasks] bigint NULL
        , [MaxWorkQueuePerScheduler] bigint NULL
        , [MaxRunnablePerScheduler] int NULL
        , [ThreadpoolWaitingTaskCount] bigint NULL
        , [BlockingRequestCount] bigint NULL
        , [LongRequestCount] bigint NULL
        , [FailedToCreateWorkerSchedulers] int NULL
        , [FindingCode] varchar(80) NOT NULL
        , [Interpretation] nvarchar(1000) NOT NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_SourceStatus]
    (
          [SourceOrdinal] int NOT NULL PRIMARY KEY
        , [SourceName] sysname NOT NULL
        , [SourceObject] nvarchar(256) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [ReturnedRowCount] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_Warnings]
    (
          [WarningOrdinal] int IDENTITY(1,1) NOT NULL
        , [SourceName] sysname NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [Message] nvarchar(2048) NOT NULL
    );

    CREATE TABLE [#WorkerPressureAnalysis_ModuleStatus]
    (
          [ModuleName] sysname NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [SampleSeconds] tinyint NOT NULL
        , [ReturnedSchedulerRows] bigint NOT NULL
        , [ReturnedRequestRows] bigint NOT NULL
        , [HasMoreRequestRows] bit NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @SampleSeconds IS NULL OR @SampleSeconds>60
       OR @MinRequestElapsedMs IS NULL OR @MinRequestElapsedMs<0 OR @MaxZeilen<0
       OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @OutputMode NOT IN('CONSOLE','RAW','TABLE','NONE')
       OR (@OutputMode<>'TABLE' AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL)
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungültiger Sample-, Request-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode='AVAILABLE' AND @OutputMode='TABLE'
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'moduleStatus|summary|schedulers|waits|requests|sourceStatus|warnings'
            , @MappingTable=N'#WorkerPressureAnalysis_ResultTableMap'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @ThrowOnError=1;

    SET LOCK_TIMEOUT 0;

    DECLARE @SchedulerStatus varchar(40)='NOT_EXECUTED',@SchedulerError int=NULL,@SchedulerMessage nvarchar(2048)=NULL;
    DECLARE @WorkerStatus varchar(40)='NOT_EXECUTED',@WorkerError int=NULL,@WorkerMessage nvarchar(2048)=NULL;
    DECLARE @WaitStatus varchar(40)='NOT_EXECUTED',@WaitError int=NULL,@WaitMessage nvarchar(2048)=NULL;
    DECLARE @RequestStatus varchar(40)='NOT_EXECUTED',@RequestError int=NULL,@RequestMessage nvarchar(2048)=NULL;
    DECLARE @EffectiveMaxWorkers int=NULL,@ConfiguredMaxWorkers int=NULL,@SchedulerCount int=NULL;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        SELECT @EffectiveMaxWorkers=[max_workers_count],@SchedulerCount=[scheduler_count]
        FROM [sys].[dm_os_sys_info] WITH (NOLOCK);
        SELECT @ConfiguredMaxWorkers=TRY_CONVERT(int,[value_in_use])
        FROM [sys].[configurations] WITH (NOLOCK)
        WHERE [name]=N'max worker threads';

        INSERT [#WorkerPressureAnalysis_SchedulerBefore]
        SELECT [scheduler_address],[scheduler_id],[parent_node_id],[cpu_id],[status],
               [current_tasks_count],[runnable_tasks_count],[current_workers_count],
               [active_workers_count],[work_queue_count],[pending_disk_io_count],
               [context_switches_count],[yield_count],[total_cpu_usage_ms],
               [total_scheduler_delay_ms],[failed_to_create_worker],[ideal_workers_limit]
        FROM [sys].[dm_os_schedulers] WITH (NOLOCK)
        WHERE [scheduler_id]<1048576 AND [status]=N'VISIBLE ONLINE';

        IF @SampleSeconds>0
        BEGIN
            SET @Delay=CONVERT(char(8),DATEADD(SECOND,@SampleSeconds,CONVERT(time(0),'00:00:00')),108);
            WAITFOR DELAY @Delay;
            INSERT [#WorkerPressureAnalysis_SchedulerAfter]
            SELECT [scheduler_address],[scheduler_id],[parent_node_id],[cpu_id],[status],
                   [current_tasks_count],[runnable_tasks_count],[current_workers_count],
                   [active_workers_count],[work_queue_count],[pending_disk_io_count],
                   [context_switches_count],[yield_count],[total_cpu_usage_ms],
                   [total_scheduler_delay_ms],[failed_to_create_worker],[ideal_workers_limit]
            FROM [sys].[dm_os_schedulers] WITH (NOLOCK)
            WHERE [scheduler_id]<1048576 AND [status]=N'VISIBLE ONLINE';
        END
        ELSE
            INSERT [#WorkerPressureAnalysis_SchedulerAfter] SELECT * FROM [#WorkerPressureAnalysis_SchedulerBefore];

        SET @SampleEndUtc=SYSUTCDATETIME();
        SET @SchedulerStatus='AVAILABLE';
    END TRY
    BEGIN CATCH
        SELECT @SchedulerStatus=CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
               @SchedulerError=ERROR_NUMBER(),@SchedulerMessage=ERROR_MESSAGE();
    END CATCH;

    IF @SampleEndUtc IS NULL SET @SampleEndUtc=SYSUTCDATETIME();

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        INSERT [#WorkerPressureAnalysis_Workers]
        SELECT [scheduler_address],TRY_CONVERT(int,COUNT_BIG(*)),
               TRY_CONVERT(int,SUM(CASE WHEN [state]=N'RUNNING' THEN 1 ELSE 0 END)),
               TRY_CONVERT(int,SUM(CASE WHEN [state]=N'RUNNABLE' THEN 1 ELSE 0 END)),
               TRY_CONVERT(int,SUM(CASE WHEN [state]=N'SUSPENDED' THEN 1 ELSE 0 END)),
               TRY_CONVERT(int,SUM(CASE WHEN [is_preemptive]=1 THEN 1 ELSE 0 END)),
               TRY_CONVERT(int,SUM(CASE WHEN [is_sick]=1 THEN 1 ELSE 0 END))
        FROM [sys].[dm_os_workers] WITH (NOLOCK)
        GROUP BY [scheduler_address];
        SET @WorkerStatus='AVAILABLE';
    END TRY
    BEGIN CATCH
        SELECT @WorkerStatus=CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
               @WorkerError=ERROR_NUMBER(),@WorkerMessage=ERROR_MESSAGE();
    END CATCH;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        INSERT [#WorkerPressureAnalysis_Waits]
        SELECT [wait_type],COUNT_BIG(*),MAX([wait_duration_ms]),
               SUM(CONVERT(bigint,CASE WHEN [blocking_session_id] IS NULL OR [blocking_session_id]=0 THEN 0 ELSE 1 END)),
               CASE WHEN [wait_type]=N'THREADPOOL' THEN 'THREADPOOL_WAIT_VISIBLE' ELSE 'CORRELATED_WAIT_CONTEXT' END
        FROM [sys].[dm_os_waiting_tasks] WITH (NOLOCK)
        WHERE [wait_type]=N'THREADPOOL'
        GROUP BY [wait_type];
        SET @WaitStatus='AVAILABLE';
    END TRY
    BEGIN CATCH
        SELECT @WaitStatus=CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
               @WaitError=ERROR_NUMBER(),@WaitMessage=ERROR_MESSAGE();
    END CATCH;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        INSERT [#WorkerPressureAnalysis_Requests]
        SELECT TOP(@CandidateLimit) [session_id],[request_id],[scheduler_id],[status],[command],
               [total_elapsed_time],[cpu_time],[logical_reads],[reads],[writes],[dop],
               NULLIF([blocking_session_id],0),[wait_type],[wait_time],
               CASE WHEN [wait_type]=N'THREADPOOL' THEN 'THREADPOOL'
                    WHEN [blocking_session_id]<>0 THEN 'BLOCKED_REQUEST'
                    ELSE 'LONG_RUNNING_REQUEST' END
        FROM [sys].[dm_exec_requests] WITH (NOLOCK)
        WHERE [session_id]<>@@SPID
          AND ([wait_type]=N'THREADPOOL' OR [blocking_session_id]<>0 OR [total_elapsed_time]>=@MinRequestElapsedMs)
        ORDER BY CASE WHEN [wait_type]=N'THREADPOOL' THEN 0 WHEN [blocking_session_id]<>0 THEN 1 ELSE 2 END,
                 [total_elapsed_time] DESC,[session_id],[request_id];
        SET @RequestStatus='AVAILABLE';
    END TRY
    BEGIN CATCH
        SELECT @RequestStatus=CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
               @RequestError=ERROR_NUMBER(),@RequestMessage=ERROR_MESSAGE();
    END CATCH;

    IF @SchedulerStatus='AVAILABLE'
    BEGIN
        INSERT [#WorkerPressureAnalysis_Schedulers]
        SELECT [a].[SchedulerId],[a].[ParentNodeId],[a].[CpuId],[a].[Status],
               CONVERT(decimal(19,6),DATEDIFF_BIG(MICROSECOND,@SampleStartUtc,@SampleEndUtc)/1000000.0),
               [a].[CurrentTasks],[a].[RunnableTasks],[a].[CurrentWorkers],[a].[ActiveWorkers],
               [a].[WorkQueueCount],[a].[PendingDiskIoCount],[w].[WorkerCount],[w].[RunningWorkers],
               [w].[RunnableWorkers],[w].[SuspendedWorkers],[w].[PreemptiveWorkers],[w].[SickWorkers],
               CASE WHEN @SampleSeconds>0 THEN [a].[WorkQueueCount]-[b].[WorkQueueCount] END,
               CASE WHEN @SampleSeconds>0 THEN [a].[RunnableTasks]-[b].[RunnableTasks] END,
               CASE WHEN @SampleSeconds>0 THEN [a].[CurrentWorkers]-[b].[CurrentWorkers] END,
               CASE WHEN @SampleSeconds>0 THEN [a].[ActiveWorkers]-[b].[ActiveWorkers] END,
               CASE WHEN @SampleSeconds>0 AND [a].[ContextSwitches]>=[b].[ContextSwitches]
                    THEN CONVERT(bigint,[a].[ContextSwitches])-CONVERT(bigint,[b].[ContextSwitches]) END,
               CASE WHEN @SampleSeconds>0 AND [a].[YieldCount]>=[b].[YieldCount]
                    THEN CONVERT(bigint,[a].[YieldCount])-CONVERT(bigint,[b].[YieldCount]) END,
               CASE WHEN @SampleSeconds>0 AND [a].[TotalCpuUsageMs]>=[b].[TotalCpuUsageMs]
                    THEN [a].[TotalCpuUsageMs]-[b].[TotalCpuUsageMs] END,
               CASE WHEN @SampleSeconds>0 AND [a].[TotalSchedulerDelayMs]>=[b].[TotalSchedulerDelayMs]
                    THEN [a].[TotalSchedulerDelayMs]-[b].[TotalSchedulerDelayMs] END,
               CONVERT(bit,CASE WHEN @SampleSeconds>0 AND
                    ([a].[ContextSwitches]<[b].[ContextSwitches] OR [a].[YieldCount]<[b].[YieldCount]
                     OR [a].[TotalCpuUsageMs]<[b].[TotalCpuUsageMs]
                     OR [a].[TotalSchedulerDelayMs]<[b].[TotalSchedulerDelayMs]) THEN 1 ELSE 0 END),
               [a].[FailedToCreateWorker],[a].[IdealWorkersLimit],
               CASE WHEN [a].[WorkQueueCount]>0 THEN 'WORKER_QUEUE_VISIBLE'
                    WHEN [a].[RunnableTasks]>0 THEN 'RUNNABLE_CPU_QUEUE_VISIBLE'
                    WHEN [a].[FailedToCreateWorker]=1 THEN 'WORKER_CREATION_FAILED'
                    ELSE 'NO_QUEUE_VISIBLE_IN_SAMPLE' END,
               N'Flüchtiger Schedulerzustand. work_queue_count und runnable_tasks_count haben verschiedene Bedeutungen; ein Snapshot beweist weder Dauer noch Ursache.'
        FROM [#WorkerPressureAnalysis_SchedulerAfter] AS [a]
        LEFT JOIN [#WorkerPressureAnalysis_SchedulerBefore] AS [b] ON [b].[SchedulerAddress]=[a].[SchedulerAddress]
        LEFT JOIN [#WorkerPressureAnalysis_Workers] AS [w] ON [w].[SchedulerAddress]=[a].[SchedulerAddress];
    END;

    DECLARE @CurrentWorkerCount int=(SELECT SUM([WorkerCount]) FROM [#WorkerPressureAnalysis_Workers]);
    DECLARE @AvailableWorkerCapacity int=CASE WHEN @EffectiveMaxWorkers IS NULL OR @CurrentWorkerCount IS NULL THEN NULL WHEN @EffectiveMaxWorkers>@CurrentWorkerCount THEN @EffectiveMaxWorkers-@CurrentWorkerCount ELSE 0 END;
    DECLARE @WorkQueue bigint=(SELECT SUM([WorkQueueCount]) FROM [#WorkerPressureAnalysis_Schedulers]);
    DECLARE @Runnable bigint=(SELECT SUM(CONVERT(bigint,[RunnableTasks])) FROM [#WorkerPressureAnalysis_Schedulers]);
    DECLARE @Threadpool bigint=COALESCE((SELECT SUM([WaitingTaskCount]) FROM [#WorkerPressureAnalysis_Waits] WHERE [WaitType]=N'THREADPOOL'),0);
    DECLARE @Blocking bigint=(SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Requests] WHERE [BlockingSessionId] IS NOT NULL);
    DECLARE @LongRequests bigint=(SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Requests] WHERE [ElapsedMs]>=@MinRequestElapsedMs);

    INSERT [#WorkerPressureAnalysis_Summary]
    SELECT @CapturedAtUtc,@SampleStartUtc,@SampleEndUtc,
           CONVERT(decimal(19,6),DATEDIFF_BIG(MICROSECOND,@SampleStartUtc,@SampleEndUtc)/1000000.0),
           (SELECT COUNT(*) FROM [#WorkerPressureAnalysis_Schedulers]),@ConfiguredMaxWorkers,@EffectiveMaxWorkers,@CurrentWorkerCount,@AvailableWorkerCapacity,
           CONVERT(decimal(9,2),100.0*@CurrentWorkerCount/NULLIF(@EffectiveMaxWorkers,0)),
           @WorkQueue,@Runnable,(SELECT MAX([WorkQueueCount]) FROM [#WorkerPressureAnalysis_Schedulers]),
           (SELECT MAX([RunnableTasks]) FROM [#WorkerPressureAnalysis_Schedulers]),@Threadpool,@Blocking,@LongRequests,
           (SELECT COUNT(*) FROM [#WorkerPressureAnalysis_Schedulers] WHERE [FailedToCreateWorker]=1),
           CASE WHEN COALESCE(@WorkQueue,0)>0 OR @Threadpool>0 THEN 'WORKER_QUEUE_PRESSURE_VISIBLE'
                WHEN COALESCE(@Runnable,0)>0 THEN 'CPU_RUNNABLE_QUEUE_VISIBLE'
                ELSE 'NO_WORKER_PRESSURE_VISIBLE_IN_SAMPLE' END,
           CASE WHEN COALESCE(@WorkQueue,0)>0 OR @Threadpool>0
                THEN N'Workerbedarf ist sichtbar. Blocking, lange Requests, Parallelität und Ressourcenengpässe prüfen; max worker threads nicht aus diesem Einzelindikator ändern.'
                WHEN COALESCE(@Runnable,0)>0
                THEN N'Runnable Tasks warten auf Schedulerzeit. CPU, teure Pläne, Reads und Parallelität prüfen; dies ist kein THREADPOOL-Nachweis.'
                ELSE N'Das begrenzte Sample zeigt keinen Worker-Queue-Druck. Andere Zeitpunkte und längere Trends bleiben unbewertet.' END;

    INSERT [#WorkerPressureAnalysis_SourceStatus]
    VALUES
      (1,N'schedulers',N'sys.dm_os_schedulers|sys.dm_os_sys_info|sys.configurations',@CapturedAtUtc,@SchedulerStatus,CONVERT(bit,CASE WHEN @SchedulerStatus='AVAILABLE' THEN 0 ELSE 1 END),(SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Schedulers]),@SchedulerError,@SchedulerMessage,N'Zwei Beobachtungen nur bei @SampleSeconds>0; Counter können beim Engine-Neustart zurückgesetzt werden.'),
      (2,N'workers',N'sys.dm_os_workers',@CapturedAtUtc,@WorkerStatus,CONVERT(bit,CASE WHEN @WorkerStatus='AVAILABLE' THEN 0 ELSE 1 END),(SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Workers]),@WorkerError,@WorkerMessage,N'Ein vollständiger Worker-DMV-Scan wird sofort je Scheduler aggregiert; kein Workerdetail wird ausgegeben.'),
      (3,N'waits',N'sys.dm_os_waiting_tasks',@CapturedAtUtc,@WaitStatus,CONVERT(bit,CASE WHEN @WaitStatus='AVAILABLE' THEN 0 ELSE 1 END),(SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Waits]),@WaitError,@WaitMessage,N'Flüchtiger THREADPOOL-Waitsnapshot; fehlende Zeilen beweisen keine Abwesenheit zu anderen Zeitpunkten.'),
      (4,N'requests',N'sys.dm_exec_requests',@CapturedAtUtc,@RequestStatus,CONVERT(bit,CASE WHEN @RequestStatus='AVAILABLE' THEN 0 ELSE 1 END),(SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Requests]),@RequestError,@RequestMessage,N'Begrenzter aktueller Kontext ohne SQL-, Plan-, Login-, Host- oder Programmnamen.');

    INSERT [#WorkerPressureAnalysis_Warnings]([SourceName],[StatusCode],[ErrorNumber],[Message])
    SELECT [SourceName],[StatusCode],[ErrorNumber],COALESCE([ErrorMessage],N'Quelle nicht verfügbar.')
    FROM [#WorkerPressureAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    IF @StatusCode='AVAILABLE'
    BEGIN
        IF @SchedulerStatus<>'AVAILABLE'
            SELECT @StatusCode=@SchedulerStatus,@IsPartial=1,@ErrorNumber=@SchedulerError,@ErrorMessage=@SchedulerMessage;
        ELSE IF EXISTS(SELECT 1 FROM [#WorkerPressureAnalysis_SourceStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
    END;

    IF @ErrorMessage IS NULL
        SELECT TOP(1) @ErrorNumber=[ErrorNumber],@ErrorMessage=[Message]
        FROM [#WorkerPressureAnalysis_Warnings] ORDER BY [WarningOrdinal];

    DECLARE @RequestRows bigint=(SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Requests]);
    INSERT [#WorkerPressureAnalysis_ModuleStatus]
    VALUES(N'USP_WorkerPressureAnalysis',@CapturedAtUtc,@StatusCode,@IsPartial,@SampleSeconds,
           (SELECT COUNT_BIG(*) FROM [#WorkerPressureAnalysis_Schedulers]),
           CASE WHEN @RequestRows>@Limit THEN @Limit ELSE @RequestRows END,
           CONVERT(bit,CASE WHEN @Limit<9223372036854775807 AND @RequestRows>@Limit THEN 1 ELSE 0 END),
           @ErrorNumber,@ErrorMessage);

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'WorkerPressureAnalysis' [resultName],1 [schemaVersion],@CapturedAtUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @SummaryJson nvarchar(max)=(SELECT * FROM [#WorkerPressureAnalysis_Summary] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @SchedulersJson nvarchar(max)=(SELECT * FROM [#WorkerPressureAnalysis_Schedulers] ORDER BY [SchedulerId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @WaitsJson nvarchar(max)=(SELECT * FROM [#WorkerPressureAnalysis_Waits] ORDER BY [WaitingTaskCount] DESC,[WaitType] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @RequestsJson nvarchar(max)=(SELECT TOP(@Limit) * FROM [#WorkerPressureAnalysis_Requests] ORDER BY CASE [ContextReason] WHEN 'THREADPOOL' THEN 0 WHEN 'BLOCKED_REQUEST' THEN 1 ELSE 2 END,[ElapsedMs] DESC,[SessionId],[RequestId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @SourceJson nvarchar(max)=(SELECT * FROM [#WorkerPressureAnalysis_SourceStatus] ORDER BY [SourceOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max)=(SELECT * FROM [#WorkerPressureAnalysis_Warnings] ORDER BY [WarningOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"summary":',COALESCE(@SummaryJson,N'[]'),N',"schedulers":',COALESCE(@SchedulersJson,N'[]'),N',"waits":',COALESCE(@WaitsJson,N'[]'),N',"requests":',COALESCE(@RequestsJson,N'[]'),N',"sourceStatus":',COALESCE(@SourceJson,N'[]'),N',"warnings":',COALESCE(@WarningsJson,N'[]'),N'}');
    END;

    IF @ConsoleResultRequested=1
        EXEC [monitor].[InternalEmitConsoleResult] @SourceTable=N'#WorkerPressureAnalysis_Summary',@ResultLabel=N'Worker- und Scheduler-Druck',@EmptyMessage=N'Keine Worker-Evidenz verfügbar';
    ELSE IF @OutputMode='RAW'
    BEGIN
        SELECT * FROM [#WorkerPressureAnalysis_ModuleStatus];
        SELECT * FROM [#WorkerPressureAnalysis_Summary];
        SELECT * FROM [#WorkerPressureAnalysis_Schedulers] ORDER BY [SchedulerId];
        SELECT * FROM [#WorkerPressureAnalysis_Waits] ORDER BY [WaitingTaskCount] DESC,[WaitType];
        SELECT TOP(@Limit) * FROM [#WorkerPressureAnalysis_Requests] ORDER BY CASE [ContextReason] WHEN 'THREADPOOL' THEN 0 WHEN 'BLOCKED_REQUEST' THEN 1 ELSE 2 END,[ElapsedMs] DESC,[SessionId],[RequestId];
        SELECT * FROM [#WorkerPressureAnalysis_SourceStatus] ORDER BY [SourceOrdinal];
        SELECT * FROM [#WorkerPressureAnalysis_Warnings] ORDER BY [WarningOrdinal];
    END
    ELSE IF @OutputMode='TABLE'
    BEGIN
        DECLARE @ResultName sysname,@TargetTable sysname,@SourceTable sysname;
        DECLARE [ResultCursor] CURSOR LOCAL FAST_FORWARD FOR SELECT [ResultName],[TargetTable] FROM [#WorkerPressureAnalysis_ResultTableMap] ORDER BY [ResultName];
        OPEN [ResultCursor]; FETCH NEXT FROM [ResultCursor] INTO @ResultName,@TargetTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @SourceTable=CASE @ResultName WHEN N'moduleStatus' THEN N'#WorkerPressureAnalysis_ModuleStatus' WHEN N'summary' THEN N'#WorkerPressureAnalysis_Summary' WHEN N'schedulers' THEN N'#WorkerPressureAnalysis_Schedulers' WHEN N'waits' THEN N'#WorkerPressureAnalysis_Waits' WHEN N'requests' THEN N'#WorkerPressureAnalysis_Requests' WHEN N'sourceStatus' THEN N'#WorkerPressureAnalysis_SourceStatus' WHEN N'warnings' THEN N'#WorkerPressureAnalysis_Warnings' END;
            EXEC [monitor].[InternalWriteResultTable] @SourceTable=@SourceTable,@TargetTable=@TargetTable,@ThrowOnError=1;
            FETCH NEXT FROM [ResultCursor] INTO @ResultName,@TargetTable;
        END;
        CLOSE [ResultCursor]; DEALLOCATE [ResultCursor];
    END;

    IF @PrintMeldungen=1 AND @StatusCode<>'AVAILABLE'
    BEGIN
        DECLARE @PrintMessage nvarchar(2048)=LEFT(CONCAT(N'USP_WorkerPressureAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe warnings-Resultset.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,@ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
END;
GO
