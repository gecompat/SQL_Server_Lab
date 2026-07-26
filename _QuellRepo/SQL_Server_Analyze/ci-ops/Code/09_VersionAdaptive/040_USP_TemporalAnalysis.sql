USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_TemporalAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Typ          : Stored Procedure
Zweck        : Analysiert sichtbare systemversionierte Temporal Tables,
               Retention-Konfiguration, ungefähre Kapazität und die
               Perioden-Indexabdeckung ihrer History-Tabellen.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.tables, sys.schemas, sys.periods, sys.columns, sys.databases,
               sys.indexes, sys.index_columns und sys.dm_db_partition_stats.
Methodik     : Feature-Gate und jede abhängige Quelle werden datenbankweise
               best effort ausgewertet. Fehlende Rechte verwerfen andere
               zugängliche Evidenz nicht.
Grenzen      : Keine Zeilen aus aktuellen oder historischen Benutzertabellen,
               keine DBCC-Prüfung und keine DDL. Katalog- und Größenmetadaten
               beweisen weder Periodenüberlappungsfreiheit noch erfolgreichen
               Cleanup. Nach SYSTEM_VERSIONING=OFF getrennte Tabellen sind ohne
               erhaltene Zuordnung nicht zuverlässig als ehemaliges Paar
               erkennbar.
