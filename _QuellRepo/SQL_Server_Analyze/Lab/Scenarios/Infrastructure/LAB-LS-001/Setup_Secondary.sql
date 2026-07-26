SET NOCOUNT ON;
USE [master];

DECLARE @DatabaseName sysname = N'LabLs001';
DECLARE @PrimaryServer sysname = N'$(PrimaryServer)';
DECLARE @BackupSourceDirectory nvarchar(500) = N'/lab/runtime/scenarios/LAB-LS-001/transfer/source';
DECLARE @BackupDestinationDirectory nvarchar(500) = N'/lab/runtime/scenarios/LAB-LS-001/transfer/destination';
DECLARE @InitialBackup nvarchar(500) = N'/lab/runtime/scenarios/LAB-LS-001/transfer/source/LabLs001_init.bak';
DECLARE @CopyJobName sysname = N'LAB_LS_001_Copy';
DECLARE @RestoreJobName sysname = N'LAB_LS_001_Restore';

RESTORE DATABASE [LabLs001]
FROM DISK = @InitialBackup
WITH
      MOVE N'LabLs001_Data' TO N'/var/opt/mssql/data/LabLs001.mdf'
    , MOVE N'LabLs001_Log' TO N'/var/opt/mssql/data/LabLs001_log.ldf'
    , NORECOVERY
    , REPLACE;

DECLARE @CopyJobId uniqueidentifier;
DECLARE @RestoreJobId uniqueidentifier;
DECLARE @SecondaryId uniqueidentifier;
EXEC [msdb].[dbo].[sp_add_log_shipping_secondary_primary]
      @primary_server = @PrimaryServer
    , @primary_database = @DatabaseName
    , @backup_source_directory = @BackupSourceDirectory
    , @backup_destination_directory = @BackupDestinationDirectory
    , @copy_job_name = @CopyJobName
    , @restore_job_name = @RestoreJobName
    , @file_retention_period = 60
    , @copy_job_id = @CopyJobId OUTPUT
    , @restore_job_id = @RestoreJobId OUTPUT
    , @secondary_id = @SecondaryId OUTPUT
    , @overwrite = 1;

EXEC [msdb].[dbo].[sp_add_log_shipping_secondary_database]
      @secondary_database = @DatabaseName
    , @primary_server = @PrimaryServer
    , @primary_database = @DatabaseName
    , @restore_delay = 0
    , @restore_mode = 0
    , @disconnect_users = 0
    , @restore_threshold = 30
    , @threshold_alert_enabled = 0
    , @history_retention_period = 60
    , @overwrite = 1
    , @ignoreremotemonitor = 1;

EXEC [msdb].[dbo].[sp_update_job]
      @job_id = @CopyJobId
    , @enabled = 1;
EXEC [msdb].[dbo].[sp_update_job]
      @job_id = @RestoreJobId
    , @enabled = 1;

IF NOT EXISTS
(
    SELECT 1
    FROM [msdb].[dbo].[log_shipping_secondary_databases]
    WHERE [secondary_database] = @DatabaseName
)
    THROW 51000, 'Synthetic Log Shipping secondary metadata is missing.', 1;

SELECT N'LAB_SETUP_JSON={"ScenarioId":"$(ScenarioId)","Status":"PASS","Role":"SQL_SECONDARY"}';
