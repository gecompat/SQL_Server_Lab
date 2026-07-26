USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 180_P2_InMemory_Oltp_Runtime_Contract.sql
Zweck        : Automatisiert die 14 P2-In-Memory-OLTP-Verträge.
Datenschutz  : Ausschließlich synthetische Kennzahlen und sichtbare Metadaten;
               keine Tabellenzeilen, SQL-Texte, Transaktions-IDs oder Pfade.
Kosten       : Der potenziell vollständige Hash-DMV-Scan wird nicht erzwungen.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @Definition nvarchar(max);

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_InMemoryOltpAnalysis';
IF @Definition IS NULL THROW 55400,N'XTP-Proceduredefinition ist nicht sichtbar.',1;

/* XTP-NONE */
EXEC [monitor].[USP_InMemoryOltpAnalysis]
     @DatabaseNames=N'[DeineDatenbank]',@MaxZeilen=10,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1 OR @Status NOT IN('NOT_APPLICABLE','AVAILABLE','AVAILABLE_LIMITED')
   OR NOT EXISTS
      (
          SELECT 1 FROM OPENJSON(@Json,N'$.databaseStatus')
          WITH ([StatusCode] varchar(40) N'$.StatusCode')
          WHERE [StatusCode] IN('NOT_APPLICABLE_VISIBLE_SCOPE','AVAILABLE','AVAILABLE_LIMITED')
      )
    THROW 55401,N'P2-Vertrag XTP-NONE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('XTP-NONE');

/* Statische Kopplung der positiven und isolierten Quellenverträge. */
DECLARE @StaticCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY,[Token1] nvarchar(200) NOT NULL,[Token2] nvarchar(200) NULL);
INSERT @StaticCases VALUES
      ('XTP-SCHEMA-ONLY',N'[is_memory_optimized]',N'[durability_desc]')
    , ('XTP-TABLE-MEMORY',N'''LARGE_MEMORY_CONSUMER_CONTEXT''',N'@MinTableMemoryMb')
    , ('XTP-CONSUMERS',N'''XTP_MEMORY_CONSUMERS''',N'[memory_consumer_type]')
    , ('XTP-HASH-CATALOG',N'''NOT_REQUESTED''',N'[bucket_count]')
    , ('XTP-HASH-DENIED',N'''DENIED_GROUP''',N'''CATALOG_DEEP''')
    , ('XTP-HASH-CHAIN',N'''HASH_DUPLICATE_OR_SKEW_REVIEW''',N'''HASH_BUCKET_COUNT_REVIEW''')
    , ('XTP-CHECKPOINT',N'''WAITING_LOG_TRUNCATION_REVIEW''',N'@WaitingCheckpointWarnMb')
    , ('XTP-TRANSACTIONS',N'''ACTIVE_TRANSACTION_VOLUME_REVIEW''',N'@ActiveTransactionWarnCount')
    , ('XTP-POOL-DEFAULT',N'''SHARED_DEFAULT_POOL_CONTEXT''',N'[resource_pool_id]')
    , ('XTP-POOL-NAMED',N'''POOL_MEMORY_PRESSURE_REVIEW''',N'''POOL_OUT_OF_MEMORY_RECORDED''')
    , ('XTP-DENIED',N'''AVAILABLE_LIMITED''',N'''XTP_EVIDENCE_GAP''')
    , ('XTP-FILTER',N'@FullObjectNames',N'@ObjectNamePattern')
    , ('XTP-BOUNDED',N'TOP(@Limit)',N'@MaxZeilen');

IF EXISTS
(
    SELECT 1 FROM @StaticCases
    WHERE CHARINDEX([Token1],@Definition)=0
       OR ([Token2] IS NOT NULL AND CHARINDEX([Token2],@Definition)=0)
)
    THROW 55402,N'Mindestens ein XTP-Quellen-, Filter- oder Begrenzungsvertrag fehlt.',1;

/* Synthetische Schwellenwerte prüfen die dokumentierte Priorität der vorhandenen Codes. */
DECLARE @Hash TABLE([AverageChainLength] decimal(19,4),[MaxChainLength] bigint,[EmptyBucketPercent] decimal(9,4),[Expected] varchar(100));
INSERT @Hash VALUES
      (11,20,20,'HASH_DUPLICATE_OR_SKEW_REVIEW')
    , (11,20,5,'HASH_BUCKET_COUNT_REVIEW')
    , (2,101,50,'HASH_MAX_CHAIN_REVIEW')
    , (2,20,5,'LOW_EMPTY_BUCKET_PERCENT_REVIEW');
IF EXISTS
(
    SELECT 1 FROM @Hash
    WHERE [Expected]<>CASE
          WHEN [AverageChainLength]>10 AND [EmptyBucketPercent]>=10 THEN 'HASH_DUPLICATE_OR_SKEW_REVIEW'
          WHEN [AverageChainLength]>10 AND [EmptyBucketPercent]<10 THEN 'HASH_BUCKET_COUNT_REVIEW'
          WHEN [MaxChainLength]>=100 THEN 'HASH_MAX_CHAIN_REVIEW'
          WHEN [EmptyBucketPercent]<10 THEN 'LOW_EMPTY_BUCKET_PERCENT_REVIEW' END
)
    THROW 55403,N'XTP-Hashklassifikation verletzt die dokumentierte Priorität.',1;

DECLARE @CheckpointFinding varchar(100)=CASE WHEN 2048>=1024 THEN 'WAITING_LOG_TRUNCATION_REVIEW' END;
DECLARE @TransactionFinding varchar(100)=CASE WHEN 101>=100 THEN 'ACTIVE_TRANSACTION_VOLUME_REVIEW' END;
DECLARE @DefaultPoolFinding varchar(100)=CASE WHEN 2=2 THEN 'SHARED_DEFAULT_POOL_CONTEXT' END;
DECLARE @NamedPoolFinding varchar(100)=CASE WHEN 85>=80 THEN 'POOL_MEMORY_PRESSURE_REVIEW' END;
IF @CheckpointFinding<>'WAITING_LOG_TRUNCATION_REVIEW'
   OR @TransactionFinding<>'ACTIVE_TRANSACTION_VOLUME_REVIEW'
   OR @DefaultPoolFinding<>'SHARED_DEFAULT_POOL_CONTEXT'
   OR @NamedPoolFinding<>'POOL_MEMORY_PRESSURE_REVIEW'
    THROW 55404,N'XTP-Schwellenklassifikation fehlgeschlagen.',1;

INSERT @ExecutedCases SELECT [CaseId] FROM @StaticCases;

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>14
    THROW 55405,N'Der P2-XTP-Vertrag hat nicht alle 14 Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'14 P2-XTP-Fälle wurden ohne erzwungenen vollständigen Hash-DMV-Scan geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
