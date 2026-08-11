# Interaktiver Erstellungs-Workflow (Ziel zuerst)

## Ziel

Dieser Leitfaden beschreibt den neuen, stabilen Interaktionspfad für
`Invoke-SqlServerLab.ps1` im Menüpunkt **[1] Neue Umgebung erstellen**.

Der Unterschied ist bewusst:

1. Erst wird festgelegt, **welcher Laufzeittyp** gewünscht ist.
2. Danach wird nur bei Bedarf der Provider abgefragt.

## Ablauf

Nach dem Hauptmenü:

```text
Auswahl: 1   # Neue Umgebung erstellen
```

### Schritt 1: Zieltyp wählen

```text
Umgebungstyp:
  [1] SQL-Umgebung
  [2] Windows-OS-Slot (für spätere SQL-Nachrüstung)
  Ziel [1]:
```

- `1` = normale SQL-Umgebung (mit SQL-Ziel)
- `2` = reiner Windows-OS-Slot über Hyper-V (manuelle OOBE + Übernahme Schritt für Schritt)

### Schritt 2: SQL-Sollzustand festlegen

Bei `1` wird nicht mehr zuerst nach einem Provider gefragt. Zunächst wird die
gewünschte Umgebung beschrieben:

```text
SQL-Zielkonfiguration:
  [1] Schnellkonfiguration mit sichtbaren Standardwerten
  [2] Benutzerdefiniert: OS, Edition, Netzwerk, Storage, I/O, TempDB und Collation
```

Die benutzerdefinierte Konfiguration erfasst SQL-Version und CU, Edition,
Windows-Anforderung, Zweck, vCPU, RAM, Netzwerk, Port, Collation, SQL-Memory,
MAXDOP, Cost Threshold, TempDB-Dateien sowie getrennte Data-, Log-, TempDB- und
Backup-Datenträger einschließlich optionaler IOPS-Limits.

Quick und Custom werden anschließend als cursorbasiertes, editierbares Formular
angezeigt. `Enter` bearbeitet das fokussierte Feld, `F10` wechselt zur
vollständigen Review-Ansicht. Fehler wie ein unzulässiger Hostport, eine
ungültige Collation oder SQL-Memory oberhalb des verfügbaren Lab-RAMs blockieren
die Bestätigung. Erst `Anwenden` in der Review-Ansicht übergibt den Intent an die
Providerentscheidung; Navigation und Bearbeitung erzeugen keine Umgebung.

### Schritt 3: Provider automatisch bestimmen

- Docker wird bevorzugt, wenn ein Linux-Container alle Anforderungen erfüllt.
- Ist Docker nicht verfügbar, wird Podman verwendet.
- Hyper-V wird nur erzwungen, wenn Windows, eine Nicht-Developer-Edition, ein
  SQL-Pool-Slot, Isolation oder reproduzierbare VHDX-IOPS benötigt werden.
- Nicht reproduzierbare Kombinationen werden vor jeder Mutation mit den
  konkreten Gründen abgelehnt.
- Ein externes LAN wird ohne expliziten IP-/Gateway-/DNS-Vertrag nicht geraten,
  sondern kontrolliert abgewiesen.

### Schritt 4: Weiterer Pfad

- Bei `Windows-OS-Slot` wird die Slot-Erzeugung direkt nach Hyper-V geroutet.
- Bei `SQL-Umgebung + hyperv` wird der Hyper-V-SQL-Pfad gestartet.
- Bei `SQL-Umgebung + docker/podman` wird der Container-Pfad gestartet.
- Für Container stehen SQL Server 2017, 2019, 2022 und 2025 katalogbasiert
  zur Auswahl. Danach kann `latest` oder eine konkrete katalogisierte CU gewählt
  werden. Eine konkrete CU verwendet einen festen MCR-Tag; `latest` verändert
  sich mit neuen Microsoft-Veröffentlichungen.
- Container erhalten die exakt eingegebenen CPU-/RAM-Limits, den Hostport, die
  Collation, getrennte Volumes und anschließend die deklarierte SQL-/TempDB-
  Konfiguration. Dezimalwerte für CPU verwenden immer einen Punkt.
- Hyper-V übernimmt denselben Sollzustand in VM-Ressourcen, Zusatz-VHDX,
  VHDX-IOPS, SQL-Setup-Parameter und die SQL-Postkonfiguration.

Fehlen im interaktiven Hyper-V-SQL-Pfad Vorlagen, endet die Erstellung nicht
mit einem bloßen Fehler:

- Eine vorhandene SQL-Prepared-Vorlage wird direkt geklont.
- Fehlt eine SQL-Vorlage, prüft der Einstieg zuerst vorhandene Windows-Slots ohne
  SQL-Ausbau. Ein solcher Slot wird standardmäßig fortgesetzt; mit `[n]` kann
  ausdrücklich stattdessen ein neuer Slot aus der OS-Vorlage erzeugt werden.
- Ein bereits übernommener Slot fährt direkt mit SQL-Planung und Installation fort.
  Bei einem Slot mit offener OOBE werden VM-Start, VMConnect und die Bestätigung
  wieder in denselben geführten Ablauf aufgenommen.
- Ein unterbrochener SQL-Ausbau mit gespeichertem Plan wird ebenfalls unter `[1]`
  angeboten. Nach erfolgreichem Setup wird nur die noch offene Hostzugriffs- und
  Netzwerkkonfiguration fortgesetzt; SQL Setup wird nicht erneut gestartet.
- SQL Setup gilt erst dann als abgeschlossen, wenn neben dem Prozess-Exitcode auch
  die SQL-Instanz in der Registry und der zugehörige Windows-Dienst vorhanden sind.
