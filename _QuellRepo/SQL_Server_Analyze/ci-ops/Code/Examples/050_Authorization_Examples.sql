USE [DeineDatenbank];
GO

/*
==============================================================================
Datei        : 050_Authorization_Examples.sql
Zweck        : Enthält sichere Beispielaufrufe für Ressourcenschutz,
               Gruppenpolicy und technische Capabilityprüfung.
Datenschutz  : Ausschließlich synthetische Gruppen- und Klassennamen.
Hinweis      : Das Framework vergibt keine SQL-Server-Berechtigungen.
==============================================================================
*/

/* 1. Kosten- und Schutzklassen anzeigen. */
SELECT
      [AnalysisClass]
    , [AnalysisLevel]
    , [RequiresGroupGate]
    , [DefaultMaxRows]
    , [DefaultTimeoutSeconds]
    , [Description]
FROM [monitor].[VW_AnalyseClassCatalog]
ORDER BY [RequiresGroupGate], [AnalysisLevel], [AnalysisClass];
GO

/* 2. Effektive Ressourcenschutzentscheidung für den aktuellen Login. */
SELECT
      [AnalysisClass]
    , [AnalysisLevel]
    , [RequiresGroupGate]
    , [IsAllowed]
    , [AccessReason]
    , [ActivePolicyCount]
    , [RelevantPolicyCount]
    , [MatchedGroupCount]
FROM [monitor].[VW_AnalyseAccessCurrent]
ORDER BY [RequiresGroupGate], [AnalysisLevel], [AnalysisClass];
GO

/* 3. Lesbare Übersicht aller Klassen. */
EXEC [monitor].[USP_CheckAnalyseAccess]
      @ResultSetArt = 'CONSOLE';
GO

/* 4. Nur aktuell ausgeschlossene ressourcenintensive Klassen. */
EXEC [monitor].[USP_CheckAnalyseAccess]
      @NurGesperrte = 1
    , @ResultSetArt = 'CONSOLE';
GO

/* 5. Eine konkrete Deep-Klasse prüfen. */
EXEC [monitor].[USP_CheckAnalyseAccess]
      @AnalyseKlasse = 'PLAN_CACHE_DEEP'
    , @ResultSetArt  = 'RAW';
GO

/* 6. Policy, Version, Capability und SQL-Berechtigung gemeinsam prüfen. */
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames        = N''
    , @AnalyseKlasse        = 'PLAN_CACHE_DEEP'
    , @MitGruppenpruefung   = 1
    , @NurNichtVerfuegbar   = 0
    , @ResultSetArt         = 'RAW';
GO

/*
7. Nur technische Capabilitydiagnose.
   @MitGruppenpruefung=0 ist kein Bypass in den eigentlichen Analyse-Procedures.
*/
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames        = N''
    , @AnalyseKlasse        = 'PLAN_CACHE_DEEP'
    , @MitGruppenpruefung   = 0
    , @NurNichtVerfuegbar   = 0
    , @ResultSetArt         = 'CONSOLE';
GO

/* 8. JSON-only-Ausgabe für automatisierte Diagnose. */
DECLARE @Json nvarchar(max);

EXEC [monitor].[USP_CheckAnalyseAccess]
      @AnalyseKlasse  = 'CROSS_DATABASE_DEEP'
    , @ResultSetArt   = 'NONE'
    , @JsonErzeugen   = 1
    , @Json           = @Json OUTPUT
    , @PrintMeldungen = 0;

SELECT @Json AS [AuthorizationJson];
GO

/*
9. Beispiel für eine lokale Policydefinition.
   Nicht ungeprüft übernehmen. Reale Domain- und Gruppennamen dürfen nicht in
   Repository-, Issue-, Log- oder Downloadartefakte kopiert werden.
*/
/*
CREATE OR ALTER VIEW [monitor].[VW_AnalyseAccessPolicy]
AS
    SELECT
          [p].[AnalysisClass]
        , [p].[ADGroupName]
        , [p].[IsEnabled]
        , [p].[ValidFromUtc]
        , [p].[ValidToUtc]
        , [p].[Priority]
        , [p].[Comment]
    FROM
    (
        VALUES
          (CAST('PLAN_CACHE_DEEP' AS varchar(64)),
           CAST(N'ExampleDomain\SqlMonitorDeep' AS nvarchar(256)),
           CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
           CAST(100 AS smallint), CAST(N'Synthetic deep-path example.' AS nvarchar(1000))),

          (CAST('EXTENDED_EVENTS_FORENSICS_DEEP' AS varchar(64)),
           CAST(N'ExampleDomain\SqlMonitorForensics' AS nvarchar(256)),
           CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
           CAST(100 AS smallint), CAST(N'Synthetic forensics example.' AS nvarchar(1000))),

          (CAST('*' AS varchar(64)),
           CAST(N'ExampleDomain\SqlMonitorAdmins' AS nvarchar(256)),
           CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
           CAST(10 AS smallint), CAST(N'Synthetic administrator fallback.' AS nvarchar(1000)))
    ) AS [p]
    (
          [AnalysisClass]
        , [ADGroupName]
        , [IsEnabled]
        , [ValidFromUtc]
        , [ValidToUtc]
        , [Priority]
        , [Comment]
    );
GO
*/

/*
10. Beispiel für einen leichten und einen geschützten Pfad.
    Der genaue Deep-Auslöser ist in der jeweiligen Procedure-Hilfe beschrieben.
*/
EXEC [monitor].[USP_QueryStats]
      @AnalyseModus = 'TOP'
    , @MaxZeilen    = 100;
GO

EXEC [monitor].[USP_QueryStats]
      @AnalyseModus = 'VOLL'
    , @MaxZeilen    = 1000;
GO
