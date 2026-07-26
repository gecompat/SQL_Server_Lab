/* QRY-001 observation: compare result equivalence, access method and reads. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @BaselineResult bigint;
DECLARE @ProblemResult bigint;
DECLARE @BaselineReads bigint;
DECLARE @ProblemReads bigint;
DECLARE @BaselineAccess varchar(32);
DECLARE @ProblemAccess varchar(32);

SELECT @BaselineResult=ResultValue,@BaselineReads=LogicalReads,@BaselineAccess=AccessMethod
FROM lab.Qry001Evidence WHERE Phase='BASELINE';
SELECT @ProblemResult=ResultValue,@ProblemReads=LogicalReads,@ProblemAccess=AccessMethod
FROM lab.Qry001Evidence WHERE Phase='PROBLEM';

IF @BaselineResult IS NULL OR @ProblemResult IS NULL
    THROW 51002, 'FAIL_STATE: QRY-001-Baseline oder Problem-Evidenz fehlt.', 1;
IF @BaselineResult<>@ProblemResult
    THROW 51006, 'FAIL_RESULT_CONTRACT: Die verglichenen Prädikate liefern unterschiedliche Ergebnisse.', 1;
IF @BaselineAccess<>'INDEX_SEEK' OR @ProblemAccess<>'INDEX_SCAN'
    THROW 51006, 'FAIL_RESULT_CONTRACT: Die erwartete Seek-/Scan-Planform ist nicht belegt.', 1;
IF @ProblemReads<=@BaselineReads
    THROW 51006, 'FAIL_RESULT_CONTRACT: Der Scan liest in dieser kontrollierten Demo nicht mehr Seiten als der Seek.', 1;

SELECT Phase,ResultValue,LogicalReads,AccessMethod,CapturedAtUtc
FROM lab.Qry001Evidence
ORDER BY CASE Phase WHEN 'BASELINE' THEN 1 ELSE 2 END;

SELECT 1 AS Sequence,'OBSERVATION' AS Phase,'SUMMARY' AS CheckId,
       'PASS' AS Outcome,'OK' AS Code,
       CONCAT(N'Resultgleichheit=1; ReadRatio=',CONVERT(decimal(19,2),@ProblemReads*1.0/NULLIF(@BaselineReads,0))) AS ObservedValue,
       N'gleiche Ergebnismenge; ProblemReads > BaselineReads; Seek gegenüber Scan' AS RequiredValue,
       N'Ursache, Planform und Messwert stimmen im kontrollierten Modell überein.' AS Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
