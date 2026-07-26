USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.SqlServerBuildCatalog
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Framework-Metadatentabelle und idempotenter Seed
Zweck        : Ermöglicht die offline reproduzierbare Einordnung ausgewählter
               RTM-, CU-, GDR- und CU-GDR-Builds für SQL Server 2019, 2022 und
               2025.
Quelle       : Microsoft SQL Server build versions; Abruf 2026-07-21.
Grenze       : Der Katalog ist kein Online-Patchscanner und kein
               Verwundbarkeits-, Neustart- oder Freigabenachweis.
===============================================================================
*/
IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[t].[schema_id]
    WHERE [s].[name]=N'monitor' AND [t].[name]=N'SqlServerBuildCatalog'
)
BEGIN
    EXEC(N'
CREATE TABLE [monitor].[SqlServerBuildCatalog]
(
      [BuildVersion] varchar(32) NOT NULL
    , [ProductMajorVersion] int NOT NULL
    , [BuildNumber] int NOT NULL
    , [RevisionNumber] int NOT NULL
    , [ReleaseName] nvarchar(64) NOT NULL
    , [ServicingBranch] varchar(16) NOT NULL
    , [KnowledgeBaseNumber] varchar(16) NULL
    , [ReleaseDate] date NOT NULL
    , [PlatformScope] varchar(32) NOT NULL
    , [IsSecurityRelease] bit NOT NULL
    , [IsLatestInBranch] bit NOT NULL
    , [BuildOverviewUrl] nvarchar(512) NOT NULL
    , [KnowledgeBaseUrl] nvarchar(512) NULL
    , [CatalogAsOfDate] date NOT NULL
    , [PrimarySourceUrl] nvarchar(512) NOT NULL
    , [SourceRetrievedAtUtc] datetime2(0) NOT NULL
    , CONSTRAINT [PK_SqlServerBuildCatalog] PRIMARY KEY ([BuildVersion])
    , CONSTRAINT [CK_SqlServerBuildCatalog_Branch]
      CHECK ([ServicingBranch] IN (''RTM'',''CU'',''GDR'',''CU_GDR'',''OD''))
);');
END;
GO

DECLARE @Seed TABLE
(
      [BuildVersion] varchar(32) NOT NULL PRIMARY KEY
    , [ProductMajorVersion] int NOT NULL
    , [BuildNumber] int NOT NULL
    , [RevisionNumber] int NOT NULL
    , [ReleaseName] nvarchar(64) NOT NULL
    , [ServicingBranch] varchar(16) NOT NULL
    , [KnowledgeBaseNumber] varchar(16) NULL
    , [ReleaseDate] date NOT NULL
    , [PlatformScope] varchar(32) NOT NULL
    , [IsSecurityRelease] bit NOT NULL
    , [IsLatestInBranch] bit NOT NULL
    , [BuildOverviewUrl] nvarchar(512) NOT NULL
    , [KnowledgeBaseUrl] nvarchar(512) NULL
    , [CatalogAsOfDate] date NOT NULL
    , [PrimarySourceUrl] nvarchar(512) NOT NULL
    , [SourceRetrievedAtUtc] datetime2(0) NOT NULL
);

INSERT @Seed
VALUES
 ('15.0.2000.5',15,2000,5,N'RTM','RTM',NULL,'2019-11-04','WINDOWS_LINUX',0,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions',NULL,'2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions','2026-07-21T06:30:00')
,('15.0.4430.1',15,4430,1,N'CU32','CU','KB5054833','2025-02-27','WINDOWS_LINUX',0,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions',N'https://support.microsoft.com/help/5054833','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions','2026-07-21T06:30:00')
,('15.0.4480.2',15,4480,2,N'CU32 + GDR','CU_GDR','KB5102335','2026-07-14','WINDOWS_LINUX',1,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions',N'https://support.microsoft.com/help/5102335','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions','2026-07-21T06:30:00')
,('15.0.2180.2',15,2180,2,N'GDR','GDR','KB5102336','2026-07-14','WINDOWS_LINUX',1,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions',N'https://support.microsoft.com/help/5102336','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions','2026-07-21T06:30:00')
,('16.0.1000.6',16,1000,6,N'RTM','RTM',NULL,'2022-11-16','WINDOWS_LINUX',0,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions',NULL,'2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions','2026-07-21T06:30:00')
,('16.0.4265.3',16,4265,3,N'CU26','CU','KB5093420','2026-07-16','WINDOWS_LINUX',0,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions',N'https://support.microsoft.com/help/5093420','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions','2026-07-21T06:30:00')
,('16.0.4262.2',16,4262,2,N'CU25 + GDR','CU_GDR','KB5101347','2026-07-14','WINDOWS_LINUX',1,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions',N'https://support.microsoft.com/help/5101347','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions','2026-07-21T06:30:00')
,('16.0.1190.2',16,1190,2,N'GDR','GDR','KB5102334','2026-07-14','WINDOWS_LINUX',1,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions',N'https://support.microsoft.com/help/5102334','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions','2026-07-21T06:30:00')
,('17.0.1000.7',17,1000,7,N'RTM','RTM',NULL,'2025-11-18','WINDOWS_LINUX',0,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions',NULL,'2026-07-21',N'https://learn.microsoft.com/en-us/sql/sql-server/sql-server-2025-release-notes','2026-07-21T06:30:00')
,('17.0.4065.4',17,4065,4,N'CU7','CU','KB5096981','2026-07-16','WINDOWS_LINUX',0,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions',N'https://support.microsoft.com/help/5096981','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions','2026-07-21T06:30:00')
,('17.0.4060.2',17,4060,2,N'CU6 + GDR','CU_GDR','KB5101346','2026-07-14','WINDOWS_LINUX',1,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions',N'https://support.microsoft.com/help/5101346','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions','2026-07-21T06:30:00')
,('17.0.1125.2',17,1125,2,N'GDR','GDR','KB5102333','2026-07-14','WINDOWS_LINUX',1,1,N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions',N'https://support.microsoft.com/help/5102333','2026-07-21',N'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions','2026-07-21T06:30:00');

UPDATE [target]
SET [ProductMajorVersion]=[source].[ProductMajorVersion],
    [BuildNumber]=[source].[BuildNumber],
    [RevisionNumber]=[source].[RevisionNumber],
    [ReleaseName]=[source].[ReleaseName],
    [ServicingBranch]=[source].[ServicingBranch],
    [KnowledgeBaseNumber]=[source].[KnowledgeBaseNumber],
    [ReleaseDate]=[source].[ReleaseDate],
    [PlatformScope]=[source].[PlatformScope],
    [IsSecurityRelease]=[source].[IsSecurityRelease],
    [IsLatestInBranch]=[source].[IsLatestInBranch],
    [BuildOverviewUrl]=[source].[BuildOverviewUrl],
    [KnowledgeBaseUrl]=[source].[KnowledgeBaseUrl],
    [CatalogAsOfDate]=[source].[CatalogAsOfDate],
    [PrimarySourceUrl]=[source].[PrimarySourceUrl],
    [SourceRetrievedAtUtc]=[source].[SourceRetrievedAtUtc]
FROM [monitor].[SqlServerBuildCatalog] AS [target]
JOIN @Seed AS [source] ON [source].[BuildVersion]=[target].[BuildVersion];

INSERT [monitor].[SqlServerBuildCatalog]
SELECT [source].*
FROM @Seed AS [source]
WHERE NOT EXISTS
(
    SELECT 1 FROM [monitor].[SqlServerBuildCatalog] AS [target]
    WHERE [target].[BuildVersion]=[source].[BuildVersion]
);
GO
