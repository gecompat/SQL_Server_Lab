USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CurrentWaits
Version      : 4.0.0
Stand        : 2026-07-23
Zweck        : Liefert aktuelle Waiting Tasks sowie kumulativen oder
               gesampelten instanzweiten Wait-Kontext mit Listen- und
               Patternfiltern.
Ausgabe      : RAW, CONSOLE, NONE und optionales JSON mit currentTasks,
               instanceWaits und warnings.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CurrentWaits]
      @SessionIds                    nvarchar(max)  = NULL
    , @MinWaitMs                    bigint         = 0
    , @WaitTypes                    nvarchar(max)  = NULL
    , @WaitTypePattern              nvarchar(4000) = NULL
    , @WaitGroups                   nvarchar(max)  = NULL
    , @WaitGroupPattern             nvarchar(4000) = NULL
    , @SystemSessionsEinbeziehen    bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit       = 0
    , @MitSqlText                   bit            = 1
    , @MaxSqlTextZeichen            int            = 2000
    , @SampleSeconds                tinyint        = 0
    , @UnkritischeWaitsEinbeziehen  bit            = 0
    , @TopWaitPercentage            decimal(5,2)   = 95.00
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json=NULL;
    DECLARE @ModuleName sysname=N'USP_CurrentWaits',@CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),@MeasurementStartUtc datetime2(3)=NULL,@MeasurementEndUtc datetime2(3)=NULL;
    DECLARE @StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0,@TaskRowCount bigint=0,@InstanceRowCount bigint=0,@ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL,@Detail nvarchar(2000)=NULL,@DeltaStatus varchar(40)=CASE WHEN @SampleSeconds=0 THEN 'CUMULATIVE_CONTEXT' ELSE 'SKIPPED' END,@DeltaDetail nvarchar(2000)=NULL;
    DECLARE @RequiredPermission nvarchar(256)=CASE WHEN TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END;
    DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'currentTasks',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) WHEN @MaxZeilen>0 THEN CONVERT(bigint,@MaxZeilen) ELSE CONVERT(bigint,0) END;
    DECLARE @CandidateMaxZeilen bigint,@MonitorPrintMessage nvarchar(2048),@StartBefore datetime,@StartAfter datetime;
    DECLARE @EvidenceSnapshotId uniqueidentifier=COALESCE(@ParentCurrentStateSnapshotId,NEWID());
    DECLARE @EvidenceSnapshotStartedAtUtc datetime2(3)=@CollectionTimeUtc;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_CurrentWaits';
        PRINT N'@SessionIds, @WaitTypes und @WaitGroups akzeptieren bracket-aware Pipe-Listen.';
        PRINT N'@ToolHintergrundabfragenEinbeziehen=0 blendet erkannte Object-Explorer-, Copilot- und SQL-Prompt-Waiting-Tasks standardmäßig aus; 1 zeigt sie samt Klassifikation.';
        PRINT N'@WaitTypePattern/@WaitGroupPattern: LIKE (Default/like:), regex: oder regexi:; Liste und Pattern sind gegenseitig exklusiv.';
        PRINT N'@SampleSeconds=0 liefert kumulative Instanzwerte; 1..60 liefert ein Delta.';
        PRINT N'@MaxZeilen positiv begrenzt; NULL/0 unbegrenzt. @ResultSetArt CONSOLE (Default), RAW, TABLE oder NONE; optional @Json OUTPUT.';
        RETURN;
    END;

    CREATE TABLE [#CurrentWaits_SessionIdFilter]([SessionId] smallint NOT NULL PRIMARY KEY);
    CREATE TABLE [#CurrentWaits_WaitTypeFilter]([WaitType] nvarchar(120) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY);
    CREATE TABLE [#CurrentWaits_WaitGroupFilter]([WaitGroup] nvarchar(64) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY);
    DECLARE @WaitTypeMode varchar(8),@WaitTypeValue nvarchar(4000),@WaitTypeFlags varchar(8),@WaitTypeValid bit;
    DECLARE @WaitGroupMode varchar(8),@WaitGroupValue nvarchar(4000),@WaitGroupFlags varchar(8),@WaitGroupValid bit;
    SELECT @WaitTypeMode=[PatternMode],@WaitTypeValue=[PatternValue],@WaitTypeFlags=[RegexFlags],@WaitTypeValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@WaitTypePattern);
    SELECT @WaitGroupMode=[PatternMode],@WaitGroupValue=[PatternValue],@WaitGroupFlags=[RegexFlags],@WaitGroupValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@WaitGroupPattern);

    IF @SessionIds IS NOT NULL
    BEGIN
        IF EXISTS(SELECT 1 FROM [monitor].[TVF_ParseBigintList](@SessionIds) WHERE [IsValid]=0 OR [NumberValue] NOT BETWEEN 1 AND 32767) SET @StatusCode='INVALID_PARAMETER';
        ELSE INSERT [#CurrentWaits_SessionIdFilter] SELECT CONVERT(smallint,[NumberValue]) FROM [monitor].[TVF_ParseBigintList](@SessionIds) GROUP BY [NumberValue];
    END;
    IF @StatusCode='AVAILABLE' AND ((@WaitTypes IS NOT NULL AND @WaitTypePattern IS NOT NULL) OR (@WaitGroups IS NOT NULL AND @WaitGroupPattern IS NOT NULL) OR @WaitTypeValid=0 OR @WaitGroupValid=0) SET @StatusCode='INVALID_PARAMETER';
    IF @StatusCode='AVAILABLE' AND ((@WaitTypes IS NOT NULL AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseStringList](@WaitTypes) WHERE [IsValid]=0 OR LEN([StringValue])>120)) OR (@WaitGroups IS NOT NULL AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseStringList](@WaitGroups) WHERE [IsValid]=0 OR LEN([StringValue])>64))) SET @StatusCode='INVALID_PARAMETER';
    IF @StatusCode='AVAILABLE'
    BEGIN
        INSERT [#CurrentWaits_WaitTypeFilter] SELECT CONVERT(nvarchar(120),[StringValue]) FROM [monitor].[TVF_ParseStringList](@WaitTypes) WHERE [IsValid]=1 GROUP BY [StringValue];
        INSERT [#CurrentWaits_WaitGroupFilter] SELECT CONVERT(nvarchar(64),[StringValue]) FROM [monitor].[TVF_ParseStringList](@WaitGroups) WHERE [IsValid]=1 GROUP BY [StringValue];
    END;
    DECLARE @HasRegex bit=CASE WHEN @WaitTypeMode IN('REGEX','REGEXI') OR @WaitGroupMode IN('REGEX','REGEXI') THEN 1 ELSE 0 END;
    IF @StatusCode='AVAILABLE' AND @HasRegex=1 AND (TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<17 OR (SELECT [compatibility_level] FROM [master].[sys].[databases] WITH(NOLOCK) WHERE [database_id]=DB_ID())<170) BEGIN SET @StatusCode='UNAVAILABLE_FEATURE';SET @ErrorMessage=N'Regex benötigt SQL Server 2025 und Compatibility Level 170.';END;
    IF @StatusCode='AVAILABLE' AND (@MinWaitMs<0 OR @SampleSeconds>60 OR @TopWaitPercentage<=0 OR @TopWaitPercentage>100 OR @MaxZeilen<0 OR @MaxSqlTextZeichen<0 OR @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') OR @ToolHintergrundabfragenEinbeziehen IS NULL OR @ToolHintergrundabfragenEinbeziehen NOT IN(0,1)) SET @StatusCode='INVALID_PARAMETER';
    IF @StatusCode='INVALID_PARAMETER' SET @ErrorMessage=COALESCE(@ErrorMessage,N'Ungültige Liste, Kombination, Pattern- oder Steuerangabe.');

    CREATE TABLE [#CurrentWaits_Tasks]
    (
        [SessionId] smallint NULL,[ExecContextId] int NULL,[WaitDurationMs] bigint NULL,[WaitType] nvarchar(120) NULL,[BlockingSessionId] smallint NULL,[ResourceDescription] nvarchar(3072) NULL,[SessionStatus] nvarchar(30) NULL,[RequestStatus] nvarchar(30) NULL,[LoginName] nvarchar(128) NULL,[HostName] nvarchar(128) NULL,[ProgramName] nvarchar(128) NULL,[IsToolBackgroundQuery] bit NOT NULL,[ToolBackgroundRuleCode] varchar(64) NULL,[ToolBackgroundCategory] varchar(40) NULL,[ToolBackgroundDetection] varchar(40) NULL,[ToolBackgroundConfidence] varchar(16) NULL,[DatabaseId] smallint NULL,[Command] nvarchar(32) NULL,[CurrentStatementCharacters] bigint NULL,[CurrentStatementBytes] bigint NULL,[CurrentStatementIsTruncated] bit NOT NULL DEFAULT(0),[CurrentStatement] nvarchar(max) NULL,[WaitGroup] nvarchar(64) NULL,[WaitSeverity] tinyint NULL,[IsGenerallyBenign] bit NULL,[WaitMeaning] nvarchar(1000) NULL,[WaitTypicalOccurrence] nvarchar(1200) NULL,[HighWaitImpact] nvarchar(1200) NULL,[RecommendedChecks] nvarchar(1500) NULL,[WaitHelpUrl] nvarchar(500) NULL,[DescriptionSource] varchar(40) NULL,[DescriptionQuality] varchar(40) NULL,[CatalogMatchType] varchar(20) NULL
    );
    CREATE TABLE [#CurrentWaits_A]([WaitType] nvarchar(120) PRIMARY KEY,[WaitingTasksCount] bigint,[WaitTimeMs] bigint,[SignalWaitTimeMs] bigint);
    CREATE TABLE [#CurrentWaits_B]([WaitType] nvarchar(120) PRIMARY KEY,[WaitingTasksCount] bigint,[WaitTimeMs] bigint,[SignalWaitTimeMs] bigint);
    CREATE TABLE [#CurrentWaits_RawInstance]([WaitType] nvarchar(120) NOT NULL,[WaitingTasksCount] bigint NULL,[WaitTimeMs] bigint NULL,[SignalWaitTimeMs] bigint NULL,[ResourceWaitTimeMs] bigint NULL,[SampleSeconds] int NULL,[MeasurementType] varchar(30) NOT NULL);
    CREATE TABLE [#CurrentWaits_Instance]
    (
        [WaitType] nvarchar(120) NOT NULL,[WaitingTasksCount] bigint NULL,[WaitTimeMs] bigint NULL,[SignalWaitTimeMs] bigint NULL,[ResourceWaitTimeMs] bigint NULL,[SampleSeconds] int NULL,[MeasurementType] varchar(30) NOT NULL,[WaitGroup] nvarchar(64) NULL,[WaitSeverity] tinyint NULL,[IsGenerallyBenign] bit NULL,[WaitMeaning] nvarchar(1000) NULL,[WaitTypicalOccurrence] nvarchar(1200) NULL,[HighWaitImpact] nvarchar(1200) NULL,[RecommendedChecks] nvarchar(1500) NULL,[WaitHelpUrl] nvarchar(500) NULL,[DescriptionSource] varchar(40) NULL,[DescriptionQuality] varchar(40) NULL,[CatalogMatchType] varchar(20) NULL,[WaitPercentage] decimal(9,4) NULL,[CumulativePercentage] decimal(9,4) NULL,[AverageWaitMs] decimal(19,4) NULL,[AverageResourceWaitMs] decimal(19,4) NULL,[AverageSignalWaitMs] decimal(19,4) NULL
    );
    CREATE TABLE [#CurrentWaits_Warnings]([WarningCode] varchar(40) NOT NULL,[WarningMessage] nvarchar(2048) NOT NULL);
    CREATE TABLE [#CurrentWaits_SourceWaitingTasks]
    (
          [waiting_task_address] varbinary(8) NOT NULL
        , [session_id] smallint NULL
        , [exec_context_id] int NULL
        , [wait_duration_ms] bigint NOT NULL
        , [wait_type] nvarchar(60) NOT NULL
        , [blocking_session_id] smallint NULL
        , [resource_description] nvarchar(3072) NULL
    );
    CREATE TABLE [#CurrentWaits_SourceSessions]
    (
          [session_id] smallint NOT NULL PRIMARY KEY
        , [is_user_process] bit NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [login_name] nvarchar(128) NOT NULL
        , [host_name] nvarchar(128) NULL
        , [program_name] nvarchar(128) NULL
    );
    CREATE TABLE [#CurrentWaits_SourceRequests]
    (
          [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [database_id] smallint NOT NULL
        , [command] nvarchar(32) NOT NULL
        , [sql_handle] varbinary(64) NULL
        , [statement_start_offset] int NULL
        , [statement_end_offset] int NULL
        , PRIMARY KEY([session_id],[request_id])
    );
    CREATE TABLE [#CurrentWaits_SourceSqlText]
    (
          [SqlHandle] varbinary(64) NOT NULL PRIMARY KEY
        , [Text] nvarchar(max) NULL
    );
    SET @CandidateMaxZeilen=CASE WHEN @HasRegex=1 OR @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen)+1 END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        BEGIN TRY
            IF @ParentCurrentStateSnapshotId IS NOT NULL
            BEGIN
                EXEC [sys].[sp_executesql] N'
                    DECLARE @Probe int;
                    SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Context] WHERE 1=0;
                    SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus] WHERE 1=0;
                    SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_WaitingTasks] WHERE 1=0;
                    SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Sessions] WHERE 1=0;
                    SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Requests] WHERE 1=0;
                    SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SqlText] WHERE 1=0;';

                IF NOT EXISTS
                (
                    SELECT 1
                    FROM [#CurrentOverview_CurrentStateSnapshot_Context]
                    WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                      AND [OwnerSessionId]=CONVERT(smallint,@@SPID)
                      AND [ContractVersion]=2
                )
                    THROW 51020,N'Die Parent-Snapshot-ID gehört nicht zum aktuellen Aufruf.',1;

                INSERT [#CurrentWaits_SourceWaitingTasks]
                SELECT
                      [waiting_task_address],[session_id],[exec_context_id],[wait_duration_ms]
                    , [wait_type],[blocking_session_id],[resource_description]
                FROM [#CurrentOverview_CurrentStateSnapshot_WaitingTasks]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentWaits_SourceSessions]
                SELECT [session_id],[is_user_process],[status],[login_name],[host_name],[program_name]
                FROM [#CurrentOverview_CurrentStateSnapshot_Sessions]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentWaits_SourceRequests]
                SELECT
                      [session_id],[request_id],[status],[database_id],[command],[sql_handle]
                    , [statement_start_offset],[statement_end_offset]
                FROM [#CurrentOverview_CurrentStateSnapshot_Requests]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                IF @MitSqlText=1
                    INSERT [#CurrentWaits_SourceSqlText]
                    SELECT [SqlHandle],[Text]
                    FROM [#CurrentOverview_CurrentStateSnapshot_SqlText]
                    WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                SELECT
                      @EvidenceSnapshotStartedAtUtc=MIN([CapturedAtUtc])
                    , @IsPartial=CONVERT(bit,MAX(CONVERT(int,[IsPartial])))
                FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                  AND [SourceCode] IN ('WAITING_TASKS','SESSIONS','REQUESTS','SQL_TEXT');
            END
            ELSE
            BEGIN
                SET @EvidenceSnapshotStartedAtUtc=SYSUTCDATETIME();
                INSERT [#CurrentWaits_SourceWaitingTasks]
                SELECT
                      [waiting_task_address],[session_id],[exec_context_id],[wait_duration_ms]
                    , [wait_type],[blocking_session_id],[resource_description]
                FROM [sys].[dm_os_waiting_tasks] WITH (NOLOCK);

                INSERT [#CurrentWaits_SourceSessions]
                SELECT [session_id],[is_user_process],[status],[login_name],[host_name],[program_name]
                FROM [sys].[dm_exec_sessions] WITH (NOLOCK);

                INSERT [#CurrentWaits_SourceRequests]
                SELECT
                      [session_id],[request_id],[status],[database_id],[command],[sql_handle]
                    , [statement_start_offset],[statement_end_offset]
                FROM [sys].[dm_exec_requests] WITH (NOLOCK);

                IF @MitSqlText=1
                    INSERT [#CurrentWaits_SourceSqlText]
                    SELECT [h].[SqlHandle],[t].[text]
                    FROM
                    (
                        SELECT [sql_handle] AS [SqlHandle]
                        FROM [#CurrentWaits_SourceRequests]
                        WHERE [sql_handle] IS NOT NULL
                        GROUP BY [sql_handle]
                    ) AS [h]
                    OUTER APPLY [sys].[dm_exec_sql_text]([h].[SqlHandle]) AS [t];
            END;
        END TRY
        BEGIN CATCH
            SET @ErrorNumber=ERROR_NUMBER();
            SET @ErrorMessage=ERROR_MESSAGE();
            SET @IsPartial=1;
            SET @StatusCode=CASE
                WHEN @ErrorNumber=1222 THEN 'TIMEOUT'
                WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                WHEN @ParentCurrentStateSnapshotId IS NOT NULL
                 AND @ErrorNumber IN(208,51020) THEN 'INVALID_PARENT_SNAPSHOT'
                ELSE 'ERROR_HANDLED' END;
            INSERT [#CurrentWaits_Warnings] VALUES(@StatusCode,@ErrorMessage);
        END CATCH;

        BEGIN TRY
            INSERT [#CurrentWaits_Tasks]
            SELECT TOP(@CandidateMaxZeilen) [w].[session_id],[w].[exec_context_id],[w].[wait_duration_ms],[w].[wait_type],NULLIF([w].[blocking_session_id],0),[w].[resource_description],[s].[status],[r].[status],[s].[login_name],[s].[host_name],[s].[program_name],[tool].[IsToolBackgroundQuery],[tool].[ToolBackgroundRuleCode],[tool].[ToolBackgroundCategory],[tool].[ToolBackgroundDetection],[tool].[ToolBackgroundConfidence],[r].[database_id],[r].[command],NULL,NULL,CONVERT(bit,0),CASE WHEN @MitSqlText=1 THEN [st].[StatementText] END,[wi].[WaitGroup],[wi].[Severity],[wi].[IsGenerallyBenign],[wi].[Meaning],[wi].[TypicalOccurrence],[wi].[HighWaitImpact],[wi].[RecommendedChecks],[wi].[HelpUrl],[wi].[DescriptionSource],[wi].[DescriptionQuality],[wi].[CatalogMatchType]
            FROM [#CurrentWaits_SourceWaitingTasks] AS [w]
            LEFT JOIN [#CurrentWaits_SourceSessions] AS [s] ON [s].[session_id]=[w].[session_id]
            LEFT JOIN [#CurrentWaits_SourceRequests] AS [r] ON [r].[session_id]=[w].[session_id]
            CROSS APPLY [monitor].[TVF_ToolBackgroundQueryInfo]([s].[program_name]) AS [tool]
            LEFT JOIN [#CurrentWaits_SourceSqlText] AS [t]
              ON [t].[SqlHandle]=CASE WHEN @MitSqlText=1 THEN [r].[sql_handle] END
            OUTER APPLY [monitor].[TVF_StatementText]([t].[Text],[r].[statement_start_offset],[r].[statement_end_offset]) AS [st]
            CROSS APPLY [monitor].[TVF_WaitTypeInfo]([w].[wait_type]) AS [wi]
            WHERE (NOT EXISTS(SELECT 1 FROM [#CurrentWaits_SessionIdFilter]) OR EXISTS(SELECT 1 FROM [#CurrentWaits_SessionIdFilter] AS [f] WHERE [f].[SessionId]=[w].[session_id]))
              AND [w].[wait_duration_ms]>=@MinWaitMs AND (@SystemSessionsEinbeziehen=1 OR COALESCE([s].[is_user_process],1)=1)
              AND (@ToolHintergrundabfragenEinbeziehen=1 OR [tool].[IsToolBackgroundQuery]=0)
              AND (NOT EXISTS(SELECT 1 FROM [#CurrentWaits_WaitTypeFilter]) OR EXISTS(SELECT 1 FROM [#CurrentWaits_WaitTypeFilter] AS [f] WHERE [f].[WaitType]=[w].[wait_type] COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (NOT EXISTS(SELECT 1 FROM [#CurrentWaits_WaitGroupFilter]) OR EXISTS(SELECT 1 FROM [#CurrentWaits_WaitGroupFilter] AS [f] WHERE [f].[WaitGroup]=[wi].[WaitGroup] COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (@WaitTypeMode<>'LIKE' OR [w].[wait_type] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @WaitTypeValue COLLATE SQL_Latin1_General_CP1_CS_AS)
              AND (@WaitGroupMode<>'LIKE' OR [wi].[WaitGroup] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @WaitGroupValue COLLATE SQL_Latin1_General_CP1_CS_AS)
            ORDER BY [w].[wait_duration_ms] DESC,[w].[session_id];
            SET @Detail=CASE WHEN @@ROWCOUNT=0 THEN N'Aktuell keine passende wartende Task sichtbar.' ELSE N'Aktuelle Waiting Tasks erfolgreich gelesen.' END;
        END TRY
        BEGIN CATCH
            SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();SET @IsPartial=1;SET @StatusCode=CASE WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN @ErrorNumber=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END;INSERT [#CurrentWaits_Warnings] VALUES(@StatusCode,@ErrorMessage);
        END CATCH;

        IF @SampleSeconds=0
        BEGIN TRY
            SET @MeasurementStartUtc=SYSUTCDATETIME();
            INSERT [#CurrentWaits_RawInstance] SELECT [wait_type],[waiting_tasks_count],[wait_time_ms],[signal_wait_time_ms],[wait_time_ms]-[signal_wait_time_ms],NULL,'INSTANCE_CUMULATIVE' FROM [sys].[dm_os_wait_stats] WITH (NOLOCK) WHERE [waiting_tasks_count]>0;
            SET @MeasurementEndUtc=SYSUTCDATETIME();SET @DeltaStatus='CUMULATIVE_CONTEXT';SET @DeltaDetail=N'Kumulativ seit SQL-Server-Start oder letztem Reset.';
        END TRY BEGIN CATCH SET @DeltaStatus='ERROR_HANDLED';SET @DeltaDetail=ERROR_MESSAGE();SET @IsPartial=1;INSERT [#CurrentWaits_Warnings] VALUES(@DeltaStatus,@DeltaDetail);END CATCH;
        ELSE
        BEGIN TRY
            SET @MeasurementStartUtc=SYSUTCDATETIME();SELECT @StartBefore=[sqlserver_start_time] FROM [sys].[dm_os_sys_info] WITH (NOLOCK);INSERT [#CurrentWaits_A] SELECT [wait_type],[waiting_tasks_count],[wait_time_ms],[signal_wait_time_ms] FROM [sys].[dm_os_wait_stats] WITH (NOLOCK);DECLARE @Delay char(8)=CONVERT(char(8),DATEADD(SECOND,@SampleSeconds,CONVERT(datetime,'19000101',112)),108);WAITFOR DELAY @Delay;SELECT @StartAfter=[sqlserver_start_time] FROM [sys].[dm_os_sys_info] WITH (NOLOCK);INSERT [#CurrentWaits_B] SELECT [wait_type],[waiting_tasks_count],[wait_time_ms],[signal_wait_time_ms] FROM [sys].[dm_os_wait_stats] WITH (NOLOCK);SET @MeasurementEndUtc=SYSUTCDATETIME();
            IF @StartBefore<>@StartAfter OR EXISTS(SELECT 1 FROM [#CurrentWaits_A] AS [a] JOIN [#CurrentWaits_B] AS [b] ON [b].[WaitType]=[a].[WaitType] WHERE [b].[WaitTimeMs]<[a].[WaitTimeMs] OR [b].[WaitingTasksCount]<[a].[WaitingTasksCount] OR [b].[SignalWaitTimeMs]<[a].[SignalWaitTimeMs]) BEGIN SET @DeltaStatus='MEASUREMENT_RESET';SET @DeltaDetail=N'Serverneustart oder Wait-Zählerreset während des Messfensters erkannt.';SET @IsPartial=1;INSERT [#CurrentWaits_Warnings] VALUES(@DeltaStatus,@DeltaDetail);END
            ELSE BEGIN INSERT [#CurrentWaits_RawInstance] SELECT [b].[WaitType],[b].[WaitingTasksCount]-COALESCE([a].[WaitingTasksCount],0),[b].[WaitTimeMs]-COALESCE([a].[WaitTimeMs],0),[b].[SignalWaitTimeMs]-COALESCE([a].[SignalWaitTimeMs],0),([b].[WaitTimeMs]-COALESCE([a].[WaitTimeMs],0))-([b].[SignalWaitTimeMs]-COALESCE([a].[SignalWaitTimeMs],0)),@SampleSeconds,'INSTANCE_DELTA' FROM [#CurrentWaits_B] AS [b] LEFT JOIN [#CurrentWaits_A] AS [a] ON [a].[WaitType]=[b].[WaitType] WHERE [b].[WaitTimeMs]-COALESCE([a].[WaitTimeMs],0)>0;SET @DeltaStatus='AVAILABLE';SET @DeltaDetail=CONCAT(N'Gültiges Wait-Delta über ',@SampleSeconds,N' Sekunden.');END;
        END TRY BEGIN CATCH SET @DeltaStatus='ERROR_HANDLED';SET @DeltaDetail=ERROR_MESSAGE();SET @IsPartial=1;INSERT [#CurrentWaits_Warnings] VALUES(@DeltaStatus,@DeltaDetail);END CATCH;

        INSERT [#CurrentWaits_Instance]
        SELECT [x].[WaitType],[x].[WaitingTasksCount],[x].[WaitTimeMs],[x].[SignalWaitTimeMs],[x].[ResourceWaitTimeMs],[x].[SampleSeconds],[x].[MeasurementType],[wi].[WaitGroup],[wi].[Severity],[wi].[IsGenerallyBenign],[wi].[Meaning],[wi].[TypicalOccurrence],[wi].[HighWaitImpact],[wi].[RecommendedChecks],[wi].[HelpUrl],[wi].[DescriptionSource],[wi].[DescriptionQuality],[wi].[CatalogMatchType],CONVERT(decimal(9,4),100.0*[x].[WaitTimeMs]/NULLIF(SUM([x].[WaitTimeMs]) OVER(),0)),NULL,CONVERT(decimal(19,4),1.0*[x].[WaitTimeMs]/NULLIF([x].[WaitingTasksCount],0)),CONVERT(decimal(19,4),1.0*[x].[ResourceWaitTimeMs]/NULLIF([x].[WaitingTasksCount],0)),CONVERT(decimal(19,4),1.0*[x].[SignalWaitTimeMs]/NULLIF([x].[WaitingTasksCount],0))
        FROM [#CurrentWaits_RawInstance] AS [x] CROSS APPLY [monitor].[TVF_WaitTypeInfo]([x].[WaitType]) AS [wi]
        WHERE (@UnkritischeWaitsEinbeziehen=1 OR [wi].[IsGenerallyBenign]=0)
          AND (NOT EXISTS(SELECT 1 FROM [#CurrentWaits_WaitTypeFilter]) OR EXISTS(SELECT 1 FROM [#CurrentWaits_WaitTypeFilter] AS [f] WHERE [f].[WaitType]=[x].[WaitType] COLLATE SQL_Latin1_General_CP1_CS_AS))
          AND (NOT EXISTS(SELECT 1 FROM [#CurrentWaits_WaitGroupFilter]) OR EXISTS(SELECT 1 FROM [#CurrentWaits_WaitGroupFilter] AS [f] WHERE [f].[WaitGroup]=[wi].[WaitGroup] COLLATE SQL_Latin1_General_CP1_CS_AS))
          AND (@WaitTypeMode<>'LIKE' OR [x].[WaitType] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @WaitTypeValue COLLATE SQL_Latin1_General_CP1_CS_AS)
          AND (@WaitGroupMode<>'LIKE' OR [wi].[WaitGroup] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @WaitGroupValue COLLATE SQL_Latin1_General_CP1_CS_AS);

        IF @HasRegex=1
        BEGIN
            DECLARE @Sql nvarchar(max)=N'';
            IF @WaitTypeMode IN('REGEX','REGEXI') SET @Sql=N'DELETE FROM [#CurrentWaits_Tasks] WHERE [WaitType] IS NULL OR NOT REGEXP_LIKE([WaitType],@WaitType,@WaitTypeFlags);DELETE FROM [#CurrentWaits_Instance] WHERE NOT REGEXP_LIKE([WaitType],@WaitType,@WaitTypeFlags);';
            IF @WaitGroupMode IN('REGEX','REGEXI') SET @Sql+=N'DELETE FROM [#CurrentWaits_Tasks] WHERE [WaitGroup] IS NULL OR NOT REGEXP_LIKE([WaitGroup],@WaitGroup,@WaitGroupFlags);DELETE FROM [#CurrentWaits_Instance] WHERE [WaitGroup] IS NULL OR NOT REGEXP_LIKE([WaitGroup],@WaitGroup,@WaitGroupFlags);';
            EXEC [sys].[sp_executesql] @Sql,N'@WaitType nvarchar(4000),@WaitTypeFlags varchar(8),@WaitGroup nvarchar(4000),@WaitGroupFlags varchar(8)',@WaitTypeValue,@WaitTypeFlags,@WaitGroupValue,@WaitGroupFlags;
        END;

        ;WITH [C] AS (SELECT [WaitType],CONVERT(decimal(9,4),SUM([WaitPercentage]) OVER(ORDER BY [WaitTimeMs] DESC,[WaitType] ROWS UNBOUNDED PRECEDING)) AS [Cum] FROM [#CurrentWaits_Instance]) UPDATE [i] SET [CumulativePercentage]=[c].[Cum] FROM [#CurrentWaits_Instance] AS [i] JOIN [C] AS [c] ON [c].[WaitType]=[i].[WaitType];
        DELETE FROM [#CurrentWaits_Instance] WHERE [CumulativePercentage]-[WaitPercentage]>=@TopWaitPercentage;
        IF @MaxZeilen IS NOT NULL AND @MaxZeilen>0
        BEGIN
            ;WITH [T] AS (SELECT ROW_NUMBER() OVER(ORDER BY [WaitDurationMs] DESC,[SessionId]) AS [rn],* FROM [#CurrentWaits_Tasks]) DELETE FROM [T] WHERE [rn]>@MaxZeilen;
            ;WITH [I] AS (SELECT ROW_NUMBER() OVER(ORDER BY [WaitTimeMs] DESC,[WaitType]) AS [rn],* FROM [#CurrentWaits_Instance]) DELETE FROM [I] WHERE [rn]>@MaxZeilen;
        END;
        DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentWaits_Tasks',@TextColumn=N'CurrentStatement'
            , @CharactersColumn=N'CurrentStatementCharacters',@BytesColumn=N'CurrentStatementBytes'
            , @IsTruncatedColumn=N'CurrentStatementIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@TruncatedValueCount OUTPUT,@LargestRequiredCharacters=@LargestRequiredCharacters OUTPUT;
        EXEC [monitor].[InternalEmitTruncationWarning]
              @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen'
            , @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters
            , @PrintMeldungen=@PrintMeldungen;
        SELECT @TaskRowCount=COUNT_BIG(*) FROM [#CurrentWaits_Tasks];SELECT @InstanceRowCount=COUNT_BIG(*) FROM [#CurrentWaits_Instance];
        IF @IsPartial=1 AND @StatusCode='AVAILABLE' SET @StatusCode='AVAILABLE_LIMITED';
    END;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE') BEGIN SET @MonitorPrintMessage=FORMATMESSAGE(N'WARNUNG %s: %s',@StatusCode,COALESCE(@ErrorMessage,@DeltaDetail,@Detail,N'eingeschränkte Sicht'));RAISERROR(N'%s',10,1,@MonitorPrintMessage) WITH NOWAIT;END;
    IF @JsonErzeugen=1
    BEGIN
        DECLARE @Meta nvarchar(max)=(SELECT @ModuleName AS [resultName],3 AS [schemaVersion],@CollectionTimeUtc AS [generatedAtUtc],@EvidenceSnapshotStartedAtUtc AS [evidenceSnapshotStartedAtUtc],@EvidenceSnapshotId AS [evidenceSnapshotId],@MeasurementStartUtc AS [measurementStartUtc],@MeasurementEndUtc AS [measurementEndUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@DeltaStatus AS [measurementStatusCode],@TaskRowCount AS [currentTaskRows],@InstanceRowCount AS [instanceWaitRows],@ToolHintergrundabfragenEinbeziehen AS [toolBackgroundQueriesIncluded] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@Tasks nvarchar(max)=(SELECT * FROM [#CurrentWaits_Tasks] ORDER BY [WaitDurationMs] DESC,[SessionId] FOR JSON PATH,INCLUDE_NULL_VALUES),@Instance nvarchar(max)=(SELECT * FROM [#CurrentWaits_Instance] ORDER BY [WaitTimeMs] DESC,[WaitType] FOR JSON PATH,INCLUDE_NULL_VALUES),@Warnings nvarchar(max)=(SELECT [WarningCode] AS [code],[WarningMessage] AS [message] FROM [#CurrentWaits_Warnings] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"currentTasks":',COALESCE(@Tasks,N'[]'),N',"instanceWaits":',COALESCE(@Instance,N'[]'),N',"warnings":',COALESCE(@Warnings,N'[]'),N'}');
    END;
    IF @ResultSetArtNormalisiert='RAW'
    BEGIN
        SELECT N'2.0' AS [ContractVersion],@ModuleName AS [ModuleName],@CollectionTimeUtc AS [CollectionTimeUtc],@EvidenceSnapshotStartedAtUtc AS [EvidenceSnapshotStartedAtUtc],@EvidenceSnapshotId AS [EvidenceSnapshotId],@MeasurementStartUtc AS [MeasurementStartUtc],@MeasurementEndUtc AS [MeasurementEndUtc],@StatusCode AS [StatusCode],@IsPartial AS [IsPartial],@TaskRowCount AS [CurrentTaskRowCount],@InstanceRowCount AS [InstanceWaitRowCount],@RequiredPermission AS [RequiredPermission],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],@Detail AS [Detail],@DeltaStatus AS [DeltaStatusCode],@DeltaDetail AS [DeltaDetail],@StartBefore AS [ServerStartTimeBefore],@StartAfter AS [ServerStartTimeAfter];
        SELECT * FROM [#CurrentWaits_Tasks] ORDER BY [WaitDurationMs] DESC,[SessionId];SELECT * FROM [#CurrentWaits_Instance] ORDER BY [WaitTimeMs] DESC,[WaitType];SELECT * FROM [#CurrentWaits_Warnings] ORDER BY [WarningCode];
    END
    ELSE IF @ResultSetArtNormalisiert='CONSOLE'
    BEGIN
        SELECT N'Wait-Analyse' AS [Ergebnis],@StatusCode AS [Status],@DeltaStatus AS [Messstatus],@TaskRowCount AS [Aktuelle_Tasks],@InstanceRowCount AS [Instanz_Waits],@DeltaDetail AS [Messhinweis],@ErrorMessage AS [Fehler];
        SELECT N'Aktuelle wartende Task' AS [Ergebnis],[SessionId] AS [Session],[ExecContextId] AS [Exec_Context],[LoginName] AS [Login],[HostName] AS [Host],[ProgramName] AS [Programm],[Command] AS [Befehl],[WaitType] AS [Wait],CONCAT(CONVERT(varchar(40),[WaitDurationMs]),N' ms') AS [Wartezeit],[BlockingSessionId] AS [Blockiert_durch],[WaitGroup] AS [Wait_Gruppe],[WaitMeaning] AS [Bedeutung],[CurrentStatement] AS [Aktuelles_Statement] FROM [#CurrentWaits_Tasks] ORDER BY [WaitDurationMs] DESC,[SessionId];
        SELECT N'Instanzweite Wait-Messung' AS [Ergebnis],[WaitType] AS [Wait],[WaitGroup] AS [Wait_Gruppe],[MeasurementType] AS [Messart],[WaitingTasksCount] AS [Tasks],CONCAT(CONVERT(varchar(40),[WaitTimeMs]),N' ms') AS [Wartezeit],CONCAT(CONVERT(varchar(40),[WaitPercentage]),N' %') AS [Anteil],CONCAT(CONVERT(varchar(40),[AverageWaitMs]),N' ms') AS [Durchschnitt],[WaitMeaning] AS [Bedeutung],[RecommendedChecks] AS [Empfohlene_Pruefung] FROM [#CurrentWaits_Instance] ORDER BY [WaitTimeMs] DESC,[WaitType];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CurrentWaits_Tasks'
            , @ResultLabel=N'Aktuelle Waits'
            , @EmptyMessage=N'Keine aktiven Waits';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#CurrentWaits_Tasks'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
