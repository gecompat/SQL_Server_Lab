SET NOCOUNT ON;
USE [msdb];

DECLARE @Jobs table
(
      [Ordinal] int NOT NULL PRIMARY KEY
    , [JobName] sysname NOT NULL
    , [PhaseName] varchar(20) NOT NULL
);
INSERT @Jobs ([Ordinal], [JobName], [PhaseName])
VALUES
      (1, N'LAB_LS_001_Copy', 'COPY')
    , (2, N'LAB_LS_001_Restore', 'RESTORE');

DECLARE @Ordinal int = 1;
WHILE @Ordinal <= 2
BEGIN
    DECLARE @JobName sysname;
    DECLARE @PhaseName varchar(20);
    SELECT @JobName = [JobName], @PhaseName = [PhaseName]
    FROM @Jobs
    WHERE [Ordinal] = @Ordinal;

    DECLARE @JobId uniqueidentifier =
    (
        SELECT [job_id]
        FROM [dbo].[sysjobs]
        WHERE [name] = @JobName
    );
    IF @JobId IS NULL
        THROW 51000, 'Synthetic Log Shipping secondary job is missing.', 1;

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
            THROW 51000, 'Synthetic Log Shipping secondary job timed out.', 1;
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
        THROW 51000, 'Synthetic Log Shipping secondary job did not succeed.', 1;

    SET @Ordinal += 1;
END;

SELECT N'LAB_PHASE_JSON={"ScenarioId":"$(ScenarioId)","Status":"PASS","Phase":"SECONDARY_COPY_RESTORE"}';
