/* OPT-013 cleanup: marker-verified removal of the isolated spill database. */
USE [master];
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DemoId varchar(7)='$(DemoId)';
DECLARE @RunToken varchar(20)='$(RunToken)';
DECLARE @TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @Expected sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken);
DECLARE @Project nvarchar(128),@Contract nvarchar(32),@ExistingDemo varchar(7),@ExistingRun varchar(20);
DECLARE @Sql nvarchar(max);

IF @DemoId<>'OPT-013' OR @TargetDatabase<>@Expected
    THROW 51000,'FAIL_CONTRACT: OPT-013-Cleanupziel ist ungültig.',1;

IF DB_ID(@TargetDatabase) IS NULL
BEGIN
    SELECT 1 Sequence,'CLEANUP' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,
           N'Zieldatenbank bereits nicht vorhanden' ObservedValue,N'idempotenter Cleanup' RequiredValue,
           N'Es war keine Bereinigung erforderlich.' Message;
    PRINT 'SQLPERF_SUMMARY|PASS|OK';
    RETURN;
END;

SET @Sql=N'SELECT
 @ProjectOut=MAX(CASE WHEN name=N''SQLPERF.Project'' THEN CONVERT(nvarchar(128),value) END),
 @ContractOut=MAX(CASE WHEN name=N''SQLPERF.ContractVersion'' THEN CONVERT(nvarchar(32),value) END),
 @DemoOut=MAX(CASE WHEN name=N''SQLPERF.DemoId'' THEN CONVERT(varchar(7),value) END),
 @RunOut=MAX(CASE WHEN name=N''SQLPERF.RunToken'' THEN CONVERT(varchar(20),value) END)
FROM '+QUOTENAME(@TargetDatabase)+N'.sys.extended_properties
WHERE class=0 AND major_id=0 AND minor_id=0;';
EXEC sys.sp_executesql @Sql,
 N'@ProjectOut nvarchar(128) OUTPUT,@ContractOut nvarchar(32) OUTPUT,@DemoOut varchar(7) OUTPUT,@RunOut varchar(20) OUTPUT',
 @ProjectOut=@Project OUTPUT,@ContractOut=@Contract OUTPUT,@DemoOut=@ExistingDemo OUTPUT,@RunOut=@ExistingRun OUTPUT;

IF @Project<>N'SQL_PerformanceSchulung' OR @Contract<>N'1.0' OR @ExistingDemo<>@DemoId OR @ExistingRun<>@RunToken
    THROW 51004,'FAIL_CLEANUP: OPT-013-Eigentumsmarker stimmen nicht vollständig überein.',1;

SET @Sql=N'ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE '+QUOTENAME(@TargetDatabase)+N';';
EXEC sys.sp_executesql @Sql;

SELECT 1 Sequence,'CLEANUP' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,
       N'markierte OPT-013-Datenbank entfernt' ObservedValue,N'vollständige Markerübereinstimmung' RequiredValue,
       N'Der definierte Ausgangszustand ist wiederhergestellt.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
