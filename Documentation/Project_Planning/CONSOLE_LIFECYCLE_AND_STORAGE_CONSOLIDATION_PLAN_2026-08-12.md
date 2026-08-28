# Konsolen-, Lifecycle- und Storage-Konsolidierungsplan

| Merkmal | Wert |
|---|---|
| Status | `PLANNED_FROM_MANUAL_ACCEPTANCE` |
| Stand | 2026-08-12 |
| Priorität | `P0` für Fehlerkorrekturen, `P1` für Storage-Ausbau und Komfort |
| Geltung | interaktive PowerShell-Konsole, Lifecycle-Seiteneffekte, Storage-Registry, Providerplanung und SQL-Dateiplatzierung |
| Ausgangspunkt | manuelle lokale Abnahme von Docker-, CMS-, Storage- und Hyper-V-Abläufen |
| Ziel | einheitliche Bedienung ohne versteckte Mutation sowie reproduzierbare Platzierung einzelner SQL-Dateien auf ausdrücklich gewählten Storage-Zielen |

## 1. Entscheidung

Die in der manuellen Abnahme gefundenen Punkte werden als eine gemeinsame
Konsolidierungswelle umgesetzt. Einzelkorrekturen dürfen den bestehenden
Sonderpfaden keine weiteren lokalen Bedien-, Status- oder Storage-Verträge
hinzufügen.

Die Lieferreihenfolge ist verbindlich:

1. reproduzierbare Funktionsfehler und unerwünschte Seiteneffekte beheben;
2. alle echten Auswahlmenüs auf die gemeinsame Console-UI migrieren;
3. Legacy- und Multi-Root-Storage konsistent verwalten;
4. einen providerneutralen Storage- und SQL-Dateiplan einführen;
5. Hyper-V und Container capability-basiert daran binden;
6. SQL-Pfade nach der Mutation technisch verifizieren;
7. Status, Collation-Suche und optionale I/O-Evidenz ergänzen;
8. automatische und manuelle Regression vollständig abschließen.

Dieser Plan erweitert den
[Console-UI-Vertrag](CONSOLE_UI_FRAMEWORK_PLAN.md) und den
[Storage-Contract](STORAGE_CONTRACT_PLAN.md). Er ersetzt nicht deren
grundlegende Sicherheits- und Besitzregeln.

## 2. Verifizierte Ausgangslage und Problemregister

Ein grüner statischer Testlauf ist kein Nachweis für die hier aufgeführten
interaktiven und nativen Runtimepfade. Die folgenden Beobachtungen stammen aus
einer realen Konsolensitzung und gelten bis zu einem passenden Regressionstest
als offen.

