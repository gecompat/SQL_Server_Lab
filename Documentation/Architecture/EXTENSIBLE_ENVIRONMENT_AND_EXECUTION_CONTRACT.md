# Erweiterbarer SQL-Server-Umgebungs- und Ausführungsvertrag

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_DECISION_DRAFT` |
| Stand | 2026-07-26 |
| Vertragsfamilie | `SQL_SERVER_LAB_CONTRACTS` |
| Hauptzweck | reproduzierbare SQL-Server-Labs |
| Erweiterungsgrenze | Supporting Components nur für einen dokumentierten SQL-Server-Zweck |
| Maßgebliche Scope-Entscheidung | [SQL-Server-zentrierte Scope-Entscheidung](./SQL_SERVER_CENTRIC_SCOPE_DECISION.md) |

## 1. Zentrale Architekturentscheidung

Ein konsumierendes Projekt übergibt dem Lab weder ein einziges Universal-Setup-Skript noch eine providergebundene Compose- oder Hyper-V-Datei. Es liefert ein versioniertes, selbstbeschreibendes **SQL Server Lab Package**.

Das Package beschreibt getrennt:

1. den SQL-Server-Zweck;
2. die primären SQL-Server-Komponenten;
3. optional erforderliche Supporting Components;
4. Installation und Konfiguration innerhalb der Komponenten;
5. synthetische Testdaten und deren Verifikation;
6. Workload, Observation und Assertions;
7. typisierte Inputs und Outputs zwischen Schritten;
8. Safety-, Ressourcen-, Privacy- und Cleanup-Grenzen.

Das Lab löst diese Beschreibung gegen SQL-Server- und Supporting-Component-Types, Action Handler, Provider und lokale Host-Capabilities auf. Erst daraus entsteht ein konkreter, read-only prüfbarer Ausführungsplan.

SQL Server bleibt dabei immer das Primärsystem. Erweiterbarkeit verhindert nur, dass SQL-bezogene Hilfssysteme wie Domain Controller, Hadoop-Cluster oder REST-Testdienste als unwartbare Sonderfälle in den Orchestrator eingebaut werden.

## 2. Warum ein einfacher Project Adapter nicht genügt

Ein Adapter mit festen Entrypoints wie `Install`, `Observe` und `Cleanup` beantwortet nur, welches Skript aufgerufen werden soll. Er beantwortet nicht ausreichend:

- wie viele SQL-Server-Instanzen benötigt werden;
- welche SQL-Version, Edition, Betriebssystem- und Authentifizierungsart erforderlich ist;
- ob SQL Server als Container, Linux-VM oder Windows-VM bereitgestellt werden muss;
- welche Netzwerke, Storage-Rollen und Ressourcenlimits erforderlich sind;
- ob Domain Controller, Router, Load Driver, Hadoop oder REST-Service benötigt werden;
- welche Frameworkobjekte, Datenbanken oder Testartefakte installiert werden;
- wie synthetische Testdaten erzeugt, verteilt und geprüft werden;
- welche Workloads parallel oder sequenziell laufen;
- welche SQL- und Infrastrukturevidenz beobachtet wird;
- wie Outputs eines Schritts in spätere Schritte gelangen;
- wie Cleanup und Recovery über alle beteiligten Systeme erfolgen.

Der Project Adapter bleibt deshalb klein. Er bindet einen Katalog versionierter SQL Server Lab Packages. Die eigentliche Beschreibung liegt in Package, Environment Blueprint, DataSets und Workflow.

## 3. Gesamtmodell

```text
Project Adapter
      ↓
SQL Server Lab Package
      ├─ SqlPurpose
      ├─ Environment Blueprint
      ├─ Deployment Units
      ├─ DataSets
      ├─ Workflow Graph
      ├─ Probes und Assertions
      └─ Safety/Privacy/Cleanup Policies
      ↓
SQL- und Supporting-Component-Type-Auflösung
      ↓
Expanded SQL Resource Graph
      ↓
Capability Negotiation und lokale Bindings
      ↓
Bound Execution Plan
      ↓
Hyper-V | Docker | Podman
      ↓
