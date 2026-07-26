USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 175_P1_Statistics_Runtime_Contract.sql
Zweck        : Prüft Laufzeitverträge für acht
               P1-Statistikverteilungsfälle.
Datenschutz  : Ausschließlich generische synthetische Objekte und Principals;
               Laufzeitwerte werden nicht in Repositoryartefakte übernommen.
Nebenwirkung : Erzeugt kurzlebige Tabellen, Statistiken, eine Partitionierung
               sowie transaktional einen synthetischen Berechtigungskontext.
               Sämtliche Fixtures werden im Erfolgs- und Fehlerpfad entfernt.
Kosten       : Begrenzte FULLSCAN-Statistiken auf weniger als 10.000
               synthetischen Zeilen; Histogrammzugriffe sind objektbezogen.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);
DECLARE @Impersonating bit=0;

BEGIN TRY
    DROP TABLE IF EXISTS [dbo].[ExampleStatisticsIncremental];
    DROP TABLE IF EXISTS [dbo].[ExampleStatisticsBounded];
    DROP TABLE IF EXISTS [dbo].[ExampleStatisticsFiltered];
    DROP TABLE IF EXISTS [dbo].[ExampleStatisticsModified];
    DROP TABLE IF EXISTS [dbo].[ExampleStatisticsTail];
    DROP TABLE IF EXISTS [dbo].[ExampleStatisticsDominant];
    DROP TABLE IF EXISTS [dbo].[ExampleStatisticsUniform];

    IF EXISTS(SELECT 1 FROM [sys].[partition_schemes] WITH (NOLOCK) WHERE [name]=N'PS_ExampleStatisticsIncremental')
        DROP PARTITION SCHEME [PS_ExampleStatisticsIncremental];
    IF EXISTS(SELECT 1 FROM [sys].[partition_functions] WITH (NOLOCK) WHERE [name]=N'PF_ExampleStatisticsIncremental')
        DROP PARTITION FUNCTION [PF_ExampleStatisticsIncremental];

    CREATE TABLE [#P1_Statistics_Runtime_Contract_Numbers]
    (
        [NumberValue] int NOT NULL PRIMARY KEY
    );

    ;WITH [numbers] AS
    (
        SELECT 1 AS [NumberValue]
        UNION ALL
        SELECT [NumberValue]+1
        FROM [numbers]
        WHERE [NumberValue]<2000
    )
    INSERT [#P1_Statistics_Runtime_Contract_Numbers]([NumberValue])
    SELECT [NumberValue]
    FROM [numbers]
    OPTION (MAXRECURSION 0);

    CREATE TABLE [dbo].[ExampleStatisticsUniform]
    (
        [DistributionValue] int NOT NULL
    );
    INSERT [dbo].[ExampleStatisticsUniform]([DistributionValue])
    SELECT [NumberValue]
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=1000;
    CREATE STATISTICS [ST_ExampleStatisticsUniform]
        ON [dbo].[ExampleStatisticsUniform]([DistributionValue]) WITH FULLSCAN;

    CREATE TABLE [dbo].[ExampleStatisticsDominant]
    (
        [DistributionValue] int NOT NULL
    );
    INSERT [dbo].[ExampleStatisticsDominant]([DistributionValue])
    SELECT 1 FROM [#P1_Statistics_Runtime_Contract_Numbers] WHERE [NumberValue]<=1000
    UNION ALL
    SELECT [NumberValue]+1 FROM [#P1_Statistics_Runtime_Contract_Numbers] WHERE [NumberValue]<=100;
    CREATE STATISTICS [ST_ExampleStatisticsDominant]
        ON [dbo].[ExampleStatisticsDominant]([DistributionValue]) WITH FULLSCAN;

    CREATE TABLE [dbo].[ExampleStatisticsTail]
    (
        [DistributionValue] int NOT NULL
    );
    INSERT [dbo].[ExampleStatisticsTail]([DistributionValue])
    SELECT [NumberValue] FROM [#P1_Statistics_Runtime_Contract_Numbers] WHERE [NumberValue]<=100
    UNION ALL
    SELECT 101 FROM [#P1_Statistics_Runtime_Contract_Numbers] WHERE [NumberValue]<=1000;
    CREATE STATISTICS [ST_ExampleStatisticsTail]
        ON [dbo].[ExampleStatisticsTail]([DistributionValue]) WITH FULLSCAN;

    CREATE TABLE [dbo].[ExampleStatisticsModified]
    (
        [DistributionValue] int NOT NULL
    );
    INSERT [dbo].[ExampleStatisticsModified]([DistributionValue])
    SELECT (([NumberValue]-1)%100)+1
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=1000;
    CREATE STATISTICS [ST_ExampleStatisticsModified]
        ON [dbo].[ExampleStatisticsModified]([DistributionValue]) WITH FULLSCAN;
    INSERT [dbo].[ExampleStatisticsModified]([DistributionValue])
    SELECT 1000+[NumberValue]
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=500;

    CREATE TABLE [dbo].[ExampleStatisticsFiltered]
    (
          [DistributionValue] int NOT NULL
        , [IsIncluded] bit NOT NULL
    );
    INSERT [dbo].[ExampleStatisticsFiltered]([DistributionValue],[IsIncluded])
    SELECT (([NumberValue]-1)%100)+1,CONVERT(bit,1)
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=1000
    UNION ALL
    SELECT (([NumberValue]-1)%100)+1,CONVERT(bit,0)
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=1000;
    CREATE STATISTICS [ST_ExampleStatisticsFiltered]
        ON [dbo].[ExampleStatisticsFiltered]([DistributionValue])
        WHERE [IsIncluded]=(1) WITH FULLSCAN;

    CREATE TABLE [dbo].[ExampleStatisticsBounded]
    (
          [C1] int NOT NULL
        , [C2] int NOT NULL
        , [C3] int NOT NULL
        , [C4] int NOT NULL
        , [C5] int NOT NULL
        , [C6] int NOT NULL
    );
    INSERT [dbo].[ExampleStatisticsBounded]([C1],[C2],[C3],[C4],[C5],[C6])
    SELECT ([NumberValue]-1)%10,([NumberValue]-1)%20,([NumberValue]-1)%25,
           ([NumberValue]-1)%40,([NumberValue]-1)%50,([NumberValue]-1)%100
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=1000;
    CREATE STATISTICS [ST_ExampleStatisticsBounded_1] ON [dbo].[ExampleStatisticsBounded]([C1]) WITH FULLSCAN;
    CREATE STATISTICS [ST_ExampleStatisticsBounded_2] ON [dbo].[ExampleStatisticsBounded]([C2]) WITH FULLSCAN;
    CREATE STATISTICS [ST_ExampleStatisticsBounded_3] ON [dbo].[ExampleStatisticsBounded]([C3]) WITH FULLSCAN;
    CREATE STATISTICS [ST_ExampleStatisticsBounded_4] ON [dbo].[ExampleStatisticsBounded]([C4]) WITH FULLSCAN;
    CREATE STATISTICS [ST_ExampleStatisticsBounded_5] ON [dbo].[ExampleStatisticsBounded]([C5]) WITH FULLSCAN;
    CREATE STATISTICS [ST_ExampleStatisticsBounded_6] ON [dbo].[ExampleStatisticsBounded]([C6]) WITH FULLSCAN;

    CREATE PARTITION FUNCTION [PF_ExampleStatisticsIncremental](int)
        AS RANGE RIGHT FOR VALUES(100,200);
    CREATE PARTITION SCHEME [PS_ExampleStatisticsIncremental]
        AS PARTITION [PF_ExampleStatisticsIncremental] ALL TO ([PRIMARY]);
    CREATE TABLE [dbo].[ExampleStatisticsIncremental]
    (
          [PartitionValue] int NOT NULL
        , [DistributionValue] int NOT NULL
    ) ON [PS_ExampleStatisticsIncremental]([PartitionValue]);
    INSERT [dbo].[ExampleStatisticsIncremental]([PartitionValue],[DistributionValue])
    SELECT CASE WHEN [NumberValue]<=100 THEN 1
                WHEN [NumberValue]<=200 THEN 150 ELSE 250 END,
           [NumberValue]
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=300;
    CREATE STATISTICS [ST_ExampleStatisticsIncremental]
        ON [dbo].[ExampleStatisticsIncremental]([DistributionValue])
        WITH FULLSCAN,INCREMENTAL=ON;
    INSERT [dbo].[ExampleStatisticsIncremental]([PartitionValue],[DistributionValue])
    SELECT 250,1000+[NumberValue]
    FROM [#P1_Statistics_Runtime_Contract_Numbers]
    WHERE [NumberValue]<=100;

    /* STAT-UNIFORM: sichtbares, begrenztes und annähernd gleichmäßiges Histogramm. */
    EXEC [monitor].[USP_StatisticsDistributionAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
         @ObjectNames=N'ExampleStatisticsUniform',
         @StatisticsNames=N'ST_ExampleStatisticsUniform',@AnalyseModus='GEZIELT',
         @MaxVerteilungsStatistiken=5,@MinVerteilungsZeilen=100,
         @SkewWarnFaktor=10,@DominanterSchrittWarnPercent=50,
         @ModificationWarnPercent=100,@PartitionSpreadWarnPercent=100,
         @MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE'
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.distribution')
           WITH ([ObjectName] sysname N'$.ObjectName',[HistogramSteps] int N'$.HistogramSteps',
                 [DominantStepPercent] decimal(19,4) N'$.DominantStepPercent',
                 [TailVsAverageStepRatio] decimal(19,4) N'$.TailVsAverageStepRatio',
                 [AnalysisState] varchar(40) N'$.AnalysisState')
           WHERE [ObjectName]=N'ExampleStatisticsUniform'
             AND [HistogramSteps]>0
             AND [AnalysisState]='EVIDENCE_AVAILABLE')
       OR EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.findings')
           WITH ([ObjectName] sysname N'$.ObjectName',[FindingCode] varchar(120) N'$.FindingCode')
           WHERE [ObjectName]=N'ExampleStatisticsUniform'
             AND [FindingCode] IN('DOMINANT_HISTOGRAM_STEP_REVIEW','EQUALITY_FREQUENCY_SKEW_REVIEW',
                                  'RANGE_DENSITY_SKEW_REVIEW','TAIL_CONCENTRATION_REVIEW'))
        THROW 54900,N'P1-Vertrag STAT-UNIFORM fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('STAT-UNIFORM');

    /* STAT-DOMINANT: ein Schritt enthält den überwiegenden Zeilenanteil. */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_StatisticsDistributionAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
         @ObjectNames=N'ExampleStatisticsDominant',
         @StatisticsNames=N'ST_ExampleStatisticsDominant',@AnalyseModus='GEZIELT',
         @MaxVerteilungsStatistiken=5,@MinVerteilungsZeilen=100,
         @SkewWarnFaktor=100000,@DominanterSchrittWarnPercent=50,
         @ModificationWarnPercent=100,@PartitionSpreadWarnPercent=100,
         @MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE_WITH_FINDING'
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.findings')
           WITH ([ObjectName] sysname N'$.ObjectName',[FindingCode] varchar(120) N'$.FindingCode',
                 [MetricValue] decimal(38,4) N'$.MetricValue',[ThresholdValue] decimal(38,4) N'$.ThresholdValue')
           WHERE [ObjectName]=N'ExampleStatisticsDominant'
             AND [FindingCode]='DOMINANT_HISTOGRAM_STEP_REVIEW'
             AND [MetricValue]>=50 AND [ThresholdValue]=50)
        THROW 54901,N'P1-Vertrag STAT-DOMINANT fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('STAT-DOMINANT');

    /* STAT-TAIL: der letzte Histogrammschritt ist gegenüber dem Durchschnitt konzentriert. */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_StatisticsDistributionAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
         @ObjectNames=N'ExampleStatisticsTail',
         @StatisticsNames=N'ST_ExampleStatisticsTail',@AnalyseModus='GEZIELT',
         @MaxVerteilungsStatistiken=5,@MinVerteilungsZeilen=100,
         @SkewWarnFaktor=10,@DominanterSchrittWarnPercent=100,
         @ModificationWarnPercent=100,@PartitionSpreadWarnPercent=100,
         @MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE_WITH_FINDING'
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.findings')
           WITH ([ObjectName] sysname N'$.ObjectName',[FindingCode] varchar(120) N'$.FindingCode',
                 [MetricValue] decimal(38,4) N'$.MetricValue',[ThresholdValue] decimal(38,4) N'$.ThresholdValue')
           WHERE [ObjectName]=N'ExampleStatisticsTail'
             AND [FindingCode]='TAIL_CONCENTRATION_REVIEW'
             AND [MetricValue]>=10 AND [ThresholdValue]=10)
        THROW 54902,N'P1-Vertrag STAT-TAIL fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('STAT-TAIL');

    /* STAT-MODIFIED: Modification Counter bleibt Wertverteilungs-Evidenzgrenze. */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_StatisticsDistributionAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
         @ObjectNames=N'ExampleStatisticsModified',
         @StatisticsNames=N'ST_ExampleStatisticsModified',@AnalyseModus='GEZIELT',
         @MaxVerteilungsStatistiken=5,@MinVerteilungsZeilen=100,
         @SkewWarnFaktor=100000,@DominanterSchrittWarnPercent=100,
         @ModificationWarnPercent=20,@PartitionSpreadWarnPercent=100,
         @MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE_WITH_FINDING'
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.findings')
           WITH ([ObjectName] sysname N'$.ObjectName',[FindingCode] varchar(120) N'$.FindingCode',
                 [MetricValue] decimal(38,4) N'$.MetricValue',[ThresholdValue] decimal(38,4) N'$.ThresholdValue')
           WHERE [ObjectName]=N'ExampleStatisticsModified'
             AND [FindingCode]='OUT_OF_RANGE_NOT_MEASURABLE_REVIEW'
             AND [MetricValue]>=20 AND [ThresholdValue]=20)
        THROW 54903,N'P1-Vertrag STAT-MODIFIED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('STAT-MODIFIED');

    /* STAT-FILTERED: Filterstatus wird ausgewiesen, ohne Eignungsurteil. */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_StatisticsDistributionAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
         @ObjectNames=N'ExampleStatisticsFiltered',
         @StatisticsNames=N'ST_ExampleStatisticsFiltered',@AnalyseModus='GEZIELT',
         @MaxVerteilungsStatistiken=5,@MinVerteilungsZeilen=100,
         @SkewWarnFaktor=100000,@DominanterSchrittWarnPercent=100,
         @ModificationWarnPercent=100,@PartitionSpreadWarnPercent=100,
         @MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE'
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.distribution')
           WITH ([ObjectName] sysname N'$.ObjectName',[StatisticsName] sysname N'$.StatisticsName',
                 [Rows] bigint N'$.Rows',[IsFiltered] bit N'$.IsFiltered',
                 [AnalysisState] varchar(40) N'$.AnalysisState',[EvidenceLimit] nvarchar(1000) N'$.EvidenceLimit')
           WHERE [ObjectName]=N'ExampleStatisticsFiltered'
             AND [StatisticsName]=N'ST_ExampleStatisticsFiltered'
             AND [Rows]=1000 AND [IsFiltered]=1
             AND [AnalysisState]='EVIDENCE_AVAILABLE'
             AND NULLIF([EvidenceLimit],N'') IS NOT NULL)
        THROW 54904,N'P1-Vertrag STAT-FILTERED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('STAT-FILTERED');

    /* STAT-INCREMENTAL: unterschiedliche Änderungsanteile bleiben getrennte Partitions-Evidenz. */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_StatisticsDistributionAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
         @ObjectNames=N'ExampleStatisticsIncremental',
         @StatisticsNames=N'ST_ExampleStatisticsIncremental',@AnalyseModus='GEZIELT',
         @MaxVerteilungsStatistiken=5,@MinVerteilungsZeilen=100,
         @SkewWarnFaktor=100000,@DominanterSchrittWarnPercent=100,
         @ModificationWarnPercent=100,@PartitionSpreadWarnPercent=20,
         @MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status<>'AVAILABLE_WITH_FINDING'
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.partitionVariation')
           WITH ([ObjectName] sysname N'$.ObjectName',[StatisticsName] sysname N'$.StatisticsName',
                 [PartitionCount] int N'$.PartitionCount',
                 [ModificationSpreadPercentPoints] decimal(19,4) N'$.ModificationSpreadPercentPoints')
           WHERE [ObjectName]=N'ExampleStatisticsIncremental'
             AND [StatisticsName]=N'ST_ExampleStatisticsIncremental'
             AND [PartitionCount]>=3 AND [ModificationSpreadPercentPoints]>=20)
       OR NOT EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.findings')
           WITH ([ObjectName] sysname N'$.ObjectName',[FindingCode] varchar(120) N'$.FindingCode')
           WHERE [ObjectName]=N'ExampleStatisticsIncremental'
             AND [FindingCode]='PARTITION_MODIFICATION_SKEW_REVIEW')
        THROW 54905,N'P1-Vertrag STAT-INCREMENTAL fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('STAT-INCREMENTAL');

    /* STAT-BOUNDED: vor Histogrammzugriff bleiben höchstens zwei Kandidaten. */
    SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
    EXEC [monitor].[USP_StatisticsDistributionAnalysis]
         @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
         @ObjectNames=N'ExampleStatisticsBounded',@AnalyseModus='GEZIELT',
         @MaxVerteilungsStatistiken=2,@MinVerteilungsZeilen=0,
         @SkewWarnFaktor=100000,@DominanterSchrittWarnPercent=100,
         @ModificationWarnPercent=100,@PartitionSpreadWarnPercent=100,
         @MaxZeilen=0,@ResultSetArt='NONE',
         @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
         @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
         @HighImpactConfirmed=1;
    IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING')
       OR TRY_CONVERT(int,JSON_VALUE(@Json,N'$.meta.distributionCount'))<>2
       OR EXISTS
          (SELECT 1
           FROM OPENJSON(@Json,N'$.databaseStatus')
           WITH ([DatabaseName] sysname N'$.DatabaseName',[CandidateCount] bigint N'$.CandidateCount',
                 [HistogramVisibleCount] bigint N'$.HistogramVisibleCount')
           WHERE [DatabaseName]=(SELECT [name] FROM [master].[sys].[databases] WITH (NOLOCK) WHERE [database_id] = DB_ID())
             AND ([CandidateCount]<>2 OR [HistogramVisibleCount]>2))
       OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.distribution'))<>2
        THROW 54906,N'P1-Vertrag STAT-BOUNDED fehlgeschlagen.',1;
    INSERT @ExecutedCases VALUES('STAT-BOUNDED');

    /* STAT-DENIED: aktives CATALOG_DEEP-Gate verweigert einem nicht passenden User den Zugriff. */
    IF USER_ID(N'ExampleStatisticsDeniedUser') IS NOT NULL
        THROW 54907,N'Der synthetische Principal für STAT-DENIED ist bereits vorhanden.',1;

    BEGIN TRANSACTION;
    BEGIN TRY
        EXEC(N'CREATE OR ALTER VIEW [monitor].[VW_AnalyseAccessPolicy]
AS
SELECT [p].[AnalysisClass],[p].[ADGroupName],[p].[IsEnabled],[p].[ValidFromUtc],
       [p].[ValidToUtc],[p].[Priority],[p].[Comment]
FROM
(
    VALUES
    (
        CAST(''CATALOG_DEEP'' AS varchar(64)),
        CAST(N''ExampleStatisticsAllowedGroup'' AS nvarchar(256)),
        CAST(1 AS bit),CAST(NULL AS datetime2(0)),CAST(NULL AS datetime2(0)),
        CAST(100 AS smallint),CAST(N''Synthetic statistics permission contract'' AS nvarchar(1000))
    )
) AS [p]([AnalysisClass],[ADGroupName],[IsEnabled],[ValidFromUtc],[ValidToUtc],[Priority],[Comment]);');

        CREATE USER [ExampleStatisticsDeniedUser] WITHOUT LOGIN;
        GRANT EXECUTE ON OBJECT::[monitor].[USP_StatisticsDistributionAnalysis]
            TO [ExampleStatisticsDeniedUser];
        GRANT SELECT ON OBJECT::[monitor].[VW_AnalyseAccessCurrent]
            TO [ExampleStatisticsDeniedUser];

        SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
        EXECUTE AS USER=N'ExampleStatisticsDeniedUser';
        SET @Impersonating=1;
        EXEC [monitor].[USP_StatisticsDistributionAnalysis]
             @DatabaseNames=N'[DeineDatenbank]',@SchemaNames=N'dbo',
             @ObjectNames=N'ExampleStatisticsUniform',
             @StatisticsNames=N'ST_ExampleStatisticsUniform',@AnalyseModus='GEZIELT',
             @MaxVerteilungsStatistiken=1,@MinVerteilungsZeilen=0,
             @MaxZeilen=0,@ResultSetArt='NONE',
             @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
             @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
             @HighImpactConfirmed=1;
        REVERT;
        SET @Impersonating=0;
        IF ISJSON(@Json)<>1 OR @Status<>'DENIED_GROUP' OR @Partial<>1
           OR NOT EXISTS
              (SELECT 1
               FROM OPENJSON(@Json,N'$.databaseStatus')
               WITH ([StatusCode] varchar(40) N'$.StatusCode')
               WHERE [StatusCode]='DENIED_GROUP')
            THROW 54908,N'P1-Vertrag STAT-DENIED fehlgeschlagen.',1;

        ROLLBACK TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @Impersonating=1
        BEGIN
            BEGIN TRY
                REVERT;
                SET @Impersonating=0;
            END TRY
            BEGIN CATCH
            END CATCH;
        END;
        IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    INSERT @ExecutedCases VALUES('STAT-DENIED');

    DROP TABLE [dbo].[ExampleStatisticsIncremental];
    DROP PARTITION SCHEME [PS_ExampleStatisticsIncremental];
    DROP PARTITION FUNCTION [PF_ExampleStatisticsIncremental];
    DROP TABLE [dbo].[ExampleStatisticsBounded];
    DROP TABLE [dbo].[ExampleStatisticsFiltered];
    DROP TABLE [dbo].[ExampleStatisticsModified];
    DROP TABLE [dbo].[ExampleStatisticsTail];
    DROP TABLE [dbo].[ExampleStatisticsDominant];
    DROP TABLE [dbo].[ExampleStatisticsUniform];
END TRY
BEGIN CATCH
    IF @Impersonating=1
    BEGIN
        BEGIN TRY
            REVERT;
        END TRY
        BEGIN CATCH
        END CATCH;
    END;
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;

    BEGIN TRY
        DROP TABLE IF EXISTS [dbo].[ExampleStatisticsIncremental];
        DROP TABLE IF EXISTS [dbo].[ExampleStatisticsBounded];
        DROP TABLE IF EXISTS [dbo].[ExampleStatisticsFiltered];
        DROP TABLE IF EXISTS [dbo].[ExampleStatisticsModified];
        DROP TABLE IF EXISTS [dbo].[ExampleStatisticsTail];
        DROP TABLE IF EXISTS [dbo].[ExampleStatisticsDominant];
        DROP TABLE IF EXISTS [dbo].[ExampleStatisticsUniform];
        IF EXISTS(SELECT 1 FROM [sys].[partition_schemes] WITH (NOLOCK) WHERE [name]=N'PS_ExampleStatisticsIncremental')
            DROP PARTITION SCHEME [PS_ExampleStatisticsIncremental];
        IF EXISTS(SELECT 1 FROM [sys].[partition_functions] WITH (NOLOCK) WHERE [name]=N'PF_ExampleStatisticsIncremental')
            DROP PARTITION FUNCTION [PF_ExampleStatisticsIncremental];
    END TRY
    BEGIN CATCH
    END CATCH;
    THROW;
END CATCH;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>8
    THROW 54909,N'Der P1-Statistikverteilungsvertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Acht synthetische P1-Statistikverteilungsfälle wurden vollständig bereinigt.' AS [Detail]
FROM @ExecutedCases;
GO
