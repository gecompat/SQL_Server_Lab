USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 193_ExecutionPlanAnalysis_Standalone_Runtime_Contract.sql
Zweck        : Installiert PLAN-001 zweimal in einer leeren synthetischen
               SQL-Server-2025-Datenbank und prüft Public APIs, Idempotenz,
               Installationsscope sowie den unabhängigen @PlanXml-Pfad.
Ausführung   : sqlcmd-Arbeitsverzeichnis muss Code/Install sein.
Datenschutz  : Ausschließlich generische synthetische Testwerte.
===============================================================================
*/
SET NOCOUNT ON;

IF TRY_CONVERT(int,SERVERPROPERTY(N'ProductMajorVersion'))<>17
    THROW 53620,N'Der Standalone-Installervertrag ist während der Entwicklung für SQL Server 2025 vorgesehen.',1;

IF EXISTS
(
    SELECT 1
    FROM [sys].[database_query_store_options] WITH (NOLOCK)
    WHERE [actual_state_desc]<>N'OFF'
)
    THROW 53621,N'Query Store muss für den unabhängigen Standalone-Test deaktiviert sein.',1;

CREATE TABLE [#193_ExecutionPlanAnalysis_Standalone_Runtime_Contract_Baseline]
(
      [MetricName] varchar(64) NOT NULL PRIMARY KEY
    , [MetricCount] bigint NOT NULL
    , [MetricChecksum] int NULL
);

INSERT [#193_ExecutionPlanAnalysis_Standalone_Runtime_Contract_Baseline]
(
      [MetricName]
    , [MetricCount]
    , [MetricChecksum]
)
SELECT
      'SERVER_EVENT_SESSIONS'
    , COUNT_BIG(*)
    , CHECKSUM_AGG(BINARY_CHECKSUM([event_session_id],[name],[startup_state]))
FROM [sys].[server_event_sessions] WITH (NOLOCK);
GO

/* 1. Erstinstallation des eigenständigen Teilprojekts. */
:r Install_ExecutionPlanAnalysis.sql

/* 2. Beide öffentlichen Procedures mit synthetischer Evidenz aufrufen. */
:r ../Tests/PlanCache/120_ExecutionPlanAnalysis_Runtime_Contract.sql

USE [DeineDatenbank];
GO
SET NOCOUNT ON;

IF EXISTS
(
    SELECT 1
    FROM [sys].[procedures] AS [p] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[p].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [p].[name]=N'USP_ShowplanAnalysis'
)
    THROW 53622,N'Die Erstinstallation hat USP_ShowplanAnalysis unerwartet installiert.',1;

CREATE USER [ExampleStandaloneUser] WITHOUT LOGIN;
GRANT EXECUTE ON [monitor].[USP_ExecutionPlanAnalysis] TO [ExampleStandaloneUser];
GRANT EXECUTE ON [monitor].[USP_CreateExecutionEvidenceJson] TO [ExampleStandaloneUser];
GO

EXECUTE AS USER=N'ExampleStandaloneUser';

DECLARE @Plan xml=N'
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.600" Build="17.0.1000.1">
  <BatchSequence><Batch><Statements>
    <StmtSimple StatementId="1" StatementCompId="1" StatementType="SELECT" StatementText="SELECT ExampleValue" StatementSubTreeCost="0.1" StatementEstRows="1" StatementOptmLevel="TRIVIAL" QueryHash="0x0303030303030303" QueryPlanHash="0x3333333333333333">
      <QueryPlan CardinalityEstimationModelVersion="170" CompileTime="1" CompileCPU="1" CompileMemory="64">
        <RelOp NodeId="0" PhysicalOp="Constant Scan" LogicalOp="Constant Scan" EstimateRows="1" EstimatedTotalSubtreeCost="0.1">
          <RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="1" ActualExecutions="1" /></RunTimeInformation>
          <ConstantScan />
        </RelOp>
      </QueryPlan>
    </StmtSimple>
  </Statements></Batch></BatchSequence>
</ShowPlanXML>';
DECLARE
      @AnalysisJson nvarchar(max)
    , @AnalysisStatus varchar(40)
    , @AnalysisPartial bit
    , @AnalysisError int
    , @AnalysisMessage nvarchar(2048);

EXEC [monitor].[USP_ExecutionPlanAnalysis]
      @PlanXml=@Plan
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@AnalysisJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@AnalysisStatus OUTPUT
    , @IsPartialOut=@AnalysisPartial OUTPUT
    , @ErrorNumberOut=@AnalysisError OUTPUT
    , @ErrorMessageOut=@AnalysisMessage OUTPUT;

IF @AnalysisStatus NOT IN ('AVAILABLE','PARTIAL') OR ISJSON(@AnalysisJson)<>1
    THROW 53623,N'Der berechtigungsarme Standalone-Aufruf der Plananalyse ist fehlgeschlagen.',1;

DECLARE
      @EvidenceJson nvarchar(max)
    , @EvidenceStatus varchar(40)
    , @EvidencePartial bit
    , @EvidenceError int
    , @EvidenceMessage nvarchar(2048);

EXEC [monitor].[USP_CreateExecutionEvidenceJson]
      @StatisticsIoText=N'Table ''ExampleObject''. Scan count 1, logical reads 2, physical reads 0, read-ahead reads 0, lob logical reads 0, lob physical reads 0, lob read-ahead reads 0.'
    , @StatisticsTimeText=N'SQL Server Execution Times: CPU time = 1 ms, elapsed time = 1 ms.'
    , @ResultSetArt='NONE'
    , @Json=@EvidenceJson OUTPUT
    , @PrintMeldungen=0
    , @StatusCodeOut=@EvidenceStatus OUTPUT
    , @IsPartialOut=@EvidencePartial OUTPUT
    , @ErrorNumberOut=@EvidenceError OUTPUT
    , @ErrorMessageOut=@EvidenceMessage OUTPUT;

IF @EvidenceStatus NOT IN ('AVAILABLE','PARTIAL') OR ISJSON(@EvidenceJson)<>1
    THROW 53624,N'Der berechtigungsarme Standalone-Aufruf des Evidenzerzeugers ist fehlgeschlagen.',1;

REVERT;
DROP USER [ExampleStandaloneUser];
GO

/* Synthetische lokale Konfiguration muss die erneute Installation überleben. */
INSERT [monitor].[PlanAnalysisProfile]
(
      [ProfileCode]
    , [Description]
    , [Priority]
    , [IsEnabled]
    , [IsFrameworkDefault]
    , [SeedVersion]
    , [LastUpdatedUtc]
)
VALUES
(
      'EXAMPLE_LOCAL'
    , N'Synthetic local profile for the standalone installer contract.'
    , 900
    , 1
    , 0
    , 0
    , CONVERT(datetime2(0),'2026-01-01T00:00:00')
);

INSERT [monitor].[PlanAnalysisRuleThreshold]
(
      [RuleCode]
    , [ProfileCode]
    , [Severity]
    , [IsEnabled]
    , [MinRatio]
    , [RequiredEvidenceLevel]
    , [IsFrameworkDefault]
    , [SeedVersion]
    , [LastUpdatedUtc]
)
VALUES
(
      'EXAMPLE_CUSTOM_RULE'
    , 'EXAMPLE_LOCAL'
    , 'INFO'
    , 1
    , CONVERT(decimal(19,6),2.500000)
    , 'RUNTIME_MEASURED'
    , 0
    , 0
    , CONVERT(datetime2(0),'2026-01-01T00:00:00')
);

INSERT [monitor].[PlanAnalysisProfileAssignment]
(
      [Priority]
    , [IsEnabled]
    , [ProfileCode]
    , [DatabaseNamePattern]
    , [IsFrameworkDefault]
    , [Comment]
    , [LastUpdatedUtc]
)
VALUES
(
      900
    , 1
    , 'EXAMPLE_LOCAL'
    , N'ExampleDatabase%'
    , 0
    , N'Synthetic local assignment for the standalone installer contract.'
    , CONVERT(datetime2(0),'2026-01-01T00:00:00')
);
GO

/* 3. Zweite Installation zur realen Idempotenzprüfung. */
:r Install_ExecutionPlanAnalysis.sql

USE [DeineDatenbank];
GO
SET NOCOUNT ON;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[PlanAnalysisProfile]
    WHERE [ProfileCode]='EXAMPLE_LOCAL'
      AND [Description]=N'Synthetic local profile for the standalone installer contract.'
      AND [IsFrameworkDefault]=0
      AND [SeedVersion]=0
      AND [LastUpdatedUtc]=CONVERT(datetime2(0),'2026-01-01T00:00:00')
)
    THROW 53625,N'Die erneute Installation hat das synthetische lokale Profil verändert oder entfernt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[PlanAnalysisRuleThreshold]
    WHERE [RuleCode]='EXAMPLE_CUSTOM_RULE'
      AND [ProfileCode]='EXAMPLE_LOCAL'
      AND [Severity]='INFO'
      AND [MinRatio]=CONVERT(decimal(19,6),2.500000)
      AND [IsFrameworkDefault]=0
      AND [SeedVersion]=0
      AND [LastUpdatedUtc]=CONVERT(datetime2(0),'2026-01-01T00:00:00')
)
    THROW 53626,N'Die erneute Installation hat den synthetischen lokalen Schwellenwert verändert oder entfernt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[PlanAnalysisProfileAssignment]
    WHERE [ProfileCode]='EXAMPLE_LOCAL'
      AND [DatabaseNamePattern]=N'ExampleDatabase%'
      AND [IsFrameworkDefault]=0
      AND [Comment]=N'Synthetic local assignment for the standalone installer contract.'
      AND [LastUpdatedUtc]=CONVERT(datetime2(0),'2026-01-01T00:00:00')
)
    THROW 53627,N'Die erneute Installation hat die synthetische lokale Profilzuordnung verändert oder entfernt.',1;