Runtime State, Evidence und Cleanup
```

Das Modell trennt fünf Zustände:

| Zustand | Inhalt | Mutierend? |
|---|---|---:|
| `Intent` | SQL-Zweck, Versionen und fachliche Constraints | Nein |
| `DesiredState` | expandierte logische SQL-Topologie | Nein |
| `BoundPlan` | konkrete Provider, lokale Bindings und Mutationen | Nein |
| `RuntimeState` | tatsächlich erzeugte Ressourcen, IDs und Schrittstatus | Ja |
| `EvidenceState` | technische lokale Evidenz und sanitisierte Summary | nur lokale Artefakterzeugung |

## 4. SQL Server Lab Package

### 4.1 Pflichtbestandteile

Ein ausführbares Package enthält mindestens:

- `PackageContractVersion`;
- `PackageId` und `PackageVersion`;
- `ProjectId`;
- `SqlPurpose`;
- `EnvironmentCatalog`;
- `ScenarioCatalog`;
- `RequiredComponentTypes`;
- `RequiredActionTypes`;
- Artefakte mit Hashes;
- Secret Requirements ohne Werte;
- Trust Class;
- Data Classification;
- License Notice;
- Privacy Export Policy;
- Known Limitations.

### 4.2 `SqlPurpose`

Der `SqlPurpose` beschreibt den fachlichen SQL-Server-Bezug.

Pflichtinformationen:

- `PurposeId`;
- `PurposeClass`;
- `TargetSqlVersions`;
- `TargetOperatingSystems`;
- `TargetEditions`;
- `RequiredSqlCapabilities`;
- `PrimarySqlComponents`;
- `SupportingComponents`;
- `ScenarioRefs`;
- `ExpectedSqlEvidence`;
- `KnownSqlLimitations`.

Vorgesehene Purpose Classes:

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

Ein Package ohne `SqlPurpose` wird abgelehnt.

## 5. Environment Blueprint

### 5.1 Primäre SQL-Komponenten

Primäre SQL-Komponenten sind das fachliche Zentrum.

Beispiele:

```text
mssql.instance
mssql.availability-group
mssql.failover-cluster-instance
mssql.replication-topology
mssql.log-shipping-topology
mssql.polybase-instance
mssql.load-generator
```

Eine primäre SQL-Komponente beschreibt mindestens:

- Component ID und Role;
- SQL-Server-Version oder Version Constraint;
- Betriebssystemfamilie;
- Editionanforderung;
- Agentanforderung;
- Authentication Modes;
- Collationanforderung;
- CPU-, RAM- und SQL-Memory-Anforderungen;
- Data-, Log-, TempDB- und Backup-Storage Claims;
- Netzwerkinterfaces;
- Required Capabilities;
- Lifecycle Policy;
- exportierte SQL Bindings.

### 5.2 Supporting Components

Supporting Components sind nur mit dokumentiertem SQL-Bezug zulässig.

Beispiele:

```text
identity.domain-controller
identity.dns-server
hadoop.cluster
http.service
http.mock-service
client.sql-workload-driver
core.router
core.network-fault-controller
observability.collector
```

Jede Supporting Component benötigt:

- `SupportsSqlPurpose`;
- eine Relation zu einer primären SQL-Komponente oder einem SQL-Workflow;
- eine begründete Capability Requirement;
- einen eigenen Health-, Lifecycle- und Cleanup-Vertrag;
- Known Limitations.

### 5.3 Management Modes

```text
PROVISIONED
ATTACHED
EXTERNAL_READ_ONLY
EXTERNAL_MUTABLE
EMULATED
FIXTURE
```

`EXTERNAL_MUTABLE` ist standardmäßig blockiert. Ein produktiver Endpoint ist kein zulässiger Standardtarget.

## 6. Beziehungen

Typisierte Beziehungen verbinden SQL- und Supporting Components.

Beispiele:

```text
connects-to
replicates-to
authenticates-against
joined-to-domain
reads-external-data-from
writes-to
calls-http
observes
fault-targets
```

Eine Relation beschreibt:

- Source und Target;
- Interface Type;
- Richtung;
- Readiness-Abhängigkeit;
- Network- und Security-Constraints;
- optional Latenz-, Bandbreiten- oder Isolationserfordernisse;
- SQL-Zweck der Beziehung.

## 7. Composite SQL-Topologien

Komplexe SQL-Konstellationen dürfen als Composite Component beschrieben und anschließend expandiert werden.

Beispiele:

- Availability Group → primäre und sekundäre Instanzen, Listener, optional Domain/DNS/Witness;
- FCI → Cluster Nodes, Shared Storage, Domain/DNS und SQL-Rolle;
- Replication → Publisher, Distributor, Subscriber und Workload Driver;
- PolyBase → SQL-Instanz, Hadoop- oder Object-Storage-Supporting-Component und DataSet;
- Security Lab → SQL-Instanz, Domain Controller, Accounts und Client.

Der Expander erzeugt logische Components und Relations. Die konkrete Providerzuordnung erfolgt erst danach.

## 8. Deployment Units

Alles, was innerhalb einer SQL- oder Supporting Component installiert oder konfiguriert wird, ist eine Deployment Unit.

Pflichtfelder:

- `UnitId`;
- `TargetSelector`;
- `ActionType`;
- `ArtifactRef`;
- `Parameters`;
- `SecretRefs`;
- `DependsOn`;
- `IdempotencyMode`;
- `SuccessCondition`;
- `ProducedBindings`;
- `RollbackAction`;
- `TimeoutSeconds`;
- `SafetyClass`;
- `DataClassification`.

Beispiele:

- SQL_Server_Analyze installieren;
- Performance-Schulungs-Framework installieren;
- SQL-Datenbank mit definierter Collation erzeugen;
- SQL Agent aktivieren oder konfigurieren;
- Domain Join durchführen;
- Hadoop-Testcluster initialisieren;
- REST-Mock-Service konfigurieren;
- Workload Driver bereitstellen.

## 9. Action Types

Action Types sind namespaced und typisiert.

SQL-nahe Beispiele:

```text
mssql.script.execute
mssql.database.create
mssql.database.drop-marked
mssql.backup.restore-synthetic
mssql.query.execute
mssql.wait-for-ready
mssql.assert.version
mssql.assert.object
mssql.agent.configure
mssql.session.start
mssql.session.stop
```

Supporting-Action-Beispiele:

```text
powershell.script.execute
shell.script.execute
core.file.copy
http.request.execute
hadoop.hdfs.put
hadoop.job.submit
identity.domain.join
fault.network.apply
fault.network.remove
fault.storage.apply
fault.storage.remove
```

Der Core führt keinen unbekannten Action Type aus. Jeder Handler deklariert Input-/Output-Schema, Side Effects, Capabilities, Secret-Injection, Idempotenz, Retry, Cancel und Compensation.

## 10. Testdatenvertrag

Testdaten werden nicht als unsichtbarer Nebeneffekt eines Setup-Skripts behandelt.

Eine `DataSetDefinition` enthält:

- `DataSetId`;
- SQL- oder Supporting-Target;
- `CreationMode`;
- Generator oder Fixture;
- deterministischen Seed oder begründete Abweichung;
- Scale Profile;
- Distribution Profile;
- Preconditions;
- Completion Signal;
- Verification Actions;
- Exports;
- Reset Policy;
- Cleanup Policy;
- Data Classification;
- Known Variability.

Creation Modes:

```text
GENERATE
LOAD_PUBLIC_FIXTURE
RESTORE_SYNTHETIC_ARTIFACT
DERIVE
STREAM
```

Reale Produktionsbackups oder aus realen Systemen extrahierte Daten sind unzulässig.

### 10.1 Beispiel Performance-Demo

```text
DataSet: SQLPERF-SKEW-001
Target: sql-primary
Mode: GENERATE
Profile: HighlySkewed
Verify:
  - markierte Datenbank vorhanden
  - erwartete Tabellenmarker
  - Zeilenanzahl innerhalb Bandbreite
  - Statistik vorhanden
