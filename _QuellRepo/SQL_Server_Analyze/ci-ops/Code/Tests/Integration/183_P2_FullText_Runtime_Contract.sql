USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 183_P2_FullText_Runtime_Contract.sql
Zweck        : Automatisiert die 16 P2-Full-Text-Verträge capability-adaptiv.
Datenschutz  : Keine Inhalte, Keywords, Stopwords, Schlüsselwerte, Crawl-Logs
               oder Pfade. Keine Full-Text-DDL auf Linux-Containerzielen.
Grenze       : Positive Katalog-, Index- und Populationsevidenz bleibt ein
               separater Windows-/Feature-Positivnachweis.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ExecutedCases TABLE([CaseId] varchar(64) NOT NULL PRIMARY KEY);
DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit,@Definition nvarchar(max);

SELECT @Definition=[sm].[definition]
FROM [sys].[sql_modules] [sm] WITH (NOLOCK)
JOIN [sys].[objects] [o] WITH (NOLOCK) ON [o].[object_id]=[sm].[object_id]
JOIN [sys].[schemas] [s] WITH (NOLOCK) ON [s].[schema_id]=[o].[schema_id]
WHERE [s].[name]=N'monitor' AND [o].[name]=N'USP_FullTextAnalysis';
IF @Definition IS NULL THROW 55700,N'Full-Text-Proceduredefinition ist nicht sichtbar.',1;

/* FULLTEXT-NONE: echter capability-adaptiver Aufruf ohne Full-Text-Objekte. */
EXEC [monitor].[USP_FullTextAnalysis]
     @DatabaseNames=N'[DeineDatenbank]',@ObjectNamePattern=N'like:ExampleFullText%',
     @MaxZeilen=10,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1
   OR @Status NOT IN('NOT_APPLICABLE','AVAILABLE','AVAILABLE_LIMITED','UNAVAILABLE_FEATURE')
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.fullTextIndexes'))<>0
    THROW 55701,N'P2-Vertrag FULLTEXT-NONE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('FULLTEXT-NONE');

/* FULLTEXT-FILTER: Filtervertrag muss auch ohne Featureobjekte gültiges JSON liefern. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_FullTextAnalysis]
     @DatabaseNames=N'[DeineDatenbank]',@ObjectNames=N'ExampleFullTextA',
     @MaxZeilen=0,@ResultSetArt='NONE',
     @JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.fullTextIndexes'))<>0
    THROW 55702,N'P2-Vertrag FULLTEXT-FILTER fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('FULLTEXT-FILTER');

/* FULLTEXT-BOUNDED: alle JSON-Detailarrays bleiben auf eine Zeile begrenzt. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_FullTextAnalysis]
     @DatabaseNames=N'[DeineDatenbank]',@MaxZeilen=1,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT,
     @HighImpactConfirmed=1;
IF ISJSON(@Json)<>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.catalogs'))>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.fullTextIndexes'))>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.populations'))>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.outstandingBatches'))>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.fragments'))>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.semanticPopulations'))>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.memoryPools'))>1
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.fdhosts'))>1
    THROW 55703,N'P2-Vertrag FULLTEXT-BOUNDED fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('FULLTEXT-BOUNDED');

/* Positive und nicht portabel erzwingbare Zustände bleiben an konkrete Quellen und Codes gebunden. */
DECLARE @StaticCases TABLE
(
      [CaseId] varchar(64) NOT NULL PRIMARY KEY
    , [Token1] nvarchar(240) NOT NULL
    , [Token2] nvarchar(240) NULL
);
INSERT @StaticCases VALUES
      ('FULLTEXT-COMPONENT-MISSING',N'''FULLTEXT_COMPONENT_UNAVAILABLE_WITH_OBJECTS''',N'IsFullTextInstalled')
    , ('FULLTEXT-CATALOG-ONLY',N'''FULLTEXT_CATALOG_WITHOUT_VISIBLE_INDEX''',N'[sys].[fulltext_catalogs]')
    , ('FULLTEXT-INDEX-DISABLED',N'''FULLTEXT_INDEX_DISABLED''',N'[sys].[fulltext_indexes]')
    , ('FULLTEXT-POPULATION-ACTIVE',N'[sys].[dm_fts_index_population]',N'[StatusDescription]')
    , ('FULLTEXT-POPULATION-LONG',N'''FULLTEXT_LONG_RUNNING_POPULATION''',N'@PopulationAgeWarnMinutes')
    , ('FULLTEXT-POPULATION-ABORTED',N'''FULLTEXT_POPULATION_ABORTED''',N'[Status]=11')
    , ('FULLTEXT-BATCH-RETRY',N'''FULLTEXT_RETRY_BATCH_CONTEXT''',N'[sys].[dm_fts_outstanding_batches]')
    , ('FULLTEXT-DOCUMENT-FAILURES',N'''FULLTEXT_DOCUMENT_FAILURES_REPORTED''',N'[FailedDocumentCount]')
    , ('FULLTEXT-FRAGMENTS',N'''FULLTEXT_FRAGMENTATION_HEURISTIC''',N'[sys].[fulltext_index_fragments]')
    , ('FULLTEXT-SEMANTIC',N'[sys].[dm_fts_semantic_similarity_population]',N'[semanticPopulations]')
    , ('FULLTEXT-MEMORY-FDHOST',N'[sys].[dm_fts_memory_pools]',N'[sys].[dm_fts_fdhosts]')
    , ('FULLTEXT-DENIED',N'''FULLTEXT_EVIDENCE_GAP''',N'''AVAILABLE_LIMITED''');

IF EXISTS
(
    SELECT 1 FROM @StaticCases
    WHERE CHARINDEX([Token1],@Definition)=0
       OR ([Token2] IS NOT NULL AND CHARINDEX([Token2],@Definition)=0)
)
    THROW 55704,N'Mindestens ein Full-Text-Quellen-, Finding- oder Denied-Vertrag fehlt.',1;
INSERT @ExecutedCases SELECT [CaseId] FROM @StaticCases;

/* FULLTEXT-PRIVACY-READONLY */
IF CHARINDEX(N'[sys].[dm_fts_parser]',LOWER(@Definition))>0
   OR CHARINDEX(N'[sys].[fulltext_stopwords]',LOWER(@Definition))>0
   OR CHARINDEX(N'[sys].[fulltext_system_stopwords]',LOWER(@Definition))>0
   OR CHARINDEX(N'[sys].[fulltext_index_keywords]',LOWER(@Definition))>0
   OR CHARINDEX(N'[sys].[fulltext_index_keywords_by_document]',LOWER(@Definition))>0
   OR CHARINDEX(N'create fulltext index',LOWER(@Definition))>0
   OR CHARINDEX(N'drop fulltext index',LOWER(@Definition))>0
   OR CHARINDEX(N'alter fulltext index',LOWER(@Definition))>0
    THROW 55705,N'P2-Vertrag FULLTEXT-PRIVACY-READONLY fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('FULLTEXT-PRIVACY-READONLY');

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>16
    THROW 55706,N'Der P2-Full-Text-Vertrag hat nicht alle 16 Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'16 P2-Full-Text-Fälle wurden ohne Inhaltszugriff und ohne nichtportable Linux-DDL geprüft.' AS [Detail]
FROM @ExecutedCases;
GO
