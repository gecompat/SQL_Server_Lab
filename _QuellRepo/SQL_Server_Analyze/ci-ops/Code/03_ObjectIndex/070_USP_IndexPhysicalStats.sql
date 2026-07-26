USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_IndexPhysicalStats
Version      : 1.1.0
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Führt eine bewusst aktivierte und gruppengeschützte Physical-Stats-Analyse für Rowstore-Indizes/Heaps durch; LIMITED ist Default, SAMPLED/DETAILED sind explizit.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.dm_db_index_physical_stats sowie je Datenbank sys.objects, sys.schemas und sys.indexes.
Parameter    :
  @DatabaseName                  sysname        = NULL  - Zieldatenbank; bei Einzelmodus Pflicht.
  @CrossDatabaseRequestedInternal               bit            = 0     - sichtbare Online-Datenbanken analysieren.
  @SystemdatenbankenEinbeziehen  bit            = 0     - master/model/msdb/tempdb einbeziehen.
  @DatenbankNameLike             nvarchar(256)  = NULL  - Filter im Cross-Database-Modus.
  @SchemaNamePattern                nvarchar(256)  = NULL  - GEZIELT: exakter Schemaname; VOLL: LIKE.
  @ObjectNamePattern                nvarchar(256)  = NULL  - GEZIELT: exakter Objektname; VOLL: LIKE.
  @MaxZeilen                     int            = 10000 - positive Werte begrenzen; NULL/0 = unbegrenzt.
  @LockTimeoutMs                 int            = 0     - 0 = nicht auf Metadatenlocks warten.
  @PrintMeldungen                bit            = 1     - Warnungen via RAISERROR 10.
  @Hilfe                         bit            = 0     - Hilfe via PRINT, keine Analyse.
  @AnalyseModus varchar(16)='GEZIELT' - GEZIELT genau ein Objekt; VOLL erlaubt LIKE-/Breitenscan.
  @ScanMode varchar(16)='LIMITED' - LIMITED|SAMPLED|DETAILED.
  @IndexNamePattern nvarchar(256)=NULL - Indexfilter.
  @MinPageCount bigint=1000 - kleine Strukturen ausblenden.
  @MinFragmentationPercent decimal(9,2)=0 - Filter.
  @PartitionNumber int=NULL - einzelne Partition.
  @IndexId int=NULL - einzelner Index.
Resultsets   : 1. Modulstatus. 2. Status je Datenbank. 3. Physical-Stats-Ergebnisse.
Berechtigung : Immer PHYSICAL_STATS_DEEP; Cross-Database zusätzlich CROSS_DATABASE_DEEP. SQL 2019 VIEW DATABASE STATE bzw. CONTROL am Objekt; SQL 2022+ VIEW DATABASE PERFORMANCE STATE.
Eigenlast    : GEZIELT übergibt genau eine sicher aufgelöste object_id. VOLL kann breit lesen. LIMITED kann bereits relevant sein; SAMPLED/DETAILED können hohe I/O-/CPU-Kosten erzeugen. TOP filtert erst nach DMF-Ausführung.
Locking      : DMF kann IS-Locks auf Metadaten/Objekten anfordern; LOCK_TIMEOUT begrenzt Warten. Keine automatische Wartung.
Partial      : Fehler je Datenbank bzw. Teilquelle werden isoliert; vorhandene
               Teilergebnisse bleiben erhalten. Das Framework vergibt keine Rechte.
Beispiele    :
  EXEC monitor.USP_IndexPhysicalStats @DatabaseNames=N'SampleDatabase', @SchemaNamePattern=N'dbo', @ObjectNamePattern=N'FactSales';
  EXEC monitor.USP_IndexPhysicalStats @DatabaseNames=N'SampleDatabase', @AnalyseModus='VOLL', @ObjectNamePattern=N'Fact%', @ScanMode='SAMPLED', @MinPageCount=10000;
  EXEC monitor.USP_IndexPhysicalStats @Hilfe=1;
