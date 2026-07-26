/* OPT-002 / FWK-001 / FWK-008 / FWK-012 */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DemoId varchar(7)='$(DemoId)';
DECLARE @RunToken varchar(20)='$(RunToken)';
DECLARE @TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @MajorVersion int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
DECLARE @ExpectedDatabase sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken);
DECLARE @HasCreateDatabase bit=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'CREATE ANY DATABASE')=1 OR HAS_PERMS_BY_NAME(NULL,NULL,'ALTER ANY DATABASE')=1 OR HAS_PERMS_BY_NAME(N'master','DATABASE','CREATE DATABASE')=1 THEN 1 ELSE 0 END;

IF @DemoId<>'OPT-002' OR @TargetDatabase<>@ExpectedDatabase OR @RunToken COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Z0-9_]%'
    THROW 51000,'FAIL_CONTRACT: OPT-002-Zielkennung ist ungültig.',1;

IF @MajorVersion NOT BETWEEN 15 AND 17
BEGIN
    SELECT 1 Sequence,'PREFLIGHT' Phase,'ENGINE_VERSION' CheckId,'SKIP' Outcome,'SKIP_VERSION' Code,
           CONVERT(nvarchar(20),@MajorVersion) ObservedValue,N'15 bis 17' RequiredValue,
           N'OPT-002 unterstützt SQL Server 2019 bis 2025.' Message;
    PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_VERSION';
    RETURN;
END;

IF @HasCreateDatabase=0
BEGIN
    SELECT 1 Sequence,'PREFLIGHT' Phase,'PERMISSIONS' CheckId,'SKIP' Outcome,'SKIP_PERMISSION' Code,
           N'CREATE DATABASE fehlt' ObservedValue,N'isolierte Testdatenbank anlegen' RequiredValue,
           N'OPT-002 wird ohne Lab-Berechtigung kontrolliert übersprungen.' Message;
    PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_PERMISSION';
    RETURN;
END;

SELECT 1 Sequence,'PREFLIGHT' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,
       CONCAT(N'Major=',@MajorVersion,N'; Zielkennung validiert') ObservedValue,
       N'SQL Server 2019 bis 2025' RequiredValue,N'Preflight für OPT-002 ist bestanden.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
