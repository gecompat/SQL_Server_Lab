# SQL-Server-zentrierte Scope-Entscheidung

| Merkmal | Wert |
|---|---|
| Status | `BINDING_ARCHITECTURE_DECISION` |
| Stand | 2026-07-26 |
| Primärzweck | reproduzierbare SQL-Server-Labs |
| Erweiterungsgrenze | zusätzliche Komponenten nur zur Unterstützung eines SQL-Server-Szenarios |

## 1. Entscheidung

`SQL_Server_Lab` ist und bleibt ein **SQL-Server-Lab**.

Der Hauptzweck ist:

- SQL-Server-Versionen über einen erweiterbaren Versionskatalog bereitzustellen;
- derzeit SQL Server 2019, SQL Server 2022 und SQL Server 2025 aktiv vorzusehen;
- SQL-Server-Konstellationen reproduzierbar aufzubauen;
- SQL-Server-Demos, Diagnosefälle, Lastsituationen und Infrastrukturabhängigkeiten nachzustellen;
- SQL-Server-bezogene Tests kontrolliert auszuführen, zu beobachten, zu validieren und zu bereinigen.

Die derzeitige Versionsliste ist keine dauerhafte Grenze. Neue Versionen werden über Katalogeintrag, Provider-Mapping und Capability Record ergänzt. Alte Versionen können über Statuswerte kontrolliert aus dem aktiven Umfang genommen werden.

Die Architektur darf zusätzliche Technologien unterstützen, jedoch ausschließlich dann, wenn sie für ein SQL-Server-Szenario fachlich oder technisch erforderlich sind.

Beispiele:

- Domain Controller und DNS für Windows Authentication, Kerberos, Cluster oder Service Accounts;
- Hadoop-Cluster für PolyBase- oder externe Datenszenarien;
- REST-Service oder Test-API als SQL-Server-Client, Datenquelle, Datenziel oder Integrationspartner;
- Load Generator für Concurrency-, Blocking-, CPU-, Memory- oder I/O-Tests;
- Router oder Network Fault Controller für SQL-Server-Netzwerk- und Availability-Szenarien;
- File-, Object- oder HDFS-Storage für Backup-, Import-, Export- oder PolyBase-Tests;
- Monitoring- oder Observability-Komponente zur zusätzlichen Evidenz eines SQL-Server-Szenarios.

Eine Umgebung ohne SQL-Server-Bezug ist kein Ziel dieses Repositorys.

## 2. Primäre und unterstützende Komponenten

Jedes vollständige fachliche Lab Package muss mindestens eine primäre SQL-Server-Komponente oder einen ausdrücklich SQL-Server-bezogenen Contract Fixture enthalten.

### 2.1 Primäre Komponenten

Primäre Components gehören zur SQL-Server-Zielumgebung, beispielsweise:

```text
mssql.instance
mssql.availability-group
mssql.failover-cluster-instance
mssql.replication-topology
mssql.log-shipping-topology
mssql.polybase-instance
mssql.load-generator
```

### 2.2 Unterstützende Komponenten

Supporting Components sind nur zulässig, wenn das Package ihre Beziehung zum SQL-Server-Szenario dokumentiert.

Beispiele:

```text
identity.domain-controller
identity.dns-server
hadoop.cluster
http.service
http.mock-service
core.router
core.network-fault-controller
core.storage-service
observability.collector
client.sql-workload-driver
```

Jede Supporting Component benötigt:

- `SupportsSqlPurpose`;
- mindestens eine Beziehung zu einer primären SQL-Server-Komponente oder einem SQL-Server-Workflow;
- eine begründete Required Capability;
- einen eigenen Lifecycle- und Cleanup-Vertrag;
- eine dokumentierte Aussagegrenze.

## 3. SQL Purpose Contract

Jedes Lab Package deklariert einen `SqlPurpose`-Block.

Geplante Pflichtfelder:

