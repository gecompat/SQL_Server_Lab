# [monitor].[USP_QueryStoreRegressions]

**Bereich:** Query Store<br>
**Zweck:** Vergleicht zwei Zeitfenster nach Dauer, CPU, Reads, Writes oder Ausführungen.<br>
**Beobachtungsart:** persistierte, retentionbegrenzte Historie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Hat sich eine gewählte Metrik zwischen Baseline- und Vergleichsfenster belastbar verschlechtert?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_QueryStoreRegressions]
      @QueryStoreDatabaseNames = N'[ExampleDatabase]',
      @MinAusfuehrungenJeFenster = 10,
      @MinRegressionProzent = 20,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `regressions`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Query mit aggregierter Baseline und aggregiertem Vergleichsfenster. Sie ist kein Vergleich zweier Einzelaufrufe.

## So lesen

Berücksichtigen Sie Fenstergrenzen, Ausführungsanzahl, absolute Werte, Plananzahl und Prozentänderung gemeinsam.

## Warum kann das problematisch sein?

Eine belastbare Regression bedeutet, dass vergleichbarer Workload im neuen Fenster deutlich mehr Zeit oder Ressourcen benötigt.

## Wann ist es kein Problem?

Große Prozentwerte bei sehr kleiner Stichprobe können durch Parameter, Datenmenge oder Zufall entstehen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 100 ms → 150 ms bei je 100.000 Ausführungen: belastbare 50-%-Regression. 1 ms → 10 ms bei je einer Ausführung: 900 %, aber schwache Evidenz.

**Bisher dokumentierter Folgeschritt:** Verwenden Sie Plan Changes, Wait Stats und konkrete Parameter-/Plananalyse. Keine automatische Plan-Forcing-Entscheidung.

**Ähnlich aussehender Gegenfall:** Große Prozentwerte bei sehr kleiner Stichprobe können durch Parameter, Datenmenge oder Zufall entstehen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_QueryStoreRegressions` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, zwei kurze nicht überlappende Vergleichsfenster, TOP 100 und kein Referenzdatenbankfilter. |
| Teuerster Pfad | Viele Datenbanken, `VOLL`/unbegrenztes Limit, Gesamtspanne über 24 Stunden und Referenzdatenbank-/Regexfilter; dafür wird gespeichertes Showplan-XML intern zerlegt. |
| Haupttreiber | Zahl gewählter Query Stores, Runtimeintervalle und Query-/Plan-Kombinationen in beiden Vergleichsfenstern. Ein Referenzdatenbankfilter kann zusätzlich gespeicherte Showplan-XML laden und zerlegen, bevor die Regressionen rangiert werden. |
| Skalierung | Zwei Fenster müssen je Query/Plan aggregiert und verglichen werden; Aufwand wächst mit Intervallen, Queries, Datenbanken und Gesamtspanne. Referenzfilter addieren Plan-XML-Parsing. |
| Ressourcen | Query-Store-I/O, CPU/TempDB für zwei Aggregationen, Join und Regressionranking; SQL-Texttransfer sowie optional XML-CPU für Referenzobjektfilter. |
| Begrenzungswirkung | Fenster, QueryId/-Hash und Mindestexecutions reduzieren Quell-/Ergebnisarbeit. N+1/Global-TOP greifen erst nach beiden Fensteraggregationen und begrenzen die zuvor gelesenen Runtimezeilen nicht. |
| Locking und Nebenwirkungen | Read-only gegenüber Query Store; normale interne Synchronisation/Schema-Stability ist möglich. Die Procedure erzwingt, entfernt oder bereinigt keine Pläne/Hints. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `QUERY_STORE_CURRENT`, `QUERY_STORE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, gleichartige kurze Fenster und TOP 100; Queryfilter bevorzugen. Mehr als 24 Stunden, `VOLL`, Referenzfilter oder >1000/unbegrenzt nur nach Deep-Gate. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierte, retentionbegrenzte Historie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Hat sich eine gewählte Metrik zwischen Baseline- und Vergleichsfenster belastbar verschlechtert?

### Technischer Hintergrund

Die Procedure aggregiert zwei nicht überlappende Zeiträume und vergleicht Duration, CPU, Reads, Writes oder Executions. Prozentänderung teilt die absolute Änderung durch den Baselinewert; Baseline nahe null macht Prozent instabil. Intervalle können Fenstergrenzen überlappen.

### Datenkette

`sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.query_store_runtime_stats`, `sys.query_store_runtime_stats_interval`, `sys.schemas`, `sys.sp_executesql`.

### Source Select

Der kostenbestimmende Join verbindet Runtime-Statistik, Intervall, Plan und Query; beide Vergleichsfenster müssen früh begrenzt werden:

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
WHERE [i].[end_time] > @BaselineVonUtc
  AND [i].[start_time] < @ProblemBisUtc;
```

**Wichtig für die Eigenlast:** Setzen Sie Baseline- und Problemfenster sowie Datenbank vor Aggregation, Ranking und SQL-Text. `@MaxZeilen` wirkt erst nach dem Vergleich und spart die Interval-Joins nicht.

### Zeit- und Scope-Modell

Die Auswertung vergleicht zwei persistierte Query-Store-Fenster innerhalb der Retention; der Standardvergleich und die abgeleitete Baseline müssen im Wrapperkontext dokumentiert sein.

### Bewertung und Gegenprobe

Berücksichtigen Sie Baseline/Comparison Executions, PlanCount, absolute Änderung, Prozent, Datenvolumen und Workloadmix gemeinsam. Erhöhen Sie Mindestexecutionzahl passend zur Workload.

### Typische Fehlinterpretation

900 Prozent bei je einer Ausführung ist schwache Evidenz. Geänderte Parameter-/Datenmengen können Effizienz- statt Planregression vortäuschen.

### Folgeanalyse

Verwenden Sie für die weitere Analyse PlanChanges, WaitStats, RuntimeStats und Showplan. Erzwingen Sie einen Plan nicht ohne fachliche Prüfung.

## Primärquellen

- [Query Store: Überwachung und Auswertung](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#5-monitorusp_querystoreregressions)
