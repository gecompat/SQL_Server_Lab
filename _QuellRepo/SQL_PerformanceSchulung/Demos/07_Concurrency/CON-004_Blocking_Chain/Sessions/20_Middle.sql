/* Synthetic concurrency session for the isolated CON-004 lab database. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @FirstSession smallint;
DECLARE @Started datetime2(3)=SYSUTCDATETIME();

EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='MIDDLE_START';
EXEC fwk.USP_WaitForSignal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='HEAD_START',@TimeoutMs=10000;
SELECT @FirstSession=SignaledBySessionId
FROM fwk.SessionSignal
WHERE DemoId='$(DemoId)' AND RunToken='$(RunToken)' AND SignalName='HEAD_START';

WHILE NOT EXISTS
(
    SELECT 1
    FROM sys.dm_tran_locks
    WHERE request_session_id=@FirstSession
      AND resource_database_id=DB_ID()
      AND resource_type='KEY'
      AND request_status='GRANT'
      AND request_mode IN('X','U')
)
BEGIN
    IF DATEDIFF_BIG(millisecond,@Started,SYSUTCDATETIME())>=10000
        THROW 51005,'FAIL_TIMEOUT: Der erwartete Transaktionszustand wurde nicht sichtbar.',1;
    WAITFOR DELAY '00:00:00.050';
END;

BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE lab.BlockingDemo SET Value=Value+10 WHERE BlockId=2;
    UPDATE lab.BlockingDemo SET Value=Value+10 WHERE BlockId=1;
    COMMIT TRANSACTION;
    EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='MIDDLE_COMMITTED';
    PRINT 'SQLPERF_SUMMARY|PASS|OK';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
