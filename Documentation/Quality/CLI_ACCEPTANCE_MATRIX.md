# CLI-Akzeptanzmatrix

| Merkmal | Festlegung |
|---|---|
| Stand | 2026-08-27 |
| Zweck | nachvollziehbarer Runtime-Nachweis fuer die oeffentliche CLI |
| CU-Strategie | keine Vollmatrix aller CUs; je Containerprovider ein repraesentativer CU |
| Containerreferenz | SQL Server 2022 CU18 (`2022-CU18`) |
| Windowsreferenz | SQL Server 2025 Enterprise Developer Basisinstallation aus verifizierter ISO |
| Ausloesung | gezielt nach Frameworkaenderungen; kein unveraenderter Nightly-Wiederholungslauf |

`PASS` darf erst nach einem tatsaechlich erfolgreichen Lauf eingetragen werden.
Statische Vertragspruefungen und Runtime-Nachweise sind getrennte Evidence.

## Provider- und Datenmatrix

| Nachweis | Docker | Podman | Hyper-V / Windows |
|---|---|---|---|
| echte Provisionierung | `2022-CU18` | `2022-CU18` | frischer `OS_SEALED`-Klon, danach SQL-Setup |
| CU-Abdeckung | ein beliebiger katalogisierter CU: CU18 | ein beliebiger katalogisierter CU: CU18 | kein CU-Zwang; optional nur mit lokal verifiziertem Paket |
| reale Testdatenbank | Chinook, katalogisierter SHA-256 | Chinook, katalogisierter SHA-256 | Chinook, katalogisierter SHA-256 |
| SQL-Systemzustand | run-scoped `/var/opt/mssql`-Volume | run-scoped `/var/opt/mssql`-Volume | Child-VHDX der VM |
| getrennte Daten/Log-Pfade | `/sqldata`, `/sqllog` | `/sqldata`, `/sqllog` | `E:\SQLData`, `L:\SQLLog` auf eigenen VHDX |
| TempDB auf mehreren Datentraegern | `/sqltemp1`, `/sqltemp2` | `/sqltemp1`, `/sqltemp2` | `T:\TempDB`, `U:\TempDB` auf eigenen VHDX |
| Backup-Speicher | eigenes `/sqlbackup`-Volume | eigenes `/sqlbackup`-Volume | `R:\SQLBackup` auf eigener VHDX |
| SQL-Ressourcen | Max Memory, MAXDOP, Cost Threshold, Ad-hoc-Optimierung | gleich | gleich |
| Runtime-Ressourcen | CPU/RAM in-place und Port-Recreate | gleich | vCPU/RAM bei ausgeschalteter VM |
| Datenpersistenz | Reconcile, Stop/Start/Restart | gleich | Ressourcenwechsel, Stop/Start/Restart |
| Cleanup | Container und alle run-eigenen Volumes | gleich | VM, Child-VHDX und alle Zusatz-VHDX |
| ausfuehrbarer Einstieg | `Invoke-ContainerCliAcceptance.ps1 -Provider docker` | `Invoke-ContainerCliAcceptance.ps1 -Provider podman` | `Invoke-HyperVCliAcceptance.ps1` |

## Oeffentliche CLI

| CLI-Funktion(en) | Vertragsnachweis | Runtime-Nachweis |
|---|---|---|
| `New-SqlServerLab`, `Get-SqlServerLab`, `Start-SqlServerLab`, `Stop-SqlServerLab`, `Restart-SqlServerLab`, `Remove-SqlServerLab` | statische Manifest-, Lifecycle- und Reconcile-Suites | alle drei Provider-Akzeptanzlaeufe |
| `New-SqlServerLabDatabase`, `Invoke-SqlServerLabScript` | Parser-, SQL- und Sample-Handler-Checks | getrennte Daten/Log-Dateien, Mehrbatch-Skript und Chinook auf allen drei Providern |
| `Restore-SqlServerLabDatabase` | Restore- und Artifact-Vertraege | dedizierter synthetischer Backup/Restore-Smoke fuer Docker und Podman |
| `New-SqlServerLabManifest`, `Test-SqlServerLabManifest` | Manifest-Builder-, Schema- und Pester-Suites | Manifest-Smoke je Containerprovider ueber die bestehende Smoke-Matrix |
| `Test-SqlServerLabPrerequisite`, `Get-SqlServerLabCatalog`, `Get-SqlServerLabWorkflow` | Readiness-, Katalog- und Workflow-Suites | Provider-Preflight; Katalog und Workflow im Container-Akzeptanzlauf |
| `Get-SqlServerLabConnectionCenter`, `Sync-SqlServerLabConnectionCenter`, `Export-SqlServerLabSsmsRegistration` | Connection-Center-Suites | lesender Container-Nachweis und gemeinsame Testumgebungsabnahme |
| `Initialize-SqlServerLabCms`, `Sync-SqlServerLabCms`, `Export-SqlServerLabCmsSyncScript` | CMS-Suites | gemeinsame Sechs-Umgebungen-/CMS-Abnahme |
| `New/Get/Stop-SqlServerLabBatch` | Batch-Vertrag | Zwei-Lab-Batch-Smoke fuer Docker, Podman und Hyper-V-Slots |
| `Get/Move/SetPriority/Suspend/Resume/Stop/Confirm-SqlServerLabOperation`, `Get-SqlServerLabQueue`, `Invoke-SqlServerLabScheduler` | Queue-, Prioritaets-, User-Gate- und Scheduler-Suites | Batch-Smokes fuer beide Containerprovider; Hyper-V-Slot-Batch |
| `Get-SqlServerLabReconcilePlan`, `Invoke-SqlServerLabReconcileAction` | Lifecycle- und External-Runtime-Reconcile-Suites | Container-Smokes, native Docker-/Podman-External-Runtime-Refresh-Abnahme und Windows-Baseline-Akzeptanz |
| `Invoke-SqlServerLabWorkflowAction` | Workflow-Action-Vertrag | Rename und Ressourcenwechsel in den vertieften Akzeptanzlaeufen |
| `New/Clear/Export-SqlServerLabAutomatedTestEnvironment` | Testumgebungs- und Recovery-Suites | sechs gemeinsam registrierte SQL-Ziele und CMS |
| `Install/Test-SqlServerLabAdapter` | Adapter-Schema und Capability-Gates | GitHub-hosted Adapter-Smoke |
| `Install-SqlServerLab7Zip` | 7-Zip- und Archivhandler-Vertraege | nur fuer ZIP-Samples erforderlich; Chinook benoetigt 7-Zip nicht |
| `Clear-SqlServerLab`, `Get-SqlServerLabCleanupAudit` | Cleanup-, Recovery- und Scope-Suites | Provider-Akzeptanz prueft den engeren rungebundenen Cleanup; globales Clear wird nicht gegen fremde Labs ausgefuehrt |
| `Get-SqlServerLabGeneratedSqlAccess` | Secret-/DPAPI-Vertraege | Windows-SQL-Pfad mit runlokalem SA-Secret |
| `Invoke-SqlServerLab` | Menue-, Routing- und Self-Reload-Vertraege | interaktive Tastatureingaben bleiben UI-Contract; die mutierenden Zielaktionen laufen ueber dieselben oeffentlichen Fachfunktionen |

