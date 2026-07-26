USE [DeineDatenbank];
GO

/* Quellen und Aussagezweck eines Wait Types. Unbekannte Waits erhalten einen
   transparenten generischen Quellenfallback, aber keine erfundene Detailquelle. */
CREATE OR ALTER FUNCTION [monitor].[TVF_WaitTypeSources]
(
 @WaitType nvarchar(120)
)
RETURNS TABLE
AS
RETURN
(
    SELECT
          [s].[WaitType]
        , [s].[SourceOrdinal]
        , [s].[SourceType]
        , [s].[Publisher]
        , [s].[SourceTitle]
        , [s].[SourceUrl]
        , [s].[SupportsFields]
        , [s].[EvidenceLevel]
        , [s].[SourceNotes]
        , CONVERT(varchar(20),'EXACT') AS [CatalogMatchType]
        , [s].[LastVerifiedUtc]
    FROM [monitor].[WaitTypeCatalogSource] AS [s] WITH (NOLOCK)
    WHERE [s].[WaitType]=@WaitType

    UNION ALL

    SELECT
          @WaitType
        , [f].[SourceOrdinal]
        , [f].[SourceType]
        , [f].[Publisher]
        , [f].[SourceTitle]
        , [f].[SourceUrl]
        , [f].[SupportsFields]
        , [f].[EvidenceLevel]
        , [f].[SourceNotes]
        , CONVERT(varchar(20),'GENERIC_FALLBACK')
        , CONVERT(datetime2(0),NULL)
    FROM
    (
        VALUES
          (CONVERT(tinyint,1),'DEFINITION',N'Microsoft',
           N'sys.dm_os_wait_stats – Types of Waits',
           N'https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-wait-stats-transact-sql?view=sql-server-ver17',
           N'WaitType, Meaning, Versionshinweise','PRIMARY_VENDOR',
           N'Generische Definitionsquelle; ein fehlender exakter Katalogeintrag bleibt fachlich zu recherchieren.'),
          (CONVERT(tinyint,2),'MEASUREMENT',N'Microsoft',
           N'Troubleshoot slow-running queries – diagnose waits or bottlenecks',
           N'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-slow-running-queries',
           N'AssessmentBasis, MeasurementGuidance, CounterEvidence','PRIMARY_VENDOR',
           N'Allgemeine Messmethodik, keine wait-spezifische Ursachenbehauptung.'),
          (CONVERT(tinyint,3),'INTERPRETATION',N'SQLskills',
           CONCAT(N'SQL Server Wait Types Library: ',@WaitType),
           CONCAT(N'https://www.sqlskills.com/help/waits/',@WaitType),
           N'TypicalOccurrence, AssessmentBasis, RelatedWaitTypes','SPECIALIST_REFERENCE',
           N'Externe Spezialistenreferenz; Inhalt wird nicht in das Repository kopiert.')
    ) AS [f]
    (
      [SourceOrdinal],[SourceType],[Publisher],[SourceTitle],[SourceUrl],
      [SupportsFields],[EvidenceLevel],[SourceNotes]
    )
    WHERE @WaitType IS NOT NULL
      AND NOT EXISTS
          (
            SELECT 1
            FROM [monitor].[WaitTypeCatalogSource] AS [x] WITH (NOLOCK)
            WHERE [x].[WaitType]=@WaitType
          )
);
GO
