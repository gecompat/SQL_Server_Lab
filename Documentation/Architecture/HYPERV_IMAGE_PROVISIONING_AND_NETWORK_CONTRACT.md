# Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag

| Merkmal | Wert |
|---|---|
| Status | `BINDING_IMPLEMENTATION_TARGET` |
| Runtime-Status | `PARTIALLY_IMPLEMENTED_WINDOWS_SPECIALIZATION_SQL_READINESS` |
| Stand | 2026-08-03 |
| Geltungsbereich | Hyper-V sowie providerneutrale Anteile für Docker und Podman |
| Aktueller Ist-Nachweis | [`KNOWN_LIMITATIONS.md`](../Quality/KNOWN_LIMITATIONS.md) |
| Ergänzender Artifact-Vertrag | [Testdatenbank-Provisionierung und Manifest-Wizard](SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md) |

## 1. Zweck und Statusabgrenzung

Dieses Dokument definiert den verbindlichen Zielvertrag für:

- die automatische und resumierbare Hyper-V-Provisionierung;
- die Auswahl, Verifikation, Erzeugung, Aktualisierung und Wiederverwendung von
  OS-, SQL-Server- und Software-Artefakten;
- Windows- und Linux-Gäste;
- SQL-Server-Installation aus dem bestmöglichen kompatiblen Aufsetzpunkt;
- zusätzliche Drives, Netzwerke, Software, External Runtimes und
  Testdatenbanken;
- manuelle Installationsschritte mit geführter Fortsetzung;
- die kontrollierte nachträgliche Änderung bestehender Umgebungen;
- providerneutrale Netzwerk-, Software-, Resource- und Reconcile-Verträge für
  Hyper-V, Docker und Podman.

Dieses Dokument ist **kein vollständiger Runtime-Nachweis**. Implementiert sind
die isolierte Lifecycle-Grundlage aus Welle 4, die Registry-Grundlage aus Welle
2 sowie Teile aus Welle 5: Generation 2, Secure Boot, verifizierte Parent-/
Child-VHDX, Status, Start, Stop, PowerShell Direct, scopegebundener Cleanup,
immutable sealed VHDX, deterministische Auswahl, Manifest Lock, zusätzliche
Gast-Drives, Windows-Specialization mit Reboot/Reconnect und eine interne SQL-
Readiness-Orchestrierung. Unattended Image Build, SQL `CompleteImage`, Netzwerk-
und Manifest-Binding sowie der echte Windows-/SQL-End-to-End-Nachweis sind noch
nicht implementiert. Die bestehenden Containerpfade bleiben für SQL-fertige
Labs unverändert maßgeblich.

## 2. Verbindliche Grundentscheidungen

1. Hyper-V wird als resumierbare Image- und Provisioning-Pipeline umgesetzt,
   nicht als einzelner monolithischer `New-VM`-Ablauf.
2. Das Betriebssystem liegt immer auf genau einer eigenen OS-VHDX. Zusätzliche
   Drives werden pro Lab separat erstellt und eingebunden.
3. Wiederverwendbare, unveränderliche VHDX-Zustände heißen `sealed artifacts`.
   Hyper-V-Checkpoints und VM-Exporte sind run-lokale Recovery Points und keine
   kanonischen globalen Images.
4. Die bevorzugte allgemeine SQL-Ausgangsbasis ist
   `SQL_PREPARED_SEALED` mit SQL Server `PrepareImage`. Die konkrete Instanz
   wird erst im Child über `CompleteImage` fertiggestellt.
5. SQL Server Developer Edition ist der Default, sofern sie für die gewünschte
   Version und Plattform verfügbar und rechtlich zulässig ist. Evaluation ist
   der Fallback.
6. Bei Windows wird in dieser Reihenfolge gewählt:
   - ein vom Benutzer bereitgestelltes gültig lizenziertes Medium;
   - eine dauerhaft legal kostenlos nutzbare und funktional geeignete Edition,
     sofern verfügbar;
   - andernfalls eine Evaluation Edition.
7. Evaluierungszeiträume werden erfasst und niemals durch Checkpoints,
   Differencing Disks oder andere technische Mittel künstlich zurückgesetzt.
8. `software`, Python, R, Java und andere External Runtimes sind
   providerneutral. Die heutige Schemaeinschränkung auf wenige
   Hyper-V-orientierte Software-IDs ist eine Runtimegrenze, keine
   Architekturentscheidung.
9. Funktionale Ad-hoc-Labs dürfen Dynamic Memory verwenden. Reproduzierbare
   Performance-Labs verwenden standardmäßig statisches RAM. Beide Varianten
   bleiben über Manifest und Menü nachträglich änderbar.
10. Netzwerktopologie wird providerneutral nach Intent modelliert. `public` ist
    keine Netzwerkart, sondern eine getrennte Exposure Policy.
11. Manifeste sind die gewünschte Konfiguration. Die Runtime plant die
    Differenz zum Ist-Zustand und wählt pro Änderung `live`, `restart`,
    `recreate` oder `reprovision`.
12. Verwendete Artefakte werden nie überschrieben. Refresh oder Rebuild erzeugt
    stets eine neue versionierte Artifact-ID.

## 3. Aktueller Ausgangspunkt und notwendige Providerneutralisierung

