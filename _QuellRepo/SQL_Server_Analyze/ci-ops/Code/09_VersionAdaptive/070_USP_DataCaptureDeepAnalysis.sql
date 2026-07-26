USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_DataCaptureDeepAnalysis
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Stored Procedure
Zweck        : Vertieft Change Tracking, Change Data Capture und lokal
               erreichbare Replikationsmetadaten mit isolierten Quellen.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.change_tracking_databases, sys.change_tracking_tables,
               cdc.change_tables, sys.dm_cdc_log_scan_sessions,
               sys.dm_cdc_errors, msdb.dbo.cdc_jobs sowie lokale
               MSdistribution_*, MSlogreader_*, MSmerge_* und MSrepl_errors.
Methodik     : Feature-Gate und Quellen werden best effort ausgewertet.
               Grenzwerte sind konfigurierbare Pruefheuristiken. Ein sicherer
               Change-Tracking-Synchronisationsverlust wird nur gegen eine
               explizit gelieferte Client-Version bewertet.
Grenzen      : Keine Nutzdaten, Change-Table-Zeilen, Replikationsbefehle,
               Anmeldeinformationen, Agent-Commands oder DDL. Eine entfernte
               oder unzugaengliche Distribution wird als Evidenzluecke und
               niemals als gesunder Zustand ausgegeben.
