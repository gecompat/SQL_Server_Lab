/*
===============================================================================
Datei        : 195_SnapshotBaseline_Runtime_Contract.sql
Zweck        : Prüft SC-023 isoliert mit ausschließlich synthetischen Namen.
Ausführung   : sqlcmd-Arbeitsverzeichnis Code/Install; Core ist installiert,
               SQLServerAnalyzeSnapshotTest ist leer und explizit angelegt.
Datenschutz  : Keine Laufzeitwerte werden ausgegeben oder in Artefakte kopiert.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

CREATE TABLE [#SnapshotBaselineRuntimeContract_State]
(
      [StateName] varchar(40) NOT NULL PRIMARY KEY
    , [BigintValue] bigint NULL
    , [GuidValue] uniqueidentifier NULL
);

USE [SQLServerAnalyzeTest];
GO

IF EXISTS
(
    SELECT 1
    FROM [sys].[tables] AS [t] WITH (NOLOCK)
    JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id]
    WHERE [s].[name]=N'monitor' AND [t].[name]=N'SnapshotTargetConfiguration'
)
    THROW 53720,N'SC023_CORE_STATELESS_CONTRACT',1;
GO

USE [SQLServerAnalyzeSnapshotTest];
GO
:r Install_SnapshotBaseline_Target.sql

USE [SQLServerAnalyzeTest];
GO
:r Install_SnapshotBaseline_Framework.sql

DECLARE @Status varchar(40),@Partial bit,@Error int,@Message nvarchar(2048);
EXEC [monitor].[USP_ConfigureSnapshotTarget]
     @TargetDatabaseName=N'SQLServerAnalyzeSnapshotTest',@IsEnabled=1,
     @SchedulerType='EXTERNAL',@CollectionIntervalSeconds=30,@MaxRows=100,
     @PayloadEnabled=1,@RawRetentionDays=14,@PayloadRetentionDays=7,
     @RollupRetentionDays=180,@SoftBudgetMB=10240,@PurgeIntervalMinutes=60,
     @PurgeBatchRows=1000,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'AVAILABLE' THROW 53721,N'SC023_CONFIGURE_FAILED',1;

DECLARE @Run1 bigint,@Run2 bigint,@Run3 bigint,@Run4 bigint,@Json nvarchar(max),@Epoch1 uniqueidentifier,@Epoch2 uniqueidentifier;
EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType='MANUAL',@RunEvenIfNotDue=1,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,@CaptureRunIdOut=@Run1 OUTPUT,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status NOT IN ('AVAILABLE','PARTIAL') OR @Run1 IS NULL OR ISJSON(@Json)<>1
    THROW 53722,N'SC023_FIRST_CYCLE_FAILED',1;
IF NOT EXISTS (SELECT 1 FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[MetricSample] WHERE [CaptureRunId]=@Run1)
    THROW 53723,N'SC023_METRIC_SAMPLE_MISSING',1;
IF NOT EXISTS
(
    SELECT 1
    FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[PayloadSnapshot]
    WHERE [CaptureRunId]=@Run1
      AND [PayloadHash]=HASHBYTES('SHA2_256',CONVERT(varbinary(max),CONVERT(nvarchar(max),DECOMPRESS([Payload]))))
      AND [UncompressedCharacterCount]=LEN(CONVERT(nvarchar(max),DECOMPRESS([Payload])))
)
    THROW 53724,N'SC023_PAYLOAD_LOSSLESS_CONTRACT',1;
SELECT @Epoch1=[ResetEpochId]
FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[CaptureRun]
WHERE [CaptureRunId]=@Run1;
IF @Epoch1 IS NULL THROW 53725,N'SC023_RESET_EPOCH_MISSING',1;
INSERT [#SnapshotBaselineRuntimeContract_State]([StateName],[BigintValue],[GuidValue])
VALUES ('FIRST_RUN',@Run1,@Epoch1);

EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType='EXTERNAL',@RunEvenIfNotDue=1,@ResultSetArt='NONE',@PrintMeldungen=0,
     @CaptureRunIdOut=@Run2 OUTPUT,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status NOT IN ('AVAILABLE','PARTIAL') OR @Run2 IS NULL THROW 53726,N'SC023_EXTERNAL_ENTRY_FAILED',1;
SELECT @Epoch2=[ResetEpochId]
FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[CaptureRun]
WHERE [CaptureRunId]=@Run2;
IF @Epoch2<>@Epoch1 THROW 53727,N'SC023_RESET_EPOCH_DRIFT',1;

EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType='SQL_AGENT',@RunEvenIfNotDue=1,@ResultSetArt='NONE',@PrintMeldungen=0,
     @CaptureRunIdOut=@Run3 OUTPUT,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status NOT IN ('AVAILABLE','PARTIAL') OR @Run3 IS NULL THROW 53728,N'SC023_SQL_AGENT_ENTRY_FAILED',1;

EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType='EXTERNAL',@RunEvenIfNotDue=0,@ResultSetArt='NONE',@PrintMeldungen=0,
     @CaptureRunIdOut=@Run4 OUTPUT,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'SKIPPED_NOT_DUE' OR @Run4 IS NULL
    THROW 53729,N'SC023_DUE_CONTRACT_FAILED',1;
IF EXISTS (SELECT 1 FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[MetricSample] WHERE [CaptureRunId]=@Run4)
    THROW 53730,N'SC023_NOT_DUE_READ_SOURCE',1;

CREATE TABLE [#SnapshotBaselineRuntimeContract_RunOutput]
([Seed] bit NULL);
CREATE TABLE [#SnapshotBaselineRuntimeContract_ModuleOutput]
([Seed] bit NULL);
DECLARE @TableRun bigint;
EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType='EXTERNAL',@RunEvenIfNotDue=0,@ResultSetArt='TABLE',
     @ResultTablesJson=N'{"run":"#SnapshotBaselineRuntimeContract_RunOutput","modules":"#SnapshotBaselineRuntimeContract_ModuleOutput"}',
     @PrintMeldungen=0,@CaptureRunIdOut=@TableRun OUTPUT,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'SKIPPED_NOT_DUE' OR @TableRun IS NULL
   OR (SELECT COUNT_BIG(*) FROM [#SnapshotBaselineRuntimeContract_RunOutput])<>1
   OR (SELECT COUNT_BIG(*) FROM [#SnapshotBaselineRuntimeContract_ModuleOutput])<>1
    THROW 53742,N'SC023_COLLECTION_TABLE_OUTPUT_FAILED',1;
GO

USE [SQLServerAnalyzeSnapshotTest];
GO
IF NOT EXISTS (SELECT 1 FROM [snapshot].[RetentionPolicy] WHERE [RetentionPolicyCode]='EXAMPLE_LOCAL')
    INSERT [snapshot].[RetentionPolicy]
    ([RetentionPolicyCode],[RawRetentionDays],[PayloadRetentionDays],[RollupRetentionDays],[SoftBudgetMB],[PurgeIntervalMinutes],[PurgeBatchRows],[BudgetAction],[IsFrameworkDefault],[SeedVersion],[LastUpdatedUtc])
    VALUES ('EXAMPLE_LOCAL',30,15,365,2048,120,500,'PURGE_EXPIRED_THEN_STOP',0,1,CONVERT(datetime2(3),'2026-01-01T00:00:00'));
GO
:r Install_SnapshotBaseline_Target.sql

USE [SQLServerAnalyzeTest];
GO
:r Install_SnapshotBaseline_Framework.sql

IF NOT EXISTS
(
    SELECT 1 FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[RetentionPolicy]
    WHERE [RetentionPolicyCode]='EXAMPLE_LOCAL'
      AND [LastUpdatedUtc]=CONVERT(datetime2(3),'2026-01-01T00:00:00')
)
    THROW 53731,N'SC023_REINSTALL_CHANGED_LOCAL_POLICY',1;
IF NOT EXISTS
(
    SELECT 1 FROM [monitor].[SnapshotTargetConfiguration]
    WHERE [ConfigurationId]=1 AND [TargetDatabaseName]=N'SQLServerAnalyzeSnapshotTest' AND [IsEnabled]=1
)
    THROW 53732,N'SC023_REINSTALL_CHANGED_FRAMEWORK_CONFIG',1;

DECLARE @OldRun bigint,@ScopeId bigint,@MetricId bigint;
SELECT TOP (1) @ScopeId=[ScopeId]
FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[Scope]
WHERE [ScopeType]='SERVER' ORDER BY [ScopeId];
SELECT @MetricId=[MetricDefinitionId]
FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[MetricDefinition]
WHERE [MetricCode]='PERFORMANCE_COUNTER_RAW';
INSERT [SQLServerAnalyzeSnapshotTest].[snapshot].[CaptureRun]
([CollectorCode],[SchedulerType],[StartedAtUtc],[EndedAtUtc],[SourceDatabaseName],[SqlServerStartTimeUtc],[ResetEpochId],[ContractVersion],[StatusCode],[IsPartial],[MetricSampleCount],[PayloadCount])
VALUES ('PERFORMANCE_COUNTERS','MANUAL',DATEADD(DAY,-30,SYSUTCDATETIME()),DATEADD(DAY,-30,SYSUTCDATETIME()),N'ExampleFrameworkDatabase',DATEADD(DAY,-40,SYSUTCDATETIME()),NEWID(),1,'AVAILABLE',0,1,0);
SET @OldRun=CONVERT(bigint,SCOPE_IDENTITY());
INSERT [SQLServerAnalyzeSnapshotTest].[snapshot].[MetricSample]
([CaptureRunId],[ScopeId],[MetricDefinitionId],[CollectedAtUtc],[ResetEpochId],[BigintValue],[QualityCode],[IsPartial])
VALUES (@OldRun,@ScopeId,@MetricId,DATEADD(DAY,-30,SYSUTCDATETIME()),NEWID(),1,'EXAMPLE_MEASURED',0);
INSERT [SQLServerAnalyzeSnapshotTest].[snapshot].[ModuleStatus]
([CaptureRunId],[ModuleName],[CollectionTimeUtc],[StatusCode],[IsPartial],[EvidenceLimit])
VALUES (@OldRun,N'ExampleCollector',DATEADD(DAY,-30,SYSUTCDATETIME()),'AVAILABLE',0,N'Synthetic retention fixture.');

DECLARE @PurgeRun bigint,@PurgeJson nvarchar(max),@Status varchar(40),@Partial bit,@Error int,@Message nvarchar(2048);
EXEC [monitor].[USP_PurgeSnapshotData]
     @MaxBatches=2,@Force=1,@ResultSetArt='NONE',@JsonErzeugen=1,@Json=@PurgeJson OUTPUT,@PrintMeldungen=0,
     @PurgeRunIdOut=@PurgeRun OUTPUT,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status NOT IN ('AVAILABLE','AVAILABLE_LIMITED') OR @PurgeRun IS NULL OR ISJSON(@PurgeJson)<>1
    THROW 53733,N'SC023_PURGE_FAILED',1;
IF EXISTS (SELECT 1 FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[CaptureRun] WHERE [CaptureRunId]=@OldRun)
    THROW 53734,N'SC023_EXPIRED_RUN_RETAINED',1;
DECLARE @FirstRunRestored bigint=(SELECT [BigintValue] FROM [#SnapshotBaselineRuntimeContract_State] WHERE [StateName]='FIRST_RUN');
IF NOT EXISTS (SELECT 1 FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[CaptureRun] WHERE [CaptureRunId]=@FirstRunRestored)
    THROW 53735,N'SC023_UNEXPIRED_RUN_DELETED',1;

CREATE TABLE [#SnapshotBaselineRuntimeContract_PurgeOutput]
([Seed] bit NULL);
DECLARE @TablePurgeRun bigint;
EXEC [monitor].[USP_PurgeSnapshotData]
     @MaxBatches=2,@Force=0,@ResultSetArt='TABLE',
     @ResultTablesJson=N'{"purge":"#SnapshotBaselineRuntimeContract_PurgeOutput"}',
     @PrintMeldungen=0,@PurgeRunIdOut=@TablePurgeRun OUTPUT,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'SKIPPED_NOT_DUE'
   OR (SELECT COUNT_BIG(*) FROM [#SnapshotBaselineRuntimeContract_PurgeOutput])<>1
    THROW 53743,N'SC023_PURGE_TABLE_OUTPUT_FAILED',1;

UPDATE [SQLServerAnalyzeSnapshotTest].[snapshot].[RetentionPolicy]
SET [SoftBudgetMB]=1
WHERE [RetentionPolicyCode]='DEFAULT';
DECLARE @BudgetRun bigint;
EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @SchedulerType='MANUAL',@RunEvenIfNotDue=1,@ResultSetArt='NONE',@PrintMeldungen=0,
     @CaptureRunIdOut=@BudgetRun OUTPUT,@StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'STOPPED_SIZE_BUDGET' OR @BudgetRun IS NULL
    THROW 53736,N'SC023_BUDGET_STOP_FAILED',1;
IF EXISTS (SELECT 1 FROM [SQLServerAnalyzeSnapshotTest].[snapshot].[MetricSample] WHERE [CaptureRunId]=@BudgetRun)
    THROW 53737,N'SC023_BUDGET_STOP_READ_SOURCE',1;
UPDATE [SQLServerAnalyzeSnapshotTest].[snapshot].[RetentionPolicy]
SET [SoftBudgetMB]=10240
WHERE [RetentionPolicyCode]='DEFAULT';

EXEC [monitor].[USP_ConfigureSnapshotTarget]
     @TargetDatabaseName=N'SQLServerAnalyzeSnapshotTest',@IsEnabled=0,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'AVAILABLE' THROW 53738,N'SC023_DISABLE_CONFIG_FAILED',1;
EXEC [monitor].[USP_RunSnapshotCollectionCycle]
     @ResultSetArt='NONE',@PrintMeldungen=0,@StatusCodeOut=@Status OUTPUT,
     @IsPartialOut=@Partial OUTPUT,@ErrorNumberOut=@Error OUTPUT,@ErrorMessageOut=@Message OUTPUT;
IF @Status<>'DISABLED' THROW 53739,N'SC023_DISABLED_CONTRACT_FAILED',1;

PRINT N'SC023_RUNTIME_CONTRACT PASS';
GO
