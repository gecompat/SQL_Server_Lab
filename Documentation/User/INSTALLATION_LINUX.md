# Installation für AnwenderInnen unter Linux

| Merkmal | Wert |
|---|---|
| Referenzdistribution | Ubuntu Server 24.04 LTS x64 |
| Mindestversion PowerShell | 7.2 |
| Container-Provider | Docker Engine oder Podman |
| SQL-Client | `sqlcmd` aus `mssql-tools18` |

## 1. Geltungsbereich und aktueller Nachweis

Diese Anleitung richtet einen nativen Ubuntu-Host für den Containerpfad von
`SQL_Server_Lab` ein. Sie beschreibt keine Linux-VM-Provisionierung durch den
Hyper-V-Provider. Der aktuelle Hyper-V-Image-Builder unterstützt ausschließlich
Windows Server 2022 und 2025.

Die statische Suite läuft in GitHub Actions auf Ubuntu. Zusätzlich existiert ein
GitHub-hosted Docker-/Adapter-Smoke-Test auf Ubuntu. Podman ist unter Linux als
Provider vorgesehen; der veröffentlichte projektspezifische Native-Nachweis
erfolgte bisher jedoch nicht ausdrücklich auf einem Linux-Host. Für einen neuen
Linux-Referenzrunner ist Docker Engine deshalb der primäre Pfad.

Die zusätzlichen Anforderungen für Beiträge, vollständige Matrizen und
Self-hosted Runner stehen in der
[Linux-Entwicklungs- und Testumgebung](../Development/DEVELOPMENT_AND_TEST_SETUP_LINUX.md).

## 2. Benötigte Software

