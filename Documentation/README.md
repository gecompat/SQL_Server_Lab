# Dokumentationsübersicht

| Merkmal | Wert |
|---|---|
| Status | `BINDING_INDEX` |
| Stand | 2026-07-27 |

## 1. Verbindliche Lesereihenfolge

1. [SQL-Server-zentrierte Scope-Entscheidung](Architecture/SQL_SERVER_CENTRIC_SCOPE_DECISION.md)
2. [Master-Umsetzungsplan](Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
3. [Verbindliche Masterplan-Ergänzung](Project_Planning/MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md)
4. [Erweiterbarer SQL-Server-Umgebungs- und Ausführungsvertrag](Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md)
5. [Manifest- und Schnittstellenarchitektur](Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md)
6. [Projektintegrationsvertrag](Architecture/PROJECT_INTEGRATION_CONTRACT.md)
7. [Zukünftige SQL-Server-Anwendungsfälle](Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md)

Bei widersprüchlichen älteren Formulierungen haben Scope-Entscheidung und Masterplan-Ergänzung Vorrang.

## 2. Architektur

| Dokument | Inhalt |
|---|---|
| [SQL-Server-zentrierte Scope-Entscheidung](Architecture/SQL_SERVER_CENTRIC_SCOPE_DECISION.md) | SQL Server als Hauptzweck; Supporting Components nur mit SQL-Bezug |
| [Erweiterbarer Umgebungs- und Ausführungsvertrag](Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md) | Package, Versionskatalog, Components, DataSets, Backups, Resource Assessment, Workflow, Provider, Recovery und Cleanup |
| [Manifest- und Schnittstellenarchitektur](Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md) | geplante maschinenlesbare Schemas, Version Constraints, Database Artifacts, Resource Override und Auflösungsreihenfolge |
| [Projektintegrationsvertrag](Architecture/PROJECT_INTEGRATION_CONTRACT.md) | Anbindung von Analyze und Performance-Schulung |
| [Zukünftige Anwendungsfälle](Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md) | SQL-Server-Roadmap und Grenzen für Supporting Components |

## 3. Verbindliche Querschnittsregeln

### SQL-Server-Versionen

Derzeit sind SQL Server 2019, 2022 und 2025 als aktive Katalogeinträge vorgesehen. Die Schnittstellen sind versionsoffen: neue Versionen werden über Katalog, Provider-Mapping und Capabilities ergänzt; alte Versionen über Status kontrolliert ausgesteuert.

### Datenbankartefakte

Zulässig sind Lab-erzeugte Backups, öffentliche Demo-Datenbanken und ausdrücklich klassifizierte lokale Nicht-Produktionsbackups. Produktions- und unbekannte Daten bleiben blockiert.

### Ressourcen und Cleanup

CPU, RAM, freier Speicher, Provider-Overhead und Restore-Peak werden vor Mutation bewertet. Vorhergesagte Unterversorgung kann ausdrücklich übersteuert werden. Ohne vollständigen Cleanup Plan ist keine Mutation zulässig; Fehler lösen automatische und wiederaufnehmbare Compensation aus.

## 4. Projektplanung

| Dokument | Inhalt |
|---|---|
| [Master-Umsetzungsplan](Project_Planning/MASTER_IMPLEMENTATION_PLAN.md) | Gesamtziel, Provider, Lifecycle, Wellen und Abnahmekriterien |
| [Masterplan-Ergänzung](Project_Planning/MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md) | vorrangige Regeln zu SQL-Scope, Versionskatalog, Backups, Ressourcenübersteuerung und Recovery |

## 5. Migration

| Dokument | Inhalt |
|---|---|
| [Migrationsinventar und Ablöseentscheidungen](Migration/MIGRATION_INVENTORY_AND_DECISIONS.md) | Übernahme aus Analyze QuickStart, Analyze Lab/QuickTest und Performance-Schulung |

## 6. Qualität und Sicherheit

| Dokument | Inhalt |
|---|---|
| [Privacy- und Artefaktsicherheitsvertrag](Quality/PRIVACY_AND_ARTIFACT_SECURITY.md) | Trennung lokaler Runtimewerte und versionierter Artefakte |
| [Lokale Validierungsstrategie](Quality/LOCAL_VALIDATION_STRATEGY.md) | Static-, Contract-, Planner-, Artifact-, Resource-, Recovery- und Native-Tests ohne CI/CD |

## 7. Standards

| Dokument | Inhalt |
|---|---|
| [Sprach-, Übersetzungs- und Schreibstandard](Standards/LANGUAGE_TRANSLATION_AND_STYLE_STANDARD.md) | Deutsch als Dokumentationssprache, englische Codes und Übersetzungsparität |

## 8. Forschung

| Dokument | Inhalt |
|---|---|
| [Analyse bestehender Lab- und Orchestrierungsprojekte](Research/EXISTING_LAB_AND_ORCHESTRATION_PROJECTS_REVIEW.md) | AutomatedLab, MSLab, Compose und weitere Musterquellen |

Die Forschungsanalyse dient ausschließlich der Auswahl bewährter Muster für das SQL-Server-Lab. Sie ist keine Entscheidung, alle untersuchten Produkte zu kombinieren.

## 9. KI- und Arbeitskontext

| Dokument | Inhalt |
|---|---|
| [Projektkontext](../.ai/PROJECT_CONTEXT.md) | dauerhafte Projektentscheidungen, Versions-, Artifact-, Resource- und Recovery-Regeln |
| [Arbeitsregeln](../.ai/WORKING_RULES.md) | Privacy-, Provider-, Package-, Validierungs- und Git-Regeln |

## 10. Aktueller Status

### Implementiert und getestet (Stand: Juli 2026)

| Komponente | Status | Dateien |
|---|---|---|
| SQL Version Catalog | ✅ implementiert | `Catalogs/sql-server-versions.json` (2019, 2022, 2025) |
| Lab CLI (Public API) | ✅ 11 Cmdlets | `Public/*.ps1` |
| Planner und Resource Assessment | ✅ implementiert | `Private/ResourceAssessment.ps1` |
| Run State und Cleanup Engine | ✅ implementiert | `Private/StateMachine.ps1`, `Private/CleanupEngine.ps1` |
| Docker-Provider | ✅ implementiert | `Providers/Docker/DockerProvider.ps1` |
| Podman-Provider | ✅ implementiert | `Providers/Podman/PodmanProvider.ps1` |
| Secret-Management (DPAPI) | ✅ implementiert | `Private/SecretProvider.ps1` |
| SQL-Engine (3-stufig) | ✅ implementiert | `Private/SqlReadiness.ps1` (Microsoft.Data → System.Data → sqlcmd) |
| Manifest-Parser | ✅ implementiert | `Private/ManifestParser.ps1` + `Schemas/example-lab.json` |
| Interaktives Menue | ✅ implementiert | `Public/Invoke-SqlServerLab.ps1` (Provider-Auswahl) |
| Integration-Tests | ✅ runtime-agnostisch | `Tests/Integration/Invoke-SmokeTest.ps1` (docker/podman auto-detect) |

### Cmdlet-Uebersicht

| Cmdlet | Zweck |
|---|---|
| `Invoke-SqlServerLab` | Interaktives Menue mit Provider-Auswahl |
| `New-SqlServerLab` | Neue Umgebung erstellen (Ad-hoc oder Manifest) |
| `Get-SqlServerLab` | Status anzeigen (State + Live-Container-Status) |
| `Stop-SqlServerLab` | Graceful Stop, Daten bleiben erhalten |
| `Start-SqlServerLab` | Gestoppte Umgebung starten + SQL-Readiness |
| `Restart-SqlServerLab` | Stop + Start in einem Aufruf |
| `Remove-SqlServerLab` | Umgebung entfernen (Scope-validiert) |
| `Clear-SqlServerLab` | Alle Lab-Container + State aufraeumen |
| `New-LabDatabase` | Datenbank mit Multi-File-Specs erstellen |
| `Invoke-LabScript` | T-SQL-Skript ausfuehren (GO-Batch-Splitting, -KeepConnection) |
| `Test-LabResources` | Ressourcen pruefen ohne Mutation |

### Provider-Unterstuetzung

| Provider | Status | Runtime-Erkennung |
|---|---|---|
| Docker | ✅ Produktiv | `docker` CLI-Befehl |
| Podman | ✅ Produktiv | `podman` CLI-Befehl |
| Hyper-V | ⬜ geplant | `Get-VM` Cmdlet |

Auf Dual-Systemen (Docker + Podman) werden beide Provider erkannt und im interaktiven Menue zur Auswahl angeboten. Der Smoke-Test prueft alle installierten Runtimes.

### Noch nicht implementiert

- JSON-Schemas (Manifest-Validierung);
- Backup-/Restore-Actions (AdventureWorks per URL);
- Hyper-V-Provider;
- Analyze- und Performance-Packages.

Planungsdokumente sind kein Runtime-Nachweis.
