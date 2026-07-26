USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_ObjectAnalysis
Version      : 2.4.0
Stand        : 2026-07-23
Typ          : Stored Procedure
Zweck        : Orchestriert die Objekt-, Index-, Statistik-, Partition-,
               Columnstore-, Vector-Index- und Physical-Stats-Analysen mit
               einem einheitlichen Listen-, Pattern- und Ausgabevertrag.
               Das ObjectInventory ergänzt capability-adaptiv sichtbare
               SQL-Server-2025-JSON-Indizes und deren SQL/JSON-Pfade.
SQL-Version  : SQL Server 2019 oder neuer.
Parameter    : @DatabaseNames, @DatabaseNamePattern, @SchemaNames,
               @SchemaNamePattern, @ObjectNames, @ObjectNamePattern,
               @FullObjectNames, @IndexNames, @IndexNamePattern,
               @StatisticsNames, @StatisticsNamePattern, Modulschalter,
               @MaxZeilen, @ResultSetArt,
               @JsonErzeugen, @Json OUTPUT, @PrintMeldungen, @Hilfe.
Semantik     : Exakte Listen sind bracket-aware Pipe-Listen; Pattern sind
               einzelne LIKE-/Regex-Ausdrücke. Exakte Liste und Pattern
               derselben Eigenschaft sind gegenseitig exklusiv.
Ausgabe      : Aktivierte Teilmodule liefern RAW oder CONSOLE. NONE unterdrückt
               fachliche Resultsets. JSON enthält die Teilmodul-Envelopes unter
               benannten Eigenschaften und einen Orchestratorstatus.
Locking      : Der angeforderte LOCK_TIMEOUT gilt für den Childlauf; der
               vorherige Sessionwert wird vor der Ausgabe wiederhergestellt.
