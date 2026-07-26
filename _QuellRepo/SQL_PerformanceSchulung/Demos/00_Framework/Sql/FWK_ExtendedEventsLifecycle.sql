/*
    FWK-007 Extended Events reference implementation
    Actions: STATUS | CREATE | START | STOP | DROP

    The reference session is server-scoped, uses ring_buffer only, has
    STARTUP_STATE = OFF, and captures project error numbers for the marked
    test database.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Action varchar(10) = 'STATUS';
DECLARE @DemoId varchar(7) = 'DGN-005';
DECLARE @RunToken varchar(20) = 'LOCAL';
DECLARE @ConfirmLabUse bit = 0;
DECLARE @ConfirmDrop bit = 0;
DECLARE @EmitRingBufferXml bit = 0;

DECLARE @MajorVersion int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @ProjectMarker nvarchar(128);
DECLARE @ContractMarker nvarchar(128);
DECLARE @MarkerDemoId varchar(7);
DECLARE @MarkerRunToken varchar(20);
DECLARE @DatabaseId int = DB_ID();
DECLARE @SessionName sysname =
    CONVERT(sysname, N'SQLPERF_' + REPLACE(@DemoId, '-', '') + N'_' + @RunToken);
DECLARE @Sql nvarchar(max);
DECLARE @HasAlterAnyEventSession int =
    HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY EVENT SESSION');
DECLARE @HasCreateAnyEventSession int =
    CASE WHEN @MajorVersion >= 16
         THEN HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE ANY EVENT SESSION')
         ELSE 0 END;
DECLARE @HasDropAnyEventSession int =
    CASE WHEN @MajorVersion >= 16
         THEN HAS_PERMS_BY_NAME(NULL, NULL, 'DROP ANY EVENT SESSION')
         ELSE 0 END;
DECLARE @HasViewEventState int =
    CASE WHEN @MajorVersion >= 16
         THEN CASE
             WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE') = 1
               OR HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') = 1
             THEN 1 ELSE 0 END
         ELSE HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') END;

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

IF @DatabaseId <= 4
   OR @ProjectMarker <> N'SQL_PerformanceSchulung'
   OR @ContractMarker <> N'1.0'
   OR @MarkerDemoId <> @DemoId
   OR @MarkerRunToken <> @RunToken
    THROW 51001, 'FAIL_SAFETY: Extended Events dürfen nur aus der erwarteten markierten Testdatenbank verwaltet werden.', 1;

IF @SessionName NOT LIKE N'SQLPERF[_][A-Z][A-Z][A-Z][0-9][0-9][0-9][_]%' OR LEN(@SessionName) > 128
    THROW 51000, 'FAIL_CONTRACT: Ungültiger Extended-Events-Sessionname.', 1;

SET @Action = UPPER(@Action);

IF @Action NOT IN ('STATUS', 'CREATE', 'START', 'STOP', 'DROP')
    THROW 51000, 'FAIL_CONTRACT: Unbekannte Extended-Events-Aktion.', 1;

IF @Action = 'STATUS'
BEGIN
    IF COALESCE(@HasViewEventState, 0) <> 1
    BEGIN
        SELECT
            Sequence = 1,
            Phase = 'TELEMETRY',
            CheckId = 'XE_STATUS',
            Outcome = 'SKIP',
            Code = 'SKIP_PERMISSION',
            ObservedValue = CONVERT(nvarchar(4000), N'Statusberechtigung fehlt'),
            RequiredValue = CONVERT(nvarchar(4000), N'VIEW SERVER STATE oder VIEW SERVER PERFORMANCE STATE'),
            Message = CONVERT(nvarchar(4000), N'Der Extended-Events-Laufzeitstatus wurde nicht gelesen.');
        PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_PERMISSION';
        RETURN;
    END;

    SELECT
        Sequence = 1,
        Phase = 'TELEMETRY',
        CheckId = 'XE_STATUS',
        Outcome = 'PASS',
        Code = 'OK',
        ObservedValue = CONVERT
        (
            nvarchar(4000),
            CONCAT
            (
                N'Configured=', IIF(EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @SessionName), 1, 0),
                N'; Running=', IIF(EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = @SessionName), 1, 0)
            )
        ),
        RequiredValue = CONVERT(nvarchar(4000), @SessionName),
        Message = CONVERT(nvarchar(4000), N'Extended-Events-Status wurde gelesen.');

    SELECT
        ses.name,
        ses.event_retention_mode_desc,
        ses.max_dispatch_latency,
        ses.track_causality,
        ses.startup_state,
        IsRunning = CONVERT(bit, IIF(dx.address IS NULL, 0, 1))
    FROM sys.server_event_sessions AS ses
    LEFT JOIN sys.dm_xe_sessions AS dx ON dx.name = ses.name
    WHERE ses.name = @SessionName;

    IF @EmitRingBufferXml = 1
    BEGIN
        SELECT
            SessionName = dx.name,
            TargetData = TRY_CONVERT(xml, dxt.target_data)
        FROM sys.dm_xe_sessions AS dx
        INNER JOIN sys.dm_xe_session_targets AS dxt ON dxt.event_session_address = dx.address
        WHERE dx.name = @SessionName
          AND dxt.target_name = N'ring_buffer';
    END;
END
ELSE IF @Action = 'CREATE'
BEGIN
    IF @ConfirmLabUse <> 1
        THROW 51001, 'FAIL_SAFETY: CREATE benötigt ConfirmLabUse=1.', 1;

    IF COALESCE(@HasAlterAnyEventSession, 0) <> 1 AND COALESCE(@HasCreateAnyEventSession, 0) <> 1
    BEGIN
        SELECT
            Sequence = 1,
            Phase = 'TELEMETRY',
            CheckId = 'XE_CREATE',
            Outcome = 'SKIP',
            Code = 'SKIP_PERMISSION',
            ObservedValue = CONVERT(nvarchar(4000), N'Berechtigung fehlt'),
            RequiredValue = CONVERT(nvarchar(4000), N'CREATE ANY EVENT SESSION oder ALTER ANY EVENT SESSION'),
            Message = CONVERT(nvarchar(4000), N'Die Referenzsession wurde nicht erstellt.');
        PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_PERMISSION';
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @SessionName)
        THROW 51002, 'FAIL_STATE: Eine gleichnamige Event-Session existiert bereits und wird nicht übernommen.', 1;

    SET @Sql =
        N'CREATE EVENT SESSION ' + QUOTENAME(@SessionName) + N'
          ON SERVER
          ADD EVENT sqlserver.error_reported
          (
              ACTION (sqlserver.database_id, sqlserver.session_id)
              WHERE ([error_number] >= (50000) AND [sqlserver].[database_id] = (' + CONVERT(nvarchar(20), @DatabaseId) + N'))
          )
          ADD TARGET package0.ring_buffer
          (
              SET MAX_EVENTS_LIMIT = (1000), MAX_MEMORY = (1024)
          )
          WITH
          (
              MAX_MEMORY = 2048 KB,
              EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
              MAX_DISPATCH_LATENCY = 5 SECONDS,
              TRACK_CAUSALITY = ON,
              STARTUP_STATE = OFF
          );';

    EXEC sys.sp_executesql @Sql;

    SELECT
        Sequence = 1,
        Phase = 'TELEMETRY',
        CheckId = 'XE_CREATE',
        Outcome = 'PASS',
        Code = 'OK',
        ObservedValue = CONVERT(nvarchar(4000), @SessionName),
        RequiredValue = CONVERT(nvarchar(4000), N'ring_buffer <= 1024 KB; STARTUP_STATE OFF'),
        Message = CONVERT(nvarchar(4000), N'Extended-Events-Referenzsession wurde erstellt.');

    PRINT 'SQLPERF_SUMMARY|PASS|OK';
END
ELSE IF @Action IN ('START', 'STOP')
BEGIN
    IF @ConfirmLabUse <> 1
        THROW 51001, 'FAIL_SAFETY: START/STOP benötigt ConfirmLabUse=1.', 1;

    IF COALESCE(@HasAlterAnyEventSession, 0) <> 1
        THROW 51002, 'FAIL_STATE: ALTER ANY EVENT SESSION ist für START/STOP erforderlich.', 1;

    IF NOT EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @SessionName)
        THROW 51002, 'FAIL_STATE: Die erwartete Event-Session ist nicht vorhanden.', 1;

    SET @Sql = N'ALTER EVENT SESSION ' + QUOTENAME(@SessionName) + N' ON SERVER STATE = ' + @Action + N';';
    EXEC sys.sp_executesql @Sql;

    SELECT
        Sequence = 1,
        Phase = 'TELEMETRY',
        CheckId = CONVERT(varchar(64), N'XE_' + @Action),
        Outcome = 'PASS',
        Code = 'OK',
        ObservedValue = CONVERT(nvarchar(4000), @SessionName),
        RequiredValue = CONVERT(nvarchar(4000), @Action),
        Message = CONVERT(nvarchar(4000), N'Extended-Events-Status wurde geändert.');

    PRINT 'SQLPERF_SUMMARY|PASS|OK';
END
ELSE
BEGIN
    IF @ConfirmLabUse <> 1 OR @ConfirmDrop <> 1
        THROW 51001, 'FAIL_SAFETY: DROP benötigt ConfirmLabUse=1 und ConfirmDrop=1.', 1;

    IF COALESCE(@HasAlterAnyEventSession, 0) <> 1 AND COALESCE(@HasDropAnyEventSession, 0) <> 1
        THROW 51002, 'FAIL_STATE: DROP ANY EVENT SESSION oder ALTER ANY EVENT SESSION ist erforderlich.', 1;

    IF COALESCE(@HasViewEventState, 0) = 1 AND EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = @SessionName)
    BEGIN
        SET @Sql = N'ALTER EVENT SESSION ' + QUOTENAME(@SessionName) + N' ON SERVER STATE = STOP;';
        EXEC sys.sp_executesql @Sql;
    END;

    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @SessionName)
    BEGIN
        SET @Sql = N'DROP EVENT SESSION ' + QUOTENAME(@SessionName) + N' ON SERVER;';
        EXEC sys.sp_executesql @Sql;
    END;

    SELECT
        Sequence = 1,
        Phase = 'CLEANUP',
        CheckId = 'XE_DROP',
        Outcome = 'PASS',
        Code = 'OK',
        ObservedValue = CONVERT(nvarchar(4000), @SessionName),
        RequiredValue = CONVERT(nvarchar(4000), N'bestätigte SQLPERF-Session'),
        Message = CONVERT(nvarchar(4000), N'Extended-Events-Session wurde gestoppt und entfernt.');

    PRINT 'SQLPERF_SUMMARY|PASS|OK';
END;
