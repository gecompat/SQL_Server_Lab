USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.PlanAnalysisProfileAssignment
Version      : 1.0.0
Stand        : 2026-07-21
Typ          : Steuertabelle
Zweck        : Ordnet Plan- und Workloadkontext optional einem generischen
               lokalen Analyseprofil zu. Die Auslieferung enthält keine realen
               Zuordnungen und überschreibt keine lokalen Zeilen.
===============================================================================
*/
IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[t].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [t].[name]=N'PlanAnalysisProfileAssignment'
)
BEGIN
    CREATE TABLE [monitor].[PlanAnalysisProfileAssignment]
    (
          [AssignmentId]          bigint        IDENTITY(1,1) NOT NULL
        , [Priority]              smallint      NOT NULL
        , [IsEnabled]             bit           NOT NULL
            CONSTRAINT [DF_PlanAnalysisProfileAssignment_IsEnabled] DEFAULT (1)
        , [ProfileCode]           varchar(32)   NOT NULL
        , [DatabaseNamePattern]   nvarchar(256) NULL
        , [SchemaNamePattern]     nvarchar(256) NULL
        , [ObjectNamePattern]     nvarchar(256) NULL
        , [QueryHash]             binary(8)     NULL
        , [QueryStoreQueryId]     bigint        NULL
        , [StatementId]           int           NULL
        , [ProgramNameLikePattern] nvarchar(256) NULL
        , [ResourcePoolId]        int           NULL
        , [WorkloadGroupId]       int           NULL
        , [IsFrameworkDefault]    bit           NOT NULL
            CONSTRAINT [DF_PlanAnalysisProfileAssignment_IsFrameworkDefault] DEFAULT (0)
        , [Comment]               nvarchar(1000) NULL
        , [LastUpdatedUtc]        datetime2(0)   NOT NULL
            CONSTRAINT [DF_PlanAnalysisProfileAssignment_LastUpdatedUtc] DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_PlanAnalysisProfileAssignment]
            PRIMARY KEY CLUSTERED ([AssignmentId])
        , CONSTRAINT [FK_PlanAnalysisProfileAssignment_Profile]
            FOREIGN KEY ([ProfileCode])
            REFERENCES [monitor].[PlanAnalysisProfile]([ProfileCode])
        , CONSTRAINT [CK_PlanAnalysisProfileAssignment_Priority]
            CHECK ([Priority] BETWEEN 1 AND 32767)
        , CONSTRAINT [CK_PlanAnalysisProfileAssignment_Scope]
            CHECK
            (
                   [DatabaseNamePattern] IS NOT NULL
                OR [SchemaNamePattern] IS NOT NULL
                OR [ObjectNamePattern] IS NOT NULL
                OR [QueryHash] IS NOT NULL
                OR [QueryStoreQueryId] IS NOT NULL
                OR [StatementId] IS NOT NULL
                OR [ProgramNameLikePattern] IS NOT NULL
                OR [ResourcePoolId] IS NOT NULL
                OR [WorkloadGroupId] IS NOT NULL
            )
    );

    CREATE INDEX [IX_PlanAnalysisProfileAssignment_Resolution]
        ON [monitor].[PlanAnalysisProfileAssignment]
        ([IsEnabled],[Priority],[ProfileCode])
        INCLUDE
        (
              [DatabaseNamePattern],[SchemaNamePattern],[ObjectNamePattern]
            , [QueryHash],[QueryStoreQueryId],[StatementId]
            , [ProgramNameLikePattern],[ResourcePoolId],[WorkloadGroupId]
        );
END;
GO
