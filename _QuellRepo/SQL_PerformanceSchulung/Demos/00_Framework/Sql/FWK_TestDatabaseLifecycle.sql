/*
    FWK-002 reference implementation
    Actions: CREATE | VALIDATE | DROP

    This script derives the database name from a canonical demo ID and a
    synthetic run token. DROP is impossible without matching database-level
    ownership markers and two explicit confirmations.
*/

USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Action varchar(10) = 'VALIDATE'; -- CREATE | VALIDATE | DROP
DECLARE @DemoId varchar(7) = 'QRY-001';
DECLARE @RunToken varchar(16) = 'LOCAL';
DECLARE @RequestedCompatibilityLevel int = NULL; -- NULL = maximum supported by engine
DECLARE @ConfirmLabUse bit = 0;
DECLARE @ConfirmDrop bit = 0;
DECLARE @EmitEnvironmentDetails bit = 0;

DECLARE @ProjectMarker nvarchar(128) = N'SQL_PerformanceSchulung';
DECLARE @ContractVersion nvarchar(32) = N'1.0';
DECLARE @NormalizedRunToken varchar(16);
DECLARE @DatabaseName sysname;
DECLARE @ExpectedDatabaseName sysname;
DECLARE @MajorVersion int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @EngineEdition int = TRY_CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @MaximumCompatibilityLevel int;
DECLARE @EffectiveCompatibilityLevel int;
DECLARE @DatabaseId int;
DECLARE @DatabaseState nvarchar(60);
DECLARE @IsReadOnly bit;
DECLARE @ExistingCompatibilityLevel int;
DECLARE @ExistingProject nvarchar(128);
DECLARE @ExistingContractVersion nvarchar(32);
DECLARE @ExistingDemoId nvarchar(32);
DECLARE @ExistingRunToken nvarchar(32);
DECLARE @Sql nvarchar(max);
DECLARE @ParameterDefinition nvarchar(1000);
DECLARE @CreatedInThisBatch bit = 0;
DECLARE @CreatedUtc nvarchar(33);
DECLARE @ThrowNumber int;
DECLARE @Outcome varchar(8);
DECLARE @Code varchar(64);
DECLARE @Message nvarchar(4000);
DECLARE @ErrorMessage nvarchar(2048);
DECLARE @OriginalErrorNumber int;
DECLARE @OriginalErrorMessage nvarchar(2048);

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

SET @Action = UPPER(LTRIM(RTRIM(@Action)));
SET @NormalizedRunToken = UPPER(LTRIM(RTRIM(@RunToken)));
SET @ExpectedDatabaseName = CONVERT(sysname, N'SQLPERF_LAB_' + REPLACE(@DemoId, '-', '') + N'_' + @NormalizedRunToken);
SET @DatabaseName = @ExpectedDatabaseName;

/* Contract validation */
IF @Action NOT IN ('CREATE', 'VALIDATE', 'DROP')
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'ACTION', 'FAIL', 'FAIL_CONTRACT', @Action, N'CREATE, VALIDATE oder DROP', N'Die angeforderte Lifecycle-Aktion ist ungültig.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'ACTION', 'PASS', 'OK', @Action, N'CREATE, VALIDATE oder DROP', N'Die Lifecycle-Aktion ist gültig.');
END;

IF LEN(@DemoId) = 7
   AND @DemoId LIKE '[A-Z][A-Z][A-Z]-[0-9][0-9][0-9]'
   AND LEFT(@DemoId, 3) IN ('STL', 'OPT', 'QRY', 'IDX', 'CON', 'RES', 'DGN')
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'DEMO_ID', 'PASS', 'OK', @DemoId, N'kanonische fachliche Demo-ID', N'Die Demo-ID entspricht dem Vertrag.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'DEMO_ID', 'FAIL', 'FAIL_CONTRACT', @DemoId, N'STL|OPT|QRY|IDX|CON|RES|DGN-nnn', N'Die Demo-ID ist nicht kanonisch.');
END;

IF @NormalizedRunToken IS NOT NULL
   AND LEN(@NormalizedRunToken) BETWEEN 1 AND 16
   AND @NormalizedRunToken NOT LIKE '%[^A-Z0-9]%'
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'RUN_TOKEN', 'PASS', 'OK', @NormalizedRunToken, N'1 bis 16 Zeichen A-Z oder 0-9', N'Der Run-Token entspricht dem Vertrag.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'RUN_TOKEN', 'FAIL', 'FAIL_CONTRACT', @NormalizedRunToken, N'1 bis 16 Zeichen A-Z oder 0-9', N'Der Run-Token ist ungültig.');
END;

