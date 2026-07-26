USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_InMemoryOltpAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Typ          : Stored Procedure
Zweck        : Analysiert sichtbare In-Memory-OLTP-Konfiguration und isolierte
               Laufzeitevidenz zu Speicher, Hashindizes, Checkpoint-Dateien,
               aktiven Transaktionen und Resource-Governor-Pools.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.tables, sys.table_types, sys.filegroups, sys.hash_indexes,
               sys.dm_db_xtp_table_memory_stats,
               sys.dm_db_xtp_memory_consumers,
               sys.dm_db_xtp_hash_index_stats (opt-in),
               sys.dm_db_xtp_checkpoint_files, sys.dm_db_xtp_transactions,
               sys.databases und sys.dm_resource_governor_resource_pools.
Methodik     : Jede DMV-Quelle wird separat best effort ausgewertet. Fehlende
               Rechte oder Quellen verwerfen andere zugängliche Evidenz nicht.
Grenzen      : Momentaufnahmen und heuristische Prüfhinweise sind kein Beweis
               für Speicherknappheit, fehlerhafte Bucket-Zahlen, Log-Stau oder
               Transaktionsprobleme. Keine DDL-, Daten- oder Definitionsscans.
Kosten       : MEDIUM; Hashindex-Laufzeitstatistik HIGH_OPT_IN, da die DMV nach
               Herstellerdokumentation vollständige Tabellen scannen kann.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_InMemoryOltpAnalysis]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)  = NULL
    , @SchemaNamePattern                nvarchar(4000) = NULL
    , @ObjectNames                      nvarchar(max)  = NULL
    , @ObjectNamePattern                nvarchar(4000) = NULL
    , @FullObjectNames                  nvarchar(max)  = NULL
    , @MitHashIndexStats                bit            = 0
    , @NurProblematisch                 bit            = 0
    , @MinTableMemoryMb                 decimal(19,2)  = 1024
    , @HashAvgChainWarn                 decimal(19,4)  = 10
    , @HashMaxChainWarn                 bigint         = 100
    , @HashMinEmptyBucketPercent        decimal(9,4)   = 10
    , @WaitingCheckpointWarnMb          decimal(19,2)  = 1024
    , @ActiveTransactionWarnCount       int            = 100
    , @PoolUsedWarnPercent              decimal(9,4)   = 80
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
        PRINT N'monitor.USP_InMemoryOltpAnalysis';
        PRINT N'Die Procedure führt eine rein lesende Tiefenanalyse sichtbarer In-Memory-OLTP-Metadaten und isolierter Laufzeitquellen durch.';
        PRINT N'@MitHashIndexStats=1 aktiviert eine potenziell teure vollständige Hashindex-DMV-Auswertung und benötigt CATALOG_DEEP.';
        PRINT N'Exakte Namenslisten und Pattern derselben Eigenschaft sind gegenseitig exklusiv; Pattern: LIKE, regex: oder regexi:.';
        PRINT N'Grenzwerte erzeugen Prüfhinweise, keine automatische DDL- oder Kapazitätsempfehlung.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson; @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        PRINT N'Es werden keine Benutzertabellendaten, Moduldefinitionen, SQL-Texte, Transaktions-IDs oder Checkpoint-Dateipfade gelesen.';
        RETURN;
    END;

    IF @SystemdatenbankenEinbeziehen IS NULL OR @MitHashIndexStats IS NULL
       OR @NurProblematisch IS NULL OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @MinTableMemoryMb IS NULL OR @MinTableMemoryMb<0
       OR @HashAvgChainWarn IS NULL OR @HashAvgChainWarn<1 OR @HashAvgChainWarn>100000
       OR @HashMaxChainWarn IS NULL OR @HashMaxChainWarn<1
       OR @HashMinEmptyBucketPercent IS NULL OR @HashMinEmptyBucketPercent<0 OR @HashMinEmptyBucketPercent>100
       OR @WaitingCheckpointWarnMb IS NULL OR @WaitingCheckpointWarnMb<0
       OR @ActiveTransactionWarnCount IS NULL OR @ActiveTransactionWarnCount<1
       OR @PoolUsedWarnPercent IS NULL OR @PoolUsedWarnPercent<0 OR @PoolUsedWarnPercent>100
 OR @MaxZeilen<0
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

    CREATE TABLE [#InMemoryOltpAnalysis_NameFilters]
    (
          [FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [ItemOrdinal] int NOT NULL
        , [NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_DatabaseCandidates]
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
    CREATE TABLE [#InMemoryOltpAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_FeatureScope]
    (
          [DatabaseName] sysname NOT NULL PRIMARY KEY
        , [MemoryOptimizedTableCount] bigint NOT NULL
        , [MemoryOptimizedTableTypeCount] bigint NOT NULL
        , [MemoryOptimizedFilegroupCount] bigint NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_DatabaseStatus]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [MemoryOptimizedTableCount] bigint NOT NULL
        , [MemoryOptimizedTableTypeCount] bigint NOT NULL
        , [MemoryOptimizedFilegroupCount] bigint NOT NULL
        , [SourceFailureCount] int NOT NULL
        , [FindingCount] bigint NOT NULL
        , [RequiredPermission] nvarchar(256) NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_SourceStatus]
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
    CREATE TABLE [#InMemoryOltpAnalysis_TableMemory]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [TableName] sysname NOT NULL
        , [ObjectId] int NOT NULL
        , [DurabilityDesc] nvarchar(60) NULL
        , [TableAllocatedMb] decimal(19,2) NULL
        , [TableUsedMb] decimal(19,2) NULL
        , [IndexAllocatedMb] decimal(19,2) NULL
        , [IndexUsedMb] decimal(19,2) NULL
        , [TotalAllocatedMb] decimal(19,2) NULL
        , [TotalUsedMb] decimal(19,2) NULL
        , [UsedPercent] decimal(9,4) NULL
        , [Severity] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_HashIndex]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [TableName] sysname NOT NULL
        , [IndexName] sysname NOT NULL
        , [ObjectId] int NOT NULL
        , [IndexId] int NOT NULL
        , [ConfiguredBucketCount] bigint NULL
        , [TotalBucketCount] bigint NULL
        , [EmptyBucketCount] bigint NULL
        , [EmptyBucketPercent] decimal(9,4) NULL
        , [AverageChainLength] decimal(19,4) NULL
        , [MaxChainLength] bigint NULL
        , [RuntimeStatsStatus] varchar(40) NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_MemoryConsumer]
    (
          [DatabaseName] sysname NOT NULL
        , [MemoryConsumerType] int NULL
        , [MemoryConsumerDesc] nvarchar(256) NULL
        , [ConsumerCount] bigint NOT NULL
        , [AllocationCount] bigint NULL
        , [AllocatedMb] decimal(19,2) NULL
        , [UsedMb] decimal(19,2) NULL
        , [UsedPercent] decimal(9,4) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_Checkpoint]
    (
          [DatabaseName] sysname NOT NULL
        , [FileType] int NULL
        , [FileTypeDesc] nvarchar(60) NULL
        , [State] int NULL
        , [StateDesc] nvarchar(60) NULL
        , [FileCount] bigint NOT NULL
        , [FileSizeMb] decimal(19,2) NULL
        , [FileUsedMb] decimal(19,2) NULL
        , [LogicalRowCount] bigint NULL
        , [Severity] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_Transaction]
    (
          [DatabaseName] sysname NOT NULL
        , [TransactionState] int NULL
        , [TransactionStateDesc] nvarchar(60) NOT NULL
        , [ResultDesc] nvarchar(256) NULL
        , [TransactionCount] bigint NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_ResourcePool]
    (
          [DatabaseName] sysname NOT NULL
        , [ResourcePoolId] int NULL
        , [ResourcePoolName] sysname NULL
        , [IsDefaultOrUnbound] bit NOT NULL
        , [DatabasesUsingPool] bigint NULL
        , [MinMemoryPercent] int NULL
        , [MaxMemoryPercent] int NULL
        , [MaxMemoryMb] decimal(19,2) NULL
        , [TargetMemoryMb] decimal(19,2) NULL
        , [UsedMemoryMb] decimal(19,2) NULL
        , [UsedPercentOfTarget] decimal(9,4) NULL
        , [OutOfMemoryCount] bigint NULL
        , [Severity] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#InMemoryOltpAnalysis_Findings]
    (
          [FindingOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [DatabaseName] sysname NULL
        , [SchemaName] sysname NULL
        , [ObjectName] sysname NULL
        , [IndexName] sysname NULL
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
            , @ErrorMessage=@ErrorMessage OUTPUT,@FilterTable=N'#InMemoryOltpAnalysis_NameFilters';
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    DECLARE @CrossDatabaseRequested bit=0;
    IF @StatusCode='AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames=@DatabaseNames
            , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass='OBJECT_ANALYSIS_CURRENT'
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#InMemoryOltpAnalysis_DatabaseCandidates',@WarningTable=N'#InMemoryOltpAnalysis_DatabaseCandidateWarnings';
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    INSERT [#InMemoryOltpAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[MemoryOptimizedTableCount],[MemoryOptimizedTableTypeCount],
     [MemoryOptimizedFilegroupCount],[SourceFailureCount],[FindingCount],[Detail])
    SELECT [DatabaseName],'PENDING',0,0,0,0,0,0,
           N'Feature-Gate und Quellen werden datenbankweise best effort ausgewertet.'
    FROM [#InMemoryOltpAnalysis_DatabaseCandidates];

    INSERT [#InMemoryOltpAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[MemoryOptimizedTableCount],[MemoryOptimizedTableTypeCount],
     [MemoryOptimizedFilegroupCount],[SourceFailureCount],[FindingCount],[ErrorMessage],[Detail])
    SELECT [RequestedName],[StatusCode],1,0,0,0,1,0,[ErrorMessage],N'Explizit angeforderte Datenbank nicht auswertbar.'
    FROM [#InMemoryOltpAnalysis_DatabaseCandidateWarnings];

    IF @StatusCode='AVAILABLE' AND NOT EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_DatabaseCandidates])
    BEGIN
        SELECT @StatusCode='NOT_APPLICABLE',@ErrorMessage=N'Keine auswertbare Datenbank im gewählten Scope.';
    END;

    IF @StatusCode='AVAILABLE' AND @MitHashIndexStats=1
        EXEC [monitor].[InternalCheckAnalysisPath]
              @AnalysisClass='CATALOG_DEEP'
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT;
    DECLARE @HashStatsAllowed bit=CONVERT(bit,CASE WHEN @StatusCode='AVAILABLE' THEN 1 ELSE 0 END);

    DECLARE @SchemaPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @ObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @FullObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDatabaseName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
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
            FROM [#InMemoryOltpAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;

        WHILE @@FETCH_STATUS=0
        BEGIN
            IF (@SchemaPatternMode IN('REGEX','REGEXI') OR @ObjectPatternMode IN('REGEX','REGEXI'))
               AND COALESCE(@CompatibilityLevel,0)<170
            BEGIN
                UPDATE [#InMemoryOltpAnalysis_DatabaseStatus]
                SET [StatusCode]='UNAVAILABLE_FEATURE',[IsPartial]=1,[SourceFailureCount]=1,
                    [ErrorMessage]=N'Regex-Pattern benötigen Compatibility Level 170.',
                    [Detail]=N'Für diese Datenbank wurde wegen inkompatiblem Patternvertrag keine Analyse ausgeführt.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'FILTER_CONTRACT','UNAVAILABLE_FEATURE',1,0,NULL,NULL,
                       N'Regex-Pattern benötigen Compatibility Level 170.',N'Keine Quellenabfrage ausgeführt.');
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#InMemoryOltpAnalysis_FeatureScope]([DatabaseName],[MemoryOptimizedTableCount],[MemoryOptimizedTableTypeCount],[MemoryOptimizedFilegroupCount])
SELECT @pDatabaseName,
       (SELECT COUNT_BIG(*) FROM [sys].[tables] WITH (NOLOCK) WHERE [is_ms_shipped]=0 AND [is_memory_optimized]=1),
       (SELECT COUNT_BIG(*) FROM [sys].[table_types] WITH (NOLOCK) WHERE [is_memory_optimized]=1),
       (SELECT COUNT_BIG(*) FROM [sys].[filegroups] WITH (NOLOCK) WHERE [type]=''FX'');
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',@pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_FEATURE_GATE','AVAILABLE',0,@Rows,N'Katalogsicht auf sichtbare Datenbankmetadaten',NULL,NULL,
                       N'Tabellen, Tabellentypen und MEMORY_OPTIMIZED_DATA-Dateigruppe; keine Nutzdaten.');
                UPDATE [ds]
                SET [MemoryOptimizedTableCount]=[fs].[MemoryOptimizedTableCount],
                    [MemoryOptimizedTableTypeCount]=[fs].[MemoryOptimizedTableTypeCount],
                    [MemoryOptimizedFilegroupCount]=[fs].[MemoryOptimizedFilegroupCount]
                FROM [#InMemoryOltpAnalysis_DatabaseStatus] [ds]
                JOIN [#InMemoryOltpAnalysis_FeatureScope] [fs] ON [fs].[DatabaseName]=[ds].[DatabaseName]
                WHERE [ds].[DatabaseName]=@DbName;
            END TRY
            BEGIN CATCH
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_FEATURE_GATE','ERROR_HANDLED',1,0,N'Katalogsicht auf sichtbare Datenbankmetadaten',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Feature-Sichtbarkeit konnte nicht bestimmt werden.');
                UPDATE [#InMemoryOltpAnalysis_DatabaseStatus]
                SET [StatusCode]='ERROR_HANDLED',[IsPartial]=1,[SourceFailureCount]=[SourceFailureCount]+1,
                    [ErrorNumber]=ERROR_NUMBER(),[ErrorMessage]=ERROR_MESSAGE(),
                    [Detail]=N'Feature-Gate fehlgeschlagen; keine belastbare Anwendbarkeitsaussage.'
                WHERE [DatabaseName]=@DbName;
            END CATCH;

            IF NOT EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_FeatureScope] WHERE [DatabaseName]=@DbName)
            BEGIN
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            IF EXISTS
            (
                SELECT 1 FROM [#InMemoryOltpAnalysis_FeatureScope]
                WHERE [DatabaseName]=@DbName
                  AND [MemoryOptimizedTableCount]+[MemoryOptimizedTableTypeCount]+[MemoryOptimizedFilegroupCount]=0
            )
            BEGIN
                UPDATE [#InMemoryOltpAnalysis_DatabaseStatus]
                SET [StatusCode]='NOT_APPLICABLE_VISIBLE_SCOPE',[IsPartial]=0,
                    [Detail]=N'Im sichtbaren Katalogscope wurde keine In-Memory-OLTP-Nutzung oder MEMORY_OPTIMIZED_DATA-Dateigruppe erkannt; dies beweist keine vollständige Abwesenheit.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                SELECT @DbName,[SourceCode],'NOT_APPLICABLE',0,0,[RequiredPermission],NULL,NULL,
                       N'Quelle wegen negativem sichtbaren Feature-Gate nicht aufgerufen.'
                FROM (VALUES
                      ('XTP_TABLE_MEMORY',N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE'),
                      ('XTP_MEMORY_CONSUMERS',N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE'),
                      ('XTP_HASH_INDEX_CATALOG',N'Katalogsicht auf sichtbare Hashindizes'),
                      ('XTP_HASH_INDEX_STATS',N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE'),
                      ('XTP_CHECKPOINT_FILES',N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE'),
                      ('XTP_TRANSACTIONS',N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE'),
                      ('RESOURCE_POOL_MEMORY',N'VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE'))
                     [x]([SourceCode],[RequiredPermission]);
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#InMemoryOltpAnalysis_TableMemory]
SELECT @pDatabaseName,[s].[name],[t].[name],[t].[object_id],[t].[durability_desc],
       CONVERT(decimal(19,2),[m].[memory_allocated_for_table_kb]/1024.0),
       CONVERT(decimal(19,2),[m].[memory_used_by_table_kb]/1024.0),
       CONVERT(decimal(19,2),[m].[memory_allocated_for_indexes_kb]/1024.0),
       CONVERT(decimal(19,2),[m].[memory_used_by_indexes_kb]/1024.0),
       CONVERT(decimal(19,2),([m].[memory_allocated_for_table_kb]+[m].[memory_allocated_for_indexes_kb])/1024.0),
       CONVERT(decimal(19,2),([m].[memory_used_by_table_kb]+[m].[memory_used_by_indexes_kb])/1024.0),
       CONVERT(decimal(9,4),100.0*([m].[memory_used_by_table_kb]+[m].[memory_used_by_indexes_kb])/
          NULLIF([m].[memory_allocated_for_table_kb]+[m].[memory_allocated_for_indexes_kb],0)),
       CASE WHEN ([m].[memory_used_by_table_kb]+[m].[memory_used_by_indexes_kb])/1024.0>=@pMinTableMemoryMb THEN ''INFO'' ELSE ''NONE'' END,
       CASE WHEN ([m].[memory_used_by_table_kb]+[m].[memory_used_by_indexes_kb])/1024.0>=@pMinTableMemoryMb THEN ''LARGE_MEMORY_CONSUMER_CONTEXT'' END,
       N''Tabellenspeicher ist eine Momentaufnahme und beweist weder Pooldruck noch zukünftigen Kapazitätsbedarf.''
FROM [sys].[dm_db_xtp_table_memory_stats] [m] WITH (NOLOCK)
JOIN [sys].[tables] [t] WITH (NOLOCK) ON [t].[object_id]=[m].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
WHERE [t].[is_ms_shipped]=0'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N';
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,
                     N'@pDatabaseName sysname,@pRows bigint OUTPUT,@pMinTableMemoryMb decimal(19,2)',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT,@pMinTableMemoryMb=@MinTableMemoryMb;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_TABLE_MEMORY','AVAILABLE',0,@Rows,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,NULL,
                       N'Sichtbare speicheroptimierte Tabellen; Nullzeilen können auch aus Filtern oder Metadatensichtbarkeit folgen.');
            END TRY
            BEGIN CATCH
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_TABLE_MEMORY','ERROR_HANDLED',1,0,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Andere XTP-Quellen werden fortgesetzt.');
            END CATCH;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#InMemoryOltpAnalysis_MemoryConsumer]
SELECT @pDatabaseName,[memory_consumer_type],[memory_consumer_desc],COUNT_BIG(*),SUM(CONVERT(bigint,[allocation_count])),
       CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[allocated_bytes]))/1048576.0),
       CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[used_bytes]))/1048576.0),
       CONVERT(decimal(9,4),100.0*SUM(CONVERT(decimal(38,2),[used_bytes]))/NULLIF(SUM(CONVERT(decimal(38,2),[allocated_bytes])),0)),
       N''Aggregat nach Consumer-Typ; Typ 0 wird als reine Aggregationszeile ausgelassen und eine Datenbankzuordnung einzelner Verbraucher wird nicht behauptet.''
FROM [sys].[dm_db_xtp_memory_consumers] WITH (NOLOCK)
WHERE [memory_consumer_type]<>0
GROUP BY [memory_consumer_type],[memory_consumer_desc];
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',@pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_MEMORY_CONSUMERS','AVAILABLE',0,@Rows,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,NULL,
                       N'Aggregierte Consumer-Typen ohne Objekt-, Session- oder Transaktionsidentifikatoren.');
            END TRY
            BEGIN CATCH
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_MEMORY_CONSUMERS','ERROR_HANDLED',1,0,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Andere XTP-Quellen werden fortgesetzt.');
            END CATCH;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#InMemoryOltpAnalysis_HashIndex]
SELECT @pDatabaseName,[s].[name],[t].[name],[i].[name],[t].[object_id],[i].[index_id],
       CONVERT(bigint,[i].[bucket_count]),NULL,NULL,NULL,NULL,NULL,
       ''NOT_REQUESTED'',''NONE'',NULL,
       N''Konfigurierte Bucket-Zahl ohne Laufzeitketten; daraus allein folgt keine Fehlkonfiguration.''
FROM [sys].[hash_indexes] [i] WITH (NOLOCK)
JOIN [sys].[tables] [t] WITH (NOLOCK) ON [t].[object_id]=[i].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
WHERE [t].[is_ms_shipped]=0'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N';
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',@pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_HASH_INDEX_CATALOG','AVAILABLE',0,@Rows,N'Katalogsicht auf sichtbare Hashindizes',NULL,NULL,
                       N'Nur konfigurierte Bucket-Zahl; keine Benutzerdaten oder Schlüsselwerte.');
            END TRY
            BEGIN CATCH
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_HASH_INDEX_CATALOG','ERROR_HANDLED',1,0,N'Katalogsicht auf sichtbare Hashindizes',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Andere XTP-Quellen werden fortgesetzt.');
            END CATCH;

            IF @MitHashIndexStats=0
            BEGIN
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_HASH_INDEX_STATS','NOT_REQUESTED',0,0,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,NULL,
                       N'Bewusst nicht ausgeführt: Die DMV kann vollständige Tabellen scannen.');
            END
            ELSE IF @HashStatsAllowed=0
            BEGIN
                UPDATE [#InMemoryOltpAnalysis_HashIndex]
                SET [RuntimeStatsStatus]='DENIED_GROUP'
                WHERE [DatabaseName]=@DbName AND [RuntimeStatsStatus]='NOT_REQUESTED';
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_HASH_INDEX_STATS','DENIED_GROUP',1,0,
                       N'CATALOG_DEEP und VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,
                       N'CATALOG_DEEP ist nicht freigegeben.',N'Basisevidenz bleibt verfügbar; Laufzeitketten wurden nicht gelesen.');
            END
            ELSE
            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
