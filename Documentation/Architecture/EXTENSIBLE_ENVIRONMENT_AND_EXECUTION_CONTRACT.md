# Erweiterbarer Umgebungs- und Ausführungsvertrag

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_DECISION_DRAFT` |
| Stand | 2026-07-26 |
| Vertragsfamilie | `LAB_CORE_CONTRACTS` |
| Ausgangspunkt | SQL Server; ausdrücklich technologieoffen erweiterbar |
| Kritischer Zweck | Übersetzung einer fachlichen Konstellation in Umgebung, Installation, Testdaten, Workload, Beobachtung, Prüfung und Cleanup |

## 1. Zentrale Architekturentscheidung

**ENTSCHEIDUNG:** Ein konsumierendes Projekt übergibt dem Lab nicht bloß ein Setup-Skript und auch keine providerbezogene Compose- oder Hyper-V-Datei. Es liefert ein versioniertes, selbstbeschreibendes **Lab Package**.

Ein Lab Package beschreibt getrennt:

1. **was fachlich benötigt wird**;
2. **welche logischen Komponenten und Beziehungen erforderlich sind**;
3. **welche Inhalte in den Komponenten installiert oder erzeugt werden müssen**;
4. **welcher Ablauf den gewünschten Zustand erzeugt und prüft**;
5. **welche Outputs zwischen den Schritten weitergereicht werden**;
6. **welche Sicherheits-, Ressourcen-, Datenschutz- und Cleanup-Grenzen gelten**.

Das Lab löst diese Beschreibung gegen registrierte Component Types, Action Handlers, Provider und lokale Host-Capabilities auf. Erst daraus entsteht ein konkreter, read-only prüfbarer Ausführungsplan.

Diese Trennung ist die wichtigste Voraussetzung dafür, dass die Schnittstelle später nicht auf SQL Server, Docker, Hyper-V oder PowerShell beschränkt bleibt.

## 2. Warum ein einfacher Project Adapter nicht genügt

Ein Adapter mit festen Entrypoints wie `Install`, `Observe` und `Cleanup` beantwortet nur, **welches Skript** aufgerufen werden soll. Er beantwortet nicht ausreichend:

- wie viele Systeme benötigt werden;
- welche Rollen diese Systeme besitzen;
- wie sie miteinander verbunden sind;
- welche Versionen und Capabilities erforderlich sind;
- welche Software innerhalb welcher Rolle installiert wird;
- wie Testdaten erzeugt, verteilt und verifiziert werden;
- welche Schritte parallel oder sequenziell laufen;
- welche Outputs ein Schritt erzeugt und ein anderer benötigt;
- wie eine zusammengesetzte Umgebung wie ein Hadoop-Cluster expandiert wird;
- wie externe REST-Endpunkte gebunden werden;
- wie providerunabhängige Szenarien auf Docker, Podman, Hyper-V oder einem späteren Provider abgebildet werden.

Der **Project Adapter bleibt bestehen**, wird aber auf Discovery, Paketbindung und projektspezifische Vertrauensinformationen reduziert. Die eigentliche fachliche und technische Beschreibung liegt in Lab Packages und deren typisierten Manifesten.

## 3. Gesamtmodell

```text
Project Adapter / Package Catalog
              ↓
          Lab Package
              ↓
      Environment Blueprint
        + Content Bundle
        + Workflow Graph
        + Assertions
              ↓
 Component-Type- und Action-Type-Auflösung
              ↓
      Expanded Resource Graph
              ↓
 Capability Negotiation + lokale Bindings
              ↓
       Bound Execution Plan
              ↓
 Provider + Action Handlers + State Engine
              ↓
 Runtime Bindings + Events + Evidence + Cleanup
