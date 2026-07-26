# [monitor].[USP_QueryStoreForcedPlans]

**Bereich:** Query Store<br>
**Zweck:** Inventarisiert erzwungene Pläne und Plan-Forcing-Fehler.<br>
**Beobachtungsart:** persistierter Konfigurationsstand + Planhistorie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Pläne werden erzwungen, funktionieren sie technisch und sind sie noch betrieblich begründet?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_QueryStoreForcedPlans]
      @QueryStoreDatabaseNames = N'[ExampleDatabase]',
      @NurMitFehler = 0,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `forcedPlans`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Query-Store-Plan mit Forcingmetadaten.

## So lesen

Berücksichtigen Sie `IsForcedPlan`, Forcing Type, Failure Count/Reason, letzte Ausführung, Engineversion und Compatibility gemeinsam.

## Warum kann das problematisch sein?

Force-Fehler bedeuten, dass die gewünschte Bindung nicht zuverlässig angewendet wird. Ein alter Forced Plan kann neue Optimizerverbesserungen verhindern.

## Wann ist es kein Problem?

Ein fehlerfrei erzwungener Plan mit stabiler Performance kann bewusste Risikokontrolle sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** 50 Force-Fehler plus aktuelle Regression ist dringender als ein stabiler alter Forced Plan ohne Fehler. Prüfen Sie Runtimevergleich, Plan Changes und Rücknahmepfad.

**Ähnlich aussehender Gegenfall:** Ein fehlerfrei erzwungener Plan mit stabiler Performance kann bewusste Risikokontrolle sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_QueryStoreForcedPlans` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, TOP 100, gekürzter SQL-Text und kein Plan XML; es werden ausschließlich aktuell als forced markierte Query-Store-Pläne inventarisiert. |
| Teuerster Pfad | Viele Datenbanken, unbegrenztes/hohes Limit, vollständiger SQL-Text, Plan XML und Referenzdatenbank-/Regexfilter. Einen Zeitfensterparameter besitzt die Procedure nicht. |
| Haupttreiber | Zahl gewählter Query Stores und aktuell forced markierter Pläne samt Querytext. Volltext, Plan-XML, Regex und Referenzdatenbankfilter verbreitern beziehungsweise verteuern jeden Kandidaten; ein Zeitfenster existiert nicht. |
| Skalierung | Aufwand wächst mit Query-Store-Plan-/Queryzeilen und ausgewählten Datenbanken; Plan-/Textbreite sowie Referenz-XML-Parsing können CPU, Speicher und Transfer dominieren. |
| Ressourcen | Query-Store-I/O und CPU für Plan-/Query-/Textjoin und Ranking; optional Plan-XML-Materialisierung beziehungsweise XML-Shredding. Keine Fensteraggregation. |
| Begrenzungswirkung | QueryId und `@NurMitFehler` wirken vor dem lokalen TOP N+1. Das Limit ist lokal und anschließend global, verhindert aber Referenz-XML-Prüfung der zu betrachtenden Forced-Plan-Zeilen nicht zuverlässig. Textzeichen begrenzen nur Ausgabegröße. |
| Locking und Nebenwirkungen | Read-only gegenüber Query Store; normale interne Synchronisation/Schema-Stability ist möglich. Die Procedure erzwingt, entfernt oder bereinigt keine Pläne/Hints. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `QUERY_STORE_CURRENT`, `QUERY_STORE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, `@NurMitFehler = 1`, TOP 100 und kein Plan XML. Plan XML, Referenzfilter oder >1000/unbegrenzt nur nach `QUERY_STORE_DEEP`. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierter Konfigurationsstand + Planhistorie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Pläne werden erzwungen, funktionieren sie technisch und sind sie noch betrieblich begründet?

### Technischer Hintergrund

Query Store Plan Forcing beeinflusst die Planwahl über gespeicherte Planrepräsentation. Metadaten enthalten Forcing Type, Failure Count/Reason, Compile-/Executionzeit und Version. Schema-/Index-/Engineänderungen können Forcing verhindern oder seine Qualität verändern.

### Datenkette

`sys.database_query_store_options`, `sys.objects`, `sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`, `sys.schemas`, `sys.sp_executesql`.

### Source Select

Forced Plans werden über Plan, Query und Query Text verbunden; der Force-Status ist das frühe Fachprädikat:

```sql
SELECT
      [p].[plan_id]
    , [p].[query_id]
    , [p].[is_forced_plan]
    , [p].[force_failure_count]
    , [p].[last_force_failure_reason_desc]
    , [q].[object_id]
    , [qt].[query_sql_text]
FROM [sys].[query_store_plan] AS [p] WITH (NOLOCK)
JOIN [sys].[query_store_query] AS [q] WITH (NOLOCK)
  ON [q].[query_id] = [p].[query_id]
JOIN [sys].[query_store_query_text] AS [qt] WITH (NOLOCK)
  ON [qt].[query_text_id] = [q].[query_text_id]
WHERE [p].[is_forced_plan] = 1;
```

**Wichtig für die Eigenlast:** Datenbank und Forced-Status vor SQL-Text und Plan-XML anwenden. Vollständiges XML nur für einzelne `plan_id`-Kandidaten lesen; die Inventarisierung benötigt es nicht.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Forcingstatus sowie den persistierten Planlebenszyklus.

### Bewertung und Gegenprobe

Prüfen Sie Fehler, letzte Nutzung, Runtime im Vergleich zu Alternativen, Engine-/Compatibilitywechsel und Owner/Reviewdatum. Stabilität kann wichtiger als minimaler Durchschnitt sein.

### Typische Fehlinterpretation

`IsForcedPlan=1` beweist nicht, dass der Plan aktuell benutzt oder optimal ist. `0` Fehler beweist nur technischen Erfolg, nicht fachlichen Nutzen.

### Folgeanalyse

Verwenden Sie für die weitere Analyse Runtime, Regressions und PlanChanges. Nehmen Sie eine Änderung nur mit einem Rollback- und Monitoringplan vor.

## Primärquellen

- [Query Store: Überwachung und Auswertung](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#6-monitorusp_querystoreforcedplans)
