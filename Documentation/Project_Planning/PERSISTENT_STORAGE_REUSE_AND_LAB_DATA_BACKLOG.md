# Persistente SQL-Speicher, Wiederverwendung und `Lab_Data` – Backlog

## Status und Priorität

`ACTIVE / PSR_001_PARTIAL_PSR_002_COMPLETE_PSR_003_004_006_READ_ONLY_PSR_005_007_008_009_010_IMPLEMENTED_CORE` – die vorhandenen
Persistenzmechanismen schützen bereits Teile des SQL-Zustands, bilden aber noch
keinen vollständigen, providerübergreifenden Wiederverwendungs- und
Löschvertrag. Planung ist kein Implementierungs- oder Runtime-Nachweis.

Der P0-Bugfix zur verbindlichen Ablage aller neuen Hyper-V-Ressourcen unter
registrierten `Lab_Data`-Roots bleibt vorrangig. Die Bestandsanalyse dieses
Backlogs darf parallel beginnen; mutierende Storage-Migrationen und der breite
Produktpfad folgen erst auf geklärte Root-, Ownership-, Recovery- und
Cleanup-Grenzen.

Der erste read-only `PSR-001`-Slice ist implementiert. Der Cleanup-Audit liefert
den getrennten Vertrag `SqlServerLab.StorageResidencyInventory/1.0` mit stabilen
Objektidentitäten, Provider-Coverage, logischem Eigentum, physischer
Pfadklassifikation, Lebensdauer, Retention, Cleanup-Policy und Auditstatus.
`Lab_Data`, native Docker-/Podman-Runtime-Namensräume, externe Hostpfade,
Hyper-V-Run-/Shared-Ressourcen und Legacy-/Repository-Residuen werden nicht
gleichgesetzt. Ein Providerpfad innerhalb einer Runtime-VM gilt ausdrücklich
nicht als hostseitige `Lab_Data`-Ablage. Die vollständige Auflösung der
physischen Docker-Desktop-/Podman-Machine-Backing-Disks bleibt offen; `PARTIAL`
ist deshalb ein gültiger Auditstatus und kein positiver Vollständigkeitsnachweis.

`PSR-002` ist durch den bindenden Entscheid
[`SqlServerLab.LabDataResidencyDecision/1.0`](../Architecture/LAB_DATA_AND_NATIVE_RUNTIME_STORAGE_DECISION.md)
abgeschlossen. `Lab_Data` ist der hostseitige Katalog-, Austausch-, Sicherungs-
und Recovery-Einstieg, kein falsches Vollresidenzversprechen für gemeinsam
genutzte Container-Runtimes. Katalogisierte native Instanzstores bleiben
zulässig; globale Docker-/Podman-Ablagen, labfremde Ressourcen und externe
Pfade bleiben ohne eigenen Ownership- und Migrationsvertrag außerhalb des
Mutationsscopes. Neue Hyper-V-Hostdateien bleiben an registrierte `Lab_Data`-
Bindings gebunden.

Der read-only Slice `PSR-003` ist implementiert. Der strenge Vertrag
`SqlServerLab.PersistentStorageCatalog/1.0` führt eine eigenständige
`PersistentStorageId`, die Klassen `INSTANCE_STORE`, `DATABASE_PACKAGE`,
`BACKUP_SET` und `EXCHANGE_WORKSPACE`, den vollständigen Zustandsraum,
Referenzen und genau eine exklusive Lease. Der Parser führt identische,
controllergebundene Katalogspiegel zusammen und blockiert ungültige oder
divergierende Spiegel. `SqlServerLab.PersistentStoragePlan/1.0` bindet diese
Einträge read-only an das Residency-Inventar und meldet retained Objekte ohne
erfundene ID als Registrierungskandidaten. Katalogschreiben, Lease-Erwerb,
Wiederverwendung und Löschung bleiben getrennte Folgearbeit.

Der read-only Slice `PSR-004` ist ebenfalls implementiert. Ein strikter
`SqlServerLab.PersistentStorageRemovalIntent/1.0` bindet die sechs
Retention-/Removal-Policies an Run- und Storage-ID sowie aktive
Datenbankreferenzen. `SqlServerLab.PersistentStorageRemovalPlan/1.0` ordnet
Scope-, Referenz- und Lease-Prüfung vor jede Folge, verlangt für Backups
`CHECKSUM` und `RESTORE VERIFYONLY`, für Pakete Offline-/Detach-Evidence,
vollständiges Dateiinventar, SHA-256 und Postcondition und setzt Fehler ab der
ersten Mutation auf `RECOVERY_REQUIRED`. Fremde Referenzen, Recovery-Zustände
und nicht katalogisierte retained Objekte blockieren. Der Plan selbst führt
nichts aus; endgültige Löschung eines persistenten Stores bleibt eine eigene,
noch nicht implementierte Expertenaktion.

