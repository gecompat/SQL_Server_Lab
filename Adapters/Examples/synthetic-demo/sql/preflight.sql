-- Read-only Preflight des synthetischen Demo-Adapters.
-- Prueft nur Erreichbarkeit und Version; veraendert keinen Zustand.
SET NOCOUNT ON;

SELECT
    SERVERPROPERTY('ProductMajorVersion') AS ProductMajorVersion,
    SERVERPROPERTY('Edition')             AS Edition;
GO
