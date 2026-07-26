USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 169_P0_Runtime_Contract.sql
Zweck        : Prüft reproduzierbare P0-Positiv-, Leer- und Grenzfälle gegen
               die ausschließlich synthetische Actions-Datenbank.
Datenschutz  : Persistiert keine Laufzeitausgabe. Namen, Ereignisse und
               Konfigurationswerte sind generische Testwerte; produktive
               Resultsets und OUTPUT-Parameter bleiben unverändert.
Nebenwirkung : DBCC, Dateioptionen, msdb-Testmetadaten und eine XE-Session
               betreffen nur das disposable Actions-Ziel und werden
               soweit möglich im selben Lauf zurückgesetzt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DatabaseNames nvarchar(max)=QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()));
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@ErrorNumber int,@ErrorMessage nvarchar(2048);
DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);

/* INT-CHECKDB: blockierungsfrei nicht verfügbare CHECKDB-Zeit bleibt eine Evidenzgrenze. */
EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
     @DatabaseNames=@DatabaseNames,@MitPageDetails=0,@MaxZeilen=20,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT,
     @HighImpactConfirmed=1;

IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.integrity')
    WITH ([FindingCode] varchar(80) N'$.FindingCode')
    WHERE [FindingCode]='CHECKDB_EVIDENCE_UNAVAILABLE'
)
    THROW 54140,N'P0-Vertrag INT-CHECKDB fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('INT-CHECKDB');

/* INT-EMPTY: auch ein realer CHECKDB-Lauf wird nicht über blockierende Metadatenfunktionen zurückgelesen. */
DBCC CHECKDB WITH NO_INFOMSGS;

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL; SET @ErrorNumber=NULL; SET @ErrorMessage=NULL;
EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
     @DatabaseNames=@DatabaseNames,@MitPageDetails=0,@MaxZeilen=20,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT,
     @HighImpactConfirmed=1;

IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.integrity')
    WITH ([FindingCode] varchar(80) N'$.FindingCode',[EvidenceLimit] nvarchar(1000) N'$.EvidenceLimit')
    WHERE [FindingCode]='CHECKDB_EVIDENCE_UNAVAILABLE'
      AND [EvidenceLimit] LIKE N'%beweist%weder%Integrität%'
)
    THROW 54141,N'P0-Vertrag INT-EMPTY fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('INT-EMPTY');

/* INT-SUSPECT: synthetische suspect_pages-Zeile bleibt transaktional und die Detailausgabe ist begrenzt. */
BEGIN TRANSACTION;
INSERT [msdb].[dbo].[suspect_pages]
       ([database_id],[file_id],[page_id],[event_type],[error_count],[last_update_date])
VALUES (DB_ID(),1,1,1,1,GETDATE());

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL; SET @ErrorNumber=NULL; SET @ErrorMessage=NULL;
EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
     @DatabaseNames=@DatabaseNames,@MitPageDetails=1,@MaxZeilen=1,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT,@ErrorMessageOut=@ErrorMessage OUTPUT,
     @HighImpactConfirmed=1;

IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@Json,N'$.integrity')
    WITH ([FindingCode] varchar(80) N'$.FindingCode',[SuspectPageCount] bigint N'$.SuspectPageCount')
    WHERE [FindingCode]='SUSPECT_PAGES_PRESENT' AND [SuspectPageCount]>=1
)
OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.pageDetails'))>1
BEGIN
    ROLLBACK TRANSACTION;
    THROW 54142,N'P0-Vertrag INT-SUSPECT fehlgeschlagen.',1;
END;
ROLLBACK TRANSACTION;
INSERT @ExecutedCases VALUES('INT-SUSPECT');

