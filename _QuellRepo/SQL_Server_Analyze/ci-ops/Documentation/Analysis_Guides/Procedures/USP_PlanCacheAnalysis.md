# [monitor].[USP_PlanCacheAnalysis]

**Bereich:** Plan Cache, Orchestrator<br>
**Zweck:** Orchestriert Query Stats, Query Hash, Cache Health und optional Showplan.<br>
**Beobachtungsart:** nicht atomarer Plan-Cache-Snapshot<br>
**Kostenklasse:** LOW–HIGH_OPT_IN

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Plan-Cache-Perspektiven sollen gemeinsam für Triage oder Deep Analysis ausgeführt werden?** Sie unterstützt die Entscheidung, welche aktuell gecachten Query-/Plan-Kandidaten vertieft werden sollen und welche Historienquelle die flüchtige Cachebeobachtung bestätigen muss.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige Workloadhistorie; evictete Pläne, nicht gecachte Statements und Ursachen außerhalb des Plans bleiben unsichtbar. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_PlanCacheAnalysis]
      @MitQueryStats = 1,
      @MaxZeilen = 100,
      @HighImpactConfirmed = 1,
      @ResultSetArt = 'CONSOLE';
```

Aktivieren Sie Showplan erst nach Kandidatenpriorisierung.

Der hier gewählte unselektierte Query-Stats-Childpfad benötigt `PLAN_CACHE_DEEP`. Die Bestätigung ersetzt weder ein kleines Limit noch die getrennte Prüfung, ob nach der Triage überhaupt Showplan benötigt wird.

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `moduleStatus`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Die Granularität hängt vom Child ab: Cachezeile, Query-Hash-Gruppe, Cacheaggregation oder Planbestandteil.

## So lesen

Beachten Sie den Modulstatus und die Reihenfolge: Query Stats findet Kandidaten, Query Hash erklärt Varianten, Health bewertet den Cache und Showplan erklärt den Planinhalt.

## Warum kann das problematisch sein?

Breite XML-Analyse kann selbst CPU erzeugen und sehr viele Findings ohne Priorisierung liefern.

## Wann ist es kein Problem?

Nicht aktivierte Children fehlen absichtlich; der Default ist bewusst leichtgewichtig.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Bestimmen Sie zuerst die Queries mit der höchsten CPU-Nutzung und parsen Sie danach nur wenige relevante Pläne. Prüfen Sie deren historische Relevanz anschließend im Query Store.

**Ähnlich aussehender Gegenfall:** Nicht aktivierte Children fehlen absichtlich; der Default ist bewusst leichtgewichtig. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Im Plan Cache kann leer bedeuten: evicted, nie gecacht, recompile, falscher Datenbank-/Hashfilter oder fehlender Text-/Planzugriff.

Für `USP_PlanCacheAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–HIGH_OPT_IN |
| Standardpfad | Query-Stats-Child, TOP 100 und CONSOLE. Ohne QueryHash ist bereits dieser unselektierte Parentpfad `PLAN_CACHE_DEEP`-geschützt; andere Children sind aus. |
| Teuerster Pfad | Alle vier Children, `@AnalyseModus = 'VOLL'`, `@MaxZeilen = 0`, unbegrenzte Analyseobjekte und hohe `@MaxDurationSeconds`: vollständige Cachegruppierung plus Showplan-XML für viele Kandidaten. Es gibt keine Datei-, `msdb`- oder Samplingquelle. |
| Haupttreiber | Zahl der Einträge in `sys.dm_exec_query_stats`/`sys.dm_exec_cached_plans`, Breite von SQL-Text und Planattributen sowie Zahl/Größe der für Showplan ausgewählten XML-Pläne. |
| Skalierung | Benötigen mehrere Children Query Stats, materialisiert der Parent diese DMV einmal laufgebunden und reicht den Snapshot weiter. Gruppierung, Sortierung und Showplan-Shredding bleiben childbezogen; Cache Health kann unabhängig den gesamten Cache aggregieren. |
| Ressourcen | Summe der Plan-Cache-Children: Cache-DMV-/Attribut-/Textzugriff, Gruppierung/Sortierung, TempDB/Arbeitsspeicher und optional Showplan-XML-CPU/Transfer. Kein msdb-, Datei- oder Benutzerdatenscan. |
| Begrenzungswirkung | `@MaxZeilen` gilt je Child, `@MaxAnalyseobjekte` nur für Showplan. `@MaxDurationSeconds` ist dessen kooperative Deadline und begrenzt weder Query Stats noch Cache Health. Text-/Hash-/Handlefilter können früh Kandidaten reduzieren; Top-N entsteht ansonsten erst nach Cachezugriff und Sortierung. |
| Locking und Nebenwirkungen | Der Parent ändert weder Nutzdaten noch Cachekonfiguration. Childaufrufe sind nacheinander und nicht atomar; Cacheeinträge können zwischen Query Stats, Hash, Health und Showplan evicted oder neu kompiliert werden. |
| Schutzmechanismus | Der Code prüft die Analyseklassen `PLAN_CACHE_DEEP`. Verlangt deren Policy ein Gruppengate, ist zusätzlich `@HighImpactConfirmed = 1` nötig; Freigabe und Bestätigung ersetzen keine Scopebegrenzung. |
| Sicherer Einsatz | TOP 100, nur Query Stats, möglichst Datenbank-/Hashselektor und `@HighImpactConfirmed = 1` für den dokumentierten unselektierten Einstieg. Danach nur den auffälligen Childpfad separat vertiefen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „nicht atomarer Plan-Cache-Snapshot“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Plan-Cache-Perspektiven sollen gemeinsam für Triage oder Deep Analysis ausgeführt werden?