```

Das Modell besitzt fünf voneinander getrennte Zustände:

| Zustand | Inhalt | Mutierend? |
|---|---|---:|
| **Intent** | fachliche Anforderung und Constraints | Nein |
| **Desired State** | expandierter logischer Ressourcen- und Ablaufgraph | Nein |
| **Bound Plan** | konkrete Provider, lokale Bindings und geplante Mutationen | Nein |
| **Runtime State** | tatsächlich erzeugte Ressourcen, IDs, Endpunkte und Schrittstatus | Ja |
| **Evidence State** | technische lokale Evidenz und getrennte sanitisierte Summary | Nein, außer lokale Artefakterzeugung |

## 4. Lab Package

### 4.1 Inhalt

Ein Lab Package besteht konzeptionell aus:

```text
<PackageRoot>/
├── package.manifest.json
├── Catalog/
│   ├── Environments/
│   ├── Scenarios/
│   ├── DataSets/
│   ├── Workloads/
│   └── Assertions/
├── Content/
│   ├── Sql/
│   ├── PowerShell/
│   ├── Shell/
│   ├── Http/
│   ├── Hadoop/
│   └── Files/
└── Documentation/
```

Die Verzeichnisnamen sind ein Zielbild. Entscheidend ist die logische Trennung, nicht die frühe Festschreibung jedes physischen Pfades.

### 4.2 `package.manifest.json`

Das Package Manifest enthält mindestens:

- `PackageContractVersion`;
- `PackageId`;
- `PackageVersion`;
- `ProjectId`;
- `DisplayName`;
- `MinimumLabCoreVersion`;
- `SupportedLabCoreVersions`;
- `EnvironmentCatalog`;
- `ScenarioCatalog`;
- `RequiredComponentTypes`;
- `RequiredActionTypes`;
- `RequiredCapabilities`;
- `Artifacts` mit Hashes;
- `SecretRequirements` ohne Werte;
- `TrustClass`;
- `DataClassification`;
- `LicenseNotice`;
- `PrivacyExportPolicy`;
- `KnownLimitations`.

### 4.3 Paketklassen

| Klasse | Inhalt | Ausführbarer Erweiterungscode? |
|---|---|---:|
| `DECLARATIVE` | ausschließlich bekannte Component Types, Actions und Artefakte | Nein |
| `CONTENT` | Skripte, Testdaten-Generatoren, Workloads und Assertions für registrierte Handler | Skripte als kontrollierter Inhalt |
| `TRUSTED_EXTENSION` | neue Component-Type-Expander oder Action Handler | Ja, nur nach ausdrücklicher lokaler Freigabe |
| `PROVIDER_EXTENSION` | neuer Infrastrukturprovider | Ja, höchste Vertrauens- und Testanforderung |

Ein normales Projektpaket soll möglichst `DECLARATIVE` oder `CONTENT` bleiben. Neue Technologieunterstützung wird nicht durch beliebigen Code in jedem Szenario, sondern durch versionierte, registrierte Erweiterungspakete bereitgestellt.

## 5. Environment Blueprint

### 5.1 Zweck

Das Environment Blueprint beschreibt den fachlich gewünschten Aufbau. Es enthält keine Docker-Container-IDs, Hyper-V-VM-Namen, realen IP-Adressen oder Hostpfade.

### 5.2 Komponenten statt fest verdrahteter SQL-Instanzen

Eine Komponente besitzt mindestens:

- `ComponentId`;
- `ComponentType`;
- `ComponentTypeVersion`;
- `Role`;
- `ManagementMode`;
- `VersionConstraint`;
- `Scale`;
- `PlacementConstraints`;
- `ResourceRequirements`;
- `CapabilityRequirements`;
- `Configuration`;
- `Interfaces`;
- `StorageClaims`;
- `Exports`;
- `Dependencies`;
- `LifecyclePolicy`;
- `DataClassification`.

### 5.3 Namespaced Component Types

Component Types sind namespaced und nicht auf SQL Server beschränkt.

Beispiele:

```text
core.host
core.vm
core.container
core.network
core.storage
core.external-endpoint
mssql.instance
mssql.availability-group
mssql.load-generator
hadoop.cluster
hadoop.namenode
hadoop.datanode
http.service
http.mock-service
observability.collector
```

Der Core kennt nur den generischen Component-Vertrag. Technologiebezogene Semantik kommt aus registrierten Component-Type-Definitionen.

### 5.4 Composite Components

Eine Composite Component beschreibt eine fachliche Einheit, die in mehrere Ressourcen expandiert werden kann.

Beispiel:

```text
hadoop.cluster
  Scale.Workers = 3
