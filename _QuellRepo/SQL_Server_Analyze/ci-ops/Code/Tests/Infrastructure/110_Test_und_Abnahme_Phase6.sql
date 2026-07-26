USE [DeineDatenbank];
GO

-- Sichere Signatur-/Hilfeprüfung; keine ressourcenintensive Analyse.
EXEC [monitor].[USP_AgentStatus] @Hilfe=1;
EXEC [monitor].[USP_ResourceGovernorAnalysis] @Hilfe=1;
EXEC [monitor].[USP_InfrastructureAnalysis] @Hilfe=1;
GO