- `PurposeId`;
- `PurposeClass`;
- `TargetSqlVersionConstraints`;
- `TargetOperatingSystems`;
- `TargetEditions`;
- `RequiredSqlCapabilities`;
- `PrimarySqlComponents`;
- `SupportingComponents`;
- `SqlScenarioRefs`;
- `ExpectedSqlEvidence`;
- `KnownSqlLimitations`.

Ein Package ohne `SqlPurpose` wird nicht als ausführbares SQL-Server-Lab-Package akzeptiert.

## 4. Versions- und Artifact-Grenze

### 4.1 SQL-Versionen

Core-Schemas dürfen keine feste Liste einzelner Produktjahre enthalten. Version Constraints referenzieren einen separaten SQL Version Catalog.

Vorgesehene Statuswerte:

```text
EXPERIMENTAL
SUPPORTED
DEPRECATED
RETIRED
BLOCKED
```

### 4.2 Datenbankartefakte

Zulässig sind:

- Lab-erzeugte Backups zulässiger Labdatenbanken;
- öffentliche Demo- und Beispieldatenbanken;
- ausdrücklich klassifizierte lokale Entwicklungs-, Test- oder Lab-Backups.

Unzulässig sind Produktionsbackups, aus Produktivsystemen extrahierte Daten sowie unbekannte oder unklassifizierte Artefakte.

## 5. Rolle des generischen Komponentenmodells

Das generische Component-, Action-, Binding- und Workflowmodell bleibt bestehen, aber nur als technische Grundlage zur Beschreibung komplexer SQL-Server-Labs.

Es dient dazu:

- SQL-Server-Topologien providerunabhängig zu modellieren;
- unterstützende Systeme nicht als Sonderfall in den Orchestrator einzubauen;
- Hyper-V-, Docker- und Podman-Ressourcen über denselben Lifecycle zu steuern;
- Installations-, Artifact-, Testdaten-, Workload- und Observation-Schritte typisiert zu verbinden;
- spätere SQL-Server-Versionen und Funktionen nicht durch heute zu enge Schemas zu blockieren.

Es dient ausdrücklich nicht dazu, aus `SQL_Server_Lab` eine allgemeine Hadoop-, API-, Kubernetes- oder Multi-Purpose-Labplattform zu machen.

## 6. Gültige zukünftige Erweiterungen

### 6.1 PolyBase mit Hadoop

Gültig:

- SQL Server mit PolyBase-Rolle;
- Hadoop-Cluster als Supporting Component;
- synthetische Daten in HDFS;
- SQL-Server-Abfrage über External Table;
- Performance-, Fehler- und Netzwerkbeobachtung;
- Cleanup beider Seiten.

Nicht Ziel sind allgemeine Hadoop-Schulungen, unabhängige Hadoop-Clusterverwaltung oder Hadoop-Benchmarks ohne SQL-Bezug.

### 6.2 Domain Controller

Gültig:

- SQL Server unter Domain Service Account;
- Kerberos-/SPN-Test;
- Windows Authentication;
- Always On, WSFC oder FCI;
- Gruppen- und Berechtigungsszenarien.

Nicht Ziel ist ein allgemeines Active-Directory-Schulungslab ohne SQL Server.

### 6.3 REST oder API

Gültig:

- API als SQL-Server-Client;
- REST-Datenquelle oder -ziel;
- API-Workload für Connection Pooling, Retry oder Transaktionen;
- Integrationstests mit HTTP-Komponente;
- Mock-Service für reproduzierbare SQL-bezogene Tests.

Nicht Ziel ist ein allgemeines API-Testframework ohne SQL-Server-Szenario.

### 6.4 Weitere Datenplattformen

Gültig, wenn die Plattform Datenquelle oder Datenziel für SQL Server ist, Replikation, ETL, PolyBase oder Linked-Server-Verhalten unterstützt oder als Vergleichskomponente eines SQL-Server-Tests dient.

Nicht Ziel ist eine eigenständige Orchestrierungsplattform für diese Technologie.

## 7. Provider- und Ressourcen-Scope

