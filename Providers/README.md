# Providers/ – Container- und VM-Provider

Jedes Unterverzeichnis ist ein eigenstaendiger Provider mit:
- `provider.json` – Konfiguration (Ports, Labels, Requirements)
- `<Name>Provider.ps1` – Implementierung des Provider-Interface

## Registrierte Provider

| Provider | Status | Runtime-Check |
|---|---|---|
| [Docker](Docker/) | ✅ Produktiv | `docker` CLI |
| [Podman](Podman/) | ✅ Produktiv | `podman` CLI |
| [HyperV](HyperV/) | ⬜ Geplant | `Get-VM` Cmdlet |

## Provider-Interface (Konvention)

Jeder Provider implementiert:
- `Test-<Name>Available` → PSCustomObject mit Available, Version, Message
- `New-<Name>Instance` → Container/VM erstellen
- `Get-<Name>InstanceStatus` → Running/Healthy pruefen
- `Start-<Name>Instance` → Container/VM starten
- `Stop-<Name>Instance` → Container/VM stoppen
- `Remove-<Name>Instance` → Container/VM entfernen (Scope-validiert)
- `Get-<Name>LabContainers` → Alle Lab-Container auflisten

## Auto-Discovery

Der Smoke-Test und `Invoke-SqlServerLab` erkennen Provider automatisch
anhand der Unterverzeichnisse in diesem Ordner.
