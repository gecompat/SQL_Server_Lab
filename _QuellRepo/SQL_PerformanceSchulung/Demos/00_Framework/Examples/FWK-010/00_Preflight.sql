/* Synthetic FWK-010 smoke preflight. No state change. */
SET NOCOUNT ON;

SELECT
    Sequence = 1,
    Phase = 'PREFLIGHT',
    CheckId = 'SUMMARY',
    Outcome = 'PASS',
    Code = 'OK',
    ObservedValue = CONVERT(nvarchar(4000), N'synthetischer Smoke-Test'),
    RequiredValue = CONVERT(nvarchar(4000), N'strukturierte Summary'),
    Message = CONVERT(nvarchar(4000), N'Der Runtime-Harness kann die Summary auswerten.');

PRINT 'SQLPERF_SUMMARY|PASS|OK';
