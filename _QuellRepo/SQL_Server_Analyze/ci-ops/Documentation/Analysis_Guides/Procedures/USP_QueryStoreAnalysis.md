# [monitor].[USP_QueryStoreAnalysis]

**Bereich:** Query Store, Orchestrator<br>
**Zweck:** Orchestriert Status, Runtime, Waits, Planwechsel, Regressionen, Forced Plans, Hints und IQP.<br>
**Beobachtungsart:** nicht atomare Folge persistierter Query-Store-Historien<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Query-Store-Perspektiven sollen kontrolliert in einem Lauf ausgeführt werden?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
DECLARE @ExampleBisUtc datetime2(7) = SYSUTCDATETIME();
DECLARE @ExampleVonUtc datetime2(7) = DATEADD(HOUR, -1, @ExampleBisUtc);

EXEC [monitor].[USP_QueryStoreAnalysis]
      @QueryStoreDatabaseNames = N'[ExampleDatabase]',
      @VonUtc = @ExampleVonUtc,
      @BisUtc = @ExampleBisUtc,
      @MitStatus = 1,
      @MitRuntimeStats = 1,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Ohne `@VonUtc`/`@BisUtc` aggregiert das Runtime-Child die gesamte noch
aufbewahrte Query-Store-Historie. Das kurze Fenster ist deshalb ein
Quellkosten- und zugleich ein Aussage-Scope, nicht nur ein Ausgabefilter.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `moduleStatus`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Die Granularität hängt vom Child ab: Datenbank, Query/Plan-Aggregat, Waitkategorie, Plan, Hint oder IQP-Signal.

## So lesen

Prüfen Sie zuerst das Status-Child und danach nur die aktivierten Children. Beachten Sie Zeitfenster und Wrappersemantik der Regressionen.

## Warum kann das problematisch sein?

Ein historisches Ergebnis kann durch Capture, Retention oder Wrapperfenster falsch eingeordnet werden. Der Wrapper übergibt das Fenster als Vergleichsfenster; die Baseline liegt davor.

## Wann ist es kein Problem?

Deaktivierte Children fehlen absichtlich.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Letzte Stunde als Eingabefenster bedeutet: Vergleich letzte Stunde, Baseline die Stunde davor. Wiederholen Sie Auffälliges Child mit QueryId/Hash und engem Zeitraum.

