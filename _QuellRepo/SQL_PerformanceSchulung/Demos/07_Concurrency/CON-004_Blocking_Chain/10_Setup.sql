/* CON-004 setup: marker-protected database plus deterministic signal primitives. */
USE [master];
GO
SET NOCOUNT ON;SET XACT_ABORT ON;
DECLARE @DemoId varchar(7)='$(DemoId)',@RunToken varchar(20)='$(RunToken)',@TargetDatabase sysname=N'$(TargetDatabase)';
DECLARE @Expected sysname=CONVERT(sysname,N'SQLPERF_LAB_'+REPLACE(@DemoId,'-','')+N'_'+@RunToken),@Major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
DECLARE @Cl int=CASE @Major WHEN 15 THEN 150 WHEN 16 THEN 160 WHEN 17 THEN 170 END,@Created bit=0,@Sql nvarchar(max),@P nvarchar(128),@C nvarchar(32),@D varchar(7),@R varchar(20);
IF @DemoId<>'CON-004' OR @TargetDatabase<>@Expected OR @Cl IS NULL THROW 51000,'FAIL_CONTRACT: CON-004-Zielkennung ist ungültig.',1;
IF DB_ID(@TargetDatabase) IS NULL BEGIN SET @Sql=N'CREATE DATABASE '+QUOTENAME(@TargetDatabase)+N';';EXEC sys.sp_executesql @Sql;SET @Created=1;END;
SET @Sql=N'ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET RECOVERY SIMPLE; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET AUTO_CLOSE OFF; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET AUTO_SHRINK OFF; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET PAGE_VERIFY CHECKSUM; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET COMPATIBILITY_LEVEL='+CONVERT(nvarchar(10),@Cl)+N';';EXEC sys.sp_executesql @Sql;
IF @Created=1 BEGIN SET @Sql=N'USE '+QUOTENAME(@TargetDatabase)+N';EXEC sys.sp_addextendedproperty @name=N''SQLPERF.Project'',@value=N''SQL_PerformanceSchulung'';EXEC sys.sp_addextendedproperty @name=N''SQLPERF.ContractVersion'',@value=N''1.0'';EXEC sys.sp_addextendedproperty @name=N''SQLPERF.DemoId'',@value=@D;EXEC sys.sp_addextendedproperty @name=N''SQLPERF.RunToken'',@value=@R;';EXEC sys.sp_executesql @Sql,N'@D varchar(7),@R varchar(20)',@D=@DemoId,@R=@RunToken;END
ELSE BEGIN SET @Sql=N'SELECT @P=MAX(CASE WHEN name=N''SQLPERF.Project'' THEN CONVERT(nvarchar(128),value) END),@C=MAX(CASE WHEN name=N''SQLPERF.ContractVersion'' THEN CONVERT(nvarchar(32),value) END),@D=MAX(CASE WHEN name=N''SQLPERF.DemoId'' THEN CONVERT(varchar(7),value) END),@R=MAX(CASE WHEN name=N''SQLPERF.RunToken'' THEN CONVERT(varchar(20),value) END) FROM '+QUOTENAME(@TargetDatabase)+N'.sys.extended_properties WHERE class=0 AND major_id=0 AND minor_id=0;';EXEC sys.sp_executesql @Sql,N'@P nvarchar(128) OUTPUT,@C nvarchar(32) OUTPUT,@D varchar(7) OUTPUT,@R varchar(20) OUTPUT',@P=@P OUTPUT,@C=@C OUTPUT,@D=@D OUTPUT,@R=@R OUTPUT;IF @P<>N'SQL_PerformanceSchulung' OR @C<>N'1.0' OR @D<>@DemoId OR @R<>@RunToken THROW 51002,'FAIL_STATE: Gleichnamige Datenbank besitzt nicht die erwarteten Marker.',1;END;
GO
USE [$(TargetDatabase)];
GO
SET NOCOUNT ON;SET XACT_ABORT ON;
IF SCHEMA_ID(N'lab') IS NULL EXEC(N'CREATE SCHEMA lab AUTHORIZATION dbo;');
IF SCHEMA_ID(N'fwk') IS NULL EXEC(N'CREATE SCHEMA fwk AUTHORIZATION dbo;');
DROP TABLE IF EXISTS lab.BlockingEvidence;
DROP TABLE IF EXISTS lab.BlockingDemo;
DROP TABLE IF EXISTS fwk.SessionSignal;
CREATE TABLE lab.BlockingDemo(BlockId int NOT NULL CONSTRAINT PK_BlockingDemo PRIMARY KEY,Value int NOT NULL);
INSERT lab.BlockingDemo(BlockId,Value) VALUES(1,0),(2,0);
CREATE TABLE lab.BlockingEvidence
(
 EvidenceId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_BlockingEvidence PRIMARY KEY,
 HeadSessionId smallint NOT NULL,MiddleSessionId smallint NOT NULL,LeafSessionId smallint NOT NULL,
 MiddleBlockingSessionId smallint NOT NULL,LeafBlockingSessionId smallint NOT NULL,
 MiddleWaitType nvarchar(60) NOT NULL,LeafWaitType nvarchar(60) NOT NULL,
 MiddleWaitMs int NOT NULL,LeafWaitMs int NOT NULL,ChainDepth int NOT NULL,CapturedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_BlockingEvidence_Captured DEFAULT SYSUTCDATETIME()
);
CREATE TABLE fwk.SessionSignal
(
 DemoId varchar(7) NOT NULL,RunToken varchar(20) NOT NULL,SignalName varchar(64) NOT NULL,
 SignaledAtUtc datetime2(3) NOT NULL CONSTRAINT DF_SessionSignal_Captured DEFAULT SYSUTCDATETIME(),
 SignaledBySessionId smallint NOT NULL,
 CONSTRAINT PK_SessionSignal PRIMARY KEY(DemoId,RunToken,SignalName)
);
GO
CREATE OR ALTER PROCEDURE fwk.USP_Signal @DemoId varchar(7),@RunToken varchar(20),@SignalName varchar(64)
AS
BEGIN
 SET NOCOUNT ON;SET XACT_ABORT ON;
 IF @SignalName IS NULL OR @SignalName COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Z0-9_]%' THROW 51000,'FAIL_CONTRACT: Ungültiger Signalname.',1;
 UPDATE fwk.SessionSignal SET SignaledAtUtc=SYSUTCDATETIME(),SignaledBySessionId=@@SPID WHERE DemoId=@DemoId AND RunToken=@RunToken AND SignalName=@SignalName;
 IF @@ROWCOUNT=0 BEGIN TRY INSERT fwk.SessionSignal(DemoId,RunToken,SignalName,SignaledBySessionId) VALUES(@DemoId,@RunToken,@SignalName,@@SPID); END TRY BEGIN CATCH IF ERROR_NUMBER() NOT IN(2601,2627) THROW;UPDATE fwk.SessionSignal SET SignaledAtUtc=SYSUTCDATETIME(),SignaledBySessionId=@@SPID WHERE DemoId=@DemoId AND RunToken=@RunToken AND SignalName=@SignalName;END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE fwk.USP_WaitForSignal @DemoId varchar(7),@RunToken varchar(20),@SignalName varchar(64),@TimeoutMs int
