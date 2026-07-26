USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_IndexUsage
Version      : 1.1.0
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Liefert kumulative Indexnutzung seit dem letzten DMV-Reset und klassifiziert gelesene, schreiblastige sowie seit Reset ungenutzte Indizes.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.dm_db_index_usage_stats, sys.dm_db_xtp_index_stats,
               sys.dm_os_sys_info sowie je Datenbank sys.objects, sys.tables,
               sys.schemas, sys.indexes, sys.hash_indexes und sys.partitions.
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
  @NurUngenutzt bit = 0 - nur seit Reset nicht gelesene Indizes.
  @MinUserUpdates bigint = 0 - Mindestzahl User-Updates.
  @PrimaryUndUniqueEinbeziehen bit = 1 - Constraint-Indizes einbeziehen.
  @MitMemoryOptimized bit = 1 - separaten In-Memory-OLTP-Resultset versuchen.
Resultsets   : 1. Modulstatus. 2. Status je Datenbank und Quelle.
               3. Rowstore-/Columnstore-/Spatial-Indexnutzung.
               4. In-Memory-OLTP-Indexnutzung.
Berechtigung : SQL Server 2019 VIEW SERVER STATE; SQL Server 2022+ VIEW SERVER PERFORMANCE STATE. Metadaten zusätzlich gemäß Sichtbarkeit.
Eigenlast    : Moderate DMV-/Katalogabfrage; keine Physical-Stats-Scans.
Locking      : DMV plus READUNCOMMITTED-Kataloge; LOCK_TIMEOUT konfigurierbar.
Partial      : Fehler je Datenbank bzw. Teilquelle werden isoliert; vorhandene
               Teilergebnisse bleiben erhalten. Das Framework vergibt keine Rechte.
Beispiele    :
  EXEC monitor.USP_IndexUsage @DatabaseNames=N'[SampleDatabase]', @ObjectNamePattern=N'like:Fact%';
  EXEC monitor.USP_IndexUsage @DatabaseNames=N'SampleDatabase', @AnalyseModus='VOLL', @NurUngenutzt=1, @MinUserUpdates=1000;
  EXEC monitor.USP_IndexUsage @Hilfe=1;
