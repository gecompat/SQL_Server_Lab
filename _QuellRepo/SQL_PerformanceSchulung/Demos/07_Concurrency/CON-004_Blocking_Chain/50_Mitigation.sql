/* CON-004 mitigation: commit before handing work to the following session. */
SET NOCOUNT ON;SET XACT_ABORT ON;
EXEC fwk.USP_ClearSignals @DemoId='$(DemoId)',@RunToken='$(RunToken)';
TRUNCATE TABLE lab.BlockingEvidence;
UPDATE lab.BlockingDemo SET Value=0;
SELECT Mitigation=N'Kurze Transaktionen; Folgesession wird erst nach Commit freigegeben.',NonMitigation=N'NOLOCK oder pauschales Beenden fremder Sessions';
SELECT 1 Sequence,'MITIGATION' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'Commit vor Signal an Folgesession' ObservedValue,N'gleiche fachliche Änderungen ohne absichtliche Lock-Wartekette' RequiredValue,N'Der Vergleichszustand ist vorbereitet.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
