# [monitor].[USP_InternalContentionAnalysis]

**Bereich:** Server Health<br>
**Zweck:** Analysiert Spinlocks, Latches und Hot Pages über ein begrenztes Sample.<br>
**Beobachtungsart:** kumulativ + optionale Stichprobe<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche Latches, Spinlocks, Tasks oder Hot Pages zeigen interne Synchronisationskonkurrenz?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_InternalContentionAnalysis]
      @SampleSeconds = 5,
      @MitPageDetails = 0,
      @MaxZeilen = 50,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `latches`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset entspricht eine Zeile einer Spinlockklasse, einem Latch-/Hot-Page-Kandidaten, Page Detail oder Finding.

## So lesen

Betrachten Sie Delta über Sample, Klasse, Waitdauer, Hot Page, Session-/Objektkontext und Wiederholung.

Delta-, Rate- und Resetlogik verwendet die reine Funktion `monitor.TVF_InterpretContentionCounter`. Fallende Zähler liefern weder eine Differenz noch eine Rate; die Procedure setzt stattdessen `CounterResetDetected=1`.

## Warum kann das problematisch sein?

Interne Synchronisationswartezeiten können CPU-Durchsatz begrenzen, obwohl einzelne Queries unauffällig wirken.

## Wann ist es kein Problem?

Hohe kumulative Zähler ohne aktuelles Delta sind schwach.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Dieselbe Hot Page in mehreren Samples mit wachsender Waitzeit: belastbare Contention. Ein einmaliger kleiner Peak nicht. Prüfen Sie TempDB-/Indexdesign, Insertmuster und Requests.

**Ähnlich aussehender Gegenfall:** Hohe kumulative Zähler ohne aktuelles Delta sind schwach. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_InternalContentionAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Fünfsekündiges Delta aller Latchklassen und Spinlocks; danach ein Snapshot aktuell auf `PAGELATCH%`/`PAGEIOLATCH%` wartender Requests. Hot Pages sind an, `sys.dm_db_page_info` ist mit `@MitPageDetails = 0` aus. |
| Teuerster Pfad | 60 Sekunden, Spinlocks und Hot Pages an, `@MitPageDetails = 1`, unbegrenzte Ausgabe und viele gleichzeitige Page-Waiter. Jede auflösbare Hot Page wird einzeln über `sys.dm_db_page_info(...,'LIMITED')` ergänzt. |
| Haupttreiber | Zahl der Latch-/Spinlockklassen ist instanzweit begrenzt; variabel sind parallele Aufrufer und aktuelle Page-Waiter. PageDetails skaliert mit diesen Waitern, nicht mit allen Datenbankseiten. |
| Skalierung | Latch- und Spinlock-DMVs werden jeweils zweimal vollständig gelesen und gruppiert. WAITFOR dominiert die Mindestdauer; Page-Info-Aufrufe und Ergebnisaufbereitung wachsen mit dem aktuellen Hot-Page-Snapshot. |
| Ressourcen | SQLOS-DMV-CPU, kleine Temp-Tabellen, eine wartende Session und optional Metadatenzugriffe per `sys.dm_db_page_info`. Keine Benutzerseiteninhalte, XEL-Dateien oder Historientabellen werden gelesen. |
| Begrenzungswirkung | `@MaxZeilen` greift nur bei Ausgabe/JSON je Resultset. Latch-/Spinlock-Snapshots, Hot-Page-Ermittlung und optionale Page-Info-Aufrufe finden vorher statt; das Limit ist daher kein Quellkostenschutz. `@SampleSeconds` ist auf 60 begrenzt. |
| Locking und Nebenwirkungen | Read-only; WAITFOR hält die Verbindung, aber keine absichtlich über das Intervall gehaltenen Nutzdatenlocks. Page- und Requestzustand kann sich nach dem Sample bereits geändert haben. |
| Schutzmechanismus | Kein High-Impact-Gate. Das Sample ist auf 60 Sekunden begrenzt; Spinlocks, Hot Pages und insbesondere die einzelnen Page-Info-Aufrufe lassen sich separat abschalten. `@MaxZeilen` begrenzt nur die Ausgabe und ersetzt diese Opt-outs nicht. |
| Sicherer Einsatz | Fünf Sekunden, PageDetails aus, `@MaxZeilen = 50` und nur ein Sampler. PageDetails erst aktivieren, wenn wiederholt dieselbe Waitressource sichtbar ist. |
| Aussagegrenze | Das Delta zeigt interne Konkurrenz, aber noch keine verursachende Abfrage. Hot Pages werden erst nach dem Intervall als Momentaufnahme ermittelt und sind zeitlich nicht exakt identisch zum Latchdelta; kumulative Werte bei Sample 0 sind seit Start und keine aktuelle Rate. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche Latches, Spinlocks, Tasks oder Hot Pages zeigen interne Synchronisationskonkurrenz?

