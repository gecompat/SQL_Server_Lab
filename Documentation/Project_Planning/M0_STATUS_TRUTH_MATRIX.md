# M0-Statuswahrheit und planbare Baseline

| Merkmal | Wert |
|---|---|
| Status | `implemented` |
| Stand | 2026-09-10 |
| Geltungsbereich | Planungsindex, Master-Plan-Zuordnung, Console-UX-Einstieg und Validierungsbereitschaft |
| Runtime-Evidence dieser Welle | `NOT_EXECUTED`: keine Runtimefunktion oder Providerimplementierung geändert |

Dieses Dokument ist die kanonische, deduplizierte Abnahmematrix für M0 aus dem
[Entwicklungs- und Ausführungsplan](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md).
Es bewertet ausschließlich den hier genannten Scope. Historische
Runtime-Evidence bleibt in den datierten Validierungsnachweisen und in
[`KNOWN_LIMITATIONS.md`](../Quality/KNOWN_LIMITATIONS.md) erhalten.

## Statusvokabular

Planungsstände verwenden genau diese Begriffe:

| Status | Bedeutung |
|---|---|
| `planned` | Ziel und Abnahmekriterien sind beschrieben; eine Implementierung ist nicht belegt. |
| `implemented` | Der Vertrag ist im Repository umgesetzt; mindestens ein erforderlicher Nachweis ist noch nicht ausgeführt oder nicht erfolgreich. |
| `validated` | Die für den ausdrücklich genannten Scope erforderlichen Prüfungen wurden ausgeführt und bestanden. |
| `unsupported` | Der Pfad liegt außerhalb des aktuell unterstützten Vertrags; dies ist weder `PASS` noch eine Implementierungsbehauptung. |

Testergebnisse verwenden die Begriffe aus der
[lokalen Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md):
`PASS`, `WARN`, `SKIP_OPTIONAL`, `NOT_EXECUTED`, `UNSUPPORTED`, `FAIL` und
`RECOVERY_REQUIRED`. `SKIP_OPTIONAL`, `NOT_EXECUTED` und `UNSUPPORTED` sind
kein bestandener Runtime-Nachweis.

## Deduplizierte M0-Abnahmekriterien

Jede Zeile ist ein eigenständiges Kriterium. Andere Pläne dürfen darauf
verweisen, sollen den Wortlaut aber nicht als zweite Statusquelle pflegen.

| Kriterium | Deckt ab | Abnahme | Status | Evidence oder Grund |
|---|---|---|---|---|
| `M0-AC-001` | `BASE-001` | Capability-Inventar und diese Matrix trennen vorhandene Artefakte, Implementierung und ausgeführte Nachweise. | `validated` | `Get-SqlServerLabCapabilityInventory.ps1` ist vorhanden; Dokumentationscheck und impacted statische Suites bestanden am 2026-09-10. |
| `M0-AC-002` | `BASE-002` | Der Einstieg für bestehende Hyper-V-Umgebungen liegt unter **Umgebungen verwalten**; das Infrastrukturmenü enthält nur Vorlagen-, Slot-, Build- und Medienaufgaben. | `validated` | Fokussierter `Invoke-ConsoleUiChecks.ps1` und Dokumentationscheck bestanden am 2026-09-10; Runtime-Evidence `NOT_EXECUTED`, weil nur die Menüroute geändert wurde. |
| `M0-AC-003` | `BASE-003` | Jede alte Master-Plan-Welle ist mindestens einem aktuellen Meilenstein zugeordnet; historische Aussagen bleiben erhalten. | `validated` | Mappingtabelle in diesem Dokument und Cross-Doc-Prüfung bestanden am 2026-09-10. |
| `M0-AC-004` | `BASE-004` | Der Dokumentationscheck erzwingt Planindex, Statusvokabular, vollständiges Mapping und widerspruchsfreie UX-Aussagen. | `validated` | `Invoke-DocumentationChecks.ps1` und impacted statische Suites bestanden am 2026-09-10. |
| `M0-AC-005` | `BASE-005` | Jede Änderungsklasse nennt statische Prüfung, erforderliche Runtime-Evidence und zulässigen Ergebnisstatus mit Grund. | `validated` | Readinessmatrix in diesem Dokument und Dokumentationscheck bestanden am 2026-09-10. |

## Mapping der alten Master-Plan-Wellen

Die Wellen 0 bis 9 und 7a im
[Master-Umsetzungsplan](MASTER_IMPLEMENTATION_PLAN.md) bleiben historische
Planungsstruktur. Die folgende Tabelle ordnet sie der aktuellen
Ausführungsstruktur zu, ohne alte Evidence umzuschreiben.

