# End-to-End-Testumgebung: Windows und Linux mit SQL Server 2019–2025

| Merkmal | Wert |
|---|---|
| Status | `BINDING_OPERATOR_RUNBOOK` |
| Ziel | sechs geschützte SQL-Testziele und ein separater CMS |
| Plattformen | Windows/Hyper-V und Linux/Docker oder Podman |
| SQL-Versionen | 2019, 2022 und 2025 |
| Primäre Einstiege | `-Action Image`, `-Action AutomatedTestEnvironment`, `-Action ConnectionCenter` |

Diese Anleitung ist der autoritative Operator-Einstieg für die vollständige
Testumgebung. Sie führt von einer unveränderlichen Windows-OS-Baseline über drei
unabhängige Windows-Slots zu drei Windows-SQL-Slots, ergänzt die drei
Linux-Ziele, prüft den gemeinsamen Export und richtet einen separaten Central
Management Server (CMS) ein.

Die Jahreszahlen 2019, 2022 und 2025 bezeichnen in dieser Matrix die
**SQL-Server-Versionen**. Die Windows-Slots dürfen alle aus derselben passenden,
noch gültigen Windows-Server-Baseline stammen.

## 1. Zielbild und Begriffe

```text
eine immutable OS_SEALED-Baseline
  ├─ eigene Child-VHDX → OS-Slot → SQL Server 2019 → WINDOWS_2019_BASE
  ├─ eigene Child-VHDX → OS-Slot → SQL Server 2022 → WINDOWS_2022_BASE
  └─ eigene Child-VHDX → OS-Slot → SQL Server 2025 → WINDOWS_2025_BASE

Docker oder Podman
  ├─ SQL Server 2019 latest → LINUX_2019_LATEST
  ├─ SQL Server 2022 latest → LINUX_2022_LATEST
  └─ SQL Server 2025 latest → LINUX_2025_LATEST

separater SQL-2025-Container → CMS → SQL Server Lab / Running
```

- `OS_SEALED` ist ein hashverifiziertes, read-only Parent-Image. Es wird nicht
  direkt gestartet oder verändert.
- Ein **OS-Slot** ist eine veränderliche, run-lokale VM mit eigener
  differenzierender Child-VHDX. Drei SQL-Ziele benötigen drei getrennte
  OS-Slots.
- Jeder OS-Slot wird genau einmal zu einem **SQL-Slot** ausgebaut. Ein bereits
  veränderter Slot ist keine Quelle für die beiden anderen SQL-Versionen.
- `SQL_SLOT_READY` ist das Erfolgskriterium des Windows-SQL-Ausbaus.
- Die sechs Testziele bilden eine geschützte Alles-oder-nichts-Gruppe. Der CMS
  ist ein siebenter, davon getrennter Systemdienst.

## 2. Voraussetzungen und Sicherheitsgrenzen

Vor Beginn müssen vorhanden sein:

- Windows-Host mit aktivem Hyper-V, Hardwarevirtualisierung, VMConnect und einer
  erhöhten PowerShell-7.2-Sitzung für Hyper-V-Mutationen;
- Docker oder Podman mit erreichbarer Engine für die Linux-Ziele und den CMS;
- `sqlcmd` für SQL-Readiness, Konfiguration und Synchronisation;
- ausreichend RAM, CPU und Storage für sechs gleichzeitige Testziele plus CMS;
- ein initialisierter `Lab_Base`/Media Root außerhalb des Repositorys;
- mindestens ein registrierter `Lab_Data`/Data Root außerhalb des Repositorys;
- eine passende Windows-Server-Evaluation-ISO mit SHA-256-Sidecar;
- SQL-Server-Developer-Installationsmedien für 2019, 2022 und 2025;
- Internetzugang der Container-Runtime für die Linux-Images;
- für die einmalige Windows-Evaluation-Aktivierung ein verbundener Hyper-V-
  External-Switch oder eine eindeutig auswählbare verbundene physische NIC.

Die Ordnerstruktur und die erlaubten Medienquellen stehen unter
[Externer Media Root](MEDIA_ROOT_LAYOUT.md). Die Erstkonfiguration ist über
folgenden Direktaufruf erreichbar:

```powershell
Set-Location <Repository>
.\Invoke-SqlServerLab.ps1 -Action Setup
```

Dabei `Lab_Base` und `Lab_Data` bestätigen. Medien, Image-Registry, State und
Exports haben unterschiedliche Rollen:

- `Lab_Base` enthält ISO-, Installer- und CU-Medien;
- `Lab_Data` enthält langlebige Daten und `Exports`;
- der lokale State Root enthält Runs, Receipts und geschützte Secrets;
- das Git-Repository enthält keine dieser Laufzeitdaten.

