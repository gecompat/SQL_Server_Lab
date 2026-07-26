USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CurrentBlocking
Version      : 3.0.0
Stand        : 2026-07-23
Typ          : Stored Procedure
Zweck        : Ermittelt aktuelle Blocking-Ketten, löst deren Ressourcen
               begrenzt auf Datenbank-, Objekt-, Index-, Partitions- und
               Seitenkontext auf und liefert optional die zugehörigen Locks.
SQL-Version  : SQL Server 2019 oder neuer.
Parameter    : @SessionIds = NULL oder z. B. N'57|61'; @MaxZeilen > 0
               begrenzt, NULL/0 ist unbegrenzt. @ResultSetArt akzeptiert
               RAW, CONSOLE, TABLE oder NONE case-insensitiv. JSON wird als Envelope
               mit blockingChains, locks und warnings geliefert.
Berechtigung : VIEW SERVER STATE bis SQL Server 2019 beziehungsweise
               VIEW SERVER PERFORMANCE STATE ab SQL Server 2022. Lockdetails
               benötigen zusätzlich die freigegebene Analyseklasse LOCKS_DEEP.
Eigenlast    : Standard gering. Ressourcen werden dedupliziert und nur bis
               @MaxObjektAufloesungen einzeln mit LOCK_TIMEOUT 0 aufgelöst.
               sys.dm_tran_locks wird nur bei expliziter Anforderung und nur
               für beteiligte Sessions gelesen.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CurrentBlocking]
      @SessionIds                 nvarchar(max)  = NULL
    , @MinWaitMs                  bigint         = 0
    , @SystemSessionsEinbeziehen  bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit     = 0
    , @MitSqlText                 bit            = 1
    , @MaxSqlTextZeichen          int            = 3000
    , @BlockingObjektTiefe        varchar(16)    = 'STANDARD'
    , @MaxObjektAufloesungen      int            = 100
    , @MitLockDetails             bit            = 0
    , @HighImpactConfirmed        bit            = 0
    , @MaxZeilen                  int            = 1000
    , @ResultSetArt               varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen               bit             = 0
    , @Json                       nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen             bit             = 1
    , @Hilfe                      bit             = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @BlockingObjektTiefeNormalisiert varchar(16) =
        UPPER(LTRIM(RTRIM(COALESCE(@BlockingObjektTiefe, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'blockingChains',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807)
             WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen)
             ELSE CONVERT(bigint, 0) END;
    DECLARE @CandidateRows bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807)
             WHEN @MaxZeilen < 2147483647 THEN CONVERT(bigint, @MaxZeilen) + 1
             ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CurrentBlocking';
        PRINT N'@SessionIds: exakte Session-IDs als Pipe-Liste, z. B. N''57|61''; NULL = keine Einschränkung.';
        PRINT N'@ToolHintergrundabfragenEinbeziehen=0 blendet Ketten mit erkanntem Tool-Hintergrundrequest als Blatt standardmäßig aus; 1 zeigt sie. Ein Tool-Blocker einer normalen Abfrage bleibt immer in deren Kette sichtbar.';
        PRINT N'@BlockingObjektTiefe: NONE, STANDARD oder DEEP. DEEP aktiviert zusätzlich Lockdetails und benötigt LOCKS_DEEP plus @HighImpactConfirmed=1.';
        PRINT N'@MaxObjektAufloesungen begrenzt Katalog- und Page-Auflösungen auf 1 bis 1000 Kandidaten.';
        PRINT N'Jede Namens-/Objektanreicherung läuft einzeln mit LOCK_TIMEOUT 0; ein Timeout betrifft nur diesen Kandidaten.';
        PRINT N'@MitLockDetails=1 aktiviert die gruppengeschützte LOCKS_DEEP-Auswertung.';
        PRINT N'@MaxZeilen: positive Werte begrenzen; NULL/0 = unbegrenzt; negative Werte sind ungültig.';
        PRINT N'@ResultSetArt: CONSOLE (Default), RAW, TABLE oder NONE; Groß-/Kleinschreibung wird ignoriert.';
        PRINT N'@JsonErzeugen=1 liefert blockingChains, locks und warnings in @Json OUTPUT.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @RequiredPermission nvarchar(256) =
        CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
             THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END;
    DECLARE @LockStatusCode varchar(40) = 'SKIPPED';
    DECLARE @ObjectResolutionStatusCode varchar(40) =
        CASE WHEN @BlockingObjektTiefeNormalisiert <> 'NONE' THEN 'AVAILABLE' ELSE 'SKIPPED' END;
    DECLARE @MainCandidateCount bigint = 0;
    DECLARE @LockCandidateCount bigint = 0;
    DECLARE @ObjectResolutionCandidateCount bigint = 0;
    DECLARE @ObjectResolutionTotalCount bigint = 0;
    DECLARE @ObjectResolutionHasMoreRows bit = 0;
    DECLARE @ObjectResolutionResolvedCount bigint = 0;
    DECLARE @ObjectResolutionPartialCount bigint = 0;
    DECLARE @ObjectResolutionRawOnlyCount bigint = 0;
    DECLARE @ObjectResolutionTimeoutCount bigint = 0;
    DECLARE @ObjectResolutionDeniedCount bigint = 0;
    DECLARE @ObjectResolutionErrorCount bigint = 0;
    DECLARE @ObjectResolutionSkippedLimitCount bigint = 0;
    DECLARE @HasMoreRows bit = 0;
    DECLARE @Message nvarchar(2048);
    DECLARE @EvidenceSnapshotId uniqueidentifier=COALESCE(@ParentCurrentStateSnapshotId,NEWID());
    DECLARE @EvidenceSnapshotStartedAtUtc datetime2(3)=@CollectionTimeUtc;

    CREATE TABLE [#CurrentBlocking_SessionFilter]
    (
        [SessionId] smallint NOT NULL PRIMARY KEY
    );

    CREATE TABLE [#CurrentBlocking_Edges]
    (
          [BlockedSessionId]  smallint      NOT NULL
        , [BlockingSessionId] smallint      NOT NULL
        , [WaitType]          nvarchar(120) NULL
        , [WaitTimeMs]        bigint        NULL
        , [WaitResource]      nvarchar(3072) NULL
        , [SourceCode]        varchar(24)   NOT NULL
        , PRIMARY KEY ([BlockedSessionId], [BlockingSessionId])
    );

    CREATE TABLE [#CurrentBlocking_BlockingChains]
    (
          [LeafSessionId]         smallint       NOT NULL
        , [BlockedSessionId]      smallint       NOT NULL
        , [BlockingSessionId]     smallint       NOT NULL
        , [RootBlockingSessionId] smallint       NULL
        , [BlockingOwnerType]     varchar(40)    NULL
        , [BlockingOwnerDescription] nvarchar(512) NULL
        , [BlockingChain]          nvarchar(4000) NULL
        , [ChainDepth]            int            NOT NULL
        , [IsCycle]               bit            NOT NULL
        , [WaitType]              nvarchar(120)  NULL
        , [WaitTimeMs]            bigint         NULL
        , [WaitResource]          nvarchar(3072) NULL
        , [BlockingResourceType]             nvarchar(60)   NULL
        , [BlockingResourceDatabaseId]       int            NULL
        , [BlockingResourceDatabaseName]     sysname        NULL
        , [BlockingResourceSchemaName]       sysname        NULL
        , [BlockingResourceObjectId]         int            NULL
        , [BlockingResourceObjectName]       sysname        NULL
        , [BlockingResourceIndexId]          int            NULL
        , [BlockingResourceIndexName]        sysname        NULL
        , [BlockingResourcePartitionId]      bigint         NULL
        , [BlockingResourcePartitionNumber]  int            NULL
        , [BlockingResourceFileId]           int            NULL
        , [BlockingResourcePageId]           bigint         NULL
        , [BlockingResourceRowId]            int            NULL
        , [BlockingResourceMetadataSubtype]  nvarchar(60)   NULL
        , [BlockingResourceMetadataName]     sysname        NULL
        , [BlockingResourcePageTypeDesc]     nvarchar(60)   NULL
        , [BlockingResourceName]             nvarchar(1024) NULL
        , [BlockingResourceResolutionStatus] varchar(40)    NULL
        , [BlockedLoginName]      nvarchar(128)  NULL
        , [BlockedHostName]       nvarchar(128)  NULL
        , [BlockedProgramName]    nvarchar(128)  NULL
        , [BlockedIsToolBackgroundQuery] bit      NOT NULL
        , [BlockedToolBackgroundRuleCode] varchar(64) NULL
        , [BlockedToolBackgroundCategory] varchar(40) NULL
        , [BlockedToolBackgroundDetection] varchar(40) NULL
        , [BlockedToolBackgroundConfidence] varchar(16) NULL
        , [BlockerLoginName]      nvarchar(128)  NULL
        , [BlockerHostName]       nvarchar(128)  NULL
        , [BlockerProgramName]    nvarchar(128)  NULL
        , [RootBlockerLoginName]  nvarchar(128)  NULL
        , [RootBlockerHostName]   nvarchar(128)  NULL
        , [RootBlockerProgramName] nvarchar(128) NULL
        , [RootBlockerSessionStatus] nvarchar(30) NULL
        , [RootBlockerRequestStatus] nvarchar(30) NULL
        , [RootBlockerOpenTransactionCount] int NULL
        , [RootBlockerLastRequestStartTime] datetime NULL
        , [RootBlockerLastRequestEndTime] datetime NULL
        , [RootIsToolBackgroundQuery] bit NOT NULL
        , [RootToolBackgroundRuleCode] varchar(64) NULL
        , [RootToolBackgroundCategory] varchar(40) NULL
        , [RootToolBackgroundDetection] varchar(40) NULL
        , [RootToolBackgroundConfidence] varchar(16) NULL
        , [BlockedStatementCharacters] bigint NULL
        , [BlockedStatementBytes] bigint NULL
        , [BlockedStatementIsTruncated] bit NOT NULL DEFAULT(0)
        , [BlockedStatement]      nvarchar(max)  NULL
        , [BlockerStatementCharacters] bigint NULL
        , [BlockerStatementBytes] bigint NULL
        , [BlockerStatementIsTruncated] bit NOT NULL DEFAULT(0)
        , [BlockerStatement]      nvarchar(max)  NULL
        , [RootBlockerStatementSource] varchar(32) NULL
        , [RootBlockerStatementCharacters] bigint NULL
        , [RootBlockerStatementBytes] bigint NULL
        , [RootBlockerStatementIsTruncated] bit NOT NULL DEFAULT(0)
        , [RootBlockerStatement]  nvarchar(max)  NULL
    );

    CREATE TABLE [#CurrentBlocking_RetainedSessions]
    (
        [SessionId] smallint NOT NULL PRIMARY KEY
    );

    CREATE TABLE [#CurrentBlocking_Locks]
    (
          [SessionId]             smallint       NULL
        , [ResourceType]          nvarchar(60)   NULL
        , [ResourceDatabaseId]    int            NULL
        , [ResourceDatabaseName]  sysname        NULL
        , [ResourceDescription]   nvarchar(256)  NULL
        , [ResourceSubtype]       nvarchar(60)   NULL
        , [ResourceAssociatedEntityId] bigint    NULL
        , [ResourceLockPartition] int            NULL
        , [RequestMode]           nvarchar(60)   NULL
        , [RequestStatus]         nvarchar(60)   NULL
        , [RequestOwnerType]      nvarchar(60)   NULL
        , [RequestReferenceCount] smallint       NULL
        , [LockOwnerAddress]      varbinary(8)   NULL
        , [ResolvedResourceType]  nvarchar(60)   NULL
        , [ResolvedSchemaName]    sysname        NULL
        , [ResolvedObjectId]      int            NULL
        , [ResolvedObjectName]    sysname        NULL
        , [ResolvedIndexId]       int            NULL
        , [ResolvedIndexName]     sysname        NULL
        , [ResolvedPartitionId]   bigint         NULL
        , [ResolvedPartitionNumber] int          NULL
        , [ResolvedResourceName]  nvarchar(1024) NULL
        , [ResourceResolutionStatus] varchar(40) NULL
    );

    CREATE TABLE [#CurrentBlocking_ResourceResolution]
    (
          [CandidateId]       int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [SourceCode]        varchar(24)       NOT NULL
        , [WaitResource]      nvarchar(3072)    NULL
        , [ResourceType]      nvarchar(60)      NULL
        , [FormatCode]        varchar(40)       NOT NULL
        , [DatabaseId]        int               NULL
        , [DatabaseName]      sysname           NULL
        , [EntityId]          bigint            NULL
        , [SubEntityId]       bigint            NULL
        , [FileId]            int               NULL
        , [FileName]          sysname           NULL
        , [PageId]            bigint            NULL
        , [RowId]             int               NULL
        , [MetadataSubtype]   nvarchar(60)      NULL
        , [MetadataName]      sysname           NULL
        , [ResourceQualifier] nvarchar(512)     NULL
        , [SchemaName]        sysname           NULL
        , [ObjectId]          int               NULL
        , [ObjectName]        sysname           NULL
        , [IndexId]           int               NULL
        , [IndexName]         sysname           NULL
        , [PartitionId]       bigint            NULL
        , [PartitionNumber]   int               NULL
        , [PageTypeDesc]      nvarchar(60)      NULL
        , [ResourceName]      nvarchar(1024)    NULL
        , [ResolutionStatus]  varchar(40)       NOT NULL
    );

    CREATE TABLE [#CurrentBlocking_Warnings]
    (
          [ScopeName]    nvarchar(128)  NULL
        , [StatusCode]   varchar(40)    NOT NULL
        , [ErrorNumber]  int            NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#CurrentBlocking_SourceSessions]
    (
          [session_id] smallint NOT NULL PRIMARY KEY
        , [is_user_process] bit NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [login_name] nvarchar(128) NOT NULL
        , [host_name] nvarchar(128) NULL
        , [program_name] nvarchar(128) NULL
        , [open_transaction_count] int NOT NULL
        , [last_request_start_time] datetime NOT NULL
        , [last_request_end_time] datetime NULL
    );
    CREATE TABLE [#CurrentBlocking_SourceRequests]
    (
          [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [blocking_session_id] smallint NULL
        , [wait_type] nvarchar(60) NULL
        , [wait_time] int NOT NULL
        , [wait_resource] nvarchar(256) NOT NULL
        , [sql_handle] varbinary(64) NULL
        , [statement_start_offset] int NULL
        , [statement_end_offset] int NULL
        , PRIMARY KEY([session_id],[request_id])
    );
    CREATE TABLE [#CurrentBlocking_SourceWaitingTasks]
    (
          [session_id] smallint NULL
        , [wait_duration_ms] bigint NOT NULL
        , [wait_type] nvarchar(60) NOT NULL
        , [blocking_session_id] smallint NULL
        , [resource_description] nvarchar(3072) NULL
    );
    CREATE TABLE [#CurrentBlocking_SourceConnections]
    (
          [session_id] int NULL
        , [connection_id] uniqueidentifier NOT NULL PRIMARY KEY
        , [most_recent_sql_handle] varbinary(64) NULL
        , [connect_time] datetime NOT NULL
    );
    CREATE INDEX [IX_CurrentBlocking_SourceConnections_Session]
        ON [#CurrentBlocking_SourceConnections]([session_id]);
    CREATE TABLE [#CurrentBlocking_SourceSqlText]
    (
          [SqlHandle] varbinary(64) NOT NULL PRIMARY KEY
        , [Text] nvarchar(max) NULL
    );

    IF @SessionIds IS NOT NULL
    BEGIN
        IF EXISTS
        (
            SELECT 1
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid] = 0 OR [NumberValue] NOT BETWEEN 0 AND 32767
        )
        OR EXISTS
        (
            SELECT [NumberValue]
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid] = 1
            GROUP BY [NumberValue]
            HAVING COUNT(*) > 1
        )
        BEGIN
            SET @StatusCode = 'INVALID_PARAMETER';
            SET @ErrorMessage = N'@SessionIds enthält ungültige, doppelte oder außerhalb des smallint-Bereichs liegende Werte.';
        END;
        ELSE
        BEGIN
            INSERT [#CurrentBlocking_SessionFilter]([SessionId])
            SELECT CONVERT(smallint, [NumberValue])
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid] = 1;
        END;
    END;

    IF @StatusCode = 'AVAILABLE'
       AND
       (
           COALESCE(@MinWaitMs, -1) < 0
           OR @MaxZeilen < 0
           OR @MaxSqlTextZeichen < 0
           OR @BlockingObjektTiefeNormalisiert NOT IN ('NONE', 'STANDARD', 'DEEP')
           OR @MaxObjektAufloesungen IS NULL
           OR @MaxObjektAufloesungen NOT BETWEEN 1 AND 1000
           OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
           OR @SystemSessionsEinbeziehen IS NULL
           OR @ToolHintergrundabfragenEinbeziehen IS NULL
           OR @ToolHintergrundabfragenEinbeziehen NOT IN (0,1)
           OR @MitSqlText IS NULL
           OR @MitLockDetails IS NULL
           OR @HighImpactConfirmed IS NULL
           OR @JsonErzeugen IS NULL
           OR @PrintMeldungen IS NULL
       )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Mindestens ein Parameter besitzt einen ungültigen Wert.';
    END;

    IF @StatusCode = 'AVAILABLE' AND @BlockingObjektTiefeNormalisiert = 'DEEP'
        SET @MitLockDetails = 1;

    IF @StatusCode = 'AVAILABLE'
       AND @MitLockDetails=1
        EXEC [monitor].[InternalCheckAnalysisPath]
              @AnalysisClass='LOCKS_DEEP'
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT;

    IF @StatusCode = 'AVAILABLE'
    BEGIN TRY
        IF @ParentCurrentStateSnapshotId IS NOT NULL
        BEGIN
            EXEC [sys].[sp_executesql] N'
                DECLARE @Probe int;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Context] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Sessions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Requests] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_WaitingTasks] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Connections] WHERE 1=0;
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

            INSERT [#CurrentBlocking_SourceSessions]
            SELECT
                  [session_id],[is_user_process],[status],[login_name],[host_name],[program_name]
                , [open_transaction_count],[last_request_start_time],[last_request_end_time]
            FROM [#CurrentOverview_CurrentStateSnapshot_Sessions]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentBlocking_SourceRequests]
            SELECT
                  [session_id],[request_id],[status],[blocking_session_id],[wait_type]
                , [wait_time],[wait_resource],[sql_handle]
                , [statement_start_offset],[statement_end_offset]
            FROM [#CurrentOverview_CurrentStateSnapshot_Requests]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentBlocking_SourceWaitingTasks]
            SELECT
                  [session_id],[wait_duration_ms],[wait_type]
                , [blocking_session_id],[resource_description]
            FROM [#CurrentOverview_CurrentStateSnapshot_WaitingTasks]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentBlocking_SourceConnections]
            SELECT [session_id],[connection_id],[most_recent_sql_handle],[connect_time]
            FROM [#CurrentOverview_CurrentStateSnapshot_Connections]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            IF @MitSqlText=1
                INSERT [#CurrentBlocking_SourceSqlText]
                SELECT [SqlHandle],[Text]
                FROM [#CurrentOverview_CurrentStateSnapshot_SqlText]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            SELECT
                  @EvidenceSnapshotStartedAtUtc=MIN([CapturedAtUtc])
                , @IsPartial=CONVERT(bit,MAX(CONVERT(int,[IsPartial])))
            FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
              AND [SourceCode] IN
                  ('SESSIONS','REQUESTS','WAITING_TASKS','CONNECTIONS','SQL_TEXT');
        END
        ELSE
        BEGIN
            SET @EvidenceSnapshotStartedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentBlocking_SourceSessions]
            SELECT
                  [session_id],[is_user_process],[status],[login_name],[host_name],[program_name]
                , [open_transaction_count],[last_request_start_time],[last_request_end_time]
            FROM [sys].[dm_exec_sessions] WITH (NOLOCK);

            INSERT [#CurrentBlocking_SourceRequests]
            SELECT
                  [session_id],[request_id],[status],[blocking_session_id],[wait_type]
                , [wait_time],[wait_resource],[sql_handle]
                , [statement_start_offset],[statement_end_offset]
            FROM [sys].[dm_exec_requests] WITH (NOLOCK);

            INSERT [#CurrentBlocking_SourceWaitingTasks]
            SELECT
                  [session_id],[wait_duration_ms],[wait_type]
                , [blocking_session_id],[resource_description]
            FROM [sys].[dm_os_waiting_tasks] WITH (NOLOCK);

            INSERT [#CurrentBlocking_SourceConnections]
            SELECT [session_id],[connection_id],[most_recent_sql_handle],[connect_time]
            FROM [sys].[dm_exec_connections] WITH (NOLOCK);

            IF @MitSqlText=1
                INSERT [#CurrentBlocking_SourceSqlText]
                SELECT [h].[SqlHandle],[t].[text]
                FROM
                (
                    SELECT [sql_handle] AS [SqlHandle]
                    FROM [#CurrentBlocking_SourceRequests]
                    WHERE [sql_handle] IS NOT NULL
                    UNION
                    SELECT [most_recent_sql_handle]
                    FROM [#CurrentBlocking_SourceConnections]
                    WHERE [most_recent_sql_handle] IS NOT NULL
                ) AS [h]
                OUTER APPLY [sys].[dm_exec_sql_text]([h].[SqlHandle]) AS [t];
        END;

        INSERT [#CurrentBlocking_Edges]
        (
              [BlockedSessionId], [BlockingSessionId], [WaitType]
            , [WaitTimeMs], [WaitResource], [SourceCode]
        )
        SELECT
              [r].[session_id]
            , [r].[blocking_session_id]
            , MAX([r].[wait_type])
            , MAX(CONVERT(bigint, [r].[wait_time]))
            , MAX(CONVERT(nvarchar(3072), [r].[wait_resource]))
            , 'REQUEST'
        FROM [#CurrentBlocking_SourceRequests] AS [r]
        INNER JOIN [#CurrentBlocking_SourceSessions] AS [s]
          ON [s].[session_id] = [r].[session_id]
        WHERE [r].[blocking_session_id] <> 0
          AND [r].[blocking_session_id] <> [r].[session_id]
          AND (@SystemSessionsEinbeziehen = 1 OR [s].[is_user_process] = 1)
          AND COALESCE([r].[wait_time], 0) >= @MinWaitMs
        GROUP BY [r].[session_id], [r].[blocking_session_id];

        INSERT [#CurrentBlocking_Edges]
        (
              [BlockedSessionId], [BlockingSessionId], [WaitType]
            , [WaitTimeMs], [WaitResource], [SourceCode]
        )
        SELECT
              [w].[session_id]
            , [w].[blocking_session_id]
            , MAX([w].[wait_type])
            , MAX(CONVERT(bigint, [w].[wait_duration_ms]))
            , MAX(CONVERT(nvarchar(3072), [w].[resource_description]))
            , 'WAITING_TASK'
        FROM [#CurrentBlocking_SourceWaitingTasks] AS [w]
        LEFT JOIN [#CurrentBlocking_SourceSessions] AS [s]
          ON [s].[session_id] = [w].[session_id]
        WHERE [w].[blocking_session_id] <> 0
          AND [w].[blocking_session_id] <> [w].[session_id]
          AND COALESCE([w].[wait_duration_ms], 0) >= @MinWaitMs
          AND (@SystemSessionsEinbeziehen = 1 OR COALESCE([s].[is_user_process], 1) = 1)
          AND NOT EXISTS
              (
                  SELECT 1
                  FROM [#CurrentBlocking_Edges] AS [e]
                  WHERE [e].[BlockedSessionId] = [w].[session_id]
                    AND [e].[BlockingSessionId] = [w].[blocking_session_id]
              )
        GROUP BY [w].[session_id], [w].[blocking_session_id];

        ;WITH [Chain] AS
        (
            SELECT
                  [e].[BlockedSessionId] AS [LeafSessionId]
                , [e].[BlockedSessionId]
                , [e].[BlockingSessionId]
                , 1 AS [ChainDepth]
                , CONVERT(varchar(4000), CONCAT('|', [e].[BlockedSessionId], '|', [e].[BlockingSessionId], '|')) AS [Path]
                , CONVERT(nvarchar(4000), CONCAT([e].[BlockedSessionId], N' <- ', [e].[BlockingSessionId])) AS [BlockingChain]
                , CONVERT(bit, 0) AS [IsCycle]
            FROM [#CurrentBlocking_Edges] AS [e]

            UNION ALL

            SELECT
                  [c].[LeafSessionId]
                , [e].[BlockedSessionId]
                , [e].[BlockingSessionId]
                , [c].[ChainDepth] + 1
                , CONVERT(varchar(4000), CONCAT([c].[Path], [e].[BlockingSessionId], '|'))
                , CONVERT(nvarchar(4000), CONCAT([c].[BlockingChain], N' <- ', [e].[BlockingSessionId]))
                , CONVERT
                  (
                      bit,
                      CASE WHEN [c].[Path] LIKE CONCAT('%|', [e].[BlockingSessionId], '|%')
                           THEN 1 ELSE 0 END
                  )
            FROM [Chain] AS [c]
            INNER JOIN [#CurrentBlocking_Edges] AS [e]
              ON [e].[BlockedSessionId] = [c].[BlockingSessionId]
            WHERE [c].[ChainDepth] < 32
              AND [c].[IsCycle] = 0
        ),
        [Root] AS
        (
            SELECT
                  [c].*
                , ROW_NUMBER() OVER
                  (
                      PARTITION BY [c].[LeafSessionId]
                      ORDER BY [c].[ChainDepth] DESC, [c].[Path]
                  ) AS [RowNumber]
            FROM [Chain] AS [c]
        )
        INSERT [#CurrentBlocking_BlockingChains]
        (
              [LeafSessionId], [BlockedSessionId], [BlockingSessionId]
            , [RootBlockingSessionId], [BlockingOwnerType], [BlockingOwnerDescription]
            , [BlockingChain], [ChainDepth], [IsCycle]
            , [WaitType], [WaitTimeMs], [WaitResource]
            , [BlockedLoginName], [BlockedHostName], [BlockedProgramName]
            , [BlockedIsToolBackgroundQuery], [BlockedToolBackgroundRuleCode]
            , [BlockedToolBackgroundCategory], [BlockedToolBackgroundDetection]
            , [BlockedToolBackgroundConfidence]
            , [BlockerLoginName], [BlockerHostName], [BlockerProgramName]
            , [RootBlockerLoginName], [RootBlockerHostName], [RootBlockerProgramName]
            , [RootBlockerSessionStatus], [RootBlockerRequestStatus]
            , [RootBlockerOpenTransactionCount]
            , [RootBlockerLastRequestStartTime], [RootBlockerLastRequestEndTime]
            , [RootIsToolBackgroundQuery], [RootToolBackgroundRuleCode]
            , [RootToolBackgroundCategory], [RootToolBackgroundDetection]
            , [RootToolBackgroundConfidence]
            , [BlockedStatementCharacters], [BlockedStatementBytes], [BlockedStatementIsTruncated], [BlockedStatement]
            , [BlockerStatementCharacters], [BlockerStatementBytes], [BlockerStatementIsTruncated], [BlockerStatement]
            , [RootBlockerStatementSource]
            , [RootBlockerStatementCharacters], [RootBlockerStatementBytes], [RootBlockerStatementIsTruncated], [RootBlockerStatement]
        )
        SELECT TOP (@CandidateRows)
              [r].[LeafSessionId]
            , [e].[BlockedSessionId]
            , [e].[BlockingSessionId]
            , [r].[BlockingSessionId]
            , CASE [r].[BlockingSessionId]
                  WHEN -2 THEN 'ORPHAN_DTC'
                  WHEN -3 THEN 'DEFERRED_RECOVERY'
                  WHEN -4 THEN 'LATCH_OWNER_TRANSIENT'
                  WHEN -5 THEN 'LATCH_OWNER_UNTRACKED'
                  ELSE 'SESSION' END
            , CASE [r].[BlockingSessionId]
                  WHEN -2 THEN N'Verwaiste verteilte Transaktion ohne zugeordnete Session.'
                  WHEN -3 THEN N'Verzögerte Recovery-Transaktion hält die Ressource.'
                  WHEN -4 THEN N'Der Latch-Besitzer war während der Momentaufnahme nicht bestimmbar.'
                  WHEN -5 THEN N'Der Latch-Besitzer wird für diesen Ressourcentyp nicht verfolgt.'
                  ELSE N'Blockierende SQL-Server-Session.' END
            , [r].[BlockingChain]
            , [r].[ChainDepth]
            , [r].[IsCycle]
            , [e].[WaitType]
            , [e].[WaitTimeMs]
            , [e].[WaitResource]
            , [blockedSession].[login_name]
            , [blockedSession].[host_name]
            , [blockedSession].[program_name]
            , [blockedTool].[IsToolBackgroundQuery]
            , [blockedTool].[ToolBackgroundRuleCode]
            , [blockedTool].[ToolBackgroundCategory]
            , [blockedTool].[ToolBackgroundDetection]
            , [blockedTool].[ToolBackgroundConfidence]
            , [blockerSession].[login_name]
            , [blockerSession].[host_name]
            , [blockerSession].[program_name]
            , [rootSession].[login_name]
            , [rootSession].[host_name]
            , [rootSession].[program_name]
            , [rootSession].[status]
            , [rootRequest].[status]
            , [rootSession].[open_transaction_count]
            , [rootSession].[last_request_start_time]
            , [rootSession].[last_request_end_time]
            , [rootTool].[IsToolBackgroundQuery]
            , [rootTool].[ToolBackgroundRuleCode]
            , [rootTool].[ToolBackgroundCategory]
            , [rootTool].[ToolBackgroundDetection]
            , [rootTool].[ToolBackgroundConfidence]
            , NULL,NULL,CONVERT(bit,0),CASE WHEN @MitSqlText = 1 THEN [blockedStatement].[StatementText] END
            , NULL,NULL,CONVERT(bit,0),CASE WHEN @MitSqlText = 1 THEN [blockerStatement].[StatementText] END
            , CASE
                  WHEN @MitSqlText = 0 THEN 'NOT_REQUESTED'
                  WHEN [rootRequest].[sql_handle] IS NOT NULL THEN 'ACTIVE_REQUEST'
                  WHEN [rootConnection].[most_recent_sql_handle] IS NOT NULL THEN 'MOST_RECENT_CONNECTION'
                  ELSE 'UNAVAILABLE'
              END
            , NULL,NULL,CONVERT(bit,0),CASE WHEN @MitSqlText = 1 THEN [rootStatement].[StatementText] END
        FROM [Root] AS [r]
        INNER JOIN [#CurrentBlocking_Edges] AS [e]
          ON [e].[BlockedSessionId] = [r].[LeafSessionId]
        LEFT JOIN [#CurrentBlocking_SourceSessions] AS [blockedSession]
          ON [blockedSession].[session_id] = [e].[BlockedSessionId]
        LEFT JOIN [#CurrentBlocking_SourceSessions] AS [blockerSession]
          ON [blockerSession].[session_id] = [e].[BlockingSessionId]
        LEFT JOIN [#CurrentBlocking_SourceSessions] AS [rootSession]
          ON [rootSession].[session_id] = [r].[BlockingSessionId]
        OUTER APPLY
        (
            SELECT TOP (1) [request].*
            FROM [#CurrentBlocking_SourceRequests] AS [request]
            WHERE [request].[session_id] = [e].[BlockedSessionId]
            ORDER BY [request].[request_id]
        ) AS [blockedRequest]
        OUTER APPLY
        (
            SELECT TOP (1) [request].*
            FROM [#CurrentBlocking_SourceRequests] AS [request]
            WHERE [request].[session_id] = [e].[BlockingSessionId]
            ORDER BY [request].[request_id]
        ) AS [blockerRequest]
        OUTER APPLY
        (
            SELECT TOP (1) [request].*
            FROM [#CurrentBlocking_SourceRequests] AS [request]
            WHERE [request].[session_id] = [r].[BlockingSessionId]
            ORDER BY [request].[request_id]
        ) AS [rootRequest]
        OUTER APPLY
        (
            SELECT TOP (1) [connection].[most_recent_sql_handle]
            FROM [#CurrentBlocking_SourceConnections] AS [connection]
            WHERE [connection].[session_id] = [r].[BlockingSessionId]
            ORDER BY [connection].[connect_time] DESC
        ) AS [rootConnection]
        CROSS APPLY [monitor].[TVF_ToolBackgroundQueryInfo]([blockedSession].[program_name]) AS [blockedTool]
        CROSS APPLY [monitor].[TVF_ToolBackgroundQueryInfo]([rootSession].[program_name]) AS [rootTool]
        LEFT JOIN [#CurrentBlocking_SourceSqlText] AS [blockedText]
          ON [blockedText].[SqlHandle]=CASE WHEN @MitSqlText=1 THEN [blockedRequest].[sql_handle] END
        OUTER APPLY [monitor].[TVF_StatementText]
        (
              [blockedText].[Text]
            , [blockedRequest].[statement_start_offset]
            , [blockedRequest].[statement_end_offset]
        ) AS [blockedStatement]
        LEFT JOIN [#CurrentBlocking_SourceSqlText] AS [blockerText]
          ON [blockerText].[SqlHandle]=CASE WHEN @MitSqlText=1 THEN [blockerRequest].[sql_handle] END
        OUTER APPLY [monitor].[TVF_StatementText]
        (
              [blockerText].[Text]
            , [blockerRequest].[statement_start_offset]
            , [blockerRequest].[statement_end_offset]
        ) AS [blockerStatement]
        LEFT JOIN [#CurrentBlocking_SourceSqlText] AS [rootText]
          ON [rootText].[SqlHandle]=CASE WHEN @MitSqlText=1
               THEN COALESCE([rootRequest].[sql_handle],[rootConnection].[most_recent_sql_handle]) END
        OUTER APPLY [monitor].[TVF_StatementText]
        (
              [rootText].[Text]
            , CASE WHEN [rootRequest].[sql_handle] IS NOT NULL
                   THEN [rootRequest].[statement_start_offset] END
            , CASE WHEN [rootRequest].[sql_handle] IS NOT NULL
                   THEN [rootRequest].[statement_end_offset] END
        ) AS [rootStatement]
        WHERE [r].[RowNumber] = 1
          AND
          (
              @SessionIds IS NULL
              OR EXISTS
                 (
                     SELECT 1
                     FROM [#CurrentBlocking_SessionFilter] AS [filter]
                     WHERE [r].[Path] LIKE CONCAT('%|', [filter].[SessionId], '|%')
                 )
          )
          AND
          (
              @ToolHintergrundabfragenEinbeziehen = 1
              OR [blockedTool].[IsToolBackgroundQuery] = 0
          )
        ORDER BY [e].[WaitTimeMs] DESC, [e].[BlockedSessionId]
        OPTION (MAXRECURSION 32);

        ;WITH [RetainedChain] AS
        (
            SELECT
                  [e].[BlockedSessionId]
                , [e].[BlockingSessionId]
                , 1 AS [ChainDepth]
                , CONVERT(varchar(4000), CONCAT('|', [e].[BlockedSessionId], '|', [e].[BlockingSessionId], '|')) AS [Path]
            FROM [#CurrentBlocking_Edges] AS [e]
            JOIN [#CurrentBlocking_BlockingChains] AS [retained]
              ON [retained].[LeafSessionId] = [e].[BlockedSessionId]

            UNION ALL

            SELECT
                  [e].[BlockedSessionId]
                , [e].[BlockingSessionId]
                , [chain].[ChainDepth] + 1
                , CONVERT(varchar(4000), CONCAT([chain].[Path], [e].[BlockingSessionId], '|'))
            FROM [RetainedChain] AS [chain]
            JOIN [#CurrentBlocking_Edges] AS [e]
              ON [e].[BlockedSessionId] = [chain].[BlockingSessionId]
            WHERE [chain].[ChainDepth] < 32
              AND [chain].[Path] NOT LIKE CONCAT('%|', [e].[BlockingSessionId], '|%')
        ),
        [RetainedSessions] AS
        (
            SELECT [BlockedSessionId] AS [SessionId]
            FROM [RetainedChain]
            WHERE [BlockedSessionId] > 0
            UNION
            SELECT [BlockingSessionId]
            FROM [RetainedChain]
            WHERE [BlockingSessionId] > 0
        )
        INSERT [#CurrentBlocking_RetainedSessions]([SessionId])
        SELECT [SessionId]
        FROM [RetainedSessions]
        OPTION (MAXRECURSION 32);

        SELECT @MainCandidateCount = COUNT_BIG(*) FROM [#CurrentBlocking_BlockingChains];
        SET @HasMoreRows = CONVERT
        (
            bit,
            CASE WHEN @EffectiveMaxZeilen < 9223372036854775807
                       AND @MainCandidateCount > @EffectiveMaxZeilen
                 THEN 1 ELSE 0 END
        );

        IF @MitLockDetails = 1
        BEGIN
            DECLARE @LockAllowed bit = 1;

            IF @LockAllowed = 0
            BEGIN
                SET @LockStatusCode = 'DENIED_GROUP';
                SET @IsPartial = 1;
                INSERT [#CurrentBlocking_Warnings]([ScopeName], [StatusCode], [ErrorMessage])
                VALUES (N'Locks', 'DENIED_GROUP', N'Die Analyseklasse LOCKS_DEEP ist nicht freigegeben.');
            END;
            ELSE
            BEGIN TRY
                INSERT [#CurrentBlocking_Locks]
                (
                      [SessionId], [ResourceType], [ResourceDatabaseId]
                    , [ResourceDatabaseName], [ResourceDescription], [ResourceSubtype]
                    , [ResourceAssociatedEntityId], [ResourceLockPartition]
                    , [RequestMode], [RequestStatus], [RequestOwnerType]
                    , [RequestReferenceCount], [LockOwnerAddress]
                )
                SELECT TOP (@CandidateRows)
                      CONVERT(smallint, [l].[request_session_id])
                    , [l].[resource_type]
                    , [l].[resource_database_id]
                    , CONVERT(sysname, NULL)
                    , [l].[resource_description]
                    , [l].[resource_subtype]
                    , [l].[resource_associated_entity_id]
                    , [l].[resource_lock_partition]
                    , [l].[request_mode]
                    , [l].[request_status]
                    , [l].[request_owner_type]
                    , [l].[request_reference_count]
                    , [l].[lock_owner_address]
                FROM [sys].[dm_tran_locks] AS [l] WITH (NOLOCK)
                WHERE EXISTS
                      (
                          SELECT 1
                          FROM [#CurrentBlocking_RetainedSessions] AS [retained]
                          WHERE [retained].[SessionId] = [l].[request_session_id]
                      )
                ORDER BY
                      [l].[request_session_id]
                    , [l].[resource_database_id]
                    , [l].[resource_type]
                    , [l].[request_mode];

                SELECT @LockCandidateCount = COUNT_BIG(*) FROM [#CurrentBlocking_Locks];
                SET @LockStatusCode = 'AVAILABLE';
            END TRY
            BEGIN CATCH
                SET @LockStatusCode = CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371, 916)
                                           THEN 'DENIED_PERMISSION'
                                           WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                                           ELSE 'ERROR_HANDLED' END;
                SET @IsPartial = 1;
                INSERT [#CurrentBlocking_Warnings]([ScopeName], [StatusCode], [ErrorNumber], [ErrorMessage])
                VALUES (N'Locks', @LockStatusCode, ERROR_NUMBER(), ERROR_MESSAGE());
            END CATCH;
        END;

        IF @BlockingObjektTiefeNormalisiert <> 'NONE'
        BEGIN
            SELECT @ObjectResolutionTotalCount = COUNT_BIG(*)
            FROM
            (
                SELECT DISTINCT [WaitResource]
                FROM [#CurrentBlocking_BlockingChains]
                WHERE NULLIF(LTRIM(RTRIM([WaitResource])), N'') IS NOT NULL
            ) AS [r];

            IF @MitLockDetails = 1
            BEGIN
                DECLARE @DistinctLockResources bigint;
                SELECT @DistinctLockResources = COUNT_BIG(*)
                FROM
                (
                    SELECT DISTINCT
                          [ResourceType], [ResourceDatabaseId]
                        , [ResourceAssociatedEntityId], [ResourceDescription], [ResourceSubtype]
                    FROM [#CurrentBlocking_Locks]
                ) AS [l];
                SET @ObjectResolutionTotalCount += COALESCE(@DistinctLockResources, 0);
            END;

            ;WITH [ParsedWaitResources] AS
            (
                SELECT
                      [c].[WaitResource]
                    , [p].[ResourceType], [p].[FormatCode], [p].[DatabaseId]
                    , [p].[EntityId], [p].[SubEntityId], [p].[FileId]
                    , [p].[PageId], [p].[RowId], [p].[MetadataSubtype]
                    , [p].[ResourceQualifier], [p].[ParseStatus]
                    , MAX(COALESCE([c].[WaitTimeMs], 0)) OVER
                      (PARTITION BY [c].[WaitResource]) AS [MaximumWaitTimeMs]
                    , ROW_NUMBER() OVER
                      (PARTITION BY [c].[WaitResource] ORDER BY [c].[BlockedSessionId]) AS [DuplicateOrdinal]
                FROM [#CurrentBlocking_BlockingChains] AS [c]
                CROSS APPLY [monitor].[TVF_ParseBlockingResource]([c].[WaitResource]) AS [p]
                WHERE NULLIF(LTRIM(RTRIM([c].[WaitResource])), N'') IS NOT NULL
            )
            INSERT [#CurrentBlocking_ResourceResolution]
            (
                  [SourceCode], [WaitResource], [ResourceType], [FormatCode]
                , [DatabaseId], [EntityId], [SubEntityId], [FileId], [PageId]
                , [RowId], [MetadataSubtype], [ResourceQualifier], [ResolutionStatus]
            )
            SELECT TOP (@MaxObjektAufloesungen)
                  'WAIT_RESOURCE', [p].[WaitResource], [p].[ResourceType], [p].[FormatCode]
                , [p].[DatabaseId], [p].[EntityId], [p].[SubEntityId], [p].[FileId]
                , [p].[PageId], [p].[RowId], [p].[MetadataSubtype]
                , [p].[ResourceQualifier], [p].[ParseStatus]
            FROM [ParsedWaitResources] AS [p]
            WHERE [p].[DuplicateOrdinal] = 1
            ORDER BY [p].[MaximumWaitTimeMs] DESC, [p].[WaitResource];

            SELECT @ObjectResolutionCandidateCount = COUNT_BIG(*)
            FROM [#CurrentBlocking_ResourceResolution];

            IF @MitLockDetails = 1
               AND @ObjectResolutionCandidateCount < @MaxObjektAufloesungen
            BEGIN
                DECLARE @RemainingResolutionRows int =
                    @MaxObjektAufloesungen - CONVERT(int, @ObjectResolutionCandidateCount);

                INSERT [#CurrentBlocking_ResourceResolution]
                (
                      [SourceCode], [WaitResource], [ResourceType], [FormatCode]
                    , [DatabaseId], [EntityId], [MetadataSubtype]
                    , [ResourceQualifier], [ResolutionStatus]
                )
                SELECT TOP (@RemainingResolutionRows)
                      'LOCK_DMV', NULL, UPPER([l].[ResourceType]), 'LOCK_DMV'
                    , [l].[ResourceDatabaseId], [l].[ResourceAssociatedEntityId]
                    , [l].[ResourceSubtype]
                    , [l].[ResourceDescription]
                    , CASE WHEN [l].[ResourceType] IS NULL THEN 'INVALID_FORMAT'
                           ELSE 'PARSED' END
                FROM
                (
                    SELECT DISTINCT
                          [ResourceType], [ResourceDatabaseId]
                        , [ResourceAssociatedEntityId], [ResourceDescription], [ResourceSubtype]
                    FROM [#CurrentBlocking_Locks]
                ) AS [l]
                ORDER BY [l].[ResourceDatabaseId], [l].[ResourceType], [l].[ResourceAssociatedEntityId];

                SELECT @ObjectResolutionCandidateCount = COUNT_BIG(*)
                FROM [#CurrentBlocking_ResourceResolution];
            END;

            UPDATE [r]
            SET
                  [EntityId] = COALESCE([p].[EntityId], [r].[EntityId])
                , [SubEntityId] = COALESCE([p].[SubEntityId], [r].[SubEntityId])
            FROM [#CurrentBlocking_ResourceResolution] AS [r]
            CROSS APPLY [monitor].[TVF_ParseBlockingResource]
            (
                CONCAT
                (
                      N'METADATA: database_id = ', [r].[DatabaseId], N' '
                    , COALESCE([r].[MetadataSubtype], N'OTHER'), N'('
                    , COALESCE([r].[ResourceQualifier], N''), N')'
                )
            ) AS [p]
            WHERE [r].[FormatCode] = 'LOCK_DMV'
              AND [r].[ResourceType] = N'METADATA';

            IF @ObjectResolutionTotalCount > @ObjectResolutionCandidateCount
            BEGIN
                SET @ObjectResolutionHasMoreRows = 1;
                SET @ObjectResolutionStatusCode = 'AVAILABLE_LIMITED';
                SET @IsPartial = 1;
                INSERT [#CurrentBlocking_Warnings]
                ([ScopeName], [StatusCode], [ErrorMessage])
                VALUES
                (
                      N'BlockingResourceResolution'
                    , 'ROW_LIMIT_APPLIED'
                    , CONCAT
                      (
                            N'Die Objektauflösung wurde auf '
                          , CONVERT(nvarchar(20), @MaxObjektAufloesungen)
                          , N' deduplizierte Ressourcen begrenzt; Rohressourcen bleiben vollständig erhalten.'
                      )
                );
            END;

            UPDATE [r]
            SET [FileId] = COALESCE
                           (
                               TRY_CONVERT(int, NULLIF([r].[ResourceQualifier], N'')),
                               TRY_CONVERT(int, [r].[EntityId])
                           )
            FROM [#CurrentBlocking_ResourceResolution] AS [r]
            WHERE [r].[FormatCode] = 'LOCK_DMV'
              AND [r].[ResourceType] = N'FILE';

            UPDATE [r]
            SET
                  [FileId] = TRY_CONVERT
                             (
                                 int,
                                 PARSENAME
                                 (
                                     REPLACE([r].[ResourceQualifier], N':', N'.'),
                                     CASE WHEN LEN([r].[ResourceQualifier]) - LEN(REPLACE([r].[ResourceQualifier], N':', N'')) >= 2
                                          THEN 3 ELSE 2 END
                                 )
                             )
                , [PageId] = TRY_CONVERT
                             (
                                 bigint,
                                 PARSENAME
                                 (
                                     REPLACE([r].[ResourceQualifier], N':', N'.'),
                                     CASE WHEN LEN([r].[ResourceQualifier]) - LEN(REPLACE([r].[ResourceQualifier], N':', N'')) >= 2
                                          THEN 2 ELSE 1 END
                                 )
                             )
                , [RowId] = CASE WHEN [r].[ResourceType] = N'RID'
                                 THEN TRY_CONVERT(int, PARSENAME(REPLACE([r].[ResourceQualifier], N':', N'.'), 1)) END
            FROM [#CurrentBlocking_ResourceResolution] AS [r]
            WHERE [r].[FormatCode] = 'LOCK_DMV'
              AND [r].[ResourceType] IN (N'PAGE', N'RID', N'EXTENT')
              AND [r].[ResourceQualifier] LIKE N'%:%';

            DECLARE @ResolutionCandidateId int;
            DECLARE @ResolutionResourceType nvarchar(60);
            DECLARE @ResolutionFormatCode varchar(40);
            DECLARE @ResolutionDatabaseId int;
            DECLARE @ResolutionDatabaseName sysname;
            DECLARE @ResolutionDatabaseState tinyint;
            DECLARE @ResolutionEntityId bigint;
            DECLARE @ResolutionSubEntityId bigint;
            DECLARE @ResolutionFileId int;
            DECLARE @ResolutionFileName sysname;
            DECLARE @ResolutionPageId bigint;
            DECLARE @ResolutionPageIdInt int;
            DECLARE @ResolutionRowId int;
            DECLARE @ResolutionMetadataSubtype nvarchar(60);
            DECLARE @ResolutionQualifier nvarchar(512);
            DECLARE @ResolutionSchemaName sysname;
            DECLARE @ResolutionObjectId int;
            DECLARE @ResolutionObjectName sysname;
            DECLARE @ResolutionIndexId int;
            DECLARE @ResolutionIndexName sysname;
            DECLARE @ResolutionPartitionId bigint;
            DECLARE @ResolutionPartitionNumber int;
            DECLARE @ResolutionPageTypeDesc nvarchar(60);
            DECLARE @ResolutionMetadataName sysname;
            DECLARE @ResolutionResourceName nvarchar(1024);
            DECLARE @ResolutionSql nvarchar(max);
            DECLARE @ResolutionFirstErrorNumber int;
            DECLARE @ResolutionFirstErrorMessage nvarchar(2048);
            DECLARE @ResolutionFirstErrorScope nvarchar(128);

            -- Der Kern-Snapshot ist vollständig materialisiert. Jeder Kandidat
            -- wird in eigenen Child-Batches angereichert, damit LOCK_TIMEOUT 0
            -- und Fehlerstatus niemals auf den nächsten Kandidaten übergreifen.
            DECLARE [CurrentBlocking_ResolutionCandidateCursor] CURSOR LOCAL FAST_FORWARD FOR
                SELECT
                      [CandidateId], [ResourceType], [FormatCode], [DatabaseId]
                    , [DatabaseName], [EntityId], [SubEntityId], [FileId], [FileName]
                    , [PageId], [RowId], [MetadataSubtype], [ResourceQualifier]
                    , [SchemaName], [ObjectId], [ObjectName], [IndexId], [IndexName]
                    , [PartitionId], [PartitionNumber], [PageTypeDesc], [MetadataName]
                    , [ResourceName]
                FROM [#CurrentBlocking_ResourceResolution]
                ORDER BY [CandidateId];

            OPEN [CurrentBlocking_ResolutionCandidateCursor];
            FETCH NEXT FROM [CurrentBlocking_ResolutionCandidateCursor]
            INTO
                  @ResolutionCandidateId, @ResolutionResourceType, @ResolutionFormatCode
                , @ResolutionDatabaseId, @ResolutionDatabaseName, @ResolutionEntityId
                , @ResolutionSubEntityId, @ResolutionFileId, @ResolutionFileName
                , @ResolutionPageId, @ResolutionRowId, @ResolutionMetadataSubtype
                , @ResolutionQualifier, @ResolutionSchemaName, @ResolutionObjectId
                , @ResolutionObjectName, @ResolutionIndexId, @ResolutionIndexName
                , @ResolutionPartitionId, @ResolutionPartitionNumber
                , @ResolutionPageTypeDesc, @ResolutionMetadataName
                , @ResolutionResourceName;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT
                      @ResolutionDatabaseState = NULL
                    , @ResolutionPageIdInt = TRY_CONVERT(int, @ResolutionPageId)
                    , @ResolutionFirstErrorNumber = NULL
                    , @ResolutionFirstErrorMessage = NULL
                    , @ResolutionFirstErrorScope = NULL;

                IF @ResolutionDatabaseId IS NOT NULL
                BEGIN TRY
                    EXEC [sys].[sp_executesql]
                          N'SET LOCK_TIMEOUT 0;
                            SELECT
                                  @DatabaseName = [d].[name]
                                , @DatabaseState = CONVERT(tinyint, [d].[state])
                            FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
                            WHERE [d].[database_id] = @DatabaseId;'
                        , N'@DatabaseId int, @DatabaseName sysname OUTPUT, @DatabaseState tinyint OUTPUT'
                        , @DatabaseId = @ResolutionDatabaseId
                        , @DatabaseName = @ResolutionDatabaseName OUTPUT
                        , @DatabaseState = @ResolutionDatabaseState OUTPUT;
                END TRY
                BEGIN CATCH
                    IF @ResolutionFirstErrorNumber IS NULL
                    BEGIN
                        SELECT
                              @ResolutionFirstErrorNumber = ERROR_NUMBER()
                            , @ResolutionFirstErrorMessage = ERROR_MESSAGE()
                            , @ResolutionFirstErrorScope = N'DATABASE';
                    END;
                END CATCH;

                IF @ResolutionDatabaseId IS NOT NULL
                   AND @ResolutionFileId IS NOT NULL
                BEGIN TRY
                    EXEC [sys].[sp_executesql]
                          N'SET LOCK_TIMEOUT 0;
                            SELECT @FileName = [f].[name]
                            FROM [master].[sys].[master_files] AS [f] WITH (NOLOCK)
                            WHERE [f].[database_id] = @DatabaseId
                              AND [f].[file_id] = @FileId;'
                        , N'@DatabaseId int, @FileId int, @FileName sysname OUTPUT'
                        , @DatabaseId = @ResolutionDatabaseId
                        , @FileId = @ResolutionFileId
                        , @FileName = @ResolutionFileName OUTPUT;
                END TRY
                BEGIN CATCH
                    IF @ResolutionFirstErrorNumber IS NULL
                    BEGIN
                        SELECT
                              @ResolutionFirstErrorNumber = ERROR_NUMBER()
                            , @ResolutionFirstErrorMessage = ERROR_MESSAGE()
                            , @ResolutionFirstErrorScope = N'FILE';
                    END;
                END CATCH;

                IF @ResolutionFormatCode = 'NAMED_RESOURCE'
                BEGIN TRY
                    EXEC [sys].[sp_executesql]
                          N'SET LOCK_TIMEOUT 0;
                            SELECT TOP (1)
                                  @ResourceType = N''LINKED_SERVER''
                                , @ResourceName = CONCAT(N''Linked Server '', QUOTENAME([s].[name]))
                            FROM [sys].[servers] AS [s] WITH (NOLOCK)
                            WHERE LEFT(@Qualifier, LEN([s].[name])) = [s].[name]
                              AND
                              (
                                  LEN(@Qualifier) = LEN([s].[name])
                                  OR SUBSTRING(@Qualifier, LEN([s].[name]) + 1, 1) IN (N'' '', N''('')
                              )
                            ORDER BY LEN([s].[name]) DESC, [s].[server_id];'
                        , N'@Qualifier nvarchar(512), @ResourceType nvarchar(60) OUTPUT, @ResourceName nvarchar(1024) OUTPUT'
                        , @Qualifier = @ResolutionQualifier
                        , @ResourceType = @ResolutionResourceType OUTPUT
                        , @ResourceName = @ResolutionResourceName OUTPUT;
                END TRY
                BEGIN CATCH
                    IF @ResolutionFirstErrorNumber IS NULL
                    BEGIN
                        SELECT
                              @ResolutionFirstErrorNumber = ERROR_NUMBER()
                            , @ResolutionFirstErrorMessage = ERROR_MESSAGE()
                            , @ResolutionFirstErrorScope = N'LINKED_SERVER';
                    END;
                END CATCH;

                IF @ResolutionResourceType IN (N'PAGE', N'RID', N'EXTENT')
                   AND @ResolutionDatabaseId IS NOT NULL
                   AND @ResolutionFileId IS NOT NULL
                   AND @ResolutionPageId IS NOT NULL
                BEGIN TRY
                    EXEC [sys].[sp_executesql]
                          N'SET LOCK_TIMEOUT 0;
                            SELECT
                                  @ObjectId = [p].[object_id]
                                , @IndexId = [p].[index_id]
                                , @PartitionId = [p].[partition_id]
                                , @PageTypeDesc = [p].[page_type_desc]
                            FROM [sys].[dm_db_page_info]
                            (
                                  @DatabaseId
                                , @FileId
                                , @PageId
                                , ''LIMITED''
                            ) AS [p];'
                        , N'@DatabaseId int, @FileId int, @PageId int,
                            @ObjectId int OUTPUT, @IndexId int OUTPUT,
                            @PartitionId bigint OUTPUT, @PageTypeDesc nvarchar(60) OUTPUT'
                        , @DatabaseId = @ResolutionDatabaseId
                        , @FileId = @ResolutionFileId
                        , @PageId = @ResolutionPageIdInt
                        , @ObjectId = @ResolutionObjectId OUTPUT
                        , @IndexId = @ResolutionIndexId OUTPUT
                        , @PartitionId = @ResolutionPartitionId OUTPUT
                        , @PageTypeDesc = @ResolutionPageTypeDesc OUTPUT;
                END TRY
                BEGIN CATCH
                    IF @ResolutionFirstErrorNumber IS NULL
                    BEGIN
                        SELECT
                              @ResolutionFirstErrorNumber = ERROR_NUMBER()
                            , @ResolutionFirstErrorMessage = ERROR_MESSAGE()
                            , @ResolutionFirstErrorScope = N'PAGE';
                    END;
                END CATCH;

                SET @ResolutionSql = NULL;

                IF @ResolutionDatabaseName IS NOT NULL
                   AND @ResolutionDatabaseState = 0
                BEGIN
                    IF @ResolutionResourceType = N'OBJECT'
                        SET @ResolutionSql = N'
                            SELECT
                                  @SchemaName = [s].[name]
                                , @ObjectId = [o].[object_id]
                                , @ObjectName = [o].[name]
                            FROM ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[objects] AS [o] WITH (NOLOCK)
                            JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[schemas] AS [s] WITH (NOLOCK)
                              ON [s].[schema_id] = [o].[schema_id]
                            WHERE [o].[object_id] = TRY_CONVERT(int, @EntityId);';
                    ELSE IF @ResolutionResourceType IN (N'KEY', N'HOBT', N'OIB', N'XACT')
                            OR
                            (
                                @ResolutionResourceType IN (N'PAGE', N'RID', N'EXTENT')
                                AND @ResolutionObjectId IS NULL
                                AND @ResolutionEntityId IS NOT NULL
                            )
                        SET @ResolutionSql = N'
                            SELECT TOP (1)
                                  @SchemaName = [s].[name]
                                , @ObjectId = [o].[object_id]
                                , @ObjectName = [o].[name]
                                , @IndexId = [i].[index_id]
                                , @IndexName = [i].[name]
                                , @PartitionId = [p].[partition_id]
                                , @PartitionNumber = [p].[partition_number]
                            FROM ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[partitions] AS [p] WITH (NOLOCK)
                            JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[objects] AS [o] WITH (NOLOCK)
                              ON [o].[object_id] = [p].[object_id]
                            JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[schemas] AS [s] WITH (NOLOCK)
                              ON [s].[schema_id] = [o].[schema_id]
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[indexes] AS [i] WITH (NOLOCK)
                              ON [i].[object_id] = [p].[object_id]
                             AND [i].[index_id] = [p].[index_id]
                            WHERE [p].[hobt_id] = @EntityId;';
                    ELSE IF @ResolutionResourceType IN (N'PAGE', N'RID', N'EXTENT')
                            AND @ResolutionObjectId IS NOT NULL
                        SET @ResolutionSql = N'
                            SELECT
                                  @SchemaName = [s].[name]
                                , @ObjectName = [o].[name]
                                , @IndexName = [i].[name]
                                , @PartitionNumber = [p].[partition_number]
                            FROM ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[objects] AS [o] WITH (NOLOCK)
                            JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[schemas] AS [s] WITH (NOLOCK)
                              ON [s].[schema_id] = [o].[schema_id]
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[indexes] AS [i] WITH (NOLOCK)
                              ON [i].[object_id] = @PageObjectId
                             AND [i].[index_id] = @PageIndexId
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[partitions] AS [p] WITH (NOLOCK)
                              ON [p].[partition_id] = @PagePartitionId
                            WHERE [o].[object_id] = @PageObjectId;';
                    ELSE IF @ResolutionResourceType = N'ALLOCATION_UNIT'
                        SET @ResolutionSql = N'
                            SELECT TOP (1)
                                  @SchemaName = [s].[name]
                                , @ObjectId = [o].[object_id]
                                , @ObjectName = [o].[name]
                                , @IndexId = [i].[index_id]
                                , @IndexName = [i].[name]
                                , @PartitionId = [p].[partition_id]
                                , @PartitionNumber = [p].[partition_number]
                            FROM ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[allocation_units] AS [a] WITH (NOLOCK)
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[partitions] AS [p] WITH (NOLOCK)
                              ON [a].[container_id] = CASE WHEN [a].[type] = 2 THEN [p].[partition_id] ELSE [p].[hobt_id] END
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[objects] AS [o] WITH (NOLOCK)
                              ON [o].[object_id] = [p].[object_id]
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[schemas] AS [s] WITH (NOLOCK)
                              ON [s].[schema_id] = [o].[schema_id]
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[indexes] AS [i] WITH (NOLOCK)
                              ON [i].[object_id] = [p].[object_id]
                             AND [i].[index_id] = [p].[index_id]
                            WHERE [a].[allocation_unit_id] = @EntityId;';
                    ELSE IF @ResolutionResourceType = N'METADATA'
                            AND @ResolutionMetadataSubtype = N'STATS'
                        SET @ResolutionSql = N'
                            SELECT
                                  @SchemaName = [s].[name]
                                , @ObjectId = [o].[object_id]
                                , @ObjectName = [o].[name]
                                , @MetadataName = [st].[name]
                            FROM ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[objects] AS [o] WITH (NOLOCK)
                            JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[schemas] AS [s] WITH (NOLOCK)
                              ON [s].[schema_id] = [o].[schema_id]
                            LEFT JOIN ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[stats] AS [st] WITH (NOLOCK)
                              ON [st].[object_id] = [o].[object_id]
                             AND [st].[stats_id] = TRY_CONVERT(int, @SubEntityId)
                            WHERE [o].[object_id] = TRY_CONVERT(int, @EntityId);';
                    ELSE IF @ResolutionResourceType = N'METADATA'
                            AND @ResolutionMetadataSubtype = N'SCHEMA'
                        SET @ResolutionSql = N'
                            SELECT @SchemaName = [s].[name]
                            FROM ' + QUOTENAME(@ResolutionDatabaseName) + N'.[sys].[schemas] AS [s] WITH (NOLOCK)
                            WHERE [s].[schema_id] = TRY_CONVERT(int, @EntityId);';
                END;

                IF @ResolutionSql IS NOT NULL
                BEGIN TRY
                    SET @ResolutionSql = N'SET LOCK_TIMEOUT 0;' + @ResolutionSql;
                    EXEC [sys].[sp_executesql]
                          @ResolutionSql
                        , N'@EntityId bigint, @SubEntityId bigint,
                            @PageObjectId int, @PageIndexId int, @PagePartitionId bigint,
                            @SchemaName sysname OUTPUT, @ObjectId int OUTPUT,
                            @ObjectName sysname OUTPUT, @IndexId int OUTPUT,
                            @IndexName sysname OUTPUT, @PartitionId bigint OUTPUT,
                            @PartitionNumber int OUTPUT, @MetadataName sysname OUTPUT'
                        , @EntityId = @ResolutionEntityId
                        , @SubEntityId = @ResolutionSubEntityId
                        , @PageObjectId = @ResolutionObjectId
                        , @PageIndexId = @ResolutionIndexId
                        , @PagePartitionId = @ResolutionPartitionId
                        , @SchemaName = @ResolutionSchemaName OUTPUT
                        , @ObjectId = @ResolutionObjectId OUTPUT
                        , @ObjectName = @ResolutionObjectName OUTPUT
                        , @IndexId = @ResolutionIndexId OUTPUT
                        , @IndexName = @ResolutionIndexName OUTPUT
                        , @PartitionId = @ResolutionPartitionId OUTPUT
                        , @PartitionNumber = @ResolutionPartitionNumber OUTPUT
                        , @MetadataName = @ResolutionMetadataName OUTPUT;
                END TRY
                BEGIN CATCH
                    IF @ResolutionFirstErrorNumber IS NULL
                    BEGIN
                        SELECT
                              @ResolutionFirstErrorNumber = ERROR_NUMBER()
                            , @ResolutionFirstErrorMessage = ERROR_MESSAGE()
                            , @ResolutionFirstErrorScope = N'CATALOG';
                    END;
                END CATCH;

                UPDATE [r]
                SET
                      [ResourceType] = @ResolutionResourceType
                    , [DatabaseName] = @ResolutionDatabaseName
                    , [FileName] = @ResolutionFileName
                    , [SchemaName] = @ResolutionSchemaName
                    , [ObjectId] = @ResolutionObjectId
                    , [ObjectName] = @ResolutionObjectName
                    , [IndexId] = @ResolutionIndexId
                    , [IndexName] = @ResolutionIndexName
                    , [PartitionId] = @ResolutionPartitionId
                    , [PartitionNumber] = @ResolutionPartitionNumber
                    , [PageTypeDesc] = @ResolutionPageTypeDesc
                    , [MetadataName] = @ResolutionMetadataName
                    , [ResourceName] = @ResolutionResourceName
                    , [ResolutionStatus] =
                        CASE
                            WHEN @ResolutionFirstErrorNumber IS NULL THEN [r].[ResolutionStatus]
                            WHEN @ResolutionFirstErrorNumber IN (229, 262, 297, 300, 371, 916)
                                THEN 'DENIED_PERMISSION'
                            WHEN @ResolutionFirstErrorNumber = 1222 THEN 'TIMEOUT'
                            ELSE 'ERROR_HANDLED'
                        END
                FROM [#CurrentBlocking_ResourceResolution] AS [r]
                WHERE [r].[CandidateId] = @ResolutionCandidateId;

                IF @ResolutionFirstErrorNumber IS NOT NULL
                BEGIN
                    SET @ObjectResolutionStatusCode = 'AVAILABLE_LIMITED';
                    SET @IsPartial = 1;

                    INSERT [#CurrentBlocking_Warnings]
                    ([ScopeName], [StatusCode], [ErrorNumber], [ErrorMessage])
                    VALUES
                    (
                          CONCAT(N'BlockingResource:', @ResolutionCandidateId, N':', @ResolutionFirstErrorScope)
                        , CASE WHEN @ResolutionFirstErrorNumber IN (229, 262, 297, 300, 371, 916)
                               THEN 'DENIED_PERMISSION'
                               WHEN @ResolutionFirstErrorNumber = 1222 THEN 'TIMEOUT'
                               ELSE 'ERROR_HANDLED' END
                        , @ResolutionFirstErrorNumber
                        , @ResolutionFirstErrorMessage
                    );
                END;

                FETCH NEXT FROM [CurrentBlocking_ResolutionCandidateCursor]
                INTO
                      @ResolutionCandidateId, @ResolutionResourceType, @ResolutionFormatCode
                    , @ResolutionDatabaseId, @ResolutionDatabaseName, @ResolutionEntityId
                    , @ResolutionSubEntityId, @ResolutionFileId, @ResolutionFileName
                    , @ResolutionPageId, @ResolutionRowId, @ResolutionMetadataSubtype
                    , @ResolutionQualifier, @ResolutionSchemaName, @ResolutionObjectId
                    , @ResolutionObjectName, @ResolutionIndexId, @ResolutionIndexName
                    , @ResolutionPartitionId, @ResolutionPartitionNumber
                    , @ResolutionPageTypeDesc, @ResolutionMetadataName
                    , @ResolutionResourceName;
            END;

            CLOSE [CurrentBlocking_ResolutionCandidateCursor];
            DEALLOCATE [CurrentBlocking_ResolutionCandidateCursor];

            UPDATE [r]
            SET
                  [ResourceName] =
                    CASE
                        WHEN [r].[ResourceName] IS NOT NULL THEN [r].[ResourceName]
                        WHEN [r].[ResourceType] = N'DATABASE' AND [r].[DatabaseName] IS NOT NULL
                            THEN QUOTENAME([r].[DatabaseName])
                        WHEN [r].[ResourceType] = N'FILE' AND [r].[DatabaseName] IS NOT NULL
                            THEN CONCAT(QUOTENAME([r].[DatabaseName]), N' / FILE ', [r].[FileId],
                                        CASE WHEN [r].[FileName] IS NOT NULL THEN CONCAT(N' ', QUOTENAME([r].[FileName])) ELSE N'' END)
                        WHEN [r].[FormatCode] = 'LOCK_DMV' AND [r].[ResourceType] = N'XACT'
                             AND [r].[ObjectName] IS NOT NULL
                            THEN CONCAT
                                 (
                                      QUOTENAME([r].[DatabaseName]), N'.'
                                    , QUOTENAME([r].[SchemaName]), N'.', QUOTENAME([r].[ObjectName])
                                    , CASE WHEN [r].[IndexName] IS NOT NULL
                                           THEN CONCAT(N' / INDEX ', QUOTENAME([r].[IndexName])) ELSE N'' END
                                    , N' / XACT ', COALESCE([r].[ResourceQualifier], N'')
                                    , N' / underlying HOBT ', [r].[EntityId]
                                 )
                        WHEN [r].[ObjectName] IS NOT NULL
                            THEN CONCAT
                                 (
                                      QUOTENAME([r].[DatabaseName]), N'.'
                                    , QUOTENAME([r].[SchemaName]), N'.', QUOTENAME([r].[ObjectName])
                                    , CASE WHEN [r].[IndexName] IS NOT NULL
                                           THEN CONCAT(N' / INDEX ', QUOTENAME([r].[IndexName])) ELSE N'' END
                                    , CASE WHEN [r].[MetadataName] IS NOT NULL
                                           THEN CONCAT(N' / STATISTICS ', QUOTENAME([r].[MetadataName])) ELSE N'' END
                                    , CASE WHEN [r].[PartitionNumber] IS NOT NULL
                                           THEN CONCAT(N' / PARTITION ', [r].[PartitionNumber]) ELSE N'' END
                                    , CASE WHEN [r].[PageId] IS NOT NULL
                                           THEN CONCAT(N' / PAGE ', [r].[FileId], N':', [r].[PageId]) ELSE N'' END
                                    , CASE WHEN [r].[PageTypeDesc] IS NOT NULL
                                           THEN CONCAT(N' / ', [r].[PageTypeDesc]) ELSE N'' END
                                    , CASE WHEN [r].[RowId] IS NOT NULL
                                           THEN CONCAT(N' / ROW ', [r].[RowId]) ELSE N'' END
                                 )
                        WHEN [r].[ResourceType] = N'METADATA' AND [r].[MetadataSubtype] = N'SCHEMA'
                             AND [r].[SchemaName] IS NOT NULL
                            THEN CONCAT(QUOTENAME([r].[DatabaseName]), N'.', QUOTENAME([r].[SchemaName]), N' / METADATA SCHEMA')
                        WHEN [r].[ResourceType] IN (N'PAGE', N'RID', N'EXTENT') AND [r].[DatabaseName] IS NOT NULL
                            THEN CONCAT
                                 (
                                      QUOTENAME([r].[DatabaseName]), N' / PAGE ', [r].[FileId], N':', [r].[PageId]
                                    , CASE WHEN [r].[PageTypeDesc] IS NOT NULL THEN CONCAT(N' / ', [r].[PageTypeDesc]) ELSE N'' END
                                    , CASE WHEN [r].[RowId] IS NOT NULL THEN CONCAT(N' / ROW ', [r].[RowId]) ELSE N'' END
                                 )
                        WHEN [r].[ResourceType] = N'APPLICATION'
                            THEN CONCAT(COALESCE(QUOTENAME([r].[DatabaseName]) + N' / ', N''), N'APPLICATION ', COALESCE([r].[ResourceQualifier], N''))
                        WHEN [r].[ResourceType] = N'XACT'
                            THEN CONCAT
                                 (
                                      COALESCE(QUOTENAME([r].[DatabaseName]) + N' / ', N'')
                                    , N'XACT ', COALESCE([r].[ResourceQualifier], N'')
                                    , CASE WHEN COALESCE([r].[EntityId], 0) <> 0
                                           THEN CONCAT(N' / underlying HOBT ', [r].[EntityId]) ELSE N'' END
                                 )
                        WHEN [r].[ResourceType] = N'METADATA'
                            THEN CONCAT(COALESCE(QUOTENAME([r].[DatabaseName]) + N' / ', N''), N'METADATA ', COALESCE([r].[MetadataSubtype], N'OTHER'),
                                        CASE WHEN [r].[ResourceQualifier] IS NOT NULL THEN CONCAT(N' / ', [r].[ResourceQualifier]) ELSE N'' END)
                        WHEN [r].[DatabaseName] IS NOT NULL
                            THEN CONCAT(QUOTENAME([r].[DatabaseName]), N' / ', COALESCE([r].[ResourceType], N'RESOURCE'),
                                        CASE WHEN [r].[EntityId] IS NOT NULL THEN CONCAT(N' ', [r].[EntityId]) ELSE N'' END)
                        ELSE [r].[ResourceQualifier]
                    END
                , [ResolutionStatus] =
                    CASE
                        WHEN [r].[ResolutionStatus] IN
                             ('EMPTY', 'INVALID_FORMAT', 'TIMEOUT', 'DENIED_PERMISSION', 'ERROR_HANDLED')
                            THEN [r].[ResolutionStatus]
                        WHEN [r].[ResolutionStatus] = 'RAW_ONLY' AND [r].[ResourceName] IS NULL THEN 'RAW_ONLY'
                        WHEN [r].[ResourceType] = N'LINKED_SERVER' THEN 'RESOLVED'
                        WHEN [r].[ResourceType] IN (N'DATABASE', N'FILE') AND [r].[DatabaseName] IS NOT NULL THEN 'RESOLVED'
                        WHEN [r].[ResourceType] = N'XACT'
                             AND [r].[ResourceQualifier] IS NOT NULL THEN 'PARTIAL'
                        WHEN [r].[ObjectName] IS NOT NULL THEN 'RESOLVED'
                        WHEN [r].[ResourceType] = N'METADATA' AND [r].[MetadataSubtype] = N'SCHEMA'
                             AND [r].[SchemaName] IS NOT NULL THEN 'RESOLVED'
                        WHEN [r].[ResourceType] IN (N'PAGE', N'RID', N'EXTENT') AND [r].[PageTypeDesc] IS NOT NULL THEN 'RESOLVED'
                        WHEN [r].[ResourceType] = N'APPLICATION'
                             AND [r].[ResourceQualifier] IS NOT NULL THEN 'PARTIAL'
                        WHEN [r].[DatabaseName] IS NOT NULL OR [r].[ResourceType] IS NOT NULL THEN 'PARTIAL'
                        ELSE [r].[ResolutionStatus]
                    END
            FROM [#CurrentBlocking_ResourceResolution] AS [r];

            SELECT
                  @ObjectResolutionResolvedCount = COALESCE(SUM(CASE WHEN [ResolutionStatus] = 'RESOLVED' THEN CONVERT(bigint, 1) ELSE 0 END), 0)
                , @ObjectResolutionPartialCount = COALESCE(SUM(CASE WHEN [ResolutionStatus] = 'PARTIAL' THEN CONVERT(bigint, 1) ELSE 0 END), 0)
                , @ObjectResolutionRawOnlyCount = COALESCE(SUM(CASE WHEN [ResolutionStatus] IN ('RAW_ONLY', 'INVALID_FORMAT', 'EMPTY') THEN CONVERT(bigint, 1) ELSE 0 END), 0)
                , @ObjectResolutionTimeoutCount = COALESCE(SUM(CASE WHEN [ResolutionStatus] = 'TIMEOUT' THEN CONVERT(bigint, 1) ELSE 0 END), 0)
                , @ObjectResolutionDeniedCount = COALESCE(SUM(CASE WHEN [ResolutionStatus] = 'DENIED_PERMISSION' THEN CONVERT(bigint, 1) ELSE 0 END), 0)
                , @ObjectResolutionErrorCount = COALESCE(SUM(CASE WHEN [ResolutionStatus] = 'ERROR_HANDLED' THEN CONVERT(bigint, 1) ELSE 0 END), 0)
            FROM [#CurrentBlocking_ResourceResolution];

            SET @ObjectResolutionSkippedLimitCount =
                CASE WHEN @ObjectResolutionTotalCount > @ObjectResolutionCandidateCount
                     THEN @ObjectResolutionTotalCount - @ObjectResolutionCandidateCount ELSE 0 END;

            UPDATE [c]
            SET
                  [BlockingResourceType] = [r].[ResourceType]
                , [BlockingResourceDatabaseId] = [r].[DatabaseId]
                , [BlockingResourceDatabaseName] = [r].[DatabaseName]
                , [BlockingResourceSchemaName] = [r].[SchemaName]
                , [BlockingResourceObjectId] = [r].[ObjectId]
                , [BlockingResourceObjectName] = [r].[ObjectName]
                , [BlockingResourceIndexId] = [r].[IndexId]
                , [BlockingResourceIndexName] = [r].[IndexName]
                , [BlockingResourcePartitionId] = [r].[PartitionId]
                , [BlockingResourcePartitionNumber] = [r].[PartitionNumber]
                , [BlockingResourceFileId] = [r].[FileId]
                , [BlockingResourcePageId] = [r].[PageId]
                , [BlockingResourceRowId] = [r].[RowId]
                , [BlockingResourceMetadataSubtype] = [r].[MetadataSubtype]
                , [BlockingResourceMetadataName] = [r].[MetadataName]
                , [BlockingResourcePageTypeDesc] = [r].[PageTypeDesc]
                , [BlockingResourceName] = [r].[ResourceName]
                , [BlockingResourceResolutionStatus] = [r].[ResolutionStatus]
            FROM [#CurrentBlocking_BlockingChains] AS [c]
            JOIN [#CurrentBlocking_ResourceResolution] AS [r]
              ON [r].[SourceCode] = 'WAIT_RESOURCE'
             AND [r].[WaitResource] = [c].[WaitResource];

            UPDATE [c]
            SET [BlockingResourceResolutionStatus] =
                CASE WHEN NULLIF(LTRIM(RTRIM([c].[WaitResource])), N'') IS NULL THEN 'EMPTY'
                     ELSE 'SKIPPED_LIMIT' END
            FROM [#CurrentBlocking_BlockingChains] AS [c]
            WHERE [c].[BlockingResourceResolutionStatus] IS NULL;

            UPDATE [l]
            SET
                  [ResourceDatabaseName] = [r].[DatabaseName]
                , [ResolvedResourceType] = [r].[ResourceType]
                , [ResolvedSchemaName] = [r].[SchemaName]
                , [ResolvedObjectId] = [r].[ObjectId]
                , [ResolvedObjectName] = [r].[ObjectName]
                , [ResolvedIndexId] = [r].[IndexId]
                , [ResolvedIndexName] = [r].[IndexName]
                , [ResolvedPartitionId] = [r].[PartitionId]
                , [ResolvedPartitionNumber] = [r].[PartitionNumber]
                , [ResolvedResourceName] = [r].[ResourceName]
                , [ResourceResolutionStatus] = [r].[ResolutionStatus]
            FROM [#CurrentBlocking_Locks] AS [l]
            CROSS APPLY
            (
                SELECT TOP (1) [x].*
                FROM [#CurrentBlocking_ResourceResolution] AS [x]
                WHERE [x].[SourceCode] = 'LOCK_DMV'
                  AND COALESCE([x].[ResourceType], N'') = COALESCE(UPPER([l].[ResourceType]), N'')
                  AND COALESCE([x].[DatabaseId], -1) = COALESCE([l].[ResourceDatabaseId], -1)
                  AND COALESCE([x].[EntityId], -1) = COALESCE([l].[ResourceAssociatedEntityId], -1)
                  AND COALESCE([x].[MetadataSubtype], N'') = COALESCE([l].[ResourceSubtype], N'')
                  AND COALESCE([x].[ResourceQualifier], N'') = COALESCE([l].[ResourceDescription], N'')
                ORDER BY [x].[CandidateId]
            ) AS [r];

            UPDATE [l]
            SET [ResourceResolutionStatus] = 'SKIPPED_LIMIT'
            FROM [#CurrentBlocking_Locks] AS [l]
            WHERE [l].[ResourceResolutionStatus] IS NULL;
        END;
        ELSE
        BEGIN
            UPDATE [#CurrentBlocking_BlockingChains]
            SET [BlockingResourceResolutionStatus] = 'SKIPPED';

            UPDATE [#CurrentBlocking_Locks]
            SET [ResourceResolutionStatus] = 'SKIPPED';
        END;

        DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
        DECLARE @ColumnTruncatedCount bigint=0,@ColumnLargestCharacters bigint=NULL;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentBlocking_BlockingChains',@TextColumn=N'BlockedStatement'
            , @CharactersColumn=N'BlockedStatementCharacters',@BytesColumn=N'BlockedStatementBytes'
            , @IsTruncatedColumn=N'BlockedStatementIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
        SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
               @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentBlocking_BlockingChains',@TextColumn=N'BlockerStatement'
            , @CharactersColumn=N'BlockerStatementCharacters',@BytesColumn=N'BlockerStatementBytes'
            , @IsTruncatedColumn=N'BlockerStatementIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
        SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
               @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentBlocking_BlockingChains',@TextColumn=N'RootBlockerStatement'
            , @CharactersColumn=N'RootBlockerStatementCharacters',@BytesColumn=N'RootBlockerStatementBytes'
            , @IsTruncatedColumn=N'RootBlockerStatementIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
        SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
               @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
        EXEC [monitor].[InternalEmitTruncationWarning]
              @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen'
            , @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters
            , @PrintMeldungen=@PrintMeldungen;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();
        SET @IsPartial = 1;
        SET @StatusCode = CASE WHEN @ErrorNumber IN (229, 262, 297, 300, 371, 916)
                               THEN 'DENIED_PERMISSION'
                               WHEN @ErrorNumber = 1222 THEN 'TIMEOUT'
                               WHEN @ParentCurrentStateSnapshotId IS NOT NULL
                                AND @ErrorNumber IN (208, 51020) THEN 'INVALID_PARENT_SNAPSHOT'
                               ELSE 'ERROR_HANDLED' END;
    END CATCH;

    IF @IsPartial = 1 AND @StatusCode = 'AVAILABLE'
        SET @StatusCode = 'AVAILABLE_LIMITED';

    IF @PrintMeldungen = 1 AND @StatusCode NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED')
    BEGIN
        SET @Message = FORMATMESSAGE(N'WARNUNG USP_CurrentBlocking [%s]: %s', @StatusCode, COALESCE(@ErrorMessage, N'Unbekannter Fehler.'));
        RAISERROR(N'%s', 10, 1, @Message) WITH NOWAIT;
    END;

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        SELECT
              N'USP_CurrentBlocking' AS [ModuleName]
            , @CollectionTimeUtc AS [CollectionTimeUtc]
            , @EvidenceSnapshotStartedAtUtc AS [EvidenceSnapshotStartedAtUtc]
            , @EvidenceSnapshotId AS [EvidenceSnapshotId]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , CASE WHEN @MainCandidateCount > @EffectiveMaxZeilen
                   THEN @EffectiveMaxZeilen ELSE @MainCandidateCount END AS [ReturnedRowCount]
            , @HasMoreRows AS [HasMoreRows]
            , @ToolHintergrundabfragenEinbeziehen AS [ToolBackgroundQueriesIncluded]
            , @LockStatusCode AS [LockStatusCode]
            , @BlockingObjektTiefeNormalisiert AS [BlockingObjectDepth]
            , @ObjectResolutionStatusCode AS [ObjectResolutionStatusCode]
            , @ObjectResolutionCandidateCount AS [ObjectResolutionCandidateCount]
            , @ObjectResolutionTotalCount AS [ObjectResolutionTotalCount]
            , @ObjectResolutionHasMoreRows AS [ObjectResolutionHasMoreRows]
            , @ObjectResolutionResolvedCount AS [ObjectResolutionResolvedCount]
            , @ObjectResolutionPartialCount AS [ObjectResolutionPartialCount]
            , @ObjectResolutionRawOnlyCount AS [ObjectResolutionRawOnlyCount]
            , @ObjectResolutionTimeoutCount AS [ObjectResolutionTimeoutCount]
            , @ObjectResolutionDeniedCount AS [ObjectResolutionDeniedCount]
            , @ObjectResolutionErrorCount AS [ObjectResolutionErrorCount]
            , @ObjectResolutionSkippedLimitCount AS [ObjectResolutionSkippedLimitCount]
            , @RequiredPermission AS [RequiredPermission]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage];

        IF @ResultSetArtNormalisiert = 'RAW'
        BEGIN
            SELECT TOP (@EffectiveMaxZeilen)
                  [LeafSessionId], [BlockedSessionId], [BlockingSessionId]
                , [RootBlockingSessionId], [BlockingOwnerType], [BlockingOwnerDescription]
                , [BlockingChain], [ChainDepth], [IsCycle]
                , [WaitType], [WaitTimeMs], [WaitResource]
                , [BlockingResourceType], [BlockingResourceDatabaseId], [BlockingResourceDatabaseName]
                , [BlockingResourceSchemaName], [BlockingResourceObjectId], [BlockingResourceObjectName]
                , [BlockingResourceIndexId], [BlockingResourceIndexName]
                , [BlockingResourcePartitionId], [BlockingResourcePartitionNumber]
                , [BlockingResourceFileId], [BlockingResourcePageId], [BlockingResourceRowId]
                , [BlockingResourceMetadataSubtype], [BlockingResourceMetadataName]
                , [BlockingResourcePageTypeDesc]
                , [BlockingResourceName], [BlockingResourceResolutionStatus]
                , [BlockedLoginName], [BlockedHostName], [BlockedProgramName]
                , [BlockedIsToolBackgroundQuery], [BlockedToolBackgroundRuleCode]
                , [BlockedToolBackgroundCategory], [BlockedToolBackgroundDetection]
                , [BlockedToolBackgroundConfidence]
                , [BlockerLoginName], [BlockerHostName], [BlockerProgramName]
                , [RootBlockerLoginName], [RootBlockerHostName], [RootBlockerProgramName]
                , [RootBlockerSessionStatus], [RootBlockerRequestStatus]
                , [RootBlockerOpenTransactionCount]
                , [RootBlockerLastRequestStartTime], [RootBlockerLastRequestEndTime]
                , [RootIsToolBackgroundQuery], [RootToolBackgroundRuleCode]
                , [RootToolBackgroundCategory], [RootToolBackgroundDetection]
                , [RootToolBackgroundConfidence]
                , [BlockedStatementCharacters], [BlockedStatementBytes], [BlockedStatementIsTruncated], [BlockedStatement]
                , [BlockerStatementCharacters], [BlockerStatementBytes], [BlockerStatementIsTruncated], [BlockerStatement]
                , [RootBlockerStatementSource]
                , [RootBlockerStatementCharacters], [RootBlockerStatementBytes], [RootBlockerStatementIsTruncated], [RootBlockerStatement]
            FROM [#CurrentBlocking_BlockingChains]
            ORDER BY [WaitTimeMs] DESC, [BlockedSessionId];

            IF @MitLockDetails = 1
            BEGIN
                SELECT TOP (@EffectiveMaxZeilen)
                      [SessionId], [ResourceType], [ResourceDatabaseId]
                    , [ResourceDatabaseName], [ResourceDescription], [ResourceSubtype]
                    , [ResourceAssociatedEntityId], [ResourceLockPartition]
                    , [RequestMode], [RequestStatus], [RequestOwnerType]
                    , [RequestReferenceCount], [LockOwnerAddress]
                    , [ResolvedResourceType], [ResolvedSchemaName]
                    , [ResolvedObjectId], [ResolvedObjectName]
                    , [ResolvedIndexId], [ResolvedIndexName]
                    , [ResolvedPartitionId], [ResolvedPartitionNumber]
                    , [ResolvedResourceName], [ResourceResolutionStatus]
                FROM [#CurrentBlocking_Locks]
                ORDER BY [SessionId], [ResourceDatabaseId], [ResourceType], [RequestMode];
            END;
        END
        ELSE
        BEGIN
            SELECT TOP (@EffectiveMaxZeilen)
                  N'Blocking-Kette' AS [Ergebnis]
                , [BlockedSessionId] AS [Blockierte Session]
                , [BlockingSessionId] AS [Blockierende Session]
                , [RootBlockingSessionId] AS [Root Blocker]
                , [BlockingChain] AS [Blocker-Kette]
                , [BlockingOwnerType] AS [Blocker-Typ]
                , [BlockingOwnerDescription] AS [Blocker-Typbeschreibung]
                , [ChainDepth] AS [Kettentiefe]
                , CASE WHEN [IsCycle] = 1 THEN N'Ja' ELSE N'Nein' END AS [Zyklus]
                , [WaitType] AS [Wait]
                , CONCAT(CONVERT(varchar(30), [WaitTimeMs]), N' ms') AS [Wartezeit]
                , [WaitResource] AS [Wait-Ressource]
                , [BlockingResourceType] AS [Aufgelöster Ressourcentyp]
                , [BlockingResourceName] AS [Aufgelöste Blocking-Ressource]
                , [BlockingResourceResolutionStatus] AS [Auflösungsstatus]
                , [BlockedLoginName] AS [Blockierter Login]
                , [BlockedHostName] AS [Blockierter Host]
                , [BlockedProgramName] AS [Blockiertes Programm]
                , [BlockerLoginName] AS [Blocker Login]
                , [BlockerHostName] AS [Blocker Host]
                , [BlockerProgramName] AS [Blocker Programm]
                , [RootBlockerLoginName] AS [Root-Blocker Login]
                , [RootBlockerHostName] AS [Root-Blocker Host]
                , [RootBlockerProgramName] AS [Root-Blocker Programm]
                , [RootBlockerSessionStatus] AS [Root-Blocker Sessionstatus]
                , [RootBlockerRequestStatus] AS [Root-Blocker Requeststatus]
                , [RootBlockerOpenTransactionCount] AS [Root-Blocker offene Transaktionen]
                , [BlockedSessionId] AS [Session_SQL]
                , [BlockedStatement] AS [Blockiertes Statement]
                , [BlockerStatement] AS [Blocker Statement]
                , [RootBlockerStatementSource] AS [Root-Blocker Statementquelle]
                , [RootBlockerStatement] AS [Root-Blocker Statement]
            FROM [#CurrentBlocking_BlockingChains]
            ORDER BY [WaitTimeMs] DESC, [BlockedSessionId];

            IF @MitLockDetails = 1
            BEGIN
                SELECT TOP (@EffectiveMaxZeilen)
                      N'Lock der Blocking-Kette' AS [Ergebnis]
                    , [SessionId] AS [Session]
                    , [ResourceDatabaseName] AS [Datenbank]
                    , [ResourceType] AS [Ressourcentyp]
                    , [ResourceSubtype] AS [Ressourcenuntertyp]
                    , [ResourceDescription] AS [Ressource]
                    , [ResourceAssociatedEntityId] AS [Entitäts-ID]
                    , [ResolvedResourceName] AS [Aufgelöste Ressource]
                    , [ResourceResolutionStatus] AS [Auflösungsstatus]
                    , [RequestMode] AS [Lock-Modus]
                    , [RequestStatus] AS [Status]
                    , [RequestOwnerType] AS [Owner]
                    , [RequestReferenceCount] AS [Referenzen]
                FROM [#CurrentBlocking_Locks]
                ORDER BY [SessionId], [ResourceDatabaseId], [ResourceType], [RequestMode];
            END;
        END;

        SELECT [ScopeName], [StatusCode], [ErrorNumber], [ErrorMessage]
        FROM [#CurrentBlocking_Warnings]
        ORDER BY [ScopeName], [StatusCode];
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  N'CurrentBlocking' AS [resultName]
                , 3 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @EvidenceSnapshotStartedAtUtc AS [evidenceSnapshotStartedAtUtc]
                , @EvidenceSnapshotId AS [evidenceSnapshotId]
                , @IsPartial AS [isPartial]
                , @StatusCode AS [statusCode]
                , @MaxZeilen AS [requestedMaxRows]
                , CASE WHEN @MainCandidateCount > @EffectiveMaxZeilen
                       THEN @EffectiveMaxZeilen ELSE @MainCandidateCount END AS [returnedRows]
                , @HasMoreRows AS [hasMoreRows]
                , @LockStatusCode AS [lockStatusCode]
                , @BlockingObjektTiefeNormalisiert AS [blockingObjectDepth]
                , @ObjectResolutionStatusCode AS [objectResolutionStatusCode]
                , @ObjectResolutionCandidateCount AS [objectResolutionCandidateCount]
                , @ObjectResolutionTotalCount AS [objectResolutionTotalCount]
                , @ObjectResolutionHasMoreRows AS [objectResolutionHasMoreRows]
                , @ObjectResolutionResolvedCount AS [objectResolutionResolvedCount]
                , @ObjectResolutionPartialCount AS [objectResolutionPartialCount]
                , @ObjectResolutionRawOnlyCount AS [objectResolutionRawOnlyCount]
                , @ObjectResolutionTimeoutCount AS [objectResolutionTimeoutCount]
                , @ObjectResolutionDeniedCount AS [objectResolutionDeniedCount]
                , @ObjectResolutionErrorCount AS [objectResolutionErrorCount]
                , @ObjectResolutionSkippedLimitCount AS [objectResolutionSkippedLimitCount]
                , @ToolHintergrundabfragenEinbeziehen AS [toolBackgroundQueriesIncluded]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @ChainsJson nvarchar(max) =
        (
            SELECT TOP (@EffectiveMaxZeilen) *
            FROM [#CurrentBlocking_BlockingChains]
            ORDER BY [WaitTimeMs] DESC, [BlockedSessionId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        DECLARE @LocksJson nvarchar(max) =
        (
            SELECT TOP (@EffectiveMaxZeilen) *
            FROM [#CurrentBlocking_Locks]
            ORDER BY [SessionId], [ResourceDatabaseId], [ResourceType], [RequestMode]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        DECLARE @WarningsJson nvarchar(max) =
        (
            SELECT *
            FROM [#CurrentBlocking_Warnings]
            ORDER BY [ScopeName], [StatusCode]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"blockingChains":', COALESCE(@ChainsJson, N'[]')
            , N',"locks":', COALESCE(@LocksJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CurrentBlocking_BlockingChains'
            , @ResultLabel=N'Blocking-Ketten'
            , @EmptyMessage=N'Keine Blocking-Ketten';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#CurrentBlocking_BlockingChains'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