| ID | Priorität | Beobachtung | Gewünschtes Verhalten |
|---|---:|---|---|
| `ACC-LIF-001` | P0 | Nach `Escape`, einer abgebrochenen Löschung und anderen Ergebnissen wie `Cancelled`, `NoChange` oder `Skipped` wird trotzdem der Connection Center/CMS synchronisiert. Dadurch läuft insbesondere nach „Löschen abgebrochen“ unnötig die CMS-Synchronisierung. | Synchronisation ausschließlich nach einer erfolgreichen, tatsächlich status- oder endpunktrelevanten Mutation; Abbruch, Ablehnung, No-op, übersprungene und fehlgeschlagene Aktionen lösen weder Connection-Center- noch CMS-Sync aus. |
| `ACC-CUI-001` | P0 | Storage-, Connection-Center-, Erstellungs- und einzelne Hyper-V-Auswahlen verwenden weiterhin direkte `Read-Host`-Menüs. | Jede Auswahl aus mehreren Einträgen verwendet die gemeinsame Cursor-UI; `Read-Host` bleibt nur Fallback oder freier Werteeditor. |
| `ACC-CUI-002` | P0 | `Escape` funktioniert in alten Untermenüs und Bestätigungen nicht einheitlich. | `Escape` verlässt genau eine Ebene; im Fallback bleibt `0` ein dokumentierter Alias. |
| `ACC-CUI-003` | P0 | Storage `[2] Konfiguration erneut anzeigen` beendet das Untermenü und springt über eine zusätzliche Pause ins Hauptmenü. | Anzeige aktualisieren und im Storage-Menü bleiben; nur `[0]` oder `Escape` verlässt die Ebene. |
| `ACC-CUI-004` | P1 | Der globale Hinweis `[Enter] fuer Menue...` erscheint auch ohne weitere Entscheidungsmöglichkeit. | Keine pauschale Pause; Ergebnisansichten besitzen nur bei echtem Lesebedarf einen eigenen, klar beschrifteten Rückweg. |
| `ACC-CUI-005` | P1 | Es ist nicht reproduzierbar beschrieben, in welcher Konsole der `Read-Host`-Fallback manuell geprüft werden soll. | Derselbe PowerShell-7-Einstieg erhält einen diagnostischen Modus `Auto|Fallback`; ein DOS-/`cmd.exe`-Fenster ist dafür nicht erforderlich. |
| `ACC-CUI-006` | P0 | Direkte `Read-Host`-Erfassungen besitzen keinen einheitlichen hierarchischen Abbruch; `Escape` ist dadurch nicht überall wirksam. | `Escape` verwirft die aktuelle Erfassung und kehrt genau eine Menüebene zurück; im Hauptmenü beendet es die UI. |
| `ACC-CUI-007` | P0 | Für `Ctrl+C` existiert kein ausdrücklich getesteter, globaler Abbruchvertrag; breite Fehlerbehandlung kann einen harten Nutzerabbruch fälschlich als normalen Fehler behandeln. | `Ctrl+C` beendet die gesamte aktuelle Verarbeitung, wird nie als normaler Menüfehler verschluckt und hinterlässt außerhalb atomarer Operationen höchstens einen eindeutig wiederaufnehmbaren Zustand. |
| `ACC-PRV-001` | P1 | Für die manuelle Abnahme ist unklar, ob die gesamte Konsole erhöht gestartet werden muss. | Standardtests beginnen nicht erhöht; nur privilegierte Aktionen fordern nach Preview und Zustimmung eine eigene Erhöhung an. |
| `ACC-STO-001` | P0 | Ein laufwerksrelativer Pfad wie `D:` wird als Parent akzeptiert. | Nur vollqualifizierte Pfade wie `D:\` oder `D:\SQLLab` akzeptieren; normalisiertes Ziel vor Mutation anzeigen. |
| `ACC-STO-002` | P0 | Ein vorhandener Legacy-Default `D:\Lab_Data` wurde beim ersten Registrieren von `C:\Lab_Data` nicht übernommen; C wurde still zum Standard. | Legacy-Root zuerst erkennen und migrieren; ein neuer Root ändert den Standard nur nach ausdrücklicher Bestätigung. |
| `ACC-STO-003` | P1 | „Diese Lab_Data-Wurzel als Standard verwenden?“ erklärt seine Reichweite nicht. | Als „globalen Fallback für neue persistente Lab-Ablagen“ bezeichnen und ausdrücklich von SQL-Rollenzuordnungen trennen. |
| `ACC-STO-004` | P0 | Registrierte Roots lassen sich nicht Data, Log, TempDB, Backup oder einzelnen SQL-Dateien zuordnen. | Rollen- und dateigenaue Platzierung im Intent, Bound Plan, Provider und SQL-Receipt. |
| `ACC-PORT-001` | P0 | Belegte Ports wie 1433 oder der CMS-Port werden im Erstellformular akzeptiert. | Belegung im Review und atomar unmittelbar vor der Mutation prüfen. |
| `ACC-HV-001` | P0 | Windows-Generalize scheitert, weil `Invoke-Command` mit dem nicht vorhandenen Parameter `-Passthru` aufgerufen wird. | Parameter entfernen, realen PowerShell-Direct-Vertrag testen und zustandsabhängigen nächsten Schritt anzeigen. |
| `ACC-UAC-001` | P0 | Die Windows-UAC-Abfrage erklärte ihren Anlass nicht und startete ohne vorgelagerte Zustimmung. | Zweck erklären und vor dem UAC-Dialog standardmäßig ablehnend bestätigen lassen. |
| `ACC-STS-001` | P1 | Das Hauptmenü lädt und zeigt alle Umgebungen und Connection Strings; die Anzeige verschwindet beim Menürendering, während `[2] Status` den Connection String nicht vollständig ausgibt. | Hauptmenü schlank; vollständige Status- und Endpunktübersicht einschließlich kopierbarem Connection String ausschließlich unter `[2] Status`. Automatisch erzeugte Testzugänge dürfen dort vollständig erscheinen; sonstige Secrets bleiben gemäß Secretvertrag maskiert. |
| `ACC-UX-001` | P1 | „Änderungen jetzt anwenden“ wird auch bei einer Neuanlage ohne vorherige Änderung verwendet. | Aktionsverb nach Kontext: erstellen, ändern, prüfen oder entfernen. |
| `ACC-COL-001` | P1 | Collation ist ein freies Textfeld ohne katalogisierte Auswahl und Suche. | Versionsfähiger Katalog mit tokenbasierter Suche, Metadaten und technischer Validierung. |
| `ACC-IO-001` | P1 | IOPS-Limits werden ohne Information über das Zielvolume erfasst. | Topologie und vorhandene Mess-Receipts anzeigen; niemals einen unbelegten Maximalwert behaupten. |

### 2.1 Bereits begonnener Teilstand

`ACC-UAC-001` ist im Arbeitsstand bereits als vorgelagerte, standardmäßig
ablehnende Bestätigung in `Private/Elevation.ps1` begonnen. Der Punkt bleibt
bis zu einem automatischen Test für Ablehnung, Zustimmung und bereits erhöhte
Sitzung `IMPLEMENTED_UNVERIFIED`.

Alle anderen Punkte dieses Dokuments sind zunächst `PLANNED`. Ein Plantext
oder Schemafeld darf nicht als Implementierungs- oder Runtime-Nachweis gelten.

## 3. Unveränderliche Leitplanken

1. Navigation, Review und Abbruch mutieren weder Runtime noch CMS, State oder
   Storage-Registry.
2. Jede Mutation liefert ein strukturiertes Ergebnis; Konsolentext steuert
   keine Folgeaktion.
3. Ein Storage-Ziel wird über eine lokale stabile Identität gebunden, nicht
   über einen unversionierbaren freien Hostpfad im portablen Manifest.
4. Unterschiedliche Gastlaufwerksbuchstaben beweisen keine physische
   Datentrennung.
5. Physische Trennung darf nur als erfüllt gelten, wenn die Backing Devices
   nachweislich disjunkt sind; `UNKNOWN` ist nicht `PASS`.
6. Ein Provider darf keine physische Platzierung versprechen, die er nicht
   reproduzierbar kontrolliert und verifiziert.
7. `TempDB`-Datenfiles, `TempDB`-Log, User-Data, User-Log und Backup sind
   getrennte Platzierungsobjekte.
8. SQL-Systemdatenbanken werden in der ersten Lieferstufe nicht stillschweigend
   verschoben. Ein späteres Verschieben von `master`, `model` oder `msdb`
   benötigt einen eigenen Recovery- und Abnahmevertrag.
9. Benchmarks sind ausdrücklich gestartete Diagnosen, keine automatische
   Nebenwirkung eines Erstellungsdialogs.
10. Secrets werden weder in Statuslisten noch in portablen Plänen angezeigt.
11. Die Konsole startet für normale Bedienung und read-only Prüfungen im
    Benutzerkontext. Administratorrechte werden nicht vorsorglich für die
    gesamte Testsitzung verlangt.

## 4. Zielvertrag für Lifecycle-Ergebnisse und CMS-Synchronisation

### 4.1 Strukturiertes Aktionsergebnis

Jede interaktive und direkte Lifecycle-Aktion liefert intern ein Objekt nach
folgendem Muster:

```text
SqlServerLab.ActionResult/1.0
  Status: Changed | NoChange | Cancelled | Failed
  Action: New | Start | Stop | Restart | Remove | Clear | Rename | Resources | ...
  RunIds: []
  Mutations: []
  ConnectionCenterImpact: None | RuntimeState | EndpointSet | DisplayMetadata
  ErrorCode: <optional>
