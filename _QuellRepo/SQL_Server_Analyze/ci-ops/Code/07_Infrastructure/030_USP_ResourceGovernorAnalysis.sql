USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ResourceGovernorAnalysis
Version      : 3.0.0
Stand        : 2026-07-23
Typ          : Stored Procedure
Zweck        : Trennt Resource-Governor-Konfiguration, Laufzeitkennzahlen und
               die SQL-Server-2025-TempDB-Governance je Workload Group.
SQL-Version  : SQL Server 2019 oder neuer; TempDB-Governance ab 2025 (17.x).
Datenquellen : sys.resource_governor_configuration,
               sys.dm_resource_governor_configuration,
               sys.resource_governor_resource_pools,
               sys.dm_resource_governor_resource_pools,
               sys.resource_governor_workload_groups,
               sys.dm_resource_governor_workload_groups,
               sys.dm_exec_sessions, master.sys.master_files.
Parameter    : @MitSessions, @MaxZeilen, @ResultSetArt, @ResultTablesJson,
               @JsonErzeugen, @Json OUTPUT, @PrintMeldungen, @Hilfe.
Resultsets   : configuration, resourcePools, workloadGroups, sessions,
               tempdbGovernance und warnings.
Berechtigung : Nur lesender Zugriff. Das Framework vergibt keine Rechte und
               ändert weder Resource Governor noch TempDB.
Eigenlast    : Gering bis mittel; jede fachliche Quelle höchstens einmal.
Locking      : LOCK_TIMEOUT 0 für Quellen; vorheriger Sessionwert wird
               auch nach TABLE- und CONSOLE-Ausgabe wiederhergestellt.
