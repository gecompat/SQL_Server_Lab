# [monitor].[USP_QueryStoreRuntimeStats]

**Bereich:** Query Store<br>
**Zweck:** Aggregiert historische Laufzeit- und Ressourcenwerte je Query und Plan über Query-Store-Intervalle.<br>
**Beobachtungsart:** persistierte, retentionbegrenzte Historie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Query-/Plan-Kombinationen verursachten im gewählten historischen Fenster Ausführungen, Dauer, CPU, I/O, Memory, TempDB oder Loglast?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
DECLARE @ExampleBisUtc datetime2(7) = SYSUTCDATETIME();
DECLARE @ExampleVonUtc datetime2(7) = DATEADD(HOUR, -1, @ExampleBisUtc);

EXEC [monitor].[USP_QueryStoreRuntimeStats]
      @QueryStoreDatabaseNames = N'[ExampleDatabase]',
      @VonUtc = @ExampleVonUtc,
      @BisUtc = @ExampleBisUtc,
      @Sortierung = 'CPU_TOTAL',
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `runtimeStats`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Aggregation je Query, Plan und Ausführungstyp über alle berücksichtigten Runtime-Intervalle. Sie ist keine einzelne Ausführung.

## So lesen

Vergleichen Sie Zeitfenster und Intervalllänge, `ExecutionCount`, Total- und Averagewerte sowie `PlanId`.

## Warum kann das problematisch sein?

Mehrere Pläne derselben Query mit stark unterschiedlichen Werten können Regression oder Parameter Sensitivity anzeigen.

## Wann ist es kein Problem?

Hohe Total-CPU bei sehr vielen Ausführungen kann pro Aufruf klein sein. Hohe Average-Dauer bei einer Ausführung ist schwache Evidenz.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Plan A: 10 ms × 100.000; Plan B: 500 ms × 20. B ist pro Aufruf schlechter, A kann aber mehr Gesamtlast erzeugen. Prüfen Sie Waits, Plan Changes und Showplan.

**Ähnlich aussehender Gegenfall:** Hohe Total-CPU bei sehr vielen Ausführungen kann pro Aufruf klein sein. Hohe Average-Dauer bei einer Ausführung ist schwache Evidenz. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_QueryStoreRuntimeStats` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Randintervalle können Messanteile außerhalb des exakten Fensters enthalten.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, kurzes UTC-Fenster, TOP 100, kein Plan XML und keine Referenzdatenbankauflösung. Lokal werden höchstens N+1 gerankte Kandidaten übernommen. |
| Teuerster Pfad | Viele Datenbanken, `VOLL` beziehungsweise unbegrenztes/hohes Limit, langer Zeitraum, Plan XML und Referenzdatenbank-/Regexfilter. Aggregation und XML-Prüfung können große Retentionsbestände berühren. |
| Haupttreiber | Zahl der gewählten Query Stores, überlappenden Runtimeintervalle, Query-/Plan-Kombinationen und Ausführungsstatistikzeilen. Ohne enges UTC-Fenster wächst die Aggregation mit der gesamten aufbewahrten Historie; Referenzfilter können Plan-XML ergänzen. |
| Skalierung | Quellarbeit wächst mit überlappenden Runtimeintervallen, Queries/Plänen und Datenbanken. Plan-XML-/Referenzfilter erhöhen CPU und Speicher; Text-/Planbreite erhöht Transfer. |
| Ressourcen | CPU und I/O auf Query-Store-internen Tabellen, TempDB für Fensteraggregation und Transfer für Texte/Pläne; Umfang folgt Retention und Capturevolumen. |
| Begrenzungswirkung | Datenbank, UTC-Fenster, QueryId/-Hash und Textfilter begrenzen die Quelle. N+1 wird jedoch erst nach Intervallaggregation und Sortierung je Datenbank angewandt; es begrenzt nicht die dafür gelesenen Historyzeilen. Das globale TOP wird anschließend über lokale Kandidaten gebildet. |
| Locking und Nebenwirkungen | Read-only gegenüber Query Store; normale interne Synchronisation/Schema-Stability ist möglich. Die Procedure erzwingt, entfernt oder bereinigt keine Pläne/Hints. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `QUERY_STORE_CURRENT`, `QUERY_STORE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, einstündiges UTC-Fenster, TOP 100 und kein XML. `VOLL`, >1000/unbegrenzt, Regex-/Referenzfilter oder breite Zeitfenster erst nach `QUERY_STORE_DEEP`-Bestätigung. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierte, retentionbegrenzte Historie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Query-/Plan-Kombinationen verursachten im gewählten historischen Fenster Ausführungen, Dauer, CPU, I/O, Memory, TempDB oder Loglast?

### Technischer Hintergrund

Runtime Stats speichern aggregierte Messwerte je Plan, Intervall und Execution Type. Totalwerte entstehen aus Intervallsummen; globale Averagewerte müssen nach Ausführungszahl gewichtet werden, wenn der Code nicht bereits gewichtete Totals verwendet. Query, Plan und Text werden über IDs verbunden, die nur innerhalb der Query-Store-Datenbank eindeutig sind.

### Datenkette

`sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.query_store_runtime_stats`, `sys.query_store_runtime_stats_interval`, `sys.schemas`, `sys.sp_executesql`.

### Source Select

Runtimewerte werden über Intervall, Plan, Query und Query Text verbunden:

```sql
SELECT
      [q].[query_id]
    , [p].[plan_id]
    , [i].[start_time]
    , [i].[end_time]
    , [rs].[count_executions]
    , [rs].[avg_duration]
    , [rs].[avg_cpu_time]
    , [rs].[avg_logical_io_reads]
FROM [sys].[query_store_runtime_stats] AS [rs] WITH (NOLOCK)
JOIN [sys].[query_store_runtime_stats_interval] AS [i] WITH (NOLOCK)
  ON [i].[runtime_stats_interval_id] = [rs].[runtime_stats_interval_id]
JOIN [sys].[query_store_plan] AS [p] WITH (NOLOCK)
  ON [p].[plan_id] = [rs].[plan_id]
JOIN [sys].[query_store_query] AS [q] WITH (NOLOCK)
  ON [q].[query_id] = [p].[query_id]
WHERE [i].[end_time] > @VonUtc
  AND [i].[start_time] < @BisUtc;
```

**Wichtig für die Eigenlast:** Zeitfenster und optional `query_id`/Query Hash vor Text- und Planprojektion anwenden. Die Intervallmenge bestimmt CPU und Speicher; ein späteres Top-N reduziert nur das Ergebnisranking.

### Zeit- und Scope-Modell

Die Auswertung verwendet eine persistierte, nach Intervallen aggregierte Historie innerhalb der Retention. Überlappende Randintervalle können vollständig einbezogen sein.

### Bewertung und Gegenprobe

Berücksichtigen Sie Total und Average stets zusammen mit Execution Count, PlanId, Execution Type und Zeitspanne. Eine hohe Total-CPU bei niedriger Average-CPU ist eine kumulative Optimierungschance; eine hohe Average-Duration bei niedriger CPU verlangt Wait-, Blocking- und I/O-Kontext.

### Typische Fehlinterpretation

Durchschnittswerte verdecken P95/P99, multimodale Parametergruppen und Ausreißer. Query Store Runtime ist keine Storage-Latenzmessung.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_QueryStoreWaitStats`, PlanChanges, Regressions und Showplan.

## Primärquellen

- [Query Store: Überwachung und Auswertung](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#2-monitorusp_querystoreruntimestats)
