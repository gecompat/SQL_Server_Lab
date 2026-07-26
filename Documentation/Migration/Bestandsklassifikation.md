# Bestandsklassifikation: Lab-bezogene Dateien in Quellrepositories

**Stand:** 2026-07-26
**Zweck:** Systematische Erfassung aller Lab-/Infrastruktur-Dateien in SQL_Server_Analyze und SQL_PerformanceSchulung als Grundlage fuer die Bereinigung.

---

## 1. SQL_Server_Analyze

### 1.1 QuickStart/ (31 Dateien)

#### QuickStart/Docker/ (13 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| Setup.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Interaktiver Docker-Einstieg |
| Uninstall.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Scope-sichere Deinstallation |
| docker-compose.yml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Basis-Compose (Podman-kompatibel) |
| docker-compose.docker-desktop.yml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Docker-Desktop-spezifisch |
| docker-compose.slow-io.yml | GENERIC_FAULT_INJECTION | MOVE_OR_REIMPLEMENT_IN_LAB | I/O-Drosselung |
| .env.example | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Template fuer lokale .env |
| README.md | DOCUMENTATION | MOVE_OR_REIMPLEMENT_IN_LAB | Docker-Anleitung |
| Internal/Common.ps1 | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Hilfsfunktionen |
| Internal/PathSafety.ps1 | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Pfadvalidierung |
| Internal/Configuration.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Setup-Dialog Docker |
| Internal/Runtime.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Start/Stop/Status |
| Internal/Lifecycle.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Remove/Destroy |
| Internal/Configuration/Storage.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Volume-/Pfadlogik |
| Internal/Configuration/Parameters.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | CLI-Parameter |
| Internal/Configuration/Environment.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Env-Generierung |
| Internal/Configuration/SetupConfiguration.ps1 | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Konfigurationsfluss |
| Validation/Invoke-QuickStartPathSafetyTests.ps1 | VALIDATION | MOVE_OR_REIMPLEMENT_IN_LAB | Pfad-Negativtests |

#### QuickStart/HyperV/ (14 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| Setup.ps1 | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Interaktiver HyperV-Einstieg |
| Uninstall.ps1 | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Deinstallation |
| .env.example | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Template |
| README.md | DOCUMENTATION | MOVE_OR_REIMPLEMENT_IN_LAB | HyperV-Anleitung |
| Documentation/Base_Image_Quellen.md | DOCUMENTATION | MOVE_OR_REIMPLEMENT_IN_LAB | Image-Download-Referenzen |
| Internal/Common.ps1 | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Hilfsfunktionen |
| Internal/PathSafety.ps1 | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Pfadvalidierung |
| Internal/Configuration.ps1 | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Setup-Dialog HyperV |
| Internal/VmProvisioning.ps1 | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | VM-Erstellung |
| Internal/SqlInstall.ps1 | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | SQL auf Win/Linux |
| Internal/NetworkSimulation.ps1 | GENERIC_FAULT_INJECTION | MOVE_OR_REIMPLEMENT_IN_LAB | tc/netem/cgroups |
| Internal/Runtime.ps1 | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Start/Stop/Status |
| Internal/Lifecycle.ps1 | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Remove/Destroy |

#### QuickStart/ Root

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| README.md | DOCUMENTATION | REPLACE_WITH_ADAPTER | Wird Verweis auf SQL_Server_Lab |

---

### 1.2 Lab/ (~50 Dateien)

#### Lab/ Root (6 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| README.md | DOCUMENTATION | REMOVE_AFTER_GATE | Wird durch SQL_Server_Lab ersetzt |
| Install-Lab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Orchestrierungs-Einstieg |
| Uninstall-Lab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Scope-sicherer Abbau |
| Update-Framework.ps1 | PROJECT_INSTALLER | KEEP_IN_SOURCE | Framework-Update (Analyze-spezifisch) |
| Run-LogShipping-Lab.ps1 | PROJECT_WORKLOAD | KEEP_IN_SOURCE | Szenario-Starter |
| .gitignore | GENERIC_LAB_CORE | REMOVE_AFTER_GATE | Nur Lab-Scope relevant |

