# Terminologie- und Schreibstandard

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W0-007` |
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Geltungsbereich | Präsentationen, Speaker Notes, Teilnehmerunterlagen, Demo-Dokumentation, Tests und Projektplanung |

## 1. Sprach- und Darstellungsziel

Die Schulungsunterlagen verwenden sachliche, präzise und technisch überprüfbare Sprache. Eine Darstellung beginnt mit dem beobachtbaren Sachverhalt, erklärt den zugrunde liegenden Mechanismus, benennt geeignete Evidenz und grenzt Version, Konfiguration sowie Messbereich ein. Empfehlungen werden nicht als allgemeine Produktregeln formuliert.

Projekt- und Schulungssprache ist Deutsch. Etablierte SQL-Server-Fachbegriffe bleiben in ihrer üblichen englischen Form erhalten. Eine deutsche Einordnung kann bei der ersten Verwendung ergänzt werden, darf den Fachbegriff aber nicht durch eine ungebräuchliche Übersetzung ersetzen.

## 2. Aussageklassen

Technische Texte kennzeichnen ihre Aussagebasis, wenn eine Verwechslung möglich ist:

| Klasse | Bedeutung | Zulässige Formulierung |
|---|---|---|
| `DOKUMENTIERT` | unmittelbar durch eine aktive Primärquelle belegt | „Dokumentiert: …“ oder Quellen-ID im Aussagenregister |
| `EMPIRISCH` | konkrete Wirkung oder Bandbreite wurde unter benannten Bedingungen gemessen | „Empirisch im beschriebenen Laborszenario: …“ |
| `METHODE` | Diagnose-, Mess- oder Unterrichtsablauf | „Die Untersuchung beginnt mit …“ |
| `DIDAKTISCH` | Strukturierung oder Lernhilfe ohne Produkteigenschaft | „Für die Schulung wird … getrennt betrachtet.“ |
| `VERMUTUNG` | noch nicht bestätigte Hypothese | „Vermutung: …; zu prüfen durch …“ |
| `INFERENZ` | logisch aus mehreren Quellen hergeleitete Aussage | „Inferenz aus SRC-… und SRC-…: …“ |

Ein einzelner gemessener Wert darf nicht als dokumentierte Produkteigenschaft oder universeller Schwellenwert dargestellt werden.

## 3. Versions- und Gültigkeitsangaben

Engine-Version, Datenbank-Compatibility-Level und Datenbankkonfiguration sind getrennt anzugeben. Die Formulierung „ab SQL Server 2022“ ist unzureichend, wenn zusätzlich ein bestimmtes Compatibility Level, Query Store oder eine Datenbankoption erforderlich ist.

Bevorzugtes Schema:

```text
SQL Server 2022 oder höher; Compatibility Level 160; Query Store READ_WRITE.
```

Für die Zielversionen gelten folgende Bezeichnungen:

| Produkt | Kurzbezeichnung im Text | Major Version |
|---|---|---:|
| SQL Server 2019 | SQL Server 2019 | 15.x |
| SQL Server 2022 | SQL Server 2022 | 16.x |
| SQL Server 2025 | SQL Server 2025 | 17.x |

`Compatibility Level` wird nicht mit der Engine-Version gleichgesetzt. Eine Datenbank auf SQL Server 2025 kann mit einem niedrigeren Compatibility Level betrieben werden und dadurch ein anderes Optimierungsverhalten zeigen.

## 4. Verbindliche Fachbegriffe

### 4.1 Abfrage und Plan

| Bevorzugter Begriff | Verwendung und Abgrenzung |
|---|---|
| `Query` | fachliche Abfrage; bei T-SQL-Ausführung gegebenenfalls genauer als `Statement` bezeichnen |
| `Batch` | gemeinsam an SQL Server übertragene Folge von T-SQL-Statements |
| `Statement` | einzeln optimierbare oder ausführbare T-SQL-Anweisung innerhalb eines Batches |
| `Estimated Execution Plan` | kompilierter Plan ohne Laufzeitinformationen der betrachteten Ausführung |
| `Actual Execution Plan` | Plan mit Laufzeitinformationen; nicht mit vollständig gemessener Systemursache gleichsetzen |
| `Plan Operator` | einzelner Operator im Execution Plan |
| `Estimated Rows` / `Actual Rows` | geschätzte beziehungsweise tatsächlich beobachtete Zeilen; Ausführungsanzahl und Bezugsoperator beachten |
| `Cardinality Estimate` | Schätzung der Zeilenanzahl für einen Planabschnitt |
| `Predicate` | Filter- oder Joinbedingung am Operator; Seek Predicate und Residual Predicate getrennt benennen |
| `Plan Reuse` | Wiederverwendung eines vorhandenen Plans; nicht automatisch Planstabilität oder optimale Eignung |
| `Recompilation` | erneute Kompilierung aufgrund eines dokumentierten oder gemessenen Ereignisses; nicht mit separatem Cacheeintrag verwechseln |

### 4.2 Storage und I/O

| Bevorzugter Begriff | Verwendung und Abgrenzung |
|---|---|
| `Page` | 8-KB-Datenseite als zentrale Zugriffseinheit der Storage Engine |
| `Extent` | Gruppe von acht Pages; nicht als eigenständige Zeile oder Partition beschreiben |
| `Row` | physische Zeile; Row Width und nutzbarer Page-Platz getrennt betrachten |
| `Logical Read` | Zugriff auf eine Page über den Buffer Pool; kein Synonym für physischen Datenträgerzugriff |
| `Physical Read` | Page musste vom Speichersystem gelesen werden |
| `Read-ahead` | vorausschauendes Einlesen; getrennt von normalen Physical Reads interpretieren |
| `Data File` | Datei für Datenpages; von Transaction Log und dessen sequenziellem Schreibpfad abgrenzen |
| `Transaction Log` | Write-ahead-Log für Recovery; kein normales Datenfile |
| `Filegroup` | logische Gruppierung von Data Files; keine automatische Garantie physischer I/O-Parallelität |
| `Rowgroup`, `Column Segment`, `Delta Store`, `Delete Bitmap` | getrennte Columnstore-Strukturen; nicht unter „Columnstore-Kompression“ zusammenfassen |

### 4.3 Indizes

| Bevorzugter Begriff | Verwendung und Abgrenzung |
|---|---|
| `Heap` | Tabelle ohne Clustered Index; nicht pauschal als Fehlkonstruktion bezeichnen |
| `Clustered Index` | B+-Tree, dessen Leaf Level die Datenseiten der Tabelle bildet |
| `Nonclustered Index` | separater B+-Tree mit Row Locator zum Basisobjekt |
| `Index Seek` | navigierender Zugriff unter Verwendung eines geeigneten Suchpräfixes; kann dennoch viele Zeilen lesen |
| `Index Scan` / `Table Scan` | durchlaufender Zugriff; nicht ohne Kosten- und Ergebniskontext als Fehler bezeichnen |
| `Key Lookup` | Lookup vom Nonclustered Index in einen Clustered Index |
| `RID Lookup` | Lookup vom Nonclustered Index in einen Heap |
| `Forwarded Record` | weitergeleitete Heapzeile nach Vergrößerung variabler Daten; kein Synonym für RID Lookup |
| `Page Split` | Aufteilung einer Page während einer Änderung; von Fragmentation und Page Density trennen |
| `Logical Fragmentation` | Abweichung logischer und physischer Page-Reihenfolge |
| `Page Density` | Belegungsgrad der Pages; nicht automatisch durch Fragmentation beschrieben |
| `Fill Factor` | Ziel für freien Platz beim Build/Rebuild; keine allgemeine Geschwindigkeitsoption |

### 4.4 Optimizer, Statistiken und Memory Grants

| Bevorzugter Begriff | Verwendung und Abgrenzung |
|---|---|
| `Query Optimizer` | kostenbasierte Komponente mit begrenzter Suchzeit; nicht als allwissende oder zufällige Instanz beschreiben |
| `Histogram` | Verteilung für die führende Statistikspalte; maximal vorhandene Schritte und Grenzen beachten |
| `Density Vector` | Dichteinformation für Spaltenkombinationen; nicht mit Histogramm gleichsetzen |
| `Sampling` | Stichprobenbildung bei Statistikaktualisierung; konkrete Qualität empirisch prüfen |
| `Skew` | ungleichmäßige Datenverteilung; Verteilung und Parameterwert explizit benennen |
| `Memory Grant` | vor Ausführung reservierter Workspace für geeignete Operatoren |
| `Required Memory` | Mindestmenge für die Initialisierung der vorgesehenen Operatoren |
| `Desired Memory` | vom kompilierten Plan als günstig ermittelte Menge |
| `Requested Memory` | angeforderte Menge unter Berücksichtigung der Laufzeitumgebung |
| `Granted Memory` | tatsächlich gewährte Menge |
| `Used Memory` | tatsächlich verwendete Menge; Bezugszeitpunkt und Planattribute beachten |
| `Spill` | Auslagerung von Operatorarbeit nach TempDB; Ursache und Auswirkung gesondert messen |

### 4.5 Concurrency und Waits

| Bevorzugter Begriff | Verwendung und Abgrenzung |
|---|---|
| `Blocking` | gerichtetes Warten einer Session oder eines Tasks auf eine gehaltene Ressource |
| `Blocking Chain` | Kette gerichteter Wartebeziehungen |
| `Head Blocker` | blockierende Wurzel der untersuchten Chain; nicht zwingend identisch mit der teuersten Query |
| `Deadlock` | zyklische Abhängigkeit mit Opferauswahl; kein besonders langes Blocking |
| `Lock` | logische Sperre auf einer Ressource |
| `Latch` | interne Synchronisation für Speicherstrukturen; nicht als Lock bezeichnen |
| `RCSI` | Read Committed Snapshot Isolation mit statementkonsistenter Sicht |
| `SNAPSHOT` | transaktionskonsistente Sicht mit eigener Konfliktsemantik |
| `Wait Type` | Klassifikation eines Wartezustands; allein kein Ursachenbeweis |
| `Wait Stats` | kumulierte Wartezeiten in einem klar benannten Scope und Zeitraum |
| `Current Task Wait` | aktueller Wartezustand eines Tasks; von instanzweiten kumulativen Wait Stats trennen |
| `Worker`, `Task`, `Scheduler`, `Thread` | unterschiedliche Engine- und Betriebssystemkonzepte; keine 1:1-Zuordnung zu Tabellenpartitionen behaupten |

## 5. Schreibregeln

Ein technischer Abschnitt soll nach Möglichkeit folgende Reihenfolge verwenden:

1. beobachtbarer Sachverhalt,
2. technischer Mechanismus,
3. geeignete Evidenz,
4. Gültigkeitsgrenzen,
5. mögliche Gegenmaßnahme und Trade-offs,
6. erneute Messung unter vergleichbaren Bedingungen.

Die Darstellung verwendet vollständige Sätze. Aufzählungen sind zulässig, wenn sie technische Alternativen, Voraussetzungen, Prüfpfade oder Abnahmekriterien klarer machen. Reine Stichwortsammlungen ohne logische Verbindung sind zu vermeiden.

Objektnamen, T-SQL-Schlüsselwörter, Parameter, DMV-Namen, Wait Types, Planattribute und Konfigurationswerte werden in Backticks gesetzt. Codeblöcke verwenden die tatsächliche Syntax und übersetzen keine Bezeichner.

## 6. Unzulässige Pauschalformulierungen

Folgende Formulierungen sind ohne explizite Voraussetzungen und Evidenz unzulässig:

- „immer schneller“, „immer langsamer“, „optimal“ oder „Best Practice“ ohne Workloadbezug,
- feste Fragmentierungs-, Zeilen-, Kosten- oder Laufzeitschwellen als Produkteigenschaft,
- „ein Seek ist gut“ oder „ein Scan ist schlecht“,
- „CTEs materialisieren“,
- „Table Variables haben keine Statistiken und immer eine feste Schätzung“ ohne Versionsgrenze,
- „ein niedriger Fill Factor verhindert Page Splits“,
- „Filegroups verteilen I/O automatisch“,
- „Row Versioning verhindert Blocking“,
- „`NOLOCK` löst Blocking“ oder garantiert korrekte schnellere Reads,
- „eine Partition entspricht einem Thread“,
- „Wait Type X ist die Ursache“ ohne bestätigende Gegenprobe,
- „Query Store ersetzt DMVs oder Extended Events“.

Stattdessen ist die konkrete Voraussetzung zu nennen und die Behauptung als dokumentiert, empirisch oder als zu prüfende Hypothese einzuordnen.

## 7. Abnahme von W0-007

Die verbindliche Terminologie, die Evidenzklassen, die Versionsschreibweise und die Regeln für technische Empfehlungen sind definiert. Neue oder geänderte Schulungsartefakte müssen gegen diesen Standard geprüft werden. Damit ist `W0-007` abgeschlossen.