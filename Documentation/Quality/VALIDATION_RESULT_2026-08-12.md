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
| Docker / SQL Server 2025 | `PASS` | isolierter Lauf 33/33 und abschließender Lifecycle-Gate erfolgreich |
| Podman / SQL Server 2025 | `PASS` | isolierter und abschließender Lifecycle-Gate erfolgreich |
| Docker/Podman parallel | `PASS` | vier parallele Runs mit eindeutigen Ports, State und Cleanup |
| Mixed Docker/Podman | `PASS` | gemeinsamer Run, Status, Stop/Start und Cleanup erfolgreich |
| Project Adapter / Docker / SQL Server 2025 | `PASS` | 10 von 10 Prüfungen erfolgreich; enger State-115-Retry wurde ausgeführt |
| Restore / Docker / SQL Server 2025 | `PASS` | Hash-Ablehnung, Restore, Datenprüfung und Cleanup erfolgreich; enger State-115-Retry wurde ausgeführt |
| Restore / Podman / SQL Server 2025 | `PASS` | Hash-Ablehnung, Restore, Datenprüfung und Cleanup erfolgreich; enger State-115-Retry wurde ausgeführt |
| Abschließende kompakte Matrix | `PASS` | `PASS=4 FAIL=0 SKIP=1`; Docker und Podman SQL Server 2025 |
| Hyper-V | `NOT_EXECUTED` | echte Administrator-Sitzung erforderlich |

Während der Initialisierung der SQL-2025-Systemdatenbanken trat bei Docker und
Podman sporadisch der Loginfehler 18456/State 115 auf. Die Diagnose wurde auf
diesen konkreten Logzustand begrenzt; ausschließlich dafür wird der
scopeverifizierte Container genau einmal neu erstellt. Dieser Pfad wurde im
Adapterlauf sowie in beiden Restore-Läufen tatsächlich ausgeführt. Die zweiten
Versuche und das Cleanup waren erfolgreich; alle anderen Readiness-Fehler
bleiben hart fehlschlagend.

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

Für nachfolgende Änderungen gilt SQL Server 2025 als einzige Runtime-
Referenzversion dieses Repositories. Die katalogisierten Versionen 2019 und
2022 bleiben auflösbar, ihre reale Kompatibilitätsmatrix wird jedoch in den
Partnerprojekten SQL Analyze und Toolbelt geführt.
