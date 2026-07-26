# Masterplan-Ergänzung: SQL-Server-zentrierter Scope

| Merkmal | Wert |
|---|---|
| Status | `BINDING_ADDENDUM` |
| Stand | 2026-07-26 |
| Bezieht sich auf | `MASTER_IMPLEMENTATION_PLAN.md` |
| Vorrang | Diese Ergänzung und `SQL_SERVER_CENTRIC_SCOPE_DECISION.md` haben bei widersprüchlichen Formulierungen Vorrang. |

## 1. Korrektur der Architekturgrenze

Der Masterplan ist ausschließlich als Plan für ein **SQL-Server-Lab** zu verstehen.

Formulierungen wie „projektneutral“, „generische Component Types“ oder „technologieoffener Proof“ bedeuten nicht, dass ein allgemeines Multi-Purpose-Lab entwickelt wird. Sie bedeuten nur, dass ein SQL-Server-Szenario unterstützende Systeme einbinden kann, ohne dass diese als Sonderfall fest in den Orchestrator codiert werden müssen.

SQL Server ist stets:

- Hauptzweck des Runs;
- primäre fachliche Zielplattform;
- Bezugspunkt für Testdaten, Workload, Observation und Assertion;
- Grund für jede zusätzlich bereitgestellte Supporting Component.

## 2. Verbindliche Package-Regel

Jedes ausführbare Lab Package muss einen `SqlPurpose` deklarieren und mindestens eine primäre SQL-Server-Komponente enthalten.

Supporting Components sind nur zulässig, wenn sie für diesen SQL-Zweck erforderlich sind, beispielsweise:

- Domain Controller und DNS für Windows Authentication, Kerberos, WSFC oder FCI;
- Hadoop-Cluster für PolyBase;
- REST-Service als SQL-Server-Client, Datenquelle oder Datenziel;
- Load Generator für SQL-Server-Last und Concurrency;
- Router oder Fault Controller für SQL-Server-Netzwerk- und Availability-Tests;
- Observability-Komponente für zusätzliche SQL-Server-Evidenz.

Ein Package ohne SQL-Server-Zweck ist nicht Teil dieses Repositorys.

## 3. Korrektur der Architekturbeweise

Vor Vertragsversion `1.0` sind nicht allgemeine Nicht-SQL-Proofs erforderlich, sondern SQL-zentrierte Beweise:

1. SQL-Server-Quick-Environment auf Docker;
2. derselbe logische Quick-Contract auf Podman;
3. SQL-Server-VM auf Hyper-V;
4. Performance-Demo mit synthetischem DataSet und mehrstufigem Workflow;
5. Analyze-Szenario mit Frameworkinstallation und Finding-Assertion;
6. Supporting-Component-Proof, beispielsweise SQL Server plus Domain Controller;
7. später SQL Server plus Hadoop für PolyBase oder SQL Server plus REST-Testdienst.

Der Supporting-Component-Proof darf nicht zu einem eigenständigen Nicht-SQL-Produktziel werden.

## 4. Korrektur der Roadmap

Die priorisierte Reihenfolge lautet:

### Phase A – SQL-Server-Core

- Contracts und CLI;
- Docker-Provider;
- Podman-Provider;
- Hyper-V-Provider;
- SQL Server 2019, 2022 und 2025;
- State, Secret, Binding und Cleanup;
- Quick Environment.

### Phase B – SQL-Projektintegration

- `SQL_PerformanceSchulung`-Package;
- `SQL_Server_Analyze`-Package;
- synthetische DataSets;
- Workloads, Probes und Assertions;
- SQL-bezogene Fault Injection.

### Phase C – SQL-Infrastrukturkonstellationen

- Domain Controller und DNS;
- mehrere SQL-Server-Knoten;
- Windows Authentication und Kerberos;
- WSFC, AG und FCI;
- getrennte Data-/Log-/TempDB-Storage-Rollen;
- Netzwerk- und I/O-Simulation.

### Phase D – SQL-Integrationskonstellationen

Nur bei konkretem SQL-Bedarf:

- PolyBase mit Hadoop;
- REST-/HTTP-Datenquelle oder Testclient;
- ETL-, File-, Object-Storage- oder Messaging-Komponenten;
- zusätzliche Datenplattformen als SQL-Quelle, Ziel oder Vergleichssystem.

## 5. Korrektur der Provideranforderung

Hyper-V, Docker und Podman sind verbindliche Kernprovider. Keiner davon darf zu einer bloßen späteren Option herabgestuft werden.

Die Provider müssen denselben übergeordneten Vertrag erfüllen:

- `Preflight`;
- read-only `Plan`;
- `Provision`;
- tatsächliche Ressourcen-IDs;
- Health und SQL Readiness;
- Runtime Bindings;
- `Status`, `Stop`, `Start`, `Reset`, `Down` und `Destroy`, soweit fachlich unterstützt;
- scope-gebundener Cleanup.

Providerunterschiede werden über Capabilities dargestellt und nicht durch falsche Gleichwertigkeitsbehauptungen verdeckt.

## 6. Auswirkung auf bestehende Dokumente

Bei der weiteren Umsetzung werden folgende Dokumente entsprechend dieser Ergänzung interpretiert und überarbeitet:

- `EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md`;
- `FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md`;
- `PROJECT_INTEGRATION_CONTRACT.md`;
- `MANIFEST_AND_INTERFACE_ARCHITECTURE.md`;
- `EXISTING_LAB_AND_ORCHESTRATION_PROJECTS_REVIEW.md`.

Die Recherche zu allgemeinen Orchestrierungsprojekten bleibt sinnvoll, dient aber ausschließlich der Auswahl bewährter Muster für das SQL-Server-Lab.

## 7. Abnahmekriterien

- SQL Server ist in allen öffentlichen Einstiegsdokumenten eindeutig Hauptzweck.
- Jedes ausführbare Package besitzt `SqlPurpose`.
- Supporting Components sind an einen SQL-Zweck gebunden.
- Hyper-V, Docker und Podman stehen gleichrangig im Zielvertrag.
- Roadmap und Architekturtests beginnen mit SQL-Server-Szenarien.
- Hadoop, REST und andere Technologien erscheinen nur als mögliche SQL-Supporting-Components.
- Es entsteht keine allgemeine Labplattform außerhalb des SQL-Server-Zwecks.
