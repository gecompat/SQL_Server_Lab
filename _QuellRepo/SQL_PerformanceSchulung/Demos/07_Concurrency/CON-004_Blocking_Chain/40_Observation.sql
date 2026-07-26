/* CON-004 observation after all problem sessions completed. */
SET NOCOUNT ON;SET XACT_ABORT ON;
DECLARE @Head smallint,@Middle smallint,@Leaf smallint,@MiddleBlocker smallint,@LeafBlocker smallint,@MiddleWait nvarchar(60),@LeafWait nvarchar(60),@MiddleMs int,@LeafMs int,@Depth int;
SELECT TOP(1) @Head=HeadSessionId,@Middle=MiddleSessionId,@Leaf=LeafSessionId,@MiddleBlocker=MiddleBlockingSessionId,@LeafBlocker=LeafBlockingSessionId,@MiddleWait=MiddleWaitType,@LeafWait=LeafWaitType,@MiddleMs=MiddleWaitMs,@LeafMs=LeafWaitMs,@Depth=ChainDepth FROM lab.BlockingEvidence ORDER BY EvidenceId DESC;
IF @Head IS NULL THROW 51002,'FAIL_STATE: CON-004-Blocking-Evidenz fehlt.',1;
IF @MiddleBlocker<>@Head OR @LeafBlocker<>@Middle OR @Depth<>2 THROW 51006,'FAIL_RESULT_CONTRACT: Die gespeicherte Blockerhierarchie ist nicht Head-Middle-Leaf.',1;
IF @MiddleWait NOT LIKE N'LCK_M[_]%' OR @LeafWait NOT LIKE N'LCK_M[_]%' OR @MiddleMs<=0 OR @LeafMs<=0 THROW 51006,'FAIL_RESULT_CONTRACT: Lock-Wait-Evidenz ist unvollständig.',1;
IF (SELECT Value FROM lab.BlockingDemo WHERE BlockId=1)<>11 OR (SELECT Value FROM lab.BlockingDemo WHERE BlockId=2)<>110 THROW 51006,'FAIL_RESULT_CONTRACT: Die Transaktionen wurden nicht vollständig in erwarteter Reihenfolge abgeschlossen.',1;
IF EXISTS(SELECT 1 FROM sys.dm_exec_requests WHERE database_id=DB_ID() AND blocking_session_id<>0) THROW 51002,'FAIL_STATE: Nach dem Problemszenario verbleibt ein blockierter Request.',1;
SELECT * FROM lab.BlockingEvidence ORDER BY EvidenceId;
SELECT * FROM lab.BlockingDemo ORDER BY BlockId;
SELECT 1 Sequence,'OBSERVATION' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,CONCAT(N'Head=',@Head,N'; Middle=',@Middle,N'; Leaf=',@Leaf,N'; WaitMs=',@MiddleMs,N'/',@LeafMs) ObservedValue,N'Chain Depth 2; zwei positive LCK_M-Waits; Endwerte 11/110' RequiredValue,N'Head Blocker und unmittelbare Blockerbeziehungen sind bestätigt.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
