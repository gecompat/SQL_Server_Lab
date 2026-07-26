USE [DeineDatenbank];
GO

SET QUOTED_IDENTIFIER ON;
GO

/*
===============================================================================
Objekt       : monitor.USP_CriticalEngineEvents
Version      : 1.0.0
Stand        : 2026-07-17
Zweck        : Liest kritische Engine-Evidenz aus einem vorhandenen
               system_health-Eventfile und optional einmalig aus
               sys.sp_server_diagnostics.
Nebenwirkung : Keine XE- oder Serveränderung. Eventfiles werden nur gelesen.
               sp_server_diagnostics läuft ausschließlich als One-Shot.
Eigenlast    : Eventfile-Lesen MEDIUM und begrenzt; XML-Transfer opt-in.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CriticalEngineEvents]
      @SourceExtendedEventSessionName nvarchar(258) = N'system_health'
    , @FilePath                        nvarchar(4000) = NULL
    , @VonUtc                          datetime2(7)   = NULL
    , @BisUtc                          datetime2(7)   = NULL
    , @MinErrorSeverity                tinyint         = 20
    , @MitSystemHealth                 bit             = 1
    , @MitServerDiagnostics            bit             = 0
    , @MitEventXml                     bit             = 0
    , @MaxZeilen                       int             = 500
    , @ResultSetArt                    varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                    bit             = 0
    , @Json                            nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                  bit             = 1
    , @Hilfe                           bit             = 0
    , @StatusCodeOut                   varchar(40)     = NULL OUTPUT
    , @IsPartialOut                    bit             = NULL OUTPUT
    , @ErrorNumberOut                  int             = NULL OUTPUT
    , @ErrorMessageOut                 nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) =
        UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'events',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             ELSE CONVERT(bigint, @MaxZeilen) END;
    DECLARE @SessionName sysname = NULL;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CriticalEngineEvents';
        PRINT N'@MitSystemHealth=1 liest nur vorhandene event_file-Targets; keine XE-Änderung.';
        PRINT N'@MitServerDiagnostics=0; 1 führt sys.sp_server_diagnostics einmalig ohne Repeat-Modus aus.';
        PRINT N'@MitEventXml=0 reduziert den Transfer; Runtime-Inhalte werden nicht persistiert.';
        PRINT N'@MinErrorSeverity=20; @VonUtc/@BisUtc begrenzen das Eventzeitfenster.';
        RETURN;
    END;

    IF @SourceExtendedEventSessionName IS NOT NULL
       AND (SELECT COUNT_BIG(*)
            FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName)
            WHERE [IsValid] = 1) = 1
       AND NOT EXISTS
           (SELECT 1
            FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName)
            WHERE [IsValid] = 0)
        SELECT @SessionName = MIN([NameValue])
        FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName)
        WHERE [IsValid] = 1;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @MonitorPrintMessage nvarchar(2048) = NULL;
    DECLARE @ConfiguredFilePath nvarchar(4000) = NULL;
    DECLARE @ResolvedFilePath nvarchar(4000) = NULL;

    CREATE TABLE [#CriticalEngineEvents_Events]
    (
          [TimestampUtc] datetime2(7) NULL
        , [EventName] sysname NULL
        , [ErrorNumber] int NULL
        , [Severity] int NULL
        , [ComponentName] sysname NULL
        , [StateDesc] sysname NULL
        , [MessageText] nvarchar(4000) NULL
        , [FindingCode] varchar(100) NOT NULL
        , [EventXml] xml NULL
    );

    CREATE TABLE [#CriticalEngineEvents_Diagnostics]
    (
          [CreateTime] datetime NULL
        , [ComponentType] sysname NULL
        , [ComponentName] sysname NULL
        , [State] int NULL
        , [StateDesc] sysname NULL
        , [Data] xml NULL
    );

    CREATE TABLE [#CriticalEngineEvents_SourceStatus]
    (
          [SourceName] nvarchar(128) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(1000) NULL
    );

    IF @SessionName IS NULL
       OR @MaxZeilen < 0
       OR @MinErrorSeverity > 25
       OR (@VonUtc IS NOT NULL AND @BisUtc IS NOT NULL AND @VonUtc >= @BisUtc)
       OR (@MitSystemHealth = 0 AND @MitServerDiagnostics = 0)
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER',
               @IsPartial = 1,
               @ErrorMessage = N'Ungültige Session-, Zeit-, Severity-, Modul-, Zeilen- oder Ausgabeparameter.';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE' AND @MitSystemHealth = 1
    BEGIN
        BEGIN TRY
            SELECT @ConfiguredFilePath = MAX(CONVERT(nvarchar(4000), [f].[value]))
            FROM [sys].[server_event_sessions] AS [s] WITH (NOLOCK)
            JOIN [sys].[server_event_session_targets] AS [t] WITH (NOLOCK)
              ON [t].[event_session_id] = [s].[event_session_id]
             AND [t].[name] = N'event_file'
            LEFT JOIN [sys].[server_event_session_fields] AS [f] WITH (NOLOCK)
              ON [f].[event_session_id] = [t].[event_session_id]
             AND [f].[object_id] = [t].[target_id]
             AND [f].[name] = N'filename'
            WHERE [s].[name] = @SessionName;

            SET @ResolvedFilePath = COALESCE(NULLIF(@FilePath, N''), NULLIF(@ConfiguredFilePath, N''));

            IF @ResolvedFilePath IS NULL
            BEGIN
                SET @IsPartial = 1;
                INSERT [#CriticalEngineEvents_SourceStatus]
                VALUES
                (
                      N'system_health event_file', 'UNAVAILABLE_OBJECT', NULL, NULL
                    , N'Kein lesbarer event_file-Pfad vorhanden; es wurde kein Ringbuffer gelesen.'
                );
            END
            ELSE
            BEGIN
                IF RIGHT(LOWER(@ResolvedFilePath), 4) = N'.xel'
                    SET @ResolvedFilePath =
                        LEFT(@ResolvedFilePath, LEN(@ResolvedFilePath) - 4) + N'*.xel';
                ELSE IF CHARINDEX(N'*', @ResolvedFilePath) = 0
                    SET @ResolvedFilePath = @ResolvedFilePath + N'*.xel';

                ;WITH [RawEvents] AS
                (
                    SELECT TOP (@Limit)
                          [r].[timestamp_utc] AS [TimestampUtc]
                        , [r].[object_name] AS [EventName]
                        , CONVERT(xml, [r].[event_data]) AS [EventXml]
                    FROM [sys].[fn_xe_file_target_read_file]
                         (@ResolvedFilePath, NULL, NULL, NULL) AS [r]
                    WHERE [r].[object_name] IN
                    (
                          N'error_reported'
                        , N'scheduler_monitor_non_yielding_ring_buffer_recorded'
                        , N'scheduler_monitor_non_yielding_iocp_ring_buffer_recorded'
                        , N'scheduler_monitor_stalled_dispatcher_ring_buffer_recorded'
                        , N'sp_server_diagnostics_component_result'
                        , N'memory_broker_ring_buffer_recorded'
                        , N'resource_monitor_ring_buffer_recorded'
                        , N'connectivity_ring_buffer_recorded'
                        , N'xml_deadlock_report'
                    )
                      AND (@VonUtc IS NULL OR [r].[timestamp_utc] >= @VonUtc)
                      AND (@BisUtc IS NULL OR [r].[timestamp_utc] < @BisUtc)
                    ORDER BY [r].[timestamp_utc] DESC, [r].[file_name] DESC, [r].[file_offset] DESC
                ),
                [Parsed] AS
                (
                    SELECT
                          [TimestampUtc], [EventName], [EventXml]
                        , [EventXml].value('(event/data[@name="error_number"]/value/text())[1]', 'int') AS [ErrorNumber]
                        , [EventXml].value('(event/data[@name="severity"]/value/text())[1]', 'int') AS [Severity]
                        , [EventXml].value('(event/data[@name="component_name"]/value/text())[1]', 'sysname') AS [ComponentName]
                        , [EventXml].value('(event/data[@name="state_desc"]/value/text())[1]', 'sysname') AS [StateDesc]
                        , [EventXml].value('(event/data[@name="message"]/value/text())[1]', 'nvarchar(4000)') AS [MessageText]
                    FROM [RawEvents]
                    WHERE [EventXml] IS NOT NULL
                )
                INSERT [#CriticalEngineEvents_Events]
                SELECT
                      [TimestampUtc], [EventName], [ErrorNumber], [Severity]
                    , [ComponentName], [StateDesc], [MessageText]
                    , CASE
                          WHEN [EventName] LIKE N'scheduler_monitor_non_yielding%' THEN 'NON_YIELDING_SCHEDULER'
                          WHEN [EventName] = N'scheduler_monitor_stalled_dispatcher_ring_buffer_recorded' THEN 'STALLED_DISPATCHER'
                          WHEN [EventName] = N'error_reported' THEN 'SEVERE_ERROR_REPORTED'
                          WHEN [EventName] = N'sp_server_diagnostics_component_result'
                           AND LOWER(COALESCE([StateDesc], N'')) IN (N'warning', N'error')
                              THEN 'SERVER_DIAGNOSTICS_WARNING_OR_ERROR'
                          WHEN [EventName] IN
                               (N'memory_broker_ring_buffer_recorded', N'resource_monitor_ring_buffer_recorded')
                              THEN 'MEMORY_OR_RESOURCE_MONITOR_EVENT'
                          WHEN [EventName] = N'connectivity_ring_buffer_recorded' THEN 'CONNECTIVITY_EVENT'
                          WHEN [EventName] = N'xml_deadlock_report' THEN 'DEADLOCK_EVENT'
                          ELSE 'CRITICAL_EVENT_REVIEW'
                      END
                    , CASE WHEN @MitEventXml = 1 THEN [EventXml] END
                FROM [Parsed]
                WHERE [EventName] <> N'error_reported'
                   OR COALESCE([Severity], 0) >= @MinErrorSeverity
                   OR [ErrorNumber] IN (701, 802, 823, 824, 825, 832, 833, 8645, 8651, 17803);

                INSERT [#CriticalEngineEvents_SourceStatus]
                VALUES
                (
                      N'system_health event_file', 'AVAILABLE', NULL, NULL
                    , N'Vorhandene Eventfiles wurden begrenzt und rein lesend ausgewertet.'
                );
            END;
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            INSERT [#CriticalEngineEvents_SourceStatus]
            VALUES
            (
                  N'system_health event_file'
                , CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371) THEN 'DENIED_PERMISSION'
                       WHEN ERROR_NUMBER() IN(6335,6336,6337) THEN 'XML_UNAVAILABLE_LIMIT'
                       WHEN ERROR_NUMBER() BETWEEN 9400 AND 9431 THEN 'XML_INVALID'
                       ELSE 'ERROR_HANDLED' END
                , ERROR_NUMBER(), ERROR_MESSAGE()
                , N'Das Eventfile konnte nicht ausgewertet werden; andere Quellen bleiben verfügbar.'
            );
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitServerDiagnostics = 1
    BEGIN
        BEGIN TRY
            INSERT [#CriticalEngineEvents_Diagnostics]
            EXEC [sys].[sp_server_diagnostics] 0;

            INSERT [#CriticalEngineEvents_SourceStatus]
            VALUES
            (
                  N'sp_server_diagnostics', 'AVAILABLE', NULL, NULL
                , N'One-Shot-Aufruf ohne Repeat-Modus; vollständige Daten können mindestens fünf Sekunden benötigen.'
            );
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            INSERT [#CriticalEngineEvents_SourceStatus]
            VALUES
            (
                  N'sp_server_diagnostics'
                , CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371)
                       THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END
                , ERROR_NUMBER(), ERROR_MESSAGE()
                , N'One-Shot-Diagnose nicht verfügbar; kein Wiederholungsmodus gestartet.'
            );
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE'
       AND (@IsPartial = 1 OR EXISTS
           (SELECT 1 FROM [#CriticalEngineEvents_SourceStatus] WHERE [StatusCode] <> 'AVAILABLE'))
        SET @StatusCode = 'AVAILABLE_LIMITED';
    ELSE IF @StatusCode = 'AVAILABLE'
        AND EXISTS (SELECT 1 FROM [#CriticalEngineEvents_Events])
        SET @StatusCode = 'AVAILABLE_WITH_FINDING';

    SELECT @StatusCodeOut = @StatusCode,
           @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber,
           @ErrorMessageOut = @ErrorMessage;

    IF @PrintMeldungen = 1 AND @StatusCode <> 'AVAILABLE'
    BEGIN
        SET @MonitorPrintMessage = COALESCE(@ErrorMessage, CONVERT(nvarchar(2048), @StatusCode));
        RAISERROR(N'USP_CriticalEngineEvents: %s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT CAST('1.0' AS varchar(16)) AS [ContractVersion], @Now AS [CollectionTimeUtc],
               N'monitor.USP_CriticalEngineEvents' AS [ModuleName],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT * FROM [#CriticalEngineEvents_Events] ORDER BY [TimestampUtc] DESC, [EventName];
            SELECT * FROM [#CriticalEngineEvents_Diagnostics] ORDER BY [CreateTime], [ComponentName];
            SELECT * FROM [#CriticalEngineEvents_SourceStatus] ORDER BY [SourceName];
        END
        ELSE
        BEGIN
            SELECT
                  N'Kritisches Engine-Ereignis' AS [Ergebnis]
                , [TimestampUtc] AS [Zeit UTC]
                , [FindingCode] AS [Bewertung]
                , [EventName] AS [Event]
                , [ErrorNumber] AS [Fehlernummer]
                , [Severity] AS [Severity]
                , [ComponentName] AS [Komponente]
                , [StateDesc] AS [Zustand]
                , [MessageText] AS [Meldung]
                , [EventXml] AS [Event XML]
            FROM [#CriticalEngineEvents_Events]
            ORDER BY [TimestampUtc] DESC, [EventName];

            SELECT
                  N'Server Diagnostics' AS [Ergebnis]
                , [CreateTime] AS [Zeit]
                , [ComponentType] AS [Komponententyp]
                , [ComponentName] AS [Komponente]
                , [StateDesc] AS [Zustand]
                , CASE WHEN @MitEventXml = 1 THEN [Data] END AS [Daten XML]
            FROM [#CriticalEngineEvents_Diagnostics]
            ORDER BY [CreateTime], [ComponentName];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT N'CriticalEngineEvents' AS [resultName], 1 AS [schemaVersion],
                   @Now AS [generatedAtUtc], @StatusCode AS [statusCode],
                   @IsPartial AS [isPartial], @ErrorNumber AS [errorNumber],
                   @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @EventsJson nvarchar(max) =
            (SELECT * FROM [#CriticalEngineEvents_Events] ORDER BY [TimestampUtc] DESC FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @DiagnosticsJson nvarchar(max) =
            (SELECT [CreateTime], [ComponentType], [ComponentName], [State], [StateDesc],
                    CASE WHEN @MitEventXml = 1 THEN [Data] END AS [Data]
             FROM [#CriticalEngineEvents_Diagnostics] ORDER BY [CreateTime], [ComponentName]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @SourcesJson nvarchar(max) =
            (SELECT * FROM [#CriticalEngineEvents_SourceStatus] ORDER BY [SourceName] FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"events":', COALESCE(@EventsJson, N'[]')
            , N',"serverDiagnostics":', COALESCE(@DiagnosticsJson, N'[]')
            , N',"sources":', COALESCE(@SourcesJson, N'[]')
            , N',"warnings":[]}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CriticalEngineEvents_Events'
            , @ResultLabel=N'CriticalEngineEvents'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#CriticalEngineEvents_Events'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
