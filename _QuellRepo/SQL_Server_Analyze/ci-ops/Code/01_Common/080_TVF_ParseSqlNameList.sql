USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ParseSqlNameList
Version      : 1.0.0
Stand        : 2026-07-15
Typ          : Inline Table-valued Function
Zweck        : Validiert eine bracket-aware Pipe-Liste aus einteiligen SQL-
               Namen und liefert die entquoteten sysname-Werte.
Beispiele    : SELECT * FROM monitor.TVF_ParseSqlNameList(
                   N'[ColumnOne]|[Column With Spaces]|[Column|WithPipe]');
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ParseSqlNameList]
(
    @List nvarchar(max)
)
RETURNS TABLE
AS
RETURN
(
    SELECT
          [l].[ItemOrdinal]
        , [l].[ItemText]
        , [NameValue] = CONVERT(sysname, PARSENAME([l].[ItemText], 1))
        , [IsValid] = CONVERT(bit,
              CASE WHEN [l].[IsValid] = 1
                     AND PARSENAME([l].[ItemText], 1) IS NOT NULL
                     AND PARSENAME([l].[ItemText], 2) IS NULL
                     AND LEN(PARSENAME([l].[ItemText], 1)) <= 128
                   THEN 1 ELSE 0 END)
        , [ErrorCode] = CONVERT(varchar(40),
              CASE WHEN [l].[IsValid] = 0 THEN [l].[ErrorCode]
                   WHEN PARSENAME([l].[ItemText], 1) IS NULL THEN 'INVALID_SQL_NAME'
                   WHEN PARSENAME([l].[ItemText], 2) IS NOT NULL THEN 'MULTIPART_NAME_NOT_ALLOWED'
                   WHEN LEN(PARSENAME([l].[ItemText], 1)) > 128 THEN 'SQL_NAME_TOO_LONG'
              END)
        , [ErrorMessage] = CONVERT(nvarchar(4000),
              CASE WHEN [l].[IsValid] = 0 THEN [l].[ErrorMessage]
                   WHEN PARSENAME([l].[ItemText], 1) IS NULL THEN N'Das Listenelement ist kein gültiger SQL-Name.'
                   WHEN PARSENAME([l].[ItemText], 2) IS NOT NULL THEN N'Für diesen Parameter ist nur ein einteiliger SQL-Name zulässig.'
                   WHEN LEN(PARSENAME([l].[ItemText], 1)) > 128 THEN N'Der SQL-Name überschreitet die sysname-Länge von 128 Zeichen.'
              END)
    FROM [monitor].[TVF_ParsePipeList](@List) AS [l]
);
GO
