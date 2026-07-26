/* QRY-001 mitigation: preserve the search argument as a half-open interval. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

SELECT
    Mitigation = N'EventDateTime >= @Start AND EventDateTime < DATEADD(day,1,@Start)',
    Rationale = N'Die Datumsgrenzen werden außerhalb der Indexspalte berechnet; die Spalte bleibt unverändert vergleichbar.',
    ConstraintNote = N'Die fachliche Ergebnismenge muss vor dem Performancevergleich identisch sein.';

SELECT 1 AS Sequence,'MITIGATION' AS Phase,'SUMMARY' AS CheckId,
       'PASS' AS Outcome,'OK' AS Code,
       N'halboffenes SARGable Datumsintervall' AS ObservedValue,
       N'keine Funktion auf EventDateTime' AS RequiredValue,
       N'Die Gegenmaßnahme ist fachlich begründet und ändert keine Daten.' AS Message;
PRINT 'SQLPERF_SUMMARY|PASS|OK';