Die verbindlichen Kernprovider bleiben:

```text
provider.hyperv
provider.docker
provider.podman
```

Jeder Provider muss Resource Assessment, Plan, tatsächliche Ressourcen-IDs, Health, Lifecycle, Recovery und Cleanup unterstützen.

CPU, RAM und Storage werden vor Mutation bewertet. Vorhergesagte Unterversorgung kann bewusst bestätigt werden. Unsichere Pfade, fehlende Providerfähigkeit, blockierte SQL-Versionen, unzulässige Daten und ein fehlender Cleanup Plan bleiben nicht übersteuerbar.

## 8. Package-Scope-Regeln

Ein ausführbares Package ist gültig, wenn:

1. `SqlPurpose` vorhanden ist;
2. mindestens eine primäre SQL-Server-Komponente enthalten ist oder ein SQL-Contract-Fixture ausdrücklich ausgewiesen wird;
3. jede Supporting Component einen dokumentierten SQL-Bezug besitzt;
4. Version Constraints gegen den SQL Version Catalog auflösbar sind;
5. Workflow, DataSets, Database Artifacts, Probes und Assertions auf den SQL-Zweck rückführbar sind;
6. Ressourcen- und Fault-Profile SQL-bezogene Testziele unterstützen;
7. vor Mutation ein vollständiger Cleanup Plan existiert;
8. Cleanup alle primären und unterstützenden Komponenten umfasst;
9. kein unabhängiges Nicht-SQL-Produktziel entsteht.

## 9. Auswirkungen auf die Forschungsanalyse

Bestehende Projekte und Standards werden weiterhin untersucht, aber nur unter der Frage:

> Welches Muster hilft, ein besseres SQL-Server-Lab mit Hyper-V, Docker und Podman zu bauen?

Die Recherche ist keine Produkt-Roadmap für allgemeine Orchestrierung.

## 10. Umsetzungspriorität

Priorität:

1. einzelne SQL-Server-Instanz;
2. SQL Version Catalog und derzeitige Versionseinträge 2019, 2022 und 2025;
3. Database-Artifact-, Backup- und Restore-Vertrag;
4. Resource Assessment, Overcommit, Cleanup und Recovery;
5. SQL-Server-Demo- und Diagnose-Packages;
6. SQL-Server-Last- und Fault-Szenarien;
7. Domain Controller für SQL-Server-Security- und HA-Szenarien;
8. SQL-Server-Cluster-/Availability-Topologien;
9. Hadoop- oder REST-Supporting-Components für konkrete SQL-Server-Integrationstests;
10. weitere Supporting Components nur nach dokumentiertem SQL-Bedarf.

Es wird kein generisches Hadoop-, REST- oder Clusterframework im Voraus implementiert.

## 11. Abnahmekriterien

Die Scope-Entscheidung ist eingehalten, wenn:

- README und Masterplan SQL Server als Hauptzweck nennen;
- jedes ausführbare Package einen `SqlPurpose` besitzt;
- Versionsangaben den aktuellen Katalogstand und keine permanente Grenze darstellen;
- neue oder alte SQL-Versionen ohne Core-Neuentwurf ergänzt oder ausgesteuert werden können;
- zulässige Lab- und öffentliche Backup-Artefakte unterstützt werden;
- Produktions- und unbekannte Daten blockiert bleiben;
- Resource Assessment und bewusster Overcommit vorgesehen sind;
- vor jeder Mutation ein Cleanup Plan existiert;
- Cleanup automatisch und wiederaufnehmbar ist;
- Supporting Components ihren SQL-Bezug deklarieren;
- Hyper-V, Docker und Podman weiterhin Kernprovider bleiben;
- generische Contracts nur der Erweiterbarkeit von SQL-Server-Szenarien dienen;
- ein Hadoop- oder REST-Proof nur als SQL-Server-Integrationsszenario umgesetzt wird;
- Forschungsergebnisse als Musterquelle und nicht als allgemeine Produktfusion behandelt werden.
