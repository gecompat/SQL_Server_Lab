:setvar ScenarioId "LAB-INVALID-000"
:setvar LabRunId "LAB-20000101T000000Z-00000000"

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ScenarioId varchar(40) = '$(ScenarioId)';
DECLARE @LabRunId varchar(40) = '$(LabRunId)';
DECLARE @ContextToken binary(128) =
    CONVERT(binary(128), HASHBYTES('SHA2_256', CONCAT(@LabRunId, '|', @ScenarioId)));
DECLARE @SessionId int;
DECLARE @Sql nvarchar(max);

DECLARE [OwnedSessions] CURSOR LOCAL FAST_FORWARD FOR
    SELECT [s].[session_id]
    FROM [sys].[dm_exec_sessions] AS [s]
    WHERE [s].[session_id] <> @@SPID
      AND [s].[context_info] = @ContextToken;

OPEN [OwnedSessions];
FETCH NEXT FROM [OwnedSessions] INTO @SessionId;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = CONCAT(N'KILL ', CONVERT(varchar(11), @SessionId), N';');
    BEGIN TRY
        EXEC [sys].[sp_executesql] @Sql;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 6104
            THROW;
    END CATCH;
    FETCH NEXT FROM [OwnedSessions] INTO @SessionId;
END;
CLOSE [OwnedSessions];
DEALLOCATE [OwnedSessions];

DECLARE @ResourceGovernorWasEnabled bit = 0;
DECLARE @DatabaseOwner nvarchar(128) = NULL;
DECLARE @NamedServerObjectExists bit =
    CASE
        WHEN EXISTS
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
        THEN 1
        ELSE 0
    END;

IF DB_ID(N'Lab001Wave3') IS NOT NULL
BEGIN
    EXEC [Lab001Wave3].[sys].[sp_executesql]
          N'
SELECT @Owner = TRY_CONVERT(nvarchar(128), [value])
FROM [sys].[extended_properties]
WHERE [class] = 0
  AND [name] = N''Lab001RunId'';

IF OBJECT_ID(N''dbo.LabState'', N''U'') IS NOT NULL
BEGIN
    SELECT @WasEnabled = TRY_CONVERT(bit, [StateValue])
    FROM [dbo].[LabState]
    WHERE [StateName] = N''ResourceGovernorWasEnabled'';
END;'
        , N'@Owner nvarchar(128) OUTPUT, @WasEnabled bit OUTPUT'
        , @Owner = @DatabaseOwner OUTPUT
        , @WasEnabled = @ResourceGovernorWasEnabled OUTPUT;

    IF @DatabaseOwner <> @LabRunId
        THROW 55390, N'Cleanup refused a database without the exact run marker.', 1;
END;
ELSE IF @NamedServerObjectExists = 1
    THROW 55393, N'Cleanup refused an unowned fixed server-object name.', 1;

IF EXISTS
(
    SELECT 1
    FROM [sys].[server_event_sessions]
    WHERE [name] = N'Lab001Wave3Session'
)
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM [sys].[dm_xe_sessions]
        WHERE [name] = N'Lab001Wave3Session'
    )
        ALTER EVENT SESSION [Lab001Wave3Session] ON SERVER STATE = STOP;

    DROP EVENT SESSION [Lab001Wave3Session] ON SERVER;
END;

IF EXISTS
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
BEGIN
    ALTER RESOURCE GOVERNOR DISABLE;

    IF EXISTS
    (
        SELECT 1
        FROM [sys].[resource_governor_workload_groups]
        WHERE [name] = N'Lab001Group'
    )
        DROP WORKLOAD GROUP [Lab001Group];

    IF EXISTS
    (
        SELECT 1
        FROM [sys].[resource_governor_resource_pools]
        WHERE [name] = N'Lab001Pool'
    )
        DROP RESOURCE POOL [Lab001Pool];

    ALTER RESOURCE GOVERNOR RECONFIGURE;
    IF @ResourceGovernorWasEnabled = 0
        ALTER RESOURCE GOVERNOR DISABLE;
END;

IF DB_ID(N'Lab001Wave3') IS NOT NULL
BEGIN
    DECLARE @PlanHandle varbinary(64);
    DECLARE [OwnedPlans] CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT [cp].[plan_handle]
        FROM [sys].[dm_exec_cached_plans] AS [cp]
        CROSS APPLY [sys].[dm_exec_sql_text]([cp].[plan_handle]) AS [st]
        WHERE [st].[dbid] = DB_ID(N'Lab001Wave3')
           OR [st].[text] LIKE N'%LAB001_WAVE3%';

    OPEN [OwnedPlans];
    FETCH NEXT FROM [OwnedPlans] INTO @PlanHandle;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DBCC FREEPROCCACHE(@PlanHandle) WITH NO_INFOMSGS;
        FETCH NEXT FROM [OwnedPlans] INTO @PlanHandle;
    END;
    CLOSE [OwnedPlans];
    DEALLOCATE [OwnedPlans];

    ALTER DATABASE [Lab001Wave3] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [Lab001Wave3];
END;

IF EXISTS
(
    SELECT 1
    FROM [sys].[dm_exec_sessions]
    WHERE [context_info] = @ContextToken
)
    THROW 55391, N'Run-token sessions remain after cleanup.', 1;

IF DB_ID(N'Lab001Wave3') IS NOT NULL
    THROW 55392, N'The synthetic scenario database remains after cleanup.', 1;

SELECT CONCAT
(
      N'LAB_CLEANUP_JSON='
    , (
        SELECT
              @ScenarioId AS [ScenarioId]
            , N'PASS' AS [Status]
            , N'EXACT_SYNTHETIC_SCOPE' AS [ResetPolicy]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
      )
);
