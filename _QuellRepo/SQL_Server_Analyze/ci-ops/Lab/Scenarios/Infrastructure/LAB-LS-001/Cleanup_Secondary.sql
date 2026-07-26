SET NOCOUNT ON;
USE [master];

DECLARE @DatabaseName sysname = N'LabLs001';
DECLARE @CopyJobName sysname = N'LAB_LS_001_Copy';
DECLARE @RestoreJobName sysname = N'LAB_LS_001_Restore';

IF EXISTS
(
    SELECT 1
    FROM [msdb].[dbo].[log_shipping_secondary_databases]
    WHERE [secondary_database] = @DatabaseName
)
BEGIN
    EXEC [msdb].[dbo].[sp_delete_log_shipping_secondary_database]
          @secondary_database = @DatabaseName
        , @ignoreremotemonitor = 1;
END;

DECLARE @JobId uniqueidentifier;
SELECT @JobId = [job_id]
FROM [msdb].[dbo].[sysjobs]
WHERE [name] = @CopyJobName;
IF @JobId IS NOT NULL
BEGIN
    EXEC [msdb].[dbo].[sp_delete_job]
          @job_id = @JobId
        , @delete_unused_schedule = 1;
END;

SET @JobId = NULL;
SELECT @JobId = [job_id]
FROM [msdb].[dbo].[sysjobs]
WHERE [name] = @RestoreJobName;
IF @JobId IS NOT NULL
BEGIN
    EXEC [msdb].[dbo].[sp_delete_job]
          @job_id = @JobId
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
