# Tools/ – Operator- und Repository-Werkzeuge

| Werkzeug | Zweck |
|---|---|
| [Initialize-SqlServerLabMediaRoot.ps1](Initialize-SqlServerLabMediaRoot.ps1) | Erstellt einen externen Media Root samt lokalen Download-READMEs, sortiert vorhandene ISO/VHDX/Installer optional ein und erzeugt auf Wunsch SHA-256-Sidecars |
| [Initialize-SqlServerLabDataRoot.ps1](Initialize-SqlServerLabDataRoot.ps1) | Erstellt den getrennten langlebigen Data Root für Evaluation-Refresh, Backups und versionsgebundene Datenbankdateien |
| [Start-SqlServerLabUi.ps1](Start-SqlServerLabUi.ps1) | Startet das lokale Browser-Cockpit für Workflow, Hintergrundaktionen und Live-Logs auf 127.0.0.1 |
| [Prepare-LocalRelease.ps1](Prepare-LocalRelease.ps1) | Erzeugt ein reproduzierbares lokales Release-Artefakt inkl. Manifest, optionalem SHA-256-Digest und optionalem ZIP-Archiv |
| [Get-CiTestSelection.ps1](Get-CiTestSelection.ps1) | Klassifiziert geänderte Pfade für schnelle, betroffene PR-Checks und gezielte Runtime-Smokes |
| [Initialize-SqlServerLabHostTools.ps1](Initialize-SqlServerLabHostTools.ps1) | Löst Docker, Podman und Python zentral auf und ergänzt fehlende Installationsverzeichnisse ausschließlich im aktuellen Prozess-PATH |
| [CheckLargeGitFilesPush.ps1](../CheckLargeGitFilesPush.ps1) | Prüft staged/untracked Dateien auf Größe, schreibt optional Log und kann Commit+Push nach Prüfung ausführen |

Werkzeuge unter `Tools/` sind keine exportierten Cmdlets des PowerShell-Moduls.
Sie werden ausdrücklich über ihren Dateipfad aufgerufen.

## Start-SqlServerLabUi.ps1

Die UI wird per Dateipfad gestartet:

```powershell
.\Tools\Start-SqlServerLabUi.ps1
```

## Standard-Hilfe (Skript-Einstiegspunkte)

Alle Skript-Einstiegspunkte im Projekt unterstützen konsistent `-ShowHelp`/`--help`
als Hilfemodus (PowerShell kann die Schalter `/?`, `-h`, `-help` oder `-?`
je nach Kontext auch direkt als Engine-Hilfe behandeln):

- `./Tools/<script>.ps1 -ShowHelp`
- `./Tools/<script>.ps1 --help`

Projektweit häufig zusätzlich genutzt:

- `.\Invoke-SqlServerLab.ps1 -ShowHelp`
- `.\Tools\Initialize-SqlServerLabDataRoot.ps1 -ShowHelp`
- `.\Tools\Initialize-SqlServerLabMediaRoot.ps1 -ShowHelp`
- `.\Tools\Start-SqlServerLabUi.ps1 -ShowHelp`
- `.\Tools\Prepare-LocalRelease.ps1 -ShowHelp`
- `.\CheckLargeGitFilesPush.ps1 --help`

Damit wird direkt die Skript-spezifische Hilfe angezeigt und anschließend die
Ausführung beendet.

Unterstützte Optionen:

- `-Port <Int>` (Standard: `8484`)
  - Port, auf dem der lokale HTTP-Listener für die UI läuft.
- `-JobStopTimeoutSeconds <Int>` (Standard: `5`, Bereich: `0..300`)
  - Maximale Wartezeit beim Stoppen der laufenden PowerShell-Hintergrundjobs beim Beenden des Scripts.
  - `0` beendet Jobs sofort per harter Bereinigung.
- `-JobLogBurstLimit <Int>` (Standard: `300`, Bereich: `1..2000`)
  - Maximale Anzahl von neuen Log-Zeilen, die pro Polling-Zyklus vom Server übertragen werden.
  - Dient zur Begrenzung der UI-Update-Menge bei aktiven Jobs.

Die UI-Ansicht bietet einen **„Aktualisieren“**-Button für den manuellen Refresh der Workflow-Daten.
Auftragslogs laufen ohnehin im Polling (`/api/jobs`) weiter und werden ebenfalls nach dem Burst-Limit gedrosselt.
