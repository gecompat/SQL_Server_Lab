USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 196_Analysis_Navigator_Runtime_Contract.sql
Zweck        : Prüft Vollständigkeit, Suche, Filter, Relationen, Paketstatus
               und Ausgabe des Analysis Navigators ausschließlich über
               konstante Framework- und lokale Installationsmetadaten.
Datenschutz  : Nur synthetische Suchbegriffe und technische Frameworknamen.
               Keine fachlichen DMVs, Pläne, Texte oder Benutzerdaten.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Failure]
(
      [TestName] sysname NOT NULL
    , [Detail] nvarchar(2048) NOT NULL
);

IF (SELECT COUNT_BIG(*) FROM [monitor].[VW_AnalysisCatalog]) <> 97
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'CATALOG_COUNT',N'Der fachliche Katalog enthält nicht genau 97 öffentliche Procedures.');

IF EXISTS
(
    SELECT [ProcedureName]
    FROM [monitor].[VW_AnalysisCatalog]
    GROUP BY [ProcedureName]
    HAVING COUNT_BIG(*) <> 1
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'CATALOG_UNIQUE',N'Mindestens eine öffentliche Procedure besitzt nicht genau eine Katalogzeile.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisCatalog]
    WHERE [NavigationRole] NOT IN ('ENTRY','FOLLOW_UP','TARGETED','SETUP','SUPPORT')
       OR [PrimaryAreaCode] NOT IN
          ('NAVIGATION','FRAMEWORK','LIVE','OBJECT','PLAN','QUERY_STORE','EXTENDED_EVENTS','OPERATIONS','SERVER','SPECIAL_FEATURE','SNAPSHOT')
       OR [CostRangeCode] NOT IN
          ('LOW','LOW_MEDIUM','MEDIUM','LOW_HIGH_OPT_IN','MEDIUM_HIGH_OPT_IN','HIGH_OPT_IN')
       OR [PackageCode] NOT IN ('CORE','CORE_PLAN_STANDALONE','SNAPSHOT_OPTIONAL')
       OR [ProcedureName] IS NULL
       OR [DisplayName] IS NULL
       OR [Purpose] IS NULL
       OR [PrerequisiteSummary] IS NULL
       OR [SafeCall] IS NULL
       OR [DocumentationPath] IS NULL
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'CATALOG_DOMAIN',N'Der Katalog enthält einen unbekannten Code oder ein leeres Pflichtfeld.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisCatalog] AS [c]
    LEFT JOIN [monitor].[VW_AnalyseClassCatalog] AS [a]
      ON [a].[AnalysisClass] = [c].[RepresentativeAnalysisClass]
    WHERE [c].[RepresentativeAnalysisClass] IS NOT NULL
      AND [a].[AnalysisClass] IS NULL
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'ANALYSIS_CLASS_REFERENCE',N'Mindestens eine repräsentative AnalysisClass ist im zentralen Klassenkatalog unbekannt.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisCatalog]
    WHERE [HighImpactPathAvailable] <>
          CASE WHEN [CostRangeCode] LIKE '%HIGH%' THEN 1 ELSE 0 END
       OR [RequiresHighImpactForSafeStart] > [HighImpactPathAvailable]
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'HIGH_IMPACT_COST_CONSISTENCY',N'Kostenband, High-Impact-Pfad und erforderliche Startbestätigung sind inkonsistent.');

