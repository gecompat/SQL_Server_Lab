# Tests/Static/ – Statische Vertragspruefungen

Die Pruefungen laufen lokal mit PowerShell 7.2 oder neuer und mutieren keine
Container, Datenbanken oder Run-States.

| Skript | Scope | Aufruf |
|---|---|---|
| `Invoke-AllChecks.ps1` | Fuehrt alle statischen Suites isoliert aus und erzwingt deren Exitcodes | `.\Tests\Static\Invoke-AllChecks.ps1` |
| `Invoke-CleanupRecoveryChecks.ps1` | Simulierter Providerfehler, `RECOVERY_REQUIRED`, persistierte Fehlerursache und erfolgreicher Cleanup-Retry | `.\Tests\Static\Invoke-CleanupRecoveryChecks.ps1` |
| `Invoke-PodmanBootstrapChecks.ps1` | Ready-, Start-, Fehler-, Timeout- und Parallelpfade des Podman-Bootstraps ohne echte Runtime | `.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1` |
| `Invoke-LabNetworkChecks.ps1` | Feste, konfigurierbare Docker-, Podman- und Hyper-V-Labnetze, CIDR-Kollisionsschutz sowie Hostzugriffsvertrag | `.\Tests\Static\Invoke-LabNetworkChecks.ps1` |
| `Invoke-MediaRootLayoutChecks.ps1` | Externe Media-Root-Struktur, sichere Einsortierung, SHA-256-Sidecars, Idempotenz und Repository-Pfadgrenze | `.\Tests\Static\Invoke-MediaRootLayoutChecks.ps1` |
| `Invoke-HyperVProviderChecks.ps1` | Hyper-V-Metadaten, Lifecycle-Oberfläche, stabile Zusatz-VHDX-Identität sowie gemockte Gastinitialisierung, Windows-Specialization/Reconnect und SQL-Readiness ohne Credential-Persistenz | `.\Tests\Static\Invoke-HyperVProviderChecks.ps1` |
| `Invoke-HyperVImageRegistryChecks.ps1` | Inhaltsadressierter VHDX-Import, Idempotenz, Generalisierungs-Gate, Auswahl und portables Manifest Lock | `.\Tests\Static\Invoke-HyperVImageRegistryChecks.ps1` |
| `Invoke-HyperVImageBuilderChecks.ps1` | ISO-Integrity, persistenter Build-State, PowerShell-Direct-Sysprep, Credential-Nichtpersistenz, Challenge-gebundene Evidenz und test-only/OS_SEALED-Grenze | `.\Tests\Static\Invoke-HyperVImageBuilderChecks.ps1` |
| `Invoke-HyperVImageOperatorChecks.ps1` | Media-Root-Auflösung, einzelnes SHA-256-Sidecar, Build-Auflistung und Image-Menüvertrag | `.\Tests\Static\Invoke-HyperVImageOperatorChecks.ps1` |
| `Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1` | Unattended OOBE mit Region Deutschland/UI en-US/deutscher Tastatur, erhöhungsgebundener Offline-VHDX-Pfad, DPAPI-Secrets, direkte SQL-Installation und Create/Insert/Backup/Verify/Drop-Abnahme | `.\Tests\Static\Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1` |
| `Invoke-DocumentationChecks.ps1` | PowerShell-Syntax, Exporte und Help, JSON-Schemas, Kataloge, Beispielmanifeste, Provider-Metadaten, Links und Statusaussagen | `.\Tests\Static\Invoke-DocumentationChecks.ps1` |
| `Invoke-ManifestBuilderChecks.ps1` | Schema-gesteuerter Builder, semantische Manifestpruefung und atomisches Schreiben | `.\Tests\Static\Invoke-ManifestBuilderChecks.ps1` |
| `Invoke-ReadinessContractChecks.ps1` | SQL-Readiness, interaktives Menue und atomare Portallokation ohne Provider-Mutation | `.\Tests\Static\Invoke-ReadinessContractChecks.ps1` |
| `Invoke-ReconcileActionContractChecks.ps1` | Executor-Phasen für Reconcile-Aktionen inkl. `WhatIf`, unterstützte/unsupported-Pläne und Leak-Schutz | `.\Tests\Static\Invoke-ReconcileActionContractChecks.ps1` |
| `Invoke-MixedProviderLifecycleChecks.ps1` | ProviderSubRun-State, gruppierter Lifecycle, Cleanup-Zuordnung und Mixed-Provider-Beispiel ohne Provider-Mutation | `.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1` |

Alle Skripte beenden sich bei einem fehlgeschlagenen Vertrag mit einem Exitcode
ungleich null. Native Docker-, Podman- und Hyper-V-Lifecycle-Tests liegen getrennt unter
[`../Integration/`](../Integration/README.md).

CI-Workflows verwenden `Invoke-AllChecks.ps1`, damit der Exitcode einer
fehlgeschlagenen Suite nicht durch eine spaetere erfolgreiche Suite maskiert
wird.

PSScriptAnalyzer mit einer projektspezifischen Baseline und eigenstaendige
Provider-Interface-Contract-Tests bleiben Erweiterungspunkte; sie sind nicht mit
den vorhandenen Vertragspruefungen gleichzusetzen.
