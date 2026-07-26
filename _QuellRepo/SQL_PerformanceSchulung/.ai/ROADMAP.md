# Roadmap

## Welle 0 - Fachliche Konsolidierung

Bestehende Schulungsaussagen inventarisieren und als beibehalten, präzisieren, ersetzen oder entfernen klassifizieren. Besonders zu prüfen sind CTE-Materialisierung, Table Variables, Fill Factor, Partition-Metadaten, RCSI/SNAPSHOT, Columnstore-Versionen, Cardinality Estimation, Filegroups und Memory Grants.

## Welle 1 - Gemeinsames Demo-Framework

Demo-Vertrag, Sicherheitsstufen, Preflight, synthetische Testdatenbanken und Datengeneratoren, Messhelfer, Benennung und Cleanup-Konventionen implementieren. T-SQL bleibt der Standardpfad.

## Welle 2 - Vorhandene Beispiele modernisieren

Bestehende Beispiele fachlich prüfen, interne Abhängigkeiten entfernen, synthetische Daten ergänzen und nach dem Demo-Vertrag strukturieren.

## Welle 3 - Storage, Pages und Transaktionslog

Pages, Row Layout, Row Overflow, LOB, Heaps, Forwarded Records, Allocation, Files/Filegroups, Buffer Pool, Transaction Log, VLF, WRITELOG und Kompression.

## Welle 4 - Optimizer, Statistiken und Execution Plans

Estimated/Actual Plans, Histogramme, Density, Sampling, Skew, Korrelation, Ascending Key, Statistikpflege, Cardinality Estimation, Compile/Recompile, Plan Reuse, Parameter Sniffing, PSP, OPPO, Row Goals, Joins, Spills und Memory Grants.

## Welle 5 - Query Patterns

SARGability, Implicit Conversion, Datumsintervalle, optionale Parameter, dynamisches SQL, UNION ALL, NULL-Semantik, Semi/Anti Joins, DISTINCT, CTE/Temp Table/Table Variable, TVFs, Scalar UDFs, APPLY, Window Functions, set-based Verarbeitung und Partition Elimination.

## Welle 6 - Rowstore und Columnstore

Heap/Clustered, Schlüsselbreite, Uniquifier, Key-Reihenfolge, INCLUDE, Covering, Lookups, Tipping Point, Indexüberlappung, DML-Kosten, Page Splits, Page Density, Fill Factor, Sequential-Key-Insert, Kompression, Rowgroups und Segment Elimination.

## Welle 7 - Concurrency, Isolation und TempDB

Isolationseffekte, RCSI, SNAPSHOT, Blocking Chains, Lock Escalation, Deadlocks, Schema Locks, Version Store, ADR, Optimized Locking, TempDB Allocation Contention und Memory-optimized TempDB Metadata.

## Welle 8 - CPU, Memory, I/O und Waits

Scheduler, Parallelism Overhead, Parallel Skew, SOS_SCHEDULER_YIELD, RESOURCE_SEMAPHORE, Over-/Undergrant, PAGEIOLATCH, PAGELATCH, WRITELOG, Wait-Deltas, Dateilatenz und ASYNC_NETWORK_IO.

## Welle 9 - Diagnosewerkzeuge

STATISTICS IO/TIME, Execution Plans, Live Query Statistics, Plan XML, DMVs, Query Store, Extended Events, Betriebssystemmetriken und reproduzierbare Workload-Treiber.

## Welle 10 - Testumgebungs-How-to und notwendige Sonderinfrastruktur

Ein kompakter Bereitstellungspfad ermöglicht die Ausführung der T-SQL-Beispiele, wenn kein SQL Server verfügbar ist. CPU-/RAM-Limits, gedrosseltes I/O, Netzwerkbegrenzung, Mehrinstanz- oder Windows-Szenarien werden nur für Demos umgesetzt, deren Kernaussage mit T-SQL und einer normalen Testdatenbank nicht belastbar gezeigt werden kann.

## Abschlusskriterien

- Zuordnung jeder Demo zu Curriculum und Präsentationsabschnitt.
- Datenschutz- und Quellenprüfung.
- Statische Vertragsprüfung.
- Laufzeittest in der zutreffenden Matrix SQL Server 2019/2022/2025.
- Fachliches Review der Erklärung und der erwarteten Evidenz.
- T-SQL/Testdatenbank als Standardpfad; jede zusätzliche Infrastrukturabhängigkeit ist begründet.
