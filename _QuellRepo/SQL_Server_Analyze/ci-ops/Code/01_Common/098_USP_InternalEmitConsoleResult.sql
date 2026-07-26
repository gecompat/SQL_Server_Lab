USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalEmitConsoleResult
Version      : 1.0.0
Stand        : 2026-07-20
Typ          : Interne Stored Procedure
Zweck        : Rendert genau ein menschenlesbares CONSOLE-Resultset aus einer
               bereits im Aufrufer materialisierten lokalen Temp-Tabelle.
Vertrag      : Keine fachlichen Systemzugriffe. Nicht leere Quellen liefern
               eine beschriftete Fachansicht. Leere Quellen liefern genau eine
               verständliche Console-Zeile; RAW und TABLE verwenden den Helper
               nicht und erhalten deshalb keine künstlichen Datenzeilen.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalEmitConsoleResult]
      @SourceTable    sysname
    , @ResultLabel    nvarchar(200)
    , @EmptyMessage   nvarchar(200)
    , @StatusCode     varchar(40)    = NULL
    , @StatusMessage  nvarchar(2048) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    IF @SourceTable IS NULL
       OR LEFT(@SourceTable,1)<>N'#'
       OR LEFT(@SourceTable,2)=N'##'
       OR LEN(@SourceTable)>116
        THROW 51012,N'@SourceTable muss eine lokale #Temp-Tabelle des Aufrufers bezeichnen.',1;

    SET @ResultLabel=COALESCE(NULLIF(LTRIM(RTRIM(@ResultLabel)),N''),N'Ergebnis');
    SET @EmptyMessage=COALESCE(NULLIF(LTRIM(RTRIM(@EmptyMessage)),N''),N'Keine Ergebnisse');

    DECLARE @Sql nvarchar(max)=
          N'IF EXISTS (SELECT 1 FROM '+QUOTENAME(@SourceTable)+N')'
        + N' SELECT @Label AS [Ergebnis],[src].* FROM '+QUOTENAME(@SourceTable)+N' AS [src];'
        + N' ELSE SELECT @Empty AS [Ergebnis],@Status AS [Status],@Message AS [Hinweis];';

    EXEC [sys].[sp_executesql]
          @Sql
        , N'@Label nvarchar(200),@Empty nvarchar(200),@Status varchar(40),@Message nvarchar(2048)'
        , @Label=@ResultLabel
        , @Empty=@EmptyMessage
        , @Status=@StatusCode
        , @Message=@StatusMessage;
END;
GO