Kosten       : MEDIUM; Katalogabfragen und approximative Partitionsstatistik.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_TemporalAnalysis]
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
    , @HistorySizeWarnMb                decimal(19,2)  = 10240
    , @HistoryRowsWarn                  bigint         = 10000000
    , @HistoryToCurrentRatioWarn        decimal(19,4)  = 10
    , @MinHistoryMbForRatioWarn         decimal(19,2)  = 100
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
        PRINT N'monitor.USP_TemporalAnalysis';
        PRINT N'Die Procedure führt eine rein lesende Tiefenanalyse sichtbarer systemversionierter Temporal Tables und zugeordneter History-Tabellen durch.';
        PRINT N'Geprüft werden Katalogzuordnung, Periodenmetadaten, Retention-Schalter, approximative Größe/Zeilen und History-Indexreihenfolge End/Start.';
        PRINT N'Exakte Namenslisten und Pattern derselben Eigenschaft sind gegenseitig exklusiv; Pattern: LIKE, regex: oder regexi:.';
        PRINT N'Grenzwerte erzeugen Prüfkontext, keine automatische Retention-, DDL- oder Kapazitätsentscheidung.';
        PRINT N'@ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson; @JsonErzeugen=1 erzeugt @Json OUTPUT.';
        PRINT N'Es werden keine Zeilen aus aktuellen oder historischen Benutzertabellen gelesen und keine zeitliche Datenkonsistenz behauptet.';
        RETURN;
    END;

    IF @SystemdatenbankenEinbeziehen IS NULL OR @NurProblematisch IS NULL
       OR @JsonErzeugen IS NULL OR @PrintMeldungen IS NULL
       OR @HistorySizeWarnMb IS NULL OR @HistorySizeWarnMb<0
       OR @HistoryRowsWarn IS NULL OR @HistoryRowsWarn<0
       OR @HistoryToCurrentRatioWarn IS NULL OR @HistoryToCurrentRatioWarn<=0
       OR @MinHistoryMbForRatioWarn IS NULL OR @MinHistoryMbForRatioWarn<0

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

    CREATE TABLE [#TemporalAnalysis_NameFilters]
    (
          [FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [ItemOrdinal] int NOT NULL
        , [NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
    );
    CREATE TABLE [#TemporalAnalysis_DatabaseCandidates]
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
    CREATE TABLE [#TemporalAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NOT NULL
    );
    CREATE TABLE [#TemporalAnalysis_FeatureScope]
    (
          [DatabaseName] sysname NOT NULL PRIMARY KEY
        , [TemporalTableCount] bigint NOT NULL
        , [HistoryTableCount] bigint NOT NULL
    );
    CREATE TABLE [#TemporalAnalysis_DatabaseStatus]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [TemporalTableCount] bigint NOT NULL
        , [HistoryTableCount] bigint NOT NULL
        , [SourceFailureCount] int NOT NULL
        , [FindingCount] bigint NOT NULL
        , [RequiredPermission] nvarchar(256) NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#TemporalAnalysis_SourceStatus]
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
    CREATE TABLE [#TemporalAnalysis_TemporalTable]
    (
          [DatabaseName] sysname NOT NULL
        , [CurrentSchemaName] sysname NOT NULL
        , [CurrentTableName] sysname NOT NULL
        , [CurrentObjectId] int NOT NULL
        , [HistorySchemaName] sysname NULL
        , [HistoryTableName] sysname NULL
        , [HistoryObjectId] int NULL
        , [PeriodStartColumnName] sysname NULL
        , [PeriodEndColumnName] sysname NULL
        , [PeriodStartIsHidden] bit NULL
        , [PeriodEndIsHidden] bit NULL
        , [CurrentIsMemoryOptimized] bit NOT NULL
        , [CurrentDurabilityDesc] nvarchar(60) NULL
        , [DatabaseRetentionEnabled] bit NULL
        , [HistoryRetentionPeriod] int NULL
        , [HistoryRetentionUnitDesc] nvarchar(10) NULL
        , [RetentionMode] varchar(16) NOT NULL
        , [CurrentRowsApprox] bigint NULL
        , [HistoryRowsApprox] bigint NULL
        , [CurrentReservedMb] decimal(19,2) NULL
        , [CurrentUsedMb] decimal(19,2) NULL
        , [HistoryReservedMb] decimal(19,2) NULL
        , [HistoryUsedMb] decimal(19,2) NULL
        , [HistoryToCurrentRowRatio] decimal(19,4) NULL
        , [HistoryIndexCount] int NULL
        , [HasPeriodLeadingHistoryIndex] bit NULL
        , [AssessmentStatus] varchar(32) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , PRIMARY KEY ([DatabaseName],[CurrentObjectId])
    );
    CREATE TABLE [#TemporalAnalysis_HistoryIndex]
    (
          [DatabaseName] sysname NOT NULL
        , [CurrentSchemaName] sysname NOT NULL
        , [CurrentTableName] sysname NOT NULL
        , [HistorySchemaName] sysname NOT NULL
        , [HistoryTableName] sysname NOT NULL
        , [IndexName] sysname NULL
        , [IndexId] int NOT NULL
        , [IndexTypeDesc] nvarchar(60) NOT NULL
        , [IsUnique] bit NOT NULL
        , [IsDisabled] bit NOT NULL
        , [FirstKeyColumnName] sysname NULL
        , [SecondKeyColumnName] sysname NULL
        , [IsPeriodLeadingIndex] bit NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#TemporalAnalysis_Findings]
    (
          [FindingOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [DatabaseName] sysname NULL
        , [SchemaName] sysname NULL
        , [ObjectName] sysname NULL
        , [HistorySchemaName] sysname NULL
        , [HistoryTableName] sysname NULL
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

    -- Lokale TempDB-DDL soll nicht an einer flüchtigen Metadatenkollision mit
    -- dem für fachliche Quellen gewünschten NOWAIT-Vertrag scheitern. Erst
    -- nach vollständiger Materialisierung der Arbeitsstrukturen wird NOWAIT
    -- für die leichten Framework-/Katalogzugriffe aktiviert. Die isolierten
    -- datenbanklokalen Child-Batches verwenden weiterhin @LockTimeoutMs.
    SET LOCK_TIMEOUT 0;

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
            , @ErrorMessage=@ErrorMessage OUTPUT,@FilterTable=N'#TemporalAnalysis_NameFilters';
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
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#TemporalAnalysis_DatabaseCandidates',@WarningTable=N'#TemporalAnalysis_DatabaseCandidateWarnings';
        IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;
    END;

    INSERT [#TemporalAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[TemporalTableCount],[HistoryTableCount],
     [SourceFailureCount],[FindingCount],[Detail])
    SELECT [DatabaseName],'PENDING',0,0,0,0,0,
           N'Feature-Gate und Temporal-Quellen werden datenbankweise best effort ausgewertet.'
    FROM [#TemporalAnalysis_DatabaseCandidates];

    INSERT [#TemporalAnalysis_DatabaseStatus]
    ([DatabaseName],[StatusCode],[IsPartial],[TemporalTableCount],[HistoryTableCount],
     [SourceFailureCount],[FindingCount],[ErrorMessage],[Detail])
    SELECT [RequestedName],[StatusCode],1,0,0,1,0,[ErrorMessage],N'Explizit angeforderte Datenbank nicht auswertbar.'
    FROM [#TemporalAnalysis_DatabaseCandidateWarnings];

    IF @StatusCode='AVAILABLE' AND NOT EXISTS(SELECT 1 FROM [#TemporalAnalysis_DatabaseCandidates])
    BEGIN
        SELECT @StatusCode='NOT_APPLICABLE',@ErrorMessage=N'Keine auswertbare Datenbank im gewählten Scope.';
    END;

    DECLARE @SchemaPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#TemporalAnalysis_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#TemporalAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @ObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#TemporalAnalysis_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#TemporalAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    DECLARE @FullObjectPredicate nvarchar(max)=
        N' AND (NOT EXISTS(SELECT 1 FROM [#TemporalAnalysis_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#TemporalAnalysis_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDatabaseName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[t].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
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
            FROM [#TemporalAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];
        OPEN [DatabaseCursor];
        FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;

        WHILE @@FETCH_STATUS=0
        BEGIN
            IF (@SchemaPatternMode IN('REGEX','REGEXI') OR @ObjectPatternMode IN('REGEX','REGEXI'))
               AND COALESCE(@CompatibilityLevel,0)<170
            BEGIN
                UPDATE [#TemporalAnalysis_DatabaseStatus]
                SET [StatusCode]='UNAVAILABLE_FEATURE',[IsPartial]=1,[SourceFailureCount]=1,
                    [ErrorMessage]=N'Regex-Pattern benötigen Compatibility Level 170.',
                    [Detail]=N'Für diese Datenbank wurde wegen inkompatiblem Patternvertrag keine Analyse ausgeführt.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'FILTER_CONTRACT','UNAVAILABLE_FEATURE',1,0,NULL,NULL,
                       N'Regex-Pattern benötigen Compatibility Level 170.',N'Keine Quellenabfrage ausgeführt.');
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#TemporalAnalysis_FeatureScope]([DatabaseName],[TemporalTableCount],[HistoryTableCount])
SELECT @pDatabaseName,
       COALESCE(SUM(CASE WHEN [temporal_type]=2 THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),0),
       COALESCE(SUM(CASE WHEN [temporal_type]=1 THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),0)
FROM [sys].[tables] WITH (NOLOCK)
WHERE [is_ms_shipped]=0;
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_FEATURE_GATE','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sichtbare Datenbankmetadaten',NULL,NULL,
                       N'Zählt sichtbare aktuelle Temporal- und zugeordnete History-Tabellen; keine Nutzdaten.');
                UPDATE [ds]
                SET [TemporalTableCount]=[fs].[TemporalTableCount],
                    [HistoryTableCount]=[fs].[HistoryTableCount]
                FROM [#TemporalAnalysis_DatabaseStatus] [ds]
                JOIN [#TemporalAnalysis_FeatureScope] [fs] ON [fs].[DatabaseName]=[ds].[DatabaseName]
                WHERE [ds].[DatabaseName]=@DbName;
            END TRY
            BEGIN CATCH
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_FEATURE_GATE','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sichtbare Datenbankmetadaten',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Feature-Sichtbarkeit konnte nicht bestimmt werden.');
                UPDATE [#TemporalAnalysis_DatabaseStatus]
                SET [StatusCode]='ERROR_HANDLED',[IsPartial]=1,[SourceFailureCount]=[SourceFailureCount]+1,
                    [ErrorNumber]=ERROR_NUMBER(),[ErrorMessage]=ERROR_MESSAGE(),
                    [Detail]=N'Feature-Gate fehlgeschlagen; keine belastbare Anwendbarkeitsaussage.'
                WHERE [DatabaseName]=@DbName;
            END CATCH;

            IF NOT EXISTS(SELECT 1 FROM [#TemporalAnalysis_FeatureScope] WHERE [DatabaseName]=@DbName)
            BEGIN
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            IF EXISTS
            (
                SELECT 1 FROM [#TemporalAnalysis_FeatureScope]
                WHERE [DatabaseName]=@DbName AND [TemporalTableCount]=0
            )
            BEGIN
                UPDATE [#TemporalAnalysis_DatabaseStatus]
                SET [StatusCode]='NOT_APPLICABLE_VISIBLE_SCOPE',[IsPartial]=0,
                    [Detail]=N'Im sichtbaren Katalogscope wurde keine aktive systemversionierte Temporal Table erkannt; dies beweist keine vollständige Abwesenheit und erkennt keine früher getrennten Tabellenpaare.'
                WHERE [DatabaseName]=@DbName;
                INSERT [#TemporalAnalysis_SourceStatus]
                SELECT @DbName,[SourceCode],'NOT_APPLICABLE',0,0,[RequiredPermission],NULL,NULL,
                       N'Quelle wegen negativem sichtbaren Feature-Gate nicht aufgerufen.'
                FROM (VALUES
                      ('TEMPORAL_CATALOG',N'Katalogsicht auf sichtbare Tabellen, Perioden und Spalten'),
                      ('TEMPORAL_CAPACITY',N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION'),
                      ('TEMPORAL_HISTORY_INDEX',N'Katalogsicht auf sichtbare Indizes und Indexspalten'))
                     [x]([SourceCode],[RequiredPermission]);
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#TemporalAnalysis_TemporalTable]
([DatabaseName],[CurrentSchemaName],[CurrentTableName],[CurrentObjectId],
 [HistorySchemaName],[HistoryTableName],[HistoryObjectId],
 [PeriodStartColumnName],[PeriodEndColumnName],[PeriodStartIsHidden],[PeriodEndIsHidden],
 [CurrentIsMemoryOptimized],[CurrentDurabilityDesc],[DatabaseRetentionEnabled],
 [HistoryRetentionPeriod],[HistoryRetentionUnitDesc],[RetentionMode],
 [AssessmentStatus],[EvidenceLimit])
SELECT @pDatabaseName,[s].[name],[t].[name],[t].[object_id],
       [hs].[name],[h].[name],[t].[history_table_id],
       [pcStart].[name],[pcEnd].[name],[pcStart].[is_hidden],[pcEnd].[is_hidden],
       [t].[is_memory_optimized],[t].[durability_desc],[d].[is_temporal_history_retention_enabled],
       [t].[history_retention_period],[t].[history_retention_period_unit_desc],
       CASE WHEN [t].[history_retention_period_unit]=-1 THEN ''INFINITE''
            WHEN [t].[history_retention_period] IS NULL THEN ''UNAVAILABLE'' ELSE ''FINITE'' END,
       ''AVAILABLE'',
       N''Katalog- und Konfigurationsevidenz beweist keine Zeilenkonsistenz, Cleanup-Ausführung oder vollständige Metadatensichtbarkeit.''
FROM [sys].[tables] [t] WITH (NOLOCK)
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
LEFT JOIN [sys].[tables] [h] WITH (NOLOCK) ON [h].[object_id]=[t].[history_table_id]
LEFT JOIN [sys].[schemas] [hs] WITH (NOLOCK) ON [hs].[schema_id]=[h].[schema_id]
LEFT JOIN [sys].[periods] [p] WITH (NOLOCK) ON [p].[object_id]=[t].[object_id] AND [p].[period_type]=1
LEFT JOIN [sys].[columns] [pcStart] WITH (NOLOCK) ON [pcStart].[object_id]=[p].[object_id] AND [pcStart].[column_id]=[p].[start_column_id]
LEFT JOIN [sys].[columns] [pcEnd] WITH (NOLOCK) ON [pcEnd].[object_id]=[p].[object_id] AND [pcEnd].[column_id]=[p].[end_column_id]
OUTER APPLY
(
    SELECT [is_temporal_history_retention_enabled]
    FROM [sys].[databases] WITH (NOLOCK)
    WHERE [database_id]=DB_ID()
) [d]
WHERE [t].[is_ms_shipped]=0 AND [t].[temporal_type]=2'+@SchemaPredicate+@ObjectPredicate+@FullObjectPredicate+N';
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_CATALOG','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sichtbare Tabellen, Perioden und Spalten',NULL,NULL,
                       N'Aktive Zuordnung, Periodenspalten und Retention-Konfiguration; Nullzeilen können aus Filtern oder Metadatensichtbarkeit folgen.');
            END TRY
            BEGIN CATCH
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_CATALOG','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sichtbare Tabellen, Perioden und Spalten',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Kapazitäts- und Indexquellen benötigen die Katalogzuordnung und werden für diese Datenbank ausgelassen.');
            END CATCH;

            IF EXISTS
            (
                SELECT 1 FROM [#TemporalAnalysis_SourceStatus]
                WHERE [DatabaseName]=@DbName AND [SourceCode]='TEMPORAL_CATALOG' AND [IsPartial]=1
            )
            BEGIN
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES
                (@DbName,'TEMPORAL_CAPACITY','UNAVAILABLE_DEPENDENCY',1,0,
                 N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION',
                 NULL,N'TEMPORAL_CATALOG ist nicht verfügbar.',N'Keine Partitionsstatistik ohne belastbare Objektzuordnung.'),
                (@DbName,'TEMPORAL_HISTORY_INDEX','UNAVAILABLE_DEPENDENCY',1,0,
                 N'Katalogsicht auf sichtbare Indizes und Indexspalten',NULL,
                 N'TEMPORAL_CATALOG ist nicht verfügbar.',N'Keine Indexbewertung ohne belastbare Perioden- und History-Zuordnung.');
                FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
                CONTINUE;
            END;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
UPDATE [tt]
SET [CurrentRowsApprox]=[c].[RowCountApprox],
    [CurrentReservedMb]=[c].[ReservedMb],
    [CurrentUsedMb]=[c].[UsedMb],
    [HistoryRowsApprox]=[h].[RowCountApprox],
    [HistoryReservedMb]=[h].[ReservedMb],
    [HistoryUsedMb]=[h].[UsedMb],
    [HistoryToCurrentRowRatio]=CASE WHEN [tt].[CurrentIsMemoryOptimized]=0 AND [c].[RowCountApprox]>0
                                    THEN CONVERT(decimal(19,4),CONVERT(decimal(38,4),[h].[RowCountApprox])/[c].[RowCountApprox]) END
FROM [#TemporalAnalysis_TemporalTable] [tt]
OUTER APPLY
(
    SELECT SUM(CASE WHEN [index_id] IN(0,1) THEN CONVERT(bigint,[row_count]) END) AS [RowCountApprox],
           CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[reserved_page_count]))*8.0/1024.0) AS [ReservedMb],
           CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[used_page_count]))*8.0/1024.0) AS [UsedMb]
    FROM [sys].[dm_db_partition_stats] WITH (NOLOCK)
    WHERE [object_id]=[tt].[CurrentObjectId]
) [c]
OUTER APPLY
(
    SELECT SUM(CASE WHEN [index_id] IN(0,1) THEN CONVERT(bigint,[row_count]) END) AS [RowCountApprox],
           CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[reserved_page_count]))*8.0/1024.0) AS [ReservedMb],
           CONVERT(decimal(19,2),SUM(CONVERT(decimal(38,2),[used_page_count]))*8.0/1024.0) AS [UsedMb]
    FROM [sys].[dm_db_partition_stats] WITH (NOLOCK)
    WHERE [object_id]=[tt].[HistoryObjectId]
) [h]
WHERE [tt].[DatabaseName]=@pDatabaseName;
SET @pRows=@@ROWCOUNT;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_CAPACITY','AVAILABLE',0,@Rows,
                       N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION',NULL,NULL,
                       N'Approximative Zeilen und Seiten aller Indizes; keine Tabellenzeilen. Current-Ratio wird für speicheroptimierte aktuelle Tabellen nicht behauptet.');
            END TRY
            BEGIN CATCH
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_CAPACITY','ERROR_HANDLED',1,0,
                       N'VIEW DATABASE STATE und VIEW DEFINITION; SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE und VIEW SECURITY DEFINITION',
                       ERROR_NUMBER(),ERROR_MESSAGE(),N'Katalog- und Indexevidenz bleiben verfügbar.');
            END CATCH;

            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#TemporalAnalysis_HistoryIndex]
SELECT [tt].[DatabaseName],[tt].[CurrentSchemaName],[tt].[CurrentTableName],
       [tt].[HistorySchemaName],[tt].[HistoryTableName],[i].[name],[i].[index_id],[i].[type_desc],
       [i].[is_unique],[i].[is_disabled],[k].[FirstKeyColumnName],[k].[SecondKeyColumnName],
       CONVERT(bit,CASE WHEN [i].[type] IN(1,2) AND [i].[is_disabled]=0
                            AND [k].[FirstKeyColumnName]=[tt].[PeriodEndColumnName]
                            AND [k].[SecondKeyColumnName]=[tt].[PeriodStartColumnName]
                        THEN 1 ELSE 0 END),
       N''Bewertet nur die dokumentierte führende Schlüsselreihenfolge Periodenende/Periodenstart; keine Workload-, Selektivitäts- oder Plananalyse.''
FROM [#TemporalAnalysis_TemporalTable] [tt]
JOIN [sys].[indexes] [i] WITH (NOLOCK)
  ON [i].[object_id]=[tt].[HistoryObjectId] AND [i].[index_id]>0 AND [i].[is_hypothetical]=0
OUTER APPLY
(
    SELECT MAX(CASE WHEN [ic].[key_ordinal]=1 THEN [c].[name] END) AS [FirstKeyColumnName],
           MAX(CASE WHEN [ic].[key_ordinal]=2 THEN [c].[name] END) AS [SecondKeyColumnName]
    FROM [sys].[index_columns] [ic] WITH (NOLOCK)
    JOIN [sys].[columns] [c] WITH (NOLOCK)
      ON [c].[object_id]=[ic].[object_id] AND [c].[column_id]=[ic].[column_id]
    WHERE [ic].[object_id]=[i].[object_id] AND [ic].[index_id]=[i].[index_id]
) [k]
WHERE [tt].[DatabaseName]=@pDatabaseName
  AND [tt].[HistorySchemaName] IS NOT NULL AND [tt].[HistoryTableName] IS NOT NULL;
SET @pRows=@@ROWCOUNT;

UPDATE [tt]
SET [HistoryIndexCount]=[x].[IndexCount],
    [HasPeriodLeadingHistoryIndex]=[x].[HasPeriodLeading]
FROM [#TemporalAnalysis_TemporalTable] [tt]
OUTER APPLY
(
    SELECT COUNT(*) AS [IndexCount],
           CONVERT(bit,COALESCE(MAX(CONVERT(tinyint,[hi].[IsPeriodLeadingIndex])),0)) AS [HasPeriodLeading]
    FROM [#TemporalAnalysis_HistoryIndex] [hi]
    WHERE [hi].[DatabaseName]=[tt].[DatabaseName]
      AND [hi].[CurrentSchemaName]=[tt].[CurrentSchemaName]
      AND [hi].[CurrentTableName]=[tt].[CurrentTableName]
) [x]
WHERE [tt].[DatabaseName]=@pDatabaseName;';
                SET @Rows=0;
                EXEC [sys].[sp_executesql] @Sql,N'@pDatabaseName sysname,@pRows bigint OUTPUT',
                     @pDatabaseName=@DbName,@pRows=@Rows OUTPUT;
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_HISTORY_INDEX','AVAILABLE',0,@Rows,
                       N'Katalogsicht auf sichtbare Indizes und Indexspalten',NULL,NULL,
                       N'Indexmetadaten ohne Schlüsselwerte; bewertet ausschließlich eine dokumentierte Baseline, keine endgültige Indexeignung.');
            END TRY
            BEGIN CATCH
                INSERT [#TemporalAnalysis_SourceStatus]
                VALUES(@DbName,'TEMPORAL_HISTORY_INDEX','ERROR_HANDLED',1,0,
                       N'Katalogsicht auf sichtbare Indizes und Indexspalten',ERROR_NUMBER(),ERROR_MESSAGE(),
                       N'Katalog- und Kapazitätsevidenz bleiben verfügbar.');
            END CATCH;

            FETCH NEXT FROM [DatabaseCursor] INTO @DbName,@CompatibilityLevel;
        END;
        CLOSE [DatabaseCursor];
        DEALLOCATE [DatabaseCursor];
    END;

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[HistorySchemaName],[HistoryTableName],
     [Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CurrentSchemaName],[CurrentTableName],[HistorySchemaName],[HistoryTableName],
           'WARN','HIGH','HISTORY_TABLE_NOT_VISIBLE','HISTORY_OBJECT_VISIBLE',0,1,
           N'Die aktive Temporal-Metadatenzeile enthält keine vollständig sichtbare zugeordnete History-Tabelle.',
           [EvidenceLimit],
           N'Metadatensichtbarkeit und Berechtigungen prüfen; erst danach eine strukturelle Abweichung untersuchen.'
    FROM [#TemporalAnalysis_TemporalTable]
    WHERE [HistoryObjectId] IS NULL OR [HistorySchemaName] IS NULL OR [HistoryTableName] IS NULL;

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[HistorySchemaName],[HistoryTableName],
     [Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CurrentSchemaName],[CurrentTableName],[HistorySchemaName],[HistoryTableName],
           'WARN','HIGH','PERIOD_METADATA_INCOMPLETE','PERIOD_COLUMNS_VISIBLE',
           CONVERT(decimal(38,4),CASE WHEN [PeriodStartColumnName] IS NOT NULL THEN 1 ELSE 0 END+
                                      CASE WHEN [PeriodEndColumnName] IS NOT NULL THEN 1 ELSE 0 END),2,
           N'Für die sichtbare aktive Temporal Table sind Start- und Endspalte des SYSTEM_TIME-Periods nicht vollständig sichtbar.',
           [EvidenceLimit],
           N'Metadatensichtbarkeit und sys.periods/sys.columns-Zuordnung prüfen; keine Dateninkonsistenz daraus ableiten.'
    FROM [#TemporalAnalysis_TemporalTable]
    WHERE [PeriodStartColumnName] IS NULL OR [PeriodEndColumnName] IS NULL;

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[HistorySchemaName],[HistoryTableName],
     [Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CurrentSchemaName],[CurrentTableName],[HistorySchemaName],[HistoryTableName],
           'WARN','HIGH','RETENTION_CONFIGURED_DATABASE_CLEANUP_DISABLED','DATABASE_RETENTION_ENABLED',
           CONVERT(decimal(38,4),[DatabaseRetentionEnabled]),1,
           N'Eine endliche History-Retention ist konfiguriert, der datenbankweite automatische Temporal-Cleanup ist jedoch nicht aktiviert.',
           N'Der Schalter zeigt Konfiguration, nicht Ausführung, Fortschritt oder Löschberechtigung des Hintergrundtasks.',
           N'Datenbankoption, Restore-Historie und Cleanup-Fortschritt mit freigegebener Laufzeitevidenz prüfen.'
    FROM [#TemporalAnalysis_TemporalTable]
    WHERE [RetentionMode]='FINITE' AND [DatabaseRetentionEnabled]=0;

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[HistorySchemaName],[HistoryTableName],
     [Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CurrentSchemaName],[CurrentTableName],[HistorySchemaName],[HistoryTableName],
           'WARN','MEDIUM','HISTORY_PERIOD_INDEX_REVIEW','PERIOD_LEADING_HISTORY_INDEX',
           CONVERT(decimal(38,4),COALESCE([HasPeriodLeadingHistoryIndex],0)),1,
           N'Kein aktiver sichtbarer B-Tree-History-Index beginnt mit Periodenende und Periodenstart.',
           N'Die dokumentierte Baseline ist kein universelles Workload-Optimum; Columnstore, Partitionierung, Schreiblast und konkrete Pläne bleiben unbewertet.',
           N'History-Workload und vorhandene Indexstrategie prüfen; DDL nur nach messbarer Plan- und Wartungsbewertung ableiten.'
    FROM [#TemporalAnalysis_TemporalTable]
    WHERE [HistoryObjectId] IS NOT NULL
      AND [HistorySchemaName] IS NOT NULL AND [HistoryTableName] IS NOT NULL
      AND [PeriodStartColumnName] IS NOT NULL AND [PeriodEndColumnName] IS NOT NULL
      AND COALESCE([HasPeriodLeadingHistoryIndex],0)=0
      AND EXISTS
          (SELECT 1 FROM [#TemporalAnalysis_SourceStatus] [ss]
           WHERE [ss].[DatabaseName]=[#TemporalAnalysis_TemporalTable].[DatabaseName]
             AND [ss].[SourceCode]='TEMPORAL_HISTORY_INDEX' AND [ss].[IsPartial]=0);

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[HistorySchemaName],[HistoryTableName],
     [Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CurrentSchemaName],[CurrentTableName],[HistorySchemaName],[HistoryTableName],
           'INFO','MEDIUM','LARGE_HISTORY_SIZE_CONTEXT','HISTORY_RESERVED_MB',[HistoryReservedMb],@HistorySizeWarnMb,
           N'Die approximative reservierte History-Größe überschreitet den konfigurierten Kontextgrenzwert.',
           N'Pages sind approximativ und enthalten Tabellen- sowie Indexspeicher; Größe allein ist kein Fehler.',
           N'Wachstumsverlauf, Retentionsziel, Kompression, Partitionierung und Abfragebedarf gemeinsam bewerten.'
    FROM [#TemporalAnalysis_TemporalTable]
    WHERE [HistoryReservedMb]>=@HistorySizeWarnMb;

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[HistorySchemaName],[HistoryTableName],
     [Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CurrentSchemaName],[CurrentTableName],[HistorySchemaName],[HistoryTableName],
           'INFO','MEDIUM','LARGE_HISTORY_ROW_CONTEXT','HISTORY_ROWS_APPROX',[HistoryRowsApprox],@HistoryRowsWarn,
           N'Die approximative History-Zeilenzahl überschreitet den konfigurierten Kontextgrenzwert.',
           N'row_count ist approximativ; Zeilenvolumen allein beweist weder Cleanup-Rückstand noch Kapazitätsdruck.',
           N'Wiederholte Messungen, Änderungsrate, Retentionsziel und Speichertrend korrelieren.'
    FROM [#TemporalAnalysis_TemporalTable]
    WHERE [HistoryRowsApprox]>=@HistoryRowsWarn;

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[SchemaName],[ObjectName],[HistorySchemaName],[HistoryTableName],
     [Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],
     [Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],[CurrentSchemaName],[CurrentTableName],[HistorySchemaName],[HistoryTableName],
           'INFO','LOW','HISTORY_TO_CURRENT_RATIO_CONTEXT','HISTORY_TO_CURRENT_ROW_RATIO',
           [HistoryToCurrentRowRatio],@HistoryToCurrentRatioWarn,
           N'Das approximative Verhältnis History zu Current überschreitet den konfigurierten Kontextgrenzwert.',
           N'Das Verhältnis ist für leere/kleine oder speicheroptimierte Current-Tabellen nicht belastbar und sagt nichts über fachlich zulässige Historientiefe aus.',
           N'Retentionsanforderung, Änderungsrate, Alter der History und Zeitverlauf prüfen.'
    FROM [#TemporalAnalysis_TemporalTable]
    WHERE [HistoryReservedMb]>=@MinHistoryMbForRatioWarn
      AND [HistoryToCurrentRowRatio]>=@HistoryToCurrentRatioWarn;

    INSERT [#TemporalAnalysis_Findings]
    ([DatabaseName],[Severity],[Confidence],[FindingCode],[MetricName],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
    SELECT [DatabaseName],'WARN','HIGH','TEMPORAL_EVIDENCE_GAP',[SourceCode],
           COALESCE([ErrorMessage],N'Die angeforderte Quelle ist nicht verfügbar.'),
           [Detail],N'Berechtigung, Featureverfügbarkeit und Abhängigkeiten prüfen; andere Resultsets bleiben gültig.'
    FROM [#TemporalAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    UPDATE [tt]
    SET [AssessmentStatus]=CASE WHEN EXISTS
        (SELECT 1 FROM [#TemporalAnalysis_Findings] [f]
         WHERE [f].[DatabaseName]=[tt].[DatabaseName]
           AND [f].[SchemaName]=[tt].[CurrentSchemaName]
           AND [f].[ObjectName]=[tt].[CurrentTableName]
           AND [f].[Severity]='WARN') THEN 'REVIEW' ELSE 'AVAILABLE' END
    FROM [#TemporalAnalysis_TemporalTable] AS [tt];

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
                      WHEN [ds].[StatusCode]='PENDING' THEN N'Kein konfigurierter Warnindikator in der zugänglichen Metadatenaufnahme; dies beweist weder Datenkonsistenz noch erfolgreichen Cleanup.'
                      ELSE [ds].[Detail] END
    FROM [#TemporalAnalysis_DatabaseStatus] [ds]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FailureCount]
        FROM [#TemporalAnalysis_SourceStatus] [ss]
        WHERE [ss].[DatabaseName]=[ds].[DatabaseName] AND [ss].[IsPartial]=1
    ) [x]
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS [FindingCount],
               COALESCE(SUM(CASE WHEN [ff].[Severity]='WARN' THEN CONVERT(bigint,1) ELSE CONVERT(bigint,0) END),0) AS [WarnCount]
        FROM [#TemporalAnalysis_Findings] [ff]
        WHERE [ff].[DatabaseName]=[ds].[DatabaseName]
    ) [f];

    IF @StatusCode='AVAILABLE'
    BEGIN
        IF EXISTS(SELECT 1 FROM [#TemporalAnalysis_DatabaseStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        ELSE IF EXISTS(SELECT 1 FROM [#TemporalAnalysis_Findings] WHERE [Severity]='WARN')
            SET @StatusCode='AVAILABLE_WITH_FINDING';
        ELSE IF NOT EXISTS(SELECT 1 FROM [#TemporalAnalysis_FeatureScope] WHERE [TemporalTableCount]>0)
            SET @StatusCode='NOT_APPLICABLE';
    END;

    SELECT @ErrorNumber=COALESCE(@ErrorNumber,MIN([ErrorNumber])),
           @ErrorMessage=COALESCE(@ErrorMessage,MIN([ErrorMessage]))
    FROM [#TemporalAnalysis_SourceStatus]
    WHERE [IsPartial]=1;

    IF @JsonErzeugen=1
    BEGIN
        SELECT @Json=(
            SELECT
                JSON_QUERY((SELECT N'USP_TemporalAnalysis' AS [module],@Now AS [collectedAtUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@ErrorNumber AS [errorNumber],@ErrorMessage AS [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) AS [meta],
                JSON_QUERY(COALESCE((SELECT * FROM [#TemporalAnalysis_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH),N'[]')) AS [databaseStatus],
                JSON_QUERY(COALESCE((SELECT * FROM [#TemporalAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode] FOR JSON PATH),N'[]')) AS [sourceStatus],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#TemporalAnalysis_Findings] WHERE @NurProblematisch=0 OR [Severity]='WARN' ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal] FOR JSON PATH),N'[]')) AS [findings],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) * FROM [#TemporalAnalysis_TemporalTable] WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW' ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,[HistoryReservedMb] DESC,[DatabaseName],[CurrentSchemaName],[CurrentTableName] FOR JSON PATH),N'[]')) AS [temporalTables],
                JSON_QUERY(COALESCE((SELECT TOP(@Limit) [hi].* FROM [#TemporalAnalysis_HistoryIndex] [hi] WHERE @NurProblematisch=0 OR EXISTS(SELECT 1 FROM [#TemporalAnalysis_TemporalTable] [tt] WHERE [tt].[DatabaseName]=[hi].[DatabaseName] AND [tt].[CurrentSchemaName]=[hi].[CurrentSchemaName] AND [tt].[CurrentTableName]=[hi].[CurrentTableName] AND [tt].[AssessmentStatus]='REVIEW') ORDER BY [hi].[DatabaseName],[hi].[CurrentSchemaName],[hi].[CurrentTableName],[hi].[IndexId] FOR JSON PATH),N'[]')) AS [historyIndexes]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
    END;

    IF @OutputMode<>'NONE'
    BEGIN
        SELECT N'USP_TemporalAnalysis' AS [Module],@Now AS [CollectedAtUtc],@StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage],
               N'Read-only Metadatenaufnahme; keine Benutzertabellenzeilen, DBCC-, Cleanup- oder DDL-Ausführung.' AS [Detail];
        SELECT * FROM [#TemporalAnalysis_DatabaseStatus] ORDER BY [DatabaseName];
        SELECT * FROM [#TemporalAnalysis_SourceStatus] ORDER BY [DatabaseName],[SourceCode];
        SELECT TOP(@Limit) * FROM [#TemporalAnalysis_Findings]
        WHERE @NurProblematisch=0 OR [Severity]='WARN'
        ORDER BY CASE [Severity] WHEN 'WARN' THEN 1 ELSE 2 END,[FindingOrdinal];
        SELECT TOP(@Limit) * FROM [#TemporalAnalysis_TemporalTable]
        WHERE @NurProblematisch=0 OR [AssessmentStatus]='REVIEW'
        ORDER BY CASE [AssessmentStatus] WHEN 'REVIEW' THEN 1 ELSE 2 END,
                 [HistoryReservedMb] DESC,[DatabaseName],[CurrentSchemaName],[CurrentTableName];
        SELECT TOP(@Limit) [hi].* FROM [#TemporalAnalysis_HistoryIndex] [hi]
        WHERE @NurProblematisch=0 OR EXISTS
              (SELECT 1 FROM [#TemporalAnalysis_TemporalTable] [tt]
               WHERE [tt].[DatabaseName]=[hi].[DatabaseName]
                 AND [tt].[CurrentSchemaName]=[hi].[CurrentSchemaName]
                 AND [tt].[CurrentTableName]=[hi].[CurrentTableName]
                 AND [tt].[AssessmentStatus]='REVIEW')
        ORDER BY [hi].[DatabaseName],[hi].[CurrentSchemaName],[hi].[CurrentTableName],[hi].[IndexId];
    END;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=LEFT(CONCAT(N'USP_TemporalAnalysis: ',@StatusCode,N'. ',COALESCE(@ErrorMessage,N'Siehe strukturierte Quellenstatus.')),2048);
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#TemporalAnalysis_Findings'
            , @ResultLabel=N'TemporalAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#TemporalAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
