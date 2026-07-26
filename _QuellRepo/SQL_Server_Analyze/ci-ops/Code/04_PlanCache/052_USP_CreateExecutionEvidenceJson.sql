USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.USP_CreateExecutionEvidenceJson
Version      : 1.0.2
Stand        : 2026-07-21
Typ          : Stored Procedure
Zweck        : Erzeugt und validiert ein versioniertes Execution-Evidence-JSON
               aus Plan-XML, bereits erfassten STATISTICS IO/TIME-Meldungen und
               optional zielgerichteter Statistik-/Histogrammevidenz.
Sicherheit   : Führt niemals übergebenes SQL aus. Histogramm-, Parameter- und
               Predicatewerte werden standardmäßig DERIVED_ONLY verarbeitet.
SQL-Version  : SQL Server 2019 oder neuer.
===============================================================================
*/
CREATE OR ALTER PROCEDURE [monitor].[USP_CreateExecutionEvidenceJson]
      @PlanXml                       xml             = NULL
    , @StatisticsIoText              nvarchar(max)   = NULL
    , @StatisticsTimeText            nvarchar(max)   = NULL
    , @StatisticsLanguage            varchar(16)     = 'AUTO'
    , @StatisticsEvidenceJson        nvarchar(max)   = NULL
    , @ObjectMetadataJson            nvarchar(max)   = NULL
    , @StatistikEvidenzModus         varchar(16)     = 'PLAN_ONLY'
    , @HistogrammModus               varchar(16)     = 'NONE'
    , @MetadatenQuellenmodus         varchar(16)     = 'EVIDENCE_ONLY'
    , @QuellumgebungBestaetigt       bit             = 0
    , @EvidenzDatenschutzModus       varchar(24)     = 'DERIVED_ONLY'
    , @IdentifierDatenschutzModus    varchar(16)     = 'RAW'
    , @SensitiveDataConfirmed        bit             = 0
    , @MitPredicateHistogramMap      bit             = 1
    , @StatementId                   int             = NULL
    , @StatementOrdinal              int             = NULL
    , @SameExecutionAsPlanConfirmed  bit             = NULL
    , @CapturedAtUtc                 datetime2(3)    = NULL
    , @SourceProductVersion          nvarchar(128)   = NULL
    , @SourceCompatibilityLevel      smallint        = NULL
    , @SourceEngineEdition           int             = NULL
    , @MaxStatistiken                int             = 100
    , @MaxHistogrammSchritte         int             = 20000
    , @LockTimeoutMs                 int             = 0
    , @HighImpactConfirmed           bit             = 0
    , @AdditionalEvidenceJson        nvarchar(max)   = NULL
    , @ExistingEvidenceJson          nvarchar(max)   = NULL
    , @RawTextHandling               varchar(16)     = 'HASH_ONLY'
    , @StrictValidation              bit             = 1
    , @ResultSetArt                  varchar(16)     = 'CONSOLE'
    , @ResultTablesJson              nvarchar(max)   = NULL
    , @JsonErzeugen                  bit             = 1
    , @Json                          nvarchar(max)   = NULL OUTPUT
    , @PrintMeldungen                bit             = 1
    , @Hilfe                         bit             = 0
    , @StatusCodeOut                 varchar(40)     = NULL OUTPUT
    , @IsPartialOut                  bit             = NULL OUTPUT
    , @ErrorNumberOut                int             = NULL OUTPUT
    , @ErrorMessageOut               nvarchar(2048)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 0;
    SET @Json=NULL;

    DECLARE @OutputMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@ResultSetArt,''))));
    DECLARE @ConsoleResultRequested bit=CONVERT(bit,CASE WHEN @OutputMode='CONSOLE' THEN 1 ELSE 0 END);
    DECLARE @TableRequested bit=CONVERT(bit,CASE WHEN @OutputMode='TABLE' THEN 1 ELSE 0 END);
    DECLARE @StatisticsMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@StatistikEvidenzModus,'PLAN_ONLY'))));
    DECLARE @HistogramMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@HistogrammModus,'NONE'))));
    DECLARE @MetadataSourceMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@MetadatenQuellenmodus,'EVIDENCE_ONLY'))));
    DECLARE @PrivacyMode varchar(24)=UPPER(LTRIM(RTRIM(COALESCE(@EvidenzDatenschutzModus,'DERIVED_ONLY'))));
    DECLARE @IdentifierMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@IdentifierDatenschutzModus,'RAW'))));
    DECLARE @RawMode varchar(16)=UPPER(LTRIM(RTRIM(COALESCE(@RawTextHandling,'HASH_ONLY'))));
    DECLARE @GeneratedAtUtc datetime2(3)=COALESCE(@CapturedAtUtc,SYSUTCDATETIME());
    DECLARE @TokenSalt varbinary(32)=CRYPT_GEN_RANDOM(32);
    DECLARE @SameExecutionConfidence varchar(40)=CASE
        WHEN @SameExecutionAsPlanConfirmed=1 THEN 'CONFIRMED'
        WHEN @SameExecutionAsPlanConfirmed=0 THEN 'UNCONFIRMED'
        ELSE 'UNCONFIRMED' END;

    SELECT @StatusCodeOut='AVAILABLE',@IsPartialOut=0,@ErrorNumberOut=NULL,@ErrorMessageOut=NULL;

    IF @Hilfe=1
    BEGIN
        PRINT N'monitor.USP_CreateExecutionEvidenceJson';
        PRINT N'Erzeugt Evidence JSON aus optionalem PlanXml, STATISTICS IO/TIME und zielgerichteten Statistikmetadaten; führt kein SQL aus.';
        PRINT N'@StatistikEvidenzModus NONE|PLAN_ONLY|USED|RELEVANT|OBJECT_ALL; aktuelle Metadaten benötigen CURRENT_SERVER und bestätigte Quellumgebung.';
        PRINT N'@HistogrammModus NONE|SUMMARY|STEPS. @EvidenzDatenschutzModus DERIVED_ONLY (Default)|TOKENIZED|STRUCTURE_ONLY|RAW.';
        PRINT N'RAW benötigt @SensitiveDataConfirmed=1. @IdentifierDatenschutzModus RAW|TOKENIZED|OMIT.';
        PRINT N'@RawTextHandling NONE|HASH_ONLY|INCLUDE. INCLUDE benötigt @SensitiveDataConfirmed=1 und @IdentifierDatenschutzModus=RAW.';
        PRINT N'Der Generator führt die analysierte Query niemals selbst aus.';
        RETURN;
    END;

    CREATE TABLE [#CreateExecutionEvidenceJson_TableMap]
    (
          [ResultName] sysname NOT NULL
        , [TargetTable] sysname NOT NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_CaptureStatus]
    (
          [ModuleName] sysname NOT NULL
        , [GeneratedAtUtc] datetime2(3) NOT NULL
        , [StatusCode] varchar(40) NOT NULL
        , [IsPartial] bit NOT NULL
        , [SchemaVersion] int NOT NULL
        , [StatisticsIoRowCount] bigint NOT NULL
        , [StatisticsTimeRowCount] bigint NOT NULL
        , [PlanStatisticsUsageCount] bigint NOT NULL
        , [CurrentStatisticsCount] bigint NOT NULL
        , [HistogramStepCount] bigint NOT NULL
        , [PredicateMappingCount] bigint NOT NULL
        , [EvidencePrivacyMode] varchar(24) NOT NULL
        , [IdentifierPrivacyMode] varchar(16) NOT NULL
        , [SameExecutionConfidence] varchar(40) NOT NULL
        , [ErrorNumber] int NULL
        , [ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_StatisticsIo]
    (
          [StatementOrdinal] int NULL,[MessageOrdinal] int NOT NULL,[ObjectOrdinal] int NOT NULL
        , [ObjectDisplayName] nvarchar(512) NULL,[ScanCount] bigint NULL,[LogicalReads] bigint NULL
        , [PhysicalReads] bigint NULL,[PageServerReads] bigint NULL,[ReadAheadReads] bigint NULL
        , [PageServerReadAheadReads] bigint NULL,[LobLogicalReads] bigint NULL,[LobPhysicalReads] bigint NULL
        , [LobPageServerReads] bigint NULL,[LobReadAheadReads] bigint NULL,[LobPageServerReadAheadReads] bigint NULL
        , [LanguageDetected] varchar(16) NOT NULL,[ParseStatus] varchar(40) NOT NULL,[RawLine] nvarchar(4000) NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_StatisticsTime]
    (
          [StatementOrdinal] int NULL,[MessageOrdinal] int NOT NULL,[TimeCategory] varchar(24) NOT NULL
        , [CpuMs] bigint NULL,[ElapsedMs] bigint NULL,[LanguageDetected] varchar(16) NOT NULL
        , [ParseStatus] varchar(40) NOT NULL,[RawLine] nvarchar(4000) NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_PlanStatisticsUsage]
    (
          [StatisticsUsageOrdinal] bigint NOT NULL,[StatementOrdinal] int NOT NULL
        , [StatementId] int NULL,[StatementCompId] int NULL
        , [DatabaseName] sysname NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL,[StatisticsName] sysname NULL
        , [LastUpdateAtCompile] datetime2(7) NULL,[ModificationCountAtCompile] bigint NULL
        , [SamplingPercentAtCompile] decimal(19,6) NULL,[SourceElement] nvarchar(128) NOT NULL,[ParseStatus] varchar(40) NOT NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_ObjectReferences]
    (
          [ReferenceOrdinal] bigint NOT NULL,[StatementOrdinal] int NOT NULL,[StatementId] int NULL,[StatementCompId] int NULL
        , [NodeId] int NULL,[ReferenceType] varchar(40) NOT NULL,[ReferenceSource] varchar(40) NOT NULL
        , [DatabaseName] sysname NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL,[IndexName] sysname NULL
        , [AliasName] sysname NULL,[StorageType] nvarchar(128) NULL,[PlanObjectId] int NULL,[PlanIndexId] int NULL
        , [IsTemporaryObject] bit NOT NULL,[IsTableVariable] bit NOT NULL,[IsRemoteObject] bit NOT NULL,[IsDmlTarget] bit NOT NULL
        , [ResolutionCapability] varchar(40) NOT NULL,[SourceElement] nvarchar(128) NOT NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_StatisticsCurrent]
    (
          [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL,[ObjectId] int NOT NULL
        , [StatisticsName] sysname NOT NULL,[StatisticsId] int NOT NULL,[IsIndexStatistics] bit NOT NULL
        , [IsAutoCreated] bit NULL,[IsUserCreated] bit NULL,[IsFiltered] bit NULL,[FilterDefinition] nvarchar(max) NULL
        , [NoRecompute] bit NULL,[IsIncremental] bit NULL,[HasPersistedSample] bit NULL,[LeadingColumnName] sysname NULL
        , [LastUpdated] datetime2(7) NULL,[Rows] bigint NULL,[RowsSampled] bigint NULL,[SamplePercent] decimal(19,6) NULL
        , [Steps] int NULL,[UnfilteredRows] bigint NULL,[ModificationCounter] bigint NULL,[ModificationPercent] decimal(19,6) NULL
        , [PersistedSamplePercent] float NULL,[CollectionStatus] varchar(40) NOT NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_HistogramSteps]
    (
          [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL
        , [StatisticsName] sysname NOT NULL,[StatisticsId] int NOT NULL,[LeadingColumnName] sysname NULL
        , [StepOrdinal] int NOT NULL,[RangeHighKeyRaw] nvarchar(4000) NULL
        , [RangeRows] float NULL,[EqualRows] float NULL,[DistinctRangeRows] bigint NULL,[AverageRangeRows] float NULL
        , [IsPredicateTarget] bit NULL,[PredicateMatchCount] int NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_HistogramSummary]
    (
          [DatabaseName] sysname NOT NULL,[SchemaName] sysname NOT NULL,[ObjectName] sysname NOT NULL
        , [StatisticsName] sysname NOT NULL,[StatisticsId] int NOT NULL,[LeadingColumnName] sysname NULL
        , [HistogramSteps] int NOT NULL,[HistogramEstimatedRows] float NULL,[MaxEqualRows] float NULL
        , [MaxRangeRows] float NULL,[MaxStepRows] float NULL,[DominantStepPercent] decimal(19,6) NULL
        , [TailStepRows] float NULL,[TailStepPercent] decimal(19,6) NULL,[CollectionStatus] varchar(40) NOT NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_PredicateHistogramMappings]
    (
          [PredicateReferenceId] bigint NOT NULL,[StatementOrdinal] int NOT NULL,[NodeId] int NULL
        , [DatabaseName] sysname NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL,[ColumnName] sysname NULL
        , [StatisticsName] sysname NULL,[PredicateKind] varchar(40) NULL,[ValueSource] varchar(32) NOT NULL
        , [MappingStatus] varchar(48) NOT NULL,[MappingConfidence] varchar(16) NOT NULL,[MatchedStepOrdinal] int NULL
        , [MatchesRangeHighKey] bit NOT NULL,[IsBelowHistogram] bit NOT NULL,[IsAboveHistogram] bit NOT NULL
        , [SensitiveValueStatus] varchar(40) NOT NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_CollectionStatus]
    (
          [DatabaseName] sysname NULL,[SchemaName] sysname NULL,[ObjectName] sysname NULL,[StatisticsName] sysname NULL
        , [StatusCode] varchar(40) NOT NULL,[ErrorNumber] int NULL,[ErrorMessage] nvarchar(2048) NULL
    );
    CREATE TABLE [#CreateExecutionEvidenceJson_Warnings]
    (
          [WarningCode] varchar(80) NOT NULL
        , [Severity] varchar(16) NOT NULL
        , [Detail] nvarchar(2048) NOT NULL
    );

    IF @OutputMode NOT IN ('CONSOLE','RAW','TABLE','NONE')
       OR @StatisticsMode NOT IN ('NONE','PLAN_ONLY','USED','RELEVANT','OBJECT_ALL')
       OR @HistogramMode NOT IN ('NONE','SUMMARY','STEPS')
       OR @MetadataSourceMode NOT IN ('EVIDENCE_ONLY','CURRENT_SERVER')
       OR @PrivacyMode NOT IN ('DERIVED_ONLY','TOKENIZED','RAW','STRUCTURE_ONLY')
       OR @IdentifierMode NOT IN ('RAW','TOKENIZED','OMIT')
       OR @RawMode NOT IN ('NONE','HASH_ONLY','INCLUDE')
       OR @StrictValidation NOT IN (0,1) OR @JsonErzeugen NOT IN (0,1)
       OR @MitPredicateHistogramMap NOT IN (0,1)
       OR @MaxStatistiken IS NULL OR @MaxStatistiken NOT BETWEEN 1 AND 1000
       OR @MaxHistogrammSchritte IS NULL OR @MaxHistogrammSchritte NOT BETWEEN 0 AND 200000
       OR @LockTimeoutMs IS NULL OR @LockTimeoutMs NOT BETWEEN 0 AND 60000
       OR @HighImpactConfirmed NOT IN (0,1)
       OR @SourceCompatibilityLevel IS NOT NULL AND @SourceCompatibilityLevel NOT BETWEEN 80 AND 200
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Ungültiger Modus-, Grenzwert-, Ausgabe-, Datenschutz- oder Versionsparameter.';
    END;

    IF @StatusCodeOut='AVAILABLE' AND @PrivacyMode='RAW' AND @SensitiveDataConfirmed<>1
    BEGIN
        SELECT @StatusCodeOut='SENSITIVE_DATA_CONFIRMATION_REQUIRED',@IsPartialOut=1,
               @ErrorMessageOut=N'RAW-Evidenz kann Parameter-, Predicate-, Filter- oder Histogrammwerte enthalten und benötigt @SensitiveDataConfirmed=1.';
    END;

    IF @StatusCodeOut='AVAILABLE'
       AND @RawMode='INCLUDE'
       AND (@SensitiveDataConfirmed<>1 OR @IdentifierMode<>'RAW')
    BEGIN
        SELECT @StatusCodeOut='SENSITIVE_DATA_CONFIRMATION_REQUIRED',@IsPartialOut=1,
               @ErrorMessageOut=N'Rohtext kann sensible Werte und nicht zuverlässig einzeln anonymisierbare Identifikatoren enthalten. INCLUDE benötigt @SensitiveDataConfirmed=1 und @IdentifierDatenschutzModus=RAW.';
    END;

    IF @StatusCodeOut='AVAILABLE'
       AND @MetadataSourceMode='CURRENT_SERVER'
       AND @QuellumgebungBestaetigt<>1
    BEGIN
        SELECT @StatusCodeOut='SOURCE_ENVIRONMENT_CONFIRMATION_REQUIRED',@IsPartialOut=1,
               @ErrorMessageOut=N'CURRENT_SERVER-Anreicherung benötigt @QuellumgebungBestaetigt=1.';
    END;

    IF @StatusCodeOut='AVAILABLE'
       AND @HistogramMode<>'NONE'
       AND (@MetadataSourceMode<>'CURRENT_SERVER' OR @StatisticsMode IN ('NONE','PLAN_ONLY'))
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'Histogramme benötigen CURRENT_SERVER und Statistikmodus USED, RELEVANT oder OBJECT_ALL.';
    END;

    IF @StatusCodeOut='AVAILABLE' AND @TableRequested=1
    BEGIN
        EXEC [monitor].[InternalPrepareResultTables]
              @ResultTablesJson=@ResultTablesJson
            , @AllowedResultNames=N'captureStatus|statisticsIo|statisticsTime|planStatisticsUsage|objectReferences|currentStatistics|histogramSummaries|histogramSteps|predicateHistogramMappings|collectionStatus|warnings'
            , @MappingTable=N'#CreateExecutionEvidenceJson_TableMap'
            , @ThrowOnError=1;
        SET @OutputMode='NONE';
    END
    ELSE IF @StatusCodeOut='AVAILABLE' AND @ResultTablesJson IS NOT NULL
    BEGIN
        SELECT @StatusCodeOut='INVALID_PARAMETER',@IsPartialOut=1,
               @ErrorMessageOut=N'@ResultTablesJson ist ausschließlich mit @ResultSetArt=TABLE zulässig.';
    END;
    IF @ConsoleResultRequested=1 SET @OutputMode='NONE';

    IF @StatusCodeOut='AVAILABLE'
    BEGIN TRY
        INSERT [#CreateExecutionEvidenceJson_StatisticsIo]
        SELECT * FROM [monitor].[TVF_ParseStatisticsIoText](@StatisticsIoText,@StatisticsLanguage);

        INSERT [#CreateExecutionEvidenceJson_StatisticsTime]
        SELECT * FROM [monitor].[TVF_ParseStatisticsTimeText](@StatisticsTimeText,@StatisticsLanguage);

        DECLARE @PlanStatementCount int=0;
        IF @PlanXml IS NOT NULL
        BEGIN
            SELECT @PlanStatementCount=COUNT(*)
            FROM @PlanXml.nodes('//*[local-name(.)="StmtSimple"]') AS [s]([n]);

            IF @StatementOrdinal IS NOT NULL
            BEGIN
                UPDATE [#CreateExecutionEvidenceJson_StatisticsIo] SET [StatementOrdinal]=@StatementOrdinal WHERE [StatementOrdinal] IS NULL;
                UPDATE [#CreateExecutionEvidenceJson_StatisticsTime] SET [StatementOrdinal]=@StatementOrdinal WHERE [StatementOrdinal] IS NULL;
            END
            ELSE IF @PlanStatementCount=1
            BEGIN
                UPDATE [#CreateExecutionEvidenceJson_StatisticsIo] SET [StatementOrdinal]=1 WHERE [StatementOrdinal] IS NULL;
                UPDATE [#CreateExecutionEvidenceJson_StatisticsTime] SET [StatementOrdinal]=1 WHERE [StatementOrdinal] IS NULL;
            END
            ELSE IF @PlanStatementCount>1 AND (EXISTS(SELECT 1 FROM [#CreateExecutionEvidenceJson_StatisticsIo]) OR EXISTS(SELECT 1 FROM [#CreateExecutionEvidenceJson_StatisticsTime]))
            BEGIN
                INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('AMBIGUOUS_STATEMENT_MAPPING','MEDIUM',N'STATISTICS IO/TIME wurde für einen Mehrstatementplan ohne explizite @StatementOrdinal übergeben. Die Werte bleiben planbezogen.');
                SET @IsPartialOut=1;
            END;

            IF @StatisticsMode<>'NONE'
            BEGIN
                INSERT [#CreateExecutionEvidenceJson_PlanStatisticsUsage]
                SELECT * FROM [monitor].[TVF_ExecutionPlanStatisticsUsage](@PlanXml,@StatementId);
            END;

            INSERT [#CreateExecutionEvidenceJson_ObjectReferences]
            SELECT * FROM [monitor].[TVF_ExecutionPlanObjectReferences](@PlanXml,@StatementId);
        END;

        IF @StatisticsEvidenceJson IS NOT NULL AND ISJSON(@StatisticsEvidenceJson)<>1
        BEGIN
            IF @StrictValidation=1 THROW 51021,N'@StatisticsEvidenceJson ist kein gültiges JSON.',1;
            INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('INVALID_STATISTICS_EVIDENCE_JSON','MEDIUM',N'Externes Statistik-Evidenz-JSON wurde verworfen.');
            SET @IsPartialOut=1;
        END;
        IF @ObjectMetadataJson IS NOT NULL AND ISJSON(@ObjectMetadataJson)<>1
        BEGIN
            IF @StrictValidation=1 THROW 51022,N'@ObjectMetadataJson ist kein gültiges JSON.',1;
            INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('INVALID_OBJECT_METADATA_JSON','MEDIUM',N'Externes Objektmetadaten-JSON wurde verworfen.');
            SET @IsPartialOut=1;
        END;
        IF @AdditionalEvidenceJson IS NOT NULL AND ISJSON(@AdditionalEvidenceJson)<>1
        BEGIN
            IF @StrictValidation=1 THROW 51023,N'@AdditionalEvidenceJson ist kein gültiges JSON.',1;
            INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('INVALID_ADDITIONAL_EVIDENCE_JSON','MEDIUM',N'Zusätzliche Evidenz wurde verworfen.');
            SET @IsPartialOut=1;
        END;
        IF @ExistingEvidenceJson IS NOT NULL AND ISJSON(@ExistingEvidenceJson)<>1
        BEGIN
            IF @StrictValidation=1 THROW 51024,N'@ExistingEvidenceJson ist kein gültiges JSON.',1;
            INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('INVALID_EXISTING_EVIDENCE_JSON','MEDIUM',N'Bestehende Evidenz wurde verworfen.');
            SET @IsPartialOut=1;
        END;

        /* Separate Statistik- und Objektpayloads werden in eine kanonische
           Evidence-Hülle überführt. Explizit übergebene Teilpayloads haben
           Vorrang vor gleichnamigen Abschnitten aus @ExistingEvidenceJson. */
        DECLARE @CanonicalEvidenceJson nvarchar(max)=
            CASE WHEN @ExistingEvidenceJson IS NOT NULL AND ISJSON(@ExistingEvidenceJson)=1
                 THEN @ExistingEvidenceJson ELSE N'{}' END;

        IF @StatisticsEvidenceJson IS NOT NULL AND ISJSON(@StatisticsEvidenceJson)=1
        BEGIN
            DECLARE @StatisticsSection nvarchar(max)=JSON_QUERY(@StatisticsEvidenceJson,N'$.statistics');
            IF @StatisticsSection IS NULL AND LEFT(LTRIM(@StatisticsEvidenceJson),1)=N'{'
                SET @StatisticsSection=JSON_QUERY(@StatisticsEvidenceJson);
            IF @StatisticsSection IS NULL
            BEGIN
                IF @StrictValidation=1 THROW 51021,N'@StatisticsEvidenceJson muss ein JSON-Objekt mit Statistikabschnitten enthalten.',1;
                INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('INVALID_STATISTICS_EVIDENCE_SHAPE','MEDIUM',N'Externes Statistik-Evidenz-JSON besitzt keine unterstützte Objektstruktur.');
                SET @IsPartialOut=1;
            END
            ELSE
                SET @CanonicalEvidenceJson=JSON_MODIFY(@CanonicalEvidenceJson,N'$.statistics',JSON_QUERY(@StatisticsSection));
        END;

        IF @ObjectMetadataJson IS NOT NULL AND ISJSON(@ObjectMetadataJson)=1
        BEGIN
            DECLARE @ObjectSection nvarchar(max)=JSON_QUERY(@ObjectMetadataJson,N'$.objectReferences');
            IF @ObjectSection IS NULL AND LEFT(LTRIM(@ObjectMetadataJson),1)=N'['
                SET @ObjectSection=JSON_QUERY(@ObjectMetadataJson);
            IF @ObjectSection IS NULL
            BEGIN
                IF @StrictValidation=1 THROW 51022,N'@ObjectMetadataJson muss ein JSON-Array oder objectReferences enthalten.',1;
                INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('INVALID_OBJECT_METADATA_SHAPE','MEDIUM',N'Externes Objektmetadaten-JSON besitzt keine unterstützte Arraystruktur.');
                SET @IsPartialOut=1;
            END
            ELSE
                SET @CanonicalEvidenceJson=JSON_MODIFY(@CanonicalEvidenceJson,N'$.objectReferences',JSON_QUERY(@ObjectSection));
        END;

        /* Bestehende kanonische Evidenz wird strukturell zusammengeführt. Plan-
           referenzen werden bei vorhandenem @PlanXml neu und damit eindeutiger
           aufgebaut; bereits erfasste IO-/TIME-Werte bleiben erhalten. */
        IF ISJSON(@CanonicalEvidenceJson)=1
        BEGIN
            INSERT [#CreateExecutionEvidenceJson_StatisticsIo]
            SELECT [StatementOrdinal],[MessageOrdinal],[ObjectOrdinal],[ObjectDisplayName],
                   [ScanCount],[LogicalReads],[PhysicalReads],[PageServerReads],[ReadAheadReads],
                   [PageServerReadAheadReads],[LobLogicalReads],[LobPhysicalReads],[LobPageServerReads],
                   [LobReadAheadReads],[LobPageServerReadAheadReads],[LanguageDetected],[ParseStatus],NULL
            FROM OPENJSON(@CanonicalEvidenceJson,N'$.statisticsIo')
            WITH
            (
                  [StatementOrdinal] int N'$.statementOrdinal',[MessageOrdinal] int N'$.messageOrdinal'
                , [ObjectOrdinal] int N'$.objectOrdinal',[ObjectDisplayName] nvarchar(512) N'$.objectDisplayName'
                , [ScanCount] bigint N'$.scanCount',[LogicalReads] bigint N'$.logicalReads'
                , [PhysicalReads] bigint N'$.physicalReads',[PageServerReads] bigint N'$.pageServerReads'
                , [ReadAheadReads] bigint N'$.readAheadReads',[PageServerReadAheadReads] bigint N'$.pageServerReadAheadReads'
                , [LobLogicalReads] bigint N'$.lobLogicalReads',[LobPhysicalReads] bigint N'$.lobPhysicalReads'
                , [LobPageServerReads] bigint N'$.lobPageServerReads',[LobReadAheadReads] bigint N'$.lobReadAheadReads'
                , [LobPageServerReadAheadReads] bigint N'$.lobPageServerReadAheadReads'
                , [LanguageDetected] varchar(16) N'$.languageDetected',[ParseStatus] varchar(40) N'$.parseStatus'
            );

            INSERT [#CreateExecutionEvidenceJson_StatisticsTime]
            SELECT [StatementOrdinal],[MessageOrdinal],[TimeCategory],[CpuMs],[ElapsedMs],[LanguageDetected],[ParseStatus],NULL
            FROM OPENJSON(@CanonicalEvidenceJson,N'$.statisticsTime')
            WITH
            (
                  [StatementOrdinal] int N'$.statementOrdinal',[MessageOrdinal] int N'$.messageOrdinal'
                , [TimeCategory] varchar(24) N'$.timeCategory',[CpuMs] bigint N'$.cpuMs'
                , [ElapsedMs] bigint N'$.elapsedMs',[LanguageDetected] varchar(16) N'$.languageDetected'
                , [ParseStatus] varchar(40) N'$.parseStatus'
            );

            IF @PlanXml IS NULL
            BEGIN
                INSERT [#CreateExecutionEvidenceJson_PlanStatisticsUsage]
                SELECT [StatisticsUsageOrdinal],[StatementOrdinal],[StatementId],[StatementCompId],
                       [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],[LastUpdateAtCompile],
                       [ModificationCountAtCompile],[SamplingPercentAtCompile],[SourceElement],[ParseStatus]
                FROM OPENJSON(@CanonicalEvidenceJson,N'$.statistics.planUsage')
                WITH
                (
                      [StatisticsUsageOrdinal] bigint N'$.statisticsUsageOrdinal',[StatementOrdinal] int N'$.statementOrdinal'
                    , [StatementId] int N'$.statementId',[StatementCompId] int N'$.statementCompId'
                    , [DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
                    , [ObjectName] sysname N'$.objectName',[StatisticsName] sysname N'$.statisticsName'
                    , [LastUpdateAtCompile] datetime2(7) N'$.lastUpdateAtCompile'
                    , [ModificationCountAtCompile] bigint N'$.modificationCountAtCompile'
                    , [SamplingPercentAtCompile] decimal(19,6) N'$.samplingPercentAtCompile'
                    , [SourceElement] nvarchar(128) N'$.sourceElement',[ParseStatus] varchar(40) N'$.parseStatus'
                );
          

                INSERT [#CreateExecutionEvidenceJson_ObjectReferences]
                SELECT [ReferenceOrdinal],[StatementOrdinal],[StatementId],[StatementCompId],[NodeId],
                       [ReferenceType],[ReferenceSource],[DatabaseName],[SchemaName],[ObjectName],[IndexName],
                       [AliasName],[StorageType],[PlanObjectId],[PlanIndexId],[IsTemporaryObject],
                       [IsTableVariable],[IsRemoteObject],[IsDmlTarget],[ResolutionCapability],[SourceElement]
                FROM OPENJSON(@CanonicalEvidenceJson,N'$.objectReferences')
                WITH
                (
                      [ReferenceOrdinal] bigint N'$.referenceOrdinal',[StatementOrdinal] int N'$.statementOrdinal'
                    , [StatementId] int N'$.statementId',[StatementCompId] int N'$.statementCompId',[NodeId] int N'$.nodeId'
                    , [ReferenceType] varchar(40) N'$.referenceType',[ReferenceSource] varchar(40) N'$.referenceSource'
                    , [DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
                    , [ObjectName] sysname N'$.objectName',[IndexName] sysname N'$.indexName'
                    , [AliasName] sysname N'$.aliasName',[StorageType] nvarchar(128) N'$.storageType'
                    , [PlanObjectId] int N'$.planObjectId',[PlanIndexId] int N'$.planIndexId'
                    , [IsTemporaryObject] bit N'$.isTemporaryObject',[IsTableVariable] bit N'$.isTableVariable'
                    , [IsRemoteObject] bit N'$.isRemoteObject',[IsDmlTarget] bit N'$.isDmlTarget'
                    , [ResolutionCapability] varchar(40) N'$.resolutionCapability',[SourceElement] nvarchar(128) N'$.sourceElement'
                );
            END;

            IF @MetadataSourceMode<>'CURRENT_SERVER'
            BEGIN
                INSERT [#CreateExecutionEvidenceJson_StatisticsCurrent]
                SELECT *
                FROM OPENJSON(@CanonicalEvidenceJson,N'$.statistics.currentSnapshot')
                WITH
                (
                      [DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
                    , [ObjectName] sysname N'$.objectName',[ObjectId] int N'$.objectId'
                    , [StatisticsName] sysname N'$.statisticsName',[StatisticsId] int N'$.statisticsId'
                    , [IsIndexStatistics] bit N'$.isIndexStatistics',[IsAutoCreated] bit N'$.isAutoCreated'
                    , [IsUserCreated] bit N'$.isUserCreated',[IsFiltered] bit N'$.isFiltered'
                    , [FilterDefinition] nvarchar(max) N'$.filterDefinition',[NoRecompute] bit N'$.noRecompute'
                    , [IsIncremental] bit N'$.isIncremental',[HasPersistedSample] bit N'$.hasPersistedSample'
                    , [LeadingColumnName] sysname N'$.leadingColumnName',[LastUpdated] datetime2(7) N'$.lastUpdated'
                    , [Rows] bigint N'$.rows',[RowsSampled] bigint N'$.rowsSampled'
                    , [SamplePercent] decimal(19,6) N'$.samplePercent',[Steps] int N'$.steps'
                    , [UnfilteredRows] bigint N'$.unfilteredRows',[ModificationCounter] bigint N'$.modificationCounter'
                    , [ModificationPercent] decimal(19,6) N'$.modificationPercent'
                    , [PersistedSamplePercent] float N'$.persistedSamplePercent',[CollectionStatus] varchar(40) N'$.collectionStatus'
                );

                INSERT [#CreateExecutionEvidenceJson_HistogramSummary]
                SELECT *
                FROM OPENJSON(@CanonicalEvidenceJson,N'$.statistics.histogramSummaries')
                WITH
                (
                      [DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
                    , [ObjectName] sysname N'$.objectName',[StatisticsName] sysname N'$.statisticsName'
                    , [StatisticsId] int N'$.statisticsId',[LeadingColumnName] sysname N'$.leadingColumnName'
                    , [HistogramSteps] int N'$.histogramSteps',[HistogramEstimatedRows] float N'$.histogramEstimatedRows'
                    , [MaxEqualRows] float N'$.maxEqualRows',[MaxRangeRows] float N'$.maxRangeRows'
                    , [MaxStepRows] float N'$.maxStepRows',[DominantStepPercent] decimal(19,6) N'$.dominantStepPercent'
                    , [TailStepRows] float N'$.tailStepRows',[TailStepPercent] decimal(19,6) N'$.tailStepPercent'
                    , [CollectionStatus] varchar(40) N'$.collectionStatus'
                );

                INSERT [#CreateExecutionEvidenceJson_HistogramSteps]
                SELECT [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],[StatisticsId],[LeadingColumnName],
                       [StepOrdinal],CASE WHEN @PrivacyMode IN ('RAW','TOKENIZED') THEN [RangeHighKey] END,[RangeRows],[EqualRows],
                       [DistinctRangeRows],[AverageRangeRows],[IsPredicateTarget],[PredicateMatchCount]
                FROM OPENJSON(@CanonicalEvidenceJson,N'$.statistics.histogramSteps')
                WITH
                (
                      [DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
                    , [ObjectName] sysname N'$.objectName',[StatisticsName] sysname N'$.statisticsName'
                    , [StatisticsId] int N'$.statisticsId',[LeadingColumnName] sysname N'$.leadingColumnName'
                    , [StepOrdinal] int N'$.stepOrdinal',[RangeHighKey] nvarchar(4000) N'$.rangeHighKey'
                    , [RangeRows] float N'$.rangeRows',[EqualRows] float N'$.equalRows'
                    , [DistinctRangeRows] bigint N'$.distinctRangeRows',[AverageRangeRows] float N'$.averageRangeRows'
                    , [IsPredicateTarget] bit N'$.isPredicateTarget',[PredicateMatchCount] int N'$.predicateMatchCount'
                );

                INSERT [#CreateExecutionEvidenceJson_PredicateHistogramMappings]
                SELECT [PredicateReferenceId],[StatementOrdinal],[NodeId],[DatabaseName],[SchemaName],[ObjectName],
                       [ColumnName],[StatisticsName],[PredicateKind],[ValueSource],[MappingStatus],[MappingConfidence],
                       [MatchedStepOrdinal],COALESCE([MatchesRangeHighKey],0),COALESCE([IsBelowHistogram],0),
                       COALESCE([IsAboveHistogram],0),COALESCE([SensitiveValueStatus],'IMPORTED_DERIVED')
                FROM OPENJSON(@CanonicalEvidenceJson,N'$.predicateHistogramMappings')
                WITH
                (
                      [PredicateReferenceId] bigint N'$.predicateReferenceId',[StatementOrdinal] int N'$.statementOrdinal'
                    , [NodeId] int N'$.nodeId',[DatabaseName] sysname N'$.databaseName',[SchemaName] sysname N'$.schemaName'
                    , [ObjectName] sysname N'$.objectName',[ColumnName] sysname N'$.columnName'
                    , [StatisticsName] sysname N'$.statisticsName',[PredicateKind] varchar(40) N'$.predicateKind'
                    , [ValueSource] varchar(32) N'$.valueSource',[MappingStatus] varchar(48) N'$.mappingStatus'
                    , [MappingConfidence] varchar(16) N'$.mappingConfidence',[MatchedStepOrdinal] int N'$.matchedStepOrdinal'
                    , [MatchesRangeHighKey] bit N'$.matchesRangeHighKey',[IsBelowHistogram] bit N'$.isBelowHistogram'
                    , [IsAboveHistogram] bit N'$.isAboveHistogram',[SensitiveValueStatus] varchar(40) N'$.sensitiveValueStatus'
                );
            END;
        END;

        IF @PlanXml IS NOT NULL
           AND @MetadataSourceMode='CURRENT_SERVER'
           AND @StatisticsMode IN ('USED','RELEVANT','OBJECT_ALL')
        BEGIN
            DECLARE @CollectionStatus varchar(40),@CollectionPartial bit,@CollectionError int,@CollectionMessage nvarchar(2048);
            EXEC [monitor].[InternalCollectExecutionPlanMetadata]
                  @PlanXml=@PlanXml
                , @StatistikEvidenzModus=@StatisticsMode
                , @HistogrammModus=@HistogramMode
                , @QuellumgebungBestaetigt=@QuellumgebungBestaetigt
                , @MitPredicateHistogramMap=@MitPredicateHistogramMap
                , @MaxStatistiken=@MaxStatistiken
                , @MaxHistogrammSchritte=@MaxHistogrammSchritte
                , @LockTimeoutMs=@LockTimeoutMs
                , @HighImpactConfirmed=@HighImpactConfirmed
                , @StatusCodeOut=@CollectionStatus OUTPUT
                , @IsPartialOut=@CollectionPartial OUTPUT
                , @ErrorNumberOut=@CollectionError OUTPUT
                , @ErrorMessageOut=@CollectionMessage OUTPUT;

            IF @CollectionStatus<>'AVAILABLE'
            BEGIN
                SET @IsPartialOut=1;
                INSERT [#CreateExecutionEvidenceJson_Warnings]
                VALUES('CURRENT_METADATA_COLLECTION_LIMITED','MEDIUM',CONCAT(N'Status=',COALESCE(@CollectionStatus,N'<NULL>'),N'; ',COALESCE(@CollectionMessage,N'')));
            END;
        END;

        UPDATE [h]
        SET [h].[IsPredicateTarget]=CONVERT(bit,CASE WHEN [m].[PredicateMatchCount]>0 THEN 1 ELSE 0 END),
            [h].[PredicateMatchCount]=COALESCE([m].[PredicateMatchCount],0)
        FROM [#CreateExecutionEvidenceJson_HistogramSteps] AS [h]
        OUTER APPLY
        (
            SELECT COUNT(*) [PredicateMatchCount]
            FROM [#CreateExecutionEvidenceJson_PredicateHistogramMappings] AS [p]
            WHERE [p].[DatabaseName]=[h].[DatabaseName]
              AND [p].[SchemaName]=[h].[SchemaName]
              AND [p].[ObjectName]=[h].[ObjectName]
              AND [p].[StatisticsName]=[h].[StatisticsName]
              AND [p].[MatchedStepOrdinal]=[h].[StepOrdinal]
        ) AS [m];

        IF @RawMode<>'INCLUDE'
        BEGIN
            UPDATE [#CreateExecutionEvidenceJson_StatisticsIo] SET [RawLine]=NULL;
            UPDATE [#CreateExecutionEvidenceJson_StatisticsTime] SET [RawLine]=NULL;
        END;

        IF EXISTS(SELECT 1 FROM [#CreateExecutionEvidenceJson_StatisticsIo] WHERE [ParseStatus]<>'PARSED')
           OR EXISTS(SELECT 1 FROM [#CreateExecutionEvidenceJson_StatisticsTime] WHERE [ParseStatus]<>'PARSED')
        BEGIN
            INSERT [#CreateExecutionEvidenceJson_Warnings] VALUES('MESSAGE_PARSE_PARTIAL','LOW',N'Mindestens eine STATISTICS IO/TIME-Zeile konnte nur teilweise geparst werden.');
            SET @IsPartialOut=1;
        END;
    END TRY
    BEGIN CATCH
        SELECT @StatusCodeOut=CASE WHEN ERROR_NUMBER() BETWEEN 51021 AND 51024 THEN 'INVALID_EVIDENCE_JSON' ELSE 'ERROR_HANDLED' END,
               @IsPartialOut=1,@ErrorNumberOut=ERROR_NUMBER(),@ErrorMessageOut=ERROR_MESSAGE();
    END CATCH;

    IF @IsPartialOut=1 AND @StatusCodeOut='AVAILABLE' SET @StatusCodeOut='PARTIAL';

    /* Datenschutzgerechte Ausgabeprojektionen. Rohwerte bleiben nur bis hier lokal. */
    SELECT
          [StatementOrdinal],[MessageOrdinal],[ObjectOrdinal]
        , [ObjectDisplayName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectDisplayName]
             WHEN 'TOKENIZED' THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([ObjectDisplayName],N''))),1)
             ELSE NULL END
        , [ScanCount],[LogicalReads],[PhysicalReads],[PageServerReads],[ReadAheadReads],[PageServerReadAheadReads]
        , [LobLogicalReads],[LobPhysicalReads],[LobPageServerReads],[LobReadAheadReads],[LobPageServerReadAheadReads]
        , [LanguageDetected],[ParseStatus],[RawLine]
    INTO [#CreateExecutionEvidenceJson_StatisticsIoOutput]
    FROM [#CreateExecutionEvidenceJson_StatisticsIo];

    SELECT * INTO [#CreateExecutionEvidenceJson_StatisticsTimeOutput] FROM [#CreateExecutionEvidenceJson_StatisticsTime];

    SELECT
          [StatisticsUsageOrdinal],[StatementOrdinal],[StatementId],[StatementCompId]
        , [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([DatabaseName],N''))),1)) ELSE NULL END
        , [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([SchemaName],N''))),1)) ELSE NULL END
        , [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([ObjectName],N''))),1)) ELSE NULL END
        , [StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([StatisticsName],N''))),1)) ELSE NULL END
        , [LastUpdateAtCompile],[ModificationCountAtCompile],[SamplingPercentAtCompile],[SourceElement],[ParseStatus]
    INTO [#CreateExecutionEvidenceJson_PlanStatisticsUsageOutput]
    FROM [#CreateExecutionEvidenceJson_PlanStatisticsUsage];

    SELECT
          [ReferenceOrdinal],[StatementOrdinal],[StatementId],[StatementCompId],[NodeId],[ReferenceType],[ReferenceSource]
        , [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([DatabaseName],N''))),1)) ELSE NULL END
        , [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([SchemaName],N''))),1)) ELSE NULL END
        , [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([ObjectName],N''))),1)) ELSE NULL END
        , [IndexName]=CASE @IdentifierMode WHEN 'RAW' THEN [IndexName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([IndexName],N''))),1)) ELSE NULL END
        , [AliasName]=CASE @IdentifierMode WHEN 'RAW' THEN [AliasName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([AliasName],N''))),1)) ELSE NULL END
        , [StorageType],[PlanObjectId],[PlanIndexId],[IsTemporaryObject],[IsTableVariable],[IsRemoteObject],[IsDmlTarget]
        , [ResolutionCapability],[SourceElement]
    INTO [#CreateExecutionEvidenceJson_ObjectReferencesOutput]
    FROM [#CreateExecutionEvidenceJson_ObjectReferences];

    SELECT
          [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1)) ELSE NULL END
        , [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1)) ELSE NULL END
        , [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1)) ELSE NULL END
        , [ObjectId],[StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[StatisticsName])),1)) ELSE NULL END
        , [StatisticsId],[IsIndexStatistics],[IsAutoCreated],[IsUserCreated],[IsFiltered]
        , [FilterDefinition]=CASE WHEN @PrivacyMode='RAW' THEN [FilterDefinition] END
        , [FilterDefinitionStatus]=CONVERT(varchar(40),CASE WHEN [IsFiltered]=0 THEN 'NOT_FILTERED' WHEN @PrivacyMode='RAW' THEN 'AVAILABLE_RAW' ELSE 'OMITTED_SENSITIVE' END)
        , [NoRecompute],[IsIncremental],[HasPersistedSample]
        , [LeadingColumnName]=CASE @IdentifierMode WHEN 'RAW' THEN [LeadingColumnName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([LeadingColumnName],N''))),1)) ELSE NULL END
        , [LastUpdated],[Rows],[RowsSampled],[SamplePercent],[Steps],[UnfilteredRows]
        , [ModificationCounter],[ModificationPercent],[PersistedSamplePercent],[CollectionStatus]
    INTO [#CreateExecutionEvidenceJson_StatisticsCurrentOutput]
    FROM [#CreateExecutionEvidenceJson_StatisticsCurrent];

    SELECT
          [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1)) ELSE NULL END
        , [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1)) ELSE NULL END
        , [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1)) ELSE NULL END
        , [StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[StatisticsName])),1)) ELSE NULL END
        , [StatisticsId]
        , [LeadingColumnName]=CASE @IdentifierMode WHEN 'RAW' THEN [LeadingColumnName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([LeadingColumnName],N''))),1)) ELSE NULL END
        , [HistogramSteps],[HistogramEstimatedRows],[MaxEqualRows],[MaxRangeRows],[MaxStepRows]
        , [DominantStepPercent],[TailStepRows],[TailStepPercent],[CollectionStatus]
    INTO [#CreateExecutionEvidenceJson_HistogramSummaryOutput]
    FROM [#CreateExecutionEvidenceJson_HistogramSummary];

    SELECT
          [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[DatabaseName])),1)) ELSE NULL END
        , [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[SchemaName])),1)) ELSE NULL END
        , [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[ObjectName])),1)) ELSE NULL END
        , [StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[StatisticsName])),1)) ELSE NULL END
        , [StatisticsId]
        , [LeadingColumnName]=CASE @IdentifierMode WHEN 'RAW' THEN [LeadingColumnName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([LeadingColumnName],N''))),1)) ELSE NULL END
        , [StepOrdinal]
        , [RangeHighKey]=CASE WHEN @PrivacyMode='RAW' THEN [RangeHighKeyRaw] END
        , [RangeHighKeyToken]=CASE WHEN @PrivacyMode='TOKENIZED' AND [RangeHighKeyRaw] IS NOT NULL
            THEN HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),[RangeHighKeyRaw])) END
        , [RangeRows],[EqualRows],[DistinctRangeRows],[AverageRangeRows]
        , [IsPredicateTarget]=COALESCE([IsPredicateTarget],0),[PredicateMatchCount]=COALESCE([PredicateMatchCount],0)
        , [SensitiveValueStatus]=CONVERT(varchar(40),CASE @PrivacyMode WHEN 'RAW' THEN 'AVAILABLE_RAW'
             WHEN 'TOKENIZED' THEN 'TOKENIZED_CAPTURE_LOCAL' WHEN 'STRUCTURE_ONLY' THEN 'OMITTED_STRUCTURE_ONLY'
             ELSE 'OMITTED_DERIVED_ONLY' END)
    INTO [#CreateExecutionEvidenceJson_HistogramStepsOutput]
    FROM [#CreateExecutionEvidenceJson_HistogramSteps];

    SELECT
          [PredicateReferenceId],[StatementOrdinal],[NodeId]
        , [DatabaseName]=CASE @IdentifierMode WHEN 'RAW' THEN [DatabaseName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([DatabaseName],N''))),1)) ELSE NULL END
        , [SchemaName]=CASE @IdentifierMode WHEN 'RAW' THEN [SchemaName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([SchemaName],N''))),1)) ELSE NULL END
        , [ObjectName]=CASE @IdentifierMode WHEN 'RAW' THEN [ObjectName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([ObjectName],N''))),1)) ELSE NULL END
        , [ColumnName]=CASE @IdentifierMode WHEN 'RAW' THEN [ColumnName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([ColumnName],N''))),1)) ELSE NULL END
        , [StatisticsName]=CASE @IdentifierMode WHEN 'RAW' THEN [StatisticsName] WHEN 'TOKENIZED' THEN CONVERT(sysname,CONVERT(nvarchar(130),HASHBYTES('SHA2_256',@TokenSalt+CONVERT(varbinary(max),COALESCE([StatisticsName],N''))),1)) ELSE NULL END
        , [PredicateKind],[ValueSource],[MappingStatus],[MappingConfidence],[MatchedStepOrdinal]
        , [MatchesRangeHighKey],[IsBelowHistogram],[IsAboveHistogram],[SensitiveValueStatus]
    INTO [#CreateExecutionEvidenceJson_PredicateMappingsOutput]
    FROM [#CreateExecutionEvidenceJson_PredicateHistogramMappings];

    INSERT [#CreateExecutionEvidenceJson_CaptureStatus]
    SELECT
          N'USP_CreateExecutionEvidenceJson',@GeneratedAtUtc,@StatusCodeOut,@IsPartialOut,1
        , (SELECT COUNT_BIG(*) FROM [#CreateExecutionEvidenceJson_StatisticsIoOutput])
        , (SELECT COUNT_BIG(*) FROM [#CreateExecutionEvidenceJson_StatisticsTimeOutput])
        , (SELECT COUNT_BIG(*) FROM [#CreateExecutionEvidenceJson_PlanStatisticsUsageOutput])
        , (SELECT COUNT_BIG(*) FROM [#CreateExecutionEvidenceJson_StatisticsCurrentOutput])
        , (SELECT COUNT_BIG(*) FROM [#CreateExecutionEvidenceJson_HistogramStepsOutput])
        , (SELECT COUNT_BIG(*) FROM [#CreateExecutionEvidenceJson_PredicateMappingsOutput])
        , @PrivacyMode,@IdentifierMode,@SameExecutionConfidence,@ErrorNumberOut,@ErrorMessageOut;

    IF @JsonErzeugen=1
    BEGIN
        DECLARE @PlanDocumentHash nvarchar(130)=CASE WHEN @PlanXml IS NOT NULL
            THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',CONVERT(varbinary(max),CONVERT(nvarchar(max),@PlanXml))),1) END;
        DECLARE @MetaJson nvarchar(max)=(SELECT N'ExecutionEvidence' [resultName],1 [schemaVersion],N'USP_CreateExecutionEvidenceJson' [generator],N'1.0.0' [generatorVersion],@GeneratedAtUtc [generatedAtUtc],@StatusCodeOut [statusCode],@IsPartialOut [isPartial] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @CaptureJson nvarchar(max)=(SELECT @GeneratedAtUtc [capturedAtUtc],@SameExecutionAsPlanConfirmed [sameExecutionAsPlan],@SameExecutionConfidence [sameExecutionConfidence],@StatementOrdinal [statementOrdinal],@StatisticsLanguage [statisticsLanguage] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @EnvironmentJson nvarchar(max)=(SELECT @SourceProductVersion [productVersion],@SourceCompatibilityLevel [compatibilityLevel],@SourceEngineEdition [engineEdition] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @IdentityJson nvarchar(max)=(SELECT @PlanDocumentHash [planDocumentHash],@StatementId [statementId] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
        DECLARE @IoJson nvarchar(max)=(SELECT
              [StatementOrdinal] [statementOrdinal],[MessageOrdinal] [messageOrdinal],[ObjectOrdinal] [objectOrdinal]
            , [ObjectDisplayName] [objectDisplayName],[ScanCount] [scanCount],[LogicalReads] [logicalReads]
            , [PhysicalReads] [physicalReads],[PageServerReads] [pageServerReads],[ReadAheadReads] [readAheadReads]
            , [PageServerReadAheadReads] [pageServerReadAheadReads],[LobLogicalReads] [lobLogicalReads]
            , [LobPhysicalReads] [lobPhysicalReads],[LobPageServerReads] [lobPageServerReads]
            , [LobReadAheadReads] [lobReadAheadReads],[LobPageServerReadAheadReads] [lobPageServerReadAheadReads]
            , [LanguageDetected] [languageDetected],[ParseStatus] [parseStatus],[RawLine] [rawLine]
            FROM [#CreateExecutionEvidenceJson_StatisticsIoOutput] ORDER BY [MessageOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @TimeJson nvarchar(max)=(SELECT
              [StatementOrdinal] [statementOrdinal],[MessageOrdinal] [messageOrdinal],[TimeCategory] [timeCategory]
            , [CpuMs] [cpuMs],[ElapsedMs] [elapsedMs],[LanguageDetected] [languageDetected]
            , [ParseStatus] [parseStatus],[RawLine] [rawLine]
            FROM [#CreateExecutionEvidenceJson_StatisticsTimeOutput] ORDER BY [MessageOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @PlanStatsJson nvarchar(max)=(SELECT
              [StatisticsUsageOrdinal] [statisticsUsageOrdinal],[StatementOrdinal] [statementOrdinal]
            , [StatementId] [statementId],[StatementCompId] [statementCompId]
            , [DatabaseName] [databaseName],[SchemaName] [schemaName],[ObjectName] [objectName]
            , [StatisticsName] [statisticsName],[LastUpdateAtCompile] [lastUpdateAtCompile]
            , [ModificationCountAtCompile] [modificationCountAtCompile]
            , [SamplingPercentAtCompile] [samplingPercentAtCompile],[SourceElement] [sourceElement]
            , [ParseStatus] [parseStatus]
            FROM [#CreateExecutionEvidenceJson_PlanStatisticsUsageOutput] ORDER BY [StatementOrdinal],[StatisticsUsageOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @ObjectsJson nvarchar(max)=(SELECT
              [ReferenceOrdinal] [referenceOrdinal],[StatementOrdinal] [statementOrdinal]
            , [StatementId] [statementId],[StatementCompId] [statementCompId],[NodeId] [nodeId]
            , [ReferenceType] [referenceType],[ReferenceSource] [referenceSource]
            , [DatabaseName] [databaseName],[SchemaName] [schemaName],[ObjectName] [objectName]
            , [IndexName] [indexName],[AliasName] [aliasName],[StorageType] [storageType]
            , [PlanObjectId] [planObjectId],[PlanIndexId] [planIndexId]
            , [IsTemporaryObject] [isTemporaryObject],[IsTableVariable] [isTableVariable]
            , [IsRemoteObject] [isRemoteObject],[IsDmlTarget] [isDmlTarget]
            , [ResolutionCapability] [resolutionCapability],[SourceElement] [sourceElement]
            FROM [#CreateExecutionEvidenceJson_ObjectReferencesOutput] ORDER BY [StatementOrdinal],[ReferenceOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @CurrentStatsJson nvarchar(max)=(SELECT
              [DatabaseName] [databaseName],[SchemaName] [schemaName],[ObjectName] [objectName]
            , [ObjectId] [objectId],[StatisticsName] [statisticsName],[StatisticsId] [statisticsId]
            , [IsIndexStatistics] [isIndexStatistics],[IsAutoCreated] [isAutoCreated],[IsUserCreated] [isUserCreated]
            , [IsFiltered] [isFiltered],[FilterDefinition] [filterDefinition],[FilterDefinitionStatus] [filterDefinitionStatus]
            , [NoRecompute] [noRecompute],[IsIncremental] [isIncremental],[HasPersistedSample] [hasPersistedSample]
            , [LeadingColumnName] [leadingColumnName],[LastUpdated] [lastUpdated],[Rows] [rows]
            , [RowsSampled] [rowsSampled],[SamplePercent] [samplePercent],[Steps] [steps]
            , [UnfilteredRows] [unfilteredRows],[ModificationCounter] [modificationCounter]
            , [ModificationPercent] [modificationPercent],[PersistedSamplePercent] [persistedSamplePercent]
            , [CollectionStatus] [collectionStatus]
            FROM [#CreateExecutionEvidenceJson_StatisticsCurrentOutput] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[StatisticsName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @HistogramSummaryJson nvarchar(max)=(SELECT
              [DatabaseName] [databaseName],[SchemaName] [schemaName],[ObjectName] [objectName]
            , [StatisticsName] [statisticsName],[StatisticsId] [statisticsId],[LeadingColumnName] [leadingColumnName]
            , [HistogramSteps] [histogramSteps],[HistogramEstimatedRows] [histogramEstimatedRows]
            , [MaxEqualRows] [maxEqualRows],[MaxRangeRows] [maxRangeRows],[MaxStepRows] [maxStepRows]
            , [DominantStepPercent] [dominantStepPercent],[TailStepRows] [tailStepRows]
            , [TailStepPercent] [tailStepPercent],[CollectionStatus] [collectionStatus]
            FROM [#CreateExecutionEvidenceJson_HistogramSummaryOutput] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[StatisticsName] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @HistogramStepsJson nvarchar(max)=(SELECT
              [DatabaseName] [databaseName],[SchemaName] [schemaName],[ObjectName] [objectName]
            , [StatisticsName] [statisticsName],[StatisticsId] [statisticsId],[LeadingColumnName] [leadingColumnName]
            , [StepOrdinal] [stepOrdinal],[RangeHighKey] [rangeHighKey],[RangeHighKeyToken] [rangeHighKeyToken]
            , [RangeRows] [rangeRows],[EqualRows] [equalRows],[DistinctRangeRows] [distinctRangeRows]
            , [AverageRangeRows] [averageRangeRows],[IsPredicateTarget] [isPredicateTarget]
            , [PredicateMatchCount] [predicateMatchCount],[SensitiveValueStatus] [sensitiveValueStatus]
            FROM [#CreateExecutionEvidenceJson_HistogramStepsOutput] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],[StepOrdinal] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @MappingsJson nvarchar(max)=(SELECT
              [PredicateReferenceId] [predicateReferenceId],[StatementOrdinal] [statementOrdinal],[NodeId] [nodeId]
            , [DatabaseName] [databaseName],[SchemaName] [schemaName],[ObjectName] [objectName]
            , [ColumnName] [columnName],[StatisticsName] [statisticsName],[PredicateKind] [predicateKind]
            , [ValueSource] [valueSource],[MappingStatus] [mappingStatus],[MappingConfidence] [mappingConfidence]
            , [MatchedStepOrdinal] [matchedStepOrdinal],[MatchesRangeHighKey] [matchesRangeHighKey]
            , [IsBelowHistogram] [isBelowHistogram],[IsAboveHistogram] [isAboveHistogram]
            , [SensitiveValueStatus] [sensitiveValueStatus]
            FROM [#CreateExecutionEvidenceJson_PredicateMappingsOutput] ORDER BY [StatementOrdinal],[PredicateReferenceId],[ValueSource] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @StatusJson nvarchar(max)=(SELECT
              [DatabaseName] [databaseName],[SchemaName] [schemaName],[ObjectName] [objectName]
            , [StatisticsName] [statisticsName],[StatusCode] [statusCode],[ErrorNumber] [errorNumber]
            , [ErrorMessage] [errorMessage]
            FROM [#CreateExecutionEvidenceJson_CollectionStatus] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @WarningsJson nvarchar(max)=(SELECT
              [WarningCode] [warningCode],[Severity] [severity],[Detail] [detail]
            FROM [#CreateExecutionEvidenceJson_Warnings] FOR JSON PATH,INCLUDE_NULL_VALUES);
        DECLARE @RawInputJson nvarchar(max)=(SELECT
              LEN(@StatisticsIoText) [statisticsIoCharacters]
            , CASE WHEN @RawMode IN ('HASH_ONLY','INCLUDE') AND @StatisticsIoText IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',CONVERT(varbinary(max),@StatisticsIoText)),1) END [statisticsIoHash]
            , LEN(@StatisticsTimeText) [statisticsTimeCharacters]
            , CASE WHEN @RawMode IN ('HASH_ONLY','INCLUDE') AND @StatisticsTimeText IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',CONVERT(varbinary(max),@StatisticsTimeText)),1) END [statisticsTimeHash]
            FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);

        SET @Json=CONCAT
        (
              N'{"meta":',COALESCE(@MetaJson,N'{}')
            , N',"capture":',COALESCE(@CaptureJson,N'{}')
            , N',"sourceEnvironment":',COALESCE(@EnvironmentJson,N'{}')
            , N',"planIdentity":',COALESCE(@IdentityJson,N'{}')
            , N',"statisticsIo":',COALESCE(@IoJson,N'[]')
            , N',"statisticsTime":',COALESCE(@TimeJson,N'[]')
            , N',"statistics":{"planUsage":',COALESCE(@PlanStatsJson,N'[]')
            , N',"currentSnapshot":',COALESCE(@CurrentStatsJson,N'[]')
            , N',"histogramSummaries":',COALESCE(@HistogramSummaryJson,N'[]')
            , N',"histogramSteps":',COALESCE(@HistogramStepsJson,N'[]'),N'}'
            , N',"objectReferences":',COALESCE(@ObjectsJson,N'[]')
            , N',"predicateHistogramMappings":',COALESCE(@MappingsJson,N'[]')
            , N',"collectionStatus":',COALESCE(@StatusJson,N'[]')
            , N',"warnings":',COALESCE(@WarningsJson,N'[]')
            , N',"rawInput":',COALESCE(@RawInputJson,N'{}')
            , N',"importedEvidence":'
            , COALESCE
              (
                  (
                      SELECT
                            CONVERT(bit,CASE WHEN @StatisticsEvidenceJson IS NOT NULL THEN 1 ELSE 0 END) [statisticsEvidenceProvided]
                          , CASE WHEN @StatisticsEvidenceJson IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',CONVERT(varbinary(max),@StatisticsEvidenceJson)),1) END [statisticsEvidenceHash]
                          , CONVERT(bit,CASE WHEN @ObjectMetadataJson IS NOT NULL THEN 1 ELSE 0 END) [objectMetadataProvided]
                          , CASE WHEN @ObjectMetadataJson IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',CONVERT(varbinary(max),@ObjectMetadataJson)),1) END [objectMetadataHash]
                          , CONVERT(bit,CASE WHEN @ExistingEvidenceJson IS NOT NULL AND ISJSON(@ExistingEvidenceJson)=1 THEN 1 ELSE 0 END) [existingEvidenceMerged]
                          , CASE WHEN @ExistingEvidenceJson IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',CONVERT(varbinary(max),@ExistingEvidenceJson)),1) END [existingEvidenceHash]
                          , CONVERT(bit,CASE WHEN @AdditionalEvidenceJson IS NOT NULL THEN 1 ELSE 0 END) [additionalEvidenceProvided]
                          , CASE WHEN @AdditionalEvidenceJson IS NOT NULL THEN CONVERT(nvarchar(130),HASHBYTES('SHA2_256',CONVERT(varbinary(max),@AdditionalEvidenceJson)),1) END [additionalEvidenceHash]
                      FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES
                  )
                , N'{}'
              )
            , N',"additionalEvidence":'
            , CASE WHEN @PrivacyMode='RAW' AND @SensitiveDataConfirmed=1
                   THEN COALESCE(JSON_QUERY(@AdditionalEvidenceJson),N'null') ELSE N'null' END
            , N'}'
        );
    END;

    IF @OutputMode='RAW'
    BEGIN
        SELECT * FROM [#CreateExecutionEvidenceJson_CaptureStatus];
        SELECT * FROM [#CreateExecutionEvidenceJson_StatisticsIoOutput] ORDER BY [MessageOrdinal];
        SELECT * FROM [#CreateExecutionEvidenceJson_StatisticsTimeOutput] ORDER BY [MessageOrdinal];
        SELECT * FROM [#CreateExecutionEvidenceJson_PlanStatisticsUsageOutput] ORDER BY [StatementOrdinal],[StatisticsUsageOrdinal];
        SELECT * FROM [#CreateExecutionEvidenceJson_ObjectReferencesOutput] ORDER BY [StatementOrdinal],[ReferenceOrdinal];
        SELECT * FROM [#CreateExecutionEvidenceJson_StatisticsCurrentOutput] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[StatisticsName];
        SELECT * FROM [#CreateExecutionEvidenceJson_HistogramSummaryOutput] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[StatisticsName];
        SELECT * FROM [#CreateExecutionEvidenceJson_HistogramStepsOutput] ORDER BY [DatabaseName],[SchemaName],[ObjectName],[StatisticsName],[StepOrdinal];
        SELECT * FROM [#CreateExecutionEvidenceJson_PredicateMappingsOutput] ORDER BY [StatementOrdinal],[PredicateReferenceId],[ValueSource];
        SELECT * FROM [#CreateExecutionEvidenceJson_CollectionStatus];
        SELECT * FROM [#CreateExecutionEvidenceJson_Warnings];
    END;

    IF @ConsoleResultRequested=1
        EXEC [monitor].[InternalEmitConsoleResult]
              @SourceTable=N'#CreateExecutionEvidenceJson_CaptureStatus'
            , @ResultLabel=N'Execution Evidence'
            , @EmptyMessage=N'Keine Evidenz erzeugt'
            , @StatusCode=@StatusCodeOut
            , @StatusMessage=@ErrorMessageOut;

    IF @TableRequested=1
    BEGIN
        DECLARE @ResultName sysname,@TargetTable sysname,@SourceTable sysname;
        DECLARE [MapCursor] CURSOR LOCAL FAST_FORWARD FOR
            SELECT [ResultName],[TargetTable] FROM [#CreateExecutionEvidenceJson_TableMap] ORDER BY [ResultName];
        OPEN [MapCursor];
        FETCH NEXT FROM [MapCursor] INTO @ResultName,@TargetTable;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @SourceTable=CASE @ResultName
                WHEN N'captureStatus' THEN N'#CreateExecutionEvidenceJson_CaptureStatus'
                WHEN N'statisticsIo' THEN N'#CreateExecutionEvidenceJson_StatisticsIoOutput'
                WHEN N'statisticsTime' THEN N'#CreateExecutionEvidenceJson_StatisticsTimeOutput'
                WHEN N'planStatisticsUsage' THEN N'#CreateExecutionEvidenceJson_PlanStatisticsUsageOutput'
                WHEN N'objectReferences' THEN N'#CreateExecutionEvidenceJson_ObjectReferencesOutput'
                WHEN N'currentStatistics' THEN N'#CreateExecutionEvidenceJson_StatisticsCurrentOutput'
                WHEN N'histogramSummaries' THEN N'#CreateExecutionEvidenceJson_HistogramSummaryOutput'
                WHEN N'histogramSteps' THEN N'#CreateExecutionEvidenceJson_HistogramStepsOutput'
                WHEN N'predicateHistogramMappings' THEN N'#CreateExecutionEvidenceJson_PredicateMappingsOutput'
                WHEN N'collectionStatus' THEN N'#CreateExecutionEvidenceJson_CollectionStatus'
                WHEN N'warnings' THEN N'#CreateExecutionEvidenceJson_Warnings' END;
            EXEC [monitor].[InternalWriteResultTable]
                  @SourceTable=@SourceTable,@TargetTable=@TargetTable,@ThrowOnError=1;
            FETCH NEXT FROM [MapCursor] INTO @ResultName,@TargetTable;
        END;
        CLOSE [MapCursor];DEALLOCATE [MapCursor];
    END;

    IF @PrintMeldungen=1 AND @StatusCodeOut NOT IN ('AVAILABLE')
    BEGIN
        DECLARE @Message nvarchar(2048)=FORMATMESSAGE(N'WARNUNG USP_CreateExecutionEvidenceJson: %s - %s',@StatusCodeOut,COALESCE(@ErrorMessageOut,N'partielle Evidenz'));
        RAISERROR(N'%s',10,1,@Message) WITH NOWAIT;
    END;
END;
GO
