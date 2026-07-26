USE [DeineDatenbank];
GO

-- Sichere Signatur-/Hilfeprüfung; keine ressourcenintensive Analyse.
EXEC [monitor].[USP_QueryStats] @Hilfe=1;
EXEC [monitor].[USP_PlanCacheAnalysis] @Hilfe=1;
GO

/* Laufinterner Source-Snapshot: zwei Consumer verwenden denselben
   dm_exec_query_stats-Stand; es wird kein SQL-/Plantext ausgegeben. */
DECLARE @PlanCacheJson nvarchar(max);

EXEC [monitor].[USP_PlanCacheAnalysis]
      @MitQueryStats=1
    , @MitQueryHashAnalysis=1
    , @MitPlanCacheHealth=0
    , @MitShowplanAnalysis=0
    , @DatabaseNames=N'[DeineDatenbank]'
    , @HighImpactConfirmed=1
    , @MaxZeilen=10
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@PlanCacheJson OUTPUT
    , @PrintMeldungen=0;

IF ISJSON(@PlanCacheJson)<>1
    THROW 53300,N'Der Plan-Cache-Orchestrator hat kein gültiges JSON geliefert.',1;

IF JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.resultName') IS NULL
   OR JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.resultName')<>N'QueryStats'
   OR JSON_VALUE(@PlanCacheJson,N'$.queryHashes.meta.resultName') IS NULL
   OR JSON_VALUE(@PlanCacheJson,N'$.queryHashes.meta.resultName')<>N'QueryHashAnalysis'
    THROW 53301,N'Die erwarteten Child-Payloads fehlen im Plan-Cache-JSON.',1;

IF JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.statusCode') IS NULL
   OR JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.statusCode')<>'AVAILABLE'
   OR JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.errorNumber') IS NOT NULL
BEGIN
    DECLARE @QueryStatsContractError nvarchar(2048)=CONCAT
    (
          N'Der Query-Stats-Snapshot-Consumer war nicht erfolgreich: '
        , COALESCE(JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.statusCode'),N'<NULL>')
        , N' / '
        , COALESCE(JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.errorNumber'),N'<NULL>')
        , N' / '
        , COALESCE(JSON_VALUE(@PlanCacheJson,N'$.queryStats.meta.errorMessage'),N'<NULL>')
    );
    THROW 53302,@QueryStatsContractError,1;
END;

IF JSON_VALUE(@PlanCacheJson,N'$.queryHashes.meta.statusCode') IS NULL
   OR JSON_VALUE(@PlanCacheJson,N'$.queryHashes.meta.statusCode')<>'AVAILABLE'
   OR JSON_VALUE(@PlanCacheJson,N'$.queryHashes.meta.errorNumber') IS NOT NULL
    THROW 53303,N'Der Query-Hash-Snapshot-Consumer war nicht erfolgreich.',1;

IF EXISTS (SELECT 1 FROM OPENJSON(@PlanCacheJson,N'$.warnings'))
    THROW 53304,N'Erfolgreiche Snapshot-Wiederverwendung darf keine Warnung erzeugen.',1;

IF
(
    SELECT COUNT_BIG(*)
    FROM OPENJSON(@PlanCacheJson,N'$.modules')
    WITH
    (
        [ModuleName] sysname N'$.ModuleName',
        [InvocationStatus] varchar(40) N'$.InvocationStatus'
    )
    WHERE [ModuleName] IN(N'USP_QueryStats',N'USP_QueryHashAnalysis')
      AND [InvocationStatus]='REUSED_PARENT_SNAPSHOT'
)<>2
    THROW 53305,N'Der laufinterne Plan-Cache-Snapshot wurde nicht von beiden Consumern wiederverwendet.',1;
GO

/* Ein einzelner Consumer liest frisch und baut keinen Parent-Snapshot auf. */
DECLARE @SingleConsumerJson nvarchar(max);

EXEC [monitor].[USP_PlanCacheAnalysis]
      @MitQueryStats=1
    , @MitQueryHashAnalysis=0
    , @MitPlanCacheHealth=0
    , @MitShowplanAnalysis=0
    , @DatabaseNames=N'[DeineDatenbank]'

    , @MaxZeilen=10
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@SingleConsumerJson OUTPUT
    , @PrintMeldungen=0;

IF ISJSON(@SingleConsumerJson)<>1
   OR JSON_VALUE(@SingleConsumerJson,N'$.modules[0].ModuleName')<>N'USP_QueryStats'
   OR JSON_VALUE(@SingleConsumerJson,N'$.modules[0].InvocationStatus')<>'EXECUTED'
    THROW 53306,N'Der Frischlesevertrag für einen einzelnen Plan-Cache-Consumer ist verletzt.',1;
GO
