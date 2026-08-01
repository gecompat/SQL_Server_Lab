# SQL Server Lab – Master-Umsetzungsplan

| Merkmal | Wert |
|---|---|
| Projekt | `SQL_Server_Lab` |
| Status | `PLANNING_BASELINE_WITH_STATUS_TRACKING` |
| Stand | 2026-08-01 |
| Umsetzungsstand | Abschnitt 17a; Runtime-Nachweis ausschließlich über `Documentation/Quality/KNOWN_LIMITATIONS.md` |
| Zielversion der Verträge | `0.1-draft` |
| Primärsprache | Deutsch; etablierte englische Fachbegriffe bleiben erhalten |
| CI/CD | ausdrücklich nicht Bestandteil dieses Repositories |
| Quellprojekte | `gecompat/SQL_Server_Analyze`, `gecompat/SQL_PerformanceSchulung` |

## 1. Architekturentscheidung

**ENTSCHEIDUNG:** Das gesamte generische SQL-Server-Lab-Thema wird in `SQL_Server_Lab` gebündelt. Die konsumierenden Projekte behalten ihre fachlichen Installations-, Demo-, Beobachtungs- und Erwartungsverträge, delegieren jedoch Infrastruktur, Lifecycle, Host-Preflight, Ressourcensteuerung, Topologieaufbau und Fault Injection an dieses Repository.

Damit werden drei heute getrennte Anforderungen unter einer gemeinsamen Architektur zusammengeführt:

1. **Quick Environment:** schnell eine isolierte SQL-Server-Umgebung bereitstellen;
2. **Project Scenario:** eine definierte fachliche Konstellation für ein konsumierendes Projekt reproduzierbar erzeugen;
3. **Custom Lab:** über Menü oder Manifest eine frei konfigurierbare synthetische Labortopologie aufbauen.

Die bestehende Funktionalität in `SQL_Server_Analyze/QuickStart`, `SQL_Server_Analyze/Lab/QuickTest` und `SQL_PerformanceSchulung/Infrastructure` wird nicht unkontrolliert kopiert. Sie wird inventarisiert, fachlich zusammengeführt, über gemeinsame Verträge neu geordnet und erst nach Abnahme schrittweise aus den Quellprojekten abgelöst.

## 2. Problemstellung

### 2.1 Aktuelle Überschneidung

`SQL_Server_Analyze` besitzt zwei getrennte Quick-Lab-Linien:

- `QuickStart/` mit starker Benutzerführung, Docker- und Hyper-V-Einstieg, Ressourcenprofilen, Storage-Layouts und Slow-I/O-Optionen;
- `Lab/QuickTest/` mit starkem Preflight-, Lifecycle-, Ownership-, State-, Secret- und Evidence-Vertrag sowie Docker-/Podman-Unterstützung.

Die Linien verfolgen ähnliche Ziele, verwenden aber unterschiedliche Zustandsmodelle, Verzeichnisse, Begriffe und Bedienoberflächen. Das erschwert Wartung, Dokumentation und Wiederverwendung.

`SQL_PerformanceSchulung` benötigt ebenfalls eine reproduzierbare Infrastruktur, besitzt aber bewusst fachliche Demo-Verträge, die nicht zu einer zweiten allgemeinen Provisionierungsplattform anwachsen sollen.

### 2.2 Zielkonflikt

Eine einfache QuickStart-Oberfläche darf nicht auf Kosten der Schutzmechanismen gehen. Umgekehrt darf ein belastbarer Lifecycle-Vertrag die Bedienung nicht unnötig kompliziert machen.

Die Zielarchitektur kombiniert daher:

- die einfache Menüführung und verständlichen Profile aus `QuickStart`;
- die read-only Preflight-, Run-ID-, Marker-, Full-ID-, Secret- und Cleanup-Grenzen aus `Lab/QuickTest`;
- die fachliche Demo-Struktur, Sicherheitsstufen und Messverträge aus `SQL_PerformanceSchulung`;
- eine projektneutrale Schnittstelle, über die weitere Repositories später denselben Lab-Core verwenden können.

## 3. Ziele

### 3.1 Funktionale Ziele

`SQL_Server_Lab` soll:

- SQL Server 2019, 2022 und 2025 einzeln oder in definierten Kombinationen bereitstellen;
- Docker und Podman über denselben Container-Core unterstützen;
- Hyper-V mit Windows- und Linux-Gästen unterstützen;
- eine verteilte Ausführung über getrennte Windows- und Linux-Hosts ermöglichen, ohne sie für den Standardbetrieb vorauszusetzen;
- Hostfähigkeiten read-only erfassen und nur passende Topologien anbieten;
- menügeführte und vollständig deklarative Ausführung bereitstellen;
- CPU-, RAM-, Storage-, Netzwerk- und SQL-Server-Ressourcenprofile trennen;
- sichere Fault-Injection-Profile für Netzwerk, I/O, CPU, Memory, TempDB, Transaction Log und kontrollierte Kapazitätsengpässe ermöglichen;
- projektbezogene Installations-, Demo-, Beobachtungs- und Validierungsabläufe über Project Adapter ausführen;
- alle mutierten Ressourcen mit Run-ID, Owner-Marker und tatsächlichen Objekt-IDs registrieren;
- nur den eigenen Scope verändern oder entfernen;
- lokale Verbindungsinformationen ohne Secrets verständlich ausgeben;
- schnelle Umgebungen ebenso wie mehrstufige Szenarien reproduzierbar zurücksetzen und bereinigen.

### 3.2 Qualitätsziele

- Alle versionierten Beispiele, Namen und Daten sind eindeutig synthetisch.
- Kein Secret gelangt in Repository, Konsolenausgabe, Manifest, generierte Konfiguration oder Evidenzzusammenfassung.
- Fehlende Plattformfähigkeiten werden sichtbar als `UNSUPPORTED` oder `NOT_EXECUTED` behandelt.
- Reproduzierbar ist der fachliche Zustand beziehungsweise Befund, nicht eine identische Laufzeit oder ein identischer Wait-Wert.
- Jede destruktive Aktion besitzt eine explizite Zielgrenze, Vorschau, Bestätigung und Recovery-Beschreibung.
- Die Bedienoberfläche und die maschinenlesbaren Verträge verwenden dieselben Begriffe und Statuscodes.
- Technische Dokumentation erklärt nicht nur die Bedienung, sondern auch Grenzen, Risiken, Ursache-Wirkungs-Zusammenhänge und Abnahmekriterien.

