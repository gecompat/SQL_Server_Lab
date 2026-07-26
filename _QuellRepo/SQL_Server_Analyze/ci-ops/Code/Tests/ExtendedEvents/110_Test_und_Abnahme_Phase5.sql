USE [DeineDatenbank];
GO

-- Sichere Signatur-/Hilfeprüfung; keine ressourcenintensive Analyse.
EXEC [monitor].[USP_ExtendedEventsSessions] @Hilfe=1;
EXEC [monitor].[USP_ExtendedEventsAnalysis] @Hilfe=1;
GO
