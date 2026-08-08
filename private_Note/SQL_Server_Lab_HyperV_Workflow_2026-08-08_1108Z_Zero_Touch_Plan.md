# SQL_Server_Lab: Zero-Touch-Hyper-V, optionale Warm-Pool-Slots und nachträgliches Reconcile

| Merkmal | Wert |
|---|---|
| Projekt | `gecompat/SQL_Server_Lab` |
| Dokumenttyp | Verbindlicher Umsetzungsplan für Codex |
| Stand | 2026-08-08 |
| Ziel | Hyper-V-Umgebungen nach einmaliger OS-Baseline-Erstellung ohne weiteren manuellen Gasteingriff bereitstellen und später kontrolliert ändern |
| Primärer Provider | Hyper-V |
| Weitere Provider | Docker und Podman bleiben kompatible Zielprovider des übergeordneten Desired-State-/Reconcile-Vertrags |
| Status | `PLANNING_BASELINE_FOR_IMPLEMENTATION` |
| Datenschutz | Nur öffentliche Produkt-/Projektnamen und synthetische Beispiele; keine realen Hostpfade, Konten, Secrets, Logs oder Hardwaredaten |

> **Wichtige Statusabgrenzung:** Dieses Dokument ist ein Umsetzungsplan, kein Nachweis bereits vorhandener Runtime-Funktionalität. Codex muss vor jeder Welle den tatsächlichen Stand des aktuellen `main` prüfen und Dokumentation, Runtime und Tests gemeinsam fortschreiben.

---

## 1. Auftrag an Codex

Codex soll den Hyper-V-Teil von `SQL_Server_Lab` von einem Builder- und Sysprep-zentrierten Ablauf zu einem **umgebungszentrierten, vollständig automatisierbaren Desired-State-Workflow** umbauen.

Der normale Benutzer beschreibt nur die gewünschte Umgebung. Das Framework entscheidet selbst, welcher kompatible Aufsetzpunkt verwendet wird und ob eine Umgebung aus einer generalisierten OS-Baseline, einem optionalen vorbereiteten SQL-Image oder einem optionalen Warm-Pool-Slot erzeugt wird.

Nach Vorhandensein mindestens einer kompatiblen generalisierten Windows-Baseline muss eine neue Hyper-V-Umgebung ohne folgende Benutzeraktionen entstehen können:

- kein Öffnen von VMConnect;
- keine manuelle Anmeldung im Gast;
- keine manuelle Passworteingabe innerhalb von Windows;
- keine manuelle Auswahl von Region, Sprache oder Tastaturlayout;
- keine manuelle OOBE-/Telemetrieentscheidung;
- keine Bestätigung „Windows ist jetzt fertig“;
- kein manueller Weiterklick nach einem Reboot;
- kein manueller Abschluss von SQL Setup.

Manuelle Eingriffe dürfen im **Standardpfad zur Bereitstellung einer neuen Umgebung** nicht mehr vorkommen. Seltene Factory-, Trust-, Lizenz- oder Diagnoseaktionen sind davon getrennt und müssen vor Beginn der Mutation klar sichtbar sein.

### Verbindliche Kernaussage

```text
Notwendiger Kern:
MEDIA_VERIFIED
    -> OS_GENERALIZED_SEALED
    -> run-spezifischer Child-Datenträger
    -> run-spezifische Unattend-Konfiguration
    -> automatische Windows-Spezialisierung/OOBE
    -> OS_READY
    -> automatische Software-/SQL-Provisionierung
    -> READY

Optionale Beschleuniger:
OS_READY_SLOT
SQL_PREPARED_SEALED
SQL_READY_SLOT
```

Ein Warm Pool ist **nur ein Cache**. Er darf die Korrektheit oder grundsätzliche Verfügbarkeit des Provisionierungswegs nicht bestimmen.

---

## 2. Problemdefinition

### 2.1 Der bisherige Workflowbruch

Der bisherige Hyper-V-Ablauf koppelt den normalen Bereitstellungsworkflow zu eng an Windows Sysprep und nachfolgende OOBE-Schritte. Nach einem generalisierten Windows-Image muss Windows beim ersten Boot spezialisiert werden. Werden Region, Sprache, Tastatur, Konto und OOBE-Seiten nicht vollständig automatisiert, bleibt der Ablauf stehen und verlangt einen Menschen im Gast.

Das führt zu einem für eine Infrastrukturplattform ungeeigneten Ablauf:

```text
Framework startet
-> Sysprep bzw. generalisiertes Image
-> VM bootet in OOBE
-> Framework wartet
-> Benutzer öffnet VMConnect
-> Benutzer meldet sich an
-> Benutzer beantwortet Windows-Dialoge
-> Benutzer kehrt zum Framework zurück
-> Framework setzt fort
```

Dieser Workflow ist:

- nicht unattended;
- nicht für wiederholte Ad-hoc-Umgebungen geeignet;
- nicht zuverlässig resumierbar;
- schlecht automatisierbar;
- in Menü und UI unnötig technisch;
- für andere Repositories schwer konsumierbar;
- ungeeignet als Basis für Reconcile und deklarative Änderungen.

### 2.2 Zentrale Erkenntnis

Windows OOBE kann über eine passende `Unattend.xml` weitgehend beziehungsweise vollständig automatisiert werden. Daher ist nach dem Erstellen einer generalisierten OS-Baseline **kein vorab vollständig gestartetes Betriebssystem zwingend erforderlich**.

Ein vorbereiteter, bereits spezialisierter OS-Slot bleibt sinnvoll, weil er Zeit spart. Er ist aber keine funktionale Abhängigkeit.

### 2.3 Zwei verschiedene Sysprep-Begriffe strikt trennen

| Begriff | Bedeutung | Rolle im Zielsystem |
|---|---|---|
| Windows Sysprep `/generalize` | Entfernt maschinenbezogene Windows-Identität und bereitet einen klonbaren OS-Zustand vor | Nur in der Factory-/Image-Ebene; nicht als manueller Schritt im normalen Lab-Workflow |
| SQL Server SysPrep `PrepareImage`/`CompleteImage` | Installiert SQL-Binaries vor und konfiguriert später eine konkrete Instanz | Optionaler Beschleuniger; nicht zwingend für jede neue Umgebung |

Die Implementierung, Dokumentation und UI dürfen diese beiden Mechanismen nicht mehr sprachlich oder technisch vermischen.

---

## 3. Verbindliche Architekturentscheidungen

### 3.1 Benutzer beschreibt den Zielzustand, nicht den technischen Aufsetzpunkt

Der Benutzer wählt beispielsweise:

- Provider: Hyper-V;
- Betriebssystem und Version;
- SQL-Server-Version und Edition;
- Features;
- CPU und RAM;
- statisches oder dynamisches RAM;
- Laufwerke und Größen;
- Netzwerk und Erreichbarkeit;
- SQL-Konfiguration;
- Testdatenbanken;
- zusätzliche Software;
- Persistenzregeln.

Der Benutzer wählt im Standardworkflow **nicht**:

- `OS_SEALED` oder `SQL_PREPARED_SEALED`;
- `PrepareImage` oder `CompleteImage`;
- Sysprep-Modus;
- Builder-VM;
- Parent-/Child-VHDX;
- OOBE-Fortsetzung;
- Registry-Publikationsschritt.

Diese Details gehören in Resolver, Planner und Factory-Verwaltung.

### 3.2 Einmalige Baseline reicht für einen vollständigen Zero-Touch-Labpfad

Für den ersten umsetzbaren Zielzustand genügt:

1. Windows einmal installieren;
2. Baseline konfigurieren und zulässige Updates einspielen;
3. Windows mit Sysprep generalisieren und herunterfahren;
4. VHDX hashverifiziert als `OS_GENERALIZED_SEALED` registrieren;
5. ab dann jede neue Umgebung aus einem Child-Datenträger und einer run-spezifischen Unattend-Konfiguration automatisch bereitstellen.

Die erstmalige Windows-Installation darf in der ersten Implementierungsstufe noch eine kontrollierte Factory-Aktion mit manueller Installation sein. Der normale Lab-Workflow muss danach vollständig unattended sein.

Eine spätere Welle kann auch die erstmalige OS-Installation aus ISO automatisieren. Diese spätere Verbesserung darf den Zero-Touch-Labpfad nicht blockieren.

### 3.3 Sysprep liegt ausschließlich in der Factory-Ebene

Windows Sysprep darf vorkommen bei:

- Erzeugung einer neuen generalisierten OS-Baseline;
- optionaler Erzeugung eines SQL-Prepared-Images;
- Erneuerung einer Baseline nach Updates oder Evaluation-Ablauf.

Windows Sysprep darf **nicht** als normaler Schritt vorkommen bei:

- „Neue Umgebung erstellen“;
- „Bestehende Umgebung ändern“;
- „Umgebung starten“;
- „Umgebung zurücksetzen“;
- „Umgebung entfernen“.

### 3.4 Warm Pools sind optionale Performance-Caches

Verbindliche Regeln:

- Der Pool darf leer sein.
- Der Pool darf deaktiviert sein.
- Ein Cache Miss führt zum langsameren Standardpfad, nicht zum Fehler.
- Der Planner muss den Fallback automatisch wählen.
- Slots sind lokale, spezialisierte Ressourcen mit eigener Identität.
- Ein Slot darf höchstens an genau einen aktiven Run gleichzeitig verleast werden.
- Ein spezialisierter Slot darf nicht als allgemeines, parallel klonbares Image behandelt werden.
- Ein Slot wird nach Cleanup durch Verwerfen des Run-Overlays auf seinen sauberen Zustand zurückgesetzt.

### 3.5 Jede deklarative Option ist später änderbar, aber nicht zwingend live

„Nachträglich änderbar“ bedeutet:

