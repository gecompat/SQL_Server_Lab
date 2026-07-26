# Baseline Review – Vorhandene Performance-Schulungsunterlagen 2024

| Merkmal | Wert |
|---|---|
| Status | `BASELINE_REVIEWED` |
| Stand | 2026-07-23 |
| Quelle | vorhandene ZIP mit Präsentationen, Beispielen und Begleitdokumenten |
| Review-Typ | anonymisierte fachliche und didaktische Ausgangsbewertung |
| Zulässige Eigennamen | `Gerhard Pisch` |
| Zu entfernende Kennzeichen | das vom Auftraggeber bezeichnete Firmenlogo sowie zugehörige Firmen- und Markenkennzeichen |

## 1. Zweck

Dieses Dokument beschreibt die Ausgangsqualität der vorhandenen Schulungsunterlagen. Es dient als fachliche Arbeitsgrundlage für die Überarbeitung von Präsentation, Begleitunterlagen und Beispieldemos. Die Bewertung enthält keine schutzwürdigen Kontaktdaten, keine internen Systembezeichnungen und keine nicht freigegebenen Organisationskennzeichen.

## 2. Umfang des geprüften Bestands

Geprüft wurden fünf Präsentationsmodule mit insgesamt 171 Folien, begleitende SQL-Beispiele sowie ergänzende Dokumente. Die Module behandeln Einführung, Data Storage Internals, Processing Internals, Abfrageperformance und Fallen sowie Index-Themen.

## 3. Qualitätsbaseline

| Bewertungsbereich | Einschätzung |
|---|---:|
| Themenbreite | 7/10 |
| technisches Grundlagenwissen | 6/10 |
| fachliche Präzision | 4/10 |
| Aktualität | 4/10 |
| didaktische Struktur | 5/10 |
| Qualität der Beispiele | 5/10 |
| Quellenqualität | 4/10 |
| Reproduzierbarkeit | 3/10 |
| Datenschutz und Neutralität | 3/10 |
| Gesamt | 5/10 |

Die numerischen Werte sind eine qualitative Baseline und keine empirische Messung. Sie dienen dem Vergleich des Ausgangsstands mit späteren Review-Stufen.

## 4. Stärken

Die Unterlagen besitzen eine brauchbare fachliche Basis in den Themenbereichen Storage, Optimizer, Statistiken, Execution Plans, Join-Algorithmen, Buffer Pool, Memory Grants, SARGability, Partition Elimination, Parameter Sniffing, Rowstore- und Columnstore-Indizes sowie grundlegende Diagnoseabfragen. Bereits vorhandene SQL-Beispiele erleichtern den Umbau zu reproduzierbaren, messbaren Schulungsdemos.

## 5. Hauptbefunde mit hoher Priorität

### 5.1 Fachlich zu korrigierende oder zu präzisierende Aussagen

- CTE: keine garantierte Materialisierung; Spools sind Optimizer-Entscheidungen und keine allgemeine Eigenschaft eines CTE.
- Table Variables: pauschale Aussagen zu Statistiken und Parallelität sind nicht belastbar; Deferred Compilation, Compatibility Level und konkrete Operatoren sind zu berücksichtigen.
- Heap-Tabellen: Zugriffe müssen nicht grundsätzlich alle Pages durchsuchen; Heap Scan, RID Lookup und Forwarded Records sind zu unterscheiden.
- Filegroups: zusätzliche Files oder Filegroups erzeugen nicht automatisch zusätzliche I/O-Leistung; logische Verwaltung und physische Storage-Pfade sind getrennt zu behandeln.
- Plan Cache: vereinfachte historische Aging-Formeln sind kein stabiler, versionsunabhängiger Vertrag.
- Adaptive Join: Batch Mode und aktuelle Varianten einschließlich Batch Mode on Rowstore sind zu berücksichtigen.
- Columnstore-Maintenance: pauschale regelmäßige Rebuild-Empfehlungen sind zu ersetzen; `REORGANIZE`, Rowgroup-Qualität, Deleted Rows und Background Merge sind einzubeziehen.
- Hash-basierte Eindeutigkeit: ein Unique Index auf einem Hashwert garantiert ohne Kollisionsvertrag nicht die Eindeutigkeit der Ursprungswerte.
- Partitionierung und Threads: eine feste Zuordnung einer Partition zu genau einem Thread darf nicht vermittelt werden.
- Linked Server: lokale und entfernte Verarbeitung, Predicate Pushdown und Datenbewegung sind differenziert und messbar zu erklären.

### 5.2 Didaktische Defizite

- Lernziele sind überwiegend nicht explizit und nicht überprüfbar formuliert.
- Eine durchgängige Diagnosemethodik fehlt.
- Zu viele Folien vermitteln pauschale Regeln ohne Voraussetzungen, Gegenbeispiele, Messmethode und Trade-offs.
- Mehrere Folien sind für eine Projektionsfolie zu textlastig.
- Wissenskontrollen, Zusammenfassungen, Plan-Leseübungen und Transferaufgaben sind unzureichend.

### 5.3 Fehlende oder zu schwach ausgeprägte moderne Themen

Mit hoher Priorität zu ergänzen oder zu vertiefen sind:

