USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 172_P1_Memory_Runtime_Contract.sql
Zweck        : Prüft rein lesende Laufzeitverträge für vier P1-Speicherfälle.
Datenschutz  : Technische DMV-Werte werden nur im laufenden Test verglichen und
               nicht in Repository- oder Downloadartefakte übernommen.
Kosten       : MEM-BUFFER aktiviert den auf dem disposable Ziel erlaubten
               Buffer-Descriptor-Scan ausdrücklich und begrenzt die Ausgabe.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Json nvarchar(max),@Status varchar(40),@Partial bit;
DECLARE @ExecutedCases TABLE([CaseId] varchar(40) NOT NULL PRIMARY KEY);

EXEC [monitor].[USP_BufferPoolAnalysis]
     @MitMemoryClerks=0,@MitBufferPoolVerteilung=0,@MaxZeilen=0,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;

/* MEM-BASE: der Defaultpfad scannt keine Buffer Descriptors. */
IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING')
   OR NOT EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.meta')
       WITH ([Collected] bit N'$.bufferPoolDistributionCollected') WHERE [Collected]=0)
   OR EXISTS(SELECT 1 FROM OPENJSON(@Json,N'$.bufferPool'))
    THROW 54600,N'P1-Vertrag MEM-BASE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('MEM-BASE');

/* MEM-PRESSURE: Finding und Severity folgen ausschließlich der aktuellen Zeile. */
IF NOT EXISTS(SELECT 1 FROM OPENJSON(@Json,N'$.memory'))
   OR EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.memory')
       WITH
       (
           [PhysicalLow] bit N'$.ProcessPhysicalMemoryLow',
           [VirtualLow] bit N'$.ProcessVirtualMemoryLow',
           [AvailablePercent] decimal(9,2) N'$.AvailablePhysicalMemoryPercent',
           [FindingCode] varchar(80) N'$.FindingCode',
           [Severity] varchar(16) N'$.FindingSeverity'
       )
       WHERE (COALESCE([PhysicalLow],0)=1
              AND ([FindingCode]<>'PROCESS_PHYSICAL_MEMORY_LOW' OR [Severity]<>'HIGH'))
          OR (COALESCE([PhysicalLow],0)=0 AND COALESCE([VirtualLow],0)=1
              AND ([FindingCode]<>'PROCESS_VIRTUAL_MEMORY_LOW' OR [Severity]<>'HIGH'))
          OR (COALESCE([PhysicalLow],0)=0 AND COALESCE([VirtualLow],0)=0
              AND [AvailablePercent]<5
              AND ([FindingCode]<>'OS_AVAILABLE_MEMORY_BELOW_5_PERCENT' OR [Severity]<>'MEDIUM'))
          OR (COALESCE([PhysicalLow],0)=0 AND COALESCE([VirtualLow],0)=0
              AND ([AvailablePercent]>=5 OR [AvailablePercent] IS NULL)
              AND ([FindingCode]<>'NO_MEMORY_PRESSURE_FLAG' OR [Severity]<>'INFO')))
    THROW 54601,N'P1-Vertrag MEM-PRESSURE fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('MEM-PRESSURE');

/* MEM-GRANT: der in einem Zeitpunkt erfasste Semaphore-Snapshot ist vollständig
   strukturiert. Ein zweiter DMV-Read wäre wegen legitimer Zähleränderungen kein
   stabiler Gleichheitsbeweis. */
DECLARE @Semaphores TABLE
(
    [PoolId] int NULL,[ResourceSemaphoreId] smallint NULL,
    [WaiterCount] int NULL,[GranteeCount] int NULL
);
INSERT @Semaphores
SELECT [PoolId],[ResourceSemaphoreId],[WaiterCount],[GranteeCount]
FROM OPENJSON(@Json,N'$.resourceSemaphores')
WITH
(
    [PoolId] int N'$.PoolId',[ResourceSemaphoreId] smallint N'$.ResourceSemaphoreId',
    [WaiterCount] int N'$.WaiterCount',[GranteeCount] int N'$.GranteeCount'
);
IF NOT EXISTS(SELECT 1 FROM @Semaphores)
   OR EXISTS
      (SELECT 1 FROM @Semaphores
       WHERE [PoolId] IS NULL OR [ResourceSemaphoreId] IS NULL
          OR [WaiterCount] IS NULL OR [WaiterCount]<0
          OR [GranteeCount] IS NULL OR [GranteeCount]<0)
   OR EXISTS
      (SELECT 1 FROM @Semaphores
       GROUP BY [PoolId],[ResourceSemaphoreId] HAVING COUNT_BIG(*)>1)
    THROW 54602,N'P1-Vertrag MEM-GRANT fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('MEM-GRANT');

/* MEM-BUFFER: explizites Opt-in, höchstens eine ausgegebene Datenbankgruppe. */
SET @Json=NULL; SET @Status=NULL; SET @Partial=NULL;
EXEC [monitor].[USP_BufferPoolAnalysis]
     @MitMemoryClerks=0,@MitBufferPoolVerteilung=1,@MaxZeilen=1,
     @ResultSetArt='NONE',@JsonErzeugen=1,@Json=@Json OUTPUT,@PrintMeldungen=0,
     @StatusCodeOut=@Status OUTPUT,@IsPartialOut=@Partial OUTPUT;
IF ISJSON(@Json)<>1 OR @Status NOT IN('AVAILABLE','AVAILABLE_WITH_FINDING')
   OR NOT EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.meta')
       WITH ([Collected] bit N'$.bufferPoolDistributionCollected') WHERE [Collected]=1)
   OR (SELECT COUNT_BIG(*) FROM OPENJSON(@Json,N'$.bufferPool'))>1
   OR EXISTS
      (SELECT 1 FROM OPENJSON(@Json,N'$.bufferPool')
       WITH ([DatabaseId] int N'$.DatabaseId',[CachedPages] bigint N'$.CachedPages')
       WHERE [DatabaseId] IS NULL OR [CachedPages]<=0)
    THROW 54603,N'P1-Vertrag MEM-BUFFER fehlgeschlagen.',1;
INSERT @ExecutedCases VALUES('MEM-BUFFER');

IF (SELECT COUNT_BIG(*) FROM @ExecutedCases)<>4
    THROW 54604,N'Der P1-Speichervertrag hat nicht alle vorgesehenen Fälle ausgeführt.',1;

SELECT CAST('AVAILABLE' AS varchar(40)) AS [StatusCode],CAST(0 AS bit) AS [IsPartial],
       COUNT_BIG(*) AS [ExecutedCases],
       N'Vier read-only P1-Speicherfälle wurden ohne persistierte Laufzeitausgabe ausgeführt.' AS [Detail]
FROM @ExecutedCases;
GO