## 4. Nichtziele

Das Repository ist nicht:

- eine Produktionsbereitstellungsplattform;
- ein Benchmark mit maschinenübergreifend vergleichbaren absoluten Leistungswerten;
- ein Ersatz für Produkt-, Betriebssystem-, SQL-Server- oder Cloud-Lizenzen;
- ein Verteiler für Windows-, SQL-Server- oder sonstige Installationsmedien;
- ein Speicherort für reale Datenbanken, Backups, Logs, Pläne, Screenshots, Zertifikate oder Umgebungsinformationen;
- ein CI/CD-Repository;
- ein automatischer Produktions-Fault-Injection-Dienst;
- ein Tool, das fremde Container, VMs, Netzwerke, Volumes, Datenträger oder Dateien anhand bloßer Namen entfernt.

## 5. Nutzungsmodelle

### 5.1 Modus `QUICK`

Zielgruppe: Benutzer, die kurzfristig eine SQL-Server-Testinstanz benötigen.

Der Benutzer wählt über Menü oder Parameter:

- SQL-Server-Versionen;
- Docker, Podman oder Hyper-V;
- Windows oder Linux, soweit der Provider dies unterstützt;
- Ressourcenprofil;
- Ports;
- Persistenzmodus;
- Storage-Layout;
- optionale SQL-Server-Agent-Aktivierung;
- optionale Installation eines Project Adapters;
- optionale, klar begrenzte Netzwerk- oder I/O-Profile.

`QUICK` verwendet intern denselben Preflight-, State-, Ownership- und Cleanup-Core wie komplexe Szenarien. Es ist eine vereinfachte Bedienansicht, kein paralleles technisches System.

### 5.2 Modus `SCENARIO`

Zielgruppe: Analyse-, Schulungs-, Entwicklungs- und Reproduktionstests.

Ein versioniertes Szenariomanifest beschreibt:

- Zweck und Aussagegrenze;
- erforderliche Capabilities;
- unterstützte SQL-Server-Versionen;
- Topologie;
- Ressourcen- und Fault-Profile;
- `Arrange`, `Act`, `Observe`, `Assert`, `Cleanup`;
- Sicherheitsklasse;
- Timeouts und Abbruchsignale;
- erwartete Status- oder Finding-Verträge;
- zulässige Alternativ-Evidenz;
- Datenklassifikation.

### 5.3 Modus `CUSTOM`

Zielgruppe: Entwickler und Administratoren mit eigenständigem Testbedarf.

Der Benutzer stellt eine Topologie über Menü oder Manifest zusammen. `CUSTOM` darf nur Kombinationen erzeugen, die der Capability- und Sicherheitsvertrag des gewählten Providers unterstützt. Freie Konfiguration bedeutet nicht, Schutzgrenzen zu umgehen.

## 6. Zielarchitektur

### 6.1 Vertragsebenen

```text
Run Request
    ↓
Project Adapter
    ↓
Scenario
    ↓
Topology + Resource/Fault Profiles
    ↓
Provider Plan
    ↓
Docker | Podman | Hyper-V Windows | Hyper-V Linux | Distributed
    ↓
Local Run State + Sanitized Summary
```

#### Run Request

Beschreibt die konkrete Benutzeranforderung eines Laufs. Er enthält Referenzen auf Project Adapter, Szenario, Topologie, Providerpräferenz und zulässige Overrides. Secrets und reale Hostpfade sind nicht Bestandteil des versionierbaren Run Requests.

#### Project Adapter

Beschreibt die Kopplung zu einem konsumierenden Repository. Er kennt keine Providerdetails, sondern nur projektbezogene Entrypoints und Anforderungen.

#### Scenario

Beschreibt den fachlichen Zustand und dessen Ablauf. Es ist unabhängig davon, ob die Infrastruktur über Container oder VMs bereitgestellt wird, solange die erforderlichen Capabilities erfüllt sind.

#### Topology

Beschreibt Rollen, Nodes, Netzwerke, Storage-Rollen, SQL-Versionen und Beziehungen. Sie enthält keine realen Hostpfade, IP-Adressen oder Gerätekennungen.

#### Provider

Übersetzt die logische Topologie in konkrete Docker-, Podman- oder Hyper-V-Ressourcen und liefert tatsächliche Objekt-IDs an den Run-State zurück.

### 6.2 Kernkomponenten

| Komponente | Verantwortung |
|---|---|
| `Lab CLI` | einheitlicher Einstieg für interaktive und nicht interaktive Ausführung |
| `Planner` | validiert Run Request, Adapter, Szenario, Topologie und Host-Capabilities; erzeugt einen Mutationsplan |
| `Capability Resolver` | ermittelt read-only Host- und Providerfähigkeiten |
| `Lifecycle Engine` | steuert `Preflight`, `Plan`, `Up`, `Run`, `Observe`, `Validate`, `Status`, `Stop`, `Start`, `Reset`, `Down`, `Destroy` |
| `State Store` | hält lokale Run-ID, Soll-/Ist-Zustand, tatsächliche Objekt-IDs und Übergangsstatus |
| `Secret Provider` | kapselt interaktive Eingabe, lokale Secret Stores und kurzlebige Prozessvariablen |
| `Provider Adapter` | setzt logische Ressourcen providerbezogen um |
| `Scenario Engine` | führt Phasen und Abbruch-/Cleanup-Verträge aus |
| `Project Adapter Host` | ruft projektbezogene Entrypoints ohne Infrastrukturwissen auf |
| `Evidence Normalizer` | erzeugt eine lokale technische Evidenz und eine getrennte sanitisierte Zusammenfassung |
| `Fault Controller` | aktiviert und entfernt ausschließlich definierte, scope-gebundene Fault-Profile |

## 7. Öffentliche Bedienoberfläche

Geplanter Einstiegspunkt:

```powershell
./Invoke-SqlServerLab.ps1
```

Nicht interaktive Beispiele:

```powershell
./Invoke-SqlServerLab.ps1 -Action Preflight

./Invoke-SqlServerLab.ps1 `
  -Action Plan `
  -Mode Quick `
  -Provider Docker `
  -SqlVersions 2022,2025 `
  -ResourceProfile Compact

./Invoke-SqlServerLab.ps1 `
  -Action Up `
  -RequestPath ./Requests/example.quick.request.json