/* 4. Nur die transitive PLAN-001-Abhängigkeitsschließung darf vorhanden sein. */
DECLARE @ExpectedObjects TABLE
(
      [ObjectName] sysname NOT NULL PRIMARY KEY
    , [ObjectType] char(2) NOT NULL
);

INSERT @ExpectedObjects([ObjectName],[ObjectType])
VALUES
  (N'VW_AnalyseClassCatalog','V')
, (N'VW_AnalyseAccessPolicy','V')
, (N'VW_AnalyseAccessCurrent','V')
, (N'TVF_ParsePipeList','TF')
, (N'TVF_ParseBigintList','IF')
, (N'InternalCheckAnalysisPath','P')
, (N'InternalWriteResultTable','P')
, (N'InternalPrepareResultTables','P')
, (N'InternalEmitConsoleResult','P')
, (N'PlanAnalysisProfile','U')
, (N'PlanAnalysisRuleThreshold','U')
, (N'PlanAnalysisProfileAssignment','U')
, (N'TVF_ParseStatisticsIoText','TF')
, (N'TVF_ParseStatisticsTimeText','TF')
, (N'TVF_ExecutionPlanObjectReferences','IF')
, (N'TVF_ExecutionPlanStatisticsUsage','IF')
, (N'TVF_ExecutionPlanColumnReferences','IF')
, (N'InternalCollectExecutionPlanMetadata','P')
, (N'InternalAnalyzeExecutionPlan','P')
, (N'USP_CreateExecutionEvidenceJson','P')
, (N'USP_ExecutionPlanAnalysis','P');