Der Core-Slice `PSR-005` ist implementiert und für Docker und Podman getrennt
real belegt. `SqlServerLab.ContainerInstanceStoreIntent/1.0` wählt eine bereits
katalogisierte Quelle ausschließlich über ihre stabile `PersistentStorageId`;
Planner und Runtime-Revalidierung verlangen ein passendes unveränderliches
Volume-Label, dieselbe SQL-Major-Version, `AVAILABLE` oder `DETACHED`, keine
Lease, keine aktive Referenz und keinen angehängten Container. `CONTINUE`
liefert die revalidierte `/var/opt/mssql`-Bindung. `CLONE` erstellt ein neues,
operationsgebundenes Ziel, mountet die Quelle nur read-only, vergleicht
Dateizahl, Bytes und SHA-256-Inhaltsdigest und bleibt bei Fehlern über ein
`RECOVERY_REQUIRED`-Journal fortsetzbar. Die realen Docker- und Podman-Läufe
bestätigen nach Recreate und im Clone jeweils ein Serverobjekt sowie eine
Benutzerdatenbank. Katalog-Commit/Lease-Akquisition, External-Runtime-Sidecars
und öffentliche CLI-/GUI-Anbindung bleiben getrennte Folgearbeit.

Der read-only Slice `PSR-006` ist implementiert und gegen die reale Docker-
Desktop- sowie Podman-WSL-Runtime belegt. Der sanitisierte Vertrag
`SqlServerLab.ContainerRuntimeScope/1.0` bindet den aktiven Docker-Context oder
die aktive Podman-Connection samt Machine an eine stabile, endpunktgebundene
Runtime-ID, ohne Rohendpunkt, Identity-Pfad oder Runtime-Storage-Pfad
auszugeben. Bestehende Engines und Machines bleiben `SHARED_EXTERNAL`, ihre
Hostdefaults und ihr physisches Backing `REPORT_ONLY`; Relocation, Removal,
Default-Connection-/Modusänderung und Adoption labfremder Ressourcen sind
explizit blockiert. Eine künftig dedizierte Runtime benötigt weiterhin einen
eigenen Ownership-, Location-, Capacity-, Recovery- und Cleanup-Vertrag.

Der read-only Core-Slice `PSR-010` ist implementiert. Der Vertrag
`SqlServerLab.DatabaseMigrationDependencyInventory/1.0` zählt SQL-seitig
beobachtbare Server-Login-Mappings, datenbankgebundene SQL-Agent-Jobs,
zugehörige Proxies, instanzweite Linked-Server-Kandidaten und TDE-Protectoren.
Serverkonfiguration, SSISDB und SSAS bleiben ausdrücklich
`NOT_OBSERVABLE` und verlangen externes Review. Neue Backup- und
Datenbankpaket-Receipts weisen ihren Scope als `DATABASE_FILES_ONLY` aus und
setzen `FullInstanceMigration`, Serverobjekt-, TDE-Key-, Secret- und externe
Service-Mitnahme ausnahmslos auf `false`. TDE ohne verifizierte Recovery-
Evidence bleibt blockiert. Objekt-, Host-, Credential- und Schlüsselnamen
werden nicht im sanitierten Receipt gespeichert. Export-/Import-Executor und
öffentliche CLI-/GUI-Bedienung bleiben Folgearbeit.

## Ausgangslage

Die Bezeichnung *persistenter Speicher* fasst derzeit technisch und fachlich
unterschiedliche Dinge zusammen:

- Docker und Podman binden für einen persistenten SQL-Systemzustand ein stabil
  benanntes, von der Runtime verwaltetes Volume auf `/var/opt/mssql` ein. Es
  enthält unter anderem Systemdatenbanken, Datenbankregistrierungen und die dort
  abgelegten Benutzerdatenbanken, liegt physisch aber nicht als direkt
  sichtbarer Verzeichnisbaum unter `Lab_Data`.
- Der Backup-Arbeitsbereich eines Containers ist ein separater Host-Bind-Mount
  unter `Lab_Data`.
- Optionale External-Language- und External-Library-Inhalte liegen in eigenen
  Runtime-Volumes; kurzlebige Sandboxes bleiben containerlokal.
- Ohne ausdrückliche Persistenzpolicy sind die SQL-System- und Zusatzvolumes nur
  rungebunden und werden beim regulären Cleanup entfernt.
- Hyper-V kann eine langlebige `sql-data.vhdx` unter `Lab_Data` anhängen. Bei
  einer frischen SQL-Installation kann sie Benutzer-Data, -Log, TempDB und
  Backups aufnehmen. Bei einem bereits vorbereiteten SQL-Image wird sie aktuell
  nur initialisiert; ohne weiteren Storage-Plan werden bestehende SQL-Pfade
  nicht automatisch dorthin verschoben.
