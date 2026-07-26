USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_QueryStoreHints
Version      : 2.0.0
Stand        : 2026-07-15
Zweck        : Liefert Query-Store-Hints aus einer oder mehreren
               Quelldatenbanken mit globaler Top-N-Ausgabe. Die Funktion ist
               ab SQL Server 2022 verfügbar.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_QueryStoreHints]
      @QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @QueryId                          bigint         = NULL
    , @NurMitFehler                     bit            = 0
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
 SET NOCOUNT ON;SET @Json=NULL;DECLARE @Out varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,'')))),@Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) WHEN @MaxZeilen>0 THEN @MaxZeilen ELSE 0 END,@Local bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) WHEN @MaxZeilen<2147483647 THEN CONVERT(bigint,@MaxZeilen)+1 ELSE @MaxZeilen END;
    DECLARE @TableResultRequested bit = CASE WHEN @Out = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @Out = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'queryHints',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @Out = 'NONE';
 IF @Hilfe=1 BEGIN PRINT N'monitor.USP_QueryStoreHints';PRINT N'Quell-DB-Liste/Pattern, globales @MaxZeilen, RAW|CONSOLE|TABLE|NONE und JSON.';RETURN;END;
 DECLARE @Now datetime2(3)=SYSUTCDATETIME(),@Status varchar(40)='AVAILABLE',@Partial bit=0,@Error nvarchar(2048)=NULL,@Cross bit=0,@Allowed bit=1,@Db sysname,@Sql nvarchar(max),@Count bigint=0,@HasMore bit=0,@Msg nvarchar(2048);
 CREATE TABLE [#QueryStoreHints_DatabaseCandidates]([DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60),[UserAccessDesc] nvarchar(60),[IsReadOnly] bit,[CompatibilityLevel] tinyint,[CollationName] sysname,[RecoveryModelDesc] nvarchar(60),[IsSystemDatabase] bit,[RequestedOrdinal] int);
 CREATE TABLE [#QueryStoreHints_Result]([QueryStoreDatabaseId] int,[QueryStoreDatabaseName] sysname,[QueryHintId] bigint,[QueryId] bigint,[ReplicaGroupId] bigint,[QueryHash] binary(8),[QueryHintText] nvarchar(max),[LastQueryHintFailureReason] int,[LastQueryHintFailureReasonDesc] nvarchar(128),[QueryHintFailureCount] bigint,[Source] int,[SourceDesc] nvarchar(128),[QuerySqlText] nvarchar(max),[SourceType] varchar(32) NULL,[SourceObject] nvarchar(256) NULL,[CapturedAtUtc] datetime2(3) NULL,[EvidenceScope] varchar(40) NULL,[IsCurrent] bit NULL,[QuerySqlTextCharacters] bigint NULL,[QuerySqlTextBytes] bigint NULL,[QuerySqlTextIsTruncated] bit NOT NULL DEFAULT(0),[EvidenceLimit] nvarchar(1000) NULL);
 CREATE TABLE [#QueryStoreHints_Errors]([DatabaseName] sysname,[StatusCode] varchar(40),[ErrorNumber] int NULL,[ErrorMessage] nvarchar(2048));
 IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<16 BEGIN SET @Status='UNAVAILABLE_VERSION';SET @Error=N'Query Store Hints sind erst ab SQL Server 2022 verfügbar.';END;
 IF @MaxZeilen<0 OR @MaxSqlTextZeichen < 0 OR @Out NOT IN('RAW','CONSOLE','NONE') BEGIN SET @Status='INVALID_PARAMETER';SET @Error=N'Ungültiger Parameter.';END;
 IF @Status='AVAILABLE' EXEC [monitor].[USP_PrepareDatabaseCandidates] @DatabaseNames=@QueryStoreDatabaseNames,@SystemdatenbankenEinbeziehen=0,@DatabaseNamePattern=@QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass='QUERY_STORE_CURRENT',@StatusCode=@Status OUTPUT,@ErrorMessage=@Error OUTPUT,@CrossDatabaseRequested=@Cross OUTPUT,@CandidateTable=N'#QueryStoreHints_DatabaseCandidates';
 IF @Status='AVAILABLE' AND @Limit>1000 EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='QUERY_STORE_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@Status OUTPUT,@ErrorMessage=@Error OUTPUT;
 SET LOCK_TIMEOUT 0;
 IF @Status='AVAILABLE' BEGIN DECLARE [c] CURSOR LOCAL FAST_FORWARD FOR SELECT [DatabaseName] FROM [#QueryStoreHints_DatabaseCandidates] ORDER BY COALESCE([RequestedOrdinal],[DatabaseId]),[DatabaseId];OPEN [c];FETCH NEXT FROM [c] INTO @Db;WHILE @@FETCH_STATUS=0 BEGIN BEGIN TRY SET @Sql=N'USE '+QUOTENAME(@Db)+N';IF EXISTS(SELECT 1 FROM [sys].[all_objects] AS [o] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id] WHERE [s].[name]=N''sys'' AND [o].[name]=N''query_store_query_hints'') INSERT [#QueryStoreHints_Result]([QueryStoreDatabaseId],[QueryStoreDatabaseName],[QueryHintId],[QueryId],[ReplicaGroupId],[QueryHash],[QueryHintText],[LastQueryHintFailureReason],[LastQueryHintFailureReasonDesc],[QueryHintFailureCount],[Source],[SourceDesc],[QuerySqlText]) SELECT TOP(@TopRows) DB_ID(),(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID()),[h].[query_hint_id],[h].[query_id],[h].[replica_group_id],[q].[query_hash],[h].[query_hint_text],[h].[last_query_hint_failure_reason],[h].[last_query_hint_failure_reason_desc],[h].[query_hint_failure_count],[h].[source],[h].[source_desc],[qt].[query_sql_text] FROM [sys].[query_store_query_hints] [h] WITH (NOLOCK) LEFT JOIN [sys].[query_store_query] [q] WITH (NOLOCK) ON [q].[query_id]=[h].[query_id] LEFT JOIN [sys].[query_store_query_text] [qt] WITH (NOLOCK) ON [qt].[query_text_id]=[q].[query_text_id] WHERE (@QueryId IS NULL OR [h].[query_id]=@QueryId) AND (@OnlyErrors=0 OR [h].[query_hint_failure_count]>0 OR [h].[last_query_hint_failure_reason]<>0) ORDER BY CASE WHEN [h].[last_query_hint_failure_reason]<>0 THEN 0 ELSE 1 END,[h].[query_hint_failure_count] DESC,[h].[query_hint_id];';EXEC [sys].[sp_executesql] @Sql,N'@TopRows bigint,@QueryId bigint,@OnlyErrors bit',@Local,@QueryId,@NurMitFehler;END TRY BEGIN CATCH INSERT [#QueryStoreHints_Errors] VALUES(@Db,CASE WHEN ERROR_NUMBER() IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' WHEN ERROR_NUMBER() IN(207,208) THEN 'UNAVAILABLE_OBJECT' ELSE 'ERROR_HANDLED' END,ERROR_NUMBER(),ERROR_MESSAGE());SET @Partial=1;IF @PrintMeldungen=1 BEGIN SET @Msg=FORMATMESSAGE(N'WARNUNG USP_QueryStoreHints [%s]: %s',@Db,ERROR_MESSAGE());RAISERROR(N'%s',10,1,@Msg) WITH NOWAIT;END;END CATCH;FETCH NEXT FROM [c] INTO @Db;END;CLOSE [c];DEALLOCATE [c];END;
 UPDATE [#QueryStoreHints_Result]
 SET [SourceType]='QUERY_STORE',[SourceObject]=N'sys.query_store_query_hints|sys.query_store_query_text',
     [CapturedAtUtc]=@Now,[EvidenceScope]='DATABASE_QUERY_HINT',[IsCurrent]=1,
     [EvidenceLimit]=N'Aktueller gespeicherter Query-Store-Hintstatus; keine Aussage über die Wirksamkeit jeder zukünftigen Ausführung.';
 DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
 EXEC [monitor].[InternalProjectUnicodeTextColumn] @SourceTable=N'#QueryStoreHints_Result',@TextColumn=N'QuerySqlText',@CharactersColumn=N'QuerySqlTextCharacters',@BytesColumn=N'QuerySqlTextBytes',@IsTruncatedColumn=N'QuerySqlTextIsTruncated',@MaxCharacters=@MaxSqlTextZeichen,@TruncatedValueCount=@TruncatedValueCount OUTPUT,@LargestRequiredCharacters=@LargestRequiredCharacters OUTPUT;
 EXEC [monitor].[InternalEmitTruncationWarning] @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen',@ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters,@PrintMeldungen=@PrintMeldungen;
 SELECT @Count=COUNT_BIG(*) FROM [#QueryStoreHints_Result];SET @HasMore=CONVERT(bit,CASE WHEN @Limit<9223372036854775807 AND @Count>@Limit THEN 1 ELSE 0 END);IF @Partial=1 AND @Status='AVAILABLE' SET @Status='AVAILABLE_LIMITED';
 IF @Out<>'NONE' BEGIN SELECT N'USP_QueryStoreHints' [ModuleName],@Now [CollectionTimeUtc],@Status [StatusCode],@Partial [IsPartial],CASE WHEN @Count>@Limit THEN @Limit ELSE @Count END [ReturnedRowCount],@HasMore [HasMoreRows],@Error [ErrorMessage];IF @Out='RAW' SELECT TOP(@Limit) * FROM [#QueryStoreHints_Result] ORDER BY CASE WHEN [LastQueryHintFailureReason]<>0 THEN 0 ELSE 1 END,[QueryHintFailureCount] DESC,[QueryHintId];ELSE SELECT TOP(@Limit) N'Query-Store Hint' [Ergebnis],[QueryStoreDatabaseName] [Query-Store-Datenbank],[QueryId] [Query],[QueryHintText] [Hint],[LastQueryHintFailureReasonDesc] [letzter Fehler],[QueryHintFailureCount] [Fehleranzahl],[QueryStoreDatabaseName] [Quelle],[QuerySqlText] [SQL-Text] FROM [#QueryStoreHints_Result] ORDER BY CASE WHEN [LastQueryHintFailureReason]<>0 THEN 0 ELSE 1 END,[QueryHintFailureCount] DESC,[QueryHintId];SELECT * FROM [#QueryStoreHints_Errors] ORDER BY [DatabaseName];END;
 IF @JsonErzeugen=1 BEGIN DECLARE @Meta nvarchar(max)=(SELECT N'QueryStoreHints' [resultName],1 [schemaVersion],@Now [generatedAtUtc],@Status [statusCode],@MaxZeilen [requestedMaxRows],CASE WHEN @Count>@Limit THEN @Limit ELSE @Count END [returnedRows],@HasMore [hasMoreRows] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),@Data nvarchar(max)=(SELECT TOP(@Limit) * FROM [#QueryStoreHints_Result] ORDER BY CASE WHEN [LastQueryHintFailureReason]<>0 THEN 0 ELSE 1 END,[QueryHintFailureCount] DESC,[QueryHintId] FOR JSON PATH,INCLUDE_NULL_VALUES),@Warnings nvarchar(max)=(SELECT * FROM [#QueryStoreHints_Errors] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);SET @Json=CONCAT(N'{"meta":',COALESCE(@Meta,N'{}'),N',"queryHints":',COALESCE(@Data,N'[]'),N',"warnings":',COALESCE(@Warnings,N'[]'),N'}');END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#QueryStoreHints_Result'
            , @ResultLabel=N'QueryStoreHints'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#QueryStoreHints_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
