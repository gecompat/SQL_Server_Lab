USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.TVF_ExecutionPlanObjectReferences
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Inline Table-valued Function
Zweck        : Extrahiert statement- und operatorbezogene Objekt-/Indexreferenzen
               ausschließlich aus übergebenem Showplan-XML. Keine Katalogzugriffe.
SQL-Version  : SQL Server 2019 oder neuer.
===============================================================================
*/
CREATE OR ALTER FUNCTION [monitor].[TVF_ExecutionPlanObjectReferences]
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
            , [StatementId]
            , [StatementCompId]
            , [StatementXml]
        FROM [StatementsBase]
        WHERE @StatementId IS NULL OR [StatementId]=@StatementId
    ),
    [AccessObjectsRaw] AS
    (
        SELECT
              [st].[StatementOrdinal]
            , [st].[StatementId]
            , [st].[StatementCompId]
            , [NodeId]=TRY_CONVERT(int,NULLIF([r].[n].value('string((@NodeId)[1])','nvarchar(50)'),N''))
            , [PhysicalOp]=NULLIF([r].[n].value('string((@PhysicalOp)[1])','nvarchar(128)'),N'')
            , [DatabaseRaw]=NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Database)[1])','nvarchar(256)'),N'')
            , [SchemaRaw]=NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Schema)[1])','nvarchar(256)'),N'')
            , [ObjectRaw]=NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Table)[1])','nvarchar(256)'),N'')
            , [IndexRaw]=NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Index)[1])','nvarchar(256)'),N'')
            , [AliasRaw]=NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Alias)[1])','nvarchar(256)'),N'')
            , [StorageType]=NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@Storage)[1])','nvarchar(128)'),N'')
            , [PlanObjectId]=TRY_CONVERT(int,NULLIF([r].[n].value('string((./*/*[local-name(.)="Object"]/@ObjectId)[1])','nvarchar(50)'),N''))
            , [PlanIndexId]=CONVERT(int,NULL)
        FROM [Statements] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="RelOp"]') AS [r]([n])
        WHERE [r].[n].exist('./*/*[local-name(.)="Object"]')=1
    ),
    [AccessObjects] AS
    (
        SELECT
              [StatementOrdinal],[StatementId],[StatementCompId],[NodeId],[PhysicalOp]
            , [DatabaseName]=CASE WHEN LEFT([DatabaseRaw],1)=N'[' AND RIGHT([DatabaseRaw],1)=N']'
                                  THEN REPLACE(SUBSTRING([DatabaseRaw],2,LEN([DatabaseRaw])-2),N']]',N']') ELSE [DatabaseRaw] END
            , [SchemaName]=CASE WHEN LEFT([SchemaRaw],1)=N'[' AND RIGHT([SchemaRaw],1)=N']'
                                THEN REPLACE(SUBSTRING([SchemaRaw],2,LEN([SchemaRaw])-2),N']]',N']') ELSE [SchemaRaw] END
            , [ObjectName]=CASE WHEN LEFT([ObjectRaw],1)=N'[' AND RIGHT([ObjectRaw],1)=N']'
                                THEN REPLACE(SUBSTRING([ObjectRaw],2,LEN([ObjectRaw])-2),N']]',N']') ELSE [ObjectRaw] END
            , [IndexName]=CASE WHEN LEFT([IndexRaw],1)=N'[' AND RIGHT([IndexRaw],1)=N']'
                               THEN REPLACE(SUBSTRING([IndexRaw],2,LEN([IndexRaw])-2),N']]',N']') ELSE [IndexRaw] END
            , [AliasName]=CASE WHEN LEFT([AliasRaw],1)=N'[' AND RIGHT([AliasRaw],1)=N']'
                               THEN REPLACE(SUBSTRING([AliasRaw],2,LEN([AliasRaw])-2),N']]',N']') ELSE [AliasRaw] END
            , [StorageType],[PlanObjectId],[PlanIndexId]
        FROM [AccessObjectsRaw]
    ),
    [MissingObjectsRaw] AS
    (
        SELECT
              [st].[StatementOrdinal]
            , [st].[StatementId]
            , [st].[StatementCompId]
            , [DatabaseRaw]=NULLIF([m].[n].value('string((@Database)[1])','nvarchar(256)'),N'')
            , [SchemaRaw]=NULLIF([m].[n].value('string((@Schema)[1])','nvarchar(256)'),N'')
            , [ObjectRaw]=NULLIF([m].[n].value('string((@Table)[1])','nvarchar(256)'),N'')
        FROM [Statements] AS [st]
        CROSS APPLY [st].[StatementXml].nodes('.//*[local-name(.)="MissingIndex"]') AS [m]([n])
    ),
    [MissingObjects] AS
    (
        SELECT
              [StatementOrdinal],[StatementId],[StatementCompId]
            , [DatabaseName]=CASE WHEN LEFT([DatabaseRaw],1)=N'[' AND RIGHT([DatabaseRaw],1)=N']'
                                  THEN REPLACE(SUBSTRING([DatabaseRaw],2,LEN([DatabaseRaw])-2),N']]',N']') ELSE [DatabaseRaw] END
            , [SchemaName]=CASE WHEN LEFT([SchemaRaw],1)=N'[' AND RIGHT([SchemaRaw],1)=N']'
                                THEN REPLACE(SUBSTRING([SchemaRaw],2,LEN([SchemaRaw])-2),N']]',N']') ELSE [SchemaRaw] END
            , [ObjectName]=CASE WHEN LEFT([ObjectRaw],1)=N'[' AND RIGHT([ObjectRaw],1)=N']'
                                THEN REPLACE(SUBSTRING([ObjectRaw],2,LEN([ObjectRaw])-2),N']]',N']') ELSE [ObjectRaw] END
        FROM [MissingObjectsRaw]
    ),
    [AllReferences] AS
    (
        SELECT
              [StatementOrdinal],[StatementId],[StatementCompId],[NodeId]
            , [ReferenceType]=CONVERT(varchar(40),CASE
                  WHEN [ObjectName] LIKE N'#%' THEN 'TEMPORARY_OBJECT'
                  WHEN [ObjectName] LIKE N'@%' THEN 'TABLE_VARIABLE'
                  WHEN [IndexName] IS NOT NULL THEN 'INDEX'
                  ELSE 'TABLE' END)
            , [ReferenceSource]=CONVERT(varchar(40),CASE
                  WHEN [PhysicalOp] LIKE N'%Update%' OR [PhysicalOp] LIKE N'%Insert%'
                    OR [PhysicalOp] LIKE N'%Delete%' OR [PhysicalOp]=N'Merge'
                    THEN 'DML_TARGET' ELSE 'ACCESS_PATH' END)
            , [DatabaseName],[SchemaName],[ObjectName],[IndexName],[AliasName],[StorageType]
            , [PlanObjectId],[PlanIndexId]
            , [IsTemporaryObject]=CONVERT(bit,CASE WHEN [ObjectName] LIKE N'#%' OR [DatabaseName]=N'tempdb' THEN 1 ELSE 0 END)
            , [IsTableVariable]=CONVERT(bit,CASE WHEN [ObjectName] LIKE N'@%' THEN 1 ELSE 0 END)
            , [IsRemoteObject]=CONVERT(bit,0)
            , [IsDmlTarget]=CONVERT(bit,CASE
                  WHEN [PhysicalOp] LIKE N'%Update%' OR [PhysicalOp] LIKE N'%Insert%'
                    OR [PhysicalOp] LIKE N'%Delete%' OR [PhysicalOp]=N'Merge'
                    THEN 1 ELSE 0 END)
            , [ResolutionCapability]=CONVERT(varchar(40),CASE
                  WHEN [ObjectName] LIKE N'#%' THEN 'TEMP_OBJECT_CONTEXT_REQUIRED'
                  WHEN [ObjectName] LIKE N'@%' THEN 'PLAN_ONLY'
                  WHEN [DatabaseName] IS NULL OR [SchemaName] IS NULL OR [ObjectName] IS NULL THEN 'INCOMPLETE_REFERENCE'
                  ELSE 'CATALOG_RESOLVABLE' END)
            , [SourceElement]=CONVERT(nvarchar(128),N'Object')
        FROM [AccessObjects]
        WHERE [ObjectName] IS NOT NULL

        UNION ALL

        SELECT
              [StatementOrdinal],[StatementId],[StatementCompId],NULL
            , 'TABLE','MISSING_INDEX',[DatabaseName],[SchemaName],[ObjectName]
            , NULL,NULL,NULL,NULL,NULL,0,0,0,0
            , CASE WHEN [DatabaseName] IS NULL OR [SchemaName] IS NULL OR [ObjectName] IS NULL
                   THEN 'INCOMPLETE_REFERENCE' ELSE 'CATALOG_RESOLVABLE' END
            , N'MissingIndex'
        FROM [MissingObjects]
        WHERE [ObjectName] IS NOT NULL
    )
    SELECT
          [ReferenceOrdinal]=CONVERT(bigint,ROW_NUMBER() OVER
            (ORDER BY [StatementOrdinal],COALESCE([NodeId],2147483647),[ReferenceSource],COALESCE([DatabaseName],N''),COALESCE([SchemaName],N''),COALESCE([ObjectName],N''),COALESCE([IndexName],N'')))
        , [StatementOrdinal],[StatementId],[StatementCompId],[NodeId]
        , [ReferenceType],[ReferenceSource],[DatabaseName],[SchemaName],[ObjectName]
        , [IndexName],[AliasName],[StorageType],[PlanObjectId],[PlanIndexId]
        , [IsTemporaryObject],[IsTableVariable],[IsRemoteObject],[IsDmlTarget]
        , [ResolutionCapability],[SourceElement]
    FROM [AllReferences]
);
GO