- Die Hyper-V-System-/Child-VHDX trägt weiterhin Windows, Registry,
  SQL-Installation, Systemdatenbanken und Serverobjekte. Sie ist rungebunden
  und wird beim Cleanup entfernt.
- Vorhandene persistente Runtime-Volumes oder Hyper-V-Daten-VHDX können weder
  in CLI noch GUI als eigenständige Speicherressource katalogisiert, ausgewählt,
  geklont, sicher freigegeben oder gezielt gelöscht werden.

Damit erfüllt der aktuelle Containerpfad primär **Instanzpersistenz** für
Restart und Recreate. Er erfüllt noch nicht den Benutzerzweck eines sichtbaren,
zwischen Umgebungen kontrolliert wiederverwendbaren Datenbestands. Der
Hyper-V-Pfad ist ohne Attach-/Restore-Workflow noch stärker eingeschränkt.

## Zielbild

`SQL_Server_Lab` soll einen gemeinsamen, in CLI und GUI bedienbaren
Storage-Lifecycle anbieten, der vier Speicherklassen ausdrücklich trennt:

| Speicherklasse | Zweck | Portabilität |
|---|---|---|
| `INSTANCE_STORE` | Exakt denselben SQL-Instanzzustand nach Stop, Restart oder kompatiblem Recreate fortsetzen | provider- und versionsgebunden |
| `DATABASE_PACKAGE` | Vollständige MDF/NDF/LDF-/FILESTREAM-Dateimenge kontrolliert offline übergeben | Attach an genau eine kompatible Zielinstanz |
| `BACKUP_SET` | Geprüfte SQL-Backups als kanonische Übergabe zwischen Umgebungen und Providern | gleiche oder unterstützte neuere SQL-Version |
| `EXCHANGE_WORKSPACE` | Hostsichtbare Import-, Export-, Skript- und Transferdateien | providerneutral, keine aktiven SQL-Dateien |

Ein persistenter Speicher erhält eine stabile, vom Anzeigenamen unabhängige
`PersistentStorageId`. Er bleibt auch ohne aktiven Run katalogisiert und darf
nicht allein aus Labname, Instanz-ID oder einem erneut berechneten Runtime-Namen
identifiziert werden.

## Gewünschter `Lab_Data`-Einstiegspunkt

Der Benutzer soll einen klaren Verzeichniseinstiegspunkt besitzen, unter dem
jedes System seine fachlich zugeordneten Ressourcen ablegt. Das folgende Layout
ist ein zu prüfender Zielentwurf und noch kein festgelegter physischer Vertrag:

```text
Lab_Data
└── PersistentStores
    └── <PersistentStorageId>
        ├── store.json
        ├── Backups
        ├── DatabasePackages
        │   └── <DatabaseId>
        │       ├── data
        │       ├── log
        │       ├── filestream
        │       └── database.json
        ├── Exchange
        └── ProviderData
            ├── docker
            ├── podman
            └── hyperv
```

Direkte Sichtbarkeit bedeutet nicht, dass aktive Datenbankdateien gleichzeitig
vom Host und vom SQL-Dienst geöffnet oder von mehreren SQL-Instanzen schreibend
verwendet werden dürfen. Wo ein providergeeigneter nativer Datenträger
erforderlich ist, stellt das Produkt sichere Export-, Materialize-, Clone- und
Import-Aktionen bereit, anstatt eine gefährliche Dateifreigabe vorzutäuschen.

## Katalog- und Metadatenvertrag

Jeder Speicher muss mindestens folgende geheimnisfreie Metadaten besitzen:

- stabile Storage-, Datenbank- und Revision-Identitäten;
- Speicherklasse, Providerbackend und physische beziehungsweise logische
  Location-Bindung;
- erzeugende Umgebung, SQL-Version, Edition, Plattform und Build;
- Datenbanken, logische Dateinamen, Dateitypen, relative Pfade, Größen und
  SHA-256-Werte;
- vollständige FILESTREAM-Container und deren Zuordnung;
- Backup-Typ, LSN-/Zeitbezug, `CHECKSUM`-/Verifikationsstatus und Restore-
  Evidence;
- Verschlüsselungsstatus und benötigte, **nicht im Katalog gespeicherte**
  TDE-/Zertifikats- oder Credential-Abhängigkeiten;
- letzte saubere SQL-Offlining-/Detach-, Backup- oder Shutdown-Evidence;
- Zustand `AVAILABLE`, `IN_USE`, `DETACHED`, `INCOMPLETE`, `RECOVERY_REQUIRED`
  oder `DELETE_PENDING`;
- exklusive Lease beziehungsweise aktuell gebundene Umgebung;
- Retention-, Cleanup-, Clone- und Löschpolicy.

