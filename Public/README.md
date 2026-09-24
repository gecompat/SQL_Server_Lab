# Public/ – Exportierte Cmdlets

Dieses Verzeichnis enthält die öffentlichen PowerShell-Funktionen des Moduls. Die autoritative Exportliste steht in `SqlServerLab.psd1`.

`New-SqlServerLab -AllowResourceOvercommit` erlaubt gemessene übersteuerbare
Unterversorgung. Ausgeführtes, explizit übersteuertes und per `-SkipAssessment`
übersprungenes Assessment werden im lokalen Run getrennt gespeichert.
`Get-SqlServerLabReconcilePlan -TargetState` zeigt den historischen Entscheid
hostwertfrei unter `Desired.ResourceAssessment`; harte Sperren bleiben aktiv.

`Find-SqlServerLabCollation` liefert die kuratierte Auswahl für die
Instanzcollation in `New-SqlServerLab -Collation` und `instances[].collation`.
Manifest-Wizard und Konsolenformular prüfen denselben versionsgebundenen
Vertrag für SQL 2019/2022/2025. Ein vollständiger Name wird ohne Beachtung der
Groß-/Kleinschreibung gebunden und kanonisch übernommen. Unbekannte Namen
werden vor Provisionierung beziehungsweise Manifest-Speicherung abgewiesen.
Die SQL-seitige Verifikation bleibt offen.

## Cmdlet-Übersicht

