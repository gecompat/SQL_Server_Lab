# Validierungsergebnis vom 2026-07-27

## Geprüfter Stand

- Branch: `main`
- Stand nach Menü-, Readiness-, Matrix- und atomarer Portallokationsreparatur
- Remote Runner: `Key18_Lab`
- Runnerlabels:
  - Docker: `self-hosted`, `SQL_Lab`, `Docker`
  - Podman: `self-hosted`, `SQL_Lab`, `Podman`
- PowerShell auf dem Runner: `7.6.4`

## Gesamtergebnis

| Bereich | Ergebnis |
|---|---|
| statische Dokumentations- und Modulprüfung | `PASS` |
| Readiness-, Menü- und Portvertrag | `PASS` |
| Docker SQL Server 2019 | `PASS` |
| Docker SQL Server 2022 | `PASS` |
| Docker SQL Server 2025 Lifecycle | `PASS` |
| Docker parallele Runs | `PASS` |
| Podman SQL Server 2019 | `PASS` |
| Podman SQL Server 2022 | `PASS` |
| Podman SQL Server 2025 Lifecycle | `PASS` |
| Podman parallele Runs | `PASS` |

## Statische Prüfungen

Remote ausgeführt wurden:

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-ReadinessContractChecks.ps1
```

Die Prüfungen umfassen unter anderem:

- PowerShell-Parser und Modulimport;
- Exportvertrag;
- JSON-, Schema-, Provider- und Dokumentationskonsistenz;
- SQL- und Datenbank-Readiness;
- Podman-Windows-Diagnosehinweis;
- Schutz vor Selbst-Neuladung des interaktiven Menüs;
- Ausschluss eines fälschlich angebotenen, noch nicht implementierten Hyper-V-Providers;
- runtimeübergreifende Portermittlung;
- hostweiten Portallokations-Lock;
- automatische Wiederholung bei einem vom Runtime-Backend erst beim Binden erkannten Portkonflikt.

Ergebnis: `PASS`.

## Docker Remote-Smoke-Test

Workflow:

```text
.github/workflows/runtime-smoke-docker.yml
```

Ausgeführt wurde:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider docker `
    -FullMatrix `
    -IncludeParallel
```

Ergebnis:

```text
Discovery docker   PASS
Lifecycle docker 2025 PASS
Matrix docker 2019 PASS – Major 15
Matrix docker 2022 PASS – Major 16
Parallel docker mixed PASS – 2 Runs, eindeutige Ports/States, isolierter Cleanup

PASS=5 FAIL=0 SKIP=0
Dauer=53,6s
```

Der vollständige Lifecycle umfasste:

```text
Provisionierung
→ Datenbankerstellung
→ SQL-Skript
→ Restart
→ Persistenzprüfung
→ Stop
→ Start
→ Cleanup
```

## Podman Remote-Smoke-Test

Workflow:

```text
.github/workflows/runtime-smoke-podman.yml
```

Ausgeführt wurde:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider podman `
    -FullMatrix `
    -IncludeParallel
```

Ergebnis:

```text
Discovery podman   PASS
Lifecycle podman 2025 PASS
Matrix podman 2019 PASS – Major 15
Matrix podman 2022 PASS – Major 16
Parallel podman mixed PASS – 2 Runs, eindeutige Ports/States, isolierter Cleanup

PASS=5 FAIL=0 SKIP=0
Dauer=109,8s
```

Podman unter Windows benötigt auf dem geprüften Host eine funktionierende Localhost-Weiterleitung über WSL Mirrored Networking. Die Konfiguration und Diagnose sind unter `Documentation/HowTo/PODMAN_WINDOWS_NETWORKING.md` beschrieben.

## Parallelitätsbefund und Reparatur

Ein früher Remote-Lauf deckte eine echte Race Condition auf: Zwei parallele Provisionierungen konnten denselben zunächst freien Port auswählen, bevor die Runtime den ersten Port gebunden hatte.

Die Reparatur umfasst:

- einen hostweiten, prozessübergreifenden Mutex für Portsuche und Runtime-Bindung;
- gemeinsame Ermittlung belegter Ports aus aktiven TCP-Listenern, Docker und Podman;
- erneute Portwahl, wenn Docker oder Podman einen Konflikt erst beim tatsächlichen Bindungsschritt meldet;
- Entfernung eines dabei teilweise angelegten Containers vor dem nächsten Versuch.

Der anschließende Docker- und Podman-Paralleltest war erfolgreich.

## Interaktives Menü

Der Fehler, bei dem `Invoke-SqlServerLab` das laufende Modul innerhalb der eigenen Ausführung mit `Import-Module -Force` entlud, wurde entfernt. Der Menüstart wurde anschließend manuell geprüft; Banner und Menü waren sichtbar. Der Vertrag gegen eine erneute Selbst-Neuladung ist zusätzlich statisch abgesichert.

Eine vollständige manuelle Bedienprüfung aller Menüaktionen bleibt eine optionale Benutzeroberflächen-Abnahme. Die zugrunde liegenden Cmdlets und Lifecycle-Pfade sind durch die Runtime-Smoke-Tests abgedeckt.

## CI-Ausführung

Runtime-Smoke-Tests laufen nicht bei jedem Push. Sie sind auf folgende Auslöser begrenzt:

- `workflow_dispatch`;
- relevante Pull Requests gegen `main`.

Damit werden umfangreiche Runtimeprüfungen gezielt ausgeführt und nicht durch reine Dokumentations- oder Zwischencommits vervielfacht.

## Freigabe

Der Docker-/Podman-Container-Core ist für die Nutzung durch `SQL_Server_Analyze` und `SQL_PerformanceSchulung` freigegeben.

Weiterhin nicht als implementiert nachgewiesen sind insbesondere:

- Hyper-V;
- gemischte Provider innerhalb eines einzelnen Runs;
- alle in `Documentation/Quality/KNOWN_LIMITATIONS.md` ausdrücklich genannten Grenzen.
