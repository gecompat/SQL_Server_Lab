USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ParseFullObjectNameList
Version      : 1.0.0
Stand        : 2026-07-15
Typ          : Inline Table-valued Function
Zweck        : Validiert eine bracket-aware Pipe-Liste aus ein-, zwei- oder
               dreiteiligen Objektbezügen: Objekt, Schema.Objekt oder
               Datenbank.Schema.Objekt. Vierteilige Linked-Server-Namen werden
               bewusst nicht unterstützt.
Beispiele    : SELECT * FROM monitor.TVF_ParseFullObjectNameList(
                   N'[DeineDatenbank].dbo.[IrgendeinObjekt]|und.noch.eines');
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ParseFullObjectNameList]
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
        , [DatabaseName] = CONVERT(sysname, PARSENAME([l].[ItemText], 3))
        , [SchemaName]   = CONVERT(sysname, PARSENAME([l].[ItemText], 2))
        , [ObjectName]   = CONVERT(sysname, PARSENAME([l].[ItemText], 1))
        , [PartCount]    = CONVERT(tinyint,
              CASE WHEN PARSENAME([l].[ItemText], 3) IS NOT NULL THEN 3
                   WHEN PARSENAME([l].[ItemText], 2) IS NOT NULL THEN 2
                   WHEN PARSENAME([l].[ItemText], 1) IS NOT NULL THEN 1
                   ELSE 0 END)
        , [IsValid] = CONVERT(bit,
              CASE WHEN [l].[IsValid] = 1
                     AND PARSENAME([l].[ItemText], 1) IS NOT NULL
                     AND PARSENAME([l].[ItemText], 4) IS NULL
                     AND NOT (PARSENAME([l].[ItemText], 3) IS NOT NULL
                              AND PARSENAME([l].[ItemText], 2) IS NULL)
                     AND LEN(PARSENAME([l].[ItemText], 1)) <= 128
                     AND COALESCE(LEN(PARSENAME([l].[ItemText], 2)), 0) <= 128
                     AND COALESCE(LEN(PARSENAME([l].[ItemText], 3)), 0) <= 128
                   THEN 1 ELSE 0 END)
        , [ErrorCode] = CONVERT(varchar(40),
              CASE WHEN [l].[IsValid] = 0 THEN [l].[ErrorCode]
                   WHEN PARSENAME([l].[ItemText], 1) IS NULL THEN 'INVALID_OBJECT_REFERENCE'
                   WHEN PARSENAME([l].[ItemText], 4) IS NOT NULL THEN 'FOUR_PART_NAME_NOT_ALLOWED'
                   WHEN PARSENAME([l].[ItemText], 3) IS NOT NULL
                    AND PARSENAME([l].[ItemText], 2) IS NULL THEN 'SCHEMA_NAME_REQUIRED'
                   WHEN LEN(PARSENAME([l].[ItemText], 1)) > 128
                     OR COALESCE(LEN(PARSENAME([l].[ItemText], 2)), 0) > 128
                     OR COALESCE(LEN(PARSENAME([l].[ItemText], 3)), 0) > 128 THEN 'SQL_NAME_TOO_LONG'
              END)
        , [ErrorMessage] = CONVERT(nvarchar(4000),
              CASE WHEN [l].[IsValid] = 0 THEN [l].[ErrorMessage]
                   WHEN PARSENAME([l].[ItemText], 1) IS NULL THEN N'Der Objektbezug ist syntaktisch ungültig.'
                   WHEN PARSENAME([l].[ItemText], 4) IS NOT NULL THEN N'Vierteilige Linked-Server-Namen werden nicht unterstützt.'
                   WHEN PARSENAME([l].[ItemText], 3) IS NOT NULL
                    AND PARSENAME([l].[ItemText], 2) IS NULL THEN N'Bei einem dreiteiligen Objektbezug ist das Schema erforderlich.'
                   WHEN LEN(PARSENAME([l].[ItemText], 1)) > 128
                     OR COALESCE(LEN(PARSENAME([l].[ItemText], 2)), 0) > 128
                     OR COALESCE(LEN(PARSENAME([l].[ItemText], 3)), 0) > 128 THEN N'Mindestens ein Namensbestandteil überschreitet die sysname-Länge von 128 Zeichen.'
              END)
    FROM [monitor].[TVF_ParsePipeList](@List) AS [l]
);
GO
