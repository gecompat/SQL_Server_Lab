# Projektintegrationsvertrag

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_DECISION_DRAFT` |
| Vertragsversion | `0.3` |
| Stand | 2026-08-12 |
| Primärkonsumenten | `SQL_PerformanceSchulung`, `SQL_Server_Analyze`, `SQL_Server_Toolbelt` |
| Hauptzweck | Übergabe SQL-zentrierter Lab Packages |
| Maßgebliche Scope-Entscheidung | [SQL-Server-zentrierte Scope-Entscheidung](./SQL_SERVER_CENTRIC_SCOPE_DECISION.md) |

## 1. Zweck

Dieser Vertrag definiert, wie ein konsumierendes SQL-Server-Projekt dem Lab mitteilt:

- welchen SQL-Server-Zweck der Lauf besitzt;
- welche SQL-Server-Instanzen oder -Topologien erforderlich sind;
- welche Supporting Components für diesen SQL-Zweck benötigt werden;
- welche Projektartefakte installiert werden;
- wie synthetische Testdaten erzeugt und geprüft werden;
- welche Workloads, Demos oder Analysekonstellationen auszuführen sind;
- welche SQL- und Infrastrukturevidenz beobachtet wird;
- welche Assertions gelten;
- wie Cleanup, Reset und Recovery erfolgen.

Der Vertrag verhindert, dass jedes Projekt Provider-, Lifecycle-, State-, Secret- oder Fault-Injection-Logik selbst implementiert.

## 2. Verantwortungsgrenze

Der Project Adapter ist nicht die vollständige Ausführungsschnittstelle. Er entdeckt und bindet versionierte **SQL Server Lab Packages**.

```text
Project Adapter
    ↓
SQL Server Lab Package
    ├─ SqlPurpose
    ├─ Environment Blueprint
    │   ├─ Primary SQL Components
    │   └─ Supporting Components
    ├─ Deployment Units
    ├─ DataSets
    ├─ Workflow
    ├─ Probes und Assertions
    └─ Privacy-, Trust-, License- und Cleanup-Policy
