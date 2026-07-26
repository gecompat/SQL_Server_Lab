/* Observer captures the live two-edge blocking hierarchy before releasing it. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @Head smallint,@Middle smallint,@Leaf smallint;
DECLARE @MiddleBlocker smallint,@LeafBlocker smallint;
DECLARE @MiddleWait nvarchar(60),@LeafWait nvarchar(60);
DECLARE @MiddleWaitMs int,@LeafWaitMs int;
DECLARE @Started datetime2(3)=SYSUTCDATETIME();

EXEC fwk.USP_WaitForSignal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='HEAD_START',@TimeoutMs=10000;
EXEC fwk.USP_WaitForSignal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='MIDDLE_START',@TimeoutMs=10000;
EXEC fwk.USP_WaitForSignal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='LEAF_START',@TimeoutMs=10000;

SELECT @Head=MAX(CASE WHEN SignalName='HEAD_START' THEN SignaledBySessionId END),
       @Middle=MAX(CASE WHEN SignalName='MIDDLE_START' THEN SignaledBySessionId END),
       @Leaf=MAX(CASE WHEN SignalName='LEAF_START' THEN SignaledBySessionId END)
FROM fwk.SessionSignal
WHERE DemoId='$(DemoId)' AND RunToken='$(RunToken)';

WHILE 1=1
BEGIN
    SELECT @MiddleBlocker=blocking_session_id,@MiddleWait=wait_type,@MiddleWaitMs=wait_time
    FROM sys.dm_exec_requests WHERE session_id=@Middle;
    SELECT @LeafBlocker=blocking_session_id,@LeafWait=wait_type,@LeafWaitMs=wait_time
    FROM sys.dm_exec_requests WHERE session_id=@Leaf;

    IF @MiddleBlocker=@Head AND @LeafBlocker=@Middle
       AND @MiddleWait LIKE N'LCK_M[_]%' AND @LeafWait LIKE N'LCK_M[_]%'
       AND @MiddleWaitMs>0 AND @LeafWaitMs>0
        BREAK;

    IF DATEDIFF_BIG(millisecond,@Started,SYSUTCDATETIME())>=12000
        THROW 51005,'FAIL_TIMEOUT: Die erwartete zweistufige Blocking Chain wurde nicht sichtbar.',1;
    WAITFOR DELAY '00:00:00.050';
END;

INSERT lab.BlockingEvidence
(
 HeadSessionId,MiddleSessionId,LeafSessionId,MiddleBlockingSessionId,LeafBlockingSessionId,
 MiddleWaitType,LeafWaitType,MiddleWaitMs,LeafWaitMs,ChainDepth
)
VALUES(@Head,@Middle,@Leaf,@MiddleBlocker,@LeafBlocker,@MiddleWait,@LeafWait,@MiddleWaitMs,@LeafWaitMs,2);

EXEC fwk.USP_Signal @DemoId='$(DemoId)',@RunToken='$(RunToken)',@SignalName='OBSERVED';
SELECT @Head HeadSessionId,@Middle MiddleSessionId,@Leaf LeafSessionId,@MiddleBlocker MiddleBlockedBy,@LeafBlocker LeafBlockedBy,@MiddleWait MiddleWaitType,@LeafWait LeafWaitType,@MiddleWaitMs MiddleWaitMs,@LeafWaitMs LeafWaitMs;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