Export:
  - binding.dataset.database.name
```

### 10.2 Beispiel PolyBase

```text
DataSet: POLYBASE-HDFS-001
Targets:
  - hadoop-cluster
  - sql-polybase
Mode: GENERATE
Verify:
  - synthetische HDFS-Dateien vorhanden
  - SQL External Data Source erreichbar
  - External Table liefert erwartete Invarianten
```

## 11. Workflow Graph

`Arrange`, `Act`, `Observe`, `Assert` und `Cleanup` bleiben semantische Phasen. Technisch wird ein Szenario als gerichteter, azyklischer Workflow Graph modelliert.

Ein Step enthält:

- `StepId`;
- `Phase`;
- `ActionType`;
- `TargetRef`;
- `Inputs`;
- `SecretRefs`;
- `DependsOn`;
- optional `Condition` und `ConcurrencyGroup`;
- `TimeoutSeconds`;
- Retry- und Failure Policy;
- Idempotency Mode;
- `Produces`;
- Compensation;
- `AlwaysRun`;
- Safety Class.

Unbegrenzte Schleifen sind unzulässig. Wiederholung benötigt harte Attempt- und Zeitgrenzen.

## 12. Runtime Bindings

Statische Packages enthalten keine lokalen Endpunkte, Pfade oder Secret-Werte. Provider und Actions erzeugen typisierte Runtime Bindings.

SQL-Beispiele:

```text
binding.sql-primary.endpoint.sql
binding.sql-primary.credential-ref.admin
binding.sql-primary.metadata.product-version
binding.dataset.database.name
binding.ag.listener.endpoint.sql
```

Supporting-Beispiele:

```text
binding.domain.endpoint.dns
binding.hadoop.endpoint.hdfs
binding.api.endpoint.http-base
binding.artifacts.local-root
```

Ein Binding besitzt Type, Producer, Sensitivity, Scope, Lifetime, Consumer Allowlist und Export Policy. Der tatsächliche Wert steht nur im lokalen Runtime State.

## 13. Input-/Output-Verkettung

Ein Step kann Outputs früherer Schritte referenzieren:

```text
Inputs.SqlEndpoint     = ${bindings.sql-primary.endpoint.sql}
Inputs.TargetDatabase  = ${bindings.dataset.database.name}
Inputs.AdminCredential = ${bindings.sql-primary.credential-ref.admin}
```

Referenzen werden typ- und scopesicher geprüft. Secret Bindings dürfen nicht als normale Strings ausgegeben werden.

## 14. Providervertrag

Verbindliche Kernprovider:

```text
provider.hyperv
provider.docker
provider.podman
```

Jeder Provider implementiert mindestens:

- `DetectCapabilities`;
- `ValidateResourceGraph`;
- read-only `Plan`;
- `Provision`;
- `GetStatus`;
- `Stop` und `Start`;
- `Reset`, soweit unterstützt;
- `Destroy`;
- `ExecuteInResource`, soweit unterstützt;
- Rückgabe tatsächlicher Ressourcen-IDs und Bindings.

Provider dürfen keine projektspezifischen Testdaten, SQL-Findings oder Schulungsaussagen besitzen.

Docker und Podman bleiben getrennte Provider. Eine erfolgreiche Docker-Ausführung gilt nicht automatisch als Podman-Nachweis.

## 15. Beispiele

### 15.1 SQL Performance Schulung

```text
sql-primary: mssql.instance
load-driver: client.sql-workload-driver

