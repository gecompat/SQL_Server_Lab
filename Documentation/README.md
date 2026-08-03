# Dokumentationsübersicht

| Merkmal | Wert |
|---|---|
| Status | `BINDING_INDEX` |
| Stand | 2026-08-03 |

Diese Datei ist der verbindliche Dokumentationsindex. Die Root-[README](../README.md) ist der operative Einstieg. Bei Widersprüchen zwischen Planungsdokumenten und implementiertem Verhalten gelten Code, Schemas, Kataloge, Tests und die dokumentierten bekannten Grenzen als Ist-Nachweis.

## 1. Einstieg nach Zielgruppe

### Lab verwenden

1. [Installation für AnwenderInnen unter Windows](User/INSTALLATION_WINDOWS.md)
2. [Installation für AnwenderInnen unter Linux](User/INSTALLATION_LINUX.md)
3. [Externer Media Root](HowTo/MEDIA_ROOT_LAYOUT.md)
4. [Getting Started](User/Getting_Started.md)
5. [Root-README](../README.md)
6. [Manifest-Schemas und Beispiele](../Schemas/README.md)
7. [Öffentliche Cmdlets](../Public/README.md)
8. [Bekannte Grenzen](Quality/KNOWN_LIMITATIONS.md)
9. [Tests](../Tests/README.md)

### Projekt weiterentwickeln

1. [Entwicklungs- und Testumgebung unter Windows](Development/DEVELOPMENT_AND_TEST_SETUP_WINDOWS.md)
2. [Entwicklungs- und Testumgebung unter Linux](Development/DEVELOPMENT_AND_TEST_SETUP_LINUX.md)
3. [KI-Projektkontext](../.ai/PROJECT_CONTEXT.md)
4. [Arbeitsregeln](../.ai/WORKING_RULES.md)
5. [Maschinenlesbare Repo-Map](../.ai/repo_map.yaml)
6. [Beitragsregeln](../CONTRIBUTING.md)
7. [Lokale Validierungsstrategie](Quality/LOCAL_VALIDATION_STRATEGY.md)
8. [Bekannte Grenzen](Quality/KNOWN_LIMITATIONS.md)
9. [PowerShell Command and Help Standard](Standards/POWERSHELL_COMMAND_AND_HELP_STANDARD.md)

### Architektur und langfristige Planung verstehen

1. [SQL-Server-zentrierte Scope-Entscheidung](Architecture/SQL_SERVER_CENTRIC_SCOPE_DECISION.md)
2. [Erweiterbarer Umgebungs- und Ausführungsvertrag](Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md)
3. [Manifest- und Schnittstellenarchitektur](Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md)
4. [Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md)
5. [Gemischter Container-Provider-Lifecycle](Architecture/MIXED_PROVIDER_LIFECYCLE.md)
6. [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
7. [Projektintegrationsvertrag](Architecture/PROJECT_INTEGRATION_CONTRACT.md)
8. [Master-Umsetzungsplan](Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
9. [Masterplan-Ergänzung](Project_Planning/MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md)
10. [Project-Adapter-Priorisierung](Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md)
11. [Zukünftige Anwendungsfälle](Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md)

Planungsdokumente beschreiben Zielzustände. Sie sind kein Beleg dafür, dass ein Feature bereits ausgeführt werden kann.

## 2. Aktueller Runtime-Status

| Komponente | Status | Autoritative Dateien |
|---|---|---|
| PowerShell-Modul | implementiert | `SqlServerLab.psd1`, `SqlServerLab.psm1` |
| Öffentliche API | 14 exportierte Funktionen | `SqlServerLab.psd1`, `Public/` |
| Docker | implementiert | `Providers/Docker/DockerProvider.ps1` |
| Podman | implementiert | `Providers/Podman/PodmanProvider.ps1` |
| Hyper-V | Lifecycle-Grundlage; keine SQL-Provisionierung | `Providers/HyperV/HyperVProvider.ps1`, `Providers/HyperV/README.md` |
| Versions- und Buildauflösung | implementiert | `Catalogs/sql-server-versions.json`, `Private/VersionCatalog.ps1` |
| Sample-Katalog | typisierter Artifact-Vertrag implementiert; Runtime weiterhin nur für ausführbare Backup-Varianten | `Catalogs/sample-databases.json`, `Schemas/sample-databases.schema.json`, `Private/ManifestParser.ps1` |
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
| Statische Vertragsprüfung | implementiert | `Tests/Static/Invoke-DocumentationChecks.ps1` |

## 3. Öffentliche Cmdlets

| Cmdlet | Zweck |
|---|---|
| `Invoke-SqlServerLab` | Interaktives Menü |
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
| `Test-SqlServerLabPrerequisite` | Provider, RAM, Storage und Ports prüfen |
| `Test-SqlServerLabAdapter` | Project Adapter gegen Schema, Pfadgrenzen und optional einen Run prüfen |
| `Install-SqlServerLabAdapter` | Validierten Adapter-Entrypoint ohne Lifecycle-Seiteneffekt anwenden |

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
| [Testdatenbank-Provisionierung und menügeführte Manifest-Erstellung](Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md) | Zielvertrag für Artifact Handler, Trust/Hash, Mehrfachauswahl, Pfadführung und Baselines; Backup-Handler, Trust-Pfad und Mehrfachauswahl sind implementiert |
| [Gemischter Container-Provider-Lifecycle](Architecture/MIXED_PROVIDER_LIFECYCLE.md) | implementierter Docker-/Podman-Lifecycle mit ProviderSubRuns, Start-Rollback und providergebundenem Cleanup |
| [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md) | verbindlicher Zielvertrag für Hyper-V, sealed Images, Netzwerke, Software, Reconcile und Refresh; noch kein Runtime-Nachweis |
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

1. `README.md`
2. `.ai/repo_map.yaml`
3. `SqlServerLab.psd1`
4. `Schemas/` und `Catalogs/`
5. `Public/`, `Private/`, `Providers/`
6. `Tests/`
7. `Documentation/Quality/KNOWN_LIMITATIONS.md`
8. Planungsdokumente erst danach

Bei jeder Änderung müssen Code, Beispiel, Dokumentation und Test gemeinsam geprüft werden. Die statische Prüfung ist über folgenden Befehl ausführbar:

```powershell
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
```
