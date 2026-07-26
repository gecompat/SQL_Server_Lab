USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : [monitor].[WaitTypeCatalog]
Version      : 2.2.0
Stand        : 2026-07-20
Zweck        : Stellt einen persistenten, erweiterbaren Wait-Katalog mit
               geprüftem Framework-Seed, analytischer Vertiefung und
               typisierten Quellen bereit.
Hinweis      : FRAMEWORK_CURATED kennzeichnet die belegte Namens- und Textprüfung.
               SQLskills-Inhalte werden nicht kopiert, sondern ausschließlich als
               optionale HelpUrl verlinkt.
===============================================================================
*/
IF NOT EXISTS
(
 SELECT 1
 FROM [sys].[tables] AS [t] WITH (NOLOCK)
 JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
 WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog'
)
BEGIN
 CREATE TABLE [monitor].[WaitTypeCatalog]
 (
  [WaitType] nvarchar(120) NOT NULL CONSTRAINT PK_WaitTypeCatalog PRIMARY KEY CLUSTERED,
  [WaitGroup] nvarchar(64) NOT NULL,[Severity] tinyint NOT NULL CONSTRAINT DF_WaitTypeCatalog_Severity DEFAULT(1),
  [IsGenerallyBenign] bit NOT NULL CONSTRAINT DF_WaitTypeCatalog_Benign DEFAULT(0),[Meaning] nvarchar(1000) NOT NULL,
  [TypicalOccurrence] nvarchar(1200) NOT NULL,[HighWaitImpact] nvarchar(1200) NOT NULL,[RecommendedChecks] nvarchar(1500) NOT NULL,
  [DefaultAssessment] varchar(30) NOT NULL CONSTRAINT DF_WaitTypeCatalog_Assessment DEFAULT('CONTEXT_DEPENDENT'),
  [AssessmentBasis] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_AssessmentBasis DEFAULT(N'Nur im Delta-, Aktivitäts- und Workloadkontext bewerten.'),
  [CommonCauses] nvarchar(2000) NOT NULL CONSTRAINT DF_WaitTypeCatalog_CommonCauses DEFAULT(N'Komponenten- und workloadabhängige Ursachen.'),
  [PerformanceImpact] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_PerformanceImpact DEFAULT(N'Kein Wirkungsnachweis ohne aktive oder zeitlich korrelierte Wartezeit.'),
  [Mitigation] nvarchar(2000) NOT NULL CONSTRAINT DF_WaitTypeCatalog_Mitigation DEFAULT(N'Nicht den Wait Type unterdrücken, sondern die bestätigte Ursache beheben.'),
  [CounterEvidence] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_CounterEvidence DEFAULT(N'Fehlende aktive Tasks oder ein nicht reproduzierbares Delta sprechen gegen einen aktuellen Engpass.'),
  [RelatedWaitTypes] nvarchar(1000) NULL,
  [MeasurementGuidance] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_MeasurementGuidance DEFAULT(N'Aktive Tasks und ein belastungsbezogenes Delta gemeinsam bewerten; kumulative Werte seit Start oder Reset sind allein kein Befund.'),
  [AnalysisConfidence] varchar(30) NOT NULL CONSTRAINT DF_WaitTypeCatalog_AnalysisConfidence DEFAULT('FAMILY_INFERENCE'),
  [HelpUrl] nvarchar(500) NULL,[MinProductMajorVersion] int NULL,[DescriptionSource] varchar(40) NULL,
  [DescriptionQuality] varchar(40) NULL,[SourceReference] nvarchar(500) NULL,
  [IsFrameworkDefault] bit NOT NULL CONSTRAINT DF_WaitTypeCatalog_Default DEFAULT(1),
  [LastUpdatedUtc] datetime2(0) NOT NULL CONSTRAINT DF_WaitTypeCatalog_Updated DEFAULT(SYSUTCDATETIME()),
  CONSTRAINT CK_WaitTypeCatalog_Severity CHECK([Severity] BETWEEN 0 AND 5)
 );
