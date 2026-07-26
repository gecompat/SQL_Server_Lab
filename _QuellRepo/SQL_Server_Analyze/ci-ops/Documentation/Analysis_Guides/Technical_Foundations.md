# Technische Grundlagen für belastbare SQL-Server-Analysen

**Stand:** 20. Juli 2026
**Geltungsbereich:** alle 97 dokumentierten öffentlichen Procedures einschließlich der eigenständigen und optionalen Pakete

Dieses Dokument beschreibt das gemeinsame Execution-, Zeit- und Evidenzmodell. Die Procedure-Seiten ergänzen es um ihre konkrete Datenkette, Bewertungslogik, Gegenproben und Folgeanalysen.

## 1. Von der Engine zur Bewertung

Eine Diagnose ist erst belastbar, wenn die gesamte Kette sichtbar bleibt:

```text
Engine-Mechanismus -> Messquelle -> Framework-Transformation -> Resultset -> Gegenprobe -> Bewertung
```

Ein einzelner Messwert ist zunächst Evidenz. Er kann Ursache, Symptom, Auswirkung oder nur ein Korrelationsschlüssel sein. Vor einer Änderung sind Scope, Zeitbezug, Datenmenge, zweite Evidenzquelle, Risiko und Rollbackweg zu bestimmen.

## 2. Beobachtungsarten und Zeitmodelle

| Beobachtungsart | Typischer Zeitbezug | Wichtige Aussagegrenze |
|---|---|---|
| Momentaufnahme | beim Lesen sichtbarer Zustand | kann Millisekunden später verschwunden sein |
| Session- oder Requestzähler | seit Session- oder Requestbeginn | Session-IDs können nach Ende wiederverwendet werden |
| kumulative DMV | seit Engine-Start, Reset oder Lebenszyklus der Struktur | frühere Last kann den aktuellen Zustand dominieren |
| Stichprobendelta | Differenz zwischen Messung A und B | Reset oder Restart im Fenster macht das Delta ungültig |
| Plan-Cache-Evidenz | seit Entstehung des Cacheeintrags | Eviction, Recompile, Restart und Cache-Clear verkürzen die Historie |
| Query-Store-Historie | persistierte Datenbankintervalle | Capture Mode, Cleanup, Retention und Randintervalle begrenzen die Aussage |
| Extended-Events-Ereignis | während aktiver Session erfasstes Einzelereignis | nicht erfasst oder rotiert bedeutet nicht, dass es nicht geschah |
| Katalog oder Konfiguration | aktuell sichtbarer Metadatenzustand | beweist weder Nutzung noch Gesundheit eines Features |
| Betriebsmetadaten | abhängig von Job und Aufbewahrung | fehlende Historie beweist keine fehlende Ausführung |

Für jedes Resultset sind deshalb Beobachtungsart, Scope, Messfenster, Resetbedingungen, Aggregationsstufe, Einheit, Nenner und partielle Verfügbarkeit mitzulesen.

## 3. Session, Request, Task, Worker und Scheduler

Eine Clientverbindung besitzt eine Session. Eine Session führt Requests aus. Ein Request wird in mindestens eine Task zerlegt; ein paralleler Plan kann mehrere Tasks besitzen. Eine Task wird durch einen Worker ausgeführt, den SQLOS kooperativ auf einem Scheduler einplant.

- `session_id` identifiziert den Sitzungskontext, nicht den einzelnen parallelen Task.
- `request_id` trennt Requests innerhalb einer Session.
- `exec_context_id` unterscheidet Tasks beziehungsweise Execution Contexts.
- Ein paralleler Request kann gleichzeitig verschiedene Waittypen auf mehreren Tasks besitzen.
- Summierte CPU- oder Task-Wartezeiten können deshalb größer als die Wanduhrzeit sein.

Ein Worker ist vereinfacht `RUNNING`, wartet als `SUSPENDED` auf eine Ressource oder ein Ereignis oder ist nach Ende des Waits `RUNNABLE` und wartet auf Schedulerzeit. Bei instanzweiten Wait Stats ist die Signalzeit in der gesamten Waitzeit enthalten:

```text
ResourceWaitTimeMs = WaitTimeMs - SignalWaitTimeMs
```

## 4. Ursache, Symptom und Auswirkung trennen

| Beobachtung | Zunächst gezeigt | Noch nicht bewiesen |
|---|---|---|
| `LCK_M_*` | ein Task erhält einen inkompatiblen Lock noch nicht | warum der Blocker den Lock hält |
| `PAGEIOLATCH_*` | eine benötigte Seite ist noch nicht aus I/O verfügbar | dass ausschließlich das Storage langsam ist |
| `RESOURCE_SEMAPHORE` | ein Request wartet auf Query Execution Memory | ob Schätzfehler, DOP, Konkurrenz oder Konfiguration Hauptursache sind |
| `SOS_SCHEDULER_YIELD` | ein Worker gab CPU kooperativ ab | dass zusätzliche CPUs die richtige Lösung sind |
| `ASYNC_NETWORK_IO` | SQL Server wartet auf die Abnahme von Ergebnisdaten | ob Netzwerk, Clientverarbeitung oder Ergebnismenge ursächlich sind |
| hohe Dateilatenz | I/O-Abschlüsse dauerten im Messfenster lange | ob Storage, Queueing, Backup, Filtersoftware oder Workloadform Hauptursache sind |

## 5. Verbindliches Bewertungsmuster