IF EXISTS
(
    SELECT [ProcedureName]
    FROM [monitor].[VW_AnalysisCatalog]
    WHERE [RequiresHighImpactForSafeStart] = 1
    EXCEPT
    SELECT [v].[ProcedureName]
    FROM
    (
        VALUES
          (N'USP_DataCaptureDeepAnalysis')
        , (N'USP_ExtendedEventsBlockedProcesses')
        , (N'USP_ExtendedEventsDeadlocks')
        , (N'USP_ExtendedEventsReadEvents')
        , (N'USP_ExtendedEventsTargetRuntime')
        , (N'USP_FullTextAnalysis')
        , (N'USP_IndexPhysicalStats')
        , (N'USP_IntelligentQueryProcessingAnalysis')
        , (N'USP_PlanDetails')
        , (N'USP_PlanCacheAnalysis')
        , (N'USP_QueryHashAnalysis')
        , (N'USP_SchemaDesignAnalysis')
        , (N'USP_ServiceBrokerAnalysis')
        , (N'USP_StatisticsDistributionAnalysis')
        , (N'USP_TemporalAnalysis')
    ) AS [v]([ProcedureName])
)
OR EXISTS
(
    SELECT [v].[ProcedureName]
    FROM
    (
        VALUES
          (N'USP_DataCaptureDeepAnalysis')
        , (N'USP_ExtendedEventsBlockedProcesses')
        , (N'USP_ExtendedEventsDeadlocks')
        , (N'USP_ExtendedEventsReadEvents')
        , (N'USP_ExtendedEventsTargetRuntime')
        , (N'USP_FullTextAnalysis')
        , (N'USP_IndexPhysicalStats')
        , (N'USP_IntelligentQueryProcessingAnalysis')
        , (N'USP_PlanDetails')
        , (N'USP_PlanCacheAnalysis')
        , (N'USP_QueryHashAnalysis')
        , (N'USP_SchemaDesignAnalysis')
        , (N'USP_ServiceBrokerAnalysis')
        , (N'USP_StatisticsDistributionAnalysis')
        , (N'USP_TemporalAnalysis')
    ) AS [v]([ProcedureName])
    EXCEPT
    SELECT [ProcedureName]
    FROM [monitor].[VW_AnalysisCatalog]
    WHERE [RequiresHighImpactForSafeStart] = 1
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'HIGH_IMPACT_SAFE_ENTRY_SET',N'Die Menge der bereits im fachlichen Einstieg bestätigungspflichtigen Procedures ist unvollständig oder zu breit.');

IF (SELECT COUNT_BIG(*) FROM [monitor].[VW_AnalysisCatalog] WHERE [DefaultRank] IS NOT NULL) <> 16
   OR EXISTS
      (
          SELECT [DefaultRank]
          FROM [monitor].[VW_AnalysisCatalog]
          WHERE [DefaultRank] IS NOT NULL
          GROUP BY [DefaultRank]
          HAVING COUNT_BIG(*) <> 1
      )
   OR (SELECT MIN([DefaultRank]) FROM [monitor].[VW_AnalysisCatalog]) <> 1
   OR (SELECT MAX([DefaultRank]) FROM [monitor].[VW_AnalysisCatalog]) <> 16
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'DEFAULT_RANK',N'Die kuratierte Startliste besitzt nicht genau die eindeutigen Ränge 1 bis 16.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisCatalog] AS [c]
    WHERE [c].[PackageCode] IN ('CORE','CORE_PLAN_STANDALONE')
      AND NOT EXISTS
          (
              SELECT 1
              FROM [sys].[procedures] AS [p] WITH (NOLOCK)
              JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
                ON [s].[schema_id] = [p].[schema_id]
              WHERE [s].[name] = N'monitor'
                AND [p].[name] = [c].[ProcedureName]
          )
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'CORE_INSTALLATION',N'Mindestens eine als CORE katalogisierte Procedure ist lokal nicht installiert.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisSearchTerm]
    WHERE [LanguageCode] NOT IN ('de','en')
       OR [SearchWeight] NOT BETWEEN 1 AND 100
       OR NULLIF(LTRIM(RTRIM([SearchTerm])),N'') IS NULL
       OR NULLIF(LTRIM(RTRIM([MatchReason])),N'') IS NULL
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'SEARCH_TERM_DOMAIN',N'Ein Suchbegriff besitzt ungültige Sprache, Gewichtung oder Pflichtfelder.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisCatalog] AS [c]
    WHERE (SELECT COUNT_BIG(*)
           FROM [monitor].[VW_AnalysisSearchTerm] AS [t]
           WHERE [t].[ProcedureName] = [c].[ProcedureName]) < 2
       OR NOT EXISTS
          (
              SELECT 1 FROM [monitor].[VW_AnalysisSearchTerm] AS [t]
              WHERE [t].[ProcedureName] = [c].[ProcedureName]
                AND [t].[LanguageCode] = 'de'
          )
       OR NOT EXISTS
          (
              SELECT 1 FROM [monitor].[VW_AnalysisSearchTerm] AS [t]
              WHERE [t].[ProcedureName] = [c].[ProcedureName]
                AND [t].[LanguageCode] = 'en'
          )
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'SEARCH_TERM_COVERAGE',N'Mindestens eine öffentliche Procedure besitzt weniger als zwei oder keine vollständigen DE-/EN-Suchbegriffe.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisSearchTerm] AS [t]
    LEFT JOIN [monitor].[VW_AnalysisCatalog] AS [c]
      ON [c].[ProcedureName] = [t].[ProcedureName]
    WHERE [c].[ProcedureName] IS NULL
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'SEARCH_TERM_ENDPOINT',N'Mindestens ein Suchbegriff verweist auf keine öffentliche Katalogprocedure.');

