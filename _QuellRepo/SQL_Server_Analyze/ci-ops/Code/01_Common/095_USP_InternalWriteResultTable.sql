USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.InternalWriteResultTable
Version      : 1.1.0
Stand        : 2026-07-19
Typ          : Interne Stored Procedure
Zweck        : Kopiert genau ein bereits materialisiertes Analyseergebnis in
               eine lokale Temp-Tabelle des Aufrufers. Eine leere Tabelle mit
               genau einer beliebigen Dummy-Spalte wird sicher an die native
               Quellstruktur angepasst; eine bereits passende Struktur wird
               zum Anhängen verwendet.
Sicherheit   : Ausschließlich lokale #Temp-Tabellen. Globale ##Temp-Tabellen
               und permanente Tabellen sind bewusst nicht zugelassen.
Locking      : Katalogauflösung ausschließlich über tempdb.sys.* WITH (NOLOCK)
               und LOCK_TIMEOUT 0; keine blockierenden Metadatenfunktionen.
===============================================================================
*/
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [monitor].[InternalWriteResultTable]
      @SourceTable  sysname
    , @TargetTable  sysname
    , @InsertedRows bigint         = NULL OUTPUT
    , @StatusCode   varchar(40)    = NULL OUTPUT
    , @ErrorNumber  int            = NULL OUTPUT
    , @ErrorMessage nvarchar(2048) = NULL OUTPUT
    , @ThrowOnError bit            = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Diese lokalen Tabellen entstehen vor LOCK_TIMEOUT 0. Der No-Wait-
    -- Vertrag gilt für die fremden Quell-/Ziel-Temp-Tabellen, nicht für die
    -- eigene tempdb-Metadatenanlage des Writers.
    CREATE TABLE [#InternalWriteResultTable_SourceSchema]
    (
          [ColumnId] int NOT NULL
        , [ColumnName] sysname NOT NULL
        , [TypeName] sysname NOT NULL
        , [SystemTypeId] tinyint NOT NULL
        , [MaxLength] smallint NOT NULL
        , [Precision] tinyint NOT NULL
        , [Scale] tinyint NOT NULL
        , [CollationName] sysname NULL
        , [IsNullable] bit NOT NULL
        , [IsIdentity] bit NOT NULL
        , [IsComputed] bit NOT NULL
        , [IsUserDefined] bit NOT NULL
        , [IsAssemblyType] bit NOT NULL
        , [XmlCollectionId] int NOT NULL
    );

    CREATE TABLE [#InternalWriteResultTable_TargetSchema]
    (
          [ColumnId] int NOT NULL
        , [ColumnName] sysname NOT NULL
        , [TypeName] sysname NOT NULL
        , [SystemTypeId] tinyint NOT NULL
        , [MaxLength] smallint NOT NULL
        , [Precision] tinyint NOT NULL
        , [Scale] tinyint NOT NULL
        , [CollationName] sysname NULL
        , [IsNullable] bit NOT NULL
        , [IsIdentity] bit NOT NULL
        , [IsComputed] bit NOT NULL
        , [IsUserDefined] bit NOT NULL
        , [IsAssemblyType] bit NOT NULL
        , [XmlCollectionId] int NOT NULL
    );

    SET LOCK_TIMEOUT 0;

    DECLARE @TableThrowMessage nvarchar(2048);

    SELECT
          @InsertedRows = 0
        , @StatusCode = 'AVAILABLE'
        , @ErrorNumber = NULL
        , @ErrorMessage = NULL;

    IF @ThrowOnError IS NULL OR @ThrowOnError NOT IN (0,1)
    BEGIN
        SELECT
              @StatusCode = 'INVALID_PARAMETER'
            , @ErrorMessage = N'@ThrowOnError muss 0 oder 1 enthalten.';
        GOTO TableWriteFailed;
    END;

    IF @SourceTable IS NULL
       OR LEFT(@SourceTable, 1) <> N'#'
       OR LEFT(@SourceTable, 2) = N'##'
       OR @TargetTable IS NULL
       OR LEFT(@TargetTable, 1) <> N'#'
       OR LEFT(@TargetTable, 2) = N'##'
       OR LEN(@SourceTable) > 116
       OR LEN(@TargetTable) > 116
       OR @TargetTable LIKE N'#Monitor%' COLLATE Latin1_General_100_CI_AS
    BEGIN
        SELECT
              @StatusCode = 'INVALID_PARAMETER'
            , @ErrorMessage = N'@SourceTable und @TargetTable müssen lokale #Temp-Tabellen bezeichnen; ##Temp-, permanente Tabellen und das reservierte Präfix #Monitor sind nicht zulässig.';
        GOTO TableWriteFailed;
    END;

    IF @SourceTable = @TargetTable COLLATE Latin1_General_100_CI_AS
    BEGIN
        SELECT
              @StatusCode = 'INVALID_PARAMETER'
            , @ErrorMessage = N'Quell- und Zieltabelle dürfen nicht identisch sein.';
        GOTO TableWriteFailed;
    END;

    DECLARE @SourceObjectId int = NULL;
    DECLARE @TargetObjectId int = NULL;
    DECLARE @SourceMarker sysname = N'__MonitorResolveSource_' + REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N'');
    DECLARE @TargetMarker sysname = N'__MonitorResolveTarget_' + REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N'');
    DECLARE @ResolveSql nvarchar(max);

    BEGIN TRY
        SET @ResolveSql = N'ALTER TABLE ' + QUOTENAME(@SourceTable)
                        + N' ADD ' + QUOTENAME(@SourceMarker) + N' bit NULL;';
        EXEC [sys].[sp_executesql] @ResolveSql;
    END TRY
    BEGIN CATCH
        SELECT
              @StatusCode = CASE WHEN ERROR_NUMBER() = 1222 THEN 'LOCK_TIMEOUT' ELSE 'SOURCE_NOT_FOUND' END
            , @ErrorNumber = ERROR_NUMBER()
            , @ErrorMessage = N'Die interne Quelltabelle des ausgewählten Resultsets konnte nicht aufgelöst werden: ' + ERROR_MESSAGE();
        GOTO TableWriteFailed;
    END CATCH;

    SELECT @SourceObjectId = [c].[object_id]
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [c].[object_id]
    WHERE [c].[name] = @SourceMarker;

    BEGIN TRY
        SET @ResolveSql = N'ALTER TABLE ' + QUOTENAME(@SourceTable)
                        + N' DROP COLUMN ' + QUOTENAME(@SourceMarker) + N';';
        EXEC [sys].[sp_executesql] @ResolveSql;
    END TRY
    BEGIN CATCH
        SELECT
              @StatusCode = CASE WHEN ERROR_NUMBER() = 1222 THEN 'LOCK_TIMEOUT' ELSE 'TABLE_WRITE_ERROR' END
            , @ErrorNumber = ERROR_NUMBER()
            , @ErrorMessage = N'Die temporäre Quellmarkierung konnte nicht entfernt werden: ' + ERROR_MESSAGE();
        GOTO TableWriteFailed;
    END CATCH;

    IF @SourceObjectId IS NULL
    BEGIN
        SELECT
              @StatusCode = 'METADATA_NOT_VISIBLE'
            , @ErrorMessage = N'Die interne Quelltabelle ist vorhanden, ihre Katalogzeile war jedoch ohne Warten nicht sichtbar.';
        GOTO TableWriteFailed;
    END;

    BEGIN TRY
        SET @ResolveSql = N'ALTER TABLE ' + QUOTENAME(@TargetTable)
                        + N' ADD ' + QUOTENAME(@TargetMarker) + N' bit NULL;';
        EXEC [sys].[sp_executesql] @ResolveSql;
    END TRY
    BEGIN CATCH
        SELECT
              @StatusCode = CASE WHEN ERROR_NUMBER() = 1222 THEN 'LOCK_TIMEOUT' ELSE 'TARGET_NOT_FOUND' END
            , @ErrorNumber = ERROR_NUMBER()
            , @ErrorMessage = N'@TargetTable konnte nicht aufgelöst werden: ' + ERROR_MESSAGE();
        GOTO TableWriteFailed;
    END CATCH;

    SELECT @TargetObjectId = [c].[object_id]
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [c].[object_id]
    WHERE [c].[name] = @TargetMarker;

    BEGIN TRY
        SET @ResolveSql = N'ALTER TABLE ' + QUOTENAME(@TargetTable)
                        + N' DROP COLUMN ' + QUOTENAME(@TargetMarker) + N';';
        EXEC [sys].[sp_executesql] @ResolveSql;
    END TRY
    BEGIN CATCH
        SELECT
              @StatusCode = CASE WHEN ERROR_NUMBER() = 1222 THEN 'LOCK_TIMEOUT' ELSE 'TABLE_WRITE_ERROR' END
            , @ErrorNumber = ERROR_NUMBER()
            , @ErrorMessage = N'Die temporäre Zielmarkierung konnte nicht entfernt werden: ' + ERROR_MESSAGE();
        GOTO TableWriteFailed;
    END CATCH;

    IF @TargetObjectId IS NULL
    BEGIN
        SELECT
              @StatusCode = 'METADATA_NOT_VISIBLE'
            , @ErrorMessage = N'@TargetTable ist vorhanden, ihre Katalogzeile war jedoch ohne Warten nicht sichtbar.';
        GOTO TableWriteFailed;
    END;

    INSERT [#InternalWriteResultTable_SourceSchema]
    (
          [ColumnId], [ColumnName], [TypeName], [SystemTypeId], [MaxLength]
        , [Precision], [Scale], [CollationName], [IsNullable], [IsIdentity]
        , [IsComputed], [IsUserDefined], [IsAssemblyType], [XmlCollectionId]
    )
    SELECT
          CONVERT(int, ROW_NUMBER() OVER (ORDER BY [c].[column_id]))
        , [c].[name]
        , [t].[name]
        , [c].[system_type_id]
        , [c].[max_length]
        , [c].[precision]
        , [c].[scale]
        , [c].[collation_name]
        , [c].[is_nullable]
        , [c].[is_identity]
        , [c].[is_computed]
        , [t].[is_user_defined]
        , [t].[is_assembly_type]
        , [c].[xml_collection_id]
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[types] AS [t] WITH (NOLOCK)
      ON [t].[user_type_id] = [c].[user_type_id]
    WHERE [c].[object_id] = @SourceObjectId;

    IF NOT EXISTS (SELECT 1 FROM [#InternalWriteResultTable_SourceSchema])
    BEGIN
        SELECT
              @StatusCode = 'UNSUPPORTED_SOURCE_SCHEMA'
            , @ErrorMessage = N'Das ausgewählte Resultset besitzt keine exportierbaren Spalten.';
        GOTO TableWriteFailed;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM [#InternalWriteResultTable_SourceSchema]
        WHERE [IsComputed] = 1
           OR [IsUserDefined] = 1
           OR [IsAssemblyType] = 1
           OR [XmlCollectionId] <> 0
           OR [TypeName] IN (N'timestamp', N'rowversion')
    )
    BEGIN
        SELECT
              @StatusCode = 'UNSUPPORTED_SOURCE_SCHEMA'
            , @ErrorMessage = N'Das ausgewählte Resultset enthält einen nicht sicher reproduzierbaren Datentyp oder eine berechnete Spalte.';
        GOTO TableWriteFailed;
    END;

    INSERT [#InternalWriteResultTable_TargetSchema]
    (
          [ColumnId], [ColumnName], [TypeName], [SystemTypeId], [MaxLength]
        , [Precision], [Scale], [CollationName], [IsNullable], [IsIdentity]
        , [IsComputed], [IsUserDefined], [IsAssemblyType], [XmlCollectionId]
    )
    SELECT
          CONVERT(int, ROW_NUMBER() OVER (ORDER BY [c].[column_id]))
        , [c].[name]
        , [t].[name]
        , [c].[system_type_id]
        , [c].[max_length]
        , [c].[precision]
        , [c].[scale]
        , [c].[collation_name]
        , [c].[is_nullable]
        , [c].[is_identity]
        , [c].[is_computed]
        , [t].[is_user_defined]
        , [t].[is_assembly_type]
        , [c].[xml_collection_id]
    FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
    JOIN [tempdb].[sys].[types] AS [t] WITH (NOLOCK)
      ON [t].[user_type_id] = [c].[user_type_id]
    WHERE [c].[object_id] = @TargetObjectId;

    DECLARE @TargetColumnCount int;
    DECLARE @TargetHasRows bit = 0;
    DECLARE @DummyColumnName sysname;
    DECLARE @TargetNeedsAdaptation bit = 0;

    SELECT
          @TargetColumnCount = COUNT(*)
        , @DummyColumnName = MAX([ColumnName])
    FROM [#InternalWriteResultTable_TargetSchema];

    IF EXISTS
    (
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_SourceSchema]
        EXCEPT
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_TargetSchema]
    )
    OR EXISTS
    (
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_TargetSchema]
        EXCEPT
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_SourceSchema]
    )
    OR EXISTS
    (
        SELECT 1
        FROM [#InternalWriteResultTable_TargetSchema]
        WHERE [IsIdentity] = 1
           OR [IsComputed] = 1
           OR [IsUserDefined] = 1
           OR [IsAssemblyType] = 1
           OR [XmlCollectionId] <> 0
    )
        SET @TargetNeedsAdaptation = 1;

    IF @TargetNeedsAdaptation = 1
    BEGIN
        IF @TargetColumnCount <> 1
        BEGIN
            SELECT
                  @StatusCode = 'TARGET_SCHEMA_MISMATCH'
                , @ErrorMessage = N'Eine abweichende Zieltabelle wird nur dann automatisch angepasst, wenn sie leer ist und genau eine beliebige Dummy-Spalte besitzt.';
            GOTO TableWriteFailed;
        END;

        DECLARE @HasRowsSql nvarchar(max) =
            N'SELECT @HasRows = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM '
            + QUOTENAME(@TargetTable)
            + N') THEN 1 ELSE 0 END);';

        BEGIN TRY
            EXEC [sys].[sp_executesql]
                  @HasRowsSql
                , N'@HasRows bit OUTPUT'
                , @HasRows = @TargetHasRows OUTPUT;
        END TRY
        BEGIN CATCH
            SELECT
                  @StatusCode = CASE WHEN ERROR_NUMBER() = 1222 THEN 'LOCK_TIMEOUT' ELSE 'TABLE_WRITE_ERROR' END
                , @ErrorNumber = ERROR_NUMBER()
                , @ErrorMessage = ERROR_MESSAGE();
            GOTO TableWriteFailed;
        END CATCH;

        IF @TargetHasRows = 1
        BEGIN
            SELECT
                  @StatusCode = 'TARGET_SCHEMA_MISMATCH'
                , @ErrorMessage = N'Die Zieltabelle muss leer sein, bevor ihre einzelne Dummy-Spalte ersetzt werden kann.';
            GOTO TableWriteFailed;
        END;

        DECLARE @ColumnDefinitions nvarchar(max);

        SELECT @ColumnDefinitions = STUFF
        (
            (
                SELECT
                      N', '
                    + QUOTENAME([s].[ColumnName])
                    + N' '
                    + CASE
                          WHEN [s].[TypeName] IN (N'varchar', N'char', N'varbinary', N'binary')
                              THEN QUOTENAME([s].[TypeName]) + N'(' + CASE WHEN [s].[MaxLength] = -1 THEN N'MAX' ELSE CONVERT(nvarchar(10), [s].[MaxLength]) END + N')'
                          WHEN [s].[TypeName] IN (N'nvarchar', N'nchar')
                              THEN QUOTENAME([s].[TypeName]) + N'(' + CASE WHEN [s].[MaxLength] = -1 THEN N'MAX' ELSE CONVERT(nvarchar(10), [s].[MaxLength] / 2) END + N')'
                          WHEN [s].[TypeName] IN (N'decimal', N'numeric')
                              THEN QUOTENAME([s].[TypeName]) + N'(' + CONVERT(nvarchar(10), [s].[Precision]) + N',' + CONVERT(nvarchar(10), [s].[Scale]) + N')'
                          WHEN [s].[TypeName] IN (N'datetime2', N'datetimeoffset', N'time')
                              THEN QUOTENAME([s].[TypeName]) + N'(' + CONVERT(nvarchar(10), [s].[Scale]) + N')'
                          WHEN [s].[TypeName] = N'float'
                              THEN QUOTENAME([s].[TypeName]) + N'(' + CONVERT(nvarchar(10), [s].[Precision]) + N')'
                          ELSE QUOTENAME([s].[TypeName])
                      END
                    + CASE WHEN [s].[CollationName] IS NULL THEN N'' ELSE N' COLLATE ' + [s].[CollationName] END
                    + CASE WHEN [s].[IsNullable] = 1 THEN N' NULL' ELSE N' NOT NULL' END
                FROM [#InternalWriteResultTable_SourceSchema] AS [s]
                ORDER BY [s].[ColumnId]
                FOR XML PATH(N''), TYPE
            ).value(N'.', N'nvarchar(max)')
            , 1
            , 2
            , N''
        );

        DECLARE @BridgeColumnName sysname = N'__MonitorBridge_' + REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N'');
        WHILE EXISTS (SELECT 1 FROM [#InternalWriteResultTable_SourceSchema] WHERE [ColumnName] = @BridgeColumnName)
           OR EXISTS (SELECT 1 FROM [#InternalWriteResultTable_TargetSchema] WHERE [ColumnName] = @BridgeColumnName)
            SET @BridgeColumnName = N'__MonitorBridge_' + REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N'');

        BEGIN TRY
            DECLARE @AlterSql nvarchar(max) =
                  N'ALTER TABLE ' + QUOTENAME(@TargetTable) + N' ADD ' + QUOTENAME(@BridgeColumnName) + N' bit NULL;'
                + N' ALTER TABLE ' + QUOTENAME(@TargetTable) + N' DROP COLUMN ' + QUOTENAME(@DummyColumnName) + N';'
                + N' ALTER TABLE ' + QUOTENAME(@TargetTable) + N' ADD ' + @ColumnDefinitions + N';'
                + N' ALTER TABLE ' + QUOTENAME(@TargetTable) + N' DROP COLUMN ' + QUOTENAME(@BridgeColumnName) + N';';

            EXEC [sys].[sp_executesql] @AlterSql;
        END TRY
        BEGIN CATCH
            SELECT
                  @StatusCode = CASE WHEN ERROR_NUMBER() = 1222 THEN 'LOCK_TIMEOUT' ELSE 'TABLE_WRITE_ERROR' END
                , @ErrorNumber = ERROR_NUMBER()
                , @ErrorMessage = ERROR_MESSAGE();
            GOTO TableWriteFailed;
        END CATCH;

        DELETE FROM [#InternalWriteResultTable_TargetSchema];

        INSERT [#InternalWriteResultTable_TargetSchema]
        (
              [ColumnId], [ColumnName], [TypeName], [SystemTypeId], [MaxLength]
            , [Precision], [Scale], [CollationName], [IsNullable], [IsIdentity]
            , [IsComputed], [IsUserDefined], [IsAssemblyType], [XmlCollectionId]
        )
        SELECT
              CONVERT(int, ROW_NUMBER() OVER (ORDER BY [c].[column_id]))
            , [c].[name]
            , [t].[name]
            , [c].[system_type_id]
            , [c].[max_length]
            , [c].[precision]
            , [c].[scale]
            , [c].[collation_name]
            , [c].[is_nullable]
            , [c].[is_identity]
            , [c].[is_computed]
            , [t].[is_user_defined]
            , [t].[is_assembly_type]
            , [c].[xml_collection_id]
        FROM [tempdb].[sys].[columns] AS [c] WITH (NOLOCK)
        JOIN [tempdb].[sys].[types] AS [t] WITH (NOLOCK)
          ON [t].[user_type_id] = [c].[user_type_id]
        WHERE [c].[object_id] = @TargetObjectId;
    END;

    IF EXISTS
    (
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_SourceSchema]
        EXCEPT
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_TargetSchema]
    )
    OR EXISTS
    (
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_TargetSchema]
        EXCEPT
        SELECT
              [ColumnId], [ColumnName], [SystemTypeId], [MaxLength], [Precision]
            , [Scale], [CollationName], [IsNullable]
        FROM [#InternalWriteResultTable_SourceSchema]
    )
    OR EXISTS
    (
        SELECT 1
        FROM [#InternalWriteResultTable_TargetSchema]
        WHERE [IsIdentity] = 1
           OR [IsComputed] = 1
           OR [IsUserDefined] = 1
           OR [IsAssemblyType] = 1
           OR [XmlCollectionId] <> 0
    )
    BEGIN
        SELECT
              @StatusCode = 'TARGET_SCHEMA_MISMATCH'
            , @ErrorMessage = N'Die vorhandene Struktur von @TargetTable stimmt nicht exakt mit dem ausgewählten Resultset überein.';
        GOTO TableWriteFailed;
    END;

    DECLARE @ColumnList nvarchar(max);

    SELECT @ColumnList = STUFF
    (
        (
            SELECT N', ' + QUOTENAME([s].[ColumnName])
            FROM [#InternalWriteResultTable_SourceSchema] AS [s]
            ORDER BY [s].[ColumnId]
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'nvarchar(max)')
        , 1
        , 2
        , N''
    );

    BEGIN TRY
        DECLARE @InsertSql nvarchar(max) =
              N'INSERT ' + QUOTENAME(@TargetTable) + N' (' + @ColumnList + N')'
            + N' SELECT ' + @ColumnList + N' FROM ' + QUOTENAME(@SourceTable) + N';'
            + N' SET @Rows = @@ROWCOUNT;';

        EXEC [sys].[sp_executesql]
              @InsertSql
            , N'@Rows bigint OUTPUT'
            , @Rows = @InsertedRows OUTPUT;
    END TRY
    BEGIN CATCH
        SELECT
              @StatusCode = 'TABLE_WRITE_ERROR'
            , @ErrorNumber = ERROR_NUMBER()
            , @ErrorMessage = ERROR_MESSAGE();
    END CATCH;

    IF @StatusCode <> 'AVAILABLE'
        GOTO TableWriteFailed;

    RETURN;

TableWriteFailed:
    IF @ThrowOnError = 1
    BEGIN
        SET @TableThrowMessage = CONCAT
        (
              N'TABLE-Ausgabe fehlgeschlagen ('
            , COALESCE(@StatusCode, N'UNKNOWN')
            , N'): '
            , COALESCE(@ErrorMessage, N'Unbekannter Fehler.')
        );
        THROW 51010, @TableThrowMessage, 1;
    END;
END;
GO