IF LEN(@ExpectedDatabaseName) <= 128
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'DATABASE_NAME', 'PASS', 'OK', CASE WHEN @EmitEnvironmentDetails = 1 THEN @ExpectedDatabaseName ELSE N'kanonischer Name; Details unterdrückt' END, N'SQLPERF_LAB_DEMO_RUN', N'Der Datenbankname wurde deterministisch abgeleitet.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'DATABASE_NAME', 'FAIL', 'FAIL_CONTRACT', NULL, N'maximal 128 Zeichen', N'Der abgeleitete Datenbankname überschreitet sysname.');
END;

IF @@TRANCOUNT = 0
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'TRANSACTION_STATE', 'PASS', 'OK', N'0', N'keine aktive Transaktion', N'Der Lifecycle läuft im Autocommit-Kontext.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'TRANSACTION_STATE', 'FAIL', 'FAIL_STATE', CONVERT(nvarchar(20), @@TRANCOUNT), N'0', N'CREATE DATABASE und DROP DATABASE dürfen nicht in einer aktiven Transaktion ausgeführt werden.');
END;

IF @MajorVersion IS NULL OR @MajorVersion NOT BETWEEN 15 AND 17
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'ENGINE_VERSION', 'SKIP', 'SKIP_VERSION', CONVERT(nvarchar(20), @MajorVersion), N'15 bis 17', N'Die Framework-Basis unterstützt SQL Server 2019 bis 2025.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'ENGINE_VERSION', 'PASS', 'OK', CONVERT(nvarchar(20), @MajorVersion), N'15 bis 17', N'Die Engine-Version ist unterstützt.');
END;

IF @EngineEdition IN (2, 3, 4)
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'ENGINE_EDITION', 'PASS', 'OK', CASE WHEN @EmitEnvironmentDetails = 1 THEN CONVERT(nvarchar(20), @EngineEdition) ELSE N'Details unterdrückt' END, N'EngineEdition 2, 3 oder 4', N'Die Engine Edition ist unterstützt.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'ENGINE_EDITION', 'SKIP', 'SKIP_PLATFORM', CASE WHEN @EmitEnvironmentDetails = 1 THEN CONVERT(nvarchar(20), @EngineEdition) ELSE N'Details unterdrückt' END, N'EngineEdition 2, 3 oder 4', N'Diese Lifecycle-Implementierung ist nicht für die verbundene Plattform freigegeben.');
END;

SET @MaximumCompatibilityLevel = CASE @MajorVersion WHEN 15 THEN 150 WHEN 16 THEN 160 WHEN 17 THEN 170 ELSE NULL END;
SET @EffectiveCompatibilityLevel = COALESCE(@RequestedCompatibilityLevel, @MaximumCompatibilityLevel);

IF @EffectiveCompatibilityLevel IN (140, 150, 160, 170)
   AND @EffectiveCompatibilityLevel <= @MaximumCompatibilityLevel
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'COMPATIBILITY_LEVEL', 'PASS', 'OK', CONVERT(nvarchar(20), @EffectiveCompatibilityLevel), CONCAT(N'140 bis ', @MaximumCompatibilityLevel), N'Das angeforderte Compatibility Level ist auf dieser Engine zulässig.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'COMPATIBILITY_LEVEL', 'SKIP', 'SKIP_COMPATIBILITY_LEVEL', CONVERT(nvarchar(20), @EffectiveCompatibilityLevel), CONCAT(N'140 bis ', @MaximumCompatibilityLevel), N'Das angeforderte Compatibility Level ist auf dieser Engine nicht unterstützt.');
END;

IF @Action IN ('CREATE', 'DROP') AND @ConfirmLabUse <> 1
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('SAFETY', 'LAB_CONFIRMATION', 'FAIL', 'FAIL_SAFETY', CONVERT(nvarchar(20), @ConfirmLabUse), N'@ConfirmLabUse = 1', N'Zustandsverändernde Lifecycle-Aktionen benötigen die ausdrückliche Lab-Freigabe.');
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('SAFETY', 'LAB_CONFIRMATION', 'PASS', 'OK', CONVERT(nvarchar(20), @ConfirmLabUse), N'für CREATE und DROP gleich 1', N'Die Lab-Freigabe ist für die angeforderte Aktion ausreichend.');
END;

