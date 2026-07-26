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

- SQL Server 2019, 2022 und 2025 bereitzustellen;
- SQL-Server-Konstellationen reproduzierbar aufzubauen;
- SQL-Server-Demos, Diagnosefälle, Lastsituationen und Infrastrukturabhängigkeiten nachzustellen;
- SQL-Server-bezogene Tests kontrolliert auszuführen, zu beobachten, zu validieren und zu bereinigen.

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
- `TargetSqlVersions`;
- `TargetOperatingSystems`;
- `TargetEditions`;
- `RequiredSqlCapabilities`;
- `PrimarySqlComponents`;
- `SupportingComponents`;
- `SqlScenarioRefs`;
- `ExpectedSqlEvidence`;
- `KnownSqlLimitations`.

Vorgesehene `PurposeClass`-Werte:

```text
QUICK_ENVIRONMENT
PERFORMANCE_DEMO
DIAGNOSTIC_SCENARIO
LOAD_SCENARIO
AVAILABILITY_SCENARIO
SECURITY_SCENARIO
INTEGRATION_SCENARIO
UPGRADE_COMPATIBILITY_SCENARIO
CONTRACT_FIXTURE
```

Ein Package ohne `SqlPurpose` wird nicht als ausführbares SQL-Server-Lab-Package akzeptiert.

## 4. Rolle des generischen Komponentenmodells

Das generische Component-, Action-, Binding- und Workflowmodell bleibt bestehen, aber nur als technische Grundlage zur Beschreibung komplexer SQL-Server-Labs.

Es dient dazu:

- SQL-Server-Topologien providerunabhängig zu modellieren;
- unterstützende Systeme nicht als Sonderfall in den Orchestrator einzubauen;
- Hyper-V-, Docker- und Podman-Ressourcen über denselben Lifecycle zu steuern;
- Installations-, Testdaten-, Workload- und Observation-Schritte typisiert zu verbinden;
- spätere SQL-Server-Funktionen nicht durch heute zu enge Schemas zu blockieren.

Es dient ausdrücklich nicht dazu, aus `SQL_Server_Lab` eine allgemeine Hadoop-, API-, Kubernetes- oder Multi-Purpose-Labplattform zu machen.

## 5. Gültige zukünftige Erweiterungen

### 5.1 PolyBase mit Hadoop

Gültig:

- SQL Server mit PolyBase-Rolle;
- Hadoop-Cluster als Supporting Component;
- synthetische Daten in HDFS;
- SQL-Server-Abfrage über External Table;
- Performance-, Fehler- und Netzwerkbeobachtung;
- Cleanup beider Seiten.

Nicht Ziel:

- allgemeine Hadoop-Schulung ohne SQL Server;
- unabhängiger Hadoop-Cluster-Manager;
- Hadoop-Benchmark ohne SQL-Bezug.

### 5.2 Domain Controller

Gültig:

- SQL Server unter Domain Service Account;
- Kerberos-/SPN-Test;
- Windows Authentication;
- Always On, WSFC oder FCI;
- Gruppen- und Berechtigungsszenarien.

Nicht Ziel:

- allgemeines Active-Directory-Schulungslab ohne SQL Server.

### 5.3 REST oder API

Gültig:

- API als SQL-Server-Client;
- REST-Datenquelle oder -ziel;
- API-Workload für Connection Pooling, Retry oder Transaktionen;
- SQL-Server-2025- oder Integrationstests mit HTTP-Komponente;
- Mock-Service für reproduzierbare SQL-bezogene Tests.

Nicht Ziel:

- allgemeines API-Testframework ohne SQL-Server-Szenario.

### 5.4 Weitere Datenplattformen

Gültig, wenn die Plattform:

- Datenquelle oder Datenziel für SQL Server ist;
- Replikation, ETL, PolyBase oder Linked-Server-Verhalten unterstützt;
- als Vergleichs- oder Integrationskomponente eines SQL-Server-Tests dient.

