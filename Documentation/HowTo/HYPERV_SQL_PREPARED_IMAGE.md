# SQL Server 2019, 2022 und 2025 als Hyper-V-Prepared-Image

| Merkmal | Wert |
|---|---|
| Betriebssystem | frische Windows-Server-2025-Installation aus einer verifizierten ISO |
| Einstieg | `Invoke-SqlServerLab.ps1 -Action Image` |
| Ziel | ein immutable `SQL_PREPARED_SEALED`-Artifact je SQL-Hauptversion |
| SQL-Features | Database Engine, Full-Text, Replication |
| Netzwerk während Build | internes `SQL_LAB_HYPERV`, kein Egress |

## 1. Standardpfad und Menüstruktur

Der normale Pfad erstellt Windows und SQL in **derselben frischen Builder-VM**
und führt genau einen finalen Windows-Sysprep aus. Das vermeidet den Umgang mit
einer bereits generalisierten OS-Baseline und schont deren Sysprep-Zähler.

| Hauptmenü | Zweck |
|---|---|
| `1` Neues SQL-Prepared-Image erstellen | Geführter Standardpfad: Windows-ISO + SQL-ISO, ein finaler Sysprep |
| `2` Offenen Prepared-Image-Builder fortsetzen | VMConnect, Windows-Bestätigung, SQL `PrepareImage`, Sysprep, Publikation und Recovery |
| `3` Neue Hyper-V-Umgebung aus Prepared-Image erstellen | Aus einem veröffentlichten Image eine ausgeschaltete differenzierende Lab-VM erzeugen |
| `4` Hyper-V-Umgebungen verwalten | Start, VMConnect, Stopp und Entfernen regulärer Lab-VMs |
| `5` Veröffentlichte Images verwalten | Anzeigenamen ändern oder Image kontrolliert löschen |
| `e` Erweitert | OS-Baselines, Abnahme-VMs, Recovery und der historische Baseline-Pfad |

Reguläre Hyper-V-Labs erhalten als VM-Namen `<Projektname>-<RunId-Präfix>`,
zum Beispiel `win-sql2025-6a2e8828`. Der Projektname ist damit im Hyper-V-
Manager direkt wiederzuerkennen und bleibt durch das Präfix eindeutig. Wird ein
Hyper-V-Lab später umbenannt, wird die ausgeschaltete VM mit umbenannt.

Eine run-lokale Abnahmeumgebung ist **kein** Prepared-Image-Schritt. Sie
installiert eine vollständige, konkrete SQL-Instanz für Tests; `PrepareImage`
ist ausschließlich für die portable Vorlage vorgesehen.

## Schnellstart: erster realer SQL-2025-Prepared-Image-Lauf

Diese Anleitung erstellt ein `SQL_PREPARED_SEALED`-Image aus Windows Server
2025 Standard Evaluation, Desktop Experience und SQL Server 2025 Enterprise
Developer. Windows und SQL werden dabei in derselben Builder-VM installiert.

### Vor dem Start

1. Ein erhöhtes PowerShell-Terminal öffnen und das Repository aktualisieren:

   ```powershell
   git pull --ff-only
   .\Invoke-SqlServerLab.ps1 -Action Image
   ```

2. Falls der Einstieg fehlende Hyper-V-Komponenten meldet, die angebotene
   Installation bestätigen. Bei der Meldung `Neustart erforderlich` Windows
   neu starten und diesen Schritt erneut ausführen.

3. Eine Windows-ISO und eine passende SQL-ISO bereitstellen, beispielsweise:

   ```text
   D:\Lab_Base\WindowsServer\2025\Eval\ISO\Windows_Server_2025.iso
   D:\Lab_Base\SQL\2025\Enterprise\ISO\SQLServer2025-x64-ENU-EntDev.iso
   ```

### Frischen Builder erstellen

1. Im Hyper-V-Hauptmenü `1` wählen.
2. Als Media Root `D:\Lab_Base` eingeben oder den angebotenen Default mit
   Enter übernehmen.
