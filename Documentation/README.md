# Dokumentationsübersicht

| Merkmal | Wert |
|---|---|
| Status | `BINDING_INDEX` |
| Stand | 2026-08-13 |

Diese Datei ist der verbindliche Dokumentationsindex. Die Root-[README](../README.md) ist der operative Einstieg. Bei Widersprüchen zwischen Planungsdokumenten und implementiertem Verhalten gelten Code, Schemas, Kataloge, Tests und die dokumentierten bekannten Grenzen als Ist-Nachweis.

## 1. Einstieg nach Zielgruppe

### Lab verwenden

1. [Installation für AnwenderInnen unter Windows](User/INSTALLATION_WINDOWS.md)
2. [Installation für AnwenderInnen unter Linux](User/INSTALLATION_LINUX.md)
3. [Externer Media Root](HowTo/MEDIA_ROOT_LAYOUT.md)
4. [Windows-Server-Baseline aus ISO mit Hyper-V erstellen](HowTo/HYPERV_WINDOWS_IMAGE_BUILD.md)
5. [Hyper-V Slot- und SQL-Workflow (OS-Slot → SQL-Slot)](HowTo/HYPERV_SLOT_SQL_WORKFLOW.md)
6. [SQL-Prepared-Images aus frischer Windows-Installation](HowTo/HYPERV_SQL_PREPARED_IMAGE.md)
7. [Persistente Daten und Evaluation-Refresh](HowTo/PERSISTENT_DATA_AND_EVALUATION_REFRESH.md)
8. [Lokale Workflow-Oberfläche](HowTo/WORKFLOW_UI.md)
9. [Getting Started](User/Getting_Started.md)
9. [Root-README](../README.md)
10. [Manifest-Schemas und Beispiele](../Schemas/README.md)
11. [Öffentliche Cmdlets](../Public/README.md)
12. [Bekannte Grenzen](Quality/KNOWN_LIMITATIONS.md)
13. [Tests](../Tests/README.md)

### Projekt weiterentwickeln

1. [Verbindlicher Agenten-Arbeitsvertrag](../AGENTS.md)
2. [Entwicklungs- und Testumgebung unter Windows](Development/DEVELOPMENT_AND_TEST_SETUP_WINDOWS.md)
3. [Entwicklungs- und Testumgebung unter Linux](Development/DEVELOPMENT_AND_TEST_SETUP_LINUX.md)
4. [KI-Projektkontext](../.ai/PROJECT_CONTEXT.md)
5. [Arbeitsregeln](../.ai/WORKING_RULES.md)
6. [Anbieterneutrale kosten- und qualitätsoptimierte Verarbeitung](../.ai/MODEL_ROUTING_POLICY.md)
7. [Kosten- und kontexteffiziente Entwicklung](Quality/COST_EFFICIENT_DEVELOPMENT.md)
8. [Maschinenlesbare Repo-Map](../.ai/repo_map.yaml)
9. [Beitragsregeln](../CONTRIBUTING.md)
10. [Lokale Validierungsstrategie](Quality/LOCAL_VALIDATION_STRATEGY.md)
11. [Bekannte Grenzen](Quality/KNOWN_LIMITATIONS.md)
12. [PowerShell Command and Help Standard](Standards/POWERSHELL_COMMAND_AND_HELP_STANDARD.md)

### Architektur und langfristige Planung verstehen

