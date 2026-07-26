SET NOCOUNT ON;
USE [master];

DECLARE @DatabaseName sysname = N'LabLs001';
DECLARE @SecondaryServer sysname = N'$(SecondaryServer)';
DECLARE @BackupJobName sysname = N'LAB_LS_001_Backup';

IF EXISTS
(
    SELECT 1
    FROM [msdb].[dbo].[log_shipping_primary_secondaries]
    WHERE [primary_database] = @DatabaseName
      AND [secondary_server] = @SecondaryServer
      AND [secondary_database] = @DatabaseName
)
BEGIN
    EXEC [msdb].[dbo].[sp_delete_log_shipping_primary_secondary]
          @primary_database = @DatabaseName
        , @secondary_server = @SecondaryServer
        , @secondary_database = @DatabaseName;
END;

IF EXISTS
(
    SELECT 1
    FROM [msdb].[dbo].[log_shipping_primary_databases]
    WHERE [primary_database] = @DatabaseName
)
BEGIN
    EXEC [msdb].[dbo].[sp_delete_log_shipping_primary_database]
          @database = @DatabaseName
        , @ignoreremotemonitor = 1;
END;

DECLARE @BackupJobId uniqueidentifier =
(
    SELECT [job_id]
    FROM [msdb].[dbo].[sysjobs]
    WHERE [name] = @BackupJobName
);
IF @BackupJobId IS NOT NULL
BEGIN
    EXEC [msdb].[dbo].[sp_delete_job]
          @job_id = @BackupJobId
        , @delete_unused_schedule = 1;
END;

IF DB_ID(@DatabaseName) IS NOT NULL
BEGIN
    EXEC
    (
        N'ALTER DATABASE ' + QUOTENAME(@DatabaseName)
        + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '
        + QUOTENAME(@DatabaseName) + N';'
    );
END;

SELECT N'LAB_CLEANUP_JSON={"ScenarioId":"$(ScenarioId)","Status":"PASS","ResetPolicy":"EXACT_SYNTHETIC_SCOPE"}';
