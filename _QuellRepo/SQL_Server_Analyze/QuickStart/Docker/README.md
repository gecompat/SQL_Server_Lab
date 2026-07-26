# Docker QuickStart

Dieser Bereich stellt eine eigenständige Docker-Testumgebung für
`SQL_Server_Analyze` bereit. Er ist für Anwender vorgesehen, die SQL Server 2019,
2022 und/oder 2025 lokal starten und das Framework automatisch installieren
möchten.

Der QuickStart ist vom umfangreicheren Verzeichnis `Lab/` getrennt:

- keine LAB-Run-IDs oder Evidence-Gates;
- keine Abhängigkeit von LAB-Konfigurationen;
- keine gemeinsam verwendeten State-, Secret- oder Datenpfade;
- nur der kanonische Frameworkinstaller unter `Code/Install` wird wiederverwendet.

## Ein Einstiegspunkt

PowerShell 7 im Repository-Root öffnen und ausführen:

```powershell
./QuickStart/Docker/Setup.ps1
```

`Setup.ps1` führt beim ersten Aufruf durch die Einrichtung. Bei späteren Aufrufen
zeigt es ein Menü für Start, Status, Stop und Remove/Uninstall.

Direkte Aktionen sind ebenfalls möglich:

```powershell
./QuickStart/Docker/Setup.ps1 -Action Start
./QuickStart/Docker/Setup.ps1 -Action Status
./QuickStart/Docker/Setup.ps1 -Action Stop
./QuickStart/Docker/Setup.ps1 -Action Remove
```

Für die vollständige Deinstallation der verwalteten QuickStart-Umgebung steht
zusätzlich ein eigener Einstiegspunkt bereit:

```powershell
./QuickStart/Docker/Uninstall.ps1
```

`Uninstall.ps1` verwendet dieselbe marker- und scope-gebundene Remove-Logik wie
`Setup.ps1 -Action Remove`.

## Was Setup abfragt

Das Setup fragt interaktiv nach:

- SQL-Server-Versionen: 2019, 2022 und/oder 2025;
- Ressourcenprofil: Compact, Standard oder Performance;
- Speicherlayout;
- sicheren, leeren Zielpfaden;
- optionaler Slow-I/O-Simulation;
- freien Hostports;
- SA-Passwort für die ausschließlich synthetischen Testinstanzen;
- Aktivierung des SQL Server Agents für Infrastrukturtests;
- automatischer Frameworkinstallation in `LabAnalyze`.

Danach erzeugt es lokal `QuickStart/Docker/.env`, bereitet ausschließlich die
bestätigten leeren Zielpfade vor und startet die gewählten Container sequenziell.

## Lokale `.env`

Die erzeugte `.env` enthält das SA-Passwort im Klartext, weil das SQL-Server-
Container-Image `MSSQL_SA_PASSWORD` als Environment-Variable erwartet. Die Datei
ist durch die Repository-`.gitignore` ausgeschlossen und darf nicht weitergegeben
oder committed werden.

`.env.example` enthält nur synthetische Platzhalter. Die Beispieldatei ist nicht
für einen realen Start vorgesehen. Eine nachträgliche Änderung des Passworts in
`.env` ändert nicht das Passwort bereits initialisierter SQL-Datenverzeichnisse.
Für einen Passwortwechsel wird die Umgebung einschließlich der zugeordneten
Docker-Volumes und markierten Daten über `Uninstall.ps1` entfernt und anschließend
mit `Setup.ps1` neu erstellt.

## Schutz vor Überschreiben

Vor jeder Mutation prüft das Setup:

- Pfade müssen absolut und lokal sein;
- Laufwerkswurzeln und Betriebssystempfade sind gesperrt;
- Repository, QuickStart-Quellverzeichnis und Benutzerprofilwurzel sind gesperrt;
- UNC-Pfade, Junctions und symbolische Links sind gesperrt;
- jeder neue Zielpfad muss fehlen oder vollständig leer sein;
- getrennte Lab-, Daten- und Log-Wurzeln dürfen sich nicht überlappen;
- Ports müssen frei und untereinander eindeutig sein.

In jeder verwalteten Wurzel wird ein Scope-Marker angelegt. Start, Stop und
Remove akzeptieren nur Pfade, deren Marker exakt zur lokalen `.env` passt.
Docker-Container, Netzwerke und Docker-Volumes werden ebenfalls über Projekt-,
Owner- und Scope-Labels geprüft.

Nicht verwendet werden:

- `docker system prune`;
- globale Volume- oder Image-Löschungen;
- Wildcard-Löschungen;
- namensbasierte Suche und Entfernung fremder Container.

