# Traceability-Matrix

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `CUR-005` |
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Aussagen | 84 |
| Lernziele | 43 |
| Primärquellen | 36 |
| Folien mit Demo-Zuordnung | 47 |
| Eindeutige kanonische Demo-Bündel | 36 |

## 1. Zweck

Die Matrix bildet die Kette Quelle → Aussage → Curriculum-Lernziel → aktive Folie → geplantes Demo-Bündel → Testziel ab. Aussagewortlaut, stabile Folien-ID, Versionsgrenze und fachliche Entscheidung stehen im [Folien- und Aussagenregister](../Inventories/SLIDE_STATEMENT_REGISTER.md). Die vier früheren `REFINE`-Entscheidungen sind durch `W2-007` abgeschlossen; fachliche Änderung und Abnahme stehen im [W2-007-Review](../Project_Planning/W2_007_REFINE_CLAIMS_REVIEW.md).

Eine Demo-Zuordnung bedeutet `PLANNED`, nicht `IMPLEMENTED` oder `VALIDATED`. Ein Gedankenmodell, eine Navigation oder eine methodische Folie benötigt nicht künstlich eine Runtime-Demo; in diesem Fall prüfen Quellenreview, Struktur- und Präsentationstest die Nachverfolgbarkeit.

## 2. Testprofile

| Profil | Zugeordnete Qualitätsarbeitspakete | Zweck |
|---|---|---|
| `TP-DOC` | `TST-001`, `TST-010` | Struktur, Linkage, Folien-/Notes-Konsistenz und Renderprüfung |
| `TP-RUN` | `TST-003`, `TST-004`, `TST-005`, `TST-006`, `TST-010` | Demo-Vertrag, Runtime, Wiederholung, Cleanup, Versionsmatrix und Präsentationsabgleich |
| `TP-PERF` | `TP-RUN`, `TST-008` | zusätzlich relationale Performanceerwartung, Bandbreiten und Abbruchbedingungen |
| `TP-CON` | `TP-RUN`, `TST-007`, `TST-008` | zusätzlich deterministische Multi-Session-Steuerung und Concurrency-Cleanup |
| `TP-REFINE` | `W2-007`, `TST-001`, `TST-010` | historisches Abschlussprofil für sichtbare Aussage, Notes, Quellen, Versionsgrenze und Renderprüfung |

## 3. Vollständige Zuordnung

