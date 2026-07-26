USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.VW_AnalyseAccessPolicy
Version      : 1.0.0
Stand        : 2026-07-14
Typ          : View
Zweck        : Stellt die rein lesende Policyquelle für eine oder mehrere
               AD-Gruppen je ressourcenintensiver Analyseklasse bereit.
Standard     : Die ausgelieferte View enthält keine Zeilen. Solange keine aktive
               Gruppendefinition vorhanden ist, sind alle Analyseklassen erlaubt.
Policy       : Sobald mindestens eine aktive Definition vorhanden ist, sind
               gruppengeschützte Analyseklassen nur für passende Gruppen erlaubt.
               Ein Eintrag mit AnalysisClass='*' gilt für alle geschützten Klassen.
Sysadmin     : sysadmin wird unabhängig von Gruppenregeln immer zugelassen.
Fallback     : Die effektive Prüfung verwendet zuerst sys.login_token und danach
               IS_MEMBER als Fallback.
Parameter    : Keine.
Resultset    : AnalysisClass, ADGroupName, IsEnabled, ValidFromUtc, ValidToUtc,
               Priority, Comment.
Berechtigung : SELECT auf der View; keinerlei GRANT/DENY/REVOKE im Framework.
Änderung     : Gruppen werden später durch CREATE OR ALTER VIEW gepflegt.
Beispiel     : Siehe kommentierte VALUES-Vorlage am Dateiende.
Änderungen   : 1.0.0 - Erstfassung Phase 1A.
===============================================================================
*/
CREATE OR ALTER VIEW [monitor].[VW_AnalyseAccessPolicy]
AS
    SELECT
        [p].[AnalysisClass],
        [p].[ADGroupName],
        [p].[IsEnabled],
        [p].[ValidFromUtc],
        [p].[ValidToUtc],
        [p].[Priority],
        [p].[Comment]
    FROM
    (
        VALUES
        (
            CAST(NULL AS varchar(64)),
            CAST(NULL AS nvarchar(256)),
            CAST(NULL AS bit),
            CAST(NULL AS datetime2(0)),
            CAST(NULL AS datetime2(0)),
            CAST(NULL AS smallint),
            CAST(NULL AS nvarchar(1000))
        )
    ) AS [p]
    (
        [AnalysisClass],
        [ADGroupName],
        [IsEnabled],
        [ValidFromUtc],
        [ValidToUtc],
        [Priority],
        [Comment]
    )
    WHERE 1 = 0;
GO

/*
Beispiel für eine spätere, bewusst manuell gepflegte Policy-View:

CREATE OR ALTER VIEW monitor.VW_AnalyseAccessPolicy
AS
    SELECT
        p.AnalysisClass,
        p.ADGroupName,
        p.IsEnabled,
        p.ValidFromUtc,
        p.ValidToUtc,
        p.Priority,
        p.Comment
    FROM
    (
        VALUES
          (CAST('PLAN_CACHE_DEEP' AS varchar(64)), CAST(N'CONTOSO\\SQL_Monitor_Deep' AS nvarchar(256)), CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)), CAST(100 AS smallint), CAST(N'Plan-Cache Deep Analysis' AS nvarchar(1000))),
          (CAST('SHOWPLAN_XML_DEEP' AS varchar(64)), CAST(N'CONTOSO\\SQL_Monitor_Deep' AS nvarchar(256)), CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)), CAST(100 AS smallint), CAST(N'Showplan XML Deep Analysis' AS nvarchar(1000))),
          (CAST('*' AS varchar(64)), CAST(N'CONTOSO\\SQL_Server_Admins' AS nvarchar(256)), CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)), CAST(10 AS smallint), CAST(N'Alle geschützten Analyseklassen' AS nvarchar(1000)))
    ) AS [p]
    (
        [AnalysisClass],
        [ADGroupName],
        [IsEnabled],
        [ValidFromUtc],
        [ValidToUtc],
        [Priority],
        [Comment]
    );
GO
*/
