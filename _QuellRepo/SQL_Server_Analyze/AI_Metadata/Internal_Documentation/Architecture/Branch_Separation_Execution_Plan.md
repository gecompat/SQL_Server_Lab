# Ausführungsplan für die Branch-Aufteilung

**Status:** verbindlich für die lokale Umstellung  
**Zweck:** erste konkrete Ausführung der Produkt-/Operations-Trennung ohne Änderung der Frameworkfunktionalität

## Zielzustand

- `main` bleibt der Produktzweig für Framework, Installation, Dokumentation und Beispiele.
- `ci-ops` enthält die Operations-/Validierungs- und Automatisierungslinie.

## Vorgehen

1. Die bestehenden Richtlinien und die neue Abgrenzung werden zuerst in `main` verankert.
2. Ein separater Branch `ci-ops` wird lokal angelegt.
3. Zukünftige CI-/Workflow-/Test-Änderungen werden bevorzugt in `ci-ops` gepflegt.
4. Produktänderungen bleiben in `main`.
5. Bei Bedarf können später die Inhalte der Operationslinie in ein eigenes Remote-Repository ausgelagert werden.

## Abgrenzung der Inhalte

### In `main`

- Frameworkobjekte
- Installer
- Beispiele
- Produktdokumentation
- Lab-/Repro-Umgebungen für Nutzer

### In `ci-ops`

- GitHub-Actions-Workflows
- Tests und Contract-Validierungen
- Runner- und Hostvorbereitung
- Release-Gates und Qualitätsnachweise

## Wichtiger Grundsatz

Die Hauptlinie soll schlank und nutzbar bleiben. Die Operationslinie ist eine getrennte Warteschiene und keine normale Produktfunktion.
