# Private/ – Interne Modulfunktionen

Nicht exportierte Hilfsfunktionen. Werden vom Modul-Loader (`SqlServerLab.psm1`)
automatisch dot-sourced und stehen allen Public-Cmdlets zur Verfuegung.

## Dateien

| Datei | Inhalt |
|---|---|
| `Common.ps1` | Write-Lab*, Read-Lab*, New-LabGuid, Get-LabTimestamp, Test-CommandExists, Get-ContainerRuntime |
| `PathSafety.ps1` | Get-ProtectedPaths, Test-PathSafe, Assert-PathSafe, Write-ScopeMarker |
| `SecretProvider.ps1` | Save/Get/Remove-LabSecret (DPAPI auf Windows) |
| `VersionCatalog.ps1` | Get-SqlServerVersion, Get-SqlServerDockerImage, Get-LabResourceProfile |
| `StateMachine.ps1` | Get/Set/New/Add/Remove-LabRunState, Get-LabActiveRuns, Get-LabStateRoot |
| `SqlReadiness.ps1` | Wait-SqlReady, Invoke-SqlQuery (3-stufig), Invoke-SqlReader, Invoke-LabSqlScript |
| `ResourceAssessment.ps1` | Test-LabResources, Test-ProviderAvailability, Test-RamAvailability |
| `CleanupEngine.ps1` | New-CleanupPlan, Add-CleanupStep, Invoke-CleanupPlan |
| `ManifestParser.ps1` | Read-LabManifest, Resolve-ManifestDefaults, Resolve-ProviderAutoSelect, Resolve-DatabaseFiles |
| `ServerConfig.ps1` | Set-LabServerConfig, Set-LabDatabaseOptions, Resolve-GrowthClause |

## Konventionen

- Kein `Export-ModuleMember` in Private-Dateien
- Funktionen beginnen mit Verb-Noun (PowerShell-Standard)
- Fehler werden via `throw` oder `Write-LabError` kommuniziert
