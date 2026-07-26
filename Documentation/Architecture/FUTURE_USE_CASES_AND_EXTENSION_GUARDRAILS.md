# Zukünftige SQL-Server-Anwendungsfälle und Erweiterungsleitplanken

| Merkmal | Wert |
|---|---|
| Status | `ARCHITECTURE_TEST_CATALOG` |
| Stand | 2026-07-26 |
| Hauptzweck | SQL-Server-Labs |
| Zweck | Sicherstellen, dass frühe Schnittstellen spätere SQL-Server-Szenarien nicht blockieren |
| Maßgebliche Scope-Entscheidung | [SQL-Server-zentrierte Scope-Entscheidung](./SQL_SERVER_CENTRIC_SCOPE_DECISION.md) |

## 1. Einordnung

Dieses Dokument ist kein Versprechen, alle genannten Funktionen kurzfristig zu implementieren. Die Anwendungsfälle dienen als Architekturtests für ein SQL-Server-Lab.

Zusätzliche Technologien sind nur dann relevant, wenn sie eine SQL-Server-Konstellation ermöglichen, beeinflussen oder beobachtbar machen. Es entsteht kein allgemeines Hadoop-, REST-, Active-Directory-, Kubernetes- oder Multi-Purpose-Lab.

## 2. Zentrale SQL-Server-Anwendungsfälle

### 2.1 Quick Environment

- SQL Server 2019, 2022 oder 2025;
- eine oder mehrere Versionen;
- Linux-Container über Docker oder Podman;
- Windows- oder Linux-VM über Hyper-V;
- auswählbare CPU-, RAM- und Storageprofile;
- persistente oder temporäre Daten;
- sichere lokale Zugangsdaten;
- optionale Installation eines Projektpakets;
- Connection Summary ohne Passwort;
- Start, Stop, Reset, Down und Destroy.

**Architekturfolge:** Der einfache Menüpfad verwendet denselben Package-, State-, Provider- und Cleanup-Core wie komplexe Szenarien.

### 2.2 Performance-Schulungsdemo

- deterministische synthetische Daten;
- Baseline;
- kontrollierter Effekt;
- Observation;
- Gegenmaßnahme;
- Vorher-/Nachher-Vergleich;
- mehrere Sessions;
- definierte CPU-, RAM-, I/O- und Laufzeitgrenzen;
- Cleanup.

**Architekturfolge:** DataSet, Workload, Probe und Assertion sind getrennte Verträge.

### 2.3 Diagnose- und Analyze-Szenario

- Frameworkinstallation;
- gezielte Blocking-, Wait-, TempDB-, Log-, I/O-, Query-Store- oder Extended-Events-Konstellation;
- Analyzer-Aufrufe;
- erwartete Finding-, Status- und Resultset-Codes;
- alternative Evidenz bei fehlender Capability;
- lokaler technischer Evidence-Scope;
- vollständiges Cleanup.

**Architekturfolge:** Das Analyze-Repository besitzt fachliche Assertions; das Lab besitzt Provider, Faults und Lifecycle.

## 3. SQL-Server-Topologien

### 3.1 Mehrere unabhängige Instanzen

- verschiedene SQL-Versionen;
- verschiedene Betriebssysteme;
- unterschiedliche Collations oder Compatibility Levels;
- Client- oder Workloadvergleich;
- Upgrade- und Migrationstests.

### 3.2 Availability Groups

- primäre und sekundäre SQL-Knoten;
- Listener;
- Synchronisations- und Failovermodi;
- optional Domain Controller, DNS und Witness;
- Netzwerkprofile;
- Readable Secondary und Backuppräferenzen;
- kontrollierter Failover und Recovery.

### 3.3 Failover Cluster Instance

- mehrere Windows-Knoten;
- Domain/DNS;
- Shared Storage oder geeignete Labemulation;
- Cluster- und SQL-Rollen;
- Dienst- und Storage-Faults;
- sauberer Resetpfad.

### 3.4 Replication und Log Shipping

- Publisher, Distributor, Subscriber;
- Primary und Secondary;
- Backup-, Copy- und Restorepfade;
- Latenz- und Unterbrechungsszenarien;
- Rollenbezogene DataSets und Assertions.

**Architekturfolge:** Komplexe SQL-Topologien werden als Composite SQL Components expandiert.

## 4. SQL-Server-Security und Identity

### 4.1 Domain Controller und DNS

Gültige SQL-Zwecke:

- Windows Authentication;
- Service Accounts;
- Kerberos und SPNs;
- Gruppenbasierte Berechtigungen;
- WSFC, AG und FCI;
- constrained delegation oder double-hop-bezogene Tests;
- Zertifikats- und TLS-Szenarien.

