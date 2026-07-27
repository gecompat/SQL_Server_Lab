# SQL_Server_Lab – Getting Started

## Ziel

Diese Anleitung führt vom leeren Arbeitsverzeichnis bis zu einer erreichbaren SQL-Server-Testinstanz und anschließend durch Datenbankerstellung, Restore, Skriptausführung und Cleanup.

Für Architektur und Entwicklungsregeln siehe [Dokumentationsübersicht](../README.md). Aktuelle Einschränkungen stehen in [KNOWN_LIMITATIONS.md](../Quality/KNOWN_LIMITATIONS.md).

## 1. Voraussetzungen

Erforderlich:

- PowerShell 7.2 oder neuer
- Docker oder Podman
- mindestens 4 GB freier RAM
- mindestens 5 GB freier Speicherplatz
- `sqlcmd` für Datenbankoperationen und den vollständigen Smoke-Test

Prüfen:

```powershell
$PSVersionTable.PSVersion

docker info
# oder
podman info

sqlcmd -?
```

Mindestens eine Container-Runtime muss ohne Fehler antworten.

## 2. Repository beziehen

```powershell
git clone https://github.com/gecompat/SQL_Server_Lab.git
Set-Location .\SQL_Server_Lab
```

Es werden keine festen lokalen Laufwerks- oder Benutzerpfade vorausgesetzt.

## 3. Modul importieren

```powershell
Import-Module .\SqlServerLab.psd1 -Force
```

Öffentliche Cmdlets prüfen:

```powershell
Get-Command -Module SqlServerLab | Sort-Object Name
```

Die autoritative Exportliste steht in `SqlServerLab.psd1`.

## 4. Ressourcen prüfen

Docker:

```powershell
Test-LabResources -Provider docker
```

Podman:

```powershell
Test-LabResources -Provider podman
```

Die Prüfung erzeugt keine Container. Sie bewertet unter anderem Runtime-Verfügbarkeit, RAM, Storage und Ports.

## 5. Erste Instanz erstellen

Docker:

```powershell
$lab = New-SqlServerLab -Version '2025' -Provider docker
```

Podman:

```powershell
$lab = New-SqlServerLab -Version '2025' -Provider podman
```

Interaktiv:

```powershell
Invoke-SqlServerLab
```

Das Cmdlet:

1. löst Version und Ressourcenprofil auf;
2. führt das Resource Assessment aus;
3. fragt das SA-Passwort ab, sofern keines übergeben wurde;
4. erzeugt Run-State und Cleanup-Plan;
5. startet den Container;
6. wartet auf SQL-Bereitschaft;
7. führt optional Server-, Datenbank-, Restore- und Post-Provision-Schritte aus;
8. speichert `connection-info.json` und liefert ein Ergebnisobjekt zurück.

## 6. Ergebnisobjekt verstehen

```powershell
$lab | Format-List
$lab.Instances | Format-List
```

Wichtige Werte:

```powershell
$lab.RunId
$lab.State
$lab.StateRoot
$lab.Instances[0].Provider
$lab.Instances[0].Host
$lab.Instances[0].Port
$lab.Instances[0].ContainerName
$lab.Instances[0].ConnectionString
```

Der Port wird standardmäßig im Bereich `14330` bis `14399` automatisch vergeben.

## 7. Verbindung mit SSMS

Beispiel:

```text
Server name: 127.0.0.1,14330
Authentication: SQL Server Authentication
Login: sa
Password: das bei der Erstellung gesetzte Passwort
Trust server certificate: aktiviert
```

Verwenden Sie den tatsächlich in `$lab.Instances[0].Port` zurückgegebenen Port.

Mit `sqlcmd`:

```powershell
sqlcmd -S "127.0.0.1,$($lab.Instances[0].Port)" -U sa -C
```

Das Passwort wird von `sqlcmd` interaktiv abgefragt, wenn `-P` nicht angegeben wird.

## 8. Datenbank erstellen

```powershell
$pw = Read-Host 'SA-Passwort' -AsSecureString

New-LabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -DatabaseName 'MeineTestDB'
```

Mehrere Dateien auf dem Standardpfad:

```powershell
New-LabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -DatabaseName 'MehrdateiDB' `
    -DataFiles @(
        @{ name = 'MehrdateiDB_Data1'; sizeMB = 100; filegrowthMB = 64 },
        @{ name = 'MehrdateiDB_Data2'; sizeMB = 100; filegrowthMB = 64 }
    ) `
    -LogFiles @(
        @{ name = 'MehrdateiDB_Log'; sizeMB = 50; filegrowthMB = 32 }
    )
```

Dateien auf gemounteten Containerpfaden:

```powershell
New-LabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -DatabaseName 'StorageDemo' `
    -DataFiles @(
        @{ name = 'StorageDemo_Data'; path = '/sqldata/StorageDemo_Data.mdf'; sizeMB = 256 }
    ) `
    -LogFiles @(
        @{ name = 'StorageDemo_Log'; path = '/sqllog/StorageDemo_Log.ldf'; sizeMB = 128 }
    )
```

Die Pfade müssen über `drives` im Manifest als Volumes bereitgestellt worden sein.

## 9. T-SQL-Skript ausführen

```powershell
Invoke-LabScript `
    -ScriptPath '.\setup.sql' `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -Database 'MeineTestDB'
```

Das Cmdlet unterstützt `GO`-getrennte Batches.

## 10. Backup wiederherstellen

### Lokale `.bak`-Datei

```powershell
Restore-LabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -BackupSource 'C:\Backups\AdventureWorks2022.bak' `
    -DatabaseName 'AdventureWorks2022' `
    -ContainerName $lab.Instances[0].ContainerName
```

### HTTPS-URL

```powershell
Restore-LabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -BackupSource 'https://example.invalid/database.bak' `
    -DatabaseName 'RestoreDemo' `
    -ContainerName $lab.Instances[0].ContainerName
```

Die Beispiel-URL ist absichtlich nicht ausführbar. Verwenden Sie eine zulässige reale `.bak`-Quelle.

`Restore-LabDatabase` unterstützt die Parameter `Port`, `SaPassword`, `BackupSource`, `DatabaseName` und optional `ContainerName`. Es besitzt keine Parameter `RunId` oder `BackupUrl`.

## 11. Manifest-Modus

Datei `mein-lab.json`:

```json
{
  "$schema": "./Schemas/lab-manifest.schema.json",
  "name": "mein-erstes-lab",
  "instances": [
    {
      "id": "primary",
      "version": "2025",
      "provider": "docker",
      "profile": "standard",
      "databases": [
        {
          "name": "AppDB",
          "options": {
            "recoveryModel": "FULL",
            "queryStore": true,
            "rcsi": true
          }
        }
      ]
    }
  ]
}
```

Ausführen:

```powershell
$lab = New-SqlServerLab -Manifest '.\mein-lab.json'
```

Relative Pfade für lokale Restore-Dateien, `hostPath` und `postProvision` werden relativ zum Manifest-Verzeichnis aufgelöst.

## 12. Manifest-Restore

```json
{
  "$schema": "./Schemas/lab-manifest.schema.json",
  "name": "restore-lab",
  "instances": [
    {
      "id": "primary",
      "version": "2022",
      "provider": "docker",
      "databases": [
        {
          "name": "AdventureWorks2022",
          "restore": {
            "source": "C:\\Backups\\AdventureWorks2022.bak",
            "replace": true
          }
        }
      ]
    }
  ]
}
```

Eine Restore-Datenbank wird nicht zuerst per `CREATE DATABASE` angelegt. Nach erfolgreichem Restore werden konfigurierte Datenbankoptionen angewendet.

## 13. Sample-Datenbank aus dem Katalog

```json
{
  "$schema": "./Schemas/lab-manifest.schema.json",
  "name": "sample-lab",
  "instances": [
    {
      "id": "primary",
      "version": "2022",
      "provider": "docker",
      "databases": [
        {
          "name": "AdventureWorks2022",
          "sample": {
            "id": "adventureworks-2022",
            "variant": "full"
          }
        }
      ]
    }
  ]
}
```

Unterstützt werden derzeit nur Katalogvarianten, deren URL direkt auf eine `.bak`-Datei zeigt. `.7z`-Archive, Attach-Verfahren und reine SQL-Skript-Samples werden nicht automatisch verarbeitet.

## 14. Server- und Datenbankkonfiguration

Ausgeführt werden derzeit insbesondere:

- `serverConfig.memory`
- `serverConfig.tempdb`
- `serverConfig.maxDop`
- `serverConfig.costThreshold`
- `serverConfig.traceFlags`
- `serverConfig.spConfigure`
- `serverConfig.externalScripts` mit den dokumentierten Einschränkungen
- Datenbankoptionen wie Recovery Model, Compatibility Level, Query Store, RCSI und PAGE_VERIFY

Ein ausführbares Performance-Beispiel liegt in `Schemas/example-performance-lab.json`.

Felder, die nur als Zukunftsvertrag vorhanden sind, werden in [KNOWN_LIMITATIONS.md](../Quality/KNOWN_LIMITATIONS.md) aufgeführt.

## 15. Status und Lifecycle

```powershell
Get-SqlServerLab
Get-SqlServerLab -RunId $lab.RunId -Detailed

Stop-SqlServerLab -RunId $lab.RunId
Start-SqlServerLab -RunId $lab.RunId
Restart-SqlServerLab -RunId $lab.RunId
```

Der gespeicherte Provider wird für Start, Stop und Live-Status verwendet. Bei gleichzeitig installiertem Docker und Podman bleibt der Run an seinen ursprünglichen Provider gebunden.

## 16. Umgebung entfernen

```powershell
Remove-SqlServerLab -RunId $lab.RunId
```

Alle erkannten Lab-Reste bereinigen:

```powershell
Clear-SqlServerLab
```

Vor destruktiven Aktionen wird – abhängig vom Cmdlet und den verwendeten Schaltern – eine Bestätigung verlangt.

## 17. State-Verzeichnis

Standard:

- Windows: `%LOCALAPPDATA%\SqlServerLab`
- Linux/macOS: `~/.sql-server-lab`

Override:

```powershell
$env:SQL_SERVER_LAB_STATE = 'C:\SqlServerLabState'
```

Es gibt keine implementierte Environment Variable `SQL_SERVER_LAB_PATH`.

Im State liegen unter anderem:

```text
runs/<RunId>/run-state.json
runs/<RunId>/cleanup-plan.json
runs/<RunId>/connection-info.json
runs/<RunId>/secrets/
cache/backups/
```

State, Secrets, konkrete Hostpfade und Connection Information dürfen nicht in Git übernommen werden.

## 18. Smoke-Test

Docker:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
```

Podman:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Auto-Modus:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
```

Im Auto-Modus wird für den mutierenden Lifecycle genau eine Runtime gewählt: zuerst Docker, sonst Podman. Das Resource Assessment prüft zusätzlich alle erkannten Provider.

## 19. Statische Konsistenzprüfung

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Die Prüfung kontrolliert unter anderem Exportliste, Kernlinks, Schema-Referenzen, JSON-Dateien, Provider-Metadaten und bekannte veraltete Dokumentationsbeispiele.

## 20. Troubleshooting

### Modul importiert nicht

```powershell
Import-Module .\SqlServerLab.psd1 -Force -Verbose
Get-Error
```

### Docker oder Podman ist nicht erreichbar

```powershell
docker info
podman info
```

Unter Windows oder macOS muss bei Podman gegebenenfalls zuerst die Podman Machine gestartet werden.

### SQL Server startet, ist aber nicht erreichbar

```powershell
docker ps -a --filter 'label=sql-server-lab.run-id'
docker logs <ContainerName>

# oder
podman ps -a --filter 'label=sql-server-lab.run-id'
podman logs <ContainerName>
```

Prüfen Sie den tatsächlich vergebenen Host-Port aus `$lab.Instances[0].Port`.

### SA-Passwort wird abgelehnt

SQL Server verlangt ein ausreichend komplexes Passwort. Verwenden Sie Groß- und Kleinbuchstaben, Ziffern und Sonderzeichen.

### Restore findet den falschen Container

Geben Sie bei manuellen Restores `-ContainerName $lab.Instances[0].ContainerName` explizit an.

### Manifestfeld wird nicht angewendet

Prüfen Sie zuerst:

1. `Schemas/lab-manifest.schema.json`
2. `Private/ManifestParser.ps1`
3. die zuständige Ausführungsfunktion
4. `Documentation/Quality/KNOWN_LIMITATIONS.md`

Das Schema allein ist kein Runtime-Nachweis.
