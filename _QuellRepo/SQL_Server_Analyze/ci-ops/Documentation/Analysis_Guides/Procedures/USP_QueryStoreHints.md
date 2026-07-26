# [monitor].[USP_QueryStoreHints]

**Bereich:** Query Store<br>
**Zweck:** Inventarisiert Query Store Hints, Herkunft und Anwendungsfehler.<br>
**Beobachtungsart:** persistierter Konfigurationsstand<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Query Store Hints greifen auf Queries ein, und schlagen sie fehl oder überdecken sie inzwischen bessere Optimizerentscheidungen?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_QueryStoreHints]
      @QueryStoreDatabaseNames = N'[ExampleDatabase]',
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `queryHints`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einem Query Store Hint für eine Query und gegebenenfalls Replica-Gruppe.

## So lesen

Berücksichtigen Sie Hinttext, Quelle, Failure Count/Reason, Queryidentität und letzte Relevanz gemeinsam.

## Warum kann das problematisch sein?

Ein Hint begrenzt Optimizerfreiheit und kann nach Daten-, Schema- oder Versionsänderungen schädlich werden.

## Wann ist es kein Problem?

Ein dokumentierter, getesteter Hint kann eine bewusste Maßnahme sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Fehlerfrei angewendet bedeutet nur „wirksam“, nicht „weiterhin nützlich“. Prüfen Sie Runtime, Regression, Plan Changes, Owner und Reviewdatum.

**Ähnlich aussehender Gegenfall:** Ein dokumentierter, getesteter Hint kann eine bewusste Maßnahme sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_QueryStoreHints` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase`, TOP 100 und auf 4000 Zeichen gekürzter Querytext. Die Procedure liest Hinttext und Anwendungsfehler, aber weder Zeitfenster noch Plan XML. |
| Teuerster Pfad | Viele Datenbanken, unbegrenztes/hohes Limit und ungekürzte Hint-/Querytexte bei sehr vielen gespeicherten Query Store Hints. |
| Haupttreiber | Zahl gewählter Query Stores und vorhandener Hintzeilen samt zugehörigem Querytext. Volltext und Regex erhöhen Breite beziehungsweise späte Filterarbeit; Runtimeintervalle und Plan-XML werden in diesem Inventarpfad nicht gelesen. |
| Skalierung | Aufwand wächst mit Hintzeilen, Query-/Textjoins und Datenbanken; ungekürzte Hint- und Querytexte erhöhen Arbeitsspeicher und Ergebnistransfer. |
| Ressourcen | Geringe bis mittlere Query-Store-I/O-/CPU-Last für Hint-/Query-/Textjoin und Ranking; keine Intervallaggregation oder XML-Verarbeitung. |
| Begrenzungswirkung | QueryId und Fehlerfilter wirken vor dem lokalen TOP N+1; danach wird global begrenzt. Das Zeichenlimit reduziert nur Querytextbreite, nicht Hinttext oder Quelllesung. |
| Locking und Nebenwirkungen | Read-only gegenüber Query Store; normale interne Synchronisation/Schema-Stability ist möglich. Die Procedure erzwingt, entfernt oder bereinigt keine Pläne/Hints. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `QUERY_STORE_CURRENT`, `QUERY_STORE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, `@NurMitFehler = 1`, TOP 100 und gekürzter Text. Erst bei Bedarf alle Hints zeigen; >1000/unbegrenzt erfordert `QUERY_STORE_DEEP`. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „persistierter Konfigurationsstand“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Query Store Hints greifen auf Queries ein, und schlagen sie fehl oder überdecken sie inzwischen bessere Optimizerentscheidungen?

### Technischer Hintergrund

Query Store Hints hängen an QueryId und injizieren unterstützte Queryoptionen ohne Textänderung. Source, Hinttext, Failure Reason/Count und Replica Group liefern Governance-/Fehlerkontext. Verfügbarkeit ist versionsabhängig.

### Datenkette

`sys.query_store_query`, `sys.query_store_query_hints`, `sys.query_store_query_text`, `sys.sp_executesql`.

### Source Select

Query Store Hints werden über `query_id` mit Query- und Textkatalog verbunden:

```sql
SELECT
      [h].[query_id]
    , [h].[query_hint_text]
    , [h].[last_query_hint_failure_reason_desc]
    , [q].[object_id]
    , [qt].[query_sql_text]
FROM [sys].[query_store_query_hints] AS [h] WITH (NOLOCK)
JOIN [sys].[query_store_query] AS [q] WITH (NOLOCK)
  ON [q].[query_id] = [h].[query_id]
JOIN [sys].[query_store_query_text] AS [qt] WITH (NOLOCK)
  ON [qt].[query_text_id] = [q].[query_text_id]
WHERE @QueryId IS NULL OR [h].[query_id] = @QueryId;
```

**Wichtig für die Eigenlast:** Setzen Sie Wenn bekannt, `query_id` vor Textprojektion. Query Store Hints sind ab SQL Server 2022 verfügbar; fehlende Sicht oder Version wird als Status behandelt, nicht durch einen Ersatzscan kompensiert.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuell persistierten Hintbestand; `QueryId` ist datenbanklokal.

### Bewertung und Gegenprobe

Korrelieren Sie Hint, Zielquery, Failure Count, letzte Runtime, Planveränderung, Version/Compatibility und Begründung. Jede Intervention benötigt Owner, Reviewdatum und Rücknahmepfad.

### Typische Fehlinterpretation

Fehlerfrei bedeutet nicht sinnvoll. Nach Upgrade kann ein alter Hint Adaptive/IQP-Verbesserungen verhindern.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: RuntimeStats, Regressions, PlanChanges und Change-Dokumentation.

## Primärquellen

- [Query Store: Überwachung und Auswertung](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#7-monitorusp_querystorehints)
