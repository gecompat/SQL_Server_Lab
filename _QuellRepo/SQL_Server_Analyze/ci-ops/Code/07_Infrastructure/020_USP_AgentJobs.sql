USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_AgentJobs
Version      : 2.0.0
Stand        : 2026-07-15
Typ          : Stored Procedure
Zweck        : Analysiert Agent-Jobs, Laufzeitstatus, letzte Ausführung, Fehler,
               Schedules und Owner.
SQL-Version  : SQL Server 2019 oder neuer.
Filter       : @JobNames als bracket-aware Pipe-Liste oder alternativ
               @JobNamePattern mit LIKE/regex/regexi.
Resultsets   : RAW oder CONSOLE: Modulstatus, Jobs, Jobsteps. NONE: keine.
JSON         : meta, jobs, steps.
Änderungen   : 2.0.0 - Mehrfachfilter, Patternvertrag und Ausgabeadapter.
               1.0.0 - Erstfassung Phase 6.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_AgentJobs]
      @JobNames          nvarchar(max)  = NULL
    , @JobNamePattern    nvarchar(4000) = NULL
    , @NurProblematisch  bit            = 0
    , @LongRunningMinutes int           = 60
    , @MaxZeilen         int            = 2000
    , @ResultSetArt      varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen      bit            = 0
    , @Json              nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen    bit            = 1
    , @Hilfe             bit            = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @Json = NULL;

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'jobs',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @PatternMode varchar(8);
    DECLARE @PatternValue nvarchar(4000);
    DECLARE @RegexFlags varchar(8);
    DECLARE @PatternIsValid bit;
    DECLARE @EffectiveMaxZeilen bigint =
        CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen = 0
             THEN CONVERT(bigint, 9223372036854775807)
             ELSE CONVERT(bigint, @MaxZeilen) END;

    SELECT
          @PatternMode = [PatternMode]
        , @PatternValue = [PatternValue]
        , @RegexFlags = [RegexFlags]
        , @PatternIsValid = [IsValid]
    FROM [monitor].[TVF_ParsePattern](@JobNamePattern);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_AgentJobs';
        PRINT N'@JobNames: exakter Jobname oder bracket-aware Pipe-Liste, zum Beispiel N''[DWH Load]|[Index Maintenance]''.';
        PRINT N'@JobNamePattern: genau ein LIKE-/Regex-Pattern; exakte Liste und Pattern sind gegenseitig exklusiv.';
        PRINT N'@NurProblematisch bit=0; @LongRunningMinutes int=60.';
        PRINT N'@MaxZeilen: positive Werte begrenzen; NULL/0 = unbegrenzt.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE case-insensitiv; @JsonErzeugen=1 setzt @Json OUTPUT.';
        RETURN;
    END;

    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorNumber int = NULL;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;

    CREATE TABLE [#AgentJobs_JobNameFilter]
    (
          [ItemOrdinal] int NOT NULL
        , [JobName] sysname COLLATE SQL_Latin1_General_CP1_CS_AS NOT NULL
        , CONSTRAINT [PK_JobNameFilter] PRIMARY KEY ([JobName])
    );

    CREATE TABLE [#AgentJobs_Jobs]
    (
          [JobId] uniqueidentifier
        , [JobName] sysname
        , [Enabled] bit
        , [OwnerName] sysname
        , [CategoryName] sysname
        , [IsRunning] bit
        , [RunStart] datetime
        , [RunningMinutes] int
        , [LastRunDateTime] datetime
        , [LastRunStatus] int
        , [LastRunStatusDesc] nvarchar(60)
        , [LastRunDurationSeconds] int
        , [LastMessage] nvarchar(4000)
        , [ScheduleCount] int
        , [EnabledScheduleCount] int
        , [StepCount] int
        , [ProblemCode] varchar(100)
    );

    CREATE TABLE [#AgentJobs_Steps]
    (
          [JobName] sysname
        , [StepId] int
        , [StepName] sysname
        , [Subsystem] nvarchar(40)
        , [LastRunOutcome] int
        , [LastRunOutcomeDesc] nvarchar(60)
        , [LastRunDateTime] datetime
        , [LastRunDurationSeconds] int
        , [LastRunRetries] int
        , [LastRunMessage] nvarchar(4000)
    );

    IF @JobNames IS NOT NULL
    BEGIN
        INSERT [#AgentJobs_JobNameFilter]([ItemOrdinal], [JobName])
        SELECT [ItemOrdinal], [NameValue]
        FROM [monitor].[TVF_ParseSqlNameList](@JobNames)
        WHERE [IsValid] = 1;
    END;

    IF @MaxZeilen < 0
       OR @LongRunningMinutes < 1
       OR @ResultSetArtNormalisiert NOT IN ('RAW', 'CONSOLE', 'NONE')
       OR @PatternIsValid = 0
       OR (@JobNames IS NOT NULL AND @JobNamePattern IS NOT NULL)
       OR (@JobNames IS NOT NULL AND EXISTS
          (SELECT 1 FROM [monitor].[TVF_ParseSqlNameList](@JobNames) WHERE [IsValid] = 0))
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @IsPartial = 1;
        SET @ErrorMessage = N'Ungültige Filter-, Grenzwert- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
       AND @PatternMode IN ('REGEX', 'REGEXI')
       AND
       (
           TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) < 17
           OR NOT EXISTS
              (
                  SELECT 1
                  FROM [master].[sys].[databases] AS [d] WITH (NOLOCK)
                  WHERE [d].[database_id] = DB_ID()
                    AND [d].[compatibility_level] >= 170
              )
       )
    BEGIN
        SET @StatusCode = 'UNAVAILABLE_FEATURE';
        SET @IsPartial = 1;
        SET @ErrorMessage = N'Regex benötigt SQL Server 2025 und Compatibility Level 170 für die Installationsdatenbank.';
    END;

    SET LOCK_TIMEOUT 0;

    IF @StatusCode = 'AVAILABLE'
    BEGIN TRY
        ;WITH [A] AS
        (
            SELECT [ja].*, ROW_NUMBER() OVER
                   (PARTITION BY [ja].[job_id] ORDER BY [ja].[session_id] DESC) AS [rn]
            FROM [msdb].[dbo].[sysjobactivity] AS [ja] WITH (NOLOCK)
        ),
        [H] AS
        (
            SELECT [h].*, ROW_NUMBER() OVER
                   (PARTITION BY [h].[job_id] ORDER BY [h].[instance_id] DESC) AS [rn]
            FROM [msdb].[dbo].[sysjobhistory] AS [h] WITH (NOLOCK)
            WHERE [h].[step_id] = 0
        ),
        [S] AS
        (
            SELECT
                  [js].[job_id]
                , COUNT_BIG(*) AS [ScheduleCount]
                , SUM(CASE WHEN [sc].[enabled] = 1 THEN 1 ELSE 0 END) AS [EnabledScheduleCount]
            FROM [msdb].[dbo].[sysjobschedules] AS [js] WITH (NOLOCK)
            JOIN [msdb].[dbo].[sysschedules] AS [sc] WITH (NOLOCK)
              ON [sc].[schedule_id] = [js].[schedule_id]
            GROUP BY [js].[job_id]
        )
        INSERT [#AgentJobs_Jobs]
        SELECT TOP (CASE WHEN @PatternMode IN ('REGEX', 'REGEXI') THEN CONVERT(bigint, 9223372036854775807) ELSE @EffectiveMaxZeilen END)
              [j].[job_id]
            , [j].[name]
            , [j].[enabled]
            , SUSER_SNAME([j].[owner_sid])
            , [c].[name]
            , CONVERT(bit, CASE WHEN [a].[start_execution_date] IS NOT NULL AND [a].[stop_execution_date] IS NULL THEN 1 ELSE 0 END)
            , [a].[start_execution_date]
            , CASE WHEN [a].[start_execution_date] IS NOT NULL AND [a].[stop_execution_date] IS NULL
                   THEN DATEDIFF(MINUTE, [a].[start_execution_date], GETDATE()) END
            , CASE WHEN [h].[run_date] > 0 THEN [msdb].[dbo].[agent_datetime]([h].[run_date], [h].[run_time]) END
            , [h].[run_status]
            , CASE [h].[run_status] WHEN 0 THEN N'FAILED' WHEN 1 THEN N'SUCCEEDED'
                   WHEN 2 THEN N'RETRY' WHEN 3 THEN N'CANCELED' WHEN 4 THEN N'IN_PROGRESS' END
            , ([h].[run_duration] / 10000) * 3600
              + (([h].[run_duration] % 10000) / 100) * 60
              + ([h].[run_duration] % 100)
            , [h].[message]
            , CONVERT(int, COALESCE([s].[ScheduleCount], 0))
            , CONVERT(int, COALESCE([s].[EnabledScheduleCount], 0))
            , (SELECT COUNT_BIG(*) FROM [msdb].[dbo].[sysjobsteps] AS [st] WITH (NOLOCK) WHERE [st].[job_id] = [j].[job_id])
            , CASE WHEN [j].[enabled] = 0 THEN 'DISABLED'
                   WHEN [a].[start_execution_date] IS NOT NULL AND [a].[stop_execution_date] IS NULL
                    AND DATEDIFF(MINUTE, [a].[start_execution_date], GETDATE()) >= @LongRunningMinutes THEN 'LONG_RUNNING'
                   WHEN [h].[run_status] = 0 THEN 'LAST_FAILED'
                   WHEN COALESCE([s].[ScheduleCount], 0) = 0 THEN 'NO_SCHEDULE'
                   WHEN COALESCE([s].[EnabledScheduleCount], 0) = 0 THEN 'NO_ENABLED_SCHEDULE' END
        FROM [msdb].[dbo].[sysjobs] AS [j] WITH (NOLOCK)
        LEFT JOIN [msdb].[dbo].[syscategories] AS [c] WITH (NOLOCK)
          ON [c].[category_id] = [j].[category_id]
        LEFT JOIN [A] AS [a] ON [a].[job_id] = [j].[job_id] AND [a].[rn] = 1
        LEFT JOIN [H] AS [h] ON [h].[job_id] = [j].[job_id] AND [h].[rn] = 1
        LEFT JOIN [S] AS [s] ON [s].[job_id] = [j].[job_id]
        WHERE
            (
                NOT EXISTS (SELECT 1 FROM [#AgentJobs_JobNameFilter])
                OR EXISTS
                   (
                       SELECT 1
                       FROM [#AgentJobs_JobNameFilter] AS [f]
                       WHERE [f].[JobName] = [j].[name] COLLATE SQL_Latin1_General_CP1_CS_AS
                   )
            )
          AND
            (
                @PatternMode IN ('NONE', 'REGEX', 'REGEXI')
                OR [j].[name] COLLATE SQL_Latin1_General_CP1_CS_AS
                   LIKE @PatternValue COLLATE SQL_Latin1_General_CP1_CS_AS
            )
          AND
            (
                @NurProblematisch = 0
                OR [j].[enabled] = 0
                OR [h].[run_status] = 0
                OR COALESCE([s].[ScheduleCount], 0) = 0
                OR COALESCE([s].[EnabledScheduleCount], 0) = 0
                OR ([a].[start_execution_date] IS NOT NULL AND [a].[stop_execution_date] IS NULL
                    AND DATEDIFF(MINUTE, [a].[start_execution_date], GETDATE()) >= @LongRunningMinutes)
            )
        ORDER BY
              CASE WHEN [a].[start_execution_date] IS NOT NULL AND [a].[stop_execution_date] IS NULL THEN 0 ELSE 1 END
            , [j].[name];

        IF @PatternMode IN ('REGEX', 'REGEXI')
        BEGIN
            DECLARE @RegexSql nvarchar(max) = N'DELETE [j]
FROM [#AgentJobs_Jobs] AS [j]
WHERE NOT REGEXP_LIKE([j].[JobName], @Pattern, @Flags);';

            EXEC [sys].[sp_executesql]
                  @RegexSql
                , N'@Pattern nvarchar(4000), @Flags varchar(8)'
                , @Pattern = @PatternValue
                , @Flags = @RegexFlags;
        END;

        IF @EffectiveMaxZeilen < 9223372036854775807
        BEGIN
            ;WITH [D] AS
            (
                SELECT
                      [JobId]
                    , ROW_NUMBER() OVER
                      (ORDER BY CASE WHEN [ProblemCode] IS NULL THEN 1 ELSE 0 END, [JobName]) AS [rn]
                FROM [#AgentJobs_Jobs]
            )
            DELETE [j]
            FROM [#AgentJobs_Jobs] AS [j]
            JOIN [D] AS [d] ON [d].[JobId] = [j].[JobId]
            WHERE [d].[rn] > @EffectiveMaxZeilen;
        END;

        ;WITH [SH] AS
        (
            SELECT [h].*, ROW_NUMBER() OVER
                   (PARTITION BY [h].[job_id], [h].[step_id] ORDER BY [h].[instance_id] DESC) AS [rn]
            FROM [msdb].[dbo].[sysjobhistory] AS [h] WITH (NOLOCK)
            WHERE [h].[step_id] > 0
        )
        INSERT [#AgentJobs_Steps]
        SELECT TOP (@EffectiveMaxZeilen)
              [j].[name], [st].[step_id], [st].[step_name], [st].[subsystem], [h].[run_status]
            , CASE [h].[run_status] WHEN 0 THEN N'FAILED' WHEN 1 THEN N'SUCCEEDED'
                   WHEN 2 THEN N'RETRY' WHEN 3 THEN N'CANCELED' WHEN 4 THEN N'IN_PROGRESS' END
            , CASE WHEN [h].[run_date] > 0 THEN [msdb].[dbo].[agent_datetime]([h].[run_date], [h].[run_time]) END
            , ([h].[run_duration] / 10000) * 3600
              + (([h].[run_duration] % 10000) / 100) * 60
              + ([h].[run_duration] % 100)
            , [h].[retries_attempted], [h].[message]
        FROM [msdb].[dbo].[sysjobsteps] AS [st] WITH (NOLOCK)
        JOIN [msdb].[dbo].[sysjobs] AS [j] WITH (NOLOCK) ON [j].[job_id] = [st].[job_id]
        JOIN [#AgentJobs_Jobs] AS [selected] ON [selected].[JobId] = [j].[job_id]
        LEFT JOIN [SH] AS [h]
          ON [h].[job_id] = [st].[job_id]
         AND [h].[step_id] = [st].[step_id]
         AND [h].[rn] = 1
        WHERE @NurProblematisch = 0 OR [h].[run_status] IN (0, 2, 3)
        ORDER BY [j].[name], [st].[step_id];
    END TRY
    BEGIN CATCH
        SELECT
              @StatusCode = 'ERROR_HANDLED'
            , @IsPartial = 1
            , @ErrorNumber = ERROR_NUMBER()
            , @ErrorMessage = ERROR_MESSAGE();

        IF @PrintMeldungen = 1
            RAISERROR(N'Agentjobs konnten nicht vollständig gelesen werden: %s', 10, 1, @ErrorMessage) WITH NOWAIT;
    END CATCH;

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        SELECT
              @CollectionTimeUtc AS [CollectionTimeUtc]
            , CAST(N'monitor.USP_AgentJobs' AS nvarchar(256)) AS [ModuleName]
            , @StatusCode AS [StatusCode]
            , @IsPartial AS [IsPartial]
            , @ErrorNumber AS [ErrorNumber]
            , @ErrorMessage AS [ErrorMessage];

        IF @ResultSetArtNormalisiert = 'RAW'
        BEGIN
            SELECT * FROM [#AgentJobs_Jobs] ORDER BY CASE WHEN [ProblemCode] IS NULL THEN 1 ELSE 0 END, [JobName];
            SELECT * FROM [#AgentJobs_Steps] ORDER BY [JobName], [StepId];
        END;
        ELSE
        BEGIN
            SELECT
                  N'SQL-Agent-Job' AS [Ergebnis]
                , [JobName] AS [Job]
                , [Enabled] AS [Aktiv]
                , [IsRunning] AS [Läuft]
                , CASE WHEN [RunningMinutes] IS NULL THEN NULL ELSE CONCAT([RunningMinutes], N' min') END AS [Aktuelle Laufzeit]
                , [LastRunStatusDesc] AS [Letzter Status]
                , CASE WHEN [LastRunDurationSeconds] IS NULL THEN NULL ELSE CONCAT([LastRunDurationSeconds], N' s') END AS [Letzte Laufzeit]
                , [ProblemCode] AS [Problem]
                , [OwnerName] AS [Owner]
                , [CategoryName] AS [Kategorie]
                , [ScheduleCount] AS [Schedules]
                , [EnabledScheduleCount] AS [Aktive Schedules]
                , [StepCount] AS [Steps]
                , [LastMessage] AS [Letzte Meldung]
            FROM [#AgentJobs_Jobs]
            ORDER BY CASE WHEN [ProblemCode] IS NULL THEN 1 ELSE 0 END, [JobName];

            SELECT
                  N'SQL-Agent-Jobstep' AS [Ergebnis]
                , [JobName] AS [Job]
                , [StepId] AS [Step]
                , [StepName] AS [Stepname]
                , [Subsystem]
                , [LastRunOutcomeDesc] AS [Letzter Status]
                , [LastRunDateTime] AS [Letzte Ausführung]
                , CASE WHEN [LastRunDurationSeconds] IS NULL THEN NULL ELSE CONCAT([LastRunDurationSeconds], N' s') END AS [Laufzeit]
                , [LastRunRetries] AS [Retries]
                , [LastRunMessage] AS [Meldung]
            FROM [#AgentJobs_Steps]
            ORDER BY [JobName], [StepId];
        END;
    END;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @MetaJson nvarchar(max) =
        (
            SELECT
                  N'AgentJobs' AS [resultName]
                , 1 AS [schemaVersion]
                , @CollectionTimeUtc AS [generatedAtUtc]
                , @StatusCode AS [statusCode]
                , @IsPartial AS [isPartial]
                , @MaxZeilen AS [requestedMaxRows]
                , (SELECT COUNT_BIG(*) FROM [#AgentJobs_Jobs]) AS [jobCount]
                , (SELECT COUNT_BIG(*) FROM [#AgentJobs_Steps]) AS [stepCount]
                , @ErrorNumber AS [errorNumber]
                , @ErrorMessage AS [errorMessage]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );
        DECLARE @JobsJson nvarchar(max) =
            (SELECT * FROM [#AgentJobs_Jobs] ORDER BY CASE WHEN [ProblemCode] IS NULL THEN 1 ELSE 0 END, [JobName] FOR JSON PATH, INCLUDE_NULL_VALUES);
        DECLARE @StepsJson nvarchar(max) =
            (SELECT * FROM [#AgentJobs_Steps] ORDER BY [JobName], [StepId] FOR JSON PATH, INCLUDE_NULL_VALUES);

        SET @Json = CONCAT
        (
              N'{"meta":', COALESCE(@MetaJson, N'{}')
            , N',"jobs":', COALESCE(@JobsJson, N'[]')
            , N',"steps":', COALESCE(@StepsJson, N'[]')
            , N'}'
        );
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#AgentJobs_Jobs'
            , @ResultLabel=N'AgentJobs'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#AgentJobs_Jobs'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