> Der Benutzer kann den gewünschten Zielwert ändern. Das Framework ermittelt daraus einen nachvollziehbaren Änderungsplan und klassifiziert jede Änderung als `live`, `restart`, `recreate`, `reprovision` oder `unsupported`.

Nicht jede Änderung muss im bestehenden Gast in-place möglich sein. Ein Wechsel von Betriebssystem oder inkompatiblen SQL-Features darf zu einem kontrollierten Reprovision führen.

### 3.6 Baselines bleiben unveränderlich

- Registrierte Parent-VHDX sind immutable und read-only.
- Jeder normale Run schreibt nur in Child-/Overlay-Datenträger und run-lokale Zusatzdatenträger.
- Kein Reconcile mutiert eine veröffentlichte Baseline.
- Refresh erzeugt eine neue Artifact-ID.
- Cleanup entfernt nur Ressourcen des eigenen Runs beziehungsweise setzt einen exklusiv geleasten Slot zurück.

---

## 4. Zielmodell der Artefakte und Ressourcen

### 4.1 Portabel und unveränderlich: Factory Artifacts

| Zustand | Inhalt | Klonbar | Benötigt im Kern |
|---|---|---:|---:|
| `MEDIA_VERIFIED` | Verifiziertes Windows-/SQL-/Softwaremedium mit Herkunft, Lizenzmetadaten und SHA-256 | nein | ja, wenn neue Baselines gebaut werden |
| `OS_GENERALIZED_SEALED` | Installiertes, generalisiertes Windows vor der run-spezifischen Spezialisierung | ja | ja |
| `SQL_PREPARED_SEALED` | Generalisiertes Windows mit SQL-Binaries aus `PrepareImage`, aber ohne konkrete SQL-Instanz | ja | nein; optionaler Beschleuniger |

### 4.2 Lokal und identitätsgebunden: Warm-Pool-Slots

| Zustand | Inhalt | Parallel klonbar | Benötigt im Kern |
|---|---|---:|---:|
| `OS_READY_SLOT` | Vollständig spezialisiertes Windows mit eigener Identität und geprüfter Guest-Erreichbarkeit | nein | nein |
| `SQL_READY_SLOT` | Vollständig spezialisiertes Windows mit vollständig installierter und geprüfter SQL-Instanz | nein | nein |

Ein Slot ist kein allgemein portables Golden Image. Er ist eine konkrete lokale, ausgeschaltete und saubere Ressourcenbasis mit stabiler Identität und Lease-Vertrag.

### 4.3 Run-lokal und verwerfbar: Lab-Ressourcen

| Ressource | Zweck | Cleanup |
|---|---|---|
| `RUN_OS_OVERLAY` | Alle Änderungen am Systemdatenträger eines konkreten Runs | löschen |
| `RUN_EPHEMERAL_DATA_DISK` | Wegwerfbare Daten-, Log-, TempDB- oder Arbeitsdatenträger | löschen |
| `PERSISTENT_DATA_DISK` | Bewusst beibehaltene Daten eines benannten Labs | behalten, separat registrieren |
| `RUN_UNATTEND_PAYLOAD` | Run-spezifische OOBE-/Account-/Locale-Konfiguration | nach erfolgreicher Spezialisierung im Gast entfernen; Hostkopie sicher entfernen |
| `RUN_SECRET_MATERIAL` | Kurzlebige Zugangsdaten und Setup-Secrets | niemals ins Repository; geschützt speichern und nach Policy entfernen |
| `RUN_STATE` | Idempotente Workflow-, Reboot-, Lease- und Validierungszustände | lokal gemäß State-Vertrag |

### 4.4 Empfohlener Zustandsgraph

```text
MEDIA_VERIFIED
    |
    +--> OS_GENERALIZED_SEALED ------------------------------+
    |          |                                              |
    |          +--> direkte Lab-Spezialisierung               |
    |          |      -> OS_READY                              |
    |          |      -> SQL unattended installieren          |
    |          |      -> SQL_READY                             |
    |          |                                              |
    |          +--> OS_READY_SLOT -----------------------------+
    |                                                         |
    +--> optional SQL_PREPARED_SEALED                         |
               |                                              |
               +--> Unattend + CompleteImage -> SQL_READY     |
                                                              |
    optional SQL_READY_SLOT ----------------------------------+
                                                              |
                                                              v
                                                     LAB_RUN + OVERLAY
                                                              |
                                                              v
                                                            READY
```

---

## 5. Resolver: Auswahl des schnellsten kompatiblen Pfads

Der Benutzer darf den technischen Pfad nicht selbst zusammensetzen müssen. Ein deterministischer Resolver wählt nach Kompatibilität und Restaufwand.

### 5.1 Verbindliche Auswahlreihenfolge

1. **Freier, exakt kompatibler `SQL_READY_SLOT`**
   - schnellster Pfad;
   - Slot exklusiv leasen;
   - Run-Overlay erzeugen;
   - run-spezifische Abweichungen anwenden.

2. **Kompatibles `SQL_PREPARED_SEALED`**
   - Child erzeugen;
   - Windows per Unattend spezialisieren;
   - SQL `CompleteImage` unattended ausführen;
   - gewünschte Konfiguration anwenden.

3. **Freier, kompatibler `OS_READY_SLOT`**
   - Slot exklusiv leasen;
   - Run-Overlay erzeugen;
   - SQL unattended installieren;
   - gewünschte Konfiguration anwenden.

4. **Kompatibles `OS_GENERALIZED_SEALED`**
   - Child erzeugen;
   - Unattend injizieren;
   - Windows automatisch spezialisieren;
   - SQL unattended installieren;
   - gewünschte Konfiguration anwenden.

5. **Verifiziertes Installationsmedium vorhanden und Factory-Build erlaubt**
   - neue Baseline erzeugen;
   - danach erneut planen;
   - in der ersten Welle darf dieser Factory-Schritt noch eine explizite einmalige manuelle OS-Installation enthalten.

6. **Kein kompatibler Aufsetzpunkt**
   - fail-closed mit einer konkreten, verständlichen Missing-Artifact-Diagnose;
   - keine versteckte OOBE- oder VMConnect-Aufforderung.

### 5.2 Kompatibilitätsschlüssel

Mindestens folgende Merkmale müssen berücksichtigt werden:

#### Betriebssystem

- Produktfamilie;
- Version und Build;
- Edition;
- Core/Desktop Experience beziehungsweise Installationsart;
- Sprache und Architektur;
- Lizenztyp;
- Evaluation-Ablauf und Mindestrestlaufzeit;
- Secure-Boot-/Generation-2-Kompatibilität;
- Servicing-/Patchstand;
- Guest-Management-Fähigkeit.

#### SQL Server

- Hauptversion und Build/CU;
- Edition;
- Plattform;
- Features;
- Instanztyp und Instanzname;
- Collation, falls install-time relevant;
- Authentifizierungsmodus;
- benötigte Service-Account-Klasse;
- PrepareImage-/CompleteImage-Eignung;
- Lizenzstatus;
- erwartetes Reboot-Verhalten.

#### Slot-spezifisch

- Lease-Status;
- letzter erfolgreicher Health Check;
- kein ausstehender Reboot;
- Baseline-Hash unverändert;
- kein Drift außerhalb des zugelassenen Slotzustands;
- Restlaufzeit bei Evaluation;
- exakte oder klar definierte kompatible Konfiguration.

### 5.3 Planner-Ausgabe

Vor der Mutation muss der Planner zeigen:

- gewünschte Umgebung;
- gewählter Aufsetzpunkt;
- warum dieser kompatibel ist;
- warum schnellere Kandidaten nicht verwendet werden;
- ob ein Pool-Slot verwendet wird;
- erforderliche Reboots;
- persistente und verwerfbare Datenträger;
- erwartete Änderungsklassen;
- erforderliche Trust-/Lizenzentscheidungen;
- mögliche Downtime bei Reconcile;
- Datenübernahmeweg bei Reprovision;
- klare Aussage, ob der Ablauf vollständig unattended ist.

---

## 6. Unattend-Architektur

### 6.1 Zweck

Die `Unattend.xml` muss die Windows-Spezialisierung so weit automatisieren, dass nach dem ersten Boot keine OOBE-Seite auf menschliche Eingabe wartet.

Mindestens abzudecken sind:

- Computername;
- UI-Sprache;
- System-Locale;
- User-Locale;
- Tastaturlayout/Input-Locale;
- Zeitzone;
- lokales administratives Konto oder kontrollierte Aktivierung eines geeigneten Kontos;
- run-spezifisches Passwort;
- auszublendende OOBE-Seiten;
- Datenschutz-/Express-Settings gemäß expliziter Projektpolicy;
- EULA-/Lizenzbehandlung nur im rechtlich zulässigen Rahmen;
- Netzwerkverhalten für isolierte und host-erreichbare VMs;
- sichere Übergabe an die nachgelagerte Guest-Orchestrierung.

### 6.2 Verbindliche Sicherheitsregeln

- Kein Passwort wird in die generalisierte Parent-VHDX eingebaut.
- Jedes Lab erhält ein eigenes generiertes oder explizit übergebenes Secret.
- Das Manifest enthält nur eine `secretRef`, nie das Secret selbst.
- Die Unattend-Datei wird ausschließlich run-spezifisch erzeugt.
- Die Unattend-Datei wird nur in den Child-/Run-Kontext injiziert.
- Die Unattend-Datei wird nach erfolgreicher Spezialisierung im Gast entfernt.
- Hostseitige temporäre Kopien werden nach Abschluss sicher entfernt.
- Secrets erscheinen nicht in Logs, Evidence, Fehlermeldungen, VM-Notes, Manifest Lock oder Git.
- AutoLogon ist im Standardpfad zu vermeiden. Wird es für einen nachgewiesenen Spezialfall benötigt, muss es zeitlich begrenzt und nach dem ersten erfolgreichen Lauf deaktiviert werden.
- Eine bloße XML-Codierung oder `PlainText=false` darf nicht als ausreichender Secret-Schutz betrachtet werden; die Schutzwirkung entsteht primär durch Run-Isolation, Zugriffsschutz und kurze Lebensdauer.

