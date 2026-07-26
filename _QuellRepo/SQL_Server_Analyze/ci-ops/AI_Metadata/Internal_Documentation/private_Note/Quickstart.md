Nein, du übersiehst grundsätzlich nichts. Im Gegenteil: Für den **eigentlichen Zweck dieses Projekts** (schnell reproduzierbare Testumgebung für SQL_Server_Analyze) ist dein Ansatz wahrscheinlich der bessere Einstieg.

Ich würde sogar sagen: Die aktuelle Lab-Architektur ist inzwischen **zu stark in Richtung CI-/Enterprise-Lifecycle-Plattform gewachsen**, bevor der einfachste Nutzerpfad sauber vorhanden ist.

Der einfache Pfad sollte sein:

```
User
 |
 | 1. git clone
 |
 | 2. ./setup.ps1
 |
 | 3. .env ausfüllen
 |
 | 4. docker compose up
 |
 v
Fertige SQL-Testumgebung
```

---

## Dein vorgeschlagener Ansatz ist fachlich korrekt

### Repository enthält:

```
SQL_Server_Analyze
│
├── docker-compose.yml
├── .env.example
├── .gitignore
│
├── scripts
│   ├── Setup-TestEnvironment.ps1
│   ├── Start-TestEnvironment.ps1
│   └── Remove-TestEnvironment.ps1
│
└── README.md
```

---

## Ablauf

### 1. Benutzer startet Setup

Beispiel:

```powershell
.\scripts\Setup-TestEnvironment.ps1
```

Das Script:

prüft:

* Docker vorhanden?
* Docker Compose vorhanden?
* genügend Speicher?
* Ports frei?

Dann:

```text
Keine .env gefunden.

Erzeuge:
.env

Bitte setzen:
SQL_SA_PASSWORD=
```

---

## 2. .env

Beispiel:

```env
ACCEPT_EULA=Y

SQL_SA_PASSWORD=MeinTestPasswort123!

SQL_VERSIONS=2019,2022,2025

SQL_DATA_PATH=D:\SQLAnalyze\Data
```

Diese Datei:

```
.gitignore
```

enthält:

```gitignore
.env
*.local.*
```

---

## 3. docker-compose.yml

Beispiel:

```yaml
services:

  sql2019:
    image: mcr.microsoft.com/mssql/server:2019-latest
    container_name: sqlanalyze-2019
    environment:
      ACCEPT_EULA: ${ACCEPT_EULA}
      MSSQL_SA_PASSWORD: ${SQL_SA_PASSWORD}
    ports:
      - "14331:1433"
    volumes:
      - ${SQL_DATA_PATH}/2019:/var/opt/mssql


  sql2022:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: sqlanalyze-2022
    environment:
      ACCEPT_EULA: ${ACCEPT_EULA}
      MSSQL_SA_PASSWORD: ${SQL_SA_PASSWORD}
    ports:
      - "14332:1433"


  sql2025:
    image: mcr.microsoft.com/mssql/server:2025-latest
    container_name:
      sqlanalyze-2025
```

---

## 4. Framework Installation

Danach:

```powershell
docker compose up -d
```

und:

```powershell
.\scripts\Install-Framework.ps1
```

macht:

* wartet bis SQL erreichbar
* installiert Framework
* führt Smoke Tests aus

---

# Was spricht gegen diesen Ansatz?

Es gibt nur wenige Punkte.

## 1. Secrets

Dein Ansatz:

```
.env
```

ist für ein lokales Testsystem völlig üblich.

Für:

* Entwickler
* Schulung
* lokale LABs

ist das akzeptabel.

Für:

* Produktionsumgebung
* Enterprise CI

würde man später Secret Provider verwenden.

Aber das sind zwei verschiedene Zielgruppen.

---

## 2. Reproduzierbarkeit

Ein möglicher Einwand:

"Image-Tags können sich ändern."

Das stimmt.

Für ein späteres CI-System braucht man:

```
mcr.microsoft.com/mssql/server@sha256:xxxx
```

Aber für einen ersten lokalen Test:

```
2022-latest
```

ist völlig ausreichend.

---

## 3. Windows + Docker Desktop

Dein konkreter Fall:

Windows 11 Pro
Docker Desktop
Self-hosted Runner

passt perfekt.

---

# Was ich ändern würde

Ich würde zwei Ebenen anbieten:

## Ebene 1: Quick Start (90 % der Benutzer)

```
.env
docker compose
Install script
```

Ziel:

"Innerhalb von 10 Minuten läuft SQL_Server_Analyze."

---

## Ebene 2: Advanced Lab

Die bereits vorhandene Architektur:

```
Invoke-DiagnosticLab.ps1
Preflight
Lifecycle
Evidence Gates
Run IDs
Image Locks
```

Ziel:

"Automatisierte reproduzierbare Testplattform."

---

Momentan fehlt Ebene 1.

---

# Meine Empfehlung

Ich würde jetzt **nicht weiter am komplexen Lab-Setup drehen**, sondern einen neuen einfachen Einstieg ergänzen:

```
Lab/SimpleDockerTestEnvironment/
```

mit:

```
.env.example
docker-compose.yml
Setup.ps1
Start.ps1
Stop.ps1
InstallFramework.ps1
README.md
```

Dieser Pfad würde:

* deinen Windows Runner testen
* Docker Desktop validieren
* SQL 2019/2022/2025 bereitstellen
* das Framework installieren

Danach kann der komplexere LAB-Pfad darauf aufbauen.

Das ist aus meiner Sicht der fehlende "erste 15 Minuten Erfolgspfad" im Repository.


---

Ja, das ist möglich und ich halte diese Trennung für die bessere Architektur.

Die aktuelle Situation zeigt ein typisches Problem: Das bestehende LAB-Framework ist für **kontrollierte, reproduzierbare Evidenztests** gebaut. Es ist aber nicht der optimale Einstiegspunkt für jemanden, der einfach nur sagen möchte:

> "Ich habe eine Testmaschine. Ich möchte SQL Server 2019/2022/2025 starten und das Framework ausprobieren."

Diese beiden Zielgruppen sollten getrennt werden.

---

# Zielarchitektur

Ich würde zwei klar getrennte Bereiche definieren:

```text
SQL_Server_Analyze
│
├── Lab/
│   └── DiagnosticLab
│       ├── Preflight
│       ├── Evidence Gates
│       ├── Lifecycle
│       └── CI Tests
│
└── QuickStart/
    └── DockerTestEnvironment
        ├── Setup.ps1
        ├── docker-compose.yml
        ├── .env.example
        ├── InstallFramework.ps1
        └── README.md
```

## Für den Anwender sichtbar:

README:

```text
Start here:
    QuickStart/DockerTestEnvironment/README.md
```

Nicht:

```text
Lab/...
```

Der Anwender muss das LAB-Framework gar nicht kennen.

---

# Setup.ps1 Konzept

Das Script sollte interaktiv alle relevanten Parameter abfragen.

Beispiel:

```powershell
.\Setup.ps1
```

---

## 1. Runtime Auswahl

Frage:

```
Welche Container Runtime verwenden?

[1] Docker Desktop
[2] Docker Engine
[3] Podman

Auswahl:
```

Ergebnis:

```env
CONTAINER_ENGINE=docker
```

---

# 2. SQL Server Versionen

Frage:

```
Welche SQL Server Versionen bereitstellen?

[x] SQL Server 2019
[x] SQL Server 2022
[x] SQL Server 2025

Auswahl:
```

Ergebnis:

```env
SQL_VERSIONS=2019,2022,2025
```

---

# 3. SQL Login

Frage:

```
SQL Administrator Passwort:
```

Eingabe:

```powershell
Read-Host -AsSecureString
```

Speichern:

```env
SQL_SA_PASSWORD=...
```

Die `.env` bleibt lokal.

---

# 4. Storageprofil

Hier wird es wichtig für deine Performance-Schulung und Tests.

Nicht nur:

```text
C:\DockerData
```

sondern Profile.

---