```

Ein registrierter `hadoop.cluster`-Expander kann daraus erzeugen:

- einen NameNode;
- drei DataNodes;
- optionale ResourceManager-/NodeManager-Rollen;
- interne Netzwerke;
- Storage Claims;
- Health-Probes;
- exportierte HDFS- und Management-Endpunkte.

Das konsumierende Projekt muss weder konkrete VM-Anzahlen noch Providerbefehle kennen. Eine spätere Clustertechnologie wird durch einen neuen Component Type ergänzt, nicht durch einen Breaking Change des Lab-Core-Vertrags.

### 5.5 Management Modes

| Modus | Bedeutung |
|---|---|
| `PROVISIONED` | Lab erstellt und verwaltet die Komponente vollständig |
| `ATTACHED` | Komponente existiert lokal und wird anhand einer expliziten Binding-Datei eingebunden |
| `EXTERNAL_READ_ONLY` | externer Dienst wird nur gelesen oder auf Erreichbarkeit geprüft |
| `EXTERNAL_MUTABLE` | externer Testdienst darf im ausdrücklich freigegebenen Scope verändert werden |
| `EMULATED` | Komponente wird durch eine klar gekennzeichnete Emulation ersetzt |
| `FIXTURE` | nur Vertrags- oder Parserprüfung, kein realer Laufzeitnachweis |

`EXTERNAL_MUTABLE` ist standardmäßig blockiert und verlangt eine separate Vertrauens-, Netzwerk- und Cleanup-Freigabe. Produktive Endpunkte sind kein zulässiger Standardtarget.

## 6. Beziehungen und Datenflüsse

Komponenten werden durch typisierte Links verbunden. Beispiele:

```text
depends-on
network-connects-to
replicates-to
reads-from
writes-to
calls-http
submits-job-to
observes
fault-targets
```

Ein Link beschreibt:

- Quell- und Zielkomponente;
- Link Type;
- erforderliche Interfaces;
- Netzwerk- oder Sicherheitsconstraints;
- Datenflussrichtung;
- Health- und Readiness-Abhängigkeit;
- optionale Bandbreiten-, Latenz- oder Isolationserfordernisse.

Neue Link Types werden namespaced registriert. Der Core behandelt sie als typisierte Constraints und überlässt technologiespezifische Validierung dem zuständigen Expander oder Handler.

## 7. Component-Type-Definition

Jeder registrierte Component Type veröffentlicht einen maschinenlesbaren Vertrag:

- eindeutiger `TypeId` und Version;
- Schema für `Configuration`;
- benötigte Capabilities;
- erlaubte Management Modes;
- unterstützte Providerklassen;
- Expansionslogik für Composite Components;
- Health- und Readiness-Probes;
- exportierte Binding-Typen;
- zulässige Actions;
- Lifecycle- und Cleanup-Vertrag;
- Safety Class;
- lokale Artefaktarten;
- bekannte Aussagegrenzen.

Beispiel `mssql.instance`:

```text
Inputs:
  ProductMajorVersion
  EditionClass
  OperatingSystemFamily
  AgentRequired
  AuthenticationModes
  Collation
  StorageClaims

Exports:
  endpoint.sql
  credential-ref.sql-admin
  metadata.product-version
  metadata.engine-edition
  capability.sql-agent
  capability.windows-authentication
```

Beispiel `http.service`:

```text
Inputs:
  Protocol
  VersionConstraint
  HealthPath
  AuthenticationRequirement

Exports:
  endpoint.http-base
  credential-ref.http-client
  metadata.api-version
```

## 8. Inhalte innerhalb der Installationen

### 8.1 Deployment Units

Alles, was **innerhalb** einer Komponente installiert, konfiguriert oder ausgeführt werden muss, wird als Deployment Unit beschrieben.

Eine Deployment Unit enthält:

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

### 8.2 Namespaced Action Types

Beispiele:

```text
core.file.copy
core.archive.extract
core.process.execute
powershell.script.execute
shell.script.execute
mssql.script.execute
mssql.database.create
mssql.backup.restore
mssql.query.execute
http.request.execute
http.openapi.validate
hadoop.hdfs.put
hadoop.job.submit
hadoop.job.wait
fault.network.apply
fault.network.remove
fault.storage.apply
fault.storage.remove
```

Der Core führt keinen unbekannten Action Type aus. Ein Action Handler muss registriert, versioniert und mit einem Input-/Output-Schema beschrieben sein.

### 8.3 Action-Handler-Vertrag

Ein Action Handler stellt mindestens bereit:

- `Validate`;
- `Plan`;
- `Execute`;
- `GetStatus`;
- `Cancel`, sofern technisch möglich;
- `Compensate` oder einen expliziten Nicht-Kompensierbarkeitsstatus;
- Input- und Output-Schema;
- benötigte Component- und Capability-Typen;
- Secret-Injection-Modi;
- Side-Effect- und Safety-Klasse;
- Idempotenzvertrag;
- Log- und Redaction-Regeln.

Damit kann später beispielsweise ein `hadoop.job.submit`-Handler ergänzt werden, ohne den Workflow- oder Environment-Vertrag zu ändern.

## 9. Testdatenvertrag

### 9.1 Testdaten sind ein eigener Vertrag

Testdaten werden nicht implizit als Nebeneffekt eines Setup-Skripts behandelt. Ein Szenario referenziert eine oder mehrere `DataSetDefinition`-Einheiten.

### 9.2 `DataSetDefinition`

Pflichtinformationen:

- `DataSetId`;
- `TargetComponentRef`;
- `CreationMode`;
- `GeneratorActionType` oder `FixtureRef`;
- `DeterministicSeed` oder begründete Abweichung;
- `ScaleProfile`;
- `DistributionProfile`;
- `Preconditions`;
- `CompletionSignal`;
- `VerificationActions`;
- `Exports`;
- `ResetPolicy`;
- `CleanupPolicy`;
- `DataClassification`;
- `KnownVariability`.

### 9.3 Creation Modes

| Modus | Bedeutung |
|---|---|
| `GENERATE` | Daten werden reproduzierbar im Zielsystem erzeugt |
| `LOAD_PUBLIC_FIXTURE` | veröffentlichte, lizenz- und privacy-geprüfte Fixture |
| `RESTORE_SYNTHETIC_ARTIFACT` | synthetisches, hashgebundenes Backup oder Image |
| `DERIVE` | Daten werden aus anderen synthetischen Daten transformiert |
| `STREAM` | Daten werden während des Szenarios kontrolliert erzeugt |

Reale Produktionsbackups oder aus realen Systemen extrahierte Daten sind kein zulässiger Package-Inhalt.

### 9.4 Beispiel SQL-Performance-Demo

```text
DataSetId: SQLPERF-SKEW-001
Target: component sql-primary
CreationMode: GENERATE
ScaleProfile: Medium
DistributionProfile: HighlySkewed
Generator: mssql.script.execute
Verification:
  - erwartete Tabellenmarker
  - erwartete Zeilenbandbreite
  - erwartete Statistikexistenz
