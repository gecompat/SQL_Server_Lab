# [monitor].[USP_CheckAnalyseAccess]

**Bereich:** Common<br>
**Zweck:** Prüft, ob der aktuelle Sicherheitskontext eine Analyseklasse gemäß Framework-Policy ausführen darf.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Erlaubt die Frameworkpolicy dem aktuellen Sicherheitskontext die angeforderte Analyseklasse?** Sie unterstützt die Entscheidung, ob der gewünschte Analysepfad sicher und eindeutig vorbereitet ist oder der Fachaufruf wegen Policy, Capability oder ungültigem Scope unterbleiben muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Performance- oder Verfügbarkeitsursache und keine Aussage über Daten außerhalb des aktuellen Execution-Kontexts. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @ResultSetArt = 'CONSOLE';
```

Für vollständige Spalten `@ResultSetArt='RAW'`; für Parameterhilfe `@Hilfe=1`.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `access`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Access-Zeile beschreibt das effektive Gate-Ergebnis für eine Analyseklasse. Policy-Zeilen beschreiben jeweils eine konfigurierte Gruppenregel.

## So lesen

Berücksichtigen Sie zuerst `IsAllowed`, danach `AccessReason`, `RelevantPolicyCount` und `MatchedGroupCount`. Vergleichen Sie anschließend Original- und Effektivlogin.

## Warum kann das problematisch sein?

`RelevantPolicyCount > 0` und `MatchedGroupCount = 0` bedeutet: Für die Analyseklasse existieren Regeln, aber keine passende Gruppenmitgliedschaft wurde erkannt. Die Sperre ist dann erwartbares Policyverhalten und kein DMV-Defekt.

## Wann ist es kein Problem?

`RelevantPolicyCount = 0` und `IsAllowed = 1` entspricht dem Frameworkvertrag: Ohne definierte Policy bleibt die Klasse offen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** `IsAllowed=0` mit `AccessReason=NO_GROUP_MATCH` verlangt eine Prüfung der Gruppenpolicy, nicht das vorschnelle Erteilen zusätzlicher SQL-Rechte. Prüfen Sie danach mit `USP_CheckFrameworkCapabilities` die technische Lesbarkeit.

**Ähnlich aussehender Gegenfall:** `RelevantPolicyCount = 0` und `IsAllowed = 1` entspricht dem Frameworkvertrag: Ohne definierte Policy bleibt die Klasse offen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Hilfsprocedures kann eine leere interne Zieltabelle aus bewusst leerem Filter, ungültiger Eingabe oder fehlender Policy entstehen; diese Fälle dürfen nicht zu einem ungefilterten Parentlauf zusammenfallen.

Für `USP_CheckAnalyseAccess` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Leere Accessdaten sind nur nach Prüfung von Status, Filter und Policyumfang interpretierbar. `PERMISSION_DENIED` oder `IsPartial=1` ist keine Entwarnung.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | `@AnalyseKlasse = NULL` bewertet alle Klassen aus `VW_AnalyseAccessCurrent` und alle aktuell gültigen Policies. Für jede Policy werden Login-Token-Match und `IS_MEMBER` bestimmt. |
| Teuerster Pfad | Viele definierte Analyseklassen und aktive Gruppenpolicies mit langen Kommentaren. Datenbankzahl, Nutzdaten und Fach-DMVs beeinflussen den Pfad nicht. |
| Haupttreiber | Zahl der Analyseklassen und gültigen Policyzeilen; `sys.login_token` wird je Policy per Existenzprüfung verglichen, zusätzlich erfolgt je Gruppe ein `IS_MEMBER`-Check. |
| Skalierung | Accesszeilen wachsen mit Klassen, Policyzeilen mit Gruppenregeln. JSON/RAW übertragen zusätzlich Policykommentare; die Quellmenge bleibt Framework-/Security-Metadaten. |
| Ressourcen | Views über Frameworkpolicy, Login-Token-/Membershipprüfungen und kleine Temp-Tabellen. Keine Datenbankenumeration, Capabilityprobe oder Nutzdatenabfrage. |
| Begrenzungswirkung | `@AnalyseKlasse` ist der wirksamste Kostenscope. `@NurGesperrte` filtert die Accessausgabe, aber die für den Scope gültigen Policies werden weiterhin geprüft. Ein Max-Rows-Parameter existiert nicht. |
| Locking und Nebenwirkungen | Read-only. Policygültigkeit wird gegen `SYSUTCDATETIME()` geprüft; Gruppenmitgliedschaft oder Policy kann direkt nach dem Snapshot wechseln. Es werden keine Tokens oder Rollen verändert. |
| Schutzmechanismus | Diese Procedure entscheidet Zugänglichkeit, führt aber selbst keine Fachanalyse und kein High-Impact-Gate aus. `@AnalyseKlasse` beschränkt die zu prüfenden Klassen; `@NurGesperrte` reduziert nur die Ausgabe. Token-/Gruppenprüfung und Policies bleiben fail-closed, wenn ihre Evidenz nicht bestimmbar ist. |
| Sicherer Einsatz | Für eine Freigabeentscheidung eine konkrete dokumentierte Analyseklasse prüfen; Gesamtübersicht nur für Policy-Audits. Login- und Gruppennamen als sensible Security-Metadaten behandeln. |
| Aussagegrenze | `IsAllowed` beschreibt ausschließlich die Framework-Gruppenpolicy im aktuellen Login-Kontext. Objekt-/DMV-Berechtigungen, Datenbanksichtbarkeit und `@HighImpactConfirmed` werden hier nicht bewiesen. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Erlaubt die Frameworkpolicy dem aktuellen Sicherheitskontext die angeforderte Analyseklasse?

### Technischer Hintergrund

Das Framework besitzt eine zusätzliche Berechtigungsschiene oberhalb der SQL-Server-Quellberechtigungen. Es prüft Original- und Effektivlogin, sysadmin-Bypass sowie sichtbare Login-/Gruppentokens. Existiert für eine Analyseklasse keine Policy, bleibt sie gemäß Frameworkvertrag offen; existieren Policies, muss eine passende erlaubende Mitgliedschaft sichtbar sein.

### Datenkette

`sys.login_token`.

### Source Select

Die effektive Policy basiert auf aktiven Policyzeilen und Gruppen im Login-Token. Das relevante Grundselect lautet:

```sql
SELECT
      [p].[AnalysisClass]
    , [p].[ADGroupName]
    , [lt].[name] AS [MatchedLoginToken]