**Ähnlich aussehender Gegenfall:** Deaktivierte Children fehlen absichtlich. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_QueryStoreAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Status plus Runtime Stats. Bei `@VonUtc = NULL` und `@BisUtc = NULL` ist der Runtimepfad zeitlich nicht klein, sondern aggregiert die gesamte aufbewahrte Historie jeder gewählten Query-Store-Datenbank. |
| Teuerster Pfad | Alle acht Children über mehrere große Query Stores ohne Zeit- oder Zeilenlimit und mit Referenzdatenbankfilter: dieselben Query-/Plan-/Runtimebereiche werden mehrfach aggregiert; mehrere Children müssen Plan-XML zur Referenzauflösung parsen. |
| Haupttreiber | Zahl der Query-Store-Datenbanken, Queries, Pläne, Runtime-/Wait-Intervalle und Breite des Zeitfensters. Referenzdatenbankfilter verlagern Arbeit in Plan-XML-Auswertung; IQP ergänzt datenbankweite Konfigurations-/Feedbackaggregation. |
| Skalierung | Children laufen nacheinander ohne gemeinsamen Query-Store-Snapshot. Status ist klein, Runtime/Wait/Regressionen skalieren mit Intervallen, und PlanChanges/ForcedPlans mit Plananzahl. Dasselbe Zeitfenster wird je aktiviertem Historienchild separat verarbeitet. |
| Ressourcen | I/O und CPU in den persistenten `sys.query_store_*`-Views, Sortierung/Aggregation, dynamisches Cross-Database-SQL, optional Plan-XML und JSON/Transfer. Kein `msdb`, XEL oder WAITFOR. |
| Begrenzungswirkung | `@VonUtc`/`@BisUtc` reduzieren nur zeitfähige Children; Status, Forced Plans und Hints haben andere beziehungsweise keine Zeitsemantik. `@MaxZeilen` gilt je Child nach dessen eigener Aggregations-/Kandidatenlogik und verhindert nicht automatisch das Lesen aller passenden Intervalle. |
| Locking und Nebenwirkungen | Read-only; es werden weder Pläne erzwungen noch Hints gesetzt. Query Store erfasst während des sequenziellen Laufs weiter, daher können Childnenner und „letzte“ Zeitpunkte voneinander abweichen. |
| Schutzmechanismus | Datenbankscope und IQP-/Cross-Database-Pfade werden über Childanalyseklassen und `@HighImpactConfirmed` geprüft; sechs teurere Perspektiven sind standardmäßig aus. Der Gate-Schalter ist kein Zeitfenster und kein Max-Rows-Ersatz. |
| Sicherer Einsatz | Eine Query-Store-Datenbank, ein enges UTC-Fenster, Status + Runtime und `@MaxZeilen = 100`. Referenzdatenbankfilter sowie weitere Children erst nach einem konkreten Query-/Planbefund aktivieren. |
| Aussagegrenze | Zeitfilter und Retention bestimmen gemeinsam, was historisch sichtbar ist. Ein Top-N je Child kann unterschiedliche Queries zeigen; Planwechsel, Regression und Waits dürfen nur über Query-/Plan-ID plus Fenster korreliert werden, nicht über Zeilenposition. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Query-Store-Perspektiven sollen kontrolliert in einem Lauf ausgeführt werden?

### Technischer Hintergrund

Der Wrapper orchestriert Status, Runtime, Waits, PlanChanges, Regressions, Forced Plans, Hints und IQP. Er übergibt gemeinsame Datenbankscope-/Zeitparameter, aber einzelne Children interpretieren Fenster unterschiedlich.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung; die Quellen liegen in den Childmodulen.

### Source Select

Kein einzelnes Grundselect wird verwendet. Die Procedure orchestriert Status, Runtime Stats, Wait Stats, Planwechsel, Regressionen, Forced Plans, Hints und optional IQP-Details. Alle Childmodule lesen die ausgewählte Datenbank separat.

**Wichtig für die Eigenlast:** Legen Sie Datenbank, Zeitfenster und benötigte Childmodule vor jeder Query-Store-Abfrage fest. Ein finales Ergebnislimit verhindert weder Interval-/Runtime-Joins noch Plan-XML-Auflösung in den Childpfaden.

### Zeit- und Scope-Modell

Die Auswertung liest persistierte Queries in einer nicht atomaren Folge; der Childstatus gilt jeweils für eine Datenbank.

### Bewertung und Gegenprobe

Prüfen Sie zuerst den Status. Priorisieren Sie danach die Runtime und vertiefen Sie Wait, Plan, Regression und Intervention nur bei Bedarf. Deep-Optionen, Plan-XML und viele Datenbanken erhöhen die Kosten.

### Typische Fehlinterpretation

Ein Wrapperfenster kann für Regression als Comparison Window verwendet werden, während die Baseline davor abgeleitet wird. Führen Sie Resultsets nicht ohne Childnamen und Childstatus zusammen.

### Folgeanalyse

Führen Sie das betroffene Child gezielt erneut aus.

## Primärquellen

- [Query Store: Überwachung und Auswertung](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#9-monitorusp_querystoreanalysis)
Für einen in den Query-Store-Children ausgewählten Plan liefert
`USP_ExecutionPlanAnalysis` den gezielten DIAG-005-Vertrag mit
`queryStoreContext` und `feedbackAndVariants`. Dieser Folgepfad liest keinen
Querytext und behandelt persistierte Hint-/Feedbackpayloads nach dem
angeforderten Evidenzdatenschutzmodus.