IF @Action = 'DROP' AND @ConfirmDrop <> 1
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('SAFETY', 'DROP_CONFIRMATION', 'FAIL', 'FAIL_SAFETY', CONVERT(nvarchar(20), @ConfirmDrop), N'@ConfirmDrop = 1', N'DROP benötigt eine separate ausdrückliche Bestätigung.');
END
ELSE IF @Action = 'DROP'
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('SAFETY', 'DROP_CONFIRMATION', 'PASS', 'OK', N'1', N'1', N'Die Löschbestätigung ist vorhanden.');
END;

/* Stop before reading or changing database state when the contract already failed. */
IF EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'FAIL')
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'SUMMARY', 'FAIL', COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'FAIL' ORDER BY Sequence), 'FAIL_CONTRACT'), NULL, NULL, N'Der Lifecycle-Vertrag ist nicht erfüllt; es wurde keine Datenbank verändert.');

    SELECT Sequence, Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message
    FROM @Results
    ORDER BY Sequence;

    SET @ErrorMessage = N'Der Testdatenbank-Lifecycle wurde vor jeder Zustandsänderung abgebrochen.';
    THROW 51000, @ErrorMessage, 1;
END;

IF EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'SKIP')
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'SUMMARY', 'SKIP', COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'SKIP' ORDER BY Sequence), 'SKIP_CONFIGURATION'), NULL, NULL, N'Die Lifecycle-Aktion ist in dieser Umgebung kontrolliert nicht anwendbar; es wurde keine Datenbank verändert.');

    SELECT Sequence, Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message
    FROM @Results
    ORDER BY Sequence;

    RETURN;
END;

SET @DatabaseId = DB_ID(@DatabaseName);

IF @DatabaseId IS NOT NULL
BEGIN
    SELECT
        @DatabaseState = d.state_desc,
        @IsReadOnly = d.is_read_only,
        @ExistingCompatibilityLevel = d.compatibility_level
    FROM sys.databases AS d
    WHERE d.database_id = @DatabaseId;

    IF @DatabaseId <= 4
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('LIFECYCLE', 'SYSTEM_DATABASE_GUARD', 'FAIL', 'FAIL_STATE', CONVERT(nvarchar(20), @DatabaseId), N'database_id > 4', N'Systemdatenbanken sind vom Lifecycle ausgeschlossen.');
    END
    ELSE IF @DatabaseState <> N'ONLINE'
    BEGIN
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('LIFECYCLE', 'DATABASE_STATE', 'FAIL', 'FAIL_STATE', @DatabaseState, N'ONLINE', N'Die Datenbankmarker können nur im ONLINE-Zustand sicher geprüft werden.');
    END
    ELSE
    BEGIN
        BEGIN TRY
            SET @Sql = N'
SELECT
    @ProjectOut = MAX(CASE WHEN ep.name = N''SQLPERF.Project'' THEN CONVERT(nvarchar(128), ep.value) END),
    @ContractOut = MAX(CASE WHEN ep.name = N''SQLPERF.ContractVersion'' THEN CONVERT(nvarchar(32), ep.value) END),
    @DemoOut = MAX(CASE WHEN ep.name = N''SQLPERF.DemoId'' THEN CONVERT(nvarchar(32), ep.value) END),
    @RunOut = MAX(CASE WHEN ep.name = N''SQLPERF.RunToken'' THEN CONVERT(nvarchar(32), ep.value) END)