| Bereich | Aktueller Stand | Ziel |
|---|---|---|
| Hyper-V | Lifecycle- und Image-Registry-Grundlage | vollständiger, getesteter Lifecycle |
| Betriebssystem | nur `windows` oder `linux` | Version, Edition, Sprache, Architektur, Installationsart und Lizenzstatus |
| Drives | `containerPath` und `tmpfs` geprägt | providerneutrale Rolle, `guestPath` und Provider-Binding |
| Netzwerke | nicht im Manifest modelliert | Intent, IPAM, DNS und Exposure Policy |
| Software | begrenzte ID-Liste, primär VM-orientiert | Capability- und Artifact-basierter Vertrag für alle Provider |
| Ressourcen | containerorientierte Schätzung | OS-, VHDX-, Builder-, Baseline-, Download- und Gastbedarf |
| Änderungen | Create-/Lifecycle-orientiert | Plan, Diff, Reconcile und Validation |
| Medien | kein vollständiger Lifecycle | Acquire, Trust, Verify, Build, Refresh, Retire und Cleanup |
| Wiederaufnahme | kein allgemeiner Vertrag | persistente Steps, Reboots und `MANUAL_ACTION_REQUIRED` |

Providerneutrale Verträge werden zuerst definiert. Providerbezogene Details
bleiben in Adaptern. Ein Manifestfeld wird erst ergänzt, wenn der zugehörige
Runtimepfad, die Fachvalidierung, ein Beispiel, Known Limitations und Tests
gemeinsam bereitstehen.

## 4. Artefakt- und Recovery-Modell

### 4.1 Begriffe

| Begriff | Bedeutung | Portabel |
|---|---|---:|
| `sealed artifact` | unveränderliche, verifizierte VHDX- oder Image-Baseline | ja, innerhalb des Kompatibilitätsvertrags |
| `run recovery point` | Checkpoint oder Export einer konkreten VM eines konkreten Runs | nein |
| `database baseline` | verifiziertes `LAB_GENERATED`-Backup einer zulässigen Labdatenbank | ja, nach Restore-Kompatibilität |
| `manifest lock` | vollständig aufgelöste Artifact-IDs, Quellen, Hashes, Builds und Verträge | sanitisiert exportierbar |
| `artifact registry` | lokaler Katalog aller versionierten Medien, Images, Baselines und Referenzen | lokal |

### 4.2 Vorgesehene Aufsetzpunkte

| Zustand | Global wiederverwendbar | Inhalt | Nächster Schritt |
|---|---:|---|---|
| `MEDIA_VERIFIED` | ja | OS-/SQL-/Software-Medium, SHA-256, Lizenz- und Herkunftsmetadaten | Image Build |
| `OS_SEALED` | ja | installiertes, aktualisiertes und generalisiertes OS | SQL vorbereiten oder installieren |
| `SQL_PREPARED_SEALED` | ja | SQL Server mit `PrepareImage`, noch keine konfigurierte Instanz | Child erstellen und `CompleteImage` |
| `SQL_READY_RUN` | nur gleicher Run | konkrete SQL-Instanz vollständig konfiguriert | Software und Datenbanken |
| `EXTENSIONS_READY_RUN` | nur gleicher Run | External Runtimes und Zusatzsoftware validiert | Datenbanken |
| `DATABASES_READY_RUN` | optional, gleicher Run | Testdatenbanken installiert und verifiziert | Szenario ausführen |

Nur generalisierte Zustände dürfen als globale VHDX-Baseline veröffentlicht
werden. Eine vollständig konfigurierte SQL-VM ohne korrektes
`PrepareImage`/`CompleteImage`-Verfahren bleibt run-lokal.

### 4.3 VHDX-Regeln

- Registrierte Parent-VHDX sind unveränderlich und read-only.
- Jede VM erhält eine neue Differencing Disk direkt von einem registrierten
  Parent.
- Mehrstufige Laufzeit-Differencing-Ketten werden vermieden.
- Ein Update erzeugt eine neue Parent-Generation und mutiert kein bestehendes
  Parent.
- Checkpoints werden nicht als allgemeine Golden Images verwendet.
- Cleanup entfernt nur registrierte Child-Ressourcen des aktuellen Scopes.
- Parents, Cache und Baselines werden referenzgezählt und erst ohne Referenzen
  zur Bereinigung angeboten.

## 5. Deterministische Auswahl der besten Ausgangsbasis

`imagePolicy: bestAvailable` bedeutet nicht „neuester Zustand“. Der Resolver
filtert und bewertet in dieser Reihenfolge:

1. Source und Artifact sind vertrauenswürdig und SHA-256-verifiziert.
2. OS-Version, Edition, Sprache, Architektur und Core/Desktop Experience passen.
3. SQL-Version, Edition, Build/CU und Feature-Set passen.
4. Installierte Features sind exakt kompatibel; unerwünschte zusätzliche
   Features gelten nicht automatisch als passend.
5. Kein ausstehender Neustart und alle Health Checks erfolgreich.
6. Lizenz- oder Evaluierungsstatus ist gültig und erfüllt die konfigurierte
   Mindestrestlaufzeit.
7. Parent-VHDX und vollständige Herkunftskette sind vorhanden.
8. Der höchste kompatible Zustand mit dem geringsten verbleibenden Aufwand
   gewinnt.

