/*
    Template: 00_Preflight.sql
    Contracts: FWK-001, FWK-008, FWK-012

    Replace the synthetic example values before using this file in a demo.
    The batch is read-only. It changes no database or instance option.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DemoId varchar(7) = 'QRY-001';
DECLARE @SafetyLevel varchar(6) = 'GREEN'; -- GREEN | YELLOW | RED
DECLARE @MinimumMajorVersion int = 15;
DECLARE @MaximumMajorVersion int = 17;
DECLARE @MinimumCompatibilityLevel int = 150;
DECLARE @MaximumCompatibilityLevel int = 170;
DECLARE @TargetDatabase sysname = N'SQLPERF_LAB_QRY001_LOCAL';
DECLARE @RequireTargetDatabase bit = 1;
DECLARE @RequireWritableDatabase bit = 1;
DECLARE @RequireShowplan bit = 1;
DECLARE @RequireViewServerState bit = 0;
DECLARE @RequireViewServerPerformanceState bit = 0;
DECLARE @RequireCreateDatabasePermission bit = 0;
DECLARE @RequireAlterDatabase bit = 0;
DECLARE @ConfirmIsolatedLab bit = 0;
DECLARE @HighImpactConfirmed bit = 0;
DECLARE @DisposableEnvironmentConfirmed bit = 0;
DECLARE @RecoveryPlanConfirmed bit = 0;
DECLARE @MaximumRuntimeSeconds int = NULL;
DECLARE @MinimumFreeSpaceMB bigint = NULL;
DECLARE @EmitEnvironmentDetails bit = 0;
DECLARE @EnvironmentDetailsRequired bit = 0;

DECLARE @Results table
(
    Sequence int IDENTITY(1,1) NOT NULL,
    Phase varchar(20) NOT NULL,
    CheckId varchar(64) NOT NULL,
    Outcome varchar(8) NOT NULL,
    Code varchar(64) NOT NULL,
    ObservedValue nvarchar(4000) NULL,
    RequiredValue nvarchar(4000) NULL,
    Message nvarchar(4000) NOT NULL
);

DECLARE @MajorVersion int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @ProductVersion nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'));
DECLARE @Edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
DECLARE @EngineEdition int = TRY_CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @DatabaseId int = DB_ID(@TargetDatabase);
DECLARE @DatabaseState nvarchar(60) = NULL;
DECLARE @CompatibilityLevel int = NULL;
DECLARE @IsReadOnly bit = NULL;
DECLARE @Observed nvarchar(4000);
DECLARE @Required nvarchar(4000);
DECLARE @PermissionValue int;
DECLARE @MinimumObservedFreeSpaceMB bigint = NULL;
DECLARE @SummaryOutcome varchar(8);
DECLARE @SummaryCode varchar(64);
DECLARE @ThrowMessage nvarchar(2048);

IF @DatabaseId IS NOT NULL
BEGIN
    SELECT
        @DatabaseState = d.state_desc,
        @CompatibilityLevel = d.compatibility_level,
        @IsReadOnly = d.is_read_only
    FROM sys.databases AS d
    WHERE d.database_id = @DatabaseId;
END;

/* Contract checks */
IF LEN(@DemoId) = 7
   AND @DemoId LIKE '[A-Z][A-Z][A-Z]-[0-9][0-9][0-9]'
   AND LEFT(@DemoId, 3) IN ('STL', 'OPT', 'QRY', 'IDX', 'CON', 'RES', 'DGN')
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'DEMO_ID', 'PASS', 'OK', @DemoId, N'kanonische fachliche Demo-ID', N'Die Demo-ID entspricht dem Vertrag.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'DEMO_ID', 'FAIL', 'FAIL_CONTRACT', @DemoId, N'STL|OPT|QRY|IDX|CON|RES|DGN-nnn', N'Die Demo-ID ist nicht kanonisch.');
END;

IF @SafetyLevel IN ('GREEN', 'YELLOW', 'RED')
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'SAFETY_LEVEL', 'PASS', 'OK', @SafetyLevel, N'GREEN, YELLOW oder RED', N'Die Sicherheitsstufe ist gültig.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'SAFETY_LEVEL', 'FAIL', 'FAIL_CONTRACT', @SafetyLevel, N'GREEN, YELLOW oder RED', N'Die Sicherheitsstufe ist ungültig.');
END;

