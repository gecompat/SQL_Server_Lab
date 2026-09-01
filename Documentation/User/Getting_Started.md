# SQL_Server_Lab – Getting Started

## Ziel

Diese Anleitung führt vom leeren Arbeitsverzeichnis bis zu einer erreichbaren SQL-Server-Testinstanz und anschließend durch Datenbankerstellung, Restore, Skriptausführung und Cleanup.

Für Architektur und Entwicklungsregeln siehe [Dokumentationsübersicht](../README.md). Aktuelle Einschränkungen stehen in [KNOWN_LIMITATIONS.md](../Quality/KNOWN_LIMITATIONS.md).

## 1. Voraussetzungen

Die schrittweise Installation mit offiziellen Downloadlinks und getrennter
Abgrenzung zur Entwicklungsumgebung steht in
[Installation für AnwenderInnen unter Windows](INSTALLATION_WINDOWS.md).

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

Standard für Skript-Hilfeeinträge (`-ShowHelp` und `--help`; `/?` sowie
`-help`/`-h`/`-?` können je nach PowerShell-Kontext die Engine-Hilfe auslösen):

```powershell
.\Invoke-SqlServerLab.ps1 -ShowHelp
.\Tools\Initialize-SqlServerLabDataRoot.ps1 -ShowHelp
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 -ShowHelp
.\Tools\Start-SqlServerLabUi.ps1 -ShowHelp
.\CheckLargeGitFilesPush.ps1 --help
```

Für alle aufgeführten Skripte gilt: Wird ein Support-Switch erkannt, wird direkt
die Skript-Hilfe angezeigt und anschließend die Ausführung beendet.

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

### 4a. Beliebigen CU vorab bereitstellen

Der Versionskatalog enthält alle 65 bei Microsoft weiterhin verfügbaren CUs
für SQL Server 2019, 2022 und 2025. Windows-Pakete werden in den Media Root
geschrieben und vor der Veröffentlichung gegen den katalogisierten SHA-256
sowie eine gültige Microsoft-Authenticode-Signatur geprüft:

```powershell
Save-SqlServerLabCuResource `
    -SqlVersion 2019 `
    -Cu CU6 `
    -Platform Windows `
    -MediaRoot 'D:\Lab_Base'
```

Unter Linux wird derselbe CU über seinen expliziten MCR-Tag in den lokalen
Docker- oder Podman-Cache gezogen:

```powershell
Save-SqlServerLabCuResource `
    -SqlVersion 2019 `
    -Cu CU6 `
    -Platform Linux `
    -Provider Docker
```

Ohne Parameterkenntnis führt das Konsolenmenü unter **Medien, Testdaten und
Speicher → SQL Server CU herunterladen oder prüfen** durch Plattform, Version,
CU und Container-Provider. Ein fehlender oder nicht katalogisierter CU wird
fail-closed abgelehnt; SQL Server 2019 CU7 ist wegen des Microsoft-Rückzugs
nicht auswählbar.

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

Für neue Labore über das Menü gilt nun der Ziel-first-Fluss:
für SQL-Umgebungen wird danach der Provider abgefragt, für einen OS-Slot wird direkt
der Hyper-V-Weg genutzt. Details stehen unter
[INTERACTIVE_WORKFLOW.md](./INTERACTIVE_WORKFLOW.md).

Für eine geführte Übersicht mit OS-Baselines, SQL-Prepared-Images,
Hintergrundaktionen und Live-Log kann die
[lokale Workflow-Oberfläche](../HowTo/WORKFLOW_UI.md) gestartet werden.

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

Die Beispiel-URL ist absichtlich nicht ausführbar. Verwenden Sie eine zulässige reale `.bak`-Quelle. Bei einer URL ohne bekannte SHA-256 wird im interaktiven Ablauf einmalig die Vertrauensfreigabe abgefragt. Nach erfolgreichem Download speichert der lokale Trust Store den berechneten Digest und der inhaltsadressierte Cache verwendet ihn bei späteren Aufrufen. Mit `-NonInteractive` wird ohne bekannte Prüfsumme nicht geladen; der Aufruf endet mit `TRUST_REQUIRED`.

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

