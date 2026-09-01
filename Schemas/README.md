# Schemas/ – JSON-Schemas und Labbeispiele

Dieses Verzeichnis enthält die maschinenlesbaren Verträge und ausführbaren Beispielmanifeste.

## Schema-Dateien

| Datei | Zweck |
|---|---|
| `lab-manifest.schema.json` | Struktur deklarativer Labdefinitionen |
| `lab-batch.schema.json` | Mengenfähiger Vertrag `SqlServerLab.BatchManifest/1.0` mit Defaults, Positionen, Anzahl, Intent und Overrides |
| `version-catalog.schema.json` | Struktur von `Catalogs/sql-server-versions.json` |
| `sample-databases.schema.json` | Struktur von `Catalogs/sample-databases.json` |
| `software-catalog.schema.json` | Versionierter Katalogvertrag für SQL-bezogene Python-, R- und Java-Runtimes |
| `sample-baseline-registry.schema.json` | Portables Register verifizierter, inhaltsadressierter Single-Backup- und Multi-Database-ZIP-`LAB_GENERATED`-Objekte |
| `backup-library.schema.json` | Strikter `SqlServerLab.BackupLibrary/1.0`-Vertrag für inhaltsadressierte, per SQL-Checksum, `RESTORE VERIFYONLY`, Host-Hash und Metadatenreceipt veröffentlichte Backups sowie getrennte Restore-Evidence |
| `database-migration-dependency-inventory.schema.json` | Read-only Vertrag `SqlServerLab.DatabaseMigrationDependencyInventory/1.0` für sanitisierte Serverobjekt-/TDE-Kategorien, Counts und die ausdrückliche Datenbank-statt-Instanz-Migrationsgrenze |
| `project-adapter.schema.json` | Adaptervertrag konsumierender Projekte (`Adapters/`), Version `0.1-draft` |
| `test-environment.schema.json` | Vertrag `SqlServerLab.TestEnvironment/1.0` für den lokalen Export automatisierter Testumgebungen |
| `lab-storage-contract.schema.json` | Lokale Multi-Root-Registry mit stabilen Location-IDs, Anzeigenamen, Selektoren und Topologiebeleg |
| `lab-storage-intent.schema.json` | Portabler Manifestvertrag `SqlServerLab.StorageIntent/1.0` ohne lokale Pfade oder Geräte-IDs |
| `lab-storage-bound-plan.schema.json` | Lokaler read-only Vertrag `SqlServerLab.StorageBoundPlan/1.0` für Selector-, Location-, Topologie- und Dateibindung |
| `lab-storage-runtime-receipt.schema.json` | Getrennter Evidence-Vertrag für Hyper-V-VHDX, Gastdisk, SQL-Dateipfad, CREATE-/Restore-Operationen, Dienstrestart, Postconditions und Recovery |
| `lab-storage-residency-inventory.schema.json` | Read-only Vertrag `SqlServerLab.StorageResidencyInventory/1.0` für `Lab_Data`, Backup-Sets, Datenbankpakete, native Runtime-Ablage, externe Pfade, Retention, Cleanup-Zuordnung und unverifizierbares physisches Backing |
| `persistent-storage-catalog.schema.json` | Katalogvertrag `SqlServerLab.PersistentStorageCatalog/1.0` für stabile IDs, Storage-Klassen, Zustände, Referenzen, exklusive Leases und atomare Artefaktregistrierung |
| `persistent-storage-plan.schema.json` | Read-only Planvertrag `SqlServerLab.PersistentStoragePlan/1.0` für Inventarbindung, Lease-Prüfung und Registrierungskandidaten |
| `persistent-storage-removal-intent.schema.json` | Explizite run- und storage-ID-gebundene Policy-Auswahl `SqlServerLab.PersistentStorageRemovalIntent/1.0` ohne Secrets |
| `persistent-storage-removal-plan.schema.json` | Verlustsicherer read-only Vertrag `SqlServerLab.PersistentStorageRemovalPlan/1.0` für Retention, Backup/Package, Recovery-Evidence und separate Löschung |
| `container-instance-store-intent.schema.json` | Strikter `CONTINUE`-/`CLONE`-Intent für katalogisierte Docker-/Podman-Instanzstores |
| `container-instance-store-plan.schema.json` | Fail-closed Auswahl-, Kompatibilitäts- und Mutationsplan für Container-Instanzstores |
| `container-instance-store-journal.schema.json` | Wiederaufnehmbares Clone-Journal mit Quell-/Zielidentität und Inhaltsdigest-Evidence |
| `container-runtime-scope.schema.json` | Sanitisierter read-only Vertrag `SqlServerLab.ContainerRuntimeScope/1.0` für Engine-/Context-/Machine-Reichweite, Ownership und verbotene Hostmutationen |
| `lab-cleanup-audit.schema.json` | Lokaler Cleanup-Audit einschließlich Storage-Residency-Matrix und strikt getrennter read-only Retention-, Residual-, Recovery- und Unverifiable-Findings |
| `hyperv-resource-binding.schema.json` | Lokaler Vertrag `SqlServerLab.HyperVResourceBinding/1.0` für kurze Hyper-V-Create-Roots mit Controller-, Location-, Volume- und `Lab_Data`-Identität |
| `hyperv-resource-migration-plan.schema.json` | Lokaler read-only Vertrag `SqlServerLab.HyperVResourceMigrationPlan/1.0` für exaktes Legacy-Inventar, Zielbindung, Blocker und geplante Aktionen |
| `hyperv-resource-migration-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.HyperVResourceMigrationJournal/1.0` für vorjournalisiertes Parent-Reparent, getrennte Child-Hashes, VHDX-/VM-Umbindung, Readiness, Image-Resume, späten Quell-Cleanup und sichtbaren Recovery-Bedarf |
| `hyperv-image-migration-plan.schema.json` | Lokaler read-only Vertrag `SqlServerLab.HyperVImageMigrationPlan/1.0` für Legacy-Image-Inventar, Zielbelegung, Child-Graph und Kopierbedarf |
| `hyperv-image-migration-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.HyperVImageMigrationJournal/1.0` für hashidentische Veröffentlichung, Binding-Commit, `WAITING_FOR_CONSUMERS` und referenzsicheren Quell-Cleanup |
| `container-reconcile-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.ContainerReconcileJournal/1.0` für Live-/Recreate-Mutation, echte Runtime-IDs, Resume, Rollback und sichtbaren Recovery-Bedarf |
| `hyperv-network-reconcile-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.HyperVNetworkReconcileJournal/1.0` für run-/scope-/VM-gebundene additive Infrastrukturreparatur, genau einen vorhandenen getrennten Adapter und Recovery-Retry |
| `hyperv-resource-reconcile-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.HyperVResourceReconcileJournal/1.0` für vCPU, statisches/dynamisches RAM, Min/Startup/Max, Stop-Apply-Start und Recovery-Resume |
| `hyperv-sql-configuration-ownership.schema.json` | VM-gebundener lokaler Eigentumsnachweis `SqlServerLab.HyperVSqlConfigurationOwnership/1.0` für durch den Run aktivierte globale Runtime-Trace-Flags |
| `hyperv-sql-configuration-reconcile-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.HyperVSqlConfigurationReconcileJournal/1.0` für dynamische oder dienstrestartpflichtige `sp_configure`-Werte, additive und eigentumsgeschützt entfernte globale Runtime-Trace-Flags, Desired-State-Commit und Recovery-Resume |
| `hyperv-sql-port-reconcile-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.HyperVSqlPortReconcileJournal/1.0` für statisches SQL-TCP, die run-eigene Gastfirewall, kontrollierten SQL-Dienstrestart und Recovery-Resume |
| `hyperv-test-database-ownership.schema.json` | VM-gebundener lokaler Eigentumsnachweis `SqlServerLab.HyperVTestDatabaseOwnership/1.0` für katalogisierte Testdatenbanken |
| `hyperv-test-database-reconcile-journal.schema.json` | Lokales Operationsjournal `SqlServerLab.HyperVTestDatabaseReconcileJournal/1.0` für Additionen, verifiziert gesicherte Entfernungen und Recovery-Resume |

