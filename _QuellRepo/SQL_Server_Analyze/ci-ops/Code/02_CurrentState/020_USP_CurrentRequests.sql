USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CurrentRequests
Version      : 4.0.0
Stand        : 2026-07-23
Typ          : Stored Procedure
Zweck        : Liefert aktive Requests mit Session-, Wait-, Memory-Grant-,
               Modul- und exakt abgegrenztem SQL-Statement- sowie Ausführungs-
               und Verschachtelungskontext.
Filter       : Session-ID-Liste, exakte bracket-aware Textlisten und getrennte
               LIKE-/Regex-Patterns.
SQL-Text     : Das laufende Statement wird über statement_start_offset und
               statement_end_offset aus dem Batch beziehungsweise persistenten
               Modul extrahiert. Optional sind vollständiger Batch-/Modultext,
               Input Buffer und Modulauflösung verfügbar.
Ausgabe      : CONSOLE (Default), RAW, TABLE, NONE sowie optionales JSON-Envelope
               mit requests (Legacy), requestContext, snapshotStatus,
               statements, batches, inputBuffers und warnings.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CurrentRequests]
      @SessionIds                    nvarchar(max)  = NULL
    , @EigeneSessionsModus           varchar(16)    = 'ALLE'
    , @AktuelleSessionEinbeziehen    bit            = 0
    , @SystemSessionsEinbeziehen     bit            = 0
    , @ToolHintergrundabfragenEinbeziehen bit        = 0
    , @NurBlockierte                 bit            = 0
    , @NurMitWait                    bit            = 0
    , @MinLaufzeitSekunden           int            = NULL
    , @MinCpuMs                      bigint         = NULL
    , @MinLogicalReads               bigint         = NULL
    , @LoginNames                    nvarchar(max)  = NULL
    , @LoginNamePattern              nvarchar(4000) = NULL
    , @HostNames                     nvarchar(max)  = NULL
    , @HostNamePattern               nvarchar(4000) = NULL
    , @ProgramNames                  nvarchar(max)  = NULL
    , @ProgramNamePattern            nvarchar(4000) = NULL
    , @DatabaseNames                 nvarchar(max)  = NULL
    , @DatabaseNamePattern           nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @TextPattern                   nvarchar(4000) = NULL
    , @MitSqlText                    bit            = 1
    , @GesamtenSqlTextEinbeziehen    bit            = 0
    , @InputBufferEinbeziehen        bit            = 0
    , @ModulInfoEinbeziehen          bit            = 1
    , @MaxSqlTextZeichen             int            = 4000
    , @MaxZeilen                     int            = 500
    , @Sortierung                    varchar(32)    = 'RELEVANZ'
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                bit            = 1
    , @Hilfe                         bit            = 0
    , @ParentCurrentStateSnapshotId  uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @ModuleName sysname = N'USP_CurrentRequests';
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @RowCount bigint = 0;
    DECLARE @HasMoreRows bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Detail nvarchar(2000) = NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @RequiredPermission nvarchar(256) =
        CASE
            WHEN TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
                THEN N'VIEW SERVER PERFORMANCE STATE'
            ELSE N'VIEW SERVER STATE'
        END;
    DECLARE @HasFullView bit =
        CASE
            WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 1
            WHEN TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
                THEN COALESCE(HAS_PERMS_BY_NAME(NULL, N'SERVER', N'VIEW SERVER PERFORMANCE STATE'), 0)
            ELSE COALESCE(HAS_PERMS_BY_NAME(NULL, N'SERVER', N'VIEW SERVER STATE'), 0)
        END;
    DECLARE @MonitorPrintMessage nvarchar(2048);
    DECLARE @CandidateMaxZeilen bigint;
    DECLARE @SqlTextErforderlich bit;
    DECLARE @StatementTextErforderlich bit;
    DECLARE @BatchTextErforderlich bit;
    DECLARE @EvidenceSnapshotStartedAtUtc datetime2(3)=@CollectionTimeUtc;
    DECLARE @EvidenceSnapshotId uniqueidentifier=COALESCE(@ParentCurrentStateSnapshotId,NEWID());
    DECLARE @ParentSnapshotIsPartial bit=0;

    SET @EigeneSessionsModus = UPPER(LTRIM(RTRIM(COALESCE(@EigeneSessionsModus, 'ALLE'))));
    SET @Sortierung = UPPER(LTRIM(RTRIM(COALESCE(@Sortierung, 'RELEVANZ'))));
    SET @StatementTextErforderlich =
        CASE WHEN @MitSqlText = 1 OR @TextPattern IS NOT NULL THEN 1 ELSE 0 END;
    SET @BatchTextErforderlich =
        CASE WHEN @GesamtenSqlTextEinbeziehen = 1 OR @TextPattern IS NOT NULL THEN 1 ELSE 0 END;
    SET @SqlTextErforderlich =
        CASE
            WHEN @StatementTextErforderlich = 1
              OR @BatchTextErforderlich = 1
              OR @ModulInfoEinbeziehen = 1
                THEN 1
            ELSE 0
        END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CurrentRequests';
        PRINT N'@SessionIds: Pipe-Liste. Exakte Namenslisten und die zugehörigen ...Pattern sind gegenseitig exklusiv.';
        PRINT N'@ToolHintergrundabfragenEinbeziehen=0 blendet erkannte Object-Explorer-, Copilot- und SQL-Prompt-Hintergrundrequests standardmäßig aus; 1 zeigt sie samt Klassifikation.';
        PRINT N'Pattern: LIKE (Default/like:), regex: oder regexi:. @TextPattern prüft das aktuelle Statement und den vollständigen Batch-/Modultext.';
        PRINT N'@MitSqlText=1 gibt das exakt über die Request-Offsets ermittelte Statement aus.';
        PRINT N'@GesamtenSqlTextEinbeziehen=1 gibt zusätzlich den vollständigen Batch beziehungsweise persistenten Modultext aus.';
        PRINT N'@InputBufferEinbeziehen=1 ergänzt den ursprünglich an SQL Server übergebenen Befehl, z. B. EXEC/RPC-Aufruf.';
        PRINT N'@ModulInfoEinbeziehen=1 löst dbid/objectid über die Systemtabellen der jeweiligen Datenbank auf.';
        PRINT N'@MaxSqlTextZeichen: positiver Wert kürzt die Darstellung; NULL/0 gibt den jeweiligen Text vollständig aus.';
        PRINT N'@MaxZeilen: positiver Wert begrenzt; NULL/0 unbegrenzt. @ResultSetArt CONSOLE (Default), RAW, TABLE oder NONE; optional @Json OUTPUT.';
        PRINT N'TABLE-Namen: requests (Legacy), requestContext, snapshotStatus, statements, batches, inputBuffers und warnings.';
        PRINT N'@ParentCurrentStateSnapshotId ist ausschließlich für den laufinternen Overview-Consumer bestimmt; NULL erzwingt einen frischen Einzelread.';
        RETURN;
    END;

    CREATE TABLE [#CurrentRequests_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL UNIQUE
    );

    CREATE TABLE [#CurrentRequests_SessionIdFilter]
    (
        [SessionId] smallint NOT NULL PRIMARY KEY
    );

    CREATE TABLE [#CurrentRequests_StringFilter]
    (
          [FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [StringValue] nvarchar(4000) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , PRIMARY KEY ([FilterType], [StringValue])
    );

    CREATE TABLE [#CurrentRequests_Warnings]
    (
          [WarningId] int IDENTITY(1,1) NOT NULL PRIMARY KEY
        , [SessionId] smallint NULL
        , [RequestId] int NULL
        , [DatabaseName] sysname NULL
        , [Code] varchar(40) NOT NULL
        , [Message] nvarchar(2048) NOT NULL
    );

    DECLARE @LoginMode varchar(8), @LoginPattern nvarchar(4000), @LoginFlags varchar(8), @LoginValid bit;
    DECLARE @HostMode varchar(8), @HostPattern nvarchar(4000), @HostFlags varchar(8), @HostValid bit;
    DECLARE @ProgramMode varchar(8), @ProgramPattern nvarchar(4000), @ProgramFlags varchar(8), @ProgramValid bit;
    DECLARE @DatabaseMode varchar(8), @DatabasePattern nvarchar(4000), @DatabaseFlags varchar(8), @DatabaseValid bit;
    DECLARE @TextMode varchar(8), @TextPatternValue nvarchar(4000), @TextFlags varchar(8), @TextValid bit;

    SELECT @LoginMode = [PatternMode], @LoginPattern = [PatternValue], @LoginFlags = [RegexFlags], @LoginValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@LoginNamePattern);

    SELECT @HostMode = [PatternMode], @HostPattern = [PatternValue], @HostFlags = [RegexFlags], @HostValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@HostNamePattern);

    SELECT @ProgramMode = [PatternMode], @ProgramPattern = [PatternValue], @ProgramFlags = [RegexFlags], @ProgramValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@ProgramNamePattern);

    SELECT @DatabaseMode = [PatternMode], @DatabasePattern = [PatternValue], @DatabaseFlags = [RegexFlags], @DatabaseValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@DatabaseNamePattern);

    SELECT @TextMode = [PatternMode], @TextPatternValue = [PatternValue], @TextFlags = [RegexFlags], @TextValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@TextPattern);

    IF @SessionIds IS NOT NULL
    BEGIN
        IF EXISTS
        (
            SELECT 1
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid] = 0
               OR [NumberValue] NOT BETWEEN 1 AND 32767
        )
        BEGIN
            SET @StatusCode = 'INVALID_PARAMETER';
        END;
        ELSE
        BEGIN
            INSERT [#CurrentRequests_SessionIdFilter] ([SessionId])
            SELECT CONVERT(smallint, [NumberValue])
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            GROUP BY [NumberValue];
        END;
    END;

    IF @StatusCode = 'AVAILABLE'
       AND
       (
              (@LoginNames IS NOT NULL AND @LoginNamePattern IS NOT NULL)
           OR (@HostNames IS NOT NULL AND @HostNamePattern IS NOT NULL)
           OR (@ProgramNames IS NOT NULL AND @ProgramNamePattern IS NOT NULL)
           OR (@DatabaseNames IS NOT NULL AND @DatabaseNamePattern IS NOT NULL)
           OR @LoginValid = 0
           OR @HostValid = 0
           OR @ProgramValid = 0
           OR @DatabaseValid = 0
           OR @TextValid = 0
       )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
    END;

    IF @StatusCode = 'AVAILABLE'
       AND
       (
              (@LoginNames IS NOT NULL AND EXISTS
               (SELECT 1 FROM [monitor].[TVF_ParseStringList](@LoginNames) WHERE [IsValid] = 0 OR LEN([StringValue]) > 128))
           OR (@HostNames IS NOT NULL AND EXISTS
               (SELECT 1 FROM [monitor].[TVF_ParseStringList](@HostNames) WHERE [IsValid] = 0 OR LEN([StringValue]) > 128))
           OR (@ProgramNames IS NOT NULL AND EXISTS
               (SELECT 1 FROM [monitor].[TVF_ParseStringList](@ProgramNames) WHERE [IsValid] = 0 OR LEN([StringValue]) > 128))
           OR (@DatabaseNames IS NOT NULL AND EXISTS
               (SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@DatabaseNames) WHERE [IsValid] = 0))
       )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        INSERT [#CurrentRequests_StringFilter] ([FilterType], [StringValue])
        SELECT 'LOGIN', [StringValue]
        FROM [monitor].[TVF_ParseStringList](@LoginNames)
        WHERE [IsValid] = 1
        GROUP BY [StringValue];

        INSERT [#CurrentRequests_StringFilter] ([FilterType], [StringValue])
        SELECT 'HOST', [StringValue]
        FROM [monitor].[TVF_ParseStringList](@HostNames)
        WHERE [IsValid] = 1
        GROUP BY [StringValue];

        INSERT [#CurrentRequests_StringFilter] ([FilterType], [StringValue])
        SELECT 'PROGRAM', [StringValue]
        FROM [monitor].[TVF_ParseStringList](@ProgramNames)
        WHERE [IsValid] = 1
        GROUP BY [StringValue];

        INSERT [#CurrentRequests_StringFilter] ([FilterType], [StringValue])
        SELECT 'DATABASE', [NameValue]
        FROM [monitor].[TVF_ParseSqlNameList](@DatabaseNames)
        WHERE [IsValid] = 1
        GROUP BY [NameValue];
    END;

    DECLARE @HasRegex bit =
        CASE
            WHEN @LoginMode IN ('REGEX', 'REGEXI')
              OR @HostMode IN ('REGEX', 'REGEXI')
              OR @ProgramMode IN ('REGEX', 'REGEXI')
              OR @DatabaseMode IN ('REGEX', 'REGEXI')
              OR @TextMode IN ('REGEX', 'REGEXI')
                THEN 1
            ELSE 0
        END;

    IF @StatusCode = 'AVAILABLE'
       AND @HasRegex = 1
       AND
       (
           TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) < 17
           OR
           (
               SELECT [compatibility_level]
               FROM [master].[sys].[databases] WITH (NOLOCK)
               WHERE [database_id] = DB_ID()
           ) < 170
       )
    BEGIN
        SET @StatusCode = 'UNAVAILABLE_FEATURE';
        SET @ErrorMessage = N'Regex benötigt SQL Server 2025 und Compatibility Level 170.';
    END;

    IF @StatusCode = 'AVAILABLE'
       AND
       (
              @EigeneSessionsModus NOT IN ('ALLE', 'NUR', 'AUSSCHLIESSEN')
           OR @Sortierung NOT IN ('RELEVANZ', 'CPU', 'READS', 'DAUER', 'SESSION')
           OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
           OR @MaxZeilen < 0
           OR @MaxSqlTextZeichen < 0
           OR COALESCE(@MinLaufzeitSekunden, 0) < 0
           OR COALESCE(@MinCpuMs, 0) < 0
           OR COALESCE(@MinLogicalReads, 0) < 0
           OR @MitSqlText IS NULL OR @MitSqlText NOT IN (0, 1)
           OR @GesamtenSqlTextEinbeziehen IS NULL OR @GesamtenSqlTextEinbeziehen NOT IN (0, 1)
           OR @InputBufferEinbeziehen IS NULL OR @InputBufferEinbeziehen NOT IN (0, 1)
           OR @ModulInfoEinbeziehen IS NULL OR @ModulInfoEinbeziehen NOT IN (0, 1)
           OR @ToolHintergrundabfragenEinbeziehen IS NULL OR @ToolHintergrundabfragenEinbeziehen NOT IN (0, 1)
           OR @JsonErzeugen IS NULL OR @JsonErzeugen NOT IN (0, 1)
       )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
    END;

    IF @StatusCode = 'INVALID_PARAMETER'
    BEGIN
        SET @ErrorMessage = COALESCE(@ErrorMessage, N'Ungültige Liste, Kombination, Pattern- oder Steuerangabe.');
    END;

    IF @StatusCode='AVAILABLE' AND @TableResultRequested=1
    BEGIN
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'requests|requestContext|snapshotStatus|statements|batches|inputBuffers|warnings'
            , @MappingTable=N'#CurrentRequests_ResultTableMap'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @ThrowOnError=1;
    END;

    CREATE TABLE [#CurrentRequests_Result]
    (
          [SessionId] smallint NOT NULL
        , [RequestId] int NOT NULL
        , [RequestStatus] nvarchar(30) NULL
        , [Command] nvarchar(32) NULL
        , [DatabaseId] smallint NULL
        , [DatabaseName] sysname NULL
        , [LoginName] nvarchar(128) NULL
        , [OriginalLoginName] nvarchar(128) NULL
        , [HostName] nvarchar(128) NULL
        , [ProgramName] nvarchar(128) NULL
        , [IsToolBackgroundQuery] bit NOT NULL
        , [ToolBackgroundRuleCode] varchar(64) NULL
        , [ToolBackgroundCategory] varchar(40) NULL
        , [ToolBackgroundDetection] varchar(40) NULL
        , [ToolBackgroundConfidence] varchar(16) NULL
        , [StartTime] datetime NULL
        , [ElapsedMs] int NULL
        , [CpuMs] int NULL
        , [LogicalReads] bigint NULL
        , [Reads] bigint NULL
        , [Writes] bigint NULL
        , [RowCount] bigint NULL
        , [PercentComplete] real NULL
        , [EstimatedCompletionTimeMs] bigint NULL
        , [BlockingSessionId] smallint NULL
        , [WaitType] nvarchar(120) NULL
        , [WaitTimeMs] int NULL
        , [LastWaitType] nvarchar(120) NULL
        , [WaitResource] nvarchar(256) NULL
        , [WaitingTaskCount] int NULL
        , [MaxTaskWaitMs] bigint NULL
        , [TaskWaitTypes] nvarchar(max) NULL
        , [RequestedMemoryMb] decimal(19,2) NULL
        , [GrantedMemoryMb] decimal(19,2) NULL
        , [UsedMemoryMb] decimal(19,2) NULL
        , [IdealMemoryMb] decimal(19,2) NULL
        , [Dop] smallint NULL
        , [ParallelWorkerCount] int NULL
        , [TransactionIsolationLevel] nvarchar(40) NULL
        , [OpenTransactionCount] int NULL
        , [OpenResultsetCount] int NULL
        , [TransactionId] bigint NULL
        , [ConnectionId] uniqueidentifier NULL
        , [SchedulerId] int NULL
        , [TaskAddress] varbinary(8) NULL
        , [NestLevel] int NULL
        , [WorkloadGroupId] int NULL
        , [WorkloadGroupName] sysname NULL
        , [ResourcePoolId] int NULL
        , [ResourcePoolName] sysname NULL
        , [StatementSqlHandle] varbinary(64) NULL
        , [StatementContextId] bigint NULL
        , [IsResumable] bit NULL
        , [ExecutingManagedCode] bit NULL
        , [ContextInfo] varbinary(128) NULL
        , [ClientNetAddress] varchar(48) NULL
        , [QueryHash] binary(8) NULL
        , [QueryPlanHash] binary(8) NULL
        , [SqlHandle] varbinary(64) NULL
        , [PlanHandle] varbinary(64) NULL
        , [SqlTextDatabaseId] int NULL
        , [SqlTextObjectId] int NULL
        , [SqlTextObjectNumber] smallint NULL
        , [SqlTextIsEncrypted] bit NULL
        , [ExecutionContextType] varchar(20) NULL
        , [ModuleDatabaseName] sysname NULL
        , [ModuleSchemaName] sysname NULL
        , [ModuleObjectName] sysname NULL
        , [ModuleType] char(2) NULL
        , [ModuleTypeDescription] nvarchar(60) NULL
        , [ModuleFullName] nvarchar(776) NULL
        , [HasStatementOffsets] bit NULL
        , [IsStatementOffsetValid] bit NULL
        , [StatementStartOffsetBytes] int NULL
        , [StatementEndOffsetBytes] int NULL
        , [StatementStartCharacter] int NULL
        , [StatementEndCharacter] int NULL
        , [StatementStartLine] int NULL
        , [StatementEndLine] int NULL
        , [CurrentStatementCharacterCount] bigint NULL
        , [CurrentStatementBytes] bigint NULL
        , [CurrentStatementIsTruncated] bit NULL
        , [BatchTextCharacterCount] bigint NULL
        , [BatchTextBytes] bigint NULL
        , [BatchTextIsTruncated] bit NULL
        , [CurrentStatement] nvarchar(max) NULL
        , [BatchText] nvarchar(max) NULL
        , [InputBufferEventType] nvarchar(256) NULL
        , [InputBufferParameterCount] smallint NULL
        , [InputBufferCharacterCount] bigint NULL
        , [InputBufferBytes] bigint NULL
        , [InputBufferIsTruncated] bit NULL
        , [InputBufferText] nvarchar(max) NULL
        , PRIMARY KEY ([SessionId], [RequestId])
    );

    CREATE TABLE [#CurrentRequests_SnapshotStatus]
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
        , PRIMARY KEY ([SourceCode])
    );

    CREATE TABLE [#CurrentRequests_SourceSessions]
    (
          [session_id] smallint NOT NULL PRIMARY KEY
        , [is_user_process] bit NOT NULL
        , [login_name] nvarchar(128) NOT NULL
        , [original_login_name] nvarchar(128) NOT NULL
        , [host_name] nvarchar(128) NULL
        , [program_name] nvarchar(128) NULL
    );
    CREATE TABLE [#CurrentRequests_SourceRequests]
    (
          [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [command] nvarchar(32) NOT NULL
        , [database_id] smallint NOT NULL
        , [start_time] datetime NOT NULL
        , [total_elapsed_time] int NOT NULL
        , [cpu_time] int NOT NULL
        , [logical_reads] bigint NOT NULL
        , [reads] bigint NOT NULL
        , [writes] bigint NOT NULL
        , [row_count] bigint NOT NULL
        , [percent_complete] real NOT NULL
        , [estimated_completion_time] bigint NOT NULL
        , [blocking_session_id] smallint NULL
        , [wait_type] nvarchar(60) NULL
        , [wait_time] int NOT NULL
        , [last_wait_type] nvarchar(60) NOT NULL
        , [wait_resource] nvarchar(256) NOT NULL
        , [dop] int NOT NULL
        , [parallel_worker_count] int NULL
        , [transaction_isolation_level] smallint NOT NULL
        , [open_transaction_count] int NOT NULL
        , [open_resultset_count] int NOT NULL
        , [transaction_id] bigint NOT NULL
        , [scheduler_id] int NULL
        , [task_address] varbinary(8) NULL
        , [nest_level] int NOT NULL
        , [group_id] int NOT NULL
        , [statement_sql_handle] varbinary(64) NULL
        , [statement_context_id] bigint NULL
        , [is_resumable] bit NOT NULL
        , [executing_managed_code] bit NOT NULL
        , [context_info] varbinary(128) NULL
        , [query_hash] binary(8) NULL
        , [query_plan_hash] binary(8) NULL
        , [sql_handle] varbinary(64) NULL
        , [plan_handle] varbinary(64) NULL
        , [statement_start_offset] int NULL
        , [statement_end_offset] int NULL
        , PRIMARY KEY ([session_id],[request_id])
    );
    CREATE TABLE [#CurrentRequests_SourceConnections]
    (
          [session_id] int NULL
        , [connection_id] uniqueidentifier NOT NULL PRIMARY KEY
        , [client_net_address] varchar(48) NULL
        , [net_transport] nvarchar(40) NOT NULL
        , [protocol_type] nvarchar(40) NULL
        , [encrypt_option] nvarchar(40) NOT NULL
        , [auth_scheme] nvarchar(40) NOT NULL
    );
    CREATE INDEX [IX_CurrentRequests_SourceConnections_SessionId]
        ON [#CurrentRequests_SourceConnections]([session_id]);
    CREATE TABLE [#CurrentRequests_SourceWaitingTasks]
    (
          [waiting_task_address] varbinary(8) NOT NULL
        , [session_id] smallint NULL
        , [exec_context_id] int NULL
        , [wait_duration_ms] bigint NOT NULL
        , [wait_type] nvarchar(60) NOT NULL
        , [blocking_session_id] smallint NULL
        , [resource_description] nvarchar(3072) NULL
    );
    CREATE INDEX [IX_CurrentRequests_SourceWaitingTasks_SessionId]
        ON [#CurrentRequests_SourceWaitingTasks]([session_id]);
    CREATE TABLE [#CurrentRequests_SourceMemoryGrants]
    (
          [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [requested_memory_kb] bigint NOT NULL
        , [granted_memory_kb] bigint NULL
        , [used_memory_kb] bigint NULL
        , [ideal_memory_kb] bigint NULL
    );
    CREATE INDEX [IX_CurrentRequests_SourceMemoryGrants_Request]
        ON [#CurrentRequests_SourceMemoryGrants]([session_id],[request_id]);
    CREATE TABLE [#CurrentRequests_SourceTasks]
    (
          [task_address] varbinary(8) NOT NULL PRIMARY KEY
        , [task_state] nvarchar(60) NOT NULL
        , [session_id] smallint NULL
        , [request_id] int NULL
        , [exec_context_id] int NULL
        , [scheduler_id] int NULL
        , [worker_address] varbinary(8) NULL
    );
    CREATE INDEX [IX_CurrentRequests_SourceTasks_Request]
        ON [#CurrentRequests_SourceTasks]([session_id],[request_id]);
    CREATE TABLE [#CurrentRequests_SourceSchedulers]
    (
          [scheduler_id] int NOT NULL PRIMARY KEY
        , [scheduler_address] varbinary(8) NOT NULL
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
    );
    CREATE TABLE [#CurrentRequests_SourceSessionTransactions]
    (
          [session_id] int NOT NULL
        , [transaction_id] bigint NOT NULL
        , [is_user_transaction] bit NOT NULL
        , [is_local] bit NOT NULL
        , [is_enlisted] bit NOT NULL
        , [is_bound] bit NOT NULL
        , [open_transaction_count] int NOT NULL
        , PRIMARY KEY ([session_id],[transaction_id])
    );
    CREATE TABLE [#CurrentRequests_SourceActiveTransactions]
    (
          [transaction_id] bigint NOT NULL PRIMARY KEY
        , [transaction_begin_time] datetime NOT NULL
        , [transaction_type] int NOT NULL
        , [transaction_state] int NOT NULL
    );
    CREATE TABLE [#CurrentRequests_SourceDatabaseTransactions]
    (
          [transaction_id] bigint NOT NULL
        , [database_id] int NOT NULL
        , [database_transaction_log_bytes_used] bigint NOT NULL
        , [database_transaction_log_bytes_reserved] bigint NOT NULL
    );
    CREATE INDEX [IX_CurrentRequests_SourceDatabaseTransactions]
        ON [#CurrentRequests_SourceDatabaseTransactions]([transaction_id],[database_id]);
    CREATE TABLE [#CurrentRequests_SourceTempDbSessionUsage]
    (
          [session_id] smallint NOT NULL PRIMARY KEY
        , [user_objects_alloc_page_count] bigint NOT NULL
        , [user_objects_dealloc_page_count] bigint NOT NULL
        , [internal_objects_alloc_page_count] bigint NOT NULL
        , [internal_objects_dealloc_page_count] bigint NOT NULL
    );
    CREATE TABLE [#CurrentRequests_SourceTempDbTaskUsage]
    (
          [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [exec_context_id] int NOT NULL
        , [user_objects_alloc_page_count] bigint NOT NULL
        , [user_objects_dealloc_page_count] bigint NOT NULL
        , [internal_objects_alloc_page_count] bigint NOT NULL
        , [internal_objects_dealloc_page_count] bigint NOT NULL
    );
    CREATE INDEX [IX_CurrentRequests_SourceTempDbTaskUsage]
        ON [#CurrentRequests_SourceTempDbTaskUsage]([session_id],[request_id]);
    CREATE TABLE [#CurrentRequests_SourceWorkloadGroups]
    (
          [group_id] int NOT NULL PRIMARY KEY
        , [name] sysname NOT NULL
        , [pool_id] int NOT NULL
    );
    CREATE TABLE [#CurrentRequests_SourceResourcePools]
    (
          [pool_id] int NOT NULL PRIMARY KEY
        , [name] sysname NOT NULL
    );
    CREATE TABLE [#CurrentRequests_SourceSqlText]
    (
          [SqlHandle] varbinary(64) NOT NULL PRIMARY KEY
        , [text] nvarchar(max) NULL
        , [dbid] int NULL
        , [objectid] int NULL
        , [number] smallint NULL
        , [encrypted] bit NULL
    );
    CREATE TABLE [#CurrentRequests_SourceInputBuffer]
    (
          [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [event_type] nvarchar(256) NULL
        , [parameters] smallint NULL
        , [event_info] nvarchar(max) NULL
        , PRIMARY KEY ([session_id],[request_id])
    );
    CREATE TABLE [#CurrentRequests_RequestContext]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [SessionId] smallint NOT NULL
        , [RequestId] int NOT NULL
        , [RequestStatus] nvarchar(30) NULL
        , [Command] nvarchar(32) NULL
        , [DatabaseId] smallint NULL
        , [DatabaseName] sysname NULL
        , [StartTime] datetime NULL
        , [ElapsedMs] int NULL
        , [CpuMs] int NULL
        , [LogicalReads] bigint NULL
        , [Reads] bigint NULL
        , [Writes] bigint NULL
        , [RowCount] bigint NULL
        , [PercentComplete] real NULL
        , [EstimatedCompletionTimeMs] bigint NULL
        , [BlockingSessionId] smallint NULL
        , [WaitType] nvarchar(120) NULL
        , [WaitTimeMs] bigint NULL
        , [WaitResource] nvarchar(3072) NULL
        , [ConnectionId] uniqueidentifier NULL
        , [ClientNetAddress] varchar(48) NULL
        , [NetTransport] nvarchar(40) NULL
        , [ProtocolType] nvarchar(40) NULL
        , [EncryptOption] nvarchar(40) NULL
        , [AuthScheme] nvarchar(40) NULL
        , [TaskCount] int NULL
        , [WorkerCount] int NULL
        , [ExecutionContextCount] int NULL
        , [RunnableTaskCount] int NULL
        , [SuspendedTaskCount] int NULL
        , [SchedulerId] int NULL
        , [SchedulerStatus] nvarchar(60) NULL
        , [SchedulerParentNodeId] int NULL
        , [SchedulerRunnableTaskCount] int NULL
        , [SchedulerWorkQueueCount] bigint NULL
        , [SchedulerPendingDiskIoCount] int NULL
        , [SchedulerLoadFactor] int NULL
        , [TransactionId] bigint NULL
        , [TransactionBeginTime] datetime NULL
        , [TransactionAgeSeconds] bigint NULL
        , [TransactionType] int NULL
        , [TransactionState] int NULL
        , [IsUserTransaction] bit NULL
        , [IsLocalTransaction] bit NULL
        , [IsEnlistedTransaction] bit NULL
        , [IsBoundTransaction] bit NULL
        , [TransactionLogBytesUsed] bigint NULL
        , [TransactionLogBytesReserved] bigint NULL
        , [RequestedMemoryMb] decimal(19,2) NULL
        , [GrantedMemoryMb] decimal(19,2) NULL
        , [UsedMemoryMb] decimal(19,2) NULL
        , [IdealMemoryMb] decimal(19,2) NULL
        , [TempDbSessionNetMb] decimal(19,2) NULL
        , [TempDbRequestNetMb] decimal(19,2) NULL
        , [Dop] smallint NULL
        , [ParallelWorkerCount] int NULL
        , [WorkloadGroupId] int NULL
        , [WorkloadGroupName] sysname NULL
        , [ResourcePoolId] int NULL
        , [ResourcePoolName] sysname NULL
        , [QueryHash] binary(8) NULL
        , [QueryPlanHash] binary(8) NULL
        , [SqlHandle] varbinary(64) NULL
        , [PlanHandle] varbinary(64) NULL
        , [StatementSqlHandle] varbinary(64) NULL
        , [StatementContextId] bigint NULL
        , [ModuleFullName] nvarchar(776) NULL
        , [IsCurrent] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [EvidenceBoundary] nvarchar(512) NULL
        , PRIMARY KEY ([SessionId],[RequestId])
    );
    CREATE TABLE [#CurrentRequests_Statements]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [SessionId] smallint NOT NULL
        , [RequestId] int NOT NULL
        , [SourceCode] varchar(40) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [HasStatementOffsets] bit NULL
        , [IsStatementOffsetValid] bit NULL
        , [StartOffsetBytes] int NULL
        , [EndOffsetBytes] int NULL
        , [StartCharacter] int NULL
        , [EndCharacter] int NULL
        , [StartLine] int NULL
        , [EndLine] int NULL
        , [CharacterCount] bigint NULL
        , [Bytes] bigint NULL
        , [IsTruncated] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [OmissionReason] nvarchar(512) NULL
        , [Text] nvarchar(max) NULL
        , PRIMARY KEY ([SessionId],[RequestId])
    );
    CREATE TABLE [#CurrentRequests_Batches]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [SessionId] smallint NOT NULL
        , [RequestId] int NOT NULL
        , [SourceCode] varchar(40) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [SqlTextDatabaseId] int NULL
        , [SqlTextObjectId] int NULL
        , [SqlTextObjectNumber] smallint NULL
        , [IsEncrypted] bit NULL
        , [CharacterCount] bigint NULL
        , [Bytes] bigint NULL
        , [IsTruncated] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [OmissionReason] nvarchar(512) NULL
        , [Text] nvarchar(max) NULL
        , PRIMARY KEY ([SessionId],[RequestId])
    );
    CREATE TABLE [#CurrentRequests_InputBuffers]
    (
          [SnapshotId] uniqueidentifier NOT NULL
        , [SessionId] smallint NOT NULL
        , [RequestId] int NOT NULL
        , [SourceCode] varchar(40) NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [EventType] nvarchar(256) NULL
        , [ParameterCount] smallint NULL
        , [CharacterCount] bigint NULL
        , [Bytes] bigint NULL
        , [IsTruncated] bit NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [OmissionReason] nvarchar(512) NULL
        , [Text] nvarchar(max) NULL
        , PRIMARY KEY ([SessionId],[RequestId])
    );

    IF @StatusCode='AVAILABLE' AND @ParentCurrentStateSnapshotId IS NOT NULL
    BEGIN
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
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Tasks] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Schedulers] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SessionTransactions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_ActiveTransactions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_DatabaseTransactions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_TempDbTaskUsage] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_ResourcePools] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SqlText] WHERE 1=0;';

            IF NOT EXISTS
            (
                SELECT 1
                FROM [#CurrentOverview_CurrentStateSnapshot_Context]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                  AND [OwnerSessionId]=CONVERT(smallint,@@SPID)
                  AND [ContractVersion]=2
            )
            BEGIN
                SET @StatusCode='INVALID_PARENT_SNAPSHOT';
                SET @IsPartial=1;
                SET @ErrorMessage=N'Die Parent-Snapshot-ID gehört nicht zum aktuellen Aufruf.';
            END
            ELSE
            BEGIN
                INSERT [#CurrentRequests_SourceSessions]
                SELECT [session_id],[is_user_process],[login_name],[original_login_name],[host_name],[program_name]
                FROM [#CurrentOverview_CurrentStateSnapshot_Sessions]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceRequests]
                SELECT
                      [session_id],[request_id],[status],[command],[database_id],[start_time]
                    , [total_elapsed_time],[cpu_time],[logical_reads],[reads],[writes],[row_count]
                    , [percent_complete],[estimated_completion_time],[blocking_session_id]
                    , [wait_type],[wait_time],[last_wait_type],[wait_resource],[dop]
                    , [parallel_worker_count],[transaction_isolation_level]
                    , [open_transaction_count],[open_resultset_count],[transaction_id]
                    , [scheduler_id],[task_address],[nest_level],[group_id]
                    , [statement_sql_handle],[statement_context_id],[is_resumable]
                    , [executing_managed_code],[context_info],[query_hash],[query_plan_hash]
                    , [sql_handle],[plan_handle],[statement_start_offset],[statement_end_offset]
                FROM [#CurrentOverview_CurrentStateSnapshot_Requests]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceConnections]
                SELECT
                      [session_id],[connection_id],[client_net_address]
                    , [net_transport],[protocol_type],[encrypt_option],[auth_scheme]
                FROM [#CurrentOverview_CurrentStateSnapshot_Connections]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceWaitingTasks]
                SELECT
                      [waiting_task_address],[session_id],[exec_context_id]
                    , [wait_duration_ms],[wait_type],[blocking_session_id],[resource_description]
                FROM [#CurrentOverview_CurrentStateSnapshot_WaitingTasks]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceMemoryGrants]
                SELECT [session_id],[request_id],[requested_memory_kb],[granted_memory_kb],[used_memory_kb],[ideal_memory_kb]
                FROM [#CurrentOverview_CurrentStateSnapshot_MemoryGrants]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceTasks]
                SELECT
                      [task_address],[task_state],[session_id],[request_id]
                    , [exec_context_id],[scheduler_id],[worker_address]
                FROM [#CurrentOverview_CurrentStateSnapshot_Tasks]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceSchedulers]
                SELECT
                      [scheduler_id],[scheduler_address],[parent_node_id],[status]
                    , [is_online],[is_idle],[current_tasks_count],[runnable_tasks_count]
                    , [current_workers_count],[active_workers_count],[work_queue_count]
                    , [pending_disk_io_count],[load_factor]
                FROM [#CurrentOverview_CurrentStateSnapshot_Schedulers]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceSessionTransactions]
                SELECT
                      [session_id],[transaction_id],[is_user_transaction],[is_local]
                    , [is_enlisted],[is_bound],[open_transaction_count]
                FROM [#CurrentOverview_CurrentStateSnapshot_SessionTransactions]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceActiveTransactions]
                SELECT
                      [transaction_id],[transaction_begin_time],[transaction_type],[transaction_state]
                FROM [#CurrentOverview_CurrentStateSnapshot_ActiveTransactions]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceDatabaseTransactions]
                SELECT
                      [transaction_id],[database_id],[database_transaction_log_bytes_used]
                    , [database_transaction_log_bytes_reserved]
                FROM [#CurrentOverview_CurrentStateSnapshot_DatabaseTransactions]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceTempDbSessionUsage]
                SELECT
                      [session_id],[user_objects_alloc_page_count],[user_objects_dealloc_page_count]
                    , [internal_objects_alloc_page_count],[internal_objects_dealloc_page_count]
                FROM [#CurrentOverview_CurrentStateSnapshot_TempDbSessionUsage]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceTempDbTaskUsage]
                SELECT
                      [session_id],[request_id],[exec_context_id]
                    , [user_objects_alloc_page_count],[user_objects_dealloc_page_count]
                    , [internal_objects_alloc_page_count],[internal_objects_dealloc_page_count]
                FROM [#CurrentOverview_CurrentStateSnapshot_TempDbTaskUsage]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceWorkloadGroups]
                SELECT [group_id],[name],[pool_id]
                FROM [#CurrentOverview_CurrentStateSnapshot_WorkloadGroups]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SourceResourcePools]
                SELECT [pool_id],[name]
                FROM [#CurrentOverview_CurrentStateSnapshot_ResourcePools]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                IF @SqlTextErforderlich=1
                    INSERT [#CurrentRequests_SourceSqlText]
                    SELECT [SqlHandle],[Text],[DatabaseId],[ObjectId],[ObjectNumber],[IsEncrypted]
                    FROM [#CurrentOverview_CurrentStateSnapshot_SqlText]
                    WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

                INSERT [#CurrentRequests_SnapshotStatus]
                (
                      [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject]
                    , [CapturedAtUtc],[CompletedAtUtc],[StatusCode],[IsPartial]
                    , [CapturedRowCount],[ErrorNumber],[ErrorMessage]
                )
                SELECT
                      [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject]
                    , [CapturedAtUtc],[CompletedAtUtc],[StatusCode],[IsPartial]
                    , [CapturedRowCount],[ErrorNumber],[ErrorMessage]
                FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                  AND [SourceCode] IN
                      ('SESSIONS','REQUESTS','CONNECTIONS','WAITING_TASKS','MEMORY_GRANTS',
                       'TASKS','SCHEDULERS','SESSION_TRANSACTIONS','ACTIVE_TRANSACTIONS',
                       'DATABASE_TRANSACTIONS','TEMPDB_SESSION_USAGE','TEMPDB_TASK_USAGE',
                       'WORKLOAD_GROUPS','RESOURCE_POOLS','SQL_TEXT');

                SELECT
                      @EvidenceSnapshotStartedAtUtc=MIN([CapturedAtUtc])
                    , @ParentSnapshotIsPartial=CONVERT(bit,MAX(CONVERT(int,[IsPartial])))
                FROM [#CurrentRequests_SnapshotStatus];
            END;
        END TRY
        BEGIN CATCH
            SELECT
                  @ErrorNumber=ERROR_NUMBER()
                , @ErrorMessage=ERROR_MESSAGE()
                , @IsPartial=1
                , @StatusCode=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                    WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                    ELSE 'INVALID_PARENT_SNAPSHOT' END;
        END CATCH;
    END
    ELSE IF @StatusCode='AVAILABLE'
    BEGIN TRY
        SET @EvidenceSnapshotStartedAtUtc=SYSUTCDATETIME();

        INSERT [#CurrentRequests_SourceSessions]
        SELECT [session_id],[is_user_process],[login_name],[original_login_name],[host_name],[program_name]
        FROM [sys].[dm_exec_sessions] WITH (NOLOCK);

        INSERT [#CurrentRequests_SourceRequests]
        SELECT
              [session_id],[request_id],[status],[command],[database_id],[start_time]
            , [total_elapsed_time],[cpu_time],[logical_reads],[reads],[writes],[row_count]
            , [percent_complete],[estimated_completion_time],[blocking_session_id]
            , [wait_type],[wait_time],[last_wait_type],[wait_resource],[dop]
            , [parallel_worker_count],[transaction_isolation_level]
            , [open_transaction_count],[open_resultset_count],[transaction_id]
            , [scheduler_id],[task_address],[nest_level],[group_id]
            , [statement_sql_handle],[statement_context_id],[is_resumable]
            , [executing_managed_code],[context_info],[query_hash],[query_plan_hash]
            , [sql_handle],[plan_handle],[statement_start_offset],[statement_end_offset]
        FROM [sys].[dm_exec_requests] WITH (NOLOCK);

        INSERT [#CurrentRequests_SourceConnections]
        SELECT
              [session_id],[connection_id],[client_net_address]
            , [net_transport],[protocol_type],[encrypt_option],[auth_scheme]
        FROM [sys].[dm_exec_connections] WITH (NOLOCK);

        INSERT [#CurrentRequests_SourceWaitingTasks]
        SELECT
              [waiting_task_address],[session_id],[exec_context_id]
            , [wait_duration_ms],[wait_type],[blocking_session_id],[resource_description]
        FROM [sys].[dm_os_waiting_tasks] WITH (NOLOCK);

        INSERT [#CurrentRequests_SourceMemoryGrants]
        SELECT [session_id],[request_id],[requested_memory_kb],[granted_memory_kb],[used_memory_kb],[ideal_memory_kb]
        FROM [sys].[dm_exec_query_memory_grants] WITH (NOLOCK);

        INSERT [#CurrentRequests_SourceWorkloadGroups]
        SELECT [group_id],[name],[pool_id]
        FROM [sys].[dm_resource_governor_workload_groups] WITH (NOLOCK);

        INSERT [#CurrentRequests_SourceResourcePools]
        SELECT [pool_id],[name]
        FROM [sys].[dm_resource_governor_resource_pools] WITH (NOLOCK);

        INSERT [#CurrentRequests_SourceTasks]
        SELECT
              [t].[task_address],[t].[task_state],[t].[session_id],[t].[request_id]
            , [t].[exec_context_id],[t].[scheduler_id],[t].[worker_address]
        FROM [sys].[dm_os_tasks] AS [t] WITH (NOLOCK)
        WHERE EXISTS
        (
            SELECT 1
            FROM [#CurrentRequests_SourceRequests] AS [r]
            WHERE [r].[session_id]=[t].[session_id]
              AND [r].[request_id]=[t].[request_id]
        );

        INSERT [#CurrentRequests_SourceSchedulers]
        SELECT
              [s].[scheduler_id],[s].[scheduler_address],[s].[parent_node_id],[s].[status]
            , [s].[is_online],[s].[is_idle],[s].[current_tasks_count],[s].[runnable_tasks_count]
            , [s].[current_workers_count],[s].[active_workers_count],[s].[work_queue_count]
            , [s].[pending_disk_io_count],[s].[load_factor]
        FROM [sys].[dm_os_schedulers] AS [s] WITH (NOLOCK)
        WHERE [s].[scheduler_id] < 1048576
          AND
          (
              EXISTS
              (
                  SELECT 1 FROM [#CurrentRequests_SourceRequests] AS [r]
                  WHERE [r].[scheduler_id]=[s].[scheduler_id]
              )
              OR EXISTS
              (
                  SELECT 1 FROM [#CurrentRequests_SourceTasks] AS [t]
                  WHERE [t].[scheduler_id]=[s].[scheduler_id]
              )
          );

        INSERT [#CurrentRequests_SourceSessionTransactions]
        SELECT
              [st].[session_id],[st].[transaction_id],[st].[is_user_transaction]
            , [st].[is_local],[st].[is_enlisted],[st].[is_bound],[st].[open_transaction_count]
        FROM [sys].[dm_tran_session_transactions] AS [st] WITH (NOLOCK)
        WHERE EXISTS
        (
            SELECT 1 FROM [#CurrentRequests_SourceRequests] AS [r]
            WHERE [r].[session_id]=[st].[session_id]
        );

        INSERT [#CurrentRequests_SourceActiveTransactions]
        SELECT
              [at].[transaction_id],[at].[transaction_begin_time]
            , [at].[transaction_type],[at].[transaction_state]
        FROM [sys].[dm_tran_active_transactions] AS [at] WITH (NOLOCK)
        WHERE EXISTS
        (
            SELECT 1 FROM [#CurrentRequests_SourceSessionTransactions] AS [st]
            WHERE [st].[transaction_id]=[at].[transaction_id]
        );

        INSERT [#CurrentRequests_SourceDatabaseTransactions]
        SELECT
              [dt].[transaction_id],[dt].[database_id]
            , [dt].[database_transaction_log_bytes_used]
            , [dt].[database_transaction_log_bytes_reserved]
        FROM [sys].[dm_tran_database_transactions] AS [dt] WITH (NOLOCK)
        WHERE EXISTS
        (
            SELECT 1 FROM [#CurrentRequests_SourceSessionTransactions] AS [st]
            WHERE [st].[transaction_id]=[dt].[transaction_id]
        );

        EXEC [sys].[sp_executesql] N'
            USE [tempdb];
            INSERT [#CurrentRequests_SourceTempDbSessionUsage]
            SELECT
                  [u].[session_id],[u].[user_objects_alloc_page_count]
                , [u].[user_objects_dealloc_page_count]
                , [u].[internal_objects_alloc_page_count]
                , [u].[internal_objects_dealloc_page_count]
            FROM [sys].[dm_db_session_space_usage] AS [u] WITH (NOLOCK)
            WHERE EXISTS
            (
                SELECT 1 FROM [#CurrentRequests_SourceRequests] AS [r]
                WHERE [r].[session_id]=[u].[session_id]
            );

            INSERT [#CurrentRequests_SourceTempDbTaskUsage]
            SELECT
                  [u].[session_id],[u].[request_id],[u].[exec_context_id]
                , [u].[user_objects_alloc_page_count]
                , [u].[user_objects_dealloc_page_count]
                , [u].[internal_objects_alloc_page_count]
                , [u].[internal_objects_dealloc_page_count]
            FROM [sys].[dm_db_task_space_usage] AS [u] WITH (NOLOCK)
            WHERE EXISTS
            (
                SELECT 1 FROM [#CurrentRequests_SourceRequests] AS [r]
                WHERE [r].[session_id]=[u].[session_id]
                  AND [r].[request_id]=[u].[request_id]
            );';

        IF @SqlTextErforderlich=1
        BEGIN
            INSERT [#CurrentRequests_SourceSqlText]
            ([SqlHandle],[text],[dbid],[objectid],[number],[encrypted])
            SELECT
                  [h].[SqlHandle],[t].[text],[t].[dbid],[t].[objectid],[t].[number],[t].[encrypted]
            FROM
            (
                SELECT [sql_handle] AS [SqlHandle]
                FROM [#CurrentRequests_SourceRequests]
                WHERE [sql_handle] IS NOT NULL
                GROUP BY [sql_handle]
            ) AS [h]
            OUTER APPLY [sys].[dm_exec_sql_text]([h].[SqlHandle]) AS [t];
        END;

        INSERT [#CurrentRequests_SnapshotStatus]
        (
              [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject]
            , [CapturedAtUtc],[CompletedAtUtc],[StatusCode],[IsPartial]
            , [CapturedRowCount],[ErrorNumber],[ErrorMessage]
        )
        SELECT
              [v].[SourceOrdinal],@EvidenceSnapshotId,[v].[SourceCode],[v].[SourceObject]
            , @EvidenceSnapshotStartedAtUtc,SYSUTCDATETIME(),'AVAILABLE',CONVERT(bit,0)
            , [v].[CapturedRowCount],NULL,NULL
        FROM
        (
            VALUES
              (10,'SESSIONS',N'sys.dm_exec_sessions',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceSessions])))
            , (20,'REQUESTS',N'sys.dm_exec_requests',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceRequests])))
            , (30,'CONNECTIONS',N'sys.dm_exec_connections',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceConnections])))
            , (40,'WAITING_TASKS',N'sys.dm_os_waiting_tasks',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceWaitingTasks])))
            , (50,'MEMORY_GRANTS',N'sys.dm_exec_query_memory_grants',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceMemoryGrants])))
            , (60,'WORKLOAD_GROUPS',N'sys.dm_resource_governor_workload_groups',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceWorkloadGroups])))
            , (70,'RESOURCE_POOLS',N'sys.dm_resource_governor_resource_pools',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceResourcePools])))
            , (90,'TASKS',N'sys.dm_os_tasks',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceTasks])))
            , (100,'SCHEDULERS',N'sys.dm_os_schedulers',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceSchedulers])))
            , (110,'SESSION_TRANSACTIONS',N'sys.dm_tran_session_transactions',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceSessionTransactions])))
            , (120,'ACTIVE_TRANSACTIONS',N'sys.dm_tran_active_transactions',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceActiveTransactions])))
            , (130,'DATABASE_TRANSACTIONS',N'sys.dm_tran_database_transactions',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceDatabaseTransactions])))
            , (140,'TEMPDB_SESSION_USAGE',N'tempdb.sys.dm_db_session_space_usage',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceTempDbSessionUsage])))
            , (150,'TEMPDB_TASK_USAGE',N'tempdb.sys.dm_db_task_space_usage',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceTempDbTaskUsage])))
            , (160,'SQL_TEXT',N'sys.dm_exec_sql_text',CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceSqlText])))
        ) AS [v]([SourceOrdinal],[SourceCode],[SourceObject],[CapturedRowCount]);
    END TRY
    BEGIN CATCH
        SELECT
              @ErrorNumber=ERROR_NUMBER()
            , @ErrorMessage=ERROR_MESSAGE()
            , @IsPartial=1
            , @StatusCode=CASE WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                ELSE 'ERROR_HANDLED' END;
    END CATCH;

    IF NOT EXISTS
    (
        SELECT 1 FROM [#CurrentRequests_SnapshotStatus]
        WHERE [SourceCode]='SQL_TEXT'
    )
    BEGIN
        INSERT [#CurrentRequests_SnapshotStatus]
        VALUES
        (
              160,@EvidenceSnapshotId,'SQL_TEXT',N'sys.dm_exec_sql_text'
            , @CollectionTimeUtc,SYSUTCDATETIME()
            , CASE WHEN @SqlTextErforderlich=0 THEN 'NOT_COLLECTED' ELSE @StatusCode END
            , CASE WHEN @SqlTextErforderlich=0 THEN 0 ELSE 1 END
            , 0,@ErrorNumber
            , CASE WHEN @SqlTextErforderlich=0
                   THEN N'SQL-Text wurde für diesen Aufruf nicht benötigt.'
                   ELSE @ErrorMessage END
        );
    END;

    IF @SqlTextErforderlich=0
    BEGIN
        UPDATE [#CurrentRequests_SnapshotStatus]
        SET [StatusCode]='NOT_COLLECTED',[IsPartial]=0,[ErrorNumber]=NULL,
            [ErrorMessage]=N'SQL-Text wurde für diesen Aufruf nicht benötigt.'
        WHERE [SourceCode]='SQL_TEXT';
    END;

    IF @StatusCode<>'AVAILABLE'
       AND NOT EXISTS (SELECT 1 FROM [#CurrentRequests_SnapshotStatus])
    BEGIN
        INSERT [#CurrentRequests_SnapshotStatus]
        VALUES
        (
              1,@EvidenceSnapshotId,'CURRENT_REQUESTS_SNAPSHOT'
            , N'CurrentRequests source materialization',@EvidenceSnapshotStartedAtUtc
            , SYSUTCDATETIME(),@StatusCode,1,0,@ErrorNumber,@ErrorMessage
        );
    END;

    SET @CandidateMaxZeilen =
        CASE
            WHEN @HasRegex = 1 OR @MaxZeilen IS NULL OR @MaxZeilen = 0
                THEN CONVERT(bigint, 9223372036854775807)
            ELSE CONVERT(bigint, @MaxZeilen) + 1
        END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN TRY
        INSERT [#CurrentRequests_Result]
        (
              [SessionId], [RequestId], [RequestStatus], [Command]
            , [DatabaseId], [DatabaseName], [LoginName], [OriginalLoginName]
            , [HostName], [ProgramName]
            , [IsToolBackgroundQuery], [ToolBackgroundRuleCode]
            , [ToolBackgroundCategory]
            , [ToolBackgroundDetection], [ToolBackgroundConfidence]
            , [StartTime], [ElapsedMs], [CpuMs]
            , [LogicalReads], [Reads], [Writes], [RowCount], [PercentComplete]
            , [EstimatedCompletionTimeMs], [BlockingSessionId], [WaitType]
            , [WaitTimeMs], [LastWaitType], [WaitResource], [WaitingTaskCount]
            , [MaxTaskWaitMs], [TaskWaitTypes], [RequestedMemoryMb]
            , [GrantedMemoryMb], [UsedMemoryMb], [IdealMemoryMb], [Dop]
            , [ParallelWorkerCount], [TransactionIsolationLevel]
            , [OpenTransactionCount], [OpenResultsetCount], [TransactionId]
            , [ConnectionId], [SchedulerId], [TaskAddress], [NestLevel]
            , [WorkloadGroupId], [WorkloadGroupName], [ResourcePoolId], [ResourcePoolName]
            , [StatementSqlHandle], [StatementContextId], [IsResumable]
            , [ExecutingManagedCode], [ContextInfo], [ClientNetAddress], [QueryHash]
            , [QueryPlanHash], [SqlHandle], [PlanHandle]
            , [SqlTextDatabaseId], [SqlTextObjectId], [SqlTextObjectNumber]
            , [SqlTextIsEncrypted], [ExecutionContextType]
            , [HasStatementOffsets], [IsStatementOffsetValid]
            , [StatementStartOffsetBytes], [StatementEndOffsetBytes]
            , [StatementStartCharacter], [StatementEndCharacter]
            , [StatementStartLine], [StatementEndLine]
            , [CurrentStatementCharacterCount], [CurrentStatementBytes], [CurrentStatementIsTruncated]
            , [BatchTextCharacterCount], [BatchTextBytes], [BatchTextIsTruncated]
            , [CurrentStatement], [BatchText]
            , [InputBufferEventType], [InputBufferParameterCount]
            , [InputBufferCharacterCount], [InputBufferBytes], [InputBufferIsTruncated]
            , [InputBufferText]
        )
        SELECT TOP (@CandidateMaxZeilen)
              [r].[session_id]
            , [r].[request_id]
            , [r].[status]
            , [r].[command]
            , [r].[database_id]
            , [d].[name]
            , [s].[login_name]
            , [s].[original_login_name]
            , [s].[host_name]
            , [s].[program_name]
            , [tool].[IsToolBackgroundQuery]
            , [tool].[ToolBackgroundRuleCode]
            , [tool].[ToolBackgroundCategory]
            , [tool].[ToolBackgroundDetection]
            , [tool].[ToolBackgroundConfidence]
            , [r].[start_time]
            , [r].[total_elapsed_time]
            , [r].[cpu_time]
            , [r].[logical_reads]
            , [r].[reads]
            , [r].[writes]
            , [r].[row_count]
            , [r].[percent_complete]
            , [r].[estimated_completion_time]
            , NULLIF([r].[blocking_session_id], 0)
            , [r].[wait_type]
            , [r].[wait_time]
            , [r].[last_wait_type]
            , [r].[wait_resource]
            , CONVERT(int, [wt].[WaitingTaskCount])
            , [wt].[MaxTaskWaitMs]
            , [wt].[TaskWaitTypes]
            , CONVERT(decimal(19,2), [mg].[requested_memory_kb] / 1024.0)
            , CONVERT(decimal(19,2), [mg].[granted_memory_kb] / 1024.0)
            , CONVERT(decimal(19,2), [mg].[used_memory_kb] / 1024.0)
            , CONVERT(decimal(19,2), [mg].[ideal_memory_kb] / 1024.0)
            , [r].[dop]
            , [r].[parallel_worker_count]
            , CASE [r].[transaction_isolation_level]
                  WHEN 0 THEN N'Unspecified'
                  WHEN 1 THEN N'ReadUncommitted'
                  WHEN 2 THEN N'ReadCommitted'
                  WHEN 3 THEN N'RepeatableRead'
                  WHEN 4 THEN N'Serializable'
                  WHEN 5 THEN N'Snapshot'
              END
            , [r].[open_transaction_count]
            , [r].[open_resultset_count]
            , [r].[transaction_id]
            , [c].[connection_id]
            , [r].[scheduler_id]
            , [r].[task_address]
            , [r].[nest_level]
            , [r].[group_id]
            , [wg].[name]
            , [rp].[pool_id]
            , [rp].[name]
            , [r].[statement_sql_handle]
            , [r].[statement_context_id]
            , [r].[is_resumable]
            , [r].[executing_managed_code]
            , [r].[context_info]
            , [c].[client_net_address]
            , [r].[query_hash]
            , [r].[query_plan_hash]
            , [r].[sql_handle]
            , [r].[plan_handle]
            , [txt].[dbid]
            , [txt].[objectid]
            , [txt].[number]
            , [txt].[encrypted]
            , CASE
                  WHEN [txt].[objectid] IS NOT NULL AND [txt].[objectid] > 0 THEN 'MODULE'
                  WHEN [txt].[text] IS NOT NULL THEN 'BATCH'
                  ELSE 'UNAVAILABLE'
              END
            , [st].[HasStatementOffsets]
            , [st].[IsStatementOffsetValid]
            , [st].[StatementStartOffsetBytes]
            , [st].[StatementEndOffsetBytes]
            , [st].[StatementStartCharacter]
            , [st].[StatementEndCharacter]
            , [st].[StatementStartLine]
            , [st].[StatementEndLine]
            , [st].[StatementCharacterCount]
            , NULL
            , CONVERT(bit, 0)
            , [st].[BatchCharacterCount]
            , NULL
            , CONVERT(bit, 0)
            , CASE WHEN @StatementTextErforderlich = 1 THEN [st].[StatementText] END
            , CASE WHEN @BatchTextErforderlich = 1 THEN [txt].[text] END
            , NULL
            , NULL
            , NULL
            , NULL
            , CONVERT(bit, 0)
            , NULL
        FROM [#CurrentRequests_SourceRequests] AS [r]
        JOIN [#CurrentRequests_SourceSessions] AS [s]
          ON [s].[session_id] = [r].[session_id]
        CROSS APPLY [monitor].[TVF_ToolBackgroundQueryInfo]([s].[program_name]) AS [tool]
        LEFT JOIN [#CurrentRequests_SourceConnections] AS [c]
          ON [c].[session_id] = [r].[session_id]
        LEFT JOIN [sys].[databases] AS [d] WITH (NOLOCK)
          ON [d].[database_id] = [r].[database_id]
        OUTER APPLY
        (
            SELECT
                  [WaitingTaskCount] = COUNT_BIG(*)
                , [MaxTaskWaitMs] = MAX(CONVERT(bigint, [w].[wait_duration_ms]))
                , [TaskWaitTypes] = STRING_AGG(CONVERT(nvarchar(max), [w].[wait_type]), N',')
                    WITHIN GROUP (ORDER BY [w].[wait_type])
            FROM [#CurrentRequests_SourceWaitingTasks] AS [w]
            WHERE [w].[session_id] = [r].[session_id]
        ) AS [wt]
        LEFT JOIN [#CurrentRequests_SourceMemoryGrants] AS [mg]
          ON [mg].[session_id] = [r].[session_id]
         AND [mg].[request_id] = [r].[request_id]
        LEFT JOIN [#CurrentRequests_SourceWorkloadGroups] AS [wg]
          ON [wg].[group_id] = [r].[group_id]
        LEFT JOIN [#CurrentRequests_SourceResourcePools] AS [rp]
          ON [rp].[pool_id] = [wg].[pool_id]
        LEFT JOIN [#CurrentRequests_SourceSqlText] AS [txt]
          ON [txt].[SqlHandle]=CASE WHEN @SqlTextErforderlich=1 THEN [r].[sql_handle] END
        OUTER APPLY [monitor].[TVF_StatementText]
        (
              [txt].[text]
            , [r].[statement_start_offset]
            , [r].[statement_end_offset]
        ) AS [st]
        WHERE
              (NOT EXISTS (SELECT 1 FROM [#CurrentRequests_SessionIdFilter])
               OR EXISTS
                  (SELECT 1 FROM [#CurrentRequests_SessionIdFilter] AS [f] WHERE [f].[SessionId] = [r].[session_id]))
          AND (@AktuelleSessionEinbeziehen = 1 OR [r].[session_id] <> @@SPID)
          AND (@SystemSessionsEinbeziehen = 1 OR [s].[is_user_process] = 1)
          AND (@ToolHintergrundabfragenEinbeziehen = 1 OR [tool].[IsToolBackgroundQuery] = 0)
          AND
          (
              @EigeneSessionsModus = 'ALLE'
              OR (@EigeneSessionsModus = 'NUR' AND [s].[original_login_name] = ORIGINAL_LOGIN())
              OR (@EigeneSessionsModus = 'AUSSCHLIESSEN' AND ISNULL([s].[original_login_name], N'') <> ORIGINAL_LOGIN())
          )
          AND (@NurBlockierte = 0 OR [r].[blocking_session_id] <> 0)
          AND (@NurMitWait = 0 OR [r].[wait_type] IS NOT NULL OR [wt].[WaitingTaskCount] > 0)
          AND (@MinLaufzeitSekunden IS NULL OR [r].[total_elapsed_time] >= @MinLaufzeitSekunden * 1000)
          AND (@MinCpuMs IS NULL OR [r].[cpu_time] >= @MinCpuMs)
          AND (@MinLogicalReads IS NULL OR [r].[logical_reads] >= @MinLogicalReads)
          AND
          (
              NOT EXISTS (SELECT 1 FROM [#CurrentRequests_StringFilter] WHERE [FilterType] = 'LOGIN')
              OR EXISTS
                 (
                     SELECT 1
                     FROM [#CurrentRequests_StringFilter] AS [f]
                     WHERE [f].[FilterType] = 'LOGIN'
                       AND [f].[StringValue] = [s].[login_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                 )
          )
          AND
          (
              NOT EXISTS (SELECT 1 FROM [#CurrentRequests_StringFilter] WHERE [FilterType] = 'HOST')
              OR EXISTS
                 (
                     SELECT 1
                     FROM [#CurrentRequests_StringFilter] AS [f]
                     WHERE [f].[FilterType] = 'HOST'
                       AND [f].[StringValue] = [s].[host_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                 )
          )
          AND
          (
              NOT EXISTS (SELECT 1 FROM [#CurrentRequests_StringFilter] WHERE [FilterType] = 'PROGRAM')
              OR EXISTS
                 (
                     SELECT 1
                     FROM [#CurrentRequests_StringFilter] AS [f]
                     WHERE [f].[FilterType] = 'PROGRAM'
                       AND [f].[StringValue] = [s].[program_name] COLLATE SQL_Latin1_General_CP1_CS_AS
                 )
          )
          AND
          (
              NOT EXISTS (SELECT 1 FROM [#CurrentRequests_StringFilter] WHERE [FilterType] = 'DATABASE')
              OR EXISTS
                 (
                     SELECT 1
                     FROM [#CurrentRequests_StringFilter] AS [f]
                     WHERE [f].[FilterType] = 'DATABASE'
                       AND [f].[StringValue] = [d].[name] COLLATE SQL_Latin1_General_CP1_CS_AS
                 )
          )
          AND (@LoginMode <> 'LIKE' OR [s].[login_name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @LoginPattern COLLATE SQL_Latin1_General_CP1_CS_AS)
          AND (@HostMode <> 'LIKE' OR [s].[host_name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @HostPattern COLLATE SQL_Latin1_General_CP1_CS_AS)
          AND (@ProgramMode <> 'LIKE' OR [s].[program_name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @ProgramPattern COLLATE SQL_Latin1_General_CP1_CS_AS)
          AND (@DatabaseMode <> 'LIKE' OR [d].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @DatabasePattern COLLATE SQL_Latin1_General_CP1_CS_AS)
          AND
          (
              @TextMode <> 'LIKE'
              OR [st].[StatementText] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @TextPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS
              OR [txt].[text] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @TextPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS
          )
        ORDER BY
              CASE
                  WHEN @Sortierung = 'RELEVANZ'
                      THEN CASE
                               WHEN [r].[blocking_session_id] <> 0 THEN 3
                               WHEN [r].[wait_type] IS NOT NULL THEN 2
                               ELSE 1
                           END
              END DESC
            , CASE WHEN @Sortierung = 'CPU' THEN [r].[cpu_time] END DESC
            , CASE WHEN @Sortierung = 'READS' THEN [r].[logical_reads] END DESC
            , CASE WHEN @Sortierung = 'DAUER' THEN [r].[total_elapsed_time] END DESC
            , [r].[session_id]
            , [r].[request_id];

        IF @HasRegex = 1
        BEGIN
            DECLARE @Sql nvarchar(max) = N'';

            IF @LoginMode IN ('REGEX', 'REGEXI')
                SET @Sql += N'DELETE FROM [#CurrentRequests_Result] WHERE [LoginName] IS NULL OR NOT REGEXP_LIKE([LoginName],@LoginPattern,@LoginFlags);';
            IF @HostMode IN ('REGEX', 'REGEXI')
                SET @Sql += N'DELETE FROM [#CurrentRequests_Result] WHERE [HostName] IS NULL OR NOT REGEXP_LIKE([HostName],@HostPattern,@HostFlags);';
            IF @ProgramMode IN ('REGEX', 'REGEXI')
                SET @Sql += N'DELETE FROM [#CurrentRequests_Result] WHERE [ProgramName] IS NULL OR NOT REGEXP_LIKE([ProgramName],@ProgramPattern,@ProgramFlags);';
            IF @DatabaseMode IN ('REGEX', 'REGEXI')
                SET @Sql += N'DELETE FROM [#CurrentRequests_Result] WHERE [DatabaseName] IS NULL OR NOT REGEXP_LIKE([DatabaseName],@DatabasePattern,@DatabaseFlags);';
            IF @TextMode IN ('REGEX', 'REGEXI')
                SET @Sql += N'DELETE FROM [#CurrentRequests_Result] WHERE COALESCE([CurrentStatement],[BatchText]) IS NULL OR (NOT REGEXP_LIKE(COALESCE([CurrentStatement],N''''),@TextPattern,@TextFlags) AND NOT REGEXP_LIKE(COALESCE([BatchText],N''''),@TextPattern,@TextFlags));';

            EXEC [sys].[sp_executesql]
                  @Sql
                , N'@LoginPattern nvarchar(4000),@LoginFlags varchar(8),@HostPattern nvarchar(4000),@HostFlags varchar(8),@ProgramPattern nvarchar(4000),@ProgramFlags varchar(8),@DatabasePattern nvarchar(4000),@DatabaseFlags varchar(8),@TextPattern nvarchar(4000),@TextFlags varchar(8)'
                , @LoginPattern
                , @LoginFlags
                , @HostPattern
                , @HostFlags
                , @ProgramPattern
                , @ProgramFlags
                , @DatabasePattern
                , @DatabaseFlags
                , @TextPatternValue
                , @TextFlags;
        END;

        IF @MaxZeilen IS NOT NULL AND @MaxZeilen > 0
        BEGIN
            IF (SELECT COUNT_BIG(*) FROM [#CurrentRequests_Result]) > @MaxZeilen
            BEGIN
                SET @HasMoreRows = 1;
            END;

            ;WITH [Ranked] AS
            (
                SELECT
                      [RowNumber] = ROW_NUMBER() OVER
                        (
                            ORDER BY
                                  CASE
                                      WHEN @Sortierung = 'RELEVANZ'
                                          THEN CASE
                                                   WHEN [BlockingSessionId] IS NOT NULL THEN 3
                                                   WHEN [WaitType] IS NOT NULL THEN 2
                                                   ELSE 1
                                               END
                                  END DESC
                                , CASE WHEN @Sortierung = 'CPU' THEN [CpuMs] END DESC
                                , CASE WHEN @Sortierung = 'READS' THEN [LogicalReads] END DESC
                                , CASE WHEN @Sortierung = 'DAUER' THEN [ElapsedMs] END DESC
                                , [SessionId]
                                , [RequestId]
                        )
                    , *
                FROM [#CurrentRequests_Result]
            )
            DELETE FROM [Ranked]
            WHERE [RowNumber] > @MaxZeilen;
        END;


        IF @ModulInfoEinbeziehen = 1
        BEGIN
            CREATE TABLE [#CurrentRequests_ModuleLookup]
            (
                  [SqlTextDatabaseId] int NOT NULL
                , [SqlTextObjectId] int NOT NULL
                , [ModuleDatabaseName] sysname NULL
                , [ModuleSchemaName] sysname NULL
                , [ModuleObjectName] sysname NULL
                , [ModuleType] char(2) NULL
                , [ModuleTypeDescription] nvarchar(60) NULL
                , [ModuleFullName] nvarchar(776) NULL
                , PRIMARY KEY ([SqlTextDatabaseId], [SqlTextObjectId])
            );

            INSERT [#CurrentRequests_ModuleLookup] ([SqlTextDatabaseId], [SqlTextObjectId])
            SELECT DISTINCT [SqlTextDatabaseId], [SqlTextObjectId]
            FROM [#CurrentRequests_Result]
            WHERE [SqlTextDatabaseId] IS NOT NULL
              AND [SqlTextObjectId] IS NOT NULL
              AND [SqlTextObjectId] > 0;

            DECLARE @LookupDatabaseId int;
            DECLARE @LookupDatabaseName sysname;
            DECLARE @LookupSql nvarchar(max);

            DECLARE [ModuleDatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT [d].[database_id], [d].[name]
                FROM [#CurrentRequests_ModuleLookup] AS [m]
                JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
                  ON [d].[database_id] = [m].[SqlTextDatabaseId]
                WHERE [d].[state] = 0
                ORDER BY [d].[database_id];

            OPEN [ModuleDatabaseCursor];
            FETCH NEXT FROM [ModuleDatabaseCursor] INTO @LookupDatabaseId, @LookupDatabaseName;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                BEGIN TRY
                    SET @LookupSql =
                        N'USE ' + QUOTENAME(@LookupDatabaseName) + N';
                          UPDATE [m]
                          SET [ModuleDatabaseName] = @DatabaseName,
                              [ModuleSchemaName] = [s].[name],
                              [ModuleObjectName] = [o].[name],
                              [ModuleType] = [o].[type],
                              [ModuleTypeDescription] = [o].[type_desc],
                              [ModuleFullName] = QUOTENAME(@DatabaseName) + N''.'' + QUOTENAME([s].[name]) + N''.'' + QUOTENAME([o].[name])
                          FROM [#CurrentRequests_ModuleLookup] AS [m]
                          JOIN [sys].[objects] AS [o] WITH (NOLOCK)
                            ON [o].[object_id] = [m].[SqlTextObjectId]
                          JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                            ON [s].[schema_id] = [o].[schema_id]
                          WHERE [m].[SqlTextDatabaseId] = @DatabaseId;';

                    EXEC [sys].[sp_executesql]
                          @LookupSql
                        , N'@DatabaseId int, @DatabaseName sysname'
                        , @DatabaseId = @LookupDatabaseId
                        , @DatabaseName = @LookupDatabaseName;
                END TRY
                BEGIN CATCH
                    INSERT [#CurrentRequests_Warnings]
                    (
                          [DatabaseName], [Code], [Message]
                    )
                    VALUES
                    (
                          @LookupDatabaseName
                        , CASE
                              WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371, 916) THEN 'MODULE_LOOKUP_DENIED'
                              WHEN ERROR_NUMBER() = 1222 THEN 'MODULE_LOOKUP_TIMEOUT'
                              ELSE 'MODULE_LOOKUP_FAILED'
                          END
                        , ERROR_MESSAGE()
                    );

                    SET @IsPartial = 1;
                END CATCH;

                FETCH NEXT FROM [ModuleDatabaseCursor] INTO @LookupDatabaseId, @LookupDatabaseName;
            END;

            CLOSE [ModuleDatabaseCursor];
            DEALLOCATE [ModuleDatabaseCursor];

            UPDATE [r]
            SET
                  [ModuleDatabaseName] = [m].[ModuleDatabaseName]
                , [ModuleSchemaName] = [m].[ModuleSchemaName]
                , [ModuleObjectName] = [m].[ModuleObjectName]
                , [ModuleType] = [m].[ModuleType]
                , [ModuleTypeDescription] = [m].[ModuleTypeDescription]
                , [ModuleFullName] = [m].[ModuleFullName]
            FROM [#CurrentRequests_Result] AS [r]
            JOIN [#CurrentRequests_ModuleLookup] AS [m]
              ON [m].[SqlTextDatabaseId] = [r].[SqlTextDatabaseId]
             AND [m].[SqlTextObjectId] = [r].[SqlTextObjectId];
        END;

        INSERT [#CurrentRequests_SnapshotStatus]
        (
              [SourceOrdinal],[SnapshotId],[SourceCode],[SourceObject]
            , [CapturedAtUtc],[CompletedAtUtc],[StatusCode],[IsPartial]
            , [CapturedRowCount],[ErrorNumber],[ErrorMessage]
        )
        SELECT
              180,@EvidenceSnapshotId,'MODULE_CATALOG',N'<database>.sys.objects|sys.schemas'
            , @CollectionTimeUtc,SYSUTCDATETIME()
            , CASE
                  WHEN @ModulInfoEinbeziehen=0 THEN 'NOT_COLLECTED'
                  WHEN EXISTS
                       (
                           SELECT 1 FROM [#CurrentRequests_Warnings]
                           WHERE [Code] LIKE 'MODULE_LOOKUP_%'
                       ) THEN 'PARTIAL_RESULT'
                  ELSE 'AVAILABLE'
              END
            , CONVERT(bit,CASE WHEN EXISTS
              (
                  SELECT 1 FROM [#CurrentRequests_Warnings]
                  WHERE [Code] LIKE 'MODULE_LOOKUP_%'
              ) THEN 1 ELSE 0 END)
            , CONVERT(bigint,(SELECT COUNT_BIG(*) FROM [#CurrentRequests_Result] WHERE [ModuleFullName] IS NOT NULL))
            , NULL
            , CASE WHEN @ModulInfoEinbeziehen=0 THEN N'Die Modulauflösung wurde nicht angefordert.' END;

        IF @InputBufferEinbeziehen = 1
        BEGIN
            DECLARE @InputBufferCapturedAtUtc datetime2(3)=SYSUTCDATETIME();
            BEGIN TRY
                INSERT [#CurrentRequests_SourceInputBuffer]
                (
                    [session_id],[request_id],[event_type],[parameters],[event_info]
                )
                SELECT
                      [r].[SessionId],[r].[RequestId]
                    , [ib].[event_type],[ib].[parameters],[ib].[event_info]
                FROM [#CurrentRequests_Result] AS [r]
                OUTER APPLY [sys].[dm_exec_input_buffer]
                (
                      [r].[SessionId]
                    , [r].[RequestId]
                ) AS [ib];

                UPDATE [r]
                SET
                      [InputBufferEventType]=[ib].[event_type]
                    , [InputBufferParameterCount]=[ib].[parameters]
                    , [InputBufferText]=[ib].[event_info]
                FROM [#CurrentRequests_Result] AS [r]
                LEFT JOIN [#CurrentRequests_SourceInputBuffer] AS [ib]
                  ON [ib].[session_id]=[r].[SessionId]
                 AND [ib].[request_id]=[r].[RequestId];

                INSERT [#CurrentRequests_SnapshotStatus]
                VALUES
                (
                      170,@EvidenceSnapshotId,'INPUT_BUFFER',N'sys.dm_exec_input_buffer'
                    , @InputBufferCapturedAtUtc,SYSUTCDATETIME(),'AVAILABLE',0
                    , (SELECT COUNT_BIG(*) FROM [#CurrentRequests_SourceInputBuffer]),NULL,NULL
                );
            END TRY
            BEGIN CATCH
                INSERT [#CurrentRequests_SnapshotStatus]
                VALUES
                (
                      170,@EvidenceSnapshotId,'INPUT_BUFFER',N'sys.dm_exec_input_buffer'
                    , @InputBufferCapturedAtUtc,SYSUTCDATETIME()
                    , CASE
                          WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                          WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                          ELSE 'ERROR_HANDLED'
                      END
                    , 1,0,ERROR_NUMBER(),ERROR_MESSAGE()
                );
                SET @IsPartial=1;
            END CATCH;
        END
        ELSE
        BEGIN
            INSERT [#CurrentRequests_SnapshotStatus]
            VALUES
            (
                  170,@EvidenceSnapshotId,'INPUT_BUFFER',N'sys.dm_exec_input_buffer'
                , @CollectionTimeUtc,SYSUTCDATETIME(),'NOT_COLLECTED',0,0,NULL
                , N'Der Input Buffer wurde nicht angefordert.'
            );
        END;

        UPDATE [r]
        SET [CurrentStatement]=CASE WHEN @MitSqlText=1 THEN [CurrentStatement] END,
            [BatchText]=CASE WHEN @GesamtenSqlTextEinbeziehen=1 THEN [BatchText] END,
            [InputBufferText]=CASE WHEN @InputBufferEinbeziehen=1 THEN [InputBufferText] END
        FROM [#CurrentRequests_Result] AS [r];

        DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
        DECLARE @ColumnTruncatedCount bigint=0,@ColumnLargestCharacters bigint=NULL;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentRequests_Result',@TextColumn=N'CurrentStatement'
            , @CharactersColumn=N'CurrentStatementCharacterCount',@BytesColumn=N'CurrentStatementBytes'
            , @IsTruncatedColumn=N'CurrentStatementIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
        SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
               @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentRequests_Result',@TextColumn=N'BatchText'
            , @CharactersColumn=N'BatchTextCharacterCount',@BytesColumn=N'BatchTextBytes'
            , @IsTruncatedColumn=N'BatchTextIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
        SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
               @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentRequests_Result',@TextColumn=N'InputBufferText'
            , @CharactersColumn=N'InputBufferCharacterCount',@BytesColumn=N'InputBufferBytes'
            , @IsTruncatedColumn=N'InputBufferIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
        SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
               @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
        EXEC [monitor].[InternalEmitTruncationWarning]
              @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen'
            , @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters
            , @PrintMeldungen=@PrintMeldungen;

        INSERT [#CurrentRequests_RequestContext]
        (
              [SnapshotId],[CapturedAtUtc],[SessionId],[RequestId],[RequestStatus],[Command]
            , [DatabaseId],[DatabaseName],[StartTime],[ElapsedMs],[CpuMs],[LogicalReads]
            , [Reads],[Writes],[RowCount],[PercentComplete],[EstimatedCompletionTimeMs]
            , [BlockingSessionId],[WaitType],[WaitTimeMs],[WaitResource]
            , [ConnectionId],[ClientNetAddress],[NetTransport],[ProtocolType],[EncryptOption],[AuthScheme]
            , [TaskCount],[WorkerCount],[ExecutionContextCount],[RunnableTaskCount],[SuspendedTaskCount]
            , [SchedulerId],[SchedulerStatus],[SchedulerParentNodeId],[SchedulerRunnableTaskCount]
            , [SchedulerWorkQueueCount],[SchedulerPendingDiskIoCount],[SchedulerLoadFactor]
            , [TransactionId],[TransactionBeginTime],[TransactionAgeSeconds],[TransactionType]
            , [TransactionState],[IsUserTransaction],[IsLocalTransaction],[IsEnlistedTransaction]
            , [IsBoundTransaction],[TransactionLogBytesUsed],[TransactionLogBytesReserved]
            , [RequestedMemoryMb],[GrantedMemoryMb],[UsedMemoryMb],[IdealMemoryMb]
            , [TempDbSessionNetMb],[TempDbRequestNetMb],[Dop],[ParallelWorkerCount]
            , [WorkloadGroupId],[WorkloadGroupName],[ResourcePoolId],[ResourcePoolName]
            , [QueryHash],[QueryPlanHash],[SqlHandle],[PlanHandle],[StatementSqlHandle]
            , [StatementContextId],[ModuleFullName],[IsCurrent],[StatusCode],[IsPartial],[EvidenceBoundary]
        )
        SELECT
              @EvidenceSnapshotId
            , COALESCE
              (
                  (SELECT [CapturedAtUtc] FROM [#CurrentRequests_SnapshotStatus] WHERE [SourceCode]='REQUESTS')
                , @EvidenceSnapshotStartedAtUtc
              )
            , [r].[SessionId],[r].[RequestId],[r].[RequestStatus],[r].[Command]
            , [r].[DatabaseId],[r].[DatabaseName],[r].[StartTime],[r].[ElapsedMs],[r].[CpuMs]
            , [r].[LogicalReads],[r].[Reads],[r].[Writes],[r].[RowCount],[r].[PercentComplete]
            , [r].[EstimatedCompletionTimeMs],[r].[BlockingSessionId],[r].[WaitType]
            , COALESCE([wt].[MaxTaskWaitMs],[r].[WaitTimeMs])
            , COALESCE([wt].[WaitResource],[r].[WaitResource])
            , [c].[connection_id],[c].[client_net_address],[c].[net_transport]
            , [c].[protocol_type],[c].[encrypt_option],[c].[auth_scheme]
            , CONVERT(int,[task].[TaskCount]),CONVERT(int,[task].[WorkerCount])
            , CONVERT(int,[task].[ExecutionContextCount]),CONVERT(int,[task].[RunnableTaskCount])
            , CONVERT(int,[task].[SuspendedTaskCount])
            , [r].[SchedulerId],[sch].[status],[sch].[parent_node_id],[sch].[runnable_tasks_count]
            , [sch].[work_queue_count],[sch].[pending_disk_io_count],[sch].[load_factor]
            , [r].[TransactionId],[at].[transaction_begin_time]
            , CASE WHEN [at].[transaction_begin_time] IS NULL THEN NULL
                   ELSE DATEDIFF_BIG(SECOND,[at].[transaction_begin_time],@CollectionTimeUtc) END
            , [at].[transaction_type],[at].[transaction_state],[st].[is_user_transaction]
            , [st].[is_local],[st].[is_enlisted],[st].[is_bound]
            , [dt].[LogBytesUsed],[dt].[LogBytesReserved]
            , [r].[RequestedMemoryMb],[r].[GrantedMemoryMb],[r].[UsedMemoryMb],[r].[IdealMemoryMb]
            , CONVERT(decimal(19,2),
                (
                    COALESCE([ts].[user_objects_alloc_page_count],0)
                  - COALESCE([ts].[user_objects_dealloc_page_count],0)
                  + COALESCE([ts].[internal_objects_alloc_page_count],0)
                  - COALESCE([ts].[internal_objects_dealloc_page_count],0)
                )*8.0/1024.0)
            , CONVERT(decimal(19,2),COALESCE([tt].[NetPages],0)*8.0/1024.0)
            , CONVERT(smallint,[r].[Dop]),[r].[ParallelWorkerCount]
            , [r].[WorkloadGroupId],[r].[WorkloadGroupName],[r].[ResourcePoolId],[r].[ResourcePoolName]
            , [r].[QueryHash],[r].[QueryPlanHash],[r].[SqlHandle],[r].[PlanHandle]
            , [r].[StatementSqlHandle],[r].[StatementContextId],[r].[ModuleFullName]
            , CONVERT(bit,1)
            , CASE WHEN @ParentSnapshotIsPartial=1 OR @IsPartial=1 THEN 'AVAILABLE_LIMITED' ELSE 'AVAILABLE' END
            , CONVERT(bit,CASE WHEN @ParentSnapshotIsPartial=1 OR @IsPartial=1 THEN 1 ELSE 0 END)
            , CASE
                  WHEN @ParentCurrentStateSnapshotId IS NULL
                      THEN N'Frische, aufruflokale Quellen; Quellzeitpunkte sind nicht transaktional atomar.'
                  ELSE N'Gemeinsamer Overview-Snapshot; Quellzeitpunkte sind je DMV ausgewiesen und nicht transaktional atomar.'
              END
        FROM [#CurrentRequests_Result] AS [r]
        LEFT JOIN [#CurrentRequests_SourceConnections] AS [c]
          ON [c].[connection_id]=[r].[ConnectionId]
        LEFT JOIN [#CurrentRequests_SourceSchedulers] AS [sch]
          ON [sch].[scheduler_id]=[r].[SchedulerId]
        LEFT JOIN [#CurrentRequests_SourceSessionTransactions] AS [st]
          ON [st].[session_id]=[r].[SessionId]
         AND [st].[transaction_id]=[r].[TransactionId]
        LEFT JOIN [#CurrentRequests_SourceActiveTransactions] AS [at]
          ON [at].[transaction_id]=[r].[TransactionId]
        LEFT JOIN [#CurrentRequests_SourceTempDbSessionUsage] AS [ts]
          ON [ts].[session_id]=[r].[SessionId]
        OUTER APPLY
        (
            SELECT
                  [TaskCount]=COUNT_BIG(*)
                , [WorkerCount]=COUNT_BIG(DISTINCT [t].[worker_address])
                , [ExecutionContextCount]=COUNT_BIG(DISTINCT [t].[exec_context_id])
                , [RunnableTaskCount]=SUM(CASE WHEN [t].[task_state]=N'RUNNABLE' THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END)
                , [SuspendedTaskCount]=SUM(CASE WHEN [t].[task_state]=N'SUSPENDED' THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END)
            FROM [#CurrentRequests_SourceTasks] AS [t]
            WHERE [t].[session_id]=[r].[SessionId]
              AND [t].[request_id]=[r].[RequestId]
        ) AS [task]
        OUTER APPLY
        (
            SELECT
                  [MaxTaskWaitMs]=MAX([w].[wait_duration_ms])
                , [WaitResource]=MAX([w].[resource_description])
            FROM [#CurrentRequests_SourceWaitingTasks] AS [w]
            LEFT JOIN [#CurrentRequests_SourceTasks] AS [t]
              ON [t].[task_address]=[w].[waiting_task_address]
            WHERE [w].[session_id]=[r].[SessionId]
              AND ([t].[request_id]=[r].[RequestId] OR [t].[request_id] IS NULL)
        ) AS [wt]
        OUTER APPLY
        (
            SELECT
                  [LogBytesUsed]=SUM([d].[database_transaction_log_bytes_used])
                , [LogBytesReserved]=SUM([d].[database_transaction_log_bytes_reserved])
            FROM [#CurrentRequests_SourceDatabaseTransactions] AS [d]
            WHERE [d].[transaction_id]=[r].[TransactionId]
        ) AS [dt]
        OUTER APPLY
        (
            SELECT [NetPages]=SUM
            (
                  [u].[user_objects_alloc_page_count]-[u].[user_objects_dealloc_page_count]
                + [u].[internal_objects_alloc_page_count]-[u].[internal_objects_dealloc_page_count]
            )
            FROM [#CurrentRequests_SourceTempDbTaskUsage] AS [u]
            WHERE [u].[session_id]=[r].[SessionId]
              AND [u].[request_id]=[r].[RequestId]
        ) AS [tt];

        INSERT [#CurrentRequests_Statements]
        SELECT
              @EvidenceSnapshotId,[r].[SessionId],[r].[RequestId],'SQL_TEXT'
            , COALESCE((SELECT [CapturedAtUtc] FROM [#CurrentRequests_SnapshotStatus] WHERE [SourceCode]='SQL_TEXT'),@EvidenceSnapshotStartedAtUtc)
            , [r].[HasStatementOffsets],[r].[IsStatementOffsetValid]
            , [r].[StatementStartOffsetBytes],[r].[StatementEndOffsetBytes]
            , [r].[StatementStartCharacter],[r].[StatementEndCharacter]
            , [r].[StatementStartLine],[r].[StatementEndLine]
            , [r].[CurrentStatementCharacterCount],[r].[CurrentStatementBytes]
            , COALESCE([r].[CurrentStatementIsTruncated],0)
            , CASE
                  WHEN @MitSqlText=0 THEN 'NOT_COLLECTED'
                  WHEN [r].[SqlTextIsEncrypted]=1 THEN 'ENCRYPTED'
                  WHEN [r].[HasStatementOffsets]=1 AND [r].[IsStatementOffsetValid]=0 THEN 'INVALID_OFFSETS'
                  WHEN [r].[CurrentStatement] IS NULL THEN 'TEXT_UNAVAILABLE'
                  WHEN [r].[CurrentStatementIsTruncated]=1 THEN 'TEXT_TRUNCATED'
                  ELSE 'AVAILABLE'
              END
            , CASE
                  WHEN @MitSqlText=0 THEN N'Der Statementtext wurde nicht angefordert.'
                  WHEN [r].[SqlTextIsEncrypted]=1 THEN N'Der SQL-Text ist verschlüsselt.'
                  WHEN [r].[HasStatementOffsets]=1 AND [r].[IsStatementOffsetValid]=0 THEN N'Die Request-Offsets sind für den gelesenen Batch ungültig.'
                  WHEN [r].[CurrentStatement] IS NULL THEN N'Für den erfassten Request war kein Statementtext verfügbar.'
              END
            , [r].[CurrentStatement]
        FROM [#CurrentRequests_Result] AS [r];

        INSERT [#CurrentRequests_Batches]
        SELECT
              @EvidenceSnapshotId,[r].[SessionId],[r].[RequestId],'SQL_TEXT'
            , COALESCE((SELECT [CapturedAtUtc] FROM [#CurrentRequests_SnapshotStatus] WHERE [SourceCode]='SQL_TEXT'),@EvidenceSnapshotStartedAtUtc)
            , [r].[SqlTextDatabaseId],[r].[SqlTextObjectId],[r].[SqlTextObjectNumber]
            , [r].[SqlTextIsEncrypted],[r].[BatchTextCharacterCount],[r].[BatchTextBytes]
            , COALESCE([r].[BatchTextIsTruncated],0)
            , CASE
                  WHEN @GesamtenSqlTextEinbeziehen=0 THEN 'NOT_COLLECTED'
                  WHEN [r].[SqlTextIsEncrypted]=1 THEN 'ENCRYPTED'
                  WHEN [r].[BatchText] IS NULL THEN 'TEXT_UNAVAILABLE'
                  WHEN [r].[BatchTextIsTruncated]=1 THEN 'TEXT_TRUNCATED'
                  ELSE 'AVAILABLE'
              END
            , CASE
                  WHEN @GesamtenSqlTextEinbeziehen=0 THEN N'Der Batchtext wurde nicht angefordert.'
                  WHEN [r].[SqlTextIsEncrypted]=1 THEN N'Der SQL-Text ist verschlüsselt.'
                  WHEN [r].[BatchText] IS NULL THEN N'Für den erfassten Request war kein Batchtext verfügbar.'
              END
            , [r].[BatchText]
        FROM [#CurrentRequests_Result] AS [r];

        INSERT [#CurrentRequests_InputBuffers]
        SELECT
              @EvidenceSnapshotId,[r].[SessionId],[r].[RequestId],'INPUT_BUFFER'
            , COALESCE((SELECT [CapturedAtUtc] FROM [#CurrentRequests_SnapshotStatus] WHERE [SourceCode]='INPUT_BUFFER'),@CollectionTimeUtc)
            , [r].[InputBufferEventType],[r].[InputBufferParameterCount]
            , [r].[InputBufferCharacterCount],[r].[InputBufferBytes]
            , COALESCE([r].[InputBufferIsTruncated],0)
            , CASE
                  WHEN @InputBufferEinbeziehen=0 THEN 'NOT_COLLECTED'
                  WHEN [ibs].[StatusCode] NOT IN ('AVAILABLE') THEN [ibs].[StatusCode]
                  WHEN [r].[InputBufferText] IS NULL THEN 'REQUEST_FINISHED'
                  WHEN [r].[InputBufferIsTruncated]=1 THEN 'TEXT_TRUNCATED'
                  ELSE 'AVAILABLE'
              END
            , CASE
                  WHEN @InputBufferEinbeziehen=0 THEN N'Der Input Buffer wurde nicht angefordert.'
                  WHEN [ibs].[StatusCode] NOT IN ('AVAILABLE') THEN [ibs].[ErrorMessage]
                  WHEN [r].[InputBufferText] IS NULL THEN N'Der Request war beim späteren Input-Buffer-Lesezeitpunkt nicht mehr verfügbar.'
              END
            , [r].[InputBufferText]
        FROM [#CurrentRequests_Result] AS [r]
        LEFT JOIN [#CurrentRequests_SnapshotStatus] AS [ibs]
          ON [ibs].[SourceCode]='INPUT_BUFFER';

        SELECT @RowCount = COUNT_BIG(*)
        FROM [#CurrentRequests_Result];

        IF @HasFullView=0 OR @ParentSnapshotIsPartial=1
        BEGIN
            SET @StatusCode='AVAILABLE_LIMITED';
            SET @IsPartial=1;
            SET @Detail=N'Mindestens eine Current-State-Quelle war nur eingeschränkt verfügbar.';
        END;
        ELSE IF @IsPartial=1
        BEGIN
            SET @StatusCode='PARTIAL_RESULT';
            SET @Detail=N'Requests wurden gelesen; mindestens eine optionale Modulauflösung war nicht vollständig möglich.';
        END;
        ELSE
        BEGIN
            SET @Detail=N'Aktive Requests aus einer frischen laufinternen Evidenzbasis gelesen.';
        END;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();
        SET @IsPartial = 1;
        SET @StatusCode =
            CASE
                WHEN @ErrorNumber IN (229, 262, 297, 300, 371, 916) THEN 'DENIED_PERMISSION'
                WHEN @ErrorNumber = 1222 THEN 'TIMEOUT'
                WHEN @ErrorNumber IN (207, 208, 4121) THEN 'UNAVAILABLE_OBJECT'
                ELSE 'ERROR_HANDLED'
            END;
    END CATCH;

    IF @PrintMeldungen = 1 AND @StatusCode <> 'AVAILABLE'
    BEGIN
        SET @MonitorPrintMessage = FORMATMESSAGE
        (
              N'WARNUNG %s: %s'
            , @StatusCode
            , COALESCE(@ErrorMessage, @Detail, N'eingeschränkte Sicht')
        );
        RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  @ModuleName AS [resultName]
                , 4 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @EvidenceSnapshotStartedAtUtc AS [evidenceSnapshotStartedAtUtc]
                , @EvidenceSnapshotId AS [evidenceSnapshotId]
                , @StatusCode AS [statusCode]
                , @IsPartial AS [isPartial]
                , @MaxZeilen AS [requestedMaxRows]
                , @RowCount AS [returnedRows]
                , @HasMoreRows AS [hasMoreRows]
                , @MitSqlText AS [statementTextIncluded]
                , @GesamtenSqlTextEinbeziehen AS [batchTextIncluded]
                , @InputBufferEinbeziehen AS [inputBufferIncluded]
                , @ModulInfoEinbeziehen AS [moduleInfoIncluded]
                , @MaxSqlTextZeichen AS [maxSqlTextCharacters]
                , @ToolHintergrundabfragenEinbeziehen AS [toolBackgroundQueriesIncluded]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );

        DECLARE @RequestsJson nvarchar(max) =
        (
            SELECT
                  [r].[SessionId] AS [sessionId]
                , [r].[RequestId] AS [requestId]
                , [r].[RequestStatus] AS [requestStatus]
                , [r].[Command] AS [command]
                , [r].[DatabaseId] AS [databaseId]
                , [r].[DatabaseName] AS [databaseName]
                , [r].[LoginName] AS [loginName]
                , [r].[HostName] AS [hostName]
                , [r].[ProgramName] AS [programName]
                , [r].[IsToolBackgroundQuery] AS [isToolBackgroundQuery]
                , [r].[ToolBackgroundRuleCode] AS [toolBackgroundRuleCode]
                , [r].[ToolBackgroundCategory] AS [toolBackgroundCategory]
                , [r].[ToolBackgroundDetection] AS [toolBackgroundDetection]
                , [r].[ToolBackgroundConfidence] AS [toolBackgroundConfidence]
                , [r].[StartTime] AS [startTime]
                , [r].[ElapsedMs] AS [elapsedMs]
                , [r].[CpuMs] AS [cpuMs]
                , [r].[LogicalReads] AS [logicalReads]
                , [r].[Writes] AS [writes]
                , [r].[BlockingSessionId] AS [blockingSessionId]
                , [r].[WaitType] AS [waitType]
                , [wi].[WaitGroup] AS [waitGroup]
                , [wi].[Severity] AS [waitSeverity]
                , [r].[WaitTimeMs] AS [waitTimeMs]
                , [r].[RequestedMemoryMb] AS [requestedMemoryMb]
                , [r].[GrantedMemoryMb] AS [grantedMemoryMb]
                , [r].[UsedMemoryMb] AS [usedMemoryMb]
                , [r].[Dop] AS [dop]
                , [r].[ParallelWorkerCount] AS [parallelWorkerCount]
                , [r].[SchedulerId] AS [schedulerId]
                , [r].[TaskAddress] AS [taskAddress]
                , [r].[NestLevel] AS [nestLevel]
                , [r].[OpenTransactionCount] AS [openTransactionCount]
                , [r].[OpenResultsetCount] AS [openResultsetCount]
                , [r].[TransactionId] AS [transactionId]
                , [r].[ConnectionId] AS [connectionId]
                , [r].[WorkloadGroupId] AS [workloadGroupId]
                , [r].[WorkloadGroupName] AS [workloadGroupName]
                , [r].[ResourcePoolId] AS [resourcePoolId]
                , [r].[ResourcePoolName] AS [resourcePoolName]
                , [r].[StatementSqlHandle] AS [statementSqlHandle]
                , [r].[StatementContextId] AS [statementContextId]
                , [r].[IsResumable] AS [isResumable]
                , [r].[ExecutingManagedCode] AS [executingManagedCode]
                , [r].[ContextInfo] AS [contextInfo]
                , [r].[ModuleFullName] AS [moduleFullName]
                , [r].[ModuleTypeDescription] AS [moduleTypeDescription]
                , [r].[ExecutionContextType] AS [executionContextType]
                , [r].[QueryHash] AS [queryHash]
                , [r].[QueryPlanHash] AS [queryPlanHash]
                , [r].[SqlHandle] AS [sqlHandle]
                , [r].[PlanHandle] AS [planHandle]
            FROM [#CurrentRequests_Result] AS [r]
            CROSS APPLY [monitor].[TVF_WaitTypeInfo]([r].[WaitType]) AS [wi]
            ORDER BY [r].[SessionId], [r].[RequestId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        DECLARE @RequestContextJson nvarchar(max) =
        (
            SELECT *
            FROM [#CurrentRequests_RequestContext]
            ORDER BY [SessionId],[RequestId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        DECLARE @SnapshotStatusJson nvarchar(max) =
        (
            SELECT *
            FROM [#CurrentRequests_SnapshotStatus]
            ORDER BY [SourceOrdinal]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        DECLARE @StatementsJson nvarchar(max) =
        (
            SELECT *
            FROM [#CurrentRequests_Statements]
            ORDER BY [SessionId],[RequestId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        DECLARE @BatchesJson nvarchar(max) =
        (
            SELECT *
            FROM [#CurrentRequests_Batches]
            ORDER BY [SessionId],[RequestId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        DECLARE @InputBuffersJson nvarchar(max) =
        (
            SELECT *
            FROM [#CurrentRequests_InputBuffers]
            ORDER BY [SessionId],[RequestId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        DECLARE @WarningsJson nvarchar(max) =
        (
            SELECT
                  [w].[SessionId] AS [sessionId]
                , [w].[RequestId] AS [requestId]
                , [w].[DatabaseName] AS [databaseName]
                , [w].[Code] AS [code]
                , [w].[Message] AS [message]
            FROM [#CurrentRequests_Warnings] AS [w]
            ORDER BY [w].[WarningId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"requests":', COALESCE(@RequestsJson, N'[]')
            , N',"requestContext":', COALESCE(@RequestContextJson,N'[]')
            , N',"snapshotStatus":', COALESCE(@SnapshotStatusJson,N'[]')
            , N',"statements":', COALESCE(@StatementsJson, N'[]')
            , N',"batches":', COALESCE(@BatchesJson, N'[]')
            , N',"inputBuffers":', COALESCE(@InputBuffersJson, N'[]')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;

    IF @ResultSetArtNormalisiert = 'RAW'
    BEGIN
        SELECT
              @ModuleName AS [ModuleName]
            , @CollectionTimeUtc AS [CollectionTimeUtc]
            , @EvidenceSnapshotStartedAtUtc AS [EvidenceSnapshotStartedAtUtc]
            , @EvidenceSnapshotId AS [EvidenceSnapshotId]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , @RowCount AS [RowCount]
            , @MaxZeilen AS [RequestedMaxRows]
            , @HasMoreRows AS [HasMoreRows]
            , @RequiredPermission AS [RequiredPermission]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage]
            , @Detail AS [Detail];

        SELECT
              [r].*
            , [wi].[WaitGroup]
            , [wi].[Severity] AS [WaitSeverity]
            , [wi].[IsGenerallyBenign]
            , [wi].[Meaning] AS [WaitMeaning]
            , [wi].[TypicalOccurrence] AS [WaitTypicalOccurrence]
            , [wi].[HighWaitImpact]
            , [wi].[RecommendedChecks]
            , [wi].[HelpUrl] AS [WaitHelpUrl]
            , [wi].[InterpretationScope]
            , [wi].[CatalogMatchType]
            , [lwi].[WaitGroup] AS [LastWaitGroup]
            , [lwi].[Meaning] AS [LastWaitMeaning]
        FROM [#CurrentRequests_Result] AS [r]
        CROSS APPLY [monitor].[TVF_WaitTypeInfo]([r].[WaitType]) AS [wi]
        CROSS APPLY [monitor].[TVF_WaitTypeInfo]([r].[LastWaitType]) AS [lwi]
        ORDER BY
              CASE WHEN @Sortierung = 'CPU' THEN [r].[CpuMs] END DESC
            , CASE WHEN @Sortierung = 'READS' THEN [r].[LogicalReads] END DESC
            , CASE WHEN @Sortierung = 'DAUER' THEN [r].[ElapsedMs] END DESC
            , CASE
                  WHEN @Sortierung = 'RELEVANZ'
                      THEN CASE
                               WHEN [r].[BlockingSessionId] IS NOT NULL THEN 3
                               WHEN [r].[WaitType] IS NOT NULL THEN 2
                               ELSE 1
                           END
              END DESC
            , [r].[SessionId]
            , [r].[RequestId];

        SELECT * FROM [#CurrentRequests_RequestContext] ORDER BY [SessionId],[RequestId];
        SELECT * FROM [#CurrentRequests_SnapshotStatus] ORDER BY [SourceOrdinal];
        SELECT * FROM [#CurrentRequests_Statements] ORDER BY [SessionId],[RequestId];
        SELECT * FROM [#CurrentRequests_Batches] ORDER BY [SessionId],[RequestId];
        SELECT * FROM [#CurrentRequests_InputBuffers] ORDER BY [SessionId],[RequestId];

        SELECT
              [w].[WarningId]
            , [w].[SessionId]
            , [w].[RequestId]
            , [w].[DatabaseName]
            , [w].[Code]
            , [w].[Message]
        FROM [#CurrentRequests_Warnings] AS [w]
        ORDER BY [w].[WarningId];
    END
    ELSE IF @ResultSetArtNormalisiert = 'CONSOLE'
    BEGIN
        SELECT
              N'Modulstatus' AS [Ergebnis]
            , @ModuleName AS [Modul]
            , @StatusCode AS [Status]
            , @RowCount AS [Zeilen]
            , @Detail AS [Hinweis]
            , @ErrorMessage AS [Fehler];

        SELECT
              N'Aktiver Request' AS [Ergebnis]
            , [r].[SessionId] AS [Session]
            , [r].[RequestId] AS [Request]
            , COALESCE([r].[ModuleFullName], N'Ad-hoc/Prepared Batch') AS [Ausfuehrung]
            , [r].[ModuleTypeDescription] AS [Modultyp]
            , [r].[LoginName] AS [Login]
            , [r].[HostName] AS [Host]
            , [r].[ProgramName] AS [Programm]
            , [r].[DatabaseName] AS [Datenbank]
            , [r].[Command] AS [Befehl]
            , [r].[RequestStatus] AS [Status]
            , CONCAT(CONVERT(decimal(19,2), [r].[ElapsedMs] / 1000.0), N' s') AS [Laufzeit]
            , [r].[CpuMs] AS [CPU_ms]
            , [r].[LogicalReads] AS [Logical_Reads]
            , [r].[Writes] AS [Writes]
            , [r].[SessionId] AS [Session_Wait]
            , [r].[WaitType] AS [Wait]
            , [r].[WaitTimeMs] AS [Wait_ms]
            , [r].[BlockingSessionId] AS [Blockiert_durch]
            , [r].[RequestedMemoryMb] AS [Memory_angefordert_MB]
            , [r].[GrantedMemoryMb] AS [Memory_gewaehrt_MB]
            , [r].[UsedMemoryMb] AS [Memory_verwendet_MB]
            , CASE
                  WHEN [r].[StatementStartLine] IS NULL THEN NULL
                  WHEN [r].[StatementEndLine] = [r].[StatementStartLine]
                      THEN CONVERT(varchar(20), [r].[StatementStartLine])
                  ELSE CONCAT([r].[StatementStartLine], N'-', [r].[StatementEndLine])
              END AS [Statement_Zeile]
            , CONCAT
              (
                    COALESCE(CONVERT(varchar(20), [r].[StatementStartOffsetBytes]), N'?')
                  , N'-'
                  , CASE
                        WHEN [r].[StatementEndOffsetBytes] = -1 THEN N'Batch-Ende'
                        ELSE COALESCE(CONVERT(varchar(20), [r].[StatementEndOffsetBytes]), N'?')
                    END
              ) AS [Statement_Offset_Bytes]
            , [r].[CurrentStatementIsTruncated] AS [Statement_gekuerzt]
            , [r].[CurrentStatement] AS [Aktuelles_Statement]
        FROM [#CurrentRequests_Result] AS [r]
        ORDER BY
              CASE
                  WHEN @Sortierung = 'RELEVANZ'
                      THEN CASE
                               WHEN [r].[BlockingSessionId] IS NOT NULL THEN 3
                               WHEN [r].[WaitType] IS NOT NULL THEN 2
                               ELSE 1
                           END
              END DESC
            , CASE WHEN @Sortierung = 'CPU' THEN [r].[CpuMs] END DESC
            , CASE WHEN @Sortierung = 'READS' THEN [r].[LogicalReads] END DESC
            , CASE WHEN @Sortierung = 'DAUER' THEN [r].[ElapsedMs] END DESC
            , [r].[SessionId]
            , [r].[RequestId];

        SELECT
              N'SQL-Kontext' AS [Ergebnis]
            , [r].[SessionId] AS [Session]
            , [r].[RequestId] AS [Request]
            , [r].[ExecutionContextType] AS [Kontextart]
            , [r].[ModuleFullName] AS [Modul]
            , [r].[ModuleTypeDescription] AS [Modultyp]
            , [r].[NestLevel] AS [Verschachtelungsebene]
            , [r].[ConnectionId] AS [ConnectionId]
            , [r].[TransactionId] AS [TransactionId]
            , [r].[SchedulerId] AS [SchedulerId]
            , [r].[TaskAddress] AS [TaskAddress]
            , [r].[WorkloadGroupId] AS [WorkloadGroupId]
            , [r].[WorkloadGroupName] AS [WorkloadGroup]
            , [r].[ResourcePoolId] AS [ResourcePoolId]
            , [r].[ResourcePoolName] AS [ResourcePool]
            , [r].[StatementSqlHandle] AS [StatementSqlHandle]
            , [r].[StatementContextId] AS [StatementContextId]
            , [r].[IsResumable] AS [Ist_fortsetzbar]
            , [r].[ExecutingManagedCode] AS [Fuehrt_CLR_aus]
            , [r].[ContextInfo] AS [ContextInfo]
            , [r].[SqlTextDatabaseId] AS [SQLText_DatabaseId]
            , [r].[SqlTextObjectId] AS [SQLText_ObjectId]
            , [r].[SqlTextObjectNumber] AS [SQLText_ObjectNumber]
            , [r].[SqlTextIsEncrypted] AS [SQLText_verschluesselt]
            , [r].[HasStatementOffsets] AS [Offsets_vorhanden]
            , [r].[IsStatementOffsetValid] AS [Offsets_gueltig]
            , [r].[StatementStartOffsetBytes] AS [Statement_Start_Byte]
            , [r].[StatementEndOffsetBytes] AS [Statement_Ende_Byte]
            , [r].[StatementStartCharacter] AS [Statement_Start_Zeichen]
            , [r].[StatementEndCharacter] AS [Statement_Ende_Zeichen]
            , [r].[StatementStartLine] AS [Statement_Start_Zeile]
            , [r].[StatementEndLine] AS [Statement_Ende_Zeile]
            , [r].[CurrentStatementCharacterCount] AS [Statement_Zeichen]
            , [r].[BatchTextCharacterCount] AS [Batch_Zeichen]
            , [r].[QueryHash] AS [QueryHash]
            , [r].[QueryPlanHash] AS [QueryPlanHash]
            , [r].[SqlHandle] AS [SqlHandle]
            , [r].[PlanHandle] AS [PlanHandle]
        FROM [#CurrentRequests_Result] AS [r]
        ORDER BY [r].[SessionId], [r].[RequestId];

        IF @GesamtenSqlTextEinbeziehen = 1
        BEGIN
            SELECT
                  N'Gesamter SQL-Batch/Modultext' AS [Ergebnis]
                , [r].[SessionId] AS [Session]
                , [r].[RequestId] AS [Request]
                , COALESCE([r].[ModuleFullName], N'Ad-hoc/Prepared Batch') AS [Ausfuehrung]
                , [r].[BatchTextCharacterCount] AS [Zeichen_gesamt]
                , [r].[BatchTextIsTruncated] AS [Text_gekuerzt]
                , [r].[BatchText] AS [Gesamter_SQL_Text]
            FROM [#CurrentRequests_Result] AS [r]
            WHERE [r].[BatchText] IS NOT NULL
            ORDER BY [r].[SessionId], [r].[RequestId];
        END;

        IF @InputBufferEinbeziehen = 1
        BEGIN
            SELECT
                  N'Input Buffer' AS [Ergebnis]
                , [r].[SessionId] AS [Session]
                , [r].[RequestId] AS [Request]
                , [r].[InputBufferEventType] AS [Ereignistyp]
                , [r].[InputBufferParameterCount] AS [Parameteranzahl]
                , [r].[InputBufferCharacterCount] AS [Zeichen_gesamt]
                , [r].[InputBufferIsTruncated] AS [Text_gekuerzt]
                , [r].[InputBufferText] AS [Uebergebener_Befehl]
            FROM [#CurrentRequests_Result] AS [r]
            WHERE [r].[InputBufferText] IS NOT NULL
            ORDER BY [r].[SessionId], [r].[RequestId];
        END;

        IF EXISTS (SELECT 1 FROM [#CurrentRequests_Warnings])
        BEGIN
            SELECT
                  N'Warnung' AS [Ergebnis]
                , [w].[SessionId] AS [Session]
                , [w].[RequestId] AS [Request]
                , [w].[DatabaseName] AS [Datenbank]
                , [w].[Code] AS [Code]
                , [w].[Message] AS [Hinweis]
            FROM [#CurrentRequests_Warnings] AS [w]
            ORDER BY [w].[WarningId];
        END;
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CurrentRequests_Result'
            , @ResultLabel=N'Aktuelle Requests'
            , @EmptyMessage=N'Keine aktiven Requests';
    END;
    IF @TableResultRequested = 1
    BEGIN
        DECLARE @ExportResultName sysname;
        DECLARE @ExportTargetTable sysname;
        DECLARE @ExportSourceTable sysname;
        DECLARE [CurrentRequestsExportCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [ResultName],[TargetTable]
            FROM [#CurrentRequests_ResultTableMap]
            ORDER BY [ResultName];

        OPEN [CurrentRequestsExportCursor];
        FETCH NEXT FROM [CurrentRequestsExportCursor]
            INTO @ExportResultName,@ExportTargetTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @ExportSourceTable=
                CASE @ExportResultName
                    WHEN N'requests' THEN N'#CurrentRequests_Result'
                    WHEN N'requestContext' THEN N'#CurrentRequests_RequestContext'
                    WHEN N'snapshotStatus' THEN N'#CurrentRequests_SnapshotStatus'
                    WHEN N'statements' THEN N'#CurrentRequests_Statements'
                    WHEN N'batches' THEN N'#CurrentRequests_Batches'
                    WHEN N'inputBuffers' THEN N'#CurrentRequests_InputBuffers'
                    WHEN N'warnings' THEN N'#CurrentRequests_Warnings'
                END;

            EXEC [monitor].[InternalWriteResultTable]
                  @SourceTable=@ExportSourceTable
                , @TargetTable=@ExportTargetTable
                , @ThrowOnError=1;

            FETCH NEXT FROM [CurrentRequestsExportCursor]
                INTO @ExportResultName,@ExportTargetTable;
        END;
        CLOSE [CurrentRequestsExportCursor];
        DEALLOCATE [CurrentRequestsExportCursor];
    END;
END;
GO
