# [monitor].[USP_CheckFrameworkCapabilities]

**Bereich:** Common<br>
**Zweck:** Prüft Version, Policy, Berechtigung, Abfragbarkeit und Featurestatus für Diagnosepfade.<br>
**Beobachtungsart:** Snapshot<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Ist ein Analysepfad auf dieser konkreten Instanz nicht nur theoretisch unterstützt, sondern tatsächlich nutzbar?** Sie unterstützt die Entscheidung, ob der gewünschte Analysepfad sicher und eindeutig vorbereitet ist oder der Fachaufruf wegen Policy, Capability oder ungültigem Scope unterbleiben muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Performance- oder Verfügbarkeitsursache und keine Aussage über Daten außerhalb des aktuellen Execution-Kontexts. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @NurNichtVerfuegbar = 1,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `capabilities`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Capability-Zeile bewertet ein Feature in einem Server- oder Datenbank-Scope. Dieselbe Fähigkeit kann deshalb je Datenbank unterschiedlich ausfallen.

## So lesen

Lesen Sie die Angaben in dieser Reihenfolge: `VersionSupported` → `GroupAccessAllowed` → `HasRequiredPermission` → `IsQueryable` → `IsFeatureEnabled` → `IsUsable`.

## Warum kann das problematisch sein?

`HasRequiredPermission=1`, aber `IsQueryable=0` zeigt, dass eine formale Permission nicht genügt. Datenbankstatus, Plattform, Replica-Rolle oder Laufzeitfehler begrenzen den Pfad.

## Wann ist es kein Problem?

Ein deaktiviertes Feature ist kein Serverfehler, wenn es nicht benötigt wird. Es erklärt lediglich, warum die zugehörige Analyse keine Daten liefern kann.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Query Store kann versionsseitig unterstützt und lesbar, aber deaktiviert sein. Ein leeres Query-Store-Resultset sagt dann nichts über die Queryqualität. Nur Scopes mit `IsUsable=1` fachlich auswerten.

**Ähnlich aussehender Gegenfall:** Ein deaktiviertes Feature ist kein Serverfehler, wenn es nicht benötigt wird. Es erklärt lediglich, warum die zugehörige Analyse keine Daten liefern kann. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Bei Hilfsprocedures kann eine leere interne Zieltabelle aus bewusst leerem Filter, ungültiger Eingabe oder fehlender Policy entstehen; diese Fälle dürfen nicht zu einem ungefilterten Parentlauf zusammenfallen.

