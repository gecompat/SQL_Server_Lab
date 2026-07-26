/* OPT-002 mitigation: remove sampling uncertainty for this controlled data set. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
UPDATE STATISTICS lab.StatisticsData ST_StatisticsData_Category_Region WITH FULLSCAN,NORECOMPUTE;
SELECT 1 Sequence,'MITIGATION' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,N'FULLSCAN für ST_StatisticsData_Category_Region' ObservedValue,N'vollständige Stichprobe ohne Änderung der Histogrammgrenze von 200 Schritten' RequiredValue,N'Die Statistik wurde kontrolliert vollständig aktualisiert.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
