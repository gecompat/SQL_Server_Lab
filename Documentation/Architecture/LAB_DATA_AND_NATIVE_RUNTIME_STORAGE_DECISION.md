# `Lab_Data` und native Runtime-Speicher – Architekturentscheidung

| Merkmal | Wert |
|---|---|
| Decision-ID | `PSR-002` |
| Vertragsversion | `SqlServerLab.LabDataResidencyDecision/1.0` |
| Status | `BINDING_ARCHITECTURE_DECISION` |
| Stand | 2026-09-01 |
| Grundlage | `SqlServerLab.StorageResidencyInventory/1.0` |

## 1. Entscheidung

`Lab_Data` ist der controllergebundene, hostseitig sichtbare Einstiegsroot für
Katalog, Austausch, Sicherung, Recovery-Evidence und alle vom Produkt direkt
verwalteten Hostdateien. `Lab_Data` bedeutet ausdrücklich **nicht**, dass jedes
physische Byte einer Docker-Desktop-, Podman-Machine- oder anderen gemeinsam
genutzten Runtime dort liegen muss.

Native Docker-/Podman-Volumes sind als begrenzte Ausnahme für aktive
`INSTANCE_STORE`-Daten zulässig. Die Ausnahme ändert nicht deren logisches
Eigentum: Runtime, Engine beziehungsweise Context, Volume, Referenzen,
Retention und Auditstatus müssen katalogisierbar sein. Ein Pfad innerhalb des
Runtime-Namensraums ist kein Nachweis für einen Hostpfad unter `Lab_Data`.

Neue Hyper-V-Ressourcen des Produkts bleiben physisch an einen registrierten,
controller-eigenen `Lab_Data`-Root gebunden. Externe oder historische
Hyper-V-Ressourcen sind keine native Ausnahme; sie bleiben read-only
inventarisiert, bis ein eigener validierter Migrations- oder Adoptionsvertrag
sie übernimmt.

## 2. Verbindliches Benutzer-Versprechen

Unter `Lab_Data` liegen beziehungsweise werden dort veröffentlicht:

- Storage-Kataloge, Bindings, Journale und sanitisiertes Recovery-Evidence;
- geprüfte `BACKUP_SET`-Artefakte und deren Metadaten;
- kontrolliert materialisierte `DATABASE_PACKAGE`-Artefakte;
- `EXCHANGE_WORKSPACE`-Inhalte für Import, Export und Transfer;
- vom Produkt erzeugte Hyper-V-Run-, Build-, Image-, Staging- und
  Recovery-Dateien;
- hostseitig gebundene Container-Backup- und Austauschverzeichnisse.

Nicht als direkt hostsichtbar versprochen werden:

- aktive SQL-Dateien innerhalb eines nativen Docker-/Podman-Volumes;
- die physische Backing-Disk einer gemeinsam genutzten Docker-Desktop- oder
  Podman-Machine-Runtime;
- containerlokale, wegwerfbare Arbeitsbereiche;
- fremde oder nur referenzierte Hostressourcen.

Wo aktive Daten nur nativ sicher betrieben werden können, stellt der geplante
Produktvertrag Export, Backup, Materialize, Clone oder Restore bereit. Eine
indirekte Referenz oder ein Runtime-Mountpoint darf nie als physische
`Lab_Data`-Ablage ausgegeben werden.

## 3. Zulässige Residency nach Speicherklasse

| Speicherklasse | Verbindliche Residency | Hostsichtbarkeit |
|---|---|---|
| `INSTANCE_STORE` Docker/Podman | natives, katalogisiertes Runtime-Volume zulässig | über Audit und sichere Exportaktionen |
| `INSTANCE_STORE` Hyper-V | controller-eigene VHDX unter registriertem `Lab_Data` | Hostdatei sichtbar, Gastinhalt nicht gleichzeitig zu öffnen |
| `BACKUP_SET` | unter `Lab_Data` oder explizit extern-unmanaged | direkt sichtbar und verifiziert |
| `DATABASE_PACKAGE` | materialisiert unter `Lab_Data` | nur nach sauberem Offline-/Detach-Nachweis |
| `EXCHANGE_WORKSPACE` | unter `Lab_Data` | direkt sichtbar, keine aktiven SQL-Dateien |

