USE [DeineDatenbank];
GO

-- Sichere Signatur-/Hilfeprüfung; keine ressourcenintensive Analyse.
EXEC [monitor].[USP_ServerCpuTopology] @Hilfe=1;
EXEC [monitor].[USP_ServerMemory] @Hilfe=1;
EXEC [monitor].[USP_ServerHealthAnalysis] @Hilfe=1;
GO