| Cmdlet | Datei oder Definition | Zweck |
|---|---|---|
| `Invoke-SqlServerLab` | `Invoke-SqlServerLab.ps1` | Interaktives Menü |
| `New-SqlServerLabBatch` | `BatchWorkflow.ps1` | Einzel- oder Mengenbatch validieren, expandieren und persistent einreihen |
| `Get-SqlServerLabBatch` | `BatchWorkflow.ps1` | Batchplan, Abhängigkeiten, Fortschritt und Cleanup-Scope lesen |
| `Get-SqlServerLabQueue` | `BatchWorkflow.ps1` | Worker, Locks, Blockierungen und User-Gates lesen |
| `Get-SqlServerLabOperation` | `BatchWorkflow.ps1` | Schritte, Receipts, Events und Ergebnis eines Kindvorgangs lesen |
| `Confirm-SqlServerLabOperationUserAction` | `BatchWorkflow.ps1` | User-Gates einzeln technisch prüfen und nur erfolgreiche Positionen fortsetzen |
| `Move-SqlServerLabOperation` | `BatchWorkflow.ps1` | Wartenden Vorgang innerhalb seiner Priorität umreihen |
| `Set-SqlServerLabOperationPriority` | `BatchWorkflow.ps1` | Individuelle Priorität eines Kindvorgangs setzen |
| `Suspend-SqlServerLabOperation` | `BatchWorkflow.ps1` | Wartenden Vorgang pausieren |
| `Resume-SqlServerLabOperation` | `BatchWorkflow.ps1` | Pausierten Vorgang wieder freigeben |
| `Stop-SqlServerLabOperation` | `BatchWorkflow.ps1` | Vorgang an sicherer Grenze stoppen und optional scopegebunden bereinigen |
| `Stop-SqlServerLabBatch` | `BatchWorkflow.ps1` | Unfertige Positionen oder ausdrücklich den gesamten Batch zurückbauen |
| `Invoke-SqlServerLabScheduler` | `BatchWorkflow.ps1` | Persistente Queue mit begrenzter Workerzahl bis zum Leerlauf verarbeiten |
| `Get-SqlServerLabWorkflow` | `Get-SqlServerLabWorkflow.ps1` | Verdichtete Workflow-, Image- und Kombinationsübersicht ohne Geheimnisse |
| `Get-SqlServerLabAutomationPlan` | `Get-SqlServerLabAutomationPlan.ps1` | Versionierten, lokalen und nicht ausführbaren Plan-/Result-Vertrag für ausgewählte bestehende öffentliche Plan-/Action-Grenzen projizieren; keine Adapter, Runtime-, Netzwerk- oder State-Aktion |
| `Find-SqlServerLabCollation` | `Find-SqlServerLabCollation.ps1` | Katalogisierte SQL-Server-Collations tokenbasiert und versionsgebunden durchsuchen; die Suche verändert keine Runtime |
| `Get-SqlServerLabHyperVImageArtifact` | `Get-SqlServerLabHyperVImageArtifact.ps1` | Pfadfreie read-only Hyper-V-Image-Registry mit Evaluation, manueller Refresh-Empfehlung, Referenzen und optionaler Integritätsprüfung |
| `Get-SqlServerLabEvaluationWatch` | `Get-SqlServerLabEvaluationWatch.ps1` | Windows- und SQL-Artefaktfristen read-only bewerten; SQL-Gastfristen nur aus frischer, gebundener Evidence für registrierte Hyper-V-SQL-Runs projizieren und fällige Ereignisse optional lokal deduplizieren |
| `Invoke-SqlServerLabEvaluationWatchTrigger` | `Invoke-SqlServerLabEvaluationWatchTrigger.ps1` | Evaluation-Watch in einem explizit begrenzten lokalen Zeitintervall ausführen; keine Windows-Aufgabe, Runtime- oder Netzwerkmutation |
| `Update-SqlServerLabSqlGuestEvaluationEvidence` | `Update-SqlServerLabSqlGuestEvaluationEvidence.ps1` | SQL-2025-Hyper-V-Edition live lesen und rungebundene NO_DEADLINE-Evidence atomar erneuern; keine erfundene Ablaufzeit |
| `Get-SqlServerLabRunStateUpgradePlan` | `Get-SqlServerLabRunStateUpgradePlan.ps1` | Einen einzelnen Run-State pfad- und secretfrei gegen den Zielvertrag klassifizieren |
| `Get-SqlServerLabDiagnosticBundle` | `Get-SqlServerLabDiagnosticBundle.ps1` | [Begrenzte Diagnose-Evidence](../Documentation/Architecture/DIAGNOSTIC_BUNDLE.md) für eine eigene Instanz ohne Secrets, Rohlogs, Hostwerte oder Mutation liefern |
| `Invoke-SqlServerLabRunStateUpgrade` | `Invoke-SqlServerLabRunStateUpgrade.ps1` | Nur einen ausdrücklich synthetisch markierten, unversionierten Legacy-State atomar migrieren; unbekannte Versionen und Runtime-Ressourcen bleiben blockiert |
| `Get-SqlServerLabPortableLabImportPlan` | `Get-SqlServerLabPortableLabImportPlan.ps1` | Ein portables Container-Lab-Paket mit BackupSetId- und Integritäts-Evidence read-only an einen bestehenden Docker-/Podman-Ziel-Run binden; die Ausführung ist nicht implementiert |
| `Get-SqlServerLabPortableContainerTransferExecutorPlan` | `Get-SqlServerLabPortableContainerTransferExecutorPlan.ps1` | Ausschließlich explizite Mehrdatenbankauswahl lokal vorprüfen; bis zu vollständiger Inventur, SQL-Revalidierung und atomarem Rollback strikt blockiert |
| `Invoke-SqlServerLabPortableContainerTransfer` | `Invoke-SqlServerLabPortableContainerTransfer.ps1` | Ein read-only Bibliotheksbackup einer SQL-2025-Linux-Quelle in einen neuen eigenen Docker-/Podman-Run restaurieren; MATCH, Idempotenz und Whole-Run-Recovery |
| `Invoke-SqlServerLabPortableContainerTransferPreflight` | `Invoke-SqlServerLabPortableContainerTransferPreflight.ps1` | Backupsets einer expliziten Auswahl nur im bereits live verifizierten `persistent-backups` Bind-Mount stagen sowie mit SQL `HEADERONLY` und `VERIFYONLY` prüfen; keine Datenbank, kein Restore und kein freigegebener Transfer |
| `Get-SqlServerLabHyperVRecoveryPointPlan` | `Get-SqlServerLabHyperVRecoveryPointPlan.ps1` | Bestehende, eindeutig an einen Hyper-V-Run gebundene Checkpoints ohne VM-Namen oder Hostpfade read-only inventarisieren; Erstellung, Quiesce und Restore sind nicht implementiert |
| `Get-SqlServerLabHyperVResourcePreview` | `Get-SqlServerLabHyperVResourcePreview.ps1` | Registrierte Hyper-V-Location, freien Speicher und physische Klassenroots ohne Mutation auflösen |
| `Get-SqlServerLabCatalog` | `Get-SqlServerLabCatalog.ps1` | Workflow-Katalog als persistenter, maschinenlesbarer Katalog mit Laufzeit-Metadaten |
| `Get-SqlServerLabCleanupAudit` | `Get-SqlServerLabCleanupAudit.ps1` | `Lab_Data`, Storage-Residency und Runtime-Scopes read-only klassifizieren sowie jedes auffällige Objekt mit Typ, stabilem Grund, Löschungs-/Bewahrungsempfehlung und Handlungshinweis ausweisen |
| `Sync-SqlServerLabRuntimeState` | `Sync-SqlServerLabRuntimeState.ps1` | Gespeicherte Runs mit Docker, Podman und Hyper-V abgleichen; eindeutig fehlende gebundene Ressourcen fail-closed als `RECOVERY_REQUIRED` markieren, ohne sie zu löschen oder neu zu erzeugen |
| `Get-SqlServerLabMaintenancePlan` | `Maintenance.ps1` | State und alle vorhandenen Docker-, Podman- und Hyper-V-Ressourcen read-only inventarisieren und sichere, scopegebundene sowie explizit freizugebende Aktionen trennen |
| `Invoke-SqlServerLabMaintenance` | `Maintenance.ps1` | Einen Maintenance-Plan nach erneuter Scope-/Fingerprint-Prüfung ausführen; fremde Ressourcen bleiben unangetastet |
| `Get-SqlServerLabPersistentStorageRemovalPlan` | `Get-SqlServerLabPersistentStorageRemovalPlan.ps1` | Retention-Folgen einer Run-Entfernung anhand stabiler Storage-IDs über den frisch inventarisierten, schema-validierten Removal-Plan read-only prüfen |
| `Get-SqlServerLabRetainedStoreRemovalPlan` | `Get-SqlServerLabRetainedStoreRemovalPlan.ps1` | UUID-basierte Vorschau für einen eigenen abgetrennten Docker-/Podman-Speicher; Backup und Inhalte nicht geprüft |
| `Invoke-SqlServerLabRetainedStoreRemoval` | `Invoke-SqlServerLabRetainedStoreRemoval.ps1` | Endgültiger Delete mit Preview-Bindung, eigener Wiederaufnahme und unveränderlichem REMOVED-Tombstone |
| `Invoke-SqlServerLabPersistentStorageRemoval` | `Invoke-SqlServerLabPersistentStorageRemoval.ps1` | Docker-/Podman-Instanzstores mit `RETAIN_INSTANCE_STORE`, `BACKUP_ON_REMOVE`, `PACKAGE_ON_REMOVE` oder `BACKUP_AND_PACKAGE` revalidiert, journalisiert und wiederaufnehmbar ausführen; `EXTERNAL_UNMANAGED` löst ausschließlich die eigene Katalogbindung. `DELETE_WITH_RUN` ist nur für den registrierten rungebundenen Containerstore zweiphasig ausführbar; FILESTREAM, TDE und jede andere endgültige Löschung bleiben blockiert |
| `Sync-SqlServerLabPersistentStorageArtifact` | `Sync-SqlServerLabPersistentStorageArtifact.ps1` | Genau ein vorhandenes `BackupSetId`, `DatabasePackageId` oder sicheres relatives `ExchangeWorkspaceId`-Verzeichnis revalidieren, mit `-WhatIf` mutationsfrei planen und controllergebunden idempotent registrieren |
| `Sync-SqlServerLabRunScopedContainerStore` | `Sync-SqlServerLabRunScopedContainerStore.ps1` | Einen laufenden, labelgebundenen Docker-/Podman-Run-Store aus persistierter Run-, Desired-State- und Container-Evidence mit `-WhatIf` revisionsgeschützt registrieren |
| `Repair-SqlServerLabPersistentStorageCatalog` | `Repair-SqlServerLabPersistentStorageCatalog.ps1` | Ausschließlich einen nachweisbar eigenen, abgetrennten und UUID-labelgebundenen Docker-/Podman-Store mit unveränderter ID revisionsgeschützt wieder in den Katalog aufnehmen |
| `Get-SqlServerLabDatabasePackage` | `Get-SqlServerLabDatabasePackage.ps1` | Datenbankpakete pfadfrei per stabiler `DatabasePackageId` inventarisieren und optional mit `-VerifyIntegrity` vollständig revalidieren |
| `Export-SqlServerLabDatabasePackage` | `Export-SqlServerLabDatabasePackage.ps1` | Eine ausschließlich per Run-/Instanz-ID gebundene Docker-/Podman-Datenbank nach exklusivem Offline-Commit als hashgebundenes Paket veröffentlichen |
| `Invoke-SqlServerLabDatabasePackageAttach` | `Invoke-SqlServerLabDatabasePackageAttach.ps1` | Ein Paket ausschließlich per stabiler ID an einen scopegebundenen laufenden Hyper-V-SQL-Run binden, in das live ermittelte SQL-Default-Data-Ziel kopieren, im Gast hashen und attachen |
| `Get-SqlServerLabDatabaseMigrationDependency` | `Get-SqlServerLabDatabaseMigrationDependency.ps1` | SQL-seitig beobachtbare Login-, Job-, Proxy-, Linked-Server- und TDE-Abhängigkeiten direkt oder per Run-/Instanzbindung read-only als sanitisierte Kategorien und Counts inventarisieren |
| `Get-SqlServerLabSqlObservabilityEvidence` | `Get-SqlServerLabSqlObservabilityEvidence.ps1` | Aggregierte Server-, Datenbank-, Query-Store- und Wait-Metriken direkt oder per Run-/Instanzbindung read-only erfassen, ohne Endpunkt-, SQL-Text-, Namens- oder Secretprojektion |
| `Get-SqlServerLabAiScenario` | `Get-SqlServerLabAiScenario.ps1` | Hashgebundenes SQL-KI-Szenario katalogisiert oder gegen einen Run auflösen; Ausgabe bleibt frei von Pfaden, Endpoints und Secrets |
| `Start-SqlServerLabLlamaCppRuntime` | `Start-SqlServerLabLlamaCppRuntime.ps1` | Eigenen Windows-HTTPS-Embeddingserver mit expliziter Runtime-/Modell-/Gerätewahl und begrenzter Lease starten |
| `Stop-SqlServerLabLlamaCppRuntime` | `Stop-SqlServerLabLlamaCppRuntime.ps1` | Ausschließlich den eigenen sitzungsgebundenen llama.cpp-Server beenden und API-Key bereinigen |
| `Get-SqlServerLabLlamaCppRuntime` | `Get-SqlServerLabLlamaCppRuntime.ps1` | Lokale Windows-/Linux-Pakete ohne Hashpflicht erkennen; FILES_ONLY und lokale Pfade, kein Laufzeitnachweis |
| `Get-SqlServerLabLlamaCppModel` | `Get-SqlServerLabLlamaCppModel.ps1` | Kuratierte Generations-GGUFs mit fest gebundener Herstellerquelle, Revision, Größe, SHA-256 und Lizenz auflisten |
| `Save-SqlServerLabLlamaCppModel` | `Save-SqlServerLabLlamaCppModel.ps1` | Ein explizit gewähltes Katalogmodell bei Bedarf unter `MediaRoot/AI/Models` laden und vor atomarer Veröffentlichung vollständig prüfen |
| `Get-SqlServerLabAiComputeInventory` | `Get-SqlServerLabAiComputeInventory.ps1` | CPU, alle vom Betriebssystem gemeldeten GPUs und NPUs read-only inventarisieren; unvollständige Geräteklassen erhalten keinen Hash |
| `Get-SqlServerLabAiRuntimeCapability` | `Get-SqlServerLabAiRuntimeCapability.ps1` | Lokale llama.cpp-Paketbinärdateien unter Lesesperre hashen und herstellergebundene Benchmark-Lanes ohne Ausführungsbehauptung ableiten |
| `Get-SqlServerLabAiComputeCandidate` | `Get-SqlServerLabAiComputeCandidate.ps1` | Aus vollständigem Inventar und strikten Runtime-Fähigkeiten alle erlaubten Einzel-, Mehrgeräte- und Mischkandidaten erzeugen |
| `Get-SqlServerLabAiComputeSelection` | `Get-SqlServerLabAiComputeSelection.ps1` | Vollständig benchmarkte geeignete CPU-/NPU-/Einzel-/Mehr-GPU-Kandidaten automatisch rangieren oder eine geeignete Kombination explizit fixieren |
| `Get-SqlServerLabAiExternalModelPlan` | `Get-SqlServerLabAiExternalModelPlan.ps1` | Vorhandenen OpenAI-kompatiblen HTTPS-Embedding-Endpunkt hashgebunden für SQL `CREATE EXTERNAL MODEL` planen; keine Probe oder Hostmutation |
| `Get-SqlServerLabAiExternalModelSqlPlan` | `Get-SqlServerLabAiExternalModelSqlPlan.ps1` | Frisches Endpoint-Receipt an einen geheimnisfreien SQL-2025-Mutations-/Cleanupplan binden; keine SQL-Verbindung oder Objektmutation |
| `Test-SqlServerLabAiExternalModelSqlPreflight` | `Test-SqlServerLabAiExternalModelSqlPreflight.ps1` | Eigenen SQL-2025-Zielscope read-only auf Datenbankidentität, Master Key, Rechte und freie Objektnamen prüfen |
| `Invoke-SqlServerLabAiExternalModelSqlApply` | `Invoke-SqlServerLabAiExternalModelSqlApply.ps1` | Gebundenes Ownership-Receipt, Database Scoped Credential und External Model journalisiert und transaktional erstellen; unbekannte Ausgänge nur beobachtend fortsetzen |
| `Test-SqlServerLabAiExternalModelSqlEmbedding` | `Test-SqlServerLabAiExternalModelSqlEmbedding.ps1` | Applied-Ownership receiptgebunden revalidieren und genau ein festes SQL-Embedding ohne Text-/Vektorausgabe prüfen |
| `Remove-SqlServerLabAiExternalModelSql` | `Remove-SqlServerLabAiExternalModelSql.ps1` | Eigenes External Model, Credential und Ownership-Receipt receiptgebunden, journalisiert und transaktional entfernen |
| `Test-SqlServerLabAiExternalModelArtifact` | `Test-SqlServerLabAiExternalModelArtifact.ps1` | Lokale Runtime- und Modelldatei read-only gegen die SHA-256-Werte des Plans prüfen; kein Prozess- oder Acceleratornachweis |
| `Test-SqlServerLabAiExternalModelEndpoint` | `Test-SqlServerLabAiExternalModelEndpoint.ps1` | Geplanten HTTPS-Endpunkt mit festem synthetischem Request, echtem Zertifikatspin sowie Antwort- und Dimensionsprüfung read-only verifizieren; keine Accelerator-Attestation |
| `Test-SqlServerLabOvmsUpstreamEndpoint` | `Test-SqlServerLabOvmsUpstreamEndpoint.ps1` | Numerischen Loopback-HTTP-Upstream von OVMS mit festem `/v3/embeddings`-Request, Modell- und Dimensionsbindung read-only prüfen; kein Gateway- oder Acceleratornachweis |
| `Start-SqlServerLabOvmsHttpsGateway` | `Start-SqlServerLabOvmsHttpsGateway.ps1` | Eigenen zeitlich begrenzten Windows-Loopback-HTTPS-Gateway vor einem verifizierten OVMS-v3-Upstream starten |
| `Stop-SqlServerLabOvmsHttpsGateway` | `Stop-SqlServerLabOvmsHttpsGateway.ps1` | Ausschließlich den sitzungsgebundenen OVMS-Gateway beenden und dessen API-Key-Datei entfernen |
| `Get-SqlServerLabConnectionCenter` | `Sync-SqlServerLabConnectionCenter.ps1` | Passwortfreie Endpunktübersicht für SSMS, CMS und Exporte |
| `Sync-SqlServerLabConnectionCenter` | `Sync-SqlServerLabConnectionCenter.ps1` | Endpunktkatalog der Verbindungszentrale atomar aktualisieren |
| `Export-SqlServerLabSsmsRegistration` | `Sync-SqlServerLabConnectionCenter.ps1` | Kennwortfreien SSMS-`.regsrvr`-Export erzeugen |
| `Export-SqlServerLabCmsSyncScript` | `Sync-SqlServerLabConnectionCenter.ps1` | Idempotentes CMS-Synchronisationsskript erzeugen |
| `Initialize-SqlServerLabCms` | `Sync-SqlServerLabConnectionCenter.ps1` | Kompakten persistenten Docker-/Podman-CMS nach expliziter Auswahl erstellen |
| `Sync-SqlServerLabCms` | `Sync-SqlServerLabConnectionCenter.ps1` | Verwalteten lokalen CMS mit dem aktuellen Katalog abgleichen |
| `Get-SqlServerLabReconcilePlan` | `Get-SqlServerLabReconcilePlan.ps1` | Read-only Lifecycle-, Hyper-V-Netzwerk-/Ressourcen-/Storage-/SQL-Konfigurations-/Port-/Testdatenbank-, Containerressourcen-/Autostart- oder resolvergebundener External-Runtime-Reconcile-Plan einschließlich additiver Hyper-V-Gastinstallation |
| `Invoke-SqlServerLabReconcileAction` | `Invoke-SqlServerLabReconcileAction.ps1` | `START`/`STOP`, eigentumsgebundene Hyper-V-Netzwerk-, Ressourcen-, Storage-, SQL- oder Testdatenbank-Aktionen, Container-Replacement sowie additive Hyper-V-External-Runtime-Aktionen mit Validierung, Recovery und `-WhatIf` ausführen |
| `Move-SqlServerLabContainerNetwork` | `Move-SqlServerLabContainerNetwork.ps1` | Konfligierendes verwaltetes Docker- oder Podman-Labnetz nach expliziter Bestätigung auf ein automatisch geprüftes Subnetz verschieben; fremde Container bleiben unverändert |
| `Invoke-SqlServerLabWorkflowAction` | `Invoke-SqlServerLabWorkflowAction.ps1` | Nicht interaktive, UI-taugliche Workflow-Aktion einschließlich getrenntem journalgebundenem Hyper-V-Datenbankpaket-Attach-Recovery und pfad-/secretfreier Container-Paket-Exportbindung |
| `New-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema-gesteuertes Manifest interaktiv oder aus einem Objekt erstellen |
| `Test-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema, Kataloge und Runtime-Grenzen prüfen und eine mutationsfreie SQL-Lifecycle-, External-Runtime- und Sample-Planvorschau liefern |
| `New-SqlServerLab` | `New-SqlServerLab.ps1` | Neue Umgebung ad hoc oder per Manifest erstellen; detached Docker-/Podman-Instanzstore optional per stabiler ID fortsetzen oder unabhängig klonen |
| `Get-SqlServerLab` | `Get-SqlServerLab.ps1` | State, Live-Containerstatus und sanitisierte kataloggebundene Container-Tool-Metadaten je Provider anzeigen |
| `Start-SqlServerLab` | `Start-SqlServerLab.ps1` | Gestoppte Umgebung je gespeicherten Provider starten |
| `Stop-SqlServerLab` | `Stop-SqlServerLab.ps1` | Laufende Umgebung je gespeicherten Provider stoppen |
| `Restart-SqlServerLab` | `Restart-SqlServerLab.ps1` | Stop und Start kombinieren |
| `Remove-SqlServerLab` | `Remove-SqlServerLab.ps1` | Einzelnen Run scope-validiert entfernen |
| `Clear-SqlServerLab` | `Clear-SqlServerLab.ps1` | Lab-Container und/oder State bereinigen |
| `New-SqlServerLabDatabase` | `New-SqlServerLabDatabase.ps1` | Datenbank mit konfigurierbaren Dateien und Pfaden erstellen |
| `Backup-SqlServerLabDatabase` | `Backup-SqlServerLabDatabase.ps1` | Providerneutrales, gehashtes SQL-Backup erst nach `CHECKSUM` und `RESTORE VERIFYONLY` in der registrierten `Lab_Data`-Bibliothek veröffentlichen |
| `Invoke-SqlServerLabScript` | `Invoke-SqlServerLabScript.ps1` | T-SQL-Skript mit `GO`-Batchtrennung ausführen |
| `Invoke-SqlServerLabAiScenario` | `Invoke-SqlServerLabAiScenario.ps1` | Deklariertes SQL-KI-Szenario nach Revalidierung journalisiert ausführen; unterstützt `WhatIf`, No-op, Force und automatisches Cleanup |
| `Invoke-SqlServerLabAiModel` | `Invoke-SqlServerLabAiModel.ps1` | Katalogisiertes lokales Ollama-Modell oder die Cloud-Lane mit explizitem Egress, Datenklasse und begrenztem Budget aufrufen |
| `Measure-SqlServerLabAiRetrieval` | `Measure-SqlServerLabAiRetrieval.ps1` | Manuelle Rangfolgen oder ein hashgebundenes, tatsächlich ausgeführtes Golden-RAG deterministisch über Recall@k, Precision@k, MRR und nDCG prüfen |
| `Invoke-SqlServerLabAiRag` | `Invoke-SqlServerLabAiRag.ps1` | Lokales Ollama-RAG ad hoc oder mit versioniert gebundener Golden-Dataset-/Fallidentität über exakte SQL-2025-Vektorsuche ausführen |
| `Invoke-SqlServerLabAiPersistentRetrieval` | `Invoke-SqlServerLabAiPersistentRetrieval.ps1` | Feste synthetische Generationen oder 1–16 Caller-Dokumente auf SQL-2025-Docker/Podman persistieren, den vollständigen Caller-Bestand atomar synchronisieren, per Vektor oder Hybrid abfragen, Fixture oder Caller-Bestand explizit nach Nomic migrieren, gebunden fortsetzen und entfernen |
| `Invoke-SqlServerLabAiDiagnosticAgent` | `Invoke-SqlServerLabAiDiagnosticAgent.ps1` | Katalogisierte read-only SQL-Diagnosen unter kurzlebiger Identität lokal zusammenfassen |
| `Test-SqlServerLabContainerTool` | `Test-SqlServerLabContainerTool.ps1` | Kataloggebundenes SqlPackage per Run-/Scope-gebundenem read-only Versionsprobe prüfen |
| `Restore-SqlServerLabDatabase` | `Restore-SqlServerLabDatabase.ps1` | Verifiziertes Lab_Data-Backup per stabiler `BackupSetId` oder direkte `.bak`-Datei wiederherstellen; URL-Acquisition mit SHA-256, lokalem Trust Store und inhaltsadressiertem Cache; Ziel bevorzugt per RunId aufloesen |
| `Get-SqlServerLabGeneratedSqlAccess` | `Get-SqlServerLabGeneratedSqlAccess.ps1` | Hyper-V-SQL-Laufzeit passwortgesicherte SA-Zugriffsdaten mit ConnectionString als kopierfertiges Objekt zurückgeben |
| `Test-SqlServerLabRelationalCoreComparison` | `Test-SqlServerLabRelationalCoreComparison.ps1` | Mehrere verwaltete Docker-/Podman-Datenbankpaare nach `RELATIONAL_CORE/1.0` rein lesend und ohne Datenwerte vergleichen; ein Transfer bleibt `BLOCKED` |
| `Get-SqlServerLabGeneratedWindowsAccess` | `Get-SqlServerLabGeneratedWindowsAccess.ps1` | Das automatisch erzeugte, run-lokal DPAPI-geschützte Windows-Administratorpasswort eines ausgewählten Hyper-V-Slots gezielt ausgeben |
| `New-SqlServerLabWindowsSlotPool` | `New-SqlServerLabWindowsSlotPool.ps1` | Aus einer gültigen `OS_SEALED`-Baseline N resumierbare Windows-Slots mit abgefragtem RAM, Locale und vollständig unbeaufsichtigter OOBE erzeugen |
| `New-SqlServerLabAutomatedTestEnvironment` | `TestEnvironment.ps1` | Linux-Testumgebungen mit getrennten Zufallskennwörtern erstellen und nach Lab_Data exportieren |
| `Export-SqlServerLabTestEnvironment` | `TestEnvironment.ps1` | Registrierte Testumgebungen mit gebundener Live-Health-Prüfung als dotenv, schema-validierbares JSON, portablen Agenten-Prompt und Markdown exportieren |
| `Repair-SqlServerLabAutomatedTestEnvironment` | `TestEnvironment.ps1` | Linux-Ressourcen, Health und Autostart, Windows-Evaluationsaktivierung sowie sprechende Runtime-Namen abgleichen; Ports, Volumes und Run-IDs bleiben erhalten |
| `Start-SqlServerLabAutomatedTestEnvironment` | `TestEnvironmentLifecycle.ps1` | Registrierte Mitglieder gruppenweise starten, Windows-Lizenz und SQL-Dienste live prüfen und den erneuerten Export bis `READY` validieren |
| `Stop-SqlServerLabAutomatedTestEnvironment` | `TestEnvironmentLifecycle.ps1` | Registrierte Windows-Hyper-V-Mitglieder gruppenweise ausschalten, Hostkapazität freigeben und den Export fail-closed erneuern; keine Runs oder Registrierungen löschen |
| `Clear-SqlServerLabAutomatedTestEnvironment` | `TestEnvironment.ps1` | Alle Runs der geschützten Testgruppe gemeinsam entfernen und deren Exporte löschen |
| `Test-SqlServerLabPrerequisite` | `Private/ResourceAssessment.ps1` | Provider, RAM, Storage und Ports ohne Mutation prüfen |
| `Test-SqlServerLabAdapter` | `Test-SqlServerLabAdapter.ps1` | Project Adapter gegen Schema, Pfadgrenzen und optional eine Run-Instanz prüfen |
| `Install-SqlServerLabAdapter` | `Install-SqlServerLabAdapter.ps1` | Validierten Adapter-Entrypoint ohne Lifecycle-Seiteneffekt auf eine Instanz anwenden |
| `Install-SqlServerLab7Zip` | `Install-SqlServerLab7Zip.ps1` | 7-Zip ausschließlich auf expliziten Aufruf über `winget` für katalogisierte `.7z`-Backups installieren |
| `Get-SqlServerLabCuStatus` | `Get-SqlServerLabCuStatus.ps1` | Microsoft-Learn-Buildtabellen read-only gegen den lokalen CU-Katalog prüfen; neue Funde bleiben bis zur Hash-/Signaturbindung nicht downloadbar |
| `Save-SqlServerLabCuResource` | `Save-SqlServerLabCuResource.ps1` | Einen beliebigen katalogisierten Windows-CU mit SHA-256 und Microsoft-Authenticode in den Media Root oder den exakten Linux-MCR-Tag in Docker/Podman laden |
| `Get-SqlServerLabResourcePlan` | `Get-SqlServerLabResourcePlan.ps1` | Fehlende katalogisierte Samples und Windows-/Hyper-V-External-Runtime-Medien read-only planen und einen optionalen alten Media Root als Importquelle prüfen |
| `Get-SqlServerLabSecurityToolPlan` | `Get-SqlServerLabSecurityToolPlan.ps1` | Exakte Security-Tool-/Varianten-/Purpose-IDs und Zieltuple lokal gegen die leere Allowlist prüfen; keine Beschaffung oder Ausführungsautorität |
| `Save-SqlServerLabResourceSet` | `Save-SqlServerLabResourceSet.ps1` | Ausgewählte Ressourcen aus verifiziertem Cache, hashgeprüftem lokalem Bestand oder katalogisierter HTTP(S)-Quelle vorab bereitstellen; unterstützt `-WhatIf` |
| `Save-SqlServerLabMediaSource` | `Save-SqlServerLabMediaSource.ps1` | Ein katalogisiertes SQL- oder Windows-Server-Basismedium nach Größen-, SHA-256- und gegebenenfalls Microsoft-Signaturprüfung atomar in den Media Root laden; Community-Scans brauchen eine ausdrückliche Quarantänefreigabe |
| `Set-SqlServerLabLicenseProfile` | `LicenseProfile.ps1` | Optionalen Product Key als `SecureString` versions- und editionsgebunden im lokalen State Root DPAPI-geschützt speichern |
| `Get-SqlServerLabLicenseProfile` | `LicenseProfile.ps1` | Ausschließlich geheimnisfreie Profilmetadaten und Secret-Verfügbarkeit auflisten |
| `Test-SqlServerLabLicenseProfile` | `LicenseProfile.ps1` | Metadaten, Secret und lokales Format prüfen; keine Onlineaktivierung |
| `Remove-SqlServerLabLicenseProfile` | `LicenseProfile.ps1` | Ein exakt benanntes lokales Profil samt geschütztem Secret entfernen |