IF @MinimumMajorVersion > @MaximumMajorVersion
   OR @MinimumCompatibilityLevel > @MaximumCompatibilityLevel
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'VERSION_RANGE', 'FAIL', 'FAIL_CONTRACT', NULL, N'gültige aufsteigende Bereiche', N'Der konfigurierte Versions- oder Compatibility-Level-Bereich ist widersprüchlich.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'VERSION_RANGE', 'PASS', 'OK', NULL, N'gültige aufsteigende Bereiche', N'Die konfigurierten Bereiche sind konsistent.');
END;

/* Engine and platform */
SET @Observed = CASE WHEN @EmitEnvironmentDetails = 1 THEN CONCAT(N'Major=', @MajorVersion, N'; ProductVersion=', @ProductVersion, N'; Edition=', @Edition, N'; EngineEdition=', @EngineEdition) ELSE CONCAT(N'Major=', @MajorVersion, N'; Details unterdrückt') END;
SET @Required = CONCAT(@MinimumMajorVersion, N' bis ', @MaximumMajorVersion);

IF @MajorVersion IS NULL
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'ENGINE_VERSION', 'FAIL', 'FAIL_STATE', @Observed, @Required, N'Die Engine-Hauptversion konnte nicht bestimmt werden.');
END
ELSE IF @MajorVersion < @MinimumMajorVersion OR @MajorVersion > @MaximumMajorVersion
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'ENGINE_VERSION', 'SKIP', 'SKIP_VERSION', @Observed, @Required, N'Diese Demo unterstützt die verbundene Engine-Version nicht.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'ENGINE_VERSION', 'PASS', 'OK', @Observed, @Required, N'Die Engine-Version liegt im unterstützten Bereich.');
END;

IF @EngineEdition IN (2, 3, 4)
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'ENGINE_EDITION', 'PASS', 'OK', CASE WHEN @EmitEnvironmentDetails = 1 THEN CONVERT(nvarchar(20), @EngineEdition) ELSE N'Details unterdrückt' END, N'SQL-Server-Instanz oder Container', N'Die Engine Edition entspricht dem Zielbereich der Schulung.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'ENGINE_EDITION', 'SKIP', 'SKIP_PLATFORM', CASE WHEN @EmitEnvironmentDetails = 1 THEN CONVERT(nvarchar(20), @EngineEdition) ELSE N'Details unterdrückt' END, N'EngineEdition 2, 3 oder 4', N'Diese Vorlage unterstützt die verbundene Plattform nicht.');
END;

/* Target database */
IF @RequireTargetDatabase = 0
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'TARGET_DATABASE', 'PASS', 'OK', N'nicht erforderlich', N'nicht erforderlich', N'Die Demo benötigt in dieser Phase keine Ziel-Datenbank.');
END
ELSE IF @DatabaseId IS NULL
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'TARGET_DATABASE', 'FAIL', 'FAIL_STATE', CASE WHEN @EmitEnvironmentDetails = 1 THEN @TargetDatabase ELSE N'Name unterdrückt' END, N'vorhandene markierte Testdatenbank', N'Die erwartete Testdatenbank ist nicht vorhanden.');
END
ELSE IF @DatabaseState <> N'ONLINE'
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'TARGET_DATABASE', 'FAIL', 'FAIL_STATE', @DatabaseState, N'ONLINE', N'Die Ziel-Datenbank ist nicht online.');
END
ELSE IF @RequireWritableDatabase = 1 AND @IsReadOnly = 1
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'TARGET_DATABASE', 'FAIL', 'FAIL_STATE', N'READ_ONLY', N'READ_WRITE', N'Die Demo benötigt eine schreibbare Ziel-Datenbank.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'TARGET_DATABASE', 'PASS', 'OK', CASE WHEN @EmitEnvironmentDetails = 1 THEN CONCAT(@TargetDatabase, N'; ', @DatabaseState) ELSE @DatabaseState END, N'ONLINE und passende Schreibbarkeit', N'Der Ziel-Datenbankzustand ist geeignet.');
END;

