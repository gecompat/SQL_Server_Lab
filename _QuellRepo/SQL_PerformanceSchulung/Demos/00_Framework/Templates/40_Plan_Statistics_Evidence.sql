/*
    FWK-005 reference template
    Reads statistics metadata and histogram data from the current,
    FWK-002-marked test database and optionally returns Actual Showplan XML.

    The script persists no plan or statistics export.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DemoId varchar(7) = 'QRY-001';
DECLARE @RunToken varchar(20) = 'LOCAL';
DECLARE @SchemaName sysname = N'lab';
DECLARE @ObjectName sysname = N'SyntheticFact';
DECLARE @StatisticsName sysname = N'PK_lab_SyntheticFact';
DECLARE @ReferenceSkewKey int = 1;
DECLARE @EmitActualPlan bit = 1;

DECLARE @ProjectMarker nvarchar(128);
DECLARE @ContractMarker nvarchar(128);
DECLARE @MarkerDemoId varchar(7);
DECLARE @MarkerRunToken varchar(20);
DECLARE @ObjectId int;
DECLARE @StatsId int;
DECLARE @HasShowplan int;

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
   OR @ProjectMarker <> N'SQL_PerformanceSchulung'
   OR @ContractMarker <> N'1.0'
   OR @MarkerDemoId <> @DemoId
   OR @MarkerRunToken <> @RunToken
    THROW 51001, 'FAIL_SAFETY: FWK-005 wurde außerhalb des erwarteten markierten Demo-Kontexts aufgerufen.', 1;

SELECT
    @ObjectId = o.object_id
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
    ON s.schema_id = o.schema_id
WHERE s.name = @SchemaName
  AND o.name = @ObjectName
  AND o.type = 'U';

IF @ObjectId IS NULL
    THROW 51002, 'FAIL_STATE: Das Zielobjekt für die Statistikevidenz ist nicht vorhanden.', 1;

SELECT
    @StatsId = st.stats_id
FROM sys.stats AS st
WHERE st.object_id = @ObjectId
  AND st.name = @StatisticsName;

IF @StatsId IS NULL
    THROW 51002, 'FAIL_STATE: Die angeforderte Statistik ist nicht vorhanden oder nicht sichtbar.', 1;

SELECT
    Sequence = CONVERT(int, 1),
    Phase = CONVERT(varchar(20), 'EVIDENCE'),
    CheckId = CONVERT(varchar(64), 'STATISTICS_METADATA'),
    Outcome = CONVERT(varchar(8), 'PASS'),
    Code = CONVERT(varchar(64), 'OK'),
    ObservedValue = CONVERT
    (
        nvarchar(4000),
        CONCAT(N'Object=', @SchemaName, N'.', @ObjectName, N'; Statistics=', @StatisticsName)
    ),
    RequiredValue = CONVERT(nvarchar(4000), N'vorhandene Statistik in markierter Testdatenbank'),
    Message = CONVERT(nvarchar(4000), N'Die Statistik wurde aufgelöst.');

SELECT
    SchemaName = sc.name,
    ObjectName = o.name,
    StatisticsName = st.name,
    st.stats_id,
    st.auto_created,
    st.user_created,
    st.no_recompute,
    st.has_filter,
    st.filter_definition,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.steps,
    sp.unfiltered_rows,
    sp.modification_counter,
    sp.persisted_sample_percent
FROM sys.stats AS st
INNER JOIN sys.objects AS o
    ON o.object_id = st.object_id
INNER JOIN sys.schemas AS sc
    ON sc.schema_id = o.schema_id
OUTER APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
WHERE st.object_id = @ObjectId
  AND st.stats_id = @StatsId;

SELECT
    hist.step_number,
    hist.range_high_key,
    hist.range_rows,
    hist.equal_rows,
    hist.distinct_range_rows,
    hist.average_range_rows
FROM sys.dm_db_stats_histogram(@ObjectId, @StatsId) AS hist
ORDER BY hist.step_number;

SET @HasShowplan = HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'SHOWPLAN');

IF @EmitActualPlan = 0
BEGIN
    SELECT
        Sequence = CONVERT(int, 2),
        Phase = CONVERT(varchar(20), 'EVIDENCE'),
        CheckId = CONVERT(varchar(64), 'ACTUAL_PLAN'),
        Outcome = CONVERT(varchar(8), 'SKIP'),
        Code = CONVERT(varchar(64), 'SKIP_CONFIGURATION'),
        ObservedValue = CONVERT(nvarchar(4000), N'EmitActualPlan=0'),
        RequiredValue = CONVERT(nvarchar(4000), N'EmitActualPlan=1'),
        Message = CONVERT(nvarchar(4000), N'Die Actual-Plan-Ausgabe wurde durch die Vorlage deaktiviert.');
END
ELSE IF COALESCE(@HasShowplan, 0) <> 1
BEGIN
    SELECT
        Sequence = CONVERT(int, 2),
        Phase = CONVERT(varchar(20), 'EVIDENCE'),
        CheckId = CONVERT(varchar(64), 'ACTUAL_PLAN'),
        Outcome = CONVERT(varchar(8), 'SKIP'),
        Code = CONVERT(varchar(64), 'SKIP_PERMISSION'),
        ObservedValue = CONVERT(nvarchar(4000), N'SHOWPLAN nicht verfügbar'),
        RequiredValue = CONVERT(nvarchar(4000), N'SHOWPLAN'),
        Message = CONVERT(nvarchar(4000), N'Die planabhängige Referenzabfrage wurde nicht ausgeführt.');
END
ELSE
BEGIN
    SELECT
        Sequence = CONVERT(int, 2),
        Phase = CONVERT(varchar(20), 'EVIDENCE'),
        CheckId = CONVERT(varchar(64), 'ACTUAL_PLAN'),
        Outcome = CONVERT(varchar(8), 'PASS'),
        Code = CONVERT(varchar(64), 'OK'),
        ObservedValue = CONVERT(nvarchar(4000), N'STATISTICS XML aktiviert'),
        RequiredValue = CONVERT(nvarchar(4000), N'Actual Showplan XML für synthetische Referenzabfrage'),
        Message = CONVERT(nvarchar(4000), N'Die folgende Abfrage gibt Resultat und Actual Showplan XML interaktiv aus.');

    BEGIN TRY
        SET STATISTICS XML ON;

        SELECT
            MatchingRows = COUNT_BIG(*),
            MeasureTotal = SUM(sf.MeasureValue)
        FROM lab.SyntheticFact AS sf
        WHERE sf.SkewKey = @ReferenceSkewKey
        OPTION (RECOMPILE, MAXDOP 1);

        SET STATISTICS XML OFF;
    END TRY
    BEGIN CATCH
        SET STATISTICS XML OFF;

        DECLARE @ErrorMessage nvarchar(2048) =
            CONCAT
            (
                N'FAIL_EXECUTION: Die Actual-Plan-Referenzabfrage ist fehlgeschlagen. SQL-Fehler ',
                ERROR_NUMBER(),
                N': ',
                LEFT(ERROR_MESSAGE(), 1700)
            );

        THROW 51003, @ErrorMessage, 1;
    END CATCH;
END;