```

Die UI entscheidet nur anhand dieses Objekts über Folgeaktionen. Ein leerer
Rückgabewert oder das bloße Betreten eines Menüpunktes gilt nicht als
erfolgreiche Mutation.

### 4.2 Sync-Gate

Connection Center und CMS werden genau einmal synchronisiert, wenn:

```text
Status == Changed
AND ConnectionCenterImpact != None
```

| Aktion | Ergebnis | CMS-Sync |
|---|---|---:|
| Stop-Menü öffnen, `Escape` | `Cancelled` | nein |
| bereits gestopptes Ziel als No-op behandeln | `NoChange` | nein |
| Umgebung erfolgreich stoppen | `Changed/RuntimeState` | ja |
| CPU oder RAM ändern | `Changed/None` | nein |
| Anzeigename erfolgreich ändern | `Changed/DisplayMetadata` | ja |
| neue Umgebung vollständig bereit | `Changed/EndpointSet` | ja |
| Erstellung scheitert und wird bereinigt | `Failed` | nein |

Der automatische Sync läuft nicht innerhalb tiefer Providerfunktionen. Er
wird am gemeinsamen Action-Orchestrator ausgelöst, damit genau ein Sync pro
Benutzeraktion entsteht.

## 5. Zielvertrag für die Konsolenbedienung

### 5.1 Auswahl gegenüber Werteingabe

Eine Auswahl aus zwei oder mehr bekannten Optionen verwendet immer
`Invoke-LabConsoleMenu` oder `Invoke-LabConsoleMultiSelect`. Dazu gehören auch
Ja/Nein-Entscheidungen mit relevanter Seitenauswirkung.

`Read-Host` bleibt zulässig für:

- freie Namen und Pfade;
- numerische Werte;
- SecureString-Eingaben;
- den nummerierten/buchstabenbasierten Console-UI-Fallback.

Statische Tests suchen nach neuen direkten Mustern wie
`$choice = Read-Host 'Auswahl'` und `$selection = Read-Host '...Nummer...'`
außerhalb der zentralen Fallbackimplementierung.

### 5.2 Navigation

- Pfeiltasten ändern nur lokalen UI-State.
- `Enter` wählt oder öffnet einen Feldeditor.
- `Escape` verlässt genau die aktuelle Ebene ohne Mutation.
- `F5` aktualisiert nur den ausdrücklich beschriebenen Snapshot.
- `0` bleibt im `Read-Host`-Fallback der Alias für „Zurück“.
- Nach einer Unteraktion wird der Snapshot neu geladen und dasselbe Untermenü
  wieder angezeigt.
- Eine pauschale `[Enter] fuer Menue...`-Pause im Hauptloop entfällt.

### 5.3 Zu migrierende Menügruppen

1. Storage-Verwaltung einschließlich Root-, Quell- und Planauswahl;
2. SQL-Verbindungszentrale und CMS-Untermenüs;
3. Zieltyp, SQL-Version, Patch/CU und Ressourcenprofil bei der Neuanlage;
4. verbleibende Hyper-V-Build-, Medien-, Quell-VM- und Fortsetzungsauswahlen;
5. Gastpasswortmodus und andere bekannte Optionslisten;
6. destruktive Bestätigungen mit konsistentem Default und Abbruch;
7. alle neu durch diesen Plan entstehenden Storage- und Dateizuordnungen.

### 5.4 Reproduzierbarer Fallback-Test

Der Einstieg erhält einen diagnostischen, nicht im State gespeicherten
Console-Modus:

```text
Auto      -> Capability-Erkennung entscheidet (Produktionsstandard)
Fallback  -> nummerierte/buchstabenbasierte Read-Host-Bedienung erzwingen
```

Der Benutzer startet beide Modi in demselben `pwsh`-Terminal. `cmd.exe`, die
veraltete Windows PowerShell 5.1 oder das absichtliche Beschädigen der
Cursorsteuerung sind nicht erforderlich. Der Schalter verändert nur den
Renderer; Workflow, Validierung und Mutation bleiben identisch. Ein erzwungener
Cursor-Modus ist nicht vorgesehen, weil ein ungeeigneter Host fail-safe auf den
Fallback wechseln muss.

## 6. Multi-Root-Storage und Default-Semantik

### 6.1 Registry-Modell

Eine lokale Storage-Location enthält mindestens:

```text
LocationId
ControllerId
LabDataRoot
VolumeId
DriveLetter
BackingDeviceIds[]
TopologyStatus: Proven | LogicalOnly | Unknown
MediaType
BusType
HealthStatus
FreeBytes
```

`LocationId` bleibt auch dann stabil, wenn sich ein Laufwerksbuchstabe ändert.
Konkrete Hostpfade und Geräteidentitäten verbleiben im lokalen Storage-Katalog
und Run-State.

### 6.2 Legacy-Übernahme

Beim ersten Lesen eines Storage-2.x-Katalogs wird ein vorhandener Legacy-Wert
aus der lokalen Preference geprüft:

1. Pfad vollständig qualifizieren;
2. vorhandenen Root und Besitzmarker prüfen;
3. fehlenden Marker nur nach erklärter Bestätigung initialisieren;
4. Root mit stabiler `LocationId` registrieren;
5. bisherigen Default unverändert übernehmen;
6. Migration mit Receipt festhalten;
7. erst danach weitere Locations anbieten.

Das Hinzufügen einer Location ändert einen vorhandenen Default nie implizit.
Wenn noch kein Default existiert, zeigt die Review ausdrücklich, dass der erste
Root zum globalen Fallback wird.

### 6.3 Pfadvalidierung

| Eingabe | Ergebnis |
|---|---|
| `D:` | blockiert: laufwerksrelativ und vom aktuellen Laufwerksverzeichnis abhängig |
| `D:\` | gültiger Volume-Root; Ziel wird `D:\Lab_Data` |
| `D:\SQLLab` | gültiger absoluter Parent; Ziel wird `D:\SQLLab\Lab_Data` |
| relativer Pfad | blockiert |
| Repository-Unterpfad | blockiert |
| fremd markierter Root | blockiert |

Vor dem Schreiben zeigt eine Review Eingabe, normalisierten Parent, resultierenden
`Lab_Data`-Root, Volume/Backing Device und Default-Auswirkung.

### 6.4 Neues Storage-Menü

```text
Storage verwalten
  [1] Lab_Data-Location hinzufügen
  [2] Registrierte Locations und Topologie anzeigen
  [3] Globalen Fallback festlegen
  [4] Location umbenennen oder Anzeigename ändern
  [5] Unbenutzte Location deregistrieren
  [6] Parent-Migration planen
  [7] Freigegebenen Migrationsplan ausführen
  [8] Optionalen Storage-Nachweis ausführen oder anzeigen
  [0] Zurück
