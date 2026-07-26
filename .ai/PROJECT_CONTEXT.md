# Projektkontext

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-07-26 |
| Repository | `gecompat/SQL_Server_Lab` |

## 1. Ziel

`SQL_Server_Lab` ist eine gemeinsame Plattform für reproduzierbare SQL-Server-Testumgebungen.

Hauptanwendungsfälle:

- schnelle SQL-Server-Umgebung;
- Performance-Schulungsdemos;
- Analyse- und Diagnosekonstellationen;
- kontrollierte Last- und Fault-Szenarien;
- SQL-Server-Availability-, Security- und Integrationsszenarien.

SQL Server steht immer im Zentrum. Supporting Components wie Domain Controller, Hadoop-Cluster oder REST-Dienste sind nur zulässig, wenn sie einen dokumentierten SQL-Server-Zweck erfüllen.

## 2. Kernprovider

Verbindlich:

```text
Hyper-V
Docker
Podman
```

Die drei Provider erfüllen denselben übergeordneten Plan-, Resource-Assessment-, State-, Binding-, Recovery- und Cleanup-Vertrag. Providerfähigkeiten werden getrennt nachgewiesen.

## 3. SQL-Server-Versionen

SQL-Versionen werden über einen versionierten Katalog und Version Constraints aufgelöst. Core-Schemas enthalten kein dauerhaftes Enum einzelner Produktjahre.

Derzeit vorgesehen:

- SQL Server 2019;
- SQL Server 2022;
- SQL Server 2025.

Neue Versionen werden über Katalogeintrag, Provider-Mapping, Capability Record und Validierung ergänzt. Alte Versionen werden über `DEPRECATED`, `RETIRED` oder `BLOCKED` aus dem aktiven Umfang genommen, ohne historische Vertragsinformationen zu löschen.

## 4. Primärprojekte

- `gecompat/SQL_Server_Analyze`;
- `gecompat/SQL_PerformanceSchulung`.

Die Projekte liefern SQL Server Lab Packages. Sie behalten fachliche Installations-, DataSet-, Database-Artifact-, Workload-, Probe-, Assertion- und Cleanup-Inhalte.

## 5. Feste Architekturentscheidungen

- `SqlPurpose` ist Pflicht.
- Mindestens eine Primary SQL Component ist erforderlich.
- Supporting Components benötigen einen dokumentierten SQL-Bezug.
- Project Adapter entdecken Packages; sie sind keine Universal-Skripte.
- Packages trennen Environment, Deployment Units, DataSets, Database Artifacts und Workflow.
- `Arrange`, `Act`, `Observe`, `Assert`, `Cleanup` sind semantische Phasen über einem Workflow DAG.
- Inputs und Outputs werden über typisierte Runtime Bindings verbunden.
- konkrete Endpunkte, Pfade und Secretwerte stehen nicht in versionierten Manifesten.
- vor jeder Mutation wird ein read-only Bound Plan erzeugt.
- vor jeder Mutation werden CPU, RAM, Storage, Provider-Overhead und Hostreserve bewertet.
- vorhergesagte Ressourcenunterversorgung kann ausdrücklich übersteuert werden.
- Resource Override setzt keine Safety-, Scope-, Secret-, Lizenz-, Versions- oder Datenklassifikationsblocker außer Kraft.
- vor jeder Mutation existiert ein maschinenlesbarer Cleanup Plan.
- State enthält tatsächliche Ressourcen-IDs.
- Cleanup verwendet IDs, Owner Marker und Scope, nicht bloß Namen.
- Fehler lösen standardmäßig automatische Compensation aus.
- unvollständiges Cleanup ergibt `RECOVERY_REQUIRED`.
- Cleanup ist idempotent und über `ResumeCleanup`, `RecoverRun` oder `DestroyRun` wiederaufnehmbar.
- Docker und Podman sind getrennte Provider.
- Hyper-V kann intern ein optionales AutomatedLab-Backend oder einen nativen Provider verwenden; der öffentliche Contract bleibt gleich.
- CI/CD ist kein Bestandteil dieses Repositorys.

## 6. Datenbankartefakte

Zulässig:

- im Lab erzeugte Backups zulässiger Labdatenbanken;
- Wiederverwendung eines Lab-Backups in späteren Runs;
- öffentliche Demo- und Beispieldatenbanken mit Quelle, Lizenz, Hash und Versionskompatibilität;
- lokal bereitgestellte Entwicklungs-, Test- oder Lab-Backups mit ausdrücklicher Nicht-Produktionsklassifikation.

Blockiert:

- Produktionsbackups;
- aus Produktivsystemen extrahierte reale Daten;
- unbekannte oder unklassifizierte Backups;
- automatische Übernahme lokaler Backups in Repository, GitHub-Inhalte oder Downloadpakete.

