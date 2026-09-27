-- Execute only in the acceptance runner's own database after registration.
SET NOCOUNT ON;
DECLARE @actual TABLE(id int, doubled int, runtimeMajor int, appContainer int, workerPid int);
INSERT INTO @actual
EXEC sys.sp_execute_external_script
    @language=N'dotnet',
    @script=N'SqlServerLab.CSharpProbe;SqlServerLab.Acceptance.Probe',
    @input_data_1=N'SELECT id FROM (VALUES (-7),(0),(21)) AS sample(id)',
    @params=N'';
IF (SELECT COUNT(*) FROM @actual) <> 3
    THROW 51000, 'CSHARP_PROBE_ROW_COUNT', 1;
IF EXISTS (SELECT id, doubled FROM @actual EXCEPT SELECT id, doubled FROM (VALUES (-7,-14),(0,0),(21,42)) AS expected(id,doubled))
    OR EXISTS (SELECT id, doubled FROM (VALUES (-7,-14),(0,0),(21,42)) AS expected(id,doubled) EXCEPT SELECT id, doubled FROM @actual)
    THROW 51000, 'CSHARP_PROBE_ROUNDTRIP', 1;
IF EXISTS (SELECT 1 FROM @actual WHERE runtimeMajor IS NULL OR runtimeMajor<>8
    OR appContainer IS NULL OR appContainer<>1 OR workerPid IS NULL OR workerPid<=0)
    THROW 51000, 'CSHARP_PROBE_WORKER_CONTRACT', 1;
SELECT N'CSHARP_SQL_ROUNDTRIP_OK' AS Result;