./Invoke-SqlServerLab.ps1 `
  -Action Run `
  -ProjectAdapterPath <lokaler-Adapterpfad> `
  -ScenarioId SQLPERF-OPT-002

./Invoke-SqlServerLab.ps1 `
  -Action Destroy `
  -LabRunId <lokale-Run-ID>
```

### 7.1 Lebenszyklusaktionen

| Aktion | Bedeutung |
|---|---|
| `Preflight` | rein lesende Host-, Provider-, Port-, Storage-, Medien-, Secret- und Konfliktprüfung |
| `Plan` | erzeugt einen verständlichen, noch nicht mutierenden Sollplan |
| `Up` | erstellt nur die geplante Topologie und wartet auf Health- und SQL-Bereitschaft |
| `ApplyAdapter` | installiert oder aktualisiert den gewählten Projektanteil |
| `Run` | führt ein Szenario oder eine explizite Szenariogruppe aus |
| `Observe` | führt die definierten Beobachtungs- und Messschritte aus |
| `Validate` | prüft Status, Invarianten, Findings, Evidenzklasse und Aussagegrenzen |
| `Status` | zeigt Soll-/Ist-Zustand und Health read-only |
| `Stop` | stoppt Ressourcen geordnet, ohne sie zu entfernen |
| `Start` | startet exakt registrierte Ressourcen erneut |
| `Restart` | zusammengesetzter Stop-/Start-Vertrag ohne Identitätswechsel |
| `Reset` | stellt den definierten synthetischen Ausgangszustand wieder her |
| `Down` | entfernt Runtime-Ressourcen, bewahrt freigegebene lokale Zustände |
| `Destroy` | entfernt nach Bestätigung den vollständigen registrierten Lab-Scope |
| `ExportSummary` | erzeugt ausschließlich eine sanitisierte, privacy-geprüfte Zusammenfassung; kein automatischer Repositoryexport |

### 7.2 Zustandsmodell

Vorgesehene Kernzustände:

```text
NOT_PLANNED
PREFLIGHT_READY
PREFLIGHT_FAILED
PLAN_READY
PLAN_REJECTED
UP_IN_PROGRESS
READY
PARTIAL_READY
RUNNING
OBSERVING
VALIDATING
PASSED
WARNED
SKIPPED
FAILED
STOPPING
STOPPED
STARTING
RESETTING
DOWN_IN_PROGRESS
DOWN
DESTROY_CONFIRMATION_REQUIRED
DESTROYING
DESTROYED
RECOVERY_REQUIRED
```

Jeder Übergang wird vor der ersten Mutation lokal persistiert. Fehler dürfen den Scope nicht erweitern.

## 8. Project-Adapter-Vertrag

### 8.1 Verantwortung des Lab-Repositories

`SQL_Server_Lab` verantwortet:

- Host-Preflight und Capability-Ermittlung;
- Provider- und Topologieplanung;
- Container-, VM-, Netzwerk- und Storage-Lifecycle;
- generische SQL-Bereitschaft;
- lokale Secret- und State-Grenzen;
- Fault Injection und deren Rücknahme;
- generische Run-, Status- und Cleanup-Verträge;
- Schema- und Vertragsversionierung.

### 8.2 Verantwortung des konsumierenden Projekts

Das konsumierende Projekt verantwortet:

- fachliche SQL-Skripte und Installationsartefakte;
- Demo- oder Analyse-Szenarioinhalte;
- erwartete fachliche Findings und Invarianten;
- projektbezogene Datenbanken, Marker und Cleanup-Logik;
- projektspezifische Dokumentation;
- fachliche Aussagegrenzen;
- Lizenz- und Quellenpflichten seiner eigenen Inhalte.

### 8.3 Adapterfelder

Der geplante Adaptervertrag enthält mindestens:

- `ContractVersion`;
- `ProjectId`;
- `DisplayName`;
- `SupportedLabContractVersions`;
- `RequiredCapabilities`;
- `SupportedSqlVersions`;
- `DefaultScenarioCatalog`;
- `Entrypoints.Preflight`;
- `Entrypoints.Install`;
- `Entrypoints.Update`;
- `Entrypoints.Observe`;
- `Entrypoints.Validate`;
- `Entrypoints.Cleanup`;
- `SecretInputs` ohne Werte;
- `ProducedLocalArtifacts`;
- `DataClassification`;
- `PrivacyExportPolicy`;
- `LicenseNotice`;
- `KnownLimitations`.

Der Adapter enthält keine realen Repositorypfade. Der lokale Aufrufer bindet einen Checkout oder ein freigegebenes Paket zur Laufzeit ein.

## 9. Providerstrategie

### 9.1 Docker

Docker Engine ist die primäre Container-Lane. Docker Desktop kann für lokale Quick-Umgebungen unterstützt werden, wird aber wegen backendabhängiger Netzwerk- und I/O-Eigenschaften nicht automatisch mit einer nativen Linux-Engine gleichgesetzt.

Verbindliche Ziele:

- gemeinsamer Compose-Core;
- explizite Image-Tags und später optionale Digests;
- sequenzieller Start als Standard;
- CPU- und RAM-Limits;
- Portprüfung vor Mutation;
- Healthcheck plus SQL-Abfrage plus Major-Version-Prüfung;
- Scope-, Owner- und Run-ID-Labels;
- tatsächliche Container-, Netzwerk- und Volume-IDs im State;
- keine globalen Prune- oder Wildcard-Löschungen.

### 9.2 Podman

Podman verwendet denselben logischen Containervertrag. Abweichungen werden in einem Provider-Override und einer Capability-Matrix dokumentiert. Eine Docker-Abnahme gilt nicht automatisch als Podman-Abnahme.

### 9.3 Hyper-V Windows

Einsatzbereiche:

- Windows Authentication;
- vollständiger SQL Server Agent;
- Windows-spezifische Konfigurationen und Performance Counter;
- WSFC-, FCI- und automatische AG-Szenarien;
- feste vCPU-/RAM-Topologien;
- getrennte virtuelle Storage-Controller und VHDX-Rollen;
- VM-basierte Netzwerk- und Ausfalltopologien.

Installationsmedien, Produktschlüssel und Base Images werden ausschließlich lokal referenziert und nicht versioniert.

### 9.4 Hyper-V Linux

Einsatzbereiche:

- kontrollierte native Linux-SQL-Server-Installationen;
- Docker-/Podman-Lane innerhalb einer isolierten VM;
- dedizierte virtuelle Blockgeräte;
- `tc/netem`-basierte Netzwerkprofile;
- cgroup- beziehungsweise blockgerätebezogene I/O-Grenzen, soweit der Gast dies nachweislich unterstützt.