Kosten       : MEDIUM; Kataloge, kleine CDC-DMVs, Jobhistorie und aggregierte
               lokale Distributionsmetadaten.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_DataCaptureDeepAnalysis]
      @DatabaseNames                    nvarchar(max)   = NULL
    , @SystemdatenbankenEinbeziehen     bit             = 0
    , @DatabaseNamePattern              nvarchar(4000)  = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)   = NULL
    , @SchemaNamePattern                nvarchar(4000)  = NULL
    , @ObjectNames                      nvarchar(max)   = NULL
    , @ObjectNamePattern                nvarchar(4000)  = NULL
    , @FullObjectNames                  nvarchar(max)   = NULL
    , @NurProblematisch                 bit             = 0
    , @ChangeTrackingClientVersion      bigint          = NULL
    , @CdcLatencyWarnSeconds            bigint          = 300
    , @CdcCleanupGraceMinutes           bigint          = 60
    , @ErrorLookbackHours               int             = 24
    , @ReplicationLatencyWarnSeconds    bigint          = 300
    , @ReplicationPendingCommandWarn    bigint          = 10000
    , @ReplicationAgentStaleWarnMinutes bigint          = 15
    , @MaxZeilen                        int             = 2000
    , @LockTimeoutMs                    int             = 0
    , @ResultSetArt                     varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit             = 0
    , @Json                             nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                   bit             = 1
    , @Hilfe                            bit             = 0
    , @StatusCodeOut                    varchar(40)     = NULL OUTPUT
    , @IsPartialOut                     bit             = NULL OUTPUT
    , @ErrorNumberOut                   int             = NULL OUTPUT
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
                               WHEN @MaxZeilen>0 THEN CONVERT(bigint,@MaxZeilen)
                               ELSE CONVERT(bigint,0) END;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_DataCaptureDeepAnalysis';
        PRINT N'Die Procedure führt eine rein lesende Tiefenanalyse von Change Tracking, CDC und lokal erreichbarer Replikation durch.';
        PRINT N'@ChangeTrackingClientVersion ist optional; ohne Client-Wasserstand wird kein Synchronisationsverlust behauptet.';
        PRINT N'CDC- und Replikationsgrenzwerte sind Heuristiken; zeitgesteuerte Capture-Jobs und Momentaufnahmen werden kenntlich gemacht.';
        PRINT N'Exakte Schema-/Objektfilter betreffen CT- und CDC-Quelltabellen; Pattern: LIKE, regex: oder regexi:.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson; @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        PRINT N'Es werden keine Nutzdaten, Change-Table-Zeilen, Replikationsbefehle, Credentials oder Agent-Commands gelesen und keine Änderungen ausgeführt.';
        RETURN;
    END;

    IF @SystemdatenbankenEinbeziehen IS NULL OR @NurProblematisch IS NULL
       OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @ChangeTrackingClientVersion<0
       OR @CdcLatencyWarnSeconds IS NULL OR @CdcLatencyWarnSeconds NOT BETWEEN 0 AND 315360000
       OR @CdcCleanupGraceMinutes IS NULL OR @CdcCleanupGraceMinutes NOT BETWEEN 0 AND 52560000
       OR @ErrorLookbackHours IS NULL OR @ErrorLookbackHours NOT BETWEEN 0 AND 876000
       OR @ReplicationLatencyWarnSeconds IS NULL OR @ReplicationLatencyWarnSeconds NOT BETWEEN 0 AND 315360000
       OR @ReplicationPendingCommandWarn IS NULL OR @ReplicationPendingCommandWarn<0
       OR @ReplicationAgentStaleWarnMinutes IS NULL OR @ReplicationAgentStaleWarnMinutes NOT BETWEEN 0 AND 52560000

       OR @MaxZeilen IS NULL OR @MaxZeilen<0
       OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
       OR @OutputMode NOT IN('CONSOLE','RAW','NONE')
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungueltiger Bit-, Versions-, Grenzwert-, Mengen-, Lock-Timeout- oder Ausgabeparameter.';
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
               @ErrorMessage=N'Pattern ungueltig oder exakte Liste und Pattern derselben Eigenschaft gleichzeitig angegeben.';
    END;

    IF @StatusCode='AVAILABLE'
       AND (@SchemaPatternMode IN('REGEX','REGEXI') OR @ObjectPatternMode IN('REGEX','REGEXI'))
       AND COALESCE(@Major,0)<17
    BEGIN
        SELECT @StatusCode='UNAVAILABLE_VERSION',@IsPartial=1,
               @ErrorMessage=N'Regex-Pattern benoetigen SQL Server 2025 oder neuer und Compatibility Level 170.';
    END;

    CREATE TABLE [#DataCaptureDeepAnalysis_NameFilters]
    (
          [FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [ItemOrdinal] int NOT NULL
        , [NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_DatabaseCandidates]
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
    CREATE TABLE [#DataCaptureDeepAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_FeatureScope]
    (
          [DatabaseName] sysname NOT NULL PRIMARY KEY
        , [IsChangeTrackingEnabled] bit NOT NULL
        , [CurrentCtVersion] bigint NULL
        , [CtRetentionPeriod] bigint NULL
        , [CtRetentionUnit] nvarchar(60) NULL
        , [IsCtAutoCleanupOn] bit NULL
        , [CtTableCount] bigint NOT NULL
        , [IsCdcEnabled] bit NOT NULL
        , [CdcCaptureInstanceCount] bigint NOT NULL
        , [IsPublished] bit NOT NULL
        , [IsSubscribed] bit NOT NULL
        , [IsMergePublished] bit NOT NULL
        , [IsDistributor] bit NOT NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_DatabaseStatus]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [IsChangeTrackingEnabled] bit NULL
        , [CtTableCount] bigint NOT NULL
        , [IsCdcEnabled] bit NULL
        , [CdcCaptureInstanceCount] bigint NOT NULL
        , [HasReplicationRole] bit NULL
        , [FindingCount] bigint NOT NULL
        , [SourceFailureCount] int NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_SourceStatus]
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
    CREATE TABLE [#DataCaptureDeepAnalysis_DistributionDatabase]
    (
          [DatabaseName] sysname NOT NULL PRIMARY KEY
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_ChangeTrackingTable]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [TableName] sysname NOT NULL
        , [TableObjectId] int NOT NULL
        , [IsTrackColumnsUpdatedOn] bit NOT NULL
        , [BeginVersion] bigint NULL
        , [CleanupVersion] bigint NULL
        , [MinValidVersion] bigint NULL
        , [CurrentVersion] bigint NULL
        , [ClientVersion] bigint NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY([DatabaseName],[TableObjectId])
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_CdcCaptureInstance]
    (
          [DatabaseName] sysname NOT NULL
        , [CaptureInstance] sysname NOT NULL
        , [SourceSchema] sysname NULL
        , [SourceTable] sysname NULL
        , [SourceObjectId] int NOT NULL
        , [SupportsNetChanges] bit NOT NULL
        , [HasDropPending] bit NOT NULL
        , [CreateDate] datetime NULL
        , [OldestAvailableTimeUtc] datetime NULL
        , [OldestAvailableAgeMinutes] bigint NULL
        , [CleanupRetentionMinutes] bigint NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY([DatabaseName],[CaptureInstance])
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_CdcScanSession]
    (
          [DatabaseName] sysname NOT NULL
        , [SessionId] int NOT NULL
        , [StartTimeUtc] datetime NULL
        , [EndTimeUtc] datetime NULL
        , [ScanPhase] nvarchar(200) NULL
        , [ErrorCount] int NULL
        , [LastCommitTimeUtc] datetime NULL
        , [LastCommitCdcTimeUtc] datetime NULL
        , [LatencySeconds] bigint NULL
        , [EmptyScanCount] int NULL
        , [FailedSessionsCount] int NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_CdcErrorGroup]
    (
          [DatabaseName] sysname NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorSeverity] int NULL
        , [PhaseNumber] int NULL
        , [ErrorCount] bigint NOT NULL
        , [FirstErrorTimeUtc] datetime NULL
        , [LastErrorTimeUtc] datetime NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_CdcJob]
    (
          [DatabaseName] sysname NOT NULL
        , [JobType] nvarchar(20) NOT NULL
        , [IsEnabled] bit NULL
        , [LastRunOutcome] int NULL
        , [LastRunTimeUtc] datetime NULL
        , [MaxTrans] int NULL
        , [MaxScans] int NULL
        , [IsContinuous] bit NULL
        , [PollingIntervalSeconds] bigint NULL
        , [RetentionMinutes] bigint NULL
        , [DeleteThreshold] bigint NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_ReplicationAgent]
    (
          [AgentType] varchar(20) NOT NULL
        , [DistributionDatabase] sysname NOT NULL
        , [AgentId] int NOT NULL
        , [PublisherDatabase] sysname NULL
        , [PublicationName] sysname NULL
        , [SubscriberName] sysname NULL
        , [SubscriberDatabase] sysname NULL
        , [RunStatus] int NULL
        , [LastHistoryTimeUtc] datetime NULL
        , [DurationSeconds] bigint NULL
        , [DeliveryLatencyMs] bigint NULL
        , [PendingCommandCount] bigint NULL
        , [DeliveredCommandCount] bigint NULL
        , [InactiveSubscriptionCount] bigint NULL
        , [ConflictCount] bigint NULL
        , [RetryCount] bigint NULL
        , [LastHistoryAgeMinutes] bigint NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_ReplicationErrorGroup]
    (
          [DistributionDatabase] sysname NOT NULL
        , [ErrorCode] int NULL
        , [ErrorCount] bigint NOT NULL
        , [FirstErrorTimeUtc] datetime NULL
        , [LastErrorTimeUtc] datetime NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#DataCaptureDeepAnalysis_Findings]
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
            , @ErrorMessage=@ErrorMessage OUTPUT,@FilterTable=N'#DataCaptureDeepAnalysis_NameFilters';
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
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#DataCaptureDeepAnalysis_DatabaseCandidates',@WarningTable=N'#DataCaptureDeepAnalysis_DatabaseCandidateWarnings';
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    IF @StatusCode='AVAILABLE' AND @ChangeTrackingClientVersion IS NOT NULL
       AND (SELECT COUNT_BIG(*) FROM [#DataCaptureDeepAnalysis_DatabaseCandidates])<>1
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'@ChangeTrackingClientVersion ist datenbankspezifisch und darf nur mit genau einer ausgewaehlten Datenbank verwendet werden.';
    END;

    INSERT [#DataCaptureDeepAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[CtTableCount],[CdcCaptureInstanceCount],
     [FindingCount],[SourceFailureCount],[Detail])
    SELECT [DatabaseName],CASE WHEN @StatusCode='AVAILABLE' THEN 'PENDING' ELSE @StatusCode END,
           CASE WHEN @StatusCode='AVAILABLE' THEN 0 ELSE 1 END,0,0,0,
           CASE WHEN @StatusCode='AVAILABLE' THEN 0 ELSE 1 END,
           CASE WHEN @StatusCode='AVAILABLE'
                THEN N'Feature-Gate und Data-Capture-Quellen werden datenbankweise best effort ausgewertet.'
                ELSE @ErrorMessage END
    FROM [#DataCaptureDeepAnalysis_DatabaseCandidates];

    INSERT [#DataCaptureDeepAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[CtTableCount],[CdcCaptureInstanceCount],
     [FindingCount],[SourceFailureCount],[ErrorMessage],[Detail])
    SELECT [RequestedName],[StatusCode],1,0,0,0,1,[ErrorMessage],N'Explizit angeforderte Datenbank nicht auswertbar.'
    FROM [#DataCaptureDeepAnalysis_DatabaseCandidateWarnings];

    IF @StatusCode='AVAILABLE' AND NOT EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_DatabaseCandidates])
        SELECT @StatusCode='NOT_APPLICABLE',@ErrorMessage=N'Keine auswertbare Datenbank im gewaehlten Scope.';

    DECLARE @SchemaPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @ObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @FullObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDatabaseName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
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
        DECLARE @DbName sysname,@CompatibilityLevel int,@Sql nvarchar(max),@Rows bigint,@HasCdcCatalog bit,@CdcCount bigint;
        DECLARE [DatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName],[CompatibilityLevel]
            FROM [#DataCaptureDeepAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;

        WHILE @@FETCH_STATUS=0
        BEGIN
            IF (@SchemaPatternMode IN('REGEX','REGEXI') OR @ObjectPatternMode IN('REGEX','REGEXI'))
               AND COALESCE(@CompatibilityLevel,0)<170
            BEGIN
                UPDATE [#DataCaptureDeepAnalysis_DatabaseStatus]
                SET [StatusCode]='UNAVAILABLE_FEATURE',[IsPartial]=1,[SourceFailureCount]=1,
                    [ErrorMessage]=N'Regex-Pattern benoetigen Compatibility Level 170.',
                    [Detail]=N'Fuer diese Datenbank wurde wegen inkompatiblem Patternvertrag keine Analyse ausgefuehrt.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES(@DbName,'FILTER_CONTRACT','UNAVAILABLE_FEATURE',1,0,NULL,NULL,
                       N'Regex-Pattern benoetigen Compatibility Level 170.',N'Keine Quellenabfrage ausgefuehrt.');
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#DataCaptureDeepAnalysis_FeatureScope]
([DatabaseName],[IsChangeTrackingEnabled],[CurrentCtVersion],[CtRetentionPeriod],[CtRetentionUnit],
 [IsCtAutoCleanupOn],[CtTableCount],[IsCdcEnabled],[CdcCaptureInstanceCount],
 [IsPublished],[IsSubscribed],[IsMergePublished],[IsDistributor])
SELECT @pDatabaseName,CONVERT(bit,CASE WHEN [ctd].[database_id] IS NULL THEN 0 ELSE 1 END),
       CHANGE_TRACKING_CURRENT_VERSION(),[ctd].[retention_period],[ctd].[retention_period_units_desc],
       [ctd].[is_auto_cleanup_on],
       (SELECT COUNT_BIG(*) FROM [sys].[change_tracking_tables] WITH (NOLOCK)),
       [d].[is_cdc_enabled],0,[d].[is_published],[d].[is_subscribed],
       [d].[is_merge_published],[d].[is_distributor]
FROM [sys].[databases] [d] WITH (NOLOCK)
LEFT JOIN [sys].[change_tracking_databases] [ctd] WITH (NOLOCK)
  ON [ctd].[database_id]=[d].[database_id]
WHERE [d].[database_id]=DB_ID();
SELECT @pHasCdcCatalog=CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N''cdc'' AND [t].[name]=N''change_tables'') THEN 1 ELSE 0 END);
SET @pRows=@@ROWCOUNT;';
                SELECT @Rows=0,@HasCdcCatalog=0;
                EXEC [sys].[sp_executesql] @Sql,
                     N'@pDatabaseName sysname,@pHasCdcCatalog bit OUTPUT,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pHasCdcCatalog=@HasCdcCatalog OUTPUT,@pRows=@Rows OUTPUT;
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES(@DbName,'DATA_CAPTURE_FEATURE_GATE','AVAILABLE',0,@Rows,N'Katalogsicht',NULL,NULL,
                       N'Zaehlt sichtbare Feature- und Katalogmetadaten; Nullzaehlungen beweisen bei eingeschraenkter Sichtbarkeit keine Abwesenheit.');
            END TRY
            BEGIN CATCH
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES(@DbName,'DATA_CAPTURE_FEATURE_GATE','ERROR_HANDLED',1,0,N'Katalogsicht',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Feature-Gate fehlgeschlagen; keine belastbare Anwendbarkeitsaussage.');
                UPDATE [#DataCaptureDeepAnalysis_DatabaseStatus]
                SET [StatusCode]='ERROR_HANDLED',[IsPartial]=1,[SourceFailureCount]=[SourceFailureCount]+1,
                    [ErrorNumber]=ERROR_NUMBER(),[ErrorMessage]=ERROR_MESSAGE(),
                    [Detail]=N'Feature-Gate fehlgeschlagen; zugaengliche andere Datenbanken bleiben erhalten.'
                WHERE [DatabaseName]=@DbName;
            END CATCH;

            IF NOT EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope] WHERE [DatabaseName]=@DbName)
            BEGIN
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#DataCaptureDeepAnalysis_ChangeTrackingTable]
([DatabaseName],[SchemaName],[TableName],[TableObjectId],[IsTrackColumnsUpdatedOn],
 [BeginVersion],[CleanupVersion],[MinValidVersion],[CurrentVersion],[ClientVersion],
 [AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[s].[name],[t].[name],[ct].[object_id],[ct].[is_track_columns_updated_on],
       [ct].[begin_version],[ct].[cleanup_version],CHANGE_TRACKING_MIN_VALID_VERSION([ct].[object_id]),
       CHANGE_TRACKING_CURRENT_VERSION(),@pClientVersion,''AVAILABLE'',
       N''MinValidVersion ist tabellenspezifisch. Nur der Vergleich mit einem echten Client-Wasserstand kann Synchronisationsverlust belegen.''
FROM [sys].[change_tracking_tables] [ct] WITH (NOLOCK)
JOIN [sys].[tables] [t] WITH (NOLOCK) ON [t].[object_id]=[ct].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
WHERE 1=1'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N';
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,
                     N'@pDatabaseName sysname,@pClientVersion bigint,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pClientVersion=@ChangeTrackingClientVersion,@pRows=@Rows OUTPUT;
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES(@DbName,'CHANGE_TRACKING_TABLES','AVAILABLE',0,@Rows,N'Katalogsicht',NULL,NULL,
                       N'Es werden ausschliesslich CT-Katalogversionen und keine Aenderungszeilen gelesen.');
            END TRY
            BEGIN CATCH
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES(@DbName,'CHANGE_TRACKING_TABLES','ERROR_HANDLED',1,0,N'Katalogsicht',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'CT-Tabellenevidenz konnte nicht gelesen werden.');
            END CATCH;

            IF @HasCdcCatalog=1
            BEGIN
                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#DataCaptureDeepAnalysis_CdcCaptureInstance]
([DatabaseName],[CaptureInstance],[SourceSchema],[SourceTable],[SourceObjectId],
 [SupportsNetChanges],[HasDropPending],[CreateDate],[OldestAvailableTimeUtc],
 [OldestAvailableAgeMinutes],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[ct].[capture_instance],[s].[name],[t].[name],[ct].[source_object_id],
       [ct].[supports_net_changes],[ct].[has_drop_pending],[ct].[create_date],
       [x].[OldestTime],DATEDIFF_BIG(MINUTE,[x].[OldestTime],@pNow),''AVAILABLE'',
       N''Das Alter des aeltesten verfuegbaren LSN wird gegen die Cleanup-Retention nur heuristisch bewertet; ruhige Systeme und Cleanup-Timing begrenzen die Aussage.''
FROM [cdc].[change_tables] [ct] WITH (NOLOCK)
LEFT JOIN [sys].[tables] [t] WITH (NOLOCK) ON [t].[object_id]=[ct].[source_object_id]
LEFT JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
OUTER APPLY
(
    SELECT [sys].[fn_cdc_map_lsn_to_time]([sys].[fn_cdc_get_min_lsn]([ct].[capture_instance])) AS [OldestTime]
) [x]
WHERE 1=1'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N';
SET @pRows=@@ROWCOUNT;
SELECT @pCdcCount=COUNT_BIG(*) FROM [cdc].[change_tables] WITH (NOLOCK);';
                    SELECT @Rows=0,@CdcCount=0;
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseName sysname,@pNow datetime2(3),@pCdcCount bigint OUTPUT,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pNow=@Now,@pCdcCount=@CdcCount OUTPUT,@pRows=@Rows OUTPUT;
                    UPDATE [#DataCaptureDeepAnalysis_FeatureScope] SET [CdcCaptureInstanceCount]=@CdcCount WHERE [DatabaseName]=@DbName;
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_CAPTURE_INSTANCES','AVAILABLE',0,@Rows,N'Katalogsicht auf CDC-Metadaten',NULL,NULL,
                           N'Es werden Capture-Konfiguration und LSN-Zeitgrenzen, aber keine Change-Table-Zeilen gelesen.');
                END TRY
                BEGIN CATCH
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_CAPTURE_INSTANCES','ERROR_HANDLED',1,0,N'Katalogsicht auf CDC-Metadaten',ERROR_NUMBER(),ERROR_MESSAGE(),
                           N'CDC-Capture-Instanzen oder ihre Zeitgrenzen konnten nicht gelesen werden.');
                END CATCH;
            END
            ELSE
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES(@DbName,'CDC_CAPTURE_INSTANCES','NOT_APPLICABLE',0,0,N'Katalogsicht auf CDC-Metadaten',NULL,NULL,
                       N'cdc.change_tables ist im sichtbaren Datenbankkontext nicht vorhanden.');

            IF EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope] WHERE [DatabaseName]=@DbName AND [IsCdcEnabled]=1)
            BEGIN
                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#DataCaptureDeepAnalysis_CdcScanSession]
([DatabaseName],[SessionId],[StartTimeUtc],[EndTimeUtc],[ScanPhase],[ErrorCount],
 [LastCommitTimeUtc],[LastCommitCdcTimeUtc],[LatencySeconds],
 [EmptyScanCount],[FailedSessionsCount],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[session_id],[start_time],[end_time],[scan_phase],[error_count],
       [last_commit_time],[last_commit_cdc_time],[latency],
       [empty_scan_count],[failed_sessions_count],''AVAILABLE'',
       N''CDC-Scan-DMVs enthalten nur einen Neustart-/Failover-abhaengigen Ausschnitt; auf einer AG-Sekundaerreplik kann die Quelle leer sein.''
FROM [sys].[dm_cdc_log_scan_sessions] WITH (NOLOCK)
WHERE [session_id]=0 OR [session_id]=(SELECT MAX([session_id]) FROM [sys].[dm_cdc_log_scan_sessions] WITH (NOLOCK));
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_LOG_SCAN_SESSIONS','AVAILABLE',0,@Rows,
                           N'VIEW DATABASE STATE; SQL Server 2022+ quellenabhaengige Datenbankberechtigung',NULL,NULL,
                           N'Aggregatzeile und neueste Sitzung; DMV wird bei Neustart oder Failover zurueckgesetzt.');
                END TRY
                BEGIN CATCH
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_LOG_SCAN_SESSIONS','ERROR_HANDLED',1,0,
                           N'VIEW DATABASE STATE; SQL Server 2022+ quellenabhaengige Datenbankberechtigung',ERROR_NUMBER(),ERROR_MESSAGE(),
                           N'CDC-Scan-Evidenz fehlt; andere Quellen bleiben gueltig.');
                END CATCH;

                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#DataCaptureDeepAnalysis_CdcErrorGroup]
([DatabaseName],[ErrorNumber],[ErrorSeverity],[PhaseNumber],[ErrorCount],
 [FirstErrorTimeUtc],[LastErrorTimeUtc],[EvidenceLimit])
SELECT @pDatabaseName,[error_number],[error_severity],[phase_number],COUNT_BIG(*),MIN([entry_time]),MAX([entry_time]),
       N''CDC-Fehler-DMV enthaelt nur die letzten Sitzungen seit Neustart; Meldungstext und LSN-Werte werden nicht ausgegeben.''
FROM [sys].[dm_cdc_errors] WITH (NOLOCK)
WHERE [entry_time]>=DATEADD(HOUR,-@pLookback,@pNow)
GROUP BY [error_number],[error_severity],[phase_number];
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseName sysname,@pLookback int,@pNow datetime2(3),@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pLookback=@ErrorLookbackHours,@pNow=@Now,@pRows=@Rows OUTPUT;
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_ERRORS','AVAILABLE',0,@Rows,
                           N'SQL Server 2019: VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,NULL,
                           N'Fehler werden nach Nummer, Schweregrad und Phase aggregiert; keine Meldungstexte oder LSNs.');
                END TRY
                BEGIN CATCH
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_ERRORS','ERROR_HANDLED',1,0,
                           N'SQL Server 2019: VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',ERROR_NUMBER(),ERROR_MESSAGE(),
                           N'CDC-Fehlerevidenz fehlt; andere Quellen bleiben gueltig.');
                END CATCH;
            END
            ELSE
            BEGIN
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES
                (@DbName,'CDC_LOG_SCAN_SESSIONS','NOT_APPLICABLE',0,0,N'VIEW DATABASE STATE',NULL,NULL,N'CDC ist laut sichtbarem Feature-Gate nicht aktiviert.'),
                (@DbName,'CDC_ERRORS','NOT_APPLICABLE',0,0,N'VIEW DATABASE STATE',NULL,NULL,N'CDC ist laut sichtbarem Feature-Gate nicht aktiviert.');
            END;

            IF EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope] WHERE [DatabaseName]=@DbName AND [IsCdcEnabled]=1)
            BEGIN
                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N';
