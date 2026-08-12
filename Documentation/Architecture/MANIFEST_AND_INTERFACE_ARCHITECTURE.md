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

Dieses Dokument definiert die geplanten maschinenlesbaren Verträge und ihre Auflösungsreihenfolge.

SQL Server ist verbindlicher Hauptzweck. Supporting Components werden über erweiterbare Typen modelliert, damit SQL-Server-Szenarien wie Windows Authentication, Always On, PolyBase oder REST-Integration nicht durch zu enge Schemas verhindert werden.

## 2. Architekturprinzipien

1. **SQL Purpose ist Pflicht:** Jeder ausführbare Request und jedes Package besitzt einen SQL-Server-Zweck.
2. **Primäre SQL Components:** Mindestens eine primäre SQL-Server-Komponente ist erforderlich.
3. **Versionskatalog statt festem Enum:** SQL-Server-Versionen werden über katalogisierte Versionseinträge und Constraints aufgelöst.
4. **Supporting Components nur mit SQL-Bezug:** Domain, Hadoop, REST, Client oder Observability sind Hilfssysteme eines SQL-Szenarios.
5. **Komponenten statt Providerbefehle:** Packages enthalten keine `docker`, `podman`- oder Hyper-V-Befehle.
6. **Packages statt Universal-Skripte:** Installation, Datenbankartefakte, Testdaten, Workload und Prüfung sind getrennte Package-Inhalte.
7. **Typisierte Actions:** SQL-, Artifact-, Supporting-, Fault-, Probe- und Assertion-Aktionen sind registriert und versioniert.
8. **Runtime Bindings:** Endpunkte, Pfade und Secret-Referenzen entstehen erst lokal.
9. **Resource Assessment vor Mutation:** CPU, RAM, Storage, Provider-Overhead und Hostreserve werden sichtbar bewertet.
10. **Ressourcenmangel ist übersteuerbar:** Vorhergesagte Unterversorgung kann ausdrücklich bestätigt werden; Safety-Verletzungen nicht.
11. **Cleanup Plan vor Mutation:** Kein Provisioning ohne maschinenlesbaren Recovery- und Cleanup-Plan.
12. **Provider-Capabilities statt Gleichheitsannahmen:** Hyper-V, Docker und Podman werden getrennt nachgewiesen.
13. **Strikte Schemas:** `additionalProperties` ist standardmäßig `false`.
14. **Stabile Codes und Events:** Konsolentext ist keine Integrationsschnittstelle.
15. **Cleanup als Kernvertrag:** Jede Mutation ist registriert, kompensierbar oder führt zu `RECOVERY_REQUIRED`.

## 3. Vertragsfamilien

### 3.1 Core Contracts

| Schema | Zweck |
|---|---|
| `sql-lab-request.schema.json` | konkrete SQL-Server-Lab-Anforderung |
| `sql-purpose.schema.json` | fachlicher SQL-Zweck und Version Constraints |
| `sql-lab-package.schema.json` | Package aus Environment, Content, DataSets und Workflow |
| `environment-blueprint.schema.json` | primäre SQL Components, Supporting Components und Relations |
| `workflow.schema.json` | typisierter Ausführungsgraph |
| `runtime-binding.schema.json` | lokale, typisierte Outputs und Referenzen |
| `resource-assessment.schema.json` | Bedarf, Hostreserve, Defizit, Schätzqualität und Override |
| `cleanup-plan.schema.json` | Compensation-, Recovery-, Retention- und Löschplan |
| `bound-plan.schema.json` | vollständig aufgelöster read-only Plan |
| `run-state.schema.json` | tatsächliche Ressourcen und Schrittstatus |
| `recovery-state.schema.json` | offene Cleanup- und Compensation-Schritte |
| `run-event.schema.json` | strukturierte Zustands- und Fortschrittsereignisse |
| `evidence.schema.json` | lokale technische Evidenz und sanitisierte Summary |

### 3.2 Registry Contracts

