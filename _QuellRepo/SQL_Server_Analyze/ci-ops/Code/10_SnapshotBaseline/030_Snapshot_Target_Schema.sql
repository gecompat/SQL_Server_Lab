/*
===============================================================================
Datei        : 030_Snapshot_Target_Schema.sql
Version      : 1.0.0
Stand        : 2026-07-21
Zweck        : Erstellt das versionierte Basisschema des optionalen SC-023-
               Snapshot-/Baseline-Ziels in der aktuell verbundenen Datenbank.
Voraussetzung: Die Verbindung zeigt auf eine beschreibbare Nicht-Systemdatenbank.
Datenschutz  : Die Tabellen dürfen im autorisierten Betrieb vollständige reale
               Laufzeitevidenz speichern. Dieses Installationsskript enthält
               ausschließlich generische Seeds und keine Laufzeitwerte.
Locking      : Katalogprüfungen erfolgen direkt über sys.* WITH (NOLOCK) unter
               LOCK_TIMEOUT 0. DDL wartet nicht auf fremde Metadatensperren.
Rechte       : Das Skript erstellt keine Logins, Benutzer, Rollen oder GRANTs.
===============================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 0;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;

DECLARE
      @SnapshotTargetDatabaseId int = NULL
    , @SnapshotTargetDatabaseName sysname = NULL
    , @SnapshotTargetState tinyint = NULL
    , @SnapshotTargetIsReadOnly bit = NULL;

SELECT TOP (1)
       @SnapshotTargetDatabaseId = [r].[database_id]
FROM [sys].[dm_exec_requests] AS [r] WITH (NOLOCK)
WHERE [r].[session_id] = @@SPID;

SELECT
      @SnapshotTargetDatabaseName = [d].[name]
    , @SnapshotTargetState = [d].[state]
    , @SnapshotTargetIsReadOnly = [d].[is_read_only]
FROM [sys].[databases] AS [d] WITH (NOLOCK)
WHERE [d].[database_id] = @SnapshotTargetDatabaseId;

IF @SnapshotTargetDatabaseId IS NULL
   OR @SnapshotTargetDatabaseName IS NULL
    THROW 51030, N'Die aktuell verbundene Zieldatenbank konnte nicht sicher aufgelöst werden.', 1;

IF @SnapshotTargetDatabaseId <= 4
    THROW 51031, N'Das SC-023-Zielschema darf nicht in einer SQL-Server-Systemdatenbank installiert werden.', 1;

IF @SnapshotTargetState <> 0 OR @SnapshotTargetIsReadOnly <> 0
    THROW 51032, N'Die SC-023-Zieldatenbank muss ONLINE und beschreibbar sein.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[schemas] AS [s] WITH (NOLOCK)
    WHERE [s].[name] = N'snapshot'
)
BEGIN
    EXEC [sys].[sp_executesql]
         N'CREATE SCHEMA [snapshot] AUTHORIZATION [dbo];';
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'PackageVersion'
)
BEGIN
    CREATE TABLE [snapshot].[PackageVersion]
    (
          [PackageCode] varchar(32) NOT NULL
        , [PackageVersion] varchar(16) NOT NULL
        , [SchemaVersion] int NOT NULL
        , [InstalledAtUtc] datetime2(3) NOT NULL
              CONSTRAINT [DF_snapshot_PackageVersion_InstalledAtUtc]
              DEFAULT (SYSUTCDATETIME())
        , [LastInstallerRunUtc] datetime2(3) NOT NULL
              CONSTRAINT [DF_snapshot_PackageVersion_LastInstallerRunUtc]
              DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_snapshot_PackageVersion]
              PRIMARY KEY CLUSTERED ([PackageCode])
        , CONSTRAINT [CK_snapshot_PackageVersion_PackageCode]
              CHECK ([PackageCode] = 'SC-023')
        , CONSTRAINT [CK_snapshot_PackageVersion_SchemaVersion]
              CHECK ([SchemaVersion] > 0)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'RetentionPolicy'
)
BEGIN
    CREATE TABLE [snapshot].[RetentionPolicy]
    (
          [RetentionPolicyCode] varchar(64) NOT NULL
        , [RawRetentionDays] smallint NOT NULL
        , [PayloadRetentionDays] smallint NOT NULL
        , [RollupRetentionDays] smallint NOT NULL
        , [SoftBudgetMB] bigint NOT NULL
        , [PurgeIntervalMinutes] int NOT NULL
        , [PurgeBatchRows] int NOT NULL
        , [BudgetAction] varchar(40) NOT NULL
        , [IsFrameworkDefault] bit NOT NULL
              CONSTRAINT [DF_snapshot_RetentionPolicy_IsFrameworkDefault]
              DEFAULT (0)
        , [SeedVersion] int NOT NULL
        , [LastUpdatedUtc] datetime2(3) NOT NULL
              CONSTRAINT [DF_snapshot_RetentionPolicy_LastUpdatedUtc]
              DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_snapshot_RetentionPolicy]
              PRIMARY KEY CLUSTERED ([RetentionPolicyCode])
        , CONSTRAINT [CK_snapshot_RetentionPolicy_RawRetentionDays]
              CHECK ([RawRetentionDays] BETWEEN 1 AND 36500)
        , CONSTRAINT [CK_snapshot_RetentionPolicy_PayloadRetentionDays]
              CHECK ([PayloadRetentionDays] BETWEEN 1 AND 36500)
        , CONSTRAINT [CK_snapshot_RetentionPolicy_RollupRetentionDays]
              CHECK ([RollupRetentionDays] BETWEEN 1 AND 36500)
        , CONSTRAINT [CK_snapshot_RetentionPolicy_SoftBudgetMB]
              CHECK ([SoftBudgetMB] > 0)
        , CONSTRAINT [CK_snapshot_RetentionPolicy_PurgeIntervalMinutes]
              CHECK ([PurgeIntervalMinutes] BETWEEN 1 AND 10080)
        , CONSTRAINT [CK_snapshot_RetentionPolicy_PurgeBatchRows]
              CHECK ([PurgeBatchRows] BETWEEN 1 AND 100000)
        , CONSTRAINT [CK_snapshot_RetentionPolicy_BudgetAction]
              CHECK ([BudgetAction] = 'PURGE_EXPIRED_THEN_STOP')
        , CONSTRAINT [CK_snapshot_RetentionPolicy_SeedVersion]
              CHECK ([SeedVersion] > 0)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'CollectorPolicy'
)
BEGIN
    CREATE TABLE [snapshot].[CollectorPolicy]
    (
          [CollectorCode] varchar(64) NOT NULL
        , [IsEnabled] bit NOT NULL
              CONSTRAINT [DF_snapshot_CollectorPolicy_IsEnabled] DEFAULT (1)
        , [CollectionIntervalSeconds] int NOT NULL
        , [MaxRows] int NOT NULL
        , [PayloadEnabled] bit NOT NULL
        , [RetentionPolicyCode] varchar(64) NOT NULL
        , [IsFrameworkDefault] bit NOT NULL
              CONSTRAINT [DF_snapshot_CollectorPolicy_IsFrameworkDefault]
              DEFAULT (0)
        , [SeedVersion] int NOT NULL
        , [LastUpdatedUtc] datetime2(3) NOT NULL
              CONSTRAINT [DF_snapshot_CollectorPolicy_LastUpdatedUtc]
              DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_snapshot_CollectorPolicy]
              PRIMARY KEY CLUSTERED ([CollectorCode])
        , CONSTRAINT [FK_snapshot_CollectorPolicy_RetentionPolicy]
              FOREIGN KEY ([RetentionPolicyCode])
              REFERENCES [snapshot].[RetentionPolicy]([RetentionPolicyCode])
        , CONSTRAINT [CK_snapshot_CollectorPolicy_CollectorCode]
              CHECK ([CollectorCode] = 'PERFORMANCE_COUNTERS')
        , CONSTRAINT [CK_snapshot_CollectorPolicy_CollectionIntervalSeconds]
              CHECK ([CollectionIntervalSeconds] BETWEEN 1 AND 3600)
        , CONSTRAINT [CK_snapshot_CollectorPolicy_MaxRows]
              CHECK ([MaxRows] BETWEEN 1 AND 100000)
        , CONSTRAINT [CK_snapshot_CollectorPolicy_SeedVersion]
              CHECK ([SeedVersion] > 0)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'CaptureRun'
)
BEGIN
    CREATE TABLE [snapshot].[CaptureRun]
    (
          [CaptureRunId] bigint IDENTITY(1,1) NOT NULL
        , [CollectorCode] varchar(64) NOT NULL
        , [SchedulerType] varchar(16) NOT NULL
        , [StartedAtUtc] datetime2(3) NOT NULL
        , [EndedAtUtc] datetime2(3) NULL
        , [SourceDatabaseName] sysname NOT NULL
        , [SqlServerStartTimeUtc] datetime2(3) NULL
        , [ResetEpochId] uniqueidentifier NULL
        , [ContractVersion] int NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
              CONSTRAINT [DF_snapshot_CaptureRun_IsPartial] DEFAULT (0)
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [MetricSampleCount] bigint NOT NULL
              CONSTRAINT [DF_snapshot_CaptureRun_MetricSampleCount] DEFAULT (0)
        , [PayloadCount] bigint NOT NULL
              CONSTRAINT [DF_snapshot_CaptureRun_PayloadCount] DEFAULT (0)
        , CONSTRAINT [PK_snapshot_CaptureRun]
              PRIMARY KEY CLUSTERED ([CaptureRunId])
        , CONSTRAINT [FK_snapshot_CaptureRun_CollectorPolicy]
              FOREIGN KEY ([CollectorCode])
              REFERENCES [snapshot].[CollectorPolicy]([CollectorCode])
        , CONSTRAINT [CK_snapshot_CaptureRun_SchedulerType]
              CHECK ([SchedulerType] IN ('MANUAL','EXTERNAL','SQL_AGENT'))
        , CONSTRAINT [CK_snapshot_CaptureRun_EndedAtUtc]
              CHECK ([EndedAtUtc] IS NULL OR [EndedAtUtc] >= [StartedAtUtc])
        , CONSTRAINT [CK_snapshot_CaptureRun_MetricSampleCount]
              CHECK ([MetricSampleCount] >= 0)
        , CONSTRAINT [CK_snapshot_CaptureRun_PayloadCount]
              CHECK ([PayloadCount] >= 0)
        , CONSTRAINT [CK_snapshot_CaptureRun_ContractVersion]
              CHECK ([ContractVersion] > 0)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'ModuleStatus'
)
BEGIN
    CREATE TABLE [snapshot].[ModuleStatus]
    (
          [ModuleStatusId] bigint IDENTITY(1,1) NOT NULL
        , [CaptureRunId] bigint NOT NULL
        , [ModuleName] sysname NOT NULL
        , [CollectionTimeUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
              CONSTRAINT [DF_snapshot_ModuleStatus_IsPartial] DEFAULT (0)
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [EvidenceLimit] nvarchar(1000) NULL
        , CONSTRAINT [PK_snapshot_ModuleStatus]
              PRIMARY KEY CLUSTERED ([ModuleStatusId])
        , CONSTRAINT [FK_snapshot_ModuleStatus_CaptureRun]
              FOREIGN KEY ([CaptureRunId])
              REFERENCES [snapshot].[CaptureRun]([CaptureRunId])
        , CONSTRAINT [UQ_snapshot_ModuleStatus_RunModule]
              UNIQUE ([CaptureRunId],[ModuleName])
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'Scope'
)
BEGIN
    CREATE TABLE [snapshot].[Scope]
    (
          [ScopeId] bigint IDENTITY(1,1) NOT NULL
        , [ScopeType] varchar(40) NOT NULL
        , [ParentScopeId] bigint NULL
        , [ScopeKeyHash] varbinary(32) NOT NULL
        , [ScopeIdentityJson] nvarchar(max) NOT NULL
        , [CreatedAtUtc] datetime2(3) NOT NULL
              CONSTRAINT [DF_snapshot_Scope_CreatedAtUtc]
              DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_snapshot_Scope]
              PRIMARY KEY CLUSTERED ([ScopeId])
        , CONSTRAINT [FK_snapshot_Scope_ParentScope]
              FOREIGN KEY ([ParentScopeId])
              REFERENCES [snapshot].[Scope]([ScopeId])
        , CONSTRAINT [UQ_snapshot_Scope_TypeKeyHash]
              UNIQUE ([ScopeType],[ScopeKeyHash])
        , CONSTRAINT [CK_snapshot_Scope_ScopeType]
              CHECK ([ScopeType] IN ('SERVER','PERFORMANCE_COUNTER'))
        , CONSTRAINT [CK_snapshot_Scope_ScopeKeyHash]
              CHECK (DATALENGTH([ScopeKeyHash]) = 32)
        , CONSTRAINT [CK_snapshot_Scope_ScopeIdentityJson]
              CHECK (ISJSON([ScopeIdentityJson]) = 1)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'MetricDefinition'
)
BEGIN
    CREATE TABLE [snapshot].[MetricDefinition]
    (
          [MetricDefinitionId] bigint IDENTITY(1,1) NOT NULL
        , [MetricCode] varchar(96) NOT NULL
        , [ValueType] varchar(24) NOT NULL
        , [Unit] varchar(40) NOT NULL
        , [ContractVersion] int NOT NULL
        , [Description] nvarchar(1000) NOT NULL
        , [IsFrameworkDefault] bit NOT NULL
              CONSTRAINT [DF_snapshot_MetricDefinition_IsFrameworkDefault]
              DEFAULT (0)
        , [SeedVersion] int NOT NULL
        , [LastUpdatedUtc] datetime2(3) NOT NULL
              CONSTRAINT [DF_snapshot_MetricDefinition_LastUpdatedUtc]
              DEFAULT (SYSUTCDATETIME())
        , CONSTRAINT [PK_snapshot_MetricDefinition]
              PRIMARY KEY CLUSTERED ([MetricDefinitionId])
        , CONSTRAINT [UQ_snapshot_MetricDefinition_MetricCode]
              UNIQUE ([MetricCode])
        , CONSTRAINT [CK_snapshot_MetricDefinition_ValueType]
              CHECK ([ValueType] IN ('NUMERIC','BIGINT','STRING'))
        , CONSTRAINT [CK_snapshot_MetricDefinition_ContractVersion]
              CHECK ([ContractVersion] > 0)
        , CONSTRAINT [CK_snapshot_MetricDefinition_SeedVersion]
              CHECK ([SeedVersion] > 0)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'MetricSample'
)
BEGIN
    CREATE TABLE [snapshot].[MetricSample]
    (
          [MetricSampleId] bigint IDENTITY(1,1) NOT NULL
        , [CaptureRunId] bigint NOT NULL
        , [ScopeId] bigint NOT NULL
        , [MetricDefinitionId] bigint NOT NULL
        , [CollectedAtUtc] datetime2(3) NOT NULL
        , [ResetEpochId] uniqueidentifier NOT NULL
        , [NumericValue] decimal(38,6) NULL
        , [BigintValue] bigint NULL
        , [StringValue] nvarchar(4000) NULL
        , [QualityCode] varchar(80) NOT NULL
        , [IsPartial] bit NOT NULL
              CONSTRAINT [DF_snapshot_MetricSample_IsPartial] DEFAULT (0)
        , CONSTRAINT [PK_snapshot_MetricSample]
              PRIMARY KEY CLUSTERED ([MetricSampleId])
        , CONSTRAINT [FK_snapshot_MetricSample_CaptureRun]
              FOREIGN KEY ([CaptureRunId])
              REFERENCES [snapshot].[CaptureRun]([CaptureRunId])
        , CONSTRAINT [FK_snapshot_MetricSample_Scope]
              FOREIGN KEY ([ScopeId])
              REFERENCES [snapshot].[Scope]([ScopeId])
        , CONSTRAINT [FK_snapshot_MetricSample_MetricDefinition]
              FOREIGN KEY ([MetricDefinitionId])
              REFERENCES [snapshot].[MetricDefinition]([MetricDefinitionId])
        , CONSTRAINT [UQ_snapshot_MetricSample_RunScopeMetric]
              UNIQUE ([CaptureRunId],[ScopeId],[MetricDefinitionId])
        , CONSTRAINT [CK_snapshot_MetricSample_ExactlyOneValue]
              CHECK
              (
                  (CASE WHEN [NumericValue] IS NULL THEN 0 ELSE 1 END)
                + (CASE WHEN [BigintValue] IS NULL THEN 0 ELSE 1 END)
                + (CASE WHEN [StringValue] IS NULL THEN 0 ELSE 1 END) = 1
              )
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'PayloadSnapshot'
)
BEGIN
    CREATE TABLE [snapshot].[PayloadSnapshot]
    (
          [PayloadSnapshotId] bigint IDENTITY(1,1) NOT NULL
        , [CaptureRunId] bigint NOT NULL
        , [ModuleName] sysname NOT NULL
        , [CapturedAtUtc] datetime2(3) NOT NULL
        , [PayloadFormat] varchar(40) NOT NULL
        , [PayloadContractVersion] int NOT NULL
        , [CompressionType] varchar(16) NOT NULL
        , [PayloadHash] varbinary(32) NOT NULL
        , [Payload] varbinary(max) NOT NULL
        , [UncompressedCharacterCount] bigint NOT NULL
        , CONSTRAINT [PK_snapshot_PayloadSnapshot]
              PRIMARY KEY CLUSTERED ([PayloadSnapshotId])
        , CONSTRAINT [FK_snapshot_PayloadSnapshot_CaptureRun]
              FOREIGN KEY ([CaptureRunId])
              REFERENCES [snapshot].[CaptureRun]([CaptureRunId])
        , CONSTRAINT [CK_snapshot_PayloadSnapshot_PayloadFormat]
              CHECK ([PayloadFormat] IN ('JSON','TEXT','XML','SQL_TEXT','PLAN_XML','ERROR_CONTEXT','PATH'))
        , CONSTRAINT [CK_snapshot_PayloadSnapshot_PayloadContractVersion]
              CHECK ([PayloadContractVersion] > 0)
        , CONSTRAINT [CK_snapshot_PayloadSnapshot_CompressionType]
              CHECK ([CompressionType] IN ('NONE','GZIP'))
        , CONSTRAINT [CK_snapshot_PayloadSnapshot_PayloadHash]
              CHECK (DATALENGTH([PayloadHash]) = 32)
        , CONSTRAINT [CK_snapshot_PayloadSnapshot_UncompressedCharacterCount]
              CHECK ([UncompressedCharacterCount] >= 0)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'PurgeRun'
)
BEGIN
    CREATE TABLE [snapshot].[PurgeRun]
    (
          [PurgeRunId] bigint IDENTITY(1,1) NOT NULL
        , [StartedAtUtc] datetime2(3) NOT NULL
        , [EndedAtUtc] datetime2(3) NULL
        , [StatusCode] varchar(40) NOT NULL
        , [BatchesExecuted] int NOT NULL
              CONSTRAINT [DF_snapshot_PurgeRun_BatchesExecuted] DEFAULT (0)
        , [MetricRowsDeleted] bigint NOT NULL
              CONSTRAINT [DF_snapshot_PurgeRun_MetricRowsDeleted] DEFAULT (0)
        , [PayloadRowsDeleted] bigint NOT NULL
              CONSTRAINT [DF_snapshot_PurgeRun_PayloadRowsDeleted] DEFAULT (0)
        , [ModuleRowsDeleted] bigint NOT NULL
              CONSTRAINT [DF_snapshot_PurgeRun_ModuleRowsDeleted] DEFAULT (0)
        , [CaptureRunsDeleted] bigint NOT NULL
              CONSTRAINT [DF_snapshot_PurgeRun_CaptureRunsDeleted] DEFAULT (0)
        , [ScopeRowsDeleted] bigint NOT NULL
              CONSTRAINT [DF_snapshot_PurgeRun_ScopeRowsDeleted] DEFAULT (0)
        , [UsedDataMbBefore] decimal(19,3) NULL
        , [UsedDataMbAfter] decimal(19,3) NULL
        , [SoftBudgetMb] bigint NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , CONSTRAINT [PK_snapshot_PurgeRun]
              PRIMARY KEY CLUSTERED ([PurgeRunId])
        , CONSTRAINT [CK_snapshot_PurgeRun_EndedAtUtc]
              CHECK ([EndedAtUtc] IS NULL OR [EndedAtUtc] >= [StartedAtUtc])
        , CONSTRAINT [CK_snapshot_PurgeRun_BatchesExecuted]
              CHECK ([BatchesExecuted] >= 0)
        , CONSTRAINT [CK_snapshot_PurgeRun_DeletedRows]
              CHECK ([MetricRowsDeleted] >= 0
                 AND [PayloadRowsDeleted] >= 0
                 AND [ModuleRowsDeleted] >= 0
                 AND [CaptureRunsDeleted] >= 0
                 AND [ScopeRowsDeleted] >= 0)
        , CONSTRAINT [CK_snapshot_PurgeRun_SoftBudgetMb]
              CHECK ([SoftBudgetMb] > 0)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS [i] WITH (NOLOCK)
    INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [i].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'RetentionPolicy'
      AND [i].[name] = N'UX_snapshot_RetentionPolicy_FrameworkDefault'
)
BEGIN
    CREATE UNIQUE INDEX [UX_snapshot_RetentionPolicy_FrameworkDefault]
        ON [snapshot].[RetentionPolicy]([IsFrameworkDefault])
        WHERE [IsFrameworkDefault] = 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS [i] WITH (NOLOCK)
    INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [i].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'CaptureRun'
      AND [i].[name] = N'IX_snapshot_CaptureRun_CollectorStarted'
)
BEGIN
    CREATE INDEX [IX_snapshot_CaptureRun_CollectorStarted]
        ON [snapshot].[CaptureRun]([CollectorCode],[StartedAtUtc] DESC,[CaptureRunId] DESC)
        INCLUDE ([EndedAtUtc],[StatusCode],[IsPartial],[SqlServerStartTimeUtc],[ResetEpochId]);
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS [i] WITH (NOLOCK)
    INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [i].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'ModuleStatus'
      AND [i].[name] = N'IX_snapshot_ModuleStatus_CaptureRun'
)
BEGIN
    CREATE INDEX [IX_snapshot_ModuleStatus_CaptureRun]
        ON [snapshot].[ModuleStatus]([CaptureRunId],[ModuleStatusId]);
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS [i] WITH (NOLOCK)
    INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [i].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'MetricSample'
      AND [i].[name] = N'IX_snapshot_MetricSample_CollectedAtUtc'
)
BEGIN
    CREATE INDEX [IX_snapshot_MetricSample_CollectedAtUtc]
        ON [snapshot].[MetricSample]([CollectedAtUtc],[MetricSampleId])
        INCLUDE ([CaptureRunId],[ScopeId],[MetricDefinitionId]);
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS [i] WITH (NOLOCK)
    INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [i].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'MetricSample'
      AND [i].[name] = N'IX_snapshot_MetricSample_ScopeMetricTime'
)
BEGIN
    CREATE INDEX [IX_snapshot_MetricSample_ScopeMetricTime]
        ON [snapshot].[MetricSample]([ScopeId],[MetricDefinitionId],[CollectedAtUtc] DESC)
        INCLUDE ([ResetEpochId],[NumericValue],[BigintValue],[QualityCode],[IsPartial]);
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS [i] WITH (NOLOCK)
    INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [i].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'PayloadSnapshot'
      AND [i].[name] = N'IX_snapshot_PayloadSnapshot_CapturedAtUtc'
)
BEGIN
    CREATE INDEX [IX_snapshot_PayloadSnapshot_CapturedAtUtc]
        ON [snapshot].[PayloadSnapshot]([CapturedAtUtc],[PayloadSnapshotId])
        INCLUDE ([CaptureRunId],[ModuleName],[PayloadFormat]);
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes] AS [i] WITH (NOLOCK)
    INNER JOIN [sys].[tables] AS [t] WITH (NOLOCK)
      ON [t].[object_id] = [i].[object_id]
    INNER JOIN [sys].[schemas] AS [s] WITH (NOLOCK)
      ON [s].[schema_id] = [t].[schema_id]
    WHERE [s].[name] = N'snapshot'
      AND [t].[name] = N'PurgeRun'
      AND [i].[name] = N'IX_snapshot_PurgeRun_StartedAtUtc'
)
BEGIN
    CREATE INDEX [IX_snapshot_PurgeRun_StartedAtUtc]
        ON [snapshot].[PurgeRun]([StartedAtUtc] DESC,[PurgeRunId] DESC)
        INCLUDE ([EndedAtUtc],[StatusCode]);
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [snapshot].[PackageVersion] WITH (NOLOCK)
    WHERE [PackageCode] = 'SC-023'
)
BEGIN
    INSERT [snapshot].[PackageVersion]
    (
          [PackageCode],[PackageVersion],[SchemaVersion]
        , [InstalledAtUtc],[LastInstallerRunUtc]
    )
    VALUES
    (
          'SC-023','1.0.0',1
        , SYSUTCDATETIME(),SYSUTCDATETIME()
    );
END
ELSE
BEGIN
    UPDATE [snapshot].[PackageVersion]
    SET [PackageVersion] = '1.0.0'
      , [SchemaVersion] = 1
      , [LastInstallerRunUtc] = SYSUTCDATETIME()
    WHERE [PackageCode] = 'SC-023';
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [snapshot].[RetentionPolicy] WITH (NOLOCK)
    WHERE [RetentionPolicyCode] = 'DEFAULT'
)
BEGIN
    INSERT [snapshot].[RetentionPolicy]
    (
          [RetentionPolicyCode]
        , [RawRetentionDays],[PayloadRetentionDays],[RollupRetentionDays]
        , [SoftBudgetMB],[PurgeIntervalMinutes],[PurgeBatchRows]
        , [BudgetAction],[IsFrameworkDefault],[SeedVersion],[LastUpdatedUtc]
    )
    VALUES
    (
          'DEFAULT'
        , 14,7,180
        , 10240,60,10000
        , 'PURGE_EXPIRED_THEN_STOP',1,1,SYSUTCDATETIME()
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [snapshot].[CollectorPolicy] WITH (NOLOCK)
    WHERE [CollectorCode] = 'PERFORMANCE_COUNTERS'
)
BEGIN
    INSERT [snapshot].[CollectorPolicy]
    (
          [CollectorCode],[IsEnabled],[CollectionIntervalSeconds]
        , [MaxRows],[PayloadEnabled],[RetentionPolicyCode]
        , [IsFrameworkDefault],[SeedVersion],[LastUpdatedUtc]
    )
    VALUES
    (
          'PERFORMANCE_COUNTERS',1,30
        , 1000,0,'DEFAULT'
        , 1,1,SYSUTCDATETIME()
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [snapshot].[MetricDefinition] WITH (NOLOCK)
    WHERE [MetricCode] = 'PERFORMANCE_COUNTER_RAW'
)
BEGIN
    INSERT [snapshot].[MetricDefinition]
    (
          [MetricCode],[ValueType],[Unit],[ContractVersion],[Description]
        , [IsFrameworkDefault],[SeedVersion],[LastUpdatedUtc]
    )
    VALUES
    (
          'PERFORMANCE_COUNTER_RAW','BIGINT','RAW_VALUE',1
        , N'Unveränderter kumulativer oder aktueller Wert aus monitor.USP_PerformanceCounters.'
        , 1,1,SYSUTCDATETIME()
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [snapshot].[MetricDefinition] WITH (NOLOCK)
    WHERE [MetricCode] = 'PERFORMANCE_COUNTER_INTERPRETED'
)
BEGIN
    INSERT [snapshot].[MetricDefinition]
    (
          [MetricCode],[ValueType],[Unit],[ContractVersion],[Description]
        , [IsFrameworkDefault],[SeedVersion],[LastUpdatedUtc]
    )
    VALUES
    (
          'PERFORMANCE_COUNTER_INTERPRETED','NUMERIC','SOURCE_DEFINED',1
        , N'Vom Quellvertrag abgeleiteter Wert; Einheit und Interpretation stehen in der Scope-Identität und Qualitätsklassifikation.'
        , 1,1,SYSUTCDATETIME()
    );
END;
GO
