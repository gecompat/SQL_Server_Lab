USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalPrepareResultTables
Version      : 1.0.0
Stand        : 2026-07-20
Typ          : Interne Stored Procedure
Zweck        : Validiert eine benannte TABLE-Mehrfachzuordnung vollständig vor
               dem ersten fachlichen Systemzugriff und befüllt eine lokale
               Mapping-Temp-Tabelle des Aufrufers.
Sicherheit   : Nur vorhandene, leere lokale #Temp-Tabellen mit genau einer
               Seed-Spalte. Doppelte Ziele und unbekannte Resultsetnamen werden
               atomar abgelehnt. Keine fachlichen Datenquellen werden gelesen.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[InternalPrepareResultTables]
      @ResultTablesJson    nvarchar(max)
    , @AllowedResultNames  nvarchar(max)
    , @MappingTable        sysname
    , @StatusCode          varchar(40)    = NULL OUTPUT
    , @ErrorMessage        nvarchar(2048) = NULL OUTPUT
    , @ThrowOnError        bit            = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Lokale Metadatenobjekte werden vor dem bewussten No-Wait-Vertrag
    -- angelegt, damit eine kurzzeitige tempdb-DDL-Kollision nicht schon den
    -- rein internen Arbeitsbereich mit Fehler 1222 abbrechen lässt.
    CREATE TABLE [#InternalPrepareResultTables_Allowed]
    (
        [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL PRIMARY KEY
    );

    CREATE TABLE [#InternalPrepareResultTables_Parsed]
    (
          [ResultName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [TargetTable] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [JsonType] int NOT NULL
    );

    SET LOCK_TIMEOUT 0;

    SELECT
          @StatusCode = 'AVAILABLE'
        , @ErrorMessage = NULL;

    IF @ThrowOnError IS NULL OR @ThrowOnError NOT IN (0,1)
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@ThrowOnError muss 0 oder 1 enthalten.';
        GOTO PreflightFailed;
    END;

    IF @MappingTable IS NULL
       OR LEFT(@MappingTable,1) <> N'#'
       OR LEFT(@MappingTable,2) = N'##'
       OR LEN(@MappingTable) > 116
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@MappingTable muss eine gültige lokale #Temp-Tabelle bezeichnen.';
        GOTO PreflightFailed;
    END;

    IF @ResultTablesJson IS NULL
       OR ISJSON(@ResultTablesJson) <> 1
       OR LEFT(LTRIM(@ResultTablesJson),1) <> N'{'
       OR RIGHT(RTRIM(@ResultTablesJson),1) <> N'}'
    BEGIN
        SET @StatusCode = 'INVALID_RESULT_TABLE_MAPPING';
        SET @ErrorMessage = N'@ResultTablesJson muss ein gültiges JSON-Objekt enthalten.';
        GOTO PreflightFailed;
    END;

    INSERT [#InternalPrepareResultTables_Allowed]([ResultName])
    SELECT CONVERT(sysname, LTRIM(RTRIM([value])))
    FROM STRING_SPLIT(COALESCE(@AllowedResultNames,N''),N'|')
    WHERE NULLIF(LTRIM(RTRIM([value])),N'') IS NOT NULL;

    BEGIN TRY
        INSERT [#InternalPrepareResultTables_Parsed]([ResultName],[TargetTable],[JsonType])
        SELECT
              CONVERT(sysname,[key])
            , CONVERT(sysname,[value])
            , [type]
        FROM OPENJSON(@ResultTablesJson);
    END TRY
    BEGIN CATCH
        SET @StatusCode = 'INVALID_RESULT_TABLE_MAPPING';
        SET @ErrorMessage = N'@ResultTablesJson enthält einen nicht unterstützten Namen oder Zielwert.';
        GOTO PreflightFailed;
    END CATCH;

    IF NOT EXISTS (SELECT 1 FROM [#InternalPrepareResultTables_Parsed])
       OR EXISTS
          (
              SELECT 1
              FROM [#InternalPrepareResultTables_Parsed]
              WHERE [JsonType] <> 1
                 OR NULLIF(LTRIM(RTRIM([ResultName])),N'') IS NULL
                 OR NULLIF(LTRIM(RTRIM([TargetTable])),N'') IS NULL
          )
       OR EXISTS
          (
              SELECT 1
              FROM [#InternalPrepareResultTables_Parsed]
              GROUP BY [ResultName] COLLATE SQL_Latin1_General_CP1_CS_AS
              HAVING COUNT(*) > 1
          )
       OR EXISTS
          (
              SELECT 1
              FROM [#InternalPrepareResultTables_Parsed]
              GROUP BY [TargetTable] COLLATE Latin1_General_100_CI_AS
              HAVING COUNT(*) > 1
          )
       OR EXISTS
          (
              SELECT 1
              FROM [#InternalPrepareResultTables_Parsed] AS [p]
              WHERE NOT EXISTS
                    (
                        SELECT 1
                        FROM [#InternalPrepareResultTables_Allowed] AS [a]
                        WHERE [a].[ResultName] = [p].[ResultName]
                              COLLATE SQL_Latin1_General_CP1_CS_AS
                    )
          )
       OR EXISTS
          (
              SELECT 1
              FROM [#InternalPrepareResultTables_Parsed]
              WHERE LEFT([TargetTable],1) <> N'#'
                 OR LEFT([TargetTable],2) = N'##'
                 OR LEN([TargetTable]) > 116
                 OR [TargetTable] LIKE N'#Monitor%' COLLATE Latin1_General_100_CI_AS
          )
    BEGIN
        SET @StatusCode = 'INVALID_RESULT_TABLE_MAPPING';
        SET @ErrorMessage = N'Die TABLE-Zuordnung enthält unbekannte oder doppelte Resultsetnamen, doppelte Ziele oder unzulässige Temp-Tabellennamen.';
        GOTO PreflightFailed;
    END;

    DECLARE @MappingTableQuoted nvarchar(258) = QUOTENAME(@MappingTable);
    DECLARE @Sql nvarchar(max);

    BEGIN TRY
        SET @Sql = N'DECLARE @ResultName sysname,@TargetTable sysname;
SELECT TOP (0) @ResultName=[ResultName],@TargetTable=[TargetTable]
FROM ' + @MappingTableQuoted + N';';
        EXEC [sys].[sp_executesql] @Sql;
    END TRY
    BEGIN CATCH
        SET @StatusCode = 'INTERNAL_ERROR';
        SET @ErrorMessage = N'Die Mapping-Temp-Tabelle wurde nicht mit dem erwarteten Schema angelegt.';
        GOTO PreflightFailed;
    END CATCH;

    DECLARE @TargetTable sysname;
    DECLARE @TargetTableQuoted nvarchar(258);
    DECLARE @HasRows bit;
    DECLARE @Marker sysname;
    DECLARE @MarkerAdded bit;
    DECLARE @ColumnCount int;

    DECLARE [TargetCursor] CURSOR LOCAL FAST_FORWARD FOR
        SELECT [TargetTable]
        FROM [#InternalPrepareResultTables_Parsed]
        ORDER BY [ResultName];

    OPEN [TargetCursor];
    FETCH NEXT FROM [TargetCursor] INTO @TargetTable;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
              @TargetTableQuoted = QUOTENAME(@TargetTable)
            , @HasRows = NULL
            , @Marker = N'__MonitorPreflight_' + REPLACE(CONVERT(nvarchar(36),NEWID()),N'-',N'')
            , @MarkerAdded = 0
            , @ColumnCount = NULL;

        BEGIN TRY
            SET @Sql = N'SELECT @HasRows = CONVERT(bit,CASE WHEN EXISTS(SELECT 1 FROM '
                     + @TargetTableQuoted + N') THEN 1 ELSE 0 END);';
            EXEC [sys].[sp_executesql] @Sql,N'@HasRows bit OUTPUT',@HasRows=@HasRows OUTPUT;

            IF @HasRows = 1
            BEGIN
                SET @StatusCode = 'INVALID_RESULT_TABLE_TARGET';
                SET @ErrorMessage = N'Alle TABLE-Ziele müssen vor dem Aufruf leer sein.';
                CLOSE [TargetCursor];
                DEALLOCATE [TargetCursor];
                GOTO PreflightFailed;
            END;

            SET @Sql = N'ALTER TABLE ' + @TargetTableQuoted
                     + N' ADD ' + QUOTENAME(@Marker) + N' bit NULL;';
            EXEC [sys].[sp_executesql] @Sql;
            SET @MarkerAdded = 1;

            SELECT @ColumnCount = COUNT(*)
            FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
            INNER JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
              ON [t].[object_id] = [c].[object_id]
            WHERE EXISTS
                  (
                      SELECT 1
                      FROM [tempdb].[sys].[columns] AS [m] WITH (NOLOCK)
                      WHERE [m].[object_id] = [t].[object_id]
                        AND [m].[name] = @Marker
                  );

            SET @Sql = N'ALTER TABLE ' + @TargetTableQuoted
                     + N' DROP COLUMN ' + QUOTENAME(@Marker) + N';';
            EXEC [sys].[sp_executesql] @Sql;
            SET @MarkerAdded = 0;

            IF @ColumnCount <> 2
            BEGIN
                SET @StatusCode = 'INVALID_RESULT_TABLE_TARGET';
                SET @ErrorMessage = N'Jedes neue TABLE-Ziel muss genau eine Seed-Spalte besitzen.';
                CLOSE [TargetCursor];
                DEALLOCATE [TargetCursor];
                GOTO PreflightFailed;
            END;
        END TRY
        BEGIN CATCH
            IF @MarkerAdded = 1
            BEGIN TRY
                SET @Sql = N'ALTER TABLE ' + @TargetTableQuoted
                         + N' DROP COLUMN ' + QUOTENAME(@Marker) + N';';
                EXEC [sys].[sp_executesql] @Sql;
            END TRY
            BEGIN CATCH
            END CATCH;

            SET @StatusCode = 'INVALID_RESULT_TABLE_TARGET';
            SET @ErrorMessage = N'Mindestens eine angeforderte lokale Ziel-Temp-Tabelle ist nicht vorhanden oder nicht sicher validierbar.';
            CLOSE [TargetCursor];
            DEALLOCATE [TargetCursor];
            GOTO PreflightFailed;
        END CATCH;

        FETCH NEXT FROM [TargetCursor] INTO @TargetTable;
    END;
    CLOSE [TargetCursor];
    DEALLOCATE [TargetCursor];

    SET @Sql = N'INSERT ' + @MappingTableQuoted + N'([ResultName],[TargetTable])
SELECT [ResultName],[TargetTable]
FROM [#InternalPrepareResultTables_Parsed];';
    EXEC [sys].[sp_executesql] @Sql;
    RETURN;

PreflightFailed:
    IF @ThrowOnError = 1
        THROW 51011, @ErrorMessage, 1;
END;
GO
