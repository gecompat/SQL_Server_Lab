/* OPT-013 setup: marker-protected database with deterministic wide rows. */
USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DemoId varchar(7)='$(DemoId)';
DECLARE @RunToken varchar(20)='$(RunToken)';
DECLARE @TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @Expected sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken);
DECLARE @Major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
DECLARE @Compatibility int=CASE @Major WHEN 15 THEN 150 WHEN 16 THEN 160 WHEN 17 THEN 170 END;
DECLARE @Created bit=0;
DECLARE @Sql nvarchar(max);
DECLARE @Project nvarchar(128),@Contract nvarchar(32),@ExistingDemo varchar(7),@ExistingRun varchar(20);

IF @DemoId<>'OPT-013' OR @TargetDatabase<>@Expected OR @Compatibility IS NULL
    THROW 51000,'FAIL_CONTRACT: OPT-013-Zielkennung oder Engine-Version ist ungültig.',1;

IF DB_ID(@TargetDatabase) IS NULL
BEGIN
    SET @Sql=N'CREATE DATABASE '+QUOTENAME(@TargetDatabase)+N';';
    EXEC sys.sp_executesql @Sql;
    SET @Created=1;
END;

SET @Sql=N'ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET RECOVERY SIMPLE;
ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET AUTO_CLOSE OFF;
ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET AUTO_SHRINK OFF;
ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(10),@Compatibility)+N';';
EXEC sys.sp_executesql @Sql;

IF @Created=1
BEGIN
    SET @Sql=N'USE '+QUOTENAME(@TargetDatabase)+N';
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.Project'',@value=N''SQL_PerformanceSchulung'';
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.ContractVersion'',@value=N''1.0'';
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.DemoId'',@value=@Demo;
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.RunToken'',@value=@Run;';
    EXEC sys.sp_executesql @Sql,N'@Demo varchar(7),@Run varchar(20)',@Demo=@DemoId,@Run=@RunToken;
END
ELSE
BEGIN
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
        THROW 51002,'FAIL_STATE: Eine gleichnamige Datenbank besitzt nicht die erwarteten Eigentumsmarker.',1;
END;
GO

USE [$(TargetDatabase)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID(N'lab') IS NULL EXEC(N'CREATE SCHEMA lab AUTHORIZATION dbo;');
DROP TABLE IF EXISTS lab.SpillStage;
DROP TABLE IF EXISTS lab.SpillEvidence;
DROP TABLE IF EXISTS lab.SpillData;

CREATE TABLE lab.SpillData
(
    SpillDataId int NOT NULL CONSTRAINT PK_SpillData PRIMARY KEY CLUSTERED,
    SortKey int NOT NULL,
    Payload char(200) NOT NULL,
    MeasureValue int NOT NULL
);

CREATE TABLE lab.SpillEvidence
(
    Phase varchar(20) NOT NULL CONSTRAINT PK_SpillEvidence PRIMARY KEY,
    ResultChecksum int NULL,
    LastSpills bigint NOT NULL,
    PlanHasSort bit NOT NULL,
    LastGrantKb bigint NOT NULL,
    LastUsedGrantKb bigint NOT NULL,
    ActualRows bigint NOT NULL,
    InputKind varchar(32) NOT NULL,
    CapturedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_SpillEvidence_Captured DEFAULT SYSUTCDATETIME()
);

;WITH Digits AS
(
    SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) d(n)
), Numbers AS
(
    SELECT TOP(300000)
        n=1+d0.n+d1.n*10+d2.n*100+d3.n*1000+d4.n*10000+d5.n*100000
    FROM Digits d0 CROSS JOIN Digits d1 CROSS JOIN Digits d2
    CROSS JOIN Digits d3 CROSS JOIN Digits d4 CROSS JOIN Digits d5
    ORDER BY 1
)
INSERT lab.SpillData(SpillDataId,SortKey,Payload,MeasureValue)
SELECT n,
       CONVERT(int,(CONVERT(bigint,n)*7919)%300000),
       CONVERT(char(200),REPLICATE(CHAR(65+(n%26)),180)+RIGHT(REPLICATE('0',20)+CONVERT(varchar(20),n),20)),
       n%10000
FROM Numbers
OPTION(MAXDOP 1);

IF (SELECT COUNT_BIG(*) FROM lab.SpillData)<>300000
    THROW 51003,'FAIL_EXECUTION: OPT-013-Datenmenge ist unvollständig.',1;

SELECT 1 Sequence,'SETUP' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,
       N'300000 deterministische Zeilen mit 200-Byte-Sortiernutzlast' ObservedValue,
       N'isolierte markierte Testdatenbank; Basistabelle mit sichtbarer Kardinalität' RequiredValue,
       N'OPT-013 wurde reproduzierbar aufgebaut.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
GO
