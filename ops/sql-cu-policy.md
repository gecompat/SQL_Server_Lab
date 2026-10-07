# SQL Server CU und SqlPackage Watch (SQL_Server_Lab)

## Ziel
Der Agent soll dem Projekt Bescheid geben, sobald die aktuelle
Versionskatalogdatei `Catalogs/sql-server-versions.json` gegenüber den
Microsoft-CU-Quellen oder genau der katalogisierte SqlPackage-Eintrag
`sql2022-sqlpackage170-linux-derived` gegenüber seinem festen Learnartikel
hinterherhinkt.

Er ist kein autonomer Installations-Agent; die Bereitstellung von
Windows-ISO/EXE liegt weiterhin beim Betreiber.

## Scope
- Geltung nur für dieses Repo (`SQL_Server_Lab`), dessen CU-Katalog und genau
  diesen SqlPackage-Eintrag in `Catalogs/software.json`.
- Der Standardlauf prüft ausschließlich Katalogeinträge mit Status `SUPPORTED`.
  Veraltete oder anderweitig nicht aktive Versionen werden nur bei expliziter
  Angabe über `-Version` ausgewertet.
- Keine Risiko-Matrix nach Prod/Test/Dev oder Sicherheitskategorien.
- Keine hypothetische Statusauswertung: nur belastbare Delta-Erkennung.

## Autoritative Inputs
1. `Catalogs/sql-server-versions.json`
2. [Microsoft Support: Latest updates and version history for SQL Server](https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates)
3. `Tools/Get-SqlServerCuStatus.ps1`
4. `Catalogs/software.json`, genau `sql2022-sqlpackage170-linux-derived`;
5. `https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17`;
6. `Tools/Invoke-VersionCatalogResourceWatch.ps1` für die bestehende Monatslane.

## Ausführung
- Standard:
```powershell
.\Tools\Get-SqlServerCuStatus.ps1
```
- Optional als JSON:
```powershell
.\Tools\Get-SqlServerCuStatus.ps1 -AsJson
```

## Was als "neu" gilt
- Neue CU/Builds, die in den Microsoft-Quellen vorhanden sind, aber nicht im
  aktuellen Katalogeintrag stehen.
- `CU_MONITORING_BACKLOG.md` führt den implementierten SQL-CU-Watch und dessen
  getrennte Erweiterungen. Ein konfigurierter Zeitplan ist kein Nachweis eines
  erfolgreichen aktuellen Quellenabgleichs.

## Erwartetes Resultat des Agents
1. `NEU`: es gibt Kataloglücken, welche Versionen betroffen sind.
2. `NO CHANGE`: Katalog ist aktuell.
3. `UNCLEAR`: Quellverfügbarkeit oder Prüfung war nicht eindeutig.

## Zusätzliche Framework-Hinweise
- Die automatische Watch-Lane liest keine Slot-, Host-, Runtime- oder
  Providerzustände. Slot-Generierung bleibt ein eigener operativer Vertrag.

## Ausgabeformat (Pflicht)
- **A Status** (`NEW` / `NO CHANGE` / `UNCLEAR`)
- **B** fehlende CU-Einträge je SQL-Version (Version, erwarteter CU, KB, Datum/Quelle)
- **C** betroffene katalogisierte Fähigkeit, Prüfzeitpunkt in UTC und Alt/Neu
- **D** Nächster manueller Schritt

## Prüfkriterium bei Unsicherheit
- Bei fehlender Quelle, nicht lesbarem Katalog oder zweifelhafter Zuordnung:
  `UNCLEAR` + genaue Lücke benennen.

## Veröffentlichbarer Workflowbericht

Der unveränderte Einzel-CU-Adapter `Tools/Common/VersionCatalogCuWatchReport.ps1` projiziert ausschließlich den
aktuellen `SqlServerLab.CuStatus/1.0`-Vertrag: `Sources`, `LatestCatalog` und
geprüfte Build-/KB-Metadaten. Lokaler `CatalogPath`, rohe `Reason`-/`Note`-Felder
und vollständige JSON-Diagnostik werden nicht veröffentlicht. Unklare oder leere
Prüfung ist keine Aktualitätsbestätigung. Der Workflow lädt nur den bereinigten
Markdownbericht hoch. Andere Quellen als die bestehende Microsoft-Learn-Lane
benötigen einen expliziten Ausbau dieses Veröffentlichungsvertrags.

Der interne Prüfadapter trennt `CU_WATCH_CHECK_FAILED`, `CU_WATCH_REPORT_FAILED`
und `CU_WATCH_INCONCLUSIVE`. Er publiziert keine ursprüngliche Exception und
unterdrückt Warn-/Informationsausgaben der Prüfaktion. Der Workflow versucht
bei einem solchen Fehler zunächst den vorhandenen monatlichen Issuehinweis und
endet anschließend fehlgeschlagen. Ein erfolgreicher Hinweis oder Upload heilt
keinen fehlgeschlagenen Quellencheck. Fehler vor dem Adapter oder fehlende
GitHub-Berechtigungen bleiben separate Infrastrukturgrenzen.

