USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_FullTextAnalysis
Version      : 1.0.0
Stand        : 2026-07-18
Typ          : Stored Procedure
Zweck        : Analysiert sichtbare Full-Text-Kataloge und -Indizes sowie
               aktuelle Populationen, ausstehende Batches, Fragmente,
               semantische Populationen und serverweite Laufzeitkapazitaet.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : SERVERPROPERTY, sys.fulltext_catalogs, sys.fulltext_indexes,
               sys.fulltext_index_columns, sys.fulltext_index_fragments,
               sys.indexes, sys.dm_fts_index_population,
               sys.dm_fts_outstanding_batches,
               sys.dm_fts_semantic_similarity_population,
               sys.dm_fts_memory_pools und sys.dm_fts_fdhosts.
Methodik     : Feature-Gate und jede abhaengige Quelle werden best effort
               ausgewertet. Eine DMV-Momentaufnahme ist keine Historie;
               Grenzwerte erzeugen Pruefhinweise, keine Betriebsentscheidung.
Grenzen      : Keine Tabelleninhalte, Suchbegriffe, Schluesselwerte,
               Stopwords, Parser-Eingaben, Crawl-Logs, Dateipfade oder DDL.
               Eine fehlende aktive Population beweist weder Abschluss noch
               Stillstand; MANUAL/OFF ist zulaessige Konfiguration.
