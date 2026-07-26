# Erweiterbarer SQL-Server-Umgebungs- und Ausführungsvertrag

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_DECISION_DRAFT` |
| Stand | 2026-07-26 |
| Vertragsfamilie | `SQL_SERVER_LAB_CONTRACTS` |
| Hauptzweck | reproduzierbare SQL-Server-Labs |
| Kernprovider | Hyper-V, Docker und Podman |
| Erweiterungsgrenze | Supporting Components nur für einen dokumentierten SQL-Server-Zweck |
| Maßgebliche Scope-Entscheidung | [SQL-Server-zentrierte Scope-Entscheidung](./SQL_SERVER_CENTRIC_SCOPE_DECISION.md) |

## 1. Zentrale Architekturentscheidung

Ein konsumierendes Projekt übergibt dem Lab weder ein Universal-Setup-Skript noch eine providergebundene Compose- oder Hyper-V-Datei. Es liefert ein versioniertes, selbstbeschreibendes **SQL Server Lab Package**.

Das Package beschreibt getrennt:

1. den SQL-Server-Zweck;
2. die primären SQL-Server-Komponenten;
3. optional erforderliche Supporting Components;
4. SQL-Server-Versionen als versionierte Constraints;
5. Installation und Konfiguration innerhalb der Komponenten;
6. DataSets, Datenbankartefakte und deren Verifikation;
7. Workload, Observation und Assertions;
8. typisierte Inputs und Outputs zwischen Schritten;
9. Ressourcenbedarf, Resource-Override und Hostreserve;
10. Safety-, Privacy-, Recovery- und Cleanup-Grenzen.

Das Lab löst diese Beschreibung gegen registrierte SQL-Server-Versionen, Component Types, Action Handler, Provider und lokale Host-Capabilities auf. Erst daraus entsteht ein konkreter, read-only prüfbarer Ausführungsplan.

SQL Server bleibt immer das Primärsystem. Erweiterbarkeit verhindert nur, dass SQL-bezogene Hilfssysteme wie Domain Controller, Hadoop-Cluster oder REST-Testdienste als unwartbare Sonderfälle in den Orchestrator eingebaut werden.

## 2. Warum ein einfacher Project Adapter nicht genügt

Ein Adapter mit festen Entrypoints wie `Install`, `Observe` und `Cleanup` beantwortet nur, welches Skript aufgerufen werden soll. Er beantwortet nicht ausreichend:

- wie viele SQL-Server-Instanzen benötigt werden;
- welche SQL-Server-Version, Edition, Betriebssystem- und Authentifizierungsart erforderlich ist;
- ob SQL Server als Container, Linux-VM oder Windows-VM bereitgestellt werden muss;
- welche Netzwerke, Storage-Rollen und Ressourcenlimits erforderlich sind;
- ob Domain Controller, Router, Load Driver, Hadoop oder REST-Service benötigt werden;
- welche Frameworkobjekte, Datenbanken oder Datenbankartefakte installiert werden;
- wie Testdaten erzeugt, aus einem zulässigen Backup wiederhergestellt, verteilt und geprüft werden;
- welche Workloads parallel oder sequenziell laufen;
- welche SQL- und Infrastrukturevidenz beobachtet wird;
- wie Outputs eines Schritts in spätere Schritte gelangen;
- wie Recovery und Cleanup über alle beteiligten Systeme erfolgen.

Der Project Adapter bleibt deshalb klein. Er bindet einen Katalog versionierter SQL Server Lab Packages. Die eigentliche Beschreibung liegt in Package, Environment Blueprint, DataSets, Artifact Definitions und Workflow.

## 3. Gesamtmodell

```text
Project Adapter
      ↓
SQL Server Lab Package
      ├─ SqlPurpose
      ├─ Version Constraints
      ├─ Environment Blueprint
      ├─ Deployment Units
      ├─ DataSets und Database Artifacts
      ├─ Workflow Graph
      ├─ Probes und Assertions
      └─ Resource/Safety/Privacy/Recovery/Cleanup Policies
      ↓
SQL-Version-, Component- und Action-Type-Auflösung
      ↓
Expanded SQL Resource Graph
      ↓
