# Catalogs/ – SQL-Versionen und Sample-Datenbanken

Die Kataloge sind maschinenlesbare Runtimeeingaben. Änderungen müssen mit Schema, Auflösungslogik, Beispielen und Tests konsistent bleiben.

## Dateien

| Datei | Zweck | Schema |
|---|---|---|
| `sql-server-versions.json` | SQL-Server-Versionen, Major Version, Compatibility Level, Status, Images, CU-Builds und Ressourcenprofile | `../Schemas/version-catalog.schema.json` |
| `sample-databases.json` | Metadaten öffentlicher Testdatenbanken, Varianten, Lizenzen, URLs und Mindestversionen | `sample-databases.schema.json` → `../Schemas/sample-databases.schema.json` |
| `software.json` | Providerneutrale SQL-bezogene Software- und External-Runtime-Varianten mit Support-, Integrity- und Verification-Metadaten | `../Schemas/software-catalog.schema.json` |

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

## Softwarekatalog

`software.json` trennt die deklarative Anforderung von der konkreten
Installation. Der Resolver bindet SQL-Major-Version, Betriebssystem,
Architektur und Provider an genau eine Variante. Eine Variante ist erst
`SUPPORTED`, wenn alle erforderlichen Artefakte mit Version, SHA-256 und
Herkunft gebunden sind und der Provider die notwendigen Capabilities
deklariert. Die vorbereiteten SQL-2022-Varianten für Python, R und Java bleiben
bis zum Derived-Image- beziehungsweise Hyper-V-Nachweis `PREVIEW` und werden
vor jeder Mutation als `DECLARED_UNSUPPORTED` abgelehnt.

Die Linux-Python-Variante besitzt bereits vollständige Basisimage-, DEB- und
Wheel-Artefakte. `Images/ExternalLanguages/Linux/recipe.json` und die
Lockdatei müssen dieselben IDs, Versionen, Quellen und SHA-256-Werte enthalten.
Diese Artefaktvollständigkeit allein hebt den Status nicht an: Docker und
Podman benötigen je eine echte Native Acceptance im sicheren
`sql2022-namespace-v1`-Modus.

Freie Installationsbefehle und nicht katalogisierte Zusatzpakete sind für
External Runtimes nicht zulässig. Der geheimnisfreie Desired State enthält nur
IDs, Versionen, Hashes, Rezept- und Postcondition-Metadaten, aber keine
Download- oder lokalen Gastpfade.

## Sample-Datenbank-Katalog

Jeder Eintrag enthält:

- stabile ID
- Datenbankname und Anzeigename
- Beschreibung und Kategorie
- Lizenz und Quellseite
- eine oder mehrere typisierte Artifact-Varianten
- konkreten Artifact Type, Handler-Contract-Version und typspezifische Installation-Metadaten
- Download- und, soweit belastbar, Installationsgröße
- erwartete Datenbankausgaben, Integrity Origin und Trust Policy
- Download-URL und Compatibility Level
- Mindestversion von SQL Server
- Tags

Beispiel:

```json
{
  "id": "adventureworks-2022",
  "name": "AdventureWorks2022",
  "versions": {
    "full": {
      "artifactType": "backup",
      "handlerContractVersion": "1",
      "url": "https://.../AdventureWorks2022.bak",
      "downloadSizeMB": 209,
      "estimatedInstallSizeMB": null,
      "resourceEstimateStatus": "unknown",
      "sha256": null,
      "integrityOrigin": null,
      "trustPolicy": "interactive-once",
      "runtimeStatus": "executable",
      "compatibility": 160,
      "expectedOutputs": [
        { "name": "AdventureWorks2022", "kind": "database" }
      ],
      "installation": {
        "kind": "backup",
        "restoreMode": "direct-backup",
        "idempotencyMode": "fail-if-exists",
        "baselinePolicy": "eligible-after-verification"
      }
    }
  },
  "minSqlVersion": "2022"
}
```

### Runtimeunterstützung

Der Katalog wird in den gemeinsamen Artifact-Vertrag aufgelöst. Automatisch
bereitstellen kann der aktuelle Runtimepfad direkte Backups (`backup` und
`.bak`), sichere Archiv-Backups (`archive-backup` mit `.zip` oder `.7z`) sowie
einzelne T-SQL-Skripte (`sql-script` und `.sql`) und katalogisierte ZIP-Script-
Bundles (`script-bundle`), jeweils mit
`runtimeStatus: executable`. Archiv-Backups benötigen eine exakte
`installation.payloadPath`-Angabe und werden nur temporär entpackt. Für `.7z`
muss die lokale 7-Zip-Kommandozeile verfügbar sein; sie kann nach expliziter
Bestätigung mit `Install-SqlServerLab7Zip` bzw. über den Konsolenmenüpunkt
`[z]` installiert werden. Die Integrität sichert entweder eine
Katalog-SHA-256 (`trustPolicy: catalog-only`) oder der Trust-Pfad
`interactive-once` mit einmaliger interaktiver Freigabe; nicht interaktive
Läufe enden ohne bekannten Hash mit `TRUST_REQUIRED`.

Nicht automatisch ausführbar sind unter anderem:

- nicht katalogisierte Archive
- Attach-Szenarien
- Script-Bundles mit nicht freigegebenen sqlcmd-Features, `:connect` oder
  Shell-Escapes; `:r` und `:setvar` sind nur innerhalb des extrahierten
  Bundle-Roots und bei explizitem `allowedSqlcmdFeatures` zulässig

Diese Einträge dürfen trotzdem als Planungs- und Quellenkatalog enthalten sein.
Der Runtimepfad lehnt sie mit einer erklärenden Fehlermeldung ab.

Der verbindliche Zielvertrag für zusätzliche Artifact Types und Baselines steht in [Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](../Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md). Der Sample-Backup-Handler nutzt Trust Store, inhaltsadressierten Cache und Run Lock einschließlich Sample-Identität.

### Prüfsummen

`sha256: null` bedeutet, dass keine kryptografische Prüfsumme hinterlegt ist.
In diesem Fall muss `integrityOrigin: null` und
`trustPolicy: interactive-once` gesetzt sein. Der implementierte Trust Store
darf nach einer ausdrücklichen interaktiven Entscheidung nur lokal einen
erwarteten Hash registrieren; `cachePolicy.verifyChecksum` allein erzeugt keine
Prüfsumme. Kontrolliert verifizierte Prüfsummen sollen mittelfristig als
`catalog-verified` mit `trustPolicy: catalog-only` in den Katalog übernommen
werden.

## Validierung

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Die Prüfung kontrolliert JSON-Syntax, Schema-Referenzen und zentrale Katalogverträge.
