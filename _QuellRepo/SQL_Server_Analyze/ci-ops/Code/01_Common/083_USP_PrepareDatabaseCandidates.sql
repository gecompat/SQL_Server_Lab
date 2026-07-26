USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_PrepareDatabaseCandidates
Version      : 2.0.0
Stand        : 2026-07-20
Typ          : Interne Stored Procedure
Zweck        : Validiert die frameworkweite Datenbankauswahl, prüft den
               tatsächlich aktivierten Analysepfad und befüllt lokale
               Kandidaten- und Warning-Temp-Tabellen des Aufrufers.
Semantik     : Ohne explizite Einschränkung alle sichtbaren, online befindlichen
               Benutzerdatenbanken. Kein CURRENT-Scope und keine Vorabbegrenzung.
High Impact  : Nur eine tatsächlich aktivierte Analyseklasse mit
               RequiresGroupGate=1 verlangt @HighImpactConfirmed=1.
Vertrag      : Die Procedure kennt keine Datenbank-Mengenbegrenzung.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_PrepareDatabaseCandidates]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @AnalysisClass                    varchar(64)    = NULL
    , @HighImpactConfirmed              bit            = 0
    , @StatusCode                       varchar(40)    OUTPUT
    , @ErrorMessage                     nvarchar(2048) OUTPUT
    , @CrossDatabaseRequested           bit            OUTPUT
    , @CandidateTable                   sysname        = N'#PrepareDatabaseCandidates_Result'
    , @WarningTable                     sysname        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;

    SELECT
          @StatusCode = 'AVAILABLE'
        , @ErrorMessage = NULL
        , @CrossDatabaseRequested = 0;

    DECLARE @EffectiveDatabaseNames nvarchar(max) =
        CASE WHEN NULLIF(LTRIM(RTRIM(COALESCE(@DatabaseNames, N''))), N'') IS NULL
             THEN NULL ELSE @DatabaseNames END;
    DECLARE @PatternMode varchar(8);
    DECLARE @PatternValue nvarchar(4000);
    DECLARE @RegexFlags varchar(8);
    DECLARE @PatternIsValid bit;
    DECLARE @DatabaseListCount int = 0;
    DECLARE @Sql nvarchar(max);
    DECLARE @CandidateTableQuoted nvarchar(258);
    DECLARE @WarningTableQuoted nvarchar(258);

    IF @SystemdatenbankenEinbeziehen IS NULL
       OR @SystemdatenbankenEinbeziehen NOT IN (0,1)
       OR @HighImpactConfirmed IS NULL
       OR @HighImpactConfirmed NOT IN (0,1)
       OR @CandidateTable IS NULL
       OR LEFT(@CandidateTable,1) <> N'#'
       OR LEFT(@CandidateTable,2) = N'##'
       OR LEN(@CandidateTable) > 116
       OR
       (
           @WarningTable IS NOT NULL
           AND
           (
               LEFT(@WarningTable,1) <> N'#'
               OR LEFT(@WarningTable,2) = N'##'
               OR LEN(@WarningTable) > 116
           )
       )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültige Auswahl-, Bestätigungs- oder interne Temp-Tabellenparameter.';
        RETURN;
    END;

    SELECT
          @CandidateTableQuoted = QUOTENAME(@CandidateTable)
        , @WarningTableQuoted = QUOTENAME(@WarningTable);

    CREATE TABLE [#PrepareDatabaseCandidates_Work]
    (
          [DatabaseId] int NOT NULL
        , [DatabaseName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , [StateDesc] nvarchar(60) NULL
        , [UserAccessDesc] nvarchar(60) NULL
        , [IsReadOnly] bit NULL
        , [CompatibilityLevel] tinyint NULL
        , [CollationName] sysname NULL
        , [RecoveryModelDesc] nvarchar(60) NULL
        , [IsSystemDatabase] bit NULL
        , [RequestedOrdinal] int NULL
    );

    CREATE TABLE [#PrepareDatabaseCandidates_RequestedNames]
    (
          [NameValue] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NULL
        , [IsValid] bit NOT NULL
    );

    IF @EffectiveDatabaseNames IS NOT NULL
        INSERT [#PrepareDatabaseCandidates_RequestedNames]([NameValue],[IsValid])
        SELECT [NameValue],[IsValid]
        FROM [monitor].[TVF_ParseSqlNameList](@EffectiveDatabaseNames);

    BEGIN TRY
        SET @Sql = N'DECLARE @DatabaseId int,@DatabaseName sysname;
SELECT TOP (0) @DatabaseId=[DatabaseId],@DatabaseName=[DatabaseName]
FROM ' + @CandidateTableQuoted + N';';
        EXEC [sys].[sp_executesql] @Sql;
    END TRY
    BEGIN CATCH
        SET @StatusCode = 'INTERNAL_ERROR';
        SET @ErrorMessage = N'Die Kandidaten-Temp-Tabelle wurde nicht mit dem erwarteten Schema angelegt.';
        RETURN;
    END CATCH;

    SELECT
          @PatternMode = [PatternMode]
        , @PatternValue = [PatternValue]
        , @RegexFlags = [RegexFlags]
        , @PatternIsValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@DatabaseNamePattern);

    IF @EffectiveDatabaseNames IS NOT NULL
        SELECT @DatabaseListCount = COUNT(*)
        FROM [#PrepareDatabaseCandidates_RequestedNames]
        WHERE [IsValid] = 1;

    SET @CrossDatabaseRequested = CONVERT
    (
        bit,
        CASE WHEN @EffectiveDatabaseNames IS NULL OR @DatabaseListCount > 1
             THEN 1 ELSE 0 END
    );

    IF @PatternIsValid = 0
       OR
       (
           @EffectiveDatabaseNames IS NOT NULL
           AND EXISTS
           (
               SELECT 1
               FROM [#PrepareDatabaseCandidates_RequestedNames]
               WHERE [IsValid] = 0
           )
       )
       OR (@EffectiveDatabaseNames IS NOT NULL AND @DatabaseNamePattern IS NOT NULL)
       OR
       (
           @EffectiveDatabaseNames IS NOT NULL
           AND EXISTS
           (
               SELECT [NameValue]
               FROM [#PrepareDatabaseCandidates_RequestedNames]
               WHERE [IsValid] = 1
               GROUP BY [NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS
               HAVING COUNT(*) > 1
           )
       )
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültige oder doppelte Datenbankliste beziehungsweise ungültiges Pattern. Exakte Liste und Pattern sind gegenseitig exklusiv.';
        RETURN;
    END;

    IF NULLIF(@AnalysisClass, '') IS NOT NULL
    BEGIN
        EXEC [monitor].[InternalCheckAnalysisPath]
              @AnalysisClass=@AnalysisClass
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT;

        IF @StatusCode<>'AVAILABLE'
            RETURN;
    END;

    INSERT [#PrepareDatabaseCandidates_Work]
    (
          [DatabaseId],[DatabaseName],[StateDesc],[UserAccessDesc],[IsReadOnly]
        , [CompatibilityLevel],[CollationName],[RecoveryModelDesc]
        , [IsSystemDatabase],[RequestedOrdinal]
    )
    SELECT
          [DatabaseId],[DatabaseName],[StateDesc],[UserAccessDesc],[IsReadOnly]
        , [CompatibilityLevel],[CollationName],[RecoveryModelDesc]
        , [IsSystemDatabase],[RequestedOrdinal]
    FROM [monitor].[TVF_DatabaseCandidates]
    (
          @EffectiveDatabaseNames
        , @SystemdatenbankenEinbeziehen
        , @DatabaseNamePattern
    );

    SET @Sql = N'INSERT ' + @CandidateTableQuoted + N'
(
      [DatabaseId],[DatabaseName],[StateDesc],[UserAccessDesc],[IsReadOnly]
    , [CompatibilityLevel],[CollationName],[RecoveryModelDesc]
    , [IsSystemDatabase],[RequestedOrdinal]
)
SELECT
      [DatabaseId],[DatabaseName],[StateDesc],[UserAccessDesc],[IsReadOnly]
    , [CompatibilityLevel],[CollationName],[RecoveryModelDesc]
    , [IsSystemDatabase],[RequestedOrdinal]
FROM [#PrepareDatabaseCandidates_Work];';
    EXEC [sys].[sp_executesql] @Sql;

    DECLARE @WarningTableAvailable bit = 0;
    IF @WarningTable IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT TOP (0) [RequestedName],[StatusCode],[ErrorMessage] FROM ' + @WarningTableQuoted + N';';
            EXEC [sys].[sp_executesql] @Sql;
            SET @WarningTableAvailable = 1;
        END TRY
        BEGIN CATCH
            SET @WarningTableAvailable = 0;
        END CATCH;
    END;

    IF @WarningTableAvailable = 1 AND @EffectiveDatabaseNames IS NOT NULL
    BEGIN
        SET @Sql = N'INSERT ' + @WarningTableQuoted + N' ([RequestedName],[StatusCode],[ErrorMessage])
SELECT
      [n].[NameValue]
    , CASE
          WHEN @IncludeSystem = 0
           AND [n].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS
               IN (N''master'',N''tempdb'',N''model'',N''msdb'')
              THEN ''SYSTEM_DATABASE_EXCLUDED''
          ELSE ''DATABASE_UNAVAILABLE''
      END
    , CASE
          WHEN @IncludeSystem = 0
           AND [n].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS
               IN (N''master'',N''tempdb'',N''model'',N''msdb'')
              THEN N''Die explizit angeforderte Systemdatenbank ist ohne Opt-in ausgeschlossen.''
          ELSE N''Die explizit angeforderte Datenbank ist nicht vorhanden, nicht online oder für den aktuellen Login nicht zugreifbar.''
      END
FROM [#PrepareDatabaseCandidates_RequestedNames] AS [n]
WHERE [n].[IsValid] = 1
  AND NOT EXISTS
      (
          SELECT 1
          FROM ' + @CandidateTableQuoted + N' AS [c]
          WHERE [c].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
              = [n].[NameValue] COLLATE SQL_Latin1_General_CP1_CS_AS
      );';

        EXEC [sys].[sp_executesql]
              @Sql
            , N'@IncludeSystem bit'
            , @IncludeSystem = @SystemdatenbankenEinbeziehen;
    END;

    IF @PatternMode IN ('REGEX', 'REGEXI')
    BEGIN
        IF TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) < 17
           OR NOT EXISTS
              (
                  SELECT 1
                  FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
                  WHERE [d].[database_id] = DB_ID()
                    AND [d].[compatibility_level] >= 170
              )
        BEGIN
            SET @Sql = N'DELETE FROM ' + @CandidateTableQuoted + N';';
            EXEC [sys].[sp_executesql] @Sql;
            SET @StatusCode = 'UNAVAILABLE_FEATURE';
            SET @ErrorMessage = N'Regex benötigt SQL Server 2025 und Compatibility Level 170 für die Installationsdatenbank.';
            RETURN;
        END;

        SET @Sql = N'DELETE [c]
FROM ' + @CandidateTableQuoted + N' AS [c]
WHERE NOT REGEXP_LIKE([c].[DatabaseName], @Pattern, @Flags);';

        EXEC [sys].[sp_executesql]
              @Sql
            , N'@Pattern nvarchar(4000), @Flags varchar(8)'
            , @Pattern = @PatternValue
            , @Flags = @RegexFlags;
    END;
END;
GO
