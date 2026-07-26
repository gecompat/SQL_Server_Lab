# Tests/ – Testinfrastruktur

## Verzeichnisse

| Verzeichnis | Inhalt |
|---|---|
| [Integration/](Integration/) | End-to-End Smoke-Test (Docker/Podman) |
| Static/ | Statische Analyse (geplant) |

## Smoke-Test ausfuehren

```powershell
Import-Module .\SqlServerLab.psd1 -Force
.\Tests\Integration\Invoke-SmokeTest.ps1
```

Der Test erkennt automatisch die verfuegbare Runtime (Docker/Podman)
und prueft ALLE installierten Provider.
