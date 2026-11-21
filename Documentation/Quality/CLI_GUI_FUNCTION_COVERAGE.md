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
`Documentation/User/FUNCTIONS_CLI_GUI.md` findet 151 der 166 Exportnamen und
15 dort nicht referenzierte Exporte. Das ist ein Referenzabgleich, keine
vollständige Prüfung, ob die 151 Treffer tatsächlich korrekt geführt,
ausführbar oder providerabgenommen sind. Die folgende Inventarliste hält die
15 nicht referenzierten Namen einzeln fest. Die sieben Environment-Group-
Operationen aus dem vorherigen Abgleich sind jetzt in der Funktionsübersicht
enthalten und unten separat quellengestützt als `GUIDED_BOTH` bewertet. Von
den verbleibenden 15 Einträgen sind vier TLS-001-Exporte `DEFERRED`,
7 Exporte als `KNOWN_GAP`, einer als `EXPERT_CATALOG_ONLY` und 3 als
`NOT_ASSESSED` bewertet.
Die Bewertung folgt aus Menüdispatch, GUI-Aktion, öffentlichen Parametern
und den vorhandenen Nachweisen. Der Expertenkatalog allein erfüllt die
geführte Abdeckung nicht.

| Funktionsfamilie | Nicht einzeln in der Funktionsübersicht referenzierte Exporte | Status |
|---|---|---|
| Shared Gateway | `Get-SqlServerLabAiSharedGatewayPlan`; `Test-SqlServerLabAiSharedGatewayPreflight`; `Register-SqlServerLabAiSharedGatewayStorage`; `Test-SqlServerLabAiSharedGatewayUpstream`; `Start-SqlServerLabAiSharedGatewaySession`; `Stop-SqlServerLabAiSharedGatewaySession`; `Get-SqlServerLabAiSharedGatewayStatus` | `KNOWN_GAP` für diese sieben Fachaktionen. Der vorhandene Dialog zum Dienst-Preflight nimmt einen bereits erstellten Gateway-Plan entgegen. |
| Modell-/Gateway-Lifecycle | `Test-SqlServerLabAiExternalModelEndpoint`; `Start-SqlServerLabOvmsHttpsGateway`; `Stop-SqlServerLabOvmsHttpsGateway` | `NOT_ASSESSED`; vorhandene Workflow-Dokumentation weist Lifecycle-Lücken aus |
| Security-Tool-Katalog | `Get-SqlServerLabSecurityToolPlan` | `EXPERT_CATALOG_ONLY`. Die produktive Allowlist ist leer, der lokale Resolver blockiert alle Anfragen. [Katalogvertrag und Freigabestand](../Project_Planning/SECURITY_TOOL_ACQUISITION_BACKLOG.md). |
| TLS-001, zurückgestellt | `Update-SqlServerLabTlsBinding`; `Get-SqlServerLabTlsBindingRecovery`; `Resolve-SqlServerLabTlsBindingRecovery`; `Read-SqlServerLabQualifiedTestEnvironment` | `DEFERRED`; bestehender Zustand bleibt erhalten, keine neue Abdeckungs- oder Runtimearbeit ohne dokumentierten Anwendungsfall |

Die 15 Namen ohne Referenz und die einzeln geprüften Exporte unten
wurden unmittelbar gegen `FunctionsToExport` im Manifest
abgeglichen; die Familiengruppierung ist nur eine Lesbarkeitshilfe. Sie ist
keine Behauptung, dass eine Familie einen gemeinsamen Aufrufer oder denselben
Nachweis besitzt.

## Geprüfte Operationen: Environment Groups

