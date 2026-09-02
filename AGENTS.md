# AGENTS.md — verbindlicher Arbeitsvertrag

Diese Datei ist der primäre Einstieg für KI-Agenten und automatisierte
Entwicklungswerkzeuge. Der Repositoryzustand muss ausreichen, um ohne frühere
Chat-Historie sicher weiterzuarbeiten.

<!-- AI_REPOSITORY_FOUNDATION:BEGIN v1 -->
## AI Repository Foundation baseline

At the start of every new run, let Codex rebuild the applicable `AGENTS.override.md`/`AGENTS.md` chain. Before project work, read `.ai/foundation/FOUNDATION_RULESET.md` and then only the Foundation and project rule files relevant to the current scope. Project-specific instructions in this repository remain the source of truth for project facts, domain rules, architecture, state, and selected overrides.

After additional rules have been fully read and analyzed once for a scope, later change waves may reuse that session analysis only through `.ai/foundation/RULE_CONTEXT_CACHE_POLICY.md`: run deterministic discovery/fingerprint checking first, use the exact validated analysis key on `CACHE_HIT`, reread changed rules plus transitive dependents on `PARTIAL_INVALIDATION`, and fully reread on `CACHE_MISS` or uncertainty. A cache never replaces native instruction discovery, repository sources, current instructions, or validation evidence.

Active project-specific governance must be transitively discoverable from this root `AGENTS.md`. If this repository keeps authoritative project rules elsewhere, preserve or add a concise project-owned discovery section outside this managed Foundation block that points to their canonical entrypoints or documents the scoped-`AGENTS.md` convention. Do not copy project rule text into this Foundation block. Active authority that cannot be discovered is an integration defect.

The current explicit task authorizes ordinary, reasonably expected and proportionate operations inside the project's authorization envelope. Do not create repeated confirmation gates for normal work. Escalate only for unresolved handling/authorization boundaries, unexpected material scope/effects, or destructive/irreversible effects lacking exact authority.

Foundation `REQUIRED` rules are a minimum protected floor; a project may intentionally be stricter. Foundation `DEFAULT` rules may be intentionally overridden by project-specific rules. Use `.ai/foundation/SEMANTIC_INTEGRATION_POLICY.md` to classify overlaps instead of replacing richer project governance.

Tool-specific adapters must lead back to this repository entry point and may not define parallel governance. When an existing adapter contains unique project rules, preserve/rehome those rules before thinning the adapter.

Foundation validation covers Foundation integration integrity only. Preserve and use the target repository's existing semantic validators, static contracts, tests, reviews, and manual validation when their contracts are affected. A green Foundation validator is not evidence that the entire project is validated.

Chat history, memory, prior scratchpads, and vendor-specific project prompts are not durable project truth.
<!-- AI_REPOSITORY_FOUNDATION:END -->

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
