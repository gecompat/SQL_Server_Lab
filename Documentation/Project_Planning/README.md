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
| PROJECT_ADAPTER_PRIORITIZATION.md | Entscheidung, Project Adapter vor Hyper-V umzusetzen, mit Arbeitspaketen |
| EXTERNAL_LANGUAGES_IMPLEMENTATION_PLAN.md | Providerneutraler Umsetzungsplan für Python, R und Java auf Hyper-V/Windows sowie Docker/Podman unter Linux; konkretisiert `SFT-711` und `SFT-712` |
| CU_MONITORING_BACKLOG.md | Backlog zur Katalogaktualität der SQL-Server-Builds |
| HYPERV_REMOTE_HOST_BACKLOG.md | Spätere Steuerung eines entfernten Windows-Hyper-V-Hosts aus der lokalen Workflow-Oberfläche |
| WINDOWS_LOCALE_CONFIGURATION_BACKLOG.md | Deklarative, pro Windows-Instanz konfigurierbare Sprache, Region, Tastatur und Zeitzone für Manifest- und Batch-Pfade |

Für Reihenfolge und Priorität der Weiterentwicklung ist ausschließlich
`DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md` maßgeblich. Die Wellenzählungen in
den übrigen Dokumenten beschreiben deren jeweiligen fachlichen Teilvertrag und
werden über den Master-Plan zugeordnet. Ein Planungsstatus ist kein
Implementierungs- oder Runtime-Nachweis.