Kosten       : MEDIUM; Kataloge und aggregierte Full-Text-Laufzeitmetadaten.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_FullTextAnalysis]
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
    , @PopulationAgeWarnMinutes         bigint          = 60
    , @QueryableFragmentWarn            bigint          = 30
    , @OutstandingBatchWarn             bigint          = 100
    , @FailedDocumentWarn               bigint          = 1
    , @CatalogSizeWarnMb                decimal(19,2)   = 10240
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
    DECLARE @IsFullTextInstalled bit=COALESCE(TRY_CONVERT(bit,SERVERPROPERTY(N'IsFullTextInstalled')),0);
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
        PRINT N'monitor.USP_FullTextAnalysis';
        PRINT N'Die Procedure führt eine rein lesende Tiefenanalyse sichtbarer Full-Text-Kataloge, -Indizes und aggregierter Laufzeitmetadaten durch.';
        PRINT N'Geprüft werden Indexschalter, Crawl-Kontext, aktuelle Populationen, Batches, Fragmente und semantische Populationen.';
        PRINT N'Exakte Namenslisten und Pattern beziehen sich auf Tabellenschema und Tabellenname; Pattern: LIKE, regex: oder regexi:.';
        PRINT N'Grenzwerte sind Heuristiken. MANUAL/OFF, eine leere DMV oder ein alter Crawl beweisen für sich keinen Fehler.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson; @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        PRINT N'Es werden keine Tabelleninhalte, Suchbegriffe, Crawl-Logs, Dateipfade, Stopwords oder Schlüsselwerte gelesen; DDL wird nicht ausgeführt.';
        RETURN;
    END;

    IF @SystemdatenbankenEinbeziehen IS NULL OR @NurProblematisch IS NULL
       OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @PopulationAgeWarnMinutes IS NULL OR @PopulationAgeWarnMinutes<0
       OR @QueryableFragmentWarn IS NULL OR @QueryableFragmentWarn<0
       OR @OutstandingBatchWarn IS NULL OR @OutstandingBatchWarn<0
       OR @FailedDocumentWarn IS NULL OR @FailedDocumentWarn<0
       OR @CatalogSizeWarnMb IS NULL OR @CatalogSizeWarnMb<0

       OR @MaxZeilen IS NULL OR @MaxZeilen<0
       OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
       OR @OutputMode NOT IN('CONSOLE','RAW','NONE')
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungueltiger Bit-, Grenzwert-, Mengen-, Lock-Timeout- oder Ausgabeparameter.';
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

    CREATE TABLE [#FullTextAnalysis_NameFilters]
    (
          [FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [ItemOrdinal] int NOT NULL
        , [NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
    );
    CREATE TABLE [#FullTextAnalysis_DatabaseCandidates]
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
    CREATE TABLE [#FullTextAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#FullTextAnalysis_FeatureScope]
    (
          [DatabaseName] sysname NOT NULL PRIMARY KEY
        , [IsFullTextInstalled] bit NOT NULL
        , [CatalogCount] bigint NOT NULL
        , [FullTextIndexCount] bigint NOT NULL
        , [SemanticColumnCount] bigint NOT NULL
    );
    CREATE TABLE [#FullTextAnalysis_DatabaseStatus]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [IsFullTextInstalled] bit NULL
        , [CatalogCount] bigint NOT NULL
        , [FullTextIndexCount] bigint NOT NULL
        , [ActivePopulationCount] bigint NOT NULL
        , [OutstandingBatchCount] bigint NOT NULL
        , [FindingCount] bigint NOT NULL
        , [SourceFailureCount] int NOT NULL
        , [RequiredPermission] nvarchar(256) NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#FullTextAnalysis_SourceStatus]
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
    CREATE TABLE [#FullTextAnalysis_Catalog]
    (
          [DatabaseName] sysname NOT NULL
        , [FullTextCatalogId] int NOT NULL
        , [CatalogName] sysname NOT NULL
        , [IsDefault] bit NOT NULL
        , [IsAccentSensitivityOn] bit NOT NULL
        , [IndexCount] bigint NOT NULL
        , [EnabledIndexCount] bigint NOT NULL
        , [QueryableFragmentCount] bigint NULL
        , [LogicalSizeMb] decimal(19,2) NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY ([DatabaseName],[FullTextCatalogId])
    );
    CREATE TABLE [#FullTextAnalysis_FullTextIndex]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [TableName] sysname NOT NULL
        , [TableObjectId] int NOT NULL
        , [CatalogId] int NOT NULL
        , [CatalogName] sysname NOT NULL
        , [UniqueIndexId] int NOT NULL
        , [IsEnabled] bit NOT NULL
        , [IsKeyIndexDisabled] bit NOT NULL
        , [ChangeTrackingState] char(1) NULL
        , [ChangeTrackingStateDesc] nvarchar(60) NULL
        , [HasCrawlCompleted] bit NOT NULL
        , [CrawlType] char(1) NULL
        , [CrawlTypeDesc] nvarchar(60) NULL
        , [CrawlStartDate] datetime NULL
        , [CrawlEndDate] datetime NULL
        , [IndexedColumnCount] bigint NOT NULL
        , [SemanticColumnCount] bigint NOT NULL
        , [QueryableFragmentCount] bigint NULL
        , [LogicalFragmentSizeMb] decimal(19,2) NULL
        , [FragmentRowCount] bigint NULL
        , [ActivePopulationCount] bigint NOT NULL
        , [OldestPopulationStartTime] datetime NULL
        , [OutstandingBatchCount] bigint NOT NULL
        , [FailedDocumentCount] bigint NOT NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY ([DatabaseName],[TableObjectId])
    );
    CREATE TABLE [#FullTextAnalysis_Population]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [TableName] sysname NOT NULL
        , [TableObjectId] int NOT NULL
        , [CatalogId] int NOT NULL
        , [PopulationType] int NULL
        , [PopulationTypeDescription] nvarchar(120) NULL
        , [Status] int NULL
        , [StatusDescription] nvarchar(120) NULL
        , [CompletionType] int NULL
        , [CompletionTypeDescription] nvarchar(120) NULL
        , [IsClusteredIndexScan] bit NULL
        , [RangeCount] int NULL
        , [CompletedRangeCount] int NULL
        , [OutstandingBatchCount] int NULL
        , [QueuedPopulationTypeDescription] nvarchar(120) NULL
        , [StartTime] datetime NULL
        , [AgeMinutes] bigint NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#FullTextAnalysis_BatchGroup]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [TableName] sysname NOT NULL
        , [TableObjectId] int NOT NULL
        , [CatalogId] int NOT NULL
        , [BatchErrorCode] int NULL
        , [IsRetryBatch] bit NOT NULL
        , [RetryHintsDescription] nvarchar(120) NULL
        , [BatchCount] bigint NOT NULL
        , [FailedDocumentCount] bigint NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#FullTextAnalysis_SemanticPopulation]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [TableName] sysname NOT NULL
        , [TableObjectId] int NOT NULL
        , [CatalogId] int NOT NULL
        , [DocumentCount] bigint NULL
        , [DocumentProcessedCount] bigint NULL
        , [CompletionType] int NULL
        , [CompletionTypeDescription] nvarchar(120) NULL
        , [Status] int NULL
        , [StatusDescription] nvarchar(120) NULL
        , [WorkerCount] int NULL
        , [StartTime] datetime NULL
        , [AgeMinutes] bigint NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#FullTextAnalysis_MemoryPool]
    (
          [PoolId] int NOT NULL
        , [BufferSizeBytes] bigint NULL
        , [MinBufferLimit] bigint NULL
        , [MaxBufferLimit] bigint NULL
        , [BufferCount] bigint NULL
        , [AllocatedMb] decimal(19,2) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#FullTextAnalysis_FdHost]
    (
          [FdHostType] nvarchar(120) NULL
        , [HostCount] bigint NOT NULL
        , [MaxThreadCount] bigint NULL
        , [BatchCount] bigint NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#FullTextAnalysis_Findings]
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
            , @ErrorMessage=@ErrorMessage OUTPUT,@FilterTable=N'#FullTextAnalysis_NameFilters';
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
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#FullTextAnalysis_DatabaseCandidates',@WarningTable=N'#FullTextAnalysis_DatabaseCandidateWarnings';
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    INSERT [#FullTextAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[IsFullTextInstalled],[CatalogCount],[FullTextIndexCount],
     [ActivePopulationCount],[OutstandingBatchCount],[FindingCount],[SourceFailureCount],[Detail])
    SELECT [DatabaseName],'PENDING',0,NULL,0,0,0,0,0,0,
           N'Feature-Gate und Full-Text-Quellen werden datenbankweise best effort ausgewertet.'
    FROM [#FullTextAnalysis_DatabaseCandidates];

    INSERT [#FullTextAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[IsFullTextInstalled],[CatalogCount],[FullTextIndexCount],
     [ActivePopulationCount],[OutstandingBatchCount],[FindingCount],[SourceFailureCount],[ErrorMessage],[Detail])
    SELECT [RequestedName],[StatusCode],1,NULL,0,0,0,0,0,1,[ErrorMessage],N'Explizit angeforderte Datenbank nicht auswertbar.'
    FROM [#FullTextAnalysis_DatabaseCandidateWarnings];

    IF @StatusCode='AVAILABLE' AND NOT EXISTS(SELECT 1 FROM [#FullTextAnalysis_DatabaseCandidates])
    BEGIN
        SELECT @StatusCode='NOT_APPLICABLE',@ErrorMessage=N'Keine auswertbare Datenbank im gewaehlten Scope.';
    END;

    DECLARE @SchemaPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#FullTextAnalysis_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#FullTextAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @ObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#FullTextAnalysis_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#FullTextAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @FullObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#FullTextAnalysis_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#FullTextAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDatabaseName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
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
            FROM [#FullTextAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;

        WHILE @@FETCH_STATUS=0
        BEGIN
            IF (@SchemaPatternMode IN('REGEX','REGEXI') OR @ObjectPatternMode IN('REGEX','REGEXI'))
               AND COALESCE(@CompatibilityLevel,0)<170
            BEGIN
                UPDATE [#FullTextAnalysis_DatabaseStatus]
                SET [StatusCode]='UNAVAILABLE_FEATURE',[IsPartial]=1,[SourceFailureCount]=1,
                    [ErrorMessage]=N'Regex-Pattern benoetigen Compatibility Level 170.',
                    [Detail]=N'Fuer diese Datenbank wurde wegen inkompatiblem Patternvertrag keine Analyse ausgefuehrt.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#FullTextAnalysis_SourceStatus]
                VALUES(@DbName,'FILTER_CONTRACT','UNAVAILABLE_FEATURE',1,0,NULL,NULL,
                       N'Regex-Pattern benoetigen Compatibility Level 170.',N'Keine Quellenabfrage ausgefuehrt.');
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#FullTextAnalysis_FeatureScope]([DatabaseName],[IsFullTextInstalled],[CatalogCount],[FullTextIndexCount],[SemanticColumnCount])
SELECT @pDatabaseName,@pIsFullTextInstalled,[c].[CatalogCount],[i].[IndexCount],[sc].[SemanticColumnCount]
FROM (SELECT COUNT_BIG(*) AS [CatalogCount] FROM [sys].[fulltext_catalogs] WITH (NOLOCK)) [c]
CROSS JOIN (SELECT COUNT_BIG(*) AS [IndexCount] FROM [sys].[fulltext_indexes] WITH (NOLOCK)) [i]
CROSS JOIN
(
    SELECT COUNT_BIG(*) AS [SemanticColumnCount]
    FROM [sys].[fulltext_index_columns] WITH (NOLOCK)
    WHERE [statistical_semantics]=1
) [sc];
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,
                     N'@pDatabaseName sysname,@pIsFullTextInstalled bit,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pIsFullTextInstalled=@IsFullTextInstalled,@pRows=@Rows OUTPUT;
                INSERT [#FullTextAnalysis_SourceStatus]
                VALUES(@DbName,'FULLTEXT_FEATURE_GATE','AVAILABLE',0,@Rows,
                       N'Katalogsicht; SERVERPROPERTY(IsFullTextInstalled)',NULL,NULL,
                       N'Zaehlt nur sichtbare Katalog-, Index- und Semantikmetadaten; Nullzaehlungen beweisen bei eingeschraenkter Metadatensichtbarkeit keine Abwesenheit.');
                UPDATE [ds]
                SET [IsFullTextInstalled]=[fs].[IsFullTextInstalled],
                    [CatalogCount]=[fs].[CatalogCount],
                    [FullTextIndexCount]=[fs].[FullTextIndexCount]
                FROM [#FullTextAnalysis_DatabaseStatus] [ds]
                JOIN [#FullTextAnalysis_FeatureScope] [fs] ON [fs].[DatabaseName]=[ds].[DatabaseName]
                WHERE [ds].[DatabaseName]=@DbName;
            END TRY
            BEGIN CATCH
                INSERT [#FullTextAnalysis_SourceStatus]
                VALUES(@DbName,'FULLTEXT_FEATURE_GATE','ERROR_HANDLED',1,0,
                       N'Katalogsicht; SERVERPROPERTY(IsFullTextInstalled)',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Feature-Sichtbarkeit konnte nicht bestimmt werden.');
                UPDATE [#FullTextAnalysis_DatabaseStatus]
                SET [StatusCode]='ERROR_HANDLED',[IsPartial]=1,[SourceFailureCount]=[SourceFailureCount]+1,
                    [ErrorNumber]=ERROR_NUMBER(),[ErrorMessage]=ERROR_MESSAGE(),
                    [Detail]=N'Feature-Gate fehlgeschlagen; keine belastbare Anwendbarkeitsaussage.'
                WHERE [DatabaseName]=@DbName;
            END CATCH;

            IF NOT EXISTS(SELECT 1 FROM [#FullTextAnalysis_FeatureScope] WHERE [DatabaseName]=@DbName)
            BEGIN
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            IF EXISTS
            (
                SELECT 1 FROM [#FullTextAnalysis_FeatureScope]
                WHERE [DatabaseName]=@DbName AND [CatalogCount]=0 AND [FullTextIndexCount]=0
            )
            BEGIN
                UPDATE [#FullTextAnalysis_DatabaseStatus]
                SET [StatusCode]='NOT_APPLICABLE_VISIBLE_SCOPE',[IsPartial]=0,
                    [Detail]=N'Im sichtbaren Katalogscope wurden keine Full-Text-Kataloge oder -Indizes erkannt; dies beweist bei eingeschraenkter Metadatensichtbarkeit keine vollstaendige Abwesenheit.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#FullTextAnalysis_SourceStatus]
                SELECT @DbName,[SourceCode],'NOT_APPLICABLE',0,0,[RequiredPermission],NULL,NULL,
                       N'Quelle wegen negativem sichtbaren Feature-Gate nicht aufgerufen.'
                FROM (VALUES
                      ('FULLTEXT_CATALOG_INDEX',N'Katalogsicht auf sichtbare Full-Text-Kataloge und -Indizes'),
                      ('FULLTEXT_FRAGMENTS',N'Katalogsicht auf sys.fulltext_index_fragments'),
                      ('FULLTEXT_POPULATION',N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE'),
                      ('FULLTEXT_BATCHES',N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE'),
                      ('FULLTEXT_SEMANTIC_POPULATION',N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE'))
                     [x]([SourceCode],[RequiredPermission]);
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#FullTextAnalysis_Catalog]
([DatabaseName],[FullTextCatalogId],[CatalogName],[IsDefault],[IsAccentSensitivityOn],
 [IndexCount],[EnabledIndexCount],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[c].[fulltext_catalog_id],[c].[name],[c].[is_default],[c].[is_accent_sensitivity_on],
       COUNT_BIG([fi].[object_id]),COALESCE(SUM(CONVERT(bigint,[fi].[is_enabled])),0),''AVAILABLE'',
       N''Katalogmetadaten enthalten keine Crawl-Historie; eine Nullzaehlung kann auch aus eingeschraenkter Metadatensichtbarkeit folgen.''
FROM [sys].[fulltext_catalogs] [c] WITH (NOLOCK)
LEFT JOIN [sys].[fulltext_indexes] [fi] WITH (NOLOCK) ON [fi].[fulltext_catalog_id]=[c].[fulltext_catalog_id]
GROUP BY [c].[fulltext_catalog_id],[c].[name],[c].[is_default],[c].[is_accent_sensitivity_on];

INSERT [#FullTextAnalysis_FullTextIndex]
([DatabaseName],[SchemaName],[TableName],[TableObjectId],[CatalogId],[CatalogName],
 [UniqueIndexId],[IsEnabled],[IsKeyIndexDisabled],[ChangeTrackingState],[ChangeTrackingStateDesc],
 [HasCrawlCompleted],[CrawlType],[CrawlTypeDesc],[CrawlStartDate],[CrawlEndDate],
 [IndexedColumnCount],[SemanticColumnCount],[ActivePopulationCount],[OutstandingBatchCount],
 [FailedDocumentCount],[AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[s].[name],[t].[name],[t].[object_id],[fi].[fulltext_catalog_id],[c].[name],
       [fi].[unique_index_id],[fi].[is_enabled],CONVERT(bit,COALESCE([ki].[is_disabled],0)),
       [fi].[change_tracking_state],[fi].[change_tracking_state_desc],[fi].[has_crawl_completed],
       [fi].[crawl_type],[fi].[crawl_type_desc],[fi].[crawl_start_date],[fi].[crawl_end_date],
       COALESCE([fc].[IndexedColumnCount],0),COALESCE([fc].[SemanticColumnCount],0),0,0,0,''AVAILABLE'',
       N''Index- und Crawl-Metadaten sind Konfiguration beziehungsweise letzter sichtbarer Katalogzustand; sie beweisen keine Suchvollstaendigkeit oder Fehlerursache.''
FROM [sys].[fulltext_indexes] [fi] WITH (NOLOCK)
JOIN [sys].[tables] [t] WITH (NOLOCK) ON [t].[object_id]=[fi].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
JOIN [sys].[fulltext_catalogs] [c] WITH (NOLOCK) ON [c].[fulltext_catalog_id]=[fi].[fulltext_catalog_id]
LEFT JOIN [sys].[indexes] [ki] WITH (NOLOCK)
  ON [ki].[object_id]=[fi].[object_id] AND [ki].[index_id]=[fi].[unique_index_id]
OUTER APPLY
(
    SELECT COUNT_BIG(*) AS [IndexedColumnCount],
           COALESCE(SUM(CONVERT(bigint,[x].[statistical_semantics])),0) AS [SemanticColumnCount]
    FROM [sys].[fulltext_index_columns] [x] WITH (NOLOCK)
    WHERE [x].[object_id]=[fi].[object_id]
) [fc]
WHERE [t].[is_ms_shipped]=0'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N';
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#FullTextAnalysis_SourceStatus]
                VALUES(@DbName,'FULLTEXT_CATALOG_INDEX','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sichtbare Full-Text-Kataloge und -Indizes',NULL,NULL,
                       N'Kataloge werden vollstaendig im sichtbaren Scope, Tabellenindizes unter den Objektfiltern ausgegeben; Inhalte, Schluesselwerte, Stopwords und Pfade bleiben ausgeschlossen.');
            END TRY
            BEGIN CATCH
                DELETE FROM [#FullTextAnalysis_Catalog] WHERE [DatabaseName]=@DbName;
                DELETE FROM [#FullTextAnalysis_FullTextIndex] WHERE [DatabaseName]=@DbName;
                INSERT [#FullTextAnalysis_SourceStatus]
                VALUES(@DbName,'FULLTEXT_CATALOG_INDEX','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sichtbare Full-Text-Kataloge und -Indizes',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Objektabhaengige Full-Text-Quellen werden ausgelassen; serverweite Quellen bleiben unabhaengig.');
            END CATCH;

            IF EXISTS
            (
                SELECT 1 FROM [#FullTextAnalysis_SourceStatus]
                WHERE [DatabaseName]=@DbName AND [SourceCode]='FULLTEXT_CATALOG_INDEX' AND [IsPartial]=1
            )
            BEGIN
                INSERT [#FullTextAnalysis_SourceStatus]
                VALUES
                (@DbName,'FULLTEXT_FRAGMENTS','UNAVAILABLE_DEPENDENCY',1,0,
                 N'Katalogsicht auf sys.fulltext_index_fragments',NULL,N'FULLTEXT_CATALOG_INDEX ist nicht verfuegbar.',
                 N'Keine Fragmentzuordnung ohne belastbare Tabellenzuordnung.'),
                (@DbName,'FULLTEXT_POPULATION','UNAVAILABLE_DEPENDENCY',1,0,
                 N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,N'FULLTEXT_CATALOG_INDEX ist nicht verfuegbar.',
                 N'Keine Populationzuordnung ohne belastbare Tabellenzuordnung.'),
                (@DbName,'FULLTEXT_BATCHES','UNAVAILABLE_DEPENDENCY',1,0,
                 N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,N'FULLTEXT_CATALOG_INDEX ist nicht verfuegbar.',
                 N'Keine Batchzuordnung ohne belastbare Tabellenzuordnung.'),
                (@DbName,'FULLTEXT_SEMANTIC_POPULATION','UNAVAILABLE_DEPENDENCY',1,0,
                 N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,N'FULLTEXT_CATALOG_INDEX ist nicht verfuegbar.',
                 N'Keine semantische Populationzuordnung ohne belastbare Tabellenzuordnung.');
            END
            ELSE
            BEGIN
                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
UPDATE [fi]
SET [QueryableFragmentCount]=[fr].[QueryableFragmentCount],
    [LogicalFragmentSizeMb]=[fr].[LogicalFragmentSizeMb],
    [FragmentRowCount]=[fr].[FragmentRowCount]
FROM [#FullTextAnalysis_FullTextIndex] [fi]
OUTER APPLY
(
    SELECT SUM(CASE WHEN [x].[status] IN(4,6) THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END) AS [QueryableFragmentCount],
           CONVERT(decimal(19,2),SUM(CASE WHEN [x].[status] IN(4,6) THEN CONVERT(decimal(38,2),[x].[data_size]) ELSE 0 END)/1048576.0) AS [LogicalFragmentSizeMb],
           SUM(CASE WHEN [x].[status] IN(4,6) THEN CONVERT(bigint,[x].[row_count]) ELSE CONVERT(bigint,0) END) AS [FragmentRowCount]
    FROM [sys].[fulltext_index_fragments] [x] WITH (NOLOCK)
    WHERE [x].[table_id]=[fi].[TableObjectId]
) [fr]
WHERE [fi].[DatabaseName]=@pDatabaseName;
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    INSERT [#FullTextAnalysis_SourceStatus]
                    VALUES(@DbName,'FULLTEXT_FRAGMENTS','AVAILABLE',0,@Rows,
                           N'Katalogsicht auf sys.fulltext_index_fragments',NULL,NULL,
                           N'Aggregiert werden nur querybare Fragmente mit Status 4 oder 6; viele Fragmente koennen Abfragen belasten, es existiert jedoch kein universeller Grenzwert.');
                END TRY
                BEGIN CATCH
                    INSERT [#FullTextAnalysis_SourceStatus]
                    VALUES(@DbName,'FULLTEXT_FRAGMENTS','ERROR_HANDLED',1,0,
                           N'Katalogsicht auf sys.fulltext_index_fragments',ERROR_NUMBER(),ERROR_MESSAGE(),
                           N'Katalog-, Population- und Batch-Evidenz bleiben verfuegbar.');
                END CATCH;

                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#FullTextAnalysis_Population]
([DatabaseName],[SchemaName],[TableName],[TableObjectId],[CatalogId],[PopulationType],
 [PopulationTypeDescription],[Status],[StatusDescription],[CompletionType],[CompletionTypeDescription],
 [IsClusteredIndexScan],[RangeCount],[CompletedRangeCount],[OutstandingBatchCount],
 [QueuedPopulationTypeDescription],[StartTime],[AgeMinutes],[EvidenceLimit])
SELECT @pDatabaseName,[fi].[SchemaName],[fi].[TableName],[fi].[TableObjectId],[p].[catalog_id],
       [p].[population_type],[p].[population_type_description],[p].[status],[p].[status_description],
       [p].[completion_type],[p].[completion_type_description],[p].[is_clustered_index_scan],
       [p].[range_count],[p].[completed_range_count],[p].[outstanding_batch_count],
       [p].[queued_population_type_description],[p].[start_time],
       DATEDIFF_BIG(MINUTE,[p].[start_time],SYSUTCDATETIME()),
       N''Die DMV zeigt ausschliesslich aktuell laufende Populationen und semantische Extraktionen; Nullzeilen sind weder Abschlussnachweis noch Historie.''
FROM [sys].[dm_fts_index_population] [p] WITH (NOLOCK)
JOIN [#FullTextAnalysis_FullTextIndex] [fi]
  ON [fi].[DatabaseName]=@pDatabaseName AND [fi].[TableObjectId]=[p].[table_id]
WHERE [p].[database_id]=DB_ID();
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    INSERT [#FullTextAnalysis_SourceStatus]
                    VALUES(@DbName,'FULLTEXT_POPULATION','AVAILABLE',0,@Rows,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                           N'Aktuelle Populationen sind eine Momentaufnahme; Status STOPPED kann waehrend eines automatischen Merge vorkommen.');
                END TRY
                BEGIN CATCH
                    INSERT [#FullTextAnalysis_SourceStatus]
                    VALUES(@DbName,'FULLTEXT_POPULATION','ERROR_HANDLED',1,0,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',ERROR_NUMBER(),ERROR_MESSAGE(),
                           N'Katalog-, Fragment- und Batch-Evidenz bleiben verfuegbar.');
                END CATCH;

                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#FullTextAnalysis_BatchGroup]
([DatabaseName],[SchemaName],[TableName],[TableObjectId],[CatalogId],[BatchErrorCode],
 [IsRetryBatch],[RetryHintsDescription],[BatchCount],[FailedDocumentCount],
 [EvidenceLimit])
SELECT @pDatabaseName,[fi].[SchemaName],[fi].[TableName],[fi].[TableObjectId],[b].[catalog_id],
       [b].[hr_batch],CONVERT(bit,[b].[is_retry_batch]),[b].[retry_hints_description],
       COUNT_BIG(*),COALESCE(SUM(CONVERT(bigint,[b].[doc_failed])),0),
       N''Batches sind aktuelle interne Arbeitseinheiten; Fehlercodes und Retry-Metadaten werden aggregiert, Inhalte, Batch-IDs und Speicheradressen bleiben ausgeschlossen.''
FROM [sys].[dm_fts_outstanding_batches] [b] WITH (NOLOCK)
JOIN [#FullTextAnalysis_FullTextIndex] [fi]
  ON [fi].[DatabaseName]=@pDatabaseName AND [fi].[TableObjectId]=[b].[table_id]
WHERE [b].[database_id]=DB_ID()
GROUP BY [fi].[SchemaName],[fi].[TableName],[fi].[TableObjectId],[b].[catalog_id],
         [b].[hr_batch],[b].[is_retry_batch],[b].[retry_hints_description];
SET @pRows=@@ROWCOUNT;';
                    SET @Rows=0;
                    EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                         @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                    INSERT [#FullTextAnalysis_SourceStatus]
                    VALUES(@DbName,'FULLTEXT_BATCHES','AVAILABLE',0,@Rows,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                           N'Aktuelle Batches werden pro Tabelle, Fehlercode und Retryzustand aggregiert; Zeileninhalt und interne Identifikatoren werden nicht ausgegeben.');
                END TRY
                BEGIN CATCH
                    INSERT [#FullTextAnalysis_SourceStatus]
                    VALUES(@DbName,'FULLTEXT_BATCHES','ERROR_HANDLED',1,0,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',ERROR_NUMBER(),ERROR_MESSAGE(),
                           N'Katalog-, Fragment- und Populationsevidenz bleiben verfuegbar.');
                END CATCH;

                IF EXISTS
                (
                    SELECT 1 FROM [#FullTextAnalysis_FeatureScope]
                    WHERE [DatabaseName]=@DbName AND [SemanticColumnCount]>0
                )
                BEGIN
                    BEGIN TRY
                        SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#FullTextAnalysis_SemanticPopulation]
([DatabaseName],[SchemaName],[TableName],[TableObjectId],[CatalogId],[DocumentCount],
 [DocumentProcessedCount],[CompletionType],[CompletionTypeDescription],[Status],[StatusDescription],
 [WorkerCount],[StartTime],[AgeMinutes],[EvidenceLimit])
SELECT @pDatabaseName,[fi].[SchemaName],[fi].[TableName],[fi].[TableObjectId],[p].[catalog_id],
       [p].[document_count],[p].[document_processed_count],[p].[completion_type],
       [p].[completion_type_description],[p].[status],[p].[status_description],
       [p].[worker_count],[p].[start_time],DATEDIFF_BIG(MINUTE,[p].[start_time],SYSUTCDATETIME()),
       N''Die semantische DMV zeigt nur die aktuelle Aehnlichkeitspopulation; sie beweist weder Vollstaendigkeit indizierter Inhalte noch eine Historie.''
FROM [sys].[dm_fts_semantic_similarity_population] [p] WITH (NOLOCK)
JOIN [#FullTextAnalysis_FullTextIndex] [fi]
  ON [fi].[DatabaseName]=@pDatabaseName AND [fi].[TableObjectId]=[p].[table_id]
WHERE [p].[database_id]=DB_ID();
SET @pRows=@@ROWCOUNT;';
                        SET @Rows=0;
                        EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                             @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                        INSERT [#FullTextAnalysis_SourceStatus]
                        VALUES(@DbName,'FULLTEXT_SEMANTIC_POPULATION','AVAILABLE',0,@Rows,
                               N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                               N'Aktuelle semantische Aehnlichkeitspopulation fuer sichtbare Indizes mit STATISTICAL_SEMANTICS.');
                    END TRY
                    BEGIN CATCH
                        INSERT [#FullTextAnalysis_SourceStatus]
                        VALUES(@DbName,'FULLTEXT_SEMANTIC_POPULATION','ERROR_HANDLED',1,0,
                               N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',ERROR_NUMBER(),ERROR_MESSAGE(),
                               N'Katalog- und normale Populationsevidenz bleiben verfuegbar.');
                    END CATCH;
                END
                ELSE
                BEGIN
                    INSERT [#FullTextAnalysis_SourceStatus]
                    VALUES(@DbName,'FULLTEXT_SEMANTIC_POPULATION','NOT_APPLICABLE',0,0,
                           N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                           N'Im sichtbaren Feature-Gate wurden keine Spalten mit STATISTICAL_SEMANTICS erkannt.');
                END;
            END;

            FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
        END;
        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];
    END;

    IF EXISTS
    (
        SELECT 1 FROM [#FullTextAnalysis_FeatureScope]
        WHERE [CatalogCount]>0 OR [FullTextIndexCount]>0
    )
    BEGIN
        BEGIN TRY
            INSERT [#FullTextAnalysis_MemoryPool]
            ([PoolId],[BufferSizeBytes],[MinBufferLimit],[MaxBufferLimit],[BufferCount],[AllocatedMb],[EvidenceLimit])
            SELECT [pool_id],CONVERT(bigint,[buffer_size]),CONVERT(bigint,[min_buffer_limit]),
                   CONVERT(bigint,[max_buffer_limit]),CONVERT(bigint,[buffer_count]),
                   CONVERT(decimal(19,2),CONVERT(decimal(38,2),[buffer_size])*CONVERT(decimal(38,2),[buffer_count])/1048576.0),
                   N'Serverweite Gatherer-Speicherpools sind gemeinsamer Laufzeitkontext; ohne Zeitreihe und Workload existiert kein universelles Gesundheitsurteil.'
            FROM [sys].[dm_fts_memory_pools] WITH (NOLOCK);
            SET @Rows=@@ROWCOUNT;
            INSERT [#FullTextAnalysis_SourceStatus]
            VALUES(NULL,'FULLTEXT_MEMORY_POOLS','AVAILABLE',0,@Rows,
                   N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                   N'Serverweite Poolgroessen und Pufferzaehler; keine Speicheradressen oder Pufferdetails.');
        END TRY
        BEGIN CATCH
            INSERT [#FullTextAnalysis_SourceStatus]
            VALUES(NULL,'FULLTEXT_MEMORY_POOLS','ERROR_HANDLED',1,0,
                   N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',ERROR_NUMBER(),ERROR_MESSAGE(),
                   N'Datenbankbezogene Full-Text-Evidenz bleibt verfuegbar.');
        END CATCH;

        BEGIN TRY
            INSERT [#FullTextAnalysis_FdHost]
            ([FdHostType],[HostCount],[MaxThreadCount],[BatchCount],[EvidenceLimit])
            SELECT [fdhost_type],COUNT_BIG(*),SUM(CONVERT(bigint,[max_thread])),SUM(CONVERT(bigint,[batch_count])),
                   N'Filter-Daemon-Hosts sind eine serverweite Momentaufnahme; Prozess-IDs, Hostnamen und interne Kennungen werden nicht ausgegeben.'
            FROM [sys].[dm_fts_fdhosts] WITH (NOLOCK)
            GROUP BY [fdhost_type];
            SET @Rows=@@ROWCOUNT;
            INSERT [#FullTextAnalysis_SourceStatus]
            VALUES(NULL,'FULLTEXT_FDHOSTS','AVAILABLE',0,@Rows,
                   N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                   N'Nur nach Hosttyp aggregierte Host-, Thread- und Batchanzahlen; keine Prozess-IDs oder Hostnamen.');
        END TRY
        BEGIN CATCH
            INSERT [#FullTextAnalysis_SourceStatus]
            VALUES(NULL,'FULLTEXT_FDHOSTS','ERROR_HANDLED',1,0,
                   N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',ERROR_NUMBER(),ERROR_MESSAGE(),
                   N'Datenbankbezogene Full-Text-Evidenz bleibt verfuegbar.');
        END CATCH;
    END
    ELSE
    BEGIN
        INSERT [#FullTextAnalysis_SourceStatus]
        VALUES
        (NULL,'FULLTEXT_MEMORY_POOLS','NOT_APPLICABLE',0,0,
         N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
         N'Kein sichtbarer Full-Text-Katalog oder -Index im gewaehlten Scope.'),
        (NULL,'FULLTEXT_FDHOSTS','NOT_APPLICABLE',0,0,
         N'SQL Server 2019: VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
         N'Kein sichtbarer Full-Text-Katalog oder -Index im gewaehlten Scope.');
    END;

    UPDATE [fi]
    SET [ActivePopulationCount]=COALESCE([p].[PopulationCount],0),
        [OldestPopulationStartTime]=[p].[OldestStartTime],
        [OutstandingBatchCount]=COALESCE([b].[BatchCount],0),
        [FailedDocumentCount]=COALESCE([b].[FailedDocumentCount],0)
    FROM [#FullTextAnalysis_FullTextIndex] [fi]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [PopulationCount],MIN([StartTime]) AS [OldestStartTime]
        FROM [#FullTextAnalysis_Population] [x]
        WHERE [x].[DatabaseName]=[fi].[DatabaseName] AND [x].[TableObjectId]=[fi].[TableObjectId]
    ) [p]
    OUTER APPLY
    (
        SELECT SUM([BatchCount]) AS [BatchCount],SUM([FailedDocumentCount]) AS [FailedDocumentCount]
        FROM [#FullTextAnalysis_BatchGroup] [x]
        WHERE [x].[DatabaseName]=[fi].[DatabaseName] AND [x].[TableObjectId]=[fi].[TableObjectId]
    ) [b];

    UPDATE [c]
    SET [QueryableFragmentCount]=[x].[QueryableFragmentCount],
        [LogicalSizeMb]=[x].[LogicalSizeMb]
    FROM [#FullTextAnalysis_Catalog] [c]
    OUTER APPLY
    (
        SELECT SUM([fi].[QueryableFragmentCount]) AS [QueryableFragmentCount],
               SUM([fi].[LogicalFragmentSizeMb]) AS [LogicalSizeMb]
        FROM [#FullTextAnalysis_FullTextIndex] [fi]
        WHERE [fi].[DatabaseName]=[c].[DatabaseName] AND [fi].[CatalogId]=[c].[FullTextCatalogId]
    ) [x];

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','FULLTEXT_COMPONENT_UNAVAILABLE_WITH_OBJECTS','IS_FULLTEXT_INSTALLED',0,1,
           N'Sichtbare Full-Text-Kataloge oder -Indizes sind vorhanden, SERVERPROPERTY(IsFullTextInstalled) meldet jedoch 0.',
           N'Der Serverwert und sichtbare Metadaten beweisen weder die Entstehungsursache noch die Betriebsabsicht.',
           N'Installationszustand der Full-Text-Komponente, Upgrade-/Restore-Historie und geplanten Featureeinsatz pruefen; keine automatische Aenderung ableiten.'
    FROM [#FullTextAnalysis_FeatureScope]
    WHERE [IsFullTextInstalled]=0 AND ([CatalogCount]>0 OR [FullTextIndexCount]>0);

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CatalogName],'INFO','MEDIUM','FULLTEXT_CATALOG_WITHOUT_VISIBLE_INDEX','VISIBLE_INDEX_COUNT',0,1,
           N'Im sichtbaren Metadatenscope ist dem Full-Text-Katalog kein Index zugeordnet.',
           [EvidenceLimit],
           N'Metadatensichtbarkeit, Deployment-Zustand und beabsichtigte Katalognutzung pruefen; ein leerer Katalog ist nicht automatisch fehlerhaft.'
    FROM [#FullTextAnalysis_Catalog]
    WHERE [IndexCount]=0;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','HIGH','FULLTEXT_INDEX_DISABLED','IS_ENABLED',0,1,
           N'Der sichtbare Full-Text-Index ist deaktiviert.',
           [EvidenceLimit],
           N'Deployment-, Wartungs- und Fehlerhistorie sowie die beabsichtigte Suchverfuegbarkeit pruefen; keine automatische Aktivierung ausfuehren.'
    FROM [#FullTextAnalysis_FullTextIndex]
    WHERE [IsEnabled]=0;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','HIGH','FULLTEXT_KEY_INDEX_DISABLED','IS_KEY_INDEX_DISABLED',1,0,
           N'Der eindeutige Schluesselindex des sichtbaren Full-Text-Index ist deaktiviert.',
           N'Der Schalter ist belastbare Katalogevidenz; Ursache und Auswirkung auf bereits indizierte Inhalte bleiben ohne Laufzeit- und Fehlerhistorie offen.',
           N'Indexzustand, Wartungshistorie und Full-Text-Fehlerereignisse kontrolliert pruefen; Schluesselwerte werden nicht benoetigt.'
    FROM [#FullTextAnalysis_FullTextIndex]
    WHERE [IsKeyIndexDisabled]=1;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'INFO','HIGH','FULLTEXT_MANUAL_OR_OFF_TRACKING_CONTEXT','CHANGE_TRACKING_STATE',
           CASE [ChangeTrackingState] WHEN 'M' THEN 1 WHEN 'O' THEN 0 ELSE NULL END,NULL,
           CONCAT(N'Der Full-Text-Index verwendet den zulaessigen Change-Tracking-Modus ',COALESCE([ChangeTrackingStateDesc],N'UNKNOWN'),N'.'),
           N'MANUAL oder OFF ist Konfiguration und kein Fehler. Aktualitaet haengt dann von bewusst gestarteten Populationen und dem Betriebsprozess ab.',
           N'Geforderte Suchaktualitaet, Population-Runbook und Zeitverlauf gegen die Betriebsabsicht pruefen.'
    FROM [#FullTextAnalysis_FullTextIndex]
    WHERE [ChangeTrackingState] IN('M','O');

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'INFO','MEDIUM','FULLTEXT_CRAWL_NOT_COMPLETED_CONTEXT','HAS_CRAWL_COMPLETED',0,1,
           N'Fuer den sichtbaren Full-Text-Index ist kein abgeschlossener Crawl vermerkt und aktuell keine Population sichtbar.',
           N'Dies kann nach CREATE ... NO POPULATION oder in einem bewusst verzögerten Betriebsablauf korrekt sein; die Population-DMV ist keine Historie.',
           N'Deployment- und Population-Runbook, Crawl-Logs nur in der geschuetzten Laufzeitumgebung und eine wiederholte Momentaufnahme pruefen.'
    FROM [#FullTextAnalysis_FullTextIndex]
    WHERE [HasCrawlCompleted]=0 AND [ActivePopulationCount]=0;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','MEDIUM','FULLTEXT_CRAWL_PAUSED_REVIEW','CRAWL_PAUSED',1,0,
           N'Der sichtbare Full-Text-Crawl ist als pausierter Full Crawl gekennzeichnet.',
           N'Der Katalogzustand zeigt weder die Ursache noch, ob die Pause beabsichtigt und zeitlich begrenzt ist.',
           N'Wartungsfenster, Populationstatus, Ressourcenlage und freigegebene Crawl-Logs in der Laufzeitumgebung pruefen; nicht automatisch fortsetzen.'
    FROM [#FullTextAnalysis_FullTextIndex]
    WHERE [CrawlTypeDesc]=N'PAUSED_FULL_CRAWL';

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','MEDIUM','FULLTEXT_LONG_RUNNING_POPULATION','POPULATION_AGE_MINUTES',
           [AgeMinutes],@PopulationAgeWarnMinutes,
           CONCAT(N'Eine aktuelle Full-Text-Population ist seit mindestens dem konfigurierten Grenzwert sichtbar; Status: ',COALESCE([StatusDescription],N'UNKNOWN'),N'.'),
           [EvidenceLimit],
           N'Fortschrittszaehler, ausstehende Batches, I/O- und Log-Kontext als Zeitreihe korrelieren; Alter allein beweist keinen Stillstand.'
    FROM [#FullTextAnalysis_Population]
    WHERE [AgeMinutes]>=@PopulationAgeWarnMinutes;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','HIGH','FULLTEXT_POPULATION_ABORTED','POPULATION_STATUS',
           [Status],NULL,
           N'Die aktuelle Population meldet den Status ABORTED.',
           [EvidenceLimit],
           N'Full-Text-Fehlerlog und Crawl-Log in der geschuetzten Laufzeitumgebung, Ressourcen- und Quelldokumentfehler sowie einen kontrollierten Neustartprozess pruefen.'
    FROM [#FullTextAnalysis_Population]
    WHERE [Status]=11;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'INFO','MEDIUM','FULLTEXT_POPULATION_STOPPED_CONTEXT','POPULATION_STATUS',
           [Status],NULL,
           N'Die aktuelle Population meldet STOPPED PROCESSING.',
           N'Dieser Zustand kann laut Microsoft waehrend eines automatischen Merge auftreten und beweist allein keinen Fehler.',
           N'Bei anhaltendem Zustand Folgeaufnahme, Merge-/I/O-Kontext, ausstehende Batches und geschuetzte Full-Text-Logs korrelieren.'
    FROM [#FullTextAnalysis_Population]
    WHERE [Status]=7;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','MEDIUM','FULLTEXT_FRAGMENTATION_HEURISTIC','QUERYABLE_FRAGMENT_COUNT',
           [QueryableFragmentCount],@QueryableFragmentWarn,
           N'Die Zahl querybarer Full-Text-Fragmente erreicht den konfigurierten Pruefgrenzwert.',
           N'Microsoft beschreibt viele querybare Fragmente als moeglichen Query-Performance-Faktor, nennt aber keinen universellen Grenzwert; Groesse und Workload bleiben entscheidend.',
           N'Querylatenz und Fragmenttrend korrelieren und erst danach einen kontrollierten ALTER FULLTEXT CATALOG ... REORGANIZE bewerten.'
    FROM [#FullTextAnalysis_FullTextIndex]
    WHERE [QueryableFragmentCount]>0 AND [QueryableFragmentCount]>=@QueryableFragmentWarn;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CatalogName],'INFO','MEDIUM','FULLTEXT_CATALOG_SIZE_CONTEXT','LOGICAL_FRAGMENT_SIZE_MB',
           [LogicalSizeMb],@CatalogSizeWarnMb,
           N'Die aggregierte logische Groesse querybarer Fragmente erreicht den konfigurierten Kontextgrenzwert.',
           N'Die Fragmentgroesse ist weder Speicherbelegung des gesamten Systems noch ein Gesundheitsurteil und kann bei unvollstaendiger Metadatensichtbarkeit unvollstaendig sein.',
           N'Kapazitaets- und Wachstumstrend, Abfrageworkload, Sicherung und Wartungsfenster gemeinsam pruefen.'
    FROM [#FullTextAnalysis_Catalog]
    WHERE [LogicalSizeMb]>0 AND [LogicalSizeMb]>=@CatalogSizeWarnMb;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','MEDIUM','FULLTEXT_OUTSTANDING_BATCH_BACKLOG','OUTSTANDING_BATCH_COUNT',
           SUM([BatchCount]),@OutstandingBatchWarn,
           N'Die Zahl aktuell ausstehender Full-Text-Batches erreicht den konfigurierten Pruefgrenzwert.',
           N'Batches sind eine Momentaufnahme; ihre Anzahl allein beweist weder Blockierung noch Fehler.',
           N'Populationfortschritt, Retry-/Fehlergruppen, I/O, CPU und Verlauf gemeinsam pruefen.'
    FROM [#FullTextAnalysis_BatchGroup]
    GROUP BY [DatabaseName],[SchemaName],[TableName]
    HAVING SUM([BatchCount])>0 AND SUM([BatchCount])>=@OutstandingBatchWarn;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','HIGH','FULLTEXT_BATCH_ERROR_REPORTED','BATCH_ERROR_CODE',
           [BatchErrorCode],0,
           CONCAT(N'Mindestens ein aktueller Full-Text-Batch meldet den aggregierten Fehlercode ',CONVERT(nvarchar(20),[BatchErrorCode]),N'.'),
           [EvidenceLimit],
           N'Fehlercode ueber freigegebene Microsoft-Dokumentation und geschuetzte Full-Text-/Crawl-Logs aufloesen; keine Quelldaten in das Repository uebernehmen.'
    FROM [#FullTextAnalysis_BatchGroup]
    WHERE COALESCE([BatchErrorCode],0)<>0;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','MEDIUM','FULLTEXT_RETRY_BATCH_CONTEXT','RETRY_BATCH_COUNT',
           [BatchCount],NULL,
           CONCAT(N'Aktuelle Full-Text-Batches werden als Retry ausgefuehrt; Retry-Hinweis: ',COALESCE([RetryHintsDescription],N'UNKNOWN'),N'.'),
           [EvidenceLimit],
           N'Zeitverlauf, Fehlercode, Dokumentfehlerzahl und geschuetzte Crawl-Logs korrelieren; ein einzelner Retry beweist keinen dauerhaften Fehler.'
    FROM [#FullTextAnalysis_BatchGroup]
    WHERE [IsRetryBatch]=1;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','HIGH','FULLTEXT_DOCUMENT_FAILURES_REPORTED','FAILED_DOCUMENT_COUNT',
           SUM([FailedDocumentCount]),@FailedDocumentWarn,
           N'Aktuelle Full-Text-Batches melden fehlgeschlagene Dokumente.',
           N'Einzelne Dokumentfehler koennen eine Population nicht stoppen, betroffene Inhalte aber von der Suche ausschliessen; es werden nur aggregierte Zaehler gelesen.',
           N'Fehlerklassen und freigegebene Crawl-Logs in der Laufzeitumgebung pruefen; Dokumentinhalt oder Schluesselwerte nicht persistieren.'
    FROM [#FullTextAnalysis_BatchGroup]
    GROUP BY [DatabaseName],[SchemaName],[TableName]
    HAVING SUM([FailedDocumentCount])>=@FailedDocumentWarn AND SUM([FailedDocumentCount])>0;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],'WARN','MEDIUM','FULLTEXT_LONG_SEMANTIC_POPULATION','SEMANTIC_POPULATION_AGE_MINUTES',
           [AgeMinutes],@PopulationAgeWarnMinutes,
           CONCAT(N'Eine aktuelle semantische Aehnlichkeitspopulation ueberschreitet den Altersgrenzwert; Status: ',COALESCE([StatusDescription],N'UNKNOWN'),N'.'),
           [EvidenceLimit],
           N'Dokumentfortschritt und Workerzahl wiederholt messen und mit normaler Full-Text-Extraktion, Ressourcenlage und freigegebenen Logs korrelieren.'
    FROM [#FullTextAnalysis_SemanticPopulation]
    WHERE [AgeMinutes]>=@PopulationAgeWarnMinutes;

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT NULL,'WARN','LOW','FULLTEXT_ACTIVE_WITHOUT_VISIBLE_FDHOST','VISIBLE_FDHOST_COUNT',0,1,
           N'Mindestens eine aktuelle Population ist sichtbar, aber die vollstaendig gelesene FDHost-Momentaufnahme enthaelt keinen Host.',
           N'Die beiden DMVs sind nicht atomar und koennen sich zwischen den Abfragen aendern; ein kurzer Uebergang ist moeglich.',
           N'Zeitnah wiederholen und erst bei anhaltender Abweichung Full-Text-Dienst, Ressourcen und Fehlerprotokolle in der Laufzeitumgebung pruefen.'
    WHERE EXISTS(SELECT 1 FROM [#FullTextAnalysis_Population])
      AND NOT EXISTS(SELECT 1 FROM [#FullTextAnalysis_FdHost])
      AND EXISTS(SELECT 1 FROM [#FullTextAnalysis_SourceStatus] WHERE [SourceCode]='FULLTEXT_FDHOSTS' AND [StatusCode]='AVAILABLE' AND [IsPartial]=0)
      AND NOT EXISTS(SELECT 1 FROM [#FullTextAnalysis_SourceStatus] WHERE [SourceCode]='FULLTEXT_POPULATION' AND [IsPartial]=1);

    INSERT [#FullTextAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','FULLTEXT_EVIDENCE_GAP',[SourceCode],
           COALESCE([ErrorMessage],N'Die angeforderte Quelle ist nicht verfuegbar.'),
           [Detail],N'Berechtigung, Featureverfuegbarkeit und Abhaengigkeiten pruefen; andere Resultsets bleiben gueltig.'
    FROM [#FullTextAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    UPDATE [fi]
    SET [AssessmentStatus]=CASE WHEN EXISTS
        (SELECT 1 FROM [#FullTextAnalysis_Findings] [f]
         WHERE [f].[DatabaseName]=[fi].[DatabaseName]
           AND [f].[SchemaName]=[fi].[SchemaName]
           AND [f].[ObjectName]=[fi].[TableName]
           AND [f].[Severity]='WARN') THEN 'REVIEW' ELSE 'AVAILABLE' END
    FROM [#FullTextAnalysis_FullTextIndex] [fi];

    UPDATE [c]
    SET [AssessmentStatus]=CASE WHEN EXISTS
        (SELECT 1 FROM [#FullTextAnalysis_Findings] [f]
         WHERE [f].[DatabaseName]=[c].[DatabaseName]
           AND [f].[ObjectName]=[c].[CatalogName]
           AND [f].[Severity]='WARN') THEN 'REVIEW' ELSE 'AVAILABLE' END
    FROM [#FullTextAnalysis_Catalog] [c];

    UPDATE [ds]
    SET [ActivePopulationCount]=COALESCE([p].[PopulationCount],0),
        [OutstandingBatchCount]=COALESCE([b].[BatchCount],0),
        [SourceFailureCount]=[x].[FailureCount]+[g].[GlobalFailureCount],
        [IsPartial]=CONVERT(bit,CASE WHEN [x].[FailureCount]+[g].[GlobalFailureCount]>0 THEN 1 ELSE 0 END),
        [FindingCount]=[f].[FindingCount],
        [StatusCode]=CASE WHEN [ds].[StatusCode] IN('NOT_APPLICABLE_VISIBLE_SCOPE','UNAVAILABLE_FEATURE','ERROR_HANDLED') THEN [ds].[StatusCode]
                          WHEN [x].[FailureCount]+[g].[GlobalFailureCount]>0 THEN 'AVAILABLE_LIMITED'
                          WHEN [f].[WarnCount]>0 THEN 'AVAILABLE_WITH_FINDING'
                          ELSE 'AVAILABLE' END,
        [Detail]=CASE WHEN [ds].[StatusCode]='PENDING' AND [x].[FailureCount]+[g].[GlobalFailureCount]>0 THEN N'Mindestens eine isolierte Quelle fehlt; zugaengliche Teilergebnisse bleiben erhalten.'
                      WHEN [ds].[StatusCode]='PENDING' AND [f].[WarnCount]>0 THEN N'Mindestens ein konfigurierter Pruefhinweis liegt vor; kein automatisches Gesundheitsurteil.'
                      WHEN [ds].[StatusCode]='PENDING' THEN N'Kein konfigurierter Warnindikator in der zugaenglichen Momentaufnahme; dies beweist weder vollstaendige Indizierung noch fehlerfreie Verarbeitung.'
                      ELSE [ds].[Detail] END
    FROM [#FullTextAnalysis_DatabaseStatus] [ds]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [PopulationCount]
        FROM [#FullTextAnalysis_Population] [pp]
        WHERE [pp].[DatabaseName]=[ds].[DatabaseName]
    ) [p]
    OUTER APPLY
    (
        SELECT SUM([bb].[BatchCount]) AS [BatchCount]
        FROM [#FullTextAnalysis_BatchGroup] [bb]
        WHERE [bb].[DatabaseName]=[ds].[DatabaseName]
    ) [b]
    OUTER APPLY
    (
        SELECT CONVERT(int,COUNT_BIG(*)) AS [FailureCount]
        FROM [#FullTextAnalysis_SourceStatus] [ss]
        WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1
    ) [x]
    CROSS APPLY
    (
        SELECT CONVERT(int,COUNT_BIG(*)) AS [GlobalFailureCount]
        FROM [#FullTextAnalysis_SourceStatus] [ss]
        WHERE [ss].[DatabaseName] IS NULL AND [ss].[IsPartial]=1
          AND ([ds].[CatalogCount]>0 OR [ds].[FullTextIndexCount]>0)
    ) [g]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FindingCount],
               COALESCE(SUM(CASE WHEN [ff].[Severity]='WARN' THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),0) AS [WarnCount]
        FROM [#FullTextAnalysis_Findings] [ff]
        WHERE [ff].[DatabaseName]=[ds].[DatabaseName]
           OR ([ff].[DatabaseName] IS NULL AND ([ds].[CatalogCount]>0 OR [ds].[FullTextIndexCount]>0))
    ) [f];

    IF @StatusCode='AVAILABLE'
    BEGIN
        IF EXISTS(SELECT 1 FROM [#FullTextAnalysis_DatabaseStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        ELSE IF EXISTS(SELECT 1 FROM [#FullTextAnalysis_Findings] WHERE [Severity]='WARN')
            SET @StatusCode='AVAILABLE_WITH_FINDING';
        ELSE IF NOT EXISTS
            (SELECT 1 FROM [#FullTextAnalysis_FeatureScope] WHERE [CatalogCount]>0 OR [FullTextIndexCount]>0)
            SET @StatusCode='NOT_APPLICABLE';
    END;

    SELECT @ErrorNumber=COALESCE(@ErrorNumber,MIN([ErrorNumber])),
           @ErrorMessage=COALESCE(@ErrorMessage,MIN([ErrorMessage]))
    FROM [#FullTextAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    IF @JsonErzeugen=1
    BEGIN
        SELECT @Json=(
            SELECT
                JSON_QUERY((SELECT N'USP_FullTextAnalysis' AS [module],@Now AS [collectedAtUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@ErrorNumber AS [errorNumber],@ErrorMessage AS [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS [meta],
                JSON_QUERY(COALESCE((SELECT * FROM [#FullTextAnalysis_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH),N'[]')) AS [databaseStatus],
                JSON_QUERY(COALESCE((SELECT * FROM [#FullTextAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode] FOR JSON PATH),N'[]')) AS [sourceStatus],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal] FOR JSON PATH),N'[]')) AS [findings],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_Catalog] WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW' ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[LogicalSizeMb] DESC,[DatabaseName],[CatalogName] FOR JSON PATH),N'[]')) AS [catalogs],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_FullTextIndex] WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW' ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[QueryableFragmentCount] DESC,[DatabaseName],[SchemaName],[TableName] FOR JSON PATH),N'[]')) AS [fullTextIndexes],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_Population] WHERE @NurProblematisch=0 OR [AgeMinutes]>=@PopulationAgeWarnMinutes OR [Status]=11 ORDER BY [AgeMinutes] DESC,[DatabaseName],[SchemaName],[TableName] FOR JSON PATH),N'[]')) AS [populations],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_BatchGroup] WHERE @NurProblematisch=0 OR COALESCE([BatchErrorCode],0)<>0 OR [IsRetryBatch]=1 OR [FailedDocumentCount]>=@FailedDocumentWarn ORDER BY [FailedDocumentCount] DESC,[BatchCount] DESC,[DatabaseName],[SchemaName],[TableName] FOR JSON PATH),N'[]')) AS [outstandingBatches],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_SemanticPopulation] WHERE @NurProblematisch=0 OR [AgeMinutes]>=@PopulationAgeWarnMinutes ORDER BY [AgeMinutes] DESC,[DatabaseName],[SchemaName],[TableName] FOR JSON PATH),N'[]')) AS [semanticPopulations],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_MemoryPool] ORDER BY [AllocatedMb] DESC,[PoolId] FOR JSON PATH),N'[]')) AS [memoryPools],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#FullTextAnalysis_FdHost] ORDER BY [FdHostType] FOR JSON PATH),N'[]')) AS [fdHosts]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
    END;

    IF @OutputMode<>'NONE'
    BEGIN
        SELECT N'USP_FullTextAnalysis' AS [Module],@Now AS [CollectedAtUtc],@StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],
               N'Read-only Full-Text-Metadatenaufnahme; keine Tabelleninhalte, Suchbegriffe, Crawl-Logs, Pfade, Schluesselwerte oder DDL.' AS [Detail];
        SELECT * FROM [#FullTextAnalysis_DatabaseStatus] ORDER BY [DatabaseName];
        SELECT * FROM [#FullTextAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_Findings]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_Catalog]
        WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW'
        ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,
                 [LogicalSizeMb] DESC,[DatabaseName],[CatalogName];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_FullTextIndex]
        WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW'
        ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,
                 [QueryableFragmentCount] DESC,[DatabaseName],[SchemaName],[TableName];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_Population]
        WHERE @NurProblematisch=0 OR [AgeMinutes]>=@PopulationAgeWarnMinutes OR [Status]=11
        ORDER BY [AgeMinutes] DESC,[DatabaseName],[SchemaName],[TableName];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_BatchGroup]
        WHERE @NurProblematisch=0 OR COALESCE([BatchErrorCode],0)<>0 OR [IsRetryBatch]=1 OR [FailedDocumentCount]>=@FailedDocumentWarn
        ORDER BY [FailedDocumentCount] DESC,[BatchCount] DESC,[DatabaseName],[SchemaName],[TableName];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_SemanticPopulation]
        WHERE @NurProblematisch=0 OR [AgeMinutes]>=@PopulationAgeWarnMinutes
        ORDER BY [AgeMinutes] DESC,[DatabaseName],[SchemaName],[TableName];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_MemoryPool] ORDER BY [AllocatedMb] DESC,[PoolId];
        SELECT TOP(@Limit) * FROM [#FullTextAnalysis_FdHost] ORDER BY [FdHostType];
    END;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=LEFT(CONCAT(N'USP_FullTextAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe strukturierte Quellenstatus.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#FullTextAnalysis_Findings'
            , @ResultLabel=N'FullTextAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#FullTextAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