Änderungen   : 1.1.0 - GEZIELT als sicherer Default; fehlende exakte Objektauflösung löst keinen Datenbank-Wildcardscan aus.
               1.0.0 - Erstfassung Phase 2.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_IndexPhysicalStats]
      @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @IndexNames                     nvarchar(max)  = NULL
    , @IndexNamePattern               nvarchar(4000) = NULL
    , @AnalyseModus                   varchar(16)   = 'GEZIELT'
    , @ScanMode                       varchar(16)   = 'LIMITED'
    , @IndexId                        int           = NULL
    , @PartitionNumber                int           = NULL
    , @MinPageCount                   bigint        = 1000
    , @MinFragmentationPercent        decimal(9,2)  = 0
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'indexPhysicalStats',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @DatabaseName sysname=NULL,@CrossDatabaseRequestedInternal bit=0,@DatenbankNameLike nvarchar(4000)=NULL;
    DECLARE @SchemaNameLike nvarchar(4000)=NULL,@ObjectNameLike nvarchar(4000)=NULL;
    DECLARE @IndexNameLike nvarchar(4000)=NULL;
    DECLARE @SchemaPatternMode varchar(8),@SchemaPatternValue nvarchar(4000),@SchemaRegexFlags varchar(8),@SchemaPatternValid bit;
    DECLARE @ObjectPatternMode varchar(8),@ObjectPatternValue nvarchar(4000),@ObjectRegexFlags varchar(8),@ObjectPatternValid bit;
    SELECT @SchemaPatternMode=[PatternMode],@SchemaPatternValue=[PatternValue],@SchemaRegexFlags=[RegexFlags],@SchemaPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@SchemaNamePattern);
    SELECT @ObjectPatternMode=[PatternMode],@ObjectPatternValue=[PatternValue],@ObjectRegexFlags=[RegexFlags],@ObjectPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@ObjectNamePattern);
    IF @SchemaPatternMode='LIKE' SET @SchemaNameLike=@SchemaPatternValue;
    IF @ObjectPatternMode='LIKE' SET @ObjectNameLike=@ObjectPatternValue;
    DECLARE @IndexPatternMode varchar(8),@IndexPatternValue nvarchar(4000),@IndexRegexFlags varchar(8),@IndexPatternValid bit;
    SELECT @IndexPatternMode=[PatternMode],@IndexPatternValue=[PatternValue],@IndexRegexFlags=[RegexFlags],@IndexPatternValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@IndexNamePattern);
    IF @IndexPatternMode='LIKE' SET @IndexNameLike=@IndexPatternValue;
    DECLARE @StatisticsPatternMode varchar(8)='NONE',@StatisticsPatternValue nvarchar(4000)=NULL,@StatisticsRegexFlags varchar(8)=NULL,@StatisticsPatternValid bit=1;
    DECLARE @DatabaseListCount int=0;
    IF @DatabaseNames IS NOT NULL AND NULLIF(LTRIM(RTRIM(@DatabaseNames)),N'') IS NOT NULL
        SELECT @DatabaseListCount=COUNT(*),@DatabaseName=MIN([NameValue]) FROM [monitor].[TVF_ParseSqlNameList](@DatabaseNames) WHERE [IsValid]=1;
    SET @CrossDatabaseRequestedInternal=CONVERT(bit,CASE WHEN @DatabaseNames IS NULL OR @DatabaseNamePattern IS NOT NULL OR @DatabaseListCount>1 THEN 1 ELSE 0 END);
    SELECT @DatenbankNameLike=CASE WHEN [PatternMode]='LIKE' THEN [PatternValue] END FROM [monitor].[TVF_ParsePattern](@DatabaseNamePattern);
    CREATE TABLE [#IndexPhysicalStats_NameFilters]([FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL,[ItemOrdinal] int NOT NULL,[NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL);
    CREATE TABLE [#IndexPhysicalStats_DatabaseCandidates]([DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60),[UserAccessDesc] nvarchar(60),[IsReadOnly] bit,[CompatibilityLevel] tinyint,[CollationName] sysname,[RecoveryModelDesc] nvarchar(60),[IsSystemDatabase] bit,[RequestedOrdinal] int);
    DECLARE @FilterStatus varchar(40)='AVAILABLE',@FilterError nvarchar(2048)=NULL,@CrossDatabaseRequested bit=0;
    EXEC [monitor].[USP_PrepareNameFilters] @SchemaNames=@SchemaNames,@ObjectNames=@ObjectNames,@FullObjectNames=@FullObjectNames,@IndexNames=@IndexNames,@StatisticsNames=NULL,@ColumnNames=NULL,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@FilterTable=N'#IndexPhysicalStats_NameFilters';
    IF @FilterStatus='AVAILABLE' EXEC [monitor].[USP_PrepareDatabaseCandidates] @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass='PHYSICAL_STATS_DEEP',@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#IndexPhysicalStats_DatabaseCandidates';
    DECLARE @SchemaPredicateS nvarchar(max),@SchemaPredicateSch nvarchar(max),@ObjectPredicateO nvarchar(max),@FullObjectPredicateSO nvarchar(max),@IndexPredicateI nvarchar(max),@StatisticsPredicateSt nvarchar(max);
    SET @SchemaPredicateS=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @SchemaPredicateSch=REPLACE(@SchemaPredicateS,N'[s].[name]',N'[sch].[name]');
    SET @ObjectPredicateO=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @FullObjectPredicateSO=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDbName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @IndexPredicateI=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]=''INDEX'') OR EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] [f] WHERE [f].[FilterType]=''INDEX'' AND [f].[NameValue]=[i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @StatisticsPredicateSt=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]=''STATISTICS'') OR EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] [f] WHERE [f].[FilterType]=''STATISTICS'' AND [f].[NameValue]=[st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    IF @SchemaPatternMode='LIKE' BEGIN SET @SchemaPredicateS+=N' AND [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';SET @SchemaPredicateSch+=N' AND [sch].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';END;
    IF @SchemaPatternMode IN('REGEX','REGEXI') BEGIN SET @SchemaPredicateS+=N' AND REGEXP_LIKE([s].[name],N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''','''+@SchemaRegexFlags+N''')';SET @SchemaPredicateSch+=N' AND REGEXP_LIKE([sch].[name],N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''','''+@SchemaRegexFlags+N''')';END;
    IF @ObjectPatternMode='LIKE' SET @ObjectPredicateO+=N' AND [o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @ObjectPatternMode IN('REGEX','REGEXI') SET @ObjectPredicateO+=N' AND REGEXP_LIKE([o].[name],N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''','''+@ObjectRegexFlags+N''')';
    IF @IndexPatternMode='LIKE' SET @IndexPredicateI+=N' AND [i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@IndexPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @IndexPatternMode IN('REGEX','REGEXI') SET @IndexPredicateI+=N' AND REGEXP_LIKE([i].[name],N'''+REPLACE(@IndexPatternValue,N'''',N'''''')+N''','''+@IndexRegexFlags+N''')';
    IF @StatisticsPatternMode='LIKE' SET @StatisticsPredicateSt+=N' AND [st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@StatisticsPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @StatisticsPatternMode IN('REGEX','REGEXI') SET @StatisticsPredicateSt+=N' AND REGEXP_LIKE([st].[name],N'''+REPLACE(@StatisticsPatternValue,N'''',N'''''')+N''','''+@StatisticsRegexFlags+N''')';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048); SET @AnalyseModus=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,'GEZIELT')))); SET @ScanMode=UPPER(LTRIM(RTRIM(COALESCE(@ScanMode,'LIMITED'))));
 IF @Hilfe=1
 BEGIN
        PRINT N'monitor.USP_IndexPhysicalStats';        PRINT N'@DatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken; N'''' = keine Einschränkung.';        PRINT N'@SystemdatenbankenEinbeziehen bit = 0: Systemdatenbanken einbeziehen.';
        PRINT N'@DatenbankNameLike: optionaler Cross-Database-LIKE-Filter.';
        PRINT N'@SchemaNamePattern/@ObjectNamePattern: GEZIELT beide als exakte Equality-Namen; VOLL als optionale LIKE-Filter.';
        PRINT N'Datenbankauswahl ohne Vorabbegrenzung; @MaxZeilen int = 10000: harte Ergebnismengenbegrenzung.';
        PRINT N'@LockTimeoutMs int = 0: Metadatenzugriff wartet standardmäßig nicht auf Locks.';
        PRINT N'@PrintMeldungen bit = 1: strukturierte Warnungen zusätzlich in der Console.';
        PRINT N'Die Procedure liefert Physical Stats für Rowstore-Indizes und Heaps, führt jedoch keine Wartungsaktion aus.';
        PRINT N'@IndexNamePattern nvarchar(256) = NULL: optionaler Indexfilter.';
        PRINT N'@AnalyseModus varchar(16) = GEZIELT: exakt ein Objekt; VOLL erlaubt LIKE-/Breitenscan. Beide Modi prüfen PHYSICAL_STATS_DEEP.';
        PRINT N'@ScanMode: LIMITED, SAMPLED oder DETAILED. DETAILED ist besonders kostenintensiv.';
        PRINT N'@IndexId/@PartitionNumber: optionale technische Eingrenzung.';
        PRINT N'@MinPageCount: Default 1000; Filter wird auf DMF-Ergebnis angewandt.';
        PRINT N'@MinFragmentationPercent: 0 bis 100.';
        PRINT N'Immer PHYSICAL_STATS_DEEP; Cross-Database prüft zusätzlich CROSS_DATABASE_DEEP.';
        PRINT N'@Hilfe bit = 0: 1 zeigt diese Hilfe und führt keine Analyse aus.';
        RETURN;
 END;

    DECLARE @ModuleName sysname = N'USP_IndexPhysicalStats';
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();

    DECLARE @OverallStatus varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @TotalRows bigint = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Detail nvarchar(2000) = NULL;

    CREATE TABLE [#IndexPhysicalStats_DatabaseStatus]
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
    IF @SchemaPatternValid=0 OR @ObjectPatternValid=0 OR @IndexPatternValid=0 OR @StatisticsPatternValid=0 OR (@SchemaNames IS NOT NULL AND @SchemaNamePattern IS NOT NULL) OR (@ObjectNames IS NOT NULL AND @ObjectNamePattern IS NOT NULL) OR (@IndexNames IS NOT NULL AND @IndexNamePattern IS NOT NULL) BEGIN SET @OverallStatus='INVALID_PARAMETER';SET @ErrorMessage=N'Exakte Liste und Pattern derselben Eigenschaft sind gegenseitig exklusiv.';END;
IF @MaxZeilen<0 OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
    BEGIN
        SET @OverallStatus = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültiger Parameter: @MaxZeilen oder @LockTimeoutMs außerhalb des zulässigen Bereichs.';
    END


    IF @OverallStatus <> 'AVAILABLE'
    BEGIN
        INSERT [#IndexPhysicalStats_DatabaseStatus]([DatabaseName], [StatusCode], [IsPartial], [RowCount], [RequiredPermission], [ErrorNumber], [ErrorMessage], [Detail])
        VALUES(@DatabaseName, @OverallStatus, 1, 0, NULL, NULL, @ErrorMessage, N'Keine Datenbankanalyse ausgeführt.');
        SET @IsPartial = 1;
    END
    ELSE
    BEGIN
        SET LOCK_TIMEOUT 0;
    END;

 DECLARE @PhysicalAllowed bit=0; SELECT @PhysicalAllowed=COALESCE(MAX(CONVERT(tinyint,[IsAllowed])),0) FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='PHYSICAL_STATS_DEEP';
 CREATE TABLE [#IndexPhysicalStats_Result]
 (
  [DatabaseName] sysname NOT NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL,[ObjectId] int NOT NULL,[IndexId] int NOT NULL,[IndexName] sysname NULL,[IndexTypeDesc] nvarchar(60) NULL,
  [PartitionNumber] int NULL,[IndexLevel] tinyint NULL,[AllocationUnitTypeDesc] nvarchar(60) NULL,[IndexDepth] tinyint NULL,[IndexTypeDescPhysical] nvarchar(60) NULL,
  [AvgFragmentationPercent] float NULL,[FragmentCount] bigint NULL,[AvgFragmentSizePages] float NULL,[PageCount] bigint NULL,[AvgPageSpaceUsedPercent] float NULL,
  [RecordCount] bigint NULL,[GhostRecordCount] bigint NULL,[VersionGhostRecordCount] bigint NULL,[MinRecordSizeBytes] int NULL,[MaxRecordSizeBytes] int NULL,[AvgRecordSizeBytes] float NULL,
  [ForwardedRecordCount] bigint NULL,[CompressedPageCount] bigint NULL,[ScanMode] varchar(16) NOT NULL
 );
 IF @OverallStatus='AVAILABLE' AND (@AnalyseModus NOT IN ('GEZIELT','VOLL') OR @ScanMode NOT IN ('LIMITED','SAMPLED','DETAILED') OR @MinPageCount<0 OR @MinFragmentationPercent<0 OR @MinFragmentationPercent>100 OR (@IndexId IS NOT NULL AND @IndexId<0) OR (@PartitionNumber IS NOT NULL AND @PartitionNumber<1))
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'Ungültige Physical-Stats-Parameter.'; INSERT [#IndexPhysicalStats_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus='GEZIELT' AND NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]='FULL_OBJECT') AND (NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]='SCHEMA') OR NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_NameFilters] WHERE [FilterType]='OBJECT'))
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'GEZIELT benötigt exakte @SchemaNameLike- und @ObjectNameLike-Werte.'; INSERT [#IndexPhysicalStats_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND @PhysicalAllowed=0
 BEGIN SET @OverallStatus='DENIED_GROUP'; SET @ErrorMessage=N'PHYSICAL_STATS_DEEP ist nicht freigegeben.'; INSERT [#IndexPhysicalStats_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE'
 BEGIN
  DECLARE @DbId int,@DbName sysname,@Sql nvarchar(max),@Rows bigint;
  DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR SELECT [DatabaseId],[DatabaseName] FROM [#IndexPhysicalStats_DatabaseCandidates];
  OPEN dbcur; FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  WHILE @@FETCH_STATUS=0
  BEGIN
   BEGIN TRY
    SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
DECLARE @ObjectIdFilter int=NULL;
IF @pMode=''GEZIELT''
BEGIN
 SELECT @ObjectIdFilter=[o].[object_id]
 FROM sys.objects AS [o] WITH (NOLOCK)
 JOIN sys.schemas AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
 WHERE [o].[type] IN (''U'',''V'')'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+N';
 IF @ObjectIdFilter IS NULL THROW 50001,N''Zielobjekt nicht gefunden oder nicht sichtbar; Physical Stats werden nicht mit NULL-Wildcard aufgerufen.'',1;
END;
INSERT #IndexPhysicalStats_Result
SELECT TOP (@pMaxRows) @pDbName,[s].[name],[o].[name],[ps].[object_id],[ps].[index_id],[i].[name],[i].[type_desc],[ps].[partition_number],[ps].[index_level],[ps].[alloc_unit_type_desc],[ps].[index_depth],[ps].[index_type_desc],
 [ps].[avg_fragmentation_in_percent],[ps].[fragment_count],[ps].[avg_fragment_size_in_pages],[ps].[page_count],[ps].[avg_page_space_used_in_percent],[ps].[record_count],[ps].[ghost_record_count],[ps].[version_ghost_record_count],
 [ps].[min_record_size_in_bytes],[ps].[max_record_size_in_bytes],[ps].[avg_record_size_in_bytes],[ps].[forwarded_record_count],[ps].[compressed_page_count],@pScanMode
FROM sys.dm_db_index_physical_stats(@pDbId,@ObjectIdFilter,@pIndexId,@pPartition,@pScanMode) AS [ps]
LEFT JOIN sys.objects AS [o] WITH (NOLOCK) ON [o].[object_id]=[ps].[object_id]
LEFT JOIN sys.schemas AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
LEFT JOIN sys.indexes AS [i] WITH (NOLOCK) ON [i].[object_id]=[ps].[object_id] AND [i].[index_id]=[ps].[index_id]
WHERE [ps].[page_count]>=@pMinPages AND [ps].[avg_fragmentation_in_percent]>=@pMinFrag'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+@IndexPredicateI+N'
ORDER BY [ps].[page_count] DESC,[ps].[avg_fragmentation_in_percent] DESC
OPTION (MAXDOP 1,RECOMPILE);';
    EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pDbId int,@pMode varchar(16),@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256),@pIndexLike nvarchar(256),@pScanMode varchar(16),@pIndexId int,@pPartition int,@pMinPages bigint,@pMinFrag decimal(9,2)',@pDbName=@DbName,@pDbId=@DbId,@pMode=@AnalyseModus,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike,@pIndexLike=@IndexNameLike,@pScanMode=@ScanMode,@pIndexId=@IndexId,@pPartition=@PartitionNumber,@pMinPages=@MinPageCount,@pMinFrag=@MinFragmentationPercent;
    SELECT @Rows=COUNT_BIG(*) FROM [#IndexPhysicalStats_Result] WHERE [DatabaseName]=@DbName; INSERT [#IndexPhysicalStats_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW DATABASE PERFORMANCE STATE oder CONTROL am Objekt' ELSE N'VIEW DATABASE STATE oder CONTROL am Objekt' END,NULL,NULL,N'Physical Stats erfolgreich; ScanMode='+@ScanMode+N'.');
   END TRY
   BEGIN CATCH
    INSERT [#IndexPhysicalStats_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER()=50001 THEN 'UNAVAILABLE_OBJECT' WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,1,0,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW DATABASE PERFORMANCE STATE oder CONTROL' ELSE N'VIEW DATABASE STATE oder CONTROL' END,ERROR_NUMBER(),ERROR_MESSAGE(),N'Physical-Stats-Fehler isoliert; übrige Datenbanken laufen weiter.');
   END CATCH;
   FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  END; CLOSE dbcur; DEALLOCATE dbcur;
  IF NOT EXISTS(SELECT 1 FROM [#IndexPhysicalStats_DatabaseStatus]) INSERT [#IndexPhysicalStats_DatabaseStatus] VALUES(@DatabaseName,'DATABASE_UNAVAILABLE',1,0,NULL,NULL,N'Keine sichtbare Online-Zieldatenbank gefunden.',NULL);
 END;



    SELECT @TotalRows = COUNT_BIG(*) FROM [#IndexPhysicalStats_Result];

    IF @OverallStatus = 'AVAILABLE'
    BEGIN
        IF EXISTS (SELECT 1 FROM [#IndexPhysicalStats_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
        BEGIN
            SET @OverallStatus = CASE WHEN @TotalRows > 0 THEN 'PARTIAL' ELSE (SELECT TOP (1) [StatusCode] FROM [#IndexPhysicalStats_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE') ORDER BY [DatabaseName]) END;
            SET @IsPartial = 1;
        END
        ELSE IF EXISTS (SELECT 1 FROM [#IndexPhysicalStats_DatabaseStatus] WHERE [StatusCode] IN ('AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
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
        SELECT [DatabaseName],[StatusCode],[IsPartial],[RowCount],[RequiredPermission],[ErrorNumber],[ErrorMessage],[Detail] FROM [#IndexPhysicalStats_DatabaseStatus] ORDER BY [DatabaseName];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#IndexPhysicalStats_Result] ORDER BY [PageCount] DESC,[AvgFragmentationPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber]; ELSE SELECT N'Index Physical Stats' [Ergebnis],[r].* FROM [#IndexPhysicalStats_Result] [r] ORDER BY [PageCount] DESC,[AvgFragmentationPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber];
    END;
    IF @JsonErzeugen=1 BEGIN
        DECLARE @JsonMeta nvarchar(max)=(SELECT @ModuleName [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@OverallStatus [statusCode],@IsPartial [isPartial],@TotalRows [rowCount] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @JsonDatabaseStatus nvarchar(max)=(SELECT * FROM [#IndexPhysicalStats_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData1 nvarchar(max)=(SELECT * FROM [#IndexPhysicalStats_Result] ORDER BY [PageCount] DESC,[AvgFragmentationPercent] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@JsonMeta,N'{}'),N',"indexPhysicalStats":',COALESCE(@JsonData1,N'[]'),N',"databaseStatus":',COALESCE(@JsonDatabaseStatus,N'[]'),N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#IndexPhysicalStats_Result'
            , @ResultLabel=N'IndexPhysicalStats'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#IndexPhysicalStats_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
