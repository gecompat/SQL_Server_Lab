/* CON-004 cleanup: only the marked isolated database can be removed. */
USE [master];SET NOCOUNT ON;SET XACT_ABORT ON;
DECLARE @DemoId varchar(7)='$(DemoId)',@RunToken varchar(20)='$(RunToken)',@TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @Expected sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken),@P nvarchar(128),@C nvarchar(32),@D varchar(7),@R varchar(20),@Sql nvarchar(max);
IF @DemoId<>'CON-004' OR @TargetDatabase<>@Expected THROW 51000,'FAIL_CONTRACT: CON-004-Cleanupziel ist ungültig.',1;
IF DB_ID(@TargetDatabase) IS NULL BEGIN SELECT 1 Sequence,'CLEANUP' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'bereits nicht vorhanden' ObservedValue,N'idempotent' RequiredValue,N'Kein Cleanup erforderlich.' Message;PRINT 'SQLPERF_SUMMARY|PASS|OK';RETURN;END;
SET @Sql=N'SELECT @P=MAX(CASE WHEN name=N''SQLPERF.Project'' THEN CONVERT(nvarchar(128),value) END),@C=MAX(CASE WHEN name=N''SQLPERF.ContractVersion'' THEN CONVERT(nvarchar(32),value) END),@D=MAX(CASE WHEN name=N''SQLPERF.DemoId'' THEN CONVERT(varchar(7),value) END),@R=MAX(CASE WHEN name=N''SQLPERF.RunToken'' THEN CONVERT(varchar(20),value) END) FROM '+QUOTENAME(@TargetDatabase)+N'.sys.extended_properties WHERE class=0 AND major_id=0 AND minor_id=0;';
EXEC sys.sp_executesql @Sql,N'@P nvarchar(128) OUTPUT,@C nvarchar(32) OUTPUT,@D varchar(7) OUTPUT,@R varchar(20) OUTPUT',@P=@P OUTPUT,@C=@C OUTPUT,@D=@D OUTPUT,@R=@R OUTPUT;
IF @P<>N'SQL_PerformanceSchulung' OR @C<>N'1.0' OR @D<>@DemoId OR @R<>@RunToken THROW 51004,'FAIL_CLEANUP: CON-004-Eigentumsmarker stimmen nicht überein.',1;
SET @Sql=N'ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;DROP DATABASE '+QUOTENAME(@TargetDatabase)+N';';EXEC sys.sp_executesql @Sql;
SELECT 1 Sequence,'CLEANUP' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'markierte CON-004-Datenbank entfernt' ObservedValue,N'vollständige Markerübereinstimmung' RequiredValue,N'Alle Lab-Transaktionen und Objekte sind bereinigt.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
