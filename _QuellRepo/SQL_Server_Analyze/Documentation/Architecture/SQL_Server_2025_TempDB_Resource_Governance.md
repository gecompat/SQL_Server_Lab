# SQL Server 2025 TempDB Resource Governance

**Status:** `IMPLEMENTED_ACTIONS_GATE`  
**Arbeitsumfang:** `SQL25-003`  
**Öffentliche Procedures:** `[monitor].[USP_CurrentTempDB]` und
`[monitor].[USP_ResourceGovernorAnalysis]`  
**Orchestrator:** `[monitor].[USP_CurrentOverview]` über den gemeinsamen
Current-State-Snapshot

## Ziel

Welle 7 integriert die SQL-Server-2025-TempDB-Governance in vorhandene
Analysewege. Sie trennt für jede sichtbare Workload Group:

- gespeicherte MB- und Prozentkonfiguration;
- das aus der aktiven Konfiguration ableitbare effektive Limit;
- aktuelle und höchste TempDB-Datennutzung;
- Limitverletzungen und deren Statistikfenster;
- Versions-, Schema-, Berechtigungs- und Partialitätsstatus.

Es wurde bewusst keine neue öffentliche Procedure angelegt. Die Analyse liest
keine Benutzertabellenzeilen, Querytexte oder Pläne und persistiert keine
Messwerte.

## Versions- und Quellgrenze

Das Framework bleibt ab SQL Server 2019 installier- und parsbar. Die neuen
Spalten der beiden SQL-Server-2025-Quellen stehen ausschließlich in Dynamic
SQL. Vor jeder Referenz prüft der Produktpfad:

1. `ProductMajorVersion >= 17`;
2. die Existenz des Katalog- beziehungsweise DMV-Objekts;
3. alle Pflichtspalten;
4. die Lesbarkeit im aktuellen Sicherheitskontext.

Die Konfiguration stammt aus `sys.resource_governor_workload_groups`.
Aktuelle Nutzung, Peak, Verletzungszähler und
`statistics_start_time` stammen aus
`sys.dm_resource_governor_workload_groups`. Der aktivierte Zustand und eine
ausstehende Rekonfiguration werden getrennt gelesen. Nur wenn ein
Prozentlimit ohne MB-Limit relevant ist, wird die sichtbare
TempDB-Dateikonfiguration einmal aus `master.sys.master_files` ausgewertet.

Fehlen Version, Pflichtspalten oder Rechte, entsteht kein leerer Erfolg.
`SourceStatusCode`, `IsPartial` und `EvidenceLimit` weisen die Grenze
explizit aus. Ein fehlender Zugriff auf die TempDB-Dateikonfiguration begrenzt
nur Workload Groups mit ausschließlichem Prozentlimit; feste MB-Limits und
Gruppen ohne Limit bleiben auswertbar.

## Effektives Limit

Die Procedure speichert keinen eigenen Grenzwert, sondern leitet ihn für den
Aufruf nachvollziehbar ab:

| `EffectiveLimitSource` | Bedeutung |
|---|---|
| `NO_LIMIT_CONFIGURED` | weder MB- noch Prozentlimit gespeichert; neutraler Zustand |
| `FIXED_MB_EFFECTIVE` | das MB-Limit ist aktiv und hat Vorrang |
| `PERCENT_EFFECTIVE` | ein Prozentlimit ist aus einer geeigneten TempDB-Dateikonfiguration auflösbar |
| `PERCENT_NOT_EFFECTIVE` | Prozentwert gespeichert, Dateikonfiguration liefert aber kein wirksames Maximum |
| `RESOURCE_GOVERNOR_DISABLED` | gespeicherter Wert ist derzeit nicht wirksam |
| `RECONFIGURATION_PENDING` | gespeicherte und aktive Konfiguration können abweichen |
| `UNAVAILABLE` | die notwendige Quelle ist nicht belastbar verfügbar |

Sind MB und Prozent gleichzeitig gespeichert, gewinnt das MB-Limit. Ein
Prozentlimit ist nur wirksam, wenn die TempDB-Datendateien gemeinsam ein nach
dem dokumentierten SQL-Server-Vertrag auflösbares Maximum besitzen.
`EffectiveLimitUtilizationPercent` wird ausschließlich gegen ein tatsächlich
wirksames Limit berechnet.

## Runtime- und Resetsemantik

`TempdbDataSpaceMb` und `PeakTempdbDataSpaceMb` sind
Workload-Group-Werte. Sie sind nicht direkt mit den sessionbezogenen
Allokationszählern aus `tempdb.sys.dm_db_session_space_usage` addierbar.

`TotalTempdbDataLimitViolationCount` zeigt durchgesetzte Grenzverletzungen im
aktuellen Statistikfenster. Ein Wert größer null belegt weder die verursachende
Anweisung noch eine dauerhafte Störung. `StatisticsStartTime` begrenzt Peak
und Verletzungszähler auf den Zeitraum seit Serverstart beziehungsweise seit
`ALTER RESOURCE GOVERNOR RESET STATISTICS`.

Die Governance umfasst TempDB-Datennutzung durch die Workload Group. Version
Store und TempDB-Transaktionslog liegen außerhalb dieses Limits und müssen über
ihre eigenen Resultsets bewertet werden.