### 6.3 Delivery-Strategie

Der Code soll eine klar abgegrenzte `UnattendDelivery`-Komponente erhalten.

**Primärer erster Implementierungspfad:**

- Child-VHDX offline mounten;
- Antwortdatei an einer für die konkrete Windows-Version unterstützten Stelle ablegen;
- VHDX sauber dismounten;
- vor dem Start prüfen, dass ausschließlich der Child-Datenträger verändert wurde.

Wenn der Runner nicht über die dafür notwendigen erhöhten Rechte verfügt, muss der Standardpfad im Preflight fail-closed enden. Er darf nicht still in einen manuellen OOBE-Pfad wechseln.

Eine spätere alternative Delivery-Methode über ein run-lokales virtuelles Medium darf ergänzt werden, aber erst nach echtem End-to-End-Nachweis.

### 6.4 Keine problematischen Abkürzungen

- `SkipMachineOOBE` nicht als pauschale Abkürzung verwenden.
- Stattdessen die von Windows vorgesehenen OOBE-/International-/UserAccounts-Einstellungen explizit konfigurieren.
- Run-spezifische Antwortdateien nicht in die sealed Parent-Baseline schreiben.
- Die Parent-Baseline nach Sysprep nie erneut booten.
- Bei fehlerhafter Unattend-Verarbeitung nicht automatisch VMConnect öffnen und die Umgebung als „teilweise fertig“ deklarieren.

### 6.5 Readiness Gates nach dem ersten Boot

`OS_READY` darf erst gesetzt werden, wenn mindestens Folgendes bestätigt wurde:

- VM läuft;
- Hyper-V Heartbeat ist gesund;
- Windows-Spezialisierung ist abgeschlossen;
- PowerShell Direct funktioniert mit dem run-spezifischen Konto;
- gewünschter Computername ist aktiv;
- gewünschte Sprache/Locale/Tastaturwerte sind nachweisbar;
- kein OOBE-Dialog blockiert;
- Antwortdatei und temporäre Setup-Artefakte sind entfernt oder zur sicheren Entfernung vorgemerkt;
- kein ungeplanter Pending Reboot besteht;
- run-spezifische Identitätswerte unterscheiden sich von anderen gleichzeitig provisionierten VMs;
- State und Evidence enthalten keine Secrets.

---

## 7. SQL-Provisionierungsstrategie

### 7.1 Standardpfad ohne SQL-Vorlage

Ein vollständig spezialisiertes Windows kann SQL Server unattended installieren. Dieser Pfad ist der notwendige Fallback und muss unabhängig von SQL-Warm-Pool-Slots funktionieren.

Ablauf:

```text
OS_READY
-> SQL-Medium verifizieren und run-lokal verfügbar machen
-> SQL Setup Configuration erzeugen
-> Setup quiet/unattended starten
-> Exit Code und Setup Logs auswerten
-> geplante Reboots persistieren
-> nach Reboot idempotent fortsetzen
-> SQL Service und Systemdatenbanken prüfen
-> TCP/WMI/Firewall nach Desired State konfigurieren
-> SQL-Konfiguration anwenden
-> SQL_READY
```

### 7.2 SQL Setup als resumierbarer Workflow

Der SQL-Workflow muss:

- vor jedem mutierenden Schritt State persistieren;
- Setup nicht doppelt ausführen;
- Reboot-Codes und Pending-Reboot-Zustände unterscheiden;
- eine tatsächlich neue Bootzeit nachweisen;
- Setup-Logs nur lokal und datenschutzkonform halten;
- Secrets aus Setup-Parametern und Logs maskieren;
- Fehler mit konkreter Phase und Logpfad-Hinweis melden, ohne Logdaten ins Repository zu schreiben;
- SQL-Version, Edition und erwartete Features nach Abschluss verifizieren;
- fehlgeschlagene oder unvollständige Installationen nicht als wiederverwendbaren Slot registrieren.

### 7.3 `SQL_PREPARED_SEALED` bleibt optional erhalten

Der bestehende `PrepareImage`-/`CompleteImage`-Ansatz soll nicht entfernt werden. Er wird als optionaler Factory-Beschleuniger eingeordnet.

Vorteile:

- SQL-Binaries müssen nicht bei jedem Run vollständig installiert werden;
- mehrere eindeutige, spezialisierte VMs können aus einer generalisierten Vorlage entstehen;
- die konkrete SQL-Instanz wird erst run-spezifisch abgeschlossen.

Grenzen:

- nicht alle Features und Kombinationen unterstützen SQL Server SysPrep;
- Fehler bei Prepare/Complete benötigen klare Recovery-/Neuaufbaupfade;
- Windows-Generalize bleibt Factory-Aufgabe;
- der normale Benutzer darf diesen Mechanismus nicht auswählen müssen.

### 7.4 `SQL_READY_SLOT` als schnellster Cache

Ein `SQL_READY_SLOT` enthält eine vollständige, konkrete SQL-Installation. Er darf nur verwendet werden, wenn die angeforderte Umgebung exakt oder gemäß klarer Kompatibilitätsregeln passt.

Verbindlich:

- keine parallele Mehrfachnutzung desselben Slots;
- kein Klonen in mehrere gleichzeitig aktive identitätsgleiche VMs;
- Lease vor jeder Mutation atomar setzen;
- Run-Änderungen ausschließlich im Overlay;
- nach Cleanup Overlay verwerfen;
- Baseline-Zustand erneut validieren;
- bei Drift Slot sperren und neu aufbauen;
- bei inkompatibler SQL-Konfiguration auf einen anderen Pfad zurückfallen.

---

## 8. Warm-Pool-Modell

### 8.1 Zweck

Warm Pools reduzieren Bereitstellungszeit. Sie ersetzen weder generalisierte Images noch den Standard-Provisionierungsweg.

### 8.2 Slot-Lifecycle

```text
CREATING
-> SPECIALIZING
-> VALIDATING
-> READY
-> LEASED
-> IN_USE
-> RESETTING
-> VALIDATING
-> READY

Fehlerpfade:
ANY -> QUARANTINED -> REBUILD_REQUIRED
```

### 8.3 Lease-Vertrag

Jeder Slot benötigt mindestens:

- stabile Slot-ID;
- Slot-Typ `os-ready` oder `sql-ready`;
- Basis-Artifact-ID und SHA-256;
- lokale VM-/VHDX-Identität;
- Kompatibilitätsschlüssel;
- Status;
- Lease-Owner/Run-ID;
- Lease-Zeitpunkt;
- Health-/Drift-Nachweis;
- Evaluation-Ablauf;
- Reset-Generation;
- letzter erfolgreicher Reset;
- Quarantänegrund.

Das Leasen muss hostweit atomar erfolgen. Zwei parallele Provisionierungen dürfen niemals denselben Slot erhalten.

### 8.4 Reset-Vertrag

Beim Entfernen eines Runs aus einem Slot:

1. VM geordnet stoppen;
2. run-lokale Zusatzdatenträger lösen;
3. persistente Datenträger gemäß Policy behalten;
4. Run-Overlay entfernen;
5. neues sauberes Overlay vom Slot-Root erzeugen oder die Slot-VM auf ihren definierten Rootzustand zurücksetzen;
6. VM-Hardware auf Slot-Default zurücksetzen;
7. temporäre NICs, ISO-Mounts und Ports entfernen;
8. Slot-Health und Baseline-Hash prüfen;
9. Lease erst danach freigeben;
10. bei Abweichung Slot quarantänisieren statt freigeben.

### 8.5 Pool-Policy

Beispielhafte, noch nicht verbindliche Konfiguration:

```yaml
warmPool:
  enabled: true
  osSlots:
    - compatibilityRef: windows-server-2025-standard-desktop-en-us
      minimumReady: 2
      maximumReady: 4
  sqlSlots:
    - compatibilityRef: windows-server-2025-sql-2025-developer-engine
      minimumReady: 1
      maximumReady: 2
  replenish: onDemand
  allowFallback: true
```

`allowFallback` muss im Standard immer `true` sein. Ein Pool-Fehler darf keine normale Provisionierung verhindern, solange ein generalisiertes kompatibles Image vorhanden ist.

---

## 9. Desired State und Manifest

### 9.1 Grundsatz

Das Manifest beschreibt den gewünschten Zustand einer Umgebung. Es beschreibt nicht die Reihenfolge einzelner Installationsschritte.

Illustratives Zielmodell, noch kein fertiges Schema:

```yaml
schemaVersion: 2
name: sql-lab-example
provider: hyperv

operatingSystem:
  family: windows-server
  version: "2025"
  edition: standard
  installationType: desktop-experience
  uiLanguage: en-US
  systemLocale: de-AT
  userLocale: de-AT
  inputLocale: de-AT
  timeZone: Central Europe Standard Time

identity:
  computerName: SQLLAB01
  administratorSecretRef: SQL_SERVER_LAB_SECRET_GUEST_PASSWORD

sqlServer:
  version: "2025"
  edition: developer
  instanceName: MSSQLSERVER
  features:
    - database-engine
    - full-text
  collation: Latin1_General_100_CI_AS_SC
  authenticationMode: mixed
  saSecretRef: SQL_SERVER_LAB_SECRET_SA_PASSWORD

resources:
  processorCount: 8
  memory:
    mode: static
    startupMB: 16384
  drives:
    - role: data
      sizeGB: 100
      persistence: ephemeral
    - role: log
      sizeGB: 50
      persistence: ephemeral

network:
  intent: host-access
  sqlPort: 1433

provisioning:
  imagePolicy: best-compatible
  allowWarmPool: true
  requireUnattended: true
  resetPolicy: discard-overlay

serverConfig:
  maxServerMemoryMB: 12288
  maxDop: 4

databases:
  - sampleRef: adventureworks-compatible
```