## Speicherlayouts

Unter Windows berücksichtigt die Standardpfadermittlung ausschließlich
bereitgestellte lokale Laufwerke vom Typ `Fixed`. UNC-Pfade, gemappte
Netzwerklaufwerke und Wechseldatenträger werden nicht vorgeschlagen. Als Standard
wird das lokale feste Laufwerk mit dem größten aktuell verfügbaren freien
Speicher verwendet.

### Single Root

Geeignet für Systeme mit nur einem Laufwerk. Ein einziger leerer Lab-Pfad wird
gewählt; Setup erzeugt darunter:

```text
<LabRoot>/
  control/installer/
  data/2019|2022|2025/
  log/2019|2022|2025/
  backup/2019|2022|2025/
```

Ein Systemlaufwerk ist zulässig, solange ein dedizierter, nicht geschützter und
leerer Unterordner verwendet wird. Betriebssystemverzeichnisse, Programm-
verzeichnisse, Laufwerkswurzeln und das Repository selbst werden abgelehnt.

### Separate Data/Log Roots

Für Systeme mit mehreren Datenträgern können drei leere, nicht überlappende
Wurzeln gewählt werden:

- Steuerung und Backups;
- Datendateien;
- Logdateien.

Es werden keine bestehenden Ordnerinhalte übernommen oder überschrieben.

### Docker Desktop auf Windows

Docker Desktop betreibt Linux-Container innerhalb einer Linux-VM. Für jede
SQL-Version wird deshalb genau ein projektgebundenes Docker-Volume auf das
vollständige Verzeichnis `/var/opt/mssql` gemountet. Damit bleiben Daten,
Transaktionslogs, Systemmetadaten und der SQL-Secrets-Bereich gemeinsam erhalten.
Direkte Windows-Bind-Mounts werden für aktive SQL-Dateien nicht verwendet.

Ein neues leeres Docker-Volume wird beim ersten Mount mit dem vorhandenen Inhalt
und den Besitzinformationen des Image-Verzeichnisses befüllt. Dadurch können die
SQL-Container wieder mit dem vom Microsoft-Image vorgesehenen Non-root-Benutzer
laufen. Der frühere Docker-Desktop-Kompatibilitätsmodus mit Root-Benutzer und
getrennten Data-/Log-Volumes wird nicht mehr verwendet.

Die ausgewählten Hostpfade bleiben für Scope-Marker, Steuerungsdateien, Installer
und Backups zuständig. Die Instanz-Volumes tragen denselben Owner- und Scope-Marker
wie Container und Netzwerk. Eine vollständige Deinstallation entfernt nach
Bestätigung alle Volumes dieses Scopes, einschließlich Volumes aus einem älteren
getrennten Data-/Log-Modell.

Auf einer nativen Linux-Docker-Engine werden weiterhin die ausgewählten lokalen
Daten- und Logpfade als Bind-Mounts verwendet. Dadurch bleibt die dedizierte
Blockgerätezuordnung für Linux-native Slow-I/O-Tests verfügbar.

## Ressourcenprofile

| Profil | Containerlimit je Instanz | SQL-Memory-Limit | CPU-Limit |
|---|---:|---:|---:|
| Compact | 3 GiB | 2 GiB | 2 CPUs |
| Standard | 8 GiB | 6 GiB | 4 CPUs |
| Performance | 16 GiB | 12 GiB | 8 CPUs |

Wenn die Summe der gewählten Instanzen mehr als ungefähr 70 Prozent des
Hostspeichers reservieren würde, verlangt Setup eine zusätzliche Bestätigung.
Container werden sequenziell gepullt, gestartet, auf `healthy` geprüft und erst
danach mit dem Framework versehen.

## Slow-I/O

Eine belastbare Block-I/O-Drosselung wird nicht für Docker Desktop auf Windows
behauptet. Die Abstraktion von WSL2/Docker Desktop erlaubt keine portable und
sichere Zuordnung eines Windows-Bind-Mounts zu einem Linux-Blockgerät.

Slow-I/O ist deshalb nur verfügbar, wenn der QuickStart mit PowerShell 7 direkt
auf einer Linux Docker Engine ausgeführt wird. Das kann eine Linux-VM unter
Hyper-V sein. Voraussetzungen:

- Single-Root-Layout;
- dediziertes, bereits gemountetes und leeres Blockgerät;
- `findmnt`, `lsblk` und `readlink`;
- exakte Bestätigung `SLOWIO`.

