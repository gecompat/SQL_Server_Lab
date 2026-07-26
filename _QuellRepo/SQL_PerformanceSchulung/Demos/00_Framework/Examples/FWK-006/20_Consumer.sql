/* Synthetic FWK-006 consumer session. Requires FWK_MultiSessionControl.sql INSTALL. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

EXEC fwk.USP_WaitForSignal
    @DemoId = '$(DemoId)',
    @RunToken = '$(RunToken)',
    @SignalName = 'PRODUCER_READY',
    @TimeoutMs = 10000;

EXEC fwk.USP_Signal
    @DemoId = '$(DemoId)',
    @RunToken = '$(RunToken)',
    @SignalName = 'CONSUMER_DONE';

PRINT 'SQLPERF_SUMMARY|PASS|OK';
