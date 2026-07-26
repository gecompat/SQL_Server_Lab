SET NOCOUNT ON;
USE [master];

DECLARE @DatabaseName sysname = N'LabLs001';
DECLARE @SecondaryServer sysname = N'$(SecondaryServer)';
DECLARE @BackupDirectory nvarchar(500) = N'/lab/runtime/scenarios/LAB-LS-001/transfer/source';
DECLARE @InitialBackup nvarchar(500) = N'/lab/runtime/scenarios/LAB-LS-001/transfer/source/LabLs001_init.bak';
DECLARE @BackupJobName sysname = N'LAB_LS_001_Backup';

CREATE DATABASE [LabLs001]
ON PRIMARY
(
      NAME = N'LabLs001_Data'
    , FILENAME = N'/var/opt/mssql/data/LabLs001.mdf'
    , SIZE = 16MB
    , FILEGROWTH = 16MB
)
LOG ON
(
      NAME = N'LabLs001_Log'
    , FILENAME = N'/var/opt/mssql/data/LabLs001_log.ldf'
    , SIZE = 16MB
    , FILEGROWTH = 16MB
);
ALTER DATABASE [LabLs001] SET RECOVERY FULL;

CREATE TABLE [LabLs001].[dbo].[LabLogShippingMarker]
(
      [MarkerId] int IDENTITY(1,1) NOT NULL PRIMARY KEY
    , [RunId] varchar(40) NOT NULL
    , [CycleOrdinal] int NOT NULL
    , [CreatedAtUtc] datetime2(3) NOT NULL
        CONSTRAINT [DF_LabLogShippingMarker_CreatedAtUtc]
        DEFAULT (SYSUTCDATETIME())
);
INSERT [LabLs001].[dbo].[LabLogShippingMarker] ([RunId], [CycleOrdinal])
VALUES ('$(LabRunId)', 0);

BACKUP DATABASE [LabLs001]
TO DISK = @InitialBackup
WITH INIT, CHECKSUM;

DECLARE @BackupJobId uniqueidentifier;
DECLARE @PrimaryId uniqueidentifier;
EXEC [msdb].[dbo].[sp_add_log_shipping_primary_database]
      @database = @DatabaseName
    , @backup_directory = @BackupDirectory
    , @backup_share = @BackupDirectory
    , @backup_job_name = @BackupJobName
    , @backup_retention_period = 60
    , @backup_threshold = 30
    , @threshold_alert_enabled = 0
    , @history_retention_period = 60
    , @backup_job_id = @BackupJobId OUTPUT
    , @primary_id = @PrimaryId OUTPUT
    , @overwrite = 1;

EXEC [msdb].[dbo].[sp_add_log_shipping_primary_secondary]
      @primary_database = @DatabaseName
    , @secondary_server = @SecondaryServer
    , @secondary_database = @DatabaseName
    , @overwrite = 1;

EXEC [msdb].[dbo].[sp_update_job]
      @job_id = @BackupJobId
    , @enabled = 1;

IF NOT EXISTS
(
    SELECT 1
    FROM [msdb].[dbo].[log_shipping_primary_databases]
    WHERE [primary_database] = @DatabaseName
)
    THROW 51000, 'Synthetic Log Shipping primary metadata is missing.', 1;

SELECT N'LAB_SETUP_JSON={"ScenarioId":"$(ScenarioId)","Status":"PASS","Role":"SQL_PRIMARY"}';
