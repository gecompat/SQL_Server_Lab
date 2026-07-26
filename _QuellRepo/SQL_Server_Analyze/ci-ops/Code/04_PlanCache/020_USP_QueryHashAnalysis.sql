USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_QueryHashAnalysis
Version      : 2.1.0
Stand        : 2026-07-19
Typ          : Stored Procedure
Zweck        : Aggregiert gecachte Statement-Statistiken je query_hash und zeigt
               Planvielfalt, Recompiles und kumulative Ressourcenanteile.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : sys.dm_exec_query_stats, sys.dm_exec_sql_text.
Parameter    : @QueryHash, @Sortierung, @AnalyseModus, @MinExecutionCount,
               @MinPlanVarianten, @MaxZeilen, @MaxSqlTextZeichen,
               @ParentQueryStatsSnapshot,
               @PrintMeldungen, @Hilfe.
Resultsets   : 1. Modulstatus. 2. Query-Hash-Aggregate mit Beispielstatement.
Berechtigung : VIEW SERVER STATE beziehungsweise SQL Server 2022+
               VIEW SERVER PERFORMANCE STATE. Keine Rechtevergabe.
Eigenlast    : Gruppiert sys.dm_exec_query_stats. Ohne konkreten @QueryHash sowie
               im Modus VOLL wird PLAN_CACHE_DEEP geprüft. Text wird nur für
               gewählte Hashes geladen.
Locking      : Keine Benutzerobjekte.
Partial      : Cache-Eviction kann Beispieltexte zwischen Auswahl und Ausgabe entfernen.
Beispiele    : EXEC monitor.USP_QueryHashAnalysis @MinPlanVarianten=2;
               EXEC monitor.USP_QueryHashAnalysis @Sortierung='READS_TOTAL';
               EXEC monitor.USP_QueryHashAnalysis @Hilfe=1;