### 9.2 Trennung von Desired State, Plan und Actual State

- **Desired State:** Was der Benutzer haben möchte.
- **Actual State:** Was Hyper-V, Windows und SQL tatsächlich besitzen.
- **Plan:** Wie die Differenz sicher umgesetzt wird.
- **Lock:** Welche konkreten Artifacts, Builds, Hashes und Aufsetzpunkte für diesen Run gewählt wurden.

Keines dieser Artefakte enthält Klartextsecrets.

---

## 10. Reconcile: Bestehende Umgebungen ändern

### 10.1 Ablauf

```text
Manifest ändern
-> Desired State validieren
-> Actual State erfassen
-> Diff erzeugen
-> Änderungsklassen bestimmen
-> Downtime und Datenwirkung anzeigen
-> Plan bestätigen
-> Änderungen anwenden
-> Reboots/Recreate/Reprovision resumierbar ausführen
-> validieren
-> State und Lock aktualisieren
```

### 10.2 Änderungsklassen

| Klasse | Typische Beispiele | Verhalten |
|---|---|---|
| `live` | SQL `max server memory`, MaxDOP, bestimmte SQL-Optionen, neue Testdatenbank | direkt anwenden und validieren |
| `restart` | Wechsel statisch/dynamisch, bestimmte RAM-/CPU-Änderungen, Computername | geordnet stoppen beziehungsweise Gast rebooten, ändern, wieder starten |
| `recreate` | VM-/Container-nahe Eigenschaften, die einen Ersatz der Laufzeitressource erfordern, aber dieselbe fachliche Umgebung behalten | neue Laufzeitressource mit erhaltenen persistenten Daten erstellen |
| `reprovision` | Betriebssystemwechsel, inkompatible SQL-Version/Edition/Features, grundlegende Installationsänderung | neue Umgebung aus bestem kompatiblem Aufsetzpunkt erstellen, Daten kontrolliert übernehmen, alte erst nach Abnahme entfernen |
| `unsupported` | technisch, rechtlich oder sicherheitlich nicht zulässige Änderung | vor Mutation mit konkreter Begründung ablehnen |

### 10.3 Beispielmatrix für Hyper-V

| Änderung | Erwartete Klasse, capability-abhängig |
|---|---|
| SQL `max server memory` | `live` |
| MaxDOP | `live` |
| Testdatenbank hinzufügen/entfernen | `live` oder kontrollierter Datenbank-Cleanup |
| vCPU ändern | `live` oder `restart` |
| Startup RAM ändern | meist `restart` |
| statisch auf Dynamic Memory wechseln | `restart` |
| zusätzliche VHDX hinzufügen | `live` oder `restart` |
| bestehende VHDX vergrößern | `live`/`restart` plus Gast-Erweiterung |
| NIC/Switch ändern | `live` oder `restart` |
| SQL-Port ändern | `live` plus Service-Restart/Firewall-Reconcile |
| SQL Feature hinzufügen | Setup-Maintenance, `restart` oder `reprovision` |
| SQL 2022 auf 2025 | `reprovision` beziehungsweise expliziter Upgradepfad, niemals stillschweigend |
| Windows Server 2022 auf 2025 | `reprovision` |
| Core auf Desktop Experience | `reprovision` |
| Persistenzmodus ändern | `recreate` oder Datenmigration |

Die konkrete Klasse wird nicht allein aus dieser Tabelle abgeleitet, sondern aus Provider- und Versions-Capabilities.

### 10.4 Reprovision ist ein gültiger Änderungsweg

Reprovision bedeutet nicht „nicht unterstützt“. Der Plan muss:

1. neue Zielumgebung parallel oder kontrolliert sequenziell erstellen;
2. persistente Daten über einen zulässigen Weg übernehmen;
3. SQL- und Datenkompatibilität prüfen;
4. neue Umgebung vollständig validieren;
5. Umschaltung sichtbar machen;
6. alte Umgebung erst nach erfolgreicher Abnahme entfernen oder als Rollback beibehalten.

Für SQL-Daten gilt grundsätzlich:

- bevorzugt Backup/Restore;
- keine blinde Wiederverwendung von MDF/LDF über inkompatible Versionsgrenzen;
- Downgradepfade explizit ablehnen;
- TDE-/Zertifikatsanforderungen gesondert behandeln;
- persistente Daten nie durch normales Run-Cleanup entfernen.

---

## 11. Ziel-Workflow in CLI und UI

### 11.1 Hauptmenü

Das Hauptmenü soll auf Benutzeraufgaben reduziert werden:

1. **Neue Umgebung erstellen**
2. **Bestehende Umgebung ändern**
3. **Umgebungen verwalten**
4. **Vorlagen und Installationsmedien verwalten**
5. **Erweitert und Diagnose**

Builder-, Sysprep-, PrepareImage- und Registry-Aktionen gehören nicht in die erste Ebene.

### 11.2 Neue Umgebung erstellen

Geführter Ablauf:

1. Zweck beziehungsweise Profil wählen;
2. Provider oder automatische Auswahl;
3. Betriebssystem;
4. SQL-Version/Edition/Features;
5. Ressourcen;
6. Storage und Persistenz;
7. Netzwerk und Exposure;
8. SQL-Konfiguration;
9. Testdatenbanken und Software;
10. Zusammenfassung und Planvorschau;
11. Bereitstellen.

Der Planner zeigt den intern gewählten Pfad, verlangt aber keine technische Auswahl.

### 11.3 Bestehende Umgebung ändern

- Umgebung auswählen;
- aktuelle Konfiguration anzeigen;
- Werte bearbeiten;
- Diff und Änderungsklassen zeigen;
- Downtime, Datenwirkung und Reprovision klar ausweisen;
- Plan anwenden;
- Status verfolgen.

### 11.4 Keine versteckten Mid-Run-Prompts

Alle erforderlichen Entscheidungen müssen vor der ersten Mutation geklärt sein:

- Trust unbekannter Bytes;
- Lizenzbestätigung;
- gewünschte Secret-Quelle;
- Datenverlust-/Reprovision-Bestätigung;
- bewusste Host-Exposure;
- bewusste persistente Daten.

Danach läuft der Job unattended. Tritt ein unerwarteter Zustand ein, geht er auf `FAILED`, `RECOVERY_REQUIRED` oder einen klaren Factory-spezifischen Status. Er darf nicht während eines normalen Jobs plötzlich eine Konsoleneingabe verlangen.

### 11.5 VMConnect nur als Diagnosewerkzeug

VMConnect bleibt verfügbar unter **Erweitert und Diagnose**. Es ist kein regulärer Provisionierungsschritt und kein Akzeptanzkriterium für einen erfolgreichen Standardlauf.

---

## 12. Zustandsmaschine und Resume

Empfohlene, zu harmonisierende Zustände:

```text
REQUESTED
PLANNED
PRECHECK_RUNNING
PRECHECK_FAILED
ARTIFACT_RESOLVED
SLOT_LEASED
PROVISIONING_VM
INJECTING_UNATTEND
OS_SPECIALIZING
OS_REBOOT_REQUIRED
OS_READY
SQL_INSTALLING
SQL_REBOOT_REQUIRED
SQL_COMPLETING
SQL_READY
CONFIGURING
DATABASES_PROVISIONING
VALIDATING
READY
STOPPED
RECONCILE_PLANNED
RECONCILING
RECREATE_REQUIRED
REPROVISION_REQUIRED
RESETTING
FAILED
RECOVERY_REQUIRED
CLEANUP_PENDING
CLEANUP_RUNNING
REMOVED
```

### Verbindliche Regeln

- Zustand vor jeder Mutation persistieren.
- Jeder Schritt muss idempotent oder über eindeutige Receipts geschützt sein.
- Reboot vor dem Auslösen persistieren.
- Nach Reboot muss eine neue Bootzeit oder ein äquivalenter Nachweis erbracht werden.
- Ein Prozessabbruch darf nicht zu einer zweiten SQL-Installation oder doppeltem CompleteImage führen.
- Slot-Leases werden bei Prozessabbruch nicht still freigegeben.
- Recovery muss den tatsächlichen Hyper-V-/Guest-/SQL-Zustand erneut erfassen.
- `MANUAL_ACTION_REQUIRED` ist im normalen Labpfad nicht zulässig. Dieser Status darf nur in klar abgegrenzten Factory-/Legacy-/Diagnosepfaden vorkommen.

---

## 13. Umsetzung in Wellen

Jede Welle muss einen konsistenten Stand liefern. Nach jeder Welle:

- Tests ausführen;
- Dokumentation und `.ai/repo_map.yaml` aktualisieren;
- `KNOWN_LIMITATIONS.md` an die Realität anpassen;
- Datenschutzprüfung durchführen;
- Commit mit Präfix `Codex:`;
- nur bei konsistentem Stand in `main` integrieren.

### Welle 0 – Ist-Abgleich und Architekturbindung

**Ziel:** Keine neue Funktion, sondern Widersprüche entfernen und den neuen Zielvertrag verbindlich machen.

Aufgaben:

- aktuellen `main` prüfen;
- bestehende Hyper-V-Builder-, Prepared-Image-, OOBE- und Labpfade inventarisieren;
- feststellen, welche Unattend-/Offline-Injection-Funktionen bereits existieren;
- aktuelle manuelle Eingriffspunkte exakt dokumentieren;
- `SQL_PREPARED_SEALED` als optionalen Accelerator statt zwingendes Primärmodell einordnen;
- Warm Pool als optionalen Cache definieren;
- veraltete Aussagen in Architektur-, How-to- und UI-Dokumentation kennzeichnen;
- keine Runtime-Funktion als implementiert deklarieren, die nur geplant ist.

**Done-Kriterien:**

- Architekturvertrag enthält die in diesem Dokument definierten Ebenen;
- `KNOWN_LIMITATIONS.md` nennt den realen manuellen Restpfad;
- Repo-Metadaten stimmen mit der Runtime überein;
- statische Dokumentationsprüfungen sind grün.