#### Lab/QuickTest/ (13 Dateien)

| Pfad | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| QuickTestLab.psm1 | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | PowerShell-Modul-Manifest |
| README.md | DOCUMENTATION | REMOVE_AFTER_GATE | QuickTest-Doku |
| Public/Install-QuickTestLab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Container-Setup |
| Public/Start-QuickTestLab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Start |
| Public/Start-QuickTestStoppedLab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Resume |
| Public/Stop-QuickTestLab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Stop |
| Public/Restart-QuickTestLab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Restart |
| Public/Reset-QuickTestLab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Reset |
| Public/Remove-QuickTestLab.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Remove |
| Public/Get-QuickTestLabStatus.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Status |
| Public/Invoke-QuickTestPreflight.ps1 | GENERIC_RESOURCE_MANAGEMENT | MOVE_OR_REIMPLEMENT_IN_LAB | Preflight |
| Public/Invoke-QuickTestLabDown.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Down |
| Public/Update-QuickTestFramework.ps1 | PROJECT_INSTALLER | KEEP_IN_SOURCE | Framework-Update |
| Private/Common.ps1 | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Interne Helfer |
| Private/LifecycleRuntime.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | Runtime-Logik |
| Private/LifecycleState.ps1 | GENERIC_LIFECYCLE | MOVE_OR_REIMPLEMENT_IN_LAB | State-Machine |

#### Lab/Containers/ (8 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| compose.yaml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Basis Podman-kompatibel |
| compose.docker.yaml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Docker-spezifisch |
| quick-test.compose.yaml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | QuickTest Podman |
| quick-test.compose.docker.yaml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | QuickTest Docker |
| quick-test.compose.podman.yaml | PROVIDER_PODMAN | MOVE_OR_REIMPLEMENT_IN_LAB | QuickTest Podman-spezifisch |
| wave4.compose.yaml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Multi-Instanz-Topologie |
| wave4.compose.docker.yaml | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Wave4 Docker |
| Scripts/bootstrap-linux.sh | PROVIDER_DOCKER | MOVE_OR_REIMPLEMENT_IN_LAB | Container-Bootstrap |

#### Lab/Config/ (6 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| resource-profiles.json | GENERIC_RESOURCE_MANAGEMENT | MOVE_OR_REIMPLEMENT_IN_LAB | CPU/RAM/Storage-Profile |
| host-capabilities.example.json | GENERIC_RESOURCE_MANAGEMENT | MOVE_OR_REIMPLEMENT_IN_LAB | Host-Erkennung |
| capability-overrides.example.json | GENERIC_RESOURCE_MANAGEMENT | MOVE_OR_REIMPLEMENT_IN_LAB | Override-Doku |
| lab.config.example.psd1 | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Konfigurationsformat |
| image-lock.example.json | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Image-Pinning |
| .gitignore | GENERIC_LAB_CORE | REMOVE_AFTER_GATE | Lokale Konfig ausschliessen |

#### Lab/Contracts/ (9 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| topology.schema.json | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Topologie-Vertrag |
| scenario.schema.json | PROJECT_PROBE | KEEP_IN_SOURCE | Szenario-Format (Analyze-spezifisch) |
| lab-config.schema.json | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Lab-Konfigurationsformat |
| host-capability.schema.json | GENERIC_RESOURCE_MANAGEMENT | MOVE_OR_REIMPLEMENT_IN_LAB | Host-Assessment |
| finding-expectation.schema.json | PROJECT_ASSERTION | KEEP_IN_SOURCE | Finding-Validierung |
| evidence.schema.json | PROJECT_ASSERTION | KEEP_IN_SOURCE | Evidenz-Format |
| contract-fixture.schema.json | PROJECT_PROBE | KEEP_IN_SOURCE | Test-Fixtures |
| hyperv-image-pipeline.schema.json | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Image-Erstellung |
| wave4-topology-profile.schema.json | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Multi-Instanz-Profile |
| scenario-runbook.schema.json | PROJECT_PROBE | KEEP_IN_SOURCE | Szenario-Runbooks |