FROM [monitor].[VW_AnalyseAccessPolicy] AS [p]
LEFT JOIN [sys].[login_token] AS [lt] WITH (NOLOCK)
  ON UPPER(CONVERT(nvarchar(256), [lt].[name])) COLLATE Latin1_General_100_CI_AS
   = UPPER([p].[ADGroupName]) COLLATE Latin1_General_100_CI_AS
 AND [lt].[type] = N'WINDOWS GROUP'
WHERE [p].[IsEnabled] = 1
  AND [p].[AnalysisClass] IN ('PLAN_CACHE_DEEP', '*');
```

**Wichtig für die Eigenlast:** Die Mengen sind klein. Der Klassenfilter verhindert unnötige `IS_MEMBER`-Fallbackprüfungen; die öffentliche Procedure ergänzt außerdem offene Policy und sysadmin-Bypass.

### Zeit- und Scope-Modell

Die Auswertung liefert eine Momentaufnahme des aktuellen Login- und Execution-Kontexts. Gruppenauflösung kann sich durch Token, Impersonation oder Verzeichniszustand vom erwarteten Benutzerbild unterscheiden.

### Bewertung und Gegenprobe

Berücksichtigen Sie `IsAllowed`, Policyanzahl, gematchte Gruppen und AccessReason gemeinsam. Ein Deny bei vorhandener Policy und ohne Match ist erwartetes Policyverhalten; SQL-Quellrechte zu erweitern würde die Frameworksperre nicht fachlich lösen.

### Typische Fehlinterpretation

`IsAllowed=1` beweist nicht, dass die benötigten DMVs tatsächlich lesbar sind. Umgekehrt ist ein leeres Fachresultset kein Beweis für Policy-Deny.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_CheckFrameworkCapabilities` trennt anschließend Feature-, Rechte- und Queryabilityprobleme.

## Primärquellen

- [sys.login_token](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-login-token-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../01_Common.md#2-monitorusp_checkanalyseaccess)
