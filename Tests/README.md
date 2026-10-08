# Tests/ – lokale und Remote-Validierung

## Pester-Runner und Ergebnisstatus

`Static/Invoke-PesterChecks.ps1` benötigt Pester ab Version 5 und führt die
Unit-/Contract-Suite unter `Pester/` aus. Maßgeblich für Status und Exitcodes
ist die [Validierungsstrategie](../Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md#pester-runnerstatus).

`Static/Fixtures/ReleaseReadinessPesterChecks.ps1` ist in die bestehende
ReleaseReadiness-Suite eingebunden. Isolierte Prozesse mit synthetischer
Modulauflösung prüfen Erfolg, fehlendes/zu altes Pester, Import-/Aufruffehler,
leere/ungültige Ergebnisse, Test-/Containerfehler und unvollständige Fälle.
Die Fixture belegt Runnerstatus und Exitcodes; echte Pester-Ausführung bleibt
ein eigener Nachweis. `Invoke-ImpactedChecks.ps1` und `Invoke-AllChecks.ps1`
behandeln jeden von null verschiedenen Suite-Exitcode als nicht grünen Gate.
Voraussetzungen und Nachweisführung: [Validierungsstrategie](../Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md#pester-runnerstatus).

`Static/Fixtures/ActionProgressDownloadLimitChecks.ps1` ist in die direkte
Fortschrittssuite eingebunden: echte eigene Loopback-HTTP-Antworten prüfen
Byteceilings vor Zielöffnung und während des Empfangs. Die Medienquellen- und
Modellkatalog-Suites prüfen die Kataloggrenzen mit synthetischen Leaves.
SQL, Provider, Speicherreservierung und kumulative Quoten sind keine daraus
abgeleiteten Nachweise. [Vertrag](../Documentation/Architecture/DOWNLOAD_STREAM_LIMITS.md).

`Static/Fixtures/AiExternalModelAuthorityChecks.ps1` ist in die External-Model-
Suite eingebunden. Sie prueft die feste lokale Autoritaetsliste und Vetos vor
Transport-/SQL-Dispatch ohne Netzwerk oder Provider; bestehende PlanKeys und
der Legacy-SQL-Lesevertrag bleiben gebunden. Diese Authority-Fixture belegt
keine DNS-/TCP-Zielbindung und keinen Cloud-Consent. Die zusätzliche
`Static/Fixtures/AiExternalModelConnectionBindingChecks.ps1` prüft den
vollständigen synthetischen DNS-Snapshot, Deadline, Vetos vor Connector und
Schlüsselöffnung, einmaligen CLR-Streamhandoff auf einem Worker sowie echte
eigene numerische TCP-Verbindungen einschließlich falschem Peerport und Cleanup.
Sie kann direkt oder innerhalb der External-Model-Suite ausgeführt werden;
am 2026-10-08 bestanden vor der Kulturkorrektur 88 Fälle auf PowerShell
7.2.24/.NET 6.0.35 und 7.6.6/.NET 10.0.12. Die spätere Erweiterung prüft
ordinale Adresswahl unter `en-US`/`cy-GB`, umgekehrte Eingaben, IPv4-Vorrang,
ungültigen Snapshot-Tail und Wiederherstellung der Aufruferkultur im `finally`.
115 Fälle bestanden auf PowerShell 7.4.20/.NET 8.0.31 und 7.6.6/.NET 10.0.12;
die Kulturkorrektur besitzt keinen neuen .NET-6- oder TLS-/HTTP-Nachweis.
TLS, HttpClient-Scheduling, native Hostaliasauflösung und
Plattformnachweise sind getrennt: die separate Windows-Mindestframeworkmatrix
ist mit 29/30 Fällen `PARTIAL`, der TLS-1.3-Sequenzfehler bleibt offen.
Unter .NET 10 bestanden sieben repräsentative Produktfälle; Diagnosevergleiche
sind keine akzeptierte Abnahme. [Nachweise und Grenzen](../Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md#lokale-external-model-autoritaeten).
Der getrennte Windows-OVMS-Gateway-Runner
prueft einen eigenen kurzlebigen numerischen HTTPS-Loopback-Endpunkt.

`Static/Fixtures/WorkflowUiJsonBodyChecks.ps1` ist in WorkflowUI eingebunden:
35 Checks mit 13 echten HTTP-Requests über den vollständigen Produktblock und
synthetischen Fach-Sinks prüfen sieben direkte POST-Reader, Überlängenheader
ohne Body, Chunked, UTF-8-Veto, Trickle-Deadline und drei gültige Folge-Requests.
Eigene Streams prüfen Sentinel und exaktes Bytelimit. Kein Produktmodul, State,
SQL oder Provider; eigener Listener und Threadjob werden beendet. Spezifische
Adapter, Headerdeadline, Parallelität, Authentifizierung und Statequotas bleiben offen.

`Static/Fixtures/WorkflowUiRequestBoundaryChecks.ps1` ist in WorkflowUI
eingebunden. Die 48 fokussierten Checks prüfen Header-/Authority-Grenzen ohne
Bodylesung und zwölf echte HTTP-Requests über zentrale Produktanweisungen.
Zehn Vetos erreichen keinen synthetischen Job; zwei erlaubte Requests tun es.
Produktmodul, State, SQL und Provider bleiben ungenutzt. Eigener Loopbacklistener
und Threadjob werden geschlossen/entfernt. Operatorauthentifizierung und
gerenderter Browser sind damit nicht abgenommen.

`Integration/Invoke-ExternalRuntimeCapabilityCatalogBrowserAcceptance.ps1` liefert die
vollständigen zwölf unveränderten Produktassets für die getrennte gerenderte
External-Languages-Katalogabnahme. Ein frisches
`.artifacts/test-runs/external-catalog-browser-<GUID-N>` bewahrt lokale Records;
der eigene Loopbacklistener ist auf vier Minuten und 512 Requests begrenzt.
Vier Bootstrapreads sind synthetisch. Die tatsächliche HTTP-Route verwendet
im isolierten Modul den öffentlichen Entscheid mit den tatsächlichen
Katalogen, Provider-Metadaten und Rezept-/Lockdateien. Vier Optionsreads und
vier Entscheidungen prüfen Docker Java/2019, Docker Python/2022, Podman R/2022
und die explizite Podman Java/2025-shared-user-Variante. Geschlossene Payloads
und DTOs, deaktivierte blockierte Optionen, Öffnen/Bearbeiten ohne Aktion und
Rücksetzen der Ausgabe beim Wiederöffnen werden gebunden. Hostprüfung und
historischer Lookup sind verboten; Produktmodulimport, State, Provider-Runtime,
Secrets, Installation und SQL bleiben ungenutzt. Der Listener schließt auf
jedem Ergebnis; die Offlinefixture ersetzt keine ausgeführte Browserabnahme.
Die gerenderte Abnahme bestand am 2026-10-07 auf `4007d414` mit 98 Requests,
36 unveränderten Produktquellhashes und genau vier öffentlichen Entscheidungen.
Keine Skriptfehler oder instrumentierten verbotenen Effekte; eigener Listener
und Tab geschlossen. Die fokussierte Offlinefixture bestand mit 48 Fällen.
Hostprüfung, historischer Lookup, Installation und SQL bleiben ungenutzt.

`Integration/Invoke-CollationCatalogBrowserAcceptance.ps1` dient der getrennten
gerenderten Collation-Katalogabnahme über einen eigenen begrenzten Loopbacklistener.
Ein frisches `.artifacts/test-runs/collation-browser-<GUID-N>` bewahrt lokale
Ready-, Operator- und Ergebnisrecords. Die vollständigen zwölf Produktassets
werden unverändert geliefert. Vier Bootstrapreads sind synthetisch; die echte
Suchroute verwendet im isolierten Modul ausschließlich HTTP-Helper, Public-
Suchbefehl und Schema-/Katalogreader. Sechs bewusste Suchen prüfen drei SQL-
Versionen, ASCII-AND/UTF-8, DEPRECATED, Nulltreffer und Zero-Token-Verhalten.
Öffnen/Bearbeiten ohne Suche, Rücksetzen beim Wiederöffnen und Schließen werden
gerendert beobachtet; achtzehn Produktquellhashes bleiben gebunden. Verbotene
State-/Provider-/Secret-/SQLleaves sind instrumentiert. Der eigene Listener
schließt auf jedem Ergebnis; private Evidence bleibt erhalten. Der Test
importiert kein vollständiges Produktmodul und startet keine Runtime. Die
fokussierte Fixture prüft Quelle, tatsächlichen Katalogreader und geschlossene
Abschlussbedingungen offline; sie ersetzt keine ausgeführte Browserabnahme.
Die gerenderte Abnahme bestand am 2026-10-07 auf `8b2aba1c` mit 105 Requests,
genau sechs öffentlichen Suchen und null instrumentierten verbotenen Effekten.
Eigenen Listener und Tab geschlossen; der fokussierte Offlinevertrag bestand
mit 36 Fällen. Der Seitenbootstrap bleibt synthetisch, SQL ungenutzt.

`Integration/Invoke-ConnectionCenterCmsFullPageAcceptance.ps1` prüft den
CMS-Einstieg im tatsächlichen vollständigen Seitenbootstrap mit synthetischem Backend.
Ein frisches `.artifacts/test-runs/cms-full-page-<GUID-N>` enthält lokale Ready-,
Operator- und Ergebnisrecords. Der eigene begrenzte Loopbacklistener liefert
unveränderte Bytes von `index.html`, CSS und allen zehn Produkt-JavaScripts;
zusammen mit der CMS-HTTP-Quelle sind dreizehn Produktquelldigests gebunden.
Vier Bootstrapendpunkte antworten ausschließlich synthetisch und lesend;
Jobpolling ist begrenzt. Andere Endpunkte werden vor Effekten abgewiesen.
Der Operator prüft vollständigen Bootstrap ohne Skriptfehler, Navigation nach
„Verbindungen und CMS“, Registrierung lesen, bewusste Prüfung und Schließen.
Der Server verlangt alle zwölf Assets, vier Bootstrapreads einschließlich
wiederholtem Jobpolling und genau zwei CMS-Aktionen. Kein Modul, State, Provider,
Secret oder SQL wird ausgeführt. Die Browserabnahme bestand am 2026-10-07 auf
`c6a1458d`: zwölf Assets, dreizehn unveränderte Produktquelldigests, 53 gemessene
Requests einschließlich 33 Job-/drei Workflowreads und genau zwei CMS-Aktionen.
Navigation, Registrierung ohne SQL-Verbindung, explizite Prüfung mit Major 17,
drei Gruppen/echtem Nullwert für Server und Schließen wurden sichtbar geprüft;
keine Skriptfehler, eigener Listener/Browser-Tab geschlossen. 32 fokussierte Checks
und sechs betroffene statische Suites bestanden. Der erste Browserlauf scheiterte
an einer leeren Bytearray-Antwort; der Fehler wurde korrigiert und die lokale
Fehlerevidence erhalten. Nativer Browser-bis-SQL-Pfad und weitere UI-Aktionen
bleiben eigene Nachweise; das Pflichtgate ist am finalen PR-Head erforderlich.

`Integration/Invoke-ConnectionCenterCmsInspectionBrowserAcceptance.ps1` dient der getrennten
gerenderten CMS-Dialog-/HTTP-Abnahme mit ausschließlich synthetischen Antworten.
Ein frisches `.artifacts/test-runs/cms-browser-<GUID-N>` im eigenen Checkout
enthält Ready-, Operator- und Ergebnisrecords. Der begrenzte eigene Loopback-
Listener liefert exaktes Produktmarkup, den unveränderten CMS-Block aus `Ui/app.js`,
CSS und die tatsächliche HTTP-Adapter-/Dispatchroute. WorkflowActions sind feste
synthetische Leaves; Modulimport, State, Provider, Secrets und SQL bleiben ausgeschlossen.
Der Operator prüft die zehn Fälle `docker15`, `podman16`, `docker17`,
`not-configured`, `unknown`, `hyperv`, `wrong-binding`, `unsafe`, `error`, `late`
in dieser Reihenfolge. Nach sichtbarer Prüfung erstellt er ausschließlich den
festen Completionrecord; die gemessenen 19 HTTP-Aktionen müssen dazu passen.
Die Late-Response wird erst nach beobachtetem Schließen explizit freigegeben.
Fixture-/Helperprüfungen laufen in der CMS-Suite. Die zehn gerenderten Fälle
bestanden am 2026-10-07 auf `56fae2de` mit exakt 19 gemessenen HTTP-Aktionen,
unveränderten vier Produktquelldigests und anschließend geschlossenem eigenem
Listener/Browser-Tab. Die fokussierte Fixture bestand mit 27 Checks einschließlich
der CMS-Auswahl für jeden neuen Einzeldateipfad; sechs betroffene statische Suites
bestanden lokal. Ganze UI-Seite und native Browser-bis-SQL-Abnahme bleiben getrennt.

`Integration/Invoke-ConnectionCenterCmsInspectionAcceptance.ps1 -Provider docker|podman -Version 2019|2022|2025`
verlangt einen frischen externen `sql-lab-cms-inspection-<GUID-N>`-Parent
und ParentOperationId. Getrennte Parent-/State-Policies binden genau einen
neuen nichtpersistenten Run der expliziten SQL-Version (Default 2025);
bestehende CMS werden nicht adoptiert.
Aktive CLI-Route und native Engineidentität müssen mit dem Custody-Pin
übereinstimmen. Registrierung und synthetische msdb-Daten sind getrenntes
Arrangement. Danach prüfen tatsächliche WorkflowActions und der echte Worker
stale Auswahl, fehlenden markierten Root und zweimal den zur angeforderten
Version passenden SQL-Major 15/16/17 mit zwei
markierten Gruppen/einem Server trotz unmarkierter Kontrollobjekte. Ganze
Rootdateien und beide CMS-Tabellen müssen unverändert bleiben. Cleanup verlangt
exakte Creationreceipts, REMOVED/COMPLETED, same-pin Ressourcenabwesenheit und
hashgesicherte Terminalkopien vor Entfernung des eigenen Parents. Fehler oder
unreturned Creation behalten den Parent. `ConnectionCenterCmsInspectionAcceptanceChecks.ps1`
prüft Custody-/Drift-/Copy-/Abwesenheitsveto synthetisch über die CMS-Suite.
Am 2026-10-07 auf `56e8aabf` bestanden Docker und Podman getrennt: stale
Auswahlveto, echter Worker mit fehlendem Root (UNKNOWN/null), anschließend
zweimal OBSERVED/17/2/1, unveränderte ganze Rootdateien/beide CMS-Tabellen und
bestätigtes Own-Cleanup mit zwei gesicherten Terminalrecords. Der bidirektionale
Schutzvergleich hatte je null Findings; Podman beobachtete eine begrenzte
Windows-Systemtask-Zeitplanänderung ohne Callerzuordnung. Zwei vorausgehende
Harnessfehler (interner Modulaufruf, leere JSON-Tabelle) sind korrigiert;
deren Runtime-Ressourcen entfernt, Fehlerparents/Evidence bleiben erhalten.
Frühere Protection-Failures bleiben unverändert. Sync, SSMS, Mitgliedsverbindungen,
gerenderte UI, Windows, weitere katalogisierte Builds und Least Privilege bleiben separat.
Die additive Auswahl von 2019/2022 besitzt einen versionsgebundenen SQL-
Preflight und DTO-Check. Am 2026-10-07 auf `ef5a8fa9` bestanden vier getrennte
frische Abnahmen: Docker/2019, Docker/2022, Podman/2019 und Podman/2022 mit
je zweimal OBSERVED/15 beziehungsweise 16/2/1, fehlendem Root UNKNOWN/null,
stale Auswahlveto, unveränderten Datei-/CMS-Tabellenhashes und bestätigtem
Own-Cleanup samt je zwei hashgesicherten Terminalkopien. Alle vier
bidirektionalen Schutzvergleiche hatten null Findings; Podman/2022 beobachtete
eine begrenzte Windows-Systemtask-Zeitplanänderung ohne Callerzuordnung.
Die Offline-Fixture bestand mit 179 Checks, darunter Versionsdrift vor
Effekt/Secret, falsche gemessene Majors und tatsächliche Create-Weitergabe.

`Integration/Invoke-ContainerPortPreviewAcceptance.ps1` prüft die getrennte
native Docker-/Podman-Portvorschau-Abnahme. Sie verlangt einen frischen
externen `sql-lab-port-preview-<GUID-N>`-Parent und ParentOperationId, bindet
eigene Parent-/State-Policies und erstellt genau einen nichtpersistenten SQL-Run.
Die Runtime muss bereits erreichbar sein. Öffentlicher Core, tatsächlicher
Console-Menürouter und in-process HTTP-Serverroute werden mit realem Inspect
ausgeführt; Ownership-Revalidierungen dürfen zusätzliche Inspectreads benötigen.
Ein gültiger CLI-/HTTP-Request hat genau einen öffentlichen Previewaufruf,
Cancel/ungültige Eingabe keinen. State-Dateibytes müssen unverändert bleiben.
Cleanup verlangt vorher exakte Claims/Creationreceipts, danach gebundene
Ressourcenabwesenheit. Unreturned/Drift/Fehler erhalten den gesamten Parent.
Im Standardmodus werden gerenderter Browser, HTTP-Netztransport,
Preview-SQL/Endpoint und Apply nicht geprüft. Am 2026-10-05 auf `bee35c5d` bestanden Docker und Podman
getrennt je fünf öffentliche Previewaufrufe, unveränderte Statebytes und
bestätigtes Own-Cleanup (REMOVED/COMPLETED, Ressourcen und Parent entfernt).
Der eigene Vorher-/Nachher-Schutzvergleich hatte null Findings/Beobachtungen;
frühere fehlgeschlagene Wellen bleiben unverändert. Dies ist kein vollständiger
kanonischer Provider-Gate oder Scope-A-Abschluss.

Der additive Modus `-BrowserAcceptance -ListenerPort 19541` verwendet denselben
eigenen Run und Cleanupvertrag. Er stellt den tatsächlichen Portdialog aus
`Ui/index.html`, CSS und JavaScript auf einem begrenzten Loopback-Testlistener
bereit und führt den tatsächlichen HTTP-Dispatch aus. Andere APIs sind gesperrt;
der vollständige UI-Server ist nicht Bestandteil dieser Abnahme. Die lokale
`browser-ready.private.json` nennt URL, eigene Wunschports und Completiondatei.
Ein externer Browseroperator öffnet den Dialog, prüft eine ungültige Eingabe,
liest Änderung/No-op/Wiederholung und schließt/öffnet ihn erneut. Bearbeitung
muss das Ergebnis löschen, Schließen die Auswahl/Eingabe verwerfen. Danach
schreibt er den festen lokalen `SqlServerLab.PortBrowserOperatorObservation/1.0`-
Record mit den vier booleschen Feldern `RenderedDialog`, `InvalidPortVeto`,
`EditingClearedResult`, `CloseClearedDialog`. Diese Beobachtungen sind keine
Runtime- oder Cleanupautorität. Der Server verlangt unabhängig davon genau zwei
inspectfreie Metadatenreads und drei gebundene öffentliche Vorschauaufrufe,
strikte DTOs, Inhaltsbindung und unveränderte Statebytes/Containerkonfiguration.
Der Listener wartet höchstens zwölf Minuten auf die Bedienung; ein Bodyread
ist zusätzlich auf zehn Sekunden und 2049 Bytes begrenzt. Fehler führen zu
unbestätigter Abnahme und dem bestehenden Recovery-/Cleanupvertrag.
`ContainerPortPreviewBrowserAcceptanceChecks.ps1` wird von WorkflowUI ausgeführt
und prüft falsche/unvollständige Evidence sowie einen unvollständigen echten
Loopback-Requestbody ohne Provideraufruf. Native Browserbelege bleiben getrennt.

Der Browsermodus bestand am 2026-10-07 getrennt unter Docker und Podman:
je zwei Metadatenreads ohne Inspect, drei öffentliche PLAN_ONLY-Aufrufe,
neun pinned Reads, unveränderte Statebytes und Containerkonfiguration sowie
bestätigte Entfernung eigener Ressourcen und Roots. Die vier UI-Beobachtungen
wurden am tatsächlich gerenderten Dialog bestätigt. Preview-SQL/Endpoint,
Port-Apply und vollständiger UI-Server sind dadurch nicht abgenommen.

Die Container-CI verwendet einen frischen expliziten eigenen StateRoot über
`Common/OwnedHostTestScope.ps1`. `Static/Invoke-OwnedHostIntegrationChecks.ps1`
prüft Policy-/Runbindung, tatsächliche Carrier und native Transportgrenzen
mit synthetischen Ressourcen; kein Provider- oder Tasknachweis.
Die vollständigen fünf Pflichtgates bleiben separat erforderlich.
[CI-Scope und Grenzen](../Documentation/Architecture/OWNED_HOST_CI_ISOLATION.md).

`Static/Invoke-StoppedHostMemoryChecks.ps1` prüft die Speicherwartung nach
Container-Stop: Hostdruck, Cachegrenze, explizites Opt-out, Remote-/Override-
Abwehr, laufende WSL-Bindung, Bindungswechsel und verzögerte Windows-Rückgabe.
Die Tests verwenden synthetische Messungen; sie belegen keine native Freigabe.
`Integration/Invoke-StoppedHostMemoryAcceptance.ps1 -Provider docker|podman`
prüft getrennt den öffentlichen Stop mit eigenem SQL-Lab, Cachefüller im
run-eigenen Volume, unverändert laufenden Nachbarn und vollständigem Cleanup.
Nur die Gesamtkapazität wird als Drucksignal simuliert; Cache und freier RAM
werden nativ gemessen. Der Runner wirkt auf den gemeinsamen WSL-Dateicache.
[Vertrag](../Documentation/Architecture/STOP_HOST_MEMORY.md).

`Static/Invoke-DiagnosticBundleChecks.ps1` prüft das read-only Diagnosebundle
mit synthetischen modernen State-Produzenten, Ownership- und Privacy-Negativen,
Schema und echten begrenzten synthetischen Kindprozessen. Provider-Readiness
ist dabei simuliert; keine Lab-Runtime wird verändert.

`Static/Invoke-AiSqlHttpsBridgeChecks.ps1` prüft Request-/Vektorvertrag und einen
eigenen Gateway-Prozess ohne SQL oder Modellrequests.
`Static/Invoke-AiExternalModelAccelerationChecks.ps1` prüft zusätzlich den
OVMS-Upstreamvertrag ausschließlich mit synthetischem Transport: numerischer
Loopback, fester `/v3/embeddings`-Pfad, exaktes Runtime-Modell, Dimension und
sanitisiertes Receipt. Dabei startet der Test weder OVMS noch einen Gateway.
`Static/Invoke-AiSharedGatewayPlanChecks.ps1` prüft den rein lesenden Vertrag
für einen gemeinsamen lokalen HTTPS-Gateway, deterministische Consumerbindung,
Secret-Referenzen, lokale Endpunkte und den ausdrücklich blockierten Status.
`Static/Invoke-AiSharedGatewayPreflightChecks.ps1` erzeugt ausschließlich
synthetische lokale Dateien und Zertifikate. Die Suite prüft Hash-, Key-, CA-,
Chain-, Gültigkeits- und SAN-Bindung, ohne Listener, Gateway oder SQL zu starten.
`Static/Invoke-AiSharedGatewayStorageChecks.ps1` prüft mit synthetischen Dateien
die geschützte atomare Registrierung, Idempotenz über zwei Prozesse, Konflikt-
und Driftablehnung sowie Fehlercleanup. Sie startet keinen Dienst oder Provider.
`Static/Invoke-AiSharedGatewayUpstreamChecks.ps1` revalidiert diesen synthetischen
Store und prüft injizierte Llama-v1- und OVMS-v3-Antworten einschließlich Modell,
Dimension, endlicher Werte, Fehlercodes und geheimnisfreiem Receipt ohne Netzwerk.
`Static/Invoke-AiSharedGatewaySessionChecks.ps1` startet ausschließlich einen
synthetischen Loopback-Upstream und einen ownergebundenen TLS-Gateway. Geprüft
werden zwei getrennte Consumer-Schlüssel, TLS-Pinning, Secret-Cleanup, Lease-
und Prozessbesitz sowie vollständiger Cleanup; SQL und Provider bleiben unberührt.
`Integration/Invoke-AiSqlHttpsBridgeAcceptance.ps1` ist die separate Docker-only-
Referenz für SQL External Model, TLS-Negative, Retrieval, SQLrestart und Cleanup.
Die native Abnahme bestand am 2026-09-21 mit sieben Embeddings, SQL-TLS-Negativen,
Retrieval vor/nach SQLrestart und eigenem Cleanup.
[Vertrag](../Documentation/Architecture/AI_SQL_HTTPS_BRIDGE.md).

`Integration/Invoke-SqlcmdPasswordParserAcceptance.ps1` charakterisiert den
echten lokalen sqlcmd-Hilfeparser ohne SQL-Verbindung. Die separate
`Integration/Invoke-SqlcmdPasswordAcceptance.ps1 -Provider docker|podman`
verwendet einen neuen operationgebundenen SQL-2025-Run mit synthetischem
führendem Minus im Passwort: Readiness, Hostquery, Healthcheck und bestätigtes
Run-/Volume-Cleanup. Sie besitzt die globale Runtime-Sperre; unklare Ownership
bewahrt den Recovery-State. Native Nachweise sind providerweise auszuführen.

`Static/Invoke-ResourceAssessmentChecks.ps1` prüft CORE-111 offline: feste
Statuspriorität, explizites Overcommit, Skip, Persistenz vor Providermutation
für die drei `New-SqlServerLab`-Providerpfade sowie hostwertfreie read-only
Legacy-/Desired-Projektion. Vertrag:
`../Documentation/Architecture/RESOURCE_ASSESSMENT_DECISION.md`.

Der private Memory-Puls besitzt `Static/Invoke-ContainerMemoryFaultChecks.ps1`
und `Integration/Invoke-ContainerMemoryFaultAcceptance.ps1 -Provider docker`
beziehungsweise `-Provider podman`. Beide nativen Varianten unterstützen
`-HardInterrupt` und verwenden frische eigene SQL-2025-Runs mit Cleanup.
`-HardInterrupt -StopAfterInterrupt` prüft am gestoppten eigenen Container die
Docker-Limit-Rücknahme beziehungsweise die unverifizierte Podman-Grenze,
jeweils mit erwartetem Recoverybedarf und anschließendem Cleanup.
Offline werden gestoppte Restoreziele und separate Limit-/SQL-Evidence geprüft.
Vertrag: `../Documentation/Architecture/CONTAINER_MEMORY_FAULT.md`.

Der interne Container-CPU-Puls besitzt die Offline-Suite
`Static/Invoke-ContainerCpuFaultChecks.ps1` sowie die getrennten nativen
`Integration/Invoke-ContainerCpuFaultAcceptance.ps1 -Provider docker` und
`-Provider podman`. Beide nativen Läufe erzeugen ausschließlich frische eigene
SQL-2025-Runs und verlangen vollständigen Cleanup. Der Vertrag steht unter
`Documentation/Architecture/CONTAINER_CPU_FAULT.md`.
Mit zusätzlichem `-HardInterrupt` wartet der Parent auf den authentifizierten
Applied-Checkpoint eines secretfreien Kindprozesses, bestätigt dessen harten
Abbruch und prüft Restore-only-Resume mit echter SQL-Probe, exakter Baseline
und bytegleichem terminalem Journal. Docker und Podman sind separat auszuführen.

## Verzeichnisse

| Verzeichnis | Inhalt |
|---|---|
| `Static/` | Import-, Export-, JSON-, Schema-, Metadaten-, Link-, Menü- und Dokumentationskonsistenz |
| `Integration/` | read-only sowie mutierende Lifecycle-, Provider-, Versions- und Parallelitäts-Smoke-Tests |

## Kurz-Readiness vor einem Pull Request

`Tests/Static/Invoke-ScenarioCapabilityDecisionChecks.ps1` prüft den privaten
SCN-803-Entscheid ausschließlich mit synthetischem JSON: Capability-Mengen,
strikte Evidence-Bindung, Ablaufzeiten, vollständige Eingabevalidierung und
deterministische sanitisierte Ergebnisse. Es entstehen keine Runtime- oder
Journaldateien; der Test ist kein SQL-/Provider-Nachweis.

`Tests/Static/Invoke-ScenarioExecutorChecks.ps1` prüft den internen synthetischen
SCN-802/SCN-804-Executor einschließlich Cancellation, globalen und individuellen
Phasenfristen, unabhängigem Cleanupbudget, Fehlern, Ownership,
Journalintegrität und Resume nach hartem Abbruch eines eigenen Kindprozesses.
Plan `0.2` erzwingt begrenzte Primärphasencaps; alte Pläne und bei Resume
geänderte Caps werden vor Mutation abgewiesen.
Er erzeugt ausschließlich temporäre lokale Fixtures, keine SQL-Umgebungen.

Der lokale Security-Tool-Katalog-/Planvertrag wird mit
`Tests/Static/Invoke-SecurityToolCatalogChecks.ps1` ausschließlich anhand
synthetischer Katalogdaten geprüft. Die produktive Allowlist bleibt leer;
Provider-Runtime und kryptographische Beschaffung sind kein Teil dieses Tests.

Die CI ermittelt die betroffenen Suites aus den geänderten Pfaden. Lokal kann
dieselbe Auswahl verwendet werden:

```powershell
$paths = git diff --name-only origin/main...HEAD
.\Tests\Static\Invoke-ImpactedChecks.ps1 -ChangedPath $paths
```

Die vollständige statische Regression bleibt für Nightly, Release oder eine
bewusste manuelle Abnahme verfügbar:

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
```

Bei Hyper-V-relevanten Änderungen zusätzlich:

```powershell
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
```

Für einen nach einem fehlgeschlagenen nativen Hyper-V-Test eindeutig
zurückgebliebenen `lifecycle=test`-Run gibt es den manuellen GitHub-Workflow
`Hyper-V Scoped Test-Run Cleanup`. Er läuft nur bei Dispatch von `main`,
akzeptiert ausschließlich die kanonische RunId und prüft lokalen State,
Cleanup-Plan sowie die Live-VM-Identität vor dem öffentlichen Cleanup. Er ist
kein regulärer Smoke-Test und darf weder gemeinsame noch produktive
Umgebungen entfernen.

Die vertiefte Matrix fuer reale Samples, Ressourcen- und Storageaenderungen ist
in [CLI_ACCEPTANCE_MATRIX.md](../Documentation/Quality/CLI_ACCEPTANCE_MATRIX.md)
dokumentiert. Ihre ausfuehrbaren Einstiege sind:

```powershell
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider docker -Version 2022-CU18
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider podman -Version 2022-CU18
.\Tests\Integration\Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerInstanceStoreAcceptance.ps1 -Provider podman
.\Tests\Integration\Invoke-PersistentStorageRemovalExecutorAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-PersistentStorageRemovalExecutorAcceptance.ps1 -Provider podman
.\Tests\Integration\Invoke-ContainerRuntimeScopeAcceptance.ps1
.\Tests\Integration\Invoke-ContainerToolAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerToolAcceptance.ps1 -Provider podman
.\Tests\Integration\Invoke-HyperVCliAcceptance.ps1 -MediaRoot D:\Lab_Base -SqlVersion 2025
.\Tests\Integration\Invoke-HyperVSqlPreparedImageAcceptance.ps1
.\Tests\Integration\Invoke-HyperVSqlConfigurationReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVSqlConfigurationReconcileAcceptanceBootstrap.ps1
.\Tests\Integration\Invoke-HyperVSqlPortReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVSqlPortReconcileAcceptanceBootstrap.ps1
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVSampleManifestAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVDatabasePackageAttachAcceptance.ps1 `
    -RunId '<laufender-verwalteter-sql-2025-run>'
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptanceBootstrap.ps1 `
    -MediaRoot D:\Lab_Base
.\Tests\Integration\Invoke-HyperVStorageAcceptance.ps1 `
    -StorageIntentPath .\Schemas\hyperv-storage-n5-intent.sample.json `
    -MediaRoot D:\Lab_Base
```

`Invoke-ContainerToolAcceptance` erzeugt zusätzlich ein synthetisches BACPAC
und prüft dessen scoped SqlPackage-Import einschließlich Datenrücklauf und
Aufräumen der temporären Containerdatei.

Der Testdatenbank-Reconcile-Runner verwendet für seine Sample-Bibliothek einen
prozesslokalen temporären Root. Er belegt im selben isolierten Hyper-V-Lauf die
Erzeugung, Hashprüfung, bevorzugte Wiederverwendung und abschließende
eigentumsgebundene Entfernung einer `LAB_GENERATED`-Chinook-Baseline; globale
Testdaten-Bibliotheken bleiben unverändert.

Der Mehrfach-Sample-Manifest-Runner führt zwei frische sequenzielle
SQL-2025-Prepared-Runs mit Chinook und Northwind aus, teilt nur seinen
isolierten Testdaten-Root und verlangt im zweiten Run identische
`LAB_GENERATED`-Baseline-IDs, Keys, Hashes sowie Manifest-Locks. Bis zum ersten
nativen erfolgreichen Lauf bleibt seine Evidence `NOT_EXECUTED`.

Der Datenbankpaket-Attach-Runner verwendet ressourcenschonend einen expliziten
laufenden, verwalteten SQL-2025-Run oder erzeugt ohne `-RunId` genau einen
isolierten Prepared-Run. Er publiziert eine sauber detached MDF/NDF/LDF-
Dateimenge in einem temporären `Lab_Data`-Root und prüft den öffentlichen
pfadfreien WhatIf-/Attach-Pfad, PowerShell-Direct-Kopie, Gast-Hashes, Inhalt,
Journal und scopegebundenen Cleanup. Der separate lokale Windows-SQL-Runner
deckt den FILESTREAM-Dateibaum ab.

Der SQL-Konfigurationsrunner erzeugt einen eigenen Prepared-Image-Klon und
prüft Plan, `WhatIf`, Live-Reconcile, Trace-Flag-Ownership, den Fortbestand
eines fremden Runtime-Flags, einen ausschließlichen SQL-Dienstrestart für einen
nicht dynamischen Wert, Desired-State-Rückkehr, No-op und Cleanup. Der Bootstrap
erzeugt zuvor ein isoliertes SQL-2025-Prepared-Artifact und entfernt es nur nach
erfolgreichem Runner-Cleanup. Beide Einstiege behalten bei Fehlern die exakten
Recovery-IDs; eine positive native Ausführung ist noch `NOT_EXECUTED`.

Der SQL-Port-Runner erzeugt ausschließlich im neuen Gast eine kontrollierte
TCP-/Firewall-Drift und prüft anschließend Plan, `WhatIf`, den alleinigen SQL-
Dienstrestart, Connection-State, No-op und vollständigen Cleanup. Der getrennte
Bootstrap besitzt denselben isolierten Artifact-/Recovery-Vertrag; eine
positive native Ausführung ist noch `NOT_EXECUTED`.

Der letzte Runner ist der ausführbare Vertrag für Gate N5. Er startet nur,
wenn vier TempDB-Datendateien auf mindestens zwei beziehungsweise der im Intent
geforderten höheren Zahl nachweislich getrennter Backing Devices liegen und das
TempDB-Log einen eigenen Selector und damit eine eigene VHDX-Lane besitzt. Das
mitgelieferte Referenz-Intent verwendet drei Geräte mit der Verteilung 2/1/1.
Er erzeugt State
und Cleanup-Plan vor der ersten VM-Mutation, prüft SQL-Dienstrestart, CREATE,
einen synthetischen Backup/Restore-Roundtrip, VM-Restart und entfernt danach
VM, Child-VHDX sowie alle zusätzlichen run-eigenen VHDX. Ein vorhandener
Runner oder ein grüner statischer Check ist noch kein Runtime-Nachweis.

Interpretation:

- `SKIP`: Provider nicht erreichbar/fehlend oder fehlende Elevation
- `FAIL`: Erreichbarer Provider hat einen harten Fehler, Exitcode ist `1`
- `PASS`: Testpfad ist vollständig erfolgreich

## Statische Prüfungen

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-BatchWorkflowChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-ReadinessContractChecks.ps1
.\Tests\Static\Invoke-ReconcileContractChecks.ps1
.\Tests\Static\Invoke-ReconcileActionContractChecks.ps1
.\Tests\Static\Invoke-HyperVResourceReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVStorageReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVStorageReconcileAcceptanceChecks.ps1
.\Tests\Static\Invoke-HyperVSqlStorageReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVSqlStorageReconcileAcceptanceChecks.ps1
.\Tests\Static\Invoke-HyperVSqlConfigurationReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVSqlPortReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVTestDatabaseReconcileChecks.ps1
.\Tests\Static\Invoke-ExternalRuntimeReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVExternalRuntimeReconcileChecks.ps1
.\Tests\Static\Invoke-StorageFilePlacementChecks.ps1
.\Tests\Static\Invoke-HyperVResourceMigrationChecks.ps1
.\Tests\Static\Invoke-HyperVImageMigrationChecks.ps1
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
.\Tests\Static\Invoke-ArtifactResolverChecks.ps1
.\Tests\Static\Invoke-SampleHandlerChecks.ps1
.\Tests\Static\Invoke-ProjectAdapterChecks.ps1
.\Tests\Static\Invoke-CleanupRecoveryChecks.ps1
.\Tests\Static\Invoke-CleanupAuditChecks.ps1
.\Tests\Static\Invoke-PersistentStorageCatalogChecks.ps1
.\Tests\Static\Invoke-PersistentStorageRemovalPlanChecks.ps1
.\Tests\Static\Invoke-PersistentStorageRemovalExecutorChecks.ps1
.\Tests\Static\Invoke-DatabaseMigrationDependencyChecks.ps1
.\Tests\Static\Invoke-AiScenarioChecks.ps1
.\Tests\Static\Invoke-ContainerInstanceStoreChecks.ps1
.\Tests\Static\Invoke-ContainerRuntimeScopeChecks.ps1
.\Tests\Static\Invoke-HostToolResolutionChecks.ps1
.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1
.\Tests\Static\Invoke-PesterChecks.ps1
.\Tests\Static\Invoke-ReleaseReadinessChecks.ps1
.\Tests\Static\Invoke-ReleaseArtifactChecks.ps1
```

Die Release-Artefaktprüfung verwendet isolierte Git-Fixtures. Sie prüft
mutationsfreies `WhatIf`, saubere Quellen, Ausschluss lokaler Daten,
Pfadumleitungen, Teilpublikation, ZIP-/Hash-Integrität und den Import des
tatsächlich entpackten Moduls. Zusätzliche eigene PowerShell-Kindprozesse
werden an vier Publikationsgrenzen hart beendet. Intent, Abschlussquittung
und rein lesende Inspektion trennen unvollständige Artefakte von einem
vollständigen, bytegeprüften Stand mit möglichen Stagingresten. Recordlimits,
Inhaltsdrift, Traversal und leere Reparsepunkte werden ebenfalls geprüft.
Sie startet keine Provider-Runtime. [Vertrag](../Documentation/Architecture/LOCAL_RELEASE_PUBLICATION.md).

Die native Vector-Core-Abnahme wird für die beiden Linux-Provider getrennt
ausgeführt. Jeder Lauf provisioniert ein eigenes SQL-2025-Lab und benötigt
weder Modell-Download noch Internetzugriff:

```powershell
.\Tests\Integration\Invoke-AiVectorCoreAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiVectorCoreAcceptance.ps1 -Provider podman
```

Die separate Abnahmeversion 1.0 testet SQL-2025-Preview-Vektorindizes mit
`CREATE VECTOR INDEX` und `VECTOR_SEARCH`/`TOP_N`. Sie bindet den tatsächlichen
SQL-Build und die Indexversion, vergleicht vier synthetische Suchfälle mit
exakter Suche (Recall@10 mindestens 0,8; der aktuelle Lauf liefert in allen
vier Fällen `MinimumRecallAt10=1,0`), prüft Distanz und Filter sowie
Persistenz nach Stop/Start. Laufzeiten sind Messwerte dieses kleinen Tests,
keine Performancezusage. Neuere inkompatible Indexsemantik benötigt eine
angepasste beziehungsweise eigene Testversion. Die getrennten nativen Läufe
vom 2026-09-10 bestanden unter Docker und Podman auf SQL-Build `17.0.4075.5`,
jeweils mit `Preview=true`, `Compatibility Level 170`, `4096` Vektoren, je 32
Dimensionen, `MinimumRecallAt10=1,0` vor/nach Restart und Cleanup `CLEANUP_SUCCEEDED`.
Dieser Build meldet Indexparameter ohne numerisches Versionsfeld; das Ergebnis
kennzeichnet diese tatsächlich beobachtete Form als `sql2025-unversioned` und
erfindet keine Versionsnummer.

```powershell
.\Tests\Integration\Invoke-AiVectorIndexAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiVectorIndexAcceptance.ps1 -Provider podman
```

Der optionale Ollama-Cloud-Smoke sendet genau einen synthetischen Prompt und
benötigt eine lokale `.env`-Datei mit dem Schlüssel `OLLAMA`:

```powershell
.\Tests\Integration\Invoke-AiOllamaCloudAcceptance.ps1 -SecretFilePath 'D:\Lab1_Base\.env'
```

Lokale Embedding- und Generation-Modelle werden mit getrennten nativen
Providerläufen, dynamischem Loopback-Port, Live-Digests, Restart und Cleanup
abgenommen:

```powershell
.\Tests\Integration\Invoke-AiOllamaContainerAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiOllamaContainerAcceptance.ps1 -Provider podman
```

Der vollständige lokale RAG-Pfad verbindet dieselben Modelle mit einer echten,
flüchtigen SQL-Server-2025-Vektorsuche und bewertet den gebundenen Golden-Fall
blockierend. Docker und Podman werden getrennt samt Restart und Cleanup geprüft:

```powershell
.\Tests\Integration\Invoke-AiRagContainerAcceptance.ps1 -Provider docker -TimeoutSeconds 1800
.\Tests\Integration\Invoke-AiRagContainerAcceptance.ps1 -Provider podman -TimeoutSeconds 1800
```

Der Golden-Lauf verwendet einen run-eigenen Ollama-Bind-Mount, den globalen Runtime-Mutex und eine tokengebundene Container-ID. Ohne `-KeepOnFailure` bestätigt er SQL-, Container- und Storage-Cleanup vor `PASS`; `-KeepOnFailure` ist ausschließlich für die Recovery eines fehlgeschlagenen eigenen Laufs vorgesehen.

Docker und Podman bestanden am 2026-09-21 den festen Fall `backup-frequency`,
Golden-Metriken, SQL-/Ollama-Restart und vollständiges eigenes Cleanup.
Modellpaarung und Inferenzlimits blieben unverändert. Bei Fehlern bleibt ein
ignorierter Receipt unter `.artifacts/test-runs/ai-golden-podman-acceptance/`
auch nach Temp-Cleanup erhalten. Er enthält nur Provider, Bereitstellungs-,
Download-, erste beziehungsweise Restart-Phase, einen freigegebenen Fehlercode
und die aus der bekannten lokalen
RAG-Aufrufstelle abgeleitete Einordnung Embedding/Generierung oder `UNCLASSIFIED`.

Für bereits vorhandenes Host-`embeddinggemma:latest` mit ausdrücklich gewählter
HTTPS-Cloudgeneration gibt es eine separate synthetische AdHoc-Abnahme:

```powershell
.\Tests\Integration\Invoke-AiRagExistingOllamaAcceptance.ps1 -Provider podman -SecretFilePath $secretFile
```

Sie prüft zwei feste Retrievaltreffer über einen eigenen SQLrestart, höchstens
zwei Cloudrequests ohne Retry, unveränderte Host-Tags und exakte Container-/
Volume-Abwesenheit nach Cleanup. Hostmodelle werden weder heruntergeladen noch
entfernt; der Hostdienst wird nicht neugestartet. `PASS` kommt erst nach dem
Cleanup. Docker benötigt einen getrennten Aufruf. Dies ist kein unverändertes
Golden-v1-Gate und keine allgemeine Antwortqualitätszusage. Der genaue
[Vertrag und Evidencestand](../Documentation/Architecture/AI_RAG_EXISTING_OLLAMA.md)
bleiben maßgeblich.

Derselbe Container-Harness unterstützt `-LocalGeneration -IncludeDiagnostic`
mit vorhandenem Qwen, ohne Cloudsecret. Docker und Podman prüfen RAG/Agent
vor und nach SQLrestart und vollständiges Cleanup getrennt. Der neue
`Invoke-AiHyperVOwnRunAcceptance.ps1` benötigt ein explizites `ArtifactId` und
prüft mit `PreflightOnly` ausschließlich die Voraussetzungen. Der vollständige
Lauf ist über den manuellen Workflowmodus `ai-rag-own-run-acceptance` verfügbar;
[Vertrag und native Grenzen](../Documentation/Architecture/AI_HYPERV_OWN_RUN_ACCEPTANCE.md)
bleiben maßgeblich.

Das zusätzliche Nomic-v1.5-Profil wird mit demselben eigenen SQL-Run-Harness
und rein lokaler Generierung geprüft:

```powershell
.\Tests\Integration\Invoke-AiRagExistingOllamaAcceptance.ps1 -Provider podman `
    -LocalGeneration -EmbeddingModelKey ollama-nomic-embed-text-v1-5
```

Der Host muss `nomic-embed-text:latest` und das lokale Qwen-Modell bereits
enthalten. Der Harness verändert das Hostmodellinventar nicht. Docker und
Podman bestanden am 2026-09-22 getrennt mit SQLrestart und vollständigem
eigenem Cleanup.

Der mehrsprachige 1024-dimensionale BGE-M3-Pfad verwendet denselben Harness:

```powershell
.\Tests\Integration\Invoke-AiRagExistingOllamaAcceptance.ps1 -Provider podman `
    -LocalGeneration -EmbeddingModelKey ollama-bge-m3-latest
```

Der Host muss dafür zusätzlich `bge-m3:latest` enthalten. Docker und Podman
bestanden am 2026-09-22 getrennt mit festen SQL-Top-Treffern vor und nach
SQLrestart sowie vollständigem eigenem Cleanup.

Der read-only Diagnose-Agent wird mit echten katalogisierten SQL-Abfragen,
kurzlebigem Login, lokalem Modell, Login-Cleanup und Restart getrennt geprüft:

```powershell
.\Tests\Integration\Invoke-AiDiagnosticAgentContainerAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiDiagnosticAgentContainerAcceptance.ps1 -Provider podman
```

Für einen vorhandenen verwalteten Hyper-V-SQL-2025-Run verbindet der
Controller-Nachweis RAG und read-only Diagnose mit einem scopegebundenen
Ollama-Container. Er entfernt den übergebenen Run nie:

```powershell
.\Tests\Integration\Invoke-AiHyperVAcceptance.ps1 `
    -RunId '<laufender-verwalteter-hyperv-sql-2025-run>' `
    -SaPassword $password `
    -OllamaProvider docker
```

Die statischen Prüfungen benötigen keine laufende SQL-Server-Instanz. Sie kontrollieren unter anderem:

- JSON-Syntax der Kataloge, Schemas und Beispiele;
- Existenz referenzierter Schema-Dateien;
- Import des Modulmanifests;
- Übereinstimmung von `FunctionsToExport` und tatsächlich verfügbaren Funktionen;
- persistente Batch-/Operation-Verträge, deterministische Mengenexpansion,
  Zwei-Worker-/HyperVHeavy-Limits, Fehlerisolation, User-Gates und Resume;
- schema- und fachgerechte Manifest-Erstellung ohne Provisionierung;
- Ablehnung unbekannter Felder, doppelter IDs, Providerkonflikte und inkompatibler Datenbankoptionen;
- Existenz der in Provider-Metadaten angegebenen Module;
- zentrale Dokumentationslinks;
- SQL- und Datenbank-Readiness-Verträge;
- Read-only Reconcile-Vertrag: versionierter Desired/Actual/Diff/Action-Plan,
  No-op, providergebundene Vorschläge, fail-closed Runtime-Zustände und
  Geheimnisfreiheit;
- Reconcile-Executor-Vertrag: `Invoke-SqlServerLabReconcileAction` mit
  unterstütztem `START`/`STOP`, `-WhatIf`, mixed-operation-Schutz und
  geheimnissicherem Ergebnis;
- External-Runtime-Reconcile-Vertrag: versionsbewusster SQL-2019-/2022-/2025-
  Container-Refresh, Nicht-Software-Drift-/Removal-Gates, sanitisiertes
  `-WhatIf`, Journal, Rollback, Umschaltreihenfolge und Rückweg vom letzten
  Runtime-Image zum katalogisierten SQL-Basisimage ohne vorzeitiges Löschen der
  Runtime-Sidecars;
- portabler Storage-Intent, lokale Selector-/Topologiebindung, vollständige
  SQL-Dateipläne und der getrennte Runtime-Receipt-Vertrag;
- Hyper-V-Legacy-Migration: schema-valides read-only Inventar, Checkpoint-
  Blocker, `-WhatIf`, Hash-/VHDX-Verifikation, journalisiertes Resume nach
  unterbrochenem Parent-Reparent, getrennte Quell-/Ziel-Child-Hashes, zwei
  Neustartprüfungen, Erhalt externer SQL-Lanes, Quell-Cleanup erst nach
  erfolgreicher Zielbindung und automatisches Resume des Image-Cleanup;
- Hyper-V-Image-Migration: exaktes Artifact-/Hash-Inventar, Fremdbelegungs-
  und Planmanipulationsschutz, hashidentische Veröffentlichung im gebundenen
  Image-Store sowie `WAITING_FOR_CONSUMERS` bis zum referenzfreien Resume-
  Cleanup;
- Pester-Vertrag: projektspezifische Baseline, Manifest-/Exportkonsistenz und
  deterministisch ausführbare Unit-/Contract-Tests unter `Tests/Pester`; der
  reguläre Runner wertet das Ergebnis direkt aus und hinterlässt keinen XML-
  Bericht im Repository;
- Ausschluss bekannter veralteter Beispiele und Statusangaben.
- ProviderSubRuns, Mixed-Provider-Beispiel und Cleanup-Zuordnung.
- Trust Store, inhaltsadressierten Artifact Cache, Quarantäne und sanitisiertes Run Lock mit ausschliesslich synthetischen Testbytes.
- Sample-Backup-Handler-Vertrag: Katalogfilterung, Auflösung, Idempotenz- und Trust-Metadaten sowie den nicht interaktiven `TRUST_REQUIRED`-Pfad ohne Netzwerk oder Container.
- Project-Adapter-Vertrag: Schema, Versions- und Capability-Gates sowie die Pfadgrenzen des Adapter-Roots anhand manipulierter Kopien.
- Cleanup-/Recovery-Vertrag: sichtbarer Providerfehler, persistierter
  `RECOVERY_REQUIRED`-State, Fehlerhistorie und erfolgreicher Wiederholungsversuch.
- Storage-Residency-Inventar: stabile Objektidentitäten, host-sichtbares
  `Lab_Data`, native Runtime-Volumes, externe Referenzen, Retention,
  Orphan-Kandidaten und ausdrücklich unverifizierbares physisches Backing.
- Podman-Bootstrap: bereits erreichbare Runtime, eindeutige Machine-Auswahl,
  Startfehler, Timeout und hostweit serialisierter Parallelstart.

Der interaktive Menüpfad darf das bereits laufende Modul nicht innerhalb von `Invoke-SqlServerLab` erneut mit `Import-Module -Force` laden. Eine Selbst-Neuladung entfernt die gerade verwendeten Hilfsfunktionen aus dem Funktionskontext.

## Einzelprovider-Smoke-Test

Der bestehende Test prüft einen explizit gewählten Provider vollständig:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider hyperv
```

`-Provider auto` wählt weiterhin genau einen erreichbaren Container-Provider, bevorzugt Docker vor Podman. Ein erfolgreicher Docker-Lauf ist kein Nachweis für Podman und umgekehrt.

`-Provider hyperv` startet den Hyper-V-native Smoke-Test (`Invoke-HyperVSmokeTest.ps1`) und überprüft damit ausschließlich den VM-/VHDX-/Image-Builder-Lifecycle (ohne SQL-Containerlaufzeit). Nach Run- und Builder-Cleanup entfernt der Test auch alle von ihm veröffentlichten synthetischen Registry-Artefakte; ein verbliebenes Test-Image lässt den Lauf fehlschlagen.

## Gemischter Container-Provider-Smoke-Test

Der folgende Test prüft Docker und Podman innerhalb eines gemeinsamen Runs:

```powershell
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
```

Er benötigt einen Runner, auf dem beide Runtimes erreichbar sind. Die beiden
Instanzen gehören zu einem einzelnen Lab und werden im Lifecycle nicht parallel
als unabhängige Jobs provisioniert.

Eine vorhandene, gestoppte Podman-Machine wird vor Podman- und Mixed-Smokes
durch `Tests/Integration/Initialize-PodmanRuntime.ps1` automatisch gestartet.
Podman muss installiert und mindestens eine Machine bereits angelegt sein.

## Batch-/Queue-Runtime-Smoke-Test

Der Batch-Smoke erzeugt zwei Umgebungen über die persistente Queue, führt sie
mit zwei Workern aus, prüft eindeutige RunIds und idempotentes Scheduler-Resume
und baut anschließend beide Operation-Scopes wieder ab. Das synthetische
SA-Passwort wird nur über eine temporäre `SQL_SERVER_LAB_SECRET_*`-
Prozessvariable an die Worker vererbt.

```powershell
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 `
    -Provider hyperv `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

Der Hyper-V-Workflow kann denselben Nachweis gezielt und erhöht auf dem
Self-hosted Runner ausführen, ohne den Nightly-Lauf zu wiederholen. Der Modus
`slot-batch` wählt ohne explizite Artifact-ID das neueste reale `OS_SEALED`-
Artifact und entfernt beide erzeugten Slot-Scopes nach dem Test.

Der Modus `shared-environments` ist der eng begrenzte Bereitschaftsnachweis für
die dauerhaft registrierte Testgruppe. Er startet nur gebundene Windows-VMs und
vorhandene SQL-Engine-Dienste, falls sie nicht laufen, und führt anschließend
die bestehende SQL-/CMS-Abnahme für alle sechs Ziele aus. Er provisioniert oder
löscht keine Testumgebung und ersetzt keinen Nightly-Lauf.

## Backup-/Restore-Smoke-Test

Der echte Restore-Test verwendet ausschliesslich eine zur Laufzeit erzeugte
synthetische Datenbank. Er erzeugt ein temporaeres `.bak`, prueft dessen
SHA-256 und stellt es ueber die gespeicherte Run-/Providerbindung wieder her:

```powershell
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

Die Remote-Workflows fuehren den Test nach dem jeweiligen SQL-2025-Lifecycle
für Docker beziehungsweise Podman unter demselben hostweiten Mutex aus.

Der lokale PSR-008-Cross-Provider-Nachweis verwendet zusätzlich dieselbe
test-eigene Quelle für Docker → Podman und registriert nur den sanitierten
Inhaltsdigest. Die Backup-Erstellung führt dabei auch das read-only PSR-010-
Inventar aus und speichert nur Serverobjekt-/TDE-Kategorien und Counts, keine
Objekt-, Host-, Credential- oder Schlüsselnamen. FILESTREAM ist für diesen
Linux-Container-Paarlauf capability-basiert `NOT_APPLICABLE`; eine positive
FILESTREAM-Evidence darf daraus nicht abgeleitet werden:

```powershell
.\Tests\Integration\Invoke-BackupLibraryCrossProviderAcceptance.ps1
```

Der native Vorprüfungsnachweis bleibt getrennt je Provider und erzeugt keine
Wiederherstellung oder Übertragung:

```powershell
.\Tests\Integration\Invoke-PortableContainerTransferPreflightAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-PortableContainerTransferPreflightAcceptance.ps1 -Provider podman
```

## Provider-Referenztest

Der bevorzugte übergreifende Test ist:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

Ohne weitere Parameter werden alle implementierten und lokal erreichbaren Provider erkannt. Pro Provider wird ein vollständiger Lifecycle mit der Referenzversion ausgeführt:

```text
Provisionierung
→ Datenbank
→ SQL-Skript
→ Restart
→ Persistenzprüfung
→ Stop
→ Start
→ Cleanup
```

Nicht erreichbare Provider werden als `SKIP` ausgewiesen. Ein erreichbarer, aber fehlerhafter Provider führt zu `FAIL` und Exitcode `1`.

SQL_Server_Lab prüft im eigenen Runtime-Gate genau die Referenzversion SQL
Server 2025. Der Katalog bleibt versionsoffen, aber reale Kompatibilitätsläufe
für 2019 und 2022 gehören in die Partnerprojekte SQL Analyze und Toolbelt, in
denen die versionsabhängigen Workflows tatsächlich verwendet werden.

### Parallelitätsprüfung

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -IncludeParallel
```

Der Paralleltest prüft gleichzeitig laufende Labs je verfügbarem Provider.
Aktuell werden bis zu vier SQL-Server-2025-Szenarien verwendet:

- zweimal Docker / SQL Server 2025;
- zweimal Podman / SQL Server 2025.

Geprüft werden:

- eindeutige RunIds und ScopeIds;
- eindeutige Hostports;
- voneinander getrennte Run-States;
- isolierter Cleanup eines Runs;
- Fortbestand der übrigen Runs;
- vollständiger abschließender Cleanup.

### Erweiterte lokale Parallelitätsabnahme

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -IncludeParallel
```

## Remote Runner

Der Workflow `PR Gate` führt bei Pull Requests auf Windows und Ubuntu nur die
von `Tools/Get-CiTestSelection.ps1` ermittelten statischen Suites aus. Je nach
Änderungsbereich wird höchstens der passende Docker-, Podman-, Mixed-, Hyper-V-
oder Adapter-Smoke zugeschaltet. Reine Dokumentationsänderungen starten keine
Runtime. Unbekannte produktive Änderungen verwenden Docker als sicheren
repräsentativen Fallback.

Ein Push auf `main` startet keine erneute Vollmatrix. Der tägliche Workflow
`Nightly Regression` führt stattdessen alle statischen Suites, alle Runtime-
Smokes und die getrennt autorisierte Shared-Abnahme aus. Der gesamte statische
Matrixjob erhält je Plattform 40 Minuten; einzelne Suite-/Previewfristen bleiben
erhalten. Schedule autorisiert die gemeinsam exportierten SQL-Testumgebungen
nicht: Ihre SQL-/CMS-Abnahme benötigt einen manuellen Aufruf desselben
Repositorys mit `confirm_shared_mutation=true`. Der belegte Ausschluss bleibt
`NOT_EXECUTED` / `NOT_AUTHORIZED`.
Die Host-Tool-Suite extrahiert die tatsächliche Podman-Verfügbarkeitsfunktion
und prüft mit synthetischer Recording-Bridge die absoluten Resolveraufrufe,
StateRoot, exakten Argumente und Fehlerpfade ohne native Podman-Ausführung.
Für den lokalen Folgestand sind die zehn grünen Suites des ursprünglichen
betroffenen Laufs und der spätere unveränderte Workflow-UI-PASS mit 72 Checks
getrennt belegt. Der ursprüngliche Elf-Suite-Lauf bleibt wegen eines
60-Sekunden-Fixturetimeouts fehlgeschlagen; der instrumentierte Diagnose-PASS
ist kein Produktnachweis. Die vollständige 134-Suite-Matrix für Windows und
Ubuntu, PowerShell 7.2/.NET 6 und die fünf Providerabnahmen bleiben
`NOT_EXECUTED`; #675 bleibt offen. Einzelheiten stehen in der
[Validierungsstrategie](../Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md#host-tool-auflösung-betroffen).
Die bestehende Vollregressionsliste enthält noch keine Standalone-
`Invoke-TestGroupGuidanceChecks.ps1`; deren Aufnahme bleibt ein separater Scope.
Der native Gruppen-Lifecycle kann ergänzend mit
`Invoke-TestEnvironmentGroupLifecycle.ps1` ausgeführt werden; er beweist den
öffentlichen Ablauf Start, Live-Export `READY`, nicht-destruktiver Windows-Stopp
und fail-closed Export bei unveränderten Registrierungen und Linux-Mitgliedern.
Im garantierten Abschluss stellt er alle Windows-Mitglieder wieder bis
`READY` bereit, damit der Nachweis die persistente Testgruppe nicht außer
Betrieb hinterlässt.
Fehler werden in einem wiederverwendeten GitHub-Issue sichtbar gehalten. Die
frische Hyper-V-/SQL-Installation läuft zusätzlich wöchentlich oder manuell.

Self-hosted Runtime-Jobs aus Pull Requests werden nur für Branches desselben
Repositories ausgeführt. Fork-Code erhält keinen Zugriff auf die privilegierten
SQL-/Hyper-V-Runner und wird auf GitHub-hosted Runnern statisch geprüft; die
vollständige Runtime-Abdeckung folgt über den vertrauenswürdigen Nightly-Lauf
von `main`.

Die Runtime-Tests verwenden ausschließlich dafür gekennzeichnete Self-hosted Runner:

| Workflow | Erforderliche Labels |
|---|---|
| Docker Runtime Smoke | `self-hosted`, `SQL_Lab`, `Docker` |
| Podman Runtime Smoke | `self-hosted`, `SQL_Lab`, `Podman` |
| Mixed Provider Runtime Smoke | `self-hosted`, `SQL_Lab`, `Docker`, `Podman` |
| Hyper-V Lifecycle Smoke | `self-hosted`, `SQL_Lab`, `Hyper-V` |

Die Workflows werden bewusst nicht auf einem generischen `self-hosted`-Runner ausgeführt. Der mutierende Teil jedes Docker-, Podman- und Mixed-Provider-Smoke-Tests hält einen gemeinsamen hostweiten Mutex. Dadurch können auf demselben Runner keine zwei Runtime-Lifecycle-Tests gleichzeitig Ressourcen erzeugen oder entfernen, ohne dass GitHub wartende Workflow-Läufe verwerfen muss. Die Parallelität wird innerhalb des jeweiligen Smoke-Tests kontrolliert erzeugt.

Remote-Läufe befinden sich unter:

```text
.github/workflows/static-contracts.yml
.github/workflows/nightly-regression.yml
.github/workflows/adapter-smoke-github-hosted.yml
.github/workflows/runtime-smoke-docker-github-hosted.yml
.github/workflows/runtime-smoke-docker.yml
.github/workflows/runtime-smoke-podman.yml
.github/workflows/runtime-smoke-mixed-providers.yml
.github/workflows/runtime-smoke-hyperv.yml
```

Die Runtime-Workflows sind wiederverwendbar und enthalten keine Kopie der
statischen Vollregression. Der stabile Pflichtcheck für Branch Protection heißt
`PR Gate`; veraltete PR-Läufe werden automatisch abgebrochen.

## Voraussetzungen

- PowerShell 7.2 oder neuer;
- laufendes Docker; Podman muss installiert sein, eine vorhandene gestoppte
  Podman-Machine wird automatisch gestartet;
- `sqlcmd`;
- genügend RAM, Storage und freie Ports im Bereich 14330 bis 14399;
- Zugriff auf die konfigurierten SQL-Server-Container-Images;
- für den Hyper-V-Lifecycle-Smoke einen freigegebenen Windows-Host mit Hyper-V;
  der Test registriert nur eine synthetische Parent-VHDX, erzeugt ein Child und
  keine OS-/SQL-VM;
- für Podman unter Windows eine funktionierende Localhost-Weiterleitung, siehe `Documentation/HowTo/PODMAN_WINDOWS_NETWORKING.md`.

## Fehlerdiagnose

Fehlgeschlagene Labs für eine lokale Diagnose behalten:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider docker `
    -KeepOnFailure
```

Danach:

```powershell
Get-SqlServerLab -Detailed

docker ps -a --filter 'label=sql-server-lab.run-id'
# oder
podman ps -a --filter 'label=sql-server-lab.run-id'
# oder fuer den isolierten Hyper-V-Lifecycle
Get-VM | Where-Object Notes -Like 'SQL_SERVER_LAB:*'
```

Die Remote-Workflows verwenden `KeepOnFailure` nicht. Sie versuchen den normalen testseitigen Cleanup und beenden den Job bei einem Fehler mit Exitcode `1`.

### Native Hyper-V-Netzwerk-Reconnect-Abnahme

`Integration/Invoke-HyperVNetworkReconnectAcceptance.ps1` wird in einer erhoehten
PowerShell-7-Sitzung ausgefuehrt. `CloneSourceRunId` bezeichnet einen ausdruecklich
ausgewaehlten, gestoppten eigenen Windows-2025-Slot ohne SQL-Plan und Checkpoints;
`MediaRoot` enthaelt bereits hashregistrierte SQL-2025-Medien.

```powershell
.\Tests\Integration\Invoke-HyperVNetworkReconnectAcceptance.ps1 `
    -CloneSourceRunId $approvedSourceRunId -MediaRoot $approvedMediaRoot `
    -MediaEdition Enterprise -TimeoutSeconds 5400
```

Der Runner kopiert die Quelle unabhaengig, verwendet `VerifyOnly` ohne Egress
und ausschliesslich vorhandene `hostOnly`-Infrastruktur. Der eigene SQL-Run wird
vor und nach Disconnect/Plan/WhatIf/Apply/No-op mit einem synthetischen SQL-Marker
geprueft. Es werden keine externen Switches, Host-IP-Adressen oder NAT angelegt.
Der Parent haelt `Global\SQL_Server_Lab_Runtime_Smoke`. Nach Timeout wird der
Kindprozessbaum beendet; erst nach bestaetigter Terminierung darf der Parent
die eigene Operation bereinigen. Quelle und fremde Ressourcen sind niemals
Cleanupziele. Bei unbestaetigter Terminierung bleibt der lokale Operationshinweis
fuer Recovery erhalten; ein solcher Lauf ist kein PASS.

Die Offline-Suite `Static/Invoke-HyperVNetworkReconnectAcceptanceChecks.ps1`
prueft Identitaetswechsel, Fehlerkompensation, bestehende Infrastruktur und die
Supervisor-/Cleanup-Grenzen ohne Providerressourcen. Die lokale native Abnahme
bestand am 2026-09-19 fuer einen neuen Windows-2025-/SQL-2025-Clone mit SQL-Marker
vor und nach dem Reconnect, Plan, `WhatIf`, Apply, No-op und vollstaendigem
operationseigenem Cleanup. Sie ist auf einen vorhandenen `hostOnly`-Adapter
begrenzt und ersetzt keinen Nachweis fuer External-Switches, Host-IP/NAT,
Adapter-Neuanlage, Gastadressreparatur oder Fault/Resume.

`Static/Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1` prüft den
neuen Ein-Datenbank-Executor offline: eigene Runtime-/Volume-/Endpunktbindung,
Request-/Lockkollision, Größenlimit, Journal-/Antwortverlust, Cleanupresiduen und
Resume ohne Restorewiederholung. Der CI-Selektor entdeckt diese Suite separat.
`Integration/Invoke-PortableContainerTransferAcceptance.ps1 -Provider docker`
beziehungsweise `-Provider podman` erstellt ausschließlich eigene SQL-2025-
Linux-Runs und prüft Backup/Restore/MATCH, unveränderte read-only Quelle,
Idempotenz sowie abweichenden Inhalt mit vollständigem Whole-Run-Cleanup.

## Persistentes Retrieval

`Tests/Static/Invoke-AiPersistentRetrievalMigrationChecks.ps1` prüft das
v1→v2-Upgrade und den expliziten Modellwechsel der festen Delta-Fixture sowie
eines vollständig gebundenen Caller-Bestands in die nächste Nomic-Generation.
Die separate Abnahme `Tests/Integration/Invoke-AiPersistentRetrievalMigrationAcceptance.ps1`
mit `-Provider docker` beziehungsweise `-Provider podman` verwendet je einen
eigenen SQLrun, vorhandene Hostmodelle, gezählte Faultpoints, beide festen
Rankings, eine Caller-Collection vor/nach SQLrestart sowie eigenes vollständiges
Cleanup. Die erweiterten Docker- und Podman-Nachweise bestanden am 2026-09-22
getrennt mit je 25 Assertions und vollständigem Cleanup. Details im
[Migrationsvertrag](../Documentation/Architecture/AI_PERSISTENT_MODEL_MIGRATION.md).

`Tests/Static/Invoke-AiPersistentRetrievalChecks.ps1` prüft den eigenen SQL-
Generationsvertrag offline, einschließlich der exakten 768-/1024-dimensionalen
SQL-Bindung für EmbeddingGemma und BGE-M3. Der geführte Podman-
Erstellungsnachweis kann beide öffentlichen Auswahlen prüfen:

```powershell
.\Tests\Integration\Invoke-AiPodmanSetupAcceptance.ps1
.\Tests\Integration\Invoke-AiPodmanSetupAcceptance.ps1 -EmbeddingModelKey ollama-bge-m3-latest
```

Der BGE-M3-Lauf bestand am 2026-09-22 mit sechs Assertions, Query vor und nach
SQLrestart, unverändertem Hostmodellinventar und `CLEANUP=COMPLETED`.

Die allgemeine persistente Abnahme verwendet standardmäßig EmbeddingGemma und
getrennte eigene SQL-Runs:

```powershell
.\Tests\Integration\Invoke-AiPersistentRetrievalAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiPersistentRetrievalAcceptance.ps1 -Provider podman
```

Sie umfasst exakte Vektor- und hybride SQL-Termabdeckungs-/Vektorsuche, 1–16
Caller-Dokumente mit freier Frage, atomarem Sync und Hashdrift-Abweisung, SQLrestart,
konkurrierenden SQL-AppLock, Staging-/Commitantwortverlust, Resume und eigenes
DB-/Run-Cleanup. Kein Download oder Cloudaufruf. Docker und Podman bestanden am
2026-09-22 getrennt mit jeweils 26 Assertions einschließlich Caller-Update,
Insert, Delete, Vektorübernahme und vollständigem Cleanup;
[Vertrag](../Documentation/Architecture/AI_PERSISTENT_RETRIEVAL.md).

## SQL-Gast-Evidence-Capture

- `Static/Invoke-SqlGuestEvaluationCaptureChecks.ps1`: Offlinevertrag für Editionscapture, Bindung, Dateisperre, atomaren Receipt und Fehlererhaltung.
- `Integration/Invoke-SqlGuestEvaluationCaptureAcceptance.ps1 -ArtifactId <prepared-id>`: eigener Developer-Run auf erhöhtem Hyper-V-Runner, echter Capture/Watch, Evidence-Kette und Cleanup. Verwendet ein vorhandenes SQL_PREPARED_SEALED-Artifact; kein neuer Image-Build und kein positiver Deadline-Nachweis.

## Behaltenen Instanzstore endgültig löschen

Offline: `Invoke-RetainedStoreRemovalChecks.ps1`,
`Invoke-RetainedStoreRuntimeChecks.ps1` und
`Invoke-RetainedStoreRemovalConcurrencyChecks.ps1` unter `Tests/Static`.
Die Suites verwenden ausschließlich synthetische Fixtures und begrenzte Prozesse.

Native Abnahme (für diesen Stand noch nicht ausgeführt):

```powershell
./Tests/Integration/Invoke-RetainedStoreRemovalAcceptance.ps1 -Provider docker
./Tests/Integration/Invoke-RetainedStoreRemovalAcceptance.ps1 -Provider podman
```

Jeder Lauf erstellt seinen eigenen isolierten SQL-2025-Run. Der Supervisor hält
den Runtime-Testmutex, begrenzt Arbeit und Cleanup getrennt und persistiert die
Operation vor New. Private Rohlogs, Run-State und Katalog bleiben lokal zur Prüfung
erhalten. Nur geschlossene Statuswerte verlassen den Supervisor. Der Harness
übernimmt oder löscht keinen vorhandenen Benutzerstore. Details zur Produktgrenze
stehen in [der Benutzeranleitung](../Documentation/User/RETAINED_STORE_REMOVAL.md).

Für den Windows-llama.cpp-Pfad sind
`Static/Invoke-LlamaCppOwnedRuntimeChecks.ps1`,
`Integration/Invoke-LlamaCppOwnershipAcceptance.ps1` und die optionale
Docker-/CUDA-Abnahme `Integration/Invoke-LlamaCppSqlAcceptance.ps1` getrennt.
[Vertrag](../Documentation/Architecture/LLAMA_CPP_OWNED_RUNTIME.md).

## External Languages auf cgroup v2

`Integration/Invoke-ExternalRuntimeCgroupV2Acceptance.ps1 -Provider docker|podman
-EvidenceRoot <neuer-lokaler-Ordner>` prüft den expliziten SQL-2025-CU9-Modus
über öffentliche Manifest-Erstellung und Restart. Beide Provider benötigen
einen eigenen Lauf. Die Prüfung belegt SQL-Sprachroundtrips, Workeridentität,
reine v2-Mounts, No-op-Reconcile und Own-Cleanup. Sie stellt keinen Host um.
`-InstallViaReconcile` prueft getrennt die Nachinstallation in ein Basislab,
einschließlich Datenbankerhalt beim Containerwechsel und nach Restart.
`-Language Java` prüft den separaten finalen Java-Image-Stage.
[Auswahl und Isolationsgrenzen](../Documentation/User/EXTERNAL_LANGUAGES_CGROUP_V2.md).
