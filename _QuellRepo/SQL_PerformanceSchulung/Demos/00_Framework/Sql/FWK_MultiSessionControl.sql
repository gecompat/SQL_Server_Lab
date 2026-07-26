/*
    FWK-006 reference implementation
    Actions: INSTALL | STATUS | CLEAR | UNINSTALL

    Run only inside a FWK-002-marked test database.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Action varchar(12) = 'STATUS';
DECLARE @DemoId varchar(7) = 'CON-004';
DECLARE @RunToken varchar(20) = 'LOCAL';
DECLARE @ConfirmUninstall bit = 0;

DECLARE @ProjectMarker nvarchar(128);
DECLARE @ContractMarker nvarchar(128);
DECLARE @MarkerDemoId varchar(7);
DECLARE @MarkerRunToken varchar(20);

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
    THROW 51001, 'FAIL_SAFETY: FWK-006 wurde außerhalb der erwarteten markierten Testdatenbank aufgerufen.', 1;

SET @Action = UPPER(@Action);

IF @Action NOT IN ('INSTALL', 'STATUS', 'CLEAR', 'UNINSTALL')
    THROW 51000, 'FAIL_CONTRACT: Unbekannte FWK-006-Aktion.', 1;

IF @Action = 'INSTALL'
BEGIN
    IF SCHEMA_ID(N'fwk') IS NULL
        EXEC(N'CREATE SCHEMA fwk AUTHORIZATION dbo;');

    IF OBJECT_ID(N'fwk.SessionSignal', N'U') IS NULL
    BEGIN
        CREATE TABLE fwk.SessionSignal
        (
            DemoId varchar(7) NOT NULL,
            RunToken varchar(20) NOT NULL,
            SignalName varchar(64) NOT NULL,
            SignaledAtUtc datetime2(3) NOT NULL
                CONSTRAINT DF_fwk_SessionSignal_SignaledAtUtc DEFAULT SYSUTCDATETIME(),
            SignaledBySessionId smallint NOT NULL,
            CONSTRAINT PK_fwk_SessionSignal
                PRIMARY KEY CLUSTERED (DemoId, RunToken, SignalName)
        );
    END;

    EXEC(N'
CREATE OR ALTER PROCEDURE fwk.USP_Signal
    @DemoId varchar(7),
    @RunToken varchar(20),
    @SignalName varchar(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @SignalName IS NULL
       OR LEN(@SignalName) NOT BETWEEN 1 AND 64
       OR @SignalName LIKE ''%[^A-Z0-9_]%''
        THROW 51000, ''FAIL_CONTRACT: Ungültiger Signalname.'', 1;

    DECLARE @ProjectMarker nvarchar(128);
    DECLARE @MarkerDemoId varchar(7);
    DECLARE @MarkerRunToken varchar(20);

    SELECT
        @ProjectMarker = MAX(CASE WHEN ep.name = N''SQLPERF.Project'' THEN CONVERT(nvarchar(128), ep.value) END),
        @MarkerDemoId = MAX(CASE WHEN ep.name = N''SQLPERF.DemoId'' THEN CONVERT(varchar(7), ep.value) END),
        @MarkerRunToken = MAX(CASE WHEN ep.name = N''SQLPERF.RunToken'' THEN CONVERT(varchar(20), ep.value) END)
    FROM sys.extended_properties AS ep
    WHERE ep.class = 0
      AND ep.major_id = 0
      AND ep.minor_id = 0
      AND ep.name IN (N''SQLPERF.Project'', N''SQLPERF.DemoId'', N''SQLPERF.RunToken'');

    IF @ProjectMarker <> N''SQL_PerformanceSchulung''
       OR @MarkerDemoId <> @DemoId
       OR @MarkerRunToken <> @RunToken
        THROW 51001, ''FAIL_SAFETY: Signal passt nicht zum Datenbankeigentum.'', 1;

    UPDATE fwk.SessionSignal
    SET
        SignaledAtUtc = SYSUTCDATETIME(),
        SignaledBySessionId = @@SPID
    WHERE DemoId = @DemoId
      AND RunToken = @RunToken
      AND SignalName = @SignalName;

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT fwk.SessionSignal
            (
                DemoId,
                RunToken,
                SignalName,
                SignaledBySessionId
            )
            VALUES
            (
                @DemoId,
                @RunToken,
                @SignalName,
                @@SPID
            );
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (2601, 2627)
                THROW;

            UPDATE fwk.SessionSignal
            SET
                SignaledAtUtc = SYSUTCDATETIME(),
                SignaledBySessionId = @@SPID
            WHERE DemoId = @DemoId
              AND RunToken = @RunToken
              AND SignalName = @SignalName;
        END CATCH;
    END;

    SELECT
        Sequence = CONVERT(int, 1),
        Phase = CONVERT(varchar(20), ''ORCHESTRATION''),
        CheckId = CONVERT(varchar(64), ''SIGNAL''),
        Outcome = CONVERT(varchar(8), ''PASS''),
        Code = CONVERT(varchar(64), ''OK''),
        ObservedValue = CONVERT(nvarchar(4000), @SignalName),
        RequiredValue = CONVERT(nvarchar(4000), N''gültiges Signal''),
        Message = CONVERT(nvarchar(4000), N''Signal wurde gesetzt.'');
END;
');

    EXEC(N'
CREATE OR ALTER PROCEDURE fwk.USP_WaitForSignal
    @DemoId varchar(7),
    @RunToken varchar(20),
    @SignalName varchar(64),
    @TimeoutMs int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @SignalName IS NULL
       OR LEN(@SignalName) NOT BETWEEN 1 AND 64
       OR @SignalName LIKE ''%[^A-Z0-9_]%''
       OR @TimeoutMs NOT BETWEEN 1 AND 3600000
        THROW 51000, ''FAIL_CONTRACT: Ungültiger Signalname oder Timeout.'', 1;

    DECLARE @StartedAt datetime2(3) = SYSUTCDATETIME();

    WHILE NOT EXISTS
    (
        SELECT 1
        FROM fwk.SessionSignal AS ss
        WHERE ss.DemoId = @DemoId
          AND ss.RunToken = @RunToken
          AND ss.SignalName = @SignalName
    )
    BEGIN
        IF DATEDIFF_BIG(millisecond, @StartedAt, SYSUTCDATETIME()) >= @TimeoutMs
            THROW 51005, ''FAIL_TIMEOUT: Das erwartete Multi-Session-Signal wurde nicht rechtzeitig gesetzt.'', 1;

        WAITFOR DELAY ''00:00:00.100'';
    END;

    SELECT
        Sequence = CONVERT(int, 1),
        Phase = CONVERT(varchar(20), ''ORCHESTRATION''),
        CheckId = CONVERT(varchar(64), ''WAIT_SIGNAL''),
        Outcome = CONVERT(varchar(8), ''PASS''),
        Code = CONVERT(varchar(64), ''OK''),
        ObservedValue = CONVERT(nvarchar(4000), @SignalName),
        RequiredValue = CONVERT(nvarchar(4000), CONCAT(N''TimeoutMs='', @TimeoutMs)),
        Message = CONVERT(nvarchar(4000), N''Signal wurde innerhalb des Zeitbudgets beobachtet.'');
END;
');

    EXEC(N'
CREATE OR ALTER PROCEDURE fwk.USP_ClearSignals
    @DemoId varchar(7),
    @RunToken varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE fwk.SessionSignal
    WHERE DemoId = @DemoId
      AND RunToken = @RunToken;

    SELECT
        Sequence = CONVERT(int, 1),
        Phase = CONVERT(varchar(20), ''CLEANUP''),
        CheckId = CONVERT(varchar(64), ''CLEAR_SIGNALS''),
        Outcome = CONVERT(varchar(8), ''PASS''),
        Code = CONVERT(varchar(64), ''OK''),
        ObservedValue = CONVERT(nvarchar(4000), CONCAT(N''Deleted='', @@ROWCOUNT)),
        RequiredValue = CONVERT(nvarchar(4000), N''exakte Demo-/Run-Kombination''),
        Message = CONVERT(nvarchar(4000), N''Multi-Session-Signale wurden bereinigt.'');
END;
');

    SELECT
        Sequence = 1,
        Phase = 'SETUP',
        CheckId = 'FWK006_INSTALL',
        Outcome = 'PASS',
        Code = 'OK',
        ObservedValue = CONVERT(nvarchar(4000), N'fwk.SessionSignal und drei Prozeduren'),
        RequiredValue = CONVERT(nvarchar(4000), N'installierte Multi-Session-Steuerung'),
        Message = CONVERT(nvarchar(4000), N'FWK-006 wurde idempotent installiert.');

    PRINT 'SQLPERF_SUMMARY|PASS|OK';
END
ELSE IF @Action = 'STATUS'
BEGIN
    SELECT
        Sequence = 1,
        Phase = 'ORCHESTRATION',
        CheckId = 'FWK006_STATUS',
        Outcome = CASE
            WHEN OBJECT_ID(N'fwk.SessionSignal', N'U') IS NOT NULL
             AND OBJECT_ID(N'fwk.USP_Signal', N'P') IS NOT NULL
             AND OBJECT_ID(N'fwk.USP_WaitForSignal', N'P') IS NOT NULL
             AND OBJECT_ID(N'fwk.USP_ClearSignals', N'P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END,
        Code = CASE
            WHEN OBJECT_ID(N'fwk.SessionSignal', N'U') IS NOT NULL
             AND OBJECT_ID(N'fwk.USP_Signal', N'P') IS NOT NULL
             AND OBJECT_ID(N'fwk.USP_WaitForSignal', N'P') IS NOT NULL
             AND OBJECT_ID(N'fwk.USP_ClearSignals', N'P') IS NOT NULL
            THEN 'OK' ELSE 'FAIL_STATE' END,
        ObservedValue = CONVERT
        (
            nvarchar(4000),
            CONCAT
            (
                N'Table=', IIF(OBJECT_ID(N'fwk.SessionSignal', N'U') IS NULL, 0, 1),
                N'; Signal=', IIF(OBJECT_ID(N'fwk.USP_Signal', N'P') IS NULL, 0, 1),
                N'; Wait=', IIF(OBJECT_ID(N'fwk.USP_WaitForSignal', N'P') IS NULL, 0, 1),
                N'; Clear=', IIF(OBJECT_ID(N'fwk.USP_ClearSignals', N'P') IS NULL, 0, 1)
            )
        ),
        RequiredValue = CONVERT(nvarchar(4000), N'alle FWK-006-Objekte'),
        Message = CONVERT(nvarchar(4000), N'Status der Multi-Session-Steuerung.');

    IF OBJECT_ID(N'fwk.SessionSignal', N'U') IS NOT NULL
        SELECT DemoId, RunToken, SignalName, SignaledAtUtc, SignaledBySessionId
        FROM fwk.SessionSignal
        WHERE DemoId = @DemoId
          AND RunToken = @RunToken
        ORDER BY SignalName;
END
ELSE IF @Action = 'CLEAR'
BEGIN
    IF OBJECT_ID(N'fwk.USP_ClearSignals', N'P') IS NULL
        THROW 51002, 'FAIL_STATE: FWK-006 ist nicht installiert.', 1;

    EXEC fwk.USP_ClearSignals @DemoId = @DemoId, @RunToken = @RunToken;
    PRINT 'SQLPERF_SUMMARY|PASS|OK';
END
ELSE
BEGIN
    IF @ConfirmUninstall <> 1
        THROW 51001, 'FAIL_SAFETY: UNINSTALL benötigt ConfirmUninstall=1.', 1;

    IF OBJECT_ID(N'fwk.USP_ClearSignals', N'P') IS NOT NULL
        EXEC fwk.USP_ClearSignals @DemoId = @DemoId, @RunToken = @RunToken;

    DROP PROCEDURE IF EXISTS fwk.USP_WaitForSignal;
    DROP PROCEDURE IF EXISTS fwk.USP_Signal;
    DROP PROCEDURE IF EXISTS fwk.USP_ClearSignals;
    DROP TABLE IF EXISTS fwk.SessionSignal;

    SELECT
        Sequence = 1,
        Phase = 'CLEANUP',
        CheckId = 'FWK006_UNINSTALL',
        Outcome = 'PASS',
        Code = 'OK',
        ObservedValue = CONVERT(nvarchar(4000), N'Objekte entfernt'),
        RequiredValue = CONVERT(nvarchar(4000), N'bestätigte markierte Testdatenbank'),
        Message = CONVERT(nvarchar(4000), N'FWK-006 wurde entfernt.');

    PRINT 'SQLPERF_SUMMARY|PASS|OK';
END;
