USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 188_Framework_Output_Pilot_Runtime_Contract.sql
Zweck        : Validiert den Pilotvertrag für Datenbankauswahl,
               USP_CurrentIO, USP_CurrentOverview und benannte TABLE-Ziele.
Datenschutz  : Ausschließlich generische lokale Temp-Tabellen und synthetische
               nicht verfügbare Datenbanknamen; keine Laufzeitwerte werden
               persistiert oder als Testartefakt ausgegeben.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE TABLE [#FrameworkOutputPilotRuntimeContract_Failure]
(
      [TestName] sysname NOT NULL
    , [Detail] nvarchar(2048) NOT NULL
);

/* Öffentliche Pilot-API. */
IF EXISTS
(
    SELECT 1
    FROM [sys].[parameters] AS [p] WITH (NOLOCK)
    INNER JOIN [sys].[objects] AS [o] WITH (NOLOCK)
      ON [o].[object_id]=[p].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[o].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [o].[name] IN (N'USP_CurrentIO',N'USP_CurrentOverview')
      AND [p].[name] IN (N'@MaxDatenbanken',N'@ResultTable',N'@DatabaseScope')
)
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'PILOT_API_REMOVALS',N'Ein entfernter Parameter ist noch Teil der öffentlichen Pilot-API.');

IF 2<>(
    SELECT COUNT(*)
    FROM [sys].[parameters] AS [p] WITH (NOLOCK)
    INNER JOIN [sys].[objects] AS [o] WITH (NOLOCK)
      ON [o].[object_id]=[p].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[o].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [o].[name] IN (N'USP_CurrentIO',N'USP_CurrentOverview')
      AND [p].[name]=N'@ResultTablesJson'
)
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'PILOT_TABLE_PARAMETER',N'@ResultTablesJson fehlt in mindestens einer Pilot-Procedure.');

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[parameters] AS [p] WITH (NOLOCK)
    INNER JOIN [sys].[objects] AS [o] WITH (NOLOCK)
      ON [o].[object_id]=[p].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[o].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [o].[name]=N'USP_CurrentOverview'
      AND [p].[name]=N'@Detailgrad'
)
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'OVERVIEW_DETAIL_LEVEL',N'Der steuerbare Detailgrad fehlt.');

