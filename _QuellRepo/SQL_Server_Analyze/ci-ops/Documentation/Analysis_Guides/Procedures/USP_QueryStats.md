# [monitor].[USP_QueryStats]

**Bereich:** Plan Cache<br>
**Zweck:** Rangiert aktuell gecachte Statements nach CPU, Dauer, I/O, Ausführungen, Grants, Spills oder Zeilen.<br>
**Beobachtungsart:** kumulativ je aktuellem Cacheeintrag<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche aktuell gecachten Statements verursachten kumulativ oder durchschnittlich CPU, Dauer, Reads und Writes?** Sie unterstützt die Entscheidung, welche aktuell gecachten Query-/Plan-Kandidaten vertieft werden sollen und welche Historienquelle die flüchtige Cachebeobachtung bestätigen muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige Workloadhistorie; evictete Pläne, nicht gecachte Statements und Ursachen außerhalb des Plans bleiben unsichtbar. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_QueryStats]
      @Sortierung = 'CPU_TOTAL',
      @MaxZeilen = 50,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `queries`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer aktuell gecachten Statementinstanz. Derselbe logische Querytext kann durch unterschiedliche Handles, SET-Optionen oder Pläne mehrfach erscheinen.

## So lesen

Betrachten Sie zuerst Cachefenster (`CreationTime`, `LastExecutionTime`) und `ExecutionCount`, danach Total-, Average-, Max- und Lastwerte getrennt.

## Warum kann das problematisch sein?

Totalwerte zeigen Gesamtauswirkung, Maxwerte Ausreißer und Averagewerte systematische Kosten. Hohe Reads bei wenigen Ergebniszeilen können ineffizienten Zugriff anzeigen.

## Wann ist es kein Problem?

Eine einmalige administrative Query darf hohe Maxwerte besitzen, ohne die normale Workload wesentlich zu belasten.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Eine Million Ausführungen zu je 2 ms verursachen mehr Gesamtlast als eine einmalige 10-Minuten-Query. Prüfen Sie Query Hash, Plan Details, Showplan und Query Store.

**Ähnlich aussehender Gegenfall:** Eine einmalige administrative Query darf hohe Maxwerte besitzen, ohne die normale Workload wesentlich zu belasten. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Im Plan Cache kann leer bedeuten: evicted, nie gecacht, recompile, falscher Datenbank-/Hashfilter oder fehlender Text-/Planzugriff.

Für `USP_QueryStats` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

Der Plan Cache ist flüchtig. Recompile, Eviction oder Restart können relevante Queries entfernen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | TOP 50 aus `sys.dm_exec_query_stats`, nach CPU sortiert und mit auf 4000 Zeichen gekürztem SQL-Text; optionaler Datenbank-/Hashfilter kann den Kandidatenscope weiter eingrenzen. |
| Teuerster Pfad | `VOLL` beziehungsweise >1000/unbegrenzt, kein Query-/Datenbankfilter, ungekürzte Texte und Regex über einen sehr großen Plan Cache. Dieser Pfad prüft `PLAN_CACHE_DEEP`. |
| Haupttreiber | Zahl aktueller Cache-Statementzeilen, gewählte Rangiermetrik sowie Planattribut- und SQL-Textauflösung. Datenbank-/Hashfilter können Kandidaten verkleinern; Regex, Volltext und unbegrenztes Ranking verlagern Arbeit auf den breiten Cachepfad. |
| Skalierung | Laufzeit und CPU wachsen mit dem Haupttreiber. Sortierung/Aggregation erhöht Speicher- und gegebenenfalls TempDB-Bedarf; breite Texte/XML sowie viele Zeilen erhöhen Netzwerk- und Clientkosten. Für USP_QueryStats ist insbesondere die im Datenkettenabschnitt beschriebene Reihenfolge maßgeblich. |
| Ressourcen | CPU und Speicher für Cache-DMV-Scan, Textauflösung, Gruppierung und Sortierung; Ergebnistransfer bei langen Texten. |
| Begrenzungswirkung | TOP begrenzt die Rückgabe, doch Ranking, Hashaggregation oder Cachekategorie kann zuvor viele Cachezeilen lesen. Früh wirkende Datenbank-/Hashfilter sind wertvoller. |
| Locking und Nebenwirkungen | Keine Nutzdatenlocks. Cacheeinträge können während des Lesens evicted oder neu kompiliert werden; Text-/Attributauflösung ist daher nicht atomar. |
| Schutzmechanismus | TOP bis 1000 nutzt `PLAN_CACHE_CURRENT` ohne High-Impact-Pflicht. `VOLL`, >1000 oder unbegrenzt prüft `PLAN_CACHE_DEEP` und verlangt `@HighImpactConfirmed = 1`. |
| Sicherer Einsatz | Kleines Limit, gekürzte Texte und eine Datenbank beziehungsweise ein QueryHash; VOLL/unbegrenzt nur nach Cachegrößenprüfung. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „kumulativ je aktuellem Cacheeintrag“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche aktuell gecachten Statements verursachten kumulativ oder durchschnittlich CPU, Dauer, Reads und Writes?

