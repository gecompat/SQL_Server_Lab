# Console UI Framework - Menü-, Cursor- und Refresh-Vertrag

| Merkmal | Wert |
|---|---|
| Status | `PLANNED_BINDING_UI_CONTRACT` |
| Stand | 2026-08-11 |
| Priorität | `P0 / M2` |
| Geltung | interaktive PowerShell-Konsole von `SQL_Server_Lab` |
| Ziel | konsistente cursorbasierte Menüs und lange editierbare Formulare ohne flackernden Vollbild-Neuaufbau |

## 1. Entscheidung

`SQL_Server_Lab` erhält eine wiederverwendbare interne Console-UI-Schicht.
Menüs und Erfassungsformulare dürfen ihre Navigation, Darstellung und
Validierung nicht mehr jeweils selbst mit Kombinationen aus `Write-Host`,
`Read-Host` und `Clear-Host` implementieren.

Die Console-UI ist eine Ansicht auf bestehende Workflow-, Planner- und
Runtime-Funktionen. Sie enthält keine eigene Provisionierungs-, Lifecycle-,
State-, Cleanup- oder SQL-Fachlogik.

Die cursorbasierte Oberfläche ist der bevorzugte interaktive Pfad. Eine
nummerierte beziehungsweise buchstabenbasierte `Read-Host`-Bedienung bleibt als
vollwertiger Fallback für nicht unterstützte Hosts und umgeleitete Ein- oder
Ausgabe erhalten.

## 2. Ausgangslage

Die Haupt- und Hyper-V-Menüs werden überwiegend vollständig ausgegeben und
anschließend über `Read-Host` ausgewählt. Lange Konfigurationen werden als
sequenzielle Prompt-Kette erfasst. Dadurch fehlen insbesondere:

- Navigation mit Pfeiltasten;
- ein sichtbarer Fokus;
- Zurückspringen zu bereits erfassten Feldern;
- ein stabiler Viewport für lange Listen und Formulare;
- eine gemeinsame Review-Seite vor der Mutation;
- einheitliche Inline-Validierung;
- ein sauberer Refresh ohne `Clear-Host` bei jedem Tastendruck.

`Update-SqlServerLabContainer` besitzt bereits einen lokalen
Pfeiltasten-Dialog. Dieser dient als Verhaltensreferenz, wird aber nicht als
zweite Console-UI-Implementierung fortgeführt. Insbesondere wird dessen
`Clear-Host` pro Tastendruck durch den gemeinsamen Renderer ersetzt.

## 3. Nichtziele

- keine zweite Businesslogik neben CLI, Manifest und Browser-UI;
- keine automatische Mutation während der Formularnavigation;
- keine Pflichtabhängigkeit von einer externen TUI-Bibliothek;
- keine Annahme, dass `System.Console` in jedem PowerShell-Host verfügbar ist;
- kein Verlust der bestehenden Direktaktionen und Tastenkürzel;
- kein periodischer Runtime-Poll bei jeder Cursorbewegung;
- keine Anzeige von Secrets im Klartext oder im wiederverwendbaren UI-State.

## 4. Console-Capability und Fallback

Vor dem Start einer cursorbasierten Ansicht wird einmalig geprüft:

- Ein- und Ausgabe sind nicht umgeleitet;
- ein interaktiver Host steht zur Verfügung;
- `System.Console` kann Tasten ohne Echo lesen;
- Fensterbreite, Fensterhöhe und Cursorposition sind lesbar;
- Cursorposition und Cursorsichtbarkeit können sicher gesetzt werden.

Schlägt eine dieser Prüfungen fehl, wird ohne Warnungsflut auf den
`Read-Host`-Fallback gewechselt. Direktaktionen, nicht interaktive Aufrufe,
Pipelines und Tests dürfen nie von einer echten Terminal-Konsole abhängen.