SELECT @pRows=0;
IF EXISTS(SELECT 1 FROM [msdb].[sys].[tables] AS [t] WITH (NOLOCK) JOIN [msdb].[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N''dbo'' AND [t].[name]=N''cdc_jobs'')
BEGIN
    INSERT [#DataCaptureDeepAnalysis_CdcJob]
    ([DatabaseName],[JobType],[IsEnabled],[LastRunOutcome],[LastRunTimeUtc],
     [MaxTrans],[MaxScans],[IsContinuous],[PollingIntervalSeconds],[RetentionMinutes],
     [DeleteThreshold],[AssessmentStatus],[EvidenceLimit])
    SELECT @pDatabaseName,[cj].[job_type],[j].[enabled],[h].[run_status],
           CASE WHEN [h].[run_date]>0 THEN [msdb].[dbo].[agent_datetime]([h].[run_date],[h].[run_time]) END,
           [cj].[maxtrans],[cj].[maxscans],[cj].[continuous],[cj].[pollinginterval],
           [cj].[retention],[cj].[threshold],''AVAILABLE'',
           N''Jobkonfiguration und letzter Jobausgang sind keine lueckenlose Capture- oder Cleanup-Historie.''
    FROM [msdb].[dbo].[cdc_jobs] [cj] WITH (NOLOCK)
    LEFT JOIN [msdb].[dbo].[sysjobs] [j] WITH (NOLOCK) ON [j].[job_id]=[cj].[job_id]
    OUTER APPLY
    (
        SELECT TOP(1) [x].[run_status],[x].[run_date],[x].[run_time]
        FROM [msdb].[dbo].[sysjobhistory] [x] WITH (NOLOCK)
        WHERE [x].[job_id]=[cj].[job_id] AND [x].[step_id]=0
        ORDER BY [x].[instance_id] DESC
    ) [h]
    WHERE [cj].[database_id]=(SELECT [database_id] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [name]=@pDatabaseName);
    SET @pRows=@@ROWCOUNT;
END;
';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    UPDATE [ci]
                    SET [CleanupRetentionMinutes]=[j].[RetentionMinutes]
                    FROM [#DataCaptureDeepAnalysis_CdcCaptureInstance] [ci]
                    CROSS APPLY
                    (
                        SELECT MAX([RetentionMinutes]) AS [RetentionMinutes]
                        FROM [#DataCaptureDeepAnalysis_CdcJob]
                        WHERE [DatabaseName]=@DbName AND [JobType]=N'cleanup'
                    ) [j]
                    WHERE [ci].[DatabaseName]=@DbName;
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_JOBS','AVAILABLE',0,@Rows,N'Lesesicht auf msdb CDC- und Agent-Metadaten',NULL,NULL,
                           N'Jobnamen, Owner, Schritte, Commands, Proxies und Anmeldeinformationen werden nicht ausgegeben.');
                END TRY
                BEGIN CATCH
                    INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                    VALUES(@DbName,'CDC_JOBS','ERROR_HANDLED',1,0,N'Lesesicht auf msdb CDC- und Agent-Metadaten',ERROR_NUMBER(),ERROR_MESSAGE(),
                           N'CDC-Jobevidenz fehlt; andere Quellen bleiben gueltig.');
                END CATCH;
            END
            ELSE
                INSERT [#DataCaptureDeepAnalysis_SourceStatus]
                VALUES(@DbName,'CDC_JOBS','NOT_APPLICABLE',0,0,N'Lesesicht auf msdb CDC- und Agent-Metadaten',NULL,NULL,
                       N'CDC ist laut sichtbarem Feature-Gate nicht aktiviert.');

            FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
        END;

        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];
    END;

    DECLARE @DistributionDatabase sysname=NULL;
    DECLARE @ReplicationScopeDetected bit=CONVERT(bit,CASE WHEN EXISTS
    (
        SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope]
        WHERE [IsPublished]=1 OR [IsSubscribed]=1 OR [IsMergePublished]=1 OR [IsDistributor]=1
    ) THEN 1 ELSE 0 END);
    DECLARE @ReplicationAllowed bit=0;

    IF @ReplicationScopeDetected=1
    BEGIN
        SELECT @ReplicationAllowed=[IsAllowed]
        FROM [monitor].[VW_AnalyseAccessCurrent]
        WHERE [AnalysisClass]='ENTERPRISE_TOPOLOGY_DEEP';

        IF COALESCE(@ReplicationAllowed,0)=0
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_POLICY','DENIED_GROUP',1,0,N'ENTERPRISE_TOPOLOGY_DEEP',NULL,
                   N'Die lokale Replikations-Tiefenanalyse ist fuer den aktuellen Login nicht freigegeben.',
                   N'Die Topologie bleibt unbeobachtet; dies ist kein gesunder Befund.');
        ELSE
        BEGIN TRY
                IF EXISTS(SELECT 1 FROM [msdb].[sys].[tables] AS [t] WITH (NOLOCK) JOIN [msdb].[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'dbo' AND [t].[name]=N'MSdistributiondbs')
                    INSERT [#DataCaptureDeepAnalysis_DistributionDatabase]([DatabaseName])
                    SELECT DISTINCT [name]
                    FROM [msdb].[dbo].[MSdistributiondbs] WITH (NOLOCK)
                    WHERE EXISTS(SELECT 1 FROM [master].[sys].[databases] AS [d] WITH (NOLOCK) WHERE [d].[name]=[MSdistributiondbs].[name]);
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_DISTRIBUTOR_DISCOVERY','AVAILABLE',0,
                   (SELECT COUNT_BIG(*) FROM [#DataCaptureDeepAnalysis_DistributionDatabase]),
                   N'Lesesicht auf msdb Replikationsmetadaten',NULL,NULL,
                   CASE WHEN NOT EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_DistributionDatabase])
                        THEN N'Keine lokal registrierte Distribution-Datenbank sichtbar; Remote- oder Berechtigungsgrenzen werden datenbankbezogen bewertet.'
                        ELSE N'Lokal registrierte Distribution-Datenbanken sind sichtbar; nur lokale aggregierte Metadaten werden gelesen.' END);
        END TRY
        BEGIN CATCH
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_DISTRIBUTOR_DISCOVERY','ERROR_HANDLED',1,0,
                   N'Lesesicht auf msdb Replikationsmetadaten',ERROR_NUMBER(),ERROR_MESSAGE(),
                   N'Distributor-Topologie ist nicht belastbar bestimmbar; dies ist kein gesunder Befund.');
        END CATCH;
    END;
    ELSE
        INSERT [#DataCaptureDeepAnalysis_SourceStatus]
        VALUES(NULL,'REPLICATION_DISTRIBUTOR_DISCOVERY','NOT_APPLICABLE',0,0,
               N'ENTERPRISE_TOPOLOGY_DEEP und Lesesicht auf msdb Replikationsmetadaten',NULL,NULL,
               N'Keine Replikationsrolle im sichtbaren ausgewaehlten Datenbankscope erkannt.');

    IF EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_DistributionDatabase])
    BEGIN
        DECLARE [DistributionDatabaseCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName] FROM [#DataCaptureDeepAnalysis_DistributionDatabase] ORDER BY [DatabaseName];
        OPEN [DistributionDatabaseCursor];
        FETCH NEXT FROM [DistributionDatabaseCursor] INTO @DistributionDatabase;

        WHILE @@FETCH_STATUS=0
        BEGIN
        BEGIN TRY
            SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DistributionDatabase)+N';
