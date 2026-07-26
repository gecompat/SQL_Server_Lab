/* CON-004 comparison verification after short committed transactions. */
SET NOCOUNT ON;SET XACT_ABORT ON;
IF (SELECT Value FROM lab.BlockingDemo WHERE BlockId=1)<>11 OR (SELECT Value FROM lab.BlockingDemo WHERE BlockId=2)<>110
    THROW 51006,'FAIL_RESULT_CONTRACT: Der Vergleich liefert nicht dieselben fachlichen Endwerte.',1;
IF EXISTS(SELECT 1 FROM sys.dm_exec_requests WHERE database_id=DB_ID() AND blocking_session_id<>0)
    THROW 51006,'FAIL_RESULT_CONTRACT: Im Vergleich verbleibt eine Blocking-Beziehung.',1;
IF EXISTS(SELECT 1 FROM lab.BlockingEvidence)
    THROW 51006,'FAIL_RESULT_CONTRACT: Der Vergleich hat unerwartet Problem-Evidenz erzeugt.',1;
SELECT * FROM lab.BlockingDemo ORDER BY BlockId;
SELECT 1 Sequence,'COMPARISON' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'Endwerte 11/110; keine blockierten Requests' ObservedValue,N'fachlich gleiches Ergebnis ohne absichtliche Blocking Chain' RequiredValue,N'Kurze Transaktionen und Commit vor Übergabe vermeiden den demonstrierten Problemzustand.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