Passwörter, `TestUmgebung.env`, `TestUmgebung.json`, Connection Strings,
konkrete Hostpfade und lokale Diagnosedaten niemals committen, in einen Pull
Request kopieren oder weitergeben. Einmalig angezeigte Passwörter nur in einem
geeigneten Secret Store ablegen.

## 3. Windows-`OS_SEALED`-Baseline erstellen

### 3.1 Image-Menü öffnen

```powershell
.\Invoke-SqlServerLab.ps1 -Action Image
```

Der gleichwertige Hauptmenüpfad lautet:

`Hyper-V-Infrastruktur` → `Hyper-V Infrastruktur: OS-Images und ISOs verwalten`

Im Image-Menü `[1] Windows-OS-Vorlage aus DVD erstellen oder fortsetzen`
wählen. Dieses Untermenü enthält den resumierbaren Ablauf:

1. `[1] Windows-Builder aus Media Root vorbereiten`;
2. `[3] Windows-Builder starten und VMConnect öffnen`;
3. `[4] Installiertes Windows generalisieren`;
4. `[5] Windows-Image veröffentlichen`.

### 3.2 Builder und Windows installieren

1. Die erkannte Windows-ISO auswählen. Fehlt das Sidecar, die einmalige
   SHA-256-Berechnung im Menü bestätigen.
2. Edition, Installationstyp und Sprache gegen das tatsächlich verwendete
   Medium prüfen.
3. Den Builder erstellen, starten und VMConnect geöffnet lassen.
4. Beim Hinweis `Press any key to boot from CD or DVD` sofort eine Taste im
   VMConnect-Fenster drücken.
5. Windows benutzerdefiniert auf die einzige leere OS-Disk installieren.
6. OOBE vollständig abschließen, ein lokales Administratorpasswort setzen und
   einmal vollständig anmelden.

Der Baseline-Builder ist absichtlich ohne Netzwerkadapter. SQL Server gehört
nicht in diese Baseline.

### 3.3 Generalisieren und veröffentlichen

1. Zum Image-Menü zurückkehren und im Baseline-Untermenü `[4] Installiertes
   Windows generalisieren` wählen.
2. Die Gast-Credentials nur für diesen PowerShell-Direct-Aufruf eingeben.
3. Nach erfolgreichem Sysprep und Shutdown `[5] Windows-Image veröffentlichen`
   wählen.
4. Bei Evaluation-Medien das angezeigte Ablaufdatum fachlich prüfen.
5. Im Status kontrollieren, dass das Artifact `OS_SEALED`, read-only und
   hashverifiziert ist.

Bei einem Abbruch nicht VM, VHDX oder State manuell löschen. `[2]
Windows-Build-Status anzeigen` verwenden und denselben Build fortsetzen. Nur
ein bewusst verworfener Build wird über `[6] Unfertigen Windows-Builder
aufräumen` entfernt. Details enthält
[Windows-Server-Baseline aus ISO](HYPERV_WINDOWS_IMAGE_BUILD.md).

## 4. Drei unabhängige Windows-OS-Slots anlegen

Den folgenden Ablauf dreimal ausführen:

1. `-Action Image` öffnen.
2. `[2] Betriebssystem-Slot aus Windows-OS-Vorlage erstellen` wählen.
3. Dieselbe veröffentlichte `OS_SEALED`-Baseline auswählen.
4. Einen eindeutigen Namen vergeben, beispielsweise
   `windows-slot-sql2019`, `windows-slot-sql2022` und
   `windows-slot-sql2025`.
5. Für den späteren Gruppenbetrieb 4 vCPU und 4096 MB Startspeicher verwenden.
6. Die Erstellung bestätigen. Das Lab startet die VM und öffnet VMConnect.
7. Windows-OOBE abschließen, ein lokales Administratorpasswort setzen und
   einmal vollständig anmelden.
8. Wieder `-Action Image` öffnen und `[4] Betriebssystem- und SQL-Slots
   verwalten` wählen.
9. Den Slot auswählen und mit `[o] Windows-Grundinstallation übernehmen` die
   Credentials sowie PowerShell Direct prüfen lassen.

Danach muss jeder Slot als Windows-bereit und noch ohne SQL-Ausbau erscheinen.
Jeder Slot besitzt seine eigene Child-VHDX; das gemeinsame Parent-Artifact
bleibt unverändert. Die drei Slots noch nicht über die manuelle Aktion `[a]`
zu Standalone-SQL-Slots ausbauen: Der folgende Testumgebungsworkflow reserviert
sie unter den stabilen Matrixschlüsseln und führt dabei Aktivierung und
SQL-Installation aus.

