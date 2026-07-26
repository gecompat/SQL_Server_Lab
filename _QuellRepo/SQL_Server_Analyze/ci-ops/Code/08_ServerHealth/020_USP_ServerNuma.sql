USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ServerNuma
Version      : 2.0.0
Stand        : 2026-07-15
Zweck        : Liefert die NUMA- und Soft-NUMA-Verteilung, den Scheduler-Skew
               und die Memory Nodes.
Datenquellen : sys.dm_os_nodes, sys.dm_os_schedulers, sys.dm_os_memory_nodes
Vertrag      : Resultset 1 ist immer Modulstatus; @ResultSetArt=NONE unterdrückt Resultsets; RAW und CONSOLE liefern unterschiedliche Projektionen. Optional JSON.
===============================================================================
*/

CREATE OR ALTER PROCEDURE [monitor].[USP_ServerNuma]
 @PrintMeldungen bit=1,@Hilfe bit=0,@ResultSetArt varchar(16)='CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen bit=0,@Json nvarchar(max)=NULL OUTPUT,
 @StatusCodeOut varchar(40)=NULL OUTPUT,@IsPartialOut bit=NULL OUTPUT,@ErrorNumberOut int=NULL OUTPUT,@ErrorMessageOut nvarchar(2048)=NULL OUTPUT
AS
BEGIN
 SET NOCOUNT ON;SET @Json=NULL;DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'numaNodes',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';IF @Hilfe=1 BEGIN PRINT N'monitor.USP_ServerNuma';RETURN;END;
 DECLARE @T datetime2(3)=SYSUTCDATETIME(),@S varchar(40)='AVAILABLE',@P bit=0,@E int=NULL,@M nvarchar(2048)=NULL;
 IF @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') SELECT @S='INVALID_PARAMETER',@P=1,@M=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';
 CREATE TABLE [#ServerNuma_N]([node_id] int,[node_state_desc] nvarchar(60),[memory_node_id] int,[online_scheduler_count] int,[idle_scheduler_count] int,[active_worker_count] int,[avg_load_balance] bigint,[SchedulerCount] bigint,[VisibleOnline] bigint,[CurrentTasks] bigint,[RunnableTasks] bigint,[ActiveWorkers] bigint,[LoadFactor] bigint,[RunnablePerScheduler] decimal(19,4),[Finding] varchar(50));
 CREATE TABLE [#ServerNuma_MN]([memory_node_id] int,[virtual_address_space_reserved_kb] bigint,[virtual_address_space_committed_kb] bigint,[locked_page_allocations_kb] bigint,[pages_kb] bigint,[shared_memory_reserved_kb] bigint,[shared_memory_committed_kb] bigint);
 SET LOCK_TIMEOUT 0;
 BEGIN TRY
  ;WITH X AS(SELECT [parent_node_id],COUNT_BIG(*)[SchedulerCount],SUM(CONVERT(bigint,CASE WHEN [status]='VISIBLE ONLINE' THEN 1 ELSE 0 END))[VisibleOnline],SUM(CONVERT(bigint,[current_tasks_count]))[CurrentTasks],SUM(CONVERT(bigint,[runnable_tasks_count]))[RunnableTasks],SUM(CONVERT(bigint,[active_workers_count]))[ActiveWorkers],SUM(CONVERT(bigint,[load_factor]))[LoadFactor] FROM [sys].[dm_os_schedulers] WITH (NOLOCK) WHERE [scheduler_id]<1048576 GROUP BY [parent_node_id])
  INSERT [#ServerNuma_N] SELECT [n].[node_id],[n].[node_state_desc],[n].[memory_node_id],[n].[online_scheduler_count],[n].[idle_scheduler_count],[n].[active_worker_count],[n].[avg_load_balance],[x].[SchedulerCount],[x].[VisibleOnline],[x].[CurrentTasks],[x].[RunnableTasks],[x].[ActiveWorkers],[x].[LoadFactor],
   CONVERT(decimal(19,4),1.0*[x].[RunnableTasks]/NULLIF([x].[VisibleOnline],0)),CASE WHEN [n].[node_state_desc] NOT LIKE 'ONLINE%' THEN 'NODE_NOT_ONLINE' WHEN [x].[RunnableTasks]>0 THEN 'RUNNABLE_TASKS_PRESENT' ELSE 'OK_SNAPSHOT' END
  FROM [sys].[dm_os_nodes] n WITH (NOLOCK) LEFT JOIN [X] x ON [x].[parent_node_id]=[n].[node_id] WHERE [n].[node_state_desc]<>'ONLINE DAC';
  INSERT [#ServerNuma_MN] SELECT [memory_node_id],[virtual_address_space_reserved_kb],[virtual_address_space_committed_kb],[locked_page_allocations_kb],[pages_kb],[shared_memory_reserved_kb],[shared_memory_committed_kb] FROM [sys].[dm_os_memory_nodes] WITH (NOLOCK) WHERE [memory_node_id]<64;
 END TRY BEGIN CATCH SELECT @S=CASE WHEN ERROR_NUMBER() IN(229,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,@P=1,@E=ERROR_NUMBER(),@M=ERROR_MESSAGE(); END CATCH;
 SELECT @StatusCodeOut=@S,@IsPartialOut=@P,@ErrorNumberOut=@E,@ErrorMessageOut=@M;
 IF @PrintMeldungen=1 AND @S<>'AVAILABLE' RAISERROR(N'USP_ServerNuma: %s',10,1,@M) WITH NOWAIT;
 IF @ResultSetArtNormalisiert<>'NONE' BEGIN SELECT CAST('2.0' AS varchar(16)) [ContractVersion],@T [CollectionTimeUtc],N'monitor.USP_ServerNuma' [ModuleName],@S [StatusCode],@P [IsPartial],@E [ErrorNumber],@M [ErrorMessage];IF @ResultSetArtNormalisiert='RAW' BEGIN SELECT * FROM [#ServerNuma_N] ORDER BY [node_id];SELECT * FROM [#ServerNuma_MN] ORDER BY [memory_node_id]; END ELSE BEGIN SELECT N'numaNodes' [Ergebnis],[x].* FROM [#ServerNuma_N] [x] ORDER BY [node_id];SELECT N'memoryNodes' [Ergebnis],[x].* FROM [#ServerNuma_MN] [x] ORDER BY [memory_node_id]; END;END;
 IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'ServerNuma' [resultName],1 [schemaVersion],@T [generatedAtUtc],@S [statusCode],@P [isPartial],@E [errorNumber],@M [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@J0 nvarchar(max)=(SELECT * FROM [#ServerNuma_N] ORDER BY [node_id] FOR JSON PATH,INCLUDE_NULL_VALUES),@J1 nvarchar(max)=(SELECT * FROM [#ServerNuma_MN] ORDER BY [memory_node_id] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"numaNodes":',COALESCE(@J0,N'[]'),N',"memoryNodes":',COALESCE(@J1,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ServerNuma_N'
            , @ResultLabel=N'ServerNuma'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ServerNuma_N'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