### 9.5 Distributed

Ein zentraler Run kann Rollen auf einen Windows-Hyper-V-Host und einen nativen Linux-Containerhost verteilen. Jeder Teilhost besitzt einen eigenen lokalen State- und Cleanup-Scope. Ein nicht erreichbarer Teilhost löst keine automatische Ersatzplatzierung aus.

## 10. Hardware- und Ressourcenmodell

### 10.1 Host-Capability-Vektor

Der read-only Preflight ermittelt lokal mindestens:

- Betriebssystemfamilie und Architektur;
- PowerShell-Version;
- logische CPU-Anzahl und verfügbare Reserve;
- physischen und verfügbaren RAM;
- freigegebenen Storage-Scope und freien Speicher;
- Hyper-V-, Virtualisierungs- und PowerShell-Direct-Fähigkeiten;
- Docker-, Podman-, Compose-, cgroup- und Netzwerkfähigkeiten;
- freie Ports;
- lokale Medien- und Image-Locks;
- unterstützte Fault-Mechanismen;
- vorhandene, vom Lab registrierte Ressourcen.

Reale Hostnamen, Pfade, Gerätebezeichnungen, Seriennummern, konkrete IP-Adressen und Identitäten bleiben ausschließlich im ignorierten lokalen State.

### 10.2 Ressourcenprofile

Vorgesehene benannte Profile:

| Profil | Zweck |
|---|---|
| `Minimal` | eine kleine Instanz für Funktions- und Syntaxprüfungen |
| `Compact` | normale lokale Quick- und einfache Szenarioläufe |
| `Standard` | umfangreichere Schulungs- und Analyseszenarien |
| `Performance` | größere Datenmengen und kontrollierte Vergleichsmessungen |
| `Stress` | explizit bestätigte, hart begrenzte Ressourcenlast |
| `Custom` | benutzerdefinierte Werte innerhalb validierter Host- und Szenariogrenzen |

Ein Profil ist kein Benchmarkversprechen. SQL-Server-`max server memory`, Container-/VM-Limits und Hostreserve werden getrennt geplant.

### 10.3 Storage-Rollen

Die Topologie verwendet logische Rollen statt realer Laufwerksnamen:

- `CONTROL`;
- `IMAGE_CACHE`;
- `ACTIVE_VM`;
- `SQL_DATA`;
- `SQL_LOG`;
- `TEMPDB`;
- `BACKUP`;
- `EPHEMERAL_DATA`;
- `FAULT_TARGET`.

`FAULT_TARGET` muss eine harte Maximalgröße besitzen und darf niemals auf einen System- oder fremden Datenpfad zeigen.

## 11. Menügeführte Installation

Die interaktive Oberfläche arbeitet in nachvollziehbaren Schritten:

1. Nutzungsart auswählen: `Quick`, `Scenario`, `Custom`;
2. Host-Preflight ausführen;
3. kompatible Provider anzeigen;
4. SQL-Server-Versionen und Betriebssystem wählen;
5. Ressourcenprofil oder benutzerdefinierte Werte wählen;
6. Storage-Layout und Persistenzmodus wählen;
7. Ports und Netzwerkbindung wählen;
8. optionale Project Adapter und Szenarien wählen;
9. optionale Fault-Profile wählen;
10. Secret-Quelle festlegen;
11. vollständigen Mutationsplan anzeigen;
12. Ressourcen-, Sicherheits- und Lizenzhinweise bestätigen;
13. Topologie sequenziell erstellen;
14. Health, SQL-Bereitschaft und erwartete Version prüfen;
15. Verbindungsinformationen ohne Passwort ausgeben;
16. Status-, Reset- und Cleanup-Befehle anzeigen.

Der Menüpfad erzeugt intern einen Run Request. Dadurch sind interaktive und deklarative Ausführung technisch identisch.

## 12. Fault-Injection-Architektur

### 12.1 Grundregeln

- Faults sind standardmäßig deaktiviert.
- Jede Aktivierung benötigt ein Szenario mit Ziel, Scope, Dauer, Obergrenze und Cleanup.
- Faults dürfen nur auf registrierte Labressourcen wirken.
- Der Controller speichert vor der Aktivierung den rekonstruierbaren Ausgangszustand.
- Cleanup wird auch nach fehlgeschlagenem `Act` versucht.
- Ein nicht vollständig rücknehmbarer Fault führt zu `RECOVERY_REQUIRED`.
- Reale Produktionsendpunkte oder externe Netzwerke sind als Ziele unzulässig.

### 12.2 Netzwerkprofile

Vorgesehene Dimensionen:

- zusätzliche Latenz;
- Jitter;
- Bandbreitenbegrenzung;
- Paketverlust;
- Paketduplizierung oder Reordering nur in späteren, explizit validierten Szenarien;
- einseitige und beidseitige Einschränkung;
- definierte Dauer und automatische Rücknahme.

Die konkrete technische Umsetzung ist providerabhängig. Eine auf Docker Desktop nicht belastbar kontrollierbare Eigenschaft wird nicht als gleichwertiger Netzwerkfault ausgewiesen.

### 12.3 I/O-Profile

Vorgesehene Dimensionen:

- Read-/Write-IOPS;
- Read-/Write-Durchsatz;
- zusätzliche Latenz, soweit der Provider sie kontrolliert unterstützt;
- getrennte Data-, Log- und TempDB-Ziele;
- kontrollierter Disk-Full-Scope;
- kleine dedizierte Fault-Volumes;
- optionale Queue-Depth- oder Parallelitätsbegrenzung, sofern technisch nachweisbar.

### 12.4 CPU- und Memory-Profile

- Container-CPU- und Memory-Limits;
- feste VM-vCPU und VM-RAM;
- kontrolliertes `max server memory` innerhalb einer synthetischen Instanz;
- definierte Worker-/Concurrency-Last;
- begrenzte TempDB-, Sort-, Hash- oder Memory-Grant-Szenarien;
- Abbruchsignal und Maximaldauer für jede Last.

## 13. Daten-, Secret- und Evidenzmodell

### 13.1 Datenklassifikation

Zulässige versionierte Klassen:

- `SYNTHETIC`;
- `PUBLIC_FIXTURE`;
- `PUBLIC_REFERENCE`.

Unzulässig im Repository:

- reale Personen-, Benutzer-, Kunden-, Firmen-, Organisations- oder Umgebungsdaten;
- reale Datenbankstrukturen, Namen, Logs, Querytexte, Pläne oder Screenshots;
- Secrets, Tokens, private Schlüssel oder Connection Strings;
- lokale Pfade, Hostnamen, IP-Adressen, Geräte- oder VM-Identitäten;
- proprietäre interne Konfigurationen.

### 13.2 Lokale Laufzeitbereiche

Geplante ignorierte Bereiche:

```text
.artifacts/
.cache/
.secrets/
.state/
.local/
HyperV/Images/output-*/
```

Die exakte Zielstruktur wird in Welle 1 festgeschrieben.

### 13.3 Evidenztrennung

- **Local Technical Evidence:** darf notwendige lokale Laufzeitwerte enthalten, bleibt ignoriert und wird nicht automatisch übertragen.
- **Sanitized Summary:** enthält nur Vertrag, Versionen, Statuscodes, aggregierte Messwerte und synthetische Bezeichner.
- **Repository Evidence:** darf erst nach Privacy-Review aus einer Sanitized Summary abgeleitet werden.

## 14. Integration mit `SQL_Server_Analyze`

### 14.1 Zu übernehmende Stärken

Aus `QuickStart`:

- verständlicher Menüeinstieg;
- Docker- und Hyper-V-Pfade;
- Ressourcenprofile und Storage-Layouts;
- Slow-I/O- und Netzwerkideen;
- Frameworkinstallation und Verbindungsinformationen.

Aus `Lab/QuickTest` und LAB-001:

- read-only Preflight;
- Docker-/Podman-Core;
- Lifecycle- und Statusvertrag;
- Run-ID, Owner-Marker und tatsächliche Objekt-IDs;
- Secret- und State-Grenzen;
- `Arrange`, `Act`, `Observe`, `Assert`, `Cleanup`;
- Capability- und Evidence-Klassen;
- explizite `NOT_EXECUTED`-Behandlung;
- scope-gebundener Reset und Destroy.

### 14.2 Zielzustand im Quellrepository

Nach erfolgreicher Migration verbleiben in `SQL_Server_Analyze` nur:

- ein schlanker Project Adapter;
- analyserspezifische Szenariomanifeste und Assertions;
- Frameworkinstaller und fachliche Testskripte;
- Dokumentation, wie ein kompatibles `SQL_Server_Lab` eingebunden wird;
- vorübergehende Compatibility Wrapper während der Übergangsphase.

Generische Container-, Hyper-V-, Lifecycle- und Fault-Injection-Logik wird nicht parallel weitergeführt.

## 15. Integration mit `SQL_PerformanceSchulung`

### 15.1 Erhaltene fachliche Verantwortung

Der bestehende Demo-Vertrag bleibt maßgeblich für:

- Lernziel und Kernaussage;
- Baseline, Demonstration, Beobachtung, Gegenmaßnahme und Vergleich;
- Sicherheitsstufen Grün, Gelb und Rot;
- deterministische synthetische Daten;
- Mess- und Ergebnisverträge;
- Cleanup und fachliche Traceability.

### 15.2 Zielzustand im Quellrepository

`SQL_PerformanceSchulung` enthält weiterhin:

- Demo-SQL und Demo-README;
- Frameworkobjekte für Datengeneratoren, Messung und Sessionsteuerung;
- fachliche Erwartungswerte und Assertionen;
- einen Project Adapter;
- je Demo eine Referenz auf ein Lab-Szenario oder eine kleine eingebettete Scenario-Erweiterung.

Allgemeine Provider- und Provisionierungslogik wird aus `Infrastructure/` herausgelöst. `Infrastructure/` kann als Adapter-, Beispiel- oder Übergangsbereich bestehen bleiben, aber nicht als zweite Labplattform.

## 16. Vorgesehene Repositorystruktur

```text
SQL_Server_Lab/
├── README.md
├── LICENCE.md
├── CONTRIBUTING.md
├── Invoke-SqlServerLab.ps1
├── .gitignore
├── .ai/
│   ├── PROJECT_CONTEXT.md
│   └── WORKING_RULES.md
├── Contracts/
│   ├── Versions/
│   ├── lab-request.schema.json
│   ├── project-adapter.schema.json
│   ├── scenario.schema.json
│   ├── topology.schema.json
│   ├── resource-profile.schema.json
│   ├── capability.schema.json
│   └── evidence.schema.json
├── Catalog/
│   ├── Providers/
│   ├── Topologies/
│   ├── ResourceProfiles/
│   ├── FaultProfiles/
│   └── Scenarios/
├── Orchestration/
│   ├── SqlServerLab.psd1
│   ├── SqlServerLab.psm1
│   ├── Public/
│   └── Private/
├── Providers/
│   ├── Docker/
│   ├── Podman/
│   ├── HyperVWindows/
│   ├── HyperVLinux/
│   └── Distributed/
├── Scenarios/
│   ├── Core/
│   ├── Performance/
│   ├── Diagnostics/
│   ├── Availability/
│   ├── Infrastructure/
│   └── Fixtures/
├── Adapters/
│   ├── Examples/
│   └── Official/
├── Tools/
│   ├── Validation/
│   ├── Packaging/
│   └── Troubleshooting/
├── Tests/
│   ├── Static/
│   ├── Contract/
│   ├── Synthetic/
│   └── Runtime/
└── Documentation/
    ├── Architecture/
    ├── Operations/
    ├── Project_Planning/
    ├── Quality/
    ├── Reference/
    ├── Standards/
    └── Migration/
```

Diese Struktur ist ein Zielbild. Ordner werden erst angelegt, wenn mindestens ein kanonisches Artefakt darin existiert.

## 17. Umsetzungswellen

### Welle 0 – Repository- und Governance-Basis

**Ziel:** verbindliche Architektur, Regeln und Migrationsgrenze.

Arbeitspakete:

- `LAB-FND-001`: README und Projektabgrenzung;
- `LAB-FND-002`: angepasste `LICENCE.md`;
- `LAB-FND-003`: Privacy- und Artefaktsicherheitsvertrag;
- `LAB-FND-004`: Sprach-, Übersetzungs- und Schreibstandard;
- `LAB-FND-005`: Master-Umsetzungsplan;
- `LAB-FND-006`: Project-Integration-Vertrag;
- `LAB-FND-007`: Migrationsinventar;
- `LAB-FND-008`: lokale Validierungsstrategie ohne CI/CD;
- `LAB-FND-009`: KI-Projektkontext.

