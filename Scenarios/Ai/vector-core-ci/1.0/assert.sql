USE [SqlServerLabAiVectorCore];
GO

DECLARE @Query vector(3) = '[1,0,0]';
DECLARE @FirstDocumentId int;

SELECT TOP (1) @FirstDocumentId = DocumentId
FROM dbo.Documents
ORDER BY VECTOR_DISTANCE('cosine', @Query, Embedding), DocumentId;

IF @FirstDocumentId <> 1
    THROW 51000, 'AI_VECTOR_CORE_TOP_K_ORDER_FAILED', 1;

IF ABS(VECTOR_DISTANCE('cosine', @Query, CAST('[1,0,0]' AS vector(3)))) > 0.000001
    THROW 51001, 'AI_VECTOR_CORE_DISTANCE_FAILED', 1;

DECLARE @ChunkCount int;
SELECT @ChunkCount = COUNT(*)
FROM AI_GENERATE_CHUNKS(
    SOURCE = N'Dieser synthetische Text prüft reproduzierbares Chunking in SQL Server 2025 ohne externe Daten.',
    CHUNK_TYPE = FIXED,
    CHUNK_SIZE = 24,
    OVERLAP = 4
);

IF @ChunkCount < 2
    THROW 51002, 'AI_VECTOR_CORE_CHUNK_COUNT_FAILED', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.Documents
    WHERE EmbeddingModelId <> 'fixed-vector-3'
       OR DatasetId <> 'synthetic-vector-core-de'
)
    THROW 51003, 'AI_VECTOR_CORE_IDENTITY_BINDING_FAILED', 1;
GO
