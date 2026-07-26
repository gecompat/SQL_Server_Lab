# Folien- und Aussagenregister

**Arbeitspakete:** W0-003, CUR-005  
**Status:** VALIDATED  
**Prüfdatum:** 2026-07-24  
**Aktiver Foliensatz:** `Presentations/Performance_Schulung_Chat_2026-07-23_2146_SQL_Server_Performance_Grundlagen.pptx`  
**SHA-256:** `3ad528c2eb6ad531c1bbf5a26bee17e35004f764357b5061c9fc15bc04807a18`  
**Folienumfang:** 84  
**Quellenbasis:** [Primärquellenregister W0](../Research/PRIMARY_SOURCES_W0.md)  
**Vertiefung:** [Kritische Aussagenprüfung](../Reviews/CRITICAL_CLAIMS_REVIEW.md)

## Leseschlüssel

- `DOCUMENTED`: dokumentierte Produkteigenschaft;
- `EMPIRICAL`: workloadabhängige Empfehlung; Mechanismus dokumentiert, Entscheidung zu messen;
- `METHOD`: Diagnose- oder Unterrichtsmethode;
- `DIDACTIC`: Navigation, Lernziel, Transfer oder Zusammenfassung;
- `KEEP`, `REFINE`, `REPLACE`, `REMOVE`: Entscheidung gemäß kritischer Aussagenprüfung.

Die stabile Folien-ID stammt aus der internen Folienkennung des geprüften Office-Pakets und dient neben der Foliennummer als robuste Referenz. `–` bei Quellen bedeutet, dass die Folie keine eigenständige Produktbehauptung aufstellt. Kanonische Demo-IDs werden nur vergeben, wenn die Aussage ein reproduzierbares Verhalten sinnvoll benötigt. Die IDs stammen aus dem Master-Umsetzungsplan; Zuordnung und Testprofil stehen in der [Traceability-Matrix](../Curriculum/TRACEABILITY_MATRIX.md).

## Register

