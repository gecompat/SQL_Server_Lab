# Public/ – Exportierte Cmdlets

`Get-SqlServerLabRunArtifactRemovalPlan` prüft genau einen modernen entfernten
Run read-only. `Invoke-SqlServerLabRunArtifactRemoval` entfernt nach gebundener
Vorschau nur zugelassene Run-Metadaten und leere Runroots; Referenzen, Retention,
Ressourcen und Recovery sperren. [Vertrag](../Documentation/User/RUN_ARTIFACT_REMOVAL.md).

Die Konsole bietet unter **Wartung, Aufräumen und Recovery → Artefakte eines
entfernten Runs** eine geführte Einzelauswahl mit öffentlicher Vorschau,
verständlichen Sperren und bestätigtem Apply/Resume. Derselbe Dialog ist über
`Invoke-SqlServerLab -Action RunArtifactRemoval` erreichbar.
Der eigene Browserdialog **Run-Artefakte prüfen** im Wartungsbereich bietet
dieselbe Vorschau und bestätigtes Apply/Resume mit serverseitigen Roots und
einer einmaligen fünf Minuten gültigen Vorschau. Der Public Core revalidiert
weiterhin; verlorene Antworten werden nicht automatisch wiederholt.

## SA-Passwort: Containererstellung

`New-SqlServerLab` prueft Containerpasswoerter vor State-/Secret-/Providerschritten:
mindestens acht, maximal 128 Zeichen und drei von vier Zeichengruppen.
`-SaPasswordMinimumLength 1..8` ist nur im engen AdHoc-Neucontainervertrag
zulaessig. Der manuelle Fachdialog erlaubt Korrektur, Abbruch oder bewusstes
Customminimum auf geeignetem Ziel. `Invoke-SqlServerLabWorkflowAction` reicht
die nur bewusst gewaehlt kuerzere Mindestlaenge fuer `NewContainerLab` weiter;
der Browser prueft vor der Jobanlage zusaetzlich die Eingabe. Getrennte
Docker-/Podman-Erststarts mit SQL2025-CU9 und Mindestlaenge drei sind
bestanden; gueltiger HTTP-Creationjob und gerenderte Browserbedienung bleiben
offen. [Vertrag](../Documentation/Architecture/SA_PASSWORD_POLICY.md).

## Container-Autostart nur vorprüfen

`Get-SqlServerLabReconcilePlan -ContainerAutoStartPreview -RunId $runId -InstanceId primary -AutoStart on -StateRoot $stateRoot` ist eine getrennte PLAN_ONLY-Vorschau der Container-Restartpolicy für moderne registrierte laufende SQL-Instanzen unter Docker/Podman. Explizite skalare on/off-Labels und Restartpolicy müssen übereinstimmen; fehlende, untypisierte oder widersprüchliche Evidence bleibt UNKNOWN/DRIFTED und gesperrt. Nur die begrenzte SQL-Loopbacktopologie und darstellbare Mounts werden akzeptiert. Der DTO zeigt feste ON/OFF- und SAME_POLICY/DIFFERENT_POLICY-Kategorien sowie Mountcounts ohne Hostwerte, native IDs oder Pfade. CanApply=false, MutationAllowed=false und leere Actions gelten auch für No-op; der opaque ObservationKey ist reine Inhaltsbindung, keine CAS-/Reservierungs-/Executorautorität. Endpoint, SQL, Backup und Hostlogin bleiben NOT_CHECKED. Ein Kontextread nutzt die bestehenden Ownership-Revalidierungen; zusätzliche eigene Inspectreads bleiben erhalten. Der geführte CLI-Einstieg „Lab-Umgebungen → Container-Autostart vorprüfen“ wählt registrierte Lab-/Instanzmetadaten und liest den bestehenden öffentlichen Core nach einem vollständigen on/off-Wunsch genau einmal. Abbruch und ungültige Eingaben vor dem Aufruf lesen kein Inspect; feste Kategorien, Mountcounts und NOT_CHECKED-Grenzen werden erst nach strikter skalarer DTO-Prüfung angezeigt. Der separate Browserdialog „Lab verwalten → Container-Autostart vorprüfen · PLAN_ONLY“ liest beim Öffnen nur registrierte Zielmetadaten des serverseitigen Roots. Ziel-/on/off-Wechsel lösen keinen Read aus; erst bewusste Vorschau ruft denselben öffentlichen Core einmal auf. Strikte Request-/DTO-Projektionen erlauben keine clientseitigen Roots, nativen IDs oder Applyautorität. UNKNOWN/DRIFTED, Mountcounts und NOT_CHECKED-Grenzen bleiben sichtbar; Schließen, Bearbeitung und neue Requests verwerfen späte Antworten, während ein bereits versandter Read fertiglaufen darf. Die spezifische native CLI-Abnahme vom 2026-10-05 auf Head `960b5452` bestand unter Docker und Podman mit je drei tatsächlichen Menü-/Dualrouter-/Public-Vorschauaufrufen (on/off/on), null frühen Cancel-/Invalid-Aufrufen, unveränderten eigenen Statebytes und je neun getrennten Ownership-/Inspectreads. Zwei bytegebundene terminale Cleanuprecords bestätigten pro Provider die Entfernung der eigenen Ressourcen und Roots; der gemeinsame Schutzvergleich hatte null Findings und null Observations. Gerenderter Browser und HTTP-Netztransport bleiben NOT_EXECUTED; der generische CLI-/Webkatalog verwendet unverändert den öffentlichen Parametervertrag. Die spezifische native Core-Abnahme vom 2026-10-05 auf Head `77fbaee` bestand unter Docker und Podman mit je fünf öffentlichen Vorschauaufrufen, unveränderten eigenen Statebytes, zwei bytegebundenen terminalen Cleanuprecords und entfernten eigenen Ressourcen/Roots. Der gemeinsame Schutzvergleich bestand mit null Findings und null Observations. Der historische Corelauf allein nahm keine CLI-/Browserdialoge oder HTTP-Netztransport ab; CPU/RAM, Portvorschau, Apply/Recovery und der vollständige Scope A bleiben unverändert bzw. separat offen.