**Empfohlener Commit:**

```text
Codex: bind zero-touch Hyper-V target architecture
```

### Welle 1 – Desired-State-, Plan- und Artifact-Verträge

**Ziel:** Maschinenlesbare Verträge vor Runtime-Ausbau.

Aufgaben:

- `OS_GENERALIZED_SEALED`, `SQL_PREPARED_SEALED`, `OS_READY_SLOT`, `SQL_READY_SLOT` und Run-Overlay klar modellieren;
- Slots von portablen Artifacts trennen;
- Desired State, Actual State, Diff, Plan und Lock getrennt definieren;
- Änderungsklassen einführen;
- Manifest-/Schema-Erweiterungen nur mit Runtime-Status markieren;
- Migration bestehender Registry-Einträge planen;
- Capability-Schlüssel für OS und SQL definieren;
- keine Secrets in neuen Verträgen zulassen.

**Tests:**

- Schema-/Contract-Tests;
- Serialisierung/Deserialisierung;
- unbekannte Major-Version ablehnen;
- alte Registry-Daten read-only weiter lesen;
- Slot und Artifact nicht verwechseln.

**Done-Kriterien:**

- Planner kann ohne Mutation einen vollständigen Plan erzeugen;
- Pool deaktiviert/leer ist ein gültiger Zustand;
- Resolver kann einen Standardfallback planen.

**Empfohlener Commit:**

```text
Codex: add Hyper-V desired state and artifact contracts
```

### Welle 2 – Unattend Generator und sichere Delivery

**Ziel:** Run-spezifische OOBE-Automatisierung als isolierte Komponente.

Aufgaben:

- zentrale Unattend-Generatorfunktion erstellen;
- OS-/Versionsprofile aus Katalogdaten ableiten;
- Sprache, Locale, Tastatur, Zeitzone, Computername und Konto abbilden;
- Secret-Referenzen zur Laufzeit auflösen;
- Antwortdatei nur run-lokal erzeugen;
- Offline-Injection ausschließlich in Child-VHDX;
- sichere Entfernung nach Erfolg;
- Preflight für Mount-/Elevationsrechte;
- keine automatische manuelle Fallback-Route;
- strukturiertes, secretfreies Diagnostic Receipt erzeugen.

**Vorgeschlagene neue Komponente:**

```text
Private/WindowsUnattend.ps1
```

Der tatsächliche Dateiname ist an bestehende Repo-Konventionen anzupassen.

**Tests:**

- XML-Struktur;
- alle Pflichtwerte;
- keine Secretwerte in Logs/State;
- Parent-Hash vor/nach Injection identisch;
- Child enthält Payload;
- ungültige Locale wird vor Mutation abgelehnt;
- fehlende Mount-Rechte führen zu Preflight-Fehler;
- `SkipMachineOOBE` wird nicht erzeugt.

**Done-Kriterien:**

- eine Unattend-Datei kann deterministisch aus einem synthetischen Desired State erzeugt werden;
- Secretmaterial ist nur im Laufzeitkontext vorhanden;
- kein Parent wird verändert.

**Empfohlener Commit:**

```text
Codex: generate secure per-run Windows unattend payloads
```

### Welle 3 – Zero-Touch-OS-Spezialisierung aus generalisierter Baseline

**Ziel:** Wichtigster MVP. Eine generalisierte Windows-Baseline erzeugt ohne VMConnect eine vollständig verwaltbare Windows-VM.

Aufgaben:

- kompatibles `OS_GENERALIZED_SEALED` auswählen;
- differenzierenden Child-Datenträger erzeugen;
- Unattend injizieren;
- VM-Hardware und Netzwerk erzeugen;
- VM starten;
- OOBE/Specialize mit Timeout überwachen;
- PowerShell Direct readiness prüfen;
- Reboot/Resume unterstützen;
- Guest-Metadaten und Locale validieren;
- Unattend-/Setup-Payload entfernen;
- `OS_READY` setzen;
- bei Fehlern sauber diagnostizieren und Cleanup ermöglichen.

**Erster realer Referenzfall:**

```text
Windows Server 2025
Generation 2
Desktop Experience oder die im bestehenden Repo primär unterstützte Variante
interner Hyper-V-Switch
run-spezifischer Administrator
kein VMConnect
```

**Realtest-Akzeptanz:**

- Benutzer startet die Bereitstellung und greift danach nicht in die VM ein;
- Region/Sprache/Tastatur/Konto sind korrekt;
- PowerShell Direct funktioniert;
- Parent-VHDX-Hash bleibt unverändert;
- zwei parallele Child-VMs besitzen getrennte Identitäten;
- Cleanup entfernt nur run-lokale Ressourcen.

**Done-Kriterien:**

- Standard-Hyper-V-OS-Provisionierung hat keinen manuellen Gasteingriff mehr;
- UI/CLI zeigt keinen „Windows jetzt fertigstellen“-Schritt;
- Known Limitations nennt nur noch echte verbleibende Grenzen.

**Empfohlener Commit:**

```text
Codex: provision Windows Hyper-V labs without manual OOBE
```

### Welle 4 – Unattended SQL-Installation auf `OS_READY`

**Ziel:** Vollständige SQL-Umgebung ohne SQL-Vorlage und ohne menschlichen Eingriff.

Aufgaben:

- SQL-Medium aus Katalog/Media Root auflösen;
- Setup-Konfiguration aus Desired State erzeugen;
- SQL Setup im Quiet-Modus ausführen;
- Feature-/Edition-/Collation-Parameter validieren;
- Setup-Exitcodes klassifizieren;
- Reboot-Resume implementieren;
- Setup-Receipts gegen Doppelinstallation verwenden;
- SQL Services, Version, Edition, Features und Systemdatenbanken prüfen;
- TCP, WMI, Firewall, Authentifizierung und SQL-Konfiguration anwenden;
- Testdatenbanken über bestehende Artifact-/Trust-Pfade installieren.

**Testreihenfolge:**

1. SQL Server 2025, primär unterstützte Developer-Variante;
2. SQL Server 2022;
3. SQL Server 2019;
4. zusätzliche Feature-Kombinationen nur nach eigener Capability-Validierung.

**Done-Kriterien:**

- `OS_GENERALIZED_SEALED -> READY` funktioniert ohne SQL-Prepared-Image;
- Reboot unterbricht den Workflow nicht;
- keine Passwörter in Setup-Logs/State;
- fehlgeschlagene Installation wird nicht als READY oder Slot registriert.

**Empfohlener Commit:**

```text
Codex: install SQL Server unattended on specialized Hyper-V guests
```

### Welle 5 – Resolver und bestehendes SQL-Prepared-Image integrieren

**Ziel:** Schnellsten kompatiblen Pfad automatisch auswählen.

Aufgaben:

- bestehende `SQL_PREPARED_SEALED`-Runtime als optionalen Pfad integrieren;
- Resolver-Reihenfolge implementieren;
- Auswahl begründen;
- Cache Miss und Inkompatibilität transparent behandeln;
- direkte SQL-Installation als verlässlichen Fallback behalten;
- keine UI-Auswahl „PrepareImage vs. Vollinstallation“ im Standardworkflow.

**Tests:**

- SQL-Ready-Slot gewinnt bei exaktem Match;
- SQL-Prepared gewinnt ohne SQL-Ready-Slot;
- OS-Ready-Slot gewinnt vor kalter OS-Spezialisierung, wenn SQL noch installiert werden muss;
- generalisierte OS-Baseline funktioniert ohne jeden Slot;
- inkompatibler Accelerator wird begründet verworfen;
- Poolfehler blockiert Fallback nicht.

**Done-Kriterien:**

- Benutzer erhält dieselbe Desired-State-Oberfläche unabhängig vom internen Pfad;
- Plan und Lock zeigen den gewählten Aufsetzpunkt;
- Standardpfad bleibt ohne Cache funktionsfähig.

**Empfohlener Commit:**

```text
Codex: resolve the fastest compatible Hyper-V provisioning path
```

### Welle 6 – Optionaler OS-/SQL-Warm-Pool

**Ziel:** Bereitstellungszeiten reduzieren, ohne neue Korrektheitsabhängigkeit.

Aufgaben:

- Slot Registry und Lease-Lock implementieren;
- OS_READY_SLOT erstellen und validieren;
- SQL_READY_SLOT erstellen und validieren;
- run-spezifische Overlays verwenden;
- atomare Lease-/Release-Operationen;
- Reset-/Quarantänepfad;
- Pool-Replenishment als explizite oder optionale Hintergrundaktion innerhalb eines aktuellen Aufrufs;
- Poolstatus in Workflow-Übersicht;
- Evaluation- und Driftprüfung.

**Wichtig:** Keine asynchrone Zusage außerhalb eines laufenden Prozesses. Replenishment ist ein normaler Job mit persistentem State, kein unsichtbares Hintergrundversprechen.

**Tests:**

- derselbe Slot kann nicht doppelt geleast werden;
- mehrere Slots können parallel genutzt werden;
- Overlay-Cleanup stellt exakt den Slot-Baselinezustand her;
- Quarantäne bei Hash-/Health-Abweichung;
- Pool leer/deaktiviert -> Standardfallback;
- Prozessabbruch lässt Lease recoverbar, nicht frei.

**Done-Kriterien:**

- Warm Pool kann vollständig ausgeschaltet werden;
- ein Slot spart Schritte, ändert aber nicht das fachliche Ergebnis;
- keine Identitätskollision durch paralleles Klonen spezialisierter Slots.

**Empfohlener Commit:**

```text
Codex: add optional leased Hyper-V warm pool slots
```

### Welle 7 – Reconcile und nachträgliche Änderungen

**Ziel:** Bestehende Umgebungen deklarativ ändern.

Aufgaben:

- Actual-State-Collector für Hyper-V, Windows und SQL;
- semantischer Diff;
- Capability-basierte Änderungsklassen;
- Planvorschau;
- live/restart/recreate/reprovision Executor;
- Rollback-/Recovery-Receipts;
- persistente Datenübergabe;
- State/Lock aktualisieren;
- idempotente Wiederaufnahme nach Unterbrechung.

**Erste unterstützte Änderungen:**

- CPU;
- statisches/dynamisches RAM;
- Startup-/Minimum-/Maximum-RAM;
- zusätzliche VHDX und Größenanpassung;
- Hyper-V-Switch/NIC;
- SQL-Port;
- SQL Memory und MaxDOP;
- Testdatenbanken;
- ausgewählte SQL-Konfigurationen.

OS-/SQL-Versionswechsel werden zunächst als `reprovision` behandelt.

**Tests:**

- No-op-Diff verändert nichts;
- Live-Änderung ohne Neustart;
- Restart-Änderung mit Resume;
- Recreate erhält persistente Daten;
- Reprovision validiert neue Umgebung vor Entfernen der alten;
- Fehler führt zu Recovery-State statt Scope-Ausweitung.

**Done-Kriterien:**

- jede unterstützte Manifestoption kann nachträglich geändert werden;
- Plan erklärt die Wirkung;
- nicht live mögliche Änderungen führen nicht pauschal zu „geht nicht“.

**Empfohlener Commit:**

```text
Codex: reconcile existing Hyper-V lab environments
```

### Welle 8 – UI-/Menü-Neuordnung

**Ziel:** Umgebungszentrierter Workflow ohne technische Builder-Begriffe im Hauptpfad.

Aufgaben:

- Hauptmenü gemäß Abschnitt 11 umbauen;
- „Neue Umgebung“ für Container und Hyper-V über dieselbe semantische Struktur führen;
- „Bestehende Umgebung ändern“ ergänzen;
- Plan-/Diff-Ansicht;
- Pool-/Artifact-Auswahl nur als Information;
- Factory-Aktionen unter „Vorlagen und Installationsmedien“ beziehungsweise „Erweitert“;
- veraltete direkte Buttons aus dem Primärbereich entfernen;
- CLI und UI auf dieselbe Service-/Planner-Schicht aufsetzen;
- keine duplizierte Businesslogik in JavaScript und PowerShell.

**Done-Kriterien:**

- ein Benutzer kann eine Hyper-V-SQL-Umgebung erstellen, ohne die Begriffe Sysprep, PrepareImage oder Child-VHDX zu verstehen;
- bestehende Umgebung ist aus derselben UI änderbar;
- kein Mid-Run-Prompt;
- technische Details bleiben in Plan/Diagnose sichtbar.

**Empfohlener Commit:**

```text
Codex: make the SQL Server Lab workflow environment-centric
```

### Welle 9 – Vollautomatische Factory und Media Lifecycle

**Ziel:** Auch die erstmalige OS-Baseline-Erzeugung aus ISO unattended machen.

Diese Welle ist **nicht erforderlich**, um den normalen Labpfad nach einer vorhandenen Baseline zero-touch zu machen.

Aufgaben:

- Windows Setup aus verifizierter ISO automatisieren;
- Factory-spezifische Unattend-Datei;
- Updates/Servicing Policy;
- Sysprep/Generalize;
- Health-/ImageState-Prüfung;
- immutable Publikation;
- Evaluation-Ablauf erfassen;
- Refresh und neue Artifact-Generation;
- keine Mutation bestehender Artifacts;
- SQL-Prepared-Generation optional integrieren.

**Done-Kriterien:**

- `MEDIA_VERIFIED -> OS_GENERALIZED_SEALED` ohne Gastinteraktion;
- fehlerhafte Factory-Builds werden nicht veröffentlicht;
- alte Referenzen bleiben unverändert verfügbar;
- neuer Evaluierungszeitraum nur durch zulässige Neuinstallation.

**Empfohlener Commit:**

```text
Codex: automate the Hyper-V Windows image factory
```

### Welle 10 – Hardening, Migration und Abschluss

**Ziel:** Alte und neue Pfade konsistent zusammenführen.

Aufgaben:

- alte Builder-/UI-Pfade migrieren oder als Legacy/Advanced kennzeichnen;
- bestehende Artifacts weiterverwenden, sofern kompatibel;
- veraltete Zustände und Menüpunkte entfernen;
- vollständige Doku- und Repo-Map-Konsistenz;
- Native-/Real-Tests dokumentieren;
- Failure-Injection für Reboot, Prozessabbruch, Slot-Lease und Cleanup;
- Performance-/Kapazitätsgrenzen des Pools dokumentieren;
- Branch- und PR-Bereinigung nach Projektregeln.

**Done-Kriterien:**

- kein Dokument behauptet einen manuellen Schritt als Standard, wenn er nur Legacy ist;
- kein Runtimepfad behauptet Zero-Touch ohne realen Nachweis;
- alle statischen Tests grün;
- definierte reale Hyper-V-Abnahmetests erfolgreich oder explizit als noch offen dokumentiert.

**Empfohlener Commit:**

```text
Codex: harden and document zero-touch Hyper-V provisioning
```

---

## 14. Priorisierte erste vertikale Umsetzung

Codex soll nicht zuerst den gesamten Warm Pool oder alle SQL-Versionen bauen. Die erste vertikale Scheibe muss den zentralen Architekturbeweis liefern.

### Ziel der ersten Scheibe

```text
Vorhandenes OS_GENERALIZED_SEALED
-> Child-VHDX
-> run-spezifische Unattend.xml
-> automatischer Boot
-> OOBE vollständig ohne UI-Eingriff
-> PowerShell Direct bereit
-> OS_READY
-> sauberer Cleanup
```

Danach:

```text
OS_READY
-> SQL Server 2025 unattended
-> Reboot/Resume
-> SQL_READY
-> Basiskonfiguration
-> READY
```

Erst wenn dieser Pfad stabil ist, folgen:

- Resolver-Optimierung;
- SQL-Prepared-Accelerator;
- Warm Pool;
- Reconcile-Breite;
- UI-Endausbau.

Diese Reihenfolge verhindert, dass ein schneller Cache einen unvollständigen Kernpfad verdeckt.

---

## 15. Teststrategie

### 15.1 Testpyramide

#### Statische und Unit Tests

- Manifest-/Schema-Validierung;
- Unattend-Generator;
- Secret-Redaction;
- Kompatibilitätsresolver;
- Plan-/Diff-Klassifikation;
- State Transitions;
- Lease Locking;
- Cleanup-Plan;
- Migration alter Metadaten;
- Dokumentationskonsistenz.

#### Mock-/Component Tests

- Hyper-V-Kommandos ohne reale VM-Mutation;
- offline VHDX mount/inject/dismount abstrahiert;
- Reboot-Receipts;
- SQL-Setup-Exitcodes;
- PowerShell-Direct-Retry;
- Slot-Reset;
- Reconcile-Plan.

#### Native Hyper-V Smoke Tests

- Child-VHDX aus synthetischer Parent-VHDX;
- VM-Erstellung;
- NIC/Drive-Attach;
- scopegebundener Cleanup;
- keine Aussage über Windows-/SQL-Readiness ohne echten Gast.

#### Reale End-to-End-Tests

- echte generalisierte Windows-Baseline;
- echte unattended OOBE;
- echte PowerShell-Direct-Verbindung;
- echte SQL-Installation;
- echter Reboot/Resume;
- echter SQL-Readiness-Nachweis;
- echter Cleanup und Parent-Hash-Vergleich.

### 15.2 Verbindliche End-to-End-Szenarien

1. **OS Cold Path**
   - kein Slot;
   - generalisierte Baseline;
   - vollständig unattended zu `OS_READY`.

2. **SQL Cold Path**
   - kein SQL-Accelerator;
   - SQL unattended installieren;
   - mindestens ein Reboot-Szenario.

3. **SQL Prepared Path**
   - kompatibles `SQL_PREPARED_SEALED`;
   - Unattend + CompleteImage;
   - Vergleich zum Direct-Install-Pfad.

4. **OS Slot Path**
   - exklusiver Lease;
   - SQL installieren;
   - Reset und Wiederverwendung.

5. **SQL Slot Path**
   - schnellster Pfad;
   - run-spezifische Änderungen;
   - Overlay verwerfen;
   - Baseline wieder identisch.

6. **Parallelität**
   - zwei Cold-Path-VMs aus demselben generalisierten Parent;
   - getrennte Identitäten;
   - keine Port-/IP-/Name-Kollision.

7. **Lease-Konflikt**
   - zwei Anforderungen für einen Slot;
   - nur eine erhält Lease;
   - zweite fällt auf anderen Pfad zurück oder wartet gemäß expliziter Policy.

8. **Abbruch während OOBE**
   - Prozess beenden;
   - erneuter Aufruf erkennt tatsächlichen Zustand;
   - kein zweites VM-/Child-Objekt.

9. **Abbruch während SQL Setup/Reboot**
   - idempotente Fortsetzung;
   - keine doppelte Installation.

10. **Reconcile Live/Restart/Reprovision**
    - je mindestens ein realer Fall;
    - Plan, Downtime, Validation und Rollback-Verhalten prüfen.

11. **Cleanup**
    - Parent unverändert;
    - Run-Overlay entfernt;
    - persistente Daten gemäß Policy erhalten;
    - Slot nur nach Health Check freigegeben.

12. **Privacy/Security**
    - keine Secrets in State, Lock, Logs, Evidence oder Repository;
    - temporäre Unattend-Datei entfernt;
    - Fehlerausgabe maskiert.

### 15.3 Testnachweise

Reale Tests dürfen keine realen Hostpfade, Benutzernamen, Passwörter, Maschinenkennungen, IP-Adressen, Hardwaredaten oder Logauszüge ins Repository schreiben.