#### Lab/Orchestration/ (3 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| Invoke-DiagnosticLab.ps1 | PROJECT_WORKLOAD | KEEP_IN_SOURCE | Analyze-Orchestrierung |
| Modules/DiagnosticLab/DiagnosticLab.psm1 | PROJECT_WORKLOAD | KEEP_IN_SOURCE | Diagnose-Modul |
| Modules/DiagnosticLab/DiagnosticLab.psd1 | PROJECT_WORKLOAD | KEEP_IN_SOURCE | Modul-Manifest |

#### Lab/Validation/ (12 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| Invoke-LabValidation.ps1 | VALIDATION | MOVE_OR_REIMPLEMENT_IN_LAB | Allgemeiner Validator |
| Invoke-LabQuickTestPreflightTests.ps1 | VALIDATION | MOVE_OR_REIMPLEMENT_IN_LAB | Preflight-Tests |
| Invoke-LabQuickTestLifecycleTests.ps1 | VALIDATION | MOVE_OR_REIMPLEMENT_IN_LAB | Lifecycle-Tests |
| Invoke-LabQuickTestStopTests.ps1 | VALIDATION | MOVE_OR_REIMPLEMENT_IN_LAB | Stop-Tests |
| Invoke-LabQuickTestRestartTests.ps1 | VALIDATION | MOVE_OR_REIMPLEMENT_IN_LAB | Restart-Tests |
| Invoke-LabQuickTestResetTests.ps1 | VALIDATION | MOVE_OR_REIMPLEMENT_IN_LAB | Reset-Tests |
| Invoke-LabQuickTestUpdateFrameworkTests.ps1 | PROJECT_PROBE | KEEP_IN_SOURCE | Framework-Update-Tests |
| Invoke-LabWave1Tests.ps1 | PROJECT_PROBE | KEEP_IN_SOURCE | Wave1-Szenario |
| Invoke-LabWave2Tests.ps1 | PROJECT_PROBE | KEEP_IN_SOURCE | Wave2-Szenario |
| Invoke-LabWave3Tests.ps1 | PROJECT_PROBE | KEEP_IN_SOURCE | Wave3-Szenario |
| Invoke-LabWave4LogShippingTests.ps1 | PROJECT_PROBE | KEEP_IN_SOURCE | LogShipping-Szenario |
| Invoke-LabWave4RuntimeTests.ps1 | PROJECT_PROBE | KEEP_IN_SOURCE | Runtime-Szenario |
| Fixtures/Valid/*.json (5 Dateien) | PROJECT_PROBE | KEEP_IN_SOURCE | Test-Fixtures |

#### Lab/Scenarios/ (10 Dateien)

| Pfad | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| LEARNING_PATH.md | PROJECT_WORKLOAD | KEEP_IN_SOURCE | Lernpfad (Analyze-spezifisch) |
| Catalog/topologies.json | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Verfuegbare Topologien |
| Catalog/scenarios.json | PROJECT_PROBE | KEEP_IN_SOURCE | Szenario-Katalog |
| Catalog/coverage.csv | PROJECT_PROBE | KEEP_IN_SOURCE | Abdeckungsmatrix |
| Core/LAB-BASE-001/* | PROJECT_PROBE | KEEP_IN_SOURCE | Basis-Szenario |
| Core/LAB-BASE-002/* | PROJECT_PROBE | KEEP_IN_SOURCE | Basis-Szenario |
| Infrastructure/README.md | DOCUMENTATION | MOVE_OR_REIMPLEMENT_IN_LAB | Infra-Szenarien-Doku |
| Infrastructure/wave4-contracts.csv | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Wave4-Vertrag |
| Infrastructure/wave4-topology-profiles.json | GENERIC_LAB_CORE | MOVE_OR_REIMPLEMENT_IN_LAB | Topologie-Profile |
| Infrastructure/LAB-LS-001/* (5 Dateien) | PROJECT_WORKLOAD | KEEP_IN_SOURCE | LogShipping-Szenario |

#### Lab/HyperV/ (2 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| Images/README.md | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Image-Pipeline-Doku |
| Images/image-pipeline-contract.json | PROVIDER_HYPERV | MOVE_OR_REIMPLEMENT_IN_LAB | Image-Pipeline-Vertrag |

---

### 1.3 .github/workflows/ (7 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| quickstart-docker-validation.yml | VALIDATION | REMOVE_AFTER_GATE | Lab-spezifischer CI-Test |
| lab-contract-validation.yml | VALIDATION | REMOVE_AFTER_GATE | Schema-Validierung fuer Lab-Contracts |
| sqlserver-compatibility-matrix-manual.yml | VALIDATION | REMOVE_AFTER_GATE | SQL-Server-Kompatibilitaetsmatrix |
| sqlserver-2022-linux-release-gate.yml | VALIDATION | REMOVE_AFTER_GATE | Release-Gate (Lab-abhaengig) |
| documentation-validation.yml | VALIDATION | KEEP_IN_SOURCE | Doku-Qualitaet |
| repository-privacy-validation.yml | VALIDATION | KEEP_IN_SOURCE | Privacy-Pruefung |
| commit-message-validation.yml | VALIDATION | KEEP_IN_SOURCE | Commit-Format |
| collect-statistics-release-evidence.yml | VALIDATION | KEEP_IN_SOURCE | Release-Evidenz |

---

## 2. SQL_PerformanceSchulung

### 2.1 Infrastructure/ (1 Datei)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| README.md | DOCUMENTATION | REPLACE_WITH_ADAPTER | Platzhalter, wird Verweis auf SQL_Server_Lab |

### 2.2 Tests/ (11 Dateien)

| Pfad | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| README.md | DOCUMENTATION | KEEP_IN_SOURCE | Test-Uebersicht |
| Static/validate_framework_contracts.py | PROJECT_ASSERTION | KEEP_IN_SOURCE | Fachliche Validierung |
| Static/validate_gate_b_pilots.py | PROJECT_ASSERTION | KEEP_IN_SOURCE | Gate-B-Pruefung |
| Static/validate_w2_001_classification.py | PROJECT_ASSERTION | KEEP_IN_SOURCE | Klassifikation |
| Static/validate_w2_007_presentation.py | PROJECT_ASSERTION | KEEP_IN_SOURCE | Praesentationscheck |
| Static/validate_orchestration_runtime.py | PROJECT_ASSERTION | KEEP_IN_SOURCE | Orchestrierungs-Vertrag |
| Static/test_orchestration_runtime.py | PROJECT_ASSERTION | KEEP_IN_SOURCE | Orchestrierungs-Unit-Tests |
| Static/test_result_contract_evaluator.py | PROJECT_ASSERTION | KEEP_IN_SOURCE | Ergebnis-Evaluator |
| Runtime/README.md | DOCUMENTATION | KEEP_IN_SOURCE | Runtime-Test-Doku |
| Runtime/docker_sqlcmd_proxy.py | COMPATIBILITY_WRAPPER | REPLACE_WITH_ADAPTER | Docker-Zugriff → Lab-Adapter |
| Runtime/run_framework_sql_matrix.py | PROJECT_PROBE | REPLACE_WITH_ADAPTER | Braucht Lab-Verbindung |
| Runtime/run_framework_sql_matrix_staged.py | PROJECT_PROBE | REPLACE_WITH_ADAPTER | Braucht Lab-Verbindung |
| Runtime/run_gate_b_pilots.py | PROJECT_PROBE | REPLACE_WITH_ADAPTER | Braucht Lab-Verbindung |

### 2.3 .github/workflows/ (5 Dateien)

| Datei | Klasse | Entscheidung | Bemerkung |
| --- | --- | --- | --- |
| framework-contracts.yml | VALIDATION | KEEP_IN_SOURCE | Fachliche Vertraege |
| gate-b-pilots.yml | VALIDATION | KEEP_IN_SOURCE | Gate-B (braucht SQL) |
| framework-sql-matrix.yml | VALIDATION | KEEP_IN_SOURCE | SQL-Matrix (braucht SQL) |
| presentation-refine-claims.yml | VALIDATION | KEEP_IN_SOURCE | Praesentationslogik |
| w2-001-classification.yml | VALIDATION | KEEP_IN_SOURCE | Klassifikation |
| pull_request_template.md | DOCUMENTATION | KEEP_IN_SOURCE | PR-Vorlage |

---

## 3. Zusammenfassung

### Entscheidungsverteilung SQL_Server_Analyze

| Entscheidung | Anzahl Dateien |
| --- | --- |
| MOVE_OR_REIMPLEMENT_IN_LAB | ~65 |
| KEEP_IN_SOURCE | ~25 |
| REMOVE_AFTER_GATE | ~10 |
| REPLACE_WITH_ADAPTER | ~1 |

### Entscheidungsverteilung SQL_PerformanceSchulung

| Entscheidung | Anzahl Dateien |
| --- | --- |
| KEEP_IN_SOURCE | ~14 |
| REPLACE_WITH_ADAPTER | ~4 |

### Reihenfolge der Bereinigung

1. **SQL_Server_Analyze/QuickStart/** — gesamter Ordner (31 Dateien) → nach SQL_Server_Lab
2. **SQL_Server_Analyze/Lab/QuickTest/** — allgemeine Lifecycle-Logik → nach SQL_Server_Lab
3. **SQL_Server_Analyze/Lab/Containers/** — alle Compose-Dateien → nach SQL_Server_Lab
4. **SQL_Server_Analyze/Lab/Config/** — Ressourcenprofile, Host-Caps → nach SQL_Server_Lab
5. **SQL_Server_Analyze/Lab/Contracts/** (nur generische) — Topologie, Host-Cap, Lab-Config Schemas
6. **SQL_Server_Analyze/Lab/Validation/** (nur allgemeine) — Preflight, Lifecycle, Stop, Restart, Reset
7. **SQL_Server_Analyze/.github/workflows/** — 4 Lab-spezifische Workflows entfernen
8. **SQL_PerformanceSchulung/Tests/Runtime/** — docker_sqlcmd_proxy.py durch Lab-Adapter ersetzen

### Was in SQL_Server_Analyze BLEIBT

- `Lab/Update-Framework.ps1` (PROJECT_INSTALLER)
- `Lab/Run-LogShipping-Lab.ps1` (PROJECT_WORKLOAD)
- `Lab/Orchestration/` komplett (PROJECT_WORKLOAD)
- `Lab/Validation/Invoke-LabWave*` und `*UpdateFramework*` (PROJECT_PROBE)
- `Lab/Validation/Fixtures/` (PROJECT_PROBE)
- `Lab/Contracts/` — scenario, finding-expectation, evidence, contract-fixture, scenario-runbook Schemas
- `Lab/Scenarios/Core/` und `Infrastructure/LAB-LS-001/` (PROJECT_PROBE)
- `Lab/Scenarios/LEARNING_PATH.md` (PROJECT_WORKLOAD)
- `Lab/Scenarios/Catalog/scenarios.json`, `coverage.csv` (PROJECT_PROBE)

### Was in SQL_PerformanceSchulung BLEIBT

- Alles ausser den 4 Runtime-Adaptern
- `.github/workflows/` bleiben (rufen kuenftig SQL_Server_Lab auf)