```

## 3. Eigentumsmodell

### 3.1 `SQL_Server_Lab`

Das Lab verantwortet:

- Host-Preflight;
- Package-, Schema- und Vertrauensprüfung;
- SQL- und Supporting-Component-Type-Registry;
- Hyper-V-, Docker- und Podman-Provider;
- Topologie- und Placementplanung;
- Container-, VM-, Netzwerk- und Storage-Lifecycle;
- lokale State-, Secret- und Binding-Grenzen;
- Ressourcen- und Fault-Profile;
- Workflow-, Operation- und Event Engine;
- generischen Cleanup- und Compensation-Mechanismus;
- lokale technische Evidence-Hülle und sanitisierte Summary.

### 3.2 Konsumierendes Projekt

Das Projekt verantwortet:

- Project Adapter und SQL Package Catalog;
- `SqlPurpose`;
- SQL Environment Blueprints;
- Installations-, Update- und Konfigurationsartefakte;
- synthetische DataSet-Definitionen;
- Workloads und Sessionabläufe;
- fachliche Probes und Assertions;
- projektspezifischen Cleanup innerhalb der bereitgestellten SQL-Komponenten;
- Quellen-, Lizenz- und Privacy-Regeln seiner Inhalte.

### 3.3 Supporting Extensions

Eine Supporting Extension darf neue Component- oder Action Types bereitstellen, beispielsweise:

- Domain Controller für Windows Authentication oder HA;
- Hadoop für PolyBase;
- REST-Testdienst als SQL-Client oder Datenquelle;
- Load Driver;
- Network Fault Controller.

Sie darf nur durch ein SQL Package mit dokumentiertem `SqlPurpose` verwendet werden.

## 4. Aufrufmodelle

### 4.1 Lokaler Sibling-Checkout

```text
<Workspace>/
├── SQL_Server_Lab/
├── SQL_Server_Analyze/
├── SQL_PerformanceSchulung/
└── SQL_Server_Toolbelt/
```

Der lokale Projektroot wird beim Aufruf explizit gebunden. Kein absoluter Pfad wird versioniert.

### 4.2 Freigegebenes Package

Ein Projekt kann ein privacy-geprüftes, versioniertes Package bereitstellen. Das Lab prüft:

- Package Contract und SQL Purpose;
- Hashes;
- Core-Kompatibilität;
- Required Component und Action Types;
- Trust Class;
- Artefaktgrenzen;
- Lizenz- und Privacy-Policy.

### 4.3 Lokale Package Registry

Eine spätere lokale Registry kann Packages anhand ID, Version und Hash auflösen. Hostbindings und Secrets bleiben lokale Konfiguration.

### 4.4 Git-Submodule

Git-Submodule sind nicht der Standard. Der Vertrag funktioniert mit Sibling-Checkout, geprüftem Archiv oder lokaler Registry.

## 5. Project Adapter

### 5.1 Pflichtinformationen

Konzeptioneller Entwurf:

```json
{
  "AdapterContractVersion": "0.3",
  "ProjectId": "SQL_EXAMPLE_PROJECT",
  "DisplayName": "SQL Example Project",
  "SupportedLabCoreVersions": ["0.x"],
  "SqlPackageCatalogs": ["relative/catalog/path"],
  "DefaultPackageRefs": [],
  "TrustPolicy": "PROJECT_CONTENT",
  "DataClassification": "SYNTHETIC_ONLY",
  "PrivacyExportPolicy": "NO_AUTOMATIC_EXPORT",
  "LicenseNotice": "relative/licence/path",
  "KnownLimitations": []
}
```

### 5.2 Der Adapter enthält nicht

- Providerbefehle;
- reale Endpunkte;
- Secret-Werte;
- feste Docker-, Podman- oder Hyper-V-Ressourcen;
- vollständige Setup-, Workload- oder Cleanup-Logik;
- absolute Hostpfade;
- unabhängige Nicht-SQL-Packages.

### 5.3 Pfadregeln

- Katalog- und Packagepfade sind relativ zum gebundenen Projektroot.
- `..`-Pfadtraversierung ist unzulässig.
- Symbolische Links oder Junctions außerhalb des Projektroots werden abgelehnt.
- Artefakte werden gegen Package-Hashes geprüft.
- Das Lab verändert keine Projektdatei, um Runtimewerte einzutragen.

## 6. SQL Server Lab Package

### 6.1 `SqlPurpose`

Jedes Package deklariert:

- Purpose ID und Class;
- SQL-Zielversionen;
- Betriebssystem- und Editionsconstraints;
- Required SQL Capabilities;
- Primary SQL Components;
- Supporting Components mit Begründung;
- erwartete SQL-Evidenz;
- Known Limitations.

### 6.2 Environment Blueprint

Das Blueprint beschreibt:

- eine oder mehrere SQL-Server-Komponenten;
- logische Rollen;
- Networks und Storage Claims;
- Relations;
- optionale Supporting Components;
- Required Capabilities;
- Lifecycle Policy.

### 6.3 Deployment Units

Deployment Units installieren oder konfigurieren beispielsweise:

- SQL_Server_Analyze;
- Performance-Schulungs-Framework;
- SQL_Server_Toolbelt-Modul oder -Modulpaket;
- markierte Testdatenbank;
- SQL Agent;
- Service Account und Domain Join;
- PolyBase-Konfiguration;
- Workload Driver.

### 6.4 DataSets

DataSets definieren:

- Ziel-SQL-Komponente;
- Generator oder synthetische Fixture;
- Seed, Scale und Distribution;
- Verifikation;
- exportierte Datenbank- oder Objektbindings;
- Reset und Cleanup.

### 6.5 Workflow

Der Workflow verknüpft Deployment Units, DataSets, Workloads, Probes, Assertions und Cleanup über typisierte Inputs und Outputs.

## 7. Runtime Context und Bindings

Der lokale Run Context enthält:

- Lab Run ID;
- Plan-Hash;
- SQL Purpose;
- Package- und Vertragsversionen;
- Component- und Providerzuordnung;
- Runtime Bindings;
- Capability-Vektor;
- Safety Class;
- Timeouts;
- Operation- und Abbruchstatus;
- lokale Artefaktroots;
- Cleanup- und Compensation-Stack.

Beispielbindings:

```text
binding.sql-primary.endpoint.sql
binding.sql-primary.credential-ref.admin
binding.sql-primary.metadata.product-version
binding.dataset.database.name
binding.domain.endpoint.dns
binding.hadoop.endpoint.hdfs
binding.api.endpoint.http-base
```

Konkrete Werte entstehen erst lokal. Secret-Werte werden nicht in normale Bindings, Events oder Evidence kopiert.

## 8. Installations- und Testreihenfolge

Ein Package kann beispielsweise ausdrücken:

```text
Provision SQL environment
  -> Wait for SQL readiness
  -> Provision required Supporting Components
  -> Install project framework
  -> Create marked synthetic database
  -> Generate DataSet
  -> Verify DataSet
  -> Capture baseline
  -> Run controlled workload
  -> Observe SQL evidence
  -> Assert SQL contract
  -> Cleanup project objects
  -> Destroy or preserve environment according to request