Capability Negotiation und lokale Bindings
      ↓
Resource Assessment und Cleanup Plan
      ↓
Bound Execution Plan
      ↓
Hyper-V | Docker | Podman
      ↓
Runtime State, Evidence, Recovery und Cleanup
```

Das Modell trennt folgende Zustände:

| Zustand | Inhalt | Mutierend? |
|---|---|---:|
| `Intent` | SQL-Zweck, Version Constraints und fachliche Anforderungen | Nein |
| `DesiredState` | expandierte logische SQL-Topologie | Nein |
| `ResourceAssessment` | Ressourcenbedarf, Hostreserve, Defizite und Overcommit-Risiko | Nein |
| `BoundPlan` | konkrete Provider, lokale Bindings, Mutationen und Cleanup Plan | Nein |
| `RuntimeState` | tatsächlich erzeugte Ressourcen, IDs und Schrittstatus | Ja |
| `EvidenceState` | technische lokale Evidenz und sanitisierte Summary | nur lokale Artefakterzeugung |
| `RecoveryState` | offene Compensation- und Cleanup-Schritte | nur lokale Recovery-Metadaten |

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
- Resource Policy;
- Recovery und Cleanup Policy;
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
- `TargetSqlVersionConstraints`;
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

## 5. SQL-Server-Versionen und Versionskatalog

### 5.1 Versionsoffener Vertrag

SQL-Server-Versionen werden nicht als dauerhaftes Enum `2019|2022|2025` in den Core-Schemas festgeschrieben.

**Derzeit** sind SQL Server 2019, SQL Server 2022 und SQL Server 2025 die vorgesehenen aktiven Versionseinträge. Neue Versionen müssen später über Katalog- und Capability-Daten ergänzt werden können, ohne den Package-, Workflow-, State- oder Providervertrag neu zu entwerfen.

Ein Package referenziert:

- eine konkrete `VersionRef`;
- eine Major-Version;
- oder eine Version Constraint, beispielsweise Mindestversion, Maximalversion oder Capability-Anforderung.

### 5.2 Versionseintrag

Ein Versionseintrag enthält mindestens:

- `VersionId`;
- Produktbezeichnung;
- `ProductMajorVersion`;
- Versionsstatus;
- unterstützte Betriebssystemfamilien;
- unterstützte Editions;
- unterstützte Compatibility Levels;
- Provider Support für Hyper-V, Docker und Podman;
- Image-, Repository- oder lokale Medienreferenzen;
- erforderliche SQL-Capabilities;
- bekannte Einschränkungen;
- Upgrade- und Restore-Kompatibilitätsregeln;
- Default-Ressourcenempfehlungen;
- Quellen- und Prüfstand.

Vorgesehene Versionsstatus:

```text
EXPERIMENTAL
SUPPORTED
DEPRECATED
RETIRED
BLOCKED
```

`RETIRED` entfernt keine historische Vertragsdefinition. Der Planner lehnt neue Runs mit einem strukturierten Status ab, sofern kein ausdrücklich zugelassener Legacy-Modus existiert.

### 5.3 Erweiterung und Ausgrenzung

Das Hinzufügen einer neuen SQL-Server-Version soll im Regelfall nur folgende Änderungen erfordern:

1. neuen Versionseintrag anlegen;
2. Provider-Mappings und Medien-/Imageauflösung ergänzen;
3. Capability-Matrix ergänzen;
4. Ressourcenprofile prüfen;
5. lokale Smoke-, Lifecycle- und Restore-Tests ausführen;
6. Status nach erfolgreicher Validierung von `EXPERIMENTAL` auf `SUPPORTED` setzen.

Das Ausgrenzen einer alten Version erfolgt über den Versionsstatus und Provider Support, nicht durch Entfernen von Feldern aus Core-Schemas.

## 6. Environment Blueprint

### 6.1 Primäre SQL-Komponenten

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
- Data-, Log-, TempDB-, Backup- und Artifact-Storage Claims;
- Netzwerkinterfaces;
- Required Capabilities;
- Lifecycle Policy;
- exportierte SQL Bindings.

### 6.2 Supporting Components

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

### 6.3 Management Modes

```text
PROVISIONED
ATTACHED
EXTERNAL_READ_ONLY
EXTERNAL_MUTABLE
EMULATED
FIXTURE
```

`EXTERNAL_MUTABLE` ist standardmäßig blockiert. Ein produktiver Endpoint ist kein zulässiges Standardtarget.

## 7. Beziehungen

Typisierte Beziehungen verbinden SQL- und Supporting Components.

Beispiele:

```text
connects-to
replicates-to
authenticates-against
joined-to-domain
reads-external-data-from
restores-from
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

