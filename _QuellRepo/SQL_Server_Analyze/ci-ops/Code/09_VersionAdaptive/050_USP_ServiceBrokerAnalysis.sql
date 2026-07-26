USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ServiceBrokerAnalysis
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Stored Procedure
Zweck        : Analysiert sichtbare Service-Broker-Konfiguration, Queue-
               Kapazität, interne Aktivierung, Transmission-Rückstand und
               aggregierte Conversation-Zustände.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.databases, sys.service_queues, sys.services,
               sys.dm_db_partition_stats, sys.dm_broker_queue_monitors,
               sys.dm_broker_activated_tasks, sys.transmission_queue und
               sys.conversation_endpoints.
Methodik     : Feature-Gate und jede abhängige Quelle werden datenbankweise
               best effort ausgewertet. Fehlende Rechte verwerfen andere
               zugängliche Evidenz nicht.
Grenzen      : Keine Queue-Nutzdaten, keine Nachrichtenkörper, kein RECEIVE,
               keine Queue-Änderung und kein END CONVERSATION. Deaktivierte
               Queues, alte Einträge und DMV-Zustände sind Prüfhinweise; sie
               beweisen weder eine Poison Message noch deren Ursache.
Kosten       : MEDIUM; Kataloge, aggregierte Broker-Laufzeitmetadaten und
               approximative Partitionsstatistik.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ServiceBrokerAnalysis]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)  = NULL
    , @SchemaNamePattern                nvarchar(4000) = NULL
    , @ObjectNames                      nvarchar(max)  = NULL
    , @ObjectNamePattern                nvarchar(4000) = NULL
    , @FullObjectNames                  nvarchar(max)  = NULL
    , @NurProblematisch                 bit            = 0
    , @TransmissionAgeWarnMinutes       bigint         = 60
    , @TransmissionRowsWarn             bigint         = 1000
    , @QueueRowsWarn                    bigint         = 10000
    , @ActivationSilenceWarnMinutes     bigint         = 60
    , @ConversationRowsWarn             bigint         = 100000
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit            = NULL OUTPUT
    , @ErrorNumberOut                   int            = NULL OUTPUT
    , @ErrorMessageOut                  nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json=NULL;

    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'findings',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @PrintMessage nvarchar(2048)=NULL;
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                               THEN CONVERT(bigint,9223372036854775807)
                               ELSE CONVERT(bigint,@MaxZeilen) END;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_ServiceBrokerAnalysis';
        PRINT N'Die Procedure führt eine rein lesende Tiefenanalyse sichtbarer Service-Broker-Konfiguration und aggregierter Laufzeitmetadaten durch.';
        PRINT N'Geprüft werden Queue-Schalter, approximative Queue-Zeilen, Aktivierungs-DMVs, Transmission-Alter und Conversation-Zustände.';
        PRINT N'Exakte Namenslisten und Pattern beziehen sich auf Queue-Schema und Queue-Name; Pattern: LIKE, regex: oder regexi:.';
        PRINT N'Grenzwerte erzeugen Prüfkontext und keine automatische Betriebs-, Routing- oder Bereinigungsentscheidung.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson; @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        PRINT N'Es werden keine Queue-Nutzdaten oder Nachrichtenkörper gelesen und keine Broker-Objekte verändert.';
        RETURN;
    END;

    IF @SystemdatenbankenEinbeziehen IS NULL OR @NurProblematisch IS NULL
       OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @TransmissionAgeWarnMinutes IS NULL OR @TransmissionAgeWarnMinutes<0
       OR @TransmissionRowsWarn IS NULL OR @TransmissionRowsWarn<0
       OR @QueueRowsWarn IS NULL OR @QueueRowsWarn<0
       OR @ActivationSilenceWarnMinutes IS NULL OR @ActivationSilenceWarnMinutes<0
       OR @ConversationRowsWarn IS NULL OR @ConversationRowsWarn<0

       OR @MaxZeilen IS NULL OR @MaxZeilen<0
       OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
       OR @OutputMode NOT IN('CONSOLE','RAW','NONE')
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungültiger Bit-, Grenzwert-, Mengen-, Lock-Timeout- oder Ausgabeparameter.';
    END;

    DECLARE @SchemaPatternMode varchar(8),@SchemaPatternValue nvarchar(4000),@SchemaRegexFlags varchar(8),@SchemaPatternValid bit;
    DECLARE @ObjectPatternMode varchar(8),@ObjectPatternValue nvarchar(4000),@ObjectRegexFlags varchar(8),@ObjectPatternValid bit;
    SELECT @SchemaPatternMode=[PatternMode],@SchemaPatternValue=[PatternValue],@SchemaRegexFlags=[RegexFlags],@SchemaPatternValid=[IsValid]
    FROM [monitor].[TVF_ParsePattern](@SchemaNamePattern);
    SELECT @ObjectPatternMode=[PatternMode],@ObjectPatternValue=[PatternValue],@ObjectRegexFlags=[RegexFlags],@ObjectPatternValid=[IsValid]
    FROM [monitor].[TVF_ParsePattern](@ObjectNamePattern);

    IF @StatusCode='AVAILABLE'
       AND (@SchemaPatternValid=0 OR @ObjectPatternValid=0
            OR (@SchemaNames IS NOT NULL AND @SchemaNamePattern IS NOT NULL)
            OR (@ObjectNames IS NOT NULL AND @ObjectNamePattern IS NOT NULL))
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Pattern ungültig oder exakte Liste und Pattern derselben Eigenschaft gleichzeitig angegeben.';
    END;

    IF @StatusCode='AVAILABLE'
       AND (@SchemaPatternMode IN('REGEX','REGEXI') OR @ObjectPatternMode IN('REGEX','REGEXI'))
       AND COALESCE(@Major,0)<17
    BEGIN
        SELECT @StatusCode='UNAVAILABLE_VERSION',@IsPartial=1,
               @ErrorMessage=N'Regex-Pattern benötigen SQL Server 2025 oder neuer und Compatibility Level 170.';
    END;

    CREATE TABLE [#ServiceBrokerAnalysis_NameFilters]
    (
          [FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [ItemOrdinal] int NOT NULL
        , [NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_FeatureScope]
    (
          [DatabaseName] sysname NOT NULL PRIMARY KEY
        , [IsBrokerEnabled] bit NOT NULL
        , [UserQueueCount] bigint NOT NULL
        , [UserServiceCount] bigint NOT NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_DatabaseStatus]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [IsBrokerEnabled] bit NULL
        , [UserQueueCount] bigint NOT NULL
        , [UserServiceCount] bigint NOT NULL
        , [TransmissionMessageCount] bigint NOT NULL
        , [ConversationEndpointCount] bigint NOT NULL
        , [SourceFailureCount] int NOT NULL
        , [FindingCount] bigint NOT NULL
        , [RequiredPermission] nvarchar(256) NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_SourceStatus]
    (
          [DatabaseName] sysname NULL
        , [SourceCode] varchar(64) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [RowCount] bigint NOT NULL
        , [RequiredPermission] nvarchar(256) NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_Queue]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [QueueName] sysname NOT NULL
        , [QueueObjectId] int NOT NULL
        , [ServiceCount] int NOT NULL
        , [IsBrokerEnabled] bit NOT NULL
        , [IsActivationEnabled] bit NOT NULL
        , [IsReceiveEnabled] bit NOT NULL
        , [IsEnqueueEnabled] bit NOT NULL
        , [IsRetentionEnabled] bit NOT NULL
        , [IsPoisonMessageHandlingEnabled] bit NOT NULL
        , [MaxReaders] smallint NULL
        , [ActivationProcedure] nvarchar(776) NULL
        , [ExecuteAsPrincipalId] int NULL
        , [QueueRowsApprox] bigint NULL
        , [QueueReservedMb] decimal(19,2) NULL
        , [QueueUsedMb] decimal(19,2) NULL
        , [QueueMonitorState] nvarchar(32) NULL
        , [LastEmptyRowsetTime] datetime NULL
        , [LastActivatedTime] datetime NULL
        , [TasksWaiting] int NULL
        , [ActivatedTaskCount] int NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY ([DatabaseName],[QueueObjectId])
    );
    CREATE TABLE [#ServiceBrokerAnalysis_TransmissionGroup]
    (
          [DatabaseName] sysname NOT NULL
        , [FromServiceName] nvarchar(256) NULL
        , [ToServiceName] nvarchar(256) NULL
        , [ToBrokerInstance] nvarchar(128) NULL
        , [ServiceContractName] nvarchar(256) NULL
        , [MessageTypeName] nvarchar(256) NULL
        , [TransmissionStatus] nvarchar(4000) NULL
        , [MessageCount] bigint NOT NULL
        , [ConversationErrorMessageCount] bigint NOT NULL
        , [EndDialogMessageCount] bigint NOT NULL
        , [OldestEnqueueTimeUtc] datetime NULL
        , [NewestEnqueueTimeUtc] datetime NULL
        , [OldestAgeMinutes] bigint NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_ConversationState]
    (
          [DatabaseName] sysname NOT NULL
        , [StateCode] char(2) NOT NULL
        , [StateDescription] nvarchar(60) NULL
        , [IsInitiator] bit NOT NULL
        , [IsSystem] bit NOT NULL
        , [EndpointCount] bigint NOT NULL
        , [ExpiredLifetimeCount] bigint NOT NULL
        , [EarliestLifetimeUtc] datetime NULL
        , [EarliestSecurityTimestampUtc] datetime NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#ServiceBrokerAnalysis_Findings]
    (
          [FindingOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [DatabaseName] sysname NULL
        , [SchemaName] sysname NULL
        , [ObjectName] sysname NULL
        , [Severity] varchar(16) NOT NULL
        , [Confidence] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NOT NULL
        , [MetricName] varchar(80) NOT NULL
        , [MetricValue] decimal(38,4) NULL
        , [ThresholdValue] decimal(38,4) NULL
        , [Evidence] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , [RecommendedNextCheck] nvarchar(1000) NOT NULL
    );

    IF @StatusCode='AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareNameFilters]
              @SchemaNames=@SchemaNames
            , @ObjectNames=@ObjectNames
            , @FullObjectNames=@FullObjectNames
            , @IndexNames=NULL
            , @StatisticsNames=NULL
            , @ColumnNames=NULL
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT,@FilterTable=N'#ServiceBrokerAnalysis_NameFilters';
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    DECLARE @CrossDatabaseRequested bit=0;
    IF @StatusCode='AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames=@DatabaseNames
            , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass='CATALOG_DEEP'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#ServiceBrokerAnalysis_DatabaseCandidates',@WarningTable=N'#ServiceBrokerAnalysis_DatabaseCandidateWarnings';
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    INSERT [#ServiceBrokerAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[IsBrokerEnabled],[UserQueueCount],[UserServiceCount],
     [TransmissionMessageCount],[ConversationEndpointCount],[SourceFailureCount],[FindingCount],[Detail])
    SELECT [DatabaseName],'PENDING',0,NULL,0,0,0,0,0,0,
           N'Feature-Gate und Service-Broker-Quellen werden datenbankweise best effort ausgewertet.'
    FROM [#ServiceBrokerAnalysis_DatabaseCandidates];

    INSERT [#ServiceBrokerAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[IsBrokerEnabled],[UserQueueCount],[UserServiceCount],
     [TransmissionMessageCount],[ConversationEndpointCount],[SourceFailureCount],[FindingCount],[ErrorMessage],[Detail])
    SELECT [RequestedName],[StatusCode],1,NULL,0,0,0,0,1,0,[ErrorMessage],N'Explizit angeforderte Datenbank nicht auswertbar.'
    FROM [#ServiceBrokerAnalysis_DatabaseCandidateWarnings];

    IF @StatusCode='AVAILABLE' AND NOT EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_DatabaseCandidates])
    BEGIN
        SELECT @StatusCode='NOT_APPLICABLE',@ErrorMessage=N'Keine auswertbare Datenbank im gewählten Scope.';
    END;

    DECLARE @SchemaPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @ObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @FullObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDatabaseName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    IF @SchemaPatternMode='LIKE'
        SET @SchemaPredicate+=N' AND [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @SchemaPatternMode IN('REGEX','REGEXI')
        SET @SchemaPredicate+=N' AND REGEXP_LIKE([s].[name],N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''','''+@SchemaRegexFlags+N''')';
    IF @ObjectPatternMode='LIKE'
        SET @ObjectPredicate+=N' AND [t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @ObjectPatternMode IN('REGEX','REGEXI')
        SET @ObjectPredicate+=N' AND REGEXP_LIKE([t].[name],N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''','''+@ObjectRegexFlags+N''')';

    IF @StatusCode='AVAILABLE'
    BEGIN
        DECLARE @DbName sysname,@CompatibilityLevel int,@Sql nvarchar(max),@Rows bigint;
        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName],[CompatibilityLevel]
            FROM [#ServiceBrokerAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;

        WHILE @@FETCH_STATUS=0
        BEGIN
            IF (@SchemaPatternMode IN('REGEX','REGEXI') OR @ObjectPatternMode IN('REGEX','REGEXI'))
               AND COALESCE(@CompatibilityLevel,0)<170
            BEGIN
                UPDATE [#ServiceBrokerAnalysis_DatabaseStatus]
                SET [StatusCode]='UNAVAILABLE_FEATURE',[IsPartial]=1,[SourceFailureCount]=1,
                    [ErrorMessage]=N'Regex-Pattern benötigen Compatibility Level 170.',
                    [Detail]=N'Für diese Datenbank wurde wegen inkompatiblem Patternvertrag keine Analyse ausgeführt.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'FILTER_CONTRACT','UNAVAILABLE_FEATURE',1,0,NULL,NULL,
                       N'Regex-Pattern benötigen Compatibility Level 170.',N'Keine Quellenabfrage ausgeführt.');
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#ServiceBrokerAnalysis_FeatureScope]([DatabaseName],[IsBrokerEnabled],[UserQueueCount],[UserServiceCount])
SELECT @pDatabaseName,CONVERT(bit,[d].[is_broker_enabled]),[q].[QueueCount],[svc].[ServiceCount]
FROM [sys].[databases] [d] WITH (NOLOCK)
CROSS APPLY
(
    SELECT COUNT_BIG(*) AS [QueueCount]
    FROM [sys].[service_queues] WITH (NOLOCK)
    WHERE [is_ms_shipped]=0
) [q]
CROSS APPLY
(
    SELECT COUNT_BIG(*) AS [ServiceCount]
    FROM [sys].[services] [x] WITH (NOLOCK)
    JOIN [sys].[service_queues] [sq] WITH (NOLOCK) ON [sq].[object_id]=[x].[service_queue_id]
    WHERE [sq].[is_ms_shipped]=0
) [svc]
WHERE [d].[database_id]=DB_ID();
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_FEATURE_GATE','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sichtbare Datenbank- und Broker-Metadaten',NULL,NULL,
                       N'Prüft Datenbankschalter und sichtbare nicht ausgelieferte Queues/Services; Nullzählungen beweisen bei eingeschränkter Metadatensichtbarkeit keine Abwesenheit.');
                UPDATE [ds]
                SET [IsBrokerEnabled]=[fs].[IsBrokerEnabled],
                    [UserQueueCount]=[fs].[UserQueueCount],
                    [UserServiceCount]=[fs].[UserServiceCount]
                FROM [#ServiceBrokerAnalysis_DatabaseStatus] [ds]
                JOIN [#ServiceBrokerAnalysis_FeatureScope] [fs] ON [fs].[DatabaseName]=[ds].[DatabaseName]
                WHERE [ds].[DatabaseName]=@DbName;
            END TRY
            BEGIN CATCH
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_FEATURE_GATE','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sichtbare Datenbank- und Broker-Metadaten',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Feature-Sichtbarkeit konnte nicht bestimmt werden.');
                UPDATE [#ServiceBrokerAnalysis_DatabaseStatus]
                SET [StatusCode]='ERROR_HANDLED',[IsPartial]=1,[SourceFailureCount]=[SourceFailureCount]+1,
                    [ErrorNumber]=ERROR_NUMBER(),[ErrorMessage]=ERROR_MESSAGE(),
                    [Detail]=N'Feature-Gate fehlgeschlagen; keine belastbare Anwendbarkeitsaussage.'
                WHERE [DatabaseName]=@DbName;
            END CATCH;

            IF NOT EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_FeatureScope] WHERE [DatabaseName]=@DbName)
            BEGIN
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            IF EXISTS
            (
                SELECT 1 FROM [#ServiceBrokerAnalysis_FeatureScope]
                WHERE [DatabaseName]=@DbName AND [IsBrokerEnabled]=0
                  AND [UserQueueCount]=0 AND [UserServiceCount]=0
            )
            BEGIN
                UPDATE [#ServiceBrokerAnalysis_DatabaseStatus]
                SET [StatusCode]='NOT_APPLICABLE_VISIBLE_SCOPE',[IsPartial]=0,
                    [Detail]=N'Service Broker ist deaktiviert und im sichtbaren Katalogscope wurden keine benutzerdefinierten Queues oder Services erkannt; dies beweist bei eingeschränkter Metadatensichtbarkeit keine vollständige Abwesenheit.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                SELECT @DbName,[SourceCode],'NOT_APPLICABLE',0,0,[RequiredPermission],NULL,NULL,
                       N'Quelle wegen negativem sichtbaren Feature-Gate nicht aufgerufen.'
                FROM (VALUES
                      ('BROKER_QUEUE_CATALOG',N'Katalogsicht auf sichtbare Broker-Queues und Services'),
                      ('BROKER_QUEUE_CAPACITY',N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION'),
                      ('BROKER_QUEUE_MONITOR',N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE'),
                      ('BROKER_ACTIVATED_TASKS',N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE'),
                      ('BROKER_TRANSMISSION',N'Katalogsicht auf sys.transmission_queue'),
                      ('BROKER_CONVERSATION',N'Katalogsicht auf sys.conversation_endpoints'))
                     [x]([SourceCode],[RequiredPermission]);
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#ServiceBrokerAnalysis_Queue]
([DatabaseName],[SchemaName],[QueueName],[QueueObjectId],[ServiceCount],[IsBrokerEnabled],
 [IsActivationEnabled],[IsReceiveEnabled],[IsEnqueueEnabled],[IsRetentionEnabled],
 [IsPoisonMessageHandlingEnabled],[MaxReaders],[ActivationProcedure],[ExecuteAsPrincipalId],
 [AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[s].[name],[t].[name],[t].[object_id],CONVERT(int,[svc].[ServiceCount]),
       CONVERT(bit,[d].[is_broker_enabled]),[t].[is_activation_enabled],[t].[is_receive_enabled],
       [t].[is_enqueue_enabled],[t].[is_retention_enabled],[t].[is_poison_message_handling_enabled],
       [t].[max_readers],[t].[activation_procedure],[t].[execute_as_principal_id],''AVAILABLE'',
       N''Queue-Kataloge und Aktivierungsmetadaten beweisen weder erfolgreiche Verarbeitung noch die Ursache eines deaktivierten Zustands.''
FROM [sys].[service_queues] [t] WITH (NOLOCK)
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
OUTER APPLY
(
    SELECT COUNT_BIG(*) AS [ServiceCount]
    FROM [sys].[services] [x] WITH (NOLOCK)
    WHERE [x].[service_queue_id]=[t].[object_id]
) [svc]
CROSS APPLY
(
    SELECT [is_broker_enabled]
    FROM [sys].[databases] WITH (NOLOCK)
    WHERE [database_id]=DB_ID()
) [d]
WHERE [t].[is_ms_shipped]=0'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N';
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_QUEUE_CATALOG','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sichtbare Broker-Queues und Services',NULL,NULL,
                       N'Queue-Schalter, Aktivierungskonfiguration und Service-Zuordnungsanzahl; Nullzeilen können aus Filtern oder Metadatensichtbarkeit folgen.');
            END TRY
            BEGIN CATCH
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_QUEUE_CATALOG','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sichtbare Broker-Queues und Services',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Queue-abhängige Kapazitäts- und Aktivierungsquellen werden ausgelassen; Transmission und Conversations bleiben unabhängig.');
            END CATCH;

            IF EXISTS
            (
                SELECT 1 FROM [#ServiceBrokerAnalysis_SourceStatus]
                WHERE [DatabaseName]=@DbName AND [SourceCode]='BROKER_QUEUE_CATALOG' AND [IsPartial]=1
            )
            BEGIN
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES
                (@DbName,'BROKER_QUEUE_CAPACITY','UNAVAILABLE_DEPENDENCY',1,0,
                 N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION',
                 NULL,N'BROKER_QUEUE_CATALOG ist nicht verfügbar.',N'Keine Partitionsstatistik ohne belastbare Queue-Zuordnung.'),
                (@DbName,'BROKER_QUEUE_MONITOR','UNAVAILABLE_DEPENDENCY',1,0,
                 N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',
                 NULL,N'BROKER_QUEUE_CATALOG ist nicht verfügbar.',N'Keine Monitor-Zuordnung ohne belastbare Queue-Zuordnung.'),
                (@DbName,'BROKER_ACTIVATED_TASKS','UNAVAILABLE_DEPENDENCY',1,0,
                 N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',
                 NULL,N'BROKER_QUEUE_CATALOG ist nicht verfügbar.',N'Keine Task-Zuordnung ohne belastbare Queue-Zuordnung.');
            END
            ELSE
            BEGIN
                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
UPDATE [q]
SET [QueueRowsApprox]=[p].[RowCountApprox],
    [QueueReservedMb]=[p].[ReservedMb],
    [QueueUsedMb]=[p].[UsedMb]
FROM [#ServiceBrokerAnalysis_Queue] [q]
OUTER APPLY
(
    SELECT SUM(CASE WHEN [index_id] IN(0,1) THEN CONVERT(bigint,[row_count]) END) AS [RowCountApprox],
           CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[reserved_page_count]))*8.0/1024.0) AS [ReservedMb],
           CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[used_page_count]))*8.0/1024.0) AS [UsedMb]
    FROM [sys].[dm_db_partition_stats] WITH (NOLOCK)
    WHERE [object_id]=[q].[QueueObjectId]
) [p]
WHERE [q].[DatabaseName]=@pDatabaseName;
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    INSERT [#ServiceBrokerAnalysis_SourceStatus]
                    VALUES(@DbName,'BROKER_QUEUE_CAPACITY','AVAILABLE',0,@Rows,
                           N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION',NULL,NULL,
                           N'Approximative Queue-Zeilen und Seiten ohne Queue-Nutzdaten; row_count ist kein Durchsatz- oder Altersnachweis.');
                END TRY
                BEGIN CATCH
                    INSERT [#ServiceBrokerAnalysis_SourceStatus]
                    VALUES(@DbName,'BROKER_QUEUE_CAPACITY','ERROR_HANDLED',1,0,
                           N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION',
                           ERROR_NUMBER(),ERROR_MESSAGE(),N'Queue-Katalog und andere Broker-Quellen bleiben verfügbar.');
                END CATCH;

                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
UPDATE [q]
SET [QueueMonitorState]=[m].[MonitorState],
    [LastEmptyRowsetTime]=[m].[LastEmptyRowsetTime],
    [LastActivatedTime]=[m].[LastActivatedTime],
    [TasksWaiting]=[m].[TasksWaiting]
FROM [#ServiceBrokerAnalysis_Queue] [q]
OUTER APPLY
(
    SELECT MAX([state]) AS [MonitorState],MAX([last_empty_rowset_time]) AS [LastEmptyRowsetTime],
           MAX([last_activated_time]) AS [LastActivatedTime],MAX([tasks_waiting]) AS [TasksWaiting]
    FROM [sys].[dm_broker_queue_monitors] WITH (NOLOCK)
    WHERE [database_id]=DB_ID() AND [queue_id]=[q].[QueueObjectId]
) [m]
WHERE [q].[DatabaseName]=@pDatabaseName;
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    INSERT [#ServiceBrokerAnalysis_SourceStatus]
                    VALUES(@DbName,'BROKER_QUEUE_MONITOR','AVAILABLE',0,@Rows,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                           N'Monitorstatus und Zeitstempel sind Momentaufnahmen; wartende Tasks sind wartende Receiver und kein Backlogmaß.');
                END TRY
                BEGIN CATCH
                    INSERT [#ServiceBrokerAnalysis_SourceStatus]
                    VALUES(@DbName,'BROKER_QUEUE_MONITOR','ERROR_HANDLED',1,0,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',
                           ERROR_NUMBER(),ERROR_MESSAGE(),N'Queue-Katalog, Kapazität und andere Broker-Quellen bleiben verfügbar.');
                END CATCH;

                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
UPDATE [q]
SET [ActivatedTaskCount]=[a].[ActivatedTaskCount]
FROM [#ServiceBrokerAnalysis_Queue] [q]
OUTER APPLY
(
    SELECT CONVERT(int,COUNT_BIG(*)) AS [ActivatedTaskCount]
    FROM [sys].[dm_broker_activated_tasks] WITH (NOLOCK)
    WHERE [database_id]=DB_ID() AND [queue_id]=[q].[QueueObjectId]
) [a]
WHERE [q].[DatabaseName]=@pDatabaseName;
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    INSERT [#ServiceBrokerAnalysis_SourceStatus]
                    VALUES(@DbName,'BROKER_ACTIVATED_TASKS','AVAILABLE',0,@Rows,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                           N'Zählt aktuell von Service Broker aktivierte Prozeduren pro Queue; externe oder manuelle Reader sind nicht vollständig abgebildet.');
                END TRY
                BEGIN CATCH
                    INSERT [#ServiceBrokerAnalysis_SourceStatus]
                    VALUES(@DbName,'BROKER_ACTIVATED_TASKS','ERROR_HANDLED',1,0,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',
                           ERROR_NUMBER(),ERROR_MESSAGE(),N'Queue-Katalog, Kapazität und andere Broker-Quellen bleiben verfügbar.');
                END CATCH;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#ServiceBrokerAnalysis_TransmissionGroup]
([DatabaseName],[FromServiceName],[ToServiceName],[ToBrokerInstance],[ServiceContractName],
 [MessageTypeName],[TransmissionStatus],[MessageCount],[ConversationErrorMessageCount],
 [EndDialogMessageCount],[OldestEnqueueTimeUtc],[NewestEnqueueTimeUtc],[OldestAgeMinutes],[EvidenceLimit])
SELECT @pDatabaseName,[x].[from_service_name],[x].[to_service_name],[x].[to_broker_instance],
       [x].[service_contract_name],[x].[message_type_name],NULLIF([x].[transmission_status],N''''),
       COUNT_BIG(*),SUM(CONVERT(bigint,[x].[is_conversation_error])),
       SUM(CONVERT(bigint,[x].[is_end_of_dialog])),MIN([x].[enqueue_time]),MAX([x].[enqueue_time]),
       DATEDIFF_BIG(MINUTE,MIN([x].[enqueue_time]),SYSUTCDATETIME()),
       N''Transmission-Einträge können auch während normaler Zustellung oder Retention sichtbar sein; Alter und Status beweisen allein keinen dauerhaften Fehler.''
FROM [sys].[transmission_queue] [x] WITH (NOLOCK)
LEFT JOIN [sys].[services] [svc] WITH (NOLOCK) ON [svc].[name]=[x].[from_service_name]
LEFT JOIN [sys].[service_queues] [t] WITH (NOLOCK) ON [t].[object_id]=[svc].[service_queue_id]
LEFT JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
WHERE 1=1'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N'
GROUP BY [x].[from_service_name],[x].[to_service_name],[x].[to_broker_instance],
         [x].[service_contract_name],[x].[message_type_name],NULLIF([x].[transmission_status],N'''');
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_TRANSMISSION','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sys.transmission_queue',NULL,NULL,
                       N'Nur nicht-payloadhaltige Metadaten werden gruppiert; Nachrichtenkörper und Conversation-Handles werden nicht gelesen.');
            END TRY
            BEGIN CATCH
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_TRANSMISSION','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sys.transmission_queue',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Queue- und Conversation-Evidenz bleiben verfügbar.');
            END CATCH;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#ServiceBrokerAnalysis_ConversationState]
([DatabaseName],[StateCode],[StateDescription],[IsInitiator],[IsSystem],[EndpointCount],
 [ExpiredLifetimeCount],[EarliestLifetimeUtc],[EarliestSecurityTimestampUtc],[EvidenceLimit])
SELECT @pDatabaseName,[x].[state],[x].[state_desc],CONVERT(bit,[x].[is_initiator]),[x].[is_system],
       COUNT_BIG(*),SUM(CASE WHEN [x].[lifetime]<SYSUTCDATETIME() THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),
       MIN([x].[lifetime]),MIN([x].[security_timestamp]),
       N''Aggregierte Endpoint-Zustände und Zeitstempel beweisen weder fachliche Vollständigkeit noch die Ursache verzögerter Conversation-Bereinigung.''
FROM [sys].[conversation_endpoints] [x] WITH (NOLOCK)
LEFT JOIN [sys].[services] [svc] WITH (NOLOCK) ON [svc].[service_id]=[x].[service_id]
LEFT JOIN [sys].[service_queues] [t] WITH (NOLOCK) ON [t].[object_id]=[svc].[service_queue_id]
LEFT JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
WHERE 1=1'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N'
GROUP BY [x].[state],[x].[state_desc],[x].[is_initiator],[x].[is_system];
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_CONVERSATION','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sys.conversation_endpoints',NULL,NULL,
                       N'Zustände werden ohne Handles, Gruppen-IDs, Schlüsselkennungen oder Nachrichteninhalt aggregiert.');
            END TRY
            BEGIN CATCH
                INSERT [#ServiceBrokerAnalysis_SourceStatus]
                VALUES(@DbName,'BROKER_CONVERSATION','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sys.conversation_endpoints',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Queue- und Transmission-Evidenz bleiben verfügbar.');
            END CATCH;

            FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
        END;
        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];
    END;

    UPDATE [ds]
    SET [TransmissionMessageCount]=COALESCE([tx].[MessageCount],0),
        [ConversationEndpointCount]=COALESCE([ce].[EndpointCount],0)
    FROM [#ServiceBrokerAnalysis_DatabaseStatus] [ds]
    OUTER APPLY
    (
        SELECT SUM([MessageCount]) AS [MessageCount]
        FROM [#ServiceBrokerAnalysis_TransmissionGroup] [x]
        WHERE [x].[DatabaseName]=[ds].[DatabaseName]
    ) [tx]
    OUTER APPLY
    (
        SELECT SUM([EndpointCount]) AS [EndpointCount]
        FROM [#ServiceBrokerAnalysis_ConversationState] [x]
        WHERE [x].[DatabaseName]=[ds].[DatabaseName]
    ) [ce];

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','BROKER_DISABLED_WITH_VISIBLE_OBJECTS','IS_BROKER_ENABLED',0,1,
           N'Service Broker ist für die Datenbank deaktiviert, obwohl sichtbare benutzerdefinierte Queues oder Services vorhanden sind.',
           N'Der Datenbankschalter und sichtbare Objekte beweisen nicht, ob die Deaktivierung geplant, temporär oder fehlerbedingt ist.',
           N'Betriebsabsicht, Restore-/Failover-Historie und abhängige Anwendungen prüfen; keine automatische Aktivierung ableiten.'
    FROM [#ServiceBrokerAnalysis_FeatureScope]
    WHERE [IsBrokerEnabled]=0 AND ([UserQueueCount]>0 OR [UserServiceCount]>0);

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[QueueName],'WARN','HIGH','QUEUE_RECEIVE_DISABLED','IS_RECEIVE_ENABLED',0,1,
           N'RECEIVE ist für die sichtbare Queue deaktiviert.',
           N'Der OFF-Zustand kann nach wiederholten Rollbacks durch Poison-Message-Erkennung oder manuell entstehen; ohne Ereignis- und Anwendungsevidenz ist die Ursache nicht bewiesen.',
           N'SQL-Fehlerlog, Broker:Queue Disabled beziehungsweise Extended Events, Anwendungstransaktionen und freigegebene Queue-Diagnose prüfen.'
    FROM [#ServiceBrokerAnalysis_Queue]
    WHERE [IsReceiveEnabled]=0;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[QueueName],'WARN','HIGH','QUEUE_ENQUEUE_DISABLED','IS_ENQUEUE_ENABLED',0,1,
           N'Enqueue ist für die sichtbare Queue deaktiviert.',
           N'Der Katalogzustand zeigt keine Ursache und keine fachliche Betriebsabsicht.',
           N'Bereitstellungszustand, Betriebsabsicht und abhängige Sender prüfen; keine automatische Änderung ableiten.'
    FROM [#ServiceBrokerAnalysis_Queue]
    WHERE [IsEnqueueEnabled]=0;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[QueueName],'WARN','HIGH','INTERNAL_ACTIVATION_DISABLED','IS_ACTIVATION_ENABLED',0,1,
           N'Eine interne Aktivierungsprozedur ist konfiguriert, die Aktivierung ist jedoch deaktiviert.',
           N'Externe oder geplante Reader können beabsichtigt sein; der Katalogzustand allein beweist keinen Verarbeitungsfehler.',
           N'Startstrategie, Deployment-Zustand und verantwortlichen Readerpfad prüfen.'
    FROM [#ServiceBrokerAnalysis_Queue]
    WHERE [ActivationProcedure] IS NOT NULL AND [IsActivationEnabled]=0;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[QueueName],'WARN','MEDIUM','QUEUE_BACKLOG_CONTEXT','QUEUE_ROWS_APPROX',
           [QueueRowsApprox],@QueueRowsWarn,
           N'Die approximative Queue-Zeilenzahl überschreitet den konfigurierten Kontextgrenzwert.',
           N'row_count ist approximativ und enthält keine Aussage zu Nachrichtenalter, Durchsatz, Priorität oder fachlich zulässigem Rückstand.',
           N'Zeitreihe, Ankunfts-/Verarbeitungsrate, Conversation-Gruppen und Readerkapazität mit freigegebener Laufzeitevidenz korrelieren.'
    FROM [#ServiceBrokerAnalysis_Queue]
    WHERE [QueueRowsApprox]>=@QueueRowsWarn;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[QueueName],'WARN','MEDIUM','INTERNAL_ACTIVATION_PROGRESS_REVIEW','MINUTES_SINCE_LAST_ACTIVATION',
           CASE WHEN [LastActivatedTime] IS NULL THEN NULL ELSE DATEDIFF_BIG(MINUTE,[LastActivatedTime],@Now) END,
           @ActivationSilenceWarnMinutes,
           N'Für eine nichtleere Queue mit aktivierter interner Prozedur ist aktuell kein aktivierter Task sichtbar und der Monitor meldet keine laufenden Receives.',
           N'DMV-Werte sind Momentaufnahmen; Conversation-Group-Locks, externe Reader, kurze Aktivierungen und fehlende DMV-Rechte können die Interpretation verändern.',
           N'Queue-Monitor, aktivierte Tasks, Fehlerlog und Ausführungskontext wiederholt messen; Prozedur nur kontrolliert und mit passendem EXECUTE-AS-Kontext testen.'
    FROM [#ServiceBrokerAnalysis_Queue]
    WHERE [QueueRowsApprox]>0
      AND [ActivationProcedure] IS NOT NULL
      AND [IsActivationEnabled]=1
      AND COALESCE([ActivatedTaskCount],0)=0
      AND COALESCE([QueueMonitorState],N'')<>N'RECEIVES_OCCURRING'
      AND ([LastActivatedTime] IS NULL OR DATEDIFF_BIG(MINUTE,[LastActivatedTime],@Now)>=@ActivationSilenceWarnMinutes)
      AND EXISTS
          (SELECT 1 FROM [#ServiceBrokerAnalysis_SourceStatus] [ss]
           WHERE [ss].[DatabaseName]=[#ServiceBrokerAnalysis_Queue].[DatabaseName]
             AND [ss].[SourceCode] IN('BROKER_QUEUE_CAPACITY','BROKER_QUEUE_MONITOR','BROKER_ACTIVATED_TASKS')
           GROUP BY [ss].[DatabaseName]
           HAVING SUM(CONVERT(int,[ss].[IsPartial]))=0 AND COUNT(*)=3);

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[QueueName],'INFO','MEDIUM','QUEUE_RETENTION_ENABLED_CONTEXT','IS_RETENTION_ENABLED',1,0,
           N'Die Queue behält Nachrichten bis zum Ende des Dialogs.',
           N'Retention kann sichtbare Zeilen trotz erfolgreicher Übertragung erhalten; dies ist Konfiguration und kein Fehler.',
           N'Bei Kapazitätsfragen Dialog-Lebenszyklus und erwartete Retention gemeinsam prüfen.'
    FROM [#ServiceBrokerAnalysis_Queue]
    WHERE [IsRetentionEnabled]=1;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[QueueName],'INFO','MEDIUM','POISON_HANDLING_DISABLED_CONTEXT','IS_POISON_HANDLING_ENABLED',0,1,
           N'Die automatische Poison-Message-Behandlung ist für die Queue deaktiviert.',
           N'Dies kann eine bewusste Anwendungsstrategie sein und beweist keine vorhandene Poison Message.',
           N'Anwendungsseitige Fehler- und Wiederholungsstrategie gegen die Betriebsanforderungen prüfen.'
    FROM [#ServiceBrokerAnalysis_Queue]
    WHERE [IsPoisonMessageHandlingEnabled]=0;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','MEDIUM','TRANSMISSION_BACKLOG_CONTEXT','TRANSMISSION_MESSAGE_COUNT',
           SUM([MessageCount]),@TransmissionRowsWarn,
           N'Die aggregierte Transmission Queue überschreitet den konfigurierten Zeilengrenzwert.',
           N'Nicht alle Transmission-Einträge sind Fehler; Zustellung, Bestätigung und Retention können Einträge vorübergehend erhalten.',
           N'Statusgruppen, Alter, Routing, Endpunktverfügbarkeit und Zeitverlauf gemeinsam prüfen.'
    FROM [#ServiceBrokerAnalysis_TransmissionGroup]
    GROUP BY [DatabaseName]
    HAVING SUM([MessageCount])>=@TransmissionRowsWarn;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','TRANSMISSION_STATUS_REPORTED','TRANSMISSION_MESSAGE_COUNT',
           [MessageCount],NULL,
           LEFT(CONCAT(N'Für eine Transmission-Gruppe ist ein Übertragungsstatus gemeldet: ',[TransmissionStatus]),1000),
           [EvidenceLimit],
           N'Routing, Broker-Endpunkt, Zertifikate, Zielverfügbarkeit und Fehlerlog anhand der Laufzeitumgebung prüfen.'
    FROM [#ServiceBrokerAnalysis_TransmissionGroup]
    WHERE [TransmissionStatus] IS NOT NULL;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','MEDIUM','AGED_TRANSMISSION_REVIEW','OLDEST_AGE_MINUTES',
           [OldestAgeMinutes],@TransmissionAgeWarnMinutes,
           N'Der älteste Eintrag einer Transmission-Gruppe überschreitet den konfigurierten Altersgrenzwert.',
           [EvidenceLimit],
           N'Wiederholte Messung, Status, Netzwerk-/Zielverfügbarkeit und beabsichtigte Retention korrelieren.'
    FROM [#ServiceBrokerAnalysis_TransmissionGroup]
    WHERE [OldestAgeMinutes]>=@TransmissionAgeWarnMinutes;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','CONVERSATION_ERROR_STATE','ERROR_ENDPOINT_COUNT',
           SUM([EndpointCount]),0,
           N'Mindestens ein sichtbarer Conversation Endpoint befindet sich im Zustand ERROR.',
           N'Der Endpoint-Zustand enthält keine fachliche Ursache; die zugehörige Fehlermeldung kann bereits konsumiert worden sein.',
           N'Fehlerlog, Transmission-Status und Anwendungskorrelation prüfen, ohne Nachrichteninhalt zu persistieren.'
    FROM [#ServiceBrokerAnalysis_ConversationState]
    WHERE [StateCode]='ER'
    GROUP BY [DatabaseName];

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','MEDIUM','CONVERSATION_ENDPOINT_GROWTH_CONTEXT','ENDPOINT_COUNT',
           SUM([EndpointCount]),@ConversationRowsWarn,
           N'Die sichtbare Zahl der Conversation Endpoints überschreitet den konfigurierten Kontextgrenzwert.',
           N'Die Anzahl allein beweist weder ein End-Dialog-Leck noch einen Fehler; langlebige aktive Dialoge können fachlich erforderlich sein.',
           N'Zustandsverteilung, Dialoglebenszyklus, Ankunftsrate und Verlauf getrennt untersuchen.'
    FROM [#ServiceBrokerAnalysis_ConversationState]
    GROUP BY [DatabaseName]
    HAVING SUM([EndpointCount])>=@ConversationRowsWarn;

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','MEDIUM','EXPIRED_CONVERSATION_LIFETIME_REVIEW','EXPIRED_LIFETIME_COUNT',
           SUM([ExpiredLifetimeCount]),0,
           N'Sichtbare Conversation Endpoints besitzen eine abgelaufene Lifetime.',
           N'Lifetime und Zustandsaufnahme sind Momentaufnahmen; verzögerte Systemverarbeitung und normale Übergangszustände bleiben möglich.',
           N'Zustand, Zeitverlauf, Broker-Aktivität und Fehlerlog korrelieren; keine automatische Conversation-Bereinigung ausführen.'
    FROM [#ServiceBrokerAnalysis_ConversationState]
    WHERE [ExpiredLifetimeCount]>0
    GROUP BY [DatabaseName];

    INSERT [#ServiceBrokerAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','SERVICE_BROKER_EVIDENCE_GAP',[SourceCode],
           COALESCE([ErrorMessage],N'Die angeforderte Quelle ist nicht verfügbar.'),
           [Detail],N'Berechtigung, Featureverfügbarkeit und Abhängigkeiten prüfen; andere Resultsets bleiben gültig.'
    FROM [#ServiceBrokerAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    UPDATE [q]
    SET [AssessmentStatus]=CASE WHEN EXISTS
        (SELECT 1 FROM [#ServiceBrokerAnalysis_Findings] [f]
         WHERE [f].[DatabaseName]=[q].[DatabaseName]
           AND [f].[SchemaName]=[q].[SchemaName]
           AND [f].[ObjectName]=[q].[QueueName]
           AND [f].[Severity]='WARN') THEN 'REVIEW' ELSE 'AVAILABLE' END
    FROM [#ServiceBrokerAnalysis_Queue] [q];

    UPDATE [ds]
    SET [SourceFailureCount]=[x].[FailureCount],
        [IsPartial]=CONVERT(bit,CASE WHEN [x].[FailureCount]>0 THEN 1 ELSE 0 END),
        [FindingCount]=[f].[FindingCount],
        [StatusCode]=CASE WHEN [ds].[StatusCode] IN('NOT_APPLICABLE_VISIBLE_SCOPE','UNAVAILABLE_FEATURE','ERROR_HANDLED') THEN [ds].[StatusCode]
                          WHEN [x].[FailureCount]>0 THEN 'AVAILABLE_LIMITED'
                          WHEN [f].[WarnCount]>0 THEN 'AVAILABLE_WITH_FINDING'
                          ELSE 'AVAILABLE' END,
        [Detail]=CASE WHEN [ds].[StatusCode]='PENDING' AND [x].[FailureCount]>0 THEN N'Mindestens eine isolierte Quelle fehlt; zugängliche Teilergebnisse bleiben erhalten.'
                      WHEN [ds].[StatusCode]='PENDING' AND [f].[WarnCount]>0 THEN N'Mindestens ein konfigurierter Prüfhinweis liegt vor; kein automatisches Gesundheitsurteil.'
                      WHEN [ds].[StatusCode]='PENDING' THEN N'Kein konfigurierter Warnindikator in der zugänglichen Momentaufnahme; dies beweist weder vollständige Zustellung noch fehlerfreie Verarbeitung.'
                      ELSE [ds].[Detail] END
    FROM [#ServiceBrokerAnalysis_DatabaseStatus] [ds]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FailureCount]
        FROM [#ServiceBrokerAnalysis_SourceStatus] [ss]
        WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1
    ) [x]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FindingCount],
               COALESCE(SUM(CASE WHEN [ff].[Severity]='WARN' THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),0) AS [WarnCount]
        FROM [#ServiceBrokerAnalysis_Findings] [ff]
        WHERE [ff].[DatabaseName]=[ds].[DatabaseName]
    ) [f];

    IF @StatusCode='AVAILABLE'
    BEGIN
        IF EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_DatabaseStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        ELSE IF EXISTS(SELECT 1 FROM [#ServiceBrokerAnalysis_Findings] WHERE [Severity]='WARN')
            SET @StatusCode='AVAILABLE_WITH_FINDING';
        ELSE IF NOT EXISTS
            (SELECT 1 FROM [#ServiceBrokerAnalysis_FeatureScope]
             WHERE [IsBrokerEnabled]=1 OR [UserQueueCount]>0 OR [UserServiceCount]>0)
            SET @StatusCode='NOT_APPLICABLE';
    END;

    SELECT @ErrorNumber=COALESCE(@ErrorNumber,MIN([ErrorNumber])),
           @ErrorMessage=COALESCE(@ErrorMessage,MIN([ErrorMessage]))
    FROM [#ServiceBrokerAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    IF @JsonErzeugen=1
    BEGIN
        SELECT @Json=(
            SELECT
                JSON_QUERY((SELECT N'USP_ServiceBrokerAnalysis' AS [module],@Now AS [collectedAtUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@ErrorNumber AS [errorNumber],@ErrorMessage AS [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS [meta],
                JSON_QUERY(COALESCE((SELECT * FROM [#ServiceBrokerAnalysis_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH),N'[]')) AS [databaseStatus],
                JSON_QUERY(COALESCE((SELECT * FROM [#ServiceBrokerAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode] FOR JSON PATH),N'[]')) AS [sourceStatus],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal] FOR JSON PATH),N'[]')) AS [findings],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_Queue] WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW' ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[QueueRowsApprox] DESC,[DatabaseName],[SchemaName],[QueueName] FOR JSON PATH),N'[]')) AS [queues],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_TransmissionGroup] WHERE @NurProblematisch=0 OR [TransmissionStatus] IS NOT NULL OR [OldestAgeMinutes]>=@TransmissionAgeWarnMinutes ORDER BY [OldestAgeMinutes] DESC,[MessageCount] DESC,[DatabaseName] FOR JSON PATH),N'[]')) AS [transmissionGroups],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_ConversationState] WHERE @NurProblematisch=0 OR [StateCode]='ER' OR [ExpiredLifetimeCount]>0 OR [EndpointCount]>=@ConversationRowsWarn ORDER BY [EndpointCount] DESC,[DatabaseName],[StateCode] FOR JSON PATH),N'[]')) AS [conversationStates]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
    END;

    IF @OutputMode<>'NONE'
    BEGIN
        SELECT N'USP_ServiceBrokerAnalysis' AS [Module],@Now AS [CollectedAtUtc],@StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],
               N'Read-only Broker-Metadatenaufnahme; keine Queue-Nutzdaten, Nachrichtenkörper, RECEIVE-, DDL- oder Conversation-Änderung.' AS [Detail];
        SELECT * FROM [#ServiceBrokerAnalysis_DatabaseStatus] ORDER BY [DatabaseName];
        SELECT * FROM [#ServiceBrokerAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode];
        SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_Findings]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal];
        SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_Queue]
        WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW'
        ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,
                 [QueueRowsApprox] DESC,[DatabaseName],[SchemaName],[QueueName];
        SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_TransmissionGroup]
        WHERE @NurProblematisch=0 OR [TransmissionStatus] IS NOT NULL OR [OldestAgeMinutes]>=@TransmissionAgeWarnMinutes
        ORDER BY [OldestAgeMinutes] DESC,[MessageCount] DESC,[DatabaseName];
        SELECT TOP(@Limit) * FROM [#ServiceBrokerAnalysis_ConversationState]
        WHERE @NurProblematisch=0 OR [StateCode]='ER' OR [ExpiredLifetimeCount]>0 OR [EndpointCount]>=@ConversationRowsWarn
        ORDER BY [EndpointCount] DESC,[DatabaseName],[StateCode];
    END;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=LEFT(CONCAT(N'USP_ServiceBrokerAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe strukturierte Quellenstatus.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ServiceBrokerAnalysis_Findings'
            , @ResultLabel=N'ServiceBrokerAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ServiceBrokerAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
