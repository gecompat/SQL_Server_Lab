/* OPT-002 comparison: validate full-scan header and deterministic hot-key frequency. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @ObjectId int=OBJECT_ID(N'lab.StatisticsData');
DECLARE @StatsId int=(SELECT stats_id FROM sys.stats WHERE object_id=@ObjectId AND name=N'ST_StatisticsData_Category_Region');
DECLARE @Rows bigint,@RowsSampled bigint,@Steps int,@HotEqualRows float,@FirstColumn sysname,@ActualHot bigint;
SELECT @Rows=rows,@RowsSampled=rows_sampled,@Steps=steps FROM sys.dm_db_stats_properties(@ObjectId,@StatsId);
SELECT @HotEqualRows=equal_rows FROM sys.dm_db_stats_histogram(@ObjectId,@StatsId) WHERE TRY_CONVERT(int,range_high_key)=1;
SELECT @FirstColumn=c.name FROM sys.stats_columns sc INNER JOIN sys.columns c ON c.object_id=sc.object_id AND c.column_id=sc.column_id WHERE sc.object_id=@ObjectId AND sc.stats_id=@StatsId AND sc.stats_column_id=1;
SELECT @ActualHot=COUNT_BIG(*) FROM lab.StatisticsData WHERE CategoryId=1;
DELETE lab.Opt002Evidence WHERE Phase='FULLSCAN';
INSERT lab.Opt002Evidence(Phase,TotalRows,HotRows,RowsSampled,HistogramSteps,HotEqualRows,FirstStatsColumn)
VALUES('FULLSCAN',@Rows,@ActualHot,@RowsSampled,@Steps,@HotEqualRows,@FirstColumn);
IF @Rows<>100000 OR @RowsSampled<>@Rows THROW 51006,'FAIL_RESULT_CONTRACT: FULLSCAN-Header zeigt keinen vollständigen Stichprobenumfang.',1;
IF @Steps<>101 THROW 51006,'FAIL_RESULT_CONTRACT: Das deterministische 101-Werte-Histogramm besitzt nicht 101 Schritte.',1;
IF @HotEqualRows<>CONVERT(float,@ActualHot) OR @ActualHot<>50000 THROW 51006,'FAIL_RESULT_CONTRACT: Die Fullscan-Hot-Key-Frequenz stimmt nicht mit den tatsächlichen Zeilen überein.',1;
IF @FirstColumn<>N'CategoryId' THROW 51006,'FAIL_RESULT_CONTRACT: Die führende Statistikspalte hat sich unerwartet geändert.',1;
SELECT Phase,TotalRows,HotRows,RowsSampled,HistogramSteps,HotEqualRows,FirstStatsColumn FROM lab.Opt002Evidence ORDER BY CASE Phase WHEN 'BASELINE' THEN 1 WHEN 'SAMPLE' THEN 2 ELSE 3 END;
DBCC SHOW_STATISTICS (N'lab.StatisticsData',N'ST_StatisticsData_Category_Region') WITH STAT_HEADER,DENSITY_VECTOR,HISTOGRAM,NO_INFOMSGS;
SELECT 1 Sequence,'COMPARISON' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,CONCAT(N'RowsSampled=',@RowsSampled,N'; Steps=',@Steps,N'; HotEqualRows=',CONVERT(bigint,@HotEqualRows)) ObservedValue,N'100000 vollständig gelesene Zeilen; 101 Schritte; HotEqualRows=50000' RequiredValue,N'Die deterministischen Fullscan-Invarianten sind bestätigt.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
