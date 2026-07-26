USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_PerformanceCounters
Version      : 1.1.0
Stand        : 2026-07-18
Zweck        : Typisiert SQL-Server-Performance-Counter als Snapshot, Rate,
               Fraction oder nicht automatisch interpretierbaren Rohwert.
Datenquellen : sys.dm_os_performance_counters, sys.dm_os_sys_info.
Grenzen      : Universelle Alarmgrenzen werden nicht behauptet. Rate-Counter
               benötigen ein Sample; Counterreset wird als solcher markiert.
Nebenwirkung : Optionales WAITFOR für 1 bis 60 Sekunden; keine Persistenz.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_PerformanceCounters]
      @ObjectNames       nvarchar(max)  = NULL
    , @CounterNames      nvarchar(max)  = NULL
    , @SampleSeconds     tinyint         = 0
    , @MaxZeilen         int             = 1000
    , @ResultSetArt      varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen      bit             = 0
    , @Json              nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen    bit             = 1
    , @Hilfe             bit             = 0
    , @StatusCodeOut     varchar(40)     = NULL OUTPUT
    , @IsPartialOut      bit             = NULL OUTPUT
    , @ErrorNumberOut    int             = NULL OUTPUT
    , @ErrorMessageOut   nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) =
        UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'counters',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_PerformanceCounters';
        PRINT N'@ObjectNames und @CounterNames: optionale bracket-aware Pipe-Listen mit exakten Namen.';
        PRINT N'@SampleSeconds=0 liefert Roh-Snapshots; 1..60 berechnet unterstützte Raten und Quotienten aus Deltas.';
        PRINT N'Countertyp, Basiswert, Samplezeit und SQL-Startzeit werden immer mitgeführt.';
        PRINT N'Nicht unterstützte cntr_type-Werte werden als RAW_UNINTERPRETED gekennzeichnet.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @SampleStartUtc datetime2(7) = SYSUTCDATETIME();
    DECLARE @SampleEndUtc datetime2(7);
    DECLARE @SqlServerStartTime datetime2(3);
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @MonitorPrintMessage nvarchar(2048) = NULL;
    DECLARE @Delay char(8);

    CREATE TABLE [#PerformanceCounters_Before]
    (
          [ObjectName] nvarchar(128) NOT NULL
        , [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterValue] bigint NOT NULL
        , [CounterType] int NOT NULL
        , PRIMARY KEY ([ObjectName], [CounterName], [InstanceName], [CounterType])
    );

    CREATE TABLE [#PerformanceCounters_After]
    (
          [ObjectName] nvarchar(128) NOT NULL
        , [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterValue] bigint NOT NULL
        , [CounterType] int NOT NULL
        , PRIMARY KEY ([ObjectName], [CounterName], [InstanceName], [CounterType])
    );

    CREATE TABLE [#PerformanceCounters_Result]
    (
          [ObjectName] nvarchar(128) NOT NULL
        , [CounterName] nvarchar(128) NOT NULL
        , [InstanceName] nvarchar(128) NOT NULL
        , [CounterType] int NOT NULL
        , [Interpretation] varchar(40) NOT NULL
        , [MetricValue] decimal(38,6) NULL
        , [MetricUnit] varchar(40) NOT NULL
        , [BeforeValue] bigint NULL
        , [AfterValue] bigint NOT NULL
        , [BaseBeforeValue] bigint NULL
        , [BaseAfterValue] bigint NULL
        , [DeltaValue] bigint NULL
        , [BaseDeltaValue] bigint NULL
        , [SampleSeconds] decimal(19,6) NULL
        , [SqlServerStartTime] datetime2(3) NULL
        , [FindingCode] varchar(80) NOT NULL
    );

    IF @MaxZeilen < 0
       OR @SampleSeconds > 60
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR (@ObjectNames IS NOT NULL AND EXISTS
          (SELECT 1 FROM [monitor].[TVF_ParseStringList](@ObjectNames) WHERE [IsValid] = 0))
       OR (@CounterNames IS NOT NULL AND EXISTS
          (SELECT 1 FROM [monitor].[TVF_ParseStringList](@CounterNames) WHERE [IsValid] = 0))
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER',
               @IsPartial = 1,
               @ErrorMessage = N'Ungültige Listen-, Sample-, Zeilen- oder Ausgabeparameter.';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN TRY
        SELECT @SqlServerStartTime = TRY_CONVERT(datetime2(3), [sqlserver_start_time])
        FROM [sys].[dm_os_sys_info] WITH (NOLOCK);

        INSERT [#PerformanceCounters_Before]
        SELECT DISTINCT RTRIM([object_name]), RTRIM([counter_name]), RTRIM([instance_name]), [cntr_value], [cntr_type]
        FROM [sys].[dm_os_performance_counters] WITH (NOLOCK)
        WHERE
            (@ObjectNames IS NULL OR EXISTS
             (
                 SELECT 1
                 FROM [monitor].[TVF_ParseStringList](@ObjectNames) AS [o]
                 WHERE [o].[IsValid] = 1
                   AND [o].[StringValue] COLLATE SQL_Latin1_General_CP1_CS_AS
                     = [object_name] COLLATE SQL_Latin1_General_CP1_CS_AS
             ))
        AND (@CounterNames IS NULL OR EXISTS
             (
                 SELECT 1
                 FROM [monitor].[TVF_ParseStringList](@CounterNames) AS [n]
                 WHERE [n].[IsValid] = 1
                   AND [n].[StringValue] COLLATE SQL_Latin1_General_CP1_CS_AS
                     = [counter_name] COLLATE SQL_Latin1_General_CP1_CS_AS
             )
             OR EXISTS
             (
                 SELECT 1
                 FROM [monitor].[TVF_ParseStringList](@CounterNames) AS [n]
                 WHERE [n].[IsValid] = 1
                   AND CONCAT([n].[StringValue], N' base') COLLATE SQL_Latin1_General_CP1_CI_AS
                     = RTRIM([counter_name]) COLLATE SQL_Latin1_General_CP1_CI_AS
             ));

        IF NOT EXISTS (SELECT 1 FROM [#PerformanceCounters_Before])
        BEGIN
            SELECT @StatusCode = 'UNAVAILABLE_OBJECT',
                   @IsPartial = 1,
                   @ErrorMessage = N'sys.dm_os_performance_counters liefert keine aktivierten Counter.';
        END;

        IF @SampleSeconds > 0
        BEGIN
            SET @Delay = CONVERT(char(8),
                DATEADD(SECOND, @SampleSeconds, CONVERT(time(0), '00:00:00')), 108);
            WAITFOR DELAY @Delay;
        END;

        SET @SampleEndUtc = SYSUTCDATETIME();

        INSERT [#PerformanceCounters_After]
        SELECT DISTINCT RTRIM([p].[object_name]), RTRIM([p].[counter_name]), RTRIM([p].[instance_name]),
               [p].[cntr_value], [p].[cntr_type]
        FROM [sys].[dm_os_performance_counters] AS [p] WITH (NOLOCK)
        JOIN [#PerformanceCounters_Before] AS [b]
         ON [b].[ObjectName] = [p].[object_name]
         AND [b].[CounterName] = [p].[counter_name]
         AND [b].[InstanceName] = [p].[instance_name]
         AND [b].[CounterType] = [p].[cntr_type];

        INSERT [#PerformanceCounters_Result]
        SELECT
              [a].[ObjectName]
            , [a].[CounterName]
            , [a].[InstanceName]
            , [a].[CounterType]
            , [i].[Interpretation]
            , [i].[MetricValue]
            , [i].[MetricUnit]
            , [b].[CounterValue]
            , [a].[CounterValue]
            , [baseBefore].[CounterValue]
            , [baseAfter].[CounterValue]
            , TRY_CONVERT(bigint, CONVERT(decimal(38,0), [a].[CounterValue])
                                 - CONVERT(decimal(38,0), [b].[CounterValue]))
            , TRY_CONVERT(bigint, CONVERT(decimal(38,0), [baseAfter].[CounterValue])
                                 - CONVERT(decimal(38,0), [baseBefore].[CounterValue]))
            , CONVERT(decimal(19,6),
                DATEDIFF_BIG(MICROSECOND, @SampleStartUtc, @SampleEndUtc) / 1000000.0)
            , @SqlServerStartTime
            , [i].[FindingCode]
        FROM [#PerformanceCounters_After] AS [a]
        JOIN [#PerformanceCounters_Before] AS [b]
         ON [b].[ObjectName] = [a].[ObjectName]
         AND [b].[CounterName] = [a].[CounterName]
         AND [b].[InstanceName] = [a].[InstanceName]
         AND [b].[CounterType] = [a].[CounterType]
        LEFT JOIN [#PerformanceCounters_Before] AS [baseBefore]
          ON [baseBefore].[ObjectName] = [a].[ObjectName]
         AND [baseBefore].[InstanceName] = [a].[InstanceName]
         AND [baseBefore].[CounterName] COLLATE SQL_Latin1_General_CP1_CI_AS =
             CONVERT(nvarchar(128), CONCAT(RTRIM([a].[CounterName]), N' base'))
             COLLATE SQL_Latin1_General_CP1_CI_AS
         AND [baseBefore].[CounterType] IN (1073939458, 1073939712)
        LEFT JOIN [#PerformanceCounters_After] AS [baseAfter]
          ON [baseAfter].[ObjectName] = [a].[ObjectName]
         AND [baseAfter].[InstanceName] = [a].[InstanceName]
         AND [baseAfter].[CounterName] COLLATE SQL_Latin1_General_CP1_CI_AS =
             CONVERT(nvarchar(128), CONCAT(RTRIM([a].[CounterName]), N' base'))
             COLLATE SQL_Latin1_General_CP1_CI_AS
         AND [baseAfter].[CounterType] IN (1073939458, 1073939712)
        CROSS APPLY [monitor].[TVF_InterpretPerformanceCounter]
        (
              [a].[CounterType]
            , [b].[CounterValue]
            , [a].[CounterValue]
            , [baseBefore].[CounterValue]
            , [baseAfter].[CounterValue]
            , CASE WHEN @SampleSeconds = 0 THEN CONVERT(decimal(19,6), 0)
                   ELSE CONVERT(decimal(19,6),
                        DATEDIFF_BIG(MICROSECOND, @SampleStartUtc, @SampleEndUtc) / 1000000.0) END
        ) AS [i]
        WHERE [a].[CounterType] NOT IN (1073939458, 1073939712);

        IF NOT EXISTS (SELECT 1 FROM [#PerformanceCounters_Result])
        BEGIN
            SELECT @StatusCode = 'UNAVAILABLE_OBJECT',
                   @IsPartial = 1,
                   @ErrorMessage = N'Es stehen keine auswertbaren Performance-Counter-Zeilen bereit.';
        END;
    END TRY
    BEGIN CATCH
        SELECT @StatusCode =
                   CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371)
                        THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
               @IsPartial = 1,
               @ErrorNumber = ERROR_NUMBER(),
               @ErrorMessage = ERROR_MESSAGE();
    END CATCH;

    SELECT @StatusCodeOut = @StatusCode,
           @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber,
           @ErrorMessageOut = @ErrorMessage;

    IF @PrintMeldungen = 1 AND @StatusCode <> 'AVAILABLE'
    BEGIN
        SET @MonitorPrintMessage = COALESCE(@ErrorMessage, CONVERT(nvarchar(2048), @StatusCode));
        RAISERROR(N'USP_PerformanceCounters: %s', 10, 1, @MonitorPrintMessage) WITH NOWAIT;
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT CAST('1.0' AS varchar(16)) AS [ContractVersion], @Now AS [CollectionTimeUtc],
               N'monitor.USP_PerformanceCounters' AS [ModuleName],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               @SampleStartUtc AS [SampleStartUtc], @SampleEndUtc AS [SampleEndUtc],
               @SqlServerStartTime AS [SqlServerStartTime];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT TOP (@Limit) *
            FROM [#PerformanceCounters_Result]
            ORDER BY [ObjectName], [CounterName], [InstanceName];
        END
        ELSE
        BEGIN
            SELECT TOP (@Limit)
                  N'Performance Counter' AS [Ergebnis]
                , [ObjectName] AS [Objekt]
                , [CounterName] AS [Counter]
                , [InstanceName] AS [Instanz]
                , [MetricValue] AS [Wert]
                , [MetricUnit] AS [Einheit]
                , [Interpretation] AS [Interpretation]
                , [CounterType] AS [Countertyp]
                , [FindingCode] AS [Bewertung]
                , [SampleSeconds] AS [Sample Sekunden]
            FROM [#PerformanceCounters_Result]
            ORDER BY [ObjectName], [CounterName], [InstanceName];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT N'PerformanceCounters' AS [resultName], 1 AS [schemaVersion],
                   @Now AS [generatedAtUtc], @StatusCode AS [statusCode],
                   @IsPartial AS [isPartial], @SampleStartUtc AS [sampleStartUtc],
                   @SampleEndUtc AS [sampleEndUtc], @SqlServerStartTime AS [sqlServerStartTime],
                   @ErrorNumber AS [errorNumber], @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @CountersJson nvarchar(max) =
        (
            SELECT TOP (@Limit) *
            FROM [#PerformanceCounters_Result]
            ORDER BY [ObjectName], [CounterName], [InstanceName]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );
        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"counters":', COALESCE(@CountersJson, N'[]')
            , N',"warnings":[]}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#PerformanceCounters_Result'
            , @ResultLabel=N'PerformanceCounters'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#PerformanceCounters_Result'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
