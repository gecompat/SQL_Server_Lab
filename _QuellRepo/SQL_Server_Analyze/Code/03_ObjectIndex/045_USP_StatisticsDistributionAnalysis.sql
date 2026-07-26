USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_StatisticsDistributionAnalysis
Version      : 1.0.0
Stand        : 2026-07-17
Typ          : Stored Procedure
Zweck        : Analysiert begrenzt und opt-in die Verteilung sichtbarer
               Statistikhistogramme sowie die Änderungsvariation inkrementeller
               Statistikpartitionen.
SQL-Version  : SQL Server 2019 oder neuer.
Datenquellen : monitor.USP_Statistics, sys.stats_columns, sys.columns,
               sys.types und sys.dm_db_stats_histogram.
Methodik     : Die Kandidatenmenge wird je Datenbank vor dem Histogrammzugriff
               begrenzt. Bewertet werden ausschließlich numerische Verteilungs-
               kennzahlen; konkrete Histogrammgrenzwerte sind für diese
               Auswertung nicht erforderlich.
Grenzen      : Skew, Tail-Konzentration und Änderungen seit dem Statistikstand
               sind Prüfhinweise, kein Beweis für einen schlechten Plan oder
               Werte außerhalb des Histogramms. Query-/Prädikatkontext und
               tatsächliche Kardinalitätsabweichungen müssen separat korreliert
               werden. Es werden keine Statistiken aktualisiert und keine Daten
               aus Benutzertabellen gelesen.