## Beispiele

| Datei | Zweck | Erwarteter Status |
|---|---|---|
| `example-lab.json` | einfache Instanz mit Datenbank und Post-Provision | ausführbar, sofern referenzierte SQL-Datei vorhanden ist |
| `example-restore-lab.json` | Restore einer `.bak`-Quelle | ausführbar bei erreichbarer Quelle |
| `example-performance-lab.json` | Volumes, Data-/Log-Pfade, TempDB, Memory, MaxDOP und DB-Optionen | ausführbar mit ausreichenden Ressourcen |
| `example-cu-comparison.json` | zwei katalogisierte SQL-2022-CU-Stände mit identischer Sample-Datenbank | ausführbar über den Sample-Backup-Handler; ohne Katalog-SHA-256 fragt ein interaktiver Lauf einmalig nach Vertrauen |
| `example-ml-services.json` | Legacy-External-Languages-Konfiguration mit Sample-Referenz | External-Runtime-Anteil wird sicher als `NON_REPRODUCIBLE` abgelehnt; Sample-Anteil ist separat über den Backup-Handler ausführbar |
| `example-performance-tuning.json` | Performance-Konfiguration mit Sample-Referenz | vorbereitet; referenzierte StackOverflow-Variante ist ein Attach-Archiv und bleibt beschreibend |
| `example-mixed-provider-lab.json` | zwei kompakte Instanzen mit Docker und Podman in einem Run | ausführbar, wenn beide Runtimes erreichbar sind; keine gemeinsame Netzwerktopologie |
| `example-hyperv-drive-lab.json` | SQL-Prepared-Hyper-V-VM mit run-lokalen Data-/Log-VHDX und Guest-Initialisierung | ausführbar, wenn die referenzierte lokale Sealed-Artifact-ID vorhanden ist |
| `example-hyperv-lan-lab.json` | portabler Hyper-V-LAN-Intent mit External Switch und DHCP | ausführbar nur nach expliziter lokaler Switch-/Adapterbindung gemäß `Documentation/HowTo/LAB_NETWORKS.md` |
| `hyperv-storage-n5-intent.sample.json` | Portabler N5-Storage-Intent mit vier TempDB-Datendateien, die round-robin auf drei physisch getrennte Geräte verteilt werden, separatem TempDB-Log sowie Create-/Restore-Bindings | ausführbarer Abnahme-Input, wenn die vier Selektoren lokal eindeutig registriert und drei TempDB-Backing-Devices als getrennt belegt sind; die Log-Lane darf einen dieser Roots mit eigenem Selector nutzen |
| `batch-manifest.sample.json` | Providerneutrale SQL-/Windows-Mengenplanung mit gemeinsamen Defaults und individuellen Overrides | wird vor Ausführung expandiert und provider-/hostabhängig validiert |

