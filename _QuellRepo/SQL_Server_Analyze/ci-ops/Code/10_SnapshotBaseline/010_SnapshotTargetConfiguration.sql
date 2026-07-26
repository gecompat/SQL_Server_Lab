USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.SnapshotTargetConfiguration
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Definiert die typisierte Singleton-Konfiguration des optionalen
               SC-023-Pakets.
Datenschutz  : Die Tabelle liegt nur im Zielsystem. Repository-Seeds enthalten
               ausschließlich den generischen, deaktivierten Defaultnamen.
===============================================================================
*/
IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id]=[t].[schema_id]
    WHERE [s].[name]=N'monitor'
      AND [t].[name]=N'SnapshotTargetConfiguration'
)
BEGIN
    CREATE TABLE [monitor].[SnapshotTargetConfiguration]
    (
          [ConfigurationId] tinyint NOT NULL
        , [TargetDatabaseName] sysname NOT NULL
        , [IsEnabled] bit NOT NULL
            CONSTRAINT [DF_SnapshotTargetConfiguration_IsEnabled] DEFAULT (0)
        , [DefaultSchedulerType] varchar(16) NOT NULL
            CONSTRAINT [DF_SnapshotTargetConfiguration_DefaultSchedulerType] DEFAULT ('EXTERNAL')
        , [PackageContractVersion] int NOT NULL
            CONSTRAINT [DF_SnapshotTargetConfiguration_PackageContractVersion] DEFAULT (1)
        , [SeedVersion] int NOT NULL
            CONSTRAINT [DF_SnapshotTargetConfiguration_SeedVersion] DEFAULT (0)
        , [LastUpdatedUtc] datetime2(3) NOT NULL
            CONSTRAINT [DF_SnapshotTargetConfiguration_LastUpdatedUtc] DEFAULT (SYSUTCDATETIME())
        , [RowVersion] rowversion NOT NULL
        , CONSTRAINT [PK_SnapshotTargetConfiguration]
            PRIMARY KEY CLUSTERED ([ConfigurationId])
        , CONSTRAINT [CK_SnapshotTargetConfiguration_Singleton]
            CHECK ([ConfigurationId]=1)
        , CONSTRAINT [CK_SnapshotTargetConfiguration_Scheduler]
            CHECK ([DefaultSchedulerType] IN ('MANUAL','EXTERNAL','SQL_AGENT'))
        , CONSTRAINT [CK_SnapshotTargetConfiguration_Contract]
            CHECK ([PackageContractVersion]>=1)
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[SnapshotTargetConfiguration]
    WHERE [ConfigurationId]=1
)
BEGIN
    INSERT [monitor].[SnapshotTargetConfiguration]
    (
          [ConfigurationId]
        , [TargetDatabaseName]
        , [IsEnabled]
        , [DefaultSchedulerType]
        , [PackageContractVersion]
        , [SeedVersion]
    )
    VALUES
    (1,N'SQL_Server_Analyze_History',0,'EXTERNAL',1,1);
END;
GO
