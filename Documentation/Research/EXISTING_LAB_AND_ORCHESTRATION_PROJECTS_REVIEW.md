# Analyse bestehender Lab-, Orchestrierungs- und Package-Modelle

| Merkmal | Wert |
|---|---|
| Status | `RESEARCH_BASELINE` |
| Stand | 2026-07-26 |
| Zweck | Bewährte Muster übernehmen, Fehlentscheidungen vermeiden und unnötige Eigenentwicklung begrenzen |
| Verbindliche Zielplattformen | Hyper-V, Docker und Podman |
| Ergebnis | eigener technologieoffener Lab Core; bestehende Projekte als Architekturquellen und optionale Backends |

## 1. Fragestellung

Die Recherche beantwortet nicht nur, welches Tool virtuelle Maschinen oder Container startet. Entscheidend ist, ob eine Lösung folgende Ebenen gemeinsam oder sauber getrennt abbildet:

1. deklarative gewünschte Umgebung;
2. Providerabstraktion;
3. logische Rollen oder Components;
4. Installation und Konfiguration innerhalb der Components;
5. synthetische Testdaten;
6. Workload- und Fehlerszenarien;
7. Observation und Assertions;
8. typisierte Inputs, Outputs und Secrets;
9. State, tatsächliche Ressourcen-IDs und Recovery;
10. Cleanup und sichere Scope-Grenzen;
11. Erweiterbarkeit für weitere Technologien;
12. lokale CLI und spätere REST-/UI-Control-Plane.

Keine untersuchte Lösung erfüllt den gesamten Zielvertrag von `SQL_Server_Lab` einschließlich Hyper-V, Docker, Podman, Testdaten, fachlichem Workflow, Privacy-Grenzen und projektübergreifenden Packages. Die sinnvolle Lösung ist daher kein unveränderter Fork eines bestehenden Projekts.

## 2. Bewertungsmaßstab

| Kriterium | Bedeutung |
|---|---|
| `Topology` | logische Beschreibung mehrerer Components und Beziehungen |
| `Provider` | austauschbare technische Bereitstellung |
| `Content` | Installation und Konfiguration innerhalb bereitgestellter Ressourcen |
| `Workflow` | mehrstufige Abläufe, Abhängigkeiten, Parallelität und Fehlerpfade |
| `Data` | eigener Vertrag für synthetische Testdaten |
| `Verify` | Health, Probe, Assertion und fachliche Abnahme |
| `State` | persistierter tatsächlicher Istzustand und Ressourcenidentität |
| `Cleanup` | explizite Rücknahme und sichere Löschgrenze |
| `Extension` | neue Typen, Actions, Provider oder Packages ohne Core-Fork |
| `Target fit` | Eignung für Hyper-V, Docker und Podman zusammen |

Bewertungswerte:

- `STARK`: direkt als Architekturvorbild geeignet;
- `TEILWEISE`: nützliches Teilmuster;
- `NICHT_ZIEL`: für diese Anforderung nicht ausreichend;
- `OPTIONALES_BACKEND`: möglicher ausführender Adapter hinter dem Lab Core;
- `REFERENZ_NUR`: keine geplante Runtimeabhängigkeit.

## 3. Ergebnisübersicht