FROM ' + QUOTENAME(@DatabaseName) + N'.sys.extended_properties AS ep
WHERE ep.class = 0
  AND ep.major_id = 0
  AND ep.minor_id = 0
  AND ep.name IN (N''SQLPERF.Project'', N''SQLPERF.ContractVersion'', N''SQLPERF.DemoId'', N''SQLPERF.RunToken'');';

            SET @ParameterDefinition = N'@ProjectOut nvarchar(128) OUTPUT, @ContractOut nvarchar(32) OUTPUT, @DemoOut nvarchar(32) OUTPUT, @RunOut nvarchar(32) OUTPUT';

            EXEC sys.sp_executesql
                @Sql,
                @ParameterDefinition,
                @ProjectOut = @ExistingProject OUTPUT,
                @ContractOut = @ExistingContractVersion OUTPUT,
                @DemoOut = @ExistingDemoId OUTPUT,
                @RunOut = @ExistingRunToken OUTPUT;

            IF @ExistingProject = @ProjectMarker
               AND @ExistingContractVersion = @ContractVersion
               AND @ExistingDemoId = @DemoId
               AND @ExistingRunToken = @NormalizedRunToken
            BEGIN
                INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
                VALUES ('LIFECYCLE', 'OWNERSHIP_MARKERS', 'PASS', 'OK', N'vollständig passend', N'Projekt, Vertrag, Demo-ID und Run-Token', N'Die Datenbank ist eindeutig diesem Demolauf zugeordnet.');

                IF @Action IN ('CREATE', 'VALIDATE')
                   AND (@ExistingCompatibilityLevel <> @EffectiveCompatibilityLevel OR @IsReadOnly <> 0)
                BEGIN
                    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
                    VALUES ('LIFECYCLE', 'DATABASE_CONFIGURATION', 'FAIL', 'FAIL_STATE', CONCAT(N'Compatibility=', @ExistingCompatibilityLevel, N'; ReadOnly=', @IsReadOnly), CONCAT(N'Compatibility=', @EffectiveCompatibilityLevel, N'; ReadOnly=0'), N'Die vorhandene markierte Datenbank besitzt nicht die angeforderte Konfiguration.');
                END;
            END
            ELSE
            BEGIN
                INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
                VALUES ('LIFECYCLE', 'OWNERSHIP_MARKERS', 'FAIL', 'FAIL_STATE', N'fehlend oder abweichend', N'vollständige exakte Markerübereinstimmung', N'Die vorhandene Datenbank wird nicht verändert, weil ihr Eigentum nicht eindeutig bestätigt ist.');
            END;
        END TRY
        BEGIN CATCH
            INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
            VALUES ('LIFECYCLE', 'OWNERSHIP_MARKERS', 'FAIL', 'FAIL_STATE', N'nicht lesbar', N'vollständige exakte Markerübereinstimmung', N'Die vorhandene Datenbank wird nicht verändert, weil ihre Marker nicht sicher gelesen werden konnten.');
        END CATCH;
    END;
END
ELSE
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'DATABASE_EXISTENCE', CASE WHEN @Action = 'CREATE' THEN 'PASS' ELSE 'FAIL' END, CASE WHEN @Action = 'CREATE' THEN 'OK' ELSE 'FAIL_STATE' END, N'nicht vorhanden', CASE WHEN @Action = 'CREATE' THEN N'noch nicht vorhanden' ELSE N'vorhandene markierte Testdatenbank' END, CASE WHEN @Action = 'CREATE' THEN N'Der Name ist für die Erstellung frei.' ELSE N'Die erwartete Testdatenbank ist nicht vorhanden.' END);
END;

IF EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'FAIL')
BEGIN
    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'SUMMARY', 'FAIL', COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'FAIL' ORDER BY Sequence), 'FAIL_STATE'), NULL, NULL, N'Die Zustands- oder Eigentumsprüfung ist fehlgeschlagen; es wurde keine Datenbank verändert.');

    SELECT Sequence, Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message
    FROM @Results
    ORDER BY Sequence;

    SET @ErrorMessage = N'Der Testdatenbank-Lifecycle wurde wegen einer fehlgeschlagenen Zustands- oder Eigentumsprüfung abgebrochen.';
    THROW 51002, @ErrorMessage, 1;
END;

