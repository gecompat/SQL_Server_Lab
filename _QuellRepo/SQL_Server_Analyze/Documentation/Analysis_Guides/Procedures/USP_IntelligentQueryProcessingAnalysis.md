# [monitor].[USP_IntelligentQueryProcessingAnalysis]

**Bereich:** Query Store und IQP<br>
**Zweck:** Zeigt Featureeignung, datenbankbezogene Konfiguration und aggregierte Feedbacksignale.<br>
**Beobachtungsart:** Konfigurationssnapshot + persistierte Feedbackhistorie<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche IQP-Funktionen sind technisch möglich, konfiguriert und durch sichtbare Query-/Planfeedbacksignale belegt?** Sie unterstützt die Entscheidung, ob persistierte Query-Store-Evidenz eine zeitlich belastbare Abweichung zeigt und welcher Query-/Plan-Scope danach gezielt geprüft wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine Ausführungen außerhalb Capture und Retention sowie keinen Beweis, dass ein beobachteter Planwechsel allein die Auswirkung verursacht hat. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_IntelligentQueryProcessingAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Der datenbankweise IQP-Katalogpfad ist als `CATALOG_DEEP` geschützt. `@HighImpactConfirmed = 1` bestätigt die Policyfreigabe, begrenzt aber weder die Zahl der Datenbanken noch die dort vorhandenen Feedbackzeilen.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `signals`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer Datenbank, einer Configuration, Automatic-Tuning-Option oder einem aggregierten Signal.

## So lesen

Betrachten Sie Eligibility, Compatibility, Database-scoped Configurations, Query-Store-Zustand und Evidence Counts getrennt.

## Warum kann das problematisch sein?

Ein Feature kann versionsseitig geeignet, aber deaktiviert sein. Query Store OFF oder READ_ONLY kann persistentes Feedback begrenzen.

## Wann ist es kein Problem?

`EvidenceCount=0` beweist weder Erfolg noch Misserfolg; eventuell existierte keine geeignete Query oder keine persistierte Evidenz.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** PSP eligible, aber keine Query Variants: kein Fehler. Erst eine bekannte parameter-sensitive Query liefert eine sinnvolle Gegenprobe. Prüfen Sie Query Store und Showplan.

**Ähnlich aussehender Gegenfall:** `EvidenceCount=0` beweist weder Erfolg noch Misserfolg; eventuell existierte keine geeignete Query oder keine persistierte Evidenz. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Query Store kann nutzbar sein, obwohl das gewählte Fenster leer ist. Prüfen Sie zuerst Capturemodus, Read-only-Status, Retention und UTC-Fenster.

Für `USP_IntelligentQueryProcessingAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Eine `ExampleDatabase` mit endlichem Limit; gelesen werden IQP-/Query-Store-/Automatic-Tuning-Konfiguration und aggregierte Varianten-/Feedbacksignale, ohne Query-Text oder Showplan. |
| Teuerster Pfad | Alle sichtbaren Datenbanken und `@MaxZeilen = 0` bei sehr vielen Query-Store-Varianten, Plan-Feedbackzeilen und Tuningempfehlungen. Ein Zeitfenster- oder XML-Pfad existiert nicht. |
| Haupttreiber | Zahl gewählter Datenbanken sowie Query-Store-Varianten, Plan-Feedback- und Automatic-Tuning-Empfehlungszeilen. Konfigurationsquellen sind klein; unbegrenzte Feedback-/Variantenbestände dominieren, obwohl weder Querytext noch Showplan gelesen wird. |
| Skalierung | Feste Konfigurationszeilen bleiben klein; Aufwand wächst mit ausgewählten Datenbanken und sichtbaren Query-Variant-/Plan-Feedback-/Tuningzeilen. Keine Text-, Plan-XML- oder Intervallaggregation. |
| Ressourcen | CPU und Katalog-/Query-Store-Metadaten-I/O sowie dynamisches SQL/temporäre Signalresultate; Ergebnistransfer wächst mit der Signalmenge. |
| Begrenzungswirkung | Der Datenbankscope begrenzt Quellarbeit. `@MaxZeilen` wird erst auf die vollständig gesammelten Signale angewandt und begrenzt weder Datenbankcursor noch vorgelagerte Feedbackabfragen. |
| Locking und Nebenwirkungen | Read-only gegenüber Query Store; normale interne Synchronisation/Schema-Stability ist möglich. Die Procedure erzwingt, entfernt oder bereinigt keine Pläne/Hints. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `CATALOG_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Eine `ExampleDatabase`, Standardlimit und CONSOLE. Die zwingende `CATALOG_DEEP`-Bestätigung nicht mit einer Freigabe für alle Datenbanken verwechseln; zunächst Status-/Versionspfad lesen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Konfigurationssnapshot + persistierte Feedbackhistorie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche IQP-Funktionen sind technisch möglich, konfiguriert und durch sichtbare Query-/Planfeedbacksignale belegt?

### Technischer Hintergrund

IQP umfasst unter anderem PSP, OPPO, Memory Grant Feedback, DOP/CE Feedback, Adaptive Joins, Deferred Compilation und weitere versions-/compatibilityabhängige Features. Database Scoped Configurations und Query-Store-basierte Feedbacks sind getrennte Ebenen.

### Datenkette

`sys.database_automatic_tuning_options`, `sys.database_query_store_options`, `sys.database_scoped_configurations`, `sys.databases`, `sys.dm_db_tuning_recommendations`, `sys.query_store_plan_feedback`, `sys.query_store_query_variant`, `sys.sp_executesql`.

### Source Select

Der leichte Basispfad liest nur relevante datenbankweite Konfigurationswerte:

```sql
SELECT
      [c].[name]
    , [c].[value]
    , [c].[value_for_secondary]
FROM [sys].[database_scoped_configurations] AS [c] WITH (NOLOCK)
WHERE [c].[name] IN
      (N'LEGACY_CARDINALITY_ESTIMATION',
       N'PARAMETER_SNIFFING',
       N'QUERY_OPTIMIZER_HOTFIXES',
       N'MAXDOP');
```

**Wichtig für die Eigenlast:** Wählen Sie Datenbank vor Query-Store-Variant-, Plan-Feedback- und Tuning-Recommendation-Pfaden aus. Diese versionsabhängigen Detailquellen nur lesen, wenn Query Store und das jeweilige Feature verfügbar sind.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Versions-, Compatibility- und Configurationzustand sowie die persistierte, sichtbare Feedback- und Variantenevidenz.

### Bewertung und Gegenprobe

Trennen Sie `Eligible`, Configuration Value, Query Store State und Evidence Count. Ein Signal führt zur konkreten Query-/Plananalyse, nicht zur pauschalen Aktivierung/Deaktivierung.

### Typische Fehlinterpretation

`Eligible=1` ist kein Wirksamkeitsbeweis; `EvidenceCount=0` beweist weder fehlendes Problem noch Featureversagen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Query Store Runtime/PlanChanges, Showplan und konkrete Parameterworkload.

## Primärquellen

- [Intelligent query processing](https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../05_Query_Store.md#8-monitorusp_intelligentqueryprocessinganalysis)