Weitere `example-*.json`-Dateien können spezialisierte oder vorbereitete Szenarien enthalten. Ein Beispiel ist nur dann als End-to-End ausführbar anzusehen, wenn alle referenzierten Skripte und Quellen existieren und keine Grenze aus `Documentation/Quality/KNOWN_LIMITATIONS.md` verletzt wird.

## Verwendbare Manifestbereiche

### Instanz

- `id`
- `version`
- `provider`
- `profile`
- `collation` als Default für neu angelegte Datenbanken
- `drives`
- `serverConfig`
- `storageIntent` für portable Rollen-, TempDB-, Datenbankdatei- und Restore-Platzierungsanforderungen
- `network.intent` und `network.exposure` für portable Netzwerk- und Zugriffsanforderungen
- `hyperv.processorCount`, `hyperv.dynamicMemoryEnabled` sowie
  `hyperv.memoryMinimumMB`, `hyperv.memoryStartupMB` und
  `hyperv.memoryMaximumMB` für den portablen VM-Ressourcenintent
- `hyperv.sqlPort` für den statischen TCP-Port der SQL-Standardinstanz im Gast
- `databases`
- `postProvision`

### Datenbank

- `name`
- `collation`
- `files.data[]` und `files.log[]`
- `path`, `sizeMB`, `filegrowthMB`
- `options`
- `restore`
- `sample`