UPDATE [h]
SET [TotalBucketCount]=[x].[total_bucket_count],
    [EmptyBucketCount]=[x].[empty_bucket_count],
    [EmptyBucketPercent]=CONVERT(decimal(9,4),100.0*[x].[empty_bucket_count]/NULLIF([x].[total_bucket_count],0)),
    [AverageChainLength]=CONVERT(decimal(19,4),[x].[avg_chain_length]),
    [MaxChainLength]=[x].[max_chain_length],
    [RuntimeStatsStatus]=''AVAILABLE''
FROM [#InMemoryOltpAnalysis_HashIndex] [h]
JOIN [sys].[dm_db_xtp_hash_index_stats] [x] WITH (NOLOCK)
  ON [x].[object_id]=[h].[ObjectId] AND [x].[index_id]=[h].[IndexId]
WHERE [h].[DatabaseName]=@pDatabaseName;
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',@pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                UPDATE [#InMemoryOltpAnalysis_HashIndex]
                SET [RuntimeStatsStatus]='NO_RUNTIME_ROW'
                WHERE [DatabaseName]=@DbName AND [RuntimeStatsStatus]='NOT_REQUESTED';
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_HASH_INDEX_STATS','AVAILABLE',0,@Rows,
                       N'CATALOG_DEEP und VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,NULL,
                       N'Opt-in-Laufzeitketten; die DMV kann vollständige Tabellen scannen.');
            END TRY
            BEGIN CATCH
                UPDATE [#InMemoryOltpAnalysis_HashIndex]
                SET [RuntimeStatsStatus]='ERROR_HANDLED'
                WHERE [DatabaseName]=@DbName AND [RuntimeStatsStatus]='NOT_REQUESTED';
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_HASH_INDEX_STATS','ERROR_HANDLED',1,0,
                       N'CATALOG_DEEP und VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Basisevidenz bleibt verfügbar; Laufzeitketten fehlen.');
            END CATCH;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#InMemoryOltpAnalysis_Checkpoint]