Install demo framework
Create marked synthetic database
Generate DataSet
Capture baseline
Run workload
Observe SQL evidence
Apply mitigation
Capture comparison
Assert direction and invariants
Cleanup
```

### 15.2 SQL Server Analyze

```text
sql-primary: mssql.instance
workload-driver: client.sql-workload-driver
optional network-fault-controller

Install framework
Create synthetic database
Create blocking/tempdb/io condition
Run analyzer probes
Assert finding and status codes
Cleanup
```

### 15.3 SQL Server plus Domain Controller

```text
domain-controller: identity.domain-controller
sql-primary: mssql.instance
client: client.sql-workload-driver

Provision domain
Join SQL and client
Configure service account/SPN
Run Windows Authentication or Kerberos test
Observe SQL and security evidence
Cleanup disposable scope
```

### 15.4 SQL Server PolyBase plus Hadoop

```text
sql-polybase: mssql.polybase-instance
hadoop-support: hadoop.cluster

Provision both components
Generate synthetic HDFS DataSet
Configure External Data Source and External Table
Run SQL query
Observe SQL and supporting evidence
Assert SQL result contract
Cleanup
```

Das Lab wird dadurch nicht zum allgemeinen Hadoop-Manager. Hadoop ist ausschließlich Supporting Component des SQL-Purpose.

## 16. Control Plane

Die erste Bedienoberfläche ist PowerShell. Der Core darf aber nicht an Konsolentext gekoppelt werden.

CLI und eine spätere REST- oder UI-Anbindung verwenden dieselben serialisierbaren Commands:

```text
GetCapabilities
ValidatePackage
ValidateRequest
CreatePlan
ApprovePlan
StartRun
GetRun
GetRunEvents
CancelRun
StopRun
StartResources
ResetRun
DestroyRun
ExportSanitizedSummary
```

Länger laufende Commands liefern eine `OperationId`. Status und Events werden strukturiert abgefragt. Eine spätere REST API ist nur Control-Plane-Adapter und dupliziert weder Provider- noch Package-Logik.

## 17. Trust- und Sicherheitsmodell

Trust Classes:

```text
CORE_BUILTIN
OFFICIAL_EXTENSION
PROJECT_CONTENT
LOCAL_TRUSTED
UNTRUSTED
```

Jede Action deklariert:

- Datei-, Netzwerk-, Prozess-, Provider- und Datenbankmutationen;
- benötigte Privilegien;
- Zielscope;
- maximale Ressourcen;
- External-Egress-Bedarf;
- Secret-Zugriff;
- Destructive Class;
- Compensation-Verhalten.

Project Content darf keine Providerressourcen direkt löschen. Untrusted Content wird nicht ausgeführt.

## 18. Erweiterungsmodell

Erweiterungspunkte:

| Extension Point | SQL-bezogener Zweck |
|---|---|
| Provider Plugin | neue technische Plattform für SQL-Server- oder Supporting Components |
| SQL Component-Type Pack | neue SQL-Server-Rolle oder Topologie |
| Supporting Component-Type Pack | benötigtes Hilfssystem für SQL-Szenario |
| Action-Type Pack | neue SQL-, Client-, Integrations- oder Beobachtungsaktion |
| Fault Pack | kontrollierte SQL-bezogene Fault Injection |
| Project Package | Analyze-, Schulungs- oder weiteres SQL-Projekt |
| Control-Plane Adapter | CLI, REST oder UI |
| Evidence Renderer | lokale oder sanitisierte Darstellung |

Supporting Extensions werden erst bei konkretem SQL-Anwendungsfall implementiert.

## 19. Anti-Patterns

Unzulässig:

1. ein Universal-`Setup.ps1`, das Provider, SQL-Installation, Testdaten, Workload und Cleanup untrennbar vermischt;
2. Compose- oder Hyper-V-Dateien als fachliche Projektschnittstelle;
3. reale Connection Strings oder Hostbindings in Packages;
4. Projektskripte, die fremde Container oder VMs direkt verwalten;
5. Testdaten ohne eigene Verifikation und Cleanup-Regel;
6. Providerbefehle innerhalb fachlicher SQL-Szenarien;
7. Statusbestimmung durch Parsen von Konsolentext;
8. ein Package ohne SQL Purpose;
9. eine Supporting Component ohne dokumentierten SQL-Bezug;
10. vorauseilende Entwicklung einer allgemeinen Hadoop-, REST- oder Clusterplattform.

## 20. Implementierungsreihenfolge

### Schritt 1 – SQL-Core-Contracts

- Package und `SqlPurpose`;
- SQL Environment Blueprint;
- SQL-/Supporting-Component Type;
- Action Type;
- DataSet;
- Workflow;
- Runtime Binding;
- Bound Plan;
- Run State und Event.

### Schritt 2 – Built-in SQL Types

- `mssql.instance`;
- grundlegende Storage- und Network Claims;
- SQL Readiness;
- SQL Script, Query und Assertion Actions;
- Docker-, Podman- und Hyper-V-Mapping.

### Schritt 3 – Primärprojekte

- Quick Environment;
- Performance-Schulungs-Pilot;
- Analyze-Pilot;
- DataSet-, Workload-, Probe- und Cleanup-Verträge.

### Schritt 4 – SQL-Infrastruktur

- Domain Controller und DNS;
- mehrere SQL-Knoten;
- Windows Authentication, Kerberos, AG und FCI;
- SQL-bezogene Netzwerk- und I/O-Faults.

### Schritt 5 – SQL-Integration

Nur nach konkretem Bedarf:

- PolyBase mit Hadoop;
- REST-Testdienst oder -Datenquelle;
- weitere Supporting Components.

## 21. Abnahmekriterien

Der Vertrag ist belastbar, wenn:

1. jedes Package einen SQL-Zweck beschreibt;
2. Umgebung, Installation, Testdaten, Workload, Observation und Cleanup vollständig modelliert werden;
3. Hyper-V, Docker und Podman denselben übergeordneten Vertrag erfüllen;
4. Projekte keine Providerbefehle enthalten müssen;
5. DataSets verifizierbar und resetbar sind;
6. Inputs und Outputs typisiert verbunden werden;
7. Composite SQL-Topologien expandierbar sind;
8. Supporting Components einen dokumentierten SQL-Bezug besitzen;
9. SQL Server plus Domain Controller und später PolyBase plus Hadoop ohne Core-Neuentwurf modellierbar sind;
10. CLI und spätere REST Control Plane dieselben Commands, Results und Events verwenden;
11. alle Seiteneffekte, Secrets, Ressourcen und Cleanup-Grenzen vor Mutation planbar sind;
12. keine allgemeine Nicht-SQL-Labplattform entsteht.
