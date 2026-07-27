# Private/ – Interne Modulfunktionen

Der Modul-Loader `SqlServerLab.psm1` dot-sourct die PowerShell-Dateien dieses Verzeichnisses in den Modulkontext.

Der Pfad `Private/` beschreibt primär die interne Architektur. Die tatsächliche öffentliche Sichtbarkeit wird ausschließlich durch `FunctionsToExport` in `SqlServerLab.psd1` festgelegt. Derzeit ist `Test-LabResources` bewusst exportiert, obwohl die Funktion in `Private/ResourceAssessment.ps1` definiert ist.

## Dateien

| Datei | Verantwortung |
|---|---|
| `Common.ps1` | Ausgabe, Eingaben, IDs, Zeitstempel und gemeinsame Runtime-Erkennung |
| `PathSafety.ps1` | geschützte Pfade, Scope-Prüfung und Scope-Marker |
| `SecretProvider.ps1` | lokales Speichern, Lesen und Entfernen von Secrets |
| `VersionCatalog.ps1` | Versionen, CU-Builds, Images, Ressourcenprofile und Sample-Katalogzugriff |
| `StateMachine.ps1` | State-Root, Run-State, Übergänge, Historie und aktive Runs |
| `SqlReadiness.ps1` | SQL-Bereitschaft, Queries und interne Skriptausführung |
| `ResourceAssessment.ps1` | Provider-, RAM-, Storage- und Portprüfung; definiert das exportierte `Test-LabResources` |
| `CleanupEngine.ps1` | Cleanup-Plan, Schritte und Compensation |
| `ManifestParser.ps1` | Manifestvalidierung, Defaults, relative Pfade und Sample-Auflösung |
| `ServerConfig.ps1` | Server- und Datenbankoptionen sowie External Languages |

## Zentrale Aufrufkette

```text
New-SqlServerLab
  -> Read-LabManifest
  -> Test-SqlServerVersionSupported
  -> Test-LabResources
  -> New-LabRunState
  -> New-CleanupPlan
  -> Provider-Provisionierung
  -> Wait-SqlReady
  -> Set-LabServerConfig
  -> New-LabDatabase oder Restore-LabDatabase
  -> Set-LabDatabaseOptions
  -> Invoke-LabSqlScript
  -> connection-info.json
```

## Interne Funktionen sind keine Benutzer-API

Benutzerdokumentation darf interne Hilfsfunktionen nicht als stabilen direkten Einstieg empfehlen. Das betrifft beispielsweise:

- `Get-LabStateRoot`
- `Get-LabRunState`
- `Get-LabSecret`
- `Get-SqlServerDockerImage`
- `Resolve-LabSampleRestore`
- `Invoke-CleanupPlan`

Für öffentliche Bedienung sind die in `SqlServerLab.psd1` exportierten Funktionen zu verwenden.

## Konventionen

- kein `Export-ModuleMember` in einzelnen Private-Dateien;
- PowerShell-Verb-Nomen-Namen;
- keine erfundenen Fallbacks für unbekannte Versionen oder Quellen;
- relative Pfade werden im Manifestparser normalisiert;
- State und Cleanup-Plan entstehen vor Provider-Mutationen;
- Fehler enthalten ausreichenden Kontext und werden nicht als Erfolg maskiert;
- Änderungen an internen Verträgen werden in `.ai/repo_map.yaml`, Known Limitations und Tests nachgeführt.

## Prüfung

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Bei Runtimeänderungen zusätzlich den betroffenen Provider getrennt testen.
