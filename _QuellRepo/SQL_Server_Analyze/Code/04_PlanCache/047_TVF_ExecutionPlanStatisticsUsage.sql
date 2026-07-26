USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ExecutionPlanStatisticsUsage
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Inline Table-valued Function
Zweck        : Extrahiert OptimizerStatsUsage je Statement aus Showplan-XML.
               Die Werte beschreiben den im Plan gespeicherten Compilezeitstand.
SQL-Version  : SQL Server 2019 oder neuer.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ExecutionPlanStatisticsUsage]
(
      @PlanXml     xml
    , @StatementId int = NULL
)
RETURNS TABLE
AS
RETURN
(
    WITH [StatementsBase] AS
    (
        SELECT
              [StatementXml]=[s].[n].query('.')
            , [StatementId]=TRY_CONVERT(int,NULLIF([s].[n].value('string((@StatementId)[1])','nvarchar(50)'),N''))
            , [StatementCompId]=TRY_CONVERT(int,NULLIF([s].[n].value('string((@StatementCompId)[1])','nvarchar(50)'),N''))
            , [StatementText]=NULLIF([s].[n].value('string((@StatementText)[1])','nvarchar(4000)'),N'')
        FROM @PlanXml.nodes('//*[local-name(.)="StmtSimple"]') AS [s]([n])
    ),
    [Statements] AS
    (
        SELECT
              [StatementOrdinal]=CONVERT(int,ROW_NUMBER() OVER
                (ORDER BY COALESCE([StatementId],2147483647),COALESCE([StatementCompId],2147483647),COALESCE([StatementText],N'')))
            , [StatementId],[StatementCompId],[StatementXml]
        FROM [StatementsBase]
        WHERE @StatementId IS NULL OR [StatementId]=@StatementId
    ),
    [Raw] AS
    (
        SELECT
              [st].[StatementOrdinal],[st].[StatementId],[st].[StatementCompId]
            , [DatabaseRaw]=NULLIF([i].[n].value('string((@Database)[1])','nvarchar(256)'),N'')
            , [SchemaRaw]=NULLIF([i].[n].value('string((@Schema)[1])','nvarchar(256)'),N'')
            , [ObjectRaw]=NULLIF([i].[n].value('string((@Table)[1])','nvarchar(256)'),N'')
            , [StatisticsRaw]=NULLIF([i].[n].value('string((@Statistics)[1])','nvarchar(256)'),N'')
            , [LastUpdateAtCompile]=TRY_CONVERT(datetime2(7),NULLIF([i].[n].value('string((@LastUpdate)[1])','nvarchar(100)'),N''))
            , [ModificationCountAtCompile]=TRY_CONVERT(bigint,NULLIF([i].[n].value('string((@ModificationCount)[1])','nvarchar(100)'),N''))
            , [SamplingPercentAtCompile]=TRY_CONVERT(decimal(19,6),NULLIF([i].[n].value('string((@SamplingPercent)[1])','nvarchar(100)'),N''))
        FROM [Statements] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="OptimizerStatsUsage"]/*[local-name(.)="StatisticsInfo"]') AS [i]([n])
    )
    SELECT
          [StatisticsUsageOrdinal]=CONVERT(bigint,ROW_NUMBER() OVER
            (ORDER BY [StatementOrdinal],COALESCE([DatabaseRaw],N''),COALESCE([SchemaRaw],N''),COALESCE([ObjectRaw],N''),COALESCE([StatisticsRaw],N'')))
        , [StatementOrdinal],[StatementId],[StatementCompId]
        , [DatabaseName]=CASE WHEN LEFT([DatabaseRaw],1)=N'[' AND RIGHT([DatabaseRaw],1)=N']'
                              THEN REPLACE(SUBSTRING([DatabaseRaw],2,LEN([DatabaseRaw])-2),N']]',N']') ELSE [DatabaseRaw] END
        , [SchemaName]=CASE WHEN LEFT([SchemaRaw],1)=N'[' AND RIGHT([SchemaRaw],1)=N']'
                            THEN REPLACE(SUBSTRING([SchemaRaw],2,LEN([SchemaRaw])-2),N']]',N']') ELSE [SchemaRaw] END
        , [ObjectName]=CASE WHEN LEFT([ObjectRaw],1)=N'[' AND RIGHT([ObjectRaw],1)=N']'
                            THEN REPLACE(SUBSTRING([ObjectRaw],2,LEN([ObjectRaw])-2),N']]',N']') ELSE [ObjectRaw] END
        , [StatisticsName]=CASE WHEN LEFT([StatisticsRaw],1)=N'[' AND RIGHT([StatisticsRaw],1)=N']'
                                THEN REPLACE(SUBSTRING([StatisticsRaw],2,LEN([StatisticsRaw])-2),N']]',N']') ELSE [StatisticsRaw] END
        , [LastUpdateAtCompile],[ModificationCountAtCompile],[SamplingPercentAtCompile]
        , [SourceElement]=CONVERT(nvarchar(128),N'OptimizerStatsUsage/StatisticsInfo')
        , [ParseStatus]=CONVERT(varchar(40),CASE
              WHEN [ObjectRaw] IS NOT NULL AND [StatisticsRaw] IS NOT NULL THEN 'AVAILABLE'
              ELSE 'INCOMPLETE_REFERENCE' END)
    FROM [Raw]
);
GO
