# Providers/Podman/ – Podman-Provider

Die [SA-Passwortpolicy-Vorbereitung](../../Documentation/Architecture/SA_PASSWORD_POLICY.md)
seedet ein bewusstes Customminimum nur in eine frische eigene kurzlebige
SQL2025-CU-Systemvolume vor Standardlaunch. Bestehende Config/Volumes bleiben
gesperrt. Ein eigener Podman-Erststart mit SQL2025-CU9 und Mindestlaenge drei,
SA-Anmeldung, Restart/Configerhalt und Cleanup ist bestanden; andere CUs und
Mindestlaengen bleiben ohne native Abnahme.

Container via Podman. Der allgemeine Provider unterstützt rootless Betrieb;
Der isolierte Standardmodus für SQL Server 2019/2022/2025 External Runtimes
benötigt rootful Linux mit cgroup v1. Für SQL 2025 existiert zusätzlich die
unten beschriebene explizite shared-user-v2-Variante.

## Dateien

- `provider.json` – Konfiguration (identisch zu Docker)
- `PodmanProvider.ps1` – Provider-Implementierung

## Besonderheiten

- Kein Daemon noetig (rootless)
- Windows/Mac: `podman machine` muss laufen
- stderr-Warnings werden als Strings konvertiert (ErrorRecord-Fix)
- Container-ID per Hex-Regex extrahiert
- sqlcmd-Healthcheck bindet das Passwort unverändert als ein Shellargument, auch bei führendem Minus und beim Container-Reconcile
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

## Explizite External-Languages-Variante für cgroup v2

SQL Server 2025 CU9 kann unter rootful Docker und Podman ausdrücklich mit
shared-user-v2-Varianten ausgewählt werden. Dabei entfallen Launchpad-Sandbox-
und Worker-Isolation; der isolierte cgroup-v1-Modus bleibt Standard.
[Auswahl, Voraussetzungen und Nachweisgrenzen](../../Documentation/User/EXTERNAL_LANGUAGES_CGROUP_V2.md).