3. Die Windows Server 2025 Standard Evaluation / Desktop Experience ISO auswählen.
4. Bei SQL-Version `2025` und SQL-Medien-Edition `Enterprise` bestätigen.
5. Optional einen sprechenden Namen vergeben. Fehlt ein SHA-256-Sidecar,
   dessen Berechnung bestätigen. Der Builder ändert
   dabei keine ISO, sondern schreibt nur die Prüfsumme unter `Hashes`.
6. Den Builder erzeugen, starten und VMConnect öffnen lassen.
7. Windows installieren, die OOBE abschließen, das lokale Passwort für `Administrator` setzen und sich
   einmal vollständig anmelden. Das Passwort nur für den unmittelbar folgenden
   Schritt merken; es wird nicht im Build-State oder Git gespeichert.

Erwarteter Zustand: Die VM läuft, Windows ist angemeldet und der
SQL-Image-Build steht im Menü bei `MANUAL_ACTION_REQUIRED`.

### SQL vorbereiten und einmalig versiegeln

1. Zurück im Hyper-V-Hauptmenü `2` wählen und dort zuerst die Windows-Installation
   bestätigen, anschließend **SQL PrepareImage und finalen Sysprep ausführen** wählen.
2. `Administrator` und das soeben gesetzte Passwort eingeben.
3. Die Bestätigung für `SQL PrepareImage und anschliessend Windows-Sysprep`
   mit `j` geben.
4. Warten, bis der Ablauf `RESUME_PENDING` meldet. SQL Setup kann je nach
   Storage und ISO mehrere Minuten dauern. Falls Setup einen Neustart verlangt,
   wird `REBOOT_REQUIRED` gemeldet: im Untermenü den Builder erneut starten,
   vollständig booten lassen und den SQL-Prepare-Schritt nochmals wählen. `PrepareImage`
   wird dabei nicht doppelt ausgeführt.

Erwarteter Endzustand: Die VM ist ausgeschaltet und der Build hat den Status
`RESUME_PENDING`. Ein nach Sysprep zurückgesetztes Administratorpasswort ist
normal und wird nicht mehr benötigt.

### Image veröffentlichen

1. Im Untermenü **Prepared-Image veröffentlichen** wählen.
2. Für die Windows Evaluation das angezeigte Ablaufdatum prüfen oder eingeben.
3. Die Veröffentlichung bestätigen.

Erwartetes Ergebnis: `SQL_PREPARED_SEALED` mit einer Artifact-ID. Erst eine
spätere Laufzeit-VM führt SQL `CompleteImage` aus und erhält konkrete
Instanz-, Administrator- und Netzwerkdaten.

### Die drei Image-Versionen real prüfen

Die Images werden nacheinander gebaut, nie parallel. Zwischen zwei Läufen
zuerst die Veröffentlichung aus dem vorigen Lauf abwarten und das Ergebnis im
Builder-Status kontrollieren.

| Reihenfolge | Auswahl beim neuen Prepared-Image | Nachweis |
|---|---|---|
| 1 | Windows Server 2025 ISO; SQL 2025 Enterprise | Status `SQL_PREPARED_SEALED`, Artifact-ID und Evaluation-Ende festhalten |
| 2 | Windows Server 2025 ISO; SQL 2022 und passende Medien-Edition | eigener Builder und eigene Artifact-ID |
| 3 | Windows Server 2025 ISO; SQL 2019 und passende Medien-Edition | eigener Builder und eigene Artifact-ID |

Für jeden Lauf gilt: Builder erstellen → Windows installieren → SQL
`PrepareImage` + Sysprep → veröffentlichen. Nur die SQL-Version und die
dazugehörige ISO ändern sich. Ein fehlgeschlagener Builder darf nicht mit einem
anderen Menüpfad weiterverwendet werden: im Prepared-Image-Untermenü aufräumen
und danach einen frischen Builder beginnen. Der Fehlertext und die
`C:\\Windows\\System32\\Sysprep\\Panther`-Logs der betroffenen VM sind
vor dem Aufräumen zu sichern.

