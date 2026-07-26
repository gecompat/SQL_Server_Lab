# Manifest- und Schnittstellenarchitektur

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_DECISION_DRAFT` |
| Vertragsfamilie | `SQL_SERVER_LAB_CONTRACTS` |
| Zielversion | `0.1` |
| Stand | 2026-07-26 |
| Hauptzweck | SQL-Server-Labs |
| Maßgebliche Vertiefung | [Erweiterbarer SQL-Server-Umgebungs- und Ausführungsvertrag](./EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md) |

## 1. Ziel

Dieses Dokument definiert die maschinenlesbaren Verträge und ihre Auflösungsreihenfolge.

SQL Server ist keine bloße erste Beispieltechnologie, sondern verbindlicher Hauptzweck. Supporting Components werden über erweiterbare Typen modelliert, damit SQL-Server-Szenarien wie Windows Authentication, Always On, PolyBase oder REST-Integration nicht durch zu enge Schemas verhindert werden.

## 2. Architekturprinzipien

1. **SQL Purpose ist Pflicht:** Jeder ausführbare Request und jedes Package besitzt einen SQL-Server-Zweck.
2. **Primäre SQL Components:** Mindestens eine primäre SQL-Server-Komponente ist erforderlich.
3. **Supporting Components nur mit SQL-Bezug:** Domain, Hadoop, REST, Client oder Observability sind Hilfssysteme eines SQL-Szenarios.
4. **Komponenten statt Providerbefehle:** Packages enthalten keine `docker`, `podman`- oder Hyper-V-Befehle.
5. **Packages statt Universal-Skripte:** Installation, Testdaten, Workload und Prüfung sind getrennte Package-Inhalte.
6. **Typisierte Actions:** SQL-, Supporting-, Fault-, Probe- und Assertion-Aktionen sind registriert und versioniert.
7. **Runtime Bindings:** Endpunkte, Pfade und Secret-Referenzen entstehen erst lokal.
8. **Plan vor Mutation:** Jeder gültige Request wird vollständig zu einem read-only Bound Plan aufgelöst.
9. **Provider-Capabilities statt Gleichheitsannahmen:** Hyper-V, Docker und Podman werden getrennt nachgewiesen.
10. **Strikte Schemas:** `additionalProperties` ist standardmäßig `false`.
11. **Stabile Codes und Events:** Konsolentext ist keine Integrationsschnittstelle.
12. **Cleanup als Kernvertrag:** Jede Mutation ist registriert, kompensierbar oder führt zu `RECOVERY_REQUIRED`.

## 3. Vertragsfamilien

### 3.1 Core Contracts

| Schema | Zweck |
|---|---|
| `sql-lab-request.schema.json` | konkrete SQL-Server-Lab-Anforderung |
| `sql-purpose.schema.json` | fachlicher SQL-Zweck und Zielgrenzen |
| `sql-lab-package.schema.json` | Package aus Environment, Content, DataSets und Workflow |
| `environment-blueprint.schema.json` | primäre SQL Components, Supporting Components und Relations |
| `workflow.schema.json` | typisierter Ausführungsgraph |
| `runtime-binding.schema.json` | lokale, typisierte Outputs und Referenzen |
| `bound-plan.schema.json` | vollständig aufgelöster read-only Plan |
| `run-state.schema.json` | tatsächliche Ressourcen und Schrittstatus |
| `run-event.schema.json` | strukturierte Zustands- und Fortschrittsereignisse |
| `evidence.schema.json` | lokale technische Evidenz und sanitisierte Summary |

### 3.2 Registry Contracts

| Schema | Zweck |
|---|---|
| `component-type.schema.json` | primärer SQL- oder Supporting-Component-Type |
| `action-type.schema.json` | ausführbare typisierte Aktion |
| `provider.schema.json` | Hyper-V-, Docker- oder Podman-Provider |
| `capability.schema.json` | normalisierte Fähigkeit und Nachweisgrenze |
| `fault-type.schema.json` | kontrollierte SQL-bezogene Fault Injection |
| `control-plane-adapter.schema.json` | CLI-, REST- oder UI-Anbindung |

### 3.3 Content Contracts

| Schema | Zweck |
|---|---|
| `deployment-unit.schema.json` | Installation oder Konfiguration innerhalb einer Component |
| `dataset.schema.json` | Erzeugung, Verifikation, Reset und Cleanup synthetischer Daten |
| `workload.schema.json` | kontrollierte SQL- oder Client-Last |
| `probe.schema.json` | SQL-, Infrastruktur- oder Supporting-Observation |
| `assertion.schema.json` | fachliche oder technische Erwartung |
| `artifact.schema.json` | hashgebundenes Package-Artefakt |

## 4. `sql-purpose.schema.json`

Pflichtfelder:

- `PurposeId`;
- `PurposeClass`;
- `TargetSqlVersions`;
- `TargetOperatingSystems`;
- `TargetEditions`;
- `RequiredSqlCapabilities`;
- `PrimarySqlComponentRefs`;
- `SupportingComponentRefs`;
- `ScenarioRefs`;
- `ExpectedSqlEvidence`;
- `KnownSqlLimitations`.

Purpose Classes:

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

`SupportingComponentRefs` darf leer sein. `PrimarySqlComponentRefs` darf nur für einen ausdrücklich gekennzeichneten `CONTRACT_FIXTURE`-Negativtest leer sein.

## 5. `sql-lab-request.schema.json`

Pflichtfelder:

- `ContractVersion`;
- `RequestId`;
- `Mode`: `QUICK`, `SCENARIO` oder `CUSTOM`;
- `PackageRefs`;
- `SqlPurposeRef` oder Inline-`SqlPurpose`;
- `EnvironmentRef` oder Inline-Environment;
- `ProviderPreferences`;
- `ResourceProfileRef`;
- `PersistenceMode`;
- `AllowedOverrides`;
- `SafetyAcknowledgements`;
- `OutputPolicy`.

Ein Request ohne SQL Purpose ist ungültig.

## 6. `sql-lab-package.schema.json`

Ein Package enthält:

- Package-ID und Version;
- Project-ID;
- unterstützte Lab-Core-Versionen;
- `SqlPurposeCatalog`;
- Environment-Katalog;
- Scenario-Katalog;
- Deployment Units;
- DataSets;
- Workloads, Probes und Assertions;
- Required Component und Action Types;
- Artefakte und Hashes;
- Secret Requirements ohne Werte;
- Trust Class;
- Data Classification;
- License Notice;
- Privacy Export Policy;
- Known Limitations.

Package Classes:

```text
SQL_QUICK
SQL_PROJECT_CONTENT
SQL_SCENARIO_CATALOG
SQL_SUPPORTING_EXTENSION
SQL_PROVIDER_EXTENSION
```

Ein `SQL_SUPPORTING_EXTENSION` ist nur über ein SQL Package verwendbar und kein eigenständiges Labprodukt.

## 7. `environment-blueprint.schema.json`

### 7.1 Primary SQL Component

Pflichtfelder:

- `ComponentId`;
- `ComponentType`;
- `Role`;
- `SqlVersionConstraint`;
- `OperatingSystemFamily`;
- `EditionConstraint`;
- `AuthenticationRequirements`;
- `ResourceRequirements`;
- `StorageClaims`;
- `NetworkInterfaces`;
- `RequiredCapabilities`;
- `Exports`;
- `LifecyclePolicy`.

### 7.2 Supporting Component

Zusätzliche Pflichtfelder:

- `SupportsSqlPurpose`;
- `SqlRelationRefs`;
- `Justification`;
- `KnownStatementBoundary`.

Beispiele:

```text
identity.domain-controller
hadoop.cluster
http.mock-service
client.sql-workload-driver
core.network-fault-controller
observability.collector
```

### 7.3 Relations

Beispiele:

```text
authenticates-against
joined-to-domain
connects-to
replicates-to
reads-external-data-from
calls-http
observes
fault-targets
```

Jede Relation besitzt einen SQL-Zweckbezug.

## 8. `component-type.schema.json`

Eine Component-Type-Definition beschreibt:

- `TypeId` und Version;
- `Category`: `PRIMARY_SQL` oder `SUPPORTING`;
- Configuration-Schema;
- erlaubte Management Modes;
- Required Capabilities;
- unterstützte Providerklassen;
- optionale Composite Expansion;
- Health- und Readiness-Probes;
- exportierte Binding Types;
- erlaubte Actions;
- Lifecycle- und Cleanup-Vertrag;
- Safety Class;
- Known Limitations.

SQL-bezogene Beispiele:

```text
mssql.instance
mssql.availability-group
mssql.failover-cluster-instance
mssql.polybase-instance
mssql.replication-topology
```

## 9. `deployment-unit.schema.json`

Pflichtfelder:

- `UnitId`;
- `TargetSelector`;
- `ActionType`;
- optional `ArtifactRef`;
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

Deployment Units installieren beispielsweise SQL_Server_Analyze, das Schulungsframework, SQL Agent-Konfiguration, Domain Join oder PolyBase-Supporting-Inhalte.

## 10. `dataset.schema.json`

Pflichtfelder:

- `DataSetId`;
- `TargetComponentRefs`;
- `SqlPurposeRef`;
- `CreationMode`;
- Generator oder Fixture;
- deterministischer Seed oder begründete Abweichung;
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

## 11. `workflow.schema.json`

Semantische Phasen:

```text
ARRANGE
ACT
OBSERVE
ASSERT
CLEANUP
```

Ein Step enthält:

- `StepId`;
- `Phase`;
- `SqlPurposeRef`;
- `ActionType`;
- `TargetRef`;
- `Inputs`;
- `SecretRefs`;
- `DependsOn`;
- optional Condition und Concurrency Group;
- Timeout;
- Retry und Failure Policy;
- Idempotency Mode;
- Outputs;
- Compensation;
- `AlwaysRun`;
- Safety Class.

Ein Supporting-Step ohne SQL-Purpose-Referenz ist ungültig.

## 12. `runtime-binding.schema.json`

Beispiele:

```text
binding.sql-primary.endpoint.sql
binding.sql-primary.credential-ref.admin
binding.sql-primary.metadata.product-version
binding.dataset.database.name
binding.domain.endpoint.dns
binding.hadoop.endpoint.hdfs
binding.api.endpoint.http-base
```

Ein Binding enthält:

- Binding ID und Type;
- Producer;
- Sensitivity Class;
- Scope;
- Lifetime;
- Consumer Allowlist;
- Export Policy;
- tatsächlichen Wert nur im lokalen Runtime State.

## 13. `provider.schema.json`

Verbindliche Provider-IDs:

```text
provider.hyperv
provider.docker
provider.podman
```

Pflichtoperationen:

- `DetectCapabilities`;
- `ValidateResourceGraph`;
- read-only `Plan`;
- `Provision`;
- `GetStatus`;
- `Stop`;
- `Start`;
- `Reset`, soweit unterstützt;
- `Destroy`;
- `ExecuteInResource`, soweit unterstützt;
- Rückgabe tatsächlicher IDs und Runtime Bindings.

Docker und Podman besitzen getrennte Capability Records.

## 14. `capability.schema.json`

Beispiele:

```text
provider.docker.compose
provider.podman.compose
provider.hyperv.powershell-direct
mssql.version.2019
mssql.version.2022
mssql.version.2025
mssql.sql-agent
mssql.windows-authentication
mssql.polybase
identity.active-directory
fault.network.netem
fault.storage.block-io-throttle
```

Ein Record enthält Version, Status, Scope, Provider oder Component, lokale Evidence Source und Statement Boundary.

## 15. `bound-plan.schema.json`

Der Bound Plan enthält:

- SQL Purpose;
- Package- und Vertragsversionen;
- expandierte SQL-Topologie;
- Supporting Components mit Begründung;
- ausgewählte Provider und Handler;
- Ressourcenbudget und Hostreserve;
- lokale Bindings in redigierter Form;
- Deployment Units, DataSets und Workflow Steps;
- Secret Requirements ohne Werte;
- Faults und harte Grenzen;
- Side Effects und Safety Classes;
- Destructive Actions;
- Cleanup- und Compensation-Plan;
- `NOT_EXECUTED`-Teile und Aussagegrenzen;
- Plan-Hash.

## 16. `run-state.schema.json`

Der lokale Run State enthält:

- Lab Run ID;
- Plan-Hash;
- SQL Purpose;
- tatsächliche Providerressourcen und vollständige IDs;
- lokale Endpunkte und Pfade;
- Runtime Bindings;
- Operations und Stepstatus;
- abgeschlossene Mutationen;
- Compensation Stack;
- Health und SQL Readiness;
- Cleanup und Recovery.

Der State ist nicht exportierbar.

## 17. `run-event.schema.json`

Beispiele:

```text
PLAN_CREATED
PLAN_APPROVAL_REQUIRED
SQL_RESOURCE_PROVISIONING_STARTED
SQL_RESOURCE_READY
SUPPORTING_RESOURCE_READY
DATASET_READY
STEP_STARTED
STEP_COMPLETED
STEP_FAILED
COMPENSATION_STARTED
CLEANUP_COMPLETED
RECOVERY_REQUIRED
```

Events enthalten keine Secrets oder unkontrollierten Runtime-Payloads.

## 18. `evidence.schema.json`

Evidence Classes:

```text
LOCAL_TECHNICAL
SANITIZED_SUMMARY
```

Eine Summary darf SQL-Produktversionen, Statuscodes, aggregierte Messwerte, Assertionsergebnisse und Aussagegrenzen enthalten. Reale Endpunkte, Pfade, Identitäten, Querytexte, Plans, Logs und Responses sind ausgeschlossen.

## 19. Project Adapter

Der Adapter beschreibt:

- Project-ID;
- kompatible Lab-Core-Versionen;
- SQL Package Catalogs;
- Default Package Refs;
- Trust Policy;
- License Notice;
- Privacy Export Policy.

Installations-, Daten-, Workload-, Observation- und Cleanup-Schritte liegen im Package.

## 20. Auflösungsreihenfolge

1. Request und Vertragsversion prüfen;
2. SQL Purpose prüfen;
3. Project Adapter und Package-Katalog auflösen;
4. Package-Hashes, Trust und Kompatibilität prüfen;
5. Environment Blueprint laden;
6. primäre SQL Components auflösen;
7. Supporting Components auf SQL-Bezug prüfen;
8. Composite SQL Components expandieren;
9. Deployment Units, DataSets und Workflow laden;
10. Action Types und Handler auflösen;
11. Host- und Provider-Capabilities read-only ermitteln;
12. Hyper-V-, Docker- oder Podman-Placement auswählen;
13. lokale Pfad-, Port-, Media-, Endpoint- und Secret-Bindings prüfen;
14. Inputs und Outputs typisiert verbinden;
15. Ressourcen-, Safety-, Egress- und Cleanup-Plan erzeugen;
16. Plan validieren und Hash bilden;
17. Bestätigungen prüfen;
18. erst danach Mutation zulassen.

## 21. Override-Regeln

| Klasse | Beispiel | Regel |
|---|---|---|
| `SAFE_RUNTIME` | lokaler Port oder Zielroot | lokal zulässig |
| `RESOURCE_WITHIN_BOUNDS` | CPU/RAM innerhalb Package- und Hostgrenzen | Planner prüft Reserve |
| `SQL_SEMANTIC` | andere SQL-Version | nur bei erfülltem Purpose und Version Constraint |
| `SAFETY_RELEVANT` | längere Stressdauer | explizite Bestätigung und harte Grenze |
| `EXTERNAL_SQL_SUPPORT` | Hadoop- oder REST-Testendpoint | SQL Purpose und Network Policy erforderlich |
| `FORBIDDEN` | Systempfad, produktiver Endpoint, fremde Ressource | immer ablehnen |

## 22. Control Plane

Serialisierbare Commands:

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

CLI und spätere REST-/UI-Adapter verwenden dieselben Commands und Events.

## 23. Vertragsversionierung

Getrennt versioniert werden:

- SQL Lab Request;
- SQL Purpose;
- Lab Package;
- Component Type;
- Action Type;
- DataSet;
- Workflow;
- Provider;
- Evidence;
- Control Plane.

Unbekannte Major-Versionen werden abgelehnt. Felder werden nicht still ignoriert.

## 24. Architekturbeweise vor `1.0`

1. SQL Server Quick Environment auf Docker;
2. derselbe logische Contract auf Podman;
3. SQL Server auf Hyper-V;
4. Performance-Demo mit DataSet und Workflow;
5. Analyze-Szenario mit Frameworkinstallation und Finding-Assertion;
6. SQL Server plus Domain Controller;
7. später SQL Server plus Hadoop für PolyBase oder SQL Server plus REST-Mock-Service.

## 25. Abnahmekriterien

- jedes Package besitzt SQL Purpose;
- primäre SQL Components sind Pflicht;
- Supporting Components haben einen dokumentierten SQL-Bezug;
- Hyper-V, Docker und Podman erfüllen denselben übergeordneten Vertrag;
- Umgebung, Installation, Testdaten und Workflow sind vollständig beschreibbar;
- Inputs und Outputs sind typisiert;
- Composite SQL Topologies sind expandierbar;
- Plan, State, Events und Cleanup sind providerunabhängig;
- SQL- und Supporting-Evidence sind getrennt und privacy-sicher;
- keine allgemeine Nicht-SQL-Labplattform entsteht.
