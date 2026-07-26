# Repository-Abgrenzung und Branch-Strategie

**Status:** verbindlich  
**Geltungsbereich:** Repository-Änderungen, Branch-Arbeit, KI-gestützte Fortsetzung und zukünftige Aufteilung von Produkt- und Operationsschichten

## Ziel

Das Repository wird bewusst in zwei fachlich getrennte Linien unterteilt:

1. **Produktlinie / Framework** für Installation, Nutzung, Dokumentation und nachvollziehbare Lab-Umgebungen.
2. **Operations-/Validation-Linie** für GitHub-Actions, Runner, Tests, Release-Gates, Qualitätsnachweise und ähnliche Automatisierungsartefakte.

Diese Trennung gilt ab sofort als verbindlich. Sie ist kein Vorschlag, sondern eine Repository-Policy für alle zukünftigen Änderungen.

## Verbindliche Abgrenzung

### Kernprodukt: Hauptlinie
Die Hauptlinie enthält die nutzerorientierten Artefakte des Frameworks:

- installierbare Frameworkobjekte unter `Code/`
- Installer und Buildskripte für die Frameworkinstallation
- Beispiele für Analysefunktionen unter `Code/Examples/`
- Dokumentation für Installation, Nutzung, Referenz und Analyseverständnis unter `Documentation/`
- Lab-/Repro-Umgebungen für Docker, Podman und Hyper-V, sofern sie als Nutzer- oder Reproduktionspfad gedacht sind

Die Hauptlinie ist der sichtbare Produktzweig und soll schlank und nutzbar bleiben.

### Operations- und Validierung: eigene Linie
Die Operations- und Validierungslinie enthält die Automatisierungs- und Qualitätsartefakte:

- `/.github/workflows/`
- Runner- und Hostvorbereitungsskripte
- Validierungs-, Test- und Contract-Assets
- Release-Gates, Evidenzsammlung und Qualitätsnachweise
- Repository-Privacy-, Lifecycle- und Infrastruktur-Tests

Diese Artefakte gehören nicht zur Kernproduktlinie und dürfen nicht in der Hauptlinie als „normaler Produktinhalt“ behandelt werden.

## Branch-Regeln

### Empfohlene Branch-Namen

- `main`: Produkt-/Frameworkzweig
- `ci-ops` oder eine gleichwertige Operationslinie: CI/CD-, Test- und Validierungszweig

Falls der Repositoryinhaber andere Namen verwendet, bleibt die fachliche Bedeutung identisch: Der Hauptzweig ist der Produktzweig, die separate Linie ist die Operations-/Validierungs-Linie.

### Arbeitsregeln

1. Änderungen an Framework, Installation, Dokumentation und Beispielen erfolgen in der Produktlinie.
2. Änderungen an Workflows, Tests, Runner-Setup, Release-Gates und Evidence-Assets erfolgen in der Operationslinie.
3. Änderungen, die beide Linien betreffen, sind zu trennen: eine Produktänderung und eine Operations-/Validierungsänderung dürfen nicht unstrukturiert gemischt werden.
4. Ein automatisiertes Bearbeitungssystem darf keine CI-/Workflow- oder Test-Assets in die Produktlinie einbringen, sofern der Nutzer nicht ausdrücklich eine solche Mischform verlangt.
5. Die Hauptlinie darf nicht als „Sammelbecken“ für CI- und Produktartefakte dienen.

## Für KI-Systeme und zukünftige Automatisierung

Ein KI-System muss diese Abgrenzung wie folgt beachten:

- Es darf keine neuen GitHub-Workflows, Runner-Skripte oder Test-Assets in die Produktlinie einfügen, wenn der Auftrag nicht ausdrücklich die Operationslinie betrifft.
- Es muss neue Dokumentations- oder Beispielinhalte im Produktzweig platzieren, wenn sie für Nutzer und Installation relevant sind.
- Es darf keine CI-/Release-Logik als „normale Framework-Änderung“ behandeln.
- Wenn eine Änderung fachlich beide Bereiche betrifft, ist eine saubere Trennung in separate Änderungen oder separate Branches vorzunehmen.

## Konsequenz für zukünftige Änderungen

Die bestehende Repositoryhistorie darf nicht als Rechtfertigung für eine gemischte Struktur verwendet werden. Die Struktur ist ab sofort bewusst und verbindlich zu trennen.
