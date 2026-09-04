# Public/ – Exportierte Cmdlets

Dieses Verzeichnis enthält die öffentlichen PowerShell-Funktionen des Moduls. Die autoritative Exportliste steht in `SqlServerLab.psd1`.

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
| `Get-SqlServerLabHyperVImageArtifact` | `Get-SqlServerLabHyperVImageArtifact.ps1` | Pfadfreie read-only Hyper-V-Image-Registry mit Evaluation, manueller Refresh-Empfehlung, Referenzen und optionaler Integritätsprüfung |
| `Get-SqlServerLabHyperVResourcePreview` | `Get-SqlServerLabHyperVResourcePreview.ps1` | Registrierte Hyper-V-Location, freien Speicher und physische Klassenroots ohne Mutation auflösen |
| `Get-SqlServerLabCatalog` | `Get-SqlServerLabCatalog.ps1` | Workflow-Katalog als persistenter, maschinenlesbarer Katalog mit Laufzeit-Metadaten |
| `Get-SqlServerLabCleanupAudit` | `Get-SqlServerLabCleanupAudit.ps1` | Storage-Residency und Runtime-Scopes read-only klassifizieren sowie retained Objekte, unerwartete Residuen, Recovery und unverifizierbare Evidence mit stabilen Reason-Codes getrennt ausweisen |
| `Get-SqlServerLabPersistentStorageRemovalPlan` | `Get-SqlServerLabPersistentStorageRemovalPlan.ps1` | Retention-Folgen einer Run-Entfernung anhand stabiler Storage-IDs über den frisch inventarisierten, schema-validierten Removal-Plan read-only prüfen |
| `Invoke-SqlServerLabPersistentStorageRemoval` | `Invoke-SqlServerLabPersistentStorageRemoval.ps1` | Docker-/Podman-Instanzstores mit `RETAIN_INSTANCE_STORE`, `BACKUP_ON_REMOVE`, `PACKAGE_ON_REMOVE` oder `BACKUP_AND_PACKAGE` revalidiert, journalisiert und wiederaufnehmbar ausführen; `EXTERNAL_UNMANAGED` löst ausschließlich die eigene Katalogbindung. FILESTREAM, TDE und endgültiges Löschen bleiben blockiert |
| `Sync-SqlServerLabPersistentStorageArtifact` | `Sync-SqlServerLabPersistentStorageArtifact.ps1` | Genau ein vorhandenes `BackupSetId`, `DatabasePackageId` oder sicheres relatives `ExchangeWorkspaceId`-Verzeichnis revalidieren, mit `-WhatIf` mutationsfrei planen und controllergebunden idempotent registrieren |
| `Sync-SqlServerLabRunScopedContainerStore` | `Sync-SqlServerLabRunScopedContainerStore.ps1` | Einen laufenden, labelgebundenen Docker-/Podman-Run-Store aus persistierter Run-, Desired-State- und Container-Evidence mit `-WhatIf` revisionsgeschützt registrieren |
| `Get-SqlServerLabDatabasePackage` | `Get-SqlServerLabDatabasePackage.ps1` | Datenbankpakete pfadfrei per stabiler `DatabasePackageId` inventarisieren und optional mit `-VerifyIntegrity` vollständig revalidieren |
| `Invoke-SqlServerLabDatabasePackageAttach` | `Invoke-SqlServerLabDatabasePackageAttach.ps1` | Ein Paket ausschließlich per stabiler ID an einen scopegebundenen laufenden Hyper-V-SQL-Run binden, in das live ermittelte SQL-Default-Data-Ziel kopieren, im Gast hashen und attachen |
| `Get-SqlServerLabDatabaseMigrationDependency` | `Get-SqlServerLabDatabaseMigrationDependency.ps1` | SQL-seitig beobachtbare Login-, Job-, Proxy-, Linked-Server- und TDE-Abhängigkeiten direkt oder per Run-/Instanzbindung read-only als sanitisierte Kategorien und Counts inventarisieren |
| `Get-SqlServerLabConnectionCenter` | `Sync-SqlServerLabConnectionCenter.ps1` | Passwortfreie Endpunktübersicht für SSMS, CMS und Exporte |
| `Sync-SqlServerLabConnectionCenter` | `Sync-SqlServerLabConnectionCenter.ps1` | Endpunktkatalog der Verbindungszentrale atomar aktualisieren |
| `Export-SqlServerLabSsmsRegistration` | `Sync-SqlServerLabConnectionCenter.ps1` | Kennwortfreien SSMS-`.regsrvr`-Export erzeugen |
| `Export-SqlServerLabCmsSyncScript` | `Sync-SqlServerLabConnectionCenter.ps1` | Idempotentes CMS-Synchronisationsskript erzeugen |
| `Initialize-SqlServerLabCms` | `Sync-SqlServerLabConnectionCenter.ps1` | Kompakten persistenten Docker-/Podman-CMS nach expliziter Auswahl erstellen |
| `Sync-SqlServerLabCms` | `Sync-SqlServerLabConnectionCenter.ps1` | Verwalteten lokalen CMS mit dem aktuellen Katalog abgleichen |
| `Get-SqlServerLabReconcilePlan` | `Get-SqlServerLabReconcilePlan.ps1` | Read-only Lifecycle-, Hyper-V-Netzwerk-/Ressourcen-/Storage-/SQL-Konfigurations-/Port-/Testdatenbank-, Containerressourcen-/Autostart- oder resolvergebundener External-Runtime-Reconcile-Plan einschließlich additiver Hyper-V-Gastinstallation |
| `Invoke-SqlServerLabReconcileAction` | `Invoke-SqlServerLabReconcileAction.ps1` | `START`/`STOP`, eigentumsgebundene Hyper-V-Netzwerk-, Ressourcen-, Storage-, SQL- oder Testdatenbank-Aktionen, Container-Replacement sowie additive Hyper-V-External-Runtime-Aktionen mit Validierung, Recovery und `-WhatIf` ausführen |
| `Invoke-SqlServerLabWorkflowAction` | `Invoke-SqlServerLabWorkflowAction.ps1` | Nicht interaktive, UI-taugliche Hyper-V-Workflow-Aktion einschließlich getrenntem journalgebundenem Datenbankpaket-Attach-Recovery |
| `New-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema-gesteuertes Manifest interaktiv oder aus einem Objekt erstellen |
| `Test-SqlServerLabManifest` | `New-SqlServerLabManifest.ps1` | Schema, Kataloge und Runtime-Grenzen prüfen und eine mutationsfreie External-Runtime-Planvorschau liefern |
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
| `Test-SqlServerLabContainerTool` | `Test-SqlServerLabContainerTool.ps1` | Kataloggebundenes SqlPackage per Run-/Scope-gebundenem read-only Versionsprobe prüfen |
| `Restore-SqlServerLabDatabase` | `Restore-SqlServerLabDatabase.ps1` | Verifiziertes Lab_Data-Backup per stabiler `BackupSetId` oder direkte `.bak`-Datei wiederherstellen; URL-Acquisition mit SHA-256, lokalem Trust Store und inhaltsadressiertem Cache; Ziel bevorzugt per RunId aufloesen |
| `Get-SqlServerLabGeneratedSqlAccess` | `Get-SqlServerLabGeneratedSqlAccess.ps1` | Hyper-V-SQL-Laufzeit passwortgesicherte SA-Zugriffsdaten mit ConnectionString als kopierfertiges Objekt zurückgeben |
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