/* Kapazitätsfälle verändern nur die Optionen der synthetischen primären Datendatei und stellen sie wieder her. */
DECLARE @LogicalFileName sysname,@OriginalGrowth int,@OriginalPercent bit,@OriginalMaxSize int,@CurrentSizePages int;
DECLARE @Sql nvarchar(max),@RestoreSql nvarchar(max),@CurrentSizeMb bigint;
SELECT TOP(1)
       @LogicalFileName=[name],@OriginalGrowth=[growth],@OriginalPercent=[is_percent_growth],
       @OriginalMaxSize=[max_size],@CurrentSizePages=[size]
FROM [sys].[database_files] WITH (NOLOCK)
WHERE [type]=0
ORDER BY [file_id];

SET @CurrentSizeMb=CEILING(@CurrentSizePages*8.0/1024.0);
SET @RestoreSql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' MODIFY FILE (NAME=N'''
    +REPLACE(@LogicalFileName,N'''',N'''''')+N''', FILEGROWTH='
    +CASE WHEN @OriginalPercent=1 THEN CONVERT(nvarchar(20),@OriginalGrowth)+N'%'
          ELSE CONVERT(nvarchar(30),CONVERT(bigint,@OriginalGrowth)*8)+N'KB' END
    +N', MAXSIZE='+CASE WHEN @OriginalMaxSize=-1 THEN N'UNLIMITED'
                        ELSE CONVERT(nvarchar(30),CEILING(@OriginalMaxSize*8.0/1024.0))+N'MB' END+N');';

/* CAP-PERCENT */
SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' MODIFY FILE (NAME=N'''
    +REPLACE(@LogicalFileName,N'''',N'''''')+N''', FILEGROWTH=10%, MAXSIZE=UNLIMITED);';
EXEC [sys].[sp_executesql] @Sql;
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_DatabaseCapacityAnalysis]
     @DatabaseNames=@DatabaseNames,@MinVolumeFreePercent=0,@MaxZeilen=20,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.capacity')
    WITH ([FindingCode] varchar(80) N'$.FindingCode') WHERE [FindingCode]='PERCENT_GROWTH_REVIEW'
)
    THROW 54144,N'P0-Vertrag CAP-PERCENT fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('CAP-PERCENT');

/* CAP-MAX */
SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' MODIFY FILE (NAME=N'''
    +REPLACE(@LogicalFileName,N'''',N'''''')+N''', FILEGROWTH=1MB, MAXSIZE='
    +CONVERT(nvarchar(30),@CurrentSizeMb)+N'MB);';
EXEC [sys].[sp_executesql] @Sql;
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_DatabaseCapacityAnalysis]
     @DatabaseNames=@DatabaseNames,@MinVolumeFreePercent=0,@MaxZeilen=20,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.capacity')
    WITH ([FindingCode] varchar(80) N'$.FindingCode') WHERE [FindingCode]='FILE_MAX_SIZE_REACHED'
)
    THROW 54145,N'P0-Vertrag CAP-MAX fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('CAP-MAX');

/* CAP-GROWTH */
SET @Sql=N'ALTER DATABASE '+QUOTENAME((SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()))+N' MODIFY FILE (NAME=N'''
    +REPLACE(@LogicalFileName,N'''',N'''''')+N''', FILEGROWTH=1048576MB, MAXSIZE=UNLIMITED);';
EXEC [sys].[sp_executesql] @Sql;
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_DatabaseCapacityAnalysis]
     @DatabaseNames=@DatabaseNames,@MinVolumeFreePercent=0,@MaxZeilen=20,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.capacity')
    WITH ([FindingCode] varchar(80) N'$.FindingCode') WHERE [FindingCode]='NEXT_GROWTH_EXCEEDS_VOLUME_FREE'
)
    THROW 54146,N'P0-Vertrag CAP-GROWTH fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('CAP-GROWTH');

EXEC [sys].[sp_executesql] @RestoreSql;