Exports:
  - binding.database.demo
  - binding.dataset.marker
```

Der Workflow verwendet anschließend die exportierte Datenbankbindung und muss keinen realen Datenbanknamen kennen.

## 10. Workflow Graph

### 10.1 Entscheidung

`Arrange`, `Act`, `Observe`, `Assert` und `Cleanup` bleiben als verständliche **semantische Phasen** erhalten. Technisch wird ein Szenario jedoch als gerichteter, azyklischer Workflow Graph modelliert.

Der Grund: Zukünftige Szenarien benötigen mehrere Installations-, Daten-, Service-, Job-, Beobachtungs- oder Vergleichsschritte und teilweise kontrollierte Parallelität.

### 10.2 Workflow Step

Jeder Step enthält:

- `StepId`;
- `Phase`;
- `ActionType`;
- `TargetRef`;
- `Inputs`;
- `SecretRefs`;
- `DependsOn`;
- `Condition`;
- `ConcurrencyGroup`;
- `TimeoutSeconds`;
- `RetryPolicy`;
- `FailurePolicy`;
- `IdempotencyMode`;
- `Produces`;
- `Compensation`;
- `AlwaysRun`;
- `SafetyClass`.

### 10.3 Kontrollierte Wiederholung

Unbegrenzte Schleifen sind im deklarativen Vertrag unzulässig. Wiederholung wird nur mit harten Grenzen unterstützt:

- `MaxAttempts`;
- `MaxDurationSeconds`;
- `UntilCondition`;
- `BackoffPolicy`.

### 10.4 Parallelität

Parallelität wird über explizite Abhängigkeiten und `ConcurrencyGroup` gesteuert. Ressourcenprofile und Hostreserve begrenzen die tatsächlich zulässige Parallelität.

### 10.5 Cleanup und Compensation

- Jeder mutierende Step muss angeben, ob und wie er kompensiert wird.
- Nach begonnenem `Arrange` wird Cleanup unabhängig vom fachlichen Ergebnis versucht.
- `AlwaysRun`-Cleanup-Schritte besitzen ein eigenes Zeitbudget.
- Der Runtime State hält die tatsächlich erfolgreich abgeschlossenen Mutationen in Reihenfolge.
- Cleanup arbeitet mit registrierten Objekt-IDs und Bindings, nicht mit bloßen Namen.
- Nicht vollständig kompensierbare Zustände ergeben `RECOVERY_REQUIRED`.

## 11. Runtime Bindings

### 11.1 Zweck

Statische Manifeste dürfen keine lokalen Endpunkte, Secrets oder Pfade enthalten. Der Planner und die Provider erzeugen deshalb zur Laufzeit typisierte Bindings.

### 11.2 Binding-Beispiele

```text
binding.sql-primary.endpoint.sql
binding.sql-primary.credential-ref.admin
binding.sql-primary.database.system
binding.api-under-test.endpoint.http-base
binding.hadoop-cluster.endpoint.hdfs
binding.hadoop-cluster.endpoint.resource-manager
binding.dataset-skew.database.name
binding.artifacts.local-root
```

### 11.3 Binding-Vertrag

Ein Binding besitzt:

- `BindingId`;
- `BindingType`;
- `ProducerRef`;
- `ValueClass`;
- `SensitivityClass`;
- `Scope`;
- `Lifetime`;
- `ConsumerAllowlist`;
- `ExportPolicy`;
- `ActualValue` nur im lokalen Runtime State.

### 11.4 Secret Bindings

Secrets werden ausschließlich als Referenz weitergereicht:

```text
credential-ref.sql-admin
credential-ref.http-client
credential-ref.ssh-guest
```

Der Action Handler fordert den Wert über den Secret Provider an. Er schreibt ihn nicht in Plan, Event, Evidence oder Command Line, sofern ein sichererer Injection-Modus verfügbar ist.

## 12. Input- und Output-Verkettung

Ein Step darf Outputs früherer Schritte referenzieren:

```text
Inputs.TargetDatabase = ${bindings.dataset-skew.database.name}
Inputs.SqlEndpoint     = ${bindings.sql-primary.endpoint.sql}
Inputs.AdminCredential = ${bindings.sql-primary.credential-ref.admin}
```

Referenzen werden vor Ausführung typ- und scopesicher geprüft. Ein HTTP-Endpunkt kann nicht versehentlich als SQL-Endpunkt verwendet werden. Ein Secret Binding darf nicht in einen normalen Stringoutput aufgelöst werden.

## 13. Beispiel: SQL Server Performance Schulung

### 13.1 Environment Blueprint

```text
component sql-primary
  type: mssql.instance
  version: 2022
  role: primary
  resources: Standard

