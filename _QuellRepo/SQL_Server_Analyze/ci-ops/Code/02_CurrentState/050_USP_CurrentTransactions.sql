USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CurrentTransactions
Version      : 3.0.0
Stand        : 2026-07-23
Zweck        : Zeigt aktive Transaktionen einschließlich Session-, Request- und
               Logverbrauchsinformationen. Unterstützt Sessionlisten sowie
               RAW-, CONSOLE- und JSON-Ausgabe.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CurrentTransactions]
      @SessionIds                 nvarchar(max) = NULL
    , @MinAlterSekunden           int           = 0
    , @NurSleeping                bit           = 0
    , @SystemSessionsEinbeziehen  bit           = 0
    , @MitSqlText                 bit           = 1
    , @MaxSqlTextZeichen          int           = 3000
    , @MaxZeilen                  int           = 1000
    , @ResultSetArt               varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen               bit            = 0
    , @Json                       nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen             bit            = 1
    , @Hilfe                      bit            = 0
    , @ParentCurrentStateSnapshotId uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'transactions',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807)
                                 WHEN @MaxZeilen > 0 THEN CONVERT(bigint, @MaxZeilen) ELSE 0 END;
    DECLARE @Candidates bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0 THEN CONVERT(bigint, 9223372036854775807)
                                      WHEN @MaxZeilen < 2147483647 THEN CONVERT(bigint, @MaxZeilen) + 1 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_CurrentTransactions';
        PRINT N'@SessionIds = N''57|61''; NULL = keine Einschränkung.';
        PRINT N'@MaxZeilen positiv = begrenzt, NULL/0 = unbegrenzt.';
        PRINT N'@ResultSetArt = CONSOLE (Default)|RAW|TABLE|NONE; Steuerwert case-insensitiv.';
        PRINT N'@JsonErzeugen=1 liefert transactions und warnings in @Json OUTPUT.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @RowCount bigint = 0;
    DECLARE @HasMoreRows bit = 0;
    DECLARE @Message nvarchar(2048);
    DECLARE @EvidenceSnapshotId uniqueidentifier=COALESCE(@ParentCurrentStateSnapshotId,NEWID());
    DECLARE @EvidenceSnapshotStartedAtUtc datetime2(3)=@Now;
    DECLARE @EvidenceIsPartial bit=0;

    CREATE TABLE [#CurrentTransactions_SessionFilter]([SessionId] smallint NOT NULL PRIMARY KEY);
    CREATE TABLE [#CurrentTransactions_Result]
    (
          [SessionId]                smallint       NOT NULL
        , [TransactionId]            bigint         NOT NULL
        , [TransactionBeginTimeUtc]  datetime       NULL
        , [TransactionAgeSeconds]    bigint         NULL
        , [TransactionType]          int            NULL
        , [TransactionState]         int            NULL
        , [OpenTransactionCount]     int            NULL
        , [LoginName]                nvarchar(128)  NULL
        , [HostName]                 nvarchar(128)  NULL
        , [ProgramName]              nvarchar(128)  NULL
        , [SessionStatus]            nvarchar(30)   NULL
        , [RequestStatus]            nvarchar(30)   NULL
        , [DatabaseId]               int            NULL
        , [DatabaseName]             sysname        NULL
        , [LogBytesUsed]             bigint         NULL
        , [LogBytesReserved]         bigint         NULL
        , [StatementTextCharacters]  bigint         NULL
        , [StatementTextBytes]       bigint         NULL
        , [StatementTextIsTruncated] bit            NOT NULL DEFAULT(0)
        , [StatementText]            nvarchar(max)  NULL
    );
    CREATE TABLE [#CurrentTransactions_Warnings]
    (
          [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#CurrentTransactions_SourceSessionTransactions]
    (
          [session_id] int NOT NULL
        , [transaction_id] bigint NOT NULL
        , PRIMARY KEY([session_id],[transaction_id])
    );
    CREATE TABLE [#CurrentTransactions_SourceActiveTransactions]
    (
          [transaction_id] bigint NOT NULL PRIMARY KEY
        , [transaction_begin_time] datetime NULL
        , [transaction_type] int NULL
        , [transaction_state] int NULL
    );
    CREATE TABLE [#CurrentTransactions_SourceDatabaseTransactions]
    (
          [transaction_id] bigint NOT NULL
        , [database_id] int NOT NULL
        , [database_transaction_log_bytes_used] bigint NOT NULL
        , [database_transaction_log_bytes_reserved] bigint NOT NULL
    );
    CREATE TABLE [#CurrentTransactions_SourceSessions]
    (
          [session_id] smallint NOT NULL PRIMARY KEY
        , [is_user_process] bit NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [open_transaction_count] int NOT NULL
        , [login_name] nvarchar(128) NOT NULL
        , [host_name] nvarchar(128) NULL
        , [program_name] nvarchar(128) NULL
    );
    CREATE TABLE [#CurrentTransactions_SourceRequests]
    (
          [session_id] smallint NOT NULL
        , [request_id] int NOT NULL
        , [status] nvarchar(30) NOT NULL
        , [database_id] smallint NOT NULL
        , [sql_handle] varbinary(64) NULL
        , [statement_start_offset] int NULL
        , [statement_end_offset] int NULL
        , PRIMARY KEY([session_id],[request_id])
    );
    CREATE TABLE [#CurrentTransactions_SourceSqlText]
    (
          [SqlHandle] varbinary(64) NOT NULL PRIMARY KEY
        , [Text] nvarchar(max) NULL
    );

    IF @SessionIds IS NOT NULL
    BEGIN
        IF EXISTS
        (
            SELECT 1 FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid] = 0 OR [NumberValue] NOT BETWEEN 0 AND 32767
        )
        OR EXISTS
        (
            SELECT [NumberValue]
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid] = 1
            GROUP BY [NumberValue]
            HAVING COUNT(*) > 1
        )
        BEGIN
            SET @StatusCode = 'INVALID_PARAMETER';
            SET @ErrorMessage = N'@SessionIds ist ungültig oder enthält Duplikate.';
        END
        ELSE
        BEGIN
            INSERT [#CurrentTransactions_SessionFilter]([SessionId])
            SELECT CONVERT(smallint, [NumberValue])
            FROM [monitor].[TVF_ParseBigintList](@SessionIds)
            WHERE [IsValid] = 1;
        END;
    END;

    IF @StatusCode = 'AVAILABLE'
       AND
       (
           COALESCE(@MinAlterSekunden, -1) < 0
           OR @MaxZeilen < 0
           OR @MaxSqlTextZeichen < 0
           OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
           OR @JsonErzeugen IS NULL
       )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Mindestens ein Parameter besitzt einen ungültigen Wert.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN TRY
        IF @ParentCurrentStateSnapshotId IS NOT NULL
        BEGIN
            EXEC [sys].[sp_executesql] N'
                DECLARE @Probe int;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Context] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SessionTransactions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_ActiveTransactions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_DatabaseTransactions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Sessions] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_Requests] WHERE 1=0;
                SELECT @Probe=0 FROM [#CurrentOverview_CurrentStateSnapshot_SqlText] WHERE 1=0;';

            IF NOT EXISTS
            (
                SELECT 1
                FROM [#CurrentOverview_CurrentStateSnapshot_Context]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
                  AND [OwnerSessionId]=CONVERT(smallint,@@SPID)
                  AND [ContractVersion]=2
            )
                THROW 51020,N'Die Parent-Snapshot-ID gehört nicht zum aktuellen Aufruf.',1;

            INSERT [#CurrentTransactions_SourceSessionTransactions]
            SELECT [session_id],[transaction_id]
            FROM [#CurrentOverview_CurrentStateSnapshot_SessionTransactions]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentTransactions_SourceActiveTransactions]
            SELECT [transaction_id],[transaction_begin_time],[transaction_type],[transaction_state]
            FROM [#CurrentOverview_CurrentStateSnapshot_ActiveTransactions]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentTransactions_SourceDatabaseTransactions]
            SELECT
                  [transaction_id],[database_id],[database_transaction_log_bytes_used]
                , [database_transaction_log_bytes_reserved]
            FROM [#CurrentOverview_CurrentStateSnapshot_DatabaseTransactions]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentTransactions_SourceSessions]
            SELECT
                  [session_id],[is_user_process],[status],[open_transaction_count]
                , [login_name],[host_name],[program_name]
            FROM [#CurrentOverview_CurrentStateSnapshot_Sessions]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            INSERT [#CurrentTransactions_SourceRequests]
            SELECT
                  [session_id],[request_id],[status],[database_id],[sql_handle]
                , [statement_start_offset],[statement_end_offset]
            FROM [#CurrentOverview_CurrentStateSnapshot_Requests]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            IF @MitSqlText=1
                INSERT [#CurrentTransactions_SourceSqlText]
                SELECT [SqlHandle],[Text]
                FROM [#CurrentOverview_CurrentStateSnapshot_SqlText]
                WHERE [SnapshotId]=@ParentCurrentStateSnapshotId;

            SELECT
                  @EvidenceSnapshotStartedAtUtc=MIN([CapturedAtUtc])
                , @EvidenceIsPartial=CONVERT(bit,MAX(CONVERT(int,[IsPartial])))
            FROM [#CurrentOverview_CurrentStateSnapshot_SourceStatus]
            WHERE [SnapshotId]=@ParentCurrentStateSnapshotId
              AND [SourceCode] IN
                  ('SESSION_TRANSACTIONS','ACTIVE_TRANSACTIONS','DATABASE_TRANSACTIONS',
                   'SESSIONS','REQUESTS','SQL_TEXT');
        END
        ELSE
        BEGIN
            SET @EvidenceSnapshotStartedAtUtc=SYSUTCDATETIME();
            INSERT [#CurrentTransactions_SourceSessionTransactions]
            SELECT [session_id],[transaction_id]
            FROM [sys].[dm_tran_session_transactions] WITH (NOLOCK);

            INSERT [#CurrentTransactions_SourceActiveTransactions]
            SELECT [transaction_id],[transaction_begin_time],[transaction_type],[transaction_state]
            FROM [sys].[dm_tran_active_transactions] WITH (NOLOCK);

            INSERT [#CurrentTransactions_SourceDatabaseTransactions]
            SELECT
                  [transaction_id],[database_id],[database_transaction_log_bytes_used]
                , [database_transaction_log_bytes_reserved]
            FROM [sys].[dm_tran_database_transactions] WITH (NOLOCK);

            INSERT [#CurrentTransactions_SourceSessions]
            SELECT
                  [session_id],[is_user_process],[status],[open_transaction_count]
                , [login_name],[host_name],[program_name]
            FROM [sys].[dm_exec_sessions] WITH (NOLOCK);

            INSERT [#CurrentTransactions_SourceRequests]
            SELECT
                  [session_id],[request_id],[status],[database_id],[sql_handle]
                , [statement_start_offset],[statement_end_offset]
            FROM [sys].[dm_exec_requests] WITH (NOLOCK);

            IF @MitSqlText=1
                INSERT [#CurrentTransactions_SourceSqlText]
                SELECT [h].[SqlHandle],[t].[text]
                FROM
                (
                    SELECT [sql_handle] AS [SqlHandle]
                    FROM [#CurrentTransactions_SourceRequests]
                    WHERE [sql_handle] IS NOT NULL
                    GROUP BY [sql_handle]
                ) AS [h]
                OUTER APPLY [sys].[dm_exec_sql_text]([h].[SqlHandle]) AS [t];
        END;

        INSERT [#CurrentTransactions_Result]
        (
              [SessionId], [TransactionId], [TransactionBeginTimeUtc]
            , [TransactionAgeSeconds], [TransactionType], [TransactionState]
            , [OpenTransactionCount], [LoginName], [HostName], [ProgramName]
            , [SessionStatus], [RequestStatus], [DatabaseId], [DatabaseName]
            , [LogBytesUsed], [LogBytesReserved]
            , [StatementTextCharacters], [StatementTextBytes], [StatementTextIsTruncated], [StatementText]
        )
        SELECT TOP (@Candidates)
              [st].[session_id]
            , [at].[transaction_id]
            , [at].[transaction_begin_time]
            , DATEDIFF_BIG(SECOND, [at].[transaction_begin_time], GETDATE())
            , [at].[transaction_type]
            , [at].[transaction_state]
            , [s].[open_transaction_count]
            , [s].[login_name]
            , [s].[host_name]
            , [s].[program_name]
            , [s].[status]
            , [r].[status]
            , COALESCE([r].[database_id], [dt].[database_id])
            , [d].[name]
            , [dt].[database_transaction_log_bytes_used]
            , [dt].[database_transaction_log_bytes_reserved]
            , NULL,NULL,CONVERT(bit,0),CASE WHEN @MitSqlText = 1 THEN [statementText].[StatementText] END
        FROM [#CurrentTransactions_SourceSessionTransactions] AS [st]
        INNER JOIN [#CurrentTransactions_SourceActiveTransactions] AS [at]
          ON [at].[transaction_id] = [st].[transaction_id]
        INNER JOIN [#CurrentTransactions_SourceSessions] AS [s]
          ON [s].[session_id] = [st].[session_id]
        LEFT JOIN [#CurrentTransactions_SourceRequests] AS [r]
          ON [r].[session_id] = [st].[session_id]
        LEFT JOIN [#CurrentTransactions_SourceDatabaseTransactions] AS [dt]
          ON [dt].[transaction_id] = [st].[transaction_id]
        LEFT JOIN [master].[sys].[databases] AS [d] WITH (NOLOCK)
          ON [d].[database_id] = COALESCE([r].[database_id], [dt].[database_id])
        LEFT JOIN [#CurrentTransactions_SourceSqlText] AS [sqlText]
          ON [sqlText].[SqlHandle]=CASE WHEN @MitSqlText=1 THEN [r].[sql_handle] END
        OUTER APPLY [monitor].[TVF_StatementText]
        (
              [sqlText].[Text]
            , [r].[statement_start_offset]
            , [r].[statement_end_offset]
        ) AS [statementText]
        WHERE (@SystemSessionsEinbeziehen = 1 OR [s].[is_user_process] = 1)
          AND (@NurSleeping = 0 OR [s].[status] = N'sleeping')
          AND DATEDIFF_BIG(SECOND, [at].[transaction_begin_time], GETDATE()) >= @MinAlterSekunden
          AND
          (
              @SessionIds IS NULL
              OR EXISTS
                 (
                     SELECT 1 FROM [#CurrentTransactions_SessionFilter] AS [f]
                     WHERE [f].[SessionId] = [st].[session_id]
                 )
          )
        ORDER BY
              DATEDIFF_BIG(SECOND, [at].[transaction_begin_time], GETDATE()) DESC
            , [st].[session_id]
            , [at].[transaction_id];

        DECLARE @TruncatedValueCount bigint=0,@LargestRequiredCharacters bigint=NULL;
        EXEC [monitor].[InternalProjectUnicodeTextColumn]
              @SourceTable=N'#CurrentTransactions_Result',@TextColumn=N'StatementText'
            , @CharactersColumn=N'StatementTextCharacters',@BytesColumn=N'StatementTextBytes'
            , @IsTruncatedColumn=N'StatementTextIsTruncated',@MaxCharacters=@MaxSqlTextZeichen
            , @TruncatedValueCount=@TruncatedValueCount OUTPUT,@LargestRequiredCharacters=@LargestRequiredCharacters OUTPUT;
        EXEC [monitor].[InternalEmitTruncationWarning]
              @TruncatedValueCount=@TruncatedValueCount,@ParameterName=N'@MaxSqlTextZeichen'
            , @ParameterValue=@MaxSqlTextZeichen,@LargestRequiredCharacters=@LargestRequiredCharacters
            , @PrintMeldungen=@PrintMeldungen;

        SELECT @RowCount = COUNT_BIG(*) FROM [#CurrentTransactions_Result];
        SET @HasMoreRows = CONVERT(bit, CASE WHEN @Limit < 9223372036854775807 AND @RowCount > @Limit THEN 1 ELSE 0 END);
        IF @EvidenceIsPartial=1 SET @StatusCode='AVAILABLE_LIMITED';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();
        SET @StatusCode = CASE WHEN @ErrorNumber IN (229, 262, 297, 300, 371, 916) THEN 'DENIED_PERMISSION'
                               WHEN @ErrorNumber = 1222 THEN 'TIMEOUT'
                               WHEN @ParentCurrentStateSnapshotId IS NOT NULL
                                AND @ErrorNumber IN (208, 51020) THEN 'INVALID_PARENT_SNAPSHOT'
                               ELSE 'ERROR_HANDLED' END;
        INSERT [#CurrentTransactions_Warnings] VALUES (@StatusCode, @ErrorNumber, @ErrorMessage);
    END CATCH;

    IF @PrintMeldungen = 1 AND @StatusCode <> 'AVAILABLE'
    BEGIN
        SET @Message = FORMATMESSAGE(N'WARNUNG USP_CurrentTransactions [%s]: %s', @StatusCode, COALESCE(@ErrorMessage, N'Unbekannter Fehler.'));
        RAISERROR(N'%s', 10, 1, @Message) WITH NOWAIT;
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT
              N'USP_CurrentTransactions' AS [ModuleName]
            , @Now AS [CollectionTimeUtc]
            , @EvidenceSnapshotStartedAtUtc AS [EvidenceSnapshotStartedAtUtc]
            , @EvidenceSnapshotId AS [EvidenceSnapshotId]
            , @StatusCode AS [StatusCode]
            , CONVERT(bit, CASE WHEN @StatusCode = 'AVAILABLE' THEN 0 ELSE 1 END) AS [IsPartial]
            , CASE WHEN @RowCount > @Limit THEN @Limit ELSE @RowCount END AS [ReturnedRowCount]
            , @HasMoreRows AS [HasMoreRows]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT TOP (@Limit) *
            FROM [#CurrentTransactions_Result]
            ORDER BY [TransactionAgeSeconds] DESC, [SessionId], [TransactionId];
        END
        ELSE
        BEGIN
            SELECT TOP (@Limit)
                  N'Aktive Transaktion' AS [Ergebnis]
                , [SessionId] AS [Session]
                , [TransactionId] AS [Transaktion]
                , [DatabaseName] AS [Datenbank]
                , [LoginName] AS [Login]
                , [HostName] AS [Host]
                , [ProgramName] AS [Programm]
                , [SessionStatus] AS [Session-Status]
                , [RequestStatus] AS [Request-Status]
                , CONCAT(CONVERT(varchar(30), [TransactionAgeSeconds]), N' s') AS [Alter]
                , CONVERT(decimal(19, 2), [LogBytesUsed] / 1048576.0) AS [Log verwendet MB]
                , CONVERT(decimal(19, 2), [LogBytesReserved] / 1048576.0) AS [Log reserviert MB]
                , [SessionId] AS [Session_SQL]
                , [StatementText] AS [SQL-Text]
            FROM [#CurrentTransactions_Result]
            ORDER BY [TransactionAgeSeconds] DESC, [SessionId], [TransactionId];
        END;

        SELECT * FROM [#CurrentTransactions_Warnings] ORDER BY [StatusCode];
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @Meta nvarchar(max) =
        (
            SELECT
                  N'CurrentTransactions' AS [resultName]
                , 2 AS [schemaVersion]
                , @Now AS [generatedAtUtc]
                , @EvidenceSnapshotStartedAtUtc AS [evidenceSnapshotStartedAtUtc]
                , @EvidenceSnapshotId AS [evidenceSnapshotId]
                , @StatusCode AS [statusCode]
                , CONVERT(bit,CASE WHEN @StatusCode='AVAILABLE' THEN 0 ELSE 1 END) AS [isPartial]
                , @MaxZeilen AS [requestedMaxRows]
                , CASE WHEN @RowCount > @Limit THEN @Limit ELSE @RowCount END AS [returnedRows]
                , @HasMoreRows AS [hasMoreRows]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @Data nvarchar(max) =
        (
            SELECT TOP (@Limit) *
            FROM [#CurrentTransactions_Result]
            ORDER BY [TransactionAgeSeconds] DESC, [SessionId], [TransactionId]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        DECLARE @Warnings nvarchar(max) =
        (
            SELECT * FROM [#CurrentTransactions_Warnings] ORDER BY [StatusCode]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        SET @Json = CONCAT(N'{"meta":', COALESCE(@Meta, N'{}'), N',"transactions":', COALESCE(@Data, N'[]'), N',"warnings":', COALESCE(@Warnings, N'[]'), N'}');
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CurrentTransactions_Result'
            , @ResultLabel=N'Aktuelle Transaktionen'
            , @EmptyMessage=N'Keine aktiven Transaktionen';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#CurrentTransactions_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