## 8. Composite SQL-Topologien

Komplexe SQL-Konstellationen dürfen als Composite Component beschrieben und anschließend expandiert werden.

Beispiele:

- Availability Group → primäre und sekundäre Instanzen, Listener, optional Domain/DNS/Witness;
- FCI → Cluster Nodes, Shared Storage, Domain/DNS und SQL-Rolle;
- Replication → Publisher, Distributor, Subscriber und Workload Driver;
- PolyBase → SQL-Instanz, Hadoop- oder Object-Storage-Supporting-Component und DataSet;
- Security Lab → SQL-Instanz, Domain Controller, Accounts und Client.

Der Expander erzeugt logische Components und Relations. Die konkrete Providerzuordnung erfolgt erst danach.

## 9. Deployment Units und Action Types

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

SQL-nahe Action Types:

```text
mssql.script.execute
mssql.database.create
mssql.database.drop-marked
mssql.backup.create
mssql.backup.inspect
mssql.backup.restore
mssql.database.verify
mssql.query.execute
mssql.wait-for-ready
mssql.assert.version
mssql.assert.object
mssql.agent.configure
mssql.session.start
mssql.session.stop
```

Supporting Actions:

```text
powershell.script.execute
shell.script.execute
core.file.copy
core.artifact.download
core.artifact.verify
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

## 10. DataSets und Datenbankartefakte

### 10.1 Grundsatz

Testdaten werden nicht als unsichtbarer Nebeneffekt eines Setup-Skripts behandelt. Ein DataSet kann erzeugt, aus einer öffentlichen Beispieldatenbank geladen oder aus einem zulässigen Datenbankartefakt wiederhergestellt werden.

Eine `DataSetDefinition` enthält:

- `DataSetId`;
- SQL- oder Supporting-Target;
- `CreationMode`;
- Generator, Fixture oder `DatabaseArtifactRef`;
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
LOAD_PUBLIC_SAMPLE
RESTORE_LAB_ARTIFACT
RESTORE_USER_NON_PRODUCTION_ARTIFACT
DERIVE
STREAM
```

### 10.2 Zulässige Datenbankartefakte

Zulässig sind:

1. **Lab-erzeugte Backups**  
   Backups einer synthetischen oder anderweitig zulässigen Labdatenbank dürfen lokal erzeugt, außerhalb des Repositorys gespeichert, versioniert referenziert und in späteren Runs wiederverwendet werden.

2. **Öffentliche Demo- und Beispieldatenbanken**  
   Öffentlich bereitgestellte Beispieldatenbanken dürfen automatisiert heruntergeladen, gecacht und wiederhergestellt werden, wenn Quelle, Lizenz, Hash beziehungsweise Prüfsumme und unterstützte SQL-Version dokumentiert sind.

3. **Lokal bereitgestellte Nicht-Produktionsbackups**  
   Ein Benutzer darf ein lokales Backup einer Entwicklungs-, Test- oder selbst aufgebauten Labdatenbank anbinden. Das Artefakt wird nicht automatisch in das Repository kopiert oder übertragen. Vor Nutzung sind Klassifikation, Scope, Hash, Größe, Restore-Kompatibilität und Cleanup-Regel zu erfassen.

Unzulässig bleiben:

- Produktionsbackups;
- aus realen Produktivsystemen extrahierte oder nicht ausreichend klassifizierte Daten;
- Artefakte mit unbekannter Herkunft;
- Backups mit eingebetteten Secrets oder nicht freigegebenen realen Personen-, Kunden-, Firmen-, Organisations- oder Umgebungsdaten;
- automatische Übernahme lokaler Backups in Git, Issues, PRs oder Downloadpakete.