1. [SQL-Server-zentrierte Scope-Entscheidung](Architecture/SQL_SERVER_CENTRIC_SCOPE_DECISION.md)
2. [Erweiterbarer Umgebungs- und Ausführungsvertrag](Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md)
3. [Manifest- und Schnittstellenarchitektur](Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md)
4. [Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md)
5. [Gemischter Container-Provider-Lifecycle](Architecture/MIXED_PROVIDER_LIFECYCLE.md)
6. [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
7. [Vorlagenpool und automatisierte Manifeste](Architecture/TEMPLATE_POOL_AND_AUTOMATED_MANIFESTS.md)
8. [Feste isolierte Labnetze](HowTo/LAB_NETWORKS.md)
9. [Projektintegrationsvertrag](Architecture/PROJECT_INTEGRATION_CONTRACT.md)
10. [Konsolidierter Entwicklungs- und Ausführungsplan](Project_Planning/DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md)
11. [Konsolen-, Lifecycle- und Storage-Konsolidierungsplan aus der manuellen Abnahme](Project_Planning/CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md)
12. [Providerneutraler Batch-, Queue- und Resume-Workflow](Project_Planning/PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md)
13. [Master-Umsetzungsplan](Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
14. [Masterplan-Ergänzung](Project_Planning/MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md)
15. [Project-Adapter-Priorisierung](Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md)
16. [Zukünftige Anwendungsfälle](Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md)

Planungsdokumente beschreiben Zielzustände. Sie sind kein Beleg dafür, dass ein Feature bereits ausgeführt werden kann.

## 2. Aktueller Runtime-Status

| Komponente | Status | Autoritative Dateien |
|---|---|---|
| PowerShell-Modul | implementiert | `SqlServerLab.psd1`, `SqlServerLab.psm1` |
| Öffentliche API | 49 exportierte Funktionen | `SqlServerLab.psd1`, `Public/` |
| Docker | implementiert | `Providers/Docker/DockerProvider.ps1` |
| Podman | implementiert | `Providers/Podman/PodmanProvider.ps1` |
| SQL Server External Languages | Container: Java für SQL 2019, Python/R/Java für SQL 2022/2025, jeweils Docker und Podman; Hyper-V/Windows: SQL-2022 Python/R/Java nativ akzeptiert, C# für SQL 2019–2025 sichtbar `PREVIEW` | `../Catalogs/software.json`, `../Tests/Integration/Invoke-ExternalRuntimeContainerAcceptance.ps1`, `../Tests/Integration/Invoke-ExternalRuntimeHyperVAcceptance.ps1` |
| Hyper-V | Lifecycle, sealed Registry und enger Manifestpfad aus SQL-Prepared-Image; echter SQL-2025-Vertical-Slice aus frischem Windows-Slot einschließlich Storage, Ressourcenwechsel, Datenpersistenz und Cleanup akzeptiert | `Providers/HyperV/HyperVProvider.ps1`, `Private/HyperVImageRegistry.ps1`, `../Tests/Integration/Invoke-HyperVCliAcceptance.ps1` |
| Versions- und Buildauflösung | implementiert | `Catalogs/sql-server-versions.json`, `Private/VersionCatalog.ps1` |
| Sample-Katalog | typisierter Artifact-Vertrag; direkte Backups, sichere ZIP-Backups und gepinnte Einzelskripte ausführbar | `Catalogs/sample-databases.json`, `Schemas/sample-databases.schema.json`, `Private/SampleArtifactHandlers.ps1` |
| Manifestparser | implementiert | `Private/ManifestParser.ps1` |
| Resource Assessment | implementiert | `Private/ResourceAssessment.ps1` |
| State und Cleanup | implementiert | `Private/StateMachine.ps1`, `Private/CleanupEngine.ps1` |
| Gemischter Docker-/Podman-Lifecycle | implementiert | `Documentation/Architecture/MIXED_PROVIDER_LIFECYCLE.md` |
| SQL Readiness | implementiert | `Private/SqlReadiness.ps1` |
| Serverkonfiguration | teilweise implementiert | `Private/ServerConfig.ps1`, `Quality/KNOWN_LIMITATIONS.md` |
| Datenbankerstellung | implementiert | `Public/New-SqlServerLabDatabase.ps1` |
| Restore | direkte `.bak`-Dateien einschließlich Trust-, SHA-256-, Cache- und Lock-Pfad implementiert | `Public/Restore-SqlServerLabDatabase.ps1`, `Private/ArtifactResolver.ps1` |
| Skriptausführung | implementiert | `Public/Invoke-SqlServerLabScript.ps1` |
| Integrationstest | implementiert | `Tests/Integration/Invoke-SmokeTest.ps1` |
| Manifest-Builder und -Fachprüfung | implementiert, einschließlich `x-ui`-Pfadkontext und Hostvorschau | `Private/ManifestBuilder.ps1`, `Tests/Static/Invoke-ManifestBuilderChecks.ps1` |
| Unbeaufsichtigtes Manifest | implementiert für Container; externe Secret-Referenzen, SHA-256-Restore und sichere Host-Mount-Defaults | `Schemas/lab-manifest.schema.json`, `Public/New-SqlServerLab.ps1` |
| Vorlagenpool | implementiert: maximal 20 immutable OS-/SQL-Prepared-Images, rungebundener Löschschutz | `Private/HyperVImageRegistry.ps1`, `Public/Get-SqlServerLabWorkflow.ps1` |
| Statische Vertragsprüfung | implementiert | `Tests/Static/Invoke-DocumentationChecks.ps1` |

## 3. Öffentliche Cmdlets

| Cmdlet | Zweck |
|---|---|
| `Invoke-SqlServerLab` | Interaktives Menü |
| `New-SqlServerLabBatch` | Providerneutralen Einzel- oder Mengenbatch validieren, expandieren und persistent einreihen |
| `Get-SqlServerLabBatch` | Batchplan, Abhängigkeiten, Fortschritt und Cleanup-Scope lesen |
| `Get-SqlServerLabQueue` | Worker, Locks, Blockierungen und User-Gates lesen |
| `Invoke-SqlServerLabScheduler` | Persistente Queue mit begrenzter Workerzahl bis zum Leerlauf verarbeiten |
| `Get-SqlServerLabOperation` | Schritte, Receipts, Events und Ergebnis eines Kindvorgangs lesen |
| `Confirm-SqlServerLabOperationUserAction` | Ausgewählte User-Gates einzeln technisch prüfen und fortsetzen |
| `Move-SqlServerLabOperation` | Wartenden Vorgang innerhalb seiner Priorität umreihen |
| `Set-SqlServerLabOperationPriority` | Individuelle Vorgangspriorität setzen |
| `Suspend-SqlServerLabOperation` | Wartenden Vorgang pausieren |
| `Resume-SqlServerLabOperation` | Pausierten Vorgang wieder freigeben |
| `Stop-SqlServerLabOperation` | Vorgang an sicherer Grenze stoppen und optional scopegebunden bereinigen |
| `Stop-SqlServerLabBatch` | Unfertige Positionen oder ausdrücklich den gesamten Batch zurückbauen |
| `Get-SqlServerLabWorkflow` | Konsolidierte Workflow- und Imageübersicht ohne Geheimnisse |
| `Get-SqlServerLabCatalog` | Konsolidierten Lab-Katalog als JSON-Artefakt erzeugen |
| `Get-SqlServerLabCleanupAudit` | Bekannte Lab-Daten und Runtime-Ressourcen read-only auf Reste prüfen |
| `Get-SqlServerLabConnectionCenter` | Passwortfreien SQL-Endpunktkatalog für SSMS und CMS ermitteln |
| `Sync-SqlServerLabConnectionCenter` | Endpunktkatalog der Verbindungszentrale aktualisieren |
| `Export-SqlServerLabSsmsRegistration` | Kennwortfreien SSMS-`.regsrvr`-Export erzeugen |
| `Export-SqlServerLabCmsSyncScript` | Idempotentes CMS-Synchronisationsskript erzeugen |
| `Initialize-SqlServerLabCms` | Kompakten persistenten Docker-/Podman-CMS nach expliziter Auswahl erstellen |
| `Sync-SqlServerLabCms` | Verwalteten lokalen CMS mit dem Endpunktkatalog abgleichen |
| `Get-SqlServerLabReconcilePlan` | Read-only Lifecycle-, Containerressourcen-/Autostart- oder External-Runtime-Reconcile-Plan |
| `Invoke-SqlServerLabReconcileAction` | Start/Stop, journalisierter Containerressourcen-/Autostart-Reconcile oder validierter additiver SQL-2022-Container-Runtime-Refresh (mit `-WhatIf`) |
| `Invoke-SqlServerLabWorkflowAction` | Nicht interaktive UI-Aktion für einen Hyper-V-Workflow-Schritt |
| `New-SqlServerLabManifest` | Manifest schema-gesteuert erstellen |
| `Test-SqlServerLabManifest` | Manifest ohne Provisionierung prüfen |
| `New-SqlServerLab` | Umgebung ad hoc oder per Manifest erstellen |
| `Get-SqlServerLab` | State und Live-Status anzeigen |
| `Start-SqlServerLab` | Gestoppte Umgebung starten |
| `Stop-SqlServerLab` | Laufende Umgebung stoppen |
| `Restart-SqlServerLab` | Stop und Start kombinieren |
| `Remove-SqlServerLab` | Einzelnen Run entfernen |
| `Clear-SqlServerLab` | Lab-Container und/oder State bereinigen |
| `New-SqlServerLabDatabase` | Datenbank erzeugen |
| `Restore-SqlServerLabDatabase` | `.bak` aus Datei oder URL wiederherstellen |
| `Invoke-SqlServerLabScript` | T-SQL-Skript ausführen |
| `Get-SqlServerLabGeneratedSqlAccess` | Laufzeit-generierte SQL-Access-Daten inkl. SA-Passwort und ConnectionString aus einem Hyper-V-Run beziehen |
| `New-SqlServerLabAutomatedTestEnvironment` | Linux-Testumgebungen mit getrennten Zufallskennwörtern erstellen und nach Lab_Data exportieren |
| `Export-SqlServerLabTestEnvironment` | Testzugänge nach gebundener Live-Health-Prüfung als dotenv, schema-validierbares JSON, portablen Agenten-Prompt und Markdown exportieren |
| `Repair-SqlServerLabAutomatedTestEnvironment` | Ressourcen, Health, Autostart, Windows-Aktivierung und sprechende Container-/VM-Namen der registrierten Testgruppe sicher abgleichen |
| `Start-SqlServerLabAutomatedTestEnvironment` | Registrierte Docker-, Podman- und Hyper-V-Mitglieder gruppenweise starten und den Live-Export bis `READY` prüfen |
| `Stop-SqlServerLabAutomatedTestEnvironment` | Registrierte Docker-, Podman- und Hyper-V-Mitglieder nicht-destruktiv stoppen und den Live-Export fail-closed erneuern |
| `Clear-SqlServerLabAutomatedTestEnvironment` | Die geschützte Gruppe automatisierter Testumgebungen vollständig entfernen |
| `Test-SqlServerLabPrerequisite` | Provider, RAM, Storage und Ports prüfen |
| `Test-SqlServerLabAdapter` | Project Adapter gegen Schema, Pfadgrenzen und optional einen Run prüfen |
| `Install-SqlServerLabAdapter` | Validierten Adapter-Entrypoint ohne Lifecycle-Seiteneffekt anwenden |
| `Install-SqlServerLab7Zip` | 7-Zip für katalogisierte `.7z`-Backup-Payloads ausdrücklich und optional über `winget` installieren |
| `Save-SqlServerLabCuResource` | Katalogisierten Windows-CU mit SHA-256 und Microsoft-Authenticode in den Media Root oder exakten Linux-MCR-Tag in Docker/Podman laden |

Die Liste in `SqlServerLab.psd1` ist autoritativ.

## 4. Manifest und Kataloge

| Artefakt | Zweck |
|---|---|
| `Schemas/lab-manifest.schema.json` | Struktur deklarativer Labs |
| `Schemas/version-catalog.schema.json` | Struktur des SQL-Version-Katalogs |
| `Schemas/sample-databases.schema.json` | Struktur des Sample-Katalogs |
| `Catalogs/sql-server-versions.json` | Versionen, Images, Builds und Profile |
| `Catalogs/sample-databases.json` | Öffentliche Testdatenbank-Metadaten |
| `Schemas/example-*.json` | ausführbare oder ausdrücklich begrenzte Beispiele |

Für Manifestfelder gilt:

1. JSON-Schema beschreibt die zulässige Struktur.
2. `Private/ManifestParser.ps1` normalisiert und löst Referenzen auf.
3. Die zuständige Runtimefunktion führt das Feld aus.
4. [KNOWN_LIMITATIONS.md](Quality/KNOWN_LIMITATIONS.md) beschreibt Abweichungen und reservierte Felder.

Nur wenn alle Ebenen zusammenpassen, ist ein Feld als vollständig implementiert anzusehen.

## 5. Architektur

| Dokument | Inhalt |
|---|---|
| [SQL-Server-zentrierte Scope-Entscheidung](Architecture/SQL_SERVER_CENTRIC_SCOPE_DECISION.md) | SQL Server als Hauptzweck; Supporting Components nur mit SQL-Bezug |
| [Erweiterbarer Umgebungs- und Ausführungsvertrag](Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md) | Packages, Kataloge, Komponenten, Ressourcen, Workflow, Provider, Recovery und Cleanup |
| [Manifest- und Schnittstellenarchitektur](Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md) | langfristiger deklarativer Vertrag und Auflösungsreihenfolge |
| [Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md) | Zielvertrag für Artifact Handler, Trust/Hash, Mehrfachauswahl, Pfadführung und Baselines; direkte Backups, sichere ZIP-Backups, Einzelskripte, Trust-Pfad und Mehrfachauswahl sind implementiert |
| [Gemischter Container-Provider-Lifecycle](Architecture/MIXED_PROVIDER_LIFECYCLE.md) | implementierter Docker-/Podman-Lifecycle mit ProviderSubRuns, Start-Rollback und providergebundenem Cleanup |
| [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md) | verbindlicher Zielvertrag für Hyper-V, sealed Images, Netzwerke, Software, Reconcile und Refresh; noch kein Runtime-Nachweis |
| [Vorlagenpool und automatisierte Manifeste](Architecture/TEMPLATE_POOL_AND_AUTOMATED_MANIFESTS.md) | implementierter Standardpfad, Eigentumsgrenzen und aktueller Hyper-V-Umfang |
| [Projektintegrationsvertrag](Architecture/PROJECT_INTEGRATION_CONTRACT.md) | Anbindung konsumierender Projekte |
| [Zukünftige Anwendungsfälle](Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md) | Roadmap und Grenzen für Supporting Components |

## 6. Qualität, Privacy und Sicherheit

| Dokument | Inhalt |
|---|---|
| [Privacy- und Artefaktsicherheitsvertrag](Quality/PRIVACY_AND_ARTIFACT_SECURITY.md) | Trennung lokaler Runtimewerte und versionierter Artefakte |
| [Lokale Validierungsstrategie](Quality/LOCAL_VALIDATION_STRATEGY.md) | reproduzierbare lokale Prüfungen |
| [Bekannte Grenzen](Quality/KNOWN_LIMITATIONS.md) | verbindliche Einschränkungen des aktuellen Runtimepfads |
| [Security Policy](../SECURITY.md) | Meldung sicherheitsrelevanter Probleme ohne Secrets oder reale Daten |

## 7. Migration und Quell-Snapshots

| Dokument oder Pfad | Inhalt |
|---|---|
| [Migrationsinventar](Migration/MIGRATION_INVENTORY_AND_DECISIONS.md) | Übernahme- und Ablöseentscheidungen |
| `_QuellRepo/SQL_Server_Analyze/` | eingefrorener Quell-Snapshot ohne eigenes `.git` |
| `_QuellRepo/SQL_PerformanceSchulung/` | eingefrorener Quell-Snapshot ohne eigenes `.git` |

Inhalte unter `_QuellRepo/` sind Referenzmaterial. Sie definieren nicht automatisch die öffentliche API von `SQL_Server_Lab`.

## 8. Standards

| Dokument | Inhalt |
|---|---|
| [Sprach-, Übersetzungs- und Schreibstandard](Standards/LANGUAGE_TRANSLATION_AND_STYLE_STANDARD.md) | Deutsch als Dokumentationssprache; etablierte englische Fachbegriffe bleiben erhalten |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Coding-, Test-, Doku- und Pull-Request-Regeln |
| [CHANGELOG.md](../CHANGELOG.md) | nachvollziehbare Änderungen am öffentlichen Vertrag |

## 9. Forschung

| Dokument | Inhalt |
|---|---|
| [Analyse bestehender Lab- und Orchestrierungsprojekte](Research/EXISTING_LAB_AND_ORCHESTRATION_PROJECTS_REVIEW.md) | Musterquellen wie AutomatedLab, MSLab und Compose |

Forschungsunterlagen dienen der Auswahl von Mustern. Sie sind keine automatische Implementierungsentscheidung.

## 10. KI-Weiterarbeit

Eine generische KI soll den Projektstand in dieser Reihenfolge ermitteln:

1. `AGENTS.md`
2. `.ai/PROJECT_CONTEXT.md`
3. `.ai/WORKING_RULES.md`
4. `.ai/repo_map.yaml`
5. `.ai/MODEL_ROUTING_POLICY.md`
6. `Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`
7. `SqlServerLab.psd1`
8. `Schemas/` und `Catalogs/`
9. `Public/`, `Private/`, `Providers/`
10. `Tests/`
11. `Documentation/Quality/KNOWN_LIMITATIONS.md`
12. Planungsdokumente erst danach

Bei jeder Änderung müssen Code, Beispiel, Dokumentation und Test gemeinsam geprüft werden. Die statische Prüfung ist über folgenden Befehl ausführbar:

```powershell
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
```