Die Auswahl zeigt vor der Mutation mindestens:

- gewählte Artifact-ID und Zustand;
- begründete Kompatibilität;
- verworfene höherwertige Kandidaten und Grund;
- verbleibende Schritte;
- Download-, Storage-, Reboot- und Zeitbedarf;
- Evaluierungsrestlaufzeit;
- erforderliche Trust- oder Manual Actions.

Das Run-Lock hält die gewählten Artifact-IDs, Versionen, Builds, Sources,
SHA-256, Integrity Origins, Contract-Versionen und Kompatibilitätsentscheidung
fest. Secrets und konkrete Benutzer- oder Hostdaten bleiben ausgeschlossen.

## 6. Medien-, Lizenz- und Image-Lifecycle

### 6.1 Acquisition und Trust

OS-, SQL- und Software-Medien verwenden denselben übergeordneten Lifecycle:

`Resolve -> Plan -> Acquire -> VerifyIntegrity -> Prepare -> Apply -> VerifyOutputs -> Register`

Ist keine Hersteller-Prüfsumme verfügbar, gilt der verbindliche
Trust-/SHA-256-Vertrag aus
[`SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md`](SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md):

- interaktiv einmalig Vertrauen für die konkreten Bytes abfragen;
- nach Zustimmung vollständig herunterladen;
- SHA-256 berechnen und dauerhaft registrieren;
- spätere Verwendung derselben Bytes nicht erneut abfragen;
- andere Bytes unter derselben URL als neues Artifact behandeln;
- im nicht interaktiven Modus mit `TRUST_REQUIRED` abbrechen.

### 6.2 OS-Katalog

Ein OS-Katalog benötigt mindestens:

- stabile ID und Version;
- Familie, Edition und Installationsart;
- Core/Desktop Experience beziehungsweise Distribution und Variante;
- Sprache und Architektur;
- Generation-2- und Secure-Boot-Kompatibilität;
- Source, Lizenztyp und Nutzungsbedingungen;
- Evaluation-Dauer, Aktivierungsanforderung und bekannte Ablaufregel;
- `installedAt`, `evaluationExpiresAt` und Mindestrestlaufzeit;
- unattended Installationsmethode;
- Guest-Management-Methode;
- Servicing Policy;
- SHA-256 und Integrity Origin;
- Artifact- und Contract-Version.

Der Katalog bezeichnet eine Quelle nicht ohne Herstellerprüfung als aktuellste
Version.

### 6.3 SQL-Server-Katalog

Die Auswahlreihenfolge lautet:

1. Developer Edition, wenn verfügbar und geeignet;
2. bei bewusstem Editionsvergleich eine ausdrücklich gewählte alternative
   Developer-Variante, sofern angeboten;
3. Evaluation, wenn keine geeignete Developer Edition oder kein verwendbares
   Medium verfügbar ist;
4. Express oder eine lizenzierte Edition nur nach expliziter Auswahl.

Der Katalog hält Version, Edition, Build/CU, Plattform, Feature-Support,
Installationsmethode, `PrepareImage`-/`CompleteImage`-Eignung, Source,
SHA-256, Lizenz und Reboot-Verhalten.

### 6.4 Refresh und Rebuild

Das Menü bietet mindestens:

- Medien und Images anzeigen;
- Source und Lizenzstatus prüfen;
- Evaluation-Ablauf prüfen;
- Source erneut herunterladen;
- neuere kompatible Source suchen;
- SHA-256 erneut verifizieren;
- OS-Baseline neu erstellen;
- SQL-Baseline neu erstellen;
- Derived Container Image neu bauen;
- OS-Updates oder SQL-CU in eine neue Generation einarbeiten;
- Artifact stilllegen;
- unreferenzierte Artifacts bereinigen.

Regeln:

- bestehende Artifact-IDs und Bytes bleiben unverändert;
- jeder Refresh oder Build erzeugt eine neue Artifact-ID;
- laufende Labs behalten ihr Manifest Lock;
- neue Labs wählen gemäß Policy das beste gültige Artifact;
- abgelaufene oder fast abgelaufene Evaluation-Baselines werden nicht
  automatisch wiederverwendet;
- ein neuer Evaluierungszeitraum beginnt ausschließlich durch zulässige
  Neuinstallation aus einem aktuellen Medium;
- Referenzen verhindern die Bereinigung.

Beispiel für den späteren Zielvertrag:

```yaml
artifacts:
  refreshPolicy: ifExpiredOrOutdated
  minimumEvaluationDaysRemaining: 30
  sourcePolicy: latestCompatible
  rebuildDerivedImages: true
  preserveReferencedVersions: true
```

## 7. Erstmaliger Image Build

1. OS-Auswahl und Lizenzpfad auflösen.
2. Medium erwerben und SHA-256 verifizieren.
3. Temporäre Builder-VM mit genau einer OS-VHDX erzeugen.
4. Betriebssystem unattended über die unterstützte Installationsmethode
   installieren.
5. Guest Management einrichten:
   - Windows bevorzugt über PowerShell Direct;
   - Linux bevorzugt über cloud-init und SSH.