### 10.3 Database Artifact Definition

Eine `DatabaseArtifactDefinition` enthält mindestens:

- `ArtifactId`;
- `ArtifactClass`;
- `SourceType`;
- lokale Referenz oder öffentliche Downloadreferenz;
- Hash beziehungsweise Prüfsumme;
- Größe des Artefakts;
- erwartete entpackte beziehungsweise wiederhergestellte Größe;
- Lizenz- und Quellenhinweis;
- Data Classification;
- unterstützte Quell- und Zielversionen;
- Verschlüsselungs- und Credential Requirements;
- `RestoreFileMappingPolicy`;
- Verifikationsaktionen;
- Cache-, Retention- und Cleanup Policy;
- Export Policy.

Artifact Classes:

```text
LAB_GENERATED
PUBLIC_SAMPLE
USER_PROVIDED_NON_PRODUCTION
PRODUCTION_DATA
UNKNOWN
```

`PRODUCTION_DATA` und `UNKNOWN` sind blockiert.

### 10.4 Restore-Plan

Vor einem Restore werden, soweit technisch möglich, mindestens geprüft:

- Datei- und Backupmetadaten;
- vollständige Backupkette bei mehrteiligen Artefakten;
- SQL-Server-Versionskompatibilität;
- erwartete Data-, Log- und FILESTREAM-Dateien;
- benötigter freier Speicher nach Restore, nicht nur Backupgröße;
- Zielpfade und `WITH MOVE`-Bindings;
- Datenbankname und Marker;
- vorhandene Zieldatenbank und Konfliktpolicy;
- Berechtigungen;
- Verschlüsselungs- oder Credential-Anforderungen;
- Restore-Timeout;
- Verifikations- und Cleanup-Schritte.

Nach Restore folgen mindestens SQL Readiness, Datenbankstatus, Markerprüfung und packagespezifische Integritäts- oder Objektprüfungen. `DBCC CHECKDB` kann abhängig von Größe und Szenario als optionale oder erforderliche Verifikation definiert werden.

### 10.5 Öffentliche Beispiele

Der Lab-Core enthält keine feste Liste aller Demo-Datenbanken. Ein versionierter Public-Sample-Katalog kann beispielsweise AdventureWorks- oder WideWorldImporters-Artefakte referenzieren. Der Katalog hält Quelle, Lizenz, Hash, Größe, Zielversion und bekannte Einschränkungen. Ein Download benötigt eine explizit zulässige Egress-Policy.

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
binding.database-artifact.local-path
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

## 13. Ressourcen-Preflight und Resource Assessment

### 13.1 Prüfbereiche

Vor jeder Mutation prüft der Planner mindestens:

- physische und logische CPU-Kapazität;
- aktuell verfügbare CPU-Kapazität, soweit sinnvoll messbar;
- physischen und aktuell verfügbaren RAM;
- Hypervisor- oder Container-Runtime-Overhead;
- freien Speicher je gebundener Storage-Rolle;
- voraussichtlichen Peakbedarf für Images, VHDX, Container-Layer, Data, Log, TempDB, Backups, Downloads, entpackte Dateien und Restore;
- Port- und Netzwerkverfügbarkeit;
- Virtualisierungs- und Provider-Capabilities;
- erforderliche lokale Medien und Images;
- Schreibrechte und sichere Zielpfade;
- bereits vorhandene Lab-Ressourcen;
- Hostreserve während Aufbau, Betrieb und Cleanup.

### 13.2 Ergebnisstatus

```text
RESOURCE_OK
RESOURCE_WARNING
RESOURCE_INSUFFICIENT_OVERRIDABLE
RESOURCE_HARD_BLOCK
RESOURCE_UNKNOWN
```

Der Plan zeigt je Ressourcendimension mindestens:

- ermittelten Istwert;
- geschätzten Bedarf;
- geplante Hostreserve;
- erwartetes Defizit oder verbleibende Reserve;
- Schätzqualität;
- Override-Möglichkeit;
- mögliche Fehlerfolge;
- Cleanup-Auswirkung.

