USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CurrentTempDB
Version      : 4.0.0
Stand        : 2026-07-23
Zweck        : Zeigt aktuellen TempDB-Verbrauch je Session, optional Dateien
               und SQL-Server-2025-TempDB-Governance je Workload Group.
SQL-Version  : SQL Server 2019 oder neuer; Governance ab 2025 (17.x).
Datenquellen : sys.dm_exec_sessions, tempdb.sys.dm_db_session_space_usage,
               tempdb.sys.database_files, Resource-Governor-Katalog/DMV und
               master.sys.master_files; im Parentpfad gemeinsame Materialisierung.
Output       : sessions, tempdbFiles, tempdbGovernance und warnings;
               RAW, CONSOLE, NONE, JSON und benannte TABLE-Ziele.
Locking      : LOCK_TIMEOUT 0 für Quellen; vorheriger Sessionwert wird
               auch nach TABLE- und CONSOLE-Ausgabe wiederhergestellt.
Datenschutz  : Laufzeitwerte werden nur ausgegeben, nicht persistiert.
Änderungen   : 4.0.0 - SQL25-003 TempDB Resource Governance.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CurrentTempDB]
      @SessionIds                    nvarchar(max) = NULL
    , @AktuelleSessionEinbeziehen    bit           = 0
    , @MinNettoMb                    decimal(19,2)  = 0
    , @SystemSessionsEinbeziehen     bit           = 0
    , @MitDateien                    bit           = 1
    , @MaxZeilen                     int           = 1000
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson              nvarchar(max) = NULL
    , @JsonErzeugen                  bit           = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                bit           = 1
    , @Hilfe                         bit           = 0
    , @ParentCurrentStateSnapshotId  uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
    DECLARE @RestoreLockTimeoutSql nvarchar(100);
    SET @Json=NULL;

    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit=CASE WHEN @OutputMode='TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit=CASE WHEN @OutputMode='CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                              THEN CONVERT(bigint,9223372036854775807)
                              WHEN @MaxZeilen>0 THEN CONVERT(bigint,@MaxZeilen)
                              ELSE CONVERT(bigint,0) END;
    DECLARE @Candidates bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                                   THEN CONVERT(bigint,9223372036854775807)
                                   WHEN @MaxZeilen<2147483647 THEN CONVERT(bigint,@MaxZeilen)+1
                                   ELSE CONVERT(bigint,@MaxZeilen) END;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_CurrentTempDB';
        PRINT N'@SessionIds=N''57|61''; NULL = keine Einschränkung.';
        PRINT N'@MitDateien=1 liefert tempdbFiles.';
        PRINT N'@MaxZeilen positiv = begrenzt; NULL/0 = unbegrenzt.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE; JSON über @JsonErzeugen=1.';
        PRINT N'TABLE erlaubt sessions und tempdbGovernance.';
        PRINT N'tempdbGovernance trennt Limit, Wirksamkeit, aktuelle Nutzung, Peak und Verletzungszähler.';
        RETURN;
    END;

    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @ProductMajorVersion int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @RowCount bigint=0;
    DECLARE @HasMoreRows bit=0;
    DECLARE @EvidenceSnapshotId uniqueidentifier=COALESCE(@ParentCurrentStateSnapshotId,NEWID());
    DECLARE @EvidenceSnapshotStartedAtUtc datetime2(3)=@Now;
    DECLARE @EvidenceIsPartial bit=0;
    DECLARE @TablePreflightStatus varchar(40);
    DECLARE @TablePreflightError nvarchar(2048);
    DECLARE @Sql nvarchar(max);

    CREATE TABLE [#CurrentTempDB_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );

    CREATE TABLE [#CurrentTempDB_SessionFilter]([SessionId] smallint NOT NULL PRIMARY KEY);
    CREATE TABLE [#CurrentTempDB_Sessions]
    (
          [SessionId] smallint NOT NULL
        , [LoginName] nvarchar(128) NULL
        , [HostName] nvarchar(128) NULL
        , [ProgramName] nvarchar(128) NULL
        , [SessionStatus] nvarchar(30) NULL
        , [UserObjectsAllocatedMb] decimal(19,2) NOT NULL
        , [UserObjectsDeallocatedMb] decimal(19,2) NOT NULL
        , [UserObjectsNetMb] decimal(19,2) NOT NULL
        , [InternalObjectsAllocatedMb] decimal(19,2) NOT NULL
        , [InternalObjectsDeallocatedMb] decimal(19,2) NOT NULL
        , [InternalObjectsNetMb] decimal(19,2) NOT NULL
        , [TotalNetMb] decimal(19,2) NOT NULL
    );

    CREATE TABLE [#CurrentTempDB_Files]
    (
          [FileId] int NOT NULL
        , [LogicalName] sysname NOT NULL
        , [PhysicalName] nvarchar(260) NOT NULL
        , [FileTypeDesc] nvarchar(60) NOT NULL
        , [SizeMb] decimal(19,2) NOT NULL
        , [UsedMb] decimal(19,2) NULL
        , [FreeMb] decimal(19,2) NULL
        , [UsedPercent] decimal(9,2) NULL
        , [GrowthMb] decimal(19,2) NULL
        , [IsPercentGrowth] bit NOT NULL
    );

    CREATE TABLE [#CurrentTempDB_TempdbGovernance]
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

    CREATE TABLE [#CurrentTempDB_Warnings]
    (
          [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    CREATE TABLE [#CurrentTempDB_SourceSessions]
    (
          [session_id] smallint NOT NULL PRIMARY KEY
        , [is_user_process] bit NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [login_name] nvarchar(128) NOT NULL
        , [host_name] nvarchar(128) NULL
        , [program_name] nvarchar(128) NULL
    );

    CREATE TABLE [#CurrentTempDB_SourceSessionUsage]
    (
          [session_id] smallint NOT NULL PRIMARY KEY
        , [user_objects_alloc_page_count] bigint NOT NULL
        , [user_objects_dealloc_page_count] bigint NOT NULL
        , [internal_objects_alloc_page_count] bigint NOT NULL
        , [internal_objects_dealloc_page_count] bigint NOT NULL
    );

    CREATE TABLE [#CurrentTempDB_SourceGroupCatalog]
    (
          [GroupId] int NOT NULL PRIMARY KEY
        , [GroupName] sysname NOT NULL
        , [PoolId] int NOT NULL
        , [ConfiguredGroupMaxTempdbDataMb] decimal(19,2) NULL
        , [ConfiguredGroupMaxTempdbDataPercent] decimal(9,4) NULL
    );

    CREATE TABLE [#CurrentTempDB_SourceGroupRuntime]
    (
          [GroupId] int NOT NULL PRIMARY KEY
        , [GroupName] sysname NOT NULL
        , [PoolId] int NOT NULL
        , [StatisticsStartTime] datetime NULL
        , [TempdbDataSpaceKb] bigint NULL
        , [PeakTempdbDataSpaceKb] bigint NULL
        , [TotalTempdbDataLimitViolationCount] bigint NULL
    );

    CREATE TABLE [#CurrentTempDB_SourcePools]
    (
          [PoolId] int NOT NULL PRIMARY KEY
        , [PoolName] sysname NOT NULL
    );

    CREATE TABLE [#CurrentTempDB_TempdbConfigFiles]
    (
          [FileId] int NOT NULL PRIMARY KEY
        , [SizePages] bigint NOT NULL
        , [MaxSizePages] bigint NOT NULL
        , [GrowthPagesOrPercent] bigint NOT NULL
    );

    IF @SessionIds IS NOT NULL
    BEGIN
        IF EXISTS
           (
               SELECT 1
               FROM [monitor].[TVF_ParseBigintList](@SessionIds)
               WHERE [IsValid]=0 OR [NumberValue] NOT BETWEEN 0 AND 32767
           )
           OR EXISTS
              (
                  SELECT [NumberValue]
                  FROM [monitor].[TVF_ParseBigintList](@SessionIds)
                  WHERE [IsValid]=1
                  GROUP BY [NumberValue]
                  HAVING COUNT(*)>1
              )
        BEGIN
            SET @StatusCode='INVALID_PARAMETER';
            SET @ErrorMessage=N'@SessionIds ist ungültig oder enthält Duplikate.';
        END
        ELSE
            INSERT [#CurrentTempDB_SessionFilter]([SessionId])
            SELECT CONVERT(smallint,[NumberValue])
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid]=1;
    END;

    IF @StatusCode='AVAILABLE'
       AND
       (
           @MinNettoMb<0
           OR @MaxZeilen<0
           OR @AktuelleSessionEinbeziehen IS NULL
           OR @SystemSessionsEinbeziehen IS NULL
           OR @MitDateien IS NULL
           OR @JsonErzeugen IS NULL
           OR @OutputMode NOT IN ('RAW','CONSOLE','TABLE','NONE')
           OR (@OutputMode<>'TABLE' AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL)
       )
    BEGIN
        SET @StatusCode='INVALID_PARAMETER';
        SET @ErrorMessage=N'Mindestens ein Parameter besitzt einen ungültigen Wert.';
    END;

    IF @StatusCode='AVAILABLE' AND @TableResultRequested=1
    BEGIN
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'sessions|tempdbGovernance'
            , @MappingTable=N'#CurrentTempDB_ResultTableMap'
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

    BEGIN TRY
        IF @ParentCurrentStateSnapshotId IS NOT NULL
        BEGIN
            EXEC [sys].[sp_executesql] N'
                DECLARE @Probe int;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Context] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Sessions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_ResourcePools] WHERE 1=0;';

            IF NOT EXISTS
               (
                   SELECT 1
                   FROM [#CurrentOverview_CurrentStateSnapshot_Context]
                   WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                     AND [OwnerSessionId]=CONVERT(smallint,@@SPID)
                     AND [ContractVersion]=2
               )
                THROW 51020,N'Die Parent-Snapshot-ID gehört nicht zum aktuellen Aufruf.',1;

            INSERT [#CurrentTempDB_SourceSessions]
            SELECT [session_id],[is_user_process],[status],[login_name],[host_name],[program_name]
            FROM [#CurrentOverview_CurrentStateSnapshot_Sessions]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentTempDB_SourceSessionUsage]
            SELECT
                  [session_id],[user_objects_alloc_page_count],[user_objects_dealloc_page_count]
                , [internal_objects_alloc_page_count],[internal_objects_dealloc_page_count]
            FROM [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentTempDB_TempdbGovernance]
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
            SELECT
                  [g].[group_id],[g].[name],[g].[pool_id],[p].[name]
                , [g].[configured_group_max_tempdb_data_mb]
                , [g].[configured_group_max_tempdb_data_percent]
                , [g].[tempdb_maximum_size_mb]
                , [g].[effective_group_max_tempdb_data_mb]
                , [g].[effective_limit_source]
                , [g].[is_percent_limit_effective]
                , [g].[tempdb_data_space_mb]
                , [g].[peak_tempdb_data_space_mb]
                , [g].[effective_limit_utilization_percent]
                , [g].[total_tempdb_data_limit_violation_count]
                , [g].[has_recorded_limit_violation]
                , [g].[statistics_start_time]
                , [g].[is_resource_governor_enabled]
                , [g].[reconfiguration_pending]
                , [g].[tempdb_governance_status_code]
                , [g].[tempdb_governance_is_partial]
                , [g].[tempdb_governance_evidence_limit]
            FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups] AS [g]
            LEFT JOIN [#CurrentOverview_CurrentStateSnapshot_ResourcePools] AS [p]
              ON [p].[SnapshotId]=[g].[SnapshotId]
             AND [p].[pool_id]=[g].[pool_id]
            WHERE [g].[SnapshotId]=@ParentCurrentStateSnapshotId;

            IF NOT EXISTS (SELECT 1 FROM [#CurrentTempDB_TempdbGovernance])
            BEGIN
                DECLARE @ParentGovernanceStatus varchar(40)=
                (
                    SELECT TOP (1) [StatusCode]
                    FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
                    WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                      AND [SourceCode] IN ('TEMPDB_GOVERNANCE','WORKLOAD_GROUPS')
                    ORDER BY CASE WHEN [SourceCode]='TEMPDB_GOVERNANCE' THEN 0 ELSE 1 END
                );
                DECLARE @ParentGovernanceErrorNumber int=
                (
                    SELECT TOP (1) [ErrorNumber]
                    FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
                    WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                      AND [SourceCode] IN ('TEMPDB_GOVERNANCE','WORKLOAD_GROUPS')
                    ORDER BY CASE WHEN [SourceCode]='TEMPDB_GOVERNANCE' THEN 0 ELSE 1 END
                );
                DECLARE @ParentGovernanceErrorMessage nvarchar(2048)=
                (
                    SELECT TOP (1) [ErrorMessage]
                    FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
                    WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                      AND [SourceCode] IN ('TEMPDB_GOVERNANCE','WORKLOAD_GROUPS')
                    ORDER BY CASE WHEN [SourceCode]='TEMPDB_GOVERNANCE' THEN 0 ELSE 1 END
                );

                INSERT [#CurrentTempDB_TempdbGovernance]
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
                      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'UNAVAILABLE',NULL
                    , NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
                    , COALESCE(@ParentGovernanceStatus,
                        CASE WHEN @ProductMajorVersion<17 THEN 'UNAVAILABLE_VERSION'
                             ELSE 'AVAILABLE_EMPTY_OR_RESTRICTED' END)
                    , 1
                    , COALESCE
                      (
                          @ParentGovernanceErrorMessage,
                          CASE WHEN @ProductMajorVersion<17
                               THEN N'TempDB Resource Governance beginnt mit SQL Server 2025 (17.x).'
                               ELSE N'Keine sichtbare Workload Group war für die TempDB-Governance auswertbar.' END
                      )
                );

                IF @ParentGovernanceErrorNumber IS NOT NULL
                    INSERT [#CurrentTempDB_Warnings]
                    VALUES(COALESCE(@ParentGovernanceStatus,'AVAILABLE_LIMITED'),
                           @ParentGovernanceErrorNumber,@ParentGovernanceErrorMessage);
            END;

            SELECT
                  @EvidenceSnapshotStartedAtUtc=MIN([CapturedAtUtc])
                , @EvidenceIsPartial=CONVERT(bit,MAX(CONVERT(int,[IsPartial])))
            FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
              AND [SourceCode] IN ('SESSIONS','TEMPDB_SESSION_USAGE');

            IF @ProductMajorVersion>=17
               AND EXISTS
                   (
                       SELECT 1
                       FROM [#CurrentTempDB_TempdbGovernance]
                       WHERE [SourceStatusCode] NOT IN ('AVAILABLE','AVAILABLE_EMPTY_OR_RESTRICTED')
                   )
            BEGIN
                SET @EvidenceIsPartial=1;
                IF @StatusCode='AVAILABLE' SET @StatusCode='AVAILABLE_LIMITED';
            END;
        END
        ELSE
        BEGIN
            SET @EvidenceSnapshotStartedAtUtc=SYSUTCDATETIME();

            INSERT [#CurrentTempDB_SourceSessions]
            SELECT [session_id],[is_user_process],[status],[login_name],[host_name],[program_name]
            FROM [sys].[dm_exec_sessions] WITH (NOLOCK);

            EXEC [sys].[sp_executesql] N'
                USE [tempdb];
                INSERT [#CurrentTempDB_SourceSessionUsage]
                SELECT
                      [session_id],[user_objects_alloc_page_count],[user_objects_dealloc_page_count]
                    , [internal_objects_alloc_page_count],[internal_objects_dealloc_page_count]
                FROM [sys].[dm_db_session_space_usage] WITH (NOLOCK);';

            IF @ProductMajorVersion IS NULL OR @ProductMajorVersion<17
            BEGIN
                INSERT [#CurrentTempDB_TempdbGovernance]
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
                      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'UNAVAILABLE',NULL
                    , NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
                    , 'UNAVAILABLE_VERSION',1
                    , N'TempDB Resource Governance beginnt mit SQL Server 2025 (17.x).'
                );
            END
            ELSE
            BEGIN
                DECLARE @CatalogColumnsValid bit=0,@RuntimeColumnsValid bit=0;
                DECLARE @GovernanceStatus varchar(40)='AVAILABLE';
                DECLARE @GovernanceErrorNumber int=NULL;
                DECLARE @GovernanceErrorMessage nvarchar(2048)=NULL;
                DECLARE @TempdbMaximumSizeMb decimal(19,2)=NULL;
                DECLARE @TempdbFileStatus varchar(40)='NOT_APPLICABLE';
                DECLARE @TempdbFileErrorNumber int=NULL;
                DECLARE @TempdbFileErrorMessage nvarchar(2048)=NULL;
                DECLARE @IsResourceGovernorEnabled bit=NULL;
                DECLARE @ReconfigurationPending bit=NULL;

                BEGIN TRY
                    SELECT
                          @CatalogColumnsValid=CONVERT
                          (
                              bit,
                              CASE WHEN SUM(CASE WHEN [o].[name]=N'resource_governor_workload_groups'
                                                  AND [c].[name] IN
                                                      (N'group_max_tempdb_data_mb',N'group_max_tempdb_data_percent')
                                                THEN 1 ELSE 0 END)=2
                                   THEN 1 ELSE 0 END
                          )
                        , @RuntimeColumnsValid=CONVERT
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

                    IF @CatalogColumnsValid=0 OR @RuntimeColumnsValid=0
                        SET @GovernanceStatus='UNAVAILABLE_SOURCE_SCHEMA';
                END TRY
                BEGIN CATCH
                    SELECT
                          @GovernanceErrorNumber=ERROR_NUMBER()
                        , @GovernanceErrorMessage=ERROR_MESSAGE()
                        , @GovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                             WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
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
                          @GovernanceErrorNumber=ERROR_NUMBER()
                        , @GovernanceErrorMessage=ERROR_MESSAGE()
                        , @GovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                             WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                             ELSE 'ERROR_HANDLED' END;
                END CATCH;

                IF @CatalogColumnsValid=1
                BEGIN TRY
                    EXEC [sys].[sp_executesql] N'
                        INSERT [#CurrentTempDB_SourceGroupCatalog]
                        (
                              [GroupId],[GroupName],[PoolId]
                            , [ConfiguredGroupMaxTempdbDataMb]
                            , [ConfiguredGroupMaxTempdbDataPercent]
                        )
                        SELECT
                              [g].[group_id],[g].[name],[g].[pool_id]
                            , CONVERT(decimal(19,2),[g].[group_max_tempdb_data_mb])
                            , CONVERT(decimal(9,4),[g].[group_max_tempdb_data_percent])
                        FROM [sys].[resource_governor_workload_groups] AS [g] WITH (NOLOCK);';
                END TRY
                BEGIN CATCH
                    SELECT
                          @GovernanceErrorNumber=ERROR_NUMBER()
                        , @GovernanceErrorMessage=ERROR_MESSAGE()
                        , @GovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                             WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                             ELSE 'ERROR_HANDLED' END;
                END CATCH;

                IF @RuntimeColumnsValid=1
                BEGIN TRY
                    EXEC [sys].[sp_executesql] N'
                        INSERT [#CurrentTempDB_SourceGroupRuntime]
                        (
                              [GroupId],[GroupName],[PoolId],[StatisticsStartTime]
                            , [TempdbDataSpaceKb],[PeakTempdbDataSpaceKb]
                            , [TotalTempdbDataLimitViolationCount]
                        )
                        SELECT
                              [g].[group_id],[g].[name],[g].[pool_id],[g].[statistics_start_time]
                            , CONVERT(bigint,[g].[tempdb_data_space_kb])
                            , CONVERT(bigint,[g].[peak_tempdb_data_space_kb])
                            , CONVERT(bigint,[g].[total_tempdb_data_limit_violation_count])
                        FROM [sys].[dm_resource_governor_workload_groups] AS [g] WITH (NOLOCK);';

                    INSERT [#CurrentTempDB_SourcePools]
                    SELECT [p].[pool_id],[p].[name]
                    FROM [sys].[dm_resource_governor_resource_pools] AS [p] WITH (NOLOCK);
                END TRY
                BEGIN CATCH
                    SELECT
                          @GovernanceErrorNumber=ERROR_NUMBER()
                        , @GovernanceErrorMessage=ERROR_MESSAGE()
                        , @GovernanceStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                             WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                             ELSE 'ERROR_HANDLED' END;
                END CATCH;

                IF @GovernanceStatus='AVAILABLE'
                   AND EXISTS
                       (
                           SELECT 1
                           FROM [#CurrentTempDB_SourceGroupCatalog]
                           WHERE [ConfiguredGroupMaxTempdbDataMb] IS NULL
                             AND [ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
                       )
                BEGIN
                    SET @TempdbFileStatus='AVAILABLE';
                    BEGIN TRY
                        INSERT [#CurrentTempDB_TempdbConfigFiles]
                        SELECT
                              [f].[file_id],CONVERT(bigint,[f].[size])
                            , CONVERT(bigint,[f].[max_size]),CONVERT(bigint,[f].[growth])
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
                        FROM [#CurrentTempDB_TempdbConfigFiles];
                    END TRY
                    BEGIN CATCH
                        SELECT
                              @TempdbFileErrorNumber=ERROR_NUMBER()
                            , @TempdbFileErrorMessage=ERROR_MESSAGE()
                            , @TempdbFileStatus=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                                 WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                                 ELSE 'ERROR_HANDLED' END;
                        INSERT [#CurrentTempDB_Warnings]
                        VALUES(@TempdbFileStatus,@TempdbFileErrorNumber,@TempdbFileErrorMessage);
                    END CATCH;
                END;

                INSERT [#CurrentTempDB_TempdbGovernance]
                SELECT TOP (@Limit)
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
                              WHEN @GovernanceStatus<>'AVAILABLE' THEN NULL
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
                          WHEN @GovernanceStatus<>'AVAILABLE' THEN 'UNAVAILABLE'
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
                          WHEN @GovernanceStatus='AVAILABLE'
                           AND [g].[ConfiguredGroupMaxTempdbDataMb] IS NULL
                           AND [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
                           AND @TempdbFileStatus<>'AVAILABLE'
                              THEN @TempdbFileStatus
                          WHEN @GovernanceStatus='AVAILABLE'
                           AND @ReconfigurationPending=1
                           AND
                             (
                                 [g].[ConfiguredGroupMaxTempdbDataMb] IS NOT NULL
                                 OR [g].[ConfiguredGroupMaxTempdbDataPercent] IS NOT NULL
                             )
                              THEN 'AVAILABLE_LIMITED'
                          ELSE @GovernanceStatus
                      END
                    , CONVERT
                      (
                          bit,
                          CASE
                              WHEN @GovernanceStatus<>'AVAILABLE' THEN 1
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
                          WHEN @GovernanceStatus<>'AVAILABLE'
                              THEN COALESCE(@GovernanceErrorMessage,N'Die SQL-Server-2025-Quelle ist nicht vollständig verfügbar.')
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
                FROM [#CurrentTempDB_SourceGroupCatalog] AS [g]
                FULL OUTER JOIN [#CurrentTempDB_SourceGroupRuntime] AS [d]
                  ON [d].[GroupId]=[g].[GroupId]
                LEFT JOIN [#CurrentTempDB_SourcePools] AS [p]
                  ON [p].[PoolId]=COALESCE([g].[PoolId],[d].[PoolId])
                ORDER BY COALESCE([g].[GroupId],[d].[GroupId]);

                IF NOT EXISTS (SELECT 1 FROM [#CurrentTempDB_TempdbGovernance])
                    INSERT [#CurrentTempDB_TempdbGovernance]
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
                        , CASE WHEN @GovernanceStatus='AVAILABLE'
                               THEN 'AVAILABLE_EMPTY_OR_RESTRICTED' ELSE @GovernanceStatus END
                        , 1
                        , COALESCE(@GovernanceErrorMessage,N'Keine sichtbare Workload Group war für die TempDB-Governance auswertbar.')
                    );

                IF EXISTS
                   (
                       SELECT 1
                       FROM [#CurrentTempDB_TempdbGovernance]
                       WHERE [SourceStatusCode] NOT IN ('AVAILABLE','AVAILABLE_EMPTY_OR_RESTRICTED')
                   )
                BEGIN
                    SET @EvidenceIsPartial=1;
                    IF @StatusCode='AVAILABLE' SET @StatusCode='AVAILABLE_LIMITED';
                END;
            END;
        END;

        INSERT [#CurrentTempDB_Sessions]
        (
              [SessionId],[LoginName],[HostName],[ProgramName],[SessionStatus]
            , [UserObjectsAllocatedMb],[UserObjectsDeallocatedMb],[UserObjectsNetMb]
            , [InternalObjectsAllocatedMb],[InternalObjectsDeallocatedMb],[InternalObjectsNetMb]
            , [TotalNetMb]
        )
        SELECT TOP (@Candidates)
              [su].[session_id],[s].[login_name],[s].[host_name],[s].[program_name],[s].[status]
            , CONVERT(decimal(19,2),[su].[user_objects_alloc_page_count]*8.0/1024.0)
            , CONVERT(decimal(19,2),[su].[user_objects_dealloc_page_count]*8.0/1024.0)
            , CONVERT(decimal(19,2),([su].[user_objects_alloc_page_count]-[su].[user_objects_dealloc_page_count])*8.0/1024.0)
            , CONVERT(decimal(19,2),[su].[internal_objects_alloc_page_count]*8.0/1024.0)
            , CONVERT(decimal(19,2),[su].[internal_objects_dealloc_page_count]*8.0/1024.0)
            , CONVERT(decimal(19,2),([su].[internal_objects_alloc_page_count]-[su].[internal_objects_dealloc_page_count])*8.0/1024.0)
            , CONVERT
              (
                  decimal(19,2),
                  (
                      [su].[user_objects_alloc_page_count]-[su].[user_objects_dealloc_page_count]
                      +[su].[internal_objects_alloc_page_count]-[su].[internal_objects_dealloc_page_count]
                  )*8.0/1024.0
              )
        FROM [#CurrentTempDB_SourceSessionUsage] AS [su]
        LEFT JOIN [#CurrentTempDB_SourceSessions] AS [s]
          ON [s].[session_id]=[su].[session_id]
        WHERE (@AktuelleSessionEinbeziehen=1 OR [su].[session_id]<>@@SPID)
          AND (@SystemSessionsEinbeziehen=1 OR COALESCE([s].[is_user_process],1)=1)
          AND
          (
              @SessionIds IS NULL
              OR EXISTS
                 (
                     SELECT 1
                     FROM [#CurrentTempDB_SessionFilter] AS [f]
                     WHERE [f].[SessionId]=[su].[session_id]
                 )
          )
          AND
          (
              [su].[user_objects_alloc_page_count]-[su].[user_objects_dealloc_page_count]
              +[su].[internal_objects_alloc_page_count]-[su].[internal_objects_dealloc_page_count]
          )*8.0/1024.0>=@MinNettoMb
        ORDER BY
          (
              [su].[user_objects_alloc_page_count]-[su].[user_objects_dealloc_page_count]
              +[su].[internal_objects_alloc_page_count]-[su].[internal_objects_dealloc_page_count]
          ) DESC,
          [su].[session_id];

        IF @MitDateien=1
        BEGIN
            SET @Sql=N'USE [tempdb];
INSERT [#CurrentTempDB_Files]
(
      [FileId],[LogicalName],[PhysicalName],[FileTypeDesc]
    , [SizeMb],[UsedMb],[FreeMb],[UsedPercent],[GrowthMb],[IsPercentGrowth]
)
SELECT
      [df].[file_id],[df].[name],[df].[physical_name],[df].[type_desc]
    , CONVERT(decimal(19,2),[df].[size]*8.0/1024.0)
    , CONVERT(decimal(19,2),FILEPROPERTY([df].[name],N''SpaceUsed'')*8.0/1024.0)
    , CONVERT(decimal(19,2),([df].[size]-FILEPROPERTY([df].[name],N''SpaceUsed''))*8.0/1024.0)
    , CONVERT(decimal(9,2),100.0*FILEPROPERTY([df].[name],N''SpaceUsed'')/NULLIF([df].[size],0))
    , CONVERT(decimal(19,2),CASE WHEN [df].[is_percent_growth]=0 THEN [df].[growth]*8.0/1024.0 END)
    , [df].[is_percent_growth]
FROM [sys].[database_files] AS [df] WITH (NOLOCK)
ORDER BY [df].[file_id];';
            EXEC [sys].[sp_executesql] @Sql;
        END;

        SELECT @RowCount=COUNT_BIG(*) FROM [#CurrentTempDB_Sessions];
        SET @HasMoreRows=CONVERT(bit,CASE WHEN @Limit<9223372036854775807 AND @RowCount>@Limit THEN 1 ELSE 0 END);
        IF @EvidenceIsPartial=1 AND @StatusCode='AVAILABLE' SET @StatusCode='AVAILABLE_LIMITED';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();
        SET @ErrorMessage=ERROR_MESSAGE();
        SET @StatusCode=CASE WHEN @ErrorNumber IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                             WHEN @ErrorNumber=1222 THEN 'TIMEOUT'
                             WHEN @ParentCurrentStateSnapshotId IS NOT NULL
                              AND @ErrorNumber IN (208,51020) THEN 'INVALID_PARENT_SNAPSHOT'
                             ELSE 'ERROR_HANDLED' END;
        SET @EvidenceIsPartial=1;
        INSERT [#CurrentTempDB_Warnings] VALUES(@StatusCode,@ErrorNumber,@ErrorMessage);
    END CATCH;

    IF @PrintMeldungen=1 AND @StatusCode<>'AVAILABLE'
    BEGIN
        DECLARE @Message nvarchar(2048)=FORMATMESSAGE
        (
            N'WARNUNG USP_CurrentTempDB [%s]: %s',
            @StatusCode,
            COALESCE(@ErrorMessage,N'Teilergebnis oder eingeschränkte Sicht.')
        );
        RAISERROR(N'%s',10,1,@Message) WITH NOWAIT;
    END;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @Meta nvarchar(max)=
        (
            SELECT
                  N'CurrentTempDB' AS [resultName]
                , 3 AS [schemaVersion]
                , @Now AS [generatedAtUtc]
                , @EvidenceSnapshotStartedAtUtc AS [evidenceSnapshotStartedAtUtc]
                , @EvidenceSnapshotId AS [evidenceSnapshotId]
                , @StatusCode AS [statusCode]
                , CONVERT(bit,CASE WHEN @StatusCode='AVAILABLE' THEN 0 ELSE 1 END) AS [isPartial]
                , @ProductMajorVersion AS [productMajorVersion]
                , @MaxZeilen AS [requestedMaxRows]
                , CASE WHEN @RowCount>@Limit THEN @Limit ELSE @RowCount END AS [returnedRows]
                , @HasMoreRows AS [hasMoreRows]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES
        );
        DECLARE @SessionsJson nvarchar(max)=
        (
            SELECT TOP (@Limit) *
            FROM [#CurrentTempDB_Sessions]
            ORDER BY [TotalNetMb] DESC,[SessionId]
            FOR JSON PATH,INCLUDE_NULL_VALUES
        );
        DECLARE @FilesJson nvarchar(max)=
        (
            SELECT *
            FROM [#CurrentTempDB_Files]
            ORDER BY [FileId]
            FOR JSON PATH,INCLUDE_NULL_VALUES
        );
        DECLARE @GovernanceJson nvarchar(max)=
        (
            SELECT *
            FROM [#CurrentTempDB_TempdbGovernance]
            ORDER BY [GroupId]
            FOR JSON PATH,INCLUDE_NULL_VALUES
        );
        DECLARE @WarningsJson nvarchar(max)=
        (
            SELECT *
            FROM [#CurrentTempDB_Warnings]
            ORDER BY [StatusCode],[ErrorNumber]
            FOR JSON PATH,INCLUDE_NULL_VALUES
        );
        SET @Json=CONCAT
        (
              N'{"meta":',COALESCE(@Meta,N'{}')
            , N',"sessions":',COALESCE(@SessionsJson,N'[]')
            , N',"tempdbFiles":',COALESCE(@FilesJson,N'[]')
            , N',"tempdbGovernance":',COALESCE(@GovernanceJson,N'[]')
            , N',"warnings":',COALESCE(@WarningsJson,N'[]')
            , N'}'
        );
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT
              N'USP_CurrentTempDB' AS [ModuleName]
            , @Now AS [CollectionTimeUtc]
            , @EvidenceSnapshotStartedAtUtc AS [EvidenceSnapshotStartedAtUtc]
            , @EvidenceSnapshotId AS [EvidenceSnapshotId]
            , @StatusCode AS [StatusCode]
            , CONVERT(bit,CASE WHEN @StatusCode='AVAILABLE' THEN 0 ELSE 1 END) AS [IsPartial]
            , CASE WHEN @RowCount>@Limit THEN @Limit ELSE @RowCount END AS [ReturnedRowCount]
            , @HasMoreRows AS [HasMoreRows]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage];

        SELECT TOP (@Limit) *
        FROM [#CurrentTempDB_Sessions]
        ORDER BY [TotalNetMb] DESC,[SessionId];

        IF @MitDateien=1
            SELECT * FROM [#CurrentTempDB_Files] ORDER BY [FileId];

        SELECT * FROM [#CurrentTempDB_TempdbGovernance] ORDER BY [GroupId];
        SELECT * FROM [#CurrentTempDB_Warnings] ORDER BY [StatusCode],[ErrorNumber];
    END;

    BEGIN TRY
        IF @ConsoleResultRequested=1
        BEGIN
            EXEC [monitor].[InternalEmitConsoleResult]
                  @SourceTable=N'#CurrentTempDB_Sessions'
                , @ResultLabel=N'Aktuelle TempDB-Nutzung'
                , @EmptyMessage=N'Keine aktive TempDB-Nutzung';
            IF @MitDateien=1
                EXEC [monitor].[InternalEmitConsoleResult]
                      @SourceTable=N'#CurrentTempDB_Files'
                    , @ResultLabel=N'TempDB-Dateien'
                    , @EmptyMessage=N'Keine sichtbaren TempDB-Dateien';
            EXEC [monitor].[InternalEmitConsoleResult]
                  @SourceTable=N'#CurrentTempDB_TempdbGovernance'
                , @ResultLabel=N'TempDB Resource Governance'
                , @EmptyMessage=N'Keine TempDB-Governance-Evidenz';
        END;

        IF @TableResultRequested=1
        BEGIN
            DECLARE @TableTarget sysname;
            SELECT @TableTarget=[TargetTable] FROM [#CurrentTempDB_ResultTableMap] WHERE [ResultName]=N'sessions';
            IF @TableTarget IS NOT NULL
                EXEC [monitor].[InternalWriteResultTable]
                      @SourceTable=N'#CurrentTempDB_Sessions'
                    , @TargetTable=@TableTarget
                    , @ThrowOnError=1;

            SET @TableTarget=NULL;
            SELECT @TableTarget=[TargetTable] FROM [#CurrentTempDB_ResultTableMap] WHERE [ResultName]=N'tempdbGovernance';
            IF @TableTarget IS NOT NULL
                EXEC [monitor].[InternalWriteResultTable]
                      @SourceTable=N'#CurrentTempDB_TempdbGovernance'
                    , @TargetTable=@TableTarget
                    , @ThrowOnError=1;
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
