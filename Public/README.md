# Public/ – Exportierte Cmdlets

Dieses Verzeichnis enthält die öffentlichen PowerShell-Funktionen des Moduls. Die autoritative Exportliste steht in `SqlServerLab.psd1`.

## Cmdlet-Übersicht

| Cmdlet | Datei oder Definition | Zweck |
|---|---|---|
| `Invoke-SqlServerLab` | `Invoke-SqlServerLab.ps1` | Interaktives Menü |
| `New-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema-gesteuertes Manifest interaktiv oder aus einem Objekt erstellen |
| `Test-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema, Kataloge und Runtime-Grenzen ohne Provisionierung prüfen |
| `New-SqlServerLab` | `New-SqlServerLab.ps1` | Neue Umgebung ad hoc oder per Manifest erstellen |
| `Get-SqlServerLab` | `Get-SqlServerLab.ps1` | State und Live-Containerstatus je Provider anzeigen |
| `Start-SqlServerLab` | `Start-SqlServerLab.ps1` | Gestoppte Umgebung je gespeicherten Provider starten |
| `Stop-SqlServerLab` | `Stop-SqlServerLab.ps1` | Laufende Umgebung je gespeicherten Provider stoppen |
| `Restart-SqlServerLab` | `Restart-SqlServerLab.ps1` | Stop und Start kombinieren |
| `Remove-SqlServerLab` | `Remove-SqlServerLab.ps1` | Einzelnen Run scope-validiert entfernen |
| `Clear-SqlServerLab` | `Clear-SqlServerLab.ps1` | Lab-Container und/oder State bereinigen |
| `New-SqlServerLabDatabase` | `New-SqlServerLabDatabase.ps1` | Datenbank mit konfigurierbaren Dateien und Pfaden erstellen |
| `Invoke-SqlServerLabScript` | `Invoke-SqlServerLabScript.ps1` | T-SQL-Skript mit `GO`-Batchtrennung ausführen |
| `Restore-SqlServerLabDatabase` | `Restore-SqlServerLabDatabase.ps1` | Direkte `.bak`-Datei wiederherstellen; URL-Acquisition mit SHA-256, lokalem Trust Store und inhaltsadressiertem Cache; Ziel bevorzugt per RunId aufloesen |
| `Test-SqlServerLabPrerequisite` | `Private/ResourceAssessment.ps1` | Provider, RAM, Storage und Ports ohne Mutation prüfen |
| `Test-SqlServerLabAdapter` | `Test-SqlServerLabAdapter.ps1` | Project Adapter gegen Schema, Pfadgrenzen und optional eine Run-Instanz prüfen |
| `Install-SqlServerLabAdapter` | `Install-SqlServerLabAdapter.ps1` | Validierten Adapter-Entrypoint ohne Lifecycle-Seiteneffekt auf eine Instanz anwenden |

`Test-SqlServerLabPrerequisite` ist öffentlich exportiert, obwohl seine Definition im internen Resource-Assessment-Baustein liegt. Der Ablageort allein bestimmt nicht die Sichtbarkeit; maßgeblich ist `FunctionsToExport` im Modulmanifest.

## Hilfe, Discovery und Modulzuordnung

PowerShell stellt die öffentliche API über die Standardmechanismen bereit:

```powershell
Get-Command -Module SqlServerLab | Sort-Object Name
Get-Help about_SqlServerLab
Get-Help New-SqlServerLab -Full
```

`ModuleName` und `Source` ordnen jeden Export eindeutig `SqlServerLab` zu. Bei
Namenskonflikten kann ein Command modulqualifiziert aufgerufen werden, zum
Beispiel `SqlServerLab\New-SqlServerLabDatabase`.

Die verbindlichen Regeln für zugelassene Verben, spezifische Nomen,
Comment-based Help und mögliche spätere Namensmigrationen stehen im
[PowerShell Command and Help Standard](../Documentation/Standards/POWERSHELL_COMMAND_AND_HELP_STANDARD.md).

## Öffentliche und interne Verträge

Öffentlich stabil sind nur die exportierten Funktionen. Hilfsfunktionen aus `Private/` und `Providers/` dürfen in Benutzeranleitungen nicht als direkte Bedienoberfläche verwendet werden.

Insbesondere sind folgende Namen keine öffentliche API:

- `Get-LabStateRoot`
- `Get-LabRunState`
- `Get-LabSecret`
- `Get-DockerInstanceStatus`
- `Get-PodmanInstanceStatus`
- `Invoke-CleanupPlan`

## Dokumentationspflicht bei Änderungen

Bei einer neuen oder geänderten öffentlichen Funktion müssen mindestens gemeinsam geprüft werden:

1. `SqlServerLab.psd1`
2. Comment-based Help der Funktion
3. diese Übersicht
4. Root-README und Getting Started
5. `.ai/repo_map.yaml`
6. statische Vertragsprüfung
7. Integrationstest, falls Runtimeverhalten betroffen ist

## Prüfung

```powershell
Import-Module .\SqlServerLab.psd1 -Force
Get-Command -Module SqlServerLab | Sort-Object Name
.\Tests\Static\Invoke-DocumentationChecks.ps1
```
