USE [DeineDatenbank];
GO

-- Hilfe
EXEC [monitor].[USP_AnalysisNavigator] @Hilfe=1;
-- Geeignete Analyse nach Symptom finden; führt keinen Treffer aus
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff=N'Benutzer warten'
    , @MaxZeilen=8
    , @ResultSetArt='CONSOLE';
-- Priorisierte sichere Einstiege ohne Suchbegriff
EXEC [monitor].[USP_AnalysisNavigator]
      @NurInstallierte=1
    , @ResultSetArt='CONSOLE';

EXEC [monitor].[USP_CurrentOverview] @Hilfe=1;
-- Aktuelle Übersicht, Console
EXEC [monitor].[USP_CurrentOverview] @MaxZeilen=100,@ResultSetArt='console';
-- Erkannte Tool-Hintergrundaktivität bewusst einblenden
EXEC [monitor].[USP_CurrentOverview]
      @ToolHintergrundabfragenEinbeziehen=1
    , @Detailgrad='RELEVANT'
    , @MaxZeilen=100
    , @ResultSetArt='CONSOLE';
-- Aktive metadatengetriebene LIKE-Regeln prüfen
SELECT [RuleCode],[Priority],[ProgramNameLikePattern],[ToolBackgroundCategory],
       [ToolBackgroundConfidence],[SourceUrl]
FROM [monitor].[ToolBackgroundQueryPattern] WITH (NOLOCK)
WHERE [IsEnabled]=1
ORDER BY [Priority] DESC,[RuleCode];
-- Zwei Datenbanken exakt
EXEC [monitor].[USP_ObjectInventory] @DatabaseNames=N'[DeineDatenbank]|[BeispielDatenbankB]',@AnalyseModus='VOLL',@MaxZeilen=200;
-- Query Store aller zum Pattern passenden Datenbanken, globales Top 100
EXEC [monitor].[USP_QueryStoreRuntimeStats] @QueryStoreDatabaseNames=NULL,@QueryStoreDatabaseNamePattern=N'like:Database_%',@MaxZeilen=100;
-- Memory Grants einschließlich Resource Governor
EXEC [monitor].[USP_CurrentMemoryGrants] @NurWartende=0,@MaxZeilen=100,@ResultSetArt='CONSOLE';

-- Datei-I/O plus flüchtige Pending-I/O-Evidenz; physische Pfade bleiben aus
EXEC [monitor].[USP_CurrentIO]
      @DatabaseNames=N'[DeineDatenbank]'
    , @SampleSeconds=5
    , @PendingIoEinbeziehen=1
    , @NurWiederholtPending=0
    , @PhysischePfadeEinbeziehen=0
    , @MaxZeilen=100;

-- Worker Queue und CPU-Runnable-Queue getrennt auswerten
EXEC [monitor].[USP_WorkerPressureAnalysis]
      @SampleSeconds=1
    , @MinRequestElapsedMs=5000
    , @MaxZeilen=100;

-- Lokale Konfigurationsvariation ohne universelles Sollprofil
EXEC [monitor].[USP_DatabaseConfigurationAnalysis]
      @DatabaseNames=N'[DeineDatenbank]'
    , @MaxZeilen=200;

-- Aktuelles SQL-Server-Errorlog, kategorisiert und ohne Meldungsvolltext
EXEC [monitor].[USP_ErrorLogAnalysis]
      @MaxArchivNummer=0
    , @MeldungstextEinbeziehen=0
    , @MaxQuellzeilen=10000
    , @MaxZeilen=100;