BEGIN TRY
    IF @Action = 'CREATE'
    BEGIN
        IF @DatabaseId IS NULL
        BEGIN
            IF COALESCE(HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE ANY DATABASE'), 0) <> 1
               AND COALESCE(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY DATABASE'), 0) <> 1
               AND COALESCE(HAS_PERMS_BY_NAME(N'master', 'DATABASE', 'CREATE DATABASE'), 0) <> 1
            BEGIN
                INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
                VALUES ('LIFECYCLE', 'CREATE_PERMISSION', 'SKIP', 'SKIP_PERMISSION', N'nicht verfügbar', N'CREATE ANY DATABASE oder ALTER ANY DATABASE', N'Die Datenbank kann mit den aktuellen Berechtigungen nicht erstellt werden.');
            END
            ELSE
            BEGIN
                SET @Sql = N'CREATE DATABASE ' + QUOTENAME(@DatabaseName) + N';';
                EXEC sys.sp_executesql @Sql;
                SET @CreatedInThisBatch = 1;

                SET @Sql = N'
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET RECOVERY SIMPLE;
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET AUTO_CLOSE OFF;
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET AUTO_SHRINK OFF;
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET COMPATIBILITY_LEVEL = ' + CONVERT(nvarchar(10), @EffectiveCompatibilityLevel) + N';';
                EXEC sys.sp_executesql @Sql;

                SET @Sql = N'
USE ' + QUOTENAME(@DatabaseName) + N';
EXEC sys.sp_addextendedproperty @name = N''SQLPERF.Project'', @value = @Project;
EXEC sys.sp_addextendedproperty @name = N''SQLPERF.ContractVersion'', @value = @Contract;
EXEC sys.sp_addextendedproperty @name = N''SQLPERF.DemoId'', @value = @Demo;
EXEC sys.sp_addextendedproperty @name = N''SQLPERF.RunToken'', @value = @Run;
EXEC sys.sp_addextendedproperty @name = N''SQLPERF.CreatedUtc'', @value = @CreatedUtc;';

                SET @ParameterDefinition = N'@Project nvarchar(128), @Contract nvarchar(32), @Demo nvarchar(32), @Run nvarchar(32), @CreatedUtc nvarchar(33)';

                SET @CreatedUtc = CONVERT(nvarchar(33), SYSUTCDATETIME(), 126);

                EXEC sys.sp_executesql
                    @Sql,
                    @ParameterDefinition,
                    @Project = @ProjectMarker,
                    @Contract = @ContractVersion,
                    @Demo = @DemoId,
                    @Run = @NormalizedRunToken,
                    @CreatedUtc = @CreatedUtc;

                INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
                VALUES ('LIFECYCLE', 'CREATE_DATABASE', 'PASS', 'OK', CASE WHEN @EmitEnvironmentDetails = 1 THEN @DatabaseName ELSE N'Name unterdrückt' END, CONCAT(N'Compatibility Level ', @EffectiveCompatibilityLevel), N'Die Testdatenbank wurde erstellt, konfiguriert und markiert.');
            END;
        END
        ELSE
        BEGIN
            INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
            VALUES ('LIFECYCLE', 'CREATE_DATABASE', 'PASS', 'OK', N'bereits vorhanden und passend markiert', N'idempotente Wiederverwendung', N'Die passende Testdatenbank wird unverändert wiederverwendet.');
        END;
    END
    ELSE IF @Action = 'VALIDATE'
    BEGIN
        IF @ExistingCompatibilityLevel = @EffectiveCompatibilityLevel AND @IsReadOnly = 0
        BEGIN
            INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
            VALUES ('LIFECYCLE', 'VALIDATE_DATABASE', 'PASS', 'OK', CONCAT(N'State=', @DatabaseState, N'; Compatibility=', @ExistingCompatibilityLevel, N'; ReadOnly=', @IsReadOnly), CONCAT(N'ONLINE; Compatibility=', @EffectiveCompatibilityLevel, N'; READ_WRITE'), N'Die Testdatenbank erfüllt Zustand, Compatibility Level und Marker-Vertrag.');
        END
        ELSE
        BEGIN
            INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
            VALUES ('LIFECYCLE', 'VALIDATE_DATABASE', 'FAIL', 'FAIL_STATE', CONCAT(N'State=', @DatabaseState, N'; Compatibility=', @ExistingCompatibilityLevel, N'; ReadOnly=', @IsReadOnly), CONCAT(N'ONLINE; Compatibility=', @EffectiveCompatibilityLevel, N'; READ_WRITE'), N'Die vorhandene Datenbank ist korrekt markiert, aber nicht in der angeforderten Konfiguration.');
        END;
    END
    ELSE IF @Action = 'DROP'
    BEGIN
        SET @Sql = N'
USE [master];
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE ' + QUOTENAME(@DatabaseName) + N';';
        EXEC sys.sp_executesql @Sql;

        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('CLEANUP', 'DROP_DATABASE', 'PASS', 'OK', CASE WHEN @EmitEnvironmentDetails = 1 THEN @DatabaseName ELSE N'Name unterdrückt' END, N'vollständig markierte Testdatenbank', N'Die eindeutig zugeordnete Testdatenbank wurde entfernt.');
    END;
END TRY
BEGIN CATCH
    SET @OriginalErrorNumber = ERROR_NUMBER();
    SET @OriginalErrorMessage = ERROR_MESSAGE();

    IF @CreatedInThisBatch = 1 AND DB_ID(@DatabaseName) IS NOT NULL
    BEGIN TRY
        SET @Sql = N'
USE [master];
ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE ' + QUOTENAME(@DatabaseName) + N';';
        EXEC sys.sp_executesql @Sql;

        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('CLEANUP', 'ROLLBACK_NEW_DATABASE', 'PASS', 'OK', N'gerade in diesem Batch erstellt', N'keine unvollständig markierte Datenbank', N'Die neu erstellte Datenbank wurde nach dem Fehler entfernt.');
    END TRY
    BEGIN CATCH
        INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
        VALUES ('CLEANUP', 'ROLLBACK_NEW_DATABASE', 'FAIL', 'FAIL_CLEANUP', N'Cleanup fehlgeschlagen', N'Entfernung der gerade erstellten Datenbank', N'Die unvollständig initialisierte Testdatenbank konnte nach dem Fehler nicht entfernt werden.');
    END CATCH;

    INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
    VALUES ('LIFECYCLE', 'EXECUTION_ERROR', 'FAIL', CASE WHEN EXISTS (SELECT 1 FROM @Results WHERE Code = 'FAIL_CLEANUP') THEN 'FAIL_CLEANUP' ELSE 'FAIL_EXECUTION' END, CONVERT(nvarchar(20), @OriginalErrorNumber), N'erfolgreiche Lifecycle-Aktion', LEFT(@OriginalErrorMessage, 4000));
END CATCH;

SET @Outcome = CASE
    WHEN EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'FAIL') THEN 'FAIL'
    WHEN EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'SKIP') THEN 'SKIP'
    WHEN EXISTS (SELECT 1 FROM @Results WHERE Outcome = 'WARN') THEN 'WARN'
    ELSE 'PASS'