Dieselben MDF-, NDF-, LDF- oder FILESTREAM-Dateien dürfen niemals gleichzeitig
von mehreren SQL-Instanzen schreibend verwendet werden. Direkte
Hostsichtbarkeit ist keine Freigabe zum parallelen Öffnen aktiver Dateien.

## 4. Native Runtime-Ausnahme

Eine native Runtime-Residency ist nur zulässig, wenn alle folgenden Bedingungen
erfüllt sind:

1. Der Provider benötigt sie für unterstützte Dateisystem-, Sicherheits- oder
   Performanceeigenschaften eines aktiven Instanzstores.
2. Das Objekt besitzt eine eindeutige Provider-, Runtime-/Context- und
   Volume-Identität sowie bekannte Run- oder Storage-Referenzen.
3. Retention und Cleanup sind getrennt ausgewiesen; ein retained Store wird
   nicht als Nebeneffekt eines Run-Cleanups gelöscht.
4. Das Inventar unterscheidet Runtime-Namespace, logisches Eigentum und
   unbekanntes physisches Host-Backing.
5. Ein geprüfter Weg zu Backup, Export, Clone oder Restore ist vorgesehen,
   bevor Wiederverwendbarkeit behauptet wird.

Fehlt eine dieser Bedingungen, bleibt die Residency `UNVERIFIABLE` oder
`EXTERNAL_UNMANAGED`; sie wird nicht still zu `Lab_Data` umklassifiziert.

## 5. Hosteingriffsgrenzen

Der normale Produkt-Lifecycle darf:

- controller-eigene Roots und Ressourcen innerhalb des bestätigten Scopes
  anlegen, prüfen, binden und scopegebunden bereinigen;
- projektspezifische Docker-/Podman-Volumes verwalten;
- eine künftig ausdrücklich projektverwaltete Engine oder Machine nur über
  einen eigenen versionierten Ownership-, Preview-, Recovery- und
  Löschvertrag verwalten.

Der normale Produkt-Lifecycle darf nicht:

- die globale Docker-Desktop-Disk, den Docker-Data-Root oder eine bestehende
  allgemeine Podman Machine still verschieben oder neu konfigurieren;
- labfremde Images, Container, Volumes, Netzwerke, Machines oder Hostdefaults
  übernehmen, löschen oder in den Cleanup-Scope ziehen;
- unbekannte externe Pfade aus Namen, Labels oder Run-Referenzen als Eigentum
  ableiten;
- Runtime-/Machine-Backing ohne Kapazitätsprüfung, Preview, Journal, Recovery
  und exakte Benutzerfreigabe migrieren;
- ergänzend entdeckten Hyper-V-Pfaden allein durch eine Run-ID
  Cleanup-Autorität verleihen.

Externe und unverifizierbare Objekte sind im normalen Audit `REPORT_ONLY`.
Mutation benötigt einen getrennten, revalidierten Bindungs-, Migrations- oder
Adoptionsvertrag.

## 6. Providerfolgen

### Docker

Ein Named Volume für `/var/opt/mssql` bleibt zulässig. Eine Verlagerung der
gemeinsamen Docker-Desktop-Ablage ist kein normaler Labvorgang. Ein künftig
dedizierter Engine-/Context-Vertrag muss labfremde Ressourcen ausschließen und
seine physische Reichweite vor jeder Mutation zeigen.

### Podman

Ein Volume innerhalb einer Podman Machine bleibt zulässig. Eine bestehende
allgemeine Machine wird weder umgebogen noch vom Lab entfernt. Eine dedizierte
Machine ist erst nach eigenem Ownership-, Disk-, Start-/Stop-, Update-,
Recovery- und Cleanup-Vertrag Teil des Produkts.

