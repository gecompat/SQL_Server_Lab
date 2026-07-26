USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 110_Smoke_Test.sql
Zweck        : Führt nach einer Installation oder einem Upgrade einen kompakten,
               optionalen Smoke-Test aus. Der Test persistiert keine Daten,
               ändert keine Konfiguration und führt keine Deep-Scans aus.
===============================================================================
*/
SET NOCOUNT ON;
USE [DeineDatenbank];
GO

DECLARE @Missing nvarchar(max);
DECLARE @Expected TABLE([ObjectName] nvarchar(256), [ObjectType] char(2));

INSERT @Expected([ObjectName],[ObjectType])
VALUES
(N'monitor.VW_ModuleStatusCatalog','V'),
(N'monitor.VW_AnalyseClassCatalog','V'),
(N'monitor.VW_AnalysisCatalog','V'),
(N'monitor.VW_AnalysisSearchTerm','V'),
(N'monitor.VW_AnalysisRelation','V'),
(N'monitor.VW_FrameworkFeatureCatalog','V'),
(N'monitor.WaitTypeCatalog','U'),
(N'monitor.WaitTypeCatalogSource','U'),
(N'monitor.FrameworkVersion','U'),
(N'monitor.TVF_WaitTypeInfo','IF'),
(N'monitor.TVF_WaitTypeSources','IF'),
(N'monitor.TVF_StatementText','IF'),
(N'monitor.TVF_InterpretPerformanceCounter','IF'),
(N'monitor.TVF_InterpretContentionCounter','IF'),
(N'monitor.TVF_ClassifyErrorLogEvent','IF'),
(N'monitor.USP_CheckAnalyseAccess','P'),
(N'monitor.USP_CheckFrameworkCapabilities','P'),
(N'monitor.USP_AnalysisNavigator','P'),
(N'monitor.USP_CurrentOverview','P'),
(N'monitor.USP_CurrentWaits','P'),
(N'monitor.USP_ObjectAnalysis','P'),
(N'monitor.USP_VectorIndexAnalysis','P'),
(N'monitor.USP_PlanCacheAnalysis','P'),
(N'monitor.USP_QueryStoreAnalysis','P'),
(N'monitor.USP_ExtendedEventsAnalysis','P'),
(N'monitor.USP_InfrastructureAnalysis','P'),
(N'monitor.USP_ServerHealthAnalysis','P'),
(N'monitor.USP_DatabaseIntegrityAnalysis','P'),
(N'monitor.USP_DatabaseCapacityAnalysis','P'),
(N'monitor.USP_PerformanceCounters','P'),
(N'monitor.USP_CriticalEngineEvents','P'),
(N'monitor.USP_IntelligentQueryProcessingAnalysis','P'),
(N'monitor.USP_InternalContentionAnalysis','P'),
(N'monitor.USP_BufferPoolAnalysis','P'),
(N'monitor.USP_BackupChainAnalysis','P'),
(N'monitor.USP_SchemaDesignAnalysis','P'),
(N'monitor.USP_StatisticsDistributionAnalysis','P'),
(N'monitor.USP_AvailabilityDeepAnalysis','P'),
(N'monitor.USP_AgentMonitoringAnalysis','P'),
(N'monitor.USP_DiagnosticFindings','P'),
(N'monitor.USP_ErrorLogAnalysis','P'),
(N'monitor.USP_WorkerPressureAnalysis','P'),
(N'monitor.USP_DatabaseConfigurationAnalysis','P'),
(N'monitor.USP_ServerFeatureCapabilities','P'),
(N'monitor.USP_SpecialFeatureInventory','P'),
(N'monitor.USP_InMemoryOltpAnalysis','P'),
(N'monitor.USP_TemporalAnalysis','P'),
(N'monitor.USP_ServiceBrokerAnalysis','P'),
(N'monitor.USP_FullTextAnalysis','P'),
(N'monitor.USP_DataCaptureDeepAnalysis','P'),
(N'monitor.USP_EncryptionAnalysis','P'),
(N'monitor.USP_ExternalRuntimeAnalysis','P'),
(N'monitor.USP_ClrAnalysis','P'),
(N'monitor.USP_MaintenanceOperations','P');

