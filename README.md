# SQL Server Lab

---

# ⚠️ READ BEFORE USE

## License notice

**NOTICE: This software is NOT Open Source. Use is governed by a custom Attribution & Non-Commercial Redistribution License.**

1. **NO RESALE:** Selling, renting, leasing, or charging third parties for access to this repository, its scripts, lab definitions, templates, documentation, or generated project content is prohibited.
2. **ATTRIBUTION REQUIRED:** The copyright notice for **gecompat - Gerhard Pisch** must be preserved.
3. **NO LIABILITY:** Use is at your own risk. Lab scenarios may deliberately create resource pressure, failures, configuration changes, or destructive states inside isolated lab scopes.

The complete terms are defined in [LICENCE.md](./LICENCE.md).

---

## Zweck

`SQL_Server_Lab` wird die gemeinsame, projektunabhängige Bereitstellungs- und Szenarioplattform für reproduzierbare Testumgebungen mit SQL Server als erstem fachlichem Schwerpunkt.

Das Repository ergänzt insbesondere:

- [`gecompat/SQL_Server_Analyze`](https://github.com/gecompat/SQL_Server_Analyze),
- [`gecompat/SQL_PerformanceSchulung`](https://github.com/gecompat/SQL_PerformanceSchulung).

Es trennt Infrastruktur, Lifecycle, Ressourcensteuerung und Fault Injection von den fachlichen Inhalten der konsumierenden Projekte. Die Core-Verträge werden technologieoffen angelegt, damit spätere Komponenten wie Hadoop-Cluster, REST-Dienste, Clientanwendungen oder weitere Datenplattformen ohne parallele Orchestrierung ergänzt werden können.

## Drei Nutzungsarten

### 1. Schnelle SQL-Server-Umgebung

Eine menügeführte Bereitstellung für Benutzer, die kurzfristig eine isolierte SQL-Server-Instanz benötigen. Auswählbar sind unter anderem SQL-Server-Version, Container- oder VM-Plattform, CPU, RAM, Storage, Ports, Persistenz und optionale Zusatzfunktionen.

### 2. Reproduzierbares Projektszenario

Ein konsumierendes Repository stellt ein versioniertes **Lab Package** bereit. Dieses beschreibt:

- benötigte logische Komponenten und Beziehungen;
- Installations- und Konfigurationsinhalte;
- synthetische Testdaten und deren Verifikation;
- Workloads, Beobachtungen und Assertions;
- Ressourcen-, Safety-, Privacy- und Cleanup-Grenzen.

Das Lab prüft Hostfähigkeiten, expandiert zusammengesetzte Komponenten, wählt passende Provider und erzeugt vor jeder Mutation einen vollständigen Plan.

Beispiele:

- Performance-Schulungsdemo mit kontrollierter Datenverteilung, Baseline, Last, Messung, Gegenmaßnahme und Cleanup;
- Analyse-Szenario mit Blocking Chain, TempDB-Druck, I/O-Engpass, Netzwerkverzögerung oder versionsabhängigem SQL-Server-Verhalten;
- späteres Cluster- oder Service-Szenario mit SQL-Quelle, Hadoop-Verarbeitung und REST-basierter Ergebnisprüfung.

### 3. Frei konfigurierbare Labortopologie

Eine menügeführte oder deklarative Konfiguration für beliebige synthetische Testumgebungen, beispielsweise mehrere SQL-Server-Versionen, Windows- und Linux-Gäste, getrennte Data-/Log-/TempDB-Datenträger, definierte Netzwerkprofile oder unterschiedliche CPU-/RAM-/I/O-Grenzen.

## Zielplattformen

| Provider | Zielrolle |
|---|---|
| Docker Engine | primäre portable Linux-Container-Lane |
| Podman | kompatible alternative Container-Lane |
| Hyper-V mit Windows-Gästen | Windows Authentication, SQL Server Agent, WSFC-/FCI- und Windows-spezifische Szenarien |
| Hyper-V mit Linux-Gästen | kontrollierte Linux-, Netzwerk- und Storage-Szenarien |
| Verteilte Ausführung | optionale Kombination eines Hyper-V-Hosts mit einem nativen Linux-Containerhost |
| spätere Provider Plugins | beispielsweise Kubernetes, Remote Hosts oder andere ausdrücklich freigegebene Plattformen |

Nicht jede Plattform kann jede Aussage gleichwertig nachweisen. Fehlende Capabilities führen zu einem strukturierten `NOT_EXECUTED` oder `UNSUPPORTED`, nicht zu einer vorgetäuschten Simulation.

## Architekturgrundsatz

Das Lab trennt folgende Vertragsebenen:

1. **Run Request:** Welche Umgebung oder welches Szenario wird angefordert?
2. **Project Adapter:** Welche versionierten Lab Packages stellt ein Projekt bereit?
3. **Lab Package:** Welche Environments, Inhalte, DataSets und Workflows gehören zusammen?
4. **Environment Blueprint:** Welche logischen Components und Beziehungen werden benötigt?
5. **Component- und Action-Type Registry:** Wie werden Technologien und Aktionen typisiert erweitert?
6. **Provider:** Wie werden logische Ressourcen konkret bereitgestellt?
7. **Runtime Bindings:** Welche lokalen Endpunkte, Secret-Referenzen und Outputs verbinden die Schritte?
8. **Workflow und State:** Welche Schritte laufen in welcher Reihenfolge, und welche Mutationen müssen bereinigt werden?
9. **Control Plane:** CLI und spätere REST-/UI-Adapter verwenden dieselben Commands, Operations und Events.

Lokale Secrets, reale Hostinformationen, konkrete Pfade und erzeugte Laufzeitdaten verbleiben ausschließlich in ignorierten lokalen Bereichen.

## Verbindliche Planung

- [Master-Umsetzungsplan](Documentation/Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
- [Erweiterbarer Umgebungs- und Ausführungsvertrag](Documentation/Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md)
- [Zukünftige Anwendungsfälle und Erweiterungsleitplanken](Documentation/Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md)
- [Projektintegrationsvertrag](Documentation/Architecture/PROJECT_INTEGRATION_CONTRACT.md)
- [Manifest- und Schnittstellenarchitektur](Documentation/Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md)
- [Migrationsinventar und Ablöseplan](Documentation/Migration/MIGRATION_INVENTORY_AND_DECISIONS.md)
- [Privacy- und Artefaktsicherheitsvertrag](Documentation/Quality/PRIVACY_AND_ARTIFACT_SECURITY.md)
- [Sprach-, Übersetzungs- und Schreibstandard](Documentation/Standards/LANGUAGE_TRANSLATION_AND_STYLE_STANDARD.md)
- [Lokale Validierungsstrategie ohne CI/CD](Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md)
- [KI-Projektkontext](.ai/PROJECT_CONTEXT.md)

## Status

**Status:** `PLANNING_FOUNDATION`

Das Repository enthält zunächst die verbindliche Architektur-, Qualitäts-, Migrations- und Umsetzungsplanung. Vor der Implementierung der Provider werden die Package-, Component-, Action-, Binding-, Workflow- und Control-Plane-Verträge prototypisch gegen zwei SQL-Szenarien und mindestens einen technologieoffenen Proof geprüft.

## CI/CD-Abgrenzung

CI/CD ist kein Bestandteil dieses Repositories. Qualitätsprüfungen werden lokal und reproduzierbar ausführbar gestaltet. Eine spätere zentrale Automatisierung kann in einem getrennten Repository umgesetzt werden und die öffentlichen Commands, Packages, Plans und Events konsumieren, ohne die Produkt- und Labarchitektur hier mit Runner- oder Workflowlogik zu vermischen.
