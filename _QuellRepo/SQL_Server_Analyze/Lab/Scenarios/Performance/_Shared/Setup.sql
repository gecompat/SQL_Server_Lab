:setvar ScenarioId "LAB-INVALID-000"
:setvar LabRunId "LAB-20000101T000000Z-00000000"

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ScenarioId varchar(40) = '$(ScenarioId)';
DECLARE @LabRunId varchar(40) = '$(LabRunId)';
DECLARE @ProductMajorVersion int =
    TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));

IF @ScenarioId NOT LIKE 'LAB-%-[0-9][0-9][0-9]'
    THROW 55300, N'The scenario identifier is invalid.', 1;

IF DB_ID(N'Lab001Wave3') IS NOT NULL
    THROW 55301, N'The synthetic scenario database was not reset.', 1;

IF EXISTS
(
    SELECT 1
    FROM [sys].[server_event_sessions]
    WHERE [name] = N'Lab001Wave3Session'
)
OR EXISTS
(
    SELECT 1
    FROM [sys].[resource_governor_workload_groups]
    WHERE [name] = N'Lab001Group'
)
OR EXISTS
(
    SELECT 1
    FROM [sys].[resource_governor_resource_pools]
    WHERE [name] = N'Lab001Pool'
)
    THROW 55306, N'A fixed synthetic server-object name is already in use.', 1;

CREATE DATABASE [Lab001Wave3]
COLLATE SQL_Latin1_General_CP1_CS_AS;

EXEC [Lab001Wave3].[sys].[sp_addextendedproperty]
      @name = N'Lab001RunId'
    , @value = @LabRunId;

EXEC [Lab001Wave3].[sys].[sp_executesql]
    N'
SET NOCOUNT ON;
SET XACT_ABORT ON;

CREATE TABLE [dbo].[LabState]
(
      [StateName] sysname NOT NULL
        CONSTRAINT [PK_LabState] PRIMARY KEY
    , [StateValue] nvarchar(4000) NULL
);

INSERT [dbo].[LabState] ([StateName], [StateValue])
SELECT N''ScenarioId'', @ScenarioId
UNION ALL
SELECT N''FixedSeed'', N''1701''
UNION ALL
SELECT N''ResourceGovernorWasEnabled'',
       CONVERT(nvarchar(10), [is_enabled])
FROM [sys].[resource_governor_configuration];

CREATE TABLE [dbo].[Workload]
(
      [SyntheticId] int NOT NULL
        CONSTRAINT [PK_Workload] PRIMARY KEY CLUSTERED
    , [GroupId] int NOT NULL
    , [Amount] int NOT NULL
    , [Payload] char(256) NOT NULL
);