| Schema | Zweck |
|---|---|
| `sql-version.schema.json` | SQL-Server-Version, Status, Provider Support und Capabilities |
| `component-type.schema.json` | primärer SQL- oder Supporting-Component-Type |
| `action-type.schema.json` | ausführbare typisierte Aktion |
| `provider.schema.json` | Hyper-V-, Docker- oder Podman-Provider |
| `capability.schema.json` | normalisierte Fähigkeit und Nachweisgrenze |
| `fault-type.schema.json` | kontrollierte SQL-bezogene Fault Injection |
| `control-plane-adapter.schema.json` | CLI-, REST- oder UI-Anbindung |

Der aktuelle M1-Schnitt persistiert noch keine Capability-Dateien. Er projiziert
stattdessen die bestehenden `provider.json`-Angaben als versionierten,
deklarativen `SqlServerLab.ProviderCapability`-Vertrag in die Workflow-Sicht.
`DECLARED_SUPPORTED` bedeutet dabei ausschließlich eine Metadatenbehauptung;
Runtime-, Gast- und End-to-End-Nachweise bleiben getrennte Evidenz.

### 3.3 Content Contracts

| Schema | Zweck |
|---|---|
| `deployment-unit.schema.json` | Installation oder Konfiguration innerhalb einer Component |
| `dataset.schema.json` | Erzeugung, Restore, Verifikation, Reset und Cleanup von Testdaten |
| `database-artifact.schema.json` | Lab-Backup, öffentliche Beispieldatenbank oder lokales Nicht-Produktionsbackup |
| `public-sample-entry.schema.json` | Quelle, Lizenz, Hash, Größe und Versionskompatibilität öffentlicher Beispiele |
| `workload.schema.json` | kontrollierte SQL- oder Client-Last |
| `probe.schema.json` | SQL-, Infrastruktur- oder Supporting-Observation |
| `assertion.schema.json` | fachliche oder technische Erwartung |
| `artifact.schema.json` | hashgebundenes Package-Artefakt |

## 4. `sql-purpose.schema.json`

Pflichtfelder:

- `PurposeId`;
- `PurposeClass`;
- `TargetSqlVersionConstraints`;
- `TargetOperatingSystems`;
- `TargetEditions`;
- `RequiredSqlCapabilities`;
- `PrimarySqlComponentRefs`;
- `SupportingComponentRefs`;
- `ScenarioRefs`;
- `ExpectedSqlEvidence`;
- `KnownSqlLimitations`.

`TargetSqlVersionConstraints` referenziert Versionseinträge oder beschreibt Constraints. Eine dauerhafte Enumeration einzelner Produktjahre im Core-Schema ist unzulässig.

## 5. `sql-version.schema.json`

Pflichtfelder:

- `VersionId`;
- Produktbezeichnung;
- `ProductMajorVersion`;
- `Status`;
- `SupportedOperatingSystems`;
- `SupportedEditions`;
- `SupportedCompatibilityLevels`;
- `ProviderSupport`;
- `ImageOrMediaResolvers`;
- `Capabilities`;
- `RestoreCompatibility`;
- `DefaultResourceGuidance`;
- `KnownLimitations`;
- `EvidenceDate`.

Status:

```text
EXPERIMENTAL
SUPPORTED
DEPRECATED
RETIRED
BLOCKED
```

Derzeit sind SQL Server 2019, SQL Server 2022 und SQL Server 2025 als aktive Katalogeinträge vorgesehen. Diese Liste ist ein aktueller Implementierungsstand, keine Schemaobergrenze.

## 6. `sql-lab-request.schema.json`

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

Optionale bewusste Ressourcenübersteuerung:

```text
AllowedOverrides.AllowResourceOvercommit
```

Der Request darf dadurch keinen Safety-, Scope-, Secret-, Lizenz-, Versions- oder Datenklassifikationsblock umgehen.

## 7. `sql-lab-package.schema.json`

Ein Package enthält:

- Package-ID und Version;
- Project-ID;
- unterstützte Lab-Core-Versionen;
- `SqlPurposeCatalog`;
- Environment-Katalog;
- Scenario-Katalog;
- Deployment Units;
- DataSets;
- Database Artifacts;
- Workloads, Probes und Assertions;
- Required Component und Action Types;
- Artefakte und Hashes;
- Secret Requirements ohne Werte;
- Resource Policy;
- Recovery und Cleanup Policy;
- Trust Class;
- Data Classification;
- License Notice;
- Privacy Export Policy;
- Known Limitations.

