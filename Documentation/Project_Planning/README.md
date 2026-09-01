# Project_Planning/ – Projektplanung

| Dokument | Inhalt |
|---|---|
| DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md | Kanonische Ausführungsreihenfolge; Abschnitt 12 führt den evidenzgebundenen Status der fünf Wellen für Baseline, P0-Recovery, drei Adapterpiloten, Hyper-V-End-to-End sowie Storage/Reconcile |
| MASTER_IMPLEMENTATION_PLAN.md | Gesamtziel, Wellen, Abnahmekriterien und Umsetzungsstand |
| MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md | Vorrangige Scope-Regeln |
| FUTURE_UI_WORKFLOW_PLAN_2026-08-08.md | Zukunftsplanung für CLI-/UI-Menüführung, Reconcile-Aktionen und Infrastruktur-Changes (Hyper-V + Container) |
| CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md | Verbindliche Konsolidierungswelle aus der manuellen Abnahme: Lifecycle-Seiteneffekte, vollständige Console-UI-Migration, Multi-Root-Storage und dateigenaue SQL-/TempDB-Platzierung |
| PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md | Beschlossener P0-Zielvertrag für providerneutrale Batchplanung, persistente Queue, Resume, Scheduler, User-Gates, Bulk-Slots, Cleanup und konsolidierte Menüführung |
| CONSOLE_UI_FRAMEWORK_PLAN.md | Verbindlicher Plan für cursorbasierte Konsolenmenüs, lange editierbare Formulare, Viewports, stabilen Refresh und Read-Host-Fallback |
| STORAGE_CONTRACT_PLAN.md | Zielvertrag für ein globales `Lab_Base`, genau eine `Lab_Data`-Wurzel je Volume und journalisierte Pfadmigrationen |
| HYPERV_LAB_DATA_RESOURCE_ROOT_BUGFIX_BACKLOG.md | Abgeschlossener P0-Bugfix für Slot-/Builder-VHDX, VM-Konfiguration, Smart Paging, Checkpoints und Hyper-V-Artefakte ausschließlich unter registrierten `Lab_Data`-Roots einschließlich real belegter Legacy-Migration |
| PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md | Providerübergreifender P1-Backlog für auswählbare Instanzspeicher, Backup-/Restore- und MDF/LDF/FILESTREAM-Pakete, sichere Retention sowie die noch erforderliche physische `Lab_Data`-Analyse für Docker, Podman und Hyper-V |
| PROJECT_ADAPTER_PRIORITIZATION.md | Entscheidung, Project Adapter vor Hyper-V umzusetzen, mit Arbeitspaketen |
| EXTERNAL_LANGUAGES_IMPLEMENTATION_PLAN.md | Providerneutraler Umsetzungsplan für Python, R und Java auf Hyper-V/Windows sowie Docker/Podman unter Linux; konkretisiert `SFT-711` und `SFT-712` |
| CU_MONITORING_BACKLOG.md | Backlog zur Katalogaktualität der SQL-Server-Builds |
| HYPERV_REMOTE_HOST_BACKLOG.md | Spätere Steuerung eines entfernten Windows-Hyper-V-Hosts aus der lokalen Workflow-Oberfläche |
| WINDOWS_LOCALE_CONFIGURATION_BACKLOG.md | Deklarative, pro Windows-Instanz konfigurierbare Sprache, Region, Tastatur und Zeitzone für Manifest- und Batch-Pfade |
| WINDOWS_SLOT_ACTIVATION_BACKLOG.md | Allgemeines Lizenz-Reconcile für Windows-Child-Slots mit sicherer Unterscheidung persistenter und temporärer External-NICs |
| POLYBASE_S3_OBJECT_STORAGE_BACKLOG.md | Automatisierter S3-kompatibler Object Store als SQL-Supporting-Component für PolyBase und native SQL-2025-Dateizugriffe unter Docker, Podman und später Hyper-V/Linux |
| SQL2025_VECTOR_EMBEDDING_BACKLOG.md | SQL-2025-Vector-Core, lokale ONNX-Embeddings unter Windows sowie gesicherte lokale Ollama- und optionale Cloud-Embedding-Lanes |
| NEW_SQL_LAB_USE_CASES_BACKLOG.md | Priorisierter Explorationsbacklog für neue fachliche Lab-Produkte wie Upgrade-/Regressionstests, Recovery-Übungen, App-/Treiberkompatibilität, Cross-Platform-Parität, Security, HA/DR und Event-Integration |
| SSIS_ETL_DATA_WAREHOUSE_BACKLOG.md | SSIS-Backlog für ETL, Data Warehouse, CDC/SCD, SSISDB, Package-Kompatibilität, Fault/Resume, Betrieb, Performance und Scale Out |
| SSAS_ANALYTICS_SEMANTIC_MODEL_BACKLOG.md | SSAS-Backlog für Tabular und später Multidimensional, DAX/MDX, Import/DirectQuery, Processing, Partitionierung, Security, Deployment, Performance und Recovery |
| END_TO_END_BI_PIPELINE_BACKLOG.md | Vollständige BI-Pipeline von synthetischer OLTP-Quelle über SSIS und Data Warehouse bis SSAS Tabular einschließlich Delta Load, DAX-Assertions, Faults und Recovery |
| SQL_SSIS_SSAS_CLUSTER_BACKLOG.md | Getrennte Clusterpfade für SQL-AG/FCI, SSISDB-HA/Scale Out, SSAS-WSFC/Query-Scale-out und ein späteres Clustered End-to-End BI |

Für Reihenfolge und Priorität der Weiterentwicklung ist ausschließlich
`DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md` maßgeblich. Die Wellenzählungen in
den übrigen Dokumenten beschreiben deren jeweiligen fachlichen Teilvertrag und
werden über den Master-Plan zugeordnet. Ein Planungsstatus ist kein
Implementierungs- oder Runtime-Nachweis.
