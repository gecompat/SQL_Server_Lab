# Hyper-V Slot- und SQL-Installationsworkflow

Diese Anleitung beschreibt den aktuellen **Interaktionspfad für Hyper-V-Slots**
im Menüsystem nach der aktuellen Implementierung:

- OS-Slot: reine Windows-VM aus `OS_SEALED` erzeugen
- SQL-Slot-Setup: SQL-Plan setzen und optional direkt installieren
- SQL-Prepared-Image-Pfad: bestehende vorbereitete Slots weiterverarbeiten

## Zielbild

Typischer Ablauf:

1. Baseline-OS vorbereiten (`OS_SEALED`)
2. OS-Slot erzeugen (run-lokale Child-VHDX)
3. Windows-OOBE manuell im Gast abschließen
4. bei automatisierten Testslots die Windows-Evaluation in der eindeutigen,
   wiederverwendbaren Child-VHDX online aktivieren
5. Slot übernehmen (`o`)
6. SQL-Ausbau festlegen (`a`) und direkt installieren (`x` optional automatisch)
7. Slot als fertigen SQL-Slot nutzen oder als Vorlage weiterverwenden

## 1) OS-Baseline erzeugen

1. Hyper-V-Image-Meldung starten:

```powershell
.\Invoke-SqlServerLab.ps1 -Action Image
```

2. Menü: `i` → **Windows-OS-Baselines verwalten**
3. neuen Builder ausführen bis zur allgemeinen Veröffentlichung:

- ISO auswählen, Build durchführen
- im Builder-Menü Gast starten und OOBE manuell beenden
- manuelle OOBE/Installation quittieren
- Sysprep über die Menüsequenz starten
- VHDX als `OS_SEALED` veröffentlichen

Die veröffentlichte OS-Baseline kann als reine Windows-Vorlage verwendet werden.

## 2) Windows-Slot aus OS-Baseline erstellen

1. Hauptmenü `Hyper-V` aufrufen.
2. Aktion **[1] Neue Hyper-V-Umgebung aus Windows- oder SQL-Vorlage erstellen**.
3. Zieltyp direkt auswählen (ab sofort in diesem Pfad):

- `[2] Windows-OS-Slot für spätere Anpassung/Installation`

4. OS-Slot auswählen und bestätigen.

Seit dem neuen Codepfad wird die VM bei Slot-Erstellung automatisch gestartet
und VMConnect geöffnet, damit das OOBE direkt im Fenster weitergeführt werden kann.

> Bei SQL-Zielen läuft die Provider-Auswahl danach. Dadurch wird verhindert, dass du
> bereits vor der Zielentscheidung den richtigen Container-/Hyper-V-Anbieter raten musst.

## 3) Windows-Manual OOBE prüfen und übernehmen

1. Zur Slot-Verwaltung:

```powershell
.\Invoke-SqlServerLab.ps1
Hyper-V → [5] Hyper-V-Umgebungen verwalten → [i] SQL-Slots verwalten (Windows-Slot auswählen)
```

2. Aktion **[o] Windows-Grundinstallation übernehmen**

Das Menü startet/öffnet die VM automatisch, zeigt die OOBE-Schritte und fragt:

```text
  Hast du die Windows-Grundinstallation vollständig abgeschlossen?
  [a] Ja / [b] Problem - jetzt abbrechen [b]
```

Nach Bestätigung werden im gleichen Aufruf automatisch die gespeicherten
Gastanmeldedaten geprüft und die Übernahme abgeschlossen.

Im automatisierten Testumgebungsauftrag folgt jetzt vor SQL Setup zusätzlich
der Aktivierungs-Gate. Der Auftrag bindet eine temporäre zweite NIC an den
ausdrücklich gewählten verbundenen External-Switch, aktiviert die Evaluation
online und entfernt diese NIC garantiert wieder. Es wird weder die Edition
konvertiert noch ein Product Key verlangt. Die `OS_SEALED`-Baseline und die
interne Lab-NIC werden nicht verändert. Allgemeine manuell erzeugte Windows-
Slots werden nicht still aktiviert, weil deren Lizenzvertrag nicht aus dem
Slottyp abgeleitet werden darf.

