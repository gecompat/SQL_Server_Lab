# Tests/Integration/ – Integration Smoke-Test

End-to-End-Test des gesamten Lab-Lifecycles.

## Invoke-SmokeTest.ps1

| Parameter | Default | Beschreibung |
|---|---|---|
| `-SaPassword` | SmokeTest_Pwd1! | SA-Passwort (SecureString) |
| `-Version` | 2025 | SQL-Server-Version |
| `-Provider` | auto | docker, podman, oder auto (erkennt verfuegbare Runtime) |
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
Boot, startet und stoppt sie und prüft den scopegebundenen Cleanup. Zusätzlich
prüft er einen synthetischen Windows-Image-Build-Plan samt Generation-2-/DVD-
Builder, buildgebundener Generalisierungsevidenz, Resume, immutable Registry-
Publikation als `LIFECYCLE_TEST_ONLY` und Cleanup. Er beweist zusätzlich, dass
synthetische Medien nicht zu `OS_SEALED` eskalieren können. Er installiert weder
Betriebssystem noch SQL Server und verwendet kein Netzwerk.

```powershell
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
```