Der Katalog darf weder Passwörter noch private Schlüssel, konkrete
Credential-Werte oder ungeschützte TDE-Key-Backups enthalten.

## Datenbank-, FILESTREAM- und Backup-Lifecycle

### Kanonischer Portabilitätspfad

Ein vollständiges SQL-Backup ist der Standard für den Wechsel zwischen
Umgebungen und Providern. FILESTREAM-Daten müssen im vollständigen Backup
enthalten und beim Restore tatsächlich verifiziert werden. Ein Backup wird erst
als wiederverwendbar veröffentlicht, wenn mindestens SQL `CHECKSUM`,
`RESTORE VERIFYONLY`, Hash und Metadatenreceipt erfolgreich vorliegen. Für
höhere Schutzklassen ist ein realer testweiser Restore der stärkere Nachweis.

### Kontrollierter Attach-Pfad

Ein `DATABASE_PACKAGE` ist ein ausdrücklicher Expertenpfad. Vor der
Veröffentlichung muss das Produkt:

1. die Datenbankzugriffe sperren und einen sauberen Offline-/Detach-Zustand
   nachweisen;
2. alle MDF-, NDF- und LDF-Dateien sowie den vollständigen FILESTREAM-
   Container inventarisieren;
3. die zusammengehörige Dateimenge atomar kopieren oder snapshotten und hashen;
4. SQL-Major-Version, Datenbankstatus, Verschlüsselung und externe
   Serverabhängigkeiten aufzeichnen;
5. die Quelle erst freigeben, wenn keine Instanz sie mehr schreibend verwendet.

Beim Import werden Abwärtskompatibilität, Vollständigkeit, Hashes,
FILESTREAM-Capability, TDE-Schlüssel und exklusive Nutzung fail-closed geprüft.
Dieselben physischen Dateien dürfen nie gleichzeitig an zwei schreibende
SQL-Instanzen gebunden werden. Eine zweite Umgebung erhält einen Clone oder
einen Restore, keine gemeinsame Read/Write-Bindung.

### Nicht datenbankgebundener Instanzzustand

Benutzerdatenbanken enthalten nicht alle Serverobjekte. Für einen vollständigen
Umzug müssen mindestens Logins und SIDs, SQL-Agent-Jobs, Credentials, Linked
Servers, Serverkonfiguration, Zertifikate und gegebenenfalls SSISDB-/SSAS-
Abhängigkeiten separat klassifiziert, exportiert oder bewusst ausgeschlossen
werden. Ein reines Attach darf nicht als vollständige Instanzwiederherstellung
ausgegeben werden.

## Retention und Entfernen einer Umgebung

Vor dem Entfernen zeigt CLI und GUI für jede Datenressource die tatsächliche
Folge an. Mindestens folgende Policies sind zu planen:

- `DELETE_WITH_RUN`: rungebundene Ressource wird nach Scope-Prüfung entfernt;
- `RETAIN_INSTANCE_STORE`: Instanzspeicher bleibt katalogisiert erhalten;
- `BACKUP_ON_REMOVE`: alle ausgewählten Benutzerdatenbanken werden vor dem
  Cleanup gesichert und geprüft;
- `PACKAGE_ON_REMOVE`: Datenbanken werden sauber offline als Paket
  materialisiert;
- `BACKUP_AND_PACKAGE`: beide unabhängigen Wiederherstellungswege werden
  erzeugt;
- `EXTERNAL_UNMANAGED`: Produkt entfernt weder Quelle noch Inhalt und löst nur
  seine eigene Bindung.

Scheitert eine verlangte Sicherung, ein Hash, ein Detach oder eine
Postcondition, darf der Datenträger nicht still freigegeben oder gelöscht
werden. Der Run endet mit einem sichtbaren Recovery-Pfad. Ein späteres
erzwungenes Entfernen ist eine getrennte Expertenaktion mit genauer
Auswirkungsanzeige.

Persistente Speicher werden niemals als Nebeneffekt von `Remove-SqlServerLab`
gelöscht. Ihre endgültige Löschung ist eine eigene Aktion mit Storage-ID,
Inhaltsinventar, Referenzprüfung, Preview und Bestätigung.

## Providervertrag

### Docker

- `/var/opt/mssql` darf weiterhin in einem nativen Named Volume liegen, wenn
  Windows-/Linux-Dateisystemsemantik, SQL-Version oder Performance gegen einen
  direkten Host-Bind-Mount sprechen.
- Das Produkt muss Volume-Name, Runtime, Engine-/Context-Identität,
  Mountpoints, Datenumfang und Retention katalogisieren.
- Ein direkter Host-Mount aktiver SQL-Dateien ist nur nach eigener Capability-
  und Performanceprüfung sowie ausdrücklichem Experten-Opt-in zulässig.
