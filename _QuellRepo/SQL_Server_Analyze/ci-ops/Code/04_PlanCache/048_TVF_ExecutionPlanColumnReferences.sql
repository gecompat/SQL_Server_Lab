USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ExecutionPlanColumnReferences
Version      : 1.0.2
Stand        : 2026-07-21
Typ          : Inline Table-valued Function
Zweck        : Normalisiert Spaltenrollen aus Showplan-XML für zielgerichtete
               Index- und Statistikauflösung. Keine Katalogzugriffe.
SQL-Version  : SQL Server 2019 oder neuer.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ExecutionPlanColumnReferences]
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
    [RelOps] AS
    (
        SELECT
              [st].[StatementOrdinal],[st].[StatementId],[st].[StatementCompId]
            , [NodeId]=TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , [RelOpXml]=[r].[n].query('.')
        FROM [Statements] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"]') AS [r]([n])
    ),
    [Roles] AS
    (
        SELECT [StatementOrdinal],[StatementId],[StatementCompId],[NodeId],
               CONVERT(varchar(40),'SEEK') [ColumnUsage],CONVERT(varchar(80),'SEEK_PREDICATE') [ExpressionContext],
               [ColumnReferenceXml]=[c].[n].query('.')
        FROM [RelOps]
        CROSS APPLY [RelOpXml].nodes('./*/*[local-name(.)="SeekPredicates"]//*[local-name(.)="ColumnReference"]') AS [c]([n])

        UNION ALL
        SELECT [StatementOrdinal],[StatementId],[StatementCompId],[NodeId],
               'RESIDUAL','PREDICATE',[c].[n].query('.')
        FROM [RelOps]
        CROSS APPLY [RelOpXml].nodes('./*/*[local-name(.)="Predicate"]//*[local-name(.)="ColumnReference"]') AS [c]([n])

        UNION ALL
        SELECT [StatementOrdinal],[StatementId],[StatementCompId],[NodeId],
               'JOIN','JOIN_KEY_OR_PREDICATE',[c].[n].query('.')
        FROM [RelOps]
        CROSS APPLY [RelOpXml].nodes('./*/*[local-name(.)="HashKeysBuild" or local-name(.)="HashKeysProbe" or local-name(.)="InnerSideJoinColumns" or local-name(.)="OuterSideJoinColumns" or local-name(.)="OuterReferences"]//*[local-name(.)="ColumnReference"]') AS [c]([n])

        UNION ALL
        SELECT [StatementOrdinal],[StatementId],[StatementCompId],[NodeId],
               'ORDER_BY','ORDER_REQUIREMENT',[c].[n].query('.')
        FROM [RelOps]
        CROSS APPLY [RelOpXml].nodes('./*/*[local-name(.)="OrderBy" or local-name(.)="SortKeys"]//*[local-name(.)="ColumnReference"]') AS [c]([n])

        UNION ALL
        SELECT [StatementOrdinal],[StatementId],[StatementCompId],[NodeId],
               'GROUP_BY','GROUP_REQUIREMENT',[c].[n].query('.')
        FROM [RelOps]
        CROSS APPLY [RelOpXml].nodes('./*/*[local-name(.)="GroupBy"]//*[local-name(.)="ColumnReference"]') AS [c]([n])

        UNION ALL
        SELECT [StatementOrdinal],[StatementId],[StatementCompId],[NodeId],
               'OUTPUT','OUTPUT_LIST',[c].[n].query('.')
        FROM [RelOps]
        CROSS APPLY [RelOpXml].nodes('./*[local-name(.)="OutputList"]/*[local-name(.)="ColumnReference"]') AS [c]([n])
    ),
    [Raw] AS
    (
        SELECT
              [StatementOrdinal],[StatementId],[StatementCompId],[NodeId]
            , [ColumnUsage],[ExpressionContext]
            , [DatabaseRaw]=NULLIF([ColumnReferenceXml].value('string((/*/@Database)[1])','nvarchar(256)'),N'')
            , [SchemaRaw]=NULLIF([ColumnReferenceXml].value('string((/*/@Schema)[1])','nvarchar(256)'),N'')
            , [ObjectRaw]=NULLIF([ColumnReferenceXml].value('string((/*/@Table)[1])','nvarchar(256)'),N'')
            , [AliasRaw]=NULLIF([ColumnReferenceXml].value('string((/*/@Alias)[1])','nvarchar(256)'),N'')
            , [ColumnRaw]=NULLIF([ColumnReferenceXml].value('string((/*/@Column)[1])','nvarchar(256)'),N'')
        FROM [Roles]
    )
    SELECT
          [ColumnReferenceOrdinal]=CONVERT(bigint,ROW_NUMBER() OVER
            (ORDER BY [StatementOrdinal],COALESCE([NodeId],2147483647),[ColumnUsage],COALESCE([ObjectRaw],N''),COALESCE([ColumnRaw],N'')))
        , [StatementOrdinal],[StatementId],[StatementCompId],[NodeId]
        , [ColumnUsage],[ExpressionContext]
        , [DatabaseName]=CASE WHEN LEFT([DatabaseRaw],1)=N'[' AND RIGHT([DatabaseRaw],1)=N']'
                              THEN REPLACE(SUBSTRING([DatabaseRaw],2,LEN([DatabaseRaw])-2),N']]',N']') ELSE [DatabaseRaw] END
        , [SchemaName]=CASE WHEN LEFT([SchemaRaw],1)=N'[' AND RIGHT([SchemaRaw],1)=N']'
                            THEN REPLACE(SUBSTRING([SchemaRaw],2,LEN([SchemaRaw])-2),N']]',N']') ELSE [SchemaRaw] END
        , [ObjectName]=CASE WHEN LEFT([ObjectRaw],1)=N'[' AND RIGHT([ObjectRaw],1)=N']'
                            THEN REPLACE(SUBSTRING([ObjectRaw],2,LEN([ObjectRaw])-2),N']]',N']') ELSE [ObjectRaw] END
        , [AliasName]=CASE WHEN LEFT([AliasRaw],1)=N'[' AND RIGHT([AliasRaw],1)=N']'
                           THEN REPLACE(SUBSTRING([AliasRaw],2,LEN([AliasRaw])-2),N']]',N']') ELSE [AliasRaw] END
        , [ColumnName]=CASE WHEN LEFT([ColumnRaw],1)=N'[' AND RIGHT([ColumnRaw],1)=N']'
                            THEN REPLACE(SUBSTRING([ColumnRaw],2,LEN([ColumnRaw])-2),N']]',N']') ELSE [ColumnRaw] END
        , [IsSeekColumn]=CONVERT(bit,CASE WHEN [ColumnUsage]='SEEK' THEN 1 ELSE 0 END)
        , [IsResidualPredicateColumn]=CONVERT(bit,CASE WHEN [ColumnUsage]='RESIDUAL' THEN 1 ELSE 0 END)
        , [IsJoinColumn]=CONVERT(bit,CASE WHEN [ColumnUsage]='JOIN' THEN 1 ELSE 0 END)
        , [IsGroupByColumn]=CONVERT(bit,CASE WHEN [ColumnUsage]='GROUP_BY' THEN 1 ELSE 0 END)
        , [IsOrderByColumn]=CONVERT(bit,CASE WHEN [ColumnUsage]='ORDER_BY' THEN 1 ELSE 0 END)
        , [IsOutputColumn]=CONVERT(bit,CASE WHEN [ColumnUsage]='OUTPUT' THEN 1 ELSE 0 END)
        , [IsPartitionColumn]=CONVERT(bit,0)
    FROM [Raw]
    WHERE [ColumnRaw] IS NOT NULL
);
GO
