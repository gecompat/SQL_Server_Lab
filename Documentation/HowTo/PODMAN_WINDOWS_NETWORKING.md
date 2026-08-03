# Podman unter Windows: Localhost-Portweiterleitung

## Zweck

`SQL_Server_Lab` verwendet fuer Container-Provider standardmaessig `127.0.0.1` und einen dynamisch vergebenen Hostport. Unter Podman auf Windows laeuft die Podman-Machine typischerweise in WSL. Je nach WSL-Netzwerkmodus kann Podman eine Portfreigabe wie `0.0.0.0:14330->1433/tcp` anzeigen, obwohl der Port vom Windows-Host ueber `127.0.0.1:14330` nicht erreichbar ist.

Das Framework erkennt diesen Sonderfall aktiv: Wenn der SQL-Server-Container intern bereits bereit ist, aber `localhost` nicht funktioniert, bricht die Bereitschaftspruefung frueh mit einem konkreten Hinweis ab. Dadurch muss nicht der gesamte allgemeine SQL-Timeout abgewartet werden.

## Empfohlene Konfiguration

Datei `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Danach WSL und die Podman-Machine vollstaendig neu starten:

```powershell
podman machine stop podman-machine-default
wsl --shutdown
podman machine start podman-machine-default
```

Nach einem Hostneustart oder einer bewusst gestoppten Machine wird die
Standard-Machine manuell so gestartet:

```powershell
podman machine start podman-machine-default
podman info
```

Existiert die Standard-Machine noch nicht, muss sie einmalig angelegt werden:

```powershell
podman machine init podman-machine-default
podman machine start podman-machine-default
```

Anschliessend kann die Weiterleitung geprueft werden:

```powershell
Test-NetConnection -ComputerName 127.0.0.1 -Port 14330
```

Der Port muss dabei dem tatsaechlich veroeffentlichten Port des Containers entsprechen.

## User-Mode Networking

`podman machine set --user-mode-networking=true` kann andere WSL-, VPN- oder Routingprobleme loesen. Es stellt die Localhost-Portweiterleitung jedoch nicht auf jedem Windows-Host her. Fuer den hier beschriebenen Fehler ist `networkingMode=mirrored` die bevorzugte Konfiguration.

## Diagnose ueber die Podman-Machine-IP

Die IPv4-Adresse des WSL-Interfaces `eth0` kann fuer Diagnosezwecke ermittelt werden:

```powershell
podman machine ssh "ip -4 -o addr show dev eth0 scope global"
```

Beispiel:

```text
2: eth0 inet 172.23.234.180/20 ...
```

Ein Test gegen diese Adresse kann zeigen, dass SQL Server und die Portfreigabe innerhalb der Podman-Machine funktionieren:

```powershell
Test-NetConnection -ComputerName 172.23.234.180 -Port 14330
```

Diese Adresse ist kein stabiler Connection-String. Sie kann sich nach einem WSL- oder Hostneustart aendern. Ein eigenes statisches Podman-Containernetzwerk stabilisiert nicht automatisch die Windows-zu-WSL-Adresse und ersetzt daher die Localhost-Konfiguration nicht.

## Framework-Verhalten

Die Bereitschaftspruefung arbeitet mit kurzen Polling-Intervallen und beendet sich sofort bei Erfolg. Bei Podman unter Windows wird nach wenigen Sekunden zusaetzlich geprueft, ob:

1. ein Podman-Container den betroffenen Port veroeffentlicht;
2. dessen SQL-Server-Log bereits `SQL Server is now ready for client connections` enthaelt;
3. der Zugriff ueber `127.0.0.1` trotzdem fehlschlaegt.

In diesem Fall zeigt das Framework die konkrete `.wslconfig`-Konfiguration und die notwendigen Neustartbefehle an.

Nach `Start-SqlServerLab` und `Restart-SqlServerLab` wartet das Framework ausserdem auf alle im Run gespeicherten Benutzerdatenbanken. Dadurch wird ein kurzer Zeitraum abgefangen, in dem `master` bereits erreichbar ist, eine Benutzerdatenbank aber noch nicht vollstaendig online ist.