IF EXISTS
(
    SELECT 1
    FROM @ExpectedObjects AS [e]
    LEFT JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[name]=N'monitor'
    LEFT JOIN [sys].[objects] AS [o] WITH (NOLOCK)
      ON [o].[schema_id]=[s].[schema_id]
     AND [o].[name]=[e].[ObjectName]
     AND [o].[type] COLLATE DATABASE_DEFAULT=[e].[ObjectType]
    WHERE [o].[object_id] IS NULL
)
    THROW 53628,N'Die Standalone-Installation enthält nicht alle erforderlichen PLAN-001-Objekte.',1;

IF EXISTS
(
    SELECT 1
    FROM [sys].[objects] AS [o] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[o].[schema_id]
    LEFT JOIN @ExpectedObjects AS [e]
      ON [e].[ObjectName]=[o].[name]
     AND [e].[ObjectType]=[o].[type] COLLATE DATABASE_DEFAULT
    WHERE [s].[name]=N'monitor'
      AND [o].[type] IN ('U','V','P','IF','TF','FN')
      AND [o].[is_ms_shipped]=0
      AND [e].[ObjectName] IS NULL
)
    THROW 53629,N'Die Standalone-Installation enthält ein unnötiges Frameworkmodul.',1;

/* 5. Keine unresolved Abhängigkeit zu einem nicht installierten monitor-Modul. */
IF EXISTS
(
    SELECT 1
    FROM [sys].[sql_expression_dependencies] AS [d] WITH (NOLOCK)
    JOIN [sys].[objects] AS [referencing] WITH (NOLOCK)
      ON [referencing].[object_id]=[d].[referencing_id]
    JOIN [sys].[schemas] AS [referencingSchema] WITH (NOLOCK)
      ON [referencingSchema].[schema_id]=[referencing].[schema_id]
    LEFT JOIN @ExpectedObjects AS [expectedReferenced]
      ON [expectedReferenced].[ObjectName]=[d].[referenced_entity_name]
    WHERE [referencingSchema].[name]=N'monitor'
      AND [referencing].[type] IN ('V','P','IF','TF','FN')
      AND [d].[referenced_database_name] IS NULL
      AND [d].[referenced_schema_name]=N'monitor'
      AND [expectedReferenced].[ObjectName] IS NULL
)
    THROW 53630,N'Die Standalone-Installation besitzt eine unresolved Abhängigkeit zu einem nicht installierten monitor-Modul.',1;