Jedes Datenbankartefakt benötigt Klassifikation, Hash, Größe, erwartete Restore-Größe, Versionskompatibilität, Verifikation, Retention und Cleanup Policy.

## 7. Scope

Gültige Supporting Components:

- Domain Controller/DNS für Authentication, Kerberos, WSFC, AG oder FCI;
- Hadoop für PolyBase;
- REST-/HTTP-Service als SQL-Client, Datenquelle, Datenziel oder Mock;
- SQL Workload Driver;
- Router und Fault Controller;
- Observability Collector;
- Storage Service für SQL-bezogene Szenarien.

Nicht Ziel:

- allgemeines Hadoop-Lab;
- allgemeines REST-Testframework;
- allgemeines Active-Directory-Lab;
- allgemeine Multi-Purpose-Orchestrierungsplattform.

## 8. Privacy

In Repository-, GitHub-, Package- und Downloadartefakten sind verboten:

- reale Personen-, Benutzer-, Kunden-, Firmen- und Organisationsdaten;
- reale Host-, Netzwerk-, Endpoint- und Pfadinformationen;
- reale Datenbank- und Objektstrukturen aus Produktivsystemen;
- Secrets, Tokens, Connection Strings und private Schlüssel;
- reale Logs, Plans, Responses, Screenshots und Diagnoseexports;
- Produktionsbackups oder unklassifizierte Datenbankartefakte.

Öffentliche Beispieldatenbanken und ausdrücklich klassifizierte lokale Nicht-Produktionsartefakte sind nicht automatisch Repositoryartefakte. Lokale Artifact Stores bleiben ignoriert und werden nicht automatisch exportiert.

Lokale Runtime States und technische Evidence dürfen notwendige lokale Werte enthalten, bleiben aber ignoriert und werden nicht automatisch exportiert.

Bei unklarer Klassifikation wird vor dem Schreiben oder Git-Vorgang angehalten und eine nicht sensitive Alternative verwendet.

## 9. Sprache

- Dokumentation: Deutsch.
- etablierte englische Fachbegriffe bleiben erhalten.
- JSON-Felder, IDs, Codes, PowerShell-Parameter und API-Bezeichner: Englisch.
- `LICENCE.md`: englische Masterfassung ist maßgeblich.
- Statuscodes werden nicht übersetzt.

## 10. Lizenz

Das Projekt verwendet eine eigene `Attribution & Non-Commercial Redistribution`-Lizenz und ist nicht Open Source.

Attribution:

```text
gecompat - Gerhard Pisch
```

Drittsoftware, öffentliche Beispieldatenbanken und Medien behalten ihre eigenen Lizenzbedingungen. Windows-, SQL-Server-, Container- oder Betriebssystemmedien werden nicht versioniert oder weitergegeben.

## 11. Migration

- generischer Lifecycle aus Analyze `QuickStart` und `Lab/QuickTest` wird konsolidiert;
- starke State-, Secret-, Ownership-, Cleanup- und Recovery-Verträge aus `Lab/QuickTest` haben Vorrang;
- einfache Benutzerführung aus `QuickStart` bleibt erhalten;
- Analyze-spezifische Framework- und Findinglogik bleibt im Analyze Package;
- Schulungs-Demo-Vertrag bleibt im Schulungsrepository;
- keine Entfernung alter Pfade vor Funktionsparität und Wrapperabnahme.

## 12. Forschung

Bestehende Projekte werden als Musterquellen untersucht, nicht zu einer Gesamtplattform zusammengebaut.

AutomatedLab wird als mögliches Hyper-V-Backend gegen einen nativen Provider geprüft. Docker und Podman bleiben eigene Provider.

## 13. Umsetzungsreihenfolge

1. Repository- und Governance-Basis;
2. SQL Purpose, Package und Contract Schemas;
3. SQL Version Catalog;
4. Database-Artifact- und Public-Sample-Verträge;
5. Resource Assessment, Overcommit und Cleanup Plan;
6. read-only Planner, Run State und Recovery State;
7. Docker Quick Environment;
8. Podman-Parität;
9. Hyper-V SQL Environment;
10. Performance-Schulungs-Pilot;
11. Analyze-Pilot;
12. Domain Controller als SQL Supporting Component;
13. SQL HA/Cluster;
14. PolyBase/Hadoop oder REST nur bei konkretem SQL-Bedarf.

## 14. Statuswahrheit

Planungsdokumente sind kein Runtime-Nachweis. Eine Funktion darf erst als implementiert oder validiert bezeichnet werden, wenn Code und passende lokale Tests vorhanden sind.
