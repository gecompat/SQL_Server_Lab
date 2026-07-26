USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ServerHealthAnalysis
Version      : 3.2.0
Stand        : 2026-07-19
Zweck        : Orchestriert alle Server-Health-Module. RAW/CONSOLE werden an
               Child-Module weitergereicht; JSON enthält benannte Modulobjekte.
Änderungen   : 3.2.0 - Bereits erhobene Integritäts-, Kapazitäts- und
                         Buffer-Pool-Ergebnisse im Findings-Child wiederverwendet.
               3.1.0 - Spezialfallmodule und normalisierte Befunde als opt-in.
               3.0.1 - IF/TRY/CATCH-Blöcke syntaktisch eindeutig strukturiert;
                         Child-Statusvariablen vor jedem Aufruf zurückgesetzt.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ServerHealthAnalysis]
      @MitCpu           bit           = 1
    , @MitNuma          bit           = 1
    , @MitMemory        bit           = 1
    , @MitTempDB        bit           = 1
    , @MitConfiguration bit           = 1
    , @MitTraceFlags    bit           = 1
    , @MitStartup       bit           = 1
    , @MitOS            bit           = 1
    , @MitSecurity      bit           = 1
    , @MitIntegritaet   bit           = 0
    , @MitKapazitaet    bit           = 0
    , @MitPerformanceCounters bit      = 0
    , @MitCriticalEvents bit           = 0
    , @MitContention    bit           = 0
    , @MitBufferPool    bit           = 0
    , @MitFindings      bit           = 0
    , @DatabaseNames    nvarchar(max) = NULL
    , @SystemdatenbankenEinbeziehen bit = 0
    , @DatabaseNamePattern nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MaxZeilen        int           = 100
    , @ResultSetArt     varchar(16)   = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen     bit           = 0
    , @Json             nvarchar(max) = NULL OUTPUT
    , @PrintMeldungen   bit           = 1
    , @Hilfe            bit           = 0
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
    DECLARE @ChildJsonRequested bit = CASE WHEN @JsonErzeugen=1 OR @MitFindings=1 THEN 1 ELSE 0 END;
    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @OverallStatus varchar(40) = 'AVAILABLE';
    DECLARE @ChildStatus varchar(40);
    DECLARE @ChildPartial bit;
    DECLARE @ChildErrorNumber int;
    DECLARE @ChildErrorMessage nvarchar(2048);
    DECLARE @CpuJson nvarchar(max);
    DECLARE @NumaJson nvarchar(max);
    DECLARE @MemoryJson nvarchar(max);
    DECLARE @TempDbJson nvarchar(max);
    DECLARE @ConfigurationJson nvarchar(max);
    DECLARE @TraceFlagsJson nvarchar(max);
    DECLARE @StartupJson nvarchar(max);
    DECLARE @OsJson nvarchar(max);
    DECLARE @SecurityJson nvarchar(max);
    DECLARE @IntegrityJson nvarchar(max);
    DECLARE @CapacityJson nvarchar(max);
    DECLARE @CountersJson nvarchar(max);
    DECLARE @CriticalEventsJson nvarchar(max);
    DECLARE @ContentionJson nvarchar(max);
    DECLARE @BufferPoolJson nvarchar(max);
    DECLARE @FindingsJson nvarchar(max);

    CREATE TABLE [#ServerHealthAnalysis_ModuleStatus]
    (
          [Ordinal]      tinyint        NOT NULL
        , [ModuleName]   sysname        NOT NULL
        , [StatusCode]   varchar(40)    NOT NULL
        , [IsPartial]    bit            NOT NULL
        , [ErrorNumber]  int            NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_ServerHealthAnalysis';
        PRINT N'@ResultSetArt = RAW, CONSOLE, TABLE oder NONE; optional JSON mit benannten Modulobjekten.';
        RETURN;
    END;

    IF @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR (@MitCpu = 0 AND @MitNuma = 0 AND @MitMemory = 0 AND @MitTempDB = 0
           AND @MitConfiguration = 0 AND @MitTraceFlags = 0 AND @MitStartup = 0
           AND @MitOS = 0 AND @MitSecurity = 0 AND @MitIntegritaet = 0
           AND @MitKapazitaet = 0 AND @MitPerformanceCounters = 0
           AND @MitCriticalEvents = 0 AND @MitContention = 0
           AND @MitBufferPool = 0 AND @MitFindings = 0)
    BEGIN
        SET @OverallStatus = 'INVALID_PARAMETER';
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitCpu = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_ServerCpuTopology]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @CpuJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (1, N'USP_ServerCpuTopology', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitNuma = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_ServerNuma]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @NumaJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (2, N'USP_ServerNuma', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitMemory = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_ServerMemory]
                  @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @MemoryJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (3, N'USP_ServerMemory', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitTempDB = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_TempDBConfiguration]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @TempDbJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (4, N'USP_TempDBConfiguration', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitConfiguration = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_ServerConfiguration]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @ConfigurationJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (5, N'USP_ServerConfiguration', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitTraceFlags = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_TraceFlags]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @TraceFlagsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (6, N'USP_TraceFlags', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitStartup = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_StartupParameters]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @StartupJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (7, N'USP_StartupParameters', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitOS = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_OSInformation]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @OsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (8, N'USP_OSInformation', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitSecurity = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_ServerSecurityConfiguration]
                  @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @SecurityJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT @ChildStatus = 'ERROR_HANDLED', @ChildPartial = 1,
                   @ChildErrorNumber = ERROR_NUMBER(), @ChildErrorMessage = ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES
        (9, N'USP_ServerSecurityConfiguration', COALESCE(@ChildStatus, 'ERROR_HANDLED'), COALESCE(@ChildPartial, 1), @ChildErrorNumber, @ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitIntegritaet = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
                  @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @MitPageDetails = 0
                , @MaxZeilen = @MaxZeilen, @ResultSetArt = @OutputMode
                , @JsonErzeugen = @ChildJsonRequested, @Json = @IntegrityJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY BEGIN CATCH
            SELECT @ChildStatus='ERROR_HANDLED',@ChildPartial=1,@ChildErrorNumber=ERROR_NUMBER(),@ChildErrorMessage=ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES (10,N'USP_DatabaseIntegrityAnalysis',COALESCE(@ChildStatus,'ERROR_HANDLED'),COALESCE(@ChildPartial,1),@ChildErrorNumber,@ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitKapazitaet = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_DatabaseCapacityAnalysis]
                  @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode, @JsonErzeugen = @ChildJsonRequested
                , @Json = @CapacityJson OUTPUT, @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY BEGIN CATCH
            SELECT @ChildStatus='ERROR_HANDLED',@ChildPartial=1,@ChildErrorNumber=ERROR_NUMBER(),@ChildErrorMessage=ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES (11,N'USP_DatabaseCapacityAnalysis',COALESCE(@ChildStatus,'ERROR_HANDLED'),COALESCE(@ChildPartial,1),@ChildErrorNumber,@ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitPerformanceCounters = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_PerformanceCounters]
                  @SampleSeconds = 0, @MaxZeilen = @MaxZeilen, @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen, @Json = @CountersJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY BEGIN CATCH
            SELECT @ChildStatus='ERROR_HANDLED',@ChildPartial=1,@ChildErrorNumber=ERROR_NUMBER(),@ChildErrorMessage=ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES (12,N'USP_PerformanceCounters',COALESCE(@ChildStatus,'ERROR_HANDLED'),COALESCE(@ChildPartial,1),@ChildErrorNumber,@ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitCriticalEvents = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_CriticalEngineEvents]
                  @MitSystemHealth = 1, @MitServerDiagnostics = 0, @MitEventXml = 0
                , @MaxZeilen = @MaxZeilen, @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen, @Json = @CriticalEventsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY BEGIN CATCH
            SELECT @ChildStatus='ERROR_HANDLED',@ChildPartial=1,@ChildErrorNumber=ERROR_NUMBER(),@ChildErrorMessage=ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES (13,N'USP_CriticalEngineEvents',COALESCE(@ChildStatus,'ERROR_HANDLED'),COALESCE(@ChildPartial,1),@ChildErrorNumber,@ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitContention = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_InternalContentionAnalysis]
                  @SampleSeconds = 5, @MitPageDetails = 0, @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode, @JsonErzeugen = @JsonErzeugen
                , @Json = @ContentionJson OUTPUT, @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY BEGIN CATCH
            SELECT @ChildStatus='ERROR_HANDLED',@ChildPartial=1,@ChildErrorNumber=ERROR_NUMBER(),@ChildErrorMessage=ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES (14,N'USP_InternalContentionAnalysis',COALESCE(@ChildStatus,'ERROR_HANDLED'),COALESCE(@ChildPartial,1),@ChildErrorNumber,@ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitBufferPool = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_BufferPoolAnalysis]
                  @MitBufferPoolVerteilung = 0, @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode, @JsonErzeugen = @ChildJsonRequested
                , @Json = @BufferPoolJson OUTPUT, @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY BEGIN CATCH
            SELECT @ChildStatus='ERROR_HANDLED',@ChildPartial=1,@ChildErrorNumber=ERROR_NUMBER(),@ChildErrorMessage=ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES (15,N'USP_BufferPoolAnalysis',COALESCE(@ChildStatus,'ERROR_HANDLED'),COALESCE(@ChildPartial,1),@ChildErrorNumber,@ChildErrorMessage);
    END;

    IF @OverallStatus = 'AVAILABLE' AND @MitFindings = 1
    BEGIN
        SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
        BEGIN TRY
            EXEC [monitor].[USP_DiagnosticFindings]
                  @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @ParentIntegrityJson = @IntegrityJson
                , @ParentCapacityJson = @CapacityJson
                , @ParentBufferPoolJson = @BufferPoolJson
                , @MaxZeilen = @MaxZeilen, @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen, @Json = @FindingsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
        END TRY BEGIN CATCH
            SELECT @ChildStatus='ERROR_HANDLED',@ChildPartial=1,@ChildErrorNumber=ERROR_NUMBER(),@ChildErrorMessage=ERROR_MESSAGE();
        END CATCH;
        INSERT [#ServerHealthAnalysis_ModuleStatus] VALUES (16,N'USP_DiagnosticFindings',COALESCE(@ChildStatus,'ERROR_HANDLED'),COALESCE(@ChildPartial,1),@ChildErrorNumber,@ChildErrorMessage);
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [#ServerHealthAnalysis_ModuleStatus]
        WHERE [StatusCode] NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED', 'AVAILABLE_WITH_FINDING', 'NOT_APPLICABLE')
    )
       AND @OverallStatus = 'AVAILABLE'
    BEGIN
        SET @OverallStatus = 'AVAILABLE_LIMITED';
    END;

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT
              N'USP_ServerHealthAnalysis' AS [ModuleName]
            , @Now                       AS [CollectionTimeUtc]
            , @OverallStatus             AS [StatusCode]
            , CONVERT(bit, CASE WHEN @OverallStatus = 'AVAILABLE' THEN 0 ELSE 1 END) AS [IsPartial]
            , (SELECT COUNT_BIG(*) FROM [#ServerHealthAnalysis_ModuleStatus]) AS [ModuleCount]
            , (SELECT COUNT_BIG(*) FROM [#ServerHealthAnalysis_ModuleStatus]
               WHERE [StatusCode] NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED', 'AVAILABLE_WITH_FINDING', 'NOT_APPLICABLE')) AS [ProblemModuleCount];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT * FROM [#ServerHealthAnalysis_ModuleStatus] ORDER BY [Ordinal];
        END
        ELSE
        BEGIN
            SELECT
                  N'Server-Health Teilmodul' AS [Ergebnis]
                , [Ordinal]                  AS [Reihenfolge]
                , [ModuleName]               AS [Modul]
                , [StatusCode]               AS [Status]
                , [IsPartial]                AS [Partiell]
                , [ErrorMessage]             AS [Fehler]
            FROM [#ServerHealthAnalysis_ModuleStatus]
            ORDER BY [Ordinal];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @Meta nvarchar(max);
        DECLARE @Warnings nvarchar(max);

        SELECT @Meta =
        (
            SELECT
                  N'ServerHealthAnalysis' AS [resultName]
                , 1                       AS [schemaVersion]
                , @Now                    AS [generatedAtUtc]
                , @OverallStatus          AS [statusCode]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        SELECT @Warnings =
        (
            SELECT *
            FROM [#ServerHealthAnalysis_ModuleStatus]
            WHERE [StatusCode] NOT IN ('AVAILABLE', 'AVAILABLE_LIMITED', 'AVAILABLE_WITH_FINDING', 'NOT_APPLICABLE')
            ORDER BY [Ordinal]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@Meta, N'{}')
            , N',"cpuTopology":', COALESCE(JSON_QUERY(@CpuJson), N'null')
            , N',"numa":', COALESCE(JSON_QUERY(@NumaJson), N'null')
            , N',"memory":', COALESCE(JSON_QUERY(@MemoryJson), N'null')
            , N',"tempdb":', COALESCE(JSON_QUERY(@TempDbJson), N'null')
            , N',"configuration":', COALESCE(JSON_QUERY(@ConfigurationJson), N'null')
            , N',"traceFlags":', COALESCE(JSON_QUERY(@TraceFlagsJson), N'null')
            , N',"startupParameters":', COALESCE(JSON_QUERY(@StartupJson), N'null')
            , N',"operatingSystem":', COALESCE(JSON_QUERY(@OsJson), N'null')
            , N',"security":', COALESCE(JSON_QUERY(@SecurityJson), N'null')
            , N',"databaseIntegrity":', COALESCE(JSON_QUERY(@IntegrityJson), N'null')
            , N',"databaseCapacity":', COALESCE(JSON_QUERY(@CapacityJson), N'null')
            , N',"performanceCounters":', COALESCE(JSON_QUERY(@CountersJson), N'null')
            , N',"criticalEngineEvents":', COALESCE(JSON_QUERY(@CriticalEventsJson), N'null')
            , N',"internalContention":', COALESCE(JSON_QUERY(@ContentionJson), N'null')
            , N',"bufferPool":', COALESCE(JSON_QUERY(@BufferPoolJson), N'null')
            , N',"diagnosticFindings":', COALESCE(JSON_QUERY(@FindingsJson), N'null')
            , N',"warnings":', COALESCE(@Warnings, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ServerHealthAnalysis_ModuleStatus'
            , @ResultLabel=N'ServerHealthAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ServerHealthAnalysis_ModuleStatus'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
