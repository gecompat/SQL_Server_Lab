USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_AgentMonitoringAnalysis
Version      : 1.1.0
Stand        : 2026-07-18
Zweck        : Prüft SQL-Agent-/Alert-/Operator-/Job- und Database-Mail-Evidenz.
Datenquellen : sys.dm_server_services, msdb.dbo.sysalerts,
               msdb.dbo.sysoperators, msdb.dbo.sysnotifications,
               msdb.dbo.sysjobs, msdb.dbo.sysjobschedules,
               msdb.dbo.sysschedules, msdb.dbo.sysjobhistory und
               msdb.dbo.sysmail_allitems.
Methodik     : Alert-Routing, Jobzustand und aggregierter Mailstatus werden über
               dieselben reinen Interpretationsfunktionen klassifiziert, die
               der deterministische Laufzeitvertrag verwendet.
Datenschutz  : Liest keine Mailadressen, Empfänger, Betreffzeilen,
               Jobschrittbefehle oder Fehlermeldungstexte.
Grenzen      : Fehlende Standardalarme sind ein Prüfauftrag; externe
               Monitoringwege können die Alarmierung anderweitig abdecken.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_AgentMonitoringAnalysis]
      @HistoryHours       int             = 24
    , @MitJobStatus       bit             = 1
    , @MitDatabaseMail    bit             = 1
    , @MaxZeilen          int             = 1000
    , @ResultSetArt       varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen       bit             = 0
    , @Json               nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen     bit             = 1
    , @Hilfe              bit             = 0
    , @StatusCodeOut      varchar(40)     = NULL OUTPUT
    , @IsPartialOut       bit             = NULL OUTPUT
    , @ErrorNumberOut     int             = NULL OUTPUT
    , @ErrorMessageOut    nvarchar(2048)  = NULL OUTPUT
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'findings',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
                                 THEN CONVERT(bigint, 9223372036854775807)
                                 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_AgentMonitoringAnalysis';
        PRINT N'Prüft Alarmierungs- und Jobmetadaten, liest aber keine Mailadressen, Empfänger oder Jobschrittbefehle.';
        PRINT N'Fehlende SQL-Agent-Alarme können durch externes Monitoring kompensiert sein.';
        PRINT N'@HistoryHours=24; @MaxZeilen positiv, NULL/0 = unbegrenzt.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @CutoffLocal datetime = CASE WHEN @HistoryHours IS NULL THEN NULL ELSE DATEADD(HOUR, -@HistoryHours, GETDATE()) END;
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;

    CREATE TABLE [#AgentMonitoringAnalysis_Services]
    (
          [ServiceName] nvarchar(256) NULL
        , [StatusDesc] nvarchar(60) NULL
        , [StartupTypeDesc] nvarchar(60) NULL
        , [LastStartupTime] datetimeoffset(7) NULL
        , [FindingCode] varchar(80) NOT NULL
    );
    CREATE TABLE [#AgentMonitoringAnalysis_Findings]
    (
          [Category] varchar(40) NOT NULL
        , [FindingCode] varchar(100) NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [ScopeType] nvarchar(40) NOT NULL
        , [ScopeName] nvarchar(256) NULL
        , [MetricValue] bigint NULL
        , [Evidence] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#AgentMonitoringAnalysis_Jobs]
    (
          [JobId] uniqueidentifier NOT NULL
        , [JobName] sysname NOT NULL
        , [IsEnabled] tinyint NOT NULL
        , [LatestRunDateTime] datetime NULL
        , [LatestRunStatus] int NULL
        , [LatestRunDuration] int NULL
        , [ScheduleCount] bigint NOT NULL
        , [EnabledScheduleCount] bigint NOT NULL
        , [FindingCode] varchar(100) NOT NULL
        , [FindingSeverity] varchar(16) NOT NULL
    );
    CREATE TABLE [#AgentMonitoringAnalysis_Mail]
    (
          [SentStatus] varchar(8) NULL
        , [ItemCount] bigint NOT NULL
        , [OldestRequestDate] datetime NULL
        , [NewestRequestDate] datetime NULL
    );

    IF @HistoryHours IS NULL OR @HistoryHours < 1 OR @HistoryHours > 8760 OR @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Historien-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            INSERT [#AgentMonitoringAnalysis_Services]
            SELECT [servicename], [status_desc], [startup_type_desc], [last_startup_time],
                   CASE WHEN [status_desc] = N'Running' THEN 'AGENT_SERVICE_RUNNING'
                        ELSE 'AGENT_SERVICE_NOT_RUNNING' END
            FROM [sys].[dm_server_services] WITH (NOLOCK)
            WHERE [servicename] LIKE N'SQL Server Agent%';
        END TRY
        BEGIN CATCH
            SELECT @IsPartial = 1, @ErrorNumber = ERROR_NUMBER(),
                   @ErrorMessage = CONCAT(N'Dienststatus nicht lesbar: ', ERROR_MESSAGE());
        END CATCH;

        BEGIN TRY
            ;WITH [RequiredAlerts] AS
            (
                SELECT 'MESSAGE_823' AS [Code], 823 AS [MessageId], 0 AS [Severity]
                UNION ALL SELECT 'MESSAGE_824', 824, 0
                UNION ALL SELECT 'MESSAGE_825', 825, 0
                UNION ALL SELECT CONCAT('SEVERITY_', [n]), 0, [n]
                FROM (VALUES (19),(20),(21),(22),(23),(24),(25)) AS [v]([n])
            )
            INSERT [#AgentMonitoringAnalysis_Findings]
            SELECT
                  'ALERT_COVERAGE', 'REQUIRED_AGENT_ALERT_MISSING', 'HIGH', N'ALERT_REQUIREMENT'
                , [r].[Code], NULL
                , CONCAT(N'Kein aktivierter SQL-Agent-Alert für message_id=', [r].[MessageId],
                         N' beziehungsweise severity=', [r].[Severity], N' gefunden.')
                , N'Externe Alarmierung kann die Anforderung erfüllen; Monitoringarchitektur vor Anlage eines Alerts prüfen.'
            FROM [RequiredAlerts] AS [r]
            WHERE NOT EXISTS
            (
                SELECT 1 FROM [msdb].[dbo].[sysalerts] AS [a] WITH (NOLOCK)
                WHERE [a].[enabled] = 1
                  AND (([r].[MessageId] > 0 AND [a].[message_id] = [r].[MessageId])
                    OR ([r].[Severity] > 0 AND [a].[severity] = [r].[Severity]))
            );

            INSERT [#AgentMonitoringAnalysis_Findings]
            SELECT
                  'ALERT_ROUTING', [route].[FindingCode], [route].[FindingSeverity], N'ALERT', [a].[name]
                , CONVERT(bigint, [a].[occurrence_count])
                , N'Aktivierter Alert besitzt weder Operatorbenachrichtigung noch Jobaktion.'
                , N'Externe Weiterleitung und absichtlich rein protokollierende Alerts separat prüfen.'
            FROM [msdb].[dbo].[sysalerts] AS [a] WITH (NOLOCK)
            OUTER APPLY
            (
                SELECT [NotificationCount]=COUNT_BIG(*)
                FROM [msdb].[dbo].[sysnotifications] AS [n] WITH (NOLOCK)
                WHERE [n].[alert_id]=[a].[id]
            ) AS [notifications]
            CROSS APPLY [monitor].[TVF_InterpretAgentAlertRoute]
            (
                  CONVERT(bit,[a].[enabled])
                , CONVERT(bit,CASE WHEN [a].[job_id]<>CONVERT(uniqueidentifier,'00000000-0000-0000-0000-000000000000') THEN 1 ELSE 0 END)
                , [notifications].[NotificationCount]
            ) AS [route]
            WHERE [route].[FindingCode]='ENABLED_ALERT_WITHOUT_ACTION';

            INSERT [#AgentMonitoringAnalysis_Findings]
            SELECT
                  'ALERT_ROUTING', 'ALERT_TARGET_OPERATOR_DISABLED', 'HIGH', N'OPERATOR', [o].[name]
                , COUNT_BIG(*)
                , N'Mindestens ein aktivierter Alert verweist auf einen deaktivierten Operator.'
                , N'Externe Zustellung und Bereitschaftsmodell separat prüfen; Adressdaten werden nicht gelesen.'
            FROM [msdb].[dbo].[sysoperators] AS [o] WITH (NOLOCK)
            JOIN [msdb].[dbo].[sysnotifications] AS [n] WITH (NOLOCK) ON [n].[operator_id] = [o].[id]
            JOIN [msdb].[dbo].[sysalerts] AS [a] WITH (NOLOCK) ON [a].[id] = [n].[alert_id]
            WHERE [a].[enabled] = 1 AND [o].[enabled] = 0
            GROUP BY [o].[name];

            INSERT [#AgentMonitoringAnalysis_Findings]
            SELECT
                  'ALERT_ACTIVITY', 'ALERT_OCCURRED_IN_WINDOW', 'MEDIUM', N'ALERT', [a].[name]
                , CONVERT(bigint, [a].[occurrence_count])
                , N'Der Alert besitzt eine Auftretenshistorie; Meldungstext wird nicht gelesen.'
                , N'occurrence_count kann seit einem früheren Reset kumulativ sein; Zeitstempel und externes Monitoring korrelieren.'
            FROM [msdb].[dbo].[sysalerts] AS [a] WITH (NOLOCK)
            WHERE [a].[enabled] = 1 AND [a].[occurrence_count] > 0
              AND [a].[last_occurrence_date] > 0
              AND [msdb].[dbo].[agent_datetime]
                  ([a].[last_occurrence_date], [a].[last_occurrence_time]) >= @CutoffLocal;
        END TRY
        BEGIN CATCH
            SELECT @IsPartial = 1;
            IF @ErrorNumber IS NULL
                SELECT @ErrorNumber = ERROR_NUMBER(),
                       @ErrorMessage = CONCAT(N'Alert-/Operatorstatus nicht lesbar: ', ERROR_MESSAGE());
        END CATCH;

        IF @MitJobStatus = 1
        BEGIN
            BEGIN TRY
                ;WITH [LatestOutcome] AS
                (
                    SELECT [h].[job_id], [h].[run_status], [h].[run_duration],
                           [msdb].[dbo].[agent_datetime]([h].[run_date], [h].[run_time]) AS [RunDateTime],
                           ROW_NUMBER() OVER
                           (PARTITION BY [h].[job_id] ORDER BY [h].[instance_id] DESC) AS [rn]
                    FROM [msdb].[dbo].[sysjobhistory] AS [h] WITH (NOLOCK)
                    WHERE [h].[step_id] = 0 AND [h].[run_date] > 0
                ),
                [Schedules] AS
                (
                    SELECT [js].[job_id], COUNT_BIG(*) AS [ScheduleCount],
                           SUM(CONVERT(bigint, CASE WHEN [s].[enabled] = 1 THEN 1 ELSE 0 END)) AS [EnabledCount]
                    FROM [msdb].[dbo].[sysjobschedules] AS [js] WITH (NOLOCK)
                    JOIN [msdb].[dbo].[sysschedules] AS [s] WITH (NOLOCK) ON [s].[schedule_id] = [js].[schedule_id]
                    GROUP BY [js].[job_id]
                )
                INSERT [#AgentMonitoringAnalysis_Jobs]
                SELECT
                      [j].[job_id], [j].[name], [j].[enabled], [o].[RunDateTime], [o].[run_status]
                    , [o].[run_duration], COALESCE([s].[ScheduleCount], 0), COALESCE([s].[EnabledCount], 0)
                    , [state].[FindingCode], [state].[FindingSeverity]
                FROM [msdb].[dbo].[sysjobs] AS [j] WITH (NOLOCK)
                LEFT JOIN [LatestOutcome] AS [o] ON [o].[job_id] = [j].[job_id] AND [o].[rn] = 1
                LEFT JOIN [Schedules] AS [s] ON [s].[job_id] = [j].[job_id]
                CROSS APPLY [monitor].[TVF_InterpretAgentJobState]
                (
                      [j].[enabled], [o].[run_status], [o].[RunDateTime], @CutoffLocal
                    , COALESCE([s].[ScheduleCount],0), COALESCE([s].[EnabledCount],0)
                ) AS [state];
            END TRY
            BEGIN CATCH
                SELECT @IsPartial = 1;
                IF @ErrorNumber IS NULL
                    SELECT @ErrorNumber = ERROR_NUMBER(),
                           @ErrorMessage = CONCAT(N'Jobstatus nicht lesbar: ', ERROR_MESSAGE());
            END CATCH;
        END;

        IF @MitDatabaseMail = 1
        BEGIN
            BEGIN TRY
                INSERT [#AgentMonitoringAnalysis_Mail]
                SELECT [sent_status], COUNT_BIG(*), MIN([send_request_date]), MAX([send_request_date])
                FROM [msdb].[dbo].[sysmail_allitems] WITH (NOLOCK)
                WHERE [send_request_date] >= @CutoffLocal
                GROUP BY [sent_status];
            END TRY
            BEGIN CATCH
                SELECT @IsPartial = 1;
                IF @ErrorNumber IS NULL
                    SELECT @ErrorNumber = ERROR_NUMBER(),
                           @ErrorMessage = CONCAT(N'Database-Mail-Status nicht lesbar: ', ERROR_MESSAGE());
            END CATCH;
        END;

        INSERT [#AgentMonitoringAnalysis_Findings]
        SELECT 'JOB_ACTIVITY', [FindingCode], [FindingSeverity],
               N'JOB', [JobName], NULL,
               CONCAT(N'Letzter Status=', COALESCE(CONVERT(nvarchar(20), [LatestRunStatus]), N'NULL'),
                      N'; Schedules=', [ScheduleCount], N'; aktive Schedules=', [EnabledScheduleCount], N'.'),
               N'On-demand Jobs und externe Scheduler können einen fehlenden SQL-Agent-Zeitplan erklären.'
        FROM [#AgentMonitoringAnalysis_Jobs]
        WHERE [FindingCode] <> 'JOB_STATE_INFORMATIONAL';

        INSERT [#AgentMonitoringAnalysis_Findings]
        SELECT 'DATABASE_MAIL', [state].[FindingCode], [state].[FindingSeverity],
               N'MAIL_STATUS', [m].[SentStatus], [m].[ItemCount],
               CONCAT(N'Database-Mail-Elemente mit Status ', [m].[SentStatus], N' im Sichtfenster.'),
               N'Empfänger, Betreff und Nachrichtentext werden bewusst nicht gelesen; Mailserver separat prüfen.'
        FROM [#AgentMonitoringAnalysis_Mail] AS [m]
        CROSS APPLY [monitor].[TVF_InterpretDatabaseMailStatus]([m].[SentStatus]) AS [state]
        WHERE [state].[FindingSeverity] IN ('HIGH','MEDIUM');

        IF @IsPartial = 1
            SET @StatusCode = 'AVAILABLE_LIMITED';
        ELSE IF EXISTS
                (
                    SELECT 1 FROM [#AgentMonitoringAnalysis_Findings] WHERE [Severity] IN ('HIGH', 'MEDIUM')
                    UNION ALL
                    SELECT 1 FROM [#AgentMonitoringAnalysis_Services] WHERE [FindingCode] = 'AGENT_SERVICE_NOT_RUNNING'
                )
            SET @StatusCode = 'AVAILABLE_WITH_FINDING';
    END;

    SELECT @StatusCodeOut = @StatusCode, @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber, @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
            (SELECT N'AgentMonitoringAnalysis' AS [resultName], 1 AS [schemaVersion],
                    @Now AS [generatedAtUtc], @StatusCode AS [statusCode], @IsPartial AS [isPartial],
                    @HistoryHours AS [historyHours]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @ServicesJson nvarchar(max) = (SELECT * FROM [#AgentMonitoringAnalysis_Services] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @FindingsJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AgentMonitoringAnalysis_Findings]
             ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                      [Category], [ScopeName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @JobsJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#AgentMonitoringAnalysis_Jobs] ORDER BY [JobName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @MailJson nvarchar(max) =
            (SELECT * FROM [#AgentMonitoringAnalysis_Mail] ORDER BY [SentStatus] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'),
                           N',"services":', COALESCE(@ServicesJson, N'[]'),
                           N',"findings":', COALESCE(@FindingsJson, N'[]'),
                           N',"jobs":', COALESCE(@JobsJson, N'[]'),
                           N',"mailStatus":', COALESCE(@MailJson, N'[]'), N'}');
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_AgentMonitoringAnalysis' AS [ModuleName], @Now AS [CollectionTimeUtc],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'Keine Adressen, Empfänger, Jobbefehle oder Nachrichtentexte gelesen.' AS [Detail];
        SELECT * FROM [#AgentMonitoringAnalysis_Services];
        SELECT TOP (@Limit) * FROM [#AgentMonitoringAnalysis_Findings]
        ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [Category], [ScopeName];
        SELECT TOP (@Limit) * FROM [#AgentMonitoringAnalysis_Jobs] ORDER BY [JobName];
        SELECT * FROM [#AgentMonitoringAnalysis_Mail] ORDER BY [SentStatus];
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Agent- und Alert-Monitoring' AS [Ergebnis], @Now AS [Stand_UTC],
               @StatusCode AS [Status], @IsPartial AS [Teilweise], @ErrorMessage AS [Hinweis];
        SELECT N'SQL-Agent-Dienst' AS [Ergebnis], [ServiceName] AS [Dienst],
               [StatusDesc] AS [Status], [StartupTypeDesc] AS [Starttyp],
               [LastStartupTime] AS [Letzter_Start], [FindingCode] AS [Befund]
        FROM [#AgentMonitoringAnalysis_Services];
        SELECT TOP (@Limit) N'Monitoring-Befund' AS [Ergebnis], [Category] AS [Kategorie],
               [ScopeType] AS [Bereichstyp], [ScopeName] AS [Bereich],
               [FindingCode] AS [Befund], [Severity] AS [Prioritaet],
               [MetricValue] AS [Messwert], [Evidence] AS [Evidenz], [EvidenceLimit] AS [Grenze]
        FROM [#AgentMonitoringAnalysis_Findings]
        ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [Category], [ScopeName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#AgentMonitoringAnalysis_Findings'
            , @ResultLabel=N'AgentMonitoringAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#AgentMonitoringAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