Nicht Ziel:

- allgemeines Active-Directory-Schulungslab ohne SQL Server.

### 4.2 Zertifikate und Secrets

- TDE- oder Backupverschlüsselungs-Testschritte;
- TLS-Verbindungen;
- Zertifikatserneuerung in wegwerfbaren Labs;
- Secret Rotation für synthetische Accounts;
- Berechtigungs- und Negativtests.

**Architekturfolge:** Identity-, Certificate- und Secret-Bindings bleiben typisiert und lokal.

## 5. SQL-Server-Integration mit Hadoop oder verteilten Datenplattformen

### 5.1 PolyBase

Mögliche Komponenten:

- SQL Server mit PolyBase-Capability;
- Hadoop-Cluster oder andere unterstützte externe Datenquelle;
- synthetische Daten im externen System;
- External Data Source, File Format und External Table;
- Query, Performance- und Fehlertests;
- Netzwerk- und Authentifizierungsvarianten;
- Cleanup beider Seiten.

**Architekturfolge:** `hadoop.cluster` ist Supporting Component. Der Packagezweck bleibt `INTEGRATION_SCENARIO` für SQL Server.

### 5.2 Weitere Datenplattformen

Zulässig, wenn sie:

- SQL-Server-Datenquelle oder -ziel sind;
- ETL-, Replikations-, Linked-Server- oder PolyBase-Verhalten ermöglichen;
- als Vergleichssystem eines SQL-Server-Tests dienen.

Nicht Ziel ist die allgemeine Verwaltung dieser Plattform.

## 6. SQL Server und REST-/HTTP-Dienste

Gültige Szenarien:

- API als SQL-Server-Client;
- API mit Connection Pooling, Retry und Transaktionsverhalten;
- REST-Datenquelle oder -ziel;
- Mock-Service für reproduzierbare SQL-Integrationsfälle;
- HTTP-Workload zur Erzeugung bestimmter SQL-Abfragemuster;
- Responseprüfung gemeinsam mit SQL-Evidenz.

**Architekturfolge:** Der API-Endpunkt ist Supporting Component oder externer Testendpoint mit expliziter Network Policy. Ein allgemeines API-Testframework ist kein Ziel.

## 7. Client- und Workload-Komponenten

Mögliche SQL-bezogene Clients:

- `sqlcmd`;
- PowerShell;
- .NET;
- Java/JDBC;
- Python;
- ODBC;
- ORM-Testclient;
- SSIS oder ETL-Driver;
- kontrollierter Multi-Session-Load Generator.

Szenarien:

- Connection Pooling;
- Retry;
- Parameter Sniffing;
- Transaktionsgrenzen;
- Blocking und Deadlocks;
- Batch- und RPC-Unterschiede;
- Application Name und Toolfilter;
- Treiber- und TLS-Verhalten.

**Architekturfolge:** Der Client konsumiert typisierte SQL Endpoint- und Credential-Reference-Bindings.

## 8. Storage- und I/O-Szenarien

- getrennte Data-, Log-, TempDB- und Backup-Rollen;
- verschiedene virtuelle Datenträger;
- IOPS- und Durchsatzgrenzen;
- kontrollierte Latenz;
- Disk-Full auf einem hart begrenzten Fault Target;
- Autogrowth und Filelayout;
- Backup- und Restorepfade;
- Container-Volumes gegenüber Hyper-V-VHDX;
- Docker-Desktop-Grenzen gegenüber nativer Linux-Engine.

**Architekturfolge:** Storage Claims sind logisch. Reale Pfade und Geräte werden erst lokal gebunden.

## 9. Netzwerk- und Availability-Szenarien

- Latenz, Jitter, Bandbreite und Paketverlust;
- gerichtete Fehler zwischen SQL-Knoten oder Client und SQL Server;
- Listener- und DNS-Verhalten;
- Timeout und Retry;
- AG-Synchronisation;
- Log Shipping oder Replication bei unterbrochener Verbindung;
- Toxiproxy-, `tc/netem`- oder Hyper-V-bezogene Fault Handler.

**Architekturfolge:** Faults sind eigene typisierte Actions mit Dauer, Status, Rücknahme und Verifikation.

## 10. Observability und zusätzliche Evidenz

- SQL-DMVs und Kataloge;
- Query Store;
- Extended Events;
- Execution Plans;
- SQL Error Log;
- Windows Performance Counter;
- Linux- und Containerressourcen;
- Netzwerk- und Storage-Metriken;
- externe Collector als Supporting Components.

**Architekturfolge:** Probes sind nicht auf T-SQL beschränkt, aber ihre Verwendung muss dem SQL-Szenario dienen. Rohdaten und sanitisierte Summary bleiben getrennt.

