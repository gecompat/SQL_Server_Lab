USE [DeineDatenbank];
GO

SET QUOTED_IDENTIFIER ON;
GO

/*
===============================================================================
Objekt       : monitor.USP_ExtendedEventsReadEvents
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Liest Ereignisse aus einem bereits vorhandenen event_file- oder
               ring_buffer-Target. Die Procedure ist eine optionale Forensik-
               quelle und wird von keinem Standard-Current-State-Modul benötigt.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.server_event_sessions/-targets/-fields,
               sys.fn_xe_file_target_read_file, optional sys.dm_xe_session_targets.
Parameter    : @ResolvedSourceExtendedEventSessionName, @Quelle, @FilePath, @EventNamePattern, @VonUtc,
               @BisUtc, @MaxZeilen, @MitEventXml, @BestaetigeTargetFlush,
               @PrintMeldungen, @Hilfe.
Resultsets   : 1. Modulstatus. 2. normalisierte Events. 3. Quell-/Fehlerstatus.
Berechtigung : SQL 2019 VIEW SERVER STATE; SQL 2022+ VIEW SERVER PERFORMANCE
               STATE beziehungsweise für Filezugriff ggf. VIEW DATABASE
               PERFORMANCE STATE. Zusätzlich muss SQL Server die Datei lesen können.
Eigenlast    : Abhängig von Anzahl und Größe der XEL-Dateien bzw. Ringbufferdaten.
               File-Lesen und XML-Konvertierung sind explizit Deep/opt-in.
Locking      : LOCK_TIMEOUT 0; keine Benutzerobjekte und keine Änderungen.
Nebenwirkung : Das Lesen von sys.dm_xe_session_targets kann einen Target-Flush
               auslösen und erfordert daher @BestaetigeTargetFlush=1.
Partial      : Fehlende Sessions, Targets, Dateien oder Rechte werden strukturiert
               gemeldet; andere Framework-Module bleiben funktionsfähig.
Beispiele    : EXEC monitor.USP_ExtendedEventsReadEvents
                   @ResolvedSourceExtendedEventSessionName=N'system_health', @Quelle='EVENT_FILE',
                   @EventNamePattern=N'xml_deadlock_report', @MaxZeilen=100;
               EXEC monitor.USP_ExtendedEventsReadEvents
                   @ResolvedSourceExtendedEventSessionName=N'system_health', @Quelle='RING_BUFFER',
                   @BestaetigeTargetFlush=1;
               EXEC monitor.USP_ExtendedEventsReadEvents @Hilfe=1;
Änderungen   : 1.0.0 - Erstfassung Phase 5.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ExtendedEventsReadEvents]
      @SourceExtendedEventSessionName nvarchar(258)         = N'system_health'
    , @Quelle                  varchar(20)     = 'EVENT_FILE'
    , @FilePath                nvarchar(4000)  = NULL
    , @EventNames              nvarchar(max)   = NULL
    , @EventNamePattern        nvarchar(4000)  = NULL
    , @VonUtc                  datetime2(7)    = NULL
    , @BisUtc                  datetime2(7)    = NULL
    , @MaxZeilen               int             = 1000
    , @MitEventXml             bit             = 1
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'events',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @ResolvedSourceExtendedEventSessionName sysname=NULL;
    DECLARE @EventPatternMode varchar(8),@EventPatternValue nvarchar(4000),@EventPatternFlags varchar(8),@EventPatternValid bit;
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_ExtendedEventsReadEvents';
        PRINT N'@ResolvedSourceExtendedEventSessionName sysname=N''system_health'': vorhandene serverweite Extended-Events-Session.';
        PRINT N'@Quelle varchar(20)=''EVENT_FILE'': EVENT_FILE, RING_BUFFER oder AUTO. AUTO bevorzugt EVENT_FILE.';
        PRINT N'@FilePath nvarchar(4000)=NULL: optionaler XEL-Pfad oder URL; NULL leitet den event_file-Pfad aus der Sessiondefinition ab.';
        PRINT N'@EventNamePattern nvarchar(256)=NULL: LIKE-Filter auf den Eventnamen.';
        PRINT N'@VonUtc datetime2(7)=NULL; @BisUtc datetime2(7)=NULL: UTC-Zeitfenster.';
        PRINT N'@MaxZeilen int=1000: positive Werte begrenzen; NULL/0 = unbegrenzt.';
        PRINT N'@MitEventXml bit=1: 1 gibt das vollständige Event-XML aus; 0 reduziert Ergebnistransfer.';
        PRINT N'@BestaetigeTargetFlush bit=0: muss für RING_BUFFER 1 sein, da sys.dm_xe_session_targets einen Flush auslösen kann.';
        PRINT N'@PrintMeldungen bit=1: Warnungen via RAISERROR Severity 10; @Hilfe bit=0: 1 zeigt diese Hilfe.';
        PRINT N'Die Procedure verändert keine Extended-Events-Session und ist kein Bestandteil des Standardlaufs.';
        RETURN;
    END;

    IF @SourceExtendedEventSessionName IS NULL OR (SELECT COUNT_BIG(*) FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName) WHERE [IsValid]=1)<>1 OR EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName) WHERE [IsValid]=0)
    BEGIN SET @ResolvedSourceExtendedEventSessionName=NULL;END
    ELSE SELECT @ResolvedSourceExtendedEventSessionName=MIN([NameValue]) FROM [monitor].[TVF_ParseSqlNameList](@SourceExtendedEventSessionName) WHERE [IsValid]=1;

    SELECT @EventPatternMode=[PatternMode],@EventPatternValue=[PatternValue],@EventPatternFlags=[RegexFlags],@EventPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@EventNamePattern);
    IF @EventNames IS NOT NULL AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@EventNames) WHERE [IsValid]=0) SET @EventPatternValid=0;

    DECLARE
        @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME(),
        @StatusCode varchar(40) = 'AVAILABLE',
        @IsPartial bit = 0,
        @ErrorNumber int = NULL,
        @ErrorMessage nvarchar(2048) = NULL,
        @RowCount bigint = 0,
        @Allowed bit = 1,
        @ResolvedSource varchar(20) = UPPER(LTRIM(RTRIM(COALESCE(@Quelle, '')))),
        @ResolvedFilePath nvarchar(4000) = NULL,
        @ConfiguredFilePath nvarchar(4000) = NULL,
        @TargetData xml = NULL;

    CREATE TABLE [#ExtendedEventsReadEvents_Raw]
    (
        [SourceType] varchar(20) NOT NULL,
        [EventName] sysname NULL,
        [TimestampUtc] datetime2(7) NULL,
        [FileName] nvarchar(260) NULL,
        [FileOffset] bigint NULL,
        [EventXml] xml NULL
    );

    CREATE TABLE [#ExtendedEventsReadEvents_SourceStatus]
    (
        [SourceType] varchar(20) NULL,
        [SessionName] sysname NULL,
        [TargetName] sysname NULL,
        [ResolvedPath] nvarchar(4000) NULL,
        [StatusCode] varchar(40) NOT NULL,
        [ErrorNumber] int NULL,
        [ErrorMessage] nvarchar(2048) NULL,
        [Detail] nvarchar(1000) NULL
    );

    IF @ResolvedSourceExtendedEventSessionName IS NULL BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'@SourceExtendedEventSessionName muss genau einen gültigen, optional geklammerten sysname enthalten.';END;

    IF @ResolvedSource NOT IN ('EVENT_FILE', 'RING_BUFFER', 'AUTO')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@Quelle muss EVENT_FILE, RING_BUFFER oder AUTO sein.';
    END;

    IF @MaxZeilen<0 OR @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@MaxZeilen darf nicht negativ sein; NULL/0 bedeutet unbegrenzt.';
    END;

    IF @VonUtc IS NOT NULL AND @BisUtc IS NOT NULL AND @VonUtc >= @BisUtc
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@VonUtc muss kleiner als @BisUtc sein.';
    END;

    IF @StatusCode = 'AVAILABLE'
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='EXTENDED_EVENTS_FORENSICS_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@StatusCode OUTPUT,@ErrorMessage=@ErrorMessage OUTPUT;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            SELECT @ConfiguredFilePath = MAX(CONVERT(nvarchar(4000), [f].[value]))
            FROM [sys].[server_event_sessions] AS s WITH (NOLOCK)
            JOIN [sys].[server_event_session_targets] AS t WITH (NOLOCK)
              ON [t].[event_session_id] = [s].[event_session_id]
             AND [t].[name] = N'event_file'
            LEFT JOIN [sys].[server_event_session_fields] AS f WITH (NOLOCK)
              ON [f].[event_session_id] = [t].[event_session_id]
             AND [f].[object_id] = [t].[target_id]
             AND [f].[name] = N'filename'
            WHERE [s].[name] = @ResolvedSourceExtendedEventSessionName;
        END TRY
        BEGIN CATCH
            SET @IsPartial = 1;
            INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES
            ('CATALOG', @ResolvedSourceExtendedEventSessionName, 'event_file', NULL,
             CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
             ERROR_NUMBER(), ERROR_MESSAGE(), N'Der konfigurierte event_file-Pfad konnte nicht gelesen werden. Ein expliziter @FilePath kann weiterhin funktionieren.');
        END CATCH;

        IF @ResolvedSource = 'AUTO'
        BEGIN
            IF @FilePath IS NOT NULL OR @ConfiguredFilePath IS NOT NULL
                SET @ResolvedSource = 'EVENT_FILE';
            ELSE IF @BestaetigeTargetFlush = 1
                SET @ResolvedSource = 'RING_BUFFER';
            ELSE
            BEGIN
                SET @StatusCode = 'AVAILABLE_DISABLED';
                SET @ErrorMessage = N'AUTO fand keinen lesbaren event_file-Pfad; Ringbuffer wurde ohne @BestaetigeTargetFlush=1 nicht gelesen.';
            END;
        END;
    END;

    IF @StatusCode = 'AVAILABLE' AND @ResolvedSource = 'EVENT_FILE'
    BEGIN
        SET @ResolvedFilePath = COALESCE(NULLIF(@FilePath, N''), NULLIF(@ConfiguredFilePath, N''));

        IF @ResolvedFilePath IS NULL
        BEGIN
            SET @StatusCode = 'UNAVAILABLE_OBJECT';
            SET @ErrorMessage = N'Kein event_file-Pfad vorhanden. @FilePath angeben oder eine Session mit event_file-Target verwenden.';
            INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES('EVENT_FILE', @ResolvedSourceExtendedEventSessionName, 'event_file', NULL, @StatusCode, NULL, @ErrorMessage, N'Keine Datei gelesen.');
        END
        ELSE
        BEGIN
            IF (RIGHT(LOWER(@ResolvedFilePath), 4) = N'.xel')
                SET @ResolvedFilePath = LEFT(@ResolvedFilePath, LEN(@ResolvedFilePath) - 4) + N'*.xel';
            ELSE IF CHARINDEX(N'*', @ResolvedFilePath) = 0
                SET @ResolvedFilePath = @ResolvedFilePath + N'*.xel';

            BEGIN TRY
                INSERT [#ExtendedEventsReadEvents_Raw]([SourceType], [EventName], [TimestampUtc], [FileName], [FileOffset], [EventXml])
                SELECT TOP (@EffectiveMaxZeilen)
                    'EVENT_FILE',
                    [r].[object_name],
                    [r].[timestamp_utc],
                    [r].[file_name],
                    [r].[file_offset],
                    CONVERT([xml], [r].[event_data])
                FROM sys.fn_xe_file_target_read_file(@ResolvedFilePath, NULL, NULL, NULL) AS r
                WHERE ((@EventNames IS NULL OR EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@EventNames) [ef] WHERE [ef].[IsValid]=1 AND [ef].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=[r].[object_name] COLLATE SQL_Latin1_General_CP1_CS_AS)) AND (@EventPatternMode IN('NONE','REGEX','REGEXI') OR [r].[object_name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @EventPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS))
                  AND (@VonUtc IS NULL OR [r].[timestamp_utc] >= @VonUtc)
                  AND (@BisUtc IS NULL OR [r].[timestamp_utc] < @BisUtc)
                ORDER BY [r].[timestamp_utc] DESC, [r].[file_name] DESC, [r].[file_offset] DESC;

                INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES
                ('EVENT_FILE', @ResolvedSourceExtendedEventSessionName, 'event_file', @ResolvedFilePath, 'AVAILABLE', NULL, NULL,
                 N'XEL-Dateien wurden gelesen. Große oder viele Rollover-Dateien können trotz Ergebnislimit vollständig gescannt werden.');
            END TRY
            BEGIN CATCH
                SET @StatusCode = CASE
                                    WHEN ERROR_NUMBER() IN (229,262,297,300,371) THEN 'DENIED_PERMISSION'
                                    WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                                    WHEN ERROR_NUMBER() IN(6335,6336,6337) THEN 'XML_UNAVAILABLE_LIMIT'
                                    WHEN ERROR_NUMBER() BETWEEN 9400 AND 9431 THEN 'XML_INVALID'
                                    ELSE 'ERROR_HANDLED'
                                  END;
                SET @ErrorNumber = ERROR_NUMBER();
                SET @ErrorMessage = ERROR_MESSAGE();
                INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES('EVENT_FILE', @ResolvedSourceExtendedEventSessionName, 'event_file', @ResolvedFilePath, @StatusCode, @ErrorNumber, @ErrorMessage, N'Event-Datei konnte nicht gelesen werden.');
            END CATCH;
        END;
    END;

    IF @StatusCode = 'AVAILABLE' AND @ResolvedSource = 'RING_BUFFER'
    BEGIN
        IF @BestaetigeTargetFlush = 0
        BEGIN
            SET @StatusCode = 'AVAILABLE_DISABLED';
            SET @ErrorMessage = N'RING_BUFFER erfordert @BestaetigeTargetFlush=1.';
            INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES('RING_BUFFER', @ResolvedSourceExtendedEventSessionName, 'ring_buffer', NULL, @StatusCode, NULL, @ErrorMessage, N'sys.dm_xe_session_targets wurde nicht gelesen.');
        END
        ELSE
        BEGIN
            BEGIN TRY
                SELECT @TargetData = CONVERT([xml], [t].[target_data])
                FROM [sys].[dm_xe_session_targets] AS t WITH (NOLOCK)
                JOIN [sys].[dm_xe_sessions] AS s WITH (NOLOCK)
                  ON [s].[address] = [t].[event_session_address]
                WHERE [s].[name] = @ResolvedSourceExtendedEventSessionName
                  AND [t].[target_name] = N'ring_buffer';

                IF @TargetData IS NULL
                BEGIN
                    SET @StatusCode = 'UNAVAILABLE_OBJECT';
                    SET @ErrorMessage = N'Kein laufendes ring_buffer-Target mit lesbaren Targetdaten gefunden.';
                    INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES('RING_BUFFER', @ResolvedSourceExtendedEventSessionName, 'ring_buffer', NULL, @StatusCode, NULL, @ErrorMessage, N'Die Session ist möglicherweise gestoppt oder besitzt kein Ringbuffer-Target.');
                END
                ELSE
                BEGIN
                    INSERT [#ExtendedEventsReadEvents_Raw]([SourceType], [EventName], [TimestampUtc], [FileName], [FileOffset], [EventXml])
                    SELECT TOP (@EffectiveMaxZeilen)
                        'RING_BUFFER',
                        x.e.value('(@name)[1]', 'sysname'),
                        x.e.value('(@timestamp)[1]', 'datetime2(7)'),
                        NULL,
                        NULL,
                        x.e.query('.')
                    FROM @TargetData.nodes('/RingBufferTarget/event') AS [x]([e])
                    WHERE ((@EventNames IS NULL OR EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@EventNames) [ef] WHERE [ef].[IsValid]=1 AND [ef].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=x.e.value('(@name)[1]', 'sysname') COLLATE SQL_Latin1_General_CP1_CS_AS)) AND (@EventPatternMode IN('NONE','REGEX','REGEXI') OR x.e.value('(@name)[1]', 'sysname') COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @EventPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS))
                      AND (@VonUtc IS NULL OR x.e.value('(@timestamp)[1]', 'datetime2(7)') >= @VonUtc)
                      AND (@BisUtc IS NULL OR x.e.value('(@timestamp)[1]', 'datetime2(7)') < @BisUtc)
                    ORDER BY x.e.value('(@timestamp)[1]', 'datetime2(7)') DESC;

                    INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES
                    ('RING_BUFFER', @ResolvedSourceExtendedEventSessionName, 'ring_buffer', NULL, 'AVAILABLE', NULL, NULL,
                     N'sys.dm_xe_session_targets wurde bewusst gelesen; dies kann einen Target-Flush auslösen.');
                END;
            END TRY
            BEGIN CATCH
                SET @StatusCode = CASE
                                    WHEN ERROR_NUMBER() IN (229,262,297,300,371) THEN 'DENIED_PERMISSION'
                                    WHEN ERROR_NUMBER() = 1222 THEN 'TIMEOUT'
                                    WHEN ERROR_NUMBER() IN(6335,6336,6337) THEN 'XML_UNAVAILABLE_LIMIT'
                                    WHEN ERROR_NUMBER() BETWEEN 9400 AND 9431 THEN 'XML_INVALID'
                                    ELSE 'ERROR_HANDLED'
                                  END;
                SET @ErrorNumber = ERROR_NUMBER();
                SET @ErrorMessage = ERROR_MESSAGE();
                INSERT [#ExtendedEventsReadEvents_SourceStatus] VALUES('RING_BUFFER', @ResolvedSourceExtendedEventSessionName, 'ring_buffer', NULL, @StatusCode, @ErrorNumber, @ErrorMessage, N'Ringbuffer konnte nicht gelesen werden.');
            END CATCH;
        END;
    END;

    IF @StatusCode='AVAILABLE' AND (@EventPatternValid=0 OR (@EventNames IS NOT NULL AND @EventNamePattern IS NOT NULL)) BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'@EventNames oder @EventNamePattern ist ungültig.';END;
    IF @StatusCode='AVAILABLE' AND @EventPatternMode IN('REGEX','REGEXI')
    BEGIN
        IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<17 OR NOT EXISTS(SELECT 1 FROM [master].[sys].[databases] [d] WITH(NOLOCK) WHERE [d].[database_id]=DB_ID() AND [d].[compatibility_level]>=170) BEGIN SET @StatusCode='UNAVAILABLE_FEATURE';SET @ErrorMessage=N'Regex benötigt SQL Server 2025 und Compatibility Level 170.';END
        ELSE EXEC [sys].[sp_executesql] N'DELETE FROM [#ExtendedEventsReadEvents_Raw] WHERE NOT REGEXP_LIKE([EventName],@P,@F);',N'@P nvarchar(4000),@F varchar(8)',@P=@EventPatternValue,@F=@EventPatternFlags;
    END;

    SELECT @RowCount = COUNT_BIG(*) FROM [#ExtendedEventsReadEvents_Raw];

    IF @StatusCode = 'AVAILABLE' AND @RowCount = 0
    BEGIN
        SET @StatusCode = 'AVAILABLE_LIMITED';
        SET @IsPartial = 1;
        SET @ErrorMessage = COALESCE(@ErrorMessage, N'Die Quelle war lesbar, enthielt aber keine passenden Events im Filterfenster.');
    END;

    IF @IsPartial = 1 AND @StatusCode = 'AVAILABLE'
        SET @StatusCode = 'AVAILABLE_LIMITED';



    IF @PrintMeldungen = 1 AND @StatusCode NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED')
        BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ExtendedEventsReadEvents: %s - %s', @StatusCode, COALESCE(@ErrorMessage, N'Keine Details.'));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;

    IF @ResultSetArtNormalisiert<>'NONE'
    BEGIN
        SELECT N'USP_ExtendedEventsReadEvents' [ModuleName],@CollectionTimeUtc [CollectionTimeUtc],@StatusCode [StatusCode],@IsPartial [IsPartial],@RowCount [RowCount],@ResolvedSource [ResolvedSource],@ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage];
        IF @ResultSetArtNormalisiert='RAW'
        BEGIN SELECT [r].[SourceType],[r].[EventName],[r].[TimestampUtc],TRY_CONVERT(int,COALESCE([r].[EventXml].value('(/event/action[@name="database_id"]/value/text())[1]','nvarchar(32)'),[r].[EventXml].value('(/event/data[@name="database_id"]/value/text())[1]','nvarchar(32)'))) AS [DatabaseId],COALESCE([r].[EventXml].value('(/event/action[@name="database_name"]/value/text())[1]','nvarchar(256)'),[r].[EventXml].value('(/event/data[@name="database_name"]/value/text())[1]','nvarchar(256)')) AS [DatabaseName],TRY_CONVERT(int,COALESCE([r].[EventXml].value('(/event/action[@name="session_id"]/value/text())[1]','nvarchar(32)'),[r].[EventXml].value('(/event/data[@name="session_id"]/value/text())[1]','nvarchar(32)'))) AS [SessionId],[r].[EventXml].value('(/event/action[@name="client_app_name"]/value/text())[1]','nvarchar(512)') AS [ClientApplication],[r].[EventXml].value('(/event/action[@name="client_hostname"]/value/text())[1]','nvarchar(512)') AS [ClientHostName],COALESCE([r].[EventXml].value('(/event/action[@name="username"]/value/text())[1]','nvarchar(512)'),[r].[EventXml].value('(/event/action[@name="server_principal_name"]/value/text())[1]','nvarchar(512)')) AS [LoginName],COALESCE([r].[EventXml].value('(/event/action[@name="sql_text"]/value/text())[1]','nvarchar(4000)'),[r].[EventXml].value('(/event/data[@name="statement"]/value/text())[1]','nvarchar(4000)'),[r].[EventXml].value('(/event/data[@name="batch_text"]/value/text())[1]','nvarchar(4000)')) AS [SqlText],TRY_CONVERT(bigint,[r].[EventXml].value('(/event/data[@name="duration"]/value/text())[1]','nvarchar(64)')) AS [DurationRaw],TRY_CONVERT(int,[r].[EventXml].value('(/event/data[@name="error_number"]/value/text())[1]','nvarchar(32)')) AS [ErrorNumber],TRY_CONVERT(int,[r].[EventXml].value('(/event/data[@name="severity"]/value/text())[1]','nvarchar(32)')) AS [Severity],COALESCE([r].[EventXml].value('(/event/data[@name="wait_type"]/text/text())[1]','nvarchar(256)'),[r].[EventXml].value('(/event/data[@name="wait_type"]/value/text())[1]','nvarchar(256)')) AS [WaitType],[r].[EventXml].value('(/event/data[@name="resource_description"]/value/text())[1]','nvarchar(4000)') AS [ResourceDescription],[r].[FileName],[r].[FileOffset],CASE WHEN @MitEventXml=1 THEN [r].[EventXml] END AS [EventXml] FROM [#ExtendedEventsReadEvents_Raw] [r] ORDER BY [r].[TimestampUtc] DESC,[r].[FileName] DESC,[r].[FileOffset] DESC;SELECT * FROM [#ExtendedEventsReadEvents_SourceStatus] ORDER BY [SourceType],[TargetName];END
        ELSE
        BEGIN SELECT N'Extended-Events Event' [Ergebnis],[x].* FROM (SELECT [r].[SourceType],[r].[EventName],[r].[TimestampUtc],TRY_CONVERT(int,COALESCE([r].[EventXml].value('(/event/action[@name="database_id"]/value/text())[1]','nvarchar(32)'),[r].[EventXml].value('(/event/data[@name="database_id"]/value/text())[1]','nvarchar(32)'))) AS [DatabaseId],COALESCE([r].[EventXml].value('(/event/action[@name="database_name"]/value/text())[1]','nvarchar(256)'),[r].[EventXml].value('(/event/data[@name="database_name"]/value/text())[1]','nvarchar(256)')) AS [DatabaseName],TRY_CONVERT(int,COALESCE([r].[EventXml].value('(/event/action[@name="session_id"]/value/text())[1]','nvarchar(32)'),[r].[EventXml].value('(/event/data[@name="session_id"]/value/text())[1]','nvarchar(32)'))) AS [SessionId],[r].[EventXml].value('(/event/action[@name="client_app_name"]/value/text())[1]','nvarchar(512)') AS [ClientApplication],[r].[EventXml].value('(/event/action[@name="client_hostname"]/value/text())[1]','nvarchar(512)') AS [ClientHostName],COALESCE([r].[EventXml].value('(/event/action[@name="username"]/value/text())[1]','nvarchar(512)'),[r].[EventXml].value('(/event/action[@name="server_principal_name"]/value/text())[1]','nvarchar(512)')) AS [LoginName],COALESCE([r].[EventXml].value('(/event/action[@name="sql_text"]/value/text())[1]','nvarchar(4000)'),[r].[EventXml].value('(/event/data[@name="statement"]/value/text())[1]','nvarchar(4000)'),[r].[EventXml].value('(/event/data[@name="batch_text"]/value/text())[1]','nvarchar(4000)')) AS [SqlText],TRY_CONVERT(bigint,[r].[EventXml].value('(/event/data[@name="duration"]/value/text())[1]','nvarchar(64)')) AS [DurationRaw],TRY_CONVERT(int,[r].[EventXml].value('(/event/data[@name="error_number"]/value/text())[1]','nvarchar(32)')) AS [ErrorNumber],TRY_CONVERT(int,[r].[EventXml].value('(/event/data[@name="severity"]/value/text())[1]','nvarchar(32)')) AS [Severity],COALESCE([r].[EventXml].value('(/event/data[@name="wait_type"]/text/text())[1]','nvarchar(256)'),[r].[EventXml].value('(/event/data[@name="wait_type"]/value/text())[1]','nvarchar(256)')) AS [WaitType],[r].[EventXml].value('(/event/data[@name="resource_description"]/value/text())[1]','nvarchar(4000)') AS [ResourceDescription],[r].[FileName],[r].[FileOffset],CASE WHEN @MitEventXml=1 THEN [r].[EventXml] END AS [EventXml] FROM [#ExtendedEventsReadEvents_Raw] [r]) [x] ORDER BY [TimestampUtc] DESC,[FileName] DESC,[FileOffset] DESC;SELECT N'Extended-Events Quelle' [Ergebnis],[x].* FROM [#ExtendedEventsReadEvents_SourceStatus] [x] ORDER BY [SourceType],[TargetName];END;
    END;
    IF @JsonErzeugen=1
    BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'ExtendedEventsReadEvents' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@RowCount [returnedRows],@ResolvedSource [source],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@EventsJson nvarchar(max)=(SELECT [r].[SourceType],[r].[EventName],[r].[TimestampUtc],TRY_CONVERT(int,COALESCE([r].[EventXml].value('(/event/action[@name="database_id"]/value/text())[1]','nvarchar(32)'),[r].[EventXml].value('(/event/data[@name="database_id"]/value/text())[1]','nvarchar(32)'))) AS [DatabaseId],COALESCE([r].[EventXml].value('(/event/action[@name="database_name"]/value/text())[1]','nvarchar(256)'),[r].[EventXml].value('(/event/data[@name="database_name"]/value/text())[1]','nvarchar(256)')) AS [DatabaseName],TRY_CONVERT(int,COALESCE([r].[EventXml].value('(/event/action[@name="session_id"]/value/text())[1]','nvarchar(32)'),[r].[EventXml].value('(/event/data[@name="session_id"]/value/text())[1]','nvarchar(32)'))) AS [SessionId],[r].[EventXml].value('(/event/action[@name="client_app_name"]/value/text())[1]','nvarchar(512)') AS [ClientApplication],[r].[EventXml].value('(/event/action[@name="client_hostname"]/value/text())[1]','nvarchar(512)') AS [ClientHostName],COALESCE([r].[EventXml].value('(/event/action[@name="username"]/value/text())[1]','nvarchar(512)'),[r].[EventXml].value('(/event/action[@name="server_principal_name"]/value/text())[1]','nvarchar(512)')) AS [LoginName],COALESCE([r].[EventXml].value('(/event/action[@name="sql_text"]/value/text())[1]','nvarchar(4000)'),[r].[EventXml].value('(/event/data[@name="statement"]/value/text())[1]','nvarchar(4000)'),[r].[EventXml].value('(/event/data[@name="batch_text"]/value/text())[1]','nvarchar(4000)')) AS [SqlText],TRY_CONVERT(bigint,[r].[EventXml].value('(/event/data[@name="duration"]/value/text())[1]','nvarchar(64)')) AS [DurationRaw],TRY_CONVERT(int,[r].[EventXml].value('(/event/data[@name="error_number"]/value/text())[1]','nvarchar(32)')) AS [ErrorNumber],TRY_CONVERT(int,[r].[EventXml].value('(/event/data[@name="severity"]/value/text())[1]','nvarchar(32)')) AS [Severity],COALESCE([r].[EventXml].value('(/event/data[@name="wait_type"]/text/text())[1]','nvarchar(256)'),[r].[EventXml].value('(/event/data[@name="wait_type"]/value/text())[1]','nvarchar(256)')) AS [WaitType],[r].[EventXml].value('(/event/data[@name="resource_description"]/value/text())[1]','nvarchar(4000)') AS [ResourceDescription],[r].[FileName],[r].[FileOffset],CASE WHEN @MitEventXml=1 THEN [r].[EventXml] END AS [EventXml] FROM [#ExtendedEventsReadEvents_Raw] [r] ORDER BY [r].[TimestampUtc] DESC,[r].[FileName] DESC,[r].[FileOffset] DESC FOR JSON PATH,INCLUDE_NULL_VALUES),@SourcesJson nvarchar(max)=(SELECT * FROM [#ExtendedEventsReadEvents_SourceStatus] ORDER BY [SourceType],[TargetName] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"events":',COALESCE(@EventsJson,N'[]'),N',"sources":',COALESCE(@SourcesJson,N'[]'),N',"warnings":[]}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ExtendedEventsReadEvents_Raw'
            , @ResultLabel=N'ExtendedEventsReadEvents'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ExtendedEventsReadEvents_Raw'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
