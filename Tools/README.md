# Tools/ – Operator- und Repository-Werkzeuge

| Werkzeug | Zweck |
|---|---|
| [Initialize-SqlServerLabMediaRoot.ps1](Initialize-SqlServerLabMediaRoot.ps1) | Erstellt einen externen Media Root samt lokalen Download-READMEs, sortiert vorhandene ISO/VHDX/Installer optional ein und erzeugt auf Wunsch SHA-256-Sidecars |
| [Initialize-SqlServerLabDataRoot.ps1](Initialize-SqlServerLabDataRoot.ps1) | Erstellt den getrennten langlebigen Data Root für Evaluation-Refresh, Backups und versionsgebundene Datenbankdateien |
| [Start-SqlServerLabUi.ps1](Start-SqlServerLabUi.ps1) | Startet das lokale Browser-Cockpit für Workflow, Hintergrundaktionen und Live-Logs auf 127.0.0.1 |
| [Prepare-LocalRelease.ps1](Prepare-LocalRelease.ps1) | Erzeugt ein reproduzierbares lokales Release-Artefakt inkl. Manifest, optionalem SHA-256-Digest und optionalem ZIP-Archiv |
| [Get-CiTestSelection.ps1](Get-CiTestSelection.ps1) | Klassifiziert geänderte Pfade für schnelle, betroffene PR-Checks und gezielte Runtime-Smokes |
| [Get-SqlServerCuStatus.ps1](Get-SqlServerCuStatus.ps1) | Zeigt den read-only CU-Abgleich mit den wartbar katalogisierten Microsoft-Learn-Buildtabellen an |
| [Initialize-SqlServerLabHostTools.ps1](Initialize-SqlServerLabHostTools.ps1) | Löst Docker, Podman und Python zentral auf und ergänzt fehlende Installationsverzeichnisse ausschließlich im aktuellen Prozess-PATH |
| [New-WindowsServer2003SysprepMedia.ps1](New-WindowsServer2003SysprepMedia.ps1) | Erzeugt aus dem hashgebundenen offiziellen SP2-x86-ISO ein schlüsselfreies AutoRun-Hilfsmedium für den Legacy-Sysprep-Reseal |
| [New-WindowsServer2003LegacyChild.ps1](New-WindowsServer2003LegacyChild.ps1) | Erzeugt einen Generation-1-Child mit deutschem Login-Layout, automatisiert Mini-Setup und verifiziert den Aktivierungsversuch über eine temporäre NIC fail-closed |
| [Invoke-WindowsServer2003LegacyActivation.ps1](Invoke-WindowsServer2003LegacyActivation.ps1) | Setzt das deutsche Login-Layout eines Server-2003-Childs und versucht optional die offizielle Gast-WMI-Aktivierung; die temporäre Internet-NIC wird stets entfernt |
| [New-WindowsServer2003SqlAcceptanceEnvironment.ps1](New-WindowsServer2003SqlAcceptanceEnvironment.ps1) | Erstellt einen frischen Windows-Server-2003-Evaluation-Child innerhalb der Aktivierungs-Gnadenfrist, staged den lokalen SQL-2005-Job offline und startet bzw. beobachtet ihn über Legacy-WMI |
| [Test-WindowsServer2003HyperVIntegrationMedia.ps1](Test-WindowsServer2003HyperVIntegrationMedia.ps1) | Prüft Hash, VMGUEST-Volume, Version und Microsoft-Signaturen der archivierten Hyper-V-Integrations-DVD für Server 2003 SP2 |
| [New-LegacySqlServerAcceptanceEnvironment.ps1](New-LegacySqlServerAcceptanceEnvironment.ps1) | Erstellt oder übernimmt reale SQL-Server-2012-Evaluation- und SQL-Server-2014-Express-SP3-Abnahmeumgebungen auf der verifizierten Windows-Server-2012-R2-Vorlage und prüft Setup, Dienst, Version, Create, Backup und Restore |
| [Invoke-SqlServerLabMaintenance.ps1](Invoke-SqlServerLabMaintenance.ps1) | Plant oder korrigiert State-/Runtime-Drift und bereinigt eng gebundene Lab-Artefakte deterministisch; geeignet für manuelle Aufrufe und Windows Task Scheduler |
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
- `.\Tools\New-WindowsServer2003SysprepMedia.ps1 -ShowHelp`
- `.\Tools\New-WindowsServer2003LegacyChild.ps1 -ShowHelp`
- `.\Tools\Invoke-WindowsServer2003LegacyActivation.ps1 -ShowHelp`
- `.\Tools\New-WindowsServer2003SqlAcceptanceEnvironment.ps1 -ShowHelp`
- `.\Tools\Test-WindowsServer2003HyperVIntegrationMedia.ps1 -ShowHelp`
- `.\Tools\New-LegacySqlServerAcceptanceEnvironment.ps1 -ShowHelp`
- `.\Tools\Start-SqlServerLabUi.ps1 -ShowHelp`
- `.\Tools\Prepare-LocalRelease.ps1 -ShowHelp`
- `.\Tools\Invoke-SqlServerLabMaintenance.ps1 -ShowHelp`
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
