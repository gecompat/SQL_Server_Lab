USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_MissingIndexes
Version      : 1.0.0
Stand        : 2026-07-14
Typ          : Stored Procedure
Zweck        : Liefert aktuelle Missing-Index-Hinweise aus den flüchtigen SQL-Server-DMVs, bewertet Nutzenindikatoren und erzeugt nur einen prüfpflichtigen DDL-Entwurf.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.dm_db_missing_index_details, sys.dm_db_missing_index_groups, sys.dm_db_missing_index_group_stats sowie je Datenbank sys.objects, sys.schemas und sys.tables.
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
  @MinUserReads bigint = 1 - Mindestanzahl Seeks+Scans.
  @MinAvgUserImpact decimal(9,2) = 0 - Mindestwirkung in Prozent.
  @MinImprovementMeasure decimal(28,2) = 0 - Mindest-Nutzenindikator.
Resultsets   : 1. Modulstatus. 2. Status je Datenbank. 3. Missing-Index-Hinweise.
Berechtigung : SQL Server 2019 VIEW SERVER STATE; SQL Server 2022+ VIEW SERVER PERFORMANCE STATE; Metadatensicht kann zusätzlich begrenzt sein.
Eigenlast    : DMV-Menge ist intern begrenzt; Join und Sortierung werden durch TOP begrenzt.
Locking      : Server-DMVs und READUNCOMMITTED-Kataloge; keine DDL-Ausführung.
Partial      : Fehler je Datenbank bzw. Teilquelle werden isoliert; vorhandene
               Teilergebnisse bleiben erhalten. Das Framework vergibt keine Rechte.
Beispiele    :
  EXEC monitor.USP_MissingIndexes @DatabaseNames=N'SampleDatabase';
  EXEC monitor.USP_MissingIndexes @DatabaseNames=N'SampleDatabase', @MinUserReads=100, @MinAvgUserImpact=50;
  EXEC monitor.USP_MissingIndexes @Hilfe=1;