SELECT @Missing = STRING_AGG([ObjectName],N', ')
FROM @Expected AS [e]
WHERE NOT EXISTS
(
    SELECT 1
    FROM [sys].[objects] AS [o] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[o].[schema_id]
    WHERE [s].[name] COLLATE SQL_Latin1_General_CP1_CS_AS
            =PARSENAME([e].[ObjectName],2) COLLATE SQL_Latin1_General_CP1_CS_AS
      AND [o].[name] COLLATE SQL_Latin1_General_CP1_CS_AS
            =PARSENAME([e].[ObjectName],1) COLLATE SQL_Latin1_General_CP1_CS_AS
      AND [o].[type] COLLATE SQL_Latin1_General_CP1_CS_AS
            =[e].[ObjectType] COLLATE SQL_Latin1_General_CP1_CS_AS
);

IF @Missing IS NOT NULL
BEGIN
    DECLARE @MissingMessage nvarchar(2048)=CONCAT(N'Fehlende Kernobjekte: ',@Missing);
    THROW 54000,@MissingMessage,1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[FrameworkVersion] WITH (NOLOCK)
    WHERE [FrameworkName]=N'SQLServerMonitoringFramework'
      AND [FrameworkVersion]='1.1.0-special.19'
)
    THROW 54001,N'FrameworkVersion fehlt oder entspricht nicht dem Spezialfall-Release.',1;

IF (SELECT COUNT_BIG(*) FROM [monitor].[VW_AnalysisCatalog]) <> 97
    THROW 54025,N'Der Analysis Catalog enthält nicht genau alle 97 öffentlichen Procedures.',1;

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisCatalog] AS [c]
    WHERE NOT EXISTS
          (
              SELECT 1
              FROM [monitor].[VW_AnalysisSearchTerm] AS [t]
              WHERE [t].[ProcedureName] = [c].[ProcedureName]
                AND [t].[LanguageCode] = 'de'
          )
       OR NOT EXISTS
          (
              SELECT 1
              FROM [monitor].[VW_AnalysisSearchTerm] AS [t]
              WHERE [t].[ProcedureName] = [c].[ProcedureName]
                AND [t].[LanguageCode] = 'en'
          )
)
    THROW 54026,N'Mindestens eine öffentliche Procedure besitzt keine vollständige DE-/EN-Suchabdeckung.',1;

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisRelation] AS [r]
    LEFT JOIN [monitor].[VW_AnalysisCatalog] AS [f]
      ON [f].[ProcedureName] = [r].[FromProcedureName]
    LEFT JOIN [monitor].[VW_AnalysisCatalog] AS [t]
      ON [t].[ProcedureName] = [r].[ToProcedureName]
    WHERE [f].[ProcedureName] IS NULL
       OR [t].[ProcedureName] IS NULL
       OR [r].[FromProcedureName] = [r].[ToProcedureName]
)
    THROW 54027,N'Der Analysis Relationskatalog enthält einen ungültigen Endpunkt.',1;

IF (SELECT COUNT_BIG(*) FROM [monitor].[WaitTypeCatalog] WITH (NOLOCK) WHERE [IsFrameworkDefault]=1) < 347
    THROW 54002,N'Der Framework-Wait-Katalog ist unvollständig.',1;

IF EXISTS
(
    SELECT 1
    FROM [monitor].[WaitTypeCatalog] WITH (NOLOCK)
    WHERE [IsFrameworkDefault]=1
      AND ([Meaning] IS NULL OR [TypicalOccurrence] IS NULL OR [HighWaitImpact] IS NULL
           OR [RecommendedChecks] IS NULL OR [HelpUrl] IS NULL OR [SourceReference] IS NULL
           OR [DescriptionSource]<>'FRAMEWORK_CURATED' OR [DescriptionQuality]<>'FRAMEWORK_CURATED')
)
    THROW 54003,N'Der Framework-Wait-Katalog enthält unvollständige Pflichtinformationen.',1;

IF EXISTS
(
    SELECT 1
    FROM [monitor].[WaitTypeCatalog] WITH (NOLOCK)
    WHERE [IsFrameworkDefault]=1
      AND
      (
           [DefaultAssessment] IS NULL OR [AssessmentBasis] IS NULL
        OR [CommonCauses] IS NULL OR [PerformanceImpact] IS NULL
        OR [Mitigation] IS NULL OR [CounterEvidence] IS NULL
        OR [MeasurementGuidance] IS NULL OR [AnalysisConfidence] IS NULL
        OR [WaitGroup]=N'OTHER_OR_NEW'
      )
)
    THROW 54021,N'Der Framework-Wait-Katalog enthält unvollständige Analysefelder oder eine nicht migrierte Sammelgruppe.',1;