SELECT @pDatabaseName,[file_type],[file_type_desc],[state],[state_desc],COUNT_BIG(*),
       CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[file_size_in_bytes]))/1048576.0),
       CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[file_size_used_in_bytes]))/1048576.0),
       SUM(CONVERT(bigint,[logical_row_count])),
       CASE WHEN [state]=8 AND SUM(CONVERT(decimal(38,2),[file_size_in_bytes]))/1048576.0>=@pWarnMb THEN ''WARN'' ELSE ''NONE'' END,
       CASE WHEN [state]=8 AND SUM(CONVERT(decimal(38,2),[file_size_in_bytes]))/1048576.0>=@pWarnMb THEN ''WAITING_LOG_TRUNCATION_REVIEW'' END,
       N''State 8 kann transient sein; Momentaufnahme ohne Verlauf, Log-Reuse-Wait oder Merge-Fortschritt. Keine Dateipfade oder GUIDs ausgegeben.''
FROM [sys].[dm_db_xtp_checkpoint_files] WITH (NOLOCK)
GROUP BY [file_type],[file_type_desc],[state],[state_desc];
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT,@pWarnMb decimal(19,2)',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT,@pWarnMb=@WaitingCheckpointWarnMb;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_CHECKPOINT_FILES','AVAILABLE',0,@Rows,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,NULL,
                       N'Aggregat nach Dateiart und Zustand; keine relativen Pfade oder Container-GUIDs.');
            END TRY
            BEGIN CATCH
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_CHECKPOINT_FILES','ERROR_HANDLED',1,0,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Andere XTP-Quellen werden fortgesetzt.');
            END CATCH;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#InMemoryOltpAnalysis_Transaction]
