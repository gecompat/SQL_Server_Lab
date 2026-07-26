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

`SQL_Server_Lab` ist die gemeinsame Bereitstellungs- und Szenarioplattform für reproduzierbare **SQL-Server-Testumgebungen**.

Das Repository ergänzt insbesondere:

- [`gecompat/SQL_Server_Analyze`](https://github.com/gecompat/SQL_Server_Analyze),
- [`gecompat/SQL_PerformanceSchulung`](https://github.com/gecompat/SQL_PerformanceSchulung).

SQL Server steht immer im Zentrum. Zusätzliche Komponenten wie Domain Controller, Hadoop-Cluster, REST-Dienste, Clientanwendungen, Router oder Observability-Systeme werden nur dann vorgesehen, wenn sie für ein konkretes SQL-Server-Szenario benötigt werden, beispielsweise für Windows Authentication, Always On, PolyBase, ETL, externe Datenquellen oder kontrollierte Netzwerkfehler.

Das Repository trennt Infrastruktur, Lifecycle, Ressourcensteuerung und Fault Injection von den fachlichen Inhalten der konsumierenden Projekte.

## Drei Nutzungsarten

### 1. Schnelle SQL-Server-Umgebung

Eine menügeführte Bereitstellung für Benutzer, die kurzfristig eine isolierte SQL-Server-Instanz benötigen. Auswählbar sind unter anderem SQL-Server-Version, Container- oder VM-Plattform, CPU, RAM, Storage, Ports, Persistenz und optionale Zusatzfunktionen.

### 2. Reproduzierbares SQL-Server-Projektszenario

Ein konsumierendes Repository stellt ein versioniertes **Lab Package** bereit. Dieses beschreibt:

- den konkreten SQL-Server-Zweck;
- benötigte SQL-Server-Komponenten und unterstützende Systeme;
- SQL-Server-Version Constraints;
- Installations- und Konfigurationsinhalte;
- erzeugte Testdaten oder zulässige Datenbankartefakte;
- Workloads, Beobachtungen und Assertions;
- Ressourcen-, Safety-, Privacy-, Recovery- und Cleanup-Grenzen.

Das Lab prüft Hostfähigkeiten, löst SQL-Version und Topologie auf, ergänzt nur die erforderlichen Supporting Components, bewertet die verfügbaren Ressourcen, wählt passende Provider und erzeugt vor jeder Mutation einen vollständigen Plan einschließlich Cleanup Plan.

Beispiele:

- Performance-Schulungsdemo mit kontrollierter Datenverteilung, Baseline, Last, Messung, Gegenmaßnahme und Cleanup;
- Analyse-Szenario mit Blocking Chain, TempDB-Druck, I/O-Engpass, Netzwerkverzögerung oder versionsabhängigem SQL-Server-Verhalten;
- Fortsetzung eines Labstands über ein zuvor erzeugtes Lab-Backup;
- Verwendung einer öffentlichen Demo-Datenbank mit dokumentierter Quelle, Lizenz und Prüfsumme;
- PolyBase-Szenario mit SQL Server als Primärsystem und einem Hadoop-Cluster als unterstützender Datenquelle;
- Windows-Authentication- oder Availability-Szenario mit Domain Controller, DNS und mehreren SQL-Server-Knoten.

### 3. Frei konfigurierbare SQL-Server-Labortopologie

Eine menügeführte oder deklarative Konfiguration für synthetische SQL-Server-Testumgebungen, beispielsweise mehrere SQL-Server-Versionen, Windows- und Linux-Gäste, getrennte Data-/Log-/TempDB-Datenträger, definierte Netzwerkprofile oder unterschiedliche CPU-/RAM-/I/O-Grenzen.

Eine Umgebung ohne SQL-Server-Zweck ist kein Ziel dieses Repositorys.

## SQL-Server-Versionen

**Derzeit** sind SQL Server 2019, SQL Server 2022 und SQL Server 2025 als aktive Versionseinträge vorgesehen.

Die Schnittstellen sind nicht auf diese drei Versionen festgeschrieben. Neue Versionen werden später über einen SQL Version Catalog, Provider-Mappings und Capability Records ergänzt. Alte Versionen können über Statuswerte wie `DEPRECATED`, `RETIRED` oder `BLOCKED` kontrolliert aus dem aktiven Umfang genommen werden.

## Datenbankartefakte und Backups

Zulässig sind:

- im Lab erzeugte Backups zulässiger Labdatenbanken;
- Wiederverwendung dieser Backups in späteren Runs;
- öffentliche Demo- und Beispieldatenbanken;
- ausdrücklich klassifizierte lokale Entwicklungs-, Test- oder Lab-Backups.

Produktionsbackups, aus Produktivsystemen extrahierte Daten sowie unbekannte oder unklassifizierte Artefakte bleiben unzulässig.

Lokale Backups werden nicht automatisch in das Repository, GitHub-Inhalte oder Downloadpakete übernommen.

## Ressourcen und Cleanup

Vor jeder Mutation bewertet das Lab mindestens CPU, RAM, freien Speicher, Provider-Overhead, Images beziehungsweise VHDX, Data, Log, TempDB, Backup-, Download- und Restore-Peak.

Eine vorhergesagte Unterversorgung darf nach ausdrücklicher Bestätigung übersteuert werden. Der Defizitstatus bleibt sichtbar. Unsichere Pfade, fehlende Providerfähigkeiten, blockierte SQL-Versionen, unzulässige Daten und ein fehlender Cleanup Plan sind nicht übersteuerbar.

Vor der ersten Mutation wird ein lokaler Run State samt vollständigem Cleanup Plan angelegt. Fehler lösen standardmäßig automatische Compensation aus. Partielles Cleanup bleibt als `RECOVERY_REQUIRED` sichtbar und kann über einen wiederaufnehmbaren Recovery-/Destroy-Pfad fortgesetzt werden.

## Zielplattformen

| Provider | Zielrolle |
|---|---|
| Docker Engine | primäre portable Linux-Container-Lane |
| Podman | kompatible alternative Container-Lane |
| Hyper-V mit Windows-Gästen | Windows Authentication, SQL Server Agent, WSFC-/FCI- und Windows-spezifische Szenarien |
| Hyper-V mit Linux-Gästen | kontrollierte Linux-, Netzwerk-, Storage- und PolyBase-Supporting-Szenarien |
| Verteilte Ausführung | optionale Kombination eines Hyper-V-Hosts mit einem nativen Linux-Containerhost |

Hyper-V, Docker und Podman sind verbindliche Kernprovider. Weitere Provider können später ergänzt werden, sind aber kein aktueller Hauptzweck.

Nicht jede Plattform kann jede Aussage gleichwertig nachweisen. Fehlende Capabilities führen zu einem strukturierten `NOT_EXECUTED` oder `UNSUPPORTED`, nicht zu einer vorgetäuschten Simulation.

## Architekturgrundsatz

Das Lab trennt folgende Vertragsebenen:

1. **Run Request:** Welche SQL-Server-Umgebung oder welches SQL-Server-Szenario wird angefordert?
2. **Project Adapter:** Welche versionierten SQL-Server-Lab-Packages stellt ein Projekt bereit?
3. **Lab Package:** Welcher `SqlPurpose`, welche Version Constraints, Environments, Inhalte, DataSets, Database Artifacts und Workflows gehören zusammen?
4. **Environment Blueprint:** Welche primären SQL-Server-Komponenten und Supporting Components werden benötigt?
5. **Registries:** Welche SQL-Versionen, Component Types und Action Types sind verfügbar?
6. **Provider:** Wie werden logische Ressourcen über Hyper-V, Docker oder Podman konkret bereitgestellt?
7. **Runtime Bindings:** Welche lokalen Endpunkte, Secret-Referenzen und Outputs verbinden die Schritte?
8. **Resource Assessment:** Reichen CPU, RAM und Storage aus, oder wird ein bewusster Overcommit benötigt?
9. **Workflow, State und Recovery:** Welche Schritte laufen in welcher Reihenfolge, und wie werden Mutationen kompensiert und bereinigt?
10. **Control Plane:** CLI und eine spätere REST-/UI-Anbindung verwenden dieselben Commands, Operations und Events.

Lokale Secrets, reale Hostinformationen, konkrete Pfade und erzeugte Laufzeitdaten verbleiben ausschließlich in ignorierten lokalen Bereichen.

## Verbindliche Planung

- [Dokumentationsübersicht und Lesereihenfolge](Documentation/README.md)
- [Master-Umsetzungsplan](Documentation/Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
- [Verbindliche Masterplan-Ergänzung](Documentation/Project_Planning/MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md)
- [SQL-Server-zentrierte Scope-Entscheidung](Documentation/Architecture/SQL_SERVER_CENTRIC_SCOPE_DECISION.md)
- [Erweiterbarer Umgebungs- und Ausführungsvertrag](Documentation/Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md)
- [Zukünftige SQL-Server-Anwendungsfälle und Erweiterungsleitplanken](Documentation/Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md)
- [Projektintegrationsvertrag](Documentation/Architecture/PROJECT_INTEGRATION_CONTRACT.md)
- [Manifest- und Schnittstellenarchitektur](Documentation/Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md)
- [Analyse bestehender Lab- und Orchestrierungsprojekte](Documentation/Research/EXISTING_LAB_AND_ORCHESTRATION_PROJECTS_REVIEW.md)
- [Migrationsinventar und Ablöseplan](Documentation/Migration/MIGRATION_INVENTORY_AND_DECISIONS.md)
- [Privacy- und Artefaktsicherheitsvertrag](Documentation/Quality/PRIVACY_AND_ARTIFACT_SECURITY.md)
- [Sprach-, Übersetzungs- und Schreibstandard](Documentation/Standards/LANGUAGE_TRANSLATION_AND_STYLE_STANDARD.md)
- [Lokale Validierungsstrategie ohne CI/CD](Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md)
- [KI-Projektkontext](.ai/PROJECT_CONTEXT.md)

## Status

**Status:** `PLANNING_FOUNDATION`

Das Repository enthält zunächst die verbindliche Architektur-, Qualitäts-, Migrations- und Umsetzungsplanung. SQL Version Catalog, Schemas, CLI, Planner, Provider, Backup-/Restore-Actions, Resource Assessment und Recovery Engine sind noch nicht implementiert.

## CI/CD-Abgrenzung

CI/CD ist kein Bestandteil dieses Repositories. Qualitätsprüfungen werden lokal und reproduzierbar ausführbar gestaltet. Eine spätere zentrale Automatisierung kann in einem getrennten Repository umgesetzt werden und die öffentlichen Commands, Packages, Plans und Events konsumieren, ohne die Produkt- und Labarchitektur hier mit Runner- oder Workflowlogik zu vermischen.