Änderungen   : 1.0.0 - Erstfassung Phase 2.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_MissingIndexes]
      @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                    nvarchar(max)  = NULL
    , @SchemaNamePattern              nvarchar(4000) = NULL
    , @ObjectNames                    nvarchar(max)  = NULL
    , @ObjectNamePattern              nvarchar(4000) = NULL
    , @FullObjectNames                nvarchar(max)  = NULL
    , @MinUserReads                   bigint        = 1
    , @MinAvgUserImpact               decimal(9,2)  = 0
    , @MinImprovementMeasure          decimal(28,2) = 0
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'missingIndexes',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
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
    CREATE TABLE [#MissingIndexes_NameFilters]([FilterType] varchar(20) COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL,[ItemOrdinal] int NOT NULL,[NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[SchemaName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL,[ObjectName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL);
    CREATE TABLE [#MissingIndexes_DatabaseCandidates]([DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60),[UserAccessDesc] nvarchar(60),[IsReadOnly] bit,[CompatibilityLevel] tinyint,[CollationName] sysname,[RecoveryModelDesc] nvarchar(60),[IsSystemDatabase] bit,[RequestedOrdinal] int);
    DECLARE @FilterStatus varchar(40)='AVAILABLE',@FilterError nvarchar(2048)=NULL,@CrossDatabaseRequested bit=0;
    EXEC [monitor].[USP_PrepareNameFilters] @SchemaNames=@SchemaNames,@ObjectNames=@ObjectNames,@FullObjectNames=@FullObjectNames,@IndexNames=NULL,@StatisticsNames=NULL,@ColumnNames=NULL,@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@FilterTable=N'#MissingIndexes_NameFilters';
    IF @FilterStatus='AVAILABLE' EXEC [monitor].[USP_PrepareDatabaseCandidates] @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass='MISSING_INDEX_CURRENT',@StatusCode=@FilterStatus OUTPUT,@ErrorMessage=@FilterError OUTPUT,@CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#MissingIndexes_DatabaseCandidates';
    DECLARE @SchemaPredicateS nvarchar(max),@SchemaPredicateSch nvarchar(max),@ObjectPredicateO nvarchar(max),@FullObjectPredicateSO nvarchar(max),@IndexPredicateI nvarchar(max),@StatisticsPredicateSt nvarchar(max);
    SET @SchemaPredicateS=N' AND (NOT EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] WHERE [FilterType]=''SCHEMA'') OR EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] [f] WHERE [f].[FilterType]=''SCHEMA'' AND [f].[NameValue]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @SchemaPredicateSch=REPLACE(@SchemaPredicateS,N'[s].[name]',N'[sch].[name]');
    SET @ObjectPredicateO=N' AND (NOT EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] WHERE [FilterType]=''OBJECT'') OR EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] [f] WHERE [f].[FilterType]=''OBJECT'' AND [f].[NameValue]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @FullObjectPredicateSO=N' AND (NOT EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] WHERE [FilterType]=''FULL_OBJECT'') OR EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] [f] WHERE [f].[FilterType]=''FULL_OBJECT'' AND ([f].[DatabaseName] IS NULL OR [f].[DatabaseName]=@pDbName COLLATE SQL_Latin1_General_CP1_CS_AS) AND ([f].[SchemaName] IS NULL OR [f].[SchemaName]=[s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS) AND [f].[ObjectName]=[o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @IndexPredicateI=N' AND (NOT EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] WHERE [FilterType]=''INDEX'') OR EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] [f] WHERE [f].[FilterType]=''INDEX'' AND [f].[NameValue]=[i].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
    SET @StatisticsPredicateSt=N' AND (NOT EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] WHERE [FilterType]=''STATISTICS'') OR EXISTS(SELECT 1 FROM [#MissingIndexes_NameFilters] [f] WHERE [f].[FilterType]=''STATISTICS'' AND [f].[NameValue]=[st].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))';
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
 IF @Hilfe=1
 BEGIN
        PRINT N'monitor.USP_MissingIndexes';        PRINT N'@DatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken; N'''' = keine Einschränkung.';        PRINT N'@SystemdatenbankenEinbeziehen bit = 0: Systemdatenbanken einbeziehen.';        PRINT N'Exakte Listen und ...NamePattern sind gegenseitig exklusiv. Pattern: LIKE (Default/like:), regex: oder regexi:.';
        PRINT N'Datenbankauswahl ohne Vorabbegrenzung; @MaxZeilen int: harte Ergebnismengenbegrenzung.';
        PRINT N'@LockTimeoutMs int = 0: Metadatenzugriff wartet standardmäßig nicht auf Locks.';
        PRINT N'@PrintMeldungen bit = 1: strukturierte Warnungen zusätzlich in der Console.';
        PRINT N'Die Procedure liefert flüchtige Missing-Index-Hinweise und führt keine CREATE-INDEX-Anweisung aus.';
        PRINT N'@MinUserReads bigint = 1: Mindestwert user_seeks + user_scans.';
        PRINT N'@MinAvgUserImpact decimal(9,2) = 0: Mindestwirkung laut DMV.';
        PRINT N'@MinImprovementMeasure decimal(28,2) = 0: avg_total_user_cost * avg_user_impact * reads.';
        PRINT N'DDL-Entwurf muss mit bestehenden Indizes, Write-Kosten, Selectivity und Workload geprüft werden.';
        PRINT N'@Hilfe bit = 0: 1 zeigt diese Hilfe und führt keine Analyse aus.';
        RETURN;
 END;

    DECLARE @ModuleName sysname = N'USP_MissingIndexes';
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();

    DECLARE @OverallStatus varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @TotalRows bigint = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Detail nvarchar(2000) = NULL;

    CREATE TABLE [#MissingIndexes_DatabaseStatus]
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
        INSERT [#MissingIndexes_DatabaseStatus]([DatabaseName], [StatusCode], [IsPartial], [RowCount], [RequiredPermission], [ErrorNumber], [ErrorMessage], [Detail])
        VALUES(@DatabaseName, @OverallStatus, 1, 0, NULL, NULL, @ErrorMessage, N'Keine Datenbankanalyse ausgeführt.');
        SET @IsPartial = 1;
    END
    ELSE
    BEGIN
        SET LOCK_TIMEOUT 0;
    END;

 CREATE TABLE [#MissingIndexes_Result]
 (
   [DatabaseName] sysname NOT NULL, [SchemaName] sysname NULL, [ObjectName] sysname NULL, [ObjectId] int NULL,
   [IndexHandle] int NOT NULL, [IndexGroupHandle] int NOT NULL, [UniqueCompiles] bigint NULL,
   [UserSeeks] bigint NULL, [UserScans] bigint NULL, [TotalUserReads] bigint NULL, [LastUserSeek] datetime NULL, [LastUserScan] datetime NULL,
   [AvgTotalUserCost] float NULL, [AvgUserImpact] float NULL, [ImprovementMeasure] decimal(28,2) NULL,
   [EqualityColumns] nvarchar(4000) NULL, [InequalityColumns] nvarchar(4000) NULL, [IncludedColumns] nvarchar(4000) NULL,
   [StatementName] nvarchar(4000) NULL, [ProposedIndexName] sysname NULL, [ProposedCreateIndex] nvarchar(max) NULL,
   [WarningText] nvarchar(1000) NOT NULL
 );
 IF @OverallStatus='AVAILABLE' AND (@MinUserReads<0 OR @MinAvgUserImpact<0 OR @MinAvgUserImpact>100 OR @MinImprovementMeasure<0)
 BEGIN SET @OverallStatus='INVALID_PARAMETER'; SET @ErrorMessage=N'Ungültiger Mindestfilter.'; INSERT [#MissingIndexes_DatabaseStatus] VALUES(@DatabaseName,@OverallStatus,1,0,NULL,NULL,@ErrorMessage,NULL); END
 ELSE IF @OverallStatus='AVAILABLE'
 BEGIN
  DECLARE @DbId int,@DbName sysname,@Sql nvarchar(max),@Rows bigint;
  DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR SELECT [DatabaseId],[DatabaseName] FROM [#MissingIndexes_DatabaseCandidates];
  OPEN dbcur; FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  WHILE @@FETCH_STATUS=0
  BEGIN
   BEGIN TRY
    SET @Sql = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(11), @LockTimeoutMs) + N'; USE ' + QUOTENAME(@DbName) + N';
INSERT #MissingIndexes_Result
SELECT TOP (@pMaxRows)
 @pDbName,[s].[name],[o].[name],[d].[object_id],[d].[index_handle],[g].[index_group_handle],[gs].[unique_compiles],
 [gs].[user_seeks],[gs].[user_scans],[gs].[user_seeks]+[gs].[user_scans],[gs].[last_user_seek],[gs].[last_user_scan],
 [gs].[avg_total_user_cost],[gs].[avg_user_impact],
 CONVERT(decimal(28,2),[gs].[avg_total_user_cost]*[gs].[avg_user_impact]*([gs].[user_seeks]+[gs].[user_scans])),
 [d].[equality_columns],[d].[inequality_columns],[d].[included_columns],[d].[statement],
 CONVERT(sysname,LEFT(N''IX_Missing_''+CONVERT(nvarchar(20),[d].[object_id])+N''_''+CONVERT(nvarchar(20),[d].[index_handle]),128)),
 N''CREATE INDEX ''+QUOTENAME(LEFT(N''IX_Missing_''+CONVERT(nvarchar(20),[d].[object_id])+N''_''+CONVERT(nvarchar(20),[d].[index_handle]),128))+N'' ON ''+QUOTENAME(@pDbName)+N''.''+QUOTENAME([s].[name])+N''.''+QUOTENAME([o].[name])+N'' (''+
 COALESCE([d].[equality_columns],N'''')+CASE WHEN [d].[equality_columns] IS NOT NULL AND [d].[inequality_columns] IS NOT NULL THEN N'', '' ELSE N'''' END+COALESCE([d].[inequality_columns],N'''')+N'')''+
 CASE WHEN [d].[included_columns] IS NOT NULL THEN N'' INCLUDE (''+[d].[included_columns]+N'')'' ELSE N'''' END+N'';'',
 N''Hinweis aus flüchtigen DMVs; vor Umsetzung auf Überlappung, Schlüsselbreite, Selectivity, Write-Kosten und reale Pläne prüfen.''
FROM sys.dm_db_missing_index_details AS [d] WITH (NOLOCK)
JOIN sys.dm_db_missing_index_groups AS [g] WITH (NOLOCK) ON [g].[index_handle]=[d].[index_handle]
JOIN sys.dm_db_missing_index_group_stats AS [gs] WITH (NOLOCK) ON [gs].[group_handle]=[g].[index_group_handle]
LEFT JOIN sys.objects AS [o] WITH (NOLOCK) ON [o].[object_id]=[d].[object_id]
LEFT JOIN sys.schemas AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [d].[database_id]=@pDbId
'+@SchemaPredicateS+@ObjectPredicateO+@FullObjectPredicateSO+N'
 AND [gs].[user_seeks]+[gs].[user_scans]>=@pMinReads
 AND [gs].[avg_user_impact]>=@pMinImpact
 AND [gs].[avg_total_user_cost]*[gs].[avg_user_impact]*([gs].[user_seeks]+[gs].[user_scans])>=@pMinMeasure
ORDER BY [gs].[avg_total_user_cost]*[gs].[avg_user_impact]*([gs].[user_seeks]+[gs].[user_scans]) DESC
OPTION (MAXDOP 1, RECOMPILE);';
    EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pDbId int,@pMaxRows bigint,@pSchemaLike nvarchar(256),@pObjectLike nvarchar(256),@pMinReads bigint,@pMinImpact decimal(9,2),@pMinMeasure decimal(28,2)',@pDbName=@DbName,@pDbId=@DbId,@pMaxRows=@EffectiveMaxZeilen,@pSchemaLike=@SchemaNameLike,@pObjectLike=@ObjectNameLike,@pMinReads=@MinUserReads,@pMinImpact=@MinAvgUserImpact,@pMinMeasure=@MinImprovementMeasure;
    SELECT @Rows=COUNT_BIG(*) FROM [#MissingIndexes_Result] WHERE [DatabaseName]=@DbName; INSERT [#MissingIndexes_DatabaseStatus] VALUES(@DbName,'AVAILABLE',0,@Rows,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END,NULL,NULL,N'Missing-Index-DMVs erfolgreich gelesen; Inhalte sind flüchtig und nicht vollständig.');
   END TRY
   BEGIN CATCH
    INSERT [#MissingIndexes_DatabaseStatus] VALUES(@DbName,CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,1,0,CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END,ERROR_NUMBER(),ERROR_MESSAGE(),N'Fehler isoliert.');
   END CATCH;
   FETCH NEXT FROM dbcur INTO @DbId,@DbName;
  END; CLOSE dbcur; DEALLOCATE dbcur;
  IF NOT EXISTS(SELECT 1 FROM [#MissingIndexes_DatabaseStatus]) INSERT [#MissingIndexes_DatabaseStatus] VALUES(@DatabaseName,'DATABASE_UNAVAILABLE',1,0,NULL,NULL,N'Keine sichtbare Online-Zieldatenbank gefunden.',NULL);
 END;



    SELECT @TotalRows = COUNT_BIG(*) FROM [#MissingIndexes_Result];

    IF @OverallStatus = 'AVAILABLE'
    BEGIN
        IF EXISTS (SELECT 1 FROM [#MissingIndexes_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
        BEGIN
            SET @OverallStatus = CASE WHEN @TotalRows > 0 THEN 'PARTIAL' ELSE (SELECT TOP (1) [StatusCode] FROM [#MissingIndexes_DatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE') ORDER BY [DatabaseName]) END;
            SET @IsPartial = 1;
        END
        ELSE IF EXISTS (SELECT 1 FROM [#MissingIndexes_DatabaseStatus] WHERE [StatusCode] IN ('AVAILABLE_LIMITED','SKIPPED','NOT_APPLICABLE'))
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
        SELECT [DatabaseName],[StatusCode],[IsPartial],[RowCount],[RequiredPermission],[ErrorNumber],[ErrorMessage],[Detail] FROM [#MissingIndexes_DatabaseStatus] ORDER BY [DatabaseName];
        IF @ResultSetArtNormalisiert='RAW' SELECT * FROM [#MissingIndexes_Result] ORDER BY [ImprovementMeasure] DESC,[DatabaseName],[SchemaName],[ObjectName]; ELSE SELECT N'Missing Index' [Ergebnis],[r].* FROM [#MissingIndexes_Result] [r] ORDER BY [ImprovementMeasure] DESC,[DatabaseName],[SchemaName],[ObjectName];
    END;
    IF @JsonErzeugen=1 BEGIN
        DECLARE @JsonMeta nvarchar(max)=(SELECT @ModuleName [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@OverallStatus [statusCode],@IsPartial [isPartial],@TotalRows [rowCount] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @JsonDatabaseStatus nvarchar(max)=(SELECT * FROM [#MissingIndexes_DatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JsonData1 nvarchar(max)=(SELECT * FROM [#MissingIndexes_Result] ORDER BY [ImprovementMeasure] DESC,[DatabaseName],[SchemaName],[ObjectName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@JsonMeta,N'{}'),N',"missingIndexes":',COALESCE(@JsonData1,N'[]'),N',"databaseStatus":',COALESCE(@JsonDatabaseStatus,N'[]'),N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#MissingIndexes_Result'
            , @ResultLabel=N'MissingIndexes'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#MissingIndexes_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