Das Aufräumen unfertiger Builder bietet neben einer einzelnen Nummer auch `ALL`. Diese Auswahl
entfernt **alle angezeigten unfertigen** SQL-Builder samt VMs und buildlokalen
VHDX, verlangt eine zweite Gesamtbestätigung und zeigt den Fortschritt. Bereits
veröffentlichte `SQL_PREPARED_SEALED`-Images sind davon ausgeschlossen.

### Laufzeit-VM und SQL CompleteImage

Die lokale Oberfläche erzeugt reguläre Hyper-V-Labs aus einem veröffentlichten
`SQL_PREPARED_SEALED`-Image. Nach dem expliziten VM-Start führt die Aktion
**SQL CompleteImage ausführen** das passende, verifizierte SQL-Medium in der
run-eigenen VM aus und startet `MSSQLSERVER`. Dieser Schritt verändert weder
das Prepared-Image noch die OS-Baseline.

## 2. Erweitert: OS-Baseline und Abnahme-VMs

Der frühere Baseline-Pfad bleibt unter `e` für Experten verfügbar. Er kann die
Windows-Installationszeit senken, erzeugt aber einen bereits generalisierten
Parent und einen weiteren Generalize-Schritt im SQL-Child. Deshalb ist er nicht
mehr der Standardpfad.

Unter `e` liegen außerdem run-lokale Abnahme-VMs und die Offline-Recovery nach
unterbrochenem Sysprep. Diese Funktionen sind für Diagnose und Spezialfälle
gedacht, nicht für die reguläre Image-Erstellung.

Windows Server Core ist dafür gültig. Microsoft unterstützt dort unter anderem
Database Engine, Replication und Full-Text. Die grafische Setup-Oberfläche ist
auf Server Core nicht verfügbar; SQL Setup muss mit `/Q` oder `/QS` ausgeführt
werden. SSMS wird auf einem anderen Rechner installiert und verbindet sich
später remote.

Offizielle Referenzen:

- [SQL Server auf Server Core installieren](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-on-server-core)
- [SQL Server über die Eingabeaufforderung installieren](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt)
- [SQL Server mit SysPrep vorbereiten](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/considerations-for-installing-sql-server-using-sysprep)

## 3. Medien im zentralen Media Root

Beispielroot: `D:\Lab_Base`

```text
D:\Lab_Base\SQL\2019\Eval\ISO\SQLServer2019-x64-ENU.iso
D:\Lab_Base\SQL\2022\Eval\ISO\SQLServer2022-x64-ENU.iso
D:\Lab_Base\SQL\2025\Enterprise\ISO\SQLServer2025-x64-ENU-EntDev.iso
D:\Lab_Base\SQL\2025\Standard\ISO\SQLServer2025-x64-ENU-StdDev.iso
```

Die Struktur wird mit
`Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath 'D:\Lab_Base'`
erzeugt. Genau eine ISO darf im ausgewählten Versions-/Editionsordner liegen.
Vor der ersten VM-Mutation bindet ein SHA-256-Sidecar Digest und relativen Pfad.

## 4. Erweitert: Builder aus einer OS-Baseline erzeugen

```powershell
$env:SQL_SERVER_LAB_MEDIA_ROOT = 'D:\Lab_Base'
.\Invoke-SqlServerLab.ps1 -Action Image
```

Im Hyper-V-Hauptmenü `e` wählen und anschließend **SQL-Builder aus einer
OS-Baseline erstellen**. Danach:

1. veröffentlichte OS-Baseline auswählen;
2. SQL-Version und Medien-Edition auswählen;
3. fehlende SHA-256-Sidecars nach Sichtprüfung erzeugen;
4. Builder bestätigen.

Der Builder erzeugt eine Generation-2-VM mit einer neuen differenzierenden
VHDX, Secure Boot, deaktivierten automatischen Checkpoints und dem internen
`SQL_LAB_HYPERV`-Switch. Nur die SQL-ISO wird eingebunden; ein externer
Netzwerkzugang wird nicht bereitgestellt.

## 5. OOBE für den Abnahme-VM-Pfad: automatisch oder kontrollierter Fallback