IF EXISTS
(
    SELECT 1
    FROM [sys].[procedures] AS [p] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[p].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [p].[name]=N'USP_ShowplanAnalysis'
)
    THROW 53631,N'USP_ShowplanAnalysis wurde durch den Standalone-Installer installiert.',1;

IF EXISTS
(
    SELECT 1
    FROM [sys].[database_query_store_options] WITH (NOLOCK)
    WHERE [actual_state_desc]<>N'OFF'
)
    THROW 53632,N'Der Standalone-Test hat Query Store aktiviert oder benötigt.',1;

IF EXISTS
(
    SELECT 1
    FROM [#193_ExecutionPlanAnalysis_Standalone_Runtime_Contract_Baseline] AS [b]
    CROSS APPLY
    (
        SELECT
              COUNT_BIG(*) AS [MetricCount]
            , CHECKSUM_AGG(BINARY_CHECKSUM([event_session_id],[name],[startup_state])) AS [MetricChecksum]
        FROM [sys].[server_event_sessions] WITH (NOLOCK)
    ) AS [currentState]
    WHERE [b].[MetricName]='SERVER_EVENT_SESSIONS'
      AND
      (
           [b].[MetricCount]<>[currentState].[MetricCount]
        OR ISNULL([b].[MetricChecksum],0)<>ISNULL([currentState].[MetricChecksum],0)
      )
)
    THROW 53633,N'Der Standalone-Test hat die Extended-Events-Sessionkonfiguration verändert.',1;

DELETE [monitor].[PlanAnalysisProfileAssignment]
WHERE [ProfileCode]='EXAMPLE_LOCAL';

DELETE [monitor].[PlanAnalysisRuleThreshold]
WHERE [ProfileCode]='EXAMPLE_LOCAL';

DELETE [monitor].[PlanAnalysisProfile]
WHERE [ProfileCode]='EXAMPLE_LOCAL';

SELECT
      N'ExecutionPlanAnalysisStandalone' AS [ContractName]
    , N'PASSED' AS [StatusCode]
    , N'First install, public APIs, reinstall, scope and independence passed with synthetic values only.' AS [Detail];
GO
