# [monitor].[USP_QueryStorePlanChanges]

**Bereich:** Query Store<br>
**Zweck:** Findet Queries mit mehreren Query-Store-Plänen und zeigt Compile- sowie Nutzungsmetadaten.<br>
**Beobachtungsart:** persistierte, retentionbegrenzte Historie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Queries besitzen mehrere gespeicherte Pläne, und wodurch unterscheiden sich deren Lebenszyklus und Compilekontext?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_QueryStorePlanChanges]
      @QueryStoreDatabaseNames = N'[ExampleDatabase]',
      @NurMehrerePlaene = 1,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `queries`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Summary-Zeilen entsprechen Queries; Planzeilen entsprechen jeweils einer Query-Store-Plan-ID.

## So lesen

Vergleichen Sie PlanCount, Distinct Plan Hashes, Compile-/Executionzeiten, Engine-/Compatibility-Kontext und Forced-Status.

## Warum kann das problematisch sein?

Ein neuer Plan kann andere Kosten, Parallelität oder Zugriffspfade besitzen und zeitlich mit einer Regression zusammenfallen.

## Wann ist es kein Problem?

Mehrere Planzeilen mit demselben Hash oder alte, nicht mehr ausgeführte Pläne sind nicht automatisch relevant.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Vier PlanIds, aber nur zwei Hashes; einer seit Monaten inaktiv. Untersuchen Sie Aktive Varianten mit Runtime Stats, Regressionen und Planvergleich.

**Ähnlich aussehender Gegenfall:** Mehrere Planzeilen mit demselben Hash oder alte, nicht mehr ausgeführte Pläne sind nicht automatisch relevant. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_QueryStorePlanChanges` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, jüngerer Startzeitpunkt, nur Queries mit mehreren Plänen, TOP 100 und `@MitPlanXml = 0`. |
| Teuerster Pfad | Viele Datenbanken, `VOLL`/unbegrenztes Limit, weit zurückliegendes `@VonUtc`, Plan XML und Referenzdatenbank-/Regexfilter mit XML-Shredding. |
| Haupttreiber | Zahl gewählter Query Stores, Queries und zugehöriger Pläne, die für Mehrplanerkennung gruppiert werden. Querytext-, Regex- und Referenzdatenbankfilter können zusätzliche Text- beziehungsweise Showplanarbeit verursachen; ein Zeitfenster gibt es nicht. |
| Skalierung | Aufwand wächst mit Queries, Planvarianten und überlappenden Runtimezeilen seit `@VonUtc`. Plan-XML-Ausgabe oder Referenzfilter erhöhen XML-CPU, Speicher und Transfer. |
| Ressourcen | CPU/I/O auf Query-Store-Query-, Plan- und Runtimestatistiken, TempDB/Arbeitsspeicher für Gruppierung/Ranking; optional Plan-XML-Materialisierung. |
| Begrenzungswirkung | Datenbank, `@VonUtc`, QueryId/-Hash begrenzen die Quelle. Lokales N+1 wirkt erst nach Plan-/Runtimekorrelation und Ranking; globales TOP begrenzt danach die Rückgabe. Referenzfilter müssen Plan XML bereits vor dem TOP prüfen. |
| Locking und Nebenwirkungen | Read-only gegenüber Query Store; normale interne Synchronisation/Schema-Stability ist möglich. Die Procedure erzwingt, entfernt oder bereinigt keine Pläne/Hints. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `QUERY_STORE_CURRENT`, `QUERY_STORE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, Queryselektor oder jüngerer Start, TOP 100 und kein XML. `VOLL`, Plan XML, Referenzfilter oder >1000/unbegrenzt nur nach Deep-Gate. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierte, retentionbegrenzte Historie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Queries besitzen mehrere gespeicherte Pläne, und wodurch unterscheiden sich deren Lebenszyklus und Compilekontext?

### Technischer Hintergrund

`sys.query_store_plan` speichert PlanId, Plan Hash, Engine Version, Compatibility, Compilezeiten, IsParallel, Forced-Status und Plan XML. Mehrere PlanIds können strukturell gleichen Plan Hash besitzen; Recompile oder Kontextänderung kann neue Zeilen erzeugen.

### Datenkette

`sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.schemas`, `sys.sp_executesql`.

### Source Select

Planwechsel entstehen aus Query, Text und den dazugehörigen Planzeilen:

```sql
SELECT
      [q].[query_id]
    , [q].[query_hash]
    , COUNT_BIG(*) AS [PlanCount]
    , MIN([p].[initial_compile_start_time]) AS [FirstPlanCompile]
    , MAX([p].[last_compile_start_time]) AS [LastPlanCompile]
    , MAX([p].[last_execution_time]) AS [LastPlanExecution]
FROM [sys].[query_store_query] AS [q] WITH (NOLOCK)
JOIN [sys].[query_store_plan] AS [p] WITH (NOLOCK)
  ON [p].[query_id] = [q].[query_id]
WHERE [p].[last_compile_start_time] >= @VonUtc
   OR [p].[last_execution_time] >= @VonUtc
GROUP BY [q].[query_id], [q].[query_hash]
HAVING COUNT_BIG(*) > 1;
```

**Wichtig für die Eigenlast:** Setzen Sie Datenbank und Zeitfenster vor Plananzahl und Text- beziehungsweise XML-Anreicherung. Laden Sie Plan-XML erst für die begrenzte Kandidatenmenge; mehrere Pläne sind zunächst nur ein Befund, keine Regression.

### Zeit- und Scope-Modell

Die Auswertung berücksichtigt den persistierten Planbestand innerhalb der Query-Store-Retention; Last Execution zeigt Aktivität, aber keine dauerhafte Gültigkeit.

### Bewertung und Gegenprobe

Vergleichen Sie PlanCount, DistinctPlanHashCount, Compile-/Executionzeit, Engine/Compatibility, Forced-Status und Runtimewerte je Plan. Ein neuer Plan ist erst bei abweichender Wirkung relevant.

### Typische Fehlinterpretation

Mehrere Pläne bedeuten nicht automatisch Parameter Sensitivity oder Regression. Ein alter nie mehr ausgeführter Plan kann historisch, aber aktuell irrelevant sein.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Runtime Stats je Plan, Regressions, Forced Plans und Showplanvergleich.

## Primärquellen

- [Query Store: Überwachung und Auswertung](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#4-monitorusp_querystoreplanchanges)
