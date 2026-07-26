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
- IDs, Namespaces und Versionsregeln;
- SQL-Purpose-Pflicht;
- Supporting Components mit SQL-Bezug;
- keine `.github/workflows`-Dateien.

### 2.2 Contract Validation

Prüft:

- SQL Lab Request;
- `SqlPurpose`;
- Package;
- Environment Blueprint;
- Primary SQL Component;
- Supporting Component;
- Deployment Unit;
- DataSet;
- Workflow;
- Runtime Binding;
- Provider Capability;
- Bound Plan;
- Run State;
- Event und Evidence.

Contract Tests verwenden ausschließlich synthetische Fixtures.

### 2.3 Planner Validation

Read-only Prüfung:

- Package- und Extensionauflösung;
- SQL-Purpose-Validierung;
- Component Expansion;
- Providerauswahl;
- Capability Negotiation;
- Port-, Pfad-, Media- und Secret Requirements;
- Ressourcenbudget und Hostreserve;
- Side Effects;
- Cleanup- und Compensation-Plan;
- Plan-Hash.

Planner Tests dürfen keine Container, VMs, Netzwerke, Volumes oder Dateien außerhalb temporärer Testverzeichnisse erzeugen.

### 2.4 Synthetic Provider Tests

Provideroperationen werden gegen synthetische In-Memory- oder Fixture-Backends geprüft:

- Resource Graph;
- tatsächliche Objekt-ID-Rückgabe;
- Stateübergänge;
- Stop/Start;
- Reset;
- Destroy;
- Fremdobjektschutz;
- Recovery nach Teilfehler.

Ein grüner Synthetic Test ist kein echter Docker-, Podman- oder Hyper-V-Nachweis.

### 2.5 Native Runtime Tests

Getrennte lokale Nachweise:

- Docker Engine;
- Podman;
- Hyper-V;
- SQL Server 2019;
- SQL Server 2022;
- SQL Server 2025;
- Windows- und Linux-Gastpfade, soweit erforderlich.

Jeder Native Test dokumentiert:

- Hostklasse und Provider;
- Produktversionen;
- Contract- und Package-Versionen;
- SQL Purpose;
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
./Tests/Invoke-LocalValidation.ps1 -Scope AllLocal
```

Diese Befehle sind geplant und erst nach Implementierung als ausführbar zu dokumentieren.

## 4. Provider-Abnahmematrix

| Fähigkeit | Docker | Podman | Hyper-V |
|---|---:|---:|---:|
| read-only Preflight | erforderlich | erforderlich | erforderlich |
| Plan ohne Mutation | erforderlich | erforderlich | erforderlich |
| einzelne SQL-Instanz | erforderlich | erforderlich | erforderlich |
| SQL 2019/2022/2025 | erforderlich | erforderlich | erforderlich |
| tatsächliche Objekt-IDs | erforderlich | erforderlich | erforderlich |
| Health plus SQL Readiness | erforderlich | erforderlich | erforderlich |
| Stop/Start | erforderlich | erforderlich | erforderlich |
| Reset | erforderlich, scopeabhängig | erforderlich, scopeabhängig | erforderlich, imageabhängig |
| Down/Destroy | erforderlich | erforderlich | erforderlich |
| fremde Ressourcen geschützt | erforderlich | erforderlich | erforderlich |
| Supporting Components | capabilityabhängig | capabilityabhängig | capabilityabhängig |

Eine Providerabnahme gilt nicht automatisch für einen anderen Provider.

## 5. SQL-Server-Abnahmeszenarien

### P0

1. `QUICK_ENVIRONMENT` mit SQL Server 2022;
2. SQL Server 2019, 2022 und 2025 einzeln;
3. Multi-Version-Quick-Environment;
4. markierte synthetische Datenbank;
5. DataSet-Erzeugung und Verifikation;
6. Packageinstallation;
7. Stop, Start, Reset und Destroy;
8. Privacy- und Secret-Gate.

### P1

1. Performance-Schulungs-Pilotdemo;
2. Analyze-Pilot mit Finding-Assertion;
3. Multi-Session-Blocking;
4. kontrollierter CPU-, Memory-, TempDB- oder I/O-Druck;
5. Domain-Controller-Supporting-Component;
6. Windows Authentication oder Kerberos;
7. Netzwerkfault mit verifizierter Rücknahme.

### P2

1. Availability Group;
2. FCI;
3. Replication oder Log Shipping;
4. PolyBase mit Hadoop;
5. REST-/HTTP-Supporting-Component;
6. verteilte Hyper-V-/Container-Topologie.

## 6. Ergebnisstatus

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

`PASS` ist nur zulässig, wenn erforderliches Cleanup erfolgreich war.

## 7. Privacy-Validierung

Vor Datei-, Package-, Git- oder Exportoperationen werden geprüft:

- Personen-, Firmen-, Kunden- und Organisationsbezüge;
- Hostnamen, IP-Adressen, Endpunkte und Pfade;
- Secrets und Connection Strings;
- reale Datenbank- und Objektstrukturen;
- Logs, Plans, Responses und Screenshots;
- Office- und Dateimetadaten;
- lokale State-, Artifact-, Cache- und Secretpfade;
- unerwartete Binärdateien und Archive.

Prüfergebnisse enthalten Regelcode, Pfad und Trefferanzahl, aber keine Fundwerte.

## 8. Destructive-Safety-Tests

Verbindliche Negativtests:

- Name passt, Owner Marker fehlt;
- Owner Marker passt, tatsächliche Objekt-ID weicht ab;
- Pfad liegt außerhalb des registrierten Roots;
- symbolischer Link oder Junction verlässt den Scope;
- fremder Container oder fremde VM mit ähnlichem Namen;
- unerwartetes Netzwerk oder Volume;
- unterbrochener Übergang vor Statepersistenz;
- Cleanupteilfehler;
- wiederholter Destroy-Aufruf;
- `-WhatIf` verändert nichts.

## 9. Ressourcen- und Lasttests

- Hostreserve wird vor Start geprüft.
- Sequenzieller Start ist Standard.
- Stress benötigt positive Zeit- und Ressourcenobergrenzen.
- Abbruchsignal und Cleanup laufen unabhängig vom fachlichen Ergebnis.
- absolute Laufzeitwerte werden nicht provider- oder hostübergreifend als Produktgarantie verwendet.
- SQL-Server-`max server memory`, VM-/Containerlimit und Hostreserve werden getrennt geprüft.

## 10. Dokumentationsprüfung

- alle Links auf vorhandene Pfade;
- Status `DRAFT`, `PLANNED`, `IMPLEMENTED` oder `VALIDATED` korrekt;
- geplante Commands nicht als vorhanden darstellen;
- SQL Server als Hauptzweck;
- Supporting Components nur mit SQL-Bezug;
- Providerunterschiede und Grenzen dokumentiert;
- Lizenz- und Privacy-Hinweise sichtbar;
- Einsteigerpfad und technische Vertiefung getrennt verständlich.

## 11. Evidence-Regel

Native Runtime Evidence wird zunächst lokal gehalten. Versioniert werden dürfen nur privacy-geprüfte Summaries mit:

- Contract- und Package-Version;
- synthetischer Scenario-ID;
- Providerklasse;
- SQL-Server-Major-Version;
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
- Querytexte, Plans, Logs oder Responses ohne separate Sanitization.

## 12. Externes Validation-Repository

Ein späteres separates Repository darf:

- das Lab installieren oder beziehen;
- öffentliche Commands aufrufen;
- Packages auswählen;
- Plans und Events verarbeiten;
- Matrixläufe koordinieren;
- sanitisierte Summaries sammeln.

Es darf nicht:

- Provider- oder Package-Core duplizieren;
- private Runtime States importieren;
- Secrets als Workflowinput versionieren;
- CI-spezifische Anforderungen in die Produktcontracts zurückdrücken.

## 13. Abnahmekriterien

- alle Prüfungen sind lokal ausführbar;
- CI/CD ist keine Produktvoraussetzung;
- Static, Contract, Planner, Synthetic und Runtime sind getrennt;
- Docker, Podman und Hyper-V besitzen eigene Native Nachweise;
- SQL 2019, 2022 und 2025 werden getrennt erkannt;
- Safety- und Privacy-Negativtests existieren;
- Supporting Components werden erst nach SQL-Core-Abnahme getestet;
- Cleanup ist Teil jedes Erfolgsvertrags;
- ein späterer externer Validator kann öffentliche Contracts nutzen.