Änderungen   : 2.4.0 - SQL25-002-JSON-Indexmetadaten über das bestehende
                         ObjectInventory in den Orchestratorvertrag aufgenommen.
               2.3.0 - SQL-Server-2025-Vector-Index-Laufzeitanalyse als
                          capability-adaptives opt-in Teilmodul integriert.
               2.2.0 - Begrenzte Statistikverteilungsanalyse als opt-in
                         Teilmodul integriert.
               2.1.0 - Schema-/Designkorrektheit als opt-in Teilmodul.
               2.0.0 - Mehrfachfilter, getrennte Pattern, Cross-Database-Scope,
                         RAW/CONSOLE/NONE und JSON-Orchestrierung.
               1.3.0 - Vorheriger Stand.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_ObjectAnalysis]
      @DatabaseNames                    nvarchar(max)  = NULL
    , @SystemdatenbankenEinbeziehen     bit            = 0
    , @DatabaseNamePattern              nvarchar(4000) = NULL
    , @HighImpactConfirmed              bit            = 0
    , @SchemaNames                      nvarchar(max)  = NULL
    , @SchemaNamePattern                nvarchar(4000) = NULL
    , @ObjectNames                      nvarchar(max)  = NULL
    , @ObjectNamePattern                nvarchar(4000) = NULL
    , @FullObjectNames                  nvarchar(max)  = NULL
    , @IndexNames                       nvarchar(max)  = NULL
    , @IndexNamePattern                 nvarchar(4000) = NULL
    , @StatisticsNames                  nvarchar(max)  = NULL
    , @StatisticsNamePattern            nvarchar(4000) = NULL
    , @Vollanalyse                      bit            = 0
    , @MitObjectInventory               bit            = 1
    , @MitIndexUsage                    bit            = 1
    , @MitMissingIndexes                bit            = 1
    , @MitOperationalStats              bit            = 0
    , @MitStatistics                    bit            = 0
    , @MitStatisticsDistribution        bit            = 0
    , @MitPartitions                    bit            = 0
    , @MitColumnstore                   bit            = 0
    , @MitPhysicalStats                 bit            = 0
    , @MitVectorIndexes                 bit            = 0
    , @MitSchemaDesign                  bit            = 0
    , @MaxZeilen                        int            = 2000
    , @LockTimeoutMs                    int            = 0
    , @ResultSetArt                     varchar(16)    = 'CONSOLE'
    , @ResultTablesJson               nvarchar(max) = NULL
    , @JsonErzeugen                     bit            = 0
    , @Json                             nvarchar(max)  = NULL OUTPUT
    , @PrintMeldungen                   bit            = 1
    , @Hilfe                            bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Json = NULL;
    DECLARE @OriginalLockTimeout int=@@LOCK_TIMEOUT;
    DECLARE @LockTimeoutSql nvarchar(64);

    DECLARE @ResultSetArtNormalisiert varchar(16) = UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt, ''))));
    DECLARE @TableResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'TABLE' THEN 1 ELSE 0 END;
    DECLARE @ConsoleResultRequested bit = CASE WHEN @ResultSetArtNormalisiert = 'CONSOLE' THEN 1 ELSE 0 END;
    DECLARE @TableTarget sysname=NULL;
    IF @TableResultRequested=0 AND NULLIF(LTRIM(RTRIM(COALESCE(@ResultTablesJson,N''))),N'') IS NOT NULL THROW 51011,N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.',1;
    IF @TableResultRequested=1 EXEC [monitor].[InternalPrepareSingleResultTable] @ResultTablesJson=@ResultTablesJson,@ResultName=N'moduleStatus',@TargetTable=@TableTarget OUTPUT,@ThrowOnError=1;
    IF @TableResultRequested = 1 OR @ConsoleResultRequested = 1 SET @ResultSetArtNormalisiert = 'NONE';
    DECLARE @AnalyseModus varchar(16) = CASE WHEN @Vollanalyse = 1 THEN 'VOLL' ELSE 'GEZIELT' END;
    DECLARE @CollectionTimeUtc datetime2(3) = SYSUTCDATETIME();
    DECLARE @StatusCode varchar(40) = 'AVAILABLE';
    DECLARE @IsPartial bit = 0;
    DECLARE @ErrorMessage nvarchar(2048) = NULL;
    DECLARE @MonitorPrintMessage nvarchar(2048);

    IF @Hilfe = 1
    BEGIN
        PRINT N'monitor.USP_ObjectAnalysis';
        PRINT N'@DatabaseNames=N''[Db1]|[Db2]''; NULL=alle; @DatabaseNamePattern separat.';
        PRINT N'@SchemaNames/@ObjectNames/@IndexNames/@StatisticsNames sind bracket-aware Pipe-Listen.';
        PRINT N'@FullObjectNames unterstützt Objekt, Schema.Objekt oder Datenbank.Schema.Objekt.';
        PRINT N'Pattern unterstützen like:, regex:, regexi: und werden nicht an Pipe getrennt.';
        PRINT N'@Vollanalyse=0 nutzt GEZIELT; ressourcenintensive Teilmodule bleiben zusätzlich gruppengeschützt.';
        PRINT N'@MitStatisticsDistribution=1 aktiviert die begrenzte, CATALOG_DEEP-geschützte Histogramm-/Partitionsverteilung.';
        PRINT N'@MitObjectInventory=1 ergänzt ab SQL Server 2025 sichtbare JSON-Indizes und SQL/JSON-Pfade; JSON-Dokumentwerte werden nicht gelesen.';
        PRINT N'@MitVectorIndexes=1 aktiviert die versionsadaptive Vector-Index-Katalog- und Wartungsanalyse; auf älteren Versionen bleibt der Childstatus explizit UNAVAILABLE_VERSION.';
        PRINT N'@ResultSetArt=CONSOLE (Default)|RAW|TABLE|NONE (case-insensitiv); @JsonErzeugen=1 erzeugt benannte Teilmodule in @Json.';
        RETURN;
    END;

    CREATE TABLE [#ObjectAnalysis_ModuleStatus]
    (
          [ModuleName] sysname NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );

    IF @MaxZeilen < 0 OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
       OR @ResultSetArtNormalisiert NOT IN ('RAW','CONSOLE','NONE')
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Ungültige Mengen-, Lock-Timeout- oder Ausgabeparameter.';
    END;

    IF @StatusCode = 'AVAILABLE'
       AND @FullObjectNames IS NOT NULL
       AND (@SchemaNames IS NOT NULL OR @ObjectNames IS NOT NULL OR @SchemaNamePattern IS NOT NULL OR @ObjectNamePattern IS NOT NULL)
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'@FullObjectNames ist zu separaten Schema-/Objektfiltern gegenseitig exklusiv.';
    END;

    IF @StatusCode='AVAILABLE'
    BEGIN
        SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@LockTimeoutMs)+N';';
        EXEC [sys].[sp_executesql] @LockTimeoutSql;
    END;

    IF @StatusCode = 'AVAILABLE'
       AND ((@SchemaNames IS NOT NULL AND @SchemaNamePattern IS NOT NULL)
         OR (@ObjectNames IS NOT NULL AND @ObjectNamePattern IS NOT NULL)
         OR (@IndexNames IS NOT NULL AND @IndexNamePattern IS NOT NULL)
         OR (@StatisticsNames IS NOT NULL AND @StatisticsNamePattern IS NOT NULL))
    BEGIN
        SET @StatusCode = 'INVALID_PARAMETER';
        SET @ErrorMessage = N'Exakte Liste und Pattern derselben Eigenschaft sind gegenseitig exklusiv.';
    END;

    DECLARE @JsonObjectInventory nvarchar(max) = NULL;
    DECLARE @JsonIndexUsage nvarchar(max) = NULL;
    DECLARE @JsonMissingIndexes nvarchar(max) = NULL;
    DECLARE @JsonOperationalStats nvarchar(max) = NULL;
    DECLARE @JsonStatistics nvarchar(max) = NULL;
    DECLARE @JsonStatisticsDistribution nvarchar(max) = NULL;
    DECLARE @JsonPartitions nvarchar(max) = NULL;
    DECLARE @JsonColumnstore nvarchar(max) = NULL;
    DECLARE @JsonPhysicalStats nvarchar(max) = NULL;
    DECLARE @JsonVectorIndexes nvarchar(max) = NULL;
    DECLARE @JsonSchemaDesign nvarchar(max) = NULL;
    DECLARE @StatisticsDistributionStatus varchar(40) = NULL;
    DECLARE @StatisticsDistributionPartial bit = NULL;
    DECLARE @StatisticsDistributionErrorNumber int = NULL;
    DECLARE @StatisticsDistributionErrorMessage nvarchar(2048) = NULL;
    DECLARE @VectorIndexStatus varchar(40) = NULL;
    DECLARE @VectorIndexPartial bit = NULL;
    DECLARE @VectorIndexErrorNumber int = NULL;
    DECLARE @VectorIndexErrorMessage nvarchar(2048) = NULL;
    DECLARE @SchemaDesignStatus varchar(40) = NULL;
    DECLARE @SchemaDesignPartial bit = NULL;
    DECLARE @SchemaDesignErrorNumber int = NULL;
    DECLARE @SchemaDesignErrorMessage nvarchar(2048) = NULL;

    IF @StatusCode = 'AVAILABLE' AND @MitObjectInventory = 1
    BEGIN TRY
        EXEC [monitor].[USP_ObjectInventory]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @AnalyseModus=@AnalyseModus,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonObjectInventory OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_ObjectInventory',COALESCE(JSON_VALUE(@JsonObjectInventory,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_ObjectInventory','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitIndexUsage = 1
    BEGIN TRY
        EXEC [monitor].[USP_IndexUsage]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @AnalyseModus=@AnalyseModus,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonIndexUsage OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_IndexUsage',COALESCE(JSON_VALUE(@JsonIndexUsage,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_IndexUsage','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitMissingIndexes = 1
    BEGIN TRY
        EXEC [monitor].[USP_MissingIndexes]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            ,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonMissingIndexes OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_MissingIndexes',COALESCE(JSON_VALUE(@JsonMissingIndexes,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_MissingIndexes','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitOperationalStats = 1
    BEGIN TRY
        EXEC [monitor].[USP_IndexOperationalStats]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @IndexNames=@IndexNames,@IndexNamePattern=@IndexNamePattern,@AnalyseModus=@AnalyseModus
            ,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonOperationalStats OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_IndexOperationalStats',COALESCE(JSON_VALUE(@JsonOperationalStats,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_IndexOperationalStats','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitStatistics = 1
    BEGIN TRY
        EXEC [monitor].[USP_Statistics]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @StatisticsNames=@StatisticsNames,@StatisticsNamePattern=@StatisticsNamePattern,@AnalyseModus=@AnalyseModus
            ,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonStatistics OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_Statistics',COALESCE(JSON_VALUE(@JsonStatistics,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_Statistics','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitStatisticsDistribution = 1
    BEGIN TRY
        EXEC [monitor].[USP_StatisticsDistributionAnalysis]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @StatisticsNames=@StatisticsNames,@StatisticsNamePattern=@StatisticsNamePattern,@AnalyseModus=@AnalyseModus
            ,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonStatisticsDistribution OUTPUT,@PrintMeldungen=@PrintMeldungen
            , @StatusCodeOut=@StatisticsDistributionStatus OUTPUT,@IsPartialOut=@StatisticsDistributionPartial OUTPUT
            , @ErrorNumberOut=@StatisticsDistributionErrorNumber OUTPUT,@ErrorMessageOut=@StatisticsDistributionErrorMessage OUTPUT;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_StatisticsDistributionAnalysis',COALESCE(@StatisticsDistributionStatus,'ERROR_HANDLED'),@StatisticsDistributionErrorNumber,@StatisticsDistributionErrorMessage);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_StatisticsDistributionAnalysis','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitPartitions = 1
    BEGIN TRY
        EXEC [monitor].[USP_Partitions]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @AnalyseModus=@AnalyseModus,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonPartitions OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_Partitions',COALESCE(JSON_VALUE(@JsonPartitions,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_Partitions','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitColumnstore = 1
    BEGIN TRY
        EXEC [monitor].[USP_Columnstore]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @AnalyseModus=@AnalyseModus,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonColumnstore OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_Columnstore',COALESCE(JSON_VALUE(@JsonColumnstore,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_Columnstore','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitPhysicalStats = 1
    BEGIN TRY
        EXEC [monitor].[USP_IndexPhysicalStats]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @IndexNames=@IndexNames,@IndexNamePattern=@IndexNamePattern,@AnalyseModus=@AnalyseModus
            ,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonPhysicalStats OUTPUT,@PrintMeldungen=@PrintMeldungen;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_IndexPhysicalStats',COALESCE(JSON_VALUE(@JsonPhysicalStats,'$.meta.statusCode'),'EXECUTED'),NULL,NULL);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_IndexPhysicalStats','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitVectorIndexes = 1
    BEGIN TRY
        EXEC [monitor].[USP_VectorIndexAnalysis]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            , @SchemaNames=@SchemaNames,@SchemaNamePattern=@SchemaNamePattern,@ObjectNames=@ObjectNames,@ObjectNamePattern=@ObjectNamePattern,@FullObjectNames=@FullObjectNames
            , @IndexNames=@IndexNames,@IndexNamePattern=@IndexNamePattern,@MaxZeilen=@MaxZeilen,@LockTimeoutMs=@LockTimeoutMs
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonVectorIndexes OUTPUT,@PrintMeldungen=@PrintMeldungen
            , @StatusCodeOut=@VectorIndexStatus OUTPUT,@IsPartialOut=@VectorIndexPartial OUTPUT
            , @ErrorNumberOut=@VectorIndexErrorNumber OUTPUT,@ErrorMessageOut=@VectorIndexErrorMessage OUTPUT;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_VectorIndexAnalysis',COALESCE(@VectorIndexStatus,'ERROR_HANDLED'),@VectorIndexErrorNumber,@VectorIndexErrorMessage);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_VectorIndexAnalysis','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF @StatusCode = 'AVAILABLE' AND @MitSchemaDesign = 1
    BEGIN TRY
        EXEC [monitor].[USP_SchemaDesignAnalysis]
              @DatabaseNames=@DatabaseNames,@SystemdatenbankenEinbeziehen=@SystemdatenbankenEinbeziehen,@DatabaseNamePattern=@DatabaseNamePattern,@HighImpactConfirmed=@HighImpactConfirmed
            ,@MaxZeilen=@MaxZeilen
            , @ResultSetArt=@ResultSetArtNormalisiert,@JsonErzeugen=@JsonErzeugen,@Json=@JsonSchemaDesign OUTPUT,@PrintMeldungen=@PrintMeldungen
            , @StatusCodeOut=@SchemaDesignStatus OUTPUT,@IsPartialOut=@SchemaDesignPartial OUTPUT
            , @ErrorNumberOut=@SchemaDesignErrorNumber OUTPUT,@ErrorMessageOut=@SchemaDesignErrorMessage OUTPUT;
        INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_SchemaDesignAnalysis',COALESCE(@SchemaDesignStatus,'ERROR_HANDLED'),@SchemaDesignErrorNumber,@SchemaDesignErrorMessage);
    END TRY BEGIN CATCH INSERT [#ObjectAnalysis_ModuleStatus] VALUES(N'USP_SchemaDesignAnalysis','ERROR_HANDLED',ERROR_NUMBER(),ERROR_MESSAGE()); SET @IsPartial=1; END CATCH;

    IF EXISTS(SELECT 1 FROM [#ObjectAnalysis_ModuleStatus]
              WHERE [StatusCode] NOT IN ('EXECUTED','AVAILABLE','AVAILABLE_WITH_FINDING','NOT_APPLICABLE','UNAVAILABLE_VERSION','UNAVAILABLE_FEATURE','NOT_ENABLED'))
    BEGIN
        SET @StatusCode = 'PARTIAL_RESULT';
        SET @IsPartial = 1;
    END
    ELSE IF EXISTS(SELECT 1 FROM [#ObjectAnalysis_ModuleStatus] WHERE [StatusCode] = 'AVAILABLE_WITH_FINDING')
        SET @StatusCode = 'AVAILABLE_WITH_FINDING';

    IF @StatusCode <> 'AVAILABLE' AND @PrintMeldungen = 1
    BEGIN
        SET @MonitorPrintMessage = FORMATMESSAGE(N'WARNUNG USP_ObjectAnalysis %s: %s',@StatusCode,COALESCE(@ErrorMessage,N'Mindestens ein Teilmodul lieferte kein vollständiges Ergebnis.'));
        RAISERROR(N'%s',10,1,@MonitorPrintMessage) WITH NOWAIT;
    END;

    SET @LockTimeoutSql=N'SET LOCK_TIMEOUT '+CONVERT(nvarchar(20),@OriginalLockTimeout)+N';';
    EXEC [sys].[sp_executesql] @LockTimeoutSql;

    IF @JsonErzeugen = 1
    BEGIN
        DECLARE @JsonMeta nvarchar(max)=(SELECT N'ObjectAnalysis' [resultName],1 [schemaVersion],@CollectionTimeUtc [generatedAtUtc],@StatusCode [statusCode],@IsPartial [isPartial],@ErrorMessage [errorMessage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @JsonModuleStatus nvarchar(max)=(SELECT * FROM [#ObjectAnalysis_ModuleStatus] ORDER BY [ModuleName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        SET @Json=CONCAT
        (
              N'{"meta":',COALESCE(@JsonMeta,N'{}')
            ,N',"moduleStatus":',COALESCE(@JsonModuleStatus,N'[]')
            ,N',"objectInventory":',COALESCE(@JsonObjectInventory,N'null')
            ,N',"indexUsage":',COALESCE(@JsonIndexUsage,N'null')
            ,N',"missingIndexes":',COALESCE(@JsonMissingIndexes,N'null')
            ,N',"indexOperationalStats":',COALESCE(@JsonOperationalStats,N'null')
            ,N',"statistics":',COALESCE(@JsonStatistics,N'null')
            ,N',"statisticsDistribution":',COALESCE(@JsonStatisticsDistribution,N'null')
            ,N',"partitions":',COALESCE(@JsonPartitions,N'null')
            ,N',"columnstore":',COALESCE(@JsonColumnstore,N'null')
            ,N',"indexPhysicalStats":',COALESCE(@JsonPhysicalStats,N'null')
            ,N',"vectorIndexAnalysis":',COALESCE(@JsonVectorIndexes,N'null')
            ,N',"schemaDesign":',COALESCE(@JsonSchemaDesign,N'null')
            ,N'}'
        );
    END;

    IF @ResultSetArtNormalisiert <> 'NONE'
    BEGIN
        IF @ResultSetArtNormalisiert = 'RAW'
            SELECT @CollectionTimeUtc [CollectionTimeUtc],N'monitor.USP_ObjectAnalysis' [ModuleName],@StatusCode [StatusCode],@IsPartial [IsPartial],@ErrorMessage [ErrorMessage];
        ELSE
            SELECT N'Objekt-/Indexanalyse' [Ergebnis],@CollectionTimeUtc [Stand_UTC],@StatusCode [Status],@IsPartial [Teilergebnis],@ErrorMessage [Hinweis];

        IF @ResultSetArtNormalisiert = 'RAW'
            SELECT * FROM [#ObjectAnalysis_ModuleStatus] ORDER BY [ModuleName];
        ELSE
            SELECT N'Teilmodulstatus' [Ergebnis],[ModuleName] [Modul],[StatusCode] [Status],[ErrorNumber] [Fehlernummer],[ErrorMessage] [Fehlermeldung] FROM [#ObjectAnalysis_ModuleStatus] ORDER BY [ModuleName];
    END;
    IF @ConsoleResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#ObjectAnalysis_ModuleStatus'
            , @ResultLabel=N'ObjectAnalysis'
            , @EmptyMessage=N'Keine fachlichen Ergebnisse';
    END;
    IF @TableResultRequested = 1
    BEGIN
        EXEC [monitor].[InternalWriteResultTable]
              @SourceTable = N'#ObjectAnalysis_ModuleStatus'
            , @TargetTable=@TableTarget
            , @ThrowOnError = 1;
    END;
END;
GO
