# Projektintegrationsvertrag

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_DECISION_DRAFT` |
| Vertragsversion | `0.2` |
| Stand | 2026-07-26 |
| Konsumenten | `SQL_Server_Analyze`, `SQL_PerformanceSchulung`, spätere kompatible Projekte |
| Maßgebliche Vertiefung | [Erweiterbarer Umgebungs- und Ausführungsvertrag](./EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md) |

## 1. Zweck

Dieser Vertrag definiert, wie ein konsumierendes Projekt dem Lab mitteilt:

- welche Umgebung benötigt wird;
- welche logischen Komponenten enthalten sein müssen;
- welche Software und Projektartefakte innerhalb der Komponenten installiert werden;
- wie synthetische Testdaten erzeugt und geprüft werden;
- welche Workloads, Demos oder Analysekonstellationen auszuführen sind;
- welche Beobachtungen und Assertions gelten;
- wie Cleanup, Reset und Recovery erfolgen.

Der Vertrag verhindert zugleich, dass jedes Projekt Provider-, Lifecycle-, State-, Secret- oder Fault-Injection-Logik selbst implementiert.

## 2. Neue Verantwortungsgrenze

**ENTSCHEIDUNG:** Der Project Adapter ist nicht die vollständige Ausführungsschnittstelle. Er dient als stabiler Einstiegspunkt zur Discovery und Bindung versionierter **Lab Packages**.

```text
Project Adapter
    ↓ findet und beschreibt
Lab Package
    ├─ Environment Blueprint
    ├─ Deployment Units
    ├─ DataSets
    ├─ Workflow
    ├─ Workloads / Probes / Assertions
    └─ Privacy-, Trust-, License- und Cleanup-Policy
```

Damit bleibt der Adapter klein und stabil, während neue Szenarien, Technologien und Installationsinhalte als versionierte Packages ergänzt werden können.

## 3. Eigentumsmodell

### 3.1 `SQL_Server_Lab`

Das Lab verantwortet:

- Host-Preflight und Capability-Ermittlung;
- Package-, Schema- und Vertrauensprüfung;
- Component-Type- und Action-Type-Registry;
- Expansion logischer Komponenten;
- Provider- und Placementplanung;
- Container-, VM-, Netzwerk- und Storage-Lifecycle;
- lokale State-, Secret- und Binding-Grenzen;
- Ressourcen- und Fault-Profile;
- Workflow- und Operation Engine;
- strukturierte Events;
- generischen Cleanup- und Compensation-Mechanismus;
- lokale technische Evidence-Hülle und sanitisierte Summary.

### 3.2 Konsumierendes Projekt

Das Projekt verantwortet:

- Project Adapter und Package Catalog;
- fachliche Environment Blueprints und Szenarien;
- Installations-, Update- und Konfigurationsartefakte;
- synthetische DataSet-Definitionen;
- Workloads und Sessionabläufe;
- Beobachtungs- und Messschritte;
- fachliche Assertions und Aussagegrenzen;
- projektspezifischen Cleanup innerhalb der bereitgestellten Komponenten;
- Lizenz-, Quellen- und Privacy-Regeln seiner Package-Inhalte.

### 3.3 Extension Packs

Technologiespezifische Erweiterungen verantworten:

- neue Component Types;
- Composite Expander;
- neue Action Types und Handler;
- technologiebezogene Health-Probes;
- technologiebezogene Binding Types;
- neue Fault Types;
- eigene Versionen, Capabilities, Trust- und Safety-Verträge.

Ein Projekt darf ein Extension Pack referenzieren. Es soll neue Infrastrukturtechnologie nicht als verborgenes Skript im Szenario nachbauen.

## 4. Aufrufmodelle

### 4.1 Lokaler Sibling-Checkout

Empfohlener Entwicklungsmodus:

```text
<Workspace>/
├── SQL_Server_Lab/
├── SQL_Server_Analyze/
└── SQL_PerformanceSchulung/
```

Der lokale Projektroot wird beim Aufruf explizit gebunden. Der versionierte Adapter enthält keinen absoluten Hostpfad.

### 4.2 Freigegebenes Package

Ein Projekt kann ein privacy-geprüftes, versioniertes Package bereitstellen. Das Lab prüft mindestens:

- Package Contract;
- Hashes;
- Core-Kompatibilität;
- erforderliche Component- und Action Types;
- Trust Class;
- Artefaktgrenzen;
- Lizenz- und Privacy-Policy.

### 4.3 Lokale Package Registry

Später kann eine lokale Registry Packages und Extension Packs anhand von ID, Version und Hash auflösen. Diese Registry ist lokale Konfiguration und kein Speicherort für Secrets oder reale Umgebungsdaten.

### 4.4 Git-Submodule

Git-Submodule sind nicht der Standard. Der Vertrag funktioniert unabhängig davon, ob ein Package aus einem Sibling-Checkout, einem geprüften Archiv oder einer lokalen Registry stammt.

## 5. Project Adapter

### 5.1 Pflichtinformationen

Der Adapter enthält konzeptionell:

```json
{
  "AdapterContractVersion": "0.2",
  "ProjectId": "EXAMPLE_PROJECT",
  "DisplayName": "Example Project",
  "SupportedLabCoreVersions": ["0.x"],
  "PackageCatalogs": ["relative/catalog/path"],
  "DefaultPackageRefs": [],
  "TrustPolicy": "PROJECT_CONTENT",
  "DataClassification": "SYNTHETIC_ONLY",
  "PrivacyExportPolicy": "NO_AUTOMATIC_EXPORT",
  "LicenseNotice": "relative/licence/path",
  "KnownLimitations": []
}
```

Das Beispiel ist kein endgültiges JSON-Schema.

### 5.2 Der Adapter enthält ausdrücklich nicht

- Providerbefehle;
- reale Endpunkte;
- Secret-Werte;
- feste Docker-/Podman-/Hyper-V-Ressourcen;
- fachliche Setup-, Workload- oder Cleanup-Skripte als lose Entrypointliste;
- absolute Repository- oder Hostpfade;
- eine vollständige Kopie des Package-Inhalts.

### 5.3 Pfadregeln

- Katalog- und Packagepfade sind relativ zum explizit gebundenen Projektroot.
- `..`-Pfadtraversierung ist unzulässig.
- Symbolische Links oder Junctions außerhalb des Projektroots werden abgelehnt.
- Artefakte werden gegen Package-Hashes geprüft.
- Das Lab verändert keine Projektdatei, um lokale Runtimewerte einzutragen.

## 6. Lab Package als eigentliche Projektschnittstelle

### 6.1 Environment Blueprint

Das Blueprint beschreibt logische Components und Beziehungen.

Beispiel für eine Performance-Demo:

```text
mssql.instance sql-primary
mssql.load-generator load-driver
connects-to load-driver -> sql-primary
```

Beispiel für eine spätere Hadoop-Konstellation:

```text
mssql.instance sql-source
hadoop.cluster analytics-cluster
http.service result-api

