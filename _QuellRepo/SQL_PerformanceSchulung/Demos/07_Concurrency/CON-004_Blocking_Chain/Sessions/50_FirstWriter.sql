/* Comparison writer: the hand-off signal is emitted only after commit. */
SET NOCOUNT ON;SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 UPDATE lab.BlockingDemo SET Value=Value+1 WHERE BlockId=1;
 UPDATE lab.BlockingDemo SET Value=Value+10 WHERE BlockId=2;
 COMMIT TRANSACTION;
 EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='FIRST_COMMITTED';
 PRINT 'SQLPERF_SUMMARY|PASS|OK';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
