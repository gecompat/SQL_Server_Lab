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

Die drei Provider erfüllen denselben übergeordneten Plan-, State-, Binding- und Cleanup-Vertrag. Providerfähigkeiten werden getrennt nachgewiesen.

## 3. Primärprojekte

- `gecompat/SQL_Server_Analyze`;
- `gecompat/SQL_PerformanceSchulung`.

Die Projekte liefern SQL Server Lab Packages. Sie behalten fachliche Installations-, DataSet-, Workload-, Probe-, Assertion- und Cleanup-Inhalte.

## 4. Feste Architekturentscheidungen

- `SqlPurpose` ist Pflicht.
- Mindestens eine Primary SQL Component ist erforderlich.
- Supporting Components benötigen einen dokumentierten SQL-Bezug.
- Project Adapter entdecken Packages; sie sind keine Universal-Skripte.
- Packages trennen Environment, Deployment Units, DataSets und Workflow.
- `Arrange`, `Act`, `Observe`, `Assert`, `Cleanup` sind semantische Phasen über einem Workflow DAG.
- Inputs und Outputs werden über typisierte Runtime Bindings verbunden.
- konkrete Endpunkte, Pfade und Secretwerte stehen nicht in versionierten Manifesten.
- vor jeder Mutation wird ein read-only Bound Plan erzeugt.
- State enthält tatsächliche Ressourcen-IDs.
- Cleanup verwendet IDs, Owner Marker und Scope, nicht bloß Namen.
- unvollständiges Cleanup ergibt `RECOVERY_REQUIRED`.
- Docker und Podman sind getrennte Provider.
- Hyper-V kann intern ein optionales AutomatedLab-Backend oder einen nativen Provider verwenden; der öffentliche Contract bleibt gleich.
- CI/CD ist kein Bestandteil dieses Repositorys.

## 5. Scope

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

## 6. Privacy

In Repository-, GitHub-, Package- und Downloadartefakten sind verboten:

- reale Personen-, Benutzer-, Kunden-, Firmen- und Organisationsdaten;
- reale Host-, Netzwerk-, Endpoint- und Pfadinformationen;
- reale Datenbank- und Objektstrukturen;
- Secrets, Tokens, Connection Strings und private Schlüssel;
- reale Logs, Plans, Responses, Screenshots und Diagnoseexports.

Beispiele und Tests sind ausschließlich synthetisch.

Lokale Runtime States und technische Evidence dürfen notwendige lokale Werte enthalten, bleiben aber ignoriert und werden nicht automatisch exportiert.

Bei unklarer Klassifikation wird vor dem Schreiben oder Git-Vorgang angehalten und eine nicht sensitive Alternative verwendet.

## 7. Sprache

- Dokumentation: Deutsch.
- etablierte englische Fachbegriffe bleiben erhalten.
- JSON-Felder, IDs, Codes, PowerShell-Parameter und API-Bezeichner: Englisch.
- `LICENCE.md`: englische Masterfassung ist maßgeblich.
- Statuscodes werden nicht übersetzt.

## 8. Lizenz

Das Projekt verwendet eine eigene `Attribution & Non-Commercial Redistribution`-Lizenz und ist nicht Open Source.

Attribution:

```text
gecompat - Gerhard Pisch
```

Drittsoftware und Medien behalten ihre eigenen Lizenzbedingungen. Windows-, SQL-Server-, Container- oder Betriebssystemmedien werden nicht versioniert oder weitergegeben.

## 9. Migration

- generischer Lifecycle aus Analyze `QuickStart` und `Lab/QuickTest` wird konsolidiert;
- starke State-, Secret-, Ownership- und Cleanup-Verträge aus `Lab/QuickTest` haben Vorrang;
- einfache Benutzerführung aus `QuickStart` bleibt erhalten;
- Analyze-spezifische Framework- und Findinglogik bleibt im Analyze Package;
- Schulungs-Demo-Vertrag bleibt im Schulungsrepository;
- keine Entfernung alter Pfade vor Funktionsparität und Wrapperabnahme.

## 10. Forschung

Bestehende Projekte werden als Musterquellen untersucht, nicht zu einer Gesamtplattform zusammengebaut.

Relevant:

- AutomatedLab;
- Microsoft MSLab;
- Lability;
- Compose;
- Testcontainers;
- Molecule;
- Test Kitchen;
- Terraform/Pulumi;
- TOSCA;
- CNAB/Porter;
- Ambari;
- Toxiproxy/Chaos Mesh.

AutomatedLab wird als mögliches Hyper-V-Backend gegen einen nativen Provider geprüft. Docker und Podman bleiben eigene Provider.

## 11. Umsetzungsreihenfolge

1. Repository- und Governance-Basis;
2. SQL Purpose, Package und Contract Schemas;
3. read-only Planner und State Skeleton;
4. Docker Quick Environment;
5. Podman-Parität;
6. Hyper-V SQL Environment;
7. Performance-Schulungs-Pilot;
8. Analyze-Pilot;
9. Domain Controller als SQL Supporting Component;
10. SQL HA/Cluster;
11. PolyBase/Hadoop oder REST nur bei konkretem SQL-Bedarf.

## 12. Statuswahrheit

Planungsdokumente sind kein Runtime-Nachweis. Eine Funktion darf erst als implementiert oder validiert bezeichnet werden, wenn Code und passende lokale Tests vorhanden sind.
