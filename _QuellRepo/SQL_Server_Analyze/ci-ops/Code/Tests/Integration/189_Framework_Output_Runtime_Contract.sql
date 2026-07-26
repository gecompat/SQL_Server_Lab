USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 189_Framework_Output_Runtime_Contract.sql
Zweck        : Prüft den frameworkweiten öffentlichen CONSOLE- und benannten
               TABLE-Vertrag sowie repräsentative Leer- und Preflightpfade.
Datenschutz  : Ausschließlich generische lokale Temp-Tabellen und eine
               synthetische, nicht vorhandene Session-ID; keine Laufzeitdaten
               werden persistiert oder als Testartefakt ausgegeben.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE TABLE [#FrameworkOutputRuntimeContract_Failure]
(
      [TestName] sysname NOT NULL
    , [Detail] nvarchar(2048) NOT NULL
);

CREATE TABLE [#FrameworkOutputRuntimeContract_Public]
(
      [ObjectId] int NOT NULL PRIMARY KEY
    , [ProcedureName] sysname NOT NULL
    , [Definition] nvarchar(max) NULL
);

INSERT [#FrameworkOutputRuntimeContract_Public]([ObjectId],[ProcedureName],[Definition])
SELECT [p].[object_id],[p].[name],[m].[definition]
FROM [sys].[procedures] AS [p] WITH (NOLOCK)
INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
  ON [s].[schema_id]=[p].[schema_id]
LEFT JOIN [sys].[sql_modules] AS [m] WITH (NOLOCK)
  ON [m].[object_id]=[p].[object_id]
WHERE [s].[name]=N'monitor'
  AND [p].[name] NOT LIKE N'Internal%'
  AND [p].[name] NOT LIKE N'USP_Prepare%';

IF (SELECT COUNT(*) FROM [#FrameworkOutputRuntimeContract_Public])<>92
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'PUBLIC_INVENTORY',N'Die installierte öffentliche Procedure-Inventur enthält nicht genau 92 Vertragsobjekte.');

INSERT [#FrameworkOutputRuntimeContract_Failure]([TestName],[Detail])
SELECT N'PUBLIC_PARAMETER',CONCAT([p].[ProcedureName],N': ',[v].[ParameterName],N' fehlt.')
FROM [#FrameworkOutputRuntimeContract_Public] AS [p]
CROSS APPLY (VALUES(N'@ResultSetArt'),(N'@ResultTablesJson'),(N'@JsonErzeugen'),(N'@Json')) AS [v]([ParameterName])
WHERE NOT EXISTS
      (
          SELECT 1
          FROM [sys].[parameters] AS [sp] WITH (NOLOCK)
          WHERE [sp].[object_id]=[p].[ObjectId]
            AND [sp].[name]=[v].[ParameterName]
      );

INSERT [#FrameworkOutputRuntimeContract_Failure]([TestName],[Detail])
SELECT N'REMOVED_PARAMETER',CONCAT([p].[ProcedureName],N': ',[sp].[name],N' ist weiterhin installiert.')
FROM [#FrameworkOutputRuntimeContract_Public] AS [p]
INNER JOIN [sys].[parameters] AS [sp] WITH (NOLOCK)
  ON [sp].[object_id]=[p].[ObjectId]
WHERE [sp].[name] IN(N'@ResultTable',N'@MaxDatenbanken',N'@DatabaseScope');

INSERT [#FrameworkOutputRuntimeContract_Failure]([TestName],[Detail])
SELECT N'CONSOLE_RENDERER',CONCAT([ProcedureName],N': kein eindeutiger Console-Renderer im installierten Modul.')
FROM [#FrameworkOutputRuntimeContract_Public]
WHERE [Definition] IS NULL
   OR
   (
       [ProcedureName] NOT IN(N'USP_CurrentIO',N'USP_CurrentOverview')
       AND
       (
           [Definition] NOT LIKE N'%@ConsoleResultRequested%'
           OR [Definition] NOT LIKE N'%[[]monitor].[[]InternalEmitConsoleResult]%'
       )
   );

INSERT [#FrameworkOutputRuntimeContract_Failure]([TestName],[Detail])
SELECT N'TABLE_PREFLIGHT',CONCAT([ProcedureName],N': kein benannter TABLE-Preflight im installierten Modul.')
FROM [#FrameworkOutputRuntimeContract_Public]
WHERE [Definition] IS NULL
   OR
   (
       [Definition] NOT LIKE N'%[[]monitor].[[]InternalPrepareSingleResultTable]%'
       AND [Definition] NOT LIKE N'%[[]monitor].[[]InternalPrepareResultTables]%'
   );

/* Leeres CONSOLE-Ergebnis: genau eine verständliche Zeile. */
CREATE TABLE [#FrameworkOutputRuntimeContract_Console]
(
      [Ergebnis] nvarchar(200) NULL
    , [Status] varchar(40) NULL
    , [Hinweis] nvarchar(2048) NULL
);

BEGIN TRY
    INSERT [#FrameworkOutputRuntimeContract_Console]
    EXEC [monitor].[USP_CurrentRequests]
          @SessionIds=N'32767'
        , @MitSqlText=0
        , @MaxZeilen=1
        , @ResultSetArt='CONSOLE'
        , @PrintMeldungen=0;

    IF (SELECT COUNT(*) FROM [#FrameworkOutputRuntimeContract_Console])<>1
       OR NOT EXISTS
          (
              SELECT 1
              FROM [#FrameworkOutputRuntimeContract_Console]
              WHERE [Ergebnis]=N'Keine aktiven Requests'
          )
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'EMPTY_CONSOLE',N'Ein leeres fachliches Ergebnis erzeugte nicht genau eine verständliche Console-Zeile.');
END TRY
BEGIN CATCH
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'EMPTY_CONSOLE',CONCAT(N'Der leere Console-Aufruf ist fehlgeschlagen: ',ERROR_NUMBER(),N'.'));
END CATCH;

/* Dasselbe leere Ergebnis bleibt in TABLE künstlich zeilenlos. */
CREATE TABLE [#FrameworkOutputRuntimeContract_Requests]([Seed] bit NULL);
BEGIN TRY
    EXEC [monitor].[USP_CurrentRequests]
          @SessionIds=N'32767'
        , @MitSqlText=0
        , @MaxZeilen=1
        , @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"requests":"#FrameworkOutputRuntimeContract_Requests"}'
        , @PrintMeldungen=0;

    IF EXISTS(SELECT 1 FROM [#FrameworkOutputRuntimeContract_Requests])
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'EMPTY_TABLE',N'TABLE enthält für ein leeres fachliches Ergebnis eine künstliche Datenzeile.');
END TRY
BEGIN CATCH
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'EMPTY_TABLE',CONCAT(N'Der leere TABLE-Aufruf ist fehlgeschlagen: ',ERROR_NUMBER(),N'.'));
END CATCH;

/* Fehlerhafte Mappings werden vor dem öffentlichen Fachpfad abgelehnt. */
CREATE TABLE [#FrameworkOutputRuntimeContract_TargetA]([Seed] bit NULL);
CREATE TABLE [#FrameworkOutputRuntimeContract_TargetB]([Seed] bit NULL);

BEGIN TRY
    EXEC [monitor].[USP_CheckAnalyseAccess]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"access":"#FrameworkOutputRuntimeContract_TargetA","access":"#FrameworkOutputRuntimeContract_TargetB"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'DUPLICATE_RESULT_NAME',N'Ein doppelter Resultsetname wurde nicht abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'DUPLICATE_RESULT_NAME',CONCAT(N'Erwartet Fehler 51011, erhalten ',ERROR_NUMBER(),N'.'));
END CATCH;

BEGIN TRY
    EXEC [monitor].[USP_CurrentIO]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"databaseStatus":"#FrameworkOutputRuntimeContract_TargetB","ioFiles":"#FrameworkOutputRuntimeContract_TargetB"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'DUPLICATE_TARGET',N'Ein doppelt verwendetes TABLE-Ziel wurde nicht abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'DUPLICATE_TARGET',CONCAT(N'Erwartet Fehler 51011, erhalten ',ERROR_NUMBER(),N'.'));
END CATCH;

BEGIN TRY
    EXEC [monitor].[USP_CheckAnalyseAccess]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"unknownResult":"#FrameworkOutputRuntimeContract_TargetB"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'UNKNOWN_RESULT_NAME',N'Ein unbekannter Resultsetname wurde nicht abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'UNKNOWN_RESULT_NAME',CONCAT(N'Erwartet Fehler 51011, erhalten ',ERROR_NUMBER(),N'.'));
END CATCH;

BEGIN TRY
    EXEC [monitor].[USP_CheckAnalyseAccess]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"access":"#FrameworkOutputRuntimeContract_Missing"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'MISSING_TARGET',N'Eine nicht vorhandene lokale Ziel-Temp-Tabelle wurde nicht abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'MISSING_TARGET',CONCAT(N'Erwartet Fehler 51011, erhalten ',ERROR_NUMBER(),N'.'));
END CATCH;

INSERT [#FrameworkOutputRuntimeContract_TargetA] VALUES(1);
BEGIN TRY
    EXEC [monitor].[USP_CheckAnalyseAccess]
          @ResultSetArt='TABLE'
        , @ResultTablesJson=N'{"access":"#FrameworkOutputRuntimeContract_TargetA"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'NONEMPTY_TARGET',N'Ein gefülltes TABLE-Ziel wurde nicht im Preflight abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'NONEMPTY_TARGET',CONCAT(N'Erwartet Fehler 51011, erhalten ',ERROR_NUMBER(),N'.'));
END CATCH;

BEGIN TRY
    EXEC [monitor].[USP_CheckAnalyseAccess]
          @ResultSetArt='NONE'
        , @ResultTablesJson=N'{"access":"#FrameworkOutputRuntimeContract_TargetB"}'
        , @PrintMeldungen=0;
    INSERT [#FrameworkOutputRuntimeContract_Failure]
    VALUES(N'MAPPING_WITHOUT_TABLE',N'Eine TABLE-Zuordnung außerhalb des TABLE-Modus wurde nicht abgelehnt.');
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>51011
        INSERT [#FrameworkOutputRuntimeContract_Failure]
        VALUES(N'MAPPING_WITHOUT_TABLE',CONCAT(N'Erwartet Fehler 51011, erhalten ',ERROR_NUMBER(),N'.'));
END CATCH;

SELECT [TestName],[Detail]
FROM [#FrameworkOutputRuntimeContract_Failure]
ORDER BY [TestName],[Detail];

IF EXISTS(SELECT 1 FROM [#FrameworkOutputRuntimeContract_Failure])
    THROW 54720,N'Der frameworkweite Ausgabe-Laufzeitvertrag ist verletzt.',1;
GO
