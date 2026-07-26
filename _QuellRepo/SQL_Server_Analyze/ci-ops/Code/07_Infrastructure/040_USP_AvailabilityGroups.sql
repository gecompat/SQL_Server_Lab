USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_AvailabilityGroups
Version      : 1.0.0
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Analysiert Availability Groups, Replikate, Datenbanken, Listener, Routing sowie Send-/Redo-Queues und geschätzte Lags.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.availability_groups, sys.availability_replicas, sys.dm_hadr_*, sys.availability_group_listeners
Parameter    : @MitRouting, @MaxZeilen, @PrintMeldungen, @Hilfe
Resultsets   : 1. Modulstatus. 2. Gruppen/Replikate. 3. Datenbanken/Queues. 4. Listener. 5. Routing.
Berechtigung : Nur lesender Zugriff auf die genannten Systemobjekte. Das
               Framework vergibt keine Rechte und ändert keine Konfiguration.
Eigenlast    : Mittel; reine HADR-Katalog- und DMV-Auswertung.
Locking      : LOCK_TIMEOUT 0; keine fachlichen Schreibzugriffe.
Partial      : Fehlende Features, Objekte oder Rechte werden strukturiert als
               Partial Result behandelt; andere Module bleiben ausführbar.
Änderungen   : 1.0.0 - Erstfassung Phase 6.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_AvailabilityGroups]
      @MitRouting bit=1
    , @MaxZeilen int=5000
    , @ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0
    , @Json nvarchar(max)=NULL OUTPUT
    , @PrintMeldungen bit=1
    , @Hilfe bit=0