Nicht Ziel ist eine eigenständige Orchestrierungsplattform für diese Technologie.

## 6. Provider-Scope

Die verbindlichen ersten Provider bleiben:

```text
provider.hyperv
provider.docker
provider.podman
```

Der Providervertrag wird nicht nach Technologieinhalt getrennt. Ein Hadoop- oder Domain-Controller-Supporting-Component kann auf Hyper-V oder Container abgebildet werden, sofern die dafür erforderlichen Capabilities nachgewiesen sind.

Eine Supporting Component darf nicht dazu führen, dass einer der drei Kernprovider architektonisch benachteiligt oder aus dem gemeinsamen Contract herausgedrängt wird.

## 7. Package-Scope-Regeln

Ein ausführbares Package ist gültig, wenn:

1. `SqlPurpose` vorhanden ist;
2. mindestens eine primäre SQL-Server-Komponente enthalten ist oder ein SQL-Contract-Fixture ausdrücklich ausgewiesen wird;
3. jede Supporting Component einen dokumentierten SQL-Bezug besitzt;
4. Workflow, DataSets, Probes und Assertions auf den SQL-Zweck rückführbar sind;
5. Ressourcen- und Fault-Profile SQL-bezogene Testziele unterstützen;
6. Cleanup alle primären und unterstützenden Komponenten umfasst;
7. kein unabhängiges Nicht-SQL-Produktziel entsteht.

## 8. Auswirkungen auf die Forschungsanalyse

Bestehende Projekte und Standards werden weiterhin untersucht, aber nur unter der Frage:

> Welches Muster hilft, ein besseres SQL-Server-Lab mit Hyper-V, Docker und Podman zu bauen?

Die Recherche ist keine Produkt-Roadmap für allgemeine Orchestrierung.

Beispiele:

- AutomatedLab: Rollen, Maschinen, Remoting und Hyper-V-Lifecycle;
- MSLab: Parent Images und Differencing Disks;
- Compose: Container-Service-, Network- und Volume-Modell;
- Test Kitchen: Driver, Transport, Provisioner und Verifier;
- Molecule: Prepare, Converge, Side Effect, Verify und Cleanup;
- TOSCA: typisierte Components, Relationships und Capabilities;
- CNAB/Porter: Packages, Credentials, Outputs und Actions;
- Ambari: Composite Cluster und Host Groups für einen möglichen PolyBase-Supporting-Cluster.

## 9. Umsetzungspriorität

Die Technologieoffenheit wird erst implementiert, wenn sie für einen konkreten SQL-Server-Anwendungsfall benötigt wird.

Priorität:

1. einzelne SQL-Server-Instanz;
2. mehrere SQL-Server-Versionen;
3. SQL-Server-Demo- und Diagnose-Packages;
4. SQL-Server-Last- und Fault-Szenarien;
5. Domain Controller für SQL-Server-Security- und HA-Szenarien;
6. SQL-Server-Cluster-/Availability-Topologien;
7. Hadoop- oder REST-Supporting-Components für konkrete SQL-Server-Integrationstests;
8. weitere Supporting Components nur nach dokumentiertem SQL-Bedarf.

Es wird kein generisches Hadoop-, REST- oder Clusterframework im Voraus implementiert.

## 10. Abnahmekriterien

Die Scope-Entscheidung ist eingehalten, wenn:

- README und Masterplan SQL Server als Hauptzweck nennen;
- jedes ausführbare Package einen `SqlPurpose` besitzt;
- Supporting Components ihren SQL-Bezug deklarieren;
- Roadmap und Backlog keine unabhängigen Nicht-SQL-Produktziele enthalten;
- Hyper-V, Docker und Podman weiterhin Kernprovider bleiben;
- generische Contracts nur der Erweiterbarkeit von SQL-Server-Szenarien dienen;
- ein Hadoop- oder REST-Proof nur als SQL-Server-Integrationsszenario umgesetzt wird;
- Forschungsergebnisse als Musterquelle und nicht als allgemeine Produktfusion behandelt werden.