| Claim | Folie | Aussagekern | Curriculum | Pfad | Quellen | Kanonische Demo | Testprofil | Entscheidung |
|---|---:|---|---|---|---|---|---|---|
| `CLM-001` | 1 | fachlicher Rahmen des Grundlagenkurses | `LO-M00-01` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-002` | 2 | vor Änderung beobachten und messen | `LO-M00-02` | KERN | `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-003` | 3 | Performance mehrdimensional bewerten | `LO-M00-01` | KERN | `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-004` | 4 | Diagnosezyklus konsequent anwenden | `LO-M00-02` | KERN | `SRC-027`, `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-005` | 5 | Evidenzquellen nach Fragestellung auswählen | `LO-M00-03` | KERN | `SRC-027`, `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-006` | 6 | Version, Compatibility Level und Konfiguration trennen | `LO-M00-04` | KERN | `SRC-007`, `SRC-025`, `SRC-026` | – | `TP-DOC` | KEEP |
| `CLM-007` | 7 | Storage-Modul einordnen | `LO-M01-01..05` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-008` | 8 | Data Files und Log besitzen verschiedene Rollen | `LO-M01-01` | KERN | `SRC-003`, `SRC-033` | `STL-005` | `TP-PERF` | KEEP |
| `CLM-009` | 9 | Filegroups garantieren keinen Performancegewinn | `LO-M01-01` | KERN | `SRC-003` | – | `TP-DOC` | KEEP |
| `CLM-010` | 10 | Pages und Extents erklären Zugriffseinheiten | `LO-M01-02` | KERN | `SRC-002` | `STL-004` | `TP-RUN` | KEEP |
| `CLM-011` | 11 | Row Layout begrenzt nutzbaren Page-Platz | `LO-M01-02` | KERN | `SRC-002` | – | `TP-DOC` | KEEP |
| `CLM-012` | 12 | Row Width beeinflusst Page-Anzahl und Reads | `LO-M01-02` | KERN | `SRC-002` | `STL-001` | `TP-RUN` | KEEP |
| `CLM-013` | 13 | Allocation Units trennen Speicherbereiche | `LO-M01-03` | VERTIEFUNG | `SRC-002`, `SRC-019` | – | `TP-DOC` | KEEP |
| `CLM-014` | 14 | Buffer Pool macht Logical Reads zentral | `LO-M01-04` | KERN | `SRC-001` | `STL-006` | `TP-PERF` | KEEP |
| `CLM-015` | 15 | Logical und Physical Reads getrennt deuten | `LO-M01-04` | KERN | `SRC-001` | `STL-006` | `TP-PERF` | KEEP |
| `CLM-016` | 16 | WAL, Log Flush und Checkpoint unterscheiden | `LO-M01-05` | KERN | `SRC-033` | `STL-007` | `TP-RUN` | KEEP |
| `CLM-017` | 17 | Autogrowth ist keine Kapazitätsplanung | `LO-M01-05` | KERN | `SRC-003`, `SRC-034` | – | `TP-DOC` | KEEP |
| `CLM-018` | 18 | Storage-Wissen auf einen Planfall übertragen | `LO-M01-01..05` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-019` | 19 | Query-Processing-Modul einordnen | `LO-M02-01..07` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-020` | 20 | Query-Phasen unterscheiden | `LO-M02-01` | KERN | `SRC-001` | – | `TP-DOC` | KEEP |
| `CLM-021` | 21 | Optimierung ist kostenbasiert und zeitbegrenzt | `LO-M02-01` | KERN | `SRC-001` | – | `TP-DOC` | KEEP |
| `CLM-022` | 22 | Kardinalität treibt Planentscheidungen | `LO-M02-02` | KERN | `SRC-001`, `SRC-006` | `OPT-001` | `TP-RUN` | KEEP |
| `CLM-023` | 23 | Statistiken beschreiben Verteilung begrenzt | `LO-M02-02` | KERN | `SRC-005` | `OPT-002` | `TP-RUN` | KEEP |
| `CLM-024` | 24 | Histogramm und Density liefern andere Evidenz | `LO-M02-02` | KERN | `SRC-005`, `SRC-006` | `OPT-002` | `TP-RUN` | KEEP |
| `CLM-025` | 25 | vertrauenswürdige Constraints liefern Optimizerwissen | `LO-M02-02` | KERN | `SRC-001` | – | `TP-DOC` | KEEP |
| `CLM-026` | 26 | Estimated/Actual-Abweichung ist kein Ursachenbeweis | `LO-M02-03` | KERN | `SRC-031`, `SRC-005` | `OPT-001` | `TP-RUN` | KEEP |
| `CLM-027` | 27 | Plan entlang Datenfluss und Laufzeit lesen | `LO-M02-03` | KERN | `SRC-031` | `OPT-001` | `TP-RUN` | KEEP |
| `CLM-028` | 28 | Joinwahl folgt Eingabe- und Kostenprofil | `LO-M02-04` | KERN | `SRC-001`, `SRC-007` | `OPT-012` | `TP-RUN` | KEEP |
| `CLM-029` | 29 | Grants koppeln Plan und Concurrency | `LO-M02-05` | VERTIEFUNG | `SRC-009`, `SRC-010` | `OPT-014` | `TP-PERF` | KEEP |
| `CLM-030` | 30 | Spill belegt unzureichenden nutzbaren Workspace | `LO-M02-05` | VERTIEFUNG | `SRC-009`, `SRC-029`, `SRC-031` | `OPT-013` | `TP-PERF` | KEEP |
| `CLM-031` | 31 | Parallelität garantiert keine gleichmäßige Arbeit | `LO-M02-06` | VERTIEFUNG | `SRC-001` | `RES-002` | `TP-PERF` | KEEP |
| `CLM-032` | 32 | Cache-Schlüssel, zusätzliche Einträge und Planinvalidierung getrennt diagnostizieren | `LO-M02-07` | VERTIEFUNG | `SRC-001`, `SRC-027` | `OPT-007` | `TP-PERF` | KEEP |
| `CLM-033` | 33 | Parameter Sensitivity folgt Datenverteilung | `LO-M02-07` | VERTIEFUNG | `SRC-007` | `OPT-008` | `TP-RUN` | KEEP |
| `CLM-034` | 34 | IQP-Version, CL, Konfiguration, Query Store und Eligibility gemeinsam prüfen | `LO-M02-07` | VERTIEFUNG | `SRC-007`, `SRC-008`, `SRC-009`, `SRC-026` | – | `TP-DOC` | KEEP |
| `CLM-035` | 35 | Query-Processing-Evidenz konsolidieren | `LO-M02-01..07` | KERN + VERTIEFUNG | – | – | `TP-DOC` | KEEP |
| `CLM-036` | 36 | Query-Patterns-Modul einordnen | `LO-M03-01..06` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-037` | 37 | SARGability hält Suchargument verfügbar | `LO-M03-01` | KERN | `SRC-012` | `QRY-001` | `TP-RUN` | KEEP |
| `CLM-038` | 38 | Conversion auf Indexseite kann Zugriff beeinträchtigen | `LO-M03-01` | KERN | `SRC-030`, `SRC-031` | `QRY-002` | `TP-RUN` | KEEP |
| `CLM-039` | 39 | halboffene Zeitintervalle vermeiden Randfehler | `LO-M03-02` | KERN | `SRC-012` | `QRY-003` | `TP-RUN` | KEEP |
| `CLM-040` | 40 | optionale Parameter benötigen Verteilungsstrategie | `LO-M03-03` | VERTIEFUNG | `SRC-026` | `QRY-004` | `TP-RUN` | KEEP |
| `CLM-041` | 41 | CTE garantiert keine Materialisierung | `LO-M03-04` | KERN | `SRC-011`, `SRC-001` | `QRY-008` | `TP-RUN` | KEEP |
| `CLM-042` | 42 | Temp Table, Table Variable Deferred Compilation, Statistiken und Planwiederverwendung differenziert bewerten | `LO-M03-04` | KERN | `SRC-007`, `SRC-008` | `QRY-008` | `TP-RUN` | KEEP |
| `CLM-043` | 43 | Inline TVF, MSTVF Interleaved Execution und Scalar UDF Inlining nach Eligibility und Plan unterscheiden | `LO-M03-04` | KERN | `SRC-007`, `SRC-008` | `QRY-009` | `TP-RUN` | KEEP |
| `CLM-044` | 44 | Partition Elimination muss ableitbar sein | `LO-M03-05` | VERTIEFUNG | `SRC-018` | `QRY-012` | `TP-PERF` | KEEP |
| `CLM-045` | 45 | Remote Pushdown ist provider- und planabhängig | `LO-M03-05` | VERTIEFUNG | `SRC-020`, `SRC-021`, `SRC-022` | `QRY-012` | `TP-PERF` | KEEP |
| `CLM-046` | 46 | Datenmodell und Datentyp begrenzen Optimierung | `LO-M03-02` | KERN | `SRC-002`, `SRC-005`, `SRC-030` | – | `TP-DOC` | KEEP |
| `CLM-047` | 47 | Query-Rewrite über Plan und Messung prüfen | `LO-M03-06` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-048` | 48 | Indexmodul einordnen | `LO-M04-01..07` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-049` | 49 | Heap und Clustered Index sind alternative Basen | `LO-M04-01` | KERN | `SRC-012`, `SRC-013` | `IDX-001` | `TP-RUN` | KEEP |
| `CLM-050` | 50 | B+-Tree ermöglicht Suchnavigation | `LO-M04-01` | KERN | `SRC-012` | – | `TP-DOC` | KEEP |
| `CLM-051` | 51 | Row Locator bestimmt Lookup-Form und -Kosten | `LO-M04-01` | KERN | `SRC-012`, `SRC-013` | `IDX-001` | `TP-RUN` | KEEP |
| `CLM-052` | 52 | Key-Reihenfolge folgt Zugriff und Ordnung | `LO-M04-02` | KERN | `SRC-012` | `IDX-003` | `TP-RUN` | KEEP |
| `CLM-053` | 53 | INCLUDE und Filter lösen verschiedene Aufgaben | `LO-M04-02` | KERN | `SRC-012` | `IDX-003` | `TP-RUN` | KEEP |
| `CLM-054` | 54 | Lookup-Tipping-Point ist workloadabhängig | `LO-M04-03` | KERN | `SRC-001`, `SRC-012` | `IDX-004` | `TP-RUN` | KEEP |
| `CLM-055` | 55 | Clustering-Key-Breite vervielfacht Folgekosten | `LO-M04-03` | KERN | `SRC-012` | – | `TP-DOC` | KEEP |
| `CLM-056` | 56 | Indexdesign bilanziert Read- und Betriebskosten | `LO-M04-04` | KERN | `SRC-012`, `SRC-032` | – | `TP-DOC` | KEEP |
| `CLM-057` | 57 | Split, Fragmentation und Density sind verschieden | `LO-M04-05` | VERTIEFUNG | `SRC-014`, `SRC-015` | `IDX-006` | `TP-PERF` | KEEP |
| `CLM-058` | 58 | Maintenance benötigt Messziel und Wirkungskontrolle | `LO-M04-05` | VERTIEFUNG | `SRC-015` | `IDX-006` | `TP-PERF` | KEEP |
| `CLM-059` | 59 | Columnstore organisiert Rowgroups und Segmente | `LO-M04-06` | VERTIEFUNG | `SRC-016` | `IDX-009` | `TP-PERF` | KEEP |
| `CLM-060` | 60 | Batch Mode und Segment Elimination reduzieren unterschiedliche Arbeit | `LO-M04-06` | VERTIEFUNG | `SRC-007`, `SRC-016`, `SRC-017` | `IDX-010` | `TP-PERF` | KEEP |
| `CLM-061` | 61 | Rowgroup-Qualität steuert Diagnose und Maintenance | `LO-M04-07` | VERTIEFUNG | `SRC-015`, `SRC-016`, `SRC-017` | `IDX-010` | `TP-PERF` | KEEP |
| `CLM-062` | 62 | Indexentscheidung als Workloadrechnung festigen | `LO-M04-01..07` | KERN + VERTIEFUNG | – | – | `TP-DOC` | KEEP |
| `CLM-063` | 63 | Concurrency-Modul einordnen | `LO-M05-01..05` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-064` | 64 | Isolation Levels steuern Sicht und Konflikte | `LO-M05-01` | KERN | `SRC-004` | `CON-003` | `TP-CON` | KEEP |
| `CLM-065` | 65 | Locking und Versioning verschieben Kosten | `LO-M05-01` | KERN | `SRC-004`, `SRC-029` | `CON-003` | `TP-CON` | KEEP |
| `CLM-066` | 66 | Blocking vom Head Blocker aus analysieren | `LO-M05-02` | KERN | `SRC-036` | `CON-004` | `TP-CON` | KEEP |
| `CLM-067` | 67 | Blocking-Kette und Deadlock-Zyklus unterscheiden | `LO-M05-03` | KERN | `SRC-004` | `CON-006` | `TP-CON` | KEEP |
| `CLM-068` | 68 | TempDB trägt mehrere Kostenklassen | `LO-M05-04` | VERTIEFUNG | `SRC-029`, `SRC-004` | `CON-009` | `TP-CON` | KEEP |
| `CLM-069` | 69 | Optimized Locking benötigt klare Voraussetzungen | `LO-M05-05` | VERTIEFUNG | `SRC-025` | `CON-008` | `TP-CON` | KEEP |
| `CLM-070` | 70 | Isolation und Blocking ohne `NOLOCK`-Pauschale festigen | `LO-M05-01..05` | KERN + VERTIEFUNG | – | – | `TP-DOC` | KEEP |
| `CLM-071` | 71 | Diagnosemodul einordnen | `LO-M06-01..06` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-072` | 72 | CPU und CPU-bezogene Waits sind andere Signale | `LO-M06-01` | KERN | `SRC-028`, `SRC-035` | `RES-001` | `TP-PERF` | KEEP |
| `CLM-073` | 73 | kumulative und aktuelle Waits haben anderen Scope | `LO-M06-01` | KERN | `SRC-035`, `SRC-036` | `RES-007` | `TP-PERF` | KEEP |
| `CLM-074` | 74 | RESOURCE_SEMAPHORE belegt Grant-Warten | `LO-M06-02` | VERTIEFUNG | `SRC-010`, `SRC-035` | `RES-003` | `TP-PERF` | KEEP |
| `CLM-075` | 75 | Wait-Kategorien sind Hypothesenstart | `LO-M06-03` | KERN | `SRC-035`, `SRC-036` | – | `TP-DOC` | KEEP |
| `CLM-076` | 76 | Query Store liefert Plan- und Laufzeithistorie | `LO-M06-04` | KERN | `SRC-027` | `DGN-003` | `TP-RUN` | KEEP |
| `CLM-077` | 77 | Extended Events und DMVs ergänzen einander | `LO-M06-04` | KERN | `SRC-027`, `SRC-028` | `DGN-005` | `TP-CON` | KEEP |
| `CLM-078` | 78 | Outside-in verbindet Nutzerzeit bis Operatorursache | `LO-M06-05` | KERN | `SRC-027`, `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-079` | 79 | Vorher/Nachher benötigt vergleichbare Bedingungen | `LO-M06-06` | KERN | `SRC-027`, `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-080` | 80 | Diagnose folgt der fehlenden Zeit | `LO-M06-06` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-081` | 81 | Diagnoseprinzipien zu Arbeitsmethode verdichten | `LO-M07-01` | KERN | `SRC-027`, `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-082` | 82 | nächste Messung aus fehlender Evidenz ableiten | `LO-M07-02` | KERN | – | – | `TP-DOC` | KEEP |
| `CLM-083` | 83 | Quelle, Version und Empirie getrennt verfolgen | `LO-M07-03` | KERN | `SRC-007`, `SRC-028` | – | `TP-DOC` | KEEP |
| `CLM-084` | 84 | Transferauftrag und fachlicher Abschluss | `LO-M07-03` | KERN | – | – | `TP-DOC` | KEEP |

