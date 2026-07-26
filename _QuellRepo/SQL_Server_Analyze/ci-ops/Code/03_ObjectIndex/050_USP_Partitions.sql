USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_Partitions
Version      : 1.0.0
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Liefert Partitionierung, Grenzwerte, Filegroups, Zeilen, Größe und Datenkompression; ungezielte Vollanalyse ist gruppengeschützt.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : Je Datenbank sys.objects, sys.schemas, sys.indexes, sys.partitions, sys.allocation_units, sys.data_spaces, sys.partition_schemes, sys.partition_functions und sys.partition_range_values.
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
  @AnalyseModus varchar(16)='GEZIELT' - GEZIELT|VOLL; VOLL benötigt CATALOG_DEEP.
  @NurPartitionierte bit=0 - nur Objekte mit mehr als einer Partition.
  @NurGemischteKompression bit=0 - nur Indizes mit mehreren Kompressionsarten.
Resultsets   : 1. Modulstatus. 2. Status je Datenbank. 3. Partitionen und Kompression.
Berechtigung : Metadata Visibility; sys.dm_db_partition_stats wird nicht benötigt.
Eigenlast    : Katalog- und Allocation-Unit-Aggregation; VOLL ist gruppengeschützt und begrenzt.
Locking      : READUNCOMMITTED-Systemkataloge und LOCK_TIMEOUT.
Partial      : Fehler je Datenbank bzw. Teilquelle werden isoliert; vorhandene
               Teilergebnisse bleiben erhalten. Das Framework vergibt keine Rechte.
Beispiele    :
  EXEC monitor.USP_Partitions @DatabaseNames=N'SampleDatabase', @ObjectNamePattern=N'FactSales';
  EXEC monitor.USP_Partitions @DatabaseNames=N'SampleDatabase', @AnalyseModus='VOLL', @NurPartitionierte=1;
  EXEC monitor.USP_Partitions @Hilfe=1;
