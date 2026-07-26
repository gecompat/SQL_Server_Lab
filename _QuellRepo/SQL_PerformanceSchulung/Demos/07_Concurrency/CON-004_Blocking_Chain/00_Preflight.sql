/* CON-004 / FWK-001 / FWK-008 / FWK-012 */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @DemoId varchar(7)='$(DemoId)',@RunToken varchar(20)='$(RunToken)',@TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
DECLARE @Expected sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken);
DECLARE @ConfirmIsolatedLab bit=$(ConfirmIsolatedLab),@HighImpactConfirmed bit=$(HighImpactConfirmed),@MaximumRuntimeSeconds int=$(MaximumRuntimeSeconds);
DECLARE @HasCreate bit=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'CREATE ANY DATABASE')=1 OR HAS_PERMS_BY_NAME(NULL,NULL,'ALTER ANY DATABASE')=1 OR HAS_PERMS_BY_NAME(N'master','DATABASE','CREATE DATABASE')=1 THEN 1 ELSE 0 END;
DECLARE @HasState bit=0;
IF @DemoId<>'CON-004' OR @TargetDatabase<>@Expected THROW 51000,'FAIL_CONTRACT: CON-004-Zielkennung ist ungültig.',1;
IF @Major>=16 SET @HasState=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER PERFORMANCE STATE')=1 OR IS_SRVROLEMEMBER('sysadmin')=1 THEN 1 ELSE 0 END;
ELSE SET @HasState=CASE WHEN HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER STATE')=1 OR IS_SRVROLEMEMBER('sysadmin')=1 THEN 1 ELSE 0 END;
IF @Major NOT BETWEEN 15 AND 17 BEGIN SELECT 1 Sequence,'PREFLIGHT' Phase,'ENGINE_VERSION' CheckId,'SKIP' Outcome,'SKIP_VERSION' Code,CONVERT(nvarchar(20),@Major) ObservedValue,N'15 bis 17' RequiredValue,N'CON-004 unterstützt SQL Server 2019 bis 2025.' Message;PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_VERSION';RETURN;END;
IF @HasCreate=0 OR @HasState=0 BEGIN SELECT 1 Sequence,'PREFLIGHT' Phase,'PERMISSIONS' CheckId,'SKIP' Outcome,'SKIP_PERMISSION' Code,CONCAT(N'Create=',@HasCreate,N'; State=',@HasState) ObservedValue,N'CREATE DATABASE und Server-State-Sichtbarkeit' RequiredValue,N'Blocking-Evidenz ist mit den verfügbaren Rechten nicht belastbar.' Message;PRINT 'SQLPERF_SUMMARY|SKIP|SKIP_PERMISSION';RETURN;END;
IF @ConfirmIsolatedLab<>1 OR @HighImpactConfirmed<>1 OR @MaximumRuntimeSeconds<=0 THROW 51001,'FAIL_SAFETY: CON-004 benötigt isoliertes Lab, High-Impact-Bestätigung und positives Zeitbudget.',1;
SELECT 1 Sequence,'PREFLIGHT' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,CONCAT(N'Major=',@Major,N'; Safety=YELLOW; Runtime=',@MaximumRuntimeSeconds) ObservedValue,N'isoliertes Lab; maximal 4 Sessions; positive Laufzeitgrenze' RequiredValue,N'Preflight für CON-004 ist bestanden.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