### Technischer Hintergrund

Latches schützen interne In-Memory-Strukturen/Pages, Spinlocks sehr kurze Critical Sections ohne sofortiges Schlafen. Hohe Konkurrenz erzeugt Waits, Spins/Backoffs oder Schedulerlast. Sampling zweier kumulativer DMVs lokalisiert aktuelle Deltas; Waiting Tasks/Resource Description können Hotspots zeigen.

### Datenkette

`sys.dm_db_page_info`, `sys.dm_exec_requests`, `sys.dm_os_latch_stats`, `sys.dm_os_spinlock_stats`, `sys.dm_os_sys_info`.

### Source Select

Das kumulative Grundselect beginnt bei den serverweiten Latch-Zählern und behält nur tatsächlich beobachtete Klassen:

```sql
SELECT
      [l].[latch_class]
    , [l].[waiting_requests_count]
    , [l].[wait_time_ms]
    , [l].[max_wait_time_ms]
FROM [sys].[dm_os_latch_stats] AS [l] WITH (NOLOCK)
WHERE [l].[waiting_requests_count] > 0
ORDER BY [l].[wait_time_ms] DESC;
```

**Wichtig für die Eigenlast:** Latch-/Spinlock-Schwellen vor Detailprojektion anwenden. Request- und `dm_db_page_info`-Korrelation ist ein separater, gezielter Momentaufnahmepfad und darf nicht breit für alle historischen Counter ausgeführt werden.

### Zeit- und Scope-Modell

Die Auswertung kombiniert ein kurzes Sampledelta mit einem Tasksnapshot; ein Reset oder Neustart macht das Delta ungültig.

### Bewertung und Gegenprobe

Korrelieren Sie Delta-Waitzeit/Count, Average, Spin/Backoff, CPU, Resource/Page und wiederholte Samples. PAGELATCH an TempDB Allocation unterscheidet sich von B-Tree Last-Page Contention.

### Typische Fehlinterpretation

Hohe kumulative Latchwerte seit langem Uptime sind kein aktueller Hotspot. Undokumentierte interne Namen/Verhalten können versionsabhängig sein.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Current Waits/TempDB/Requests, Page-/Objectauflösung und versionsspezifische Microsoftguidance.

## Primärquellen

- [sys.dm_os_latch_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-latch-stats-transact-sql?view=sql-server-ver17)

## Weiterführende Vertiefung

Die folgenden Quellen ergänzen die Produktspezifikation um Praxis- oder Toolingperspektiven. Sie sind keine Grundlage für versions-, Berechtigungs- oder Engineaussagen dieser Seite.

- [SQLskills Wait Types Library – vertiefende Einordnung einzelner Waittypen](https://www.sqlskills.com/help/waits/)
- [sp_WhoIsActive – ergänzende Live-Diagnostik und andere Aufbereitung aktueller Aktivität](https://github.com/amachanic/sp_whoisactive)

[Technische Detailbeschreibung](../08_Server_Health.md#15-monitorusp_internalcontentionanalysis)
