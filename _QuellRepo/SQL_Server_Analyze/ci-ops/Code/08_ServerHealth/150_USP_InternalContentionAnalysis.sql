USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_InternalContentionAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Zweck        : Misst Latch-/Spinlock-Deltas und aktuelle Hot-Page-Wartevorgänge.
Datenquellen : sys.dm_os_latch_stats, sys.dm_os_spinlock_stats,
               sys.dm_exec_requests, sys.dm_os_sys_info und optional
               sys.dm_db_page_info.
Methodik     : @SampleSeconds>0 liefert ein Intervall-Delta. Bei 0 werden
               kumulative Werte seit SQL-Server-Start eindeutig gekennzeichnet.
Grenzen      : Korrelation ist Evidenz, keine automatische Ursachenfeststellung.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_InternalContentionAnalysis]
      @SampleSeconds     tinyint        = 5
    , @MitSpinlocks      bit            = 1
    , @MitHotPages       bit            = 1
    , @MitPageDetails    bit            = 0
    , @MaxZeilen         int            = 100
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
    , @StatusCodeOut     varchar(40)    = NULL OUTPUT
    , @IsPartialOut      bit            = NULL OUTPUT
    , @ErrorNumberOut    int            = NULL OUTPUT
    , @ErrorMessageOut   nvarchar(2048) = NULL OUTPUT
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'latches',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
                                 THEN CONVERT(bigint, 9223372036854775807)
                                 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_InternalContentionAnalysis';
        PRINT N'@SampleSeconds=0..60; 0 zeigt kumulative Werte, >0 misst Deltas.';
        PRINT N'@MitPageDetails=1 löst ausschließlich aktuell wartende Seiten über sys.dm_db_page_info auf.';
        PRINT N'@MaxZeilen positiv; NULL/0 = unbegrenzt. @ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @SampleStartUtc datetime2(3) = @Now;
    DECLARE @SampleEndUtc datetime2(3) = @Now;
    DECLARE @SqlServerStartTime datetime2(3) = NULL;
    DECLARE @ActualSampleSeconds decimal(19,6) = 0;
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @Delay varchar(8);

    CREATE TABLE [#InternalContentionAnalysis_LatchStart]
    (
          [LatchClass] nvarchar(120) NOT NULL
        , [WaitingRequestsCount] bigint NOT NULL
        , [WaitTimeMs] bigint NOT NULL
        , [MaxWaitTimeMs] bigint NOT NULL
    );
    CREATE TABLE [#InternalContentionAnalysis_LatchEnd]
    (
          [LatchClass] nvarchar(120) NOT NULL
        , [WaitingRequestsCount] bigint NOT NULL
        , [WaitTimeMs] bigint NOT NULL
        , [MaxWaitTimeMs] bigint NOT NULL
    );
    CREATE TABLE [#InternalContentionAnalysis_SpinStart]
    (
          [SpinlockName] nvarchar(256) NOT NULL
        , [Collisions] bigint NOT NULL
        , [Spins] bigint NOT NULL
        , [SleepTime] bigint NOT NULL
        , [Backoffs] bigint NOT NULL
    );
    CREATE TABLE [#InternalContentionAnalysis_SpinEnd]
    (
          [SpinlockName] nvarchar(256) NOT NULL
        , [Collisions] bigint NOT NULL
        , [Spins] bigint NOT NULL
        , [SleepTime] bigint NOT NULL
        , [Backoffs] bigint NOT NULL
    );
    CREATE TABLE [#InternalContentionAnalysis_LatchResult]
    (
          [LatchClass] nvarchar(120) NOT NULL
        , [MeasurementKind] varchar(30) NOT NULL
        , [WaitingRequests] bigint NULL
        , [WaitTimeMs] bigint NULL
        , [MaxObservedWaitTimeMs] bigint NULL
        , [WaitsPerSecond] decimal(19,4) NULL
        , [WaitMsPerSecond] decimal(19,4) NULL
        , [CounterResetDetected] bit NOT NULL
    );
    CREATE TABLE [#InternalContentionAnalysis_SpinResult]
    (
          [SpinlockName] nvarchar(256) NOT NULL
        , [MeasurementKind] varchar(30) NOT NULL
        , [Collisions] bigint NULL
        , [Spins] bigint NULL
        , [SleepTime] bigint NULL
        , [Backoffs] bigint NULL
        , [CollisionsPerSecond] decimal(19,4) NULL
        , [BackoffsPerSecond] decimal(19,4) NULL
        , [CounterResetDetected] bit NOT NULL
    );
    CREATE TABLE [#InternalContentionAnalysis_HotPages]
    (
          [SessionId] smallint NOT NULL
        , [DatabaseId] int NULL
        , [DatabaseName] sysname NULL
        , [WaitType] nvarchar(60) NULL
        , [WaitTimeMs] int NULL
        , [WaitResource] nvarchar(256) NULL
        , [FileId] int NULL
        , [PageId] bigint NULL
        , [PageTypeDesc] nvarchar(64) NULL
        , [ObjectId] int NULL
        , [IndexId] int NULL
    );

    IF @SampleSeconds > 60
       OR @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR (@MitPageDetails = 1 AND @MitHotPages = 0)
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Sample-, Zeilen-, Detail- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        BEGIN TRY
            SELECT @SqlServerStartTime = [sqlserver_start_time]
            FROM [sys].[dm_os_sys_info] WITH (NOLOCK);

            INSERT [#InternalContentionAnalysis_LatchStart]
            SELECT [latch_class], [waiting_requests_count], [wait_time_ms], [max_wait_time_ms]
            FROM [sys].[dm_os_latch_stats] WITH (NOLOCK);

            IF @MitSpinlocks = 1
            BEGIN
                INSERT [#InternalContentionAnalysis_SpinStart]
                SELECT [name], [collisions], [spins], [sleep_time], [backoffs]
                FROM [sys].[dm_os_spinlock_stats] WITH (NOLOCK);
            END;

            SET @SampleStartUtc = SYSUTCDATETIME();
            IF @SampleSeconds > 0
            BEGIN
                SET @Delay = CONVERT(varchar(8),
                    DATEADD(SECOND,@SampleSeconds,CONVERT(datetime,'19000101')),108);
                WAITFOR DELAY @Delay;
            END;
            SET @SampleEndUtc = SYSUTCDATETIME();
            SET @ActualSampleSeconds = CONVERT
            (
                decimal(19,6),
                DATEDIFF_BIG(MICROSECOND, @SampleStartUtc, @SampleEndUtc) / 1000000.0
            );

            INSERT [#InternalContentionAnalysis_LatchEnd]
            SELECT [latch_class], [waiting_requests_count], [wait_time_ms], [max_wait_time_ms]
            FROM [sys].[dm_os_latch_stats] WITH (NOLOCK);

            IF @MitSpinlocks = 1
            BEGIN
                INSERT [#InternalContentionAnalysis_SpinEnd]
                SELECT [name], [collisions], [spins], [sleep_time], [backoffs]
                FROM [sys].[dm_os_spinlock_stats] WITH (NOLOCK);
            END;

            ;WITH [LatchStart] AS
            (
                SELECT [LatchClass],SUM([WaitingRequestsCount]) AS [WaitingRequestsCount],
                       SUM([WaitTimeMs]) AS [WaitTimeMs],MAX([MaxWaitTimeMs]) AS [MaxWaitTimeMs]
                FROM [#InternalContentionAnalysis_LatchStart] GROUP BY [LatchClass]
            ),
            [LatchEnd] AS
            (
                SELECT [LatchClass],SUM([WaitingRequestsCount]) AS [WaitingRequestsCount],
                       SUM([WaitTimeMs]) AS [WaitTimeMs],MAX([MaxWaitTimeMs]) AS [MaxWaitTimeMs]
                FROM [#InternalContentionAnalysis_LatchEnd] GROUP BY [LatchClass]
            )
            INSERT [#InternalContentionAnalysis_LatchResult]
            SELECT
                  [e].[LatchClass]
                , CASE WHEN @SampleSeconds = 0 THEN 'CUMULATIVE_SINCE_START' ELSE 'SAMPLE_DELTA' END
                , [Waiting].[CounterValue]
                , [WaitTime].[CounterValue]
                , [e].[MaxWaitTimeMs]
                , [Waiting].[RatePerSecond]
                , [WaitTime].[RatePerSecond]
                , CONVERT(bit,CASE WHEN [Waiting].[CounterResetDetected]=1
                                      OR [WaitTime].[CounterResetDetected]=1 THEN 1 ELSE 0 END)
            FROM [LatchEnd] AS [e]
            JOIN [LatchStart] AS [s] ON [s].[LatchClass] = [e].[LatchClass]
            CROSS APPLY [monitor].[TVF_InterpretContentionCounter]
            ([s].[WaitingRequestsCount],[e].[WaitingRequestsCount],@SampleSeconds,@ActualSampleSeconds) AS [Waiting]
            CROSS APPLY [monitor].[TVF_InterpretContentionCounter]
            ([s].[WaitTimeMs],[e].[WaitTimeMs],@SampleSeconds,@ActualSampleSeconds) AS [WaitTime]
            WHERE (@SampleSeconds = 0 AND [e].[WaitTimeMs] > 0)
               OR (@SampleSeconds > 0 AND ([e].[WaitTimeMs] <> [s].[WaitTimeMs]
                                           OR [e].[WaitingRequestsCount] <> [s].[WaitingRequestsCount]));

            IF @MitSpinlocks = 1
            BEGIN
                ;WITH [SpinStart] AS
                (
                    SELECT [SpinlockName],SUM([Collisions]) AS [Collisions],SUM([Spins]) AS [Spins],
                           SUM([SleepTime]) AS [SleepTime],SUM([Backoffs]) AS [Backoffs]
                    FROM [#InternalContentionAnalysis_SpinStart] GROUP BY [SpinlockName]
                ),
                [SpinEnd] AS
                (
                    SELECT [SpinlockName],SUM([Collisions]) AS [Collisions],SUM([Spins]) AS [Spins],
                           SUM([SleepTime]) AS [SleepTime],SUM([Backoffs]) AS [Backoffs]
                    FROM [#InternalContentionAnalysis_SpinEnd] GROUP BY [SpinlockName]
                )
                INSERT [#InternalContentionAnalysis_SpinResult]
                SELECT
                      [e].[SpinlockName]
                    , CASE WHEN @SampleSeconds = 0 THEN 'CUMULATIVE_SINCE_START' ELSE 'SAMPLE_DELTA' END
                    , [Collision].[CounterValue]
                    , [Spin].[CounterValue]
                    , [Sleep].[CounterValue]
                    , [Backoff].[CounterValue]
                    , [Collision].[RatePerSecond]
                    , [Backoff].[RatePerSecond]
                    , CONVERT(bit,CASE WHEN [Collision].[CounterResetDetected]=1
                                           OR [Spin].[CounterResetDetected]=1
                                           OR [Sleep].[CounterResetDetected]=1
                                           OR [Backoff].[CounterResetDetected]=1 THEN 1 ELSE 0 END)
                FROM [SpinEnd] AS [e]
                JOIN [SpinStart] AS [s] ON [s].[SpinlockName] = [e].[SpinlockName]
                CROSS APPLY [monitor].[TVF_InterpretContentionCounter]
                ([s].[Collisions],[e].[Collisions],@SampleSeconds,@ActualSampleSeconds) AS [Collision]
                CROSS APPLY [monitor].[TVF_InterpretContentionCounter]
                ([s].[Spins],[e].[Spins],@SampleSeconds,@ActualSampleSeconds) AS [Spin]
                CROSS APPLY [monitor].[TVF_InterpretContentionCounter]
                ([s].[SleepTime],[e].[SleepTime],@SampleSeconds,@ActualSampleSeconds) AS [Sleep]
                CROSS APPLY [monitor].[TVF_InterpretContentionCounter]
                ([s].[Backoffs],[e].[Backoffs],@SampleSeconds,@ActualSampleSeconds) AS [Backoff]
                WHERE (@SampleSeconds = 0 AND [e].[Collisions] > 0)
                   OR (@SampleSeconds > 0 AND ([e].[Collisions] <> [s].[Collisions]
                                               OR [e].[Spins] <> [s].[Spins]
                                               OR [e].[SleepTime] <> [s].[SleepTime]
                                               OR [e].[Backoffs] <> [s].[Backoffs]));
            END;

            IF @MitHotPages = 1
            BEGIN
                INSERT [#InternalContentionAnalysis_HotPages]
                (
                      [SessionId], [DatabaseId], [DatabaseName], [WaitType]
                    , [WaitTimeMs], [WaitResource], [FileId], [PageId]
                )
                SELECT
                      [r].[session_id], [r].[database_id], (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = [r].[database_id])
                    , [r].[wait_type], [r].[wait_time], [r].[wait_resource]
                    , TRY_CONVERT(int, PARSENAME(REPLACE([r].[wait_resource], N':', N'.'), 2))
                    , TRY_CONVERT(bigint, PARSENAME(REPLACE([r].[wait_resource], N':', N'.'), 1))
                FROM [sys].[dm_exec_requests] AS [r] WITH (NOLOCK)
                WHERE [r].[session_id] <> @@SPID
                  AND ([r].[wait_type] LIKE N'PAGELATCH%'
                       OR [r].[wait_type] LIKE N'PAGEIOLATCH%');

                IF @MitPageDetails = 1
                BEGIN
                    UPDATE [h]
                    SET [PageTypeDesc] = [p].[page_type_desc],
                        [ObjectId] = [p].[object_id],
                        [IndexId] = [p].[index_id]
                    FROM [#InternalContentionAnalysis_HotPages] AS [h]
                    OUTER APPLY [sys].[dm_db_page_info]
                    ([h].[DatabaseId], [h].[FileId], [h].[PageId], 'LIMITED') AS [p]
                    WHERE [h].[DatabaseId] IS NOT NULL
                      AND [h].[FileId] IS NOT NULL
                      AND [h].[PageId] IS NOT NULL;
                END;
            END;
        END TRY
        BEGIN CATCH
            SELECT @StatusCode = CASE WHEN ERROR_NUMBER() IN (229, 297, 300, 371)
                                      THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                   @IsPartial = 1, @ErrorNumber = ERROR_NUMBER(),
                   @ErrorMessage = ERROR_MESSAGE();
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE'
       AND EXISTS
           (
               SELECT 1 FROM [#InternalContentionAnalysis_LatchResult] WHERE [CounterResetDetected] = 1
               UNION ALL
               SELECT 1 FROM [#InternalContentionAnalysis_SpinResult] WHERE [CounterResetDetected] = 1
               UNION ALL
               SELECT 1 FROM [#InternalContentionAnalysis_HotPages]
           )
        SET @StatusCode = 'AVAILABLE_WITH_FINDING';

    SELECT @StatusCodeOut = @StatusCode, @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber, @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
            (SELECT N'InternalContentionAnalysis' AS [resultName], 1 AS [schemaVersion],
                    @Now AS [generatedAtUtc], @StatusCode AS [statusCode], @IsPartial AS [isPartial],
                    @SampleSeconds AS [requestedSampleSeconds], @ActualSampleSeconds AS [actualSampleSeconds],
                    @SqlServerStartTime AS [sqlServerStartTime]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
        DECLARE @LatchJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#InternalContentionAnalysis_LatchResult]
             ORDER BY [WaitTimeMs] DESC, [LatchClass] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @SpinJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#InternalContentionAnalysis_SpinResult]
             ORDER BY [Collisions] DESC, [SpinlockName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @HotJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#InternalContentionAnalysis_HotPages]
             ORDER BY [WaitTimeMs] DESC, [SessionId] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'),
                           N',"latches":', COALESCE(@LatchJson, N'[]'),
                           N',"spinlocks":', COALESCE(@SpinJson, N'[]'),
                           N',"hotPages":', COALESCE(@HotJson, N'[]'), N'}');
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_InternalContentionAnalysis' AS [ModuleName], @Now AS [CollectionTimeUtc],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @SampleSeconds AS [RequestedSampleSeconds], @ActualSampleSeconds AS [ActualSampleSeconds],
               @SqlServerStartTime AS [SqlServerStartTime],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'Intervalldeltas bei SampleSeconds>0; sonst kumulativ seit Serverstart.' AS [Detail];
        SELECT TOP (@Limit) * FROM [#InternalContentionAnalysis_LatchResult] ORDER BY [WaitTimeMs] DESC, [LatchClass];
        SELECT TOP (@Limit) * FROM [#InternalContentionAnalysis_SpinResult] ORDER BY [Collisions] DESC, [SpinlockName];
        SELECT TOP (@Limit) * FROM [#InternalContentionAnalysis_HotPages] ORDER BY [WaitTimeMs] DESC, [SessionId];
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Interne Contention' AS [Ergebnis], @Now AS [Stand_UTC], @StatusCode AS [Status],
               @SampleSeconds AS [Angeforderte_Messdauer_Sekunden],
               @ActualSampleSeconds AS [Tatsaechliche_Messdauer_Sekunden],
               CASE WHEN @SampleSeconds = 0 THEN N'Kumulativ seit Serverstart' ELSE N'Intervall-Delta' END AS [Messart],
               @ErrorMessage AS [Hinweis];
        SELECT TOP (@Limit) N'Latch' AS [Ergebnis], [LatchClass] AS [Klasse],
               [WaitingRequests] AS [Wartevorgaenge], [WaitTimeMs] AS [Wartezeit_ms],
               [WaitsPerSecond] AS [Wartevorgaenge_pro_s], [WaitMsPerSecond] AS [Wartezeit_ms_pro_s],
               [CounterResetDetected] AS [Reset_erkannt]
        FROM [#InternalContentionAnalysis_LatchResult] ORDER BY [WaitTimeMs] DESC, [LatchClass];
        SELECT TOP (@Limit) N'Spinlock' AS [Ergebnis], [SpinlockName] AS [Name],
               [Collisions], [Backoffs], [CollisionsPerSecond] AS [Kollisionen_pro_s],
               [BackoffsPerSecond] AS [Backoffs_pro_s], [CounterResetDetected] AS [Reset_erkannt]
        FROM [#InternalContentionAnalysis_SpinResult] ORDER BY [Collisions] DESC, [SpinlockName];
        SELECT TOP (@Limit) N'Hot Page' AS [Ergebnis], [SessionId] AS [Session_ID],
               [DatabaseName] AS [Datenbank], [WaitType] AS [Wait_Typ], [WaitTimeMs] AS [Wartezeit_ms],
               [FileId] AS [Datei_ID], [PageId] AS [Seiten_ID], [PageTypeDesc] AS [Seitentyp],
               [ObjectId] AS [Objekt_ID], [IndexId] AS [Index_ID]
        FROM [#InternalContentionAnalysis_HotPages] ORDER BY [WaitTimeMs] DESC, [SessionId];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#InternalContentionAnalysis_LatchResult'
            , @ResultLabel=N'InternalContentionAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#InternalContentionAnalysis_LatchResult'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
