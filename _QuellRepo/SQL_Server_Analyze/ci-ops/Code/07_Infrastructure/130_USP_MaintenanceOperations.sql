USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_MaintenanceOperations
Version      : 1.0.0
Stand        : 2026-07-18
Zweck        : Liefert eine korrelierte, rein lesende Sicht auf laufende
               Wartungsanforderungen, resumierbare Indexoperationen, ADR/PVS
               und explizit gewählte Jobs.
Datenschutz  : Liest keine SQL-Texte, Jobschritte, Befehle, Meldungen, Konten,
               Clientdaten, Wait-Ressourcen oder Objektdefinitionen.
Grenzen      : Dauer und Pausenzustand sind Kontext, kein automatischer Defekt.
               Die Prozedur setzt nichts fort, bricht nichts ab und beendet nichts.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_MaintenanceOperations]
      @DatabaseNames                       nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen        bit            = 0
    , @DatabaseNamePattern                 nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @JobNames                            nvarchar(max)  = NULL
    , @JobNamePattern                      nvarchar(4000) = NULL
    , @NurProblematisch                    bit            = 0
    , @ResumablePausedWarnMinutes          int            = 60
    , @BlockedWarnMs                       bigint         = 5000
    , @PvsWarnMb                           decimal(19,2)  = 1024
    , @AbortedTransactionsWarnCount        bigint         = 1
    , @MaxZeilen                           int            = 1000
    , @LockTimeoutMs                       int            = 0
    , @ResultSetArt                        varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                        bit            = 0
    , @Json                                nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                      bit            = 1
    , @Hilfe                               bit            = 0
    , @StatusCodeOut                       varchar(40)    = NULL OUTPUT
    , @IsPartialOut                        bit            = NULL OUTPUT
    , @ErrorNumberOut                      int            = NULL OUTPUT
    , @ErrorMessageOut                     nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json=NULL;

    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'resumableOperations',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                               THEN CONVERT(bigint,9223372036854775807)
                               ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @CrossDatabaseRequested bit=0;
    DECLARE @JobPatternMode varchar(8),@JobPatternValue nvarchar(4000),@JobPatternIsValid bit;
    SELECT @JobPatternMode=[PatternMode],@JobPatternValue=[PatternValue],@JobPatternIsValid=[IsValid]
    FROM [monitor].[TVF_ParsePattern](@JobNamePattern);
    DECLARE @JobFilterRequested bit=CONVERT(bit,CASE WHEN NULLIF(LTRIM(RTRIM(@JobNames)),N'') IS NOT NULL
                                                      OR NULLIF(LTRIM(RTRIM(@JobNamePattern)),N'') IS NOT NULL
                                                     THEN 1 ELSE 0 END);

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_MaintenanceOperations';
        PRINT N'Die Procedure liefert eine korrelierte, rein lesende Sicht auf Wartungsrequests, resumierbare Indexoperationen, ADR/PVS und explizit gefilterte Agent-Jobs.';
        PRINT N'Ohne @JobNames oder @JobNamePattern werden weder Jobnamen noch Jobaktivitaet gelesen; JobNamePattern ist ein LIKE-Pattern.';
        PRINT N'Keine SQL-Texte, Jobschritte, Befehlsinhalte, Meldungen, Konten, Clientdaten oder Wait-Ressourcen werden gelesen.';
        RETURN;
    END;

    CREATE TABLE [#MaintenanceOperations_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL PRIMARY KEY,[DatabaseName] sysname NOT NULL,[StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL,[IsReadOnly] bit NULL,[CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL,[RecoveryModelDesc] nvarchar(60) NULL,[IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );
    CREATE TABLE [#MaintenanceOperations_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL,[StatusCode] varchar(40) NOT NULL,[ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#MaintenanceOperations_SourceStatus]
    (
          [SourceName] nvarchar(128) NOT NULL PRIMARY KEY,[StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL,[Detail] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#MaintenanceOperations_Resumable]
    (
          [DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[SchemaName] sysname NULL
        , [ObjectName] sysname NULL,[IndexName] sysname NULL,[PartitionNumber] int NULL
        , [StateDesc] nvarchar(60) NULL,[StartTime] datetime NULL,[LastPauseTime] datetime NULL
        , [TotalExecutionTimeMinutes] bigint NULL,[PercentComplete] real NULL,[PageCount] bigint NULL
        , [FindingCode] varchar(100) NOT NULL,[FindingSeverity] varchar(16) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#MaintenanceOperations_Requests]
    (
          [SessionId] smallint NOT NULL,[RequestId] int NOT NULL,[DatabaseId] int NULL,[DatabaseName] sysname NULL
        , [Command] nvarchar(60) NULL,[Status] nvarchar(30) NULL,[StartTime] datetime NULL
        , [ElapsedMs] int NULL,[PercentComplete] real NULL,[EstimatedCompletionMs] bigint NULL
        , [BlockingSessionId] smallint NULL,[WaitType] nvarchar(120) NULL,[WaitTimeMs] int NULL
        , [Reads] bigint NULL,[Writes] bigint NULL,[IsResumable] bit NULL
        , [FindingCode] varchar(100) NOT NULL,[FindingSeverity] varchar(16) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#MaintenanceOperations_Pvs]
    (
          [DatabaseId] int NOT NULL,[DatabaseName] sysname NOT NULL,[AdrEnabled] bit NOT NULL
        , [PvsSizeMb] decimal(19,2) NULL,[OnlineIndexPvsSizeMb] decimal(19,2) NULL
        , [CurrentAbortedTransactionCount] bigint NULL
        , [FindingCode] varchar(100) NOT NULL,[FindingSeverity] varchar(16) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#MaintenanceOperations_Jobs]
    (
          [JobName] sysname NOT NULL,[StartExecutionDate] datetime NULL,[StopExecutionDate] datetime NULL
        , [IsRunning] bit NOT NULL,[FindingCode] varchar(100) NOT NULL,[FindingSeverity] varchar(16) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );

    IF @MaxZeilen<0 OR @LockTimeoutMs<0
       OR @ResumablePausedWarnMinutes<1 OR @ResumablePausedWarnMinutes>525600
       OR @BlockedWarnMs<0 OR @PvsWarnMb<0 OR @AbortedTransactionsWarnCount<0
       OR @JobPatternIsValid=0 OR (@JobNames IS NOT NULL AND @JobNamePattern IS NOT NULL)
       OR @OutputMode NOT IN ('RAW','CONSOLE','NONE')
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungueltiger Grenzwert, Datenbank-, Zeilen- oder Ausgabeparameter.';
    END;
    IF @StatusCode='AVAILABLE' AND @JobPatternMode IN ('REGEX','REGEXI')
    BEGIN
        SELECT @StatusCode='UNAVAILABLE_FEATURE',@IsPartial=1,
               @ErrorMessage=N'Dieses Metadatenmodul unterstuetzt fuer Jobnamen exakte Listen und LIKE-Pattern; Regex wird nicht ausgefuehrt.';
    END;
    IF @StatusCode='AVAILABLE' AND @JobNames IS NOT NULL
       AND EXISTS(SELECT 1 FROM [monitor].[TVF_ParseStringList](@JobNames) WHERE [IsValid]=0)
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'@JobNames enthaelt mindestens einen ungueltigen Listenwert.';
    END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed,@AnalysisClass=NULL
            , @StatusCode=@StatusCode OUTPUT,@ErrorMessage=@ErrorMessage OUTPUT
            , @CrossDatabaseRequested=@CrossDatabaseRequested OUTPUT,@CandidateTable=N'#MaintenanceOperations_DatabaseCandidates',@WarningTable=N'#MaintenanceOperations_DatabaseCandidateWarnings';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode='AVAILABLE'
    BEGIN
        BEGIN TRY
            DECLARE @DatabaseId int,@DatabaseName sysname,@Sql nvarchar(max);
            DECLARE [database_cursor] CURSOR LOCAL FAST_FORWARD FOR
                SELECT [DatabaseId],[DatabaseName] FROM [#MaintenanceOperations_DatabaseCandidates]
                WHERE [StateDesc]=N'ONLINE' AND [DatabaseId]<>2 ORDER BY [DatabaseId];
            OPEN [database_cursor];
            FETCH NEXT FROM [database_cursor] INTO @DatabaseId,@DatabaseName;
            WHILE @@FETCH_STATUS=0
            BEGIN
                BEGIN TRY
                    SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; INSERT [#MaintenanceOperations_Resumable] '
                        +N'([DatabaseId],[DatabaseName],[SchemaName],[ObjectName],[IndexName],[PartitionNumber],[StateDesc],'
                        +N'[StartTime],[LastPauseTime],[TotalExecutionTimeMinutes],[PercentComplete],[PageCount],'
                        +N'[FindingCode],[FindingSeverity],[EvidenceLimit]) '
                        +N'SELECT @pDatabaseId,@pDatabaseName,[s].[name],[t].[name],COALESCE([i].[name],[r].[name]),'
                        +N'[r].[partition_number],[r].[state_desc],[r].[start_time],[r].[last_pause_time],'
                        +N'[r].[total_execution_time],[r].[percent_complete],[r].[page_count],'
                        +N'CASE WHEN [r].[state_desc]=N''PAUSED'' AND COALESCE([r].[last_pause_time],[r].[start_time])<DATEADD(MINUTE,-@pWarnMinutes,GETDATE()) '
                        +N'THEN ''RESUMABLE_OPERATION_PAUSED_LONG'' WHEN [r].[state_desc]=N''PAUSED'' THEN ''RESUMABLE_OPERATION_PAUSED'' '
                        +N'ELSE ''RESUMABLE_OPERATION_ACTIVE'' END,'
                        +N'CASE WHEN [r].[state_desc]=N''PAUSED'' AND COALESCE([r].[last_pause_time],[r].[start_time])<DATEADD(MINUTE,-@pWarnMinutes,GETDATE()) '
                        +N'THEN ''MEDIUM'' ELSE ''INFO'' END,'
                        +N'N''Ein Pausenzustand kann beabsichtigt sein; keine automatische RESUME- oder ABORT-Aktion.'' '
                        +N'FROM '+QUOTENAME(@DatabaseName)+N'.[sys].[index_resumable_operations] AS [r] WITH (NOLOCK) '
                        +N'LEFT JOIN '+QUOTENAME(@DatabaseName)+N'.[sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[r].[object_id] '
                        +N'LEFT JOIN '+QUOTENAME(@DatabaseName)+N'.[sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] '
                        +N'LEFT JOIN '+QUOTENAME(@DatabaseName)+N'.[sys].[indexes] AS [i] WITH (NOLOCK) '
                        +N'ON [i].[object_id]=[r].[object_id] AND [i].[index_id]=[r].[index_id];';
                    EXEC [sys].[sp_executesql] @Sql,
                         N'@pDatabaseId int,@pDatabaseName sysname,@pWarnMinutes int',
                         @pDatabaseId=@DatabaseId,@pDatabaseName=@DatabaseName,@pWarnMinutes=@ResumablePausedWarnMinutes;
                END TRY
                BEGIN CATCH
                    SET @IsPartial=1;
                    INSERT [#MaintenanceOperations_DatabaseCandidateWarnings] VALUES
                    (@DatabaseName,CASE WHEN ERROR_NUMBER() IN (229,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                     N'Resumierbare Indexoperationen waren fuer diese Datenbank nicht lesbar.');
                END CATCH;
                FETCH NEXT FROM [database_cursor] INTO @DatabaseId,@DatabaseName;
            END;
            CLOSE [database_cursor];
            DEALLOCATE [database_cursor];
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'sys.index_resumable_operations','AVAILABLE',@IsPartial,
             N'Resumierbare Indexoperationen ohne SQL-Text; pausierte Operationen werden niemals automatisch veraendert.');
        END TRY
        BEGIN CATCH
            IF CURSOR_STATUS('local','database_cursor')>=0 CLOSE [database_cursor];
            IF CURSOR_STATUS('local','database_cursor')>-3 DEALLOCATE [database_cursor];
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'sys.index_resumable_operations','ERROR_HANDLED',1,N'Die datenbanklokale Abfrage wurde abgefangen.');
            SELECT @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
        END CATCH;

        BEGIN TRY
            INSERT [#MaintenanceOperations_Requests]
            SELECT [r].[session_id],[r].[request_id],[r].[database_id],[d].[DatabaseName],
                   [r].[command],[r].[status],[r].[start_time],[r].[total_elapsed_time],[r].[percent_complete],
                   [r].[estimated_completion_time],[r].[blocking_session_id],[r].[wait_type],[r].[wait_time],
                   [r].[reads],[r].[writes],[r].[is_resumable],
                   CASE WHEN [r].[blocking_session_id]>0 AND [r].[wait_time]>=@BlockedWarnMs
                        THEN 'MAINTENANCE_REQUEST_BLOCKED' WHEN [r].[command] LIKE N'ROLLBACK%'
                        THEN 'ROLLBACK_IN_PROGRESS' ELSE 'MAINTENANCE_REQUEST_ACTIVE' END,
                   CASE WHEN [r].[blocking_session_id]>0 AND [r].[wait_time]>=@BlockedWarnMs THEN 'MEDIUM' ELSE 'INFO' END,
                   N'Fortschritt und Restzeit sind Engine-Schaetzwerte; SQL-Text, Handles, Konten, Clients und Wait-Ressourcen bleiben ausgeschlossen.'
            FROM [sys].[dm_exec_requests] AS [r] WITH (NOLOCK)
            LEFT JOIN [#MaintenanceOperations_DatabaseCandidates] AS [d] ON [d].[DatabaseId]=[r].[database_id]
            WHERE [r].[session_id]<>@@SPID
              AND ([r].[database_id] IN (SELECT [DatabaseId] FROM [#MaintenanceOperations_DatabaseCandidates]) OR [r].[database_id] IS NULL)
              AND ([r].[command] LIKE N'ALTER INDEX%'
                OR [r].[command] LIKE N'DBCC%'
                OR [r].[command] LIKE N'BACKUP%'
                OR [r].[command] LIKE N'RESTORE%'
                OR [r].[command] LIKE N'ROLLBACK%');
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'sys.dm_exec_requests','AVAILABLE',0,
             N'Nur technische Request-, Fortschritts-, Blockierungs- und IO-Zaehler; keine Identitaets-, Client- oder SQL-Daten.');
        END TRY
        BEGIN CATCH
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'sys.dm_exec_requests',CASE WHEN ERROR_NUMBER() IN (229,371) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,
             N'Laufende Wartungsrequests waren nicht lesbar; die uebrigen Quellen werden weiter ausgewertet.');
            SELECT @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
        END CATCH;

        INSERT [#MaintenanceOperations_Pvs]
        ([DatabaseId],[DatabaseName],[AdrEnabled],[PvsSizeMb],[OnlineIndexPvsSizeMb],
         [CurrentAbortedTransactionCount],
         [FindingCode],[FindingSeverity],[EvidenceLimit])
        SELECT [c].[DatabaseId],[c].[DatabaseName],[d].[is_accelerated_database_recovery_on],NULL,NULL,NULL,
               CASE WHEN [d].[is_accelerated_database_recovery_on]=1 THEN 'ADR_ENABLED_PVS_DETAIL_PENDING' ELSE 'ADR_NOT_ENABLED' END,
               'INFO',N'ADR/PVS-Zaehler sind Zeitpunktwerte und beweisen allein keine Bereinigungsstoerung.'
        FROM [#MaintenanceOperations_DatabaseCandidates] AS [c]
        JOIN [sys].[databases] AS [d] WITH (NOLOCK) ON [d].[database_id]=[c].[DatabaseId];

        IF @Major>=16
        BEGIN
          BEGIN TRY
            SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; UPDATE [p] SET '
                +N'[PvsSizeMb]=CONVERT(decimal(19,2),[s].[persistent_version_store_size_kb]/1024.0),'
                +N'[OnlineIndexPvsSizeMb]=CONVERT(decimal(19,2),[s].[online_index_version_store_size_kb]/1024.0),'
                +N'[CurrentAbortedTransactionCount]=[s].[current_aborted_transaction_count] '
                +N'FROM [#MaintenanceOperations_Pvs] AS [p] JOIN [sys].[dm_tran_persistent_version_store_stats] AS [s] WITH (NOLOCK) '
                +N'ON [s].[database_id]=[p].[DatabaseId];';
            EXEC [sys].[sp_executesql] @Sql;

            UPDATE [p]
            SET [FindingCode]=CASE
                    WHEN [PvsSizeMb]>=@PvsWarnMb AND [CurrentAbortedTransactionCount]>=@AbortedTransactionsWarnCount
                        THEN 'PVS_LARGE_WITH_ABORTED_TRANSACTIONS'
                    WHEN [PvsSizeMb]>=@PvsWarnMb THEN 'PVS_SIZE_THRESHOLD_REACHED'
                    WHEN [CurrentAbortedTransactionCount]>=@AbortedTransactionsWarnCount
                        THEN 'ABORTED_TRANSACTIONS_VISIBLE' ELSE 'PVS_WITHIN_THRESHOLDS' END,
                [FindingSeverity]=CASE WHEN [PvsSizeMb]>=@PvsWarnMb
                                        OR [CurrentAbortedTransactionCount]>=@AbortedTransactionsWarnCount
                                       THEN 'MEDIUM' ELSE 'INFO' END
            FROM [#MaintenanceOperations_Pvs] AS [p] WHERE [AdrEnabled]=1;
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'sys.dm_tran_persistent_version_store_stats','AVAILABLE',0,
             N'Aggregierte ADR/PVS-Zaehler; Verfuegbarkeit wird fuer SQL Server 2022 oder neuer geprueft.');
          END TRY
          BEGIN CATCH
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'sys.dm_tran_persistent_version_store_stats',CASE WHEN ERROR_NUMBER() IN (229,371) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,
             N'ADR/PVS-Detailzaehler waren nicht lesbar; ADR-Konfiguration bleibt sichtbar.');
            SELECT @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
          END CATCH;
        END
        ELSE
        BEGIN
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'sys.dm_tran_persistent_version_store_stats','UNAVAILABLE_VERSION',1,
             N'Der stabile Detailvertrag dieses Moduls beginnt mit SQL Server 2022; SQL Server 2019 liefert nur den ADR-Kontext.');
        END;

        IF @JobFilterRequested=1
        BEGIN
          BEGIN TRY
            ;WITH [CurrentAgentSession] AS
            (
                SELECT MAX([session_id]) AS [session_id] FROM [msdb].[dbo].[syssessions] WITH (NOLOCK)
            )
            INSERT [#MaintenanceOperations_Jobs]
            SELECT [j].[name],[a].[start_execution_date],[a].[stop_execution_date],
                   CONVERT(bit,CASE WHEN [a].[start_execution_date] IS NOT NULL AND [a].[stop_execution_date] IS NULL THEN 1 ELSE 0 END),
                   'SELECTED_JOB_STATE','INFO',
                   N'Nur explizit gefilterter Jobname und Laufstatus; keine Owner, Schritte, Befehle oder Meldungen.'
            FROM [msdb].[dbo].[sysjobs] AS [j] WITH (NOLOCK)
            LEFT JOIN [CurrentAgentSession] AS [s] ON 1=1
            LEFT JOIN [msdb].[dbo].[sysjobactivity] AS [a] WITH (NOLOCK)
              ON [a].[session_id]=[s].[session_id] AND [a].[job_id]=[j].[job_id]
            WHERE (@JobNames IS NULL OR EXISTS
                  (SELECT 1 FROM [monitor].[TVF_ParseStringList](@JobNames) AS [f]
                   WHERE [f].[IsValid]=1 AND [f].[StringValue]=[j].[name] COLLATE SQL_Latin1_General_CP1_CS_AS))
              AND (@JobPatternMode='NONE' OR [j].[name] COLLATE SQL_Latin1_General_CP1_CS_AS LIKE @JobPatternValue COLLATE SQL_Latin1_General_CP1_CS_AS);

            IF (SELECT COUNT_BIG(*) FROM [#MaintenanceOperations_Jobs] WHERE [IsRunning]=1)>1
                UPDATE [#MaintenanceOperations_Jobs] SET [FindingCode]='SELECTED_JOBS_OVERLAP',[FindingSeverity]='MEDIUM'
                WHERE [IsRunning]=1;

            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'msdb.dbo.sysjobs + msdb.dbo.sysjobactivity','AVAILABLE',0,
             N'Jobquelle wurde nur wegen eines expliziten Namens- oder Patternfilters gelesen.');
          END TRY
          BEGIN CATCH
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'msdb.dbo.sysjobs + msdb.dbo.sysjobactivity',CASE WHEN ERROR_NUMBER() IN (229,371,916) THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,1,
             N'Explizit angeforderte Jobaktivitaet war nicht lesbar; keine Jobdetails wurden ersatzweise gelesen.');
            SELECT @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
          END CATCH;
        END
        ELSE
        BEGIN
            INSERT [#MaintenanceOperations_SourceStatus] VALUES
            (N'msdb.dbo.sysjobs + msdb.dbo.sysjobactivity','NOT_REQUESTED',0,
             N'Ohne expliziten Jobfilter werden Jobnamen und Jobaktivitaet nicht gelesen.');
        END;

        IF EXISTS(SELECT 1 FROM [#MaintenanceOperations_SourceStatus] WHERE [IsPartial]=1)
            SELECT @StatusCode='AVAILABLE_LIMITED',@IsPartial=1;
        ELSE IF EXISTS(SELECT 1 FROM [#MaintenanceOperations_Resumable] WHERE [FindingSeverity] IN ('HIGH','MEDIUM'))
             OR EXISTS(SELECT 1 FROM [#MaintenanceOperations_Requests] WHERE [FindingSeverity] IN ('HIGH','MEDIUM'))
             OR EXISTS(SELECT 1 FROM [#MaintenanceOperations_Pvs] WHERE [FindingSeverity] IN ('HIGH','MEDIUM'))
             OR EXISTS(SELECT 1 FROM [#MaintenanceOperations_Jobs] WHERE [FindingSeverity] IN ('HIGH','MEDIUM'))
            SET @StatusCode='AVAILABLE_WITH_FINDING';
    END;

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=(SELECT N'MaintenanceOperations' AS [resultName],1 AS [schemaVersion],
            @Now AS [generatedAtUtc],@StatusCode AS [statusCode],@IsPartial AS [isPartial],@Major AS [productMajorVersion]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
        DECLARE @ResumableJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Resumable]
            WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM')
            ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,[DatabaseId],[StartTime]
            FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @RequestJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Requests]
            WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM')
            ORDER BY CASE [FindingSeverity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,[ElapsedMs] DESC
            FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @PvsJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Pvs]
            WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM') ORDER BY [DatabaseId]
            FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @JobJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Jobs]
            WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM') ORDER BY [JobName]
            FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @SourceJson nvarchar(max)=(SELECT * FROM [#MaintenanceOperations_SourceStatus] ORDER BY [SourceName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"resumableOperations":',COALESCE(@ResumableJson,N'[]'),
            N',"requests":',COALESCE(@RequestJson,N'[]'),N',"pvs":',COALESCE(@PvsJson,N'[]'),
            N',"jobs":',COALESCE(@JobJson,N'[]'),N',"sources":',COALESCE(@SourceJson,N'[]'),N'}');
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT N'USP_MaintenanceOperations' AS [ModuleName],@Now AS [CollectionTimeUtc],@StatusCode AS [StatusCode],
               @IsPartial AS [IsPartial],@Major AS [ProductMajorVersion],@ErrorNumber AS [ErrorNumber],@ErrorMessage AS [ErrorMessage];
        SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Resumable] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Requests] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Pvs] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT TOP (@Limit) * FROM [#MaintenanceOperations_Jobs] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT * FROM [#MaintenanceOperations_SourceStatus] ORDER BY [SourceName];
        SELECT * FROM [#MaintenanceOperations_DatabaseCandidateWarnings] ORDER BY [RequestedName];
    END
    ELSE IF @OutputMode='CONSOLE'
    BEGIN
        SELECT N'Wartungsoperationen' AS [Ergebnis],@Now AS [Stand_UTC],@StatusCode AS [Status],
               @IsPartial AS [Teilweise],@ErrorMessage AS [Hinweis];
        SELECT TOP (@Limit) N'Resumierbare Indexoperation' AS [Ergebnis],[DatabaseName] AS [Datenbank],
               [SchemaName] AS [Schema],[ObjectName] AS [Objekt],[IndexName] AS [Index],[StateDesc] AS [Status],
               [PercentComplete] AS [Fortschritt_Prozent],[LastPauseTime] AS [Letzte_Pause],
               [FindingCode] AS [Befund],[FindingSeverity] AS [Prioritaet],[EvidenceLimit] AS [Evidenzgrenze]
        FROM [#MaintenanceOperations_Resumable] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT TOP (@Limit) N'Laufender Wartungsrequest' AS [Ergebnis],[SessionId] AS [Session_ID],
               [DatabaseName] AS [Datenbank],[Command] AS [Operation],[Status],[ElapsedMs] AS [Dauer_ms],
               [PercentComplete] AS [Fortschritt_Prozent],[BlockingSessionId] AS [Blockiert_durch],
               [WaitType] AS [Wait_Typ],[FindingCode] AS [Befund],[FindingSeverity] AS [Prioritaet]
        FROM [#MaintenanceOperations_Requests] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT TOP (@Limit) N'ADR und PVS' AS [Ergebnis],[DatabaseName] AS [Datenbank],[AdrEnabled] AS [ADR_Aktiv],
               [PvsSizeMb] AS [PVS_MB],[OnlineIndexPvsSizeMb] AS [Online_Index_PVS_MB],
               [CurrentAbortedTransactionCount] AS [Abgebrochene_Transaktionen],
               [FindingCode] AS [Befund],[FindingSeverity] AS [Prioritaet],[EvidenceLimit] AS [Evidenzgrenze]
        FROM [#MaintenanceOperations_Pvs] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT TOP (@Limit) N'Explizit gewaehlter Job' AS [Ergebnis],[JobName] AS [Job],
               [StartExecutionDate] AS [Start],[IsRunning] AS [Laeuft],[FindingCode] AS [Befund],
               [FindingSeverity] AS [Prioritaet],[EvidenceLimit] AS [Evidenzgrenze]
        FROM [#MaintenanceOperations_Jobs] WHERE @NurProblematisch=0 OR [FindingSeverity] IN ('HIGH','MEDIUM');
        SELECT N'Quellenstatus' AS [Ergebnis],[SourceName] AS [Quelle],[StatusCode] AS [Status],[Detail] AS [Hinweis]
        FROM [#MaintenanceOperations_SourceStatus] ORDER BY [SourceName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#MaintenanceOperations_Resumable'
            , @ResultLabel=N'MaintenanceOperations'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#MaintenanceOperations_Resumable'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
