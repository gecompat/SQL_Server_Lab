# Windows-/SSISDB-Abnahme vom 2026-10-16

| Merkmal | Ausgeführter Stand |
|---|---|
| Implementierungscommit | `9b891acc5d891d009c04e19116e22156cfcef849` |
| Integration | [PR #754](https://github.com/gecompat/SQL_Server_Lab/pull/754); der dortige Mergecommit bindet den integrierten Stand |
| Provider / Ziel | Hyper-V, isolierter eigener Windows-SQL-Run |
| Tatsächliche SQL-Engine | SQL Server 2025, `17.0.1000.7` |
| Tatsächliches SSIS | `17.0.1000.7`, Major 17 |
| Bestehender SQL-/IS-/SSISDB-Pfad | `PASSED_RETAINED_SOURCE` |
| Neuer Run / Manifest | `FAILED_NOT_QUALIFIED`; Ausführungsstatus nicht wie erwartet |
| Cleanup des fehlgeschlagenen neuen Runs | `CLEANUP_SUCCEEDED`, drei Schritte, null Fehler |

## Öffentliche Nachweisquelle

Die [ausgeführte Existing-Run-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38855907638)
bestand am **2026-10-16 um 05:28:39 UTC** auf dem Implementierungscommit.
Die Workflow-Zusammenfassung enthält die geheimnisfreie maschinenlesbare
`SqlServerLab.SsisCatalogExistingRunAcceptance/1.0`-Receipt. Sie bestätigt echte
SSISDB-Katalogausführungen; ein Tabellenclone wurde weder erzeugt noch verwendet.

Der [neue Manifest-Run](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38856079120)
auf demselben Implementierungscommit scheiterte nach erfolgreichem CompleteImage,
OOBE und additiver IS-Installation einschließlich Neustart an
`SSIS_FIXTURE_EXECUTION_STATUS_INVALID`. Die ursprüngliche Fehlermeldung enthielt
keine Einzelstatus; eine konkrete Ursache ist damit noch nicht belegt. Der eigene
Run wurde mit drei erfolgreichen Cleanupschritten und null Fehlern entfernt.
Dieser Lauf qualifiziert den neuen Manifestpfad ausdrücklich nicht.

Die vorherige einmalige Diagnosevorbereitung verwendete einen veröffentlichten
SQL-Prepared-Slot und ergänzte ausschließlich vorhandene IS-Medien. Die
bestandene Abnahme verwendete genau diesen bestehenden Run weiter;
`Install-SqlServerLabSsisComponent` meldete `ALREADY_INSTALLED`. Während der
Fixtureanlage erfolgten kein Download, SDK-Setup, Drittsoftwarebuild oder
SQL-Engine-Neuinstallation. Kataloganlage: Microsofts `Catalog.Create()` mit
den bereits installierten IS-17-Managementdateien und deren Binding-Redirects.

## Qualifizierte öffentliche Aufrufe

Dieser Producerblock dokumentiert die vom Lab-Workflow ausgeführte Anlage
auf dem zuvor bereinigten Ziel. Consumer übernehmen die letzte Quelle mit
den lesenden Aufrufen im Abschnitt Verbindungsbindung und den quittierten IDs.

```powershell
Import-Module SqlServerLab
$runId=[guid]'12da9ca8-341d-4787-b97c-131b70062d27'
# $stateRoot ist der lokal gebundene Lab-StateRoot; keine Hostpfade im Nachweis.
$fixture=SqlServerLab\New-SqlServerLabSsisCatalogFixture `
  -RunId $runId -InstanceId primary -StateRoot $stateRoot -Confirm:$false

SqlServerLab\Remove-SqlServerLabSsisCatalogFixture `
  -RunId $runId -InstanceId primary -StateRoot $stateRoot -Confirm:$false
```

Der Workflow bereinigt zuerst eine eventuell zuvor quittierte eigene Fixture,
erzeugt und prüft eine neue Fixture, führt den Fremdobjektschutztest aus,
entfernt das eigene Projekt und den leeren Ordner und erzeugt anschließend
erneut drei Fälle im bereits vorhandenen SSISDB-Katalog. Zu keinem Zeitpunkt
wird ein zweiter SQL-Run dafür erstellt. Die letzte Quelle bleibt bewusst für
den Consumer erhalten.

## Tatsächlich vorhandene letzte Quelle

| Bindung | Beobachtet |
|---|---|
| RunId | `12da9ca8-341d-4787-b97c-131b70062d27` |
| InstanceId | `primary` |
| Target.BindingStatus | `BOUND` |
| Source.ConnectionBinding | `OWNED_EXISTING_HYPERV_RUN` |
| Katalog | `SSISDB_OBSERVED` |
| Catalog-Views | `catalog.executions`, `catalog.event_messages` |
| Rechte | `SYSADMIN_OBSERVED` |
| Consumer-Zugang | `PUBLIC_GENERATED_SQL_ACCESS_VERIFIED` |

| Eigener Fall | Execution-ID | Tatsächlicher Status |
|---|---:|---|
| Erfolg | `14` | `7` – succeeded |
| Fehler | `15` | `4` – failed |
| Unvollständiges Logging | `16` | `1` – created, ausdrücklich nicht gestartet |

Jede Fixture erzeugt genau drei eigene Pakete ohne Verbindungen oder Tasks.
Das Logging wird nur für ihre eigenen Execution-IDs auf Basic gesetzt.
Diagnosevorgänger können als normale SSIS-Operationshistorie weiter vorhanden
sein. Der Analyzer bindet seine Fallmenge deshalb an die Receipt-IDs und nimmt
keine globale Dreizeiligkeit des Katalogs an.

## Verbindungs- und Rechtebindung

```powershell
$lab=SqlServerLab\Get-SqlServerLab -RunId $runId -StateRoot $stateRoot
$access=SqlServerLab\Get-SqlServerLabGeneratedSqlAccess `
  -RunId $runId -StateRoot $stateRoot
# $access ist geheimnistragend: ausschließlich lokal an den SQL-Client übergeben.
# Nicht ausgeben, serialisieren, weiterprotokollieren oder versionieren.
```

Die Abnahme hat über diesen expliziten öffentlichen Zugang eine tatsächliche
SQL-Verbindung geöffnet, `IS_SRVROLEMEMBER('sysadmin')=1` beobachtet und die drei
quittierten letzten Execution-IDs gelesen. Credentials stehen weder in dieser
Quelle noch in der Fixture-Receipt. Die Rechteklassifikation ist keine Behauptung
eines ausschließlich leseberechtigten SQL-Accounts; die Analyzeroperation selbst
bleibt read-only.

## Cleanupbefund und Verantwortlichkeit

- Gezielter öffentlicher Cleanup: `CATALOG_FOLDER_CLEANUP_SUCCEEDED`.
- Fremdobjektschutz: `FOREIGN_RESOURCE_GUARD_PASSED`. Eine zusätzliche eigene
  synthetische Umgebung blockierte die Fixturelöschung; Projekt und Umgebung
  blieben erhalten. Die Testumgebung wurde anschließend anhand ihrer exakten
  Identität separat entfernt.
- Cleanup löscht ausschließlich das gebundene Projekt und danach den leeren
  Ordner. Andere Projekte, Umgebungen und globale Katalog-/Logging-/Retentionwerte
  werden nicht gelöscht oder umkonfiguriert.
- SSIS-Projektversionen und Operationshistorie folgen weiter der unveränderten
  Herstellerretention; Folder-Cleanup behauptet keine Historienlöschung.
- Der letzte Source-Run bleibt bewusst erhalten. Nach den Consumerprüfungen
  entfernt `Remove-SqlServerLab -RunId $runId -StateRoot $stateRoot -Force
  -Confirm:$false` den gesamten eigenen Run einschließlich Historie.

## Aussagegrenzen

Der Nachweis gilt für diesen Windows-/Hyper-V-/SQL-2025-Referenzpfad mit
vorhandenen geprüften Medien. Linux besitzt keinen SSISDB-Katalog. Mutierende
SQL-2019-/2022- oder weitere Editionskombinationen sind hier **NOT_EXECUTED**.
CLI und Browser verwenden den gemeinsamen öffentlichen Befehls-/Manifestvertrag;
ein separat gerenderter SSIS-Fachdialog ist **NOT_EXECUTED**. Ein harter Hostausfall
oder ein VM-Restore während der Fixtureausführung wurde nicht injiziert.

Das SQL_Server_Analyze-Runtimegate setzt zusätzlich die reguläre Integration
dieses Standes mit den erforderlichen grünen Checks am finalen PR-Head voraus.
Die Analyzerimplementierung selbst gehört weiterhin zu SQL_Server_Analyze.