| Komponente | Erforderlich | Offizielle Quelle |
|---|---|---|
| Ubuntu Server 24.04 LTS x64 | für einen neuen Linux-Host | [Ubuntu Server herunterladen](https://ubuntu.com/download/server) |
| PowerShell 7.2 oder neuer | ja | [PowerShell unter Ubuntu installieren](https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu) |
| Git | empfohlen | [Git installieren](https://git-scm.com/download/linux) |
| Docker Engine oder Podman | ja | [Docker Engine unter Ubuntu](https://docs.docker.com/engine/install/ubuntu/) / [Podman installieren](https://podman.io/docs/installation) |
| `mssql-tools18` | ja für vollständige SQL-Pfade | [SQL Server Command-Line Tools unter Linux](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-tools) |

Mindestens 4 GB freier RAM und 5 GB freier Speicher sind für ein kleines Lab
erforderlich. Für mehrere SQL-Server-Versionen und parallele Runs sind 12–16 GB
freier RAM und 30–60 GB schneller Speicher sinnvoll.

## 3. Ubuntu installieren

Wenn noch kein Linux-Host vorhanden ist:

1. Ubuntu Server 24.04 LTS x64 von der offiziellen Downloadseite laden.
2. Für eine VM mindestens 2 vCPU, 8 GB RAM und 40 GB Disk bereitstellen. Für
   einen vollständigen Test-Runner sind 4 vCPU, 16 GB RAM und 80 GB Disk
   empfehlenswert.
3. Während der Ubuntu-Installation OpenSSH nur aktivieren, wenn Remotezugriff
   benötigt wird.
4. Nach dem ersten Login das System aktualisieren:

```bash
sudo apt-get update
sudo apt-get full-upgrade -y
sudo reboot
```

Die ISO ist nur für die Hostinstallation erforderlich. `SQL_Server_Lab`
verwendet sie nicht als Runtime-Artifact. Operatorseitige ISO/VHDX-Ablage ist
unter [Externer Media Root](../HowTo/MEDIA_ROOT_LAYOUT.md) beschrieben.

## 4. Basispakete installieren

```bash
sudo apt-get update
sudo apt-get install -y \
  git \
  curl \
  wget \
  ca-certificates \
  apt-transport-https \
  software-properties-common
```

Prüfen:

```bash
git --version
curl --version
```

## 5. Microsoft-Paketquelle registrieren

PowerShell und `mssql-tools18` werden aus der offiziellen Microsoft-
Paketquelle installiert:

```bash
source /etc/os-release

wget -q \
  "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb"

sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt-get update
```

## 6. PowerShell 7 installieren

```bash
sudo apt-get install -y powershell
pwsh --version
```

Eine Shell starten und die Version prüfen:

```bash
pwsh
$PSVersionTable.PSVersion
exit
```

Erforderlich ist PowerShell 7.2 oder eine insgesamt neuere Version.

## 7. `sqlcmd` installieren

Die GitHub-hosted Linux-Workflows dieses Repository verwenden die ODBC-Variante
aus `mssql-tools18`:

```bash
sudo ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev

echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.profile
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
export PATH="$PATH:/opt/mssql-tools18/bin"
```

Prüfen:

```bash
command -v sqlcmd
sqlcmd -?
```

Für einen Service-Runner muss `/opt/mssql-tools18/bin` auch in dessen
Serviceumgebung enthalten sein; Benutzerprofile werden von Diensten nicht
zwangsläufig geladen.

## 8. Eine Container-Runtime installieren

Nur eine Variante ist für die Lab-Nutzung erforderlich.

### Variante A – Docker Engine

Docker Desktop ist auf einem Ubuntu-Server nicht erforderlich. Die offizielle
Docker-Paketquelle einrichten:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL \
  https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

source /etc/os-release
ARCH="$(dpkg --print-architecture)"

echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" |
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

Dienst aktivieren:

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

Den ausführenden Benutzer zur Docker-Gruppe hinzufügen:

```bash
sudo usermod -aG docker "$USER"
```

Danach vollständig ab- und wieder anmelden. Für die aktuelle Shell kann
alternativ `newgrp docker` verwendet werden. Mitgliedschaft in der Docker-
Gruppe gewährt praktisch Root-äquivalente Rechte und darf nur vertrauenswürdigen
Konten erteilt werden.

Prüfen:

```bash
docker version
docker info
docker run --rm hello-world
```

### Variante B – Podman

Podman läuft auf einem nativen Linux-Host direkt. Eine Podman Machine ist dort
nicht erforderlich; `podman machine start` gehört nur zu Windows und macOS.

```bash
sudo apt-get update
sudo apt-get install -y \
  podman \
  uidmap \
  slirp4netns \
  fuse-overlayfs
```

Prüfen:

```bash
podman version
podman info
podman run --rm docker.io/library/alpine cat /etc/os-release
```

Bei `instances[].autostart: "on"` aktiviert SQL Server Lab für Podman den
User-Service `podman-restart.service` sowie systemd-Linger für den aktuellen
Benutzer. Docker verwendet dieselbe Container-Restart-Policy und prüft, dass
`docker.service` beim Boot aktiviert ist. Fehlende Rechte oder ein deaktivierter
Hostdienst führen zu einem klaren Fehler statt zu einem Schein-Autostart.

## 9. Repository beziehen

Empfohlener interaktiver Checkout:

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/gecompat/SQL_Server_Lab.git
cd SQL_Server_Lab
```

Das Repository liegt damit unter:

```text
/home/<benutzer>/src/SQL_Server_Lab
```

Modul importieren:

```bash
pwsh -NoProfile -Command \
  'Import-Module ./SqlServerLab.psd1 -Force; Get-Command -Module SqlServerLab'
```

## 10. Lokalen State konfigurieren

Ohne Konfiguration speichert das Projekt seinen Linux-State hier:

```text
/home/<benutzer>/.sql-server-lab
```

Dieser Pfad liegt außerhalb des Checkouts. Er enthält Runs, Cache, Trust-
Informationen und lokale Artifacts und darf nicht nach Git kopiert werden.

Optional kann ein eigener State Root verwendet werden:

```bash
sudo install -d -o "$USER" -g "$USER" /var/lib/sql-server-lab
echo 'export SQL_SERVER_LAB_STATE=/var/lib/sql-server-lab' >> ~/.profile
export SQL_SERVER_LAB_STATE=/var/lib/sql-server-lab
```

Der State Root ist nicht der Media Root. ISO-, VHDX- und Installationsmedien
bleiben in einem getrennten operatorseitigen Verzeichnis.

## 11. Installation abschließend prüfen

Statische Suite:

```bash
cd ~/src/SQL_Server_Lab
pwsh -NoProfile -File ./Tests/Static/Invoke-AllChecks.ps1
```

Docker:

```bash
pwsh -NoProfile -Command \
  'Import-Module ./SqlServerLab.psd1 -Force; Test-SqlServerLabPrerequisite -Provider docker'

pwsh -NoProfile -File \
  ./Tests/Integration/Invoke-SmokeTest.ps1 \
  -Provider docker
```

Podman:

```bash
pwsh -NoProfile -Command \
  'Import-Module ./SqlServerLab.psd1 -Force; Test-SqlServerLabPrerequisite -Provider podman'

pwsh -NoProfile -File \
  ./Tests/Integration/Invoke-SmokeTest.ps1 \
  -Provider podman
```

Die SQL-Server-Images werden bei Bedarf automatisch aus
`mcr.microsoft.com/mssql/server` geladen. Sie werden nicht manuell in den Media
Root kopiert.