Der aktive Eingabemodus wird pro Ansicht festgelegt und nicht innerhalb einer
laufenden Tastensequenz still gewechselt. Ein Konsolenfehler beendet die
cursorbasierte Ansicht kontrolliert und bietet anschließend den Fallback an.

## 5. Zustandsmodell

Jede Ansicht besitzt einen lokalen, von der Runtime getrennten UI-State mit
mindestens folgenden Informationen:

| Feld | Bedeutung |
|---|---|
| `ScreenId` | stabile Identität der Ansicht |
| `Items` | darzustellende Menüeinträge oder Formularfelder |
| `SelectedId` | stabile Identität des fokussierten Elements |
| `SelectedIndex` | aktueller Index nach Filterung und Sortierung |
| `TopIndex` | erstes sichtbares Element des Viewports |
| `ViewportHeight` | verfügbare Zeilen zwischen Header und Footer |
| `Values` | lokal erfasste, noch nicht angewandte Werte |
| `Validation` | feldbezogene Fehler und Warnungen |
| `Message` | Statusmeldung für den stabilen Footer |
| `Snapshot` | explizit geladener read-only Runtime-Snapshot |
| `Dirty` | noch nicht bestätigte Formularänderungen |

Auswahl und Fokus werden über `SelectedId` erhalten. Nach Sortierung,
Filterung oder Runtime-Refresh darf nicht versehentlich ein anderes Objekt nur
wegen desselben Listenindex ausgewählt werden.

## 6. Tastaturvertrag

| Taste | Verhalten |
|---|---|
| `UpArrow` / `DownArrow` | vorheriges oder nächstes auswählbares Element |
| `PageUp` / `PageDown` | um eine Viewport-Seite navigieren |
| `Home` / `End` | erstes oder letztes auswählbares Element |
| `Enter` | Aktion wählen oder fokussiertes Feld bearbeiten |
| `Spacebar` | Mehrfachauswahl umschalten |
| `LeftArrow` / `RightArrow` | Wert einer begrenzten Option ändern |
| `Tab` / `Shift+Tab` | nächstes oder vorheriges Formularfeld |
| `Escape` | aktuelle Ebene verlassen oder Änderung verwerfen |
| `F5` | Runtime-Snapshot ausdrücklich aktualisieren |
| `F10` | Formular validieren und zur Bestätigung wechseln |
| Ziffer/Buchstabe | sichtbaren vorhandenen Shortcut ausführen |

Destruktive Aktionen benötigen weiterhin eine gesonderte Bestätigung. Ein
Shortcut darf diese Bestätigung nicht umgehen.

## 7. Lange Erfassungsformulare

Lange Prompt-Ketten werden als editierbare Feldübersicht modelliert. Alle
wesentlichen Werte sind vor der Ausführung gemeinsam sichtbar. `Enter` öffnet
einen Editor für das fokussierte Feld; anschließend kehrt der Fokus an dieselbe
Position zurück.

Ein Formular besitzt mindestens diese Phasen:

1. Snapshot und Defaults laden;
2. Werte ohne Runtime-Mutation bearbeiten;
3. feldbezogen validieren;
4. Warnungen und blockierende Fehler anzeigen;
5. vollständige Zusammenfassung beziehungsweise Action Preview anzeigen;
6. ausdrücklich bestätigen oder zurück zur Bearbeitung wechseln;
7. erst danach den bestehenden Workflow aufrufen.

Sensitive Werte werden nur über geeignete Secure-String-Eingaben erfasst. Im
UI-State und in der Review-Ansicht wird ausschließlich ein Maskierungsstatus,
nicht der Klartextwert gespeichert oder dargestellt.

## 8. Viewport und Layout

Header, Inhalts-Viewport und Footer werden getrennt gerendert. Lange Listen
scrollen nur innerhalb des Viewports. Das Terminal-Scrollback ist kein Ersatz
für Listennavigation.

Für jede Darstellung gelten folgende Regeln:

- der Fokus ist durch `>` oder eine andere Textmarkierung sichtbar und nicht
  ausschließlich durch Farbe;
- Zeilen werden auf die nutzbare Terminalbreite begrenzt;
- umgebrochene Detailtexte werden vor der Viewport-Berechnung in Renderzeilen
  aufgelöst;
- der Footer bleibt für Tastenhilfe, Validierung und Attention Items sichtbar;
- bei zu kleiner Fensterhöhe wird Inhalt reduziert, nicht Header und
  Navigation verdrängt;
- Terminal-Resize führt zu neuer Layoutberechnung und einem kontrollierten
  Full Refresh;
- `SelectedId` und Formularwerte bleiben bei Resize erhalten.

## 9. Refresh-Vertrag

Runtime-Refresh und Repaint sind zwei getrennte Operationen.

### 9.1 Repaint

Eine normale Cursorbewegung verändert nur den lokalen UI-State. Sie führt
keinen Provider-Aufruf, keine State-Synchronisation, keinen Hash-Lauf und keine
sonstige teure Ermittlung aus.

Der Renderer:

1. erzeugt das neue Bild vollständig als Zeilen- und Stilmodell im Speicher;
2. setzt den Cursor an den gespeicherten Render-Ursprung;
3. überschreibt den kontrollierten Renderbereich;
4. füllt kürzere neue Zeilen bis zur vorherigen sichtbaren Länge mit
   Leerzeichen auf;
5. löscht übrig gebliebene alte Renderzeilen kontrolliert;
6. positioniert den Cursor am definierten Eingabe- oder Footerpunkt.

`Clear-Host` ist innerhalb der Key-Loop verboten. Ein einmaliges Leeren beim
Betreten einer Vollbildansicht sowie bei nicht anders beherrschbarem
Terminal-Resize ist zulässig. Auch dabei muss der Render-Ursprung anschließend
neu bestimmt werden.

### 9.2 Runtime-Refresh

Runtime-Daten werden nur geladen:

- beim Betreten der Ansicht;
- nach einer ausgeführten Aktion;
- durch ausdrückliches `F5`;
- durch einen später bewusst implementierten, begrenzten Refresh-Timer.

Ein Refresh erstellt zuerst einen vollständigen neuen Snapshot, ordnet danach
`SelectedId` erneut zu und löst anschließend genau einen Full Refresh aus.
Provider-Ausgaben dürfen niemals zwischen Zeilen eines aktiven Frames
geschrieben werden.

Länger laufende Provisionierungs- und Diagnoseaktionen verlassen den
interaktiven Frame, zeigen ihren normalen Log-/Progress-Pfad und öffnen die
Ansicht danach mit einem neuen Snapshot erneut.

## 10. Konsolenzustand und Fehlerbehandlung

Vor dem ersten Rendern werden mindestens Cursor-Sichtbarkeit, Farben und
Render-Ursprung gesichert. Die UI-Key-Loop läuft in `try/finally`.

Der `finally`-Block stellt unabhängig von Erfolg, Fehler, `Escape` oder
Pipeline-Abbruch wieder her:

- sichtbaren Cursor;
- ursprüngliche Vorder- und Hintergrundfarbe;
- gültige Cursorposition innerhalb des aktuellen Puffers;
- einen abschließenden Zeilenumbruch, falls die Ansicht die Konsole verlässt.

Ein Fehler darf die Konsole niemals mit unsichtbarem Cursor, falschen Farben
oder einer Eingabe mitten im alten Frame zurücklassen.

## 11. Attention Items

Der stabile Footer kann read-only Attention Items aus dem gemeinsamen
Framework-State anzeigen, beispielsweise:

- neues CU bekannt;
- Installationsmedium fehlt oder ist unverifiziert;
- Slot-Pool leer oder unter Mindestbestand;
- Evaluation läuft ab;
- Provider ist nicht erreichbar;
- Recovery oder Cleanup ist erforderlich.