6. Gewählte Servicing Policy anwenden.
7. Reboots resumierbar ausführen und Health Checks wiederholen.
8. OS generalisieren und herunterfahren.
9. Eigenständige, immutable `OS_SEALED`-VHDX veröffentlichen.
10. Optional SQL Server über `PrepareImage` vorbereiten.
11. Erneut generalisieren, verifizieren und `SQL_PREPARED_SEALED`
    veröffentlichen.

Default für Hyper-V:

- Generation 2;
- Secure Boot aktiv;
- Windows-Template für Windows;
- passende UEFI-CA-Vorlage für unterstützte Linux-Distributionen;
- Abweichung nur nach Capability-Nachweis und sichtbarer Begründung.

## 8. Regulärer Hyper-V-Lab-Run

1. bestmögliche Baseline deterministisch auswählen;
2. Child-VHDX und VM im Run-Scope registrieren;
3. OS `specialize`, eindeutigen Hostnamen und neue Maschinenidentität setzen;
4. zusätzliche Drives erstellen und anhängen;
5. Drives im Gast über stabile Disk-ID initialisieren und verifizieren;
6. Management- und Lab-Netze anbinden;
7. SQL `CompleteImage` oder vollständiges unattended Setup ausführen;
8. SQL Server konfigurieren;
9. Software und External Runtimes installieren;
10. Testdatenbanken und Post-Provision-Schritte anwenden;
11. Connection-, Versions-, Feature- und Health-Checks ausführen;
12. optional run-lokalen Recovery Point erzeugen;
13. State auf `RUNNING` setzen.

State und Cleanup Plan existieren vor der ersten Host- oder Gastmutation.

## 9. Providerneutraler Drive-Vertrag

Ein zukünftiges Drive-Objekt enthält mindestens:

| Feld | Bedeutung |
|---|---|
| `id` | stabile logische ID |
| `role` | `sqlData`, `sqlLog`, `tempdb`, `backup` oder `general` |
| `guestPath` | Windows-Drive/Mountpoint oder Linux-Mountpoint |
| `sizeGB` | angeforderte Größe |
| `format` | Dateisystem |
| `allocationUnitKB` | Allocation Unit |
| `vhdType` | `dynamic`, `fixed` oder `differencing` |
| `hostStorage` | `auto` oder gebundener lokaler Storage Root |
| `iops.minimum` / `iops.maximum` | optionale I/O-Grenzen |
| `persistAfterRemove` | explizite Retention Policy |

Defaults:

- OS: Differencing Disk von sealed Parent;
- funktionales Lab: dynamische zusätzliche VHDX;
- Performance-Lab: feste zusätzliche VHDX;
- keine tiefe Differencing-Kette;
- SQL-Pfade erst nach Drive-Validation konfigurieren.

Mehrere VHDX auf demselben physischen Host-Datenträger erzeugen nur logische,
keine physische I/O-Trennung. Planvorschau und Menü müssen dies sichtbar
machen.

## 10. Netzwerk- und Exposure-Vertrag

### 10.1 Providerneutrale Network Intents

| Intent | Hyper-V | Docker/Podman | Bedeutung |
|---|---|---|---|
| `isolated` | Private Switch | isoliertes internes Bridge-Netz | nur Teilnehmer desselben Netzes |
| `hostOnly` | Internal Switch ohne NAT | internes Netz mit Hostzugang | Gast zu Host, kein Internet |
| `nat` | Internal Switch plus WinNAT | Bridge-Netz mit NAT | Outbound; Inbound nur explizit |
| `lan` | External Switch | macvlan/ipvlan, sofern unterstützt | Teilnehmer im physischen LAN |

Hyper-V verwendet die nativen Switch-Typen External, Internal und Private.
`public` wird nicht als vierter Switch-Typ modelliert.

### 10.2 Exposure Policy

| Wert | Bedeutung |
|---|---|
| `none` | kein eingehender Zugriff außerhalb des Lab-Netzes |
| `host` | nur vom Host erreichbar |
| `lan` | im lokalen LAN erreichbar |
| `public` | ausdrücklich freigegebener eingehender Zugriff |

Default ist `none` beziehungsweise höchstens `host` für den benötigten
Managementzugriff. Öffentliche oder LAN-Exposition erfordert eine explizite
Auswahl.

### 10.3 Hyper-V-Netzwerkregeln

- ein Lab-verwaltetes gemeinsames Management-NAT-Netz pro Host;
- zusätzlich run- oder netzspezifische Private Switches;
- optional zweite NIC für `lan`;
- automatische CIDR-/IPAM-Kollisionsprüfung gegen Hostrouten sowie vorhandene
  Hyper-V-, Docker- und Podman-Netze;
- statische Gastadressierung, solange kein explizit verwalteter DHCP-Dienst
  existiert;
- DNS und Adresszuweisung im Bound Plan;
- vollständige Registrierung im Resource Ledger.

WinNAT unterstützt auf einem Host nur ein internes NAT-Präfix. Deshalb wird NAT
geteilt und nicht pro Run unkoordiniert neu erzeugt.

Ein External Switch kann die Hostverbindung beeinflussen und das Lab in das
reale LAN einbinden. Er darf nur nach expliziter Wahl der physischen NIC
angelegt oder verwendet werden. External-Switch-Tests laufen ausschließlich auf
dafür freigegebenen Runnern.

## 11. SQL-Installationsdialog und Automation

