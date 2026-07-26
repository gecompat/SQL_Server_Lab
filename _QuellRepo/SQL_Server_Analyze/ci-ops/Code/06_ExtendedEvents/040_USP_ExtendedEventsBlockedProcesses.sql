USE [DeineDatenbank];
GO

SET QUOTED_IDENTIFIER ON;
GO

/*
===============================================================================
Objekt       : monitor.USP_ExtendedEventsBlockedProcesses
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Liest bereits erfasste blocked_process_report-Ereignisse aus
               vorhandenen Extended-Events-Targets und zerlegt die Reports in
               Summary-, Blocked- und Blocking-Process-Resultsets.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : vorhandene serverweite XE-Session mit blocked_process_report,
               event_file oder optional ring_buffer; sys.configurations lesend.
Parameter    : @ResolvedSourceExtendedEventSessionName, @Quelle, @FilePath, @VonUtc, @BisUtc,
               @MaxZeilen, @MitReportXml, @MitProcessXml,
               @BestaetigeTargetFlush, @PrintMeldungen, @Hilfe.
Resultsets   : 1. Modulstatus. 2. Report-Summary. 3. blocked process.
               4. blocking process. 5. Quellen-/Fehlerstatus.
Berechtigung : SQL 2019 VIEW SERVER STATE; SQL 2022+ VIEW SERVER PERFORMANCE
               STATE oder höher. Das Framework vergibt keine Rechte.
Eigenlast    : Event-Datei- und XML-abhängig; begrenzte Ergebnismenge und
               Vorfilter vor XML-Zerlegung. XEL-Dateien können dennoch vollständig
               gelesen werden müssen.
Locking      : LOCK_TIMEOUT 0; keine Benutzerobjekte und keine Änderungen.
Nebenwirkung : Ringbuffer-Lesen erfordert @BestaetigeTargetFlush=1.
Voraussetzung: Reports existieren nur, wenn blocked process threshold und eine
               erfassende Session bereits außerhalb des Frameworks konfiguriert sind.
Partial      : Fehlende Konfiguration, Session, Datei oder Rechte werden als Status
               gemeldet und brechen andere Monitoring-Funktionen nicht ab.
Beispiele    : EXEC monitor.USP_ExtendedEventsBlockedProcesses;
               EXEC monitor.USP_ExtendedEventsBlockedProcesses
                   @ResolvedSourceExtendedEventSessionName=N'MeineBlockingSession', @Quelle='EVENT_FILE';
               EXEC monitor.USP_ExtendedEventsBlockedProcesses @Hilfe=1;
Änderungen   : 1.0.0 - Erstfassung Phase 5.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ExtendedEventsBlockedProcesses]
      @SourceExtendedEventSessionName nvarchar(258)         = NULL
    , @Quelle                  varchar(20)     = 'AUTO'
    , @FilePath                nvarchar(4000)  = NULL
    , @VonUtc                  datetime2(7)    = NULL
    , @BisUtc                  datetime2(7)    = NULL
    , @MaxZeilen              int             = 200
    , @MitReportXml            bit             = 1
    , @MitProcessXml           bit             = 0
    , @BestaetigeTargetFlush   bit             = 0
    , @HighImpactConfirmed     bit             = 0
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen          bit             = 1
    , @Hilfe                   bit             = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'reports',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @ResolvedSourceExtendedEventSessionName sysname=NULL;
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ExtendedEventsBlockedProcesses';
        PRINT N'@ResolvedSourceExtendedEventSessionName sysname=NULL: konkrete vorhandene Session; NULL sucht eine Session mit blocked_process_report.';
        PRINT N'@Quelle varchar(20)=''AUTO'': AUTO, EVENT_FILE oder RING_BUFFER; AUTO bevorzugt EVENT_FILE.';
        PRINT N'@FilePath nvarchar(4000)=NULL: optionaler XEL-Pfad/URL; NULL liest die Sessiondefinition.';
        PRINT N'@VonUtc datetime2(7)=NULL: NULL verwendet letzte 24 Stunden; @BisUtc datetime2(7)=NULL: exklusive Obergrenze.';
        PRINT N'@MaxZeilen int=200: positive Werte begrenzen; NULL/0 = unbegrenzt.';
        PRINT N'@MitReportXml bit=1: vollständiges blocked-process-report XML im Summary.';
        PRINT N'@MitProcessXml bit=0: Prozess-XML in den Detailresultsets.';
        PRINT N'@BestaetigeTargetFlush bit=0: für RING_BUFFER auf 1 setzen.';
        PRINT N'@PrintMeldungen bit=1: Warnungen Severity 10; @Hilfe bit=0: 1 zeigt diese Hilfe.';
        PRINT N'Die Procedure ändert weder blocked process threshold noch Extended-Events-Sessions.';
        RETURN;
    END;

    IF @SourceExtendedEventSessionName IS NULL OR (SELECT COUNT_BIG(*) FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName) WHERE [IsValid]=1)<>1 OR EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName) WHERE [IsValid]=0)
    BEGIN SET @ResolvedSourceExtendedEventSessionName=NULL;END
    ELSE SELECT @ResolvedSourceExtendedEventSessionName=MIN([NameValue]) FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName) WHERE [IsValid]=1;

    DECLARE
        @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),
        @StatusCode varchar(40)='AVAILABLE',
        @IsPartial bit=0,
        @ErrorNumber int=NULL,
        @ErrorMessage nvarchar(2048)=NULL,
        @RowCount bigint=0,
        @Allowed bit=1,
        @ResolvedSource varchar(20)=UPPER(LTRIM(RTRIM(COALESCE(@Quelle,'')))),
        @ResolvedSessionName sysname=@ResolvedSourceExtendedEventSessionName,
        @ConfiguredFilePath nvarchar(4000)=NULL,
        @ResolvedFilePath nvarchar(4000)=NULL,
        @TargetData xml=NULL,
        @BlockedProcessThresholdSeconds int=NULL;

    IF @VonUtc IS NULL SET @VonUtc=DATEADD(HOUR,-24,SYSUTCDATETIME());

    CREATE TABLE [#ExtendedEventsBlockedProcesses_Raw]([SourceType] varchar(20) NOT NULL,[TimestampUtc] datetime2(7) NULL,[FileName] nvarchar(260) NULL,[FileOffset] bigint NULL,[EventXml] xml NULL);
    CREATE TABLE [#ExtendedEventsBlockedProcesses_Reports]
    (
        [ReportId] int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [SourceType] varchar(20) NOT NULL,
        [ReportTimeUtc] datetime2(7) NULL,
        [FileName] nvarchar(260) NULL,
        [FileOffset] bigint NULL,
        [ReportXml] xml NULL
    );
    CREATE TABLE [#ExtendedEventsBlockedProcesses_SourceStatus]
    (
        [SourceType] varchar(20) NULL,[SessionName] sysname NULL,[ResolvedPath] nvarchar(4000) NULL,
        [StatusCode] varchar(40) NOT NULL,[ErrorNumber] int NULL,[ErrorMessage] nvarchar(2048) NULL,[Detail] nvarchar(1000) NULL
    );

    IF @ResolvedSource NOT IN('AUTO','EVENT_FILE','RING_BUFFER')
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'@Quelle muss AUTO, EVENT_FILE oder RING_BUFFER sein.';END;
    IF @MaxZeilen<0 OR @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE')
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'@MaxZeilen darf nicht negativ sein; NULL/0 bedeutet unbegrenzt.';END;
    IF @VonUtc IS NOT NULL AND @BisUtc IS NOT NULL AND @VonUtc>=@BisUtc
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'@VonUtc muss kleiner als @BisUtc sein.';END;

    IF @StatusCode='AVAILABLE'
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='EXTENDED_EVENTS_FORENSICS_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@StatusCode OUTPUT,@ErrorMessage=@ErrorMessage OUTPUT;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode='AVAILABLE'
    BEGIN
        BEGIN TRY
            SELECT @BlockedProcessThresholdSeconds=TRY_CONVERT([int],[value_in_use])
            FROM [sys].[configurations] WITH (NOLOCK) WHERE [name]=N'blocked process threshold (s)';
        END TRY
        BEGIN CATCH
            SET @IsPartial=1;
        END CATCH;

        BEGIN TRY
            IF @ResolvedSessionName IS NULL
            BEGIN
                SELECT TOP(1) @ResolvedSessionName=[s].[name]
                FROM [sys].[server_event_sessions] AS s WITH (NOLOCK)
                JOIN [sys].[server_event_session_events] AS e WITH (NOLOCK)
                  ON [e].[event_session_id]=[s].[event_session_id] AND [e].[name]=N'blocked_process_report'
                ORDER BY CASE WHEN EXISTS
                (
                    SELECT 1 FROM [sys].[server_event_session_targets] AS t WITH (NOLOCK)
                    WHERE [t].[event_session_id]=[s].[event_session_id] AND [t].[name]=N'event_file'
                ) THEN 0 ELSE 1 END,[s].[name];
            END;

            IF @ResolvedSessionName IS NOT NULL
            BEGIN
                SELECT @ConfiguredFilePath=MAX(CONVERT(nvarchar(4000),[f].[value]))
                FROM [sys].[server_event_sessions] AS s WITH (NOLOCK)
                JOIN [sys].[server_event_session_targets] AS t WITH (NOLOCK)
                  ON [t].[event_session_id]=[s].[event_session_id] AND [t].[name]=N'event_file'
                LEFT JOIN [sys].[server_event_session_fields] AS f WITH (NOLOCK)
                  ON [f].[event_session_id]=[t].[event_session_id] AND [f].[object_id]=[t].[target_id] AND [f].[name]=N'filename'
                WHERE [s].[name]=@ResolvedSessionName;
            END;
        END TRY
        BEGIN CATCH
            SET @IsPartial=1;
            INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('CATALOG',@ResolvedSessionName,NULL,
                CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                ERROR_NUMBER(),ERROR_MESSAGE(),N'Session- oder Pfadermittlung fehlgeschlagen.');
        END CATCH;

        IF @ResolvedSessionName IS NULL AND @FilePath IS NULL
        BEGIN
            SET @StatusCode='AVAILABLE_DISABLED';
            SET @ErrorMessage=N'Keine sichtbare Session mit blocked_process_report gefunden.';
            INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('CATALOG',NULL,NULL,@StatusCode,NULL,@ErrorMessage,
                CONCAT(N'blocked process threshold in use = ',COALESCE(CONVERT(nvarchar(20),@BlockedProcessThresholdSeconds),N'unbekannt'),N' Sekunden; das Framework ändert diese Einstellung nicht.'));
        END
        ELSE IF @ResolvedSource='AUTO'
        BEGIN
            IF @FilePath IS NOT NULL OR @ConfiguredFilePath IS NOT NULL SET @ResolvedSource='EVENT_FILE';
            ELSE IF @BestaetigeTargetFlush=1 SET @ResolvedSource='RING_BUFFER';
            ELSE BEGIN SET @StatusCode='AVAILABLE_DISABLED';SET @ErrorMessage=N'Kein event_file-Pfad; Ringbuffer ohne Bestätigung nicht gelesen.';END;
        END;
    END;

    IF @StatusCode='AVAILABLE' AND @ResolvedSource='EVENT_FILE'
    BEGIN
        SET @ResolvedFilePath=COALESCE(NULLIF(@FilePath,N''),NULLIF(@ConfiguredFilePath,N''));
        IF @ResolvedFilePath IS NULL
        BEGIN
            SET @StatusCode='UNAVAILABLE_OBJECT';SET @ErrorMessage=N'Kein event_file-Pfad verfügbar.';
            INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('EVENT_FILE',@ResolvedSessionName,NULL,@StatusCode,NULL,@ErrorMessage,N'Keine Datei gelesen.');
        END
        ELSE
        BEGIN
            IF (RIGHT(LOWER(@ResolvedFilePath),4) = N'.xel')
                SET @ResolvedFilePath=LEFT(@ResolvedFilePath,LEN(@ResolvedFilePath)-4)+N'*.xel';
            ELSE IF CHARINDEX(N'*',@ResolvedFilePath)=0
                SET @ResolvedFilePath=@ResolvedFilePath+N'*.xel';
            BEGIN TRY
                INSERT [#ExtendedEventsBlockedProcesses_Raw]
                SELECT TOP (@EffectiveMaxZeilen) 'EVENT_FILE',[r].[timestamp_utc],[r].[file_name],[r].[file_offset],CONVERT([xml],[r].[event_data])
                FROM sys.fn_xe_file_target_read_file(@ResolvedFilePath,NULL,NULL,NULL) AS r
                WHERE [r].[object_name]=N'blocked_process_report'
                  AND (@VonUtc IS NULL OR [r].[timestamp_utc]>=@VonUtc)
                  AND (@BisUtc IS NULL OR [r].[timestamp_utc]<@BisUtc)
                ORDER BY [r].[timestamp_utc] DESC,[r].[file_name] DESC,[r].[file_offset] DESC;
                INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('EVENT_FILE',@ResolvedSessionName,@ResolvedFilePath,'AVAILABLE',NULL,NULL,N'blocked_process_report aus XEL gelesen.');
            END TRY
            BEGIN CATCH
                SET @StatusCode=CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN(6335,6336,6337) THEN 'XML_UNAVAILABLE_LIMIT' WHEN ERROR_NUMBER() BETWEEN 9400 AND 9431 THEN 'XML_INVALID' ELSE 'ERROR_HANDLED' END;
                SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();
                INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('EVENT_FILE',@ResolvedSessionName,@ResolvedFilePath,@StatusCode,@ErrorNumber,@ErrorMessage,N'XEL-Datei konnte nicht gelesen werden.');
            END CATCH;
        END;
    END;

    IF @StatusCode='AVAILABLE' AND @ResolvedSource='RING_BUFFER'
    BEGIN
        IF @BestaetigeTargetFlush=0
        BEGIN
            SET @StatusCode='AVAILABLE_DISABLED';SET @ErrorMessage=N'RING_BUFFER erfordert @BestaetigeTargetFlush=1.';
            INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('RING_BUFFER',@ResolvedSessionName,NULL,@StatusCode,NULL,@ErrorMessage,N'Targetdaten nicht gelesen.');
        END
        ELSE
        BEGIN
            BEGIN TRY
                SELECT @TargetData=CONVERT([xml],[t].[target_data])
                FROM [sys].[dm_xe_session_targets] AS t WITH (NOLOCK)
                JOIN [sys].[dm_xe_sessions] AS s WITH (NOLOCK) ON [s].[address]=[t].[event_session_address]
                WHERE [s].[name]=@ResolvedSessionName AND [t].[target_name]=N'ring_buffer';
                IF @TargetData IS NULL
                BEGIN
                    SET @StatusCode='UNAVAILABLE_OBJECT';SET @ErrorMessage=N'Kein lesbares laufendes ring_buffer-Target gefunden.';
                    INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('RING_BUFFER',@ResolvedSessionName,NULL,@StatusCode,NULL,@ErrorMessage,N'Session gestoppt oder kein Ringbuffer.');
                END
                ELSE
                BEGIN
                    INSERT [#ExtendedEventsBlockedProcesses_Raw]
                    SELECT TOP (@EffectiveMaxZeilen) 'RING_BUFFER',x.e.value('(@timestamp)[1]','datetime2(7)'),NULL,NULL,x.e.query('.')
                    FROM @TargetData.nodes('/RingBufferTarget/event[@name="blocked_process_report"]') AS [x]([e])
                    WHERE (@VonUtc IS NULL OR x.e.value('(@timestamp)[1]','datetime2(7)')>=@VonUtc)
                      AND (@BisUtc IS NULL OR x.e.value('(@timestamp)[1]','datetime2(7)')<@BisUtc)
                    ORDER BY x.e.value('(@timestamp)[1]','datetime2(7)') DESC;
                    INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('RING_BUFFER',@ResolvedSessionName,NULL,'AVAILABLE',NULL,NULL,N'Ringbuffer bewusst gelesen; Target-Flush möglich.');
                END;
            END TRY
            BEGIN CATCH
                SET @StatusCode=CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN(6335,6336,6337) THEN 'XML_UNAVAILABLE_LIMIT' WHEN ERROR_NUMBER() BETWEEN 9400 AND 9431 THEN 'XML_INVALID' ELSE 'ERROR_HANDLED' END;
                SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();
                INSERT [#ExtendedEventsBlockedProcesses_SourceStatus] VALUES('RING_BUFFER',@ResolvedSessionName,NULL,@StatusCode,@ErrorNumber,@ErrorMessage,N'Ringbuffer konnte nicht gelesen werden.');
            END CATCH;
        END;
    END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        INSERT [#ExtendedEventsBlockedProcesses_Reports]([SourceType],[ReportTimeUtc],[FileName],[FileOffset],[ReportXml])
        SELECT [SourceType],[TimestampUtc],[FileName],[FileOffset],
               EventXml.query('(/event/data[@name="blocked_process"]/value/blocked-process-report)[1]')
        FROM [#ExtendedEventsBlockedProcesses_Raw]
        WHERE EventXml.exist('/event/data[@name="blocked_process"]/value/blocked-process-report')=1;

        SELECT @RowCount=COUNT_BIG(*) FROM [#ExtendedEventsBlockedProcesses_Reports];
        IF @RowCount=0
        BEGIN SET @StatusCode='AVAILABLE_LIMITED';SET @IsPartial=1;SET @ErrorMessage=N'Quelle lesbar, aber keine passenden Blocked-Process-Reports gefunden.';END;
    END;

    IF @IsPartial=1 AND @StatusCode='AVAILABLE' SET @StatusCode='AVAILABLE_LIMITED';


    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE','AVAILABLE_LIMITED')
        BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ExtendedEventsBlockedProcesses: %s - %s', @StatusCode, COALESCE(@ErrorMessage,N'Keine Details.'));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;

    CREATE TABLE [#ExtendedEventsBlockedProcesses_ReportSummary]([ReportId] int,[SourceType] varchar(20),[ReportTimeUtc] datetime2(7),[FileName] nvarchar(260),[FileOffset] bigint,[MonitorLoop] bigint NULL,[BlockedSessionId] int NULL,[BlockingSessionId] int NULL,[WaitTimeMs] bigint NULL,[DatabaseId] int NULL,[DatabaseName] nvarchar(256),[WaitResource] nvarchar(1024),[RequestedLockMode] nvarchar(64),[ReportXml] xml NULL);
    CREATE TABLE [#ExtendedEventsBlockedProcesses_BlockedProcesses]([ReportId] int,[ReportTimeUtc] datetime2(7),[SessionId] int NULL,[ExecutionContextId] int NULL,[ProcessStatus] nvarchar(128),[WaitResource] nvarchar(1024),[WaitTimeMs] bigint NULL,[LockMode] nvarchar(64),[DatabaseId] int NULL,[DatabaseName] nvarchar(256),[ClientApplication] nvarchar(512),[HostName] nvarchar(512),[LoginName] nvarchar(512),[InputBuffer] nvarchar(4000),[ProcessXml] xml NULL);
    CREATE TABLE [#ExtendedEventsBlockedProcesses_BlockingProcesses]([ReportId] int,[ReportTimeUtc] datetime2(7),[SessionId] int NULL,[ExecutionContextId] int NULL,[ProcessStatus] nvarchar(128),[WaitResource] nvarchar(1024),[WaitTimeMs] bigint NULL,[LockMode] nvarchar(64),[DatabaseId] int NULL,[DatabaseName] nvarchar(256),[ClientApplication] nvarchar(512),[HostName] nvarchar(512),[LoginName] nvarchar(512),[InputBuffer] nvarchar(4000),[ProcessXml] xml NULL);
    INSERT [#ExtendedEventsBlockedProcesses_ReportSummary] SELECT [r].[ReportId],[r].[SourceType],[r].[ReportTimeUtc],[r].[FileName],[r].[FileOffset],TRY_CONVERT(bigint,[r].[ReportXml].value('(/blocked-process-report/@monitorLoop)[1]','nvarchar(64)')),TRY_CONVERT(int,[r].[ReportXml].value('(/blocked-process-report/blocked-process/process/@spid)[1]','nvarchar(32)')),TRY_CONVERT(int,[r].[ReportXml].value('(/blocked-process-report/blocking-process/process/@spid)[1]','nvarchar(32)')),TRY_CONVERT(bigint,[r].[ReportXml].value('(/blocked-process-report/blocked-process/process/@waittime)[1]','nvarchar(64)')),TRY_CONVERT(int,[r].[ReportXml].value('(/blocked-process-report/blocked-process/process/@currentdb)[1]','nvarchar(32)')),[r].[ReportXml].value('(/blocked-process-report/blocked-process/process/@currentdbname)[1]','nvarchar(256)'),[r].[ReportXml].value('(/blocked-process-report/blocked-process/process/@waitresource)[1]','nvarchar(1024)'),[r].[ReportXml].value('(/blocked-process-report/blocked-process/process/@lockMode)[1]','nvarchar(64)'),CASE WHEN @MitReportXml=1 THEN [r].[ReportXml] END FROM [#ExtendedEventsBlockedProcesses_Reports] [r];
    INSERT [#ExtendedEventsBlockedProcesses_BlockedProcesses] SELECT [r].[ReportId],[r].[ReportTimeUtc],TRY_CONVERT(int,[p].[n].value('(@spid)[1]','nvarchar(32)')),TRY_CONVERT(int,[p].[n].value('(@ecid)[1]','nvarchar(32)')),[p].[n].value('(@status)[1]','nvarchar(128)'),[p].[n].value('(@waitresource)[1]','nvarchar(1024)'),TRY_CONVERT(bigint,[p].[n].value('(@waittime)[1]','nvarchar(64)')),[p].[n].value('(@lockMode)[1]','nvarchar(64)'),TRY_CONVERT(int,[p].[n].value('(@currentdb)[1]','nvarchar(32)')),[p].[n].value('(@currentdbname)[1]','nvarchar(256)'),[p].[n].value('(@clientapp)[1]','nvarchar(512)'),[p].[n].value('(@hostname)[1]','nvarchar(512)'),[p].[n].value('(@loginname)[1]','nvarchar(512)'),[p].[n].value('(inputbuf/text())[1]','nvarchar(4000)'),CASE WHEN @MitProcessXml=1 THEN [p].[n].query('.') END FROM [#ExtendedEventsBlockedProcesses_Reports] [r] CROSS APPLY [r].[ReportXml].nodes('/blocked-process-report/blocked-process/process') [p]([n]);
    INSERT [#ExtendedEventsBlockedProcesses_BlockingProcesses] SELECT [r].[ReportId],[r].[ReportTimeUtc],TRY_CONVERT(int,[p].[n].value('(@spid)[1]','nvarchar(32)')),TRY_CONVERT(int,[p].[n].value('(@ecid)[1]','nvarchar(32)')),[p].[n].value('(@status)[1]','nvarchar(128)'),[p].[n].value('(@waitresource)[1]','nvarchar(1024)'),TRY_CONVERT(bigint,[p].[n].value('(@waittime)[1]','nvarchar(64)')),[p].[n].value('(@lockMode)[1]','nvarchar(64)'),TRY_CONVERT(int,[p].[n].value('(@currentdb)[1]','nvarchar(32)')),[p].[n].value('(@currentdbname)[1]','nvarchar(256)'),[p].[n].value('(@clientapp)[1]','nvarchar(512)'),[p].[n].value('(@hostname)[1]','nvarchar(512)'),[p].[n].value('(@loginname)[1]','nvarchar(512)'),[p].[n].value('(inputbuf/text())[1]','nvarchar(4000)'),CASE WHEN @MitProcessXml=1 THEN [p].[n].query('.') END FROM [#ExtendedEventsBlockedProcesses_Reports] [r] CROSS APPLY [r].[ReportXml].nodes('/blocked-process-report/blocking-process/process') [p]([n]);
    IF @ResultSetArtNormalisiert<>'NONE'
    BEGIN SELECT N'USP_ExtendedEventsBlockedProcesses' [ModuleName],@CollectionTimeUtc [CollectionTimeUtc],@StatusCode [StatusCode],@IsPartial [IsPartial],@RowCount [RowCount],@ResolvedSessionName [SessionName],@ResolvedSource [ResolvedSource],@BlockedProcessThresholdSeconds [BlockedProcessThresholdSeconds],@ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage];IF @ResultSetArtNormalisiert='RAW' BEGIN SELECT * FROM [#ExtendedEventsBlockedProcesses_ReportSummary] ORDER BY [ReportTimeUtc] DESC,[ReportId];SELECT * FROM [#ExtendedEventsBlockedProcesses_BlockedProcesses] ORDER BY [ReportTimeUtc] DESC,[ReportId];SELECT * FROM [#ExtendedEventsBlockedProcesses_BlockingProcesses] ORDER BY [ReportTimeUtc] DESC,[ReportId];SELECT * FROM [#ExtendedEventsBlockedProcesses_SourceStatus] ORDER BY [SourceType];END ELSE BEGIN SELECT N'Blocked Process Report' [Ergebnis],[x].* FROM [#ExtendedEventsBlockedProcesses_ReportSummary] [x] ORDER BY [ReportTimeUtc] DESC,[ReportId];SELECT N'Blockierter Prozess' [Ergebnis],[ReportId] [Report],[SessionId] [Session],[WaitTimeMs] [Wait ms],[WaitResource] [Wait-Ressource],[DatabaseName] [Datenbank],[LoginName] [Login],[HostName] [Host],[SessionId] [Session SQL],[InputBuffer] [SQL] FROM [#ExtendedEventsBlockedProcesses_BlockedProcesses] ORDER BY [ReportTimeUtc] DESC,[ReportId];SELECT N'Blockierender Prozess' [Ergebnis],[ReportId] [Report],[SessionId] [Session],[DatabaseName] [Datenbank],[LoginName] [Login],[HostName] [Host],[SessionId] [Session SQL],[InputBuffer] [SQL] FROM [#ExtendedEventsBlockedProcesses_BlockingProcesses] ORDER BY [ReportTimeUtc] DESC,[ReportId];SELECT N'Extended-Events Quelle' [Ergebnis],[x].* FROM [#ExtendedEventsBlockedProcesses_SourceStatus] [x] ORDER BY [SourceType];END;END;
    IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'ExtendedEventsBlockedProcesses' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@RowCount [returnedRows],@ResolvedSessionName [sessionName],@ResolvedSource [source],@BlockedProcessThresholdSeconds [blockedProcessThresholdSeconds],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@R nvarchar(max)=(SELECT [ReportId],[SourceType],[ReportTimeUtc],[FileName],[FileOffset],[MonitorLoop],[BlockedSessionId],[BlockingSessionId],[WaitTimeMs],[DatabaseId],[DatabaseName],[WaitResource],[RequestedLockMode],CONVERT(nvarchar(max),[ReportXml]) [ReportXml] FROM [#ExtendedEventsBlockedProcesses_ReportSummary] ORDER BY [ReportTimeUtc] DESC,[ReportId] FOR JSON PATH,INCLUDE_NULL_VALUES),@B nvarchar(max)=(SELECT [ReportId],[ReportTimeUtc],[SessionId],[ExecutionContextId],[ProcessStatus],[WaitResource],[WaitTimeMs],[LockMode],[DatabaseId],[DatabaseName],[ClientApplication],[HostName],[LoginName],[InputBuffer],CONVERT(nvarchar(max),[ProcessXml]) [ProcessXml] FROM [#ExtendedEventsBlockedProcesses_BlockedProcesses] ORDER BY [ReportTimeUtc] DESC,[ReportId] FOR JSON PATH,INCLUDE_NULL_VALUES),@G nvarchar(max)=(SELECT [ReportId],[ReportTimeUtc],[SessionId],[ExecutionContextId],[ProcessStatus],[WaitResource],[WaitTimeMs],[LockMode],[DatabaseId],[DatabaseName],[ClientApplication],[HostName],[LoginName],[InputBuffer],CONVERT(nvarchar(max),[ProcessXml]) [ProcessXml] FROM [#ExtendedEventsBlockedProcesses_BlockingProcesses] ORDER BY [ReportTimeUtc] DESC,[ReportId] FOR JSON PATH,INCLUDE_NULL_VALUES),@S nvarchar(max)=(SELECT * FROM [#ExtendedEventsBlockedProcesses_SourceStatus] ORDER BY [SourceType] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"reports":',COALESCE(@R,N'[]'),N',"blockedProcesses":',COALESCE(@B,N'[]'),N',"blockingProcesses":',COALESCE(@G,N'[]'),N',"sources":',COALESCE(@S,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ExtendedEventsBlockedProcesses_ReportSummary'
            , @ResultLabel=N'ExtendedEventsBlockedProcesses'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ExtendedEventsBlockedProcesses_ReportSummary'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