## 5. Sechs Testziele anlegen

### 5.1 Testumgebungs-Composer öffnen

```powershell
.\Invoke-SqlServerLab.ps1 -Action AutomatedTestEnvironment
```

Dieser Direktaufruf ersetzt den veralteten früheren Hauptmenüpunkt `[e]`.
Im Composer zeigt „Bestehende Testgruppe“ den persistierten Zustand und „Neuer
Auftrag“ nur die in diesem Aufruf vorgemerkten Ziele.

### 5.2 Verbindliche Matrix vormerken

Mit `Linux hinzufügen` beziehungsweise `Windows hinzufügen` genau diese sechs
Ziele aufnehmen:

| Schlüssel | Plattform | SQL Server | Patchauswahl |
|---|---|---:|---|
| `LINUX_2019_LATEST` | Linux | 2019 | `latest` |
| `LINUX_2022_LATEST` | Linux | 2022 | `latest` |
| `LINUX_2025_LATEST` | Linux | 2025 | `latest` |
| `WINDOWS_2019_BASE` | Windows | 2019 | `base` |
| `WINDOWS_2022_BASE` | Windows | 2022 | `base` |
| `WINDOWS_2025_BASE` | Windows | 2025 | `base` |

Empfohlen ist die Reihenfolge der Tabelle. Linux `latest` verwendet den
gleitenden Microsoft-Container-Tag. Windows `base` installiert direkt aus dem
geprüften SQL-Medium und behauptet keinen aktuellen CU-Stand. Eine explizite,
katalogisierte CU-Auswahl ist optional: Linux bindet dann den exakten MCR-Tag,
Windows benötigt das katalogisierte, SHA-256- und Authenticode-geprüfte
CU-Paket. Sie erzeugt jedoch einen anderen Matrixschlüssel als die obige
Standardmatrix.

### 5.3 Auftrag ausführen und Windows-Slots ausbauen

1. `Alle vorgemerkten Umgebungen erstellen` wählen.
2. Die drei Linux-Ziele vollständig automatisiert erstellen lassen. Docker
   wird bei automatischer Auswahl vor Podman bevorzugt; jedes Ziel erhält ein
   eigenes Zufallskennwort und `AutoStart = on`.
3. Für jedes Windows-Ziel bindet das Framework den ältesten geeigneten freien
   OS-Slot an den stabilen Schlüssel. Ein gebundener Slot wird nicht für ein
   anderes Ziel verwendet.
4. Falls ein Slot noch `OOBE_PENDING` meldet, VMConnect öffnen, OOBE und erste
   Anmeldung beenden und `Alles erledigt` bestätigen.
5. Das Framework übernimmt den Slot und prüft dessen Gast-Credentials.
6. Die Windows-Server-Evaluation wird online aktiviert. Nur solange die
   Aktivierung fehlt, wird eine temporäre zweite NIC
   `SQL_SERVER_LAB_ACTIVATION_TEMP` an einen verbundenen External-Switch
   gebunden und anschließend wieder entfernt. Weder Edition-Konvertierung noch
   Product Key sind Teil dieses Evaluation-Pfads.
7. SQL Server Developer in der gewählten Version installieren und die
   Konfiguration abschließen lassen.
8. Im Slotstatus prüfen, dass jeder Windows-Ausbau `SQL_SLOT_READY` erreicht.

Der Windows-Standard verwendet 4 vCPU, 4096 MB RAM, 3072 MB SQL `max server
memory`, vier TempDB-Datendateien, Hostzugriff und `AutoStart = on`.

Bei einem Fehler bleibt der reservierte Slot erhalten:

- `INSTALL_RETRY_PENDING`: denselben Windows-Schlüssel erneut in den Composer
  aufnehmen; das fehlgeschlagene SQL-Basis-Setup wird wiederholt;
- `PATCH_PENDING`: das Basis-Setup ist abgeschlossen und der gespeicherte
  CU-Schritt wird fortgesetzt;
- `PATCH_RETRY_PENDING`: der CU-Schritt wird fortgesetzt; zuerst wird der
  tatsächliche Engine-Build geprüft und ein bereits wirksames CU übernommen;
- `CONFIGURATION_PENDING`: ebenfalls denselben Schlüssel fortsetzen;
- `ACTIVATION_REQUIRED`: Konnektivität, External-Switch und den konkreten
  Microsoft-Aktivierungsfehler prüfen, dann die Gruppenreparatur ausführen;
