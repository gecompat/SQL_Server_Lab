# Lokale Validierungsstrategie ohne CI/CD

| Merkmal | Wert |
|---|---|
| Status | `REQUIRED` |
| Stand | 2026-07-26 |
| CI/CD | nicht Bestandteil dieses Repositorys |
| Ziel | alle Qualitätsprüfungen lokal reproduzierbar ausführbar |

## 1. Entscheidung

`SQL_Server_Lab` enthält keine GitHub-Actions-, Runner- oder CI/CD-Produktlogik.

Alle Produkt- und Vertragsprüfungen werden als lokal ausführbare Tools und Tests bereitgestellt. Ein späteres getrenntes Validation-Repository darf diese öffentlichen Befehle aufrufen, ohne hier Provider-, Package- oder Workflowlogik zu duplizieren.

## 2. Prüfungsebenen

### 2.1 Static Validation

Prüft ohne Runtime:

- JSON-Schemas und Beispielmanifeste;
- PowerShell-Syntax;
- PSScriptAnalyzer-Regeln;
- verbotene Pfade und Dateitypen;
- Secrets und Privacy-Muster;
- Dokumentationslinks;
- Package-Hashes;
- IDs, Namespaces und Vertragsversionen;
- SQL-Purpose-Pflicht;
- keine festen Produktjahres-Enums in Core-Schemas;
- SQL-Versionseinträge und Statuswerte;
- Supporting Components mit SQL-Bezug;
- Database-Artifact-Klassifikationen;
- keine `.github/workflows`-Dateien.

### 2.2 Contract Validation

Prüft:

- SQL Lab Request;
- `SqlPurpose`;
- SQL Version Catalog;
- Package;
- Environment Blueprint;
- Primary SQL Component;
- Supporting Component;
- Deployment Unit;
- DataSet;
- Database Artifact;
- Public Sample Entry;
- Resource Assessment;
- Cleanup Plan;
- Workflow;
- Runtime Binding;
- Provider Capability;
- Bound Plan;
- Run State und Recovery State;
- Event und Evidence.

Contract Tests verwenden ausschließlich synthetische Fixtures oder kleine öffentliche Testfixtures mit dokumentierter Herkunft.

### 2.3 Planner Validation

Read-only Prüfung:

- Package- und Extensionauflösung;
- SQL-Purpose-Validierung;
- Versionseintrag und Version Constraint;
- Component Expansion;
- Providerauswahl;
- Capability Negotiation;
- Port-, Pfad-, Media-, Artifact- und Secret Requirements;
- CPU-, RAM-, Storage- und Provider-Overhead;
- Hostreserve und Resource Assessment;
- zulässige und unzulässige Overrides;
- Side Effects;
- vollständiger Cleanup- und Compensation-Plan;
- Plan-Hash.

Planner Tests dürfen keine Container, VMs, Netzwerke, Volumes oder Dateien außerhalb temporärer Testverzeichnisse erzeugen.

### 2.4 Synthetic Provider Tests

Provideroperationen werden gegen synthetische In-Memory- oder Fixture-Backends geprüft:

- Resource Graph;
- Resource Assessment;
- tatsächliche Objekt-ID-Rückgabe;
- Stateübergänge;
- Stop/Start;
- Reset;
- Destroy;
- Fremdobjektschutz;
- automatische Compensation nach Teilfehler;
- wiederholtes `ResumeCleanup`;
- Recovery nach Prozessabbruch.

Ein grüner Synthetic Test ist kein echter Docker-, Podman- oder Hyper-V-Nachweis.

### 2.5 Native Runtime Tests

Getrennte lokale Nachweise:

- Docker Engine;
- Podman;
- Hyper-V;
- derzeit SQL Server 2019;
- derzeit SQL Server 2022;
- derzeit SQL Server 2025;
- Windows- und Linux-Gastpfade, soweit erforderlich.

