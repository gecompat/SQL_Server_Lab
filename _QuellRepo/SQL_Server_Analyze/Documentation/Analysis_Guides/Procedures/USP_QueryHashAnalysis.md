# [monitor].[USP_QueryHashAnalysis]

**Bereich:** Plan Cache<br>
**Zweck:** Aggregiert Cachezeilen je Query Hash und zeigt Planvarianten, Handles und Ressourcen.<br>
**Beobachtungsart:** kumulativ je aktuellem Cacheeintrag<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Varianten derselben normalisierten Queryform und welche Planformen liegen aktuell im Cache?** Sie unterstützt die Entscheidung, welche aktuell gecachten Query-/Plan-Kandidaten vertieft werden sollen und welche Historienquelle die flüchtige Cachebeobachtung bestätigen muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige Workloadhistorie; evictete Pläne, nicht gecachte Statements und Ursachen außerhalb des Plans bleiben unsichtbar. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_QueryHashAnalysis]
      @AnalyseModus = 'TOP',
      @MaxZeilen = 100,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Ohne konkreten `@QueryHash` ist auch der begrenzte TOP-Einstieg als `PLAN_CACHE_DEEP` geschützt. Die Bestätigung schaltet nur das Gate frei; `@MaxZeilen` begrenzt vor allem die Ausgabe und ist kein Beweis für nur 100 gelesene Cachezeilen.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `queryHashes`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Query-Hash-Gruppe über die aktuell sichtbaren Cachezeilen. Historisch evictete Varianten fehlen.

## So lesen

Vergleichen Sie `PlanVariantCount`, `PlanHandleCount`, Ausführungen, Cachefenster und Ressourcen der dominanten Varianten.

## Warum kann das problematisch sein?

Viele Planvarianten können Parameter Sensitivity oder unterschiedliche Compilekontexte anzeigen. Viele Handles bei gleichem Plan Hash können Cachebloat bedeuten.

## Wann ist es kein Problem?

SET-Optionen, Datenbankkontexte oder bewusstes Recompile können legitime Varianten erzeugen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Acht Varianten, aber eine verursacht 99 % der CPU: Nicht die Anzahl, sondern die dominante Variante priorisieren. Prüfen Sie Einzelne Handles mit `USP_PlanDetails`, Historie mit Query Store.

**Ähnlich aussehender Gegenfall:** SET-Optionen, Datenbankkontexte oder bewusstes Recompile können legitime Varianten erzeugen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Im Plan Cache kann leer bedeuten: evicted, nie gecacht, recompile, falscher Datenbank-/Hashfilter oder fehlender Text-/Planzugriff.

Für `USP_QueryHashAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

**Quellcode-Hinweis zur Eigenlast:** Die Procedure gruppiert `sys.dm_exec_query_stats`. Ohne konkreten `@QueryHash` sowie im Modus VOLL wird `PLAN_CACHE_DEEP` geprüft. Text wird nur für gewählte Hashes geladen.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Ein konkreter `@QueryHash`, TOP 100 und auf 4000 Zeichen gekürzter SQL-Text; Text wird erst für die ausgewählten Hashgruppen geladen. |
| Teuerster Pfad | Kein QueryHash, `VOLL` beziehungsweise unbegrenzte/hohe Ausgabe und ungekürzte Texte: der gesamte `sys.dm_exec_query_stats`-Bestand wird nach Hash gruppiert und gerankt. |
| Haupttreiber | Zahl aktueller `dm_exec_query_stats`-Einträge, ihre Gruppierung je Query Hash und optional aufgelöster SQL-Text. Ohne Hash-/Datenbankfilter muss der aktuelle Cache vor Ranking und Limit breit aggregiert werden. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_QueryHashAnalysis ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU und Speicher für Cache-DMV-Scan, Textauflösung, Gruppierung und Sortierung; Ergebnistransfer bei langen Texten. |
| Begrenzungswirkung | TOP begrenzt die Rückgabe, doch Ranking, Hashaggregation oder Cachekategorie kann zuvor viele Cachezeilen lesen. Früh wirkende Datenbank-/Hashfilter sind wertvoller. |
| Locking und Nebenwirkungen | Keine Nutzdatenlocks. Cacheeinträge können während des Lesens evicted oder neu kompiliert werden; Text-/Attributauflösung ist daher nicht atomar. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `PLAN_CACHE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | Einen konkreten synthetisch dargestellten QueryHash und kleines Limit verwenden. Der dokumentierte unselektierte TOP-Einstieg benötigt bereits `PLAN_CACHE_DEEP`; `VOLL`/unbegrenzt erst nach Cachegrößenprüfung. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „kumulativ je aktuellem Cacheeintrag“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Varianten derselben normalisierten Queryform und welche Planformen liegen aktuell im Cache?

### Technischer Hintergrund

Grouping nach Query Hash konsolidiert ähnliche Statementtexte; Plan Hash trennt physische Planformen. Aggregationen zeigen Planvielfalt, Lastverteilung und mögliche Ad-hoc-/Parameterisierungsvarianten.

### Datenkette

`sys.dm_exec_query_stats`, `sys.dm_exec_sql_text`.

### Source Select

Ein exakter Query Hash begrenzt die Query-Stats-Kandidaten vor Textprojektion und Variantenaggregation:

```sql
SELECT
      [qs].[query_hash]
    , [qs].[query_plan_hash]
    , COUNT_BIG(*) AS [CacheEntryCount]
    , SUM([qs].[execution_count]) AS [ExecutionCount]
    , SUM([qs].[total_worker_time]) AS [TotalWorkerTime]
    , SUM([qs].[total_logical_reads]) AS [TotalLogicalReads]
FROM [sys].[dm_exec_query_stats] AS [qs] WITH (NOLOCK)
WHERE [qs].[query_hash] = @QueryHash
GROUP BY [qs].[query_hash], [qs].[query_plan_hash];
```

**Wichtig für die Eigenlast:** Setzen Sie `@QueryHash`, `@SqlHandle` oder `@PlanHandle` vor `dm_exec_sql_text`. Ohne Zielschlüssel muss die Procedure den breiten Plan-Cache-Snapshot gruppieren; ein finales `TOP` spart diesen Scan nicht.

### Zeit- und Scope-Modell

Die Auswertung berücksichtigt nur aktuell gecachte Einträge; deren Creation Times und Evictions können voneinander abweichen.

### Bewertung und Gegenprobe

Vergleichen Sie Plananzahl, Execution Count, Total/Avg-Kosten, Text-/Parameterkontext und Creation Time. Mehrere Plan Hashes können legitime Recompile-/SET-/Compatibilitykontexte oder Parameter Sensitivity zeigen.

### Typische Fehlinterpretation

Gleicher Hash garantiert keine fachliche Gleichheit; Hashkollisionen sind theoretisch möglich. Ein fehlender alter Plan ist keine Stabilitätsevidenz.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Query Store PlanChanges/RuntimeStats und Showplanvergleich.

## Primärquellen

- [sys.dm_exec_query_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-stats-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../04_Plan_Cache.md#2-monitorusp_queryhashanalysis)
