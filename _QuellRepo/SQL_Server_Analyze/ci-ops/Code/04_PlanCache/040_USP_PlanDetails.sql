USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_PlanDetails
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Liefert gezielt SQL-Text, Planattribute, kompilierten Showplan,
               Text-Showplan, letzten bekannten Actual Plan oder Live-Plan.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.dm_exec_requests, sys.dm_exec_query_stats,
               sys.dm_exec_sql_text, sys.dm_exec_plan_attributes,
               sys.dm_exec_query_plan, sys.dm_exec_text_query_plan,
               sys.dm_exec_query_plan_stats, sys.dm_exec_query_statistics_xml.
Parameter    : @SessionIds, @PlanHandle, @SqlHandle, @QueryHash,
               @MitPlanAttributes, @MitCompilePlan, @MitTextPlan,
               @MitLastActualPlan, @MitLivePlan, @MaxAnalyseobjekte,
               @MaxSqlTextZeichen, @PrintMeldungen, @Hilfe.
Resultsets   : 1. Modulstatus. 2. Kandidaten und SQL-Text. 3. Planattribute.
               4. angeforderte Pläne mit SourceType und Status.
Berechtigung : VIEW SERVER STATE bzw. SQL Server 2022+ VIEW SERVER PERFORMANCE STATE.
Eigenlast    : Zielgerichtet und auf @MaxAnalyseobjekte begrenzt. Mehr als 20 Pläne
               prüft PLAN_CACHE_DEEP. Das Framework aktiviert keine Profilingoption.
Locking      : Keine Benutzerobjekte.
Partial      : Jede Planquelle wird je Kandidat isoliert; fehlende oder evictete
               Pläne lassen andere Quellen und Kandidaten bestehen.
Beispiele    : EXEC monitor.USP_PlanDetails @SessionIds=N57,@MitLivePlan=1;
               EXEC monitor.USP_PlanDetails @PlanHandle=0x...;
               EXEC monitor.USP_PlanDetails @QueryHash=0x...,@MitLastActualPlan=1;
               EXEC monitor.USP_PlanDetails @Hilfe=1;
