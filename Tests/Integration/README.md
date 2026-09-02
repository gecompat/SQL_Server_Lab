# Tests/Integration/ – Integration Smoke-Test

End-to-End-Test des gesamten Lab-Lifecycles.

## Invoke-SmokeTest.ps1

| Parameter | Default | Beschreibung |
|---|---|---|
| `-SaPassword` | SmokeTest_Pwd1! | SA-Passwort (SecureString) |
| `-Version` | 2025 | SQL-Server-Version |
| `-Provider` | auto | docker, podman, hyperv oder auto (erkennt verfuegbare Container-Runtimes; bei `hyperv` wird der native Hyper-V-Smoke-Test ausgeführt) |
| `-KeepOnFailure` | false | Container bei Fehler behalten (Debugging) |

## Testschritte (T1-T9)

1. Modul-Import + Provider-Funktionen
2. Resource Assessment (ALLE installierten Runtimes)
3. New-SqlServerLab
4. New-SqlServerLabDatabase (2 Data Files)
5. Invoke-SqlServerLabScript (GO-Batches)
6. Get-SqlServerLab (Live-Status)
7. Stop-SqlServerLab
8. Start-SqlServerLab
9. Remove-SqlServerLab

`hyperv` ist kein Container-Lifecycle und wird hier nur als Ziel für den dedizierten
`Invoke-HyperVSmokeTest.ps1` unterstützt.

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider hyperv
```

## Aktueller lokaler Nachweis (2026-08-12)

```text
Invoke-AllChecks.ps1                              => PASS
Invoke-SmokeMatrix.ps1 / Docker / SQL Server 2025 => PASS (*)
Invoke-SmokeMatrix.ps1 / Podman / SQL Server 2025 => PASS
Invoke-SmokeTest.ps1 / Docker / SQL Server 2025   => 33/33 PASS
Invoke-SmokeTest.ps1 / Podman / SQL Server 2025   => 33/33 PASS
Invoke-AdapterSmokeTest.ps1 / Docker / SQL 2025   => 10/10 PASS
Invoke-RestoreSmokeTest.ps1 / Docker / SQL 2025   => PASS
Invoke-RestoreSmokeTest.ps1 / Podman / SQL 2025   => PASS
Invoke-MixedProviderSmokeTest.ps1                 => PASS
Invoke-SmokeMatrix.ps1 -Provider all (Abschluss)  => PASS=4 FAIL=0 SKIP=1
Invoke-HyperVSmokeTest.ps1 / GitHub Runner        => PASS
Fresh Hyper-V SQL 2025 Acceptance                 => BLOCKED (Eval-ISO fehlt im Media-Root)
```

`(*)` Reguläre Gates verwenden Microsofts native Containercollation
`SQL_Latin1_General_CP1_CI_AS`. Eine ausdrücklich abweichende Collation kann
einen längeren Systemdatenbankumbau auslösen; nur State 115 erhält einen
scopegebundenen Einmal-Retry und schlägt bei Wiederholung geschlossen fehl.

SQL_Server_Lab prüft als Core-Referenz ausschließlich SQL Server 2025. Die
Mehrversions-Abnahme liegt bei SQL Analyze und Toolbelt.

Der vollständige Befund und die Fehlerabgrenzung stehen im
[Validierungsbericht vom 2026-08-12](../../Documentation/Quality/VALIDATION_RESULT_2026-08-12.md).

## Vorheriger lokaler Nachweis (2026-08-08)

```text
Invoke-SmokeTest.ps1 -Provider docker   => 33/33 PASS, 0 FAIL
Invoke-SmokeTest.ps1 -Provider podman   => 33/33 PASS, 0 FAIL
Invoke-SmokeTest.ps1 -Provider hyperv   => PASS (Hyper-V-Lifecycle)
Invoke-SmokeMatrix.ps1                 => PASS=5 FAIL=0 SKIP=0
```

## .gitignore

`smoke-test-query.sql` wird waehrend des Tests erzeugt und geloescht.
Bei Abbruch bleibt sie liegen → .gitignore verhindert Commit.

## Invoke-ContainerInstanceStoreAcceptance.ps1

Der PSR-005-Nachweis läuft für Docker und Podman getrennt. Er erzeugt einen
test-eigenen SQL-Systemstore mit stabiler Storage-ID, bestätigt nach einem
kontrollierten Container-Recreate sowohl ein Serverobjekt als auch eine
Benutzerdatenbank, klont den detached Store read-only und digestverifiziert und
prüft dieselben Daten live im Clone. Container, Quell- und Zielvolume sowie das
lokale Journal werden im garantierten Cleanup entfernt.

```powershell
.\Tests\Integration\Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider podman
```

## Invoke-ContainerRuntimeScopeAcceptance.ps1

Der gemeinsame PSR-001-/PSR-006-Nachweis inspiziert den aktiven Docker-Context
und die aktive Podman-Connection/Machine ausschließlich read-only. Er validiert
den sanitisierten `SqlServerLab.ContainerRuntimeScope/1.0`-Vertrag, löst die
lokalen VHDX- und Konfigurationsdateien hostseitig auf und prüft die
normalisierten Image-, Container-, Volume- und Build-Cache-Klassen. Container,
Volumes, Context-/Connection-Auswahl und Machines werden vor und nach der
Inspektion verglichen. Engine, Machine, physisches Backing und Hostdefaults
werden weder verändert noch als Lab-Eigentum ausgegeben.

```powershell
.\Tests\Integration\Invoke-ContainerRuntimeScopeAcceptance.ps1
```

## Invoke-MixedProviderSmokeTest.ps1

Der Mixed-Provider-Smoke-Test benötigt gleichzeitig erreichbares Docker und
Podman. Er provisioniert das Beispiel `example-mixed-provider-lab.json` mit
zwei kompakten SQL-Server-Instanzen, prüft Status, Stop, Start und Cleanup.
State und synthetisches SA-Passwort werden ausschließlich temporär erzeugt.

Ist Podman installiert, aber seine Machine gestoppt, startet
`Initialize-PodmanRuntime.ps1` bevorzugt `podman-machine-default` automatisch
und wartet begrenzt auf `podman info`. Das Skript erzeugt keine neue Machine
und ändert keine Connection-Auswahl.

```powershell
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
```

## Invoke-BatchWorkflowSmokeTest.ps1

Der Batch-Smoke ist der reale Gegenpart zu
`Invoke-BatchWorkflowChecks.ps1`. Er provisioniert über einen expliziten
Docker- oder Podman-Provider zwei SQL-Server-2025-Umgebungen, verarbeitet die
persistente Queue mit zwei Workern, prüft eindeutige Runs und einen
idempotenten zweiten Scheduler-Lauf und führt danach den scopegebundenen
Batch-Cleanup aus.

Der Batch-State enthält ausschließlich den Namen einer
`SQL_SERVER_LAB_SECRET_*`-Prozessvariable. Der Test erzeugt den Secret-Wert
temporär, vererbt ihn an die Worker und stellt die vorherige Prozessumgebung im
`finally`-Block wieder her.

```powershell
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 `
    -Provider hyperv `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

