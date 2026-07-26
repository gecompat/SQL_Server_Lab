USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.PlanAnalysisProfile
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Steuertabelle
Zweck        : Definiert generische Workloadprofile für die eigenständige und
               frameworkintegrierte Execution-Plan-Analyse.
Datenschutz  : Enthält ausschließlich generische Frameworkwerte. Lokale reale
               Zuordnungen werden nicht als Repositoryseed ausgeliefert.
===============================================================================
*/
IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[t].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [t].[name]=N'PlanAnalysisProfile'
)
BEGIN
    CREATE TABLE [monitor].[PlanAnalysisProfile]
    (
          [ProfileCode]        varchar(32)    NOT NULL
        , [Description]        nvarchar(1000) NOT NULL
        , [Priority]           smallint       NOT NULL
        , [IsEnabled]          bit            NOT NULL
            CONSTRAINT [DF_PlanAnalysisProfile_IsEnabled] DEFAULT (1)
        , [IsFrameworkDefault] bit            NOT NULL
            CONSTRAINT [DF_PlanAnalysisProfile_IsFrameworkDefault] DEFAULT (0)
        , [SeedVersion]        int            NOT NULL
            CONSTRAINT [DF_PlanAnalysisProfile_SeedVersion] DEFAULT (0)
        , [LastUpdatedUtc]     datetime2(0)   NOT NULL
            CONSTRAINT [DF_PlanAnalysisProfile_LastUpdatedUtc] DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_PlanAnalysisProfile]
            PRIMARY KEY CLUSTERED ([ProfileCode])
        , CONSTRAINT [CK_PlanAnalysisProfile_Priority]
            CHECK ([Priority] BETWEEN 1 AND 32767)
    );
END;
GO

DECLARE @SeedVersion int=1;
DECLARE @Defaults TABLE
(
      [ProfileCode] varchar(32) NOT NULL PRIMARY KEY
    , [Description] nvarchar(1000) NOT NULL
    , [Priority] smallint NOT NULL
);

INSERT @Defaults([ProfileCode],[Description],[Priority])
VALUES
  ('LATENCY_SENSITIVE',N'Interaktive oder hochfrequente Zugriffe; je Ausführung und Wiederholungsrate werden stärker gewichtet.',100),
  ('BALANCED',N'Neutraler Frameworkstandard für gemischte Workloads ohne belastbare explizite Zuordnung.',200),
  ('THROUGHPUT',N'Mengen- und Durchsatzverarbeitung; absolute CPU-, I/O-, TempDB- und Datenmengen werden stärker gewichtet.',300),
  ('MAINTENANCE',N'Wartungs- und strukturverändernde Verarbeitung; große Scans und Sorts können fachlich erwartet sein.',400),
  ('UNKNOWN',N'Workloadprofil nicht belastbar bestimmbar; Findings bleiben konservativ und weisen die geringe Zuordnungssicherheit aus.',500);

UPDATE [p]
SET
      [p].[Description]=[d].[Description]
    , [p].[Priority]=[d].[Priority]
    , [p].[IsEnabled]=1
    , [p].[SeedVersion]=@SeedVersion
    , [p].[LastUpdatedUtc]=SYSUTCDATETIME()
FROM [monitor].[PlanAnalysisProfile] AS [p]
JOIN @Defaults AS [d]
  ON [d].[ProfileCode]=[p].[ProfileCode]
WHERE [p].[IsFrameworkDefault]=1
  AND [p].[SeedVersion]<@SeedVersion;

INSERT [monitor].[PlanAnalysisProfile]
(
      [ProfileCode],[Description],[Priority],[IsEnabled]
    , [IsFrameworkDefault],[SeedVersion]
)
SELECT [d].[ProfileCode],[d].[Description],[d].[Priority],1,1,@SeedVersion
FROM @Defaults AS [d]
WHERE NOT EXISTS
(
    SELECT 1
    FROM [monitor].[PlanAnalysisProfile] AS [p]
    WHERE [p].[ProfileCode]=[d].[ProfileCode]
);
GO