Bei Pfadfeldern zeigt der Wizard zusätzlich die fachliche Bedeutung,
Host-/Gast-/SQL-Server-Scope, die Bezugsbasis relativer Werte, Default und
Seiteneffekt. Relative Hostpfade werden gegen das Verzeichnis der Ziel-
Manifestdatei aufgelöst und als Vorschau nur in der laufenden Konsole angezeigt.
Der Wizard schreibt keine konkreten lokalen Pfade in Projektdateien, außer sie
werden ausdrücklich als Manifestwert eingegeben.

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
| `Warnings` | `String[]` | Risiken oder ausführbare Konfigurationen mit Einschränkungen; reservierte Runtimeverträge sind Fehler |
| `Plan` | `PSCustomObject` | Mutationsfreie External-Runtime- und Sample-/Artifact-Planvorschau je Instanz |

Der Wizard bietet unter `instances[].software` nur External-Runtime-Varianten
an, die der Resolver fuer die bereits gewählte SQL-Version, den Provider und
das Betriebssystem als `RESOLVED` freigibt. `Plan.Instances[].ExternalRuntimes`
nennt fuer dieselbe Auflösung Downloads, Derived-Image-Build oder Gastmutation,
Restarts, Downtime, Package Locks und Verification. Der Aenderungsweg trennt
Artifact-`rebuild`, Service-`restart`, Container-`recreate` und sichere
Gast-`reprovision`; identische portable `PlanKey`-Werte ergeben `no-op`.
`Plan.Instances[].Samples` nennt zusätzlich Sample-ID und Variante, Artifact
Type, Quelle, Lizenz, erwartete Outputs, Download-/Installationsgröße,
Integritäts-/Trust-Status, Handler und Idempotenz.

```powershell
$validation.Plan.Instances |
    Select-Object InstanceId, Provider, ExternalRuntimes, Samples
```

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
10. resolverfreigegebene External-Runtime-Varianten und deren mutationsfreie
    Software-Planvorschau;
11. riskante SQL-Optionen und Schemafelder, die von der Runtime noch nicht
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
| `instances[].provider` | automatische Auswahl: normalerweise `docker`; `hyperv` benötigt explizit `os: "windows"` und einen `hyperv.preparedImageId`-Verweis auf ein `OS_SEALED`- oder `SQL_PREPARED_SEALED`-Artifact |
| `instances[].os` | `linux` |
| `instances[].profile` | `standard` |
| `instances[].collation` | `SQL_Latin1_General_CP1_CI_AS` (nativer Containerstandard) |
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
Runtime-Zusage. Explizit gesetzte `serverConfig`-Felder mit
`x-runtimeStatus: reserved` werden mit `MANIFEST_RESERVED_RUNTIME_FIELD`
abgelehnt; reservierte Enum-Werte wie `externalScripts.installMethod` gleich
`custom-image` oder `pre-built` mit `MANIFEST_RESERVED_RUNTIME_VALUE`.

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

### Hyper-V aus einem Prepared-Image bereitstellen

Der Manifestpfad für Hyper-V erstellt bewusst **keinen** Windows- oder
SQL-Image-Build. Er referenziert ein bereits veröffentlichtes,
unveränderliches `OS_SEALED`- oder `SQL_PREPARED_SEALED`-Artifact und erzeugt
daraus eine neue differenzierende VM. Für `SQL_PREPARED_SEALED` ist damit der
SQL-spezifische Pfad vollständig automatisiert inklusive OOBE.

```json
{
  "$schema": "./Schemas/lab-manifest.schema.json",
  "name": "projekt-sql-2025",
  "persistentData": {
    "enabled": true,
    "dataRoot": "D:\\Lab_Data",
    "dataDiskGB": 128
  },
  "instances": [
    {
      "id": "primary",
      "version": "2025",
      "provider": "hyperv",
      "os": "windows",
      "autostart": "on",
      "hyperv": {
  "preparedImageId": "hyperv-sql-prepared-sealed-<Artifact-SHA-256>",
        "switchName": "SQL_LAB_HYPERV",
        "memoryStartupMB": 4096,
        "processorCount": 4,
        "sqlPort": 1433,
        "guestPasswordMode": "generated"
      }
    }
  ]
}
```

