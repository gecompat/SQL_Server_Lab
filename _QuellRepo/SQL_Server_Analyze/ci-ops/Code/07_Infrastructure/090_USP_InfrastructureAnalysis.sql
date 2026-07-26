USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_InfrastructureAnalysis
Version      : 2.1.0
Stand        : 2026-07-17
Typ          : Stored Procedure
Zweck        : Orchestriert die Phase-6-Module fehlertolerant.
SQL-Version  : SQL Server 2019 oder neuer.
Datenbankscope: @DatabaseNames ist eine bracket-aware Pipe-Liste; NULL bedeutet
               alle zulässigen Datenbanken. @DatabaseNamePattern ist alternativ.
Resultsets   : Je aktiviertem Modul RAW oder CONSOLE sowie Modulstatus;
               NONE unterdrückt alle fachlichen Resultsets.
JSON         : meta und benannte Modulobjekte agent, agentJobs,
               resourceGovernor, availabilityGroups, backupRecovery,
               logShipping, replication, dataCapture sowie warnings.
Berechtigung : Das Framework vergibt keine Rechte und ändert keine Konfiguration.
Änderungen   : 2.1.0 - Backupketten, tiefe AG- und Agent-Monitoring-Evidenz
                         als opt-in Teilmodule ergänzt.
               2.0.0 - @AlleDatenbanken entfernt; einheitlicher Datenbankscope,
                         Ausgabeadapter und JSON-Orchestrierung.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_InfrastructureAnalysis]
      @MitAgent                       bit            = 1
    , @MitAgentJobs                   bit            = 1
    , @MitResourceGovernor            bit            = 1
    , @MitAvailabilityGroups          bit            = 1
    , @MitBackupRecovery              bit            = 1
    , @MitLogShipping                 bit            = 1
    , @MitReplication                 bit            = 1
    , @MitDataCapture                 bit            = 1
    , @MitReplicationDetails          bit            = 0
    , @MitBackupChain                 bit            = 0
    , @MitAvailabilityDeep            bit            = 0
    , @MitAgentMonitoring             bit            = 0
    , @DatabaseNames                  nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen   bit            = 0
    , @DatabaseNamePattern            nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MaxZeilen                      int            = 2000
    , @ResultSetArt                   varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                   bit            = 0
    , @Json                           nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                 bit            = 1
    , @Hilfe                          bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    SET @Json = NULL;

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'moduleStatus',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_InfrastructureAnalysis';
        PRINT N'Die Modulschalter steuern die bestehenden Module sowie die optionalen Vertiefungen @MitBackupChain, @MitAvailabilityDeep und @MitAgentMonitoring.';
        PRINT N'@DatabaseNames: exakter Name oder bracket-aware Pipe-Liste; NULL = alle zulässigen Datenbanken.';
        PRINT N'@DatabaseNamePattern: alternatives LIKE-/Regex-Pattern; exakte Liste und Pattern sind gegenseitig exklusiv.';
        PRINT N'@MaxZeilen: positive Werte begrenzen; NULL/0 = unbegrenzt; negative Werte sind ungültig.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE case-insensitiv; @JsonErzeugen=1 setzt @Json OUTPUT.';
        RETURN;
    END;

    CREATE TABLE [#InfrastructureAnalysis_ModuleStatus]
    (
          [ModuleName] sysname NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    DECLARE @AgentJson nvarchar(max) = NULL;
    DECLARE @AgentJobsJson nvarchar(max) = NULL;
    DECLARE @ResourceGovernorJson nvarchar(max) = NULL;
    DECLARE @AvailabilityGroupsJson nvarchar(max) = NULL;
    DECLARE @BackupRecoveryJson nvarchar(max) = NULL;
    DECLARE @LogShippingJson nvarchar(max) = NULL;
    DECLARE @ReplicationJson nvarchar(max) = NULL;
    DECLARE @DataCaptureJson nvarchar(max) = NULL;
    DECLARE @BackupChainJson nvarchar(max) = NULL;
    DECLARE @AvailabilityDeepJson nvarchar(max) = NULL;
    DECLARE @AgentMonitoringJson nvarchar(max) = NULL;
    DECLARE @ChildStatus varchar(40) = NULL;
    DECLARE @ChildPartial bit = NULL;
    DECLARE @ChildErrorNumber int = NULL;
    DECLARE @ChildErrorMessage nvarchar(2048) = NULL;

    IF @MaxZeilen < 0
       OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR (@DatabaseNames IS NOT NULL AND @DatabaseNamePattern IS NOT NULL)
    BEGIN
        INSERT [#InfrastructureAnalysis_ModuleStatus]
        VALUES
        (
              N'USP_InfrastructureAnalysis'
            , 'INVALID_PARAMETER'
            , NULL
            , N'Ungültige Scope-, Grenzwert- oder Ausgabeparameter.'
        );
    END;
    ELSE
    BEGIN
        IF @MitAgent = 1
        BEGIN TRY
            EXEC [monitor].[USP_AgentStatus]
                  @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @AgentJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AgentStatus', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AgentStatus', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitAgentJobs = 1
        BEGIN TRY
            EXEC [monitor].[USP_AgentJobs]
                  @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @AgentJobsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AgentJobs', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AgentJobs', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitResourceGovernor = 1
        BEGIN TRY
            EXEC [monitor].[USP_ResourceGovernorAnalysis]
                  @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @ResourceGovernorJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_ResourceGovernorAnalysis', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_ResourceGovernorAnalysis', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitAvailabilityGroups = 1
        BEGIN TRY
            EXEC [monitor].[USP_AvailabilityGroups]
                  @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @AvailabilityGroupsJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AvailabilityGroups', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AvailabilityGroups', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitBackupRecovery = 1
        BEGIN TRY
            EXEC [monitor].[USP_BackupRecovery]
                  @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @BackupRecoveryJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_BackupRecovery', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_BackupRecovery', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitLogShipping = 1
        BEGIN TRY
            EXEC [monitor].[USP_LogShippingStatus]
                  @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @LogShippingJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_LogShippingStatus', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_LogShippingStatus', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitReplication = 1
        BEGIN TRY
            EXEC [monitor].[USP_ReplicationStatus]
                  @MitDistributionDetails = @MitReplicationDetails
                , @MaxZeilen = @MaxZeilen
                , @HighImpactConfirmed = @HighImpactConfirmed
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @ReplicationJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_ReplicationStatus', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_ReplicationStatus', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitDataCapture = 1
        BEGIN TRY
            EXEC [monitor].[USP_DataCaptureStatus]
                  @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @DataCaptureJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_DataCaptureStatus', 'EXECUTED', NULL, NULL);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_DataCaptureStatus', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitBackupChain = 1
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_BackupChainAnalysis]
                  @DatabaseNames = @DatabaseNames
                , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @BackupChainJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES
            (N'USP_BackupChainAnalysis', COALESCE(@ChildStatus, 'ERROR_HANDLED'), @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_BackupChainAnalysis', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitAvailabilityDeep = 1
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_AvailabilityDeepAnalysis]
                  @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @AvailabilityDeepJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES
            (N'USP_AvailabilityDeepAnalysis', COALESCE(@ChildStatus, 'ERROR_HANDLED'), @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AvailabilityDeepAnalysis', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF @MitAgentMonitoring = 1
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_AgentMonitoringAnalysis]
                  @MaxZeilen = @MaxZeilen
                , @ResultSetArt = @ResultSetArtNormalisiert
                , @JsonErzeugen = @JsonErzeugen
                , @Json = @AgentMonitoringJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES
            (N'USP_AgentMonitoringAnalysis', COALESCE(@ChildStatus, 'ERROR_HANDLED'), @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT [#InfrastructureAnalysis_ModuleStatus] VALUES (N'USP_AgentMonitoringAnalysis', 'ERROR_HANDLED', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    DECLARE @OverallStatus varchar(40) =
        CASE WHEN EXISTS
                  (SELECT 1 FROM [#InfrastructureAnalysis_ModuleStatus]
                   WHERE [StatusCode] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE'))
             THEN 'AVAILABLE_LIMITED'
             WHEN EXISTS (SELECT 1 FROM [#InfrastructureAnalysis_ModuleStatus] WHERE [StatusCode] = 'AVAILABLE_WITH_FINDING')
             THEN 'AVAILABLE_WITH_FINDING'
             ELSE 'AVAILABLE' END;
    DECLARE @IsPartial bit = CONVERT(bit,
        CASE WHEN EXISTS
             (SELECT 1 FROM [#InfrastructureAnalysis_ModuleStatus]
              WHERE [StatusCode] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE'))
             THEN 1 ELSE 0 END);

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        SELECT
              @CollectionTimeUtc AS [CollectionTimeUtc]
            , CAST(N'monitor.USP_InfrastructureAnalysis' AS nvarchar(256)) AS [ModuleName]
            , @OverallStatus AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , CONVERT(bigint, (SELECT COUNT_BIG(*) FROM [#InfrastructureAnalysis_ModuleStatus])) AS [ModuleCount]
            , CONVERT(bigint, (SELECT COUNT_BIG(*) FROM [#InfrastructureAnalysis_ModuleStatus]
                               WHERE [StatusCode] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE'))) AS [ProblemModuleCount];

        IF @ResultSetArtNormalisiert = 'RAW'
        BEGIN
            SELECT [ModuleName], [StatusCode], [ErrorNumber], [ErrorMessage]
            FROM [#InfrastructureAnalysis_ModuleStatus]
            ORDER BY [ModuleName];
        END;
        ELSE
        BEGIN
            SELECT
                  N'Infrastruktur-Modul' AS [Ergebnis]
                , [ModuleName] AS [Modul]
                , [StatusCode] AS [Status]
                , [ErrorNumber] AS [Fehlernummer]
                , [ErrorMessage] AS [Fehlermeldung]
            FROM [#InfrastructureAnalysis_ModuleStatus]
            ORDER BY [ModuleName];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  N'InfrastructureAnalysis' AS [resultName]
                , 1 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @OverallStatus AS [statusCode]
                , @IsPartial AS [isPartial]
                , @MaxZeilen AS [requestedMaxRows]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT * FROM [#InfrastructureAnalysis_ModuleStatus]
             WHERE [StatusCode] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE')
             ORDER BY [ModuleName] FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"agent":', COALESCE(JSON_QUERY(@AgentJson), N'null')
            , N',"agentJobs":', COALESCE(JSON_QUERY(@AgentJobsJson), N'null')
            , N',"resourceGovernor":', COALESCE(JSON_QUERY(@ResourceGovernorJson), N'null')
            , N',"availabilityGroups":', COALESCE(JSON_QUERY(@AvailabilityGroupsJson), N'null')
            , N',"backupRecovery":', COALESCE(JSON_QUERY(@BackupRecoveryJson), N'null')
            , N',"logShipping":', COALESCE(JSON_QUERY(@LogShippingJson), N'null')
            , N',"replication":', COALESCE(JSON_QUERY(@ReplicationJson), N'null')
            , N',"dataCapture":', COALESCE(JSON_QUERY(@DataCaptureJson), N'null')
            , N',"backupChain":', COALESCE(JSON_QUERY(@BackupChainJson), N'null')
            , N',"availabilityDeep":', COALESCE(JSON_QUERY(@AvailabilityDeepJson), N'null')
            , N',"agentMonitoring":', COALESCE(JSON_QUERY(@AgentMonitoringJson), N'null')
            , N',"warnings":', COALESCE(@WarningsJson, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#InfrastructureAnalysis_ModuleStatus'
            , @ResultLabel=N'InfrastructureAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#InfrastructureAnalysis_ModuleStatus'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
