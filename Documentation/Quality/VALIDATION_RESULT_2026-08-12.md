# Lokaler Validierungsbericht 2026-08-12

| Merkmal | Wert |
|---|---|
| Status | `CONTAINER_VALIDATION_PASS_HYPERV_LIFECYCLE_PASS_SQL_MEDIA_BLOCKED` |
| Ausgangsstand | `origin/main` bei `e98aaf2` plus Konsolidierungsänderungen |
| PowerShell | 7.6.3 |
| Umgebung | Windows, Docker 29.6.2, Podman 6.0.2 |

## Ergebnis

Der vollständige statische Gate und alle ohne interaktive Freigabe ausführbaren
Container-Abnahmen sind grün. Docker und Podman wurden jeweils separat sowie in
einem gemeinsamen Run geprüft. Der erhöhte GitHub-Runner hat den nativen
Hyper-V-Generation-2-Lifecycle bestanden. Die echte SQL-2025-Acceptance konnte
nach grünem Hyper-V-Preflight nicht starten, weil auf dem Runner die erwartete
ISO unter `D:\Lab_Base\SQL\2025\Eval\ISO` fehlt.

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
| Podman / SQL Server 2025 | `PASS` | nativer Collation-Standard: bereit nach 9,4s; Lifecycle und Cleanup erfolgreich |
| Docker/Podman parallel | `PASS` | vier parallele Runs mit eindeutigen Ports, State und Cleanup |
| Mixed Docker/Podman | `PASS` | native Collation: bereit nach 9,4s/10,3s; Status, Stop/Start und Cleanup erfolgreich |
| Project Adapter / Docker / SQL Server 2025 | `PASS` | 10 von 10 Prüfungen erfolgreich; enger State-115-Retry wurde ausgeführt |
| Restore / Docker / SQL Server 2025 | `PASS` | Hash-Ablehnung, Restore, Datenprüfung und Cleanup erfolgreich; enger State-115-Retry wurde ausgeführt |
| Restore / Podman / SQL Server 2025 | `PASS` | Hash-Ablehnung, Restore, Datenprüfung und Cleanup mit nativer Collation erfolgreich |
| Abschließende kompakte Matrix | `PASS` | `PASS=4 FAIL=0 SKIP=1`; Docker und Podman SQL Server 2025 |
| Hyper-V Generation-2-Lifecycle | `PASS` | erhöhter GitHub-Runner; VM/VHDX, Stop/Start, Reconcile und Cleanup |
| Hyper-V / SQL Server 2025 | `BLOCKED` | Preflight PASS; `HYPERV_SQL_MEDIA_NOT_FOUND` für die erwartete Eval-ISO |

Die frühere implizite Custom-Collation `SQL_Latin1_General_CP1_CS_AS` löste in
SQL Server 2025 einen Systemdatenbankumbau aus. Auf Podman blieb dieser auch
nach einem scopegebundenen Retry im Loginzustand 18456/State 115. Der
Produktstandard wurde deshalb auf Microsofts native Containercollation
`SQL_Latin1_General_CP1_CI_AS` korrigiert und `MSSQL_COLLATION` wird nur noch
für explizite Abweichungen gesetzt. Podman und Mixed Provider wurden danach
lokal ohne Retry in rund zehn Sekunden je Instanz bereit. Der enge Einmal-Retry
für ausdrücklich gewählte Custom-Collations bleibt fail-closed.

## Cleanup und Bestandsschutz

- Alle von dieser Validierung erzeugten Test-Runs wurden scopegebunden entfernt.
- Bereits vor der Validierung vorhandene Benutzer-Labs und deren Container
  wurden erkannt und unverändert belassen.
- Der Bericht enthält keine Passwörter, lokalen Benutzernamen, Run-IDs oder
  Container-IDs.

## Verbleibende Abgrenzung

Der Containerstand und der aktuelle native Hyper-V-Lifecycle sind
freigabefähig. Der echte Hyper-V-/SQL-2025-End-to-End-Nachweis bleibt bis zur
Bereitstellung einer hashverifizierten Eval-ISO im dokumentierten Media-Root
blockiert; der automatisierte Runner benötigt keine weitere Codeänderung.

Für nachfolgende Änderungen gilt SQL Server 2025 als einzige Runtime-
Referenzversion dieses Repositories. Die katalogisierten Versionen 2019 und
2022 bleiben auflösbar, ihre reale Kompatibilitätsmatrix wird jedoch in den
Partnerprojekten SQL Analyze und Toolbelt geführt.
