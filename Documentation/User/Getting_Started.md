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

Modulübersicht und Hilfe zu einzelnen Cmdlets:

```powershell
Get-Help about_SqlServerLab
Get-Help New-SqlServerLab -Full
Get-Help Test-SqlServerLabManifest -Parameter Path
```

Die autoritative Exportliste steht in `SqlServerLab.psd1`. `Get-Command` zeigt
für jeden Export in `ModuleName` und `Source` die Zuordnung zu `SqlServerLab`.
Bei einem Namenskonflikt ist der modulqualifizierte Aufruf eindeutig, zum
Beispiel `SqlServerLab\New-SqlServerLabDatabase`.

## 4. Ressourcen prüfen

Docker:

```powershell
Test-SqlServerLabPrerequisite -Provider docker
```

Podman:

```powershell
Test-SqlServerLabPrerequisite -Provider podman
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

New-SqlServerLabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -DatabaseName 'MeineTestDB'
```

Mehrere Dateien auf dem Standardpfad:

```powershell
New-SqlServerLabDatabase `
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
New-SqlServerLabDatabase `
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
Invoke-SqlServerLabScript `
    -ScriptPath '.\setup.sql' `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -Database 'MeineTestDB'
```

Das Cmdlet unterstützt `GO`-getrennte Batches.

## 10. Backup wiederherstellen

### Lokale `.bak`-Datei

```powershell
Restore-SqlServerLabDatabase `
    -RunId $lab.RunId `
    -InstanceId 'primary' `
    -SaPassword $pw `
    -BackupSource 'C:\Backups\AdventureWorks2022.bak' `
    -DatabaseName 'AdventureWorks2022'
```

### HTTPS-URL

```powershell
Restore-SqlServerLabDatabase `
    -Port $lab.Instances[0].Port `
    -SaPassword $pw `
    -BackupSource 'https://example.invalid/database.bak' `
    -DatabaseName 'RestoreDemo' `
    -ContainerName $lab.Instances[0].ContainerName
```

Die Beispiel-URL ist absichtlich nicht ausführbar. Verwenden Sie eine zulässige reale `.bak`-Quelle.

`Restore-SqlServerLabDatabase` unterstützt bevorzugt `RunId` und optional
`InstanceId`; Provider, Container, Host und Port werden aus dem lokalen
Run-State gelesen. Alternativ bleibt der direkte Modus mit `Port` und optional
`Provider` sowie `ContainerName` verfügbar. Einen Parameter `BackupUrl` gibt es
nicht; URLs werden über `BackupSource` angegeben.

## 11. Manifest-Modus

### Manifest interaktiv erstellen

```powershell
New-SqlServerLabManifest -Path '.\mein-lab.json'
```

Der Konsolen-Wizard basiert direkt auf `Schemas/lab-manifest.schema.json`. Er
ermöglicht damit auch verschachtelte Optionen, Arrays, freie
`spConfigure`-Schlüssel und die detaillierte Query-Store-Konfiguration. Typen,
Enums, Muster und Wertebereiche werden bereits bei der Eingabe geprüft.

Der gleiche Einstieg ist im Hauptmenü über `m` verfügbar:

```powershell
Invoke-SqlServerLab -Action Manifest
```

Ein Manifest separat prüfen:

```powershell
$validation = Test-SqlServerLabManifest -Path '.\mein-lab.json'
$validation | Format-List
```

### `Test-SqlServerLabManifest` im Detail

Das Cmdlet besitzt zwei alternative Eingabewege:

```powershell
Test-SqlServerLabManifest [-Path] <String> [-Quiet]
Test-SqlServerLabManifest -InputObject <Object> [-Quiet]
```

Allgemeine PowerShell-Parameter wie `-Verbose`, `-Debug` und
`-ErrorAction` stehen zusätzlich zur Verfügung.

#### Parameter `Path`

`-Path` bezeichnet **genau eine bereits vorhandene Manifestdatei**. Der
Parameter ist im Parametersatz `Path` obligatorisch, akzeptiert einen String
und kann wegen `Position = 0` auch ohne Parameternamen angegeben werden:

```powershell
Test-SqlServerLabManifest '.\mein-lab.json'
```

Für den Pfad gelten folgende Regeln:

- Relative Pfade werden gegen das aktuelle PowerShell-Verzeichnis (`$PWD`)
  aufgelöst.