- OOBE unterbrochen: `-Action Image` → `[4] Betriebssystem- und SQL-Slots
  verwalten` → `[o] Windows-Grundinstallation übernehmen`.

Keinen Ersatzslot mit Suffix anlegen und den reservierten Run nicht einzeln
löschen. Die Registry bindet die Wiederaufnahme an den stabilen Schlüssel.

## 6. `TestUmgebung.json` und Gruppenstatus prüfen

Nach dem Auftrag im Composer `Export aktualisieren` wählen. Der kanonische
Vertrag liegt unter `Lab_Data/Exports/TestUmgebung.json`; sein Ort wird über
Benutzervariablen veröffentlicht. Die Prüfung gibt keine Secrets aus:

```powershell
$contractPath = [Environment]::GetEnvironmentVariable(
    'SQL_SERVER_LAB_TEST_ENV_FILE', 'User')
$schemaPath = [Environment]::GetEnvironmentVariable(
    'SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE', 'User')

if (-not $contractPath -or -not $schemaPath) {
    throw 'Testumgebungs- oder Schemapfad ist nicht konfiguriert.'
}
if (-not (Test-Json -LiteralPath $contractPath -SchemaFile $schemaPath)) {
    throw 'TestUmgebung.json entspricht nicht dem Schema.'
}

$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
$expected = @(
    'LINUX_2019_LATEST', 'LINUX_2022_LATEST', 'LINUX_2025_LATEST',
    'WINDOWS_2019_BASE', 'WINDOWS_2022_BASE', 'WINDOWS_2025_BASE'
) | Sort-Object
$actual = @($contract.environments.key | Sort-Object -Unique)
$delta = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
$notReady = @($contract.environments | Where-Object status -ne 'READY')

if ($contract.groupStatus -ne 'READY' -or $delta.Count -gt 0 -or
    $notReady.Count -gt 0) {
    throw 'Die Sechs-Ziele-Testgruppe ist nicht vollständig READY.'
}

[pscustomobject]@{
    GroupStatus = $contract.groupStatus
    Ready       = $contract.environments.Count
    Keys        = $actual
}
```

Verbindliche Freigaberegel für Tests:

- oberstes `groupStatus` muss `READY` sein;
- alle sechs Schlüssel müssen vorhanden sein;
- jeder Einzelstatus muss `READY` sein.

Fehlt ein Ziel, ist es gestoppt, ungesund, lizenzseitig nicht bestätigt oder
SQL nicht authentifiziert erreichbar, bleibt der Vertrag fail-closed:
`groupStatus = INCOMPLETE`; die Einträge sind nicht als Teilmenge verwendbar.

## 7. Geschützte Gruppe starten, stoppen und reparieren

Modul laden und zuerst die Vorschau verwenden:

```powershell
Import-Module .\SqlServerLab.psd1 -Force

Start-SqlServerLabAutomatedTestEnvironment -WhatIf
$start = Start-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
$start.Status
$start.Export.GroupStatus

Stop-SqlServerLabAutomatedTestEnvironment -WhatIf
$stop = Stop-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
$stop.Status
$stop.Export.GroupStatus
```

Nach einem erfolgreichen Start müssen `Status` und `Export.GroupStatus`
`READY` melden. Nach einem erfolgreichen Stopp lautet der Aktionsstatus
`STOPPED`; der erneuerte Export ist absichtlich `INCOMPLETE`, weil gestoppte
Ziele nicht verwendet werden dürfen. Runs, Secrets, Volumes und VHDX bleiben
erhalten.

Bei Ressourcen-, Health-, Autostart-, Namens- oder Aktivierungsdrift:

```powershell
Repair-SqlServerLabAutomatedTestEnvironment -WhatIf
Repair-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
```

Die normalen Einzel-Start-, Stopp-, Ressourcen- und Löschpfade sperren diese
Runs. Nur `Clear-SqlServerLabAutomatedTestEnvironment` entfernt nach bewusster
Bestätigung die gesamte geschützte Gruppe.

## 8. Separaten SQL-2025-CMS erstellen

Der Standardweg ist ein dedizierter kompakter SQL-2025-Container. Keines der
sechs geschützten Testgruppenmitglieder darf als CMS verwendet werden; der
Kandidatenselektor schließt ihre Run-IDs aus.

### 8.1 CMS bereitstellen und synchronisieren

```powershell
.\Invoke-SqlServerLab.ps1 -Action ConnectionCenter
```

Der gleichwertige Hauptmenüpfad lautet:

`Datenbanken und Verbindungen` → `Verbindungszentrale und SSMS-Endpunkte` →
`CMS verwalten und synchronisieren`

