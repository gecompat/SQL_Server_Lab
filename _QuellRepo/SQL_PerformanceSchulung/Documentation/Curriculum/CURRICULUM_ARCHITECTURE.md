# Curriculumarchitektur und Lernzielmodell

| Merkmal | Wert |
|---|---|
| Arbeitspakete | `CUR-001`, `CUR-002`, `CUR-003`, `CUR-004`, `CUR-009`, `CUR-010` |
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Aktiver Foliensatz | `Presentations/Performance_Schulung_Chat_2026-07-23_2146_SQL_Server_Performance_Grundlagen.pptx` |
| Folienumfang | 84 |
| Aussagenbasis | [Folien- und Aussagenregister](../Inventories/SLIDE_STATEMENT_REGISTER.md) |
| Nachverfolgbarkeit | [Traceability-Matrix](TRACEABILITY_MATRIX.md) |

## 1. Kommunikations- und Kompetenzziel

Nach Abschluss des gemeinsamen Kernpfads sollen SQL-Server-Developer und Analysten mit T-SQL-Grundkenntnissen ein Performanceproblem als überprüfbare Diagnoseaufgabe strukturieren, geeignete Evidenz auswählen, technische Ursache und bloße Korrelation unterscheiden und die Wirkung genau einer begründeten Änderung unter vergleichbaren Bedingungen nachweisen können.

Die Schulung vermittelt keine Sammlung allgemeiner Tuningregeln. Technische Detailkenntnisse werden nur dann als Lernziel aufgenommen, wenn sie eine beobachtbare Diagnose- oder Entwurfsentscheidung ermöglichen. Produktverhalten, empirische Beobachtung und didaktische Methode bleiben getrennte Aussageklassen.

## 2. Zielgruppen und Vorwissen

| Profil | Erwartetes Vorwissen | Gemeinsames Ziel | Zusätzliche Vertiefung |
|---|---|---|---|
| SQL-Server-Developer | `SELECT`, `JOIN`, Filter, Aggregation, grundlegende Transaktionen | Abfrage-, Plan- und Indexfolgen des eigenen Codes erkennen und messen | Parameter Sensitivity, IQP, Memory Grants, Columnstore |
| Daten- und BI-Analysten | relationale Abfragen und fachliche Datenmodelle | Kosten von Datenmodell, Datentypen, Filterung und Ergebnismenge einordnen | Statistiken, Partition Elimination, Query Store |
| Datenbankadministration | Datenbankbetrieb, Backup/Restore und grundlegende Konfiguration | Workloadsignale, Blocking, Waits und Ressourcenengpässe methodisch eingrenzen | TempDB, Extended Events, Query Store, versionsabhängige Engine-Funktionen |
| Performance Engineering | sichere Plan-, DMV- und Workloadanalyse | gemeinsame Terminologie und reproduzierbarer Diagnosevertrag | vollständige Vertiefung einschließlich Messgrenzen und Featurematrix |

Nicht vorausgesetzt werden Kenntnisse der Storage Engine, des Cardinality Estimator, der Plan-XML-Struktur, der Wait-Statistik oder von Extended Events. Für praktische Demos werden sichere Ausführung einfacher T-SQL-Batches und die Unterscheidung zwischen Test- und Produktivsystem vorausgesetzt.

## 3. Pfadmodell

`KERN` bezeichnet Inhalte, die für alle Zielgruppen erforderlich sind. `VERTIEFUNG` erweitert denselben Lernpfad um Internals, Versionsgrenzen oder betrieblich anspruchsvollere Evidenz. Die Vertiefung ist kein getrenntes Curriculum und darf keine Begriffe voraussetzen, die im Kernpfad noch nicht eingeführt wurden.

Ein Modul darf gekürzt werden, wenn alle als `KERN` markierten Lernziele erhalten bleiben und spätere Module keine ausgelassene Vertiefung voraussetzen. Demo-IDs kennzeichnen geplante Evidenz, nicht automatisch eine Pflichtvorführung in jeder Durchführungsvariante.

## 4. Modulfolge und Abhängigkeiten