- Query Store als historische Diagnosequelle,
- Blocking Chains, Head Blocker und Deadlockanalyse,
- Waits auf Request-, Session- und Serverebene,
- Estimated gegenüber Actual Rows,
- Memory Grant Feedback,
- Parameter Sensitive Plan Optimization,
- Cardinality Estimation Feedback,
- Degree of Parallelism Feedback,
- Batch Mode on Rowstore,
- Scalar UDF Inlining,
- Interleaved Execution,
- Deferred Compilation für Table Variables,
- TempDB-Contention und Version Store,
- Isolation Levels, RCSI und SNAPSHOT,
- Plan Warnings wie Spill, Implicit Conversion und Residual Predicate,
- Row Goals,
- Key Lookup Tipping Point,
- Query Store Hints,
- Page Density im Verhältnis zu Fragmentation,
- `OPTIMIZE_FOR_SEQUENTIAL_KEY`,
- Columnstore Rowgroup Quality und Segment Elimination,
- Extended Events als gezielte Diagnoseinstrumente.

## 6. Verbindlicher Diagnoseleitfaden

Die überarbeitete Schulung folgt modulübergreifend demselben Diagnoseablauf:

1. Symptom, Bezugszeitraum und betroffene Workload bestimmen.
2. CPU, Duration, Logical Reads, Physical Reads, Writes, Rows und Waits erfassen.
3. Blocking, Ressourcenengpässe und externe Warteursachen klassifizieren.
4. Actual Execution Plan und tatsächliche Kardinalitäten prüfen.
5. Schätzfehler, Zugriffspfade, Memory Grants, Parallelität und Spills untersuchen.
6. Eine überprüfbare Hypothese formulieren.
7. Genau eine fachlich begründete Änderung durchführen.
8. Vorher-Nachher-Vergleich unter vergleichbaren Bedingungen erstellen.
9. Nebenwirkungen, Wartungskosten und Versionsgrenzen bewerten.

## 7. Rollenmodell der Unterlagen

| Artefakt | Aufgabe |
|---|---|
| Projektionsfolie | Kernaussage, Struktur, Diagramm und wenige interpretierbare Messwerte |
| Sprecherhinweis | technische Herleitung, Voraussetzungen, Versionen, typische Fehlinterpretationen und Übergänge |
| Teilnehmerunterlage | vollständige Erklärung, Quellen, DMV-Abfragen, Grenzfälle und Nachschlageinformationen |
| Demo | reproduzierbare Evidenz mit Setup, Baseline, Problem, Messung, Gegenmaßnahme, Vergleich und Cleanup |

## 8. Sanitizing- und Branding-Regeln

- `Gerhard Pisch` darf im fachlich oder urheberrechtlich erforderlichen Kontext genannt werden.
- Das vom Auftraggeber bezeichnete Firmenlogo sowie die dazugehörigen Firmen- und Markenkennzeichen sind aus Präsentationen, Bildern, Notes, Masterfolien, Begleitdokumenten und Repository-Metadaten zu entfernen.
- Weitere nicht freigegebene Firmeninformationen, Kontaktdaten, interne Pfade, interne Tabellen-, Server- oder Umgebungsnamen sind zu entfernen oder zu neutralisieren.
- Office-Metadaten und eingebettete Medien sind vor der Übernahme zu prüfen.
- Eine visuelle Prüfung ist erforderlich, weil bildbasierte Logos durch Textsuche nicht zuverlässig erkannt werden.

## 9. Empfohlene Überarbeitungsreihenfolge

1. Fachlich falsche oder zu absolute Aussagen korrigieren.
2. Versions- und Quellenbezug pro kritischer Aussage herstellen.
3. Fehlende moderne SQL-Server-Funktionen ergänzen.
4. Diagnoseleitfaden als didaktischen roten Faden einziehen.
5. Vier Pilotdemos als Qualitätsmaßstab umsetzen: SARGability, Statistik-Skew, Blocking Chain und Memory Grant beziehungsweise Spill.
6. Projektionsfolien, Sprecherhinweise, Teilnehmerunterlagen und Demos trennen.
7. Bestehende Beispiele als `REUSE`, `REFACTOR`, `REBUILD`, `DIAGNOSTIC_ONLY` oder `REMOVE` klassifizieren und in den Demo-Vertrag überführen.
8. Branding und nicht freigegebene Organisationskennzeichen entfernen.

## 10. Zuordnung zum Masterplan

- Welle 0: Aussagenregister, fachliche Prüfung, Gap-Analyse, Baseline-Review und Sanitizing-Regeln.
- Querschnitt A: Lernziele, Modulreihenfolge, Diagnoseleitfaden, Übungs- und Prüfpfade sowie Rollenmodell der Unterlagen.
- Welle 1: Demo-Framework als gemeinsame technische Basis.
- Welle 2: fachliche Überarbeitung des Bestands, Demo-Vertrag, Reduktion der Projektionsfolien und Ergänzung der Tiefenmaterialien.
- Wellen 3 bis 9: schrittweise Umsetzung des modernisierten Demo-Bestands.

## 11. Arbeitsentscheidung

Der Bestand wird nicht unverändert übernommen. Fachlich fehlerhafte, veraltete, nicht reproduzierbare oder didaktisch ungeeignete Inhalte werden korrigiert, ersetzt oder neu aufgebaut. Die Qualitätsbaseline wird nach Abschluss von Gate A, Gate B und vor dem Release erneut bewertet.
