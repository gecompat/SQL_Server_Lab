:setvar ScenarioId "LAB-INVALID-000"
:setvar LabRunId "LAB-20000101T000000Z-00000000"
:setvar WorkerId "1"

SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET LOCK_TIMEOUT 30000;

DECLARE @ScenarioId varchar(40) = '$(ScenarioId)';
DECLARE @LabRunId varchar(40) = '$(LabRunId)';
DECLARE @WorkerId int = TRY_CONVERT(int, '$(WorkerId)');
DECLARE @ContextToken binary(128) =
    CONVERT(binary(128), HASHBYTES('SHA2_256', CONCAT(@LabRunId, '|', @ScenarioId)));
DECLARE @Deadline datetime2(3) = DATEADD(SECOND, 18, SYSUTCDATETIME());
DECLARE @Accumulator bigint = 0;

IF @WorkerId IS NULL OR @WorkerId < 1 OR @WorkerId > 8
    THROW 55320, N'The worker identifier is outside the bounded range.', 1;

SET CONTEXT_INFO @ContextToken;

IF @WorkerId > 1
    WAITFOR DELAY '00:00:01';

IF @ScenarioId = 'LAB-CPU-001'
BEGIN
    WHILE SYSUTCDATETIME() < @Deadline
    BEGIN
        SELECT @Accumulator =
            SUM(CONVERT(bigint, ABS(CHECKSUM([Payload], [Amount], @WorkerId))))
        FROM [Lab001Wave3].[dbo].[Workload]
        OPTION (MAXDOP 1);
    END;
END;

IF @ScenarioId = 'LAB-CPU-002'
BEGIN
    WHILE SYSUTCDATETIME() < @Deadline
    BEGIN
        SELECT @Accumulator =
            SUM
            (
                CONVERT
                (
                    bigint,
                    ABS(CHECKSUM([a].[Payload], [b].[Amount], @WorkerId))
                )
            )
        FROM [Lab001Wave3].[dbo].[Workload] AS [a]
        CROSS JOIN [Lab001Wave3].[dbo].[Workload] AS [b]
        WHERE [a].[SyntheticId] <= 256
          AND [b].[SyntheticId] <= 512
        OPTION (MAXDOP 2, HASH JOIN);
    END;
END;

IF @ScenarioId = 'LAB-CPU-003'
BEGIN
    WHILE SYSUTCDATETIME() < @Deadline
    BEGIN
        SELECT @Accumulator =
            SUM(CONVERT(bigint, ABS(CHECKSUM([Payload], [Amount], @WorkerId))))
        FROM [Lab001Wave3].[dbo].[Workload]
        OPTION (MAXDOP 1);
    END;
END;

