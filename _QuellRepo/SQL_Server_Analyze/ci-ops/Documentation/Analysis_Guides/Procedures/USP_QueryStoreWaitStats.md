# [monitor].[USP_QueryStoreWaitStats]

**Bereich:** Query Store<br>
**Zweck:** Aggregiert historische Query-Store-Waitkategorien je Query und Plan.<br>
**Beobachtungsart:** persistierte, retentionbegrenzte Historie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche groben Waitkategorien dominierten historisch je Query-Store-Plan?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
DECLARE @ExampleBisUtc datetime2(7) = SYSUTCDATETIME();
DECLARE @ExampleVonUtc datetime2(7) = DATEADD(HOUR, -1, @ExampleBisUtc);

EXEC [monitor].[USP_QueryStoreWaitStats]
      @QueryStoreDatabaseNames = N'[ExampleDatabase]',
      @VonUtc = @ExampleVonUtc,
      @BisUtc = @ExampleBisUtc,
      @MaxZeilen = 100,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `waitStats`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Query-/Plan-/Waitkategorie-Aggregation über gespeicherte Intervalle. `RecordedRows` ist nicht die Zahl einzelner Waits oder Ausführungen.

## So lesen

Berücksichtigen Sie Waitkategorie, Totalzeit, Maxwert, Recorded Rows, Query-/Planidentität und Zeitintervalle gemeinsam.

## Warum kann das problematisch sein?

Hohe Totalzeit zeigt kumulative Auswirkung; hoher Maxwert kann einzelne Ausreißer anzeigen. Kategorien sind gröber als Live-Waittypen.

## Wann ist es kein Problem?

Viele Recorded Rows bedeuten viele gespeicherte Messpunkte, nicht automatisch viele Ausführungen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Lock-Wait dominiert nur ein Intervall: möglicher Burst. Täglich stundenlang dominant: systematisches Problem. Prüfen Sie Runtime, Planwechsel und bei Reproduktion Live-Blocking.

**Ähnlich aussehender Gegenfall:** Viele Recorded Rows bedeuten viele gespeicherte Messpunkte, nicht automatisch viele Ausführungen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_QueryStoreWaitStats` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, das standardmäßige einstündige UTC-Fenster und globales TOP 100 ohne Referenzdatenbankfilter. |
| Teuerster Pfad | Viele Datenbanken, `VOLL`/unbegrenztes Limit, mehr als 24 Stunden und Referenzdatenbankfilter; letzterer lädt und zerlegt gespeicherte Showplan-XML, obwohl kein Plan-XML ausgegeben wird. |
| Haupttreiber | Zahl gewählter Query Stores, überlappender Intervalle, Query-/Plan-Kombinationen und Wait-Stats-Zeilen im UTC-Fenster. Referenzdatenbankfilter lädt zusätzlich gespeicherte Showplan-XML; das abschließende TOP spart diese Vorarbeit nicht. |
| Skalierung | Aufwand wächst mit Wait-Stat-Zeilen in überlappenden Intervallen, Plänen, Waitkategorien und Datenbanken. Referenzfilter addieren Showplan-XML-Parsing; SQL-Textbreite erhöht Transfer. |
| Ressourcen | CPU und I/O auf Query-Store-Wait-/Intervalltabellen, Speicher/TempDB für Gruppierung und Sortierung; optional XML-CPU für Referenzobjekte. |
| Begrenzungswirkung | UTC-, Query- und Waitkategoriefilter wirken vor der Aggregation. Das lokale N+1 greift erst nach Gruppierung/Sortierung je Datenbank, das globale TOP anschließend; beide begrenzen nicht alle gelesenen Intervallzeilen. |
| Locking und Nebenwirkungen | Read-only gegenüber Query Store; normale interne Synchronisation/Schema-Stability ist möglich. Die Procedure erzwingt, entfernt oder bereinigt keine Pläne/Hints. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `QUERY_STORE_CURRENT`, `QUERY_STORE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, eine Stunde, TOP 100 und möglichst Query-/Waitfilter. Referenzdatenbankfilter, >24 Stunden, `VOLL` oder >1000 Zeilen nur bewusst mit `QUERY_STORE_DEEP`. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierte, retentionbegrenzte Historie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche groben Waitkategorien dominierten historisch je Query-Store-Plan?

### Technischer Hintergrund

Query Store ordnet konkrete Waittypen Kategorien zu und speichert Total/Avg/Min/Max je Plan, Intervall und Execution Type. Es erfasst Waits während Queryausführung, nicht Compile-Waits. Der Frameworkcode mittelt gespeicherte Intervallmittelwerte ungewichtet und summiert vollständig einbezogene Überlappungsintervalle.

### Datenkette

`sys.database_query_store_options`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.query_store_runtime_stats_interval`, `sys.query_store_wait_stats`, `sys.sp_executesql`.

### Source Select

Waitwerte werden über Intervall und Plan bis zur Query korreliert:

```sql
SELECT
      [q].[query_id]
    , [p].[plan_id]
    , [i].[start_time]
    , [i].[end_time]
    , [ws].[wait_category_desc]
    , [ws].[total_query_wait_time_ms]
    , [ws].[avg_query_wait_time_ms]
FROM [sys].[query_store_wait_stats] AS [ws] WITH (NOLOCK)
JOIN [sys].[query_store_runtime_stats_interval] AS [i] WITH (NOLOCK)
  ON [i].[runtime_stats_interval_id] = [ws].[runtime_stats_interval_id]
JOIN [sys].[query_store_plan] AS [p] WITH (NOLOCK)
  ON [p].[plan_id] = [ws].[plan_id]
JOIN [sys].[query_store_query] AS [q] WITH (NOLOCK)
  ON [q].[query_id] = [p].[query_id]
WHERE [i].[end_time] > @VonUtc
  AND [i].[start_time] < @BisUtc;
```

**Wichtig für die Eigenlast:** Begrenzen Sie Datenbank, Zeitfenster, Waitkategorie und optional Query-ID vor Textprojektion. Query Store speichert Kategorien, nicht jeden einzelnen Engine-Waittyp.

### Zeit- und Scope-Modell

Die Auswertung verwendet persistierte Waitkategorien innerhalb der Retention und bei aktivem Wait Capture; die Werte sind datenbank- und planbezogen.

### Bewertung und Gegenprobe

Korrelieren Sie Total, Max, Recorded Rows, Execution Type und Runtime-Ausführungen. Kategorien priorisieren den Troubleshootingpfad, liefern aber keinen konkreten Blocker oder Wait Resource.

### Typische Fehlinterpretation

`RecordedRows` sind Messzeilen, keine Waitanzahl. Die Average-Spalte ist kein execution-weighted Gesamtdurchschnitt.

### Folgeanalyse

Die kanonischen [Query-Store-Wait-Details](../05_Query_Store.md#3-monitorusp_querystorewaitstats) und das [Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md) verwenden; historische Kategorien bei Bedarf mit Current Waits und Requests validieren.

## Primärquellen

- [Query Store: Überwachung und Auswertung](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#3-monitorusp_querystorewaitstats)