component load-driver
  type: mssql.load-generator
  placement: host-or-sidecar

link load-driver -> sql-primary
  type: connects-to
  interface: endpoint.sql
```

### 13.2 Content Bundle

- Framework-Deployment-Unit;
- Demo-Setup-Skripte;
- deterministischer DataSet Generator;
- Baseline Query;
- Demonstrationsworkload;
- Observation Queries;
- Gegenmaßnahme;
- Vergleichsassertionen;
- Cleanup.

### 13.3 Workflow

```text
PreflightDemo
  -> InstallDemoFramework
  -> CreateSyntheticDatabase
  -> GenerateDataSet
  -> VerifyDataSet
  -> CaptureBaseline
  -> RunDemonstration
  -> ObserveEffect
  -> ApplyMitigation
  -> CaptureComparison
  -> AssertDirectionAndInvariants
  -> CleanupDemo
```

Das Lab kennt nicht die fachliche Bedeutung eines `Key Lookup` oder einer Statistikschieflage. Es kennt jedoch Target, Reihenfolge, Handler, Timeouts, Outputs, Safety Class und Cleanup.

## 14. Beispiel: SQL Server Analyze

### 14.1 Environment Blueprint

```text
component sql-primary
  type: mssql.instance
  version-constraint: 2019|2022|2025

component workload-driver
  type: mssql.load-generator

optional component network-fault
  type: core.network-fault-controller
```

### 14.2 Package-Inhalt

- Frameworkinstallation;
- synthetische Datenbank;
- gezielte Blocking-, TempDB-, I/O- oder Memory-Konstellation;
- Analyzer-Aufrufe;
- erwartete Finding- und Statuscodes;
- lokale technische Evidenz;
- Cleanup.

Das Analyze-Projekt besitzt die fachlichen Assertions. Das Lab besitzt Bereitstellung, Fault Controller und Lifecycle.

## 15. Beispiel: Hadoop-Cluster als spätere Erweiterung

### 15.1 Ohne Änderung des Core-Vertrags

Ein Erweiterungspaket registriert:

```text
Component Type: hadoop.cluster
Action Types:
  hadoop.hdfs.put
  hadoop.job.submit
  hadoop.job.wait
  hadoop.hdfs.assert
```

Ein Szenario kann dann deklarieren:

```text
component analytics-cluster
  type: hadoop.cluster
  version-constraint: <freigegebene Version>
  scale.workers: 3
  resources: Standard

component sql-source
  type: mssql.instance

link sql-source -> analytics-cluster
  type: data-flow
```

Der `hadoop.cluster`-Expander entscheidet, welche Rollen und Providerressourcen erforderlich sind. Der Lab Core benötigt keine Hadoop-spezifischen Pflichtfelder.

### 15.2 SQL-Server-Bezug bleibt möglich

Ein zukünftiges Szenario könnte:

- synthetische Daten in SQL Server erzeugen;
- sie über einen registrierten Transfer-Handler in HDFS laden;
- einen Hadoop-Job starten;
- das Resultat über REST oder Dateioutput prüfen;
- SQL- und Cluster-Evidenz gemeinsam auswerten.

Die Technologiegrenze wird durch Component Types und Actions erweitert, nicht durch eine neue parallele Orchestrierung.

## 16. Beispiel: REST-API-Zugriff

### 16.1 Bereitgestellter Testdienst

```text
component api-under-test
  type: http.service
  management-mode: PROVISIONED