data-flow sql-source -> analytics-cluster
calls-http analytics-cluster -> result-api
```

### 6.2 Deployment Units

Deployment Units geben an, was innerhalb einer Component auszuführen ist, beispielsweise:

- Framework installieren;
- Datenbank und Schema erzeugen;
- Testdienst konfigurieren;
- SQL-Skripte ausführen;
- Dateien übertragen;
- REST-Konfiguration setzen;
- Hadoop-Jobartefakte bereitstellen.

### 6.3 DataSets

DataSets beschreiben unabhängig vom Installationsschritt:

- Zielkomponente;
- Generator oder Fixture;
- Seed und Skalierung;
- gewünschte Verteilung;
- Completion Signal;
- Verifikation;
- Reset und Cleanup;
- exportierte Bindings.

### 6.4 Workflow

Der Workflow verknüpft Deployment Units, DataSets, Workloads, Probes und Assertions über typisierte Inputs und Outputs.

Die bekannten Phasen bleiben:

```text
Arrange
Act
Observe
Assert
Cleanup
```

Innerhalb der Phasen sind mehrere, abhängige und begrenzt parallele Steps zulässig.

## 7. Runtime Context und Bindings

### 7.1 Run Context

Das Lab erzeugt einen lokalen Run Context mit:

- `LabRunId`;
- Plan-Hash;
- Package- und Vertragsversionen;
- Component- und Providerzuordnung;
- Runtime Bindings;
- Capability-Vektor;
- Safety Class;
- Timeouts;
- Operation- und Abbruchstatus;
- lokalen Artefaktroots;
- Cleanup- und Compensation-Stack.

### 7.2 Typisierte Bindings

Statische Packages referenzieren logische Bindings:

```text
binding.sql-primary.endpoint.sql
binding.sql-primary.credential-ref.admin
binding.dataset-demo.database.name
binding.api.endpoint.http-base
binding.hadoop.endpoint.hdfs
```

Konkrete Werte entstehen erst lokal. Secret-Werte werden nicht in normale Bindings oder persistierte Events kopiert.

### 7.3 Zielselektoren

Project Content adressiert Komponenten über logische Selektoren, beispielsweise:

```text
component-id = sql-primary
component-type = mssql.instance
role = primary
label = demo-target
```

Es adressiert keine Container-ID, VM-ID oder reale IP-Adresse.

## 8. Projektinterne Installationsreihenfolge

Ein Package kann beispielsweise folgende Abhängigkeiten ausdrücken:

```text
Provision sql-primary
  -> Wait for SQL readiness
  -> Install project framework
  -> Create synthetic database
  -> Generate deterministic DataSet
  -> Verify DataSet
  -> Run baseline
  -> Start controlled workload
  -> Observe
  -> Assert
  -> Cleanup project data
  -> Destroy or preserve environment according to Run Request
