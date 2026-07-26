USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_DatabaseCandidates
Version      : 3.0.0
Stand        : 2026-07-20
Typ          : Inline Table-valued Function
Zweck        : Liefert alle sichtbaren, zugreifbaren und online befindlichen
               Benutzerdatenbanken oder eine explizit eingeschränkte Menge.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : master.sys.databases, monitor.TVF_ParseSqlNameList,
               monitor.TVF_ParsePattern.
Semantik     : NULL, N'' und Leerzeichen bedeuten keine Einschränkung.
               Systemdatenbanken sind ausschließlich per Opt-in enthalten.
               Die Kandidatenmenge wird niemals vorab mengenmäßig begrenzt.
Vertrag      : Die Kandidatenmenge wird erst nach vollständiger Ermittlung und
               ohne willkürliche Vorabbegrenzung an den Aufrufer zurückgegeben.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_DatabaseCandidates]
(
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
)
RETURNS TABLE
AS
RETURN
(
    WITH [Parameters] AS
    (
        SELECT [EffectiveDatabaseNames] = CONVERT
        (
            nvarchar(max),
            CASE
                WHEN NULLIF(LTRIM(RTRIM(COALESCE(@DatabaseNames, N''))), N'') IS NULL
                    THEN NULL
                ELSE @DatabaseNames
            END
        )
    ),
    [ExactNames] AS
    (
        SELECT
              [l].[ItemOrdinal]
            , [DatabaseName] = CONVERT(sysname, [l].[NameValue])
        FROM [Parameters] AS [p]
        CROSS APPLY [monitor].[TVF_ParseSqlNameList]([p].[EffectiveDatabaseNames]) AS [l]
        WHERE [l].[IsValid] = 1
    ),
    [Pattern] AS
    (
        SELECT [PatternMode], [PatternValue], [IsValid]
        FROM [monitor].[TVF_ParsePattern](@DatabaseNamePattern)
    )
    SELECT
          [d].[database_id] AS [DatabaseId]
        , [d].[name] COLLATE SQL_Latin1_General_CP1_CS_AS AS [DatabaseName]
        , [d].[state_desc] AS [StateDesc]
        , [d].[user_access_desc] AS [UserAccessDesc]
        , [d].[is_read_only] AS [IsReadOnly]
        , [d].[compatibility_level] AS [CompatibilityLevel]
        , [d].[collation_name] AS [CollationName]
        , [d].[recovery_model_desc] AS [RecoveryModelDesc]
        , CONVERT(bit, CASE WHEN [d].[database_id] <= 4 THEN 1 ELSE 0 END) AS [IsSystemDatabase]
        , [e].[ItemOrdinal] AS [RequestedOrdinal]
    FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
    CROSS JOIN [Parameters] AS [p]
    CROSS JOIN [Pattern] AS [pt]
    LEFT JOIN [ExactNames] AS [e]
      ON [e].[DatabaseName] COLLATE SQL_Latin1_General_CP1_CS_AS
       = [d].[name] COLLATE SQL_Latin1_General_CP1_CS_AS
    WHERE [pt].[IsValid] = 1
      AND [d].[source_database_id] IS NULL
      AND [d].[state] = 0
      AND HAS_DBACCESS([d].[name]) = 1
      AND (@SystemdatenbankenEinbeziehen = 1 OR [d].[database_id] > 4)
      AND ([p].[EffectiveDatabaseNames] IS NULL OR [e].[DatabaseName] IS NOT NULL)
      AND
      (
          [pt].[PatternMode] IN ('NONE', 'REGEX', 'REGEXI')
          OR [d].[name] COLLATE SQL_Latin1_General_CP1_CS_AS
             LIKE [pt].[PatternValue] COLLATE SQL_Latin1_General_CP1_CS_AS
      )
);
GO
