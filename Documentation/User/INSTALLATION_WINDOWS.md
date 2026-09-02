# Installation für AnwenderInnen unter Windows

| Merkmal | Wert |
|---|---|
| Zielgruppe | AnwenderInnen von `SQL_Server_Lab` |
| Plattform | Windows 10/11 mit Linux-Containern |
| Provider | Docker **oder** Podman |
| Mindestversion PowerShell | 7.2 |

## 1. Geltungsbereich

Diese Anleitung richtet einen Windows-Rechner für die Nutzung des Labs ein.
Für den normalen Betrieb wird genau eine Container-Runtime benötigt: Docker
**oder** Podman. Beide Runtimes sind nur für Entwicklung und den gemischten
Provider-Test erforderlich.

GitHub Actions und Self-hosted Runner gehören nicht zur Anwenderinstallation.
Hyper-V ist dagegen optional verfügbar, wenn Windows-SQL-Images oder
Windows-Lab-VMs verwendet werden sollen.

ISO-, VHDX- und SQL-Installationsmedien werden nicht unterhalb des Repository
abgelegt. Die kanonische, automatisch erzeugbare Struktur steht unter
[Externer Media Root](../HowTo/MEDIA_ROOT_LAYOUT.md).

Nach dem Modulimport führt `Invoke-SqlServerLab -Action Setup` durch die
gemeinsame Einrichtung von `Lab_Base` und einer oder mehreren
`Lab_Data`-Locations. Der Assistent speichert die Auswahl für neue Prozesse,
fragt bei Wiederholungen nur fehlende oder ungültige Werte ab und überschreibt
keine vorhandenen Dateien.

## 2. Benötigte Komponenten