## 11. Persistenz- und Wiederverwendungsmodelle

- vollständig ephemerer Run;
- persistente Quick Environment;
- wiederverwendbares Base Image;
- Differencing Disk;
- resetbare SQL-Projektdatenbank;
- mehrere sequenzielle Szenarien auf validierter Basis;
- Lease für eine reservierte SQL-Testumgebung;
- getrennte Image-, Package- und Runtime-Caches.

**Architekturfolge:** Persistence, Ownership und Reset werden getrennt vom fachlichen SQL-Szenario modelliert.

## 12. Externe Steuerung

Mögliche spätere Konsumenten:

- PowerShell CLI;
- lokales Menü;
- REST API;
- Desktop- oder Web-UI;
- getrenntes Validation-Repository;
- Schulungssteuerung;
- Testkatalog oder Scheduler.

**Architekturfolge:** Commands, Plans, Operations, Events und Results sind serialisierbar. Die Control Plane ändert nicht den SQL-Package-Vertrag.

## 13. Erweiterungsleitplanken

### 13.1 SQL Purpose ist Pflicht

Jedes ausführbare Package deklariert:

- SQL-Zweck;
- primäre SQL-Komponenten;
- Zielversionen und Capabilities;
- Supporting Components mit SQL-Begründung;
- erwartete SQL-Evidenz.

### 13.2 Keine unabhängigen Nicht-SQL-Packages

Unzulässig:

- allgemeines Hadoop-Lab;
- allgemeines REST-Testframework;
- allgemeines Active-Directory-Lab;
- allgemeines Kubernetes-Lab;
- allgemeine Clusterplattform ohne SQL-Server-Bezug.

### 13.3 Namespaced Supporting Types

Supporting Types bleiben möglich:

```text
identity.*
hadoop.*
http.*
client.*
observability.*
fault.*
```

Sie werden nur für konkrete SQL-Packages implementiert.

### 13.4 Keine stille Fallback-Simulation

Fehlt eine Capability, ist nur zulässig:

- `NOT_EXECUTED`;
- `UNSUPPORTED`;
- ausdrücklich definierte `EMULATED`-Alternative;
- `FIXTURE` mit klarer Aussagegrenze.

### 13.5 Providergleichrangigkeit

Hyper-V, Docker und Podman bleiben Kernprovider. Supporting Components dürfen den gemeinsamen Contract nicht einseitig auf nur einen Provider verengen, außer das SQL-Szenario erfordert nachweislich eine spezifische Plattform.

## 14. Architekturtests vor `1.0`

### Test A – Docker SQL Quick Environment

- `mssql.instance`;
- SQL Server 2022;
- Resource Profile;
- Bindings;
- Lifecycle und Destroy.

### Test B – Podman-Parität

- derselbe logische SQL-Contract;
- eigener Capability-Nachweis;
- dokumentierte Providerabweichungen.

### Test C – Hyper-V SQL Server

- Windows- oder Linux-VM;
- Image-/Media-Binding;
- SQL Readiness;
- State und Reset.

### Test D – Performance Demo

- DataSet;
- Multi-Step-Workflow;
- Workload;
- Probe;
- Assertion;
- Cleanup.

### Test E – Analyze Szenario

- Frameworkinstallation;
- synthetischer Problemzustand;
- Analyzer-Probe;
- Finding-Assertion.

### Test F – Supporting Component Domain Controller

- SQL Server plus Domain Controller;
- Windows Authentication oder Kerberos;
- vollständiger Cleanup.

### Test G – Spätere SQL-Integration

Mindestens ein konkreter SQL-Integrationsproof, beispielsweise:

- SQL Server plus Hadoop für PolyBase; oder
- SQL Server plus REST-Mock-Service.

## 15. Bewusst vertagte Entscheidungen

Nicht vor konkretem SQL-Bedarf festschreiben:

- Hadoop-Distribution;
- allgemeiner Clusterprovider;
- Kubernetes;
- Cloudprovider;
- zentrale Schedulerarchitektur;
- REST-Control-Plane-Authentifizierung;
- Remote-Agent-Protokoll.

## 16. Abnahmekriterium für Zukunftsoffenheit

Eine neue Supporting Technology ist integrierbar, wenn sie durch:

1. Supporting Component Type;
2. gegebenenfalls Composite Expander;
3. Action Types;
4. SQL Server Lab Package;
5. Required Capabilities;
6. vorhandenes oder ergänztes Provider Mapping

modelliert werden kann, ohne den grundlegenden SQL-Purpose-, State-, Binding-, Event- oder Cleanup-Vertrag zu ändern.

Die Erweiterung ist nur zulässig, wenn sie einen konkreten SQL-Server-Anwendungsfall ermöglicht.
