/* OPT-013 baseline: sort the visible base table with a cardinality-aware plan. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Checksum int;
DECLARE @LastSpills bigint;
DECLARE @LastGrantKb bigint;
DECLARE @LastUsedGrantKb bigint;
DECLARE @Plan nvarchar(max);
DECLARE @PlanHasSort bit;
DECLARE @Tag varchar(64)=CONCAT('SQLPERF_OPT013_','BASELINE');
DECLARE @ActualRows bigint=(SELECT COUNT_BIG(*) FROM lab.SpillData);

SELECT @Checksum=CHECKSUM_AGG(BINARY_CHECKSUM(d.SortKey,d.RowNumber))
FROM
(
    SELECT SortKey,
           RowNumber=ROW_NUMBER() OVER(ORDER BY Payload,SortKey)
    FROM lab.SpillData /*SQLPERF_OPT013_BASELINE*/
) d
OPTION(MAXDOP 1);

SELECT TOP(1)
    @LastSpills=qs.last_spills,
    @LastGrantKb=qs.last_grant_kb,
    @LastUsedGrantKb=qs.last_used_grant_kb,
    @Plan=qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle,qs.statement_start_offset,qs.statement_end_offset) qp
CROSS APPLY
(
    VALUES
    (
        SUBSTRING(st.text,(qs.statement_start_offset/2)+1,
        CASE WHEN qs.statement_end_offset=-1
             THEN (DATALENGTH(st.text)-qs.statement_start_offset)/2+1
             ELSE (qs.statement_end_offset-qs.statement_start_offset)/2+1 END)
    )
) statement_text(value)
WHERE statement_text.value LIKE '%'+@Tag+'%'
ORDER BY qs.last_execution_time DESC;

SET @PlanHasSort=CASE WHEN @Plan LIKE '%PhysicalOp="Sort"%' THEN 1 ELSE 0 END;
DELETE lab.SpillEvidence WHERE Phase='BASELINE';
INSERT lab.SpillEvidence
(
    Phase,ResultChecksum,LastSpills,PlanHasSort,LastGrantKb,LastUsedGrantKb,ActualRows,InputKind
)
VALUES
(
    'BASELINE',@Checksum,COALESCE(@LastSpills,-1),@PlanHasSort,
    COALESCE(@LastGrantKb,-1),COALESCE(@LastUsedGrantKb,-1),@ActualRows,'BASE_TABLE'
);

IF @Checksum IS NULL OR @ActualRows<>300000 OR @LastSpills IS NULL OR @LastSpills<>0
   OR @LastGrantKb IS NULL OR @LastUsedGrantKb IS NULL OR @PlanHasSort<>1
    THROW 51006,'FAIL_RESULT_CONTRACT: Die OPT-013-Baseline zeigt nicht den erwarteten nicht verschütteten Sort der Basistabelle.',1;

SELECT 1 Sequence,'BASELINE' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,
       CONCAT(N'Rows=',@ActualRows,N'; GrantKb=',@LastGrantKb,
              N'; UsedGrantKb=',@LastUsedGrantKb,N'; LastSpills=',@LastSpills) ObservedValue,
       N'300000 sichtbare Zeilen; Sortoperator; last_spills=0' RequiredValue,
       N'Die cardinality-aware Baseline ist erfasst.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
