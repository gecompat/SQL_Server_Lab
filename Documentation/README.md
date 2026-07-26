# Dokumentationsübersicht

| Merkmal | Wert |
|---|---|
| Status | `BINDING_INDEX` |
| Stand | 2026-07-26 |

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
| [Erweiterbarer Umgebungs- und Ausführungsvertrag](Architecture/EXTENSIBLE_ENVIRONMENT_AND_EXECUTION_CONTRACT.md) | Package, SQL Purpose, Components, DataSets, Workflow, Bindings, Provider und Cleanup |
| [Manifest- und Schnittstellenarchitektur](Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md) | geplante maschinenlesbare Schemas und Auflösungsreihenfolge |
| [Projektintegrationsvertrag](Architecture/PROJECT_INTEGRATION_CONTRACT.md) | Anbindung von Analyze und Performance-Schulung |
| [Zukünftige Anwendungsfälle](Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md) | SQL-Server-Roadmap und Grenzen für Supporting Components |

## 3. Projektplanung

| Dokument | Inhalt |
|---|---|
| [Master-Umsetzungsplan](Project_Planning/MASTER_IMPLEMENTATION_PLAN.md) | Gesamtziel, Provider, Lifecycle, Wellen und Abnahmekriterien |
| [Masterplan-Ergänzung](Project_Planning/MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md) | verbindliche Korrektur auf SQL-zentrierten Scope |

## 4. Migration

| Dokument | Inhalt |
|---|---|
| [Migrationsinventar und Ablöseentscheidungen](Migration/MIGRATION_INVENTORY_AND_DECISIONS.md) | Übernahme aus Analyze QuickStart, Analyze Lab/QuickTest und Performance-Schulung |

## 5. Qualität und Sicherheit

| Dokument | Inhalt |
|---|---|
| [Privacy- und Artefaktsicherheitsvertrag](Quality/PRIVACY_AND_ARTIFACT_SECURITY.md) | Trennung lokaler Runtimewerte und versionierter Artefakte |
| [Lokale Validierungsstrategie](Quality/LOCAL_VALIDATION_STRATEGY.md) | Static-, Contract-, Planner-, Synthetic- und Native-Tests ohne CI/CD |

## 6. Standards

| Dokument | Inhalt |
|---|---|
| [Sprach-, Übersetzungs- und Schreibstandard](Standards/LANGUAGE_TRANSLATION_AND_STYLE_STANDARD.md) | Deutsch als Dokumentationssprache, englische Codes und Übersetzungsparität |

## 7. Forschung

| Dokument | Inhalt |
|---|---|
| [Analyse bestehender Lab- und Orchestrierungsprojekte](Research/EXISTING_LAB_AND_ORCHESTRATION_PROJECTS_REVIEW.md) | AutomatedLab, MSLab, Compose und weitere Musterquellen |

Die Forschungsanalyse dient ausschließlich der Auswahl bewährter Muster für das SQL-Server-Lab. Sie ist keine Entscheidung, alle untersuchten Produkte zu kombinieren.

## 8. KI- und Arbeitskontext

| Dokument | Inhalt |
|---|---|
| [Projektkontext](../.ai/PROJECT_CONTEXT.md) | dauerhafte Projektentscheidungen und Scope |
| [Arbeitsregeln](../.ai/WORKING_RULES.md) | Privacy-, Provider-, Package-, Validierungs- und Git-Regeln |

## 9. Aktueller Status

Der aktuelle Stand ist eine Planungs- und Governance-Basis. Noch nicht implementiert sind:

- JSON-Schemas;
- Lab CLI;
- Planner;
- State Store;
- Docker-, Podman- und Hyper-V-Provider;
- Analyze- und Performance-Packages;
- lokale Testtools.

Planungsdokumente sind kein Runtime-Nachweis.
