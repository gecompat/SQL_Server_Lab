/* QRY-001 demonstration: function on indexed predicate column. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Result bigint;
DECLARE @LogicalReads bigint;
DECLARE @Plan nvarchar(max);
DECLARE @AccessMethod varchar(32);

SELECT @Result=SUM(CONVERT(bigint,MeasureValue))
FROM lab.SearchData /*SQLPERF_QRY001_NONSARGABLE*/
WHERE CONVERT(char(10),EventDateTime,120)='2024-03-15';

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
      LIKE '%SQLPERF_QRY001_NONSARGABLE%'
ORDER BY qs.last_execution_time DESC;

SET @AccessMethod=CASE
    WHEN @Plan LIKE '%PhysicalOp="Index Seek"%' THEN 'INDEX_SEEK'
    WHEN @Plan LIKE '%PhysicalOp="Index Scan"%' THEN 'INDEX_SCAN'
    ELSE 'OTHER' END;

DELETE lab.Qry001Evidence WHERE Phase='PROBLEM';
INSERT lab.Qry001Evidence(Phase,ResultValue,LogicalReads,AccessMethod)
VALUES('PROBLEM',COALESCE(@Result,0),COALESCE(@LogicalReads,-1),@AccessMethod);

IF @Result IS NULL OR @LogicalReads IS NULL OR @LogicalReads<0 OR @AccessMethod<>'INDEX_SCAN'
    THROW 51003, 'FAIL_EXECUTION: Der kontrollierte QRY-001-Problemzustand zeigt keine belastbare statementbezogene Scan-/Read-Evidenz.', 1;

SELECT 1 AS Sequence,'DEMONSTRATION' AS Phase,'SUMMARY' AS CheckId,
       'PASS' AS Outcome,'OK' AS Code,
       CONCAT(N'Result=',@Result,N'; LogicalReads=',@LogicalReads,N'; Access=',@AccessMethod) AS ObservedValue,
       N'fachlich gleiche Ergebnismenge mit statementbezogener Scan-Evidenz' AS RequiredValue,
       N'Die Funktion auf der Indexspalte erzeugt den kontrollierten Problemzustand.' AS Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