## Enger Ausbau derselben Monatslane

`Tools/Common/VersionCatalogResourceWatchAutomation.ps1` erweitert den
Veröffentlichungsvertrag ausdrücklich um genau den oben benannten SqlPackage-
Eintrag und seine exakt gebundene Learnadresse einschließlich der festen Query.
Andere Quellen, Varianten oder Familien bleiben ausgeschlossen. Der bestehende
Monatscron, Concurrency und Repo-Issuekanal werden erhalten; ein zweiter
Scheduler ist nicht vorgesehen.

Veröffentlicht werden ausschließlich validierte Ressourcen-ID, Quelle,
UTC-Zeit, katalogisierte/beobachtete Version, Status, stabile Fehlercodes,
betroffene Fähigkeit und nächste manuelle Aktion. Namen und Markdown werden
selbst erzeugt. Lokale Pfade, Host-/Slotwerte, Herstellerantworten, Exceptions,
Secretwerte und beliebige übergebene Reports bleiben ausgeschlossen.

Ressourcen-/Revisionsmarker deduplizieren den Befund über Monatsgrenzen hinweg.
Unveränderte Hinweise erzeugen keinen Write oder Kommentar. `NO_CHANGE` schließt
nur das eigene eindeutig markierte Issue; alte Monatsissues ohne diesen Marker
werden nicht automatisch migriert. Discovery liest die begrenzte vollständige
Repo-Issueliste ohne veränderbaren Labelfilter. Label-/Marker-/Bodydrift und
Scope-Mehrdeutigkeit blockieren vor Änderung.
Unbestätigte Writes bleiben Recoverybedarf und werden vor einem weiteren Create
erneut gebunden gelesen. Checkfehler und Benachrichtigungsfehler bleiben getrennt
rot; eine erfolgreiche Issueveröffentlichung heilt keinen Quellenfehler.

Defaultscope ist `catalog`. Die optionale manuelle `workflow_dispatch`-Fixture
nutzt ausschließlich `own-<32 kleine Hexzeichen>`, getrennte Marker und Receipts.
Sie verlangt zusätzlich `acceptance_resource` mit genau einer tatsächlichen
erwarteten Ressourcen-ID. Der vollständige Quellenbericht bleibt erhalten.
Alle vorhandenen Own-Identitäten und globale `watch-check`-Fehler/Recovery zählen
gegen die Grenze von einer unterschiedlichen Identität; höchstens ein POST/PATCH
pro Publishaufruf ist erlaubt. Null Kandidaten ergeben `NO_NOTICE_NEEDED`.
UNKNOWN beendet den Aufruf und verbietet Workflow-Retry; Fortsetzung erfolgt nur
im vorhandenen Runner mit `ContinuationReceiptPath`, exakter Head-/Scope-/Befundbindung
und frisch gefundenem Marker. Fehlt dieser, bleibt Recovery ohne neuen Create offen.
Der reguläre `catalog`-Scope und Cron haben keine Ressourcenauswahl oder neue Grenze.
Die aktive CU-Adresse ist der direkte lokalisierte Microsoft-Supportartikel
KB321185. Die frühere Learnadresse leitet um; automatische Redirects bleiben
im Resource-Watch-Transport verboten. Der gebundene fünfspaltige HTML-Parser
erhält den bisherigen reinen CU-/KB-/Rücknahmevertrag. Katalogisierte Builds und
Downloadpins bleiben unverändert; Git-Metadaten des Supportartikels werden
nicht als zusätzliche Bezugsadresse verwendet. Die SourceId bleibt gleich,
die neue Adresse ändert den quellgebundenen Befundhash.
Ihre tatsächliche Ausführung benötigt die konkrete Orchestratorfreigabe. Cleanup
erfordert das exakte Receipt und erwarteten Own-Scope sowie frische Repo-/ID-/
Marker-/FindingKey-Revalidierung. Es schließt eigene Issues und löscht nichts.
Jeder Receiptstatus wird vor der Zielauswahl strikt validiert; publizierte oder
deduplizierte Hinweise brauchen echtes boolesches `Verified=true` und eine
vollständige Issue-/URL-/Bodyhashbindung. Fehlende Bindung ist kein Cleanup-PASS.
Slack, Email, fremde Chats und Agentstarts werden nicht ausgelöst.
Für einen manuellen reinen Quellencheck gibt es zusätzlich `metadata_only=true`.
Dieser eigene Job hat keine Issuerechte oder Publishtoken, verlangt leere
Fixture-Eingaben und ruft den vorhandenen Runner ohne `PublishIssues` auf.
Report und Nichtveröffentlichungs-Receipt bleiben bereinigt; unklare Quellen
bleiben fehlgeschlagen. Standardlane, Monatscron und Concurrency bleiben erhalten.
Der Metadatenmodus ersetzt keine Issue-, Dedupe-, Zustellungs- oder Cronabnahme.
Ausführungs-, Dedupe- und Cleanupnachweise sowie die getrennte Cronabnahme stehen
im [Automationsvertrag](../Documentation/Architecture/RESOURCE_WATCH_AUTOMATION.md).