Dieses Verzeichnis enthält die öffentlichen PowerShell-Funktionen des Moduls. Die autoritative Exportliste steht in `SqlServerLab.psd1`.

`Stop-SqlServerLab` und `Stop-SqlServerLabAutomatedTestEnvironment` prüfen
nach erfolgreichem Container-Stop zusätzlich die Hostspeicherreserve.
Bei Speicherdruck kann flüchtiger WSL-Dateicache freigegeben werden, ohne
andere Container zu stoppen. `HostMemory` liefert das getrennte Ergebnis;
`-SkipHostMemoryRelease` unterdrückt diese Wartung. Ein Restart erhält den
Cache. Grenzen und Statuswerte: [Hostspeichervertrag](../Documentation/Architecture/STOP_HOST_MEMORY.md).

`New-SqlServerLab -AllowResourceOvercommit` erlaubt gemessene übersteuerbare
Unterversorgung. Ausgeführtes, explizit übersteuertes und per `-SkipAssessment`
übersprungenes Assessment werden im lokalen Run getrennt gespeichert.
`Get-SqlServerLabReconcilePlan -TargetState` zeigt den historischen Entscheid
hostwertfrei unter `Desired.ResourceAssessment`; harte Sperren bleiben aktiv.
Die RAM-Prüfung verwendet für `provider=hyperv` den VM-Startspeicher
`hyperv.memoryStartupMB` (Default 4096 MiB), für Container das Ressourcenprofil.
Dynamisches Wachstum und Hostreserve sind nicht abgedeckt.

`Find-SqlServerLabCollation` liefert die kuratierte Auswahl für die
Instanzcollation in `New-SqlServerLab -Collation` und `instances[].collation`.
Manifest-Wizard und Konsolenformular prüfen denselben versionsgebundenen
Vertrag für SQL 2019/2022/2025. Ein vollständiger Name wird ohne Beachtung der
Groß-/Kleinschreibung gebunden und kanonisch übernommen. Unbekannte Namen
werden vor Provisionierung beziehungsweise Manifest-Speicherung abgewiesen.
Die Suche selbst prüft keinen SQL-Server. Der getrennte Containerpfad
verifiziert nach SQL-Readiness; dessen historische Evidence ist kein Nachweis
für die Browseransicht **Lab erstellen → Collations suchen**. Diese zeigt
dieselben Metadaten ohne Auswahltransfer und bleibt bei SQL `NOT_CHECKED`.

## Cmdlet-Übersicht

