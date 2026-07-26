/* Synthetic FWK-006 producer session. Requires FWK_MultiSessionControl.sql INSTALL. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

EXEC fwk.USP_Signal
    @DemoId = '$(DemoId)',
    @RunToken = '$(RunToken)',
    @SignalName = 'PRODUCER_READY';

EXEC fwk.USP_WaitForSignal
    @DemoId = '$(DemoId)',
    @RunToken = '$(RunToken)',
    @SignalName = 'CONSUMER_DONE',
    @TimeoutMs = 10000;

PRINT 'SQLPERF_SUMMARY|PASS|OK';
