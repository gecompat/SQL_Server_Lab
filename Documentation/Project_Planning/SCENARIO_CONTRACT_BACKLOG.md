# Interner Scenario-Contract-Slice

| Merkmal | Stand |
|---|---|
| Status | `IMPLEMENTED_INTERNAL_SLICE` |
| Arbeitspaket | `SCN-801` |
| Vertrag | `SqlServerLab.InternalScenarioContract/0.1` |
| Ausführung | `NOT_IMPLEMENTED` |

Der Slice liefert ausschließlich einen versionierten, providerneutralen internen Datenvertrag für `Scenario`, `Step`, `Evidence` und `Outcome`. `Schemas/scenario-contract.schema.json` verbietet Providerbindung und Ausführungsfelder. Das Beispiel verwendet nur synthetische Identitäten und Evidence-Metadaten. `Tests/Static/Invoke-ScenarioContractChecks.ps1` prüft Schema, Referenzintegrität sowie diese Grenzen ohne SQL-Server- oder Provideraktion.

Der Vertrag definiert keine Reihenfolge, Timeouts, Abbruchsignale, Mutation, Journale, Persistenz oder einen Executor. Diese Themen bleiben vollständig bei `SCN-802` und den nachfolgenden Fault-/Recovery-Arbeitspaketen.

## Offene Entscheidungen

Folgende öffentliche oder dauerhafte Entscheidungen sind weiterhin `DECISION_REQUIRED` und werden durch diesen internen Slice nicht entschieden:

- Registration Authority und öffentliches Namens-/Versionsmodell für Scenario-Identitäten;
- Kompatibilitäts- und Migrationsregeln einer späteren öffentlichen Contract-Version;
- zulässige persistierte und öffentliche Evidence-/Outcome-Projektionen;
- Bindung von fachlichen Consumer-Inhalten, Provider-Capabilities und Runtime-Evidence an den späteren Executor.

Der vorhandene `SqlServerLab.AiScenario/1.0`-Vertrag und seine Runtime bleiben eigenständig und unverändert. Dieser Slice erklärt weder SCN-801 noch Gate M8 als abgeschlossen oder runtime-validiert.