`Get-SqlServerLabExternalRuntimeCapability` trennt für einen expliziten
Docker-/Podman-Linux-Manifestentwurf Katalogunterstützung von optionaler
aktueller Hostbereitschaft. Standard ist `NOT_CHECKED` ohne Hostaufruf;
`-CheckProviderReadiness` liest einmal begrenzt `info`. `READY` ist keine
SQL-/Sprachabnahme oder Ausführungsfreigabe. Der vorhandene Manifestdialog
verwendet dieselbe Entscheidung; der geführte Browser nutzt denselben engen
Vertrag. Vollständiger CORE-102 und Native-Abnahmen bleiben offen.
[Vertrag und Grenzen](../Documentation/Architecture/EXTERNAL_RUNTIME_CAPABILITY.md).

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
| `Get-SqlServerLabEvaluationRefreshPlan` | `Get-SqlServerLabEvaluationRefreshPlan.ps1` | Genau eine registrierte Hyper-V-SQL-Instanz unter explizitem Lab_Data für Slotersatz, Rekonstruktion oder Migration rein informativ bewerten; keine Aktionen, Lizenzfreigabe oder Gleichwertigkeit |
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
| `Get-SqlServerLabLlamaCppStartPlan` | `Get-SqlServerLabLlamaCppStartPlan.ps1` | Reine explizite Dateivorschau für SQL-Embeddings; immer PLAN_ONLY/BLOCKED, keine Secrets oder Runtimeprüfung |
| `Start-SqlServerLabLlamaCppRuntime` | `Start-SqlServerLabLlamaCppRuntime.ps1` | Eigenen Windows-HTTPS-Embeddingserver mit benchmarkgebundener Auto-/Pinned-Auswahl oder expliziter Gerätewahl und begrenzter Lease starten |
| `Stop-SqlServerLabLlamaCppRuntime` | `Stop-SqlServerLabLlamaCppRuntime.ps1` | Ausschließlich den eigenen sitzungsgebundenen llama.cpp-Server beenden und API-Key bereinigen |
| `Get-SqlServerLabLlamaCppRuntime` | `Get-SqlServerLabLlamaCppRuntime.ps1` | Lokale Windows-/Linux-Pakete ohne Hashpflicht erkennen; FILES_ONLY und lokale Pfade, kein Laufzeitnachweis |
| `Get-SqlServerLabLlamaCppModel` | `Get-SqlServerLabLlamaCppModel.ps1` | Kuratierte Generations-GGUFs mit fest gebundener Herstellerquelle, Revision, Größe, SHA-256 und Lizenz auflisten |
| `Save-SqlServerLabLlamaCppModel` | `Save-SqlServerLabLlamaCppModel.ps1` | Ein explizit gewähltes Katalogmodell bei Bedarf unter `MediaRoot/AI/Models` laden und vor atomarer Veröffentlichung vollständig prüfen |
| `Get-SqlServerLabAiComputeInventory` | `Get-SqlServerLabAiComputeInventory.ps1` | CPU, alle vom Betriebssystem gemeldeten GPUs und NPUs read-only inventarisieren; unvollständige Geräteklassen erhalten keinen Hash |
| `Get-SqlServerLabAiRuntimeCapability` | `Get-SqlServerLabAiRuntimeCapability.ps1` | Lokale llama.cpp-Paketbinärdateien unter Lesesperre hashen und herstellergebundene Benchmark-Lanes ohne Ausführungsbehauptung ableiten |
| `Get-SqlServerLabAiComputeCandidate` | `Get-SqlServerLabAiComputeCandidate.ps1` | Aus vollständigem Inventar und strikten Runtime-Fähigkeiten alle erlaubten Einzel-, Mehrgeräte- und Mischkandidaten erzeugen |
| `Get-SqlServerLabAiComputeSelection` | `Get-SqlServerLabAiComputeSelection.ps1` | Vollständig benchmarkte geeignete CPU-/NPU-/Einzel-/Mehr-GPU-Kandidaten automatisch rangieren oder eine geeignete Kombination explizit fixieren |
| `Measure-SqlServerLabAiComputeCandidate` | `Measure-SqlServerLabAiComputeCandidate.ps1` | Einen automatisch eindeutig oder explizit auf llama.cpp-Geräteselektoren gebundenen CPU-/NPU-/Einzel-/Mehr-GPU-Kandidaten messen |
| `Measure-SqlServerLabAiComputeCandidateSet` | `Measure-SqlServerLabAiComputeCandidateSet.ps1` | Alle geeigneten Kandidaten sequenziell mit identischem Profil messen und nur bei vollständiger Coverage die schnellste Auswahl liefern |
| `Get-SqlServerLabAiSharedGatewayPlan` | `Get-SqlServerLabAiSharedGatewayPlan.ps1` | Gemeinsamen lokalen HTTPS-Gateway, Inhaltsbindungen und mehrere SQL-Verbraucher read-only planen; Ausführung bleibt sichtbar blockiert |
| `Test-SqlServerLabAiSharedGatewayPreflight` | `Test-SqlServerLabAiSharedGatewayPreflight.ps1` | Runtime, Modell, Serverzertifikat, privaten Schlüssel, CA-Kette, Gültigkeit und SAN read-only gegen den Plan prüfen |
| `Register-SqlServerLabAiSharedGatewayStorage` | `Register-SqlServerLabAiSharedGatewayStorage.ps1` | Gebundene Gatewaydateien unter einem hostweiten Mutex geschützt und atomar im gemeinsamen StateRoot registrieren; startet weder Dienst noch SQL |
| `Test-SqlServerLabAiSharedGatewayUpstream` | `Test-SqlServerLabAiSharedGatewayUpstream.ps1` | Registrierten Store revalidieren und den gebundenen Llama-v1- oder OVMS-v3-Loopback-Upstream mit einem synthetischen Embedding read-only prüfen |
| `Get-SqlServerLabAiSharedGatewayStatus` | `Get-SqlServerLabAiSharedGatewayStatus.ps1` | Registrierung, eigenen Sessionbesitz, Planabweichung, Inhaltsdrift und fremde Portbelegung read-only mit handlungsfähigem ReasonCode klassifizieren |
| `Get-SqlServerLabAiSharedGatewayServicePlan` | `Get-SqlServerLabAiSharedGatewayServicePlan.ps1` | Benutzergebundenen Host-Autostart read-only planen; Windows-S4U- und Linux-systemd/Linger-Voraussetzungen ergeben konkrete Blocker, ohne Dienstmutation |
| `Test-SqlServerLabAiSharedGatewayServiceSecret` | `Test-SqlServerLabAiSharedGatewayServiceSecret.ps1` | Benutzer-/Hostbindung vor dem Vaultzugriff revalidieren und Consumer-Referenzen ausschließlich über SecretManagement prüfen; das manipulationsgebundene Receipt gilt fünf Minuten, der nichtinteraktive Service-Logon bleibt PendingEvidence |
| `Start-SqlServerLabAiSharedGatewaySession` | `Start-SqlServerLabAiSharedGatewaySession.ps1` | Geschützten Store und Live-Upstream revalidieren und einen ownergebundenen, Loopback-only TLS-Gateway für alle geplanten Consumer starten |
| `Stop-SqlServerLabAiSharedGatewaySession` | `Stop-SqlServerLabAiSharedGatewaySession.ps1` | Ausschließlich eine Operation derselben Modulsitzung samt temporärem Zustand nach bestätigtem Prozess- und Listenerende bereinigen |
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
| `Get-SqlServerLabReconcilePlan` | `Get-SqlServerLabReconcilePlan.ps1` | Read-only Lifecycle-, Hyper-V-Netzwerk-/Ressourcen-/Storage-/SQL-Konfigurations-/Port-/Testdatenbank-, Containerressourcen-/Autostart- oder resolvergebundener External-Runtime-Reconcile-Plan einschließlich additiver Hyper-V-Gastinstallation; nicht ausführbare Komponenten-/Shared-Verbrauchervorschau über ProposedRelations ; Container-Preview mit pfadfreien Mount-/Host-Schreibzugriffszählern, Volumeeigentum NOT_CHECKED |
| `Invoke-SqlServerLabReconcileAction` | `Invoke-SqlServerLabReconcileAction.ps1` | `START`/`STOP`, eigentumsgebundene Hyper-V-Netzwerk-, Ressourcen-, Storage-, SQL- oder Testdatenbank-Aktionen, Container-Replacement sowie additive Hyper-V-External-Runtime-Aktionen mit Validierung, Recovery und `-WhatIf` ausführen |
| `Move-SqlServerLabContainerNetwork` | `Move-SqlServerLabContainerNetwork.ps1` | Konfligierendes verwaltetes Docker- oder Podman-Labnetz nach expliziter Bestätigung auf ein automatisch geprüftes Subnetz verschieben; fremde Container bleiben unverändert |
| `Invoke-SqlServerLabWorkflowAction` | `Invoke-SqlServerLabWorkflowAction.ps1` | Nicht interaktive, UI-taugliche Workflow-Aktion einschließlich Grundkonfiguration (Status, Plan, bestätigtes Apply, Providerrefresh, explizite Location-Schreibprobe und read-only Kapazitätsmomentaufnahme) und Advisory-Slotreservepolicy (GetSlotReserveState, PlanSlotReserve, ApplySlotReserve mit ConfirmSlotReserve); PlanWindowsPoolMember bindet RunId und StateRoot vor bestätigtem ApplyWindowsPoolMember; getrenntes journalgebundenes Hyper-V-Datenbankpaket-Attach-Recovery und pfad-/secretfreie Container-Paket-Exportbindung |
| `New-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema-gesteuertes Manifest interaktiv oder aus einem Objekt erstellen |
| `Test-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema, Kataloge und Runtime-Grenzen prüfen und eine mutationsfreie SQL-Lifecycle-, External-Runtime- und Sample-Planvorschau liefern |
| `New-SqlServerLab` | `New-SqlServerLab.ps1` | Neue Umgebung ad hoc oder per Manifest erstellen; detached Docker-/Podman-Instanzstore optional per stabiler ID fortsetzen oder unabhängig klonen |
| `Get-SqlServerLab` | `Get-SqlServerLab.ps1` | State, Live-Containerstatus und sanitisierte kataloggebundene Container-Tool-Metadaten je Provider anzeigen |
| `Start-SqlServerLab` | `Start-SqlServerLab.ps1` | Gestoppte Umgebung je gespeicherten Provider starten |
| `Stop-SqlServerLab` | `Stop-SqlServerLab.ps1` | Laufende Umgebung je gespeicherten Provider stoppen |
| `Restart-SqlServerLab` | `Restart-SqlServerLab.ps1` | Stop und Start kombinieren |
| `Remove-SqlServerLab` | `Remove-SqlServerLab.ps1` | Einzelnen Run scope-validiert entfernen |
| `Get-SqlServerLabExternalRuntimeCapability` | `Get-SqlServerLabExternalRuntimeCapability.ps1` | Katalogentscheidung und bewusst angeforderte Hostvoraussetzungen getrennt prüfen |
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

