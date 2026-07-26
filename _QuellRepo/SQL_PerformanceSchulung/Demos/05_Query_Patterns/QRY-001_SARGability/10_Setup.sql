/* QRY-001 setup: synthetic, idempotent, marker protected. */
USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DemoId varchar(7) = '$(DemoId)';
DECLARE @RunToken varchar(20) = '$(RunToken)';
DECLARE @TargetDatabase sysname = N'$(TargetDatabase)';
DECLARE @ExpectedDatabase sysname = CONVERT(sysname, N'SQLPERF_LAB_' + REPLACE(@DemoId, '-', '') + N'_' + @RunToken);
DECLARE @MajorVersion int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @CompatibilityLevel int = CASE @MajorVersion WHEN 15 THEN 150 WHEN 16 THEN 160 WHEN 17 THEN 170 END;
DECLARE @Created bit = 0;
DECLARE @Sql nvarchar(max);
DECLARE @Project nvarchar(128);
DECLARE @Contract nvarchar(32);
DECLARE @ExistingDemo varchar(7);
DECLARE @ExistingRun varchar(20);

IF @DemoId <> 'QRY-001' OR @TargetDatabase <> @ExpectedDatabase OR @CompatibilityLevel IS NULL
    THROW 51000, 'FAIL_CONTRACT: QRY-001-Zielkennung oder Engine-Version ist ungültig.', 1;

IF DB_ID(@TargetDatabase) IS NULL
BEGIN
    SET @Sql = N'CREATE DATABASE ' + QUOTENAME(@TargetDatabase) + N';';
    EXEC sys.sp_executesql @Sql;
    SET @Created = 1;
END;

SET @Sql = N'ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET RECOVERY SIMPLE;
ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET AUTO_CLOSE OFF;
ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET AUTO_SHRINK OFF;
ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE ' + QUOTENAME(@TargetDatabase) + N' SET COMPATIBILITY_LEVEL = ' + CONVERT(nvarchar(10), @CompatibilityLevel) + N';';
EXEC sys.sp_executesql @Sql;

IF @Created = 1
BEGIN
    SET @Sql = N'USE ' + QUOTENAME(@TargetDatabase) + N';
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.Project'', @value=N''SQL_PerformanceSchulung'';
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.ContractVersion'', @value=N''1.0'';
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.DemoId'', @value=@DemoId;
EXEC sys.sp_addextendedproperty @name=N''SQLPERF.RunToken'', @value=@RunToken;';
    EXEC sys.sp_executesql @Sql, N'@DemoId varchar(7), @RunToken varchar(20)', @DemoId=@DemoId, @RunToken=@RunToken;
END
ELSE
BEGIN
    SET @Sql = N'SELECT
 @ProjectOut=MAX(CASE WHEN name=N''SQLPERF.Project'' THEN CONVERT(nvarchar(128),value) END),
 @ContractOut=MAX(CASE WHEN name=N''SQLPERF.ContractVersion'' THEN CONVERT(nvarchar(32),value) END),
 @DemoOut=MAX(CASE WHEN name=N''SQLPERF.DemoId'' THEN CONVERT(varchar(7),value) END),
 @RunOut=MAX(CASE WHEN name=N''SQLPERF.RunToken'' THEN CONVERT(varchar(20),value) END)
FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.extended_properties WHERE class=0 AND major_id=0 AND minor_id=0;';
    EXEC sys.sp_executesql @Sql,
        N'@ProjectOut nvarchar(128) OUTPUT,@ContractOut nvarchar(32) OUTPUT,@DemoOut varchar(7) OUTPUT,@RunOut varchar(20) OUTPUT',
        @ProjectOut=@Project OUTPUT,@ContractOut=@Contract OUTPUT,@DemoOut=@ExistingDemo OUTPUT,@RunOut=@ExistingRun OUTPUT;
    IF @Project <> N'SQL_PerformanceSchulung' OR @Contract <> N'1.0' OR @ExistingDemo <> @DemoId OR @ExistingRun <> @RunToken
        THROW 51002, 'FAIL_STATE: Eine gleichnamige Datenbank besitzt nicht die erwarteten Eigentumsmarker.', 1;
END;
GO

USE [$(TargetDatabase)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID(N'lab') IS NULL EXEC(N'CREATE SCHEMA lab AUTHORIZATION dbo;');
DROP TABLE IF EXISTS lab.Qry001Evidence;
DROP TABLE IF EXISTS lab.SearchData;

CREATE TABLE lab.SearchData
(
    SearchId int NOT NULL CONSTRAINT PK_SearchData PRIMARY KEY CLUSTERED,
    EventDateTime datetime2(0) NOT NULL,
    MeasureValue int NOT NULL,
    Payload char(40) NOT NULL
);

CREATE TABLE lab.Qry001Evidence
(
    Phase varchar(20) NOT NULL CONSTRAINT PK_Qry001Evidence PRIMARY KEY,
    ResultValue bigint NOT NULL,
    LogicalReads bigint NOT NULL,
    AccessMethod varchar(32) NOT NULL,
    CapturedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_Qry001Evidence_Captured DEFAULT SYSUTCDATETIME()
);

;WITH Digits AS
(
    SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) d(n)
), Numbers AS
(
    SELECT TOP (300000)
        n = 1 + d0.n + d1.n*10 + d2.n*100 + d3.n*1000 + d4.n*10000 + d5.n*100000
    FROM Digits d0 CROSS JOIN Digits d1 CROSS JOIN Digits d2
    CROSS JOIN Digits d3 CROSS JOIN Digits d4 CROSS JOIN Digits d5
    ORDER BY 1
)
INSERT lab.SearchData(SearchId, EventDateTime, MeasureValue, Payload)
SELECT n,
       DATEADD(minute, CONVERT(int,(CONVERT(bigint,n)*37)%1051200), CONVERT(datetime2(0),'20230101')),
       n%1000,
       REPLICATE(CHAR(65+n%26),40)
FROM Numbers
OPTION (MAXDOP 1);

CREATE INDEX IX_SearchData_EventDateTime
ON lab.SearchData(EventDateTime)
INCLUDE(MeasureValue);

IF (SELECT COUNT_BIG(*) FROM lab.SearchData) <> 300000
    THROW 51003, 'FAIL_EXECUTION: QRY-001-Datenmenge ist unvollständig.', 1;

SELECT 1 AS Sequence, 'SETUP' AS Phase, 'SUMMARY' AS CheckId,
       'PASS' AS Outcome, 'OK' AS Code,
       N'300000 synthetische Zeilen; abdeckender Datumsindex' AS ObservedValue,
       N'markierte isolierte Testdatenbank' AS RequiredValue,
       N'QRY-001 wurde reproduzierbar aufgebaut.' AS Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
GO
