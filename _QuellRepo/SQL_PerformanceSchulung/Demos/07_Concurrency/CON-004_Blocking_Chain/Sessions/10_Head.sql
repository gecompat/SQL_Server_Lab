/* CON-004 head blocker. The start signal is committed before the user transaction. */
SET NOCOUNT ON;SET XACT_ABORT ON;
EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='HEAD_START';
BEGIN TRY
 BEGIN TRANSACTION;
 UPDATE lab.BlockingDemo SET Value=Value+1 WHERE BlockId=1;
 EXEC fwk.USP_WaitForSignal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='OBSERVED',@TimeoutMs=15000;
 COMMIT TRANSACTION;
 EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='HEAD_COMMITTED';
 PRINT 'SQLPERF_SUMMARY|PASS|OK';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