| Komponente | Erforderlich | Zweck | Offizielle Quelle |
|---|---|---|---|
| PowerShell 7.2 oder neuer | ja | Modul und Cmdlets ausführen | [PowerShell unter Windows installieren](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows) |
| Docker Desktop **oder** Podman Desktop | ja | SQL-Server-Linux-Container ausführen | [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) / [Podman Desktop](https://podman-desktop.io/docs/installation/windows-install) |
| WSL 2 und Hardwarevirtualisierung | bei Windows-Containerruntimes | Linux-VM für Docker beziehungsweise Podman | [WSL installieren](https://learn.microsoft.com/en-us/windows/wsl/install) |
| `sqlcmd` | ja für Datenbank-, Restore-, Skript- und vollständige Smoke-Test-Pfade | SQL Server prüfen und T-SQL ausführen | [sqlcmd herunterladen und installieren](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install) |
| Git | empfohlen | Repository klonen und aktualisieren | [Git for Windows](https://git-scm.com/install/windows) |
| Hyper-V-Plattform und Verwaltungstools | für Windows-VMs | lokale Hyper-V-Images und VMConnect | [Hyper-V installieren](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/Install-Hyper-V) |

Zusätzlich benötigt ein kleines Lab laut Projektvertrag mindestens 4 GB freien
RAM und 5 GB freien Speicher. Für mehrere parallele SQL-Server-Container ist
entsprechend mehr einzuplanen. Der Host benötigt ausgehenden HTTPS-Zugriff auf
GitHub, die Microsoft Container Registry `mcr.microsoft.com` und die jeweils
verwendeten Hersteller-Paketquellen.

Docker Desktop ist für unterstützte Windows-Clientversionen vorgesehen, nicht
für Windows Server. Vor einer geschäftlichen Nutzung sind außerdem die aktuellen
[Docker-Desktop-Lizenzbedingungen](https://docs.docker.com/subscription/desktop-license/)
zu prüfen.

## Hyper-V für Windows-SQL-Images

Beim ersten Aufruf von `Invoke-SqlServerLab.ps1 -Action Image` erkennt das Lab
fehlende Hyper-V-Komponenten und bietet deren Installation an. Nach der
Bestätigung installiert es auf Windows Server die Rolle `Hyper-V` samt
Management Tools; auf Windows 10/11 die Komponente `Microsoft-Hyper-V-All`.
Die Installation benötigt ein Administrator-Terminal und kann einen Neustart
erfordern. Der Neustart wird **nicht** automatisch ausgelöst, damit ein
laufender Runner nicht unterbrochen wird.

Nach einem geforderten Neustart den Image-Einstieg erneut starten. Das
PowerShell-Modul und die Verwaltungstools stehen dann zur Verfügung. Auf
Windows Server Core installiert Microsoft dabei nur die PowerShell-Tools; für
VMConnect wird ein Desktop-Host mit Hyper-V-Verwaltungstools benötigt.

## 3. Schritt 1 – Hardwarevirtualisierung und WSL 2 vorbereiten

1. Im BIOS/UEFI die CPU-Virtualisierung aktivieren. Die Bezeichnung hängt vom
   Hersteller ab, zum Beispiel `Intel VT-x`, `Intel Virtualization Technology`
   oder `AMD-V`.
2. PowerShell oder Windows Terminal einmal als Administrator öffnen.
3. WSL ohne zusätzliche allgemeine Linux-Distribution installieren oder
   aktualisieren:

```powershell
wsl --update
wsl --install --no-distribution
```

4. Windows neu starten, wenn der Befehl dazu auffordert.
5. Den Zustand prüfen:

```powershell
wsl --version
wsl --status
```

Podman Desktop erzeugt später seine eigene Podman Machine. Eine zusätzliche
Ubuntu-Installation ist für diesen Lab-Pfad nicht erforderlich.

## 4. Schritt 2 – PowerShell 7 installieren

PowerShell 7 läuft parallel zur eingebauten Windows PowerShell 5.1. Die
Installation über WinGet erfolgt in einem normalen Terminal:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Danach ein neues Terminal mit `pwsh` öffnen und prüfen:

```powershell
$PSVersionTable.PSVersion
```

Erforderlich ist PowerShell `7.2` oder eine insgesamt neuere Version.
Wenn WinGet nicht verfügbar ist, enthält die offizielle PowerShell-Seite auch
MSI-Downloads für x64 und ARM64.

## 5. Schritt 3 – Git installieren

Git ist erforderlich, wenn das Repository geklont und später einfach
aktualisiert werden soll:

```powershell
winget install --id Git.Git -e --source winget
```

Ein neues Terminal öffnen und prüfen:

```powershell
git --version
```

Wer das Repository stattdessen als ZIP-Datei von GitHub herunterlädt, benötigt
Git für die reine Lab-Nutzung nicht. Aktualisierungen müssen dann manuell durch
ein neues Archiv übernommen werden.

## 6. Schritt 4 – Eine Container-Runtime auswählen

Nur eine der folgenden Varianten installieren.

### Variante A – Docker Desktop

1. Den aktuellen Installer von der offiziellen
   [Docker-Desktop-Seite](https://docs.docker.com/desktop/setup/install/windows-install/)
   herunterladen.
2. Für einen normalen Einzelbenutzer-Rechner die dort empfohlene
   Per-User-Installation wählen.
3. Den WSL-2-Backend und Linux-Container verwenden.
4. Docker Desktop über das Startmenü starten und warten, bis die Engine bereit
   ist.
5. In einem neuen `pwsh`-Terminal prüfen:

```powershell
docker version
docker info
```

`docker info` muss ohne Verbindungsfehler enden. Die bloße Existenz von
`docker.exe` genügt nicht; Docker Desktop beziehungsweise die Docker Engine muss
laufen.

### Variante B – Podman Desktop

1. Podman Desktop von der offiziellen
   [Windows-Installationsseite](https://podman-desktop.io/docs/installation/windows-install)
   installieren oder WinGet verwenden:

```powershell
winget install RedHat.Podman-Desktop
```

2. Podman Desktop starten und im Onboarding den WSL-2-Provider auswählen.
3. Im Onboarding eine Podman Machine erstellen. Alternativ kann die
   Standard-Machine im Terminal angelegt werden:

```powershell
podman machine init podman-machine-default
```

4. Die Machine ausdrücklich starten:

```powershell
podman machine start podman-machine-default
```

5. Zustand und Runtime prüfen:

```powershell
podman machine list
podman info
```

Unter Windows laufen Podman-Container in dieser Machine. Nach einem Neustart
oder wenn die Machine gestoppt wurde, reicht deshalb nicht allein ein
installiertes `podman.exe`. Die Standard-Machine muss wieder gestartet werden:

```powershell
podman machine start podman-machine-default
```

Existiert noch keine Machine, ist einmalig `podman machine init
podman-machine-default` auszuführen. Die offiziellen Details stehen in der
[Podman-Machine-Dokumentation](https://docs.podman.io/en/latest/markdown/podman-machine.1.html).

## 7. Schritt 5 – Podman-Localhost-Netzwerk konfigurieren

Dieser Schritt gilt nur für Podman unter Windows. `SQL_Server_Lab` veröffentlicht
SQL Server auf `127.0.0.1` und einem dynamischen Hostport. Für eine zuverlässige
Weiterleitung wird WSL Mirrored Networking empfohlen.

1. Die Datei `%USERPROFILE%\.wslconfig` erstellen oder ergänzen:

```ini
[wsl2]
networkingMode=mirrored
```

2. Podman und WSL neu starten:

```powershell
podman machine stop podman-machine-default
wsl --shutdown
podman machine start podman-machine-default
```

3. Erneut prüfen:

```powershell
podman info
```

Weitere Diagnosebefehle enthält
[Podman unter Windows: Localhost-Portweiterleitung](../HowTo/PODMAN_WINDOWS_NETWORKING.md).

## 8. Schritt 6 – `sqlcmd` installieren

Microsoft stellt zwei Varianten bereit: die Go-Variante und die klassische
ODBC-Variante. Die Runtime-Workflows dieses Repository verwenden
`mssql-tools18`; deshalb ist `sqlcmd` (ODBC) der Referenzpfad.

1. Die offizielle Seite
   [sqlcmd herunterladen und installieren](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install)
   öffnen.
2. Im Abschnitt **Download and install sqlcmd (ODBC)** zuerst den aktuellen
   Microsoft ODBC Driver for SQL Server und danach die aktuellen Microsoft
   Command Line Utilities für die Hostarchitektur installieren.
3. Ein neues Terminal öffnen und prüfen:

```powershell
Get-Command sqlcmd
sqlcmd -?
```

Alternativ kann die Go-Variante mit `winget install sqlcmd` installiert werden.
Sie ist eine offizielle Variante, aber nicht der in den bestehenden
`mssql-tools18`-Workflows verwendete Referenzpfad. Nach ihrer Installation muss
mindestens der vollständige Lab-Smoke-Test für den gewählten Provider erfolgreich
sein.

## 9. Schritt 7 – Repository beziehen und Modul importieren

```powershell
git clone https://github.com/gecompat/SQL_Server_Lab.git
Set-Location .\SQL_Server_Lab
Import-Module .\SqlServerLab.psd1 -Force
```

Bei Verwendung eines ZIP-Archivs das Archiv zuerst entpacken und in dessen
Wurzelverzeichnis wechseln.

Die öffentlichen Cmdlets prüfen:

```powershell
Get-Command -Module SqlServerLab | Sort-Object Name
```

## 10. Schritt 8 – Installation abschließend prüfen

Für Docker:

```powershell
Test-SqlServerLabPrerequisite -Provider docker
$lab = New-SqlServerLab -Version '2025' -Provider docker
Get-SqlServerLab
Remove-SqlServerLab -RunId $lab.RunId
```

Für Podman zuerst die Machine sicherstellen und danach prüfen:

```powershell
podman machine start podman-machine-default
Test-SqlServerLabPrerequisite -Provider podman
$lab = New-SqlServerLab -Version '2025' -Provider podman
Get-SqlServerLab
Remove-SqlServerLab -RunId $lab.RunId
```

### CU-Ressourcen für Windows und Linux

Nach der Modulinstallation kann jeder katalogisierte CU ohne zusätzliche
Hilfswerkzeuge geladen werden. Windows verwendet den konfigurierten Media Root
und erzwingt SHA-256 sowie Microsoft-Authenticode; Linux zieht den exakten MCR-
Tag in Docker oder Podman:

```powershell
Save-SqlServerLabCuResource -SqlVersion 2025 -Cu CU8 -Platform Windows -MediaRoot 'D:\Lab_Base'
Save-SqlServerLabCuResource -SqlVersion 2025 -Cu CU8 -Platform Linux -Provider Docker
```

Alternativ steht derselbe Ablauf im Konsolenmenü unter **Medien, Testdaten und
Speicher → SQL Server CU herunterladen oder prüfen** bereit.

`podman machine start` kann melden, dass die Machine bereits läuft. In diesem
Fall ist keine weitere Aktion erforderlich.

## 11. Aktualisierung und täglicher Start

Repository aktualisieren:

```powershell
Set-Location .\SQL_Server_Lab
git pull --ff-only
Import-Module .\SqlServerLab.psd1 -Force
```

Ohne aktivierten Lab-Autostart starten Podman-AnwenderInnen vor der ersten
Lab-Nutzung nach einem Hostneustart:

```powershell
podman machine start podman-machine-default
podman info
```

Docker-AnwenderInnen starten Docker Desktop und prüfen anschließend `docker
info`. Bei `-AutoStart on` beziehungsweise `instances[].autostart: "on"` legt
SQL Server Lab stattdessen je Runtime einen Auftrag für das aktuelle
Benutzerkonto an. Er startet die Runtime nach der Windows-Anmeldung und fährt
nur markierte Lab-Container hoch. Desktop-/Rootless-Runtimes stehen damit erst
nach der Anmeldung, nicht als systemweiter Dienst vor dem Login, bereit.
Ein bereits vorhandener, in Benutzer, Trigger und Aktion unverändert passender
Auftrag wird gemeinsam genutzt; abweichende oder fremde Aufgaben werden nicht
stillschweigend übernommen.

Sind nur Docker oder nur Podman installiert, bleibt dieser direkte
Ein-Provider-Start unverändert. Sind beide CLIs und Desktop-Anwendungen
vorhanden und besitzt Podman einen verwalteten Lab-Autostart, wird der
Parallelbetrieb automatisch erkannt. Der Podman-Auftrag startet beziehungsweise
prüft dann zuerst Docker Desktop, wartet auf eine erreichbare Docker Engine und
startet erst danach die Podman Machine. So konkurrieren die beiden WSL-basierten
Backends nicht während ihrer Initialisierung.

Ist der bekannte Hersteller-Eintrag
`io.podman_desktop.PodmanDesktop` unter
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` vorhanden, sichert SQL
Server Lab seinen exakten Wert lokal unter
`%LOCALAPPDATA%\SQL_Server_Lab\autostart\windows-podman-desktop-autostart.json`
und entfernt nur diesen Eintrag. Nach der Podman-Bereitschaft startet der
verwaltete Auftrag Podman Desktop selbst. Beim Entfernen des letzten markierten
Podman-Labs werden Auftrag, generiertes Skript und Receipt entfernt und der
ursprüngliche Login-Eintrag wiederhergestellt. Ein unbekannter oder extern
veränderter Wert wird nicht überschrieben; die Einrichtung endet dann
fail-closed beziehungsweise bewahrt das Receipt zur manuellen Recovery auf.
