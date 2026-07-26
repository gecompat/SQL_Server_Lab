# Kritische Aussagenprüfung

**Arbeitspaket:** W0-004  
**Status:** VALIDATED  
**Prüfdatum:** 2026-07-24  
**Aktiver Foliensatz:** `Presentations/Performance_Schulung_Chat_2026-07-23_2146_SQL_Server_Performance_Grundlagen.pptx`  
**Quellenbasis:** [Primärquellenregister W0](../Research/PRIMARY_SOURCES_W0.md)

## Entscheidungsmaßstab

- `KEEP`: Die aktive Aussage ist fachlich tragfähig und angemessen eingegrenzt.
- `REFINE`: Der Kern ist richtig, aber Versionsgrenze, Voraussetzung oder Formulierung muss präzisiert werden.
- `REPLACE`: Eine übernommene Altbehauptung wäre irreführend und ist durch eine neue Aussage zu ersetzen.
- `REMOVE`: Die Behauptung hat keinen belastbaren fachlichen oder didaktischen Nutzen.

Die Schwere bewertet das Risiko, wenn die unpräzise Altbehauptung unverändert gelehrt würde. Sie bewertet nicht die Qualität des aktuellen Gesamtfoliensatzes.

## Prüfergebnisse

| ID | Thema und riskante Verkürzung | Dokumentierte Bewertung | Aktive Folie(n) | Version / Voraussetzung | Quellen | Entscheidung | Schwere / Folge |
|---|---|---|---:|---|---|---|---|
| CR-001 | „Eine CTE materialisiert das Ergebnis.“ | Eine CTE hat keine Materialisierungsgarantie; jede äußere Referenz kann erneut ausgeführt werden. Ein physischer Spool ist eine Planentscheidung, keine CTE-Semantik. | 41 | 2019–2025 | SRC-011, SRC-001 | KEEP | Hoch; aktive Aussage ist bereits korrigiert. |
| CR-002 | „Tabellenvariablen haben immer eine feste Schätzung.“ | Deferred Compilation kann ab SQL Server 2019/Stufe 150 die tatsächliche Kardinalität beim ersten Kompilieren nutzen; klassische Spaltenstatistiken entstehen dadurch nicht. | 42 | 2019+, CL 150 | SRC-007, SRC-008 | KEEP | Mittel; `W2-007` entfernt die feste Größenheuristik und trennt Zeilenzahl von Verteilungsstatistiken. |
| CR-003 | „Deferred Compilation löst jede Schätzungsabweichung.“ | Die erste tatsächliche Kardinalität verbessert den Startplan, ersetzt aber keine Spaltenstatistiken; Wiederverwendung und Datenverteilung bleiben relevant. | 42 | 2019+, CL 150 | SRC-007, SRC-008 | KEEP | Mittel; Folie nennt diese Grenze bereits. |
| CR-004 | „MSTVFs werden stets mit einer festen kleinen Zahl geschätzt.“ | Interleaved Execution kann ab Stufe 140 bei geeigneten MSTVFs während der Optimierung die tatsächliche Kardinalität der ersten Ausführung nutzen. | 43 | 2017+, CL 140 | SRC-007, SRC-008 | KEEP | Hoch; `W2-007` ergänzt Interleaved Execution, Eligibility und die Grenze fehlender Spaltenstatistiken. |
| CR-005 | „Memory-Grant-Feedback-Persistenz benötigt Stufe 160.“ | Perzentil- und Persistenzmodus kommen mit SQL Server 2022, gelten aber ab Stufe 140; Persistenz verlangt Query Store in `READ_WRITE`. | 34 | 2022+, CL 140, Query Store RW | SRC-007, SRC-009 | KEEP | Hoch; `W2-007` korrigiert Versionsmatrix, Compatibility Level und Query-Store-Voraussetzung. |
| CR-006 | „Jeder zu große Grant ist harmlos.“ | Überreservierung kann die Nebenläufigkeit über wartende Grants beeinträchtigen; Unterreservierung kann Spills verursachen. Angefordert, gewährt und genutzt sind getrennt zu prüfen. | 29–30, 74 | 2019–2025 | SRC-009, SRC-010 | KEEP | Hoch; aktive Diagnosekette ist korrekt. |
| CR-007 | „Ein niedriger Fill Factor ist generell schneller.“ | Freiraum kann Splits bei passenden Schreibmustern reduzieren, erhöht aber Speicher-, Cache- und I/O-Bedarf. Der Standard ist für viele Workloads geeigneter. | 57–58 | 2019–2025 | SRC-014, SRC-015 | KEEP | Hoch; keine starre Empfehlung im aktiven Deck. |
| CR-008 | „30 % Fragmentierung bedeutet automatisch REBUILD.“ | Die Dokumentation gibt keine universelle Grenzschwelle vor. Seitendichte, Scananteil, Wartungskosten und Messung im konkreten Workload sind mitzubeurteilen. | 57–58 | 2019–2025 | SRC-015 | KEEP | Hoch; aktive Folien behandeln die Entscheidung empirisch. |
| CR-009 | „`sys.partitions` liefert pro Tabelle genau eine Zeile.“ | Die Sicht liefert eine Zeile je Partition und Index/Heap; `index_id` 0 steht für Heap, 1 für clustered und Werte ab 2 für nonclustered. | 13, 44 | 2019–2025 | SRC-019 | KEEP | Mittel; aktive Folien sprechen von Allocation Units/Partitionen. |
| CR-010 | „Filegroups verteilen I/O automatisch optimal.“ | Dateien in einer Filegroup werden proportional gefüllt. Daraus folgt weder automatische Geräteparallelität noch ein Performancegewinn ohne passende Dateiplatzierung und Messung. | 9 | 2019–2025 | SRC-003 | KEEP | Hoch; aktive Folie grenzt die Behauptung ab. |
| CR-011 | „Eine Tabellenpartition entspricht einem Worker/Thread.“ | Worker und Tasks werden aus dem gewählten parallelen Plan und der Laufzeitausführung abgeleitet; Partitionierung ist keine 1:1-Thread-Zuordnung. | 31, 44 | 2019–2025 | SRC-001, SRC-018 | KEEP | Hoch; frühere Pauschalaussage ist nicht übernommen. |
| CR-012 | „RCSI und SNAPSHOT sind dasselbe.“ | RCSI verwendet eine konsistente Sicht je Statement; SNAPSHOT eine Sicht für die Transaktion. Schreibkonflikte und Fehlerbehandlung unterscheiden sich. | 64–65 | 2019–2025; Datenbankoptionen | SRC-004 | KEEP | Hoch; aktive Tabelle trennt beide Ebenen. |
| CR-013 | „Row Versioning beseitigt jede Blockierung.“ | Zeilenversionierung reduziert bestimmte Leser-Schreiber-Konflikte, hebt aber Schema-, Metadaten- und Schreibkonflikte nicht auf und verursacht Version-Store-Kosten. | 65, 68 | 2019–2025 | SRC-004, SRC-029 | KEEP | Hoch; aktive Folien nennen Trade-offs. |
| CR-014 | „Optimized Locking ist in SQL Server 2025 immer aktiv.“ | Die Funktion ist pro Datenbank zu aktivieren. TID Locking setzt ADR voraus; LAQ setzt zusätzlich RCSI voraus. Schema-Sperren und `tempdb`-Änderungen bleiben außerhalb bestimmter Vorteile. | 69 | 2025; Datenbankkonfiguration | SRC-025 | KEEP | Hoch; Voraussetzungen stehen im aktiven Deck. |
| CR-015 | „Ein Heap ist grundsätzlich schlecht.“ | Heaps können für bestimmte Staging-/Ladevorgänge sinnvoll sein. Ohne passenden Nonclustered Index erfolgt Scan; RID-Lookups und Forwarded Records können Kosten erhöhen. | 49, 51 | 2019–2025 | SRC-013 | KEEP | Mittel; aktive Entscheidung ist workloadbezogen. |
| CR-016 | „RID Lookup und Forwarded Record sind dasselbe.“ | RID Lookup ist der Zugriff eines Nonclustered Index auf eine Heapzeile; Forwarded Records entstehen durch vergrößerte variable Zeilen und verursachen zusätzliche Zugriffe. | 49, 51 | 2019–2025 | SRC-013 | KEEP | Mittel; Begriffe bleiben getrennt. |
| CR-017 | „Columnstore ist immer Batch Mode und automatisch optimal komprimiert.“ | Rowgroups können offen, geschlossen oder komprimiert sein; Delta Store/Delete Bitmap und Rowgroup-Qualität beeinflussen Scan und Elimination. | 59–61 | 2019–2025 | SRC-016, SRC-017 | KEEP | Hoch; aktive Folien zeigen die Zustände. |
| CR-018 | „Columnstore-Reorganisation folgt denselben Regeln wie Rowstore.“ | Columnstore-Wartung richtet sich unter anderem nach gelöschten Zeilen und Rowgroup-Qualität; seit SQL Server 2019 kann der Hintergrund-Merge zusätzliche Arbeit übernehmen. | 61 | 2019–2025 | SRC-015, SRC-016 | KEEP | Mittel; aktive Folie priorisiert Diagnose statt Kalender. |
| CR-019 | „Batch Mode erfordert einen Columnstore-Index.“ | Batch Mode on Rowstore ist ab SQL Server 2019 mit Stufe 150 verfügbar, bleibt aber eine Optimiererentscheidung und keine Ausführungsgarantie. | 34, 60 | 2019+, CL 150 | SRC-007, SRC-008 | KEEP | Mittel; aktive Aussage ist korrekt eingegrenzt. |
| CR-020 | „Adaptive Join wählt schon beim Kompilieren einen festen Join.“ | Batch Mode Adaptive Join kann ab Stufe 140 zur Laufzeit anhand der tatsächlichen Eingabemenge zwischen Alternativen wählen. | 28, 34 | 2017+, CL 140 | SRC-007 | KEEP | Mittel; aktive Folie beschreibt die Laufzeitentscheidung. |
| CR-021 | „CE Feedback ist in SQL Server 2022 unabhängig von Query Store aktiv.“ | CE Feedback setzt SQL Server 2022, Stufe 160 und Query Store in `READ_WRITE` voraus. | 34 | 2022+, CL 160, Query Store RW | SRC-007, SRC-006 | KEEP | Hoch; Voraussetzung in Notes/Register sichern. |
| CR-022 | „Ein Plan bleibt gültig, bis er pauschal aus dem Cache gelöscht wird.“ | Wiederverwendung hängt von Cache-Schlüssel, SET-Optionen, Objekt-/Statistikänderungen und Recompile-Ereignissen ab; getrennte Cacheeinträge sind nicht dasselbe wie Invalidierung. | 32 | 2019–2025 | SRC-001 | KEEP | Mittel; `W2-007` trennt Cache-Key-Mismatch, zusätzliche Einträge, Eviction, Invalidierung und Recompile. |
| CR-023 | „Remote Pushdown ist bei Linked Servers zuverlässig erzwingbar.“ | Pushdown hängt unter anderem von Providerfähigkeiten, Collation, Ausdruck und Plan ab. SQL Server 2025 bringt beim neueren OLE-DB-Treiber eine Verschlüsselungsanforderung mit Migrationswirkung. | 45 | 2019–2025; Providerabhängigkeit | SRC-020, SRC-021, SRC-022 | KEEP | Hoch; aktive Folie warnt bereits vor Pauschalen. |
| CR-024 | „Ein Unique Index auf einen Hash garantiert die Eindeutigkeit der Ausgangswerte.“ | Der Unique Index garantiert nur die Eindeutigkeit des endlichen Hashschlüssels. Eine Kollisionsfreiheit der beliebig großen Ausgangsdomäne folgt daraus nicht. | – | Algorithmus-/Schlüsselabhängigkeit | SRC-023, SRC-024 | REPLACE | Hoch; nicht in das aktive Deck übernehmen. Schlussfolgerung ist explizite Inferenz aus beiden Quellen. |
| CR-025 | „Optional-Parameter-Muster sind erst durch einen manuellen Rewrite lösbar.“ | OPPO kann in SQL Server 2025 bei Stufe 170 und aktivierter Datenbankkonfiguration Dispatcher- und Variantenpläne erzeugen; Eligibility bleibt zu prüfen. | 40 | 2025, CL 170, Konfiguration ON | SRC-026 | KEEP | Mittel; aktive Folie unterscheidet Altversionen und OPPO. |
| CR-026 | „Query Store ersetzt Live-Diagnose und Extended Events.“ | Query Store liefert persistente Query-/Plan-/Laufzeithistorie; DMVs und Extended Events beantworten andere Zeit- und Ereignisfragen. | 5, 76–77 | 2019–2025; Konfiguration beachten | SRC-027, SRC-028 | KEEP | Mittel; aktive Folien trennen die Werkzeuge. |