## Profil A: Fast SSD

```
Storage Profil:

[1] Fast SSD
[2] Slow IO Simulation
[3] Separate Data/Log
[4] Custom
```

---

### Fast SSD

```env
SQL_STORAGE_PROFILE=FAST
SQL_DATA_PATH=D:\SQLAnalyze\Data
SQL_LOG_PATH=D:\SQLAnalyze\Log
```

---

### Slow IO Simulation

Beispiel:

```env
SQL_STORAGE_PROFILE=SLOW_IO
SQL_IO_DELAY_PROFILE=HIGH_LATENCY
```

Technisch könnte das später umgesetzt werden über:

* Docker Desktop Ressourcenlimits
* Linux `tc`
* FUSE/io throttling
* Hyper-V virtuelle Disk Limits

Wichtig:
Nicht vortäuschen. Das Profil muss dokumentieren, welche Einschränkung wirklich angewendet wird.

---

### Data/Log getrennt

```env
SQL_DATA_PATH=D:\SQLData
SQL_LOG_PATH=E:\SQLLog
```

Das passt zu deinem Rechner:

```
D: Samsung SSD
E: Samsung SSD
```

---

# 5. Ressourcenprofil

Frage:

```
SQL Server Ressourcen:

[1] Minimal
[2] Standard
[3] Performance
```

Erzeugt:

```env
SQL_MEMORY_LIMIT=8G
SQL_CPU_LIMIT=4
```

---

# 6. Netzwerk / Ports

Automatisch:

```env
SQL2019_PORT=14331
SQL2022_PORT=14332
SQL2025_PORT=14333
```

Aber prüfen:

```powershell
Test-NetConnection localhost -Port xxxx
```

---

# 7. Framework Installation

Frage:

```
Framework automatisch installieren?

[J] Ja
[N] Nein
```

.env:

```env
INSTALL_FRAMEWORK=true
```

---

# 8. Ergebnis

Das Script erzeugt:

```
QuickStart/DockerTestEnvironment/

.env
docker-compose.override.yml
installation-summary.txt
```

Beispiel:

```
Setup completed

Runtime:
 Docker Desktop

SQL Versions:
 2019
 2022
 2025

Storage:
 Separate Data/Log

Framework:
 Enabled
```

---

# docker-compose Struktur

Nicht eine riesige Datei.

Besser:

```
docker-compose.yml
docker-compose.sql2019.yml
docker-compose.sql2022.yml
docker-compose.sql2025.yml
```

oder:

```
compose/
 ├── base.yml
 ├── sql2019.yml
 ├── sql2022.yml
 └── sql2025.yml
```

Setup.ps1 erzeugt daraus die gewünschte Kombination.

---

# Verbindung zum bestehenden LAB

Wichtig:

Keine Vermischung.

Also:

## QuickStart darf verwenden:

* SQL Installationsskripte
* Framework Installationsskripte

aber nicht:

* LAB State
* Evidence Gates
* Run IDs
* Szenarioverwaltung

---

## LAB darf später QuickStart nutzen

Aber nur optional:

```
LAB
 |
 +-- nutzt vorbereitete Docker Umgebung
```

nicht umgekehrt.

---

# Meine Empfehlung für den Repository-Aufbau

Ich würde anlegen:

```
QuickStart/
└── Docker/

    README.md

    Setup.ps1
    Start.ps1
    Stop.ps1
    Remove.ps1

    .env.example
    docker-compose.yml

    compose/
        sql2019.yml
        sql2022.yml
        sql2025.yml

    scripts/
        Wait-SqlReady.ps1
        Install-Framework.ps1
        Validate-Environment.ps1
```

---

# Fazit

Ja, das ist machbar.

Und die Trennung löst mehrere Probleme:

| Problem                     | Lösung             |
| --------------------------- | ------------------ |
| LAB zu komplex für Einstieg | QuickStart         |
| Secrets                     | lokale `.env`      |
| Windows Docker Desktop      | eigenes Profil     |
| Hyper-V später              | separates Profil   |
| langsamer Storage           | Storage Profile    |
| SQL Versionen               | Auswahl im Setup   |
| Anfängerfreundlichkeit      | ein Einstiegspunkt |
| CI/Evidence Tests           | bleiben im LAB     |

