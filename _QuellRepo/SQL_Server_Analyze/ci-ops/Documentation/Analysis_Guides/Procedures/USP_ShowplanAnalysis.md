# [monitor].[USP_ShowplanAnalysis]

**Bereich:** Plan Cache und Showplan<br>
**Zweck:** Extrahiert Statements, Warnungen, Objekte, Statistiken, Operatoren, Kardinalität, Memory und Parameter aus Plan-XML.<br>
**Beobachtungsart:** flüchtiger Cache-Snapshot<br>
**Kostenklasse:** MEDIUM–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Operatoren, Schätzungen, Warnungen, Objekte, Statistiken und Optimizerhinweise enthält ein Showplan?** Sie unterstützt die Entscheidung, welche aktuell gecachten Query-/Plan-Kandidaten vertieft werden sollen und welche Historienquelle die flüchtige Cachebeobachtung bestätigen muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige Workloadhistorie; evictete Pläne, nicht gecachte Statements und Ursachen außerhalb des Plans bleiben unsichtbar. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ShowplanAnalysis]
      @QueryHash = 0x0102030405060708,
      @AnalyseModus = 'GEZIELT',
      @MaxAnalyseobjekte = 5,
      @MaxDurationSeconds = 10,
      @MaxZeilen = 1000,
      @ResultSetArt = 'CONSOLE';
```

Der Aufruf verwendet ausschließlich einen synthetischen Beispielhash. Echte Hashes dürfen nur für eine kontrollierte Laufzeitanalyse verwendet und nicht ungeprüft weitergegeben werden.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `parameters`, `planWarnings`,
`optimizerContext`, `runtimeFeedback`, `queryStoreContext`,
`feedbackAndVariants` und `findings`. Status und Scope sind vor den
Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON
erhalten zusätzlich `moduleStatus`, `planStatus` und die kandidatengenauen
DIAG-003-/DIAG-005-Ergebnisse. Resultsets mit unterschiedlicher
Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einem Finding, einer Parameterevidenz,
einer Planwarnung, einem Statementkontext, einer Runtimebeobachtung, einem
Query-Store-Kontext oder einem Feature-/Variantenmerkmal. `CandidateId` und
`PlanHandle` stellen in allen kanonischen Ergebnissen den äußeren
Mehrplanbezug her.

## So lesen

Prüfen Sie zuerst `planStatus`. Lesen Sie in `parameters` anschließend
`ValueSource`, Presence-/SQL-NULL-Flags, `ValueStatus`, Quellzeit,
Current-/Last-known-Semantik und `IsComplete`. Ordnen Sie dann Warnungen,
Optimizer-/Cachekontext, Runtimefeedback und Varianten anhand von Quelle,
Zeitbezug, Mess-/Ableitungsflags und False-Positive-Grenze ein. Vertiefen Sie
danach die Findings im jeweiligen Child-Analyse-JSON.

## Warum kann das problematisch sein?

Große Estimate-/Actual-Abweichungen können ungeeignete Joinarten, Grants und Zugriffspfade verursachen. Spills zeigen Auslagerung nach TempDB.

## Wann ist es kein Problem?

Ratio 10 bei 1 zu 10 Zeilen ist meist weniger relevant als Ratio 10 bei 10 Mio. zu 100 Mio. Zeilen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Estimate 1, Actual 10 Mio. kann Nested Loops oder einen kleinen Grant kollabieren lassen. Prüfen Sie Statistik, Parameter, Query Store, Index und Memory.

**Ähnlich aussehender Gegenfall:** Ratio 10 bei 1 zu 10 Zeilen ist meist weniger relevant als Ratio 10 bei 10 Mio. zu 100 Mio. Zeilen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Im Plan Cache kann leer bedeuten: evicted, nie gecacht, recompile, falscher Datenbank-/Hashfilter oder fehlender Text-/Planzugriff.

Für `USP_ShowplanAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

XML-XQuery ist CPU-intensiv. Halten Sie Scope, Zeit- und Objektbudget klein.