AS
BEGIN
 SET NOCOUNT ON;
 SET @Json=NULL;
 DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'replicas',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
 IF @Hilfe=1 BEGIN PRINT N'monitor.USP_AvailabilityGroups'; PRINT N'@MitRouting bit=1; @MaxZeilen int=5000; @PrintMeldungen bit=1; @Hilfe bit=0.'; PRINT N'Die Procedure führt keine Failover-, Resume-, Suspend- oder Routingänderung aus.'; RETURN; END;
 DECLARE @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),@StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0,@ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL;
 CREATE TABLE [#AvailabilityGroups_R]([AgName] sysname,[ReplicaServerName] nvarchar(256),[LocalReplica] bit,[RoleDesc] nvarchar(60),[OperationalStateDesc] nvarchar(60),[ConnectedStateDesc] nvarchar(60),[RecoveryHealthDesc] nvarchar(60),[SynchronizationHealthDesc] nvarchar(60),[AvailabilityModeDesc] nvarchar(60),[FailoverModeDesc] nvarchar(60),[SessionTimeout] int,[EndpointUrl] nvarchar(256),[PrimaryRoleAllowConnectionsDesc] nvarchar(60),[SecondaryRoleAllowConnectionsDesc] nvarchar(60),[ReadOnlyRoutingUrl] nvarchar(256));
 CREATE TABLE [#AvailabilityGroups_D]([AgName] sysname,[ReplicaServerName] nvarchar(256),[DatabaseName] sysname,[IsLocal] bit,[IsPrimaryReplica] bit,[SynchronizationStateDesc] nvarchar(60),[SynchronizationHealthDesc] nvarchar(60),[DatabaseStateDesc] nvarchar(60),[IsSuspended] bit,[SuspendReasonDesc] nvarchar(60),[LogSendQueueKb] bigint,[LogSendRateKbSec] bigint,[EstimatedSendSeconds] decimal(19,2),[RedoQueueKb] bigint,[RedoRateKbSec] bigint,[EstimatedRedoSeconds] decimal(19,2),[LastSentTime] datetime,[LastReceivedTime] datetime,[LastHardenedTime] datetime,[LastRedoneTime] datetime,[SecondaryLagSeconds] bigint);
 CREATE TABLE [#AvailabilityGroups_L]([AgName] sysname,[ListenerDnsName] nvarchar(256),[Port] int,[IsConformant] bit,[IpAddress] nvarchar(48),[IpSubnetMask] nvarchar(48),[NetworkSubnetIp] nvarchar(48),[NetworkSubnetPrefixLength] int,[StateDesc] nvarchar(60));
 CREATE TABLE [#AvailabilityGroups_Route]([AgName] sysname,[ReplicaServerName] nvarchar(256),[RoutingPriority] int,[ReadOnlyReplicaServerName] nvarchar(256));
 IF @MaxZeilen<0 SELECT @StatusCode='INVALID_PARAMETER',@ErrorMessage=N'@MaxZeilen darf nicht negativ sein; NULL/0 bedeutet unbegrenzt.';
 IF @ResultSetArtNormalisiert NOT IN ('RAW','CONSOLE','NONE') SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,@ErrorMessage=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 SET LOCK_TIMEOUT 0;
 IF @StatusCode='AVAILABLE' BEGIN TRY
  IF SERVERPROPERTY('IsHadrEnabled')<>1 BEGIN SET @StatusCode='UNAVAILABLE_FEATURE'; SET @ErrorMessage=N'Always On Availability Groups ist nicht aktiviert.'; END
  ELSE BEGIN
   INSERT [#AvailabilityGroups_R] SELECT TOP (@EffectiveMaxZeilen) [ag].[name],[ar].[replica_server_name],[rs].[is_local],[rs].[role_desc],[rs].[operational_state_desc],[rs].[connected_state_desc],[rs].[recovery_health_desc],[rs].[synchronization_health_desc],[ar].[availability_mode_desc],[ar].[failover_mode_desc],[ar].[session_timeout],[ar].[endpoint_url],[ar].[primary_role_allow_connections_desc],[ar].[secondary_role_allow_connections_desc],[ar].[read_only_routing_url] FROM [sys].[availability_groups] ag WITH (NOLOCK) JOIN [sys].[availability_replicas] ar WITH (NOLOCK) ON [ar].[group_id]=[ag].[group_id] LEFT JOIN [sys].[dm_hadr_availability_replica_states] rs WITH (NOLOCK) ON [rs].[replica_id]=[ar].[replica_id] ORDER BY [ag].[name],[ar].[replica_server_name];
   INSERT [#AvailabilityGroups_D] SELECT TOP (@EffectiveMaxZeilen) [ag].[name],[ar].[replica_server_name],(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = [drs].[database_id]),[drs].[is_local],sys.fn_hadr_is_primary_replica((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = [drs].[database_id])),[drs].[synchronization_state_desc],[drs].[synchronization_health_desc],[drs].[database_state_desc],[drs].[is_suspended],[drs].[suspend_reason_desc],[drs].[log_send_queue_size],[drs].[log_send_rate],CONVERT(decimal(19,2),[drs].[log_send_queue_size]*1.0/NULLIF([drs].[log_send_rate],0)),[drs].[redo_queue_size],[drs].[redo_rate],CONVERT(decimal(19,2),[drs].[redo_queue_size]*1.0/NULLIF([drs].[redo_rate],0)),[drs].[last_sent_time],[drs].[last_received_time],[drs].[last_hardened_time],[drs].[last_redone_time],[drs].[secondary_lag_seconds] FROM [sys].[dm_hadr_database_replica_states] drs WITH (NOLOCK) JOIN [sys].[availability_replicas] ar WITH (NOLOCK) ON [ar].[replica_id]=[drs].[replica_id] JOIN [sys].[availability_groups] ag WITH (NOLOCK) ON [ag].[group_id]=[drs].[group_id] ORDER BY [ag].[name],(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = [drs].[database_id]),[ar].[replica_server_name];
   INSERT [#AvailabilityGroups_L] SELECT TOP (@EffectiveMaxZeilen) [ag].[name],[l].[dns_name],[l].[port],[l].[is_conformant],[ip].[ip_address],[ip].[ip_subnet_mask],[ip].[network_subnet_ip],[ip].[network_subnet_prefix_length],[ip].[state_desc] FROM [sys].[availability_group_listeners] l WITH (NOLOCK) JOIN [sys].[availability_groups] ag WITH (NOLOCK) ON [ag].[group_id]=[l].[group_id] LEFT JOIN [sys].[availability_group_listener_ip_addresses] ip WITH (NOLOCK) ON [ip].[listener_id]=[l].[listener_id] ORDER BY [ag].[name],[l].[dns_name],[ip].[ip_address];
   IF @MitRouting=1 INSERT [#AvailabilityGroups_Route] SELECT TOP (@EffectiveMaxZeilen) [ag].[name],[ar].[replica_server_name],[rl].[routing_priority],[ar2].[replica_server_name] FROM [sys].[availability_read_only_routing_lists] rl WITH (NOLOCK) JOIN [sys].[availability_replicas] ar WITH (NOLOCK) ON [ar].[replica_id]=[rl].[replica_id] JOIN [sys].[availability_replicas] ar2 WITH (NOLOCK) ON [ar2].[replica_id]=[rl].[read_only_replica_id] JOIN [sys].[availability_groups] ag WITH (NOLOCK) ON [ag].[group_id]=[ar].[group_id] ORDER BY [ag].[name],[ar].[replica_server_name],[rl].[routing_priority];
  END
 END TRY BEGIN CATCH SELECT @StatusCode='ERROR_HANDLED',@IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE(); IF @PrintMeldungen=1 RAISERROR(N'Availability Groups konnten nicht vollständig gelesen werden: %s',10,1,@ErrorMessage) WITH NOWAIT; END CATCH;

 IF @ResultSetArtNormalisiert<>'NONE'
 BEGIN
  SELECT @CollectionTimeUtc AS [CollectionTimeUtc],CAST(N'monitor.USP_AvailabilityGroups' AS nvarchar(256)) AS [ModuleName],@StatusCode AS [StatusCode],@IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage];
  IF @ResultSetArtNormalisiert='RAW'
  BEGIN
   SELECT * FROM [#AvailabilityGroups_R] ORDER BY [AgName],[ReplicaServerName];
   SELECT * FROM [#AvailabilityGroups_D] ORDER BY [AgName],[DatabaseName],[ReplicaServerName];
   SELECT * FROM [#AvailabilityGroups_L] ORDER BY [AgName],[ListenerDnsName],[IpAddress];
   SELECT * FROM [#AvailabilityGroups_Route] ORDER BY [AgName],[ReplicaServerName],[RoutingPriority];
  END
  ELSE
  BEGIN
   SELECT N'Availability-Group-Replikat' AS [Ergebnis],[x].* FROM [#AvailabilityGroups_R] AS [x] ORDER BY [AgName],[ReplicaServerName];
   SELECT N'Availability-Group-Datenbank' AS [Ergebnis],[x].*,CONCAT(CONVERT(decimal(19,2),[LogSendQueueKb]/1024.0),N' MB') AS [Send-Queue],CONCAT(CONVERT(decimal(19,2),[RedoQueueKb]/1024.0),N' MB') AS [Redo-Queue] FROM [#AvailabilityGroups_D] AS [x] ORDER BY [AgName],[DatabaseName],[ReplicaServerName];
   SELECT N'Availability-Group-Listener' AS [Ergebnis],[x].* FROM [#AvailabilityGroups_L] AS [x] ORDER BY [AgName],[ListenerDnsName],[IpAddress];
   SELECT N'Read-Only-Routing' AS [Ergebnis],[x].* FROM [#AvailabilityGroups_Route] AS [x] ORDER BY [AgName],[ReplicaServerName],[RoutingPriority];
  END
 END;
 IF @JsonErzeugen=1
 BEGIN
  DECLARE @MetaJson nvarchar(max)=(SELECT N'AvailabilityGroups' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
  DECLARE @ReplicasJson nvarchar(max)=(SELECT * FROM [#AvailabilityGroups_R] ORDER BY [AgName],[ReplicaServerName] FOR JSON PATH,INCLUDE_NULL_VALUES);
  DECLARE @DatabasesJson nvarchar(max)=(SELECT * FROM [#AvailabilityGroups_D] ORDER BY [AgName],[DatabaseName],[ReplicaServerName] FOR JSON PATH,INCLUDE_NULL_VALUES);
  DECLARE @ListenersJson nvarchar(max)=(SELECT * FROM [#AvailabilityGroups_L] ORDER BY [AgName],[ListenerDnsName],[IpAddress] FOR JSON PATH,INCLUDE_NULL_VALUES);
  DECLARE @RoutingJson nvarchar(max)=(SELECT * FROM [#AvailabilityGroups_Route] ORDER BY [AgName],[ReplicaServerName],[RoutingPriority] FOR JSON PATH,INCLUDE_NULL_VALUES);
  SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"replicas":',COALESCE(@ReplicasJson,N'[]'),N',"databases":',COALESCE(@DatabasesJson,N'[]'),N',"listeners":',COALESCE(@ListenersJson,N'[]'),N',"routing":',COALESCE(@RoutingJson,N'[]'),N'}');
 END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#AvailabilityGroups_R'
            , @ResultLabel=N'AvailabilityGroups'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#AvailabilityGroups_R'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