Der Hyper-V-Pfad bindet das vorhandene immutable Artefaktverzeichnis über eine
temporäre NTFS-Junction in den isolierten Test-State ein. Er kopiert oder
verändert das Parent nicht und entfernt nach dem Lauf beide VMs, Child-VHDX,
die Junction und den temporären State. Vor dem rekursiven Temp-Cleanup wird
explizit geprüft, dass das Ziel tatsächlich ein Reparse Point ist.

## Invoke-BatchUserGateAcceptance.ps1

Die reale Windows-User-Gate-Abnahme erzeugt aus einem vorhandenen
`OS_SEALED`-Artefakt genau einen Hyper-V-Windows-Slot. Sie prüft, dass ein
read-only Probe ausschließlich `CandidateSatisfied` meldet, Scheduler-Reruns
keinen Step oder Receipt vorziehen und eine Bestätigung ohne verifiziertes
Credential fail-closed bleibt. Nach testlokaler OOBE-Injektion in das
operationseigene Child-VHDX verifiziert sie ein temporäres Credential über
PowerShell Direct, erwartet genau ein `UserGateConfirmed`-Receipt und den
vollständigen Batchabschluss.

```powershell
.\Tests\Integration\Invoke-BatchUserGateAcceptance.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

Der Offline-Mount des Child-VHDX benötigt eine erhöhte Sitzung. Das immutable
Parent wird nur über eine kontrollierte read-only Junction eingebunden. VM,
Child-VHDX, Junction, temporärer State und das nur im Prozess gehaltene Secret
werden im `finally`-Pfad scopegebunden entfernt.

## Invoke-RestoreSmokeTest.ps1

Der Restore-Smoke-Test erzeugt im Lab eine kleine synthetische Datenbank mit
drei Datensaetzen, erstellt daraus ein temporaeres `.bak` und stellt es ueber
`Restore-SqlServerLabDatabase -RunId` unter neuem Namen wieder her. Er prueft
SHA-256-Ablehnung, `RESTORE FILELISTONLY`, `WITH MOVE`, Providerbindung,
ONLINE-Status, Inhalt und Cleanup. Es werden keine externen Backups verwendet.

```powershell
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

