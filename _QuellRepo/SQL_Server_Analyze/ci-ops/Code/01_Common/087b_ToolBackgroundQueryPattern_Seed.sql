USE [DeineDatenbank];
GO

/* Framework-Seed. Lokale Regeln mit IsFrameworkDefault=0 bleiben erhalten. */
DECLARE @Seed TABLE
(
      [RuleCode] varchar(64) NOT NULL
    , [Priority] smallint NOT NULL
    , [ProgramNameLikePattern] nvarchar(256) COLLATE Latin1_General_100_CI_AS NOT NULL
    , [ToolBackgroundCategory] varchar(40) NOT NULL
    , [ToolBackgroundDetection] varchar(40) NOT NULL
    , [ToolBackgroundConfidence] varchar(16) NOT NULL
    , [SourceUrl] nvarchar(1000) NULL
    , [SourceNotes] nvarchar(1000) NULL
);

INSERT @Seed
(
      [RuleCode], [Priority], [ProgramNameLikePattern]
    , [ToolBackgroundCategory], [ToolBackgroundDetection]
    , [ToolBackgroundConfidence], [SourceUrl], [SourceNotes]
)
VALUES
(
      'SSMS_GITHUB_COPILOT', 1000
    , N'Microsoft SQL Server Management Studio - GitHub Copilot'
    , 'SSMS_GITHUB_COPILOT', 'DOCUMENTED_CLIENT_APP_NAME', 'HIGH'
    , N'https://learn.microsoft.com/en-us/ssms/github-copilot/troubleshoot'
    , N'Der Client-App-Name ist in der Microsoft-Problembehandlung dokumentiert.'
),
(
      'SSMS_COPILOT_COMPLETIONS', 1000
    , N'Microsoft SQL Server Management Studio - Copilot Completions'
    , 'SSMS_COPILOT_COMPLETIONS', 'DOCUMENTED_CLIENT_APP_NAME', 'HIGH'
    , N'https://learn.microsoft.com/en-us/ssms/github-copilot/troubleshoot'
    , N'Der Client-App-Name ist in der Microsoft-Problembehandlung dokumentiert.'
),
(
      'SSMS_OBJECT_EXPLORER', 800
    , N'Microsoft SQL Server Management Studio - Object Explorer%'
    , 'SSMS_OBJECT_EXPLORER', 'PROGRAM_NAME_HEURISTIC', 'MEDIUM'
    , N'https://learn.microsoft.com/en-us/ssms/object/open-and-configure-object-explorer'
    , N'Object Explorer ist dokumentiert; das program_name-Muster bleibt eine versionsabhängige Heuristik.'
),
(
      'RED_GATE_SQL_PROMPT', 700
    , N'Red Gate SQL Prompt%'
    , 'REDGATE_SQL_PROMPT', 'PROGRAM_NAME_HEURISTIC', 'MEDIUM'
    , N'https://documentation.red-gate.com/sp11/managing-sql-prompt-behavior/managing-connections-and-memory'
    , N'SQL Prompt und seine Verbindungen sind dokumentiert; der konkrete program_name ist kein stabiler Herstellervertrag.'
),
(
      'REDGATE_SQL_PROMPT', 700
    , N'Redgate SQL Prompt%'
    , 'REDGATE_SQL_PROMPT', 'PROGRAM_NAME_HEURISTIC', 'MEDIUM'
    , N'https://documentation.red-gate.com/sp11/managing-sql-prompt-behavior/managing-connections-and-memory'
    , N'Alternative beobachtete Herstellerschreibweise.'
),
(
      'REDGATE_DOT_SQLPROMPT', 700
    , N'Redgate.SQLPrompt%'
    , 'REDGATE_SQL_PROMPT', 'PROGRAM_NAME_HEURISTIC', 'MEDIUM'
    , N'https://documentation.red-gate.com/sp11/managing-sql-prompt-behavior/managing-connections-and-memory'
    , N'Alternative beobachtete Herstellerschreibweise.'
);

UPDATE [target]
SET
      [Priority] = [source].[Priority]
    , [ProgramNameLikePattern] = [source].[ProgramNameLikePattern]
    , [ToolBackgroundCategory] = [source].[ToolBackgroundCategory]
    , [ToolBackgroundDetection] = [source].[ToolBackgroundDetection]
    , [ToolBackgroundConfidence] = [source].[ToolBackgroundConfidence]
    , [SourceUrl] = [source].[SourceUrl]
    , [SourceNotes] = [source].[SourceNotes]
    , [IsFrameworkDefault] = 1
    , [LastVerifiedUtc] = SYSUTCDATETIME()
FROM [monitor].[ToolBackgroundQueryPattern] AS [target]
JOIN @Seed AS [source]
  ON [source].[RuleCode] = [target].[RuleCode]
WHERE [target].[IsFrameworkDefault] = 1;

INSERT [monitor].[ToolBackgroundQueryPattern]
(
      [RuleCode], [Priority], [IsEnabled], [ProgramNameLikePattern]
    , [ToolBackgroundCategory], [ToolBackgroundDetection]
    , [ToolBackgroundConfidence], [SourceUrl], [SourceNotes]
    , [IsFrameworkDefault]
)
SELECT
      [source].[RuleCode], [source].[Priority], 1, [source].[ProgramNameLikePattern]
    , [source].[ToolBackgroundCategory], [source].[ToolBackgroundDetection]
    , [source].[ToolBackgroundConfidence], [source].[SourceUrl], [source].[SourceNotes]
    , 1
FROM @Seed AS [source]
WHERE NOT EXISTS
(
    SELECT 1
    FROM [monitor].[ToolBackgroundQueryPattern] AS [target]
    WHERE [target].[RuleCode] = [source].[RuleCode]
);
GO