Die Versionsmatrix wird aus dem SQL Version Catalog erzeugt. Neue `SUPPORTED`-Einträge erscheinen dadurch ohne Änderung des Testharness in der aktiven Matrix. `DEPRECATED`, `RETIRED` und `BLOCKED` werden gemäß ihrer Policy behandelt.

Jeder Native Test dokumentiert:

- Hostklasse und Provider;
- Produkt- und Katalogversionen;
- Contract- und Package-Versionen;
- SQL Purpose;
- Resource Assessment und gegebenenfalls Overcommit-Bestätigung;
- ausgeführte Schritte;
- Statuscodes;
- Cleanupstatus;
- Aussagegrenzen.

Reale Host- oder Umgebungswerte werden nicht in versionierte Evidence übernommen.

## 3. Vorgesehener lokaler Einstieg

Geplant:

```powershell
./Tests/Invoke-LocalValidation.ps1
```

Vorgesehene Modi:

```powershell
./Tests/Invoke-LocalValidation.ps1 -Scope Static
./Tests/Invoke-LocalValidation.ps1 -Scope Contract
./Tests/Invoke-LocalValidation.ps1 -Scope Planner
./Tests/Invoke-LocalValidation.ps1 -Scope Synthetic
./Tests/Invoke-LocalValidation.ps1 -Scope Runtime -Provider Docker
./Tests/Invoke-LocalValidation.ps1 -Scope Runtime -Provider Podman
./Tests/Invoke-LocalValidation.ps1 -Scope Runtime -Provider HyperV
./Tests/Invoke-LocalValidation.ps1 -Scope Artifact
./Tests/Invoke-LocalValidation.ps1 -Scope Recovery
./Tests/Invoke-LocalValidation.ps1 -Scope AllLocal
```

Diese Befehle sind geplant und erst nach Implementierung als ausführbar zu dokumentieren.

## 4. Provider-Abnahmematrix

| Fähigkeit | Docker | Podman | Hyper-V |
|---|---:|---:|---:|
| read-only Preflight | erforderlich | erforderlich | erforderlich |
| Resource Assessment | erforderlich | erforderlich | erforderlich |
| Plan ohne Mutation | erforderlich | erforderlich | erforderlich |
| einzelne SQL-Instanz | erforderlich | erforderlich | erforderlich |
| aktive SQL-Versionseinträge | kataloggetrieben | kataloggetrieben | kataloggetrieben |
| tatsächliche Objekt-IDs | erforderlich | erforderlich | erforderlich |
| Health plus SQL Readiness | erforderlich | erforderlich | erforderlich |
| Stop/Start | erforderlich | erforderlich | erforderlich |
| Reset | erforderlich, scopeabhängig | erforderlich, scopeabhängig | erforderlich, imageabhängig |
| Down/Destroy | erforderlich | erforderlich | erforderlich |
| `ResumeCleanup` | erforderlich | erforderlich | erforderlich |
| fremde Ressourcen geschützt | erforderlich | erforderlich | erforderlich |
| Supporting Components | capabilityabhängig | capabilityabhängig | capabilityabhängig |

Eine Providerabnahme gilt nicht automatisch für einen anderen Provider.

## 5. SQL-Server-Abnahmeszenarien

### P0

1. `QUICK_ENVIRONMENT` mit einem aktiven Standard-Versionseintrag;
2. derzeit SQL Server 2019, 2022 und 2025 einzeln;
3. Multi-Version-Quick-Environment;
4. zusätzlicher synthetischer künftiger Versionseintrag lässt sich ohne Schemaänderung planen;
5. `RETIRED`- oder `BLOCKED`-Version wird strukturiert abgelehnt;
6. markierte synthetische Datenbank;
7. DataSet-Erzeugung und Verifikation;
8. Packageinstallation;
9. Stop, Start, Reset und Destroy;
10. Privacy- und Secret-Gate.

### P1

