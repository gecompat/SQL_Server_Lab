SET NOCOUNT ON;
IF (SELECT COUNT(*) FROM dbo.AnnDocuments) <> 4096
    THROW 51000, 'ANN_DATASET_COUNT_INVALID', 1;
DECLARE @parameters nvarchar(max) = (SELECT build_parameters FROM sys.vector_indexes
    WHERE object_id = OBJECT_ID('dbo.AnnDocuments'));
DECLARE @reportedVersion nvarchar(40) = JSON_VALUE(@parameters, '$.Version');
-- SQL 2025 Build 17.0.4075.5 meldet StartId/L/M/R ohne numerisches Version-Feld.
-- Die Form bleibt explizit unversioniert; keine erfundene Indexversionsnummer.
IF @parameters IS NULL OR
    (@reportedVersion IS NOT NULL AND @reportedVersion NOT IN ('1','2')) OR
    (@reportedVersion IS NULL AND (
        CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 17 OR
        ISNULL(TRY_CONVERT(int, JSON_VALUE(@parameters, '$.L')), 0) <= 0 OR
        ISNULL(TRY_CONVERT(int, JSON_VALUE(@parameters, '$.M')), 0) <= 0 OR
        ISNULL(TRY_CONVERT(int, JSON_VALUE(@parameters, '$.R')), 0) <= 0 OR
        ISNULL(TRY_CONVERT(int, JSON_VALUE(@parameters, '$.StartId')), 0) <= 0 OR
        EXISTS(SELECT 1 FROM OPENJSON(@parameters) WHERE [key] NOT IN ('StartId','L','M','R'))))
    THROW 51000, 'ANN_TEST_VERSION_UPDATE_REQUIRED', 1;
DECLARE @indexVersion nvarchar(40) = COALESCE(@reportedVersion, 'sql2025-unversioned');
DECLARE @results TABLE(QueryId int, RecallAt10 float, ExactMicroseconds bigint, AnnMicroseconds bigint, FilteredCount int);
DECLARE @queries TABLE(QueryId int PRIMARY KEY);
INSERT @queries VALUES(137),(997),(2049),(3331);
DECLARE @queryId int, @query vector(32), @started datetime2, @exactUs bigint, @annUs bigint;
DECLARE @exact TABLE(DocumentId int PRIMARY KEY);
DECLARE @approx TABLE(DocumentId int PRIMARY KEY, Distance float);
DECLARE @filtered TABLE(DocumentId int PRIMARY KEY, BucketId int);
DECLARE query_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT QueryId FROM @queries ORDER BY QueryId;
OPEN query_cursor;
FETCH NEXT FROM query_cursor INTO @queryId;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @query = Embedding FROM dbo.AnnDocuments WHERE DocumentId = @queryId;
    DELETE @exact; DELETE @approx; DELETE @filtered;
    SET @started = SYSDATETIME();
    INSERT @exact SELECT TOP(10) DocumentId FROM dbo.AnnDocuments
        ORDER BY VECTOR_DISTANCE('cosine', Embedding, @query), DocumentId;
    SET @exactUs = DATEDIFF_BIG(microsecond, @started, SYSDATETIME());
    SET @started = SYSDATETIME();
    INSERT @approx SELECT t.DocumentId, s.distance
        FROM VECTOR_SEARCH(TABLE = dbo.AnnDocuments AS t, COLUMN = Embedding,
            SIMILAR_TO = @query, METRIC = 'cosine', TOP_N = 10) AS s;
    SET @annUs = DATEDIFF_BIG(microsecond, @started, SYSDATETIME());
    IF (SELECT COUNT(*) FROM @approx) <> 10 OR
        NOT EXISTS(SELECT 1 FROM @approx WHERE DocumentId = @queryId AND ABS(Distance) < 0.0001)
        THROW 51000, 'ANN_TOP10_OR_SELF_MATCH_FAILED', 1;
    IF EXISTS(SELECT 1 FROM @approx AS a JOIN dbo.AnnDocuments AS d ON d.DocumentId = a.DocumentId
        WHERE ABS(a.Distance - VECTOR_DISTANCE('cosine', d.Embedding, @query)) > 0.0001)
        THROW 51000, 'ANN_DISTANCE_MISMATCH', 1;
    DECLARE @recall float = (SELECT COUNT(*) / 10.0 FROM @approx a INNER JOIN @exact e ON a.DocumentId=e.DocumentId);
    IF @recall < 0.8 THROW 51000, 'ANN_RECALL_BELOW_0_8', 1;
    INSERT @filtered SELECT t.DocumentId, t.BucketId
        FROM VECTOR_SEARCH(TABLE = dbo.AnnDocuments AS t, COLUMN = Embedding,
            SIMILAR_TO = @query, METRIC = 'cosine', TOP_N = 30) AS s
        WHERE t.BucketId = 1;
    IF EXISTS(SELECT 1 FROM @filtered WHERE BucketId <> 1) OR
        NOT EXISTS(SELECT 1 FROM @filtered)
        THROW 51000, 'ANN_FILTER_FAILED', 1;
    INSERT @results SELECT @queryId, @recall, @exactUs, @annUs, COUNT(*) FROM @filtered;
    FETCH NEXT FROM query_cursor INTO @queryId;
END;
CLOSE query_cursor; DEALLOCATE query_cursor;
SELECT @indexVersion AS IndexVersion,
    (SELECT COUNT(*) FROM @results) AS QueryCount,
    (SELECT MIN(RecallAt10) FROM @results) AS MinimumRecallAt10,
    JSON_QUERY((SELECT * FROM @results ORDER BY QueryId FOR JSON PATH)) AS Queries
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