## Container-Portvorschau ohne Apply

`Get-SqlServerLabReconcilePlan -ContainerPortPreview -RunId $runId -InstanceId primary -Port 15433 -StateRoot $stateRoot`
liest eine moderne registrierte Docker-/Podman-Instanz mit einem aktuellen
Inspect. Der getrennte Parametersatz ist über den generischen Befehlszugang
erreichbar. Er zeigt nur Portkategorien und eine Inhaltsbindung als
`ObservationKey`; tatsächliche Portnummern, native IDs und Pfade erscheinen
nicht im Ergebnis. `CanApply` bleibt `false`, `Actions` bleiben leer. Ein
passender Istport ist `no-op`; unbekannte Bindungen, zusätzliche Port-/
Netztopologie, ungeeignete Mounts und nicht laufende Runs blockieren die
unterstützte Vorschau. Endpoint, SQL, Sicherung und Volumeeigentum bleiben
`NOT_CHECKED`. Es gibt keine Portreservierung, Journalreparatur oder Mutation.
Die CLI bietet unter **Lab-Umgebungen → SQL-Hostport vorprüfen** einen
getrennten PLAN_ONLY-Fachdialog. Er liest registrierte Metadaten eines
vorhandenen `Lab_Data`, wählt Run und Instanz und erfasst den Wunschport
1024–65535. Er ruft genau einmal denselben öffentlichen Core auf. Vor der
Anzeige validiert er DTO-Vertrag, Kategorien und fehlende Ausführungsautorität;
Fehler erscheinen als feste Meldung ohne rohe Exceptions. Nur die lokale
Wunschport-Eingabe wird angezeigt, kein erfundener Istport. `q` oder Zurück
vor dem Planaufruf ändern nichts. Der Browser bietet einen getrennten
PLAN_ONLY-Dialog im Bereich **Lab verwalten**. Seine enge read-only Route
akzeptiert weder StateRoot noch native IDs oder Ausführungsautorität; das Ziel
wird frisch aus dem aktuellen serverseitig registrierten Root bestimmt.
Öffnen und Zielwechsel lesen keine Runtime. Eine bewusste vollständige
Portvorschau ruft den öffentlichen Core einmal auf. Abbruch, Eingabe- und
Zielwechsel verwerfen späte Antworten. Spezifische native Preview-/Dialogabnahme
und gebundenes Port-Apply bleiben offen. Der bestehende `-Container`-Parametersatz
und CPU/RAM-Dialog bleiben unverändert.

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