`restore` und `sample` sind Alternativen. Eine Restore- oder Sample-Datenbank wird nicht vorab mit `CREATE DATABASE` angelegt.

### Aktuell ausgeführte Serverkonfiguration

- `memory`
- `tempdb`
- `maxDop`
- `costThreshold`
- `traceFlags`
- `spConfigure`
- `externalScripts.enabled` und Resource-Governor-Werte; die Legacy-Sprachliste
  wird in Software-Intents normalisiert und bleibt ohne freigegebene
  Katalogvariante nicht ausführbar

Das Schema enthält teilweise vorbereitete Erweiterungsfelder. Die verbindlichen Grenzen stehen in [`KNOWN_LIMITATIONS.md`](../Documentation/Quality/KNOWN_LIMITATIONS.md).

Der Network-Intent-Resolver plant ohne Hostmutation. Docker und Podman verwenden
aktuell `nat`/`host`; Hyper-V verwendet standardmäßig `hostOnly`/`host` und
unterstützt explizit `isolated`/`none`, `nat`/`host` und `lan`/`lan`. NAT bindet
Shared-WinNAT und scopegebundene IPAM-Leases; LAN verlangt eine lokale
External-Switch-/Adapter-Allowlist und verwendet Gast-DHCP. Widersprüchliche
Exposure-Werte werden vor der ersten Provider-Mutation abgelehnt.
`hyperv.switchName` ist nur ein lokales Kompatibilitätsbinding für einen
internen `hostOnly`-Switch.

Ein `storageIntent` wird im Hyper-V-Manifestpfad lokal an registrierte,
controller-eigene `Lab_Data`-Locations gebunden. Pro Selector entsteht eine
dynamische Storage-VHDX; nach der stabilen Gastinitialisierung werden
Instanz-Defaultpfade und der vollständige TempDB-Dateiplan angewendet. Erst ein
SQL-Dienstrestart mit erfolgreichen Defaultpfad- und `sys.master_files`-
Postconditions setzt das getrennte Runtime-Receipt auf `VERIFIED`. Neue
Datenbanken und direkte `.bak`-Restores verwenden anschließend ausschließlich
dateigenaue Bindings dieses Plans; Restore ordnet jede `FILELISTONLY`-Datei
genau einem typgerechten `MOVE`-Ziel zu und quittiert erst nach einer exakten
`sys.master_files`-Postcondition. Container bleiben bei physischen
Trennungsanforderungen ausdrücklich unsupported.

Der N5-Akzeptanzrunner verwendet
`hyperv-storage-n5-intent.sample.json` als portable Vorlage. Die lokalen
Storage-Locations erhalten die dort genannten Selektoren erst operatorseitig;
das Beispiel enthält bewusst keine Hostpfade, Location-IDs oder Geräte-IDs.
`minimumPhysicalDeviceCount` kann für andere Hosts bis auf zwei reduziert
werden; `one-file-per-physical-device` bleibt der strengere Modus für ein
eigenes Gerät je Datendatei.

Jede direkte Eigenschaft unter `serverConfig` ist deshalb maschinenlesbar mit
`x-runtimeStatus` klassifiziert:

- `executable`: Parser und Runtime wenden das Feld an;
- `reserved`: das Feld bleibt fuer die Vertragsentwicklung sichtbar, wird aber
  nicht als Runtime-Capability zugesagt und wird bei gesetztem Wert mit
  `MANIFEST_RESERVED_RUNTIME_FIELD` abgelehnt;
- `partially-executable`: nur die in der Beschreibung genannten Werte besitzen
  einen Runtimepfad.

Ausfuehrbare Beispielmanifeste duerfen keine als `reserved` markierten Felder
verwenden. Wertabhaengige Grenzen stehen in `x-runtimeValueStatus` und enden
mit `MANIFEST_RESERVED_RUNTIME_VALUE`; bei `externalScripts.installMethod`
sind `custom-image` und `pre-built` reserviert.

## Pfadauflösung

Relative Pfade werden wie folgt behandelt:

