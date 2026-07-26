/* OPT-013 observation: correlate identical results, input visibility, grants and spill counters. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @BaselineChecksum int,@ProblemChecksum int;
DECLARE @BaselineSpills bigint,@ProblemSpills bigint;
DECLARE @BaselineSort bit,@ProblemSort bit;
DECLARE @BaselineGrant bigint,@ProblemGrant bigint;
DECLARE @BaselineUsedGrant bigint,@ProblemUsedGrant bigint;
DECLARE @BaselineRows bigint,@ProblemRows bigint;
DECLARE @BaselineInput varchar(32),@ProblemInput varchar(32);

SELECT
    @BaselineChecksum=ResultChecksum,
    @BaselineSpills=LastSpills,
    @BaselineSort=PlanHasSort,
    @BaselineGrant=LastGrantKb,
    @BaselineUsedGrant=LastUsedGrantKb,
    @BaselineRows=ActualRows,
    @BaselineInput=InputKind
FROM lab.SpillEvidence
WHERE Phase='BASELINE';

SELECT
    @ProblemChecksum=ResultChecksum,
    @ProblemSpills=LastSpills,
    @ProblemSort=PlanHasSort,
    @ProblemGrant=LastGrantKb,
    @ProblemUsedGrant=LastUsedGrantKb,
    @ProblemRows=ActualRows,
    @ProblemInput=InputKind
FROM lab.SpillEvidence
WHERE Phase='PROBLEM';

IF @BaselineChecksum IS NULL OR @ProblemChecksum IS NULL
    THROW 51002,'FAIL_STATE: OPT-013-Baseline oder Problem-Evidenz fehlt.',1;
IF @BaselineChecksum<>@ProblemChecksum OR @BaselineRows<>300000 OR @ProblemRows<>300000
    THROW 51006,'FAIL_RESULT_CONTRACT: Baseline und Problemzustand liefern nicht dieselben 300000 Zeilen.',1;
IF @BaselineInput<>'BASE_TABLE' OR @BaselineSpills<>0 OR @BaselineSort<>1 OR @BaselineGrant<=0
    THROW 51006,'FAIL_RESULT_CONTRACT: Die Baseline besitzt nicht den erwarteten cardinality-aware Sort ohne Spill.',1;
IF @ProblemInput<>'TABLE_VARIABLE_FIXED_ESTIMATE' OR @ProblemSpills<=0 OR @ProblemSort<>1 OR @ProblemGrant<=0
    THROW 51006,'FAIL_RESULT_CONTRACT: Der Problemzustand belegt keinen Table-Variable-Sort mit Spill.',1;
IF @ProblemGrant>=@BaselineGrant
    THROW 51006,'FAIL_RESULT_CONTRACT: Der Problemzustand besitzt keinen kleineren Grant als die Baseline.',1;

SELECT
    Phase,ResultChecksum,LastSpills,PlanHasSort,LastGrantKb,LastUsedGrantKb,
    ActualRows,InputKind,CapturedAtUtc
FROM lab.SpillEvidence
ORDER BY CASE Phase WHEN 'BASELINE' THEN 1 ELSE 2 END;

SELECT 1 Sequence,'OBSERVATION' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,
       CONCAT(N'Rows=',@ProblemRows,N'; BaselineGrantKb=',@BaselineGrant,
              N'; ProblemGrantKb=',@ProblemGrant,N'; ProblemSpills=',@ProblemSpills) ObservedValue,
       N'gleiche 300000 Zeilen; Sort in beiden Plänen; kleinerer Grant und positiver Spill nur bei Table Variable' RequiredValue,
       N'Der kontrollierte Spill ist gemeinsam mit der eingeschränkten Kardinalitätssicht belegt.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