`preparedImageId` wird aus **Hyper-V Windows-Image verwalten** übernommen.
`instances[].autostart: "on"` ist providerneutral. Für Hyper-V setzt es
`AutomaticStartAction=Start`. Docker und Podman verwenden `unless-stopped` und
das Label `sql-server-lab.autostart=on`. Unter Windows richtet SQL Server Lab
zusätzlich je Runtime einen Auftrag für die Anmeldung des aktuellen Benutzers
ein: Er startet Docker Desktop beziehungsweise die Podman Machine und danach
ausschließlich markierte Lab-Container. Ein Windows-Desktop-/Rootless-Container
ist deshalb nach dem ersten Login verfügbar, nicht bereits vor der Anmeldung.
Sind Docker Desktop und Podman Desktop parallel vorhanden und besitzt Podman
einen verwalteten Lab-Autostart, erkennt der Hostkoordinator diese Kombination
automatisch. Er wartet zuerst auf Docker, startet danach die Podman Machine und
anschließend Podman Desktop. Den bekannten Podman-Desktop-Login-Eintrag sichert
er dafür lokal und übernimmt ihn reversibel; beim letzten Podman-Autostart-
Cleanup wird er wiederhergestellt. Auf Systemen mit nur einer Runtime entsteht
keine zusätzliche Providerabhängigkeit.
Auf nativem Linux prüft SQL Server Lab, dass `docker.service` beim Boot startet;
für Podman aktiviert es den User-Service `podman-restart.service` und systemd-
Linger für den aktuellen Benutzer. Kann der Hoststart nicht garantiert werden,
bricht die Provisionierung fail-closed ab. Ohne Angabe gilt `"off"`.
`hyperv.autostart` bleibt als veralteter Alias kompatibel, darf dem neuen Wert
aber nicht widersprechen.
`guestPasswordMode: "generated"` zeigt beim Start einmalig ein zufälliges
Passwort an; `"prompt"` fragt es sicher ab. Ein Klartextpasswort gehört nie in
die Manifestdatei. Die Antwortdatei wird nur in die neue Child-VHDX injiziert,
anschließend aus dem Gast entfernt und das Passwort pro Run DPAPI-geschützt
gespeichert.
`hyperv.sqlPort` legt den statischen TCP-Port der SQL-Standardinstanz im Gast
fest und gilt ohne Angabe als `1433`. Dieser Gastport ist kein Container-
Hostport und darf deshalb auf unterschiedlichen Gast-IP-Adressen identisch sein.

`persistentData` ist optional. Bei Hyper-V wird für genau diese Lab-VM eine
eigene dynamische Daten-VHDX im Data Root erstellt; andere Klone verwenden sie
nicht. Der Data Root muss vorher initialisiert sein. Ein Hyper-V-Manifest
unterstützt derzeit genau eine Instanz und keine Mischung mit Containern.
Katalogdatenbanken, beliebige Zusatzlaufwerke, Softwareinstallationen und
Post-Provisioning-Skripte werden explizit abgelehnt, damit kein Manifest nur
teilweise ausgeführt wird.

Ohne `switchName` verwendet der Manifestpfad den gespeicherten beziehungsweise
verwalteten internen Hyper-V-Lab-Switch. Nach der unbeaufsichtigten OOBE erhält
der Gast eine feste Lab-IP. Bei `SQL_PREPARED_SEALED` werden zusätzlich SQL-TCP,
eine auf den Host beschränkte Firewallregel und SQL-Authentifizierung eingerichtet.
Der ausgegebene Host-Connection-String verwendet `sa`; dessen Passwort kann bei
der Bereitstellung bewusst eigenständig gesetzt werden und wird nicht im Klartext
gespeichert.

### SQL Server Configuration Manager: WMI reparieren

`Invalid class [0x80041010]` bedeutet üblicherweise, dass der SQL-WMI-Provider
nicht registriert ist. Neue Prepared-Image-Klone prüfen ihn nach
`CompleteImage` automatisch. Für bereits vorhandene, laufende Hyper-V-Labs
steht unter **Hyper-V-Umgebungen verwalten** die Aktion `[w]mi reparieren` zur
Verfügung. Sie kompiliert ausschließlich die lokale passende SQL-MOF-Datei und
startet den WMI-Dienst im Gast neu.

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

