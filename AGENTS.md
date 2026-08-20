# AGENTS.md — verbindlicher Arbeitsvertrag

Diese Datei ist der primäre Einstieg für KI-Agenten und automatisierte
Entwicklungswerkzeuge. Der Repositoryzustand muss ausreichen, um ohne frühere
Chat-Historie sicher weiterzuarbeiten.

## Vor jeder Änderung lesen

1. `.ai/PROJECT_CONTEXT.md`
2. `.ai/WORKING_RULES.md`
3. `.ai/repo_map.yaml`
4. `Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`
5. `.ai/MODEL_ROUTING_POLICY.md`
6. `Documentation/Quality/KNOWN_LIMITATIONS.md`
7. `Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md`
8. die für den betroffenen Bereich in `.ai/repo_map.yaml` genannten Quellen

Planungsdokumente sind kein Nachweis für implementiertes oder validiertes
Verhalten. Bei Abweichungen zwischen Code, Dokumentation und Tests muss der
tatsächliche Stand ermittelt und die Abweichung im Änderungsscope behoben oder
ausdrücklich dokumentiert werden.

## Kontext- und kosteneffiziente Arbeit

- Die verfügbaren KI-Modelle werden vor jeder Aufgabe nach Aufgabenklasse,
  Risiko, benötigter Qualität, Kontextkosten und Ausführungskosten bewertet.
- Verwendet wird das kleinste beziehungsweise kostengünstigste verfügbare
  Modell, das die notwendige Qualität zuverlässig liefert.
- `gpt-5.3-codex-spark` wird als verfügbare Sonderoption mit eigenem
  Tokenkontingent in die Auswahl einbezogen, auch wenn es in einer angezeigten
  Modellliste fehlt. Für vollständig begrenzte atomare Coding-Pakete ist dieses
  Kontingent bevorzugt zu prüfen.
- Stärkere Modelle sind kritischen Architektur-, Security-, Privacy-,
  Nebenläufigkeits-, Autorisierungs- und Datenverlustfragen vorbehalten. Nach
  deren Klärung wird für begrenzte mechanische Arbeit wieder zurückgestuft.
- Vollständige Logs, große Diffs, wiederholte Fehler und lange grüne
  Testausgaben werden lokal deterministisch ausgewertet. In den Modellkontext
  gelangen nur deduplizierte Findings und die kleinsten entscheidungsrelevanten
  Ausschnitte.
- Delegation und Parallelität sind nur für konkrete, voneinander unabhängige
  Teilaufgaben sinnvoll. Eine atomare Implementierung hat genau einen aktiven
  Implementierungsagenten.

Die verbindlichen Einzelheiten stehen in
`.ai/MODEL_ROUTING_POLICY.md` und
`Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`.

## Tests und Nachweise

Tests werden lokal in steigender Breite ausgeführt:

1. kleinste Reproduktion oder Characterization;
2. fokussierte Prüfung der geänderten Einheit;
3. betroffene statische Suites über `Invoke-ImpactedChecks.ps1`;
4. nur die durch den Änderungsscope betroffenen Provider-/Runtime-Smokes;
5. der für den stabilen Stand erforderliche Abschluss-Gate genau einmal.

Ein unveränderter grüner Test und eine identische Fehlersignatur werden ohne
neue Evidence nicht wiederholt. Kostenersparnis rechtfertigt niemals das
Auslassen eines notwendigen Sicherheits-, Vertrags-, Migrations- oder
Runtime-Nachweises. Nur tatsächlich ausgeführte Prüfungen dürfen als bestanden
bezeichnet werden.

## Projektgrenzen

- SQL Server bleibt Mittelpunkt jeder Produktfunktion.
- Docker, Podman und Hyper-V sind getrennte Provider-Nachweise.
- Vor jeder Mutation müssen State, Scope, Cleanup und Recovery geklärt sein.
- Keine realen Secrets, Kunden-, Host-, Runtime-, Backup- oder Diagnosedaten
  versionieren.
- Gekoppelte Verträge aus `.ai/repo_map.yaml` gemeinsam prüfen.
- Kleine, kohärente Änderungen ohne unabhängige Refactorings bevorzugen.
- Commit- und Git-Regeln aus `.ai/WORKING_RULES.md` und `CONTRIBUTING.md`
  einhalten.
