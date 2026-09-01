# Tests/Static/ – Statische Vertragspruefungen

Die Pruefungen laufen lokal mit PowerShell 7.2 oder neuer und mutieren keine
Container, Datenbanken oder Run-States.

| Skript | Scope | Aufruf |
|---|---|---|
| `Invoke-AllChecks.ps1` | Fuehrt alle statischen Suites isoliert aus und erzwingt deren Exitcodes | `.\Tests\Static\Invoke-AllChecks.ps1` |
| `Invoke-ImpactedChecks.ps1` | Fuehrt anhand geaenderter Repositorypfade nur die betroffenen Suites aus | `.\Tests\Static\Invoke-ImpactedChecks.ps1 -ChangedPath $paths` |
| `Invoke-CiStrategyChecks.ps1` | Prueft Pfadklassifikation, PR-/Nightly-Trennung und das Verbot redundanter Volltests | `.\Tests\Static\Invoke-CiStrategyChecks.ps1` |
| `Invoke-ActionResultChecks.ps1` | `ActionResult/1.0`, No-op-/Abbruchgrenzen und exakt ein Connection-Center-/CMS-Sync fuer endpunktrelevante Mutationen | `.\Tests\Static\Invoke-ActionResultChecks.ps1` |
| `Invoke-ElevationChecks.ps1` | UAC-Vorschau, Ablehnung, Zustimmung und bereits erhöhte Sitzung ohne vorsorglichen Prozessstart | `.\Tests\Static\Invoke-ElevationChecks.ps1` |
| `Invoke-PortAllocationChecks.ps1` | Read-only-Pruefung expliziter SQL-Hostports mit Besitzer/Grund sowie erneutes Docker-/Podman-Gate innerhalb des atomaren Port-Locks | `.\Tests\Static\Invoke-PortAllocationChecks.ps1` |
| `Invoke-CleanupRecoveryChecks.ps1` | Simulierter Providerfehler, `RECOVERY_REQUIRED`, persistierte Fehlerursache und erfolgreicher Cleanup-Retry | `.\Tests\Static\Invoke-CleanupRecoveryChecks.ps1` |
| `Invoke-PodmanBootstrapChecks.ps1` | Ready-, Start-, Fehler-, Timeout- und Parallelpfade des Podman-Bootstraps ohne echte Runtime | `.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1` |
| `Invoke-LabNetworkChecks.ps1` | Feste, konfigurierbare Docker-, Podman- und Hyper-V-Labnetze, CIDR-Kollisionsschutz sowie Hostzugriffsvertrag | `.\Tests\Static\Invoke-LabNetworkChecks.ps1` |
| `Invoke-MediaRootLayoutChecks.ps1` | Externe Media-Root-Struktur, sichere Einsortierung, SHA-256-Sidecars, Idempotenz und Repository-Pfadgrenze | `.\Tests\Static\Invoke-MediaRootLayoutChecks.ps1` |
| `Invoke-HyperVProviderChecks.ps1` | Hyper-V-Metadaten, Lifecycle-Oberfläche, stabile Zusatz-VHDX-Identität sowie gemockte Gastinitialisierung, Windows-Specialization/Reconnect und SQL-Readiness ohne Credential-Persistenz | `.\Tests\Static\Invoke-HyperVProviderChecks.ps1` |
| `Invoke-HyperVImageRegistryChecks.ps1` | Inhaltsadressierter VHDX-Import, Idempotenz, Generalisierungs-Gate, Auswahl und portables Manifest Lock | `.\Tests\Static\Invoke-HyperVImageRegistryChecks.ps1` |
| `Invoke-HyperVImageBuilderChecks.ps1` | ISO-Integrity, persistenter Build-State, PowerShell-Direct-Sysprep, Credential-Nichtpersistenz, Challenge-gebundene Evidenz und test-only/OS_SEALED-Grenze | `.\Tests\Static\Invoke-HyperVImageBuilderChecks.ps1` |
| `Invoke-HyperVImageOperatorChecks.ps1` | Media-Root-Auflösung, einzelnes SHA-256-Sidecar, Build-Auflistung und Image-Menüvertrag | `.\Tests\Static\Invoke-HyperVImageOperatorChecks.ps1` |
| `Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1` | Unattended OOBE mit Region Deutschland/UI en-US/deutscher Tastatur, erhöhungsgebundener Offline-VHDX-Pfad, DPAPI-Secrets, direkte SQL-Installation und Create/Insert/Backup/Verify/Drop-Abnahme | `.\Tests\Static\Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1` |
| `Invoke-HyperVLegacySqlMigrationBootstrapChecks.ps1` | Isolierter SQL-2022-Clone, garantierter Testgruppen-Restore, absichtliche Legacy-Identität, zwei SQL-Restarts und exakter Erfolgs-Cleanup | `.\Tests\Static\Invoke-HyperVLegacySqlMigrationBootstrapChecks.ps1` |
| `Invoke-DocumentationChecks.ps1` | PowerShell-Syntax, Exporte und Help, JSON-Schemas, Kataloge, Beispielmanifeste, Provider-Metadaten, Links und Statusaussagen | `.\Tests\Static\Invoke-DocumentationChecks.ps1` |
| `Invoke-PSScriptAnalyzerChecks.ps1` | PowerShell-Linting via PSScriptAnalyzer mit projektweiter Baseline (`PSScriptAnalyzerSettings.psd1`) | `.\Tests\Static\Invoke-PSScriptAnalyzerChecks.ps1` |
| `Invoke-ManifestBuilderChecks.ps1` | Schema-gesteuerter Builder, semantische Manifestpruefung und atomisches Schreiben | `.\Tests\Static\Invoke-ManifestBuilderChecks.ps1` |
| `Invoke-HyperVSqlPortReconcileChecks.ps1` | Persistierter Hyper-V-SQL-Portintent, sanitierter Restart-Plan, journalisierte Gast-/Firewall-Reparatur und Recovery-Resume | `.\Tests\Static\Invoke-HyperVSqlPortReconcileChecks.ps1` |
| `Invoke-SampleBaselineRegistryChecks.ps1` | Deterministische `LAB_GENERATED`-Keys, inhaltsadressierte Registrierung, exakte/kompatible Auswahl, Portabilitaet und Quarantaene | `.\Tests\Static\Invoke-SampleBaselineRegistryChecks.ps1` |
| `Invoke-SampleBaselineRuntimeChecks.ps1` | SQL-Checksum-Erzeugung und bevorzugte Wiederverwendung verifizierter Single- und Multi-Output-Container-Baselines | `.\Tests\Static\Invoke-SampleBaselineRuntimeChecks.ps1` |
| `Invoke-PrivacyScannerChecks.ps1` | Scan auf sensitive Dateitypen/Dateinamen, Reparse-Points sowie hart kodierte Geheimnis-/Pfad-/E-Mail-Muster im Repository | `.\Tests\Static\Invoke-PrivacyScannerChecks.ps1` |
| `Invoke-ReleaseReadinessChecks.ps1` | Release-Readiness-Fahrplan: Repo-Map/Validation-Kette, Pflichtartefakte, Changelog-Datumskonsistenz und Static-Workflow-Vertrag | `.\Tests\Static\Invoke-ReleaseReadinessChecks.ps1` |
| `Invoke-ReadinessContractChecks.ps1` | SQL-Readiness, interaktives Menue und atomare Portallokation ohne Provider-Mutation | `.\Tests\Static\Invoke-ReadinessContractChecks.ps1` |
| `Invoke-ReconcileActionContractChecks.ps1` | Executor-Phasen für Reconcile-Aktionen inkl. `WhatIf`, unterstützte/unsupported-Pläne und Leak-Schutz | `.\Tests\Static\Invoke-ReconcileActionContractChecks.ps1` |
| `Invoke-HyperVNetworkReconcileChecks.ps1` | Eigentumsgebundene additive Hyper-V-Netzwerkreparatur, Adaptergrenzen, External-Switch-Freigabe, hostwertfreie Pläne und Journal-Recovery | `.\Tests\Static\Invoke-HyperVNetworkReconcileChecks.ps1` |
| `Invoke-InstanceIntentChecks.ps1` | Providerneutrale Drive-, Network- und Software-Intents mit deklarativer Capability-Evidenz und Privacy-Grenze | `.\Tests\Static\Invoke-InstanceIntentChecks.ps1` |
| `Invoke-SoftwareCatalogChecks.ps1` | Softwarekatalog, SQL-/OS-/Provider-Resolver, Package-/Integrity-Gates, Legacy-Grenze und sanitisiertes Receipt | `.\Tests\Static\Invoke-SoftwareCatalogChecks.ps1` |
| `Invoke-ExternalRuntimeContainerImageChecks.ps1` | Python-/R-/Java-/Kombinations-Image-Key, OCI-/Paket-/JDK-/JAR-Lock-Konsistenz, compilerfreie R-/Java-Zielgrenze, Linux-Java-DDL, ML-EULA-/Artifact-Synchronisierung, Retry-/Kompensationsvertrag, sichere cgroup-/Capability-Grenze, Providerbindung, Retention und sanitisiertes Run-Receipt | `.\Tests\Static\Invoke-ExternalRuntimeContainerImageChecks.ps1` |
| `Invoke-ExternalRuntimeReconcileChecks.ps1` | Additiver External-Runtime-Refresh und eigentumsgebundene Removal-Aktion, Drift-/Leak-Schutz, `WhatIf`, persistente Runtime-Volumes, begrenzter Restart-Retry sowie Journal-, Rollback- und Umschaltreihenfolge | `.\Tests\Static\Invoke-ExternalRuntimeReconcileChecks.ps1` |
| `Invoke-ExternalRuntimeWindowsChecks.ps1` | SHA-256-gebundene Windows-Offlinemedien, deterministischer Gastplan, geschlossene Python-/R-Installation, Hyper-V-State-/Recovery-Vertrag und reale External-Script-Postconditions | `.\Tests\Static\Invoke-ExternalRuntimeWindowsChecks.ps1` |
| `Invoke-MixedProviderLifecycleChecks.ps1` | ProviderSubRun-State, gruppierter Lifecycle, Cleanup-Zuordnung und Mixed-Provider-Beispiel ohne Provider-Mutation | `.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1` |

Alle Skripte beenden sich bei einem fehlgeschlagenen Vertrag mit einem Exitcode
ungleich null. Native Docker-, Podman- und Hyper-V-Lifecycle-Tests liegen getrennt unter
[`../Integration/`](../Integration/README.md).

Das PR-Gate verwendet `Invoke-ImpactedChecks.ps1`. `Invoke-AllChecks.ps1` läuft
gebündelt im täglichen Nightly-Workflow und bei bewusster manueller Abnahme.
Jede gewählte Suite läuft weiterhin in einem isolierten PowerShell-Prozess.

PSScriptAnalyzer ist als eigene statische Suite mit projektspezifischer
Baseline eingebunden. Privacy-Scanner und Release-Readiness-Checks sind aktiv in
`Invoke-AllChecks.ps1` integriert.