IF @RequireTargetDatabase = 1 AND @DatabaseId IS NOT NULL
BEGIN
    SET @Required = CONCAT(@MinimumCompatibilityLevel, N' bis ', @MaximumCompatibilityLevel);

    IF @CompatibilityLevel < @MinimumCompatibilityLevel OR @CompatibilityLevel > @MaximumCompatibilityLevel
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('PREFLIGHT', 'COMPATIBILITY_LEVEL', 'SKIP', 'SKIP_COMPATIBILITY_LEVEL', CONVERT(nvarchar(20), @CompatibilityLevel), @Required, N'Das Compatibility Level liegt außerhalb des fachlich unterstützten Bereichs.');
    END
    ELSE
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('PREFLIGHT', 'COMPATIBILITY_LEVEL', 'PASS', 'OK', CONVERT(nvarchar(20), @CompatibilityLevel), @Required, N'Das Compatibility Level ist geeignet.');
    END;
END;

/* Permissions */
IF @RequireShowplan = 1 AND @DatabaseId IS NOT NULL
BEGIN
    SET @PermissionValue = HAS_PERMS_BY_NAME(@TargetDatabase, 'DATABASE', 'SHOWPLAN');
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'PERMISSION_SHOWPLAN', CASE WHEN @PermissionValue = 1 THEN 'PASS' ELSE 'SKIP' END, CASE WHEN @PermissionValue = 1 THEN 'OK' ELSE 'SKIP_PERMISSION' END, CONVERT(nvarchar(20), COALESCE(@PermissionValue, 0)), N'SHOWPLAN', CASE WHEN @PermissionValue = 1 THEN N'SHOWPLAN ist verfügbar.' ELSE N'SHOWPLAN ist nicht verfügbar; planabhängige Phasen werden nicht ausgeführt.' END);
END;

IF @RequireViewServerState = 1
BEGIN
    SET @PermissionValue = HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE');
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'PERMISSION_VIEW_SERVER_STATE', CASE WHEN @PermissionValue = 1 THEN 'PASS' ELSE 'SKIP' END, CASE WHEN @PermissionValue = 1 THEN 'OK' ELSE 'SKIP_PERMISSION' END, CONVERT(nvarchar(20), COALESCE(@PermissionValue, 0)), N'VIEW SERVER STATE', CASE WHEN @PermissionValue = 1 THEN N'Die Berechtigung ist verfügbar.' ELSE N'Die erforderliche Server-State-Berechtigung fehlt.' END);
END;

IF @RequireViewServerPerformanceState = 1
BEGIN
    IF @MajorVersion < 16
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('PREFLIGHT', 'PERMISSION_VIEW_SERVER_PERFORMANCE_STATE', 'SKIP', 'SKIP_VERSION', CONVERT(nvarchar(20), @MajorVersion), N'SQL Server 2022 oder höher', N'Diese Berechtigungsbezeichnung ist für den konfigurierten Pfad erst ab SQL Server 2022 vorgesehen.');
    END
    ELSE
    BEGIN
        SET @PermissionValue = HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE');
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('PREFLIGHT', 'PERMISSION_VIEW_SERVER_PERFORMANCE_STATE', CASE WHEN @PermissionValue = 1 THEN 'PASS' ELSE 'SKIP' END, CASE WHEN @PermissionValue = 1 THEN 'OK' ELSE 'SKIP_PERMISSION' END, CONVERT(nvarchar(20), COALESCE(@PermissionValue, 0)), N'VIEW SERVER PERFORMANCE STATE', CASE WHEN @PermissionValue = 1 THEN N'Die Berechtigung ist verfügbar.' ELSE N'Die erforderliche Performance-State-Berechtigung fehlt.' END);
    END;
END;

IF @RequireCreateDatabasePermission = 1
BEGIN
    SET @PermissionValue = CASE
        WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE ANY DATABASE') = 1
          OR HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY DATABASE') = 1
          OR HAS_PERMS_BY_NAME(N'master', 'DATABASE', 'CREATE DATABASE') = 1
        THEN 1 ELSE 0 END;
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'PERMISSION_CREATE_DATABASE', CASE WHEN @PermissionValue = 1 THEN 'PASS' ELSE 'SKIP' END, CASE WHEN @PermissionValue = 1 THEN 'OK' ELSE 'SKIP_PERMISSION' END, CONVERT(nvarchar(20), @PermissionValue), N'CREATE DATABASE in master, CREATE ANY DATABASE oder ALTER ANY DATABASE', CASE WHEN @PermissionValue = 1 THEN N'Die Datenbankerstellung ist berechtigt.' ELSE N'Die Berechtigung zur Datenbankerstellung fehlt.' END);
END;