/* PC-SNAPSHOT: Delta-Counter erhalten ohne Sample niemals eine erfundene Rate. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL; SET @ErrorNumber=NULL;
EXEC [monitor].[USP_PerformanceCounters]
     @SampleSeconds=0,@MaxZeilen=10000,@ResultSetArt='NONE',@JsonErzeugen=1,
     @Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT;
DECLARE @PerformanceCounterRows bigint=(SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.counters'));
IF ISJSON(@Json)<>1
    THROW 54148,N'P0-Vertrag PC-SNAPSHOT lieferte kein gültiges JSON.',1;
IF @PerformanceCounterRows=0 AND @Status='ERROR_HANDLED'
BEGIN
    RAISERROR(N'P0 PC-SNAPSHOT technischer Fehlercode=%d; Meldungsinhalt wird nicht ausgegeben.',10,1,@ErrorNumber) WITH NOWAIT;
    THROW 54160,N'P0-Vertrag PC-SNAPSHOT endete intern behandelt statt mit einem expliziten Verfügbarkeitsstatus.',1;
END;
IF @PerformanceCounterRows=0 AND (@Status<>'UNAVAILABLE_OBJECT' OR COALESCE(@Partial,0)<>1)
    THROW 54157,N'P0-Vertrag PC-SNAPSHOT kennzeichnete ein leeres Ergebnis nicht als nicht verfügbar.',1;
IF @PerformanceCounterRows>0 AND EXISTS
   (SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH ([Interpretation] varchar(40) N'$.Interpretation',[MetricValue] decimal(38,6) N'$.MetricValue')
    WHERE [Interpretation] IN ('RATE_PER_SECOND','FRACTION_DELTA_PERCENT','AVERAGE_DELTA_RATIO')
      AND [MetricValue] IS NOT NULL)
    THROW 54158,N'P0-Vertrag PC-SNAPSHOT erfand ohne Sample einen Delta-Messwert.',1;
IF @PerformanceCounterRows>0 AND EXISTS
   (SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH ([Interpretation] varchar(40) N'$.Interpretation',[FindingCode] varchar(80) N'$.FindingCode')
    WHERE [Interpretation] IN ('RATE_PER_SECOND','FRACTION_DELTA_PERCENT','AVERAGE_DELTA_RATIO')
      AND [FindingCode]<>'SAMPLE_REQUIRED_FOR_DELTA_METRIC')
    THROW 54159,N'P0-Vertrag PC-SNAPSHOT kennzeichnete einen Delta-Counter ohne Sample nicht eindeutig.',1;
INSERT @ExecutedCases VALUES('PC-SNAPSHOT');

/* PC-RATE, PC-FRACTION und PC-AVERAGE: echte DMV-Samples, explizite Basen und Formelkontrolle. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL; SET @ErrorNumber=NULL;
EXEC [monitor].[USP_PerformanceCounters]
     @SampleSeconds=1,@MaxZeilen=10000,@ResultSetArt='NONE',@JsonErzeugen=1,
     @Json=@Json OUTPUT,@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@ErrorNumber OUTPUT;
SET @PerformanceCounterRows=(SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.counters'));
IF ISJSON(@Json)<>1
 OR (@PerformanceCounterRows=0 AND (@Status<>'UNAVAILABLE_OBJECT' OR COALESCE(@Partial,0)<>1))
 OR (@PerformanceCounterRows>0 AND NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH ([Interpretation] varchar(40) N'$.Interpretation',[SampleSeconds] decimal(19,6) N'$.SampleSeconds')
    WHERE [Interpretation]='RATE_PER_SECOND' AND [SampleSeconds]>=1
))
OR (@PerformanceCounterRows>0 AND EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH
    (
        [Interpretation] varchar(40) N'$.Interpretation',[MetricValue] decimal(38,6) N'$.MetricValue',
        [DeltaValue] bigint N'$.DeltaValue',[SampleSeconds] decimal(19,6) N'$.SampleSeconds'
    )
    WHERE [Interpretation]='RATE_PER_SECOND' AND [MetricValue] IS NOT NULL
      AND ABS([MetricValue]-CONVERT(decimal(38,6),[DeltaValue]/NULLIF([SampleSeconds],0)))>0.000001
))
    THROW 54149,N'P0-Vertrag PC-RATE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('PC-RATE');

IF @PerformanceCounterRows>0 AND NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH
    (
        [Interpretation] varchar(40) N'$.Interpretation',[BaseBeforeValue] bigint N'$.BaseBeforeValue',
        [BaseAfterValue] bigint N'$.BaseAfterValue'
    )
    WHERE [Interpretation]='FRACTION_DELTA_PERCENT'
      AND [BaseBeforeValue] IS NOT NULL AND [BaseAfterValue] IS NOT NULL
)
OR (@PerformanceCounterRows>0 AND EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH
    (
        [Interpretation] varchar(40) N'$.Interpretation',[MetricValue] decimal(38,6) N'$.MetricValue',
        [DeltaValue] bigint N'$.DeltaValue',[BaseDeltaValue] bigint N'$.BaseDeltaValue'
    )
    WHERE [Interpretation]='FRACTION_DELTA_PERCENT' AND [MetricValue] IS NOT NULL
      AND ABS([MetricValue]-CONVERT(decimal(38,6),100.0*[DeltaValue]/NULLIF([BaseDeltaValue],0)))>0.000001
))
    THROW 54150,N'P0-Vertrag PC-FRACTION fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('PC-FRACTION');

IF @PerformanceCounterRows>0 AND NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH
    (
        [Interpretation] varchar(40) N'$.Interpretation',[BaseBeforeValue] bigint N'$.BaseBeforeValue',
        [BaseAfterValue] bigint N'$.BaseAfterValue'
    )
    WHERE [Interpretation]='AVERAGE_DELTA_RATIO'
      AND [BaseBeforeValue] IS NOT NULL AND [BaseAfterValue] IS NOT NULL
)
OR (@PerformanceCounterRows>0 AND EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.counters')
    WITH
    (
        [Interpretation] varchar(40) N'$.Interpretation',[MetricValue] decimal(38,6) N'$.MetricValue',
        [DeltaValue] bigint N'$.DeltaValue',[BaseDeltaValue] bigint N'$.BaseDeltaValue'
    )
    WHERE [Interpretation]='AVERAGE_DELTA_RATIO' AND [MetricValue] IS NOT NULL
      AND ABS([MetricValue]-CONVERT(decimal(38,6),1.0*[DeltaValue]/NULLIF([BaseDeltaValue],0)))>0.000001
))
    THROW 54151,N'P0-Vertrag PC-AVERAGE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('PC-AVERAGE');

/* EV-NOTARGET */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_CriticalEngineEvents]
     @SourceExtendedEventSessionName=N'ExampleP0MissingEventSession',@MitSystemHealth=1,
     @MitServerDiagnostics=0,@MitEventXml=0,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.sources')
    WITH ([StatusCode] varchar(40) N'$.StatusCode') WHERE [StatusCode]='UNAVAILABLE_OBJECT'
)
    THROW 54152,N'P0-Vertrag EV-NOTARGET fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('EV-NOTARGET');