Abnahme:

- Ziel, Grenzen und Verantwortungen sind widerspruchsfrei;
- keine CI/CD-Artefakte vorhanden;
- Privacy- und Lizenzregeln sind sichtbar verankert;
- Migration benennt Quelle, Ziel und Übergang je Funktionsgruppe.

### Welle 1 – Versionierte Verträge und CLI-Skelett

**Ziel:** projektneutrale Schnittstelle vor Providerimplementation.

Arbeitspakete:

- JSON-Schemas für Run Request, Project Adapter, Scenario, Topology, Capability, Resource/Fault Profile und Evidence;
- Schema-Versionierungsregeln;
- `Invoke-SqlServerLab.ps1` mit `Preflight`, `Plan`, `Status` und `-WhatIf`-Skelett;
- lokales State- und Pfadmodell;
- Secret-Provider-Abstraktion;
- strukturierte Status- und Fehlercodes;
- Beispielmanifeste ohne funktionsfähige Secrets;
- lokale Schema- und Contract-Tests.

Abnahme:

- ein synthetischer Request wird vollständig validiert;
- ein Project Adapter kann ohne Providerwissen aufgelöst werden;
- ein Plan enthält keine Secrets oder reale Hostwerte;
- unbekannte Vertragsversionen werden kontrolliert abgelehnt.

### Welle 2 – Container Quick Environment

**Ziel:** gemeinsame Docker-/Podman-Basis für den schnellen Einstieg.

Arbeitspakete:

- portabler Compose-Core;
- Docker- und Podman-Overrides;
- SQL Server 2019/2022/2025;
- Menüführung und nicht interaktive Parameter;
- Ressourcenprofile und sequenzieller Start;
- lokale Volumes beziehungsweise Bind-Mounts je Capability;
- Health-, SQL- und Major-Version-Prüfung;
- `Up`, `Status`, `Stop`, `Start`, `Restart`, `Down`, `Destroy`;
- Connection Summary ohne Passwort;
- scope- und full-ID-gebundene Cleanup-Logik.

Abnahme:

- jede Version ist einzeln startbar;
- Mehrfachauswahl ist möglich;
- Docker und Podman nutzen denselben Vertrag;
- Destroy verändert keine nicht registrierte Ressource;
- wiederholter Status ist read-only und idempotent.

### Welle 3 – Migration des Analyze-QuickTest-Lifecycle

**Ziel:** die stärkeren Lifecycle- und State-Verträge aus `Lab/QuickTest` in den gemeinsamen Core übernehmen.

Arbeitspakete:

- Übergangszustände vor Mutation;
- Recovery-Status;
- Reset-Vertrag für temporäre Scopes;
- Update-/Apply-Adapter ohne Lifecycle-Seiteneffekt;
- Run-ID-/Owner-/Full-ID-Validierung;
- Preflight-Reason-Codes;
- lokale generated-secret-Verwaltung;
- Compatibility Wrapper für `SQL_Server_Analyze`.

Abnahme:

- bestehende relevante QuickTest-Lifecycle-Verträge sind abgedeckt;
- Frameworkupdate startet oder ersetzt keine Runtime-Ressource;
- Reset und Destroy unterscheiden sich klar;
- unterbrochene Übergänge sind diagnostizierbar.

### Welle 4 – Hyper-V Provider

**Ziel:** Windows- und Linux-VMs mit gemeinsamer Topologie- und State-Architektur.

Arbeitspakete:

- Base-Image- und Media-Lock-Vertrag;
- Differencing-Disks;
- Windows- und Linux-Provisionierung;
- feste vCPU-/RAM-Profile;
- virtuelle Switches und isolierte Subnetze;
- Data-/Log-/TempDB-VHDX-Rollen;
- PowerShell Direct beziehungsweise sichere Gaststeuerung;
- Health- und SQL-Bereitschaft;
- VM-Reset und Destroy über registrierte IDs;
- keine Medien- oder Lizenzweitergabe.

Abnahme:

- eine Windows- und eine Linux-SQL-VM können getrennt geplant werden;
- VM- und VHDX-Objekte sind vollständig registriert;
- Reset ersetzt nur Child Disks oder definierte temporäre Datenträger;
- fremde VMs, Switches und VHDX-Dateien bleiben unangetastet.

### Welle 5 – Scenario Engine und Fault Injection

**Ziel:** fachliche Konstellationen providerunabhängig ausführen.

Arbeitspakete:

- `Arrange`, `Act`, `Observe`, `Assert`, `Cleanup`;
- globale und phasenbezogene Timeouts;
- Abbruchsignale;
- Safety Classes;
- Capability- und Alternative-Evidence-Logik;
- Netzwerk-, I/O-, CPU-, Memory-, TempDB- und Log-Profile;
- automatischer Cleanup-Versuch nach Fehlern;
- lokale technische Evidenz und sanitisierte Summary.

Abnahme:

- ein Szenario kann auf zwei kompatiblen Providern denselben fachlichen Vertrag verwenden;
- fehlende Capabilities ergeben `NOT_EXECUTED`;
- Faults sind scope-gebunden und werden nachweislich entfernt;
- keine absolute Performancebehauptung entsteht aus einem Einzelhostlauf.

### Welle 6 – Adapter `SQL_PerformanceSchulung`

**Ziel:** Demos nutzen das Lab, ohne ihren fachlichen Demo-Vertrag zu verlieren.

Arbeitspakete:

- Project Adapter;
- Mapping der Sicherheitsstufen Grün/Gelb/Rot;
- Mapping von Setup, Baseline, Demonstration, Observation, Mitigation, Comparison und Cleanup;
- Demo-zu-Szenario-Katalog;
- Multi-Session-Entrypoints;
- Mess- und Ergebnisnormalisierung;
- Quick-Environment-How-to für Teilnehmer;
- Compatibility Wrapper unter `Infrastructure/`.

Abnahme:

- mindestens eine grüne, gelbe und rote Pilotdemo ist abgebildet;
- rote Demos verlangen wegwerfbaren Lab-Scope;
- Demo-Cleanup bleibt fachlich im Schulungsrepository;
- Provider-Logik wird nicht in Demo-Skripte kopiert.

### Welle 7 – Adapter `SQL_Server_Analyze`

**Ziel:** Analyse- und Lastkonstellationen nutzen den gemeinsamen Lab-Core.

