# SSISDB-Testquelle für SQL_Server_Analyze

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_RUNTIME_PENDING` |
| Stand | 2026-10-14 |
| Öffentliche Einstiege | `Get-SqlServerLabSsisCatalogCapability`, `Install-SqlServerLabSsisComponent`, `New-SqlServerLabSsisCatalogFixture`, `Remove-SqlServerLabSsisCatalogFixture` |

## Zweck und Grenze

Dieser Vertrag bindet eine SSISDB-Testquelle an einen ausschließlich eigenen Hyper-V-/Windows-Run. SQL Server 2025 ist die bevorzugte Referenz; 2019 und 2022 bleiben im rein lesenden Prerequisite-Reader als tatsächlich beobachtete Engineversionen getrennt bezeichnet. Linux, Docker und Podman liefern keine SSISDB-Quelle.

`Get-SqlServerLabSsisCatalogCapability` führt keinen Download, Build, keine Installation, Katalogerstellung, VM-Start, Paketbereitstellung oder SSIS-Ausführung aus. Er gibt weder Credentials, Endpunkte, VM-Namen noch lokale Pfade zurück. Er prüft die Bindung vor und nach dem begrenzten Gasttransport; eine Änderung verwirft die Beobachtung.

```powershell
Get-SqlServerLabSsisCatalogCapability -RunId $runId -InstanceId primary
```

`Install-SqlServerLabSsisComponent` ist der ausdrücklich mutierende Komponentenpfad für den normalen Bereitstellungsweg. Er akzeptiert nur einen bereits laufenden, gebundenen eigenen Windows-SQL-2025-Run, eine vorhandene SQL-2025-Enterprise-ISO und deren erwarteten SHA-256-Wert. Vor und nach dem Gasttransport bindet er Run, Scope, Instanz und VM-ID. Er ergänzt ausschließlich `IS`, startet die VM kontrolliert neu und verifiziert Engine und SSIS-Dienst. Die vorhandene SQL-Engine bleibt bestehen. Download, Update, Build und Beschaffung sind ausgeschlossen; `Remove-SqlServerLab` bleibt der Cleanup für die Komponente und den gesamten eigenen Run.

`New-SqlServerLabSsisCatalogFixture -RunId $runId -InstanceId primary` ist der folgende Fixturepfad. Er akzeptiert keine freien Hosts, Endpunkte oder Credentials. Er verlangt beobachtete SQL-2025- und IS-Komponenten und erzeugt SSISDB nur dann, wenn diese im gebundenen eigenen Run fehlt.

Der Cmdlet legt in der frischen VM SSISDB und einen eindeutig operationseigenen Katalogordner an. Er stellt ein synthetisches lokales Projekt mit drei Packages bereit: `Success.dtsx`, `Failure.dtsx` und `Incomplete.dtsx`. Er startet nur die Erfolgs- und Fehlerausführung; die dritte Ausführung bleibt im Zustand `created`. Die Receipt enthält ausschließlich Run-/Instanzbindung, die eigenen Execution-IDs, die beobachteten `catalog`-Views, Versionsmajor, Rechteklassifikation und den Cleanupstatus. Sie enthält keine Credentials, Endpunkte oder lokalen Pfade.

Die vollständige öffentliche Konsolen-CLI katalogisiert beide Exporte automatisch. Der Browser verwendet denselben Exportkatalog im Bereich **Status und Diagnose**. Bis zu einer eigenen gerenderten Fachabnahme bleibt dies ein generischer, parametergebundener Dialog und kein separater SSISDB-Fachdialog.

```powershell
$component=Install-SqlServerLabSsisComponent -RunId $runId -InstanceId primary -MediaRoot $mediaRoot `
  -SqlMediaPath 'SQL/2025/Enterprise/ISO/SQLServer2025-x64-ENU-EntDev.iso' `
  -ExpectedSqlMediaSha256 $sha256
$fixture=New-SqlServerLabSsisCatalogFixture -RunId $runId -InstanceId primary

