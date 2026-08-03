# Providers/ – Container- und VM-Provider

Ein implementierter Provider besitzt mindestens:

- `provider.json` mit Name, Anforderungen und Implementierungsdatei;
- eine vorhandene `.ps1`-Implementierung;
- Verfügbarkeits-, Provisionierungs-, Status- und Lifecyclefunktionen;
- einen eigenen Native-Smoke-Test-Lauf.

Ein Verzeichnis allein registriert keinen implementierten Provider.

## Providerstatus

| Provider | Runtime-Status | Runtime-Check | Implementierung |
|---|---|---|---|
| [Docker](Docker/) | implementiert | `docker info` | `Docker/DockerProvider.ps1` |
| [Podman](Podman/) | implementiert | `podman info` | `Podman/PodmanProvider.ps1` |
| [Hyper-V](HyperV/) | Lifecycle- und Image-Registry-Grundlage | `Get-VMHost` | `HyperV/HyperVProvider.ps1`; noch kein unattended OS-/SQL-Build |

Die implementierte Hyper-V-Grundlage umfasst eine immutable Image-Registry,
deterministische Baseline-Auswahl, Generation 2, Secure Boot,
verifizierte read-only Parent-VHDX, Differencing Child, Status, Start, Stop,
PowerShell Direct und scopegebundenen Cleanup. Der weiterführende Zielvertrag
für OS-/SQL-Provisionierung, Drives, Network Intents, Software, Reconcile und
Artifact Refresh steht in
[HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md](../Documentation/Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md).

## Provider-Interface

Die Containerprovider folgen derzeit dieser Namenskonvention:

- `Test-<Name>Available`
- `New-<Name>Instance`
- `Get-<Name>InstanceStatus`
- `Start-<Name>Instance`
- `Stop-<Name>Instance`
- `Remove-<Name>Instance`
- providerbezogene Auflistungs- und Cleanup-Hilfen

Der Modul-Loader lädt ausschließlich `.ps1`-Dateien aus Providerverzeichnissen. Eine `.psm1`-Datei würde einen eigenen Nested-Module-Scope erzeugen und ist für den aktuellen Loadervertrag nicht vorgesehen.

## Providerbindung eines Runs

`New-SqlServerLab` speichert den Provider jeder Instanz in `connection-info.json`.

`Get-SqlServerLab`, `Start-SqlServerLab` und `Stop-SqlServerLab` verwenden
diese gespeicherte Information. Dadurch wird eine Podman-Instanz nicht
versehentlich über Docker verwaltet, wenn beide Runtimes installiert sind.

## Gemischte Provider

Ein Run darf Docker- und Podman-Instanzen kombinieren. Jeder Provider bildet
einen eigenen `ProviderSubRun` mit separatem State und Cleanup-Zuordnung. Die
Runtimes werden nie gegeneinander ausgetauscht oder zufällig gewählt.

Der genaue Umfang sowie Start-Rollback und Recovery stehen im
[Gemischten Container-Provider-Lifecycle](../Documentation/Architecture/MIXED_PROVIDER_LIFECYCLE.md).

## Auto-Erkennung

- `Invoke-SqlServerLab` kann verfügbare Container-Runtimes erkennen.
- Der Integration-Smoke-Test erkennt implementierte Provider anhand einer existierenden `provider.json` und der darin referenzierten Implementierungsdatei.
- `-Provider auto` wählt für den mutierenden Test genau eine Runtime: Docker vor Podman.
- Ein Docker-Test gilt nicht als Podman-Nachweis.

## Provider ändern oder ergänzen

Gemeinsam zu pflegen sind:

1. Providerimplementierung;
2. `provider.json`;
3. Provider-README;
4. Modul- und Lifecyclevertrag;
5. Root-README und Known Limitations;
6. `.ai/repo_map.yaml`;
7. statische Prüfung;
8. eigener Native-Smoke-Test.

Die Hyper-V-Lifecycle-Grundlage darf nicht als SQL-fertiger Hyper-V-Provider
bezeichnet werden, solange OS-/SQL-Provisionierung und SQL Readiness fehlen.