```

Der Provider verantwortet Infrastruktur. Das Project Package verantwortet SQL-Inhalte und fachliche Prüfung.

## 9. Integration `SQL_Server_Analyze`

### 9.1 Package-Familien

```text
SQL_SERVER_ANALYZE_QUICK
SQL_SERVER_ANALYZE_DIAGNOSTIC_SCENARIOS
SQL_SERVER_ANALYZE_INFRASTRUCTURE_SCENARIOS
```

### 9.2 Inhalte

- SQL-Server-Environment;
- Frameworkinstallation und -update;
- synthetische DataSets;
- Blocking-, Wait-, TempDB-, I/O-, Query-Store-, XE- und Infrastrukturworkloads;
- Analyzer-Probes;
- Finding-, Status- und Resultset-Assertions;
- Windows- und Linux-Zielumgebungen für SQL Server 2019, 2022 und 2025;
- projektspezifischer Cleanup.

### 9.3 Grenze

Frameworkupdate ist eine Deployment Unit und keine Provideraktion. Es darf Topologie und Ressourcenidentität nicht ändern.

## 10. Integration `SQL_PerformanceSchulung`

### 10.1 Package-Familien

```text
SQL_PERFORMANCE_QUICK_ENVIRONMENT
SQL_PERFORMANCE_DEMO_CORE
SQL_PERFORMANCE_DEMO_INFRASTRUCTURE
```

### 10.2 Erhaltener Demo-Vertrag

- Demo-ID und Lernziel;
- Preflight;
- Setup;
- Baseline;
- Demonstration;
- Observation;
- Mitigation;
- Comparison;
- Cleanup;
- Invarianten und Messrichtungen;
- Sicherheitsstufe Grün, Gelb oder Rot.

### 10.3 Abbildung

| Schulungsinhalt | Lab-Package-Vertrag |
|---|---|
| SQL-Testinstanz | Primary SQL Component |
| Demo-Framework | Deployment Units |
| synthetische Daten | DataSet |
| Baseline und Demonstration | Workflow und Workload |
| Observation | Probe |
| Comparison | Assertion |
| Gelb/Rot | Safety Class, Resource und Fault Profile |
| Cleanup | Project Cleanup plus Lab Compensation |

Dieser Adapter dient der Konstruktion reproduzierbarer Beispiele. Sein Standard
ist die aktuelle SQL-Version auf Linux. Ein Package darf Windows oder eine
andere katalogisierte Version anfordern, wenn die Beispielkonstellation dies
fachlich benötigt. Das Schulungsrepository ist nicht Eigentümer der allgemeinen
SQL-Mehrversions-Abnahmematrix.

## 10a. Integration `SQL_Server_Toolbelt`

### 10a.1 Package-Familien

```text
SQL_SERVER_TOOLBELT_MODULE
SQL_SERVER_TOOLBELT_MODULE_SET
SQL_SERVER_TOOLBELT_COMPATIBILITY
```

### 10a.2 Erhaltener Modulvertrag

- Modul-ID und Modulversion;
- Abhängigkeiten und Installationsreihenfolge;
- lokale oder zentrale Bereitstellungsart;
- Install-, Update- und Uninstall-Entrypoints;
- Vorbedingungen und unterstützte SQL-Versionen;
- Windows- und Linux-Zielumgebungen für SQL Server 2019, 2022 und 2025;
- idempotente Validierung der bereitgestellten Objekte;
- modulbezogene Cleanup- und Recovery-Regeln;
- Kompatibilitätsevidenz für SQL Server 2019, 2022 und 2025 im
  Toolbelt-Repository.

### 10a.3 Abbildung

| Toolbelt-Inhalt | Lab-Package-Vertrag |
|---|---|
| SQL-Zielinstanz | Primary SQL Component |
| Modul oder Modulset | Deployment Units |
| Abhängigkeiten | typisierte Inputs und Ausführungsreihenfolge |
| Install/Update/Uninstall | Workflow Actions |
| Objekt- und Versionsprüfung | Probe und Assertion |
| lokale oder zentrale Bereitstellung | Package-Parameter und Bindings |
| Cleanup | Project Cleanup plus Lab Compensation |

## 11. SQL Supporting Components

### 11.1 Domain Controller

Zulässig für:

- Windows Authentication;
- Kerberos und SPN;
- Service Accounts;
- WSFC, AG und FCI;
- gruppenbasierte Berechtigungen.

### 11.2 Hadoop

Zulässig für:

- PolyBase;
- synthetische externe Daten;
- SQL-Server-Performance- und Fehlerbeobachtung.

Nicht Ziel ist ein allgemeines Hadoop-Lab.

### 11.3 REST-/HTTP-Service

Zulässig als:

- SQL-Server-Client;
- SQL-Datenquelle oder -ziel;
- reproduzierbarer Mock-Service;
- Workload Driver.

Nicht Ziel ist ein allgemeines API-Testframework.

## 12. Externe Ressourcen

Externe Ressourcen verwenden einen expliziten Management Mode:

```text
ATTACHED
EXTERNAL_READ_ONLY
EXTERNAL_MUTABLE
```

Regeln:

- konkrete Endpunkte werden lokal gebunden;
- `SqlPurpose` und Network Policy sind Pflicht;
- produktive Systeme sind kein Standardtarget;
- `EXTERNAL_MUTABLE` benötigt ausdrückliche Freigabe;
- Cleanup- und Reversibility-Vertrag sind Pflicht;
- Runtimewerte gelangen nicht automatisch in exportierbare Evidence.

## 13. Trust- und Ausführungsregeln

Trust Classes:

```text
CORE_BUILTIN
OFFICIAL_EXTENSION
PROJECT_CONTENT
LOCAL_TRUSTED
UNTRUSTED
```

Project Content darf:

- innerhalb gebundener SQL- und Supporting Components arbeiten;
- synthetische Daten erzeugen;
- registrierte Actions verwenden;
- lokale Evidence produzieren.

Project Content darf nicht:

- Providerressourcen direkt löschen;
- fremde Components adressieren;
- unbekannte Skripte außerhalb des Package-Scopes laden;
- Secrets persistieren;
- externe Endpunkte ohne SQL Purpose und Policy verwenden.

## 14. Safety Classes

```text
SAFE_READ_ONLY
LAB_MUTATION
RESOURCE_PRESSURE
INSTANCE_CHANGE
INFRASTRUCTURE_CHANGE
DESTRUCTIVE_DISPOSABLE
```

Mapping Schulung:

- Grün → `LAB_MUTATION` oder niedriger;
- Gelb → `RESOURCE_PRESSURE`;
- Rot → mindestens `INSTANCE_CHANGE`, häufig `INFRASTRUCTURE_CHANGE` oder `DESTRUCTIVE_DISPOSABLE`.

## 15. Status- und Fehlercodes

```text
ADAPTER_READY
ADAPTER_UNSUPPORTED_CONTRACT
SQL_PURPOSE_REQUIRED
PACKAGE_NOT_FOUND
PACKAGE_HASH_MISMATCH
PACKAGE_UNSUPPORTED_CONTRACT
PACKAGE_UNTRUSTED
PRIMARY_SQL_COMPONENT_REQUIRED
SUPPORTING_COMPONENT_WITHOUT_SQL_PURPOSE
COMPONENT_TYPE_MISSING
ACTION_TYPE_MISSING
BINDING_TYPE_MISMATCH
DATASET_VERIFICATION_FAILED
PROJECT_CONTENT_FAILED
PROJECT_ASSERTION_FAILED
PROJECT_CLEANUP_FAILED
PROJECT_ARTIFACT_SCOPE_VIOLATION
PROJECT_SECRET_POLICY_VIOLATION
PROJECT_PARTIAL_SUCCESS
```

Codes bleiben englisch und sprachunabhängig.

## 16. Control Plane

CLI, spätere REST API oder UI verwenden dieselben serialisierbaren Commands, Plans, Operations, Events und Results. Project Content hängt nicht von `Write-Host`-Text ab.

## 17. Datenschutzgrenze

- Packages enthalten nur synthetische oder öffentliche Inhalte.
- Reale lokale Runtimewerte werden nicht automatisch versioniert oder exportiert.
- Secret-Werte sind auch in technischer Evidence unzulässig.
- Sanitized Summary und Local Technical Evidence sind getrennt.
- Externe Responses, SQL-Texte, Pläne und Logs benötigen vor Export eine eigene Privacy-Prüfung.

## 18. Vertragsversionierung

Getrennt versioniert werden:

- Project Adapter;
- SQL Purpose;
- Lab Package;
- Component Type;
- Action Type;
- DataSet;
- Workflow;
- Provider;
- Evidence;
- Control Plane.

`1.0` wird erst nach produktiver Abnahme aller drei Primärkonsumenten und der
drei Kernprovider festgeschrieben.

## 19. Abnahmekriterien

- Adapter entdecken SQL Packages;
- jedes Package besitzt SQL Purpose;
- Primary SQL Components sind Pflicht;
- Supporting Components besitzen dokumentierten SQL-Bezug;
- Umgebung, Installation, Testdaten, Workload, Observation, Assertion und Cleanup sind vollständig beschreibbar;
- Projekte benötigen keine Providerbefehle;
- Inputs und Outputs werden typisiert verbunden;
- Hyper-V, Docker und Podman nutzen denselben übergeordneten Contract;
- alle drei Primärprojekte nutzen denselben Lab-Core;
- unbekannte oder untrusted Erweiterungen werden abgelehnt;
- Cleanup und Compensation laufen auch bei Project-Fehlern;
- keine unabhängigen Nicht-SQL-Packages werden akzeptiert.
