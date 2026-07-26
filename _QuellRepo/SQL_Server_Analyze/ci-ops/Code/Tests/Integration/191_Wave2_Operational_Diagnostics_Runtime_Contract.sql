USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 191_Wave2_Operational_Diagnostics_Runtime_Contract.sql
Zweck        : Prüft OPS-001 bis OPS-004 auf installierte Signaturen, JSON-,
               TABLE-, CONSOLE-, Leer- und eingeschränkte Berechtigungspfade.
Datenschutz  : Ausschließlich synthetische Namen und ein absichtlich nicht
               treffender Errorlog-Suchtext. Laufzeitwerte werden nicht in
               Dateien oder Evidence-Artefakte geschrieben.
Nebenwirkung : Temporärer synthetischer Datenbankbenutzer; wird immer entfernt.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

CREATE TABLE [#Wave2OperationalDiagnosticsRuntimeContract_Failure]
(
      [TestName] sysname NOT NULL
    , [Detail] nvarchar(2048) NOT NULL
);

DECLARE @ExpectedObjects TABLE([ObjectName] sysname NOT NULL PRIMARY KEY);
INSERT @ExpectedObjects VALUES
  (N'USP_DatabaseConfigurationAnalysis'),(N'USP_WorkerPressureAnalysis'),(N'USP_ErrorLogAnalysis');

INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure]
SELECT N'OBJECT_MISSING',CONCAT(N'Fehlende Procedure: monitor.',[e].[ObjectName])
FROM @ExpectedObjects AS [e]
WHERE NOT EXISTS
(
    SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id]
    WHERE [s].[name]=N'monitor' AND [p].[name]=[e].[ObjectName]
);

IF NOT EXISTS
(
    SELECT 1 FROM [sys].[parameters] AS [p] WITH (NOLOCK)
    INNER JOIN [sys].[procedures] AS [o] WITH (NOLOCK) ON [o].[object_id]=[p].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
    WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_CurrentIO' AND [p].[name]=N'@PendingIoEinbeziehen'
)
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure]
    VALUES(N'PENDING_IO_SIGNATURE',N'USP_CurrentIO besitzt den Pending-I/O-Vertrag nicht.');

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ClassifyErrorLogEvent]
         ('SQL_SERVER','CUSTOM_FILTER',N'Example synthetic Error: 824 classification')
    WHERE [Category]='IO_ERROR'
)
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure]
    VALUES(N'ERRORLOG_CLASSIFICATION',N'Die reine synthetische Errorlog-Klassifizierung lieferte nicht IO_ERROR.');

DECLARE @CurrentIoJson nvarchar(max)=NULL,@WorkerJson nvarchar(max)=NULL;
DECLARE @ConfigurationJson nvarchar(max)=NULL,@ErrorLogJson nvarchar(max)=NULL;
DECLARE @SyntheticSince datetime2(3)=DATEADD(MINUTE,-1,CONVERT(datetime2(3),SYSDATETIME()));

EXEC [monitor].[USP_CurrentIO]
      @DatabaseNames=N'ExampleMissingDatabase'
    , @PendingIoEinbeziehen=1
    , @SampleSeconds=0
    , @MaxZeilen=5
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@CurrentIoJson OUTPUT
    , @PrintMeldungen=0;

EXEC [monitor].[USP_WorkerPressureAnalysis]
      @SampleSeconds=0
    , @MinRequestElapsedMs=2147483647
    , @MaxZeilen=5
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@WorkerJson OUTPUT
    , @PrintMeldungen=0;

EXEC [monitor].[USP_DatabaseConfigurationAnalysis]
      @ProfileJson=N'[{"settingScope":"DATABASE","settingName":"COMPATIBILITY_LEVEL","expectedValue":"ExampleSyntheticValue"}]'
    , @MaxZeilen=20
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@ConfigurationJson OUTPUT
    , @PrintMeldungen=0;

EXEC [monitor].[USP_ErrorLogAnalysis]
      @SeitServerlokalzeit=@SyntheticSince
    , @Suchtext1=N'ExampleWave2SyntheticNoMatch_8F9C2A'
    , @MeldungstextEinbeziehen=0
    , @MaxQuellzeilen=20
    , @MaxZeilen=5
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@ErrorLogJson OUTPUT
    , @PrintMeldungen=0;