- Absolute Pfade sind zulässig, beispielsweise
  `C:\Lab Manifeste\vergleich.json`.
- Der Pfad wird mit `-LiteralPath` behandelt. Zeichen wie `*`, `?` und `[` sind
  daher Bestandteil des Dateinamens und keine Wildcards.
- Der Pfad muss auf eine Datei zeigen. Verzeichnisse, URLs und mehrere Pfade
  werden nicht akzeptiert.
- Eine bestimmte Dateiendung wird technisch nicht verlangt. Der Dateiinhalt
  muss jedoch gültiges UTF-8-JSON sein und dem Lab-Manifest-Schema entsprechen.
- `-Path` besitzt keinen Default. Ohne `-Path` muss `-InputObject` verwendet
  werden.

Der Speicherort der Manifestdatei bestimmt außerdem den Bezugspunkt für lokale
relative Pfade **im Manifest**:

```json
{
  "name": "relative-pfade",
  "instances": [
    {
      "id": "primary",
      "version": "2025",
      "databases": [
        {
          "name": "AppDB",
          "restore": { "source": ".\\backups\\AppDB.bak" }
        }
      ],
      "postProvision": [".\\sql\\setup.sql"]
    }
  ]
}
```

Liegt dieses Manifest unter `C:\Labs\mein-lab.json`, prüft das Cmdlet die
Dateien `C:\Labs\backups\AppDB.bak` und `C:\Labs\sql\setup.sql`. Ein relativer
`hostPath` wird bei der späteren Manifestauflösung ebenfalls auf dieses
Verzeichnis bezogen, seine Existenz wird von `Test-SqlServerLabManifest` derzeit jedoch
nicht geprüft.

#### Parameter `InputObject`

`-InputObject` prüft einen Manifestentwurf ohne vorherige Datei. Zulässig sind
beispielsweise Hashtables, geordnete Hashtables und `PSCustomObject`-Instanzen:

```powershell
$draft = [ordered]@{
    name = 'minimal'
    instances = @(
        [ordered]@{
            id = 'primary'
            version = '2025'
        }
    )
}

$validation = $draft | Test-SqlServerLabManifest
```

Der Parameter ist obligatorisch, akzeptiert Pipelineeingaben und gehört zu
einem eigenen Parametersatz. `-Path` und `-InputObject` können daher nicht
gemeinsam verwendet werden. Das Objekt wird zur Prüfung über JSON normalisiert;
das Originalobjekt wird nicht verändert. Da kein Manifestverzeichnis existiert,
werden lokale relative Restore- und Skriptpfade gegen `$PWD` geprüft.

#### Parameter `Quiet`

Ohne `-Quiet` gibt das Cmdlet ein Ergebnisobjekt zurück:

| Eigenschaft | Typ | Bedeutung |
|---|---|---|
| `IsValid` | `Boolean` | `True`, wenn keine Validierungsfehler gefunden wurden |
| `Errors` | `String[]` | Schema-, Katalog-, Pfad- und fachliche Fehler |
| `Warnings` | `String[]` | Risiken oder akzeptierte Felder mit eingeschränkter Runtime-Unterstützung |

Mit `-Quiet` wird ausschließlich `True` oder `False` zurückgegeben. Der Switch
ist standardmäßig ausgeschaltet:

```powershell
if (-not (Test-SqlServerLabManifest -Path '.\mein-lab.json' -Quiet)) {
    throw 'Das Lab-Manifest ist ungültig.'
}
```

Warnungen allein machen ein Manifest nicht ungültig. `IsValid = False`
verhindert dagegen die Verwendung durch den Manifest-Provisionierungspfad.

#### Was wird geprüft?

Die Prüfung erzeugt keine Container, VMs, Datenbanken oder State-Dateien. Sie
umfasst derzeit:

1. JSON-Syntax und Validierung gegen `Schemas/lab-manifest.schema.json`;
2. Pflichtfelder, Datentypen, Enums, Muster, Wertebereiche und unbekannte
   Eigenschaften;
3. eindeutige Instanz-IDs, Datenbanknamen, Drive-IDs und logische Dateinamen;
4. SQL-Versionen und zugehörige Container-Images aus dem Versionskatalog;
5. Providergrenzen, Betriebssystemkombinationen und gemischte Provider;
6. Compatibility Level im Verhältnis zur SQL-Server-Version;
7. lokale Restore-Dateien, Restore-Typen und Sample-Katalogvarianten;
8. vorhandene `postProvision`-Skripte;
9. fachliche Beziehungen wie `minMB <= maxMB` und alternative
   Dateiwachstumsangaben;