;WITH [n] AS
(
    SELECT TOP (16384)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[Workload]
(
      [SyntheticId]
    , [GroupId]
    , [Amount]
    , [Payload]
)
SELECT
      CONVERT(int, [n])
    , CONVERT(int, CASE WHEN [n] <= 16000 THEN 1 ELSE [n] % 97 END)
    , CONVERT(int, ([n] * 1701) % 100000)
    , CONVERT(char(256), CONCAT(''SYNTHETIC-'', [n]))
FROM [n];

CREATE TABLE [dbo].[LogWorkload]
(
      [SyntheticId] int IDENTITY(1,1) NOT NULL
        CONSTRAINT [PK_LogWorkload] PRIMARY KEY
    , [Payload] char(4000) NOT NULL
);

CREATE TABLE [dbo].[RecoveryWorkload]
(
      [SyntheticId] int NOT NULL
        CONSTRAINT [PK_RecoveryWorkload] PRIMARY KEY
    , [Payload] varchar(64) NOT NULL
);

INSERT [dbo].[RecoveryWorkload] ([SyntheticId], [Payload])
VALUES (1, ''COMMITTED_SYNTHETIC_ROW'');

CREATE TABLE [dbo].[DeadlockRange]
(
      [SyntheticId] int NOT NULL
        CONSTRAINT [PK_DeadlockRange] PRIMARY KEY
    , [Payload] varchar(64) NOT NULL
);

INSERT [dbo].[DeadlockRange] ([SyntheticId], [Payload])
VALUES
      (10, ''LOW_SYNTHETIC_BOUNDARY'')
    , (90, ''HIGH_SYNTHETIC_BOUNDARY'');
'
    , N'@ScenarioId varchar(40)'
    , @ScenarioId = @ScenarioId;

IF @ScenarioId = 'LAB-TEMP-002'
    ALTER DATABASE [Lab001Wave3] SET ALLOW_SNAPSHOT_ISOLATION ON;

IF @ScenarioId IN
(
      'LAB-DEAD-001'
    , 'LAB-DEAD-002'
    , 'LAB-DEAD-003'
    , 'LAB-XE-001'
)
BEGIN
    CREATE EVENT SESSION [Lab001Wave3Session]
    ON SERVER
    ADD EVENT [sqlserver].[xml_deadlock_report],
    ADD EVENT [sqlserver].[blocked_process_report]
    ADD TARGET [package0].[ring_buffer]
    (
        SET max_events_limit = 64,
            max_memory = 2048
    )
    WITH
    (
          MAX_MEMORY = 4096 KB
        , EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS
        , MAX_DISPATCH_LATENCY = 1 SECONDS
        , TRACK_CAUSALITY = ON
        , STARTUP_STATE = OFF
    );

    ALTER EVENT SESSION [Lab001Wave3Session] ON SERVER STATE = START;
END;

IF @ScenarioId = 'LAB-MEM-003'
BEGIN
    CREATE RESOURCE POOL [Lab001Pool]
    WITH
    (
          MIN_CPU_PERCENT = 0
        , MAX_CPU_PERCENT = 50
        , MIN_MEMORY_PERCENT = 0
        , MAX_MEMORY_PERCENT = 25
    );

    CREATE WORKLOAD GROUP [Lab001Group]
    WITH
    (
          IMPORTANCE = MEDIUM
        , REQUEST_MAX_MEMORY_GRANT_PERCENT = 10
        , REQUEST_MAX_CPU_TIME_SEC = 30
        , MAX_DOP = 2
    )
    USING [Lab001Pool];

    ALTER RESOURCE GOVERNOR RECONFIGURE;
END;

IF @ScenarioId = 'LAB-MEM-002'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
CREATE TABLE [dbo].[BufferPoolWorkload]
(
      [SyntheticId] int IDENTITY(1,1) NOT NULL
        CONSTRAINT [PK_BufferPoolWorkload] PRIMARY KEY
    , [Payload] char(8000) NOT NULL
);

;WITH [n] AS
(
    SELECT TOP (32768)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[BufferPoolWorkload] ([Payload])
SELECT REPLICATE(CONVERT(char(1), ([n] + 1701) % 10), 8000)
FROM [n];';
END;

IF @ScenarioId = 'LAB-TEMP-005'
BEGIN
    IF @ProductMajorVersion < 17
        THROW 55302, N'LAB-TEMP-005 requires SQL Server 2025.', 1;

    EXEC [sys].[sp_executesql]
        N'
CREATE RESOURCE POOL [Lab001Pool]
WITH
(
      MIN_CPU_PERCENT = 0
    , MAX_CPU_PERCENT = 50
    , MIN_MEMORY_PERCENT = 0
    , MAX_MEMORY_PERCENT = 25
);

CREATE WORKLOAD GROUP [Lab001Group]
WITH
(
      IMPORTANCE = MEDIUM
    , REQUEST_MAX_MEMORY_GRANT_PERCENT = 10
    , GROUP_MAX_TEMPDB_DATA_MB = 32
)
USING [Lab001Pool];

ALTER RESOURCE GOVERNOR RECONFIGURE;';
END;

IF @ScenarioId IN ('LAB-IO-004', 'LAB-CAP-001')
BEGIN
    DECLARE @DataFileName sysname =
    (
        SELECT [name]
        FROM [sys].[master_files]
        WHERE [database_id] = DB_ID(N'Lab001Wave3')
          AND [type] = 0
    );
    DECLARE @InitialDataPages bigint =
    (
        SELECT [size]
        FROM [sys].[master_files]
        WHERE [database_id] = DB_ID(N'Lab001Wave3')
          AND [file_id] = 1
    );
    DECLARE @FileSql nvarchar(max) =
        N'ALTER DATABASE [Lab001Wave3] MODIFY FILE
          (NAME = ' + QUOTENAME(@DataFileName, '''') +
        N', FILEGROWTH = 1 MB, MAXSIZE = 96 MB);';
    EXEC [sys].[sp_executesql] @FileSql;

    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
INSERT [dbo].[LabState] ([StateName], [StateValue])
VALUES (N''InitialDataPages'', CONVERT(nvarchar(40), @InitialDataPages));

;WITH [n] AS
(
    SELECT TOP (60000)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[Workload] ([SyntheticId], [GroupId], [Amount], [Payload])
SELECT
      100000 + CONVERT(int, [n])
    , 1701
    , CONVERT(int, [n])
    , REPLICATE(''G'', 256)
FROM [n];'
        , N'@InitialDataPages bigint'
        , @InitialDataPages = @InitialDataPages;
END;

IF @ScenarioId = 'LAB-LOG-002'
BEGIN
    DECLARE @LogFileName sysname =
    (
        SELECT [name]
        FROM [sys].[master_files]
        WHERE [database_id] = DB_ID(N'Lab001Wave3')
          AND [type] = 1
    );
    DECLARE @InitialLogPages bigint =
    (
        SELECT [size]
        FROM [sys].[master_files]
        WHERE [database_id] = DB_ID(N'Lab001Wave3')
          AND [type] = 1
    );
    DECLARE @LogSql nvarchar(max) =
        N'ALTER DATABASE [Lab001Wave3] MODIFY FILE
          (NAME = ' + QUOTENAME(@LogFileName, '''') +
        N', FILEGROWTH = 1 MB, MAXSIZE = 96 MB);';
    EXEC [sys].[sp_executesql] @LogSql;

    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
INSERT [dbo].[LabState] ([StateName], [StateValue])
VALUES (N''InitialLogPages'', CONVERT(nvarchar(40), @InitialLogPages));

BEGIN TRANSACTION;
;WITH [n] AS
(
    SELECT TOP (8000)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[LogWorkload] ([Payload])
SELECT REPLICATE(CONVERT(varchar(1), (1701 + [n]) % 10), 4000)
FROM [n];
COMMIT TRANSACTION;'
        , N'@InitialLogPages bigint'
        , @InitialLogPages = @InitialLogPages;
END;

IF @ScenarioId LIKE 'LAB-LATCH-%'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
CREATE TABLE [dbo].[LatchSequential]
(
      [SyntheticId] bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT [PK_LatchSequential]
        PRIMARY KEY CLUSTERED
    , [WorkerId] int NOT NULL
    , [Payload] char(200) NOT NULL
);

CREATE TABLE [dbo].[LatchOptimized]
(
      [SyntheticId] bigint IDENTITY(1,1) NOT NULL
    , [WorkerId] int NOT NULL
    , [Payload] char(200) NOT NULL
    , CONSTRAINT [PK_LatchOptimized]
      PRIMARY KEY CLUSTERED ([SyntheticId])
      WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
);

CREATE TABLE [dbo].[LatchDistributed]
(
      [SyntheticId] bigint NOT NULL
    , [WorkerId] int NOT NULL
    , [Payload] char(200) NOT NULL
    , CONSTRAINT [PK_LatchDistributed]
      PRIMARY KEY CLUSTERED ([SyntheticId])
);

CREATE TABLE [dbo].[LatchHeap]
(
      [SyntheticId] bigint NOT NULL
    , [WorkerId] int NOT NULL
    , [Payload] char(200) NOT NULL
);';
END;

IF @ScenarioId LIKE 'LAB-PLAN-%'
   OR @ScenarioId LIKE 'LAB-QS-%'
   OR @ScenarioId = 'LAB-EXECPLAN-001'
BEGIN
    ALTER DATABASE [Lab001Wave3]
    SET QUERY_STORE = ON
    (
          OPERATION_MODE = READ_WRITE
        , QUERY_CAPTURE_MODE = ALL
        , DATA_FLUSH_INTERVAL_SECONDS = 1
        , INTERVAL_LENGTH_MINUTES = 1
        , MAX_STORAGE_SIZE_MB = 64
        , CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 1)
    );

    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
CREATE TABLE [dbo].[PlanWorkload]
(
      [SyntheticId] int NOT NULL
        CONSTRAINT [PK_PlanWorkload] PRIMARY KEY
    , [GroupId] int NOT NULL
    , [Payload] char(128) NOT NULL
);

;WITH [n] AS
(
    SELECT TOP (12000)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[PlanWorkload] ([SyntheticId], [GroupId], [Payload])
SELECT
      CONVERT(int, [n])
    , CASE WHEN [n] <= 11800 THEN 1 ELSE CONVERT(int, [n] % 101) END
    , REPLICATE(CONVERT(varchar(1), [n] % 10), 128)
FROM [n];

CREATE INDEX [IX_PlanWorkload_GroupId]
ON [dbo].[PlanWorkload] ([GroupId]);

EXEC [sys].[sp_executesql]
    N''CREATE OR ALTER PROCEDURE [dbo].[LabSkewProcedure]
          @GroupId int
      AS
      BEGIN
          SET NOCOUNT ON;
          SELECT [SyntheticId], [Payload]
          FROM [dbo].[PlanWorkload]
          WHERE [GroupId] = @GroupId
          OPTION (MAXDOP 2);
      END;'';

EXEC [dbo].[LabSkewProcedure] @GroupId = 1;
EXEC [dbo].[LabSkewProcedure] @GroupId = 97;';
END;

IF @ScenarioId = 'LAB-PLAN-002'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
UPDATE STATISTICS [dbo].[PlanWorkload] [IX_PlanWorkload_GroupId]
WITH FULLSCAN;

;WITH [n] AS
(
    SELECT TOP (6000)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[PlanWorkload] ([SyntheticId], [GroupId], [Payload])
SELECT
      20000 + CONVERT(int, [n])
    , 1701
    , REPLICATE(''S'', 128)
FROM [n];';
END;

IF @ScenarioId = 'LAB-PLAN-003'
BEGIN
    DECLARE @Ordinal int = 1;
    WHILE @Ordinal <= 40
    BEGIN
        DECLARE @AdHocSql nvarchar(max) = CONCAT
        (
              N'SELECT COUNT_BIG(*) AS [SyntheticCount]
                FROM [Lab001Wave3].[dbo].[PlanWorkload]
                WHERE [GroupId] = '
            , CONVERT(varchar(11), @Ordinal)
            , N'; /* LAB001_WAVE3_ADHOC_'
            , RIGHT(CONCAT('000', @Ordinal), 3)
            , N' */'
        );
        EXEC [sys].[sp_executesql] @AdHocSql;
        SET @Ordinal += 1;
    END;
END;

IF @ScenarioId = 'LAB-PLAN-004'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
EXEC [sys].[sp_executesql]
    N''CREATE OR ALTER PROCEDURE [dbo].[LabRecompileProcedure]
          @GroupId int
      WITH RECOMPILE
      AS
      BEGIN
          SET NOCOUNT ON;
          SELECT COUNT_BIG(*) AS [SyntheticCount]
          FROM [dbo].[PlanWorkload]
          WHERE [GroupId] = @GroupId;
      END;'';

DECLARE @i int = 1;
WHILE @i <= 16
BEGIN
    EXEC [dbo].[LabRecompileProcedure] @GroupId = @i;
    SET @i += 1;
END;

INSERT [dbo].[LabState] ([StateName], [StateValue])
VALUES (N''RecompileExecutions'', N''16'');';
END;

IF @ScenarioId = 'LAB-PLAN-005'
BEGIN
    IF @ProductMajorVersion < 16
        THROW 55303, N'LAB-PLAN-005 requires SQL Server 2022 or newer.', 1;

    IF @ProductMajorVersion >= 17
        ALTER DATABASE [Lab001Wave3] SET COMPATIBILITY_LEVEL = 170;
    ELSE
        ALTER DATABASE [Lab001Wave3] SET COMPATIBILITY_LEVEL = 160;

    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
EXEC [sys].[sp_executesql]
    N''CREATE OR ALTER PROCEDURE [dbo].[LabAdaptiveProcedure]
          @GroupId int = NULL
      AS
      BEGIN
          SET NOCOUNT ON;
          SELECT COUNT_BIG(*) AS [SyntheticCount]
          FROM [dbo].[PlanWorkload]
          WHERE [GroupId] = @GroupId OR @GroupId IS NULL;
      END;'';

EXEC [dbo].[LabAdaptiveProcedure] @GroupId = NULL;
EXEC [dbo].[LabAdaptiveProcedure] @GroupId = 97;
EXEC [sys].[sp_query_store_flush_db];';
END;

IF @ScenarioId LIKE 'LAB-QS-%'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
EXEC [sys].[sp_executesql]
    N''CREATE OR ALTER PROCEDURE [dbo].[LabQueryStoreProcedure]
          @GroupId int
      AS
      BEGIN
          SET NOCOUNT ON;
          SELECT COUNT_BIG(*) AS [SyntheticCount]
          FROM [dbo].[PlanWorkload]
          WHERE [GroupId] = @GroupId;
          /* LAB001_WAVE3_QUERY_STORE */
      END;'';

DECLARE @i int = 1;
WHILE @i <= 20
BEGIN
    EXEC [dbo].[LabQueryStoreProcedure]
          @GroupId = CASE WHEN @i % 2 = 0 THEN 1 ELSE 97 END;
    SET @i += 1;
END;
EXEC [sys].[sp_query_store_flush_db];';
END;

IF @ScenarioId = 'LAB-QS-002'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
DECLARE @QueryId bigint;
DECLARE @PlanId bigint;

SELECT TOP (1)
       @QueryId = [q].[query_id],
       @PlanId = [p].[plan_id]
FROM [sys].[query_store_query] AS [q]
INNER JOIN [sys].[query_store_plan] AS [p]
    ON [p].[query_id] = [q].[query_id]
WHERE [q].[object_id] = OBJECT_ID(N''dbo.LabQueryStoreProcedure'')
ORDER BY [p].[last_execution_time] DESC, [p].[plan_id] DESC;

IF @QueryId IS NULL OR @PlanId IS NULL
    THROW 55304, N''Query Store did not capture the synthetic procedure.'', 1;

EXEC [sys].[sp_query_store_force_plan]
      @query_id = @QueryId
    , @plan_id = @PlanId;';
END;

IF @ScenarioId LIKE 'LAB-IDX-%'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
CREATE TABLE [dbo].[IndexWorkload]
(
      [SyntheticId] int NOT NULL
    , [GroupId] int NOT NULL
    , [Payload] char(256) NOT NULL
    , CONSTRAINT [PK_IndexWorkload]
      PRIMARY KEY CLUSTERED ([SyntheticId])
);

;WITH [n] AS
(
    SELECT TOP (12000)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[IndexWorkload] ([SyntheticId], [GroupId], [Payload])
SELECT
      CONVERT(int, ([n] * 7919) % 20011)
    , CONVERT(int, [n] % 101)
    , REPLICATE(CONVERT(varchar(1), [n] % 10), 256)
FROM [n];';
END;

IF @ScenarioId = 'LAB-IDX-001'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
DELETE [dbo].[IndexWorkload]
WHERE [SyntheticId] % 7 = 0;

UPDATE [dbo].[IndexWorkload]
SET [Payload] = REPLICATE(''F'', 256)
WHERE [SyntheticId] % 11 = 0;';
END;

IF @ScenarioId = 'LAB-IDX-002'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
CREATE INDEX [IX_IndexWorkload_GroupId_A]
ON [dbo].[IndexWorkload] ([GroupId])
INCLUDE ([Payload]);

CREATE INDEX [IX_IndexWorkload_GroupId_B]
ON [dbo].[IndexWorkload] ([GroupId], [SyntheticId])
INCLUDE ([Payload]);';
END;

IF @ScenarioId = 'LAB-IDX-003'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
DECLARE @i int = 1;
WHILE @i <= 24
BEGIN
    SELECT SUM([SyntheticId]) AS [SyntheticSum]
    FROM [dbo].[IndexWorkload]
    WHERE [GroupId] = 97
      AND [Payload] LIKE ''9%'';
    SET @i += 1;
END;';
END;

IF @ScenarioId = 'LAB-COL-001'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
CREATE TABLE [dbo].[ColumnstoreWorkload]
(
      [SyntheticId] int NOT NULL
    , [GroupId] int NOT NULL
    , [Amount] decimal(18,2) NOT NULL
    , [Payload] char(32) NOT NULL
);

CREATE CLUSTERED COLUMNSTORE INDEX [CCI_ColumnstoreWorkload]
ON [dbo].[ColumnstoreWorkload];

;WITH [n] AS
(
    SELECT TOP (110000)
           ROW_NUMBER() OVER (ORDER BY [a].[object_id], [b].[object_id]) AS [n]
    FROM [sys].[all_objects] AS [a]
    CROSS JOIN [sys].[all_objects] AS [b]
)
INSERT [dbo].[ColumnstoreWorkload]
(
      [SyntheticId]
    , [GroupId]
    , [Amount]
    , [Payload]
)
SELECT
      CONVERT(int, [n])
    , CONVERT(int, [n] % 101)
    , CONVERT(decimal(18,2), [n] % 10000)
    , CONVERT(char(32), CONCAT(''SYNTHETIC-'', [n] % 100))
FROM [n];

ALTER INDEX [CCI_ColumnstoreWorkload]
ON [dbo].[ColumnstoreWorkload]
REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);';
END;

IF @ScenarioId = 'LAB-VECTOR-001'
BEGIN
    IF @ProductMajorVersion < 17
        THROW 55305, N'LAB-VECTOR-001 requires SQL Server 2025.', 1;

    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;

CREATE TABLE [dbo].[VectorWorkload]
(
      [SyntheticId] int NOT NULL
        CONSTRAINT [PK_VectorWorkload] PRIMARY KEY
    , [Embedding] vector(5) NOT NULL
);

INSERT [dbo].[VectorWorkload] ([SyntheticId], [Embedding])
SELECT
      [value]
    , CAST
      (
          JSON_ARRAY
          (
                CAST([value] * 0.01 AS float)
              , CAST([value] * 0.02 AS float)
              , CAST([value] * 0.03 AS float)
              , CAST([value] * 0.04 AS float)
              , CAST([value] * 0.05 AS float)
          )
          AS vector(5)
      )
FROM GENERATE_SERIES(1, 100);

CREATE VECTOR INDEX [VIX_VectorWorkload_Embedding]
ON [dbo].[VectorWorkload] ([Embedding])
WITH (METRIC = ''COSINE'', TYPE = ''DISKANN'');';
END;

IF @ScenarioId = 'LAB-EXECPLAN-001'
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
        N'
SELECT SUM([SyntheticId]) AS [SyntheticSum]
FROM [dbo].[PlanWorkload]
WHERE [GroupId] = 97
OPTION (MAXDOP 2);
/* LAB001_WAVE3_EXECPLAN */';
END;

SELECT CONCAT
(
      N'LAB_SETUP_JSON='
    , (
        SELECT
              @ScenarioId AS [ScenarioId]
            , N'PASS' AS [Status]
            , @ProductMajorVersion AS [ProductMajorVersion]
            , 1701 AS [FixedSeed]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
      )
);
