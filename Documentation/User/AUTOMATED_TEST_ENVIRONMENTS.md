# Automatisierte Testumgebungen

Über den Hauptmenüpunkt **[e] Umgebung für automatisierte Tests anlegen** können
mehrere SQL-Zielumgebungen gesammelt und anschließend in einem Auftrag erstellt
werden. Linux verwendet Docker oder Podman und läuft vollständig automatisiert.
Windows verwendet Hyper-V; wenn keine vollständig vorbereitete SQL-Vorlage
vorhanden ist, pausiert der Ablauf ausschließlich für Windows-OOBE,
Administratorpasswort und die erste Anmeldung.

Alle Testumgebungen bilden eine gemeinsame, geschützte Lifecycle-Gruppe:

- Jede Linux- und Windows-Umgebung wird mit `AutoStart = on` erstellt.
- Die Gruppe ist nur verwendbar, wenn wirklich alle registrierten Ziele bereit sind.
- Normale Start-, Stopp-, Neustart-, Ressourcen-, Umbenennungs- und
  Löschmenüs zeigen die Runs an, lassen sie dort aber nicht auswählen.
- Auch `Clear-SqlServerLab` überspringt die geschützte Testgruppe.
- Hauptmenüpunkt **[x] Alle automatisierten Testumgebungen löschen** entfernt
  ausschließlich die vollständige Gruppe; einzelne Löschungen sind gesperrt.

Jede Umgebung erhält ein eigenes kryptografisch zufälliges SA-Kennwort. Der
Framework-Secret-Store bewahrt es weiterhin geschützt auf. Für externe
Testwerkzeuge wird zusätzlich ein absichtlicher Klartext-Export erzeugt:

```text
<Lab_Data>\Exports\TestUmgebung.env
<Lab_Data>\Exports\TestUmgebung.json
<Lab_Data>\Exports\TestUmgebung.md
<Lab_Data>\Exports\TestUmgebung.registry.json
```

Diese Dateien liegen nie automatisch im Git-Arbeitsverzeichnis. `.env` und JSON
enthalten dennoch Zugangsdaten und dürfen nicht kopiert, committed oder
weitergegeben werden. Das Framework beschränkt die Dateirechte nach Möglichkeit
auf den aktuellen Betriebssystembenutzer.

## Auswahlvertrag für KI und Werkzeuge

`TestUmgebung.json` ist der kanonische Vertrag
`SqlServerLab.TestEnvironment/1.0`. Ein Verbraucher wählt exakt nach:

1. `platform`: `linux` oder `windows`;
2. `sqlVersion`: beispielsweise `2019`, `2022` oder `2025`;
3. `patch`: `latest` oder ein konkreter CU-Bezeichner wie `cu18`;
4. oberstes `groupStatus`: muss `READY` sein;
5. `status`: ausschließlich `READY` verwenden.

Solange eine Umgebung noch provisioniert wird, fehlt oder nicht läuft, lautet
`groupStatus = INCOMPLETE` und alle Einträge erhalten
`status = GROUP_INCOMPLETE`. Der jeweilige Einzelzustand bleibt in
`runtimeStatus` sichtbar. Dadurch gilt für Verbraucher strikt: alle oder keine.

Danach stehen `host`, `port`, `database`, `username`, `password`, `encrypt`,
`trustServerCertificate` und `connectionString` zur Verfügung. `runId` und
`instanceId` verbinden den Export mit dem SQL_Server_Lab-Lifecycle.

Beispiel in PowerShell:

```powershell
$contract = Get-Content D:\Lab_Data\Exports\TestUmgebung.json -Raw |
    ConvertFrom-Json

$sql = $contract.environments |
    Where-Object {
        $_.platform -eq 'linux' -and
        $_.sqlVersion -eq '2022' -and
        $_.patch -eq 'latest' -and
        $_.status -eq 'READY'
    } |
    Select-Object -First 1

$sql.connectionString
```

Die `.env`-Datei bildet dieselben Felder mit stabilen Variablennamen ab:

```text
SQL_SERVER_LAB_LINUX_2022_LATEST_STATUS="READY"
SQL_SERVER_LAB_LINUX_2022_LATEST_RUNTIME_STATUS="READY"
SQL_SERVER_LAB_LINUX_2022_LATEST_HOST="127.0.0.1"
SQL_SERVER_LAB_LINUX_2022_LATEST_PORT="14330"
SQL_SERVER_LAB_LINUX_2022_LATEST_USERNAME="sa"
SQL_SERVER_LAB_LINUX_2022_LATEST_PASSWORD="..."
SQL_SERVER_LAB_LINUX_2022_LATEST_AUTO_START="on"
SQL_SERVER_LAB_LINUX_2022_LATEST_CONNECTION_STRING="..."
```

JSON ist für KI und allgemeine Programme vorzuziehen, weil mehrere Umgebungen
als Array typisiert bleiben. Dotenv ist für bestehende Testframeworks gedacht.

## `latest` und Reproduzierbarkeit

- Linux `latest` verwendet den gleitenden Microsoft-Container-Tag.
- Windows `latest` wird beim Erfassen auf den höchsten lokal katalogisierten
  konkreten CU aufgelöst. Das benötigte, per SHA-256 katalogisierte Windows-Paket
  muss vorhanden sein. Ohne sicheren konkreten CU wird die Erstellung abgelehnt.
- Ein expliziter CU bleibt auf den gewählten Katalog-Tag beziehungsweise das
  geprüfte Windows-Updatepaket fixiert.

## Nicht interaktiver Linux-Aufruf

```powershell
Import-Module D:\r\pu\SQL_Server_Lab\SqlServerLab.psd1 -Force

New-SqlServerLabAutomatedTestEnvironment -Specification @(
    @{ Platform='linux'; SqlVersion='2019'; Patch='latest' }
    @{ Platform='linux'; SqlVersion='2022'; Patch='cu18' }
)
```

Der Export kann nach Start, Stopp oder einem abgeschlossenen manuellen Hyper-V-
Schritt jederzeit erneuert werden:

```powershell
Export-SqlServerLabTestEnvironment
```

Die gesamte Gruppe lässt sich auch nicht interaktiv löschen:

```powershell
Clear-SqlServerLabAutomatedTestEnvironment
```
