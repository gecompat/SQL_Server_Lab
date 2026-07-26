USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_DiagnosticFindings
Version      : 1.2.0
Stand        : 2026-07-19
Zweck        : Aggregiert normalisierte Befunde aus den zuvor implementierten
               Spezialfallmodulen über deren JSON-Ausgabeverträge.
Abhängigkeit : DatabaseIntegrityAnalysis, DatabaseCapacityAnalysis,
               BufferPoolAnalysis, BackupChainAnalysis,
               AvailabilityDeepAnalysis, AgentMonitoringAnalysis sowie opt-in
               SchemaDesignAnalysis, StatisticsDistributionAnalysis,
               IntelligentQueryProcessingAnalysis und InternalContentionAnalysis.
Methodik     : Kindmodule laufen mit @ResultSetArt=NONE. Innerhalb eines
               Orchestratoraufrufs können kontextgleiche Parent-Ergebnisse
               wiederverwendet werden; sonst werden Quellen frisch gelesen.
               Der Aggregator liest nur definierte JSON-Felder und übernimmt
               keine freien SQL-, Mail-, Plan-, Pfad- oder Meldungstexte.
Grenzen      : Priorität ist Triage, keine automatische Ursachenfeststellung.
               Kein READPAST; unvollständige Child-Evidenz bleibt sichtbar.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_DiagnosticFindings]
      @DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @MitIntegritaet               bit            = 1
    , @MitKapazitaet                bit            = 1
    , @MitSpeicher                  bit            = 1
    , @MitBackupketten              bit            = 1
    , @MitAvailability              bit            = 1
    , @MitAgentMonitoring           bit            = 1
    , @MitSchemaDesign              bit            = 0
    , @MitStatistikverteilung       bit            = 0
    , @MitIQP                       bit            = 0
    , @MitContention                bit            = 0
    , @ContentionSampleSeconds      tinyint         = 5
    , @ContentionMinWaitMs          bigint          = 1000
    , @ParentIntegrityJson          nvarchar(max)   = NULL
    , @ParentCapacityJson           nvarchar(max)   = NULL
    , @ParentBufferPoolJson         nvarchar(max)   = NULL
    , @NurAbPrioritaet              varchar(16)     = 'INFO'
    , @MaxZeilen                    int             = 1000
    , @ResultSetArt                 varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit             = 0
    , @Json                         nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen               bit             = 1
    , @Hilfe                        bit             = 0
    , @StatusCodeOut                varchar(40)     = NULL OUTPUT
    , @IsPartialOut                 bit             = NULL OUTPUT
    , @ErrorNumberOut               int             = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048)  = NULL OUTPUT
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
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'findings',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @MinimumSeverity varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@NurAbPrioritaet, ''))));
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
                                 THEN CONVERT(bigint, 9223372036854775807)
                                 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_DiagnosticFindings';
        PRINT N'Aggregiert Befunde aus den Spezialfallmodulen; verändert keine Konfiguration und maskiert keine Resultsets.';
        PRINT N'Kostenintensive Schema-, Statistikverteilungs-, IQP- und Contention-Module sind standardmäßig deaktiviert.';
        PRINT N'@NurAbPrioritaet=INFO|LOW|MEDIUM|HIGH; @MaxZeilen positiv, NULL/0 = unbegrenzt.';
        PRINT N'@Parent...Json dient ausschließlich der Wiederverwendung bereits erhobener Ergebnisse innerhalb eines Orchestratoraufrufs; NULL liest frisch.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CurrentCompatibilityLevel int =
        (SELECT [compatibility_level] FROM [sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());

    DECLARE @IntegrityJson nvarchar(max) = @ParentIntegrityJson;
    DECLARE @CapacityJson nvarchar(max) = @ParentCapacityJson;
    DECLARE @MemoryJson nvarchar(max) = @ParentBufferPoolJson;
    DECLARE @BackupJson nvarchar(max) = NULL;
    DECLARE @AvailabilityJson nvarchar(max) = NULL;
    DECLARE @AgentJson nvarchar(max) = NULL;
    DECLARE @SchemaJson nvarchar(max) = NULL;
    DECLARE @StatisticsDistributionJson nvarchar(max) = NULL;
    DECLARE @IqpJson nvarchar(max) = NULL;
    DECLARE @ContentionJson nvarchar(max) = NULL;
    DECLARE @ChildStatus varchar(40);
    DECLARE @ChildPartial bit;
    DECLARE @ChildErrorNumber int;
    DECLARE @ChildErrorMessage nvarchar(2048);

    DECLARE @ModuleStatus TABLE
    (
          [ExecutionOrdinal] tinyint NOT NULL
        , [ModuleName] sysname NOT NULL
        , [InvocationStatus] varchar(40) NOT NULL
        , [EvidenceStatus] varchar(40) NULL
        , [IsPartial] bit NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#DiagnosticFindings_Findings]
    (
          [FindingOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [SourceModule] sysname NOT NULL
        , [Category] varchar(60) NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [Confidence] varchar(16) NOT NULL
        , [ScopeType] nvarchar(60) NOT NULL
        , [ScopeName] nvarchar(512) NULL
        , [FindingCode] varchar(120) NOT NULL
        , [EvidenceMetric] decimal(38,4) NULL
        , [Evidence] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , [RecommendedNextCheck] nvarchar(1000) NOT NULL
    );

    IF @MaxZeilen < 0 OR @ContentionSampleSeconds > 60
       OR @ContentionMinWaitMs < 0
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR @MinimumSeverity NOT IN ('INFO', 'LOW', 'MEDIUM', 'HIGH')
       OR (@ParentIntegrityJson IS NOT NULL AND ISJSON(@ParentIntegrityJson)<>1)
       OR (@ParentCapacityJson IS NOT NULL AND ISJSON(@ParentCapacityJson)<>1)
       OR (@ParentBufferPoolJson IS NOT NULL AND ISJSON(@ParentBufferPoolJson)<>1)
       OR (@MitIntegritaet = 0 AND @MitKapazitaet = 0 AND @MitSpeicher = 0
           AND @MitBackupketten = 0 AND @MitAvailability = 0 AND @MitAgentMonitoring = 0
           AND @MitSchemaDesign = 0 AND @MitStatistikverteilung = 0
           AND @MitIQP = 0 AND @MitContention = 0)
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Modul-, Datenbank-, Sample-, Prioritäts-, Zeilen- oder Ausgabeparameter.';
    END
    ELSE IF (@ParentIntegrityJson IS NOT NULL
             AND (COALESCE(JSON_VALUE(@ParentIntegrityJson,'$.meta.resultName'),'')<>'DatabaseIntegrityAnalysis'
                  OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ParentIntegrityJson,'$.meta.schemaVersion')),0)<>1))
         OR (@ParentCapacityJson IS NOT NULL
             AND (COALESCE(JSON_VALUE(@ParentCapacityJson,'$.meta.resultName'),'')<>'DatabaseCapacityAnalysis'
                  OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ParentCapacityJson,'$.meta.schemaVersion')),0)<>1))
         OR (@ParentBufferPoolJson IS NOT NULL
             AND (COALESCE(JSON_VALUE(@ParentBufferPoolJson,'$.meta.resultName'),'')<>'BufferPoolAnalysis'
                  OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ParentBufferPoolJson,'$.meta.schemaVersion')),0)<>1))
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ein Parent-Ergebnis entspricht nicht dem erwarteten JSON-Vertrag.';
    END
    ELSE IF @CurrentCompatibilityLevel < 130
    BEGIN
        SELECT @StatusCode = 'UNAVAILABLE_FEATURE', @IsPartial = 1,
               @ErrorMessage = N'Die Befundaggregation benötigt Compatibility Level 130 oder höher für OPENJSON.';
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitIntegritaet = 1
    BEGIN
        IF @ParentIntegrityJson IS NOT NULL
        BEGIN
            SELECT @ChildStatus=JSON_VALUE(@IntegrityJson,'$.meta.statusCode'),
                   @ChildPartial=CASE JSON_VALUE(@IntegrityJson,'$.meta.isPartial')
                                      WHEN 'true' THEN 1 WHEN 'false' THEN 0
                                      ELSE COALESCE(TRY_CONVERT(bit,JSON_VALUE(@IntegrityJson,'$.meta.isPartial')),1) END,
                   @ChildErrorNumber=TRY_CONVERT(int,JSON_VALUE(@IntegrityJson,'$.meta.errorNumber')),
                   @ChildErrorMessage=JSON_VALUE(@IntegrityJson,'$.meta.errorMessage');
            INSERT @ModuleStatus VALUES (1,N'USP_DatabaseIntegrityAnalysis','REUSED_PARENT_RESULT',@ChildStatus,@ChildPartial,@ChildErrorNumber,@ChildErrorMessage);
        END
        ELSE
        BEGIN
            BEGIN TRY
                SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
                EXEC [monitor].[USP_DatabaseIntegrityAnalysis]
                      @DatabaseNames = @DatabaseNames, @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                    , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                    , @MitPageDetails = 0, @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE'
                    , @JsonErzeugen = 1, @Json = @IntegrityJson OUTPUT, @PrintMeldungen = @PrintMeldungen
                    , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                    , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
                INSERT @ModuleStatus VALUES (1, N'USP_DatabaseIntegrityAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
            END TRY
            BEGIN CATCH
                INSERT @ModuleStatus VALUES (1, N'USP_DatabaseIntegrityAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
            END CATCH;
        END;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitKapazitaet = 1
    BEGIN
        IF @ParentCapacityJson IS NOT NULL
        BEGIN
            SELECT @ChildStatus=JSON_VALUE(@CapacityJson,'$.meta.statusCode'),
                   @ChildPartial=CASE JSON_VALUE(@CapacityJson,'$.meta.isPartial')
                                      WHEN 'true' THEN 1 WHEN 'false' THEN 0
                                      ELSE COALESCE(TRY_CONVERT(bit,JSON_VALUE(@CapacityJson,'$.meta.isPartial')),1) END,
                   @ChildErrorNumber=TRY_CONVERT(int,JSON_VALUE(@CapacityJson,'$.meta.errorNumber')),
                   @ChildErrorMessage=JSON_VALUE(@CapacityJson,'$.meta.errorMessage');
            INSERT @ModuleStatus VALUES (2,N'USP_DatabaseCapacityAnalysis','REUSED_PARENT_RESULT',@ChildStatus,@ChildPartial,@ChildErrorNumber,@ChildErrorMessage);
        END
        ELSE
        BEGIN
            BEGIN TRY
                SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
                EXEC [monitor].[USP_DatabaseCapacityAnalysis]
                      @DatabaseNames = @DatabaseNames, @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                    , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                    , @NurProblematisch = 0, @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE'
                    , @JsonErzeugen = 1, @Json = @CapacityJson OUTPUT, @PrintMeldungen = @PrintMeldungen
                    , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                    , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
                INSERT @ModuleStatus VALUES (2, N'USP_DatabaseCapacityAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
            END TRY
            BEGIN CATCH
                INSERT @ModuleStatus VALUES (2, N'USP_DatabaseCapacityAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
            END CATCH;
        END;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitSpeicher = 1
    BEGIN
        IF @ParentBufferPoolJson IS NOT NULL
        BEGIN
            SELECT @ChildStatus=JSON_VALUE(@MemoryJson,'$.meta.statusCode'),
                   @ChildPartial=CASE JSON_VALUE(@MemoryJson,'$.meta.isPartial')
                                      WHEN 'true' THEN 1 WHEN 'false' THEN 0
                                      ELSE COALESCE(TRY_CONVERT(bit,JSON_VALUE(@MemoryJson,'$.meta.isPartial')),1) END,
                   @ChildErrorNumber=TRY_CONVERT(int,JSON_VALUE(@MemoryJson,'$.meta.errorNumber')),
                   @ChildErrorMessage=JSON_VALUE(@MemoryJson,'$.meta.errorMessage');
            INSERT @ModuleStatus VALUES (3,N'USP_BufferPoolAnalysis','REUSED_PARENT_RESULT',@ChildStatus,@ChildPartial,@ChildErrorNumber,@ChildErrorMessage);
        END
        ELSE
        BEGIN
            BEGIN TRY
                SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
                EXEC [monitor].[USP_BufferPoolAnalysis]
                      @MitMemoryClerks = 0, @MitBufferPoolVerteilung = 0, @MaxZeilen = @MaxZeilen
                    , @ResultSetArt = 'NONE', @JsonErzeugen = 1, @Json = @MemoryJson OUTPUT
                    , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                    , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                    , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
                INSERT @ModuleStatus VALUES (3, N'USP_BufferPoolAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
            END TRY
            BEGIN CATCH
                INSERT @ModuleStatus VALUES (3, N'USP_BufferPoolAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
            END CATCH;
        END;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitBackupketten = 1
    BEGIN
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_BackupChainAnalysis]
                  @DatabaseNames = @DatabaseNames, @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE', @JsonErzeugen = 1, @Json = @BackupJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT @ModuleStatus VALUES (4, N'USP_BackupChainAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (4, N'USP_BackupChainAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitAvailability = 1
    BEGIN
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_AvailabilityDeepAnalysis]
                  @MitClusterNetzwerken = 0, @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE'
                , @JsonErzeugen = 1, @Json = @AvailabilityJson OUTPUT, @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT @ModuleStatus VALUES (5, N'USP_AvailabilityDeepAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (5, N'USP_AvailabilityDeepAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitAgentMonitoring = 1
    BEGIN
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_AgentMonitoringAnalysis]
                  @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE', @JsonErzeugen = 1, @Json = @AgentJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT @ModuleStatus VALUES (6, N'USP_AgentMonitoringAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (6, N'USP_AgentMonitoringAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitSchemaDesign = 1
    BEGIN
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_SchemaDesignAnalysis]
                  @DatabaseNames = @DatabaseNames, @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE', @JsonErzeugen = 1, @Json = @SchemaJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT @ModuleStatus VALUES (7, N'USP_SchemaDesignAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (7, N'USP_SchemaDesignAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitStatistikverteilung = 1
    BEGIN
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_StatisticsDistributionAnalysis]
                  @DatabaseNames = @DatabaseNames, @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed, @AnalyseModus = 'VOLL'
                , @MaxZeilen = @MaxZeilen
                , @ResultSetArt = 'NONE', @JsonErzeugen = 1, @Json = @StatisticsDistributionJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT @ModuleStatus VALUES (8, N'USP_StatisticsDistributionAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (8, N'USP_StatisticsDistributionAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitIQP = 1
    BEGIN
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis]
                  @DatabaseNames = @DatabaseNames, @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
                , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
                , @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE', @JsonErzeugen = 1, @Json = @IqpJson OUTPUT
                , @PrintMeldungen = @PrintMeldungen, @StatusCodeOut = @ChildStatus OUTPUT
                , @IsPartialOut = @ChildPartial OUTPUT, @ErrorNumberOut = @ChildErrorNumber OUTPUT
                , @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT @ModuleStatus VALUES (9, N'USP_IntelligentQueryProcessingAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (9, N'USP_IntelligentQueryProcessingAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE' AND @MitContention = 1
    BEGIN
        BEGIN TRY
            SELECT @ChildStatus = NULL, @ChildPartial = NULL, @ChildErrorNumber = NULL, @ChildErrorMessage = NULL;
            EXEC [monitor].[USP_InternalContentionAnalysis]
                  @SampleSeconds = @ContentionSampleSeconds, @MitSpinlocks = 1, @MitHotPages = 1
                , @MitPageDetails = 0, @MaxZeilen = @MaxZeilen, @ResultSetArt = 'NONE'
                , @JsonErzeugen = 1, @Json = @ContentionJson OUTPUT, @PrintMeldungen = @PrintMeldungen
                , @StatusCodeOut = @ChildStatus OUTPUT, @IsPartialOut = @ChildPartial OUTPUT
                , @ErrorNumberOut = @ChildErrorNumber OUTPUT, @ErrorMessageOut = @ChildErrorMessage OUTPUT;
            INSERT @ModuleStatus VALUES (10, N'USP_InternalContentionAnalysis', 'EXECUTED', @ChildStatus, @ChildPartial, @ChildErrorNumber, @ChildErrorMessage);
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (10, N'USP_InternalContentionAnalysis', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE @ParseSql nvarchar(max) = N'
INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_DatabaseIntegrityAnalysis'', ''INTEGRITY'',
       CASE WHEN [FindingCode] IN (''SUSPECT_PAGES_PRESENT'',''DAMAGED_BACKUP_METADATA'',''HADR_PAGE_REPAIR_PENDING'') THEN ''HIGH''
            WHEN [FindingCode] IN (''CHECKDB_EVIDENCE_MISSING'',''CHECKDB_EVIDENCE_OLD'') THEN ''MEDIUM'' ELSE ''LOW'' END,
       ''HIGH'', N''DATABASE'', [DatabaseName], [FindingCode],
       CONVERT(decimal(38,4), CASE WHEN [SuspectPageCount] > 0 THEN [SuspectPageCount]
                                  WHEN [DamagedBackupCount] > 0 THEN [DamagedBackupCount]
                                  ELSE [CheckdbAgeHours] END),
       CONCAT(N''Suspect pages='', [SuspectPageCount], N''; damaged backups='', [DamagedBackupCount],
              N''; CHECKDB age hours='', COALESCE(CONVERT(nvarchar(40), [CheckdbAgeHours]), N''NULL''), N''.''),
       [EvidenceLimit], N''CHECKDB-/Backup-/Seitenreparaturevidenz kontrolliert verifizieren.''
FROM OPENJSON(COALESCE(@Integrity, N''{}''), ''$.integrity'') WITH
([DatabaseName] sysname, [FindingCode] varchar(80), [SuspectPageCount] bigint,
 [DamagedBackupCount] bigint, [CheckdbAgeHours] bigint, [EvidenceLimit] nvarchar(1000))
WHERE [FindingCode] <> ''NO_INDICATOR_FOUND'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_DatabaseCapacityAnalysis'', ''CAPACITY'',
       CASE WHEN [FindingCode] IN (''FILE_MAX_SIZE_REACHED'',''NEXT_GROWTH_EXCEEDS_VOLUME_FREE'') THEN ''HIGH'' ELSE ''MEDIUM'' END,
       ''HIGH'', N''DATABASE_FILE'', CONCAT([DatabaseName], N''/'', [LogicalFileName]), [FindingCode],
       CONVERT(decimal(38,4), [VolumeFreePercent]),
       CONCAT(N''file free MB='', [FreeInFileMb], N''; volume free MB='', [VolumeAvailableMb],
              N''; next growth MB='', COALESCE(CONVERT(nvarchar(40), [NextGrowthMb]), N''NULL''), N''.''),
       [EvidenceLimit], N''Datei-, Volume- und Growth-Konfiguration gemeinsam prüfen; ohne Historie keine Zeit-bis-voll-Prognose.''
FROM OPENJSON(COALESCE(@Capacity, N''{}''), ''$.capacity'') WITH
([DatabaseName] sysname, [LogicalFileName] sysname, [FreeInFileMb] decimal(19,2),
 [VolumeAvailableMb] decimal(19,2), [VolumeFreePercent] decimal(9,2), [NextGrowthMb] decimal(19,2),
 [FindingCode] varchar(80), [EvidenceLimit] nvarchar(1000))
WHERE [FindingCode] <> ''NO_CAPACITY_INDICATOR'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_BufferPoolAnalysis'', ''MEMORY'', [FindingSeverity], ''HIGH'', N''INSTANCE'', NULL,
       [FindingCode], CONVERT(decimal(38,4), [AvailablePhysicalMemoryPercent]),
       CONCAT(N''OS available percent='', [AvailablePhysicalMemoryPercent],
              N''; process physical low='', [ProcessPhysicalMemoryLow],
              N''; process virtual low='', [ProcessVirtualMemoryLow], N''.''),
       [EvidenceLimit], N''Mit Verlauf, Resource Semaphores, anderen Prozessen und OS-Grenzen korrelieren.''
FROM OPENJSON(COALESCE(@Memory, N''{}''), ''$.memory'') WITH
([FindingCode] varchar(80), [FindingSeverity] varchar(16), [AvailablePhysicalMemoryPercent] decimal(9,2),
 [ProcessPhysicalMemoryLow] bit, [ProcessVirtualMemoryLow] bit, [EvidenceLimit] nvarchar(1000))
WHERE [FindingCode] <> ''NO_MEMORY_PRESSURE_FLAG'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_BufferPoolAnalysis'', ''MEMORY_GRANTS'', ''HIGH'', ''HIGH'', N''RESOURCE_SEMAPHORE'',
       CONCAT(N''pool='', [PoolId], N''; semaphore='', [ResourceSemaphoreId]), ''MEMORY_GRANT_WAITERS_PRESENT'',
       CONVERT(decimal(38,4), [WaiterCount]),
       CONCAT(N''waiters='', [WaiterCount], N''; available KB='', [AvailableMemoryKb], N''; granted KB='', [GrantedMemoryKb], N''.''),
       N''Momentaufnahme; kurzzeitige Wartende sind nicht automatisch ein dauerhaftes Kapazitätsproblem.'',
       N''Memory-Grant-Verlauf, Workload und Resource-Governor-Pool korrelieren.''
FROM OPENJSON(COALESCE(@Memory, N''{}''), ''$.resourceSemaphores'') WITH
([PoolId] int, [ResourceSemaphoreId] int, [AvailableMemoryKb] bigint, [GrantedMemoryKb] bigint, [WaiterCount] int)
WHERE [WaiterCount] > 0;

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_BackupChainAnalysis'', ''RECOVERABILITY'', [FindingSeverity], ''MEDIUM'', N''DATABASE'', [DatabaseName],
       [FindingCode], CONVERT(decimal(38,4), [LogGapCountInWindow]),
       CONCAT(N''log gaps='', [LogGapCountInWindow], N''; damaged='', [DamagedBackupCount],
              N''; without checksum='', [BackupWithoutChecksumCount], N''.''),
       [EvidenceLimit], N''Backuphistorie und Medien prüfen; Wiederherstellbarkeit durch kontrollierten Test-Restore belegen.''
FROM OPENJSON(COALESCE(@Backup, N''{}''), ''$.summary'') WITH
([DatabaseName] sysname, [FindingCode] varchar(100), [FindingSeverity] varchar(16),
 [LogGapCountInWindow] bigint, [DamagedBackupCount] bigint, [BackupWithoutChecksumCount] bigint,
 [EvidenceLimit] nvarchar(1000))
WHERE [FindingCode] NOT IN (''CHAIN_METADATA_CONSISTENT'',''TEMPDB_NOT_APPLICABLE'');

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_AvailabilityDeepAnalysis'', ''AVAILABILITY'', [FindingSeverity], ''HIGH'', N''AG_DATABASE'',
       CONCAT([AvailabilityGroupName], N''/'', [DatabaseName]), [FindingCode],
       CONVERT(decimal(38,4), COALESCE([SecondaryLagSeconds], [LogSendQueueSizeKb], [RedoQueueSizeKb])),
       CONCAT(N''log send queue KB='', [LogSendQueueSizeKb], N''; redo queue KB='', [RedoQueueSizeKb],
              N''; lag seconds='', [SecondaryLagSeconds], N''; suspended='', [IsSuspended], N''.''),
       N''Momentaufnahme; Queuegröße und Lag benötigen Verlauf und Rate.'',
       N''Replikazustand, Datenbewegung, Netzwerk und Clusterereignisse korrelieren.''
FROM OPENJSON(COALESCE(@Availability, N''{}''), ''$.databases'') WITH
([AvailabilityGroupName] sysname, [DatabaseName] sysname, [FindingCode] varchar(100),
 [FindingSeverity] varchar(16), [SecondaryLagSeconds] bigint, [LogSendQueueSizeKb] bigint,
 [RedoQueueSizeKb] bigint, [IsSuspended] bit)
WHERE [FindingCode] <> ''DATABASE_STATE_ACCEPTABLE'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_AvailabilityDeepAnalysis'', ''AVAILABILITY'',
       CASE WHEN [FindingCode] = ''QUORUM_STATE_NOT_VISIBLE'' THEN ''HIGH'' ELSE ''MEDIUM'' END,
       ''MEDIUM'', N''CLUSTER'', NULL, [FindingCode], NULL,
       CONCAT(N''quorum state='', COALESCE([QuorumStateDesc], N''NOT_VISIBLE''), N''.''),
       N''Cluster-DMV-Evidenz kann auf Linux- oder Read-Scale-Ausprägungen interne beziehungsweise nicht anwendbare Werte zeigen.'',
       N''Clusterquorum und Plattformzustand außerhalb der SQL-Instanz verifizieren.''
FROM OPENJSON(COALESCE(@Availability, N''{}''), ''$.cluster'') WITH
([QuorumStateDesc] nvarchar(60), [FindingCode] varchar(80))
WHERE [FindingCode] <> ''QUORUM_STATE_NORMAL'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_AvailabilityDeepAnalysis'', ''AVAILABILITY'', ''HIGH'', ''HIGH'', N''AG_REPLICA'',
       CONCAT([AvailabilityGroupName], N''/'', [ReplicaServerName]), [FindingCode], NULL,
       CONCAT(N''role='', COALESCE([RoleDesc], N''NULL''), N''; connection='', COALESCE([ConnectedStateDesc], N''NULL''),
              N''; health='', COALESCE([SynchronizationHealthDesc], N''NULL''), N''.''),
       N''Momentaufnahme; Remote-Replikazustände können vom lokalen Sichtpunkt unvollständig sein.'',
       N''Endpoint, Netzwerk, Replikarolle und Clusterereignisse korrelieren.''
FROM OPENJSON(COALESCE(@Availability, N''{}''), ''$.replicas'') WITH
([AvailabilityGroupName] sysname, [ReplicaServerName] nvarchar(256), [RoleDesc] nvarchar(60),
 [ConnectedStateDesc] nvarchar(60), [SynchronizationHealthDesc] nvarchar(60), [FindingCode] varchar(80))
WHERE [FindingCode] <> ''REPLICA_STATE_ACCEPTABLE'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_AvailabilityDeepAnalysis'', ''AVAILABILITY'', ''HIGH'', ''HIGH'', N''DATABASE'',
       [DatabaseName], [FindingCode], CONVERT(decimal(38,4), [PageStatus]),
       CONCAT(N''page repair status='', COALESCE(CONVERT(nvarchar(20), [PageStatus]), N''NULL''),
              N''; error type='', COALESCE(CONVERT(nvarchar(20), [ErrorType]), N''NULL''), N''.''),
       N''Automatische Seitenreparatur ist Einzelevidenz und ersetzt keine Integritätsprüfung.'',
       N''Seitenreparatur-, suspect_pages-, CHECKDB- und Backup-Evidenz gemeinsam prüfen.''
FROM OPENJSON(COALESCE(@Availability, N''{}''), ''$.pageRepair'') WITH
([DatabaseName] sysname, [ErrorType] int, [PageStatus] int, [FindingCode] varchar(80))
WHERE [FindingCode] <> ''PAGE_REPAIR_SUCCEEDED'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_AvailabilityDeepAnalysis'', ''AVAILABILITY'', ''HIGH'', ''MEDIUM'', N''DATABASE'',
       [DatabaseName], ''PHYSICAL_SEEDING_FAILURE'', CONVERT(decimal(38,4), [FailureCode]),
       CONCAT(N''seeding state='', COALESCE([CurrentStateDesc], N''NULL''),
              N''; failure code='', [FailureCode], N''.''),
       N''Die DMV zeigt nur aktuell aufbewahrte Seeding-Evidenz.'',
       N''Seedingstatus, Endpoint, Berechtigungen, Speicher und Netzwerk prüfen.''
FROM OPENJSON(COALESCE(@Availability, N''{}''), ''$.seeding'') WITH
([DatabaseName] sysname, [CurrentStateDesc] nvarchar(60), [FailureCode] int)
WHERE COALESCE([FailureCode], 0) <> 0;

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_AgentMonitoringAnalysis'', ''MONITORING'', [Severity], ''MEDIUM'', [ScopeType], [ScopeName],
       [FindingCode], CONVERT(decimal(38,4), [MetricValue]), [Evidence], [EvidenceLimit],
       N''SQL-Agent-Konfiguration mit externem Monitoring und Betriebsprozess abgleichen.''
FROM OPENJSON(COALESCE(@Agent, N''{}''), ''$.findings'') WITH
([Severity] varchar(16), [ScopeType] nvarchar(60), [ScopeName] nvarchar(256), [FindingCode] varchar(100),
 [MetricValue] bigint, [Evidence] nvarchar(1000), [EvidenceLimit] nvarchar(1000));

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_SchemaDesignAnalysis'', ''SCHEMA_DESIGN'', [Severity], ''HIGH'', [ObjectType],
       CONCAT([DatabaseName], N''/'', COALESCE([SchemaName] + N''.'', N''''), [ObjectName]),
       [FindingCode], [MetricValue], [Evidence], [EvidenceLimit],
       N''Workload, Abhängigkeiten und Änderungsrisiko vor DDL separat verifizieren.''
FROM OPENJSON(COALESCE(@Schema, N''{}''), ''$.findings'') WITH
([DatabaseName] sysname, [Severity] varchar(16), [ObjectType] nvarchar(60), [SchemaName] sysname,
 [ObjectName] sysname, [FindingCode] varchar(100), [MetricValue] decimal(38,4),
 [Evidence] nvarchar(1000), [EvidenceLimit] nvarchar(1000));

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_StatisticsDistributionAnalysis'', ''STATISTICS_DISTRIBUTION'', [Severity], [Confidence], N''STATISTICS'',
       CONCAT([DatabaseName],N''/'',[SchemaName],N''.'',[ObjectName],N''/'',[StatisticsName]),
       [FindingCode],[MetricValue],[Evidence],[EvidenceLimit],[RecommendedNextCheck]
FROM OPENJSON(COALESCE(@StatisticsDistribution, N''{}''), ''$.findings'') WITH
([DatabaseName] sysname, [SchemaName] sysname, [ObjectName] sysname, [StatisticsName] sysname,
 [Severity] varchar(16), [Confidence] varchar(16), [FindingCode] varchar(120),
 [MetricValue] decimal(38,4), [Evidence] nvarchar(1000), [EvidenceLimit] nvarchar(1000),
 [RecommendedNextCheck] nvarchar(1000));

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_IntelligentQueryProcessingAnalysis'', ''IQP'', [FindingSeverity], ''HIGH'', N''DATABASE'',
       [DatabaseName], [FindingCode], CONVERT(decimal(38,4), [CompatibilityLevel]),
       CONCAT(N''compatibility level='', [CompatibilityLevel], N''; query store='', [QueryStoreActualStateDesc], N''.''),
       [EvidenceLimit], N''Query-Store-Zustand und beabsichtigtes Compatibility Level prüfen.''
FROM OPENJSON(COALESCE(@Iqp, N''{}''), ''$.databaseState'') WITH
([DatabaseName] sysname, [CompatibilityLevel] int, [QueryStoreActualStateDesc] nvarchar(60),
 [FindingCode] varchar(80), [FindingSeverity] varchar(16), [EvidenceLimit] nvarchar(1000))
WHERE [FindingCode] <> ''IQP_EVIDENCE_AVAILABLE'';

INSERT [#DiagnosticFindings_Findings] ([SourceModule],[Category],[Severity],[Confidence],[ScopeType],[ScopeName],[FindingCode],[EvidenceMetric],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
SELECT N''USP_InternalContentionAnalysis'', ''INTERNAL_CONTENTION'', ''MEDIUM'', ''MEDIUM'', N''LATCH'',
       [LatchClass], ''LATCH_WAIT_DELTA_REVIEW'', CONVERT(decimal(38,4), [WaitTimeMs]),
       CONCAT(N''wait time ms='', [WaitTimeMs], N''; waiting requests='', [WaitingRequests], N''; measurement='', [MeasurementKind], N''.''),
       N''Latchklasse und kurzes Intervall sind noch keine Ursachenfeststellung.'',
       N''Messung wiederholen und mit Workload, Waits und Hot Pages korrelieren.''
FROM OPENJSON(COALESCE(@Contention, N''{}''), ''$.latches'') WITH
([LatchClass] nvarchar(120), [MeasurementKind] varchar(30), [WaitingRequests] bigint, [WaitTimeMs] bigint)
WHERE [WaitTimeMs] >= @ContentionMinWaitMs;';

        BEGIN TRY
            EXEC [sys].[sp_executesql]
                  @ParseSql
                , N'@Integrity nvarchar(max), @Capacity nvarchar(max), @Memory nvarchar(max),
                    @Backup nvarchar(max), @Availability nvarchar(max), @Agent nvarchar(max),
                    @Schema nvarchar(max), @StatisticsDistribution nvarchar(max), @Iqp nvarchar(max), @Contention nvarchar(max),
                    @ContentionMinWaitMs bigint'
                , @Integrity = @IntegrityJson, @Capacity = @CapacityJson, @Memory = @MemoryJson
                , @Backup = @BackupJson, @Availability = @AvailabilityJson, @Agent = @AgentJson
                , @Schema = @SchemaJson, @StatisticsDistribution = @StatisticsDistributionJson
                , @Iqp = @IqpJson, @Contention = @ContentionJson
                , @ContentionMinWaitMs = @ContentionMinWaitMs;
        END TRY
        BEGIN CATCH
            INSERT @ModuleStatus VALUES (11, N'JSON_EVIDENCE_AGGREGATION', 'ERROR_HANDLED', NULL, 1, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;

        IF EXISTS
        (
            SELECT 1 FROM @ModuleStatus
            WHERE [InvocationStatus] NOT IN ('EXECUTED','REUSED_PARENT_RESULT')
               OR COALESCE([IsPartial], 0) = 1
               OR [EvidenceStatus] IN ('DENIED_PERMISSION','ERROR_HANDLED','DATABASE_UNAVAILABLE','UNAVAILABLE_FEATURE')
        )
        BEGIN
            SELECT @StatusCode = 'AVAILABLE_LIMITED', @IsPartial = 1;
            SELECT TOP (1) @ErrorNumber = [ErrorNumber], @ErrorMessage = [ErrorMessage]
            FROM @ModuleStatus
            WHERE [InvocationStatus] NOT IN ('EXECUTED','REUSED_PARENT_RESULT') OR COALESCE([IsPartial], 0) = 1
            ORDER BY [ExecutionOrdinal];
        END
        ELSE IF EXISTS (SELECT 1 FROM [#DiagnosticFindings_Findings])
            SET @StatusCode = 'AVAILABLE_WITH_FINDING';
    END;

    SELECT @StatusCodeOut = @StatusCode, @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber, @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
            (SELECT N'DiagnosticFindings' AS [resultName], 1 AS [schemaVersion], @Now AS [generatedAtUtc],
                    @StatusCode AS [statusCode], @IsPartial AS [isPartial], @MinimumSeverity AS [minimumSeverity],
                    (SELECT COUNT_BIG(*) FROM [#DiagnosticFindings_Findings]) AS [totalFindingCount],
                    (SELECT COUNT_BIG(*) FROM [#DiagnosticFindings_Findings]
                     WHERE CASE [Severity] WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END
                           >= CASE @MinimumSeverity WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END)
                    AS [returnedFindingCount]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @FindingsJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#DiagnosticFindings_Findings]
             WHERE CASE [Severity] WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END
                   >= CASE @MinimumSeverity WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END
             ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,
                      [FindingOrdinal] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @ModulesJson nvarchar(max) =
            (SELECT * FROM @ModuleStatus ORDER BY [ExecutionOrdinal] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'),
                           N',"findings":', COALESCE(@FindingsJson, N'[]'),
                           N',"modules":', COALESCE(@ModulesJson, N'[]'), N'}');
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_DiagnosticFindings' AS [ModuleName], @Now AS [CollectionTimeUtc],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               (SELECT COUNT_BIG(*) FROM [#DiagnosticFindings_Findings]) AS [FindingCount],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'Normalisierte Triage über Kindmodul-Evidenz; keine automatische Ursachenfeststellung.' AS [Detail];
        SELECT TOP (@Limit) * FROM [#DiagnosticFindings_Findings]
        WHERE CASE [Severity] WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END
              >= CASE @MinimumSeverity WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END
        ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,
                 [FindingOrdinal];
        SELECT * FROM @ModuleStatus ORDER BY [ExecutionOrdinal];
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Diagnostische Befunde' AS [Ergebnis], @Now AS [Stand_UTC], @StatusCode AS [Status],
               @MinimumSeverity AS [Mindestprioritaet], (SELECT COUNT_BIG(*) FROM [#DiagnosticFindings_Findings]) AS [Befunde_gesamt],
               @ErrorMessage AS [Hinweis];
        SELECT TOP (@Limit) N'Diagnostischer Befund' AS [Ergebnis], [Severity] AS [Prioritaet],
               [Confidence] AS [Konfidenz], [Category] AS [Kategorie], [ScopeType] AS [Bereichstyp],
               [ScopeName] AS [Bereich], [FindingCode] AS [Befund], [EvidenceMetric] AS [Messwert],
               [Evidence] AS [Evidenz], [EvidenceLimit] AS [Grenze], [RecommendedNextCheck] AS [Naechste_Pruefung]
        FROM [#DiagnosticFindings_Findings]
        WHERE CASE [Severity] WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END
              >= CASE @MinimumSeverity WHEN 'HIGH' THEN 4 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 2 ELSE 1 END
        ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,
                 [FindingOrdinal];
        SELECT N'Befund-Quellmodul' AS [Ergebnis], [ExecutionOrdinal] AS [Reihenfolge],
               [ModuleName] AS [Modul], [InvocationStatus] AS [Aufrufstatus],
               [EvidenceStatus] AS [Evidenzstatus], [IsPartial] AS [Teilweise], [ErrorMessage] AS [Fehler]
        FROM @ModuleStatus ORDER BY [ExecutionOrdinal];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#DiagnosticFindings_Findings'
            , @ResultLabel=N'DiagnosticFindings'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#DiagnosticFindings_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