IF COALESCE(ISJSON(@CurrentIoJson),0)<>1 OR JSON_QUERY(@CurrentIoJson,'$.pendingIo') IS NULL OR JSON_QUERY(@CurrentIoJson,'$.sourceStatus') IS NULL
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'CURRENT_IO_JSON',N'Pending-I/O- oder Source-Status-JSON fehlt.');
IF COALESCE(ISJSON(@WorkerJson),0)<>1 OR JSON_QUERY(@WorkerJson,'$.summary') IS NULL OR JSON_QUERY(@WorkerJson,'$.schedulers') IS NULL
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'WORKER_JSON',N'Worker-/Scheduler-JSON fehlt.');
IF COALESCE(ISJSON(@ConfigurationJson),0)<>1 OR JSON_QUERY(@ConfigurationJson,'$.settings') IS NULL OR JSON_QUERY(@ConfigurationJson,'$.drift') IS NULL
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'CONFIGURATION_JSON',N'Konfigurations- oder Drift-JSON fehlt.');
IF COALESCE(ISJSON(@ConfigurationJson),0)=1
   AND NOT EXISTS
   (
       SELECT 1
       FROM OPENJSON(@ConfigurationJson,'$.drift')
            WITH ([FindingCode] varchar(80) '$.FindingCode') AS [d]
       WHERE [d].[FindingCode]='EXPLICIT_PROFILE_MISMATCH'
   )
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'CONFIGURATION_POSITIVE',N'Das synthetische Vergleichsprofil erzeugte keinen expliziten Profilbefund.');
IF COALESCE(ISJSON(@ErrorLogJson),0)<>1 OR JSON_QUERY(@ErrorLogJson,'$.summary') IS NULL OR JSON_QUERY(@ErrorLogJson,'$.sourceStatus') IS NULL
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'ERRORLOG_JSON',N'Errorlog-Summary- oder Source-Status-JSON fehlt.');