Änderungen   : 2.1.0 - Query-Stats je Aufruf einmal gelesen oder vom laufgebundenen
                         Parent-Snapshot übernommen.
               1.1.0 - Breite Aggregation ohne @QueryHash gruppengeschützt.
               1.0.0 - Erstfassung Phase 3.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_QueryHashAnalysis]
      @QueryHash           binary(8)   = NULL
    , @Sortierung              varchar(32) = 'CPU_TOTAL'
    , @AnalyseModus        varchar(16) = 'TOP'
    , @MinExecutionCount   bigint      = 1
    , @MinPlanVarianten    int         = 1
    , @MaxZeilen           int         = 100
    , @MaxSqlTextZeichen   int         = 4000
    , @ParentQueryStatsSnapshot bit    = 0
    , @HighImpactConfirmed bit         = 0
    , @ResultSetArt        varchar(16) = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen        bit         = 0
    , @Json                 nvarchar(max) = NULL OUTPUT
    , @PrintMeldungen      bit         = 1
    , @Hilfe               bit         = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;
    DECLARE @ResultSetArtNormalisiert varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'queryHashes',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @EffectiveMaxZeilen bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0 THEN CONVERT(bigint,9223372036854775807) ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @MonitorPrintMessage nvarchar(2048);
    SET @Sortierung=UPPER(LTRIM(RTRIM(COALESCE(@Sortierung,'CPU_TOTAL'))));
    SET @AnalyseModus=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,'TOP'))));
    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_QueryHashAnalysis';
        PRINT N'@QueryHash binary(8)=NULL: optional exakt auf einen Query Hash begrenzen.';
        PRINT N'@Sortierung: CPU_TOTAL, ELAPSED_TOTAL, READS_TOTAL, WRITES_TOTAL, EXECUTIONS, PLAN_VARIANTS, SPILLS_TOTAL.';
        PRINT N'@AnalyseModus TOP oder VOLL; VOLL sowie ein Lauf ohne konkreten @QueryHash prüfen PLAN_CACHE_DEEP.';
        PRINT N'@MinExecutionCount bigint=1; @MinPlanVarianten int=1; @MaxZeilen int=100.';
        PRINT N'@MaxSqlTextZeichen positiv = gekürzt; NULL/0 = vollständiger Beispielstatementtext.';
        PRINT N'@ParentQueryStatsSnapshot ist nur für die laufinterne Wiederverwendung durch USP_PlanCacheAnalysis bestimmt; 0 liest frisch.';
        PRINT N'@ResultSetArt RAW|CONSOLE|TABLE|NONE; @JsonErzeugen=1 setzt @Json OUTPUT; Steuerwerte sind case-insensitiv.';
        PRINT N'@PrintMeldungen bit=1; @Hilfe bit=0. Die Auswertung ist cachegebunden und keine Historie.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3)=SYSUTCDATETIME(),@StatusCode varchar(40)='AVAILABLE',@IsPartial bit=0,@RowCount bigint=0,
            @ErrorNumber int=NULL,@ErrorMessage nvarchar(2048)=NULL,@Detail nvarchar(2000)=NULL,@Allowed bit=1,
            @RequiredPermission nvarchar(256)=CASE WHEN TRY_CONVERT([int],SERVERPROPERTY(N'ProductMajorVersion'))>=16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END;

    CREATE TABLE [#QueryHashAnalysis_Hash]
    (
        [QueryHash] binary(8) NOT NULL,[PlanVariantCount] int NOT NULL,[PlanHandleCount] int NOT NULL,[CompilationCount] bigint NOT NULL,
        [ExecutionCount] bigint NOT NULL,[TotalCpuUs] bigint NOT NULL,[TotalElapsedUs] bigint NOT NULL,[TotalReads] bigint NOT NULL,
        [TotalWrites] bigint NOT NULL,[TotalSpills] bigint NOT NULL,[MaxGrantKb] bigint NOT NULL,[FirstCreationTime] datetime NULL,
        [LastExecutionTime] datetime NULL,[SampleSqlHandle] varbinary(64) NULL,[SampleStartOffset] int NULL,[SampleEndOffset] int NULL
    );
    CREATE TABLE [#QueryHashAnalysis_QueryStatsSource]
    (
          [query_hash] binary(8) NULL
        , [query_plan_hash] binary(8) NULL
        , [plan_handle] varbinary(64) NULL
        , [sql_handle] varbinary(64) NULL
        , [statement_start_offset] int NULL
        , [statement_end_offset] int NULL
        , [execution_count] bigint NULL
        , [total_worker_time] bigint NULL
        , [total_elapsed_time] bigint NULL
        , [total_logical_reads] bigint NULL
        , [total_logical_writes] bigint NULL
        , [total_spills] bigint NULL
        , [max_grant_kb] bigint NULL
        , [creation_time] datetime NULL
        , [last_execution_time] datetime NULL
    );

    IF @Sortierung NOT IN('CPU_TOTAL','ELAPSED_TOTAL','READS_TOTAL','WRITES_TOTAL','EXECUTIONS','PLAN_VARIANTS','SPILLS_TOTAL')
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'Unbekannter Wert für @Sortierung.';END;
    IF @StatusCode='AVAILABLE' AND (@AnalyseModus NOT IN('TOP','VOLL') OR @MaxZeilen<0 OR @ResultSetArtNormalisiert NOT IN('RAW','CONSOLE','NONE') OR @MaxSqlTextZeichen < 0 OR @MinPlanVarianten<1 OR @MinExecutionCount<0 OR @ParentQueryStatsSnapshot IS NULL)
    BEGIN SET @StatusCode='INVALID_PARAMETER';SET @ErrorMessage=N'Ungültiger Parameterwert.';END;
    IF @StatusCode='AVAILABLE' AND (@AnalyseModus='VOLL' OR @QueryHash IS NULL OR @EffectiveMaxZeilen>1000)
        EXEC [monitor].[InternalCheckAnalysisPath] @AnalysisClass='PLAN_CACHE_DEEP',@HighImpactConfirmed=@HighImpactConfirmed,@StatusCode=@StatusCode OUTPUT,@ErrorMessage=@ErrorMessage OUTPUT;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        IF @ParentQueryStatsSnapshot=1
        BEGIN
            EXEC [sys].[sp_executesql] N'
INSERT [#QueryHashAnalysis_QueryStatsSource]
SELECT [query_hash],[query_plan_hash],[plan_handle],[sql_handle],[statement_start_offset],[statement_end_offset],
       [execution_count],[total_worker_time],[total_elapsed_time],[total_logical_reads],[total_logical_writes],
       [total_spills],[max_grant_kb],[creation_time],[last_execution_time]
FROM [#PlanCacheAnalysis_QueryStatsSnapshot]
WHERE @QueryHash IS NULL OR [query_hash]=@QueryHash;',
                N'@QueryHash binary(8)',
                @QueryHash=@QueryHash;
        END
        ELSE
        BEGIN
            INSERT [#QueryHashAnalysis_QueryStatsSource]
            SELECT [query_hash],[query_plan_hash],[plan_handle],[sql_handle],[statement_start_offset],[statement_end_offset],
                   [execution_count],[total_worker_time],[total_elapsed_time],[total_logical_reads],[total_logical_writes],
                   [total_spills],[max_grant_kb],[creation_time],[last_execution_time]
            FROM [sys].[dm_exec_query_stats] WITH (NOLOCK)
            WHERE @QueryHash IS NULL OR [query_hash]=@QueryHash;
        END;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();SET @IsPartial=1;
        SET @StatusCode=CASE WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                             WHEN @ErrorNumber=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END;
    END CATCH;

    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        ;WITH G AS
        (
            SELECT [qs].[query_hash],COUNT(DISTINCT [qs].[query_plan_hash]) AS [PlanVariantCount],COUNT(DISTINCT [qs].[plan_handle]) AS [PlanHandleCount],
                   COUNT_BIG(*) AS [CompilationCount],SUM([qs].[execution_count]) AS [ExecutionCount],SUM([qs].[total_worker_time]) AS [TotalCpuUs],
                   SUM([qs].[total_elapsed_time]) AS [TotalElapsedUs],SUM([qs].[total_logical_reads]) AS [TotalReads],SUM([qs].[total_logical_writes]) AS [TotalWrites],
                   SUM([qs].[total_spills]) AS [TotalSpills],MAX([qs].[max_grant_kb]) AS [MaxGrantKb],MIN([qs].[creation_time]) AS [FirstCreationTime],
                   MAX([qs].[last_execution_time]) AS [LastExecutionTime]
            FROM [#QueryHashAnalysis_QueryStatsSource] AS qs
            WHERE [qs].[query_hash] IS NOT NULL AND (@QueryHash IS NULL OR [qs].[query_hash]=@QueryHash)
            GROUP BY [qs].[query_hash]
            HAVING SUM([qs].[execution_count])>=@MinExecutionCount AND COUNT(DISTINCT [qs].[query_plan_hash])>=@MinPlanVarianten
        ), R AS
        (
            SELECT TOP (@EffectiveMaxZeilen) *,ROW_NUMBER() OVER(ORDER BY
                CASE @Sortierung WHEN 'CPU_TOTAL' THEN [TotalCpuUs] WHEN 'ELAPSED_TOTAL' THEN [TotalElapsedUs] WHEN 'READS_TOTAL' THEN [TotalReads]
                    WHEN 'WRITES_TOTAL' THEN [TotalWrites] WHEN 'EXECUTIONS' THEN [ExecutionCount] WHEN 'PLAN_VARIANTS' THEN [PlanVariantCount]
                    WHEN 'SPILLS_TOTAL' THEN [TotalSpills] END DESC,[LastExecutionTime] DESC) AS [rn]
            FROM [G]
            WHERE @Sortierung IN('CPU_TOTAL','ELAPSED_TOTAL','READS_TOTAL','WRITES_TOTAL','EXECUTIONS','PLAN_VARIANTS','SPILLS_TOTAL')
        )
        INSERT [#QueryHashAnalysis_Hash]
        SELECT [r].[query_hash],[r].[PlanVariantCount],[r].[PlanHandleCount],[r].[CompilationCount],[r].[ExecutionCount],[r].[TotalCpuUs],[r].[TotalElapsedUs],
               [r].[TotalReads],[r].[TotalWrites],[r].[TotalSpills],[r].[MaxGrantKb],[r].[FirstCreationTime],[r].[LastExecutionTime],[s].[sql_handle],[s].[statement_start_offset],[s].[statement_end_offset]
        FROM [R] AS r
        OUTER APPLY
        (
            SELECT TOP(1) [qs].[sql_handle],[qs].[statement_start_offset],[qs].[statement_end_offset]
            FROM [#QueryHashAnalysis_QueryStatsSource] AS qs WHERE [qs].[query_hash]=[r].[query_hash] ORDER BY [qs].[total_worker_time] DESC
        ) AS s
        OPTION(RECOMPILE,MAXDOP 1);
        SET @RowCount=@@ROWCOUNT;SET @Detail=N'Query-Hash-Aggregation erfolgreich.';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER();SET @ErrorMessage=ERROR_MESSAGE();SET @IsPartial=1;
        SET @StatusCode=CASE WHEN @ErrorNumber IN(229,262,297,300,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END;
    END CATCH;

    IF @PrintMeldungen=1 AND @StatusCode<>'AVAILABLE' BEGIN
    SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_QueryHashAnalysis: %s - %s', @StatusCode, COALESCE(@ErrorMessage,N''));
    RAISERROR(N'%s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
END;
    CREATE TABLE [#QueryHashAnalysis_Output]
    (
          [QueryHash] binary(8) NOT NULL
        , [PlanVariantCount] int NOT NULL
        , [PlanHandleCount] int NOT NULL
        , [CompilationCount] bigint NOT NULL
        , [ExecutionCount] bigint NOT NULL
        , [TotalCpuMs] decimal(38,3) NULL
        , [AvgCpuMs] decimal(38,3) NULL
        , [TotalElapsedMs] decimal(38,3) NULL
        , [AvgElapsedMs] decimal(38,3) NULL
        , [TotalReads] bigint NOT NULL
        , [AvgReads] decimal(38,3) NULL
        , [TotalWrites] bigint NOT NULL
        , [TotalSpills] bigint NOT NULL
        , [MaxGrantKb] bigint NOT NULL
        , [FirstCreationTime] datetime NULL
        , [LastExecutionTime] datetime NULL
        , [SampleStatementTextCharacters] bigint NULL
        , [SampleStatementTextBytes] bigint NULL
        , [SampleStatementTextIsTruncated] bit NOT NULL DEFAULT(0)
        , [SampleStatementText] nvarchar(max) NULL
    );

    INSERT [#QueryHashAnalysis_Output]
    SELECT [h].[QueryHash],[h].[PlanVariantCount],[h].[PlanHandleCount],[h].[CompilationCount],[h].[ExecutionCount],
           CONVERT(decimal(38,3),[h].[TotalCpuUs]/1000.0),CONVERT(decimal(38,3),[h].[TotalCpuUs]/NULLIF([h].[ExecutionCount],0)/1000.0),
           CONVERT(decimal(38,3),[h].[TotalElapsedUs]/1000.0),CONVERT(decimal(38,3),[h].[TotalElapsedUs]/NULLIF([h].[ExecutionCount],0)/1000.0),
           [h].[TotalReads],CONVERT(decimal(38,3),[h].[TotalReads]*1.0/NULLIF([h].[ExecutionCount],0)),[h].[TotalWrites],[h].[TotalSpills],[h].[MaxGrantKb],
           [h].[FirstCreationTime],[h].[LastExecutionTime],
           NULL,NULL,CONVERT(bit,0),[statementText].[StatementText]
    FROM [#QueryHashAnalysis_Hash] AS [h]
    OUTER APPLY [sys].[dm_exec_sql_text]([h].[SampleSqlHandle]) AS [st]
    OUTER APPLY [monitor].[TVF_StatementText]
    (
          [st].[text]
        , [h].[SampleStartOffset]
        , [h].[SampleEndOffset]
    ) AS [statementText];

    DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
    EXEC [monitor].[InternalProjectUnicodeTextColumn]
          @SourceTable=N'#QueryHashAnalysis_Output',@TextColumn=N'SampleStatementText'
        , @CharactersColumn=N'SampleStatementTextCharacters',@BytesColumn=N'SampleStatementTextBytes'
        , @IsTruncatedColumn=N'SampleStatementTextIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
        , @TruncatedValueCount=@TruncatedValueCount OUTPUT,@LargestRequiredCharacters=@LargestRequiredCharacters OUTPUT;
    EXEC [monitor].[InternalEmitTruncationWarning]
          @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen'
        , @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters
        , @PrintMeldungen=@PrintMeldungen;

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        SELECT N'USP_QueryHashAnalysis' [ModuleName],@CollectionTimeUtc [CollectionTimeUtc],@StatusCode [StatusCode],@IsPartial [IsPartial],@RowCount [RowCount],
               @RequiredPermission [RequiredPermission],@ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage],@Detail [Detail];
        IF @ResultSetArtNormalisiert='RAW'
            SELECT * FROM [#QueryHashAnalysis_Output]
            ORDER BY CASE @Sortierung WHEN 'CPU_TOTAL' THEN [TotalCpuMs] WHEN 'ELAPSED_TOTAL' THEN [TotalElapsedMs] WHEN 'READS_TOTAL' THEN [TotalReads]
                WHEN 'WRITES_TOTAL' THEN [TotalWrites] WHEN 'EXECUTIONS' THEN [ExecutionCount] WHEN 'PLAN_VARIANTS' THEN [PlanVariantCount]
                WHEN 'SPILLS_TOTAL' THEN [TotalSpills] END DESC,[LastExecutionTime] DESC;
        ELSE
            SELECT N'Query-Hash-Aggregat' AS [Ergebnis],[QueryHash] AS [Query Hash],[PlanVariantCount] AS [Planvarianten],[ExecutionCount] AS [Ausführungen],
                   CONCAT(CONVERT(varchar(40),CONVERT(decimal(19,2),[TotalCpuMs])),N' ms') AS [CPU gesamt],
                   CONCAT(CONVERT(varchar(40),CONVERT(decimal(19,2),[AvgCpuMs])),N' ms') AS [CPU Ø],
                   [TotalReads] AS [Logical Reads],[TotalSpills] AS [Spills],[LastExecutionTime] AS [letzte Ausführung],[QueryHash] AS [Query Hash SQL],[SampleStatementText] AS [Beispielstatement]
            FROM [#QueryHashAnalysis_Output]
            ORDER BY CASE @Sortierung WHEN 'CPU_TOTAL' THEN [TotalCpuMs] WHEN 'ELAPSED_TOTAL' THEN [TotalElapsedMs] WHEN 'READS_TOTAL' THEN [TotalReads]
                WHEN 'WRITES_TOTAL' THEN [TotalWrites] WHEN 'EXECUTIONS' THEN [ExecutionCount] WHEN 'PLAN_VARIANTS' THEN [PlanVariantCount]
                WHEN 'SPILLS_TOTAL' THEN [TotalSpills] END DESC,[LastExecutionTime] DESC;
    END;
    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'QueryHashAnalysis' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@RowCount [returnedRows],@Sortierung [sortOrder],@ErrorNumber [errorNumber],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @DataJson nvarchar(max)=(SELECT * FROM [#QueryHashAnalysis_Output] ORDER BY CASE @Sortierung WHEN 'CPU_TOTAL' THEN [TotalCpuMs] WHEN 'ELAPSED_TOTAL' THEN [TotalElapsedMs] WHEN 'READS_TOTAL' THEN [TotalReads] WHEN 'WRITES_TOTAL' THEN [TotalWrites] WHEN 'EXECUTIONS' THEN [ExecutionCount] WHEN 'PLAN_VARIANTS' THEN [PlanVariantCount] WHEN 'SPILLS_TOTAL' THEN [TotalSpills] END DESC,[LastExecutionTime] DESC FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"queryHashes":',COALESCE(@DataJson,N'[]'),N',"warnings":[]}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#QueryHashAnalysis_Output'
            , @ResultLabel=N'QueryHashAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#QueryHashAnalysis_Output'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