AS
BEGIN
 SET NOCOUNT ON;SET XACT_ABORT ON;
 DECLARE @Start datetime2(3)=SYSUTCDATETIME();
 IF @TimeoutMs NOT BETWEEN 1 AND 30000 THROW 51000,'FAIL_CONTRACT: Signal-Timeout ist ungültig.',1;
 WHILE NOT EXISTS(SELECT 1 FROM fwk.SessionSignal WHERE DemoId=@DemoId AND RunToken=@RunToken AND SignalName=@SignalName)
 BEGIN
  IF DATEDIFF_BIG(millisecond,@Start,SYSUTCDATETIME())>=@TimeoutMs THROW 51005,'FAIL_TIMEOUT: Erwartetes CON-004-Signal fehlt.',1;
  WAITFOR DELAY '00:00:00.100';
 END;
END;
GO
CREATE OR ALTER PROCEDURE fwk.USP_ClearSignals @DemoId varchar(7),@RunToken varchar(20)
AS
BEGIN SET NOCOUNT ON;DELETE fwk.SessionSignal WHERE DemoId=@DemoId AND RunToken=@RunToken;END;
GO
TRUNCATE TABLE lab.BlockingEvidence;
EXEC fwk.USP_ClearSignals @DemoId='$(DemoId)',@RunToken='$(RunToken)';
SELECT 1 Sequence,'SETUP' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'2 Zeilen; Signalsteuerung; Evidenztabelle' ObservedValue,N'isolierte CON-004-Testdatenbank' RequiredValue,N'CON-004 wurde aufgebaut.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
GO