**Quellcode-Hinweis zur Eigenlast:** XML wird erst nach Kandidatenselektion planweise geladen und geschreddert. VOLL oder mehr als 20 Pläne prüft PLAN_CACHE_DEEP und SHOWPLAN_XML_DEEP; dies gilt ebenfalls ab mehr als 20 Plänen. Zeit- und Mengenlimits sind hart vorgesehen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM–HIGH_OPT_IN |
| Standardpfad | `GEZIELT`, maximal 20 Candidates, 30-Sekunden-Deadline und 50.000 Ergebniszeilen. Ohne Handle/Hash/Text-/Datenbankfilter rangiert der Code trotzdem den sichtbaren Query-Stats-Snapshot und nimmt die Top-Candidates nach `@Sortierung`. |
| Teuerster Pfad | `VOLL` oder unbegrenzte Candidates, große Plan-XMLs, 3.600-Sekunden-Deadline und unbegrenztes Zeilenbudget. Jeder Plan wird durch die zentrale Engine in mehrere fachliche Granularitäten zerlegt. |
| Haupttreiber | Zahl/Größe der ausgewählten Compile- oder Last-Actual-Pläne und Operator-/Statementknoten je XML. Candidate-Ranking liest frisch `sys.dm_exec_query_stats` oder verwendet den Parent-Snapshot. |
| Skalierung | Candidateauswahl scannt/rangiert den Cache einmal und materialisiert dabei den wiederverwendeten Cachekontext; anschließend wächst XQuery-Arbeit planweise mit XML-Komplexität. Die Child-Analyse zerlegt den Plan einmal; die äußere Procedure aggregiert deren JSON und führt keine zweite Parameter- oder Feature-XQuery aus. |
| Ressourcen | CPU, Speicher und TempDB für XML-Laden und -Shredding; Cachezugriff sowie großer Transfer bei vollständigem Plan XML. |
| Begrenzungswirkung | Candidate-Limit wirkt vor dem Planladen. Deadline und Finding-/Zeilenbudget werden zwischen Candidates geprüft, können aber das bereits begonnene XML-Shredding eines großen Plans nicht abbrechen. Die Ausgabe erhält zusätzlich pro Resultset TOP; Filter vor dem Ranking sind wirksamer. |
| Locking und Nebenwirkungen | Keine Nutzdatenänderung. Cachehandles können verschwinden; `LAST_ACTUAL` liefert nur vorhandene Last-Actual-Evidenz und aktiviert kein Profiling. XML-Auswertung kann erhebliche Schedulerzeit verbrauchen. |
| Schutzmechanismus | Bei `VOLL` oder mehr als 20/unbegrenzten Candidates prüft der Code nacheinander `PLAN_CACHE_DEEP` und `SHOWPLAN_XML_DEEP`. Einen separaten `SHOWPLAN_TARGETED`-Check gibt es in dieser Implementierung nicht. Bestätigung ersetzt Filter, Deadline und Mengenbudget nicht. |
| Sicherer Einsatz | Genau einen `ExampleQueryHash`/PlanHandle untersuchen, höchstens wenige Kandidaten und kurze Deadline. `LAST_ACTUAL` sowie `VOLL` nur bewusst und mit beiden Deep-Gates. |
| Aussagegrenze | Cacheeviction kann zwischen Ranking und XML-Laden auftreten. Compile-Pläne enthalten keine Ist-Zeilen; LAST_ACTUAL nur bereits vorhandene Profilingevidenz. Deadline/Top-N priorisiert, kann aber gerade den ursächlichen späteren Plan auslassen. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Operatoren, Schätzungen, Warnungen, Objekte, Statistiken und Optimizerhinweise enthält ein Showplan?

### Technischer Hintergrund

Showplan XML modelliert RelOp-Baum, Estimated Rows/Cost, Predicate, Object/Index, Statistics, Memory Grant, Parallelism und Warnings. Cached/Query-Store-Pläne sind typischerweise Estimated-/Compilepläne; Actual Rows existieren nur in tatsächlichen Ausführungsplänen beziehungsweise entsprechenden Runtimefeatures.

### Datenkette

`master.sys.databases`, `sys.dm_exec_plan_attributes`, `sys.dm_exec_query_plan`, `sys.dm_exec_query_plan_stats`, `sys.dm_exec_query_stats`, `sys.dm_exec_sql_text`, `sys.sp_executesql`.

### Source Select

Die Procedure selektiert zuerst eindeutige Planhandles und delegiert deren Planauflösung an `USP_ExecutionPlanAnalysis`:

```sql
SELECT
      [qs].[query_hash]
    , [qs].[query_plan_hash]
    , [qs].[plan_handle]
    , [qs].[execution_count]
    , [st].[text]
FROM [sys].[dm_exec_query_stats] AS [qs] WITH (NOLOCK)
OUTER APPLY [sys].[dm_exec_sql_text]([qs].[sql_handle]) AS [st]
WHERE [qs].[plan_handle] = @PlanHandle;
```

**Wichtig für die Eigenlast:** Setzen Sie Plan Handle, Query Hash oder enger Top-Kandidat vor dem Childaufruf. Erst `USP_ExecutionPlanAnalysis` beschafft und zerlegt das Plan-XML; Operator- und Warning-Extraktion wächst mit der XML-Größe und benötigt im breiten Pfad das entsprechende Gate.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den Planstand zum Compile- beziehungsweise Capturezeitpunkt; die zugrunde liegenden Daten oder Statistiken können inzwischen geändert sein.

### Bewertung und Gegenprobe

Berücksichtigen Sie den Operatorfluss von unten nach oben, Estimated und Actual, sofern vorhanden, die Join- und Accessmethode, Predicate, Spills, Conversions, Missing Index sowie Memory und Parallelism gemeinsam. Priorisieren Sie eine Warnung zusammen mit ihrer Runtimewirkung.

### Typische Fehlinterpretation

Estimated Cost ist keine gemessene Zeit und zwischen unabhängigen Servern/CE-Kontexten nicht absolut vergleichbar. Missing-Index-XML ist keine fertige DDL.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Statistics Distribution, Query Store Runtime/Regression und reale Laufzeitmessung.

## Primärquellen

- [Showplan XML](https://learn.microsoft.com/en-us/sql/relational-databases/showplan-logical-and-physical-operators-reference?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../04_Plan_Cache.md#5-monitorusp_showplananalysis)