/* EV-SEVERE: kontrolliertes generisches Event in einer kurzlebigen XE-Datei. */
IF EXISTS(SELECT 1 FROM [sys].[server_event_sessions] WITH (NOLOCK) WHERE [name]=N'ExampleP0CriticalEvents')
    DROP EVENT SESSION [ExampleP0CriticalEvents] ON SERVER;
CREATE EVENT SESSION [ExampleP0CriticalEvents] ON SERVER
ADD EVENT [sqlserver].[error_reported]
ADD TARGET [package0].[event_file]
(
    SET filename=N'/tmp/example_p0_critical_events.xel',max_file_size=(5),max_rollover_files=(1)
)
WITH
(
    EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY=1 SECONDS,
    STARTUP_STATE=OFF
);
ALTER EVENT SESSION [ExampleP0CriticalEvents] ON SERVER STATE=START;
DECLARE @EventStartUtc datetime2(7)=SYSUTCDATETIME();
DECLARE @EventEndUtc datetime2(7)=DATEADD(MINUTE,5,@EventStartUtc);
DECLARE @SyntheticEventOrdinal tinyint=0;
WHILE @SyntheticEventOrdinal<20
BEGIN
    BEGIN TRY
        RAISERROR(N'Example synthetic critical event.',16,1);
    END TRY
    BEGIN CATCH
    END CATCH;
    SET @SyntheticEventOrdinal+=1;
    WAITFOR DELAY '00:00:00.250';