1. Restore eines im Lab erzeugten Backups in einem Folgerun;
2. Restore mindestens einer öffentlichen Demo-Datenbank;
3. lokales Nicht-Produktionsbackup mit vollständiger Klassifikation;
4. Produktions- und unbekanntes Backup werden blockiert;
5. Restore-Speicherbedarf berücksichtigt wiederhergestellte Dateigrößen;
6. Performance-Schulungs-Pilotdemo;
7. Analyze-Pilot mit Finding-Assertion;
8. Multi-Session-Blocking;
9. kontrollierter CPU-, Memory-, TempDB- oder I/O-Druck;
10. Domain-Controller-Supporting-Component;
11. Windows Authentication oder Kerberos;
12. Netzwerkfault mit verifizierter Rücknahme.

### P2

1. Availability Group;
2. FCI;
3. Replication oder Log Shipping;
4. PolyBase mit Hadoop;
5. REST-/HTTP-Supporting-Component;
6. verteilte Hyper-V-/Container-Topologie.

## 6. Resource-Assessment-Tests

Verbindlich:

- genügend CPU, RAM und Storage ergibt `RESOURCE_OK`;
- knappe Reserve ergibt `RESOURCE_WARNING`;
- vorhergesagtes Defizit ergibt `RESOURCE_INSUFFICIENT_OVERRIDABLE`;
- expliziter Overcommit startet den Run, ohne den Defizitstatus zu verbergen;
- fehlende Overcommit-Bestätigung verhindert nur den mutierenden Start, nicht Planung und Anzeige;
- sichere absolute Limits bleiben nicht übersteuerbar;
- unsicherer Pfad, fehlende Providerfähigkeit, blockierte SQL-Version oder fehlender Cleanup Plan ergibt `RESOURCE_HARD_BLOCK`;
- Storage Assessment berücksichtigt Download, Cache, Entpacken, Images/VHDX, Data, Log, TempDB, Backup und Restore-Peak;
- CPU, RAM, Storage und Hostreserve werden getrennt ausgewiesen;
- Schätzqualität und unbekannte Werte bleiben sichtbar.

## 7. Artifact- und Restore-Tests

Verbindlich:

- `LAB_GENERATED` kann erstellt, gehasht, lokal gespeichert und später wiederhergestellt werden;
- `PUBLIC_SAMPLE` benötigt Quelle, Lizenz, Hash und Versionskompatibilität;
- `USER_PROVIDED_NON_PRODUCTION` bleibt lokal und benötigt ausdrückliche Klassifikation;
- `PRODUCTION_DATA` und `UNKNOWN` werden abgelehnt;
- lokale Backups werden nicht automatisch in Git-, Evidence- oder Downloadartefakte übernommen;
- Backupmetadaten, File Mapping, Zielpfade und Konfliktpolicy werden vor Restore geprüft;
- Restore-Verifikation und Cleanup sind Pflicht;
- Cache- und Backup-Retention sind unabhängig von der wiederhergestellten Datenbank steuerbar.

## 8. Recovery- und Destructive-Safety-Tests

Verbindliche Negativ- und Recovery-Tests:

- Name passt, Owner Marker fehlt;
- Owner Marker passt, tatsächliche Objekt-ID weicht ab;
- Pfad liegt außerhalb des registrierten Roots;
- symbolischer Link oder Junction verlässt den Scope;
- fremder Container oder fremde VM mit ähnlichem Namen;
- unerwartetes Netzwerk oder Volume;
- Prozessabbruch nach erster Mutation;
- Host- oder Providerfehler während Provisionierung;
- Restore schlägt nach Anlage der Zieldatenbank fehl;
- Setupschritt schlägt nach mehreren erfolgreichen Ressourcen fehl;
- Cleanupteilfehler;
- wiederholtes `ResumeCleanup`;
- wiederholter Destroy-Aufruf;
- `-WhatIf` verändert nichts.

Erwartung:

- State existiert vor der ersten Mutation;
- tatsächliche IDs werden fortlaufend registriert;
- automatische Compensation läuft in umgekehrter Abhängigkeitsreihenfolge;
- unvollständige Bereinigung ergibt `RECOVERY_REQUIRED`;
- erneuter Cleanup führt nur offene Schritte aus;
- fremde Ressourcen bleiben unangetastet.

