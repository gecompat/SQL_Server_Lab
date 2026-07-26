# Analysehandbuch für SQL_Server_Analyze

**Stand:** 23. Juli 2026
**Geltungsbereich:** 97 öffentliche Procedures
**Zielgruppe:** Analyseanfänger, Datenbankentwickler und SQL-Server-Administratoren

## Empfohlener Einstieg

1. Wählen Sie unter [Hier beginnen](Start_Here.md) das beobachtete Symptom oder Ziel aus.
2. Suchen Sie alternativ im installierten Framework mit `USP_AnalysisNavigator` nach deutschen oder englischen Begriffen.
3. Lesen Sie die vorgeschlagene [eigenständige Procedure-Seite](Procedures/README.md).
4. Prüfen Sie die Parameter anhand der [Parameter-Lesehilfe](Parameter_Reading_Guide.md) und `@Hilfe=1`.
5. Lesen Sie Status und Resultsets nach dem [Einsteiger-Leseleitfaden](Beginner_Reading_Guide.md).
6. Wechseln Sie für vollständige technische Zusammenhänge in den verlinkten Bereichsleitfaden.

Das gemeinsame [Execution-, Zeit- und Evidenzmodell](Technical_Foundations.md) gilt für alle Procedure-Seiten.

Alle 97 Procedure-Seiten sind strukturell vollständig. 91 Seiten besitzen den tief geprüften Status `DEEP_REVIEWED`; die zwei eigenständig installierbaren PLAN-001-, drei optionalen SC-023- und die SQL25-001-Seite stehen auf `BASELINE`. [USP_CurrentRequests](Procedures/USP_CurrentRequests.md), [USP_IndexPhysicalStats](Procedures/USP_IndexPhysicalStats.md), [USP_ExtendedEventsReadEvents](Procedures/USP_ExtendedEventsReadEvents.md) und [USP_AnalysisNavigator](Procedures/USP_AnalysisNavigator.md) zeigen die unterschiedlichen Verträge von Live-Snapshot, physischem Scan, Datei-/XML-Analyse und reiner Metadatennavigation.

## Feste Leserichtung

1. Status und Vollständigkeit,
2. Scope und Zeilengranularität,
3. Zeitbezug, Reset oder Retention,
4. Nenner und Datenmenge,
5. Kombination zusammengehöriger Werte,
6. technische Ursachehypothese,
7. Auswirkung und Gegenbeispiel,
8. zweite unabhängige Evidenzquelle,
9. erst danach Änderung und Rollback planen.

## Dokumente

| Zweck | Dokument |
|---|---|
| Einstieg nach Symptom oder Ziel | [Start_Here.md](Start_Here.md) |
| Navigator-Suche und Metadatenvertrag | [Analysis_Navigator.md](../Reference/Analysis_Navigator.md) |
| Direkte Seite je Procedure | [Procedures/README.md](Procedures/README.md) |
| Symptomorientierte Abläufe | [Runbooks/README.md](Runbooks/README.md) |
| Begriffserklärungen | [Glossary.md](Glossary.md) |
| Parameter und sichere Aufrufe | [Parameter_Reading_Guide.md](Parameter_Reading_Guide.md) |
| Gemeinsame Verträge | [Common_Contracts.md](Common_Contracts.md) |
| Technische Grundlagen einschließlich Kostenmodell | [Technical_Foundations.md](Technical_Foundations.md) |
| Versions- und Primärquellennachweis | [Version_Primary_Source_Matrix.md](Version_Primary_Source_Matrix.md) |
| Vollständiger Objektindex | [Object_Index.md](Object_Index.md) |
| Vollständige Komponentenreferenz | [Object_Reference.md](../Reference/Object_Reference.md) |

## Bereichsleitfäden

