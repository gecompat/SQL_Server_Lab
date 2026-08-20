# Lokaler und CI-gestuetzter Validierungsbericht 2026-08-20

| Merkmal | Wert |
|---|---|
| Status | `BATCH_PROVIDER_MATRIX_PASS_HYPERV_SQL_ACCEPTANCE_OPEN` |
| Ausgangsstand | PR #73, Merge-Commit `292c856` auf `origin/main` |
| PowerShell | 7.6.5 |
| Umgebung | Windows, Docker 29.7.2, Podman 6.0.2, Hyper-V |

## Ergebnis

Der providerneutrale Batch-, Queue- und Scheduler-Stand ist fuer Docker,
Podman und Hyper-V real validiert. Die lokale Abnahme erzeugte je zwei
Docker- und Podman-Umgebungen mit SQL Server 2025 sowie zwei serielle
Hyper-V-Slots aus einem vorhandenen unveraenderlichen `OS_SEALED`-Artifact.
Eindeutige Run-IDs, idempotentes Scheduler-Resume, das Ausbleiben doppelter
Runs und scopegebundenes Cleanup wurden fuer alle drei Provider bestaetigt.

Die statischen und nativen GitHub-Gates von PR #73 waren vollstaendig gruen:
Windows- und Ubuntu-Vertraege, Docker, Podman, Mixed Provider, Hyper-V und der
Project Adapter wurden erfolgreich ausgefuehrt. Die reine Regelkorrektur aus
PR #74 bestand danach erneut beide statischen Plattform-Gates.

## Lokale Pruefungen

| Pruefung | Ergebnis | Abgrenzung |
|---|---|---|
| Betroffene statische Vertragssuite | `PASS` | Batch, CI-Strategie, Console UI, Dokumentation, Pester, Privacy, PSScriptAnalyzer und Workflow UI |
| Dokumentationsvertraege | `PASS` | 500 bestanden, 0 fehlgeschlagen |
| Modul- und Exportvertrag | `PASS` | Scheduler-Export und Hilfe konsistent |
| Docker-Batch / SQL Server 2025 | `PASS` | zwei Umgebungen, eindeutige Runs, Resume und Cleanup |
| Podman-Batch / SQL Server 2025 | `PASS` | zwei Umgebungen, eindeutige Runs, Resume und Cleanup |
| Hyper-V-Batch / Windows Server 2025 | `PASS` | zwei Slots, `HyperVHeavy` seriell, Resume und Cleanup |
| Hyper-V-Parent-Artefakt | `PASS` | SHA-256 unveraendert, `OS_SEALED`, read-only, keine Test-VM oder temporaere Batchablage verblieben |

## GitHub-Gates

PR #73 bestand folgende verpflichtende Checks:

- Klassifizierung der betroffenen Tests;
- statische Vertraege auf Windows und Ubuntu;
- Docker / SQL Server 2025;
- Podman / SQL Server 2025;
- gemischter Docker-/Podman-Lifecycle;
- Hyper-V-Generation-2-Lifecycle;
- Project-Adapter-End-to-End;
- aggregierter PR-Gate.

## Cleanup und Bestandsschutz

- Alle durch die Batchpruefungen erzeugten Container, VMs, Child-VHDX-Dateien
  und temporaeren State-Verzeichnisse wurden scopegebunden entfernt.
- Das gemeinsam genutzte `OS_SEALED`-Parent-Artefakt blieb hashidentisch und
  read-only.
- Der Bericht enthaelt keine Secrets, lokalen Identitaeten, Run-IDs,
  Container-IDs oder konkreten privaten Hostpfade.

## Verbleibende Abgrenzung

Dieser Bericht ersetzt den Bericht vom 2026-08-12 als aktueller
Validierungsbefund, hebt dessen historische Ergebnisse aber nicht auf. Die
allgemeine echte Hyper-V-/SQL-2025-Acceptance aus frischer SQL-Installations-
media bleibt getrennt vom nun bestaetigten Hyper-V-Batch-Lifecycle und bis zur
Bereitstellung der hashverifizierten Eval-ISO im Media-Root offen.

Im Batchvertrag bleiben ausserdem echter Prozessabbruch, Manifest-Rerun,
reale Windows-User-Gates und die restliche manuelle Console-Abnahme offen.
