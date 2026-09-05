# Funktionsübersicht für CLI und Browser-GUI

| Merkmal | Wert |
|---|---|
| Stand | 2026-09-05 |
| Autoritative Funktionsliste | [`SqlServerLab.psd1`](../../SqlServerLab.psd1) |
| Öffentliche Funktionen | 76 exportierte Cmdlets |
| Konsolenoberfläche | `Invoke-SqlServerLab` |
| Browseroberfläche | `Tools/Start-SqlServerLabUi.ps1` und `Ui/` |

## Abgrenzung

Diese Übersicht erfasst alle Funktionen, die über `FunctionsToExport` im
Modulmanifest zur öffentlichen PowerShell-CLI gehören. Jede aufgeführte
Funktion kann nach dem Modulimport direkt in PowerShell aufgerufen werden. Die
Spalte **Konsolenmenü** nennt zusätzlich die Einbindung in das interaktive
`Invoke-SqlServerLab`-Menü. Die Spalte **Browser-GUI** beschreibt die direkte
oder über `Invoke-SqlServerLabWorkflowAction` vermittelte Verwendung in der
lokalen Browseroberfläche.

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
- **–**: Keine aktuelle Einbindung in diese Oberfläche; der direkte
  PowerShell-Aufruf bleibt verfügbar.

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
| [`Get-SqlServerLabAiScenario`](../../Public/Get-SqlServerLabAiScenario.ps1) | Löst ein hashgebundenes SQL-KI-Szenario katalogisiert oder gegen einen Run auf. | – | – |
| [`Get-SqlServerLabHyperVImageArtifact`](../../Public/Get-SqlServerLabHyperVImageArtifact.ps1) | Inventarisiert Hyper-V-Images pfadfrei mit Evaluation, Referenzen und optionaler Integritätsprüfung. | Hyper-V-Infrastruktur → Images/Slots | direkt über die Workflow-Inventur: Image-Karten und Vorlagenpool |
| [`Get-SqlServerLabHyperVResourcePreview`](../../Public/Get-SqlServerLabHyperVResourcePreview.ps1) | Zeigt registrierte Hyper-V-Location, freien Speicher und physische Klassenroots ohne Mutation. | Hyper-V-Aktionen vor UAC | über Core: Hyper-V-User-Gate und erhöhter Handoff |
| [`Get-SqlServerLabCatalog`](../../Public/Get-SqlServerLabCatalog.ps1) | Schreibt den Workflow-Katalog als persistentes, maschinenlesbares JSON-Artefakt. | Datenbanken und Verbindungen → Lab-Katalog prüfen | – |

## Verbindungszentrale, SSMS und CMS

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabConnectionCenter`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Liefert eine passwortfreie Endpunktübersicht für SSMS, CMS und Exporte. | Datenbanken und Verbindungen → Verbindungszentrale | – |
| [`Sync-SqlServerLabConnectionCenter`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Aktualisiert den Endpunktkatalog der Verbindungszentrale atomar. | Verbindungszentrale; zusätzlich nach endpunktrelevanten Lifecycle-Aktionen | – |
| [`Export-SqlServerLabSsmsRegistration`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Erzeugt einen kennwortfreien SSMS-`.regsrvr`-Export. | Verbindungszentrale → SSMS-Export | – |
| [`Export-SqlServerLabCmsSyncScript`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Erzeugt ein idempotentes CMS-Synchronisationsskript. | Verbindungszentrale → CMS-Skript | – |
| [`Initialize-SqlServerLabCms`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Erstellt nach expliziter Auswahl einen kompakten persistenten Docker-/Podman-CMS. | Verbindungszentrale → CMS initialisieren | – |
| [`Sync-SqlServerLabCms`](../../Public/Sync-SqlServerLabConnectionCenter.ps1) | Gleicht den verwalteten lokalen CMS mit dem aktuellen Katalog ab. | Verbindungszentrale; zusätzlich nach endpunktrelevanten Lifecycle-Aktionen | – |

## Reconcile und GUI-Adapter

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabReconcilePlan`](../../Public/Get-SqlServerLabReconcilePlan.ps1) | Erstellt read-only einen Lifecycle-, Ressourcen-, Storage-, SQL-, Testdatenbank- oder External-Runtime-Reconcile-Plan. | Umgebungen verwalten → External Runtimes und weitere Reconcile-Flows | über Core: Browser zeigt abgeleitete Ist-/Soll-Aktionen, ruft dieses Cmdlet aber nicht direkt auf |
| [`Invoke-SqlServerLabReconcileAction`](../../Public/Invoke-SqlServerLabReconcileAction.ps1) | Führt validierte Lifecycle-, Container-, Hyper-V-, SQL- oder External-Runtime-Reconcile-Aktionen mit Recovery und `-WhatIf` aus. | Umgebungen verwalten → External Runtimes und Lifecycle | über Adapter: `StartLabReconcile`, `StopLabReconcile` |
| [`Invoke-SqlServerLabWorkflowAction`](../../Public/Invoke-SqlServerLabWorkflowAction.ps1) | Übersetzt nicht interaktive UI-Aktionen in vorhandene Fachfunktionen. | direkter CLI-Aufruf für Automatisierung möglich | direkt: zentraler Adapter aller Browseraktionen unter `/api/actions` |