| Reihenfolge | Modul | Aktuelle Folien | Didaktische Funktion | Voraussetzung | Übergabe an Folgemodul |
|---:|---|---:|---|---|---|
| M00 | Einordnung und Diagnosevertrag | 1–6 | gemeinsames Mess- und Evidenzmodell | T-SQL-Grundkenntnisse | Scope, Vergleichsbedingungen und Evidenzquelle sind benennbar |
| M01 | Storage, Pages und Transaction Log | 7–18 | physische Ursachen von Reads, Writes und Persistenz | M00 | Page-, Cache- und Logfolgen können von Planfolgen getrennt werden |
| M02 | Query Processing, Statistiken und Pläne | 19–35 | Übergang von Datenverteilung zu Plan und Laufzeit | M00, M01 | Schätzung, Operatorwahl, Grant, Spill und Parallelität sind analysierbar |
| M03 | Query Patterns | 36–47 | typische Code- und Modellierungsmuster anhand ihrer Planwirkung beurteilen | M02; Zugriffspfad zunächst als fachliches Konzept | ein Rewrite kann als Hypothese mit identischer Messung formuliert werden |
| M04 | Rowstore- und Columnstore-Indizes | 48–62 | Zugriffspfade physisch erklären und als Workloadentscheidung entwerfen | M01, M02, M03 | Indexnutzen und DML-, Speicher- sowie Wartungskosten sind gemeinsam bewertbar |
| M05 | Concurrency, Isolation und TempDB | 63–70 | zeitgleiches Systemverhalten und Konflikte untersuchen | M00, M01 | Blocking, Deadlock, Versioning und TempDB-Kosten sind getrennt klassifizierbar |
| M06 | Ressourcen und Diagnosewerkzeuge | 71–80 | Signale zu einer Outside-in-Diagnosekette verbinden | M00–M05 | CPU, Waits, Pläne und Historie führen zu einer überprüfbaren Hypothese |
| M07 | Synthese und Transfer | 81–84 | Methode auf einen neuen Fall übertragen | M00–M06 | nächste Messung, Änderung, Vergleich und Rückfallplan sind begründet |

Die Reihenfolge von Query Patterns vor dem Indexmodul ist bewusst: M03 verwendet „passender Zugriffspfad“ als bereits in M02 beobachtbares Planmerkmal. M04 erklärt anschließend die physische Struktur und die Design-Trade-offs. Dadurch entsteht keine Abhängigkeit von B+-Tree-Internals für die erste Beurteilung eines Prädikats.

## 5. Beobachtbare Lernziele

### M00 – Einordnung und Diagnosevertrag

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M00-01` | KERN | ein Symptom nach Antwortzeit, Durchsatz, Ressourcenverbrauch und Nebenläufigkeit abgrenzen | einen gegebenen Fall mit Bezugszeitraum und betroffenem Workload klassifizieren |
| `LO-M00-02` | KERN | den Zyklus Symptom → Messung → Hypothese → Änderung → Vergleich anwenden | eine Diagnosefrage ohne vorweggenommene Tuningmaßnahme formulieren |
| `LO-M00-03` | KERN | Execution Plan, DMVs, Query Store, Extended Events und OS-Metriken nach ihrer Aussageebene auswählen | für drei Diagnosefragen jeweils eine geeignete und eine ungeeignete Evidenzquelle begründen |
| `LO-M00-04` | KERN | Engine-Version, Compatibility Level und Datenbankkonfiguration als getrennte Voraussetzungen prüfen | eine Featureaussage mit allen drei Geltungsgrenzen dokumentieren |

### M01 – Storage, Pages und Transaction Log

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M01-01` | KERN | Rollen und I/O-Muster von Data Files und Transaction Log unterscheiden und Filegroup-Aussagen eingrenzen | eine behauptete I/O-Verbesserung auf logische und physische Voraussetzungen prüfen |
| `LO-M01-02` | KERN | Row Width, Rows per Page, Page-Anzahl und Logical Reads kausal verbinden | für zwei Schemavarianten die erwartete Richtung der Read-Änderung begründen |
| `LO-M01-03` | VERTIEFUNG | `IN_ROW_DATA`, `ROW_OVERFLOW_DATA` und `LOB_DATA` einer Partition fachlich zuordnen | Katalog- und Seitenevidenz ohne falsche 1:1-Tabellenannahme interpretieren |
| `LO-M01-04` | KERN | Logical Reads, Physical Reads, Read-ahead und Cachezustand getrennt interpretieren | einen Cold-/Warm-Cache-Vergleich als gültig oder verzerrt bewerten |
| `LO-M01-05` | KERN | Write-ahead logging, Log Flush, Checkpoint, Autogrowth und Instant File Initialization voneinander abgrenzen | für Commit-Latenz und File Growth jeweils den zutreffenden Mechanismus benennen |

