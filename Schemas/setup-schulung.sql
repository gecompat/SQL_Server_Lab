-- Setup-Skript fuer SchulungsDB (PostProvision)
-- Wird automatisch nach Datenbank-Erstellung ausgefuehrt

CREATE TABLE dbo.Kunden (
    KundenId    INT IDENTITY(1,1) PRIMARY KEY,
    Vorname     NVARCHAR(50) NOT NULL,
    Nachname    NVARCHAR(50) NOT NULL,
    Email       NVARCHAR(100),
    Erstellt    DATETIME2 DEFAULT GETDATE()
);
GO

CREATE TABLE dbo.Bestellungen (
    BestellId   INT IDENTITY(1,1) PRIMARY KEY,
    KundenId    INT NOT NULL REFERENCES dbo.Kunden(KundenId),
    Betrag      DECIMAL(10,2) NOT NULL,
    Status      NVARCHAR(20) DEFAULT 'Offen',
    BestellDatum DATETIME2 DEFAULT GETDATE()
);
GO

CREATE INDEX IX_Bestellungen_KundenId ON dbo.Bestellungen(KundenId);
GO

-- Beispieldaten
INSERT INTO dbo.Kunden (Vorname, Nachname, Email) VALUES
    ('Max', 'Mustermann', 'max@example.com'),
    ('Anna', 'Schmidt', 'anna@example.com'),
    ('Peter', 'Huber', 'peter@example.com');
GO

INSERT INTO dbo.Bestellungen (KundenId, Betrag, Status) VALUES
    (1, 199.99, 'Abgeschlossen'),
    (1, 49.50, 'Offen'),
    (2, 350.00, 'Abgeschlossen'),
    (3, 75.25, 'Storniert');
GO
