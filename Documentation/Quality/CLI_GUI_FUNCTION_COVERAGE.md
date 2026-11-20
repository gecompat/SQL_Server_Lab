# CLI- und GUI-Funktionsabdeckung

| Merkmal | Wert |
|---|---|
| Status | `INCOMPLETE` |
| Bestandsaufnahme | 2026-11-20 |
| Autoritative Exportquelle | `SqlServerLab.psd1` |
| Zielvertrag | [Cross-Cutting Backlog](../Project_Planning/CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md#vollständige-cli-abdeckung-aller-lab-funktionen) |

## Zweck und Bewertungsregeln

Diese Datei beginnt die geforderte Zuordnung von Produktoperationen zu
geführter CLI-Navigation, Browser-GUI, öffentlicher PowerShell-API und
Nachweisen. Sie ist ausdrücklich noch keine vollständige Operationsmatrix und
keine Releasefreigabe.

Das Manifest exportiert 166 Funktionen aus 137 Skriptdateien. Der erzeugte
Expertenkatalog macht die 165 Befehle neben dem zentralen CLI-Einstieg und im
Browser auffindbar. Das beweist weder einen verständlichen geführten Fachweg
noch die Laufzeitfähigkeit jeder Operation. Die vorhandene
[Cmdlet-Funktionsübersicht](../User/FUNCTIONS_CLI_GUI.md) enthält bereits
Zuordnungen für ausgewählte Befehle; sie ist nicht vollständig für alle
Exporte und bildet nicht für jeden Eintrag Prüf- und Providergrenzen ab.

Die Statuswerte bewerten geführte Bedienbarkeit, nicht das bloße Vorhandensein
eines Cmdlets:

| Status | Bedeutung |
|---|---|
| `GUIDED_BOTH` | Geführte Fachaktion in CLI und GUI nachgewiesen; keine Aussage über andere Providerzellen. |
| `GUIDED_CLI_ONLY` / `GUIDED_GUI_ONLY` | Geführte Fachaktion nur in der genannten Oberfläche nachgewiesen. |
| `EXPERT_CATALOG_ONLY` | Befehl ist im Expertenkatalog verfügbar, aber keine geführte Fachaktion belegt. |
| `PUBLIC_API_ONLY` | Öffentliche API ist bekannt; Katalog- und geführte Oberflächenzuordnung ist nicht belegt. |
| `KNOWN_GAP` | Eine konkrete fehlende oder unvollständige Fachführung ist dokumentiert. |
| `NOT_ASSESSED` | Zuordnung und Bedienpfad wurden noch nicht einzeln geprüft. |
| `NOT_APPLICABLE` / `UNSUPPORTED` | Nur mit begründeter, quellengestützter Produktgrenze verwenden. |

## Exportreferenz-Audit

Ein mechanischer Abgleich des Manifests mit
`Documentation/User/FUNCTIONS_CLI_GUI.md` findet 113 der 166 Exportnamen und
53 dort nicht referenzierte Exporte. Das ist ein Referenzabgleich, keine
vollständige Prüfung, ob die 113 Treffer tatsächlich korrekt geführt,
ausführbar oder providerabgenommen sind. Die folgenden 53 Funktionen bleiben
einzeln `NOT_ASSESSED`, bis Menüdispatch, GUI-Aktion, öffentliche Parameter
und Evidence anhand der Implementierung geprüft wurden. Der generierte
Expertenkatalog allein ändert ihren Status nicht.

| Funktionsfamilie | Nicht einzeln in der Funktionsübersicht referenzierte Exporte | Status |
|---|---|---|
| Hostfähigkeit und External Runtime | `Get-SqlServerLabHostCapabilityMatrix`; `Get-SqlServerLabExternalRuntimeCapability` | `NOT_ASSESSED` |
| SSIS-Diagnose | `Get-SqlServerLabSsisPackageDiagnostic`; `Get-SqlServerLabSsisExecutionDiagnostic` | `NOT_ASSESSED` |
| KI-Compute-Auswahl und Messung | `Get-SqlServerLabAiComputeInventory`; `Get-SqlServerLabAiRuntimeCapability`; `Get-SqlServerLabAiComputeCandidate`; `Get-SqlServerLabAiComputeSelection`; `Measure-SqlServerLabAiComputeCandidate`; `Measure-SqlServerLabAiComputeCandidateSet` | `NOT_ASSESSED` |
| Shared Gateway | `Get-SqlServerLabAiSharedGatewayPlan`; `Test-SqlServerLabAiSharedGatewayPreflight`; `Register-SqlServerLabAiSharedGatewayStorage`; `Test-SqlServerLabAiSharedGatewayUpstream`; `Start-SqlServerLabAiSharedGatewaySession`; `Stop-SqlServerLabAiSharedGatewaySession`; `Get-SqlServerLabAiSharedGatewayStatus` | `NOT_ASSESSED` |
| Modell-/Gateway-Lifecycle | `Get-SqlServerLabLlamaCppRuntime`; `Start-SqlServerLabLlamaCppRuntime`; `Stop-SqlServerLabLlamaCppRuntime`; `Test-SqlServerLabAiExternalModelEndpoint`; `Test-SqlServerLabOvmsUpstreamEndpoint`; `Start-SqlServerLabOvmsHttpsGateway`; `Stop-SqlServerLabOvmsHttpsGateway` | `NOT_ASSESSED`; vorhandene Workflow-Dokumentation weist Lifecycle-Lücken aus |
| Evaluation und Watch | `Get-SqlServerLabEvaluationRefreshPlan`; `Update-SqlServerLabSqlGuestEvaluationEvidence`; `Invoke-SqlServerLabEvaluationWatchTrigger` | `NOT_ASSESSED` |
| Transfer und Vergleich | `Invoke-SqlServerLabPortableContainerTransferPreflight`; `Invoke-SqlServerLabPortableContainerTransfer`; `Test-SqlServerLabRelationalCoreComparison` | `NOT_ASSESSED` |
| Autostart und Netzwerk | `Get-SqlServerLabContainerAutoStartPlan`; `Get-SqlServerLabHyperVAutoStartPlan`; `Set-SqlServerLabHyperVAutoStart`; `Resume-SqlServerLabHyperVAutoStart`; `Set-SqlServerLabContainerAutoStart`; `Resume-SqlServerLabContainerAutoStart`; `Move-SqlServerLabContainerNetwork` | `NOT_ASSESSED` |
| SQL-Features und Zielumgebung | `Set-SqlServerLabFeature`; `Read-SqlServerLabQualifiedTestEnvironment` | `NOT_ASSESSED` |
| Environment Groups | `Get-SqlServerLabEnvironmentGroup`; `New-SqlServerLabEnvironmentGroup`; `Add-SqlServerLabEnvironmentGroupMember`; `Remove-SqlServerLabEnvironmentGroupMember`; `Remove-SqlServerLabEnvironmentGroup`; `Start-SqlServerLabEnvironmentGroup`; `Stop-SqlServerLabEnvironmentGroup` | `NOT_ASSESSED`; weitere geführte Browser-Gruppenaktionen sind als Lücke dokumentiert |
| Run-Artefakt-Retention | `Get-SqlServerLabRunArtifactRemovalPlan`; `Invoke-SqlServerLabRunArtifactRemoval` | `NOT_ASSESSED` |
| Persistentes KI-Retrieval und Security-Tools | `Invoke-SqlServerLabAiPersistentRetrieval`; `Get-SqlServerLabSecurityToolPlan` | `NOT_ASSESSED` |
| TLS-001, zurückgestellt | `Update-SqlServerLabTlsBinding`; `Get-SqlServerLabTlsBindingRecovery`; `Resolve-SqlServerLabTlsBindingRecovery` | `DEFERRED`; bestehender Zustand bleibt erhalten, keine neue Abdeckungs- oder Runtimearbeit ohne dokumentierten Anwendungsfall |

Die 53 Namen wurden unmittelbar gegen `FunctionsToExport` im Manifest
abgeglichen; die Familiengruppierung ist nur eine Lesbarkeitshilfe. Sie ist
keine Behauptung, dass eine Familie einen gemeinsamen Aufrufer oder denselben
Nachweis besitzt.

## Bereichsinventar

Die Bereiche und dokumentierten Grenzen entsprechen der neun Bereiche
umfassenden Navigation in der [Workflow-Oberfläche](../HowTo/WORKFLOW_UI.md).
`TEILWEISE` bedeutet, dass die Oberfläche passende Einstiege enthält, aber
nicht alle Operationen des Bereichs einzeln auf einen CLI-Menüpfad, GUI-Aktion,
öffentlichen Vertrag, Voraussetzungen und Testbelege abgebildet wurden.

| Fachbereich | Geführter CLI-Einstieg | GUI-Bereich | Vorhandene Grundlage | Bewertung |
|---|---|---|---|---|
| Lab-Umgebungen, Run-Lifecycle, Datenbanken, Samples und Skripte | Lab-Umgebungen | Lab-Umgebungen | Workflow-Einstieg; ausgewählte öffentliche Cmdlet-Zuordnungen; Container-/Hyper-V-Abnahmen in der [CLI-Akzeptanzmatrix](CLI_ACCEPTANCE_MATRIX.md) | `TEILWEISE`; vollständige Operations- und Änderungsmatrix offen |
| Geschützte Testsystem-Matrix und Gruppenaktionen | Testsystem-Matrix | Geschützte Testsystem-Matrix | Gruppen-/Power-Dialog und vorhandene statische Verträge | `KNOWN_GAP` für weitere geführte Browser-Gruppenaktionen; übrige Zuordnung `NOT_ASSESSED` |
| Hyper-V-Vorlagen, Windows-Images und operative Slots | Hyper-V: Vorlagen und Slots | Hyper-V: Vorlagen und Slots | Image-/Poolinventar und einzelne gebundene Workflows | `KNOWN_GAP` für operative Slots und vollständiges Provider-Setup; native Nachweise bleiben funktions- und versionsgebunden |
| Ressourcen, Medien, Downloads und Speicher | Ressourcen und Downloads | Ressourcen und Downloads | Ressourcen-/Medienkataloge, ausgewählte Plan-/Apply-Dialoge | `TEILWEISE`; vollständige Operationszuordnung und Providerbelege offen |
| Host-Dienste und Modelle | Host-Dienste und Modelle | Host-Dienste und Modelle | Einzelne Modell-/Hostservice-Dialoge und öffentliche Befehle | `KNOWN_GAP` für Fremdstart und weiteren Hostdienst-/Modell-Lifecycle |
| Verbindungen, Registrierungen und CMS | Verbindungen und CMS | Verbindungen und CMS | Lesende Verbindungssicht und CMS-Inspection; ausgewählte Cmdlet-Abnahmen | `KNOWN_GAP` für CMS-Setup und -Synchronisation im Browser; vollständige Operationszuordnung offen |
| SQL-Lab-Grundkonfiguration | Grundkonfiguration | SQL-Lab-Grundkonfiguration | Gemeinsamer Plan-/Apply-Pfad für dokumentierte Einstellungen | `TEILWEISE`; nicht jede öffentliche Konfigurationsoperation einzeln abgebildet |
| Wartung, Aufräumen und Recovery | Wartung, Aufräumen und Recovery | Wartung/Recovery | Read-only-Pläne, bestätigte Aktionen und Recovery-Verträge je Slice | `TEILWEISE`; komplette Funktions- und Fehlerpfadzuordnung offen |
| Vorgänge, Queue und Scheduler | Vorgänge, Queue und Benutzeraktionen | Vorgänge | Batch-/Queue-Einstiege und Workflow-Aktionen | `TEILWEISE`; jede Operation und ihre Abbruch-/Recoverypfade noch einzeln abzugleichen |
| Expertenbefehle und Meldungen | Alle öffentlichen Befehle / Meldungen | Alle Funktionen / Meldungen | Generierter Export-/Parametersatzkatalog; Konsolen- und Workflow-UI-Prüfungen | `EXPERT_CATALOG_ONLY` als Fachführung; Katalogvollständigkeit ist separat statisch prüfbar |

Die Bezeichnungen stammen aus dem bestehenden Navigationsvertrag. Ein
vorhandener Fachdialog oder Runtime-Smoke darf nur für genau die darin
ausgeführte Operation und gebundene Provider-/Versionszelle als Evidence
verwendet werden.

## Noch ausstehende Operationsmatrix

Diese Matrix muss noch für **jeden** Manifestexport und jede weitere
benutzerseitige Produktoperation eine einzeln prüfbare Zeile mit mindestens
folgenden Feldern erhalten:

1. stabiler Operations-ID und fachlicher Aufgabe, einschließlich Operationen
   an bereits bestehenden Labs;
2. CLI-Menüpfad und getesteter Dispatch, GUI-Bereich und getesteter Aktionspfad;
3. öffentlichem parametriertem Cmdlet, Parametern, WhatIf/Vorschau und
   Bestätigung;
4. Voraussetzungen, Secret-Grenze, Idempotenz, Seiteneffekten sowie
   Fehler-, Cleanup- und Recoveryvertrag;
5. unterstützten Providern und Versionen, mit `NOT_EXECUTED` je nicht
   tatsächlich belegter Runtimezelle;
6. präzisem statischem und Runtime-Testselektor samt Evidence-Revision.

Ein Export, ein Menüeintrag, ein HTTP-Handler oder ein bestandener globaler
Static-Check füllt diese Zeile nicht automatisch aus. Insbesondere erzeugt
eine GUI- oder CLI-Lücke keine neue Providerfähigkeit. Docker, Podman und
Hyper-V bleiben getrennte Nachweisgrenzen; es wird keine Vollmatrix aller
SQL-CUs abgeleitet.

## Umsetzungsreihenfolge und Release-Gate

1. Manifestexporte und die vorhandenen Cmdlet-Referenzen inventarisieren;
   gleiche Fachoperationen über Parameter-/Aliasvarianten deduplizieren.
2. Jede Operation mit tatsächlichem CLI-Menüdispatch, GUI-Aktion und Core
   verbinden und die Statuswerte dieser Datei durch konkrete Quell- und
   Teststellen belegen.
3. Lücken in kohärenten vertikalen Slices ergänzen. Gemeinsame Fachlogik
   bleibt im geprüften Core; Oberflächen stellen sichere Vorschau,
   Eingabevalidierung, nötige Bestätigung und verständliche Recovery bereit.
4. Geänderte statische Verträge zuerst, dann ausgewählte Provider-Smokes
   ausschließlich für unterstützte und betroffene Funktionen prüfen.
5. Erst nach vollständiger vereinbarter Matrix, erfolgreicher betroffener
   Funktionssuite, erforderlichen getrennten Runtime-Nachweisen und grüner
   Pflicht-CI kann ein Release gebaut werden.

Der offene Docker-Fehler für PR #864 ist ein eigener Release-Blocker und darf
nicht als TLS-Befund oder erfolgreicher Provider-Nachweis umgedeutet werden.
TLS-001 ist entsprechend der Projektentscheidung zurückgestellt; diese
Matrix autorisiert weder TLS-Runtime-Läufe noch Änderungen an CA oder Trust.