## Invoke-BackupLibraryCrossProviderAcceptance.ps1

Die PSR-008-Abnahme erstellt ein checksum-verifiziertes, inhaltsadressiertes
Backup in einer temporären registrierten `Lab_Data`-Bibliothek, entfernt die
Docker-Quelle und restauriert das Backup nach `RESTORE VERIFYONLY` in Podman.
Ein sanitisiertes Inhaltsdigest wird vor und nach dem Providerwechsel verglichen
und als Restore-Evidence registriert. Linux-Container werden dabei ausdrücklich
nicht als FILESTREAM-fähig ausgewiesen. Da die aktuelle Provider-Matrix außer
Hyper-V/Windows keinen FILESTREAM-fähigen Provider enthält, ist ein
Cross-Provider-FILESTREAM-Lauf `NOT_APPLICABLE` und kein offener Ersatztest.

```powershell
.\Tests\Integration\Invoke-BackupLibraryCrossProviderAcceptance.ps1
```

## Invoke-DatabasePackageSqlAcceptance.ps1

Die PSR-009-Abnahme benötigt eine erhöhte Windows-PowerShell und eine lokale
SQL-Server-2025-Instanz mit effektiv aktiviertem FILESTREAM. Sie erzeugt nur
zufällig benannte Testressourcen, inventarisiert MDF/NDF/LDF/FILESTREAM,
detached die Quelle sauber, publiziert das vollständige Hashpaket und attached
eine unabhängige Kopie. Inhalt, Pfade, Journal und Cleanup werden real geprüft.
Alte test-eigene `sql-lab-psr009-*`-Reste werden unter einem globalen Lock vor
dem Lauf bereinigt.

```powershell
# in einer erhöhten PowerShell
.\Tests\Integration\Invoke-DatabasePackageSqlAcceptance.ps1
```

## Invoke-HyperVDatabasePackageAttachAcceptance.ps1

Die Hyper-V-Abnahme benötigt einen laufenden verwalteten SQL-2025-Run oder ein
verifiziertes SQL-2025-Prepared-Artifact sowie die tatsächlichen Hyper-V-
Hostrechte; ein lokales Administrator-Rollenbit ist kein Ersatz für diesen
Capability-Probe. Ohne `-RunId` erstellt sie genau einen isolierten Run, detached darin
eine synthetische MDF/NDF/LDF-Datenbank, publiziert die kopierten Dateien in
einem temporären `Lab_Data`-Root und verwendet anschließend ausschließlich
`DatabasePackageId`, `RunId` und `InstanceId`. Der Zielpfad wird live aus SQLs
Default-Data-Verzeichnis gebunden. WhatIf, PowerShell-Direct-Kopie,
Hashverifikation im Gast, Online-/Inhalts-Postcondition, Journal und Cleanup
werden real geprüft. Der getrennte lokale Windows-SQL-Runner bleibt der native
FILESTREAM-Inhaltsnachweis.

