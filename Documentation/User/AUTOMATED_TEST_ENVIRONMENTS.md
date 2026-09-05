# Automatisierte Testumgebungen

Mehrere SQL-Zielumgebungen werden über den aktuellen Direkteinstieg gesammelt
und anschließend in einem Auftrag erstellt:

```powershell
.\Invoke-SqlServerLab.ps1 -Action AutomatedTestEnvironment
```

Der frühere Hauptmenüpunkt `[e]` ist kein aktueller Einstieg. Linux verwendet
Docker oder Podman und läuft vollständig automatisiert. Windows verwendet
Hyper-V; wenn keine vollständig vorbereitete SQL-Vorlage vorhanden ist,
pausiert der Ablauf ausschließlich für Windows-OOBE,
Administratorpasswort und die erste Anmeldung.

Die vollständige Schrittfolge von der `OS_SEALED`-Baseline über sechs Ziele bis
zur SSMS-/CMS-Kontrolle steht im
[End-to-End-Runbook](../HowTo/END_TO_END_TEST_ENVIRONMENT.md).

## Schnellablauf für die Sechs-Ziele-Matrix

1. Im Composer nacheinander `Linux hinzufügen` und `Windows hinzufügen`
   verwenden.
2. Für Linux 2019, 2022 und 2025 jeweils `latest` wählen.
3. Für Windows 2019, 2022 und 2025 jeweils `base` wählen.
4. `Alle vorgemerkten Umgebungen erstellen` ausführen.
5. Windows-OOBE, Slotübernahme und Evaluation-Aktivierung nur dort abschließen,
   wo der Workflow anhält.
6. `Export aktualisieren` wählen und erst bei `groupStatus = READY` sowie sechs
   Einzelstatus `READY` mit Tests beginnen.

Die Standardmatrix besteht exakt aus `LINUX_2019_LATEST`,
`LINUX_2022_LATEST`, `LINUX_2025_LATEST`, `WINDOWS_2019_BASE`,
`WINDOWS_2022_BASE` und `WINDOWS_2025_BASE`. Explizite katalogisierte CUs sind
eine optionale Alternative und erzeugen entsprechend andere Schlüssel.

Windows-Testslots werden nicht ohne aktivierte und noch gültige Evaluation als
bereit veröffentlicht. Nach OOBE aktiviert das Framework jede eindeutige
Child-VM online, bevor SQL Setup beginnt. Nur wenn der Slot noch nicht aktiviert
ist, wird automatisch ein vorhandener External-Switch an einer verbundenen
physischen Netzwerkkarte gewählt. Dafür wird eine
zweite NIC mit dem reservierten Namen `SQL_SERVER_LAB_ACTIVATION_TEMP` nur
temporär angebunden und auch bei einem Fehler wieder entfernt; die interne
Lab-NIC und die immutable OS-Baseline bleiben unverändert. Edition-Konvertierung
und Product Key sind für diesen Evaluationspfad nicht erforderlich.
Microsoft gibt für Windows Server Evaluation 180 Tage an und verlangt die
Online-Aktivierung innerhalb der ersten 10 Tage, um automatische Abschaltungen
zu vermeiden ([Windows Server 2025 Evaluation](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025)).

Das Menü zeigt bei jedem Öffnen zuerst die bereits registrierte Testgruppe mit
dem aktuellen Einzelstatus an, beispielsweise `fertig`, `SQL-Installation
wiederholbar` oder `SQL-Abschluss fortsetzbar`. Darunter steht getrennt der
„Neue Auftrag“, der nur die während dieses Menüaufrufs neu hinzugefügten Ziele
enthält.

Für Windows wird zuerst der älteste freie, bereits vollständig eingerichtete
Windows-Slot aus dem lokalen Slot-Pool verwendet. Der Slot wird nach erfolgreicher
Auswahl sofort für den stabilen Testumgebungsschlüssel reserviert. Nur wenn kein
geeigneter Slot vorhanden ist, erzeugt das Framework eine neue differenzierende VM
aus der veröffentlichten Windows-OS-Vorlage; dann können OOBE und erste Anmeldung
nötig werden. Bereits einer Testgruppe zugeordnete Slots werden nicht für andere
Ziele vergeben.