IF EXISTS
(
    SELECT [c].[WaitType]
    FROM [monitor].[WaitTypeCatalog] AS [c] WITH (NOLOCK)
    LEFT JOIN [monitor].[WaitTypeCatalogSource] AS [s] WITH (NOLOCK)
      ON [s].[WaitType]=[c].[WaitType]
     AND [s].[IsFrameworkDefault]=1
    WHERE [c].[IsFrameworkDefault]=1
    GROUP BY [c].[WaitType]
    HAVING COUNT_BIG([s].[SourceOrdinal])<4
        OR COUNT(DISTINCT CASE
               WHEN [s].[SourceType] IN ('DEFINITION','MEASUREMENT','INTERPRETATION','DIAGNOSTIC_MITIGATION')
               THEN [s].[SourceType]
             END)<4
)
    THROW 54022,N'Für mindestens einen Framework-Wait fehlen die vier verpflichtenden Quellenrollen.',1;

IF (SELECT COUNT_BIG(*) FROM [monitor].[WaitTypeCatalogSource] WITH (NOLOCK) WHERE [IsFrameworkDefault]=1)<>1396
    THROW 54023,N'Der Framework-Quellkatalog entspricht nicht dem erwarteten Stand.',1;

IF EXISTS
(
    SELECT [c].[WaitType]
    FROM [monitor].[WaitTypeCatalog] AS [c] WITH (NOLOCK)
    CROSS APPLY [monitor].[TVF_WaitTypeSources]([c].[WaitType]) AS [s]
    WHERE [c].[IsFrameworkDefault]=1
    GROUP BY [c].[WaitType]
    HAVING COUNT(DISTINCT CASE
               WHEN [s].[SourceType] IN ('DEFINITION','MEASUREMENT','INTERPRETATION','DIAGNOSTIC_MITIGATION')
               THEN [s].[SourceType]
             END)<4
)
    THROW 54024,N'Die Wait-Type-Quellenfunktion liefert nicht alle verpflichtenden Quellenrollen.',1;

IF EXISTS
(
    SELECT 1
    FROM [monitor].[WaitTypeCatalog] WITH (NOLOCK)
    WHERE [IsFrameworkDefault]=1
      AND [WaitType] IN
      (
          N'CURSOR',N'DBTABLE',N'IDES',N'LCK_MSCH_M',N'LCK_M_RI_NL',N'LCK_M_RI_S',N'LCK_M_RI_U',N'LCK_M_RI_X',
          N'NETWORKIO',N'PAGESUPP',N'PARALLEL_PAGE_SUPPLIER',N'PSS_CHILD',N'SLEEP',N'UMSTHREAD'
      )
)
    THROW 54020,N'Der Framework-Wait-Katalog enthält abgelöste Alt- oder Fehlnamen.',1;

IF EXISTS
(
    SELECT 1
    FROM [sys].[objects] AS [o] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[o].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND
      (
           ([o].[type]=N'U' AND [o].[name] IN
              (N'FrameworkInstallationHistory',N'FrameworkExpectedObject',N'FrameworkProcedureContract'))
        OR ([o].[type]=N'P' AND [o].[name]=N'USP_FrameworkSelfTest')
      )
)
    THROW 54004,N'Veraltete Production-Hardening-Objekte sind noch vorhanden.',1;

-- Zentrale Offsetlogik mit einem deterministischen Batch prüfen.
DECLARE @ExtractedStatement nvarchar(max);
SELECT @ExtractedStatement = [StatementText]
FROM [monitor].[TVF_StatementText]
(
      N'SELECT 1; SELECT 2;'
    , 20
    , -1
);

IF @ExtractedStatement <> N'SELECT 2;'
    THROW 54005,N'TVF_StatementText hat den erwarteten Statementausschnitt nicht geliefert.',1;

-- Aktuelle eigene Session eng begrenzt über den echten Ausführungspfad prüfen.
DECLARE @CurrentSessionIds nvarchar(20)=CONVERT(nvarchar(20),@@SPID);
DECLARE @CurrentRequestsJson nvarchar(max);
EXEC [monitor].[USP_CurrentRequests]
      @SessionIds=@CurrentSessionIds
    , @AktuelleSessionEinbeziehen=1
    , @GesamtenSqlTextEinbeziehen=1
    , @InputBufferEinbeziehen=1
    , @MaxSqlTextZeichen=0
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@CurrentRequestsJson OUTPUT;

