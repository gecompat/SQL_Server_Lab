# Tools/ – Operator- und Repository-Werkzeuge

| Werkzeug | Zweck |
|---|---|
| [Initialize-SqlServerLabMediaRoot.ps1](Initialize-SqlServerLabMediaRoot.ps1) | Erstellt einen externen Media Root samt lokalen Download-READMEs, sortiert vorhandene ISO/VHDX/Installer optional ein und erzeugt auf Wunsch SHA-256-Sidecars |
| [Initialize-SqlServerLabDataRoot.ps1](Initialize-SqlServerLabDataRoot.ps1) | Erstellt den getrennten langlebigen Data Root für Evaluation-Refresh, Backups und versionsgebundene Datenbankdateien |
| [Start-SqlServerLabUi.ps1](Start-SqlServerLabUi.ps1) | Startet das lokale Browser-Cockpit für Workflow, Hintergrundaktionen und Live-Logs auf 127.0.0.1 |

Werkzeuge unter `Tools/` sind keine exportierten Cmdlets des PowerShell-Moduls.
Sie werden ausdrücklich über ihren Dateipfad aufgerufen.
