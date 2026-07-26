SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_ID(N'Lab001Synthetic') IS NULL
BEGIN
    CREATE DATABASE [Lab001Synthetic]
    COLLATE SQL_Latin1_General_CP1_CS_AS;
END;

IF OBJECT_ID(N'Lab001Synthetic.dbo.SyntheticBaseline', N'U') IS NULL
BEGIN
    CREATE TABLE [Lab001Synthetic].[dbo].[SyntheticBaseline]
    (
          [SyntheticId] int NOT NULL
        , [SyntheticValue] nvarchar(64) NOT NULL
        , CONSTRAINT [PK_SyntheticBaseline]
          PRIMARY KEY CLUSTERED ([SyntheticId])
    );
END;

BEGIN TRANSACTION;

MERGE [Lab001Synthetic].[dbo].[SyntheticBaseline] AS [target]
USING
(
    SELECT
          [v].[SyntheticId]
        , CONCAT(N'SyntheticValue', [v].[SyntheticId]) AS [SyntheticValue]
    FROM
    (
        VALUES (1), (2), (3), (4), (5), (6), (7), (8)
    ) AS [v]([SyntheticId])
) AS [source]
  ON [source].[SyntheticId] = [target].[SyntheticId]
WHEN MATCHED THEN
    UPDATE SET [SyntheticValue] = [source].[SyntheticValue]
WHEN NOT MATCHED THEN
    INSERT ([SyntheticId], [SyntheticValue])
    VALUES ([source].[SyntheticId], [source].[SyntheticValue]);

COMMIT TRANSACTION;

IF (SELECT COUNT_BIG(*) FROM [Lab001Synthetic].[dbo].[SyntheticBaseline]) <> 8
    THROW 55001, N'LAB-BASE-001 synthetic row-count assertion failed.', 1;

DECLARE @OverviewJson nvarchar(max);

EXEC [LabAnalyze].[monitor].[USP_CurrentOverview]
      @DatabaseNames = N'[Lab001Synthetic]'
    , @MitWaits = 0
    , @MitTransactions = 0
    , @MitMemoryGrants = 0
    , @MitTempDB = 0
    , @MitIO = 0
    , @MitLog = 0
    , @SampleSeconds = 0
    , @MaxZeilen = 25
    , @ResultSetArt = 'NONE'
    , @JsonErzeugen = 1
    , @Json = @OverviewJson OUTPUT
    , @PrintMeldungen = 0;

IF COALESCE(ISJSON(@OverviewJson), 0) <> 1
    THROW 55002, N'LAB-BASE-001 did not receive valid JSON.', 1;

IF JSON_VALUE(@OverviewJson, N'$.meta.statusCode')
   NOT IN (N'AVAILABLE', N'AVAILABLE_LIMITED')
    THROW 55003, N'LAB-BASE-001 returned an unexpected status.', 1;

IF JSON_QUERY(@OverviewJson, N'$.moduleStatus') IS NULL
    THROW 55004, N'LAB-BASE-001 module-status contract is missing.', 1;

SELECT CONCAT
(
      N'LAB_ASSERTION_JSON='
    , (
        SELECT
              N'LAB-BASE-001' AS [ScenarioId]
            , N'PASS' AS [Status]
            , JSON_VALUE(@OverviewJson, N'$.meta.statusCode') AS [AnalyzerStatus]
            , JSON_QUERY(N'["BASELINE_OUTPUT_VALID"]') AS [FindingCodes]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
      )
);
