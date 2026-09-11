# Project_Planning/ – Projektplanung

| Dokument | Inhalt |
|---|---|
| [SECURITY_TOOL_ACQUISITION_BACKLOG.md](SECURITY_TOOL_ACQUISITION_BACKLOG.md) | Geplanter Beschaffungsvertrag für autorisierte Penetrationstest-Werkzeuge: Manifest UND direkte API, getrennte Windows-/Linux-Varianten, Allowlist, Hash/Signatur, lokale Freigabe, sichere Aufbewahrung und Abnahmegrenzen; keine ausführbare Funktion |
| REFRESH_AND_RECOVERY_ASSESSMENT_2026-09-10.md | Abgeschlossene Bewertungen für vollständigen Evaluation-Refresh und Recovery Points: Inventar, Login/SID, Jobs, Schlüsselgrenzen, Cutover/Rückfall, SQL-Konsistenz, unabhängiger Restore und Referenzschutz; keine neue Runtimefreigabe |
| BI_CAPABILITIES_ASSESSMENT_2026-09-10.md | Abgeschlossene SSIS-, SSAS- und BI-Bewertung mit begrenztem Windows-Referenzpfad, Daten-/Processing-Assertions, Rollen, Commit-/Resume-Grenzen und Herstellerabgleich; keine neue Runtimefreigabe |
| HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md | Abgeschlossene Remote-Host-, Mehrbenutzer-, API-/IaC- und Clusterbewertung mit Identitäts-/Autorisierungsgrenzen, Nutzen, Aufwand, Eintrittskriterien und getrennten Abnahmen |
| SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md | Abgeschlossene Bewertungen für SQL-TLS-Gateway, Windows-ONNX, Preview-ANN, zusätzliche Cloudanbieter und begründete Nichtübernahme eines gemeinsamen Modellcaches |
| DISTRIBUTION_AND_OBJECT_STORAGE_ASSESSMENT_2026-09-10.md | Abgeschlossene Air-Gap-/S3-Bewertung mit Lizenz-/Integritätsbindung, echtem Offline-Roundtrip, begrenztem SQL-Object-Store-Slice und aktualisierter MinIO-Wartungsgrenze; keine neue Runtimefreigabe |
| AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md | Vollständige Aufgaben- und Abnahmeliste aus der Repository-Durchsicht: Test-/Release-Reparaturen, vorhandene Funktionen fertigstellen, native Evidence, Szenarien, KI und begründete Erweiterungsbewertungen; konkretisiert den nachgelagerten Horizont des Ausführungsplans |
| RESERVED_MANIFEST_FIELDS_ASSESSMENT_2026-09-10.md | Abgeschlossene Bedarfsbewertung reservierter Manifest- und Adapterfelder mit Wiederverwendung bestehender Verträge, Risiken, relativem Aufwand und konkreten Freischaltungskriterien; keine neue Runtimefreigabe |
| DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md | Kanonische Ausführungsreihenfolge; Abschnitt 12 führt den evidenzgebundenen Status der fünf Wellen für Baseline, P0-Recovery, drei Adapterpiloten, Hyper-V-End-to-End sowie Storage/Reconcile |
| M0_STATUS_TRUTH_MATRIX.md | Kanonische deduplizierte M0-Abnahmekriterien, Statusvokabular, vollständiges Alt-Wellen-Mapping und Readinessmatrix je Änderungsklasse |
| SCENARIO_CONTRACT_BACKLOG.md | Interner, nicht ausführbarer `SCN-801`-Schema-Slice für Scenario-, Step-, Evidence- und Outcome-Metadaten sowie verbleibende öffentliche Contract-Entscheidungen |
| MASTER_IMPLEMENTATION_PLAN.md | Gesamtziel, Wellen, Abnahmekriterien und Umsetzungsstand |
| MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md | Vorrangige Scope-Regeln |
| FUTURE_UI_WORKFLOW_PLAN_2026-08-08.md | Zukunftsplanung für CLI-/UI-Menüführung, Reconcile-Aktionen und Infrastruktur-Changes (Hyper-V + Container) |
| CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md | Verbindliche Konsolidierungswelle aus der manuellen Abnahme: Lifecycle-Seiteneffekte, vollständige Console-UI-Migration, Multi-Root-Storage und dateigenaue SQL-/TempDB-Platzierung |
| PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md | Beschlossener P0-Zielvertrag für providerneutrale Batchplanung, persistente Queue, Resume, Scheduler, User-Gates, Bulk-Slots, Cleanup und konsolidierte Menüführung |
| CONSOLE_UI_FRAMEWORK_PLAN.md | Verbindlicher Plan für cursorbasierte Konsolenmenüs, lange editierbare Formulare, Viewports, stabilen Refresh und Read-Host-Fallback |
| STORAGE_CONTRACT_PLAN.md | Zielvertrag für ein globales `Lab_Base`, genau eine `Lab_Data`-Wurzel je Volume und journalisierte Pfadmigrationen |
| HYPERV_LAB_DATA_RESOURCE_ROOT_BUGFIX_BACKLOG.md | Abgeschlossener P0-Bugfix für Slot-/Builder-VHDX, VM-Konfiguration, Smart Paging, Checkpoints und Hyper-V-Artefakte ausschließlich unter registrierten `Lab_Data`-Roots einschließlich real belegter Legacy-Migration |
| PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md | Providerübergreifender P1-Backlog für auswählbare Instanzspeicher, Backup-/Restore- und MDF/LDF/FILESTREAM-Pakete, sichere Retention sowie die noch erforderliche physische `Lab_Data`-Analyse für Docker, Podman und Hyper-V |
| FULL_INSTANCE_EVALUATION_REFRESH_BACKLOG.md | Zielvertrag für den parallelen Neuaufbau einer Evaluation-Umgebung mit vollständig klassifizierter Instanzübernahme, Gleichwertigkeitsnachweis, Cutover und Rollback |
| SQL_GUEST_EVALUATION_EVIDENCE_BACKLOG.md | Minimaler Hyper-V-Vertrag für versionsgebundene, frische und geheimnisfreie SQL-Gast-Evaluations-Evidence; Capture und Native-Abnahme sind noch nicht implementiert |
| CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md | Sammelbacklog für bislang nicht eigenständig geplante Querschnittsfähigkeiten: Evaluation-Watchdog, Gesamt-Lab-Portabilität, externe Secret Stores, Observability, Recovery Points, Framework-Upgrades, Air Gap, Kapazitätssteuerung, Mehrbenutzerbetrieb und Automation-API/IaC |
| PROJECT_ADAPTER_PRIORITIZATION.md | Entscheidung, Project Adapter vor Hyper-V umzusetzen, mit Arbeitspaketen |
| EXTERNAL_LANGUAGES_IMPLEMENTATION_PLAN.md | Providerneutraler Umsetzungsplan für Python, R und Java auf Hyper-V/Windows sowie Docker/Podman unter Linux; konkretisiert `SFT-711` und `SFT-712` |
| REPOSITORY_AGENT_SKILLS_BACKLOG.md | Fachlich akzeptierter Backlog für repository-lokale KI-Skills; trennt den eigenständig ausführbaren Client-Readiness-Check vom Skill-Loader und priorisiert `Readiness` vor `Validation` und `Operate` |
| CU_MONITORING_BACKLOG.md | Backlog zur Katalogaktualität der SQL-Server-Builds |
| CONSOLE_UX_FOLLOW_UP_BACKLOG.md | Abgeschlossene Konsolen-UX-Nacharbeiten: Nightly-Regression, Datenbankaktionen, Diagnoselog, deaktivierte Einträge, Hilfe, Statusband, Secret-Nachpflege und Bereichsmenüs sowie bindende Erkenntnisse zu Vertragsgestaltung und Scope-Fehlern |
| HYPERV_REMOTE_HOST_BACKLOG.md | Spätere Steuerung eines entfernten Windows-Hyper-V-Hosts aus der lokalen Workflow-Oberfläche |
| WINDOWS_LOCALE_CONFIGURATION_BACKLOG.md | Deklarative, pro Windows-Instanz konfigurierbare Sprache, Region, Tastatur und Zeitzone für Manifest- und Batch-Pfade |
| WINDOWS_SLOT_ACTIVATION_BACKLOG.md | Allgemeines Lizenz-Reconcile für Windows-Child-Slots mit sicherer Unterscheidung persistenter und temporärer External-NICs |
| POLYBASE_S3_OBJECT_STORAGE_BACKLOG.md | Automatisierter S3-kompatibler Object Store als SQL-Supporting-Component für PolyBase und native SQL-2025-Dateizugriffe unter Docker, Podman und später Hyper-V/Linux |
| SQL2025_AI_PLATFORM_BACKLOG.md | Übergeordneter local-first KI-Backlog für Plattformverträge, Vector-Core, Ollama, Retrieval/RAG, Evaluation, Read-only Agent, Cloud, ONNX und Schulung |
| SQL2025_VECTOR_EMBEDDING_BACKLOG.md | SQL-2025-Vector-Core, lokale ONNX-Embeddings unter Windows sowie gesicherte lokale Ollama- und optionale Cloud-Embedding-Lanes |
| NEW_SQL_LAB_USE_CASES_BACKLOG.md | Priorisierter Explorationsbacklog für neue fachliche Lab-Produkte wie Upgrade-/Regressionstests, Recovery-Übungen, App-/Treiberkompatibilität, Cross-Platform-Parität, Security, HA/DR und Event-Integration |
| SSIS_ETL_DATA_WAREHOUSE_BACKLOG.md | SSIS-Backlog für ETL, Data Warehouse, CDC/SCD, SSISDB, Package-Kompatibilität, Fault/Resume, Betrieb, Performance und Scale Out |
| SSAS_ANALYTICS_SEMANTIC_MODEL_BACKLOG.md | SSAS-Backlog für Tabular und später Multidimensional, DAX/MDX, Import/DirectQuery, Processing, Partitionierung, Security, Deployment, Performance und Recovery |
| END_TO_END_BI_PIPELINE_BACKLOG.md | Vollständige BI-Pipeline von synthetischer OLTP-Quelle über SSIS und Data Warehouse bis SSAS Tabular einschließlich Delta Load, DAX-Assertions, Faults und Recovery |
| SQL_SSIS_SSAS_CLUSTER_BACKLOG.md | Getrennte Clusterpfade für SQL-AG/FCI, SSISDB-HA/Scale Out, SSAS-WSFC/Query-Scale-out und ein späteres Clustered End-to-End BI |

Für Reihenfolge und Priorität der Weiterentwicklung ist ausschließlich
`DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md` maßgeblich. Die Wellenzählungen in
den übrigen Dokumenten beschreiben deren jeweiligen fachlichen Teilvertrag und
werden über `M0_STATUS_TRUTH_MATRIX.md` den aktuellen Meilensteinen zugeordnet.
Ein Planungsstatus ist kein
Implementierungs- oder Runtime-Nachweis.