1. **Status und Vollständigkeit:** Prüfen Sie Modulstatus, Warnungen, ausgelassene Datenbanken und Rechte.
2. **Scope:** Bestimmen Sie Instanz, Datenbank, Session, Request, Task, Query, Plan, Objekt oder Datei.
3. **Zeit:** Unterscheiden Sie Snapshot, kumulative Messung, Sample und persistierte Historie.
4. **Menge:** Bestimmen Sie Ausführungen, Tasks, I/Os, Seiten oder Zeilen als Nenner.
5. **Mechanismus:** Erklären Sie, welcher Enginevorgang den Wert erzeugen kann.
6. **Auswirkung:** Messen Sie Laufzeit, Durchsatz, SLA, Blocking oder Kapazität.
7. **Gegenprobe:** Prüfen Sie mindestens eine plausible Alternativerklärung.
8. **Bestätigung:** Verwenden Sie eine zweite, unabhängige Evidenzquelle.

Ein leeres Resultset ist nur für den dokumentierten Scope und Zeitpunkt leer. Es ist ohne Prüfung von Filtern, Rechten, Featurestatus, Capture und Retention weder ein Gesundheitsnachweis noch ein Beweis dafür, dass ein Ereignis nie stattgefunden hat.

## 6. Änderungsgrenze

Kein einzelnes Resultset rechtfertigt automatisch `KILL`, DDL, Rebuild, Plan Forcing, Konfigurationsänderung, Failover oder Repair. Solche Eingriffe benötigen eine bestätigte Ursachehypothese, erwartete Wirkung, Nebenwirkungsanalyse, Freigabe und einen getesteten Rollbackweg.

## 7. Eigenlast und Begrenzungswirkung

Auch eine reine Leseanalyse ist Workload. Sie kann CPU, Speicher, I/O, TempDB, Metadatenlocks, Dateizugriffe und Ergebnistransfer erzeugen. Die Kostenklasse beschreibt deshalb das qualitative Betriebsrisiko des konkreten Pfads, nicht eine garantierte Laufzeit:

| Klasse | Bedeutung | Typische Beispiele |
|---|---|---|
| `LOW` | kurze, kleine Katalog- oder Live-DMV-Lesung; auf normal ausgelasteten Systemen gewöhnlich unkritisch | enger Instanzsnapshot ohne XML- oder Planmaterialisierung |
| `MEDIUM` | Kosten wachsen sichtbar mit aktuellem Scope oder erfordern Aggregation, Sortierung, Text-, XML- oder datenbankübergreifende Zugriffe | viele aktive Requests, breiter Katalogscope, begrenzte Eventdatei-Auswertung |
| `HIGH_OPT_IN` | potenziell hohe oder schwer vorhersagbare I/O-/CPU-Last beziehungsweise bewusste Nebenwirkung; explizite Freigabe erforderlich | physische Page-Scans, breite XEL-/Plan-XML-Forensik, Target-Flush |

Eine Procedure kann eine Spannweite besitzen. Dann sind mindestens der dokumentierte Standardpfad und der teuerste erlaubte Pfad getrennt zu klassifizieren.

### Was ein Limit tatsächlich begrenzt

`TOP`, `@MaxZeilen` oder ein nachgelagerter Filter begrenzen häufig nur die gespeicherten oder übertragenen Zeilen. Sie begrenzen den Quellzugriff nur dann, wenn die Engine die Begrenzung vor oder während der teuren Arbeit anwenden kann. Beispiele:

- `TOP` nach einem physischen DMF-Aufruf verhindert nicht, dass die DMF zuvor Pages untersucht.
- `TOP ... ORDER BY` über Rollover-Dateien kann viele Datensätze lesen und sortieren, bevor die neuesten Zeilen feststehen.
- ein Regexfilter, der erst auf einer temporären Ergebnismenge läuft, spart keine Arbeit beim ursprünglichen DMV- oder Dateizugriff.
- Text- oder XML-Ausgabe abzuschalten senkt den Ergebnistransfer; sie spart Quell- oder Parsearbeit nur, wenn der T-SQL-Pfad die Materialisierung ebenfalls überspringt.

Jede tief geprüfte Procedure-Seite weist daher Quellumfang, Filterposition, Sortierung, Materialisierung und Rückgabelimit getrennt aus.

### Ressourcen und Nebenwirkungen

Für die Eigenlast werden mindestens diese Dimensionen geprüft:

1. CPU für Joins, Aggregationen, Sortierung, Regex und XML/JSON-Verarbeitung,
2. logische und physische I/O für Kataloge, Pages, Cacheobjekte und Dateien,
3. Arbeitsspeicher und mögliche Memory Grants für Sortierung oder große Zwischenmengen,
4. TempDB und Ergebnistransfer für breite oder unlimitierte Resultsets,
5. Locks, Lock-Wartezeit und Interaktion mit REDO oder Metadatenänderungen,
6. explizite Nebenwirkungen wie Extended-Events-Target-Flushes,
7. Schutzmechanismen wie `@HighImpactConfirmed`, Analyseklassen, Scopepflichten und Timeouts.

`LOCK_TIMEOUT` begrenzt nur die eigene Wartezeit auf inkompatible Locks. Er begrenzt weder Page-Reads noch CPU, Dateizugriffe, Sortierung oder die Zeit einer nicht blockierten Operation. `NOLOCK` macht eine Abfrage ebenfalls nicht kostenfrei und kann inkonsistente Momentaufnahmen nicht in historische Evidenz verwandeln.

### Betrieblich sicherer Einstieg

Ein sicherer Einstieg verwendet den kleinsten aussagefähigen Scope, den leichtesten Modus, ein enges Zeitfenster und eine endliche Rückgabemenge. Vor einem breiteren Lauf werden Status, Berechtigungen, Gate, erwartete Quellgröße und ein geeigneter Betriebszeitpunkt geprüft. Wenn die Begrenzung Genauigkeit, Vollständigkeit oder Repräsentativität verändert, wird diese Aussagegrenze zusammen mit dem Ergebnis dokumentiert.
