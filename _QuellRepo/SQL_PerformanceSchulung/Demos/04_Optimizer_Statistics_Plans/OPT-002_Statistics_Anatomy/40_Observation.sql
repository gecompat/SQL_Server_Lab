/* OPT-002 observation: interpret the sampled statistics without overstating precision. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @Total bigint,@Sampled bigint,@Steps int,@FirstColumn sysname,@HotEqualRows float;
SELECT @Total=TotalRows,@Sampled=RowsSampled,@Steps=HistogramSteps,@FirstColumn=FirstStatsColumn,@HotEqualRows=HotEqualRows FROM lab.Opt002Evidence WHERE Phase='SAMPLE';
IF @Total IS NULL THROW 51002,'FAIL_STATE: OPT-002-Sample-Evidenz fehlt.',1;
IF @Sampled>=@Total OR @Sampled<=0 THROW 51006,'FAIL_RESULT_CONTRACT: Die Ausgangsstatistik ist nicht als echte Stichprobe erkennbar.',1;
IF @Steps NOT BETWEEN 1 AND 200 THROW 51006,'FAIL_RESULT_CONTRACT: Die Histogrammschrittzahl liegt außerhalb des dokumentierten Bereichs.',1;
IF @FirstColumn<>N'CategoryId' THROW 51006,'FAIL_RESULT_CONTRACT: Das Histogramm bezieht sich nicht auf die erste Statistikschlüsselspalte CategoryId.',1;
IF @HotEqualRows IS NULL OR @HotEqualRows<=0 THROW 51006,'FAIL_RESULT_CONTRACT: Die häufige Kategorie ist im Sample-Histogramm nicht beobachtbar.',1;
SELECT Phase,TotalRows,HotRows,RowsSampled,HistogramSteps,HotEqualRows,FirstStatsColumn FROM lab.Opt002Evidence ORDER BY Phase;
SELECT 1 Sequence,'OBSERVATION' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,CONCAT(N'SamplePercent=',CONVERT(decimal(9,2),@Sampled*100.0/@Total),N'; Steps=',@Steps,N'; FirstColumn=',@FirstColumn) ObservedValue,N'rows_sampled < rows; 1..200 Schritte; Histogramm auf CategoryId' RequiredValue,N'Die Statistikbestandteile sind fachlich getrennt interpretiert.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