- `postProvision`: relativ zum Manifest-Verzeichnis
- lokales `restore.source`: relativ zum Manifest-Verzeichnis
- `drives[].hostPath`: relativ zum Manifest-Verzeichnis
- Datenbank- und TempDB-Dateipfade: providerbezogene SQL-Pfade, keine
  Hostpfade; Hyper-V-Pfade werden aus dem verifizierten Storage-Plan aufgelöst

Die genannten Pfadfelder besitzen direkt im Schema `x-ui`-Metadaten. Der
Wizard zeigt damit Bedeutung, Zielscope, Default, Bezugsbasis, Erzeugungsregel,
Auswirkungen und ein Beispiel. Bei relativen Hostpfaden zeigt er während der
Eingabe zusätzlich die aufgelöste lokale Vorschau. Diese Anzeige schreibt keine
Hostpfade in versionierte Artefakte.

`drives[].hostPath` ist bei Manifesten standardmäßig `readOnly`. Für einen
schreibenden beliebigen Host-Mount müssen **beide** Freigaben vorliegen:
`drives[].accessMode: "readWrite"` zusammen mit
`expertActions.hostWriteMounts: true` im Manifest und der Aufrufschalter
`New-SqlServerLab -AllowExpertHostWriteMounts`. Für normale Testdaten sind die
verifizierte Media-Root-Bibliothek und der pro Lab getrennte Data Root vorgesehen.

## Unbeaufsichtigte Ausführung

Manifeste verwenden standardmäßig `automation.mode: "unattended"`. Geheimnisse
werden ausschließlich als Namen von Prozess-Umgebungsvariablen mit dem Präfix
`SQL_SERVER_LAB_SECRET_` referenziert, beispielsweise
`SQL_SERVER_LAB_SECRET_SA_PASSWORD`; Klartextwerte sind nicht schemagültig.
Remote-Restores brauchen für automatisierte Läufe `restore.sha256`. Ohne
bekannte Prüfsumme endet der Artifact Resolver sicher mit `TRUST_REQUIRED`.

## Sample-Datenbanken

Beispiel:

```json
{
  "name": "AdventureWorks2022",
  "sample": {
    "id": "adventureworks-2022",
    "variant": "full"
  }
}
```

Der Manifestparser akzeptiert nur als `executable` katalogisierte Varianten. Unterstützt sind direkte Backups, exakt katalogisierte Backup-Archive, einzelne SQL-Skripte und sichere Script Bundles mit festen erwarteten Datenbanken. Attach-Szenarien bleiben `descriptive` und werden nicht stillschweigend umgedeutet.

## Nutzung

```powershell
Import-Module .\SqlServerLab.psd1 -Force
New-SqlServerLabManifest -Path .\mein-lab.json
$validation = Test-SqlServerLabManifest -Path .\mein-lab.json
$validation.Plan.Instances.ExternalRuntimes.Entries
$env:SQL_SERVER_LAB_SECRET_SA_PASSWORD = '<aus Secret Store oder CI-Injection>'
New-SqlServerLab -Manifest .\Schemas\example-performance-lab.json
Remove-Item Env:SQL_SERVER_LAB_SECRET_SA_PASSWORD
```

`New-SqlServerLabManifest` liest den gesamten Eingabebaum aus
`lab-manifest.schema.json`; neue Schemafelder werden dadurch automatisch im
Konsolen-Wizard angeboten. `x-ui`-Metadaten ergänzen die generische Eingabe um
kontextreiche Hinweise. Die anschliessende Fachvalidierung prueft zusaetzlich
unter anderem Versionskatalog, Compatibility Level, Providerkombinationen,
Samplevarianten und lokale Dateipfade. Fuer `software` bietet der Wizard nur
vom Resolver freigegebene External-Runtime-Varianten an; die Planvorschau zeigt
Downloads, Build- oder Gastmutation, Restarts, Downtime, Package Locks,
Verification und Aenderungsklasse ohne Runtime-Mutation.

## Validierung

```powershell
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Die Prüfung kontrolliert JSON-Syntax, Schema-Referenzen und zentrale Beispielverträge. Ein echter Provider-Smoke-Test bleibt zusätzlich erforderlich.