### M02 – Query Processing, Statistiken und Pläne

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M02-01` | KERN | Binding, Optimierung, Compilation und Ausführung unterscheiden und die zeitbegrenzte Plansuche erklären | einen beobachteten Effekt der richtigen Phase zuordnen |
| `LO-M02-02` | KERN | Histogramm, Density Vector, Constraints und CE-Annahmen als Schätzgrundlagen einordnen | eine Estimated-/Actual-Abweichung mit mindestens zwei prüfbaren Ursachenhypothesen erklären |
| `LO-M02-03` | KERN | einen Actual Execution Plan entlang Datenfluss, Zeilen, Ausführungsanzahl, Prädikaten und Warnungen lesen | den ersten evidenzbasierten Untersuchungspunkt in einem Plan begründen |
| `LO-M02-04` | KERN | Nested Loops, Merge und Hash Join anhand von Eingabegröße, Sortierung und Zugriffspfad vergleichen | eine Joinänderung als Folge geänderter Voraussetzungen statt als pauschale Präferenz erklären |
| `LO-M02-05` | VERTIEFUNG | Requested, Granted und Used Memory sowie Spill-Evidenz für Sort/Hash unterscheiden | Undergrant, Overgrant und Server-Memory-Pressure nicht miteinander verwechseln |
| `LO-M02-06` | VERTIEFUNG | Tasks, Workers, Exchanges und Parallel Skew in einem parallelen Plan untersuchen | ungleich verteilte Arbeit anhand operatorbezogener Laufzeitevidenz nachweisen |
| `LO-M02-07` | VERTIEFUNG | Plan Reuse, Parameter Sensitivity und IQP-Funktionen einschließlich Versionsvoraussetzungen trennen | eine geeignete Strategie auswählen, ohne Recompile, PSP oder Feedback pauschal zu empfehlen |

### M03 – Query Patterns

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M03-01` | KERN | SARGability und Implicit Conversion anhand der konvertierten Ausdrucksseite beurteilen | ein Prädikat korrigieren und die Änderung im Plan sowie in Logical Reads prüfen |
| `LO-M03-02` | KERN | halboffene Datumsintervalle und passende Datentypen ohne Tagesende- oder Präzisionsannahme formulieren | einen zeitlichen Filter für beliebige Zeitanteile korrekt schreiben |
| `LO-M03-03` | VERTIEFUNG | optionale Parameter mit Recompile, dynamischem SQL, PSP und OPPO versionsbewusst vergleichen | eine Strategie anhand Verteilung, Wiederverwendung und Version begründen |
| `LO-M03-04` | KERN | CTE, Temp Table, Table Variable, Inline TVF, MSTVF und Scalar UDF nach Optimierersichtbarkeit unterscheiden | Materialisierung, Statistiken und Inlining nicht als ausnahmslose Produkteigenschaft behaupten |
| `LO-M03-05` | VERTIEFUNG | Partition Elimination und Remote Pushdown als im tatsächlichen Plan nachzuweisende Eigenschaften prüfen | lokale Restarbeit und tatsächlich reduzierte Remote-/Partitionsarbeit unterscheiden |
| `LO-M03-06` | KERN | einen Query-Rewrite als einzelne Hypothese mit identischer Baseline und Vergleichsmessung durchführen | Korrektheit, Arbeit pro Ergebnis und Nebenwirkungen gemeinsam bewerten |