## Manifest, Provisionierung und Lifecycle

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`New-SqlServerLabManifest`](../../Public/New-SqlServerLabManifest.ps1) | Erstellt ein Manifest schema-gesteuert interaktiv oder aus einem Objekt. | Datenbanken und Verbindungen → Container-Manifest | über Adapter: `CreateContainerManifest` |
| [`Test-SqlServerLabManifest`](../../Public/New-SqlServerLabManifest.ps1) | Prüft Schema, Kataloge und Runtime-Grenzen ohne Provisionierung. | im Manifest-Wizard über den gemeinsamen Core | – |
| [`New-SqlServerLab`](../../Public/New-SqlServerLab.ps1) | Erstellt eine Umgebung ad hoc oder per Manifest und kann einen detached Containerstore fortsetzen oder klonen. | Umgebungen planen und erstellen | über Adapter: `NewContainerLab`, `NewContainerLabFromManifest` |
| [`Get-SqlServerLab`](../../Public/Get-SqlServerLab.ps1) | Zeigt State, Live-Status und sanitisierte Tool-Metadaten je Provider. | Umgebungen verwalten → Status | über Core: Browserstatus stammt aus `Get-SqlServerLabWorkflow`, nicht aus diesem Export |
| [`Get-SqlServerLabGeneratedSqlAccess`](../../Public/Get-SqlServerLabGeneratedSqlAccess.ps1) | Gibt generierte Hyper-V-SA-Zugangsdaten und den Connection String gezielt zurück. | Umgebungen verwalten → Status/Zugang anzeigen | –; die GUI zeigt Connection Strings, aber keine gespeicherten Passwörter |
| [`Get-SqlServerLabGeneratedWindowsAccess`](../../Public/Get-SqlServerLabGeneratedWindowsAccess.ps1) | Gibt das run-lokal DPAPI-geschützte Windows-Administratorpasswort eines Slots gezielt aus. | – | – |
| [`New-SqlServerLabWindowsSlotPool`](../../Public/New-SqlServerLabWindowsSlotPool.ps1) | Erzeugt aus einer gültigen `OS_SEALED`-Baseline mehrere resumierbare Windows-Slots mit unbeaufsichtigter OOBE. | Hyper-V-Infrastruktur → Windows-OS-Slot-Pool | – |
| [`Sync-SqlServerLabRuntimeState`](../../Public/Sync-SqlServerLabRuntimeState.ps1) | Gleicht Runs mit Docker, Podman und Hyper-V ab und markiert eindeutig fehlende Ressourcen als `RECOVERY_REQUIRED`. | Umgebungen verwalten → mit Runtimes abgleichen | – |
| [`Start-SqlServerLab`](../../Public/Start-SqlServerLab.ps1) | Startet eine gestoppte Umgebung über den gespeicherten Provider. | Umgebungen verwalten → Start | über Adapter: `StartContainerLab`; der sichtbare Browserpfad verwendet überwiegend `StartLabReconcile` |
| [`Stop-SqlServerLab`](../../Public/Stop-SqlServerLab.ps1) | Stoppt eine laufende Umgebung über den gespeicherten Provider. | Umgebungen verwalten → Stopp | über Adapter: `StopContainerLab`; der sichtbare Browserpfad verwendet überwiegend `StopLabReconcile` |
| [`Restart-SqlServerLab`](../../Public/Restart-SqlServerLab.ps1) | Kombiniert Stop und Start. | Umgebungen verwalten → Neustart | über Adapter: `RestartContainerLab` |
| [`Remove-SqlServerLab`](../../Public/Remove-SqlServerLab.ps1) | Entfernt einen einzelnen Run scope-validiert. | Umgebungen verwalten → Entfernen | über Adapter: `RemoveContainerLab`, `RemoveHyperVLab` |
| [`Clear-SqlServerLab`](../../Public/Clear-SqlServerLab.ps1) | Bereinigt Lab-Container und/oder lokalen State. | Umgebungen verwalten → alle Lab-Ressourcen aufräumen | über Adapter: `ClearAllLabs` |

