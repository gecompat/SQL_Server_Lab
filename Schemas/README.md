# Schemas/ – Manifest-Definitionen und JSON-Schema

Deklarative Lab-Definitionen im JSON-Format.

## Dateien

| Datei | Zweck |
|---|---|
| `lab-manifest.schema.json` | JSON-Schema (Draft-07) – IDE-Validierung + Autocomplete |
| `example-lab.json` | Einfaches Lab: 1 Instanz, 1 DB, PostProvision |
| `example-restore-lab.json` | Lab mit AdventureWorks-Restore von URL |
| `example-performance-lab.json` | Performance-Schulung: TempDB, Drives, Memory, MaxDOP |
| `setup-schulung.sql` | PostProvision-SQL fuer example-lab.json |

## Schema-Features

- Instanzen: version, provider, profile, collation, drives, serverConfig
- Datenbanken: files (Multi-Disk), restore (URL/Datei), options (Recovery Model, RCSI, Query Store)
- Server-Konfiguration: memory, tempdb, maxDop, costThreshold, traceFlags, defaultPaths, spConfigure
- VS Code: Schema automatisch aktiv via `.vscode/settings.json`

## Nutzung

```powershell
New-SqlServerLab -Manifest .\Schemas\example-lab.json
```
