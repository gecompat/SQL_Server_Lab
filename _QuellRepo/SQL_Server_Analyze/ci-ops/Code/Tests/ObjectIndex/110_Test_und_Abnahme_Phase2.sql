USE [DeineDatenbank];
GO

-- Sichere Signatur-/Hilfeprüfung; keine ressourcenintensive Analyse.
EXEC [monitor].[USP_ObjectInventory] @Hilfe=1;
EXEC [monitor].[USP_IndexUsage] @Hilfe=1;
EXEC [monitor].[USP_ObjectAnalysis] @Hilfe=1;
GO
