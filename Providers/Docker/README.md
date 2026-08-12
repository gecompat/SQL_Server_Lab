# Providers/Docker/ – Docker-Provider

Container-basierte SQL-Server-Instanzen via Docker Desktop oder Docker Engine.

## Dateien

- `provider.json` – Port-Range (14330-14399), Label-Prefix, Requirements
- `DockerProvider.ps1` – Vollstaendige Provider-Implementierung

## Features

- Volume-Mounts fuer Multi-Disk-Szenarien (`-Drives`)
- Health-Check via sqlcmd
- Labels fuer Lifecycle-Management (`sql-server-lab.*`)
- MSSQL_AGENT_ENABLED=true (immer aktiv)
- Ressourcen-Limits (Memory, CPUs) per Profile
- providerneutraler Autostart über `--restart unless-stopped`,
  `sql-server-lab.autostart=on` und unter Windows einen verwalteten
  Benutzer-Anmeldeauftrag für Docker Desktop
