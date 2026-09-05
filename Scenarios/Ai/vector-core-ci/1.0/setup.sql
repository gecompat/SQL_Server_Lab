USE [master];
GO

IF DB_ID(N'SqlServerLabAiVectorCore') IS NOT NULL
BEGIN
    ALTER DATABASE [SqlServerLabAiVectorCore] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [SqlServerLabAiVectorCore];
END;
GO

CREATE DATABASE [SqlServerLabAiVectorCore];
GO
ALTER DATABASE [SqlServerLabAiVectorCore] SET COMPATIBILITY_LEVEL = 170;
GO

USE [SqlServerLabAiVectorCore];
GO
CREATE TABLE dbo.Documents
(
    DocumentId int NOT NULL CONSTRAINT PK_Documents PRIMARY KEY,
    Title nvarchar(100) NOT NULL,
    Content nvarchar(1000) NOT NULL,
    Embedding vector(3) NOT NULL,
    EmbeddingModelId varchar(64) NOT NULL,
    DatasetId varchar(64) NOT NULL
);
GO

INSERT dbo.Documents (DocumentId, Title, Content, Embedding, EmbeddingModelId, DatasetId)
VALUES
    (1, N'Vektorsuche', N'SQL Server speichert Vektoren typisiert und vergleicht ihre Distanz.', '[1,0,0]', 'fixed-vector-3', 'synthetic-vector-core-de'),
    (2, N'Sicherung', N'Eine geprüfte Sicherung unterstützt kontrollierte Wiederherstellungstests.', '[0,1,0]', 'fixed-vector-3', 'synthetic-vector-core-de'),
    (3, N'Netzwerk', N'Ein isoliertes Labornetz begrenzt unerwünschten Datenverkehr.', '[0,0,1]', 'fixed-vector-3', 'synthetic-vector-core-de'),
    (4, N'Ähnliche Suche', N'Exakte Vektordistanzen bilden die Referenz für semantische Suche.', '[0.98,0.02,0]', 'fixed-vector-3', 'synthetic-vector-core-de');
GO
