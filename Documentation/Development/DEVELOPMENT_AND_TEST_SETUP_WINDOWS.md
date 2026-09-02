# Entwicklungs- und Testumgebung unter Windows

| Merkmal | Wert |
|---|---|
| Zielgruppe | Beitragende und BetreiberInnen von Test-Runnern |
| Kernentwicklung | PowerShell 7.2+, Git |
| Container-Tests | Docker und/oder Podman plus `sqlcmd` |
| Native Hyper-V-Tests | separater administrativer Windows-Host |

## 1. Abgrenzung zur Anwenderinstallation

Die [Anwenderinstallation](../User/INSTALLATION_WINDOWS.md) beschreibt den
minimalen Rechner für die Nutzung eines Labs. Entwicklung und Tests benötigen
nur dann zusätzliche Software, wenn der geänderte Bereich diese Runtime
tatsächlich betrifft.

Operatorseitige ISO-, VHDX- und SQL-Medien werden über einen verpflichtend
angegebenen [externen Media Root](../HowTo/MEDIA_ROOT_LAYOUT.md) bereitgestellt.

| Änderung | Zusätzlich erforderliche Software oder Ressource |
|---|---|
| Dokumentation, Schema, Katalog oder reine PowerShell-Logik | keine Container-Runtime erforderlich |
| Docker-Provider oder gemeinsame Containerlogik | laufende Docker Engine und `sqlcmd` |
| Podman-Provider oder gemeinsame Containerlogik | laufende Podman Machine und `sqlcmd` |
| gemischter Provider-Lifecycle | Docker und Podman auf demselben Host |
| Hyper-V-Lifecycle | Hyper-V, Hyper-V-PowerShell-Modul und ausreichende Berechtigungen |
| Pull Requests, Workflow-Start und Checkauswertung über CLI | optional GitHub CLI |

Visual Studio, SQL Server Management Studio und eine lokal installierte
SQL-Server-Instanz sind für das Repository nicht erforderlich.

## 2. Basisausstattung installieren

### 2.1 PowerShell 7

Offizielle Quelle:
[PowerShell unter Windows installieren](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows)

```powershell
winget install --id Microsoft.PowerShell --source winget
pwsh
$PSVersionTable.PSVersion
```

### 2.2 Git