Die Aktivierung gehört damit zum Slotzustand selbst: Wird ein Pool-Slot später
verwendet, läuft dieselbe Child-VHDX weiter und der aktivierte Gastzustand bleibt
erhalten. Der Wiederverwendungspfad prüft den Lizenzstatus live und beendet den
Aktivierungsschritt ohne External-Switch oder zusätzliche NIC, wenn bereits
`EVALUATION_ACTIVE` oder `LICENSED` vorliegt. Nur ein tatsächlich noch nicht
aktivierter Slot benötigt kurzfristig einen verbundenen External-Switch.

Ist nach der Übernahme noch kein SQL-Plan vorhanden, bietet das System direkt an:

```text
SQL-Ausbau ist noch nicht geplant. Jetzt direkt mit Standardfragen erstellen?
```

## 4) SQL-Ausbau festlegen und direkt installieren

### Neuer 1-Klick-Pfad

- **[a] SQL-Ausbau festlegen und direkt ausführen**

Dieser Schritt führt `Select-LabSqlInstallationMedia`, CPU/I/O-Auswahl und
Persistenzlogik aus und fragt danach direkt, ob die vollständige SQL-Installation
in diesem Slot gestartet werden soll.

### Bereits geplanter SQL-Ausbau

- **[x] SQL vollständig installieren und konfigurieren**

Nutzt denselben Installationspfad wie `[a]`, wenn bereits ein vollständiger
Ausbauplan im Slot liegt.

Im Erfolgsfall werden Connection-String und SA-Passwort im Klartext ausgegeben.

## 5) SQL-Prepared-Image-Slot-Weg

Für bereits vorbereitete `SQL_PREPARED_SEALED`-Artefakte läuft weiterhin der
Resilienzpfad:

- Windows-OS-Übergang in SQL-Prepared-Template
- `r`: `SQL PrepareImage und Windows-Generalize` bzw. Weitersetzen bei
  `PREPARE_RUNNING`

Nach erfolgreichem Abschluss wartet der Slot auf Veröffentlichung als
`SQL_PREPARED_SEALED`.

## 6) Zustandssicht in der Slot-Übersicht

Die Übersicht zeigt jetzt pro Slot zusätzlich kompakt:

- Windows: `bereit` oder `OOBE/Übernahme ausständig`
- Windows-Testslot-Aktivierung: `EVALUATION_ACTIVE`, `LICENSED` oder `ACTIVATION_REQUIRED`
- SQL: geplant / installing / ready / prepared-template Fehlerzustände

Damit ist auf einen Blick erkennbar, welcher Slot direkt nutzbar ist und wo
manuell nachgeliefert werden muss.

## 7) Smoke-Test / Selbstprüfung (lokal)

Nach dem neuen Flow empfiehlt sich mindestens:

- PowerShell-Parser-Check der geänderten Skripte:

```powershell
 [System.Management.Automation.Language.Parser]::ParseFile('Public\Invoke-SqlServerLab.ps1',[ref]$null,[ref]$null)
```

- Dokumentations-Check:

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Damit werden Syntax- und Dokumentationskonsistenz-basierte Mindestfälle
abgedeckt, bevor reale VM-Läufe gestartet werden.

## Offene Punkte (Backlog) und Erledigt-Liste

### Erledigt

- OOBE- und SQL-Fertigstellung wurden in der Slotverwaltung zusammengeführt.
- Menü `[o]` startet automatisch VMConnect und fragt nach OOBE-Abschluss.
- SQL-Planung und direkte Ausführung stehen im selben Pfad (`a` + optionaler
  Direktstart, `x` übernimmt denselben Pfad).
- SQL-Prepared-Auswahl ist bei der Hyper-V-Neuerzeugung über `SQL_PREPARED` getrennt.
- Dokumentation ergänzt: aktueller Hyper-V-Workflow mit Zuständen und Entscheidungspunkten.

### Backlog

- Vollständiger End-to-End-Hot-Update ohne manuelle Interventionspunkte für neue
  Standard-ISOs.
- Einheitlicher Zustandstext bei allen Hyper-V-Abhängigkeiten in der UI.
- Remote-Hyper-V als produktiver Standardpfad.
- Weitere Laufzeit-Smoke-Cases für SQL-Installationspfade direkt im neuen Slot-Flow.