Änderungen   : 1.0.0 - Erstfassung Phase 2.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_Partitions]
      @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @AnalyseModus                   varchar(16)   = 'GEZIELT'
    , @NurPartitionierte              bit           = 0
    , @NurGemischteKompression        bit           = 0
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'partitions',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
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
    CREATE TABLE [#Partitions_NameFilters]([FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL,[ItemOrdinal] int NOT NULL,[NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL);
    CREATE TABLE [#Partitions_DatabaseCandidates]([DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60),[UserAccessDesc] nvarchar(60),[IsReadOnly] bit,[CompatibilityLevel] tinyint,[CollationName] sysname,[RecoveryModelDesc] nvarchar(60),[IsSystemDatabase] bit,[RequestedOrdinal] int);
    DECLARE @FilterStatus varchar(40)='AVAILABLE',@FilterError nvarchar(2048)=NULL,@CrossDatabaseRequested bit=0;
    EXEC [monitor].[USP_PrepareNameFilters] @SchemaNames=@SchemaNames,@ObjectNames=@ObjectNames,@FullObjectNames=@FullObjectNames,@IndexNames=NULL,@StatisticsNames=NULL,@ColumnNames=NULL,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@FilterTable=N'#Partitions_NameFilters';
    IF @FilterStatus='AVAILABLE' EXEC [monitor].[USP_PrepareDatabaseCandidates] @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass='OBJECT_ANALYSIS_CURRENT',@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#Partitions_DatabaseCandidates';
    IF @FilterStatus='AVAILABLE' AND UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,''))))='VOLL'
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='CATALOG_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT;
    DECLARE @SchemaPredicateS nvarchar(max),@SchemaPredicateSch nvarchar(max),@ObjectPredicateO nvarchar(max),@FullObjectPredicateSO nvarchar(max),@IndexPredicateI nvarchar(max),@StatisticsPredicateSt nvarchar(max);
    SET @SchemaPredicateS=N' AND (NOT EXISTS(SELECT 1 FROM [#Partitions_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#Partitions_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @SchemaPredicateSch=REPLACE(@SchemaPredicateS,N'[s].[name]',N'[sch].[name]');
    SET @ObjectPredicateO=N' AND (NOT EXISTS(SELECT 1 FROM [#Partitions_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#Partitions_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @FullObjectPredicateSO=N' AND (NOT EXISTS(SELECT 1 FROM [#Partitions_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#Partitions_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDbName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @IndexPredicateI=N' AND (NOT EXISTS(SELECT 1 FROM [#Partitions_NameFilters] WHERE [FilterType]=''INDEX'') OR EXISTS(SELECT 1 FROM [#Partitions_NameFilters] [f] WHERE [f].[FilterType]=''INDEX'' AND [f].[NameValue]=[i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @StatisticsPredicateSt=N' AND (NOT EXISTS(SELECT 1 FROM [#Partitions_NameFilters] WHERE [FilterType]=''STATISTICS'') OR EXISTS(SELECT 1 FROM [#Partitions_NameFilters] [f] WHERE [f].[FilterType]=''STATISTICS'' AND [f].[NameValue]=[st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
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
        PRINT N'monitor.USP_Partitions';        PRINT N'@DatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken; N'''' = keine Einschränkung.';        PRINT N'@SystemdatenbankenEinbeziehen bit = 0: Systemdatenbanken einbeziehen.';        PRINT N'Exakte Listen und ...NamePattern sind gegenseitig exklusiv. Pattern: LIKE (Default/like:), regex: oder regexi:.';
        PRINT N'Datenbankauswahl ohne Vorabbegrenzung; @MaxZeilen int: harte Ergebnismengenbegrenzung.';
        PRINT N'@LockTimeoutMs int = 0: Metadatenzugriff wartet standardmäßig nicht auf Locks.';
        PRINT N'@PrintMeldungen bit = 1: strukturierte Warnungen zusätzlich in der Console.';
        PRINT N'Die Procedure liefert Partitionen, Grenzwerte, Filegroups, Größe und Kompression.';
        PRINT N'@AnalyseModus=GEZIELT: Schema- oder Objektfilter erforderlich; VOLL prüft CATALOG_DEEP.';
        PRINT N'@NurPartitionierte: nur Indizes/Heaps mit mehr als einer Partition.';
        PRINT N'@NurGemischteKompression: nur Objekte mit unterschiedlichen data_compression_desc-Werten.';
        PRINT N'@Hilfe bit = 0: 1 zeigt diese Hilfe und führt keine Analyse aus.';
        RETURN;
 END;

    DECLARE @ModuleName sysname = N'USP_Partitions';
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();

    DECLARE @OverallStatus varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @TotalRows bigint = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Detail nvarchar(2000) = NULL;

    CREATE TABLE [#Partitions_DatabaseStatus]
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
        INSERT [#Partitions_DatabaseStatus]([DatabaseName], [StatusCode], [IsPartial], [RowCount], [RequiredPermission], [ErrorNumber], [ErrorMessage], [Detail])
        VALUES(@DatabaseName, @OverallStatus, 1, 0, NULL, NULL, @ErrorMessage, N'Keine Datenbankanalyse ausgeführt.');
        SET @IsPartial = 1;
    END
    ELSE
    BEGIN
        SET LOCK_TIMEOUT 0;
    END;

 DECLARE @CatalogAllowed bit=1; IF @AnalyseModus='VOLL' SELECT @CatalogAllowed=COALESCE(MAX(CONVERT(tinyint,[IsAllowed])),0) FROM [monitor].[VW_AnalyseAccessCurrent] WHERE [AnalysisClass]='CATALOG_DEEP';
 CREATE TABLE [#Partitions_Result]
 (
  [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL,[ObjectId] int NOT NULL,
  [IndexId] int NOT NULL,[IndexName] sysname NULL,[IndexTypeDesc] nvarchar(60) NULL,[PartitionNumber] int NOT NULL,[PartitionCount] int NOT NULL,
  [PartitionId] bigint NOT NULL,[HobtId] bigint NULL,[RowCount] bigint NULL,[ReservedMb] decimal(19,2) NULL,[UsedMb] decimal(19,2) NULL,
  [DataCompressionDesc] nvarchar(60) NULL,[XmlCompressionDesc] varchar(3) NULL,[DataSpaceName] sysname NULL,[DestinationFilegroupName] sysname NULL,
  [PartitionSchemeName] sysname NULL,[PartitionFunctionName] sysname NULL,[BoundaryOnRight] bit NULL,
  [LowerBoundaryValue] nvarchar(4000) NULL,[LowerBoundaryInclusive] bit NULL,[UpperBoundaryValue] nvarchar(4000) NULL,[UpperBoundaryInclusive] bit NULL,
  [HasMixedCompression] bit NOT NULL
 );
 IF @OverallStatus='AVAILABLE' AND @AnalyseModus NOT IN ('GEZIELT','VOLL')
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'@AnalyseModus muss GEZIELT oder VOLL sein.'; INSERT [#Partitions_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus='GEZIELT' AND NOT EXISTS(SELECT 1 FROM [#Partitions_NameFilters]) AND @SchemaNamePattern IS NULL AND @ObjectNamePattern IS NULL
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'GEZIELT erfordert eine exakte Namensliste, @FullObjectNames oder ein Schema-/Objekt-Pattern.'; INSERT [#Partitions_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus='VOLL' AND @CatalogAllowed=0
 BEGIN SET @OverallStatus='DENIED_GROUP'; SET @ErrorMessage=N'CATALOG_DEEP ist nicht freigegeben.'; INSERT [#Partitions_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE'
 BEGIN
  DECLARE @DbId int,@DbName sysname,@Sql nvarchar(max),@Rows bigint,@XmlExpr nvarchar(200);
  SET @XmlExpr=CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'[p].[xml_compression_desc]' ELSE N'CONVERT(varchar(3),NULL)' END;
  DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR SELECT [DatabaseId],[DatabaseName] FROM [#Partitions_DatabaseCandidates];
  OPEN dbcur; FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  WHILE @@FETCH_STATUS=0
  BEGIN
   BEGIN TRY
    SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
;WITH [P] AS
(
    SELECT
          [p].*
        , COUNT(*) OVER (PARTITION BY [p].[object_id], [p].[index_id]) AS [PartitionCount]
        , MIN([p].[data_compression_desc]) OVER (PARTITION BY [p].[object_id], [p].[index_id]) AS [MinCompression]
        , MAX([p].[data_compression_desc]) OVER (PARTITION BY [p].[object_id], [p].[index_id]) AS [MaxCompression]
    FROM [sys].[partitions] AS [p] WITH (NOLOCK)
),
[A] AS
(
    SELECT
          [p].[partition_id]
        , SUM(CONVERT(bigint, [au].[total_pages])) AS [ReservedPages]
        , SUM(CONVERT(bigint, [au].[used_pages])) AS [UsedPages]
    FROM [sys].[partitions] AS [p] WITH (NOLOCK)
    LEFT JOIN [sys].[allocation_units] AS [au] WITH (NOLOCK)
      ON [au].[container_id] = CASE WHEN [au].[type] = 2 THEN [p].[partition_id] ELSE [p].[hobt_id] END
    GROUP BY [p].[partition_id]
)
INSERT [#Partitions_Result]
(
      [DatabaseName], [SchemaName], [ObjectName], [ObjectId], [IndexId], [IndexName], [IndexTypeDesc]
    , [PartitionNumber], [PartitionCount], [PartitionId], [HobtId], [RowCount], [ReservedMb], [UsedMb]
    , [DataCompressionDesc], [XmlCompressionDesc], [DataSpaceName], [DestinationFilegroupName]
    , [PartitionSchemeName], [PartitionFunctionName], [BoundaryOnRight]
    , [LowerBoundaryValue], [LowerBoundaryInclusive], [UpperBoundaryValue], [UpperBoundaryInclusive]
    , [HasMixedCompression]
)
SELECT TOP (@pMaxRows)
      @pDbName
    , [s].[name]
    , [o].[name]
    , [o].[object_id]
    , [i].[index_id]
    , [i].[name]
    , [i].[type_desc]
    , [p].[partition_number]
    , [p].[PartitionCount]
    , [p].[partition_id]
    , [p].[hobt_id]
    , [p].[rows]
    , CONVERT(decimal(19,2), [a].[ReservedPages] / 128.0)
    , CONVERT(decimal(19,2), [a].[UsedPages] / 128.0)
    , [p].[data_compression_desc]
    , ' + @XmlExpr + N'
    , [ds].[name]
    , [fg].[name]
    , [ps].[name]
    , [pf].[name]
    , [pf].[boundary_value_on_right]
    , CONVERT(nvarchar(4000), [lo].[value])
    , CASE WHEN [lo].[value] IS NULL THEN NULL WHEN [pf].[boundary_value_on_right] = 1 THEN 1 ELSE 0 END
    , CONVERT(nvarchar(4000), [hi].[value])
    , CASE WHEN [hi].[value] IS NULL THEN NULL WHEN [pf].[boundary_value_on_right] = 1 THEN 0 ELSE 1 END
    , CONVERT(bit, CASE WHEN [p].[MinCompression] <> [p].[MaxCompression] THEN 1 ELSE 0 END)
FROM [P] AS [p]
JOIN [sys].[objects] AS [o] WITH (NOLOCK)
  ON [o].[object_id] = [p].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id] = [o].[schema_id]
JOIN [sys].[indexes] AS [i] WITH (NOLOCK)
  ON [i].[object_id] = [p].[object_id]
 AND [i].[index_id] = [p].[index_id]
LEFT JOIN [A] AS [a]
  ON [a].[partition_id] = [p].[partition_id]
LEFT JOIN [sys].[data_spaces] AS [ds] WITH (NOLOCK)
  ON [ds].[data_space_id] = [i].[data_space_id]
LEFT JOIN [sys].[partition_schemes] AS [ps] WITH (NOLOCK)
  ON [ps].[data_space_id] = [i].[data_space_id]
LEFT JOIN [sys].[partition_functions] AS [pf] WITH (NOLOCK)
  ON [pf].[function_id] = [ps].[function_id]
LEFT JOIN [sys].[destination_data_spaces] AS [dds] WITH (NOLOCK)
  ON [dds].[partition_scheme_id] = [ps].[data_space_id]
 AND [dds].[destination_id] = [p].[partition_number]
LEFT JOIN [sys].[data_spaces] AS [fg] WITH (NOLOCK)
  ON [fg].[data_space_id] = [dds].[data_space_id]
LEFT JOIN [sys].[partition_range_values] AS [lo] WITH (NOLOCK)
  ON [lo].[function_id] = [pf].[function_id]
 AND [lo].[boundary_id] = [p].[partition_number] - 1
LEFT JOIN [sys].[partition_range_values] AS [hi] WITH (NOLOCK)
  ON [hi].[function_id] = [pf].[function_id]
 AND [hi].[boundary_id] = [p].[partition_number]
WHERE [o].[type] IN (''U'', ''V'')
  AND [o].[is_ms_shipped] = 0
'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+N'
  AND (@pOnlyPartitioned = 0 OR [p].[PartitionCount] > 1)
  AND (@pOnlyMixed = 0 OR [p].[MinCompression] <> [p].[MaxCompression])
ORDER BY [a].[ReservedPages] DESC, [o].[object_id], [i].[index_id], [p].[partition_number]
OPTION (MAXDOP 1, RECOMPILE);';
        EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256),@pOnlyPartitioned bit,@pOnlyMixed bit',@pDbName=@DbName,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike,@pOnlyPartitioned=@NurPartitionierte,@pOnlyMixed=@NurGemischteKompression;
    SELECT @Rows=COUNT_BIG(*) FROM [#Partitions_Result] WHERE [DatabaseName]=@DbName; INSERT [#Partitions_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,N'Metadata Visibility',NULL,NULL,N'Partitionen und Allocation Units erfolgreich gelesen.');
   END TRY
   BEGIN CATCH
    INSERT [#Partitions_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,1,0,N'Metadata Visibility',ERROR_NUMBER(),ERROR_MESSAGE(),N'Partitionsfehler isoliert.');
   END CATCH;
   FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  END; CLOSE dbcur; DEALLOCATE dbcur;
  IF NOT EXISTS(SELECT 1 FROM [#Partitions_DatabaseStatus]) INSERT [#Partitions_DatabaseStatus] VALUES(@DatabaseName,'DATABASE_UNAVAILABLE',1,0,NULL,NULL,N'Keine sichtbare Online-Zieldatenbank gefunden.',NULL);
 END;



    SELECT @TotalRows = COUNT_BIG(*) FROM [#Partitions_Result];

    IF @OverallStatus = 'AVAILABLE'
    BEGIN
        IF EXISTS (SELECT 1 FROM [#Partitions_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
        BEGIN
            SET @OverallStatus = CASE WHEN @TotalRows > 0 THEN 'PARTIAL' ELSE (SELECT TOP (1) [StatusCode] FROM [#Partitions_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE') ORDER BY [DatabaseName]) END;
            SET @IsPartial = 1;
        END
        ELSE IF EXISTS (SELECT 1 FROM [#Partitions_DatabaseStatus] WHERE [StatusCode] IN ('AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
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
        SELECT [DatabaseName],[StatusCode],[IsPartial],[RowCount],[RequiredPermission],[ErrorNumber],[ErrorMessage],[Detail] FROM [#Partitions_DatabaseStatus] ORDER BY [DatabaseName];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#Partitions_Result] ORDER BY [ReservedMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber]; ELSE SELECT N'Partition' [Ergebnis],[r].* FROM [#Partitions_Result] [r] ORDER BY [ReservedMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber];
    END;
    IF @JsonErzeugen=1 BEGIN
        DECLARE @JsonMeta nvarchar(max)=(SELECT @ModuleName [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@OverallStatus [statusCode],@IsPartial [isPartial],@TotalRows [rowCount] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @JsonDatabaseStatus nvarchar(max)=(SELECT * FROM [#Partitions_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData1 nvarchar(max)=(SELECT * FROM [#Partitions_Result] ORDER BY [ReservedMb] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId],[PartitionNumber] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@JsonMeta,N'{}'),N',"partitions":',COALESCE(@JsonData1,N'[]'),N',"databaseStatus":',COALESCE(@JsonDatabaseStatus,N'[]'),N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#Partitions_Result'
            , @ResultLabel=N'Partitions'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#Partitions_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