### 13.3 Bewusster Resource Override

Eine vorhergesagte Unterversorgung darf die Installation nicht automatisch verhindern.

Ein Run mit `RESOURCE_INSUFFICIENT_OVERRIDABLE` kann nach expliziter Bestätigung gestartet werden, beispielsweise über eine semantische Option wie:

```text
AllowResourceOvercommit = true
```

Der Override:

- wird im lokalen Run State mit Zeitpunkt, Scope und betroffenen Ressourcendimensionen dokumentiert;
- ändert keine ermittelten Werte;
- täuscht keinen `RESOURCE_OK`-Status vor;
- setzt Timeouts, Failure Policy und Cleanup nicht außer Kraft;
- erlaubt keine unbeschränkte Ressourcenzuteilung;
- darf nur innerhalb der absoluten Safety Limits des Packages und Providers wirken.

Nicht übersteuerbar sind insbesondere:

- unsichere oder nicht scope-gebundene Zielpfade;
- fehlende Provider- oder Virtualisierungsfähigkeit;
- fehlende Rechte für die geplante Mutation;
- unbekannte oder blockierte SQL-Server-Version;
- unzulässige Datenklassifikation;
- fehlender Cleanup Plan;
- unauflösbare Secret-, Medien- oder Lizenzvoraussetzungen;
- Mutation fremder oder nicht eindeutig zuordenbarer Ressourcen.

## 14. Recovery- und Cleanup-Vertrag

### 14.1 Cleanup Plan vor Mutation

Vor der ersten Mutation muss ein maschinenlesbarer Cleanup Plan vorliegen. Er enthält:

- alle geplanten Ressourcenklassen;
- logische Owner- und Scope-Marker;
- erwartete Providerobjekte;
- Abhängigkeits- und Löschreihenfolge;
- Step Compensations;
- DataSet-, Backup-, Cache- und Secret-Retention;
- Timeouts und Retry-Grenzen;
- Recovery-Einstiegspunkte;
- erwarteten Endzustand.

Ohne validierten Cleanup Plan darf `Provision` nicht beginnen.

### 14.2 Operation Journal

Vor der ersten Mutation wird ein lokaler Run State angelegt. Jede Mutation wird vor Ausführung als `PLANNED` und unmittelbar danach mit tatsächlichen Objekt-IDs und Ergebnisstatus protokolliert.

Namen allein genügen nicht für Cleanup. Soweit Provider tatsächliche IDs liefern, werden diese zusammen mit Owner Marker und Run ID verwendet.

### 14.3 Automatisches Cleanup bei Fehler

Scheitert Provisionierung, Restore, Installation oder Szenarioausführung, startet die Lifecycle Engine standardmäßig die Compensation in umgekehrter Abhängigkeitsreihenfolge.

Ergebnisstatus:

```text
CLEANUP_SUCCEEDED
CLEANUP_PARTIAL
RECOVERY_REQUIRED
CLEANUP_BLOCKED
```

Ein fachlicher `PASS` ist nur zulässig, wenn erforderliches Cleanup erfolgreich war oder der Package-Vertrag ausdrücklich einen persistenten Endzustand vorsieht.

### 14.4 Wiederaufnehmbarer Cleanup

Für Hostabbruch, Prozessabsturz oder partielles Provider-Versagen bleibt der lokale Recovery State erhalten. Die öffentliche Bedienoberfläche muss einen erneuten, idempotenten Cleanup erlauben, beispielsweise:

```text
ResumeCleanup
DestroyRun
RecoverRun
```

Der Recovery-Lauf:

- liest den registrierten Soll-/Ist-Zustand;
- validiert Owner Marker, Run ID und tatsächliche Objekt-IDs erneut;
- führt nur noch offene Compensation-Schritte aus;
- entfernt keine fremden Ressourcen;
- endet erst bei `CLEANUP_SUCCEEDED` oder mit einem präzisen `RECOVERY_REQUIRED`.

Ein absoluter Ausschluss verwaister Ressourcen kann bei Hostausfall, Dateisystemschaden oder externem Providerverlust nicht garantiert werden. Der verpflichtende State-, Marker-, ID- und Recovery-Vertrag stellt jedoch sicher, dass ein deterministischer automatischer Aufräumpfad vorhanden ist und offene Reste sichtbar bleiben.

