/* Synthetic leaf session for the isolated CON-004 lab database. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @MiddleSession smallint;
DECLARE @Started datetime2(3)=SYSUTCDATETIME();

EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='LEAF_START';
EXEC fwk.USP_WaitForSignal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='MIDDLE_START',@TimeoutMs=10000;
SELECT @MiddleSession=SignaledBySessionId
FROM fwk.SessionSignal
WHERE DemoId='$(DemoId)' AND RunToken='$(RunToken)' AND SignalName='MIDDLE_START';

WHILE NOT EXISTS
(
    SELECT 1
    FROM sys.dm_tran_locks
    WHERE request_session_id=@MiddleSession
      AND resource_database_id=DB_ID()
      AND resource_type='KEY'
      AND request_status='GRANT'
      AND request_mode IN('X','U')
)
BEGIN
    IF DATEDIFF_BIG(millisecond,@Started,SYSUTCDATETIME())>=10000
        THROW 51005,'FAIL_TIMEOUT: Der mittlere Transaktionszustand wurde nicht sichtbar.',1;
    WAITFOR DELAY '00:00:00.050';
END;

UPDATE lab.BlockingDemo SET Value=Value+100 WHERE BlockId=2;
EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='LEAF_COMPLETED';
PRINT 'SQLPERF_SUMMARY|PASS|OK';
