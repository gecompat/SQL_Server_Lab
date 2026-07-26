USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_QueryStoreAnalysis
Version      : 2.1.0
Stand        : 2026-07-17
Zweck        : Orchestriert Query-Store-Module mit einheitlichem Quell- und
               Referenzdatenbankvertrag. JSON enthält benannte Modulobjekte.
Änderungen   : 2.1.0 - IQP-Evidenz als kostenbewusstes opt-in Teilmodul.
               2.0.1 - IF/TRY/CATCH-Blöcke syntaktisch eindeutig strukturiert.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_QueryStoreAnalysis]
      @QueryStoreDatabaseNames          nvarchar(max)  = NULL
    , @QueryStoreDatabaseNamePattern    nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @ReferencedDatabaseNames          nvarchar(max)  = NULL
    , @ReferencedDatabaseNamePattern    nvarchar(4000) = NULL
    , @VonUtc                           datetime2(7)   = NULL
    , @BisUtc                           datetime2(7)   = NULL
    , @MitStatus                        bit            = 1
    , @MitRuntimeStats                  bit            = 1
    , @MitWaitStats                     bit            = 0
    , @MitPlanChanges                   bit            = 0
    , @MitRegressionen                  bit            = 0
    , @MitForcedPlans                   bit            = 0
    , @MitHints                         bit            = 0
    , @MitIQP                           bit            = 0
    , @MaxZeilen                        int            = 100
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
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
    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @StatusJson nvarchar(max);
    DECLARE @RuntimeJson nvarchar(max);
    DECLARE @WaitJson nvarchar(max);
    DECLARE @PlanJson nvarchar(max);
    DECLARE @RegressionJson nvarchar(max);
    DECLARE @ForcedJson nvarchar(max);
    DECLARE @HintsJson nvarchar(max);
    DECLARE @IqpJson nvarchar(max);
    DECLARE @IqpStatus varchar(40) = NULL;
    DECLARE @IqpPartial bit = NULL;
    DECLARE @IqpErrorNumber int = NULL;
    DECLARE @IqpErrorMessage nvarchar(2048) = NULL;

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
        PRINT N'monitor.USP_QueryStoreAnalysis';
        PRINT N'@QueryStoreDatabaseNames/Pattern bestimmen Query-Store-Quellen.';
        PRINT N'@ReferencedDatabaseNames/Pattern filtern in Showplans verwendete Datenbanken.';
        PRINT N'@ResultSetArt = RAW, CONSOLE, TABLE oder NONE; optional JSON über @Json OUTPUT.';
        RETURN;
    END;

    IF @MaxZeilen < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR (@VonUtc IS NOT NULL AND @BisUtc IS NOT NULL AND @VonUtc > @BisUtc)
       OR (@MitStatus = 0 AND @MitRuntimeStats = 0 AND @MitWaitStats = 0
           AND @MitPlanChanges = 0 AND @MitRegressionen = 0
           AND @MitForcedPlans = 0 AND @MitHints = 0 AND @MitIQP = 0)
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitStatus = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStoreStatus]
                  @QueryStoreDatabaseNames = @QueryStoreDatabaseNames
                , @QueryStoreDatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @StatusJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (1, N'USP_QueryStoreStatus', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (1, N'USP_QueryStoreStatus', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitRuntimeStats = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStoreRuntimeStats]
                  @QueryStoreDatabaseNames = @QueryStoreDatabaseNames
                , @QueryStoreDatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @ReferencedDatabaseNames = @ReferencedDatabaseNames
                , @ReferencedDatabaseNamePattern = @ReferencedDatabaseNamePattern
                , @VonUtc = @VonUtc
                , @BisUtc = @BisUtc

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @RuntimeJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (2, N'USP_QueryStoreRuntimeStats', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (2, N'USP_QueryStoreRuntimeStats', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitWaitStats = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStoreWaitStats]
                  @QueryStoreDatabaseNames = @QueryStoreDatabaseNames
                , @QueryStoreDatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @ReferencedDatabaseNames = @ReferencedDatabaseNames
                , @ReferencedDatabaseNamePattern = @ReferencedDatabaseNamePattern
                , @VonUtc = @VonUtc
                , @BisUtc = @BisUtc

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @WaitJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (3, N'USP_QueryStoreWaitStats', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (3, N'USP_QueryStoreWaitStats', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitPlanChanges = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStorePlanChanges]
                  @QueryStoreDatabaseNames = @QueryStoreDatabaseNames
                , @QueryStoreDatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @ReferencedDatabaseNames = @ReferencedDatabaseNames
                , @ReferencedDatabaseNamePattern = @ReferencedDatabaseNamePattern
                , @VonUtc = @VonUtc

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @PlanJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (4, N'USP_QueryStorePlanChanges', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (4, N'USP_QueryStorePlanChanges', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitRegressionen = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStoreRegressions]
                  @QueryStoreDatabaseNames = @QueryStoreDatabaseNames
                , @QueryStoreDatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @ReferencedDatabaseNames = @ReferencedDatabaseNames
                , @ReferencedDatabaseNamePattern = @ReferencedDatabaseNamePattern
                , @VergleichVonUtc = @VonUtc
                , @VergleichBisUtc = @BisUtc

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @RegressionJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (5, N'USP_QueryStoreRegressions', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (5, N'USP_QueryStoreRegressions', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitForcedPlans = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStoreForcedPlans]
                  @QueryStoreDatabaseNames = @QueryStoreDatabaseNames
                , @QueryStoreDatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @ReferencedDatabaseNames = @ReferencedDatabaseNames
                , @ReferencedDatabaseNamePattern = @ReferencedDatabaseNamePattern

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @ForcedJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (6, N'USP_QueryStoreForcedPlans', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (6, N'USP_QueryStoreForcedPlans', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitHints = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_QueryStoreHints]
                  @QueryStoreDatabaseNames = @QueryStoreDatabaseNames
                , @QueryStoreDatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @HintsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;

            INSERT @ModuleStatus VALUES (7, N'USP_QueryStoreHints', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (7, N'USP_QueryStoreHints', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitIQP = 1
    BEGIN
        BEGIN TRY
            EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis]
                  @DatabaseNames = @QueryStoreDatabaseNames
                , @DatabaseNamePattern = @QueryStoreDatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @OutputMode
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @IqpJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @IqpStatus OUTPUT
                , @IsPartialOut = @IqpPartial OUTPUT
                , @ErrorNumberOut = @IqpErrorNumber OUTPUT
                , @ErrorMessageOut = @IqpErrorMessage OUTPUT;

            INSERT @ModuleStatus VALUES
            (8, N'USP_IntelligentQueryProcessingAnalysis', COALESCE(@IqpStatus, 'ERROR_HANDLED'), @IqpErrorNumber, @IqpErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (8, N'USP_IntelligentQueryProcessingAnalysis', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF EXISTS (SELECT 1 FROM @ModuleStatus
               WHERE [InvocationStatus] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE'))
       AND @StatusCode = 'AVAILABLE'
    BEGIN
        SET @StatusCode = 'AVAILABLE_LIMITED';
    END
    ELSE IF EXISTS (SELECT 1 FROM @ModuleStatus WHERE [InvocationStatus] = 'AVAILABLE_WITH_FINDING')
         AND @StatusCode = 'AVAILABLE'
        SET @StatusCode = 'AVAILABLE_WITH_FINDING';

    IF @OutputMode <> 'NONE'
    BEGIN
        SELECT
              N'USP_QueryStoreAnalysis' AS [ModuleName]
            , @Now                     AS [CollectionTimeUtc]
            , @StatusCode              AS [StatusCode]
            , CONVERT(bit, CASE WHEN @StatusCode IN ('AVAILABLE','AVAILABLE_WITH_FINDING') THEN 0 ELSE 1 END) AS [IsPartial]
            , (SELECT COUNT_BIG(*) FROM @ModuleStatus
               WHERE [InvocationStatus] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE')) AS [ErrorCount]
            , N'Orchestrator; Teilmodule liefern eigene benannte Resultsets.' AS [Detail];

        IF @OutputMode = 'RAW'
        BEGIN
            SELECT * FROM @ModuleStatus ORDER BY [ExecutionOrdinal];
        END
        ELSE
        BEGIN
            SELECT
                  N'Query-Store Teilmodul' AS [Ergebnis]
                , [ExecutionOrdinal]       AS [Reihenfolge]
                , [ModuleName]             AS [Modul]
                , [InvocationStatus]       AS [Status]
                , [ErrorMessage]           AS [Fehler]
            FROM @ModuleStatus
            ORDER BY [ExecutionOrdinal];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @Warnings nvarchar(max);
        DECLARE @Meta nvarchar(max);

        SELECT @Warnings =
        (
            SELECT *
            FROM @ModuleStatus
            WHERE [InvocationStatus] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE')
            ORDER BY [ExecutionOrdinal]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        );

        SELECT @Meta =
        (
            SELECT
                  N'QueryStoreAnalysis' AS [resultName]
                , 1                     AS [schemaVersion]
                , @Now                  AS [generatedAtUtc]
                , @StatusCode           AS [statusCode]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@Meta, N'{}')
            , N',"status":', COALESCE(JSON_QUERY(@StatusJson), N'null')
            , N',"runtimeStats":', COALESCE(JSON_QUERY(@RuntimeJson), N'null')
            , N',"waitStats":', COALESCE(JSON_QUERY(@WaitJson), N'null')
            , N',"planChanges":', COALESCE(JSON_QUERY(@PlanJson), N'null')
            , N',"regressions":', COALESCE(JSON_QUERY(@RegressionJson), N'null')
            , N',"forcedPlans":', COALESCE(JSON_QUERY(@ForcedJson), N'null')
            , N',"queryHints":', COALESCE(JSON_QUERY(@HintsJson), N'null')
            , N',"intelligentQueryProcessing":', COALESCE(JSON_QUERY(@IqpJson), N'null')
            , N',"warnings":', COALESCE(@Warnings, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#QueryStoreAnalysis_MonitorTableResult'
            , @ResultLabel=N'QueryStoreAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        SELECT * INTO [#QueryStoreAnalysis_MonitorTableResult] FROM @ModuleStatus;
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#QueryStoreAnalysis_MonitorTableResult'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