IF (SELECT COUNT(*) FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N''dbo'' AND [t].[name] IN (N''MSdistribution_agents'',N''MSdistribution_history'',N''MSdistribution_status'',N''MSsubscriptions''))<>4
    ;THROW 54020,N''Erforderliche lokale Distribution-Metadaten fehlen.'',1;
INSERT [#DataCaptureDeepAnalysis_ReplicationAgent]
([AgentType],[DistributionDatabase],[AgentId],[PublisherDatabase],[PublicationName],[SubscriberName],
 [SubscriberDatabase],[RunStatus],[LastHistoryTimeUtc],[DurationSeconds],
 [DeliveryLatencyMs],[PendingCommandCount],[DeliveredCommandCount],
 [InactiveSubscriptionCount],[LastHistoryAgeMinutes],[AssessmentStatus],[EvidenceLimit])
SELECT ''DISTRIBUTION'',@pDistributionDatabase,[a].[id],[a].[publisher_db],[a].[publication],[a].[subscriber_name],
       [a].[subscriber_db],[h].[runstatus],[h].[time],[h].[duration],[h].[delivery_latency],
       [p].[PendingCommands],[h].[delivered_commands],[s].[InactiveSubscriptions],
       DATEDIFF_BIG(MINUTE,[h].[time],@pNow),''AVAILABLE'',
       N''Undelivered commands sind ein lokaler Distributor-Snapshot. Idle ist ohne Rueckstand kein Fehler; History ist keine lueckenlose Zeitreihe.''
FROM [dbo].[MSdistribution_agents] [a] WITH (NOLOCK)
OUTER APPLY
(
    SELECT TOP(1) [x].[runstatus],[x].[time],[x].[duration],[x].[delivery_latency],[x].[delivered_commands]
    FROM [dbo].[MSdistribution_history] [x] WITH (NOLOCK)
    WHERE [x].[agent_id]=[a].[id]
    ORDER BY [x].[time] DESC
) [h]
OUTER APPLY
(
    SELECT SUM(CONVERT(bigint,[x].[UndelivCmdsInDistDB])) AS [PendingCommands]
    FROM [dbo].[MSdistribution_status] [x] WITH (NOLOCK)
    WHERE [x].[agent_id]=[a].[id]
) [p]
OUTER APPLY
(
    SELECT COUNT_BIG(*) AS [InactiveSubscriptions]
    FROM [dbo].[MSsubscriptions] [x] WITH (NOLOCK)
    WHERE [x].[agent_id]=[a].[id] AND [x].[status]<>2
) [s]
WHERE EXISTS
(
    SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope] [fs]
    WHERE [fs].[DatabaseName]=[a].[publisher_db] COLLATE SQL_Latin1_General_CP1_CS_AS
       OR [fs].[DatabaseName]=[a].[subscriber_db] COLLATE SQL_Latin1_General_CP1_CS_AS
       OR [fs].[IsDistributor]=1
);
SET @pRows=@@ROWCOUNT;';
            SET @Rows=0;
            EXEC [sys].[sp_executesql] @Sql,N'@pDistributionDatabase sysname,@pNow datetime2(3),@pRows bigint OUTPUT',
                 @pDistributionDatabase=@DistributionDatabase,@pNow=@Now,@pRows=@Rows OUTPUT;
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_DISTRIBUTION_AGENTS','AVAILABLE',0,@Rows,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,
                   N'Keine Replikationsbefehle, Sequenznummern, Kommentare, Job-Commands oder Sicherheitsprofile werden gelesen.');
        END TRY
        BEGIN CATCH
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_DISTRIBUTION_AGENTS','ERROR_HANDLED',1,0,N'Lesesicht auf lokale Distribution-Datenbank',ERROR_NUMBER(),ERROR_MESSAGE(),
                   N'Distribution-Agent-, Rueckstands- oder Historienevidenz fehlt.');
        END CATCH;

        BEGIN TRY
            SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DistributionDatabase)+N';
