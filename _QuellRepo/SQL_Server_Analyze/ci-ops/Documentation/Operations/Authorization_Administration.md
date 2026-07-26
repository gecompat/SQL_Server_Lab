# Administration des internen Ressourcenschutzes

**Stand:** 18. Juli 2026  
**Zielgruppe:** SQL-Server-Administratoren und Frameworkbetreiber

## 1. Grundsatz

Die interne Policy steuert, welche Benutzergruppen ressourcenintensive Analysepfade ausführen dürfen.

Sie ist eine Whitelist für Analyseklassen mit `RequiresGroupGate=1` und keine allgemeine Benutzerberechtigungsverwaltung.

Für einen Deep-Pfad müssen zwei unabhängige Bedingungen erfüllt sein:

1. Die Ressourcenschutz-Policy erlaubt die Analyseklasse.
2. Der Login besitzt die erforderlichen SQL-Server-Berechtigungen für die Systemquellen.

Die Policy vergibt keine SQL-Rechte und entfernt keine Zeilen-, Datenbank-, Zeit- oder Lock-Timeout-Grenzen.

## 2. Auslieferungszustand

Die ausgelieferte View `[monitor].[VW_AnalyseAccessPolicy]` ist leer.

Folge:

- ungeschützte Klassen: erlaubt (`NOT_REQUIRED`);
- geschützte Klassen: offen (`OPEN_POLICY`);
- keine Benutzergruppe wird im Auslieferungszustand ausgeschlossen.

Dieser Zustand erleichtert Installation und Ersttest. Für produktive Umgebungen muss bewusst entschieden werden, ob Deep- und Forensikpfade offen bleiben dürfen.

## 3. Whitelist aktivieren

Sobald **eine einzige aktive Policyzeile** existiert, wird die Whitelist für alle geschützten Klassen aktiv.

Danach gelten folgende Regeln:

- passender Klassen- oder `*`-Gruppenmatch → erlaubt;
- sysadmin → erlaubt;
- kein Match → ausgeschlossen (`NO_MATCH` / `DENIED_GROUP`).

Es gibt derzeit keine expliziten Benutzer-Deny-Zeilen. Benutzer werden ausgeschlossen, indem sie keiner freigegebenen Gruppe angehören.

Führen Sie vor der ersten aktiven Policyzeile die folgenden Schritte aus:

1. alle Klassen mit `RequiresGroupGate=1` inventarisieren;
2. gewünschte Deep-Pfade auswählen;
3. Gruppenmodell definieren;
4. bewusst über ein `*`-Fallback entscheiden;
5. Auswirkungen auf nicht aufgeführte geschützte Klassen prüfen;
6. Testen Sie das Windows-Token mit einer neuen Anmeldung.

## 4. Analyseklassen inventarisieren

```sql
SELECT
      [AnalysisClass]
    , [AnalysisLevel]
    , [RequiresGroupGate]
    , [DefaultMaxRows]
    , [DefaultTimeoutSeconds]
    , [Description]
FROM [monitor].[VW_AnalyseClassCatalog]
ORDER BY [RequiresGroupGate], [AnalysisLevel], [AnalysisClass];
```

Typische geschützte Ressourcenpfade:

- Plan-Cache-Vollanalysen;
- Showplan-XML-Shredding;
- physische Indexstatistiken;
- breite Systemkatalog- oder Query-Store-Scans;
- Cross-Database-Analysen;
- Extended-Events-Forensik;
- Enterprise-Topologieanalysen.

## 5. Empfohlenes Gruppenmodell

Ein einfaches synthetisches Modell:

| Gruppe | Zweck |
|---|---|
| `ExampleDomain\SqlMonitorDeep` | allgemeine Deep-Analysen |
| `ExampleDomain\SqlMonitorForensics` | Forensik- und Eventdateipfade |
| `ExampleDomain\SqlMonitorAdmins` | bewusstes `*`-Fallback |

Beispiele verwenden ausschließlich synthetische Namen. Reale Domain- und Gruppennamen dürfen nur in der kontrollierten Laufzeitkonfiguration gepflegt und nicht ungeprüft exportiert oder weitergegeben werden.

