# Glossar für die SQL-Server-Analyse

Dieses Glossar erklärt Begriffe so, wie sie im Framework verwendet werden.

## Session, Request und Task

- **Session:** Verbindungskontext eines Clients. Eine Session kann aktiv oder sleeping sein und mehrere Requests nacheinander ausführen.
- **Request:** aktuell ausgeführter Befehl innerhalb einer Session.
- **Task:** interne Arbeitseinheit eines Requests. Parallele Requests besitzen mehrere Tasks und können gleichzeitig unterschiedliche Waits zeigen.

## Laufzeit und CPU

- **Elapsed Time:** vergangene Uhrzeit vom Start bis zum Messzeitpunkt beziehungsweise Ende.
- **CPU/Worker Time:** tatsächlich auf CPU verbrachte Zeit. Bei Parallelität kann summierte CPU größer als Elapsed Time sein.
- **Wichtige Kombination:** hohe Elapsed Time plus niedrige CPU deutet eher auf Warten; hohe CPU plus hohe Reads eher auf aktive Queryarbeit.

## Reads und Writes

- **Logical Reads:** Zugriffe auf 8-KB-Datenseiten aus Buffer Pool oder nach physischem Einlesen. Nicht mit Zeilen verwechseln.
- **Physical Reads:** Seiten, die tatsächlich vom Storage gelesen wurden.
- **Logical Writes:** logische Änderungen beziehungsweise Schreibaktivität laut Quelle; Bedeutung ist DMV-abhängig.
- **Warum wichtig:** Hohe Reads bei wenigen Ergebniszeilen können ineffizienten Zugriff anzeigen.

## Wait, Blocking, Deadlock und Latch

- **Wait:** Request oder Task kann auf eine Ressource oder ein Ereignis nicht sofort zugreifen.
- **Blocking:** Eine Session hält einen Lock, den eine andere Session benötigt.
- **Root Blocker:** äußerste blockierende Session einer Kette.
- **Deadlock:** zyklische Wartebeziehung; mindestens ein Prozess wird als Opfer abgebrochen.
- **Latch:** interne Synchronisierung einer SQL-Server-Struktur; kein transaktionaler Lock.

## Memory Grant

- **Requested:** vom Optimizer/Executor angeforderter Speicher.
- **Granted:** tatsächlich reservierter Speicher.
- **Used:** beobachtete Nutzung.
- **Ideal:** geschätzter sinnvoller Bedarf nach vorhandener Evidenz.
- **Problemkombination:** großer Request, `Granted=0`, lange `RESOURCE_SEMAPHORE`-Wartezeit und mehrere Konkurrenten.

## Planidentitäten

- **Query Hash:** Gruppierungswert für ähnliche Statements; kein global stabiler Primärschlüssel.
- **Query Plan Hash:** Gruppierungswert für Planform.
- **SQL Handle:** flüchtiger Handle zu SQL-Text/Batch im Cache.
- **Plan Handle:** flüchtiger Handle zu einem Cacheplan.
- **Query Store QueryId/PlanId:** nur innerhalb der betreffenden Query-Store-Datenbank eindeutig.

## Estimate und Actual

- **Estimated Rows:** vom Optimizer erwartete Zeilenmenge.
- **Actual Rows:** bei Actual-/Live-Plänen beobachtete Zeilenmenge.
- **Warum wichtig:** Große absolute Abweichungen können Joinwahl, Memory Grant und Zugriffspfad verschlechtern. Ratio ohne absolute Menge ist leicht irreführend.

## Kumulativ, Delta, Sample und Historie

- **Momentaufnahme:** aktueller Zustand; kann Sekunden später verschwunden sein.
- **Kumulativer Zähler:** seit Restart, Cacheeintrag oder anderem Reset.
- **Delta/Sample:** Differenz zwischen zwei Messpunkten.
- **Historie:** persistierte Daten innerhalb Capture und Retention.

## Query Store

- **Runtime Interval:** Zeitraum, in dem Query Store Werte aggregiert. Eine Zeile der Frameworkanalyse ist regelmäßig keine einzelne Ausführung.
- **Capture Mode:** bestimmt, welche Queries erfasst werden.
- **Read-only Reason:** erklärt, warum Query Store nicht mehr schreibt.
- **Plan Forcing:** bindet eine Query an einen gespeicherten Plan; muss weiter überwacht und reversibel sein.

## Indexbegriffe

- **Seek:** gezielter Zugriff über Indexstruktur; nicht automatisch effizient.
- **Scan:** breiter Zugriff auf Index/Heap; kann für große Ergebnismengen richtig sein.
- **Lookup:** zusätzlicher Zugriff auf Clustered Index/Heap, um fehlende Spalten zu holen.
- **Page Count:** Seitengröße des betrachteten Indexbereichs; notwendiger Nenner für Fragmentierung.
- **Page Density:** durchschnittliche Seitenfüllung; beeinflusst I/O und Cachebedarf.
- **Fragmentation:** physische Reihenfolge/Segmentierung; Relevanz hängt von Größe und Workload ab.

## Statistiken

- **Rows Sampled:** Zahl der für die Statistik gelesenen Zeilen.
- **Modification Counter:** Änderungen seit Statistikupdate gemäß SQL-Server-Quelle.
- **Histogramm:** maximal 200 Schritte für die führende Statistikspalte.
- **Skew:** ungleiche Verteilung. Skew ist nicht automatisch schlecht; problematisch wird er bei ungeeigneten gemeinsamen Plänen.

## Columnstore

- **Rowgroup:** primäre Speichereinheit eines Columnstore.
- **Delta Store:** Rowstore-Zwischenspeicher für noch nicht komprimierte Zeilen.
- **Deleted Rows:** logisch gelöschte Zeilen innerhalb komprimierter Rowgroups.
- **Tuple Mover:** Hintergrundprozess, der geeignete Delta Stores komprimiert.
- **Segment Elimination:** Überspringen nicht relevanter Segmente anhand Metadaten.

## Evidenz und Findings

- **Finding:** normalisierter Prüfhinweis, keine automatisch bestätigte Ursache.
- **Severity:** Priorität oder mögliche Auswirkung.
- **Confidence:** Stärke der vorhandenen Evidenz.
- **Evidence:** beobachteter Beleg.
- **EvidenceLimit:** warum der Beleg keine vollständige Diagnose erlaubt.
- **RecommendedNextCheck:** bestätigende oder widerlegende Folgeanalyse.

## Ergebniszustände

- **Keine Zeile:** Prüfen Sie Filter, Retention, Reset, Feature und Rechte.
- **`NULL`:** Wert unbekannt, nicht anwendbar oder nicht auflösbar.
- **`0`:** tatsächlicher Nullzähler im sichtbaren Scope – nur bei vollständiger Quelle belastbar.
- **`IsPartial=1`:** mindestens ein Teil der Evidenz fehlt.