Versionierbar sind nur sanitisierte Ergebnisse wie:

```text
OS specialization: PASS
PowerShell Direct readiness: PASS
SQL version verification: PASS
Parent hash unchanged: PASS
Manual guest interaction count: 0
```

Konkrete lokale Evidence bleibt außerhalb des Repositories.

---

## 16. Akzeptanzkriterien des Gesamtprojekts

### 16.1 Funktional

- Nach Vorhandensein einer kompatiblen `OS_GENERALIZED_SEALED`-Baseline kann eine neue Hyper-V-Umgebung ohne menschlichen Gasteingriff erstellt werden.
- Der Warm Pool kann leer oder deaktiviert sein.
- SQL kann ohne SQL-Template unattended installiert werden.
- `SQL_PREPARED_SEALED` und Slots beschleunigen, sind aber keine Pflicht.
- Jeder Run verwendet eine unveränderte Basis plus run-lokale Änderungen.
- Cleanup verwirft Änderungen ohne die Basis zu verändern.
- Persistente Daten bleiben nur nach ausdrücklicher Policy erhalten.
- Reboots werden automatisch und resumierbar verarbeitet.
- Bestehende Umgebungen können über Desired-State-Änderungen angepasst werden.
- Nicht in-place mögliche Änderungen führen zu Recreate/Reprovision statt zu einem pauschalen Abbruch.

### 16.2 User Experience

- Hauptworkflow beginnt mit „Neue Umgebung“ und nicht mit „Image bauen“.
- Der Benutzer muss keine Sysprep-/VHDX-/PrepareImage-Kenntnisse besitzen.
- Alle Entscheidungen vor Mutation.
- Kein unerwarteter Prompt mitten im Job.
- VMConnect ist optionales Diagnosewerkzeug.
- Plan erklärt technischen Pfad und Auswirkungen verständlich.
- „Bestehende Umgebung ändern“ ist eine erstklassige Funktion.

### 16.3 Sicherheit und Datenschutz

- Kein Secret im Repository.
- Kein Secret im Manifest oder Manifest Lock.
- Kein gemeinsames Passwort in einer Baseline.
- Run-spezifische Credentials.
- Unattend nur im Child-/Run-Kontext.
- Parent unverändert und hashverifiziert.
- Scopegebundener Cleanup.
- Keine realen Umgebungsdaten in Tests oder Doku.

### 16.4 Qualität

- Runtime, Doku, `.ai/repo_map.yaml` und Known Limitations sind synchron.
- Kein Status wird allein aus einem Schemafeld abgeleitet.
- Zero-Touch wird erst nach echtem End-to-End-Test behauptet.
- Jeder Reboot-/Resume-Schritt ist idempotent.
- Slot-Leases sind atomar.
- Poolfehler verschlechtert höchstens die Geschwindigkeit, nicht die Korrektheit.

---

## 17. Nichtziele der ersten Umsetzung

- keine Produktionsbereitstellungsplattform;
- kein Active-Directory-Domain-Join im ersten Zero-Touch-MVP;
- kein Anspruch, jede Windows-/SQL-Kombination sofort zu unterstützen;
- kein vollständiger Warm Pool vor funktionierendem Cold Path;
- kein paralleles Klonen eines spezialisierten Slots;
- kein Speichern fixer Gastpasswörter in Images;
- kein automatisches Überschreiben bestehender Artifacts;
- keine stillschweigende SQL-/Windows-In-place-Aktualisierung;
- keine rohe MDF/LDF-Übernahme über inkompatible Versionsgrenzen;
- kein manueller OOBE-Fallback im Standardpfad;
- keine UI-Neuschreibung ohne gemeinsame Planner-/Runtime-Schicht;
- kein Abbau des bestehenden funktionierenden Containerpfads.

---

## 18. Risiken und Gegenmaßnahmen

| Risiko | Auswirkung | Gegenmaßnahme |
|---|---|---|
| Unattend-Einstellungen unterscheiden sich nach Windows-Version/Edition | OOBE bleibt stehen | OS-spezifische Profile, echte E2E-Tests, fail-closed statt manueller Standardfallback |
| Offline-VHDX-Injection benötigt erhöhte Rechte | Automatisierung startet nicht | klarer Preflight; Standardpfad nur bei erfüllter Capability; alternative Delivery erst nach Test |
| Secrets liegen kurzzeitig in der Antwortdatei | Offenlegung bei falscher Ablage | nur Child, restriktive ACLs, kurze Lebensdauer, Entfernung, Redaction-Tests |
| SQL Setup benötigt Reboot oder liefert komplexe Exitcodes | Workflow bricht oder läuft doppelt | persistente Receipts, Bootzeit-Nachweis, idempotente Resume-Logik |
| SQL Features passen nicht zu PrepareImage | Accelerator unbrauchbar | Direct-Install-Fallback; Capability-Matrix |
| Spezialisierter Slot wird parallel geklont | Identitätskollision | atomare exklusive Leases; Slots nicht parallel klonbar |
| Slot driftet | unsaubere neue Labs | Hash-/Health-Check, Quarantäne, Rebuild |
| Evaluation läuft ab | Umgebung startet nicht oder ist unzulässig | Ablaufmetadaten, Mindestrestlaufzeit, Resolver verwirft Kandidat |
| Reprovision gefährdet Daten | Datenverlust | explizite Persistenz, Backup/Restore, neue Umgebung vor Alt-Cleanup validieren |
| UI und Runtime driften auseinander | falsche Benutzererwartung | gemeinsame Planner-Schicht, Doku-/Contract-Tests |
| Warm Pool verdeckt fehlerhaften Cold Path | System funktioniert nur bei Cache Hit | Cold Path als Pflicht-Abnahmetest; Pool deaktiviert testen |

---

## 19. Voraussichtlich betroffene Repository-Bereiche

Codex muss die tatsächliche Struktur des aktuellen `main` zuerst prüfen. Nach heutigem Stand sind insbesondere folgende Bereiche relevant:

### Bestehende Runtime

- `Private/HyperVImageBuilder.ps1`
- `Private/HyperVImageRegistry.ps1`
- `Private/HyperVLabEnvironment.ps1`
- `Private/ManifestParser.ps1`
- `Private/ManifestBuilder.ps1`
- `Private/StateMachine.ps1`
- `Private/CleanupEngine.ps1`
- `Private/SqlReadiness.ps1`
- `Providers/HyperV/HyperVProvider.ps1`
- `Public/New-SqlServerLab.ps1`
- `Public/Invoke-SqlServerLab.ps1`
- `Public/Get-SqlServerLabWorkflow.ps1`
- `Public/Invoke-SqlServerLabWorkflowAction.ps1`

### Schema und Kataloge

- `Schemas/lab-manifest.schema.json`
- OS-/SQL-/Artifact-Kataloge und deren Schemas
- Registry-/Lock-/Run-State-Verträge

### UI

- `Ui/index.html`
- `Ui/app.js`
- zugehörige Styles und lokale API-/Hostschicht

### Tests

- `Tests/Static/Invoke-HyperVImageRegistryChecks.ps1`
- `Tests/Static/Invoke-HyperVImageBuilderChecks.ps1`
- `Tests/Static/Invoke-HyperVLabEnvironmentChecks.ps1`
- `Tests/Static/Invoke-ManifestBuilderChecks.ps1`
- `Tests/Static/Invoke-DocumentationChecks.ps1`
- `Tests/Integration/Invoke-HyperVSmokeTest.ps1`
- übergeordnete All-Checks-/Smoke-Matrix-Einstiege

### Dokumentation und AI-Metadaten

- `Documentation/Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md`
- `Documentation/Architecture/TEMPLATE_POOL_AND_AUTOMATED_MANIFESTS.md`
- `Documentation/Quality/KNOWN_LIMITATIONS.md`
- `Documentation/HowTo/HYPERV_WINDOWS_IMAGE_BUILD.md`
- `Documentation/HowTo/HYPERV_SQL_PREPARED_IMAGE.md`
- `Documentation/HowTo/WORKFLOW_UI.md`
- `README.md`
- `CHANGELOG.md`
- `.ai/PROJECT_CONTEXT.md`
- `.ai/repo_map.yaml`

### Mögliche neue Komponenten

Die Namen sind Vorschläge und müssen an bestehende Konventionen angepasst werden:

- `Private/WindowsUnattend.ps1`
- `Private/HyperVDesiredState.ps1`
- `Private/HyperVReconcile.ps1`
- `Private/HyperVSlotPool.ps1`
- `Private/HyperVProvisioningResolver.ps1`

Keine dieser Dateien darf nur als leere Architekturhülle angelegt werden. Neue Komponenten benötigen Runtime-Nutzung, Tests und Dokumentation in derselben Welle.

---

## 20. Arbeitsregeln für Codex

1. Vor Beginn `AGENTS.md`, `.ai/WORKING_RULES.md`, Commit-Regeln und Datenschutzvorgaben lesen.
2. Aktuellen `main` abrufen und nicht von einem fixen Commit in diesem Dokument ausgehen.
3. Vor jeder Datei- oder Git-Operation prüfen, ob reale personen-, firmen-, host-, hardware- oder umgebungsbezogene Daten enthalten sein könnten.
4. Keine realen Pfade, Konten, Hashes, IP-Adressen, VM-Namen, Logs oder Secrets versionieren.
5. Nur synthetische Beispiele verwenden.
6. Commit Messages mit `Codex:` beginnen.
7. Jede Welle in einem konsistenten, testbaren Zustand abschließen.
8. Nach jeder Welle Doku, Known Limitations und Repo Map aktualisieren.
9. Keine Runtime-Funktion als fertig markieren, solange nur Mocks grün sind.
10. Reale Hyper-V-/Windows-/SQL-Nachweise getrennt von statischen Tests ausweisen.
11. Bestehende funktionierende Containerpfade nicht unnötig umbauen.
12. Bestehende `SQL_PREPARED_SEALED`-Funktionalität kompatibel halten, aber korrekt als optionalen Accelerator einordnen.
13. Standardworkflow niemals auf einen manuellen OOBE-Fallback zurückfallen lassen.
14. Bei einer blockierten Welle an unabhängigen statischen Verträgen, Tests oder Dokumentationskonsistenz weiterarbeiten, ohne ungetestete Runtime als fertig zu deklarieren.
15. Nach jeder realen Testwelle nur sanitisierte Resultate ins Repository übernehmen.

