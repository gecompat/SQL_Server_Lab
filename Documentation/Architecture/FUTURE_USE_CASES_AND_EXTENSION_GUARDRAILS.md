# Zukünftige Anwendungsfälle und Erweiterungsleitplanken

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_TEST_CATALOG` |
| Stand | 2026-07-26 |
| Zweck | Sicherstellen, dass frühe Schnittstellen spätere Anwendungsfälle nicht blockieren |

## 1. Einordnung

Dieses Dokument ist kein Versprechen, alle genannten Technologien kurzfristig zu implementieren. Die Anwendungsfälle dienen als Architekturtests: Die Core-Verträge müssen sie grundsätzlich ausdrücken können, ohne für jede neue Technologie neu entworfen zu werden.

SQL Server bleibt der erste produktive Schwerpunkt. Der Lab Core wird jedoch als allgemeine Umgebungs-, Komponenten-, Workflow-, Binding- und Lifecycle-Plattform modelliert.

## 2. Kategorien zukünftiger Anwendungsfälle

### 2.1 Weitere SQL-Server-Topologien

- mehrere unabhängige SQL-Server-Versionen;
- Availability Groups;
- WSFC und FCI;
- Log Shipping und Replication;
- Windows- und Linux-Kombinationen;
- Domain-, DNS- und Zertifikatsabhängigkeiten;
- getrennte Data-, Log-, TempDB- und Backup-Storage-Rollen;
- Router-, Witness-, Load-Generator- und Observer-Komponenten;
- Upgrade-, Migration- und Compatibility-Level-Szenarien.

**Schnittstellenfolge:** Eine SQL-Server-Instanz darf nicht die einzige zulässige Root-Komponente sein. Topologien müssen beliebige Komponentenbeziehungen und zusammengesetzte Rollen unterstützen.

### 2.2 Hadoop-, Spark- oder verteilte Datencluster

Mögliche spätere Komponenten:

- NameNode und DataNodes;
- ResourceManager und NodeManager;
- Spark Master und Worker;
- HDFS, YARN oder vergleichbare Dienste;
- SQL-Server-Datenquelle;
- Datenimport, Jobsubmission, Jobstatus und Ergebnisprüfung;
- skalierbare Workerzahl;
- Cluster-Health und Teilkomponentenausfall.

**Schnittstellenfolge:** Composite Components müssen eine fachliche Clusterdefinition in einen Ressourcenuntergraphen expandieren können. Workflow Actions und Bindings müssen technologiebezogen erweiterbar sein.

### 2.3 REST-, HTTP-, gRPC- oder andere Service-Schnittstellen

Mögliche spätere Szenarien:

- Test-API als Container oder VM bereitstellen;
- API gegen eine Lab-SQL-Instanz konfigurieren;
- synthetische Requests erzeugen;
- Authentifizierung über Secret Bindings;
- Responsefelder als Workflowoutputs weiterreichen;
- Retry-, Timeout-, Rate-Limit- und Fehlerverhalten testen;
- einen externen Testendpoint read-only einbinden;
- einen Mock- oder Stub-Service verwenden.

**Schnittstellenfolge:** Endpunkte und Protokolle werden als typisierte Interfaces und Bindings modelliert. Ein externer Endpoint ist eine Component mit Management- und Network Policy, kein freier URL-String im Szenario.

### 2.4 Clientanwendungen und Treiber

Mögliche Komponenten:

- ODBC-/JDBC-Client;
- .NET-, Java-, Python- oder PowerShell-Testclient;
- Connection-Pooling- und Retry-Szenarien;
- ORM-spezifische Query Patterns;
- mehrere Clientversionen;
- Lastgeneratoren und Sessionkoordinatoren;
- Netzwerk- und TLS-Konfiguration.

**Schnittstellenfolge:** Workload Driver werden als eigenständige Components modelliert. Die SQL-Instanz erzeugt ein Endpoint Binding; der Client konsumiert es. Ein Szenario darf nicht voraussetzen, dass alle Aktionen direkt auf dem Orchestratorhost laufen.

### 2.5 Datenpipelines und ETL

Mögliche Szenarien:

- SSIS-Pakete;
- Dateiquellen und Dateiziele;
- REST- oder Queue-basierte Datenzufuhr;
- SQL Server als Quelle oder Ziel;
- Hadoop-/Spark-Verarbeitung;
- Lookup-, Merge-, Fehlerpfad- und Wiederanlaufszenarien;
- synthetische Batch- und Streamingdaten;
- Pipelinebeobachtung und Resultatvalidierung.

**Schnittstellenfolge:** DataSets, Workloads und Artifacts müssen getrennt sein. Ein Workflow muss mehrere Systeme und Datenflüsse verbinden können.

### 2.6 Messaging und Streaming

Mögliche spätere Technologien:

- Kafka oder vergleichbare Broker;
- Service Broker;
- Event Hubs oder lokale Emulatoren;
- Producer, Consumer und Schema Registry;
- Backpressure, Retry, Duplicate und Ordering-Szenarien;
- kontrollierte Netzwerkunterbrechung.

**Schnittstellenfolge:** Link Types wie `publishes-to` und `consumes-from` müssen registrierbar sein. Der Core darf Beziehungen nicht auf SQL-Verbindungen reduzieren.

### 2.7 Object Storage und Dateisysteme

Mögliche Komponenten:

- lokaler File Server;
- S3-kompatibler Testdienst;
- Blob-Storage-Emulator;
- HDFS;
- SMB- oder NFS-Labfreigabe;
- Backup-, Export-, Import- und Archive-Szenarien.

**Schnittstellenfolge:** Storage wird als Component beziehungsweise Storage Claim mit Interfaces modelliert. Reale Hostpfade bleiben lokale Bindings.

### 2.8 Observability und Diagnose

Mögliche Komponenten:

- Metrikcollector;
- Logcollector;
- Tracecollector;
- SQL-DMVs, Query Store und Extended Events;
- Betriebssystemmetriken;
- Netzwerk- und Storage-Telemetrie;
- sanitisierte Summary-Renderer.

**Schnittstellenfolge:** Beobachtung ist nicht auf SQL-Procedures beschränkt. Probes und Evidence Renderer sind erweiterbare Typen. Rohdaten und exportierbare Zusammenfassung bleiben getrennt.

### 2.9 Security-, Identity- und Zertifikatsszenarien

Mögliche Komponenten:

- isolierter Domain Controller und DNS;
- Kerberos- oder Windows-Authentication-Test;
- lokale Zertifizierungsstelle;
- TLS-Endpunkte;
- Service Accounts;
- Secret Rotation innerhalb eines wegwerfbaren Scopes;
- Berechtigungs- und Negativtests.

**Schnittstellenfolge:** Identity-, Certificate- und Secret-Referenzen müssen typisiert und lokal bleiben. Ein Package enthält keine realen Accounts oder Schlüssel.

### 2.10 Weitere Provider

Mögliche spätere Provider:

- Kubernetes;
- andere lokale Hypervisoren;
- bare-metal-nahe Labhosts;
- Cloud-IaaS in einem getrennten, ausdrücklich freigegebenen Scope;
- Remote Hosts;
- vorhandene Testappliances.

**Schnittstellenfolge:** Provider sind Plugins hinter demselben Resource-Graph- und State-Vertrag. Project Packages enthalten keine providerspezifische Provisionierung.

### 2.11 Verteilte und hybride Ausführung

Mögliche Szenarien:

- Hyper-V-Windows-Komponenten auf Host A;
- native Linux-Container auf Host B;
- Client oder Observer auf Host C;
- kontrollierte Netzwerkverbindungen zwischen Teilhosts;
- zentraler Run mit getrennten lokalen Cleanup-Scopes;
- Teilverfügbarkeit und `NOT_EXECUTED` einzelner Rollen.

**Schnittstellenfolge:** Placement und Providerzuordnung sind Teil des Bound Plan. Jeder Host behält einen eigenen lokalen State und registrierte Ressourcen-IDs.

### 2.12 Lang lebende und gemeinsam genutzte Testbasen

Mögliche Betriebsformen:

- vollständig ephemerer Run;
- persistente Basistopologie mit resetbaren Projektdaten;
- geteiltes Image- oder Package-Cache;
- mehrere sequenzielle Szenarien auf derselben validierten Instanz;
- reservierte Labumgebung mit Lease;
- Snapshot- oder Child-Disk-basierter Reset.

**Schnittstellenfolge:** `PersistenceMode`, `LifecyclePolicy`, Ownership und Lease müssen getrennt von Szenarioinhalt modelliert werden. Ein Project Package darf eine bestehende Basis nicht still übernehmen.

### 2.13 Externe Orchestrierung und Remote Control

Mögliche Konsumenten:

- PowerShell CLI;
- REST API;
- Desktop- oder Web-UI;
- getrenntes Validation-Repository;
- Schulungssteuerung;
- Testkatalog oder Scheduler;
- Entwicklungswerkzeug.

**Schnittstellenfolge:** Commands, Plans, Operations, Events und Results sind serialisierbare Verträge. Konsolenausgabe ist keine Integrationsschnittstelle.

## 3. Erweiterungsleitplanken

### 3.1 Keine technologiespezifischen Core-Pflichtfelder

Der Core darf nicht voraussetzen:

- `SqlVersion`;
- `DatabaseName`;
- `ContainerImage`;
- `VmName`;
- `PowerShellScript`;
- `ConnectionString`.

Solche Felder gehören in Component-Type-, Action-Type- oder Package-spezifische Schemas.

### 3.2 Namespaces

Alle erweiterbaren Typen verwenden stabile Namespaces:

```text
core.*
mssql.*
hadoop.*
http.*
observability.*
fault.*
<future-namespace>.*
```

Ein Typ wird durch ID und Version aufgelöst.

### 3.3 Composite Expansion

Cluster, hochverfügbare Systeme und größere Services dürfen als Composite Component beschrieben werden. Expansion geschieht vor Providerplanung und ist versioniert.

### 3.4 Typisierte Interfaces

Komponenten veröffentlichen Interfaces, beispielsweise:

```text
endpoint.sql
endpoint.http-base
endpoint.hdfs
endpoint.ssh
endpoint.metrics
credential-ref.admin
artifact.local
```

Consumer deklarieren benötigte Interface Types. Konkrete Werte werden erst lokal gebunden.

### 3.5 Actions statt Interpreterannahme

Der Workflow referenziert Action Types. Ob ein Handler T-SQL, PowerShell, Shell, HTTP, Java oder ein anderes Werkzeug verwendet, ist Handlersemantik und kein Core-Feld.

### 3.6 External Resource Policy

Jede externe Resource besitzt:

- Management Mode;
- Network-/Egress-Policy;
- Trust- und Safety-Klasse;
- Secret Requirements;
- Cleanup- beziehungsweise Nicht-Cleanup-Grenze;
- Exportpolicy.

Ein freier externer Endpoint ohne diese Angaben wird abgelehnt.

### 3.7 Keine stille Fallback-Simulation

Fehlt eine Capability, ist nur zulässig:

- `NOT_EXECUTED`;
- `UNSUPPORTED`;
- ausdrücklich definierte `EMULATED`-Alternative;
- `FIXTURE` mit klarer Aussagegrenze.

Ein Providerwechsel darf keine fachlich andere Topologie vortäuschen.

### 3.8 Trust Classes

Neue Handler und Provider benötigen eine Trust Class, Version, Hash und lokale Freigabe. Projektinhalte dürfen bekannte Handler nutzen, aber nicht still neue privilegierte Handler einschleusen.

### 3.9 Core und Control Plane trennen

Ein neuer REST- oder UI-Adapter darf nur Commands und Events des Core verwenden. Er implementiert weder Providerplanung noch Packageausführung erneut.

### 3.10 State und Evidence trennen

Runtime State darf lokale Endpunkte und IDs enthalten. Exportierbare Evidence darf diese Informationen nur nach expliziter Sanitization übernehmen.

## 4. Architekturtests vor `1.0`

### Test A – SQL Quick Environment

Nachweis:

- eine `mssql.instance`-Component;
- Docker- oder Podman-Provider;
- Runtime Bindings;
- Start, Status, Stop und Destroy.

### Test B – SQL Performance Demo

Nachweis:

- eigene DataSet Definition;
- mehrere Deployment Units;
- Workflow DAG;
- Multi-Session-Workload;
- Observation und Vergleichsassertion;
- Cleanup.

### Test C – SQL Analyze Szenario

Nachweis:

- Frameworkinstallation als Package Content;
- synthetische Konstellation;
- Analyzer-Probe;
- Finding- und Statusassertion;
- providerunabhängiger Fault Controller.

### Test D – HTTP-Service

Nachweis:

- `http.service` oder Mock-Service;
- `endpoint.http-base` Binding;
- `http.request.execute`;
- Responseassertion;
- Secret-Redaction;
- keine Änderung des Core-Schemas.

### Test E – Composite Cluster

Mindestens als Contract Fixture:

- `example.cluster` oder `hadoop.cluster`;
- Expansion in Master und Worker;
- Scale-Constraint;
- mehrere exportierte Endpoints;
- keine SQL-spezifischen Pflichtfelder.

### Test F – Zweite Control Plane

Mindestens als Contract Test:

- derselbe `CreatePlan`-Command wird von CLI und einem simulierten REST-Adapter serialisiert;
- Result und Events sind identisch strukturiert;
- keine Auswertung von Konsolentext.

## 5. Entscheidungen, die bewusst vertagt werden

Vor dem jeweiligen Proof werden nicht festgeschrieben:

- konkrete Hadoop-Distribution;
- Kubernetes als Provider;
- Cloudprovider;
- Authentifizierungsmodell einer REST Control Plane;
- Plugin-Signaturverfahren;
- universelle Ausdruckssprache für komplexe Bedingungen;
- Remote-Agent-Protokoll;
- persistenter zentraler Scheduler.

Die Core-Verträge müssen diese Entscheidungen ermöglichen, ohne sie heute vorzutäuschen.

## 6. Abnahmekriterium für Zukunftsoffenheit

Eine neue Technologie gilt als architektonisch integrierbar, wenn sie durch folgende Ergänzungen modelliert werden kann:

1. Component-Type Pack;
2. gegebenenfalls Composite Expander;
3. Action-Type Pack;
4. Package-Inhalte und Workflow;
5. erforderliche Capabilities;
6. optionaler Provider oder vorhandenes Provider-Mapping.

Eine Änderung der grundlegenden Run-, State-, Binding-, Event- oder Cleanup-Verträge darf dafür nicht erforderlich sein. Ist sie dennoch notwendig, muss begründet werden, ob ein bisher fehlendes allgemeines Konzept entdeckt wurde oder die Erweiterung unzulässig technologiespezifisch in den Core drängt.