```powershell
# mit Hyper-V-Hostrechten
.\Tests\Integration\Invoke-HyperVDatabasePackageAttachAcceptance.ps1 `
    -RunId '<laufender-verwalteter-sql-2025-run>'
```

## Invoke-HyperVSmokeTest.ps1

Der Hyper-V-Smoke-Test prüft Image-Registry und Lifecycle-Grundlage auf einem
Windows-Host mit Hyper-V. Er registriert eine kleine synthetische read-only
Parent-VHDX, erzeugt eine Generation-2-VM mit Differencing Child und Secure
Boot sowie zwei run-lokalen SCSI-Zusatz-VHDX für SQL-Data und SQL-Log, startet
und stoppt sie und prüft DiskIdentifier sowie scopegebundenen Cleanup. Da die
synthetische VM kein Windows enthält, führt der Test keine Gastformatierung aus;
diese Orchestrierung wird in den statischen Providerchecks gemockt. Dasselbe
gilt für Windows-Specialization, Reboot/Reconnect und SQL-Readiness. Zusätzlich
prüft er einen synthetischen Windows-Image-Build-Plan samt Generation-2-/DVD-
Builder, buildgebundener Generalisierungsevidenz, Resume, immutable Registry-
Publikation als `LIFECYCLE_TEST_ONLY` und Cleanup. Er beweist zusätzlich, dass
synthetische Medien nicht zu `OS_SEALED` eskalieren können. Er installiert weder
Betriebssystem noch SQL Server und verwendet kein Netzwerk. Weil der native
Test eine leere synthetische VHDX nutzt, fuehrt er kein echtes Gast-Sysprep aus;
diese Orchestrierung wird durch die statischen Mock-Vertraege geprueft und ist
fuer synthetische Medien in der Runtime explizit gesperrt.

```powershell
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
```

## Invoke-HyperVTestDatabaseReconcileAcceptance.ps1

Der erhöhte native Runner verwendet ausschließlich ein hashverifiziertes
`SQL_PREPARED_SEALED`-Artifact und erzeugt daraus einen neuen isolierten
Manifest-Run. Er legt eine nicht vom Sample-Receipt beanspruchte Schutzdatenbank
an und führt anschließend über die öffentlichen Cmdlets den Zyklus read-only
Plan, `WhatIf`, Chinook-Addition, No-op, eigentumsgebundene Entfernung und
erneuten No-op aus. Nach einem vollständigen VM-Restart muss die Schutzdatenbank
unverändert vorhanden sein. Der Erfolgs-Cleanup entfernt Run, VM und alle
run-eigenen VHDX; `-KeepOnFailure` lässt Journal und Run für den expliziten
Recovery-Pfad stehen.

```powershell
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
```

Fehlt ein dauerhaftes Prepared-Artifact, kann der isolierte Bootstrap zunächst
`Invoke-HyperVSqlPreparedImageAcceptance.ps1 -RetainPreparedArtifact` verwenden.
Artifact-ID und testlokaler State Root werden danach explizit an diesen Runner
übergeben und nach erfolgreicher Abnahme über die Image Registry entfernt.
Der reproduzierbare Wrapper führt genau diese Übergabe samt strengem Cleanup in
einer erhöhten Sitzung automatisch aus:

```powershell
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptanceBootstrap.ps1 `
    -MediaRoot D:\Lab_Base
```

## Invoke-HyperVWindowsGeneralizeAcceptance.ps1

Dieser reale positive Image-Factory-Nachweis verwendet die Betriebssystem- und
Lizenzmetadaten einer veröffentlichten `OS_SEALED`-Referenz, kopiert diese VHDX
aber bewusst nicht: Eine bereits generalisierte Baseline ist wegen des
begrenzten Windows-Rearm-Vertrags keine zulässige Generalize-Testquelle. Der
Runner installiert stattdessen Windows Server 2025 Standard Evaluation mit
Desktop Experience aus dem passenden SHA-256-Sidecar-verifizierten ISO auf
einer neuen eigenständigen Builder-VHDX. Ein testlokales Antwort-ISO steuert
Setup und OOBE und wird zusammen mit dem Credential vor Sysprep entfernt.