## 15. Providervertrag

Verbindliche Kernprovider:

```text
provider.hyperv
provider.docker
provider.podman
```

Jeder Provider implementiert mindestens:

- `DetectCapabilities`;
- `ValidateResourceGraph`;
- `AssessResources`;
- read-only `Plan`;
- `Provision`;
- `GetStatus`;
- `Stop` und `Start`;
- `Reset`, soweit unterstützt;
- `Destroy`;
- `ResumeCleanup`;
- `ExecuteInResource`, soweit unterstützt;
- Rückgabe tatsächlicher Ressourcen-IDs und Bindings.

Provider dürfen keine projektspezifischen Testdaten, SQL-Findings oder Schulungsaussagen besitzen.

Docker und Podman bleiben getrennte Provider. Eine erfolgreiche Docker-Ausführung gilt nicht automatisch als Podman-Nachweis.

## 16. Beispiele

### 16.1 SQL Performance Schulung mit erzeugten Daten

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

### 16.2 SQL Performance Schulung mit öffentlicher Demo-Datenbank

```text
sql-primary: mssql.instance
artifact: PUBLIC_SAMPLE
dataset-mode: LOAD_PUBLIC_SAMPLE

Resolve versioned public-sample catalog entry
Download or use verified local cache
Verify hash and license metadata
Assess restored storage requirement
Restore with provider-bound file mappings
Verify database and required objects
Run demo
Cleanup database; retain or remove cache according to policy
```

### 16.3 Fortsetzung eines Labstands über Backup

```text
Run A:
  Create synthetic lab database
  Execute development or demo preparation
  Create LAB_GENERATED backup
  Persist backup in ignored local artifact store
  Record hash, SQL version, size and classification

Run B:
  Bind the previous artifact locally
  Inspect and verify backup
  Restore into new marked lab database
  Continue work
  Cleanup according to selected retention policy
```

### 16.4 SQL Server Analyze

```text
sql-primary: mssql.instance
workload-driver: client.sql-workload-driver
optional network-fault-controller

Install framework
Create or restore allowed test database
Create blocking/tempdb/io condition
Run analyzer probes
Assert finding and status codes
Cleanup
```

### 16.5 SQL Server plus Domain Controller

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

### 16.6 SQL Server PolyBase plus Hadoop

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

## 17. Control Plane

Die erste Bedienoberfläche ist PowerShell. Der Core darf aber nicht an Konsolentext gekoppelt werden.

CLI und eine spätere REST- oder UI-Anbindung verwenden dieselben serialisierbaren Commands:

```text
GetCapabilities
GetSqlVersionCatalog
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
ResumeCleanup
RecoverRun
DestroyRun
ExportSanitizedSummary
```

Länger laufende Commands liefern eine `OperationId`. Status und Events werden strukturiert abgefragt. Eine spätere REST API ist nur Control-Plane-Adapter und dupliziert weder Provider- noch Package-Logik.

## 18. Trust- und Sicherheitsmodell

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

## 19. Erweiterungsmodell

| Extension Point | SQL-bezogener Zweck |
|---|---|
| SQL Version Catalog | neue SQL-Server-Version aktivieren oder alte Version kontrolliert ausgrenzen |
| Provider Plugin | neue technische Plattform für SQL-Server- oder Supporting Components |
| SQL Component-Type Pack | neue SQL-Server-Rolle oder Topologie |
| Supporting Component-Type Pack | benötigtes Hilfssystem für SQL-Szenario |
| Action-Type Pack | neue SQL-, Client-, Integrations- oder Beobachtungsaktion |
| Public Sample Catalog | öffentliche Demo-Datenbanken und zulässige Datenbankartefakte |
| Fault Pack | kontrollierte SQL-bezogene Fault Injection |
| Project Package | Analyze-, Schulungs- oder weiteres SQL-Projekt |
| Control-Plane Adapter | CLI, REST oder UI |
| Evidence Renderer | lokale oder sanitisierte Darstellung |

