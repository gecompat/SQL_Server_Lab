# Windows-/SSISDB-Abnahme vom 2026-10-16

| Merkmal | Ausgeführter Stand |
|---|---|
| Implementierungscommit des korrigierten Installations-/Cleanupvertrags | `ea3ac12394f3701b5210165b11117510b0a9bfa0` |
| Integration | [PR #754](https://github.com/gecompat/SQL_Server_Lab/pull/754); der dortige Mergecommit bindet den integrierten Stand |
| Provider / Ziel | Hyper-V, isolierter eigener Windows-SQL-Run |
| Tatsächliche SQL-Engine | SQL Server 2025, `17.0.1000.7` |
| Tatsächliches SSIS | `17.0.1000.7`, Major 17 |
| Bestehender SQL-/IS-/SSISDB-Pfad | `PASSED_RETAINED_SOURCE` |
| Neuer Run / Manifest | `PASSED`, normaler Prepared-Slot und additive IS-Installation |
| Cleanup des neuen Runs | `CLEANUP_SUCCEEDED`, drei Schritte, null Fehler |

## Öffentliche Nachweisquelle

Die [ausgeführte Existing-Run-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38855907638)
bestand am **2026-10-16 um 05:28:39 UTC** auf dem damaligen Stand `9b891acc5d891d009c04e19116e22156cfcef849`.
Die Workflow-Zusammenfassung enthält die geheimnisfreie maschinenlesbare
`SqlServerLab.SsisCatalogExistingRunAcceptance/1.0`-Receipt. Sie bestätigt echte
SSISDB-Katalogausführungen; ein Tabellenclone wurde weder erzeugt noch verwendet.

Der [neue Manifest-Run](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38856079120)
auf diesem damaligen Implementierungscommit scheiterte nach erfolgreichem CompleteImage,
OOBE und additiver IS-Installation einschließlich Neustart an
`SSIS_FIXTURE_EXECUTION_STATUS_INVALID`. Die ursprüngliche Fehlermeldung enthielt
keine Einzelstatus; eine konkrete Ursache ist damit noch nicht belegt. Der eigene
Run wurde mit drei erfolgreichen Cleanupschritten und null Fehlern entfernt.
Dieser Lauf qualifiziert den neuen Manifestpfad ausdrücklich nicht.

Die [begrenzte Management-Resident-Diagnose](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38858878790)
bestand anschließend auf `571348d2417fd23db80993be4ff174e8bd19044b` im vorhandenen
Run. Sie lud dieselben installierten Management-Assemblies vor einer zusätzlichen
kurzlebigen Fixture, ohne den Katalog neu anzulegen. Die eigenen Diagnosefälle
18/19/20 lieferten 7/4/1, das temporäre Projekt wurde gezielt bereinigt und die
ursprüngliche Source-Receipt blieb bytegleich. Dies widerlegt die Assemblyladung
allein als ausreichende Fehlerursache; es ist ausdrücklich keine neue
Produkt- oder Neuerstellungsabnahme.

Die vorherige einmalige Diagnosevorbereitung verwendete einen veröffentlichten
SQL-Prepared-Slot und ergänzte ausschließlich vorhandene IS-Medien. Die
bestandene Abnahme verwendete genau diesen bestehenden Run weiter;
`Install-SqlServerLabSsisComponent` meldete `ALREADY_INSTALLED`. Während der
Fixtureanlage erfolgten kein Download, SDK-Setup, Drittsoftwarebuild oder
SQL-Engine-Neuinstallation. Kataloganlage: Microsofts `Catalog.Create()` mit
den bereits installierten IS-17-Managementdateien und deren Binding-Redirects.


Die [anschließende fokussierte Legacydienst-Isolation mit öffentlicher Existing-Run-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38862203879)
bestand auf `f89beb3f6b82f9ea6ec793b028f9948377e8b56c` am 2026-10-16 um
06:37:49 UTC. Auf genau dem zuvor fehlgeschlagenen eigenen Diagnose-Run wurde
nur der nachweislich vom Lab installierte und bereits gestoppte Legacydienst
`MsDtsServer170` deaktiviert. Anschließend bestanden dieselben öffentlichen
Fixture-, Consumer-, Cleanup- und Fremdobjektschutzprüfungen. Die letzte
bewusst erhaltene Quelle ist deshalb die unten mit IDs 10/11/12 gebundene Quelle.

Die vorausgehende [lesende Gastdiagnose](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38861760440)
korrelierte fehlgeschlagene Legacydienststarts mit DCOM-Starttimeouts und den
zweiminütigen Ausführungsverzögerungen. Rohereignisse bleiben ausschließlich
lokal. Die neue Komponenteninstallation verwendet deshalb den von Microsoft
[dokumentierten Startup-Parameter](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver17)
`ISSVCStartupType=Disabled`; vorhandene Installationen werden nicht pauschal
umkonfiguriert. Der Legacy-Package-Store-Dienst ist laut
[Microsofts Dienstabgrenzung](https://learn.microsoft.com/sql/integration-services/service/integration-services-service-ssis-service?view=sql-server-ver17)
für die Katalogausführung nicht erforderlich. Der korrigierte vollständige
Manifestnachweis wird getrennt ausgewiesen; der Isolationslauf allein ersetzt ihn nicht.

## Vollständige Neuerstellung über den öffentlichen Manifestpfad

Die [Windows-/SSISDB-Neuerstellungsabnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38862975172#summary-116849283076)
bestand auf `ea3ac12394f3701b5210165b11117510b0a9bfa0` am **2026-10-16 um
06:56:51 UTC**. Gesamtdauer: 12 Minuten 3 Sekunden. Die veröffentlichte
`SqlServerLab.SsisCatalogFixtureAcceptance/1.0`-Receipt bestätigt:

| Nachweis | Tatsächlich beobachtet |
|---|---|
| Eigener neuer Run | `d0c5d1c6-5a10-49b9-9f1e-633662ff8ecd`, Instanz `primary` |
| Bindung | `BOUND`, `OWNED_PREPARED_HYPERV_RUN` |
| SQL / SSIS | jeweils `17.0.1000.7`, Major 17 |
| Erfolg / Fehler / ungestartet | eigene IDs `2` / `3` / `4`, Status `7` / `4` / `1` |
| Reale Views | `catalog.executions`, `catalog.event_messages` |
| Rechte / Consumerzugang | `SYSADMIN_OBSERVED`, `PUBLIC_GENERATED_SQL_ACCESS_VERIFIED` |
| Gezielter Projekt-/Ordnercleanup | `CATALOG_FOLDER_CLEANUP_SUCCEEDED` |
| Vollständiger VM-/VHDX-/IPAM-Cleanup | `CLEANUP_SUCCEEDED`, `REMOVED`, drei Schritte, null Fehler |

Der qualifizierte neue Produceraufruf war:

```powershell
$fixture=SqlServerLab\New-SqlServerLabSsisCatalogFixture `
  -ArtifactId $preparedSqlArtifactId -MediaRoot $mediaRoot `
  -SqlMediaPath $approvedRelativeIsoPath -ExpectedSqlMediaSha256 $sha256 `
  -StateRoot $stateRoot -Confirm:$false
```

Der öffentliche NewRun-Parametersatz erzeugt das normale Manifest und ruft
`SqlServerLab\New-SqlServerLab -Manifest` mit `instances[].ssisCatalogFixture`
auf. Dadurch sind Prepared-Slot, unbeaufsichtigtes CompleteImage, additive
IS-Installation, überprüfter deaktivierter Legacydienst, Microsoft-Kataloganlage
und genau eine Fixture Bestandteil desselben normalen Bereitstellungswegs.
Die Abnahme hat den zurückgegebenen Consumerzugang tatsächlich geöffnet,
die eigenen Fälle gelesen, Katalogeigenschaften vor und nach dem gezielten
Cleanup verglichen und anschließend den gesamten eigenen Run entfernt.
Dieser entfernte Run ist ausdrücklich keine noch erreichbare Consumerquelle.

## Qualifizierte öffentliche Aufrufe

Dieser Producerblock dokumentiert die vom Lab-Workflow ausgeführte Anlage
auf dem zuvor bereinigten Ziel. Consumer übernehmen die letzte Quelle mit
den lesenden Aufrufen im Abschnitt Verbindungsbindung und den quittierten IDs.

```powershell
Import-Module SqlServerLab
$runId=[guid]'53fbfd35-08bc-439a-baa1-680f13eb471e'
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
| RunId | `53fbfd35-08bc-439a-baa1-680f13eb471e` |
| InstanceId | `primary` |
| Target.BindingStatus | `BOUND` |
| Source.ConnectionBinding | `OWNED_EXISTING_HYPERV_RUN` |
| Katalog | `SSISDB_OBSERVED` |
| Catalog-Views | `catalog.executions`, `catalog.event_messages` |
| Rechte | `SYSADMIN_OBSERVED` |
| Consumer-Zugang | `PUBLIC_GENERATED_SQL_ACCESS_VERIFIED` |

| Eigener Fall | Execution-ID | Tatsächlicher Status |
|---|---:|---|
| Erfolg | `10` | `7` – succeeded |
| Fehler | `11` | `4` – failed |
| Unvollständiges Logging | `12` | `1` – created, ausdrücklich nicht gestartet |

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
- Der ältere Diagnose-Run wurde über den
  [exakt gebundenen Main-Cleanup](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38863241500)
  erfolgreich entfernt. Der letzte Source-Run bleibt bewusst erhalten.
  Nach den Consumerprüfungen
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

Der neue Abbruchschutz ist mit ausführbarer lokaler Journalregression und
unabhängiger Ownership-/Nebenläufigkeitsprüfung belegt. Der vollständige
Cleanup-SQL-Batch wurde zusätzlich auf dem echten SQL Server geparst und
hat einen nicht existierenden synthetischen Ordner vor jeder Ressourcenmutation
abgewiesen. Der reguläre native Projekt-/Ordnercleanup mit diesem Batch ist
Bestandteil der erfolgreichen Neuerstellungsabnahme. Ein erzwungener Abbruch
während aktiver Ausführung und der native 30-Sekunden-Stop-Timeout wurden
**NOT_EXECUTED**; daraus wird kein zusätzlicher Härtungsnachweis abgeleitet.