Attention Items werden beim Snapshot-Refresh geladen. Sie dürfen keine
automatische Medienbeschaffung, Slot-Erzeugung oder sonstige Mutation auslösen.

## 12. Umsetzungspakete

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `CUI-001` | Console-Capability-Erkennung und `Read-Host`-Fallback | sichere Host-Kompatibilität |
| `CUI-002` | gemeinsames Screen-, Item-, Field- und UI-State-Modell | keine lokalen Menü-State-Maschinen mehr |
| `CUI-003` | Frame-Renderer mit Viewport, Resize und sauberem Refresh | kein `Clear-Host` pro Tastendruck |
| `CUI-004` | gemeinsame Key-Loop für Menü, Auswahl und Mehrfachauswahl | konsistente Navigation |
| `CUI-005` | editierbares Formular mit Feldvalidierung und Review | lange Erfassungen bleiben korrigierbar |
| `CUI-006` | Hauptmenü und Auswahl aktiver Umgebungen migrieren | erster produktiver Vertical Slice |
| `CUI-007` | SQL-Zielkonfiguration migrieren | komplexer Formularnachweis |
| `CUI-008` | Sample-Auswahl sowie Hyper-V-Image-, Slot- und Verwaltungsmenüs migrieren | breite Menüabdeckung |
| `CUI-009` | Container-Änderungsdialog auf gemeinsamen Renderer umstellen | bestehende Sonderimplementierung entfernt |
| `CUI-010` | Attention-Footer an gemeinsamen read-only Status anbinden | offene Benutzeraktionen sichtbar |
| `CUI-011` | Zustands-, Render-, Resize-, Fallback- und Recovery-Tests | belastbare Console-UX |

Die Migration erfolgt vertikal. Ein migriertes Menü verwendet vollständig die
gemeinsame Schicht; neue parallele Cursorimplementierungen sind nicht zulässig.

## 13. Abnahmekriterien

Das Console UI Framework gilt als abgenommen, wenn:

1. Pfeiltastenbewegungen keine Runtime- oder Provider-Aufrufe auslösen;
2. lange Listen bei kleiner Terminalhöhe vollständig per Viewport erreichbar
   bleiben;
3. nach jeder Navigation weder alte Zeichen noch alte Zeilen sichtbar bleiben;
4. Fenstervergrößerung und -verkleinerung Fokus und Formularwerte erhalten;
5. Fehler und Abbruch Cursor, Farben und Eingabeposition wiederherstellen;
6. die Auswahl nach `F5` über stabile IDs erhalten bleibt oder kontrolliert auf
   das nächste gültige Element wechselt;
7. alle Funktionen ohne interaktive Console über `Read-Host` beziehungsweise
   Direktaktionen weiter nutzbar bleiben;
8. Farbe niemals das einzige Signal für Fokus, Fehler oder Gefahr ist;
9. Secrets weder im Frame-State noch in Test-Snapshots erscheinen;
10. ein langes SQL-Konfigurationsformular vollständig bearbeitet, validiert,
    reviewed und abgebrochen werden kann, ohne vorherige Runtime-Mutation;
11. Hauptmenü, Environment-Auswahl und mindestens ein langes Formular denselben
    Renderer verwenden;
12. keine Ansicht innerhalb ihrer Key-Loop `Clear-Host` aufruft.

## 14. Einordnung in die Lieferreihenfolge

`CUI-001` bis `CUI-006` werden vor der umfassenden umgebungszentrierten
Menüumstellung aus `UX-201` bis `UX-204` umgesetzt. Dadurch entstehen Quick-,
Scenario- und Custom-Ansichten nicht erneut als lange sequenzielle
`Read-Host`-Ketten.

Das Framework ist keine Voraussetzung für den Reconcile-Core, nutzt aber nur
dessen read-only Planner-, Validation- und Attention-Ergebnisse. Eine
Console-UI darf fehlende Runtime-Verträge nicht simulieren.