10. riskante SQL-Optionen und Schemafelder, die von der Runtime noch nicht
    zuverlässig oder vollständig angewendet werden.

Nicht geprüft werden unter anderem Runtime-Erreichbarkeit, freie Ports,
Kennwörter, Hostressourcen, Download-Erfolg, SQL-Berechtigungen und der Erfolg
der späteren T-SQL-Ausführung. Dafür sind Resource Assessment,
Provisionierung und Smoke-Test zuständig.

#### Defaults und Normalisierung

`Test-SqlServerLabManifest` ergänzt **keine** fehlenden Manifestwerte. Ein `default` im
JSON-Schema ist zunächst Schema- und Wizard-Metadatum; die JSON-Schema-Prüfung
materialisiert diesen Wert nicht. Auch das Ergebnisobjekt enthält kein
normalisiertes Manifest.

Erst `New-SqlServerLab -Manifest` liest ein gültiges Manifest ein und löst die
aktuell implementierten Runtime-Defaults auf. Zu den wichtigsten gehören:

| Manifestfeld | Effektiver Framework-Default bei fehlender Angabe |
|---|---|
| `instances[].provider` | automatische Auswahl: normalerweise `docker`; bei Windows oder GUI-Software wäre `hyperv` erforderlich, ist aber noch nicht implementiert |
| `instances[].os` | `linux` |
| `instances[].profile` | `standard` |
| `instances[].collation` | `SQL_Latin1_General_CP1_CS_AS` |
| `databases[].collation` | Collation der Instanz |
| gesamtes `databases[].options` fehlt | `{ "queryStore": true }` |
| gesamte Dateidefinition fehlt | eine Data-Datei mit 64/64 MB und eine Log-Datei mit 32/32 MB für Größe/Wachstum |
| Werte einer expliziten Datei fehlen | `sizeMB = 64`, `filegrowthMB = 64` |
| `databases[].restore.type` | `auto` |
| `databases[].restore.replace` | `true` |
| `databases[].sample.variant` | `full` |
| `drives[].type` | `auto` |
| `serverConfig.maxDop` | `0`, sofern `serverConfig` vorhanden ist |
| `serverConfig.costThreshold` | `5`, sofern `serverConfig` vorhanden ist |
| `serverConfig.tempdb.equalSize` | `true`, sofern `tempdb` vorhanden ist |
| `software[].optional` | `true` |

Wichtig: Ist `databases[].options` vorhanden, werden fehlende Unterfelder nicht
pauschal aus allen `default`-Angaben des Schemas ergänzt. Es werden nur
tatsächlich gelieferte Optionen ausgeführt. Schema-Defaults für vorbereitete,
aber noch nicht zuverlässig implementierte Felder sind ebenfalls keine
Runtime-Zusage; `Warnings` macht solche Fälle sichtbar.

#### Fehlerverhalten

Ein nicht vorhandener `-Path` oder ein Pfad auf ein Verzeichnis erzeugt einen
terminierenden PowerShell-Fehler. Syntaktisch ungültiges JSON wird dagegen als
reguläres ungültiges Prüfergebnis zurückgegeben: `IsValid = False` und ein mit
`JSON:` beginnender Eintrag in `Errors`; mit `-Quiet` lautet das Ergebnis
`False`. Schema- und Fachfehler werden gesammelt, soweit die vorherige
Prüfstufe eine weitere Analyse erlaubt.

Die vollständige, direkt aus PowerShell abrufbare Parameterhilfe zeigt:

```powershell
Get-Help Test-SqlServerLabManifest -Full
Get-Command Test-SqlServerLabManifest -Syntax
```

### Manifest manuell schreiben

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

Automatisch unterstützt werden nur Katalogvarianten, deren URL direkt auf eine
`.bak`-Datei zeigt, die `runtimeStatus: executable` tragen und eine verifizierte
SHA-256-Pruefsumme besitzen. Die aktuellen Varianten sind bis zu einer
kontrollierten Artefaktverifikation beschreibend. `.7z`-Archive,
Attach-Verfahren und reine SQL-Skript-Samples werden ebenfalls nicht automatisch
verarbeitet.

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
