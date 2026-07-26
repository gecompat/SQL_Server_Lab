# SQL_Server_Lab – Getting Started

## Voraussetzungen

- PowerShell 7.2 oder hoeher (`pwsh`)
- Docker Desktop oder Docker Engine (laufend)
- Mindestens 4 GB freier RAM
- Mindestens 5 GB freier Speicherplatz

### PowerShell-Version pruefen

```powershell
$PSVersionTable.PSVersion
# Erwartet: 7.2 oder hoeher
```

### Docker pruefen

```powershell
docker info
# Muss ohne Fehler antworten
```

---

## 1. Repository clonen (falls noch nicht geschehen)

```powershell
cd E:\GIT\gecomp\publ
git clone https://github.com/gecompat/SQL_Server_Lab.git
```

---

## 2. Modul importieren

```powershell
cd E:\GIT\gecomp\publ\SQL_Server_Lab
Import-Module .\SqlServerLab.psd1 -Force
```

Erfolgsmeldung (Verbose):

```text
VERBOSE: SqlServerLab v0.1.0 geladen. Provider: docker
```

---

## 3. Schnelltest: Eine SQL-Server-Instanz erstellen

```powershell
$lab = New-SqlServerLab -Version '2025' -Provider Docker
```

Das Cmdlet:

1. Prueft Ressourcen (RAM, Storage, Ports, Docker)
2. Fragt das SA-Passwort ab (Komplexitaetsanforderungen: 8+ Zeichen, Gross/Klein/Zahl/Sonderzeichen)
3. Erstellt einen Docker-Container mit SQL Server 2025
4. Wartet bis SQL Server antwortet (max 120 Sekunden)
5. Gibt Verbindungsinformationen aus

### Erwartete Ausgabe

```text
============================================================
  SQL Server Lab - Neue Umgebung
============================================================

[INFO]    Umgebung: adhoc-2025-docker (1 Instanz(en))
[INFO]    Resource Assessment...
  Provider                RESOURCE_OK: Docker verfuegbar (Version: 27.x)
  RAM                     RESOURCE_OK: Frei: 12000MB, Benoetigt: 4096MB
  Storage                 RESOURCE_OK: Frei: 80GB, Geschaetzt: 2GB
  Ports                   RESOURCE_OK: Verfuegbar: 1, Benoetigt: 1
[INFO]    SA-Passwort wird benoetigt.
SA-Passwort: ********
SA-Passwort bestaetigen: ********
  RunId                   a1b2c3d4-...
  ScopeId                 e5f6g7h8-...
[INFO]    Instanz 'primary' erstellen (2025, docker)...
[INFO]    Container erstellen: sql-lab-primary-a1b2c3d4 (Port 14330, Image mcr.microsoft.com/mssql/server:2025-latest)
[INFO]    Warte auf SQL-Bereitschaft (127.0.0.1:14330, Timeout: 120s)...
[OK]      SQL Server bereit nach 12.3s (Major: 17)

============================================================
  Umgebung bereit
============================================================

  RunId                   a1b2c3d4-...
  primary                 127.0.0.1:14330 (SQL 2025)
```

---

## 4. Mit der Instanz arbeiten

### Verbindung via SSMS, Azure Data Studio oder sqlcmd

```text
Server:   127.0.0.1,14330
Login:    sa
Passwort: (das soeben gesetzte)
```

### Datenbank anlegen (mit mehreren Data Files)

```powershell
$pw = $lab  # Passwort nochmal eingeben oder aus Variable
# Passwort als SecureString:
$pw = Read-Host 'SA-Passwort' -AsSecureString

New-LabDatabase -Port $lab.Instances[0].Port -SaPassword $pw `
    -DatabaseName 'MeineTestDB' `
    -DataFiles @(
        @{ name = 'Test_Data1'; sizeMB = 100 },
        @{ name = 'Test_Data2'; sizeMB = 100 }
    ) `
    -LogFiles @(
        @{ name = 'Test_Log'; sizeMB = 50 }
    )
```

### T-SQL-Skript ausfuehren

```powershell
Invoke-LabScript -ScriptPath '.\mein-skript.sql' `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -Database 'MeineTestDB'
```

---

## 5. Manifest-Modus (deklarativ)

Erstelle eine Datei `mein-lab.json`:

