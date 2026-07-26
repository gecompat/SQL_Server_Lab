USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalCaptureCurrentStateSnapshot
Version      : 2.1.0
Stand        : 2026-07-23
Typ          : Interne Stored Procedure
Zweck        : Schreibt die vom aufrufenden Orchestrator angelegten lokalen
               Snapshot-Tabellen. Jede aktivierte Systemquelle wird genau
               einmal gelesen; nicht angeforderte Quellen werden nicht berührt.
               SQL25-003 ergänzt den vorhandenen Workload-Group-Snapshot
               versions- und capability-adaptiv.
Lebensdauer  : Der Aufrufer besitzt die lokalen Temp-Tabellen. Sie verschwinden
               mit dessen Procedure-Scope und können von einem späteren
               Einzelaufruf nicht wiederverwendet werden.
Sicherheit   : Read-only. Keine Konfiguration, Persistenz oder Rechtevergabe.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalCaptureCurrentStateSnapshot]
      @SnapshotId              uniqueidentifier
    , @CaptureSessions         bit = 0
    , @CaptureRequests         bit = 0
    , @CaptureConnections      bit = 0
    , @CaptureWaitingTasks     bit = 0
    , @CaptureMemoryGrants     bit = 0
    , @CaptureResourceGovernor bit = 0
    , @CaptureTasks            bit = 0
    , @CaptureSchedulers       bit = 0
    , @CaptureTransactions     bit = 0
    , @CaptureTempDbUsage      bit = 0
    , @CaptureSqlText          bit = 0
    , @MaxSqlTextHandles       int = 1000
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    IF @SnapshotId IS NULL
        THROW 51020, N'@SnapshotId darf nicht NULL sein.', 1;

    IF @CaptureSessions IS NULL OR @CaptureSessions NOT IN (0,1)
       OR @CaptureRequests IS NULL OR @CaptureRequests NOT IN (0,1)
       OR @CaptureConnections IS NULL OR @CaptureConnections NOT IN (0,1)
       OR @CaptureWaitingTasks IS NULL OR @CaptureWaitingTasks NOT IN (0,1)
       OR @CaptureMemoryGrants IS NULL OR @CaptureMemoryGrants NOT IN (0,1)
       OR @CaptureResourceGovernor IS NULL OR @CaptureResourceGovernor NOT IN (0,1)
       OR @CaptureTasks IS NULL OR @CaptureTasks NOT IN (0,1)
       OR @CaptureSchedulers IS NULL OR @CaptureSchedulers NOT IN (0,1)
       OR @CaptureTransactions IS NULL OR @CaptureTransactions NOT IN (0,1)
       OR @CaptureTempDbUsage IS NULL OR @CaptureTempDbUsage NOT IN (0,1)
       OR @CaptureSqlText IS NULL OR @CaptureSqlText NOT IN (0,1)
       OR @MaxSqlTextHandles IS NULL OR @MaxSqlTextHandles < 0
        THROW 51020, N'Ungültiger Current-State-Snapshot-Parameter.', 1;

    BEGIN TRY
        EXEC [sys].[sp_executesql] N'
            DECLARE @Probe int;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Context] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Sessions] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Requests] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Connections] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_WaitingTasks] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_MemoryGrants] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_ResourceSemaphores] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_ResourcePools] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Tasks] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Schedulers] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SessionTransactions] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_ActiveTransactions] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_DatabaseTransactions] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_TempDbTaskUsage] WHERE 1=0;
            SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SqlText] WHERE 1=0;';
    END TRY
    BEGIN CATCH
        THROW 51020, N'Der aufrufende Snapshot-Owner hat den Temp-Table-Vertrag nicht vollständig angelegt.', 1;
    END CATCH;

    IF EXISTS
    (
        SELECT 1
        FROM [#CurrentOverview_CurrentStateSnapshot_Context]
        WHERE [SnapshotId] = @SnapshotId
    )
        THROW 51020, N'Diese Snapshot-ID wurde im aktuellen Aufruf bereits verwendet.', 1;

    INSERT [#CurrentOverview_CurrentStateSnapshot_Context]
    (
        [SnapshotId],[OwnerSessionId],[CreatedAtUtc],[ContractVersion]
    )
    VALUES
    (
        @SnapshotId,CONVERT(smallint,@@SPID),SYSUTCDATETIME(),2
    );

    DECLARE @HasFullView bit =
        CASE
            WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 1
            WHEN TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion')) >= 16
                THEN COALESCE(HAS_PERMS_BY_NAME(NULL,N'SERVER',N'VIEW SERVER PERFORMANCE STATE'),0)
            ELSE COALESCE(HAS_PERMS_BY_NAME(NULL,N'SERVER',N'VIEW SERVER STATE'),0)
        END;
    DECLARE @CapturedAtUtc datetime2(3);
    DECLARE @CompletedAtUtc datetime2(3);
    DECLARE @RowCount bigint;
    DECLARE @ErrorNumber int;
    DECLARE @ErrorMessage nvarchar(2048);
    DECLARE @StatusCode varchar(40);
    DECLARE @IsPartial bit;
    DECLARE @BaseStatusCode varchar(40)=CASE WHEN @HasFullView=1 THEN 'AVAILABLE' ELSE 'AVAILABLE_LIMITED' END;
    DECLARE @BaseIsPartial bit=CASE WHEN @HasFullView=1 THEN 0 ELSE 1 END;

    IF @CaptureSessions=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_Sessions]
            (
                [SnapshotId],[CapturedAtUtc],[session_id],[is_user_process],[status],
                [login_name],[original_login_name],[host_name],[program_name],
                [client_interface_name],[login_time],[last_request_start_time],
                [last_request_end_time],[open_transaction_count],
                [transaction_isolation_level],[cpu_time],[reads],[writes],
                [logical_reads],[memory_usage],[row_count]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[s].[session_id],[s].[is_user_process],[s].[status],
                [s].[login_name],[s].[original_login_name],[s].[host_name],[s].[program_name],
                [s].[client_interface_name],[s].[login_time],[s].[last_request_start_time],
                [s].[last_request_end_time],[s].[open_transaction_count],
                [s].[transaction_isolation_level],[s].[cpu_time],[s].[reads],[s].[writes],
                [s].[logical_reads],[s].[memory_usage],[s].[row_count]
            FROM [sys].[dm_exec_sessions] AS [s] WITH (NOLOCK);

            SELECT @RowCount=COUNT_BIG(*)
            FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups]
            WHERE [SnapshotId]=@SnapshotId;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,10,'SESSIONS',N'sys.dm_exec_sessions',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,10,'SESSIONS',N'sys.dm_exec_sessions',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureRequests=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_Requests]
            (
                [SnapshotId],[CapturedAtUtc],[session_id],[request_id],[status],[command],
                [start_time],[sql_handle],[statement_start_offset],[statement_end_offset],
                [plan_handle],[database_id],[connection_id],[blocking_session_id],
                [wait_type],[wait_time],[last_wait_type],[wait_resource],
                [open_transaction_count],[open_resultset_count],[transaction_id],
                [context_info],[percent_complete],[estimated_completion_time],
                [cpu_time],[total_elapsed_time],[scheduler_id],[task_address],
                [reads],[writes],[logical_reads],[transaction_isolation_level],
                [row_count],[nest_level],[executing_managed_code],[group_id],
                [query_hash],[query_plan_hash],[statement_sql_handle],
                [statement_context_id],[dop],[parallel_worker_count],[is_resumable]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[r].[session_id],[r].[request_id],[r].[status],[r].[command],
                [r].[start_time],[r].[sql_handle],[r].[statement_start_offset],[r].[statement_end_offset],
                [r].[plan_handle],[r].[database_id],[r].[connection_id],[r].[blocking_session_id],
                [r].[wait_type],[r].[wait_time],[r].[last_wait_type],[r].[wait_resource],
                [r].[open_transaction_count],[r].[open_resultset_count],[r].[transaction_id],
                [r].[context_info],[r].[percent_complete],[r].[estimated_completion_time],
                [r].[cpu_time],[r].[total_elapsed_time],[r].[scheduler_id],[r].[task_address],
                [r].[reads],[r].[writes],[r].[logical_reads],[r].[transaction_isolation_level],
                [r].[row_count],[r].[nest_level],[r].[executing_managed_code],[r].[group_id],
                [r].[query_hash],[r].[query_plan_hash],[r].[statement_sql_handle],
                [r].[statement_context_id],[r].[dop],[r].[parallel_worker_count],[r].[is_resumable]
            FROM [sys].[dm_exec_requests] AS [r] WITH (NOLOCK);

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,20,'REQUESTS',N'sys.dm_exec_requests',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,20,'REQUESTS',N'sys.dm_exec_requests',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureConnections=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_Connections]
            (
                [SnapshotId],[CapturedAtUtc],[session_id],[connection_id],
                [most_recent_sql_handle],[client_net_address],[net_transport],
                [protocol_type],[encrypt_option],[auth_scheme],[connect_time]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[c].[session_id],[c].[connection_id],
                [c].[most_recent_sql_handle],[c].[client_net_address],[c].[net_transport],
                [c].[protocol_type],[c].[encrypt_option],[c].[auth_scheme],[c].[connect_time]
            FROM [sys].[dm_exec_connections] AS [c] WITH (NOLOCK);

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,30,'CONNECTIONS',N'sys.dm_exec_connections',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,30,'CONNECTIONS',N'sys.dm_exec_connections',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureWaitingTasks=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_WaitingTasks]
            (
                [SnapshotId],[CapturedAtUtc],[waiting_task_address],[session_id],
                [exec_context_id],[wait_duration_ms],[wait_type],[resource_address],
                [blocking_task_address],[blocking_session_id],
                [blocking_exec_context_id],[resource_description]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[w].[waiting_task_address],[w].[session_id],
                [w].[exec_context_id],[w].[wait_duration_ms],[w].[wait_type],[w].[resource_address],
                [w].[blocking_task_address],[w].[blocking_session_id],
                [w].[blocking_exec_context_id],[w].[resource_description]
            FROM [sys].[dm_os_waiting_tasks] AS [w] WITH (NOLOCK);

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,40,'WAITING_TASKS',N'sys.dm_os_waiting_tasks',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,40,'WAITING_TASKS',N'sys.dm_os_waiting_tasks',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureMemoryGrants=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_MemoryGrants]
            (
                [SnapshotId],[CapturedAtUtc],[session_id],[request_id],
                [scheduler_id],[dop],[request_time],[grant_time],[wait_time_ms],
                [requested_memory_kb],[required_memory_kb],[granted_memory_kb],
                [used_memory_kb],[max_used_memory_kb],[ideal_memory_kb],
                [resource_semaphore_id],[queue_id],[wait_order],[is_next_candidate],
                [is_small],[plan_handle],[sql_handle],[group_id],[pool_id],
                [reserved_worker_count],[used_worker_count],[max_used_worker_count]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[g].[session_id],[g].[request_id],
                [g].[scheduler_id],[g].[dop],[g].[request_time],[g].[grant_time],[g].[wait_time_ms],
                [g].[requested_memory_kb],[g].[required_memory_kb],[g].[granted_memory_kb],
                [g].[used_memory_kb],[g].[max_used_memory_kb],[g].[ideal_memory_kb],
                [g].[resource_semaphore_id],[g].[queue_id],[g].[wait_order],[g].[is_next_candidate],
                [g].[is_small],[g].[plan_handle],[g].[sql_handle],[g].[group_id],[g].[pool_id],
                [g].[reserved_worker_count],[g].[used_worker_count],[g].[max_used_worker_count]
            FROM [sys].[dm_exec_query_memory_grants] AS [g] WITH (NOLOCK);

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,50,'MEMORY_GRANTS',N'sys.dm_exec_query_memory_grants',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,50,'MEMORY_GRANTS',N'sys.dm_exec_query_memory_grants',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;

        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_ResourceSemaphores]
            (
                [SnapshotId],[CapturedAtUtc],[pool_id],[resource_semaphore_id],
                [target_memory_kb],[max_target_memory_kb],[total_memory_kb],
                [available_memory_kb],[granted_memory_kb],[used_memory_kb],
                [grantee_count],[waiter_count]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[s].[pool_id],[s].[resource_semaphore_id],
                [s].[target_memory_kb],[s].[max_target_memory_kb],[s].[total_memory_kb],
                [s].[available_memory_kb],[s].[granted_memory_kb],[s].[used_memory_kb],
                [s].[grantee_count],[s].[waiter_count]
            FROM [sys].[dm_exec_query_resource_semaphores] AS [s] WITH (NOLOCK);

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,55,'RESOURCE_SEMAPHORES',N'sys.dm_exec_query_resource_semaphores',
             @CapturedAtUtc,@CompletedAtUtc,@BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,55,'RESOURCE_SEMAPHORES',N'sys.dm_exec_query_resource_semaphores',
             @CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureResourceGovernor=1
    BEGIN
        DECLARE @ProductMajorVersion int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
        DECLARE @CatalogTempdbColumnsValid bit=0;
        DECLARE @RuntimeTempdbColumnsValid bit=0;
        DECLARE @TempdbGovernanceStatus varchar(40)=
            CASE WHEN @ProductMajorVersion IS NULL OR @ProductMajorVersion<17
                 THEN 'UNAVAILABLE_VERSION' ELSE 'AVAILABLE' END;
        DECLARE @TempdbGovernanceErrorNumber int=NULL;
        DECLARE @TempdbGovernanceErrorMessage nvarchar(2048)=NULL;
        DECLARE @TempdbMaximumSizeMb decimal(19,2)=NULL;
        DECLARE @TempdbFileStatus varchar(40)='NOT_APPLICABLE';
        DECLARE @TempdbFileErrorNumber int=NULL;
        DECLARE @TempdbFileErrorMessage nvarchar(2048)=NULL;
        DECLARE @IsResourceGovernorEnabled bit=NULL;
        DECLARE @ReconfigurationPending bit=NULL;
        DECLARE @ResourceGovernorSql nvarchar(max);

        IF @ProductMajorVersion>=17
        BEGIN TRY
            SELECT
                  @CatalogTempdbColumnsValid=CONVERT
                  (
                      bit,
                      CASE WHEN SUM(CASE WHEN [o].[name]=N'resource_governor_workload_groups'
                                          AND [c].[name] IN
                                              (N'group_max_tempdb_data_mb',N'group_max_tempdb_data_percent')
                                        THEN 1 ELSE 0 END)=2
                           THEN 1 ELSE 0 END
                  )
                , @RuntimeTempdbColumnsValid=CONVERT
                  (
                      bit,
                      CASE WHEN SUM(CASE WHEN [o].[name]=N'dm_resource_governor_workload_groups'
                                          AND [c].[name] IN
                                              (N'tempdb_data_space_kb',N'peak_tempdb_data_space_kb',
                                               N'total_tempdb_data_limit_violation_count')
                                        THEN 1 ELSE 0 END)=3
                           THEN 1 ELSE 0 END
                  )
            FROM [sys].[all_columns] AS [c] WITH (NOLOCK)
            INNER JOIN [sys].[all_objects] AS [o] WITH (NOLOCK)
              ON [o].[object_id]=[c].[object_id]
            INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
              ON [s].[schema_id]=[o].[schema_id]
            WHERE [s].[name]=N'sys'
              AND [o].[name] IN
                  (N'resource_governor_workload_groups',N'dm_resource_governor_workload_groups');

            IF @CatalogTempdbColumnsValid=0 OR @RuntimeTempdbColumnsValid=0
                SET @TempdbGovernanceStatus='UNAVAILABLE_SOURCE_SCHEMA';
        END TRY
        BEGIN CATCH
            SELECT
                  @TempdbGovernanceErrorNumber=ERROR_NUMBER()
                , @TempdbGovernanceErrorMessage=ERROR_MESSAGE()
                , @TempdbGovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                     WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                     ELSE 'ERROR_HANDLED' END;
        END CATCH;

        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            DECLARE @RuntimeProjection nvarchar(max)=
                CASE WHEN @ProductMajorVersion>=17 AND @RuntimeTempdbColumnsValid=1
                     THEN N',CONVERT(decimal(19,2),[g].[tempdb_data_space_kb]/1024.0)
                             ,CONVERT(decimal(19,2),[g].[peak_tempdb_data_space_kb]/1024.0)
                             ,CONVERT(decimal(9,2),NULL)
                             ,CONVERT(bigint,[g].[total_tempdb_data_limit_violation_count])
                             ,CONVERT(bit,CASE WHEN [g].[total_tempdb_data_limit_violation_count]>0 THEN 1 ELSE 0 END)'
                     ELSE N',CONVERT(decimal(19,2),NULL),CONVERT(decimal(19,2),NULL)
                             ,CONVERT(decimal(9,2),NULL),CONVERT(bigint,NULL),CONVERT(bit,NULL)' END;

            SET @ResourceGovernorSql=N'
INSERT [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups]
(
      [SnapshotId],[CapturedAtUtc],[group_id],[name],[pool_id]
    , [request_max_memory_grant_percent_numeric],[max_request_grant_memory_kb]
    , [configured_group_max_tempdb_data_mb],[configured_group_max_tempdb_data_percent]
    , [tempdb_maximum_size_mb],[effective_group_max_tempdb_data_mb]
    , [effective_limit_source],[is_percent_limit_effective]
    , [tempdb_data_space_mb],[peak_tempdb_data_space_mb]
    , [effective_limit_utilization_percent]
    , [total_tempdb_data_limit_violation_count],[has_recorded_limit_violation]
    , [statistics_start_time],[is_resource_governor_enabled],[reconfiguration_pending]
    , [tempdb_governance_status_code],[tempdb_governance_is_partial]
    , [tempdb_governance_evidence_limit]
)
SELECT
      @SnapshotId,@CapturedAtUtc,[g].[group_id],[g].[name],[g].[pool_id]
    , CONVERT(decimal(9,4),[g].[request_max_memory_grant_percent_numeric])
    , [g].[max_request_grant_memory_kb]
    , CONVERT(decimal(19,2),NULL),CONVERT(decimal(9,4),NULL)
    , CONVERT(decimal(19,2),NULL),CONVERT(decimal(19,2),NULL)
    , CONVERT(varchar(40),''UNAVAILABLE''),CONVERT(bit,NULL)'
    +@RuntimeProjection+
N'
    , [g].[statistics_start_time],CONVERT(bit,NULL),CONVERT(bit,NULL)
    , @TempdbStatus
    , CONVERT(bit,CASE WHEN @TempdbStatus=''AVAILABLE'' THEN 0 ELSE 1 END)
    , CASE WHEN @TempdbStatus=''UNAVAILABLE_VERSION''
           THEN N''TempDB Resource Governance beginnt mit SQL Server 2025 (17.x).''
           WHEN @TempdbStatus<>''AVAILABLE''
           THEN N''Die SQL-Server-2025-Quelle ist nicht vollständig verfügbar.''
           ELSE N''Workload-Group-Zähler sind nicht direkt mit Sessionzählern addierbar; Version Store und TempDB-Log sind nicht umfasst.'' END
FROM [sys].[dm_resource_governor_workload_groups] AS [g] WITH (NOLOCK);';

            EXEC [sys].[sp_executesql]
                  @ResourceGovernorSql
                , N'@SnapshotId uniqueidentifier,@CapturedAtUtc datetime2(3),@TempdbStatus varchar(40)'
                , @SnapshotId=@SnapshotId
                , @CapturedAtUtc=@CapturedAtUtc
                , @TempdbStatus=@TempdbGovernanceStatus;

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (
                 @SnapshotId,60,'WORKLOAD_GROUPS',N'sys.dm_resource_governor_workload_groups'
                ,@CapturedAtUtc,@CompletedAtUtc,@BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL
            );
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (
                 @SnapshotId,60,'WORKLOAD_GROUPS',N'sys.dm_resource_governor_workload_groups'
                ,@CapturedAtUtc,@CompletedAtUtc
                ,CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT'
                      WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                      ELSE 'ERROR_HANDLED' END
                ,1,0,@ErrorNumber,@ErrorMessage
            );
            SELECT
                  @TempdbGovernanceStatus=CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT'
                       WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                       ELSE 'ERROR_HANDLED' END
                , @TempdbGovernanceErrorNumber=@ErrorNumber
                , @TempdbGovernanceErrorMessage=@ErrorMessage;
        END CATCH;

        IF @ProductMajorVersion>=17
           AND EXISTS
               (
                   SELECT 1
                   FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups]
                   WHERE [SnapshotId]=@SnapshotId
               )
        BEGIN
            IF @CatalogTempdbColumnsValid=1
            BEGIN TRY
                SET @ResourceGovernorSql=N'