IF EXISTS
(
    SELECT [ProcedureName], [SearchTerm] COLLATE Latin1_General_100_CI_AI
    FROM [monitor].[VW_AnalysisSearchTerm]
    GROUP BY [ProcedureName], [SearchTerm] COLLATE Latin1_General_100_CI_AI
    HAVING COUNT_BIG(*) > 1
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'SEARCH_TERM_UNIQUE',N'Mindestens ein Suchbegriff ist je Procedure unter dem Suchvertrag doppelt.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisRelation] AS [r]
    LEFT JOIN [monitor].[VW_AnalysisCatalog] AS [f]
      ON [f].[ProcedureName] = [r].[FromProcedureName]
    LEFT JOIN [monitor].[VW_AnalysisCatalog] AS [t]
      ON [t].[ProcedureName] = [r].[ToProcedureName]
    WHERE [r].[RelationType] NOT IN ('REFINE_WITH','CONFIRM_WITH','ALTERNATIVE_TO','PREPARE_WITH')
       OR [r].[RelationPriority] NOT BETWEEN 1 AND 100
       OR NULLIF(LTRIM(RTRIM([r].[ConditionSummary])),N'') IS NULL
       OR [f].[ProcedureName] IS NULL
       OR [t].[ProcedureName] IS NULL
       OR [r].[FromProcedureName] = [r].[ToProcedureName]
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'RELATION_DOMAIN',N'Der Relationskatalog enthält einen ungültigen Typ, Endpunkt, Rang oder Selbstbezug.');

IF EXISTS
(
    SELECT [FromProcedureName],[RelationType],[RelationPriority]
    FROM [monitor].[VW_AnalysisRelation]
    GROUP BY [FromProcedureName],[RelationType],[RelationPriority]
    HAVING COUNT_BIG(*) > 1
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'RELATION_PRIORITY_UNIQUE',N'Eine Ausgangsprocedure besitzt innerhalb desselben Relationstyps einen doppelten Rang.');

IF EXISTS
(
    SELECT 1
    FROM [monitor].[VW_AnalysisCatalog] AS [c]
    WHERE [c].[ProcedureName] <> N'USP_AnalysisNavigator'
      AND [c].[NavigationRole] <> 'SUPPORT'
      AND NOT EXISTS
          (
              SELECT 1
              FROM [monitor].[VW_AnalysisRelation] AS [r]
              WHERE [r].[FromProcedureName] = [c].[ProcedureName]
          )
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'RELATION_COVERAGE',N'Mindestens ein regulärer Anwenderpfad besitzt keine dokumentierte Folgerelation.');

