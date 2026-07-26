USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_Columnstore
Version      : 1.0.0
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Analysiert Columnstore-Indizes, Rowgroups und Deleted Rows; Physical Stats, Segmente und Dictionaries sind explizite gruppengeschützte Vertiefungen.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : Je Datenbank sys.column_store_row_groups, optional sys.dm_db_column_store_row_group_physical_stats, sys.column_store_segments, sys.column_store_dictionaries sowie Systemkataloge.
Parameter    :
  @DatabaseName                  sysname        = NULL  - Zieldatenbank; bei Einzelmodus Pflicht.
  @CrossDatabaseRequestedInternal               bit            = 0     - sichtbare Online-Datenbanken analysieren.
  @SystemdatenbankenEinbeziehen  bit            = 0     - master/model/msdb/tempdb einbeziehen.
  @DatenbankNameLike             nvarchar(256)  = NULL  - Filter im Cross-Database-Modus.
  @SchemaNamePattern                nvarchar(256)  = NULL  - LIKE-Filter auf Schema.
  @ObjectNamePattern                nvarchar(256)  = NULL  - LIKE-Filter auf Objekt.
  @MaxZeilen                     int            = 5000  - positive Werte begrenzen; NULL/0 = unbegrenzt.
  @LockTimeoutMs                 int            = 0     - 0 = nicht auf Metadatenlocks warten.
  @PrintMeldungen                bit            = 1     - Warnungen via RAISERROR 10.
  @Hilfe                         bit            = 0     - Hilfe via PRINT, keine Analyse.
  @AnalyseModus varchar(16) = 'GEZIELT' - GEZIELT benötigt Filter; VOLL prüft CATALOG_DEEP.
  @MitPhysicalStats bit=0 - zusätzliche Physical Rowgroup Stats; benötigt COLUMNSTORE_DEEP.
  @MitSegmenten bit=0 - Spaltensegmente; benötigt COLUMNSTORE_DEEP.
  @MitDictionaries bit=0 - Dictionaries; benötigt COLUMNSTORE_DEEP.
  @MinDeletedPercent decimal(9,2)=0 - Rowgroup-Filter.
  @NurProblematisch bit=0 - OPEN/CLOSED/TOMBSTONE oder Deleted Rows.
Resultsets   : 1. Modulstatus. 2. Status je Datenbank. 3. Katalog-Rowgroups. 4. Physical Rowgroups. 5. Segmente. 6. Dictionaries.
Berechtigung : Basis gemäß Metadata Visibility/VIEW DEFINITION; Physical Stats SQL 2019 VIEW DATABASE STATE plus CONTROL, SQL 2022+ VIEW DATABASE PERFORMANCE STATE; Detailwerte können SELECT erfordern.
Eigenlast    : Basis moderat; Segmentanzahl entspricht Rowgroups × Spalten und ist daher nur opt-in, gruppengeschützt und TOP-begrenzt.
Locking      : READUNCOMMITTED-Kataloge, LOCK_TIMEOUT; keine Wartungs-DDL.
Partial      : Fehler je Datenbank bzw. Teilquelle werden isoliert; vorhandene
               Teilergebnisse bleiben erhalten. Das Framework vergibt keine Rechte.
Beispiele    :
  EXEC monitor.USP_Columnstore @DatabaseNames=N'[SampleDatabase]', @ObjectNamePattern=N'like:Fact%';
  EXEC monitor.USP_Columnstore @DatabaseNames=N'[SampleDatabase]', @ObjectNamePattern=N'like:Fact%', @MinDeletedPercent=10, @NurProblematisch=1;
  EXEC monitor.USP_Columnstore @DatabaseNames=N'SampleDatabase', @AnalyseModus='VOLL', @MitPhysicalStats=1, @MitSegmenten=1;
  EXEC monitor.USP_Columnstore @Hilfe=1;
Änderungen   : 1.0.0 - Erstfassung Phase 2.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_Columnstore]
      @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @AnalyseModus                  varchar(16)   = 'GEZIELT'
    , @MitPhysicalStats               bit           = 0
    , @MitSegmenten                   bit           = 0
    , @MitDictionaries                bit           = 0
    , @MinDeletedPercent              decimal(9,2)  = 0
    , @NurProblematisch               bit           = 0
    , @MaxZeilen                      int           = 10000
    , @LockTimeoutMs                  int           = 0
    , @ResultSetArt                  varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                  bit            = 0
    , @Json                          nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit           = 1
    , @Hilfe                          bit           = 0