Automatisch unterstützt werden ausführbare Katalogvarianten mit direktem
`.bak`, ZIP oder 7z mit katalogisierter `.bak`-Payload oder einem gepinnten
einzelnen T-SQL-Skript. Für 7z muss die lokale 7-Zip-Kommandozeile verfügbar
sein; sie kann im Konsolenmenü mit `[z]` nach expliziter Bestätigung über
`winget` nachgerüstet werden. Eine im Katalog hinterlegte SHA-256 wird erzwungen; fehlt sie,
fragt ein interaktiver Lauf einmalig nach Vertrauen und registriert den
berechneten Hash im lokalen Trust Store. Mehrere Samples pro Instanz können ad-hoc über
`New-SqlServerLab -Sample 'adventureworks-2022:lightweight', 'wideworldimporters:standard'`
oder den Menüschritt `Testdatenbanken` gewählt werden. Attach-Verfahren und
Script-Bundles werden nicht automatisch verarbeitet; dies gilt auch für
`.7z`-Archive, die keine katalogisierte `.bak`-Payload enthalten.

Bei neuen Hyper-V-Manifest-Runs werden erfolgreich installierte Katalogsamples
zusätzlich durch ein lokales, VM-gebundenes Ownership-Receipt geschützt. Ein
später geändertes Manifest kann den Sample-Satz read-only planen und danach
anwenden:

```powershell
Get-SqlServerLabReconcilePlan `
    -RunId $lab.RunId `
    -HyperVTestDatabases `
    -ManifestPath '.\lab-with-updated-samples.json' `
    -InstanceId primary

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVTestDatabases `
    -ManifestPath '.\lab-with-updated-samples.json' `
    -InstanceId primary `
    -WhatIf

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVTestDatabases `
    -ManifestPath '.\lab-with-updated-samples.json' `
    -InstanceId primary `
    -Confirm:$false
```

Ein explizit bereitgestelltes SQL-Passwort wird bei einer späteren Addition
mit `-SqlSaPassword $pw` erneut übergeben. Entfernt werden ausschließlich
receiptgebundene Sample-Outputs; fremde Datenbanken mit kollidierendem Namen
blockieren den Plan. Vor einem Drop wird ein verifiziertes Recovery-Backup im
Gast erzeugt. Alte Runs ohne Ownership-Receipt werden nicht still adoptiert.

## 13a. Project Adapter anwenden

Konsumierende Projekte liefern einen Adapter gemäß
`Schemas/project-adapter.schema.json`. Prüfung und Anwendung:

```powershell
Test-SqlServerLabAdapter -Path '.\Adapters\Examples\synthetic-demo'

Install-SqlServerLabAdapter `
    -Path '.\Adapters\Examples\synthetic-demo' `
    -RunId $lab.RunId `
    -SaPassword $pw
```

Es laufen ausschließlich die deklarierten T-SQL-Entrypoints; Container,
Volumes und Run-State bleiben unverändert.

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

Der gespeicherte Provider wird für Start, Stop und Live-Status verwendet. Bei
gleichzeitig installiertem Docker und Podman bleibt jede Instanz an ihren
ursprünglichen Provider gebunden. Ein Manifest kann beide Containerprovider in
einem Run kombinieren; Details und Grenzen stehen im
[Gemischten Container-Provider-Lifecycle](../Architecture/MIXED_PROVIDER_LIFECYCLE.md).

### Hyper-V-Ressourcenziel vorab prüfen

Vor einer Hyper-V-Erstellung kann die registrierte physische Zielbindung ohne
State-, VHDX- oder VM-Mutation gelesen werden:

```powershell
Get-SqlServerLabHyperVResourcePreview -ResourceClass Run,Build,Image,Staging
```

Die Ausgabe nennt stabile `LocationId`, `LabDataRoot`, freien Speicher und die
Klassenroots unter `Lab_Data`. Das interaktive Hyper-V-Menü zeigt dieselbe
Vorschau vor UAC und vor Erstellungsaktionen. Der erhöhte Prozess übernimmt
keinen prozesslokalen Fallback, sondern revalidiert Controller, Location,
Volume und Root aus dem expliziten Handoff. Eine Abweichung blockiert vor der
ersten Hyper-V-Mutation.

Registrierte Mitglieder der geschützten automatisierten Testgruppe bleiben für
diese Einzel-Cmdlets gesperrt. Docker-, Podman- und Hyper-V-Mitglieder werden
stattdessen gemeinsam, idempotent und ohne Löschung bereitgestellt beziehungsweise
gestoppt. Im Hauptmenü unter **Umgebungen** erscheint dafür abhängig vom
Livezustand genau eine Aktion: **Automatisierte Testumgebung starten** oder
**Automatisierte Testumgebung stoppen**.

```powershell
Start-SqlServerLabAutomatedTestEnvironment -WhatIf
$start = Start-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
# Nur $start.Status = READY und $start.Export.GroupStatus = READY freigeben.