Schlägt das SQL-Basis-Setup fehl, bleibt der reservierte Slot im Zustand
`INSTALL_RETRY_PENDING`. Nach erfolgreichem Basis-Setup wird vor dem CU-Schritt
`PATCH_PENDING` persistiert; ein Fehler beim Kopieren, Installieren oder Prüfen
des CU führt zu `PATCH_RETRY_PENDING`. Bei der Wiederaufnahme prüft das Framework
zuerst den Build der laufenden SQL-Engine. Ein bereits vollständig wirksames CU
wird dadurch übernommen und nicht erneut installiert. Wird derselbe
Windows-Schlüssel erneut zur Batch-Liste hinzugefügt, setzt das Framework genau
diesen Run fort; es belegt weder einen weiteren Pool-Slot noch legt es einen
Schlüssel mit Suffix an. Eine bereits fertige Umgebung wird idempotent erkannt
und nicht erneut installiert.

Alle Testumgebungen bilden eine gemeinsame, geschützte Lifecycle-Gruppe:

- Jede Linux- und Windows-Umgebung wird mit `AutoStart = on` erstellt.
- Linux-Ziele verwenden fuer wiederholte Projektvolltests das Profil `standard`
  mit 4 GB Container-RAM, 4 vCPU, 3 GB `max server memory` und einem davon
  getrennten SQL-Linux-Memory-Limit unterhalb der cgroup-Grenze.
- Die Gruppe ist nur verwendbar, wenn wirklich alle registrierten Ziele bereit sind.
- `Start-SqlServerLabAutomatedTestEnvironment` darf alle registrierten Docker-,
  Podman- und Hyper-V-Mitglieder als Gruppe reaktivieren, vorhandene SQL-
  Engine-Dienste starten und SQL-Bereitschaft einschließlich der erwarteten
  Major-Version authentifiziert prüfen. Windows muss dabei live als lizenzierte,
  nicht mehr als Evaluation geführte Edition bestätigt werden. Erst der danach live erneuerte
  Gesamtvertrag darf `READY` melden.
- `Stop-SqlServerLabAutomatedTestEnvironment` schaltet dieselben Container und
  VMs gemeinsam aus und gibt ihre Hostkapazität frei. Registrierungen, Runs,
  Secrets, Volumes und VHDX-Dateien bleiben erhalten.
- Unter **Umgebungen** bietet das Hauptmenü zustandsabhängig genau eine sichere
  Gruppenaktion an: **Automatisierte Testumgebung starten** oder
  **Automatisierte Testumgebung stoppen**.
- Normale Start-, Stopp-, Neustart-, Ressourcen-, Umbenennungs- und
  Löschmenüs zeigen die Runs an, lassen sie dort aber nicht auswählen.
- Auch `Clear-SqlServerLab` überspringt die geschützte Testgruppe.
- Hauptmenüpunkt **[x] Alle automatisierten Testumgebungen löschen** entfernt
  ausschließlich die vollständige Gruppe; einzelne Löschungen sind gesperrt.
- Ein konfigurierter CMS folgt demselben Alles-oder-nichts-Vertrag: Solange die
  Gruppe nicht vollständig `READY` ist, wird keine ihrer Umgebungen im CMS
  freigegeben. Sobald alle bereit sind, werden sie gemeinsam unter stabilen Namen
  wie `TEST · LINUX_2022_LATEST` registriert. Die Sammellöschung entfernt auch
  alle zugehörigen CMS-Registrierungen beim nächsten automatischen Abgleich.

Jede Umgebung erhält ein eigenes kryptografisch zufälliges SA-Kennwort. Der
Framework-Secret-Store bewahrt es weiterhin geschützt auf. Für externe
Testwerkzeuge wird zusätzlich ein absichtlicher Klartext-Export erzeugt:

```text
<Lab_Data>\Exports\TestUmgebung.env
<Lab_Data>\Exports\TestUmgebung.json
<Lab_Data>\Exports\TestUmgebung.schema.json
<Lab_Data>\Exports\TestUmgebung.prompt.md
<Lab_Data>\Exports\TestUmgebung.md
<Lab_Data>\Exports\TestUmgebung.registry.json
```

Diese Dateien liegen nie automatisch im Git-Arbeitsverzeichnis. `.env` und JSON
enthalten dennoch Zugangsdaten und dürfen nicht kopiert, committed oder
weitergegeben werden. Das Framework beschränkt die Dateirechte nach Möglichkeit
auf den aktuellen Betriebssystembenutzer.

Verbraucher dürfen keinen konkreten Laufwerks- oder Repositorypfad voraussetzen.
Das Framework veröffentlicht beim Setzen des Standard-Data-Roots und bei einem
regulären Export folgende Pfadvariablen für den aktuellen Benutzer:

```text
SQL_SERVER_LAB_TEST_ENV_FILE
SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE
SQL_SERVER_LAB_TEST_ENV_PROMPT_FILE
```