Der Wizard fragt nur Werte ab, die nicht bereits durch Katalog, Profil oder
Baseline festgelegt sind:

- SQL-Version und gewünschter Build/CU;
- Edition;
- Default- oder Named Instance;
- Feature-Set;
- Authentifizierungsmodus;
- Collation;
- SQL-Administratoren;
- Service Accounts, Default virtuelle Konten, sofern geeignet;
- Data-, Log-, TempDB- und Backup-Drive;
- Port, Firewall und Exposure;
- SQL Server Agent;
- Instant File Initialization;
- `max server memory`, MAXDOP und Cost Threshold;
- External Scripts und Sprachen;
- Servicing Policy;
- erforderliche Reboots.

Jede Auswahl wird vor der Mutation auf OS-, SQL-, Feature- und
Installationskompatibilität geprüft. Eine nicht unterstützte Kombination wird
nicht still auf eine andere Edition, Plattform oder Featuremenge geändert.

## 12. Providerneutrale Software und External Runtimes

### 12.1 Grundsatz

Python kann unter Linux und Windows verwendet werden, in Hyper-V-Gästen sowie
in Docker- und Podman-Containern. Entscheidend ist die Supportmatrix der
konkreten SQL-Version, Plattform, Distribution und Runtime.

Der Softwarevertrag modelliert mindestens:

- stabile Software-ID und Version;
- Zweck und Scope;
- OS-/Provider-/SQL-Capabilities;
- Source, Lizenz, SHA-256 und Integrity Origin;
- Installationsmethode;
- Silent-/Manual-Eignung;
- Reboot-Verhalten;
- Dependencies;
- Verification;
- Retention und Cleanup.

Beispiel des späteren Zielvertrags:

```yaml
software:
  - id: python
    version: "3.12"
    scope: sqlExternalRuntime
    packages:
      - pandas
      - numpy
    validation:
      type: spExecuteExternalScript
```

### 12.2 Providerstrategie

- Hyper-V/Windows: SQL Setup, Custom Runtime, MSI/EXE, Paketmanager oder
  verifiziertes Offline Layout;
- Hyper-V/Linux: Paketmanager, Repository oder versioniertes Archiv;
- Docker/Podman: bevorzugt versioniertes Derived Image;
- Mutation eines laufenden Containers nur als ausdrücklich weniger
  reproduzierbare Alternative;
- nach Installation echte Validation, für SQL External Runtime über
  `sp_execute_external_script`.

Seit SQL Server 2022 werden R-, Python- und Java-Runtimes nicht mehr automatisch
durch SQL Setup bereitgestellt. Der Capability Resolver muss Custom Runtimes und
die jeweilige Supportmatrix berücksichtigen.

Azure Data Studio ist seit 28. Februar 2026 nicht mehr unterstützt. Ein späterer
Softwarekatalog markiert es als `retired`; VS Code mit MSSQL Extension ist die
bevorzugte Alternative. Diese Katalogänderung erfolgt erst zusammen mit Schema,
Resolver, Doku und Test.

## 13. Bestehende Umgebungen ändern

### 13.1 Reconcile-Ablauf

`Manifest ändern -> Ist-Zustand lesen -> Diff anzeigen -> Änderungsklasse bestimmen -> anwenden -> validieren -> Lock/State aktualisieren`

Das Menü erhält eine Aktion `Bestehende Umgebung ändern`. Vor jeder Mutation
zeigt der Plan:

- alte und neue Werte;
- Änderungsklasse;
- Downtime;
- Daten- und Recovery-Risiko;
- betroffene Providerressourcen;
- erforderlichen Cleanup-/Rollback-Pfad.

### 13.2 Änderungsklassen

| Klasse | Beispiele | Vorgehen |
|---|---|---|
| `live` | SQL `max server memory`, unterstützte CPU-/RAM-Limits | direkt anwenden und validieren |
| `restart` | Hyper-V Startup RAM, Wechsel statisch/dynamisch, bestimmte CPU-Werte | geordnet stoppen, ändern, starten |
| `recreate` | Container-Ports, Mounts, Environment Variables | Container kontrolliert mit erhaltenen Volumes ersetzen |
| `reprovision` | OS, inkompatible Edition, grundlegende SQL-Features | neuen Run aus geeignetem Aufsetzpunkt erzeugen |

Providerregeln:

- Hyper-V: Dynamic Memory, statisches RAM, CPU, NICs und Drives werden je nach
  Capability live oder nach Shutdown geändert;
- Docker: unterstützte Linux-Containerlimits können live geändert werden;
  Ports und Mounts erfordern typischerweise Recreate;
- Podman: cgroup-basierte Limits können je nach Version und Betriebsart live
  änderbar sein; das Manifest bleibt die dauerhafte Wahrheit;
- Docker-Desktop- oder Podman-Machine-Ressourcen sind eine getrennte
  Host-/Engine-VM-Ebene und können alle Container betreffen.

Performance-Labs verwenden statisches RAM als Default, aber nicht als
unveränderliche Eigenschaft.

## 14. Manueller Fallback und Resume

Kann ein Download, OS-Setup, SQL-Feature oder Drittsoftwarepaket nicht
automatisiert werden:

