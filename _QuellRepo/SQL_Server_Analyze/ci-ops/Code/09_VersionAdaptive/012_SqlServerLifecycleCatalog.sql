USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.SqlServerLifecycleCatalog
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Framework-Metadatentabelle und idempotenter Seed
Quelle       : Microsoft Lifecycle, Abruf 2026-07-21.
===============================================================================
*/
IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[t].[schema_id]
    WHERE [s].[name]=N'monitor' AND [t].[name]=N'SqlServerLifecycleCatalog'
)
BEGIN
    EXEC(N'
CREATE TABLE [monitor].[SqlServerLifecycleCatalog]
(
      [ProductMajorVersion] int NOT NULL
    , [ProductName] nvarchar(64) NOT NULL
    , [StartDate] date NOT NULL
    , [MainstreamEndDate] date NOT NULL
    , [ExtendedEndDate] date NOT NULL
    , [LifecyclePolicy] varchar(32) NOT NULL
    , [LifecycleUrl] nvarchar(512) NOT NULL
    , [CatalogAsOfDate] date NOT NULL
    , [SourceRetrievedAtUtc] datetime2(0) NOT NULL
    , CONSTRAINT [PK_SqlServerLifecycleCatalog] PRIMARY KEY ([ProductMajorVersion])
);');
END;
GO

DECLARE @Seed TABLE
(
      [ProductMajorVersion] int NOT NULL PRIMARY KEY
    , [ProductName] nvarchar(64) NOT NULL
    , [StartDate] date NOT NULL
    , [MainstreamEndDate] date NOT NULL
    , [ExtendedEndDate] date NOT NULL
    , [LifecyclePolicy] varchar(32) NOT NULL
    , [LifecycleUrl] nvarchar(512) NOT NULL
    , [CatalogAsOfDate] date NOT NULL
    , [SourceRetrievedAtUtc] datetime2(0) NOT NULL
);

INSERT @Seed VALUES
 (15,N'SQL Server 2019','2019-11-04','2025-02-28','2030-01-08','FIXED',N'https://learn.microsoft.com/en-us/lifecycle/products/sql-server-2019','2026-07-21','2026-07-21T06:30:00')
,(16,N'SQL Server 2022','2022-11-16','2028-01-11','2033-01-11','FIXED',N'https://learn.microsoft.com/en-us/lifecycle/products/sql-server-2022','2026-07-21','2026-07-21T06:30:00')
,(17,N'SQL Server 2025','2025-11-18','2031-01-06','2036-01-06','FIXED',N'https://learn.microsoft.com/en-us/lifecycle/products/sql-server-2025','2026-07-21','2026-07-21T06:30:00');

UPDATE [target]
SET [ProductName]=[source].[ProductName],
    [StartDate]=[source].[StartDate],
    [MainstreamEndDate]=[source].[MainstreamEndDate],
    [ExtendedEndDate]=[source].[ExtendedEndDate],
    [LifecyclePolicy]=[source].[LifecyclePolicy],
    [LifecycleUrl]=[source].[LifecycleUrl],
    [CatalogAsOfDate]=[source].[CatalogAsOfDate],
    [SourceRetrievedAtUtc]=[source].[SourceRetrievedAtUtc]
FROM [monitor].[SqlServerLifecycleCatalog] AS [target]
JOIN @Seed AS [source]
  ON [source].[ProductMajorVersion]=[target].[ProductMajorVersion];

INSERT [monitor].[SqlServerLifecycleCatalog]
SELECT [source].*
FROM @Seed AS [source]
WHERE NOT EXISTS
(
    SELECT 1 FROM [monitor].[SqlServerLifecycleCatalog] AS [target]
    WHERE [target].[ProductMajorVersion]=[source].[ProductMajorVersion]
);
GO