Der Abgleich von CLI-Router, Konsolenmenü, Browserdialog, typed HTTP route und
den fokussierten Vertragsprüfungen bestätigt für die sieben öffentlichen
Gruppenoperationen geführte Aktionen in beiden Oberflächen. Das schließt nur
diese Operationsgruppe ein; es behauptet keine vollständige Gesamtmatrix.

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis | Provider-/Versions-Evidence |
|---|---|---|---|---|
| Gruppen lesen und Bindungsstatus anzeigen | Lab-Umgebungen → Umgebung auswählen und verwalten → Lab-Umgebungsgruppen verwalten → Runtime-Zustand eines Mitglieds lesen | Lab-Umgebungen → Lab-Umgebungsgruppen ansehen → Gruppen erneut lesen; optional Runtimestatus live lesen | `Get-SqlServerLabEnvironmentGroup`; `Invoke-EnvironmentGroupLifecycleChecks.ps1`; `EnvironmentGroupsBrowserHttpChecks.ps1`; `EnvironmentGroupsBrowserUiChecks.cjs` | Containerbeobachtung und Gruppenstatus getrennt; kein SQL-Readiness-Nachweis |
| Leere Gruppe anlegen | gleicher CLI-Pfad → Lab-Umgebungsgruppen verwalten → Gruppe erstellen | gleicher GUI-Pfad → Leere Gruppe erstellen | `New-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; UI bestätigt vor dem Auftrag | kein Provideraufruf |
| Vorhandenen Run zuordnen | gleicher CLI-Pfad → Gruppe wählen → Run-ID hinzufügen | gleicher GUI-Pfad → gestoppte Gruppe → Run zuordnen | `Add-SqlServerLabEnvironmentGroupMember`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; synthetischer Mehrgruppenfall | Docker und Podman Mehrgruppen-Lifecycle separat am 2026-11-08 nativ abgenommen |
| Einzelne Zuordnung lösen | gleicher CLI-Pfad → Gruppe wählen → Zuordnung lösen | gleicher GUI-Pfad → gestoppte Gruppe → Zuordnung lösen | `Remove-SqlServerLabEnvironmentGroupMember`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; andere Gruppen und Run bleiben gebunden | kein eigener UI-Runtime-Smoke; Cleanup der eigenen Container-Runs ist im verknüpften Szenario belegt |
| Gruppe samt Zuordnungen entfernen | gleicher CLI-Pfad → gestoppte Gruppe → Gruppe entfernen | gleicher GUI-Pfad → gestoppte Gruppe → Gruppe entfernen | `Remove-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; Entfernen stoppt/entfernt keine Runs | kein eigener Provider-Lifecycle; siehe Cleanup-Grenze im Testvertrag |
| Gruppe starten | gleicher CLI-Pfad → Gruppe wählen → Gruppe starten | gleicher GUI-Pfad → Gruppe starten | `Start-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; neue Starts werden SQL-bereitschaftsgeprüft | Docker und Podman, SQL 2025 CU9: je `OPENQUERY`, Gruppenstart und Cleanup bestanden |
| Gruppe stoppen | gleicher CLI-Pfad → Gruppe wählen → Gruppe stoppen | gleicher GUI-Pfad → Gruppe stoppen / Wiederherstellen und stoppen | `Stop-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; bei weiterem Gruppenanspruch bleibt der Run aktiv | Docker und Podman, SQL 2025 CU9: geteilter Ziel-Run blieb nach Stop der ersten Gruppe aktiv und stoppte nach Freigabe des letzten Anspruchs |

Die CLI- und GUI-Prüfungen verwenden synthetische Registry-/DOM-/HTTP-
Fixtures; sie beweisen keine native Ausführung der jeweiligen Oberfläche mit
echten Laufzeitressourcen. Die native Linked-Server-Gruppenabnahme belegt das
Produktverhalten für die gebundenen Docker-/Podman-Zellen, aber keine
GUI-Automation, TLS-Identitätsprüfung, Kerberos-, MSDTC- oder gruppeneigene
Netzwerkkonfiguration. Details stehen in der [datierten Abnahme](LINKED_SERVER_ENVIRONMENT_GROUP_ACCEPTANCE_2026-11-08.md)
und dem [Gruppenvertrag](../Architecture/LAB_ENVIRONMENT_GROUPS.md).