Offizielle Quelle: [Git for Windows](https://git-scm.com/install/windows)

```powershell
winget install --id Git.Git -e --source winget
git --version
```

Repository klonen:

```powershell
git clone https://github.com/gecompat/SQL_Server_Lab.git
Set-Location .\SQL_Server_Lab
git status --short --branch
```

### 2.3 GitHub CLI – optional für Repository-Administration

GitHub CLI ist nicht für lokale Tests erforderlich. Sie erleichtert jedoch das
Starten und Auswerten von Actions sowie Pull-Request- und Merge-Arbeit.

Offizielle Quelle: [GitHub CLI](https://cli.github.com/)

```powershell
winget install --id GitHub.cli --source winget
gh auth login
gh auth status
```

Die Anmeldung soll den Betriebssystem-Credential-Store verwenden. Das Projekt
benötigt keinen dauerhaft in einer versionierten `.env` gespeicherten Personal
Access Token. Tokens, Runner-Registrierungstokens und andere Secrets dürfen
nicht in Repository, Logs oder Actions-Artefakte gelangen.

## 3. Statische Entwicklung und Tests

Die statische Suite und PSScriptAnalyzer-Prüfung laufen bereits über das
lokale Repo und benötigen PowerShell 7.2 oder neuer. 

### 3.1 Zentrale Host-Tool-Auflösung

No-Profile-Shells, Desktop-Agenten und Dienstkonten können einen älteren oder
abweichenden Prozess-`PATH` erben. Vor lokalen Runtime-Prüfungen kann deshalb
der gemeinsame Resolver ausgeführt werden:

```powershell
.\Tools\Initialize-SqlServerLabHostTools.ps1
```

Er löst Docker, Podman und Python über den bestehenden Sessionbefehl,
persistierte Benutzer-/Maschinen-`PATH`-Einträge und bekannte Windows-
Installationsorte auf. Er erweitert nur den aktuellen Prozess-`PATH`; die
persistierten Einstellungen bleiben unverändert. Für abweichende
Installationsorte stehen exakte, auf vorhandene Executables validierte
Overrides bereit:

```powershell
$env:SQL_SERVER_LAB_DOCKER_PATH = 'D:\Tools\Docker\docker.exe'
$env:SQL_SERVER_LAB_PODMAN_PATH = 'D:\Tools\Podman\podman.exe'
$env:SQL_SERVER_LAB_PYTHON_PATH = 'D:\Tools\Python\python.exe'
```

Die Auflösung beweist nur, dass eine Datei oder ein Sessionbefehl vorhanden
ist. Runtime-Erreichbarkeit und Ausführungsrechte werden weiterhin getrennt
geprüft; insbesondere kann ein Prozess-`PATH` keine Sandbox- oder
Berechtigungsgrenze umgehen. Die Framework-Probes verwenden den zentral
aufgelösten absoluten Aufrufspfad. Daher wird eine gefundene, aber im aktuellen
Ausführungskontext gesperrte Datei als Ausführungsfehler und nicht als fehlende
Installation gemeldet.

Für den ergänzenden Pester-Unit-/Contract-Check empfiehlt sich:

- `Install-Module PSScriptAnalyzer -Scope CurrentUser -Force` (für PSScriptAnalyzer)
- `Install-Module Pester -Scope CurrentUser -Force` (für `Invoke-PesterChecks`)

```powershell
Import-Module .\SqlServerLab.psd1 -Force
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Static\Invoke-PesterChecks.ps1
```

Für reine Dokumentationsänderungen ist mindestens auszuführen:

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

PSScriptAnalyzer ist als Teil des projektspezifischen Qualitätsrasters aktiv.

## 4. Docker-Testumgebung

Docker Desktop und WSL 2 gemäß
[Anwenderinstallation](../User/INSTALLATION_WINDOWS.md#variante-a--docker-desktop)
einrichten. Danach:

```powershell
docker version
docker info
sqlcmd -?
```

Relevante Tests:

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
```

Die vollständige Versions- und Parallelmatrix benötigt zusätzliche Zeit,
Arbeitsspeicher und lokalen Image-Speicher:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 -Provider docker -ReferenceVersion 2025
```

## 5. Podman-Testumgebung

Podman Desktop, WSL 2, `sqlcmd` und die Localhost-Konfiguration gemäß
[Anwenderinstallation](../User/INSTALLATION_WINDOWS.md#variante-b--podman-desktop)
einrichten.

### 5.1 Machine manuell starten

```powershell
podman machine start podman-machine-default
podman machine list
podman info
```

Dieser Befehl ist insbesondere nach einem Hostneustart oder einem vorherigen
`podman machine stop` erforderlich. Ein installiertes `podman.exe` beweist noch
keine erreichbare Runtime.

### 5.2 Automatischer Start in den Repository-Tests

Die Podman- und Mixed-Provider-Workflows verwenden:

```powershell
.\Tests\Integration\Initialize-PodmanRuntime.ps1
```

Das Skript löst zuerst `podman.exe` über den zentralen Host-Tool-Resolver auf
und führt dann `podman info` über den ermittelten Aufrufspfad aus. Ist Podman installiert, aber nicht
erreichbar, liest es vorhandene Machines ein, bevorzugt
`podman-machine-default`, startet die Machine und wartet begrenzt auf
Erreichbarkeit. Es erstellt absichtlich keine neue Machine.

Relevante Tests:

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-SmokeMatrix.ps1 -Provider podman -ReferenceVersion 2025
```

## 6. Gemischter Docker-/Podman-Test

Beide Runtimes müssen für dasselbe Windows-Benutzerkonto erreichbar sein:

```powershell
docker info
podman machine start podman-machine-default
podman info
sqlcmd -?
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
```

Der erfolgreiche Docker-Test ersetzt keinen Podman-Nachweis und umgekehrt.

## 7. Hyper-V-Native-Testumgebung

Hyper-V ist nur für Hyper-V-bezogene Entwicklungs- und Native-Testpfade
erforderlich. Der öffentliche Menü-/SQL-Runtimepfad bietet Hyper-V noch nicht
an.

Offizielle Quelle:
[Hyper-V unter Windows und Windows Server installieren](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/Install-Hyper-V)

Windows 10/11 Pro oder Enterprise als Administrator:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Windows Server als Administrator:

```powershell
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
```

Nach dem erforderlichen Neustart prüfen:

```powershell
Get-VMHost
Get-Command New-VM, New-VHD, Get-VMFirmware
```

Das ausführende Konto muss Mitglied der lokalen Administratoren oder der Gruppe
`Hyper-V Administrators` sein und Schreibrechte auf die verwendeten VM-/VHDX-
Arbeitsverzeichnisse besitzen.

Workflow und Browser aktivieren Hyper-V deshalb anhand des erfolgreichen
`Get-VMHost`-Capability-Probes und nicht anhand des Administrator-Rollenbits.
Einzelne Operationen mit zusätzlichen Volume-Rechten, insbesondere
`Mount-VHD`, prüfen ihre engere Berechtigung weiterhin erst am jeweiligen
Ausführungspunkt und melden dort gegebenenfalls den erforderlichen UAC-
Übergang.

Native Lifecycle-Prüfung:

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
```

Dieser Test verwendet eine synthetische Parent-VHDX. Er beweist VM-, VHDX-,
Registry- und Cleanup-Lifecycle, aber keine Betriebssysteminstallation und keine
SQL-Provisionierung. Der spätere vollständige End-to-End-Nachweis benötigt
zusätzlich ein legal bereitgestelltes Windows-Medium, SQL-Server-Medium,
genügend VM-Speicher, einen Hyper-V-Switch und sichere Gastzugangsdaten. Diese
Artefakte bleiben außerhalb von Git.

## 8. Self-hosted GitHub Actions Runner

Offizielle Quelle:
[Self-hosted Runner hinzufügen](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)

1. Im Repository **Settings > Actions > Runners > New self-hosted runner**
   öffnen.
2. Betriebssystem und Architektur auswählen.
3. Die dort angezeigten Download-, Entpack-, Registrierungs- und Startbefehle
   unverändert auf dem Runner ausführen. Das Registrierungstoken ist kurzlebig
   und darf nicht gespeichert werden.
4. Auf Windows bei einer Serviceinstallation die administrative PowerShell und
   einen servicegeeigneten Pfad wie `C:\actions-runner` verwenden.
5. Die zum Host passenden benutzerdefinierten Labels vergeben:

| Zweck | Erforderliche Labels zusätzlich zu `self-hosted` |
|---|---|
| Docker | `SQL_Lab`, `Docker` |
| Podman | `SQL_Lab`, `Podman` |
| gemischter Test | `SQL_Lab`, `Docker`, `Podman` |
| Hyper-V | `SQL_Lab`, `Hyper-V` |

6. In GitHub prüfen, dass der Runner den Zustand **Idle** erreicht.

### 8.1 Benutzerkonto und Runtime-Sichtbarkeit

Podman Machines sind benutzergebunden. Der Runner muss deshalb unter demselben
Windows-Konto laufen, unter dem `podman machine init` ausgeführt wurde, oder
unter seinem eigenen Dienstkonto eine eigene Machine besitzen. Das gilt ebenso
für PATH, Podman Connections und die Datei `%USERPROFILE%\.wslconfig`.

Docker Desktop ist ebenfalls an Desktop-Sitzung und Installationsmodus gebunden.
Vor dem Aktivieren eines Service-Runners muss unter genau dessen Konto geprüft
werden:

```powershell
docker info
podman info
sqlcmd -?
pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
```

Der Hyper-V-Runner benötigt unter seinem Ausführungskonto erfolgreichen Zugriff
auf `Get-VMHost`, `New-VM` und `New-VHD`.

### 8.2 Sicherheit

Self-hosted Runner führen Repository-Code mit den Rechten ihres Dienstkontos
aus. Unvertrauenswürdige Pull Requests, insbesondere aus Forks eines öffentlichen
Repositories, dürfen nicht ungeprüft auf privilegierten Docker-, Podman- oder
Hyper-V-Runnern ausgeführt werden. Runner-Berechtigungen, Workflow-Freigaben und
Branch Protection sind entsprechend restriktiv zu konfigurieren.

## 9. Ressourcenplanung

Die Werte sind Betriebsrichtwerte und keine harte Schemaanforderung:

| Testumfang | Sinnvoll verfügbare Ressourcen |
|---|---|
| statische Suite | 2 CPU-Kerne, 2 GB RAM, weniger als 1 GB Speicher |
| einzelner SQL-Container | mindestens 4 GB freier RAM und 5 GB Speicher gemäß Projektvertrag |
| vollständige Container-Matrix und parallele Runs | etwa 12–16 GB freier RAM und 30–60 GB schneller Speicher |
| ein echter Windows-/SQL-Hyper-V-Gast | etwa 16 GB freier RAM und 100–150 GB schneller Speicher zusätzlich zu Hostbedarf und Images |

Vor einem Runtime-Test sind aktive Fremdcontainer, belegte Ports und der freie
Speicher zu prüfen. Testartefakte, Images und lokale Run-States dürfen nicht in
Git aufgenommen werden.

## 10. Abnahme vor einem Pull Request

Die verbindliche Zuordnung steht in der
[lokalen Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
Mindestens den zur Änderung passenden statischen und nativen Test ausführen.
Nicht verfügbare Native-Tests im Pull Request ausdrücklich als `NOT_EXECUTED`
mit Begründung ausweisen; ein fehlender Provider ist kein `PASS`.