- Fehlt sie, wird eine vorhandene Windows-OS-Vorlage für einen neuen Windows-Slot
  verwendet. VM-Start und VMConnect erfolgen automatisch; OOBE bleibt manuell.
- Der Workflow bleibt während der OOBE geöffnet. Nach der vollständigen ersten
  Anmeldung wird direkt im laufenden Dialog mit `[a] Alles erledigt` bestätigt.
- Danach prüft das Framework die OOBE, übernimmt den Slot, richtet das Labnetz ein,
  fragt die SQL-Zielwerte mit Defaults ab, fährt die VM für Änderungen an vCPU und
  Datenträgern automatisch sauber herunter und führt die SQL-Installation aus. Ein
  Wechsel in das Hyper-V-Verwaltungsmenü ist im Normalfall nicht erforderlich.
- `[b] Problem - Workflow abbrechen` hält den Ablauf kontrolliert an und lässt den
  Slot bestehen. Nur für diesen Wiederaufnahmefall dient `[i] -> [4] -> [o]`.
- Fehlt auch die OS-Vorlage, wird ein offener OS-Builder fortgesetzt oder ein
  neuer Builder aus der Windows-DVD begonnen.
- Nach Veröffentlichung der OS-Vorlage wird `[1] Neue Umgebung erstellen`
  erneut gewählt; der Workflow setzt dann beim Windows-Slot fort.
- Manifest- und NonInteractive-Aufrufe brechen weiterhin eindeutig ab, wenn die
  notwendige fertige SQL-Vorlage fehlt, weil dort keine OOBE übernommen werden kann.

## Hinweise zur Bedienbarkeit

- Das Hauptmenü und die Auswahl aktiver Umgebungen verwenden bei geeigneter
  Konsole einen gemeinsamen cursorbasierten Viewport. Direkte Buchstaben- und
  Ziffernshortcuts bleiben erhalten; `F5` aktualisiert ausdrücklich den
  jeweiligen Snapshot. Ohne sichere Konsolensteuerung bleibt derselbe Ablauf
  nummeriert beziehungsweise buchstabenbasiert über `Read-Host` verfügbar.
- Im geführten SQL-Workflow werden OOBE-Übernahme, SQL-Planung und Installation
  nach der Bestätigung ohne Menüwechsel ausgeführt.
- Einzeln angelegte OS-Slots und bewusst abgebrochene Abläufe können weiterhin mit
  `[o] Windows-Grundinstallation übernehmen` fortgesetzt werden.
- Für einen vorbereiteten SQL-Pool-Slot kann stattdessen direkt mit `[x]`
  die Installation im Slot ausgeführt werden.
- Unter **[u] Docker-/Podman-Umgebung ändern** werden `vCPU`, `RAM MB` und
  `Hostport` per Feldvalidierung geprüft.
- Das Menü in `u` ist feldbasiert (`↑/↓`, Enter), bei ungültigen Werten gibt es
  konkrete Hinweise statt sofortiger Abbrüche.
- Der Dialog verwendet die gemeinsame Console-UI-Schicht mit stabilem Fokus,
  Viewport und In-place-Refresh ohne `Clear-Host` pro Tastendruck. Sample-Auswahl,
  Hyper-V-Image-, Slot- und Verwaltungsmenüs verwenden denselben Renderer; `Space`
  schaltet mehrere Samples um, `Enter` übernimmt und `Esc` bricht ohne Auswahl ab. Container- und
  Statusdaten werden davor einmalig geladen; Pfeiltasten zeichnen nur diesen
  gespeicherten Snapshot neu und lösen keine Docker-/Podman-Abfragen aus. In
  Hosts ohne sichere `System.Console`-Steuerung bleibt der nummerierte
  `Read-Host`-Fallback vollständig bedienbar.
- Vor der Containeränderung werden CPU, RAM und Port gemeinsam validiert und in
  einer Review-Ansicht gezeigt. Erst die dortige Aktion `Anwenden` ruft den
  bestehenden Reconcile-Pfad auf.
- Unter `[k] SQL-Verbindungszentrale` stehen der passwortfreie Endpunktkatalog,
  ein SSMS-`.regsrvr`-Export, die sichere Aktualisierung einer lokalen SSMS-Gruppe
  sowie ein idempotentes CMS-Synchronisationsskript zur Verfügung.

## Erledigt-Liste

- Menüsequenz fragt jetzt zuerst Zieltyp statt Provider.
- SQL-Anforderungen werden vollständig vor der automatischen Providerentscheidung
  erfasst und validiert.
- Windows-OS-Slot startet mit klarer Trennung von SQL-Umgebung.
- Interaktive Anleitung für den neuen Fluss wurde dokumentiert.
- SQL Server 2017 und konkrete CU-Images sind im Containerdialog auswählbar.
- Der interaktive Hyper-V-SQL-Pfad baut fehlende OS-Vorstufen auf; Manifestläufe
  bleiben bei fehlenden Vorlagen fail-closed.
- Der geführte Hyper-V-SQL-Pfad wartet inline auf die OOBE-Bestätigung und setzt
  danach Übernahme, Netzwerkkonfiguration und SQL-Installation automatisch fort.

## Backlog

- Einheitliche, einheitlich lokalisierte Menütexte für Hyper-V-spezifische
  Entscheidungspunkte (DE/EN).
- End-to-End-Signal für "Slot ist für SQL sofort lauffähig" als separate, farbige
  Statusspur in der Umgebungsliste.

## Lokale Smoke-Checks

```powershell
[System.Management.Automation.Language.Parser]::ParseFile(
  'Public\\Invoke-SqlServerLab.ps1',
  [ref]$null,
  [ref]$null
)
.\Tests\Static\Invoke-DocumentationChecks.ps1
```
