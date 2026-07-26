/* QRY-001 comparison: repeat the SARGable predicate under the same data state. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Start datetime2(0)='20240315';
DECLARE @End datetime2(0)=DATEADD(day,1,@Start);
DECLARE @Result bigint;
DECLARE @LogicalReads bigint;
DECLARE @Plan nvarchar(max);
DECLARE @AccessMethod varchar(32);
DECLARE @ProblemResult bigint;
DECLARE @ProblemReads bigint;

SELECT @ProblemResult=ResultValue,@ProblemReads=LogicalReads
FROM lab.Qry001Evidence WHERE Phase='PROBLEM';

SELECT @Result=SUM(CONVERT(bigint,MeasureValue))
FROM lab.SearchData /*SQLPERF_QRY001_COMPARISON*/
WHERE EventDateTime>=@Start AND EventDateTime<@End;

SELECT TOP(1)
    @LogicalReads=qs.last_logical_reads,
    @Plan=qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle,qs.statement_start_offset,qs.statement_end_offset) qp
WHERE SUBSTRING(st.text,(qs.statement_start_offset/2)+1,
      CASE WHEN qs.statement_end_offset=-1
           THEN (DATALENGTH(st.text)-qs.statement_start_offset)/2+1
           ELSE (qs.statement_end_offset-qs.statement_start_offset)/2+1 END)
      LIKE '%SQLPERF_QRY001_COMPARISON%'
ORDER BY qs.last_execution_time DESC;

SET @AccessMethod=CASE
    WHEN @Plan LIKE '%PhysicalOp="Index Seek"%' THEN 'INDEX_SEEK'
    WHEN @Plan LIKE '%PhysicalOp="Index Scan"%' THEN 'INDEX_SCAN'
    ELSE 'OTHER' END;

DELETE lab.Qry001Evidence WHERE Phase='COMPARISON';
INSERT lab.Qry001Evidence(Phase,ResultValue,LogicalReads,AccessMethod)
VALUES('COMPARISON',COALESCE(@Result,0),COALESCE(@LogicalReads,-1),@AccessMethod);

IF @ProblemResult IS NULL OR @Result<>@ProblemResult
    THROW 51006, 'FAIL_RESULT_CONTRACT: Die Vergleichsabfrage ist nicht fachlich äquivalent.', 1;
IF @LogicalReads IS NULL OR @AccessMethod<>'INDEX_SEEK' OR @LogicalReads>=@ProblemReads
    THROW 51006, 'FAIL_RESULT_CONTRACT: Die SARGable Vergleichsabfrage erfüllt die relationale statementbezogene Plan-/Read-Erwartung nicht.', 1;

SELECT Phase,ResultValue,LogicalReads,AccessMethod
FROM lab.Qry001Evidence
ORDER BY CASE Phase WHEN 'BASELINE' THEN 1 WHEN 'PROBLEM' THEN 2 ELSE 3 END;

SELECT 1 AS Sequence,'COMPARISON' AS Phase,'SUMMARY' AS CheckId,
       'PASS' AS Outcome,'OK' AS Code,
       CONCAT(N'Result=',@Result,N'; LogicalReads=',@LogicalReads,N'; Access=',@AccessMethod) AS ObservedValue,
       N'gleiches Ergebnis; Seek; weniger statementbezogene Reads als Problemzustand' AS RequiredValue,
       N'Die Gegenmaßnahme ist unter vergleichbaren Bedingungen bestätigt.' AS Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