- Eine etwaige Verlagerung des Docker-Desktop-Datenträgers darf nicht still
  alle labfremden Images, Volumes und Container betreffen.

### Podman

- Podman-Volumes und Images können innerhalb einer Podman Machine liegen und
  sind nicht allein durch einen Windows-Hostpfad unter `Lab_Data` beschrieben.
- Zu analysieren ist ein eigener, von SQL Server Lab verwalteter Machine-
  Vertrag mit expliziter Disk-Location, Kapazität, Rootless-/Rootful-Modus,
  Start, Stop, Update, Recovery und Entfernung.
- CLI und GUI müssen Anlegen, Auswählen und Verwalten einer solchen Machine
  unterstützen, falls sie Teil des Produktvertrags wird.
- Eine bestehende allgemeine Podman Machine und ihre labfremden Container
  dürfen weder umgebogen noch beim Lab-Cleanup entfernt werden.

### Hyper-V

- Eine vorhandene persistente Daten-VHDX muss per Storage-ID ausgewählt,
  revalidiert und an eine ausgeschaltete Ziel-VM angehängt werden können.
- Vor Read/Write-Attach sind DiskIdentifier, Hostpfadbindung, vorhandene
  Attachments, Checkpoints, Dirty-/Detach-Zustand, SQL-Version und freier
  Gastpfad zu prüfen.
- Der Vertrag unterscheidet die Fortsetzung der vollständigen ursprünglichen
  VM von Recovery beziehungsweise Migration einer bloßen Daten-VHDX.
- Systemdatenbanken und Serverobjekte auf der gelöschten Child-VHDX werden nicht
  als durch die Daten-VHDX erhalten ausgegeben.
- Normale Zusatz-VHDX für Data, Log, TempDB und Backup benötigen dieselbe
  sichtbare Retention- und Exportklassifikation; ihre bisherige Runbindung darf
  keine Datenbankdateien unbemerkt vernichten.

## Erforderliche `Lab_Data`-Bestandsanalyse

Vor einer Festlegung, dass *alle Daten unter `Lab_Data` liegen*, ist pro
Provider und Hostmodus eine physische Inventur erforderlich. Sie erfasst
mindestens:

- Run-State, Journale, Secrets, Logs, Exporte, Caches und temporäre Dateien;
- Docker- und Podman-Container, Images, Named Volumes, Netzwerke, Build-Cache
  und deren tatsächliche Backing-Disks;
- Podman Machines samt Machine-Disk, Konfiguration und Connections;
- Docker-Desktop-/WSL-/VM-Datenträger und die Reichweite einer möglichen
  Verlagerung;
- Hyper-V-VM-Konfiguration, OS-/Child-/Zusatz-/Daten-VHDX, Images, Builder,
  Staging, Checkpoints, Smart Paging und Saved State;
- Daten, die nach erfolgreichem Remove, Clear, fehlgeschlagenem Provisioning,
  Prozessabbruch und Hostneustart tatsächlich verbleiben;
- fremde beziehungsweise labfremde Ressourcen, die nie in den Ownership- oder
  Cleanup-Scope geraten dürfen.

Für jede Objektklasse sind logischer Eigentümer, physischer Pfad, Lebensdauer,
Größe, Referenzen, Cleanup-Schritt, Recovery-Möglichkeit und Auditstatus zu
dokumentieren. Ein Runtime-Volume darf nicht allein deshalb als unter
`Lab_Data` liegend gelten, weil sein Name im Run-State gespeichert ist.

Die Analyse muss folgende Produktentscheidung vorbereiten:

1. Bedeutet `Lab_Data`, dass wirklich jedes physische Byte dort liegt, oder ist
   es der verwaltete Katalog- und Austauschroot mit ausdrücklich ausgewiesenen
   nativen Runtime-Ausnahmen?
2. Kann eine dedizierte Docker-/Podman-Engine beziehungsweise Machine
   Labressourcen isolieren, ohne labfremde Objekte oder Hostdefaults zu
   verändern?
3. Welche Daten müssen direkt hostsichtbar sein und welche werden nur über
   sichere Materialize-/Exportaktionen sichtbar?
4. Wie werden bestehende Daten mit Kapazitätsprüfung, Journal, Rollback und
   Wiederaufnahme migriert?
5. Welche Residuen meldet der Cleanup-Audit, welche kann er sicher entfernen
   und welche benötigen eine eigene Benutzerentscheidung?

## CLI- und GUI-Vertrag

CLI und GUI sind Ansichten auf denselben Planner-, Katalog-, Lease-, Journal-
und Providerkern. Beide müssen mindestens anbieten:

- persistente Speicher auflisten, filtern und mit Inhalt, Größe, Provider,
  SQL-Version, Bindung und Zustand anzeigen;