## Automatisierte Testumgebungen

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`New-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironment.ps1) | Erstellt Linux-Testumgebungen mit getrennten Zufallskennwörtern und exportiert sie nach `Lab_Data`. | Umgebungen planen und erstellen → automatisierte Testumgebung | – |
| [`Export-SqlServerLabTestEnvironment`](../../Public/TestEnvironment.ps1) | Exportiert registrierte, live geprüfte Testumgebungen als dotenv, JSON, Agenten-Prompt und Markdown. | automatisierte Testumgebung → Export | – |
| [`Start-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironmentLifecycle.ps1) | Startet die registrierten Mitglieder als Gruppe und prüft sie bis `READY`. | Umgebungen verwalten → Testumgebung starten | – |
| [`Stop-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironmentLifecycle.ps1) | Stoppt die registrierten Mitglieder nicht destruktiv und erneuert den Export fail-closed. | Umgebungen verwalten → Testumgebung stoppen | – |
| [`Repair-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironment.ps1) | Gleicht Ressourcen, Health, Autostart, Windows-Aktivierung und Runtime-Namen sicher ab. | über den Testumgebungs-Workflow-Core | – |
| [`Clear-SqlServerLabAutomatedTestEnvironment`](../../Public/TestEnvironment.ps1) | Entfernt alle Runs der geschützten Testgruppe und deren Exporte. | Umgebungen verwalten → automatisierte Testumgebungen löschen | – |