```

Der Provider verantwortet nur Provisionierung und Infrastrukturstatus. Das Project Package verantwortet Framework, Daten, Workload und fachliche Prüfung.

## 9. Integration `SQL_Server_Analyze`

### 9.1 Packages

Vorgesehene Package-Familien:

```text
SQL_SERVER_ANALYZE_QUICK
SQL_SERVER_ANALYZE_DIAGNOSTIC_SCENARIOS
SQL_SERVER_ANALYZE_INFRASTRUCTURE_SCENARIOS
```

### 9.2 Package-Inhalte

- Environment Blueprints für eine oder mehrere SQL-Server-Instanzen;
- Framework-Deployment-Units;
- synthetische DataSets;
- Blocking-, Wait-, TempDB-, I/O-, Query-Store-, XE- und Infrastrukturworkloads;
- Analyzer-Probes;
- Finding-, Status- und Resultset-Assertions;
- projektspezifischer Cleanup.

### 9.3 Grenzen

- `UpdateFramework` ist eine Deployment Unit und keine Provideraktion.
- Frameworkupdate darf Topologie und Ressourcenidentität nicht ändern.
- Analyzer-Evidenz und fachliche Assertions verbleiben im Analyze-Package.
- Netzwerk- und I/O-Faults werden durch registrierte Lab-Fault-Handler umgesetzt.

## 10. Integration `SQL_PerformanceSchulung`

### 10.1 Packages

Vorgesehene Package-Familien:

```text
SQL_PERFORMANCE_QUICK_ENVIRONMENT
SQL_PERFORMANCE_DEMO_CORE
SQL_PERFORMANCE_DEMO_INFRASTRUCTURE
```

### 10.2 Erhaltener Demo-Vertrag

Die Schulung behält:

- Demo-ID und Lernziel;
- Preflight der fachlichen Demo;
- Setup;
- Baseline;
- Demonstration;
- Observation;
- Mitigation;
- Comparison;
- Cleanup;
- Invarianten und Messrichtungen;
- Sicherheitsstufe Grün, Gelb und Rot.

### 10.3 Abbildung

| Schulungsinhalt | Lab-Package-Vertrag |
|---|---|
| Testinstanz | Environment Blueprint |
| Demo-Framework | Deployment Units |
| synthetische Daten | DataSet Definition |
| Baseline/Demonstration | Workflow Steps und Workload Definition |
| Observation | Probe Actions |
| Comparison | Assertions |
| Rot-/Gelb-Grenzen | Safety Class, Resource Profile und Fault Profile |
| Cleanup | Project Cleanup plus Lab Compensation |

## 11. Zukünftige Technologien

### 11.1 Hadoop oder andere Cluster

Ein neues Component-Type Pack registriert beispielsweise:

```text
hadoop.cluster
hadoop.namenode
hadoop.datanode
hadoop.hdfs.put
hadoop.job.submit
hadoop.job.wait
```

Der Project Adapter und das Package-Modell ändern sich nicht. Das Environment Blueprint referenziert den neuen Component Type und der Workflow die neuen Actions.

### 11.2 REST- und HTTP-Dienste

REST-Zugriff wird über:

- `http.service` oder `core.external-endpoint`;
- typisierte HTTP-Bindings;
- `http.request.execute`;
- Secret References;
- Network-/Egress-Policy;
- Response-Redaction und Assertions

modelliert.

### 11.3 Weitere Datenplattformen

Weitere Systeme werden über eigene namespaced Component- und Action-Type-Packs ergänzt. Der Core erhält keine neuen technologiespezifischen Pflichtfelder.

## 12. Externe Ressourcen

Ein Package kann externe Ressourcen nur mit explizitem Management Mode verwenden:

```text
ATTACHED
EXTERNAL_READ_ONLY
EXTERNAL_MUTABLE
```

Regeln:

- konkrete Endpunkte werden lokal gebunden;
- produktive Systeme sind kein zulässiger Standardtarget;
- `EXTERNAL_MUTABLE` benötigt eine ausdrückliche Freigabe;
- Cleanup- und Reversibility-Vertrag sind Pflicht;
- Egress und Secret-Zugriff werden im Plan sichtbar;
- externe Runtimewerte gelangen nicht automatisch in exportierbare Evidence.

## 13. Trust- und Ausführungsregeln

### 13.1 Trust Classes

```text
CORE_BUILTIN
OFFICIAL_EXTENSION
PROJECT_CONTENT
LOCAL_TRUSTED
UNTRUSTED
```

`UNTRUSTED` wird nicht ausgeführt.

### 13.2 Project Content

Project Content darf:

- innerhalb gebundener Components arbeiten;
- synthetische Daten erzeugen;
- registrierte Action Types verwenden;
- lokale Evidence produzieren.

Project Content darf nicht:

- Providerressourcen direkt löschen;
- fremde Komponenten adressieren;
- unbekannte Skripte außerhalb des Package-Scopes laden;
- Secrets persistieren;
- externe Endpunkte ohne Policy verwenden.

## 14. Safety-Class-Mapping

| Lab-Klasse | Bedeutung |
|---|---|
| `SAFE_READ_ONLY` | keine Mutation |
| `LAB_MUTATION` | synthetische Daten oder Projektobjekte werden verändert |
| `RESOURCE_PRESSURE` | kontrollierte CPU-, RAM-, I/O-, Log-, TempDB- oder Concurrency-Last |
| `INSTANCE_CHANGE` | Instanzkonfiguration, Cache, Dienst oder serverweiter Zustand wird verändert |
| `INFRASTRUCTURE_CHANGE` | VM, Netzwerk, Storage oder Providerzustand wird verändert |
| `DESTRUCTIVE_DISPOSABLE` | Datenverlust oder beschädigter Zustand ist beabsichtigt; wegwerfbarer Scope erforderlich |

Mapping der Schulungsstufen:

- Grün → `LAB_MUTATION` oder niedriger;
- Gelb → `RESOURCE_PRESSURE`;
- Rot → mindestens `INSTANCE_CHANGE`, häufig `INFRASTRUCTURE_CHANGE` oder `DESTRUCTIVE_DISPOSABLE`.

## 15. Status- und Fehlervertrag

Project-, Package- und Adaptercodes:

```text
ADAPTER_READY
ADAPTER_UNSUPPORTED_CONTRACT
PACKAGE_NOT_FOUND
PACKAGE_HASH_MISMATCH
PACKAGE_UNSUPPORTED_CONTRACT
PACKAGE_UNTRUSTED
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

