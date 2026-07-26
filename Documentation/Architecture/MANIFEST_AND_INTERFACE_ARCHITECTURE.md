# Manifest- und Schnittstellenarchitektur

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_DECISION_DRAFT` |
| Vertragsfamilie | `LAB_CORE_CONTRACTS` |
| Zielversion | `0.1` |
| Stand | 2026-07-26 |
| Maßgebliche Vertiefung | [Erweiterbarer Umgebungs- und Ausführungsvertrag](./EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md) |

## 1. Ziel

Dieses Dokument definiert die maschinenlesbaren Vertragsarten und ihre Auflösungsreihenfolge. Der Lab Core ist bewusst nicht auf SQL Server, Docker, Hyper-V, PowerShell oder einen linearen Fünf-Phasen-Ablauf festgelegt.

SQL Server ist die erste produktive Component-Familie. Weitere Technologien, beispielsweise Hadoop-Cluster, HTTP-/REST-Dienste, zusätzliche Datenplattformen oder externe Testsysteme, werden über registrierte Component Types und Action Types ergänzt.

## 2. Architekturprinzipien

1. **Intent vor Implementierung:** Ein Projekt beschreibt den gewünschten fachlichen Zustand und Ablauf.
2. **Komponenten statt Providerressourcen:** Fachliche Manifeste referenzieren Component Types, keine `docker`, `podman`-, `New-VM`- oder Cloudbefehle.
3. **Packages statt Universal-Skripte:** Projektinhalte werden als versionierte Lab Packages gebunden.
4. **Typisierte Actions:** Installation, Testdatenerzeugung, Workload, REST-Zugriff, Beobachtung und Cleanup verwenden registrierte Action Types.
5. **Runtime Bindings statt statischer Endpunkte:** Konkrete Endpunkte, Pfade und Secret-Referenzen entstehen erst lokal zur Laufzeit.
6. **Plan vor Mutation:** Jeder gültige Request muss vollständig zu einem read-only Bound Plan auflösbar sein.
7. **Capabilities statt Annahmen:** Provider- und Technologieunterstützung wird verhandelt und nicht vorgetäuscht.
8. **Open Type Registry:** Neue Technologien werden namespaced registriert; der Core führt kein festes Enum aller zukünftigen Systeme.
9. **Strikte Schemas:** `additionalProperties` ist standardmäßig `false`; Erweiterungen besitzen explizite Namespaces und eigene Schemas.
10. **Keine Secrets oder realen Hostdaten:** Manifeste enthalten nur Referenzen, Constraints und synthetische Beispielwerte.
11. **Strukturierte Codes und Events:** Konsolentext ist Darstellung, nicht Schnittstelle.
12. **Cleanup als Kernvertrag:** Jede Mutation wird registriert, kompensiert oder als `RECOVERY_REQUIRED` ausgewiesen.

## 3. Vertragsfamilien

### 3.1 Core Contracts

| Schema | Zweck |
|---|---|
| `lab-request.schema.json` | konkrete Benutzer- oder API-Anforderung |
| `lab-package.schema.json` | selbstbeschreibendes Projekt- oder Erweiterungspaket |
| `environment-blueprint.schema.json` | logische Komponenten, Beziehungen und Constraints |
| `workflow.schema.json` | typisierter Ausführungsgraph |
| `runtime-binding.schema.json` | lokale, typisierte Outputs und Referenzen |
| `bound-plan.schema.json` | vollständig aufgelöster read-only Mutationsplan |
| `run-state.schema.json` | tatsächlich erzeugte Ressourcen und Schrittstatus |
| `run-event.schema.json` | strukturierte Zustands- und Fortschrittsereignisse |
| `evidence.schema.json` | lokale technische Evidenz und sanitisierte Summary |

### 3.2 Registry Contracts

| Schema | Zweck |
|---|---|
| `component-type.schema.json` | logischer oder zusammengesetzter Komponententyp |
| `action-type.schema.json` | ausführbare, typisierte Aktion |
| `provider.schema.json` | Infrastrukturprovider und unterstützte Ressourcenarten |
| `capability.schema.json` | normalisierte Fähigkeit und Nachweisgrenze |
| `fault-type.schema.json` | kontrollierte Fault-Injection-Art |
| `control-plane-adapter.schema.json` | CLI-, REST- oder spätere UI-Anbindung |

### 3.3 Content Contracts

| Schema | Zweck |
|---|---|
| `dataset.schema.json` | Erzeugung, Verifikation, Reset und Cleanup synthetischer Testdaten |
| `deployment-unit.schema.json` | Installation oder Konfiguration innerhalb einer Komponente |
| `workload.schema.json` | kontrollierte Last oder Prozessabfolge |
| `probe.schema.json` | Beobachtung und Health-/Messabfrage |
| `assertion.schema.json` | fachliche oder technische Erwartung |
| `artifact.schema.json` | hashgebundenes Package-Artefakt und Datenklassifikation |

## 4. `lab-request.schema.json`

Ein Run Request beschreibt **was** ausgeführt werden soll, nicht wie.

Pflichtfelder:

- `ContractVersion`;
- `RequestId`;
- `Mode`: `QUICK`, `SCENARIO` oder `CUSTOM`;
- `PackageRefs`;
- `EnvironmentRef` oder Inline-Environment;
- `ScenarioRefs` optional;
- `ProviderPreferences`;
- `ResourceProfileRef` optional;
- `PersistenceMode`;
- `AllowedOverrides`;
- `SafetyAcknowledgements`;
- `OutputPolicy`.

Technologiespezifische Versionswünsche liegen an Components oder Package Constraints. Ein globales Pflichtfeld `SqlVersions` ist deshalb kein Core-Vertrag.

## 5. `lab-package.schema.json`

Ein Lab Package bündelt:

- Package-Identität und Version;
- Project- oder Extension-Identität;
- Environment-Katalog;
- Scenario-Katalog;
- DataSets;
- Deployment Units;
- Workloads, Probes und Assertions;
- benötigte Component- und Action Types;
- Artefakte und Hashes;
- Secret Requirements ohne Werte;
- Trust Class;
- Lizenz- und Privacy-Policy;
- Core- und Extension-Version-Constraints.

Package-Klassen:

```text
DECLARATIVE
CONTENT
TRUSTED_EXTENSION
PROVIDER_EXTENSION
```

## 6. `environment-blueprint.schema.json`

### 6.1 Component

Eine Component enthält mindestens:

- `ComponentId`;
- `ComponentType`;
- `ComponentTypeVersionConstraint`;
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

### 6.2 Component Types

Beispiele:

```text
core.vm
core.container
core.network
core.storage
core.external-endpoint
mssql.instance
mssql.availability-group
mssql.load-generator
hadoop.cluster
http.service
http.mock-service
observability.collector
```

Neue Typen werden über die Registry ergänzt. Das Core-Schema enthält kein abschließendes Technologie-Enum.

### 6.3 Composite Components

Composite Components werden vor Provider-Mapping expandiert. Ein `hadoop.cluster` kann beispielsweise in Master-, Worker-, Netzwerk- und Storage-Komponenten aufgelöst werden. Die Expansionslogik gehört zur versionierten Component-Type-Definition.

### 6.4 Management Modes

```text
PROVISIONED
ATTACHED
EXTERNAL_READ_ONLY
EXTERNAL_MUTABLE
EMULATED
FIXTURE
```

`EXTERNAL_MUTABLE` ist standardmäßig blockiert und benötigt eine konkrete lokale Freigabe.

## 7. `component-type.schema.json`

Eine Component-Type-Definition beschreibt:

- `TypeId` und Version;
- Configuration-Schema;
- unterstützte Management Modes;
- erforderliche Capabilities;
- zulässige Providerklassen;
- optionale Composite-Expansion;
- Health- und Readiness-Probes;
- exportierte Binding Types;
- erlaubte Actions;
- Lifecycle- und Cleanup-Vertrag;
- Safety Class;
- bekannte Aussagegrenzen.

Technologiespezifische Felder liegen im Configuration-Schema des Typs und nicht im Lab-Core-Schema.

## 8. `action-type.schema.json`

Action Types sind namespaced.

Beispiele:

```text
core.file.copy
core.process.execute
powershell.script.execute
shell.script.execute
mssql.script.execute
mssql.database.create
mssql.query.execute
http.request.execute
http.openapi.validate
hadoop.hdfs.put
hadoop.job.submit
fault.network.apply
fault.network.remove
```

Jeder Action Type definiert:

- Input- und Output-Schema;
- zulässige Target Component Types;
- erforderliche Capabilities;
- Side Effects;
- Safety Class;
- Secret-Injection-Modi;
- Idempotenz;
- Retry- und Cancel-Verhalten;
- Compensation oder Nicht-Kompensierbarkeit;
- Log- und Redaction-Regeln.

## 9. `deployment-unit.schema.json`

Deployment Units beschreiben, was innerhalb von Komponenten installiert oder konfiguriert wird.

Pflichtfelder:

- `UnitId`;
- `TargetSelector`;
- `ActionType`;
- `ArtifactRef` optional;
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

Provider stellen Infrastruktur bereit. Deployment Units installieren Technologie- und Projektinhalte.

## 10. `dataset.schema.json`

Testdaten sind ein eigener Vertrag und kein unsichtbarer Setup-Nebeneffekt.

Pflichtfelder:

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

Creation Modes:

```text
GENERATE
LOAD_PUBLIC_FIXTURE
RESTORE_SYNTHETIC_ARTIFACT
DERIVE
STREAM
```

## 11. `workflow.schema.json`

### 11.1 Workflow Graph

`Arrange`, `Act`, `Observe`, `Assert` und `Cleanup` bleiben semantische Phasen. Technisch besteht ein Szenario aus einem gerichteten, azyklischen Graphen typisierter Steps.

### 11.2 Step

Pflichtinformationen:

- `StepId`;
- `Phase`;
- `ActionType`;
- `TargetRef`;
- `Inputs`;
- `SecretRefs`;
- `DependsOn`;
- `Condition` optional;
- `ConcurrencyGroup` optional;
- `TimeoutSeconds`;
- `RetryPolicy`;
- `FailurePolicy`;
- `IdempotencyMode`;
- `Produces`;
- `Compensation`;
- `AlwaysRun`;
- `SafetyClass`.

Unbegrenzte Schleifen sind unzulässig. Wiederholung besitzt harte Attempt- und Zeitgrenzen.

## 12. `runtime-binding.schema.json`

Runtime Bindings verbinden Provider-, Component- und Workflowoutputs.

Ein Binding enthält:

- `BindingId`;
- `BindingType`;
- `ProducerRef`;
- `ValueClass`;
- `SensitivityClass`;
- `Scope`;
- `Lifetime`;
- `ConsumerAllowlist`;
- `ExportPolicy`;
- den tatsächlichen Wert ausschließlich im lokalen Runtime State.

Beispiele:

```text
binding.sql-primary.endpoint.sql
binding.sql-primary.credential-ref.admin
binding.api.endpoint.http-base
binding.hadoop.endpoint.hdfs
binding.dataset.database.name
```

Binding-Referenzen werden typgeprüft. Secret Bindings dürfen nicht in normale Stringoutputs aufgelöst werden.

## 13. `provider.schema.json`

Ein Provider beschreibt Infrastrukturmechanik, nicht fachliche Inhalte.

Pflichtfähigkeiten:

- `DetectCapabilities`;
- `ValidateResourceGraph`;
- `Plan`;
- `Provision`;
- `GetStatus`;
- `Stop`;
- `Start`;
- `Reset`, soweit unterstützt;
- `Destroy`;
- `ExecuteInResource`, soweit unterstützt;
- Rückgabe tatsächlicher Ressourcen-IDs und Bindings.

Provider dürfen keine projektspezifischen Testdaten oder Findings besitzen.

## 14. `capability.schema.json`

Capabilities sind namespaced und erweiterbar.

Ein Capability Record enthält:

- `CapabilityCode`;
- `CapabilityVersion`;
- `Status`: `AVAILABLE`, `UNAVAILABLE`, `UNKNOWN`, `BLOCKED`;
- `Scope`;
- `ProviderRef` oder `ComponentRef`;
- lokale `EvidenceSource`;
- `StatementBoundary`;
- `Sanitizable`.

Beispiele:

```text
provider.docker.compose
provider.hyperv.powershell-direct
fault.network.netem
fault.storage.block-io-throttle
mssql.version.2025
mssql.windows-authentication
hadoop.cluster.expand
http.client.tls
```

## 15. `bound-plan.schema.json`

Der Bound Plan enthält:

- aufgelöste Vertrags- und Extension-Versionen;
- Package- und Szenarioidentitäten;
- expandierten Resource Graph;
- ausgewählte Provider und Handler;
- konkrete Ressourcenanzahl;
- Ressourcenbudget und Hostreserve;
- lokale Bindings in redigierter Darstellung;
- geplante Deployment Units und Workflow Steps;
- Secret Requirements ohne Werte;
- External-Egress- und Endpoint-Policy;
- Faults und harte Grenzen;
- Side Effects und Safety Classes;
- Destructive Actions;
- Cleanup- und Compensation-Plan;
- Warnungen, `NOT_EXECUTED`-Teile und Aussagegrenzen;
- Plan-Hash.

Der Plan wird vor jeder Mutation angezeigt oder maschinenlesbar bestätigt.

## 16. `run-state.schema.json`

Der lokale Run State enthält:

- `LabRunId`;
- Plan-Hash;
- tatsächliche Providerressourcen und vollständige IDs;
- tatsächliche lokale Endpunkte und Pfade;
- Secret-Referenzen, keine Secret-Werte im normalen State;
- Runtime Bindings;
- Operationen und Stepstatus;
- erfolgreich abgeschlossene Mutationen;
- Compensation Stack;
- Healthstatus;
- Cleanupstatus;
- Recoveryinformationen.

Der State ist nicht exportierbar und bleibt in einem ignorierten lokalen Scope.

## 17. `run-event.schema.json`

Strukturierte Events bilden die Control Plane.

Beispiele:

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

Ein Event enthält Codes, Zeit, Scope, Referenzen und redigierte Metadaten. Secrets oder unkontrollierte Runtime-Payloads sind unzulässig.

## 18. `evidence.schema.json`

Evidence wird getrennt geführt:

- `LOCAL_TECHNICAL` für lokale, ignorierte technische Werte;
- `SANITIZED_SUMMARY` für privacy-geprüfte, exportierbare Zusammenfassungen.

Gemeinsame Felder:

- Vertrags- und Package-Versionen;
- Run- und Scenario-ID;
- Provider- und Component-Klassen;
- Produktversionen, soweit nicht sensitiv;
- Phasen- und Stepstatus;
- aggregierte Messwerte;
- Assertionsergebnisse;
- Aussagegrenzen;
- Cleanupstatus.

Secrets, vollständige Connection Strings, reale Identitäten, ungeprüfte Querytexte, Pläne, Logs und Event-Payloads sind in `SANITIZED_SUMMARY` unzulässig.

## 19. Project Adapter

Der Project Adapter ist kein Universal-Lifecycle-Skript. Er beschreibt:

- Project-Identität;
- kompatible Lab-Core-Versionen;
- Package-Kataloge oder Package Discovery;
- lokale Vertrauens- und Lizenzinformationen;
- optionale Defaultauswahl;
- Privacy- und Exportpolicy.

Installations-, Daten-, Workload-, Observation- und Cleanup-Schritte liegen in Packages und Workflow Steps.

## 20. Auflösungsreihenfolge

1. Run Request und Vertragsversion validieren;
2. Project Adapter und Package-Katalog auflösen;
3. Package-Hashes, Trust Class und Kompatibilität prüfen;
4. Environment Blueprint laden;
5. Component Types und Composite Expander auflösen;
6. Expanded Resource Graph erzeugen;
7. Deployment Units, DataSets und Workflow laden;
8. Action Types und Handler auflösen;
9. Host- und Provider-Capabilities read-only ermitteln;
10. Provider und Placements auswählen;
11. lokale Pfad-, Port-, Medien-, Endpoint- und Secret-Bindings prüfen;
12. Inputs und Outputs typisiert verbinden;
13. Ressourcen-, Side-Effect-, Safety-, Egress- und Cleanup-Plan erzeugen;
14. Plan validieren und Hash bilden;
15. erforderliche Bestätigungen prüfen;
16. erst danach Mutation zulassen.

## 21. Override-Regeln

| Klasse | Beispiel | Regel |
|---|---|---|
| `SAFE_RUNTIME` | lokaler Port oder Zielroot | lokal zulässig, nicht versioniert |
| `RESOURCE_WITHIN_BOUNDS` | CPU/RAM innerhalb Package- und Hostgrenzen | Planner prüft Reserve |
| `SEMANTIC` | andere Component-Version | nur bei erfülltem Version Constraint |
| `SAFETY_RELEVANT` | längere Stressdauer | explizite Bestätigung und harte Package-Grenze |
| `EXTERNAL_BINDING` | REST-Testendpoint | Management- und Network Policy erforderlich |
| `FORBIDDEN` | Systempfad, produktiver Endpoint, fremde Ressource | immer ablehnen |

Overrides dürfen keine Capability, Trust Class oder Safety-Grenze vortäuschen.

## 22. Control-Plane-Vertrag

CLI, spätere REST API und mögliche UI verwenden dieselben serialisierbaren Commands:

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

Länger laufende Commands liefern `OperationId`, Status und strukturierte Events. Konsolentexte werden nicht geparst.

## 23. Versionsdimensionen

Getrennt versioniert werden:

- Lab Core Contract;
- Package Contract;
- Project Adapter Contract;
- Component Type;
- Action Type;
- Provider;
- Scenario;
- DataSet;
- Evidence;
- Control Plane.

Unbekannte Major-Versionen werden abgelehnt. Felder werden nicht still ignoriert.

## 24. Architekturbeweise vor Version `1.0`

Vor einem stabilen `1.0`-Vertrag müssen mindestens modelliert und prototypisch aufgelöst werden:

1. SQL-Server-Quick-Environment;
2. SQL-Performance-Demo mit eigenem DataSet und Multi-Step-Workflow;
3. SQL-Analyze-Szenario mit Frameworkinstallation und Finding-Assertion;
4. nicht rein SQL-basierter Proof, mindestens HTTP-Mock-Service oder Composite-Cluster-Fixture;
5. Control-Plane-Aufruf über CLI auf neutralen Commands und Events.

Damit wird verhindert, dass ein formal generisches, praktisch aber SQL-zentriertes Schema eingefroren wird.

## 25. Abnahmekriterien für Welle 1

1. Alle Schemas verwenden eine dokumentierte JSON-Schema-Version.
2. `additionalProperties` ist standardmäßig `false`.
3. Namespaced Extension Points sind ohne Core-Schemaänderung registrierbar.
4. Beispiele enthalten keine funktionsfähigen Secrets oder realen Hostwerte.
5. Ein Package beschreibt Umgebung, Inhalte, Testdaten und Ablauf vollständig.
6. Ein Run Request wird bis zu einem Bound Plan ohne Mutation aufgelöst.
7. Inputs und Outputs werden typisiert verbunden.
8. Composite Components können expandiert werden.
9. unbekannte oder nicht vertrauenswürdige Handler werden abgelehnt.
10. Cleanup und Compensation sind Teil des Plans.
11. externe Endpunkte benötigen explizite Policy.
12. lokale und exportierbare Evidence sind getrennt.
13. SQL- und Nicht-SQL-Proofs verwenden denselben Core-Vertrag.
14. CLI und spätere REST Control Plane können dieselben Commands und Events verwenden.