-- Primäres typisiertes Ergebnis in einer lokalen Temp-Tabelle weiterverarbeiten
CREATE TABLE [#Schnellreferenz_Aufrufe_RequestResult] ([Dummy] int NULL);
EXEC [monitor].[USP_CurrentRequests]
      @MaxZeilen=100
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"requests":"#Schnellreferenz_Aufrufe_RequestResult"}';
SELECT * FROM [#Schnellreferenz_Aufrufe_RequestResult] ORDER BY [SessionId],[RequestId];
DROP TABLE [#Schnellreferenz_Aufrufe_RequestResult];

-- Integritätsevidenz der aktuellen Datenbank; führt kein DBCC und keine Reparatur aus
EXEC [monitor].[USP_DatabaseIntegrityAnalysis] @DatabaseNames=N'',@MitPageDetails=0,@MaxZeilen=100;

-- Performance Counter mit echtem Fünf-Sekunden-Intervall für unterstützte Raten
EXEC [monitor].[USP_PerformanceCounters] @SampleSeconds=5,@MaxZeilen=100;

-- Begrenzte Statistikverteilung eines generischen Zielscopes; CATALOG_DEEP erforderlich
EXEC [monitor].[USP_StatisticsDistributionAnalysis]
      @DatabaseNames=N'[DeineDatenbank]'
    , @SchemaNames=N'dbo'
    , @AnalyseModus='GEZIELT'
    , @MaxVerteilungsStatistiken=25
    , @MaxZeilen=100;

-- Leichtgewichtige Nutzungsinventur; liest keine Locations, Credentials, Payloads oder Definitionen
EXEC [monitor].[USP_SpecialFeatureInventory]
      @DatabaseNames=N''
    , @NurErkannteFeatures=1
    , @MaxZeilen=100;

-- In-Memory OLTP: Basisevidenz; teure Hashketten bleiben standardmäßig aus
EXEC [monitor].[USP_InMemoryOltpAnalysis]
      @DatabaseNames=N''
    , @MitHashIndexStats=0
    , @MaxZeilen=100;

-- Temporal Tables: nur Katalog-, Retention-, Kapazitäts- und Indexmetadaten; keine History-Zeilen
EXEC [monitor].[USP_TemporalAnalysis]
      @DatabaseNames=N''
    , @HistorySizeWarnMb=10240
    , @MaxZeilen=100;

-- Service Broker: nur Kataloge und aggregierte Laufzeitmetadaten; keine Queue-Nutzdaten
EXEC [monitor].[USP_ServiceBrokerAnalysis]
      @DatabaseNames=N''
    , @TransmissionAgeWarnMinutes=60
    , @MaxZeilen=100;

-- Full-Text: Kataloge und aggregierte Laufzeitevidenz; keine Inhalte, Crawl-Logs oder DDL
EXEC [monitor].[USP_FullTextAnalysis]
      @DatabaseNames=N''
    , @PopulationAgeWarnMinutes=60
    , @QueryableFragmentWarn=30
    , @MaxZeilen=100;

-- Change Tracking, CDC und lokale Replikation; ohne echten Consumer-Wasserstand kein CT-Verlusturteil
EXEC [monitor].[USP_DataCaptureDeepAnalysis]
      @DatabaseNames=N''
    , @CdcLatencyWarnSeconds=300
    , @ReplicationPendingCommandWarn=10000
    , @MaxZeilen=100;

-- Verschluesselungslebenszyklus; keine Schluessel-, Medien- oder Kontoinhalte
EXEC [monitor].[USP_EncryptionAnalysis]
      @DatabaseNames=N'[DeineDatenbank]'
    , @ExpliziteBackupverschluesselungErwartet=0
    , @NurProblematisch=1
    , @MaxZeilen=100;

-- Wartungsoperationen read-only; ohne Jobfilter werden Jobkataloge nicht gelesen
EXEC [monitor].[USP_MaintenanceOperations]
      @DatabaseNames=N'[DeineDatenbank]'
    , @JobNames=NULL
    , @NurProblematisch=1
    , @MaxZeilen=100;

-- Normalisierte Triage; kostenintensive optionale Module bleiben aus
DECLARE @DiagnosticFindingsJson nvarchar(max);
EXEC [monitor].[USP_DiagnosticFindings]
      @DatabaseNames=N''
    , @MitSchemaDesign=0
    , @MitStatistikverteilung=0
    , @MitIQP=0
    , @MitContention=0
    , @MaxZeilen=100
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@DiagnosticFindingsJson OUTPUT;
SELECT @DiagnosticFindingsJson AS [Json];


-- BEGIN STATEMENT-KONTEXT-BEISPIELE
-- Default: lesbare CONSOLE-Ausgabe mit exaktem Statement, Modul und Offset-/Zeileninformation
EXEC [monitor].[USP_CurrentRequests];

-- Vollständiger Batch-/Modultext und ursprünglicher Input Buffer; 0 = keine Textkürzung
EXEC [monitor].[USP_CurrentRequests]
      @GesamtenSqlTextEinbeziehen = 1
    , @InputBufferEinbeziehen = 1
    , @MaxSqlTextZeichen = 0;

-- Maschinenlesbares RAW
EXEC [monitor].[USP_CurrentRequests]
      @ResultSetArt = 'raw';

-- JSON-only mit benannten Arrays
DECLARE @CurrentRequestsJson nvarchar(max);
EXEC [monitor].[USP_CurrentRequests]
      @ResultSetArt = 'none'
    , @JsonErzeugen = 1
    , @Json = @CurrentRequestsJson OUTPUT;
SELECT @CurrentRequestsJson AS [Json];
-- END STATEMENT-KONTEXT-BEISPIELE

-- Eigenständige Plananalyse: Signatur und sichere Modi anzeigen.
EXEC [monitor].[USP_ExecutionPlanAnalysis] @Hilfe=1;
EXEC [monitor].[USP_CreateExecutionEvidenceJson] @Hilfe=1;