component sql-backend
  type: mssql.instance

link api-under-test -> sql-backend
  type: connects-to
```

Deployment Units können eine API-Anwendung installieren, Konfiguration über Runtime Bindings injizieren und Healthchecks ausführen.

### 16.2 Externer Testendpunkt

```text
component external-api
  type: core.external-endpoint
  management-mode: EXTERNAL_READ_ONLY
```

Der konkrete Endpoint wird nur lokal gebunden. Der Planner prüft Egress-Policy, zulässigen Scope und Secret-Anforderungen. Ein externer produktiver Dienst wird nicht automatisch akzeptiert.

### 16.3 REST als Action Type

`http.request.execute` kann:

- Methode, relative Route und erwarteten Status aufnehmen;
- Requestdaten aus synthetischen Artefakten beziehen;
- Credentials als Secret Binding erhalten;
- strukturierte Responsefelder als Bindings exportieren;
- sensible Responseinhalte von exportierbaren Evidenzen ausschließen.

## 17. Control Plane und zukünftige REST-Steuerung des Labs

### 17.1 Entscheidung

Die erste Bedienoberfläche kann PowerShell sein. Der Core-Vertrag darf aber nicht an Konsolenausgabe oder direkte Funktionsaufrufe gekoppelt werden.

CLI und eine spätere REST API müssen dieselben serialisierbaren Commands und Results verwenden.

### 17.2 Geplante Commands

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

### 17.3 Operation Model

Länger laufende Befehle liefern einen `OperationId`. Status und Events werden separat abgefragt. Die lokale CLI kann weiterhin synchron warten und Fortschritt anzeigen.

Ein Operation Record enthält:

- `OperationId`;
- `CommandType`;
- `IdempotencyKey`;
- `LabRunId`;
- `State`;
- `StartedAt`;
- `LastUpdatedAt`;
- `ResultCode`;
- `Progress`;
- `CancellationState`;
- keine Secrets.

### 17.4 Event-Vertrag

Alle wesentlichen Zustandsänderungen erzeugen strukturierte Events:

```text
PLAN_CREATED
PLAN_APPROVAL_REQUIRED
RESOURCE_PROVISIONING_STARTED
RESOURCE_READY
STEP_STARTED
STEP_COMPLETED
STEP_FAILED
COMPENSATION_STARTED
CLEANUP_COMPLETED
RECOVERY_REQUIRED
```

Konsolentexte sind nur eine Darstellung dieser Events. Externe Clients müssen keine Textausgabe parsen.

### 17.5 REST ist ein optionaler Control-Plane-Adapter

Eine spätere REST-Schnittstelle wird als eigener Control-Plane-Adapter umgesetzt. Sie darf:

- Authentifizierung und Autorisierung ergänzen;
- Commands entgegennehmen;
- Operationen und Events ausgeben;
- keine Providerlogik duplizieren;
- keine Secrets in URLs oder normalen Logs transportieren.

Damit kann später ein UI, eine zentrale Teststeuerung oder ein getrenntes Validation-Repository denselben Core nutzen.

## 18. Erweiterungsmodell

### 18.1 Extension Points

| Extension Point | Zweck |
|---|---|
| Provider Plugin | neue Infrastrukturplattform |
| Component-Type Pack | neue logische Technologie oder Composite Component |
| Action-Type Pack | neue Installations-, Job-, API-, Beobachtungs- oder Assertion-Aktion |
| Fault Pack | neue kontrollierte Fault Injection |
| Project Package | projektspezifische Environments, Inhalte und Szenarien |
| Control-Plane Adapter | CLI, REST, UI oder externer Controller |
| Evidence Renderer | lokale Darstellung oder sanitisierte Exportform |

### 18.2 Registrierungsdaten

Jede Erweiterung deklariert:

- ID und Version;
- unterstützte Core-Versionen;
- Schemas;
- Capabilities;
- Handler/Entrypoints;
- Trust Class;
- Hashes oder spätere Signaturinformation;
- Safety- und Secret-Policy;
- Tests und bekannte Grenzen.

### 18.3 Keine stillen Überschreibungen

- Typ-IDs sind namespaced.
- Eine vorhandene Typversion wird nicht still überschrieben.
- Konflikte führen zu `EXTENSION_CONFLICT`.
- Unbekannte Major-Versionen werden abgelehnt.
- Provider- oder Handlerauswahl wird im Plan sichtbar.

## 19. Trust- und Sicherheitsmodell

### 19.1 Vertrauensebenen

| Trust Class | Bedeutung |
|---|---|
| `CORE_BUILTIN` | Bestandteil des geprüften Lab-Core |
| `OFFICIAL_EXTENSION` | offiziell gepflegte Erweiterung dieses Repositorys |
| `PROJECT_CONTENT` | Skripte und Inhalte eines gebundenen Projekts |
| `LOCAL_TRUSTED` | lokal explizit freigegebene Erweiterung |
| `UNTRUSTED` | darf nicht ausgeführt werden |

### 19.2 Planbare Seiteneffekte

Jede Action deklariert:

- Datei-, Netzwerk-, Prozess-, Provider- und Datenbankmutationen;
- benötigte Privilegien;
- Zielscope;
- maximale Ressourcen;
- External-Egress-Bedarf;
- Secret-Zugriff;
- Destructive Class;
- Compensation-Verhalten.

Der Plan zeigt diese Seiteneffekte vor der Ausführung an.

### 19.3 Ausführungsgrenzen

- Project Content darf keine Providerressourcen direkt löschen.
- Provider Plugins dürfen keine fachlichen Testdaten erzeugen.
- Action Handler dürfen nur freigegebene Binding-Typen erhalten.
- Externe Endpunkte benötigen eine explizite Network Policy.
- Unregistrierte lokale Skripte werden nicht automatisch ausgeführt.

## 20. Kompatibilitätsdimensionen

Folgende Versionen werden getrennt geführt:

- Lab Core Contract;
- Lab Package Contract;
- Project Adapter Contract;
- Component-Type-Version;
- Action-Type-Version;
- Provider-Version;
- Scenario-Version;
- DataSet-Version;
- Evidence Contract;
- Control-Plane Contract.

Ein Paket gibt Constraints an. Der Resolver erzeugt einen Fehler, wenn keine kompatible Kombination vorhanden ist. Die Lösung besteht nicht darin, Felder still zu ignorieren.

## 21. Was der Core bewusst nicht festschreibt

Der Core schreibt nicht fest:

- dass jede Umgebung SQL Server enthält;
- dass jede Komponente ein Container oder eine VM ist;
- dass jeder Schritt ein PowerShell- oder T-SQL-Skript ist;
- dass ein Cluster eine bestimmte Anzahl oder Art von Nodes besitzt;
- dass Beobachtung nur über SQL-DMVs erfolgt;
- dass Testdaten nur relational sind;
- dass Steuerung nur über CLI erfolgt;
- dass ein Provider lokal sein muss;
- dass alle Szenarien exakt fünf lineare Schritte besitzen.

Der Core schreibt stattdessen Typen, Contracts, Capabilities, Bindings, State, Safety und Cleanup fest.

## 22. Anti-Patterns

Unzulässige Zielarchitekturen:

1. ein universelles `Setup.ps1`, das Umgebung, Installation, Daten, Workload und Cleanup untrennbar vermischt;
2. Compose- oder Hyper-V-Dateien als fachliche Schnittstelle zum konsumierenden Projekt;
3. reale Connection Strings in Szenariomanifesten;
4. projektbezogene Skripte, die fremde Container oder VMs direkt verwalten;
5. providerbezogene Befehle innerhalb fachlicher Szenarien;
6. Testdaten ohne eigene Identität, Verifikation und Cleanup-Regel;
7. Abhängigkeit von Konsolentext statt strukturierter Codes und Events;
8. ein festes Enum aller zukünftigen Technologien im Core-Schema;
9. beliebiger Plugin-Code ohne Version, Trust Class und Scope;
10. externe Endpunkte ohne explizite Management- und Network Policy.

## 23. Konsequenzen für die bisherige Planung

Die bisher vorgesehenen Verträge werden wie folgt angepasst:

| Bisher | Neu |
|---|---|
| `Project Adapter` enthält feste Install-/Observe-Entrypoints | Adapter entdeckt und bindet versionierte Lab Packages; Entrypoints liegen in Deployment Units und Workflow Steps |
| `Topology` enthält SQL-spezifische Nodes | `Environment Blueprint` enthält offene, namespaced Component Types |
| festes `SupportedSqlVersions` auf oberster Ebene | technologiebezogene Version Constraints liegen an Components und Packages |
| fünf feste Szenariophaseobjekte | semantische Phasen über einem typisierten Workflow DAG |
| Provider stellt Umgebung bereit | Provider stellt Infrastrukturressourcen bereit; Component Expander und Action Handler konfigurieren Technologie und Inhalt |
| Run Context enthält lose Endpunktwerte | typisierte Runtime Bindings mit Sensitivity, Scope und Export Policy |
| PowerShell als implizite Ausführungsgrenze | PowerShell ist initiale CLI und ein Action Handler; Core Commands bleiben serialisierbar |

## 24. Implementierungsreihenfolge für die Schnittstelle

### Schritt 1 – Kernschemas

- Package;
- Environment Blueprint;
- Component Type Definition;
- Action Type Definition;
- Workflow Graph;
- Runtime Binding;
- Bound Plan;
- Run Event.

### Schritt 2 – Built-in Types

- `core.container`;
- `core.vm`;
- `core.network`;
- `core.storage`;
- `core.external-endpoint`;
- `mssql.instance`;
- grundlegende Datei-, Prozess-, PowerShell-, Shell- und SQL-Actions.

### Schritt 3 – SQL-Server-Piloten

- Quick Environment;
- Frameworkinstallation;
- synthetische DataSet-Erzeugung;
- Multi-Session-Workload;
- Analyzer-/Demo-Observation;
- Cleanup.

### Schritt 4 – Technologieoffenheits-Proof

Vor Vertragsversion `1.0` muss mindestens ein nicht rein relationaler oder nicht rein SQL-basierter Proof umgesetzt werden, beispielsweise:

- ein lokaler HTTP-Mock-Service mit `http.request.execute`; oder
- ein kleines Composite-Cluster-Fixture, das die Expansionslogik prüft.

Damit wird nachgewiesen, dass der Vertrag nicht nur formal, sondern tatsächlich technologieoffen ist.

### Schritt 5 – Control-Plane-Trennung

- Commands und Results als neutrale JSON-Verträge;
- CLI als Adapter;
- Operation- und Eventmodell;
- keine direkte Kopplung fachlicher Logik an `Write-Host` oder interaktive Prompts.

## 25. Abnahmekriterien

Der erweiterbare Schnittstellenvertrag gilt erst als belastbar, wenn:

1. ein Projekt vollständig beschreiben kann, welche Komponenten, Inhalte, Daten, Workloads, Beobachtungen und Cleanup-Schritte benötigt werden;
2. kein Projekt Providerbefehle enthalten muss;
3. ein DataSet als eigener, verifizierbarer und resetbarer Vertrag modelliert ist;
4. Outputs eines Schrittes typisiert in spätere Schritte gebunden werden können;
5. Composite Components in einen Ressourcenuntergraphen expandiert werden können;
6. neue Component- und Action Types ohne Änderung des Core-Schemas registrierbar sind;
7. externe REST-Endpunkte mit expliziter Management- und Network Policy eingebunden werden können;
8. ein zukünftiger Hadoop-Cluster als Erweiterung modellierbar ist, ohne SQL-spezifische Pflichtfelder zu erben;
9. CLI und eine spätere REST Control Plane dieselben Commands, Results und Events verwenden können;
10. alle Seiteneffekte, Secrets, Ressourcen und Cleanup-Grenzen vor Mutation planbar sind;
11. unbekannte oder nicht vertrauenswürdige Erweiterungen kontrolliert abgelehnt werden;
12. die zwei Primärprojekte über denselben Package-, Binding- und Workflowvertrag integriert werden können.

## 26. Offene Designfragen vor Schema-Festschreibung

Folgende Punkte müssen in Welle 1 durch Prototypen entschieden werden:

- ob Component-Type-Expansion zunächst rein deklarativ oder über vertrauenswürdige PowerShell-Module erfolgt;
- welches Ausdrucksformat für Bedingungen und Binding-Referenzen verwendet wird;
- wie JSON-Schema-Referenzen zwischen Core und Extension Packs versioniert werden;
- ob Workflow Steps einen generischen `Inputs`-Block oder pro Action vollständig spezialisierte Payloadfelder erhalten;
- wie lokale Paketregistrierung und Hashprüfung umgesetzt werden;
- welche Actions in der ersten Core-Version eingebaut sind und welche sofort als Packs getrennt werden;
- wie externe Endpunktfreigaben dauerhaft, aber nicht im Repository gespeichert werden;
- welche minimale nicht-SQL-Erweiterung vor `1.0` als Architekturbeweis dient.

Diese Fragen dürfen nicht durch vorschnelles Einfrieren eines SQL-zentrierten Schemas beantwortet werden. Zuerst werden zwei SQL-Piloten und mindestens ein technologieoffener Proof gegen denselben Vertragskern modelliert.