Änderungen   : 1.1.0 - Deep-Gate ab mehr als 20 Plänen.
               1.0.0 - Erstfassung Phase 3.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_PlanDetails]
      @SessionIds            nvarchar(max)  = NULL
    , @PlanHandle            varbinary(64)  = NULL
    , @SqlHandle             varbinary(64)  = NULL
    , @QueryHash             binary(8)      = NULL
    , @MitPlanAttributes     bit            = 1
    , @MitCompilePlan        bit            = 1
    , @MitTextPlan           bit            = 0
    , @MitLastActualPlan     bit            = 0
    , @MitLivePlan           bit            = 0
    , @MaxAnalyseobjekte      int            = 20
    , @HighImpactConfirmed   bit            = 0
    , @MaxSqlTextZeichen     int            = 8000
    , @ResultSetArt          varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen          bit            = 0
    , @Json                   nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen        bit            = 1
    , @Hilfe                 bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    CREATE TABLE [#PlanDetails_ResultTableMap]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
    );
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1
    BEGIN
        DECLARE @TablePreflightStatus varchar(40),@TablePreflightError nvarchar(2048);
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'candidates|attributes|plans'
            , @MappingTable=N'#PlanDetails_ResultTableMap'
            , @StatusCode=@TablePreflightStatus OUTPUT
            , @ErrorMessage=@TablePreflightError OUTPUT
            , @ThrowOnError=1;
    END;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @SingleSessionId smallint=NULL;
    DECLARE @EffectiveMaxAnalyseobjekte bigint = CASE WHEN @MaxAnalyseobjekte IS NULL OR @MaxAnalyseobjekte=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxAnalyseobjekte) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);
    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_PlanDetails';
        PRINT N'Mindestens einer der Selektoren @SessionIds, @PlanHandle, @SqlHandle oder @QueryHash ist erforderlich.';
        PRINT N'@MitPlanAttributes bit=1; @MitCompilePlan bit=1; @MitTextPlan bit=0; @MitLastActualPlan bit=0; @MitLivePlan bit=0.';
        PRINT N'@MaxAnalyseobjekte int=20: positive Werte begrenzen; NULL/0 = unbegrenzt. Mehr als 20 oder unbegrenzt prüft PLAN_CACHE_DEEP.';
        PRINT N'@MaxSqlTextZeichen int=8000: positiv = gekürzt; NULL/0 = vollständiger Statement- und Batchtext; @PrintMeldungen bit=1; @Hilfe bit=0.';
        PRINT N'LAST_QUERY_PLAN_STATS und Live-Profiling werden nur gelesen, niemals aktiviert. NULL kann bedeuten: deaktiviert, Plan evictet, nicht cachebar oder nicht verfügbar.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),@StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0,@RowCount bigint=0,
            @ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL,@Detail nvarchar(2000)=NULL,@Allowed bit=1,
            @RequiredPermission nvarchar(256)=CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END;

    CREATE TABLE [#PlanDetails_SessionIdFilter]([SessionId] smallint NOT NULL PRIMARY KEY);
    IF @SessionIds IS NOT NULL
    BEGIN
        IF EXISTS(SELECT 1 FROM [monitor].[TVF_ParseBigintList](@SessionIds) WHERE [IsValid]=0 OR [NumberValue] NOT BETWEEN 1 AND 32767)
        BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'@SessionIds enthält einen ungültigen Wert.';END
        ELSE INSERT [#PlanDetails_SessionIdFilter] SELECT CONVERT(smallint,[NumberValue]) FROM [monitor].[TVF_ParseBigintList](@SessionIds) GROUP BY [NumberValue];
        IF (SELECT COUNT_BIG(*) FROM [#PlanDetails_SessionIdFilter])=1 SELECT @SingleSessionId=MIN([SessionId]) FROM [#PlanDetails_SessionIdFilter];
    END;

    CREATE TABLE [#PlanDetails_Candidate]
    (
        [CandidateId] int IDENTITY(1,1) PRIMARY KEY,[SessionId] smallint NULL,[RequestId] int NULL,[PlanHandle] varbinary(64) NULL,
        [SqlHandle] varbinary(64) NULL,[QueryHash] binary(8) NULL,[QueryPlanHash] binary(8) NULL,[StatementStartOffset] int NULL,
        [StatementEndOffset] int NULL,[CreationTime] datetime NULL,[LastExecutionTime] datetime NULL,[ExecutionCount] bigint NULL
    );
    CREATE TABLE [#PlanDetails_Attributes]([CandidateId] int,[AttributeName] varchar(128),[AttributeValue] nvarchar(4000),[IsCacheKey] bit);
    CREATE TABLE [#PlanDetails_Plans]([CandidateId] int,[SourceType] varchar(24),[StatusCode] varchar(40),[DatabaseId] int NULL,[ObjectId] int NULL,[IsEncrypted] bit NULL,[QueryPlanXml] xml NULL,[QueryPlanText] nvarchar(max) NULL,[ErrorNumber] int NULL,[ErrorMessage] nvarchar(2048) NULL);

    SET LOCK_TIMEOUT 0;

    IF @SessionIds IS NULL AND @PlanHandle IS NULL AND @SqlHandle IS NULL AND @QueryHash IS NULL
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'Mindestens ein Selektor ist erforderlich.';END;
    IF @MaxAnalyseobjekte<0 OR @MaxSqlTextZeichen < 0 OR @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE')
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'@MaxAnalyseobjekte oder @MaxSqlTextZeichen darf nicht negativ sein.';END;
    IF @StatusCode='AVAILABLE' AND @EffectiveMaxAnalyseobjekte>20
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='PLAN_CACHE_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@StatusCode OUTPUT,@ErrorMessage=@ErrorMessage OUTPUT;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        IF @SessionIds IS NOT NULL
        BEGIN
            INSERT [#PlanDetails_Candidate]([SessionId],[RequestId],[PlanHandle],[SqlHandle],[QueryHash],[QueryPlanHash],[StatementStartOffset],[StatementEndOffset],[CreationTime],[LastExecutionTime],[ExecutionCount])
            SELECT TOP (@EffectiveMaxAnalyseobjekte) [r].[session_id],[r].[request_id],[r].[plan_handle],[r].[sql_handle],[r].[query_hash],[r].[query_plan_hash],[r].[statement_start_offset],[r].[statement_end_offset],NULL,[r].[start_time],NULL
            FROM [sys].[dm_exec_requests] AS [r] WITH (NOLOCK) JOIN [#PlanDetails_SessionIdFilter] AS [sf] ON [sf].[SessionId]=[r].[session_id] ORDER BY [r].[session_id],[r].[request_id];
        END;
        IF @PlanHandle IS NOT NULL AND NOT EXISTS(SELECT 1 FROM [#PlanDetails_Candidate] WHERE [PlanHandle]=@PlanHandle)
            INSERT [#PlanDetails_Candidate]([PlanHandle]) VALUES(@PlanHandle);
        IF @SqlHandle IS NOT NULL
            INSERT [#PlanDetails_Candidate]([PlanHandle],[SqlHandle],[QueryHash],[QueryPlanHash],[StatementStartOffset],[StatementEndOffset],[CreationTime],[LastExecutionTime],[ExecutionCount])
            SELECT TOP (@EffectiveMaxAnalyseobjekte) [qs].[plan_handle],[qs].[sql_handle],[qs].[query_hash],[qs].[query_plan_hash],[qs].[statement_start_offset],[qs].[statement_end_offset],[qs].[creation_time],[qs].[last_execution_time],[qs].[execution_count]
            FROM [sys].[dm_exec_query_stats] AS qs WITH (NOLOCK) WHERE [qs].[sql_handle]=@SqlHandle AND NOT EXISTS(SELECT 1 FROM [#PlanDetails_Candidate] c WHERE [c].[PlanHandle]=[qs].[plan_handle] AND COALESCE([c].[StatementStartOffset],-1)=COALESCE([qs].[statement_start_offset],-1))
            ORDER BY [qs].[total_worker_time] DESC;
        IF @QueryHash IS NOT NULL
            INSERT [#PlanDetails_Candidate]([PlanHandle],[SqlHandle],[QueryHash],[QueryPlanHash],[StatementStartOffset],[StatementEndOffset],[CreationTime],[LastExecutionTime],[ExecutionCount])
            SELECT TOP (@EffectiveMaxAnalyseobjekte) [qs].[plan_handle],[qs].[sql_handle],[qs].[query_hash],[qs].[query_plan_hash],[qs].[statement_start_offset],[qs].[statement_end_offset],[qs].[creation_time],[qs].[last_execution_time],[qs].[execution_count]
            FROM [sys].[dm_exec_query_stats] AS qs WITH (NOLOCK) WHERE [qs].[query_hash]=@QueryHash AND NOT EXISTS(SELECT 1 FROM [#PlanDetails_Candidate] c WHERE [c].[PlanHandle]=[qs].[plan_handle] AND COALESCE([c].[StatementStartOffset],-1)=COALESCE([qs].[statement_start_offset],-1))
            ORDER BY [qs].[total_worker_time] DESC;
        DELETE [c] FROM [#PlanDetails_Candidate] AS c WHERE [c].[CandidateId] NOT IN(SELECT TOP (@EffectiveMaxAnalyseobjekte) [CandidateId] FROM [#PlanDetails_Candidate] ORDER BY [CandidateId]);
        SELECT @RowCount=COUNT_BIG(*) FROM [#PlanDetails_Candidate];SET @Detail=CASE WHEN @RowCount=0 THEN N'Kein passender Planhandle sichtbar.' ELSE N'Kandidaten erfolgreich ermittelt.' END;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();SET @IsPartial=1;
        SET @StatusCode=CASE WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END;
    END CATCH;

    IF @StatusCode='AVAILABLE' AND @MitPlanAttributes=1
    BEGIN TRY
        INSERT [#PlanDetails_Attributes]
        SELECT [c].[CandidateId],[pa].[attribute],CONVERT(nvarchar(4000),[pa].[value]),[pa].[is_cache_key]
        FROM [#PlanDetails_Candidate] AS c CROSS APPLY sys.dm_exec_plan_attributes([c].[PlanHandle]) AS pa;
    END TRY BEGIN CATCH SET @IsPartial=1;SET @StatusCode='PARTIAL';IF @ErrorMessage IS NULL BEGIN SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();END;END CATCH;

    IF @StatusCode IN('AVAILABLE','PARTIAL') AND @MitCompilePlan=1
    BEGIN TRY
        INSERT [#PlanDetails_Plans]
        SELECT [c].[CandidateId],'COMPILE_XML',CASE WHEN [qp].[query_plan] IS NULL THEN 'UNAVAILABLE_OBJECT' ELSE 'AVAILABLE' END,[qp].[dbid],[qp].[objectid],[qp].[encrypted],[qp].[query_plan],NULL,NULL,CASE WHEN [qp].[query_plan] IS NULL THEN N'Plan nicht mehr im Cache oder XML-Tiefenlimit erreicht.' END
        FROM [#PlanDetails_Candidate] AS c OUTER APPLY sys.dm_exec_query_plan([c].[PlanHandle]) AS qp;
    END TRY BEGIN CATCH INSERT [#PlanDetails_Plans] SELECT [CandidateId],'COMPILE_XML','ERROR_HANDLED',NULL,NULL,NULL,NULL,NULL,ERROR_NUMBER(),ERROR_MESSAGE() FROM [#PlanDetails_Candidate];SET @IsPartial=1;SET @StatusCode='PARTIAL';END CATCH;

    IF @StatusCode IN('AVAILABLE','PARTIAL') AND @MitTextPlan=1
    BEGIN TRY
        INSERT [#PlanDetails_Plans]
        SELECT [c].[CandidateId],'COMPILE_TEXT',CASE WHEN [tp].[query_plan] IS NULL THEN 'UNAVAILABLE_OBJECT' ELSE 'AVAILABLE' END,[tp].[dbid],[tp].[objectid],[tp].[encrypted],NULL,[tp].[query_plan],NULL,CASE WHEN [tp].[query_plan] IS NULL THEN N'Textplan nicht verfügbar.' END
        FROM [#PlanDetails_Candidate] AS c OUTER APPLY sys.dm_exec_text_query_plan([c].[PlanHandle],COALESCE([c].[StatementStartOffset],0),COALESCE([c].[StatementEndOffset],-1)) AS tp;
    END TRY BEGIN CATCH INSERT [#PlanDetails_Plans] SELECT [CandidateId],'COMPILE_TEXT','ERROR_HANDLED',NULL,NULL,NULL,NULL,NULL,ERROR_NUMBER(),ERROR_MESSAGE() FROM [#PlanDetails_Candidate];SET @IsPartial=1;SET @StatusCode='PARTIAL';END CATCH;

    IF @StatusCode IN('AVAILABLE','PARTIAL') AND @MitLastActualPlan=1
    BEGIN TRY
        INSERT [#PlanDetails_Plans]
        SELECT [c].[CandidateId],'LAST_ACTUAL_XML',CASE WHEN [qp].[query_plan] IS NULL THEN 'AVAILABLE_DISABLED' ELSE 'AVAILABLE' END,[qp].[dbid],[qp].[objectid],[qp].[encrypted],[qp].[query_plan],NULL,NULL,
               CASE WHEN [qp].[query_plan] IS NULL THEN N'LAST_QUERY_PLAN_STATS nicht aktiviert, Plan nicht geeignet, nicht cachebar oder bereits evictet.' END
        FROM [#PlanDetails_Candidate] AS c OUTER APPLY sys.dm_exec_query_plan_stats([c].[PlanHandle]) AS qp;
    END TRY BEGIN CATCH INSERT [#PlanDetails_Plans] SELECT [CandidateId],'LAST_ACTUAL_XML','ERROR_HANDLED',NULL,NULL,NULL,NULL,NULL,ERROR_NUMBER(),ERROR_MESSAGE() FROM [#PlanDetails_Candidate];SET @IsPartial=1;SET @StatusCode='PARTIAL';END CATCH;

    IF @StatusCode IN('AVAILABLE','PARTIAL') AND @MitLivePlan=1
    BEGIN TRY
        IF @SingleSessionId IS NULL
            INSERT [#PlanDetails_Plans] VALUES(NULL,'LIVE_XML','INVALID_PARAMETER',NULL,NULL,NULL,NULL,NULL,NULL,N'@MitLivePlan erfordert genau eine Session in @SessionIds.');
        ELSE
            INSERT [#PlanDetails_Plans]
            SELECT [c].[CandidateId],'LIVE_XML',CASE WHEN [qx].[query_plan] IS NULL THEN 'UNAVAILABLE_OBJECT' ELSE 'AVAILABLE' END,NULL,NULL,NULL,[qx].[query_plan],NULL,NULL,
                   CASE WHEN [qx].[query_plan] IS NULL THEN N'Request nicht mehr aktiv oder Live-Plan nicht verfügbar.' END
            FROM [sys].[dm_exec_query_statistics_xml](@SingleSessionId) AS [qx]
            LEFT JOIN [#PlanDetails_Candidate] AS c ON [c].[SessionId]=[qx].[session_id] AND ([c].[RequestId]=[qx].[request_id] OR [c].[RequestId] IS NULL);
    END TRY BEGIN CATCH INSERT [#PlanDetails_Plans] VALUES(NULL,'LIVE_XML','ERROR_HANDLED',NULL,NULL,NULL,NULL,NULL,ERROR_NUMBER(),ERROR_MESSAGE());SET @IsPartial=1;SET @StatusCode='PARTIAL';END CATCH;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN('AVAILABLE') BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_PlanDetails: %s - %s', @StatusCode, COALESCE(@ErrorMessage,N''));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
    CREATE TABLE [#PlanDetails_CandidatesOutput]
    (
          [CandidateId] int,[SessionId] smallint NULL,[RequestId] int NULL,[PlanHandle] varbinary(64) NULL,[SqlHandle] varbinary(64) NULL
        , [QueryHash] binary(8) NULL,[QueryPlanHash] binary(8) NULL,[StatementStartOffset] int NULL,[StatementEndOffset] int NULL
        , [CreationTime] datetime NULL,[LastExecutionTime] datetime NULL,[ExecutionCount] bigint NULL
        , [StatementTextCharacters] bigint NULL,[StatementTextBytes] bigint NULL,[StatementTextIsTruncated] bit NOT NULL DEFAULT(0),[StatementText] nvarchar(max) NULL
        , [BatchTextCharacters] bigint NULL,[BatchTextBytes] bigint NULL,[BatchTextIsTruncated] bit NOT NULL DEFAULT(0),[BatchText] nvarchar(max) NULL
        , [SqlTextDatabaseId] int NULL,[SqlTextDatabaseName] sysname NULL,[SqlTextObjectId] int NULL
    );
    INSERT [#PlanDetails_CandidatesOutput]
    SELECT [c].[CandidateId],[c].[SessionId],[c].[RequestId],[c].[PlanHandle],[c].[SqlHandle],[c].[QueryHash],[c].[QueryPlanHash],[c].[StatementStartOffset],[c].[StatementEndOffset],[c].[CreationTime],[c].[LastExecutionTime],[c].[ExecutionCount],
           NULL,NULL,CONVERT(bit,0),[statementText].[StatementText],
           NULL,NULL,CONVERT(bit,0),[st].[text],[st].[dbid],(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = [st].[dbid]),[st].[objectid]
    FROM [#PlanDetails_Candidate] AS [c]
    OUTER APPLY [sys].[dm_exec_sql_text](COALESCE([c].[SqlHandle],[c].[PlanHandle])) AS [st]
    OUTER APPLY [monitor].[TVF_StatementText]
    (
          [st].[text]
        , [c].[StatementStartOffset]
        , [c].[StatementEndOffset]
    ) AS [statementText];

    DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
    DECLARE @ColumnTruncatedCount bigint=0,@ColumnLargestCharacters bigint=NULL;
    EXEC [monitor].[InternalProjectUnicodeTextColumn]
          @SourceTable=N'#PlanDetails_CandidatesOutput',@TextColumn=N'StatementText'
        , @CharactersColumn=N'StatementTextCharacters',@BytesColumn=N'StatementTextBytes'
        , @IsTruncatedColumn=N'StatementTextIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
        , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
    SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
           @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
    EXEC [monitor].[InternalProjectUnicodeTextColumn]
          @SourceTable=N'#PlanDetails_CandidatesOutput',@TextColumn=N'BatchText'
        , @CharactersColumn=N'BatchTextCharacters',@BytesColumn=N'BatchTextBytes'
        , @IsTruncatedColumn=N'BatchTextIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
        , @TruncatedValueCount=@ColumnTruncatedCount OUTPUT,@LargestRequiredCharacters=@ColumnLargestCharacters OUTPUT;
    SELECT @TruncatedValueCount=@TruncatedValueCount+@ColumnTruncatedCount,
           @LargestRequiredCharacters=CASE WHEN @LargestRequiredCharacters IS NULL OR @ColumnLargestCharacters>@LargestRequiredCharacters THEN @ColumnLargestCharacters ELSE @LargestRequiredCharacters END;
    EXEC [monitor].[InternalEmitTruncationWarning]
          @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen'
        , @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters
        , @PrintMeldungen=@PrintMeldungen;
    IF @ResultSetArtNormalisiert<>'NONE'
    BEGIN
        SELECT N'USP_PlanDetails' [ModuleName],@CollectionTimeUtc [CollectionTimeUtc],@StatusCode [StatusCode],@IsPartial [IsPartial],@RowCount [RowCount],@RequiredPermission [RequiredPermission],@ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage],@Detail [Detail];
        IF @ResultSetArtNormalisiert='RAW'
        BEGIN
            SELECT * FROM [#PlanDetails_CandidatesOutput] ORDER BY [CandidateId];
            IF @MitPlanAttributes=1 SELECT * FROM [#PlanDetails_Attributes] ORDER BY [CandidateId],[AttributeName];
            IF @MitCompilePlan=1 OR @MitTextPlan=1 OR @MitLastActualPlan=1 OR @MitLivePlan=1 SELECT * FROM [#PlanDetails_Plans] ORDER BY [CandidateId],[SourceType];
        END
        ELSE
        BEGIN
            SELECT N'Plan-Kandidat' AS [Ergebnis],[CandidateId] AS [Kandidat],[SessionId] AS [Session],[RequestId] AS [Request],[SqlTextDatabaseName] AS [Datenbank],[QueryHash] AS [Query Hash],[QueryPlanHash] AS [Plan Hash],[ExecutionCount] AS [Ausführungen],[LastExecutionTime] AS [letzte Ausführung],[SessionId] AS [Session SQL],[StatementText] AS [Statement],[BatchText] AS [Batch] FROM [#PlanDetails_CandidatesOutput] ORDER BY [CandidateId];
            IF @MitPlanAttributes=1 SELECT N'Planattribut' AS [Ergebnis],[CandidateId] AS [Kandidat],[AttributeName] AS [Attribut],[AttributeValue] AS [Wert],[IsCacheKey] AS [Cache-Key] FROM [#PlanDetails_Attributes] ORDER BY [CandidateId],[AttributeName];
            IF @MitCompilePlan=1 OR @MitTextPlan=1 OR @MitLastActualPlan=1 OR @MitLivePlan=1 SELECT N'Planinhalt' AS [Ergebnis],[CandidateId] AS [Kandidat],[SourceType] AS [Quelle],[StatusCode] AS [Status],[DatabaseId] AS [Datenbank-ID],[ObjectId] AS [Objekt-ID],[ErrorMessage] AS [Hinweis],[QueryPlanXml] AS [Plan XML],[QueryPlanText] AS [Plan Text] FROM [#PlanDetails_Plans] ORDER BY [CandidateId],[SourceType];
        END;
    END;
    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'PlanDetails' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@RowCount [candidateCount],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @CandidatesJson nvarchar(max)=(SELECT * FROM [#PlanDetails_CandidatesOutput] ORDER BY [CandidateId] FOR JSON PATH,INCLUDE_NULL_VALUES),@AttributesJson nvarchar(max)=(SELECT * FROM [#PlanDetails_Attributes] ORDER BY [CandidateId],[AttributeName] FOR JSON PATH,INCLUDE_NULL_VALUES),@PlansJson nvarchar(max)=(SELECT [CandidateId],[SourceType],[StatusCode],[DatabaseId],[ObjectId],[IsEncrypted],CONVERT(nvarchar(max),[QueryPlanXml]) [QueryPlanXml],[QueryPlanText],[ErrorNumber],[ErrorMessage] FROM [#PlanDetails_Plans] ORDER BY [CandidateId],[SourceType] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"candidates":',COALESCE(@CandidatesJson,N'[]'),N',"attributes":',COALESCE(@AttributesJson,N'[]'),N',"plans":',COALESCE(@PlansJson,N'[]'),N',"warnings":[]}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#PlanDetails_CandidatesOutput'
            , @ResultLabel=N'PlanDetails'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        DECLARE @TableResultName sysname,@TableTarget sysname,@TableSource sysname;
        DECLARE [TableResultCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [ResultName],[TargetTable] FROM [#PlanDetails_ResultTableMap] ORDER BY [ResultName];
        OPEN [TableResultCursor];
        FETCH NEXT FROM [TableResultCursor] INTO @TableResultName,@TableTarget;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @TableSource=CASE @TableResultName
                WHEN N'candidates' THEN N'#PlanDetails_CandidatesOutput'
                WHEN N'attributes' THEN N'#PlanDetails_Attributes'
                WHEN N'plans' THEN N'#PlanDetails_Plans' END;
            EXEC [monitor].[InternalWriteResultTable]
                  @SourceTable=@TableSource,@TargetTable=@TableTarget,@ThrowOnError=1;
            FETCH NEXT FROM [TableResultCursor] INTO @TableResultName,@TableTarget;
        END;
        CLOSE [TableResultCursor];DEALLOCATE [TableResultCursor];
    END;
END;
GO