Für `USP_CheckFrameworkCapabilities` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Fehlende Capability-Zeilen können durch eine explizite Datenbankauswahl, Rechte
oder nicht verfügbare Datenbanken entstehen. Status und Warnings gehören
zwingend zur Bewertung.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Ohne Scope werden alle sichtbaren Online-Benutzerdatenbanken mit allen Katalogfeatures kombiniert. Für jede Serverfeaturezeile und jede `(Datenbank, Feature)`-Zeile prüft der Code Version, Gruppe, Berechtigung, Abfragbarkeit und optional Enablement. |
| Teuerster Pfad | Viele Datenbanken × viele Datenbankfeatures mit `@MitGruppenpruefung = 1`; jede Kombination führt kleine dynamische Permission-/Probe-/Enablementstatements aus. Es sind Metadatenprobes, keine Fachanalyse- oder Nutzdatenscans. |
| Haupttreiber | Produkt aus Zahl der ausgewählten Datenbanken und DATABASE-Features plus konstante SERVER-Features. Dynamisches SQL wird je Kombination kompiliert/ausgeführt. |
| Skalierung | Annähernd linear mit den Featurekombinationen. Eine einzelne Analyseklasse reduziert den Featurekatalog früh; Datenbankscope reduziert DATABASE-Kombinationen. JSON/Sortierung sind nachgeordnet. |
| Ressourcen | Frameworkkatalogviews, `master`-Datenbankkandidaten, Login-/Permissionchecks und kurze Metadatenprobes per `sp_executesql`; Temp-Tabellen für Capability- und Warningzeilen. |
| Begrenzungswirkung | `@DatabaseNames` und `@AnalyseKlasse` begrenzen tatsächliche Probeanzahl. `@NurNichtVerfuegbar` filtert erst die Ausgabe und spart keine Probes. Es gibt kein `@MaxZeilen`. |
| Locking und Nebenwirkungen | Read-only; Probe- und Enablementtemplates werden nur abgefragt, nicht konfiguriert. Datenbankstatus/Berechtigung kann sich während der Schleife ändern, daher sind Capabilityzeilen kein atomarer Snapshot. |
| Schutzmechanismus | Der Aufruf an `USP_PrepareDatabaseCandidates` verwendet bewusst `@AnalysisClass = NULL`; damit löst `@HighImpactConfirmed` hier kein Deep-Gate aus. Schutz sind Feature-/Datenbankscope und ausschließlich leichte Capabilityprobes. |
| Sicherer Einsatz | Eine `ExampleDatabase` und eine konkrete Analyseklasse prüfen; die vollständige Matrix nur für Inventar-/Upgradeaudits ausführen. `@NurNichtVerfuegbar` dient Lesbarkeit, nicht Lastreduktion. |
| Aussagegrenze | `IsUsable` beweist, dass der kleine Capabilityprobe im aktuellen Kontext funktioniert. Es garantiert weder Berechtigung auf jede spätere Fachzeile noch geringe Kosten, Datenvollständigkeit oder erfolgreiche Ausführung des eigentlichen Analysemoduls. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Ist ein Analysepfad auf dieser konkreten Instanz nicht nur theoretisch unterstützt, sondern tatsächlich nutzbar?

### Technischer Hintergrund

Version, Edition, Featurekonfiguration und formale Permission sind verschiedene Ebenen. Die Procedure führt capability-orientierte Prüfungen aus und kann geschützte Testabfragen dynamisch ausführen. Dadurch wird zwischen `supported`, `enabled`, `permitted`, `queryable` und `usable` unterschieden.

### Datenkette

`sys.sp_executesql`.

### Source Select

Die Capability-Prüfung startet mit dem deklarativen Featurekatalog; datenbankbezogene Einträge werden erst danach mit den ausgewählten Datenbanken vervielfacht:

```sql
SELECT
      [f].[FeatureCode]
    , [f].[ScopeType]
    , [f].[AnalysisClass]
    , [f].[MinimumMajorVersion]
    , [f].[ProbeSqlTemplate]
FROM [monitor].[VW_FrameworkFeatureCatalog] AS [f]
WHERE [f].[AnalysisClass] = 'STANDARD_CURRENT'
  AND [f].[MinimumMajorVersion]
      <= TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
```

**Wichtig für die Eigenlast:** Analyseklasse und Datenbankscope vor dem Ausführen der Probe-Statements einschränken. Die Probes verwenden leichte Status- beziehungsweise `TOP (0)`-Abfragen, werden aber je Datenbank wiederholt.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Umgebungszustand; Ergebnisse können sich nach Konfigurationsänderung, Failover, Datenbankstatuswechsel oder Berechtigungsänderung ändern.

### Bewertung und Gegenprobe

Berücksichtigen Sie die Prüfkette in der dokumentierten Reihenfolge. `HasRequiredPermission=1` bei `IsQueryable=0` weist auf eine zusätzliche Laufzeitgrenze hin. `IsFeatureEnabled=0` kann bei einem bewusst ungenutzten Feature normal sein.

### Typische Fehlinterpretation

Capability ist kein Nachweis, dass relevante Daten vorhanden sind. Query Store kann nutzbar, aber leer sein; XE kann abfragbar, aber ohne passende Session sein.

### Folgeanalyse

Starten Sie nur Fachmodule, deren benötigte Quelle nutzbar ist. Prüfen Sie bei einem Partialstatus die jeweilige Datenbank oder Quelle gezielt.

## Primärquellen

- [sys.sp_executesql](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-executesql-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../01_Common.md#3-monitorusp_checkframeworkcapabilities)