### Technischer Hintergrund

Der Wrapper orchestriert Query Stats, Hashgruppen, Cache Health, Details und Showplanpfade. Wenn mindestens zwei der Consumer Query Stats, Query Hash und Showplan-Kandidatenauswahl aktiv sind, materialisiert er `sys.dm_exec_query_stats` einmal laufgebunden; die Children melden `REUSED_PARENT_SNAPSHOT`. Ein breiter gemeinsamer Read wird erst nach `PLAN_CACHE_DEEP`-Freigabe ausgeführt. Plan-XML und breite Cache-Scans erhöhen CPU, Memorytransfer und Resultsetgröße.

### Datenkette

Die Datenkette besteht aus frameworkinterner Orchestrierung; die Quellen liegen in den aufgerufenen Childmodulen.

### Source Select

Kein einzelnes Grundselect wird verwendet. Die Procedure liest `sys.dm_exec_query_stats` einmal in einen lauflokalen Snapshot und übergibt diesen an `USP_QueryStats`, `USP_QueryHashAnalysis`, `USP_PlanCacheHealth` und optional `USP_ShowplanAnalysis`.

**Wichtig für die Eigenlast:** Query Hash, Handle, Zeit und Analysemodus vor Showplan-XML eingrenzen. Die zentrale Einmalkopie verhindert wiederholte Query-Stats-Scans; breite XML-Analyse bleibt ein separater High-Impact-Pfad.

### Zeit- und Scope-Modell

Query Stats, Query Hash und Showplan-Kandidatenauswahl verwenden im gemeinsamen Lauf denselben `dm_exec_query_stats`-Stand. Cache Health besitzt mit `dm_exec_cached_plans` eine eigene Quelle; Plan-XML wird später planweise geladen und kann nach Eviction fehlen. Einzelaufrufe lesen immer frisch.

### Bewertung und Gegenprobe

Prüfen Sie zuerst Status und Partialität. Wechseln Sie danach von den Gesamtkosten zur Hash- und Planebene und führen Sie erst anschließend den XML-Deep-Dive aus. Begrenzen Sie Scope und `MaxRows` eng.

### Typische Fehlinterpretation

Ein leerer Detailpfad kann durch Eviction nach dem gemeinsamen Kandidatensnapshot entstehen, nicht durch fehlende frühere Ausführung. Berücksichtigen Sie Snapshot-Fallback und partielle Planstatus nicht als vollständige Cache-Evidenz.

### Folgeanalyse

Verwenden Sie für historische Fragen den Query Store und für die aktuelle Ressourcenauswirkung die Current-State-Module.

## Primärquellen

- [Plan-Cache-DMVs](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/execution-related-dynamic-management-views-and-functions-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQL Server First Responder Kit – ergänzende, quelloffene Praxiswerkzeuge für Triage](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)

[Technische Detailbeschreibung](../04_Plan_Cache.md#6-monitorusp_plancacheanalysis)
Wenn `MitShowplanAnalysis=1` aktiv ist, enthält die Showplan-Childanalyse
zusätzlich die fünf DIAG-005-Ergebnisse `planWarnings`, `optimizerContext`,
`runtimeFeedback`, `queryStoreContext` und `feedbackAndVariants`. Der
Query-Stats-Snapshot und der daraus abgeleitete Cachekontext werden innerhalb
des Orchestratoraufrufs wiederverwendet.

