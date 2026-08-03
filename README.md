# SQL Server Lab

---

# ⚠️ READ BEFORE USE

## License notice

**NOTICE: This software is NOT Open Source. Use is governed by a custom Attribution & Non-Commercial Redistribution License.**

1. **NO RESALE:** Selling, renting, leasing, or charging third parties for access to this repository, its scripts, lab definitions, templates, documentation, or generated project content is prohibited.
2. **ATTRIBUTION REQUIRED:** The copyright notice for **gecompat - Gerhard Pisch** must be preserved.
3. **NO LIABILITY:** Use is at your own risk. Lab scenarios may deliberately create resource pressure, failures, configuration changes, or destructive states inside isolated lab scopes.

The complete terms are defined in [LICENCE.md](./LICENCE.md).

---

## Zweck

`SQL_Server_Lab` erstellt lokale, isolierte und reproduzierbare SQL-Server-Testumgebungen. Das PowerShell-Modul kapselt Provisionierung, Ressourcenprüfung, Container-Lifecycle, SQL-Bereitschaft, Datenbankerstellung, Restore, Skriptausführung, lokalen Run-State und Cleanup.

Das Repository dient insbesondere als gemeinsame Ausführungsbasis für:

- [`gecompat/SQL_Server_Analyze`](https://github.com/gecompat/SQL_Server_Analyze)
- [`gecompat/SQL_PerformanceSchulung`](https://github.com/gecompat/SQL_PerformanceSchulung)

Fachliche Testszenarien bleiben in den konsumierenden Projekten. `SQL_Server_Lab` stellt dafür die benötigte Umgebung bereit.

## Aktueller Status

**Status:** `CONTAINER_CORE_IMPLEMENTED_HYPERV_IMAGE_SEALING_RESUME`

| Bereich | Status | Nachweis |
|---|---|---|
| PowerShell-Modul | implementiert | `SqlServerLab.psd1`, `SqlServerLab.psm1` |
| Docker-Provider | implementiert | `Providers/Docker/DockerProvider.ps1` |
| Podman-Provider | implementiert | `Providers/Podman/PodmanProvider.ps1` |
| Gemischter Docker-/Podman-Lifecycle | implementiert | `Documentation/Architecture/MIXED_PROVIDER_LIFECYCLE.md` |
| Hyper-V-Provider | Lifecycle, Image-Registry, Windows-Builder sowie buildgebundene Sealing-/Resume-Publikation implementiert; Installation/Generalisierung noch manuell | `Private/HyperVImageBuilder.ps1`, `Private/HyperVImageRegistry.ps1` |
| Ad-hoc-Provisionierung | implementiert | `New-SqlServerLab -Version ... -Provider ...` |
| Manifest-Provisionierung | implementiert | `Schemas/lab-manifest.schema.json` |
| Resource Assessment | implementiert | `Test-SqlServerLabPrerequisite` |
| Run-State und Cleanup-Plan | implementiert | `Private/StateMachine.ps1`, `Private/CleanupEngine.ps1` |
| Datenbankerstellung | implementiert | `New-SqlServerLabDatabase` |
| Backup-Restore mit Artifact Resolver | implementiert | `Restore-SqlServerLabDatabase`, `Private/ArtifactResolver.ps1` |
| Sample-Datenbanken (Backup) | implementiert | `Private/SampleArtifactHandlers.ps1`; direkte `.bak`-Varianten über Trust-/Hash-Pfad, Mehrfachauswahl im Menü und `New-SqlServerLab -Sample` |
| Project Adapter (v0.1) | implementiert | `Schemas/project-adapter.schema.json`, `Test-SqlServerLabAdapter`, `Install-SqlServerLabAdapter`; T-SQL-Entrypoints ohne Lifecycle-Seiteneffekt |
| T-SQL-Skriptausführung | implementiert | `Invoke-SqlServerLabScript` |
| Provider-/Versions-/Parallel-Smoke-Test | implementiert | `Tests/Integration/Invoke-SmokeMatrix.ps1` |
| Einzelprovider-Smoke-Test | implementiert | `Tests/Integration/Invoke-SmokeTest.ps1` |
| Statische Konsistenzprüfung | implementiert | `Tests/Static/Invoke-DocumentationChecks.ps1` |

Die [bekannten Grenzen](Documentation/Quality/KNOWN_LIMITATIONS.md) sind Teil des öffentlichen Vertrags. Planungsdokumente sind kein Runtime-Nachweis.

## Voraussetzungen

Mindestens erforderlich:

- PowerShell 7.2 oder neuer
- Docker oder Podman
- mindestens 4 GB freier RAM für ein kleines Lab
- mindestens 5 GB freier Speicherplatz
- `sqlcmd` für Datenbankerstellung, Restore, Skriptausführung und den vollständigen Smoke-Test

Runtime prüfen:

```powershell
$PSVersionTable.PSVersion
docker info
# oder
podman info

sqlcmd -?
```

## Schnellstart

Repository klonen und Modul importieren:

```powershell
git clone https://github.com/gecompat/SQL_Server_Lab.git
Set-Location .\SQL_Server_Lab
Import-Module .\SqlServerLab.psd1 -Force
```

Ressourcen prüfen, ohne etwas zu verändern:

```powershell
Test-SqlServerLabPrerequisite -Provider docker
# oder
Test-SqlServerLabPrerequisite -Provider podman
```

Eine SQL-Server-2025-Umgebung erstellen:

```powershell
$lab = New-SqlServerLab -Version '2025' -Provider docker
```

Mit Podman:

```powershell
$lab = New-SqlServerLab -Version '2025' -Provider podman
```

Interaktive Bedienung:

```powershell
Invoke-SqlServerLab
```

Status anzeigen:

```powershell
Get-SqlServerLab
```

## Verbindung herstellen

`New-SqlServerLab` liefert pro Instanz Host, Port und Connection String zurück.

```powershell
$instance = $lab.Instances[0]
$instance.Host
$instance.Port
$instance.ConnectionString
```

Beispiel für SSMS:

```text
Server name: 127.0.0.1,14330
Authentication: SQL Server Authentication
Login: sa
Password: das bei der Erstellung gesetzte SA-Passwort
Trust server certificate: aktiviert
```

Der konkrete Port wird dynamisch im Bereich `14330` bis `14399` vergeben, sofern kein Port vorgegeben wurde.

## Datenbank erstellen

```powershell
$pw = Read-Host 'SA-Passwort' -AsSecureString

New-SqlServerLabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -DatabaseName 'MeineTestDB'
```

Dateien können auf gemountete Containerpfade gelegt werden:

```powershell
New-SqlServerLabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -DatabaseName 'PerfDB' `
    -DataFiles @(
        @{ name = 'PerfDB_Data1'; path = '/sqldata/PerfDB_Data1.mdf'; sizeMB = 512 },
        @{ name = 'PerfDB_Data2'; path = '/sqldata/PerfDB_Data2.ndf'; sizeMB = 512 }
    ) `
    -LogFiles @(
        @{ name = 'PerfDB_Log'; path = '/sqllog/PerfDB_Log.ldf'; sizeMB = 256 }
    )
```

Die Zielpfade müssen als `drives` beziehungsweise Volumes in der Labdefinition bereitgestellt sein.

## T-SQL-Skript ausführen

```powershell
Invoke-SqlServerLabScript `
    -ScriptPath '.\setup.sql' `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -Database 'MeineTestDB'
```

Relative `postProvision`-Pfade in Manifesten werden relativ zum Manifest-Verzeichnis aufgelöst.

## Backup wiederherstellen

Manueller Restore:

```powershell
Restore-SqlServerLabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -BackupSource 'C:\Backups\AdventureWorks2022.bak' `
    -DatabaseName 'AdventureWorks2022' `
    -ContainerName $lab.Instances[0].ContainerName
```

Fuer einen bereits provisionierten Run ist die RunId-basierte Aufloesung
bevorzugt; sie liest Provider, Container, Host und Port aus dem lokalen State:

```powershell
Restore-SqlServerLabDatabase `
    -RunId $lab.RunId `
    -InstanceId 'primary' `
    -SaPassword $pw `
    -BackupSource 'C:\Backups\AdventureWorks2022.bak' `
    -DatabaseName 'AdventureWorks2022'
```

Eine HTTPS-URL kann ebenfalls als `BackupSource` verwendet werden. Sie wird
zuerst in einen lokalen Staging-Bereich geladen, per SHA-256 geprüft und danach
unter diesem Digest im inhaltsadressierten State-Cache gespeichert. Fehlt eine
bekannte Prüfsumme, fragt ein interaktiver Aufruf einmalig nach Vertrauen und
registriert den berechneten Hash lokal. Mit `-NonInteractive` endet derselbe
Fall ohne Download mit `TRUST_REQUIRED`.

## Manifest-Modus

Ein Manifest kann vollstaendig in der Konsole erstellt werden. Der Wizard liest
Pflichtfelder, optionale Felder, Typen, Wertebereiche und Auswahlwerte direkt
aus dem JSON-Schema. Pfade zeigen dabei ihren Host-/Gast-/SQL-Server-Scope,
ihre Bezugsbasis, Default- und Erzeugungsregel sowie bei relativen Hostwerten
eine aufgelöste Vorschau:

```powershell
New-SqlServerLabManifest -Path '.\mein-lab.json'
```

Alternativ steht im Hauptmenue die Aktion `m` zur Verfuegung:

```powershell
Invoke-SqlServerLab -Action Manifest
```

Ein vorhandenes Manifest kann ohne Provisionierung geprueft werden:

```powershell
$result = Test-SqlServerLabManifest -Path '.\mein-lab.json'
$result.Errors
$result.Warnings
```

Fehler verhindern das Speichern beziehungsweise Provisionieren. Warnungen
kennzeichnen unter anderem vorbereitete Schemafelder ohne stabilen Runtimepfad
und riskante SQL-Konfigurationen.

```json
{
  "$schema": "./Schemas/lab-manifest.schema.json",
  "name": "mein-erstes-lab",
  "instances": [
    {
      "id": "primary",
      "version": "2025",
      "provider": "docker",
      "profile": "standard",
      "databases": [
        {
          "name": "AppDB",
          "options": {
            "recoveryModel": "FULL",
            "queryStore": true
          }
        }
      ]
    }
  ]
}
```

Ausführen:

```powershell
$lab = New-SqlServerLab -Manifest '.\mein-lab.json'
```

Vollständige Beispiele liegen unter [`Schemas/`](Schemas/README.md).

## Sample-Datenbanken

Katalogisierte Testdatenbanken mit direkter `.bak`-URL und
`runtimeStatus: executable` werden automatisch über den Sample-Backup-Handler
installiert. Die Integrität sichert der Artifact Resolver: Eine im Katalog
hinterlegte SHA-256 wird erzwungen; fehlt sie, fragt ein interaktiver Lauf
einmalig nach Vertrauen (`interactive-once`), registriert den berechneten Hash
im lokalen Trust Store und legt das Artefakt im inhaltsadressierten Cache ab.
Nicht interaktive Läufe enden ohne bekannten Hash mit `TRUST_REQUIRED`.

Ad-hoc können mehrere Samples pro Instanz gewählt werden – im Menü von
`Invoke-SqlServerLab` über den Schritt `Testdatenbanken` oder direkt:

```powershell
$lab = New-SqlServerLab `
    -Version '2022' `
    -Provider docker `
    -Sample 'adventureworks-2022:lightweight', 'wideworldimporters:standard'
```

Die Zieldatenbanknamen ergeben sich aus den erwarteten Katalog-Outputs.
Kollidierende Ausgaben werden als `SAMPLE_OUTPUT_CONFLICT` abgewiesen. Nach der
Installation verifiziert der Handler die erwartete Datenbank als `ONLINE`
(`DATASET_READY`); eine bereits vorhandene Zieldatenbank blockiert die
Installation gemäß `fail-if-exists`.

Im Manifest bleibt die deklarative Referenz unverändert:

```json
{
  "name": "adventureworks-lab",
  "instances": [
    {
      "id": "primary",
      "version": "2022",
      "provider": "docker",
      "databases": [
        {
          "name": "AdventureWorks2022",
          "sample": {
            "id": "adventureworks-2022",
            "variant": "full"
          }
        }
      ]
    }
  ]
}
```

Archive, Attach-Szenarien und SQL-Skript-Samples werden nicht automatisch in
einen Restore umgedeutet. Sie führen mit einer klaren Fehlermeldung zum
Abbruch.

Der verbindliche Zielvertrag für SQL-Skript-/Bundle-Handler, kontextreiche
Pfadführung und `LAB_GENERATED`-Baselines ist in
[Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md)
dokumentiert; diese Teile folgen in den Wellen 4 und 5.

## Project Adapter

Konsumierende Projekte koppeln sich über einen versionierten Adaptervertrag an
den Lab-Core (`Schemas/project-adapter.schema.json`, Version `0.1-draft`).
Version 0.1 führt ausschließlich relative T-SQL-Entrypoints innerhalb des
Adapter-Roots aus; Pfad-Traversierung, absolute Pfade und unbekannte
Major-Vertragsversionen werden abgelehnt.

```powershell
Test-SqlServerLabAdapter -Path '.\Adapters\Examples\synthetic-demo'

Install-SqlServerLabAdapter `
    -Path '.\Adapters\Examples\synthetic-demo' `
    -RunId $lab.RunId `
    -SaPassword $pw
```

`Install-SqlServerLabAdapter` hat keinen Lifecycle-Seiteneffekt: Container,
Volumes und Run-State bleiben unverändert; es laufen nur die deklarierten
SQL-Entrypoints (`preflight`, `install`, `update`, `validate`, `cleanup`).
Details stehen in [Adapters/README.md](Adapters/README.md), die Roadmap in der
[Project-Adapter-Priorisierung](Documentation/Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md).

## Lifecycle

```powershell
Stop-SqlServerLab -RunId $lab.RunId
Start-SqlServerLab -RunId $lab.RunId
Restart-SqlServerLab -RunId $lab.RunId
Remove-SqlServerLab -RunId $lab.RunId
```

Der Lifecycle verwendet den pro Instanz gespeicherten Provider. Eine Podman-
Instanz wird daher auch dann über Podman verwaltet, wenn Docker zusätzlich
installiert ist. Ein Manifest kann Docker- und Podman-Instanzen in einem Run
kombinieren; Status, Start, Stop und Cleanup arbeiten dafür je ProviderSubRun.

Alle erkannten Lab-Reste bereinigen:

```powershell
Clear-SqlServerLab
```

## Öffentliche Cmdlets

| Cmdlet | Zweck |
|---|---|
| `Invoke-SqlServerLab` | Interaktives Menü |
| `New-SqlServerLabManifest` | Schema-gesteuertes Manifest in der Konsole erstellen |
| `Test-SqlServerLabManifest` | Manifest ohne Provisionierung strukturell und fachlich prüfen |
| `New-SqlServerLab` | Umgebung ad hoc oder per Manifest erstellen |
| `Get-SqlServerLab` | State und Live-Status anzeigen |
| `Start-SqlServerLab` | Gestoppte Umgebung starten |
| `Stop-SqlServerLab` | Laufende Umgebung stoppen |
| `Restart-SqlServerLab` | Stop und Start kombinieren |
| `Remove-SqlServerLab` | Einzelnen Run entfernen |
| `Clear-SqlServerLab` | Lab-Container und/oder State bereinigen |
| `New-SqlServerLabDatabase` | Datenbank erstellen |
| `Restore-SqlServerLabDatabase` | `.bak` aus Datei oder URL wiederherstellen |
| `Invoke-SqlServerLabScript` | T-SQL-Skript ausführen |
| `Test-SqlServerLabPrerequisite` | Provider, RAM, Storage und Ports prüfen |
| `Test-SqlServerLabAdapter` | Project Adapter gegen Schema, Pfadgrenzen und optional einen Run prüfen |
| `Install-SqlServerLabAdapter` | Validierten Adapter-Entrypoint ohne Lifecycle-Seiteneffekt anwenden |

`SqlServerLab.psd1` ist die autoritative Liste der exportierten Funktionen.

## State und lokale Daten

Run-State liegt außerhalb des Git-Checkouts:

- Windows: `%LOCALAPPDATA%\SqlServerLab`
- Linux/macOS: `~/.sql-server-lab`
- Override: Environment Variable `SQL_SERVER_LAB_STATE`

Pro Run entstehen unter anderem:

- `run-state.json`
- `cleanup-plan.json`
- `connection-info.json`
- lokale Secret-Dateien
- `trust/sample-artifacts.json`
- `cache/artifacts/sha256/<sha256>/`
- `cache/quarantine/`
- `runs/<RunId>/manifest.lock.json` bei URL-basierten Artifacts

Diese Dateien enthalten konkrete Laufzeitinformationen und gehören nicht in Git.

## Architekturüberblick

```mermaid
flowchart TD
    A[New-SqlServerLab] --> B[Manifest oder Ad-hoc Parameter]
    B --> C[Version Catalog]
    B --> D[Resource Assessment]
    D --> E[Run State + Cleanup Plan]
    E --> F{Provider}
    F --> G[Docker]
    F --> H[Podman]
    G --> I[SQL Readiness]
    H --> I
    I --> J[Server Configuration]
    J --> K[Create oder Restore Database]
    K --> L[PostProvision Scripts]
    L --> M[connection-info.json]
```

## Quellen der Wahrheit

| Aussage | Autoritative Quelle |
|---|---|
| Exportierte Cmdlets | `SqlServerLab.psd1` |
| Modul-Ladevorgang | `SqlServerLab.psm1` |
| Manifestfelder | `Schemas/lab-manifest.schema.json` |
| Manifest-Eingabe und Fachvalidierung | `Private/ManifestBuilder.ps1` plus `Private/ManifestParser.ps1` |
| SQL-Versionen und Images | `Catalogs/sql-server-versions.json` |
| Sample-Datenbanken | `Catalogs/sample-databases.json` |
| Provider-Funktion | `Providers/*/*.ps1` |
| Provider-Metadaten | `Providers/*/provider.json` |
| State und Übergänge | `Private/StateMachine.ps1` |
| Cleanup-Verhalten | `Private/CleanupEngine.ps1` |
| Aktuelle Einschränkungen | `Documentation/Quality/KNOWN_LIMITATIONS.md` |
| KI-Landkarte | `.ai/repo_map.yaml` |

## Tests und Validierung

Statische Konsistenz- und Readiness-Prüfungen:

```powershell
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-ReadinessContractChecks.ps1
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
.\Tests\Static\Invoke-ArtifactResolverChecks.ps1
.\Tests\Static\Invoke-SampleHandlerChecks.ps1
.\Tests\Static\Invoke-ProjectAdapterChecks.ps1
```

Einzelprovider-Smoke-Test:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

Providerübergreifender Lifecycle-Test für alle lokal erreichbaren Provider:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

Vollständige Matrix aus Docker/Podman, SQL Server 2019/2022/2025 und kontrollierten parallelen Runs:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -FullMatrix `
    -IncludeParallel
```

Nicht erreichbare Provider werden als `SKIP` ausgewiesen. Erreichbare, aber fehlerhafte Provider führen zu `FAIL` und Exitcode `1`. Details zu Testumfang, Parallelitätsvertrag und Remote Runnern stehen in [Tests/README.md](Tests/README.md).

## Repository-Struktur

```text
.ai/             KI-Kontext, Arbeitsregeln und Repo-Map
Adapters/        Project-Adapter-Vertrag und synthetische Beispiele
Catalogs/        SQL-Versionen und Sample-Datenbank-Metadaten
Documentation/   Benutzer-, Architektur-, Qualitäts- und Planungsdokumentation
Private/         interne Modulbausteine
Providers/       Docker, Podman und Hyper-V-Lifecycle
Public/          exportierte Cmdlets
Schemas/         JSON-Schemas und ausführbare Beispiele
Tests/           statische Prüfungen sowie Lifecycle-, Matrix- und Paralleltests
_QuellRepo/      unveränderte Quell-Snapshots anderer Repositories
```

## Weiterführende Dokumentation

- [Getting Started](Documentation/User/Getting_Started.md)
- [Dokumentationsübersicht](Documentation/README.md)
- [Bekannte Grenzen](Documentation/Quality/KNOWN_LIMITATIONS.md)
- [Manifest-Schemas und Beispiele](Schemas/README.md)
- [Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md)
- [Gemischter Container-Provider-Lifecycle](Documentation/Architecture/MIXED_PROVIDER_LIFECYCLE.md)
- [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](Documentation/Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
- [Öffentliche Cmdlets](Public/README.md)
- [Project Adapter](Adapters/README.md)
- [Provider](Providers/README.md)
- [Tests](Tests/README.md)
- [Podman unter Windows](Documentation/HowTo/PODMAN_WINDOWS_NETWORKING.md)
- [KI-Projektkontext](.ai/PROJECT_CONTEXT.md)
- [Maschinenlesbare Repo-Map](.ai/repo_map.yaml)
- [Beitragsregeln](CONTRIBUTING.md)

## CI/CD-Abgrenzung

Lab-Provisionierung bleibt lokal beziehungsweise auf ausdrücklich dafür vorgesehenen Self-hosted Runnern. Runtime-Workflows verwenden die Labels `SQL_Lab` plus `Docker` oder `Podman`; generische Self-hosted Runner werden nicht verwendet. GitHub-hosted Runner sind nur für nicht mutierende, hostunabhängige Prüfungen vorgesehen.