## Grenzen und bewusste Nichtziele

- Es werden nicht alle SQL-Hauptversionen mit allen CUs kombiniert. Der
  repraesentative Container-CU beweist Aufloesung, Pull und Start eines
  katalogisierten CU-Tags; die Versionsmetadaten bleiben statisch vollstaendig
  zu pruefen.
- Windows-CUs werden nur installiert, wenn ein katalogisiertes, lokales und
  hashverifiziertes Paket vorhanden ist. Die Basisinstallation ist der
  Pflichtnachweis fuer den frischen Windows-Slot.
- `Clear-SqlServerLab` wird nicht als global zerstoerender Runtime-Test gegen
  einen gemeinsam genutzten Host ausgefuehrt. Dessen Scope- und Recoverylogik
  wird statisch geprueft; Runtime-Cleanup bleibt exakt rungebunden.
- Maus-/Tastaturpfade des interaktiven Menues werden nicht mit realen
  Providerressourcen dupliziert. Die dahinterliegenden Fachaktionen werden
  direkt und reproduzierbar getestet.

## Remote-Aufrufe

```powershell
gh workflow run runtime-smoke-docker.yml --ref <branch> -f mode=cli-acceptance
gh workflow run runtime-smoke-podman.yml --ref <branch> -f mode=cli-acceptance
gh workflow run runtime-smoke-hyperv.yml --ref <branch> -f mode=cli-acceptance -f media_root='D:\Lab_Base' -f media_edition=Enterprise
```

Docker und Podman verwenden den gemeinsamen hostweiten Runtime-Lock. Der
Hyper-V-Lauf besitzt einen eigenen Akzeptanz-Mutex; auf dem einzelnen
Self-hosted Runner werden die Jobs zusaetzlich durch die Runner-Queue
serialisiert. Hyper-V gibt seine VM und alle run-eigenen VHDX im `finally`-Pfad
wieder frei.

## Ausgefuehrte Evidence vom 2026-08-27

| Provider | Ergebnis | Runtime-Evidence |
|---|---|---|
| Docker | `PASS` | [GitHub Actions 33086787082](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33086787082): SQL Server 2022 CU18, Chinook, SQL-/Containerressourcen, getrennte Daten-/Log-/TempDB-/Backup-Volumes, Reconcile, Lifecycle und Cleanup `7/7` |
| Podman | `PASS` | [GitHub Actions 33088515413](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33088515413): SQL Server 2022 CU18, Chinook, SQL-/Containerressourcen, getrennte Daten-/Log-/TempDB-/Backup-Volumes, Reconcile, Lifecycle und Cleanup `7/7` |
| Hyper-V / Windows | `PASS` | [GitHub Actions 33099393670](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33099393670): frischer Windows-Slot, SQL Server 2025 RTM, Chinook, SQL-/VM-Ressourcen, getrennte Daten-/Log-/TempDB-/Backup-VHDX, Rename, Lifecycle, Persistenz und Cleanup `7/7` |

Die drei Laeufe wurden gezielt fuer den geaenderten Frameworkstand ausgeloest.
Der Hyper-V-Host enthielt nach dem Lauf weder eine `win-cli-*`-VM noch ein
run-eigenes VHDX-Artefakt; der verwendete OS-Slot ist wieder frei.