```json
{
  "name": "mein-erstes-lab",
  "instances": [
    {
      "id": "primary",
      "version": "2025",
      "provider": "docker",
      "databases": [
        {
          "name": "AppDB",
          "files": {
            "data": [
              { "name": "App_Data1", "sizeMB": 200 },
              { "name": "App_Data2", "sizeMB": 200 }
            ],
            "log": [
              { "name": "App_Log", "sizeMB": 100 }
            ]
          }
        }
      ],
      "postProvision": ["setup.sql"]
    }
  ]
}
```

Ausfuehren:

```powershell
$lab = New-SqlServerLab -Manifest '.\mein-lab.json'
```

---

## 6. Umgebung entfernen

```powershell
Remove-SqlServerLab -RunId $lab.RunId
```

Oder ohne RunId (entfernt den letzten aktiven Run):

```powershell
Remove-SqlServerLab
```

Das Cmdlet:

1. Zeigt die zu entfernende Umgebung
2. Fragt nach Bestaetigung
3. Stoppt und entfernt den Container (nur eigene, Scope-geprueft)
4. Loescht Secrets sicher
5. Bereinigt den State

---

## 7. Ressourcen-Pruefung (ohne Mutation)

```powershell
Test-LabResources -Provider docker
```

Zeigt an ob genuegend RAM, Storage, Ports und Docker verfuegbar sind — ohne etwas zu veraendern.

---

## 8. Umgebungsvariablen (optional)

| Variable | Zweck | Beispiel |
| --- | --- | --- |
| `SQL_SERVER_LAB_PATH` | Modul-Pfad fuer Auto-Import | `E:\GIT\gecomp\publ\SQL_Server_Lab` |
| `SQL_SERVER_LAB_STATE` | State-Verzeichnis (Default: LocalAppData) | `C:\LabState` |

---

## 9. Troubleshooting

### Docker antwortet nicht

```powershell
docker info
# Falls Fehler: Docker Desktop starten oder Docker-Service neustarten
```

### SA-Passwort wird abgelehnt

SQL Server erfordert mindestens:
- 8 Zeichen
- Grossbuchstabe + Kleinbuchstabe + Ziffer + Sonderzeichen

### Container startet aber SQL antwortet nicht

```powershell
# Container-Logs pruefen:
docker logs sql-lab-primary-<runid-prefix>
```

### Port bereits belegt

Das Lab sucht automatisch im Bereich 14330-14399. Falls alle belegt:

```powershell
# Existierende Lab-Container anzeigen:
docker ps --filter 'label=sql-server-lab.run-id'
```

---

## 10. Naechste Schritte

- Eigene Manifeste fuer wiederkehrende Szenarien erstellen
- `postProvision`-Skripte fuer automatische Datenbank-Einrichtung nutzen
- Aus SQL_Server_Analyze oder SQL_PerformanceSchulung per Adapter aufrufen

---

## 11. Alle Lab-Container aufraeumen (Clear-SqlServerLab)

Falls Container von abgebrochenen Tests oder vergessenen Sessions uebrig sind:

```powershell
# Zeigt alle Lab-Container und fragt nach Bestaetigung:
Clear-SqlServerLab

# Ohne Rueckfrage (z.B. in Skripten):
Clear-SqlServerLab -Force

# Nur Container entfernen, State behalten:
Clear-SqlServerLab -ContainersOnly

# Nur verwaiste State-Eintraege bereinigen:
Clear-SqlServerLab -StateOnly
```

Das Cmdlet findet Container ueber das Docker-Label `sql-server-lab.run-id` — damit werden
ausschliesslich Lab-Container erkannt, keine anderen Docker-Container.

---

## 12. Integration-Tests (Smoke-Test)

Der automatisierte End-to-End-Test prueft den gesamten Lifecycle:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1
```

Testet: Import -> Assessment -> New-SqlServerLab -> New-LabDatabase ->
Invoke-LabScript -> Remove-SqlServerLab (20 Assertions, ~20 Sekunden).

### Optionen

| Parameter | Wirkung |
| --- | --- |
| `-SaPassword $pw` | Eigenes Passwort (Default: `SmokeTest_Pwd1!`) |
| `-Version '2022'` | Andere SQL-Server-Version testen |
| `-KeepOnFailure` | Container bei Fehler stehen lassen (Debugging) |

### Exit-Code

- `0` = alle Tests bestanden
- `1` = mindestens ein Test fehlgeschlagen

Geeignet fuer CI/CD-Integration.

---

## 13. Debugging

### SA-Passwort aus State lesen

```powershell
Import-Module .\SqlServerLab.psd1 -Force

