# Tests

## Aktive SQL-Server-unabhängige Prüfungen

Der Workflow `.github/workflows/framework-contracts.yml` ist auf Framework-, Demo-Vertrags- und statische Testpfade begrenzt. Er führt aus:

```bash
python Tests/Static/validate_framework_contracts.py
python Tests/Static/test_result_contract_evaluator.py
python Tests/Static/validate_orchestration_runtime.py
python Tests/Static/test_orchestration_runtime.py
```

Die Prüfungen kontrollieren Pflichtdateien, Statuscodes, Eigentumsmarker, deterministische Generatorregeln, T-SQL-Lexik, Python-Syntax, JSON-Metadaten, Ergebnisverträge, Prozesssteuerung, Safety-Gates, Query-Store- und XE-Verträge sowie Cleanup-Priorität. Die Prozess-Selbsttests verwenden ein synthetisches `sqlcmd`-Ersatzprogramm und benötigen weder Netzwerk noch SQL Server.

## Aktive Framework-Runtime-Matrix

Der Workflow `.github/workflows/framework-sql-matrix.yml` validiert das gemeinsame Framework gegen:

| SQL Server | Major | Compatibility Level | Container |
|---|---:|---:|---|
| 2019 | 15 | 150 | `mcr.microsoft.com/mssql/server:2019-latest` |
| 2022 | 16 | 160 | `mcr.microsoft.com/mssql/server:2022-latest` |
| 2025 | 17 | 170 | `mcr.microsoft.com/mssql/server:2025-latest` |

Der validierte Lauf `30099942191` hat alle drei Matrixjobs erfolgreich abgeschlossen. Geprüft wurden Lifecycle, Preflight, Datengenerator, Messrahmen, Plan-/Statistikevidenz, parallele SQL-Sessions, Query Store, Extended Events, Runtime-Harness und markergeprüftes Cleanup.

## Aktive Gate-B-Pilotmatrix

Der Workflow `.github/workflows/gate-b-pilots.yml` prüft zunächst `Tests/Static/validate_gate_b_pilots.py`. Danach startet er dieselbe SQL-Server-2019/2022/2025-Matrix und führt aus:

```bash
python Tests/Runtime/run_gate_b_pilots.py \
  --container <ephemerer-container> \
  --expected-major <15|16|17>
```

Der validierte Lauf `30108023315` führte folgende Piloten je Version zweimal vollständig über `FWK-010` aus:

| Demo-ID | Sicherheitsstufe | Fokus | Läufe je Version |
|---|---|---|---:|
| `QRY-001` | `GREEN` | SARGability, Seek/Scan und statementbezogene Reads | 2 |
| `OPT-002` | `GREEN` | Statistikheader, Histogramm, Density Vector und Fullscan | 2 |
| `CON-004` | `YELLOW` | Head–Middle–Leaf-Blocking-Chain und blockierungsfreier Vergleich | 2 |
| `OPT-013` | `YELLOW` | Table-Variable-Undergrant, Sort-Spill und Staging-Mitigation | 2 |

Damit wurden insgesamt 24 vollständige Demoläufe ausgeführt. Nach jedem Lauf prüft der Testtreiber unabhängig über `master`, dass die markierte Testdatenbank nicht mehr vorhanden ist. Statische Verträge, alle Runtimejobs und alle Containerentfernungen waren erfolgreich.

## Datenschutz und Laufzeitumgebung

Die Matrizen verwenden pro Job eine ephemere Developer-Instanz ohne Host-Port und ohne persistentes Volume. Das Kennwort wird zur Laufzeit erzeugt, maskiert und nicht in Dateien oder Prozessargumenten gespeichert. Kurzlebige Diagnoseartefakte besitzen eine Aufbewahrungsdauer von drei Tagen und enthalten ausschließlich synthetische Phasen- und Fehlerausgaben.

Details stehen unter [`Tests/Runtime`](Runtime/README.md), im [Framework-Matrixreview](../Documentation/Project_Planning/SQL_SERVER_RUNTIME_MATRIX_REVIEW.md) und im [Gate-B-Review](../Documentation/Project_Planning/GATE_B_REVIEW.md).

## Toolklassifikation

- Die Python-Prüfungen und Frameworkskripte sind User-defined Tools des Projekts.
- Das produktive Runtime-Framework verwendet das externe Microsoft-Tool `sqlcmd`.
- Fehlt `sqlcmd`, wird dies als `SKIP_TOOL_MISSING` und nicht als SQL-Server-Fehler behandelt.

## Nächste Prüfbereiche

- Pilotdemos mit Query Store und Extended Events als zentralen Evidenzpfaden,
- automatisierte Privacy- und Metadatenprüfung,
- Windows- oder OS-spezifische Profile nur bei konkreter Demoabhängigkeit,
- Releasevalidierung mit dokumentierten Containerdigests oder CU-Ständen,
- weitere Demos und Inhaltsartefakte der Welle 2.

Tests und Reports dürfen keine realen Zugangsdaten oder Umgebungsinformationen persistieren. Interaktiv notwendige reale Resultsets sind keine Repository-Artefakte.
