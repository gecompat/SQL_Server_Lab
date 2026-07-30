# Tests/Static/ – Statische Vertragspruefungen

Die Pruefungen laufen lokal mit PowerShell 7.2 oder neuer und mutieren keine
Container, Datenbanken oder Run-States.

| Skript | Scope | Aufruf |
|---|---|---|
| `Invoke-DocumentationChecks.ps1` | PowerShell-Syntax, Exporte und Help, JSON-Schemas, Kataloge, Beispielmanifeste, Provider-Metadaten, Links und Statusaussagen | `.\Tests\Static\Invoke-DocumentationChecks.ps1` |
| `Invoke-ManifestBuilderChecks.ps1` | Schema-gesteuerter Builder, semantische Manifestpruefung und atomisches Schreiben | `.\Tests\Static\Invoke-ManifestBuilderChecks.ps1` |
| `Invoke-ReadinessContractChecks.ps1` | SQL-Readiness, interaktives Menue und atomare Portallokation ohne Provider-Mutation | `.\Tests\Static\Invoke-ReadinessContractChecks.ps1` |

Alle Skripte beenden sich bei einem fehlgeschlagenen Vertrag mit einem Exitcode
ungleich null. Native Docker-/Podman-Lifecycle-Tests liegen getrennt unter
[`../Integration/`](../Integration/README.md).

PSScriptAnalyzer mit einer projektspezifischen Baseline und eigenstaendige
Provider-Interface-Contract-Tests bleiben Erweiterungspunkte; sie sind nicht mit
den vorhandenen Vertragspruefungen gleichzusetzen.
