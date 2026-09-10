SET NOCOUNT ON;
IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 17
    THROW 51000, 'ANN_SQL2025_REQUIRED', 1;
CREATE TABLE dbo.AnnDocuments
(
    DocumentId int NOT NULL PRIMARY KEY CLUSTERED,
    BucketId int NOT NULL,
    Embedding vector(32) NOT NULL
);
INSERT dbo.AnnDocuments(DocumentId, BucketId, Embedding)
SELECT n.value, n.value % 3,
    CAST('[' + STRING_AGG(CONVERT(varchar(max), CONVERT(real,
        SIN(n.value * d.value * 0.137) + COS(n.value * 0.071 + d.value * 0.19)), 3), ',')
        WITHIN GROUP (ORDER BY d.value) + ']' AS vector(32))
FROM GENERATE_SERIES(1, 4096) AS n
CROSS JOIN GENERATE_SERIES(1, 32) AS d
GROUP BY n.value;
DECLARE @started datetime2 = SYSDATETIME();
CREATE VECTOR INDEX IX_AnnDocuments_Embedding ON dbo.AnnDocuments(Embedding)
WITH (METRIC = 'cosine', TYPE = 'diskann', MAXDOP = 2);
IF (SELECT COUNT(*) FROM sys.vector_indexes WHERE object_id = OBJECT_ID('dbo.AnnDocuments')) <> 1
    THROW 51000, 'ANN_INDEX_NOT_CREATED', 1;
SELECT CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')) AS SqlBuild,
    (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()) AS CompatibilityLevel,
    (SELECT JSON_VALUE(build_parameters, '$.Version') FROM sys.vector_indexes
        WHERE object_id = OBJECT_ID('dbo.AnnDocuments')) AS IndexVersion,
    DATEDIFF_BIG(microsecond, @started, SYSDATETIME()) AS BuildMicroseconds,
    (SELECT COUNT(*) FROM dbo.AnnDocuments) AS [RowCount]
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