Als kompatibler Fallback bleibt `SQL_SERVER_LAB_DATA_ROOT` verfügbar; der Vertrag
liegt relativ dazu unter `Exports/TestUmgebung.json`. Eine Laufwerkssuche ist
nicht zulässig. Bereits laufende Prozesse müssen die Benutzervariablen bei Bedarf
explizit lesen oder nach der Konfiguration neu gestartet werden.

## Auswahlvertrag für KI und Werkzeuge

`TestUmgebung.json` ist der kanonische Vertrag
`SqlServerLab.TestEnvironment/1.0`. Ein Verbraucher wählt exakt nach:

1. `platform`: `linux` oder `windows`;
2. `sqlVersion`: beispielsweise `2019`, `2022` oder `2025`;
3. `patch`: bei Linux `latest`, bei Windows `base` oder ein konkreter
   CU-Bezeichner wie `cu18`;
4. oberstes `groupStatus`: muss `READY` sein;
5. `status`: ausschließlich `READY` verwenden.

Solange eine Umgebung noch provisioniert wird, fehlt, nicht läuft oder ihr
gebundener Container-Healthcheck fehlschlaegt, lautet
`groupStatus = INCOMPLETE` und alle Einträge erhalten
`status = GROUP_INCOMPLETE`. Der jeweilige Einzelzustand bleibt in
`runtimeStatus` sichtbar, beispielsweise als `UNHEALTHY`. Dadurch gilt für
Verbraucher strikt: alle oder keine.

Danach stehen `host`, `port`, `database`, `username`, `password`, `encrypt`,
`trustServerCertificate` und `connectionString` zur Verfügung. `runId` und
`instanceId` verbinden den Export mit dem SQL_Server_Lab-Lifecycle.

Beispiel in PowerShell:

```powershell
$contractPath = $env:SQL_SERVER_LAB_TEST_ENV_FILE
if (-not $contractPath) {
    $contractPath = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_ENV_FILE', 'User')
}
if (-not $contractPath) {
    $dataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
    if (-not $dataRoot) { $dataRoot = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User') }
    if ($dataRoot) { $contractPath = Join-Path $dataRoot 'Exports/TestUmgebung.json' }
}
if (-not $contractPath -or -not (Test-Path -LiteralPath $contractPath)) { throw 'Kein SQL_Server_Lab-Testumgebungsvertrag gefunden.' }
$contract = Get-Content -LiteralPath $contractPath -Raw |
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
`TestUmgebung.json` verweist mit `$schema` auf die danebenliegende Datei
`TestUmgebung.schema.json` (JSON Schema Draft 2020-12). Verbraucher können den
Export damit vor der Auswahl und vor jeder Verbindung strukturell validieren.

Beispiel mit PowerShell 7 und portabler Discovery:

```powershell
$contractPath = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_ENV_FILE', 'User')
$schemaPath = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE', 'User')
Test-Json -LiteralPath $contractPath -SchemaFile $schemaPath
```

Der vollständige wiederverwendbare Agenten-Prompt steht in
[`LOCAL_SQL_TESTING_PROMPT.md`](LOCAL_SQL_TESTING_PROMPT.md) und wird als
`TestUmgebung.prompt.md` neben dem Laufzeitvertrag exportiert.

## `latest`, `base` und Reproduzierbarkeit

- Linux `latest` verwendet den gleitenden Microsoft-Container-Tag.
- Windows verwendet standardmäßig `base`: SQL Server wird direkt vom ausgewählten
  und geprüften Installationsmedium installiert, ohne anschließend ein separates
  CU-Paket einzuspielen. `base` behauptet daher ausdrücklich nicht, der neueste
  Microsoft-CU-Stand zu sein. Die tatsächlich installierte Version steht nach
  der Bereitstellung in `resolvedVersion`.
- Die frühere Eingabe `latest` wird im Windows-Menü nur aus
  Kompatibilitätsgründen noch akzeptiert und wie `base` behandelt. Neu erzeugte
  Verträge verwenden dafür stets `patch = base`.
- Ein expliziter CU bleibt auf den gewählten Katalog-Tag beziehungsweise das
  geprüfte Windows-Updatepaket fixiert. Nur in diesem Fall muss das per SHA-256
  katalogisierte Windows-CU-Paket vorhanden sein.

## Nicht interaktiver Linux-Aufruf

```powershell
Import-Module .\SqlServerLab.psd1 -Force

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

## Nicht destruktiver providerübergreifender Gruppen-Lifecycle

Die geschützten Docker-, Podman- und Hyper-V-Mitglieder werden nicht über die
gesperrten Einzel-Cmdlets gestartet oder gestoppt. Dafür gibt es zwei idempotente
öffentliche Gruppenaufrufe:

```powershell
Start-SqlServerLabAutomatedTestEnvironment -WhatIf
$start = Start-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false

$start.Status
$start.Export.GroupStatus
```

`Status = READY` ist nur möglich, wenn jeder registrierte Container und jede VM
läuft, vorhandene SQL-Engine-Dienste im Gast laufen, jede gebundene SQL-Instanz
mit der zur Registry passenden Major-Version erreichbar ist, jeder Windows-Slot
live `EVALUATION_ACTIVE` oder `LICENSED` meldet und der anschließend
live erzeugte Gesamtexport `GroupStatus = READY` meldet. Einzelne Fehler werden secretfrei unter
`Details` als `FAILED/PARTIAL` zurückgegeben; der Gesamtstatus bleibt dann
`INCOMPLETE`.

Nach der Testlast werden alle Gruppenmitglieder ausgeschaltet:

```powershell
Stop-SqlServerLabAutomatedTestEnvironment -WhatIf
$stop = Stop-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false

$stop.Status
$stop.Export.GroupStatus
```

Nach erfolgreichem Stopp lautet `Status = STOPPED`. Der erneuerte Export ist
absichtlich fail-closed: `GroupStatus = INCOMPLETE`, alle Einträge haben
`runtimeStatus = STOPPED`, und kein Einzelziel wird als verwendbar freigegeben.
`-Force` unterdrückt nur die zusätzliche Gruppenrückfrage; `SupportsShouldProcess`,
`-WhatIf` und `-Confirm` bleiben wirksam. Beide Aufrufe verändern weder die
Gruppenzusammensetzung noch Providerbindungen und löschen keine Ressourcen.
Der reale providerübergreifende Hostnachweis vom 2026-08-29 ist im
[Validierungsbericht zum geschützten Testgruppen-Lifecycle](../Quality/VALIDATION_RESULT_2026-08-29_TEST_ENVIRONMENT_GROUP_LIFECYCLE.md)
dokumentiert.

Ist der Ressourcen-, Health-, Autostart- oder Namensvertrag veraltet, wird die
geschützte Gruppe nicht gelöscht. Der öffentliche Reparaturpfad ersetzt nur
betroffene Docker-/Podman-Container und besitzt dafür einen einzelnen Rollback.
Zusätzlich leitet er aus jedem Registry-Schlüssel einen sprechenden Namen ab,
zum Beispiel `test-linux-2022-latest-primary-<run>` oder
`test-windows-2022-base-<run>`. Bereits belegte Hyper-V-Slots werden für eine
notwendige Umbenennung kurz gestoppt und garantiert wieder gestartet; freie
Pool-Slots behalten ihren Slotnamen. Run-IDs, Hostports, Volumes und Kennwörter
bleiben erhalten:

```powershell
Repair-SqlServerLabAutomatedTestEnvironment
```

Bereits vorhandene Evaluation-Slots werden mit demselben Repair-Pfad einmalig
online aktiviert. Ein bereits aktivierter Slot trägt diesen Zustand in seiner
wiederverwendeten Child-VHDX; dafür wird beim nächsten Einsatz weder ein
External-Switch noch eine temporäre NIC benötigt:

```powershell
Repair-SqlServerLabAutomatedTestEnvironment `
    -Force `
    -Confirm:$false
```

Nur wenn eine Aktivierung tatsächlich aussteht, wählt der Lauf automatisch den
ersten verbundenen External-Switch. Mit `-WindowsActivationSwitchName` kann
dieser bei mehreren geeigneten Switches weiterhin ausdrücklich vorgegeben
werden.

Nach der Online-Aktivierung prüft der Lauf `LicenseStatus = 1` und die
Evaluation-Restlaufzeit. Ein vor der Erstaktivierung gemeldeter Grace-Wert 0
wird nicht vorschnell als abgelaufene 180-Tage-Evaluation interpretiert. Schlägt
die Online-Aktivierung fehl, bleibt der Slot `ACTIVATION_REQUIRED`; dann muss der
konkrete Microsoft-Fehler zwischen fehlender Konnektivität und tatsächlich
abgelaufener Evaluation unterscheiden. Ohne Lizenznachweis bleibt der
Gruppenexport fail-closed.

Nach jedem Reparaturversuch wird der Export live erneuert. Erst
`Status = READY` und `Export.GroupStatus = READY` geben die Gruppe wieder für
Verbraucher frei.

Die gesamte Gruppe lässt sich auch nicht interaktiv löschen:

```powershell
Clear-SqlServerLabAutomatedTestEnvironment
```
