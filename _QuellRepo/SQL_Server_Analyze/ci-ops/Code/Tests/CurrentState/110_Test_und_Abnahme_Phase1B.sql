USE [DeineDatenbank];
GO

-- Sichere Signatur-/Hilfeprüfung; keine ressourcenintensive Analyse.
EXEC [monitor].[USP_CurrentSessions] @Hilfe=1;
EXEC [monitor].[USP_CurrentRequests] @Hilfe=1;
EXEC [monitor].[USP_CurrentBlocking] @Hilfe=1;
EXEC [monitor].[USP_CurrentMemoryGrants] @Hilfe=1;
EXEC [monitor].[USP_CurrentOverview] @Hilfe=1;
GO

-- BEGIN STATEMENT-OFFSET-LAUFZEITTEST

-- Statement-Offset-Vertrag
DECLARE @OffsetTestStatement nvarchar(max);
SELECT @OffsetTestStatement=[StatementText]
FROM [monitor].[TVF_StatementText](N'SELECT 1; SELECT 2;',20,-1);
IF @OffsetTestStatement<>N'SELECT 2;'
    THROW 54110,N'Fehler im Statement-Offset-Vertrag.',1;

-- Eng begrenzter Laufzeittest auf der aktuellen Session
DECLARE @SelfSessionIds nvarchar(20)=CONVERT(nvarchar(20),@@SPID);
DECLARE @SelfJson nvarchar(max);
EXEC [monitor].[USP_CurrentRequests]
      @SessionIds=@SelfSessionIds
    , @AktuelleSessionEinbeziehen=1
    , @GesamtenSqlTextEinbeziehen=1
    , @InputBufferEinbeziehen=1
    , @MaxSqlTextZeichen=0
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@SelfJson OUTPUT;
IF COALESCE(ISJSON(@SelfJson),0)<>1
    THROW 54111,N'USP_CurrentRequests JSON-Laufzeittest fehlgeschlagen.',1;
GO

-- Leichter Blocking-API-Test ohne Namens- oder Lockauflösung.
DECLARE @BlockingSelfSessionIds nvarchar(20)=CONVERT(nvarchar(20),@@SPID);
DECLARE @BlockingJson nvarchar(max);
EXEC [monitor].[USP_CurrentBlocking]
      @SessionIds=@BlockingSelfSessionIds
    , @BlockingObjektTiefe='NONE'
    , @MaxObjektAufloesungen=1
    , @MaxZeilen=1
    , @ResultSetArt='NONE'
    , @JsonErzeugen=1
    , @Json=@BlockingJson OUTPUT
    , @PrintMeldungen=0;
IF COALESCE(ISJSON(@BlockingJson),0)<>1
   OR JSON_VALUE(@BlockingJson,N'$.meta.schemaVersion')<>N'3'
   OR JSON_VALUE(@BlockingJson,N'$.meta.blockingObjectDepth')<>N'NONE'
   OR JSON_VALUE(@BlockingJson,N'$.meta.objectResolutionTimeoutCount')<>N'0'
   OR JSON_VALUE(@BlockingJson,N'$.meta.objectResolutionDeniedCount')<>N'0'
   OR JSON_VALUE(@BlockingJson,N'$.meta.objectResolutionErrorCount')<>N'0'
    THROW 54120,N'USP_CurrentBlocking Ressourcen-API-Vertrag fehlgeschlagen.',1;
GO

-- Blocking-Ressourcenparser: rein syntaktisch, keine DMV- oder Katalogzugriffe.
IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'OBJECT: 5:261575970:1')
    WHERE [ResourceType]=N'OBJECT' AND [DatabaseId]=5
      AND [EntityId]=261575970 AND [SubEntityId]=1 AND [ParseStatus]='PARSED'
)
    THROW 54112,N'OBJECT-Ressource wird nicht korrekt zerlegt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'KEY: 5:72057594044284928 (3300a4f361aa)')
    WHERE [ResourceType]=N'KEY' AND [DatabaseId]=5
      AND [EntityId]=72057594044284928 AND [ParseStatus]='PARSED'
)
    THROW 54113,N'KEY-Ressource wird nicht korrekt zerlegt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'RID: 5:1:104:3')
    WHERE [ResourceType]=N'RID' AND [DatabaseId]=5 AND [FileId]=1
      AND [PageId]=104 AND [RowId]=3 AND [ParseStatus]='PARSED'
)
    THROW 54114,N'RID-Ressource wird nicht korrekt zerlegt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'EXTENT: 5:1:112')
    WHERE [ResourceType]=N'EXTENT' AND [DatabaseId]=5 AND [FileId]=1
      AND [PageId]=112 AND [ParseStatus]='PARSED'
)
    THROW 54117,N'EXTENT-Ressource wird nicht korrekt zerlegt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'APPLICATION: 5:0:ExampleApplicationLock:(a1b2c3)')
    WHERE [ResourceType]=N'APPLICATION' AND [DatabaseId]=5
      AND [ResourceQualifier] LIKE N'5:0:ExampleApplicationLock:%'
      AND [ParseStatus]='PARTIAL'
)
    THROW 54118,N'APPLICATION-Ressource wird nicht korrekt klassifiziert.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'XACT: 5:12345:67890')
    WHERE [ResourceType]=N'XACT' AND [DatabaseId]=5
      AND [ResourceQualifier]=N'5:12345:67890' AND [ParseStatus]='PARTIAL'
)
    THROW 54119,N'XACT-Ressource wird nicht korrekt klassifiziert.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'OIB: 5:72057594044284928')
    WHERE [ResourceType]=N'OIB' AND [DatabaseId]=5
      AND [EntityId]=72057594044284928 AND [ParseStatus]='PARSED'
)
    THROW 54121,N'OIB-Ressource wird nicht korrekt zerlegt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'ROW_GROUP resource_description=ExampleOpaqueValue')
    WHERE [ResourceType]=N'ROW_GROUP' AND [FormatCode]='NAMED_RESOURCE'
      AND [ParseStatus]='RAW_ONLY'
)
    THROW 54122,N'ROW_GROUP-Ressource wird nicht verlustfrei klassifiziert.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource]
    (N'METADATA: database_id = 15 STATS(object_id = 2103950492, stats_id = 13), lockPartitionId = 0')
    WHERE [ResourceType]=N'METADATA' AND [MetadataSubtype]=N'STATS'
      AND [DatabaseId]=15 AND [EntityId]=2103950492 AND [SubEntityId]=13
      AND [ParseStatus]='PARSED'
)
    THROW 54115,N'METADATA-STATS-Ressource wird nicht korrekt zerlegt.',1;

IF NOT EXISTS
(
    SELECT 1
    FROM [monitor].[TVF_ParseBlockingResource](N'ACCESS_METHODS_HOBT (000001291E56F98)')
    WHERE [ResourceType]=N'ACCESS_METHODS_HOBT'
      AND [FormatCode]='NAMED_RESOURCE' AND [ParseStatus]='RAW_ONLY'
)
    THROW 54116,N'Benannte interne Ressource wird nicht verlustfrei klassifiziert.',1;
GO