# Alle aktiven Runs anzeigen:
$runs = Get-LabActiveRuns
$runs | Format-Table runId, state, metadata

# SA-Passwort eines Runs lesen (SecureString):
$stateRoot = Get-LabStateRoot
$secret = Get-LabSecret -Path (Join-Path $stateRoot "runs/$($runs[0].runId)") -Name 'sa-password'

# Als Klartext (nur Debugging!):
[System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))
```

### State-Verzeichnis

Das State-Verzeichnis liegt unter:
- **Windows:** `$env:LOCALAPPDATA\SqlServerLab` (z.B. `C:\Users\<user>\AppData\Local\SqlServerLab`)
- **Linux:** `~/.sql-server-lab`

Struktur pro Run:
```text
SqlServerLab/
  runs/
    <RunId>/
      run-state.json        # State-Machine-Historie (JSON)
      cleanup-plan.json     # Was bei Remove entfernt wird
      connection-info.json  # Host, Port, Container
      secrets/
        sa-password.xml     # DPAPI-verschluesselt (nur eigener User lesbar)
```

### Container-Logs

```powershell
# Container-Name aus $lab.Instances[0].ContainerName oder:
docker ps --filter 'label=sql-server-lab.run-id'

# Logs anzeigen:
docker logs sql-lab-primary-<runid-prefix>
docker logs sql-lab-primary-<runid-prefix> --tail 50 --follow
```

### Direkter SQL-Zugang (sqlcmd)

```powershell
sqlcmd -S 127.0.0.1,14330 -U sa -P "MeinPasswort"
```

### Manuelles Aufraeumen

```powershell
# Ueber Modul:
Remove-SqlServerLab -RunId '<RunId>' -Force
# Oder alles:
Clear-SqlServerLab -Force

# Direkt per Docker (Notfall):
docker rm -f sql-lab-primary-<prefix>
```

---

## 14. Entwickler-Hinweise

### Import-Module -Force

Bei Code-Aenderungen muss das Modul mit `-Force` neu geladen werden:

```powershell
Import-Module .\SqlServerLab.psd1 -Force
```

Ohne `-Force` bleibt die alte Version im Speicher (PowerShell cached Module).

### Bekannte Einschraenkungen

| Thema | Status | Workaround |
| --- | --- | --- |
| Major-Version = 0 (statt 17) | Kosmetisch | Kein Workaround noetig, SQL funktioniert |
| `USE Database` in Invoke-LabScript | Design | `-Database` Parameter verwenden (jeder Batch = neue Connection) |
| System.Data.SqlClient | Fallback auf sqlcmd | sqlcmd muss installiert sein (im SQL Server Tools enthalten) |

### Invoke-LabScript und GO-Batches

`Invoke-LabScript` splittet SQL-Skripte am `GO`-Befehl und fuehrt jeden Batch
in einer **eigenen Connection** aus. Das bedeutet:

- `USE DatabaseName` wirkt nur im selben Batch
- Stattdessen: `-Database 'MeineDB'` als Parameter verwenden
- Temp-Tabellen (`#tmp`) existieren nur innerhalb eines Batches

---

## 15. Cmdlet-Uebersicht

| Cmdlet | Zweck |
| --- | --- |
| `New-SqlServerLab` | Neue Lab-Umgebung erstellen (Ad-hoc oder Manifest) |
| `Remove-SqlServerLab` | Einzelne Umgebung gezielt entfernen |
| `Clear-SqlServerLab` | Alle Lab-Container + State aufraeumen |
| `New-LabDatabase` | Datenbank mit Multi-File-Specs erstellen |
| `Invoke-LabScript` | T-SQL-Skript ausfuehren (GO-Batch-Splitting) |
| `Test-LabResources` | Ressourcen pruefen ohne Mutation |
| `Get-SqlServerLab` | *(geplant)* Status anzeigen |
| `Start-SqlServerLab` | *(geplant)* Gestoppte Umgebung starten |
| `Stop-SqlServerLab` | *(geplant)* Laufende Umgebung stoppen |
