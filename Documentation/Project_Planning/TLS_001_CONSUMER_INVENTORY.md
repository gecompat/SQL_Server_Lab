# TLS-001: Verbraucher, Vertragswahl und verbleibender Cutover

Stand: 2026-10-25. Diese Quellinventur konkretisiert den Consumerblock der
[Abschlussübersicht](TLS_001_COMPLETION_CHECKLIST.md). Sie beschreibt die
untersuchten Einstiegspunkte und deren offene Nachweise. Eine gefundene
Importstelle, ein Schema oder ein synthetischer Test ist keine SQL-Abnahme.

## Vertragsbasis und sichere Verwendung

Die [D4-Entscheidung](TLS_001_ISOLATED_CA_DESIGN.md#d4--koordinierter-nachfolgevertrag)
akzeptiert den bestehenden V1-/True- und V2-/False-Vertrag. Für Fachtests bleibt
V1 mit `Encrypt=True;TrustServerCertificate=True` zulässig. Ein Auftrag zur
Serveridentitätsprüfung verlangt den qualifizierten V2-Pfad und beide echten
Clientstacks. Ein Verbindungsfehler erlaubt keinen Modus- oder Zielwechsel.

Beim V1-Dateivertrag gilt die dokumentierte Discovery über
`SQL_SERVER_LAB_TEST_ENV_FILE`, sonst `SQL_SERVER_LAB_DATA_ROOT` und
`Exports/TestUmgebung.json`. Der Schemaoverride und ein ausdrücklich gesetzter
Promptpfad behalten ihren Vorrang. Ein projektspezifischer READY-Override muss
aus dem jeweiligen Consumervertrag stammen; die Lab-Standardgruppe bleibt
als Ganzes gesperrt, solange sie nicht vollständig bereit ist.

V2 wird ausdrücklich für einen eigenen Run, eine Instanz und deren StateRoot
exportiert. Vor der Verwendung prüft der öffentliche
[`Read-SqlServerLabQualifiedTestEnvironment`](../../Public/Read-SqlServerLabQualifiedTestEnvironment.ps1)-Reader
dieselben erfassten Bytes gegen Signatur, Frist und aktuelle Bindungen. Der
Consumer muss vor einer späteren Verbindung dieselben Exportbytes erneut
prüfen. Der Export enthält weder die Autorität, ein Modul auszuwählen, noch
eine Runtime-Reservierung. Das [operative Fachmodell](../Architecture/AUTHENTICATED_TLS_OPERATIONAL_LAB.md)
und der [Toolbelt-Consumervertrag](https://github.com/gecompat/SQL_Server_Toolbelt/blob/main/Documentation/Architecture/LAB_QUALIFIED_TLS_CONSUMER.md)
führen zu den jeweiligen Verfahren.

## Erfasste Verbraucherklassen

Die Quellen wurden anhand der konkreten Exportnamen und Discoveryvariablen
gesucht. Die Suche wurde für direkte Modul-, Manifest- und Adapteraufrufe
erweitert. Die folgende Liste umfasst die im TLS-001-Backlog genannten
Verbraucherklassen; einzelne Anwendungen und historische Testbelege sind
keine zusätzlichen Readerimplementierungen. Die Quellstände sind unten
ausgewiesen. Produkt- und Nachweisgrenzen bleiben getrennt.

| Verbraucher | Tatsächlicher Einstieg und Annahmen | TLS-001-Status und nächster notwendiger Schritt |
|---|---|---|
| Lab-JSON-/ENV-/Markdownexport | [Public/TestEnvironment.ps1](../../Public/TestEnvironment.ps1) erzeugt V1/True als Standard. Die ausdrückliche False-Auswahl delegiert an [AuthenticatedTlsQualification.ps1](../../Private/AuthenticatedTlsQualification.ps1) mit eigenem V2-Zielverzeichnis. | Beide Modi bestehen nebeneinander. Der qualifizierte öffentliche Reader ist auf den aktuellen Windowskontext begrenzt; öffentliche Linux- und Hyper-V-Fähigkeit bleiben offen. |
| Toolbelt-Hauptrunner | [run-lab-local.ps1](https://github.com/gecompat/SQL_Server_Toolbelt/blob/main/Tests/CI/run-lab-local.ps1) unterscheidet `Functional` und `AuthenticatedTls`. V2 verlangt expliziten Labkontext, geprüfte Bytes und frische Prüfung vor dem Login; unbekannte Versionen werden abgewiesen. | Der [Windows-V2-Cutover](../Quality/TLS_V2_CONSUMER_CUTOVER_ACCEPTANCE_2026-10-22.md) bleibt ein eigener datierter Nachweis. [LabQualifiedContract.ps1](https://github.com/gecompat/SQL_Server_Toolbelt/blob/main/Tests/CI/LabQualifiedContract.ps1) weist einen Linux-Clienthost derzeit ausdrücklich ab. |
| Eigenständige Toolbelt-Runner | Modul-, Release-, CI-, Spike- und Research-Runner übernehmen ausgewählte Definitionen des Hauptrunners per AST. Der Resolver benötigt zusätzlich die gemeinsam definierten Readerfunktionen. | Die Inventur fand 38 solche Consumer. In 25 fehlte der explizite gemeinsame Import; zusätzlich erwartete der Table-Clone-Snapshotseam eine veraltete Textlesestelle. Beide Fehler waren vor jeder SQL-Anmeldung reproduzierbar. Im Ausgangsstand erfasste die neue Prüfung 38 Importstellen statisch und bestand neun tatsächliche begrenzte Importfamilien mit 40 Fällen; die bisherigen 15 synthetischen V2-Fälle bestanden ebenfalls. Der unten abgegrenzte echte V1-Preflight bestand zehn Readerfamilien und zwei funktionale Clientfälle. Das ist kein Lauf aller Modulruntimes. CI und Integrationsheads werden in den jeweiligen PRs separat gebunden. |
| Analyze-SSIS-Integrationstests | [212_SsisPackageModelAnalysis_Runtime_Contract.ps1](https://github.com/gecompat/SQL_Server_Analyze/blob/b636c7d27be945c870581341c1916bdfc063fc3b/Code/Tests/Integration/212_SsisPackageModelAnalysis_Runtime_Contract.ps1) und [216_SsisCatalogHandover_Transport_Contract.ps1](https://github.com/gecompat/SQL_Server_Analyze/blob/b636c7d27be945c870581341c1916bdfc063fc3b/Code/Tests/Integration/216_SsisCatalogHandover_Transport_Contract.ps1) lesen einen ausdrücklich gelieferten JSON-/Schemavertrag, wählen genau ein READY-Ziel und prüfen Encrypt am Connection String. | Diese Einstiegspunkte binden keine bekannte V1-/V2-Version ausdrücklich und rufen den qualifizierten Reader nicht auf. Für eine V1-only-Fachtestgrenze ist die explizite Versionsablehnung nötig; eine V2-Nutzung braucht die vollständige Readerbindung. Ein permissiver Schemaoverride ersetzt sie nicht. Keine neue Analyze-TLS-Abnahme wird behauptet. |
| PerformanceSchulung-Szenarien | [PerformanceTrainingScenario.psm1](https://github.com/gecompat/SQL_PerformanceSchulung/blob/97c61092fdc62dd3c4999aa7e4b3f64164fdad92/Tools/PerformanceTrainingScenario/PerformanceTrainingScenario.psm1) löst ein Labmodul auf und ruft Manifest-, Run- und Adapter-APIs direkt auf. RunId, Provider, Adapter und eigenes Lifecycle-State werden gebunden. | Das ist ein direkter API-Verbraucher. Die untersuchte Szenariosteuerung liest keinen V1-/V2-Export. Der konkrete funktionale beziehungsweise authentifizierte Transportbedarf und die zugehörigen echten Client-Preflights müssen für behauptete TLS-Szenarien festgelegt und belegt werden. |
| Lokale Skripte und direkte Adapteraufrufe | Die Toolbelt-Definitionsconsumer und die beiden Analyze-Testskripte sind konkrete lokale Dateiconsumer. PerformanceSchulung nutzt direkte Lab-APIs; dessen Adapter führen SQL im gebundenen Run aus. | Zusätzliche Kopien eines Exportparsers dürfen nicht stillschweigend als qualifizierte Reader gelten. Neue oder geänderte Aufrufer werden ihrer vorhandenen Reader- oder direkten API-Grenze zugeordnet und erhalten deren Vertrags-/Frischeprüfungen. |
| ENV-/Markdownnutzer und Agenten-Prompt | Der [V1-Prompt](../User/LOCAL_SQL_TESTING_PROMPT.md) beschreibt die Standardgruppe und True/True. V2 erzeugt einen eigenen Prompt, Markdown und ENV mit False sowie dem Hinweis auf die autoritativen signierten JSON-Bytes. | ENV und Markdown enthalten keinen Ersatz für den qualifizierten JSON-Readback. Ein authentifizierter Consumer darf daraus allein keinen aktuellen TLS-PASS ableiten. Klartextkennwörter bleiben lokal und gelangen nicht in Dokumentation, Chat, Reports oder Git. |

Analyze besitzt außerdem ein eigenes
[DiagnosticLab-Preflight](https://github.com/gecompat/SQL_Server_Analyze/blob/b636c7d27be945c870581341c1916bdfc063fc3b/Lab/Orchestration/Modules/DiagnosticLab/Public/Invoke-LabPreflight.ps1).
Dieses prüft seine eigene Host-/Konfigurationsfähigkeit und ist kein
SQL_Server_Lab-Exportreader. Gleiche Funktionsnamen begründen keine gemeinsame
Capability oder Abnahme.

## Begrenzter echter V1-Preflight vom 2026-10-25

Ein eigenes kompaktes Docker-Lab mit SQL Server 2025 CU9 lieferte einen
öffentlichen V1-Export mit genau dem gewählten READY-Ziel. Zehn begrenzte
Toolbelt-Importfamilien lasen diesen tatsächlichen Export. Der CSV-Consumer
bestand den kanonischen funktionalen Preflight über `System.Data.SqlClient`
und einen getrennten ODBC-18-Preflight; beide ermittelten Build `17.0.5005.3`.
Der .NET-Pfad erzwingt `Encrypt=True`; sein Functional-Zweig liest keine
zusätzliche `encrypt_option`-DMV. ODBC prüfte zusätzlich den tatsächlichen
Sitzungswert `TRUE`. `TrustServerCertificate=True` prüft keine Serveridentität.

Der Worker bestand mit zehn Readerresultaten und zwei Clientresultaten.
Seine gesamte Prozessgruppe war vor dem öffentlichen Remove beendet. Der
eigene Run ist `REMOVED`; beide Cleanupschritte, frische ursprüngliche
Runtime-/Policybindungen sowie die Abwesenheit von eigenem Container,
Volume und festem Export sind belegt. Ein unabhängiger Review bestätigte
diesen begrenzten Nachweis ohne offene Findings.

Der übergeordnete Kontrolllauf bleibt **FAIL**: Währenddessen änderten sich
fremde Gitmetadaten und der Runtimebestand erhielt zusätzliche, vom eigenen
Run verschiedene Ressourcen. Eine globale Bestandsgleichheit oder vollständige
Preservation wird nicht behauptet. Der Parent brach vor dem Abholen der
Workerzahlen ab; seine ursprünglichen Nullwerte werden nicht als fehlende
Clientausführung umgedeutet. Original-FAIL und separate Workerresultate bleiben
erhalten. Zwei frühere Kontrollversuche scheiterten vor einer Labanlage an
UTF-8-Decodierung beziehungsweise der Trennung von Host- und Policy-Scope-ID.
Ihre ursprünglichen Belege bleiben ebenfalls erhalten.

Die ursprünglichen Exportdateien wurden bereinigt; ihre Bytehashes sind
erhalten, eine archivierte Kopie ihrer ursprünglichen Bytes wird nicht
behauptet. Dieser Nachweis verwendet Windowsclients und den funktionalen
V1-Modus. Er ergänzt weder V2-/Zertifikats-, Linux-Client- noch Wire-Nachweise.

## Offene Arbeit nach dieser Inventur

| Schritt | Verantwortungsgrenze und erforderlicher Nachweis |
|---|---|
| Eigenständige Toolbelt-Reader integrieren | Gemeinsame Definitionen und geschlossenen Snapshotseam erhalten. Cold-/Negativfälle sowie der begrenzte echte Windows-/Docker-V1-Preflight sind belegt; erforderliche aktuelle CI und genaue Integrationsheads bleiben eigene PR-Gates. Andere Consumer- und Plattformkontexte folgen den getrennten Zeilen unten. |
| Öffentlichen Linuxpfad schließen | Lab-Registry-/Actor-/Datei-/Client- und Trustbindung, qualifizierten Reader und Export im ausgewählten Linux-Ausführungskontext implementieren. Danach tatsächliche gekoppelte Toolbelt-Preflights mit beiden Stacks belegen. Die frühere Linux-Kryptomatrix ersetzt diesen öffentlichen Pfad nicht. |
| Analyze-Vertragsgrenze festlegen und prüfen | Die zwei erfassten SSIS-Dateiconsumer ausdrücklich auf ihren unterstützten Modus und ihre Version begrenzen oder an die qualifizierte Readergrenze anbinden. Vor einer Nutzung als authentifizierter Consumer eigene aktuelle Preflights und Negativfälle ausführen. |
| Direkte Schulungs-/Adapterkontexte zuordnen | Funktionszweck, verwendete Lab-API und tatsächliche TLS-Policy des jeweiligen behaupteten Szenarios prüfen. Funktionale Manifesttests und authentifizierte Clientnachweise getrennt ausweisen; vorhandene Szenarien und fremde Ressourcen erhalten. |
| Öffentlichen Hyper-V-Consumerpfad schließen | Zuerst die eigene öffentliche False-/Exportlane und fehlende Matrixzellen abnehmen; anschließend den behaupteten Consumerkontext gegen genau diesen Vertrag prüfen. Die private SQL-2025-RTM-Referenz bleibt separat. |
| Abschluss zuordnen | Für jeden behaupteten Kontext genaue Lab-/Consumerstände, Version, Modus, Drift-/Negativfälle, Clientresultate und Cleanup nennen. Offene oder nicht zutreffende Kombinationen ausdrücklich begründen. |

Die direkte menschliche Freigabe vom 2026-10-25 öffnet Toolbelt-Arbeit erneut
für die nötigen TLS-001-Schritte. Sie erweitert weder dessen fachlichen
SQL-Funktionsumfang noch das gemeinsame Wellenbudget. Analyze und
PerformanceSchulung wurden in dieser Inventur ausschließlich gelesen.

## Quellbindung und Aussagegrenze

Lab-Ausgangsstand ist PR #839 mit Merge `b5346783`; Toolbelt wurde zunächst
auf `ad018789` untersucht und für die Reparatur auf Main `10b9eef6` isoliert.
Die hier betroffenen Reader-/Governancequellen blieben zwischen diesen beiden
Toolbeltständen unverändert. Analyze wurde auf `b636c7d2`, PerformanceSchulung
auf `97c61092` untersucht. Vollständige lokale Hashbindungen bleiben privat.

Die neue lokale Prüfung führt PowerShell-Readercode mit synthetischen Dateien
aus und startet keine SQL-Verbindung, keinen Provider und kein Lab. Der
gesamte TLS-001-Scope bleibt **partial**. Weitere CU-, Browser- oder
Ressourcenvarianten werden aus dieser Inventur nicht zu zusätzlichen Pflichten.

Die Main-Integration ergänzte einen bereits ausdrücklich an den gemeinsamen
Reader gebundenen Geo-Consumer. Die erneute Quellinventur umfasst deshalb
39 statische Importstellen; die neun begrenzten Importfamilien bleiben gleich.
Die ursprünglichen 38 Stellen und der echte Preflight bleiben an ihren
damaligen Quellstand gebunden. Das ist keine zusätzliche SQL-Abnahme.
