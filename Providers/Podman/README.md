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
- Autostart über `--restart unless-stopped` und das Lab-Label; auf nativem Linux
  werden `podman-restart.service` und systemd-Linger aktiviert, unter Windows startet ein verwalteter
  Benutzer-Anmeldeauftrag zuerst die Podman Machine