Stop-SqlServerLabAutomatedTestEnvironment -WhatIf
$stop = Stop-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
# Danach: $stop.Status = STOPPED, Export.GroupStatus = INCOMPLETE.
```

Der Start bringt Container, VMs und vorhandene SQL-Engine-Dienste hoch, prüft
SQL-Readiness einschließlich der erwarteten Major-Version und erneuert den
kanonischen Export live. Der Stopp gibt deren CPU- und RAM-Kapazität frei,
erhält jedoch Runs, Secrets, Registrierungen, Volumes und VHDX-Dateien. Details stehen unter
[Automatisierte Testumgebungen](AUTOMATED_TEST_ENVIRONMENTS.md).

### Read-only Reconcile-Vorschau

Der aktuelle Plan kann ohne Mutation gelesen werden. Der Vertrag enthält keine
Secrets, Host-/Port-Werte oder Container-/VM-IDs. Unvollständige Runtime-
Zustände werden bewusst als `unsupported` statt mit Teilaktionen ausgewiesen.

```powershell
Get-SqlServerLabReconcilePlan -RunId $lab.RunId -TargetState STOPPED
```

### Reconcile-Executor ausführen

Für `START`/`STOP`-Vorschläge kann der Plan jetzt im nächsten Schritt ausgeführt
werden. Das Beispiel wechselt den gewünschten Zielzustand kontrolliert auf
`RUNNING`; bestehende Fehlkonfigurationen oder gemischte Operationssätze bleiben
aus Sicherheitsgründen als `unsupported` und unverändert.

```powershell
Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -TargetState RUNNING
```

Mit `-WhatIf` kann vorab geprüft werden, ob der Executor tatsächlich
Ausführungsversuche durchführt.

### Hyper-V-Netzwerkdrift gezielt reparieren

Der Lifecycle-Plan bleibt bei jeder Hyper-V-Netzwerkdrift fail-closed. Für den
eng begrenzten Reparaturpfad wird deshalb ein eigener Plan gelesen und erst
danach dessen Action ausgeführt:

```powershell
$networkPlan = Get-SqlServerLabReconcilePlan `
    -RunId $lab.RunId `
    -HyperVNetwork `
    -InstanceId primary

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVNetwork `
    -InstanceId primary `
    -WhatIf

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVNetwork `
    -InstanceId primary
```

Die Action darf ausschließlich fehlende additive, bereits lokal gebundene
Hostinfrastruktur herstellen und genau einen vorhandenen getrennten Adapter
der run- und scopegebundenen VM wieder verbinden. Sie erstellt keinen Adapter,
bindet keinen falsch verbundenen Adapter um und repariert keine Gastadresse.
Soll ein lokal erlaubter LAN-External-Switch tatsächlich erstellt werden, ist
zusätzlich `-AllowExternalSwitchCreation` erforderlich. Der öffentliche Plan
enthält keine Switch-, VM-, Adapter- oder Adresswerte; lokale Identitäten
bleiben ausschließlich im Recovery-Journal.

### Hyper-V-vCPU und RAM abgleichen

Neue Hyper-V-Manifeste speichern `processorCount`, `dynamicMemoryEnabled`
sowie `memoryMinimumMB`, `memoryStartupMB` und `memoryMaximumMB` als portablen
Sollzustand. Der getrennte Plan vergleicht diese Werte read-only mit der
run- und scopegebundenen VM:

```powershell
$resourcePlan = Get-SqlServerLabReconcilePlan `
    -RunId $lab.RunId `
    -HyperVResources `
    -InstanceId primary

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVResources `
    -InstanceId primary `
    -WhatIf
```