# Optional: nur den quittierten eigenen Katalogordner entfernen.
Remove-SqlServerLabSsisCatalogFixture -RunId $runId -InstanceId primary -Confirm:$false
# Oder den gesamten zugehörigen Run einschließlich IS entfernen.
Remove-SqlServerLab -RunId $fixture.Target.RunId -Force -Confirm:$false
```

## Rückgabevertrag

`SqlServerLab.SsisCatalogCapability/1.0` enthält nur folgende sicher projizierte Informationen:

- `Target`: RunId, InstanceId und `BindingStatus` (`BOUND` oder `BLOCKED`);
- `Sql` und `Ssis`: beobachtete Versions-/Katalogstatus;
- `Source`: nur `OBSERVED` oder `NOT_READY`; eine Consumer-Verbindungsbindung ist zunächst `NOT_PROVISIONED`, Consumerrechte sind `NOT_ASSESSED`;
- `Fixture`: bei diesem rein lesenden Einstieg weiterhin `NOT_IMPLEMENTED`, `MutationAllowed=false` und keine Execution-IDs;
- Gesamtstatus `READY_FOR_FIXTURE_IMPLEMENTATION` oder `BLOCKED`.

`READY_FOR_FIXTURE_IMPLEMENTATION` bestätigt ausschließlich die beobachtete Voraussetzung eines vorhandenen eigenen Zielruns. Er bestätigt weder `catalog.executions`-Rechte eines Analyze-Consumers noch reale SSISDB-Ausführungen, Loggingfälle, Cleanup oder die Eignung als SQL_Server_Analyze-Runtimequelle.

`SqlServerLab.SsisCatalogFixture/1.0` ist die mutierende Receipt. `Status=READY_FOR_READ_ONLY_ANALYSIS` und `Cleanup=REMOVE_OWNED_FIXTURE_TO_CLEANUP` bedeuten, dass nur der zugehörige eigene Run eine Quelle sein darf. `Remove-SqlServerLabSsisCatalogFixture` löscht ausschließlich den quittierten eigenen Katalogordner; fremde Katalogordner, Projekte, globale Retention, Katalogeigenschaften und Loggingkonfiguration bleiben erhalten. Nach Teilfehlern entfernt der Guest-Probe seinen eigenen Ordner, sofern er angelegt wurde; der Fehler bleibt getrennt sichtbar.

## Ausführungsnachweis

Die aktuelle Implementierung ist noch kein Windows-/SSISDB-Runtimenachweis. Vor dem Analyze-Runtimegate ist eine tatsächliche Abnahme erforderlich: genauer Cmdlet-Aufruf, Engine-/SSISversion, alle drei Execution-IDs und Statuswerte, beobachtete Views/Rechte, Receipt und erfolgreicher Run-Cleanup. Ein lokaler oder statischer Erfolg ersetzt diesen Nachweis nicht.

Der vorgesehene Nachweis läuft auf dem erhöhten registrierten Hyper-V-Runner,
nicht über einen lokalen UAC-Dialog. Der manuelle Workflowmodus
`ssisdb-fixture-acceptance` verlangt ausdrücklich Prepared-Artifact,
State-Root, relativen ISO-Pfad und ISO-Hash. Er ruft ausschließlich
`New-SqlServerLabSsisCatalogFixture` und `Remove-SqlServerLab` auf,
schreibt nur eine geheimnisfreie Receipt in die Workflow-Zusammenfassung und
bereinigt den neuen eigenen Run auch nach einem Fixturefehler. Bis ein
erfolgreicher Workflowlauf verlinkt ist, bleibt der Runtime-Status
`IMPLEMENTED_RUNTIME_PENDING`.

## Herstellergrundlagen

Microsoft beschreibt den SSIS-Katalog und seine `catalog`-Views als SSISDB-Quelle. Die spätere Ausführung verwendet ausschließlich die offiziellen Katalogprozeduren und getrennt dokumentierte Rechtebindungen: [SSIS-Katalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17), [catalog.executions](https://learn.microsoft.com/sql/integration-services/system-views/catalog-executions-ssisdb-database?view=sql-server-ver16), [catalog.create_execution](https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-create-execution-ssisdb-database?view=sql-server-ver17).
