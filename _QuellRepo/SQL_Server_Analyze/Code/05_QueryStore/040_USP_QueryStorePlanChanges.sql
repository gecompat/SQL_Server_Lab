USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_QueryStorePlanChanges
Version      : 2.0.0
Stand        : 2026-07-15
Zweck        : Liefert Abfragen mit mehreren Query-Store-Plänen und begrenzt
               die globale Ausgabe über lokale N+1-Kandidaten. Ein optionaler
               Filter beschränkt die Referenzdatenbanken.
Ausgabe      : RAW/CONSOLE/NONE sowie JSON mit meta, queries, plans, warnings.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_QueryStorePlanChanges]
      @QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @QueryId                          bigint         = NULL
    , @QueryHash                        binary(8)      = NULL
    , @VonUtc                           datetime2(7)   = NULL
    , @NurMehrerePlaene                 bit            = 1
    , @MitPlanXml                       bit            = 0
    , @AnalyseModus                     varchar(16)    = 'TOP'
    , @MaxZeilen                        int            = 100
    , @MaxSqlTextZeichen                int            = 4000
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
AS
BEGIN
 SET NOCOUNT ON;SET @Json=NULL;SET @AnalyseModus=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,'TOP'))));
 DECLARE @Out varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,'')))),@Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) WHEN @MaxZeilen>0 THEN @MaxZeilen ELSE 0 END,@Local bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) WHEN @MaxZeilen<2147483647 THEN CONVERT(bigint,@MaxZeilen)+1 ELSE @MaxZeilen END;
    DECLARE @TableResultRequested bit = CASE WHEN @Out = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @Out = 'CONSOLE' THEN 1 ELSE 0 END;
    CREATE TABLE [#QueryStorePlanChanges_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
    );
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1
    BEGIN
      DECLARE @TablePreflightStatus varchar(40),@TablePreflightError nvarchar(2048);
      EXEC [monitor].[InternalPrepareResultTables]
            @ResultTablesJson=@ResultTablesJson,@AllowedResultNames=N'queries|plans'
          , @MappingTable=N'#QueryStorePlanChanges_ResultTableMap'
          , @StatusCode=@TablePreflightStatus OUTPUT,@ErrorMessage=@TablePreflightError OUTPUT
          , @ThrowOnError=1;
    END;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @Out = 'NONE';
 IF @Hilfe=1 BEGIN PRINT N'monitor.USP_QueryStorePlanChanges';PRINT N'Quell-DB-Liste/Pattern, Referenz-DB-Liste/Pattern, globales @MaxZeilen, RAW|CONSOLE|TABLE|NONE und JSON.';RETURN;END;
 DECLARE @Now datetime2(3)=SYSUTCDATETIME(),@Status varchar(40)='AVAILABLE',@Partial bit=0,@Error nvarchar(2048)=NULL,@Cross bit=0,@Allowed bit=1,@Db sysname,@Compat tinyint,@Sql nvarchar(max),@Count bigint=0,@HasMore bit=0,@Msg nvarchar(2048),@RefMode varchar(8),@RefValue nvarchar(4000),@RefFlags varchar(8),@RefValid bit,@RefPredicate nvarchar(max)=N'';
 SELECT @RefMode=[PatternMode],@RefValue=[PatternValue],@RefFlags=[RegexFlags],@RefValid=[IsValid] FROM [monitor].[TVF_ParsePattern](@ReferencedDatabaseNamePattern);
 CREATE TABLE [#QueryStorePlanChanges_DatabaseCandidates]([DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60),[UserAccessDesc] nvarchar(60),[IsReadOnly] bit,[CompatibilityLevel] tinyint,[CollationName] sysname,[RecoveryModelDesc] nvarchar(60),[IsSystemDatabase] bit,[RequestedOrdinal] int);
 CREATE TABLE [#QueryStorePlanChanges_Summary]([QueryStoreDatabaseId] int,[QueryStoreDatabaseName] sysname,[QueryId] bigint,[QueryHash] binary(8),[ObjectId] bigint NULL,[ObjectName] nvarchar(517) NULL,[PlanCount] bigint,[ForcedPlanCount] bigint,[DistinctPlanHashCount] bigint,[FirstCompileTimeUtc] datetimeoffset NULL,[LastCompileTimeUtc] datetimeoffset NULL,[LastExecutionTimeUtc] datetimeoffset NULL,[TotalCompiles] bigint,[QuerySqlText] nvarchar(max),[SourceType] varchar(32) NULL,[SourceObject] nvarchar(256) NULL,[CapturedAtUtc] datetime2(3) NULL,[EvidenceScope] varchar(40) NULL,[QuerySqlTextCharacters] bigint NULL,[QuerySqlTextBytes] bigint NULL,[QuerySqlTextIsTruncated] bit NULL,[EvidenceLimit] nvarchar(1000) NULL);
 CREATE TABLE [#QueryStorePlanChanges_Plans]([QueryStoreDatabaseId] int,[QueryStoreDatabaseName] sysname,[QueryId] bigint,[PlanId] bigint,[QueryPlanHash] binary(8),[EngineVersion] nvarchar(32),[CompatibilityLevel] smallint,[IsParallelPlan] bit,[IsForcedPlan] bit,[PlanForcingTypeDesc] nvarchar(60),[ForceFailureCount] bigint,[LastForceFailureReason] int,[LastForceFailureReasonDesc] nvarchar(128),[CountCompiles] bigint,[InitialCompileStartTimeUtc] datetimeoffset,[LastCompileStartTimeUtc] datetimeoffset,[LastExecutionTimeUtc] datetimeoffset,[AverageCompileDurationMs] decimal(38,3),[LastCompileDurationMs] decimal(38,3),[QueryPlanTextFallback] nvarchar(max) NULL,[PlanSourceType] varchar(32) NULL,[PlanSourceObject] nvarchar(256) NULL,[PlanCapturedAtUtc] datetime2(3) NULL,[QueryPlanStatus] varchar(40) NULL,[QueryPlanCharacters] bigint NULL,[QueryPlanBytes] bigint NULL,[QueryPlan] xml NULL,[EvidenceLimit] nvarchar(1000) NULL);
 CREATE TABLE [#QueryStorePlanChanges_Errors]([DatabaseName] sysname,[StatusCode] varchar(40),[ErrorNumber] int NULL,[ErrorMessage] nvarchar(2048));
 IF @AnalyseModus NOT IN('TOP','VOLL') OR @MaxZeilen<0 OR @MaxSqlTextZeichen < 0 OR @Out NOT IN('RAW','CONSOLE','NONE') OR @RefValid=0 OR (@ReferencedDatabaseNames IS NOT NULL AND @ReferencedDatabaseNamePattern IS NOT NULL) OR (@ReferencedDatabaseNames IS NOT NULL AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@ReferencedDatabaseNames) WHERE [IsValid]=0)) BEGIN SET @Status='INVALID_PARAMETER';SET @Error=N'Ungültiger Parameter.';END;
 IF @Status='AVAILABLE' EXEC [monitor].[USP_PrepareDatabaseCandidates] @DatabaseNames=@QueryStoreDatabaseNames,@SystemdatenbankenEinbeziehen=0,@DatabaseNamePattern=@QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass='QUERY_STORE_CURRENT',@StatusCode=@Status OUTPUT,@ErrorMessage=@Error OUTPUT,@CrossDatabaseRequested=@Cross OUTPUT,@CandidateTable=N'#QueryStorePlanChanges_DatabaseCandidates';
 IF @Status='AVAILABLE' AND (@AnalyseModus='VOLL' OR @MitPlanXml=1 OR @Limit>1000 OR @ReferencedDatabaseNames IS NOT NULL OR @ReferencedDatabaseNamePattern IS NOT NULL) EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='QUERY_STORE_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@Status OUTPUT,@ErrorMessage=@Error OUTPUT;
 IF @ReferencedDatabaseNames IS NOT NULL SET @RefPredicate=N' AND EXISTS(SELECT 1 FROM (SELECT CONVERT(xml,[p].[query_plan]) [PlanXml]) [px] CROSS APPLY [px].[PlanXml].nodes(''declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //Object[@Database]'') [n]([x]) JOIN [monitor].[TVF_ParseSqlNameList](@ReferencedNames) [rf] ON [rf].[IsValid]=1 AND [rf].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS=PARSENAME([n].[x].value(''@Database'',''nvarchar(776)''),1) COLLATE SQL_Latin1_General_CP1_CS_AS)';
 ELSE IF @RefMode='LIKE' SET @RefPredicate=N' AND EXISTS(SELECT 1 FROM (SELECT CONVERT(xml,[p].[query_plan]) [PlanXml]) [px] CROSS APPLY [px].[PlanXml].nodes(''declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //Object[@Database]'') [n]([x]) WHERE PARSENAME([n].[x].value(''@Database'',''nvarchar(776)''),1) COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @RefValue COLLATE SQL_Latin1_General_CP1_CS_AS)';
 ELSE IF @RefMode IN('REGEX','REGEXI') SET @RefPredicate=N' AND EXISTS(SELECT 1 FROM (SELECT CONVERT(xml,[p].[query_plan]) [PlanXml]) [px] CROSS APPLY [px].[PlanXml].nodes(''declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //Object[@Database]'') [n]([x]) WHERE REGEXP_LIKE(PARSENAME([n].[x].value(''@Database'',''nvarchar(776)''),1),@RefValue,@RefFlags))';
 SET LOCK_TIMEOUT 0;
 IF @Status='AVAILABLE'
 BEGIN DECLARE [c] CURSOR LOCAL FAST_FORWARD FOR SELECT [DatabaseName],[CompatibilityLevel] FROM [#QueryStorePlanChanges_DatabaseCandidates] ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];OPEN [c];FETCH NEXT FROM [c] INTO @Db,@Compat;WHILE @@FETCH_STATUS=0
 BEGIN
  IF @RefMode IN('REGEX','REGEXI') AND (TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<17 OR @Compat<170) BEGIN INSERT [#QueryStorePlanChanges_Errors] VALUES(@Db,'UNAVAILABLE_FEATURE',NULL,N'Regex benötigt SQL Server 2025 und Compatibility Level 170.');SET @Partial=1;END
  ELSE BEGIN TRY
   SET @Sql=N'USE '+QUOTENAME(@Db)+N';IF EXISTS(SELECT 1 FROM [sys].[database_query_store_options] WITH (NOLOCK) WHERE [actual_state] IN(1,2,4))
BEGIN
;WITH [Q] AS
(
 SELECT [q].[query_id],[q].[query_hash],[q].[object_id],COUNT_BIG(*) [PlanCount],SUM(CONVERT(bigint,[p].[is_forced_plan])) [ForcedCount],COUNT(DISTINCT CONVERT(varchar(18),[p].[query_plan_hash],1)) [DistinctHashCount],MIN([p].[initial_compile_start_time]) [FirstCompile],MAX([p].[last_compile_start_time]) [LastCompile],MAX([p].[last_execution_time]) [LastExecution],SUM([p].[count_compiles]) [TotalCompiles],[qt].[query_sql_text]
 FROM [sys].[query_store_query] [q] WITH (NOLOCK) JOIN [sys].[query_store_query_text] [qt] WITH (NOLOCK) ON [qt].[query_text_id]=[q].[query_text_id] JOIN [sys].[query_store_plan] [p] WITH (NOLOCK) ON [p].[query_id]=[q].[query_id]
 WHERE (@QueryId IS NULL OR [q].[query_id]=@QueryId) AND (@QueryHash IS NULL OR [q].[query_hash]=@QueryHash) AND (@SinceUtc IS NULL OR [p].[last_compile_start_time]>=@SinceUtc OR [p].[last_execution_time]>=@SinceUtc)'+@RefPredicate+N'
 GROUP BY [q].[query_id],[q].[query_hash],[q].[object_id],[qt].[query_sql_text] HAVING @OnlyMultiple=0 OR COUNT_BIG(*)>1
)
INSERT [#QueryStorePlanChanges_Summary] ([QueryStoreDatabaseId],[QueryStoreDatabaseName],[QueryId],[QueryHash],[ObjectId],[ObjectName],[PlanCount],[ForcedPlanCount],[DistinctPlanHashCount],[FirstCompileTimeUtc],[LastCompileTimeUtc],[LastExecutionTimeUtc],[TotalCompiles],[QuerySqlText]) SELECT TOP(@TopRows) DB_ID(),(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),[query_id],[query_hash],[object_id],CASE WHEN [Q].[object_id]>0 THEN QUOTENAME([os].[name])+N''.''+QUOTENAME([oo].[name]) END,[PlanCount],[ForcedCount],[DistinctHashCount],[FirstCompile],[LastCompile],[LastExecution],[TotalCompiles],[query_sql_text] FROM [Q] LEFT JOIN [sys].[objects] AS [oo] WITH (NOLOCK) ON [oo].[object_id]=[Q].[object_id] LEFT JOIN [sys].[schemas] AS [os] WITH (NOLOCK) ON [os].[schema_id]=[oo].[schema_id] ORDER BY [LastExecution] DESC,[LastCompile] DESC;
INSERT [#QueryStorePlanChanges_Plans] ([QueryStoreDatabaseId],[QueryStoreDatabaseName],[QueryId],[PlanId],[QueryPlanHash],[EngineVersion],[CompatibilityLevel],[IsParallelPlan],[IsForcedPlan],[PlanForcingTypeDesc],[ForceFailureCount],[LastForceFailureReason],[LastForceFailureReasonDesc],[CountCompiles],[InitialCompileStartTimeUtc],[LastCompileStartTimeUtc],[LastExecutionTimeUtc],[AverageCompileDurationMs],[LastCompileDurationMs],[QueryPlanTextFallback]) SELECT DB_ID(),(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),[p].[query_id],[p].[plan_id],[p].[query_plan_hash],[p].[engine_version],[p].[compatibility_level],[p].[is_parallel_plan],[p].[is_forced_plan],[p].[plan_forcing_type_desc],[p].[force_failure_count],[p].[last_force_failure_reason],[p].[last_force_failure_reason_desc],[p].[count_compiles],[p].[initial_compile_start_time],[p].[last_compile_start_time],[p].[last_execution_time],CONVERT(decimal(38,3),[p].[avg_compile_duration]/1000.0),CONVERT(decimal(38,3),[p].[last_compile_duration]/1000.0),CASE WHEN @IncludePlan=1 THEN [p].[query_plan] END FROM [sys].[query_store_plan] [p] WITH (NOLOCK) JOIN [#QueryStorePlanChanges_Summary] [s] ON [s].[QueryStoreDatabaseId]=DB_ID() AND [s].[QueryId]=[p].[query_id];
END;';
   EXEC [sys].[sp_executesql] @Sql,N'@QueryId bigint,@QueryHash binary(8),@SinceUtc datetime2(7),@OnlyMultiple bit,@TopRows bigint,@TextChars int,@IncludePlan bit,@ReferencedNames nvarchar(max),@RefValue nvarchar(4000),@RefFlags varchar(8)',@QueryId,@QueryHash,@VonUtc,@NurMehrerePlaene,@Local,@MaxSqlTextZeichen,@MitPlanXml,@ReferencedDatabaseNames,@RefValue,@RefFlags;
  END TRY BEGIN CATCH INSERT [#QueryStorePlanChanges_Errors] VALUES(@Db,CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,ERROR_NUMBER(),ERROR_MESSAGE());SET @Partial=1;IF @PrintMeldungen=1 BEGIN SET @Msg=FORMATMESSAGE(N'WARNUNG USP_QueryStorePlanChanges [%s]: %s',@Db,ERROR_MESSAGE());RAISERROR(N'%s',10,1,@Msg) WITH NOWAIT;END;END CATCH;
  FETCH NEXT FROM [c] INTO @Db,@Compat;END;CLOSE [c];DEALLOCATE [c];END;
 UPDATE [s] SET [SourceType]='QUERY_STORE',[SourceObject]=N'sys.query_store_query|sys.query_store_plan|sys.query_store_query_text',[CapturedAtUtc]=@Now,[EvidenceScope]='DATABASE_QUERY',[QuerySqlTextCharacters]=[p].[OriginalCharacters],[QuerySqlTextBytes]=[p].[OriginalBytes],[QuerySqlTextIsTruncated]=[p].[IsTruncated],[QuerySqlText]=[p].[ProjectedValue],[EvidenceLimit]=N'Query-Store-Kompilierungs- und Ausführungsmetadaten; keine aktuelle Einzelausführung.' FROM [#QueryStorePlanChanges_Summary] [s] CROSS APPLY [monitor].[TVF_ProjectUnicodeText]([s].[QuerySqlText],@MaxSqlTextZeichen) [p];
 UPDATE [p] SET [PlanSourceType]='QUERY_STORE',[PlanSourceObject]=N'sys.query_store_plan',[PlanCapturedAtUtc]=@Now,[QueryPlanStatus]=CASE WHEN @MitPlanXml=0 THEN 'NOT_REQUESTED' ELSE 'PENDING' END,[EvidenceLimit]=N'Gespeicherter Query-Store-Plan; kein aktueller Laufzeitplan.' FROM [#QueryStorePlanChanges_Plans] [p];
 DECLARE @PlanDb int,@PlanQuery bigint,@PlanIdLocal bigint,@PlanText nvarchar(max),@PlanXml xml,@PlanStatus varchar(40),@PlanErr int,@PlanMsg nvarchar(2048);DECLARE [pc] CURSOR LOCAL FAST_FORWARD FOR SELECT [QueryStoreDatabaseId],[QueryId],[PlanId],[QueryPlanTextFallback] FROM [#QueryStorePlanChanges_Plans] WHERE @MitPlanXml=1;OPEN [pc];FETCH NEXT FROM [pc] INTO @PlanDb,@PlanQuery,@PlanIdLocal,@PlanText;WHILE @@FETCH_STATUS=0 BEGIN EXEC [monitor].[InternalParseXmlText] @XmlText=@PlanText,@XmlValue=@PlanXml OUTPUT,@StatusCode=@PlanStatus OUTPUT,@ErrorNumber=@PlanErr OUTPUT,@ErrorMessage=@PlanMsg OUTPUT;UPDATE [#QueryStorePlanChanges_Plans] SET [QueryPlanStatus]=@PlanStatus,[QueryPlanCharacters]=CASE WHEN @PlanText IS NULL THEN NULL ELSE CONVERT(bigint,LEN((@PlanText+NCHAR(1)) COLLATE Latin1_General_100_CI_AS_SC)-1) END,[QueryPlanBytes]=CONVERT(bigint,DATALENGTH(@PlanText)),[QueryPlan]=@PlanXml,[QueryPlanTextFallback]=CASE WHEN @PlanStatus IN('AVAILABLE','XML_EMPTY','SOURCE_NULL') THEN NULL ELSE @PlanText END WHERE [QueryStoreDatabaseId]=@PlanDb AND [QueryId]=@PlanQuery AND [PlanId]=@PlanIdLocal;IF @PlanStatus IN('XML_INVALID','XML_UNAVAILABLE_LIMIT') BEGIN INSERT [#QueryStorePlanChanges_Errors] VALUES((SELECT TOP(1) [QueryStoreDatabaseName] FROM [#QueryStorePlanChanges_Plans] WHERE [QueryStoreDatabaseId]=@PlanDb),@PlanStatus,@PlanErr,@PlanMsg);SET @Partial=1;END;FETCH NEXT FROM [pc] INTO @PlanDb,@PlanQuery,@PlanIdLocal,@PlanText;END;CLOSE [pc];DEALLOCATE [pc];
 DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;SELECT @TruncatedValueCount=COUNT_BIG(*),@LargestRequiredCharacters=MAX([QuerySqlTextCharacters]) FROM [#QueryStorePlanChanges_Summary] WHERE [QuerySqlTextIsTruncated]=1;EXEC [monitor].[InternalEmitTruncationWarning] @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen',@ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters,@PrintMeldungen=@PrintMeldungen;
 SELECT @Count=COUNT_BIG(*) FROM [#QueryStorePlanChanges_Summary];SET @HasMore=CONVERT(bit,CASE WHEN @Limit<9223372036854775807 AND @Count>@Limit THEN 1 ELSE 0 END);IF @Partial=1 AND @Status='AVAILABLE' SET @Status='AVAILABLE_LIMITED';
 DELETE [p] FROM [#QueryStorePlanChanges_Plans] [p] WHERE NOT EXISTS(SELECT 1 FROM (SELECT TOP(@Limit) [QueryStoreDatabaseId],[QueryId] FROM [#QueryStorePlanChanges_Summary] ORDER BY [LastExecutionTimeUtc] DESC,[LastCompileTimeUtc] DESC) [k] WHERE [k].[QueryStoreDatabaseId]=[p].[QueryStoreDatabaseId] AND [k].[QueryId]=[p].[QueryId]);
 IF @Out<>'NONE' BEGIN SELECT N'USP_QueryStorePlanChanges' [ModuleName],@Now [CollectionTimeUtc],@Status [StatusCode],@Partial [IsPartial],CASE WHEN @Count>@Limit THEN @Limit ELSE @Count END [ReturnedRowCount],@HasMore [HasMoreRows],@Error [ErrorMessage];IF @Out='RAW' BEGIN SELECT TOP(@Limit) * FROM [#QueryStorePlanChanges_Summary] ORDER BY [LastExecutionTimeUtc] DESC,[LastCompileTimeUtc] DESC;SELECT * FROM [#QueryStorePlanChanges_Plans] ORDER BY [QueryStoreDatabaseName],[QueryId],[LastExecutionTimeUtc] DESC,[PlanId];END ELSE BEGIN SELECT TOP(@Limit) N'Query-Store Planwechsel' [Ergebnis],[QueryStoreDatabaseName] [Query-Store-Datenbank],[QueryId] [Query],[PlanCount] [Pläne],[DistinctPlanHashCount] [verschiedene Plan-Hashes],[ForcedPlanCount] [erzwungene Pläne],[LastExecutionTimeUtc] [letzte Ausführung],[QueryStoreDatabaseName] [Quelle],[QuerySqlText] [SQL-Text] FROM [#QueryStorePlanChanges_Summary] ORDER BY [LastExecutionTimeUtc] DESC,[LastCompileTimeUtc] DESC;SELECT N'Query-Store Plan' [Ergebnis],[QueryStoreDatabaseName] [Query-Store-Datenbank],[QueryId] [Query],[PlanId] [Plan],[IsForcedPlan] [erzwungen],[LastExecutionTimeUtc] [letzte Ausführung],[AverageCompileDurationMs] [Compile Ø ms],[QueryPlan] [Plan-XML] FROM [#QueryStorePlanChanges_Plans] ORDER BY [QueryStoreDatabaseName],[QueryId],[LastExecutionTimeUtc] DESC,[PlanId];END;SELECT * FROM [#QueryStorePlanChanges_Errors] ORDER BY [DatabaseName];END;
 IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'QueryStorePlanChanges' [resultName],2 [schemaVersion],@Now [generatedAtUtc],@Status [statusCode],@MaxZeilen [requestedMaxRows],CASE WHEN @Count>@Limit THEN @Limit ELSE @Count END [returnedRows],@HasMore [hasMoreRows] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@Queries nvarchar(max)=(SELECT TOP(@Limit) * FROM [#QueryStorePlanChanges_Summary] ORDER BY [LastExecutionTimeUtc] DESC,[LastCompileTimeUtc] DESC FOR JSON PATH,INCLUDE_NULL_VALUES),@Plans nvarchar(max)=(SELECT [QueryStoreDatabaseId],[QueryStoreDatabaseName],[QueryId],[PlanId],[QueryPlanHash],[EngineVersion],[CompatibilityLevel],[IsParallelPlan],[IsForcedPlan],[PlanForcingTypeDesc],[ForceFailureCount],[LastForceFailureReason],[LastForceFailureReasonDesc],[CountCompiles],[InitialCompileStartTimeUtc],[LastCompileStartTimeUtc],[LastExecutionTimeUtc],[AverageCompileDurationMs],[LastCompileDurationMs],[QueryPlanTextFallback],[PlanSourceType],[PlanSourceObject],[PlanCapturedAtUtc],[QueryPlanStatus],[QueryPlanCharacters],[QueryPlanBytes],CONVERT(nvarchar(max),[QueryPlan]) [QueryPlan],[EvidenceLimit] FROM [#QueryStorePlanChanges_Plans] ORDER BY [QueryStoreDatabaseName],[QueryId],[LastExecutionTimeUtc] DESC,[PlanId] FOR JSON PATH,INCLUDE_NULL_VALUES),@Warnings nvarchar(max)=(SELECT * FROM [#QueryStorePlanChanges_Errors] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"queries":',COALESCE(@Queries,N'[]'),N',"plans":',COALESCE(@Plans,N'[]'),N',"warnings":',COALESCE(@Warnings,N'[]'),N'}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#QueryStorePlanChanges_Summary'
            , @ResultLabel=N'QueryStorePlanChanges'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        DECLARE @TableResultName sysname,@TableTarget sysname,@TableSource sysname;
        DECLARE [TableResultCursor] CURSOR LOCAL FAST_FORWARD FOR
          SELECT [ResultName],[TargetTable] FROM [#QueryStorePlanChanges_ResultTableMap] ORDER BY [ResultName];
        OPEN [TableResultCursor];FETCH NEXT FROM [TableResultCursor] INTO @TableResultName,@TableTarget;
        WHILE @@FETCH_STATUS=0
        BEGIN
          SET @TableSource=CASE @TableResultName WHEN N'queries' THEN N'#QueryStorePlanChanges_Summary' WHEN N'plans' THEN N'#QueryStorePlanChanges_Plans' END;
          EXEC [monitor].[InternalWriteResultTable] @SourceTable=@TableSource,@TargetTable=@TableTarget,@ThrowOnError=1;
          FETCH NEXT FROM [TableResultCursor] INTO @TableResultName,@TableTarget;
        END;
        CLOSE [TableResultCursor];DEALLOCATE [TableResultCursor];
    END;
END;
GO