IF (SELECT COUNT(*) FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N''dbo'' AND [t].[name] IN (N''MSlogreader_agents'',N''MSlogreader_history''))<>2
    ;THROW 54021,N''Erforderliche lokale Log-Reader-Metadaten fehlen.'',1;
INSERT [#DataCaptureDeepAnalysis_ReplicationAgent]
([AgentType],[DistributionDatabase],[AgentId],[PublisherDatabase],[PublicationName],[RunStatus],
 [LastHistoryTimeUtc],[DurationSeconds],[DeliveryLatencyMs],[DeliveredCommandCount],
 [LastHistoryAgeMinutes],[AssessmentStatus],[EvidenceLimit])
SELECT ''LOG_READER'',@pDistributionDatabase,[a].[id],[a].[publisher_db],[a].[publication],[h].[runstatus],
       [h].[time],[h].[duration],[h].[delivery_latency],[h].[delivered_commands],
       DATEDIFF_BIG(MINUTE,[h].[time],@pNow),''AVAILABLE'',
       N''Log-Reader-History ist eine lokale, bereinigbare Verlaufstabelle; einzelne Zustandszeilen beweisen keine dauerhafte Stoerung.''
FROM [dbo].[MSlogreader_agents] [a] WITH (NOLOCK)
OUTER APPLY
(
    SELECT TOP(1) [x].[runstatus],[x].[time],[x].[duration],[x].[delivery_latency],[x].[delivered_commands]
    FROM [dbo].[MSlogreader_history] [x] WITH (NOLOCK)
    WHERE [x].[agent_id]=[a].[id]
    ORDER BY [x].[time] DESC
) [h]
WHERE EXISTS
(
    SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope] [fs]
    WHERE [fs].[DatabaseName]=[a].[publisher_db] COLLATE SQL_Latin1_General_CP1_CS_AS
       OR [fs].[IsDistributor]=1
);
SET @pRows=@@ROWCOUNT;';
            SET @Rows=0;
            EXEC [sys].[sp_executesql] @Sql,N'@pDistributionDatabase sysname,@pNow datetime2(3),@pRows bigint OUTPUT',
                 @pDistributionDatabase=@DistributionDatabase,@pNow=@Now,@pRows=@Rows OUTPUT;
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_LOG_READER_AGENTS','AVAILABLE',0,@Rows,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,
                   N'Agent- und Historienmetadaten ohne Login-, Passwort-, Command-, Kommentar- oder Sequenzdaten.');
        END TRY
        BEGIN CATCH
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_LOG_READER_AGENTS','ERROR_HANDLED',1,0,N'Lesesicht auf lokale Distribution-Datenbank',ERROR_NUMBER(),ERROR_MESSAGE(),
                   N'Log-Reader-Agent- oder Historienevidenz fehlt.');
        END CATCH;

        BEGIN TRY
            SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DistributionDatabase)+N';
IF (SELECT COUNT(*) FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N''dbo'' AND [t].[name] IN (N''MSmerge_agents'',N''MSmerge_sessions''))<>2
    ;THROW 54022,N''Erforderliche lokale Merge-Metadaten fehlen.'',1;
INSERT [#DataCaptureDeepAnalysis_ReplicationAgent]
([AgentType],[DistributionDatabase],[AgentId],[PublisherDatabase],[PublicationName],[SubscriberName],
 [SubscriberDatabase],[RunStatus],[LastHistoryTimeUtc],[DurationSeconds],
 [ConflictCount],[RetryCount],[LastHistoryAgeMinutes],[AssessmentStatus],[EvidenceLimit])
SELECT ''MERGE'',@pDistributionDatabase,[a].[id],[a].[publisher_db],[a].[publication],[a].[subscriber_name],
       [a].[subscriber_db],[h].[runstatus],[h].[end_time],[h].[duration],
       COALESCE([h].[upload_conflicts],0)+COALESCE([h].[download_conflicts],0),
       COALESCE([h].[upload_rows_retried],0)+COALESCE([h].[download_rows_retried],0),
       DATEDIFF_BIG(MINUTE,[h].[end_time],@pNow),''AVAILABLE'',
       N''Merge-Sessions sind lokale, bereinigbare Historie; Konflikt- und Retry-Zaehler benoetigen Publication- und Workload-Kontext.''
FROM [dbo].[MSmerge_agents] [a] WITH (NOLOCK)
OUTER APPLY
(
    SELECT TOP(1) [x].[runstatus],[x].[end_time],[x].[duration],
           [x].[upload_conflicts],[x].[download_conflicts],[x].[upload_rows_retried],[x].[download_rows_retried]
    FROM [dbo].[MSmerge_sessions] [x] WITH (NOLOCK)
    WHERE [x].[agent_id]=[a].[id]
    ORDER BY [x].[start_time] DESC
) [h]
WHERE EXISTS
(
    SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope] [fs]
    WHERE [fs].[DatabaseName]=[a].[publisher_db] COLLATE SQL_Latin1_General_CP1_CS_AS
       OR [fs].[DatabaseName]=[a].[subscriber_db] COLLATE SQL_Latin1_General_CP1_CS_AS
       OR [fs].[IsDistributor]=1
);
SET @pRows=@@ROWCOUNT;';
            SET @Rows=0;
            EXEC [sys].[sp_executesql] @Sql,N'@pDistributionDatabase sysname,@pNow datetime2(3),@pRows bigint OUTPUT',
                 @pDistributionDatabase=@DistributionDatabase,@pNow=@Now,@pRows=@Rows OUTPUT;
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_MERGE_AGENTS','AVAILABLE',0,@Rows,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,
                   N'Keine Zeilenkonflikte, Resolver-Nutzdaten, Agent-Credentials oder Job-Commands werden gelesen.');
        END TRY
        BEGIN CATCH
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_MERGE_AGENTS','ERROR_HANDLED',1,0,N'Lesesicht auf lokale Distribution-Datenbank',ERROR_NUMBER(),ERROR_MESSAGE(),
                   N'Merge-Agent- oder Sessionevidenz fehlt.');
        END CATCH;

        BEGIN TRY
            SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DistributionDatabase)+N';
IF NOT EXISTS(SELECT 1 FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N''dbo'' AND [t].[name]=N''MSrepl_errors'')
    ;THROW 54023,N''Lokale Replikationsfehlertabelle fehlt.'',1;