- neuen Speicher erstellen oder vorhandenen Speicher auswählen;
- **Fortsetzen**, **Restore**, **Attach**, **Klonen**, **Exportieren** und
  **Freigeben** als unterschiedliche Aktionen darstellen;
- Backup-/Package-on-Remove-Policy bereits bei der Erstellung sowie vor dem
  Entfernen prüfen;
- einen read-only Plan mit physischen und logischen Zielpfaden, Downtime,
  Kapazität, Versionswechsel und Datenverlustrisiko anzeigen;
- Podman Machine beziehungsweise Docker-Kontext nur im zuvor definierten
  Ownership-Scope anlegen oder auswählen;
- unvollständige Operationen fortsetzen, zurückrollen oder als
  `RECOVERY_REQUIRED` untersuchen;
- persistente Speicher ausschließlich über eine getrennte, referenzgeprüfte
  Löschaktion entfernen.

Ein Manifest benötigt langfristig eine stabile Storage-Referenz und eine
Retention-Policy; ein frei eingebbarer Hostpfad oder ein abgeleiteter
Volumename ersetzt diese Identität nicht.

## Arbeitspakete

| ID | Priorität | Arbeitspaket | Ergebnis |
|---|---:|---|---|
| `PSR-001` | P0-Analyse | Ist-Inventar aller persistenten, rungebundenen und verbleibenden Objekte für Docker, Podman und Hyper-V | `IMPLEMENTED_PARTIAL`: versionierte read-only Matrix mit stabilen Objekt-IDs, Residency, Lifecycle, Cleanup-Policy und Provider-Coverage; physisches Desktop-/Machine-Backing bleibt explizit unverifizierbar |
| `PSR-002` | P0-Analyse | `Lab_Data`-Versprechen, native Runtime-Ausnahmen und Hosteingriffsgrenzen entscheiden | `COMPLETE`: bindender `SqlServerLab.LabDataResidencyDecision/1.0`-Entscheid |
| `PSR-003` | P1 | Storage-Katalog mit stabiler ID, Klassen, Zuständen, Referenzen und Leases entwerfen | `IMPLEMENTED_READ_ONLY`: Schema, Parser, Planner und Inventarbindung; keine Katalogmutation, Lease-Akquisition, Wiederverwendung oder Löschung |
| `PSR-004` | P1 | Retention-, Backup-on-Remove-, Package- und expliziten Löschvertrag entwerfen | `IMPLEMENTED_READ_ONLY`: verlustsicherer Cleanup-/Recovery-Plan; Executor und getrennte endgültige Storage-Löschaktion bleiben offen |
| `PSR-005` | P1 | Docker-/Podman-Instanzstore auswählbar, fortsetzbar und klonbar machen | `IMPLEMENTED_CORE`: stabile ID-Auswahl, detached Continue/Clone, Digest/Resume und getrennte reale Docker-/Podman-Nachweise; Katalog-Commit, Sidecars und öffentliche Bedienung offen |
| `PSR-006` | P1 | Podman-Machine- und Docker-Engine-/Context-Reichweite bewerten und gegebenenfalls dediziert verwalten | `IMPLEMENTED_READ_ONLY`: stabile sanitisierte Runtime-ID, Context-/Connection-/Machine-Bindung und REPORT_ONLY-Hostgrenze real belegt; dedizierter Ownership-/Lifecycle-Vertrag bleibt offen |
| `PSR-007` | P1 | Hyper-V-Daten-VHDX sicher auswählen, reattachen, freigeben und klonen | `IMPLEMENTED_CORE`: Storage-ID-, Disk-/VM-/Checkpoint-/Clean-Detach-/SQL-Versions-validierter Host-Lifecycle, unabhängiger Clone und realer Hyper-V-Nachweis; Katalog-Commit, öffentliche Bedienung und explizite Datenbankaktion bleiben getrennt |
| `PSR-008` | P1 | Providerneutrale Backup-Bibliothek mit automatischem Backup und Restore-Verifikation liefern | `IMPLEMENTED_CORE`: inhaltsadressierte `Lab_Data`-Bibliothek, `CHECKSUM`, `RESTORE VERIFYONLY`, Hash, Metadatenreceipt und realer Docker→Podman-Inhaltsnachweis; reale FILESTREAM-Cross-Provider-Evidence und öffentliche Bibliotheksauswahl bleiben offen |
| `PSR-009` | P2 | Datenbankpakete inklusive FILESTREAM, Attach und Clone implementieren | `IMPLEMENTED_CORE`: vollständiger Offline-Dateivertrag, rekursive Hashes, unabhängiger Clone und journalisiertes Copy-then-Attach; native Hyper-V-/FILESTREAM-Abnahme sowie öffentliche Bedienung offen |
| `PSR-010` | P2 | Serverobjekt- und TDE-Abhängigkeiten inventarisieren und Migrationsgrenzen anzeigen | `IMPLEMENTED_CORE`: read-only SQL-Counts, TDE-Recovery-Gate, externe Review-Grenzen und sanitisierte `DATABASE_FILES_ONLY`-Receipts; Export/Import und öffentliche Bedienung offen |
| `PSR-011` | P1 | identische CLI- und GUI-Flows für Auswahl, Retention, Restore, Attach, Clone und Delete liefern | ein gemeinsamer Core ohne Bedienungsparitätslücke |
| `PSR-012` | P1 | Cleanup-Audit um persistente Stores, Runtime-Backing, Orphans und Referenzschutz erweitern | verständliche Residuen- und Recovery-Ausgabe |
| `PSR-013` | P2 | journalisierte Migration vorhandener Volumes/VHDX und Metadaten bereitstellen | Resume, Rollback, Hash- und Kapazitätsnachweis |

