# Lokaler Validierungsbericht 2026-08-12

| Merkmal | Wert |
|---|---|
| Status | `AUTOMATED_CONTAINER_VALIDATION_PASS_HYPERV_NOT_EXECUTED` |
| Ausgangsstand | `origin/main` bei `e98aaf2` plus Konsolidierungsänderungen |
| PowerShell | 7.6.3 |
| Umgebung | Windows, Docker 29.6.2, Podman 6.0.2 |

## Ergebnis

Der vollständige statische Gate und alle ohne interaktive Freigabe ausführbaren
Container-Abnahmen sind grün. Docker und Podman wurden jeweils separat sowie in
einem gemeinsamen Run geprüft. Hyper-V wurde nicht ausgeführt, weil die aktuelle
PowerShell-Sitzung nicht erhöht ist; ein UAC-Dialog wurde bewusst nicht ausgelöst.

## Statische Prüfung

```text
pwsh -File Tests\Static\Invoke-AllChecks.ps1
=> ALLE STATISCHEN VERTRAGSPRUEFUNGEN: PASS
```

Der Einstieg enthält Cleanup-Audit-, Storage-Migration- und
Versionskatalog-Verträge. PSScriptAnalyzer 1.25.0 prüft ausschließlich den
Quellbaum; ignorierte lokale Release-, State-, Cache- und Runtime-Kopien werden
nicht als zweiter Quellbestand analysiert. Die bestehende projektspezifische
Error-Baseline bleibt unverändert, Warnungen bleiben sichtbar und nicht
blockierend.

## Native Laufzeitprüfung

| Prüfung | Ergebnis | Evidenz |
|---|---|---|
| Docker-Voraussetzung | `PASS` | Docker 29.6.2 erreichbar |
| Podman-Voraussetzung | `PASS` | Podman 6.0.2 erreichbar |
| Docker / SQL Server 2019, 2022 | `PASS` | vollständige Matrix-Lanes erfolgreich |
| Podman / SQL Server 2019, 2022, 2025 | `PASS` | vollständige Matrix-Lanes erfolgreich |
| Docker / SQL Server 2025 | `PASS` | isolierter Lauf 33/33 und abschließender Lifecycle-Gate erfolgreich |
| Docker/Podman parallel | `PASS` | vier parallele Runs mit eindeutigen Ports, State und Cleanup |
| Mixed Docker/Podman | `PASS` | gemeinsamer Run, Status, Stop/Start und Cleanup erfolgreich |
| Project Adapter / Docker / SQL Server 2022 | `PASS` | 10 von 10 Prüfungen erfolgreich |
| Restore / Docker / SQL Server 2022 | `PASS` | Hash-Ablehnung, Restore, Datenprüfung und Cleanup erfolgreich |
| Restore / Podman / SQL Server 2022 | `PASS` | Hash-Ablehnung, Restore, Datenprüfung und Cleanup erfolgreich |
| Abschließende kompakte Matrix | `PASS` | `PASS=4 FAIL=0 SKIP=1`; Docker und Podman SQL Server 2025 |
| Hyper-V | `NOT_EXECUTED` | echte Administrator-Sitzung erforderlich |

Im ersten Docker-/SQL-Server-2025-Lauf der vollständigen Matrix trat einmalig
ein Readiness-Fehler 18456, State 115 auf. Das scopegebundene Cleanup war
erfolgreich. Derselbe Pfad bestand anschließend den isolierten Test, die
parallele Lane und den abschließenden kompakten Matrixlauf. Der Fehler war damit
nicht reproduzierbar und wird nicht als aktuelle Providergrenze ausgewiesen.

## Cleanup und Bestandsschutz

- Alle von dieser Validierung erzeugten Test-Runs wurden scopegebunden entfernt.
- Bereits vor der Validierung vorhandene Benutzer-Labs und deren Container
  wurden erkannt und unverändert belassen.
- Der Bericht enthält keine Passwörter, lokalen Benutzernamen, Run-IDs oder
  Container-IDs.

## Verbleibende Abgrenzung

Der Containerstand ist lokal freigabefähig. Offen bleibt ausschließlich der
aktuelle native Hyper-V-Nachweis in einer erhöhten PowerShell-Sitzung. Der
positive Hyper-V-Lifecycle-Nachweis vom 2026-08-08 bleibt historische Evidenz,
ersetzt aber keinen neuen hostlokalen Lauf für diesen Änderungssatz.