Setup prüft, ob der Lab-Mount tatsächlich auf dem angegebenen Gerät liegt. Die
Compose-Erweiterung drosselt anschließend Lese- und Schreibrate über
`blkio_config`. Für eine Hyper-V-Variante sollte das Blockgerät eine eigene
virtuelle Disk sein, die ausschließlich diesem Lab dient.

SQL Server 2019 und neuer läuft im Linux-Container standardmäßig ohne Root-Rechte.
Deshalb muss die initiale Einrichtung unter Linux mit `sudo pwsh` ausgeführt
werden. Setup setzt nur auf den zuvor geprüften leeren und markierten Lab-Wurzeln
die für die Root-Gruppe erforderlichen Schreibrechte.

## Netzwerk und Ports

Die SQL-Ports werden standardmäßig nur an `127.0.0.1` gebunden:

- SQL Server 2019: `14331`;
- SQL Server 2022: `14332`;
- SQL Server 2025: `14335`.

Belegte Ports werden abgelehnt und können während Setup ersetzt werden. Das
projektgebundene Compose-Netzwerk verwendet einen normalen Bridge-Treiber und
trägt den QuickStart-Scope als Label. Die Erreichbarkeit bleibt durch die
explizite Bindung an `127.0.0.1` auf den lokalen Host begrenzt.

Der Healthcheck verwendet eine explizite TCP-Verbindung auf
`tcp:127.0.0.1,1433`, einen definierten Login- und Abfragetimeout und das im Image
vorhandene `sqlcmd`. Nach dem Healthcheck prüft der QuickStart sowohl die
Docker-Portbindung als auch eine TCP-Verbindung vom Host. Ein Container gilt erst
danach als von SSMS erreichbar.

## Frameworkinstallation

Setup erzeugt den eigenständigen Installer aus den kanonischen Dateien über:

```text
Code/Install/Build-StandaloneInstaller.ps1
```

Anschließend wird pro Instanz sequenziell:

1. die Datenbank `LabAnalyze` mit `SQL_Latin1_General_CP1_CS_AS` erzeugt, falls sie
   noch fehlt;
2. der vollständige Installer ausgeführt;
3. das Vorhandensein des Schemas `monitor` als `FRAMEWORK_READY` geprüft.

Das SA-Passwort wird für die Installation nicht in Kommandoargumente geschrieben.
`sqlcmd` verwendet innerhalb des Containers die bereits vorhandene
`MSSQL_SA_PASSWORD`-Variable.

## Hyper-V

Für normale Docker-Desktop-Tests wird `Setup.ps1` direkt unter Windows verwendet.
Für Linux-native und Slow-I/O-Varianten wird eine Linux-VM unter Hyper-V
vorbereitet, Docker Engine und PowerShell 7 in der VM installiert und dasselbe
Repository dort ausgecheckt. Innerhalb der VM bleibt der Einstieg identisch:

```powershell
./QuickStart/Docker/Setup.ps1
```

Der QuickStart erstellt bewusst keine Hyper-V-VM und verändert keine
Host-Netzwerke. VM-Provisionierung und Hostadministration bleiben getrennte,
explizite Schritte.

## Wechsel vom früheren Docker-Desktop-Speichermodell

Frühere QuickStart-Stände verwendeten unter Docker Desktop getrennte Volumes für
`/var/opt/mssql/data` und `/var/opt/mssql/log` und starteten die Container als
Root. Diese Volumes dürfen nicht in das neue vollständige Instanz-Volume
übernommen werden.

Vor dem ersten Start mit dem neuen Modell ist die bisherige Umgebung vollständig
zu entfernen:

```powershell
./QuickStart/Docker/Uninstall.ps1
./QuickStart/Docker/Setup.ps1
```

Bei `Uninstall.ps1` müssen sowohl die Entfernung des Compose-Projekts als auch die
Entfernung der Docker-Volumes und markierten Datenpfade bestätigt werden. Die
Deinstallation ermittelt alle Owner- und Scope-geprüften Volumes des Projekts und
entfernt dadurch auch ältere getrennte Data-/Log-Volumes. Docker-Images und fremde
Projekte bleiben unangetastet.

## Entfernen und Deinstallieren

```powershell
./QuickStart/Docker/Uninstall.ps1
```

Alternativ:

```powershell
./QuickStart/Docker/Setup.ps1 -Action Remove
```

Die erste Bestätigung entfernt ausschließlich Container und Netzwerk des in
`.env` gespeicherten Compose-Projekts. Bei der zweiten Bestätigung werden alle
Owner- und Scope-geprüften Docker-Volumes des Projekts, die markierten Hostpfade
und die lokale `.env` gelöscht. Docker-Images und andere Projekte bleiben
unangetastet.