AS
BEGIN
 SET NOCOUNT ON;

    SET @Json = NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'rowgroups',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @DatabaseName sysname=NULL,@CrossDatabaseRequestedInternal bit=0,@DatenbankNameLike nvarchar(4000)=NULL;
    DECLARE @SchemaNameLike nvarchar(4000)=NULL,@ObjectNameLike nvarchar(4000)=NULL;
    DECLARE @SchemaPatternMode varchar(8),@SchemaPatternValue nvarchar(4000),@SchemaRegexFlags varchar(8),@SchemaPatternValid bit;
    DECLARE @ObjectPatternMode varchar(8),@ObjectPatternValue nvarchar(4000),@ObjectRegexFlags varchar(8),@ObjectPatternValid bit;
    SELECT @SchemaPatternMode=[PatternMode],@SchemaPatternValue=[PatternValue],@SchemaRegexFlags=[RegexFlags],@SchemaPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@SchemaNamePattern);
    SELECT @ObjectPatternMode=[PatternMode],@ObjectPatternValue=[PatternValue],@ObjectRegexFlags=[RegexFlags],@ObjectPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@ObjectNamePattern);
    IF @SchemaPatternMode='LIKE' SET @SchemaNameLike=@SchemaPatternValue;
    IF @ObjectPatternMode='LIKE' SET @ObjectNameLike=@ObjectPatternValue;
    DECLARE @IndexPatternMode varchar(8)='NONE',@IndexPatternValue nvarchar(4000)=NULL,@IndexRegexFlags varchar(8)=NULL,@IndexPatternValid bit=1;
    DECLARE @StatisticsPatternMode varchar(8)='NONE',@StatisticsPatternValue nvarchar(4000)=NULL,@StatisticsRegexFlags varchar(8)=NULL,@StatisticsPatternValid bit=1;
    DECLARE @DatabaseListCount int=0;
    IF @DatabaseNames IS NOT NULL AND NULLIF(LTRIM(RTRIM(@DatabaseNames)),N'') IS NOT NULL
        SELECT @DatabaseListCount=COUNT(*),@DatabaseName=MIN([NameValue]) FROM [monitor].[TVF_ParseSqlNameList](@DatabaseNames) WHERE [IsValid]=1;
    SET @CrossDatabaseRequestedInternal=CONVERT(bit,CASE WHEN @DatabaseNames IS NULL OR @DatabaseNamePattern IS NOT NULL OR @DatabaseListCount>1 THEN 1 ELSE 0 END);
    SELECT @DatenbankNameLike=CASE WHEN [PatternMode]='LIKE' THEN [PatternValue] END FROM [monitor].[TVF_ParsePattern](@DatabaseNamePattern);
    CREATE TABLE [#Columnstore_NameFilters]([FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL,[ItemOrdinal] int NOT NULL,[NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL);
    CREATE TABLE [#Columnstore_DatabaseCandidates]([DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60),[UserAccessDesc] nvarchar(60),[IsReadOnly] bit,[CompatibilityLevel] tinyint,[CollationName] sysname,[RecoveryModelDesc] nvarchar(60),[IsSystemDatabase] bit,[RequestedOrdinal] int);
    DECLARE @FilterStatus varchar(40)='AVAILABLE',@FilterError nvarchar(2048)=NULL,@CrossDatabaseRequested bit=0;
    EXEC [monitor].[USP_PrepareNameFilters] @SchemaNames=@SchemaNames,@ObjectNames=@ObjectNames,@FullObjectNames=@FullObjectNames,@IndexNames=NULL,@StatisticsNames=NULL,@ColumnNames=NULL,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@FilterTable=N'#Columnstore_NameFilters';
    IF @FilterStatus='AVAILABLE' EXEC [monitor].[USP_PrepareDatabaseCandidates] @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass='COLUMNSTORE_CURRENT',@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#Columnstore_DatabaseCandidates';
    IF @FilterStatus='AVAILABLE' AND (@MitPhysicalStats=1 OR @MitSegmenten=1 OR @MitDictionaries=1)
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='COLUMNSTORE_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT;
    IF @FilterStatus='AVAILABLE' AND UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,''))))='VOLL'
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='CATALOG_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT;
    DECLARE @SchemaPredicateS nvarchar(max),@SchemaPredicateSch nvarchar(max),@ObjectPredicateO nvarchar(max),@FullObjectPredicateSO nvarchar(max),@IndexPredicateI nvarchar(max),@StatisticsPredicateSt nvarchar(max);
    SET @SchemaPredicateS=N' AND (NOT EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @SchemaPredicateSch=REPLACE(@SchemaPredicateS,N'[s].[name]',N'[sch].[name]');
    SET @ObjectPredicateO=N' AND (NOT EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @FullObjectPredicateSO=N' AND (NOT EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDbName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @IndexPredicateI=N' AND (NOT EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] WHERE [FilterType]=''INDEX'') OR EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] [f] WHERE [f].[FilterType]=''INDEX'' AND [f].[NameValue]=[i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @StatisticsPredicateSt=N' AND (NOT EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] WHERE [FilterType]=''STATISTICS'') OR EXISTS(SELECT 1 FROM [#Columnstore_NameFilters] [f] WHERE [f].[FilterType]=''STATISTICS'' AND [f].[NameValue]=[st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    IF @SchemaPatternMode='LIKE' BEGIN SET @SchemaPredicateS+=N' AND [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';SET @SchemaPredicateSch+=N' AND [sch].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';END;
    IF @SchemaPatternMode IN('REGEX','REGEXI') BEGIN SET @SchemaPredicateS+=N' AND REGEXP_LIKE([s].[name],N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''','''+@SchemaRegexFlags+N''')';SET @SchemaPredicateSch+=N' AND REGEXP_LIKE([sch].[name],N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''','''+@SchemaRegexFlags+N''')';END;
    IF @ObjectPatternMode='LIKE' SET @ObjectPredicateO+=N' AND [o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @ObjectPatternMode IN('REGEX','REGEXI') SET @ObjectPredicateO+=N' AND REGEXP_LIKE([o].[name],N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''','''+@ObjectRegexFlags+N''')';
    IF @IndexPatternMode='LIKE' SET @IndexPredicateI+=N' AND [i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@IndexPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @IndexPatternMode IN('REGEX','REGEXI') SET @IndexPredicateI+=N' AND REGEXP_LIKE([i].[name],N'''+REPLACE(@IndexPatternValue,N'''',N'''''')+N''','''+@IndexRegexFlags+N''')';
    IF @StatisticsPatternMode='LIKE' SET @StatisticsPredicateSt+=N' AND [st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@StatisticsPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @StatisticsPatternMode IN('REGEX','REGEXI') SET @StatisticsPredicateSt+=N' AND REGEXP_LIKE([st].[name],N'''+REPLACE(@StatisticsPatternValue,N'''',N'''''')+N''','''+@StatisticsRegexFlags+N''')';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048); SET @AnalyseModus=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,'GEZIELT'))));
 IF @Hilfe=1
 BEGIN
        PRINT N'monitor.USP_Columnstore';        PRINT N'@DatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken; N'''' = keine Einschränkung.';        PRINT N'@SystemdatenbankenEinbeziehen bit = 0: Systemdatenbanken einbeziehen.';        PRINT N'Exakte Listen und ...NamePattern sind gegenseitig exklusiv. Pattern: LIKE (Default/like:), regex: oder regexi:.';
        PRINT N'Datenbankauswahl ohne Vorabbegrenzung; @MaxZeilen int: harte Ergebnismengenbegrenzung.';
        PRINT N'@LockTimeoutMs int = 0: Metadatenzugriff wartet standardmäßig nicht auf Locks.';
        PRINT N'@PrintMeldungen bit = 1: strukturierte Warnungen zusätzlich in der Console.';
        PRINT N'Die Procedure liefert Rowgroups, Deleted Rows, Delta Stores sowie optionale Physical-, Segment- und Dictionary-Details.';
        PRINT N'@AnalyseModus varchar(16) = GEZIELT: GEZIELT benötigt Schema-/Objektfilter; VOLL prüft CATALOG_DEEP.';
        PRINT N'@MitPhysicalStats/@MitSegmenten/@MitDictionaries: jeweils opt-in und COLUMNSTORE_DEEP-geschützt.';
        PRINT N'@MinDeletedPercent: Filter 0 bis 100.';
        PRINT N'@NurProblematisch: Rowgroups mit Status ungleich COMPRESSED oder gelöschten Zeilen.';
        PRINT N'@Hilfe bit = 0: 1 zeigt diese Hilfe und führt keine Analyse aus.';
        RETURN;
 END;

    DECLARE @ModuleName sysname = N'USP_Columnstore';
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();

    DECLARE @OverallStatus varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @TotalRows bigint = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Detail nvarchar(2000) = NULL;

    CREATE TABLE [#Columnstore_DatabaseStatus]
    (
          [DatabaseName]       sysname        NULL
        , [StatusCode]         varchar(40)    NOT NULL
        , [IsPartial]          bit            NOT NULL
        , [RowCount]           bigint         NOT NULL
        , [RequiredPermission] nvarchar(256)  NULL
        , [ErrorNumber]        int            NULL
        , [ErrorMessage]       nvarchar(2048) NULL
        , [Detail]             nvarchar(2000) NULL
    );

    IF @FilterStatus<>'AVAILABLE' BEGIN SET @OverallStatus=@FilterStatus;SET @ErrorMessage=@FilterError;END;
    IF @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') BEGIN SET @OverallStatus='INVALID_PARAMETER';SET @ErrorMessage=N'@ResultSetArt muss CONSOLE, RAW, TABLE oder NONE enthalten.';END;
    IF @SchemaPatternValid=0 OR @ObjectPatternValid=0 OR @IndexPatternValid=0 OR @StatisticsPatternValid=0 OR (@SchemaNames IS NOT NULL AND @SchemaNamePattern IS NOT NULL) OR (@ObjectNames IS NOT NULL AND @ObjectNamePattern IS NOT NULL) BEGIN SET @OverallStatus='INVALID_PARAMETER';SET @ErrorMessage=N'Exakte Liste und Pattern derselben Eigenschaft sind gegenseitig exklusiv.';END;
IF @MaxZeilen<0 OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
    BEGIN
        SET @OverallStatus = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültiger Parameter: @MaxZeilen oder @LockTimeoutMs außerhalb des zulässigen Bereichs.';
    END


    IF @OverallStatus <> 'AVAILABLE'
    BEGIN
        INSERT [#Columnstore_DatabaseStatus]([DatabaseName], [StatusCode], [IsPartial], [RowCount], [RequiredPermission], [ErrorNumber], [ErrorMessage], [Detail])
        VALUES(@DatabaseName, @OverallStatus, 1, 0, NULL, NULL, @ErrorMessage, N'Keine Datenbankanalyse ausgeführt.');
        SET @IsPartial = 1;
    END
    ELSE
    BEGIN
        SET LOCK_TIMEOUT 0;
    END;

 DECLARE @CatalogAllowed bit=1;
 IF @AnalyseModus='VOLL' SELECT @CatalogAllowed=COALESCE(MAX(CONVERT(tinyint,[IsAllowed])),0) FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='CATALOG_DEEP';
 DECLARE @ColumnstoreDeepAllowed bit=1;
 IF @MitPhysicalStats=1 OR @MitSegmenten=1 OR @MitDictionaries=1 SELECT @ColumnstoreDeepAllowed=COALESCE(MAX(CONVERT(tinyint,[IsAllowed])),0) FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='COLUMNSTORE_DEEP';
 CREATE TABLE [#Columnstore_Result]
 (
  [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL,[ObjectId] int NOT NULL,[IndexId] int NOT NULL,[IndexName] sysname NULL,[IndexTypeDesc] nvarchar(60) NULL,
  [PartitionNumber] int NOT NULL,[RowGroupId] int NOT NULL,[StateDesc] nvarchar(60) NULL,[TotalRows] bigint NULL,[DeletedRows] bigint NULL,[ActiveRows] bigint NULL,
  [DeletedPercent] decimal(9,4) NULL,[FullnessPercent] decimal(9,4) NULL,[SizeMb] decimal(19,2) NULL,[DeltaStoreHobtId] bigint NULL,
  [TrimReasonDesc] nvarchar(60) NULL,[TransitionToCompressedStateDesc] nvarchar(60) NULL,[HasVertipaqOptimization] bit NULL,[Generation] bigint NULL,[CreatedTime] datetime2 NULL,[ClosedTime] datetime2 NULL,
  [Assessment] varchar(60) NOT NULL
 );
 CREATE TABLE [#Columnstore_Physical]
 (
  [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL,[ObjectId] int NOT NULL,[IndexId] int NOT NULL,[IndexName] sysname NULL,[IndexTypeDesc] nvarchar(60) NULL,
  [PartitionNumber] int NOT NULL,[RowGroupId] int NOT NULL,[StateDesc] nvarchar(60) NULL,[TotalRows] bigint NULL,[DeletedRows] bigint NULL,[ActiveRows] bigint NULL,
  [DeletedPercent] decimal(9,4) NULL,[SizeMb] decimal(19,2) NULL,[DeltaStoreHobtId] bigint NULL,[TrimReasonDesc] nvarchar(60) NULL,
  [TransitionToCompressedStateDesc] nvarchar(60) NULL,[HasVertipaqOptimization] bit NULL,[Generation] bigint NULL,[CreatedTime] datetime2 NULL,[ClosedTime] datetime2 NULL,[Assessment] varchar(60) NOT NULL
 );
 CREATE TABLE [#Columnstore_Segments]
 (
  [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL,[IndexId] int NOT NULL,[PartitionNumber] int NOT NULL,[ColumnId] int NOT NULL,[ColumnName] sysname NULL,
  [RowGroupId] int NOT NULL,[EncodingType] int NULL,[EncodingTypeDesc] varchar(40) NULL,[RowCount] int NULL,[HasNulls] int NULL,[PrimaryDictionaryId] int NULL,[SecondaryDictionaryId] int NULL,[OnDiskSizeMb] decimal(19,4) NULL
 );
 CREATE TABLE [#Columnstore_Dictionaries]
 (
  [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL,[IndexId] int NOT NULL,[PartitionNumber] int NOT NULL,[ColumnId] int NOT NULL,[ColumnName] sysname NULL,
  [DictionaryId] int NOT NULL,[DictionaryType] int NULL,[DictionaryTypeDesc] varchar(40) NULL,[EntryCount] bigint NULL,[OnDiskSizeMb] decimal(19,4) NULL
 );
 IF @OverallStatus='AVAILABLE' AND (@MinDeletedPercent<0 OR @MinDeletedPercent>100)
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'@MinDeletedPercent muss zwischen 0 und 100 liegen.'; INSERT [#Columnstore_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus NOT IN ('GEZIELT','VOLL')
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'@AnalyseModus muss GEZIELT oder VOLL sein.'; INSERT [#Columnstore_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus='GEZIELT' AND NOT EXISTS(SELECT 1 FROM [#Columnstore_NameFilters]) AND @SchemaNamePattern IS NULL AND @ObjectNamePattern IS NULL
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'GEZIELT erfordert eine exakte Namensliste, @FullObjectNames oder ein Schema-/Objekt-Pattern. Für den vollständigen Lauf @AnalyseModus=''VOLL'' verwenden.'; INSERT [#Columnstore_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus='VOLL' AND @CatalogAllowed=0
 BEGIN SET @OverallStatus='DENIED_GROUP'; SET @ErrorMessage=N'CATALOG_DEEP ist für die vollständige Columnstore-Basisanalyse nicht freigegeben.'; INSERT [#Columnstore_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND (@MitPhysicalStats=1 OR @MitSegmenten=1 OR @MitDictionaries=1) AND @ColumnstoreDeepAllowed=0
 BEGIN SET @OverallStatus='DENIED_GROUP'; SET @ErrorMessage=N'COLUMNSTORE_DEEP ist für die angeforderte Vertiefung nicht freigegeben.'; INSERT [#Columnstore_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE'
 BEGIN
  DECLARE @DbId int,@DbName sysname,@Sql nvarchar(max),@Rows bigint;
  DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR
   SELECT [DatabaseId],[DatabaseName]
   FROM [#Columnstore_DatabaseCandidates];
  OPEN dbcur; FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  WHILE @@FETCH_STATUS=0
  BEGIN
   BEGIN TRY
    SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
INSERT #Columnstore_Result
SELECT TOP (@pMaxRows) @pDbName,[s].[name],[o].[name],[o].[object_id],[i].[index_id],[i].[name],[i].[type_desc],[rg].[partition_number],[rg].[row_group_id],[rg].[state_description],
 [rg].[total_rows],[rg].[deleted_rows],[rg].[total_rows]-COALESCE([rg].[deleted_rows],0),CONVERT(decimal(9,4),[rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0)),
 CONVERT(decimal(9,4),([rg].[total_rows]-COALESCE([rg].[deleted_rows],0))*100.0/1048576.0),CONVERT(decimal(19,2),[rg].[size_in_bytes]/1048576.0),[rg].[delta_store_hobt_id],
 NULL,NULL,NULL,NULL,NULL,NULL,
 CASE WHEN [rg].[state_description]=''TOMBSTONE'' THEN ''TOMBSTONE'' WHEN [rg].[state_description]=''CLOSED'' THEN ''CLOSED_WAITING_FOR_TUPLE_MOVER'' WHEN [rg].[state_description]=''OPEN'' THEN ''OPEN_DELTA_STORE''
      WHEN [rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0)>=20 THEN ''HIGH_DELETED_ROWS'' WHEN [rg].[total_rows]<102400 AND [rg].[state_description]=''COMPRESSED'' THEN ''SMALL_COMPRESSED_ROWGROUP'' ELSE ''NORMAL'' END
FROM sys.column_store_row_groups AS [rg] WITH (NOLOCK)
JOIN sys.objects AS [o] WITH (NOLOCK) ON [o].[object_id]=[rg].[object_id]
JOIN sys.schemas AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
JOIN sys.indexes AS [i] WITH (NOLOCK) ON [i].[object_id]=[rg].[object_id] AND [i].[index_id]=[rg].[index_id]
WHERE 1=1'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+N'
 AND COALESCE([rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0),0)>=@pMinDeleted
 AND (@pOnlyProblems=0 OR [rg].[state_description]<>''COMPRESSED'' OR COALESCE([rg].[deleted_rows],0)>0)
ORDER BY COALESCE([rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0),0) DESC,[rg].[total_rows] ASC
OPTION (MAXDOP 1,RECOMPILE);';
    EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256),@pMinDeleted decimal(9,2),@pOnlyProblems bit',
      @pDbName=@DbName,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike,@pMinDeleted=@MinDeletedPercent,@pOnlyProblems=@NurProblematisch;
    SELECT @Rows=COUNT_BIG(*) FROM [#Columnstore_Result] WHERE [DatabaseName]=@DbName;
    INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,N'VIEW DEFINITION / Metadata Visibility',NULL,NULL,N'Quelle COLUMNSTORE_CATALOG erfolgreich gelesen.');
   END TRY
   BEGIN CATCH
    INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN (207,208) THEN 'UNAVAILABLE_OBJECT' ELSE 'ERROR_HANDLED' END,1,0,N'VIEW DEFINITION / Metadata Visibility',ERROR_NUMBER(),ERROR_MESSAGE(),N'Quelle COLUMNSTORE_CATALOG fehlgeschlagen; optionale Teilquellen werden dennoch versucht.');
   END CATCH;

   IF @MitPhysicalStats=1
   BEGIN
    BEGIN TRY
     SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
INSERT #Columnstore_Physical
SELECT TOP (@pMaxRows) @pDbName,[s].[name],[o].[name],[o].[object_id],[i].[index_id],[i].[name],[i].[type_desc],[rg].[partition_number],[rg].[row_group_id],[rg].[state_desc],
 [rg].[total_rows],[rg].[deleted_rows],[rg].[total_rows]-COALESCE([rg].[deleted_rows],0),CONVERT(decimal(9,4),[rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0)),
 CONVERT(decimal(19,2),[rg].[size_in_bytes]/1048576.0),[rg].[delta_store_hobt_id],[rg].[trim_reason_desc],[rg].[transition_to_compressed_state_desc],
 [rg].[has_vertipaq_optimization],[rg].[generation],[rg].[created_time],[rg].[closed_time],
 CASE WHEN [rg].[state_desc]=''TOMBSTONE'' THEN ''TOMBSTONE'' WHEN [rg].[state_desc]=''CLOSED'' THEN ''CLOSED_WAITING_FOR_TUPLE_MOVER'' WHEN [rg].[state_desc]=''OPEN'' THEN ''OPEN_DELTA_STORE''
      WHEN [rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0)>=20 THEN ''HIGH_DELETED_ROWS'' WHEN [rg].[total_rows]<102400 AND [rg].[state_desc]=''COMPRESSED'' THEN ''SMALL_COMPRESSED_ROWGROUP'' ELSE ''NORMAL'' END
FROM sys.dm_db_column_store_row_group_physical_stats AS [rg] WITH (NOLOCK)
JOIN sys.objects AS [o] WITH (NOLOCK) ON [o].[object_id]=[rg].[object_id]
JOIN sys.schemas AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
JOIN sys.indexes AS [i] WITH (NOLOCK) ON [i].[object_id]=[rg].[object_id] AND [i].[index_id]=[rg].[index_id]
WHERE 1=1'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+N'
 AND COALESCE([rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0),0)>=@pMinDeleted
 AND (@pOnlyProblems=0 OR [rg].[state_desc]<>''COMPRESSED'' OR COALESCE([rg].[deleted_rows],0)>0)
ORDER BY COALESCE([rg].[deleted_rows]*100.0/NULLIF([rg].[total_rows],0),0) DESC,[rg].[total_rows] ASC
OPTION (MAXDOP 1,RECOMPILE);';
     EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256),@pMinDeleted decimal(9,2),@pOnlyProblems bit',
      @pDbName=@DbName,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike,@pMinDeleted=@MinDeletedPercent,@pOnlyProblems=@NurProblematisch;
     SELECT @Rows=COUNT_BIG(*) FROM [#Columnstore_Physical] WHERE [DatabaseName]=@DbName;
     INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW DATABASE PERFORMANCE STATE' ELSE N'VIEW DATABASE STATE plus CONTROL/geeignete Objektrechte' END,NULL,NULL,N'Quelle COLUMNSTORE_PHYSICAL erfolgreich gelesen.');
    END TRY
    BEGIN CATCH
     INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN (207,208) THEN 'UNAVAILABLE_OBJECT' ELSE 'ERROR_HANDLED' END,1,0,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW DATABASE PERFORMANCE STATE' ELSE N'VIEW DATABASE STATE plus CONTROL/geeignete Objektrechte' END,ERROR_NUMBER(),ERROR_MESSAGE(),N'Quelle COLUMNSTORE_PHYSICAL fehlgeschlagen; Katalogergebnis bleibt erhalten.');
    END CATCH;
   END;

   IF @MitSegmenten=1
   BEGIN
    BEGIN TRY
     SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
INSERT #Columnstore_Segments
SELECT TOP (@pMaxRows) @pDbName,[sch].[name],[o].[name],[i].[index_id],[p].[partition_number],[sg].[column_id],[c].[name],[sg].[segment_id],[sg].[encoding_type],
 CASE [sg].[encoding_type] WHEN 1 THEN ''VALUE_BASED'' WHEN 2 THEN ''VALUE_HASH_BASED'' WHEN 3 THEN ''STRING_HASH_BASED'' WHEN 4 THEN ''STORE_BY_VALUE_BASED'' WHEN 5 THEN ''STRING_STORE_BY_VALUE_BASED'' ELSE ''UNKNOWN'' END,
 [sg].[row_count],[sg].[has_nulls],[sg].[primary_dictionary_id],[sg].[secondary_dictionary_id],CONVERT(decimal(19,4),[sg].[on_disk_size]/1048576.0)
FROM sys.column_store_segments AS [sg] WITH (NOLOCK)
JOIN sys.partitions AS [p] WITH (NOLOCK) ON [p].[hobt_id]=[sg].[hobt_id] AND [p].[partition_id]=[sg].[partition_id]
JOIN sys.objects AS [o] WITH (NOLOCK) ON [o].[object_id]=[p].[object_id]
JOIN sys.schemas AS [sch] WITH (NOLOCK) ON [sch].[schema_id]=[o].[schema_id]
JOIN sys.indexes AS [i] WITH (NOLOCK) ON [i].[object_id]=[p].[object_id] AND [i].[index_id]=[p].[index_id]
LEFT JOIN sys.columns AS [c] WITH (NOLOCK) ON [c].[object_id]=[p].[object_id] AND [c].[column_id]=[sg].[column_id]
WHERE 1=1'+@SchemaPredicateSch+@ObjectPredicateO+REPLACE(@FullObjectPredicateSO,N'[s].[name]',N'[sch].[name]')+N'
ORDER BY [sg].[on_disk_size] DESC OPTION (MAXDOP 1,RECOMPILE);';
     EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256)',@pDbName=@DbName,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike;
     SELECT @Rows=COUNT_BIG(*) FROM [#Columnstore_Segments] WHERE [DatabaseName]=@DbName;
     INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,N'VIEW DEFINITION; Detailspalten teilweise SELECT-abhängig',NULL,NULL,N'Quelle COLUMNSTORE_SEGMENTS erfolgreich gelesen.');
    END TRY
    BEGIN CATCH
     INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN (207,208) THEN 'UNAVAILABLE_OBJECT' ELSE 'ERROR_HANDLED' END,1,0,N'VIEW DEFINITION',ERROR_NUMBER(),ERROR_MESSAGE(),N'Quelle COLUMNSTORE_SEGMENTS fehlgeschlagen; andere Teilquellen bleiben verwendbar.');
    END CATCH;
   END;

   IF @MitDictionaries=1
   BEGIN
    BEGIN TRY
     SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
INSERT #Columnstore_Dictionaries
SELECT TOP (@pMaxRows) @pDbName,[sch].[name],[o].[name],[i].[index_id],[p].[partition_number],[d].[column_id],[c].[name],[d].[dictionary_id],[d].[type],
 CASE [d].[type] WHEN 1 THEN ''INT_HASH'' WHEN 3 THEN ''STRING_HASH'' WHEN 4 THEN ''FLOAT_HASH'' ELSE ''UNKNOWN'' END,
 [d].[entry_count],CONVERT(decimal(19,4),[d].[on_disk_size]/1048576.0)
FROM sys.column_store_dictionaries AS [d] WITH (NOLOCK)
JOIN sys.partitions AS [p] WITH (NOLOCK) ON [p].[hobt_id]=[d].[hobt_id] AND [p].[partition_id]=[d].[partition_id]
JOIN sys.objects AS [o] WITH (NOLOCK) ON [o].[object_id]=[p].[object_id]
JOIN sys.schemas AS [sch] WITH (NOLOCK) ON [sch].[schema_id]=[o].[schema_id]
JOIN sys.indexes AS [i] WITH (NOLOCK) ON [i].[object_id]=[p].[object_id] AND [i].[index_id]=[p].[index_id]
LEFT JOIN sys.columns AS [c] WITH (NOLOCK) ON [c].[object_id]=[p].[object_id] AND [c].[column_id]=[d].[column_id]
WHERE 1=1'+@SchemaPredicateSch+@ObjectPredicateO+REPLACE(@FullObjectPredicateSO,N'[s].[name]',N'[sch].[name]')+N'
ORDER BY [d].[on_disk_size] DESC OPTION (MAXDOP 1,RECOMPILE);';
     EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256)',@pDbName=@DbName,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike;
     SELECT @Rows=COUNT_BIG(*) FROM [#Columnstore_Dictionaries] WHERE [DatabaseName]=@DbName;
     INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,N'VIEW DEFINITION; EntryCount zusätzlich SELECT-abhängig',NULL,NULL,N'Quelle COLUMNSTORE_DICTIONARIES erfolgreich gelesen.');
    END TRY
    BEGIN CATCH
     INSERT [#Columnstore_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN (207,208) THEN 'UNAVAILABLE_OBJECT' ELSE 'ERROR_HANDLED' END,1,0,N'VIEW DEFINITION',ERROR_NUMBER(),ERROR_MESSAGE(),N'Quelle COLUMNSTORE_DICTIONARIES fehlgeschlagen; andere Teilquellen bleiben verwendbar.');
    END CATCH;
   END;

   FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  END;
  CLOSE dbcur; DEALLOCATE dbcur;
  IF NOT EXISTS(SELECT 1 FROM [#Columnstore_DatabaseStatus])
   INSERT [#Columnstore_DatabaseStatus] VALUES(@DatabaseName,'DATABASE_UNAVAILABLE',1,0,NULL,NULL,N'Keine sichtbare Online-Zieldatenbank gefunden.',NULL);
 END;



    SELECT @TotalRows=(SELECT COUNT_BIG(*) FROM [#Columnstore_Result])+(SELECT COUNT_BIG(*) FROM [#Columnstore_Physical])+(SELECT COUNT_BIG(*) FROM [#Columnstore_Segments])+(SELECT COUNT_BIG(*) FROM [#Columnstore_Dictionaries]);

    IF @OverallStatus = 'AVAILABLE'
    BEGIN
        IF EXISTS (SELECT 1 FROM [#Columnstore_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
        BEGIN
            SET @OverallStatus = CASE WHEN @TotalRows > 0 THEN 'PARTIAL' ELSE (SELECT TOP (1) [StatusCode] FROM [#Columnstore_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE') ORDER BY [DatabaseName]) END;
            SET @IsPartial = 1;
        END
        ELSE IF EXISTS (SELECT 1 FROM [#Columnstore_DatabaseStatus] WHERE [StatusCode] IN ('AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
        BEGIN
            SET @OverallStatus = CASE WHEN @TotalRows > 0 THEN 'AVAILABLE_LIMITED' ELSE 'SKIPPED' END;
            SET @IsPartial = 1;
        END;
    END;

    IF @PrintMeldungen = 1 AND @OverallStatus <> 'AVAILABLE'
        BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG %s: %s', @OverallStatus, COALESCE(@ErrorMessage, @Detail, N'Teilergebnis oder eingeschränkte Sicht'));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;

    IF @ResultSetArtNormalisiert<>'NONE' BEGIN
        SELECT @ModuleName [ModuleName],@CollectionTimeUtc [CollectionTimeUtc],@OverallStatus [StatusCode],@IsPartial [IsPartial],@TotalRows [RowCount],@ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage],@Detail [Detail];
        SELECT [DatabaseName],[StatusCode],[IsPartial],[RowCount],[RequiredPermission],[ErrorNumber],[ErrorMessage],[Detail] FROM [#Columnstore_DatabaseStatus] ORDER BY [DatabaseName];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#Columnstore_Result] ORDER BY [DeletedPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId]; ELSE SELECT N'Columnstore Rowgroup' [Ergebnis],[r].* FROM [#Columnstore_Result] [r] ORDER BY [DeletedPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#Columnstore_Physical] ORDER BY [DeletedPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId]; ELSE SELECT N'Columnstore Rowgroup' [Ergebnis],[r].* FROM [#Columnstore_Physical] [r] ORDER BY [DeletedPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#Columnstore_Segments] ORDER BY [OnDiskSizeMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId],[ColumnId]; ELSE SELECT N'Columnstore Rowgroup' [Ergebnis],[r].* FROM [#Columnstore_Segments] [r] ORDER BY [OnDiskSizeMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId],[ColumnId];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#Columnstore_Dictionaries] ORDER BY [OnDiskSizeMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[ColumnId],[DictionaryId]; ELSE SELECT N'Columnstore Rowgroup' [Ergebnis],[r].* FROM [#Columnstore_Dictionaries] [r] ORDER BY [OnDiskSizeMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[ColumnId],[DictionaryId];
    END;
    IF @JsonErzeugen=1 BEGIN
        DECLARE @JsonMeta nvarchar(max)=(SELECT @ModuleName [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@OverallStatus [statusCode],@IsPartial [isPartial],@TotalRows [rowCount] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @JsonDatabaseStatus nvarchar(max)=(SELECT * FROM [#Columnstore_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData1 nvarchar(max)=(SELECT * FROM [#Columnstore_Result] ORDER BY [DeletedPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData2 nvarchar(max)=(SELECT * FROM [#Columnstore_Physical] ORDER BY [DeletedPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData3 nvarchar(max)=(SELECT * FROM [#Columnstore_Segments] ORDER BY [OnDiskSizeMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[RowGroupId],[ColumnId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData4 nvarchar(max)=(SELECT * FROM [#Columnstore_Dictionaries] ORDER BY [OnDiskSizeMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber],[ColumnId],[DictionaryId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@JsonMeta,N'{}'),N',"rowgroups":',COALESCE(@JsonData1,N'[]'),N',"physicalStats":',COALESCE(@JsonData2,N'[]'),N',"segments":',COALESCE(@JsonData3,N'[]'),N',"dictionaries":',COALESCE(@JsonData4,N'[]'),N',"databaseStatus":',COALESCE(@JsonDatabaseStatus,N'[]'),N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#Columnstore_Result'
            , @ResultLabel=N'Columnstore'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#Columnstore_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
