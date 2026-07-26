USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 121_DIAG003_Parameter_Evidence_Runtime_Contract.sql
Zweck        : Prüft die frameworkweite Aggregation des kanonischen
               DIAG-003-Parameterresultsets in USP_ShowplanAnalysis.
Datenschutz  : Ausschließlich synthetisches, nicht auflösbares Planhandle.
===============================================================================
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @MissingPlanHandle varbinary(64)=CONVERT(varbinary(64),REPLICATE('02',64),2);
DECLARE @ShowplanJson nvarchar(max);

EXEC [monitor].[USP_ShowplanAnalysis]
      @PlanHandle=@MissingPlanHandle
    , @PlanQuelle='COMPILE'
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@ShowplanJson OUTPUT
    , @PrintMeldungen=0;

IF ISJSON(@ShowplanJson)<>1
   OR TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.meta.schemaVersion'))<>4
   OR JSON_QUERY(@ShowplanJson,N'$.parameters') IS NULL
   OR COALESCE(JSON_VALUE(@ShowplanJson,N'$.parameters[0].ValueStatus'),N'')<>N'PLAN_EVICTED'
   OR COALESCE(JSON_VALUE(@ShowplanJson,N'$.parameters[0].ValueSource'),N'')<>N'COMPILE_PLAN'
   OR COALESCE(TRY_CONVERT(int,JSON_VALUE(@ShowplanJson,N'$.parameters[0].CandidateId')),0)<>1
    THROW 53646,N'USP_ShowplanAnalysis aggregiert den DIAG-003-JSON-Vertrag nicht korrekt.',1;

IF JSON_QUERY(@ShowplanJson,N'$.analyses[0].parameters') IS NULL
   OR COALESCE(JSON_VALUE(@ShowplanJson,N'$.analyses[0].parameters[0].ValueStatus'),N'')<>N'PLAN_EVICTED'
    THROW 53647,N'Der Child-Vertrag der Showplan-Analyse enthält keine konsistente Parameterevidenz.',1;

CREATE TABLE [#121_DIAG003_Parameter_Evidence_Runtime_Contract_Parameters]
(
    [SeedColumn] bit NULL
);

EXEC [monitor].[USP_ShowplanAnalysis]
      @PlanHandle=@MissingPlanHandle
    , @PlanQuelle='COMPILE'
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"parameters":"#121_DIAG003_Parameter_Evidence_Runtime_Contract_Parameters"}'
    , @JsonErzeugen=0
    , @PrintMeldungen=0;

IF NOT EXISTS
(
    SELECT 1
    FROM [#121_DIAG003_Parameter_Evidence_Runtime_Contract_Parameters]
    WHERE [CandidateId]=1
      AND [ValueStatus]='PLAN_EVICTED'
      AND [ValueSource]='COMPILE_PLAN'
      AND [CompiledValuePresent]=0
      AND [RuntimeValuePresent]=0
      AND [IsComplete]=0
)
   OR EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#121_DIAG003_Parameter_Evidence_Runtime_Contract_Parameters%'
            AND [c].[name]=N'SeedColumn'
      )
   OR NOT EXISTS
      (
          SELECT 1
          FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
          JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
            ON [t].[object_id]=[c].[object_id]
          WHERE [t].[name] LIKE N'#121_DIAG003_Parameter_Evidence_Runtime_Contract_Parameters%'
            AND [c].[name]=N'SourceObservedAtUtc'
      )
    THROW 53648,N'Der TABLE-Vertrag der aggregierten DIAG-003-Parameterevidenz ist fehlgeschlagen.',1;

SELECT
      N'DIAG003ParameterEvidence' AS [ContractName]
    , N'PASS' AS [StatusCode]
    , COUNT_BIG(*) AS [EvidenceRowCount]
FROM [#121_DIAG003_Parameter_Evidence_Runtime_Contract_Parameters];
GO