### Hyper-V

Neue VM-Konfiguration, Checkpoints, Smart Paging, OS-/Child-/Zusatz-VHDX,
Builder, Images und Staging liegen unter registriertem `Lab_Data`. Aktive
Gastdateisysteme werden nur über SQL- beziehungsweise Gastverträge verändert.
Legacy- und externe Ressourcen bleiben bis zu einer expliziten Migration oder
Adoption außerhalb des Eigentumsscopes.

## 7. Konsequenzen und offene Folgearbeit

Die Entscheidung schließt `PSR-002` ab. Der read-only Anteil von `PSR-003` ist
inzwischen durch `SqlServerLab.PersistentStorageCatalog/1.0` und
`SqlServerLab.PersistentStoragePlan/1.0` umgesetzt; er validiert stabile IDs,
Klassen, Zustände, Referenzen und exklusive Leases und gleicht sie ohne
Mutation mit dem Residency-Inventar ab. Folgende Arbeit bleibt getrennt:

- `PSR-003`: Katalogschreiben, Lease-Akquisition und Wiederverwendungsaktionen
  auf Basis des vorhandenen read-only Vertrags;
- `PSR-004`: Der read-only Retention-/Removal-Plan sowie der journalisierte
  Docker-/Podman-Executor für `RETAIN_INSTANCE_STORE` und `BACKUP_ON_REMOVE`
  sind umgesetzt; Package, externe Freigabe und explizite endgültige
  Storage-Löschung bleiben offen;
- `PSR-005`: Der stabile ID-, Continue- und detached Clone-Core ist samt
  getrennten realen Docker-/Podman-Nachweisen umgesetzt; Katalog-Commit,
  External-Runtime-Sidecars und öffentliche Bedienung bleiben offen;
- `PSR-006`: Der read-only `SqlServerLab.ContainerRuntimeScope/1.0`-Vertrag
  bindet aktive Contexts, Connections und Machines an eine stabile sanitisierte
  Runtime-ID und blockiert Host-/Runtime-Management ohne Ownership-Evidence;
  ein dedizierter Ownership-, Location-, Capacity-, Recovery- und Cleanup-
  Vertrag bleibt offen;
- `PSR-007`: Der interne Lifecycle-Core revalidiert katalogisierte Hyper-V-
  Daten-VHDX per stabiler Storage-ID gegen `Lab_Data`, DiskIdentifier,
  Attachments, Checkpoints, Clean-Detach-, SQL-Versions- und Gastpfad-Evidenz.
  Ein isolierter nativer Lauf bestätigt quellenunveränderten eigenständigen
  Clone, Reattach und Release. Katalog-Commit, öffentliche Bedienung und die
  ausdrücklich nachgelagerte Datenbank-Restore-/Attach-Aktion bleiben offen;
- `PSR-008`/`PSR-009`: Backup-Bibliothek und kontrollierte Datenbankpakete.

`SqlServerLab.StorageResidencyInventory/1.0` darf deshalb weiterhin `PARTIAL`
melden. Dieser Status ist korrekt, solange physisches Desktop-/Machine-Backing
oder externe Objekte nicht sicher aufgelöst werden können.

## 8. Abnahmekriterien

Die Entscheidung bleibt eingehalten, wenn:

- Dokumentation und Audit native Runtime-Residency nie als physisches
  `Lab_Data` ausgeben;
- neue Hyper-V-Hostdateien ausschließlich registrierte `Lab_Data`-Bindings
  verwenden;
- retained Stores nicht durch normales Run-Cleanup gelöscht werden;
- externe und unverifizierbare Befunde ohne eigenen Vertrag `REPORT_ONLY`
  bleiben;
- globale Runtime-/Machine-Einstellungen nur durch einen getrennten,
  eigentumsgebundenen und ausdrücklich freigegebenen Vertrag verändert werden;
- sichere Backup-/Export-/Materialize-Wege die fehlende direkte
  Hostsichtbarkeit aktiver Runtime-Dateien ausgleichen.
