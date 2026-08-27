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
| `project-adapter.schema.json` | Adaptervertrag konsumierender Projekte (`Adapters/`), Version `0.1-draft` |
| `test-environment.schema.json` | Vertrag `SqlServerLab.TestEnvironment/1.0` für den lokalen Export automatisierter Testumgebungen |

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

Jede direkte Eigenschaft unter `serverConfig` ist deshalb maschinenlesbar mit
`x-runtimeStatus` klassifiziert:

- `executable`: Parser und Runtime wenden das Feld an;
- `reserved`: das Feld bleibt fuer die Vertragsentwicklung sichtbar, wird aber
  nicht als Runtime-Capability zugesagt;
- `partially-executable`: nur die in der Beschreibung genannten Werte besitzen
  einen Runtimepfad.

Ausfuehrbare Beispielmanifeste duerfen keine als `reserved` markierten Felder
verwenden. Bei `externalScripts.installMethod` ist `pre-built` reserviert.

## Pfadauflösung

Relative Pfade werden wie folgt behandelt:

- `postProvision`: relativ zum Manifest-Verzeichnis
- lokales `restore.source`: relativ zum Manifest-Verzeichnis
- `drives[].hostPath`: relativ zum Manifest-Verzeichnis
- Datenbank- und TempDB-Dateipfade: Containerpfade, keine Hostpfade

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
Test-SqlServerLabManifest -Path .\mein-lab.json
$env:SQL_SERVER_LAB_SECRET_SA_PASSWORD = '<aus Secret Store oder CI-Injection>'
New-SqlServerLab -Manifest .\Schemas\example-performance-lab.json
Remove-Item Env:SQL_SERVER_LAB_SECRET_SA_PASSWORD
```

`New-SqlServerLabManifest` liest den gesamten Eingabebaum aus
`lab-manifest.schema.json`; neue Schemafelder werden dadurch automatisch im
Konsolen-Wizard angeboten. `x-ui`-Metadaten ergänzen die generische Eingabe um
kontextreiche Hinweise. Die anschliessende Fachvalidierung prueft zusaetzlich
unter anderem Versionskatalog, Compatibility Level, Providerkombinationen,
Samplevarianten und lokale Dateipfade.

## Validierung

```powershell
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Die Prüfung kontrolliert JSON-Syntax, Schema-Referenzen und zentrale Beispielverträge. Ein echter Provider-Smoke-Test bleibt zusätzlich erforderlich.
