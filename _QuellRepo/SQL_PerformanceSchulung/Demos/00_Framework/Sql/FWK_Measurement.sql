/*
    FWK-004 reference implementation
    Installs session-scoped measurement objects in the current,
    FWK-002-marked test database.

    The implementation stores no query text, host name, login name,
    program name, server name, plan or file path.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_ID() <= 4
    THROW 51001, 'FAIL_SAFETY: FWK-004 darf nicht in einer Systemdatenbank installiert werden.', 1;

DECLARE @ProjectMarker nvarchar(128);
DECLARE @ContractMarker nvarchar(128);

SELECT
    @ProjectMarker = MAX(CASE WHEN ep.name = N'SQLPERF.Project' THEN CONVERT(nvarchar(128), ep.value) END),
    @ContractMarker = MAX(CASE WHEN ep.name = N'SQLPERF.ContractVersion' THEN CONVERT(nvarchar(128), ep.value) END)
FROM sys.extended_properties AS ep
WHERE ep.class = 0
  AND ep.major_id = 0
  AND ep.minor_id = 0
  AND ep.name IN (N'SQLPERF.Project', N'SQLPERF.ContractVersion');

IF @ProjectMarker <> N'SQL_PerformanceSchulung'
   OR @ContractMarker <> N'1.0'
    THROW 51001, 'FAIL_SAFETY: Die aktuelle Datenbank besitzt nicht die erwarteten FWK-002-Marker.', 1;

IF SCHEMA_ID(N'lab') IS NULL
    EXEC(N'CREATE SCHEMA [lab] AUTHORIZATION [dbo];');
GO

IF OBJECT_ID(N'lab.MeasurementRun', N'U') IS NULL
BEGIN
    CREATE TABLE lab.MeasurementRun
    (
        MeasurementRunId uniqueidentifier NOT NULL,
        DemoId varchar(7) NOT NULL,
        RunToken varchar(20) NOT NULL,
        Phase varchar(16) NOT NULL,
        Iteration int NOT NULL,
        SessionId smallint NOT NULL,
        StartedAtUtc datetime2(3) NOT NULL,
        EndedAtUtc datetime2(3) NULL,
        StartCpuMs bigint NOT NULL,
        EndCpuMs bigint NULL,
        StartReads bigint NOT NULL,
        EndReads bigint NULL,
        StartLogicalReads bigint NOT NULL,
        EndLogicalReads bigint NULL,
        StartWrites bigint NOT NULL,
        EndWrites bigint NULL,
        ElapsedMs bigint NULL,
        CpuMs bigint NULL,
        Reads bigint NULL,
        LogicalReads bigint NULL,
        Writes bigint NULL,
        ResultRows bigint NULL,
        WaitCaptureRequested bit NOT NULL,
        WaitCaptureOutcome varchar(8) NOT NULL,
        WaitCaptureCode varchar(64) NOT NULL,
        OverallOutcome varchar(8) NULL,
        OverallCode varchar(64) NULL,
        CONSTRAINT PK_lab_MeasurementRun
            PRIMARY KEY CLUSTERED (MeasurementRunId),
        CONSTRAINT CK_lab_MeasurementRun_Phase
            CHECK (Phase IN ('BASELINE', 'DEMONSTRATION', 'MITIGATION', 'COMPARISON', 'WARMUP')),
        CONSTRAINT CK_lab_MeasurementRun_Iteration
            CHECK (Iteration >= 1)
    );
END;
GO

IF OBJECT_ID(N'lab.MeasurementWaitSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE lab.MeasurementWaitSnapshot
    (
        MeasurementRunId uniqueidentifier NOT NULL,
        SnapshotKind char(1) NOT NULL,
        WaitType nvarchar(60) NOT NULL,
        WaitingTasksCount bigint NOT NULL,
        WaitTimeMs bigint NOT NULL,
        SignalWaitTimeMs bigint NOT NULL,
        CONSTRAINT PK_lab_MeasurementWaitSnapshot
            PRIMARY KEY CLUSTERED (MeasurementRunId, SnapshotKind, WaitType),
        CONSTRAINT FK_lab_MeasurementWaitSnapshot_MeasurementRun
            FOREIGN KEY (MeasurementRunId)
            REFERENCES lab.MeasurementRun (MeasurementRunId),
        CONSTRAINT CK_lab_MeasurementWaitSnapshot_Kind
            CHECK (SnapshotKind IN ('B', 'E'))
    );
END;
GO

CREATE OR ALTER PROCEDURE lab.USP_BeginMeasurement
    @DemoId varchar(7),
    @RunToken varchar(20),
    @Phase varchar(16),
    @Iteration int,
    @CaptureSessionWaits bit = 1,
    @MeasurementRunId uniqueidentifier OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProjectMarker nvarchar(128);
    DECLARE @ContractMarker nvarchar(128);
    DECLARE @MarkerDemoId varchar(7);
    DECLARE @MarkerRunToken varchar(20);
    DECLARE @StartCpuMs bigint;
    DECLARE @StartReads bigint;
    DECLARE @StartLogicalReads bigint;
    DECLARE @StartWrites bigint;
    DECLARE @WaitOutcome varchar(8) = 'PASS';
    DECLARE @WaitCode varchar(64) = 'OK';

    SELECT
        @ProjectMarker = MAX(CASE WHEN ep.name = N'SQLPERF.Project' THEN CONVERT(nvarchar(128), ep.value) END),
        @ContractMarker = MAX(CASE WHEN ep.name = N'SQLPERF.ContractVersion' THEN CONVERT(nvarchar(128), ep.value) END),
        @MarkerDemoId = MAX(CASE WHEN ep.name = N'SQLPERF.DemoId' THEN CONVERT(varchar(7), ep.value) END),
        @MarkerRunToken = MAX(CASE WHEN ep.name = N'SQLPERF.RunToken' THEN CONVERT(varchar(20), ep.value) END)
    FROM sys.extended_properties AS ep
    WHERE ep.class = 0
      AND ep.major_id = 0
      AND ep.minor_id = 0
      AND ep.name IN
          (
              N'SQLPERF.Project',
              N'SQLPERF.ContractVersion',
              N'SQLPERF.DemoId',
              N'SQLPERF.RunToken'
          );

    IF DB_ID() <= 4
       OR @ProjectMarker <> N'SQL_PerformanceSchulung'
       OR @ContractMarker <> N'1.0'
       OR @MarkerDemoId <> @DemoId
       OR @MarkerRunToken <> @RunToken
        THROW 51001, 'FAIL_SAFETY: Die Messung wurde außerhalb des erwarteten markierten Demo-Kontexts angefordert.', 1;

    IF @Phase NOT IN ('BASELINE', 'DEMONSTRATION', 'MITIGATION', 'COMPARISON', 'WARMUP')
       OR @Iteration < 1
        THROW 51000, 'FAIL_CONTRACT: Phase oder Iteration ist ungültig.', 1;

    SELECT
        @StartCpuMs = CONVERT(bigint, s.cpu_time),
        @StartReads = CONVERT(bigint, s.reads),
        @StartLogicalReads = CONVERT(bigint, s.logical_reads),
        @StartWrites = CONVERT(bigint, s.writes)
    FROM sys.dm_exec_sessions AS s
    WHERE s.session_id = @@SPID;

    IF @StartCpuMs IS NULL
        THROW 51002, 'FAIL_STATE: Die Sessionzähler konnten nicht gelesen werden.', 1;

    SET @MeasurementRunId = NEWID();

    INSERT lab.MeasurementRun
    (
        MeasurementRunId,
        DemoId,
        RunToken,
        Phase,
        Iteration,
        SessionId,
        StartedAtUtc,
        StartCpuMs,
        StartReads,
        StartLogicalReads,
        StartWrites,
        WaitCaptureRequested,
        WaitCaptureOutcome,
        WaitCaptureCode
    )
    VALUES
    (
        @MeasurementRunId,
        @DemoId,
        @RunToken,
        @Phase,
        @Iteration,
        @@SPID,
        SYSUTCDATETIME(),
        @StartCpuMs,
        @StartReads,
        @StartLogicalReads,
        @StartWrites,
        @CaptureSessionWaits,
        @WaitOutcome,
        @WaitCode
    );

    IF @CaptureSessionWaits = 1
    BEGIN
        BEGIN TRY
            INSERT lab.MeasurementWaitSnapshot
            (
                MeasurementRunId,
                SnapshotKind,
                WaitType,
                WaitingTasksCount,
                WaitTimeMs,
                SignalWaitTimeMs
            )
            SELECT
                @MeasurementRunId,
                'B',
                ws.wait_type,
                ws.waiting_tasks_count,
                ws.wait_time_ms,
                ws.signal_wait_time_ms
            FROM sys.dm_exec_session_wait_stats AS ws
            WHERE ws.session_id = @@SPID;
        END TRY
        BEGIN CATCH
            SET @WaitOutcome = 'WARN';
            SET @WaitCode = 'WARN_RESOURCE_PROBE_APPROXIMATE';

            UPDATE lab.MeasurementRun
            SET
                WaitCaptureOutcome = @WaitOutcome,
                WaitCaptureCode = @WaitCode
            WHERE MeasurementRunId = @MeasurementRunId;
        END CATCH;
    END;

    SELECT
        Sequence = CONVERT(int, 1),
        Phase = CONVERT(varchar(20), 'MEASUREMENT'),
        CheckId = CONVERT(varchar(64), 'BEGIN'),
        Outcome = @WaitOutcome,
        Code = @WaitCode,
        ObservedValue = CONVERT(nvarchar(4000), @MeasurementRunId),
        RequiredValue = CONVERT(nvarchar(4000), N'gleiche Session bis USP_EndMeasurement'),
        Message = CONVERT
        (
            nvarchar(4000),
            CASE
                WHEN @WaitOutcome = 'PASS'
                    THEN N'Die sessionbezogene Messung wurde gestartet.'
                ELSE N'Die Messung wurde gestartet; sessionbezogene Waits sind nicht vollständig verfügbar.'
            END
        );
END;
GO

CREATE OR ALTER PROCEDURE lab.USP_EndMeasurement
    @DemoId varchar(7),
    @RunToken varchar(20),
    @MeasurementRunId uniqueidentifier,
    @ResultRows bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProjectMarker nvarchar(128);
    DECLARE @ContractMarker nvarchar(128);
    DECLARE @MarkerDemoId varchar(7);
    DECLARE @MarkerRunToken varchar(20);
    DECLARE @StoredDemoId varchar(7);
    DECLARE @StoredRunToken varchar(20);
    DECLARE @StoredSessionId smallint;
    DECLARE @StartedAtUtc datetime2(3);
    DECLARE @EndedAtUtc datetime2(3);
    DECLARE @StartCpuMs bigint;
    DECLARE @StartReads bigint;
    DECLARE @StartLogicalReads bigint;
    DECLARE @StartWrites bigint;
    DECLARE @EndCpuMs bigint;
    DECLARE @EndReads bigint;
    DECLARE @EndLogicalReads bigint;
    DECLARE @EndWrites bigint;
    DECLARE @WaitCaptureRequested bit;
    DECLARE @WaitOutcome varchar(8);
    DECLARE @WaitCode varchar(64);
    DECLARE @OverallOutcome varchar(8);
    DECLARE @OverallCode varchar(64);

    SELECT
        @ProjectMarker = MAX(CASE WHEN ep.name = N'SQLPERF.Project' THEN CONVERT(nvarchar(128), ep.value) END),
        @ContractMarker = MAX(CASE WHEN ep.name = N'SQLPERF.ContractVersion' THEN CONVERT(nvarchar(128), ep.value) END),
        @MarkerDemoId = MAX(CASE WHEN ep.name = N'SQLPERF.DemoId' THEN CONVERT(varchar(7), ep.value) END),
        @MarkerRunToken = MAX(CASE WHEN ep.name = N'SQLPERF.RunToken' THEN CONVERT(varchar(20), ep.value) END)
    FROM sys.extended_properties AS ep
    WHERE ep.class = 0
      AND ep.major_id = 0
      AND ep.minor_id = 0
      AND ep.name IN
          (
              N'SQLPERF.Project',
              N'SQLPERF.ContractVersion',
              N'SQLPERF.DemoId',
              N'SQLPERF.RunToken'
          );

    IF DB_ID() <= 4
       OR @ProjectMarker <> N'SQL_PerformanceSchulung'
       OR @ContractMarker <> N'1.0'
       OR @MarkerDemoId <> @DemoId
       OR @MarkerRunToken <> @RunToken
        THROW 51001, 'FAIL_SAFETY: Die Messung wurde außerhalb des erwarteten markierten Demo-Kontexts beendet.', 1;

    IF @ResultRows IS NOT NULL AND @ResultRows < 0
        THROW 51000, 'FAIL_CONTRACT: ResultRows darf nicht negativ sein.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT
            @StoredDemoId = mr.DemoId,
            @StoredRunToken = mr.RunToken,
            @StoredSessionId = mr.SessionId,
            @StartedAtUtc = mr.StartedAtUtc,
            @StartCpuMs = mr.StartCpuMs,
            @StartReads = mr.StartReads,
            @StartLogicalReads = mr.StartLogicalReads,
            @StartWrites = mr.StartWrites,
            @WaitCaptureRequested = mr.WaitCaptureRequested,
            @WaitOutcome = mr.WaitCaptureOutcome,
            @WaitCode = mr.WaitCaptureCode
        FROM lab.MeasurementRun AS mr WITH (UPDLOCK, HOLDLOCK)
        WHERE mr.MeasurementRunId = @MeasurementRunId
          AND mr.EndedAtUtc IS NULL;

        IF @StoredDemoId IS NULL
            THROW 51002, 'FAIL_STATE: Die Messungs-ID ist unbekannt oder wurde bereits beendet.', 1;

        IF @StoredDemoId <> @DemoId
           OR @StoredRunToken <> @RunToken
           OR @StoredSessionId <> @@SPID
            THROW 51002, 'FAIL_STATE: Demo-, Run- oder Sessionkontext stimmt nicht mit dem Messungsstart überein.', 1;

        SELECT
            @EndCpuMs = CONVERT(bigint, s.cpu_time),
            @EndReads = CONVERT(bigint, s.reads),
            @EndLogicalReads = CONVERT(bigint, s.logical_reads),
            @EndWrites = CONVERT(bigint, s.writes)
        FROM sys.dm_exec_sessions AS s
        WHERE s.session_id = @@SPID;

        IF @EndCpuMs IS NULL
            THROW 51002, 'FAIL_STATE: Die Sessionzähler konnten beim Messungsende nicht gelesen werden.', 1;

        SET @EndedAtUtc = SYSUTCDATETIME();

        IF @WaitCaptureRequested = 1
        BEGIN
            BEGIN TRY
                INSERT lab.MeasurementWaitSnapshot
                (
                    MeasurementRunId,
                    SnapshotKind,
                    WaitType,
                    WaitingTasksCount,
                    WaitTimeMs,
                    SignalWaitTimeMs
                )
                SELECT
                    @MeasurementRunId,
                    'E',
                    ws.wait_type,
                    ws.waiting_tasks_count,
                    ws.wait_time_ms,
                    ws.signal_wait_time_ms
                FROM sys.dm_exec_session_wait_stats AS ws
                WHERE ws.session_id = @@SPID;
            END TRY
            BEGIN CATCH
                SET @WaitOutcome = 'WARN';
                SET @WaitCode = 'WARN_RESOURCE_PROBE_APPROXIMATE';
            END CATCH;
        END;

        IF @EndCpuMs < @StartCpuMs
           OR @EndReads < @StartReads
           OR @EndLogicalReads < @StartLogicalReads
           OR @EndWrites < @StartWrites
            THROW 51002, 'FAIL_STATE: Mindestens ein kumulativer Sessionzähler ist kleiner als sein Startwert.', 1;

        SET @OverallOutcome = CASE WHEN @WaitOutcome = 'WARN' THEN 'WARN' ELSE 'PASS' END;
        SET @OverallCode = CASE WHEN @WaitOutcome = 'WARN' THEN @WaitCode ELSE 'OK' END;

        UPDATE lab.MeasurementRun
        SET
            EndedAtUtc = @EndedAtUtc,
            EndCpuMs = @EndCpuMs,
            EndReads = @EndReads,
            EndLogicalReads = @EndLogicalReads,
            EndWrites = @EndWrites,
            ElapsedMs = DATEDIFF_BIG(millisecond, @StartedAtUtc, @EndedAtUtc),
            CpuMs = @EndCpuMs - @StartCpuMs,
            Reads = @EndReads - @StartReads,
            LogicalReads = @EndLogicalReads - @StartLogicalReads,
            Writes = @EndWrites - @StartWrites,
            ResultRows = @ResultRows,
            WaitCaptureOutcome = @WaitOutcome,
            WaitCaptureCode = @WaitCode,
            OverallOutcome = @OverallOutcome,
            OverallCode = @OverallCode
        WHERE MeasurementRunId = @MeasurementRunId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        IF ERROR_NUMBER() BETWEEN 51000 AND 51004
            THROW;

        DECLARE @OriginalErrorMessage nvarchar(2048) = ERROR_MESSAGE();
        DECLARE @WrappedErrorMessage nvarchar(2048) =
            CONCAT
            (
                N'FAIL_EXECUTION: FWK-004 ist fehlgeschlagen. SQL-Fehler ',
                ERROR_NUMBER(),
                N': ',
                LEFT(@OriginalErrorMessage, 1700)
            );

        THROW 51003, @WrappedErrorMessage, 1;
    END CATCH;

    SELECT
        Sequence = CONVERT(int, 1),
        Phase = CONVERT(varchar(20), 'MEASUREMENT'),
        CheckId = CONVERT(varchar(64), 'END'),
        Outcome = mr.OverallOutcome,
        Code = mr.OverallCode,
        ObservedValue = CONVERT
        (
            nvarchar(4000),
            CONCAT
            (
                N'ElapsedMs=', mr.ElapsedMs,
                N'; CpuMs=', mr.CpuMs,
                N'; LogicalReads=', mr.LogicalReads,
                N'; Reads=', mr.Reads,
                N'; Writes=', mr.Writes,
                N'; ResultRows=', COALESCE(CONVERT(nvarchar(40), mr.ResultRows), N'NULL')
            )
        ),
        RequiredValue = CONVERT(nvarchar(4000), N'nicht negative sessionbezogene Deltas'),
        Message = CONVERT
        (
            nvarchar(4000),
            CASE
                WHEN mr.OverallOutcome = 'PASS'
                    THEN N'Die sessionbezogene Messung wurde beendet.'
                ELSE N'Die Messung wurde beendet; optionale Wait-Evidenz ist eingeschränkt.'
            END
        )
    FROM lab.MeasurementRun AS mr
    WHERE mr.MeasurementRunId = @MeasurementRunId;

    IF @WaitCaptureRequested = 1
    BEGIN
        ;WITH
        BeginWaits AS
        (
            SELECT
                WaitType,
                WaitingTasksCount,
                WaitTimeMs,
                SignalWaitTimeMs
            FROM lab.MeasurementWaitSnapshot
            WHERE MeasurementRunId = @MeasurementRunId
              AND SnapshotKind = 'B'
        ),
        EndWaits AS
        (
            SELECT
                WaitType,
                WaitingTasksCount,
                WaitTimeMs,
                SignalWaitTimeMs
            FROM lab.MeasurementWaitSnapshot
            WHERE MeasurementRunId = @MeasurementRunId
              AND SnapshotKind = 'E'
        )
        SELECT
            WaitType = COALESCE(e.WaitType, b.WaitType),
            WaitingTasksDelta =
                COALESCE(e.WaitingTasksCount, 0) - COALESCE(b.WaitingTasksCount, 0),
            WaitTimeMsDelta =
                COALESCE(e.WaitTimeMs, 0) - COALESCE(b.WaitTimeMs, 0),
            SignalWaitTimeMsDelta =
                COALESCE(e.SignalWaitTimeMs, 0) - COALESCE(b.SignalWaitTimeMs, 0)
        FROM BeginWaits AS b
        FULL OUTER JOIN EndWaits AS e
            ON e.WaitType = b.WaitType
        WHERE COALESCE(e.WaitingTasksCount, 0) - COALESCE(b.WaitingTasksCount, 0) > 0
           OR COALESCE(e.WaitTimeMs, 0) - COALESCE(b.WaitTimeMs, 0) > 0
           OR COALESCE(e.SignalWaitTimeMs, 0) - COALESCE(b.SignalWaitTimeMs, 0) > 0
        ORDER BY WaitTimeMsDelta DESC, WaitType;
    END;
END;
GO