Änderungen   : 1.1.0 - Indexed Views, Spatial-Kennzeichnung und isolierter
               In-Memory-OLTP-Resultset ergänzt.
               1.0.0 - Erstfassung Phase 2.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_IndexUsage]
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
    , @NurUngenutzt                   bit           = 0
    , @MinUserUpdates                 bigint        = 0
    , @PrimaryUndUniqueEinbeziehen    bit           = 1
    , @MitMemoryOptimized              bit           = 1
    , @MaxZeilen                      int           = 5000
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'rowstoreIndexes',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
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
    CREATE TABLE [#IndexUsage_NameFilters]([FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL,[ItemOrdinal] int NOT NULL,[NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL);
    CREATE TABLE [#IndexUsage_DatabaseCandidates]([DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60),[UserAccessDesc] nvarchar(60),[IsReadOnly] bit,[CompatibilityLevel] tinyint,[CollationName] sysname,[RecoveryModelDesc] nvarchar(60),[IsSystemDatabase] bit,[RequestedOrdinal] int);
    DECLARE @FilterStatus varchar(40)='AVAILABLE',@FilterError nvarchar(2048)=NULL,@CrossDatabaseRequested bit=0;
    EXEC [monitor].[USP_PrepareNameFilters] @SchemaNames=@SchemaNames,@ObjectNames=@ObjectNames,@FullObjectNames=@FullObjectNames,@IndexNames=NULL,@StatisticsNames=NULL,@ColumnNames=NULL,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@FilterTable=N'#IndexUsage_NameFilters';
    IF @FilterStatus='AVAILABLE' EXEC [monitor].[USP_PrepareDatabaseCandidates] @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass='OBJECT_ANALYSIS_CURRENT',@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#IndexUsage_DatabaseCandidates';
    IF @FilterStatus='AVAILABLE' AND UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,''))))='VOLL'
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='CATALOG_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT;
    DECLARE @SchemaPredicateS nvarchar(max),@SchemaPredicateSch nvarchar(max),@ObjectPredicateO nvarchar(max),@FullObjectPredicateSO nvarchar(max),@IndexPredicateI nvarchar(max),@StatisticsPredicateSt nvarchar(max);
    SET @SchemaPredicateS=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @SchemaPredicateSch=REPLACE(@SchemaPredicateS,N'[s].[name]',N'[sch].[name]');
    SET @ObjectPredicateO=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @FullObjectPredicateSO=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDbName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @IndexPredicateI=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] WHERE [FilterType]=''INDEX'') OR EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] [f] WHERE [f].[FilterType]=''INDEX'' AND [f].[NameValue]=[i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @StatisticsPredicateSt=N' AND (NOT EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] WHERE [FilterType]=''STATISTICS'') OR EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters] [f] WHERE [f].[FilterType]=''STATISTICS'' AND [f].[NameValue]=[st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    IF @SchemaPatternMode='LIKE' BEGIN SET @SchemaPredicateS+=N' AND [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';SET @SchemaPredicateSch+=N' AND [sch].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';END;
    IF @SchemaPatternMode IN('REGEX','REGEXI') BEGIN SET @SchemaPredicateS+=N' AND REGEXP_LIKE([s].[name],N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''','''+@SchemaRegexFlags+N''')';SET @SchemaPredicateSch+=N' AND REGEXP_LIKE([sch].[name],N'''+REPLACE(@SchemaPatternValue,N'''',N'''''')+N''','''+@SchemaRegexFlags+N''')';END;
    IF @ObjectPatternMode='LIKE' SET @ObjectPredicateO+=N' AND [o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @ObjectPatternMode IN('REGEX','REGEXI') SET @ObjectPredicateO+=N' AND REGEXP_LIKE([o].[name],N'''+REPLACE(@ObjectPatternValue,N'''',N'''''')+N''','''+@ObjectRegexFlags+N''')';
    IF @IndexPatternMode='LIKE' SET @IndexPredicateI+=N' AND [i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@IndexPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @IndexPatternMode IN('REGEX','REGEXI') SET @IndexPredicateI+=N' AND REGEXP_LIKE([i].[name],N'''+REPLACE(@IndexPatternValue,N'''',N'''''')+N''','''+@IndexRegexFlags+N''')';
    IF @StatisticsPatternMode='LIKE' SET @StatisticsPredicateSt+=N' AND [st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE N'''+REPLACE(@StatisticsPatternValue,N'''',N'''''')+N''' COLLATE SQL_Latin1_General_CP1_CS_AS';
    IF @StatisticsPatternMode IN('REGEX','REGEXI') SET @StatisticsPredicateSt+=N' AND REGEXP_LIKE([st].[name],N'''+REPLACE(@StatisticsPatternValue,N'''',N'''''')+N''','''+@StatisticsRegexFlags+N''')';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);
    SET @AnalyseModus=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,'GEZIELT'))));
    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_IndexUsage';        PRINT N'@DatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken; N'''' = keine Einschränkung.';        PRINT N'@SystemdatenbankenEinbeziehen bit = 0: Systemdatenbanken einbeziehen.';        PRINT N'Exakte Listen und ...NamePattern sind gegenseitig exklusiv. Pattern: LIKE (Default/like:), regex: oder regexi:.';
        PRINT N'Datenbankauswahl ohne Vorabbegrenzung; @MaxZeilen int: harte Ergebnismengenbegrenzung.';
        PRINT N'@LockTimeoutMs int = 0: Metadatenzugriff wartet standardmäßig nicht auf Locks.';
        PRINT N'@PrintMeldungen bit = 1: strukturierte Warnungen zusätzlich in der Console.';
        PRINT N'Die Procedure liefert die kumulative Indexnutzung seit dem DMV-Reset und keine Ausführungshistorie.';
        PRINT N'@AnalyseModus varchar(16) = GEZIELT: GEZIELT benötigt Schema-/Objektfilter; VOLL prüft CATALOG_DEEP.';
        PRINT N'@NurUngenutzt bit = 0: nur Indizes ohne User Seek/Scan/Lookup seit Reset.';
        PRINT N'@MinUserUpdates bigint = 0: Mindestanzahl Schreiboperationen.';
        PRINT N'@PrimaryUndUniqueEinbeziehen bit = 1: PK-/Unique-Constraint-Indizes einbeziehen.';
        PRINT N'@MitMemoryOptimized bit = 1: sys.dm_db_xtp_index_stats als isolierten vierten Resultset ausgeben.';
        PRINT N'@MinUserUpdates ist auf den Rowstore-Resultset beschränkt; die XTP-DMV besitzt keinen vergleichbaren Update-Counter.';
        PRINT N'Beispiel: EXEC monitor.USP_IndexUsage @DatabaseNames=N''[DWH]'', @ObjectNamePattern=N''like:Fact%'', @NurUngenutzt=1;';
        PRINT N'@Hilfe bit = 0: 1 zeigt diese Hilfe und führt keine Analyse aus.';
        RETURN;
    END;

    DECLARE @ModuleName sysname = N'USP_IndexUsage';
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();

    DECLARE @OverallStatus varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @TotalRows bigint = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Detail nvarchar(2000) = NULL;

    CREATE TABLE [#IndexUsage_DatabaseStatus]
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
        INSERT [#IndexUsage_DatabaseStatus]([DatabaseName], [StatusCode], [IsPartial], [RowCount], [RequiredPermission], [ErrorNumber], [ErrorMessage], [Detail])
        VALUES(@DatabaseName, @OverallStatus, 1, 0, NULL, NULL, @ErrorMessage, N'Keine Datenbankanalyse ausgeführt.');
        SET @IsPartial = 1;
    END
    ELSE
    BEGIN
        SET LOCK_TIMEOUT 0;
    END;

    DECLARE @CatalogAllowed bit=1;
    IF @AnalyseModus='VOLL'
        SELECT @CatalogAllowed=COALESCE(MAX(CONVERT(tinyint,[IsAllowed])),0)
        FROM [monitor].[VW_AnalyseAccessCurrent]
        WHERE [AnalysisClass]='CATALOG_DEEP';

    CREATE TABLE [#IndexUsage_Result]
    (
          [DatabaseName]           sysname        NOT NULL
        , [SchemaName]             sysname        NOT NULL
        , [ObjectName]             sysname        NOT NULL
        , [ObjectId]               int            NOT NULL
        , [IndexId]                int            NOT NULL
        , [IndexName]              sysname        NULL
        , [IndexTypeDesc]          nvarchar(60)   NULL
        , [IsMemoryOptimized]      bit            NOT NULL
        , [IsSpatialIndex]         bit            NOT NULL
        , [IsPrimaryKey]           bit            NULL
        , [IsUniqueConstraint]     bit            NULL
        , [IsDisabled]             bit            NULL
        , [RowCount]               bigint         NULL
        , [UserSeeks]              bigint         NOT NULL
        , [UserScans]              bigint         NOT NULL
        , [UserLookups]            bigint         NOT NULL
        , [UserUpdates]            bigint         NOT NULL
        , [TotalUserReads]         bigint         NOT NULL
        , [ReadWriteRatio]         decimal(19,4)  NULL
        , [LastUserSeek]           datetime       NULL
        , [LastUserScan]           datetime       NULL
        , [LastUserLookup]         datetime       NULL
        , [LastUserUpdate]         datetime       NULL
        , [SystemSeeks]            bigint         NOT NULL
        , [SystemScans]            bigint         NOT NULL
        , [SystemLookups]          bigint         NOT NULL
        , [SystemUpdates]          bigint         NOT NULL
        , [DmvResetTimeServerLocal]  datetime2(3)   NULL
        , [UsageClassification]    varchar(48)    NOT NULL
    );

    CREATE TABLE [#IndexUsage_XtpResult]
    (
          [DatabaseName]           sysname        NOT NULL
        , [SchemaName]             sysname        NOT NULL
        , [ObjectName]             sysname        NOT NULL
        , [ObjectId]               int            NOT NULL
        , [IndexId]                int            NOT NULL
        , [IndexName]              sysname        NULL
        , [IndexTypeDesc]          nvarchar(60)   NULL
        , [IsPrimaryKey]           bit            NULL
        , [IsUniqueConstraint]     bit            NULL
        , [BucketCount]            bigint         NULL
        , [ScansStarted]           bigint         NOT NULL
        , [ScansRetries]           bigint         NOT NULL
        , [RowsReturned]           bigint         NOT NULL
        , [RowsTouched]            bigint         NOT NULL
        , [RowsReturnedPerScan]    decimal(28,4)  NULL
        , [RowsTouchedPerReturned] decimal(28,4)  NULL
        , [RetryPercent]           decimal(19,4)  NULL
        , [CounterScope]           nvarchar(200)  NOT NULL
        , [UsageClassification]    varchar(48)    NOT NULL
    );

    IF @OverallStatus='AVAILABLE' AND @MinUserUpdates < 0
    BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'@MinUserUpdates darf nicht negativ sein.'; INSERT [#IndexUsage_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
    ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus NOT IN ('GEZIELT','VOLL')
    BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'@AnalyseModus muss GEZIELT oder VOLL sein.'; INSERT [#IndexUsage_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
    ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus='GEZIELT' AND NOT EXISTS(SELECT 1 FROM [#IndexUsage_NameFilters]) AND @SchemaNamePattern IS NULL AND @ObjectNamePattern IS NULL
    BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'GEZIELT erfordert eine exakte Namensliste, @FullObjectNames oder ein Schema-/Objekt-Pattern. Für den vollständigen Lauf @AnalyseModus=''VOLL'' verwenden.'; INSERT [#IndexUsage_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
    ELSE IF @OverallStatus='AVAILABLE' AND @AnalyseModus='VOLL' AND @CatalogAllowed=0
    BEGIN SET @OverallStatus='DENIED_GROUP'; SET @ErrorMessage=N'CATALOG_DEEP ist für die vollständige Index-Usage-Analyse nicht freigegeben.'; INSERT [#IndexUsage_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
    ELSE IF @OverallStatus='AVAILABLE'
    BEGIN
        DECLARE @DbId int,@DbName sysname,@Sql nvarchar(max),@Rows bigint;
        DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR SELECT [DatabaseId],[DatabaseName] FROM [#IndexUsage_DatabaseCandidates];
        OPEN dbcur; FETCH NEXT FROM dbcur INTO @DbId,@DbName;
        WHILE @@FETCH_STATUS=0
        BEGIN
            BEGIN TRY
                SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
;WITH BaseRows AS
(
 SELECT [p].[object_id],[p].[index_id],SUM([p].[rows]) AS [RowCount]
 FROM sys.partitions AS [p] WITH (NOLOCK)
 GROUP BY [p].[object_id],[p].[index_id]
)
INSERT #IndexUsage_Result
SELECT TOP (@pMaxRows)
 @pDbName,[s].[name],[o].[name],[o].[object_id],[i].[index_id],[i].[name],[i].[type_desc],
 CONVERT(bit,COALESCE([t].[is_memory_optimized],0)),CONVERT(bit,CASE WHEN [i].[type]=4 THEN 1 ELSE 0 END),
 [i].[is_primary_key],[i].[is_unique_constraint],[i].[is_disabled],[br].[RowCount],
 COALESCE([u].[user_seeks],0),COALESCE([u].[user_scans],0),COALESCE([u].[user_lookups],0),COALESCE([u].[user_updates],0),
 COALESCE([u].[user_seeks],0)+COALESCE([u].[user_scans],0)+COALESCE([u].[user_lookups],0),
 CONVERT(decimal(19,4),(COALESCE([u].[user_seeks],0)+COALESCE([u].[user_scans],0)+COALESCE([u].[user_lookups],0))*1.0/NULLIF(COALESCE([u].[user_updates],0),0)),
 [u].[last_user_seek],[u].[last_user_scan],[u].[last_user_lookup],[u].[last_user_update],
 COALESCE([u].[system_seeks],0),COALESCE([u].[system_scans],0),COALESCE([u].[system_lookups],0),COALESCE([u].[system_updates],0),
 [osi].[sqlserver_start_time],
 CASE WHEN [i].[is_disabled]=1 THEN ''DISABLED''
      WHEN [i].[type]=4 THEN ''SPATIAL_NOT_IN_USAGE_DMV''
      WHEN [u].[index_id] IS NULL THEN ''NO_DMV_ROW''
      WHEN COALESCE([u].[user_seeks],0)+COALESCE([u].[user_scans],0)+COALESCE([u].[user_lookups],0)=0 AND COALESCE([u].[user_updates],0)>0 THEN ''WRITE_ONLY_SINCE_RESET''
      WHEN COALESCE([u].[user_seeks],0)+COALESCE([u].[user_scans],0)+COALESCE([u].[user_lookups],0)=0 THEN ''UNUSED_SINCE_RESET''
      WHEN COALESCE([u].[user_updates],0)=0 THEN ''READ_ONLY_SINCE_RESET'' ELSE ''READ_AND_WRITE'' END
FROM sys.objects AS [o] WITH (NOLOCK)
JOIN sys.schemas AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
LEFT JOIN sys.tables AS [t] WITH (NOLOCK) ON [t].[object_id]=[o].[object_id]
JOIN sys.indexes AS [i] WITH (NOLOCK) ON [i].[object_id]=[o].[object_id]
LEFT JOIN BaseRows AS [br] ON [br].[object_id]=[i].[object_id] AND [br].[index_id]=[i].[index_id]
LEFT JOIN sys.dm_db_index_usage_stats AS [u] WITH (NOLOCK) ON [u].[database_id]=@pDbId AND [u].[object_id]=[i].[object_id] AND [u].[index_id]=[i].[index_id]
CROSS JOIN sys.dm_os_sys_info AS [osi] WITH (NOLOCK)
WHERE [o].[type] IN (''U'',''V'') AND [o].[is_ms_shipped]=0 AND [i].[index_id]>0 AND [i].[is_hypothetical]=0
  AND COALESCE([t].[is_memory_optimized],0)=0
'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+N'
  AND (@pIncludeConstraints=1 OR ([i].[is_primary_key]=0 AND [i].[is_unique_constraint]=0))
  AND COALESCE([u].[user_updates],0)>=@pMinUpdates
  AND (@pOnlyUnused=0 OR COALESCE([u].[user_seeks],0)+COALESCE([u].[user_scans],0)+COALESCE([u].[user_lookups],0)=0)
ORDER BY COALESCE([u].[user_updates],0) DESC,[br].[RowCount] DESC
OPTION (MAXDOP 1, RECOMPILE);';
                EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pDbId int,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256),@pIncludeConstraints bit,@pMinUpdates bigint,@pOnlyUnused bit',@pDbName=@DbName,@pDbId=@DbId,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike,@pIncludeConstraints=@PrimaryUndUniqueEinbeziehen,@pMinUpdates=@MinUserUpdates,@pOnlyUnused=@NurUngenutzt;
                SELECT @Rows=COUNT_BIG(*) FROM [#IndexUsage_Result] WHERE [DatabaseName]=@DbName; INSERT [#IndexUsage_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END,NULL,NULL,N'Kumulative Werte; Resetzeit näherungsweise SQL-Server-Start.');
            END TRY
            BEGIN CATCH
                INSERT [#IndexUsage_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,1,0,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END,ERROR_NUMBER(),ERROR_MESSAGE(),N'DMV-/Katalogfehler isoliert.');
            END CATCH;

            IF @MitMemoryOptimized = 1
            BEGIN
                BEGIN TRY
                    SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
INSERT #IndexUsage_XtpResult
SELECT TOP (@pMaxRows)
       @pDbName,[s].[name],[o].[name],[o].[object_id],[i].[index_id],[i].[name],[i].[type_desc],
       [i].[is_primary_key],[i].[is_unique_constraint],[hi].[bucket_count],
       [xs].[scans_started],[xs].[scans_retries],[xs].[rows_returned],[xs].[rows_touched],
       CONVERT(decimal(28,4),[xs].[rows_returned]*1.0/NULLIF([xs].[scans_started],0)),
       CONVERT(decimal(28,4),[xs].[rows_touched]*1.0/NULLIF([xs].[rows_returned],0)),
       CONVERT(decimal(19,4),[xs].[scans_retries]*100.0/NULLIF([xs].[scans_started],0)),
       N''Seit Datenbankneustart beziehungsweise seit Erzeugung der Tabelle; nicht persistent.'',
       CASE WHEN [xs].[scans_started]=0 THEN ''NO_SCANS_SINCE_DB_RESTART''
            WHEN [xs].[scans_retries]>0 THEN ''SCAN_RETRIES_OCCURRED''
            WHEN [xs].[rows_touched]>[xs].[rows_returned]*10 AND [xs].[rows_returned]>0 THEN ''HIGH_ROWS_TOUCHED_RATIO''
            ELSE ''ACTIVE'' END
FROM sys.dm_db_xtp_index_stats AS [xs] WITH (NOLOCK)
JOIN sys.objects AS [o] WITH (NOLOCK) ON [o].[object_id]=CONVERT(int,[xs].[object_id])
JOIN sys.schemas AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
JOIN sys.tables AS [tb] WITH (NOLOCK) ON [tb].[object_id]=[o].[object_id] AND [tb].[is_memory_optimized]=1
JOIN sys.indexes AS [i] WITH (NOLOCK) ON [i].[object_id]=[o].[object_id] AND [i].[index_id]=CONVERT(int,[xs].[index_id])
LEFT JOIN sys.hash_indexes AS [hi] WITH (NOLOCK) ON [hi].[object_id]=[i].[object_id] AND [hi].[index_id]=[i].[index_id]
WHERE 1=1'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+N'
  AND (@pIncludeConstraints=1 OR ([i].[is_primary_key]=0 AND [i].[is_unique_constraint]=0))
  AND (@pOnlyUnused=0 OR [xs].[scans_started]=0)
ORDER BY [xs].[scans_started] DESC,[xs].[rows_touched] DESC
OPTION (MAXDOP 1,RECOMPILE);';
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDbName sysname,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256),@pIncludeConstraints bit,@pOnlyUnused bit',
                         @pDbName=@DbName,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike,
                         @pIncludeConstraints=@PrimaryUndUniqueEinbeziehen,@pOnlyUnused=@NurUngenutzt;
                    SELECT @Rows=COUNT_BIG(*) FROM [#IndexUsage_XtpResult] WHERE [DatabaseName]=@DbName;
                    INSERT [#IndexUsage_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,
                         CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW DATABASE PERFORMANCE STATE' ELSE N'VIEW DATABASE STATE' END,
                         NULL,NULL,N'Quelle XTP_INDEX_USAGE erfolgreich gelesen.');
                END TRY
                BEGIN CATCH
                    INSERT [#IndexUsage_DatabaseStatus] VALUES(@DbName,
                         CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN (207,208,4121) THEN 'UNAVAILABLE_OBJECT' ELSE 'ERROR_HANDLED' END,
                         1,0,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW DATABASE PERFORMANCE STATE' ELSE N'VIEW DATABASE STATE' END,
                         ERROR_NUMBER(),ERROR_MESSAGE(),N'Quelle XTP_INDEX_USAGE fehlgeschlagen; Rowstore-Ergebnis bleibt erhalten.');
                END CATCH;
            END;

            FETCH NEXT FROM dbcur INTO @DbId,@DbName;
        END; CLOSE dbcur; DEALLOCATE dbcur;
        IF NOT EXISTS(SELECT 1 FROM [#IndexUsage_DatabaseStatus]) INSERT [#IndexUsage_DatabaseStatus] VALUES(@DatabaseName,'DATABASE_UNAVAILABLE',1,0,NULL,NULL,N'Keine sichtbare Online-Zieldatenbank gefunden.',NULL);
    END;



    SELECT @TotalRows=(SELECT COUNT_BIG(*) FROM [#IndexUsage_Result])+(SELECT COUNT_BIG(*) FROM [#IndexUsage_XtpResult]);

    IF @OverallStatus = 'AVAILABLE'
    BEGIN
        IF EXISTS (SELECT 1 FROM [#IndexUsage_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
        BEGIN
            SET @OverallStatus = CASE WHEN @TotalRows > 0 THEN 'PARTIAL' ELSE (SELECT TOP (1) [StatusCode] FROM [#IndexUsage_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE') ORDER BY [DatabaseName]) END;
            SET @IsPartial = 1;
        END
        ELSE IF EXISTS (SELECT 1 FROM [#IndexUsage_DatabaseStatus] WHERE [StatusCode] IN ('AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
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
        SELECT [DatabaseName],[StatusCode],[IsPartial],[RowCount],[RequiredPermission],[ErrorNumber],[ErrorMessage],[Detail] FROM [#IndexUsage_DatabaseStatus] ORDER BY [DatabaseName];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#IndexUsage_Result] ORDER BY [UserUpdates] DESC,[TotalUserReads] ASC,[DatabaseName],[SchemaName],[ObjectName],[IndexId]; ELSE SELECT N'Indexnutzung' [Ergebnis],[r].* FROM [#IndexUsage_Result] [r] ORDER BY [UserUpdates] DESC,[TotalUserReads] ASC,[DatabaseName],[SchemaName],[ObjectName],[IndexId];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#IndexUsage_XtpResult] ORDER BY [ScansStarted] DESC,[RowsTouched] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId]; ELSE SELECT N'Indexnutzung' [Ergebnis],[r].* FROM [#IndexUsage_XtpResult] [r] ORDER BY [ScansStarted] DESC,[RowsTouched] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId];
    END;
    IF @JsonErzeugen=1 BEGIN
        DECLARE @JsonMeta nvarchar(max)=(SELECT @ModuleName [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@OverallStatus [statusCode],@IsPartial [isPartial],@TotalRows [rowCount] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @JsonDatabaseStatus nvarchar(max)=(SELECT * FROM [#IndexUsage_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData1 nvarchar(max)=(SELECT * FROM [#IndexUsage_Result] ORDER BY [UserUpdates] DESC,[TotalUserReads] ASC,[DatabaseName],[SchemaName],[ObjectName],[IndexId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData2 nvarchar(max)=(SELECT * FROM [#IndexUsage_XtpResult] ORDER BY [ScansStarted] DESC,[RowsTouched] DESC,[DatabaseName],[SchemaName],[ObjectName],[IndexId] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@JsonMeta,N'{}'),N',"rowstoreIndexes":',COALESCE(@JsonData1,N'[]'),N',"memoryOptimizedIndexes":',COALESCE(@JsonData2,N'[]'),N',"databaseStatus":',COALESCE(@JsonDatabaseStatus,N'[]'),N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#IndexUsage_Result'
            , @ResultLabel=N'IndexUsage'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#IndexUsage_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
