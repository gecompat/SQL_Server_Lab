# Private/ – Interne Modulfunktionen

Der Modul-Loader `SqlServerLab.psm1` dot-sourct die PowerShell-Dateien dieses Verzeichnisses in den Modulkontext.

Der Pfad `Private/` beschreibt primär die interne Architektur. Die tatsächliche öffentliche Sichtbarkeit wird ausschließlich durch `FunctionsToExport` in `SqlServerLab.psd1` festgelegt. Derzeit ist `Test-SqlServerLabPrerequisite` bewusst exportiert, obwohl die Funktion in `Private/ResourceAssessment.ps1` definiert ist.

## Dateien

| Datei | Verantwortung |
|---|---|
| `Common.ps1` | Ausgabe, Eingaben, IDs, Zeitstempel und gemeinsame Runtime-Erkennung |
| `AttentionStatus.ps1` | Read-only Snapshot für CU-/Media-Lücken, Slot-/Vorlagenkapazität, Builder und Recovery im Konsolen-Footer |
| `PathSafety.ps1` | geschützte Pfade, Scope-Prüfung und Scope-Marker |
| `SecretProvider.ps1` | lokales Speichern, Lesen und Entfernen von Secrets |
| `VersionCatalog.ps1` | Versionen, CU-Builds, Images, Ressourcenprofile, sichere Windows-CU-Acquisition und Linux-Image-Prefetch |
| `SoftwareCatalog.ps1` | Providerneutrale External-Runtime-Anforderungen, kataloggebundene Planauflösung und sanitisiertes Installation Receipt |
| `StateMachine.ps1` | State-Root, Run-State, ProviderSubRuns, Übergänge, Historie und aktive Runs |
| `DesiredState.ps1` | Geheimnisfreier Run-Sollzustand mit providerneutralen Drive-, Network- und Software-Intents |
| `StorageContract.ps1` | Controllergebundene Multi-Root-Registry, stabile Location-Metadaten, Topologie und Migrationseinstieg |
| `StorageFilePlacement.ps1` | Read-only Bindung portabler SQL-Storage-Intents an lokale Locations, Topologie, Gastpfade und reviewbare SQL-Dateien |
| `ArtifactResolver.ps1` | HTTP(S)-Backup-Acquisition, lokaler Trust Store, inhaltsadressierter Cache, Quarantäne und sanitisiertes Run Lock |
| `SampleArtifactHandlers.ps1` | Backup-, Archiv-, Einzel-Skript- und sichere Multi-Output-Script-Bundle-Installation |
| `SampleBaselineRegistry.ps1` | Inhaltsadressiertes `LAB_GENERATED`-Register, deterministische Keys, exakte/kompatible Auswahl und Quarantäne |
| `SampleBaselineRuntime.ps1` | Erzeugung und bevorzugte Wiederverwendung verifizierter Single- und Multi-Output-Container-Baselines |
| `SqlReadiness.ps1` | SQL-Bereitschaft, Queries und interne Skriptausführung |
| `ResourceAssessment.ps1` | Prüfung aller verwendeten Provider sowie runweiter RAM-, Storage- und Portkapazität; definiert das exportierte `Test-SqlServerLabPrerequisite` |
| `CleanupEngine.ps1` | Cleanup-Plan, ProviderSubRuns, Schritte und Compensation |
| `ManifestBuilder.ps1` | Schema-gesteuerte Eingabe sowie Schema-, Katalog- und Runtime-Fachprüfung |
| `ManifestParser.ps1` | Manifestvalidierung, Defaults, relative Pfade und Sample-Auflösung |
| `ServerConfig.ps1` | Server- und Datenbankoptionen sowie abgesicherte External-Languages-Aktivierungsgrenze |

## Zentrale Aufrufkette

```text
New-SqlServerLab
  -> Read-LabManifest
  -> Test-SqlServerVersionSupported
  -> Test-SqlServerLabPrerequisite
  -> New-LabRunState
  -> ProviderSubRuns
  -> New-CleanupPlan
  -> Provider-Provisionierung
  -> Wait-SqlReady
  -> Set-LabServerConfig
  -> New-SqlServerLabDatabase oder Restore-SqlServerLabDatabase
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
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-ArtifactResolverChecks.ps1
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
```

Bei Runtimeänderungen zusätzlich den betroffenen Provider getrennt testen.
