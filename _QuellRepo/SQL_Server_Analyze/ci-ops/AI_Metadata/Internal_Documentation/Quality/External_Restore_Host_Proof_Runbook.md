# Externer Restore- und Hostnachweis

Stand: 2026-07-18  
Backlog: SC-025  
Status: `RUNBOOK_READY_EXTERNAL_EXECUTION_REQUIRED`

## Ziel

Dieser Runbook beschreibt den Nachweis, den ein read-only T-SQL-Diagnoseframework nicht selbst erbringen kann: Backup tatsächlich auf ein autorisiertes isoliertes Ziel restoren, Integrität dort prüfen und Betriebssystem-, Storage- und Netzwerkbeobachtungen getrennt belegen.

Das Repository enthält weder Backup, Schlüssel, Pfade, Endpunkte, Hostnamen, Konten, interne Strukturen noch Resultsets. Vor dem Eintragen irgendeines Laufzeitergebnisses in eine Datei oder Git-Operation muss der Benutzer den bereits bereinigten Inhalt ausdrücklich bestätigen.

## Voraussetzungen

1. schriftlich autorisiertes, isoliertes und löschbares Ziel;
2. freigegebene Backupkopie und gesondert geschütztes Schlüsselmaterial;
3. minimale administrative Rechte und benannter Ausführungsverantwortlicher außerhalb des Repositorys;
4. definiertes Zeit-, Speicher- und Abbruchbudget;
5. definierter sicherer Ort für Rohlogs, der nicht dieses Repository ist;
6. bestätigter Lösch- und Nachweisprozess.

## Ablauf

1. Prüfen Sie Zielisolation, freie Kapazität sowie Version und Edition.
2. Stellen Sie Backup und erforderliches Schlüsselmaterial über den autorisierten Kanal bereit.
3. Führen Sie den Restore unter einem ausschließlich für diesen Lauf erzeugten synthetischen Zielnamen durch.
4. Behandeln Sie Restorefehler im geschützten Betriebslog und übernehmen Sie keine Rohmeldung in Git oder Downloads.
5. Führen Sie `DBCC CHECKDB` auf dem isolierten Restoreziel nach dem freigegebenen Betriebsverfahren aus.
6. Führen Sie anwendungsspezifische Start- und Lesetests nur mit synthetischen Eingaben und ohne externe Seiteneffekte aus.
7. Erfassen Sie Host-, Storage- und Netzwerkmetriken mit den jeweiligen Plattformwerkzeugen separat und stellen Sie SQL-Metadaten nicht als Ersatz dar.
8. Entfernen Sie Restoreziel, temporäre Credentials, bereitgestelltes Schlüsselmaterial und Arbeitskopien nach dem freigegebenen Verfahren.
9. Füllen Sie nur die generische Evidenzzeile aus `External_Evidence_Gates.csv` aus und führen Sie vor einem Datei- oder Git-Schreibzugriff die Datenschutzrückfrage durch.

## PASS-Kriterien

- Restore beendet sich erfolgreich.
- CHECKDB beendet sich entsprechend dem vorab definierten Integritätskriterium.
- synthetische Anwendungskontrolle erfüllt ihren festgelegten Erwartungswert.
- Host-, Storage- und Netzbeobachtung wurden durch zuständige externe Werkzeuge erhoben.
- Cleanup ist bestätigt.
- Der veröffentlichbare Nachweis enthält ausschließlich generische Statuscodes, UTC-Zeitpunkte, Commit-ID und synthetische Target-ID.

## Abbruchkriterien

Unklare Autorisierung, produktives Ziel, fehlendes Größenbudget, unklarer Schlüsselweg, mögliche externe Seiteneffekte, gefundene sensible Daten oder nicht bestätigter bereinigter Dateinhalt. Bei jedem dieser Punkte wird nicht fortgefahren.