`P0-Analyse` bedeutet hier, dass die Entscheidung vor jeder breiten
Implementierung benötigt wird. Sie ersetzt oder relativiert nicht den bereits
priorisierten P0-Hyper-V-Ressourcenroot-Bugfix.

## Abnahmekriterien

- Ein Benutzer kann einen vorhandenen Speicher in CLI und GUI anhand seiner
  stabilen ID auswählen; ein Anzeigename oder neu berechneter Volumename reicht
  nicht als Identität.
- Docker und Podman setzen denselben freigegebenen Instanzstore nach einem
  kontrollierten Container-Recreate fort und bestätigen System- sowie
  Benutzerdatenbanken live.
- Eine Hyper-V-Daten-VHDX kann nach sauberem Detach an eine neue kompatible VM
  gebunden werden; Datenbanken werden anschließend ausdrücklich restored oder
  attached und nicht nur wegen vorhandener Dateien als online gemeldet.

Stand 2026-09-01: `SqlServerLab.HyperVPersistentDataIntent/1.0`, Plan und
Recovery-Journal wählen die Quelle ausschließlich per stabiler Storage-ID aus
dem Katalog. Vor jeder Mutation werden registriertes `Lab_Data`, VHDX-Pfad und
DiskIdentifier, exklusiver Attachmentzustand, Checkpoints, ausgeschaltete und
scopegebundene Ziel-VM, Clean-Detach-Evidenz, SQL-Major-Version, freier
Gastpfad sowie Lease und Referenzen fail-closed geprüft. Der Clone verwendet
eine unveränderte Quelle, erzeugt eine eigenständige VHDX und setzt deren
DiskIdentifier explizit neu. Ein realer isolierter Hyper-V-Lauf hat
`CLONE -> REATTACH -> RELEASE` samt Cleanup bestätigt. Das Ergebnis bleibt
`DatabaseFilesOnline=false` und verlangt anschließend ausdrücklich Restore
oder Attach; diese Datenbankaktion, Katalogmutation und CLI-/GUI-Flows gehören
weiterhin zu `PSR-009`, `PSR-003` beziehungsweise `PSR-011`.
- Ein vollständiges Backup einer Datenbank mit FILESTREAM wird aus einem
  Provider exportiert, in einem zweiten unterstützten Provider restauriert und
  inhaltlich verifiziert.

Stand 2026-09-01: `SqlServerLab.BackupLibrary/1.0` veröffentlicht ein Backup
erst nach `BACKUP ... CHECKSUM`, `RESTORE VERIFYONLY ... WITH CHECKSUM`,
Host-SHA-256 und sanitiertem SQL-Metadatenreceipt als `REUSABLE`. Ein realer,
isolierter Lauf hat Docker → Podman einschließlich Quell-Cleanup, erneutem
`VERIFYONLY`, Restore und identischem Inhaltsdigest bestätigt. TDE endet ohne
eigenen Zertifikat-/Recovery-Vertrag fail-closed. FILESTREAM wird im Receipt
erkannt und eine Restore-Evidence ohne ausdrücklich bestätigten FILESTREAM-
Inhaltsnachweis abgelehnt; weil die Linux-Container diesen Nachweis nicht
liefern können, bleibt das vollständige reale FILESTREAM-Cross-Provider-
Abnahmekriterium offen und wird nicht als bestanden behauptet.
- Ein Datenbankpaket enthält nachweislich alle MDF/NDF/LDF- und FILESTREAM-
  Bestandteile; fehlende oder veränderte Inhalte sowie paralleles Read/Write-
  Attach werden blockiert.
- Neuer-zu-älter-SQL-Attach, fehlende FILESTREAM-Capability, fehlendes TDE-
  Zertifikat und inkonsistenter Detach-Zustand enden fail-closed mit
  verständlicher Recovery-Angabe.