## 6. Policy pflegen

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
           CAST(100 AS smallint), CAST(N'Synthetic plan-cache example.' AS nvarchar(1000))),

          (CAST('SHOWPLAN_XML_DEEP' AS varchar(64)),
           CAST(N'ExampleDomain\SqlMonitorDeep' AS nvarchar(256)),
           CAST(1 AS bit), CAST(NULL AS datetime2(0)), CAST(NULL AS datetime2(0)),
           CAST(100 AS smallint), CAST(N'Synthetic showplan example.' AS nvarchar(1000))),

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
```

## 7. Policyfelder

### `AnalysisClass`

- Exakter, case-sensitiver Wert aus `[monitor].[VW_AnalyseClassCatalog]`.
- `*` gilt für alle geschützten Klassen.
- Unbekannte Klassen erzeugen keine Freigabe für reale Module.

### `ADGroupName`

- Windows-Gruppenname für erlaubte Benutzer.
- Match über `[sys].[login_token]`, danach `IS_MEMBER` als Fallback.
- Leere Namen werden ignoriert.

### `IsEnabled`

Nur `1` aktiviert die Regel.

### `ValidFromUtc` / `ValidToUtc`

- Beginn inklusive;
- Ende exklusiv;
- `NULL` bedeutet unbeschränkt.

### `Priority`

Dieser Wert dient ausschließlich der Dokumentation und Sortierung. Es existiert keine Deny-overrides-Allow- oder First-Match-Logik.

### `Comment`

Dieser Wert enthält einen lokalen Zweckhinweis. Übernehmen Sie keine realen personenbezogenen, kundenbezogenen oder internen Informationen in freigegebene Beispiele oder ungeschützte Exporte.

## 8. Ressourcenschutz prüfen

### Alle Klassen

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @ResultSetArt = 'CONSOLE';
```

### Nur ausgeschlossene Klassen

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @NurGesperrte = 1
    , @ResultSetArt = 'CONSOLE';
```

### Einzelne Klasse

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @AnalyseKlasse = 'PLAN_CACHE_DEEP'
    , @ResultSetArt  = 'RAW';
```

### Effektive View

```sql
SELECT
      [AnalysisClass]
    , [RequiresGroupGate]
    , [IsAllowed]
    , [AccessReason]
    , [ActivePolicyCount]
    , [RelevantPolicyCount]
    , [MatchedGroupCount]
FROM [monitor].[VW_AnalyseAccessCurrent]
ORDER BY [RequiresGroupGate], [AnalysisClass];
```

## 9. Technische Voraussetzungen getrennt prüfen

```sql
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames      = N''
    , @AnalyseKlasse      = 'PLAN_CACHE_DEEP'
    , @MitGruppenpruefung = 1
    , @NurNichtVerfuegbar = 0
    , @ResultSetArt       = 'RAW';
```

Interpretation:

- `DENIED_GROUP`: Benutzer ist für den Ressourcenpfad ausgeschlossen.
- `DENIED_PERMISSION`: Benutzer ist intern freigegeben, SQL Server verweigert aber die Quelle.
- `AVAILABLE_LIMITED`: Pfad ist nutzbar, Sicht kann eingeschränkt sein.

`@MitGruppenpruefung=0` ist nur eine technische Diagnoseoption und kein Bypass in den eigentlichen Analysemodulen.

## 10. Tokenaktualisierung

Windows-Gruppenänderungen werden erst nach einer neuen Anmeldung zuverlässig sichtbar.

Nach einer Änderung:

1. bestehende SQL-Verbindung schließen;
2. neue Verbindung öffnen;
3. Token lokal kontrollieren;
4. Prüfen Sie die Policy erneut.

```sql
SELECT [name], [type], [usage]
FROM [sys].[login_token]
WHERE [type] = N'WINDOWS GROUP'
ORDER BY [name];
```

Diese lokale Laufzeitausgabe kann reale Gruppenwerte enthalten und darf nur kontrolliert gespeichert oder weitergegeben werden.

## 11. Zur offenen Policy zurückkehren

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

## 12. Abnahmecheckliste

- [ ] Alle ressourcenintensiven Klassen wurden bewusst bewertet.
- [ ] Alle gewünschten Klassen besitzen eine Regel oder ein bewusstes `*`-Fallback.
- [ ] Nicht zugeordnete Benutzer sind erwartungsgemäß ausgeschlossen.
- [ ] `Priority` wurde nicht als Deny-/Allow-Mechanismus missverstanden.
- [ ] Gruppenänderungen wurden mit neuer Anmeldung getestet.
- [ ] `DENIED_GROUP` und `DENIED_PERMISSION` sind getrennt nachvollziehbar.
- [ ] Freigegebene Deep-Aufrufe behalten Zeilen-, Datenbank- und Zeitlimits.
- [ ] Keine realen Gruppen- oder Laufzeitdaten wurden unkontrolliert exportiert oder archiviert.

## 13. Weiterführende Dokumente

- [Architektur](../Architecture/Authorization_Architecture.md)
- [Policy-Beispiele](../Reference/Authorization_Policy_Examples.md)
- [Statusreferenz](../Reference/Authorization_Status_and_Access_Reasons.md)
- [Fehlersuche](Authorization_Troubleshooting.md)
- [Beispielaufrufe](../../Code/Examples/050_Authorization_Examples.sql)