| Alte Welle | Aktueller Meilenstein | Begründung |
|---|---|---|
| Welle 0 | M0, M9 | Repository-Governance gehört zur Statuswahrheit und zum Abschluss-Gate. |
| Welle 1 | M1, M2 | Verträge und CLI-Skelett werden durch Planner sowie UI-Shell konkretisiert. |
| Welle 2 | M2 | Container Quick Environment ist die Referenzimplementierung der umgebungszentrierten Shell. |
| Welle 3 | M1, M3, M8 | Lifecycle-/Recovery-Core, Analyze-Adapter und spätere Ablösung teilen diesen historischen Scope. |
| Welle 4 | M4, M5, M6 | Hyper-V Cold Paths und Reconcile zerlegen die alte Providerwelle in überprüfbare Abschnitte. |
| Welle 5 | M8 | Scenario Engine und Fault Injection bleiben Teil des kontrollierten Migrations- und Szenariohorizonts. |
| Welle 6 | M3 | Der PerformanceSchulung-Pilot gehört zum Adaptermeilenstein. |
| Welle 7 | M3, M8 | Analyze-Pilot und spätere Ablösung der doppelten Implementierung bleiben getrennt. |
| Welle 7a | M3, M8 | Toolbelt-Pilot und spätere Ablösung bleiben getrennt. |
| Welle 8 | M8 | Ablösung und Repositorybereinigung entsprechen dem Migrationsmeilenstein. |
| Welle 9 | M0, M9 | Statuschecks beginnen in M0; Release-Härtung und Gesamtabschluss bleiben M9. |

## Kanonische Readinessmatrix

`Get-CiTestSelection.ps1` und `Invoke-ImpactedChecks.ps1` bestimmen die
konkreten Suites aus den geänderten Pfaden. Die Tabelle legt fest, wie deren
Ergebnis zusammen mit Runtime-Evidence zu bewerten ist.

| Änderungsklasse | Statischer Mindestnachweis | Runtime-Evidence | Status und Grund |
|---|---|---|---|
| Dokumentation, Planung oder Metadaten ohne Produktcode | `Invoke-DocumentationChecks.ps1`, Privacy-Check und impacted Auswahl | `NOT_EXECUTED`, sofern der Selektor keinen Provider verlangt | `validated` nur bei grünen statischen Checks und ohne Runtimebehauptung; sonst `implemented` oder `planned` mit Grund. |
| Console-Navigation oder Hilfetext ohne Änderung einer Fachaktion | `Invoke-ConsoleUiChecks.ps1`, `Invoke-DocumentationChecks.ps1` und impacted Auswahl | `NOT_EXECUTED`, sofern keine Fachaktion oder Providerbindung geändert wurde | `validated` für die Menüroute bei grünen statischen Checks; Providerverhalten bleibt unverändert und erhält keinen neuen Status. |
| Öffentlicher Cmdlet-, Schema-, Katalog- oder Vertragscode | fokussierte Vertragssuite plus impacted Auswahl | die vom Selektor verlangten Docker-, Podman-, Mixed-, Adapter- oder Hyper-V-Nachweise | `validated` nur für tatsächlich erfolgreiche Einzelprovider; fehlende Ausführung bleibt `implemented` und nennt `NOT_EXECUTED`. |
| Gemeinsamer Container- oder Providercode | fokussierte Provider-/Contract-Suites plus impacted Auswahl | jeder betroffene Provider getrennt; Mixed nur bei providerübergreifendem Vertrag | `validated` nur für die ausgeführten Provider; ein anderer Provider darf nicht aus diesem Ergebnis abgeleitet werden. |
| Hyper-V-, Gast-, Storage- oder Recovery-Mutation | fokussierte Hyper-V-/Recovery-Suites plus impacted Auswahl | isolierter, eigener Hyper-V-Nachweis mit dokumentiertem Cleanup | `validated` nur bei bestandener Postcondition und vollständigem Cleanup; sonst `FAIL`, `RECOVERY_REQUIRED` oder `NOT_EXECUTED` mit Grund. |
| Unbekannte produktive Änderung | sichere impacted Auswahl einschließlich Selektor-Fallback | alle vom Selektor geforderten Nachweise | Ohne vollständige angeforderte Evidence höchstens `implemented`; `validated` ist unzulässig. |

## Evidence dieser M0-Welle

| Prüfung | Ergebnis | Aussagegrenze |
|---|---|---|
| `Invoke-DocumentationChecks.ps1` | `PASS` am 2026-09-10 | Planindex, Statusvokabular, Mapping, Links und zentrale Statusaussagen. |
| `Invoke-ConsoleUiChecks.ps1` | `PASS` am 2026-09-10 | Statische Menüroute und Entfernung des Infrastruktur-Duplikats. |
| `Invoke-ImpactedChecks.ps1` | `PASS` am 2026-09-10 | Durch die tatsächlich geänderten Pfade ausgewählte statische Suites. |
| `Invoke-AllChecks.ps1` | `FAIL` am 2026-09-10 | Einmal ausgeführt; außerhalb des Änderungsscopes schlugen `Invoke-LabNetworkChecks.ps1` (`Leerer Hyper-V-Fallback wird nicht als ungültige IP validiert`) und `Invoke-SampleBaselineRuntimeChecks.ps1` (`Hyper-V-Gastexport prüft VM-Zustand, Quelldatei und Hostkopie`) fehl. Das M0-Abschluss-Gate bleibt deshalb offen. |
| Provider-/Runtime-Smokes | `NOT_EXECUTED` | Der Selektor forderte für diese Dokumentations- und Console-Navigationsänderung keinen Provider-Smoke; keine Runtime-Mutation ausgeführt. |