END;

SET @Code = CASE @Outcome
    WHEN 'FAIL' THEN COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'FAIL' ORDER BY CASE WHEN Code = 'FAIL_CLEANUP' THEN 0 ELSE 1 END, Sequence), 'FAIL_EXECUTION')
    WHEN 'SKIP' THEN COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'SKIP' ORDER BY Sequence), 'SKIP_CONFIGURATION')
    WHEN 'WARN' THEN COALESCE((SELECT TOP (1) Code FROM @Results WHERE Outcome = 'WARN' ORDER BY Sequence), 'WARN_EMPIRICAL_VARIANCE')
    ELSE 'OK'
END;

SET @Message = CASE @Outcome
    WHEN 'PASS' THEN N'Die Lifecycle-Aktion wurde vertragsgemäß abgeschlossen.'
    WHEN 'WARN' THEN N'Die Lifecycle-Aktion wurde mit dokumentierter Einschränkung abgeschlossen.'
    WHEN 'SKIP' THEN N'Die Lifecycle-Aktion wurde kontrolliert nicht ausgeführt.'
    ELSE N'Die Lifecycle-Aktion ist fehlgeschlagen. Die Prüftabelle enthält Zustands- und Cleanup-Evidenz.'
END;

INSERT @Results (Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message)
VALUES ('LIFECYCLE', 'SUMMARY', @Outcome, @Code, NULL, NULL, @Message);

SELECT Sequence, Phase, CheckId, Outcome, Code, ObservedValue, RequiredValue, Message
FROM @Results
ORDER BY Sequence;

IF @Outcome = 'FAIL'
BEGIN
    SET @ErrorMessage = CONCAT(N'Testdatenbank-Lifecycle fehlgeschlagen: ', @Code, N'.');
    SET @ThrowNumber = CASE @Code WHEN 'FAIL_CLEANUP' THEN 51004 WHEN 'FAIL_STATE' THEN 51002 WHEN 'FAIL_SAFETY' THEN 51001 WHEN 'FAIL_CONTRACT' THEN 51000 ELSE 51003 END;
    THROW @ThrowNumber, @ErrorMessage, 1;
END;
