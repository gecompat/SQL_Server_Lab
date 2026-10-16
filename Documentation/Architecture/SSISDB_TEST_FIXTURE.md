# SSISDB-Testquelle für SQL_Server_Analyze

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_RUNTIME_PENDING` |
| Stand | 2026-10-16 |
| Öffentliche Einstiege | `Get-SqlServerLabSsisCatalogCapability`, `Install-SqlServerLabSsisComponent`, `New-SqlServerLabSsisCatalogFixture`, `Remove-SqlServerLabSsisCatalogFixture` |

## Zweck und Grenze

Dieser Vertrag bindet eine SSISDB-Testquelle an einen ausschließlich eigenen Hyper-V-/Windows-Run. SQL Server 2025 ist die bevorzugte Referenz; 2019 und 2022 bleiben im rein lesenden Prerequisite-Reader als tatsächlich beobachtete Engineversionen getrennt bezeichnet. Linux, Docker und Podman liefern keine SSISDB-Quelle.

`Get-SqlServerLabSsisCatalogCapability` führt keinen Download, Build, keine Installation, Katalogerstellung, VM-Start, Paketbereitstellung oder SSIS-Ausführung aus. Er gibt weder Credentials, Endpunkte, VM-Namen noch lokale Pfade zurück. Er prüft die Bindung vor und nach dem begrenzten Gasttransport; eine Änderung verwirft die Beobachtung.

```powershell
Get-SqlServerLabSsisCatalogCapability -RunId $runId -InstanceId primary
```

`Install-SqlServerLabSsisComponent` ist der ausdrücklich mutierende Komponentenpfad für den normalen Bereitstellungsweg. Er akzeptiert nur einen bereits laufenden, gebundenen eigenen Windows-SQL-2025-Run, eine vorhandene SQL-2025-Enterprise-ISO und deren erwarteten SHA-256-Wert. Vor und nach dem Gasttransport bindet er Run, Scope, Instanz und VM-ID. Er ergänzt ausschließlich `IS`, startet die VM kontrolliert neu und verifiziert Engine und installierte Serverkomponenten. Der ältere `MsDtsServer170`-Paketverwaltungsdienst muss dabei nicht laufen: Microsoft erklärt ihn für Erstellung und Ausführung von Paketen ausdrücklich als nicht erforderlich. Seine bloße Existenz ersetzt umgekehrt keinen SSISDB-Ausführungsnachweis. Die vorhandene SQL-Engine bleibt bestehen. Download, Update, Build und Beschaffung sind ausgeschlossen; `Remove-SqlServerLab` bleibt der Cleanup für die Komponente und den gesamten eigenen Run.

`New-SqlServerLabSsisCatalogFixture -RunId $runId -InstanceId primary` ist der folgende Fixturepfad. Er akzeptiert keine freien Hosts, Endpunkte oder Credentials. Er verlangt beobachtete SQL-2025- und IS-Komponenten und erzeugt SSISDB nur dann, wenn diese im gebundenen eigenen Run fehlt. Dazu verwendet er Microsofts dokumentiertes `Microsoft.SqlServer.Management.IntegrationServices.Catalog.Create()` aus der bereits installierten IS-17-Managementassembly. Die Assembly wurde im eigenen IS-2025-Gast tatsächlich beobachtet. Fehlt sie, bricht die Funktion vor der Kataloganlage mit `SSIS_FIXTURE_INSTALLED_MANAGEMENT_ASSEMBLY_REQUIRED` ab. Ein manuell nachgebauter Template-Restore, SSMS, Download oder nachträglicher SDK-Installationsschritt gehört nicht zur Runtime. Das nur gastlokal erzeugte Katalogkennwort erfüllt alle vier Komplexitätsklassen und verlässt den Gastprozess nicht.

Der Cmdlet legt in der frischen VM SSISDB und einen eindeutig operationseigenen Katalogordner an. Er stellt ein synthetisches lokales Projekt mit drei Packages bereit: `Success.dtsx`, `Failure.dtsx` und `Incomplete.dtsx`. Er startet nur die Erfolgs- und Fehlerausführung; die dritte Ausführung bleibt im Zustand `created`. Die Receipt enthält ausschließlich Run-/Instanzbindung, die eigenen Execution-IDs, die beobachteten `catalog`-Views, vollständige Engine-/SSIS-Dateiversion und Versionsmajor, Rechteklassifikation und den Cleanupstatus. Sie enthält keine Credentials, Endpunkte oder lokalen Pfade.

Die tatsächlich installierte IS-17-Management-API verwendet
`Microsoft.Data.SqlClient.SqlConnection`. Ihre SMO-/SqlClient-Abhängigkeiten
werden ausschließlich aus dem installierten `170/DTS/Binn` geladen. Dabei
werden Assemblyidentität, Public-Key-Token und deklarierte Referenzversionen
geprüft. PowerShell übernimmt die Binding-Redirects von `ISServerExec.exe.config`
nicht automatisch; die Probe wendet genau deren lokale, versionsgebundene
Redirects an und entfernt ihren Resolver anschließend wieder. Andere Namen,
Tokens oder Versionsbereiche werden nicht aufgelöst. Fehlende Abhängigkeiten
öffnen keinen Download- oder SDK-Installationspfad.

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

## Neues Lab aus Manifest

`New-SqlServerLab -Manifest` unterstützt `instances[].ssisCatalogFixture` für
genau eine Hyper-V-/Windows-/SQL-2025-Instanz. Das Objekt verlangt `mediaRoot`,
`sqlMediaPath` und `expectedSqlMediaSha256`; unbekannte Felder werden abgewiesen.
Ein relativer Medienroot wird relativ zum Manifest aufgelöst. Die Medien werden
vor der VM-Erstellung geprüft und bei der Installation erneut inhaltsgebunden.
Nach der normalen SQL-Bereitstellung folgen dieselbe additive IS-Installation
und dieselbe öffentliche Fixture-API. Ein bereitgestellter SQL-Slot wird dabei
weiterverwendet; es gibt keine erzwungene SQL-Neuinstallation. Bei Fehlern in
diesem SSIS-Schritt wird der neue eigene Run kompensiert; ein Cleanupfehler
erhält die gebundene RunId als Recoveryhinweis.

Das [Beispielmanifest](../../Schemas/example-ssis-catalog-fixture.json) enthält
ausdrückliche Platzhalter für lokale Medien und Artifact-/ISO-Hashes. Vor der
Ausführung müssen sie durch überprüfte lokale Werte ersetzt werden. Secrets
werden ausschließlich als geschützte Parameter übergeben:

```powershell
$lab=New-SqlServerLab -Manifest $manifestPath -GuestPassword $guestPassword `
  -SqlSaPassword $sqlSaPassword -NonInteractive -StateRoot $stateRoot
$fixture=$lab.SsisCatalogFixture
```

