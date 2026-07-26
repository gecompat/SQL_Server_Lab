/*
    FWK-003 reference implementation
    Installs a deterministic synthetic data generator in the current,
    FWK-002-marked test database.

    The script creates objects only in the current test database.
    It never creates or drops a database and never changes instance options.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_ID() <= 4
    THROW 51001, 'FAIL_SAFETY: FWK-003 darf nicht in einer Systemdatenbank installiert werden.', 1;

DECLARE @ProjectMarker nvarchar(128);
DECLARE @ContractMarker nvarchar(128);

SELECT
    @ProjectMarker = MAX(CASE WHEN ep.name = N'SQLPERF.Project' THEN CONVERT(nvarchar(128), ep.value) END),
    @ContractMarker = MAX(CASE WHEN ep.name = N'SQLPERF.ContractVersion' THEN CONVERT(nvarchar(128), ep.value) END)
FROM sys.extended_properties AS ep
WHERE ep.class = 0
  AND ep.major_id = 0
  AND ep.minor_id = 0
  AND ep.name IN (N'SQLPERF.Project', N'SQLPERF.ContractVersion');

IF @ProjectMarker <> N'SQL_PerformanceSchulung'
   OR @ContractMarker <> N'1.0'
    THROW 51001, 'FAIL_SAFETY: Die aktuelle Datenbank besitzt nicht die erwarteten FWK-002-Marker.', 1;

IF SCHEMA_ID(N'lab') IS NULL
    EXEC(N'CREATE SCHEMA [lab] AUTHORIZATION [dbo];');
GO

IF OBJECT_ID(N'lab.SyntheticFact', N'U') IS NULL
BEGIN
    CREATE TABLE lab.SyntheticFact
    (
        SyntheticFactId bigint NOT NULL,
        UniformKey int NOT NULL,
        SkewKey int NOT NULL,
        CorrelationKey int NOT NULL,
        EventDate date NOT NULL,
        MeasureValue decimal(19,4) NOT NULL,
        Payload varchar(4000) NOT NULL,
        CONSTRAINT PK_lab_SyntheticFact
            PRIMARY KEY CLUSTERED (SyntheticFactId)
    );
END;
GO

IF OBJECT_ID(N'lab.SyntheticGeneratorManifest', N'U') IS NULL
BEGIN
    CREATE TABLE lab.SyntheticGeneratorManifest
    (
        ManifestId bigint IDENTITY(1,1) NOT NULL,
        GeneratedAtUtc datetime2(3) NOT NULL,
        DemoId varchar(7) NOT NULL,
        RunToken varchar(20) NOT NULL,
        [RowCount] int NOT NULL,
        Seed int NOT NULL,
        DistinctKeys int NOT NULL,
        SkewPercent tinyint NOT NULL,
        HotKeyPercent tinyint NOT NULL,
        CorrelationPercent tinyint NOT NULL,
        PayloadBytes smallint NOT NULL,
        StartDate date NOT NULL,
        DateSpanDays int NOT NULL,
        ActualRows bigint NOT NULL,
        DistinctUniformKeys int NOT NULL,
        DistinctSkewKeys int NOT NULL,
        DataFingerprint int NULL,
        CONSTRAINT PK_lab_SyntheticGeneratorManifest
            PRIMARY KEY CLUSTERED (ManifestId)
    );
END;
GO

CREATE OR ALTER PROCEDURE lab.USP_GenerateSyntheticData
    @DemoId varchar(7),
    @RunToken varchar(20),
    @RowCount int,
    @Seed int = 1,
    @DistinctKeys int = 1000,
    @SkewPercent tinyint = 80,
    @HotKeyPercent tinyint = 20,
    @CorrelationPercent tinyint = 80,
    @PayloadBytes smallint = 100,
    @StartDate date = '20200101',
    @DateSpanDays int = 3650,
    @ResetExistingData bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProjectMarker nvarchar(128);
    DECLARE @ContractMarker nvarchar(128);
    DECLARE @MarkerDemoId varchar(7);
    DECLARE @MarkerRunToken varchar(20);
    DECLARE @HotKeyCount int;
    DECLARE @ColdKeyCount int;
    DECLARE @ActualRows bigint;
    DECLARE @DistinctUniformKeys int;
    DECLARE @DistinctSkewKeys int;
    DECLARE @Fingerprint int;

    SELECT
        @ProjectMarker = MAX(CASE WHEN ep.name = N'SQLPERF.Project' THEN CONVERT(nvarchar(128), ep.value) END),
        @ContractMarker = MAX(CASE WHEN ep.name = N'SQLPERF.ContractVersion' THEN CONVERT(nvarchar(128), ep.value) END),
        @MarkerDemoId = MAX(CASE WHEN ep.name = N'SQLPERF.DemoId' THEN CONVERT(varchar(7), ep.value) END),
        @MarkerRunToken = MAX(CASE WHEN ep.name = N'SQLPERF.RunToken' THEN CONVERT(varchar(20), ep.value) END)
    FROM sys.extended_properties AS ep
    WHERE ep.class = 0
      AND ep.major_id = 0
      AND ep.minor_id = 0
      AND ep.name IN
          (
              N'SQLPERF.Project',
              N'SQLPERF.ContractVersion',
              N'SQLPERF.DemoId',
              N'SQLPERF.RunToken'
          );

    IF DB_ID() <= 4
        THROW 51001, 'FAIL_SAFETY: FWK-003 darf nicht in einer Systemdatenbank ausgeführt werden.', 1;

    IF @ProjectMarker <> N'SQL_PerformanceSchulung'
       OR @ContractMarker <> N'1.0'
       OR @MarkerDemoId <> @DemoId
       OR @MarkerRunToken <> @RunToken
        THROW 51001, 'FAIL_SAFETY: Die Datenbankmarker stimmen nicht vollständig mit Demo-ID und Run-Token überein.', 1;

    IF LEN(@DemoId) <> 7
       OR @DemoId NOT LIKE '[A-Z][A-Z][A-Z]-[0-9][0-9][0-9]'
       OR LEFT(@DemoId, 3) NOT IN ('STL', 'OPT', 'QRY', 'IDX', 'CON', 'RES', 'DGN')
        THROW 51000, 'FAIL_CONTRACT: Die Demo-ID ist nicht kanonisch.', 1;

    IF @RunToken IS NULL
       OR LEN(@RunToken) NOT BETWEEN 1 AND 20
       OR @RunToken COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Z0-9_]%'
        THROW 51000, 'FAIL_CONTRACT: Der Run-Token muss 1 bis 20 Zeichen aus A-Z, 0-9 oder Unterstrich enthalten.', 1;

    IF @RowCount NOT BETWEEN 1 AND 10000000
        THROW 51000, 'FAIL_CONTRACT: RowCount muss zwischen 1 und 10000000 liegen.', 1;

    IF @DistinctKeys < 2
       OR @DistinctKeys > @RowCount
       OR @DistinctKeys > 1000000
        THROW 51000, 'FAIL_CONTRACT: DistinctKeys muss zwischen 2 und MIN(RowCount, 1000000) liegen.', 1;

    IF @SkewPercent > 100
       OR @HotKeyPercent NOT BETWEEN 1 AND 100
       OR @CorrelationPercent > 100
       OR @PayloadBytes NOT BETWEEN 0 AND 4000
       OR @DateSpanDays NOT BETWEEN 1 AND 36500
       OR @StartDate IS NULL
        THROW 51000, 'FAIL_CONTRACT: Mindestens ein Verteilungsparameter liegt außerhalb des zulässigen Bereichs.', 1;

    IF @ResetExistingData = 0
       AND EXISTS (SELECT 1 FROM lab.SyntheticFact)
        THROW 51002, 'FAIL_STATE: SyntheticFact enthält bereits Daten und ResetExistingData ist deaktiviert.', 1;

    SET @HotKeyCount =
        CASE
            WHEN @SkewPercent = 0 THEN @DistinctKeys
            ELSE CONVERT(int, CEILING(CONVERT(decimal(19,6), @DistinctKeys) * @HotKeyPercent / 100.0))
        END;

    IF @HotKeyCount < 1
        SET @HotKeyCount = 1;
    IF @HotKeyCount > @DistinctKeys
        SET @HotKeyCount = @DistinctKeys;

    SET @ColdKeyCount = @DistinctKeys - @HotKeyCount;

    BEGIN TRY
        BEGIN TRANSACTION;

        TRUNCATE TABLE lab.SyntheticFact;
        DELETE FROM lab.SyntheticGeneratorManifest;

        ;WITH
        Digits AS
        (
            SELECT n
            FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS d(n)
        ),
        Numbers AS
        (
            SELECT
                n = CONVERT(bigint,
                      1
                    + d0.n
                    + d1.n * 10
                    + d2.n * 100
                    + d3.n * 1000
                    + d4.n * 10000
                    + d5.n * 100000
                    + d6.n * 1000000)
            FROM Digits AS d0
            CROSS JOIN Digits AS d1
            CROSS JOIN Digits AS d2
            CROSS JOIN Digits AS d3
            CROSS JOIN Digits AS d4
            CROSS JOIN Digits AS d5
            CROSS JOIN Digits AS d6
        ),
        Hashes AS
        (
            SELECT
                n,
                HashA = (
                    n * CONVERT(bigint, 1103515245)
                    + ABS(CONVERT(bigint, @Seed)) * CONVERT(bigint, 12345)
                    + CONVERT(bigint, 1013904223)
                ) % CONVERT(bigint, 2147483647),
                HashB = (
                    n * CONVERT(bigint, 214013)
                    + ABS(CONVERT(bigint, @Seed)) * CONVERT(bigint, 2531011)
                    + CONVERT(bigint, 1376312589)
                ) % CONVERT(bigint, 2147483629),
                HashC = (
                    n * CONVERT(bigint, 48271)
                    + ABS(CONVERT(bigint, @Seed)) * CONVERT(bigint, 69621)
                    + CONVERT(bigint, 1234567)
                ) % CONVERT(bigint, 2147483587),
                HashD = (
                    n * CONVERT(bigint, 16807)
                    + ABS(CONVERT(bigint, @Seed)) * CONVERT(bigint, 32719)
                    + CONVERT(bigint, 7654321)
                ) % CONVERT(bigint, 2147483563)
            FROM Numbers
            WHERE n <= @RowCount
        ),
        Derived AS
        (
            SELECT
                n,
                UniformKey = CONVERT(int, HashA % @DistinctKeys) + 1,
                IndependentKey = CONVERT(int, HashB % @DistinctKeys) + 1,
                SkewKey =
                    CASE
                        WHEN @SkewPercent = 0 OR @HotKeyCount = @DistinctKeys
                            THEN CONVERT(int, HashB % @DistinctKeys) + 1
                        WHEN HashC % 100 < @SkewPercent
                            THEN CONVERT(int, HashB % @HotKeyCount) + 1
                        ELSE @HotKeyCount + CONVERT(int, HashB % NULLIF(@ColdKeyCount, 0)) + 1
                    END,
                Correlate =
                    CASE WHEN HashD % 100 < @CorrelationPercent THEN 1 ELSE 0 END,
                EventOffset = CONVERT(int, HashC % @DateSpanDays),
                MeasureRaw = CONVERT(bigint, HashD % 1000000)
            FROM Hashes
        )
        INSERT lab.SyntheticFact
        (
            SyntheticFactId,
            UniformKey,
            SkewKey,
            CorrelationKey,
            EventDate,
            MeasureValue,
            Payload
        )
        SELECT
            SyntheticFactId = n,
            UniformKey,
            SkewKey,
            CorrelationKey =
                CASE WHEN Correlate = 1 THEN UniformKey ELSE IndependentKey END,
            EventDate = DATEADD(day, EventOffset, @StartDate),
            MeasureValue = CONVERT(decimal(19,4), MeasureRaw) / 100.0,
            Payload = CONVERT(varchar(4000), REPLICATE(CHAR(65 + CONVERT(int, n % 26)), @PayloadBytes))
        FROM Derived
        OPTION (MAXDOP 1);

        SELECT
            @ActualRows = COUNT_BIG(*),
            @DistinctUniformKeys = COUNT(DISTINCT UniformKey),
            @DistinctSkewKeys = COUNT(DISTINCT SkewKey),
            @Fingerprint = CHECKSUM_AGG
            (
                BINARY_CHECKSUM
                (
                    SyntheticFactId,
                    UniformKey,
                    SkewKey,
                    CorrelationKey,
                    EventDate,
                    MeasureValue,
                    DATALENGTH(Payload)
                )
            )
        FROM lab.SyntheticFact;

        IF @ActualRows <> @RowCount
            THROW 51003, 'FAIL_EXECUTION: Die erzeugte Zeilenanzahl entspricht nicht RowCount.', 1;

        INSERT lab.SyntheticGeneratorManifest
        (
            GeneratedAtUtc,
            DemoId,
            RunToken,
            [RowCount],
            Seed,
            DistinctKeys,
            SkewPercent,
            HotKeyPercent,
            CorrelationPercent,
            PayloadBytes,
            StartDate,
            DateSpanDays,
            ActualRows,
            DistinctUniformKeys,
            DistinctSkewKeys,
            DataFingerprint
        )
        VALUES
        (
            SYSUTCDATETIME(),
            @DemoId,
            @RunToken,
            @RowCount,
            @Seed,
            @DistinctKeys,
            @SkewPercent,
            @HotKeyPercent,
            @CorrelationPercent,
            @PayloadBytes,
            @StartDate,
            @DateSpanDays,
            @ActualRows,
            @DistinctUniformKeys,
            @DistinctSkewKeys,
            @Fingerprint
        );

        COMMIT TRANSACTION;

        SELECT
            Phase = CONVERT(varchar(20), 'SETUP'),
            CheckId = CONVERT(varchar(64), 'SYNTHETIC_DATA'),
            Outcome = CONVERT(varchar(8), 'PASS'),
            Code = CONVERT(varchar(64), 'OK'),
            GeneratedRows = @ActualRows,
            DistinctUniformKeys = @DistinctUniformKeys,
            DistinctSkewKeys = @DistinctSkewKeys,
            PayloadBytes = @PayloadBytes,
            DataFingerprint = @Fingerprint,
            Message = CONVERT(nvarchar(4000), N'Die synthetischen Daten wurden deterministisch erzeugt.');
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        IF ERROR_NUMBER() BETWEEN 51000 AND 51004
            THROW;

        DECLARE @OriginalErrorMessage nvarchar(2048) = ERROR_MESSAGE();
        DECLARE @ErrorMessage nvarchar(2048) =
            CONCAT
            (
                N'FAIL_EXECUTION: FWK-003 wurde abgebrochen. SQL-Fehler ',
                ERROR_NUMBER(),
                N': ',
                LEFT(@OriginalErrorMessage, 1700)
            );

        THROW 51003, @ErrorMessage, 1;
    END CATCH;
END;
GO
