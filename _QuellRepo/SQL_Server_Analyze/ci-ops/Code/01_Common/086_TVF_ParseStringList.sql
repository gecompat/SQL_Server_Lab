USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ParseStringList
Version      : 1.0.0
Stand        : 2026-07-15
Typ          : Inline Table-valued Function
Zweck        : Liefert aus einer bracket-aware Pipe-Liste allgemeine Textwerte.
               Ein Punkt besitzt hier keine Sonderbedeutung. Äußere Brackets
               werden entfernt; ]] wird zu ].
Beispiele    : SELECT * FROM monitor.TVF_ParseStringList(
                   N'[Microsoft SQL Server Management Studio]|Sample.Loader');
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ParseStringList]
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
        , [StringValue] = CONVERT
          (
              nvarchar(4000),
              CASE WHEN [l].[IsBracketQuoted] = 1
                   THEN REPLACE(SUBSTRING([l].[ItemText], 2, LEN([l].[ItemText]) - 2), N']]', N']')
                   ELSE [l].[ItemText]
              END
          ) COLLATE SQL_Latin1_General_CP1_CS_AS
        , [IsValid] = CONVERT
          (
              bit,
              CASE WHEN [l].[IsValid] = 1
                      AND NULLIF
                          (
                              CASE WHEN [l].[IsBracketQuoted] = 1
                                   THEN REPLACE(SUBSTRING([l].[ItemText], 2, LEN([l].[ItemText]) - 2), N']]', N']')
                                   ELSE [l].[ItemText]
                              END,
                              N''
                          ) IS NOT NULL
                   THEN 1 ELSE 0 END
          )
        , [ErrorCode] = CONVERT
          (
              varchar(40),
              CASE WHEN [l].[IsValid] = 0 THEN [l].[ErrorCode]
                   WHEN NULLIF
                        (
                            CASE WHEN [l].[IsBracketQuoted] = 1
                                 THEN REPLACE(SUBSTRING([l].[ItemText], 2, LEN([l].[ItemText]) - 2), N']]', N']')
                                 ELSE [l].[ItemText]
                            END,
                            N''
                        ) IS NULL THEN 'EMPTY_VALUE'
              END
          )
        , [ErrorMessage] = CONVERT
          (
              nvarchar(4000),
              CASE WHEN [l].[IsValid] = 0 THEN [l].[ErrorMessage]
                   WHEN NULLIF
                        (
                            CASE WHEN [l].[IsBracketQuoted] = 1
                                 THEN REPLACE(SUBSTRING([l].[ItemText], 2, LEN([l].[ItemText]) - 2), N']]', N']')
                                 ELSE [l].[ItemText]
                            END,
                            N''
                        ) IS NULL THEN N'Der Listenwert darf nicht leer sein.'
              END
          )
    FROM [monitor].[TVF_ParsePipeList](@List) AS [l]
);
GO
