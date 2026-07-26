/* OPT-002 setup: deterministic skew and sampled multi-column statistics. */
USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @DemoId varchar(7)='$(DemoId)',@RunToken varchar(20)='$(RunToken)',@TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @Expected sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken);
DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
DECLARE @Cl int=CASE @Major WHEN 15 THEN 150 WHEN 16 THEN 160 WHEN 17 THEN 170 END;
DECLARE @Created bit=0,@Sql nvarchar(max),@Project nvarchar(128),@Contract nvarchar(32),@ExistingDemo varchar(7),@ExistingRun varchar(20);
IF @DemoId<>'OPT-002' OR @TargetDatabase<>@Expected OR @Cl IS NULL THROW 51000,'FAIL_CONTRACT: OPT-002-Zielkennung ist ungültig.',1;
IF DB_ID(@TargetDatabase) IS NULL BEGIN SET @Sql=N'CREATE DATABASE '+QUOTENAME(@TargetDatabase)+N';';EXEC sys.sp_executesql @Sql;SET @Created=1;END;
SET @Sql=N'ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET RECOVERY SIMPLE; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET AUTO_CLOSE OFF; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET AUTO_SHRINK OFF; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET PAGE_VERIFY CHECKSUM; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(10),@Cl)+N';';EXEC sys.sp_executesql @Sql;
IF @Created=1
BEGIN
 SET @Sql=N'USE '+QUOTENAME(@TargetDatabase)+N'; EXEC sys.sp_addextendedproperty @name=N''SQLPERF.Project'',@value=N''SQL_PerformanceSchulung''; EXEC sys.sp_addextendedproperty @name=N''SQLPERF.ContractVersion'',@value=N''1.0''; EXEC sys.sp_addextendedproperty @name=N''SQLPERF.DemoId'',@value=@Demo; EXEC sys.sp_addextendedproperty @name=N''SQLPERF.RunToken'',@value=@Run;';
 EXEC sys.sp_executesql @Sql,N'@Demo varchar(7),@Run varchar(20)',@Demo=@DemoId,@Run=@RunToken;
END
ELSE
BEGIN
 SET @Sql=N'SELECT @P=MAX(CASE WHEN name=N''SQLPERF.Project'' THEN CONVERT(nvarchar(128),value) END),@C=MAX(CASE WHEN name=N''SQLPERF.ContractVersion'' THEN CONVERT(nvarchar(32),value) END),@D=MAX(CASE WHEN name=N''SQLPERF.DemoId'' THEN CONVERT(varchar(7),value) END),@R=MAX(CASE WHEN name=N''SQLPERF.RunToken'' THEN CONVERT(varchar(20),value) END) FROM '+QUOTENAME(@TargetDatabase)+N'.sys.extended_properties WHERE class=0 AND major_id=0 AND minor_id=0;';
 EXEC sys.sp_executesql @Sql,N'@P nvarchar(128) OUTPUT,@C nvarchar(32) OUTPUT,@D varchar(7) OUTPUT,@R varchar(20) OUTPUT',@P=@Project OUTPUT,@C=@Contract OUTPUT,@D=@ExistingDemo OUTPUT,@R=@ExistingRun OUTPUT;
 IF @Project<>N'SQL_PerformanceSchulung' OR @Contract<>N'1.0' OR @ExistingDemo<>@DemoId OR @ExistingRun<>@RunToken THROW 51002,'FAIL_STATE: Gleichnamige Datenbank besitzt nicht die erwarteten Marker.',1;
END;
GO
USE [$(TargetDatabase)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF SCHEMA_ID(N'lab') IS NULL EXEC(N'CREATE SCHEMA lab AUTHORIZATION dbo;');
DROP TABLE IF EXISTS lab.Opt002Evidence;
DROP TABLE IF EXISTS lab.StatisticsData;
CREATE TABLE lab.StatisticsData
(
 StatisticsDataId int NOT NULL CONSTRAINT PK_StatisticsData PRIMARY KEY CLUSTERED,
 CategoryId int NOT NULL,
 RegionId int NOT NULL,
 Amount decimal(12,2) NOT NULL,
 Payload char(400) NOT NULL
);
CREATE TABLE lab.Opt002Evidence
(
 Phase varchar(20) NOT NULL CONSTRAINT PK_Opt002Evidence PRIMARY KEY,
 TotalRows bigint NOT NULL,
 HotRows bigint NOT NULL,
 RowsSampled bigint NULL,
 HistogramSteps int NULL,
 HotEqualRows float NULL,
 FirstStatsColumn sysname NULL,
 CapturedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_Opt002Evidence_Captured DEFAULT SYSUTCDATETIME()
);
;WITH D AS(SELECT n FROM(VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9))v(n)),N AS
(
 SELECT TOP(100000) n=1+d0.n+d1.n*10+d2.n*100+d3.n*1000+d4.n*10000+d5.n*100000
 FROM D d0 CROSS JOIN D d1 CROSS JOIN D d2 CROSS JOIN D d3 CROSS JOIN D d4 CROSS JOIN D d5 ORDER BY 1
)
INSERT lab.StatisticsData(StatisticsDataId,CategoryId,RegionId,Amount,Payload)
SELECT n,CASE WHEN n<=50000 THEN 1 ELSE 2+((n-50001)%100) END,1+(n%10),CONVERT(decimal(12,2),(n%10000)/10.0),REPLICATE(CHAR(65+n%26),400)
FROM N OPTION(MAXDOP 1);
CREATE STATISTICS ST_StatisticsData_Category_Region ON lab.StatisticsData(CategoryId,RegionId) WITH SAMPLE 1000 ROWS,NORECOMPUTE;
IF (SELECT COUNT_BIG(*) FROM lab.StatisticsData)<>100000 THROW 51003,'FAIL_EXECUTION: OPT-002-Datenmenge ist unvollständig.',1;
SELECT 1 Sequence,'SETUP' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'100000 breite Zeilen; 101 Kategorien; explizites Sample von 1000 Zeilen' ObservedValue,N'deterministische Verteilung mit echter Stichprobe' RequiredValue,N'OPT-002 wurde aufgebaut.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
GO
