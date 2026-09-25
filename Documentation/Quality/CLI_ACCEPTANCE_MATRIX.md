# CLI-Akzeptanzmatrix

| Merkmal | Festlegung |
|---|---|
| Stand | 2026-09-25 |
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
| CU-Abdeckung | fest gebundener Referenzstand CU18 | fest gebundener Referenzstand CU18 | kein CU-Zwang; optional nur mit lokal verifiziertem Paket |
| reale Testdatenbank | Chinook, katalogisierter SHA-256 | Chinook, katalogisierter SHA-256 | Chinook, katalogisierter SHA-256 |
| SQL-Systemzustand | run-scoped `/var/opt/mssql`-Volume | run-scoped `/var/opt/mssql`-Volume | Child-VHDX der VM |
| getrennte Daten/Log-Pfade | `/sqldata`, `/sqllog` | `/sqldata`, `/sqllog` | `E:\SQLData`, `L:\SQLLog` auf eigenen VHDX |
| TempDB auf mehreren Datentraegern | `/sqltemp1`, `/sqltemp2` | `/sqltemp1`, `/sqltemp2` | `T:\TempDB`, `U:\TempDB` auf eigenen VHDX |
| Backup-Speicher | eigenes `/sqlbackup`-Volume | eigenes `/sqlbackup`-Volume | `R:\SQLBackup` auf eigener VHDX |
| SQL-Ressourcen | Max Memory, MAXDOP, Cost Threshold, Ad-hoc-Optimierung | gleich | gleich |
| Runtime-Ressourcen | read-only No-op; CPU/RAM und SQL Max Memory live; journalisiertes Port-Recreate | gleich | vCPU/RAM bei ausgeschalteter VM |
| Datenpersistenz | Recreate, erzwungener Rollback auf Original-ID, Stop/Start/Restart | gleich | Ressourcenwechsel, Stop/Start/Restart |
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
| `Get-SqlServerLabHyperVResourcePreview` | Hyper-V-Resource-Binding-, Migration-Acceptance- und Elevation-Suites | reale erhöhte Windows-Legacy-Run-/Parent-/Child-Platzierung, laufende SQL-2022-Legacy-Migration mit zwei SQL-Restarts, erneuter N5-Lauf und allgemeine Parent-Storage-Vorwärts-/Rückmigration belegt |
| `Get-SqlServerLabConnectionCenter`, `Sync-SqlServerLabConnectionCenter`, `Export-SqlServerLabSsmsRegistration` | Connection-Center-Suites | lesender Container-Nachweis und gemeinsame Testumgebungsabnahme |
| `Initialize-SqlServerLabCms`, `Sync-SqlServerLabCms`, `Export-SqlServerLabCmsSyncScript` | CMS-Suites | gemeinsame Sechs-Umgebungen-/CMS-Abnahme |
| `New/Get/Stop-SqlServerLabBatch` | Batch-Vertrag | Zwei-Lab-Batch-Smoke fuer Docker, Podman und Hyper-V-Slots |
| `Get/Move/SetPriority/Suspend/Resume/Stop/Confirm-SqlServerLabOperation`, `Get-SqlServerLabQueue`, `Invoke-SqlServerLabScheduler` | Queue-, Prioritaets-, User-Gate- und Scheduler-Suites | Batch-Smokes fuer beide Containerprovider; Hyper-V-Slot-Batch |
| `Get-SqlServerLabReconcilePlan`, `Invoke-SqlServerLabReconcileAction` | Lifecycle-, Container- und External-Runtime-Reconcile-Suites | native Docker-/Podman-No-op-, Live-, Port-Recreate-, Rollback- und Persistenzabnahme, External-Runtime-Refresh/-Removal sowie Windows-Baseline-Akzeptanz |
| `Invoke-SqlServerLabWorkflowAction` | Workflow-Action-Vertrag | Rename und Ressourcenwechsel in den vertieften Akzeptanzlaeufen |
| `New/Clear/Export-SqlServerLabAutomatedTestEnvironment` | Testumgebungs- und Recovery-Suites | sechs gemeinsam registrierte SQL-Ziele und CMS |
| `Install/Test-SqlServerLabAdapter` | Adapter-Schema und Capability-Gates | GitHub-hosted Adapter-Smoke |
| `Install-SqlServerLab7Zip` | 7-Zip- und Archivhandler-Vertraege | nur fuer ZIP-Samples erforderlich; Chinook benoetigt 7-Zip nicht |
| `Clear-SqlServerLab`, `Get-SqlServerLabCleanupAudit` | Cleanup-, Recovery- und Scope-Suites; interaktiver Audit ruft `-NoWrite` auf und zeigt Findings samt Guidance | Provider-Akzeptanz prueft den engeren rungebundenen Cleanup; globales Clear wird nicht gegen fremde Labs ausgefuehrt |
| `Invoke-SqlServerLabPersistentStorageRemoval` | `Invoke-PersistentStorageRemovalPlanChecks.ps1`, `Invoke-PersistentStorageRemovalExecutorChecks.ps1`, `Invoke-PersistentStorageRemovalExecutorAcceptance.ps1` | Der Plan unterscheidet `EXECUTABLE`, `PLANNED_NOT_EXECUTABLE` und `BLOCKED`; die Runtime-Abnahme belegt Docker und Podman getrennt mit Backup-on-Remove, MDF/NDF/LDF-Package-on-Remove und `BACKUP_AND_PACKAGE` (Backup vor Offline-Schritt) sowie retained Store. Der gleiche Runner belegt `DELETE_WITH_RUN` nur mit öffentlich registriertem `RUN_SCOPED`/`RUN_CLEANUP`-Store, Missing-Volume-Nachweis und detached Katalogabschluss; automatische SHA-256-Nachweise der Artefaktpfade bleiben verpflichtend. |
| `Get-SqlServerLabGeneratedSqlAccess` | Secret-/DPAPI-Vertraege | Windows-SQL-Pfad mit runlokalem SA-Secret |
| `Get-SqlServerLabLlamaCppModel`, `Save-SqlServerLabLlamaCppModel` | Katalogschema, feste Revision/Quelle/Lizenz, Größen-/SHA-256-/GGUF-Prüfung, atomare Veröffentlichung, Cache-Revalidierung sowie interaktives Ausgrauen mit Abhilfe ohne konfiguriertes Lab_Base | kein echter Gigabyte-Download im PR-Gate; der Downloadpfad wird mit synthetischem GGUF und injiziertem Transport vollständig geprüft |
| `Invoke-SqlServerLab` | Menue-, Routing- und Self-Reload-Vertraege; der automatisch erzeugte Befehlszugang deckt jeden Manifestexport exakt einmal ab und zeigt Parametersaetze, Defaults, Typen, Validierungsgrenzen und `WhatIf`; Fallback zeigt `0` auch bei Textfeldern, Attention nennt Abhilfe; die Podman-KI-Erstellung unterscheidet fehlende Installation, unerreichbare Runtime und fehlende Berechtigung vor der Auswahl mit ReasonCode und Abhilfe | interaktive Tastatureingaben bleiben UI-Contract; die mutierenden Zielaktionen laufen ueber dieselben oeffentlichen Fachfunktionen; die Podman-Menüprüfung ist read-only und ersetzt keinen Runtime-Smoke |