END;
WAITFOR DELAY '00:00:05';
ALTER EVENT SESSION [ExampleP0CriticalEvents] ON SERVER STATE=STOP;
WAITFOR DELAY '00:00:03';

SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_CriticalEngineEvents]
     @SourceExtendedEventSessionName=N'ExampleP0CriticalEvents',@VonUtc=@EventStartUtc,
     @BisUtc=@EventEndUtc,@MinErrorSeverity=16,@MitSystemHealth=1,
     @MitServerDiagnostics=0,@MitEventXml=0,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
DROP EVENT SESSION [ExampleP0CriticalEvents] ON SERVER;
IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.events')
    WITH
    (
        [TimestampUtc] datetime2(7) N'$.TimestampUtc',[ErrorNumber] int N'$.ErrorNumber',
        [Severity] int N'$.Severity',[FindingCode] varchar(100) N'$.FindingCode'
    )
    WHERE [ErrorNumber]=50000 AND [Severity]=16 AND [FindingCode]='SEVERE_ERROR_REPORTED'
      AND [TimestampUtc]>=@EventStartUtc AND [TimestampUtc]<@EventEndUtc
)
    THROW 54153,N'P0-Vertrag EV-SEVERE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('EV-SEVERE');

/* EV-DIAG und EV-XML: One-Shot ohne Repeat, keine XML-Nutzlast im Ergebnis. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_CriticalEngineEvents]
     @SourceExtendedEventSessionName=N'system_health',@MitSystemHealth=0,
     @MitServerDiagnostics=1,@MitEventXml=0,@MaxZeilen=20,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
IF ISJSON(@Json)<>1 OR NOT EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.sources')
    WITH ([SourceName] nvarchar(128) N'$.SourceName',[StatusCode] varchar(40) N'$.StatusCode',[Detail] nvarchar(1000) N'$.Detail')
    WHERE [SourceName]=N'sp_server_diagnostics' AND [StatusCode]='AVAILABLE' AND [Detail] LIKE N'%One-Shot%'
)
OR NOT EXISTS(SELECT 1 FROM OPENJSON(@Json,N'$.serverDiagnostics'))
    THROW 54154,N'P0-Vertrag EV-DIAG fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('EV-DIAG');

IF EXISTS
(
    SELECT 1 FROM OPENJSON(@Json,N'$.serverDiagnostics')
    WITH ([Data] nvarchar(max) N'$.Data') WHERE [Data] IS NOT NULL
)
    THROW 54155,N'P0-Vertrag EV-XML fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('EV-XML');

/* PC-RESET: deterministische Resetwerte durchlaufen dieselbe reine Funktion wie die DMV-Auswertung. */
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_InterpretPerformanceCounter]
         (272696320,100,50,NULL,NULL,CONVERT(decimal(19,6),1.0))
    WHERE [Interpretation]='RATE_PER_SECOND'
      AND [MetricValue] IS NULL
      AND [FindingCode]='COUNTER_RESET_DURING_SAMPLE'
)
    THROW 54161,N'P0-Vertrag PC-RESET unterdrückte eine negative Rate nicht eindeutig.',1;
INSERT @ExecutedCases VALUES('PC-RESET');

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>15
    THROW 54156,N'Der P0-Laufzeitvertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'15 synthetische P0-Laufzeitfälle wurden ausgeführt; zwei Berechtigungsfälle laufen in der versionsspezifischen Berechtigungsmatrix.' AS [Detail]
FROM @ExecutedCases;
GO