Arbeitspakete:

- Framework-Install-/Update-Adapter;
- Analyzer-Observation-Entrypoints;
- Mapping bestehender LAB-001-Szenarien;
- Finding- und Statusassertionen;
- Versionsmatrix 2019/2022/2025;
- Blocking-, Wait-, TempDB-, I/O-, Query-Store-, XE- und Infrastruktur-Piloten;
- Compatibility Wrapper für `QuickStart` und `Lab/QuickTest`.

Abnahme:

- mindestens ein Quick-, ein Diagnose- und ein Fault-Injection-Szenario sind übernommen;
- Frameworkupdate verändert die Topologie nicht;
- Analyzer-Evidenz bleibt fachlich im Analyze-Repository;
- generische Lifecycle-Logik ist nicht mehr dupliziert.

### Welle 8 – Ablösung und Repositorybereinigung

**Ziel:** kontrollierte Entfernung der doppelten Implementierungen.

Arbeitspakete:

- Migrationsvergleich je Datei und Funktion;
- dokumentierte Deprecation-Phase;
- Wrapper mit Versions- und Pfadhinweis;
- Anpassung der READMEs und How-tos;
- Entfernung erst nach reproduzierbarer Abnahme;
- Prüfung offener Branches und veralteter Dokumente;
- finaler Verantwortungs- und Abhängigkeitscheck.

Abnahme:

- kein Quellrepository besitzt eine zweite generische Labplattform;
- alle dokumentierten Einstiegspunkte führen eindeutig zum neuen Lab;
- keine noch benötigte Funktion wurde ohne Ersatz entfernt;
- Branches und Übergangsartefakte sind bereinigt.

### Welle 9 – Release-Härtung ohne CI/CD

**Ziel:** lokal reproduzierbare Qualitäts- und Freigabeprozesse.

Arbeitspakete:

- Pester- und Contract-Testpaket;
- statische Privacy-, Secret- und Pfadprüfung;
- PSScriptAnalyzer-Regelsatz;
- lokale Container- und Hyper-V-Abnahmeanleitungen;
- Recovery- und Troubleshooting-Handbuch;
- Versionierung und Release Notes;
- signierte beziehungsweise hashgebundene optionale Pakete;
- definierte Schnittstelle für ein späteres separates Validation-Repository.

Abnahme:

- alle Prüfungen sind lokal ohne GitHub Runner ausführbar;
- Releaseartefakte enthalten keine lokalen States, Secrets oder Umgebungsdaten;
- ein externer Validator könnte ausschließlich über veröffentlichte Verträge arbeiten.

## 17a. Umsetzungsstand der Wellen (Stand 2026-08-01)

Dieser Abschnitt gleicht den Plan mit dem tatsächlich implementierten Stand ab.
Er ist eine Statusübersicht, kein Runtime-Nachweis; verbindlich bleibt
`Documentation/Quality/KNOWN_LIMITATIONS.md`.

**Begriffsklärung:** Die Wellen dieses Master-Plans sind nicht identisch mit
den „Sample-Wellen“ in
[Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](../Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md)
und den Hyper-V-Wellen im
[Hyper-V-Zielvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md).
Jedes Dokument führt seine eigene Wellenzählung.

| Master-Plan-Welle | Stand | Anmerkung |
|---|---|---|
| Welle 0 – Repository- und Governance-Basis | abgeschlossen | README, Lizenz, Privacy-, Sprach- und Validierungsverträge, KI-Kontext vorhanden |
| Welle 1 – Verträge und CLI-Skelett | teilweise, mit bewusster Abweichung | Statt getrennter Run-Request-/Scenario-/Topology-Schemas existiert `Schemas/lab-manifest.schema.json` mit Wizard und Fachvalidierung; Preflight ist `Test-SqlServerLabPrerequisite`; der Adaptervertrag ist als `Schemas/project-adapter.schema.json` (`0.1-draft`) implementiert. Scenario- und Capability-Schemas sind offen |
| Welle 2 – Container Quick Environment | umgesetzt | Docker und Podman über direkte Provider-Adapter (kein Compose-Core), Menü und nicht interaktive Parameter, Profile, Health-/SQL-/Versionsprüfung, Lifecycle, scope-gebundener Cleanup; zusätzlich implementiert: gemischter Docker-/Podman-Run, Sample-Backup-Handler mit Trust Store und inhaltsadressiertem Cache |
| Welle 3 – Migration des Analyze-QuickTest-Lifecycle | teilweise | Übergangszustände vor Mutation, Recovery-Status, Run-ID-/Scope-Validierung und lokale Secret-Verwaltung sind im Core vorhanden; Reset-Vertrag, Apply-Adapter und Compatibility Wrapper für `SQL_Server_Analyze` sind offen |
| Welle 4 – Hyper-V Provider | nicht begonnen | verbindlicher Zielvertrag dokumentiert; Provisionierung bricht kontrolliert ab |
| Welle 5 – Scenario Engine und Fault Injection | nicht begonnen | |
| Welle 6 – Adapter `SQL_PerformanceSchulung` | begonnen | Adaptervertrag, Resolver, `Test-/Install-SqlServerLabAdapter` und synthetischer Beispieladapter sind implementiert (`ADP-001`/`ADP-002`/`ADP-005`); der Pilot im Schulungsrepository ist offen, siehe [Project-Adapter-Priorisierung](PROJECT_ADAPTER_PRIORITIZATION.md) |
| Welle 7 – Adapter `SQL_Server_Analyze` | begonnen | gleiche Adapterbasis; der Pilot im Analyze-Repository ist offen |
| Welle 8 – Ablösung und Repositorybereinigung | nicht begonnen | setzt Wellen 6 und 7 voraus |
| Welle 9 – Release-Härtung ohne CI/CD | teilweise | statische Contract-Checks und lokale Validierungsstrategie existieren; Pester-Paket, Privacy-Scanner und Releaseprozess sind offen |

**Strukturabweichung:** Die Zielstruktur aus Abschnitt 16 (`Contracts/`,
`Catalog/`, `Orchestration/`, `Scenarios/`, `Adapters/`, `Tools/`) wurde nicht
angelegt. Die implementierte Struktur verwendet `Public/`, `Private/`,
`Providers/`, `Catalogs/`, `Schemas/` und `Tests/` im Repository-Stamm. Die
Zielstruktur bleibt Orientierung für die Adapter- und Scenario-Wellen; Ordner
entstehen weiterhin erst mit dem ersten kanonischen Artefakt.

