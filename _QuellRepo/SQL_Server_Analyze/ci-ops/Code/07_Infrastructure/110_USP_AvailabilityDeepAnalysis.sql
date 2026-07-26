USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_AvailabilityDeepAnalysis
Version      : 1.1.0
Stand        : 2026-07-18
Zweck        : Vertieft Always-On-Evidenz um Replikazustand, Warteschlangen,
               Clusterquorum, Seeding und automatische Seitenreparatur.
Datenquellen : sys.availability_groups, sys.availability_replicas,
               sys.dm_hadr_availability_replica_states,
               sys.dm_hadr_database_replica_states, sys.dm_hadr_cluster,
               sys.dm_hadr_cluster_members, optional sys.dm_hadr_cluster_networks,
               sys.dm_hadr_physical_seeding_stats und sys.dm_hadr_auto_page_repair.
Methodik     : Datenbank- und Seedingzustände werden über dieselben reinen
               Interpretationsfunktionen klassifiziert, die auch der
               deterministische Laufzeitvertrag verwendet.
Grenzen      : Momentaufnahme; Netzpfad, Clusterlog und Betriebssystemereignisse
               sind nicht enthalten. Keine Failover- oder Konfigurationsaktion.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_AvailabilityDeepAnalysis]
      @QueueWarnMb              bigint          = 1024
    , @SecondaryLagWarnSeconds  int             = 60
    , @MitClusterNetzwerken     bit             = 0
    , @MaxZeilen                int             = 1000
    , @ResultSetArt             varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen             bit             = 0
    , @Json                     nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen           bit             = 1
    , @Hilfe                    bit             = 0
    , @StatusCodeOut            varchar(40)     = NULL OUTPUT
    , @IsPartialOut             bit             = NULL OUTPUT
    , @ErrorNumberOut           int             = NULL OUTPUT
    , @ErrorMessageOut          nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'replicas',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
                                 THEN CONVERT(bigint, 9223372036854775807)
                                 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_AvailabilityDeepAnalysis';
        PRINT N'Die Procedure liefert eine rein lesende Always-On-Momentaufnahme und löst weder ein Failover noch eine Konfigurationsänderung aus.';
        PRINT N'@QueueWarnMb und @SecondaryLagWarnSeconds sind Sichtungsgrenzen, keine universellen SLOs.';
        PRINT N'@MitClusterNetzwerken=0; Netzwerkdetails sind opt-in.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @ProductMajorVersion int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));

    CREATE TABLE [#AvailabilityDeepAnalysis_Cluster]
    (
          [ClusterName] nvarchar(128) NULL
        , [QuorumTypeDesc] nvarchar(60) NULL
        , [QuorumStateDesc] nvarchar(60) NULL
        , [FindingCode] varchar(80) NOT NULL
    );
    CREATE TABLE [#AvailabilityDeepAnalysis_Members]
    (
          [MemberName] nvarchar(256) NULL
        , [MemberTypeDesc] nvarchar(60) NULL
        , [MemberStateDesc] nvarchar(60) NULL
        , [NumberOfQuorumVotes] int NULL
    );
    CREATE TABLE [#AvailabilityDeepAnalysis_Networks]
    (
          [MemberName] nvarchar(128) NULL
        , [NetworkSubnetIp] nvarchar(48) NULL
        , [NetworkSubnetPrefixLength] int NULL
        , [IsPublic] bit NULL
        , [IsIpv4] bit NULL
    );
    CREATE TABLE [#AvailabilityDeepAnalysis_Replicas]
    (
          [AvailabilityGroupName] sysname NULL
        , [ReplicaServerName] nvarchar(256) NULL
        , [IsLocal] bit NULL
        , [RoleDesc] nvarchar(60) NULL
        , [OperationalStateDesc] nvarchar(60) NULL
        , [ConnectedStateDesc] nvarchar(60) NULL
        , [SynchronizationHealthDesc] nvarchar(60) NULL
        , [AvailabilityModeDesc] nvarchar(60) NULL
        , [FailoverModeDesc] nvarchar(60) NULL
        , [SeedingModeDesc] nvarchar(60) NULL
        , [FindingCode] varchar(80) NOT NULL
    );
    CREATE TABLE [#AvailabilityDeepAnalysis_Databases]
    (
          [AvailabilityGroupName] sysname NULL
        , [ReplicaServerName] nvarchar(256) NULL
        , [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [IsLocal] bit NULL
        , [SynchronizationStateDesc] nvarchar(60) NULL
        , [SynchronizationHealthDesc] nvarchar(60) NULL
        , [DatabaseStateDesc] nvarchar(60) NULL
        , [IsSuspended] bit NULL
        , [SuspendReasonDesc] nvarchar(60) NULL
        , [LogSendQueueSizeKb] bigint NULL
        , [RedoQueueSizeKb] bigint NULL
        , [SecondaryLagSeconds] bigint NULL
        , [LastCommitTime] datetime NULL
        , [FindingCode] varchar(100) NOT NULL
        , [FindingSeverity] varchar(16) NOT NULL
    );
    CREATE TABLE [#AvailabilityDeepAnalysis_Seeding]
    (
          [RemoteMachineName] nvarchar(256) NULL
        , [RoleDesc] nvarchar(60) NULL
        , [DatabaseName] sysname NULL
        , [CurrentStateDesc] nvarchar(60) NULL
        , [FailureCode] int NULL
        , [TransferredSizeBytes] bigint NULL
        , [DatabaseSizeBytes] bigint NULL
        , [TransferRateBytesPerSecond] bigint NULL
        , [StartTimeUtc] datetime NULL
        , [EndTimeUtc] datetime NULL
        , [EstimateTimeCompleteUtc] datetime NULL
        , [ProgressPercent] decimal(9,4) NULL
        , [RemainingBytes] bigint NULL
        , [FindingCode] varchar(100) NOT NULL
        , [FindingSeverity] varchar(16) NOT NULL
    );
    CREATE TABLE [#AvailabilityDeepAnalysis_PageRepair]
    (
          [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [FileId] int NULL
        , [PageId] bigint NULL
        , [ErrorType] int NULL
        , [PageStatus] int NULL
        , [ModificationTime] datetime NULL
        , [FindingCode] varchar(80) NOT NULL
    );

    IF @QueueWarnMb IS NULL OR @SecondaryLagWarnSeconds IS NULL
       OR @QueueWarnMb < 0 OR @SecondaryLagWarnSeconds < 0 OR @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Queue-, Lag-, Zeilen- oder Ausgabeparameter.';
    END
    ELSE IF COALESCE(TRY_CONVERT(int, SERVERPROPERTY(N'IsHadrEnabled')), 0) <> 1
    BEGIN
        SELECT @StatusCode = 'NOT_APPLICABLE',
               @ErrorMessage = N'Always On Availability Groups ist auf dieser Instanz nicht aktiviert.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            INSERT [#AvailabilityDeepAnalysis_Cluster]
            SELECT [cluster_name], [quorum_type_desc], [quorum_state_desc],
                   CASE WHEN [quorum_state_desc] = N'NORMAL_QUORUM'
                        THEN 'QUORUM_STATE_NORMAL' ELSE 'QUORUM_STATE_REVIEW' END
            FROM [sys].[dm_hadr_cluster] WITH (NOLOCK);

            IF NOT EXISTS (SELECT 1 FROM [#AvailabilityDeepAnalysis_Cluster])
                INSERT [#AvailabilityDeepAnalysis_Cluster]
                VALUES (NULL, NULL, NULL, 'QUORUM_STATE_NOT_VISIBLE');

            INSERT [#AvailabilityDeepAnalysis_Members]
            SELECT [member_name], [member_type_desc], [member_state_desc], [number_of_quorum_votes]
            FROM [sys].[dm_hadr_cluster_members] WITH (NOLOCK);

            IF @MitClusterNetzwerken = 1
            BEGIN
                INSERT [#AvailabilityDeepAnalysis_Networks]
                SELECT [member_name], [network_subnet_ip], [network_subnet_prefix_length], [is_public], [is_ipv4]
                FROM [sys].[dm_hadr_cluster_networks] WITH (NOLOCK);
            END;

            INSERT [#AvailabilityDeepAnalysis_Replicas]
            SELECT
                  [ag].[name], [ar].[replica_server_name], [rs].[is_local], [rs].[role_desc]
                , [rs].[operational_state_desc], [rs].[connected_state_desc]
                , [rs].[synchronization_health_desc], [ar].[availability_mode_desc]
                , [ar].[failover_mode_desc], [ar].[seeding_mode_desc]
                , CASE WHEN [rs].[connected_state_desc] = N'DISCONNECTED' THEN 'REPLICA_DISCONNECTED'
                       WHEN [rs].[synchronization_health_desc] = N'NOT_HEALTHY' THEN 'REPLICA_NOT_HEALTHY'
                       WHEN [rs].[operational_state_desc] NOT IN (N'ONLINE', N'PENDING_FAILOVER')
                            AND [rs].[operational_state_desc] IS NOT NULL THEN 'REPLICA_OPERATIONAL_STATE_REVIEW'
                       ELSE 'REPLICA_STATE_ACCEPTABLE' END
            FROM [sys].[availability_groups] AS [ag] WITH (NOLOCK)
            JOIN [sys].[availability_replicas] AS [ar] WITH (NOLOCK) ON [ar].[group_id] = [ag].[group_id]
            LEFT JOIN [sys].[dm_hadr_availability_replica_states] AS [rs] WITH (NOLOCK)
              ON [rs].[group_id] = [ar].[group_id] AND [rs].[replica_id] = [ar].[replica_id];

            INSERT [#AvailabilityDeepAnalysis_Databases]
            SELECT
                  [ag].[name], [ar].[replica_server_name], [drs].[database_id], (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = [drs].[database_id])
                , [drs].[is_local], [drs].[synchronization_state_desc]
                , [drs].[synchronization_health_desc], [drs].[database_state_desc]
                , [drs].[is_suspended], [drs].[suspend_reason_desc]
                , [drs].[log_send_queue_size], [drs].[redo_queue_size]
                , [drs].[secondary_lag_seconds], [drs].[last_commit_time]
                , [state].[FindingCode], [state].[FindingSeverity]
            FROM [sys].[dm_hadr_database_replica_states] AS [drs] WITH (NOLOCK)
            JOIN [sys].[availability_groups] AS [ag] WITH (NOLOCK) ON [ag].[group_id] = [drs].[group_id]
            JOIN [sys].[availability_replicas] AS [ar] WITH (NOLOCK)
              ON [ar].[group_id] = [drs].[group_id] AND [ar].[replica_id] = [drs].[replica_id]
            CROSS APPLY [monitor].[TVF_InterpretAvailabilityDatabaseState]
            (
                  [drs].[is_suspended], [drs].[synchronization_health_desc]
                , [drs].[synchronization_state_desc], [drs].[log_send_queue_size]
                , [drs].[redo_queue_size], [drs].[secondary_lag_seconds]
                , @QueueWarnMb, @SecondaryLagWarnSeconds
            ) AS [state];

            INSERT [#AvailabilityDeepAnalysis_Seeding]
            SELECT
                  [ps].[remote_machine_name], [ps].[role_desc], [ps].[local_database_name], [ps].[internal_state_desc]
                , [ps].[failure_code], [ps].[transferred_size_bytes], [ps].[database_size_bytes]
                , [ps].[transfer_rate_bytes_per_second], CONVERT(datetime,[ps].[start_time_utc])
                , CONVERT(datetime,[ps].[end_time_utc]), CONVERT(datetime,[ps].[estimate_time_complete_utc])
                , [state].[ProgressPercent], [state].[RemainingBytes]
                , [state].[FindingCode], [state].[FindingSeverity]
            FROM [sys].[dm_hadr_physical_seeding_stats] AS [ps] WITH (NOLOCK)
            CROSS APPLY [monitor].[TVF_InterpretAvailabilitySeedingState]
            (
                  [ps].[failure_code], [ps].[transferred_size_bytes], [ps].[database_size_bytes]
                , [ps].[transfer_rate_bytes_per_second], CONVERT(datetime,[ps].[end_time_utc])
            ) AS [state];

            INSERT [#AvailabilityDeepAnalysis_PageRepair]
            SELECT [pr].[database_id], [d].[name], [pr].[file_id], [pr].[page_id], [pr].[error_type]
                 , [pr].[page_status], [pr].[modification_time]
                 , CASE WHEN [pr].[page_status] = 5 THEN 'PAGE_REPAIR_SUCCEEDED'
                        ELSE 'PAGE_REPAIR_PENDING_OR_FAILED' END
            FROM [sys].[dm_hadr_auto_page_repair] AS [pr] WITH (NOLOCK)
            LEFT JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
              ON [d].[database_id]=[pr].[database_id];

            IF EXISTS
               (
                   SELECT 1 FROM [#AvailabilityDeepAnalysis_Cluster] WHERE [FindingCode] <> 'QUORUM_STATE_NORMAL'
                   UNION ALL
                   SELECT 1 FROM [#AvailabilityDeepAnalysis_Replicas] WHERE [FindingCode] <> 'REPLICA_STATE_ACCEPTABLE'
                   UNION ALL
                   SELECT 1 FROM [#AvailabilityDeepAnalysis_Databases] WHERE [FindingCode] <> 'DATABASE_STATE_ACCEPTABLE'
                   UNION ALL
                   SELECT 1 FROM [#AvailabilityDeepAnalysis_Seeding] WHERE [FindingSeverity] <> 'INFO'
                   UNION ALL
                   SELECT 1 FROM [#AvailabilityDeepAnalysis_PageRepair] WHERE [FindingCode] <> 'PAGE_REPAIR_SUCCEEDED'
               )
                SET @StatusCode = 'AVAILABLE_WITH_FINDING';
        END TRY
        BEGIN CATCH
            SELECT @StatusCode = CASE WHEN ERROR_NUMBER() IN (229, 297, 300, 371)
                                      THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                   @IsPartial = 1, @ErrorNumber = ERROR_NUMBER(), @ErrorMessage = ERROR_MESSAGE();
        END CATCH;
    END;

    SELECT @StatusCodeOut = @StatusCode, @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber, @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
            (SELECT N'AvailabilityDeepAnalysis' AS [resultName], 1 AS [schemaVersion],
                    @Now AS [generatedAtUtc], @StatusCode AS [statusCode], @IsPartial AS [isPartial],
                    @QueueWarnMb AS [queueWarnMb], @SecondaryLagWarnSeconds AS [secondaryLagWarnSeconds],
                    @ProductMajorVersion AS [productMajorVersion]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
        DECLARE @ClusterJson nvarchar(max) = (SELECT * FROM [#AvailabilityDeepAnalysis_Cluster] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @MemberJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Members] ORDER BY [MemberName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @NetworkJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Networks] ORDER BY [MemberName], [NetworkSubnetIp] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @ReplicaJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Replicas] ORDER BY [AvailabilityGroupName], [ReplicaServerName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @DatabaseJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Databases]
             ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                      [AvailabilityGroupName], [DatabaseName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @SeedingJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Seeding]
             ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                      [StartTimeUtc] DESC
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @RepairJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_PageRepair] ORDER BY [ModificationTime] DESC FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'),
                           N',"cluster":', COALESCE(@ClusterJson, N'[]'),
                           N',"members":', COALESCE(@MemberJson, N'[]'),
                           N',"networks":', COALESCE(@NetworkJson, N'[]'),
                           N',"replicas":', COALESCE(@ReplicaJson, N'[]'),
                           N',"databases":', COALESCE(@DatabaseJson, N'[]'),
                           N',"seeding":', COALESCE(@SeedingJson, N'[]'),
                           N',"pageRepair":', COALESCE(@RepairJson, N'[]'), N'}');
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_AvailabilityDeepAnalysis' AS [ModuleName], @Now AS [CollectionTimeUtc],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'Read-only Always-On-Momentaufnahme.' AS [Detail];
        SELECT * FROM [#AvailabilityDeepAnalysis_Cluster];
        SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Members] ORDER BY [MemberName];
        SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Networks] ORDER BY [MemberName], [NetworkSubnetIp];
        SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Replicas] ORDER BY [AvailabilityGroupName], [ReplicaServerName];
        SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Databases]
        ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [AvailabilityGroupName], [DatabaseName];
        SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_Seeding]
        ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [StartTimeUtc] DESC;
        SELECT TOP (@Limit) * FROM [#AvailabilityDeepAnalysis_PageRepair] ORDER BY [ModificationTime] DESC;
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Always On Deep Analysis' AS [Ergebnis], @Now AS [Stand_UTC],
               @StatusCode AS [Status], @IsPartial AS [Teilweise], @ErrorMessage AS [Hinweis];
        SELECT N'Clusterquorum' AS [Ergebnis], [ClusterName] AS [Cluster],
               [QuorumTypeDesc] AS [Quorum_Typ], [QuorumStateDesc] AS [Quorum_Status], [FindingCode] AS [Befund]
        FROM [#AvailabilityDeepAnalysis_Cluster];
        SELECT TOP (@Limit) N'AG-Datenbank' AS [Ergebnis], [AvailabilityGroupName] AS [AG],
               [ReplicaServerName] AS [Replikat], [DatabaseName] AS [Datenbank],
               [SynchronizationStateDesc] AS [Synchronisation],
               [SynchronizationHealthDesc] AS [Gesundheit], [IsSuspended] AS [Suspendiert],
               [LogSendQueueSizeKb] AS [Log_Send_Queue_KB], [RedoQueueSizeKb] AS [Redo_Queue_KB],
               [SecondaryLagSeconds] AS [Lag_Sekunden], [FindingCode] AS [Befund],
               [FindingSeverity] AS [Prioritaet]
        FROM [#AvailabilityDeepAnalysis_Databases]
        ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [AvailabilityGroupName], [DatabaseName];
        SELECT TOP (@Limit) N'AG-Seeding' AS [Ergebnis], [RemoteMachineName] AS [Remote_Knoten],
               [DatabaseName] AS [Datenbank], [CurrentStateDesc] AS [Status],
               [FailureCode] AS [Fehlercode], [TransferRateBytesPerSecond] AS [Bytes_pro_Sekunde],
               [ProgressPercent] AS [Fortschritt_Prozent], [RemainingBytes] AS [Verbleibende_Bytes],
               [EstimateTimeCompleteUtc] AS [Geschaetztes_Ende_UTC], [FindingCode] AS [Befund],
               [FindingSeverity] AS [Prioritaet], [StartTimeUtc] AS [Start_UTC], [EndTimeUtc] AS [Ende_UTC]
        FROM [#AvailabilityDeepAnalysis_Seeding]
        ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [StartTimeUtc] DESC;
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#AvailabilityDeepAnalysis_Replicas'
            , @ResultLabel=N'AvailabilityDeepAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#AvailabilityDeepAnalysis_Replicas'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