Stand 2026-09-01: `SqlServerLab.DatabasePackageLibrary/1.0` veröffentlicht nur
eine nach dem exklusiven Lock erneut als sauber offline oder detached
beobachtete Dateimenge. MDF, NDF, LDF und verschachtelte FILESTREAM-Inhalte
werden vollständig kopiert und einzeln gehasht; ein kanonischer Manifesthash
bindet die Gesamtmenge. Clone und Attach materialisieren eine unabhängige
physische Kopie, das direkte Read/Write-Attach eines Bibliotheksobjekts ist
verboten. Der Attach-Plan blockiert ältere SQL-Ziele, fehlende FILESTREAM- oder
TDE-Evidence, vorhandene Zieldatenbanken und parallele Writer. Kopie, Attach,
Online-Postcondition und Recovery werden journalisiert. Die deterministische
Core-Suite ist grün; ein realer Windows-SQL-/FILESTREAM-Lauf in Hyper-V bleibt
als eigener Provider-Nachweis offen und wird nicht vorweggenommen.
- Serverobjekte, TDE-Keymaterial, Credentials und externe Services werden bei
  Backup oder Datenbankpaket nicht als implizit mitgenommen ausgegeben.

Stand 2026-09-01: `SqlServerLab.DatabaseMigrationDependencyInventory/1.0`
liefert ausschließlich sanitisierte Kategorien und Counts. SQL-seitig
beobachtbare Login-Mappings, Agent-Jobs, Proxies, Linked-Server-Kandidaten und
TDE-Protectoren werden getrennt ausgewiesen; Serverkonfiguration, SSISDB und
SSAS bleiben `NOT_OBSERVABLE`. Backup- und Package-Receipts zeigen
`DATABASE_FILES_ONLY` sowie `FullInstanceMigration=false`. Ohne verifizierte
TDE-Recovery-Evidence bleibt portable Migration `BLOCKED`. Ein Export- oder
Recreate-Executor, Keymaterialtransfer und öffentliche CLI-/GUI-Flows sind
nicht Teil dieses Slices.
- `BACKUP_ON_REMOVE` entfernt die Umgebung erst nach erfolgreicher
  Sicherungs- und Verifikationsevidence oder endet ohne Datenlöschung in
  `RECOVERY_REQUIRED`.
- Normales Cleanup entfernt rungebundene Volumes und VHDX, behält freigegebene
  persistente Stores und Testdatenbibliotheken und verändert keine labfremden
  Container, Volumes, Images, Machines oder Hostdefaults.
- Der Cleanup-Audit zeigt nach Erfolg alle bewusst retained Objekte mit Grund
  sowie unerwartete Residuen getrennt an.
- Die reale Storage-Matrix weist für jede Provider-/Hostkombination aus, welche
  Daten physisch unter `Lab_Data`, in einer Runtime-/Machine-Disk oder an einem
  externen Ort liegen. Keine indirekte Referenz wird als physische Ablage
  ausgegeben.
- Docker-, Podman- und Hyper-V-Nachweise bleiben getrennt; ein erfolgreicher
  Providerlauf beweist keine Parität der anderen Provider.

## Nicht Ziel des ersten Vertical Slice

- gleichzeitiger schreibender Zugriff mehrerer SQL-Instanzen auf dieselben
  MDF/LDF-/FILESTREAM-Dateien;
- unkontrolliertes Kopieren aktiver Datenbankdateien;
- allgemeine Verwaltung aller Docker-, Podman- oder Hyper-V-Ressourcen des
  Hosts;
- stilles Verschieben der globalen Docker-Desktop- oder Podman-Standardablage;
- produktiver SAN-, NAS-, SMB-, Cluster-Shared-Volume- oder Cloud-Storage;
- automatische TDE-Schlüsselablage ohne eigenen Secret- und Recovery-Vertrag;
- Behauptung vollständiger Instanzportabilität allein aufgrund vorhandener
  Benutzerdatenbankdateien.

## Verwandte Verträge und Backlogs

- [Storage Contract](STORAGE_CONTRACT_PLAN.md);
- [P0-Hyper-V-`Lab_Data`-Ressourcenroot-Bugfix](HYPERV_LAB_DATA_RESOURCE_ROOT_BUGFIX_BACKLOG.md);
- [Persistente Daten und Evaluation-Refresh](../HowTo/PERSISTENT_DATA_AND_EVALUATION_REFRESH.md);
- [Konsolen-, Lifecycle- und Storage-Konsolidierung](CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md);
- [Providerneutraler Batch-, Queue- und Resume-Workflow](PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md);
- [SQL-, SSIS- und SSAS-Cluster](SQL_SSIS_SSAS_CLUSTER_BACKLOG.md).