## 8. `environment-blueprint.schema.json`

### 8.1 Primary SQL Component

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

### 8.2 Supporting Component

Zusätzliche Pflichtfelder:

- `SupportsSqlPurpose`;
- `SqlRelationRefs`;
- `Justification`;
- `KnownStatementBoundary`.

### 8.3 Relations

Beispiele:

```text
authenticates-against
joined-to-domain
connects-to
replicates-to
reads-external-data-from
restores-from
calls-http
observes
fault-targets
```

Jede Relation besitzt einen SQL-Zweckbezug.

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

Deployment Units installieren beispielsweise SQL_Server_Analyze, das
Schulungsframework, SQL_Server_Toolbelt-Module, SQL Agent-Konfiguration, Domain
Join oder PolyBase-Supporting-Inhalte.

## 10. `dataset.schema.json`

Pflichtfelder:

- `DataSetId`;
- `TargetComponentRefs`;
- `SqlPurposeRef`;
- `CreationMode`;
- Generator, Fixture oder `DatabaseArtifactRef`;
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
LOAD_PUBLIC_SAMPLE
RESTORE_LAB_ARTIFACT
RESTORE_USER_NON_PRODUCTION_ARTIFACT
DERIVE
STREAM
```

## 11. `database-artifact.schema.json`

Pflichtfelder:

- `ArtifactId`;
- `ArtifactClass`;
- `SourceType`;
- Source Reference;
- Hash oder Prüfsumme;
- Artefaktgröße;
- erwartete Restore-Größe;
- Data Classification;
- License und Source Notice;
- unterstützte SQL-Server-Quell- und Zielversionen;
- `RestoreFileMappingPolicy`;
- Verification Actions;
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

`PRODUCTION_DATA` und `UNKNOWN` werden abgelehnt. Zulässige lokale Backups werden weder automatisch versioniert noch exportiert.

## 12. `resource-assessment.schema.json`

Der Record enthält je Ressourcendimension:

- `ResourceType`;
- gemessene Kapazität;
- geschätzten Peakbedarf;
- Hostreserve;
- Defizit oder verbleibende Reserve;
- Schätzqualität;
- Status;
- Override-Möglichkeit;
- Failure Impact;
- Cleanup Impact.

Status:

```text
RESOURCE_OK
RESOURCE_WARNING
RESOURCE_INSUFFICIENT_OVERRIDABLE
RESOURCE_HARD_BLOCK
RESOURCE_UNKNOWN
```

Prüfdimensionen umfassen mindestens CPU, RAM, freien Speicher, Image-/VHDX-/Container-Overhead, Data/Log/TempDB, Backup- und Restore-Bedarf, Ports, Providerfähigkeit und sichere Pfade.

## 13. `cleanup-plan.schema.json`

Pflichtfelder:

- `RunId`;
- Plan-Hash;
- geplante Ressourcenklassen;
- Owner- und Scope-Marker;
- erwartete Providerobjekte;
- Abhängigkeits- und Löschreihenfolge;
- Step Compensations;
- Artifact-, DataSet-, Secret- und Cache-Retention;
- Timeouts und Retry Limits;
- Recovery Commands;
- erwarteter Endzustand.

Ohne validierten Cleanup Plan darf kein mutierender Run beginnen.

## 14. `workflow.schema.json`

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

## 15. `runtime-binding.schema.json`

Beispiele:

```text
binding.sql-primary.endpoint.sql
binding.sql-primary.credential-ref.admin
binding.sql-primary.metadata.product-version
binding.dataset.database.name
binding.database-artifact.local-path
binding.domain.endpoint.dns
binding.hadoop.endpoint.hdfs
binding.api.endpoint.http-base
```

Ein Binding enthält Type, Producer, Sensitivity Class, Scope, Lifetime, Consumer Allowlist und Export Policy. Der tatsächliche Wert steht nur im lokalen Runtime State.

## 16. `provider.schema.json`

Verbindliche Provider-IDs:

```text
provider.hyperv
provider.docker
provider.podman
```

Pflichtoperationen:

- `DetectCapabilities`;
- `ValidateResourceGraph`;
- `AssessResources`;
- read-only `Plan`;
- `Provision`;
- `GetStatus`;
- `Stop`;
- `Start`;
- `Reset`, soweit unterstützt;
- `Destroy`;
- `ResumeCleanup`;
- `ExecuteInResource`, soweit unterstützt;
- Rückgabe tatsächlicher IDs und Runtime Bindings.

Docker und Podman besitzen getrennte Capability Records.

## 17. `capability.schema.json`

Capabilities verwenden namespaced Codes, beispielsweise:

```text
provider.docker.compose
provider.podman.compose
provider.hyperv.powershell-direct
mssql.version.major.15
mssql.version.major.16
mssql.version.major.17
mssql.sql-agent
mssql.windows-authentication
mssql.polybase
identity.active-directory
fault.network.netem
fault.storage.block-io-throttle
```

Die derzeitigen Major-Versionen 15, 16 und 17 sind Beispiele aktueller Katalogeinträge. Neue Major-Versionen werden durch neue Records ergänzt.

## 18. `bound-plan.schema.json`

Der Bound Plan enthält:

- SQL Purpose;
- Package-, Vertrags- und SQL-Versionseinträge;
- expandierte SQL-Topologie;
- Supporting Components mit Begründung;
- ausgewählte Provider und Handler;
- Resource Assessment und Hostreserve;
- dokumentierte Resource Overrides;
- lokale Bindings in redigierter Form;
- Deployment Units, DataSets, Database Artifacts und Workflow Steps;
- Secret Requirements ohne Werte;
- Faults und harte Grenzen;
- Side Effects und Safety Classes;
- Destructive Actions;
- vollständigen Cleanup- und Compensation-Plan;
- `NOT_EXECUTED`-Teile und Aussagegrenzen;
- Plan-Hash.

## 19. `run-state.schema.json` und `recovery-state.schema.json`

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
- Resource Override Acknowledgements;
- Health und SQL Readiness;
- Cleanup und Recovery.

Der Recovery State enthält nur noch offene Compensation-Schritte, letzte Fehlerklasse, Retry-Status und validierte Ressourcenidentitäten.

Beide States sind nicht exportierbar.

## 20. `run-event.schema.json`

Beispiele:

```text
PLAN_CREATED
RESOURCE_ASSESSMENT_COMPLETED
RESOURCE_OVERRIDE_REQUIRED
RESOURCE_OVERRIDE_ACKNOWLEDGED
PLAN_APPROVAL_REQUIRED
SQL_RESOURCE_PROVISIONING_STARTED
SQL_RESOURCE_READY
DATABASE_ARTIFACT_VERIFIED
DATASET_READY
STEP_STARTED
STEP_COMPLETED
STEP_FAILED
COMPENSATION_STARTED
CLEANUP_COMPLETED
RECOVERY_REQUIRED
```

Events enthalten keine Secrets oder unkontrollierten Runtime-Payloads.

## 21. Auflösungsreihenfolge

1. Request und Vertragsversion prüfen;
2. SQL Purpose prüfen;
3. Project Adapter und Package-Katalog auflösen;
4. Package-Hashes, Trust und Kompatibilität prüfen;
5. SQL-Versionseinträge und Constraints auflösen;
6. Environment Blueprint laden;
7. primäre SQL Components auflösen;
8. Supporting Components auf SQL-Bezug prüfen;
9. Composite SQL Components expandieren;
10. Deployment Units, DataSets, Database Artifacts und Workflow laden;
11. Action Types und Handler auflösen;
12. Host- und Provider-Capabilities read-only ermitteln;
13. Hyper-V-, Docker- oder Podman-Placement auswählen;
14. lokale Pfad-, Port-, Media-, Artifact- und Secret-Bindings prüfen;
15. Inputs und Outputs typisiert verbinden;
16. Resource Assessment erzeugen;
17. vollständigen Safety-, Egress-, Recovery- und Cleanup-Plan erzeugen;
18. Resource Overrides und andere Bestätigungen prüfen;
19. Plan validieren und Hash bilden;
20. erst danach Mutation zulassen.

## 22. Override-Regeln

| Klasse | Beispiel | Regel |
|---|---|---|
| `SAFE_RUNTIME` | lokaler Port oder Zielroot | lokal zulässig |
| `RESOURCE_WITHIN_BOUNDS` | CPU/RAM innerhalb Package- und Hostgrenzen | Planner prüft Reserve |
| `RESOURCE_INSUFFICIENT` | erwartetes CPU-, RAM- oder Storage-Defizit | nach expliziter Overcommit-Bestätigung zulässig |
| `SQL_SEMANTIC` | andere SQL-Version | nur bei erfülltem Purpose und Version Constraint |
| `SAFETY_RELEVANT` | längere Stressdauer | explizite Bestätigung und harte Grenze |
| `EXTERNAL_SQL_SUPPORT` | Hadoop- oder REST-Testendpoint | SQL Purpose und Network Policy erforderlich |
| `FORBIDDEN` | Systempfad, produktiver Endpoint, fremde Ressource, unklassifiziertes Backup | immer ablehnen |

Ein Resource Override verändert nicht die gemessenen Werte oder den Status und setzt Cleanup, Scope, Datenklassifikation oder absolute Safety Limits nicht außer Kraft.

## 23. Control Plane

Serialisierbare Commands:

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

CLI und spätere REST-/UI-Adapter verwenden dieselben Commands und Events.

## 24. Vertragsversionierung

Getrennt versioniert werden:

- SQL Lab Request;
- SQL Purpose;
- SQL Version Catalog;
- Lab Package;
- Component Type;
- Action Type;
- DataSet;
- Database Artifact;
- Resource Assessment;
- Cleanup Plan;
- Workflow;
- Provider;
- Evidence;
- Control Plane.

Unbekannte Major-Versionen werden abgelehnt. Felder werden nicht still ignoriert.

## 25. Architekturbeweise vor `1.0`

1. SQL Server Quick Environment auf Docker;
2. derselbe logische Contract auf Podman;
3. SQL Server auf Hyper-V;
4. derzeitige SQL-Versionseinträge 2019, 2022 und 2025 ohne festes Core-Enum;
5. Probe-Erweiterung um einen synthetischen künftigen Versionseintrag ohne Schemaänderung;
6. Performance-Demo mit erzeugtem DataSet;
7. Restore eines Lab-erzeugten Backups in einem Folgerun;
8. Restore mindestens einer öffentlichen Demo-Datenbank;
9. Resource Assessment mit erfolgreichem Run;
10. Resource Assessment mit bewusst bestätigtem Overcommit und automatischem Cleanup nach provoziertem Fehler;
11. Analyze-Szenario mit Frameworkinstallation und Finding-Assertion;
12. SQL Server plus Domain Controller;
13. später SQL Server plus Hadoop für PolyBase oder SQL Server plus REST-Mock-Service.

## 26. Abnahmekriterien

- jedes Package besitzt SQL Purpose;
- primäre SQL Components sind Pflicht;
- SQL-Versionen sind katalog- und constraintbasiert;
- neue und alte Versionen können ohne Core-Neuentwurf ergänzt oder ausgesteuert werden;
- Supporting Components haben einen dokumentierten SQL-Bezug;
- Hyper-V, Docker und Podman erfüllen denselben übergeordneten Vertrag;
- Umgebung, Installation, Testdaten, Backups und Workflow sind vollständig beschreibbar;
- öffentliche Demo-Datenbanken und Lab-Backups sind zulässig und verifizierbar;
- Produktions- und unklassifizierte Daten bleiben blockiert;
- Resource Assessment ist vor Mutation vollständig;
- vorhergesagter Ressourcenmangel ist bewusst übersteuerbar;
- Safety- und Scope-Blocker bleiben nicht übersteuerbar;
- vor Mutation existiert ein vollständiger Cleanup Plan;
- fehlgeschlagene Runs sind automatisch und wiederaufnehmbar bereinigbar;
- Inputs und Outputs sind typisiert;
- Composite SQL Topologies sind expandierbar;
- Plan, State, Events und Cleanup sind providerunabhängig;
- SQL- und Supporting-Evidence sind getrennt und privacy-sicher;
- keine allgemeine Nicht-SQL-Labplattform entsteht.