1. State wird `MANUAL_ACTION_REQUIRED`.
2. VM und verifizierte Medien werden vorbereitet.
3. VM wird gestartet; `VMConnect` oder der genaue Aufruf wird angeboten.
4. Eine aus den gewählten Optionen erzeugte Schritt-für-Schritt-Anleitung wird
   angezeigt.
5. Vor dem Eingriff wird ein run-lokaler Production Checkpoint erzeugt.
6. Nach jedem Abschnitt prüft die Runtime technische Postconditions.
7. Nur nach erfolgreicher Prüfung entsteht der nächste Recovery Point.
8. Ein späteres Resume setzt beim ersten unvollständigen Step fort.

Vorgesehene manuelle Meilensteine:

- OS installiert;
- Guest Management erreichbar;
- OS generalisiert;
- SQL `PrepareImage` abgeschlossen;
- SQL-Instanz fertiggestellt;
- External Runtimes validiert;
- Zusatzsoftware validiert.

Der Resume-Vertrag speichert Step-ID, Preconditions, Postconditions,
Artifact-IDs, Reboot-Status, Recovery Point und erlaubte nächste Aktionen.
Secrets werden nicht in Anleitung oder State-Events geschrieben.

Die aktuell akzeptierte Generalisierungsevidenz ist ein kleines JSON-Artefakt,
dessen SHA-256 vor dem Einlesen bekannt sein muss. Es bindet sich an genau einen
Build und enthält keine Credentials:

```json
{
  "contractVersion": "1",
  "buildId": "<build-guid>",
  "scopeId": "<scope-guid>",
  "challenge": "<challenge-aus-build-state>",
  "kind": "windows-sysprep-generalize",
  "source": "powershell-direct",
  "completedAt": "2026-08-03T10:00:00Z",
  "checks": {
    "sysprepGeneralizeSucceeded": true,
    "oobeReady": true,
    "shutdownObserved": true
  }
}
```

Für reale Builds sind nur `powershell-direct` und `offline-inspection` als
Quelle zulässig. `synthetic-test` ist ausschließlich mit `synthetic-ci`
zulässig und kann nur ein `LIFECYCLE_TEST_ONLY`-Artifact erzeugen.

## 15. State-, Fehler- und Statusvertrag

Zusätzlich zum allgemeinen Lifecycle werden mindestens folgende Statusklassen
vorgesehen:

```text
MEDIA_VERIFIED
OS_BUILDING
OS_SEALED
SQL_PREPARING
SQL_PREPARED_SEALED
SPECIALIZING
DRIVES_READY
NETWORKS_READY
SQL_INSTALLING
SQL_READY
EXTENSIONS_READY
DATABASES_READY
MANUAL_ACTION_REQUIRED
REBOOT_REQUIRED
RESUME_PENDING
ARTIFACT_EXPIRED
ARTIFACT_NOT_COMPATIBLE
BASELINE_NOT_COMPATIBLE
RECOVERY_REQUIRED
```

Konsumenten werten strukturierte Codes und Results aus, nicht übersetzten
Konsolentext. Reboots von Gast oder Host dürfen den letzten erfolgreich
verifizierten Step nicht verlieren.

## 16. Resource Assessment

Das Assessment berücksichtigt vor der Mutation mindestens:

- Host-CPU und Virtualization Capability;
- statisches oder dynamisches Gast-RAM;
- OS-VHDX, Child-VHDX und zusätzliche Drives;
- feste VHDX mit vollständigem Platzbedarf;
- Builder- und temporären Buildbedarf;
- Download-, Entpack- und Medienbedarf;
- Parent- und Baseline-Generationen;
- SQL-Installations- und Updatebedarf;
- Datenbank-Restore- und `LAB_GENERATED`-Backupbedarf;
- Netzwerke, Switches, CIDRs und Portkollisionen;
- Hostreserve;
- Evaluierungsrestlaufzeit;
- erforderliche Reboots und geschätzte Downtime.

Die bisherige containerorientierte Pauschale ist für Hyper-V kein zulässiger
Kapazitätsnachweis.

## 17. Menü- und Manifestführung

Der Wizard führt durch:

1. neue Umgebung, bestehende Umgebung ändern oder Artifact-Verwaltung;
2. Provider und OS;
3. OS-Version, Edition, Installationsart und Lizenzpfad;
4. automatische Auswahl oder explizite Baseline;
5. Ressourcenprofil und Änderbarkeit;
6. OS-Drive und zusätzliche Drives;
7. Network Intents, IPAM und Exposure;
8. SQL-Version, Edition, Features und Konfiguration;
9. Software und External Runtimes;
10. Testdatenbanken;
11. Artifact Refresh Policy;
12. Planvorschau, Risiken, Downloads, Reboots und Manual Actions;
13. Bestätigung.

Jede Pfadfrage folgt der verbindlichen `x-ui`-Pfadsemantik des
Manifest-Wizard-Vertrags und erklärt Scope, Default, Bezugsbasis, aufgelösten
Wert, Erzeugung und Seiteneffekte.

Die Planvorschau begründet insbesondere:

- warum ein bestimmtes Artifact gewählt wurde;
- warum ein höherer Aufsetzpunkt verworfen wurde;
- ob eine Änderung live, nach Restart, per Recreate oder Reprovision erfolgt;
- ob Netzwerkzugriff nur intern, vom Host, im LAN oder öffentlich möglich ist;
- ob logische und physische I/O-Trennung übereinstimmen.

