# SSISDB-Testquelle für SQL_Server_Analyze

| Merkmal | Wert |
|---|---|
| Status | `INCREMENTAL_IMPLEMENTATION` |
| Stand | 2026-10-13 |
| Öffentlicher Einstieg | `Get-SqlServerLabSsisCatalogCapability` |

## Zweck und Grenze

Dieser Vertrag führt den ersten öffentlichen, rein lesenden Schritt für eine spätere SSISDB-Testquelle ein. Er bindet genau einen vorhandenen, eigenen und laufenden Hyper-V-/Windows-/SQL-2019-, -2022- oder -2025-Run an eine registrierte Instanz und beobachtet dessen SSIS- und SSISDB-Voraussetzungen. SQL Server 2025 ist die bevorzugte Referenz; 2019 und 2022 bleiben als tatsächlich beobachtete Engineversionen getrennt bezeichnet. Er unterstützt keine Linux-, Docker- oder Podman-Quelle für SSISDB.

Der Cmdlet führt keinen Download, Build, keine Installation, Katalogerstellung, VM-Start, Paketbereitstellung oder SSIS-Ausführung aus. Er gibt weder Credentials, Endpunkte, VM-Namen noch lokale Pfade zurück. Er prüft die Bindung vor und nach dem begrenzten Gasttransport; eine Änderung verwirft die Beobachtung.

```powershell
Get-SqlServerLabSsisCatalogCapability -RunId $runId -InstanceId primary
```

Die vollständige öffentliche Konsolen-CLI katalogisiert den Export automatisch. Der Browser verwendet denselben Exportkatalog im Bereich **Status und Diagnose**. Diese generische Eingabemöglichkeit ist kein separater SSISDB-Fachdialog und erzeugt keine Ausführung.

## Rückgabevertrag

`SqlServerLab.SsisCatalogCapability/1.0` enthält nur folgende sicher projizierte Informationen:

- `Target`: RunId, InstanceId und `BindingStatus` (`BOUND` oder `BLOCKED`);
- `Sql` und `Ssis`: beobachtete Versions-/Katalogstatus;
- `Source`: nur `OBSERVED` oder `NOT_READY`; eine Consumer-Verbindungsbindung ist zunächst `NOT_PROVISIONED`, Consumerrechte sind `NOT_ASSESSED`;
- `Fixture`: immer `NOT_IMPLEMENTED`, `MutationAllowed=false` und keine Execution-IDs;
- Gesamtstatus `READY_FOR_FIXTURE_IMPLEMENTATION` oder `BLOCKED`.

`READY_FOR_FIXTURE_IMPLEMENTATION` bestätigt ausschließlich die beobachtete Voraussetzung eines vorhandenen eigenen Zielruns. Er bestätigt weder `catalog.executions`-Rechte eines Analyze-Consumers noch reale SSISDB-Ausführungen, Loggingfälle, Cleanup oder die Eignung als SQL_Server_Analyze-Runtimequelle.

## Nächste getrennte Slices

1. Reale, eigentumsgebundene SSISDB-Fixture mit synthetischen Projekten, Packages und Erfolg-/Fehler-/unvollständigen Loggingfällen.
2. Geheimnisfreie Consumer-Quellenbindung mit tatsächlicher `catalog`-View- und Rechteprüfung.
3. Teilfehler- und Abbruchcleanup, der nur die eigenen Katalogressourcen entfernt.
4. Tatsächlich ausgeführte Windows-/SSISDB-Abnahme samt Engine-/SSISversion, API-Aufruf, Fallmengen und Cleanupbefund; erst diese öffnet das Analyze-Runtimegate.
5. Ein eigener Browser-Fachdialog erst nach dem konkret gebundenen Fixture-Vertrag. Bis dahin bleibt die generische Browser-Commandoberfläche die read-only Bedienoberfläche.

Der mutierende Folgepfad verlangt einen vorhandenen ausdrücklich bezeichneten isolierten Windows-Testhost mit SQL Server, Integration Services und online SSISDB. Installation, Medienbeschaffung, Lizenz- oder Kostenfreigaben werden durch diesen Vertrag nicht impliziert.

## Herstellergrundlagen

Microsoft beschreibt den SSIS-Katalog und seine `catalog`-Views als SSISDB-Quelle. Die spätere Ausführung verwendet ausschließlich die offiziellen Katalogprozeduren und getrennt dokumentierte Rechtebindungen: [SSIS-Katalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17), [catalog.executions](https://learn.microsoft.com/sql/integration-services/system-views/catalog-executions-ssisdb-database?view=sql-server-ver16), [catalog.create_execution](https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-create-execution-ssisdb-database?view=sql-server-ver17).
