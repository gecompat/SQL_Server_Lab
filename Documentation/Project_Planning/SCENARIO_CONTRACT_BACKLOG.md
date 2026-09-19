# Interner Scenario-Contract-Slice

| Merkmal | Stand |
|---|---|
| Status | `IMPLEMENTED_INTERNAL_SLICE` |
| Arbeitspaket | `SCN-801` |
| Vertrag | `SqlServerLab.InternalScenarioContract/0.1` |
| Metadatenvertrag | weiterhin `ExecutionImplemented=false` |
| Separater Executor | `SCN-802`: interner synthetischer Teilscope implementiert |

Der Slice liefert ausschließlich einen versionierten, providerneutralen internen Datenvertrag für `Scenario`, `Step`, `Evidence` und `Outcome`. `Schemas/scenario-contract.schema.json` verbietet Providerbindung und Ausführungsfelder. Das Beispiel verwendet nur synthetische Identitäten und Evidence-Metadaten. `Tests/Static/Invoke-ScenarioContractChecks.ps1` prüft Schema, Referenzintegrität sowie diese Grenzen ohne SQL-Server- oder Provideraktion.

Der SCN-801-Vertrag definiert weiterhin keine Reihenfolge, Timeouts,
Abbruchsignale, Mutation, Journale oder Persistenz. Der folgende separate
SCN-802-Teilscope verändert diesen Metadatenvertrag nicht.

## SCN-802: interner synthetischer Executor

`Private/ScenarioExecutor.ps1` führt ausschließlich fest eingebaute synthetische
Handler aus. Der separate `SqlServerLab.InternalSyntheticScenarioPlan/0.1`
bindet genau fünf Phasen an vorhandene Step-IDs: `Arrange`, `Act`, `Observe`,
`Assert`, `Cleanup`. Die Reihenfolge ist verpflichtend. `Synthetic` erzeugt
einen journalinternen Wert, setzt ihn auf eins, beobachtet und prüft ihn und
entfernt ihn wieder. `Fail` und der ausschließlich für Cleanup erlaubte
`FailOnce` modellieren Fehler. Freie Commands, Scriptblocks, Provider, SQL,
Netzwerkzugriffe und eine öffentliche API existieren in diesem Slice nicht.
Die referenzierten Evidence-Einträge müssen `SYNTHETIC` sein. Die Ergebnisse
belegen den Executorablauf und keine SQL-Capability oder fachliche Outcome-
Erfüllung aus dem SCN-801-Metadatenvertrag.

Vor Arrange wird ein Journal mit Cleanupbedarf atomar veröffentlicht. Ein
bereits vorhandenes, vom Aufrufer ausschließlich für diesen Zweck verwaltetes
lokales Verzeichnis nimmt die operationseigenen Journal-/Lockdateien auf;
Reparse-Points in dessen Pfad oder den Zieldateien werden abgewiesen. Ein
exklusiver Dateihandle serialisiert dieselbe Operation. Owner-ID, Operation-ID
und der Hash der vollständigen Contract-/Plan-Serialisierung sind gebunden.
Zusätzlich authentifiziert HMAC-SHA-256 jeden Journalinhalt mit einem vom
Aufrufer erzeugten 32-Byte-Schlüssel. Der Executor persistiert den Schlüssel
nicht; derselbe Schlüssel muss bei Resume erneut aus dem lokalen geschützten
Aufruferkontext vorliegen. Verlorene Schlüssel, geänderte Pläne, beschädigte
Journale und falsche Ownership werden fail-closed abgewiesen. Die atomare
Publikation verwendet eine eigene temporäre Datei im selben Verzeichnis mit
Flush und Rename. Lockdateien bleiben als stabile, leere Lockidentität bestehen.

Der monotone Arbeitsdeadline und die gesonderte Cleanupfrist sind jeweils auf
höchstens 30 Sekunden begrenzt. Die eingebauten Wartehandler prüfen Deadline
und Cancellation vor Mutation und in Millisekundenschritten. Cancellation vor
einer frischen Ausführung schreibt keine Dateien. Nach begonnenem Arrange
läuft Cleanup im `finally`, unabhängig vom fachlichen Ergebnis und vom
Cancellation-Signal. Cleanupfehler oder dessen Timeout ergeben
`RECOVERY_REQUIRED`; Primärfehler und Cleanupstatus bleiben getrennt.
Dateisystemzugriffe selbst besitzen keinen präemptiven Timeout. Ein harter
Prozessabbruch kann `finally` verhindern und wird über Resume behandelt.

Resume eines abgeschlossenen Journals verändert dieses nicht. `PREPARED`
darf erstmals starten; nach begonnenem Arrange wird ausschließlich Cleanup
wieder aufgenommen. Unterbrochene fachliche Arbeit wird `INTERRUPTED` und
niemals wiederholt oder als bestanden ausgegeben. Cleanup besitzt insgesamt
höchstens drei persistierte Versuche; nach deren Verbrauch bleibt
`RECOVERY_REQUIRED` ohne weitere Mutation. Die Ergebnisausgabe enthält nur
Version, Operations-ID und feste Phasen-/Statuswerte, keine Pfade, Schlüssel,
Rohfehler oder Nutzdaten. Die Dateien bleiben lokale Runtimeartefakte außerhalb
der Versionsverwaltung.

Die Ownershipgrenze setzt einen vertrauenswürdigen lokalen Aufrufer und ein
privates lokales Verzeichnis voraus. Sie ist keine Mehrbenutzer-Sandbox, kein
Schutz gegen einen Angreifer mit Schlüssel oder gleichwertigem Dateisystemzugriff
und kein Schutz gegen Replay eines früher authentifizierten Journals. Bei
Journalmanipulation hat fail-closed Vorrang vor Cleanup; der synthetische State
bleibt zur Untersuchung erhalten. Provider-Compensation, echte SQL-Mutationen,
öffentliche Evidenzprojektionen und fachliche Szenarien bleiben offen.

`Tests/Static/Invoke-ScenarioExecutorChecks.ps1` prüft den produktiven internen
Executor offline, einschließlich eines tatsächlich hart beendeten eigenen
PowerShell-Kindprozesses und anschließenden Cleanup-Resume. Der Test verwendet
nur temporäre synthetische State-Verzeichnisse und entfernt seine Fixtures.
Ein bestandener Lauf ist kein Docker-, Podman-, Hyper-V- oder SQL-Nachweis.

## Offene Entscheidungen

Folgende öffentliche oder dauerhafte Entscheidungen sind weiterhin `DECISION_REQUIRED` und werden durch diesen internen Slice nicht entschieden:

- Registration Authority und öffentliches Namens-/Versionsmodell für Scenario-Identitäten;
- Kompatibilitäts- und Migrationsregeln einer späteren öffentlichen Contract-Version;
- zulässige persistierte und öffentliche Evidence-/Outcome-Projektionen;
- Bindung von fachlichen Consumer-Inhalten, Provider-Capabilities und Runtime-Evidence an den späteren Executor.

Der vorhandene `SqlServerLab.AiScenario/1.0`-Vertrag und seine Runtime bleiben eigenständig und unverändert. Dieser Slice erklärt weder SCN-801 noch Gate M8 als abgeschlossen oder runtime-validiert.
