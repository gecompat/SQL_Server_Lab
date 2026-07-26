SET NOCOUNT ON;
USE [msdb];

DECLARE @CycleOrdinal int = CONVERT(int, '$(CycleOrdinal)');
INSERT [LabLs001].[dbo].[LabLogShippingMarker] ([RunId], [CycleOrdinal])
VALUES ('$(LabRunId)', @CycleOrdinal);

DECLARE @JobName sysname = N'LAB_LS_001_Backup';
DECLARE @JobId uniqueidentifier =
(
    SELECT [job_id]
    FROM [dbo].[sysjobs]
    WHERE [name] = @JobName
);
IF @JobId IS NULL
    THROW 51000, 'Synthetic Log Shipping backup job is missing.', 1;

DECLARE @BeforeInstanceId int = COALESCE
(
    (
        SELECT MAX([instance_id])
        FROM [dbo].[sysjobhistory]
        WHERE [job_id] = @JobId
          AND [step_id] = 0
    ),
    0
);
EXEC [dbo].[sp_start_job] @job_id = @JobId;

DECLARE @Deadline datetime2(0) = DATEADD(SECOND, 120, SYSUTCDATETIME());
WHILE NOT EXISTS
(
    SELECT 1
    FROM [dbo].[sysjobhistory]
    WHERE [job_id] = @JobId
      AND [step_id] = 0
      AND [instance_id] > @BeforeInstanceId
)
BEGIN
    IF SYSUTCDATETIME() >= @Deadline
        THROW 51000, 'Synthetic Log Shipping backup job timed out.', 1;
    WAITFOR DELAY '00:00:01';
END;

DECLARE @RunStatus int =
(
    SELECT TOP (1) [run_status]
    FROM [dbo].[sysjobhistory]
    WHERE [job_id] = @JobId
      AND [step_id] = 0
      AND [instance_id] > @BeforeInstanceId
    ORDER BY [instance_id] DESC
);
IF @RunStatus <> 1
    THROW 51000, 'Synthetic Log Shipping backup job did not succeed.', 1;

SELECT CONCAT
(
    N'LAB_PHASE_JSON={"ScenarioId":"$(ScenarioId)","Status":"PASS","Phase":"PRIMARY_BACKUP","CycleOrdinal":',
    @CycleOrdinal,
    N'}'
);
