/* CON-004 baseline: no blocking and deterministic initial values. */
SET NOCOUNT ON;SET XACT_ABORT ON;
EXEC fwk.USP_ClearSignals @DemoId='$(DemoId)',@RunToken='$(RunToken)';
TRUNCATE TABLE lab.BlockingEvidence;
UPDATE lab.BlockingDemo SET Value=0;
IF EXISTS(SELECT 1 FROM sys.dm_exec_requests WHERE database_id=DB_ID() AND blocking_session_id<>0)
    THROW 51002,'FAIL_STATE: Vor dem CON-004-Lauf existiert bereits Blocking in der Testdatenbank.',1;
IF EXISTS(SELECT 1 FROM lab.BlockingDemo WHERE Value<>0) OR (SELECT COUNT(*) FROM lab.BlockingDemo)<>2
    THROW 51006,'FAIL_RESULT_CONTRACT: CON-004-Ausgangsdaten sind inkonsistent.',1;
SELECT * FROM lab.BlockingDemo ORDER BY BlockId;
SELECT 1 Sequence,'BASELINE' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'keine blockierten Requests; Werte 0/0' ObservedValue,N'blockierungsfreier Ausgangszustand' RequiredValue,N'Die CON-004-Baseline ist bestätigt.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