| Bereich | Dokument | Procedures |
|---|---|---:|
| Common und Navigation | [01_Common.md](01_Common.md) | 5 |
| Current State | [02_Current_State.md](02_Current_State.md) | 11 |
| Object und Index | [03_Object_Index.md](03_Object_Index.md) | 12 |
| Plan Cache | [04_Plan_Cache.md](04_Plan_Cache.md) | 8 |
| Query Store | [05_Query_Store.md](05_Query_Store.md) | 9 |
| Extended Events | [06_Extended_Events.md](06_Extended_Events.md) | 6 |
| Infrastruktur | [07_Infrastructure.md](07_Infrastructure.md) | 13 |
| Server Health | [08_Server_Health.md](08_Server_Health.md) | 19 |
| Versionsadaptive Spezialanalysen | [09_Version_Adaptive.md](09_Version_Adaptive.md) | 11 |
| **Integriertes Framework gesamt** | | **93** |

Die zwei PLAN-001-Procedures sind zusätzlich eigenständig installierbar, gehören aber auch zum Gesamtinstaller. Die drei SC-023-Procedures bleiben vollständig optional und außerhalb von `Install_All.sql`; beide Pakete besitzen separate Architektur- und Betriebshandbücher. Der vollständige Dokumentationsbestand umfasst damit 97 Procedures.

## Schnellwahl nach Symptom

| Symptom | Erster Aufruf | Runbook |
|---|---|---|
| Hänger/Blocking | `USP_CurrentBlocking` | [Blocking](Runbooks/01_User_Hangs_Blocking.md) |
| CPU hoch | `USP_CurrentRequests`, `USP_QueryStats` | [High CPU](Runbooks/02_High_CPU.md) |
| Query plötzlich langsamer | `USP_QueryStoreRegressions` | [Regression](Runbooks/03_Query_Regression.md) |
| TempDB wächst | `USP_CurrentTempDB` | [TempDB](Runbooks/04_TempDB_Growth.md) |
| Log läuft voll | `USP_CurrentLog` | [Transaction Log](Runbooks/05_Transaction_Log_Full.md) |
| Grants warten | `USP_CurrentMemoryGrants` | [Memory Grants](Runbooks/06_Memory_Grant_Queue.md) |
| I/O-Latenz | `USP_CurrentIO` | [I/O](Runbooks/07_IO_Latency.md) |
| Index ungenutzt | `USP_IndexUsage` | [Unused Index](Runbooks/08_Unused_Index.md) |
| Backup/Integrität | `USP_DatabaseIntegrityAnalysis` | [Backup/Integrity](Runbooks/09_Backup_Integrity_Risk.md) |
| AG-Lag | `USP_AvailabilityDeepAnalysis` | [AG Lag](Runbooks/10_Availability_Group_Lag.md) |

## Evidenzarten

- Live-Momentaufnahme: flüchtiger aktueller Zustand.
- Stichprobe/Delta: Veränderung innerhalb eines Intervalls.
- kumulative DMV: seit Reset oder Cachelebensdauer.
- persistierte Historie: abhängig von Capture und Retention.
- Ereignishistorie: nur konfigurierte und noch vorhandene XE-Daten.
- Katalog/Konfiguration: sichtbarer Berechtigungs- und Plattformscope.

## Grundsatz für Änderungen

Kein einzelnes Resultset rechtfertigt automatisch `KILL`, DDL, Rebuild, Plan Forcing, Konfigurationsänderung, Failover oder Repair. Zweite Evidenzquelle, Auswirkung, Risiko und Rollbackweg sind vorher zu bestimmen.

## Vollständigkeit

Der [Objektindex](Object_Index.md) enthält alle 97 öffentlichen Procedures. Die [Objektreferenz](../Reference/Object_Reference.md) dokumentiert zusätzlich alle 67 unterstützenden Views, TVFs, internen Procedures und Tabellen. Der [Navigator-Vertrag](../Reference/Analysis_Navigator.md) erklärt die fachliche Zuordnung, Suchbegriffe, Rollen und Beziehungen.
