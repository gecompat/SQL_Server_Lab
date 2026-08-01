-- Installiert die synthetische Demo-Datenbank mit Ownership-Marker.
SET NOCOUNT ON;

IF DB_ID(N'SyntheticDemo') IS NOT NULL
BEGIN
    RAISERROR (N'Datenbank SyntheticDemo existiert bereits. Zuerst cleanup.sql ausfuehren.', 16, 1);
    RETURN;
END;
GO

CREATE DATABASE [SyntheticDemo];
GO

USE [SyntheticDemo];
GO

CREATE TABLE dbo.AdapterMarker (
    MarkerId    int           NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    ProjectId   nvarchar(64)  NOT NULL,
    InstalledAt datetime2(0)  NOT NULL CONSTRAINT DF_AdapterMarker_InstalledAt DEFAULT (sysutcdatetime())
);
GO

INSERT INTO dbo.AdapterMarker (ProjectId)
VALUES (N'synthetic-demo');
GO
