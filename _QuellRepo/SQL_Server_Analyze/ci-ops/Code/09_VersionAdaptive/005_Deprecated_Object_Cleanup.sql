USE [DeineDatenbank];
GO

/*
===============================================================================
Datei        : 005_Deprecated_Object_Cleanup.sql
Stand        : 2026-07-15
Zweck        : Entfernt ausschließlich veraltete Frameworkobjekte aus früheren
               Zwischenständen. Fachliche Diagnoseobjekte und kundeneigene
               WaitTypeCatalog-Zeilen bleiben unverändert.
===============================================================================
*/

IF EXISTS(SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id] WHERE [s].[name]=N'monitor' AND [p].[name]=N'USP_SQLServer2025Features')
    DROP PROCEDURE [monitor].[USP_SQLServer2025Features];
GO

IF EXISTS(SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id] WHERE [s].[name]=N'monitor' AND [p].[name]=N'USP_FrameworkContractInventory')
    DROP PROCEDURE [monitor].[USP_FrameworkContractInventory];
IF EXISTS(SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id] WHERE [s].[name]=N'monitor' AND [p].[name]=N'USP_FrameworkSelfTest')
    DROP PROCEDURE [monitor].[USP_FrameworkSelfTest];
IF EXISTS(SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id] WHERE [s].[name]=N'monitor' AND [p].[name]=N'USP_FrameworkInstallationHistory')
    DROP PROCEDURE [monitor].[USP_FrameworkInstallationHistory];
IF EXISTS(SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id] WHERE [s].[name]=N'monitor' AND [p].[name]=N'USP_FrameworkInstallationFinish')
    DROP PROCEDURE [monitor].[USP_FrameworkInstallationFinish];
IF EXISTS(SELECT 1 FROM [sys].[procedures] AS [p] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[p].[schema_id] WHERE [s].[name]=N'monitor' AND [p].[name]=N'USP_FrameworkInstallationBegin')
    DROP PROCEDURE [monitor].[USP_FrameworkInstallationBegin];
GO

IF EXISTS(SELECT 1 FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'FrameworkProcedureContract')
    DROP TABLE [monitor].[FrameworkProcedureContract];
IF EXISTS(SELECT 1 FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'FrameworkExpectedObject')
    DROP TABLE [monitor].[FrameworkExpectedObject];
IF EXISTS(SELECT 1 FROM [sys].[tables] AS [t] WITH (NOLOCK) JOIN [sys].[schemas] AS [s] WITH (NOLOCK) ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=N'monitor' AND [t].[name]=N'FrameworkInstallationHistory')
    DROP TABLE [monitor].[FrameworkInstallationHistory];
GO
