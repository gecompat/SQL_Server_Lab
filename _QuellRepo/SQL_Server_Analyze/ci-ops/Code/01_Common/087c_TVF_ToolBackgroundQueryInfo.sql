USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ToolBackgroundQueryInfo
Version      : 1.1.0
Stand        : 2026-07-21
Typ          : Inline Table-valued Function
Zweck        : Wertet aktivierte LIKE-Regeln aus ToolBackgroundQueryPattern aus.
Vertrag      : Heuristik für die Diagnoseausgabe, kein Sicherheitsmerkmal.
Eigenlast    : Kein DMV-, SQL-Text- oder fremder Datenbankzugriff.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ToolBackgroundQueryInfo]
(
    @ProgramName nvarchar(128)
)
RETURNS TABLE
AS
RETURN
(
    SELECT
          [IsToolBackgroundQuery] = CONVERT
            (
                bit,
                CASE WHEN [rule].[RuleCode] IS NULL THEN 0 ELSE 1 END
            )
        , [ToolBackgroundRuleCode] = [rule].[RuleCode]
        , [rule].[ToolBackgroundCategory]
        , [rule].[ToolBackgroundDetection]
        , [rule].[ToolBackgroundConfidence]
    FROM (VALUES (CONVERT(bit, 1))) AS [seed]([Value])
    OUTER APPLY
    (
        SELECT TOP (1)
              [p].[RuleCode]
            , [p].[ToolBackgroundCategory]
            , [p].[ToolBackgroundDetection]
            , [p].[ToolBackgroundConfidence]
        FROM [monitor].[ToolBackgroundQueryPattern] AS [p] WITH (NOLOCK)
        WHERE [p].[IsEnabled] = 1
          AND @ProgramName COLLATE Latin1_General_100_CI_AS
              LIKE [p].[ProgramNameLikePattern] COLLATE Latin1_General_100_CI_AS
        ORDER BY [p].[Priority] DESC, [p].[RuleCode]
    ) AS [rule]
);
GO