Supporting Extensions werden erst bei konkretem SQL-Anwendungsfall implementiert.

## 20. Anti-Patterns

Unzulässig:

1. ein Universal-`Setup.ps1`, das Provider, SQL-Installation, Testdaten, Workload und Cleanup untrennbar vermischt;
2. Compose- oder Hyper-V-Dateien als fachliche Projektschnittstelle;
3. reale Connection Strings oder Hostbindings in Packages;
4. Projektskripte, die fremde Container oder VMs direkt verwalten;
5. Testdaten oder Datenbankartefakte ohne Klassifikation, Verifikation und Cleanup-Regel;
6. Providerbefehle innerhalb fachlicher SQL-Szenarien;
7. Statusbestimmung durch Parsen von Konsolentext;
8. ein Package ohne SQL Purpose;
9. eine Supporting Component ohne dokumentierten SQL-Bezug;
10. feste SQL-Versions-Enums im Core-Schema;
11. Resource Override ohne dokumentiertes Defizit und Cleanup Plan;
12. vorauseilende Entwicklung einer allgemeinen Hadoop-, REST- oder Clusterplattform.

## 21. Implementierungsreihenfolge

### Schritt 1 – SQL-Core-Contracts

- Package und `SqlPurpose`;
- SQL Version Catalog;
- SQL Environment Blueprint;
- SQL-/Supporting-Component Type;
- Action Type;
- DataSet und Database Artifact;
- Resource Assessment und Override;
- Workflow;
- Runtime Binding;
- Bound Plan;
- Run State, Recovery State und Event.

### Schritt 2 – Built-in SQL Types

- `mssql.instance`;
- grundlegende Storage- und Network Claims;
- SQL Readiness;
- SQL Script, Query, Backup, Restore und Assertion Actions;
- Docker-, Podman- und Hyper-V-Mapping.

### Schritt 3 – Primärprojekte

- Quick Environment;
- Performance-Schulungs-Pilot;
- Analyze-Pilot;
- DataSet-, Workload-, Probe- und Cleanup-Verträge;
- Lab-Backup-Fortsetzung;
- mindestens eine öffentliche Demo-Datenbank.

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

## 22. Abnahmekriterien

Der Vertrag ist belastbar, wenn:

1. jedes Package einen SQL-Zweck beschreibt;
2. SQL-Versionen katalog- und constraintbasiert statt als dauerhaftes Enum behandelt werden;
3. derzeitige Versionen dokumentiert und neue beziehungsweise alte Versionen ohne Core-Neuentwurf ergänzt oder ausgesteuert werden können;
4. Umgebung, Installation, Testdaten, zulässige Backups, Workload, Observation und Cleanup vollständig modelliert werden;
5. Lab-erzeugte Backups und öffentliche Demo-Datenbanken wiederverwendbar sind;
6. Produktionsdaten und unklassifizierte Artefakte blockiert bleiben;
7. Hyper-V, Docker und Podman denselben übergeordneten Vertrag erfüllen;
8. Projekte keine Providerbefehle enthalten müssen;
9. DataSets und Database Artifacts verifizierbar, resetbar und bereinigbar sind;
10. Ressourcenbedarf für CPU, RAM, Storage und Provider-Overhead vor Mutation sichtbar ist;
11. vorhergesagte Ressourcenunterversorgung bewusst übersteuert werden kann, ohne Safety-Grenzen aufzuheben;
12. vor jeder Mutation ein vollständiger Cleanup Plan existiert;
13. fehlgeschlagene Installationen automatisches und wiederaufnehmbares Cleanup auslösen;
14. Inputs und Outputs typisiert verbunden werden;
15. Composite SQL-Topologien expandierbar sind;
16. Supporting Components einen dokumentierten SQL-Bezug besitzen;
17. SQL Server plus Domain Controller und später PolyBase plus Hadoop ohne Core-Neuentwurf modellierbar sind;
18. CLI und spätere REST Control Plane dieselben Commands, Results und Events verwenden;
19. alle Seiteneffekte, Secrets, Ressourcen und Cleanup-Grenzen vor Mutation planbar sind;
20. keine allgemeine Nicht-SQL-Labplattform entsteht.
