# Catalogs/ – Versionskatalog

Maschinenlesbare Definitionen der unterstuetzten SQL-Server-Versionen.

## sql-server-versions.json

```json
{
  "2019": { "major": 15, "image": "mcr.microsoft.com/mssql/server:2019-latest" },
  "2022": { "major": 16, "image": "mcr.microsoft.com/mssql/server:2022-latest" },
  "2025": { "major": 17, "image": "mcr.microsoft.com/mssql/server:2025-latest" }
}
```

## Erweiterung

Neue Versionen einfach als Key hinzufuegen. Das Modul erkennt sie automatisch.