### Technischer Hintergrund

`sys.dm_exec_query_stats` liefert pro gecachtem Statement Ausführungszahl und Total-/Last-/Min-/Maxwerte. SQL Text und Statementoffsets identifizieren den Ausschnitt; Planhandle/Plan XML beschreiben die gecachte Planform.

### Datenkette

`master.sys.databases`, `sys.dm_exec_cached_plans`, `sys.dm_exec_plan_attributes`, `sys.dm_exec_query_stats`, `sys.dm_exec_sql_text`, `sys.sp_executesql`.

### Source Select

Der Grundpfad liest kumulative Statementzähler und löst Text sowie Datenbank-ID aus Handlemetadaten auf:

```sql
SELECT
      [qs].[query_hash]
    , [qs].[query_plan_hash]
    , [qs].[execution_count]
    , [qs].[total_worker_time]
    , [qs].[total_logical_reads]
    , [st].[text]
    , TRY_CONVERT(int, [dbid].[value]) AS [DatabaseId]
FROM [sys].[dm_exec_query_stats] AS [qs] WITH (NOLOCK)
OUTER APPLY [sys].[dm_exec_sql_text]([qs].[sql_handle]) AS [st]
OUTER APPLY
(
    SELECT TOP (1) [pa].[value]
    FROM [sys].[dm_exec_plan_attributes]([qs].[plan_handle]) AS [pa]
    WHERE [pa].[attribute] = N'dbid'
) AS [dbid]
WHERE [qs].[execution_count] >= @MinExecutionCount
  AND (@VonUtc IS NULL OR [qs].[last_execution_time] >= @VonUtc)
  AND (@QueryHash IS NULL OR [qs].[query_hash] = @QueryHash);
```

**Wichtig für die Eigenlast:** Hash, Handle, Ausführungsanzahl und Zeit wirken vor Sortierung. Datenbank- und Textfilter benötigen erst Handle-/Textauflösung; Regex wirkt nach Materialisierung. `@MaxZeilen` begrenzt nicht automatisch den Cache-Scan.

### Zeit- und Scope-Modell

Die Zähler sind seit der Erstellung des Cacheeintrags kumulativ. Erstellungszeit, letzte Ausführung und Engine-Start begrenzen das Fenster.

### Bewertung und Gegenprobe

Totalwerte zeigen die Gesamtkosten, während Durchschnittswerte teure Einzelausführungen sichtbar machen. Berücksichtigen Sie immer auch Execution Count, Cachealter, Rowcount und Last Execution.

### Typische Fehlinterpretation

Ein kleiner Totalwert kann nur kurzen Cachelebenszyklus bedeuten. Durchschnitt verdeckt Ausreißer und Parameter Sensitivity.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Query Hash, Showplan und Query Store für persistierte Historie.

## Primärquellen

- [sys.dm_exec_query_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-stats-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../04_Plan_Cache.md#1-monitorusp_querystats)
