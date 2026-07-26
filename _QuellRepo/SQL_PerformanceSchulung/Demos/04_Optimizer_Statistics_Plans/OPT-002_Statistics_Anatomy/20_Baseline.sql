/* OPT-002 baseline: actual data distribution independent of statistics. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @Total bigint=(SELECT COUNT_BIG(*) FROM lab.StatisticsData);
DECLARE @Hot bigint=(SELECT COUNT_BIG(*) FROM lab.StatisticsData WHERE CategoryId=1);
IF @Total<>100000 OR @Hot<>50000 THROW 51006,'FAIL_RESULT_CONTRACT: Die tatsächliche OPT-002-Verteilung ist nicht deterministisch.',1;
DELETE lab.Opt002Evidence WHERE Phase='BASELINE';
INSERT lab.Opt002Evidence(Phase,TotalRows,HotRows) VALUES('BASELINE',@Total,@Hot);
SELECT CategoryId,ActualRows=COUNT_BIG(*) FROM lab.StatisticsData GROUP BY CategoryId ORDER BY CategoryId;
SELECT 1 Sequence,'BASELINE' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,CONCAT(N'Total=',@Total,N'; HotRows=',@Hot) ObservedValue,N'100000 Gesamtzeilen; 50000 Zeilen für Kategorie 1' RequiredValue,N'Die tatsächliche Verteilung ist erfasst.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
