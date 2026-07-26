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

`SQL_Server_Lab` wird die gemeinsame, projektunabhängige Bereitstellungs- und Szenarioplattform für reproduzierbare SQL-Server-Testumgebungen.

Das Repository ergänzt insbesondere:

- [`gecompat/SQL_Server_Analyze`](https://github.com/gecompat/SQL_Server_Analyze),
- [`gecompat/SQL_PerformanceSchulung`](https://github.com/gecompat/SQL_PerformanceSchulung).

Es trennt Infrastruktur, Lifecycle, Ressourcensteuerung und Fault Injection von den fachlichen Inhalten der konsumierenden Projekte.

## Drei Nutzungsarten

### 1. Schnelle SQL-Server-Umgebung

Eine menügeführte Bereitstellung für Benutzer, die kurzfristig eine isolierte SQL-Server-Instanz benötigen. Auswählbar sind unter anderem SQL-Server-Version, Container- oder VM-Plattform, CPU, RAM, Storage, Ports, Persistenz und optionale Zusatzfunktionen.

### 2. Reproduzierbares Projektszenario

Ein konsumierendes Repository fordert über einen versionierten Adapter und ein Szenariomanifest eine definierte Konstellation an. Das Lab prüft die Hostfähigkeiten, plant die benötigte Topologie und baut nur die tatsächlich erforderlichen Ressourcen auf.

Beispiele:

- Performance-Schulungsdemo mit kontrollierter Datenverteilung, Baseline, Last, Messung, Gegenmaßnahme und Cleanup;
- Analyse-Szenario mit Blocking Chain, TempDB-Druck, I/O-Engpass, Netzwerkverzögerung oder versionsabhängigem SQL-Server-Verhalten;
- Last- und Fault-Injection-Szenario mit klaren Ressourcen- und Sicherheitsgrenzen.

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

Nicht jede Plattform kann jede Aussage gleichwertig nachweisen. Fehlende Capabilities führen zu einem strukturierten `NOT_EXECUTED` oder `UNSUPPORTED`, nicht zu einer vorgetäuschten Simulation.

## Architekturgrundsatz

Das Lab trennt fünf Vertragsebenen:

1. **Run Request:** Was soll aufgebaut oder ausgeführt werden?
2. **Project Adapter:** Welche projektbezogenen Installations-, Beobachtungs- und Validierungsschritte gelten?
3. **Scenario:** Welche Konstellation wird durch `Arrange`, `Act`, `Observe`, `Assert` und `Cleanup` beschrieben?
4. **Topology:** Welche Nodes, Netzwerke, Storage-Rollen und SQL-Server-Versionen werden benötigt?
5. **Provider:** Wie werden diese Ressourcen mit Docker, Podman oder Hyper-V umgesetzt?

Lokale Secrets, reale Hostinformationen, konkrete Pfade und erzeugte Laufzeitdaten verbleiben ausschließlich in ignorierten lokalen Bereichen.

## Verbindliche Planung

- [Master-Umsetzungsplan](Documentation/Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
- [Projektintegrationsvertrag](Documentation/Architecture/PROJECT_INTEGRATION_CONTRACT.md)
- [Manifest- und Schnittstellenarchitektur](Documentation/Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md)
- [Migrationsinventar und Ablöseplan](Documentation/Migration/MIGRATION_INVENTORY_AND_DECISIONS.md)
- [Privacy- und Artefaktsicherheitsvertrag](Documentation/Quality/PRIVACY_AND_ARTIFACT_SECURITY.md)
- [Sprach-, Übersetzungs- und Schreibstandard](Documentation/Standards/LANGUAGE_TRANSLATION_AND_STYLE_STANDARD.md)
- [Lokale Validierungsstrategie ohne CI/CD](Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md)
- [KI-Projektkontext](.ai/PROJECT_CONTEXT.md)

## Status

**Status:** `PLANNING_FOUNDATION`

Das Repository enthält zunächst die verbindliche Architektur-, Qualitäts-, Migrations- und Umsetzungsplanung. Die ausführbaren Provider, Manifeste und Orchestrierungsskripte werden anschließend in klar abgegrenzten Wellen implementiert.

## CI/CD-Abgrenzung

CI/CD ist kein Bestandteil dieses Repositories. Qualitätsprüfungen werden lokal und reproduzierbar ausführbar gestaltet. Eine spätere zentrale Automatisierung kann in einem getrennten Repository umgesetzt werden und die öffentlichen CLI- und Manifestverträge konsumieren, ohne die Produkt- und Labarchitektur hier mit Runner- oder Workflowlogik zu vermischen.
