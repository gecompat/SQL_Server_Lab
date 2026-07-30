# Catalogs/ – SQL-Versionen und Sample-Datenbanken

Die Kataloge sind maschinenlesbare Runtimeeingaben. Änderungen müssen mit Schema, Auflösungslogik, Beispielen und Tests konsistent bleiben.

## Dateien

| Datei | Zweck | Schema |
|---|---|---|
| `sql-server-versions.json` | SQL-Server-Versionen, Major Version, Compatibility Level, Status, Images, CU-Builds und Ressourcenprofile | `../Schemas/version-catalog.schema.json` |
| `sample-databases.json` | Metadaten öffentlicher Testdatenbanken, Varianten, Lizenzen, URLs und Mindestversionen | `sample-databases.schema.json` → `../Schemas/sample-databases.schema.json` |

## Versionskatalog

Vereinfachte Struktur:

```json
{
  "versions": [
    {
      "id": "2022",
      "major": 16,
      "compatibilityLevel": 160,
      "status": "SUPPORTED",
      "docker": {
        "image": "mcr.microsoft.com/mssql/server:2022-latest",
        "minMemoryMB": 2048,
        "builds": [
          {
            "tag": "2022-CU18-ubuntu-22.04",
            "cu": "CU18"
          }
        ]
      }
    }
  ],
  "profiles": {
    "standard": {
      "maxMemoryMB": 4096,
      "maxCpus": 4
    }
  }
}
```

### Auflösung

- `version: 2022` verwendet `docker.image`.
- `version: 2022-CU18` sucht den Build anhand von `builds[].cu`.
- `version: 2022-CU18-ubuntu-22.04` wird als exakter Image-Tag verwendet.
- Ein unbekannter CU-Kurzbezeichner wird nicht durch eine vermutete Tag-Konvention ersetzt.

### Neue Version ergänzen

1. Eintrag in `versions[]` hinzufügen.
2. Status aus `statusValues` verwenden.
3. Provider-Image und Mindestressourcen dokumentieren.
4. Schema validieren.
5. mindestens einen nicht mutierenden Auflösungstest ergänzen.
6. README, Known Limitations und Changelog prüfen.

Der Katalog wird nicht automatisch aktuell gehalten. Build- und CU-Angaben müssen fachlich verifiziert werden.

## Sample-Datenbank-Katalog

Jeder Eintrag enthält:

- stabile ID
- Datenbankname und Anzeigename
- Beschreibung und Kategorie
- Lizenz und Quellseite
- eine oder mehrere Varianten
- Download-URL, Größe und Compatibility Level
- Mindestversion von SQL Server
- Tags

Beispiel:

```json
{
  "id": "adventureworks-2022",
  "name": "AdventureWorks2022",
  "versions": {
    "full": {
      "url": "https://.../AdventureWorks2022.bak",
      "sizeMB": 209,
      "sha256": null,
      "runtimeStatus": "descriptive",
      "compatibility": 160
    }
  },
  "minSqlVersion": "2022"
}
```

### Runtimeunterstützung

Der Manifestparser kann Varianten automatisch bereitstellen, wenn ihre URL
direkt auf eine `.bak`-Datei zeigt, `runtimeStatus` den Wert `executable` hat und
eine verifizierte SHA-256-Pruefsumme hinterlegt ist.

Nicht automatisch ausführbar sind unter anderem:

- Archive wie `.7z` oder `.zip`
- Attach-Szenarien
- reine SQL-Skript-Varianten

Diese Einträge dürfen trotzdem als Planungs- und Quellenkatalog enthalten sein. Der Runtimepfad lehnt sie mit einer erklärenden Fehlermeldung ab.

### Prüfsummen

`sha256: null` bedeutet, dass keine kryptografische Prüfsumme hinterlegt ist.
Eine solche Variante muss `runtimeStatus: descriptive` tragen und wird nicht
automatisch ausgefuehrt. Die derzeit katalogisierten Downloads sind deshalb
beschreibend, bis ihre Artefakte ueber einen kontrollierten Download verifiziert
und mit SHA-256 freigegeben wurden. `cachePolicy.verifyChecksum` allein erzeugt
keine Prüfsumme.

## Validierung

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Die Prüfung kontrolliert JSON-Syntax, Schema-Referenzen und zentrale Katalogverträge.
