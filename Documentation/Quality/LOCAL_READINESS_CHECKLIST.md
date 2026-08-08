# Lokal-Readiness-Checklist vor jedem Push

Ziel: reproduzierbare, schnelle Einschätzung, ob ein Push bzw. Merge auf `main` sinnvoll ist.

## 1) Repo-Zustand und Commit

- `git status --short`
  - Erwartung: Arbeitsbaum leer (oder nur bewusst mitzuübergebende Dateien).
- `git status --branch --short`
  - Erwartung: keine unerwarteten Divergenzen.
- `git log --oneline -1`
  - Erwartung: Commit-Message und Scope passen zur Änderung.
- Optional für PR-Flow: Push auf Feature-Branch statt direkt auf `main`.

## 2) Baseline-Checks (immer)

- `.\Tests\Static\Invoke-AllChecks.ps1`
  - Erwartung: `ALLE STATISCHEN VERTRAGSPRUEFUNGEN: PASS`
  - Erwartet mindestens bei Änderungen an Skripten, Modulen, Workflows, Tests, READMEs.

## 3) Runtime-Checks (wenn Laufzeit-Änderungen betroffen sind)

- PowerShell **mit Admin-Rechten** starten (für Hyper‑V-Pfade Pflicht).
- Docker/Podman/Hyper‑V Verfügbarkeit prüfen:
  - `Test-SqlServerLabPrerequisite -Provider docker`
  - `Test-SqlServerLabPrerequisite -Provider podman`
  - `Test-SqlServerLabPrerequisite -Provider hyperv`

### Empfohlenes Minimumpaket

- `.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto`
- `.\Tests\Integration\Invoke-SmokeMatrix.ps1`

### Zusätzliche gezielte Prüfung

- `.\Tests\Integration\Invoke-HyperVSmokeTest.ps1`
  - nur in echter, erhöhter PowerShell und wenn Hyper‑V vorhanden.
- `.\Tests\Integration\Invoke-AdapterSmokeTest.ps1`
  - bei Adapter-relevanten Änderungen.
- `.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1`
  - bei gemischten Provider-Szenarien.

## 4) Bekannte lokale Fehlerbilder / Ursachen

- `permission denied while trying to connect to the docker API at npipe:////./pipe/docker_engine`
  - Docker-Daemon ist nicht erreichbar oder User ist nicht berechtigt.
  - Lösung: Docker Desktop starten, Terminal erneut öffnen, ggf. Benutzer in Docker-Gruppen prüfen.
- `Podman nicht erkannt`
  - `podman` nicht im PATH oder nicht installiert.
- `Hyper-V-...echt erhöhte PowerShell-Sitzung (Administrator)`
  - Test war nicht mit echter Elevated Session gestartet.

## 5) Branch-Protection-Meldung verstehen

- Meldung wie `Bypassed rule violations for refs/heads/main` ist kein Testfehler.
- Sie bedeutet, dass ein Push die gesetzte Schutzregel umgangen hat (z. B. direkter Push auf `main` statt PR-Flow).
- Wenn du das vermeiden willst: Änderungen per PR laufen lassen oder Berechtigungseinstellungen anpassen.