Der Manifestdialog von CLI und Browser sowie der vollständige Befehlszugang
verwenden denselben `New-SqlServerLab`-Vertrag. Ein eigener SSIS-Fachdialog ist
weiterhin nicht abgenommen.

## Verbindungs- und Secretbindung

Die Receipt bindet die Quelle über `Target.RunId` und `Target.InstanceId`.
`Get-SqlServerLab -RunId` liefert die normale geheimnisfreie Verbindungsbindung.
Beim neuen Fixture-Run erzeugt das Lab das SQL-Kennwort selbst und speichert
auch den geschützten Generated-Alias. Ein Consumer ruft es ausschließlich
explizit über `Get-SqlServerLabGeneratedSqlAccess -RunId` ab. Das Ergebnis ist
geheimnistragend und gehört niemals in Logs, Receipts oder Repositoryartefakte.
Bei einem vorhandenen Run oder einem Manifest mit vom Aufrufer übergebenem
SQL-Kennwort bleibt dessen bereits geschützte Credentialübergabe maßgeblich;
der Generated-Befehl gibt keine benutzerdefinierten Kennwörter frei.

## Rückgabevertrag

`SqlServerLab.SsisCatalogCapability/1.0` enthält nur folgende sicher projizierte Informationen:

- `Target`: RunId, InstanceId und `BindingStatus` (`BOUND` oder `BLOCKED`);
- `Sql` und `Ssis`: beobachtete Versions-/Katalogstatus;
- `Source`: nur `OBSERVED` oder `NOT_READY`; eine Consumer-Verbindungsbindung ist zunächst `NOT_PROVISIONED`, Consumerrechte sind `NOT_ASSESSED`;
- `Fixture`: bei diesem rein lesenden Einstieg weiterhin `NOT_IMPLEMENTED`, `MutationAllowed=false` und keine Execution-IDs;
- Gesamtstatus `READY_FOR_FIXTURE_IMPLEMENTATION` oder `BLOCKED`.

`READY_FOR_FIXTURE_IMPLEMENTATION` bestätigt ausschließlich die beobachtete Voraussetzung eines vorhandenen eigenen Zielruns. Er bestätigt weder `catalog.executions`-Rechte eines Analyze-Consumers noch reale SSISDB-Ausführungen, Loggingfälle, Cleanup oder die Eignung als SQL_Server_Analyze-Runtimequelle.

Die Fixture erzeugt ihre drei eigenen Pakete als minimale UTF-16-DTSX-Dokumente
mit `DTS:ForceExecutionResult` und verpackt sie mit `@Project.manifest`, Paketmetadaten und OPC-Content-Types in ein vollständiges eigenes `.ispac`. Damit
genügt die bereits installierte SSIS-Serverkomponente einschließlich `DTExec`;
ein SSIS-Entwicklungs-SDK, `Microsoft.SqlServer.Dts.Runtime.dll`, Download oder
Build-Schritt ist kein Laufzeitbedarf. Der Erfolg-, Fehler- und ungestartete
Fall bleiben vollständig synthetisch und ohne externe Datenquelle.