END;
GO
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'DescriptionSource') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [DescriptionSource] varchar(40) NULL;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'DescriptionQuality') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [DescriptionQuality] varchar(40) NULL;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'SourceReference') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [SourceReference] nvarchar(500) NULL;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'DefaultAssessment') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [DefaultAssessment] varchar(30) NOT NULL CONSTRAINT DF_WaitTypeCatalog_Assessment DEFAULT('CONTEXT_DEPENDENT') WITH VALUES;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'AssessmentBasis') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [AssessmentBasis] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_AssessmentBasis DEFAULT(N'Nur im Delta-, Aktivitäts- und Workloadkontext bewerten.') WITH VALUES;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'CommonCauses') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [CommonCauses] nvarchar(2000) NOT NULL CONSTRAINT DF_WaitTypeCatalog_CommonCauses DEFAULT(N'Komponenten- und workloadabhängige Ursachen.') WITH VALUES;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'PerformanceImpact') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [PerformanceImpact] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_PerformanceImpact DEFAULT(N'Kein Wirkungsnachweis ohne aktive oder zeitlich korrelierte Wartezeit.') WITH VALUES;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'Mitigation') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [Mitigation] nvarchar(2000) NOT NULL CONSTRAINT DF_WaitTypeCatalog_Mitigation DEFAULT(N'Nicht den Wait Type unterdrücken, sondern die bestätigte Ursache beheben.') WITH VALUES;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'CounterEvidence') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [CounterEvidence] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_CounterEvidence DEFAULT(N'Fehlende aktive Tasks oder ein nicht reproduzierbares Delta sprechen gegen einen aktuellen Engpass.') WITH VALUES;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'RelatedWaitTypes') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [RelatedWaitTypes] nvarchar(1000) NULL;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'MeasurementGuidance') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [MeasurementGuidance] nvarchar(1500) NOT NULL CONSTRAINT DF_WaitTypeCatalog_MeasurementGuidance DEFAULT(N'Aktive Tasks und ein belastungsbezogenes Delta gemeinsam bewerten; kumulative Werte seit Start oder Reset sind allein kein Befund.') WITH VALUES;
IF NOT EXISTS(SELECT 1 FROM [sys].[columns] AS [c] WITH (NOLOCK) JOIN [sys].[tables] AS [t] WITH (NOLOCK) ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalog' AND [c].[name]=N'AnalysisConfidence') ALTER TABLE [monitor].[WaitTypeCatalog] ADD [AnalysisConfidence] varchar(30) NOT NULL CONSTRAINT DF_WaitTypeCatalog_AnalysisConfidence DEFAULT('FAMILY_INFERENCE') WITH VALUES;
GO

IF NOT EXISTS
(
 SELECT 1
 FROM [sys].[tables] AS [t] WITH (NOLOCK)
 JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
 WHERE [s].[name]=N'monitor' AND [t].[name]=N'WaitTypeCatalogSource'
)
BEGIN
 CREATE TABLE [monitor].[WaitTypeCatalogSource]
 (
  [WaitType] nvarchar(120) NOT NULL,
  [SourceOrdinal] tinyint NOT NULL,
  [SourceType] varchar(30) NOT NULL,
  [Publisher] nvarchar(120) NOT NULL,
  [SourceTitle] nvarchar(400) NOT NULL,
  [SourceUrl] nvarchar(1000) NOT NULL,
  [SupportsFields] nvarchar(500) NOT NULL,
  [EvidenceLevel] varchar(30) NOT NULL,
  [SourceNotes] nvarchar(1000) NULL,
  [IsFrameworkDefault] bit NOT NULL CONSTRAINT DF_WaitTypeCatalogSource_Default DEFAULT(1),
  [LastVerifiedUtc] datetime2(0) NOT NULL CONSTRAINT DF_WaitTypeCatalogSource_Verified DEFAULT(SYSUTCDATETIME()),
  CONSTRAINT PK_WaitTypeCatalogSource PRIMARY KEY CLUSTERED([WaitType],[SourceOrdinal]),
  CONSTRAINT FK_WaitTypeCatalogSource_WaitType FOREIGN KEY([WaitType]) REFERENCES [monitor].[WaitTypeCatalog]([WaitType]),
  CONSTRAINT CK_WaitTypeCatalogSource_Ordinal CHECK([SourceOrdinal] BETWEEN 1 AND 20)
 );
END;
GO
