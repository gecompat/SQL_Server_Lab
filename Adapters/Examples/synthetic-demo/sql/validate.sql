-- Fachliche Validierung der synthetischen Demo-Installation.
-- Ein Fehler gilt als PROJECT_ASSERTION_FAILED.
SET NOCOUNT ON;

IF DB_ID(N'SyntheticDemo') IS NULL
BEGIN
    RAISERROR (N'Datenbank SyntheticDemo fehlt.', 16, 1);
    RETURN;
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM [SyntheticDemo].dbo.AdapterMarker
    WHERE ProjectId = N'synthetic-demo'
)
BEGIN
    RAISERROR (N'Ownership-Marker synthetic-demo fehlt in dbo.AdapterMarker.', 16, 1);
END;
GO