## 9. Ergebnisstatus

```text
PASS
WARN
SKIP_OPTIONAL
NOT_EXECUTED
UNSUPPORTED
FAIL
RECOVERY_REQUIRED
```

Priorität:

```text
RECOVERY_REQUIRED > FAIL > NOT_EXECUTED_REQUIRED > WARN > SKIP_OPTIONAL > PASS
```

`PASS` ist nur zulässig, wenn erforderliches Cleanup erfolgreich war oder ein ausdrücklich persistenter Endzustand erreicht wurde.

## 10. Privacy-Validierung

Vor Datei-, Package-, Git- oder Exportoperationen werden geprüft:

- Personen-, Firmen-, Kunden- und Organisationsbezüge;
- Hostnamen, IP-Adressen, Endpunkte und Pfade;
- Secrets und Connection Strings;
- reale Datenbank- und Objektstrukturen aus Produktivsystemen;
- Produktions- und unbekannte Backups;
- Logs, Plans, Responses und Screenshots;
- Office- und Dateimetadaten;
- lokale State-, Artifact-, Cache- und Secretpfade;
- unerwartete Binärdateien und Archive.

Prüfergebnisse enthalten Regelcode, Pfad und Trefferanzahl, aber keine Fundwerte.

## 11. Dokumentationsprüfung

- alle Links zeigen auf vorhandene Pfade;
- Status `DRAFT`, `PLANNED`, `IMPLEMENTED` oder `VALIDATED` ist korrekt;
- geplante Commands werden nicht als vorhanden dargestellt;
- SQL Server bleibt Hauptzweck;
- Versionslisten sind als aktueller Katalogstand und nicht als permanente Grenze formuliert;
- Supporting Components erscheinen nur mit SQL-Bezug;
- zulässige und unzulässige Database Artifacts sind getrennt;
- Resource Override und nicht übersteuerbare Blocker sind dokumentiert;
- Providerunterschiede und Grenzen sind dokumentiert;
- Lizenz- und Privacy-Hinweise sind sichtbar;
- Einsteigerpfad und technische Vertiefung sind getrennt verständlich.

## 12. Evidence-Regel

Native Runtime Evidence wird zunächst lokal gehalten. Versioniert werden dürfen nur privacy-geprüfte Summaries mit:

- Contract-, Package- und SQL-Versionseintrag;
- synthetischer Scenario-ID;
- Providerklasse;
- SQL-Server-Major-Version;
- Resource-Assessment-Status ohne lokale Kapazitätswerte;
- Statuscodes;
- Assertionsergebnis;
- Cleanupstatus;
- Aussagegrenzen.

Nicht versioniert werden:

- reale Hostnamen;
- lokale Pfade;
- Objekt-IDs;
- Endpunkte;
- Credentials;
- lokale Backupinhalte;
- Querytexte, Plans, Logs oder Responses ohne separate Sanitization.

## 13. Abnahmekriterien

- alle Prüfungen sind lokal ausführbar;
- CI/CD ist keine Produktvoraussetzung;
- Static, Contract, Planner, Synthetic und Runtime sind getrennt;
- Docker, Podman und Hyper-V besitzen eigene Native Nachweise;
- aktive SQL-Versionen werden kataloggetrieben getestet;
- derzeitige Versionseinträge 2019, 2022 und 2025 werden getrennt erkannt;
- neue oder ausgesteuerte Versionen erfordern keine Harnessänderung;
- Lab-Backups und öffentliche Demo-Datenbanken besitzen positive Tests;
- Produktions- und unbekannte Backups besitzen Negativtests;
- Resource Overcommit und nicht übersteuerbare Blocker sind getestet;
- Safety- und Privacy-Negativtests existieren;
- Cleanup und Recovery sind Teil jedes Erfolgsvertrags;
- ein späterer externer Validator kann öffentliche Contracts nutzen.