| Claim | Folie | Stabile ID | Modul | Evidenz | Kernaussage / Lernziel | Version / Grenze | Quellen | Entscheidung | Kanonische Demo |
|---|---:|---|---|---|---|---|---|---|---|
| CLM-001 | 1 | sl/adhi2b | Einstieg | DIDACTIC | Titel und fachlicher Rahmen des Grundlagenkurses | 2019–2025 | – | KEEP | – |
| CLM-002 | 2 | sl/2ga0dd | Einstieg | METHOD | Erst beobachten und messen, dann gezielt verändern | versionsneutral | SRC-028 | KEEP | – |
| CLM-003 | 3 | sl/4lobkv | Einstieg | METHOD | Performance als Zusammenspiel von Latenz, Durchsatz, Ressourcen und Nebenläufigkeit bewerten | versionsneutral | SRC-028 | KEEP | – |
| CLM-004 | 4 | sl/vorwd3 | Einstieg | METHOD | Diagnosezyklus: Symptom, Engpass, Plan, Änderung, Nachweis | versionsneutral | SRC-027, SRC-028 | KEEP | – |
| CLM-005 | 5 | sl/rolfsq | Einstieg | DOCUMENTED | Plan, DMVs, Query Store, Extended Events und OS-Metriken beantworten unterschiedliche Fragen | 2019–2025 | SRC-027, SRC-028 | KEEP | – |
| CLM-006 | 6 | sl/an179p | Einstieg | DOCUMENTED | IQP-Funktionen hängen von Engine-Version, Kompatibilitätsstufe und teils Konfiguration ab | 2019–2025; CL 140–170 | SRC-007, SRC-025, SRC-026 | KEEP | – |
| CLM-007 | 7 | sl/6zxqml | Storage | DIDACTIC | Modulnavigation zu Storage und I/O | – | – | KEEP | – |
| CLM-008 | 8 | sl/b5b7hl | Storage | DOCUMENTED | Daten- und Logdateien haben unterschiedliche Rollen und I/O-Muster | 2019–2025 | SRC-003, SRC-033 | KEEP | STL-005 |
| CLM-009 | 9 | sl/ifx81i | Storage | DOCUMENTED | Filegroups sind Verwaltungs-/Platzierungseinheiten; Performance folgt nicht automatisch | 2019–2025 | SRC-003 | KEEP | – |
| CLM-010 | 10 | sl/sepwd6 | Storage | DOCUMENTED | SQL Server organisiert Datenseiten in Extents; die Struktur erklärt Zugriffsmuster | 2019–2025 | SRC-002 | KEEP | STL-004 |
| CLM-011 | 11 | sl/x0hi9d | Storage | DOCUMENTED | Zeilen- und Seitenstruktur begrenzen nutzbaren Platz und beeinflussen Seitenzahl | 2019–2025 | SRC-002 | KEEP | – |
| CLM-012 | 12 | sl/xba3wh | Storage | DOCUMENTED | Breitere Zeilen senken Zeilen pro Seite und können logische Reads erhöhen | 2019–2025 | SRC-002 | KEEP | STL-001 |
| CLM-013 | 13 | sl/nh3gh9 | Storage | DOCUMENTED | Allocation Units trennen In-row-, LOB- und Row-overflow-Speicher innerhalb von Partitionen | 2019–2025 | SRC-002, SRC-019 | KEEP | – |
| CLM-014 | 14 | sl/mwgino | Storage | DOCUMENTED | Der Buffer Pool macht logische Reads zur zentralen Messgröße; physische Reads sind ein Teil davon | 2019–2025 | SRC-001 | KEEP | STL-006 |
| CLM-015 | 15 | sl/nz5lwz | Storage | DOCUMENTED | Logical Reads und Physical Reads sind getrennt zu interpretieren; Cachezustand beeinflusst den Messlauf | 2019–2025 | SRC-001 | KEEP | STL-006 |
| CLM-016 | 16 | sl/vdvv7n | Storage | DOCUMENTED | Write-ahead logging, Log Flush und Checkpoint erfüllen unterschiedliche Persistenz-/Wiederherstellungsaufgaben | 2019–2025 | SRC-033 | KEEP | STL-007 |
| CLM-017 | 17 | sl/p8ev2r | Storage | EMPIRICAL | Autogrowth ist Sicherheitsnetz, nicht Kapazitätsplanung; IFI behandelt Daten- und Logwachstum unterschiedlich | 2019–2025; Dienst-/Sicherheitskontext | SRC-003, SRC-034 | KEEP | – |
| CLM-018 | 18 | sl/76l4h4 | Storage | DIDACTIC | Wissenssicherung zu Storage und I/O | – | – | KEEP | – |
| CLM-019 | 19 | sl/eailr5 | Query Processing | DIDACTIC | Modulnavigation zu Query Processing | – | – | KEEP | – |
| CLM-020 | 20 | sl/ltnie4 | Query Processing | DOCUMENTED | Eine Abfrage durchläuft Parsing/Binding, Optimierung und Ausführung | 2019–2025 | SRC-001 | KEEP | – |
| CLM-021 | 21 | sl/ta6csx | Query Processing | DOCUMENTED | Der kostenbasierte Optimierer sucht zeitbegrenzt und garantiert nicht den global optimalen Plan | 2019–2025 | SRC-001 | KEEP | – |
| CLM-022 | 22 | sl/6p93rr | Query Processing | DOCUMENTED | Kardinalitätsschätzungen treiben Joinwahl, Grants und Parallelitätsentscheidungen | 2019–2025; CE-Modell beachten | SRC-001, SRC-006 | KEEP | OPT-001 |
| CLM-023 | 23 | sl/0dgant | Query Processing | DOCUMENTED | Statistiken liefern Histogramm- und Dichteinformationen für Schätzungen | 2019–2025 | SRC-005 | KEEP | OPT-002 |
| CLM-024 | 24 | sl/91ehoe | Query Processing | DOCUMENTED | Histogramm und Dichte haben unterschiedliche Aussagebereiche; Kombinationen können Annahmen erfordern | 2019–2025; CE-Modell beachten | SRC-005, SRC-006 | KEEP | OPT-002 |
| CLM-025 | 25 | sl/f7hui4 | Query Processing | DOCUMENTED | Vertrauenswürdige Constraints können dem Optimierer zusätzliche logische Informationen geben | 2019–2025 | SRC-001 | KEEP | – |
| CLM-026 | 26 | sl/x9ooxu | Query Processing | METHOD | Estimated-versus-Actual-Abweichung ist ein Startpunkt, kein alleiniger Ursachenbeweis | 2019–2025 | SRC-031, SRC-005 | KEEP | OPT-001 |
| CLM-027 | 27 | sl/9sh4eo | Query Processing | METHOD | Pläne entlang Datenfluss, Zeilen, Kosten, Warnungen und Eigenschaften lesen | 2019–2025 | SRC-031 | KEEP | OPT-001 |
| CLM-028 | 28 | sl/ehe3d0 | Query Processing | DOCUMENTED | Joinoperatoren passen zu unterschiedlichen Eingabe-/Sortier-/Größensituationen; Adaptive Join entscheidet gegebenenfalls zur Laufzeit | 2019–2025; Adaptive Join CL 140 | SRC-001, SRC-007 | KEEP | OPT-012 |
| CLM-029 | 29 | sl/mbhe9f | Query Processing | DOCUMENTED | Sort/Hash können Memory Grants anfordern; Schätzung beeinflusst Warten, Reserve und Spill-Risiko | 2019–2025 | SRC-009, SRC-010 | KEEP | OPT-014 |
| CLM-030 | 30 | sl/illpzu | Query Processing | DOCUMENTED | Spills sind Laufzeitfolgen unzureichender Arbeitsfläche und im Plan/Monitoring nachzuweisen | 2019–2025 | SRC-009, SRC-029, SRC-031 | KEEP | OPT-013 |
| CLM-031 | 31 | sl/hzgydc | Query Processing | DOCUMENTED | Parallelität besteht aus Tasks/Workern; Skew kann ein paralleles Gesamtergebnis dominieren | 2019–2025 | SRC-001 | KEEP | RES-002 |
| CLM-032 | 32 | sl/vhqglr | Query Processing | DOCUMENTED | Cache-Schlüssel, zusätzliche Cacheeinträge, Eviction, Invalidierung und Recompile sind getrennte Zustände der Planwiederverwendung | 2019–2025; Query Store nur bei aktiver Konfiguration | SRC-001, SRC-027 | KEEP | OPT-007 |
| CLM-033 | 33 | sl/7j9iwe | Query Processing | DOCUMENTED | Ein einzelner gecachter Plan kann bei ungleich verteilten Parameterwerten ungeeignet sein | 2019–2025; PSP ab 2022/CL 160 | SRC-007 | KEEP | OPT-008 |
| CLM-034 | 34 | sl/ju46sf | Query Processing | DOCUMENTED | IQP-Funktionen besitzen getrennte Voraussetzungen aus Engine-Version, Compatibility Level, Datenbankkonfiguration, Query Store und Query-Eligibility | 2019–2025; MGF-Persistenz/Perzentil: 2022+, CL 140, Query Store READ_WRITE; OPPO: 2025, CL 170 | SRC-007, SRC-008, SRC-009, SRC-026 | KEEP | – |
| CLM-035 | 35 | sl/kczsyg | Query Processing | DIDACTIC | Wissenssicherung zu Optimierung und Ausführung | – | – | KEEP | – |
| CLM-036 | 36 | sl/cll1q5 | Query Patterns | DIDACTIC | Modulnavigation zu Abfragemustern | – | – | KEEP | – |
| CLM-037 | 37 | sl/balkx4 | Query Patterns | DOCUMENTED | SARGable Prädikate erleichtern passende Suchzugriffe; Funktionen auf Suchspalten können sie verhindern | 2019–2025 | SRC-012 | KEEP | QRY-001 |
| CLM-038 | 38 | sl/n587oc | Query Patterns | DOCUMENTED | Datentyppräzedenz kann implizite Konvertierung an der Spalte und damit Plan-/Zugriffsfolgen erzeugen | 2019–2025 | SRC-030, SRC-031 | KEEP | QRY-002 |
| CLM-039 | 39 | sl/e1wq25 | Query Patterns | DOCUMENTED | Halb offene Datumsintervalle vermeiden Zeitanteilsfehler und bleiben suchbar | 2019–2025 | SRC-012 | KEEP | QRY-003 |
| CLM-040 | 40 | sl/2th1fh | Query Patterns | DOCUMENTED | Optionale Prädikate können planempfindlich sein; OPPO erzeugt ab SQL Server 2025 geeignete Varianten unter Voraussetzungen | 2025/CL 170 für OPPO | SRC-026 | KEEP | QRY-004 |
| CLM-041 | 41 | sl/n34ud6 | Query Patterns | DOCUMENTED | Eine CTE ist eine logische Abfrageform ohne Materialisierungsgarantie | 2019–2025 | SRC-011, SRC-001 | KEEP | QRY-008 |
| CLM-042 | 42 | sl/hv65ke | Query Patterns | DOCUMENTED / EMPIRICAL | Temp Tables können Spaltenstatistiken besitzen; Table Variable Deferred Compilation nutzt bei CL 150 die erste Zeilenzahl, ersetzt aber keine Verteilungsstatistiken oder workloadbezogene Eignungsprüfung | 2019+, TVDC CL 150; empirische Wahl ohne feste Zeilengrenze | SRC-007, SRC-008 | KEEP | QRY-008 |
| CLM-043 | 43 | sl/240x87 | Query Patterns | DOCUMENTED | Inline TVFs sind relational integrierbar; Interleaved Execution kann geeignete MSTVFs ab CL 140 mit erster Ist-Kardinalität optimieren; Scalar UDF Inlining bleibt eligibility- und planabhängig | 2017+, CL 140 für Interleaved Execution; 2019+, CL 150 für Scalar UDF Inlining | SRC-007, SRC-008 | KEEP | QRY-009 |
| CLM-044 | 44 | sl/thzv62 | Query Patterns | DOCUMENTED | Partition Elimination folgt passenden Prädikaten und Grenzen; Partitionierung ersetzt keinen selektiven Index | 2019–2025 | SRC-018 | KEEP | QRY-012 |
| CLM-045 | 45 | sl/kiz4xp | Query Patterns | DOCUMENTED | Remote Pushdown hängt von Provider, Collation, Ausdruck und Plan ab; SQL Server 2025 ändert Treibervoraussetzungen | 2019–2025; Providerabhängigkeit | SRC-020, SRC-021, SRC-022 | KEEP | QRY-012 |
| CLM-046 | 46 | sl/hsj9bd | Query Patterns | DOCUMENTED | Datentypen und Modellierung beeinflussen Zeilenbreite, Konvertierungen, Schätzungen und Indizierbarkeit | 2019–2025 | SRC-002, SRC-005, SRC-030 | KEEP | – |
| CLM-047 | 47 | sl/g0w7mq | Query Patterns | DIDACTIC | Wissenssicherung zu Abfragemustern | – | – | KEEP | – |
| CLM-048 | 48 | sl/nbg9po | Indexes | DIDACTIC | Modulnavigation zu Indexen | – | – | KEEP | – |
| CLM-049 | 49 | sl/huaq3x | Indexes | DOCUMENTED | Heap und Clustered Index sind unterschiedliche Speicherorganisationen mit workloadabhängigen Trade-offs | 2019–2025 | SRC-012, SRC-013 | KEEP | IDX-001 |
| CLM-050 | 50 | sl/d5ushq | Indexes | DOCUMENTED | B+-Baum-Ebenen ermöglichen Suchnavigation; Höhe und Seitenzahl folgen Schlüssel/Zeilenmenge | 2019–2025 | SRC-012 | KEEP | – |
| CLM-051 | 51 | sl/ik4dwv | Indexes | DOCUMENTED | Nonclustered-Blätter enthalten einen Zeilenlokator; dessen Form hängt von Heap oder Clustered Index ab | 2019–2025 | SRC-012, SRC-013 | KEEP | IDX-001 |
| CLM-052 | 52 | sl/v80a9r | Indexes | DOCUMENTED | Schlüsselreihenfolge bestimmt nutzbare Suchpräfixe sowie Sortier-/Gruppierungsmöglichkeiten | 2019–2025 | SRC-012 | KEEP | IDX-003 |
| CLM-053 | 53 | sl/zl9dye | Indexes | DOCUMENTED | INCLUDE und Filter können Abdeckung/Selektivität verbessern, erhöhen aber Wartungs- und Speicheraufwand | 2019–2025 | SRC-012 | KEEP | IDX-003 |
| CLM-054 | 54 | sl/s03916 | Indexes | EMPIRICAL | Seek-plus-Lookup kann oberhalb eines workloadabhängigen Tipping Points teurer als Scan werden | 2019–2025 | SRC-001, SRC-012 | KEEP | IDX-004 |
| CLM-055 | 55 | sl/5uxw6h | Indexes | EMPIRICAL | Ein schmaler, stabiler Clustered Key reduziert den Lokatoranteil vieler Nonclustered Indexe | 2019–2025 | SRC-012 | KEEP | – |
| CLM-056 | 56 | sl/sry085 | Indexes | METHOD | Indexentscheidung balanciert Lesegewinn gegen Schreib-, Speicher- und Wartungskosten | 2019–2025 | SRC-012, SRC-032 | KEEP | – |
| CLM-057 | 57 | sl/2a32fw | Indexes | DOCUMENTED / EMPIRICAL | Page Split, logische Fragmentierung und Seitendichte sind getrennte Signale; Fill Factor ist workloadabhängig | 2019–2025 | SRC-014, SRC-015 | KEEP | IDX-006 |
| CLM-058 | 58 | sl/v16nzl | Indexes | EMPIRICAL | Indexwartung braucht Messziel und Wirkungskontrolle statt fester globaler Schwellen | 2019–2025 | SRC-015 | KEEP | IDX-006 |
| CLM-059 | 59 | sl/h915mh | Columnstore | DOCUMENTED | Columnstore organisiert Daten in Rowgroups/Segmenten und verwendet Delta Store/Delete Bitmap | 2019–2025 | SRC-016 | KEEP | IDX-009 |
| CLM-060 | 60 | sl/33fb68 | Columnstore | DOCUMENTED | Batch Mode und Segment Elimination können Verarbeitung reduzieren, sind aber plan-/datenabhängig | 2019–2025; BMoR ab CL 150 | SRC-007, SRC-016, SRC-017 | KEEP | IDX-010 |
| CLM-061 | 61 | sl/jiclp1 | Columnstore | DOCUMENTED / EMPIRICAL | Rowgroup-Qualität und gelöschte Zeilen steuern Diagnose und Wartung; Hintergrund-Merge unterstützt ab 2019 | 2019–2025 | SRC-015, SRC-016, SRC-017 | KEEP | IDX-010 |
| CLM-062 | 62 | sl/y7vcjo | Indexes | DIDACTIC | Wissenssicherung zu Rowstore und Columnstore | – | – | KEEP | – |
| CLM-063 | 63 | sl/2t390o | Concurrency | DIDACTIC | Modulnavigation zu Nebenläufigkeit | – | – | KEEP | – |
| CLM-064 | 64 | sl/rr9m1q | Concurrency | DOCUMENTED | Isolation Levels unterscheiden Konsistenzsicht, Sperrverhalten und Konfliktrisiko | 2019–2025; Datenbankoptionen | SRC-004 | KEEP | CON-003 |
| CLM-065 | 65 | sl/bgtaf7 | Concurrency | DOCUMENTED | Locking und Row Versioning verschieben Konflikte und Kosten, beseitigen sie aber nicht | 2019–2025 | SRC-004, SRC-029 | KEEP | CON-003 |
| CLM-066 | 66 | sl/6x4hov | Concurrency | METHOD | Blocking ist als Kette von wartender Session zur blockierenden Wurzel zu untersuchen | 2019–2025 | SRC-036 | KEEP | CON-004 |
| CLM-067 | 67 | sl/1ftcr8 | Concurrency | DOCUMENTED | Blocking ist Warten; Deadlock ist ein Zyklus, den die Engine durch Abbruch eines Opfers auflöst | 2019–2025 | SRC-004 | KEEP | CON-006 |
| CLM-068 | 68 | sl/qa7yug | Concurrency | DOCUMENTED | `tempdb` trägt temporäre Objekte, Worktables/Spills und je nach Konfiguration Versionsspeicher | 2019–2025 | SRC-029, SRC-004 | KEEP | CON-009 |
| CLM-069 | 69 | sl/ia6lp2 | Concurrency | DOCUMENTED | Optimized Locking reduziert bestimmte Sperrkosten mit TID/LAQ, verlangt aber ADR/RCSI-konforme Voraussetzungen | 2025; Datenbankkonfiguration | SRC-025 | KEEP | CON-008 |
| CLM-070 | 70 | sl/dbcybv | Concurrency | DIDACTIC | Wissenssicherung zu Isolation und Blocking | – | – | KEEP | – |
| CLM-071 | 71 | sl/filv67 | Diagnose | DIDACTIC | Modulnavigation zu Diagnosewerkzeugen | – | – | KEEP | – |
| CLM-072 | 72 | sl/4yq8ci | Diagnose | METHOD | Hohe CPU-Auslastung und CPU-bezogene Waits sind unterschiedliche Signale und brauchen Zeitkorrelation | 2019–2025 | SRC-028, SRC-035 | KEEP | RES-001 |
| CLM-073 | 73 | sl/jolrz3 | Diagnose | DOCUMENTED | Instanzweite kumulative Waits und aktuelle Task-Waits haben unterschiedliche Geltungsbereiche | 2019–2025 | SRC-035, SRC-036 | KEEP | RES-007 |
| CLM-074 | 74 | sl/n3gaqp | Diagnose | DOCUMENTED | `RESOURCE_SEMAPHORE` kann auf wartende Query Memory Grants hinweisen; Grant-DMV trennt Anforderung und Zuteilung | 2019–2025 | SRC-010, SRC-035 | KEEP | RES-003 |
| CLM-075 | 75 | sl/2adnro | Diagnose | METHOD | Wait-Kategorien priorisieren Hypothesen, ersetzen aber nicht Plan-/Workloadbezug | 2019–2025 | SRC-035, SRC-036 | KEEP | – |
| CLM-076 | 76 | sl/6qcm2e | Diagnose | DOCUMENTED | Query Store speichert Query-, Plan- und Laufzeithistorie und unterstützt Regressionsanalyse/Steuerung | 2019–2025; Konfiguration/Status prüfen | SRC-027 | KEEP | DGN-003 |
| CLM-077 | 77 | sl/375xu5 | Diagnose | DOCUMENTED | Extended Events und DMVs ergänzen Query Store für Ereignis- und Livezustände | 2019–2025 | SRC-027, SRC-028 | KEEP | DGN-005 |
| CLM-078 | 78 | sl/nrr330 | Diagnose | METHOD | Outside-in: Nutzerzeit, Systemsignal, Query/Plan und Operatorursache schrittweise verbinden | versionsneutral | SRC-027, SRC-028 | KEEP | – |
| CLM-079 | 79 | sl/l09mlv | Diagnose | METHOD | Vorher/Nachher braucht gleiche Last, Zeitraum, Cache-/Datenzustand und mehrere relevante Metriken | versionsneutral | SRC-027, SRC-028 | KEEP | – |
| CLM-080 | 80 | sl/6qupjg | Diagnose | DIDACTIC | Wissenssicherung zur evidenzbasierten Diagnose | – | – | KEEP | – |
| CLM-081 | 81 | sl/67icwm | Abschluss | METHOD | Messung, Reproduzierbarkeit, Versionsgrenzen und Rückfallplan bilden die Leitprinzipien | versionsneutral | SRC-027, SRC-028 | KEEP | – |
| CLM-082 | 82 | sl/vx6txt | Abschluss | DIDACTIC | Transfer vom Symptom zur prüfbaren nächsten Maßnahme | – | – | KEEP | – |
| CLM-083 | 83 | sl/nfagg6 | Abschluss | METHOD | Quellen, Versionsgrenzen und empirische Ergebnisse müssen getrennt und nachverfolgbar bleiben | versionsneutral | SRC-007, SRC-028 | KEEP | – |
| CLM-084 | 84 | sl/okdptu | Abschluss | DIDACTIC | Abschluss und weiterführender Arbeitsauftrag | – | – | KEEP | – |

## Abdeckungs- und Entscheidungsbilanz

| Kennzahl | Wert |
|---|---:|
| Folien im aktiven Deck | 84 |
| Registerzeilen | 84 |
| Eindeutige stabile Folien-IDs | 84 |
| `KEEP` | 84 |
| `REFINE` | 0 |
| `REPLACE` | 0 |
| `REMOVE` | 0 |
| Folien mit kanonischer Demo-ID | 47 |
| Eindeutige kanonische Demo-IDs | 36 |

Die vier früheren `REFINE`-Entscheidungen wurden in `W2-007` abgeschlossen. Sichtbarer Folientext, Speaker Notes, Quellen, Versionsgrenzen und Traceability sind im [W2-007-Review](../Project_Planning/W2_007_REFINE_CLAIMS_REVIEW.md) dokumentiert. Die kanonischen Demo-IDs sind eine curriculare Zuordnung; ihr Implementierungs- oder Validierungsstatus wird getrennt geführt.