Änderungen   : 3.0.0 - SQL25-003: gespeicherte Limits, wirksames Limit,
                         aktuelle/Peak-Nutzung, Verletzungen und Resetgrenze.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ResourceGovernorAnalysis]
      @MitSessions       bit            = 1
    , @MaxZeilen         int            = 5000
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson  nvarchar(max)  = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
    DECLARE @RestoreLockTimeoutSql nvarchar(100);
    SET @Json=NULL;

    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit=CASE WHEN @OutputMode='TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit=CASE WHEN @OutputMode='CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @EffectiveMaxZeilen bigint=
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807)
             WHEN @MaxZeilen>0 THEN CONVERT(bigint,@MaxZeilen)
             ELSE CONVERT(bigint,0) END;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ResourceGovernorAnalysis';
        PRINT N'@MitSessions bit=1: aktuelle Benutzersessions je Workload Group.';
        PRINT N'@MaxZeilen positiv = begrenzt; NULL/0 = unbegrenzt.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE; JSON über @JsonErzeugen=1.';
        PRINT N'TABLE erlaubt configuration, resourcePools, workloadGroups, sessions und tempdbGovernance.';
        PRINT N'TempDB-Limits, Wirksamkeit, Nutzung, Peak und Verletzungen sind getrennte Evidenz.';
        PRINT N'Die Procedure führt weder ALTER RESOURCE GOVERNOR noch RECONFIGURE oder RESET STATISTICS aus.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME();
    DECLARE @ProductMajorVersion int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @Sql nvarchar(max);
    DECLARE @SourceStatus varchar(40);
    DECLARE @SourceErrorNumber int;
    DECLARE @SourceErrorMessage nvarchar(2048);
    DECLARE @TablePreflightStatus varchar(40);
    DECLARE @TablePreflightError nvarchar(2048);

    CREATE TABLE [#ResourceGovernorAnalysis_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );

    CREATE TABLE [#ResourceGovernorAnalysis_Cfg]
    (
          [ClassifierFunctionId] int NULL
        , [IsEnabled] bit NULL
        , [ReconfigurationPending] bit NULL
        , [ClassifierFunctionName] nvarchar(517) NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_SourcePoolCatalog]
    (
          [PoolId] int NOT NULL PRIMARY KEY
        , [PoolName] sysname NOT NULL
        , [MinCpuPercent] int NULL
        , [MaxCpuPercent] int NULL
        , [MinMemoryPercent] int NULL
        , [MaxMemoryPercent] int NULL
        , [CapCpuPercent] int NULL
        , [MinIopsPerVolume] int NULL
        , [MaxIopsPerVolume] int NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_SourcePoolRuntime]
    (
          [PoolId] int NOT NULL PRIMARY KEY
        , [StatisticsStartTime] datetime NULL
        , [TotalCpuUsageMs] bigint NULL
        , [CacheMemoryKb] bigint NULL
        , [UsedMemoryKb] bigint NULL
        , [TargetMemoryKb] bigint NULL
        , [MaxMemoryKb] bigint NULL
        , [OutOfMemoryCount] bigint NULL
        , [ActiveMemgrantCount] int NULL
        , [PendingMemgrantCount] int NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_SourceGroupCatalog]
    (
          [GroupId] int NOT NULL PRIMARY KEY
        , [GroupName] sysname NOT NULL
        , [PoolId] int NULL
        , [Importance] nvarchar(60) NULL
        , [RequestMaxMemoryGrantPercent] decimal(9,4) NULL
        , [RequestMaxCpuTimeSec] int NULL
        , [RequestMemoryGrantTimeoutSec] int NULL
        , [MaxDop] int NULL
        , [GroupMaxRequests] int NULL
        , [ConfiguredGroupMaxTempdbDataMb] decimal(19,2) NULL
        , [ConfiguredGroupMaxTempdbDataPercent] decimal(9,4) NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_SourceGroupRuntime]
    (
          [GroupId] int NOT NULL PRIMARY KEY
        , [GroupName] sysname NOT NULL
        , [PoolId] int NULL
        , [StatisticsStartTime] datetime NULL
        , [EffectiveMaxDop] int NULL
        , [TotalRequestCount] bigint NULL
        , [TotalQueuedRequestCount] bigint NULL
        , [ActiveRequestCount] int NULL
        , [QueuedRequestCount] int NULL
        , [TotalReducedMemgrantCount] bigint NULL
        , [MaxRequestGrantMemoryKb] bigint NULL
        , [TotalCpuUsageMs] bigint NULL
        , [TotalLockWaitCount] bigint NULL
        , [TotalLockWaitTimeMs] bigint NULL
        , [TempdbDataSpaceKb] bigint NULL
        , [PeakTempdbDataSpaceKb] bigint NULL
        , [TotalTempdbDataLimitViolationCount] bigint NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_SourceSessions]
    (
          [SessionId] int NOT NULL PRIMARY KEY
        , [LoginName] sysname NULL
        , [HostName] nvarchar(128) NULL
        , [ProgramName] nvarchar(128) NULL
        , [GroupId] int NULL
        , [Status] nvarchar(60) NULL
        , [CpuTimeMs] int NULL
        , [MemoryUsagePages] int NULL
        , [Reads] bigint NULL
        , [Writes] bigint NULL
        , [LogicalReads] bigint NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_TempdbFiles]
    (
          [FileId] int NOT NULL PRIMARY KEY
        , [SizePages] bigint NOT NULL
        , [MaxSizePages] bigint NOT NULL
        , [GrowthPagesOrPercent] bigint NOT NULL
        , [IsPercentGrowth] bit NOT NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_Pools]
    (
          [PoolId] int NOT NULL
        , [PoolName] sysname NOT NULL
        , [MinCpuPercent] int NULL
        , [MaxCpuPercent] int NULL
        , [MinMemoryPercent] int NULL
        , [MaxMemoryPercent] int NULL
        , [CapCpuPercent] int NULL
        , [MinIopsPerVolume] int NULL
        , [MaxIopsPerVolume] int NULL
        , [StatisticsStartTime] datetime NULL
        , [TotalCpuUsageMs] bigint NULL
        , [CacheMemoryMb] decimal(19,2) NULL
        , [UsedWorkspaceMemoryMb] decimal(19,2) NULL
        , [TargetWorkspaceMemoryMb] decimal(19,2) NULL
        , [MaxWorkspaceMemoryMb] decimal(19,2) NULL
        , [OutOfMemoryCount] bigint NULL
        , [ActiveMemgrantCount] int NULL
        , [PendingMemgrantCount] int NULL
        , [UsedOfTargetMemoryPercent] decimal(9,2) NULL
        , [UsedOfMaxMemoryPercent] decimal(9,2) NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_Groups]
    (
          [GroupId] int NOT NULL
        , [GroupName] sysname NOT NULL
        , [PoolId] int NULL
        , [PoolName] sysname NULL
        , [Importance] nvarchar(60) NULL
        , [RequestMaxMemoryGrantPercent] decimal(9,4) NULL
        , [ConfiguredRequestMaxGrantMemoryMb] decimal(19,2) NULL
        , [TargetRequestMaxGrantMemoryMb] decimal(19,2) NULL
        , [HistoricalMaxRequestGrantMemoryMb] decimal(19,2) NULL
        , [RequestMaxCpuTimeSec] int NULL
        , [RequestMemoryGrantTimeoutSec] int NULL
        , [MaxDop] int NULL
        , [EffectiveMaxDop] int NULL
        , [GroupMaxRequests] int NULL
        , [TotalRequestCount] bigint NULL
        , [TotalQueuedRequestCount] bigint NULL
        , [ActiveRequestCount] int NULL
        , [QueuedRequestCount] int NULL
        , [TotalReducedMemgrantCount] bigint NULL
        , [TotalCpuUsageMs] bigint NULL
        , [TotalLockWaitCount] bigint NULL
        , [TotalLockWaitTimeMs] bigint NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_Sessions]
    (
          [SessionId] int NOT NULL
        , [LoginName] sysname NULL
        , [HostName] nvarchar(128) NULL
        , [ProgramName] nvarchar(128) NULL
        , [GroupId] int NULL
        , [GroupName] sysname NULL
        , [PoolName] sysname NULL
        , [Status] nvarchar(60) NULL
        , [CpuTimeMs] int NULL
        , [MemoryUsagePages] int NULL
        , [MemoryUsageMb] decimal(19,2) NULL
        , [Reads] bigint NULL
        , [Writes] bigint NULL
        , [LogicalReads] bigint NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_TempdbGovernance]
    (
          [GroupId] int NULL
        , [GroupName] sysname NULL
        , [PoolId] int NULL
        , [PoolName] sysname NULL
        , [ConfiguredGroupMaxTempdbDataMb] decimal(19,2) NULL
        , [ConfiguredGroupMaxTempdbDataPercent] decimal(9,4) NULL
        , [TempdbMaximumSizeMb] decimal(19,2) NULL
        , [EffectiveGroupMaxTempdbDataMb] decimal(19,2) NULL
        , [EffectiveLimitSource] varchar(40) NOT NULL
        , [IsPercentLimitEffective] bit NULL
        , [TempdbDataSpaceMb] decimal(19,2) NULL
        , [PeakTempdbDataSpaceMb] decimal(19,2) NULL
        , [EffectiveLimitUtilizationPercent] decimal(9,2) NULL
        , [TotalTempdbDataLimitViolationCount] bigint NULL
        , [HasRecordedLimitViolation] bit NULL
        , [StatisticsStartTime] datetime NULL
        , [IsResourceGovernorEnabled] bit NULL
        , [ReconfigurationPending] bit NULL
        , [SourceStatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [EvidenceLimit] nvarchar(1000) NULL
    );

    CREATE TABLE [#ResourceGovernorAnalysis_Warnings]
    (
          [WarningCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [WarningMessage] nvarchar(2048) NOT NULL
    );

    IF @MaxZeilen<0
       OR @MitSessions IS NULL
       OR @JsonErzeugen IS NULL
       OR @OutputMode NOT IN ('RAW','CONSOLE','TABLE','NONE')
       OR (@OutputMode<>'TABLE' AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL)
    BEGIN
        SET @StatusCode='INVALID_PARAMETER';
        SET @ErrorMessage=N'Ungültiger Parameter. @MaxZeilen darf nicht negativ sein; @ResultSetArt erlaubt CONSOLE, RAW, TABLE oder NONE.';
    END;

    IF @StatusCode='AVAILABLE' AND @TableResultRequested=1
    BEGIN
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'configuration|resourcePools|workloadGroups|sessions|tempdbGovernance'
            , @MappingTable=N'#ResourceGovernorAnalysis_ResultTableMap'
            , @StatusCode=@TablePreflightStatus OUTPUT
            , @ErrorMessage=@TablePreflightError OUTPUT
            , @ThrowOnError=0;

        SET @RestoreLockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
        EXEC [sys].[sp_executesql] @RestoreLockTimeoutSql;

        IF @TablePreflightStatus<>'AVAILABLE'
        BEGIN
            SET @StatusCode=@TablePreflightStatus;
            SET @ErrorMessage=@TablePreflightError;
        END;
    END;

    IF @StatusCode<>'AVAILABLE'
    BEGIN
        SET @RestoreLockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
        EXEC [sys].[sp_executesql] @RestoreLockTimeoutSql;
        THROW 51011,@ErrorMessage,1;
    END;

    SET LOCK_TIMEOUT 0;

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
              @TempdbGovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                    WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                    ELSE 'ERROR_HANDLED' END
            , @TempdbGovernanceErrorNumber=ERROR_NUMBER()
            , @TempdbGovernanceErrorMessage=ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        INSERT [#ResourceGovernorAnalysis_Cfg]
        (
              [ClassifierFunctionId],[IsEnabled],[ReconfigurationPending],[ClassifierFunctionName]
        )
        SELECT
              [stored].[classifier_function_id]
            , [stored].[is_enabled]
            , [effective].[is_reconfiguration_pending]
            , CASE
                  WHEN [stored].[classifier_function_id]=0 THEN NULL
                  WHEN [classifier_object].[object_id] IS NULL THEN N'<nicht sichtbar>'
                  ELSE QUOTENAME([classifier_schema].[name])+N'.'+QUOTENAME([classifier_object].[name])
              END
        FROM [sys].[resource_governor_configuration] AS [stored] WITH (NOLOCK)
        CROSS JOIN [sys].[dm_resource_governor_configuration] AS [effective] WITH (NOLOCK)
        LEFT JOIN [master].[sys].[objects] AS [classifier_object] WITH (NOLOCK)
          ON [classifier_object].[object_id]=[stored].[classifier_function_id]
        LEFT JOIN [master].[sys].[schemas] AS [classifier_schema] WITH (NOLOCK)
          ON [classifier_schema].[schema_id]=[classifier_object].[schema_id];
    END TRY
    BEGIN CATCH
        SELECT
              @SourceErrorNumber=ERROR_NUMBER()
            , @SourceErrorMessage=ERROR_MESSAGE()
            , @SourceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                 WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                 ELSE 'ERROR_HANDLED' END;
        INSERT [#ResourceGovernorAnalysis_Warnings] VALUES(@SourceStatus,@SourceErrorNumber,@SourceErrorMessage);
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        IF @ProductMajorVersion>=17 AND @TempdbGovernanceStatus='AVAILABLE'
            SELECT @TempdbGovernanceStatus=@SourceStatus,
                   @TempdbGovernanceErrorNumber=@SourceErrorNumber,
                   @TempdbGovernanceErrorMessage=@SourceErrorMessage;
    END CATCH;

    BEGIN TRY
        INSERT [#ResourceGovernorAnalysis_SourcePoolCatalog]
        SELECT
              [p].[pool_id],[p].[name],[p].[min_cpu_percent],[p].[max_cpu_percent]
            , [p].[min_memory_percent],[p].[max_memory_percent],[p].[cap_cpu_percent]
            , [p].[min_iops_per_volume],[p].[max_iops_per_volume]
        FROM [sys].[resource_governor_resource_pools] AS [p] WITH (NOLOCK);
    END TRY
    BEGIN CATCH
        SELECT @SourceErrorNumber=ERROR_NUMBER(),@SourceErrorMessage=ERROR_MESSAGE(),
               @SourceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                    WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                    ELSE 'ERROR_HANDLED' END;
        INSERT [#ResourceGovernorAnalysis_Warnings] VALUES(@SourceStatus,@SourceErrorNumber,@SourceErrorMessage);
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
    END CATCH;

    BEGIN TRY
        INSERT [#ResourceGovernorAnalysis_SourcePoolRuntime]
        SELECT
              [p].[pool_id],[p].[statistics_start_time],[p].[total_cpu_usage_ms]
            , [p].[cache_memory_kb],[p].[used_memory_kb],[p].[target_memory_kb],[p].[max_memory_kb]
            , [p].[out_of_memory_count],[p].[active_memgrant_count],[p].[memgrant_waiter_count]
        FROM [sys].[dm_resource_governor_resource_pools] AS [p] WITH (NOLOCK);
    END TRY
    BEGIN CATCH
        SELECT @SourceErrorNumber=ERROR_NUMBER(),@SourceErrorMessage=ERROR_MESSAGE(),
               @SourceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                    WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                    ELSE 'ERROR_HANDLED' END;
        INSERT [#ResourceGovernorAnalysis_Warnings] VALUES(@SourceStatus,@SourceErrorNumber,@SourceErrorMessage);
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
    END CATCH;

    BEGIN TRY
        DECLARE @CatalogTempdbProjection nvarchar(max)=
            CASE WHEN @ProductMajorVersion>=17 AND @CatalogTempdbColumnsValid=1
                 THEN N',CONVERT(decimal(19,2),[g].[group_max_tempdb_data_mb])
                         ,CONVERT(decimal(9,4),[g].[group_max_tempdb_data_percent])'
                 ELSE N',CONVERT(decimal(19,2),NULL),CONVERT(decimal(9,4),NULL)' END;
        SET @Sql=N'INSERT [#ResourceGovernorAnalysis_SourceGroupCatalog]
(
      [GroupId],[GroupName],[PoolId],[Importance],[RequestMaxMemoryGrantPercent]
    , [RequestMaxCpuTimeSec],[RequestMemoryGrantTimeoutSec],[MaxDop],[GroupMaxRequests]
    , [ConfiguredGroupMaxTempdbDataMb],[ConfiguredGroupMaxTempdbDataPercent]
)
SELECT
      [g].[group_id],[g].[name],[g].[pool_id],[g].[importance]
    , CONVERT(decimal(9,4),[g].[request_max_memory_grant_percent_numeric])
    , [g].[request_max_cpu_time_sec],[g].[request_memory_grant_timeout_sec]
    , [g].[max_dop],[g].[group_max_requests]'
    +@CatalogTempdbProjection+
N'
FROM [sys].[resource_governor_workload_groups] AS [g] WITH (NOLOCK);';
        EXEC [sys].[sp_executesql] @Sql;
    END TRY
    BEGIN CATCH
        SELECT @SourceErrorNumber=ERROR_NUMBER(),@SourceErrorMessage=ERROR_MESSAGE(),
               @SourceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                    WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                    ELSE 'ERROR_HANDLED' END;
        INSERT [#ResourceGovernorAnalysis_Warnings] VALUES(@SourceStatus,@SourceErrorNumber,@SourceErrorMessage);
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        IF @ProductMajorVersion>=17
            SELECT @TempdbGovernanceStatus=@SourceStatus,
                   @TempdbGovernanceErrorNumber=@SourceErrorNumber,
                   @TempdbGovernanceErrorMessage=@SourceErrorMessage;
    END CATCH;

    BEGIN TRY
        DECLARE @RuntimeTempdbProjection nvarchar(max)=
            CASE WHEN @ProductMajorVersion>=17 AND @RuntimeTempdbColumnsValid=1
                 THEN N',CONVERT(bigint,[g].[tempdb_data_space_kb])
                         ,CONVERT(bigint,[g].[peak_tempdb_data_space_kb])
                         ,CONVERT(bigint,[g].[total_tempdb_data_limit_violation_count])'
                 ELSE N',CONVERT(bigint,NULL),CONVERT(bigint,NULL),CONVERT(bigint,NULL)' END;
        SET @Sql=N'INSERT [#ResourceGovernorAnalysis_SourceGroupRuntime]
(
      [GroupId],[GroupName],[PoolId],[StatisticsStartTime],[EffectiveMaxDop]
    , [TotalRequestCount],[TotalQueuedRequestCount],[ActiveRequestCount],[QueuedRequestCount]
    , [TotalReducedMemgrantCount],[MaxRequestGrantMemoryKb],[TotalCpuUsageMs]
    , [TotalLockWaitCount],[TotalLockWaitTimeMs]
    , [TempdbDataSpaceKb],[PeakTempdbDataSpaceKb],[TotalTempdbDataLimitViolationCount]
)
SELECT
      [g].[group_id],[g].[name],[g].[pool_id],[g].[statistics_start_time],[g].[effective_max_dop]
    , [g].[total_request_count],[g].[total_queued_request_count]
    , [g].[active_request_count],[g].[queued_request_count]
    , [g].[total_reduced_memgrant_count],[g].[max_request_grant_memory_kb]
    , [g].[total_cpu_usage_ms],[g].[total_lock_wait_count],[g].[total_lock_wait_time_ms]'
    +@RuntimeTempdbProjection+
N'
FROM [sys].[dm_resource_governor_workload_groups] AS [g] WITH (NOLOCK);';
        EXEC [sys].[sp_executesql] @Sql;
    END TRY
    BEGIN CATCH
        SELECT @SourceErrorNumber=ERROR_NUMBER(),@SourceErrorMessage=ERROR_MESSAGE(),
               @SourceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                    WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                    ELSE 'ERROR_HANDLED' END;
        INSERT [#ResourceGovernorAnalysis_Warnings] VALUES(@SourceStatus,@SourceErrorNumber,@SourceErrorMessage);
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        IF @ProductMajorVersion>=17
            SELECT @TempdbGovernanceStatus=@SourceStatus,
                   @TempdbGovernanceErrorNumber=@SourceErrorNumber,
                   @TempdbGovernanceErrorMessage=@SourceErrorMessage;
    END CATCH;

    IF @MitSessions=1
    BEGIN TRY
        INSERT [#ResourceGovernorAnalysis_SourceSessions]
        SELECT TOP (@EffectiveMaxZeilen)
              [s].[session_id],[s].[login_name],[s].[host_name],[s].[program_name]
            , [s].[group_id],[s].[status],[s].[cpu_time],[s].[memory_usage]
            , [s].[reads],[s].[writes],[s].[logical_reads]
        FROM [sys].[dm_exec_sessions] AS [s] WITH (NOLOCK)
        WHERE [s].[is_user_process]=1
        ORDER BY [s].[cpu_time] DESC,[s].[session_id];
    END TRY
    BEGIN CATCH
        SELECT @SourceErrorNumber=ERROR_NUMBER(),@SourceErrorMessage=ERROR_MESSAGE(),
               @SourceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                    WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                    ELSE 'ERROR_HANDLED' END;
        INSERT [#ResourceGovernorAnalysis_Warnings] VALUES(@SourceStatus,@SourceErrorNumber,@SourceErrorMessage);
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
    END CATCH;

    IF @ProductMajorVersion>=17
       AND @CatalogTempdbColumnsValid=1
       AND EXISTS
           (
               SELECT 1
               FROM [#ResourceGovernorAnalysis_SourceGroupCatalog]
               WHERE [ConfiguredGroupMaxTempdbDataMb] IS NULL
                 AND [ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
           )
    BEGIN
        SET @TempdbFileStatus='AVAILABLE';
        BEGIN TRY
            INSERT [#ResourceGovernorAnalysis_TempdbFiles]
            (
                  [FileId],[SizePages],[MaxSizePages],[GrowthPagesOrPercent],[IsPercentGrowth]
            )
            SELECT
                  [f].[file_id],CONVERT(bigint,[f].[size]),CONVERT(bigint,[f].[max_size])
                , CONVERT(bigint,[f].[growth]),[f].[is_percent_growth]
            FROM [master].[sys].[master_files] AS [f] WITH (NOLOCK)
            WHERE [f].[database_id]=2 AND [f].[type]=0;

            SELECT @TempdbMaximumSizeMb=
                CASE
                    WHEN COUNT_BIG(*)>0
                     AND
                     (
                         SUM(CASE WHEN [MaxSizePages]<>-1 AND [GrowthPagesOrPercent]>0 THEN 1 ELSE 0 END)=COUNT_BIG(*)
                         OR
                         SUM(CASE WHEN [MaxSizePages]=-1 AND [GrowthPagesOrPercent]=0 THEN 1 ELSE 0 END)=COUNT_BIG(*)
                     )
                    THEN CONVERT
                         (
                             decimal(19,2),
                             SUM(CASE WHEN [GrowthPagesOrPercent]=0 THEN [SizePages] ELSE [MaxSizePages] END)
                             *8.0/1024.0
                         )
                END
            FROM [#ResourceGovernorAnalysis_TempdbFiles];
        END TRY
        BEGIN CATCH
            SELECT
                  @TempdbFileErrorNumber=ERROR_NUMBER()
                , @TempdbFileErrorMessage=ERROR_MESSAGE()
                , @TempdbFileStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                      WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                      ELSE 'ERROR_HANDLED' END;
            INSERT [#ResourceGovernorAnalysis_Warnings]
            VALUES(@TempdbFileStatus,@TempdbFileErrorNumber,@TempdbFileErrorMessage);
        END CATCH;
    END;

    INSERT [#ResourceGovernorAnalysis_Pools]
    SELECT TOP (@EffectiveMaxZeilen)
          [p].[PoolId],[p].[PoolName],[p].[MinCpuPercent],[p].[MaxCpuPercent]
        , [p].[MinMemoryPercent],[p].[MaxMemoryPercent],[p].[CapCpuPercent]
        , [p].[MinIopsPerVolume],[p].[MaxIopsPerVolume],[d].[StatisticsStartTime]
        , [d].[TotalCpuUsageMs],CONVERT(decimal(19,2),[d].[CacheMemoryKb]/1024.0)
        , CONVERT(decimal(19,2),[d].[UsedMemoryKb]/1024.0)
        , CONVERT(decimal(19,2),[d].[TargetMemoryKb]/1024.0)
        , CONVERT(decimal(19,2),[d].[MaxMemoryKb]/1024.0)
        , [d].[OutOfMemoryCount],[d].[ActiveMemgrantCount],[d].[PendingMemgrantCount]
        , CONVERT(decimal(9,2),100.0*[d].[UsedMemoryKb]/NULLIF([d].[TargetMemoryKb],0))
        , CONVERT(decimal(9,2),100.0*[d].[UsedMemoryKb]/NULLIF([d].[MaxMemoryKb],0))
    FROM [#ResourceGovernorAnalysis_SourcePoolCatalog] AS [p]
    LEFT JOIN [#ResourceGovernorAnalysis_SourcePoolRuntime] AS [d]
      ON [d].[PoolId]=[p].[PoolId]
    ORDER BY [p].[PoolId];

    INSERT [#ResourceGovernorAnalysis_Groups]
    SELECT TOP (@EffectiveMaxZeilen)
          [g].[GroupId],[g].[GroupName],[g].[PoolId],[p].[PoolName],[g].[Importance]
        , [g].[RequestMaxMemoryGrantPercent]
        , CONVERT(decimal(19,2),CONVERT(decimal(38,4),[dp].[MaxMemoryKb])
          *CONVERT(decimal(38,4),[g].[RequestMaxMemoryGrantPercent])/100.0/1024.0)
        , CONVERT(decimal(19,2),CONVERT(decimal(38,4),[dp].[TargetMemoryKb])
          *CONVERT(decimal(38,4),[g].[RequestMaxMemoryGrantPercent])/100.0/1024.0)
        , CONVERT(decimal(19,2),[d].[MaxRequestGrantMemoryKb]/1024.0)
        , [g].[RequestMaxCpuTimeSec],[g].[RequestMemoryGrantTimeoutSec]
        , [g].[MaxDop],[d].[EffectiveMaxDop],[g].[GroupMaxRequests]
        , [d].[TotalRequestCount],[d].[TotalQueuedRequestCount]
        , [d].[ActiveRequestCount],[d].[QueuedRequestCount]
        , [d].[TotalReducedMemgrantCount],[d].[TotalCpuUsageMs]
        , [d].[TotalLockWaitCount],[d].[TotalLockWaitTimeMs]
    FROM [#ResourceGovernorAnalysis_SourceGroupCatalog] AS [g]
    LEFT JOIN [#ResourceGovernorAnalysis_SourceGroupRuntime] AS [d]
      ON [d].[GroupId]=[g].[GroupId]
    LEFT JOIN [#ResourceGovernorAnalysis_SourcePoolCatalog] AS [p]
      ON [p].[PoolId]=[g].[PoolId]
    LEFT JOIN [#ResourceGovernorAnalysis_SourcePoolRuntime] AS [dp]
      ON [dp].[PoolId]=[g].[PoolId]
    ORDER BY [g].[GroupId];

    INSERT [#ResourceGovernorAnalysis_Sessions]
    SELECT
          [s].[SessionId],[s].[LoginName],[s].[HostName],[s].[ProgramName]
        , [s].[GroupId],COALESCE([g].[GroupName],[d].[GroupName]),[p].[PoolName],[s].[Status]
        , [s].[CpuTimeMs],[s].[MemoryUsagePages]
        , CONVERT(decimal(19,2),[s].[MemoryUsagePages]*8.0/1024.0)
        , [s].[Reads],[s].[Writes],[s].[LogicalReads]
    FROM [#ResourceGovernorAnalysis_SourceSessions] AS [s]
    LEFT JOIN [#ResourceGovernorAnalysis_SourceGroupCatalog] AS [g]
      ON [g].[GroupId]=[s].[GroupId]
    LEFT JOIN [#ResourceGovernorAnalysis_SourceGroupRuntime] AS [d]
      ON [d].[GroupId]=[s].[GroupId]
    LEFT JOIN [#ResourceGovernorAnalysis_SourcePoolCatalog] AS [p]
      ON [p].[PoolId]=COALESCE([g].[PoolId],[d].[PoolId]);

    DECLARE @IsResourceGovernorEnabled bit=(SELECT TOP (1) [IsEnabled] FROM [#ResourceGovernorAnalysis_Cfg]);
    DECLARE @ReconfigurationPending bit=(SELECT TOP (1) [ReconfigurationPending] FROM [#ResourceGovernorAnalysis_Cfg]);

    INSERT [#ResourceGovernorAnalysis_TempdbGovernance]
    SELECT TOP (@EffectiveMaxZeilen)
          COALESCE([g].[GroupId],[d].[GroupId])
        , COALESCE([g].[GroupName],[d].[GroupName])
        , COALESCE([g].[PoolId],[d].[PoolId])
        , [p].[PoolName]
        , [g].[ConfiguredGroupMaxTempdbDataMb]
        , [g].[ConfiguredGroupMaxTempdbDataPercent]
        , @TempdbMaximumSizeMb
        , CONVERT
          (
              decimal(19,2),
              CASE
                  WHEN @TempdbGovernanceStatus<>'AVAILABLE' THEN NULL
                  WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
                   AND [g].[ConfiguredGroupMaxTempdbDataPercent] IS NULL THEN NULL
                  WHEN @ReconfigurationPending=1 OR COALESCE(@IsResourceGovernorEnabled,0)=0 THEN NULL
                  WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NOT NULL
                      THEN [g].[ConfiguredGroupMaxTempdbDataMb]
                  WHEN @TempdbFileStatus<>'AVAILABLE' THEN NULL
                  WHEN @TempdbMaximumSizeMb IS NOT NULL
                      THEN [g].[ConfiguredGroupMaxTempdbDataPercent]*@TempdbMaximumSizeMb/100.0
              END
          )
        , CASE
              WHEN @TempdbGovernanceStatus<>'AVAILABLE' THEN 'UNAVAILABLE'
              WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
               AND [g].[ConfiguredGroupMaxTempdbDataPercent] IS NULL THEN 'NO_LIMIT_CONFIGURED'
              WHEN @ReconfigurationPending=1 THEN 'RECONFIGURATION_PENDING'
              WHEN COALESCE(@IsResourceGovernorEnabled,0)=0 THEN 'RESOURCE_GOVERNOR_DISABLED'
              WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NOT NULL THEN 'FIXED_MB_EFFECTIVE'
              WHEN @TempdbFileStatus<>'AVAILABLE' THEN 'UNAVAILABLE'
              WHEN @TempdbMaximumSizeMb IS NOT NULL THEN 'PERCENT_EFFECTIVE'
              ELSE 'PERCENT_NOT_EFFECTIVE'
          END
        , CASE
              WHEN [g].[ConfiguredGroupMaxTempdbDataPercent] IS NULL THEN NULL
              WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NOT NULL THEN CONVERT(bit,0)
              WHEN @ReconfigurationPending=1 OR COALESCE(@IsResourceGovernorEnabled,0)=0 THEN CONVERT(bit,0)
              WHEN @TempdbFileStatus<>'AVAILABLE' THEN NULL
              WHEN @TempdbMaximumSizeMb IS NOT NULL THEN CONVERT(bit,1)
              ELSE CONVERT(bit,0)
          END
        , CONVERT(decimal(19,2),[d].[TempdbDataSpaceKb]/1024.0)
        , CONVERT(decimal(19,2),[d].[PeakTempdbDataSpaceKb]/1024.0)
        , CONVERT
          (
              decimal(9,2),
              100.0*CONVERT(decimal(38,4),[d].[TempdbDataSpaceKb]/1024.0)
              /NULLIF
               (
                   CASE
                       WHEN @ReconfigurationPending=0 AND COALESCE(@IsResourceGovernorEnabled,0)=1
                        AND [g].[ConfiguredGroupMaxTempdbDataMb] IS NOT NULL
                           THEN [g].[ConfiguredGroupMaxTempdbDataMb]
                       WHEN @ReconfigurationPending=0 AND COALESCE(@IsResourceGovernorEnabled,0)=1
                        AND [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
                        AND @TempdbMaximumSizeMb IS NOT NULL
                           THEN [g].[ConfiguredGroupMaxTempdbDataPercent]*@TempdbMaximumSizeMb/100.0
                   END
               ,0)
          )
        , [d].[TotalTempdbDataLimitViolationCount]
        , CASE WHEN [d].[TotalTempdbDataLimitViolationCount] IS NULL THEN NULL
               WHEN [d].[TotalTempdbDataLimitViolationCount]>0 THEN CONVERT(bit,1)
               ELSE CONVERT(bit,0) END
        , [d].[StatisticsStartTime]
        , @IsResourceGovernorEnabled
        , @ReconfigurationPending
        , CASE
              WHEN @TempdbGovernanceStatus='AVAILABLE'
               AND [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
               AND [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
               AND @TempdbFileStatus<>'AVAILABLE'
                  THEN @TempdbFileStatus
              WHEN @TempdbGovernanceStatus='AVAILABLE'
               AND @ReconfigurationPending=1
               AND
                 (
                     [g].[ConfiguredGroupMaxTempdbDataMb] IS NOT NULL
                     OR [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
                 )
                  THEN 'AVAILABLE_LIMITED'
              ELSE @TempdbGovernanceStatus
          END
        , CONVERT
          (
              bit,
              CASE
                  WHEN @TempdbGovernanceStatus<>'AVAILABLE' THEN 1
                  WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
                   AND [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
                   AND @TempdbFileStatus<>'AVAILABLE' THEN 1
                  WHEN @ReconfigurationPending=1
                   AND
                     (
                         [g].[ConfiguredGroupMaxTempdbDataMb] IS NOT NULL
                         OR [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
                     )
                      THEN 1
                  ELSE 0
              END
          )
        , CASE
              WHEN @TempdbGovernanceStatus='UNAVAILABLE_VERSION'
                  THEN N'TempDB Resource Governance beginnt mit SQL Server 2025 (17.x).'
              WHEN @TempdbGovernanceStatus<>'AVAILABLE'
                  THEN COALESCE(@TempdbGovernanceErrorMessage,N'Die SQL-Server-2025-Quelle ist nicht vollständig verfügbar.')
              WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
               AND [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
               AND @TempdbFileStatus<>'AVAILABLE'
                  THEN COALESCE(@TempdbFileErrorMessage,N'Die TempDB-Dateikonfiguration ist im aktuellen Sicherheitskontext nicht auswertbar.')
              WHEN @ReconfigurationPending=1
                  THEN N'Die gespeicherte Konfiguration kann von der aktiven Konfiguration abweichen, bis RECONFIGURE abgeschlossen ist.'
              WHEN [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
               AND [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
               AND @TempdbMaximumSizeMb IS NULL
                  THEN N'Das gespeicherte Prozentlimit ist wegen der TempDB-Dateikonfiguration nicht wirksam.'
              ELSE N'Workload-Group-Zähler sind nicht direkt mit Sessionzählern addierbar; Version Store und TempDB-Log sind nicht umfasst.'
          END
    FROM [#ResourceGovernorAnalysis_SourceGroupCatalog] AS [g]
    FULL OUTER JOIN [#ResourceGovernorAnalysis_SourceGroupRuntime] AS [d]
      ON [d].[GroupId]=[g].[GroupId]
    LEFT JOIN [#ResourceGovernorAnalysis_SourcePoolCatalog] AS [p]
      ON [p].[PoolId]=COALESCE([g].[PoolId],[d].[PoolId])
    ORDER BY COALESCE([g].[GroupId],[d].[GroupId]);

    IF NOT EXISTS (SELECT 1 FROM [#ResourceGovernorAnalysis_TempdbGovernance])
    BEGIN
        INSERT [#ResourceGovernorAnalysis_TempdbGovernance]
        (
              [GroupId],[GroupName],[PoolId],[PoolName]
            , [ConfiguredGroupMaxTempdbDataMb],[ConfiguredGroupMaxTempdbDataPercent]
            , [TempdbMaximumSizeMb],[EffectiveGroupMaxTempdbDataMb]
            , [EffectiveLimitSource],[IsPercentLimitEffective]
            , [TempdbDataSpaceMb],[PeakTempdbDataSpaceMb],[EffectiveLimitUtilizationPercent]
            , [TotalTempdbDataLimitViolationCount],[HasRecordedLimitViolation]
            , [StatisticsStartTime],[IsResourceGovernorEnabled],[ReconfigurationPending]
            , [SourceStatusCode],[IsPartial],[EvidenceLimit]
        )
        VALUES
        (
              NULL,NULL,NULL,NULL,NULL,NULL,@TempdbMaximumSizeMb,NULL
            , 'UNAVAILABLE',NULL,NULL,NULL,NULL,NULL,NULL,NULL
            , @IsResourceGovernorEnabled,@ReconfigurationPending
            , CASE WHEN @TempdbGovernanceStatus='AVAILABLE'
                   THEN 'AVAILABLE_EMPTY_OR_RESTRICTED' ELSE @TempdbGovernanceStatus END
            , 1
            , COALESCE(@TempdbGovernanceErrorMessage,N'Keine sichtbare Workload Group war für die TempDB-Governance auswertbar.')
        );
    END;

    IF @ProductMajorVersion>=17
       AND EXISTS
           (
               SELECT 1
               FROM [#ResourceGovernorAnalysis_TempdbGovernance]
               WHERE [SourceStatusCode] NOT IN ('AVAILABLE','AVAILABLE_EMPTY_OR_RESTRICTED')
           )
    BEGIN
        SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
    END;

    IF @PrintMeldungen=1 AND @StatusCode<>'AVAILABLE'
    BEGIN
        DECLARE @PrintMessage nvarchar(2048)=FORMATMESSAGE
        (
            N'WARNUNG USP_ResourceGovernorAnalysis [%s]: %s',
            @StatusCode,
            COALESCE(@ErrorMessage,@TempdbGovernanceErrorMessage,N'Teilergebnis oder eingeschränkte Sicht.')
        );
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=
        (
            SELECT
                  N'ResourceGovernorAnalysis' AS [resultName]
                , 2 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @IsPartial AS [isPartial]
                , @ProductMajorVersion AS [productMajorVersion]
                , @MaxZeilen AS [requestedMaxRowsPerArray]
                , @ErrorNumber AS [errorNumber]
                , @ErrorMessage AS [errorMessage]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES
        );
        DECLARE @CfgJson nvarchar(max)=
            (SELECT * FROM [#ResourceGovernorAnalysis_Cfg] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @PoolsJson nvarchar(max)=
            (SELECT * FROM [#ResourceGovernorAnalysis_Pools] ORDER BY [PoolId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @GroupsJson nvarchar(max)=
            (SELECT * FROM [#ResourceGovernorAnalysis_Groups] ORDER BY [GroupId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @TempdbGovernanceJson nvarchar(max)=
            (SELECT * FROM [#ResourceGovernorAnalysis_TempdbGovernance] ORDER BY [GroupId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @SessionsJson nvarchar(max)=
            (SELECT * FROM [#ResourceGovernorAnalysis_Sessions] ORDER BY [CpuTimeMs] DESC,[SessionId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max)=
            (SELECT [WarningCode] AS [code],[ErrorNumber] AS [errorNumber],[WarningMessage] AS [message]
             FROM [#ResourceGovernorAnalysis_Warnings] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT
        (
              N'{"meta":',COALESCE(@MetaJson,N'{}')
            , N',"configuration":',COALESCE(@CfgJson,N'[]')
            , N',"resourcePools":',COALESCE(@PoolsJson,N'[]')
            , N',"workloadGroups":',COALESCE(@GroupsJson,N'[]')
            , N',"tempdbGovernance":',COALESCE(@TempdbGovernanceJson,N'[]')
            , N',"sessions":',COALESCE(@SessionsJson,N'[]')
            , N',"warnings":',COALESCE(@WarningsJson,N'[]')
            , N'}'
        );
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT
              @CollectionTimeUtc AS [CollectionTimeUtc]
            , CAST(N'monitor.USP_ResourceGovernorAnalysis' AS nvarchar(256)) AS [ModuleName]
            , @StatusCode AS [StatusCode],@IsPartial AS [IsPartial]
            , @ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage];
        SELECT * FROM [#ResourceGovernorAnalysis_Cfg];
        SELECT * FROM [#ResourceGovernorAnalysis_Pools] ORDER BY [PoolId];
        SELECT * FROM [#ResourceGovernorAnalysis_Groups] ORDER BY [GroupId];
        SELECT * FROM [#ResourceGovernorAnalysis_TempdbGovernance] ORDER BY [GroupId];
        IF @MitSessions=1
            SELECT * FROM [#ResourceGovernorAnalysis_Sessions] ORDER BY [CpuTimeMs] DESC,[SessionId];
        SELECT * FROM [#ResourceGovernorAnalysis_Warnings] ORDER BY [WarningCode],[ErrorNumber];
    END;

    BEGIN TRY
        IF @ConsoleResultRequested=1
        BEGIN
            EXEC [monitor].[InternalEmitConsoleResult]
                  @SourceTable=N'#ResourceGovernorAnalysis_Cfg'
                , @ResultLabel=N'Resource-Governor-Konfiguration'
                , @EmptyMessage=N'Keine sichtbare Resource-Governor-Konfiguration';
            EXEC [monitor].[InternalEmitConsoleResult]
                  @SourceTable=N'#ResourceGovernorAnalysis_Pools'
                , @ResultLabel=N'Resource Pools'
                , @EmptyMessage=N'Keine sichtbaren Resource Pools';
            EXEC [monitor].[InternalEmitConsoleResult]
                  @SourceTable=N'#ResourceGovernorAnalysis_Groups'
                , @ResultLabel=N'Workload Groups'
                , @EmptyMessage=N'Keine sichtbaren Workload Groups';
            EXEC [monitor].[InternalEmitConsoleResult]
                  @SourceTable=N'#ResourceGovernorAnalysis_TempdbGovernance'
                , @ResultLabel=N'TempDB Resource Governance'
                , @EmptyMessage=N'Keine TempDB-Governance-Evidenz';
            IF @MitSessions=1
                EXEC [monitor].[InternalEmitConsoleResult]
                      @SourceTable=N'#ResourceGovernorAnalysis_Sessions'
                    , @ResultLabel=N'Resource-Governor-Sessions'
                    , @EmptyMessage=N'Keine sichtbaren Benutzersessions';
        END;

        IF @TableResultRequested=1
        BEGIN
            DECLARE @TableTarget sysname;
            SELECT @TableTarget=[TargetTable] FROM [#ResourceGovernorAnalysis_ResultTableMap] WHERE [ResultName]=N'configuration';
            IF @TableTarget IS NOT NULL
                EXEC [monitor].[InternalWriteResultTable] @SourceTable=N'#ResourceGovernorAnalysis_Cfg',@TargetTable=@TableTarget,@ThrowOnError=1;

            SET @TableTarget=NULL;
            SELECT @TableTarget=[TargetTable] FROM [#ResourceGovernorAnalysis_ResultTableMap] WHERE [ResultName]=N'resourcePools';
            IF @TableTarget IS NOT NULL
                EXEC [monitor].[InternalWriteResultTable] @SourceTable=N'#ResourceGovernorAnalysis_Pools',@TargetTable=@TableTarget,@ThrowOnError=1;

            SET @TableTarget=NULL;
            SELECT @TableTarget=[TargetTable] FROM [#ResourceGovernorAnalysis_ResultTableMap] WHERE [ResultName]=N'workloadGroups';
            IF @TableTarget IS NOT NULL
                EXEC [monitor].[InternalWriteResultTable] @SourceTable=N'#ResourceGovernorAnalysis_Groups',@TargetTable=@TableTarget,@ThrowOnError=1;

            SET @TableTarget=NULL;
            SELECT @TableTarget=[TargetTable] FROM [#ResourceGovernorAnalysis_ResultTableMap] WHERE [ResultName]=N'sessions';
            IF @TableTarget IS NOT NULL
                EXEC [monitor].[InternalWriteResultTable] @SourceTable=N'#ResourceGovernorAnalysis_Sessions',@TargetTable=@TableTarget,@ThrowOnError=1;

            SET @TableTarget=NULL;
            SELECT @TableTarget=[TargetTable] FROM [#ResourceGovernorAnalysis_ResultTableMap] WHERE [ResultName]=N'tempdbGovernance';
            IF @TableTarget IS NOT NULL
                EXEC [monitor].[InternalWriteResultTable] @SourceTable=N'#ResourceGovernorAnalysis_TempdbGovernance',@TargetTable=@TableTarget,@ThrowOnError=1;
        END;
    END TRY
    BEGIN CATCH
        SET @RestoreLockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
        EXEC [sys].[sp_executesql] @RestoreLockTimeoutSql;
        THROW;
    END CATCH;

    SET @RestoreLockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
    EXEC [sys].[sp_executesql] @RestoreLockTimeoutSql;
END;
GO