Danach durchläuft der Runner die produktiven Confirm-, Generalize- und Publish-
Funktionen. Er verlangt Sysprep-Exitcode 0,
`IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, hashgebundene PowerShell-Direct-
Evidence, eine testlokale immutable `OS_SEALED`-Publikation und vollständigen
VM-/VHDX-/State-Cleanup. Die Referenz und die produktive Registry bleiben
unverändert.

```powershell
.\Tests\Integration\Invoke-HyperVWindowsGeneralizeAcceptance.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

## Invoke-TestEnvironmentGroupLifecycle.ps1

Dieser native Nachweis verwendet ausschließlich die öffentliche geschützte
Gruppen-API. Er startet alle registrierten Docker-, Podman- und Hyper-V-
Mitglieder, fordert SQL-Readiness und einen vollständigen `READY`-Export.
Danach stoppt er alle Mitglieder nicht-destruktiv und prüft
`runtimeStatus = STOPPED` sowie den fail-closed Gesamtstatus `INCOMPLETE`.
Im garantierten `finally`-Cleanup stellt er die persistente Gruppe wieder bis
`READY` bereit. Registrierungs- und Providerbindungen müssen unverändert bleiben.

```powershell
.\Tests\Integration\Invoke-TestEnvironmentGroupLifecycle.ps1
```

Das Skript löscht weder Runs, Secrets, Registrierungen noch VHDX-Dateien und
gibt keine Zugangsdaten oder vollständigen Connection Strings aus.

## Invoke-HyperVLegacySqlMigrationBootstrap.ps1

Dieser erhöhte HVR-008-Runner erzeugt aus genau einem bereiten geschützten
Windows-SQL-2022-Slot einen isolierten, eigenständigen Legacy-Kandidaten. Die
geschützte Gruppe wird nur für die konsistente VHDX-Kopie gestoppt; der Klon
erhält vor ihrem garantierten Wiederanlauf eine eigene deterministische
Lab-IP. Danach migriert der bestehende Acceptance-Kern VM-Konfiguration,
Paging, Snapshots und VHDX in den registrierten Default-Data-Root, übernimmt
die Legacy-SQL-Identität erst nach Live-Probe und verlangt zwei vollständige
Gast-/SQL-Restartzyklen.

```powershell
.\Tests\Integration\Invoke-HyperVLegacySqlMigrationBootstrap.ps1
```

Nur ein vollständig grüner Lauf entfernt Kandidat und temporären Legacy-State.
Bei einem Fehler bleibt der exakt benannte Kandidat für den journalisierten
Recovery-Pfad erhalten; die geschützte Testgruppe wird unabhängig davon wieder
bis `READY` gestartet. Der Runner schreibt weder Secrets noch lokale Evidence
in das Repository.

## Invoke-HyperVWindowsBaselineAcceptanceRun.ps1

Der Windows-Baseline-Acceptance-Runner ist der reale Gegenpart zum
synthetischen Hyper-V-Smoke. Er verlangt eine bereits veröffentlichte
`OS_SEALED`-Artifact-ID und ein als `SecureString` übergebenes
Gast-Administratorpasswort. Der Lauf:

1. erstellt eine differenzierende Windows-VM;
2. automatisiert OOBE, Region, Sprache, Tastatur und Zeitzone;
3. stoppt und startet die VM über den gemeinsamen Reconcile-Vertrag;
4. prüft PowerShell Direct nach dem Cold Start;
5. weist nach, dass die OS-Baseline keine SQL-Instanz enthält;
6. entfernt VM, Child-VHDX, State und DPAPI-Secret scopegebunden.

