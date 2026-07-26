/* QRY-001 / FWK-001 / FWK-008 / FWK-012 */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DemoId varchar(7) = '$(DemoId)';
DECLARE @RunToken varchar(20) = '$(RunToken)';
DECLARE @TargetDatabase sysname = N'$(TargetDatabase)';
DECLARE @MajorVersion int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @ExpectedDatabase sysname = CONVERT(sysname, N'SQLPERF_LAB_' + REPLACE(@DemoId, '-', '') + N'_' + @RunToken);
DECLARE @HasCreateDatabase bit = 0;
DECLARE @HasServerState bit = 0;

IF @DemoId <> 'QRY-001'
   OR @RunToken IS NULL
   OR LEN(@RunToken) NOT BETWEEN 1 AND 20
   OR @RunToken COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Z0-9_]%'
   OR @TargetDatabase <> @ExpectedDatabase
    THROW 51000, 'FAIL_CONTRACT: Demo-ID, Run-Token oder Ziel-Datenbank entsprechen nicht dem QRY-001-Vertrag.', 1;

IF @MajorVersion NOT BETWEEN 15 AND 17
BEGIN
    SELECT 1 AS Sequence, 'PREFLIGHT' AS Phase, 'ENGINE_VERSION' AS CheckId,
           'SKIP' AS Outcome, 'SKIP_VERSION' AS Code,
           CONVERT(nvarchar(20), @MajorVersion) AS ObservedValue,
           N'15 bis 17' AS RequiredValue,
           N'QRY-001 unterstützt SQL Server 2019 bis 2025.' AS Message;
    PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_VERSION';
    RETURN;
END;

SET @HasCreateDatabase = CASE
    WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE ANY DATABASE') = 1
      OR HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY DATABASE') = 1
      OR HAS_PERMS_BY_NAME(N'master', 'DATABASE', 'CREATE DATABASE') = 1
    THEN 1 ELSE 0 END;

IF @MajorVersion >= 16
    SET @HasServerState = CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE') = 1 OR IS_SRVROLEMEMBER('sysadmin') = 1 THEN 1 ELSE 0 END;
ELSE
    SET @HasServerState = CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') = 1 OR IS_SRVROLEMEMBER('sysadmin') = 1 THEN 1 ELSE 0 END;

IF @HasCreateDatabase = 0 OR @HasServerState = 0
BEGIN
    SELECT 1 AS Sequence, 'PREFLIGHT' AS Phase, 'PERMISSIONS' AS CheckId,
           'SKIP' AS Outcome, 'SKIP_PERMISSION' AS Code,
           CONCAT(N'CreateDatabase=', @HasCreateDatabase, N'; ServerState=', @HasServerState) AS ObservedValue,
           N'CREATE DATABASE und versionsgerechte Server-State-Berechtigung' AS RequiredValue,
           N'Die Demo wird ohne die erforderlichen Lab- und Planevidenzrechte nicht ausgeführt.' AS Message;
    PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_PERMISSION';
    RETURN;
END;

SELECT 1 AS Sequence, 'PREFLIGHT' AS Phase, 'SUMMARY' AS CheckId,
       'PASS' AS Outcome, 'OK' AS Code,
       CONCAT(N'Major=', @MajorVersion, N'; Zielkennung validiert') AS ObservedValue,
       N'SQL Server 2019 bis 2025; kanonische synthetische Datenbank' AS RequiredValue,
       N'Preflight für QRY-001 ist bestanden.' AS Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