| Projekt oder Standard | Hauptstärke | Hauptgrenze für dieses Projekt | Entscheidung |
|---|---|---|---|
| AutomatedLab | deklarative Labs, Maschinenrollen, Hyper-V, Custom Roles | kein gemeinsamer Docker-/Podman-Core; VM- und PowerShell-zentriert | Hyper-V-Pilotbackend prüfen; Rollenmodell adaptieren |
| Microsoft MSLab | Parent Images, Differencing Disks, schnelle reproduzierbare Hyper-V-Labs | Hyper-V-spezifisch; Konfiguration und Secrets nicht als Zielvertrag übernehmbar | Image-/Hydration-Muster adaptieren |
| Lability | deklarative Hyper-V-Labs mit PowerShell DSC | Hyper-V-/Windows-spezifisch | Hyper-V-Desired-State-Referenz |
| Vagrant | Provider-/Provisioner-Trennung, Lifecycle und Pluginmodell | Podman nicht gleichwertig; Hyper-V-Netzwerkgrenzen; Lizenzprüfung notwendig | Referenz, keine Core-Abhängigkeit |
| Packer | Image Builder, Provisioner, Plugins und reproduzierbare Images | kein vollständiger Lab-Lifecycle | optionaler Image-Build-Handler |
| Compose Specification | Services, Networks, Volumes, Configs, Secrets, Health und Dependencies | nur Container; Engineunterschiede bleiben | Basis des Container-Resource-Mappings |
| Podman Compose | Compose-Zugriff auf Podman | verwendet externen Compose Provider; Kompatibilität nicht automatisch identisch | eigener Podman-Provider mit Capability-Matrix |
| Testcontainers | dynamische Endpunkte, Readiness und testgebundener Cleanup | container- und programmiersprachenzentriert; kein Hyper-V | Binding-/Readiness-Muster adaptieren |
| Ansible Molecule | Scenario-Lifecycle, Side Effects, Verify und Cleanup | Ansible-zentriert; Infrastrukturprovider getrennt erforderlich | Workflow-Phasen adaptieren; optionaler Action Handler |
| Test Kitchen | Driver, Transport, Provisioner, Verifier, State | Ruby-/Chef-Ökosystem; kein allgemeines Topologiemodell | Schichtentrennung adaptieren |
| Terraform | Provider, Plan, Resource Graph und State | CRUD-Ressourcenmodell reicht für Tests und Faults nicht aus | Plan-/State-/Provider-Muster adaptieren |
| Pulumi | Component Resources, Outputs und Automation API | schwergewichtige Runtimeabhängigkeit; kein fertiger Labfachvertrag | Composite-/Output-/Control-Plane-Muster adaptieren |
| Kubernetes Operator Pattern | `spec`/`status`, Controller und erweiterbare Resource Types | Kubernetes-spezifische Runtime; Reconciliation passt nicht zu jedem Teststep | Desired-/Actual-State- und Type-Registry-Muster adaptieren |
| TOSCA 2.0 | Node-, Relationship-, Capability-, Interface-, Artifact- und Policy-Typen | vollständiger Standard wäre für den Einstieg zu umfangreich | bewusstes TOSCA-inspiriertes Subset |
| CNAB | versionierte Bundles, Actions, Parameters, Credentials und Outputs | Invocation-Image-/Cloud-Native-Fokus | Lab-Package-Metadaten adaptieren |
| Porter | Manifest, Mixins, Dependencies, Actions, State und Wiring | Bundleausführung ist containerorientiert und teilweise linear | Package-/Mixin-/Binding-Muster adaptieren |
| Apache Ambari Blueprints | Cluster-Blueprints mit Host Groups, Components und Konfiguration | Hadoop-spezifisch; kein allgemeiner Provider-Core | Composite-Cluster-Expansion adaptieren |
| Apache Bigtop | Packaging, Deployment und Tests für Big-Data-Komponenten | domänenspezifisch | spätere Hadoop-Extension-Referenz |
| Argo Workflows | DAG, Inputs/Outputs, Retries, Conditions und Exit Handler | Kubernetes-only | Workflow-DAG-Semantik adaptieren |
| Dagger | dynamische Serviceabhängigkeiten, Bindings und Content Addressing | container-only und programmatisch | Service-/Output-Muster adaptieren |
| NixOS Tests | deklarative Multi-Node-Umgebungen plus Test Driver | Nix-/Linux-spezifisch | kombinierte Topology-/Driver-Referenz |
| Toxiproxy | API-gesteuerte reversible Netzwerkfaults | TCP-Proxy, keine allgemeine Infrastruktursteuerung | offizieller optionaler Fault Handler prüfen |
| Chaos Mesh | typisierte Fault-Ressourcen und Fault Workflows | Kubernetes-only | Fault-Lifecycle-Muster adaptieren |
| Dev Container Specification | Features, Templates und Compose-Erweiterung | Entwicklungscontainer, kein Lab-Lifecycle | Registry-/Feature-Komposition adaptieren |

## 4. AutomatedLab

**Quellen:**