## 18. Priorisierte Pilotkonstellationen

### P0

1. Docker Quick Environment mit SQL Server 2022;
2. Docker-/Podman-Matrix für 2019, 2022 und 2025;
3. Analyze-Frameworkinstallation über Adapter;
4. Performance-Schulungsdemo mit einer Instanz und deterministischer Testdatenbank;
5. temporärer Scope mit vollständigem Reset und Destroy;
6. Netzwerk-Latenzprofil auf einer kontrollierten Linux-Lane;
7. I/O-Limit auf einem dedizierten Lab-Blockgerät oder VHDX.

### P1

1. Hyper-V-Windows-VM mit SQL Server Agent und Windows Authentication;
2. getrennte Data-/Log-/TempDB-VHDX-Rollen;
3. Blocking-/Deadlock-Multi-Session-Szenario;
4. TempDB-, Log- und Memory-Grant-Druck;
5. verteilte Windows-/Linux-Topologie;
6. Query-Store-/Extended-Events-Szenario mit lokalem, nicht versioniertem Evidence-Scope.

### P2

1. WSFC-/AG-/FCI-Topologien;
2. Log Shipping und Replication;
3. kontrollierte Disk-Full- und Recovery-Szenarien;
4. komplexe Netzwerkpartitionen;
5. zusätzliche Projektadapter;
6. optionales separates Validation-Repository.

## 19. Risiken und Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| erneute Doppelimplementierung | klare Ownership-Matrix und Adaptergrenze |
| zu komplexe Bedienung | `QUICK` als vereinfachte Sicht auf denselben Core |
| unzuverlässige Hardware-Simulation | Capability-gebundene Aussageklassen und keine Gleichwertigkeitsbehauptung ohne Nachweis |
| versehentliche Fremdressourcenlöschung | Run-ID, Marker, tatsächliche Objekt-IDs, Pfadgrenzen, `-WhatIf`, Bestätigung |
| Secret-Leak | Secret Provider, ignorierte lokale Pfade, redigierte Konsolenausgabe, keine Werte in Manifesten |
| Repositorydaten aus realen Umgebungen | verbindlicher Privacy-Vertrag und lokale Evidenztrennung |
| zu frühe Vertragsfestschreibung | `0.x`-Draftphase; `1.0` erst nach zwei produktiven Adaptern |
| Quellprojekte verlieren Funktionen | inventarisierte Migration, Wrapper und Abnahme vor Entfernung |
| CI/CD wächst wieder in das Produktrepo | lokale Tests und explizite Grenze zu einem möglichen separaten Validator |
| Lizenzkonflikte bei Medien und Images | keine Weitergabe; lokale Media Locks; Betreiberverantwortung dokumentieren |

## 20. Versions- und Kompatibilitätsstrategie

- CLI, Schemas und Adaptervertrag erhalten unabhängige, aber koordinierte Versionsnummern.
- Vor `1.0` dürfen Breaking Changes erfolgen, müssen aber mit Migrationshinweis dokumentiert werden.
- Ab `1.0` gilt Semantic Versioning für öffentliche Verträge.
- Ein Adapter nennt die unterstützte Mindest- und Höchstversion des Labvertrags.
- Unbekannte Major-Versionen werden abgelehnt.
- Minor-Erweiterungen dürfen bestehende erforderliche Felder nicht semantisch verändern.
- Statuscodes sind stabiler als Konsolentexte und werden nicht übersetzt.
- Provider-Capabilities werden additiv versioniert.

## 21. Definition of Done für das Gesamtprojekt

Das Vorhaben gilt als funktional abgeschlossen, wenn:

1. Docker, Podman und Hyper-V über einen gemeinsamen CLI- und State-Vertrag steuerbar sind;
2. Quick-, Scenario- und Custom-Modus denselben Core verwenden;
3. SQL Server 2019, 2022 und 2025 unterstützt und versionserkannt werden;
4. Project Adapter für `SQL_Server_Analyze` und `SQL_PerformanceSchulung` produktiv nutzbar sind;
5. die doppelten generischen Labimplementierungen in den Quellrepositories kontrolliert abgelöst wurden;
6. Netzwerk-, I/O-, CPU- und Memory-Konstellationen capability- und scope-gebunden verfügbar sind;
7. alle mutierten Ressourcen exakt registriert und sicher bereinigt werden;
8. lokale Secrets und Runtime-Evidenz nicht in versionierte Artefakte gelangen;
9. Privacy-, Lizenz-, Sprach- und Qualitätsregeln in Dokumentation und Umsetzung konsistent sind;
10. lokale statische, Contract-, Synthetic- und Runtime-Prüfungen dokumentiert und ausführbar sind;
11. keinerlei GitHub-Workflow- oder Runnerabhängigkeit für die Produktfunktion besteht;
12. eine neue Person das Repository ohne frühere Chatkontexte verstehen, aufsetzen und sicher bedienen kann.

## 22. Nächster sinnvoller Verarbeitungsschritt

Der Container-Core (Welle 2) ist umgesetzt; der Sample-Backup-Handler mit
Trust-Pfad und Mehrfachauswahl ist implementiert (Sample-Welle 3 des
Sample-Zielvertrags). Die nächsten Schritte sind:

1. Sample-Wellen 4 und 5 (SQL-Skript-/Bundle-Handler, `LAB_GENERATED`-Baselines)
   gemäß Sample-Zielvertrag abschließen, soweit sie für die Adapter benötigt
   werden;
2. **Project Adapter priorisieren:** Adaptervertrag als versioniertes
   JSON-Schema festschreiben und die Wellen 6 und 7 mit je einer Pilotdemo
   beginnen. Details und Reihenfolge stehen in
   [Project-Adapter-Priorisierung](PROJECT_ADAPTER_PRIORITIZATION.md);
3. Hyper-V (Welle 4) folgt nach den Adaptern; vorbereitend werden nur die
   providerneutralen Drive-, Network-, Software- und Reconcile-Verträge
   geschärft.

Vor der Übernahme ausführbarer Dateien aus den Quellrepositories wird das
Migrationsinventar pro Datei vervollständigt und jede Funktion als `MIGRATE`,
`REIMPLEMENT`, `KEEP_PROJECT_SPECIFIC`, `WRAP_TEMPORARILY` oder
`RETIRE_AFTER_ACCEPTANCE` klassifiziert.