## Befund für den aktiven Foliensatz

Die vier in Welle 0 identifizierten Präzisierungen wurden mit `W2-007` abgeschlossen. Maßgeblich ist der [W2-007-Review](../Project_Planning/W2_007_REFINE_CLAIMS_REVIEW.md).

| Folie | abgeschlossene Präzisierung | Abnahme |
|---:|---|---|
| 32 | Cache-Schlüssel und zusätzliche Cacheeinträge von Eviction, Invalidierung und Recompile getrennt | Keine pauschale Aussage, dass abweichende SET-Optionen einen vorhandenen Plan invalidieren |
| 34 | MGF-Persistenz/Perzentilmodus auf SQL Server 2022+, CL 140 und Query Store `READ_WRITE` eingeordnet; OPPO auf SQL Server 2025/CL 170 begrenzt | Funktionsmatrix, sichtbarer Text und Notes stimmen mit den Quellen überein |
| 42 | Table Variable Deferred Compilation von Spaltenverteilungsstatistiken und Planwiederverwendung getrennt; feste Größenheuristik entfernt | Entscheidung ist explizit empirisch und besitzt keine allgemeine Zeilengrenze |
| 43 | Interleaved Execution für geeignete MSTVFs ab CL 140 sowie Scalar UDF Inlining ab CL 150 mit Eligibility-/Planprüfung ergänzt | Feste Schätzung und Inlining werden nicht als ausnahmslose aktuelle Regel gelehrt |

Alle 84 aktiven Claims besitzen damit den Status `KEEP`. Keine Aussage mit Entscheidung `REMOVE` befindet sich im aktiven Deck.

## Abdeckung von W0-004

Vollständig bewertet sind CTEs, Tabellenvariablen, Fill Factor, Partition-Metadaten, Isolation, Columnstore, Cardinality Estimation, Filegroups, Memory Grants sowie die zusätzlichen Risikofelder Heaps, RID Lookup, Forwarded Records, Plan-Cache/Recompile, Adaptive Join, Batch Mode on Rowstore, Columnstore-Wartung, Remote Pushdown, Linked Servers, Partitionierung, Worker/Tasks/Threads und Hash-Eindeutigkeit.