SELECT @pDatabaseName,[state],
       CASE [state] WHEN 0 THEN N''ACTIVE'' WHEN 1 THEN N''COMMITTED'' WHEN 2 THEN N''ABORTED'' WHEN 3 THEN N''VALIDATING'' ELSE N''UNKNOWN'' END,
       [result_desc],COUNT_BIG(*),
       CASE WHEN [state] IN(0,3) AND COUNT_BIG(*)>=@pWarnCount THEN ''WARN'' ELSE ''NONE'' END,
       CASE WHEN [state] IN(0,3) AND COUNT_BIG(*)>=@pWarnCount THEN ''ACTIVE_TRANSACTION_VOLUME_REVIEW'' END,
       N''Aggregierte Momentaufnahme ohne Startzeit, Dauer, Session-, Benutzer- oder Transaktionsidentifikatoren.''
FROM [sys].[dm_db_xtp_transactions] WITH (NOLOCK)
GROUP BY [state],[result_desc];
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT,@pWarnCount int',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT,@pWarnCount=@ActiveTransactionWarnCount;
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_TRANSACTIONS','AVAILABLE',0,@Rows,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',NULL,NULL,
                       N'Aggregat nach Status und Ergebnis; keine Session-, Benutzer- oder Transaktionsidentifikatoren.');
            END TRY
            BEGIN CATCH
                INSERT [#InMemoryOltpAnalysis_SourceStatus]
                VALUES(@DbName,'XTP_TRANSACTIONS','ERROR_HANDLED',1,0,
                       N'VIEW DATABASE STATE; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Andere XTP-Quellen werden fortgesetzt.');
            END CATCH;

            FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
        END;
        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];

        BEGIN TRY
            ;WITH [PoolUse] AS
            (
                SELECT [resource_pool_id],COUNT_BIG(*) AS [DatabaseCount]
                FROM [sys].[databases] WITH (NOLOCK)
                GROUP BY [resource_pool_id]
            )
            INSERT [#InMemoryOltpAnalysis_ResourcePool]
            SELECT [fs].[DatabaseName],[d].[resource_pool_id],[p].[name],
                   CONVERT(bit,CASE WHEN COALESCE([d].[resource_pool_id],2)=2 THEN 1 ELSE 0 END),
                   [u].[DatabaseCount],[p].[min_memory_percent],[p].[max_memory_percent],
                   CONVERT(decimal(19,2),[p].[max_memory_kb]/1024.0),
                   CONVERT(decimal(19,2),[p].[target_memory_kb]/1024.0),
                   CONVERT(decimal(19,2),[p].[used_memory_kb]/1024.0),
                   CONVERT(decimal(9,4),100.0*[p].[used_memory_kb]/NULLIF([p].[target_memory_kb],0)),
                   [p].[out_of_memory_count],
                   CASE WHEN COALESCE([d].[resource_pool_id],2)<>2
                             AND (COALESCE([p].[out_of_memory_count],0)>0
                                  OR 100.0*[p].[used_memory_kb]/NULLIF([p].[target_memory_kb],0)>=@PoolUsedWarnPercent)
                        THEN 'WARN' ELSE 'INFO' END,
                   CASE WHEN COALESCE([d].[resource_pool_id],2)=2 THEN 'SHARED_DEFAULT_POOL_CONTEXT'
                        WHEN COALESCE([p].[out_of_memory_count],0)>0 THEN 'POOL_OUT_OF_MEMORY_RECORDED'
                        WHEN 100.0*[p].[used_memory_kb]/NULLIF([p].[target_memory_kb],0)>=@PoolUsedWarnPercent THEN 'POOL_MEMORY_PRESSURE_REVIEW'
                        ELSE 'RESOURCE_POOL_CONTEXT' END,
                   N'Poolwerte sind eine Servermomentaufnahme. Der Defaultpool erlaubt keine belastbare Datenbankzuordnung; auch benannte Pools können von mehreren Datenbanken geteilt werden.'
            FROM [#InMemoryOltpAnalysis_FeatureScope] [fs]
            JOIN [sys].[databases] [d] WITH (NOLOCK) ON [d].[name]=[fs].[DatabaseName]
            LEFT JOIN [sys].[dm_resource_governor_resource_pools] [p] WITH (NOLOCK) ON [p].[pool_id]=COALESCE([d].[resource_pool_id],2)
            LEFT JOIN [PoolUse] [u] ON [u].[resource_pool_id]=[d].[resource_pool_id]
            WHERE [fs].[MemoryOptimizedTableCount]+[fs].[MemoryOptimizedTableTypeCount]+[fs].[MemoryOptimizedFilegroupCount]>0;

            INSERT [#InMemoryOltpAnalysis_SourceStatus]
            SELECT [fs].[DatabaseName],'RESOURCE_POOL_MEMORY','AVAILABLE',0,
                   COUNT_BIG([p].[DatabaseName]),N'VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',NULL,NULL,
                   N'Poolweite Momentaufnahme; keine datenbankgenaue Speicherattribution.'
            FROM [#InMemoryOltpAnalysis_FeatureScope] [fs]
            LEFT JOIN [#InMemoryOltpAnalysis_ResourcePool] [p] ON [p].[DatabaseName]=[fs].[DatabaseName]
            WHERE [fs].[MemoryOptimizedTableCount]+[fs].[MemoryOptimizedTableTypeCount]+[fs].[MemoryOptimizedFilegroupCount]>0
            GROUP BY [fs].[DatabaseName];
        END TRY
        BEGIN CATCH
            INSERT [#InMemoryOltpAnalysis_SourceStatus]
            SELECT [DatabaseName],'RESOURCE_POOL_MEMORY','ERROR_HANDLED',1,0,
                   N'VIEW SERVER STATE; SQL Server 2022+: VIEW SERVER PERFORMANCE STATE',
                   ERROR_NUMBER(),ERROR_MESSAGE(),N'XTP-Datenbankquellen bleiben verfügbar.'
            FROM [#InMemoryOltpAnalysis_FeatureScope]
            WHERE [MemoryOptimizedTableCount]+[MemoryOptimizedTableTypeCount]+[MemoryOptimizedFilegroupCount]>0;
        END CATCH;
    END;

    UPDATE [#InMemoryOltpAnalysis_HashIndex]
    SET [Severity]=CASE
          WHEN [RuntimeStatsStatus]<>'AVAILABLE' THEN 'NONE'
          WHEN [AverageChainLength]>@HashAvgChainWarn OR [MaxChainLength]>=@HashMaxChainWarn
               OR [EmptyBucketPercent]<@HashMinEmptyBucketPercent THEN 'WARN'
          ELSE 'NONE' END,
        [FindingCode]=CASE
          WHEN [RuntimeStatsStatus]<>'AVAILABLE' THEN NULL
          WHEN [AverageChainLength]>@HashAvgChainWarn AND [EmptyBucketPercent]>=@HashMinEmptyBucketPercent THEN 'HASH_DUPLICATE_OR_SKEW_REVIEW'
          WHEN [AverageChainLength]>@HashAvgChainWarn AND [EmptyBucketPercent]<@HashMinEmptyBucketPercent THEN 'HASH_BUCKET_COUNT_REVIEW'
          WHEN [MaxChainLength]>=@HashMaxChainWarn THEN 'HASH_MAX_CHAIN_REVIEW'
          WHEN [EmptyBucketPercent]<@HashMinEmptyBucketPercent THEN 'LOW_EMPTY_BUCKET_PERCENT_REVIEW'
          ELSE NULL END,
        [EvidenceLimit]=CASE
          WHEN [RuntimeStatsStatus]='AVAILABLE' THEN N'Bucket- und Kettenwerte sind Momentaufnahmen. Lange Ketten können durch Bucket-Anzahl, Duplikate oder Datenverteilung entstehen; daraus folgt keine automatische DDL.'
          ELSE [EvidenceLimit] END;

    INSERT [#InMemoryOltpAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[IndexName],[Severity],[Confidence],[FindingCode],
     [MetricName],[MetricValue],[ThresholdValue],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],NULL,'INFO','MEDIUM',[FindingCode],
           'TOTAL_USED_MB',[TotalUsedMb],@MinTableMemoryMb,
           N'Die speicheroptimierte Tabelle überschreitet den konfigurierten Kontextgrenzwert.',[EvidenceLimit],
           N'Poolbindung, Gesamt-XTP-Speicher, Wachstum und Workloadverlauf gemeinsam prüfen.'
    FROM [#InMemoryOltpAnalysis_TableMemory]
    WHERE [FindingCode]='LARGE_MEMORY_CONSUMER_CONTEXT';

    INSERT [#InMemoryOltpAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[IndexName],[Severity],[Confidence],[FindingCode],
     [MetricName],[MetricValue],[ThresholdValue],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[SchemaName],[TableName],[IndexName],'WARN','MEDIUM',[FindingCode],
           CASE WHEN [FindingCode]='LOW_EMPTY_BUCKET_PERCENT_REVIEW' THEN 'EMPTY_BUCKET_PERCENT'
                WHEN [FindingCode]='HASH_MAX_CHAIN_REVIEW' THEN 'MAX_CHAIN_LENGTH'
                ELSE 'AVERAGE_CHAIN_LENGTH' END,
           CASE WHEN [FindingCode]='LOW_EMPTY_BUCKET_PERCENT_REVIEW' THEN [EmptyBucketPercent]
                WHEN [FindingCode]='HASH_MAX_CHAIN_REVIEW' THEN [MaxChainLength]
                ELSE [AverageChainLength] END,
           CASE WHEN [FindingCode]='LOW_EMPTY_BUCKET_PERCENT_REVIEW' THEN @HashMinEmptyBucketPercent
                WHEN [FindingCode]='HASH_MAX_CHAIN_REVIEW' THEN @HashMaxChainWarn
                ELSE @HashAvgChainWarn END,
           N'Die opt-in Hashindex-Momentaufnahme überschreitet mindestens einen konfigurierten Prüfgrenzwert.',[EvidenceLimit],
           N'Bucket-Leeranteil, mittlere und maximale Kettenlänge, Duplikate sowie Abfrageprädikate zusammen prüfen; keine automatische DDL ableiten.'
    FROM [#InMemoryOltpAnalysis_HashIndex]
    WHERE [Severity]='WARN';

    INSERT [#InMemoryOltpAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','LOW',[FindingCode],'CHECKPOINT_FILE_SIZE_MB',[FileSizeMb],@WaitingCheckpointWarnMb,
           N'Checkpoint-Dateien im Zustand WAITING FOR LOG TRUNCATION überschreiten den konfigurierten Momentaufnahmegrenzwert.',[EvidenceLimit],
           N'Wiederholte Messung, log_reuse_wait_desc, Log-Backupkette und Merge-Fortschritt korrelieren.'
    FROM [#InMemoryOltpAnalysis_Checkpoint] WHERE [Severity]='WARN';

    INSERT [#InMemoryOltpAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','LOW',[FindingCode],'ACTIVE_OR_VALIDATING_TRANSACTION_COUNT',[TransactionCount],@ActiveTransactionWarnCount,
           N'Aktive oder validierende XTP-Transaktionen überschreiten den konfigurierten Momentaufnahmegrenzwert.',[EvidenceLimit],
           N'Über Zeit wiederholen und mit zulässiger Laufzeit-, Konflikt- und Workload-Evidenz korrelieren.'
    FROM [#InMemoryOltpAnalysis_Transaction] WHERE [Severity]='WARN';

    INSERT [#InMemoryOltpAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','MEDIUM',[FindingCode],
           CASE WHEN [FindingCode]='POOL_OUT_OF_MEMORY_RECORDED' THEN 'OUT_OF_MEMORY_COUNT' ELSE 'POOL_USED_PERCENT_OF_TARGET' END,
           CASE WHEN [FindingCode]='POOL_OUT_OF_MEMORY_RECORDED' THEN [OutOfMemoryCount] ELSE [UsedPercentOfTarget] END,
           CASE WHEN [FindingCode]='POOL_OUT_OF_MEMORY_RECORDED' THEN 0 ELSE @PoolUsedWarnPercent END,
           N'Der zugeordnete oder gemeinsame Resource-Governor-Pool zeigt einen konfigurierten Druckindikator.',[EvidenceLimit],
           N'Poolfreigaben, geteilte Nutzung, Serverspeicher und Zeitverlauf prüfen; keine datenbankgenaue Attribution aus dem Poolwert ableiten.'
    FROM [#InMemoryOltpAnalysis_ResourcePool] WHERE [Severity]='WARN';

    INSERT [#InMemoryOltpAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','XTP_EVIDENCE_GAP',[SourceCode],
           COALESCE([ErrorMessage],N'Die angeforderte Quelle ist nicht verfügbar.'),
           [Detail],N'Berechtigung, Featureverfügbarkeit und Analysis-Class-Policy prüfen; andere Resultsets bleiben gültig.'
    FROM [#InMemoryOltpAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

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
                      WHEN [ds].[StatusCode]='PENDING' THEN N'Kein konfigurierter Warnindikator in der zugänglichen Momentaufnahme; dies beweist keinen fehlerfreien Zustand.'
                      ELSE [ds].[Detail] END
    FROM [#InMemoryOltpAnalysis_DatabaseStatus] [ds]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FailureCount]
        FROM [#InMemoryOltpAnalysis_SourceStatus] [ss]
        WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1
    ) [x]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FindingCount],
               COALESCE(SUM(CASE WHEN [ff].[Severity]='WARN' THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),0) AS [WarnCount]
        FROM [#InMemoryOltpAnalysis_Findings] [ff]
        WHERE [ff].[DatabaseName]=[ds].[DatabaseName]
    ) [f];

    IF @StatusCode='AVAILABLE'
    BEGIN
        IF EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_DatabaseStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        ELSE IF EXISTS(SELECT 1 FROM [#InMemoryOltpAnalysis_Findings] WHERE [Severity]='WARN')
            SET @StatusCode='AVAILABLE_WITH_FINDING';
        ELSE IF NOT EXISTS
        (
            SELECT 1 FROM [#InMemoryOltpAnalysis_FeatureScope]
            WHERE [MemoryOptimizedTableCount]+[MemoryOptimizedTableTypeCount]+[MemoryOptimizedFilegroupCount]>0
        )
            SET @StatusCode='NOT_APPLICABLE';
    END;

    SELECT @ErrorNumber=COALESCE(@ErrorNumber,MIN([ErrorNumber])),
           @ErrorMessage=COALESCE(@ErrorMessage,MIN([ErrorMessage]))
    FROM [#InMemoryOltpAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    IF @JsonErzeugen=1
    BEGIN
        SELECT @Json=(
            SELECT
                JSON_QUERY((SELECT N'USP_InMemoryOltpAnalysis' AS [module],@Now AS [collectedAtUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@ErrorNumber AS [errorNumber],@ErrorMessage AS [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS [meta],
                JSON_QUERY(COALESCE((SELECT * FROM [#InMemoryOltpAnalysis_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH),N'[]')) AS [databaseStatus],
                JSON_QUERY(COALESCE((SELECT * FROM [#InMemoryOltpAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode] FOR JSON PATH),N'[]')) AS [sourceStatus],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal] FOR JSON PATH),N'[]')) AS [findings],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_TableMemory] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY [TotalUsedMb] DESC,[DatabaseName],[SchemaName],[TableName] FOR JSON PATH),N'[]')) AS [tableMemory],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_HashIndex] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName],[SchemaName],[TableName],[IndexName] FOR JSON PATH),N'[]')) AS [hashIndexes],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_MemoryConsumer] WHERE @NurProblematisch=0 ORDER BY [UsedMb] DESC,[DatabaseName] FOR JSON PATH),N'[]')) AS [memoryConsumers],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_Checkpoint] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName],[State],[FileType] FOR JSON PATH),N'[]')) AS [checkpointFiles],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_Transaction] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName],[TransactionState] FOR JSON PATH),N'[]')) AS [transactions],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_ResourcePool] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName] FOR JSON PATH),N'[]')) AS [resourcePools]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
    END;

    IF @OutputMode<>'NONE'
    BEGIN
        SELECT N'USP_InMemoryOltpAnalysis' AS [Module],@Now AS [CollectedAtUtc],@StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],
               N'Momentaufnahme und Prüfhinweise; keine automatische DDL-, Daten- oder Gesundheitsentscheidung.' AS [Detail];
        SELECT * FROM [#InMemoryOltpAnalysis_DatabaseStatus] ORDER BY [DatabaseName];
        SELECT * FROM [#InMemoryOltpAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode];
        SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_Findings]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal];
        SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_TableMemory]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY [TotalUsedMb] DESC,[DatabaseName],[SchemaName],[TableName];
        SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_HashIndex]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName],[SchemaName],[TableName],[IndexName];
        SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_MemoryConsumer]
        WHERE @NurProblematisch=0
        ORDER BY [UsedMb] DESC,[DatabaseName];
        SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_Checkpoint]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName],[State],[FileType];
        SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_Transaction]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName],[TransactionState];
        SELECT TOP(@Limit) * FROM [#InMemoryOltpAnalysis_ResourcePool]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[DatabaseName];
    END;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=LEFT(CONCAT(N'USP_InMemoryOltpAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe strukturierte Quellenstatus.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#InMemoryOltpAnalysis_Findings'
            , @ResultLabel=N'InMemoryOltpAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#InMemoryOltpAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