UPDATE [target]
SET
      [configured_group_max_tempdb_data_mb]=
          CONVERT(decimal(19,2),[source].[group_max_tempdb_data_mb])
    , [configured_group_max_tempdb_data_percent]=
          CONVERT(decimal(9,4),[source].[group_max_tempdb_data_percent])
FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups] AS [target]
INNER JOIN [sys].[resource_governor_workload_groups] AS [source] WITH (NOLOCK)
  ON [source].[group_id]=[target].[group_id]
WHERE [target].[SnapshotId]=@SnapshotId;';

                EXEC [sys].[sp_executesql]
                      @ResourceGovernorSql
                    , N'@SnapshotId uniqueidentifier'
                    , @SnapshotId=@SnapshotId;
            END TRY
            BEGIN CATCH
                SELECT
                      @TempdbGovernanceErrorNumber=ERROR_NUMBER()
                    , @TempdbGovernanceErrorMessage=ERROR_MESSAGE()
                    , @TempdbGovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                         WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                         ELSE 'ERROR_HANDLED' END;
            END CATCH;

            BEGIN TRY
                SELECT
                      @IsResourceGovernorEnabled=[stored].[is_enabled]
                    , @ReconfigurationPending=[effective].[is_reconfiguration_pending]
                FROM [sys].[resource_governor_configuration] AS [stored] WITH (NOLOCK)
                CROSS JOIN [sys].[dm_resource_governor_configuration] AS [effective] WITH (NOLOCK);
            END TRY
            BEGIN CATCH
                SELECT
                      @TempdbGovernanceErrorNumber=ERROR_NUMBER()
                    , @TempdbGovernanceErrorMessage=ERROR_MESSAGE()
                    , @TempdbGovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                         WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                         ELSE 'ERROR_HANDLED' END;
            END CATCH;

            IF @TempdbGovernanceStatus='AVAILABLE'
               AND EXISTS
                   (
                       SELECT 1
                       FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups]
                       WHERE [SnapshotId]=@SnapshotId
                         AND [configured_group_max_tempdb_data_mb] IS NULL
                         AND [configured_group_max_tempdb_data_percent] IS NOT NULL
                   )
            BEGIN
                SET @TempdbFileStatus='AVAILABLE';
                BEGIN TRY
                    SELECT @TempdbMaximumSizeMb=
                        CASE
                            WHEN COUNT_BIG(*)>0
                             AND
                             (
                                 SUM(CASE WHEN [f].[max_size]<>-1 AND [f].[growth]>0 THEN 1 ELSE 0 END)=COUNT_BIG(*)
                                 OR
                                 SUM(CASE WHEN [f].[max_size]=-1 AND [f].[growth]=0 THEN 1 ELSE 0 END)=COUNT_BIG(*)
                             )
                            THEN CONVERT
                                 (
                                     decimal(19,2),
                                     SUM(CASE WHEN [f].[growth]=0 THEN CONVERT(bigint,[f].[size])
                                              ELSE CONVERT(bigint,[f].[max_size]) END)*8.0/1024.0
                                 )
                        END
                    FROM [master].[sys].[master_files] AS [f] WITH (NOLOCK)
                    WHERE [f].[database_id]=2 AND [f].[type]=0;
                END TRY
                BEGIN CATCH
                    SELECT
                          @TempdbFileErrorNumber=ERROR_NUMBER()
                        , @TempdbFileErrorMessage=ERROR_MESSAGE()
                        , @TempdbFileStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                             WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                             ELSE 'ERROR_HANDLED' END;
                END CATCH;
            END;

            UPDATE [g]
            SET
                  [tempdb_maximum_size_mb]=@TempdbMaximumSizeMb
                , [effective_group_max_tempdb_data_mb]=CONVERT
                  (
                      decimal(19,2),
                      CASE
                          WHEN @TempdbGovernanceStatus<>'AVAILABLE' THEN NULL
                          WHEN [g].[configured_group_max_tempdb_data_mb] IS NULL
                           AND [g].[configured_group_max_tempdb_data_percent] IS NULL THEN NULL
                          WHEN @ReconfigurationPending=1 OR COALESCE(@IsResourceGovernorEnabled,0)=0 THEN NULL
                          WHEN [g].[configured_group_max_tempdb_data_mb] IS NOT NULL
                              THEN [g].[configured_group_max_tempdb_data_mb]
                          WHEN @TempdbFileStatus<>'AVAILABLE' THEN NULL
                          WHEN @TempdbMaximumSizeMb IS NOT NULL
                              THEN [g].[configured_group_max_tempdb_data_percent]*@TempdbMaximumSizeMb/100.0
                      END
                  )
                , [effective_limit_source]=CASE
                      WHEN @TempdbGovernanceStatus<>'AVAILABLE' THEN 'UNAVAILABLE'
                      WHEN [g].[configured_group_max_tempdb_data_mb] IS NULL
                       AND [g].[configured_group_max_tempdb_data_percent] IS NULL THEN 'NO_LIMIT_CONFIGURED'
                      WHEN @ReconfigurationPending=1 THEN 'RECONFIGURATION_PENDING'
                      WHEN COALESCE(@IsResourceGovernorEnabled,0)=0 THEN 'RESOURCE_GOVERNOR_DISABLED'
                      WHEN [g].[configured_group_max_tempdb_data_mb] IS NOT NULL THEN 'FIXED_MB_EFFECTIVE'
                      WHEN @TempdbFileStatus<>'AVAILABLE' THEN 'UNAVAILABLE'
                      WHEN @TempdbMaximumSizeMb IS NOT NULL THEN 'PERCENT_EFFECTIVE'
                      ELSE 'PERCENT_NOT_EFFECTIVE'
                  END
                , [is_percent_limit_effective]=CASE
                      WHEN [g].[configured_group_max_tempdb_data_percent] IS NULL THEN NULL
                      WHEN [g].[configured_group_max_tempdb_data_mb] IS NOT NULL THEN CONVERT(bit,0)
                      WHEN @ReconfigurationPending=1 OR COALESCE(@IsResourceGovernorEnabled,0)=0 THEN CONVERT(bit,0)
                      WHEN @TempdbFileStatus<>'AVAILABLE' THEN NULL
                      WHEN @TempdbMaximumSizeMb IS NOT NULL THEN CONVERT(bit,1)
                      ELSE CONVERT(bit,0)
                  END
                , [effective_limit_utilization_percent]=CONVERT
                  (
                      decimal(9,2),
                      100.0*[g].[tempdb_data_space_mb]
                      /NULLIF
                       (
                           CASE
                               WHEN @ReconfigurationPending=0 AND COALESCE(@IsResourceGovernorEnabled,0)=1
                                AND [g].[configured_group_max_tempdb_data_mb] IS NOT NULL
                                   THEN [g].[configured_group_max_tempdb_data_mb]
                               WHEN @ReconfigurationPending=0 AND COALESCE(@IsResourceGovernorEnabled,0)=1
                                AND [g].[configured_group_max_tempdb_data_mb] IS NULL
                                AND @TempdbMaximumSizeMb IS NOT NULL
                                   THEN [g].[configured_group_max_tempdb_data_percent]*@TempdbMaximumSizeMb/100.0
                           END
                       ,0)
                  )
                , [is_resource_governor_enabled]=@IsResourceGovernorEnabled
                , [reconfiguration_pending]=@ReconfigurationPending
                , [tempdb_governance_status_code]=CASE
                      WHEN @TempdbGovernanceStatus='AVAILABLE'
                       AND [g].[configured_group_max_tempdb_data_mb] IS NULL
                       AND [g].[configured_group_max_tempdb_data_percent] IS NOT NULL
                       AND @TempdbFileStatus<>'AVAILABLE'
                          THEN @TempdbFileStatus
                      WHEN @TempdbGovernanceStatus='AVAILABLE'
                       AND @ReconfigurationPending=1
                       AND
                         (
                             [g].[configured_group_max_tempdb_data_mb] IS NOT NULL
                             OR [g].[configured_group_max_tempdb_data_percent] IS NOT NULL
                         )
                          THEN 'AVAILABLE_LIMITED'
                      ELSE @TempdbGovernanceStatus
                  END
                , [tempdb_governance_is_partial]=CONVERT
                  (
                      bit,
                      CASE
                          WHEN @TempdbGovernanceStatus<>'AVAILABLE' THEN 1
                          WHEN [g].[configured_group_max_tempdb_data_mb] IS NULL
                           AND [g].[configured_group_max_tempdb_data_percent] IS NOT NULL
                           AND @TempdbFileStatus<>'AVAILABLE' THEN 1
                          WHEN @ReconfigurationPending=1
                           AND
                             (
                                 [g].[configured_group_max_tempdb_data_mb] IS NOT NULL
                                 OR [g].[configured_group_max_tempdb_data_percent] IS NOT NULL
                             )
                              THEN 1
                          ELSE 0
                      END
                  )
                , [tempdb_governance_evidence_limit]=CASE
                      WHEN @TempdbGovernanceStatus<>'AVAILABLE'
                          THEN COALESCE(@TempdbGovernanceErrorMessage,N'Die SQL-Server-2025-Quelle ist nicht vollständig verfügbar.')
                      WHEN [g].[configured_group_max_tempdb_data_mb] IS NULL
                       AND [g].[configured_group_max_tempdb_data_percent] IS NOT NULL
                       AND @TempdbFileStatus<>'AVAILABLE'
                          THEN COALESCE(@TempdbFileErrorMessage,N'Die TempDB-Dateikonfiguration ist im aktuellen Sicherheitskontext nicht auswertbar.')
                      WHEN @ReconfigurationPending=1
                          THEN N'Die gespeicherte Konfiguration kann von der aktiven Konfiguration abweichen, bis RECONFIGURE abgeschlossen ist.'
                      WHEN [g].[configured_group_max_tempdb_data_mb] IS NULL
                       AND [g].[configured_group_max_tempdb_data_percent] IS NOT NULL
                       AND @TempdbMaximumSizeMb IS NULL
                          THEN N'Das gespeicherte Prozentlimit ist wegen der TempDB-Dateikonfiguration nicht wirksam.'
                      ELSE N'Workload-Group-Zähler sind nicht direkt mit Sessionzählern addierbar; Version Store und TempDB-Log sind nicht umfasst.'
                  END
            FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups] AS [g]
            WHERE [g].[SnapshotId]=@SnapshotId;

            SET @CompletedAtUtc=SYSUTCDATETIME();
            SELECT @RowCount=COUNT_BIG(*)
            FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups]
            WHERE [SnapshotId]=@SnapshotId;

            DECLARE @TempdbSnapshotStatus varchar(40)=CASE
                WHEN @TempdbGovernanceStatus<>'AVAILABLE' THEN @TempdbGovernanceStatus
                WHEN @TempdbFileStatus NOT IN ('AVAILABLE','NOT_APPLICABLE')
                    THEN 'AVAILABLE_LIMITED'
                ELSE 'AVAILABLE' END;

            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (
                 @SnapshotId,61,'TEMPDB_GOVERNANCE'
                ,N'sys.resource_governor_workload_groups | sys.dm_resource_governor_workload_groups | master.sys.master_files'
                ,@CapturedAtUtc,@CompletedAtUtc
                ,@TempdbSnapshotStatus
                ,CONVERT(bit,CASE WHEN @TempdbSnapshotStatus='AVAILABLE' THEN 0 ELSE 1 END)
                ,@RowCount
                ,COALESCE(@TempdbGovernanceErrorNumber,@TempdbFileErrorNumber)
                ,COALESCE(@TempdbGovernanceErrorMessage,@TempdbFileErrorMessage)
            );
        END;

        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_ResourcePools]
            (
                [SnapshotId],[CapturedAtUtc],[pool_id],[name],
                [max_memory_kb],[target_memory_kb],[used_memory_kb]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[p].[pool_id],[p].[name],
                [p].[max_memory_kb],[p].[target_memory_kb],[p].[used_memory_kb]
            FROM [sys].[dm_resource_governor_resource_pools] AS [p] WITH (NOLOCK);

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,70,'RESOURCE_POOLS',N'sys.dm_resource_governor_resource_pools',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,70,'RESOURCE_POOLS',N'sys.dm_resource_governor_resource_pools',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureTasks=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_Tasks]
            (
                [SnapshotId],[CapturedAtUtc],[task_address],[task_state],
                [session_id],[request_id],[exec_context_id],[scheduler_id],
                [worker_address],[parent_task_address]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[t].[task_address],[t].[task_state],
                [t].[session_id],[t].[request_id],[t].[exec_context_id],[t].[scheduler_id],
                [t].[worker_address],[t].[parent_task_address]
            FROM [sys].[dm_os_tasks] AS [t] WITH (NOLOCK)
            WHERE EXISTS
            (
                SELECT 1
                FROM [#CurrentOverview_CurrentStateSnapshot_Requests] AS [r]
                WHERE [r].[SnapshotId]=@SnapshotId
                  AND [r].[session_id]=[t].[session_id]
                  AND [r].[request_id]=[t].[request_id]
            );

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,90,'TASKS',N'sys.dm_os_tasks',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,90,'TASKS',N'sys.dm_os_tasks',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureSchedulers=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_Schedulers]
            (
                [SnapshotId],[CapturedAtUtc],[scheduler_address],[scheduler_id],
                [parent_node_id],[status],[is_online],[is_idle],
                [current_tasks_count],[runnable_tasks_count],[current_workers_count],
                [active_workers_count],[work_queue_count],[pending_disk_io_count],[load_factor]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[s].[scheduler_address],[s].[scheduler_id],
                [s].[parent_node_id],[s].[status],[s].[is_online],[s].[is_idle],
                [s].[current_tasks_count],[s].[runnable_tasks_count],[s].[current_workers_count],
                [s].[active_workers_count],[s].[work_queue_count],[s].[pending_disk_io_count],[s].[load_factor]
            FROM [sys].[dm_os_schedulers] AS [s] WITH (NOLOCK)
            WHERE [s].[scheduler_id] < 1048576
              AND
              (
                  EXISTS
                  (
                      SELECT 1
                      FROM [#CurrentOverview_CurrentStateSnapshot_Requests] AS [r]
                      WHERE [r].[SnapshotId]=@SnapshotId
                        AND [r].[scheduler_id]=[s].[scheduler_id]
                  )
                  OR EXISTS
                  (
                      SELECT 1
                      FROM [#CurrentOverview_CurrentStateSnapshot_Tasks] AS [t]
                      WHERE [t].[SnapshotId]=@SnapshotId
                        AND [t].[scheduler_id]=[s].[scheduler_id]
                  )
              );

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,100,'SCHEDULERS',N'sys.dm_os_schedulers',@CapturedAtUtc,@CompletedAtUtc,
             @BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,100,'SCHEDULERS',N'sys.dm_os_schedulers',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureTransactions=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_SessionTransactions]
            (
                [SnapshotId],[CapturedAtUtc],[session_id],[transaction_id],
                [transaction_descriptor],[enlist_count],[is_user_transaction],
                [is_local],[is_enlisted],[is_bound],[open_transaction_count]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[t].[session_id],[t].[transaction_id],
                [t].[transaction_descriptor],[t].[enlist_count],[t].[is_user_transaction],
                [t].[is_local],[t].[is_enlisted],[t].[is_bound],[t].[open_transaction_count]
            FROM [sys].[dm_tran_session_transactions] AS [t] WITH (NOLOCK)
            WHERE EXISTS
            (
                SELECT 1
                FROM [#CurrentOverview_CurrentStateSnapshot_Sessions] AS [s]
                WHERE [s].[SnapshotId]=@SnapshotId
                  AND [s].[session_id]=[t].[session_id]
            );

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,110,'SESSION_TRANSACTIONS',N'sys.dm_tran_session_transactions',
             @CapturedAtUtc,@CompletedAtUtc,@BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,110,'SESSION_TRANSACTIONS',N'sys.dm_tran_session_transactions',
             @CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;

        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_ActiveTransactions]
            (
                [SnapshotId],[CapturedAtUtc],[transaction_id],[name],
                [transaction_begin_time],[transaction_type],[transaction_uow],
                [transaction_state],[transaction_status]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[t].[transaction_id],[t].[name],
                [t].[transaction_begin_time],[t].[transaction_type],[t].[transaction_uow],
                [t].[transaction_state],[t].[transaction_status]
            FROM [sys].[dm_tran_active_transactions] AS [t] WITH (NOLOCK)
            WHERE EXISTS
            (
                SELECT 1
                FROM [#CurrentOverview_CurrentStateSnapshot_SessionTransactions] AS [st]
                WHERE [st].[SnapshotId]=@SnapshotId
                  AND [st].[transaction_id]=[t].[transaction_id]
            );

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,120,'ACTIVE_TRANSACTIONS',N'sys.dm_tran_active_transactions',
             @CapturedAtUtc,@CompletedAtUtc,@BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,120,'ACTIVE_TRANSACTIONS',N'sys.dm_tran_active_transactions',
             @CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;

        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            INSERT [#CurrentOverview_CurrentStateSnapshot_DatabaseTransactions]
            (
                [SnapshotId],[CapturedAtUtc],[transaction_id],[database_id],
                [database_transaction_begin_time],[database_transaction_type],
                [database_transaction_state],[database_transaction_log_record_count],
                [database_transaction_log_bytes_used],[database_transaction_log_bytes_reserved],
                [database_transaction_log_bytes_used_system],
                [database_transaction_log_bytes_reserved_system]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[t].[transaction_id],[t].[database_id],
                [t].[database_transaction_begin_time],[t].[database_transaction_type],
                [t].[database_transaction_state],[t].[database_transaction_log_record_count],
                [t].[database_transaction_log_bytes_used],[t].[database_transaction_log_bytes_reserved],
                [t].[database_transaction_log_bytes_used_system],
                [t].[database_transaction_log_bytes_reserved_system]
            FROM [sys].[dm_tran_database_transactions] AS [t] WITH (NOLOCK)
            WHERE EXISTS
            (
                SELECT 1
                FROM [#CurrentOverview_CurrentStateSnapshot_SessionTransactions] AS [st]
                WHERE [st].[SnapshotId]=@SnapshotId
                  AND [st].[transaction_id]=[t].[transaction_id]
            );

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,130,'DATABASE_TRANSACTIONS',N'sys.dm_tran_database_transactions',
             @CapturedAtUtc,@CompletedAtUtc,@BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,130,'DATABASE_TRANSACTIONS',N'sys.dm_tran_database_transactions',
             @CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureTempDbUsage=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            EXEC [sys].[sp_executesql] N'
                USE [tempdb];
                INSERT [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage]
                (
                    [SnapshotId],[CapturedAtUtc],[session_id],
                    [user_objects_alloc_page_count],[user_objects_dealloc_page_count],
                    [internal_objects_alloc_page_count],[internal_objects_dealloc_page_count]
                )
                SELECT
                    @SnapshotId,@CapturedAtUtc,[u].[session_id],
                    [u].[user_objects_alloc_page_count],[u].[user_objects_dealloc_page_count],
                    [u].[internal_objects_alloc_page_count],[u].[internal_objects_dealloc_page_count]
                FROM [sys].[dm_db_session_space_usage] AS [u] WITH (NOLOCK)
                WHERE EXISTS
                (
                    SELECT 1
                    FROM [#CurrentOverview_CurrentStateSnapshot_Sessions] AS [s]
                    WHERE [s].[SnapshotId]=@SnapshotId
                      AND [s].[session_id]=[u].[session_id]
                );',
                N'@SnapshotId uniqueidentifier,@CapturedAtUtc datetime2(3)',
                @SnapshotId=@SnapshotId,@CapturedAtUtc=@CapturedAtUtc;

            SET @RowCount=
                (SELECT COUNT_BIG(*) FROM [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage]
                 WHERE [SnapshotId]=@SnapshotId);
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,140,'TEMPDB_SESSION_USAGE',N'tempdb.sys.dm_db_session_space_usage',
             @CapturedAtUtc,@CompletedAtUtc,@BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,140,'TEMPDB_SESSION_USAGE',N'tempdb.sys.dm_db_session_space_usage',
             @CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;

        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            EXEC [sys].[sp_executesql] N'
                USE [tempdb];
                INSERT [#CurrentOverview_CurrentStateSnapshot_TempDbTaskUsage]
                (
                    [SnapshotId],[CapturedAtUtc],[session_id],[request_id],[exec_context_id],
                    [user_objects_alloc_page_count],[user_objects_dealloc_page_count],
                    [internal_objects_alloc_page_count],[internal_objects_dealloc_page_count]
                )
                SELECT
                    @SnapshotId,@CapturedAtUtc,[u].[session_id],[u].[request_id],[u].[exec_context_id],
                    [u].[user_objects_alloc_page_count],[u].[user_objects_dealloc_page_count],
                    [u].[internal_objects_alloc_page_count],[u].[internal_objects_dealloc_page_count]
                FROM [sys].[dm_db_task_space_usage] AS [u] WITH (NOLOCK)
                WHERE EXISTS
                (
                    SELECT 1
                    FROM [#CurrentOverview_CurrentStateSnapshot_Requests] AS [r]
                    WHERE [r].[SnapshotId]=@SnapshotId
                      AND [r].[session_id]=[u].[session_id]
                      AND [r].[request_id]=[u].[request_id]
                );',
                N'@SnapshotId uniqueidentifier,@CapturedAtUtc datetime2(3)',
                @SnapshotId=@SnapshotId,@CapturedAtUtc=@CapturedAtUtc;

            SET @RowCount=
                (SELECT COUNT_BIG(*) FROM [#CurrentOverview_CurrentStateSnapshot_TempDbTaskUsage]
                 WHERE [SnapshotId]=@SnapshotId);
            SET @CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,150,'TEMPDB_TASK_USAGE',N'tempdb.sys.dm_db_task_space_usage',
             @CapturedAtUtc,@CompletedAtUtc,@BaseStatusCode,@BaseIsPartial,@RowCount,NULL,NULL);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,150,'TEMPDB_TASK_USAGE',N'tempdb.sys.dm_db_task_space_usage',
             @CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

    IF @CaptureSqlText=1
    BEGIN
        SET @CapturedAtUtc=SYSUTCDATETIME();
        BEGIN TRY
            CREATE TABLE [#InternalCaptureCurrentStateSnapshot_SqlHandleCandidate]
            (
                [SqlHandle] varbinary(64) NOT NULL PRIMARY KEY
            );

            INSERT [#InternalCaptureCurrentStateSnapshot_SqlHandleCandidate]([SqlHandle])
            SELECT [h].[SqlHandle]
            FROM
            (
                SELECT [r].[sql_handle] AS [SqlHandle]
                FROM [#CurrentOverview_CurrentStateSnapshot_Requests] AS [r]
                WHERE [r].[SnapshotId]=@SnapshotId
                  AND [r].[sql_handle] IS NOT NULL
                UNION
                SELECT [c].[most_recent_sql_handle]
                FROM [#CurrentOverview_CurrentStateSnapshot_Connections] AS [c]
                WHERE [c].[SnapshotId]=@SnapshotId
                  AND [c].[most_recent_sql_handle] IS NOT NULL
            ) AS [h];

            DECLARE @SqlTextCandidateCount bigint=
                (SELECT COUNT_BIG(*) FROM [#InternalCaptureCurrentStateSnapshot_SqlHandleCandidate]);

            IF @MaxSqlTextHandles>0 AND @SqlTextCandidateCount>@MaxSqlTextHandles
            BEGIN
                ;WITH [Limited] AS
                (
                    SELECT
                        [SqlHandle],
                        [RowNumber]=ROW_NUMBER() OVER(ORDER BY [SqlHandle])
                    FROM [#InternalCaptureCurrentStateSnapshot_SqlHandleCandidate]
                )
                DELETE FROM [Limited]
                WHERE [RowNumber]>@MaxSqlTextHandles;
            END;

            INSERT [#CurrentOverview_CurrentStateSnapshot_SqlText]
            (
                [SnapshotId],[CapturedAtUtc],[SqlHandle],[Text],[DatabaseId],
                [ObjectId],[ObjectNumber],[IsEncrypted],[EvidenceStatus]
            )
            SELECT
                @SnapshotId,@CapturedAtUtc,[h].[SqlHandle],[t].[text],[t].[dbid],
                [t].[objectid],[t].[number],[t].[encrypted],
                CONVERT(varchar(40),CASE WHEN [t].[text] IS NULL THEN 'TEXT_UNAVAILABLE' ELSE 'AVAILABLE' END)
            FROM [#InternalCaptureCurrentStateSnapshot_SqlHandleCandidate] AS [h]
            OUTER APPLY [sys].[dm_exec_sql_text]([h].[SqlHandle]) AS [t];

            SET @RowCount=@@ROWCOUNT;
            SET @CompletedAtUtc=SYSUTCDATETIME();
            SET @IsPartial=CASE WHEN @MaxSqlTextHandles>0 AND @SqlTextCandidateCount>@MaxSqlTextHandles THEN 1 ELSE @BaseIsPartial END;
            SET @StatusCode=CASE WHEN @IsPartial=1 THEN 'AVAILABLE_LIMITED' ELSE 'AVAILABLE' END;
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,80,'SQL_TEXT',N'sys.dm_exec_sql_text',@CapturedAtUtc,@CompletedAtUtc,
             @StatusCode,@IsPartial,@RowCount,NULL,
             CASE WHEN @MaxSqlTextHandles>0 AND @SqlTextCandidateCount>@MaxSqlTextHandles
                  THEN N'Die Zahl unterschiedlicher SQL-Handles überschritt @MaxSqlTextHandles.'
                  ELSE NULL END);
        END TRY
        BEGIN CATCH
            SELECT @ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(),@CompletedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            VALUES
            (@SnapshotId,80,'SQL_TEXT',N'sys.dm_exec_sql_text',@CapturedAtUtc,@CompletedAtUtc,
             CASE WHEN @ErrorNumber=1222 THEN 'TIMEOUT' WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             1,0,@ErrorNumber,@ErrorMessage);
        END CATCH;
    END;

END;
GO