- [AutomatedLab Repository](https://github.com/AutomatedLab/AutomatedLab)
- [AutomatedLab Documentation](https://automatedlab.org/)
- [Roles](https://automatedlab.org/en/stable/Wiki/Roles/roles/)
- [Custom Roles](https://automatedlab.org/en/stable/Wiki/Advanced/customroles/)

### 4.1 Relevante Muster

AutomatedLab trennt die Definition eines Labs von dessen Installation. Ein Lab besitzt Maschinen, Netzwerke, Betriebssysteme und Rollen. Rollen können Properties besitzen, und Custom Roles ergänzen Host- und Guest-Aktivitäten, ohne den gesamten Core zu forken.

Für `SQL_Server_Lab` sind besonders wertvoll:

- Lab Definition vor Bereitstellung;
- Maschine als definierte Ressource, nicht sofortige Mutation;
- eine oder mehrere Rollen pro Maschine;
- rollenbezogene Properties und Validierung;
- Pre- und Post-Installation Activities;
- Remoting- und Credentialabstraktion;
- snapshots und vollständige Labentfernung;
- Wiederverwendung der VM-/OS-/Domain-Basis durch fachlich getrennte Projekte.

### 4.2 Grenzen

- Der dokumentierte Kern ist auf Hyper-V und Azure ausgerichtet.
- Docker und Podman sind keine gleichwertigen Provider derselben Labdefinition.
- Das Rollenmodell ist stark VM-, Produkt- und PowerShell-orientiert.
- Custom Roles können breit privilegierten Scriptcode auf Host und Guests ausführen; unser Trust-, Action-Type- und Side-Effect-Vertrag muss enger sein.
- Der bestehende Credential- und Exportvertrag entspricht nicht automatisch den strengeren Repository-Privacy-Regeln dieses Projekts.

### 4.3 Entscheidung

AutomatedLab wird nicht zum Gesamt-Core von `SQL_Server_Lab`.

Es wird jedoch in einem frühen Spike als **optionales Hyper-V-Fulfilment-Backend** geprüft. Der eigene Lab Core würde Environment Blueprint, Bound Plan, State, Package und Workflow behalten. Ein AutomatedLab-Adapter dürfte ausschließlich den expandierten Hyper-V-Resource-Graph erfüllen und tatsächliche VM-/Netzwerk-/Disk-IDs zurückgeben.

Dadurch können vorhandene Hyper-V-Fähigkeiten genutzt werden, ohne Docker und Podman in ein VM-zentriertes Modell zu pressen.

## 5. Microsoft MSLab

**Quelle:** [microsoft/MSLab](https://github.com/microsoft/MSLab)

Der vom Benutzer genannte Pfad `MSDLA/hyper-v-lab-environment` war am 26. Juli 2026 über GitHub nicht auflösbar. Er könnte umbenannt, privat oder fehlerhaft geschrieben sein. `microsoft/MSLab` wurde als fachlich naheliegende öffentliche Referenz separat untersucht; eine Identität beider Projekte wird nicht behauptet.

### 5.1 Relevante Muster

MSLab trennt eine langsamere **Hydration Phase** von einer schnellen Deployment-Phase. Aus lokalen Medien werden wiederverwendbare Parent Disks vorbereitet; konkrete Lab-VMs verwenden Differencing Disks. Eine einfache `LabConfig.ps1` beschreibt Maschinen, virtuelle Disks und Netzwerke.

Übernehmenswerte Muster:

- Base-/Parent-Image-Lifecycle getrennt vom normalen Run;
- immutable Parent Images;
- Differencing Disks für schnelle Bereitstellung und Reset;
- vorbereitete Infrastruktur für Schulungsverteilung;
- kleine, sharebare Topologiedefinition;
- klare Trennung von Hydration, Deploy und Cleanup.

### 5.2 Nicht zu übernehmen

- Hyper-V als einzige Runtime;
- Secrets direkt in einer versionierbaren PowerShell-Konfiguration;
- feste reale oder realistisch wirkende Netzwerkwerte als allgemeiner Contract;
- implizite globale Defaults ohne Capability- und Privacy-Grenze;
- Vermischung von Hostbinding und sharebarer Topologiedefinition.

### 5.3 Entscheidung

Das Parent-/Child-Disk-Modell wird Bestandteil der Hyper-V-Strategie. Die konkrete MSLab-Implementierung wird nicht zum Lab Core. Packer, AutomatedLab, MSLab-ähnliche Hydration oder eine eigene Image Pipeline können später austauschbare Image Builder sein.

## 6. Lability

**Quellen:**

- [VirtualEngine/Lability](https://github.com/VirtualEngine/Lability)
- [Lability Documentation](https://lability.readthedocs.io/)

Lability verwendet PowerShell DSC Configuration Documents zur deklarativen Definition und Bereitstellung lokaler Hyper-V-Labs.

Übernehmenswert:

- gewünschter Zustand als sharebare Definition;
- Medien- und Imagekonfiguration getrennt von der Maschineninstanz;
- idempotenzorientierte Provisionierung;
- Hyper-V-Ressourcen aus einer deklarativen Beschreibung.

Grenze:

- Windows-/Hyper-V-/DSC-spezifisch;
- keine gemeinsame Containerproviderabstraktion;
- kein vollständiger Testdaten-, Workflow- und Assertion-Vertrag.

**Entscheidung:** Referenz für Hyper-V Desired State, kein Gesamtbackend ohne Spike.

## 7. Vagrant

**Quellen:**

- [Vagrant Repository](https://github.com/hashicorp/vagrant)
- [Providers](https://developer.hashicorp.com/vagrant/docs/providers)
- [Provisioning](https://developer.hashicorp.com/vagrant/docs/provisioning)
- [Docker Provider](https://developer.hashicorp.com/vagrant/docs/providers/docker)
- [Hyper-V Provider](https://developer.hashicorp.com/vagrant/docs/providers/hyperv)

### 7.1 Relevante Muster

- Provider und Provisioner sind getrennt.
- Eine logische Maschine kann durch verschiedene Provider erfüllt werden.
- Provider Plugins ergänzen neue Infrastrukturen.
- Provisioner konfigurieren die bereitgestellte Maschine.
- Lifecyclekommandos und Box-/Image-Bezug sind standardisiert.

### 7.2 Grenzen

- Ein Providerwechsel garantiert keine semantisch identische Umgebung.
- Der Hyper-V-Provider kann Netzwerkdetails nicht in gleicher Weise kontrollieren wie andere Provider und ist auf vorhandene virtuelle Switches angewiesen.
- Docker ist ein offizieller Provider, Podman jedoch kein gleichwertiger offizieller Kernpfad.
- Das Vagrantfile ist eine Ruby-DSL und kein neutraler serialisierbarer API-Vertrag.
- Neuere Vagrant-Versionen unterliegen einer Business-Source-Lizenz; Einbettung oder verpflichtende Runtimeabhängigkeit benötigt eine gesonderte Lizenzprüfung.

### 7.3 Entscheidung

Provider-/Provisioner-Trennung übernehmen. Vagrant nicht als Core-Abhängigkeit einführen. Ein späterer optionaler Vagrant-Provideradapter ist nur sinnvoll, wenn er einen konkret fehlenden Hypervisor oder vorhandene Nutzerinvestitionen erschließt.

## 8. Packer

**Quellen:**

- [Packer Repository](https://github.com/hashicorp/packer)
- [Packer Documentation](https://developer.hashicorp.com/packer/docs)

Packer trennt Builder, Provisioner, Post-Processor und Data Sources. Erweiterungen werden über Plugins bereitgestellt.

Übernehmenswert:

- Imagebau als eigener Lifecycle;
- Builder und Provisioner getrennt;
- manifestierte Artefaktoutputs und Prüfsummen;
- wiederverwendbare Baselines;
- Provider-/Builder-spezifische Umsetzung hinter einem gemeinsamen Authoring-Modell.

Grenze:

- Packer verwaltet Images, nicht vollständige laufende Labs, Szenarien oder Cleanup.

**Entscheidung:** optionaler `image.build`-Action Handler beziehungsweise Hyper-V-Image-Backend; keine Core-Abhängigkeit.

## 9. Compose, Docker und Podman

**Quellen:**

- [Compose Specification](https://github.com/compose-spec/compose-spec)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Podman Compose Documentation](https://docs.podman.io/en/latest/markdown/podman-compose.1.html)
- [Podman Documentation](https://docs.podman.io/en/latest/)

### 9.1 Relevante Muster

Compose bietet ein etabliertes Modell für:

- Services;
- Networks;
- Volumes;
- Configs und Secrets;
- Dependencies;
- Healthchecks;
- Ports und Ressourcenlimits;
- Profile und Overrides.

### 9.2 Wichtige Podman-Grenze

`podman compose` ist ein Wrapper um einen externen Compose Provider wie `docker-compose` oder `podman-compose`. Deshalb ist eine erfolgreiche Docker-Compose-Ausführung kein automatischer Podman-Nachweis. Unterstützte Felder, Netzwerke, Healthchecks, Limits und Volume-Semantik müssen provider- und versionsbezogen geprüft werden.

### 9.3 Entscheidung

- Ein gemeinsames logisches Container-Resource-Modell wird auf Compose-artige Services, Networks und Volumes abgebildet.
- Docker und Podman bleiben **getrennte Provider** mit eigenem Capability-Vektor.
- Der Lab Core erzeugt nicht zwingend eine einzige identische Compose-Datei für beide Engines; er darf einen gemeinsamen Core plus validierte Overrides oder direkte Provideraktionen erzeugen.
- Providererfolg wird über tatsächliche IDs, Health und SQL-/Service-Readiness geprüft.

## 10. Testcontainers

**Quellen:**

- [Testcontainers](https://testcontainers.com/)
- [Supported Container Runtimes](https://java.testcontainers.org/supported_docker_environment/)

Relevante Muster:

- testgebundene kurzlebige Services;
- dynamische Ports und Endpoints;
- Wait Strategies statt bloßem Prozessstatus;
- modulare Technologieunterstützung;
- automatische Bereinigung;
- Runtime Discovery.

Grenzen:

- Container- und programmiersprachenzentriert;
- keine Hyper-V-VM- oder gemischte Topologie;
- alternative Docker-kompatible Runtimes sind nicht automatisch vollständig gleichwertig.

**Entscheidung:** Readiness-, dynamisches Binding- und testgebundenes Cleanup-Muster übernehmen. Kein allgemeiner Lab-Core.

## 11. Ansible Molecule

**Quellen:**

- [Molecule Repository](https://github.com/ansible/molecule)
- [Molecule Documentation](https://ansible.readthedocs.io/projects/molecule/)

Molecule organisiert Tests als Scenarios mit Phasen wie Dependency, Cleanup, Destroy, Create, Prepare, Converge, Idempotence, Side Effect und Verify.

Übernehmenswert:

- Scenario als eigenständige Einheit;
- Provisionierung und Verifikation getrennt;
- Side Effect als kontrollierte Testphase;
- Cleanup vor und nach einem Lauf;
- mehrfach ausführbare Verify-/Side-Effect-Sequenzen;
- gemeinsam verwendbarer Scenario State.

Grenze:

- Ansible ist Ausführungs- und Konfigurationsbasis;
- Infrastrukturprovider und fachlicher Packagevertrag werden nicht für unseren Gesamtfall gelöst.

**Entscheidung:** Workflow-Phasen und Trennung von Converge, Side Effect und Verify adaptieren. Ansible kann später ein registrierter Action Handler sein.

## 12. Test Kitchen

**Quellen:**

- [Test Kitchen Repository](https://github.com/test-kitchen/test-kitchen)
- [Test Kitchen Documentation](https://kitchen.ci/)

Test Kitchen trennt:

- Driver: Ressourcen erstellen und entfernen;
- Transport: Verbindung, Dateiübertragung und Befehle;
- Provisioner: Ziel konfigurieren;
- Verifier: Ergebnis prüfen;
- State: Verbindungsdetails und Ressourceninformationen.

Diese Schichtentrennung ist direkt relevant. Besonders wichtig ist, dass Driver tatsächliche Verbindungsdaten in den State schreiben und nachgelagerte Schichten diese konsumieren.

**Entscheidung:** als Referenz für Provider, Execution Transport, Content und Verification. Keine Ruby-/Chef-Abhängigkeit.

## 13. Terraform und Pulumi

**Quellen:**

- [Terraform Plugin Development](https://developer.hashicorp.com/terraform/plugin)
- [Terraform Providers](https://developer.hashicorp.com/terraform/language/providers)
- [Pulumi Component Resources](https://www.pulumi.com/docs/iac/concepts/resources/components/)
- [Pulumi Automation API](https://www.pulumi.com/docs/iac/automation-api/)

### 13.1 Übernehmenswerte Muster

- Provider als versionierte Plugins;
- Resource Graph;
- read-only Plan beziehungsweise Preview;
- State mit tatsächlichen Ressourcenidentitäten;
- Data Sources für read-only Informationen;
- Outputs zwischen Ressourcen;
- Component Resources als zusammengesetzte Einheiten;
- Automation API als Grundlage einer Control Plane.

### 13.2 Grenzen

- CRUD-orientierte Ressourcenmodelle bilden Workload, Test, Fault, Observation und Assertion nicht vollständig ab.
- Ein vollständiger Terraform-/Pulumi-Unterbau wäre für lokale Quick Labs schwergewichtig.
- Secrets, State Backends und Plugin-Lifecycle würden zusätzliche Betriebsverantwortung erzeugen.

### 13.3 Entscheidung

Plan, State, Provider, Composite Resource und Output-Wiring adaptieren. Terraform oder Pulumi können später optionale Provider-/Action-Backends sein, nicht die Lab-Kernsemantik.

## 14. Kubernetes Custom Resources und Operator Pattern

**Quellen:**

- [Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
- [Operator Pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)

Übernehmenswert:

- klare Trennung von gewünschter `spec` und beobachtetem `status`;
- registrierbare neue Ressourcentypen;
- Controller für typspezifische Umsetzung;
- Conditions statt unstrukturierter Statusmeldungen;
- Owner References und Garbage Collection als Denkmuster.

Grenze:

- Kubernetes darf nicht Voraussetzung für Hyper-V- oder Desktop-Labs werden.
- Dauerhafte Reconciliation ist nicht für jeden einmaligen Teststep geeignet.

**Entscheidung:** Desired State, Actual State, Conditions und Type Registry adaptieren. Kein Kubernetes-Core.

## 15. TOSCA 2.0

**Quelle:** [OASIS TOSCA Version 2.0](https://docs.oasis-open.org/tosca/TOSCA/v2.0/)

TOSCA modelliert unter anderem:

- Node Types;
- Relationship Types;
- Capability Types;
- Interface Types und Operations;
- Artifact Types;
- Policy Types;
- Groups;
- Properties, Attributes, Requirements und Outputs.

Das entspricht weitgehend den langfristigen Anforderungen an Environment Blueprint, Components, Relations, Capabilities, Interfaces, Artifacts und Policies.

### Entscheidung

Der Lab Core wird **TOSCA-inspiriert**, aber nicht sofort TOSCA-kompatibel.

Zu übernehmen:

- typisierte Nodes/Components;
- typisierte Beziehungen;
- Requirements und Capabilities;
- Interfaces und Operations;
- Artifacts;
- Policies;
- Namespaces und Imports.

Vorläufig nicht übernehmen:

- die vollständige TOSCA-Syntax und alle Profile;
- einen allgemeinen TOSCA-Orchestrator;
- semantische Features ohne konkreten Lab-Anwendungsfall.

Jede bewusste Abweichung wird dokumentiert, damit eine spätere Mapping-Schicht möglich bleibt.

## 16. CNAB und Porter

**Quellen:**

- [CNAB](https://cnab.io/)
- [Porter](https://porter.sh/)
- [Porter Manifest](https://porter.sh/docs/bundle/manifest/)

Relevante Konzepte:

- versioniertes Bundle;
- Actions;
- Parameters;
- Credentials;
- Outputs;
- Dependencies;
- State;
- sensitive Werte;
- Mixins als Adapter zu vorhandenen Tools;
- Wiring von Outputs in spätere Inputs oder Dependencies;
- erklärbare Bundle-Schnittstelle.

Grenzen:

- CNAB und Porter sind auf cloud-native Application Bundles und eine containerisierte Bundleausführung ausgerichtet.
- Porter-Actions bestehen im Wesentlichen aus geordneten Schritten; unser Scenario-Vertrag benötigt einen DAG, Faults, Assertions und providerübergreifende Ressourcen.

### Entscheidung

Das Lab-Package-Modell übernimmt:

- Package-Metadaten und Versionierung;
- getrennte Parameters, Credentials, Outputs und State;
- Dependencies;
- sensitive Kennzeichnung;
- Action-/Mixin-Idee;
- erklärbare Package-Schnittstelle.

Der Lab Core benötigt kein Invocation Image. Hyper-V- und Hostactions bleiben zulässig, sofern der Action Handler registriert und vertrauenswürdig ist.

## 17. Apache Ambari und Bigtop

**Quellen:**

- [Apache Ambari](https://github.com/apache/ambari)
- [Ambari Blueprints](https://ambari.apache.org/)
- [Apache Bigtop](https://github.com/apache/bigtop)

Ambari Blueprints modellieren Host Groups, Components und Konfigurationen, die später konkreten Hosts zugewiesen werden. Das ist ein wichtiges Muster für künftige Composite Components wie `hadoop.cluster`.

Bigtop bietet eine Referenz für Packaging, Deployment und Tests verschiedener Big-Data-Komponenten.

### Entscheidung

- Composite Component enthält logische Rollen und Scale.
- Ein Type Expander erzeugt daraus Nodes, Links, Storage Claims, Probes und Bindings.
- Host- oder Providerzuordnung erfolgt erst nach Expansion.
- Hadoop-spezifische Semantik gehört in ein Extension Pack, nicht in den Core.

## 18. Argo Workflows, Dagger und NixOS Tests

### 18.1 Argo Workflows

**Quelle:** [Argo Workflows](https://argo-workflows.readthedocs.io/)

Nützliche Muster:

- DAG oder Steps;
- typisierte Inputs und Outputs;
- Conditions;
- Retries und Timeouts;
- Artifacts;
- Exit Handler;
- API- und Eventzugriff.

Grenze: Kubernetes-only.

### 18.2 Dagger

**Quelle:** [Dagger Services](https://docs.dagger.io/features/services/)

Nützliche Muster:

- Services werden bei Bedarf gestartet;
- abhängige Schritte erhalten dynamische Servicebindings;
- Lifecycle ist an tatsächliche Nutzung gekoppelt;
- wiederverwendbare Module.

Grenze: container- und SDK-zentriert.

### 18.3 NixOS Tests

**Quelle:** [NixOS Tests](https://nixos.org/manual/nixos/stable/index.html#sec-nixos-tests)

Nützliche Muster:

- deklarative Multi-Machine-Definition;
- separater Test Driver;
- Start und Steuerung mehrerer Nodes;
- Assertions und Faultsimulation;
- reproduzierbare Systembasis.

Grenze: Nix-/Linux-spezifisch.

### Entscheidung

Workflow-DAG, Exit/Cleanup Handler, dynamische Servicebindings und separater Test Driver werden adaptiert. Keine dieser Laufzeiten wird Core-Voraussetzung.

## 19. Toxiproxy und Chaos Mesh

**Quellen:**

- [Shopify Toxiproxy](https://github.com/Shopify/toxiproxy)
- [Chaos Mesh](https://chaos-mesh.org/)

Toxiproxy stellt TCP-Proxies mit API-gesteuerten, gerichteten Toxics bereit, beispielsweise Latenz, Bandbreitenbegrenzung oder Timeout. Chaos Mesh modelliert Faults als eigene Ressourcen und unterstützt kombinierte Fault Workflows.

Übernehmenswert:

- Fault ist eine eigene typisierte Resource beziehungsweise Action;
- Aktivierung, Status, Dauer und Rücknahme sind explizit;
- Richtung und Zielinterface werden benannt;
- Reset ist separat prüfbar;
- mehrere Faults können kontrolliert kombiniert werden.

### Entscheidung

- Toxiproxy wird als möglicher offizieller, providerübergreifender Netzwerk-Fault-Handler geprüft.
- Native `tc/netem`-, cgroup-, Hyper-V- oder Storage-Faults bleiben providerbezogene Handler.
- Chaos Mesh ist keine Runtimeabhängigkeit, liefert aber das Fault-Workflow-Muster.

## 20. Dev Container Specification

**Quelle:** [Development Containers Specification](https://containers.dev/)

Nützliche Muster:

- Features als composable, versionierte Ergänzungen;
- Templates;
- OCI-basierte Distribution;
- bestehende Dockerfile-/Compose-Konfiguration wird erweitert statt ersetzt;
- metadata-getriebene Tooling-Integration.

Grenze: Development Environments, keine vollständigen Labtopologien oder Testworkflows.

**Entscheidung:** Registry-, Feature- und Template-Muster für Packages und Extension Packs adaptieren.

## 21. Empfohlene Zielarchitektur aus der Recherche

### 21.1 Eigener Lab Core

Der Lab Core besitzt:

- Run Request;
- Lab Package;
- Environment Blueprint;
- Component- und Relationship Types;
- Action Types;
- Runtime Bindings;
- Workflow DAG;
- Bound Plan;
- Run State;
- Events;
- Cleanup-/Compensation-Stack;
- Privacy-, Trust- und Safety-Policy.

### 21.2 Provider

Verbindliche erste Provider:

```text
provider.docker
provider.podman
provider.hyperv
```

Provider dürfen intern vorhandene Tools nutzen, müssen aber denselben Resource-, State- und Cleanup-Vertrag erfüllen.

### 21.3 Hyper-V-Fulfilment-Strategien

In einem Spike werden drei Wege verglichen:

1. **AutomatedLab Backend:** vorhandene Maschinen-, Netzwerk-, Rollen- und Remoting-Fähigkeiten nutzen;
2. **Native Hyper-V Backend:** direkte PowerShell-/CIM-Steuerung mit vollständiger eigener State-Grenze;
3. **Lability-/MSLab-/Packer-inspirierte Image- und DSC-Komponenten:** Imagevorbereitung und Guest Desired State getrennt einsetzen.

Die Strategien können koexistieren. Das Package wählt keine davon direkt; der Planner wählt anhand Capability, Policy und Benutzerpräferenz.

### 21.4 Containerstrategie

- gemeinsames logisches Container-Resource-Modell;
- Compose-orientierte Abbildung;
- getrennte Docker- und Podman-Provider;
- eigene Capability- und Kompatibilitätsmatrix;
- dynamische Bindings;
- Readiness-Probes;
- tatsächliche IDs und scope-gebundener Cleanup.

### 21.5 Package- und Workflowstrategie

- Package-Metadaten nach CNAB-/Porter-Mustern;
- Environment nach TOSCA-/Ambari-Mustern;
- Provider und State nach Terraform-/Test-Kitchen-Mustern;
- Workflow nach Molecule-/Argo-Mustern;
- dynamische Bindings nach Testcontainers-/Pulumi-/Porter-Mustern;
- Faults nach Toxiproxy-/Chaos-Mesh-Mustern;
- Control Plane nach Automation-API-/Operator-Mustern.

## 22. Was ausdrücklich nicht entschieden wird

Die Recherche rechtfertigt nicht:

- AutomatedLab als verpflichtende Gesamtplattform;
- Kubernetes als Lab Core;
- Terraform als Workflow Engine;
- Vagrant als einheitlichen Provider für Hyper-V, Docker und Podman;
- eine vollständige TOSCA-Implementierung;
- CNAB Invocation Images als Packagepflicht;
- Ansible, Chef, Nix oder Dagger als allgemeine Scriptlaufzeit;
- identische Providerfähigkeiten ohne Capability-Nachweis.

## 23. Forschungs- und Spike-Backlog

### `RES-001` – AutomatedLab-Backend-Spike

- eine synthetische Windows-VM definieren;
- Plan ohne Mutation ableiten;
- Installation ausführen;
- tatsächliche IDs und Endpunkte erfassen;
- Stop, Start, Reset und Destroy gegen Lab-State prüfen;
- keine AutomatedLab-internen Namen als alleinige Löschgrundlage verwenden.

### `RES-002` – Native-Hyper-V-Spike

Denselben Resource Graph direkt über PowerShell/CIM erfüllen und Komplexität, Kontrolle, Recovery und Wartbarkeit vergleichen.

### `RES-003` – Docker-/Podman-Parität

Ein identisches logisches Drei-Service-Environment auf Docker und Podman planen und ausführen. Unterschiede werden als Capability- und Provider-Override dokumentiert.

### `RES-004` – Package-/Binding-Prototyp

Ein Package mit:

- einer SQL-Component;
- einer Framework-Deployment-Unit;
- einem DataSet;
- einem Probe;
- einer Assertion;
- typisierten Endpoint- und Credential-Reference-Bindings.

### `RES-005` – Nicht-SQL-Architekturbeweis

Ein HTTP-Mock-Service und eine Composite-Cluster-Fixture müssen ohne Änderung der Core-Schemas modellierbar sein.

### `RES-006` – Fault-Handler-Spike

Toxiproxy gegen Container und VM-Endpunkte prüfen; native Netzwerkfaults als separate Capability behandeln.

### `RES-007` – Lizenz- und Abhängigkeitsreview

Vor jeder verpflichtenden Drittanbieterabhängigkeit:

- Lizenz;
- Distributionsrecht;
- Betriebsmodell;
- Update- und Securityverantwortung;
- Offlinefähigkeit;
- Plattformabdeckung;
- Maintenance- und Exitstrategie

prüfen.

## 24. Abnahmekriterien der Recherchephase

Die Recherchephase gilt als abgeschlossen, wenn:

1. kein bestehendes Tool ohne Vergleich zum Gesamtvertrag als voreilige Kernplattform gewählt wird;
2. AutomatedLab und ein nativer Hyper-V-Pfad prototypisch verglichen sind;
3. Docker und Podman getrennte Capability-Nachweise besitzen;
4. Package, Topology, Workflow, State, Binding und Faults aus den besten vorhandenen Mustern abgeleitet sind;
5. mindestens ein nicht-SQL-basierter Architekturproof besteht;
6. Drittanbieterabhängigkeiten nur nach Lizenz- und Exit-Review verpflichtend werden;
7. alle Entscheidungen im Masterplan und in den öffentlichen Contracts synchronisiert sind.