CREATE TABLE [#Wave2OperationalDiagnosticsRuntimeContract_CurrentIoPending]([Seed] bit NULL);
CREATE TABLE [#Wave2OperationalDiagnosticsRuntimeContract_CurrentIoSource]([Seed] bit NULL);
CREATE TABLE [#Wave2OperationalDiagnosticsRuntimeContract_WorkerSummary]([Seed] bit NULL);
CREATE TABLE [#Wave2OperationalDiagnosticsRuntimeContract_ConfigurationDrift]([Seed] bit NULL);
CREATE TABLE [#Wave2OperationalDiagnosticsRuntimeContract_ErrorSummary]([Seed] bit NULL);
CREATE TABLE [#Wave2OperationalDiagnosticsRuntimeContract_ErrorDetails]([Seed] bit NULL);

EXEC [monitor].[USP_CurrentIO]
      @DatabaseNames=N'ExampleMissingDatabase'
    , @PendingIoEinbeziehen=1
    , @SampleSeconds=0
    , @MaxZeilen=5
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"pendingIo":"#Wave2OperationalDiagnosticsRuntimeContract_CurrentIoPending","sourceStatus":"#Wave2OperationalDiagnosticsRuntimeContract_CurrentIoSource"}'
    , @PrintMeldungen=0;

EXEC [monitor].[USP_WorkerPressureAnalysis]
      @SampleSeconds=0
    , @MinRequestElapsedMs=2147483647
    , @MaxZeilen=5
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"summary":"#Wave2OperationalDiagnosticsRuntimeContract_WorkerSummary"}'
    , @PrintMeldungen=0;

EXEC [monitor].[USP_DatabaseConfigurationAnalysis]
      @DatabaseNames=N'ExampleMissingDatabase'
    , @MaxZeilen=5
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"drift":"#Wave2OperationalDiagnosticsRuntimeContract_ConfigurationDrift"}'
    , @PrintMeldungen=0;

EXEC [monitor].[USP_ErrorLogAnalysis]
      @SeitServerlokalzeit=@SyntheticSince
    , @Suchtext1=N'ExampleWave2SyntheticNoMatch_8F9C2A'
    , @MeldungstextEinbeziehen=0
    , @MaxQuellzeilen=20
    , @MaxZeilen=5
    , @ResultSetArt='TABLE'
    , @ResultTablesJson=N'{"summary":"#Wave2OperationalDiagnosticsRuntimeContract_ErrorSummary","details":"#Wave2OperationalDiagnosticsRuntimeContract_ErrorDetails"}'
    , @PrintMeldungen=0;

IF NOT EXISTS
(
    SELECT 1 FROM [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [tempdb].[sys].[columns] AS [c] WITH (NOLOCK) ON [c].[object_id]=[t].[object_id]
    WHERE [t].[name] LIKE N'#Wave2OperationalDiagnosticsRuntimeContract_CurrentIoPending%'
      AND [c].[name]=N'PendingDurationMs'
)
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'CURRENT_IO_TABLE',N'pendingIo-TABLE-Schema fehlt.');
IF NOT EXISTS
(
    SELECT 1 FROM [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [tempdb].[sys].[columns] AS [c] WITH (NOLOCK) ON [c].[object_id]=[t].[object_id]
    WHERE [t].[name] LIKE N'#Wave2OperationalDiagnosticsRuntimeContract_WorkerSummary%'
      AND [c].[name]=N'FindingCode'
)
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'WORKER_TABLE',N'Worker-Summary-TABLE-Schema fehlt.');
IF NOT EXISTS
(
    SELECT 1 FROM [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [tempdb].[sys].[columns] AS [c] WITH (NOLOCK) ON [c].[object_id]=[t].[object_id]
    WHERE [t].[name] LIKE N'#Wave2OperationalDiagnosticsRuntimeContract_ConfigurationDrift%'
      AND [c].[name]=N'DriftType'
)
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'CONFIGURATION_TABLE',N'Drift-TABLE-Schema fehlt.');
IF NOT EXISTS
(
    SELECT 1 FROM [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [tempdb].[sys].[columns] AS [c] WITH (NOLOCK) ON [c].[object_id]=[t].[object_id]
    WHERE [t].[name] LIKE N'#Wave2OperationalDiagnosticsRuntimeContract_ErrorSummary%'
      AND [c].[name]=N'Category'
)
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'ERRORLOG_TABLE',N'Errorlog-Summary-TABLE-Schema fehlt.');
IF EXISTS(SELECT 1 FROM [#Wave2OperationalDiagnosticsRuntimeContract_ErrorDetails])
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'ERRORLOG_DEFAULT_DETAIL',N'Der Defaultpfad gab trotz deaktiviertem Meldungstext Detailzeilen aus.');

/* Eingeschränkter Benutzer: Fehler werden in Status/JSON überführt, nicht nach außen geworfen. */
DROP USER IF EXISTS [ExampleWave2RestrictedUser];
CREATE USER [ExampleWave2RestrictedUser] WITHOUT LOGIN;
GRANT EXECUTE ON [monitor].[USP_CurrentIO] TO [ExampleWave2RestrictedUser];
GRANT EXECUTE ON [monitor].[USP_WorkerPressureAnalysis] TO [ExampleWave2RestrictedUser];
GRANT EXECUTE ON [monitor].[USP_DatabaseConfigurationAnalysis] TO [ExampleWave2RestrictedUser];
GRANT EXECUTE ON [monitor].[USP_ErrorLogAnalysis] TO [ExampleWave2RestrictedUser];

BEGIN TRY
    EXECUTE AS USER=N'ExampleWave2RestrictedUser';
    DECLARE @DeniedIo nvarchar(max)=NULL,@DeniedWorker nvarchar(max)=NULL,@DeniedConfiguration nvarchar(max)=NULL,@DeniedErrorLog nvarchar(max)=NULL;
    EXEC [monitor].[USP_CurrentIO] @DatabaseNames=N'ExampleMissingDatabase',@PendingIoEinbeziehen=1,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@DeniedIo OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_WorkerPressureAnalysis] @SampleSeconds=0,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@DeniedWorker OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_DatabaseConfigurationAnalysis] @DatabaseNames=N'ExampleMissingDatabase',@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@DeniedConfiguration OUTPUT,@PrintMeldungen=0;
    EXEC [monitor].[USP_ErrorLogAnalysis] @SeitServerlokalzeit=@SyntheticSince,@Suchtext1=N'ExampleWave2SyntheticNoMatch_8F9C2A',@MaxQuellzeilen=20,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@DeniedErrorLog OUTPUT,@PrintMeldungen=0;
    REVERT;
    IF COALESCE(ISJSON(@DeniedIo),0)<>1 OR COALESCE(ISJSON(@DeniedWorker),0)<>1 OR COALESCE(ISJSON(@DeniedConfiguration),0)<>1 OR COALESCE(ISJSON(@DeniedErrorLog),0)<>1
        INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'DENIED_JSON',N'Mindestens ein eingeschränkter Pfad lieferte kein gültiges JSON.');
END TRY
BEGIN CATCH
    IF USER_NAME()=N'ExampleWave2RestrictedUser' REVERT;
    INSERT [#Wave2OperationalDiagnosticsRuntimeContract_Failure] VALUES(N'DENIED_PATH',CONCAT(N'Eingeschränkter Pfad warf Fehler ',ERROR_NUMBER(),N'.'));
END CATCH;
DROP USER IF EXISTS [ExampleWave2RestrictedUser];

/* Leere, synthetische CONSOLE-Pfade: keine realen Datenbank- oder Meldungswerte. */
EXEC [monitor].[USP_CurrentIO] @DatabaseNames=N'ExampleMissingDatabase',@PendingIoEinbeziehen=0,@MaxZeilen=1,@ResultSetArt='CONSOLE',@PrintMeldungen=0;
EXEC [monitor].[USP_WorkerPressureAnalysis] @SampleSeconds=0,@MinRequestElapsedMs=2147483647,@MaxZeilen=1,@ResultSetArt='CONSOLE',@PrintMeldungen=0;
EXEC [monitor].[USP_DatabaseConfigurationAnalysis] @DatabaseNames=N'ExampleMissingDatabase',@MaxZeilen=1,@ResultSetArt='CONSOLE',@PrintMeldungen=0;
EXEC [monitor].[USP_ErrorLogAnalysis] @SeitServerlokalzeit=@SyntheticSince,@Suchtext1=N'ExampleWave2SyntheticNoMatch_8F9C2A',@MaxQuellzeilen=20,@MaxZeilen=1,@ResultSetArt='CONSOLE',@PrintMeldungen=0;

SELECT [TestName],[Detail] FROM [#Wave2OperationalDiagnosticsRuntimeContract_Failure] ORDER BY [TestName],[Detail];
IF EXISTS(SELECT 1 FROM [#Wave2OperationalDiagnosticsRuntimeContract_Failure])
    THROW 54740,N'Der Welle-2-Betriebsdiagnostikvertrag ist verletzt.',1;
GO