Reine Min-/Max-Aenderungen bei bereits aktiviertem dynamischem RAM sind auf
einer laufenden VM `live`. vCPU, RAM-Modus und Startspeicher werden bei einer
laufenden VM als `restart` klassifiziert und journalisiert über Stop, Apply,
Postcondition und Start ausgeführt. Unterbrechungen bleiben als
`RECOVERY_REQUIRED` sichtbar und derselbe Aufruf setzt sie fort. Alte Runs ohne
persistierten `HyperVResourceIntent/1.0` werden nicht geraten und bleiben
`unsupported`.

### Hyper-V-Zusatz-VHDX abgleichen und vergroessern

Manifestgebundene Zusatz-VHDX und die aus einem `storageIntent` lokal
gebundenen Storage-Lanes besitzen einen getrennten, hostwertfreien Plan:

```powershell
$storagePlan = Get-SqlServerLabReconcilePlan `
    -RunId $lab.RunId `
    -HyperVStorage `
    -InstanceId primary

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVStorage `
    -InstanceId primary `
    -WhatIf
```

Der Repair-Pfad erstellt ausschließlich fehlende run-/locationgebundene
SCSI-VHDX oder vergroessert vorhandene VHDX. Danach initialisiert, verifiziert
oder erweitert er das NTFS-Volume ueber PowerShell Direct. Eine zuvor
ausgeschaltete VM wird nur fuer diese Gast-Postcondition gestartet und danach
wieder ausgeschaltet. Cleanup wird vor einer neuen VHDX registriert; Abbrueche
bleiben im lokalen Journal `RECOVERY_REQUIRED` und derselbe Aufruf setzt sie
fort. Shrink, Removal, Rollen-/Pfadwechsel, belegte SCSI-Slots und fremde oder
uneindeutige Attachments bleiben ohne Teilmutation `unsupported`.

### Hyper-V-SQL-Dateiplatzierung abgleichen und fortsetzen

Nachdem der Host-/Gast-Storageplan ein No-op ist, kann ein getrennter Plan die
gebundenen SQL-Default- und TempDB-Pfade read-only mit dem Gast vergleichen:

```powershell
$sqlStoragePlan = Get-SqlServerLabReconcilePlan `
    -RunId $lab.RunId `
    -HyperVSqlStorage `
    -InstanceId primary

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVSqlStorage `
    -InstanceId primary `
    -WhatIf
```

Der öffentliche Plan enthält weder VM-Identitäten noch Host- oder Gastpfade.
Die Action schreibt vor der SQL-Mutation das lokale Storage-Runtime-Receipt,
ändert ausschließlich Default- und TempDB-Bindungen und startet den SQL-Dienst
kontrolliert neu. Ein fehlgeschlagener Lauf bleibt `RECOVERY_REQUIRED` und wird
mit demselben Aufruf fortgesetzt. User- und Systemdatenbankdateien sowie
zusätzliche TempDB-Logfiles bleiben `unsupported`.

### Hyper-V-SQL-Port abgleichen und fortsetzen

Der statische SQL-TCP-Port besitzt einen eigenen Restart-Vertrag. Der
öffentliche Plan zeigt nur semantische Binding-Statuswerte, niemals den
gewünschten oder beobachteten Port. Die Reparatur aktualisiert TCP/IP und die
run-eigene Gastfirewall, startet ausschließlich `MSSQLSERVER` neu, prüft SQL
über den Zielport und synchronisiert erst danach `connection-info.json`:

```powershell
$sqlPortPlan = Get-SqlServerLabReconcilePlan `
    -RunId $lab.RunId `
    -HyperVSqlPort `
    -InstanceId primary

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -RepairHyperVSqlPort `
    -InstanceId primary `
    -WhatIf
