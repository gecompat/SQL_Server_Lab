USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CurrentOverview
Version      : 4.1.0
Stand        : 2026-07-23
Zweck        : Orchestriert jedes aktivierte Current-State-Child genau einmal,
               übernimmt dessen expliziten Status und materialisiert Daten für
               CONSOLE, JSON und benannte TABLE-Exporte ohne erneute Systemlese.
CONSOLE      : SUMMARY ist der Default. RELEVANT und ALL ergänzen ausschließlich
               nicht leere Childdetails; Children erhalten niemals CONSOLE.
TABLE-Namen  : moduleStatus, snapshotStatus, sessions, requests, requestContext,
               statements, batches, inputBuffers, blocking, waits, transactions,
               memoryGrants, tempdbSessions, tempdbGovernance, io, logs und warnings.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CurrentOverview]
      @SessionIds                    nvarchar(max)  = NULL
    , @DatabaseNames                 nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen  bit            = 0
    , @DatabaseNamePattern           nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit          = 0
    , @Detailgrad                    varchar(16)     = 'SUMMARY'
    , @MitSessions                   bit             = 1
    , @MitRequests                   bit             = 1
    , @MitBlocking                   bit             = 1
    , @BlockingObjektTiefe           varchar(16)     = 'STANDARD'
    , @MaxObjektAufloesungen         int             = 100
    , @MitWaits                      bit             = 1
    , @MitTransactions               bit             = 1
    , @MitMemoryGrants               bit             = 1
    , @MitTempDB                     bit             = 1
    , @MitIO                         bit             = 1
    , @MitLog                        bit             = 1
    , @MitSqlText                    bit             = 1
    , @GesamtenSqlTextEinbeziehen    bit             = 0
    , @InputBufferEinbeziehen        bit             = 0
    , @ModulInfoEinbeziehen          bit             = 1
    , @MaxSqlTextZeichen             int             = 4000
    , @SampleSeconds                 tinyint         = 0
    , @MaxZeilen                     int             = 500
    , @ResultSetArt                  varchar(16)     = 'CONSOLE'
    , @ResultTablesJson              nvarchar(max)   = NULL
    , @JsonErzeugen                  bit             = 0
    , @Json                          nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                bit             = 1
    , @Hilfe                         bit             = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
    DECLARE @RestoreLockTimeoutSql nvarchar(100);
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,N''))));
    DECLARE @DetailMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@Detailgrad,N''))));
    DECLARE @BlockingObjectDepth varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@BlockingObjektTiefe,N''))));

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CurrentOverview';
        PRINT N'Ohne Datenbankfilter werden alle sichtbaren, online befindlichen Benutzerdatenbanken berücksichtigt.';
        PRINT N'@ToolHintergrundabfragenEinbeziehen=0 blendet erkannte Tool-Hintergrundaktivität in Sessions, Requests, Blocking-Blättern und aktuellen Waiting Tasks aus; 1 zeigt sie samt Klassifikation.';
        PRINT N'@Detailgrad=SUMMARY (Default)|RELEVANT|ALL. Leere Childdetails erzeugen kein Grid.';
        PRINT N'@BlockingObjektTiefe=NONE|STANDARD|DEEP; DEEP benötigt LOCKS_DEEP und @HighImpactConfirmed=1.';
        PRINT N'@MaxObjektAufloesungen begrenzt die Blocking-Ressourcenauflösung auf 1 bis 1000 Kandidaten.';
        PRINT N'Children werden genau einmal und nie mit CONSOLE aufgerufen.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet ausschließlich @ResultTablesJson.';
        PRINT N'TABLE-Namen: moduleStatus, snapshotStatus, sessions, requests, requestContext, statements, batches, inputBuffers, blocking, waits, transactions, memoryGrants, tempdbSessions, tempdbGovernance, io, logs, warnings.';
        SET @RestoreLockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
        EXEC [sys].[sp_executesql] @RestoreLockTimeoutSql;
        RETURN;
    END;

    DECLARE @StartedAtUtc datetime2(3)=SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @ExecutedModules int=0;
    DECLARE @FailedModules int=0;
    DECLARE @PartialModules int=0;
    DECLARE @Message nvarchar(2048);
    DECLARE @ChildJson nvarchar(max);
    DECLARE @ChildStartedAtUtc datetime2(3);
    DECLARE @ChildDurationMs bigint;
    DECLARE @CurrentStateSnapshotId uniqueidentifier=NULL;
    DECLARE @SnapshotConsumerId uniqueidentifier=NULL;
    DECLARE @SnapshotPartial bit=0;
    DECLARE @CaptureSessions bit=0;
    DECLARE @CaptureRequests bit=0;
    DECLARE @CaptureConnections bit=0;
    DECLARE @CaptureWaitingTasks bit=0;
    DECLARE @CaptureMemoryGrants bit=0;
    DECLARE @CaptureResourceGovernor bit=0;
    DECLARE @CaptureTasks bit=0;
    DECLARE @CaptureSchedulers bit=0;
    DECLARE @CaptureTransactions bit=0;
    DECLARE @CaptureTempDbUsage bit=0;
    DECLARE @CaptureSqlText bit=0;
    DECLARE @MaxSqlTextHandles int=0;

    CREATE TABLE [#CurrentOverview_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );

    CREATE TABLE [#CurrentOverview_ModulePayload]
    (
          [ModuleOrdinal] int NOT NULL PRIMARY KEY
        , [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [ModuleName] sysname NOT NULL
        , [SourceTable] sysname NOT NULL
        , [IsEnabled] bit NOT NULL
        , [IsRelevant] bit NOT NULL
        , [IsMaterialized] bit NOT NULL
        , [DurationMs] bigint NOT NULL
        , [JsonValue] nvarchar(max) NULL
        , [ExecutionError] nvarchar(2048) NULL
    );

    CREATE TABLE [#CurrentOverview_ModuleStatus]
    (
          [ModuleOrdinal] int NOT NULL
        , [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [ModuleName] sysname NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [ReturnedRowCount] bigint NOT NULL
        , [DurationMs] bigint NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , PRIMARY KEY ([ModuleOrdinal])
    );

    CREATE TABLE [#CurrentOverview_Warnings]
    (
          [ModuleName] sysname NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [Message] nvarchar(2048) NULL
    );

    CREATE TABLE [#CurrentOverview_Sessions]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_Requests]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_RequestContext]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_Statements]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_Batches]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_InputBuffers]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_RequestSnapshotStatus]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_Blocking]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_Waits]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_Transactions]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_MemoryGrants]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_TempDBSessions]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_TempDBGovernance]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_IO]([Seed] bit NULL);
    CREATE TABLE [#CurrentOverview_Logs]([Seed] bit NULL);

    CREATE TABLE [#CurrentOverview_SnapshotStatus]
    (
          [SourceOrdinal] int NOT NULL
        , [SnapshotId] uniqueidentifier NOT NULL
        , [SourceCode] varchar(40) NOT NULL
        , [SourceObject] nvarchar(256) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [CompletedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [CapturedRowCount] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , PRIMARY KEY ([SourceOrdinal])
    );

    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_Context]
    (
          [SnapshotId] uniqueidentifier NOT NULL PRIMARY KEY
        , [OwnerSessionId] smallint NOT NULL
        , [CreatedAtUtc] datetime2(3) NOT NULL
        , [ContractVersion] smallint NOT NULL
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [SourceOrdinal] int NOT NULL
        , [SourceCode] varchar(40) NOT NULL
        , [SourceObject] nvarchar(256) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [CompletedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [CapturedRowCount] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , PRIMARY KEY ([SnapshotId],[SourceCode])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_Sessions]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [session_id] smallint NOT NULL
        , [is_user_process] bit NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [login_name] nvarchar(128) NOT NULL
        , [original_login_name] nvarchar(128) NOT NULL
        , [host_name] nvarchar(128) NULL
        , [program_name] nvarchar(128) NULL
        , [client_interface_name] nvarchar(32) NULL
        , [login_time] datetime NOT NULL
        , [last_request_start_time] datetime NOT NULL
        , [last_request_end_time] datetime NULL
        , [open_transaction_count] int NOT NULL
        , [transaction_isolation_level] smallint NOT NULL
        , [cpu_time] int NOT NULL
        , [reads] bigint NOT NULL
        , [writes] bigint NOT NULL
        , [logical_reads] bigint NOT NULL
        , [memory_usage] int NOT NULL
        , [row_count] bigint NOT NULL
        , PRIMARY KEY ([SnapshotId],[session_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_Requests]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [command] nvarchar(32) NOT NULL
        , [start_time] datetime NOT NULL
        , [sql_handle] varbinary(64) NULL
        , [statement_start_offset] int NULL
        , [statement_end_offset] int NULL
        , [plan_handle] varbinary(64) NULL
        , [database_id] smallint NOT NULL
        , [connection_id] uniqueidentifier NULL
        , [blocking_session_id] smallint NULL
        , [wait_type] nvarchar(60) NULL
        , [wait_time] int NOT NULL
        , [last_wait_type] nvarchar(60) NOT NULL
        , [wait_resource] nvarchar(256) NOT NULL
        , [open_transaction_count] int NOT NULL
        , [open_resultset_count] int NOT NULL
        , [transaction_id] bigint NOT NULL
        , [context_info] varbinary(128) NULL
        , [percent_complete] real NOT NULL
        , [estimated_completion_time] bigint NOT NULL
        , [cpu_time] int NOT NULL
        , [total_elapsed_time] int NOT NULL
        , [scheduler_id] int NULL
        , [task_address] varbinary(8) NULL
        , [reads] bigint NOT NULL
        , [writes] bigint NOT NULL
        , [logical_reads] bigint NOT NULL
        , [transaction_isolation_level] smallint NOT NULL
        , [row_count] bigint NOT NULL
        , [nest_level] int NOT NULL
        , [executing_managed_code] bit NOT NULL
        , [group_id] int NOT NULL
        , [query_hash] binary(8) NULL
        , [query_plan_hash] binary(8) NULL
        , [statement_sql_handle] varbinary(64) NULL
        , [statement_context_id] bigint NULL
        , [dop] int NOT NULL
        , [parallel_worker_count] int NULL
        , [is_resumable] bit NOT NULL
        , PRIMARY KEY ([SnapshotId],[session_id],[request_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_Connections]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [session_id] int NULL
        , [connection_id] uniqueidentifier NOT NULL
        , [most_recent_sql_handle] varbinary(64) NULL
        , [client_net_address] varchar(48) NULL
        , [net_transport] nvarchar(40) NOT NULL
        , [protocol_type] nvarchar(40) NULL
        , [encrypt_option] nvarchar(40) NOT NULL
        , [auth_scheme] nvarchar(40) NOT NULL
        , [connect_time] datetime NOT NULL
        , PRIMARY KEY ([SnapshotId],[connection_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_WaitingTasks]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [waiting_task_address] varbinary(8) NOT NULL
        , [session_id] smallint NULL
        , [exec_context_id] int NULL
        , [wait_duration_ms] bigint NOT NULL
        , [wait_type] nvarchar(60) NOT NULL
        , [resource_address] varbinary(8) NULL
        , [blocking_task_address] varbinary(8) NULL
        , [blocking_session_id] smallint NULL
        , [blocking_exec_context_id] int NULL
        , [resource_description] nvarchar(3072) NULL
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_MemoryGrants]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [scheduler_id] int NULL
        , [dop] smallint NULL
        , [request_time] datetime NULL
        , [grant_time] datetime NULL
        , [wait_time_ms] bigint NULL
        , [requested_memory_kb] bigint NOT NULL
        , [required_memory_kb] bigint NULL
        , [granted_memory_kb] bigint NULL
        , [used_memory_kb] bigint NULL
        , [max_used_memory_kb] bigint NULL
        , [ideal_memory_kb] bigint NULL
        , [resource_semaphore_id] smallint NULL
        , [queue_id] smallint NULL
        , [wait_order] int NULL
        , [is_next_candidate] bit NULL
        , [is_small] bit NULL
        , [plan_handle] varbinary(64) NULL
        , [sql_handle] varbinary(64) NULL
        , [group_id] int NULL
        , [pool_id] int NULL
        , [reserved_worker_count] bigint NULL
        , [used_worker_count] bigint NULL
        , [max_used_worker_count] bigint NULL
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_ResourceSemaphores]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [pool_id] int NOT NULL
        , [resource_semaphore_id] smallint NOT NULL
        , [target_memory_kb] bigint NOT NULL
        , [max_target_memory_kb] bigint NULL
        , [total_memory_kb] bigint NOT NULL
        , [available_memory_kb] bigint NOT NULL
        , [granted_memory_kb] bigint NOT NULL
        , [used_memory_kb] bigint NOT NULL
        , [grantee_count] int NOT NULL
        , [waiter_count] int NOT NULL
        , PRIMARY KEY ([SnapshotId],[pool_id],[resource_semaphore_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [group_id] int NOT NULL
        , [name] sysname NOT NULL
        , [pool_id] int NOT NULL
        , [request_max_memory_grant_percent_numeric] decimal(9,4) NULL
        , [max_request_grant_memory_kb] bigint NULL
        , [configured_group_max_tempdb_data_mb] decimal(19,2) NULL
        , [configured_group_max_tempdb_data_percent] decimal(9,4) NULL
        , [tempdb_maximum_size_mb] decimal(19,2) NULL
        , [effective_group_max_tempdb_data_mb] decimal(19,2) NULL
        , [effective_limit_source] varchar(40) NOT NULL
        , [is_percent_limit_effective] bit NULL
        , [tempdb_data_space_mb] decimal(19,2) NULL
        , [peak_tempdb_data_space_mb] decimal(19,2) NULL
        , [effective_limit_utilization_percent] decimal(9,2) NULL
        , [total_tempdb_data_limit_violation_count] bigint NULL
        , [has_recorded_limit_violation] bit NULL
        , [statistics_start_time] datetime NULL
        , [is_resource_governor_enabled] bit NULL
        , [reconfiguration_pending] bit NULL
        , [tempdb_governance_status_code] varchar(40) NOT NULL
        , [tempdb_governance_is_partial] bit NOT NULL
        , [tempdb_governance_evidence_limit] nvarchar(1000) NULL
        , PRIMARY KEY ([SnapshotId],[group_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_ResourcePools]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [pool_id] int NOT NULL
        , [name] sysname NOT NULL
        , [max_memory_kb] bigint NULL
        , [target_memory_kb] bigint NULL
        , [used_memory_kb] bigint NULL
        , PRIMARY KEY ([SnapshotId],[pool_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_Tasks]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [task_address] varbinary(8) NOT NULL
        , [task_state] nvarchar(60) NOT NULL
        , [session_id] smallint NULL
        , [request_id] int NULL
        , [exec_context_id] int NULL
        , [scheduler_id] int NULL
        , [worker_address] varbinary(8) NULL
        , [parent_task_address] varbinary(8) NULL
        , PRIMARY KEY ([SnapshotId],[task_address])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_Schedulers]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [scheduler_address] varbinary(8) NOT NULL
        , [scheduler_id] int NOT NULL
        , [parent_node_id] int NOT NULL
        , [status] nvarchar(60) NOT NULL
        , [is_online] bit NOT NULL
        , [is_idle] bit NOT NULL
        , [current_tasks_count] int NOT NULL
        , [runnable_tasks_count] int NOT NULL
        , [current_workers_count] int NOT NULL
        , [active_workers_count] int NOT NULL
        , [work_queue_count] bigint NOT NULL
        , [pending_disk_io_count] int NOT NULL
        , [load_factor] int NOT NULL
        , PRIMARY KEY ([SnapshotId],[scheduler_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_SessionTransactions]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [session_id] int NOT NULL
        , [transaction_id] bigint NOT NULL
        , [transaction_descriptor] binary(8) NOT NULL
        , [enlist_count] int NOT NULL
        , [is_user_transaction] bit NOT NULL
        , [is_local] bit NOT NULL
        , [is_enlisted] bit NOT NULL
        , [is_bound] bit NOT NULL
        , [open_transaction_count] int NOT NULL
        , PRIMARY KEY ([SnapshotId],[session_id],[transaction_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_ActiveTransactions]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [transaction_id] bigint NOT NULL
        , [name] nvarchar(32) NOT NULL
        , [transaction_begin_time] datetime NOT NULL
        , [transaction_type] int NOT NULL
        , [transaction_uow] uniqueidentifier NULL
        , [transaction_state] int NOT NULL
        , [transaction_status] int NOT NULL
        , PRIMARY KEY ([SnapshotId],[transaction_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_DatabaseTransactions]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [transaction_id] bigint NOT NULL
        , [database_id] int NOT NULL
        , [database_transaction_begin_time] datetime NULL
        , [database_transaction_type] int NOT NULL
        , [database_transaction_state] int NOT NULL
        , [database_transaction_log_record_count] bigint NOT NULL
        , [database_transaction_log_bytes_used] bigint NOT NULL
        , [database_transaction_log_bytes_reserved] bigint NOT NULL
        , [database_transaction_log_bytes_used_system] bigint NOT NULL
        , [database_transaction_log_bytes_reserved_system] bigint NOT NULL
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [session_id] smallint NOT NULL
        , [user_objects_alloc_page_count] bigint NOT NULL
        , [user_objects_dealloc_page_count] bigint NOT NULL
        , [internal_objects_alloc_page_count] bigint NOT NULL
        , [internal_objects_dealloc_page_count] bigint NOT NULL
        , PRIMARY KEY ([SnapshotId],[session_id])
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_TempDbTaskUsage]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [exec_context_id] int NOT NULL
        , [user_objects_alloc_page_count] bigint NOT NULL
        , [user_objects_dealloc_page_count] bigint NOT NULL
        , [internal_objects_alloc_page_count] bigint NOT NULL
        , [internal_objects_dealloc_page_count] bigint NOT NULL
    );
    CREATE TABLE [#CurrentOverview_CurrentStateSnapshot_SqlText]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [SqlHandle] varbinary(64) NOT NULL
        , [Text] nvarchar(max) NULL
        , [DatabaseId] int NULL
        , [ObjectId] int NULL
        , [ObjectNumber] smallint NULL
        , [IsEncrypted] bit NULL
        , [EvidenceStatus] varchar(40) NOT NULL
        , PRIMARY KEY ([SnapshotId],[SqlHandle])
    );
    IF @OutputMode NOT IN ('RAW','CONSOLE','TABLE','NONE')
       OR @DetailMode NOT IN ('SUMMARY','RELEVANT','ALL')
       OR @BlockingObjectDepth NOT IN ('NONE','STANDARD','DEEP')
       OR @MaxObjektAufloesungen IS NULL OR @MaxObjektAufloesungen NOT BETWEEN 1 AND 1000
       OR @SampleSeconds > 60
       OR @MaxZeilen < 0
       OR @MaxSqlTextZeichen < 0
       OR @JsonErzeugen IS NULL OR @JsonErzeugen NOT IN (0,1)
       OR @SystemdatenbankenEinbeziehen IS NULL OR @SystemdatenbankenEinbeziehen NOT IN (0,1)
       OR @MitSessions IS NULL OR @MitSessions NOT IN (0,1)
       OR @MitRequests IS NULL OR @MitRequests NOT IN (0,1)
       OR @MitBlocking IS NULL OR @MitBlocking NOT IN (0,1)
       OR @MitWaits IS NULL OR @MitWaits NOT IN (0,1)
       OR @MitTransactions IS NULL OR @MitTransactions NOT IN (0,1)
       OR @MitMemoryGrants IS NULL OR @MitMemoryGrants NOT IN (0,1)
       OR @MitTempDB IS NULL OR @MitTempDB NOT IN (0,1)
       OR @MitIO IS NULL OR @MitIO NOT IN (0,1)
       OR @MitLog IS NULL OR @MitLog NOT IN (0,1)
       OR @MitSqlText IS NULL OR @MitSqlText NOT IN (0,1)
       OR @HighImpactConfirmed IS NULL OR @HighImpactConfirmed NOT IN (0,1)
       OR @ToolHintergrundabfragenEinbeziehen IS NULL OR @ToolHintergrundabfragenEinbeziehen NOT IN (0,1)
       OR @GesamtenSqlTextEinbeziehen IS NULL OR @GesamtenSqlTextEinbeziehen NOT IN (0,1)
       OR @InputBufferEinbeziehen IS NULL OR @InputBufferEinbeziehen NOT IN (0,1)
       OR @ModulInfoEinbeziehen IS NULL OR @ModulInfoEinbeziehen NOT IN (0,1)
       OR (@OutputMode<>'TABLE' AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL)
    BEGIN
        SET @StatusCode='INVALID_PARAMETER';
        SET @ErrorMessage=N'Mindestens ein Parameter besitzt einen ungültigen Wert.';
    END;

    IF @StatusCode='AVAILABLE' AND @OutputMode='TABLE'
    BEGIN
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'moduleStatus|snapshotStatus|sessions|requests|requestContext|statements|batches|inputBuffers|blocking|waits|transactions|memoryGrants|tempdbSessions|tempdbGovernance|io|logs|warnings'
            , @MappingTable=N'#CurrentOverview_ResultTableMap'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @ThrowOnError=1;
    END;

    IF @StatusCode<>'AVAILABLE'
    BEGIN
        INSERT [#CurrentOverview_ModuleStatus]
        VALUES(0,N'moduleStatus',N'USP_CurrentOverview',@StatusCode,1,0,0,@ErrorMessage);
        GOTO BuildOutputs;
    END;

    SET @CaptureSessions=CASE WHEN @MitSessions=1 OR @MitRequests=1 OR @MitBlocking=1
        OR @MitWaits=1 OR @MitTransactions=1 OR @MitMemoryGrants=1 OR @MitTempDB=1 THEN 1 ELSE 0 END;
    SET @CaptureRequests=CASE WHEN @MitSessions=1 OR @MitRequests=1 OR @MitBlocking=1
        OR @MitWaits=1 OR @MitTransactions=1 OR @MitMemoryGrants=1 OR @MitIO=1 THEN 1 ELSE 0 END;
    SET @CaptureConnections=CASE WHEN @MitSessions=1 OR @MitRequests=1 OR @MitBlocking=1 THEN 1 ELSE 0 END;
    SET @CaptureWaitingTasks=CASE WHEN @MitRequests=1 OR @MitBlocking=1 OR @MitWaits=1 OR @MitIO=1 THEN 1 ELSE 0 END;
    SET @CaptureMemoryGrants=CASE WHEN @MitRequests=1 OR @MitMemoryGrants=1 THEN 1 ELSE 0 END;
    SET @CaptureResourceGovernor=CASE WHEN @MitRequests=1 OR @MitMemoryGrants=1 OR @MitTempDB=1 THEN 1 ELSE 0 END;
    SET @CaptureTasks=CASE WHEN @MitRequests=1 OR @MitIO=1 THEN 1 ELSE 0 END;
    SET @CaptureSchedulers=CASE WHEN @MitRequests=1 OR @MitIO=1 THEN 1 ELSE 0 END;
    SET @CaptureTransactions=CASE WHEN @MitRequests=1 OR @MitTransactions=1 THEN 1 ELSE 0 END;
    SET @CaptureTempDbUsage=CASE WHEN @MitRequests=1 OR @MitTempDB=1 THEN 1 ELSE 0 END;
    SET @CaptureSqlText=CASE
        WHEN @MitSessions=1 AND @MitSqlText=1 THEN 1
        WHEN @MitRequests=1 AND (@MitSqlText=1 OR @GesamtenSqlTextEinbeziehen=1 OR @ModulInfoEinbeziehen=1) THEN 1
        WHEN @MitBlocking=1 AND @MitSqlText=1 THEN 1
        WHEN @MitWaits=1 AND @MitSqlText=1 THEN 1
        WHEN @MitTransactions=1 AND @MitSqlText=1 THEN 1
        WHEN @MitMemoryGrants=1 AND @MitSqlText=1 THEN 1
        ELSE 0 END;
    SET @MaxSqlTextHandles=CASE
        WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN 0
        WHEN @MaxZeilen>=1073741800 THEN 2147483647
        ELSE @MaxZeilen*2+32 END;

    IF @CaptureSessions=1 OR @CaptureRequests=1 OR @CaptureWaitingTasks=1
       OR @CaptureMemoryGrants=1 OR @CaptureTasks=1 OR @CaptureTransactions=1
       OR @CaptureTempDbUsage=1
    BEGIN
        SET @CurrentStateSnapshotId=NEWID();
        BEGIN TRY
            EXEC [monitor].[InternalCaptureCurrentStateSnapshot]
                  @SnapshotId=@CurrentStateSnapshotId
                , @CaptureSessions=@CaptureSessions
                , @CaptureRequests=@CaptureRequests
                , @CaptureConnections=@CaptureConnections
                , @CaptureWaitingTasks=@CaptureWaitingTasks
                , @CaptureMemoryGrants=@CaptureMemoryGrants
                , @CaptureResourceGovernor=@CaptureResourceGovernor
                , @CaptureTasks=@CaptureTasks
                , @CaptureSchedulers=@CaptureSchedulers
                , @CaptureTransactions=@CaptureTransactions
                , @CaptureTempDbUsage=@CaptureTempDbUsage
                , @CaptureSqlText=@CaptureSqlText
                , @MaxSqlTextHandles=@MaxSqlTextHandles;

            INSERT [#CurrentOverview_SnapshotStatus]
            (
                  [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject],[CapturedAtUtc]
                , [CompletedAtUtc],[StatusCode],[IsPartial],[CapturedRowCount]
                , [ErrorNumber],[ErrorMessage]
            )
            SELECT
                  [SourceOrdinal],@CurrentStateSnapshotId,[SourceCode],[SourceObject],[CapturedAtUtc]
                , [CompletedAtUtc],[StatusCode],[IsPartial],[CapturedRowCount]
                , [ErrorNumber],[ErrorMessage]
            FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            WHERE [SnapshotId]=@CurrentStateSnapshotId;

            SET @SnapshotConsumerId=@CurrentStateSnapshotId;
        END TRY
        BEGIN CATCH
            INSERT [#CurrentOverview_SnapshotStatus]
            VALUES
            (
                  0,@CurrentStateSnapshotId,'SNAPSHOT_OWNER',N'monitor.InternalCaptureCurrentStateSnapshot'
                , @StartedAtUtc,SYSUTCDATETIME(),'ERROR_HANDLED',1,0
                , ERROR_NUMBER(),ERROR_MESSAGE()
            );
            SET @SnapshotConsumerId=NULL;
        END CATCH;
    END;

    SET @SnapshotPartial=CASE WHEN EXISTS
    (
        SELECT 1
        FROM [#CurrentOverview_SnapshotStatus]
        WHERE [IsPartial]=1 OR [StatusCode] NOT IN ('AVAILABLE')
    ) THEN 1 ELSE 0 END;

    /* Sessions */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitSessions=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentSessions]
                  @SessionIds=@SessionIds
                , @ToolHintergrundabfragenEinbeziehen=@ToolHintergrundabfragenEinbeziehen
                , @MitSqlText=@MitSqlText
                , @MaxSqlTextZeichen=@MaxSqlTextZeichen
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"sessions":"#CurrentOverview_Sessions"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(10,N'sessions',N'USP_CurrentSessions',N'#CurrentOverview_Sessions',1,0,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(10,N'sessions',N'USP_CurrentSessions',N'#CurrentOverview_Sessions',1,0,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(10,N'sessions',N'USP_CurrentSessions',N'#CurrentOverview_Sessions',0,0,0,0,NULL,NULL);

    /* Requests */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitRequests=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentRequests]
                  @SessionIds=@SessionIds
                , @ToolHintergrundabfragenEinbeziehen=@ToolHintergrundabfragenEinbeziehen
                , @MitSqlText=@MitSqlText
                , @GesamtenSqlTextEinbeziehen=@GesamtenSqlTextEinbeziehen
                , @InputBufferEinbeziehen=@InputBufferEinbeziehen
                , @ModulInfoEinbeziehen=@ModulInfoEinbeziehen
                , @MaxSqlTextZeichen=@MaxSqlTextZeichen
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{
                      "requests":"#CurrentOverview_Requests",
                      "requestContext":"#CurrentOverview_RequestContext",
                      "snapshotStatus":"#CurrentOverview_RequestSnapshotStatus",
                      "statements":"#CurrentOverview_Statements",
                      "batches":"#CurrentOverview_Batches",
                      "inputBuffers":"#CurrentOverview_InputBuffers"
                  }'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;

            INSERT [#CurrentOverview_SnapshotStatus]
            (
                  [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject],[CapturedAtUtc]
                , [CompletedAtUtc],[StatusCode],[IsPartial],[CapturedRowCount]
                , [ErrorNumber],[ErrorMessage]
            )
            SELECT
                  [r].[SourceOrdinal],[r].[SnapshotId],[r].[SourceCode],[r].[SourceObject]
                , [r].[CapturedAtUtc],[r].[CompletedAtUtc],[r].[StatusCode],[r].[IsPartial]
                , [r].[CapturedRowCount],[r].[ErrorNumber],[r].[ErrorMessage]
            FROM [#CurrentOverview_RequestSnapshotStatus] AS [r]
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM [#CurrentOverview_SnapshotStatus] AS [s]
                WHERE [s].[SourceCode]=[r].[SourceCode]
            );
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(20,N'requests',N'USP_CurrentRequests',N'#CurrentOverview_Requests',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(20,N'requests',N'USP_CurrentRequests',N'#CurrentOverview_Requests',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(20,N'requests',N'USP_CurrentRequests',N'#CurrentOverview_Requests',0,1,0,0,NULL,NULL);

    /* Blocking */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitBlocking=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentBlocking]
                  @SessionIds=@SessionIds
                , @ToolHintergrundabfragenEinbeziehen=@ToolHintergrundabfragenEinbeziehen
                , @MitSqlText=@MitSqlText
                , @MaxSqlTextZeichen=@MaxSqlTextZeichen
                , @BlockingObjektTiefe=@BlockingObjectDepth
                , @MaxObjektAufloesungen=@MaxObjektAufloesungen
                , @HighImpactConfirmed=@HighImpactConfirmed
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"blockingChains":"#CurrentOverview_Blocking"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(30,N'blocking',N'USP_CurrentBlocking',N'#CurrentOverview_Blocking',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(30,N'blocking',N'USP_CurrentBlocking',N'#CurrentOverview_Blocking',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(30,N'blocking',N'USP_CurrentBlocking',N'#CurrentOverview_Blocking',0,1,0,0,NULL,NULL);

    /* Waits */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitWaits=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentWaits]
                  @SessionIds=@SessionIds
                , @ToolHintergrundabfragenEinbeziehen=@ToolHintergrundabfragenEinbeziehen
                , @MitSqlText=@MitSqlText
                , @MaxSqlTextZeichen=@MaxSqlTextZeichen
                , @SampleSeconds=@SampleSeconds
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"currentTasks":"#CurrentOverview_Waits"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(40,N'waits',N'USP_CurrentWaits',N'#CurrentOverview_Waits',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(40,N'waits',N'USP_CurrentWaits',N'#CurrentOverview_Waits',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(40,N'waits',N'USP_CurrentWaits',N'#CurrentOverview_Waits',0,1,0,0,NULL,NULL);

    /* Transactions */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitTransactions=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentTransactions]
                  @SessionIds=@SessionIds
                , @MitSqlText=@MitSqlText
                , @MaxSqlTextZeichen=@MaxSqlTextZeichen
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"transactions":"#CurrentOverview_Transactions"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(50,N'transactions',N'USP_CurrentTransactions',N'#CurrentOverview_Transactions',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(50,N'transactions',N'USP_CurrentTransactions',N'#CurrentOverview_Transactions',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(50,N'transactions',N'USP_CurrentTransactions',N'#CurrentOverview_Transactions',0,1,0,0,NULL,NULL);

    /* Memory grants */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitMemoryGrants=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentMemoryGrants]
                  @SessionIds=@SessionIds
                , @MitSqlText=@MitSqlText
                , @MaxSqlTextZeichen=@MaxSqlTextZeichen
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"memoryGrants":"#CurrentOverview_MemoryGrants"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(60,N'memoryGrants',N'USP_CurrentMemoryGrants',N'#CurrentOverview_MemoryGrants',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(60,N'memoryGrants',N'USP_CurrentMemoryGrants',N'#CurrentOverview_MemoryGrants',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(60,N'memoryGrants',N'USP_CurrentMemoryGrants',N'#CurrentOverview_MemoryGrants',0,1,0,0,NULL,NULL);

    /* TempDB */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitTempDB=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentTempDB]
                  @SessionIds=@SessionIds
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"sessions":"#CurrentOverview_TempDBSessions","tempdbGovernance":"#CurrentOverview_TempDBGovernance"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(70,N'tempdbSessions',N'USP_CurrentTempDB',N'#CurrentOverview_TempDBSessions',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(70,N'tempdbSessions',N'USP_CurrentTempDB',N'#CurrentOverview_TempDBSessions',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(70,N'tempdbSessions',N'USP_CurrentTempDB',N'#CurrentOverview_TempDBSessions',0,1,0,0,NULL,NULL);

    /* I/O */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitIO=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentIO]
                  @DatabaseNames=@DatabaseNames
                , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @SampleSeconds=@SampleSeconds
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"files":"#CurrentOverview_IO"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen
                , @ParentCurrentStateSnapshotId=@SnapshotConsumerId;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(80,N'io',N'USP_CurrentIO',N'#CurrentOverview_IO',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(80,N'io',N'USP_CurrentIO',N'#CurrentOverview_IO',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(80,N'io',N'USP_CurrentIO',N'#CurrentOverview_IO',0,1,0,0,NULL,NULL);

    /* Transaction log */
    SET @ChildJson=NULL;SET @ChildStartedAtUtc=SYSUTCDATETIME();
    IF @MitLog=1
    BEGIN
        SET @ExecutedModules+=1;
        BEGIN TRY
            EXEC [monitor].[USP_CurrentLog]
                  @DatabaseNames=@DatabaseNames
                , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @MaxZeilen=@MaxZeilen
                , @ResultSetArt='TABLE'
                , @ResultTablesJson=N'{"logs":"#CurrentOverview_Logs"}'
                , @JsonErzeugen=1
                , @Json=@ChildJson OUTPUT
                , @PrintMeldungen=@PrintMeldungen;
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(90,N'logs',N'USP_CurrentLog',N'#CurrentOverview_Logs',1,1,1,@ChildDurationMs,@ChildJson,NULL);
        END TRY
        BEGIN CATCH
            SET @ChildDurationMs=DATEDIFF_BIG(MILLISECOND,@ChildStartedAtUtc,SYSUTCDATETIME());
            INSERT [#CurrentOverview_ModulePayload] VALUES(90,N'logs',N'USP_CurrentLog',N'#CurrentOverview_Logs',1,1,0,@ChildDurationMs,@ChildJson,ERROR_MESSAGE());
        END CATCH;
    END
    ELSE INSERT [#CurrentOverview_ModulePayload] VALUES(90,N'logs',N'USP_CurrentLog',N'#CurrentOverview_Logs',0,1,0,0,NULL,NULL);

    SET @SnapshotPartial=CASE WHEN EXISTS
    (
        SELECT 1
        FROM [#CurrentOverview_SnapshotStatus]
        WHERE [IsPartial]=1
           OR [StatusCode] NOT IN ('AVAILABLE','NOT_COLLECTED')
    ) THEN 1 ELSE 0 END;

    INSERT [#CurrentOverview_ModuleStatus]
    (
          [ModuleOrdinal],[ResultName],[ModuleName],[StatusCode],[IsPartial]
        , [ReturnedRowCount],[DurationMs],[ErrorMessage]
    )
    SELECT
          [p].[ModuleOrdinal]
        , [p].[ResultName]
        , [p].[ModuleName]
        , [x].[StatusCode]
        , CONVERT(bit,CASE
              WHEN [p].[IsEnabled]=0 THEN 0
              WHEN [x].[StatusCode]='AVAILABLE'
               AND COALESCE(JSON_VALUE([p].[JsonValue],N'$.meta.isPartial'),N'false')=N'false'
                  THEN 0
              ELSE 1 END)
        , [x].[ReturnedRows]
        , [p].[DurationMs]
        , COALESCE([p].[ExecutionError],JSON_VALUE([p].[JsonValue],N'$.warnings[0].message'))
    FROM [#CurrentOverview_ModulePayload] AS [p]
    CROSS APPLY
    (
        SELECT
              [StatusCode]=CONVERT(varchar(40),CASE
                    WHEN [p].[IsEnabled]=0 THEN 'SKIPPED'
                    WHEN [p].[ExecutionError] IS NOT NULL THEN 'ERROR_HANDLED'
                    WHEN ISJSON([p].[JsonValue])<>1 THEN 'STATUS_UNAVAILABLE'
                    WHEN JSON_VALUE([p].[JsonValue],N'$.meta.statusCode') IS NULL THEN 'STATUS_UNAVAILABLE'
                    WHEN COALESCE
                         (
                             TRY_CONVERT(bigint,JSON_VALUE([p].[JsonValue],N'$.meta.returnedRows')),
                             TRY_CONVERT(bigint,JSON_VALUE([p].[JsonValue],N'$.meta.currentTaskRows'))
                         ) IS NULL THEN 'STATUS_UNAVAILABLE'
                    ELSE JSON_VALUE([p].[JsonValue],N'$.meta.statusCode') END)
            , [ReturnedRows]=CONVERT(bigint,CASE
                    WHEN [p].[IsEnabled]=0 THEN 0
                    ELSE COALESCE
                         (
                             TRY_CONVERT(bigint,JSON_VALUE([p].[JsonValue],N'$.meta.returnedRows')),
                             TRY_CONVERT(bigint,JSON_VALUE([p].[JsonValue],N'$.meta.currentTaskRows')),
                             0
                         ) END)
    ) AS [x];

    INSERT [#CurrentOverview_Warnings]([ModuleName],[StatusCode],[Message])
    SELECT [ModuleName],[StatusCode],[ErrorMessage]
    FROM [#CurrentOverview_ModuleStatus]
    WHERE [IsPartial]=1 OR [StatusCode] NOT IN ('AVAILABLE','SKIPPED');

    INSERT [#CurrentOverview_Warnings]([ModuleName],[StatusCode],[Message])
    SELECT
          N'CurrentStateSnapshot'
        , [StatusCode]
        , COALESCE([ErrorMessage],CONCAT(N'Quelle ',[SourceCode],N' wurde nur teilweise materialisiert.'))
    FROM [#CurrentOverview_SnapshotStatus]
    WHERE [IsPartial]=1 OR [StatusCode] NOT IN ('AVAILABLE','NOT_COLLECTED');

    SELECT
          @FailedModules=COALESCE(SUM(CASE WHEN [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED') THEN 1 ELSE 0 END),0)
        , @PartialModules=COALESCE(SUM(CASE WHEN [IsPartial]=1 THEN 1 ELSE 0 END),0)
    FROM [#CurrentOverview_ModuleStatus];

    SET @StatusCode=CASE
        WHEN @ExecutedModules=0 THEN 'AVAILABLE'
        WHEN @FailedModules=0 AND @PartialModules=0 AND @SnapshotPartial=0 THEN 'AVAILABLE'
        WHEN @FailedModules<@ExecutedModules OR @SnapshotPartial=1 THEN 'AVAILABLE_LIMITED'
        ELSE 'ERROR_HANDLED' END;

BuildOutputs:
    IF @PrintMeldungen=1 AND (@FailedModules>0 OR @PartialModules>0)
    BEGIN
        SET @Message=FORMATMESSAGE(N'HINWEIS USP_CurrentOverview: %d Modul(e) fehlgeschlagen, %d Modul(e) partiell; %d aktiviert.',@FailedModules,@PartialModules,@ExecutedModules);
        RAISERROR(N'%s',10,1,@Message) WITH NOWAIT;
    END;

    IF @OutputMode IN ('CONSOLE','RAW')
    BEGIN
        SELECT
              [ModuleName]
            , [StatusCode]
            , [IsPartial]
            , [ReturnedRowCount]
            , [DurationMs]
            , [ErrorMessage]
        FROM [#CurrentOverview_ModuleStatus]
        ORDER BY [ModuleOrdinal];
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT
              [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject],[CapturedAtUtc],[CompletedAtUtc]
            , [StatusCode],[IsPartial],[CapturedRowCount],[ErrorNumber],[ErrorMessage]
        FROM [#CurrentOverview_SnapshotStatus]
        ORDER BY [SourceOrdinal];

        SELECT [ModuleName],[StatusCode],[Message]
        FROM [#CurrentOverview_Warnings]
        ORDER BY [ModuleName];
    END;

    IF @OutputMode='CONSOLE' AND @DetailMode IN ('RELEVANT','ALL')
    BEGIN
        DECLARE @DetailSourceTable sysname;
        DECLARE @DetailSql nvarchar(max);

        DECLARE [DetailCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [p].[SourceTable]
            FROM [#CurrentOverview_ModulePayload] AS [p]
            INNER JOIN [#CurrentOverview_ModuleStatus] AS [s]
              ON [s].[ModuleOrdinal]=[p].[ModuleOrdinal]
            WHERE [p].[IsEnabled]=1
              AND [p].[IsMaterialized]=1
              AND [s].[ReturnedRowCount]>0
              AND [s].[StatusCode] IN ('AVAILABLE','AVAILABLE_LIMITED')
              AND (@DetailMode='ALL' OR [p].[IsRelevant]=1)
            ORDER BY [p].[ModuleOrdinal];

        OPEN [DetailCursor];
        FETCH NEXT FROM [DetailCursor] INTO @DetailSourceTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @DetailSql=N'SELECT * FROM '+QUOTENAME(@DetailSourceTable)+N';';
            EXEC [sys].[sp_executesql] @DetailSql;
            FETCH NEXT FROM [DetailCursor] INTO @DetailSourceTable;
        END;
        CLOSE [DetailCursor];
        DEALLOCATE [DetailCursor];
    END;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=
        (
            SELECT
                  N'CurrentOverview' AS [resultName]
                , 4 AS [schemaVersion]
                , @StartedAtUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @CurrentStateSnapshotId AS [evidenceSnapshotId]
                , CONVERT(bit,CASE WHEN @PartialModules>0 OR @FailedModules>0 OR @SnapshotPartial=1 THEN 1 ELSE 0 END) AS [isPartial]
                , @ExecutedModules AS [executedModules]
                , @FailedModules AS [failedModules]
                , @PartialModules AS [partialModules]
                , @ToolHintergrundabfragenEinbeziehen AS [toolBackgroundQueriesIncluded]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES
        );
        DECLARE @ModuleStatusJson nvarchar(max)=
        (
            SELECT [ResultName],[ModuleName],[StatusCode],[IsPartial],[ReturnedRowCount],[DurationMs],[ErrorMessage]
            FROM [#CurrentOverview_ModuleStatus]
            ORDER BY [ModuleOrdinal]
            FOR JSON PATH,INCLUDE_NULL_VALUES
        );
        DECLARE @SnapshotStatusJson nvarchar(max)=
        (
            SELECT
                  [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject],[CapturedAtUtc],[CompletedAtUtc]
                , [StatusCode],[IsPartial],[CapturedRowCount],[ErrorNumber],[ErrorMessage]
            FROM [#CurrentOverview_SnapshotStatus]
            ORDER BY [SourceOrdinal]
            FOR JSON PATH,INCLUDE_NULL_VALUES
        );
        DECLARE @WarningsJson nvarchar(max)=
        (
            SELECT [ModuleName],[StatusCode],[Message]
            FROM [#CurrentOverview_Warnings]
            ORDER BY [ModuleName]
            FOR JSON PATH,INCLUDE_NULL_VALUES
        );
        DECLARE @ChildProperties nvarchar(max)=
        (
            SELECT STRING_AGG
            (
                CONVERT(nvarchar(max),CONCAT(N'"',STRING_ESCAPE([ResultName],'json'),N'":',
                    CASE WHEN ISJSON([JsonValue])=1 THEN [JsonValue] ELSE N'null' END)),
                N','
            ) WITHIN GROUP (ORDER BY [ModuleOrdinal])
            FROM [#CurrentOverview_ModulePayload]
            WHERE [IsEnabled]=1
        );

        SET @Json=CONCAT
        (
              N'{"meta":',COALESCE(@MetaJson,N'{}')
            , N',"moduleStatus":',COALESCE(@ModuleStatusJson,N'[]')
            , N',"snapshotStatus":',COALESCE(@SnapshotStatusJson,N'[]')
            , CASE WHEN NULLIF(@ChildProperties,N'') IS NULL THEN N'' ELSE N','+@ChildProperties END
            , N',"warnings":',COALESCE(@WarningsJson,N'[]'),N'}'
        );
    END;

    IF @OutputMode='TABLE'
    BEGIN
        DECLARE @ExportResultName sysname;
        DECLARE @ExportTargetTable sysname;
        DECLARE @ExportSourceTable sysname;
        DECLARE @CanExport bit;

        DECLARE [ExportCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [ResultName],[TargetTable]
            FROM [#CurrentOverview_ResultTableMap]
            ORDER BY [ResultName];

        OPEN [ExportCursor];
        FETCH NEXT FROM [ExportCursor] INTO @ExportResultName,@ExportTargetTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SELECT
                  @ExportSourceTable=CASE
                      WHEN @ExportResultName=N'moduleStatus' THEN N'#CurrentOverview_ModuleStatus'
                      WHEN @ExportResultName=N'snapshotStatus' THEN N'#CurrentOverview_SnapshotStatus'
                      WHEN @ExportResultName=N'requestContext' THEN N'#CurrentOverview_RequestContext'
                      WHEN @ExportResultName=N'statements' THEN N'#CurrentOverview_Statements'
                      WHEN @ExportResultName=N'batches' THEN N'#CurrentOverview_Batches'
                      WHEN @ExportResultName=N'inputBuffers' THEN N'#CurrentOverview_InputBuffers'
                      WHEN @ExportResultName=N'tempdbGovernance' THEN N'#CurrentOverview_TempDBGovernance'
                      WHEN @ExportResultName=N'warnings' THEN N'#CurrentOverview_Warnings'
                      ELSE NULL END
                , @CanExport=CASE
                    WHEN @ExportResultName=N'tempdbGovernance' THEN @MitTempDB
                    WHEN @ExportResultName IN
                         (N'moduleStatus',N'snapshotStatus',N'requestContext',
                          N'statements',N'batches',N'inputBuffers',N'warnings')
                        THEN 1
                    ELSE 0
                  END;

            IF @ExportSourceTable IS NULL
                SELECT
                      @ExportSourceTable=[SourceTable]
                    , @CanExport=[IsMaterialized]
                FROM [#CurrentOverview_ModulePayload]
                WHERE [ResultName]=@ExportResultName;

            IF @CanExport=1
                EXEC [monitor].[InternalWriteResultTable]
                      @SourceTable=@ExportSourceTable
                    , @TargetTable=@ExportTargetTable
                    , @ThrowOnError=1;

            FETCH NEXT FROM [ExportCursor] INTO @ExportResultName,@ExportTargetTable;
        END;
        CLOSE [ExportCursor];
        DEALLOCATE [ExportCursor];
    END;

    SET @RestoreLockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
    EXEC [sys].[sp_executesql] @RestoreLockTimeoutSql;
END;
GO
