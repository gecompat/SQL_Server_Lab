# Public/ – Exportierte Cmdlets

Dieses Verzeichnis enthaelt alle oeffentlich exportierten PowerShell-Funktionen des Moduls.
Sie werden in `SqlServerLab.psd1` unter `FunctionsToExport` registriert.

## Cmdlet-Uebersicht

| Cmdlet | Datei | Zweck |
|---|---|---|
| `Invoke-SqlServerLab` | Invoke-SqlServerLab.ps1 | Interaktives Menue mit Provider-Auswahl + Auto-Import |
| `New-SqlServerLab` | New-SqlServerLab.ps1 | Neue Umgebung (Ad-hoc oder Manifest) |
| `Get-SqlServerLab` | Get-SqlServerLab.ps1 | Status anzeigen (State + Live-Container) |
| `Stop-SqlServerLab` | Stop-SqlServerLab.ps1 | Graceful Stop |
| `Start-SqlServerLab` | Start-SqlServerLab.ps1 | Gestoppte Umgebung starten + SQL-Readiness |
| `Restart-SqlServerLab` | Restart-SqlServerLab.ps1 | Stop + Start Convenience |
| `Remove-SqlServerLab` | Remove-SqlServerLab.ps1 | Scope-validiertes Entfernen |
| `Clear-SqlServerLab` | Clear-SqlServerLab.ps1 | Alle Lab-Container + State aufraeumen |
| `New-LabDatabase` | New-LabDatabase.ps1 | CREATE DATABASE mit Multi-File-Specs |
| `Invoke-LabScript` | Invoke-LabScript.ps1 | T-SQL ausfuehren (GO-Splitting, -KeepConnection) |
| `Restore-LabDatabase` | Restore-LabDatabase.ps1 | RESTORE aus URL/Datei (Cache, FILELISTONLY, MOVE) |

## Noch nicht implementiert (in psd1 exportiert)

- `Install-LabSoftware` – Software in HyperV-VMs
- `Test-LabResources` – Wrapper (definiert in ResourceAssessment.ps1)
- `Invoke-LabCleanup` – Manueller Cleanup-Trigger
- `Invoke-LabRecovery` – Recovery-Pfad nach partiellem Fehler