### M04 – Rowstore- und Columnstore-Indizes

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M04-01` | KERN | Heap, Clustered Index, B+-Tree und Row Locator fachlich unterscheiden | RID- und Key-Lookup sowie mögliche Forwarded-Record-Kosten korrekt zuordnen |
| `LO-M04-02` | KERN | Key-Reihenfolge, INCLUDE und Filter aus Prädikat, Range, Sortierung und Abdeckung ableiten | einen Indexvorschlag mit nutzbarem Suchpräfix und Abdeckung begründen |
| `LO-M04-03` | KERN | Lookup-Tipping-Point und Clustering-Key-Breite als workloadabhängige Kostenfaktoren erklären | Scan und Seek-plus-Lookup ohne feste Zeilenschwelle vergleichen |
| `LO-M04-04` | KERN | Lesegewinn gegen DML-, Speicher-, Cache- und Wartungskosten bilanzieren | Missing-Index-Hinweise zu einer konsolidierten Designentscheidung weiterentwickeln |
| `LO-M04-05` | VERTIEFUNG | Page Split, logische Fragmentierung und Page Density als getrennte Signale bewerten | eine Maintenance- oder Fill-Factor-Maßnahme an gemessene Workloadwirkung binden |
| `LO-M04-06` | VERTIEFUNG | Rowgroups, Column Segments, Delta Store, Delete Bitmap, Batch Mode und Segment Elimination unterscheiden | reduzierte Zeilenverarbeitung und reduzierte Segmentarbeit getrennt nachweisen |
| `LO-M04-07` | VERTIEFUNG | Rowgroup-Qualität und gelöschte Zeilen für Columnstore-Maintenance beurteilen | eine Maßnahme aus Zustands- und Queryevidenz statt aus einem Kalender ableiten |

### M05 – Concurrency, Isolation und TempDB

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M05-01` | KERN | Isolation Levels, Locking und Row Versioning anhand der geforderten Sichtbarkeit und Konflikte auswählen | RCSI und SNAPSHOT sowie Leser-/Schreiber- und Schreiber-/Schreiber-Konflikte unterscheiden |
| `LO-M05-02` | KERN | eine Blocking Chain bis zum Head Blocker verfolgen | wartende Session, Ressource, offene Transaktion und blockierende Wurzel zusammenführen |
| `LO-M05-03` | KERN | Blocking als gerichtetes Warten und Deadlock als Zyklus unterscheiden | für einen Deadlock die benötigte Ereignisevidenz und einen sicheren Recovery-Pfad nennen |
| `LO-M05-04` | VERTIEFUNG | TempDB-Kosten nach temporären Objekten, Worktables/Spills, Version Store, Allocation und I/O klassifizieren | ein TempDB-Symptom dem passenden Messpfad zuordnen |
| `LO-M05-05` | VERTIEFUNG | ADR-, RCSI- und Datenbankvoraussetzungen von Optimized Locking prüfen | TID Locking, LAQ und verbleibende Lock-Arten ohne pauschale `NOLOCK`-Empfehlung einordnen |

