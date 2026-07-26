# Providers/Podman/ – Podman-Provider

Rootless Container via Podman. CLI weitgehend Docker-kompatibel.

## Dateien

- `provider.json` – Konfiguration (identisch zu Docker)
- `PodmanProvider.ps1` – Provider-Implementierung

## Besonderheiten

- Kein Daemon noetig (rootless)
- Windows/Mac: `podman machine` muss laufen
- stderr-Warnings werden als Strings konvertiert (ErrorRecord-Fix)
- Container-ID per Hex-Regex extrahiert
