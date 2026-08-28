# Providers/Podman/ – Podman-Provider

Container via Podman. Der allgemeine Provider unterstützt rootless Betrieb;
SQL Server 2022 External Runtimes benötigen rootful Linux mit cgroup v1.

## Dateien

- `provider.json` – Konfiguration (identisch zu Docker)
- `PodmanProvider.ps1` – Provider-Implementierung

## Besonderheiten

- Kein Daemon noetig (rootless)
- Windows/Mac: `podman machine` muss laufen
- stderr-Warnings werden als Strings konvertiert (ErrorRecord-Fix)
- Container-ID per Hex-Regex extrahiert
- SQL-internes Memory-Limit mit 20 Prozent Headroom unterhalb des
  Containerlimits sowie TLS-vertraulicher Healthcheck
- Autostart über `--restart unless-stopped` und das Lab-Label; auf nativem Linux
  werden `podman-restart.service` und systemd-Linger aktiviert, unter Windows startet ein verwalteter
  Benutzer-Anmeldeauftrag zuerst die Podman Machine
- Python, R und Java über dasselbe digestgebundene Derived-Image-Rezept wie
  Docker, aber mit eigenem Buildreceipt und eigener Native Acceptance
- begrenzte Kompatibilitätskorrektur für den von Ubuntu 22.04 ausgelieferten
  Podman-3.4.4-/CNI-0.9.1-Vertrag; andere CNI-Versionen werden nicht umgeschrieben
- kontrolliertes Stop/Start mit begrenztem Retry ausschließlich für die
  bekannte sofortige Portfreigabe-Race von Podman 3.4