## Geprüfte Operation: llama.cpp-Paketübersicht

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis | Provider-/Versions-Evidence |
|---|---|---|---|---|
| Vorhandene Runtime-Paketdateien suchen (`Get-SqlServerLabLlamaCppRuntime`) | Host-Dienste und Modelle → Vorhandene llama.cpp-Pakete prüfen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH`. Lesen aus den konfigurierten Suchwurzeln und Anzeige von Backend, Build und unvollständiger Suche. `Invoke-LlamaCppRuntimeChecks.ps1` und einmaliger HTTP-Aufruf im Browserfixture. Freie Suchwurzeln bleiben ein PowerShell-Parameter. | Synthetische Paketdateien. Kein Modell-, Geräte-, SQL- oder Providerlauf für diese reine Dateisuche erforderlich. |
| Eigene llama.cpp-Sitzung starten (`Start-SqlServerLabLlamaCppRuntime`) | Host-Dienste und Modelle → Eigene llama.cpp-Sitzung geführt starten | Host-Dienste und Modelle → llama.cpp: eigene Sitzung starten | `GUIDED_BOTH`. Eingabe und Bestätigung führen zum bestehenden öffentlichen Start. CLI- und Browser-Vertragssuiten. | Synthetische Fälle. Native Abnahme des geführten Starts `NOT_EXECUTED`. |
| Eigene llama.cpp-Sitzung stoppen (`Stop-SqlServerLabLlamaCppRuntime`) | Host-Dienste und Modelle → Eigene llama.cpp-Sitzung auswählen und stoppen | Host-Dienste und Modelle → Eigene llama.cpp-Sitzung stoppen | `GUIDED_BOTH`. Beide Dialoge bestätigen eine gebundene Stop-Vorschau und nutzen denselben Core wie das Cmdlet. Geschützte Verbraucher sperren den geführten Stopp. `Invoke-LlamaCppSessionGuidanceChecks.ps1`. | Nativer Prozess- und Cleanup-Nachweis am 30.09.2026 im dokumentierten Scope. SQL- und Modellbetrieb sind separat. |

## Geprüfte Operationen: Container-Autostart

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis | Provider-/Versions-Evidence |
|---|---|---|---|---|
| Volltext und FILESTREAM ändern (`Set-SqlServerLabFeature`) | Lab-Umgebungen → Datenbanken, Samples und Skripte → Volltext und FILESTREAM ändern | Lab verwalten → SQL-Funktionen an der gewählten Instanz | `GUIDED_BOTH` für bestätigte Änderungen. Die CLI-Auswahl lässt FILESTREAM nur für Hyper-V zu. Native Abnahme des neuen CLI-Pfads `NOT_EXECUTED`. |
| Hyper-V-Autostart (`Get-SqlServerLabHyperVAutoStartPlan`, `Set-SqlServerLabHyperVAutoStart`) | Lab-Umgebungen → Hyper-V-Autostart ändern | Lab verwalten → Reguläre Hyper-V-Umgebungen → Hyper-V-Autostart ändern | `GUIDED_BOTH`. Gebundene Vorschau, Bestätigung und einmalige Browserfreigabe sind synthetisch geprüft. Native Abnahme der neuen Absicherung `NOT_EXECUTED`. |
| Hyper-V-Autostart-Recovery (`Resume-SqlServerLabHyperVAutoStart`) | Lab-Umgebungen → Hyper-V-Autostart-Recovery fortsetzen | Lab verwalten → Reguläre Hyper-V-Umgebungen → Hyper-V-Autostart ändern → Autostart-Recovery fortsetzen | `GUIDED_BOTH`. Synthetische Fälle prüfen die Journalbindung und Statepersistenz. Native Abnahme des neuen Bedienpfads `NOT_EXECUTED`. |
| Startpolicy lesen und ändern (`Get-SqlServerLabContainerAutoStartPlan`, `Set-SqlServerLabContainerAutoStart`) | Lab-Umgebungen → Docker-/Podman-Autostart ändern | Lab verwalten → Container-Autostart ändern | `GUIDED_BOTH`. Der Plan bindet die Zielpolicy. Der Browser bestätigt nur die zuletzt geprüfte Änderung über eine einmalige Auswahl. `Invoke-ContainerAutoStartChecks.ps1` und Browserfixtures. | Synthetische Vertragsfälle. Native CLI- und GUI-Abnahme `NOT_EXECUTED`. |
| Journaloperation fortsetzen (`Resume-SqlServerLabContainerAutoStart`) | Lab-Umgebungen → Docker-/Podman-Autostart-Recovery fortsetzen | Lab verwalten → Container-Autostart-Recovery fortsetzen | `GUIDED_BOTH`. Die Journaloperation wird unter der Sperre erneut geprüft. Die Browserauswahl ist einmalig und läuft nach fünf Minuten ab. `Invoke-ContainerAutoStartChecks.ps1` und Browserfixtures. | Synthetische Vertragsfälle. Native CLI- und GUI-Abnahme `NOT_EXECUTED`. |

## Geprüfte Operationen: Hostfähigkeiten und Run-Artefakte

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis |
|---|---|---|---|
| Provider- und Sprachübersicht (`Get-SqlServerLabHostCapabilityMatrix`) | Hauptmenü → Hostfähigkeiten vor der Funktionsauswahl | Lab erstellen → Hostfähigkeiten vor der Funktionsauswahl | `GUIDED_BOTH` für Katalog und explizite Lesebeobachtung. Hostmatrix-Vertrags- und Browser-Suites. |
| Sprachvariante prüfen (`Get-SqlServerLabExternalRuntimeCapability`) | Hostfähigkeiten → Konkrete Container-Variante näher prüfen | Lab erstellen → Python / R / Java: Katalog und Hostvoraussetzungen | `GUIDED_BOTH` für die geführte katalogisierte Docker-/Podman-Linux-Auswahl. Hostmatrix-Launchdetails und External-Runtime-Browser-Suites. SQL-Sprachausführung bleibt getrennt. |
| llama.cpp-Eignung prüfen (`Get-SqlServerLabAiRuntimeCapability`) | Host-Dienste und Modelle → llama.cpp-Eignung prüfen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für die Prüfung vorhandener Paketdateien gegen die Geräteinventur. Runtime-Ausführung und Leistungsnachweise erfolgen separat. |
| SSIS-Ausführungsmetadaten (`Get-SqlServerLabSsisExecutionDiagnostic`) | Lab-Umgebungen → SSIS-Diagnose eines bestehenden Windows-Labs | Lab verwalten → Reguläre Hyper-V-Umgebungen → SSISDB-Ausführung beobachten | `GUIDED_BOTH`. Menü, Belegbindung und Browserdarstellung sind synthetisch geprüft. Native Abnahme der neuen Bedienpfade `NOT_EXECUTED`. |
| SSIS-Paketladediagnose (`Get-SqlServerLabSsisPackageDiagnostic`) | Lab-Umgebungen → SSIS-Diagnose eines bestehenden Windows-Labs | Lab verwalten → Reguläre Hyper-V-Umgebungen → SSIS-Paketladediagnose | `GUIDED_BOTH`. Auswahl, Belegbindung und Vertrauensbestätigung sind synthetisch geprüft. Native Abnahme der neuen Bedienpfade `NOT_EXECUTED`. |
| Erlaubte Gerätekombinationen anzeigen (`Get-SqlServerLabAiComputeCandidate`) | Host-Dienste und Modelle → llama.cpp-Eignung prüfen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für die aggregierte Anzahl je Backend und Geräteklasse aus der gebundenen Prüfung. |
| Gerätekombinationen messen (`Measure-SqlServerLabAiComputeCandidate`, `Measure-SqlServerLabAiComputeCandidateSet`) | Host-Dienste und Modelle → llama.cpp-Gerätekombinationen messen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für ein lokal gebundenes GGUF und installierte llama-bench-Kandidaten. Geführte Einzel- und Serienauswahl synthetisch geprüft. Neue Hardwaremessung `NOT_EXECUTED`. |
| Portables Lab-Paket prüfen (`Get-SqlServerLabPortableLabImportPlan`) | Datenbanken, Samples und Skripte → Portables Lab-Paket prüfen | Lab-Umgebungen → Datenbankpakete → Portables Lab-Paket prüfen | `GUIDED_BOTH` für die JSON-Prüfung gegen einen registrierten Docker-/Podman-Run. Katalog, Schema und Zielbindung synthetisch geprüft. |
| Automatisierungsvertrag lesen (`Get-SqlServerLabAutomationPlan`) | Wartung, Aufräumen und Recovery → Automatisierungsschnittstelle ansehen | Wartung → Automatisierungsschnittstelle ansehen | `GUIDED_BOTH` für sechs Fachverträge und deren Pflichtparameter. Die Ansicht führt keinen Fachvorgang aus. |
| SQL-Editionsbeleg aktualisieren (`Update-SqlServerLabSqlGuestEvaluationEvidence`) | Wartung, Aufräumen und Recovery → SQL-Editionsbeleg im Gast aktualisieren | Wartung → SQL-Editionsbeleg im Gast aktualisieren | `GUIDED_BOTH` für geeignete eigene laufende Hyper-V-Labs mit SQL Server 2025. Auswahl und Bestätigung sind synthetisch geprüft. Native Abnahme der neuen Bedienpfade `NOT_EXECUTED`. |
| CPU, GPU und NPU erfassen (`Get-SqlServerLabAiComputeInventory`) | Host-Dienste und Modelle → CPU, GPU und NPU erfassen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für die Übersicht. Synthetische vollständige und partielle Gerätebefunde in Inventar- und Browserfixtures. Keine Geräte- oder Runtimequalifikation. |
| Metadaten eines entfernten Runs prüfen und entfernen (`Get-SqlServerLabRunArtifactRemovalPlan`, `Invoke-SqlServerLabRunArtifactRemoval`) | Wartung, Aufräumen und Recovery → Artefakte eines entfernten Runs | Wartung und Recovery → Run-Artefakte prüfen | `GUIDED_BOTH`. Dieselben Cmdlets für gebundene Vorschau, bestätigte Entfernung und Fortsetzung. Workflow-UI und CLI-Vertragsfälle mit synthetischem State. |
| Evaluationsersatz oder Migration vorprüfen (`Get-SqlServerLabEvaluationRefreshPlan`) | Wartung, Aufräumen und Recovery → SQL-Evaluation: Ersatz- und Migrationsentscheid | Wartung und Recovery → SQL-Evaluation: Ersatzentscheid | `GUIDED_BOTH` für die lesende Vorschau. Synthetische CLI-, HTTP- und Browserfälle. Die Vorschau führt keine Übernahme aus. |
| Vorhandene Hyper-V-Checkpoints lesen (`Get-SqlServerLabHyperVRecoveryPointPlan`) | Wartung, Aufräumen und Recovery → Hyper-V-Wiederherstellungspunkte lesen | Wartung → Hyper-V-Wiederherstellungspunkte lesen | `GUIDED_BOTH` für das Checkpoint-Inventar. Synthetische Menü- und HTTP-Bindung geprüft. Native Oberflächenabnahme `NOT_EXECUTED`. |
| Gespeicherten Diagnosebefund lesen (`Get-SqlServerLabDiagnosticBundle -SkipReadiness`) | Wartung, Aufräumen und Recovery → Gespeicherten Diagnosebefund lesen | Wartung → Gespeicherten Diagnosebefund lesen | `GUIDED_BOTH` für gebundene Metadaten im Standard-Lab_Data. Native Provider- und SQL-Readiness sind hier `NOT_EXECUTED`. |
| Vector-Core-Szenarioplan lesen (`Get-SqlServerLabAiScenario`) | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → Szenarioplan | Host-Dienste und Modelle → Vector-Core-Szenarioplan lesen | `GUIDED_BOTH` für `vector-core-ci/1.0`, entweder aus dem Katalog oder gegen den gespeicherten KI-Intent einer laufend registrierten Docker-/Podman-Instanz. Das Szenario wird nicht ausgeführt. |
| Run-State-Format prüfen (`Get-SqlServerLabRunStateUpgradePlan`) | Wartung, Aufräumen und Recovery → Format eines Run-States prüfen | Wartung → Format eines Run-States prüfen | `GUIDED_BOTH` für die lesende Vorschau eines registrierten Runs. Der getrennte Upgrade-Befehl bleibt auf synthetische Legacy-States begrenzt. |

## Bereichsinventar

Die Netzmigration über `Move-SqlServerLabContainerNetwork` ist bei der
Ausführung weiterhin `KNOWN_GAP`: Die CLI und der Browser führen nur die
`-WhatIf`-Vorschau. Die bestehende Ausführung hat keine an die bestätigte
Vorschau gebundene Revision und kann laufende SQL-Container unterbrechen.

Beim persistenten KI-Retrieval führen beide Oberflächen die synthetische
Demo. Eigene Dokumente, Sync, Prune und die Entfernung einer Collection
bleiben als geführte Aktionen offen (`KNOWN_GAP`).

Die Bereiche und dokumentierten Grenzen entsprechen der neun Bereiche
umfassenden Navigation in der [Workflow-Oberfläche](../HowTo/WORKFLOW_UI.md).
`TEILWEISE` bedeutet, dass die Oberfläche passende Einstiege enthält, aber
nicht alle Operationen des Bereichs einzeln auf einen CLI-Menüpfad, GUI-Aktion,
öffentlichen Vertrag, Voraussetzungen und Testbelege abgebildet wurden.

| Fachbereich | Geführter CLI-Einstieg | GUI-Bereich | Vorhandene Grundlage | Bewertung |
|---|---|---|---|---|
| Lab-Umgebungen, Run-Lifecycle, Datenbanken, Samples und Skripte | Lab-Umgebungen | Lab-Umgebungen | Workflow-Einstieg; ausgewählte öffentliche Cmdlet-Zuordnungen; Container-/Hyper-V-Abnahmen in der [CLI-Akzeptanzmatrix](CLI_ACCEPTANCE_MATRIX.md) | `TEILWEISE`; vollständige Operations- und Änderungsmatrix offen |
| Geschützte Testsystem-Matrix | Testsystem-Matrix | Geschützte Testsystem-Matrix | Gruppen-/Power-Dialog und vorhandene statische Verträge | `TEILWEISE`; vollständige Operationszuordnung und weitere geführte Aktionen `NOT_ASSESSED` |
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

Beim historischen Podman-Gate von PR #864 scheiterte der KI-Samples-Test.
Sein eigener Cleanup war erfolgreich. Am 21.11.2026 bestand der übernommene
CMS-Fix zur Wiederverwendung persistenter Labnamen auf dem aktuellen
Entwicklungsstand je acht gezielte native Prüfungen mit Docker und Podman.
Beide Abnahmen bestätigen das abschließende Inventar. Die Freigabe des
integrierten Stands benötigt dessen eigene grüne Pflicht-CI.

TLS-001 bleibt nach Projektentscheidung zurückgestellt.