`Test-SqlServerLabPrerequisite` ist öffentlich exportiert, obwohl seine Definition im internen Resource-Assessment-Baustein liegt. Der Ablageort allein bestimmt nicht die Sichtbarkeit; maßgeblich ist `FunctionsToExport` im Modulmanifest.

## Hilfe, Discovery und Modulzuordnung

PowerShell stellt die öffentliche API über die Standardmechanismen bereit:

```powershell
Get-Command -Module SqlServerLab | Sort-Object Name
Get-Help about_SqlServerLab
Get-Help New-SqlServerLab -Full
```

`ModuleName` und `Source` ordnen jeden Export eindeutig `SqlServerLab` zu. Bei
Namenskonflikten kann ein Command modulqualifiziert aufgerufen werden, zum
Beispiel `SqlServerLab\New-SqlServerLabDatabase`.

Die verbindlichen Regeln für zugelassene Verben, spezifische Nomen,
Comment-based Help und mögliche spätere Namensmigrationen stehen im
[PowerShell Command and Help Standard](../Documentation/Standards/POWERSHELL_COMMAND_AND_HELP_STANDARD.md).

## Öffentliche und interne Verträge

Öffentlich stabil sind nur die exportierten Funktionen. Hilfsfunktionen aus `Private/` und `Providers/` dürfen in Benutzeranleitungen nicht als direkte Bedienoberfläche verwendet werden.

Insbesondere sind folgende Namen keine öffentliche API:

- `Get-LabStateRoot`
- `Get-LabRunState`
- `Get-LabSecret`
- `Get-DockerInstanceStatus`
- `Get-PodmanInstanceStatus`
- `Invoke-CleanupPlan`

## Dokumentationspflicht bei Änderungen

Bei einer neuen oder geänderten öffentlichen Funktion müssen mindestens gemeinsam geprüft werden:

1. `SqlServerLab.psd1`
2. Comment-based Help der Funktion
3. diese Übersicht
4. Root-README und Getting Started
5. `.ai/repo_map.yaml`
6. statische Vertragsprüfung
7. Integrationstest, falls Runtimeverhalten betroffen ist

## Prüfung

```powershell
Import-Module .\SqlServerLab.psd1 -Force
Get-Command -Module SqlServerLab | Sort-Object Name
.\Tests\Static\Invoke-DocumentationChecks.ps1
```
