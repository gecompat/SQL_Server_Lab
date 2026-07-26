USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.ToolBackgroundQueryPattern
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Steuertabelle
Zweck        : Stellt erweiterbare LIKE-Muster zur diagnostischen Klassifikation
               von Tool-Hintergrundabfragen anhand des clientseitigen
               program_name bereit.
Vertrag      : Kein Sicherheitsmerkmal. Höhere Priority gewinnt; bei gleicher
               Priority entscheidet RuleCode deterministisch.
===============================================================================
*/
IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'monitor'
      AND [t].[name] = N'ToolBackgroundQueryPattern'
)
BEGIN
    CREATE TABLE [monitor].[ToolBackgroundQueryPattern]
    (
          [RuleCode] varchar(64) NOT NULL
        , [Priority] smallint NOT NULL
        , [IsEnabled] bit NOT NULL
            CONSTRAINT [DF_ToolBackgroundQueryPattern_IsEnabled] DEFAULT (1)
        , [ProgramNameLikePattern] nvarchar(256) COLLATE Latin1_General_100_CI_AS NOT NULL
        , [ToolBackgroundCategory] varchar(40) NOT NULL
        , [ToolBackgroundDetection] varchar(40) NOT NULL
        , [ToolBackgroundConfidence] varchar(16) NOT NULL
        , [SourceUrl] nvarchar(1000) NULL
        , [SourceNotes] nvarchar(1000) NULL
        , [IsFrameworkDefault] bit NOT NULL
            CONSTRAINT [DF_ToolBackgroundQueryPattern_IsFrameworkDefault] DEFAULT (0)
        , [LastVerifiedUtc] datetime2(0) NOT NULL
            CONSTRAINT [DF_ToolBackgroundQueryPattern_LastVerifiedUtc] DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_ToolBackgroundQueryPattern]
            PRIMARY KEY CLUSTERED ([RuleCode])
        , CONSTRAINT [CK_ToolBackgroundQueryPattern_Priority]
            CHECK ([Priority] BETWEEN 1 AND 32767)
        , CONSTRAINT [CK_ToolBackgroundQueryPattern_Confidence]
            CHECK ([ToolBackgroundConfidence] IN ('HIGH','MEDIUM','LOW'))
    );
END;
GO
