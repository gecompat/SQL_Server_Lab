# Tests/ – Lokale Validierung

## Verzeichnisse

| Verzeichnis | Inhalt |
|---|---|
| `Static/` | Import-, Export-, JSON-, Schema-, Metadaten-, Link- und Dokumentationskonsistenz |
| `Integration/` | mutierender End-to-End-Smoke-Test für genau einen gewählten Provider |

## Statische Prüfung

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Die Prüfung benötigt keine laufende SQL-Server-Instanz. Sie kontrolliert unter anderem:

- JSON-Syntax der Kataloge, Schemas und Beispiele
- Existenz referenzierter Schema-Dateien
- Import des Modulmanifests
- Übereinstimmung von `FunctionsToExport` und tatsächlich verfügbaren Funktionen
- Existenz der in Provider-Metadaten angegebenen Module
- zentrale Dokumentationslinks
- Ausschluss bekannter veralteter Beispiele wie `Restore-LabDatabase -RunId` oder `-BackupUrl`
- Ausschluss des veralteten Status `PLANNING_FOUNDATION` in der Root-README

## Integration-Smoke-Test

Docker:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
```

Podman:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Auto-Modus:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
```

### Tatsächliches Auto-Verhalten

Im Auto-Modus wird für den mutierenden Lifecycle genau eine Runtime gewählt:

1. Docker, wenn der Befehl `docker` vorhanden ist;
2. sonst Podman, wenn der Befehl `podman` vorhanden ist;
3. sonst Abbruch.

Der Test führt Resource Assessment zusätzlich für alle erkannten Provider aus. Er provisioniert aber nicht automatisch nacheinander auf allen installierten Providern.

## Voraussetzungen des Smoke-Tests

- PowerShell 7.2 oder neuer
- laufendes Docker oder Podman
- `sqlcmd`
- genügend RAM, Storage und freier Port
- Zugriff auf das konfigurierte SQL-Server-Container-Image

## Getrennte Provider-Abnahme

Für eine belastbare lokale Abnahme sind Docker und Podman ausdrücklich getrennt aufzurufen:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Ein erfolgreicher Docker-Lauf ist kein Nachweis für Podman und umgekehrt.

## Fehlerdiagnose

Container bei einem fehlgeschlagenen Test behalten:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -KeepOnFailure
```

Danach:

```powershell
Get-SqlServerLab -Detailed
```

Runtime-Logs:

```powershell
docker ps -a --filter 'label=sql-server-lab.run-id'
docker logs <ContainerName>

# oder
podman ps -a --filter 'label=sql-server-lab.run-id'
podman logs <ContainerName>
```
