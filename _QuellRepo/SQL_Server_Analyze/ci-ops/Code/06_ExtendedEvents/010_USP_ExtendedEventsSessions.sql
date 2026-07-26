USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ExtendedEventsSessions
Version      : 1.0.2
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Inventarisiert vorhandene serverweite Extended-Events-Sessions,
               deren Definitionen, Laufzeitstatus, Events, Actions, Targets und
               explizit konfigurierte Felder. Es werden keine Sessions erstellt,
               gestartet, gestoppt, geändert oder gelöscht.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.server_event_sessions, sys.server_event_session_events,
               sys.server_event_session_actions, sys.server_event_session_targets,
               sys.server_event_session_fields, optional sys.dm_xe_sessions.
Parameter    : @SessionNameLike, @NurLaufend, @MitLaufzeitstatus, @MitEvents,
               @MitActions, @MitTargets, @MitFeldern, @MaxZeilen,
               @PrintMeldungen, @Hilfe.
Resultsets   : 1. Modulstatus. 2. Sessions. 3. Events. 4. Actions. 5. Targets.
               6. konfigurierte Felder. Nicht aktivierte Resultsets bleiben leer.
Berechtigung : SQL Server 2019 VIEW SERVER STATE; SQL Server 2022+ VIEW SERVER
               PERFORMANCE STATE oder höher. Das Framework vergibt keine Rechte.
Eigenlast    : Gering. Es werden nur Extended-Events-Katalogviews und optional
               sys.dm_xe_sessions gelesen. Targetdaten werden nicht gelesen.
Locking      : LOCK_TIMEOUT 0; keine Benutzerobjekte, keine Änderungen.
Partial      : Fehlende Berechtigungen liefern strukturierte Status- und leere
               Ergebnis-Resultsets; andere Framework-Module bleiben nutzbar.
Beispiele    : EXEC monitor.USP_ExtendedEventsSessions;
               EXEC monitor.USP_ExtendedEventsSessions @SessionNameLike=N'system_health';
               EXEC monitor.USP_ExtendedEventsSessions @Hilfe=1;
