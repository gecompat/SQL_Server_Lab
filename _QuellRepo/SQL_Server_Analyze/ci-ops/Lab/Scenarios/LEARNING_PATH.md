# Lernpfad: Lab-Szenarien als geführte Exploration

**Stand:** 25. Juli 2026

Die Lab-Szenarien erzeugen reproduzierbare, synthetische SQL-Server-Zustände.
Jedes Szenario simuliert ein diagnostisches Problem und zeigt, wie die
entsprechenden Framework-Procedures es sichtbar machen. Dieser Leitfaden
ordnet die Szenarien nach Lernfortschritt.

## Voraussetzungen

- Lokales Docker/Podman mit SQL Server 2019, 2022 oder 2025.
- Installiertes Framework in einer synthetischen Testdatenbank.
- PowerShell 7 für die Lab-Orchestrierung.
- Empfohlen: [Beginner Reading Guide](../../Documentation/Analysis_Guides/Beginner_Reading_Guide.md) vorher lesen.

## Stufe 1: Grundlagen (Einsteiger)

Diese Szenarien erfordern kein Vorwissen über SQL Server Internals und
vermitteln die grundlegende Arbeitsweise des Frameworks.

| Reihenfolge | Szenario | Thema | Lernziel |
|---|---|---|---|
| 1 | LAB-BASE-001 | Baseline und Installation | Framework installieren, ersten Aufruf ausführen, Resultset-Status lesen |
| 2 | LAB-BASE-002 | Mehrere Datenbanken | Datenbankfilter verstehen, Scope begrenzen |
| 3 | LAB-CPU-001 | Einfache CPU-Last | `USP_CurrentRequests` lesen, aktive Queries identifizieren |
| 4 | LAB-CONC-001 | Blocking erzeugen | `USP_CurrentBlocking` verstehen, Blocking-Chain lesen |
| 5 | LAB-TEMP-001 | TempDB-Nutzung | `USP_CurrentTempDB` aufrufen, Verbraucher identifizieren |

**Nach Stufe 1 beherrscht man:** Resultsets lesen, Status interpretieren,
aktive Probleme erkennen, Scope begrenzen.

## Stufe 2: Diagnose (Fortgeschrittene)

Diese Szenarien setzen Grundverständnis von Sessions, Waits und Locking voraus.

| Reihenfolge | Szenario | Thema | Lernziel |
|---|---|---|---|
| 6 | LAB-CONC-002 | Komplexes Blocking | Blocking-Trees, Root Blocker, offene Transaktionen |
| 7 | LAB-MEM-001 | Memory Grant Queue | `USP_CurrentMemoryGrants`, Resource Semaphore, Wartezeit |
| 8 | LAB-MEM-002 | Überdimensionierte Grants | Grant vs. tatsächliche Nutzung, Planschätzfehler |
| 9 | LAB-LOG-001 | Transaction Log voll | `USP_CurrentLog`, Logursache, Backup-Bedarf |
| 10 | LAB-LATCH-001 | Page Latch Contention | `USP_InternalContentionAnalysis`, Hot Pages |
| 11 | LAB-IO-004 | I/O-Latenz | `USP_CurrentIO`, Datei-Latenz interpretieren |
| 12 | LAB-IDX-001 | Ungenutzte Indizes | `USP_IndexUsage`, Beobachtungsfenster beachten |

**Nach Stufe 2 beherrscht man:** Symptome von Ursachen trennen, mehrere
Procedures kombinieren, kumulative Zähler interpretieren.

## Stufe 3: Plan- und Query-Analyse (Fortgeschrittene+)

Diese Szenarien erfordern Grundverständnis von Ausführungsplänen.

| Reihenfolge | Szenario | Thema | Lernziel |
|---|---|---|---|
| 13 | LAB-PLAN-001 | Plan Cache Basics | `USP_QueryStats`, Top-Queries identifizieren |
| 14 | LAB-PLAN-002 | Parametersniffing | Gleiche Query, verschiedene Pläne, unterschiedliche Laufzeit |
| 15 | LAB-PLAN-003 | Plan-Cache-Analyse | `USP_PlanCacheAnalysis`, Planattribute lesen |
| 16 | LAB-PLAN-004 | Showplan-Warnings | Spills, Implicit Conversions, Missing Stats |
| 17 | LAB-QS-001 | Query Store Regressions | Regressionserkennung, Zeitraumvergleich |
| 18 | LAB-QS-002 | Plan Changes | Planwechsel im Query Store identifizieren |
| 19 | LAB-EXECPLAN-001 | Execution Plan Deep | XML-Plan analysieren, Operatoren verstehen |

**Nach Stufe 3 beherrscht man:** Planprobleme erkennen, Query Store
für Regressionserkennung nutzen, Showplan-Attribute interpretieren.

## Stufe 4: Infrastruktur und Spezialfälle (Spezialisten)

Diese Szenarien erfordern Wissen über SQL Server Administration.

