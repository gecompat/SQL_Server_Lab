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

```powershell
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
```
