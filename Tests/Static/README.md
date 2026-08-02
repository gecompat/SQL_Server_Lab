# Tests/Static/ – Statische Vertragspruefungen

Die Pruefungen laufen lokal mit PowerShell 7.2 oder neuer und mutieren keine
Container, Datenbanken oder Run-States.

| Skript | Scope | Aufruf |
|---|---|---|
| `Invoke-AllChecks.ps1` | Fuehrt alle statischen Suites isoliert aus und erzwingt deren Exitcodes | `.\Tests\Static\Invoke-AllChecks.ps1` |
| `Invoke-CleanupRecoveryChecks.ps1` | Simulierter Providerfehler, `RECOVERY_REQUIRED`, persistierte Fehlerursache und erfolgreicher Cleanup-Retry | `.\Tests\Static\Invoke-CleanupRecoveryChecks.ps1` |
| `Invoke-PodmanBootstrapChecks.ps1` | Ready-, Start-, Fehler-, Timeout- und Parallelpfade des Podman-Bootstraps ohne echte Runtime | `.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1` |
| `Invoke-DocumentationChecks.ps1` | PowerShell-Syntax, Exporte und Help, JSON-Schemas, Kataloge, Beispielmanifeste, Provider-Metadaten, Links und Statusaussagen | `.\Tests\Static\Invoke-DocumentationChecks.ps1` |
| `Invoke-ManifestBuilderChecks.ps1` | Schema-gesteuerter Builder, semantische Manifestpruefung und atomisches Schreiben | `.\Tests\Static\Invoke-ManifestBuilderChecks.ps1` |
| `Invoke-ReadinessContractChecks.ps1` | SQL-Readiness, interaktives Menue und atomare Portallokation ohne Provider-Mutation | `.\Tests\Static\Invoke-ReadinessContractChecks.ps1` |
| `Invoke-MixedProviderLifecycleChecks.ps1` | ProviderSubRun-State, gruppierter Lifecycle, Cleanup-Zuordnung und Mixed-Provider-Beispiel ohne Provider-Mutation | `.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1` |

Alle Skripte beenden sich bei einem fehlgeschlagenen Vertrag mit einem Exitcode
ungleich null. Native Docker-/Podman-Lifecycle-Tests liegen getrennt unter
[`../Integration/`](../Integration/README.md).

CI-Workflows verwenden `Invoke-AllChecks.ps1`, damit der Exitcode einer
fehlgeschlagenen Suite nicht durch eine spaetere erfolgreiche Suite maskiert
wird.

PSScriptAnalyzer mit einer projektspezifischen Baseline und eigenstaendige
Provider-Interface-Contract-Tests bleiben Erweiterungspunkte; sie sind nicht mit
den vorhandenen Vertragspruefungen gleichzusetzen.