Konsolentexte dürfen lokalisiert werden. Codes bleiben unverändert.

## 16. Control Plane

Der Project Adapter kann später über CLI, REST oder eine andere Control Plane verwendet werden. Entscheidend ist:

- Requests, Plans, Operations, Events und Results sind serialisierbar;
- Project Content hängt nicht von `Write-Host`-Text ab;
- länger laufende Abläufe besitzen Operation IDs;
- ein externer Controller kann Status und Events abfragen;
- Provider- und Package-Logik wird nicht in der REST-Schicht dupliziert.

## 17. Datenschutzgrenze

- Packages enthalten ausschließlich synthetische oder öffentliche freigegebene Inhalte.
- Reale lokale Runtimewerte dürfen für den lokalen Test verwendet werden, werden aber nicht automatisch versioniert oder exportiert.
- Secret-Werte sind auch in technischer Evidence unzulässig.
- Sanitized Summary und Local Technical Evidence sind getrennt.
- Das Lab verändert keine Projektdateien, um Runtimewerte einzutragen.
- Externe Responses, SQL-Texte, Pläne und Logs benötigen vor einem Export eine eigene Privacy-Prüfung.

## 18. Vertragsversionierung

Getrennt versioniert werden:

- Project Adapter;
- Lab Package;
- Environment Blueprint;
- Component Type;
- Action Type;
- DataSet;
- Workflow;
- Provider;
- Evidence;
- Control Plane.

Vor `1.0` sind Breaking Changes mit Migrationshinweis zulässig. `1.0` wird erst nach zwei produktiven SQL-Projektadaptern und mindestens einem technologieoffenen Proof festgeschrieben.

## 19. Abnahmekriterien

Der Integrationsvertrag ist umgesetzt, wenn:

1. ein Project Adapter Packages entdecken und versioniert binden kann;
2. Packages Umgebung, Installation, Testdaten, Workload, Observation, Assertion und Cleanup vollständig beschreiben;
3. Projekte keine Providerbefehle benötigen;
4. Testdaten als eigene, verifizierbare und resetbare Verträge geführt werden;
5. Inputs und Outputs typisiert über Runtime Bindings verbunden werden;
6. Composite Components expandierbar sind;
7. SQL Server, HTTP-Dienst und ein Composite-Cluster-Proof denselben Core-Vertrag verwenden;
8. `SQL_Server_Analyze` und `SQL_PerformanceSchulung` getrennte fachliche Packages, aber denselben Lab-Core nutzen;
9. externe Ressourcen nur über explizite Management- und Network-Policy eingebunden werden;
10. unbekannte oder untrusted Erweiterungen abgelehnt werden;
11. Cleanup und Compensation auch bei Project-Fehlern ausgeführt werden;
12. CLI und eine spätere REST Control Plane keine unterschiedlichen Projektverträge benötigen.
