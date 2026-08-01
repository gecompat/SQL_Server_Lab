-- Entfernt ausschliesslich projekteigene Objekte des synthetischen Adapters.
-- Es wird nur eine Datenbank entfernt, die den eigenen Ownership-Marker traegt.
SET NOCOUNT ON;

IF DB_ID(N'SyntheticDemo') IS NULL
BEGIN
    PRINT N'Datenbank SyntheticDemo ist nicht vorhanden; nichts zu bereinigen.';
    RETURN;
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM [SyntheticDemo].dbo.AdapterMarker
    WHERE ProjectId = N'synthetic-demo'
)
BEGIN
    RAISERROR (N'SyntheticDemo traegt keinen synthetic-demo-Marker und wird nicht entfernt.', 16, 1);
    RETURN;
END;
GO

ALTER DATABASE [SyntheticDemo] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

DROP DATABASE [SyntheticDemo];
GO