Ein generalisiertes Windows-Image startet absichtlich in OOBE. Im
**Abnahme-VM-Pfad** kann der Punkt **OOBE und vollständiges SQL automatisch
installieren** den Schritt vollständig automatisieren. Sie erzeugt ein Zufallspasswort,
speichert es nur lokal per Windows-DPAPI, stoppt die VM, schreibt eine
`Unattend.xml` offline in `Windows\Panther` und startet die VM wieder. Der
verifizierte Zielzustand lautet:

- Region und Systemlocale: Deutschland / `de-DE`;
- UI-Sprache: `en-US`;
- Tastatur: Deutsch / `0407:00000407`;
- Zeitzone: `W. Europe Standard Time`;
- Windows-State: `IMAGE_STATE_COMPLETE`.

Das Offline-Einbinden einer VHDX verlangt unter Windows ein erhöhtes Token mit
dem erforderlichen Volume-Recht. Mitgliedschaft in der Gruppe
`Hyper-V-Administratoren` allein genügt dafür nicht. Läuft der Remote Runner
nicht erhöht, meldet die Runtime
`HYPERV_SQL_OOBE_OFFLINE_MOUNT_REQUIRES_ELEVATED_RUNNER`, ohne den Parent zu
verändern. Dann gilt der kontrollierte Fallback:

1. VMConnect öffnen;
2. Germany, English (United States) und German auswählen;
3. lokales Administratorpasswort festlegen und einmal anmelden;
4. unter `e` → Abnahmeumgebung den Punkt **Manuell abgeschlossene OOBE übernehmen** wählen und das Passwort als SecureString eingeben.

Dieser Abnahmeschritt speichert Gast- und SA-Passwort nur lokal verschlüsselt im
Build-Verzeichnis. Klartext erscheint weder im Build-State noch in Evidenz,
VM-Notizen oder Git. Die Antwortdatei wird nach positivem OOBE-Receipt aus dem
Gast entfernt.

Für den **Prepared-Image-Standardpfad** wird Windows nach dem Start des
frischen Builders in VMConnect installiert. Nach OOBE, lokalem
Administratorpasswort und einer Anmeldung im Hauptmenü `2` den Builder
fortsetzen. Der Punkt **SQL PrepareImage und finalen Sysprep ausführen** führt
SQL `PrepareImage` und den finalen Windows-Sysprep ohne weitere
VMConnect-Interaktion aus.

Offizielle Referenzen:

- [Mount-VHD](https://learn.microsoft.com/en-us/powershell/module/hyper-v/mount-vhd)
- [Windows-Antwortdateien](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/update-windows-settings-and-scripts-create-your-own-answer-file-sxs)

## 6. SQL vorbereiten und Windows generalisieren

Der Punkt **SQL PrepareImage und finalen Sysprep ausführen** führt ohne weitere Setup-GUI aus:

```text
setup.exe /Q /ACTION=PrepareImage
  /FEATURES=SQLENGINE,FULLTEXT,REPLICATION
  /INSTANCEID=MSSQLSERVER
  /ENU=True
  /IACCEPTSQLSERVERLICENSETERMS
```

Setup-Version, Features und Exitcode werden als bereinigtes Receipt
festgehalten. Exitcode `3010` führt zu `REBOOT_REQUIRED`; nach dem Neustart
wird im Prepared-Image-Untermenü der Builder wieder gestartet und der
SQL-Prepare-Schritt erneut gewählt. Anschließend folgt:

```text
Sysprep.exe /generalize /oobe /mode:vm /quit /quiet
```

Nur der Microsoft-State `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE` und ein
beobachteter Gast-Shutdown führen zu `RESUME_PENDING`.

### Grenzen von Windows Sysprep

Windows kann ein einzelnes Image nur begrenzt lizenzseitig rearmen. Meldet
Sysprep `SLReArmWindows` mit `0xC004D307`, ist dies keine SQL-Installation und
auch kein Passwortfehler: Die zulässige Anzahl wurde für genau diese
VHDX-Kette bereits überschritten. Das betroffene SQL-Prepared-Image kann nicht
fertiggestellt werden. Im Prepared-Image-Untermenü wird der fehlgeschlagene
Builder aufgeräumt und ein frischer Builder aus den Originalmedien begonnen.
**Bestehende reguläre Lab-VMs bleiben weiter nutzbar**, solange sie nicht
erneut mit Sysprep generalisiert werden.

Die Details stehen nach der Offline-Recovery im Build-State als
`sysprepFailureDetail`; die Menümeldung nennt die notwendige Maßnahme direkt.
Microsoft dokumentiert für `0xC004D307` ebenfalls den Neuaufbau des
Windows-Images als Lösung.

- [Sysprep /generalize: Fehler 0xC004D307](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/error-occurs-when-running-sysprep-generalize)

## 7. Immutable SQL-Baseline veröffentlichen

Der Punkt **Prepared-Image veröffentlichen** prüft VM-Identität, Auszustand, fehlende Checkpoints und den
buildlokalen VHDX-Pfad. Die differenzierende Builder-VHDX wird mit `Convert-VHD` in eine
eigenständige dynamische VHDX überführt; damit gilt derselbe sichere
Publikationsschritt auch für künftige Disk-Typen. Erst danach erfolgen
SHA-256, Registry-Import und Metadatenprüfung. VM und lokale Build-VHDX werden
erst nach erfolgreichem Registry-Import entfernt.

Das Ergebnis ist ein `SQL_PREPARED_SEALED`-Artifact. Eine spätere Lab-VM muss
noch SQL `CompleteImage` ausführen und Instanzkonto, Administratoren,
Authentifizierung und Pfade konfigurieren.

## 8. Evaluation und Developer

Windows- und SQL-Lizenzstatus werden getrennt gespeichert:

- das Ablaufdatum einer Windows-Evaluation wird bei der Publikation erfasst;
- ein SQL-Evaluation-Image vermerkt, dass seine Evaluation erst bei
  `CompleteImage` beginnt; ein erfundenes Ablaufdatum wird nicht gespeichert;
- Enterprise Developer und Standard Developer sind nicht für Produktion
  freigegeben;
- ein ablaufendes Image wird neu aus Originalmedien gebaut, nicht verlängert
  oder manipuliert.

Datenbanken liegen nicht im austauschbaren Image. Der Refresh- und
Backupvertrag steht unter
[Persistente Daten und Evaluation-Refresh](PERSISTENT_DATA_AND_EVALUATION_REFRESH.md).

## 9. Direkte Windows-SQL-Abnahmeumgebungen

Neben dem Prepared-Image-Lifecycle können vorhandene run-lokale
Abnahmeumgebungen vollständig installiert und getestet werden:

- OOBE und vollständiges SQL Setup automatisch ausführen;
- manuell abgeschlossene OOBE übernehmen und SQL Setup ausführen;
- Create/Insert/Select, Backup mit `CHECKSUM`, `RESTORE VERIFYONLY`
  und Cleanup testen;
- Matrix für SQL 2019, 2022 und 2025 anzeigen.

Die drei erwarteten SQL-Major-Versionen sind 15, 16 und 17. Ein System erhält
erst nach Dienst-, Versions- und Systemdatenbankprüfung `SQL_READY_RUN`; erst
der vollständige Datenbank-/Backup-Test führt zu `TESTS_PASSED`.

## 10. Aktueller Nachweisstand

Der Host-Lifecycle, Medienresolver, resumierbare Receipts, Secret-Freiheit,
Publikation nach VHDX-Konvertierung und Menüpfad sind automatisiert getestet. Der reale
`PrepareImage`-Lauf mit den bereitgestellten Microsoft-ISOs und die direkte
SQL-2019/2022/2025-Abnahmematrix sind die nächsten nativen Schritte. Auf einem
nicht erhöhten Runner bleibt der dokumentierte OOBE-Fallback einmalig nötig.
Der feste interne Hyper-V-Hostzugriff ist implementiert; runtimeübergreifende
Netze und kontrollierter Internet-Egress sind nicht Teil dieses Nachweises.
