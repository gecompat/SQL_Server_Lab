# Foundation 1.24.0: semantisches Upgrade

Stand: 2026-10-20. Scope: ausdrücklich beauftragtes Foundation-Upgrade; vorhandene Facharbeit, Pausen und Runtimefreigaben bleiben unverändert.

## Quelle und vollständige Bewertung

Die Quelle ist [Foundation 1.24.0](https://github.com/gecompat/AI_Repository_Foundation/tree/96391403a1b89e19d4824838806d7190d8033389) am exakten Commit `96391403a1b89e19d4824838806d7190d8033389`. Ausgang ist die installierte Version 1.21.0 aus `d720db4f2f0d043756a958d5195d0e62090b1c8f`. Die [maschinenlesbare Bewertung](../../.ai/foundation-upgrade-assessments/1.21.0-to-1.24.0.json) erfasst alle neun eingeführten oder materiell geänderten Features genau einmal. Historische Bewertungen und Kennungen werden erhalten.

| Feature | Bewertung |
|---|---|
| `ai-runtime-adapters` | `RECOMMENDED` |
| `ai-work-execution` | `NOT_APPLICABLE` |
| `ai-work-orchestration` | `APPLY_DEFAULT` |
| `bounded-processing-efficiency` | `APPLY_DEFAULT` |
| `foundation-baseline` | `APPLY_DEFAULT` |
| `layered-validation` | `APPLY_DEFAULT` |
| `orchestrator-job-control` | `DECISION_REQUIRED` |
| `session-lifecycle-management` | `ALREADY_EQUIVALENT` |
| `test-evidence-reuse` | `RECOMMENDED` |

`RECOMMENDED` bezeichnet eine mögliche Nutzung unter den bestehenden Projektgates. `DECISION_REQUIRED` betrifft ausschließlich eine künftige Aktivierung autonomer Hoststeuerung; sie bleibt für dieses Upgrade ausdrücklich ausgeschaltet. Eine neue Anwendung von Local-to-Remote-Reuse benötigt einen geschützten Producer und Verifikator sowie passende Input-, Runtime-, Freshness-, Oracle- und Cleanupnachweise. Ohne diese Grundlage bleibt der vorhandene Test-/CI-Weg erforderlich. Keine Aktivierung wird aus dem Versionswechsel abgeleitet.

## Erhaltene Projektverträge und Transfer

Die bisherigen 1 Adapter und 1 Capabilities bleiben ausgewählt. Alle 77 ausgewählten Ziele sind im erneuerten Installationsreceipt mit portablem Quell- und Zielhash erfasst. Nur Manifestziele werden übertragen; Projekt-README, Lizenz, Backlog, Status und Identitätsregistry der Foundationquelle werden nicht kopiert. Die Root-Bridge wird innerhalb ihrer Marker aktualisiert. Projektgeführte Discovery, Datenschutzverschärfungen, SQL-/Demo-/Providerverträge, geschützte Lizenztexte und historische IDs bleiben erhalten. Neue Host-, Provider-, Modell-, Netzwerk-, Credential-, Budget- oder GitHub-Adminrechte werden nicht eingerichtet.

Semantisch bleiben strengere Datenschutz-, Freigabe-, Cleanup- und frische CI-Gates `PROJECT_STRONGER`; Sprache, ausgewählte Capabilities und Commitkennzeichnung bleiben `PROJECT_SELECTABLE_OVERRIDE`. Die neuen portablen Verträge sind `COMPLEMENTARY`. Es besteht kein ungelöster Required-Konflikt. Runtime- und native SQL-Abnahmen werden durch die Foundationprüfung nicht bestätigt.

Die aktuelle Basis enthält die [CI-Test- und Evidence-Regeln](CI_TEST_EVIDENCE_POLICY.md) aus dem integrierten PR #808. Sie sind zu Foundation 1.24.0 kompatibel und bleiben projektgeführt; ein lokaler Development-Record wird weder Remote-Attestation noch frischer CI-PASS. Der bestehende konservative Selektor und die offene Nightly-Driftgrenze werden nicht verändert.

## Erforderliche Bewertung des Verarbeitungsaufwands

| Tatsächlicher Weg | Disposition und Schutzgrund |
|---|---|
| Projekt-Testselektion und Workflows | Die vorhandenen konservativen Selektoren und erforderlichen aktuellen Checks bleiben maßgeblich. Foundation-/Regelprüfungen werden vor fachlich betroffenen SQL-Läufen gewählt. Unbekannte Abhängigkeit bleibt ein breiterer Fallback. Keine Matrix oder Oracle wird zur Einsparung entfernt. |
| Optionale ausführbare Referenzen | Nur bereits ausgewählte Capabilities werden aktualisiert. Synthetische lokale Verträge prüfen die betroffenen Datei-/Transport-/Provenienzgrenzen; Live-Provider und automatische Fortsetzung bleiben unkonfiguriert. |
| Logs und Erfolgsbewertung | Bestehende lokale Runner werten Status und begrenzte Findings aus. Rohlogs bleiben lokal; vollständiger Erfolg benötigt keinen zusätzlichen Modellaufruf zur bloßen Bestätigung. Unbekannte Messwerte bleiben unbekannt. |
| Reviews, Modelle und Budget | Ein Implementierungsverantwortlicher bearbeitet die vier ausdrücklich benannten Repository-Upgrades mit je einem kohärenten PR. Zusätzliche Reviews benötigen einen konkreten Befund. Es gibt keine neue Reviewkette, Telemetrie oder behauptete monetäre Budgetdurchsetzung. |
| Warten, Pausen und Aktivierung | Bestehende Pausen und laufende unabhängige PRs bleiben erhalten. Kein Scheduler oder Heartbeat wird eingerichtet. Zustandsabfragen verwenden begrenztes Backoff; unveränderte Blocker lösen keine neue semantische Analyse aus. |

## Validierung und Grenzen

Am 2026-10-20 lokal unter Windows/Python/PowerShell: Foundation-Integrität mit der erhaltenen Auswahl (ein Adapter, eine Capability, 77 Installationsziele): PASS ohne Fehler oder Warnungen. Das vollständige Neun-Feature-Delta und die Erhaltung von README, Lizenz und Arbeitsregeln wurden geprüft. `Tests/Static/Invoke-CiStrategyChecks.ps1` besteht auf der aktuellen Basis mit 845 PASS und 0 FAIL einschließlich der neuen synthetischen CI-Custody-Fälle. Die Pester-Auswahl besteht mit 23 ausgeführten Tests. Die übrigen vom unveränderten Selektor verlangten Doku-, Privacy-, Analyzer- und UI-Gates werden im PR mit ihren tatsächlichen Ergebnissen nachgewiesen; vor Merge bleibt der aktuelle vollständige Required Check verbindlich. Die Kopplung von Quellpin, Versionsintervall, genau neun Kandidaten und Negativfällen bleibt im Dokumentationsvalidator erhalten. Native SQL-/Lab-, Provider-, Trust-, Remote-Evidence- und reale Modellabnahmen bleiben `not executed`, weil das Upgrade keine entsprechende Aktivierung oder fachliche SQL-Änderung vornimmt. Erforderliche bestehende Projektgates bleiben erhalten.