## Öffentlicher Ausgabezusatz

Beide Procedures registrieren das identische benannte Resultset
`tempdbGovernance`:

| Feldgruppe | Felder |
|---|---|
| Schlüssel | `GroupId`, `GroupName`, `PoolId`, `PoolName` |
| gespeicherte Konfiguration | `ConfiguredGroupMaxTempdbDataMb`, `ConfiguredGroupMaxTempdbDataPercent` |
| Wirksamkeit | `TempdbMaximumSizeMb`, `EffectiveGroupMaxTempdbDataMb`, `EffectiveLimitSource`, `IsPercentLimitEffective`, `EffectiveLimitUtilizationPercent` |
| Runtime | `TempdbDataSpaceMb`, `PeakTempdbDataSpaceMb`, `TotalTempdbDataLimitViolationCount`, `HasRecordedLimitViolation`, `StatisticsStartTime` |
| Enginezustand | `IsResourceGovernorEnabled`, `ReconfigurationPending` |
| Aussagegrenze | `SourceStatusCode`, `IsPartial`, `EvidenceLimit` |

`USP_CurrentTempDB` stellt daneben weiterhin Session-, Datei-, Space- und
Version-Store-Evidenz bereit. `USP_ResourceGovernorAnalysis` stellt weiterhin
Konfiguration, Pools, Groups und optionale Sessions bereit.
`USP_CurrentOverview @MitTempDB=1` übernimmt das Governance-Resultset aus
dem laufinternen Primär-Snapshot. RAW, CONSOLE, NONE, JSON und benannte
TABLE-Ziele verwenden dieselbe Materialisierung.

## Einmalread- und Sessionvertrag

Jede fachliche Quelle wird je Procedure und Aufruf höchstens einmal
materialisiert. Der gemeinsame Overview-Snapshot liest sie ebenfalls höchstens
einmal und verteilt danach nur lokale Snapshotzeilen an die Children.
`master.sys.master_files` wird überhaupt nur gelesen, wenn mindestens eine
sichtbare Workload Group ausschließlich ein Prozentlimit besitzt.

Alle geänderten öffentlichen Procedures stellen den beim Eintritt vorhandenen
`LOCK_TIMEOUT` nach erfolgreichem Aufruf und nach behandelten
Ausgabefehlern wieder her.

## Berechtigungen und Datenschutz

Das Framework vergibt keine Serverberechtigung. Berechtigungsfehler werden als
`DENIED_PERMISSION` klassifiziert und von `TIMEOUT` sowie
`ERROR_HANDLED` getrennt. Ein leerer oder eingeschränkt sichtbarer Scope
wird als `AVAILABLE_EMPTY_OR_RESTRICTED` ausgewiesen.

Das Governance-Resultset enthält keine Login-, Host-, Programm-, Querytext-
oder Plandaten. Runtimefixtures verwenden ausschließlich kurzlebige
`Example*`-Workload-Groups und einen synthetischen Benutzer ohne Login.
Es werden keine realen Umgebungswerte in Repositorydateien übernommen.

## Bewertungsgrenzen

- Kein konfiguriertes Limit ist kein Fehler.
- Ein gespeichertes Prozentlimit kann unwirksam sein.
- Eine Verletzung beweist Enforcement, nicht Ursache oder Verantwortlichen.
- Peak und Verletzungszähler benötigen immer `StatisticsStartTime`.
- Session- und Workload-Group-Werte sind unterschiedliche Granularitäten.
- Version Store und TempDB-Log werden von diesem Limit nicht erfasst.
- Eine ausstehende Rekonfiguration verhindert eine belastbare
  Aktivitätsaussage aus dem gespeicherten Wert.

## Nachweis

Der maschinenlesbare Vertrag liegt in
[`SQL25_TempDB_Resource_Governance_Public_Contract.json`](../../Metadata/Quality/SQL25_TempDB_Resource_Governance_Public_Contract.json).
Der Runtimevertrag
`Code/Tests/Infrastructure/122_SQL25_TempDB_Resource_Governance_Runtime_Contract.sql`
prüft SQL Server 2019, 2022 und 2025, beide direkten Procedures, das
Overview-Routing, JSON und benannte TABLE-Ziele, eingeschränkte Rechte sowie
die Wiederherstellung von `LOCK_TIMEOUT`.

Auf SQL Server 2025 legt er – wenn der konkrete Build die Pflichtspalten
bereitstellt – ausschließlich synthetische `Example*`-Workload-Groups an.
Er prüft Kein-Limit-, MB-/Prozent-, Vorrang-, Wirksamkeits- und
Resetfenstersemantik. Fehlt die Quellschemafähigkeit, muss der Produktpfad den
konkreten Status explizit liefern.

## Primärquellen

- [TempDB space resource governance](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/tempdb-space-resource-governance?view=sql-server-ver17)
- [sys.resource_governor_workload_groups (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-resource-governor-workload-groups-transact-sql?view=sql-server-ver17)
- [sys.dm_resource_governor_workload_groups (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-resource-governor-workload-groups-transact-sql?view=sql-server-ver17)
- [ALTER RESOURCE GOVERNOR (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-resource-governor-transact-sql?view=sql-server-ver17)
