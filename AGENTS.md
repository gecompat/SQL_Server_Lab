# AGENTS.md — verbindlicher Arbeitsvertrag

Diese Datei ist der primäre Einstieg für KI-Agenten und automatisierte
Entwicklungswerkzeuge. Der Repositoryzustand muss ausreichen, um ohne frühere
Chat-Historie sicher weiterzuarbeiten.

<!-- AI_REPOSITORY_FOUNDATION:BEGIN v1 -->
## AI Repository Foundation baseline

Apply the native scoped `AGENTS.override.md`/`AGENTS.md` chain on every new session. Read `.ai/foundation/FOUNDATION_RULESET.md`, affected project sources, and only relevant additional policies. Project facts, domain contracts, selected overrides, and current state remain project-owned. Discovery links are not a demand to load every document.

Use `.ai/foundation/PROCESSING_EFFICIENCY_POLICY.md` for routine work, verified session-local rule reuse, proportionate review/delegation, shared wave budgets, and bounded waiting. Reuse requires current authority/content/scope/dependency checks and actually available analysis; no optional planner or persistent record is necessary. Persistent cache users additionally follow `.ai/foundation/RULE_CONTEXT_CACHE_POLICY.md`. Unknown discovery or lost analysis never becomes a fabricated hit.

A concrete task authorizes ordinary proportionate work inside its envelope; gate only real unresolved or exceeded boundaries. Preserve REQUIRED safety/privacy/integrity/evidence floors and compatible stronger project rules. Use `.ai/foundation/SEMANTIC_INTEGRATION_POLICY.md` for integration conflicts and efficiency recommendations. Keep active project governance transitively discoverable from this root outside the managed block; preserve/rehome unique adapter rules before thinning adapters.

Foundation validation establishes FOUNDATION_INTEGRITY only. Run affected project semantic/runtime checks and required independent reviews. Use optional routing/execution contracts only for relevant selected operations. Optional capabilities grant no execution authority. Requested models, chat history, fingerprints, and cached analysis are not evidence or durable project truth.

Installation/upgrade and material workflow-rule changes require the processing-overhead assessment: actual test triggers, duplicate checks, logs, review chains, and model calls. Preserve necessary gates; justify bounded stronger exceptions or expose pending decisions. Copying rules alone does not establish efficient integration.
<!-- AI_REPOSITORY_FOUNDATION:END -->

## Vor jeder Änderung erschließen

1. `.ai/PROJECT_CONTEXT.md`: aktueller Status und Dokumentationszuständigkeiten
2. `.ai/WORKING_RULES.md`
3. `.ai/repo_map.yaml`: betroffener Vertrag, Aufrufer und gemeinsame Abhängigkeiten
4. `Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`
5. `.ai/MODEL_ROUTING_POLICY.md`, wenn System-/Modellwahl betroffen ist
6. `Documentation/Quality/KNOWN_LIMITATIONS.md`: betroffene Grenzen
7. `Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md`: betroffene Prüfwege
8. die für den betroffenen Bereich in `.ai/repo_map.yaml` genannten Quellen

Planungsdokumente sind kein Nachweis für implementiertes oder validiertes
Verhalten. Bei Abweichungen zwischen Code, Dokumentation und Tests muss der
tatsächliche Stand ermittelt und die Abweichung im Änderungsscope behoben oder
ausdrücklich dokumentiert werden.

## Pflichtkontext nach Aufgabe finden

Die Quellen oben bleiben verbindlich; gelesen werden ihre betroffenen Abschnitte
und transitive Abhängigkeiten, keine unverbundenen historischen Nachweise.
Aktuelle Discovery/Fingerprints und wirklich verfügbare Sessionanalyse sind
Voraussetzungen für Wiederverwendung. Die folgende Orientierung führt von
den gemeinsamen Regeln zu den Quellen des konkreten Änderungsscope:

- `.ai/WORKING_RULES.md` bündelt Sicherheit, Privacy, Ownership, State,
  Cleanup und Recovery; `SECURITY.md` beschreibt die öffentliche Security Policy.
- `.ai/repo_map.yaml` ordnet Fachvertrag, Implementierung, Aufrufer, Fixtures
  und getrennte Provider-Nachweise ein. Die betroffenen gekoppelten Quellen
  werden gemeinsam gelesen und geprüft.
- `.ai/PROJECT_CONTEXT.md` erklärt die Dokumentationszuständigkeiten:
  Fachverträge für Verhalten, Validierungsstrategie für ausgeführte Nachweise
  und Known Limitations für Grenzen. Einstiegstexte verweisen darauf.

## Kontext- und kosteneffiziente Arbeit

- Die tatsächlich verfügbaren KI-Systeme, Modelle, lokalen Werkzeuge und
  Steuerungsmöglichkeiten werden vor umfangreichen Arbeiten nach Aufgabenklasse,
  Risiko, benötigter Qualität und Gesamtkosten bewertet.
- Verwendet wird die kostengünstigste verfügbare Kombination, die die notwendige
  Qualität, Sicherheit, Zuverlässigkeit und Nachprüfbarkeit erreicht.
- Separate Kontingente oder lokale Systeme werden für geeignete Routinearbeit
  bevorzugt, wenn ihre Verfügbarkeit und Eignung tatsächlich bestätigt sind.
- Leistungsfähigere Systeme sind kritischen Architektur-, Security-, Privacy-,
  Nebenläufigkeits-, Autorisierungs- und Datenverlustfragen vorbehalten. Nach
  deren Klärung wird für begrenzte mechanische Arbeit wieder zurückgestuft.
- Vollständige Logs, große Diffs, wiederholte Fehler und lange grüne
  Testausgaben werden lokal deterministisch ausgewertet. In den Modellkontext
  gelangen nur deduplizierte Findings und die kleinsten entscheidungsrelevanten
  Ausschnitte.
- Delegation und Parallelität sind nur für konkrete, voneinander unabhängige
  Teilaufgaben sinnvoll. Eine atomare Implementierung hat genau einen aktiven
  Implementierungsagenten.

Die verbindlichen anbieterneutralen Einzelheiten stehen in
`.ai/MODEL_ROUTING_POLICY.md` und
`Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`.

Automatische Chatwechsel an geeigneten, gesicherten Arbeitsgrenzen sind nach
der Projektentscheidung in `Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`
erlaubt. Maßgeblich sind die dortigen Client-, Übergabe- und Rollenbedingungen;
ein Wechsel erzeugt keine zusätzliche Ausführungsautorität.

## Host-Werkzeuge in neuen Prozessen

- Vor der Aussage, Docker, Podman oder Python sei nicht vorhanden, muss im
  aktuellen PowerShell-Prozess
  `Tools/Initialize-SqlServerLabHostTools.ps1` für das betroffene Werkzeug
  ausgeführt und dessen strukturiertes Ergebnis geprüft werden.
- Nach erfolgreicher Auflösung ist der zurückgegebene absolute `Invocation`-
  Pfad zu verwenden. Eine fehlende Auflösung, eine nicht erreichbare Runtime
  und fehlende Ausführungsberechtigung sind getrennte Fehlerklassen.
- Jeder neue No-Profile-, Agent- oder Testprozess initialisiert erneut. Der
  Benutzer- oder Maschinen-`PATH` wird dafür niemals persistierend verändert.

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