---

## 21. Empfohlener Codex-Startauftrag

Der folgende Auftrag kann als erster Arbeitsauftrag verwendet werden:

```text
Arbeite im Repository gecompat/SQL_Server_Lab auf Basis des aktuellen main.
Lies zuerst AGENTS.md, .ai/WORKING_RULES.md, die Commit-Regeln und die verbindlichen Datenschutzvorgaben.

Ziel ist die erste vertikale Zero-Touch-Hyper-V-Scheibe:

OS_GENERALIZED_SEALED
-> differenzierende Child-VHDX
-> run-spezifische Unattend.xml
-> automatisches Windows specialize/OOBE
-> PowerShell Direct bereit
-> OS_READY
-> scopegebundener Cleanup

Der Standardpfad darf nach dem Start keine manuelle Anmeldung, kein VMConnect, keine Region-/Sprach-/Tastaturabfrage und keine Bestätigung „Windows ist fertig“ verlangen.

Bearbeite zuerst Welle 0 bis Welle 3 dieses Plans. Beginne mit einem Ist-Abgleich, implementiere danach Desired-State-/Artifact-Verträge, eine sichere run-spezifische Unattend-Komponente und die reale Zero-Touch-Spezialisierung aus einer vorhandenen generalisierten Windows-Baseline.

Verbindliche Regeln:
- OS_READY_SLOT und SQL_READY_SLOT sind optionale Caches, keine Voraussetzung.
- SQL_PREPARED_SEALED bleibt kompatibler optionaler Accelerator.
- Die generalisierte Parent-VHDX bleibt unverändert und read-only.
- Secrets stehen nie im Manifest, Lock, State, Log oder Repository.
- Kein manueller OOBE-Fallback im Standardpfad.
- Vor jeder Mutation einen verständlichen Plan erzeugen.
- Dokumentation, .ai/repo_map.yaml, Known Limitations und Tests in derselben Welle aktualisieren.
- Commits mit „Codex:“ beginnen.
- Nach jedem konsistenten Stand testen und entsprechend den Projektregeln in main integrieren.

Erster zwingender Realnachweis:
Eine echte Windows-Server-Baseline wird zu einer neuen Hyper-V-VM spezialisiert, ohne dass ein Mensch den Gast öffnet oder bedient. PowerShell Direct funktioniert, gewünschte Locale-/Accountwerte sind gesetzt, die Unattend-Payload ist entfernt, und der Parent-Hash ist unverändert.
```

---

## 22. Offizielle technische Referenzen

Die folgenden Quellen sind für die Implementierung zu prüfen. Codex soll versions- und editionsspezifische Details unmittelbar vor der Umsetzung erneut gegen die aktuelle Microsoft-Dokumentation verifizieren.

- Microsoft (2024): *Automate OOBE*. Microsoft Learn. Verfügbar unter: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/automate-oobe (Zugriff: 2026-08-08).
- Microsoft (2026): *Sysprep (Generalize) a Windows installation*. Microsoft Learn. Verfügbar unter: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/sysprep--generalize--a-windows-installation?view=windows-11 (Zugriff: 2026-08-08).
- Microsoft (2026): *Deprovision or generalize a VM before creating an image*. Microsoft Learn. Verfügbar unter: https://learn.microsoft.com/en-us/azure/virtual-machines/generalize (Zugriff: 2026-08-08).
- Microsoft (2026): *Install, configure, or uninstall SQL Server on Windows from the command prompt*. Microsoft Learn. Verfügbar unter: https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver17 (Zugriff: 2026-08-08).
- Microsoft (2026): *Install SQL Server using a configuration file*. Microsoft Learn. Verfügbar unter: https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-using-a-configuration-file?view=sql-server-ver17 (Zugriff: 2026-08-08).
- Microsoft (2025): *Considerations for installing SQL Server using SysPrep*. Microsoft Learn. Verfügbar unter: https://learn.microsoft.com/en-us/sql/database-engine/install-windows/considerations-for-installing-sql-server-using-sysprep?view=sql-server-ver17 (Zugriff: 2026-08-08).

---

## 23. Abschließende Architekturentscheidung

Die neue verbindliche Leitlinie lautet:

> Eine generalisierte OS-Baseline ist der notwendige wiederverwendbare Ausgangspunkt. Eine run-spezifische Unattend-Konfiguration macht daraus ohne menschlichen Eingriff eine vollständig verwaltbare Windows-VM. Vorbereitete OS- und SQL-Slots bleiben optionale Beschleuniger. Der Benutzer beschreibt ausschließlich den Zielzustand; das Framework wählt den schnellsten kompatiblen Pfad, verarbeitet Reboots selbst und kann bestehende Umgebungen über Reconcile kontrolliert ändern oder neu provisionieren.

Damit wird Sysprep nicht abgeschafft. Es wird an die richtige Stelle verschoben: **in die Factory-Ebene und aus dem normalen Benutzerworkflow heraus.**

## 24. KI-Handover-Verankering für nächste Instanz (2026-08-08)

Folgende Punkte sind als nicht verhandelbare Ausführungsvorgaben zu behandeln, damit ein späterer Einstieg direkt die richtige Richtung nimmt:

### 24.1 Nicht verhandelbare Betriebsanforderung

- Eine neue Hyper-V-Umgebung darf im Standardpfad ohne manuelle Eingriffe des Users im Gast laufen.
- Der User darf während der Provisionierung weder VMConnect öffnen noch im Gast klicken.
- Jede Abweichung vom automatischen Pfad ist vor jeder Mutation als separate, klar als Factory/Trust/Diagnose gekennzeichnete Aktion auszuweisen.
- Kein impliziter Übergang auf manuelle OOBE-Rückfalle.

### 24.2 Konfigurierbarkeit durch Manifest, CLI und UI (Muss)

- CPU, RAM und dynamisches RAM müssen pro Lauf im Manifest, in der CLI und im UI gesetzt und verändert werden können.
- Netzwerkzielbild (NIC-Typ, Bandbreiten-/Latenzprofil, erreichbarkeit, statische vs. dynamische Adresse, DNS- und Gateway-Intent) muss pro Lauf vollständig konfigurierbar sein.
- I/O- und Performance-Intent für Testkonstellationen muss explizit abbildbar sein (z. B. `slow`, `throttled`, `balanced`, `high`).
- Datenpfade müssen je nach Lab typisierbar und nachträglich anpassbar sein:
  - TempDB
  - Datenbankdateien (Daten + Log)
  - Backup-Ziel
  - temporäre Arbeitsdaten
- Testdatenbanken müssen nachträglich erstellt, ergänzt oder entfernt werden können.
- Alle Änderungsanforderungen laufen als Manifeständerung in den Reconcile-Flow (`live`, `restart`, `recreate`, `reprovision`, `unsupported`).

### 24.3 Evaluation-Betriebssicherheit (Muss)

- Evaluation-OS-Instanzen sind in der Kompatibilität zuerst zu berücksichtigen.
- Das Ablaufdatum/ die Mindestrestzeit einer Evaluation-Basis ist vor der Aufsetzentscheidung verbindlich zu prüfen.
- Resolver darf keinen Lauf starten, wenn die Baseline aus Compliance-/Laufzeitsicht vor Ablauf steht oder nicht erneuert werden kann.
- Reprovision über frische Baseline muss als kontrollierter Standardweg vorgesehen sein.

### 24.4 Geschwindigkeit als harte Zielgröße

- Der Standard-Casual-Pfad bleibt `OS_GENERALIZED_SEALED -> Child -> Unattend -> OS_READY`, unabhängig von vorhandenen Caches.
- Warm-Pool- und SQL-Prepared-Pfade dürfen nur beschleunigen, nicht blockieren.
- Der Resolver muss bei Cache-Miss deterministisch auf den Cold-Path zurückfallen und ihn korrekt bereitstellen.

### 24.5 Empfohlene direkte nächste Schritte für neue KI

1. Welle 0 bis Welle 3 stabilisieren und als `PLANNING_BASELINE_FOR_IMPLEMENTATION` dokumentieren.
2. Contract-/Schema-Validierung für CPU/RAM/Network/Drives/Test-Db-Erweiterung nach dem Manifestvertrag abschließen.
3. Unattend- und First-Run-Pfade auf vollständige OOBE-Autonomie mit Reboot-Resume auslegen.
4. Reconcile für Laufzeitänderungen von CPU/RAM/Drives/Testdatenbanken implementieren oder protokollieren.
5. Evaluation-OS-Kompatibilitäts- und Ablaufprüfungen früh in Planner+Resolver aufnehmen.
6. Planungsstand im Repo (Plan, Known Limitations, docs, tests) synchron halten.

### 24.6 Operative Governance für Folgeänderungen

- Konsistente Änderungen werden als Wellen/Teilpakete mit sauberem Scope umgesetzt und **immer gegen `origin:main` gemerged**.
- Branches sollen zeitnah aufgeräumt werden; alte oder obsolet gewordene Pull Requests sind zu schließen oder zu löschen.
- Nicht mehr benötigte PRs sind als solche zu markieren, damit die Sicht auf aktive Umsetzungslinien klar bleibt.
- Commit-Messages folgen den Projektregeln:
  - KI-Commitpräfix (`ChatGPT:`, `Codex:` oder `Genie:`),
  - klarer Scope-Titel als erste Zeile,
  - aussagekräftiger Text für Test-/Dokumentationsstatus.