/* Datenbankstandard: alle Benutzer-, keine Systemdatenbanken. */
CREATE TABLE [#FrameworkOutputPilotRuntimeContract_Candidates]
(
      [DatabaseId] int NOT NULL
    , [DatabaseName] sysname NOT NULL
    , [StateDesc] nvarchar(60) NULL
    , [UserAccessDesc] nvarchar(60) NULL
    , [IsReadOnly] bit NULL
    , [CompatibilityLevel] tinyint NULL
    , [CollationName] sysname NULL
    , [RecoveryModelDesc] nvarchar(60) NULL
    , [IsSystemDatabase] bit NULL
    , [RequestedOrdinal] int NULL
);
CREATE TABLE [#FrameworkOutputPilotRuntimeContract_CandidateWarnings]
(
      [RequestedName] sysname NULL
    , [StatusCode] varchar(40) NOT NULL
    , [ErrorMessage] nvarchar(2048) NULL
);

DECLARE @Status varchar(40),@Error nvarchar(2048),@Cross bit;
EXEC [monitor].[USP_PrepareDatabaseCandidates]
      @DatabaseNames=NULL
    , @SystemdatenbankenEinbeziehen=0
    , @DatabaseNamePattern=NULL
    , @AnalysisClass='STANDARD_CURRENT'
    , @HighImpactConfirmed=0
    , @StatusCode=@Status OUTPUT
    , @ErrorMessage=@Error OUTPUT
    , @CrossDatabaseRequested=@Cross OUTPUT
    , @CandidateTable=N'#FrameworkOutputPilotRuntimeContract_Candidates'
    , @WarningTable=N'#FrameworkOutputPilotRuntimeContract_CandidateWarnings';

IF @Status<>'AVAILABLE'
   OR EXISTS(SELECT 1 FROM [#FrameworkOutputPilotRuntimeContract_Candidates] WHERE [DatabaseId]<=4)
   OR NOT EXISTS(SELECT 1 FROM [#FrameworkOutputPilotRuntimeContract_Candidates] WHERE [DatabaseId]>4)
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'DATABASE_DEFAULT_ALL_USER',N'Die automatische Kandidatenmenge enthält nicht ausschließlich sichtbare Online-Benutzerdatenbanken.');

TRUNCATE TABLE [#FrameworkOutputPilotRuntimeContract_Candidates];
TRUNCATE TABLE [#FrameworkOutputPilotRuntimeContract_CandidateWarnings];
SET @Status=NULL;SET @Error=NULL;SET @Cross=NULL;
EXEC [monitor].[USP_PrepareDatabaseCandidates]
      @DatabaseNames=N'[ExampleUnavailableDatabase]'
    , @SystemdatenbankenEinbeziehen=0
    , @AnalysisClass='STANDARD_CURRENT'
    , @HighImpactConfirmed=0
    , @StatusCode=@Status OUTPUT
    , @ErrorMessage=@Error OUTPUT
    , @CrossDatabaseRequested=@Cross OUTPUT
    , @CandidateTable=N'#FrameworkOutputPilotRuntimeContract_Candidates'
    , @WarningTable=N'#FrameworkOutputPilotRuntimeContract_CandidateWarnings';

IF @Status<>'AVAILABLE'
   OR NOT EXISTS
      (
          SELECT 1
          FROM [#FrameworkOutputPilotRuntimeContract_CandidateWarnings]
          WHERE [StatusCode]='DATABASE_UNAVAILABLE'
      )
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'EXPLICIT_DATABASE_WARNING',N'Eine explizit nicht verfügbare Datenbank wurde nicht strukturiert ausgewiesen.');

TRUNCATE TABLE [#FrameworkOutputPilotRuntimeContract_Candidates];
TRUNCATE TABLE [#FrameworkOutputPilotRuntimeContract_CandidateWarnings];
SET @Status=NULL;SET @Error=NULL;SET @Cross=NULL;
EXEC [monitor].[USP_PrepareDatabaseCandidates]
      @DatabaseNames=N'[master]'
    , @SystemdatenbankenEinbeziehen=0
    , @AnalysisClass='STANDARD_CURRENT'
    , @HighImpactConfirmed=0
    , @StatusCode=@Status OUTPUT
    , @ErrorMessage=@Error OUTPUT
    , @CrossDatabaseRequested=@Cross OUTPUT
    , @CandidateTable=N'#FrameworkOutputPilotRuntimeContract_Candidates'
    , @WarningTable=N'#FrameworkOutputPilotRuntimeContract_CandidateWarnings';

IF EXISTS(SELECT 1 FROM [#FrameworkOutputPilotRuntimeContract_Candidates])
   OR NOT EXISTS
      (
          SELECT 1
          FROM [#FrameworkOutputPilotRuntimeContract_CandidateWarnings]
          WHERE [StatusCode]='SYSTEM_DATABASE_EXCLUDED'
      )
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'SYSTEM_DATABASE_OPT_IN',N'Eine Systemdatenbank wurde ohne Opt-in nicht korrekt ausgeschlossen.');

TRUNCATE TABLE [#FrameworkOutputPilotRuntimeContract_Candidates];
SET @Status=NULL;SET @Error=NULL;SET @Cross=NULL;
EXEC [monitor].[USP_PrepareDatabaseCandidates]
      @DatabaseNames=NULL
    , @AnalysisClass='CROSS_DATABASE_DEEP'
    , @HighImpactConfirmed=0
    , @StatusCode=@Status OUTPUT
    , @ErrorMessage=@Error OUTPUT
    , @CrossDatabaseRequested=@Cross OUTPUT
    , @CandidateTable=N'#FrameworkOutputPilotRuntimeContract_Candidates';

IF @Status<>'HIGH_IMPACT_CONFIRMATION_REQUIRED'
   OR EXISTS(SELECT 1 FROM [#FrameworkOutputPilotRuntimeContract_Candidates])
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'HIGH_IMPACT_EARLY_GATE',N'Der breite Deep-Pfad wurde ohne Bestätigung nicht vor der Kandidatenmaterialisierung beendet.');

/* USP_CurrentIO: benannte Mehrfachausgabe aus einer Materialisierung. */
CREATE TABLE [#FrameworkOutputPilotRuntimeContract_IOStatus]([Seed] bit NULL);
CREATE TABLE [#FrameworkOutputPilotRuntimeContract_IOFiles]([Seed] bit NULL);
CREATE TABLE [#FrameworkOutputPilotRuntimeContract_IOWarnings]([Seed] bit NULL);

BEGIN TRY
    EXEC [monitor].[USP_CurrentIO]
          @MaxZeilen=100
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"moduleStatus":"#FrameworkOutputPilotRuntimeContract_IOStatus","files":"#FrameworkOutputPilotRuntimeContract_IOFiles","warnings":"#FrameworkOutputPilotRuntimeContract_IOWarnings"}'
        , @PrintMeldungen=0;

    IF NOT EXISTS
       (
           SELECT 1
           FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
           INNER JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
             ON [t].[object_id]=[c].[object_id]
           WHERE [t].[name] LIKE N'#FrameworkOutputPilotRuntimeContract_IOStatus%'
             AND [c].[name]=N'StatusCode'
       )
       OR NOT EXISTS
       (
           SELECT 1
           FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
           INNER JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
             ON [t].[object_id]=[c].[object_id]
           WHERE [t].[name] LIKE N'#FrameworkOutputPilotRuntimeContract_IOFiles%'
             AND [c].[name]=N'OverallLatencyMs'
       )
        INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'CURRENT_IO_MULTI_TABLE',N'Die benannten I/O-Ziele wurden nicht mit ihren nativen Schemas materialisiert.');
END TRY
BEGIN CATCH
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'CURRENT_IO_MULTI_TABLE',CONCAT(N'Der I/O-TABLE-Pilot ist fehlgeschlagen: ',ERROR_NUMBER()));
END CATCH;

CREATE TABLE [#FrameworkOutputPilotRuntimeContract_InvalidTarget]([Seed] bit NULL);
BEGIN TRY
    EXEC [monitor].[USP_CurrentIO]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"unknownResult":"#FrameworkOutputPilotRuntimeContract_InvalidTarget"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'UNKNOWN_RESULT_REJECTED',N'Ein unbekannter Resultsetname wurde nicht abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'UNKNOWN_RESULT_REJECTED',N'Ein unbekannter Resultsetname lieferte nicht den erwarteten Preflightfehler.');
END CATCH;

CREATE TABLE [#FrameworkOutputPilotRuntimeContract_DuplicateTarget]([Seed] bit NULL);
BEGIN TRY
    EXEC [monitor].[USP_CurrentIO]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"moduleStatus":"#FrameworkOutputPilotRuntimeContract_DuplicateTarget","files":"#FrameworkOutputPilotRuntimeContract_DuplicateTarget"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'DUPLICATE_TARGET_REJECTED',N'Ein doppelt verwendetes Ziel wurde nicht abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'DUPLICATE_TARGET_REJECTED',N'Ein doppeltes Ziel lieferte nicht den erwarteten Preflightfehler.');
END CATCH;

CREATE TABLE [#FrameworkOutputPilotRuntimeContract_Console]
(
      [Ergebnis] nvarchar(200) NULL
    , [Status] varchar(40) NULL
    , [Hinweis] nvarchar(2048) NULL
);
DECLARE @MinimumConsoleLatency decimal(19,3)=999999999.000;
BEGIN TRY
    INSERT [#FrameworkOutputPilotRuntimeContract_Console]
    EXEC [monitor].[USP_CurrentIO]
          @MinLatencyMs=@MinimumConsoleLatency
        , @PendingIoEinbeziehen=0
        , @ResultSetArt='CONSOLE'
        , @PrintMeldungen=0;

    IF (SELECT COUNT(*) FROM [#FrameworkOutputPilotRuntimeContract_Console])<>1
       OR NOT EXISTS
          (
              SELECT 1
              FROM [#FrameworkOutputPilotRuntimeContract_Console]
              WHERE [Ergebnis] LIKE N'Keine %'
          )
        INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'EMPTY_CONSOLE_ROW',N'Ein leeres I/O-Ergebnis erzeugte nicht genau eine verständliche Console-Zeile.');
END TRY
BEGIN CATCH
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'EMPTY_CONSOLE_ROW',N'Der leere CONSOLE-Pilot ist fehlgeschlagen.');
END CATCH;

/* USP_CurrentOverview: Summary und Childstatus aus genau einem Child-Aufruf. */
CREATE TABLE [#FrameworkOutputPilotRuntimeContract_OverviewStatus]([Seed] bit NULL);
CREATE TABLE [#FrameworkOutputPilotRuntimeContract_OverviewIO]([Seed] bit NULL);

BEGIN TRY
    EXEC [monitor].[USP_CurrentOverview]
          @MitSessions=0
        , @MitRequests=0
        , @MitBlocking=0
        , @MitWaits=0
        , @MitTransactions=0
        , @MitMemoryGrants=0
        , @MitTempDB=0
        , @MitIO=1
        , @MitLog=0
        , @Detailgrad='SUMMARY'
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"moduleStatus":"#FrameworkOutputPilotRuntimeContract_OverviewStatus","io":"#FrameworkOutputPilotRuntimeContract_OverviewIO"}'
        , @PrintMeldungen=0;

    DECLARE @OverviewStatusCount bigint;
    DECLARE @OverviewIoStatus varchar(40);
    EXEC [sys].[sp_executesql]
          N'SELECT @RowCount=COUNT_BIG(*),@IoStatus=MAX(CASE WHEN [ModuleName]=N''USP_CurrentIO'' THEN [StatusCode] END) FROM [#FrameworkOutputPilotRuntimeContract_OverviewStatus];'
        , N'@RowCount bigint OUTPUT,@IoStatus varchar(40) OUTPUT'
        , @RowCount=@OverviewStatusCount OUTPUT
        , @IoStatus=@OverviewIoStatus OUTPUT;

    IF @OverviewStatusCount<>9 OR @OverviewIoStatus NOT IN ('AVAILABLE','AVAILABLE_LIMITED')
        INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'OVERVIEW_CHILD_STATUS',N'Das konsolidierte Summary hat Status oder Zeilenanzahl des I/O-Childs nicht korrekt übernommen.');
END TRY
BEGIN CATCH
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'OVERVIEW_CHILD_STATUS',N'Der Overview-TABLE-Pilot ist fehlgeschlagen.');
END CATCH;

CREATE TABLE [#FrameworkOutputPilotRuntimeContract_OverviewLimited]([Seed] bit NULL);
BEGIN TRY
    EXEC [monitor].[USP_CurrentOverview]
          @DatabaseNames=N'[ExampleUnavailableDatabase]'
        , @MitSessions=0
        , @MitRequests=0
        , @MitBlocking=0
        , @MitWaits=0
        , @MitTransactions=0
        , @MitMemoryGrants=0
        , @MitTempDB=0
        , @MitIO=1
        , @MitLog=0
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"moduleStatus":"#FrameworkOutputPilotRuntimeContract_OverviewLimited"}'
        , @PrintMeldungen=0;

    DECLARE @LimitedStatus varchar(40),@LimitedPartial bit,@LimitedRows bigint;
    EXEC [sys].[sp_executesql]
          N'SELECT @Status=MAX(CASE WHEN [ModuleName]=N''USP_CurrentIO'' THEN [StatusCode] END),@Partial=MAX(CASE WHEN [ModuleName]=N''USP_CurrentIO'' THEN CONVERT(tinyint,[IsPartial]) END),@Rows=MAX(CASE WHEN [ModuleName]=N''USP_CurrentIO'' THEN [ReturnedRowCount] END) FROM [#FrameworkOutputPilotRuntimeContract_OverviewLimited];'
        , N'@Status varchar(40) OUTPUT,@Partial bit OUTPUT,@Rows bigint OUTPUT'
        , @Status=@LimitedStatus OUTPUT
        , @Partial=@LimitedPartial OUTPUT
        , @Rows=@LimitedRows OUTPUT;

    IF @LimitedStatus<>'AVAILABLE_LIMITED' OR @LimitedPartial<>1 OR @LimitedRows<>0
        INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'OVERVIEW_PARTIAL_STATUS',N'Partialität und Nullzeilenstatus des Childs wurden nicht korrekt übernommen.');
END TRY
BEGIN CATCH
    INSERT [#FrameworkOutputPilotRuntimeContract_Failure] VALUES(N'OVERVIEW_PARTIAL_STATUS',N'Der partielle Overview-Pilot ist fehlgeschlagen.');
END CATCH;

SELECT [TestName],[Detail]
FROM [#FrameworkOutputPilotRuntimeContract_Failure]
ORDER BY [TestName];

IF EXISTS(SELECT 1 FROM [#FrameworkOutputPilotRuntimeContract_Failure])
    THROW 54800,N'Der Pilotvertrag für Datenbank-, CONSOLE- oder TABLE-Ausgabe ist verletzt.',1;
GO