```

Mehrere oder benannte SQL-Instanzen sowie uneindeutige Firewallregeln bleiben
fail-closed. Der SQL-Port liegt im Gast; die VM selbst wird nicht neu gestartet.

### External Languages nachträglich installieren oder aktualisieren

Für einen laufenden SQL-Server-2019-, -2022- oder -2025-Docker-/Podman-Run kann ein Zielmanifest
erstmals oder zusätzlich resolverfreigegebene Sprachen deklarieren. Im CLI ist
der Einstieg unter `Umgebungen -> Umgebung verwalten -> External Languages
installieren oder ändern` sichtbar. Das Zielmanifest muss dieselben Instanzen
und denselben Provider-, Profil-, Storage-, Netzwerk- und Datenbankzustand
beschreiben; geändert werden dürfen hier nur resolverfreigegebene
`instances[].software`-Einträge. Derzeit ist das bei SQL Server 2019 `sql-java`
und bei SQL Server 2022/2025 `sql-python`, `sql-r` und `sql-java`.

Zuerst wird der read-only Plan geprüft, danach baut der Executor das neue
Derived Image. Der alte Container bleibt bis zum erfolgreichen
SQL-Datenroundtrip als Rollback-Ziel erhalten; alte Images werden nicht durch
den Run-Cleanup gelöscht. Bei einer Erstinstallation werden auch die beiden
scopegebundenen External-Language-/Library-Volumes in den Cleanup-Vertrag
aufgenommen.

```powershell
$plan = Get-SqlServerLabReconcilePlan `
    -RunId $lab.RunId `
    -ManifestPath .\lab-with-python-r-java.json `
    -InstanceId external-runtime

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -ManifestPath .\lab-with-python-r-java.json `
    -InstanceId external-runtime `
    -WhatIf

Invoke-SqlServerLabReconcileAction `
    -RunId $lab.RunId `
    -ManifestPath .\lab-with-python-r-java.json `
    -InstanceId external-runtime
```

Der ausführbare Umfang umfasst SQL Server 2019, 2022 und 2025 auf
Docker/Podman, aber keine gleichzeitigen Änderungen an Provider, Profil,
Storage, Netzwerk oder Datenbanken. Docker und Podman besitzen dabei dieselbe
Sprachfreigabe; Podman
muss für den sicheren `launchpadd`-Namespace-Modus jedoch rootful auf einem
Linux-Containerhost mit cgroup v1 laufen. Eine einzelne Sprache kann entfernt werden, solange mindestens
eine External Runtime erhalten bleibt. Die Entfernung der letzten Runtime und
Hyper-V-Nachinstallation/-Artifact-Refresh bleiben fail-closed. Im Hyper-V-
Verwaltungsmenü wird dieser derzeit nicht atomare Pfad deshalb sichtbar, aber
deaktiviert angezeigt.

C# ist als SQL-External-Language-Intent `sql-csharp` für SQL Server 2019 bis
2025 auf Windows/Hyper-V erfasst. Microsoft bezeichnet die registrierte
SQL-Sprache als `dotnet`. Die vorhandene Microsoft-Binärveröffentlichung zielt
jedoch auf .NET 5, während der aktuelle Quellstand .NET 8 verwendet. Bis ein
hashgebundener aktueller Build und ein nativer SQL-Roundtrip vorliegen, bleibt
die Variante sichtbar `PREVIEW` und wird vor jeder Mutation abgelehnt.

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
runs/<RunId>/manifest.lock.json
runs/<RunId>/secrets/
trust/sample-artifacts.json
cache/artifacts/sha256/<sha256>/
cache/quarantine/
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

Unter Windows oder macOS muss bei Podman gegebenenfalls zuerst die Podman
Machine gestartet werden. Für die Standard-Machine unter Windows:

```powershell
podman machine start podman-machine-default
podman info
```

Die Repository-Integrationstests können eine vorhandene gestoppte Machine über
`Tests/Integration/Initialize-PodmanRuntime.ps1` automatisch starten. Das
Skript erstellt keine fehlende Machine. Einrichtung und Localhost-Netzwerk sind
in der [Windows-Installationsanleitung](INSTALLATION_WINDOWS.md#variante-b--podman-desktop)
beschrieben.

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