IF @RequireAlterDatabase = 1 AND @DatabaseId IS NOT NULL
BEGIN
    SET @PermissionValue = HAS_PERMS_BY_NAME(@TargetDatabase, 'DATABASE', 'ALTER');
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PREFLIGHT', 'PERMISSION_ALTER_DATABASE', CASE WHEN @PermissionValue = 1 THEN 'PASS' ELSE 'SKIP' END, CASE WHEN @PermissionValue = 1 THEN 'OK' ELSE 'SKIP_PERMISSION' END, CONVERT(nvarchar(20), COALESCE(@PermissionValue, 0)), N'ALTER auf Ziel-Datenbank', CASE WHEN @PermissionValue = 1 THEN N'Die Datenbankänderung ist berechtigt.' ELSE N'Die erforderliche ALTER-Berechtigung fehlt.' END);
END;

/* Safety gate */
IF @SafetyLevel = 'GREEN'
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('SAFETY', 'SAFETY_CONFIRMATION', 'PASS', 'OK', N'GREEN', N'keine Hochlastbestätigung', N'Die Demo ist auf die eigene Testdatenbank begrenzt.');
END
ELSE IF @SafetyLevel = 'YELLOW'
BEGIN
    IF @ConfirmIsolatedLab = 1 AND @HighImpactConfirmed = 1 AND @MaximumRuntimeSeconds > 0
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('SAFETY', 'SAFETY_CONFIRMATION', 'PASS', 'OK', N'Bestätigungen vorhanden', N'isoliertes Lab, High Impact, positive Laufzeitgrenze', N'Die gelbe Demo ist ausdrücklich freigegeben.');
    END
    ELSE
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('SAFETY', 'SAFETY_CONFIRMATION', 'FAIL', 'FAIL_SAFETY', N'Bestätigung unvollständig', N'@ConfirmIsolatedLab=1; @HighImpactConfirmed=1; @MaximumRuntimeSeconds>0', N'Die gelbe Demo darf ohne vollständige Sicherheitsfreigabe nicht beginnen.');
    END;
END
ELSE IF @SafetyLevel = 'RED'
BEGIN
    IF @ConfirmIsolatedLab = 1
       AND @HighImpactConfirmed = 1
       AND @DisposableEnvironmentConfirmed = 1
       AND @RecoveryPlanConfirmed = 1
       AND @MaximumRuntimeSeconds > 0
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('SAFETY', 'SAFETY_CONFIRMATION', 'PASS', 'OK', N'Bestätigungen vorhanden', N'isoliert, High Impact, disposable, Recovery, positive Laufzeitgrenze', N'Die rote Demo ist ausdrücklich freigegeben.');
    END
    ELSE
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('SAFETY', 'SAFETY_CONFIRMATION', 'FAIL', 'FAIL_SAFETY', N'Bestätigung unvollständig', N'alle roten Sicherheitsbestätigungen', N'Die rote Demo darf ohne vollständige Sicherheits- und Recovery-Freigabe nicht beginnen.');
    END;
END;