Der nächste sinnvolle Repository-Schritt wäre daher **nicht eine Anpassung des bestehenden LABs**, sondern ein neues, klar getrenntes `QuickStart/Docker`-Modul. Danach kann man den vorhandenen Self-hosted Runner damit in wenigen Minuten testen.


---

Nein, du übersiehst nichts. Im Gegenteil: diese Anforderungen sind **entscheidend**, wenn das QuickStart-System von anderen Personen auf beliebiger Hardware verwendet werden soll.

Ich würde die Anforderungen sogar erweitern. Ein Installationsscript für eine Testumgebung darf **niemals davon ausgehen**, dass es alleine auf einem sauberen Rechner läuft.

Die richtige Zielsetzung wäre:

> Das Setup richtet eine isolierte, selbstverwaltete Testumgebung ein, ohne bestehende Daten, Installationen oder Benutzerverzeichnisse zu verändern.

---

# Zusätzliche Architekturregeln für QuickStart

## 1. Expliziter Lab-Zielpfad

Der Benutzer muss immer einen Zielpfad angeben oder bestätigen.

Beispiel:

```text
Wo soll die SQL_Server_Analyze Testumgebung erstellt werden?

Standard:
D:\SQL_Server_Analyze_Lab

Pfad:
```

---

## 2. Keine automatischen Systempfade

Folgende Pfade müssen grundsätzlich abgelehnt werden:

```text
C:\
C:\Windows
C:\Program Files
C:\Program Files (x86)
C:\Users
C:\Users\<User>
C:\ProgramData
```

Beispiel:

Ungültig:

```text
C:\Windows\SQLLab
```

Antwort:

```text
FEHLER:
Der Zielpfad befindet sich innerhalb eines Windows-Systempfades.
Bitte wählen Sie einen dedizierten Lab-Pfad.
```

---

# 3. Ein-Laufwerk-Systeme unterstützen

Das ist wichtig.

Viele Testsysteme haben:

```text
C:
 └── Windows
 └── Docker
 └── Testdaten
```

Das muss funktionieren.

Aber:

Nicht:

```text
C:\SQLLab
```

sondern:

```text
C:\Lab\SQL_Server_Analyze_Test
```

nach expliziter Bestätigung.

---

## Beispiel:

Frage:

```text
Es wurde nur ein Laufwerk erkannt.

Verfügbar:
C:\

Empfohlener Lab-Pfad:
C:\SQL_Server_Analyze_Lab

Fortfahren? [J/N]
```

---

# 4. Zielpfad muss leer sein

Das ist eine sehr gute Sicherheitsanforderung.

Vor Erstellung:

Prüfen:

```powershell
Get-ChildItem $LabPath
```

Wenn Inhalt:

```text
FEHLER:

Der Zielpfad ist nicht leer.

Vorhandene Inhalte:
- logs
- data
- backup

Aus Sicherheitsgründen wird nichts überschrieben.
```

---

## Ausnahme

Ein vorhandener QuickStart darf aktualisiert werden.

Beispiel:

```text
C:\SQL_Server_Analyze_Lab
|
├── .env
├── docker-compose.yml
└── state.json
```

Dann:

```text
Bestehende SQL_Server_Analyze Lab-Installation erkannt.

Aktion:
[1] Update
[2] Entfernen und neu erstellen
[3] Abbrechen
```

---

# 5. Schutz gegen falsche Pfade

Ich würde zusätzlich eine Pfadprüfung einbauen:

## Erlaubt

```text
D:\Labs\SQL_Server_Analyze
C:\Labs\SQL_Server_Analyze
E:\Test\SQL_Server_Analyze
```

## Nicht erlaubt

```text
C:\
C:\Windows
D:\
C:\Users\Name\Desktop
```

Warum auch Root-Verzeichnisse ablehnen?

Weil ein Fehler wie:

```powershell
Remove-Item $LabPath\*
```

bei:

```text
C:\
```

katastrophal wäre.

---

# 6. Docker Volumes niemals automatisch global verwenden

Nicht:

```yaml
volumes:
 - sql-data:/var/opt/mssql
```

weil Docker dann irgendwo verwaltet.

Besser:

```yaml
volumes:
 - ${LAB_PATH}/sql2022/data:/var/opt/mssql/data
 - ${LAB_PATH}/sql2022/log:/var/opt/mssql/log
```

Damit bleibt alles innerhalb des Lab-Verzeichnisses.

---

# 7. Cleanup nur innerhalb des eigenen Scopes

Remove Script:

```powershell
.\Remove.ps1
```

darf nur:

```text
C:\SQL_Server_Analyze_Lab
```

entfernen.

Nicht:

```powershell
docker system prune
```

Nicht:

```powershell
Remove-Item D:\*
```

---

# 8. Storage Profile erweitern

Ich würde nicht nur "Fast SSD" und "Slow IO" anbieten.

Besser:

```text
Storage Setup:

[1] Single Disk
    Alles unter einem Lab-Verzeichnis

[2] Separate Data/Log
    Daten und Logs getrennt

[3] Performance Test
    Daten auf schneller SSD

[4] Custom
```

---

## Single Disk

Beispiel:

```text
C:\SQL_Server_Analyze_Lab

├── sql2019
│   ├── data
│   └── log
│
├── sql2022
│
└── sql2025
```

---

## Separate Disk

Beispiel:

```text
D:\SQLLab\Data

E:\SQLLab\Log
```

---

# 9. Vorhandene Installationen erkennen

Setup sollte prüfen:

## Docker Container

```powershell
docker ps -a
```

Suche:

```text
sqlanalyze-
```

Nur eigene Container dürfen erkannt/verändert werden.

---

## Docker Volumes

Nur:

```text
sqlanalyze_*
```

---

## Ports

Prüfen:

```text
14331
14332
14333
```

Falls belegt:

```text
Ports bereits verwendet.

Alternative:
14341-14343 verwenden?
```

---

# 10. .env Behandlung

Deine Aussage ist richtig:

> `.env` darf überschrieben werden

Ich würde trotzdem unterscheiden:

## Erste Installation

```text
.env nicht vorhanden
→ erzeugen
```

## Vorhanden

```text
.env existiert

[1] Werte übernehmen
[2] überschreiben
[3] abbrechen
```

Denn dort steht das Passwort.

---

# Meine daraus abgeleiteten Anforderungen an QuickStart

Ich würde diese als feste Designregeln dokumentieren:

| Regel                      | Umsetzung                       |
| -------------------------- | ------------------------------- |
| Keine Überschreibung       | Zielpfadprüfung                 |
| Kein Systempfad            | Blocklist                       |
| Ein Laufwerk erlaubt       | Fallback                        |
| Mehrere Laufwerke nutzen   | optional                        |
| Secrets lokal              | `.env`                          |
| Docker isoliert            | eigener Namensraum              |
| Cleanup sicher             | Scope-basiert                   |
| Wiederholbare Installation | State-Datei                     |
| Fehler rückrollbar         | kein "halb installiert" Zustand |

---

## Eine weitere Anwendungsmöglichkeit würde ich noch ergänzen:

**Schulung / Demo-Systeme.**

Dafür sollte es einen Modus geben:

```text
Installationstyp:

[1] Entwickler/Test
[2] Schulung/Demo
[3] Performance-Test
```

Denn die Anforderungen unterscheiden sich:

* Schulung:

  * wenig Ressourcen
  * einfache Installation

* Performance:

  * getrennte SSDs
  * maximale Ressourcen

* Entwicklung:

  * schnelle Neustarts
  * Debug-Informationen

---

Damit wäre der QuickStart tatsächlich ein eigenständiges, professionelles Einstiegssystem und nicht nur ein vereinfachtes LAB-Script. Das ist aus meiner Sicht die richtige Ergänzung zum bestehenden LAB-Framework.



