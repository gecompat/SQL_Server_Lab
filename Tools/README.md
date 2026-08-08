# Tools/ – Operator- und Repository-Werkzeuge

| Werkzeug | Zweck |
|---|---|
| [Initialize-SqlServerLabMediaRoot.ps1](Initialize-SqlServerLabMediaRoot.ps1) | Erstellt einen externen Media Root samt lokalen Download-READMEs, sortiert vorhandene ISO/VHDX/Installer optional ein und erzeugt auf Wunsch SHA-256-Sidecars |
| [Initialize-SqlServerLabDataRoot.ps1](Initialize-SqlServerLabDataRoot.ps1) | Erstellt den getrennten langlebigen Data Root für Evaluation-Refresh, Backups und versionsgebundene Datenbankdateien |
| [Start-SqlServerLabUi.ps1](Start-SqlServerLabUi.ps1) | Startet das lokale Browser-Cockpit für Workflow, Hintergrundaktionen und Live-Logs auf 127.0.0.1 |

Werkzeuge unter `Tools/` sind keine exportierten Cmdlets des PowerShell-Moduls.
Sie werden ausdrücklich über ihren Dateipfad aufgerufen.

## Start-SqlServerLabUi.ps1

Die UI wird per Dateipfad gestartet:

```powershell
.\Tools\Start-SqlServerLabUi.ps1
```

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