IF COALESCE(ISJSON(@CurrentRequestsJson),0)<>1
    THROW 54006,N'USP_CurrentRequests hat kein gültiges JSON geliefert.',1;

-- Leichte Hilfepfade: prüfen die öffentlichen Einstiegspunkte ohne fachliche Deep-Scans.
DECLARE @AnalysisNavigatorJson nvarchar(max);
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff=N'Benutzer warten'
    , @MaxZeilen=5
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@AnalysisNavigatorJson OUTPUT;

IF COALESCE(ISJSON(@AnalysisNavigatorJson),0)<>1
   OR JSON_VALUE(@AnalysisNavigatorJson,N'$.navigation[0].ProcedureName')<>N'USP_CurrentBlocking'
    THROW 54028,N'Der Analysis Navigator hat für die synthetische Blockingsuche keinen gültigen priorisierten JSON-Treffer geliefert.',1;

EXEC [monitor].[USP_AnalysisNavigator] @Hilfe=1;
EXEC [monitor].[USP_CheckAnalyseAccess] @Hilfe=1;
EXEC [monitor].[USP_CheckFrameworkCapabilities] @Hilfe=1;
EXEC [monitor].[USP_CurrentOverview] @Hilfe=1;
EXEC [monitor].[USP_CurrentWaits] @Hilfe=1;
EXEC [monitor].[USP_ServerFeatureCapabilities] @Hilfe=1;
EXEC [monitor].[USP_ServerHealthAnalysis] @Hilfe=1;
EXEC [monitor].[USP_DatabaseIntegrityAnalysis] @Hilfe=1;
EXEC [monitor].[USP_DatabaseCapacityAnalysis] @Hilfe=1;
EXEC [monitor].[USP_PerformanceCounters] @Hilfe=1;
EXEC [monitor].[USP_CriticalEngineEvents] @Hilfe=1;
EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis] @Hilfe=1;
EXEC [monitor].[USP_InternalContentionAnalysis] @Hilfe=1;
EXEC [monitor].[USP_BufferPoolAnalysis] @Hilfe=1;
EXEC [monitor].[USP_BackupChainAnalysis] @Hilfe=1;
EXEC [monitor].[USP_SchemaDesignAnalysis] @Hilfe=1;
EXEC [monitor].[USP_StatisticsDistributionAnalysis] @Hilfe=1;
EXEC [monitor].[USP_VectorIndexAnalysis] @Hilfe=1;
EXEC [monitor].[USP_AvailabilityDeepAnalysis] @Hilfe=1;
EXEC [monitor].[USP_AgentMonitoringAnalysis] @Hilfe=1;
EXEC [monitor].[USP_DiagnosticFindings] @Hilfe=1;
EXEC [monitor].[USP_SpecialFeatureInventory] @Hilfe=1;
EXEC [monitor].[USP_InMemoryOltpAnalysis] @Hilfe=1;
EXEC [monitor].[USP_TemporalAnalysis] @Hilfe=1;
EXEC [monitor].[USP_ServiceBrokerAnalysis] @Hilfe=1;
EXEC [monitor].[USP_FullTextAnalysis] @Hilfe=1;
EXEC [monitor].[USP_DataCaptureDeepAnalysis] @Hilfe=1;
EXEC [monitor].[USP_EncryptionAnalysis] @Hilfe=1;
EXEC [monitor].[USP_MaintenanceOperations] @Hilfe=1;

SELECT
    CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],
    CAST(0 AS bit) AS [IsPartial],
    (SELECT [FrameworkVersion] FROM [monitor].[FrameworkVersion] WITH (NOLOCK)
     WHERE [FrameworkName]=N'SQLServerMonitoringFramework') AS [FrameworkVersion],
    (SELECT COUNT_BIG(*) FROM [sys].[procedures] p WITH (NOLOCK)
     JOIN [sys].[schemas] s WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id]
     WHERE [s].[name]=N'monitor') AS [ProcedureCount],
    (SELECT COUNT_BIG(*) FROM [monitor].[WaitTypeCatalog] WITH (NOLOCK)
     WHERE [IsFrameworkDefault]=1) AS [FrameworkWaitTypeCount],
    N'Kompakter Smoke Test erfolgreich.' AS [Detail];
GO
