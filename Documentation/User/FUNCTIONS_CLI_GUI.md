# Funktionsübersicht für CLI und Browser-GUI

Slice E: `Get-SqlServerLabReconcilePlan -ProposedRelations` liefert eine reine
Komponenten-/Shared-Verbrauchervorschau an vorhandener Labidentität. Sie ist
über den generischen CLI-Befehlszugang und **Alle öffentlichen Befehle →
SQL-Komponenten: geführte Vorschau** erreichbar. Der geführte CLI-Dialog wählt
bestehende registrierte Runs und SQL-Voraussetzungen; Zurück verwirft die Eingabe.
Der Browser bietet **SQL-Komponenten: geführte Vorschau** im Bereich
**Verbindungen und CMS** mit derselben registrierten Metadatenautorität.
Root lesen, Run und Instanzen wählen, Voraussetzungen im RAM ergänzen und
Vorschau lesen. Abbruch und verworfene Antworten erstellen keine Jobs.
Der Plan startet nichts, übernimmt keinen Shared-Dienst und
prüft SQL nicht. [Vertrag und Eingabe](../Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md#71-implementierter-enger-komponentenplan-slice-e).

`AIX-001/008`: Ressourcen und Downloads → llama.cpp-Runtime installieren / prüfen
ist in CLI und Browser ein gemeinsamer Fachdialog; direkter CLI-Einstieg:
`Invoke-SqlServerLab -Action RuntimeInstaller`. Initial unterstützt er nur den
kuratierten experimentellen Windows-x64-CPU-Pin b11247, vorhandene Lab_Base-Roots,
Vorschau, bestätigten Download/Extraktion und eine feste begrenzte `--version`-
Probe. Discovery, installierte Byteintegrität, Ausführungsevidence und Empfehlung
sind getrennt; native Probe noch `NOT_EXECUTED`, Empfehlung `UNASSESSED`.
[Scope, Prerequisites und Recovery](../Architecture/LLAMA_CPP_INSTALLER.md).

Die Wartungsführung (`CORE-105/106/109`, `PSR-011`) bietet in CLI und GUI eine
gemeinsame read-only Befundauswahl mit Herkunft, Nutzung und Detailansicht.
Eine fehlende moderne Docker-/Podman-SQL-Speicherzuordnung lässt sich separat
vorprüfen und bestätigt über den bestehenden Katalog-Repair ergänzen.
Unbekannte Identität, unlesbare Referenzevidence und widersprechende Bindungen
sperren; Preview/Abbruch/No-op schreiben nichts. Retained-Löschung bleibt im
separaten bestehenden Plan-/Resume-Verfahren und ist damit nicht nativ abgenommen.

| Merkmal | Wert |
|---|---|
| Stand | 2026-09-30 |
| Autoritative Funktionsliste | [`SqlServerLab.psd1`](../../SqlServerLab.psd1) |
| Öffentliche Funktionen | dynamisch aus `FunctionsToExport` |
| Konsolenoberfläche | `Invoke-SqlServerLab` |
| Browseroberfläche | `Tools/Start-SqlServerLabUi.ps1` und `Ui/` |

## Abgrenzung

Die aktuelle fachliche Zielstruktur steht in
[Abschnitt 4.1 des Ausführungsplans](../Project_Planning/DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md#41-kanonischer-bedienpfad).
CLI und Browser besitzen die neun Bereiche aus Abschnitt 4.1. Lab-Umgebungen
bündelt Erstellen, Auswahl und Verwaltung; Testmatrix, Vorlagen/Slots,
Ressourcen/Downloads, Host-Dienste/Modelle, Verbindungen/CMS,
Grundkonfiguration, Wartung/Recovery und Vorgänge sind eigene Einstiege.
Expertenbefehle und Meldungen bleiben separat. Browserbereiche zeigen nur die
zugehörigen vorhandenen Fachdialoge; Zurück erhält Eingaben und die
Aktualisierung erhält den gewählten Bereich. Fehlende Browserdialoge für
CMS und operative Slots sowie Fremdstart-/weiterer Hostdienst- und
Modell-Lifecycle bleiben sichtbar offen. Der geführte Stop einer eigenen
llama.cpp-Modulsitzung besitzt einen gemeinsamen CLI-/Browserdialog und einen
engen synthetischen nativen Prozessnachweis. Ein Katalogfilter ersetzt keinen
Fachdialog.

Die Testmatrix bietet in CLI und Browser einen gemeinsamen geführten
Power-Start/Stop für die kanonisch registrierte Gruppe. CLI-Einstieg ist
`Invoke-SqlServerLab -Action AutomatedTestEnvironmentLifecycle`. Auswahl,
Mitglieder-/Gesamtstatus, Ist-/Zielvorschau, gesonderte Bestätigung und
Ergebnisse je Mitglied gehören zusammen. SQL-Bereitschaft wird nicht geprüft;
die öffentlichen `Start/Stop-SqlServerLabAutomatedTestEnvironment` behalten
ihren bisherigen Bereitstellungs-/Exportvertrag. Der neue Powerpfad benötigt
genau eine gebundene Instanz pro Run, verweigert zusätzliche Runtimeobjekte
und unbekannte Recovery und bietet keine Einzelmitglied-Aktion. Cancel/No-op
mutieren nicht; Teilfehler erfordern eine neue Vorschau ohne automatische
Wiederholung. Erstellung, Reparatur, Neuaufbau, Removal und CMS sind separate
Verträge. Native Abnahme dieses neuen Dialogpfads steht noch aus.

`New-SqlServerLab`, `New-SqlServerLabBatch`,
`New-SqlServerLabWindowsSlotPool` und die Hyper-V-Erstellung über
`Invoke-SqlServerLabWorkflowAction` verwenden den gemeinsamen
[Windows-Locale-Vertrag](../HowTo/WINDOWS_LOCALE.md).
Manifest, Batch, Slot-Pool und Browser-Erstellung verwenden auch den
[Windows-Aktivierungsintent](../HowTo/WINDOWS_ACTIVATION.md).
`WindowsActivation` am Slot-Pool und Workflow-Adapter bindet Strategie und
Egress; `RepairHyperVWindowsActivation` prueft einen laufenden Slot erneut.

Diese Übersicht erfasst alle Funktionen, die über `FunctionsToExport` im
Modulmanifest zur öffentlichen PowerShell-CLI gehören. Jede aufgeführte
Funktion kann nach dem Modulimport direkt in PowerShell aufgerufen werden. Die
Spalte **Konsolenmenü** nennt zusätzlich die Einbindung in das interaktive
`Invoke-SqlServerLab`-Menü. Die Spalte **Browser-GUI** beschreibt die direkte
oder über `Invoke-SqlServerLabWorkflowAction` vermittelte Verwendung in der
lokalen Browseroberfläche. Unabhängig von einem eigenen geführten Dialog ist
jeder Export im Browser-Arbeitsbereich **Alle Funktionen** über denselben
Parametersatzkatalog erreichbar. Der generische Ergebnisweg maskiert sensible
Eigenschaften; eine ausdrückliche Kennwortanzeige benötigt weiterhin den dafür
vorgesehenen umgebungsgebundenen Dialog.

Das Konsolenmenü wertet Host- und Providerfähigkeiten vor einer Auswahl aus.
Nicht unterstützte Aktionen erscheinen dunkelgrau und nennen den konkreten
Grund samt Abhilfe; der nummerierte Fallback zeigt dieselbe Begründung. Für
External Languages verwenden Menü, Planung und Ausführung dieselbe Live-
Entscheidung. Docker und Podman benötigen dafür rootful Linux mit cgroup v1.
Eine Podman-Runtime mit cgroup v2 bleibt für allgemeine Labs verwendbar, wird
für External Languages jedoch mit `CGROUP_VERSION_UNSUPPORTED` deaktiviert.

Der Hauptmenüpunkt **Alle öffentlichen Befehle** wird direkt aus den
Modulexporten aufgebaut. Damit ist jede veröffentlichte Funktion zusätzlich zu
den fachlich geführten Menüs über `Invoke-SqlServerLab` erreichbar. Vor der
Ausführung wählt der Benutzer genau einen nativen Parametersatz. Das Formular
zeigt Pflichtstatus, Typ, deklarierte Defaults und alle aus `ValidateSet`, Enum,
`ValidateRange`, `ValidatePattern`, `ValidateLength` und `ValidateCount`
ableitbaren Eingabegrenzen. Komplexe Werte werden als JSON eingegeben;
Credentials und andere sensible Werte werden maskiert erfasst. Befehle mit
`SupportsShouldProcess` bieten `WhatIf` explizit mit dem Standard `false` an.
Der Browser verwendet denselben Katalog, dieselben Parametersätze und dieselben
Eingabegrenzen. Ändernde Befehle erfordern dort zusätzlich den einheitlichen
Bestätigungsdialog; Parameter mit Geheimnissen bleiben in einem flüchtigen Job
und werden nicht in der Queue persistiert.

Interne Hilfsfunktionen aus `Private/`, `Providers/` und nicht exportierte
Hilfsfunktionen aus `Public/` sind kein stabiler Benutzervertrag und werden
nicht einzeln aufgeführt. Der aktuelle Quellbestand enthält einschließlich
lokaler und verschachtelter Helfer deutlich mehr Funktionsdefinitionen; deren
Dateiablage allein macht sie weder zu CLI- noch zu GUI-Funktionen.

Legende:

- **direkt**: Die Oberfläche ruft das exportierte Cmdlet auf.
- **über Adapter**: Die Browser-GUI verwendet das Cmdlet über
  `Invoke-SqlServerLabWorkflowAction`.
- **über Core**: Die Bedienfunktion ist vorhanden, die Oberfläche verwendet
  jedoch einen gemeinsamen internen Core und nicht dieses exportierte Cmdlet
  direkt.
- **–**: Kein eigener geführter Fachdialog. Der Befehl bleibt über **Alle
  öffentlichen Befehle** in der CLI, über **Alle Funktionen** im Browser und
  als direkter PowerShell-Aufruf verfügbar. Sensible Ergebnisse bleiben im
  generischen Browser-Log maskiert.

## Batch, Queue und Scheduler

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`New-SqlServerLabBatch`](../../Public/BatchWorkflow.ps1) | Validiert und expandiert einen Einzel- oder Mengenbatch und reiht ihn persistent ein. | Vorgänge, Queue und Benutzeraktionen → Composer | direkt: Composer und persistente Einreihung von Browseraktionen |
| [`Get-SqlServerLabBatch`](../../Public/BatchWorkflow.ps1) | Liest Batchplan, Abhängigkeiten, Fortschritt und Cleanup-Scope. | Vorgänge, Queue und Benutzeraktionen | direkt: Workflow-Inventur |
| [`Get-SqlServerLabQueue`](../../Public/BatchWorkflow.ps1) | Zeigt Worker, Locks, Blockierungen und User-Gates. | Statusbanner und Queue | direkt: Queue-Ansicht und Workflow-Inventur |
| [`Get-SqlServerLabOperation`](../../Public/BatchWorkflow.ps1) | Liest Schritte, Receipts, Events und Ergebnis eines Kindvorgangs. | Queue → Vorgangsdetails | direkt: Workflow-Inventur |
| [`Confirm-SqlServerLabOperationUserAction`](../../Public/BatchWorkflow.ps1) | Prüft ein User-Gate technisch und setzt nur eine erfolgreiche Position fort. | Queue → Benutzeraktion bestätigen | direkt: User-Gate bestätigen |
| [`Move-SqlServerLabOperation`](../../Public/BatchWorkflow.ps1) | Verschiebt einen wartenden Vorgang innerhalb seiner Priorität. | Queue → nach oben/nach unten | direkt: `MoveUp` und `MoveDown` |
| [`Set-SqlServerLabOperationPriority`](../../Public/BatchWorkflow.ps1) | Setzt die individuelle Priorität eines Kindvorgangs. | Queue → Priorität | direkt: `PriorityHigh`, `PriorityNormal`, `PriorityLow` |
| [`Suspend-SqlServerLabOperation`](../../Public/BatchWorkflow.ps1) | Pausiert einen wartenden Vorgang. | Queue → pausieren | direkt: `Suspend` |
| [`Resume-SqlServerLabOperation`](../../Public/BatchWorkflow.ps1) | Gibt einen pausierten Vorgang wieder frei. | Queue → fortsetzen | direkt: `Resume` |
| [`Stop-SqlServerLabOperation`](../../Public/BatchWorkflow.ps1) | Stoppt einen Vorgang an einer sicheren Grenze und kann seinen Scope bereinigen. | Queue → stoppen/Stoppen mit Cleanup | direkt: `StopCleanup` |
| [`Stop-SqlServerLabBatch`](../../Public/BatchWorkflow.ps1) | Stoppt unfertige Positionen oder baut ausdrücklich den gesamten Batch zurück. | Queue → Batch stoppen | – |
| [`Invoke-SqlServerLabScheduler`](../../Public/BatchWorkflow.ps1) | Verarbeitet die persistente Queue mit begrenzter Workerzahl bis zum Leerlauf. | Queue → Scheduler ausführen | über Core: Operation Host verarbeitet eingereihte GUI-Aktionen |

## Einstieg, Inventur und Workflow

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Invoke-SqlServerLab`](../../Public/Invoke-SqlServerLab.ps1) | Startet die interaktive PowerShell-Konsolenoberfläche. | ist das Hauptmenü | – |
| [`Get-SqlServerLabWorkflow`](../../Public/Get-SqlServerLabWorkflow.ps1) | Liefert eine verdichtete, geheimnisfreie Workflow-, Image- und Kombinationsübersicht. | – | direkt: zentrale Dashboard-Inventur und Refresh |
| [`Get-SqlServerLabAutomationPlan`](../../Public/Get-SqlServerLabAutomationPlan.ps1) | Projiziert ausgewählte bestehende öffentliche Plan-/Action-Grenzen als lokalen, versionierten und nicht ausführbaren Vertrag; keine Runtime-, Netzwerk- oder State-Aktion und keine IaC-Adapter. | – | – |
| [`Get-SqlServerLabAiScenario`](../../Public/Get-SqlServerLabAiScenario.ps1) | Löst ein hashgebundenes SQL-KI-Szenario katalogisiert oder gegen einen Run auf. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → Szenarioplan | – |
| [`Get-SqlServerLabLlamaCppModel`](../../Public/Get-SqlServerLabLlamaCppModel.ps1) | Listet kuratierte, revisions-, größen-, hash- und lizenzgebundene GGUF-Generationsmodelle. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → llama.cpp-Modelle | – |
| [`Save-SqlServerLabLlamaCppModel`](../../Public/Save-SqlServerLabLlamaCppModel.ps1) | Lädt genau das ausgewählte Katalogmodell und veröffentlicht es erst nach Größen-, SHA-256- und GGUF-Prüfung atomar unter `Lab_Base/AI/Models`. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → llama.cpp-Modelle | – |
| [`Get-SqlServerLabAiSharedGatewayServicePlan`](../../Public/Get-SqlServerLabAiSharedGatewayServicePlan.ps1) | Plant einen benutzergebundenen Host-Autostart read-only. `Auto` wählt Windows S4U beziehungsweise Linux systemd user; `WindowsS4U` und `SystemdUser` fixieren die Wahl. Fehlende ScheduledTasks-, lokale Speicher-, EFS-, Usermanager- oder Linger-Voraussetzungen erscheinen als konkrete Blocker. | Alle öffentlichen Befehle; Standard `ServiceMode=Auto`, mögliche Werte werden angezeigt | – |
| [`Test-SqlServerLabAiSharedGatewayServiceSecret`](../../Public/Test-SqlServerLabAiSharedGatewayServiceSecret.ps1) | Prüft jede Consumer-Referenz für den gebundenen aktuellen Principal ausschließlich über PowerShell SecretManagement. Das Receipt gilt fünf Minuten; Prozessvariablen zählen nicht als Neustartnachweis und die echte nichtinteraktive Service-Auflösung bleibt offene Evidence. | Alle öffentlichen Befehle; `Plan` und `ServicePlan` sind Pflichtwerte | direkt: Shared-Gateway-Panel nimmt beide gebundenen JSON-Pläne an, deaktiviert die Aktion ohne `Get-Secret`, zeigt den Grund und gibt nur die sanitisierte Receipt-Zusammenfassung aus |
| [`Get-SqlServerLabAiExternalModelPlan`](../../Public/Get-SqlServerLabAiExternalModelPlan.ps1) | Bindet einen vorhandenen OpenAI-kompatiblen HTTPS-Embedding-Endpunkt samt Runtime-, Modell- und Zertifikatshash für SQL `CREATE EXTERNAL MODEL`; der Plan führt keine Probe oder Hostmutation aus. | – | – |
| [`Get-SqlServerLabAiExternalModelSqlPlan`](../../Public/Get-SqlServerLabAiExternalModelSqlPlan.ps1) | Bindet frische Endpoint-Evidence an einen geheimnisfreien SQL-Mutations- und Cleanupplan. | – | – |
| [`Test-SqlServerLabAiExternalModelSqlPreflight`](../../Public/Test-SqlServerLabAiExternalModelSqlPreflight.ps1) | Prüft den eigenen SQL-2025-Zielscope, Datenbankidentität, Master Key, Rechte und freie Objektnamen read-only. | – | – |
| [`Invoke-SqlServerLabAiExternalModelSqlApply`](../../Public/Invoke-SqlServerLabAiExternalModelSqlApply.ps1) | Erstellt Ownership-Receipt, Credential und External Model journalisiert und transaktional; `WhatIf` bleibt mutationsfrei. | – | – |
| [`Test-SqlServerLabAiExternalModelSqlEmbedding`](../../Public/Test-SqlServerLabAiExternalModelSqlEmbedding.ps1) | Revalidiert Applied-Ownership und prüft genau ein festes SQL-Embedding; Text und Vektor werden nicht ausgegeben. | – | – |
| [`Remove-SqlServerLabAiExternalModelSql`](../../Public/Remove-SqlServerLabAiExternalModelSql.ps1) | Entfernt eigenes External Model, Credential und Ownership-Receipt receiptgebunden und transaktional; `WhatIf` bleibt mutationsfrei. | – | – |
| [`Test-SqlServerLabAiExternalModelArtifact`](../../Public/Test-SqlServerLabAiExternalModelArtifact.ps1) | Prüft ausdrücklich angegebene lokale Runtime- und Modelldateien read-only gegen die SHA-256-Werte des External-Model-Plans; bestätigt keine Prozess- oder Acceleratornutzung. | – | – |
| [`Get-SqlServerLabHyperVImageArtifact`](../../Public/Get-SqlServerLabHyperVImageArtifact.ps1) | Inventarisiert Hyper-V-Images pfadfrei mit Evaluation, Referenzen und optionaler Integritätsprüfung. | Hyper-V: Vorlagen und Slots → Images/Slots | direkt über die Workflow-Inventur: Image-Karten und Vorlagenpool |
| [`Get-SqlServerLabEvaluationWatch`](../../Public/Get-SqlServerLabEvaluationWatch.ps1) | Bewertet Windows- und SQL-Artefaktfristen sowie getrennte, persistierte Windows-Fristen registrierter RUNNING-Hyper-V-Instanzen. Für RUNNING-/STOPPED-Hyper-V-SQL-Runs projiziert er eine Frist ausschließlich aus frischer, gebundener SQL-Gast-Evidence; `-RecordEvents` dedupliziert fällige Ereignisse lokal ohne Images, Lizenzen oder Runs zu verändern. Die Fachdialoge lesen ohne diesen Schalter mit Warnfrist 30 und kritischer Frist 7 Tage. | Wartung, Aufräumen und Recovery → Windows-/SQL-Evaluationsfristen → Lesen → Eintrag auswählen | Evaluationsfristen → Fristen lesen / aktualisieren → Vorlage oder Instanz auswählen |
| [`Get-SqlServerLabRunStateUpgradePlan`](../../Public/Get-SqlServerLabRunStateUpgradePlan.ps1) | Klassifiziert einen lokalen Run-State gegen den Zielvertrag ohne State- oder Runtime-Mutation. | – | – |
| [`Get-SqlServerLabDiagnosticBundle`](../../Public/Get-SqlServerLabDiagnosticBundle.ps1) | Liefert [begrenzte, gebundene Diagnose-Evidence](../Architecture/DIAGNOSTIC_BUNDLE.md) ohne Secrets, Rohlogs, Hostwerte oder Mutation. | – | – |
| [`Invoke-SqlServerLabRunStateUpgrade`](../../Public/Invoke-SqlServerLabRunStateUpgrade.ps1) | Migriert nur einen explizit synthetischen, unversionierten Legacy-State atomar; `WhatIf` plant ohne Commit, unbekannte Versionen und Runtime-Ressourcen bleiben blockiert. | – | – |
| [`Get-SqlServerLabPortableLabImportPlan`](../../Public/Get-SqlServerLabPortableLabImportPlan.ps1) | Bindet BackupSetId- und Integritäts-Evidence eines portablen Container-Lab-Pakets read-only an einen bestehenden Docker-/Podman-Ziel-Run; die Ausführung ist nicht implementiert. | – | – |
| [`Get-SqlServerLabPortableContainerTransferExecutorPlan`](../../Public/Get-SqlServerLabPortableContainerTransferExecutorPlan.ps1) | Prüft eine ausdrückliche Mehrdatenbankauswahl oder die angeforderte `AllEligible`-Inventur zwischen zwei laufenden SQL-2025/Linux-Containerinstanzen. Der Plan ist absichtlich blockiert: sichere Inventur, HEADERONLY-/Live-CHECKSUM-/VERIFYONLY- und `RELATIONAL_CORE/1.0`-Inhaltsvergleich sowie atomarer Mehrdatenbank-Rollback fehlen noch; es gibt keine Ausführung. | – | – |
| [`Get-SqlServerLabHyperVRecoveryPointPlan`](../../Public/Get-SqlServerLabHyperVRecoveryPointPlan.ps1) | Inventarisiert bestehende, eindeutig an einen Hyper-V-Run gebundene Checkpoints ohne VM-Namen oder Hostpfade; Erstellung, Quiesce und Restore bleiben nicht implementiert. | – | – |
| [`Get-SqlServerLabHyperVResourcePreview`](../../Public/Get-SqlServerLabHyperVResourcePreview.ps1) | Zeigt registrierte Hyper-V-Location, freien Speicher und physische Klassenroots ohne Mutation. | Hyper-V-Aktionen vor UAC | über Core: Hyper-V-User-Gate und erhöhter Handoff |
| [`Get-SqlServerLabCatalog`](../../Public/Get-SqlServerLabCatalog.ps1) | Schreibt den Workflow-Katalog als persistentes, maschinenlesbares JSON-Artefakt. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Lab-Katalog prüfen | – |

## Verbindungszentrale, SSMS und CMS

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabConnectionCenter`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Liefert eine passwortfreie Endpunktübersicht für SSMS, CMS und Exporte. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Verbindungszentrale | – |
| [`Sync-SqlServerLabConnectionCenter`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Aktualisiert den Endpunktkatalog der Verbindungszentrale atomar. | Verbindungszentrale; zusätzlich nach endpunktrelevanten Lifecycle-Aktionen | – |
| [`Export-SqlServerLabSsmsRegistration`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Erzeugt einen kennwortfreien SSMS-`.regsrvr`-Export. | Verbindungszentrale → SSMS-Export | – |
| [`Export-SqlServerLabCmsSyncScript`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Erzeugt ein idempotentes CMS-Synchronisationsskript. | Verbindungszentrale → CMS-Skript | – |
| [`Initialize-SqlServerLabCms`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Erstellt nach expliziter Auswahl einen kompakten persistenten Docker-/Podman-CMS; `-LabName` benennt ihn, `-ReplaceRemovedCms` ersetzt ausschließlich eine terminal entfernte CMS-Registrierung. | Verbindungszentrale → CMS initialisieren | – |
| [`Sync-SqlServerLabCms`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Gleicht den verwalteten lokalen CMS mit dem aktuellen Katalog ab. | Verbindungszentrale; zusätzlich nach endpunktrelevanten Lifecycle-Aktionen | – |

## Reconcile und GUI-Adapter

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabReconcilePlan`](../../Public/Get-SqlServerLabReconcilePlan.ps1) | Erstellt read-only einen Lifecycle-, Ressourcen-, Storage-, SQL-, Testdatenbank- oder External-Runtime-Reconcile-Plan. | Lab-Umgebungen → Umgebung auswählen und verwalten → External Runtimes und weitere Reconcile-Flows | über Core: Browser zeigt abgeleitete Ist-/Soll-Aktionen, ruft dieses Cmdlet aber nicht direkt auf |
| [`Invoke-SqlServerLabReconcileAction`](../../Public/Invoke-SqlServerLabReconcileAction.ps1) | Führt validierte Lifecycle-, Container-, Hyper-V-, SQL- oder External-Runtime-Reconcile-Aktionen mit Recovery und `-WhatIf` aus. | Lab-Umgebungen → Umgebung auswählen und verwalten → External Runtimes und Lifecycle | über Adapter: `StartLabReconcile`, `StopLabReconcile` |
| [`Invoke-SqlServerLabWorkflowAction`](../../Public/Invoke-SqlServerLabWorkflowAction.ps1) | Übersetzt nicht interaktive UI-Aktionen in vorhandene Fachfunktionen, einschließlich eigener llama.cpp-Sitzungssicht und gebundenem Preview/Stop. | direkter CLI-Aufruf für Automatisierung möglich | zentraler Adapter unter `/api/actions`; eigene llama.cpp-Sitzungen verwenden synchron `/api/llama-sessions` im erhaltenen Modulhost |

## Manifest, Provisionierung und Lifecycle

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`New-SqlServerLabManifest`](../../Public/New-SqlServerLabManifest.ps1) | Erstellt ein Manifest schema-gesteuert interaktiv oder aus einem Objekt. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Container-Manifest | über Adapter: `CreateContainerManifest` |
| [`Test-SqlServerLabManifest`](../../Public/New-SqlServerLabManifest.ps1) | Prüft Schema, Kataloge und Runtime-Grenzen ohne Provisionierung. | im Manifest-Wizard über den gemeinsamen Core | – |
| [`New-SqlServerLab`](../../Public/New-SqlServerLab.ps1) | Erstellt eine Umgebung ad hoc oder per Manifest und kann einen detached Containerstore fortsetzen oder klonen. | Umgebungen planen und erstellen | über Adapter: `NewContainerLab`, `NewContainerLabFromManifest` |
| [`Get-SqlServerLab`](../../Public/Get-SqlServerLab.ps1) | Zeigt State, Live-Status und sanitisierte Tool-Metadaten je Provider. | Lab-Umgebungen → Umgebung auswählen und verwalten → Status | über Core: Browserstatus stammt aus `Get-SqlServerLabWorkflow`, nicht aus diesem Export |
| [`Get-SqlServerLabGeneratedSqlAccess`](../../Public/Get-SqlServerLabGeneratedSqlAccess.ps1) | Gibt generierte Hyper-V-SA-Zugangsdaten und den Connection String gezielt zurück. | Lab-Umgebungen → Umgebung auswählen und verwalten → Status/Zugang anzeigen | –; die GUI zeigt Connection Strings, aber keine gespeicherten Passwörter |
| [`Get-SqlServerLabGeneratedWindowsAccess`](../../Public/Get-SqlServerLabGeneratedWindowsAccess.ps1) | Gibt das run-lokal DPAPI-geschützte Windows-Administratorpasswort eines Slots gezielt aus. | – | – |
| [`New-SqlServerLabWindowsSlotPool`](../../Public/New-SqlServerLabWindowsSlotPool.ps1) | Erzeugt aus einer gültigen `OS_SEALED`-Baseline mehrere resumierbare Windows-Slots mit unbeaufsichtigter OOBE. | Hyper-V: Vorlagen und Slots → Windows-OS-Slot-Pool | – |
| [`Sync-SqlServerLabRuntimeState`](../../Public/Sync-SqlServerLabRuntimeState.ps1) | Gleicht Runs mit Docker, Podman und Hyper-V ab und markiert eindeutig fehlende Ressourcen als `RECOVERY_REQUIRED`. | Lab-Umgebungen → Umgebung auswählen und verwalten → mit Runtimes abgleichen | – |
| [`Start-SqlServerLab`](../../Public/Start-SqlServerLab.ps1) | Startet eine gestoppte Umgebung über den gespeicherten Provider. | Lab-Umgebungen → Umgebung auswählen und verwalten → Start | über Adapter: `StartContainerLab`; der sichtbare Browserpfad verwendet überwiegend `StartLabReconcile` |
| [`Stop-SqlServerLab`](../../Public/Stop-SqlServerLab.ps1) | Stoppt eine laufende Umgebung über den gespeicherten Provider. | Lab-Umgebungen → Umgebung auswählen und verwalten → Stopp | über Adapter: `StopContainerLab`; der sichtbare Browserpfad verwendet überwiegend `StopLabReconcile` |
| [`Restart-SqlServerLab`](../../Public/Restart-SqlServerLab.ps1) | Kombiniert Stop und Start. | Lab-Umgebungen → Umgebung auswählen und verwalten → Neustart | über Adapter: `RestartContainerLab` |
| [`Remove-SqlServerLab`](../../Public/Remove-SqlServerLab.ps1) | Entfernt einen einzelnen Run scope-validiert. | Lab-Umgebungen → Umgebung auswählen und verwalten → Entfernen | über Adapter: `RemoveContainerLab`, `RemoveHyperVLab` |
| [`Clear-SqlServerLab`](../../Public/Clear-SqlServerLab.ps1) | Bereinigt Lab-Container und/oder lokalen State. | Lab-Umgebungen → Umgebung auswählen und verwalten → alle Lab-Ressourcen aufräumen | über Adapter: `ClearAllLabs` |

## Automatisierte Testumgebungen

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`New-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironment.ps1) | Erstellt Linux-Testumgebungen mit getrennten Zufallskennwörtern und exportiert sie nach `Lab_Data`. | Geschützte Testsystem-Matrix → Testgruppe erstellen oder konfigurieren | – |
| [`Export-SqlServerLabTestEnvironment`](../../Public/TestEnvironment.ps1) | Exportiert registrierte, live geprüfte Testumgebungen als dotenv, JSON, Agenten-Prompt und Markdown. | Geschützte Testsystem-Matrix → Testgruppe konfigurieren → Export | – |
| [`Start-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironmentLifecycle.ps1) | Startet die registrierten Mitglieder als Gruppe und prüft sie bis `READY`. | Geschützte Testsystem-Matrix → Testgruppe starten | – |
| [`Stop-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironmentLifecycle.ps1) | Stoppt die registrierten Mitglieder nicht destruktiv und erneuert den Export fail-closed. | Geschützte Testsystem-Matrix → Testgruppe stoppen | – |
| [`Repair-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironment.ps1) | Gleicht Ressourcen, Health, Autostart, Windows-Aktivierung und Runtime-Namen sicher ab. | über den Testumgebungs-Workflow-Core | – |
| [`Clear-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironment.ps1) | Entfernt alle Runs der geschützten Testgruppe und deren Exporte. | Geschützte Testsystem-Matrix → Testgruppe entfernen | – |

## Maintenance und Persistent Storage

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabCleanupAudit`](../../Public/Get-SqlServerLabCleanupAudit.ps1) | Klassifiziert `Lab_Data`, Storage-Residency, Runtime-Scopes und auffällige Objekte read-only. | Wartung, Aufräumen und Recovery → Cleanup-Audit | – |
| [`Get-SqlServerLabMaintenancePlan`](../../Public/Maintenance.ps1) | Inventarisiert State und Runtime-Ressourcen read-only und trennt sichere von freizugebenden Aktionen. | – | – |
| [`Invoke-SqlServerLabMaintenance`](../../Public/Maintenance.ps1) | Führt einen revalidierten Maintenance-Plan aus und lässt fremde Ressourcen unangetastet. | – | – |
| [`Get-SqlServerLabPersistentStorageRemovalPlan`](../../Public/Get-SqlServerLabPersistentStorageRemovalPlan.ps1) | Plant Retention-, Backup-, Package- und Bindungsfolgen einer Run-Entfernung anhand stabiler Storage-IDs. | über interne Storage-Verwaltungsflüsse | direkt: Vorschau vor dem Entfernen persistenter Container-Labs |
| [`Get-SqlServerLabRetainedStoreRemovalPlan`](../../Public/Get-SqlServerLabRetainedStoreRemovalPlan.ps1) | Prüft einen eigenen detached Docker-/Podman-Store per stabiler ID read-only; keine Backup-Zusage. | Wartung, Aufräumen und Recovery → Behaltenen SQL-Speicher löschen | direkt: getrennter Preview vor endgültiger Löschung |
| [`Invoke-SqlServerLabRetainedStoreRemoval`](../../Public/Invoke-SqlServerLabRetainedStoreRemoval.ps1) | Löscht einen einzelnen geprüften Store mit Revision, PlanKey, Bestätigung und vorwärtsgerichtetem Resume; behält die ID als Tombstone. | derselbe getrennte Löschdialog | über Adapter: `RemoveRetainedStore` |
| [`Invoke-SqlServerLabPersistentStorageRemoval`](../../Public/Invoke-SqlServerLabPersistentStorageRemoval.ps1) | Führt unterstützte Retention-Policies journalisiert und wiederaufnehmbar aus; endgültige Löschung bleibt eng begrenzt. | über interne Storage-Verwaltungsflüsse | über Adapter: `ExecutePersistentStorageRemoval` |
| [`Sync-SqlServerLabPersistentStorageArtifact`](../../Public/Sync-SqlServerLabPersistentStorageArtifact.ps1) | Revalidiert und registriert genau ein Backup-Set, Datenbankpaket oder Exchange-Workspace idempotent. | – | – |
| [`Sync-SqlServerLabRunScopedContainerStore`](../../Public/Sync-SqlServerLabRunScopedContainerStore.ps1) | Registriert einen laufenden, vollständig labelgebundenen Docker-/Podman-Run-Store revisionsgeschützt. | – | – |
| [`Repair-SqlServerLabPersistentStorageCatalog`](../../Public/Repair-SqlServerLabPersistentStorageCatalog.ps1) | Katalogisiert ausschließlich einen nachweisbar eigenen, abgetrennten und UUID-labelgebundenen Docker-/Podman-Store wieder. | – | – |

## Datenbankpakete und Migrationsinventur

Ein fehlgeschlagener Container-Paketexport stellt vor Bibliotheksübergabe den
ursprünglichen SQL-Zustand bei unveränderter Quellidentität wieder her. Derselbe
Exportaufruf beendet zuerst eine ausstehende Quell-Recovery und Payload-Bereinigung.
Nach Bibliotheksübergabe bleibt die Quelle offline; eine ungeklärte
Bibliotheks-Recovery blockiert den erneuten Export ausdrücklich.

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabDatabasePackage`](../../Public/Get-SqlServerLabDatabasePackage.ps1) | Inventarisiert Datenbankpakete pfadfrei und kann deren Integrität vollständig revalidieren. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Datenbankpakete anzeigen | über Core: Paketbibliothek und Migrationsplan-Projektion in der Workflow-Inventur |
| [`Export-SqlServerLabDatabasePackage`](../../Public/Export-SqlServerLabDatabasePackage.ps1) | Veröffentlicht eine gebundene Docker-/Podman-Datenbank nach exklusivem Offline-Commit als hashgebundenes Paket. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Datenbankpaket exportieren | über Adapter: `ExportContainerDatabasePackage` |
| [`Invoke-SqlServerLabDatabasePackageAttach`](../../Public/Invoke-SqlServerLabDatabasePackageAttach.ps1) | Kopiert und hasht ein Paket im gebundenen Hyper-V-Gast, attached es im live ermittelten SQL-Default-Data-Ziel und bietet journalgebundene Recovery. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Datenbankpaket anhängen | über Adapter: `AttachHyperVDatabasePackage`, `RecoverHyperVDatabasePackageAttach` |
| [`Get-SqlServerLabDatabaseMigrationDependency`](../../Public/Get-SqlServerLabDatabaseMigrationDependency.ps1) | Inventarisiert beobachtbare Login-, Job-, Proxy-, Linked-Server- und TDE-Abhängigkeiten read-only als sanitisierte Counts. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Migrationsabhängigkeiten prüfen | über Adapter: `InspectContainerDatabaseMigrationDependencies` |
| [`Get-SqlServerLabSqlObservabilityEvidence`](../../Public/Get-SqlServerLabSqlObservabilityEvidence.ps1) | Erfasst aggregierte Server-, Datenbank-, Query-Store- und Wait-Metriken read-only ohne Endpunkt-, SQL-Text-, Namens- oder Secretprojektion. | – | – |

## Datenbanken, Skripte und SQL-KI-Szenarien

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`New-SqlServerLabDatabase`](../../Public/New-SqlServerLabDatabase.ps1) | Erstellt eine Datenbank mit konfigurierbaren Dateien und SQL-Pfaden. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Datenbank anlegen | über Adapter: `CreateContainerDatabase`; Hyper-V-Schaltfläche siehe Abweichungen |
| [`Backup-SqlServerLabDatabase`](../../Public/Backup-SqlServerLabDatabase.ps1) | Veröffentlicht ein providerneutrales Backup erst nach `CHECKSUM`, `RESTORE VERIFYONLY` und Host-Hash. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Datenbank sichern | – |
| [`Restore-SqlServerLabDatabase`](../../Public/Restore-SqlServerLabDatabase.ps1) | Stellt ein verifiziertes Bibliotheksbackup oder eine direkte `.bak`-Datei mit Trust- und Cache-Schutz wieder her. | Lab-Umgebungen → Datenbanken, Samples und Skripte → Datenbank wiederherstellen | über Adapter: `RestoreContainerLibraryBackup` |
| [`Invoke-SqlServerLabScript`](../../Public/Invoke-SqlServerLabScript.ps1) | Führt ein T-SQL-Skript mit `GO`-Batchtrennung aus. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL-Skript ausführen | über Adapter: `ExecuteContainerScript`; Hyper-V-Schaltfläche siehe Abweichungen |
| [`Invoke-SqlServerLabAiScenario`](../../Public/Invoke-SqlServerLabAiScenario.ps1) | Führt ein deklariertes, hashgebundenes SQL-KI-Szenario journalisiert mit No-op-, `WhatIf`- und Cleanup-Pfad aus. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → Szenario ausführen / Geführte KI-Demos → Vector-Core | – |
| [`Invoke-SqlServerLabAiModel`](../../Public/Invoke-SqlServerLabAiModel.ps1) | Ruft ein katalogisiertes lokales oder Cloud-Ollama-Modell mit explizitem Egress, Datenklasse und begrenztem Budget auf. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → Ollama-Modell | – |
| [`Measure-SqlServerLabAiRetrieval`](../../Public/Measure-SqlServerLabAiRetrieval.ps1) | Bewertet manuelle Retrieval-IDs oder ein hashgebundenes, tatsächlich ausgeführtes Golden-RAG deterministisch mit Recall@k, Precision@k, MRR und nDCG. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → Retrieval bewerten / Golden-RAG / Geführte KI-Demos → Retrieval-Metriken | – |
| [`Invoke-SqlServerLabAiRag`](../../Public/Invoke-SqlServerLabAiRag.ps1) | Führt lokale Ollama-Embeddings, exakte SQL-2025-Vektorsuche und quellgebundene Generierung ad hoc oder aus einem versionierten Golden-Fall aus. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → lokales SQL-RAG / Golden-RAG / Geführte KI-Demos → Golden-RAG | – |
| [`Invoke-SqlServerLabAiDiagnosticAgent`](../../Public/Invoke-SqlServerLabAiDiagnosticAgent.ps1) | Führt maximal vier katalogisierte SELECT-Diagnosen unter einer kurzlebigen Least-Privilege-Identität aus und fasst sie lokal zusammen. | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → read-only Diagnose / Geführte KI-Demos → read-only Agent | – |
| [`Test-SqlServerLabContainerTool`](../../Public/Test-SqlServerLabContainerTool.ps1) | Prüft kataloggebundenes SqlPackage per run- und scopegebundener read-only Versionsprobe. | – | – |

## Voraussetzungen, Adapter und Hilfswerkzeuge

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Test-SqlServerLabPrerequisite`](../../Private/ResourceAssessment.ps1) | Prüft Provider, RAM, Storage und Ports ohne Mutation. | über die Erstellungs- und Provider-Preflights | über Core: Provisionierungs-Preflights |
| [`Test-SqlServerLabAdapter`](../../Public/Test-SqlServerLabAdapter.ps1) | Prüft einen Project Adapter gegen Schema, Pfadgrenzen und optional eine Run-Instanz. | – | – |
| [`Install-SqlServerLabAdapter`](../../Public/Install-SqlServerLabAdapter.ps1) | Führt einen validierten Adapter-Entrypoint ohne Lifecycle-Seiteneffekt aus. | – | – |
| [`Install-SqlServerLab7Zip`](../../Public/Install-SqlServerLab7Zip.ps1) | Installiert 7-Zip nur nach explizitem Aufruf über `winget` für katalogisierte `.7z`-Backups. | Systemstatus und Einstellungen → 7-Zip | – |

## CU-, Medien- und Ressourcenverwaltung

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabCuStatus`](../../Public/Get-SqlServerLabCuStatus.ps1) | Vergleicht Microsoft-Learn-Buildtabellen read-only mit dem lokalen CU-Katalog. | Ressourcen und Downloads → aktuelle CUs prüfen | – |
| [`Save-SqlServerLabCuResource`](../../Public/Save-SqlServerLabCuResource.ps1) | Lädt einen katalogisierten Windows-CU verifiziert in den Media Root oder einen exakten Linux-MCR-Tag in Docker/Podman. | Medien, Testdaten und Speicher → CU herunterladen oder prüfen | – |
| [`Get-SqlServerLabResourcePlan`](../../Public/Get-SqlServerLabResourcePlan.ps1) | Plant fehlende Samples und Windows-/Hyper-V-External-Runtime-Medien read-only. | – | – |
| [`Save-SqlServerLabResourceSet`](../../Public/Save-SqlServerLabResourceSet.ps1) | Stellt ausgewählte Ressourcen aus Cache, Altbestand oder katalogisierter HTTP(S)-Quelle hashverifiziert bereit. | – | – |
| [`Save-SqlServerLabMediaSource`](../../Public/Save-SqlServerLabMediaSource.ps1) | Lädt ein katalogisiertes SQL-Basismedium oder einen Bootstrapper atomar nach Größen-, Hash- und Signaturprüfung. | über Hyper-V-Medien- und Image-Flows | – |

## Lizenzprofile

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Set-SqlServerLabLicenseProfile`](../../Public/LicenseProfile.ps1) | Speichert einen optionalen Product Key versions- und editionsgebunden als DPAPI-geschütztes lokales Secret. | – | – |
| [`Get-SqlServerLabLicenseProfile`](../../Public/LicenseProfile.ps1) | Listet ausschließlich geheimnisfreie Profilmetadaten und Secret-Verfügbarkeit auf. | Hyper-V-SQL-Image-Build → Lizenzprofil auswählen | – |
| [`Test-SqlServerLabLicenseProfile`](../../Public/LicenseProfile.ps1) | Prüft Metadaten, Secret und lokales Format ohne Onlineaktivierung. | – | – |
| [`Remove-SqlServerLabLicenseProfile`](../../Public/LicenseProfile.ps1) | Entfernt ein exakt benanntes lokales Profil samt geschütztem Secret. | – | – |

## Browser-GUI-Funktionsbereiche

Die Browseroberfläche enthält keine eigene Provisionierungslogik. Sie lädt die
Inventur über `Get-SqlServerLabWorkflow`, persistiert normale Aktionen als
Batch und übergibt Fachaktionen an `Invoke-SqlServerLabWorkflowAction`.

| GUI-Bereich | Verwendete öffentliche Funktionen oder Adapteraktionen |
|---|---|
| Dashboard und Vorlagen | `Get-SqlServerLabWorkflow`, `Get-SqlServerLabHyperVImageArtifact` |
| Queue und User-Gates | Batch-, Queue- und Operation-Cmdlets aus dem ersten Abschnitt |
| Container-Labs | `NewContainerLab`, `NewContainerLabFromManifest`, `StartLabReconcile`, `StopLabReconcile`, `RestartContainerLab`, `RemoveContainerLab`, `ClearAllLabs`, `RenameLab`, `SetLabResources` |
| Container-Datenbanken | `CreateContainerDatabase`, `RestoreContainerLibraryBackup`, `InstallContainerSampleDatabase`, `InstallContainerSampleDatabases`, `ExecuteContainerScript` |
| Datenbankmigration | `InspectContainerDatabaseMigrationDependencies`, `ExportContainerDatabasePackage`, `AttachHyperVDatabasePackage`, `RecoverHyperVDatabasePackageAttach` |
| Persistent Storage | Removal-Plan-Endpunkte, `RemoveRetainedStore`, `ExecutePersistentStorageRemoval`, `ReleaseHyperVPersistentData`, `ReattachHyperVPersistentData`, `CloneHyperVPersistentData` |
| Hyper-V-Labs | `NewHyperVLab`, `NewHyperVLabFromExistingVm`, `StartLabReconcile`, `StopLabReconcile`, `EnableHyperVLabPersistentData`, `InitializeHyperVLabPersistentData`, `CompleteHyperVLabSql`, `EnableHyperVLabHostSqlAccess`, `InspectHyperVLabSqlInstances`, `OpenHyperVConsole`, `RemoveHyperVLab` |
| Windows-/SQL-Images | `NewWindowsBuild`, `ConfirmWindowsInstall`, `GeneralizeWindowsBuild`, `PublishWindowsBuild`, `NewSqlBuild`, `NewSqlBuildFromBaseline`, `ConfirmSqlWindowsInstall`, `PrepareSqlImage`, `ResumeSqlImage`, `PublishSqlImage`, Cleanup-, Rename- und Remove-Aktionen |
| SQL-Abnahme | `RunSqlAcceptanceSetup`, `RunSqlAcceptanceTests` |
| Lokale Roots | `SetMediaRoot`, `SetDataRoot`, `SetTestDataRoot` |

## Festgestellte Abweichungen

### Im Root-README genannt, aber nicht exportiert

Die folgenden Funktionen sind im Quellbestand vorhanden, stehen jedoch nicht
in `FunctionsToExport` und sind deshalb nach einem normalen Modulimport keine
öffentliche PowerShell-CLI:

| Funktion | Ist-Verwendung |
|---|---|
| `Set-SqlServerLabBatchPriority` | Definition in `Public/Set-SqlServerLabBatchPriority.ps1`; aktuell weder öffentlich exportiert noch direkt in Konsole oder Browser verdrahtet. |
| `Invoke-SqlServerLabOperationProbe` | Definition in `Public/BatchWorkflow.ps1`; die Browserbrücke ruft sie absichtlich intern im Modulkontext für `Probe` auf. |

Das Root-README führt beide derzeit im Abschnitt „Öffentliche Cmdlets“. Für die
öffentliche API bleibt bis zu einer bewussten Export- oder
Dokumentationskorrektur ausschließlich `SqlServerLab.psd1` maßgeblich.

### Browseraktionen ohne akzeptierten Workflow-Backendnamen

`Ui/app.js` erzeugt aktuell zwei Aktionsnamen, die nicht im `ValidateSet` von
`Invoke-SqlServerLabWorkflowAction` enthalten sind:

| Browseraktion | Sichtbare Funktion | Aktueller Effekt |
|---|---|---|
| `CreateHyperVLabDatabase` | Datenbank in einem laufenden Hyper-V-SQL-Lab anlegen | Der Request wird vom Workflow-Adapter bei der Parameterbindung abgelehnt. |
| `ExecuteHyperVLabScript` | T-SQL-Skript in einem Hyper-V-SQL-Lab ausführen | Der Request wird vom Workflow-Adapter bei der Parameterbindung abgelehnt. |

Die entsprechenden öffentlichen Cmdlets `New-SqlServerLabDatabase` und
`Invoke-SqlServerLabScript` funktionieren weiterhin direkt über die
PowerShell-CLI. Diese Übersicht wertet die beiden Browserpfade bis zu einer
separaten Korrektur nicht als funktionierende GUI-Verwendung.

## Reproduzierbarer Abgleich

Die öffentliche Liste lässt sich ohne Modulimport aus dem Manifest lesen:

```powershell
$manifest = Import-PowerShellDataFile ./SqlServerLab.psd1
$manifest.FunctionsToExport | Sort-Object
```

Nach einem Modulimport zeigt PowerShell dieselbe öffentliche Oberfläche:

```powershell
Import-Module ./SqlServerLab.psd1 -Force
Get-Command -Module SqlServerLab | Sort-Object Name
```

Die Browserverdrahtung liegt in:

- [`Tools/Start-SqlServerLabUi.ps1`](../../Tools/Start-SqlServerLabUi.ps1)
- [`Ui/app.js`](../../Ui/app.js)
- [`Public/Invoke-SqlServerLabWorkflowAction.ps1`](../../Public/Invoke-SqlServerLabWorkflowAction.ps1)
- [`Public/Get-SqlServerLabWorkflow.ps1`](../../Public/Get-SqlServerLabWorkflow.ps1)

## Geführte CPU/RAM-Änderung (`UX-202/622`, `CNT-211` bis `CNT-214`, `HV-601` bis `HV-607`)

CLI `Set-LabResourcesInteractive` und GUI `openResourceDialog` wählen eine
konkrete gewöhnliche Lab-Instanz samt Provider. Der gemeinsame read-only
`Get-LabResourceChangePlan` zeigt gemessene Istlimits und gewünschte CPU/RAM-
Werte. Die GUI liest über `/api/resource-change`; vor Apply ist eine aktuelle
Vorschau erforderlich. Cancel und No-op rufen keinen mutierenden Executor auf.
Der instanzgebundene Container-Apply verwendet `Update-SqlServerLabContainer`
mit `ExpectedResourcePlanKey`, nur CPU und MemoryMB. Er serialisiert pro Run,
normalisiert Root-Aliase, prüft stabile Run-/Providerzustände, Schutzstatus,
offene/fremde/ungültige Journale sowie die Bindung an
Runtime-ID, Lifecycle, Istwerte, Ports, Restartpolicy und Mounts erneut. Live-Apply
und Live-Rollback adressieren die unveränderliche Container-ID; ein wiederbelegter
alter Name darf keinen Nachbarn treffen. Laufende Container
übernehmen Limits live; gestoppte bleiben gestoppt. Autostart, Ports und SQL
max memory werden nicht als zusätzliche Änderungen übergeben.

Fehlende, unbegrenzte, widersprüchliche oder nicht als NanoCPU beziehungsweise
positive Quota/Period und ganze MB nachgewiesene Limits
bleiben unbekannt und sperren Apply; gespeicherte Ersatzwerte sind kein
Istnachweis. Hyper-V bietet nur Ist-/Zielvorschau, keinen Apply: Die dauerhafte
Sollzustandsautorität für neue Werte und der journalisierte Teilfehler-/Recovery-
Vertrag bleiben unter den bestehenden HV-IDs offen. DynamicMemory und Min/Max
werden nicht verändert. Am 2026-09-28 bestanden Docker und Podman getrennt jeweils neun native
SQL-2025-Prüfungen des neuen Plan-/Workflow-Apply-/No-op-/Driftpfads samt
SQL-Probe und bestätigtem Own-Runtime-Cleanup. Das belegt Container-CPU/RAM,
keinen Hyper-V-Apply und keine weiteren Eigenschaften oder Versionspaare.

### SQL-2025-Bootstrapperquellen

Ressourcen und Downloads bietet in CLI und Browser Edit, Herkunft und Reset
für alternative Microsoft-Adressen derselben drei SQL-2025-Bootstrapper.
Die gebundene Vorschau speichert erst nach Bestätigung; kein Download,
Hashwechsel oder Installationsschritt. Weitere Medienfamilien bleiben offen.
[Bedienung](Getting_Started.md#lokale-sql-2025-bootstrapperquellen).

Der geführte eigene llama.cpp-Sitzungsstop ist unter „Host-Dienste und Modelle“
über Auswahl, Vorschau, Abbruch und bewusste Bestätigung erreichbar. Die
Verbraucher-Coverage bleibt UNKNOWN; deklarierte geschützte Verbraucher sperren
den Stop. Fremdprozesse, Start/Restart und Modellaktionen bleiben offen.
Die GUI muss im selben PowerShell-Modulhost wie der bestehende Start geöffnet
werden; sie lädt den exakten vorhandenen Modulpfad ohne Force-Reload weiter.
Details und Workflow-Aktionen: [Sitzungsstop](../Architecture/LLAMA_CPP_OWNED_RUNTIME.md).
