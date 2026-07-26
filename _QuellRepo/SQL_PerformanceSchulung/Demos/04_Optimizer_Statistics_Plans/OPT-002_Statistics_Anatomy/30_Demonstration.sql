/* OPT-002 demonstration: sampled header, histogram and density vector. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @ObjectId int=OBJECT_ID(N'lab.StatisticsData');
DECLARE @StatsId int=(SELECT stats_id FROM sys.stats WHERE object_id=@ObjectId AND name=N'ST_StatisticsData_Category_Region');
DECLARE @Rows bigint,@RowsSampled bigint,@Steps int,@HotEqualRows float,@FirstColumn sysname;
IF @StatsId IS NULL THROW 51002,'FAIL_STATE: OPT-002-Statistikobjekt fehlt.',1;
SELECT @Rows=rows,@RowsSampled=rows_sampled,@Steps=steps FROM sys.dm_db_stats_properties(@ObjectId,@StatsId);
SELECT @HotEqualRows=equal_rows FROM sys.dm_db_stats_histogram(@ObjectId,@StatsId) WHERE TRY_CONVERT(int,range_high_key)=1;
SELECT @FirstColumn=c.name FROM sys.stats_columns sc INNER JOIN sys.columns c ON c.object_id=sc.object_id AND c.column_id=sc.column_id WHERE sc.object_id=@ObjectId AND sc.stats_id=@StatsId AND sc.stats_column_id=1;
DELETE lab.Opt002Evidence WHERE Phase='SAMPLE';
INSERT lab.Opt002Evidence(Phase,TotalRows,HotRows,RowsSampled,HistogramSteps,HotEqualRows,FirstStatsColumn)
SELECT 'SAMPLE',(SELECT TotalRows FROM lab.Opt002Evidence WHERE Phase='BASELINE'),(SELECT HotRows FROM lab.Opt002Evidence WHERE Phase='BASELINE'),@RowsSampled,@Steps,@HotEqualRows,@FirstColumn;
SELECT sp.rows,sp.rows_sampled,sp.steps,sp.modification_counter,h.step_number,h.range_high_key,h.equal_rows,h.range_rows,h.distinct_range_rows,h.average_range_rows
FROM sys.dm_db_stats_properties(@ObjectId,@StatsId) sp CROSS APPLY sys.dm_db_stats_histogram(@ObjectId,@StatsId) h ORDER BY h.step_number;
DBCC SHOW_STATISTICS (N'lab.StatisticsData',N'ST_StatisticsData_Category_Region') WITH STAT_HEADER,DENSITY_VECTOR,HISTOGRAM,NO_INFOMSGS;
SELECT 1 Sequence,'DEMONSTRATION' Phase,'SUMMARY' CheckId,'PASS' Outcome,'OK' Code,CONCAT(N'Rows=',@Rows,N'; Sampled=',@RowsSampled,N'; Steps=',@Steps,N'; FirstColumn=',@FirstColumn) ObservedValue,N'Sample-Header, Histogramm und Density Vector' RequiredValue,N'Die drei Statistikbestandteile wurden ausgegeben.' Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
