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

`-CleanupOnSuccess` entfernt den verwendeten Run nach erfolgreicher Evidence
über `Remove-SqlServerLab`; ohne den Switch bleibt er für die Auswertung
erhalten. Ein fehlgeschlagener Lauf bleibt für Recovery sichtbar.

Die katalogisierten Windows-Varianten bleiben bis zu diesem positiven nativen
Nachweis `PREVIEW`.