DECLARE @Cases TABLE
(
      [CaseId] int IDENTITY(1,1) NOT NULL PRIMARY KEY
    , [SearchTerm] nvarchar(200) NOT NULL
    , [ExpectedProcedure] sysname NOT NULL
);

INSERT @Cases([SearchTerm],[ExpectedProcedure])
VALUES
      (N'Benutzer warten',N'USP_CurrentBlocking')
    , (N'CPU hoch',N'USP_CurrentRequests')
    , (N'TempDB wächst',N'USP_CurrentTempDB')
    , (N'Log voll',N'USP_CurrentLog')
    , (N'Query plötzlich langsamer',N'USP_QueryStoreRegressions')
    , (N'Plan XML analysieren',N'USP_ExecutionPlanAnalysis')
    , (N'Index ungenutzt',N'USP_IndexUsage')
    , (N'AG Lag Redo Queue Send Queue',N'USP_AvailabilityDeepAnalysis')
    , (N'Deadlock',N'USP_ExtendedEventsDeadlocks')
    , (N'SQL Server Version CU Lifecycle',N'USP_ServerVersionInformation')
    , (N'JSON-Index Pfade inventarisieren',N'USP_ObjectInventory')
    , (N'JSON-Index Capability Preview',N'USP_ServerFeatureCapabilities')
    , (N'TempDB Workload Group Limit Verletzung',N'USP_CurrentTempDB')
    , (N'TempDB Resource Governance Wirksamkeit',N'USP_ResourceGovernorAnalysis')
    , (N'lesbare Secondary Statistik Replikat Herkunft',N'USP_Statistics');

DECLARE @CaseId int=1,@MaxCaseId int=(SELECT MAX([CaseId]) FROM @Cases);
DECLARE @SearchTerm nvarchar(200),@ExpectedProcedure sysname,@ActualProcedure sysname;

