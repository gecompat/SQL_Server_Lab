# Schemas/ – JSON-Schemas und Labbeispiele

Dieses Verzeichnis enthält die maschinenlesbaren Verträge und ausführbaren Beispielmanifeste.

## Schema-Dateien

| Datei | Zweck |
|---|---|
| `lab-manifest.schema.json` | Struktur deklarativer Labdefinitionen |
| `version-catalog.schema.json` | Struktur von `Catalogs/sql-server-versions.json` |
| `sample-databases.schema.json` | Struktur von `Catalogs/sample-databases.json` |

## Beispiele

| Datei | Zweck | Erwarteter Status |
|---|---|---|
| `example-lab.json` | einfache Instanz mit Datenbank und Post-Provision | ausführbar, sofern referenzierte SQL-Datei vorhanden ist |
| `example-restore-lab.json` | Restore einer `.bak`-Quelle | ausführbar bei erreichbarer Quelle |
| `example-performance-lab.json` | Volumes, Data-/Log-Pfade, TempDB, Memory, MaxDOP und DB-Optionen | ausführbar mit ausreichenden Ressourcen |
| `example-cu-comparison.json` | zwei katalogisierte SQL-2022-CU-Stände mit identischer Sample-Datenbank | ausführbar, wenn die Image-Tags und Downloadquelle verfügbar sind |
| `example-ml-services.json` | External-Languages-Konfiguration | umgebungsabhängig; siehe Known Limitations |

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
- `externalScripts` mit den dokumentierten Einschränkungen

Das Schema enthält teilweise vorbereitete Erweiterungsfelder. Die verbindlichen Grenzen stehen in [`KNOWN_LIMITATIONS.md`](../Documentation/Quality/KNOWN_LIMITATIONS.md).

## Pfadauflösung

Relative Pfade werden wie folgt behandelt:

- `postProvision`: relativ zum Manifest-Verzeichnis
- lokales `restore.source`: relativ zum Manifest-Verzeichnis
- `drives[].hostPath`: relativ zum Manifest-Verzeichnis
- Datenbank- und TempDB-Dateipfade: Containerpfade, keine Hostpfade

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

Der Manifestparser akzeptiert automatisch nur Varianten mit direkter `.bak`-URL. Archive, SQL-Skripte und Attach-Szenarien werden nicht stillschweigend umgedeutet.

## Nutzung

```powershell
Import-Module .\SqlServerLab.psd1 -Force
New-SqlServerLab -Manifest .\Schemas\example-performance-lab.json
```

## Validierung

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Die Prüfung kontrolliert JSON-Syntax, Schema-Referenzen und zentrale Beispielverträge. Ein echter Provider-Smoke-Test bleibt zusätzlich erforderlich.
