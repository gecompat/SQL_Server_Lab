# Gate-B-Ausführungs-Traceability

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Geltungsbereich | vier Pilotdemos des Gate B |
| Validierter Workflowlauf | `30108023315` |
| Zielplattformen | SQL Server 2019, 2022 und 2025 |
| Compatibility Levels | 150, 160 und 170 |

## Zweck

Dieses Dokument ergänzt die projektweite [Traceability-Matrix](TRACEABILITY_MATRIX.md) um die tatsächliche Ausführungsevidenz der vier Gate-B-Pilotdemos. Es ersetzt die vollständige Curriculum-Traceability nicht. Maßgeblich für die Gate-Entscheidung ist der [Gate-B-Review](../Project_Planning/GATE_B_REVIEW.md).

## Validierte Zuordnung

| Quellenbasis | Claim | Lernziel | Modul / Folienbezug | Demo | Sicherheitsstufe | Testprofil | Runtime-Evidenz |
|---|---|---|---|---|---|---|---|
| `GBSRC-001`, `GBSRC-002`, `GBSRC-012`, `GBSRC-013` | `CLM-037` | `LO-M03-01` | Query Patterns, Folie 37 | `QRY-001` | `GREEN` | `TP-RUN` | je zweimal `PASS` auf SQL Server 2019, 2022 und 2025; Ergebnisequivalenz, Seek/Scan und statementbezogene Logical Reads |
| `GBSRC-003` bis `GBSRC-006` | `CLM-023`, `CLM-024` | `LO-M02-02` | Optimizer und Statistiken, Folien 23–24 | `OPT-002` | `GREEN` | `TP-RUN` | je zweimal `PASS`; Sample-Header, erste Statistikschlüsselspalte, Histogramm, Density Vector und Fullscan-Invarianten |
| `GBSRC-007` bis `GBSRC-009` | `CLM-066` | `LO-M05-02` | Concurrency, Folie 66 | `CON-004` | `YELLOW` | `TP-CON` | je zweimal `PASS`; Head–Middle–Leaf-Kette, zwei unmittelbare Blockerbeziehungen, positive `LCK_M_%`-Waits und blockierungsfreier Vergleich |
| `GBSRC-010` bis `GBSRC-013` | `CLM-030` | `LO-M02-05` | Optimizer und Runtime-Evidenz, Folie 30 | `OPT-013` | `YELLOW` | `TP-PERF` | je zweimal `PASS`; identische 300.000 Zeilen, kleinerer Grant und positiver Sort-Spill bei deaktivierter Table Variable Deferred Compilation, Staging-Vergleich ohne Spill |

## Ausführungsmatrix

| SQL Server | Compatibility Level | Piloten | Wiederholungen je Pilot | vollständige Demoläufe | Ergebnis |
|---|---:|---:|---:|---:|---|
| 2019 | 150 | 4 | 2 | 8 | `PASS` |
| 2022 | 160 | 4 | 2 | 8 | `PASS` |
| 2025 | 170 | 4 | 2 | 8 | `PASS` |
| **Gesamt** | – | **4** | – | **24** | **`PASS`** |

Nach jedem Lauf wurde unabhängig geprüft, dass die markergebundene Testdatenbank nicht mehr vorhanden war. Die Abnahme umfasst deshalb nicht nur die fachliche Evidenz, sondern auch wiederholbares Setup, kontrollierte Ausführung, Mitigation, Vergleich und Cleanup.

## Statusgrenze

Die vier Pilotdemos sind `VALIDATED`, jedoch noch nicht `RELEASED`. Eine Releasefreigabe erfordert zusätzlich die Synchronisierung von Präsentation, Sprecherhinweisen, Teilnehmerunterlagen, Demo-Katalog, konkreten Containerdigests oder CU-Ständen und den vollständigen Gate-D-Kriterien.
