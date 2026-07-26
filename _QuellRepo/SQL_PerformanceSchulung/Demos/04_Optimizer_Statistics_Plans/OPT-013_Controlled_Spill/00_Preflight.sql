/* OPT-013 / FWK-001 / FWK-008 / FWK-012 */
SET NOCOUNT ON;SET XACT_ABORT ON;
DECLARE @DemoId varchar(7)='$(DemoId)',@RunToken varchar(20)='$(RunToken)',@TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),@Expected sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken);
DECLARE @Confirm bit=$(ConfirmIsolatedLab),@Impact bit=$(HighImpactConfirmed),@Runtime int=$(MaximumRuntimeSeconds);
DECLARE @HasCreate bit=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'CREATE ANY DATABASE')=1 OR HAS_PERMS_BY_NAME(NULL,NULL,'ALTER ANY DATABASE')=1 OR HAS_PERMS_BY_NAME(N'master','DATABASE','CREATE DATABASE')=1 THEN 1 ELSE 0 END,@HasState bit=0;
IF @DemoId<>'OPT-013' OR @TargetDatabase<>@Expected THROW 51000,'FAIL_CONTRACT: OPT-013-Zielkennung ist ungültig.',1;
IF @Major>=16 SET @HasState=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER PERFORMANCE STATE')=1 OR IS_SRVROLEMEMBER('sysadmin')=1 THEN 1 ELSE 0 END;ELSE SET @HasState=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER STATE')=1 OR IS_SRVROLEMEMBER('sysadmin')=1 THEN 1 ELSE 0 END;
IF @Major NOT BETWEEN 15 AND 17 BEGIN SELECT 1 Sequence,'PREFLIGHT' Phase,'ENGINE_VERSION' CheckId,'SKIP' Outcome,'SKIP_VERSION' Code,CONVERT(nvarchar(20),@Major) ObservedValue,N'15 bis 17' RequiredValue,N'OPT-013 unterstützt SQL Server 2019 bis 2025.' Message;PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_VERSION';RETURN;END;
IF @HasCreate=0 OR @HasState=0 BEGIN SELECT 1 Sequence,'PREFLIGHT' Phase,'PERMISSIONS' CheckId,'SKIP' Outcome,'SKIP_PERMISSION' Code,CONCAT(N'Create=',@HasCreate,N'; State=',@HasState) ObservedValue,N'CREATE DATABASE und Server-State-Sichtbarkeit' RequiredValue,N'Spill-Evidenz kann nicht belastbar erhoben werden.' Message;PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_PERMISSION';RETURN;END;
IF @Confirm<>1 OR @Impact<>1 OR @Runtime<=0 THROW 51001,'FAIL_SAFETY: OPT-013 benötigt isoliertes Lab, High-Impact-Bestätigung und positives Zeitbudget.',1;
SELECT 1 Sequence,'PREFLIGHT' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,CONCAT(N'Major=',@Major,N'; Safety=YELLOW; Runtime=',@Runtime) ObservedValue,N'isoliertes Lab; MAXDOP 1; begrenztes Zeitbudget' RequiredValue,N'Preflight für OPT-013 ist bestanden.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
