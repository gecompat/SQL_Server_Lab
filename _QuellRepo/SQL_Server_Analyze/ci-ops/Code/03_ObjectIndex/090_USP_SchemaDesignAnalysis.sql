USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_SchemaDesignAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Zweck        : Findet belastbare Schema-/Designindikatoren je Datenbank.
Datenquellen : sys.foreign_keys, sys.foreign_key_columns,
               sys.check_constraints, sys.indexes, sys.index_columns,
               sys.identity_columns, sys.sequences, sys.objects und sys.schemas.
Prüfungen    : deaktivierte/nicht vertrauenswürdige Constraints,
               fehlender FK-Stützindex, hypothetische/deaktivierte und exakt
               gleiche Indizes sowie Identity-/Sequence-Wertebereich.
Grenzen      : Kein DDL und keine automatische Lösch-/Indexempfehlung. Nutzung,
               Workload, Filtersemantik und Änderungsrisiko separat prüfen.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_SchemaDesignAnalysis]
      @DatabaseNames                nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen bit            = 0
    , @DatabaseNamePattern          nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @IdentityWarnPercent          decimal(5,2)   = 80.00
    , @MaxZeilen                    int            = 1000
    , @ResultSetArt                 varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                 bit            = 0
    , @Json                         nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen               bit            = 1
    , @Hilfe                        bit            = 0
    , @StatusCodeOut                varchar(40)    = NULL OUTPUT
    , @IsPartialOut                 bit            = NULL OUTPUT
    , @ErrorNumberOut               int            = NULL OUTPUT
    , @ErrorMessageOut              nvarchar(2048) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'findings',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Limit bigint = CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
                                 THEN CONVERT(bigint, 9223372036854775807)
                                 ELSE CONVERT(bigint, @MaxZeilen) END;

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_SchemaDesignAnalysis';
        PRINT N'Die Procedure führt eine rein lesende Strukturprüfung durch und erzeugt oder ändert keine Constraints und Indizes.';
        PRINT N'@DatabaseNames: bracket-aware Pipe-Liste; N''''/NULL = keine Datenbankeinschränkung.';
        PRINT N'Ein gleicher Index oder fehlender FK-Stützindex ist ein Prüfauftrag, keine automatische DDL-Anweisung.';
        RETURN;
    END;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @CrossDatabaseRequested bit = 0;
    DECLARE @Db sysname;
    DECLARE @Sql nvarchar(max);

    CREATE TABLE [#SchemaDesignAnalysis_DatabaseCandidates]
    (
          [DatabaseId] int NOT NULL PRIMARY KEY
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
    CREATE TABLE [#SchemaDesignAnalysis_DatabaseCandidateWarnings]
    (
          [RequestedName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#SchemaDesignAnalysis_Findings]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname NOT NULL
        , [FindingCode] varchar(100) NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [ObjectType] nvarchar(60) NULL
        , [SchemaName] sysname NULL
        , [ObjectName] sysname NULL
        , [RelatedObjectName] sysname NULL
        , [MetricValue] decimal(38,4) NULL
        , [Evidence] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#SchemaDesignAnalysis_Errors]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @MaxZeilen < 0
       OR @IdentityWarnPercent < 0 OR @IdentityWarnPercent > 100
       OR @OutputMode NOT IN ('RAW', 'CONSOLE', 'NONE')
    BEGIN
        SELECT @StatusCode = 'INVALID_PARAMETER', @IsPartial = 1,
               @ErrorMessage = N'Ungültiger Datenbank-, Grenzwert-, Zeilen- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        EXEC [monitor].[USP_PrepareDatabaseCandidates]
              @DatabaseNames = @DatabaseNames
            , @SystemdatenbankenEinbeziehen = @SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern = @DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed

            , @AnalysisClass = 'CATALOG_DEEP'
            , @StatusCode = @StatusCode OUTPUT
            , @ErrorMessage = @ErrorMessage OUTPUT
            , @CrossDatabaseRequested = @CrossDatabaseRequested OUTPUT,@CandidateTable=N'#SchemaDesignAnalysis_DatabaseCandidates',@WarningTable=N'#SchemaDesignAnalysis_DatabaseCandidateWarnings';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN
        DECLARE [database_cursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [DatabaseName] FROM [#SchemaDesignAnalysis_DatabaseCandidates]
            ORDER BY COALESCE([RequestedOrdinal], [DatabaseId]), [DatabaseId];
        OPEN [database_cursor];
        FETCH NEXT FROM [database_cursor] INTO @Db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
DECLARE @DatabaseId int = DB_ID();
DECLARE @DatabaseName sysname = (SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID());

INSERT [#SchemaDesignAnalysis_Findings]
SELECT @DatabaseId, @DatabaseName,
       CASE WHEN [fk].[is_disabled] = 1 THEN ''FOREIGN_KEY_DISABLED'' ELSE ''FOREIGN_KEY_NOT_TRUSTED'' END,
       CASE WHEN [fk].[is_disabled] = 1 THEN ''HIGH'' ELSE ''MEDIUM'' END,
       N''FOREIGN_KEY'', [s].[name], [t].[name], [fk].[name], NULL,
       CONCAT(N''is_disabled='', [fk].[is_disabled], N''; is_not_trusted='', [fk].[is_not_trusted]),
       N''Aktivierung beziehungsweise WITH CHECK erfordert fachliche Prüfung und ist nicht Bestandteil dieser Analyse.''
FROM [sys].[foreign_keys] AS [fk] WITH (NOLOCK)
JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id] = [fk].[parent_object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id] = [t].[schema_id]
WHERE [fk].[is_disabled] = 1 OR [fk].[is_not_trusted] = 1;

INSERT [#SchemaDesignAnalysis_Findings]
SELECT @DatabaseId, @DatabaseName,
       CASE WHEN [cc].[is_disabled] = 1 THEN ''CHECK_CONSTRAINT_DISABLED'' ELSE ''CHECK_CONSTRAINT_NOT_TRUSTED'' END,
       CASE WHEN [cc].[is_disabled] = 1 THEN ''HIGH'' ELSE ''MEDIUM'' END,
       N''CHECK_CONSTRAINT'', [s].[name], [t].[name], [cc].[name], NULL,
       CONCAT(N''is_disabled='', [cc].[is_disabled], N''; is_not_trusted='', [cc].[is_not_trusted]),
       N''Constraintdefinition und Datenqualität vor einer Änderung separat validieren.''
FROM [sys].[check_constraints] AS [cc] WITH (NOLOCK)
JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id] = [cc].[parent_object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id] = [t].[schema_id]
WHERE [cc].[is_disabled] = 1 OR [cc].[is_not_trusted] = 1;

INSERT [#SchemaDesignAnalysis_Findings]
SELECT @DatabaseId, @DatabaseName, ''FOREIGN_KEY_WITHOUT_SUPPORTING_INDEX'', ''MEDIUM'',
       N''FOREIGN_KEY'', [s].[name], [t].[name], [fk].[name],
       CONVERT(decimal(38,4), COUNT_BIG([fkc].[constraint_column_id])),
       N''Kein aktiver Index beginnt in gleicher Reihenfolge mit allen referenzierenden FK-Spalten.'',
       N''Workload, Selektivität, Schreibkosten und ein eventuell breiterer geeigneter Index müssen separat geprüft werden.''
FROM [sys].[foreign_keys] AS [fk] WITH (NOLOCK)
JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id] = [fk].[parent_object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id] = [t].[schema_id]
JOIN [sys].[foreign_key_columns] AS [fkc] WITH (NOLOCK) ON [fkc].[constraint_object_id] = [fk].[object_id]
WHERE [fk].[is_disabled] = 0
  AND NOT EXISTS
  (
      SELECT 1
      FROM [sys].[indexes] AS [i] WITH (NOLOCK)
      WHERE [i].[object_id] = [fk].[parent_object_id]
        AND [i].[index_id] > 0 AND [i].[is_disabled] = 0 AND [i].[is_hypothetical] = 0
        AND [i].[has_filter] = 0
        AND NOT EXISTS
        (
            SELECT 1
            FROM [sys].[foreign_key_columns] AS [fc] WITH (NOLOCK)
            LEFT JOIN [sys].[index_columns] AS [ic] WITH (NOLOCK)
              ON [ic].[object_id] = [i].[object_id] AND [ic].[index_id] = [i].[index_id]
             AND [ic].[key_ordinal] = [fc].[constraint_column_id]
            WHERE [fc].[constraint_object_id] = [fk].[object_id]
              AND ([ic].[column_id] IS NULL OR [ic].[column_id] <> [fc].[parent_column_id])
        )
  )
GROUP BY [s].[name], [t].[name], [fk].[name];

INSERT [#SchemaDesignAnalysis_Findings]
SELECT @DatabaseId, @DatabaseName,
       CASE WHEN [i].[is_hypothetical] = 1 THEN ''HYPOTHETICAL_INDEX'' ELSE ''INDEX_DISABLED'' END,
       CASE WHEN [i].[is_hypothetical] = 1 THEN ''INFO'' ELSE ''MEDIUM'' END,
       N''INDEX'', [s].[name], [t].[name], [i].[name], NULL,
       CONCAT(N''index_id='', [i].[index_id]),
       N''Nicht automatisch löschen oder aktivieren; Ursprung, Abhängigkeiten und Wartungsabsicht prüfen.''
FROM [sys].[indexes] AS [i] WITH (NOLOCK)
JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id] = [i].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id] = [t].[schema_id]
WHERE [i].[index_id] > 0 AND ([i].[is_hypothetical] = 1 OR [i].[is_disabled] = 1);

INSERT [#SchemaDesignAnalysis_Findings]
SELECT @DatabaseId, @DatabaseName, ''EXACT_INDEX_DEFINITION_DUPLICATE'', ''MEDIUM'',
       N''INDEX'', [s].[name], [t].[name], CONCAT([i1].[name], N'' | '', [i2].[name]), NULL,
       N''Schlüssel-/Include-Spalten, Sortierung, Eindeutigkeit und Filterdefinition sind katalogseitig gleich.'',
       N''Nutzung, Abhängigkeiten, Constraints, Kompression und betriebliche Anforderungen vor einer Änderung prüfen.''
FROM [sys].[indexes] AS [i1] WITH (NOLOCK)
JOIN [sys].[indexes] AS [i2] WITH (NOLOCK)
  ON [i2].[object_id] = [i1].[object_id] AND [i2].[index_id] > [i1].[index_id]
JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id] = [i1].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id] = [t].[schema_id]
WHERE [i1].[index_id] > 0
  AND [i1].[type] IN (1, 2) AND [i2].[type] = [i1].[type]
  AND [i1].[is_hypothetical] = 0 AND [i2].[is_hypothetical] = 0
  AND [i1].[is_disabled] = 0 AND [i2].[is_disabled] = 0
  AND [i1].[is_unique] = [i2].[is_unique]
  AND COALESCE([i1].[filter_definition], N'''') = COALESCE([i2].[filter_definition], N'''')
  AND NOT EXISTS
  (
      SELECT [column_id], [key_ordinal], [is_descending_key], [is_included_column]
      FROM [sys].[index_columns] WITH (NOLOCK) WHERE [object_id] = [i1].[object_id] AND [index_id] = [i1].[index_id]
      EXCEPT
      SELECT [column_id], [key_ordinal], [is_descending_key], [is_included_column]
      FROM [sys].[index_columns] WITH (NOLOCK) WHERE [object_id] = [i2].[object_id] AND [index_id] = [i2].[index_id]
  )
  AND NOT EXISTS
  (
      SELECT [column_id], [key_ordinal], [is_descending_key], [is_included_column]
      FROM [sys].[index_columns] WITH (NOLOCK) WHERE [object_id] = [i2].[object_id] AND [index_id] = [i2].[index_id]
      EXCEPT
      SELECT [column_id], [key_ordinal], [is_descending_key], [is_included_column]
      FROM [sys].[index_columns] WITH (NOLOCK) WHERE [object_id] = [i1].[object_id] AND [index_id] = [i1].[index_id]
  );

;WITH [IdentityRange] AS
(
    SELECT [ic].[object_id], [ic].[name], [ic].[system_type_id],
           TRY_CONVERT(decimal(38,0), [ic].[last_value]) AS [CurrentValue],
           TRY_CONVERT(decimal(38,0), [ic].[increment_value]) AS [IncrementValue],
           CONVERT(decimal(38,0), CASE [ic].[system_type_id]
                    WHEN 48 THEN 0 WHEN 52 THEN -32768 WHEN 56 THEN -2147483648
                    WHEN 127 THEN -9223372036854775808 END) AS [TypeMin],
           CONVERT(decimal(38,0), CASE [ic].[system_type_id]
                    WHEN 48 THEN 255 WHEN 52 THEN 32767 WHEN 56 THEN 2147483647
                    WHEN 127 THEN 9223372036854775807 END) AS [TypeMax]
    FROM [sys].[identity_columns] AS [ic] WITH (NOLOCK)
    WHERE [ic].[system_type_id] IN (48, 52, 56, 127) AND [ic].[last_value] IS NOT NULL
),
[IdentityUsage] AS
(
    SELECT [r].*, CONVERT(decimal(38,4),
           CASE WHEN [r].[IncrementValue] >= 0
                THEN 100.0 * ([r].[CurrentValue] - [r].[TypeMin]) / NULLIF([r].[TypeMax] - [r].[TypeMin], 0)
                ELSE 100.0 * ([r].[TypeMax] - [r].[CurrentValue]) / NULLIF([r].[TypeMax] - [r].[TypeMin], 0) END) AS [UsedPercent]
    FROM [IdentityRange] AS [r]
)
INSERT [#SchemaDesignAnalysis_Findings]
SELECT @DatabaseId, @DatabaseName, ''IDENTITY_TYPE_RANGE_USAGE'',
       CASE WHEN [u].[UsedPercent] >= 95 THEN ''HIGH'' ELSE ''MEDIUM'' END,
       N''IDENTITY_COLUMN'', [s].[name], [t].[name], [u].[name], [u].[UsedPercent],
       CONCAT(N''Typwertebereich genutzt: '', CONVERT(nvarchar(60), [u].[UsedPercent]), N'' Prozent.''),
       N''Berechnung nutzt den vollständigen numerischen Typwertebereich; Seed, Reseed, Zyklen und Fachsemantik separat prüfen.''
FROM [IdentityUsage] AS [u]
JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id] = [u].[object_id]
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id] = [t].[schema_id]
WHERE [u].[UsedPercent] >= @IdentityWarnPercent;

INSERT [#SchemaDesignAnalysis_Findings]
SELECT @DatabaseId, @DatabaseName, ''SEQUENCE_RANGE_USAGE'',
       CASE WHEN [q].[is_exhausted] = 1 OR [x].[UsedPercent] >= 95 THEN ''HIGH'' ELSE ''MEDIUM'' END,
       N''SEQUENCE'', [s].[name], [q].[name], NULL, [x].[UsedPercent],
       CONCAT(N''is_exhausted='', [q].[is_exhausted], N''; Typwertebereich genutzt: '',
              CONVERT(nvarchar(60), [x].[UsedPercent]), N'' Prozent.''),
       N''Cache, CYCLE, Sprünge und fachlich erlaubte Wertebereiche separat prüfen.''
FROM [sys].[sequences] AS [q] WITH (NOLOCK)
JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id] = [q].[schema_id]
CROSS APPLY
(
    SELECT CONVERT(decimal(38,4),
           CASE WHEN TRY_CONVERT(decimal(38,0), [q].[increment]) >= 0
                THEN 100.0 * (TRY_CONVERT(decimal(38,0), [q].[current_value]) - TRY_CONVERT(decimal(38,0), [q].[minimum_value]))
                   / NULLIF(TRY_CONVERT(decimal(38,0), [q].[maximum_value]) - TRY_CONVERT(decimal(38,0), [q].[minimum_value]), 0)
                ELSE 100.0 * (TRY_CONVERT(decimal(38,0), [q].[maximum_value]) - TRY_CONVERT(decimal(38,0), [q].[current_value]))
                   / NULLIF(TRY_CONVERT(decimal(38,0), [q].[maximum_value]) - TRY_CONVERT(decimal(38,0), [q].[minimum_value]), 0) END) AS [UsedPercent]
) AS [x]
WHERE [q].[is_exhausted] = 1 OR [x].[UsedPercent] >= @IdentityWarnPercent;';

                EXEC [sys].[sp_executesql]
                      @Sql
                    , N'@IdentityWarnPercent decimal(5,2)'
                    , @IdentityWarnPercent = @IdentityWarnPercent;
            END TRY
            BEGIN CATCH
                INSERT [#SchemaDesignAnalysis_Errors]
                VALUES (@Db,
                        CASE WHEN ERROR_NUMBER() IN (229, 262, 297, 300, 371, 916)
                             THEN 'DENIED_PERMISSION' ELSE 'ERROR_HANDLED' END,
                        ERROR_NUMBER(), ERROR_MESSAGE());
                SET @IsPartial = 1;
            END CATCH;

            FETCH NEXT FROM [database_cursor] INTO @Db;
        END;
        CLOSE [database_cursor];
        DEALLOCATE [database_cursor];

        INSERT [#SchemaDesignAnalysis_Errors]
        SELECT [RequestedName], [StatusCode], NULL, [ErrorMessage]
        FROM [#SchemaDesignAnalysis_DatabaseCandidateWarnings];
        IF EXISTS (SELECT 1 FROM [#SchemaDesignAnalysis_Errors]) SET @IsPartial = 1;

        IF NOT EXISTS (SELECT 1 FROM [#SchemaDesignAnalysis_DatabaseCandidates])
            SELECT @StatusCode = 'DATABASE_UNAVAILABLE', @IsPartial = 1;
        ELSE IF @IsPartial = 1
            SET @StatusCode = 'AVAILABLE_LIMITED';
        ELSE IF EXISTS (SELECT 1 FROM [#SchemaDesignAnalysis_Findings])
            SET @StatusCode = 'AVAILABLE_WITH_FINDING';
    END;

    SELECT @StatusCodeOut = @StatusCode, @IsPartialOut = @IsPartial,
           @ErrorNumberOut = @ErrorNumber, @ErrorMessageOut = @ErrorMessage;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
            (SELECT N'SchemaDesignAnalysis' AS [resultName], 1 AS [schemaVersion],
                    @Now AS [generatedAtUtc], @StatusCode AS [statusCode], @IsPartial AS [isPartial],
                    @IdentityWarnPercent AS [identityWarnPercent]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        DECLARE @FindingsJson nvarchar(max) =
            (SELECT TOP (@Limit) * FROM [#SchemaDesignAnalysis_Findings]
             ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                      [DatabaseId], [SchemaName], [ObjectName], [FindingCode]
             FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max) =
            (SELECT * FROM [#SchemaDesignAnalysis_Errors] ORDER BY [DatabaseName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        SET @Json = CONCAT(N'{"meta":', COALESCE(@MetaJson, N'{}'),
                           N',"findings":', COALESCE(@FindingsJson, N'[]'),
                           N',"warnings":', COALESCE(@WarningsJson, N'[]'), N'}');
    END;

    IF @OutputMode = 'RAW'
    BEGIN
        SELECT N'USP_SchemaDesignAnalysis' AS [ModuleName], @Now AS [CollectionTimeUtc],
               @StatusCode AS [StatusCode], @IsPartial AS [IsPartial],
               @ErrorNumber AS [ErrorNumber], @ErrorMessage AS [ErrorMessage],
               N'Read-only; Befunde sind Prüfaufträge, keine DDL-Anweisungen.' AS [Detail];
        SELECT TOP (@Limit) * FROM [#SchemaDesignAnalysis_Findings]
        ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [DatabaseId], [SchemaName], [ObjectName], [FindingCode];
        SELECT * FROM [#SchemaDesignAnalysis_Errors] ORDER BY [DatabaseName];
    END
    ELSE IF @OutputMode = 'CONSOLE'
    BEGIN
        SELECT N'Schema- und Designkorrektheit' AS [Ergebnis], @Now AS [Stand_UTC],
               @StatusCode AS [Status], (SELECT COUNT_BIG(*) FROM [#SchemaDesignAnalysis_Findings]) AS [Befunde],
               @ErrorMessage AS [Hinweis];
        SELECT TOP (@Limit) N'Schema-Befund' AS [Ergebnis], [DatabaseName] AS [Datenbank],
               [SchemaName] AS [Schema], [ObjectName] AS [Objekt],
               [RelatedObjectName] AS [Bezug], [FindingCode] AS [Befund],
               [Severity] AS [Prioritaet], [MetricValue] AS [Messwert],
               [Evidence] AS [Evidenz], [EvidenceLimit] AS [Grenze]
        FROM [#SchemaDesignAnalysis_Findings]
        ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                 [DatabaseId], [SchemaName], [ObjectName], [FindingCode];
        SELECT N'Schema-Warnung' AS [Ergebnis], [DatabaseName] AS [Datenbank],
               [StatusCode] AS [Status], [ErrorNumber] AS [Fehlernummer], [ErrorMessage] AS [Meldung]
        FROM [#SchemaDesignAnalysis_Errors] ORDER BY [DatabaseName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#SchemaDesignAnalysis_Findings'
            , @ResultLabel=N'SchemaDesignAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#SchemaDesignAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
