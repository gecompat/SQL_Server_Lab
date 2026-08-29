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
- Ressourcen-Limits (Memory, CPUs) per Profile; SQL Server erhaelt zusaetzlich
  ein eigenes Memory-Limit mit 20 Prozent Headroom unterhalb des cgroup-Limits
- TLS-vertraulicher Healthcheck gegen das run-lokale selbstsignierte Zertifikat
- providerneutraler Autostart über `--restart unless-stopped`,
  `sql-server-lab.autostart=on` und unter Windows einen verwalteten
  Benutzer-Anmeldeauftrag für Docker Desktop
- SQL Server 2019 External Runtime für Java sowie SQL Server 2022/2025 für
  Python, R und Java über ein
  digestgebundenes Derived Image; der sichere Namespace-Modus erfordert einen
  rootful Linux-Host mit cgroup v1 und wird vor jeder Mutation geprüft