Änderungen   : 1.0.2 - total_target_memory wird nur bei nachgewiesener Spaltenverfügbarkeit gelesen; SQL Server 2019 liefert NULL.
               1.0.1 - Alias [ObjectType] für die sortierte Feldklassifikation ergänzt.
               1.0.0 - Erstfassung Phase 5.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ExtendedEventsSessions]
      @ExtendedEventSessionNames       nvarchar(max)  = NULL
    , @ExtendedEventSessionNamePattern nvarchar(4000) = NULL
    , @EventNames                      nvarchar(max)  = NULL
    , @EventNamePattern                nvarchar(4000) = NULL
    , @TargetNames                     nvarchar(max)  = NULL
    , @TargetNamePattern               nvarchar(4000) = NULL
    , @NurLaufend           bit           = 0
    , @MitLaufzeitstatus    bit           = 1
    , @MitEvents            bit           = 1
    , @MitActions           bit           = 1
    , @MitTargets           bit           = 1
    , @MitFeldern           bit           = 0
    , @MaxZeilen            int           = 5000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen       bit           = 1
    , @Hilfe                bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'sessions',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @SessionPatternMode varchar(8),@SessionPatternValue nvarchar(4000),@SessionPatternFlags varchar(8),@SessionPatternValid bit;
    DECLARE @EventPatternMode varchar(8),@EventPatternValue nvarchar(4000),@EventPatternFlags varchar(8),@EventPatternValid bit;
    DECLARE @TargetPatternMode varchar(8),@TargetPatternValue nvarchar(4000),@TargetPatternFlags varchar(8),@TargetPatternValid bit;
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_ExtendedEventsSessions';
        PRINT N'@ExtendedEventSessionNames: bracket-aware Pipe-Liste; @ExtendedEventSessionNamePattern: LIKE/Regex-Pattern.';
        PRINT N'@NurLaufend bit=0: 1 zeigt nur aktuell laufende Sessions.';
        PRINT N'@MitLaufzeitstatus bit=1: ergänzt Laufzeitinformationen aus sys.dm_xe_sessions; liest keine Targetdaten.';
        PRINT N'@MitEvents bit=1: gibt konfigurierte Events aus.';
        PRINT N'@MitActions bit=1: gibt konfigurierte Actions aus.';
        PRINT N'@MitTargets bit=1: gibt konfigurierte Targets aus.';
        PRINT N'@MitFeldern bit=0: gibt explizit konfigurierte Event-/Targetfelder aus.';
        PRINT N'@MaxZeilen int=5000: positive Werte begrenzen jedes Detailresultset; NULL/0 = unbegrenzt.';
        PRINT N'@PrintMeldungen bit=1: Warnungen zusätzlich via RAISERROR Severity 10.';
        PRINT N'@Hilfe bit=0: 1 zeigt diese Hilfe und beendet die Procedure.';
        PRINT N'Die Procedure erstellt, startet, stoppt, ändert oder löscht keine Extended-Events-Session.';
        RETURN;
    END;

    DECLARE
        @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME(),
        @StatusCode varchar(40) = 'AVAILABLE',
        @IsPartial bit = 0,
        @ErrorNumber int = NULL,
        @ErrorMessage nvarchar(2048) = NULL,
        @RowCount bigint = 0;

    CREATE TABLE [#ExtendedEventsSessions_SessionNameFilter]([NameValue] sysname NOT NULL PRIMARY KEY);
    CREATE TABLE [#ExtendedEventsSessions_EventNameFilter]([NameValue] sysname NOT NULL PRIMARY KEY);
    CREATE TABLE [#ExtendedEventsSessions_TargetNameFilter]([NameValue] sysname NOT NULL PRIMARY KEY);
    SELECT @SessionPatternMode=[PatternMode],@SessionPatternValue=[PatternValue],@SessionPatternFlags=[RegexFlags],@SessionPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@ExtendedEventSessionNamePattern);
    SELECT @EventPatternMode=[PatternMode],@EventPatternValue=[PatternValue],@EventPatternFlags=[RegexFlags],@EventPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@EventNamePattern);
    SELECT @TargetPatternMode=[PatternMode],@TargetPatternValue=[PatternValue],@TargetPatternFlags=[RegexFlags],@TargetPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@TargetNamePattern);
    IF @ExtendedEventSessionNames IS NOT NULL AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@ExtendedEventSessionNames) WHERE [IsValid]=0) SET @StatusCode='INVALID_PARAMETER';
    IF @EventNames IS NOT NULL AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@EventNames) WHERE [IsValid]=0) SET @StatusCode='INVALID_PARAMETER';
    IF @TargetNames IS NOT NULL AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@TargetNames) WHERE [IsValid]=0) SET @StatusCode='INVALID_PARAMETER';
    IF @SessionPatternValid=0 OR @EventPatternValid=0 OR @TargetPatternValid=0 OR (@ExtendedEventSessionNames IS NOT NULL AND @ExtendedEventSessionNamePattern IS NOT NULL) OR (@EventNames IS NOT NULL AND @EventNamePattern IS NOT NULL) OR (@TargetNames IS NOT NULL AND @TargetNamePattern IS NOT NULL) SET @StatusCode='INVALID_PARAMETER';
    IF @StatusCode='INVALID_PARAMETER' SET @ErrorMessage=N'Namensliste, Pattern oder gegenseitige Exklusivität ist ungültig.';
    IF @ExtendedEventSessionNames IS NOT NULL INSERT [#ExtendedEventsSessions_SessionNameFilter] SELECT [NameValue] FROM [monitor].[TVF_ParseSqlNameList](@ExtendedEventSessionNames) WHERE [IsValid]=1 GROUP BY [NameValue];
    IF @EventNames IS NOT NULL INSERT [#ExtendedEventsSessions_EventNameFilter] SELECT [NameValue] FROM [monitor].[TVF_ParseSqlNameList](@EventNames) WHERE [IsValid]=1 GROUP BY [NameValue];
    IF @TargetNames IS NOT NULL INSERT [#ExtendedEventsSessions_TargetNameFilter] SELECT [NameValue] FROM [monitor].[TVF_ParseSqlNameList](@TargetNames) WHERE [IsValid]=1 GROUP BY [NameValue];
    IF @StatusCode='AVAILABLE' AND (@SessionPatternMode IN('REGEX','REGEXI') OR @EventPatternMode IN('REGEX','REGEXI') OR @TargetPatternMode IN('REGEX','REGEXI')) AND (TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<17 OR NOT EXISTS(SELECT 1 FROM [master].[sys].[databases] [d] WITH(NOLOCK) WHERE [d].[database_id]=DB_ID() AND [d].[compatibility_level]>=170)) BEGIN SET @StatusCode='UNAVAILABLE_FEATURE';SET @ErrorMessage=N'Regex benötigt SQL Server 2025 und Compatibility Level 170.';END;

    CREATE TABLE [#ExtendedEventsSessions_Sessions]
    (
        [EventSessionId] int NOT NULL,
        [SessionName] sysname NOT NULL,
        [IsRunning] bit NOT NULL,
        [StartupState] bit NULL,
        [EventRetentionMode] nchar(1) NULL,
        [EventRetentionModeDesc] nvarchar(60) NULL,
        [MaxDispatchLatencyMilliseconds] int NULL,
        [MaxMemoryKb] int NULL,
        [MaxEventSizeKb] int NULL,
        [MemoryPartitionMode] nchar(1) NULL,
        [MemoryPartitionModeDesc] nvarchar(60) NULL,
        [TrackCausality] bit NULL,
        [RunningSince] datetime NULL,
        [PendingBuffers] int NULL,
        [TotalRegularBuffers] int NULL,
        [RegularBufferSizeBytes] bigint NULL,
        [TotalLargeBuffers] int NULL,
        [LargeBufferSizeBytes] bigint NULL,
        [TotalBufferSizeBytes] bigint NULL,
        [BufferPolicyDesc] nvarchar(256) NULL,
        [DroppedEventCount] int NULL,
        [DroppedBufferCount] int NULL,
        [BlockedEventFireTimeMilliseconds] int NULL,
        [LargestEventDroppedSizeBytes] int NULL,
        [BufferProcessedCount] bigint NULL,
        [BufferFullCount] bigint NULL,
        [TotalBytesGenerated] bigint NULL,
        [TotalTargetMemoryBytes] bigint NULL,
        [EventCount] int NULL,
        [TargetCount] int NULL,
        [ActionCount] int NULL,
        [HasRingBuffer] bit NULL,
        [HasEventFile] bit NULL
    );

    CREATE TABLE [#ExtendedEventsSessions_Events]
    (
        [SessionName] sysname NOT NULL,
        [EventId] int NOT NULL,
        [PackageName] sysname NOT NULL,
        [EventName] sysname NOT NULL,
        [Predicate] nvarchar(max) NULL
    );

    CREATE TABLE [#ExtendedEventsSessions_Actions]
    (
        [SessionName] sysname NOT NULL,
        [EventName] sysname NOT NULL,
        [ActionOrdinal] int NOT NULL,
        [PackageName] sysname NOT NULL,
        [ActionName] sysname NOT NULL
    );

    CREATE TABLE [#ExtendedEventsSessions_Targets]
    (
        [SessionName] sysname NOT NULL,
        [TargetId] int NOT NULL,
        [PackageName] sysname NOT NULL,
        [TargetName] sysname NOT NULL,
        [ConfiguredFileName] nvarchar(4000) NULL,
        [MaxFileSizeMb] bigint NULL,
        [MaxRolloverFiles] int NULL,
        [MaxMemoryKb] bigint NULL
    );

    CREATE TABLE [#ExtendedEventsSessions_Fields]
    (
        [SessionName] sysname NOT NULL,
        [ObjectType] varchar(16) NOT NULL,
        [ObjectId] int NOT NULL,
        [ObjectName] sysname NULL,
        [FieldName] sysname NOT NULL,
        [FieldValue] nvarchar(4000) NULL
    );

    IF @MaxZeilen<0 OR @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@MaxZeilen darf nicht negativ sein; NULL/0 bedeutet unbegrenzt.';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            INSERT [#ExtendedEventsSessions_Sessions]
            (
                [EventSessionId], [SessionName], [IsRunning], [StartupState],
                [EventRetentionMode], [EventRetentionModeDesc],
                [MaxDispatchLatencyMilliseconds], [MaxMemoryKb], [MaxEventSizeKb],
                [MemoryPartitionMode], [MemoryPartitionModeDesc], [TrackCausality],
                [RunningSince], [PendingBuffers], [TotalRegularBuffers],
                [RegularBufferSizeBytes], [TotalLargeBuffers], [LargeBufferSizeBytes],
                [TotalBufferSizeBytes], [BufferPolicyDesc], [DroppedEventCount],
                [DroppedBufferCount], [BlockedEventFireTimeMilliseconds],
                [LargestEventDroppedSizeBytes], [BufferProcessedCount],
                [BufferFullCount], [TotalBytesGenerated], [TotalTargetMemoryBytes],
                [EventCount], [TargetCount], [ActionCount], [HasRingBuffer], [HasEventFile]
            )
            SELECT TOP (@EffectiveMaxZeilen)
                [s].[event_session_id],
                [s].[name],
                CONVERT(bit, CASE WHEN [r].[name] IS NULL THEN 0 ELSE 1 END),
                [s].[startup_state],
                [s].[event_retention_mode],
                [s].[event_retention_mode_desc],
                [s].[max_dispatch_latency],
                [s].[max_memory],
                [s].[max_event_size],
                [s].[memory_partition_mode],
                [s].[memory_partition_mode_desc],
                [s].[track_causality],
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[create_time] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[pending_buffers] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[total_regular_buffers] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[regular_buffer_size] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[total_large_buffers] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[large_buffer_size] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[total_buffer_size] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[buffer_policy_desc] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[dropped_event_count] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[dropped_buffer_count] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[blocked_event_fire_time] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[largest_event_dropped_size] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[buffer_processed_count] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[buffer_full_count] END,
                CASE WHEN @MitLaufzeitstatus = 1 THEN [r].[total_bytes_generated] END,
                CAST(NULL AS bigint),
                [x].[EventCount],
                [x].[TargetCount],
                [x].[ActionCount],
                [x].[HasRingBuffer],
                [x].[HasEventFile]
            FROM [sys].[server_event_sessions] AS s WITH (NOLOCK)
            LEFT JOIN [sys].[dm_xe_sessions] AS r WITH (NOLOCK)
              ON @MitLaufzeitstatus = 1
             AND [r].[name] = [s].[name]
            OUTER APPLY
            (
                SELECT
                    (SELECT COUNT_BIG(*) FROM [sys].[server_event_session_events] AS e WITH (NOLOCK) WHERE [e].[event_session_id] = [s].[event_session_id]) AS [EventCount],
                    (SELECT COUNT_BIG(*) FROM [sys].[server_event_session_targets] AS t WITH (NOLOCK) WHERE [t].[event_session_id] = [s].[event_session_id]) AS [TargetCount],
                    (
                        SELECT COUNT_BIG(*)
                        FROM [sys].[server_event_session_actions] AS a WITH (NOLOCK)
                        WHERE [a].[event_session_id] = [s].[event_session_id]
                    ) AS [ActionCount],
                    CONVERT(bit, CASE WHEN EXISTS
                    (
                        SELECT 1 FROM [sys].[server_event_session_targets] AS t WITH (NOLOCK)
                        WHERE [t].[event_session_id] = [s].[event_session_id] AND [t].[name] = N'ring_buffer'
                    ) THEN 1 ELSE 0 END) AS [HasRingBuffer],
                    CONVERT(bit, CASE WHEN EXISTS
                    (
                        SELECT 1 FROM [sys].[server_event_session_targets] AS t WITH (NOLOCK)
                        WHERE [t].[event_session_id] = [s].[event_session_id] AND [t].[name] = N'event_file'
                    ) THEN 1 ELSE 0 END) AS [HasEventFile]
            ) AS x
            WHERE ((@ExtendedEventSessionNames IS NULL OR EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_SessionNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS)) AND (@SessionPatternMode IN('NONE','REGEX','REGEXI') OR [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @SessionPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (@NurLaufend = 0 OR [r].[name] IS NOT NULL)
            ORDER BY [s].[name];

            IF @MitLaufzeitstatus = 1
               AND EXISTS
               (
                   SELECT 1
                   FROM [sys].[all_objects] AS [o] WITH (NOLOCK)
                   INNER JOIN [sys].[schemas] AS [sc] WITH (NOLOCK)
                       ON [sc].[schema_id]=[o].[schema_id]
                   INNER JOIN [sys].[all_columns] AS [c] WITH (NOLOCK)
                       ON [c].[object_id]=[o].[object_id]
                   WHERE [sc].[name]=N'sys'
                     AND [o].[name]=N'dm_xe_sessions'
                     AND [c].[name]=N'total_target_memory'
               )
            BEGIN
                DECLARE @TargetMemorySql nvarchar(max)=N'
UPDATE [s]
SET [TotalTargetMemoryBytes]=[r].[total_target_memory]
FROM [#ExtendedEventsSessions_Sessions] AS [s]
INNER JOIN [sys].[dm_xe_sessions] AS [r] WITH (NOLOCK)
    ON [r].[name]=[s].[SessionName];';
                EXEC [sys].[sp_executesql] @TargetMemorySql;
            END;

            SELECT @RowCount = COUNT_BIG(*) FROM [#ExtendedEventsSessions_Sessions];
        END TRY
        BEGIN CATCH
            SET @StatusCode = CASE
                                WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371) THEN 'DENIED_PERMISSION'
                                WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                                ELSE 'ERROR_HANDLED'
                              END;
            SET @ErrorNumber = ERROR_NUMBER();
            SET @ErrorMessage = ERROR_MESSAGE();
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitEvents = 1
    BEGIN
        BEGIN TRY
            INSERT [#ExtendedEventsSessions_Events]([SessionName], [EventId], [PackageName], [EventName], [Predicate])
            SELECT TOP (@EffectiveMaxZeilen)
                [s].[name],
                [e].[event_id],
                [e].[package],
                [e].[name],
                [e].[predicate]
            FROM [sys].[server_event_session_events] AS e WITH (NOLOCK)
            JOIN [sys].[server_event_sessions] AS s WITH (NOLOCK)
              ON [s].[event_session_id] = [e].[event_session_id]
            WHERE ((@ExtendedEventSessionNames IS NULL OR EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_SessionNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS)) AND (@SessionPatternMode IN('NONE','REGEX','REGEXI') OR [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @SessionPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (@NurLaufend = 0 OR EXISTS (SELECT 1 FROM [sys].[dm_xe_sessions] AS r WITH (NOLOCK) WHERE [r].[name] = [s].[name]))
            ORDER BY [s].[name], [e].[event_id];
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            IF @PrintMeldungen = 1
                BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ExtendedEventsSessions Events: %s', ERROR_MESSAGE());
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitActions = 1
    BEGIN
        BEGIN TRY
            INSERT [#ExtendedEventsSessions_Actions]([SessionName], [EventName], [ActionOrdinal], [PackageName], [ActionName])
            SELECT TOP (@EffectiveMaxZeilen)
                [s].[name],
                [e].[name],
                CONVERT(int, ROW_NUMBER() OVER(PARTITION BY [s].[name],[e].[name] ORDER BY [a].[package],[a].[name])),
                [a].[package],
                [a].[name]
            FROM [sys].[server_event_session_actions] AS a WITH (NOLOCK)
            JOIN [sys].[server_event_sessions] AS s WITH (NOLOCK)
              ON [s].[event_session_id] = [a].[event_session_id]
            JOIN [sys].[server_event_session_events] AS e WITH (NOLOCK)
              ON [e].[event_session_id] = [a].[event_session_id]
             AND [e].[event_id] = [a].[event_id]
            WHERE ((@ExtendedEventSessionNames IS NULL OR EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_SessionNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS)) AND (@SessionPatternMode IN('NONE','REGEX','REGEXI') OR [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @SessionPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (@NurLaufend = 0 OR EXISTS (SELECT 1 FROM [sys].[dm_xe_sessions] AS r WITH (NOLOCK) WHERE [r].[name] = [s].[name]))
            ORDER BY [s].[name], [e].[name], [a].[package], [a].[name];
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            IF @PrintMeldungen = 1
                BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ExtendedEventsSessions Actions: %s', ERROR_MESSAGE());
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitTargets = 1
    BEGIN
        BEGIN TRY
            INSERT [#ExtendedEventsSessions_Targets]
            (
                [SessionName], [TargetId], [PackageName], [TargetName],
                [ConfiguredFileName], [MaxFileSizeMb], [MaxRolloverFiles], [MaxMemoryKb]
            )
            SELECT TOP (@EffectiveMaxZeilen)
                [s].[name],
                [t].[target_id],
                [t].[package],
                [t].[name],
                MAX(CASE WHEN [f].[name] = N'filename' THEN CONVERT(nvarchar(4000), [f].[value]) END),
                MAX(CASE WHEN [f].[name] = N'max_file_size' THEN TRY_CONVERT([bigint], [f].[value]) END),
                MAX(CASE WHEN [f].[name] = N'max_rollover_files' THEN TRY_CONVERT([int], [f].[value]) END),
                MAX(CASE WHEN [f].[name] = N'max_memory' THEN TRY_CONVERT([bigint], [f].[value]) END)
            FROM [sys].[server_event_session_targets] AS t WITH (NOLOCK)
            JOIN [sys].[server_event_sessions] AS s WITH (NOLOCK)
              ON [s].[event_session_id] = [t].[event_session_id]
            LEFT JOIN [sys].[server_event_session_fields] AS f WITH (NOLOCK)
              ON [f].[event_session_id] = [t].[event_session_id]
             AND [f].[object_id] = [t].[target_id]
            WHERE ((@ExtendedEventSessionNames IS NULL OR EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_SessionNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS)) AND (@SessionPatternMode IN('NONE','REGEX','REGEXI') OR [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @SessionPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (@NurLaufend = 0 OR EXISTS (SELECT 1 FROM [sys].[dm_xe_sessions] AS r WITH (NOLOCK) WHERE [r].[name] = [s].[name]))
            GROUP BY [s].[name], [t].[target_id], [t].[package], [t].[name]
            ORDER BY [s].[name], [t].[target_id];
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            IF @PrintMeldungen = 1
                BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ExtendedEventsSessions Targets: %s', ERROR_MESSAGE());
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitFeldern = 1
    BEGIN
        BEGIN TRY
            INSERT [#ExtendedEventsSessions_Fields]([SessionName], [ObjectType], [ObjectId], [ObjectName], [FieldName], [FieldValue])
            SELECT TOP (@EffectiveMaxZeilen)
                [s].[name],
                CASE WHEN [e].[event_id] IS NOT NULL THEN 'EVENT'
                     WHEN [t].[target_id] IS NOT NULL THEN 'TARGET'
                     ELSE 'UNKNOWN' END AS [ObjectType],
                [f].[object_id],
                COALESCE([e].[name], [t].[name]),
                [f].[name],
                CONVERT(nvarchar(4000), [f].[value])
            FROM [sys].[server_event_session_fields] AS f WITH (NOLOCK)
            JOIN [sys].[server_event_sessions] AS s WITH (NOLOCK)
              ON [s].[event_session_id] = [f].[event_session_id]
            LEFT JOIN [sys].[server_event_session_events] AS e WITH (NOLOCK)
              ON [e].[event_session_id] = [f].[event_session_id]
             AND [e].[event_id] = [f].[object_id]
            LEFT JOIN [sys].[server_event_session_targets] AS t WITH (NOLOCK)
              ON [t].[event_session_id] = [f].[event_session_id]
             AND [t].[target_id] = [f].[object_id]
            WHERE ((@ExtendedEventSessionNames IS NULL OR EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_SessionNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS)) AND (@SessionPatternMode IN('NONE','REGEX','REGEXI') OR [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @SessionPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (@NurLaufend = 0 OR EXISTS (SELECT 1 FROM [sys].[dm_xe_sessions] AS r WITH (NOLOCK) WHERE [r].[name] = [s].[name]))
            ORDER BY
                [s].[name],
                CASE WHEN [e].[event_id] IS NOT NULL THEN 1
                     WHEN [t].[target_id] IS NOT NULL THEN 2
                     ELSE 3 END,
                [f].[object_id],
                [f].[name];
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            IF @PrintMeldungen = 1
                BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ExtendedEventsSessions Felder: %s', ERROR_MESSAGE());
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
        END CATCH;
    END;



    IF @StatusCode IN('AVAILABLE','AVAILABLE_LIMITED')
    BEGIN
        IF @EventNames IS NOT NULL
        BEGIN
            DELETE [e] FROM [#ExtendedEventsSessions_Events] [e] WHERE NOT EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_EventNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[e].[EventName] COLLATE SQL_Latin1_General_CP1_CS_AS);
            DELETE [a] FROM [#ExtendedEventsSessions_Actions] [a] WHERE NOT EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_EventNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[a].[EventName] COLLATE SQL_Latin1_General_CP1_CS_AS);
        END;
        IF @EventPatternMode='LIKE'
        BEGIN DELETE FROM [#ExtendedEventsSessions_Events] WHERE [EventName] COLLATE SQL_Latin1_General_CP1_CS_AS NOT LIKE @EventPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS;DELETE FROM [#ExtendedEventsSessions_Actions] WHERE [EventName] COLLATE SQL_Latin1_General_CP1_CS_AS NOT LIKE @EventPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS;END;
        IF @TargetNames IS NOT NULL DELETE [x] FROM [#ExtendedEventsSessions_Targets] [x] WHERE NOT EXISTS(SELECT 1 FROM [#ExtendedEventsSessions_TargetNameFilter] [f] WHERE [f].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[x].[TargetName] COLLATE SQL_Latin1_General_CP1_CS_AS);
        IF @TargetPatternMode='LIKE' DELETE FROM [#ExtendedEventsSessions_Targets] WHERE [TargetName] COLLATE SQL_Latin1_General_CP1_CS_AS NOT LIKE @TargetPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS;
        IF @SessionPatternMode IN('REGEX','REGEXI') OR @EventPatternMode IN('REGEX','REGEXI') OR @TargetPatternMode IN('REGEX','REGEXI')
        BEGIN
            DECLARE @FilterSql nvarchar(max)=N'';
            IF @SessionPatternMode IN('REGEX','REGEXI') SET @FilterSql+=N'DELETE FROM [#ExtendedEventsSessions_Fields] WHERE NOT REGEXP_LIKE([SessionName],@SP,@SF);DELETE FROM [#ExtendedEventsSessions_Targets] WHERE NOT REGEXP_LIKE([SessionName],@SP,@SF);DELETE FROM [#ExtendedEventsSessions_Actions] WHERE NOT REGEXP_LIKE([SessionName],@SP,@SF);DELETE FROM [#ExtendedEventsSessions_Events] WHERE NOT REGEXP_LIKE([SessionName],@SP,@SF);DELETE FROM [#ExtendedEventsSessions_Sessions] WHERE NOT REGEXP_LIKE([SessionName],@SP,@SF);';
            IF @EventPatternMode IN('REGEX','REGEXI') SET @FilterSql+=N'DELETE FROM [#ExtendedEventsSessions_Events] WHERE NOT REGEXP_LIKE([EventName],@EP,@EF);DELETE FROM [#ExtendedEventsSessions_Actions] WHERE NOT REGEXP_LIKE([EventName],@EP,@EF);';
            IF @TargetPatternMode IN('REGEX','REGEXI') SET @FilterSql+=N'DELETE FROM [#ExtendedEventsSessions_Targets] WHERE NOT REGEXP_LIKE([TargetName],@TP,@TF);';
            EXEC [sys].[sp_executesql] @FilterSql,N'@SP nvarchar(4000),@SF varchar(8),@EP nvarchar(4000),@EF varchar(8),@TP nvarchar(4000),@TF varchar(8)',@SP=@SessionPatternValue,@SF=@SessionPatternFlags,@EP=@EventPatternValue,@EF=@EventPatternFlags,@TP=@TargetPatternValue,@TF=@TargetPatternFlags;
        END;
        SELECT @RowCount=COUNT_BIG(*) FROM [#ExtendedEventsSessions_Sessions];
    END;

    IF @StatusCode = 'AVAILABLE' AND @IsPartial = 1
        SET @StatusCode = 'AVAILABLE_LIMITED';

    IF @PrintMeldungen = 1 AND @StatusCode NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED')
        BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ExtendedEventsSessions: %s - %s', @StatusCode, COALESCE(@ErrorMessage, N'Keine Details.'));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;

    IF @ResultSetArtNormalisiert<>'NONE'
    BEGIN
        SELECT N'USP_ExtendedEventsSessions' AS [ModuleName],@CollectionTimeUtc AS [CollectionTimeUtc],@StatusCode AS [StatusCode],@IsPartial AS [IsPartial],@RowCount AS [RowCount],CASE WHEN TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END AS [RequiredPermission],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],N'Nur Inventarisierung; keine Extended-Events-DDL und keine Targetdaten.' AS [Detail];
        IF @ResultSetArtNormalisiert='RAW'
        BEGIN SELECT * FROM [#ExtendedEventsSessions_Sessions] ORDER BY [SessionName];SELECT * FROM [#ExtendedEventsSessions_Events] ORDER BY [SessionName],[EventId];SELECT * FROM [#ExtendedEventsSessions_Actions] ORDER BY [SessionName],[EventName],[ActionOrdinal];SELECT * FROM [#ExtendedEventsSessions_Targets] ORDER BY [SessionName],[TargetId];SELECT * FROM [#ExtendedEventsSessions_Fields] ORDER BY [SessionName],[ObjectType],[ObjectId],[FieldName];END
        ELSE
        BEGIN SELECT N'Extended-Events Session' [Ergebnis],[SessionName] [Session],[IsRunning] [läuft],[StartupState] [Autostart],CONCAT(CONVERT(varchar(40),CONVERT(decimal(19,2),[MaxMemoryKb]/1024.0)),N' MB') [max. Speicher],[EventCount] [Events],[TargetCount] [Targets],[DroppedEventCount] [verworfene Events],[SessionName] [Session Details],[BufferPolicyDesc] [Buffer Policy] FROM [#ExtendedEventsSessions_Sessions] ORDER BY [SessionName];SELECT N'Extended-Events Event' [Ergebnis],[SessionName] [Session],[EventName] [Event],[PackageName] [Package],[Predicate] [Prädikat] FROM [#ExtendedEventsSessions_Events] ORDER BY [SessionName],[EventId];SELECT N'Extended-Events Action' [Ergebnis],[SessionName] [Session],[EventName] [Event],[ActionName] [Action],[PackageName] [Package] FROM [#ExtendedEventsSessions_Actions] ORDER BY [SessionName],[EventName],[ActionOrdinal];SELECT N'Extended-Events Target' [Ergebnis],[SessionName] [Session],[TargetName] [Target],[ConfiguredFileName] [Datei],[MaxFileSizeMb] [max. Datei MB],[MaxRolloverFiles] [Rollover-Dateien] FROM [#ExtendedEventsSessions_Targets] ORDER BY [SessionName],[TargetId];SELECT N'Extended-Events Feld' [Ergebnis],[SessionName] [Session],[ObjectType] [Objekttyp],[ObjectName] [Objekt],[FieldName] [Feld],[FieldValue] [Wert] FROM [#ExtendedEventsSessions_Fields] ORDER BY [SessionName],[ObjectType],[ObjectId],[FieldName];END;
    END;
    IF @JsonErzeugen=1
    BEGIN
        DECLARE @Meta nvarchar(max)=(SELECT N'ExtendedEventsSessions' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@RowCount [sessionCount],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@SessionsJson nvarchar(max)=(SELECT * FROM [#ExtendedEventsSessions_Sessions] ORDER BY [SessionName] FOR JSON PATH,INCLUDE_NULL_VALUES),@EventsJson nvarchar(max)=(SELECT * FROM [#ExtendedEventsSessions_Events] ORDER BY [SessionName],[EventId] FOR JSON PATH,INCLUDE_NULL_VALUES),@ActionsJson nvarchar(max)=(SELECT * FROM [#ExtendedEventsSessions_Actions] ORDER BY [SessionName],[EventName],[ActionOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES),@TargetsJson nvarchar(max)=(SELECT * FROM [#ExtendedEventsSessions_Targets] ORDER BY [SessionName],[TargetId] FOR JSON PATH,INCLUDE_NULL_VALUES),@FieldsJson nvarchar(max)=(SELECT * FROM [#ExtendedEventsSessions_Fields] ORDER BY [SessionName],[ObjectType],[ObjectId],[FieldName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"sessions":',COALESCE(@SessionsJson,N'[]'),N',"events":',COALESCE(@EventsJson,N'[]'),N',"actions":',COALESCE(@ActionsJson,N'[]'),N',"targets":',COALESCE(@TargetsJson,N'[]'),N',"fields":',COALESCE(@FieldsJson,N'[]'),N',"warnings":[]}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ExtendedEventsSessions_Sessions'
            , @ResultLabel=N'ExtendedEventsSessions'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ExtendedEventsSessions_Sessions'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
