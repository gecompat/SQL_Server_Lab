USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt/Datei : 000_Preflight_und_Schema.sql
Version      : 2.1.0
Zweck        : Prüft die SQL-Server-Baseline und die Collation der aktuell mit
               USE ausgewählten Installationsdatenbank. Legt das Schema monitor
               idempotent an. Der Platzhalter DeineDatenbank ist vor Ausführung
               durch den tatsächlichen Datenbanknamen zu ersetzen.
Voraussetzung: SQL Server 2019 oder höher; notwendige DDL-Rechte.
Seiteneffekte: Legt ausschließlich das Schema monitor an, sofern es fehlt.
Collation    : Das Framework verwendet durchgängig explizite COLLATE-Klauseln
               und funktioniert auf beliebigen Collations. Getestet und
               garantiert wird ausschließlich SQL_Latin1_General_CP1_CS_AS.
               Bei abweichender Collation wird eine Warnung ausgegeben;
               die Installation wird nicht blockiert.
Änderungen   : 2.1.0 - Collation-Prüfung von Abbruch auf Warnung geändert;
                         das Framework arbeitet collation-agnostisch durch
                         explizite COLLATE-Klauseln in allen Vergleichen.
               2.0.0 - Erstfassung mit harter Collation-Prüfung.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ProductMajorVersion int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
IF @ProductMajorVersion IS NULL OR @ProductMajorVersion < 15
    THROW 50001, N'Das Analyseframework unterstützt mindestens SQL Server 2019 (Major Version 15).', 1;

DECLARE @ExpectedCollation sysname = N'SQL_Latin1_General_CP1_CS_AS';
DECLARE @ServerCollation sysname = CONVERT(sysname, SERVERPROPERTY(N'Collation'));
DECLARE @TempDbCollation sysname = (SELECT [collation_name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [name]=N'tempdb');
DECLARE @TargetDatabaseCollation sysname = (SELECT [collation_name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id]=DB_ID());
DECLARE @CollationWarningIssued bit = 0;

IF @ServerCollation COLLATE Latin1_General_100_BIN2 <> @ExpectedCollation COLLATE Latin1_General_100_BIN2
BEGIN
    RAISERROR(N'[monitor] WARNUNG: Server-Collation ist %s (erwartet: SQL_Latin1_General_CP1_CS_AS). Das Framework verwendet explizite COLLATE-Klauseln und arbeitet grundsätzlich collation-agnostisch. Getestet ist ausschließlich SQL_Latin1_General_CP1_CS_AS; abweichendes Verhalten bei Filterlisten und Objektnamenvergleichen ist möglich.', 10, 1, @ServerCollation) WITH NOWAIT;
    SET @CollationWarningIssued = 1;
END;
IF @TempDbCollation COLLATE Latin1_General_100_BIN2 <> @ExpectedCollation COLLATE Latin1_General_100_BIN2
BEGIN
    RAISERROR(N'[monitor] WARNUNG: tempdb-Collation ist %s (erwartet: SQL_Latin1_General_CP1_CS_AS). Temporäre Tabellen verwenden explizite COLLATE-Klauseln; Konflikte sind nicht zu erwarten.', 10, 1, @TempDbCollation) WITH NOWAIT;
    SET @CollationWarningIssued = 1;
END;
IF @TargetDatabaseCollation COLLATE Latin1_General_100_BIN2 <> @ExpectedCollation COLLATE Latin1_General_100_BIN2
BEGIN
    DECLARE @TargetDbName sysname = (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());
    RAISERROR(N'[monitor] WARNUNG: Installationsdatenbank %s hat Collation %s (erwartet: SQL_Latin1_General_CP1_CS_AS). Das Framework funktioniert, jedoch ohne Garantie für ungetestete Collations.', 10, 1, @TargetDbName, @TargetDatabaseCollation) WITH NOWAIT;
    SET @CollationWarningIssued = 1;
END;
IF @CollationWarningIssued = 1
    RAISERROR(N'[monitor] HINWEIS: Die Installation wird fortgesetzt. Das Framework verwendet durchgängig explizite COLLATE SQL_Latin1_General_CP1_CS_AS in Vergleichen, Temp-Tabellen und Rückgabewerten. Bei Problemen prüfen Sie bitte zuerst Filterlisten mit bracket-quotierten Objektnamen.', 10, 1) WITH NOWAIT;
GO

IF NOT EXISTS (SELECT 1 FROM [sys].[schemas] AS [s] WITH (NOLOCK) WHERE [s].[name] = N'monitor')
BEGIN
    EXEC [sys].[sp_executesql] N'CREATE SCHEMA [monitor] AUTHORIZATION [dbo];';
END;
GO
