# Beispiele für die interne Ressourcen-Whitelist

**Stand:** 18. Juli 2026

Alle Bezeichnungen sind synthetisch. Verwenden Sie reale Domain-, Gruppen-, Login-, Server-, Datenbank- oder Unternehmenswerte ausschließlich in der geschützten lokalen Konfiguration.

## 1. Offener Auslieferungszustand

Keine aktive Zeile bedeutet, dass alle geschützten Analyseklassen organisatorisch offen sind.

```sql
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
        (
              CAST(NULL AS varchar(64))
            , CAST(NULL AS nvarchar(256))
            , CAST(NULL AS bit)
            , CAST(NULL AS datetime2(0))
            , CAST(NULL AS datetime2(0))
            , CAST(NULL AS smallint)
            , CAST(NULL AS nvarchar(1000))
        )
    ) AS [p]
    (
          [AnalysisClass]
        , [ADGroupName]
        , [IsEnabled]
        , [ValidFromUtc]
        , [ValidToUtc]
        , [Priority]
        , [Comment]
    )
    WHERE 1 = 0;
GO
```

Für geschützte Klassen wird der `AccessReason` `OPEN_POLICY` erwartet.

## 2. Eine Gruppe für alle geschützten Pfade

```sql
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
        (
              CAST('*' AS varchar(64))
            , CAST(N'ExampleDomain\SqlMonitorDeep' AS nvarchar(256))
            , CAST(1 AS bit)
            , CAST(NULL AS datetime2(0))
            , CAST(NULL AS datetime2(0))
            , CAST(100 AS smallint)
            , CAST(N'Synthetic wildcard example.' AS nvarchar(1000))
        )
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
```

Diese Konfiguration hat folgende Wirkung:

- Gruppenmitglieder: alle geschützten Klassen erlaubt;
- andere Nicht-sysadmin-Logins: alle geschützten Klassen ausgeschlossen;
- ungeschützte Standardpfade: weiterhin erlaubt.

## 3. Getrennte Deep- und Forensikgruppen

```sql
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
           CAST(100 AS smallint), CAST(N'Synthetic plan-cache rule.' AS nvarchar(1000))),

          (CAST('SHOWPLAN_XML_DEEP' AS varchar(64)),
           CAST(N'ExampleDomain\SqlMonitorDeep' AS nvarchar(256)),
           CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
           CAST(100 AS smallint), CAST(N'Synthetic showplan rule.' AS nvarchar(1000))),

          (CAST('QUERY_STORE_DEEP' AS varchar(64)),
           CAST(N'ExampleDomain\SqlMonitorDeep' AS nvarchar(256)),
           CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
           CAST(100 AS smallint), CAST(N'Synthetic query-store rule.' AS nvarchar(1000))),

          (CAST('EXTENDED_EVENTS_FORENSICS_DEEP' AS varchar(64)),
           CAST(N'ExampleDomain\SqlMonitorForensics' AS nvarchar(256)),
           CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
           CAST(100 AS smallint), CAST(N'Synthetic forensics rule.' AS nvarchar(1000)))
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
```

Alle anderen geschützten Klassen sind in diesem Beispiel ausgeschlossen, weil kein `*`-Fallback existiert.

## 4. Mehrere Gruppen für dieselbe Klasse

```sql
VALUES
  (CAST('PLAN_CACHE_DEEP' AS varchar(64)),
   CAST(N'ExampleDomain\SqlMonitorDeepA' AS nvarchar(256)),
   CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
   CAST(100 AS smallint), CAST(N'Synthetic group A.' AS nvarchar(1000))),

  (CAST('PLAN_CACHE_DEEP' AS varchar(64)),
   CAST(N'ExampleDomain\SqlMonitorDeepB' AS nvarchar(256)),
   CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
   CAST(100 AS smallint), CAST(N'Synthetic group B.' AS nvarchar(1000)))
```

Ein positiver Match in einer der beiden Gruppen genügt.

## 5. Zeitlich begrenzte Freigabe

```sql
VALUES
(
      CAST('CATALOG_DEEP' AS varchar(64))
    , CAST(N'ExampleDomain\SqlMonitorTemporary' AS nvarchar(256))
    , CAST(1 AS bit)
    , CAST('2026-08-01T06:00:00' AS datetime2(0))
    , CAST('2026-08-01T18:00:00' AS datetime2(0))
    , CAST(100 AS smallint)
    , CAST(N'Synthetic UTC maintenance window.' AS nvarchar(1000))
)
```

`ValidFromUtc` ist inklusive, `ValidToUtc` exklusiv.

## 6. Fachgruppen plus Administrator-Fallback

```sql
VALUES
  (CAST('PLAN_CACHE_DEEP' AS varchar(64)),
   CAST(N'ExampleDomain\SqlMonitorPlan' AS nvarchar(256)),
   CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
   CAST(100 AS smallint), CAST(N'Synthetic plan specialists.' AS nvarchar(1000))),

  (CAST('EXTENDED_EVENTS_FORENSICS_DEEP' AS varchar(64)),
   CAST(N'ExampleDomain\SqlMonitorForensics' AS nvarchar(256)),
   CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
   CAST(100 AS smallint), CAST(N'Synthetic forensics specialists.' AS nvarchar(1000))),

  (CAST('*' AS varchar(64)),
   CAST(N'ExampleDomain\SqlMonitorAdmins' AS nvarchar(256)),
   CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
   CAST(10 AS smallint), CAST(N'Synthetic administrator fallback.' AS nvarchar(1000)))
```

`Priority=10` macht die Administratorregel nicht stärker. Jeder positive Match erlaubt den betreffenden Pfad.

## 7. Wichtige Fehlannahmen

- Eine Policyregel vergibt keine SQL-Server-Rechte.
- Eine aktive Regel betrifft indirekt alle geschützten Klassen, weil die Whitelist global aktiviert wird.
- `Priority` ist kein Deny-/Allow-Mechanismus.
- SQL-Logins erhalten typischerweise keinen positiven Windows-Gruppenmatch.
- Gruppenfreigabe hebt keine Zeilen-, Datenbank-, Sampling- oder Zeitlimits auf.

## 8. Abnahme

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @ResultSetArt = 'RAW';
```

```sql
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames      = N''
    , @MitGruppenpruefung = 1
    , @NurNichtVerfuegbar = 1
    , @ResultSetArt       = 'RAW';
```

## 9. Verwandte Dokumente

- [Architektur](../Architecture/Authorization_Architecture.md)
- [Administration](../Operations/Authorization_Administration.md)
- [Fehlersuche](../Operations/Authorization_Troubleshooting.md)