## 4. Konsolidierung der Demo-IDs

Die bisherigen 35 vorläufigen Kennungen `DEM-*` werden nicht zu stabilen IDs. Die Zuordnung verwendet ausschließlich die im Master-Umsetzungsplan festgelegten Präfixe `STL`, `OPT`, `QRY`, `IDX`, `CON`, `RES` und `DGN`.

Die frühere Sammelkennung `DEM-STO-01` deckte sowohl Files/Log als auch Pages/Extents ab. Sie wird deshalb fachlich in `STL-005` für Files/Filegroups und `STL-004` für Allocation/Extents getrennt. Dadurch entstehen aus 35 vorläufigen Kennungen 36 eindeutige kanonische Demo-Bündel. Die Zahl der Folien mit Demo-Zuordnung bleibt 47.

## 5. Abnahme

- Alle 84 Claims sind genau einer aktiven Folie und mindestens einem Lernziel zugeordnet.
- Alle referenzierten Quellen-IDs stammen aus dem Primärquellenregister.
- Alle 47 Demo-Zuordnungen verwenden bestehende IDs des Masterplans.
- Alle Claims besitzen ein Testprofil; Runtime-Profile bleiben bis zur Implementierung der Demos `PLANNED`.
- Die vier früheren `REFINE`-Claims sind durch `W2-007` abgeschlossen und besitzen die Entscheidung `KEEP`; das historische Profil `TP-REFINE` bleibt als Abnahmenachweis dokumentiert.
- Runtime- oder Versionsprüfungen werden nur dort als bestanden bezeichnet, wo ein separates Review oder ein validierter Workflowlauf dies belegt; `W2-007` ist eine Präsentations- und Quellenabnahme.