### Geführte Bootstrapperquellen

`Invoke-SqlServerLabWorkflowAction` bietet `GetMediaOverrideState`,
`PlanMediaOverride` (`MediaSourceId`, `MediaSourceOperation`, `MediaSourceUrl`)
und `ApplyMediaOverride` (`MediaSourcePlan`, `ConfirmMediaSource`). Genau die
sechs SQL-2022/2025-Bootstrapper können eine alternative Microsoft-HTTPS-Adresse
für unveränderte katalogisierte Bytes erhalten. Die vorhandene
Preferences-Authority bindet Vorschau/Apply an Katalog und Vorgänger.
Edit/Reset beschaffen nichts; `Save-SqlServerLabMediaSource` bleibt der explizite
Downloadweg mit unveränderter Integritätsprüfung und ohne Redirectfolge bei
Overrides. [Bedienung und Grenzen](../Documentation/User/Getting_Started.md#lokale-sql-20222025-bootstrapperquellen).

### Eigene llama.cpp-Sitzung bewusst stoppen

`Invoke-SqlServerLabWorkflowAction` bietet `GetLlamaSessions`,
`PlanLlamaSessionStop -LlamaSessionOperationId` und
`StopLlamaSession -LlamaSessionPlanId -ConfirmLlamaSessionStop` innerhalb
derselben Modulsitzung. CLI und GUI zeigen UNKNOWN-Verbrauchercoverage;
PlanId ist eine fünf Minuten gültige serverseitige Auswahl. Fremdprozesse und
Modellaktionen bleiben separat offen.
Der enge Windows-GuidedStop-Nachweis vom 2026-09-30 belegt ausschließlich
synthetische native Prozessführung und bestätigten eigenen Cleanup.
Siehe [Ownership- und Evidencegrenzen](../Documentation/Architecture/LLAMA_CPP_OWNED_RUNTIME.md).

### Explizite CMS-Leseprüfung

Invoke-SqlServerLabWorkflowAction -Action GetCmsInspectionState liest die bestehende Registrierung. InspectCms -ExpectedPlanKey <serverseitiger Schlüssel> prüft ausschließlich den zuvor ausgewählten eigenen CMS. Es gibt keine Caller-Host-/Secret-/SQL-Parameter oder automatische Synchronisation. Ergebnisse folgen [CmsInspection/1.0](../Documentation/Architecture/CMS_READONLY_INSPECTION.md); Hyper-V und SSMS-/Mitgliedsverbindungen sind nicht abgenommen.

Das optionale CORE-102-Identitätsmapping verwendet den bestehenden Indexvertrag
1.1; Legacyrecords bleiben unbekannt und unverändert. Public
`Get-SqlServerLabExternalRuntimeCapability -IncludeRecordedEvidence` liefert
Version 1.1 ohne aktuelle Evidence-Aufwertung. Das Tool verlangt beide Schalter
`-IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix` und liefert
Version 1.2 ausschließlich als begrenzte historische Identitätsmatrix, ohne
Quellinventar/Modulimport. Maximal 128 Records und 256 KiB UTF-8 für die komplette
neue Antwort; Überlauf bleibt leer/UNAVAILABLE. Referenzen sind NOT_VERIFIED,
aktuelle Ausführung NOT_EXECUTED und Readiness NOT_CHECKED. Alte Public-/Browser-
und Manifestdefaults bleiben unverändert. Reale neue Producerrecords, Native-/SQL-
Abnahme und vollständige Kombinationenmatrix bleiben offen.
# Expliziter StateRoot in der Container-CI

`Get-SqlServerLab`, `Restart-SqlServerLab` und `Test-SqlServerLabPrerequisite`
akzeptieren einen optionalen expliziten `StateRoot`. Restart reicht ihn an
Beobachtung, Stop und Start weiter; Prerequisite verwendet ihn für die
gebundene Providerprüfung. Ohne Angabe bleiben die bisherigen Defaults gültig.
Der interne CI-Koordinator initialisiert einen frischen eigenen Root; ein
beliebiger Pfad aktiviert keine zusätzlichen Rechte. Im eigenen Profil werden
vorbestehende Ressourcen erhalten, Podmanmaschinen nicht gestartet und die
gemeinsame Hostspeicherwartung bei Stop übersprungen.
[Vertrag und Grenzen](../Documentation/Architecture/OWNED_HOST_CI_ISOLATION.md).