## 18. Implementierungswellen

### Welle 1 – Providerneutralisierung

- Resource-, Endpoint-, Drive-, Network-, Software- und Guest-Execution-Verträge;
- Containerfelder als Provider-Bindings statt allgemeiner Semantik;
- Diff-/Reconcile-Änderungsklassen;
- statische Contract Tests.

### Welle 2 – Artifact- und Medienverwaltung

- OS-, SQL- und Softwarekataloge;
- Trust, SHA-256, Manifest Lock, Ablaufdaten und Herkunft;
- immutable Registry, Referenzzählung, Refresh und Retire;
- Planvorschau ohne Mutation.

Stand 2026-08-03: Der immutable lokale VHDX-Registry-Kern, Integrity-Prüfung,
Baseline-Auswahl und portables Run-Lock sind implementiert. Acquisition aus
Herstellerquellen, Referenzzählung, Refresh und Retire bleiben offen.

### Welle 3 – Windows-OS-Image-Pipeline

- mindestens Windows Server 2022 und 2025 Evaluation, soweit verfügbar;
- Core und Desktop Experience;
- unattended Build, Reboots und Resume;
- Manual Fallback;
- `OS_SEALED`.

Stand 2026-08-03: Medienintegrität, persistenter Build-/Resume-State,
Generation-2-Builder, Secure Boot, DVD-Boot, Cleanup sowie Challenge-gebundene
Generalisierungsevidenz sind implementiert. Die Resume-Publikation prüft
VM-Auszustand, Identität, fehlende Checkpoints und VHDX-Pfadgrenze, bevor ein
reales Image immutable als `OS_SEALED` registriert wird; synthetische Medien
bleiben `LIFECYCLE_TEST_ONLY`. Nach manueller OS-Installation fuehrt die Runtime
Sysprep ueber PowerShell Direct aus, validiert
`IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, persistiert `REBOOT_REQUIRED`,
beobachtet den Gast-Shutdown und erzeugt die buildgebundene Evidenz automatisch.
Unattended Setup und Reboot-Orchestrierung waehrend der Installation bleiben
offen und führen zunächst zu `MANUAL_ACTION_REQUIRED`.

### Welle 4 – Hyper-V Vertical Slice

- eine Windows-VM;
- Generation 2, Secure Boot, Child-VHDX;
- PowerShell Direct;
- Start, Stop, Status, Remove und scope-sicherer Cleanup;
- eigener Smoke Test auf `SQL_Lab` plus `Hyper-V`.

Stand 2026-08-03: Die Lifecycle-Grundlage und der synthetische Native-Smoke-Test
sind implementiert. Die PowerShell-Direct-Sysprep-Orchestrierung und ihre
technischen Postconditions sind statisch abgedeckt; ein echter Windows-Gast-
End-to-End-Nachweis bleibt offen. Die run-lokale Windows-Specialization setzt
einen validierten Computernamen, persistiert ihren Reboot-Zustand und wartet
begrenzt auf den PowerShell-Direct-Reconnect; auch dieser Pfad ist mangels einer
realen sealed Baseline bislang nur statisch abgedeckt.

### Welle 5 – Drives und SQL Server

- zusätzliche VHDX;
- Guest-Disk-Initialisierung;
- SQL Setup und SQL SysPrep;
- `SQL_PREPARED_SEALED`;
- SQL Readiness und Configuration.

Stand 2026-08-03: Run-lokale dynamische und feste Zusatz-VHDX mit validierten
SQL-bezogenen Rollen, SCSI-Anbindung, VM-Identitätsbindung und scope-sicherem
Cleanup sind implementiert. Der VHDX-DiskIdentifier bindet Host und Gast;
PowerShell Direct orchestriert idempotente GPT-/NTFS-Initialisierung,
Allocation Unit, Volume Label und Gastpfad. Eine interne SQL-Readiness-Prüfung
validiert Dienst, Major-Version und die Online-Systemdatenbanken und persistiert
sanitierte `SQL_READY_RUN`-Evidenz. Ein echter Windows-Gast-End-to-End-Nachweis,
Manifest-Binding und alle SQL-Setup-/`CompleteImage`-Schritte bleiben offen.

### Welle 6 – Netzwerkabstraktion

- `isolated`, `hostOnly`, `nat` und `lan`;
- IPAM, DNS und Exposure Policy;
- Hyper-V-, Docker- und Podman-Bindings;
- External Switch nur auf freigegebenem Runner.

### Welle 7 – Software, External Runtimes und Samples

- Capability Resolver;
- Derived Container Images;
- Python, R und Java entsprechend Supportmatrix;
- mehrere Testdatenbanken;
- providerübergreifende Verification.

### Welle 8 – Menü, Manifest v2 und Reconcile

- geführte Topologie;
- verständliche Pfad- und Artifact-Erklärungen;
- `Bestehende Umgebung ändern`;
- Diff, Downtime und Änderungsweg;
- bestmögliche Baseline mit Begründung.

### Welle 9 – Robustheit und Tests

- Unit Tests für Resolver, IPAM, Reconcile und Cleanup;
- Unterbrechungs-, Reboot-, Resume- und Manual-Fallback-Tests;
- sequenzielle Hyper-V-Builds;
- keine parallelen VM-Builds auf demselben Runner;
- Native Smoke Tests auf `SQL_Lab` plus exaktem Capability-Label;
- External-Switch-Tests nur nach expliziter Runner-Freigabe.

Jede Welle hält Schema, Parser, Runtime, Beispiele, Tests, Root-README,
Dokumentationsindex, Known Limitations, Provider-Dokumentation und
`.ai/repo_map.yaml` synchron.

## 19. Abnahmekriterien

Der Vertrag ist implementiert, wenn:

1. mindestens ein Windows- und ein Linux-Gast aus katalogisierten, verifizierten
   Medien erstellt werden kann;
2. die Erstinstallation eine immutable `OS_SEALED`-Baseline erzeugt;
3. SQL Developer bevorzugt und Evaluation nur als Fallback gewählt wird;
4. `SQL_PREPARED_SEALED` deterministisch erzeugt und verwendet werden kann;
5. OS-Drive und zusätzliche Drives getrennt modelliert und validiert werden;
6. mehrere Network Intents samt Exposure Policy providerneutral funktionieren;
7. Python beziehungsweise andere Software nicht an Hyper-V gebunden ist;
8. automatische und manuelle Installationswege resumierbar sind;
9. bestehende Umgebungen mit sichtbarem Diff kontrolliert geändert werden;
10. RAM-, CPU-, Drive-, NIC- und unterstützte SQL-Parameter je Capability live,
    nach Restart, per Recreate oder Reprovision geändert werden;
11. Medien und Images ohne Überschreiben bestehender Artefakte erneuert werden;
12. Evaluation-Ablauf erkannt und nicht technisch umgangen wird;
13. Resolver und Planvorschau die Auswahl des besten Aufsetzpunkts begründen;
14. Cleanup ausschließlich registrierte Run-Ressourcen entfernt;
15. Docker, Podman und Hyper-V denselben übergeordneten Software-, Netzwerk-,
    Artifact- und Reconcile-Vertrag verwenden;
16. Statusdokumentation und Tests den tatsächlichen Runtimeumfang korrekt
    ausweisen.

## 20. Herstellerquellen

Die technische Detailimplementierung muss die jeweils aktuelle Primärquelle
erneut prüfen. Grundlage dieses Zielvertrags sind:

- Microsoft (2026): [Install SQL Server using SysPrep](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-using-sysprep?view=sql-server-ver17).
- Microsoft (2025): [Sysprep Command-Line Options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/sysprep-command-line-options?view=windows-11).
- Microsoft (2025): [Windows Setup States](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-states?view=windows-11).
- Microsoft (2025): [PowerShell Direct](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct).
- Microsoft (2025): [`New-VHD`](https://learn.microsoft.com/en-us/powershell/module/hyper-v/new-vhd?view=windowsserver2025-ps).
- Microsoft (2025): [`Add-VMHardDiskDrive`](https://learn.microsoft.com/en-us/powershell/module/hyper-v/add-vmharddiskdrive?view=windowsserver2025-ps).
- Microsoft (2025): [`Get-VHD`](https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vhd?view=windowsserver2025-ps).
- Microsoft (2025): [`Get-Disk`](https://learn.microsoft.com/en-us/powershell/module/storage/get-disk?view=windowsserver2025-ps).
- Microsoft (2025): [`Initialize-Disk`](https://learn.microsoft.com/en-us/powershell/module/storage/initialize-disk?view=windowsserver2025-ps).
- Microsoft (2025): [`New-Partition`](https://learn.microsoft.com/en-us/powershell/module/storage/new-partition?view=windowsserver2025-ps).
- Microsoft (2025): [`Format-Volume`](https://learn.microsoft.com/en-us/powershell/module/storage/format-volume?view=windowsserver2025-ps).
- Microsoft (2025): [Generation 2 virtual machine security](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/generation-2-virtual-machine-security-features).
- Microsoft (2025): [Dynamic Memory](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/dynamic-memory).
- Microsoft (2026): [Plan for Hyper-V networking](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-hyper-v-networking-in-windows-server).
- Microsoft (2025): [Set up a NAT network](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network).
- Microsoft (2026): [Windows Server 2025 Evaluation](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025).
- Microsoft (2026): [SQL Server 2025 editions and supported features](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2025?view=sql-server-ver17).
- Microsoft (2025): [Machine Learning Services on Windows](https://learn.microsoft.com/en-us/sql/machine-learning/install/sql-machine-learning-services-windows-install-sql-2022?view=sql-server-ver17).
- Microsoft (2026): [Machine Learning Services on Linux](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-machine-learning-sql-2022?view=sql-server-ver17).
- Microsoft (2026): [Azure Data Studio retirement](https://learn.microsoft.com/en-us/sql/tools/whats-happening-azure-data-studio?view=sql-server-ver17).
- Docker (2026): [Networking overview](https://docs.docker.com/engine/network/).
- Docker (2026): [Update container configuration](https://docs.docker.com/reference/cli/docker/container/update/).
- Podman (2026): [`podman-network-create`](https://docs.podman.io/en/latest/markdown/podman-network-create.1.html).
- Podman (2026): [`podman update`](https://docs.podman.io/en/stable/markdown/podman-update.1.html).