## Maintenance und Persistent Storage

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabCleanupAudit`](../../Public/Get-SqlServerLabCleanupAudit.ps1) | Klassifiziert `Lab_Data`, Storage-Residency, Runtime-Scopes und auffällige Objekte read-only. | Umgebungen verwalten → Cleanup-Audit | – |
| [`Get-SqlServerLabMaintenancePlan`](../../Public/Maintenance.ps1) | Inventarisiert State und Runtime-Ressourcen read-only und trennt sichere von freizugebenden Aktionen. | – | – |
| [`Invoke-SqlServerLabMaintenance`](../../Public/Maintenance.ps1) | Führt einen revalidierten Maintenance-Plan aus und lässt fremde Ressourcen unangetastet. | – | – |
| [`Get-SqlServerLabPersistentStorageRemovalPlan`](../../Public/Get-SqlServerLabPersistentStorageRemovalPlan.ps1) | Plant Retention-, Backup-, Package- und Bindungsfolgen einer Run-Entfernung anhand stabiler Storage-IDs. | über interne Storage-Verwaltungsflüsse | direkt: Vorschau vor dem Entfernen persistenter Container-Labs |
| [`Invoke-SqlServerLabPersistentStorageRemoval`](../../Public/Invoke-SqlServerLabPersistentStorageRemoval.ps1) | Führt unterstützte Retention-Policies journalisiert und wiederaufnehmbar aus; endgültige Löschung bleibt eng begrenzt. | über interne Storage-Verwaltungsflüsse | über Adapter: `ExecutePersistentStorageRemoval` |
| [`Sync-SqlServerLabPersistentStorageArtifact`](../../Public/Sync-SqlServerLabPersistentStorageArtifact.ps1) | Revalidiert und registriert genau ein Backup-Set, Datenbankpaket oder Exchange-Workspace idempotent. | – | – |
| [`Sync-SqlServerLabRunScopedContainerStore`](../../Public/Sync-SqlServerLabRunScopedContainerStore.ps1) | Registriert einen laufenden, vollständig labelgebundenen Docker-/Podman-Run-Store revisionsgeschützt. | – | – |

## Datenbankpakete und Migrationsinventur

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`Get-SqlServerLabDatabasePackage`](../../Public/Get-SqlServerLabDatabasePackage.ps1) | Inventarisiert Datenbankpakete pfadfrei und kann deren Integrität vollständig revalidieren. | – | über Core: Paketbibliothek und Migrationsplan-Projektion in der Workflow-Inventur |
| [`Export-SqlServerLabDatabasePackage`](../../Public/Export-SqlServerLabDatabasePackage.ps1) | Veröffentlicht eine gebundene Docker-/Podman-Datenbank nach exklusivem Offline-Commit als hashgebundenes Paket. | – | über Adapter: `ExportContainerDatabasePackage` |
| [`Invoke-SqlServerLabDatabasePackageAttach`](../../Public/Invoke-SqlServerLabDatabasePackageAttach.ps1) | Kopiert und hasht ein Paket im gebundenen Hyper-V-Gast und attached es im live ermittelten SQL-Default-Data-Ziel. | direkter CLI-Aufruf | über Adapter: `AttachHyperVDatabasePackage`, `RecoverHyperVDatabasePackageAttach` |
| [`Get-SqlServerLabDatabaseMigrationDependency`](../../Public/Get-SqlServerLabDatabaseMigrationDependency.ps1) | Inventarisiert beobachtbare Login-, Job-, Proxy-, Linked-Server- und TDE-Abhängigkeiten read-only als sanitisierte Counts. | direkter CLI-Aufruf | über Adapter: `InspectContainerDatabaseMigrationDependencies` |

## Datenbanken, Skripte und SQL-KI-Szenarien

| Cmdlet | Kurzbeschreibung | Konsolenmenü | Browser-GUI |
|---|---|---|---|
| [`New-SqlServerLabDatabase`](../../Public/New-SqlServerLabDatabase.ps1) | Erstellt eine Datenbank mit konfigurierbaren Dateien und SQL-Pfaden. | Datenbanken und Verbindungen → Datenbank anlegen | über Adapter: `CreateContainerDatabase`; Hyper-V-Schaltfläche siehe Abweichungen |
| [`Backup-SqlServerLabDatabase`](../../Public/Backup-SqlServerLabDatabase.ps1) | Veröffentlicht ein providerneutrales Backup erst nach `CHECKSUM`, `RESTORE VERIFYONLY` und Host-Hash. | – | – |
| [`Restore-SqlServerLabDatabase`](../../Public/Restore-SqlServerLabDatabase.ps1) | Stellt ein verifiziertes Bibliotheksbackup oder eine direkte `.bak`-Datei mit Trust- und Cache-Schutz wieder her. | über Sample-/Restore-Flows | über Adapter: `RestoreContainerLibraryBackup` |
| [`Invoke-SqlServerLabScript`](../../Public/Invoke-SqlServerLabScript.ps1) | Führt ein T-SQL-Skript mit `GO`-Batchtrennung aus. | Datenbanken und Verbindungen → SQL-Skript ausführen | über Adapter: `ExecuteContainerScript`; Hyper-V-Schaltfläche siehe Abweichungen |
| [`Invoke-SqlServerLabAiScenario`](../../Public/Invoke-SqlServerLabAiScenario.ps1) | Führt ein deklariertes, hashgebundenes SQL-KI-Szenario journalisiert mit No-op-, `WhatIf`- und Cleanup-Pfad aus. | – | – |
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
| [`Get-SqlServerLabCuStatus`](../../Public/Get-SqlServerLabCuStatus.ps1) | Vergleicht Microsoft-Learn-Buildtabellen read-only mit dem lokalen CU-Katalog. | Medien, Testdaten und Speicher → aktuelle CUs prüfen | – |
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
| Persistent Storage | Removal-Plan-Endpunkt, `ExecutePersistentStorageRemoval`, `ReleaseHyperVPersistentData`, `ReattachHyperVPersistentData`, `CloneHyperVPersistentData` |
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