IF @ScenarioId = 'LAB-MEM-001'
BEGIN
    SELECT TOP (16384)
          [SyntheticId]
        , [GroupId]
        , [Amount]
        , [Payload]
    INTO [#GrantWorkload]
    FROM [Lab001Wave3].[dbo].[Workload]
    ORDER BY [Payload], [Amount], [SyntheticId]
    OPTION (MAXDOP 2, MAX_GRANT_PERCENT = 1);

    WAITFOR DELAY '00:00:15';
END;

IF @ScenarioId = 'LAB-MEM-002'
BEGIN
    WHILE SYSUTCDATETIME() < @Deadline
    BEGIN
        SELECT @Accumulator = SUM(CONVERT(bigint, DATALENGTH([Payload])))
        FROM [Lab001Wave3].[dbo].[BufferPoolWorkload] WITH (INDEX(0));
    END;
END;

IF @ScenarioId = 'LAB-TEMP-001'
BEGIN
    SELECT TOP (32768)
          ROW_NUMBER() OVER (ORDER BY [a].[Payload], [b].[SyntheticId]) AS [rn]
        , [a].[Payload]
        , [b].[Amount]
    INTO [#TempWorktable]
    FROM [Lab001Wave3].[dbo].[Workload] AS [a]
    CROSS JOIN [Lab001Wave3].[dbo].[Workload] AS [b]
    WHERE [a].[SyntheticId] <= 512
      AND [b].[SyntheticId] <= 512
    ORDER BY [a].[Payload], [b].[Amount]
    OPTION (MAXDOP 2, MAX_GRANT_PERCENT = 1);

    WAITFOR DELAY '00:00:15';
END;

IF @ScenarioId = 'LAB-TEMP-002'
BEGIN
    IF @WorkerId = 1
    BEGIN
        SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
        BEGIN TRANSACTION;
        SELECT @Accumulator = SUM(CONVERT(bigint, [Amount]))
        FROM [Lab001Wave3].[dbo].[Workload];
        WAITFOR DELAY '00:00:16';
        ROLLBACK TRANSACTION;
    END;
    ELSE
    BEGIN
        WAITFOR DELAY '00:00:02';
        UPDATE [Lab001Wave3].[dbo].[Workload]
        SET [Payload] = REPLICATE('V', 256)
        WHERE [SyntheticId] <= 8192;
        WAITFOR DELAY '00:00:12';
    END;
END;

IF @ScenarioId = 'LAB-TEMP-003'
BEGIN
    DECLARE @Iteration int = 1;
    WHILE @Iteration <= 200
    BEGIN
        CREATE TABLE [#AllocationWorkload]
        (
              [SyntheticId] int NOT NULL
            , [Payload] char(200) NOT NULL
        );
        INSERT [#AllocationWorkload] ([SyntheticId], [Payload])
        SELECT TOP (128)
              [SyntheticId]
            , REPLICATE(CONVERT(char(1), @WorkerId), 200)
        FROM [Lab001Wave3].[dbo].[Workload]
        ORDER BY [SyntheticId];
        DROP TABLE [#AllocationWorkload];
        SET @Iteration += 1;
    END;
    WAITFOR DELAY '00:00:08';
END;

IF @ScenarioId = 'LAB-LOG-001'
BEGIN
    BEGIN TRANSACTION;
    INSERT [Lab001Wave3].[dbo].[LogWorkload] ([Payload])
    SELECT TOP (6000)
           REPLICATE(CONVERT(varchar(1), ([SyntheticId] + 1701) % 10), 4000)
    FROM [Lab001Wave3].[dbo].[Workload]
    ORDER BY [SyntheticId];
    WAITFOR DELAY '00:00:16';
    ROLLBACK TRANSACTION;
END;

IF @ScenarioId = 'LAB-REC-001'
BEGIN
    BEGIN TRANSACTION;
    INSERT [Lab001Wave3].[dbo].[RecoveryWorkload]
    (
          [SyntheticId]
        , [Payload]
    )
    VALUES (2, 'UNCOMMITTED_SYNTHETIC_ROW');
    WAITFOR DELAY '00:01:30';
    ROLLBACK TRANSACTION;
END;

IF @ScenarioId = 'LAB-CONC-001'
BEGIN
    IF @WorkerId = 1
    BEGIN
        BEGIN TRANSACTION;
        UPDATE [Lab001Wave3].[dbo].[Workload]
        SET [Amount] += 1
        WHERE [SyntheticId] = 1;
        WAITFOR DELAY '00:00:16';
        ROLLBACK TRANSACTION;
    END;
    ELSE
    BEGIN
        UPDATE [Lab001Wave3].[dbo].[Workload]
        SET [Amount] += 1
        WHERE [SyntheticId] = 1;
    END;
END;

IF @ScenarioId = 'LAB-CONC-002'
BEGIN
    IF @WorkerId = 1
    BEGIN
        BEGIN TRANSACTION;
        ALTER TABLE [Lab001Wave3].[dbo].[Workload]
        ADD [ScenarioColumn] int NULL;
        WAITFOR DELAY '00:00:16';
        ROLLBACK TRANSACTION;
    END;
    ELSE
    BEGIN
        SELECT @Accumulator = COUNT_BIG(*)
        FROM [Lab001Wave3].[dbo].[Workload]
        WHERE [GroupId] = 1;
    END;
END;

IF @ScenarioId IN ('LAB-DEAD-001', 'LAB-XE-001')
BEGIN
    IF @WorkerId = 2
        SET DEADLOCK_PRIORITY LOW;

    BEGIN TRANSACTION;
    UPDATE [Lab001Wave3].[dbo].[Workload]
    SET [Amount] += @WorkerId
    WHERE [SyntheticId] = CASE WHEN @WorkerId = 1 THEN 1 ELSE 2 END;
    WAITFOR DELAY '00:00:02';
    UPDATE [Lab001Wave3].[dbo].[Workload]
    SET [Amount] += @WorkerId
    WHERE [SyntheticId] = CASE WHEN @WorkerId = 1 THEN 2 ELSE 1 END;
    COMMIT TRANSACTION;
END;

IF @ScenarioId = 'LAB-DEAD-002'
BEGIN
    IF @WorkerId = 2
        SET DEADLOCK_PRIORITY LOW;

    BEGIN TRANSACTION;
    SELECT @Accumulator = [Amount]
    FROM [Lab001Wave3].[dbo].[Workload] WITH (HOLDLOCK)
    WHERE [SyntheticId] = 1;
    WAITFOR DELAY '00:00:02';
    UPDATE [Lab001Wave3].[dbo].[Workload]
    SET [Amount] += @WorkerId
    WHERE [SyntheticId] = 1;
    COMMIT TRANSACTION;
END;

IF @ScenarioId = 'LAB-DEAD-003'
BEGIN
    IF @WorkerId = 2
        SET DEADLOCK_PRIORITY LOW;

    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    BEGIN TRANSACTION;
    IF @WorkerId = 1
    BEGIN
        SELECT @Accumulator = COUNT_BIG(*)
        FROM [Lab001Wave3].[dbo].[DeadlockRange] WITH (HOLDLOCK)
        WHERE [SyntheticId] BETWEEN 20 AND 40;
        WAITFOR DELAY '00:00:02';
        INSERT [Lab001Wave3].[dbo].[DeadlockRange] ([SyntheticId], [Payload])
        VALUES (70, 'WORKER_ONE_SYNTHETIC');
    END;
    ELSE
    BEGIN
        SELECT @Accumulator = COUNT_BIG(*)
        FROM [Lab001Wave3].[dbo].[DeadlockRange] WITH (HOLDLOCK)
        WHERE [SyntheticId] BETWEEN 60 AND 80;
        WAITFOR DELAY '00:00:02';
        INSERT [Lab001Wave3].[dbo].[DeadlockRange] ([SyntheticId], [Payload])
        VALUES (30, 'WORKER_TWO_SYNTHETIC');
    END;
    COMMIT TRANSACTION;
END;

IF @ScenarioId LIKE 'LAB-LATCH-%'
BEGIN
    DECLARE @InsertOrdinal int = 1;
    WHILE @InsertOrdinal <= 3000
    BEGIN
        IF @ScenarioId IN ('LAB-LATCH-001', 'LAB-LATCH-002')
        BEGIN
            INSERT [Lab001Wave3].[dbo].[LatchSequential]
            (
                  [WorkerId]
                , [Payload]
            )
            VALUES (@WorkerId, REPLICATE(CONVERT(char(1), @WorkerId), 200));
        END;

        IF @ScenarioId = 'LAB-LATCH-002'
        BEGIN
            INSERT [Lab001Wave3].[dbo].[LatchOptimized]
            (
                  [WorkerId]
                , [Payload]
            )
            VALUES (@WorkerId, REPLICATE(CONVERT(char(1), @WorkerId), 200));
        END;

        IF @ScenarioId = 'LAB-LATCH-003'
        BEGIN
            DECLARE @DistributedId bigint =
                CONVERT(bigint, @WorkerId) * 1000000 + @InsertOrdinal * 7919;
            INSERT [Lab001Wave3].[dbo].[LatchDistributed]
            (
                  [SyntheticId]
                , [WorkerId]
                , [Payload]
            )
            VALUES
            (
                  @DistributedId
                , @WorkerId
                , REPLICATE(CONVERT(char(1), @WorkerId), 200)
            );
            INSERT [Lab001Wave3].[dbo].[LatchHeap]
            (
                  [SyntheticId]
                , [WorkerId]
                , [Payload]
            )
            VALUES
            (
                  @DistributedId
                , @WorkerId
                , REPLICATE(CONVERT(char(1), @WorkerId), 200)
            );
        END;
        SET @InsertOrdinal += 1;
    END;
    WAITFOR DELAY '00:00:08';
END;

SELECT CONCAT
(
      N'LAB_WORKER_JSON='
    , (
        SELECT
              @ScenarioId AS [ScenarioId]
            , @WorkerId AS [WorkerId]
            , N'PASS' AS [Status]
            , @Accumulator AS [Accumulator]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
      )
);