/* Optional free-space probe on target database volumes. */
IF @MinimumFreeSpaceMB IS NOT NULL
BEGIN
    IF @DatabaseId IS NULL
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('RESOURCE', 'FREE_SPACE', 'WARN', 'WARN_RESOURCE_PROBE_APPROXIMATE', N'Ziel-Datenbank nicht vorhanden', CONCAT(@MinimumFreeSpaceMB, N' MB'), N'Der tatsächliche Zielpfad kann vor der Datenbankerstellung nicht belastbar gemessen werden.');
    END
    ELSE
    BEGIN TRY
        SELECT @MinimumObservedFreeSpaceMB = MIN(CONVERT(bigint, vs.available_bytes / 1048576.0))
        FROM sys.master_files AS mf
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
        WHERE mf.database_id = @DatabaseId;

        IF @MinimumObservedFreeSpaceMB IS NULL
        BEGIN
            INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
            VALUES ('RESOURCE', 'FREE_SPACE', 'WARN', 'WARN_RESOURCE_PROBE_APPROXIMATE', N'kein Messwert', CONCAT(@MinimumFreeSpaceMB, N' MB'), N'Für das Zielvolume wurde kein belastbarer Freispeicherwert ermittelt.');
        END
        ELSE IF @MinimumObservedFreeSpaceMB < @MinimumFreeSpaceMB
        BEGIN
            INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
            VALUES ('RESOURCE', 'FREE_SPACE', 'SKIP', 'SKIP_RESOURCE_PROFILE', CONCAT(@MinimumObservedFreeSpaceMB, N' MB'), CONCAT(@MinimumFreeSpaceMB, N' MB'), N'Das gemessene Minimum der verwendeten Volumes unterschreitet die Demoanforderung.');
        END
        ELSE
        BEGIN
            INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
            VALUES ('RESOURCE', 'FREE_SPACE', 'PASS', 'OK', CONCAT(@MinimumObservedFreeSpaceMB, N' MB'), CONCAT(@MinimumFreeSpaceMB, N' MB'), N'Der gemessene Freispeicher erfüllt die Demoanforderung.');
        END;
    END TRY
    BEGIN CATCH
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('RESOURCE', 'FREE_SPACE', 'WARN', 'WARN_RESOURCE_PROBE_APPROXIMATE', N'Messung nicht verfügbar', CONCAT(@MinimumFreeSpaceMB, N' MB'), N'Der Freispeicher konnte mit den verfügbaren Berechtigungen nicht belastbar ermittelt werden.');
    END CATCH;
END;

IF @EmitEnvironmentDetails = 0 AND @EnvironmentDetailsRequired = 1
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PRIVACY', 'ENVIRONMENT_DETAILS', 'WARN', 'WARN_ENVIRONMENT_DETAIL_SUPPRESSED', N'unterdrückt', N'für diese Diagnose ausdrücklich benötigt', N'Die Demo bleibt ausführbar, aber die ausdrücklich benötigten Umgebungsdetails sind unterdrückt.');
END
ELSE IF @EmitEnvironmentDetails = 0
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PRIVACY', 'ENVIRONMENT_DETAILS', 'PASS', 'OK', N'unterdrückt', N'Standard: keine Ausgabe realer Umgebungswerte', N'Host-, Instanz-, Pfad- und Benutzerangaben werden vertragsgemäß nicht ausgegeben.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('PRIVACY', 'ENVIRONMENT_DETAILS', 'PASS', 'OK', N'interaktive Ausgabe aktiviert', N'keine Persistenz als Repository-Artefakt', N'Die Detailausgabe ist für die interaktive Diagnose aktiviert und darf nicht persistiert werden.');
END;

SET @SummaryOutcome = CASE
    WHEN EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'FAIL') THEN 'FAIL'
    WHEN EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'SKIP') THEN 'SKIP'
    WHEN EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'WARN') THEN 'WARN'
    ELSE 'PASS'
END;

SET @SummaryCode = CASE @SummaryOutcome
    WHEN 'FAIL' THEN COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'FAIL' ORDER BY Sequence), 'FAIL_CONTRACT')
    WHEN 'SKIP' THEN COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'SKIP' ORDER BY Sequence), 'SKIP_CONFIGURATION')
    WHEN 'WARN' THEN COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'WARN' ORDER BY Sequence), 'WARN_EMPIRICAL_VARIANCE')
    ELSE 'OK'
END;

INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
VALUES ('PREFLIGHT', 'SUMMARY', @SummaryOutcome, @SummaryCode, NULL, NULL, CASE @SummaryOutcome WHEN 'PASS' THEN N'Alle aktivierten Prüfungen sind bestanden.' WHEN 'WARN' THEN N'Die Demo ist ausführbar; mindestens eine Einschränkung ist zu beachten.' WHEN 'SKIP' THEN N'Mindestens eine erwartete Voraussetzung ist nicht erfüllt; zustandsverändernde Phasen dürfen nicht beginnen.' ELSE N'Mindestens ein Vertrags-, Sicherheits- oder Zustandsfehler verhindert die Ausführung.' END);

SELECT Sequence, Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message
FROM @Results
ORDER BY Sequence;

IF @SummaryOutcome = 'FAIL'
BEGIN
    SET @ThrowMessage = CONCAT(N'Preflight fehlgeschlagen: ', @SummaryCode, N'. Die vollständige Prüftabelle enthält die Evidenz.');
    THROW 51000, @ThrowMessage, 1;
END;
