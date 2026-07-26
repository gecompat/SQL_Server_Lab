# Repository instructions for AI systems

## Verbindlicher Dokumentationsstil

Vor dem Erstellen oder Überarbeiten von Dokumentationsfreitexten ist die Richtlinie [Verbindlicher Schreibstil für Dokumentation](Documentation/Quality/Documentation_Writing_Style.md) vollständig zu lesen und einzuhalten.

Die Richtlinie gilt für alle berührten README-Dateien, Architektur- und Analyseunterlagen, Betriebs- und Referenzdokumente, Release- und Qualitätsdokumente sowie für dokumentierende Freitexte in SQL-Dateien. Technische Bezeichner, Code, festgelegte Statuswerte und öffentliche Verträge bleiben unverändert, sofern die Aufgabe keine fachliche Änderung verlangt.

Eine technische Änderung berechtigt nicht zu einer unverbundenen redaktionellen Gesamtüberarbeitung. Stilkorrekturen bleiben auf den sachlich betroffenen Dokumentationsumfang begrenzt.

Ordnerspezifische Ausschlussanweisungen für persönliche Notizen oder nicht maßgebliche Inhalte bleiben unabhängig von dieser Schreibstilrichtlinie verbindlich.

## Geschützter Lizenzblock der Root-README

Der zweisprachige Lizenzblock am Anfang der Root-Datei [`README.md`](README.md) ist vor jeder Bearbeitung dieser Datei vollständig zu lesen. Maßgeblich ist stets der zu Beginn der Aufgabe im Zielbranch vorhandene Stand; dadurch werden zwischenzeitliche Anpassungen des Repositoryinhabers nicht zurückgesetzt.

Ein automatisiertes Bearbeitungssystem muss den gesamten Block einschließlich des englischen Abschnitts `READ BEFORE USE`, des deutschen Abschnitts `Lizenzhinweis`, der Überschriften, Listen, Links, Trennlinien, Hervorhebungen, Zeichensetzung, Leerzeilen und sonstigen Formatierung unverändert erhalten. Allgemeine Aufträge zum Aktualisieren, Korrigieren, Formatieren oder stilistischen Überarbeiten der Root-README oder der Repositorydokumentation erteilen keine Berechtigung, diesen Block zu verändern.

Eine Änderung ist nur zulässig, wenn der Benutzer ausdrücklich und unmittelbar eine Änderung des Lizenzblocks verlangt. Bei jeder anderen Änderung der Root-README ist vor dem Commit zu prüfen, dass der Lizenzblock gegenüber dem zu Beginn der Aufgabe gelesenen Stand inhaltlich und formal unverändert geblieben ist.

## Verbindliche Abgrenzung zwischen Produkt- und CI/Operations-Linie

Das Repository wird künftig bewusst in zwei fachlich getrennte Linien geführt:

1. **Produktlinie / Framework** für Installation, Nutzung, Dokumentation, Beispiele und Lab-/Repro-Umgebungen.
2. **Operations-/Validation-Linie** für GitHub-Actions, Runner, Tests, Release-Gates, Qualitätsnachweise und verwandte Automatisierung.

Diese Trennung gilt ab sofort als verbindliche Richtlinie für alle zukünftigen Änderungen. Ein automatisiertes Bearbeitungssystem darf keine CI-/Workflow-/Test-Assets in die Produktlinie einbringen, sofern nicht ausdrücklich eine Operations- oder Validierungsänderung beauftragt ist. Die Hauptlinie ist der Produktzweig und soll schlank und nutzbar bleiben.