### M06 – Ressourcen und Diagnosewerkzeuge

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M06-01` | KERN | CPU Time, Elapsed Time, aktuelle Task-Waits und kumulative Wait-Deltas im richtigen Scope korrelieren | aus Zeit- und Scopeangaben eine belastbare erste Engpassklasse bilden |
| `LO-M06-02` | VERTIEFUNG | `RESOURCE_SEMAPHORE`, wartende Grants, Overgrant und Undergrant unterscheiden | Grant-DMV, Plan und zeitgleichen Workload gemeinsam auswerten |
| `LO-M06-03` | KERN | I/O-, Latch-, Log-, Netzwerk- und Scheduler-Waits als Hypothesenstart klassifizieren | eine Wait-Kategorie mit mindestens einer bestätigenden Gegenprobe verbinden |
| `LO-M06-04` | KERN | Query Store, Extended Events und DMVs nach Historie, Ereignis und Livezustand auswählen | für Regression, Deadlock und aktuelle Blockierung jeweils den geeigneten Pfad wählen |
| `LO-M06-05` | KERN | eine Outside-in-Diagnose von Nutzerzeit über Systemsignal und Query bis zur Operatorursache durchführen | lokales Query-Tuning bei systemfremder Ursache begründet verwerfen |
| `LO-M06-06` | KERN | einen Vorher-/Nachher-Vergleich mit identischem Workload-, Cache-, Daten- und Messzustand entwerfen | Ergebnis als dokumentiert oder empirisch kennzeichnen und Messgrenzen angeben |

### M07 – Synthese und Transfer

| ID | Pfad | Nach Abschluss kann die lernende Person … | Abnahmenachweis |
|---|---|---|---|
| `LO-M07-01` | KERN | die Diagnoseprinzipien auf einen unbekannten Fall anwenden | eine vollständige Evidenzkette mit genau einer überprüfbaren Änderung erstellen |
| `LO-M07-02` | KERN | den nächsten Untersuchungsschritt aus fehlender Evidenz ableiten | Beobachtung, Hypothese, Messung, Abbruch und Rückfallplan dokumentieren |
| `LO-M07-03` | KERN | Quelle, Produktversion, Aussage, empirisches Ergebnis und Entscheidung nachverfolgbar halten | eine Aussage bis Quelle, Folie, Demo und Testziel zurückverfolgen |

## 6. Modulübergreifender Diagnoseleitfaden

| Diagnoseschritt | Primär eingeführt | In späteren Modulen angewendet |
|---:|---|---|
| 1. Symptom, Zeitraum und Workload abgrenzen | M00 | M05, M06, M07 |
| 2. CPU, Duration, Reads, Writes, Rows und Waits erfassen | M00, M01 | M02–M07 |
| 3. Blocking und Ressourcengrenzen klassifizieren | M05 | M06, M07 |
| 4. Actual Plan und tatsächliche Kardinalitäten prüfen | M02 | M03, M04, M06 |
| 5. Schätzfehler, Zugriffspfad, Grant, Parallelität und Spill untersuchen | M02 | M03, M04, M06 |
| 6. eine falsifizierbare Hypothese formulieren | M00 | alle Fachmodule |
| 7. genau eine begründete Änderung durchführen | M03, M04 | M05–M07 |
| 8. unter vergleichbaren Bedingungen erneut messen | M00 | alle Demos und M07 |
| 9. Nebenwirkungen, Betriebskosten und Versionsgrenzen bewerten | M00 | M01–M07 |

## 7. Rollenmodell der Unterlagen

| Artefakt | Primäre Aufgabe | Darf enthalten | Darf nicht übernehmen |
|---|---|---|---|
| Projektionsfolie | eine Kernaussage sichtbar machen und den Beobachtungsauftrag steuern | Ursache-Wirkungs-Beziehung, wenige Messwerte, Plan-/Demo-Verweis, notwendige Versionsgrenze | vollständige Herleitung, lange Codeblöcke, Recovery-Anweisungen, interne Produktionsdaten |
| Speaker Notes | fachliche Herleitung und sichere Durchführung ermöglichen | Evidenzklasse, Quellen-IDs, Voraussetzungen, typische Fehlinterpretationen, Demo-Cue, Zeitbedarf, Abbruch und Recovery | ungesicherte Behauptungen oder Informationen, die nur im Vortrag „korrigiert“ werden |
| Teilnehmerunterlage | Nacharbeit und selbständige Anwendung unterstützen | Begriffe, Herleitung, kommentierter Code, Übungen, Musterbeobachtung, Quellen und Versionsmatrix | versteckte Trainerannahmen oder nicht reproduzierbare Screenshots |
| Demo-Evidenz | eine technische Aussage reproduzierbar belegen oder widerlegen | synthetisches Setup, Baseline, Problem, Observation, Mitigation, Comparison, Cleanup und erwartete Bandbreiten | reale Umgebungsdaten, universelle Schwellen aus Einzelläufen oder nicht rücksetzbare Eingriffe |

Eine fachliche Kernaussage muss auf der Projektionsfolie korrekt sein. Notes und Teilnehmerunterlage dürfen präzisieren, aber keine sichtbare Falschaussage kompensieren. Demo-Evidenz ersetzt keine Erklärung; sie prüft die zuvor formulierte Hypothese.

## 8. Abnahme und Grenzen

Die 84 Folien sind genau einem Primärmodul und mindestens einem Lernziel zugeordnet. Die vier Aussagen mit Status `REFINE` bleiben in der Traceability-Matrix sichtbar und benötigen vor einer Präsentationsfreigabe die dokumentierte Korrektur in `W2-007`. Die curriculare Zuordnung bewertet weder die noch nicht implementierten Demos noch deren Runtime-Verhalten als bestanden.

`CUR-001` bis `CUR-004`, `CUR-009` und `CUR-010` sind für die Planungsbasis `VALIDATED`. Eine empirische Wirksamkeitsprüfung mit Teilnehmenden ist nicht Bestandteil dieses Status und folgt über `CUR-007`, `CUR-008` sowie die Generalprobe.
