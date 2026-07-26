USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ExtendedEventsAnalysis
Version      : 2.0.1
Stand        : 2026-07-16
Zweck        : Orchestriert Extended-Events-Inventar und Forensik mit
               einheitlichem Ausgabe- und Namensvertrag.
Änderungen   : 2.0.1 - IF/TRY/CATCH-Blöcke syntaktisch eindeutig strukturiert.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ExtendedEventsAnalysis]
      @SourceExtendedEventSessionName nvarchar(258)  = N'system_health'
    , @ExtendedEventSessionNames       nvarchar(max)  = NULL
    , @ExtendedEventSessionNamePattern nvarchar(4000) = NULL
    , @EventNames                      nvarchar(max)  = NULL
    , @EventNamePattern                nvarchar(4000) = NULL
    , @TargetNames                     nvarchar(max)  = NULL
    , @TargetNamePattern               nvarchar(4000) = NULL
    , @Quelle                          varchar(20)    = 'AUTO'
    , @FilePath                        nvarchar(4000) = NULL
    , @VonUtc                          datetime2(7)   = NULL
    , @BisUtc                          datetime2(7)   = NULL
    , @MitSessionInventar              bit            = 1
    , @MitTargetRuntime                bit            = 0
    , @MitEvents                       bit            = 0
    , @MitDeadlocks                    bit            = 0
    , @MitBlockedProcesses             bit            = 0
    , @MaxZeilen                       int            = 100
    , @BestaetigeTargetFlush           bit            = 0
    , @HighImpactConfirmed             bit            = 0
    , @ResultSetArt                    varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                    bit            = 0
    , @Json                            nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                  bit            = 1
    , @Hilfe                           bit            = 0
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'moduleStatus',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Source varchar(20) = UPPER(LTRIM(RTRIM(COALESCE(@Quelle, ''))));
    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @InventoryJson nvarchar(max);
    DECLARE @TargetJson nvarchar(max);
    DECLARE @EventsJson nvarchar(max);
    DECLARE @DeadlocksJson nvarchar(max);
    DECLARE @BlockedJson nvarchar(max);

    DECLARE @ModuleStatus TABLE
    (
          [ExecutionOrdinal] tinyint        NOT NULL
        , [ModuleName]       sysname        NOT NULL
        , [InvocationStatus] varchar(40)    NOT NULL
        , [ErrorNumber]      int            NULL
        , [ErrorMessage]     nvarchar(2048) NULL
    );

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_ExtendedEventsAnalysis';
        PRINT N'Inventarfilter sind listen-/patternfähig; die forensische Quellsession ist ein einzelner optional geklammerter Name.';
        PRINT N'@ResultSetArt = RAW, CONSOLE, TABLE oder NONE; optional JSON über @Json OUTPUT.';
        RETURN;
    END;

    IF @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR @Source NOT IN ('AUTO', 'EVENT_FILE', 'RING_BUFFER')
       OR (@VonUtc IS NOT NULL AND @BisUtc IS NOT NULL AND @VonUtc > @BisUtc)
       OR (@MitSessionInventar = 0 AND @MitTargetRuntime = 0 AND @MitEvents = 0
           AND @MitDeadlocks = 0 AND @MitBlockedProcesses = 0)
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitSessionInventar = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_ExtendedEventsSessions]
                  @ExtendedEventSessionNames = @ExtendedEventSessionNames
                , @ExtendedEventSessionNamePattern = @ExtendedEventSessionNamePattern
                , @EventNames = @EventNames
                , @EventNamePattern = @EventNamePattern
                , @TargetNames = @TargetNames
                , @TargetNamePattern = @TargetNamePattern
                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @InventoryJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (1, N'USP_ExtendedEventsSessions', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (1, N'USP_ExtendedEventsSessions', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitTargetRuntime = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_ExtendedEventsTargetRuntime]
                  @ExtendedEventSessionNames = @ExtendedEventSessionNames
                , @ExtendedEventSessionNamePattern = @ExtendedEventSessionNamePattern
                , @TargetNames = @TargetNames
                , @TargetNamePattern = @TargetNamePattern
                , @BestaetigeTargetFlush = @BestaetigeTargetFlush
                , @HighImpactConfirmed = @HighImpactConfirmed
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @TargetJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (2, N'USP_ExtendedEventsTargetRuntime', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (2, N'USP_ExtendedEventsTargetRuntime', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitEvents = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_ExtendedEventsReadEvents]
                  @SourceExtendedEventSessionName = @SourceExtendedEventSessionName
                , @Quelle = @Source
                , @FilePath = @FilePath
                , @EventNames = @EventNames
                , @EventNamePattern = @EventNamePattern
                , @VonUtc = @VonUtc
                , @BisUtc = @BisUtc
                , @MaxZeilen = @MaxZeilen
                , @BestaetigeTargetFlush = @BestaetigeTargetFlush
                , @HighImpactConfirmed = @HighImpactConfirmed
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @EventsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (3, N'USP_ExtendedEventsReadEvents', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (3, N'USP_ExtendedEventsReadEvents', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitDeadlocks = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_ExtendedEventsDeadlocks]
                  @SourceExtendedEventSessionName = @SourceExtendedEventSessionName
                , @Quelle = @Source
                , @FilePath = @FilePath
                , @VonUtc = @VonUtc
                , @BisUtc = @BisUtc
                , @MaxZeilen = @MaxZeilen
                , @BestaetigeTargetFlush = @BestaetigeTargetFlush
                , @HighImpactConfirmed = @HighImpactConfirmed
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @DeadlocksJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (4, N'USP_ExtendedEventsDeadlocks', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (4, N'USP_ExtendedEventsDeadlocks', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitBlockedProcesses = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_ExtendedEventsBlockedProcesses]
                  @SourceExtendedEventSessionName = @SourceExtendedEventSessionName
                , @Quelle = @Source
                , @FilePath = @FilePath
                , @VonUtc = @VonUtc
                , @BisUtc = @BisUtc
                , @MaxZeilen = @MaxZeilen
                , @BestaetigeTargetFlush = @BestaetigeTargetFlush
                , @HighImpactConfirmed = @HighImpactConfirmed
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @BlockedJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (5, N'USP_ExtendedEventsBlockedProcesses', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (5, N'USP_ExtendedEventsBlockedProcesses', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF EXISTS (SELECT 1 FROM @ModuleStatus WHERE [InvocationStatus] <> 'EXECUTED')
       AND @StatusCode = 'AVAILABLE'
    BEGIN
        SET @StatusCode = 'AVAILABLE_LIMITED';
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT
              N'USP_ExtendedEventsAnalysis' AS [ModuleName]
            , @Now                         AS [CollectionTimeUtc]
            , @StatusCode                  AS [StatusCode]
            , CONVERT(bit, CASE WHEN @StatusCode = 'AVAILABLE' THEN 0 ELSE 1 END) AS [IsPartial]
            , (SELECT COUNT_BIG(*) FROM @ModuleStatus) AS [ModuleCount];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT * FROM @ModuleStatus ORDER BY [ExecutionOrdinal];
        END
        ELSE
        BEGIN
            SELECT
                  N'Extended-Events Teilmodul' AS [Ergebnis]
                , [ExecutionOrdinal]           AS [Reihenfolge]
                , [ModuleName]                 AS [Modul]
                , [InvocationStatus]           AS [Status]
                , [ErrorMessage]               AS [Fehler]
            FROM @ModuleStatus
            ORDER BY [ExecutionOrdinal];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @Meta nvarchar(max);
        DECLARE @Warnings nvarchar(max);

        SELECT @Meta =
        (
            SELECT
                  N'ExtendedEventsAnalysis' AS [resultName]
                , 1                         AS [schemaVersion]
                , @Now                      AS [generatedAtUtc]
                , @StatusCode               AS [statusCode]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        SELECT @Warnings =
        (
            SELECT *
            FROM @ModuleStatus
            WHERE [InvocationStatus] <> 'EXECUTED'
            ORDER BY [ExecutionOrdinal]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@Meta, N'{}')
            , N',"inventory":', COALESCE(JSON_QUERY(@InventoryJson), N'null')
            , N',"targetRuntime":', COALESCE(JSON_QUERY(@TargetJson), N'null')
            , N',"events":', COALESCE(JSON_QUERY(@EventsJson), N'null')
            , N',"deadlocks":', COALESCE(JSON_QUERY(@DeadlocksJson), N'null')
            , N',"blockedProcesses":', COALESCE(JSON_QUERY(@BlockedJson), N'null')
            , N',"warnings":', COALESCE(@Warnings, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ExtendedEventsAnalysis_MonitorTableResult'
            , @ResultLabel=N'ExtendedEventsAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        SELECT * INTO [#ExtendedEventsAnalysis_MonitorTableResult] FROM @ModuleStatus;
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ExtendedEventsAnalysis_MonitorTableResult'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
