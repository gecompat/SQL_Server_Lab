USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 122_DIAG004_Request_Context_Runtime_Contract.sql
Zweck        : Prüft die kanonischen DIAG-004-Resultsets, Status- und
               Zeitsemantik von monitor.USP_CurrentRequests.
Datenschutz  : Ausschließlich flüchtige Metadaten des aktuellen Testaufrufs;
               keine Ausgabe wird in Repositoryartefakte übernommen.
Nebenwirkung : Ausschließlich lokale Temp-Tabellen.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @RequestJson nvarchar(max);
EXEC [monitor].[USP_CurrentRequests]
      @EigeneSessionsModus='ALLE'
    , @AktuelleSessionEinbeziehen=1
    , @SystemSessionsEinbeziehen=1
    , @ToolHintergrundabfragenEinbeziehen=1
    , @MitSqlText=0
    , @GesamtenSqlTextEinbeziehen=0
    , @InputBufferEinbeziehen=0
    , @ModulInfoEinbeziehen=0
    , @MaxZeilen=50
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@RequestJson OUTPUT
    , @PrintMeldungen=0;

IF ISJSON(@RequestJson)<>1
   OR TRY_CONVERT(int,JSON_VALUE(@RequestJson,N'$.meta.schemaVersion'))<>4
   OR JSON_VALUE(@RequestJson,N'$.meta.evidenceSnapshotId') IS NULL
   OR JSON_QUERY(@RequestJson,N'$.requests') IS NULL
   OR JSON_QUERY(@RequestJson,N'$.requestContext') IS NULL
   OR JSON_QUERY(@RequestJson,N'$.snapshotStatus') IS NULL
   OR JSON_QUERY(@RequestJson,N'$.statements') IS NULL
   OR JSON_QUERY(@RequestJson,N'$.batches') IS NULL
   OR JSON_QUERY(@RequestJson,N'$.inputBuffers') IS NULL
   OR JSON_QUERY(@RequestJson,N'$.warnings') IS NULL
    THROW 52122,N'Der DIAG-004-JSON-Hüllenvertrag ist unvollständig.',1;

DECLARE @ContextCount int=
    (SELECT COUNT(*) FROM OPENJSON(@RequestJson,N'$.requestContext'));
DECLARE @StatementCount int=
    (SELECT COUNT(*) FROM OPENJSON(@RequestJson,N'$.statements'));
DECLARE @BatchCount int=
    (SELECT COUNT(*) FROM OPENJSON(@RequestJson,N'$.batches'));
DECLARE @InputBufferCount int=
    (SELECT COUNT(*) FROM OPENJSON(@RequestJson,N'$.inputBuffers'));

IF @ContextCount<1
   OR @StatementCount<>@ContextCount
   OR @BatchCount<>@ContextCount
   OR @InputBufferCount<>@ContextCount
    THROW 52122,N'Die Text- und Kontextresultsets besitzen keine konsistente Request-Kardinalität.',1;

DECLARE @JsonSnapshotId nvarchar(36)=
    JSON_VALUE(@RequestJson,N'$.meta.evidenceSnapshotId');

IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@RequestJson,N'$.requestContext')
    WITH
    (
          [SnapshotId] nvarchar(36) N'$.SnapshotId'
        , [CapturedAtUtc] datetime2(3) N'$.CapturedAtUtc'
        , [SessionId] int N'$.SessionId'
        , [RequestId] int N'$.RequestId'
        , [StatusCode] varchar(40) N'$.StatusCode'
        , [EvidenceBoundary] nvarchar(512) N'$.EvidenceBoundary'
    ) AS [c]
    WHERE [c].[SnapshotId]<>@JsonSnapshotId
       OR [c].[CapturedAtUtc] IS NULL
       OR [c].[SessionId] IS NULL
       OR [c].[RequestId] IS NULL
       OR [c].[StatusCode] NOT IN ('AVAILABLE','AVAILABLE_LIMITED')
       OR NULLIF([c].[EvidenceBoundary],N'') IS NULL
)
    THROW 52122,N'requestContext verletzt Identitäts-, Zeit- oder Statussemantik.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM OPENJSON(@RequestJson,N'$.snapshotStatus')
    WITH
    (
          [SnapshotId] nvarchar(36) N'$.SnapshotId'
        , [SourceCode] varchar(40) N'$.SourceCode'
        , [CapturedAtUtc] datetime2(3) N'$.CapturedAtUtc'
        , [CompletedAtUtc] datetime2(3) N'$.CompletedAtUtc'
        , [StatusCode] varchar(40) N'$.StatusCode'
    ) AS [s]
    WHERE [s].[SnapshotId]=@JsonSnapshotId
      AND [s].[SourceCode]='REQUESTS'
      AND [s].[CapturedAtUtc] IS NOT NULL
      AND [s].[CompletedAtUtc] IS NOT NULL
      AND [s].[StatusCode] IN ('AVAILABLE','AVAILABLE_LIMITED')
)
    THROW 52122,N'snapshotStatus enthält keine gültige Request-Provenienz.',1;

IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@RequestJson,N'$.statements')
    WITH
    (
          [SnapshotId] nvarchar(36) N'$.SnapshotId'
        , [StatusCode] varchar(40) N'$.StatusCode'
        , [Text] nvarchar(max) N'$.Text'
    ) AS [s]
    WHERE [s].[SnapshotId]<>@JsonSnapshotId
       OR [s].[StatusCode]<>'NOT_COLLECTED'
       OR [s].[Text] IS NOT NULL
)
    THROW 52122,N'Der nicht angeforderte Statementtext ist nicht explizit abgegrenzt.',1;

IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@RequestJson,N'$.batches')
    WITH
    (
          [SnapshotId] nvarchar(36) N'$.SnapshotId'
        , [StatusCode] varchar(40) N'$.StatusCode'
        , [Text] nvarchar(max) N'$.Text'
    ) AS [b]
    WHERE [b].[SnapshotId]<>@JsonSnapshotId
       OR [b].[StatusCode]<>'NOT_COLLECTED'
       OR [b].[Text] IS NOT NULL
)
    THROW 52122,N'Der nicht angeforderte Batchtext ist nicht explizit abgegrenzt.',1;

IF EXISTS
(
    SELECT 1
    FROM OPENJSON(@RequestJson,N'$.inputBuffers')
    WITH
    (
          [SnapshotId] nvarchar(36) N'$.SnapshotId'
        , [StatusCode] varchar(40) N'$.StatusCode'
        , [Text] nvarchar(max) N'$.Text'
    ) AS [i]
    WHERE [i].[SnapshotId]<>@JsonSnapshotId
       OR [i].[StatusCode]<>'NOT_COLLECTED'
       OR [i].[Text] IS NOT NULL
)
    THROW 52122,N'Der nicht angeforderte Input Buffer ist nicht explizit abgegrenzt.',1;

CREATE TABLE [#122_DIAG004_Request_Context_Runtime_Contract_RequestContext]([SeedColumn] bit NULL);
CREATE TABLE [#122_DIAG004_Request_Context_Runtime_Contract_SnapshotStatus]([SeedColumn] bit NULL);
CREATE TABLE [#122_DIAG004_Request_Context_Runtime_Contract_Statements]([SeedColumn] bit NULL);
CREATE TABLE [#122_DIAG004_Request_Context_Runtime_Contract_Batches]([SeedColumn] bit NULL);
CREATE TABLE [#122_DIAG004_Request_Context_Runtime_Contract_InputBuffers]([SeedColumn] bit NULL);
CREATE TABLE [#122_DIAG004_Request_Context_Runtime_Contract_Warnings]([SeedColumn] bit NULL);

EXEC [monitor].[USP_CurrentRequests]
      @EigeneSessionsModus='ALLE'
    , @AktuelleSessionEinbeziehen=1
    , @SystemSessionsEinbeziehen=1
    , @ToolHintergrundabfragenEinbeziehen=1
    , @MitSqlText=0
    , @GesamtenSqlTextEinbeziehen=0
    , @InputBufferEinbeziehen=0
    , @ModulInfoEinbeziehen=0
    , @MaxZeilen=50
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{
          "requestContext":"#122_DIAG004_Request_Context_Runtime_Contract_RequestContext",
          "snapshotStatus":"#122_DIAG004_Request_Context_Runtime_Contract_SnapshotStatus",
          "statements":"#122_DIAG004_Request_Context_Runtime_Contract_Statements",
          "batches":"#122_DIAG004_Request_Context_Runtime_Contract_Batches",
          "inputBuffers":"#122_DIAG004_Request_Context_Runtime_Contract_InputBuffers",
          "warnings":"#122_DIAG004_Request_Context_Runtime_Contract_Warnings"
      }'
    , @JsonErzeugen=0
    , @PrintMeldungen=0;

IF NOT EXISTS
(
    SELECT 1
    FROM [#122_DIAG004_Request_Context_Runtime_Contract_RequestContext]
    WHERE [SnapshotId] IS NOT NULL
      AND [CapturedAtUtc] IS NOT NULL
      AND [StatusCode] IN ('AVAILABLE','AVAILABLE_LIMITED')
      AND NULLIF([EvidenceBoundary],N'') IS NOT NULL
)
    THROW 52122,N'Der TABLE-Vertrag für requestContext ist leer oder ungültig.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [#122_DIAG004_Request_Context_Runtime_Contract_SnapshotStatus]
    WHERE [SourceCode]='REQUESTS'
      AND [SnapshotId] IS NOT NULL
      AND [CapturedAtUtc] IS NOT NULL
      AND [CompletedAtUtc] IS NOT NULL
)
    THROW 52122,N'Der TABLE-Vertrag für snapshotStatus ist ungültig.',1;

IF EXISTS
(
    SELECT 1
    FROM [#122_DIAG004_Request_Context_Runtime_Contract_Statements]
    WHERE [StatusCode]<>'NOT_COLLECTED' OR [Text] IS NOT NULL
)
   OR EXISTS
(
    SELECT 1
    FROM [#122_DIAG004_Request_Context_Runtime_Contract_Batches]
    WHERE [StatusCode]<>'NOT_COLLECTED' OR [Text] IS NOT NULL
)
   OR EXISTS
(
    SELECT 1
    FROM [#122_DIAG004_Request_Context_Runtime_Contract_InputBuffers]
    WHERE [StatusCode]<>'NOT_COLLECTED' OR [Text] IS NOT NULL
)
    THROW 52122,N'Die TABLE-Textresultsets verletzen die NOT_COLLECTED-Semantik.',1;

IF EXISTS
(
    SELECT 1
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id]=[c].[object_id]
    WHERE [t].[name] LIKE N'#122_DIAG004_Request_Context_Runtime_Contract[_]%'
      AND [c].[name]=N'SeedColumn'
)
    THROW 52122,N'Mindestens ein benanntes TABLE-Ziel behielt die Seed-Struktur.',1;

SELECT
      N'DIAG004RequestContext' AS [ContractName]
    , N'PASS' AS [StatusCode]
    , @ContextCount AS [JsonRequestContextRows]
    , CONVERT(int,(SELECT COUNT(*) FROM [#122_DIAG004_Request_Context_Runtime_Contract_RequestContext])) AS [TableRequestContextRows];
GO