INSERT [#DataCaptureDeepAnalysis_ReplicationErrorGroup]
([DistributionDatabase],[ErrorCode],[ErrorCount],[FirstErrorTimeUtc],[LastErrorTimeUtc],[EvidenceLimit])
SELECT @pDistributionDatabase,[error_code],COUNT_BIG(*),MIN([time]),MAX([time]),
       N''Replikationsfehler werden nur nach Code und Zeit aggregiert; Quellname, Fehlertext, Command und Sequenznummern bleiben ausgeschlossen.''
FROM [dbo].[MSrepl_errors] WITH (NOLOCK)
WHERE [time]>=DATEADD(HOUR,-@pLookback,@pNow)
GROUP BY [error_code];
SET @pRows=@@ROWCOUNT;';
            SET @Rows=0;
            EXEC [sys].[sp_executesql] @Sql,N'@pDistributionDatabase sysname,@pLookback int,@pNow datetime2(3),@pRows bigint OUTPUT',
                 @pDistributionDatabase=@DistributionDatabase,@pLookback=@ErrorLookbackHours,@pNow=@Now,@pRows=@Rows OUTPUT;
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_ERRORS','AVAILABLE',0,@Rows,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,
                   N'Nur Fehlercode, Anzahl und Zeitgrenzen werden ausgegeben.');
        END TRY
        BEGIN CATCH
            INSERT [#DataCaptureDeepAnalysis_SourceStatus]
            VALUES(NULL,'REPLICATION_ERRORS','ERROR_HANDLED',1,0,N'Lesesicht auf lokale Distribution-Datenbank',ERROR_NUMBER(),ERROR_MESSAGE(),
                   N'Aggregierte lokale Replikationsfehlerevidenz fehlt.');
        END CATCH;

            FETCH NEXT FROM [DistributionDatabaseCursor] INTO @DistributionDatabase;
        END;

        CLOSE [DistributionDatabaseCursor];
        DEALLOCATE [DistributionDatabaseCursor];
    END
    ELSE
    BEGIN
        INSERT [#DataCaptureDeepAnalysis_SourceStatus]
        VALUES
        (NULL,'REPLICATION_DISTRIBUTION_AGENTS','NOT_APPLICABLE',0,0,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,N'Lokale Distribution nicht aufgerufen oder nicht sichtbar; Discovery- und Policy-Status beachten.'),
        (NULL,'REPLICATION_LOG_READER_AGENTS','NOT_APPLICABLE',0,0,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,N'Lokale Distribution nicht aufgerufen oder nicht sichtbar; Discovery- und Policy-Status beachten.'),
        (NULL,'REPLICATION_MERGE_AGENTS','NOT_APPLICABLE',0,0,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,N'Lokale Distribution nicht aufgerufen oder nicht sichtbar; Discovery- und Policy-Status beachten.'),
        (NULL,'REPLICATION_ERRORS','NOT_APPLICABLE',0,0,N'Lesesicht auf lokale Distribution-Datenbank',NULL,NULL,N'Lokale Distribution nicht aufgerufen oder nicht sichtbar; Discovery- und Policy-Status beachten.');
    END;

    UPDATE [ds]
    SET [IsChangeTrackingEnabled]=[fs].[IsChangeTrackingEnabled],
        [CtTableCount]=[fs].[CtTableCount],
        [IsCdcEnabled]=[fs].[IsCdcEnabled],
        [CdcCaptureInstanceCount]=[fs].[CdcCaptureInstanceCount],
        [HasReplicationRole]=CONVERT(bit,CASE WHEN [fs].[IsPublished]=1 OR [fs].[IsSubscribed]=1
                                                  OR [fs].[IsMergePublished]=1 OR [fs].[IsDistributor]=1
                                             THEN 1 ELSE 0 END)
    FROM [#DataCaptureDeepAnalysis_DatabaseStatus] [ds]
    JOIN [#DataCaptureDeepAnalysis_FeatureScope] [fs] ON [fs].[DatabaseName]=[ds].[DatabaseName];

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'INFO','HIGH','CT_CLIENT_WATERMARK_NOT_SUPPLIED','CLIENT_VERSION',
           N'Change Tracking ist sichtbar, aber es wurde kein Client-Wasserstand geliefert; ein Synchronisationsverlust kann daher nicht bewertet werden.',
           N'MinValidVersion allein belegt keinen betroffenen Client. Verschiedene Consumer koennen unterschiedliche Wasserstaende besitzen.',
           N'Pro Consumer dessen zuletzt erfolgreich bestaetigte Synchronisationsversion kontrolliert als @ChangeTrackingClientVersion pruefen.'
    FROM [#DataCaptureDeepAnalysis_FeatureScope]
    WHERE [IsChangeTrackingEnabled]=1 AND @ChangeTrackingClientVersion IS NULL;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','HIGH','CT_CLIENT_REINITIALIZATION_REQUIRED','CLIENT_VERSION',
           [ClientVersion],[MinValidVersion],
           N'Der gelieferte Client-Wasserstand liegt unter der minimal gueltigen Version dieser Change-Tracking-Tabelle.',
           [EvidenceLimit],N'Consumer fuer diese Tabelle kontrolliert reinitialisieren; keine inkrementelle Enumeration ab dem ungueltigen Wasserstand fortsetzen.'
    FROM [#DataCaptureDeepAnalysis_ChangeTrackingTable]
    WHERE [ClientVersion] IS NOT NULL AND [MinValidVersion] IS NOT NULL AND [ClientVersion]<[MinValidVersion];

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','HIGH','CT_CLIENT_VERSION_IN_FUTURE','CLIENT_VERSION',
           [ClientVersion],[CurrentVersion],N'Der gelieferte Client-Wasserstand liegt ueber der aktuellen Datenbankversion.',
           [EvidenceLimit],N'Consumer-Zustand, Datenbankzuordnung und Persistenz des Wasserstands korrigieren, bevor synchronisiert wird.'
    FROM [#DataCaptureDeepAnalysis_ChangeTrackingTable]
    WHERE [ClientVersion] IS NOT NULL AND [CurrentVersion] IS NOT NULL AND [ClientVersion]>[CurrentVersion];

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'INFO','HIGH','CT_AUTO_CLEANUP_DISABLED','AUTO_CLEANUP_ON',0,1,
           N'Change-Tracking-Auto-Cleanup ist deaktiviert.',
           N'Dies kann absichtliche Konfiguration sein und ist ohne Speicher- und Betriebsziel kein Fehler.',
           N'Retention-, Speicher- und Consumer-Anforderungen pruefen; keine automatische Konfigurationsaenderung ausfuehren.'
    FROM [#DataCaptureDeepAnalysis_FeatureScope]
    WHERE [IsChangeTrackingEnabled]=1 AND [IsCtAutoCleanupOn]=0;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SourceSchema],COALESCE([SourceTable],[CaptureInstance]),'WARN','HIGH','CDC_CAPTURE_INSTANCE_DROP_PENDING','HAS_DROP_PENDING',1,0,
           N'Die CDC-Capture-Instanz ist als drop-pending markiert.',[EvidenceLimit],
           N'CDC-DDL-Historie, lang laufende Capture-/Cleanup-Aktivitaet und den beabsichtigten Instanzlebenszyklus in der Laufzeitumgebung pruefen.'
    FROM [#DataCaptureDeepAnalysis_CdcCaptureInstance]
    WHERE [HasDropPending]=1;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [fs].[DatabaseName],'WARN','HIGH','CDC_CAPTURE_JOB_MISSING_OR_DISABLED','ENABLED_CAPTURE_JOB_COUNT',
           COALESCE([j].[EnabledCount],0),1,N'CDC ist mit sichtbarer Capture-Instanz aktiviert, aber kein aktivierter Capture-Job ist sichtbar.',
           N'Bei alternativer Plattform- oder Hochverfuegbarkeitssteuerung kann die Jobinterpretation abweichen; fehlende Rechte koennen Sichtbarkeit begrenzen.',
           N'CDC-Betriebsmodus und Agentjob in der Laufzeitumgebung pruefen; keine automatische Jobaenderung ausfuehren.'
    FROM [#DataCaptureDeepAnalysis_FeatureScope] [fs]
    OUTER APPLY
    (
        SELECT SUM(CASE WHEN [IsEnabled]=1 THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END) AS [EnabledCount]
        FROM [#DataCaptureDeepAnalysis_CdcJob] WHERE [DatabaseName]=[fs].[DatabaseName] AND [JobType]=N'capture'
    ) [j]
    WHERE [fs].[IsCdcEnabled]=1 AND [fs].[CdcCaptureInstanceCount]>0 AND COALESCE([j].[EnabledCount],0)=0
      AND EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_SourceStatus] WHERE [DatabaseName]=[fs].[DatabaseName] AND [SourceCode]='CDC_JOBS' AND [StatusCode]='AVAILABLE');

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [fs].[DatabaseName],'WARN','HIGH','CDC_CLEANUP_JOB_MISSING_OR_DISABLED','ENABLED_CLEANUP_JOB_COUNT',
           COALESCE([j].[EnabledCount],0),1,N'CDC ist mit sichtbarer Capture-Instanz aktiviert, aber kein aktivierter Cleanup-Job ist sichtbar.',
           N'Alternative Plattformsteuerung und eingeschraenkte msdb-Sichtbarkeit koennen die Jobinterpretation begrenzen.',
           N'Cleanup-Betriebsmodus und Retention in der Laufzeitumgebung pruefen; keine automatische Bereinigung starten.'
    FROM [#DataCaptureDeepAnalysis_FeatureScope] [fs]
    OUTER APPLY
    (
        SELECT SUM(CASE WHEN [IsEnabled]=1 THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END) AS [EnabledCount]
        FROM [#DataCaptureDeepAnalysis_CdcJob] WHERE [DatabaseName]=[fs].[DatabaseName] AND [JobType]=N'cleanup'
    ) [j]
    WHERE [fs].[IsCdcEnabled]=1 AND [fs].[CdcCaptureInstanceCount]>0 AND COALESCE([j].[EnabledCount],0)=0
      AND EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_SourceStatus] WHERE [DatabaseName]=[fs].[DatabaseName] AND [SourceCode]='CDC_JOBS' AND [StatusCode]='AVAILABLE');

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [s].[DatabaseName],CASE WHEN COALESCE([j].[IsContinuous],1)=1 THEN 'WARN' ELSE 'INFO' END,
           CASE WHEN COALESCE([j].[IsContinuous],1)=1 THEN 'MEDIUM' ELSE 'LOW' END,
           CASE WHEN COALESCE([j].[IsContinuous],1)=1 THEN 'CDC_CAPTURE_LATENCY_HIGH' ELSE 'CDC_SCHEDULED_CAPTURE_LATENCY_CONTEXT' END,
           'LATENCY_SECONDS',[s].[LatencySeconds],@CdcLatencyWarnSeconds,
           N'Die aggregierte CDC-Scan-Latenz ueberschreitet den konfigurierten Grenzwert.',[s].[EvidenceLimit],
           N'Wiederholt messen und Capture-Modus, Polling, Logaktivitaet, Agentstatus sowie Ressourcen korrelieren.'
    FROM [#DataCaptureDeepAnalysis_CdcScanSession] [s]
    OUTER APPLY
    (
        SELECT TOP(1) [IsContinuous] FROM [#DataCaptureDeepAnalysis_CdcJob]
        WHERE [DatabaseName]=[s].[DatabaseName] AND [JobType]=N'capture'
    ) [j]
    WHERE [s].[SessionId]=0 AND [s].[LatencySeconds]>=@CdcLatencyWarnSeconds;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','MEDIUM','CDC_SCAN_FAILURES_VISIBLE','FAILED_SESSION_COUNT',
           [FailedSessionsCount],0,N'Die aggregierte CDC-Scan-DMV meldet fehlgeschlagene Sitzungen.',[EvidenceLimit],
           N'Neueste CDC-Fehlergruppe, Agentjobausgang und freigegebene Laufzeitlogs korrelieren; DMV-Resetgrenze beachten.'
    FROM [#DataCaptureDeepAnalysis_CdcScanSession]
    WHERE [SessionId]=0 AND COALESCE([FailedSessionsCount],0)>0;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','CDC_ERRORS_IN_LOOKBACK','ERROR_COUNT',SUM([ErrorCount]),0,
           N'Die CDC-Fehler-DMV enthaelt Fehler im konfigurierten Rueckblick.',MIN([EvidenceLimit]),
           N'Fehlernummern und Phasen mit Agentstatus und geschuetzten Laufzeitlogs korrelieren; keine Fehlermeldung in Repositoryartefakte kopieren.'
    FROM [#DataCaptureDeepAnalysis_CdcErrorGroup]
    GROUP BY [DatabaseName];

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SourceSchema],COALESCE([SourceTable],[CaptureInstance]),'WARN','LOW','CDC_OLDEST_AVAILABLE_EXCEEDS_RETENTION','OLDEST_AVAILABLE_AGE_MINUTES',
           [OldestAvailableAgeMinutes],[CleanupRetentionMinutes]+@CdcCleanupGraceMinutes,
           N'Die aelteste verfuegbare CDC-Zeitgrenze liegt jenseits von Retention plus Toleranz.',[EvidenceLimit],
           N'Cleanup-Jobverlauf, Logaktivitaet und wiederholte LSN-Zeitgrenzen pruefen; keine automatische Loeschung ausfuehren.'
    FROM [#DataCaptureDeepAnalysis_CdcCaptureInstance]
    WHERE [CleanupRetentionMinutes] IS NOT NULL AND [OldestAvailableAgeMinutes]>[CleanupRetentionMinutes]+@CdcCleanupGraceMinutes;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','REPLICATION_TOPOLOGY_NOT_LOCALLY_OBSERVABLE','LOCAL_DISTRIBUTOR_VISIBLE',0,1,
           N'Die Datenbank besitzt eine sichtbare Replikationsrolle, aber keine lokale Distribution-Datenbank ist erreichbar.',
           N'Ein Remote Distributor oder fehlende Rechte verhindern lokale Agent-, Rueckstands- und Fehleraussagen; dies ist kein Gesundheitsnachweis.',
           N'Diagnose am Distributor mit freigegebenem Zugriff ausfuehren und die Evidenz ausschliesslich in der Laufzeitumgebung korrelieren.'
    FROM [#DataCaptureDeepAnalysis_FeatureScope]
    WHERE ([IsPublished]=1 OR [IsSubscribed]=1 OR [IsMergePublished]=1 OR [IsDistributor]=1)
      AND NOT EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_DistributionDatabase]);

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [PublisherDatabase],[PublicationName],'WARN','HIGH','REPLICATION_PENDING_COMMANDS_HIGH','PENDING_COMMAND_COUNT',
           [PendingCommandCount],@ReplicationPendingCommandWarn,
           N'Der lokale Distributor meldet einen Rueckstand oberhalb des konfigurierten Grenzwerts.',[EvidenceLimit],
           N'Rueckstand und Delivery-Rate wiederholt messen sowie Agentstatus, Subscriber-Erreichbarkeit und Ressourcen korrelieren.'
    FROM [#DataCaptureDeepAnalysis_ReplicationAgent]
    WHERE [AgentType]='DISTRIBUTION' AND [PendingCommandCount]>=@ReplicationPendingCommandWarn;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [PublisherDatabase],[PublicationName],'WARN','MEDIUM','REPLICATION_AGENT_FAILED_OR_RETRYING','RUN_STATUS',
           [RunStatus],4,N'Der neueste lokale Agent-Historienstatus ist Retry oder Fail.',[EvidenceLimit],
           N'Neueste Fehlercodes, Jobausgang und geschuetzte Laufzeitlogs korrelieren; ein einzelner Status beweist keine dauerhafte Stoerung.'
    FROM [#DataCaptureDeepAnalysis_ReplicationAgent]
    WHERE [RunStatus] IN(5,6);

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [PublisherDatabase],[PublicationName],'WARN','MEDIUM','REPLICATION_DELIVERY_LATENCY_HIGH','DELIVERY_LATENCY_SECONDS',
           CONVERT(decimal(38,4),[DeliveryLatencyMs])/1000.0,@ReplicationLatencyWarnSeconds,
           N'Die lokale Agenthistorie meldet eine Delivery-Latenz oberhalb des konfigurierten Grenzwerts.',[EvidenceLimit],
           N'Mehrere Messpunkte und den passenden Agenttyp mit Rueckstand, Delivery-Rate, Netzwerk und Subscriber-Ressourcen korrelieren.'
    FROM [#DataCaptureDeepAnalysis_ReplicationAgent]
    WHERE CONVERT(decimal(38,4),[DeliveryLatencyMs])/1000.0>=@ReplicationLatencyWarnSeconds;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [PublisherDatabase],[PublicationName],'WARN','MEDIUM','REPLICATION_INACTIVE_SUBSCRIPTION_REVIEW','INACTIVE_SUBSCRIPTION_COUNT',
           [InactiveSubscriptionCount],0,
           N'Mindestens eine lokale Subscription-Zeile des Distribution Agents ist nicht aktiv.',[EvidenceLimit],
           N'Initialisierung, Subscription-Status und Agentfehler pruefen; dieser Indikator allein beweist keine erforderliche Reinitialisierung.'
    FROM [#DataCaptureDeepAnalysis_ReplicationAgent]
    WHERE COALESCE([InactiveSubscriptionCount],0)>0;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [PublisherDatabase],[PublicationName],'WARN','LOW','REPLICATION_AGENT_STALE_WITH_BACKLOG','LAST_HISTORY_AGE_MINUTES',
           [LastHistoryAgeMinutes],@ReplicationAgentStaleWarnMinutes,
           N'Die letzte Agenthistorie ist alt und zugleich ist ein lokaler Rueckstand sichtbar.',[EvidenceLimit],
           N'Agentjob und neue Historienzeilen pruefen. Idle oder seltene Zeitplaene ohne Rueckstand sind ausdruecklich kein Fehler.'
    FROM [#DataCaptureDeepAnalysis_ReplicationAgent]
    WHERE [AgentType]='DISTRIBUTION' AND [LastHistoryAgeMinutes]>=@ReplicationAgentStaleWarnMinutes
      AND COALESCE([PendingCommandCount],0)>0;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [PublisherDatabase],[PublicationName],'WARN','MEDIUM','MERGE_CONFLICT_OR_RETRY_VISIBLE','CONFLICT_AND_RETRY_COUNT',
           COALESCE([ConflictCount],0)+COALESCE([RetryCount],0),0,
           N'Die neueste lokale Merge-Session meldet Konflikte oder Retries.',[EvidenceLimit],
           N'Publication-Regeln, Resolver und freigegebene Laufzeitevidenz pruefen; keine Konfliktzeilen in Repositoryartefakte uebernehmen.'
    FROM [#DataCaptureDeepAnalysis_ReplicationAgent]
    WHERE [AgentType]='MERGE' AND COALESCE([ConflictCount],0)+COALESCE([RetryCount],0)>0;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT 'WARN','HIGH','REPLICATION_ERRORS_IN_LOOKBACK','ERROR_COUNT',SUM([ErrorCount]),0,
           N'Die lokale Distribution-Datenbank enthaelt Replikationsfehler im konfigurierten Rueckblick.',MIN([EvidenceLimit]),
           N'Fehlercodes mit Agenten und geschuetzten Laufzeitlogs korrelieren; Fehlertexte oder Commands nicht persistieren.'
    FROM [#DataCaptureDeepAnalysis_ReplicationErrorGroup]
    HAVING SUM([ErrorCount])>0;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','DATA_CAPTURE_EVIDENCE_GAP',[SourceCode],
           COALESCE([ErrorMessage],N'Die angeforderte Quelle ist nicht verfuegbar.'),[Detail],
           N'Berechtigung, Featureverfuegbarkeit und Topologie pruefen; andere Resultsets bleiben gueltig.'
    FROM [#DataCaptureDeepAnalysis_SourceStatus]
    WHERE [IsPartial]=1 AND [DatabaseName] IS NOT NULL;

    INSERT [#DataCaptureDeepAnalysis_Findings]
    ([Severity],[Confidence],[FindingCode],[MetricName],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT 'WARN','HIGH','REPLICATION_EVIDENCE_GAP',[SourceCode],
           COALESCE([ErrorMessage],N'Die lokale Replikationsquelle ist nicht verfuegbar.'),[Detail],
           N'Berechtigung und Distributor-Topologie pruefen; eine Quellenluecke niemals als gesunden Zustand behandeln.'
    FROM [#DataCaptureDeepAnalysis_SourceStatus]
    WHERE [IsPartial]=1 AND [DatabaseName] IS NULL;

    UPDATE [x]
    SET [AssessmentStatus]=CASE WHEN EXISTS
        (SELECT 1 FROM [#DataCaptureDeepAnalysis_Findings] [f]
         WHERE [f].[DatabaseName]=[x].[DatabaseName]
           AND [f].[SchemaName]=[x].[SchemaName]
           AND [f].[ObjectName]=[x].[TableName]
           AND [f].[Severity]='WARN') THEN 'REVIEW' ELSE 'AVAILABLE' END
    FROM [#DataCaptureDeepAnalysis_ChangeTrackingTable] [x];

    UPDATE [x]
    SET [AssessmentStatus]=CASE WHEN EXISTS
        (SELECT 1 FROM [#DataCaptureDeepAnalysis_Findings] [f]
         WHERE [f].[DatabaseName]=[x].[DatabaseName]
           AND ([f].[ObjectName]=[x].[SourceTable] OR [f].[ObjectName]=[x].[CaptureInstance])
           AND [f].[Severity]='WARN') THEN 'REVIEW' ELSE 'AVAILABLE' END
    FROM [#DataCaptureDeepAnalysis_CdcCaptureInstance] [x];

    UPDATE [x]
    SET [AssessmentStatus]=CASE WHEN EXISTS
        (SELECT 1 FROM [#DataCaptureDeepAnalysis_Findings] [f]
         WHERE ([f].[DatabaseName]=[x].[PublisherDatabase] OR [f].[DatabaseName] IS NULL)
           AND ([f].[ObjectName]=[x].[PublicationName] OR [f].[ObjectName] IS NULL)
           AND [f].[Severity]='WARN') THEN 'REVIEW' ELSE 'AVAILABLE' END
    FROM [#DataCaptureDeepAnalysis_ReplicationAgent] [x];

    UPDATE [ds]
    SET [SourceFailureCount]=[x].[FailureCount]+CASE WHEN [ds].[HasReplicationRole]=1 THEN [g].[GlobalFailureCount] ELSE 0 END,
        [IsPartial]=CONVERT(bit,CASE WHEN [x].[FailureCount]+CASE WHEN [ds].[HasReplicationRole]=1 THEN [g].[GlobalFailureCount] ELSE 0 END>0 THEN 1 ELSE 0 END),
        [ErrorNumber]=COALESCE([ds].[ErrorNumber],[x].[ErrorNumber],CASE WHEN [ds].[HasReplicationRole]=1 THEN [g].[ErrorNumber] END),
        [ErrorMessage]=COALESCE([ds].[ErrorMessage],[x].[ErrorMessage],CASE WHEN [ds].[HasReplicationRole]=1 THEN [g].[ErrorMessage] END),
        [FindingCount]=[f].[FindingCount],
        [StatusCode]=CASE WHEN [ds].[StatusCode] IN('UNAVAILABLE_FEATURE','ERROR_HANDLED') THEN [ds].[StatusCode]
                          WHEN COALESCE([ds].[IsChangeTrackingEnabled],0)=0 AND COALESCE([ds].[IsCdcEnabled],0)=0 AND COALESCE([ds].[HasReplicationRole],0)=0 THEN 'NOT_APPLICABLE_VISIBLE_SCOPE'
                          WHEN [x].[FailureCount]+CASE WHEN [ds].[HasReplicationRole]=1 THEN [g].[GlobalFailureCount] ELSE 0 END>0 THEN 'AVAILABLE_LIMITED'
                          WHEN [f].[WarnCount]>0 THEN 'AVAILABLE_WITH_FINDING'
                          ELSE 'AVAILABLE' END,
        [Detail]=CASE WHEN COALESCE([ds].[IsChangeTrackingEnabled],0)=0 AND COALESCE([ds].[IsCdcEnabled],0)=0 AND COALESCE([ds].[HasReplicationRole],0)=0
                          THEN N'Keine der drei Funktionen im sichtbaren Scope erkannt; eingeschraenkte Metadatensichtbarkeit kann Abwesenheit nicht beweisen.'
                      WHEN [x].[FailureCount]+CASE WHEN [ds].[HasReplicationRole]=1 THEN [g].[GlobalFailureCount] ELSE 0 END>0
                          THEN N'Mindestens eine isolierte Quelle fehlt; zugaengliche Teilergebnisse bleiben erhalten.'
                      WHEN [f].[WarnCount]>0
                          THEN N'Mindestens ein Pruefhinweis liegt vor; kein automatisches Gesundheitsurteil.'
                      ELSE N'Kein konfigurierter Warnindikator in der zugaenglichen Momentaufnahme; dies beweist keine fehlerfreie Verarbeitung.' END
    FROM [#DataCaptureDeepAnalysis_DatabaseStatus] [ds]
    OUTER APPLY
    (
        SELECT CONVERT(int,COUNT_BIG(*)) AS [FailureCount],MIN([ss].[ErrorNumber]) AS [ErrorNumber],MIN([ss].[ErrorMessage]) AS [ErrorMessage]
        FROM [#DataCaptureDeepAnalysis_SourceStatus] [ss]
        WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1
    ) [x]
    CROSS APPLY
    (
        SELECT CONVERT(int,COUNT_BIG(*)) AS [GlobalFailureCount],MIN([ss].[ErrorNumber]) AS [ErrorNumber],MIN([ss].[ErrorMessage]) AS [ErrorMessage]
        FROM [#DataCaptureDeepAnalysis_SourceStatus] [ss]
        WHERE [ss].[DatabaseName] IS NULL AND [ss].[IsPartial]=1
    ) [g]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FindingCount],
               COALESCE(SUM(CASE WHEN [ff].[Severity]='WARN' THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),0) AS [WarnCount]
        FROM [#DataCaptureDeepAnalysis_Findings] [ff]
        WHERE [ff].[DatabaseName]=[ds].[DatabaseName]
           OR ([ff].[DatabaseName] IS NULL AND [ds].[HasReplicationRole]=1)
    ) [f];

    IF @StatusCode='AVAILABLE'
    BEGIN
        IF EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_DatabaseStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        ELSE IF EXISTS(SELECT 1 FROM [#DataCaptureDeepAnalysis_Findings] WHERE [Severity]='WARN')
            SET @StatusCode='AVAILABLE_WITH_FINDING';
        ELSE IF NOT EXISTS
            (SELECT 1 FROM [#DataCaptureDeepAnalysis_FeatureScope]
             WHERE [IsChangeTrackingEnabled]=1 OR [IsCdcEnabled]=1 OR [IsPublished]=1
                OR [IsSubscribed]=1 OR [IsMergePublished]=1 OR [IsDistributor]=1)
            SET @StatusCode='NOT_APPLICABLE';
    END;

    SELECT @ErrorNumber=COALESCE(@ErrorNumber,MIN([ErrorNumber])),
           @ErrorMessage=COALESCE(@ErrorMessage,MIN([ErrorMessage]))
    FROM [#DataCaptureDeepAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    IF @JsonErzeugen=1
    BEGIN
        SELECT @Json=(
            SELECT
                JSON_QUERY((SELECT N'USP_DataCaptureDeepAnalysis' AS [module],@Now AS [collectedAtUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@ErrorNumber AS [errorNumber],@ErrorMessage AS [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS [meta],
                JSON_QUERY(COALESCE((SELECT * FROM [#DataCaptureDeepAnalysis_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH),N'[]')) AS [databaseStatus],
                JSON_QUERY(COALESCE((SELECT * FROM [#DataCaptureDeepAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode] FOR JSON PATH),N'[]')) AS [sourceStatus],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal] FOR JSON PATH),N'[]')) AS [findings],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_ChangeTrackingTable] WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW' ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[DatabaseName],[SchemaName],[TableName] FOR JSON PATH),N'[]')) AS [changeTrackingTables],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcCaptureInstance] WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW' ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[DatabaseName],[CaptureInstance] FOR JSON PATH),N'[]')) AS [cdcCaptureInstances],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcScanSession] ORDER BY [DatabaseName],[SessionId] FOR JSON PATH),N'[]')) AS [cdcScanSessions],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcErrorGroup] ORDER BY [LastErrorTimeUtc] DESC,[DatabaseName],[ErrorNumber] FOR JSON PATH),N'[]')) AS [cdcErrors],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcJob] ORDER BY [DatabaseName],[JobType] FOR JSON PATH),N'[]')) AS [cdcJobs],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_ReplicationAgent] WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW' ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[DistributionDatabase],[AgentType],[PublisherDatabase],[PublicationName],[AgentId] FOR JSON PATH),N'[]')) AS [replicationAgents],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_ReplicationErrorGroup] ORDER BY [LastErrorTimeUtc] DESC,[DistributionDatabase],[ErrorCode] FOR JSON PATH),N'[]')) AS [replicationErrors]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
    END;

    IF @OutputMode<>'NONE'
    BEGIN
        SELECT N'USP_DataCaptureDeepAnalysis' AS [Module],@Now AS [CollectedAtUtc],@StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],
               N'Read-only Metadatenaufnahme; keine Change-Zeilen, Replikationsbefehle, Credentials, Agent-Commands oder Aenderungen.' AS [Detail];
        SELECT * FROM [#DataCaptureDeepAnalysis_DatabaseStatus] ORDER BY [DatabaseName];
        SELECT * FROM [#DataCaptureDeepAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_Findings]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_ChangeTrackingTable]
        WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW'
        ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[DatabaseName],[SchemaName],[TableName];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcCaptureInstance]
        WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW'
        ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[DatabaseName],[CaptureInstance];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcScanSession] ORDER BY [DatabaseName],[SessionId];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcErrorGroup] ORDER BY [LastErrorTimeUtc] DESC,[DatabaseName],[ErrorNumber];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_CdcJob] ORDER BY [DatabaseName],[JobType];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_ReplicationAgent]
        WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW'
        ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[DistributionDatabase],[AgentType],[PublisherDatabase],[PublicationName],[AgentId];
        SELECT TOP(@Limit) * FROM [#DataCaptureDeepAnalysis_ReplicationErrorGroup] ORDER BY [LastErrorTimeUtc] DESC,[DistributionDatabase],[ErrorCode];
    END;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=LEFT(CONCAT(N'USP_DataCaptureDeepAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe strukturierte Quellenstatus.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#DataCaptureDeepAnalysis_Findings'
            , @ResultLabel=N'DataCaptureDeepAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#DataCaptureDeepAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