## Grenzen und bewusste Nichtziele

- Es werden nicht alle SQL-Hauptversionen mit allen CUs kombiniert. Der
  auf `2022-CU18` begrenzte Container-Akzeptanzparameter beweist Aufloesung, Pull und Start eines
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
gh workflow run runtime-smoke-hyperv.yml --ref <branch> -f mode=sql-configuration-reconcile-acceptance [-f image_artifact_id=<SQL_PREPARED_SEALED-ArtifactId>]
gh workflow run runtime-smoke-hyperv.yml --ref <branch> -f mode=sql-port-reconcile-acceptance [-f image_artifact_id=<SQL_PREPARED_SEALED-ArtifactId>]
gh workflow run runtime-smoke-hyperv.yml --ref main -f mode=sample-manifest-acceptance [-f image_artifact_id=<SQL_PREPARED_SEALED-ArtifactId>]
gh workflow run runtime-smoke-hyperv.yml --ref main -f mode=external-runtime-reconcile-acceptance [-f image_artifact_id=<OS_SEALED-ArtifactId>]
```

Docker und Podman verwenden den gemeinsamen hostweiten Runtime-Lock. Der
Hyper-V-Lauf besitzt einen eigenen Akzeptanz-Mutex; auf dem einzelnen
Self-hosted Runner werden die Jobs zusaetzlich durch die Runner-Queue
serialisiert. Hyper-V gibt seine VM und alle run-eigenen VHDX im `finally`-Pfad
wieder frei. Die Reconcile- und Sample-Manifest-Modi verwenden denselben Workflow- und
Cleanup-Rahmen. Ohne `image_artifact_id` waehlt jeder Runner nur das neueste
verifizierte SQL-2025-`SQL_PREPARED_SEALED`-Artifact; eine angegebene ID wird
vom jeweiligen Runner vor jeder Mutation gegen denselben Vertrag geprueft.

## Ausgefuehrte Evidence vom 2026-08-27

| Provider | Ergebnis | Runtime-Evidence |
|---|---|---|
| Docker | `PASS` | [GitHub Actions 33086787082](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33086787082): SQL Server 2022 CU18, Chinook, SQL-/Containerressourcen, getrennte Daten-/Log-/TempDB-/Backup-Volumes, Reconcile, Lifecycle und Cleanup `7/7` |
| Podman | `PASS` | [GitHub Actions 33088515413](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33088515413): SQL Server 2022 CU18, Chinook, SQL-/Containerressourcen, getrennte Daten-/Log-/TempDB-/Backup-Volumes, Reconcile, Lifecycle und Cleanup `7/7` |
| Hyper-V / Windows | `PASS` | [GitHub Actions 33099393670](https://github.com/gecompat/SQL_Server_Lab/actions/runs/33099393670): frischer Windows-Slot, SQL Server 2025 RTM, Chinook, SQL-/VM-Ressourcen, getrennte Daten-/Log-/TempDB-/Backup-VHDX, Rename, Lifecycle, Persistenz und Cleanup `7/7` |

Die drei Laeufe wurden gezielt fuer den geaenderten Frameworkstand ausgeloest.
Der Hyper-V-Host enthielt nach dem Lauf weder eine `win-cli-*`-VM noch ein
run-eigenes VHDX-Artefakt; der verwendete OS-Slot ist wieder frei.

## Ausgefuehrte Container-Reconcile-Evidence vom 2026-08-29

Der vertiefte CLI-Akzeptanzlauf wurde lokal getrennt mit Docker und Podman gegen
SQL Server 2022 CU18 ausgefuehrt. Beide Laeufe bestätigten denselben Vertrag:
read-only No-op ohne Container-ID-Wechsel, Live-Änderung von CPU, RAM und SQL
Max Memory, absichtlich fehlgeschlagenes Port-Recreate mit Journalstatus
`ROLLED_BACK`, exakte Wiederherstellung der Original-ID und des alten Ports,
anschließend erfolgreiches Recreate mit neuer ID und erst danach entferntem
Original. Datenmarker, Mounts und SQL-Konfiguration blieben über Recreate,
Stop, Start und Restart erhalten; Container und sechs run-eigene Volumes wurden
je Provider vollständig bereinigt. Der davon getrennte Hyper-V-
Mehrgeräte-Nachweis aus Gate N5 wurde am 2026-08-30 ebenfalls real erbracht.

## Ausführbarer N5-Storage-Vertrag

`Tests/Integration/Invoke-HyperVStorageAcceptance.ps1` bindet einen portablen
`SqlServerLab.StorageIntent/1.0` an ein verifiziertes
`SQL_PREPARED_SEALED`-Artifact. Der Runner blockiert vor der VM-Mutation, wenn
die vier TempDB-Datendateien nicht auf mindestens zwei beziehungsweise der im
Intent höheren geforderten Zahl nachweislich getrennter Backing Devices liegen
oder das TempDB-Log keine eigene Selector-/VHDX-Lane hat. Das Referenz-Intent
fordert drei Geräte und verteilt die Dateien round-robin als 2/1/1. Im positiven Pfad
prüft er das `VERIFIED`-Runtime-Receipt nach SQL-Dienstrestart, dateigenaues
CREATE, einen synthetischen Backup/Restore-Roundtrip, Persistenz nach VM-Restart
und den vollständigen rungebundenen VHDX-Cleanup.

Der Vertrag wurde am 2026-08-30 real positiv ausgeführt. Vier TempDB-
Datendateien lagen in 2/1/1-Verteilung auf drei nachweislich getrennten lokalen
Geräten; TempDB-Log, Defaultpfade, Create-Data/-Log, Backup und Restore waren an
ihre verifizierten Lanes gebunden. SQL-Dienstrestart, synthetischer
Backup/Restore-Roundtrip mit Datenmarker, Persistenz nach vollständigem
VM-Restart sowie die Entfernung der VM, der Child-VHDX und aller vier externen
VHDXs waren erfolgreich. Der physische N5-Storage-Nachweis ist damit
abgeschlossen. Mit der realen Legacy-SQL-Migration vom 2026-08-31 ist auch
der priorisierte Hyper-V-Ressourcenroot-Vertrag vollständig belegt und Gate N5
`COMPLETE`.

## Ausführbarer Hyper-V-SQL-Konfigurations-Reconcile-Vertrag

`Tests/Integration/Invoke-HyperVSqlConfigurationReconcileAcceptance.ps1`
erzeugt aus einem verifizierten `SQL_PREPARED_SEALED`-Artifact einen eigenen
SQL-2025-Run. Er prüft den öffentlichen Plan, `WhatIf`, dynamische Live-
Änderung, Trace-Flag-Ownership und -Entfernung bei unverändertem fremdem
Runtime-Flag, den ausschließlichen `MSSQLSERVER`-Restart für einen nicht
dynamischen Wert ohne VM-Neustart, die Rückkehr zum Basis-Desired-State, No-op,
Journal und scopegebundenen Cleanup. Der getrennte Bootstrap erzeugt und
entfernt auch das Prepared-Artifact isoliert und gibt bei Fehlern exakte
Recovery-IDs aus.

Der native GitHub-Actions-Lauf `34754976310` vom 2026-09-13 war auf dem
erhöhten Runner erfolgreich. Er bestätigte das verifizierte Prepared-Artifact,
das gültige Manifest, den isolierten Run und Host-SQL-Zugriff sowie die
initiale dynamische und restartpflichtige Zielkonfiguration. `WhatIf` ließ
bestehendes Journal und Konfiguration unverändert; Live-Änderung,
eigentumsgebundenes Trace-Flag-Add/-Remove bei erhaltenem fremdem Flag,
Live-No-op, der ausschließliche `MSSQLSERVER`-Restart ohne VM-Neustart,
Basis-Desired-State-Konvergenz und Cleanup von VM, VHDX und IPAM-Lease
bestanden. Das ist Runtime-PASS-Evidence für diesen SQL-Konfigurationsvertrag;
der getrennte SQL-Port-Vertrag wird unten nativ belegt; External Runtimes
bleiben davon getrennte `NOT_EXECUTED`-Nachweise.

## Ausführbarer Hyper-V-SQL-Port-Reconcile-Vertrag

`Tests/Integration/Invoke-HyperVSqlPortReconcileAcceptance.ps1` erzeugt aus
einem verifizierten `SQL_PREPARED_SEALED`-Artifact einen eigenen SQL-2025-Run
und darin eine kontrollierte TCP-/Firewall-Drift. Der öffentliche Plan,
`WhatIf`, ausschließlich `MSSQLSERVER`-Restart ohne VM-Neustart,
Connection-State, No-op, Journal und scopegebundener Cleanup sind ausführbar.
Der getrennte Bootstrap erzeugt und entfernt auch das Prepared-Artifact
isoliert und gibt bei Fehlern exakte Recovery-IDs aus.

Der native GitHub-Actions-Lauf `34761955648` vom 2026-09-13 war auf dem
erhöhten Runner erfolgreich. Er bestätigte das verifizierte SQL-2025-Prepared-
Artifact, das gültige Manifest und den isolierten Run sowie den initial
deklarierten Port und Connection-State. Eine isolierte, erreichbare
Alternativport-Drift wurde im read-only Plan als TCP-/Firewall-Drift mit
`MSSQLSERVER`-Restart klassifiziert. `WhatIf` ließ Journal und Portbindung
unverändert; der Reconcile stellte Port und Connection-State mit ausschließlich
einem SQL-Dienstrestart ohne VM-Neustart wieder her. Wiederholte Planung war
No-op, und der scopegebundene Cleanup von VM, VHDX und IPAM-Lease bestand.
Das ist Runtime-PASS-Evidence für diesen SQL-Port-Vertrag; External Runtimes
bleiben getrennte `NOT_EXECUTED`-Nachweise.

## Ausführbarer Hyper-V-External-Runtime-Reconcile-CI-Vertrag

`Tests/Integration/Invoke-HyperVExternalRuntimeReconcileCiAcceptance.ps1` ist
nur über den manuellen `main`-Workflowmodus
`external-runtime-reconcile-acceptance` vorgesehen. Er akzeptiert keinen
bestehenden Run und keine Clone-Quelle. Stattdessen erzeugt er genau einen
SQL-2022-/Windows-2025-Run aus einem katalogisierten Evaluation-`OS_SEALED`-
Artifact, bindet den GitHub-Operationskontext, verwendet für Aktivierung
`EvaluationOnline`/`AllowTemporary` bei weiterhin dauerhaftem `hostOnly` und
ruft anschließend den bestehenden öffentlichen Reconcile-Runner auf. Erfolg,
Fehler nach Erstellung und frühe Teilerstellung führen nur nach Run-/Scope-/
VM-Ownership-Prüfung zum öffentlichen `Remove-SqlServerLab`-Cleanup. Rohpfade,
Transkripte und Evidence werden nicht in GitHub-Ausgaben veröffentlicht. Der
private Runner versieht Fehler zwischen SQL-Medien-Preflight und direktem
Cleanup mit genau einer festen Acceptance-Stage. Bei einem Fehler veröffentlicht
die CI nur den daraus gebildeten
`HYPERV_EXTERNAL_RUNTIME_STAGE_<STAGE>_FAILED`-`PRIMARY_FAILURE_CODE`
beziehungsweise `CLEANUP_FAILURE_CODE`; eine kleine feste Allowlist deckt nur
CI-Grenz- und Cleanupfehler außerhalb des Runners ab. Freitext, unbekannte,
malformierte oder vorgetäuschte Werte werden als `UNCLASSIFIED` ausgegeben. Der
ursprüngliche ErrorRecord bleibt ausschließlich privat am erfassten Fehler;
der erfasste Runnertext wird nie publiziert. Der Workflow lehnt jeden Aufruf
außerhalb von manuellem `main` sichtbar ab. Artefakte werden ohne
Integritätsüberspringung auf OS-Seal, Evaluation, Child-Validierung und
Hash-/Cache-Evidence geprüft; nach dem öffentlichen Cleanup müssen die exakte
VM, alle gebundenen VHDX und die Run-/Scope-gebundene IPAM-Lease nachweislich
fehlen.

Der frühe Lauf `34772015168` erreichte Windows-OOBE und endete anschließend bewusst
vor der SQL-Slot-Installation mit der sicheren Stage `SQL_MEDIA_PREFLIGHT`; VM,
VHDX und IPAM-Lease wurden vollständig entfernt. Nach lokaler Bereitstellung des
vollständigen SQL-Server-2022-Evaluation-Originalmediums unter
`SQL/2022/Eval/ISO/SQLServer2022-x64-ENU.iso` einschließlich SHA-256-Sidecar
bestand der fachliche Reconcile in Lauf `34776120704`. Dessen Cleanup wurde
ausschließlich durch ein zu geringes JSON-Leselimit im SafetyRoot-Reader blockiert;
die gültige Ownership blieb erhalten und der exakt gebundene Recovery-Lauf
`34780328388` bereinigte ihn erfolgreich.

Der vollständige manuelle `main`-Lauf `34780626984` vom 2026-09-13 ist die
positive Runtime-Evidence: Er erzeugte aus einem Windows-2025-Evaluation-
`OS_SEALED`-Artifact einen isolierten SQL-2022-Run, führte den öffentlichen
Plan-, `WhatIf`-, Apply-, No-op- und Removal-Blockade-Vertrag aus und bestätigte
den Python-, R- und Java-External-Runtime- sowie Resource-Governor-Intent über
den gebundenen Runnervertrag. Nach vollständigem VM-Kaltstart prüfte der Runner
Gast- und SQL-Readiness und führte die drei Runtime-Probes erneut aus. Der
scopegebundene Produkt-Cleanup endete mit `CLEANUP_SUCCEEDED (3 Steps, 0 Fehler)`
für exakt VM, VHDX und IPAM-Lease. Diese Evidence gilt nur für SQL-2022
Evaluation auf Windows Server 2025 und diesen isolierten Reconcile-Vertrag;
weitere SQL-/OS-/Providerkombinationen bleiben getrennte Nachweise.

Der initiale SQL-Konfigurations-Reconcile läuft ausschließlich für einen
verifizierten `SQL_PREPARED_SEALED`-Run mit `serverConfig`. Ein `OS_SEALED`-
Run bewahrt den Intent nur im Desired State, bis der External-Runtime-Runner
den SQL-2022-Slot installiert hat. Erst danach plant und repariert der
öffentliche External-Runtime-Pfad; der `ResourceGovernor`-Intent bleibt im
Zielmanifest gebunden. Diese Reihenfolge ist statisch geprüft und ersetzt
keinen erfolgreichen nativen Lauf mit Cleanup: External Runtimes bleiben
`NOT_EXECUTED`.
