# Entwicklungs- und Testumgebung unter Linux

## 1. Basis

Zuerst die vollständige
[Linux-Anwenderinstallation](../User/INSTALLATION_LINUX.md) durchführen. Für
reine Dokumentations-, Schema- und statische PowerShell-Änderungen sind Docker,
Podman und `sqlcmd` nicht erforderlich.

| Änderungsbereich | Erforderliche Runtime |
|---|---|
| Dokumentation, Schema, Katalog, reine PowerShell-Verträge | keine |
| Docker-Provider | Docker Engine und `sqlcmd` |
| Podman-Provider | Podman und `sqlcmd` |
| gemeinsame Containerlogik | Docker und Podman getrennt testen |
| gemischter Provider-Lifecycle | Docker und Podman auf demselben Host |
| Hyper-V | nicht auf Linux verfügbar; separater Windows-Host erforderlich |

## 2. Statische Entwicklung

```bash
cd ~/src/SQL_Server_Lab
pwsh -NoProfile -File ./Tests/Static/Invoke-AllChecks.ps1
```

Für den ergänzenden Pester-Check zusätzlich:

```bash
pwsh -NoProfile -File ./Tests/Static/Invoke-PesterChecks.ps1
```

PSScriptAnalyzer ist als Teil des lokalen Qualitätsrasters bereits vorgesehen.

## 3. Provider-Tests

Docker:

```bash
docker info
sqlcmd -?
pwsh -NoProfile -File ./Tests/Integration/Invoke-SmokeTest.ps1 -Provider docker
pwsh -NoProfile -File ./Tests/Integration/Invoke-RestoreSmokeTest.ps1 -Provider docker
```

Podman:

```bash
podman info
sqlcmd -?
pwsh -NoProfile -File ./Tests/Integration/Invoke-SmokeTest.ps1 -Provider podman
pwsh -NoProfile -File ./Tests/Integration/Invoke-RestoreSmokeTest.ps1 -Provider podman
```

Gemischter Provider-Test:

```bash
docker info
podman info
pwsh -NoProfile -File ./Tests/Integration/Invoke-MixedProviderSmokeTest.ps1
```

## 4. Self-hosted GitHub Actions Runner

Die aktuellen Registrierungsbefehle werden unter
**Settings > Actions > Runners > New self-hosted runner** erzeugt. Die
offizielle Anleitung steht unter
[Self-hosted Runner hinzufügen](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners).

Für einen dedizierten Linux-Runner wird ein eigenes Konto empfohlen:

```bash
sudo adduser --disabled-password --gecos '' sql-lab
sudo install -d -o sql-lab -g sql-lab /opt/actions-runner
sudo install -d -o sql-lab -g sql-lab /var/lib/sql-server-lab
```

Runner-Software nach `/opt/actions-runner` herunterladen und unter dem Konto
`sql-lab` registrieren. Den von GitHub angezeigten kurzlebigen
Registrierungstoken nicht speichern.

Docker-Runner:

```bash
sudo usermod -aG docker sql-lab
```

Nach einer Gruppenänderung die Runner-Sitzung beziehungsweise den Runner-Dienst
neu starten. Vor der Serviceinstallation unter genau diesem Konto prüfen:

```bash
sudo -iu sql-lab docker info
sudo -iu sql-lab /opt/mssql-tools18/bin/sqlcmd -?
sudo -iu sql-lab pwsh --version
```

Podman wird rootless unter dem Runner-Konto verwendet:

```bash
sudo -iu sql-lab podman info
```

Benötigte benutzerdefinierte Labels:

| Workflow | Labels zusätzlich zu `self-hosted` und `Linux` |
|---|---|
| Docker | `SQL_Lab`, `Docker` |
| Podman | `SQL_Lab`, `Podman` |
| gemischt | `SQL_Lab`, `Docker`, `Podman` |

Hyper-V-Workflows verwenden einen getrennten Windows-Runner mit `SQL_Lab` und
`Hyper-V`.

## 5. Sicherheitsgrenze

Docker-Gruppenmitglieder und Self-hosted Runner können den Host weitreichend
verändern. Ungeprüfte Fork-Pull-Requests dürfen keine privilegierten Runtime-
Runner erhalten. Media Root, Lab-State, Secrets und Runner-Arbeitsverzeichnis
bleiben voneinander getrennt.