Die immutable Parent-VHDX bleibt erhalten und wird nach dem Cleanup erneut auf
Hash und Schreibschutz geprüft. Der Runner muss in einer erhöhten
PowerShell-7-Sitzung auf dem Hyper-V-Host gestartet werden:

```powershell
$password = Read-Host 'Gast-Administratorpasswort' -AsSecureString
.\Tests\Integration\Invoke-HyperVWindowsBaselineAcceptanceRun.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>' `
    -AdministratorPassword $password
```

`-KeepOnFailure` behält Ressourcen ausschließlich nach einem fehlgeschlagenen
Lauf für die lokale Diagnose.

## Invoke-ExternalRuntimeHyperVAcceptance.ps1

Der Hyper-V-External-Runtime-Runner baut auf einer veröffentlichten
`OS_SEALED`-Baseline auf, installiert SQL Server 2022 mit
`ADVANCEDANALYTICS`, legt ausschließlich SHA-256-verifizierte Windows-
Offlinemedien in den Gast und prüft Python, R und Java durch echte
`sp_execute_external_script`-Roundtrips. Für Java werden External Language,
SDK-Library und synthetische Probe-Library datenbankgebunden registriert und
gegen ihre Content-Hashes geprüft. Dieselben Postconditions werden nach
einem Dienstneustart und nach einem VM-Cold-Start wiederholt. Evidence und
Receipts enthalten weder Secrets noch Hostpfade.

Ein frischer Run, dessen Child-VHDX noch eine OOBE-Antwortdatei benötigt, muss
in einer erhöhten PowerShell-7-Sitzung laufen. Ein bereits spezialisierter
Windows-Slot mit `windowsProvisioning.state = COMPLETE` kann ohne diesen
Offline-Mount fortgesetzt werden, sofern der aktuelle Account die konkret
benötigten Hyper-V-Operationen ausführen darf. Die Run-ID muss zu einem eigens
für diesen Nachweis freigegebenen Slot gehören: Der Runner installiert dort
dauerhaft SQL Server 2022 sowie die drei Runtimes und verändert daher keinen
allgemein geteilten oder anderweitig reservierten Poolslot ohne ausdrückliche
Freigabe.

```powershell
.\Tests\Integration\Invoke-ExternalRuntimeHyperVAcceptance.ps1 `
    -RunId '<existing-run-id>'
```

Für einen vorhandenen spezialisierten Windows-Poolslot ist der isolierte
Clone-Modus vorzuziehen. Er akzeptiert ausschließlich eine ausgeschaltete,
SQL-freie Windows-Quelle mit abgeschlossenem Provisioning aus einem noch
gültigen registrierten Evaluation-Artefakt. Die Quell-VHDX muss scopegebunden
zur signierten Run-Identität gehören. Der Runner konvertiert sie vollständig in
eine neue run-lokale, schreibgeschützte Parent-Kopie und verändert weder
Quell-VM noch Quell-State. VM, Child-VHDX und Parent-Kopie des neuen Runs werden
vor der ersten Mutation in dessen Cleanup-Plan registriert:

```powershell
.\Tests\Integration\Invoke-ExternalRuntimeHyperVAcceptance.ps1 `
    -CloneSourceRunId '<specialized-windows-source-run-id>' `
    -CleanupOnSuccess
```

`-RunId` und `-CloneSourceRunId` sind gegenseitig exklusiv. Der Clone benötigt
freien Speicher für eine vollständige dynamische Kopie der spezialisierten
Systemdisk. Bei einem Fehler bleibt ausschließlich der neue Run sichtbar in
`RECOVERY_REQUIRED` beziehungsweise `CLEANUP_PENDING`; die Quelle bleibt aus.

`-CleanupOnSuccess` entfernt den verwendeten Run nach erfolgreicher Evidence
über `Remove-SqlServerLab`; ohne den Switch bleibt er für die Auswertung
erhalten. Ein fehlgeschlagener Lauf bleibt für Recovery sichtbar.

Die katalogisierten Windows-Varianten bleiben bis zu diesem positiven nativen
Nachweis `PREVIEW`.