| Reihenfolge | Szenario | Thema | Lernziel |
|---|---|---|---|
| 20 | LAB-DEAD-001 | Key Deadlock | Extended Events Deadlocks lesen, Ursache bestimmen |
| 21 | LAB-DEAD-002 | Conversion Deadlock | Locktypen unterscheiden, Update Lock verstehen |
| 22 | LAB-DEAD-003 | Cascading Deadlock | Mehrparteien-Deadlock, Foreign Key Auswirkung |
| 23 | LAB-DEAD-004 | Parallelism Deadlock | Intra-Query-Parallelismus als Deadlock-Ursache |
| 24 | LAB-LATCH-002 | Last Page Insert | Identity-Column Hotspot, Partitionierung als Lösung |
| 25 | LAB-LATCH-003 | Allocation Contention | GAM/SGAM/PFS Contention, TempDB-Konfiguration |
| 26 | LAB-TEMP-002 | TempDB Contention | Allocationsengpass vs. Benutzerobjektlast |
| 27 | LAB-TEMP-003 | Version Store | Snapshot Isolation, Version Store Wachstum |
| 28 | LAB-CPU-002 | Parallelism | CXPACKET/CXCONSUMER verstehen, DOP-Auswirkung |
| 29 | LAB-CPU-003 | Spinlock | Spinlock-Contention erkennen und einordnen |
| 30 | LAB-LS-001 | Log Shipping | `USP_LogShippingAnalysis`, Restore-Lag diagnostizieren |
| 31 | LAB-XE-001 | Extended Events | XE-Sessions inventarisieren, Targets lesen |

**Nach Stufe 4 beherrscht man:** Komplexe Blocking-/Deadlock-Szenarien,
Infrastrukturdiagnose, Low-Level-Contention.

## Stufe 5: Erweitert (SQL Server 2025 Features)

| Reihenfolge | Szenario | Thema | Lernziel |
|---|---|---|---|
| 32 | LAB-TEMP-005 | TempDB Resource Governance | SQL 2025 Workload-Group-Limits |
| 33 | LAB-VERSION-001 | Versionsadaptive Features | Capability-Erkennung, Build-/Lifecycle-Katalog |
| 34 | LAB-VECTOR-001 | Vector Index (2025) | JSON-/Vector-Index-Metadaten lesen |
| 35 | LAB-PLAN-005 | Adaptive Query Processing | IQP-Features erkennen und bewerten |
| 36 | LAB-MEM-003 | Resource Governor Pools | Memory-Pool-Konfiguration und -Grenzen |
| 37 | LAB-IDX-002 | Resumable Index Operations | Online-/Resumable-Zustand diagnostizieren |
| 38 | LAB-IDX-003 | JSON-Index (2025) | JSON-Pfad-Metadaten inventarisieren |
| 39 | LAB-REC-001 | Accelerated Recovery | Persistent Version Store, Recovery-Zustand |

## Empfohlene Leserichtung pro Szenario

1. `scenario.json` lesen: Zweck, Plattform, erwartete Findings verstehen.
2. Arrange-Phase: Synthetische Objekte und Daten werden erstellt.
3. Act-Phase: Workload läuft – beobachten Sie das Problem live mit `USP_CurrentRequests`.
4. Observe-Phase: Die genannten Analyzer-Procedures aufrufen.
5. Expected Findings: Vergleichen Sie Ihr Ergebnis mit der Erwartung.
6. `runbook.json` lesen: Welche Gegenprobe, welcher nächster Schritt.
7. Cleanup: Synthetische Objekte werden entfernt.

## Querverbindungen zur Dokumentation

| Stufe | Begleitende Dokumentation |
|---|---|
| 1 | [Start_Here.md](../../Documentation/Analysis_Guides/Start_Here.md), [Beginner_Reading_Guide.md](../../Documentation/Analysis_Guides/Beginner_Reading_Guide.md) |
| 2 | [02_Current_State.md](../../Documentation/Analysis_Guides/02_Current_State.md), [Runbooks](../../Documentation/Analysis_Guides/Runbooks/) |
| 3 | [04_Plan_Cache.md](../../Documentation/Analysis_Guides/04_Plan_Cache.md), [05_Query_Store.md](../../Documentation/Analysis_Guides/05_Query_Store.md) |
| 4 | [06_Extended_Events.md](../../Documentation/Analysis_Guides/06_Extended_Events.md), [07_Infrastructure.md](../../Documentation/Analysis_Guides/07_Infrastructure.md) |
| 5 | [09_Version_Adaptive.md](../../Documentation/Analysis_Guides/09_Version_Adaptive.md), Architekturdokumente |

## Hinweise

- Jedes Szenario ist isoliert und zerstört nur seine eigenen synthetischen Objekte.
- Keine realen Daten werden verwendet oder benötigt.
- Die Szenarien sind keine Benchmarks – sie zeigen diagnostische Muster.
- Reihenfolge innerhalb einer Stufe ist eine Empfehlung, keine Pflicht.
- Spätere Stufen setzen das Wissen der früheren voraus.
