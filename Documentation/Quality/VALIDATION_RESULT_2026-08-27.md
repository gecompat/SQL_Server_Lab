# CLI- und Provider-Validierungsbericht 2026-08-27

| Merkmal | Wert |
|---|---|
| Status | `FULL_CLI_ACCEPTANCE_PASS` |
| Branch-Stand | `codex/full-cli-acceptance-matrix`, Hyper-V-Evidence auf `c000e5a` |
| Plattformen | Windows/Hyper-V, Docker, Podman |
| Containerreferenz | SQL Server 2022 CU18 |
| Windowsreferenz | SQL Server 2025 Enterprise Developer RTM, Build 17.0.1000.7 |

## Ergebnis

Die vertiefte CLI-Akzeptanz ist fuer Docker, Podman und Hyper-V real gruen.
Sie ergaenzt die statischen Vertraege und die bereits bestehenden fokussierten
Runtime-Smokes; sie ersetzt diese nicht. Entsprechend der festgelegten
CU-Strategie wurde nicht jede CU kombiniert, sondern bei beiden
Containerprovidern derselbe repraesentative katalogisierte CU18 ausgefuehrt.
Windows wurde aus einem frischen `OS_SEALED`-Slot installiert; ein zusaetzliches
Windows-CU-Paket war fuer diesen Basisnachweis nicht erforderlich.

## Runtime-Evidence

| Provider | Ergebnis | Ausgefuehrter Umfang |
|---|---|---|
| Docker | [`PASS`, Run 33086787082](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33086787082) | SQL Server 2022 CU18, Chinook, Max Memory, MAXDOP, Cost Threshold, Ad-hoc-Optimierung, zwei TempDB-Volumes, getrennte Daten-/Log-Volumes, Mehrbatch-Skript, Rename, CPU/RAM, Port-Reconcile, Stop/Start/Restart, Cleanup `7/7` |
| Podman | [`PASS`, Run 33088515413](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33088515413) | derselbe fachliche Umfang wie Docker einschließlich realer Podman-Volume-Besitzrechte und Cleanup `7/7` |
| Hyper-V | [`PASS`, Run 33099393670](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33099393670) | frischer Windows-Slot, unbeaufsichtigte OOBE, SQL-2025-Setup, Chinook mit 37 Batches, SQL-Konfiguration, zwei TempDB-VHDX, getrennte Daten-/Log-/Backup-VHDX, Rename, vCPU/RAM, Stop/Start/Restart, Persistenzmarker, Cleanup `7/7` |

Der Windows-Lauf bestaetigte nach dem letzten Start den zuvor geschriebenen
Persistenzmarker. Anschliessend wurden die VM und sechs run-eigene VHDX
entfernt. Eine zusaetzliche Hostpruefung fand weder eine `win-cli-*`-VM noch
ein passendes Laufwerksartefakt; der OS-Slot ist wieder allgemein verfuegbar.

## Lokale und statische Nachweise

| Pruefung | Ergebnis |
|---|---|
| Hyper-V Lab Environment | `PASS`, 31/31 |
| Hyper-V Provider | `PASS`, 59/59 |
| Hyper-V SQL Acceptance Environment | `PASS`, 17/17 |
| Readiness-Vertrag | `PASS` |
| Vollstaendiges statisches Abschluss-Gate | einmal ausgefuehrt; ein Dokumentationsvertrag meldete die umgebrochene `CompleteImage`-Zuordnung |
| Fokussierte Dokumentationssuite nach Korrektur | `PASS`, 547/547 |

Das Voll-Gate wurde gemaess Kostenregel nicht unveraendert wiederholt. Seine
einzige gemeldete Abweichung war die nicht zeilengleiche Formulierung der
Prepared-Image-`CompleteImage`-Zuordnung; nach der Korrektur bestand die direkt
betroffene Suite mit 547 von 547 Pruefungen. Das verpflichtende PR-Gate prueft
den finalen Commit erneut in der zentralen CI.

Der globale Windows-Werkzeugpfad wurde ebenfalls korrigiert. Der offiziell
signierte Python-3.13.15-Installer liegt unter
`D:\Lab_Base\Tools\Python\3.13.15`; `python`, `py -3.13` und `pip` sind ueber
den dauerhaften Benutzer-PATH erreichbar.

## Behobene Runtimeabweichungen

Die Akzeptanzlaeufe deckten mehrere zuvor nur statisch unsichtbare Fehler auf:
Besitzrechte leerer Container-Volumes, nicht persistente SQL-Systemdaten,
ungebundene Readiness nach Lifecycle-Aktionen, Windows-PowerShell-5.1-
Serialisierung und SQL-Verbindungsstrings, stabile Zuordnung mehrerer RAW-
Gastplatten, OOBE-Specialization, Mehrbatch-Dateiausfuehrung sowie die Reihenfolge
von Rename und Ressourcenwechsel. Diese Abweichungen wurden jeweils mit einem
fokussierten Vertrag abgesichert und im naechsten realen Lauf erneut geprueft.

## Ausloesungs- und Kostengrenze

Die teure Runtime-Matrix wird nicht unveraendert jede Nacht wiederholt. Der
Nightly-Orchestrator startet die betroffenen Providerlaeufe nur, wenn sich der
relevante Frameworkstand seit der letzten erfolgreichen Evidence geaendert hat.
Remote Runner sparen lokale CPU-, RAM-, Storage- und Hyper-V-Kapazitaet; sie
reduzieren nicht automatisch den Modell-Tokenverbrauch.