Danach:

1. `Kompakten persistenten CMS automatisch erstellen` wählen.
2. Die Erstellung ausdrücklich bestätigen. Docker wird bevorzugt, Podman ist
   der Fallback.
3. Das einmalig angezeigte CMS-SA-Passwort sofort sicher ablegen.
4. Die automatisch gestartete Synchronisation abwarten.
5. In der CMS-Verwaltung `CMS jetzt synchronisieren` erneut ausführen, falls
   die erste Synchronisation unterbrochen wurde.
6. `CMS-Zugang anzeigen` öffnen und das ausgegebene Serverziel notieren.

Der CMS verwendet SQL Server 2025, das Profil `compact`, persistente Daten und
`AutoStart = on`. Er wird nicht in seinen eigenen CMS-Unterbaum eingetragen.

Alternativ kann `Bestehende SQL-Umgebung als CMS verwenden` einen anderen
geeigneten, nicht geschützten Run übernehmen. Dieser Run muss einen nutzbaren
SQL-Endpunkt und ein lokal geschütztes oder ausdrücklich eingegebenes
SA-Passwort besitzen. Er wird anschließend als CMS-Systemdienst geschützt. Für
die sechs Matrix-Runs ist diese Alternative absichtlich nicht verfügbar.

### 8.2 CMS in SSMS registrieren

1. SSMS öffnen.
2. `Ansicht` → `Registrierte Server` wählen.
3. `Datenbankmodul` → `Zentrale Verwaltungsserver` öffnen.
4. Einen neuen Central Management Server mit exakt dem im CMS-Menü angezeigten
   Serverziel registrieren.
5. `SQL Server-Authentifizierung`, Login `sa` und das einmalig gesicherte
   CMS-Passwort verwenden. SQL-Authentifizierung ist für einen CMS zulässig;
   siehe [Microsoft Learn: Create a central management server and server group](https://learn.microsoft.com/en-us/ssms/register-servers/create-a-central-management-server-and-server-group).
6. Den CMS-Knoten aktualisieren.
7. `SQL Server Lab` → `Running` aufklappen. Bei vollständig bereiter Gruppe
   müssen dort sechs Testendpunkte erscheinen, optional unter `DOCKER`,
   `PODMAN` und `HYPERV`.

Die verwalteten Zielregistrierungen enthalten keine Kennwörter. Bleibt die
Testgruppe unvollständig, veröffentlicht der CMS-Sync keines ihrer Mitglieder.

## 9. Abschlusscheck und Recovery

Der Aufbau ist erst fertig, wenn alle folgenden Aussagen stimmen:

- genau eine passende immutable `OS_SEALED`-Baseline ist registriert;
- drei unabhängige Windows-Child-Slots wurden verwendet;
- jeder Windows-Run meldet `SQL_SLOT_READY` und einen bestätigten
  Lizenzstatus;
- `TestUmgebung.json` ist schema-valide und enthält exakt die sechs Schlüssel;
- `groupStatus = READY` und alle Einzelstatus sind `READY`;
- der dedizierte CMS läuft getrennt von der Testgruppe;
- SSMS zeigt unter `SQL Server Lab` → `Running` alle sechs Ziele.

Bei einem Teilfehler den gespeicherten Resume-/Repair-Pfad verwenden. Keine
Parent-VHDX, Child-VHDX, VM, Container, Registry-Datei oder Run-State manuell
verschieben oder löschen; dadurch würden Ownership-, Recovery- und
Cleanup-Nachweise verloren gehen.

## 10. Evidence und Vertiefung

Der [Validierungsbericht vom 29. August 2026](../Quality/VALIDATION_RESULT_2026-08-29_TEST_ENVIRONMENT_GROUP_LIFECYCLE.md)
dokumentiert einen historischen realen Sechs-Ziele-Lauf mit Gruppen-Start,
-Stopp und Wiederherstellung. Er ist keine Aussage, dass der Ablauf bei der
Ausführung dieser Anleitung erneut gelaufen ist. Aktuelle Runtimegrenzen stehen
unter [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md).

Vertiefende Anleitungen:

- [Hyper-V Slot- und SQL-Installationsworkflow](HYPERV_SLOT_SQL_WORKFLOW.md)
- [Automatisierte Testumgebungen](../User/AUTOMATED_TEST_ENVIRONMENTS.md)
- [SQL-Verbindungszentrale](../User/SQL_CONNECTION_CENTER.md)
- [Persistente Daten und Evaluation-Refresh](PERSISTENT_DATA_AND_EVALUATION_REFRESH.md)