```

Eine Location darf nicht deregistriert werden, solange sie Default ist oder
von einem Run, VHDX, Mount, Plan oder Journal referenziert wird.

## 7. Providerneutraler Storage- und SQL-Dateiplan

### 7.1 Zwei getrennte Dokumente

Der portable Intent beschreibt fachliche Anforderungen. Der lokale Bound Plan
bindet diese Anforderungen an konkrete Storage-Locations und Geräte.

Portable Anforderungen enthalten beispielsweise:

```json
{
  "placementPolicy": "explicit",
  "physicalIsolation": "required",
  "roles": {
    "defaultData": { "selector": "data-fast" },
    "defaultLog": { "selector": "log-durable" },
    "backup": { "selector": "backup-capacity" }
  },
  "tempDb": {
    "distribution": "one-file-per-physical-device",
    "dataFileCount": 4,
    "logPlacement": { "selector": "tempdb-log" }
  }
}
```

Der lokale Bound Plan enthält dagegen konkrete `LocationId`, `VolumeId`,
`BackingDeviceIds`, VHDX-/Mount-Identitäten und Gastpfade. Er bleibt lokal und
wird nicht als portables Beispiel versioniert.

### 7.2 Platzierungsobjekte

Die erste Vertragsversion umfasst:

- Defaultpfad für neue User-Data-Files;
- Defaultpfad für neue User-Log-Files;
- Backup-Defaultpfad;
- jedes einzelne TempDB-Datenfile;
- das TempDB-Logfile;
- explizite Data- und Log-Files bei `New-SqlServerLabDatabase`;
- Restore-Mapping jedes aus `RESTORE FILELISTONLY` erkannten Data-/Log-Files;
- spätere Sample- und Baseline-Restores über denselben Mappingvertrag.

Die explizite Verschiebung von SQL-Systemdatenbanken ist nicht Teil der ersten
Version.

### 7.3 TempDB-Dateiverteilung

| Modus | Bedeutung |
|---|---|
| `single-location` | alle TempDB-Datenfiles auf einer Location |
| `round-robin` | Dateien gleichmäßig über ausgewählte Locations verteilen |
| `explicit` | jedes File wird einzeln einer Location zugeordnet |
| `one-file-per-volume` | jedes File benötigt eine andere `VolumeId` |
| `one-file-per-physical-device` | Backing-Device-Sets aller Files müssen paarweise disjunkt sein |

Beispiel für vier Files auf vier unterschiedlichen Festplatten:

```text
tempdev.mdf  -> Location temp-01 -> Host-Device A -> Gast T:\TempDB
temp2.ndf    -> Location temp-02 -> Host-Device B -> Gast U:\TempDB
temp3.ndf    -> Location temp-03 -> Host-Device C -> Gast V:\TempDB
temp4.ndf    -> Location temp-04 -> Host-Device D -> Gast W:\TempDB
templog.ldf  -> Location log-01  -> Host-Device E -> Gast X:\TempDBLog
```

Vier Laufwerksbuchstaben oder vier Partitionen auf derselben Festplatte
erfüllen `one-file-per-physical-device` nicht. Bei Storage Spaces, RAID, SAN,
virtuellen Disks oder nicht auflösbarer Topologie lautet der Nachweis
`Unknown`. Der strikte Modus wird dann blockiert; der Benutzer kann bewusst auf
`one-file-per-volume` oder `logical-only` wechseln, aber der Reviewtext darf
dies nicht als physische Trennung bezeichnen.

### 7.4 Data- und Log-Files

Neben Defaultpfaden kann ein Datenbankplan einzelne Files binden:

```text
AppDB_Data01 -> Location data-01
AppDB_Data02 -> Location data-02
AppDB_Log01  -> Location log-01
```

Die Zuordnung gilt sowohl für neu erzeugte Datenbanken als auch für Restore-
`MOVE`-Ziele. Eine fehlende oder mehrdeutige Bindung blockiert die Mutation vor
`CREATE DATABASE` beziehungsweise `RESTORE DATABASE`.

## 8. Capability- und Providerplanung

### 8.1 Erforderliche Capabilities

```text
logical-storage-separation
host-location-binding
physical-device-topology
per-file-tempdb-placement
per-file-database-placement
storage-iops-throttle
storage-capability-measurement
```

### 8.2 Hyper-V

Hyper-V ist der Referenzprovider für reproduzierbare physische Hostplatzierung:

1. pro gebundener Location und I/O-Lane eine scopegebundene VHDX erzeugen;
2. VHDX unter dem ausgewählten `Lab_Data`-Root ablegen;
3. Hostpfad, Volume und Backing Devices vor Attach erneut prüfen;
4. VHDX per SCSI anbinden und tatsächliche Objekt-ID persistieren;
5. Gastdatenträger über DiskIdentifier initialisieren;
6. stabilen Gastpfad vergeben; Laufwerksbuchstaben oder NTFS-Mountpoints sind
   Darstellungsdetails des Bound Plans;
7. SQL-Dateiplan anwenden;
8. Host-, VM-, Gast- und SQL-Receipt gemeinsam verifizieren.

Wenn mehrere TempDB-Files dieselbe Location teilen, genügt eine VHDX für diese
Location. Für `one-file-per-physical-device` besitzt jedes File eine eigene
Location und damit eine eigene VHDX-Lane.

### 8.3 Docker und Podman

Named Volumes können logische Pfade trennen, garantieren unter Docker Desktop,
WSL oder einer Podman Machine aber keine Ablage auf verschiedenen physischen
Windows-Festplatten. Deshalb gilt zunächst:

- logische Data-/Log-/TempDB-Mounts sind capability-basiert zulässig;
- Named Volumes erfüllen keine geforderte physische Hosttrennung;
- schreibende NTFS-Host-Mounts bleiben Advanced und fail-closed;
- ein expliziter C-/D-/E-Root oder physischer Trennungszwang routet zu Hyper-V
  oder endet mit `UNSUPPORTED`;
- eine spätere Freigabe benötigt je Runtime einen realen SQL-2025-, Restart-,
  Restore-, Berechtigungs- und Cleanup-Nachweis.

## 9. SQL-Anwendung und Postconditions

### 9.1 Defaultpfade

Nach der SQL-Bereitschaft werden Defaultpfade für Data, Log und Backup über
den bestehenden SQL-Konfigurationspfad gesetzt. Die Runtime prüft anschließend
die gespeicherten Serverwerte und die Existenz/Schreibbarkeit der Ziele.

### 9.2 TempDB

Die Installation darf zunächst einen bootstrapfähigen TempDB-Zustand erzeugen.
Danach:

1. gewünschte Datenfiles mit stabilem Logical Name aufbauen;
2. jedes File per `ALTER DATABASE tempdb MODIFY FILE` auf den gebundenen Pfad
   setzen;
3. überzählige Files nur nach eindeutigem Plan entfernen;
4. SQL-Dienst kontrolliert neu starten;
5. `tempdb.sys.database_files` und `sys.master_files` prüfen;
6. Anzahl, Logical Name, physischer Pfad, Größe und Growth mit dem Bound Plan
   vergleichen;
7. bei Abweichung `SQL_STORAGE_POSTCONDITION_FAILED` und Recovery-Information
   persistieren.

Das TempDB-Log bleibt standardmäßig genau eine Datei und besitzt eine eigene
Placement-Bindung. Mehrere TempDB-Logfiles werden nicht als Performanceprofil
angeboten.

### 9.3 Neue Datenbanken und Restore

`New-SqlServerLabDatabase` und Restore verwenden denselben File-Placement-
Resolver. `RESTORE FILELISTONLY` liefert die Logical Names; der Bound Plan
erzeugt für jedes File genau ein `MOVE`-Ziel. Nach Erstellung oder Restore
werden alle Pfade über SQL erneut gelesen und mit dem Plan verglichen.

## 10. Port-, Status-, Collation- und I/O-UX

### 10.1 Portprüfung

Ein gemeinsamer `Test-LabEndpointBinding` prüft:

- aktive lokale TCP-Listener;
- Docker- und Podman-Portbindings, auch gestoppter verwalteter Container;
- reservierte Ports anderer Lab-Pläne;
- den aktuellen Port beim Reconcile als zulässige Selbstbelegung;
- die Providersemantik.

Ein Container-Hostport muss lokal frei sein. Ein Hyper-V-SQL-Port liegt dagegen
im Gast und darf auf unterschiedlichen Gast-IP-Adressen jeweils 1433 sein. Der
Bound Plan beschriftet deshalb `Hostport` und `SQL-Port im Gast` getrennt.
Die endgültige Containerprüfung läuft unter dem hostweiten Port-Lock direkt
vor dem Runtime-Create.

### 10.2 Statuszentrum

Das Hauptmenü lädt nur eine kompakte Anzahl und Attention-Snapshot. `[2] Status`
zeigt auf Anforderung:

- Umgebungsname, Run-Präfix, Provider und Runtime-State;
- SQL-Version und Readiness;
- secretfreien Endpunkt beziehungsweise maskierten Connection String;
- Autostart;
- gebundene Storage-Rollen und Dateiplan-Zusammenfassung;
- Recovery- und Attention-Status.

Automatisch erzeugte Kennwörter werden nur durch eine eigene, ausdrücklich
gewählte Reveal-Aktion angezeigt, nicht beim normalen Status- oder Menürendern.

### 10.3 Kontextabhängige Review-Verben

| Kontext | Aktionstext |
|---|---|
| Neuanlage | `Umgebung mit dieser Auswahl erstellen` |
| Änderung | `Änderungen anwenden` |
| Prüfung | `Prüfung starten` |
| Migration | `Freigegebenen Migrationsplan ausführen` |
| Entfernen | `Ausgewählte Umgebung entfernen` |

### 10.4 Collation-Suche

Ein versionierter Katalog enthält je unterstützter SQL-Major-Version mindestens
Name, Codepage, LCID, Case-/Accent-Sensitivity, UTF-8-Eigenschaft und Status.
Die Console-UI filtert tokenbasiert; `Latin1` zeigt nur passende Einträge.
Die ausgewählte Collation wird vor Mutation katalog- und anschließend
SQL-seitig verifiziert. Freie Namen sind nur in einem klar markierten
Advanced-Pfad mit Warnung zulässig.

### 10.5 I/O-Evidenz

Die Storage-Ansicht zeigt ohne Benchmark:

- Volume, Backing-Device-Nachweis und Medientyp;
- freien Speicher und Health;
- vorhandene IOPS-Limits;
- letztes passendes Benchmark-Receipt, falls vorhanden.

Eine optionale Messung läuft ausschließlich nach Bestätigung mit dokumentierter
Blockgröße, Queue Depth, Read/Write-Mix, Testdateigröße und Dauer. Sie schreibt
nur in einen markierten temporären Scope der gewählten `Lab_Data`-Location,
räumt ihn anschließend auf und bezeichnet das Ergebnis als host- und
profilbezogene Messung, niemals als garantierten Maximalwert.

## 11. Detaillierte Arbeitspakete

### Phase A – P0-Fehler und Seiteneffekte

| ID | Schritt | Primäre Dateien | Abschlusskriterium |
|---|---|---|---|
| `FIX-001` | Ungültiges `-Passthru` aus PowerShell Direct entfernen; toten Code hinter `return Invoke-Command` prüfen; echten Parametervertrag testen. | `Providers/HyperV/HyperVProvider.ps1`, Hyper-V-Providerchecks | Windows-Installationsprüfung erreicht den Receipt-Pfad ohne Parameterfehler. |
| `LIF-001` | `ActionResult/1.0` einführen und New/Start/Stop/Restart/Remove/Clear/Rename zuerst anbinden. | `Public/Invoke-SqlServerLab.ps1`, Lifecycle-Public-Funktionen | Jede Aktion unterscheidet Changed, NoChange, Cancelled und Failed. |
| `LIF-002` | Connection-Center-/CMS-Sync aus pauschalen Menüzweiglisten entfernen und an Ergebnisstatus plus `ConnectionCenterImpact` binden. | `Public/Invoke-SqlServerLab.ps1`, `Public/Sync-SqlServerLabConnectionCenter.ps1` | `Cancelled`, `NoChange`, `Skipped`, Ablehnung und Fehler erzeugen null Sync; eine erfolgreiche endpunktrelevante Aktion genau einen. Insbesondere „Löschen abgebrochen“ ruft CMS nicht auf. |
| `PORT-001` | gemeinsamen Endpoint-Binding-Check aus vorhandener Portermittlung bauen und im Review verwenden. | `Private/PortAllocation.ps1`, `Public/Invoke-SqlServerLab.ps1` | Belegte Ports werden mit Besitzer/Grund blockiert. |
| `PORT-002` | finale Portprüfung unter dem Allocation-Lock unmittelbar vor Container-Create erzwingen. | Containerprovider, `Private/PortAllocation.ps1` | Kein TOCTOU-Doppelbinding bei parallelen Läufen. |
| `UAC-001` | vorgelagerte Bestätigung testen; Ablehnung als `Cancelled/NoChange` in den Action-Vertrag übernehmen. | `Private/Elevation.ps1`, Static Checks | `n` startet keinen Prozess; `j` genau einen; elevated startet keinen zweiten. |
| `PRV-001` | Aktionen nach `User`, `RuntimeAccess` und `Administrator` klassifizieren; Erhöhung erst nach Action Preview anfordern. | Entrypoint, Elevation, Hilfe | Read-only und normale Containerbedienung starten ohne UAC; Hyper-V-/Datenträgeraktion erklärt und erhöht gezielt. |

### Phase B – Console-UI vollständig migrieren

| ID | Schritt | Abschlusskriterium |
|---|---|---|
| `CUI-012` | automatisches Inventar aller direkten Auswahl-`Read-Host`-Muster erstellen und als Testgate aufnehmen | Kein neues nicht freigegebenes Auswahlmenü kann eingecheckt werden. |
| `CUI-013` | Storage-Hauptmenü, Location-Auswahl, Defaultwechsel und Migration auf Console-UI umstellen | Pfeile/Enter/Escape funktionieren; Aktionen kehren ins Storage-Menü zurück. |
| `CUI-014` | Connection Center, CMS und Providerauswahl migrieren | Alle Ebenen besitzen denselben Navigation- und Abbruchvertrag. |
| `CUI-015` | Zieltyp, Patch/CU, Ressourcenprofil und verbleibende Erstellungsoptionen migrieren | Erstellungsworkflow enthält keine direkte bekannte Optionsliste per `Read-Host`. |
| `CUI-016` | verbleibende Hyper-V-Build-, Medien-, Quell-VM- und Fortsetzungslisten migrieren | Hyper-V-Auswahllisten verwenden stabile IDs und `Escape`. |
| `CUI-017` | globale Enter-Pause entfernen und echte Ergebnisansicht definieren | Kein unnötiger `[Enter] fuer Menue...`-Zwischenschritt. |
| `CUI-018` | kontextabhängige Review-Verben und klare Next-Action-Texte einführen | Neuanlage, Änderung und Prüfung sind sprachlich eindeutig. |
| `CUI-019` | diagnostischen Console-Modus `Auto|Fallback` am PowerShell-7-Einstieg durchreichen | Der Fallback ist im normalen Terminal reproduzierbar testbar, ohne einen ungeeigneten Host erraten zu müssen. |
| `CUI-020` | direkte Werteingaben auf einen gemeinsamen Eingabevertrag `Confirmed|Cancelled|Aborted` migrieren | `Escape` verwirft die aktuelle Erfassung und navigiert genau eine Ebene zurück; kein direkter `Read-Host`-Pfad umgeht den Vertrag. |
| `CUI-021` | globalen `Ctrl+C`-Vertrag für UI, PowerShell-Pipelines, Warteoperationen und native Prozesse implementieren | Nutzerabbruch beendet die laufende Verarbeitung; `PipelineStoppedException` wird nicht verschluckt; atomare Operationen rollen zurück oder markieren `RECOVERY_REQUIRED`. |

Stand 2026-08-28 ist `CUI-019` implementiert und im realen PowerShell-7-PTY
abgenommen. Der Console-UI-Anteil von `CUI-021` ist ebenfalls real belegt:
Cursor- und erzwungener Fallback-Modus beenden bei `Ctrl+C` die gesamte aktuelle
Verarbeitung. Die breitere `CUI-021`-Abnahme für Warteoperationen und native
Kindprozesse bleibt ein eigener Nachweis und wird durch diese Menüabnahme nicht
vorweggenommen.

### Phase C – Storage-Registry härten

**Status:** `IMPLEMENTED_STATICALLY` seit 2026-08-29. Legacy-Übernahme,
Pfadnormalisierung, expliziter Defaultwechsel, Referenzschutz, Topologiebeleg
und Location-basierte Parent-Migration sind fokussiert und schema-validiert.
Der reale Vier-Geräte-Nachweis gehört zu Phase D und Gate N5.

| ID | Schritt | Abschlusskriterium |
|---|---|---|
| `STO-009` | Legacy-Default idempotent in Storage/2.x übernehmen | Ein vorhandenes D bleibt beim Hinzufügen von C Standard. |
| `STO-010` | stabile `LocationId` und vollständige absolute Pfadvalidierung einführen | `D:` blockiert; `D:\` wird vor Bestätigung als `D:\Lab_Data` gezeigt. |
| `STO-011` | Default explizit ändern und referenzierte Locations geschützt deregistrieren | Keine implizite Defaultänderung und kein Entfernen aktiver Bindings. |
| `STO-012` | Volume- und Backing-Device-Topologie erfassen | Volume-Trennung und physische Trennung werden separat ausgewiesen. |
| `STO-013` | bestehende Migration auf `LocationId` und Defaultwechsel anpassen | Plan/Journal bleiben nach Laufwerksbuchstabenwechsel auflösbar. |

### Phase D – File Placement und Providerbindung

| ID | Schritt | Abschlusskriterium |
|---|---|---|
| `SFP-001` | Storage-Intent-, Bound-Plan- und Receipt-Schemas versionieren | Portable Anforderungen und lokale Bindings sind getrennt. |
| `SFP-002` | UI für Default Data, Default Log, Backup, TempDB-Data-Files und TempDB-Log erstellen | Jede Datei/Role ist in der Review sichtbar. |
| `SFP-003` | Modi `single`, `round-robin`, `explicit`, `one-file-per-volume` und `one-file-per-physical-device` planen | Unzureichende oder unbekannte Topologie blockiert strikte Anforderungen. |
| `HVS-001` | Hyper-V-VHDX pro Location/I/O-Lane erzeugen und binden | Hostpfad, VHDX-ID, Gastdisk und SQL-Ziel sind durch Receipts verbunden. |
| `HVS-002` | Gastinitialisierung und stabile Pfadvergabe für mehrere Storage-Lanes erweitern | vier TempDB-Lanes lassen sich eindeutig initialisieren und wiederaufnehmen. |
| `SQLS-001` | SQL-Defaultpfade und TempDB-Fileplan anwenden | Dienstrestart und SQL-Postconditions stimmen vollständig. |
| `SQLS-002` | `New-SqlServerLabDatabase` an dateigenaue Bindings koppeln | Data- und Log-Files landen auf den geplanten Zielen. |
| `SQLS-003` | Restore-`MOVE` aus Filelist und Bound Plan erzeugen | jedes Backupfile besitzt genau ein verifiziertes Ziel. |
| `CNTS-001` | Container-Capabilities ehrlich klassifizieren | logische Trennung wird nicht als physische Hosttrennung ausgegeben. |
| `CNTS-002` | optionalen Hostbinding-Pfad erst nach realer Runtimeabnahme freigeben | ohne Nachweis routet physische Trennung zu Hyper-V oder `UNSUPPORTED`. |

### Phase E – Status, Suche und I/O-Kontext

| ID | Schritt | Abschlusskriterium |
|---|---|---|
| `STS-001` | Hauptbanner auf Counts/Attention reduzieren; Detailstatus unter `[2]` bündeln | Hauptmenü lädt keine vollständigen Connection Strings. |
| `STS-002` | Status um Storage-/Dateiplan und sichere Endpunkte erweitern | Benutzer erkennt Provider, Status, Port und File Placement an einer Stelle. |
| `STS-003` | kopierfertigen Connection String in `[2] Status` aus der kanonischen Run-Verbindung auflösen | Jede verwendbare SQL-Instanz zeigt Provider, Instanz, Host, Port und Connection String; automatisch erzeugte Testzugänge enthalten das abrufbare Kennwort, andere Secrets bleiben maskiert. |
| `COL-001` | Collation-Katalog, Suche und Versionfilter implementieren | `Latin1` liefert navigierbare gültige Treffer. |
| `IO-001` | Storage-Fakten und vorhandene Receipts anzeigen | IOPS-Eingabe besitzt nachvollziehbaren Zielkontext. |
| `IO-002` | optionales, explizites Messprofil mit Cleanup entwickeln | Messung ist reproduzierbar beschrieben und niemals automatisch. |

### Phase F – Regression und Dokumentationsabschluss

| ID | Schritt | Abschlusskriterium |
|---|---|---|
| `QUAL-UI-001` | synthetische Key-, Escape-, Resize-, Untermenü- und Fallbacktests ergänzen | alle Auswahlmenüs erfüllen denselben Vertrag. |
| `QUAL-UI-002` | `Escape` und `Ctrl+C` für Werteeditor, Formular, Untermenü, Hauptmenü, Warteoperation und Fehlerbehandlung testen | `Escape` navigiert genau eine Ebene; `Ctrl+C` beendet den Gesamtvorgang und wird nicht als normaler Fehler fortgesetzt. |
| `QUAL-STS-001` | Statusausgabe für Container, Hyper-V und automatisierte Testumgebung mit und ohne generiertes Secret testen | Connection String steht unter `[2] Status`; die Secretdarstellung entspricht exakt dem dokumentierten Vertrag. |
| `QUAL-LIF-001` | CMS-Call-Counter für Löschung abgebrochen, Escape, Ablehnung, Cancelled, NoChange, Skipped, Changed und Failed testen | Alle nicht mutierenden Ergebnisse erzeugen null CMS-/Connection-Center-Aufrufe; erfolgreiche endpunktrelevante Änderungen genau einen. |
| `QUAL-STO-001` | Legacy-D-, Pfad-, Default-, Location- und Referenzschutz testen | keine stillen Storage-Umschaltungen. |
| `QUAL-STO-002` | physische Topologieszenarien einschließlich `Unknown` testen | strikte Trennung kann nicht durch Partitionen vorgetäuscht werden. |
| `QUAL-SQL-001` | TempDB mit vier Files auf vier Lanes, separates Log und SQL-Postconditions testen | Filepfade stimmen nach Restart. |
| `QUAL-SQL-002` | Datenbankcreate und Restore mit getrennten Data-/Log-Zielen testen | `sys.master_files` entspricht dem Bound Plan. |
| `QUAL-HV-001` | realen Windows-Generalize-/Publish-Pfad wiederholen | kein `Passthru`-Fehler; zustandsgebundene Fortsetzung erfolgreich. |
| `QUAL-DOC-001` | README, Hilfe, Known Limitations, Schemas und Beispiele synchronisieren | keine Funktion wird vor Runtimeabnahme als validiert bezeichnet. |

## 12. Empfohlene Änderungssätze

1. `FIX-001`, `LIF-001`, `LIF-002`, `PORT-001`, `PORT-002`, `UAC-001`;
2. `CUI-012` bis `CUI-019` ohne Storage-Fachausbau;
3. `STO-009` bis `STO-013` einschließlich Legacy-Migration;
4. `SFP-001` bis `SFP-003` als reiner Plan-/Schema-/UI-Vertical-Slice ohne
   Runtimeversprechen;
5. `HVS-001`, `HVS-002`, `SQLS-001` mit TempDB-Referenzfall;
6. `SQLS-002`, `SQLS-003` für neue Datenbanken und Restore;
7. `CNTS-001`, danach `CNTS-002` nur bei positivem Realnachweis;
8. `STS-001`, `STS-002`, `COL-001`, `IO-001`; `IO-002` bleibt nachgelagert;
9. vollständige Phase F und Aktualisierung des Runtime-Status.

Zwischen Änderungssatz 3 und 4 ist ein Format-/Schema-Review erforderlich.
Zwischen Änderungssatz 4 und 5 muss der Bound Plan mit synthetischen
Storage-Topologien vollständig testbar sein, ohne VHDX oder SQL zu mutieren.

## 13. Manuelle Testkontexte und Berechtigungen

| Testlane | Startkontext | Beispiele | Erwartete Erhöhung |
|---|---|---|---|
| Console Cursor | aktueller Account, nicht erhöht, PowerShell 7 | Navigation, Status, Formulare, Abbruch, Docker/Podman soweit Runtimezugriff vorhanden | keine pauschale UAC-Abfrage |
| Console Fallback | derselbe Account und dasselbe PowerShell-7-Terminal mit diagnostischem `Fallback`-Modus | nummerierte/buchstabenbasierte Auswahl, `0`, Abbruch und gleiche Fachaktionen | wie bei Cursor; Renderer ändert keine Rechte |
| UAC-Übergang | nicht erhöht starten | Hyper-V-, Datenträger- oder andere geschützte Aktion wählen | zuerst erklärende Standard-Nein-Bestätigung, danach genau eine UAC-Abfrage |
| Erhöhte Runtime | nach bestätigtem UAC-Übergang | Hyper-V-Build, Generalize, VHDX-/Datenträgerbindung | neues erhöhtes PowerShell-7-Fenster; kein zweiter Elevationsloop |
| Standardkonto ohne Administratormitgliedschaft | nicht erhöht; bei Bedarf Administrator-Credentials in Windows-UAC | dieselben Übergangstests | Produkt verlangt kein dauerhaft als Administrator angemeldetes Benutzerkonto |

Reine Navigation, Status, Cancel-/No-op-Prüfungen und Containerpfade werden
zuerst im normalen Benutzerkontext getestet. So wird verhindert, dass eine
dauerhaft erhöhte Konsole fehlende oder zu frühe Elevationsübergänge verdeckt.
Ob Docker oder Podman ohne Administratorrechte zugänglich ist, hängt von der
lokalen Runtime-Berechtigung ab und wird als `RuntimeAccess`, nicht pauschal als
Administratoranforderung ausgewiesen.

## 14. Abnahmematrix

| Szenario | Erwartung |
|---|---|
| Stop-Menü öffnen und `Escape` | Status unverändert, kein CMS-Sync, sofort zurück |
| Stop erfolgreich | tatsächlicher Zustand `STOPPED`, genau ein CMS-Sync |
| Storage `[2]` | Snapshot aktualisiert, Fokus bleibt, Storage-Menü bleibt offen |
| `D:` eingeben | blockierende Erklärung für laufwerksrelativen Pfad |
| Legacy-D vorhanden, C hinzufügen | D bleibt Default; C wird nur registriert |
| Default explizit auf C ändern | Review nennt globale Fallbackwirkung; Änderung erst nach Bestätigung |
| Port 1433 durch Hostdienst belegt | Containerreview blockiert |
| CMS nutzt 14333 | manuelle Eingabe 14333 blockiert und nennt Belegung |
| Port 0 | unter Lock wird ein freier Port vergeben |
| Hyper-V-Gäste auf verschiedenen IPs verwenden 1433 | kein falscher Hostportkonflikt |
| vier TempDB-Files, vier getrennte physische Geräte | Plan und SQL-Verifikation `PASS` |
| vier TempDB-Files, vier Partitionen auf einem Gerät | strikter physischer Modus blockiert |
| Backing Device nicht auflösbar | `Unknown`, kein vorgetäuschtes `PASS` |
| TempDB-Log auf eigener Location | Pfad und Receipt stimmen nach SQL-Restart |
| User-Data auf D, User-Log auf C, TempDB auf E/F/G/H | VHDX-/Gast-/SQL-Pfade stimmen durchgängig |
| Docker Named Volumes plus physische Trennung gefordert | Provider wird abgelehnt oder Hyper-V gewählt |
| Hauptmenü öffnen | keine vollständige Endpunkt-/Secretauflösung |
| Status öffnen | sichere Endpunkte und Storage-Zusammenfassung vollständig |
| normaler Start im Benutzerkontext | keine UAC-Abfrage vor Auswahl einer privilegierten Aktion |
| Console-Modus `Fallback` im selben `pwsh`-Terminal | nummerierte/buchstabenbasierte Bedienung; keine fachliche Abweichung zum Cursor-Modus |
| UAC-Vorabfrage ablehnen | kein neues Fenster und kein UAC-Dialog |
| Windows-Build generalisieren | PowerShell Direct, Sysprep, Shutdown und nächste Aktion eindeutig |

## 15. Definition of Done

Die Konsolidierungswelle ist erst abgeschlossen, wenn:

1. alle P0-Beobachtungen durch automatische Regression und den passenden
   realen Runtimepfad geschlossen sind;
2. kein bekanntes Auswahlmenü außerhalb der gemeinsamen Console-UI verbleibt
   und der Fallback im selben PowerShell-7-Terminal gezielt testbar ist;
3. `Escape` in jeder Auswahl und Werteerfassung genau eine Ebene zurückgeht;
4. `Ctrl+C` die gesamte aktuelle Verarbeitung beendet, ohne als normaler Menüfehler verschluckt zu werden;
5. der globale Enter-Wartepunkt entfernt ist;
6. Legacy-Defaults ohne stille Änderung in die Multi-Root-Registry übernommen
   werden;
7. freie oder laufwerksrelative Storage-Pfade vor Mutation blockiert werden;
8. Data-, Log-, einzelne TempDB-Data-Files, TempDB-Log und Backup getrennt
   geplant werden können;
9. ein Referenzfall mit vier TempDB-Files auf vier nachweislich getrennten
   physischen Geräten erfolgreich verifiziert wurde;
10. Container keine nicht nachgewiesene physische Platzierung versprechen;
11. SQL-Postconditions jeden geplanten Dateipfad bestätigen;
12. `[2] Status` pro verwendbarer Instanz einen kopierfertigen Connection String zeigt und Secrets nur gemäß dem dokumentierten Vertrag offenlegt;
13. Status und Connection Center Secrets standardmäßig maskieren;
14. normale Bedienung ohne vorsorgliche Administratorrechte möglich ist und
    privilegierte Aktionen genau einen erklärten Elevationsübergang besitzen;
15. Dokumentation, Schema, Hilfe, Tests und Runtime denselben Vertrag
    ausweisen.