WHILE @CaseId<=@MaxCaseId
BEGIN
    SELECT @SearchTerm=[SearchTerm],@ExpectedProcedure=[ExpectedProcedure]
    FROM @Cases
    WHERE [CaseId]=@CaseId;

    DROP TABLE IF EXISTS [#AnalysisNavigatorRuntimeContract_Navigation];
    CREATE TABLE [#AnalysisNavigatorRuntimeContract_Navigation] ([Seed] int NULL);

    BEGIN TRY
        EXEC [monitor].[USP_AnalysisNavigator]
              @Suchbegriff=@SearchTerm
            , @NurInstallierte=0
            , @MaxZeilen=10
            , @ResultSetArt='TABLE'
            , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Navigation"}'
            , @PrintMeldungen=0;

        SET @ActualProcedure=NULL;
        SELECT @ActualProcedure=[ProcedureName]
        FROM [#AnalysisNavigatorRuntimeContract_Navigation]
        WHERE [Rank]=1;

        IF @ActualProcedure<>@ExpectedProcedure
            INSERT [#AnalysisNavigatorRuntimeContract_Failure]
            VALUES
            (
                  CONCAT(N'SEARCH_CASE_',@CaseId)
                , CONCAT(N'Suche "',@SearchTerm,N'" erwartete ',@ExpectedProcedure,N', erhielt ',COALESCE(@ActualProcedure,N'NULL'),N'.')
            );
    END TRY
    BEGIN CATCH
        INSERT [#AnalysisNavigatorRuntimeContract_Failure]
        VALUES(CONCAT(N'SEARCH_CASE_',@CaseId),CONCAT(N'TABLE-Suchaufruf fehlgeschlagen: ',ERROR_MESSAGE()));
    END CATCH;

    SET @CaseId+=1;
END;

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Accent] ([Seed] int NULL);
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff=N'BENÚTZER WARTEN'
    , @NurInstallierte=0
    , @MaxZeilen=5
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Accent"}'
    , @PrintMeldungen=0;

IF NOT EXISTS
(
    SELECT 1
    FROM [#AnalysisNavigatorRuntimeContract_Accent]
    WHERE [Rank]=1 AND [ProcedureName]=N'USP_CurrentBlocking'
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'CASE_ACCENT_INSENSITIVE',N'Die Suchcollation hat Großschreibung oder Akzent im synthetischen Blockingbegriff nicht ignoriert.');

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Token] ([Seed] int NULL);
BEGIN TRY
    EXEC [monitor].[USP_AnalysisNavigator]
          @Suchbegriff=N'CPU hoch cpu CÚP'
        , @NurInstallierte=0
        , @MaxZeilen=5
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Token"}'
        , @PrintMeldungen=0;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [#AnalysisNavigatorRuntimeContract_Token]
        WHERE [Rank]=1 AND [ProcedureName]=N'USP_CurrentRequests'
    )
        INSERT [#AnalysisNavigatorRuntimeContract_Failure]
        VALUES(N'TOKEN_COLLATION_DEDUPLICATION',N'Case- oder akzentgleiche Suchtoken wurden nicht kollisionsfrei normalisiert.');
END TRY
BEGIN CATCH
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'TOKEN_COLLATION_DEDUPLICATION',CONCAT(N'Die Token-Normalisierung hat einen Fehler ausgelöst: ',ERROR_MESSAGE()));
END CATCH;

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Filter] ([Seed] int NULL);
EXEC [monitor].[USP_AnalysisNavigator]
      @Bereich='PLAN'
    , @Navigationsrolle='TARGETED'
    , @NurInstallierte=1
    , @MaxZeilen=100
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Filter"}'
    , @PrintMeldungen=0;

IF NOT EXISTS (SELECT 1 FROM [#AnalysisNavigatorRuntimeContract_Filter])
   OR EXISTS
      (
          SELECT 1
          FROM [#AnalysisNavigatorRuntimeContract_Filter]
          WHERE [PrimaryAreaCode]<>'PLAN'
             OR [NavigationRole]<>'TARGETED'
             OR [IsInstalled]<>1
      )
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'AREA_ROLE_FILTER',N'Bereichs-, Rollen- oder Installationsfilter lieferte eine leere oder fachlich fremde Zeile.');

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Default] ([Seed] int NULL);
EXEC [monitor].[USP_AnalysisNavigator]
      @NurInstallierte=1
    , @MaxZeilen=12
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Default"}'
    , @PrintMeldungen=0;

IF (SELECT COUNT_BIG(*) FROM [#AnalysisNavigatorRuntimeContract_Default])<>12
   OR NOT EXISTS
      (
          SELECT 1
          FROM [#AnalysisNavigatorRuntimeContract_Default]
          WHERE [Rank]=1 AND [ProcedureName]=N'USP_CurrentOverview'
      )
   OR EXISTS
      (
          SELECT 1
          FROM [#AnalysisNavigatorRuntimeContract_Default]
          WHERE [ProcedureName]=N'USP_AnalysisNavigator'
      )
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'DEFAULT_ENTRY_LIST',N'Die Defaultliste enthält nicht 12 Einträge, startet nicht mit CurrentOverview oder enthält den Navigator selbst.');

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Zero] ([Seed] int NULL);
EXEC [monitor].[USP_AnalysisNavigator]
      @NurInstallierte=1
    , @MaxZeilen=0
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Zero"}'
    , @PrintMeldungen=0;

IF (SELECT COUNT_BIG(*) FROM [#AnalysisNavigatorRuntimeContract_Zero])<>16
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'UNLIMITED_DEFAULT_ENTRY_LIST',N'@MaxZeilen=0 lieferte nicht die vollständige kuratierte Startliste mit 16 Einträgen.');

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Null] ([Seed] int NULL);
EXEC [monitor].[USP_AnalysisNavigator]
      @Bereich='PLAN'
    , @MaxZeilen=NULL
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Null"}'
    , @PrintMeldungen=0;

IF (SELECT COUNT_BIG(*) FROM [#AnalysisNavigatorRuntimeContract_Null]) < 2
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'NULL_UNLIMITED_FILTER_LIST',N'@MaxZeilen=NULL lieferte für den PLAN-Bereich keine vollständige gefilterte Treffermenge.');

CREATE TABLE [#AnalysisNavigatorRuntimeContract_Optional] ([Seed] int NULL);
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff=N'Snapshot erfassen Baseline'
    , @NurInstallierte=0
    , @MaxZeilen=5
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"navigation":"#AnalysisNavigatorRuntimeContract_Optional"}'
    , @PrintMeldungen=0;

IF NOT EXISTS
(
    SELECT 1
    FROM [#AnalysisNavigatorRuntimeContract_Optional]
    WHERE [Rank]=1
      AND [ProcedureName]=N'USP_RunSnapshotCollectionCycle'
      AND [PackageCode]='SNAPSHOT_OPTIONAL'
)
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'OPTIONAL_PACKAGE_VISIBLE',N'Das nicht zwingend installierte Snapshotpaket ist im vollständigen Katalog nicht korrekt auffindbar.');

DECLARE @Json nvarchar(max);
EXEC [monitor].[USP_AnalysisNavigator]
      @Suchbegriff=N'query regression'
    , @MaxZeilen=5
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;

IF COALESCE(ISJSON(@Json),0)<>1
   OR JSON_VALUE(@Json,N'$.meta.statusCode')<>'AVAILABLE'
   OR JSON_VALUE(@Json,N'$.navigation[0].ProcedureName')<>N'USP_QueryStoreRegressions'
   OR JSON_VALUE(@Json,N'$.navigation[0].RelationType') IS NULL
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'JSON_CONTRACT',N'Der JSON-Vertrag ist ungültig oder enthält nicht den erwarteten Regressions- und Relationspfad.');

SET @Json=NULL;
EXEC [monitor].[USP_AnalysisNavigator]
      @Bereich='UNKNOWN_AREA'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@Json OUTPUT
    , @PrintMeldungen=0;

IF COALESCE(ISJSON(@Json),0)<>1
   OR JSON_VALUE(@Json,N'$.meta.statusCode')<>'INVALID_PARAMETER'
   OR JSON_QUERY(@Json,N'$.navigation')<>N'[]'
    INSERT [#AnalysisNavigatorRuntimeContract_Failure]
    VALUES(N'INVALID_FILTER_STATUS',N'Ein unbekannter Bereich lieferte nicht INVALID_PARAMETER mit leerem navigation-Array.');

IF EXISTS (SELECT 1 FROM [#AnalysisNavigatorRuntimeContract_Failure])
BEGIN
    SELECT [TestName],[Detail]
    FROM [#AnalysisNavigatorRuntimeContract_Failure]
    ORDER BY [TestName];
    THROW 54596,N'Analysis-Navigator-Laufzeitvertrag fehlgeschlagen.',1;
END;

SELECT
      CAST('AVAILABLE' AS varchar(40)) AS [StatusCode]
    , CAST(0 AS bit) AS [IsPartial]
    , CAST(97 AS int) AS [CatalogProcedureCount]
    , (SELECT COUNT_BIG(*) FROM [monitor].[VW_AnalysisSearchTerm]) AS [SearchTermCount]
    , (SELECT COUNT_BIG(*) FROM [monitor].[VW_AnalysisRelation]) AS [RelationCount]
    , CAST(N'Analysis Catalog, DE/EN-Suche, Beziehungen, Filter, Paketstatus, TABLE und JSON sind konsistent.' AS nvarchar(1000)) AS [Detail];
GO
