/* Comparison follower starts only after the first transaction committed. */
SET NOCOUNT ON;SET XACT_ABORT ON;
EXEC fwk.USP_WaitForSignal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='FIRST_COMMITTED',@TimeoutMs=10000;
BEGIN TRY
 BEGIN TRANSACTION;
 UPDATE lab.BlockingDemo SET Value=Value+10 WHERE BlockId=1;
 UPDATE lab.BlockingDemo SET Value=Value+100 WHERE BlockId=2;
 COMMIT TRANSACTION;
 PRINT 'SQLPERF_SUMMARY|PASS|OK';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