Kosten       : HIGH_OPT_IN. CATALOG_DEEP-Freigabe, gezielter Scope oder bewusst
               gewählter VOLL-Modus sowie eine harte Kandidatengrenze.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_StatisticsDistributionAnalysis]
      @DatabaseNames                       nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen        bit            = 0
    , @DatabaseNamePattern                 nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                         nvarchar(max)  = NULL
    , @SchemaNamePattern                   nvarchar(4000) = NULL
    , @ObjectNames                         nvarchar(max)  = NULL
    , @ObjectNamePattern                   nvarchar(4000) = NULL
    , @FullObjectNames                     nvarchar(max)  = NULL
    , @StatisticsNames                     nvarchar(max)  = NULL
    , @StatisticsNamePattern               nvarchar(4000) = NULL
    , @AnalyseModus                        varchar(16)     = 'GEZIELT'
    , @MaxVerteilungsStatistiken           int             = 50
    , @MinVerteilungsZeilen                bigint          = 1000
    , @SkewWarnFaktor                      decimal(19,4)   = 10
    , @DominanterSchrittWarnPercent        decimal(9,4)    = 50
    , @ModificationWarnPercent             decimal(9,4)    = 20
    , @PartitionSpreadWarnPercent          decimal(9,4)    = 20
    , @MaxZeilen                           int             = 1000
    , @LockTimeoutMs                       int             = 0
    , @ResultSetArt                        varchar(16)     = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                        bit             = 0
    , @Json                                nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                      bit             = 1
    , @Hilfe                               bit             = 0
    , @StatusCodeOut                       varchar(40)     = NULL OUTPUT
    , @IsPartialOut                        bit             = NULL OUTPUT
    , @ErrorNumberOut                      int             = NULL OUTPUT
    , @ErrorMessageOut                     nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json = NULL;

    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @TableResultRequested bit = CASE WHEN @OutputMode = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @OutputMode = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'findings',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @OutputMode = 'NONE';
    DECLARE @Mode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@AnalyseModus,''))));
    DECLARE @Now datetime2(3)=SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40)='AVAILABLE';
    DECLARE @IsPartial bit=0;
    DECLARE @ErrorNumber int=NULL;
    DECLARE @ErrorMessage nvarchar(2048)=NULL;
    DECLARE @PrintMessage nvarchar(2048);
    DECLARE @Limit bigint=CASE WHEN @MaxZeilen IS NULL OR @MaxZeilen=0
                               THEN CONVERT(bigint,9223372036854775807)
                               ELSE CONVERT(bigint,@MaxZeilen) END;
    DECLARE @CandidatePoolRows int=CASE WHEN @MaxVerteilungsStatistiken BETWEEN 1 AND 250
                                        THEN @MaxVerteilungsStatistiken*4 ELSE 1000 END;
    IF @CandidatePoolRows>1000 SET @CandidatePoolRows=1000;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_StatisticsDistributionAnalysis';
        PRINT N'Die Procedure führt eine optionale Verteilungsanalyse sichtbarer Statistikhistogramme durch und verändert weder Daten noch Konfiguration.';
        PRINT N'@AnalyseModus=GEZIELT erfordert Objekt-/Schema-/Statistikfilter; VOLL benötigt CATALOG_DEEP.';
        PRINT N'@MaxVerteilungsStatistiken=1..250 begrenzt den Histogrammzugriff je Datenbank vor der Analyse.';
        PRINT N'@MinVerteilungsZeilen, @SkewWarnFaktor, @DominanterSchrittWarnPercent, @ModificationWarnPercent und @PartitionSpreadWarnPercent steuern Hinweise.';
        PRINT N'@MaxZeilen positiv begrenzt Resultsets; NULL/0 bedeutet unbegrenzt. @ResultSetArt=CONSOLE|RAW|TABLE|NONE; TABLE verwendet @ResultTablesJson.';
        PRINT N'Verteilungsindikatoren beweisen weder schlechte Pläne noch Out-of-Range-Werte; Query- und Laufzeitkontext separat prüfen.';
        RETURN;
    END;

    IF @Mode NOT IN ('GEZIELT','VOLL')
       OR @OutputMode NOT IN ('RAW','CONSOLE','NONE')
       OR @MaxVerteilungsStatistiken IS NULL OR @MaxVerteilungsStatistiken NOT BETWEEN 1 AND 250
       OR @MinVerteilungsZeilen IS NULL OR @MinVerteilungsZeilen<0
       OR @SkewWarnFaktor IS NULL OR @SkewWarnFaktor<1 OR @SkewWarnFaktor>100000
       OR @DominanterSchrittWarnPercent IS NULL OR @DominanterSchrittWarnPercent<0 OR @DominanterSchrittWarnPercent>100
       OR @ModificationWarnPercent IS NULL OR @ModificationWarnPercent<0 OR @ModificationWarnPercent>100
       OR @PartitionSpreadWarnPercent IS NULL OR @PartitionSpreadWarnPercent<0 OR @PartitionSpreadWarnPercent>100
 OR @MaxZeilen<0 OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
    BEGIN
        SELECT @StatusCode='INVALID_PARAMETER',@IsPartial=1,
               @ErrorMessage=N'Ungültiger Modus, Grenzwert-, Mengen-, Lock-Timeout- oder Ausgabeparameter.';
    END;

    IF @StatusCode='AVAILABLE'
        EXEC [monitor].[InternalCheckAnalysisPath]
              @AnalysisClass='CATALOG_DEEP'
            , @HighImpactConfirmed=@HighImpactConfirmed
            , @StatusCode=@StatusCode OUTPUT
            , @ErrorMessage=@ErrorMessage OUTPUT;
    IF @StatusCode<>'AVAILABLE' SET @IsPartial=1;

    DECLARE @CurrentCompatibilityLevel int=NULL;
    IF @StatusCode='AVAILABLE'
        SELECT @CurrentCompatibilityLevel=[compatibility_level]
        FROM [sys].[databases] WITH (NOLOCK)
        WHERE [database_id]=DB_ID();
    IF @StatusCode='AVAILABLE' AND @CurrentCompatibilityLevel<130
    BEGIN
        SELECT @StatusCode='UNAVAILABLE_FEATURE',@IsPartial=1,
               @ErrorMessage=N'Die Verteilungsanalyse benötigt Compatibility Level 130 oder höher für OPENJSON.';
    END;

    CREATE TABLE [#StatisticsDistributionAnalysis_Candidates]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [ObjectName] sysname NOT NULL
        , [ObjectId] int NOT NULL
        , [StatisticsId] int NOT NULL
        , [StatisticsName] sysname NOT NULL
        , [Rows] bigint NULL
        , [RowsSampled] bigint NULL
        , [SamplePercent] decimal(9,4) NULL
        , [Steps] int NULL
        , [ModificationCounter] bigint NULL
        , [ModificationPercent] decimal(19,4) NULL
        , [DaysSinceLastUpdate] int NULL
        , [IsFiltered] bit NULL
        , [IsIncremental] bit NULL
        , [HasPersistedSample] bit NULL
        , [PersistedSamplePercent] float NULL
        , [CandidateOrdinal] int NULL
    );
    CREATE TABLE [#StatisticsDistributionAnalysis_Incremental]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [ObjectName] sysname NOT NULL
        , [StatisticsId] int NOT NULL
        , [StatisticsName] sysname NOT NULL
        , [PartitionNumber] int NOT NULL
        , [Rows] bigint NULL
        , [RowsSampled] bigint NULL
        , [ModificationCounter] bigint NULL
        , [ModificationPercent] decimal(19,4) NULL
    );
    CREATE TABLE [#StatisticsDistributionAnalysis_DistributionDatabaseStatus]
    (
          [DatabaseName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [CandidateCount] bigint NOT NULL
        , [HistogramVisibleCount] bigint NOT NULL
        , [RequiredPermission] nvarchar(256) NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
        , [Detail] nvarchar(2000) NULL
    );
    CREATE TABLE [#StatisticsDistributionAnalysis_Distribution]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [ObjectName] sysname NOT NULL
        , [ObjectId] int NOT NULL
        , [StatisticsId] int NOT NULL
        , [StatisticsName] sysname NOT NULL
        , [CandidateOrdinal] int NOT NULL
        , [LeadingColumnName] sysname NULL
        , [LeadingTypeName] sysname NULL
        , [Rows] bigint NULL
        , [RowsSampled] bigint NULL
        , [SamplePercent] decimal(9,4) NULL
        , [ModificationCounter] bigint NULL
        , [ModificationPercent] decimal(19,4) NULL
        , [DaysSinceLastUpdate] int NULL
        , [IsFiltered] bit NULL
        , [IsIncremental] bit NULL
        , [HasPersistedSample] bit NULL
        , [PersistedSamplePercent] float NULL
        , [HistogramSteps] int NOT NULL
        , [HistogramEstimatedRows] decimal(38,4) NULL
        , [MaxEqualRows] decimal(38,4) NULL
        , [MaxRangeRows] decimal(38,4) NULL
        , [MaxStepRows] decimal(38,4) NULL
        , [DominantStepPercent] decimal(19,4) NULL
        , [EqualRowsSkewRatio] decimal(19,4) NULL
        , [AverageRangeRowsSkewRatio] decimal(19,4) NULL
        , [TailStepRows] decimal(38,4) NULL
        , [TailStepPercent] decimal(19,4) NULL
        , [TailVsAverageStepRatio] decimal(19,4) NULL
        , [AnalysisState] varchar(40) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
    );
    CREATE TABLE [#StatisticsDistributionAnalysis_PartitionVariation]
    (
          [DatabaseName] sysname NOT NULL
        , [SchemaName] sysname NOT NULL
        , [ObjectName] sysname NOT NULL
        , [StatisticsId] int NOT NULL
        , [StatisticsName] sysname NOT NULL
        , [PartitionCount] int NOT NULL
        , [PartitionsWithRows] int NOT NULL
        , [TotalRows] bigint NULL
        , [TotalModificationCounter] bigint NULL
        , [WeightedModificationPercent] decimal(19,4) NULL
        , [MinModificationPercent] decimal(19,4) NULL
        , [MaxModificationPercent] decimal(19,4) NULL
        , [ModificationSpreadPercentPoints] decimal(19,4) NULL
    );
    CREATE TABLE [#StatisticsDistributionAnalysis_Findings]
    (
          [FindingOrdinal] bigint IDENTITY(1,1) NOT NULL
        , [DatabaseName] sysname NULL
        , [SchemaName] sysname NULL
        , [ObjectName] sysname NULL
        , [StatisticsName] sysname NULL
        , [Severity] varchar(16) NOT NULL
        , [Confidence] varchar(16) NOT NULL
        , [FindingCode] varchar(120) NOT NULL
        , [MetricName] varchar(80) NOT NULL
        , [MetricValue] decimal(38,4) NULL
        , [ThresholdValue] decimal(38,4) NULL
        , [Evidence] nvarchar(1000) NOT NULL
        , [EvidenceLimit] nvarchar(1000) NOT NULL
        , [RecommendedNextCheck] nvarchar(1000) NOT NULL
    );

    DECLARE @StatisticsJson nvarchar(max)=NULL;
    IF @StatusCode='AVAILABLE'
    BEGIN TRY
        EXEC [monitor].[USP_Statistics]
              @DatabaseNames=@DatabaseNames
            , @SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen
            , @DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern
            , @ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern
            , @FullObjectNames=@FullObjectNames
            , @StatisticsNames=@StatisticsNames,@StatisticsNamePattern=@StatisticsNamePattern
            , @AnalyseModus=@Mode,@MinModificationPercent=0,@MinAlterTage=0
            , @MitIncrementellenDetails=1
            , @MaxZeilen=@CandidatePoolRows,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@StatisticsJson OUTPUT
            , @PrintMeldungen=@PrintMeldungen;

        SET @StatusCode=COALESCE(JSON_VALUE(@StatisticsJson,'$.meta.statusCode'),'ERROR_HANDLED');
        SET @IsPartial=CASE JSON_VALUE(@StatisticsJson,'$.meta.isPartial')
                           WHEN 'true' THEN 1 WHEN 'false' THEN 0
                           ELSE COALESCE(TRY_CONVERT(bit,JSON_VALUE(@StatisticsJson,'$.meta.isPartial')),1) END;

        INSERT [#StatisticsDistributionAnalysis_Candidates]
        (
              [DatabaseName],[SchemaName],[ObjectName],[ObjectId],[StatisticsId],[StatisticsName]
            , [Rows],[RowsSampled],[SamplePercent],[Steps],[ModificationCounter],[ModificationPercent]
            , [DaysSinceLastUpdate],[IsFiltered],[IsIncremental],[HasPersistedSample],[PersistedSamplePercent]
        )
        SELECT [DatabaseName],[SchemaName],[ObjectName],[ObjectId],[StatisticsId],[StatisticsName]
             , [Rows],[RowsSampled],[SamplePercent],[Steps],[ModificationCounter],[ModificationPercent]
             , [DaysSinceLastUpdate],[IsFiltered],[IsIncremental],[HasPersistedSample],[PersistedSamplePercent]
        FROM OPENJSON(COALESCE(@StatisticsJson,N'{}'),'$.statistics') WITH
        (
              [DatabaseName] sysname, [SchemaName] sysname, [ObjectName] sysname
            , [ObjectId] int, [StatisticsId] int, [StatisticsName] sysname
            , [Rows] bigint, [RowsSampled] bigint, [SamplePercent] decimal(9,4), [Steps] int
            , [ModificationCounter] bigint, [ModificationPercent] decimal(19,4)
            , [DaysSinceLastUpdate] int, [IsFiltered] bit, [IsIncremental] bit
            , [HasPersistedSample] bit, [PersistedSamplePercent] float
        );

        INSERT [#StatisticsDistributionAnalysis_Incremental]
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsId],[StatisticsName]
             , [PartitionNumber],[Rows],[RowsSampled],[ModificationCounter],[ModificationPercent]
        FROM OPENJSON(COALESCE(@StatisticsJson,N'{}'),'$.incrementalStatistics') WITH
        (
              [DatabaseName] sysname, [SchemaName] sysname, [ObjectName] sysname
            , [StatisticsId] int, [StatisticsName] sysname, [PartitionNumber] int
            , [Rows] bigint, [RowsSampled] bigint, [ModificationCounter] bigint
            , [ModificationPercent] decimal(19,4)
        );

        INSERT [#StatisticsDistributionAnalysis_DistributionDatabaseStatus]
        (
              [DatabaseName],[StatusCode],[IsPartial],[CandidateCount],[HistogramVisibleCount]
            , [RequiredPermission],[ErrorNumber],[ErrorMessage],[Detail]
        )
        SELECT [DatabaseName],[StatusCode],[IsPartial],0,0,[RequiredPermission],[ErrorNumber],[ErrorMessage],[Detail]
        FROM OPENJSON(COALESCE(@StatisticsJson,N'{}'),'$.databaseStatus') WITH
        (
              [DatabaseName] sysname, [StatusCode] varchar(40), [IsPartial] bit
            , [RequiredPermission] nvarchar(256), [ErrorNumber] int
            , [ErrorMessage] nvarchar(2048), [Detail] nvarchar(2000)
        );
    END TRY
    BEGIN CATCH
        SELECT @StatusCode=CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                                WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT' ELSE 'ERROR_HANDLED' END,
               @IsPartial=1,@ErrorNumber=ERROR_NUMBER(),@ErrorMessage=ERROR_MESSAGE();
    END CATCH;

    IF @StatusCode IN ('AVAILABLE','AVAILABLE_LIMITED','PARTIAL','AVAILABLE_WITH_FINDING')
    BEGIN
        ;WITH [ranked] AS
        (
            SELECT [RankOrdinal]=ROW_NUMBER() OVER
                   (
                       PARTITION BY [DatabaseName]
                       ORDER BY CASE WHEN [IsIncremental]=1 THEN 0 WHEN [IsFiltered]=1 THEN 1 ELSE 2 END,
                                COALESCE([Rows],0) DESC,COALESCE([ModificationPercent],0) DESC,
                                [SchemaName],[ObjectName],[StatisticsName]
                   ),[DatabaseName],[ObjectId],[StatisticsId]
            FROM [#StatisticsDistributionAnalysis_Candidates]
        )
        UPDATE [c]
        SET [CandidateOrdinal]=[r].[RankOrdinal]
        FROM [#StatisticsDistributionAnalysis_Candidates] [c]
        JOIN [ranked] [r]
          ON [r].[DatabaseName]=[c].[DatabaseName] AND [r].[ObjectId]=[c].[ObjectId]
         AND [r].[StatisticsId]=[c].[StatisticsId];

        DELETE FROM [#StatisticsDistributionAnalysis_Candidates] WHERE [CandidateOrdinal]>@MaxVerteilungsStatistiken;
        DELETE [i]
        FROM [#StatisticsDistributionAnalysis_Incremental] [i]
        WHERE NOT EXISTS
        (
            SELECT 1 FROM [#StatisticsDistributionAnalysis_Candidates] [c]
            WHERE [c].[DatabaseName]=[i].[DatabaseName]
              AND [c].[StatisticsId]=[i].[StatisticsId]
              AND [c].[SchemaName]=[i].[SchemaName]
              AND [c].[ObjectName]=[i].[ObjectName]
        );

        UPDATE [d]
        SET [CandidateCount]=(SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Candidates] [c] WHERE [c].[DatabaseName]=[d].[DatabaseName])
        FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus] [d];

        DECLARE @DbName sysname,@Sql nvarchar(max);
        DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT [DatabaseName] FROM [#StatisticsDistributionAnalysis_Candidates] ORDER BY [DatabaseName];
        OPEN dbcur; FETCH NEXT FROM dbcur INTO @DbName;
        WHILE @@FETCH_STATUS=0
        BEGIN
            BEGIN TRY
                SET @Sql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(11),@LockTimeoutMs)+N'; USE '+QUOTENAME(@DbName)+N';
INSERT [#StatisticsDistributionAnalysis_Distribution]
(
      [DatabaseName],[SchemaName],[ObjectName],[ObjectId],[StatisticsId],[StatisticsName],[CandidateOrdinal]
    , [LeadingColumnName],[LeadingTypeName],[Rows],[RowsSampled],[SamplePercent]
    , [ModificationCounter],[ModificationPercent],[DaysSinceLastUpdate]
    , [IsFiltered],[IsIncremental],[HasPersistedSample],[PersistedSamplePercent]
    , [HistogramSteps],[HistogramEstimatedRows],[MaxEqualRows],[MaxRangeRows],[MaxStepRows]
    , [DominantStepPercent],[EqualRowsSkewRatio],[AverageRangeRowsSkewRatio]
    , [TailStepRows],[TailStepPercent],[TailVsAverageStepRatio],[AnalysisState],[EvidenceLimit]
)
SELECT [c].[DatabaseName],[c].[SchemaName],[c].[ObjectName],[c].[ObjectId],[c].[StatisticsId],[c].[StatisticsName],[c].[CandidateOrdinal]
     , [lead].[LeadingColumnName],[lead].[LeadingTypeName],[c].[Rows],[c].[RowsSampled],[c].[SamplePercent]
     , [c].[ModificationCounter],[c].[ModificationPercent],[c].[DaysSinceLastUpdate]
     , [c].[IsFiltered],[c].[IsIncremental],[c].[HasPersistedSample],[c].[PersistedSamplePercent]
     , COALESCE([h].[HistogramSteps],0),[h].[HistogramEstimatedRows],[h].[MaxEqualRows],[h].[MaxRangeRows],[h].[MaxStepRows]
     , CONVERT(decimal(19,4),CONVERT(float,[h].[MaxStepRows])*100.0/NULLIF(CONVERT(float,[h].[HistogramEstimatedRows]),0))
     , CONVERT(decimal(19,4),CONVERT(float,[h].[MaxEqualRows])/NULLIF(CONVERT(float,[h].[AveragePositiveEqualRows]),0))
     , CONVERT(decimal(19,4),CONVERT(float,[h].[MaxAverageRangeRows])/NULLIF(CONVERT(float,[h].[AveragePositiveRangeRows]),0))
     , [tail].[TailStepRows]
     , CONVERT(decimal(19,4),CONVERT(float,[tail].[TailStepRows])*100.0/NULLIF(CONVERT(float,[h].[HistogramEstimatedRows]),0))
     , CONVERT(decimal(19,4),CONVERT(float,[tail].[TailStepRows])/
           NULLIF(CONVERT(float,[h].[HistogramEstimatedRows])/NULLIF(CONVERT(float,[h].[HistogramSteps]),0),0))
     , CASE WHEN COALESCE([h].[HistogramSteps],0)=0 THEN ''HISTOGRAM_NOT_VISIBLE''
            WHEN COALESCE([h].[HistogramEstimatedRows],0)<@pMinRows THEN ''SMALL_HISTOGRAM_CONTEXT''
            ELSE ''EVIDENCE_AVAILABLE'' END
     , N''Histogrammkennzahlen betreffen nur die erste Statistikspalte und den letzten materialisierten Statistikstand; sie enthalten keinen Query-/Prädikatkontext.''
FROM [#StatisticsDistributionAnalysis_Candidates] [c]
OUTER APPLY
(
    SELECT TOP (1) [col].[name] [LeadingColumnName],[typ].[name] [LeadingTypeName]
    FROM [sys].[stats_columns] [sc] WITH (NOLOCK)
    JOIN [sys].[columns] [col] WITH (NOLOCK)
      ON [col].[object_id]=[sc].[object_id] AND [col].[column_id]=[sc].[column_id]
    JOIN [sys].[types] [typ] WITH (NOLOCK) ON [typ].[user_type_id]=[col].[user_type_id]
    WHERE [sc].[object_id]=[c].[ObjectId] AND [sc].[stats_id]=[c].[StatisticsId]
    ORDER BY [sc].[stats_column_id]
) [lead]
OUTER APPLY
(
    SELECT COUNT(*) [HistogramSteps]
         , SUM(CONVERT(decimal(38,4),COALESCE([x].[equal_rows],0))+CONVERT(decimal(38,4),COALESCE([x].[range_rows],0))) [HistogramEstimatedRows]
         , MAX(CONVERT(decimal(38,4),[x].[equal_rows])) [MaxEqualRows]
         , MAX(CONVERT(decimal(38,4),[x].[range_rows])) [MaxRangeRows]
         , MAX(CONVERT(decimal(38,4),COALESCE([x].[equal_rows],0))+CONVERT(decimal(38,4),COALESCE([x].[range_rows],0))) [MaxStepRows]
         , AVG(NULLIF(CONVERT(decimal(38,4),[x].[equal_rows]),0)) [AveragePositiveEqualRows]
         , MAX(CONVERT(decimal(38,4),[x].[average_range_rows])) [MaxAverageRangeRows]
         , AVG(NULLIF(CONVERT(decimal(38,4),[x].[average_range_rows]),0)) [AveragePositiveRangeRows]
    FROM [sys].[dm_db_stats_histogram]([c].[ObjectId],[c].[StatisticsId]) [x]
) [h]
OUTER APPLY
(
    SELECT TOP (1)
           CONVERT(decimal(38,4),COALESCE([x].[equal_rows],0))+CONVERT(decimal(38,4),COALESCE([x].[range_rows],0)) [TailStepRows]
    FROM [sys].[dm_db_stats_histogram]([c].[ObjectId],[c].[StatisticsId]) [x]
    ORDER BY [x].[step_number] DESC
) [tail]
WHERE [c].[DatabaseName]=@pDbName;';

                EXEC [sys].[sp_executesql] @Sql,N'@pDbName sysname,@pMinRows bigint',
                     @pDbName=@DbName,@pMinRows=@MinVerteilungsZeilen;
            END TRY
            BEGIN CATCH
                UPDATE [#StatisticsDistributionAnalysis_DistributionDatabaseStatus]
                SET [StatusCode]=CASE WHEN ERROR_NUMBER() IN (229,262,297,300,371,916) THEN 'DENIED_PERMISSION'
                                      WHEN ERROR_NUMBER()=1222 THEN 'TIMEOUT'
                                      WHEN ERROR_NUMBER() IN (207,208,4121) THEN 'UNAVAILABLE_OBJECT'
                                      ELSE 'ERROR_HANDLED' END,
                    [IsPartial]=1,[ErrorNumber]=ERROR_NUMBER(),[ErrorMessage]=ERROR_MESSAGE(),
                    [Detail]=N'Histogrammzugriff fehlgeschlagen; andere Datenbanken und Basisstatistiken bleiben erhalten.'
                WHERE [DatabaseName]=@DbName;
            END CATCH;
            FETCH NEXT FROM dbcur INTO @DbName;
        END;
        CLOSE dbcur; DEALLOCATE dbcur;

        UPDATE [d]
        SET [HistogramVisibleCount]=
            (SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Distribution] [x]
             WHERE [x].[DatabaseName]=[d].[DatabaseName] AND [x].[HistogramSteps]>0)
        FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus] [d];

        UPDATE [#StatisticsDistributionAnalysis_DistributionDatabaseStatus]
        SET [StatusCode]='NOT_APPLICABLE',[Detail]=N'Keine sichtbare Statistik im begrenzten Kandidatenpool.'
        WHERE [CandidateCount]=0 AND [StatusCode]='AVAILABLE';

        UPDATE [#StatisticsDistributionAnalysis_DistributionDatabaseStatus]
        SET [StatusCode]='AVAILABLE_LIMITED',[IsPartial]=1,
            [Detail]=N'Kandidaten waren sichtbar, aber kein Histogramm war sichtbar; Metadatenberechtigung und Materialisierung prüfen.'
        WHERE [CandidateCount]>0 AND [HistogramVisibleCount]=0 AND [StatusCode]='AVAILABLE';

        INSERT [#StatisticsDistributionAnalysis_PartitionVariation]
        SELECT [i].[DatabaseName],[i].[SchemaName],[i].[ObjectName],[i].[StatisticsId],[i].[StatisticsName]
             , COUNT(*) [PartitionCount]
             , SUM(CASE WHEN COALESCE([i].[Rows],0)>0 THEN 1 ELSE 0 END) [PartitionsWithRows]
             , SUM([i].[Rows]) [TotalRows],SUM([i].[ModificationCounter]) [TotalModificationCounter]
             , CONVERT(decimal(19,4),CONVERT(float,SUM([i].[ModificationCounter]))*100.0/
                       NULLIF(CONVERT(float,SUM([i].[Rows])),0)) [WeightedModificationPercent]
             , MIN([i].[ModificationPercent]),MAX([i].[ModificationPercent])
             , CONVERT(decimal(19,4),MAX([i].[ModificationPercent])-MIN([i].[ModificationPercent]))
        FROM [#StatisticsDistributionAnalysis_Incremental] [i]
        GROUP BY [i].[DatabaseName],[i].[SchemaName],[i].[ObjectName],[i].[StatisticsId],[i].[StatisticsName];

        INSERT [#StatisticsDistributionAnalysis_Findings]
        ([DatabaseName],[SchemaName],[ObjectName],[StatisticsName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],'LOW','LOW','HISTOGRAM_NOT_VISIBLE','HistogramSteps',0,NULL,
               N'Für den begrenzten Kandidaten war kein sichtbarer Histogrammschritt verfügbar.',[EvidenceLimit],
               N'Metadatensichtbarkeit, Statistikmaterialisierung und den gezielten Scope prüfen.'
        FROM [#StatisticsDistributionAnalysis_Distribution] WHERE [HistogramSteps]=0
        UNION ALL
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],'MEDIUM','MEDIUM','DOMINANT_HISTOGRAM_STEP_REVIEW','DominantStepPercent',[DominantStepPercent],@DominanterSchrittWarnPercent,
               CONCAT(N'Der größte Histogrammschritt umfasst ',[DominantStepPercent],N' Prozent der sichtbaren Histogrammzeilen.'),[EvidenceLimit],
               N'Mit tatsächlicher Prädikatselektivität, Kardinalitätsabweichung und Planvarianten korrelieren.'
        FROM [#StatisticsDistributionAnalysis_Distribution]
        WHERE [HistogramEstimatedRows]>=@MinVerteilungsZeilen AND [DominantStepPercent]>=@DominanterSchrittWarnPercent
        UNION ALL
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],'MEDIUM','MEDIUM','EQUALITY_FREQUENCY_SKEW_REVIEW','EqualRowsSkewRatio',[EqualRowsSkewRatio],@SkewWarnFaktor,
               CONCAT(N'Maximale Gleichheitsfrequenz zu durchschnittlicher positiver Gleichheitsfrequenz: Faktor ',[EqualRowsSkewRatio],N'.'),[EvidenceLimit],
               N'Abfrageprädikate, Parameterwerte und geschätzte gegen tatsächliche Zeilen prüfen.'
        FROM [#StatisticsDistributionAnalysis_Distribution]
        WHERE [HistogramEstimatedRows]>=@MinVerteilungsZeilen AND [EqualRowsSkewRatio]>=@SkewWarnFaktor
        UNION ALL
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],'MEDIUM','MEDIUM','RANGE_DENSITY_SKEW_REVIEW','AverageRangeRowsSkewRatio',[AverageRangeRowsSkewRatio],@SkewWarnFaktor,
               CONCAT(N'Maximale zu durchschnittlicher positiver Range-Dichte: Faktor ',[AverageRangeRowsSkewRatio],N'.'),[EvidenceLimit],
               N'Range-Prädikate und tatsächliche Kardinalitäten für diese führende Statistikspalte prüfen.'
        FROM [#StatisticsDistributionAnalysis_Distribution]
        WHERE [HistogramEstimatedRows]>=@MinVerteilungsZeilen AND [AverageRangeRowsSkewRatio]>=@SkewWarnFaktor
        UNION ALL
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],'MEDIUM','LOW','TAIL_CONCENTRATION_REVIEW','TailVsAverageStepRatio',[TailVsAverageStepRatio],@SkewWarnFaktor,
               CONCAT(N'Letzter Histogrammschritt zu durchschnittlichem Schritt: Faktor ',[TailVsAverageStepRatio],N'; Tail-Anteil ',[TailStepPercent],N' Prozent.'),[EvidenceLimit],
               N'Zeitbezug, Insert-Muster und Querywerte prüfen; Tail-Konzentration beweist keine Ascending-Key-Problematik.'
        FROM [#StatisticsDistributionAnalysis_Distribution]
        WHERE [HistogramEstimatedRows]>=@MinVerteilungsZeilen AND [TailVsAverageStepRatio]>=@SkewWarnFaktor
        UNION ALL
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],'MEDIUM','LOW','OUT_OF_RANGE_NOT_MEASURABLE_REVIEW','ModificationPercent',[ModificationPercent],@ModificationWarnPercent,
               CONCAT(N'Seit dem Statistikstand wurden ',[ModificationPercent],N' Prozent relativ zur sichtbaren Statistikzeilenzahl geändert.'),[EvidenceLimit],
               N'Neue Werte, Queryliterale und tatsächliche Kardinalitäten kontrolliert prüfen; der Modification Counter enthält keine Wertverteilung.'
        FROM [#StatisticsDistributionAnalysis_Distribution]
        WHERE [HistogramSteps]>0 AND [Rows]>=@MinVerteilungsZeilen AND [ModificationPercent]>=@ModificationWarnPercent;

        INSERT [#StatisticsDistributionAnalysis_Findings]
        ([DatabaseName],[SchemaName],[ObjectName],[StatisticsName],[Severity],[Confidence],[FindingCode],[MetricName],[MetricValue],[ThresholdValue],[Evidence],[EvidenceLimit],[RecommendedNextCheck])
        SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],'MEDIUM','MEDIUM','PARTITION_MODIFICATION_SKEW_REVIEW','ModificationSpreadPercentPoints',[ModificationSpreadPercentPoints],@PartitionSpreadWarnPercent,
               CONCAT(N'Änderungsanteile inkrementeller Statistikpartitionen streuen um ',[ModificationSpreadPercentPoints],N' Prozentpunkte; gewichteter Anteil ',[WeightedModificationPercent],N' Prozent.'),
               N'Partitionswerte stammen aus dem aktuellen inkrementellen Statistikstatus; Retention, Partitionswechsel und Statistikupdates beeinflussen die Evidenz.',
               N'Betroffene Partitionen, Ladefenster und den beabsichtigten inkrementellen Statistikpflegepfad prüfen.'
        FROM [#StatisticsDistributionAnalysis_PartitionVariation]
        WHERE [TotalRows]>=@MinVerteilungsZeilen AND [ModificationSpreadPercentPoints]>=@PartitionSpreadWarnPercent;

        IF EXISTS(SELECT 1 FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus]
                  WHERE [StatusCode] NOT IN ('AVAILABLE','NOT_APPLICABLE'))
        BEGIN
            SET @IsPartial=1;
            IF EXISTS(SELECT 1 FROM [#StatisticsDistributionAnalysis_Distribution]) SET @StatusCode='AVAILABLE_LIMITED';
            ELSE SELECT TOP (1) @StatusCode=[StatusCode],@ErrorNumber=[ErrorNumber],@ErrorMessage=[ErrorMessage]
                 FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus] WHERE [StatusCode] NOT IN ('AVAILABLE','NOT_APPLICABLE') ORDER BY [DatabaseName];
        END
        ELSE IF EXISTS(SELECT 1 FROM [#StatisticsDistributionAnalysis_Findings])
            SET @StatusCode='AVAILABLE_WITH_FINDING';
        ELSE IF NOT EXISTS(SELECT 1 FROM [#StatisticsDistributionAnalysis_Distribution])
            SET @StatusCode='NOT_APPLICABLE';
        ELSE
            SET @StatusCode='AVAILABLE';
    END;

    IF NOT EXISTS(SELECT 1 FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus])
       AND @StatusCode<>'AVAILABLE'
        INSERT [#StatisticsDistributionAnalysis_DistributionDatabaseStatus]
        VALUES(NULL,@StatusCode,1,0,0,N'CATALOG_DEEP und Statistik-Metadatensichtbarkeit',@ErrorNumber,@ErrorMessage,N'Keine Verteilungsanalyse ausgeführt.');

    SELECT @StatusCodeOut=@StatusCode,@IsPartialOut=@IsPartial,
           @ErrorNumberOut=@ErrorNumber,@ErrorMessageOut=@ErrorMessage;

    IF @PrintMeldungen=1 AND @StatusCode NOT IN ('AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE')
    BEGIN
        SET @PrintMessage=FORMATMESSAGE(N'WARNUNG USP_StatisticsDistributionAnalysis %s: %s',@StatusCode,COALESCE(@ErrorMessage,N'Teilergebnis oder Evidenzlücke.'));
        RAISERROR(N'%s',10,1,@PrintMessage) WITH NOWAIT;
    END;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @MetaJson nvarchar(max)=
            (SELECT N'StatisticsDistributionAnalysis' [resultName],1 [schemaVersion],@Now [generatedAtUtc],
                    @StatusCode [statusCode],@IsPartial [isPartial],@MaxVerteilungsStatistiken [maxStatisticsPerDatabase],
                    @MinVerteilungsZeilen [minimumDistributionRows],
                    (SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Distribution]) [distributionCount],
                    (SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Findings]) [findingCount]
             FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @DatabaseJson nvarchar(max)=(SELECT * FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus] ORDER BY [DatabaseName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @DistributionJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#StatisticsDistributionAnalysis_Distribution] ORDER BY [DatabaseName],[CandidateOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @PartitionJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#StatisticsDistributionAnalysis_PartitionVariation] ORDER BY [ModificationSpreadPercentPoints] DESC,[DatabaseName],[SchemaName],[ObjectName],[StatisticsName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @FindingsJson nvarchar(max)=(SELECT TOP (@Limit) * FROM [#StatisticsDistributionAnalysis_Findings] ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,[FindingOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT(N'{"meta":',COALESCE(@MetaJson,N'{}'),N',"databaseStatus":',COALESCE(@DatabaseJson,N'[]'),
                         N',"distribution":',COALESCE(@DistributionJson,N'[]'),N',"partitionVariation":',COALESCE(@PartitionJson,N'[]'),
                         N',"findings":',COALESCE(@FindingsJson,N'[]'),N'}');
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT N'USP_StatisticsDistributionAnalysis' [ModuleName],@Now [CollectionTimeUtc],@StatusCode [StatusCode],@IsPartial [IsPartial],
               (SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Distribution]) [DistributionCount],(SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Findings]) [FindingCount],
               @ErrorNumber [ErrorNumber],@ErrorMessage [ErrorMessage],
               N'Begrenzte Histogramm- und Partitionsverteilung; Indikatoren sind keine Planursache.' [Detail];
        SELECT * FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus] ORDER BY [DatabaseName];
        SELECT TOP (@Limit) * FROM [#StatisticsDistributionAnalysis_Distribution] ORDER BY [DatabaseName],[CandidateOrdinal];
        SELECT TOP (@Limit) * FROM [#StatisticsDistributionAnalysis_PartitionVariation] ORDER BY [ModificationSpreadPercentPoints] DESC,[DatabaseName],[SchemaName],[ObjectName],[StatisticsName];
        SELECT TOP (@Limit) * FROM [#StatisticsDistributionAnalysis_Findings] ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,[FindingOrdinal];
    END
    ELSE IF @OutputMode='CONSOLE'
    BEGIN
        SELECT N'Statistikverteilung' [Ergebnis],@Now [Stand_UTC],@StatusCode [Status],@IsPartial [Teilergebnis],
               (SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Distribution]) [Analysierte_Statistiken],(SELECT COUNT_BIG(*) FROM [#StatisticsDistributionAnalysis_Findings]) [Befunde],@ErrorMessage [Hinweis];
        SELECT N'Datenbankstatus Statistikverteilung' [Ergebnis],[DatabaseName] [Datenbank],[StatusCode] [Status],[CandidateCount] [Kandidaten],
               [HistogramVisibleCount] [Histogramme_sichtbar],[IsPartial] [Teilweise],[Detail] [Hinweis]
        FROM [#StatisticsDistributionAnalysis_DistributionDatabaseStatus] ORDER BY [DatabaseName];
        SELECT TOP (@Limit) N'Histogrammverteilung' [Ergebnis],[d].* FROM [#StatisticsDistributionAnalysis_Distribution] [d] ORDER BY [DatabaseName],[CandidateOrdinal];
        SELECT TOP (@Limit) N'Inkrementelle Partitionsvariation' [Ergebnis],[p].* FROM [#StatisticsDistributionAnalysis_PartitionVariation] [p]
        ORDER BY [ModificationSpreadPercentPoints] DESC,[DatabaseName],[SchemaName],[ObjectName],[StatisticsName];
        SELECT TOP (@Limit) N'Statistikverteilungsbefund' [Ergebnis],[f].* FROM [#StatisticsDistributionAnalysis_Findings] [f]
        ORDER BY CASE [Severity] WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END,[FindingOrdinal];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#StatisticsDistributionAnalysis_Findings'
            , @ResultLabel=N'StatisticsDistributionAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#StatisticsDistributionAnalysis_Findings'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