`SqlServerLab.SsisCatalogFixture/1.0` ist die mutierende Receipt. `Status=READY_FOR_READ_ONLY_ANALYSIS` und `Cleanup=REMOVE_OWNED_FIXTURE_TO_CLEANUP` bedeuten, dass nur der zugehörige eigene Run eine Quelle sein darf. `Remove-SqlServerLabSsisCatalogFixture` löscht ausschließlich den quittierten eigenen Katalogordner. Name, Operationstoken und tatsächliche `FolderId` müssen übereinstimmen; die SQL-Prüfung und Löschung laufen in einer serialisierbaren Transaktion. Eine veraltete oder veränderte Receipt gibt keine fremden Ressourcen zur Löschung frei. Fremde Katalogordner, Projekte, globale Retention, Katalogeigenschaften und Loggingkonfiguration bleiben erhalten. Nach Teilfehlern entfernt der Guest-Probe seinen eigenen Ordner, sofern er angelegt wurde; Primär- und Cleanupfehler bleiben getrennt sichtbar und Verbindungen werden auch bei Cleanupfehlern geschlossen.

## Ausführungsnachweis

Die Formatabnahme `Tests/Integration/Invoke-SsisFixtureFormatAcceptance.ps1` hat am 2026-10-16 mit der vorhandenen SSIS-17-Runtime das tatsächlich erzeugte ISPAC über Microsofts `Project.OpenProject()` geöffnet: drei Entry-Point-Packages, erwartete Forced Results, keine Verbindungen oder Tasks. Sie verwendet Windows PowerShell und startet weder SQL noch eine VM. Dies ist noch kein Windows-/SSISDB-Runtimenachweis. Vor dem Analyze-Runtimegate ist eine tatsächliche Abnahme erforderlich: genauer Cmdlet-Aufruf, Engine-/SSISversion, alle drei Execution-IDs und Statuswerte, beobachtete Views/Rechte, Receipt und erfolgreicher Run-Cleanup. Ein lokaler oder statischer Erfolg ersetzt diesen Nachweis nicht.

Die ergänzende `Invoke-SsisCatalogManagementAcceptance.ps1` hat den produktiven
Loader mit den vorhandenen IS-17-Dateien unter Windows PowerShell ausgeführt:
geschlossene SqlConnection, passende echte IS-/Catalog-Konstruktorsignaturen
und Ablehnung fremder Namen, Tokens und Versionen. SQL wurde dabei nicht
geöffnet; auch dies ersetzt keine Katalog-/Ausführungsabnahme.

Für fokussierte Diagnose kann der manuelle Workflowmodus
`ssisdb-existing-run-acceptance` einen ausdrücklich gebundenen vorhandenen
Run verwenden. Der getrennte Modus `ssisdb-diagnostic-run-acceptance` verlangt
stattdessen ausdrücklich ein Prepared-Artifact und bereitet über
`Initialize-SsisCatalogDiagnosticRun.ps1` einmalig einen eigenen
SQL-/IS-Run vor und quittiert seine RunId. Dieser Run bleibt nach Fixturefehlern
für die folgende Diagnose erhalten. Weitere Versuche verwenden genau diese
RunId. Gezielter Cleanup und erneute Fixtureanlage prüfen anschließend auch
den bereits vorhandenen SSISDB-Katalog. Vollständiger Cleanup erfolgt bewusst
über `Remove-SqlServerLab` am quittierten eigenen Run.

Der Prepared-SSISDB-Pfad erklärt Windows-Aktivierung ausdrücklich als `NotRequested` mit `Denied`-Egress. SSIS, SSISDB und die lokale Katalogausführung benötigen keine Windows-Aktivierung; der Test erstellt daher weder eine temporäre externe NIC noch eine Netzverbindung. Die getrennten Fresh-Install-Abnahmen dürfen weiterhin ihre eigene Aktivierungskette prüfen.

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

Microsoft beschreibt den SSIS-Katalog und seine `catalog`-Views als SSISDB-Quelle. Die spätere Ausführung verwendet ausschließlich die offiziellen Katalogprozeduren und getrennt dokumentierte Rechtebindungen: [SSIS-Katalog](https://learn.microsoft.com/sql/integration-services/catalog/ssis-catalog?view=sql-server-ver17), [catalog.executions](https://learn.microsoft.com/sql/integration-services/system-views/catalog-executions-ssisdb-database?view=sql-server-ver16), [catalog.create_execution](https://learn.microsoft.com/sql/integration-services/system-stored-procedures/catalog-create-execution-ssisdb-database?view=sql-server-ver17), [Abgrenzung des älteren SSIS-Windows-Dienstes](https://learn.microsoft.com/sql/integration-services/service/integration-services-service-ssis-service?view=sql-server-ver17).
