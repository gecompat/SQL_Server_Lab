# Lokale Validierungsstrategie

## GUI-Aktionsstatus ohne Runtime

`WorkflowJobStatusChecks.ps1` führt den tatsächlichen Statusreader und die
extrahierten `/api/actions`, `/api/jobs` und `/api/operations`-Routebodies mit
synthetischen Batchdateien sowie Enqueue-/Hoststart-Leaves aus. Kindstatus,
Terminalbeibehaltung, fehlende/defekte Quellen, feste Privacy-Projektion,
bytegleicher Poll und der gebundene Root nach Default-Wechsel werden geprüft.
`WorkflowJobStatusChecks.cjs` führt die tatsächlichen app.js-Funktionen mit
synthetischem Transport aus: Annahme statt Running, Wartend/Blockiert,
Verbindungsverlust/Timeout, späte Antwort, Terminalkarten, Doppelclick,
unbestätigter POST, PublicCommand-Dedupe und Logcache. Beide Fixtures sind vor
dem Ergebnisabschluss in `Invoke-WorkflowUiChecks.ps1` integriert. Keine reale
GUI-Aktion, Statusaufnahme, Listener-, Provider- oder OperationHost-Ausführung.

## Container-Autostart nur vorprüfen

`Get-SqlServerLabReconcilePlan -ContainerAutoStartPreview -RunId $runId -InstanceId primary -AutoStart on -StateRoot $stateRoot` ist eine getrennte PLAN_ONLY-Vorschau der Container-Restartpolicy für moderne registrierte laufende SQL-Instanzen unter Docker/Podman. Explizite skalare on/off-Labels und Restartpolicy müssen übereinstimmen; fehlende, untypisierte oder widersprüchliche Evidence bleibt UNKNOWN/DRIFTED und gesperrt. Nur die begrenzte SQL-Loopbacktopologie und darstellbare Mounts werden akzeptiert. Der DTO zeigt feste ON/OFF- und SAME_POLICY/DIFFERENT_POLICY-Kategorien sowie Mountcounts ohne Hostwerte, native IDs oder Pfade. CanApply=false, MutationAllowed=false und leere Actions gelten auch für No-op; der opaque ObservationKey ist reine Inhaltsbindung, keine CAS-/Reservierungs-/Executorautorität. Endpoint, SQL, Backup und Hostlogin bleiben NOT_CHECKED. Ein Kontextread nutzt die bestehenden Ownership-Revalidierungen; zusätzliche eigene Inspectreads bleiben erhalten. Der geführte CLI-Einstieg „Lab-Umgebungen → Container-Autostart vorprüfen“ wählt registrierte Lab-/Instanzmetadaten und liest den bestehenden öffentlichen Core nach einem vollständigen on/off-Wunsch genau einmal. Abbruch und ungültige Eingaben vor dem Aufruf lesen kein Inspect; feste Kategorien, Mountcounts und NOT_CHECKED-Grenzen werden erst nach strikter skalarer DTO-Prüfung angezeigt. Der separate Browserdialog „Lab verwalten → Container-Autostart vorprüfen · PLAN_ONLY“ liest beim Öffnen nur registrierte Zielmetadaten des serverseitigen Roots. Ziel-/on/off-Wechsel lösen keinen Read aus; erst bewusste Vorschau ruft denselben öffentlichen Core einmal auf. Strikte Request-/DTO-Projektionen erlauben keine clientseitigen Roots, nativen IDs oder Applyautorität. UNKNOWN/DRIFTED, Mountcounts und NOT_CHECKED-Grenzen bleiben sichtbar; Schließen, Bearbeitung und neue Requests verwerfen späte Antworten, während ein bereits versandter Read fertiglaufen darf. Die spezifische native CLI-Abnahme vom 2026-10-05 auf Head `960b5452` bestand unter Docker und Podman mit je drei tatsächlichen Menü-/Dualrouter-/Public-Vorschauaufrufen (on/off/on), null frühen Cancel-/Invalid-Aufrufen, unveränderten eigenen Statebytes und je neun getrennten Ownership-/Inspectreads. Zwei bytegebundene terminale Cleanuprecords bestätigten pro Provider die Entfernung der eigenen Ressourcen und Roots; der gemeinsame Schutzvergleich hatte null Findings und null Observations. Gerenderter Browser und HTTP-Netztransport bleiben NOT_EXECUTED; der generische CLI-/Webkatalog verwendet unverändert den öffentlichen Parametervertrag. Die spezifische native Core-Abnahme vom 2026-10-05 auf Head `77fbaee` bestand unter Docker und Podman mit je fünf öffentlichen Vorschauaufrufen, unveränderten eigenen Statebytes, zwei bytegebundenen terminalen Cleanuprecords und entfernten eigenen Ressourcen/Roots. Der gemeinsame Schutzvergleich bestand mit null Findings und null Observations. Der historische Corelauf allein nahm keine CLI-/Browserdialoge oder HTTP-Netztransport ab; CPU/RAM, Portvorschau, Apply/Recovery und der vollständige Scope A bleiben unverändert bzw. separat offen.


## Getrennte AutoStart-Browservorschau

Der additive Testmodus `Invoke-ContainerAutoStartPreviewAcceptance.ps1 -BrowserOnly`
ist gegenseitig exklusiv zu `-ConsoleOnly`. Er verlangt eine private, hash- und
bytegebundene `BrowserRuntimeMetadataPath` mit vorhandenem Node, Playwright-Paket,
Browserexecutable und einem eigenen Loopbackport; Port 14336 ist ausgeschlossen.
Installation, URLACL-/UAC-Fallback, Providerstarts und globale Defaultsänderungen
sind nicht erlaubt. Der eigene NoProfile-UIprozess setzt DataRoot und StateRoot
ausschließlich im Prozessenvironment und validiert Policy, Runtimepin und
registriertes Ziel vor dem tatsächlichen Listenerstart. Fremde und unbeteiligte
Browserrequests werden vor Serverarbeit blockiert; echte statische Antworten und
AutoStart-Previewantworten werden unverändert weitergeleitet.

Die geplante native BrowserOnly-Abnahme verwendet drei öffentliche on/off/on-
Aufrufe über echten Loopback-HTTP-Transport und den gerenderten Dialog. Früher
Cancel/Invalid liest keinen Public-Core; ein bereits versandter Read darf nach
Schließen fertiglaufen und wird nur bei der Anzeige verworfen. Eigene
Ownership-/Inspectreads werden getrennt gezählt. Statebytes werden nach dem
Serverstart sowie je HTTP-Aufruf und am Abschluss gebunden: Startup wird separat
gemessen, unerwartete Startupschreibvorgänge blockieren diesen Harness ebenfalls.
Eigene Prozesshandles/Startzeiten, begrenzte Ausgaben, Wiederherstellung und die
bestehende receiptgebundene Scope-/Cleanup-/Terminalcopy-Autorität bleiben strikt.
Die bisherigen Core-/Console-Modi werden nicht wiederholt oder ersetzt.

Die neue WorkflowUI-Fixture führt die tatsächliche Beobachterinstallation,
HTTP/Public/Core mit synthetischem Inspect sowie den tatsächlichen Dialog und
Driver mit synthetischem Playwright/Transport aus. Sie prüft Exklusivschreiben,
Bytecaps, Prozesscustody, Rootenvironment, Cancel, echte Responseweitergabe,
Blocked-/Evidence-Veto und Functionrestoration. Das ist ausschließlich Offline-
Evidence: der neue BrowserOnly-Modus, gerenderter nativer Browser und echter
HTTP-Netztransport bleiben `NOT_EXECUTED`; Hostlogin, Preview-SQL/Endpoint,
Apply/Recovery und Scope A bleiben offen. Native Freigabe verlangt den aktuellen
geprüften Head, frische eigene Scope-/Runtimepins, globalen Mutationsmutex und
genau einen gebundenen Vorher-/Nachher-Schutzvergleich.

`ContainerAutoStartPreviewHttpChecks.ps1` und `ContainerAutoStartPreviewUiChecks.cjs`
laufen vor der Ergebnis-/Exit-Sektion der bestehenden WorkflowUI-Suite.
Die HTTP-Fixture führt den tatsächlichen Serverbranch, gehaltenen Modulpfad,
registrierte Metadatenreader und öffentlichen AutoStart-Core mit synthetischem
Inspect-Leaf unter Docker/Podman aus. Transport, exakte Methode/Origin,
2048-Byte-/UTF-8-Grenze, doppelte und unbekannte JSON-Felder sowie skalare
Action/on/off müssen vor Metadaten-/Core-Arbeit stimmen. Auswahl bindet den
aktuellen serverseitigen Root neu; geschützte/CMS-, Legacy-, fremde oder
gestoppte Ziele liefern keine Preview. Projektion verwirft Zusatzfelder,
Arraykategorien und unerwartete Authority vor Serialisierung. UNKNOWN/DRIFTED
bleiben blockiert, No-op bleibt ohne Apply. Die echte JavaScript-Fixture mit
synthetischem DOM/Transport prüft Öffnen, Bearbeitung, Cancel/Escape, Busy,
Zielwechsel, Metadatenrebind und späte Fetch-/JSON-Antworten. Ausgabe verwendet
textContent; Statebytes und verbotene Effekte bleiben unverändert.
Diese Offline-Evidence ist kein nativer CLI-/Browserdialog-, gerenderter
Browser- oder HTTP-Netztransportnachweis. Core77 bleibt historisch getrennt;
Hostlogin, Preview-SQL/Endpoint, Apply/Recovery und Scope A bleiben offen.
Aktuelle Impactselektion und erforderlicher stabiler Abschluss folgen separat.

## Getrennte Browser-Portvorschau

`ContainerPortPreviewHttpChecks.ps1` und `ContainerPortPreviewUiChecks.cjs`
laufen in der bestehenden `Invoke-WorkflowUiChecks.ps1`. Der tatsächliche
dedizierte Serverbranch und gehaltene Modulpfad rufen öffentliche API,
Diagnostic-Bindung und Containercontext mit synthetischem Inspect auf.
Methoden-/Origin-/UTF-8-/Bytegrenzen, doppelte und unbekannte Parameter,
freie Root-/native ID-/Authorityfelder, ungültige Ports sowie geschützte,
CMS-, gestoppte und Legacy-Ziele müssen vor jedem Coreaufruf blockieren.
Der echte JavaScript-Dialog prüft DTO- und Kategoriegrenzen, Mountcounts,
Cancel/Escape, Eingabe-/Zielwechsel, Busy und superseding Requests mit
Late-Response-Veto und `textContent`. Metadatenauswahl liest kein Inspect;
eine gültige Vorschau liest genau eins und erlaubt kein Apply. Eigene
synthetische Statebytes bleiben unverändert, verbotene Effekte sind null.
Die HTTP-Grenze verlangt echte Stringskalare für alle Vertrags- und
Kategoriefelder; auch Ein-Element-Arrays mit erlaubtem Text werden vor
Serialisierung verworfen. Auch Action-Arrays müssen vor Metadatenarbeit
blockieren. Die HTTP-Fixture prüft diese Grenzen für Docker und Podman
ohne Providerwirkung.
Diese Offlineprüfungen ersetzen keine native Preview-/Dialogabnahme und
schließen weder Port-Apply/Recovery noch Scope A insgesamt ab. Aktuelle
Impactselektion und einmaliger stabiler Abschluss bleiben erforderlich.

## Getrennte AutoStart-Core-Abnahme

Die getrennte AutoStart-Core-Abnahme liegt in
`Tests/Integration/Invoke-ContainerAutoStartPreviewAcceptance.ps1` und verwendet
die bestehenden OwnScope-/Custody-/Cleanup-Primitiven des Port-Harness.
Der frische externe Parent behält deren geforderten
`sql-lab-port-preview-<GUID-N>`-Namen. New fordert ausdrücklich `AutoStart off`;
die Vorschau muss trotzdem die tatsächliche OFF-Policy messen. Je Provider
wurden am 2026-10-05 auf Head `77fbaee` fünf öffentliche Aufrufe ausgeführt: off, on, on, ON, OFF. No-op,
Wunschänderung, Wiederholung und Normalisierung müssen Kategorien sowie
Inhaltsbindungen konsistent halten und eigene Statebytes unverändert lassen.
Feste validierte Status-/Reason-/Count-Projektionen werden vor einem Veto im
privaten EvidenceRoot exklusiv gespeichert; keine Keys, Ports, IDs oder
RawInspectdaten gelangen in diese Projektion. Der Harness erwirbt selbst den
globalen Mutex und startet keine Runtime. Scope und Ressourcen-Custody werden
vor Cleanup erneut geprüft; die zwei terminalen Records bleiben bytegebunden
außerhalb des gelöschten Runtimeparents erhalten. Fehler erhalten Custody.
Die tatsächliche öffentliche D/P-Orchestrierung wird offline über einen
synthetischen Inspect-Leaf in der bestehenden ContainerReconcile-Suite geprüft,
einschließlich Kategorie-/Authority-, Überschreib-, Reparse-, RuntimeRoot- und
Statebyte-Vetos. Beide tatsächlichen Providerläufe bestanden mit je fünf validierten Kategoriebelegen, unveränderten Statebytes und ohne zusätzliche diagnostische Reads. Cleanup bestätigte je zwei terminale Records, Ressourcenabwesenheit und Rootentfernung; der gemeinsame Vor-/Nachschutz bestand mit null Findings/Observations und unveränderten acht Providerinventaren, VM-Inventar, sechs geschützten Umgebungen, Defaults, Autostart, Registry und eigenen Aufgaben. Die nichtatomaren Snapshots begründen keine kausale Entlastung oder allgemeine Hostinvarianz.
Diese begrenzte Core-Abnahme prüft weder Hostlogin noch Preview-SQL/Endpoint,
Apply, einen eigenen CLI-/Browserdialog oder HTTP-Netztransport.

## Getrennte AutoStart-CLI-Vorschau

Die Fixture `Tests/Static/Fixtures/ContainerAutoStartPreviewConsoleChecks.ps1`
läuft in der bestehenden ContainerReconcile-Suite und führt den tatsächlichen
Fachmenüeintrag, beide Router, Dialog und öffentlichen AutoStart-Core unter
Docker/Podman mit synthetischem Inspect-Leaf aus. Gebundene lokale Menüeinträge
behalten die Zielautorität; zurückgegebenes Menü-Data wird nicht übernommen.
Cancel, ungültige Eingabe, geschützte/CMS-, Legacy-, gestoppte und fremde
Ziele rufen keinen öffentlichen Plan auf. Ein vollständiger gültiger Wunsch
ruft genau einmal auf; zusätzliche Ownership-Inspectreads bleiben erhalten.
Malformed DTOs inklusive Ein-Element-Arrays, unerwarteter Authority, Actions
oder Kategorien blockieren vor Darstellung; Rohfehler bleiben privat.
Statebytes und verbotene Effekte werden geprüft. Diese synthetische Route
ist kein nativer CLI-Nachweis; die separate native CLI-Abnahme ist unten belegt.
Die bereits bestandene native Core-Abnahme auf `77fbaee` bleibt getrennt.
Native Browserdialogabnahme, HTTP-Netztransport, Hostlogin, Preview-SQL/Endpoint sowie
Apply/Recovery und vollständiger Scope A bleiben offen.

### Eigene native AutoStart-CLI-Abnahme (belegt)

`Invoke-ContainerAutoStartPreviewAcceptance.ps1 -ConsoleOnly` nutzt denselben
frischen eigenen registrierten Root/State-Child, immutable ParentOperation,
Runtimepins, reale globale Mutex-Aufnahme und gebundene Cleanup-Primitiven wie
die bestehende Core-Abnahme. Der gewöhnliche Modus und seine fünf Core-Aufrufe
bleiben unverändert; ConsoleOnly wiederholt diese Abnahme nicht.

Die neue Observation führt den echten Fachmenüeintrag und beide Router mit
on/off/on aus: genau drei öffentliche Vorschauaufrufe für changed/no-op/repeat.
Eingabe-/Ausgabeleaves sind deterministisch; der tatsächliche öffentliche Core,
Kontext und native Ownership-/Inspectreads bleiben erhalten. Cancel, ungültige
Eingabe und gefälschte Auswahl vor dem Aufruf erzeugen null Public-/NativeReads.
Transparente Zähler und sämtliche temporären Funktionen werden auch bei
Beobachtungs- oder Evidencefehlern wiederhergestellt. Feste validierte Kategorien
werden vor einem Statusveto exklusiv außerhalb des RuntimeRoots gebunden;
Rohwerte, native IDs, Pfade und ObservationKeys gehören nicht in diesen Payload.
Statebytes müssen unverändert bleiben. Own-Cleanup prüft die bestehenden Claims
und kopiert die tatsächlichen terminalen REMOVED-/COMPLETED-Records vor RootDelete;
Unreturned/Drift/fehlende Bestätigung erhält den Root für Recovery.

Die bestehende Acceptance-Fixture prüft diesen Modus separat mit `-ConsoleOnly`
über actual Module/Public/Core und synthetischem Inspect-Leaf. Die separate native
Docker-/Podman-CLI-Abnahme bestand am 2026-10-05 auf `960b5452`: je drei
tatsächliche Menü-/Dualrouter-/Public-Aufrufe mit on/off/on, null frühen
Cancel-/Invalid-Public- und NativeReads, unveränderten eigenen Statebytes und
je neun getrennten Ownership-/Inspectreads. Beide eigenen Runs wurden mit
zwei bytegebundenen terminalen REMOVED-/COMPLETED-Cleanuprecords vollständig
entfernt; Ressourcen und Roots waren abwesend. Der gemeinsame SAME-Root-
Schutzvergleich bestätigte alle sechs geschützten Umgebungen, neun Inventare
sowie eigene Defaults, Registry, Autostart und Aufgaben mit null Findings
und null Observations. Die fünf Core-Aufrufe auf `77fbaee` wurden nicht wiederholt.
Kein HTTP-Netztransport, gerenderter Browser, Hostlogin, Preview-SQL/Endpoint,
Apply/Recovery oder vollständiger Scope-A-Abschluss wird damit behauptet.

## Getrennte CLI-Portvorschau

`Fixtures/ContainerPortPreviewConsoleChecks.ps1` läuft in der bestehenden
`Invoke-ContainerReconcileChecks.ps1` in einem eigenen No-Profile-Prozess.
Sie führt den tatsächlichen Fachmenüeintrag, Menürouter, Dialog, öffentlichen
Portcore und registrierungsgebundenen Metadatenreader mit einem synthetischen
Inspect-Werkzeug aus. Docker und Podman werden getrennt simuliert; Cancel,
Portgrenzen, gefälschte Auswahl, geschützte/CMS-/gestoppte/unregistrierte
Ziele, No-op, unbekannte Topologie und malformed DTOs prüfen Effektgrenzen,
Byteerhalt sowie feste privacy-safe Ausgabe. Eine gültige Vorschau ruft den
öffentlichen Plan einmal auf und liest ein Inspect; keine Apply-, SQL-,
Secret-, Listener-, Reparatur- oder Bestätigungsgrenze darf erreicht werden.
Diese Offlineprüfungen sind keine native Preview-/Dialogabnahme. Die begrenzte
Docker-/Podman-Abnahme ist unten separat dokumentiert; eine spätere Applyform
bleibt offen. Tatsächliche Impactselektion und stabiler Abschluss werden lokal
gebunden. Unveränderte grüne Prüfungen werden nicht zusätzlich wiederholt.

## Reine Container-Portvorschau

`Fixtures/ContainerPortPreviewChecks.ps1` wird von der bestehenden
`Invoke-ContainerReconcileChecks.ps1` in einem eigenen No-Profile-Prozess
ausgeführt. Sie verwendet die tatsächliche öffentliche Funktion, den neuen
Core, den registrierungsgebundenen Diagnostic-Reader und den bestehenden
Containercontext mit einem synthetischen Inspect-Werkzeug. Gültige Docker-/
Podman-Fälle lesen genau ein Inspect; Topologie-, Identitäts-, Scope-,
Mount-, unbekannte Limit- und Journalfälle bleiben failclosed. Bytevergleiche
des eigenen synthetischen States und verbotene Effektspies prüfen NoWrite,
kein SQL-/Secret-/Listenerzugriff und keine Recovery. Privacycanaries prüfen
den host- und portwertfreien DTO; Wiederholung und Zieländerung prüfen die
Inhaltsbindung des nicht ausführbaren `ObservationKey`. Die generische
CLI-Katalogsuite prüft den neuen nativen Parametersatz und Portbereich.
Für optionale Netzwerkaliase werden `null`, leere Arrays sowie der gebundene
Containername und seine vollständige beziehungsweise kurze ID über den echten
öffentlichen Core geprüft. `null` ist kein zusätzlicher Alias; konkrete
unbekannte Werte einschließlich Leerstring, `false` und `0` bleiben gesperrt.
Die owned-host-Orchestrierungsfixture verwendet ebenfalls nullable Aliase und
prüft die tatsächlichen Core-/CLI-/HTTP-Pfade mit synthetischem Prozess-Leaf.
Diese synthetischen Prüfungen bestätigen weder native Inspectformen noch
Portverfügbarkeit, Reservierung, Apply, Datenerhalt oder native Recovery.
Die tatsächliche betroffene Selektion und ihr einmaliger stabiler Abschluss
werden separat lokal gebunden; ausgewählte Docker-/Podman-Gates bleiben bis
zu ihrer eigenen Ausführung `NOT_EXECUTED`.

## Gemeinsame Browserkomposition

`Invoke-ReviewedBrowserCompositionChecks.ps1` führt die fünf dedizierten Routen
für Evaluation-Ersatzentscheid, llama.cpp-Dateivorschau, bewussten llama.cpp-Start
und External-Languages-Entscheid sowie Collation-Katalogsuche zusammen im selben isolierten Modul aus.
Die tatsächlichen HTTP-/Public-/Readerpfade bleiben erhalten; nur Runtime- und
Transportleaves sind synthetisch. Eindeutige HTML-IDs und Scripts, 135 Exporte,
getrennte Fehlerantworten, Zero-Fallthrough und die gemeinsame CLI-Auswahl samt
Abbruch sind Pflichtfälle. WhatIf startet keinen Worker; synthetisches READY
belegt keine aktuelle Host-, SQL-, Provider- oder Besitzautorität.
Die bestehenden Einzelsuites prüfen weiterhin ihre vollständigen Verträge.
Ausgewählte Native-Gates bleiben separat und dürfen daraus kein PASS erhalten.

`Invoke-CollationCatalogBrowserChecks.ps1` führt die extrahierte dedizierte Route
über den echten HTTP-Helper, Public-Suchbefehl und Schema-/Katalogreader aus.
UTF-8-/JSON-/Origin-/Listenergrenzen, drei Versionen, ASCII-AND-Suche,
Zero-Token-/Nulltreffer, ungültige Kataloge, geschlossene Metadaten und ehrliche
Truncation werden synthetisch geprüft. Verbotene SQL-/Provider-/Stateleaves
sind instrumentiert. Die echte JS-Datei läuft mit Fake-DOM/Fetch: bewusste Suche,
Busy, Zurück/Escape, Edit-Revision, beide späten Antwortarten und `textContent`.
Eigene synthetische HTTP-Katalogfixtures bleiben lokal ignoriert erhalten;
dieser neue Test behauptet kein Cleanup. Kein manueller Browser- oder nativer
SQL-Nachweis; die bestehende separate Container-Evidence bleibt historisch.

## Reiner Evaluation-Ersatzentscheid

`Invoke-EvaluationRefreshPlanHttpChecks.ps1` führt den tatsächlichen HTTP-Reader,
öffentlichen D-Core und registrierten Diagnostic-/Gast-Reader sowie den echten
dedizierten Serverbranch auf synthetischen Metadaten aus. Request-/Origin-/Body-
und Auswahlgrenzen, Drift bei zweiter Coreobservation, Recovery, Datenschutz und
getrennte fehlende/veraltete/aktuelle Evidence sind Pflichtfälle.
`EvaluationRefreshPlanUiChecks.cjs` führt das echte RAM-Dialogskript mit DOM-/Fetch-
Leaves aus: drei Modi, Cancel/Escape, Busy, geänderte Auswahl, verworfene späte
Erfolge/Fehler und strikt nicht ausführbare feste Responses. Kein Job, SQL-/
Providerzugriff oder neuer Lizenznachweis; ausgewählte Providergates bleiben separat.

`Invoke-EvaluationRefreshPlanConsoleChecks.ps1` führt den tatsächlichen geführten
CLI-Handler durch den öffentlichen Plan und seine Diagnostic-/Gast-Reader aus.
Nur Text-, Menü- und Anzeigegrenzen sind isoliert. Alle drei Modi, Cancel vor
jedem Planaufruf, fremde/abweichende Bindung, Auswahl-/Inhaltsdrift, fehlende und
veraltete Evidence, Datenschutz und die 64-Verzeichnisgrenze sind Pflichtfälle.
Der gemeinsame Menüdispatch erhält den generischen Editor und Komponentenplan.
Diese synthetische Komposition ist keine Runtime-, Lizenz- oder SQL-Abnahme.

`Invoke-EvaluationRefreshPlanChecks.ps1` führt die tatsächlichen öffentlichen
Plan-/Watchfunktionen, DiagnosticReader, SQL-Gast-Reader und gemeinsame
Fristklassifikation mit registrierten synthetischen Root-/Run-/Scope-Records aus.
Runtime-, Hosttool-, SQL-, Secret-, Default- und Mutationsgrenzen werfen. Drei
blockierte Modi, fehlende/veraltete/abweichende Evidence, Controller-/Instanz-
und Contentdrift, NoWrite und feste DTOs sind notwendig. Watch-Inventargrenzen
liefern nur die synthetische Quelle. Die Prüfung beweist keine Lizenzprüfung,
SQL-Readiness, Providerfunktion oder Migration; Diff-Auswahl und CI bleiben
separate Verpflichtungen.

## Prospektiver External-Languages-Capability-Entscheid

`Invoke-ExternalRuntimeCapabilityBrowserChecks.ps1` prüft die extrahierte echte
HTTP-Route im bestehenden Modulkontext, den neuen strikten Helper und den
unveränderten Public-/Resolver-/Classifier-Pfad mit isolierten Transport-Spies.
ReadOptions und Evaluate ohne Hostcheck verlangen null native Transporte;
bewusster Hostcheck verlangt genau einen begrenzten Adapteraufruf.
UTF-8-/Körper-/Origin-/Listener-/Typgrenzen und geschlossene Antworten werden
negativ geprüft. Das tatsächliche JS-Modul läuft mit Fake-DOM und Fetch-Spies:
Abbruch, Escape, Busy, verworfene späte Antworten, blockierte Varianten und
Privacyfehler werden geprüft. Das sind synthetische Prüfungen, keine manuelle
Browser- oder native Provider-/SQL-Sprachabnahme.

`Invoke-ExternalRuntimeCapabilityChecks.ps1` durchläuft den tatsächlichen
Public-Aufruf, Katalogresolver, Reducer und bestehenden Manifestdialog.
Provider-Metadaten stammen aus dem Repository; native Prozessgrenzen werden
durch isolierte Spies ersetzt. Standard-Probes=0, bewusster Info-Aufruf,
StartInfo-/Argument-/Zeit-/Streamvertrag, typisierte Hostfakten, ungeeignete
cgroup-/Rootful-Kombinationen, feste Fehler, Rawdatenfreiheit, negative
Varianten, Zurück/Abbruch und bestehende Manifestfelder werden geprüft.
Es werden keine Provider, SQL-Instanzen oder Sprachruntimes gestartet oder
abgefragt. Native Nachweise bleiben getrennt und werden nach tatsächlichem
finalen Diff ausgewählt. [Vertrag](../Architecture/EXTERNAL_RUNTIME_CAPABILITY.md).

## Reine Komponenten-/Shared-Verbrauchervorschau

Der zugehörige Browser-Slice wird durch `ComponentRelationPlanHttpChecks.ps1`
mit dem tatsächlichen HTTP-Reader, DiagnosticReader und öffentlichen Core auf
registrierten synthetischen Metadaten geprüft. Body-/Origin-/Shapegrenzen,
Auswahl-/State-/Scope-Drift und blockierte Recovery sind getrennte Fälle.
`ComponentRelationPlanUiChecks.cjs` führt das echte Dialogskript mit DOM-/Fetch-
Leaves aus: bewusste Auswahl, ein Shared-Verbraucherziel, Abbruch, Busy,
verworfene späte Antworten und feste Fehlerdarstellung. Die bestehende
Komponenten-Suite führt beide Fixtures aus. Diese Offlinekomposition enthält
keine SQL-/Providerabnahme; die tatsächliche Providerselektion bleibt verbindlich.

`Invoke-ComponentRelationPlanChecks.ps1` führt den tatsächlichen öffentlichen
Plan-/Action-Parametersatz und den privaten Core mit modernen synthetischen
Run-/Desired-State-Produzenten und registrierten Root-/Scope-Records aus.
Notwendig sind NoWrite/Legacy-Noop, DAG/Self/Cycle/Duplicate, genaue eigene und
Shared-Identität, Input-/Provider-/Scope-/Contentdrift bei zweiter Observation,
unbekannte SQL-Bereitschaft und feste sichere DTOs. Der tatsächliche Action-/
Pipelinepfad muss Mode/Version vor jeder Observation verweigern. Runtime-,
Hosttool-, SQL- und Secret-Spies werfen bei jedem Aufruf. Diese Evidence ist
eine Planprüfung, kein Start-/Shared-Removal-/Providerbeleg.

Die gekoppelte `Fixtures/ComponentRelationPlanConsoleChecks.ps1` lädt tatsächliche
Funktionsdeklarationen ohne Modul-/Providerimport und führt den CLI-Menüpfad
über den öffentlichen Plan in den unveränderten Core aus. Registrierte Root-,
Run-, Scope-, Desired-State- und ProviderSubRun-Fixtures sind synthetisch.
Abbruch an jedem Dialogschritt, leere Relations, Shared-DAG, Cycle, Inhalts-/
Statewechsel, unregistrierter Root und Zielanzahl prüfen reine Vorschau und
ZeroDispatch. Menü-, Text- und Anzeigegrenzen sind isoliert; reale Secrets,
Hosttools, Runtime und Executor dürfen nicht aufgerufen werden. Diese Fixture
wird vom bestehenden ComponentRelationPlan-Impactpfad mit ausgeführt.
## Geführte Wartung und Zuordnungsreparatur

`Tests/Static/Invoke-MaintenanceGuidanceChecks.ps1` prüft den tatsächlichen
Plan-/Katalog-Executor, serverseitige DTO-/HTTP-Grenze, CLI-Cursorauswahl,
F5, Abbruch, No-op, Stale/Volume-Wiederanlage, unbekannte Referenzevidence,
Recovery/Schutz und den prozessübergreifenden Controller-Mutex synthetisch.
Änderungen von Schutzregistrierung, aktiver Referenz und Recovery werden
nach der letzten echten Observation injiziert und müssen den Commit verhindern;
ein konkurrierender echter Registrywriter muss an allen beteiligten Roots sperren.
`Invoke-CleanupAuditChecks.ps1` prüft die gesamte NoWrite-Auditkette bei
ungültigem Run-State ohne Warnjournal und mit bytegleichem State.
`Invoke-WorkflowUiChecks.ps1` führt die echten JS-Handler einschließlich
Bestätigung, Abbruch und verspäteter Antwort aus. Provider-Nachweise bleiben
getrennt; diese Fixtures sind keine native Retained-Removal-Abnahme.

Am 2026-09-29 bestanden Docker und Podman getrennt je 38 native Assertions
für den echten Guidancepfad: Vorschau, Cancel, geänderte Sourcebytes mit
Abweisung des alten Plans, Katalogrepair und frischer No-op. Je eine neue
eigene Volume mit synthetischem Sentinel wurde über kurzlebige Shell-Helfer
aus einem bereits lokalen SQL-2025-Image geprüft, ohne SQL-Start, Netzwerk,
Ports oder Hostmounts. Sentinel und Nichtkatalogdateien blieben bytegleich;
je 14 Cleanupprüfungen bestätigten die Abwesenheit der eigenen Ressourcen.
Ein vorheriger Harnessabbruch vor Ressourcenanlage und ein failclosed
Produktfehler vor Katalogcommit bleiben getrennte Fehlerevidence. Der dabei
erkannte volatile `FreeBytes`-Anteil wurde eng aus der Locationautorität
entfernt und unabhängig nachreviewt; sämtliche anderen Bindungen bleiben
erhalten. Die synthetische Suite prüft diesen stabilen Vorschauvertrag mit.
Diese Abnahme belegt ausschließlich die Zuordnungsreparatur und den
Datenerhalt der Fixture, keine SQL-Funktionalität oder Retained-Removal.

## Geführte Gruppen-Poweraktion

`Tests/Static/Invoke-TestGroupGuidanceChecks.ps1` führt echte Plan-, Apply-,
CLI-, Workflow- und Providerprimitive mit synthetischen Runtimegrenzen aus.
Es prüft No-op/Cancel, Live-Drift, Teilfehler, frische Wiederholung ohne erneute
Aktion auf erfüllte Mitglieder, Registry-/Instanzbindung, unbekannte Recovery,
Hyper-V-VM-ID-Abwehr und konkurrierende echte Registry-/Lifecycle-Aufrufer
über kanonische Root-Aliase. Die Browserfixture führt echte DOM-Handler und
den Hintergrundaktionspfad aus; SQL-Bereitschaft wird nie abgeleitet.

Der bestehende `Tests/Integration/Invoke-TestEnvironmentGroupLifecycle.ps1`
zielt standardmäßig auf die registrierte gemeinsame Gruppe und stellt sie
abschließend bereit. Er ist **kein** isolierter Nachweis für diesen Slice und
darf für dessen Abnahme nicht gegen reservierte Gruppen ausgeführt werden.
Ein mutierender Guidance-Nachweis benötigt nach Review ausdrücklich neue
synthetische eigene Gruppen, frische Readiness, Providertrennung, Mutex,
Timeout und bestätigtes Own-Cleanup.


Am 2026-09-29 bestanden Docker, Podman und Hyper-V getrennt jeweils zehn
Prüfungen über den tatsächlichen Workflowadapter: gebundene Vorschau,
Abbruch, Start/Stop, No-op, Ablehnung einer veralteten Vorschau nach eigener
Poweränderung und bytegleiche State-/Registry-/Exportdateien. Je Provider
wurden genau zwei neue eigene Ressourcen benutzt und ihre native Abwesenheit
anschließend bestätigt. Container nutzten eine bereits lokale SQL-2025-Image-ID
mit reinem Shell-Warteprozess, ohne SQLstart, Ports, Volumes oder Netzanschluss;
Hyper-V nutzte disk-/netzlose Generation-2-VMs mit 512 MB. Dies belegt nur
Power und Identitätsbindung, keine SQL- oder Gastbereitschaft. Der erste
Hyper-V-Versuch scheiterte vor VM-Anlage an der privaten Fixture-ACL; nach
bestätigter Abwesenheit und Korrektur ausschließlich des eigenen VM-Ordners
bestand der neue Versuch. Teilfehler/Retry und Cursor-/Fallback-/F5-Verhalten
sind synthetisch geprüft; unabhängiger Nachreview ist geschlossen.

## Read-only Container-Mount-Vorschau

`Invoke-ContainerReconcileChecks.ps1` führt den öffentlichen Containerplan mit
synthetischen Inspect-Metadaten aus. Explizit leere und fehlende Mountlisten,
schreibbare und lesende Host-Bindings, Volumes und andere Typen, falsche RW-
Typen, fehlende Felder, skalare Einträge und die 1024-Grenze sind getrennte
Fälle. Feste Zähler geben keine Namen oder Host-/Gastpfade aus und bestätigen
kein Volumeeigentum. Recreate darf keine allgemeine Mount-Erhaltung behaupten;
Live-Pläne ändern Mounts nicht. Bestehende NoWrite-, Action- und Journalfälle
bleiben erhalten. Diese synthetische Evidence ersetzt weder native Inspect-
Kompatibilität noch Docker-/Podman- oder Volume-/Mount-Cleanupnachweise.
Die isolierte `Fixtures/ContainerRecreateMountChecks.ps1` führt zusätzlich den
tatsächlichen Executor und Planner mit synthetischem Kontext bis zur ersten
neuen Journalgrenze aus. Ein Journal-Sentinel verhindert Provider-Mutationen.
Die fokussierte Ausführung am 2026-10-04 bestand 239 Checks: Docker-/Podman-argv
für Bind-Mounts und benannte Volumes einschließlich Schreibrechten und Podman-U,
eindeutige Unix-, Windows-Laufwerk- und UNC-Quellpfade, frühe Ablehnung
ungültiger oder nicht unterstützter Mountdaten, explizit leere
Listen, No-op, Live-Update, `-WhatIf` und frische Metadaten nach vorheriger
Recovery. Das ist ein lokaler Grenznachweis, kein nativer Recreate-, Recovery-
oder Datenerhaltungsnachweis.
Der vorhandene eigene `Invoke-ContainerCliAcceptance.ps1` vergleicht zusätzlich
die öffentlichen Zähler mit seinem bereits gelesenen nativen Inspect; Docker
und Podman benötigen jeweils eine eigene Ausführung auf dem finalen Stand.

## Geführte Container-CPU/RAM-Änderung

Die additive Mountanzeige wurde am 2026-10-04 lokal mit dem echten gemeinsamen
Planner und der echten Browserfixture geprüft: fehlende Daten, gemessene 0,
ungültige Metadaten, pfadfreie Anzahlen, ungeprüftes Volumeeigentum,
Hyper-V ohne Mountvorschau und Verwerfen bei Eingabeänderung. Die Plannerfixture
besteht mit 43 Fällen, die Ressourcen-Suite mit sechs zusätzlichen Prüfungen;
die UI-Suite besteht mit 53 Prüfungen einschließlich 147 Browserprüfungen.
Der synthetische Providerkontext wird pro Plan nur einmal gelesen; die additive
Projektion verändert bei unveränderter privater Bindung den PlanKey nicht.
Die CI-Selektion ordnet die Plannerdatei, Ressourcen-Suite und Guidancefixture
explizit der Ressourcen-, Container-Reconcile- und UI-Prüfung sowie beiden
Containerprovidern zu. Exakte Pfade mit beiden Trennzeichen und ähnliche
Nicht-Domainpfade bestehen die Selektorfixture (457 Prüfungen). Die Änderung
am gemeinsamen Selektor selbst behält dessen volle Runtime-Pflichtmatrix.
Diese lokalen Nachweise ersetzen keine native Docker-/Podman-Abnahme des
veröffentlichten Heads und belegen keine neue Mountmutation oder Volumeverwaltung.

Die anschließende PowerShell-Menüanzeige bestand lokal 49 Guidancefälle und
sechs Ressourcenprüfungen am 2026-10-04. Die echte CLI-Funktion zeigt unbekannte,
gemessene leere und pfadfreie gemischte Mountdaten beim Ist- und Zielplan.
Pro Plan bleibt es bei einem synthetischen Kontextread; Eingabeabbruch,
abgelehnte Bestätigung und No-op rufen keinen Executor auf. Hyper-V zeigt
die fehlende Container-Mountverfügbarkeit und führt keinen Apply aus.
Diese fokussierten Offlineprüfungen sind keine native Providerabnahme.


Am 2026-09-28 bestanden Docker und Podman getrennt je neun native Prüfungen
für den neuen instanzgebundenen Plan-/Workflow-Apply-/No-op-/Driftpfad auf
SQL Server 2025. Geprüft wurden echte CPU/RAM-Limits, erhaltene Runtime-ID,
Ports, Restartpolicy und Mounts, No-op ohne Journalwrite, Ablehnung einer
veralteten Vorschau nach eigener Änderung sowie SQL-Erreichbarkeit.
Jeder Lauf verwendete einen eigenen privaten State-/Datenroot, frische
Readiness/HostTools, den globalen Runtime-Mutex und begrenzte Worker-/Cleanup-
Laufzeit. Beide eigenen Runs wurden entfernt; eigene Container, Volumes und
Netze waren anschließend abwesend. Zwei vorangehende Docker-Harnessabbrüche
wurden getrennt gehalten und nach bestätigtem Cleanup nicht als PASS gezählt.
Die unabhängige Nachprüfung schloss Lifecycle-Bindung, Root-Alias-Mutex,
ID-gebundenen Apply/Rollback und den GUI-Ladefall. Offline bestanden die
betroffenen Suites; die Ressourcenfixture prüft 37 zusätzliche Fälle und die
echte Browserfixture insgesamt 44 Fälle. Hyper-V-Apply, weitere Eigenschaften
und andere SQL-Versionen sind durch diese Evidence nicht abgenommen.

## Grundkonfiguration und explizite Providerprüfung

Die isolierten InitialSetup-Prüfungen sichern Herkunft, ungültige Roots,
registrierte Defaultwechsel, revalidiertes Apply und die HTTP-Grenze. Die
CLI-Prüfung führt den echten Cursorrenderer mit synthetischen Tasten sowie den
nummerierten Fallback aus: Rootdetails und Providerbefunde bleiben bestätigt
lesbar, F5 liest erneut. Der Browsertest führt die echten Ereignishandler aus,
einschließlich Vorschau, Abbruch, ungültig gewordener Eingaben und verspäteter
Antworten. `Fixtures/InitialSetupWriteabilityChecks.ps1` führt zusätzlich den
echten Public-/Worker-Core auf einem eigenen temporären registrierten Windows-
Root aus: Vorschau ohne Datei, Bestätigung, WhatIf, Byte/Flush, separate
Abwesenheit, Replay, Kollision, Ablauf und Markerdrift. Der tatsächliche Worker
blockiert Directoryrename und Junctionaustausch nach Open vor dem Bytewrite.
Echte HTTP-Grenze und CLI-Cursor/Fallback prüfen Bestätigung und Abbruch; echte
JS-Handler prüfen Vorschau, Eingabeänderung, Cancel und resultatsichtbares Apply.
Nicht-Windows prüft die Plattformablehnung; die Windows-Dateisystemprobe bleibt
dort `NOT_EXECUTED`. Diese Schreibprobe bestätigt keine freie Kapazität oder
SQL-/Providereignung. `Fixtures/InitialSetupCapacityChecks.ps1` prüft den
separaten read-only Capacity-Core: echte native Werteform ohne Rohwerte,
synthetische Bindungsdrift vor/nach Lesen, nullable Fehler, echte isolierte
Worker mit Resultat-/Zeitgrenzen sowie tatsächliche HTTP- und CLI-Grenzen.
Die JS-Handler prüfen explizite Einzelauswahl und verwerfen verspätete Antworten.
Neue Kapazitätsfixtures schreiben keine Dateien; die bestehende isolierte
Schreibprobenregression bleibt ein eigener Nachweis. Kanonisch ausgewählte Runtime-Gates bleiben erforderlich;
frühere SQL-Smokes sind kein Nachweis für einen neuen Source-Digest.

Am 2026-09-28 bestand der getrennte Docker-SQL-2025-Core-Smoke 34 Prüfungen mit
eigenem temporärem State-/Datenroot, globaler Testsperre und lokalem Rohlog.
Die eigenen Runs wurden entfernt; eigene Container, Volumes und Netze waren
anschließend abwesend. Dauerhafte Benutzerdefaults blieben unverändert.
Das ist ein Core-Providernachweis, keine native Abnahme des Setupdialogs.

Abdeckungsgrenze des Pfadselektors: Reine Änderungen an der Navigation wählen
die gekoppelten DataRoot- und TestEnvironment-Suites nicht automatisch aus.
Ihre noch auf frühere Hauptmenüpositionen gerichteten Assertions wurden in
diesem Slice auf den tatsächlichen Bereichsweg aktualisiert und ausgeführt.
Der Selektor selbst bleibt unverändert; gekoppelte Vertragsprüfungen bleiben
auch außerhalb seiner automatischen Auswahl erforderlich.

## Private Docker-/Podman-CI-Diagnostik

Die selbst gehosteten Docker-/Podman-Gates schreiben Preflight- und Testausgaben nur in
lokale `*.private.log`-Dateien unter `RUNNER_TEMP`. Er lädt keine Rohlogs hoch;
öffentliche Fehler und Ergebnisse enthalten feste Meldungen ohne übernommene
Host- oder Ausnahmeinformationen. Die temporären Dateien unterliegen dem
Cleanup des Runners. Testumfang, Modi, Exitcodeprüfung und Runtime-Sperre bleiben
unverändert. `Invoke-DockerSmokePrivacyChecks.ps1` und
`Invoke-PodmanSmokePrivacyChecks.ps1` führen die Workflowblöcke mit
synthetischen PowerShell-Kindprozessen aus und prüft erfolgreiche sowie
fehlgeschlagene Schritte einschließlich privater stdout-/stderr-Ausgabe.
Diese Offline-Prüfung ersetzt den erforderlichen Docker-Providernachweis nicht.

Mixed-Preflight und -Smoke, Hyper-V-Preflight und der Standardmodus `lifecycle`
sowie Adapterinstallation, -Smoke und -Cleanup führen ihre Rohstreams ebenfalls
nur in lokalen privaten Logs. Der Mixed-Rohlogupload entfällt; veröffentlichte
Fehler und Ergebnisse sind fest vorgegeben. Die vorhandenen Testskripte und
Argumente bleiben erhalten; eine PowerShell-Prozessgrenze erfasst auch direkte
Konsolenausgaben. Der Adapter-Cleanup behält seinen bisherigen Best-Effort-Vertrag.
`Invoke-RuntimeSmokePrivacyChecks.ps1` führt die echten Workflowblöcke mit
synthetischen Prozess-/Kommando-Grenzen aus, einschließlich nativer stderr,
Exceptions und früher sowie später Bash-Fehler. Unter Windows verwendet die
Fixture ausschließlich Git Bash, nicht WSL. Diese Prüfung startet keine Provider.
Der PR-Dispatch übergibt keinen Hyper-V-Modus und verwendet damit `lifecycle`;
die expliziten `shared-environments`-Schritte werden nicht ausgewählt. Weitere
manuelle Hyper-V-Modi sind nicht durch diese Privacyhärtung abgedeckt.
CI-Selektion, Zeitgrenzen, Mutex und bestehende Cleanupaufrufe bleiben erhalten;
fehlende native Nachweise werden durch die Offline-Fixtures nicht ersetzt.

Der Hyper-V-Lifecycle-Smoke verwendet den kanonischen Pfad
`StateRoot/runs/RunId` und persistiert die vom Provider zurückgegebene VM-ID
in der Connectioninfo vor Start oder Stop. Lifecycle, Reconcile und Imagebuild
führen getrennte Erstellungs- und Cleanupnachweise. Eine begonnene Erstellung
ohne bestätigte Rückgabe, ein unbekanntes natives Inventar oder ein fehlender
Cleanupnachweis bewahrt das eigene Custody-Verzeichnis einschließlich Parent.
Artefakt- und Rootcleanup verlangen bestätigte Runtime-Abwesenheit; Pfade werden
vor der Entfernung erneut auf eigene Tempgrenzen und Reparsepunkte geprüft.
Nach der Publikation reicht die physische Builder-Abwesenheit nicht aus:
der eigene Build muss über `Remove-HyperVWindowsImageBuild` mit
`CLEANUP_SUCCEEDED` und `CLEANED_UP` abschließen, bevor die Registryreferenz
entfernt werden darf. Ein unbestätigter Abschluss bewahrt die Custody.
Diese Prüfungen sind keine atomare Dateisystem-/Runtime-Transaktion.

`Invoke-HyperVResourceBindingChecks.ps1` führt den tatsächlichen Finally-Block
mit injizierten Fehlern aus: unbestätigte Erstellung in allen drei Scopes,
Cleanup- und Inventarfehler, umbenannte VM, wiederverwendeter Name, ungültige
Native-ID, Artefaktfehler und echte eigene Junction-/Symlink-Fixtures. Die
ursprüngliche Ausnahme und Mutexfreigabe werden geprüft. Die Fixtures prüfen
auch die Reihenfolge Buildabschluss vor Artefaktentfernung
und verweigern das Cleanup bei fehlgeschlagenem oder nicht terminalem Build.
Diese statischen
Fixtures ersetzen keinen nativen Hyper-V-Smoke. Die Slotpool-Fixture stellt
ihre temporären Plattform- und Rootprüfungsbindungen vollständig wieder her;
unter Unix bleibt die echte portable Rootprüfung aktiv. SQL-Medienpfade werden
mit dem Separator der tatsächlichen Plattform begrenzt.
Die Poolclaim-Prozessfixture setzt `WindowStyle Hidden` nur unter Windows;
unter Unix bleibt derselbe Prozess-/Argument-/Ausgabevertrag ohne diesen
Windowsparameter erhalten. Synthetische Plattformfälle ersetzen keine native
Unix-Prozessprüfung.
## SQL Server 2025 External Languages auf cgroup v2

Die expliziten `shared-user-v2`-Varianten besitzen getrennte native
Produktnachweise für Docker Engine 29.8.0 und Podman Server 6.0.2 auf
rootful WSL2-/cgroup-v2-Hosts. Direkte Manifest-Erstellung und Erstinstallation
über Reconcile bestanden jeweils Python/R/Java-Roundtrips, Workeridentität,
SQL-CU9-Build, reine v2-Mounts, Restart und eigenes Cleanup. Reconcile prüfte
zusätzlich den Erhalt einer synthetischen Datenbank. Der separate finale
Java-Stage wurde ebenfalls je Provider durch Erstellung, SQL-Roundtrip,
Restart und Cleanup geprüft. Diese Läufe wurden am 2026-09-27 ausgeführt.

`Tests/Integration/Invoke-ExternalRuntimeCgroupV2Acceptance.ps1` ist der
reproduzierbare Einstieg, mit `-InstallViaReconcile` für die Nachinstallation.
`-Language Java` wählt die zusätzliche Abnahme des reinen Java-Images.
Er ersetzt weder allgemeine Provider-Smokes noch einen isolierten
Launchpad-/cgroup-v1-Nachweis. Gemeinsames Worker-Konto, fehlende Launchpad-
Sandbox-/Netzwerkisolation und die Grenzen für bereits persistierte
Software-Intents stehen in
[External Languages auf cgroup v2](../User/EXTERNAL_LANGUAGES_CGROUP_V2.md).

## Nativer Linux-/WSL-Einstieg

`Invoke-NativeLinuxContainerHostChecks.ps1` prüft Providerentscheidungen ohne
Runtimezugriff, einschließlich fehlender/unzugänglicher Provider, rootless,
fehlender cgroup-Evidence und deaktiviertem v1-Speichercontroller. Unter Windows
werden WSL-Kernelblockade und gestoppte Distribution über synthetische
Prozessantworten geprüft; unter Linux zusätzlich Pfadüberlappung, abweichende
Defaults und echte symbolische Links. Es bestanden 18 Windows- und 21
Linux-Prüfungen. Die echte lokale Desktopprüfung meldet für beide Provider
cgroup v2; der ursprüngliche WSL-Kernel hatte keinen v1-Speichercontroller.

Der neue Einstieg wurde im vorhandenen cgroup-v1-Linux-Gast aus einem separaten
Repositorysnapshot ausgeführt: eigene Lab_Data-Registrierung, beide Provider
mit Create-Readiness, Wiederaufnahme aus einem frischen Prozess und unveränderte
Journaldateien bei `-WhatIf` bestanden. Dabei wurde kein Hyper-V-Verwaltungsbefehl
verwendet. Der physische Testhost des Gastes bleibt Hyper-V; dies ist kein
Nachweis einer frischen Bare-Metal-Installation oder einer erfolgreichen
WSL-Sprachabnahme. OS-Paketinstallation und Kernelumstellung sind nicht Teil
dieses Einstiegs. Der vorhandene Mediencache wurde wiederverwendet.
Die getrennten Aufrufe `-Action Test -Provider docker` und `-Provider podman`
bestanden am 2026-09-25 (lokale Zeit): SQL 2025 mit Python/R/Java, echte
Sprachprobes vor und nach Restart sowie `REMOVED` für den eigenen Run.
Eine anschließende unabhängige Prüfung fand bei beiden Providern keine
verbliebenen Container oder Volumes. Der native Setupstand bleibt erhalten.
Der erfolgreiche Docker-Lauf erklärt die zuvor beobachteten sporadischen
Launchpad-/Java-Fehler nicht und ist kein Langzeitstabilitätsnachweis.

Der genehmigte WSL-Kerneltest mit Microsoft 6.18.40.1 und passenden Modulen
aktivierte den zuvor fehlenden v1-Speichercontroller. Auf einer eigenen
Ubuntu-22.04-Distribution bestand Docker alle drei SQL-Sprachprobes vor und
nach Restart sowie Cleanup. Der Testpool verwendet jetzt `maxProcesses=128`:
mit 32 scheiterte R beim Starten eines Unterprozesses, während 128 denselben
Imagepfad erfolgreich ausführte. Dies ist keine Änderung des Produktdefaults.
Die WSL-Podman-Prüfung mit Ubuntu-Podman/CNI scheiterte zunächst an nftables,
nach Umstellung auf Legacy-iptables an der Loopback-Portweiterleitung.
Die Container-IP war erreichbar. Im gespiegelten WSL-Netz überschreibt
`WSLOUTPUT` die CNI-Paketmarkierung; eine temporäre, exakt auf die eigene
Container-IP und den SQL-Port begrenzte Masquerade-Regel machte den Port
auf TCP-Ebene erreichbar. Der SQL-Prelogin über diesen Loopbackport scheiterte
weiterhin, während die direkte Container-IP bis zur SQL-Anmeldung gelangte.
Auch der saubere WSL-Neustart lieferte deshalb keinen Podman-Sprach-PASS.
Das ist eine Diagnose und keine allgemeine Netzwerkreparatur.
Die Kernelumstellung benötigt ein Wartungsfenster für die gesamte WSL-Runtime.

## Persistenter Linux-Containerhost

`Invoke-LinuxContainerHostChecks.ps1` prüft Ownership, VM-/Diskbindung,
Pfadgrenzen, SSH-Vertrag, feste RAM-Zuweisung, unveränderliche Repositoryrevision
und echte begrenzte Kindprozesse; am 2026-09-24 bestanden 29 Checks.
Eine echte `WhatIf`-Ausführung gegen die isolierte Eigentumslesefunktion
sichert die Diskbindung auch bei aktiver PowerShell-Vorschau ab.
`Tools/Invoke-SqlServerLabLinuxContainerHost.ps1` wurde auf einem Windows-
Hyper-V-Host mit gepinntem Ubuntu-Image tatsächlich aufgebaut. Bootstrap,
Recovery nach einem Git-Pfadauflösungsfehler sowie Stop/Start wurden ausgeführt.
Die native Prüfung deckte zusätzlich einen ungeeigneten Dynamic-Memory-Default
auf; der Erstellpfad setzt deshalb ausdrücklich statischen RAM.
Die Gast-Storage-Initialisierung wurde einschließlich Wiederaufnahme und
Discovery aus frischen PowerShell-Prozessen geprüft. Beide Provider melden
danach keine fehlenden Create-Voraussetzungen; `TARGET_AUTHORIZATION_REQUIRED`
bleibt der reguläre Hinweis auf die Prüfung des konkreten Operationsziels.
Die Gast-PowerShell-Einstiege setzen `TEMP=/tmp`, das der beibehaltene
Docker-Verfügbarkeitscheck des Lab-Cores voraussetzt.

Die getrennten Docker- und Podman-Läufe von
`Tests/Integration/Invoke-LinuxContainerHostAcceptance.ps1` bestanden am selben
Tag zunächst mit übersprungener Ressourcenbewertung: SQL 2025 mit Python/R/Java direkt provisioniert, alle drei echten
SQL-Sprachprobes vor und nach öffentlichem Restart bestanden, eigener Run
bereinigt. Eine zusätzliche Gastprüfung fand keine verbliebenen Container
oder Volumes und kein eigenes Testnetz. Der Host bleibt absichtlich erhalten; sein destruktives `Remove`
wurde an diesem persistenten Host nicht ausgeführt. Providercaches bleiben
erhalten. Diese Abnahme ersetzt weder den Reconcile-Nachweis für nachträgliche
Sprachänderungen noch eine Freigabe für cgroup v2 oder andere VM-Backends.
Nach Einrichtung der regulären Create-Voraussetzungen bestand ein weiterer
Podman-Lauf mit aktiver Ressourcenbewertung einschließlich aller Sprachprobes,
Restart und Cleanup. Zwei weitere Docker-Läufe mit aktiver Ressourcenbewertung
scheiterten dagegen: zuerst bei der Provisionierung mit SQL 39011 und einem
Launchpad-Netzwerkfehler, danach nach erfolgreicher Provisionierung beim
zusätzlichen Java-Aufruf mit SQL 39128 und gescheiterter SQL-Kompensation.
Das Entfernen der jeweiligen Testressourcen gelang. Die Ursache dieser
Laufzeitinstabilität ist offen; die frühere Docker-Evidence ist keine stabile
Freigabe. Der Runner sichert bei Fehlern nach der Erstellung zusätzlich einen
begrenzten Containerlog vor dem Cleanup. Rohdiagnosen bleiben lokal.
Die ältere Reconcile-Abnahme scheiterte an ihrer Manifest-/Intent-Erwartung;
siehe [bekannte Grenzen](KNOWN_LIMITATIONS.md).
Änderungen am gemeinsamen CI-Selektor behalten dessen volle Runtime-Matrix.
Die allgemeinen Docker-, Podman-, Mixed- und Adapter-Smokes bestanden lokal.
Der zusätzliche allgemeine Hyper-V-Smoke war zunächst durch die globale
Runtime-Testsperre blockiert. Nach Freigabe der Sperre bestand er am
2026-09-25 einschließlich VM-/Disk-Lifecycle, Reconcile und Cleanup. Der
konkrete Linux-VM-Bootstrap und dieser allgemeine Providernachweis bleiben
getrennte Prüfungen.
[Betrieb und Voraussetzungen](../User/LINUX_CONTAINER_HOST.md).

## Diagnosebundle

`Invoke-DiagnosticBundleChecks.ps1` prüft unter Windows und Linux den
geschlossenen read-only Vertrag mit synthetischem registriertem Storage,
realen modernen State-Produzenten, Canarywerten, Ownership-Negativen,
Dateibytegleichheit und begrenzten synthetischen Kindprozessen.
Provider-Readiness wird simuliert und durch `Invoke-ClientReadinessChecks.ps1`
an die bestehenden klassifizierten Resolver-/Prozessgrenzen gebunden.
Die Produktdateien wählen statische Prüfungen; Änderungen am gemeinsamen
CI-Selektor bewahren dessen vollständige Pflichtmatrix einschließlich Hyper-V.
Dieser API-Slice führt lokal keine nativen Provider-Smokes aus und behauptet
keine SQL- oder Runtime-Evidence. [Vertrag](../Architecture/DIAGNOSTIC_BUNDLE.md).

## Podman-KI-Erstellung

`Invoke-AiPodmanSetupChecks.ps1` prüft die echte interne Orchestrierung und
Menüintegration mit injizierten Provider-/SQL-Grenzen. Ergänzend führt
`Invoke-AiPodmanSetupProcessChecks.ps1` echte lokale Testkindprozesse für
Timeout, Abbruch, vorzeitiges Ende, private Ausgabe und Outputdrain aus.
`Invoke-AiPodmanSetupAcceptance.ps1` ist die separate native
Podman-Abnahme mit eigenem isoliertem StateRoot, echtem Initial-Apply/Query,
Restart, persistierter Query und vollständigem Own-Cleanup. Sie benötigt das
bereits vorhandene Hostmodell und zieht es nicht automatisch nach.
Die Podman-Referenz auf `9d8d313a` bestand am 2026-09-21: sechs Assertions,
Exitcode 0 und unabhängig bestätigte Restfreiheit der einzigen eigenen
Operation (Run entfernt, Runtimebindung passend, null Container/Volumes).
577 Core-/UI- und 34 Prozessassertions bestanden unter Windows und Linux;
der vollständige betroffene statische Gate bestand mit 19 Suites und
unverändertem Dateistand.
Der spezielle Dateiscope wählt Podman; gemeinsame Selektoränderungen behalten
die vollständige Pflichtmatrix einschließlich Hyper-V.
[Vertrag und Aufruf](../Architecture/AI_PODMAN_SETUP.md).

## SQL-Version-Upgrade-Referenz

Der [feste SQL-2022-/SQL-2025-Test](SQL_VERSION_UPGRADE_REFERENCE.md) wird zuerst
mit `Invoke-SqlVersionUpgradeScenarioChecks.ps1` und
`Invoke-SqlVersionUpgradeSupervisorChecks.ps1` offline geprüft. Die Suite nutzt
die echten Kontrollflüsse, Disk-State-Operationssuche und eigene Child-Prozesse;
SQL-/Providergrenzen sind synthetisch. Anschließend wählen tatsächliche geänderte
und unversionierte Pfade über `Get-CiTestSelection.ps1` die betroffenen Checks.
Die native Abnahme erfolgt getrennt mit
`Invoke-SqlVersionUpgradeAcceptance.ps1 -Provider docker` und `-Provider podman`.
Beide Referenzläufe bestanden am 2026-09-21 auf `46340200`; der unabhängige
Nachlauf bestätigte je Provider zwei entfernte Own-Runs und keine Runtime-Residuen.
CI-Hooks verwenden den vorhandenen Runtime-Lock. Die privaten temporären
Evidence-Wurzeln bleiben gemäß Runnervertrag erhalten; Runtime-Cleanup belegt
keine vollständige Entfernung aller temporären Dateien.
Die Fähigkeit selbst betrifft beide Containerprovider; die Änderung am gemeinsamen
Selektor behält ausdrücklich die volle bestehende CI-Pflichtmatrix bei.


## SQL-HTTPS-Referenzslice

`Invoke-AiSqlHttpsBridgeChecks.ps1` prüft Requestbytes, Vektorgrenzen,
Digest-/Remoteabwehr und den eigenen Zertifikat-/Prozesszyklus ohne SQL oder
Modellaufrufe. Echte Loopbackverarbeitung vor STOP, CA-/SAN-validiertes TLS mit
Authablehnung ohne Upstream und EOF-Cleanup gehören zur Offlineprüfung.
TLS 1.2 und TLS 1.3 prüfen getrennt WrongCA, WrongSAN und einen gültigen TLS-Kanal
ohne HTTP; Receipt `1.1` trennt lokale Handshakefehler, Schließen ohne
Anwendungsbytes und empfangene HTTP-Requests.
`Invoke-AiSqlHttpsBridgeAcceptance.ps1` führt den getrennten
Docker-Nachweis aus: SQL External Model, frische WrongCA-/WrongSAN-Handshakes,
Auth-/Payloadnegative, exaktes Retrieval vor/nach SQLrestart und vollständiges
Cleanup. Die Gesamtabnahme bestand nativ am 2026-09-21: sieben Embeddings,
vollständige SQL-TLS-Negative mit Receipt `1.1`, beide Rankings vor/nach
SQLrestart, unverändertes Hostmodellinventar und bestätigtes eigenes Cleanup.
[Vertrag](../Architecture/AI_SQL_HTTPS_BRIDGE.md).

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_WITH_GAPS` |
| Stand | 2026-08-27 |
| CI/CD | keine Voraussetzung für die lokale Produktfunktion |
| Ziel | reproduzierbare lokale Prüfung von Verträgen und Provider-Runtime |

## 1. Grundsatz

`Invoke-AiPersistentRetrievalMigrationChecks.ps1` ergänzt die v1-Regression um
Upgrade-/Staging-/Commit-Abbrüche, dynamische Caller-Generationen, unveränderte
Quellgenerationen, SQL-first Modellwahl, Präfix-/Digestdrift und
modellunabhängiges Cleanup. Der separate
`Invoke-AiPersistentRetrievalMigrationAcceptance.ps1` prüft feste und Caller-
Collections in eigenen Docker-/Podman-Runs. Die erweiterten Nachweise bestanden
am 2026-09-22 getrennt mit je 25 Assertions, SQLrestart und vollständigem Cleanup.
Siehe [Migrationsvertrag](../Architecture/AI_PERSISTENT_MODEL_MIGRATION.md).

`Invoke-AiPersistentRetrievalChecks.ps1` prüft den begrenzten persistenten
Containerpfad mit Chunk-/Commit-Antwortverlust, aktiver Altgeneration, fehlendem
Ownershipreceipt, Vektor-/Modell-/DB-Drift, Locks und Journalschreibfehlern.
`Invoke-AiPersistentRetrievalAcceptance.ps1` erstellt je Docker oder Podman
nur einen eigenen SQLrun und prüft echtes SQL-AppLock, Restart, Delta/Resume,
Fixture-Update/Delete, Caller-Dokument-Sync samt Ausgangs- und Hashdrift,
explizites Generation-Prune samt SQL-Tabellenbeleg,
SQL-Termabdeckungs-/Vektor-Hybridranking und vollständiges DB-/Run-Cleanup.
Docker und Podman bestanden am 2026-09-22 getrennt mit je 30 Assertions
einschließlich Caller-Collection, atomarem Update/Insert/Delete, freier Frage
und Hashdrift-Abweisung sowie idempotenter Retention und
vollständigem Cleanup;
[Vertrag und Aufruf](../Architecture/AI_PERSISTENT_RETRIEVAL.md). Der Selector
begrenzt diese Produktdateien auf Docker/Podman; Änderungen am Selector selbst
behalten die vollständige CI-Infrastrukturmatrix.

`Invoke-AiScenarioChecks.ps1` bindet auch `Fixtures/AiRagHostChecks.ps1` ein:

`Invoke-AiExternalModelAccelerationChecks.ps1` prüft getrennt den rein
lesenden, hashgebundenen Plan für vorhandene OpenAI-kompatible HTTPS-
Embedding-Endpunkte. Der Test deckt OpenVINO-NPU, den erforderlichen OVMS-
Gateway, einen exakt gebundenen Runtime-Modellnamen, falsche Backend-/
Accelerator-Kombinationen und den ausdrücklich noch nicht ausgeführten
Evidence-Status ab. Ein nachrechenbarer UTC-Receipt-Key bindet die Live-Probe an
den geheimnisfreien SQL-2025-Mutations-/Cleanupplan; Manipulation, Planabweichung
und abgelaufene Endpoint-Evidence werden vor jeder SQL-Verbindung abgewiesen. Der
Test startet keine Runtime und führt kein SQL aus.
Die gleiche statische Suite prüft den anschließenden read-only SQL-Preflight
mit injiziertem Executor: exakte Run-/Scope-/Instance-/Datenbankbindung,
SQL-2025-Version, `ONLINE`/`READ_WRITE`, Database Master Key, beide Rechte und
freie Credential-/Modellnamen. Version, Zustand, Master Key, Rechte,
Namenskollisionen einschließlich des abgeleiteten Ownership-Tabellennamens und
manipulierte Pläne besitzen getrennte Negativfälle.
Der anschließende Apply-Executor wird mit injiziertem SQL-Transport auf
transaktionale Reihenfolge, geheimnisfreies Vorjournal, exakte SQL-Postcondition,
`WhatIf`, idempotente Beobachtung mit `-Resume`, verlorene Antworten,
abgeschlossenen Zustandsdrift und blockierte Teilzustände geprüft. Diese
Suite prüft außerdem den receiptgebundenen Cleanup: exakte Ownership vor
Mutation, Löschreihenfolge External Model/Credential/Ownership-Tabelle,
idempotente Abwesenheit, blockierte Teilzustände und Apply-Sperre nach
`CLEANED`. Davor prüft sie die receiptgebundene SQL-Embeddingprobe auf Shared-
AppLock, erneute Ownership-/Katalog-ID-Bindung, parametrisierten Festtext,
Dimension, `float32`, endliche Nichtnull-Norm und sanitisiertes Receipt; falsche
Ergebnisanzahl, Dimension, Basistyp, Norm, Receipt und Katalogdrift scheitern
geschlossen. Diese
statischen Fälle führen kein DDL auf einer echten SQL-Instanz aus; ein nativer
SQL-2025-Nachweis bleibt separat offen.
Zusätzlich prüft er die read-only OVMS-Upstream-Probe mit numerischem Loopback,
festem `/v3/embeddings`-Pfad, exaktem Runtime-Modell, Dimension und endlichen
Vektorwerten. Der getrennte
`Tests/Integration/Invoke-AiOvmsHttpsGatewayAcceptance.ps1` verwendet unter
Windows nur eigene freie Loopbackports, einen synthetischen HTTP-Upstream und
eine kurzlebige CA-/Leaf-Kette. Er bestätigt TLS-Start, kanonische Planbindung,
planbasierte HTTPS-Endpunktprobe, Owner-Stop, Listenerabbau und Secret-Löschung
sowie den daraus erzeugten SQL-Plan ohne SQL-Verbindung oder Provider.
Accelerator- und SQL-Evidence bleiben ausdrücklich unbestätigt.

`Invoke-AiSharedGatewayPlanChecks.ps1` prüft den rein lesenden gemeinsamen
Gatewayplan: deterministische Verbraucherreihenfolge, stabile Planbindung,
lokale HTTPS-Ziele, reine Loopback-Upstreams, Inhalts- und Zertifikatshashes,
Secretreferenzen sowie negative öffentliche Ziele, falsche Backendpfade,
Duplikate und zusätzliche Hostdaten. Die Suite startet keinen Dienst, ändert
keine Zertifikate und verbindet sich nicht mit SQL; Apply/Remove und native
Evidence bleiben offen.
`Invoke-AiSharedGatewayPreflightChecks.ps1` erzeugt nur synthetische lokale
Dateien und eine kurzlebige CA-/Leaf-Kette. Die Suite prüft Planrevalidierung,
Runtime-/Modellhashes, privaten Schlüssel, CA-Pin, Chain, Gültigkeit und exakten
SAN sowie sanitisierte Evidence. Sie startet keinen Listener, Gateway oder SQL-
Zugriff und bestätigt weder geschützten Storage noch persistenten Dienstbetrieb.
`Invoke-AiSharedGatewayStorageChecks.ps1` registriert ausschließlich synthetische
Dateien in einem temporären StateRoot. Die Suite prüft benutzerexklusive Rechte,
atomare Veröffentlichung, schema- und hashgebundenen Zustand, idempotente
Mehrprozesskonkurrenz, Konflikt/Drift, `WhatIf` und Cleanup nach injiziertem
Publikationsfehler. Persistenter Dienst, Live-Endpunkt und SQL bleiben unberührt.
`Invoke-AiSharedGatewayUpstreamChecks.ps1` revalidiert denselben geschützten
Speicher und prüft über einen injizierten Transport die festen Llama-v1- und
OVMS-v3-Requests sowie Modell, Dimension, endliche Vektoren und Fehlerklassen.
Die Suite öffnet kein Netzwerk und bestätigt weder Dienst noch Beschleuniger.
Hostmodell-Digest/Capability/Dimension/Remoteidentity, Egress/Datenklasse,
WhatIf, Vektoren und echten synthetischen HTTP307 ohne Weiterleitung.
`Invoke-AiRagExistingOllamaAcceptance.ps1` ist eine separate opt-in Abnahme mit
vorhandenem Host-Ollama, ausdrücklich freigegebener Cloud und eigenem SQLrun;
Docker und Podman werden getrennt ausgeführt. Sie ersetzt weder Golden-v1 noch
die Hyper-V-Abnahme. Gemeinsame KI-Produktänderungen wählen weiterhin alle
drei betroffenen Provider; ihre Evidence bleibt getrennt sichtbar.

Die Fixtures `AiDiagnosticHostChecks.ps1` und `AiHyperVOwnRunChecks.ps1` prüfen
lokale Qwen-Bindung, Login-Teilfehler sowie VM-/Datenträger-/IPAM-Grenzen.
Die [isolierte Hyper-V-Abnahme](../Architecture/AI_HYPERV_OWN_RUN_ACCEPTANCE.md)
ist ein manueller Workflow mit explizitem Prepared-Artefakt und read-only
Vorprüfung. Der Container-Parametersatz `-LocalGeneration -IncludeDiagnostic`
prüft denselben Agentpfad auf Docker und Podman ohne Cloudsecrets getrennt.
Docker und Podman haben diesen lokalen Parametersatz am 2026-09-20 jeweils mit SQLrestart, Login-Cleanup und eigenem Ressourcen-Cleanup bestanden. Der getrennte Hyper-V-Lauf 35542940923 bestand am 2026-09-21 mit 14 Assertions, VM-Neustart, anschließendem SQL-Ready-Nachweis, Login-Cleanup und vollständigem VM-/Childdisk-/IPAM-Cleanup.

`Invoke-ReconcileContractChecks.ps1` prüft persistierte Sollidentitäten offline.
Jeder Persistenzfehler wird ausschließlich über feste ReasonCodes reflektiert:
`DESIRED_STATE_CONTRACT_INVALID`, `DESIRED_STATE_PROVISIONING_MODE_INVALID`,
`DESIRED_STATE_PERSISTENT_DATA_INVALID`, `DESIRED_STATE_INSTANCES_MISSING`,
`DESIRED_INSTANCE_ID_MISSING`, `DESIRED_INSTANCE_PROVIDER_MISSING`,
`DESIRED_INSTANCE_ID_INVALID`, `DESIRED_INSTANCE_PROVIDER_INVALID`,
`DESIRED_INSTANCE_INTENT_CONTRACT_INVALID`,
`INSTANCE_CAPABILITY_ASSESSMENT_INVALID` und
`DESIRED_INSTANCE_IDENTITY_DUPLICATE` sowie
`DESIRED_INSTANCE_NETWORK_INTENT_INVALID`,
`DESIRED_INSTANCE_SQL_ENDPOINT_INTENT_INVALID`,
`DESIRED_INSTANCE_SQL_CONFIGURATION_INTENT_INVALID`,
`DESIRED_INSTANCE_HYPERV_RESOURCE_INTENT_INVALID`,
`DESIRED_INSTANCE_DRIVE_INTENT_INVALID`,
`DESIRED_INSTANCE_STORAGE_INTENT_INVALID` und
`DESIRED_INSTANCE_DATABASE_INTENT_INVALID` sowie
`DESIRED_STATE_AI_INTENT_INVALID`. Ein vorhandener Network-Intent
enthält vollständig die kanonische, hostwertfreie Resolver-Projektion; ein
vollständig fehlendes `Network` bleibt ausschließlich für Legacy-Snapshots
zulässig. Mehrere Codes sind eindeutig und ordinal sortiert. RUNNING- und
STOPPED-Pläne bleiben dann `unsupported`, ohne Aktionen oder Fallback auf
Connection-Info; State- und Connection-Dateien bleiben bytegleich. Weder
Reconcile-Reasons noch Warnings spiegeln Instanz-ID, Provider, Host oder
sonstige dynamische Persistenzwerte. Auch ein ungültiger Hyper-V-Network-Intent
erreicht keine Runtime- oder Host-Cmdlet-Abfrage. Dieselbe Id unter verschiedenen
Providern bleibt gültig. Dies ist kein nativer Providernachweis.

`Invoke-InstanceCapabilityAssessmentChecks.ps1` prüft den privaten CORE-102-
Metadatenentscheid offline: Provider-/OS-Tuple, bestehende SQL-/Netzwerk-/
Softwareentscheidungen, pfadfreie Drives, Determinismus, Sanitierung sowie
Legacy- und Fehlerfälle des read-only Desired-State-Readers. Diese Prüfung
erzeugt keine Providerressourcen. Die bestehende Runtime-Auswahl für
`DesiredState.ps1` und den gemeinsamen CI-Selektor bleibt unverändert.

`Invoke-ManifestBuilderChecks.ps1` prüft die SQL-Lifecycle-Projektion der
Manifest-Planvorschau `1.3` offline: unterstützte, veraltete und unbekannte
Versionen, CU-Basisauflösung, unveränderte Eingaben, unabhängige fachliche
Fehler, leere Schemafehler-Hülle und Anzeige ohne Samples oder External Runtimes.
Die CI-Einzelpfadfälle binden Builder, Parser und Versionskatalog an dieselbe
Suite und bewahren deren Collation-Verknüpfung. Dies ist kein Providernachweis.

`Invoke-ResourceAssessmentChecks.ps1` prüft offline die Statuspriorität,
Overcommit-Entscheidung, Skip-Unterscheidung, lokale Messwertpersistenz und
hostwertfreie Lifecycle-Projektion einschließlich unveränderter Legacy-Bytes.
Die öffentlichen Docker-/Podman-/Hyper-V-Erstellungspfade werden mit
synthetischen Preflights bis zur echten State-Persistenz ausgeführt und vor
Providermutationen unterbrochen. Getrennte native Provider-Smokes bleiben
für Änderungen am Erstellungsvertrag erforderlich.

`Invoke-RunStateUpgradeChecks.ps1` erzeugt einen frischen Run-State über den
internen Konstruktor und prüft `SqlServerLab.RunState/1.0`, `NO_ACTION`, stabile
Versions-/Planbindung sowie unveränderte Dateimenge, Bytes und Schreibzeiten
nach Planung und Upgrade-Aufruf. Historische unversionierte States ohne
Fixture-Markierung bleiben blockiert; ausschließlich synthetische Legacy-
Migration und deren bestehendes Resume werden offline geprüft. Zusätzliche
Negativfälle prüfen Text-/Zahlmarkierungen, unvollständige aktuelle States und
fremde Änderungen an Scope, Status, Provider-Subruns oder zusätzlichen Zielfeldern.
Abgelehnte Aufrufe bewahren State und Journal beziehungsweise erzeugen keine
Upgrade-Artefakte. Änderungen an
`StateMachine.ps1` wählen diese Suite zusätzlich zur Mixed-Provider-
Lifecycle-Suite. Providerressourcen werden für diesen lokalen Vertrag nicht
benötigt; die Runtime-Auswahl des gemeinsamen CI-Selektors bleibt unverändert.

`Invoke-ScenarioCapabilityDecisionChecks.ps1` prüft SCN-803 providerlos mit
synthetischen JSON-Eingaben: vollständige, fehlende und teilweise Capability-
Abdeckung, Scenario-/Version-/Evidence-Bindung, UTC-Fristen, unbekannte Felder,
duplizierte JSON-Schlüssel, geschlossene Aufrufe und sanitisierte deterministische
Ausgaben. Die Produktsources wählen nur statische Prüfungen. Die Änderung am
gemeinsamen CI-Selektor fordert weiterhin dessen Runtime-Matrix im PR-Gate;
dieser lokale read-only Slice führt keine Provider-Smokes aus und behauptet
keinen solchen Nachweis.

`Invoke-ContainerMemoryFaultChecks.ps1` prüft den privaten Memory-Puls offline,
einschließlich gestopptem Restoreziel und separat persistierter SQL-Readiness.
`Tests/Integration/Invoke-ContainerMemoryFaultAcceptance.ps1 -Provider docker`
beziehungsweise `-Provider podman` prüft je einen frischen eigenen SQL-2025-Run;
`-HardInterrupt` prüft den authentifizierten Applied-Checkpoint und
Restore-only-Resume nach echtem Kindprozessabbruch. Provider werden sequenziell
geprüft. `-HardInterrupt -StopAfterInterrupt` prüft zusätzlich ohne Start die
exakte Docker-Limit-Rücknahme beziehungsweise die unverifizierte Podman-Grenze
und die erwartete SQL-Recoverygrenze. Bestehende
Testumgebungen sind ausgeschlossen. Der Abnahmestand steht
in `Documentation/Architecture/CONTAINER_MEMORY_FAULT.md`.

`Invoke-ContainerCpuFaultChecks.ps1` prüft den internen CPU-Puls offline mit
Fake-Provider und hart beendetem Kindprozess. Die getrennten nativen Läufe
`Tests/Integration/Invoke-ContainerCpuFaultAcceptance.ps1 -Provider docker`
und `-Provider podman` verlangen Readiness, einen frischen eigenen SQL-2025-
Run, Applied-/Restore-Postconditions und vollständiges Cleanup. Bestehende
Runs sind kein Testziel; Hyper-V wird dafür nicht gestartet. Der genaue
Recovery- und Deadlinevertrag steht in
`Documentation/Architecture/CONTAINER_CPU_FAULT.md`.
Die getrennten lokalen SQL-2025-Läufe für Docker und Podman bestanden am
2026-09-19 mit Applied-Postcondition, SQL-Probe, exakter Rücknahme, terminalem
Resume und jeweils zwei erfolgreichen Cleanup-Schritten ohne Restcontainer.
Die zusätzlichen lokalen Läufe mit `-Provider docker -HardInterrupt` und
`-Provider podman -HardInterrupt` bestanden am selben Tag: authentifizierter
Applied-Checkpoint, hart beendeter eigener PowerShell-Kindprozess, bestätigtes
Prozessende, exakte native Baseline-Rücknahme und SQL-Probe im Parent mit
`INTERRUPTED`/`CleanupStatus=PASSED`, keine Aktivierungswiederholung und bytegleiches
zweites Resume. Beide Runs entfernten Container und Volume mit jeweils zwei
Cleanup-Schritten und null Fehlern; Restobjektprüfungen und temporärer Cleanup
bestanden. Ein erster Podman-Versuch scheiterte vor Aktivierung an der
Inspect-Template-ID und bereinigte ebenfalls vollständig; nach Korrektur des
festen Providerfelds bestand der getrennte Wiederholungslauf. Host-/Engine-
Abstürze und andere native Unterbrechungszeitpunkte sind damit nicht belegt.

`Invoke-SqlObservabilityEvidenceChecks.ps1` prüft den geschlossenen,
sanitisierten Parser- und Schemavertrag offline. Die getrennten nativen
Referenzläufe `Tests/Integration/Invoke-ContainerSqlObservabilityAcceptance.ps1
-Provider docker` und `-Provider podman` verwenden jeweils einen frischen
eigenen SQL-2025-Linux-Run. Sie prüfen öffentliche rungebundene Capture vor und
nach einem öffentlichen Restart, die exakte Query-Store-/Online-Datenbankdelta
einer synthetischen Datenbank, einen persistenten Marker, Privacy-Grenzen und
scopegebundenen Container-/Volume-Cleanup. Beide Läufe bestanden am 2026-09-20
mit jeweils 35 Assertions. Hyper-V, externe Provider, Extended Events,
SQL-Agent-/Backupzustände, Retention und Evidenzpakete bleiben getrennte
Nachweise.

`Invoke-ScenarioExecutorChecks.ps1` prüft SCN-802/SCN-804 ausschließlich offline:
Phasenreihenfolge, Cancellation vor/nach Arrange, Arbeits-/Phasen-/Cleanup-Timeouts,
Handler-/Cleanupfehler, begrenztes Cleanup-Resume, Ownership-/Planbindung,
Journalmanipulation, Lockkonflikt, Sanitierung und einen hart beendeten eigenen
PowerShell-Kindprozess. Sämtlicher State ist synthetisch und temporär.
Plan `0.2` wird mit fehlenden, typfalschen und außerhalb der Grenzen liegenden
Phasencaps sowie alten Versionen negativ geprüft. Jeder Primärphasencap,
die frühere globale Frist, ein erst beim Phaseneintritt beginnendes Budget,
unabhängiges Cleanup und die Ablehnung geänderter Caps bei unterbrochenem
Resume sind Bestandteil derselben Suite.
`Invoke-ScenarioContractChecks.ps1` erhält unabhängig davon SCN-801 als
Metadatenvertrag. Die Produktsources wählen keine Provider-Smokes; Änderungen
am gemeinsamen CI-Selektor wählen weiterhin dessen vollständige Runtime-Matrix.

`Tests/Static/Invoke-SecurityToolCatalogChecks.ps1` prüft den geschlossenen
Security-Tool-/Trust-Metadatenkatalog, die leere produktive Allowlist und den
direkten read-only Plan. Ausschließlich synthetische Katalogdaten prüfen
IDs, vollständige Zieltuple, Windows-/Hyper-V- und Linux-/Docker-/Podman-Bindung,
Review-/Widerrufsfristen, Hashbindung und Nebenwirkungsfreiheit. Die Prüfung
erzeugt keine Providerressourcen und ersetzt weder Signaturprüfung noch
Windows-/Linux-Beschaffungsabnahme. Beide produktiven Dateien werden gemeinsam
über eine geschlossene AST-Aufruf-Allowlist geprüft; Quelldateien, Request und
Prozessumgebung bleiben unverändert.

`Invoke-CollationCatalogChecks.ps1` prüft Katalogsuche, exakte versionsgebundene
Instanzbindung, kanonische Schreibweise, ungültige und doppelte Namen,
Manifest-/Ad-hoc-Abweisung vor Provisionierung, verweigerte Wizard-Speicherung
und die Konsolensuche mit null Treffern und Abbruch. Die Tests verwenden
synthetische Katalogfixtures und ersetzen die Konsoleneingabe; sie starten
keine Provider. `Invoke-CollationRuntimeEvidenceChecks.ps1` prueft den
Containerpfad mit gefakten SqlClient-Objekten: erneute Katalogbindung, genau
eine parametrisierte read-only Abfrage von `sys.fn_helpcollations()` und
`SERVERPROPERTY('Collation')`, fehlende Katalogverfuegbarkeit, abweichende
Postcondition, sichere Credentials und die Reihenfolge vor Konfiguration,
Datenbanken und Samples. Die native Docker-/Podman-Acceptance bestand am
2026-09-13 im PR-Gate-Lauf `34783317945` fuer SQL Server 2025 und
`Latin1_General_100_CS_AS`: Beide Provider bestaetigten Katalogverfuegbarkeit,
`SERVERPROPERTY('Collation')`, run-gebundene sanitisierte Evidence und
vollstaendigen Cleanup. Hyper-V bleibt separat.

Der allgemeine Windows-Aktivierungsintent wurde am 2026-09-10 durch 33
betroffene statische Suites geprueft. Zusaetzliche fokussierte Nachweise
decken den SQL-Blocker, Pool-Resume, unveraenderte permanente NIC bei Erfolg
und Fehler sowie Cleanup vor dem Bereits-aktiviert-No-Op ab.
`Invoke-HyperVWindowsLocaleAcceptance.ps1` verlangt im eigenen Child auch
einen aktiven Live-Lizenzzustand und prueft ein gegebenenfalls entstandenes
temporaeres Adapterjournal auf vollstaendiges Cleanup. Die Ausgabe trennt
`ALREADY_ACTIVE_NO_OP` von `TEMPORARY_ADAPTER_CLEANED`; ein No-Op ist kein
Nachweis einer neuen Online-Aktivierung. Der Lauf `34439763621` vom 2026-09-10
auf `0a8cb93` bestaetigte `TEMPORARY_ADAPTER_CLEANED`, aktiven Live-Zustand,
Locale nach Kaltstart und `CLEANUP_SUCCEEDED` mit drei Schritten und null
Fehlern. Der Nachweis der permanenten NIC bleibt separat offen.

`Invoke-WindowsActivationNetworkChecks.ps1` prueft Adaptervorbestand,
Identitaetsbindung, Teilfehler, idempotenten Cleanup und Recovery-Konflikte.
`Invoke-WindowsActivationNetworkAcceptance.ps1` hat am 2026-09-10 mit einer
ausgeschalteten eigenen VM und einem privaten Switch Erfolg, kontrollierten
Fehler und Resume nativ bestaetigt. Der gleichnamige fremde Fixture-Adapter
blieb unveraendert; abschliessender VM-/Switch-/Datei-Cleanup war erfolgreich.
Es wurde weder ein Gast gestartet noch eine Windows-Lizenz aktiviert.

`Invoke-WindowsLocaleChecks.ps1` prueft portable Normalisierung, Schema,
Wizard-/Batch-Bindung, Image-Sprachgrenze, Lock-Idempotenz und widerspruechliche
Receipts. Die Hyper-V-Umgebungssuite prueft den nach OOBE geschriebenen Receipt.
Der gesonderte `Invoke-HyperVWindowsLocaleAcceptance.ps1` prueft einen eigenen
Batch mit US-Profil nach Kaltstart. Run `34435602810` auf `bbd29e7` hat am
2026-09-10 OOBE, alle fuenf Werte, Lock-/Receipt-Bindung und Cleanup auf
Windows Server 2025 bestaetigt. Der vorherige Lauf `34434505887` auf `70cf4a8`
waehlte eine ungeeignete Legacy-Baseline und lief in den OOBE-Timeout;
sein dreistufiger Cleanup war erfolgreich. Die Baseline-Auswahl ist jetzt
explizit auf Windows Server 2025 begrenzt und statisch regressionsgeprueft.

`Invoke-HyperVSqlPreparedLocaleAcceptance.ps1` verwendet getrennt davon nur ein
explizites vorhandenes englisches SQL-2025-Prepared-Artifact. Es erzeugt einen
eigenen Manifest-Child mit US-Locale, prüft den Gast nach Kaltstart über die
VM-ID-gebundene PowerShell-Direct-Probe und einen echten SQL-SELECT mit Major 17, bewahrt
den Parent-Hash und entfernt ausschließlich den operationseigenen Run.
[Run 35574934252](https://github.com/gecompat/SQL_Server_Lab/actions/runs/35574934252)
bestand am 2026-09-21 auf `bf72dc32` diese direkte en-US-/SQL-2025-Referenz
mit Aktivierung, Locale-Receipt und überwachtem Cleanup; der eigene
Run-State wurde zusätzlich als `REMOVED` bestätigt. Die Offline-Suite führt auch fehlende/gewechselte VM-ID, Operationskonflikte, SQL-Timeout/-Identität, Receipt-/Parent-Abweichung, verlorene New-Rückgabe und Cleanup-Reste aus. Der manuelle Modus `sql-prepared-locale-acceptance` bindet denselben Repository-Checkout an den exakten 40-stelligen Commit; ArtifactId und StateRoot werden als Environmentwerte übergeben. Clone-Quellen sind ausgeschlossen.
Der CI-Supervisor prüft mit echten synthetischen Kindprozessen Erfolg, Fehler,
abgebrochenen Arrange ohne Quittung, Timeout und Cleanupfehler. Rohmeldungen bleiben
lokal im geschützten Temp-Verzeichnis außerhalb des Repositorys; nur feste Codes
erreichen GitHub. Parentgewählte Operation-ID, getrennte Fehlererhaltung und Cleanup
erst nach bestätigtem Kindprozessende sind ausführbar geprüft. Arrange ist auf
90 Minuten, nachfolgender Cleanup auf 15 Minuten begrenzt; beide verwenden den
bestehenden Runtime-Smoke-Mutex. Diese synthetischen Tests ersetzen keinen Hyper-V-Lauf.

`Invoke-BlockingActionProgressChecks.ps1` prueft einen mit `Thread.Sleep`
blockierten Hauptthread: Heartbeat ab fuenf Sekunden, Drosselung,
Phasenwechsel, Secretfreiheit, verschachtelte Aufrufe und Cleanup ohne
Beenden eines geliehenen Reporters. Ein echter PowerShell-Terminaltest vom
2026-09-10 zeigte die formatierten Zeilen bei 00:05 und 00:06 und entfernte
die Anzeige anschliessend. Ein weiterer Terminaltest bestaetigte den
Finally-Cleanup; er wird nicht als gezielt nachgewiesener Ctrl-C-Abbruch
gewertet. Die statische Suite stoppt zusaetzlich eine echte Pipeline waehrend
eines synchronen .NET-Aufrufs und bestaetigt den Reporter-Cleanup nach dessen
Rueckkehr. Der WMI-Transport bleibt unveraendert; ein vollstaendiger neuer
Legacy-Gastlauf ist damit nicht behauptet.

Die zusaetzliche Legacy-SQL-Fixture in derselben Suite verwendet den echten
Host-Receipt-Wartepfad mit synthetischem WMI-/SMB-Transport. Sie reproduzierte
die fehlende Anzeige zwischen den WMI-Aufrufen. Nach Einbindung des gesamten
Wartepfads sind Heartbeat, Receipt-Ausgabe, Verbindungs-/Receipt-Fehler,
Transport-Cleanup und geliehener Reporter geprueft. Legacy-OOBE und direkte
Setup-Abfragen verwenden denselben bereits vorhandenen Reporter. Der
Produkttransport und dessen Abbruchlatenz bleiben unveraendert; ein neuer
Legacy-Gastlauf steht weiterhin aus.

`Invoke-HyperVPersistentDataDriveChecks.ps1` prueft Operations-Lease,
Recovery-Markierung und Reattach-/Release-Abschluss mit schreibfreier Preview,
Revisionskonflikten und bestehenden Clone-/Resume-Fehlerpfaden.
`Invoke-HyperVPersistentDataDriveAcceptance.ps1` serialisiert den kleinen
nativen VHDX-Nachweis am Runtime-Mutex; Cleanup bindet die erzeugte VM-ID
und den eigenen Temp-Pfad und erhaelt Dateien bei VM-Cleanupfehlern.
Der lokale native Lauf auf 84ffc91 vom 2026-09-10 bestand: 64-MB-Test-VHDX,
ausgeschaltete eigene VM, unveraenderte Quelle, unabhaengiger Clone mit neuer
DiskIdentifier, Reattach, Release und Cleanup. SQL- und Gast-Evidence dieses
kleinen Hosttests ist modelliert und bleibt ausdruecklich separat.

Am 2026-09-10 bestaetigte die getrennte Instanzstore-Abnahme fuer Docker und
Podman den gemeinsamen Katalogkern fuer regulaere Leases und Mehr-Volume-
Clones: stabile IDs, atomare Datenbankreferenzfreigabe, Continue, Digest fuer
Hauptvolume und beide Sidecars, Katalogcommit sowie erhaltene Serverobjekte
und Benutzerdaten. Nach beiden Laeufen blieben keine neuen Testcontainer,
Testvolumes oder temporaeren Testverzeichnisse zurueck. Der Test begrenzt
jeden SQL-Container auf 4 GB und zwei CPUs; SQL selbst auf 2048 MB. Vor der
rekursiven Dateibereinigung wird der exakte eigene Temp-Pfad validiert.

`Invoke-ContainerInstanceStoreChecks.ps1` prueft auch Preview und veraltete
Revisionen fuer Clone-Lease und Zielregistrierung. Die synthetischen Spiegel
bleiben bei Preview unveraendert; Apply registriert das Ziel und loest die
Quell-Lease in derselben Revision. Copy-/Katalogfehler und Resume bleiben
Bestandteil der Suite; diese Pruefung startet keine Container-Runtime.

Die drei Retained-Store-Suites `Invoke-RetainedStoreRemovalChecks.ps1`,
`Invoke-RetainedStoreRuntimeChecks.ps1` und
`Invoke-RetainedStoreRemovalConcurrencyChecks.ps1` prüfen Producer-Fixtures,
Preview/WhatIf/Abbruch, stabile Planbindung, CAS-/Lease-/Referenzschutz,
Journal- und Spiegel-Schreibfehler, verlorene erfolgreiche Delete-Antworten,
vorwärtsgerichtetes Resume sowie den dauerhaften Tombstone. Echte getrennte
Prozesse prüfen den Katalogmutex und Prozessabbruch; Runtime-Befehle bleiben
synthetisch. Timeout-/Partial-New-Supervisortests prüfen privaten Logtransport
und unabhängiges Cleanup erst nach bestätigtem Prozessende.

Die vorbereitete native Abnahme
`Tests/Integration/Invoke-RetainedStoreRemovalAcceptance.ps1 -Provider docker`
beziehungsweise `-Provider podman` erstellt ausschließlich einen frischen eigenen
SQL-2025-Run mit isoliertem StateRoot/DataRoot. Sie schreibt einen SQL-Marker,
trennt den behaltenen Store ab, prüft WhatIf, öffentliche Löschung, Tombstone,
idempotentes Resume und eigene Restfreiheit. Der Parent hält
`SQL_Server_Lab_Runtime_Smoke` (unter Windows `Global\`), begrenzt den Arbeitschild
auf 1200 und Cleanup auf 300 Sekunden und erhält private Evidence auch nach
Fehlern. Am 2026-10-01 bestanden Docker und Podman auf `b2a1f456` getrennt
jeweils sechs Assertions sowie der separate Cleanup. Ein lokal geprüfter
Schutzwrapper wählte pro Lauf ein frisches eigenes konfliktfreies Testnetz
über Prozessvariablen; die unverpackte Abnahme verwendet das konfigurierte
Standardnetz. Eigene Container, Volumes und Testnetze waren danach abwesend;
die sechs laufenden Shared-Umgebungen, fremde VM-Zustände, geschützte Dateien
und gespeicherten Defaults blieben unverändert. Rohdaten und Testwrapper
bleiben ausschließlich lokal. Der unabhängige Ergebnisnachreview wurde für
beide Provider getrennt geschlossen; weitere SQL-Versionen und Storageklassen
bleiben offen.
Die Capability selbst betrifft Docker/Podman; die gekoppelte Änderung am
gemeinsamen Testselektor verlangt nach bestehenden Regeln den breiteren CI-Gate
einschließlich Hyper-V und wird nicht dafür abgeschwächt.

`Invoke-PersistentStorageRecoveryChecks.ps1` prüft öffentliche Preview, WhatIf,
Abbruch, Apply und Wiederholung mit echten schemaförmigen Producer-Fixtures.
Negative Ownership-, Retention-, Runtime-, Sidecar-, Lifecycle-, Lease- und
Bindungsfälle erhalten Katalogbytes und Labels; Evidence-Wechsel zwischen
Preview und Apply, Revisionkonflikt, Spiegelrollback und Consumer-Runtimewechsel
sind injiziert. Legacy-Intents bleiben lesbar; unvollständige historische Runs
bleiben nicht recoverbar. Dies ersetzt keinen nativen SQL-Inhaltsnachweis.
`Tests/Integration/Invoke-PersistentStorageRecoveryAcceptance.ps1 -Provider docker`
beziehungsweise `-Provider podman` bestand am 2026-09-21 auf `d26c29b2`
getrennt je acht Assertions: eigener frischer retained SQL-2025-Store,
Serverobjekt und Datenmarker, Detach, Verlust ausschließlich der eigenen
isolierten Katalogbindung, öffentliche Recovery und Continue sowie unveränderte
Labels. Beide Runs je Provider endeten mit zwei Cleanup-Schritten ohne Fehler;
das eigene retained Volume und der isolierte Testroot wurden anschließend entfernt.
Der regulaere Container-Lease-Erwerb und -Release verwenden ebenfalls den
gemeinsamen Katalogkern. Die Katalogsuite prueft deren Previews, erwartete
Revisionen und den fehlerhaften Release: `RECOVERY_REQUIRED` wird im Apply
vor dem Fehler committed, waehrend derselbe Preview keinerlei State schreibt.

`Tools/Get-SqlServerLabCapabilityInventory.ps1` liefert den aktuellen
maschinellen Produktquellen-, Export-, Provider-, Test- und Planungsindex.
`Tests/Static/Invoke-CapabilityInventoryChecks.ps1` prueft Exportparitaet,
portable Dateiverweise, Evidenzgrenzen, fehlerhaftes JSON und das Nichtverfolgen
von Symlinks/Junctions einschliesslich indirektem Modulimport. Das Inventar
fuehrt keine Tests oder Runtime-Probes aus und ersetzt keinen semantischen
Backlog-Abgleich.

Der versionierte [Nachweisindex](capability-evidence-index.json) ergänzt diese
Inventur um getrennte historische Prüfungen. Jeder Eintrag bindet Fähigkeit,
Provider, SQL-Version beziehungsweise `null`, Plattform, Scope, vollständige
Quellrevision, Testdatei, Ergebnis, Cleanup, Datum und öffentliche PR-/CI-/
Commitreferenz. Er ist eine kleine Querverweistabelle, keine zweite Task- oder
Runtime-Registry. Frühere Fehler bleiben erhalten; spätere Ergebnisse erhalten
eine eigene Zeile. SQL-Versionen erhalten auch den kanonischen Legacywert
`2008R2`, damit er nicht mit `2008` zusammenfällt. Native SQL-Abnahmen benötigen eine SQL-Version und einen
Integrationstest; statische Hyper-V-Checks werden dadurch nicht nativ.

Die Inventur liest den optionalen Index schema-validiert, auf 256 KiB begrenzt
und ohne Symlinks/Junctions. Ungültige Einträge ergeben `PARTIAL` sowie einen
sanitisierten Fehlercode; unbekannte Payloadfelder und `PASS` ohne geklärten
Cleanup werden abgewiesen. `RecordedEvidence` bleibt stets
`RECORDED_HISTORY_ONLY`; vorhandene Testdateien werden nur als `PRESENT`
referenziert. `CurrentExecutionStatus` und die allgemeine Runtime-Evidence
bleiben `NOT_EXECUTED`. Die Inventur prüft weder den Inhalt externer Referenzen
noch die Existenz historischer Commits und bestätigt keine aktuelle
Quellgleichheit. Neue Einträge benötigen daher eine geprüfte tatsächliche
Ausführung mit sanitisiertem Quellenbeleg. Es werden keine Rohlogs importiert.

Der optionale Schalter `-IncludeRecordedAcceptanceMatrix` ergänzt die Inventur
als `SqlServerLab.RepositoryCapabilityInventory/1.1`; ohne Schalter bleiben
Version `1.0` und deren Felder unverändert. Die sparse Sicht gruppiert nur
validierte Indexeinträge nach exakter Fähigkeit, Provider, SQL-Version
(einschließlich typisiertem `null`), aufgezeichneter Plattform und Scope.
`RecordedPlatform` ist keine abgeleitete Gastplattform. Alle Records bleiben
ordinal deterministisch erhalten. Unterschiedliche Ergebnisse oder Cleanupwerte
für dasselbe Tupel mit gleicher Revision, Testdatei und Datum setzen
`HistoryConflict`; es gibt keinen Latest-Winner. Andere Daten oder Revisionen
bleiben separate Historie. Die Suite prüft die tatsächliche Tool-Komposition,
Defaultparität, Tupeltrennung, Reihenfolge, Konflikte, 128-Record-Grenze sowie
geschlossene leere Zellen bei fehlendem, ungültigem oder umgeleitetem Index.
Die vorhandene Modulinventur bleibt unverändert; der Schalter ergänzt keine
Imports, Readiness- oder Providerproben.

Die Persistent-Storage-Katalogsuite prueft auch den umgestellten
Container-Datenbankreferenz-Writer: Preview ohne Katalogschreiben, genau eine
Revision beim Apply, stabile Referenz-IDs bei No-op sowie Abweisung einer
veralteten Revision und eines fremden Runs. Die übrigen direkten Writer bleiben
separate PSR-003-Folgearbeit.

`Tests/Static/Invoke-SkillChecks.ps1` validiert die drei Repository-Skills unter
`.agents/skills`: eindeutige Namen, einfache YAML-String-Metadaten, vorhandene
repositorygebundene Verweise und tatsaechlich exportierte Fachbefehle.
Negative Header-Faelle pruefen den Validator selbst. Zusaetzlich bestand der
Skill-Creator-YAML-Validator fuer jede Datei. Diese Nachweise pruefen die
versionierten Dateien und nicht die Skill-Erkennung eines beliebigen Clients.

`Tools/Test-SqlServerLabClientReadiness.ps1 -Provider docker -Operation Inspect`
prueft den Client ohne Skill, Setup oder Runtime-Start. Der strukturierte
Vertrag `SqlServerLab.ClientReadiness/1.0` nennt fehlende Voraussetzungen,
Warnungen und naechste Schritte ohne Hostpfade oder native Rohfehler. READY
belegt den Bootstrap; `MutationAllowed` und `SkillLoaderVerified` bleiben false.
`Tests/Static/Invoke-ClientReadinessChecks.ps1` prueft fehlende Installation,
ungültige Aufloesung, Ausfuehrungs-/Runtimeberechtigung, Nichterreichbarkeit,
Timeout, ungueltige Antworten und unvollstaendigen Checkout getrennt.

`Tests/Static/Invoke-HyperVSqlOwnershipInitializationChecks.ps1` fuehrt den
echten Initialisierungsaufruf aus dem SQL-Slotworkflow mit fehlenden, null,
leeren, positiven und ungueltigen Trace Flags gegen synthetische Receipts aus.
Der Gegenbeweis mit dem urspruenglichen Aufruf scheiterte am fehlenden Feld.
Der native CLI-Lauf vom 2026-09-10 erreichte OOBE, SQL-Installation und
Hostzugriff, scheiterte dann an `HYPERV_SQL_CONFIGURATION_OWNERSHIP_TRACE_FLAG_INVALID`
und bereinigte alle acht Run-Ressourcen. Die Wiederholung nach Korrektur auf
302a37d bestand im [nativen CLI-Lauf 34427219338](https://github.com/gecompat/SQL_Server_Lab/actions/runs/34427219338)
mit 29 PASS-Meldungen und `CLEANUP_SUCCEEDED`: eigener Windows-Klon, OOBE,
SQL-Installation und Konfiguration, Readiness, Kaltstart, Daten-/Storagepfade,
Chinook und Ressourcenwechsel. Ein synthetischer 2-MB-Sessiontransfer in beide
Richtungen wurde per Hashvergleich geprueft. Die interaktive Hostanzeige bleibt
durch die separaten Offline-Vertraege abgedeckt; CI belegt deren Darstellung nicht.

`SQL_Server_Lab` stellt seine Qualitätsprüfungen als lokal ausführbare Skripte bereit.

Die lokale Validierung besteht aktuell aus drei produktiven Ebenen:

1. statische Vertrags- und Dokumentationsprüfung ohne Labmutation;
2. mutierender End-to-End-Smoke-Test für einen ausgewählten Laufzeitprovider (oder Auto-Auswahl);
3. Übergreifender Referenztest (`Invoke-SmokeMatrix`) über erreichbare Provider mit SQL Server 2025 und optionaler Parallelitätsprüfung.

Die vertiefte, providergetrennte CLI-Abnahme ist in der
[CLI-Akzeptanzmatrix](CLI_ACCEPTANCE_MATRIX.md) festgelegt. Sie ergaenzt die
kleinen Smokes um reale Samples, getrennte Storagepfade, TempDB auf mehreren
Datentraegern, Ressourcenwechsel und den Cleanup echter Windows-SQL-Slots.

### 1.1 Validierungsscope der AI Repository Foundation

Die Foundation ergänzt die vorhandenen Prüfungen, ersetzt sie aber nicht. Die
Nachweise werden getrennt ausgewiesen:

| Scope | Zuständiger Nachweis |
|---|---|
| `FOUNDATION_INTEGRITY` | Foundation-Validator gegen die installierten Dateien unter `.ai/foundation/`, den Root-Bridge-Block, die Provenienz und ausgewählte Adapter |
| `PROJECT_SEMANTIC` | vorhandene statische Projektverträge, insbesondere `Invoke-DocumentationChecks.ps1`, `Invoke-PrivacyScannerChecks.ps1` und die betroffene Auswahl über `Invoke-ImpactedChecks.ps1` |
| `RUNTIME_EMPIRICAL` | Builds, Provider-Smokes, Integrationsprüfungen und manuelle Abnahmen, wenn der Änderungsscope Runtimeverhalten berührt |

Die Foundation-1.8-Identity-, Registration-, Upgrade-, Continuity- und
Rule-Context-Cache-Policies
werden unter `FOUNDATION_INTEGRITY` auf Datei-, Schema-, Katalog- und
Indexebene geprüft. Die projektspezifische Scope- und Authority-Zuordnung steht
in `.ai/IDENTITY_AND_ARTIFACT_REGISTRATION.md` und wird unter
`PROJECT_SEMANTIC` geprüft. Lokale Runtime-Registries bleiben unveränderte,
nicht versionierte Betriebsdaten; ohne Runtime-Änderung ist kein Provider-Smoke
durch diese Governance-Integration betroffen.

Historische Foundation-Upgrades werden unter
`.ai/foundation-upgrade-assessments/` als getrennte, schema-validierte
Assessment-Datensätze nachgewiesen. Der Projektcheck bindet jeden Datensatz an
installierte Version, Zielversion und exakten Foundation-Quellref und vergleicht
die vollständige Kandidatenmenge samt Delta-Gründen, Klassifikation,
Repository-Evidence, Begründung und ausgewählten Capabilities. Eine bloße
Statusliste in der Repo-Map genügt nicht als Upgrade-Nachweis.

Der Foundation-Validator behandelt bei verwaltetem UTF-8-Text ausschließlich
LF-/CRLF-Unterschiede als äquivalent. Andere Inhalts-, Final-Newline-, Lone-CR-
oder Binärunterschiede bleiben echte Drift. Die Projektkonfiguration für
`.gitattributes` wird dadurch nicht verändert.

Blockierte Pflichtprüfungen werden als `VALIDATION_FAILURE`,
`INFRASTRUCTURE_UNAVAILABLE` oder `UNKNOWN` klassifiziert. Ein inhaltlich
fehlgeschlagener oder nicht eindeutig klassifizierter Check darf nicht über
einen Continuity-Pfad umgangen werden. Bei Infrastrukturunverfügbarkeit bleibt
die Prüfung bis zum erfolgreichen Nachlauf ausstehend. Der verbindliche
Notfallablauf und die tatsächlich aktiven, geschichteten GitHub-Rulesets stehen
im [Repository-Continuity-Runbook](REPOSITORY_CONTINUITY_RUNBOOK.md). Der
Break-Glass-Akteur darf ausschließlich über einen Pull Request umgehen;
PR-Pflicht, Löschschutz und Force-Push-Schutz besitzen keinen Bypass.

Der Foundation-Validator wird aus einem Checkout der Foundation ausgeführt:

```text
python tools/foundation_validator.py --target <SQL_Server_Lab-Checkout>
```

Ein grüner `FOUNDATION_INTEGRITY`-Nachweis ist kein Nachweis für
`PROJECT_SEMANTIC` oder `RUNTIME_EMPIRICAL`. `NOT_EXECUTED` entspricht
`not executed`; `PASS` darf nur für den tatsächlich ausgeführten und
bestandenen Scope als `validated` abgebildet werden. `SKIP_OPTIONAL`,
`UNSUPPORTED`, `WARN`, `FAIL` und `RECOVERY_REQUIRED` bleiben eigenständige
Projektstatus und dürfen nicht als `validated` dargestellt werden.

## 2. Aktuelle Einstiegspunkte

Der direkte Fortschrittskern wird mit
`Tests/Static/Invoke-ActionProgressChecks.ps1` geprueft. Synthetische Uhrzeiten
belegen die Fuenf-Sekunden-Schwelle, Drosselung, Phasenwechsel und sanitisierten
Messwerte. Ein verzoegerter Loopback-HTTP-Transfer und ein stiller nativer
Kindprozess belegen Zwischenmeldungen vor dem Ende; Redirect-Verweigerung,
Retry, Fehler, Timeout und Reporter-Cleanup werden funktional geprueft.
Die echte Readiness-Poll-Schleife verwendet dabei einen synthetischen sqlcmd-
Ersatz. Diese Tests sind kein SQL- oder Provider-Runtime-Nachweis.

`Tests/Integration/Invoke-ActionProgressAcceptance.ps1 -Provider docker|podman`
baut ohne Download ein synthetisches Scratch-Image ueber denselben nativen
Wrapper. Label- und Image-ID-Bindung schuetzen den abschliessenden Cleanup;
vorhandene Images werden weder ersetzt noch entfernt. Docker und Podman
bestanden diesen Test am 2026-09-10 getrennt. Die separaten SQL-2025-Smokes
bestanden jeweils 34/34 Pruefungen samt Run-Cleanup. Native Runtime-Build-Caches
bleiben unter der bestehenden Providerverwaltung; der Test fuehrt kein Prune aus.

### sqlcmd-Passwortbindung

`Tests/Static/Invoke-SqlActionProgressChecks.ps1` prüft unveränderte
synthetische Passwortwerte einschließlich Minus, Leerzeichen, Anführungszeichen,
Backslash und Unicode über Query, Readiness und KeepConnection.
`Invoke-ReadinessContractChecks.ps1` bindet beide Provider-Healthchecks und
den gemeinsamen Container-Reconcile an denselben Shellargumentvertrag.
`Tests/Integration/Invoke-SqlcmdPasswordParserAcceptance.ps1` reproduziert
mit dem echten lokalen ODBC-sqlcmd-Hilfeparser den getrennten Argumentfehler
und prüft die gebundene Form ohne SQL-Verbindung. Keine Passwortwerte oder
nativen Argumente werden ausgegeben. Dieser Parsernachweis bestand am 2026-09-21.

`Tests/Integration/Invoke-SqlcmdPasswordAcceptance.ps1 -Provider docker`
und separat `-Provider podman` prüfen je einen eigenen SQL-2025-Run mit
synthetischem führendem Minus: Hostquery und Containerstatus `healthy`.
Die globale Runtime-Sperre wird vor Runtimeaktionen bis zu 30 Minuten erworben;
PASS setzt bestätigtes Run-/Volume-Cleanup voraus. Bei unklarer Bindung bleibt
der Recovery-State erhalten. Docker und Podman bestanden am 2026-09-21
getrennt Hostquery und `healthy`; je zwei Cleanup-Schritte endeten ohne Fehler,
Container- und Volume-Abwesenheit wurden bestätigt. Host-sqlcmd wird auch von Windows-/Hyper-V-SQL-Workflows
verwendet; die Änderung am gemeinsamen Wrapper hebt deren Auswahl im
verbindlichen Impact-Selector nicht auf und ist kein neuer Hyper-V-Nachweis.

### Statische Prüfung

`Tests/Static/Invoke-JobProgressChecks.ps1` prueft echte lokale PowerShell-Jobs:
stille sechssekuendige Ausfuehrung, Ergebnisreihenfolge, ErrorRecord-Kategorie,
Deadline, Schutz fremder Jobs, gemeinsame Anzeige und unterdrueckte rohe
Gast-ProgressRecords. `Invoke-HyperVGuestProgressChecks.ps1` prueft den
Transportvertrag funktional ohne VM: begrenzte OpenError-Retries, kein
Fallback bei fachlichen oder Ownershipfehlern, temporaeres WinRM-Trust sowie
den gemeinsamen Reporter und die Restdeadline mehrerer Readiness-Probes.
Diese Offline-Pruefungen ersetzen keinen nativen Gast- oder Transfernachweis.
Der vorhandene `Invoke-HyperVCliAcceptance.ps1` prueft den Gastpfad mit einem
eigenen Windows-/SQL-Run aus einer registrierten OS-Baseline. Er verwendet die
gemeinsame Runtime-Sperre, verlangt fuer seine 6144-MB-VM mindestens 7373 MB
freien RAM, vier logische CPUs und 40 GB am registrierten Ressourcenroot.
SQL-Medien muessen bereits hashregistriert sein. Fehlgeschlagenes Cleanup
bewahrt den Test-State; temporaere Testdateien werden nur innerhalb des
validierten eigenen Temp-Roots entfernt.

`Tests/Static/Invoke-ContainerTransferProgressChecks.ps1` prueft den BACPAC-
Reporter und die Fehlerpfade fuer Teilkopie, Import und Cleanup einschliesslich
nativer Ausnahmen. Eine zufaellige eigene Containerdatei bleibt das einzige
Cleanupziel; Versions- und Ownershipfehler verhindern die Mutation.
Die vorhandenen `Invoke-ContainerToolAcceptance.ps1`,
`Invoke-ContainerDatabasePackageExportAcceptance.ps1` und
`Invoke-RestoreSmokeTest.ps1` liefern die getrennten nativen Provider-Nachweise.
Am 2026-09-10 bestanden 17 betroffene statische Suites. Der Gegenbeweis mit der
alten BACPAC-Cleanup-Reihenfolge scheiterte gezielt bei der Teilkopie.
Der Paketexport bestand getrennt auf Docker und Podman mit vollstaendiger
Hashpruefung, Offline-Postcondition und Run-Cleanup. Beide Provider bestanden
zusaetzlich SqlPackage-Version, Restart, BACPAC-Inhalt, Attach-Inhalt und
Attach-Recovery samt Entfernung des Test-Runs und seines Images. Der Schutz
vor vorhandenen Images bindet das exakte geplante Ziel; andere Tool-Images
bleiben mit derselben Tag-/Image-ID-Bindung erhalten. Docker belegt diesen
Gegenfall nativ. Auch die Restore-Smokes bestanden getrennt auf Docker und
Podman mit vollstaendigem Run-Cleanup.
Beide Acceptance-Skripte koordinieren sich mit der Runtime-Sperre, pruefen
Ressourcen und bewahren bei fehlgeschlagenem Cleanup den Recovery-State.

`Tests/Static/Invoke-SessionTransferProgressChecks.ps1` prueft echte asynchrone
PowerShell-Pipelines mit langsamer synthetischer Arbeit, Ausgabeobjekten,
Fehlerkategorien, Deadline und Reporter-Cleanup. Rohe ProgressRecords werden
unterdrueckt. Dieser Offline-Lauf belegt noch keinen echten PSSession-Transfer.

`Tests/Static/Invoke-SqlActionProgressChecks.ps1` prueft Query- und Skript-
Argumente, gemeinsame GO-Verbindung, Statement-/Prozessdeadline, SQL-Exitcode,
Fehlerschwere sowie Cleanup temporaerer Ein- und Ergebnisdateien. Die Ausgabe
verwendet den Unicode-Dateivertrag von
[sqlcmd](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility).
`Tests/Integration/Invoke-SqlActionProgressAcceptance.ps1 -Provider docker|podman`
prueft getrennt an einem eigenen SQL-2025-Run einen langsamen Query-Heartbeat,
geheimnisfreie Anzeige, Unicode, SQL-Fehler, GO-Sessionbindung, Statement-Timeout
und vollstaendigen Run-Cleanup. Ein Lauf ist kein Nachweis fuer den anderen
Provider oder fuer Hyper-V.
Am 2026-09-10 bestanden Docker und Podman jeweils alle acht SQL-Progress-
Assertions samt Run-Cleanup. Der Timeout-Gegenbeweis verwendet eine zwanzig-
sekündige synthetische Wartephase mit einem einsekündigen Statement-Timeout.
Der lokale ODBC-Client lieferte dabei `Timeout expired` bei Exitcode null;
die gemeinsame Fehlererkennung behandelt diesen Fall jetzt als Fehler.
Die anschliessenden SQL-2025-Lifecycle-Smokes bestanden auf beiden Providern
34/34 Pruefungen. Auch `Invoke-RestoreSmokeTest.ps1` bestand getrennt fuer Docker
und Podman mit identischen synthetischen Daten und vollstaendigem Cleanup.
Der Restore-Test validiert seinen temporaeren Cleanup-Root und bewahrt bei
fehlgeschlagenem Provider-Cleanup den State fuer Recovery.

`Tests/Static/Invoke-ArchiveProgressChecks.ps1` prueft ZIP-Byteintegritaet,
Zeitstempel, Zwischenmeldungen, bestehende Ziele, Teilfehler-Cleanup sowie
einen gemeinsamen Reporter fuer Datei- und native Archivschritte.
`Invoke-SampleHandlerChecks.ps1` deckt weiterhin Katalog- und Pfadgrenzen ab.
`Tests/Integration/Invoke-ArchiveProgressAcceptance.ps1` verwendet eine bereits
installierte 7-Zip-Kommandozeile und ein eigenes synthetisches Archiv. Der
Lauf am 2026-09-10 bestaetigte Backup- und Attach-Bytes sowie Fehler-Cleanup;
er benoetigt weder SQL noch Container oder VM und installiert kein Werkzeug.

`Tests/Static/Invoke-TransferProgressChecks.ps1` prueft Kopieren und SHA-256
mit synthetischen Dateien: mehrere Bloecke und Restbytes, Zeitstempel,
gemessene Zwischenwerte, leere Datei, Teilfehler mit erhaltenem Altziel,
Wiederholung und Hardlink-Schutz. Die drei betroffenen Hyper-V-Dateisuites
pruefen die Registry- und Migrationsvertraege ohne VM-Mutation. Diese
Pruefungen ersetzen keinen VHDX- oder Hyper-V-Lifecycle-Nachweis.

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
```

### Docker-Smoke-Test

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
```

### Podman-Smoke-Test

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

### SQL Server 2022 External Languages

Der Gast-Runner erzeugt einen isolierten, SHA-256-gebundenen
Ubuntu-22.04-/cgroup-v1-Hyper-V-Gast und führt Docker und Podman getrennt aus:

```powershell
.\Tests\Integration\Invoke-ExternalRuntimeContainerHyperVHost.ps1
```

In einem bereits geeigneten rootful Linux-/cgroup-v1-Gast können die Provider
auch einzeln geprüft werden. `EvidencePath` liegt außerhalb des Repositorys:

```powershell
.\Tests\Integration\Invoke-ExternalRuntimeContainerAcceptance.ps1 -Provider docker -EvidencePath <path>
.\Tests\Integration\Invoke-ExternalRuntimeContainerAcceptance.ps1 -Provider podman -EvidencePath <path>
```

Beide Läufe prüfen Python, R und Java über echte SQL-Datenroundtrips, einen
additiven Refresh, eigentumsgebundenes Java-Removal, SQL-/Artefaktpersistenz,
Python-/R-Probes nach providergebundenem Neustart sowie den registrierten und
expliziten Cleanup. Docker-Evidence gilt nicht für Podman und umgekehrt.

### Hyper-V External-Runtime-Reconcile

Der additive öffentliche SQL-2022-Windows-/Hyper-V-Reconcile-Vertrag wird
fokussiert ohne Hostmutation geprüft:

```powershell
.\Tests\Static\Invoke-HyperVExternalRuntimeReconcileChecks.ps1
```

Die Suite deckt providergebundenes Routing, Plan/`WhatIf`, Journal vor der
Mutation, No-op, Failure/Resume, PlanKey-Postconditions und die fail-closed
Removal-Grenze ab. Der bestehende native Hyper-V-Acceptance-Aufbau kann den
öffentlichen Reconcile-Pfad in einer erhöhten Sitzung isoliert ausführen:

```powershell
.\Tests\Integration\Invoke-HyperVExternalRuntimeReconcileAcceptance.ps1 -CleanupOnSuccess
```

Der Runner persistiert zuerst einen softwarefreien Desired State und prüft dann
Plan, `WhatIf`, Apply, No-op, Removal-Blockade, ausbleibenden VM-Neustart,
echte SQL-Datenroundtrips und Cold Start. Der Runnervertrag ist statisch geprüft;
die öffentliche Reconcile-Sequenz bleibt bis zu einem tatsächlich erfolgreichen
Lauf `NOT_EXECUTED`.

### Auto-Modus

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
```

Der Auto-Modus wählt für den mutierenden Lifecycle genau eine Runtime: Docker vor Podman. Er ist kein Ersatz für zwei getrennte Providerläufe.

### Vertiefte CLI-Akzeptanz

```powershell
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider docker -Version 2022-CU18
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider podman -Version 2022-CU18
.\Tests\Integration\Invoke-HyperVCliAcceptance.ps1 -MediaRoot D:\Lab_Base -SqlVersion 2025
.\Tests\Integration\Invoke-HyperVStorageAcceptance.ps1 `
    -StorageIntentPath .\Schemas\hyperv-storage-n5-intent.sample.json `
    -MediaRoot D:\Lab_Base
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVSampleManifestAcceptance.ps1 `
    -ArtifactId 'hyperv-sql-prepared-sealed-<sha256>'
.\Tests\Integration\Invoke-HyperVPersistentDataDriveAcceptance.ps1
```

Der letzte Runner benötigt keinen Windows-Gast und belegt mit kleinen,
test-eigenen Ressourcen den nativen Host-Lifecycle einer persistenten VHDX:
unveränderte Quelle, eigenständiger Clone mit neuem DiskIdentifier, Reattach an
eine ausgeschaltete Generation-2-VM, Release, operationsgebundene Leases sowie
atomare Katalogcommits und vollständiger Cleanup. Er
behauptet ausdrücklich keinen SQL-/Gast- oder Datenbank-Onlinenachweis.

Fehlt auf dem Host ein dauerhaft veröffentlichtes SQL-2025-Prepared-Artifact,
kann der vollständige Nachweis stattdessen dessen isolierten N4-Bootstrap
verwenden:

```powershell
.\Tests\Integration\Invoke-HyperVStorageAcceptanceBootstrap.ps1 `
    -StorageIntentPath .\Schemas\hyperv-storage-n5-intent.sample.json `
    -MediaRoot D:\Lab_Base
```

Der Bootstrap behält den testlokalen N4-State nur nach vollständigem Erfolg
bis zur Übergabe an N5, übergibt Artifact-ID und State-Root maschinenlesbar und
entfernt anschließend zuerst den exakten terminalen Build-State und danach das
isolierte Prepared-Image über die produktive Image-Registry. Beide
Abwesenheits-Postconditions werden geprüft. Bei einem Fehler bleiben State und
Artifact mit `RECOVERY_REQUIRED` für eine sichere Diagnose erhalten. Der
Standardlauf der N4-Abnahme behält weiterhin nichts zurück.

Für den nativen Testdatenbank-Reconcile prüft ein eigener erhöhter Runner den
öffentlichen Plan-/Action-Vertrag mit einer fremden Schutzdatenbank. Er verlangt
ein verifiziertes SQL-2025-Prepared-Artifact und beweist `WhatIf`, Addition,
No-op, eigentumsgebundene Entfernung, erneuten No-op, VM-Restart und
scopegebundenen Cleanup. Derselbe isolierte Lauf erzeugt in einem ausschließlich
prozesslokal gebundenen Testdaten-Root eine hashverifizierte
`LAB_GENERATED`-Baseline, entfernt das Sample, installiert es nachweislich über
den Baseline-Eintrag im Manifest-Lock erneut und entfernt es abschließend wieder
eigentumsgebunden. Ohne dauerhaftes Artifact erzeugt der Wrapper einen
isolierten N4-Stand und entfernt ihn nur nach vollständig grünem Ergebnis:

```powershell
.\Tests\Integration\Invoke-HyperVTestDatabaseReconcileAcceptanceBootstrap.ps1 `
    -MediaRoot D:\Lab_Base
```

Der erweiterte Runner ist implementiert und statisch gebunden. Der erhöhte
Native-Wiederholungslauf vom 2026-09-12 bestätigte Addition, Journal,
Baseline-Wiederverwendung, VM-Neustart, stabile Host-SQL-Readiness und den
vollständigen scopegebundenen Cleanup. Die Readiness nach dem Neustart wurde
nach 94,2 Sekunden stabil bestätigt.

Es werden bewusst nicht alle CUs getestet. Docker und Podman verwenden je
einen repraesentativen katalogisierten CU; Windows prueft die frische
Basisinstallation und verwendet ein CU nur bei vorhandenem verifiziertem Paket.
Der empfohlene operative Push-Pfad ist in der lokalen Readiness-Checkliste beschrieben:

```text
.\Documentation\Quality\LOCAL_READINESS_CHECKLIST.md
```

`Invoke-HyperVStorageAcceptance.ps1` ist der getrennte N5-Vertrag für vier
TempDB-Datendateien auf mindestens zwei beziehungsweise der im Intent
geforderten höheren Zahl physischer Geräte, separates TempDB-Log, SQL-Dienstrestart,
dateigenaues CREATE und Restore sowie VM-Restart und Cleanup. Der Runner bleibt
`NOT_EXECUTED`, solange der Host nicht mindestens die im Intent geforderten
physischen Geräte mit eindeutig selektierbaren Storage-Locations und ein passendes `SQL_PREPARED_SEALED`-
Artifact bereitstellt.

Der Referenzlauf wurde am 2026-08-31 nach Einführung der gebundenen Hyper-V-
Ressourcenroots mit drei von drei geforderten physischen Geräten erneut
ausgeführt. Builder-VHDX, Published Image und N5-Lanes wurden über ihre
persistierten Bindungen aufgelöst; SQL-Restart, Create, Backup/Restore,
VM-Restart und Cleanup waren erfolgreich. Die unabhängigen Nachprüfungen fanden
kein Test-Artifact, keinen isolierten State und keine seit Laufbeginn erzeugte
VHDX an den registrierten Locations.

### Reale Windows-Generalize-/Publish-Abnahme

Auf einem Hyper-V-Host mit freigegebenem Windows-Server-2025-Eval-ISO prüft
dieser Runner eine frische unbeaufsichtigte Installation auf einer neuen VHDX,
den produktiven PowerShell-Direct-Generalize-Receipt, die testlokale immutable
Publikation und den garantierten Cleanup. Eine vorhandene `OS_SEALED`-Artifact-
ID liefert ausschließlich die freigegebenen OS-/Lizenzmetadaten; ihre VHDX wird
nicht als Generalize-Quelle wiederverwendet.

```powershell
.\Tests\Integration\Invoke-HyperVWindowsGeneralizeAcceptance.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

### Reale SQL-Prepared-Image-Abnahme

Dieser erhöhte Windows-Runner verifiziert Windows-Server-2025- und SQL-Server-
2025-Medien samt SHA-256-Sidecars, installiert Windows unbeaufsichtigt auf
einer neuen VHDX und führt den produktiven SQL-`PrepareImage`-/finalen-
Sysprep-/Publish-Pfad aus. Das resultierende testlokale
`SQL_PREPARED_SEALED`-Artifact wird danach über den normalen Manifestpfad als
differenzierende VM geklont. Der Runner prüft Windows-Specialization,
`CompleteImage`, WMI, TCP/IP-Hostzugriff und `SQL_READY_RUN` mit Major-Version
und vier Online-Systemdatenbanken. Abschließend belegt er den unveränderten
Parent-Hash sowie den scopegebundenen Cleanup von Builder- und Manifestlauf.
Die Builder-VHDX wird dabei nicht aus dem State-Verzeichnis zusammengesetzt,
sondern aus `resourceRelativePath` und dem persistierten `Build`-Binding erneut
aufgelöst.

```powershell
.\Tests\Integration\Invoke-HyperVSqlPreparedImageAcceptance.ps1
```

Dieser Nachweis schließt den Windows-2025-/SQL-2025-Prepared-Image-Referenzpfad
vom frischen Build bis zum bereinigten Manifestklon. Weitere Windows-/SQL-
Kombinationen und die breite Datenbank-, Software-, Post-Provisioning- und
Network-Manifestbindung benötigen weiterhin eigene Nachweise.

Der Lauf vom 2026-09-10 auf `63e272d` erreichte die Publikation, scheiterte dort
aber an fehlenden Plattformmetadaten des Fresh-Plans (`VmGeneration=0`).
VM und beide Testdatentraeger wurden entfernt und ihre Abwesenheit geprueft.
`Invoke-HyperVSqlImageBuilderChecks.ps1` reproduziert diesen Vertragsfehler
mit einem echten Fresh-Plan und Registry-Import einer synthetischen VHDX.
Nach der Korrektur bestehen 50 fokussierte Pruefungen einschliesslich
fruehem Blockieren eines alten States ohne Plattform. Der erhöhte Lauf auf
`d07d3f02` erreichte danach frische Windows-2025-OOBE, PowerShell Direct,
SQL-2025-PrepareImage, Generalize, immutable Publish und den differenzierenden
Manifestklon. Die nachgelagerte Aktivierung brach mit
`WINDOWS_ACTIVATION_EXISTING_EGRESS_UNAVAILABLE` ab; ihre VM, Child-VHDX und
IPAM-Lease wurden vollständig entfernt. Der fehlgeschlagene Test hatte einen
erfolgreichen SQL-Build-State als Artifact-Referenz hinterlassen; dessen
bereinigter Fehlerpfad entfernt zuerst genau diesen Build und danach nur das
eigene Artifact. Der Folgelauf auf `386d9159` deklariert für den bewusst
isolierten Klon explizit `EvaluationOnline`/`AllowTemporary`: Er bestand vom
frischen Windows-Server-2025-/SQL-Server-2025-Build über `PrepareImage`,
Generalize, immutable Publish, Manifestklon, echte Evaluationsaktivierung und
`SQL_READY_RUN` bis zum Parent-Hash-/Schreibschutz- und vollständigen Cleanup-
Nachweis. Der temporäre Adapter wurde nach der Aktivierung entfernt; State- und
Builder-Root, VM, Child-VHDX sowie IPAM-Lease waren anschließend abwesend.
Die übrigen SQL-Konfigurations-, Port-, Testdatenbank- und External-Runtime-
Reconcile-Slices bleiben getrennt offen.

### Reale Legacy-Run-/Parent-Child-Migration

Der erhöhte HVR-008-Runner verlangt eine exakte Run-ID, den erwarteten VM-Namen,
einen getrennten Legacy-StateRoot und einen registrierten Ziel-DataRoot. Er
veröffentlicht das Parent-Image hashgebunden, migriert und reparentet die
run-eigene VHDX, verschiebt VM-Konfiguration, Paging und Snapshots, belegt zwei
Gaststarts und entfernt die verifizierte Quelle erst nach den abschließenden
Binding-, VHDX-, Parent- und Attachment-Postconditions. Ein nichtterminales
Journal wird aus demselben Plan fortgesetzt. Für einen ursprünglich laufenden
Legacy-SQL-Run validiert `-RequireSqlReadiness` die erwartete SQL-Hauptversion
und beide Restart-Receipts. `-AdoptLegacySqlIdentity` übernimmt fehlende
aktuelle VM-Identität nur aus persistierter abgeschlossener Windows-
Provisionierung und einem erfolgreichen Live-SQL-Probe. Vor dem VHDX-Hashplan
wird der Gast geordnet heruntergefahren; ein Fehler vor Journalbeginn stellt
den laufenden Zustand samt Readiness wieder her. Nach erfolgreicher Migration
wird der ursprüngliche laufende Zustand ebenfalls mit Gast- und SQL-Readiness
wiederhergestellt.

```powershell
.\Tests\Integration\Invoke-HyperVResourceMigrationAcceptance.ps1 `
    -RunId '<run-guid>' -ExpectedVMName '<vm-name>' `
    -LegacyStateRoot '<legacy-state-root>' -DataRoot '<registered-lab-data-root>' `
    -EvidencePath '<path-outside-repository>' -Confirm:$false
```

Ein SQL-gebundener, ursprünglich laufender Kandidat ergänzt:

```powershell
-ExpectedInitialVMState Running -RequireSqlReadiness `
    -ExpectedSqlMajorVersion <major> -AdoptLegacySqlIdentity
```

Diese Parameter und ihre statischen Verträge sind implementiert; ein positiver
realer SQL-Legacy-Migrationslauf bleibt bis zur tatsächlichen Ausführung
`NOT_EXECUTED`.

Die allgemeine `Lab_Data`-Parent-Migration besitzt zusätzlich einen
fail-closed Sicherheitsvertrag: Erkennt der Plan VM-Konfiguration, Snapshots
oder Smart Paging unter dem später zu entfernenden Quellroot, bindet er exakte
VM-, Quell- und Zielidentität. Apply revalidiert den ausgeschalteten Zustand,
journalisiert `Move-VMStorage` als `PENDING`, verlangt exakte Ziel-
Postconditions und überspringt die Mutation bei einem Resume nach bereits
erfolgter Umbindung. Der fokussierte synthetische Nachweis liegt in
`Invoke-StorageMigrationChecks.ps1`. Der reale Runner verlangt die exakte ID
einer kleinen, nicht als Default verwendeten Location ohne Run-, Attachment-,
Binding- oder vorhandene VM-Konfigurationsreferenz:

```powershell
.\Tests\Integration\Invoke-HyperVStorageParentMigrationAcceptance.ps1 `
    -SourceLocationId '<non-default-location-guid>'
```

Er erstellt eine ausgeschaltete Generation-2-Test-VM mit eigener VHDX,
migriert den vollständigen Location-Root auf demselben Volume zu einem
temporären Parent und anschließend zurück. Geprüft werden Configuration,
Snapshot, Smart Paging, VHDX, `LocationId`, unveränderte Quelldateien und der
vollständige scopegebundene Cleanup. Dieser real erhöhte Lauf ist bestanden.
Bei einem Fehler bleiben Test-VM, aktueller Root und Journale als
`RECOVERY_REQUIRED` für eine sichere Fortsetzung erhalten.

## 3. Voraussetzungen

### Statische Prüfung

- PowerShell 7.2 oder neuer;
- lokaler Repository-Checkout;
- keine laufende Container-Runtime erforderlich.

### Integration-Smoke-Test

- PowerShell 7.2 oder neuer;
- Docker oder Podman installiert und erreichbar;
- `sqlcmd` installiert;
- Zugriff auf das ausgewählte SQL-Server-Container-Image;
- ausreichend RAM und Storage;
- ein freier Port im Lab-Bereich.

Ein fehlender Provider oder ein fehlendes `sqlcmd` ist kein bestandener Test. Der Test bricht mit einem nachvollziehbaren Fehler ab.

Für lokale Full-Readiness sind zusätzlich relevant:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

## 4. Statische Vertragsprüfung

`Tests/Static/Invoke-DocumentationChecks.ps1` prüft derzeit:

### PowerShell

- Syntax aller aktiven `.ps1`, `.psm1` und `.psd1` außerhalb von `_QuellRepo/` und `private_Note/`;
- Lesbarkeit des Modulmanifests;
- eindeutige `FunctionsToExport`;
- Entfernen nicht implementierter Exportplatzhalter;
- Modulimport, sofern nicht ausdrücklich mit `-SkipModuleImport` übersprungen;
- Übereinstimmung von Exportliste und tatsächlich exportierten Funktionen.

### JSON und Schemas

- JSON-Syntax unter `Catalogs/` und `Schemas/`;
- Existenz relativer `$schema`- und `$ref`-Ziele;
- Existenz der zentralen Katalogschemas;
- grundlegende Provider-Metadaten;
- Existenz der in `provider.json` angegebenen Implementierungsdatei.

Die Prüfung validiert noch nicht jedes JSON-Dokument semantisch vollständig gegen Draft-07. Das bleibt eine benannte Lücke.

### Dokumentation

- Existenz der Front-Door- und Governance-Dateien;
- relative Links in den zentralen Dokumenten;
- Ausschluss des veralteten Rootstatus `PLANNING_FOUNDATION`;
- Ausschluss individueller Entwicklerpfade aus Getting Started;
- Ausschluss der nicht implementierten Environment Variable `SQL_SERVER_LAB_PATH` als Bedienvertrag;
- Ausschluss veralteter Restore-Beispiele mit `-RunId` oder `-BackupUrl`;
- korrekte Beschreibung des Smoke-Test-Auto-Modus;
- Existenz referenzierter `postProvision`-Dateien in Beispielmanifesten.

### Grenzen

Die statische Prüfung ersetzt nicht:

- tatsächlichen Containerstart;
- SQL-Bereitschaft;
- Restore einer realen zulässigen `.bak`-Datei;
- Providerparität;
- Performance- oder Fault-Szenarien;
- vollständige Privacy- oder Secret-Erkennung aller denkbaren Inhalte.

## 5. Integration-Smoke-Test

`Tests/Integration/Invoke-SmokeTest.ps1` prüft für den ausgewählten Provider:

1. Modulimport;
2. Erkennung implementierter Provider über `provider.json` und vorhandene Implementierungsdatei;
3. Runtime-Erreichbarkeit;
4. Resource Assessment;
5. Provisionierung einer SQL-Server-Instanz;
6. Rückgabe von RunId, Provider und Port;
7. Sichtbarkeit des Containers in der ausgewählten Runtime;
8. Erstellung einer Datenbank mit mehreren Data-Files;
9. Verifikation über `sys.databases`;
10. Ausführung eines T-SQL-Skripts mit mehreren `GO`-Batches;
11. Datenverifikation;
12. `Get-SqlServerLab`;
13. `Stop-SqlServerLab`;
14. providergetreue Containerstatusprüfung;
15. `Start-SqlServerLab`;
16. `Remove-SqlServerLab`;
17. Verifikation, dass der Container entfernt wurde;
18. Cleanup bei Testfehlern, sofern `-KeepOnFailure` nicht gesetzt ist.

Der Test erzeugt ausschließlich synthetische Testobjekte.

Der dedizierte Batch-/Queue-Smoke prüft zusätzlich die reale Provisionierung
zweier Container-Labs über persistente Operationen, zwei Scheduler-Worker,
idempotentes Resume und scopegebundenen Cleanup:

```powershell
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker -AbortSchedulerOnce
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider docker -ManifestRerun
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-BatchWorkflowSmokeTest.ps1 `
    -Provider hyperv `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
.\Tests\Integration\Invoke-BatchUserGateAcceptance.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>'
```

Die statische Batch-Workflow-Prüfung hält zusätzlich die zustandsrootgebundene
Workflow-Sperre in einem eigenen PowerShell-Kindprozess. Sie verlangt, dass
eine Batch-Zusammenfassung bis zur Freigabe wartet und danach erfolgreich
abschließt. Zwei parallele Zusammenfassungen müssen anschließend denselben
vollständigen Batchzustand mit allen terminalen Operationen erhalten. Dieser
synthetische Nachweis belegt die lokale Dateisynchronisation, nicht die
Provider-Provisionierung oder extern verursachte Dateisperren.

Die getrennten nativen Batch-Referenzläufe vom 2026-09-21 bestanden mit dem
unveränderten Runtime-Commit `85dcd126`: Docker und Podman meldeten jeweils
zwölf Assertions sowie `CLEANUP_SUCCEEDED` mit zwei Schritten und null Fehlern.
Sie belegen keine externen ACL- oder fremden Reader-Sperren.

Container-Batchpositionen müssen dazu in `defaults`, `intent`, `manifest` oder
`overrides` das Feld `SaPasswordEnvironmentVariable` mit dem Namen einer
`SQL_SERVER_LAB_SECRET_*`-Prozessvariable referenzieren. Der Wert wird erst im
Worker gelesen und nicht im Workflow-State persistiert.

`-AbortSchedulerOnce` startet den Scheduler in einem separaten Prozess, wartet
auf eine reale operationseigene Providerressource, beendet den Prozess hart und
prüft anschließend `WorkerRecovered`, eindeutiges Operation-zu-Run-Eigentum,
idempotentes Resume und vollständigen scopegebundenen Cleanup.

`-ManifestRerun` prüft, dass eine zweite offene Einreichung desselben Manifests
denselben Batch und dieselben Operationen zurückgibt. Nach Abschluss und Cleanup
erzeugt dasselbe Manifest einen neuen Batch mit neuen RunIds, bleibt beim
Scheduler-Rerun idempotent und wird erneut vollständig bereinigt.

`Invoke-BatchUserGateAcceptance.ps1` benötigt für den testlokalen Offline-Mount
des operationseigenen Child-VHDX eine erhöhte Sitzung. Das immutable Parent
bleibt read-only. Der Test bindet auf einer realen Windows-VM den reinen
`CandidateSatisfied`-Probe ohne Step-/Receipt-Fortschritt, die fail-closed
Bestätigung, echte PowerShell-Direct-Credential-Verifikation, genau ein
`UserGateConfirmed`-Receipt sowie vollständigen VM-, Child-VHDX- und
State-Cleanup. Ein unverändert grüner Realnachweis wird nicht ohne neue Evidence
wiederholt.

Der diagnostische Konsolen-Fallback wird im selben PowerShell-7-Terminal
gestartet:

```powershell
.\Invoke-SqlServerLab.ps1 -ConsoleMode Fallback
```

Die reale Konsolenabnahme prüft getrennt: `0` beendet den Fallback mit Exitcode
0; `Ctrl+C` beendet Cursor- und Fallback-Verarbeitung mit einem Prozessabbruch,
ohne Ergebnis-/Fortsetzungsmarker und ohne Wechsel vom Cursor in den Fallback.
Die statische Ergänzung ist `Invoke-ConsoleUiChecks.ps1`; simulierte Keys allein
ersetzen den PTY-Nachweis nicht.

## 6. Provider-Abnahme

| Fähigkeit | Docker | Podman | Hyper-V |
|---|---:|---:|---:|
| Resource Assessment | implementiert | implementiert | Lifecycle-Verfügbarkeit implementiert |
| sealed Image-Registry | nicht zutreffend | nicht zutreffend | Import, Integrity, Auswahl und Run Lock implementiert |
| einzelne SQL-Instanz | implementiert | implementiert | Windows-2025-/SQL-2025-Manifestklon aus `SQL_PREPARED_SEALED` real validiert; breite Manifestbindung partiell |
| Health und SQL Readiness | implementiert | implementiert | OS-Slot-Installation und Host-SQL-Readiness implementiert |
| Datenbankerstellung | implementiert | implementiert | mit absoluten Windows-Pfaden implementiert |
| T-SQL-Skriptausführung | implementiert | implementiert | ueber Host-SQL-Zugriff implementiert |
| Live-Status | implementiert | implementiert | Lifecycle-Grundlage implementiert |
| Stop und Start | implementiert | implementiert | Lifecycle-Grundlage implementiert |
| Remove | implementiert | implementiert | scopegebundene Grundlage implementiert |
| eigener Smoke-Test-Aufruf | Lifecycle und CLI-Akzeptanz | Lifecycle und CLI-Akzeptanz | Lifecycle, Windows-Baseline und vollstaendige CLI-Akzeptanz |
| gemischter Provider-Run | implementiert mit Podman-ProviderSubRun | implementiert mit Docker-ProviderSubRun | nicht unterstützt |
| SQL-2022-Python/R/Java | nativ validiert auf rootful Linux/cgroup v1 | nativ validiert auf rootful Linux/cgroup v1 | nativ validiert im isolierten Windows-Gast einschließlich VM-Kaltstart |

`implementiert` bedeutet, dass Code und Testpfad vorhanden sind. `validiert` darf nur für einen tatsächlich erfolgreich ausgeführten lokalen Lauf verwendet werden.

## 7. SQL-Server-Versionen

Der Versionskatalog enthält derzeit SQL Server 2019, 2022 und 2025 sowie ausgewählte CU-Buildmetadaten.

Der Smoke-Test kann eine Version oder einen katalogisierten CU-Kurzbezeichner erhalten:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2019'
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2022'
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2025'
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker -Version '2022-CU16'
```

`Invoke-SmokeMatrix.ps1` ist der übergeordnete Provider-Testeinstieg und prüft
pro erreichbarem Provider SQL Server 2025. `-IncludeParallel` verwendet
ebenfalls ausschließlich diese Referenzversion. Die reale Mehrversions-
Kompatibilität für 2019/2022/2025 wird in SQL Analyze und Toolbelt geprüft,
weil dort die versionsabhängigen Partnerworkflows liegen. Einzelne Nachweise
bleiben getrennt zu dokumentieren, wenn ein Provider nicht verfügbar ist.

Ein Katalogeintrag oder vorhandener Testparameter beweist nicht, dass ein Image weiterhin verfügbar oder der Katalog aktuell ist.

## 8. Restore-Validierung

Der allgemeine Smoke-Test prüft derzeit keinen Download und keinen Restore einer öffentlichen Sample-Datenbank, um Laufzeit, Netzwerkabhängigkeit und Datenmenge klein zu halten.

`Invoke-ArtifactResolverChecks.ps1` ist der deterministische Nachweis für den
lokalen Artifact-Trust-Vertrag: Er simuliert einen einzelnen Download ohne
Katalog-SHA-256, prüft die Erzeugung des lokalen SHA-256-Trust-Records und
fordert anschließend nichtinteraktiv dieselbe Quelle erneut an. Der Folgelauf
muss den hashgeprüften Content-Cache verwenden und darf keinen zweiten Download
auslösen. Der Test benötigt weder Netzwerk noch Container oder SQL Server.
Er registriert außerdem für eine echte ausführbare Katalogvariante ausschließlich
synthetischen lokalen Trust-State und prüft die gemeinsame
Workflow-Projektion auf `user-trusted-generated` mit `CacheStatus: MISS`.
Der öffentliche `Get-SqlServerLabWorkflow` verwendet exakt diesen read-only
Projektionscore. Auch dieser Teil erzeugt keinen Download, keine Freigabe und
keine Provider-Mutation.

`Invoke-BackupLibraryCrossProviderAcceptance.ps1` ist der isolierte PSR-008-
Nachweis: Er erzeugt ein synthetisches Backup in Docker, veröffentlicht es nur
nach `CHECKSUM`, `RESTORE VERIFYONLY`, Host-Hash und Metadatenreceipt, entfernt
die Quelle und restauriert nach Podman ausschließlich per `BackupSetId` und
konfiguriertem `DataRoot`. Die Auswahl prüft Receipt-Status, Verification-
Evidence, Objektpräsenz und SHA-256 erneut. Quelle und Ziel müssen denselben
sanitisierten Inhaltsdigest liefern. Da SQL Server in den verwendeten Linux-
Containern keine FILESTREAM-Evidence liefert, zählt dieser Lauf ausdrücklich
nicht als FILESTREAM-Abnahme. Für `PSR-008` ist das kein offener Testersatz:
FILESTREAM ist laut Microsoft unter SQL Server auf Linux nicht unterstützt,
und die aktuelle Provider-Matrix besitzt daher kein zweites FILESTREAM-fähiges
Cross-Provider-Ziel. Das Kriterium ist `NOT_APPLICABLE` und wird erst bei einer
künftigen Capability-Erweiterung wieder zum verpflichtenden nativen Gate.

`Invoke-PortableContainerTransferPreflightAcceptance.ps1` ist der getrennte
Docker-/Podman-Nachweis für die operationseigene Container-Backup-Staging- und
Medienvorprüfung. Er verwendet zwei isolierte SQL-2025-Runs desselben Providers
und ein synthetisches, zuvor `CHECKSUM`-/`VERIFYONLY`-verifiziertes Backup. Der
Preflight muss `HEADERONLY` und `VERIFYONLY WITH CHECKSUM, STOP_ON_ERROR`
erfolgreich ausführen, die eigene Stage und das Journal vollständig entfernen
und den Transferexecutor weiterhin als `BLOCKED` ausweisen. Ein Restore oder
Transfer ist nicht Bestandteil der Acceptance.

`Invoke-DatabasePackageChecks.ps1` prüft den PSR-009-Core deterministisch mit
einer synthetischen MDF-/NDF-/LDF-Dateimenge und einem verschachtelten
FILESTREAM-Container. Der Test beweist rekursive Hashes, Manipulationsschutz,
unabhängige Clone-Dateien, `COPY_THEN_ATTACH`, Journal/Postcondition sowie die
fail-closed Grenzen für ältere SQL-Ziele, FILESTREAM, TDE, Detach-State und
parallele Writer. Er ist bewusst kein Ersatz für einen nativen Windows-SQL-
FILESTREAM-Attach; dessen Acceptance muss separat in Hyper-V laufen.
Die Suite prüft zusätzlich die pfadfreie CLI-/Browser-Inventur per stabiler
`DatabasePackageId`, aufgeschobenes Voll-Hashing beim Refresh, explizite
Integritätsverifikation, die sanitisierte Projektion persistierter
Migrationskategorien und Warnungen sowie den öffentlichen Hyper-V-WhatIf-/
Attach-Vertrag mit stabiler Run-/Instanzbindung, vorab persistiertem Recovery-
Journal und pfad-/hash-/geheimnisfreiem Ergebnis. Die Projektion führt keine
neue SQL-Abfrage aus. `Invoke-WorkflowUiChecks.ps1` prüft zusätzlich die lokale Browseraktion für
den Container-Paketexport: Der Request enthält ausschließlich Run-ID,
Instanz-ID und validierten Datenbanknamen; Host, Port, Pfad und SA-Passwort
werden nicht übertragen. Die reale Docker-/Podman-Acceptance des öffentlichen
Export-Cores bleibt der getrennte Runtime-Nachweis.
Gemeinsam mit `Invoke-BackupLibraryChecks.ps1` prüft die Suite außerdem den öffentlichen,
einzelobjektgebundenen Bestands-Sync: `-WhatIf` schreibt keine Katalogrevision,
der Apply-Pfad registriert nach vollständiger Artefaktverifikation genau eine
stabile ID und die Wiederholung bleibt ein `NO_CHANGE`.

`Invoke-DatabaseMigrationDependencyChecks.ps1` prüft den PSR-010-Core ohne
Runtime-Mutation: Parser und Schema für read-only SQL-Counts, Server-Login-,
Agent-Job-, Proxy-, Linked-Server- und TDE-Kategorien, die
`NOT_OBSERVABLE`-Grenze für Serverkonfiguration/SSISDB/SSAS, das TDE-Recovery-
Gate, den öffentlichen direkten und Run-/Instanz-gebundenen Aufruf sowie
sanitisierte `DATABASE_FILES_ONLY`-Receipts. Der Receipt enthält zusätzlich den
separat schema-validierten `SqlServerLab.DatabaseMigrationExecutionPlan/1.0`.
Die Suite prüft dessen TDE-Blockierung, kategoriebasierten manuellen/externalen
Review-Schritte sowie `MutationAllowed=false` und `TransferAuthority=NONE`; der
Plan führt keine Export-, Import- oder sonstige Runtime-Mutation aus. Der bestehende
`Invoke-DatabasePackageChecks.ps1` prüft ergänzend, dass neue
`DATABASE_PACKAGE`-Receipts diesen Plan nur geheimnisfrei persistieren, seine
kanonischen Felder in den Paketmanifest-SHA-256 aufnehmen und im pfadfreien
Katalog lediglich Status, Schrittzahl und Blocker anzeigen.
`Invoke-BackupLibraryChecks.ps1` prüft die dazu passende Backup-Binding-
Evidence: Neue Backupsets referenzieren die exakt bei der Veröffentlichung
berechnete Objekt-SHA-256, bewahren alle acht nicht ausführbaren Plan-Schritte
und projizieren nur Status, Schrittzahl und Blocker in die Auswahlansicht.
Der bestehende
`Invoke-WorkflowUiChecks.ps1` prüft zusätzlich die lokale Browserbindung der
Containerinventur: Nur Run-ID, Instanz-ID, validierter Datenbankname und
flüchtiges SA-Passwort erreichen die Workflowaktion; die Ergebnisprojektion
enthält ausschließlich Kategorien, Counts, Grenzen und Review-Schritte. Der
Browser parst nur die versionierte `[INVENTAR]`-Projektion aus dem bestehenden
Live-Log und rendert sie strukturiert, ohne einen weiteren Endpunkt oder
Rohdatenpfad einzuführen. Der
UI-Slice führt keine Runtime-Mutation aus; der bestehende öffentliche PSR-010-
Core und dessen separate Runtime-Evidence bleiben maßgeblich.
`Invoke-BackupLibraryCrossProviderAcceptance.ps1` führt die echte SQL-Abfrage
bei der Docker-Backup-Erstellung aus; dies ist kein Windows-TDE-,
Serverobjekt-Export- oder Hyper-V-FILESTREAM-Nachweis.

`Invoke-AiScenarioChecks.ps1` prüft den AI-00-/AI-10-Vertrag ohne laufenden
SQL Server: Manifest- und Package-Schema, portable Modell-/Szenario-PlanKeys,
Dataset- und Skript-SHA-256, pfadfreie öffentliche Projektion, persistierte
Intentbindung, Docker-/Podman-Capability, mutationsfreies `WhatIf`, verweigerten
Cloud-Egress und Traversal-Schutz. Dieser statische Lauf ist kein Nachweis,
dass `VECTOR`, `VECTOR_DISTANCE` oder `AI_GENERATE_CHUNKS` im Container
erfolgreich ausgeführt wurden. Der native Nachweis verwendet einen zuvor per
KI-Manifest erstellten SQL-2025-Run und anschließend
`Invoke-SqlServerLabAiScenario`; Docker und Podman sind getrennt auszuführen.
Der ausführbare, run-eigene Nachweis dafür ist
`Tests/Integration/Invoke-AiVectorCoreAcceptance.ps1 -Provider docker|podman`.
Er prüft Vector-Distanz, Chunking, sanitisierte Evidence und Szenario-Cleanup
und entfernt danach den zugehörigen Provider-Run.

Der separate Preview-Vektorindex-Nachweis verwendet SQL Server 2025 und
aktiviert `PREVIEW_FEATURES` vor dem Kompilieren der Index-Fixture:

```powershell
.\Tests\Integration\Invoke-AiVectorIndexAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiVectorIndexAcceptance.ps1 -Provider podman
```

Abnahmeversion 1.0 erstellt 4.096 synthetische Vektoren mit 32 Dimensionen und
einen echten DiskANN-Index. Vier Suchfälle prüfen Top-10, Selbsttreffer,
Distanzgleichheit, Recall@10 mindestens 0,8 und Postfilter; der aktuell
nachgezogene Lauf liefert `MinimumRecallAt10=1,0` vor und nach Restart auf
`Compatibility Level 170` sowie `CLEANUP_SUCCEEDED`. Nach öffentlichem
Stop/Start werden dieselben Assertions wiederholt. Jeder Lauf besitzt einen
eigenen State-/Datenbank-/Provider-Scope; Cleanup läuft auch nach Fehlern.
Nur erfolgreiches Cleanup erlaubt `PASS`. Ergebnisse enthalten SQL-Build,
Indexformat, rohe SHA-256 der tatsächlich ausgeführten Fixturedateien und
Messwerte. Die SQL-Uhr kann bei kurzen Abfragen 0 Mikrosekunden Differenz
liefern; daraus folgt keine Performancezusage.

Am 2026-09-10 bestanden Docker und Podman auf Revision
`6fc518847eaefb021c31666ca8386da5b53e1908`, SQL-Build `17.0.4075.5`,
jeweils mit Recall@10 1,0 vor und nach Neustart und Cleanup `PASS`.
Die beobachteten Indexmetadaten enthalten kein numerisches Versionsfeld:
`sql2025-unversioned` benennt diese Form ohne erfundene Hersteller-Version.
Abweichende spätere Metadaten oder Suchsemantik verlangen eine angepasste
beziehungsweise eigene Abnahmeversion. Preview allein blockiert keine Abnahme.
Hyper-V, DML-Aktualisierung, Backup/Restore und größere Lasttests sind dadurch
nicht abgenommen; der exakte Vector-Core bleibt ein eigener Nachweis.

Der modell- und SQL-freie HTTPS-Nachweis des Endpointvertrags läuft separat:

```powershell
.\Tests\Integration\Invoke-AiHttpsEndpointStubAcceptance.ps1
```

Er bindet einen flüchtigen IPv4-Loopback-TLS-Server mit exakt gepinntem
öffentlichem Zertifikat über Custom-Root-Trust an den normalen `HttpClient`.
Geprüft werden Embed- und Generate-Payload, ein echter HTTP-429-Retry sowie die
Ablehnung eines abweichenden Pins. Der Test verändert keinen globalen
Zertifikatspeicher, benötigt keine Modellruntime und räumt Prozess,
Zertifikatobjekte und temporäre Dateien vollständig auf.

Der vollständige lokale RAG-Nachweis wird ebenfalls providergetrennt ausgeführt:

```powershell
.\Tests\Integration\Invoke-AiRagContainerAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiRagContainerAcceptance.ps1 -Provider podman
```

Jeder Lauf verbindet katalogisierte Ollama-Embeddings und -Generierung mit
echter exakter SQL-2025-Cosine-Suche, prüft die erwartete Top-Quelle, startet
SQL und Ollama neu und entfernt Run, Container und Volumes vollständig.

Der read-only Agent besitzt einen eigenen nativen Provider-Nachweis:

```powershell
.\Tests\Integration\Invoke-AiDiagnosticAgentContainerAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiDiagnosticAgentContainerAcceptance.ps1 -Provider podman
```

Geprüft werden feste SELECT-Werkzeuge, echte Least-Privilege-Sichtrechte,
lokale Generierung, inhaltsfreies Journal, vollständiger Login-Cleanup und ein
erneuter Lauf nach Ollama-Restart.

Der vorbereitete Hyper-V-Paritätsnachweis bindet einen bereits verwalteten
SQL-2025-Run an einen scopegebundenen lokalen Ollama-Container:

```powershell
.\Tests\Integration\Invoke-AiHyperVAcceptance.ps1 `
    -RunId '<laufender-verwalteter-hyperv-sql-2025-run>' `
    -SaPassword $password `
    -OllamaProvider docker
```

Er prüft RAG, den read-only Agenten, Login-Cleanup und einen erneuten Lauf nach
VM- und Ollama-Neustart, entfernt aber niemals den übergebenen Hyper-V-Run.
Am 2026-09-07 wurden RAG, Agent, Login-Cleanup und Ollama-Restart gegen einen
echten verwalteten Hyper-V-SQL-2025-Run erfolgreich ausgeführt. Der Run gehört
zur geschützten automatischen Testgruppe; deren Einzelneustart wurde daher
korrekt abgelehnt und nicht umgangen. Das Ergebnis bleibt `PARTIAL`, bis ein
isolierter Hyper-V-Run auch den VM-Neustart belegt; vorher wird keine
vollständige Provider-Capability deklariert.

Der ausführbare native Windows-SQL-Nachweis ist:

```powershell
# benötigt ein echtes erhöhtes Windows-Token
.\Tests\Integration\Invoke-DatabasePackageSqlAcceptance.ps1
```

Er setzt SQL Server 2025 mit effektivem FILESTREAM voraus und räumt ausschließlich
seine zufällig benannten Datenbanken und `sql-lab-psr009-*`-Wurzeln auf. Ein
nicht erhöhter Prozess endet vor neuer Mutation fail-closed.

Der native Hyper-V-Providernachweis ist:

```powershell
# benötigt Hyper-V-Hostrechte und einen laufenden SQL-2025-Run (alternativ ein Prepared-Artifact)
.\Tests\Integration\Invoke-HyperVDatabasePackageAttachAcceptance.ps1 `
    -RunId '<laufender-verwalteter-sql-2025-run>'
```

Er verwendet mit `-RunId` ressourcenschonend einen laufenden verwalteten
SQL-2025-Run oder erzeugt andernfalls einen isolierten Prepared-Run. Ein
temporärer `Lab_Data`-Root hält alle Paketdaten. Geprüft werden pfadfreie
öffentliche Auswahl, Live-Zielbindung, PowerShell-Direct-Kopie, Gast-Hashes,
Online-/Inhalts-Postcondition, Journal und vollständiger Test-Cleanup.
FILESTREAM bleibt im getrennten lokalen Windows-SQL-Lauf belegt.

Für einen manuellen Restore-Nachweis sind mindestens zu dokumentieren:

- verwendete synthetische oder öffentliche Quelle;
- Lizenz und Klassifikation;
- SQL-Server-Version;
- Provider;
- Dateigröße und gegebenenfalls Prüfsumme;
- Restore-Ergebnis;
- Datenbankverifikation;
- Cleanup-Ergebnis.

Nicht in versionierte Evidence übernehmen:

- lokale Backup-Pfade;
- Passwörter;
- Connection Strings;
- reale Hostwerte;
- vollständige Backup-Metadaten aus nicht öffentlichen Quellen.

## 9. Sample-Katalog-Validierung

`Invoke-ManifestBuilderChecks.ps1` führt zusätzlich die tatsächliche
Validator-/Resolver-Komposition mit isoliertem synthetischem Katalog aus:
Bundle-Zweitoutput gegen explizite Datenbank, Bundle gegen Bundle,
Groß-/Kleinschreibung, disjunkte Outputs, getrennte Instanzen, freigegebene
Zielnamen-Overrides und ungültige Outputlisten. Eine erneute Katalogauflösung
im tatsächlichen `New-SqlServerLab -Manifest` wird vor `New-LabRunState`
bei einer neuen Kollision abgewiesen. Diese Fixtures provisionieren keine
Ressourcen und führen weder Acquisition noch SQL aus.

Die statische Prüfung verifiziert JSON und Schema-Referenzen. Der Manifestparser prüft zur Laufzeit:

- Sample-ID vorhanden;
- Variante vorhanden;
- SQL-Mindestversion erfüllt;
- URL vorhanden;
- Variante hat einen freigegebenen Handler und eine dazu passende direkte
  `.bak`-, `.zip`- oder `.sql`-Quelle.

Nicht freigegebene Archive und Attach-Szenarien müssen mit einer erklärenden
Fehlermeldung abgewiesen werden. Freigegebene Script-Bundles bleiben an ihren
root-gebundenen Entrypoint, ihre erlaubten sqlcmd-Features und die vollständige
erwartete Outputliste gebunden.

`Invoke-SampleBaselineRuntimeChecks.ps1` belegt für Container und Hyper-V
dieselbe portable Registry-, Key-, Lock-, Auswahl- und Fallback-Semantik.
Der Hyper-V-Slice verlangt einen exakten Run, ein flüchtiges Gastcredential,
ein verifiziertes Storage-Receipt und genau eine Backup-Lane. Der synthetische
Test prüft Export, Gast-Cleanup und den bevorzugten run-gebundenen Restore.
Die Storage-Placement-Suite belegt zusätzlich, dass ad-hoc CREATE und RESTORE
ohne explizite Datenbankregel ausschließlich die verifizierten Default-Data-
und Default-Log-Lanes verwenden und partielle Bindungen nicht akzeptieren.
Für den automatischen Hyper-V-Manifestpfad belegt sie den Preflight auf
vollständige Default-Data-/Default-Log-/Backup-Lanes und die Ablehnung
widersprüchlicher Einzelplatzierung; die Hyper-V-Lab-Suite bindet den
run-basierten Sample-Handler statisch an Run, Instanz und Gastcredential.
Die bereits erfolgreiche Hyper-V-Testdatenbank-Reconcile-Abnahme belegt Add/Remove und eine Chinook-Baseline innerhalb eines Runs. Der getrennte Mehrfach-Sample-Manifest-Runner wurde im manuellen Main-Lauf `34790092466` auf Commit `95c5a79c` erfolgreich ausgefuehrt: Zwei frische sequenzielle SQL-2025-Prepared-Runs mit Chinook (`sql-server`) und Northwind (`script`) verglichen `LAB_GENERATED`-Baseline-ID/Key/Hash und beide `manifest.lock.json`-Bindungen im zweiten Run und bereinigten beide Runs scopegebunden. Weitere Hyper-V-Sample-Varianten bleiben getrennt offen.

Ein vollständiger automatischer Download-/Restore-Test pro Sample ist derzeit nicht vorhanden.

## 10. Cleanup- und Recovery-Prüfung

Der Smoke-Test prüft erfolgreichen Remove und versucht Cleanup bei einem Testfehler.
Der separate Mixed-Provider-Smoke-Test prüft zusätzlich Provisionierung,
Status, Stop, Start und Remove für genau einen Docker- und einen
Podman-ProviderSubRun.

Noch nicht vollständig automatisiert sind unter anderem:

- Prozessabbruch nach einzelnen Mutationsschritten;
- wiederholtes Cleanup nach Teilfehler;
- Fremdobjektschutz bei manipulierten Labels;
- symbolische Links und Junctions außerhalb des Scope;
- Providerfehler während Restore oder Serverkonfiguration;
- idempotenter Recoverylauf nach Hostneustart;
- gezielt induzierte Teilfehler in einem gemischten Provider-Lifecycle.

Diese Punkte bleiben Roadmap und dürfen nicht als validiert bezeichnet werden.

`Invoke-CleanupVolumeOwnershipChecks.ps1` prüft zusätzlich den Netzwerkzweig
des allgemeinen Cleanup-Kerns mit simulierten Docker-/Podman-Aufrufen:
genau passende Run-/Scope-Labels erlauben die Entfernung; gemeinsame,
fremde und nicht vollständig gebundene Netzwerke bleiben unverändert.
Änderungen an `Private/CleanupEngine.ps1` wählen diese Ownership-Suite sowie
alle fünf allgemeinen Runtime-Gates aus. Die Simulation ersetzt keinen
nativen Lauf und keinen Prozessabbruch-/Wiederaufnahmenachweis.

## 11. Privacy-Validierung

Vor Datei-, Git-, Package- oder Exportoperationen sind zu prüfen:

- Personen-, Firmen-, Kunden- und Organisationsbezüge;
- Hostnamen, IP-Adressen, Endpunkte und Pfade;
- Secrets und Connection Strings;
- reale Datenbank- und Objektstrukturen;
- Produktions- und unbekannte Backups;
- Logs, Plans, Responses und Screenshots;
- lokale State-, Artifact-, Cache- und Secretpfade;
- unerwartete Binärdateien und Archive.

Die statische Vertragsprüfung ist kein vollständiger Data-Loss-Prevention-Scanner. Verantwortliche Inhaltsprüfung bleibt erforderlich.

Der Privacy-Scanner grenzt die lokalen Runtimewurzeln `.runtime`, `.state`,
`.secrets`, `.artifacts`, `.cache` und `.local` mit korrekt maskierten
Pfadsegmenten ab. Flüchtige Dateien eines gleichzeitig laufenden eigenen
Lab-Tests verändern dadurch nicht den Quellscan. In den Git-Index aufgenommene
Dateien dieser Wurzeln werden dennoch geprüft; ohne lesbaren Git-Index bricht
der Scanner ab. Versteckte Dateien im aktiven Umfang werden auch unter Linux
erfasst. Isolierte synthetische Pester-Fixtures prüfen Runtime-Isolation,
aktive Secret-/Env-Dateien, erzwungene Indexaufnahme und ähnliche
Verzeichnisnamen. Diese Abgrenzung ersetzt weder den Cleanup des Runtime-Tests
noch die Prüfung vor Commit, Package oder Export.

## 12. Ergebnisbegriffe

```text
PASS
WARN
SKIP_OPTIONAL
NOT_EXECUTED
UNSUPPORTED
FAIL
RECOVERY_REQUIRED
```

Verwendung:

- `PASS`: relevante Prüfung erfolgreich und erforderliches Cleanup abgeschlossen;
- `WARN`: Prüfung lief, aber eine nicht blockierende Grenze bleibt;
- `NOT_EXECUTED`: Prüfung wurde nicht ausgeführt;
- `UNSUPPORTED`: aktueller Vertrag unterstützt den Pfad nicht;
- `FAIL`: erwarteter Vertrag wurde verletzt;
- `RECOVERY_REQUIRED`: erzeugte Ressourcen konnten nicht vollständig bereinigt werden.

Ein nicht verfügbarer Provider darf nicht als `PASS` behandelt werden.

## 13. Empfohlene lokale Abnahme vor Push/Release

### Nur Dokumentation, Schema oder Metadaten

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

### Docker-Runtime betroffen

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-PointInTimeRecoveryAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

Die PITR-Referenz prüft ausschließlich einen neuen eigenen SQL-2025-Container:
Full vor gutem Commit, SQL-Serverzeit-Cutoff in `datetime`-Präzision, getrennter
fehlerhafter Commit und erst danach Log-Backup. Offline werden der tatsächliche
orchestrierte SQL-Ablauf, mehrere Resultsets, Quelle nach Restore, Cleanup trotz
verlorener New-Rückgabe sowie echte Kindprozesse mit Timeout/Abbruch geprüft.
Arrange und Cleanup sind separat begrenzt; Rohlogs bleiben im geschützten lokalen
Temp-Root. Auf `f51595ea` bestanden am 2026-09-21 getrennte native Docker- und
Podman-Referenzen mit SQL-Major 17, gutem wiederhergestellten Commit, ausgeschlossener
Fehlmutation, unveränderter Quelle, `DBCC CHECKDB`, Own-Run-Removal und fehlenden
Runtime-Resten. Die gemessenen Restoreintervalle (Docker 2873,8858 ms; Podman
6600,8529 ms) dokumentieren nur Beobachtungen. Die gemeinsame Selektoränderung
verlangt den bestehenden breiten CI-Gate; die PITR-Capability benötigt nur Docker
und Podman. Private Temp-Evidence ist nach abgelehnter automatischer Löschung
zurückgeblieben; daraus folgt keine Behauptung vollständiger Dateibereinigung.
Bei einem vor SQL-Readiness beendeten eigenen New-Container kann der isolierte
Child vor dem bestehenden Auto-Cleanup eine private, sanitierte Readiness-Log-
Kopie erfassen. Das verlangt erneut passenden Operation-Run, Runtime-Scope sowie
frische Run-/Scope-/Instanzlabels und exakte Container-ID; fremde, laufende oder
nicht verifizierbare Container werden nicht gelesen. Capture-Fehler verändern
weder den primären New-Fehler noch den Cleanup. Die Diagnose ist kein Ursachen-
oder Ressourcenfix; der beobachtete Podman-Startabbruch bleibt `UNKNOWN`.
Die getrennte erneute Podman-Abnahme auf `a33675ca` bestand am 2026-09-21:
PITR und Cleanup abgeschlossen, eigener Run `REMOVED`, unabhängig bestätigte
Restfreiheit. Der frühere Startfehler wurde dabei nicht reproduziert; seine
Ursache ist damit weiterhin nicht belegt. Die Diagnoseintegration besteht
zusätzlich 142 fokussierte Prüfungen unter Windows und Linux.

### Host-Tool-Auflösung betroffen

```powershell
.\Tests\Static\Invoke-HostToolResolutionChecks.ps1
.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Der statische Resolver-Vertrag prüft sichere exakte Overrides, idempotente
nur-prozesslokale `PATH`-Erweiterung, unveränderte persistierte Benutzer-/
Maschinenwerte sowie die gemeinsame Einbindung in Modulimport und Podman-
Bootstrap. Eine AST-gestützte Vollprüfung über `Private`, `Public` und
`Providers` stellt sicher, dass produktive Docker-/Podman-Aufrufpfade den
zentral aufgelösten absoluten Aufruf verwenden und nicht von einem geerbten
Shell-`PATH` abhängen. Eigenständig gestartete Runtime-Acceptances werden
zusätzlich vor ihrem ersten Provider-Probe zentral initialisiert und verwenden
danach ausschließlich den absoluten `Invocation`-Pfad. Die Runtime-Smokes
bleiben erforderlich, weil
Dateiauflösung weder Engine-Erreichbarkeit noch Ausführungsberechtigung beweist.

### Podman-Runtime betroffen

Der Bootstrap wartet bei einer bereits laufenden oder startenden Machine auf
`podman info`, ohne erneut `machine start` auszufuehren. Die isolierte Suite
`Invoke-PodmanBootstrapChecks.ps1` prueft beide verzoegerten Readiness-Pfade,
den Timeout ohne Neustart sowie unveraenderte Startfehler und Lock-Semantik.
Diese synthetische Evidence ersetzt keinen nativen Podman-Smoke. Der Bootstrap
wechselt keine Connection und startet eine aktive Machine nicht neu, auch
wenn deren API bis zum Ende der Poll-Wartezeit unerreichbar bleibt.

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-PointInTimeRecoveryAcceptance.ps1 -Provider podman
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

### Gemeinsame Containerlogik betroffen

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-HyperVNetworkReconcileChecks.ps1
.\Tests\Static\Invoke-HyperVResourceReconcileChecks.ps1
.\Tests\Static\Invoke-ContainerReconcileChecks.ps1
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerCliAcceptance.ps1 -Provider podman
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

### Kataloggebundenes SqlPackage, BACPAC oder Container-Attach betroffen

```powershell
.\Tests\Static\Invoke-SampleHandlerChecks.ps1
.\Tests\Static\Invoke-SoftwareCatalogChecks.ps1
.\Tests\Integration\Invoke-ContainerToolAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-ContainerToolAcceptance.ps1 -Provider podman
```

Die Acceptance erzeugt ein synthetisches BACPAC im gebundenen Container,
importiert es wieder über den normalen Tool-Handler, prüft die importierten SQL-
Daten und die Entfernung des temporären Containerartefakts. Zusätzlich erzeugt
sie eine synthetische Datenbank, detacht deren MDF/LDF, kopiert nur diese
Testpayloads in den Host-Workspace und führt den normalen Container-Attach-
Handler mit ONLINE-, Inhalts- und Journalpostcondition aus. Der garantierte
Run-Cleanup entfernt sämtliche testbezogenen Container und Volumes. Ein zweiter
Attach auf die bereits vorhandene Testdatenbank erzwingt einen SQL-Teilfehler;
der Test verlangt dafür das persistierte `RECOVERY_REQUIRED`-Journal mit der
passenden Detach-Aktion. Sie lädt
kein fremdes Sample-Artefakt herunter.

Der Datenbankpaket-Static-Check ergänzt dazu den öffentlichen Hyper-V-
Recoverypfad: Nur ein für dieselbe Paket-ID, Run-/Instanzbindung und
Zielunterstruktur validiertes `RECOVERY_REQUIRED`-Journal darf mit
`Invoke-SqlServerLabDatabasePackageAttach -Recover` ausgeführt werden.

### Hyper-V-Lifecycle betroffen

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
```

Der Hyper-V-Smoke-Test ist ein Image-Registry- und VM-/VHDX-Lifecycle-Nachweis. Ein erfolgreicher
Lauf ist kein Betriebssystem-, PowerShell-Direct-Postcondition- oder SQL-Nachweis.

### Voller Minimalablauf (Push/Release)

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider auto
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

Bei fehlender Docker-/Podman-Ebene dokumentiert `Invoke-SmokeMatrix` `SKIP` statt `FAIL`; ein erreichbarer Providerfehler bleibt jedoch `FAIL`.

Reproduzierbare Release-Vorbereitung:

```powershell
.\Tools\Prepare-LocalRelease.ps1 -CreateArchive -IncludeHashManifest
```

Die Vorbereitung verlangt einen sauberen Git-Stand einschließlich nicht
ignorierter neuer Dateien und exportiert den festen `HEAD`-Commit. Lokale
State-/Secret-/Cachepfade, Medien, Backups, Zertifikate und Archive werden
auch bei versehentlicher Versionierung ausgeschlossen; Symlinks und
umgeleitete Zielpfade blockieren den Export. `WhatIf` legt keine Dateien an.
Erst fertig erzeugte Inhalte werden aus einem eigenen Staging-Verzeichnis
veröffentlicht; Teilfehler entfernen ausschließlich die eigenen Artefakte.
Diese Rücknahme ist für gewöhnliche Ausnahmen geprüft. Ein harter
Prozessabbruch kann Staging- oder Teilartefakte zurücklassen; eine atomare
Mehrdateiveröffentlichung bei Prozessabbruch ist damit nicht nachgewiesen.

`ReleaseManifest.json` enthält relative Pfade, Quellcommit und SHA-256-Werte;
`ReleaseReadinessCheck` unterscheidet `PASSED` und `SKIPPED`. Die optionale
`ReleaseHashes.txt` bindet auch das Release-Manifest. Der Archivhash liegt
ausschließlich neben der fertigen ZIP-Datei; deren Inhalt wird danach nicht
mehr verändert. Die ZIP-Datei erhält auch versionierte versteckte Nutzdateien.
`Invoke-ReleaseArtifactChecks.ps1` belegt diesen Vertrag mit synthetischen
Git-Fixtures, injiziertem Publikationsfehler und Import des realen Moduls aus
dem entpackten Paket. Ein Pakettest ersetzt keine nativen Providernachweise.

Nicht verfügbare Native-Tests müssen im Pull Request mit Grund als `NOT_EXECUTED` angegeben werden.

## 14. Roadmap

Verbleibende priorisierte Ergänzungen:

1. Pester-Kontrakt-Paket und Release-Artefakt-Erstellung (mit `Tools\Prepare-LocalRelease.ps1`) sind implementiert;
2. zusätzliche nicht mutierende Versionsauflösungstests;
3. weitere Fault-Injection-Pfade für Portbindung, Runtimeabbruch und
   teilweise Orphan-Bereinigung;
4. zusätzliche Fremdobjekt- und Pfadsicherheitstests;
5. Hyper-V-Windows-Specialization, PowerShell-Direct-Postcondition und
   SQL-Provisionierung nach der validierten Lifecycle-Grundlage.

Bereits umgesetzt sind vollständige Schema-Prüfungen, die lokal steuerbare
Version-/Provider-Matrix, ein synthetischer echter Backup-/Restore-Test, ein
deterministischer Cleanup-/Recovery-Fehlertest und das übergeordnete statische
Testskript `Tests/Static/Invoke-AllChecks.ps1`.

## 15. CI/CD-Abgrenzung

Die Regressionstests für den leeren Hyper-V-Fallback verwenden seit der
Reparatur vom 2026-09-10 einen tatsächlichen PowerShell-Job und prüfen dessen
Ergebnis und Entfernung sowie die Ablehnung ungültiger IPs vor dem Gastaufruf.
Die Sample-Baseline-Suite führt die produktive Gastexportfunktion mit
synthetischen Session-/Transfergrenzen aus. Sie prüft VM-Zustand, Datei- und
Längenpostconditions, Transferfehler und Session-Cleanup. Diese Offlineprüfungen
ersetzen keine native Hyper-V-Sample-Abnahme.

Lokale Produktfunktion und Native-Tests dürfen nicht von GitHub-hosted Runnern abhängen.

Der Workflow `PR Gate` klassifiziert geänderte Pfade, führt auf Windows und
Ubuntu nur betroffene statische Suites aus und schaltet ausschließlich passende
Runtime-Smokes zu. Änderungen am Foundation-Core, Root-Agentenvertrag,
Upgrade-Assessment, Copilot-Adapter oder PR-Gate starten zusätzlich den Job
`Foundation integrity`.
Der Job `static-contracts` hat für beide bestehenden Matrixplattformen ein
begrenztes Zeitbudget von 20 Minuten. Der Windowslauf des PR-Gates auf
`c12defe2` vom 2026-09-30 überschritt das frühere 10-Minuten-Budget bei
kontinuierlicher Analyzerarbeit nach den vorherigen betroffenen Suites; der
34-Suite-Nachweis blieb dadurch unvollständig. Dieser CI-Timeout ist vom
separaten lokalen Analyzerfehler durch gemischte Zeilenenden zu unterscheiden.
Die Budgetkorrektur entfernt keine Tests und ändert weder Auswahl,
Fehlerbehandlung, Concurrency noch andere Job-/Providerbudgets. Erst ein
vollständig bestandener neuer CI-Lauf belegt den Windows-Gate; die Änderung
des Budgets selbst ist kein erfolgreicher CI-Nachweis.
Die Auswahl bindet gemeinsame Hyper-V-Job-/Storage-Helfer auch an Netzwerk-,
Sample-Baseline- und Storage-Prüfungen. Gemeinsame KI-Implementierungen und
KI-Schemas wählen die KI-Vertragssuite sowie Docker, Podman und Hyper-V aus;
SQL-Observability verwendet dieselben getrennten Providernachweise. State-
Upgrade, portabler Import, Evaluation-Watch und Recovery-Point-Plan wählen
ihre jeweiligen statischen Vertragssuiten. Tabellenfälle prüfen diese
Abhängigkeiten pro Einzelpfad mit beiden Pfadseparatoren, damit ein weiterer
geänderter Dateiname keine fehlende Zuordnung verdeckt.
Runtime-Gates werden je Datei bestimmt und anschließend vereinigt. So bleibt
der Docker-Fallback einer unbekannten Produktdatei auch neben einem bekannten
Hyper-V-Pfad oder einer ausschließlich statisch geprüften Datei erhalten.
Der PR-Gate und die nativen Docker-, Podman-, Mixed- und Hyper-V-Workflows
brechen einen bereits gestarteten Lauf bei einer neueren Revision nicht hart
ab. Der neue Lauf wartet in derselben Concurrency-Gruppe, damit der laufende
PowerShell-Prozess seinen scopegebundenen `finally`-Cleanup auf dem persistenten
self-hosted Runner ausführen kann. Ein manueller Workflow-Abbruch oder ein
Runner-Ausfall bleibt davon getrennt und ist über Lifecycle-Metadaten,
Maintenance-Plan und objektgebundenes Cleanup zu behandeln.
Die Docker- und Podman-Lifecycle-Gates führen nach ihren jeweiligen Smokes
zusätzlich die öffentliche `DELETE_WITH_RUN`-Acceptance aus. Sie teilen den
bereits gehaltenen Runtime-Mutex, erzeugen einen isolierten rungebundenen Store
und verlangen Registrierung, Missing-Volume-Nachweis sowie `DETACHED`-Katalog-
abschluss; Backup- und Paket-SHA-256-Verträge bleiben davon getrennt.
Danach belegen dieselben getrennten Provider-Gates auch den öffentlichen
`Export-SqlServerLabDatabasePackage`-Pfad unter demselben Parent-Mutex:
`WhatIf`, live gebundene Quelle, exklusives Offline, stabile Paket-/Storage-ID,
vollständige Integritätsprüfung und Cleanup. Die Acceptance akzeptiert keine
freien Container- oder Hostpfade.
Die Acceptance injiziert zusätzlich einen Kopierfehler nach dem echten
SQL-Offline-Commit und verlangt `ONLINE`/`MULTI_USER` sowie ein dauerhaftes
`ROLLED_BACK`-Journal vor dem anschließenden erfolgreichen Export.
Ein zweiter injizierter Fehler trifft das Payload-Cleanup nach tatsächlicher
Publikation. Resume muss nach Hash- und Katalogprüfung dieselben Paket-/Storage-IDs
liefern; die Bibliothek darf weiterhin genau ein Paket enthalten.
`Invoke-ContainerDatabasePackageRecoveryChecks.ps1` prüft Teilfehler beim
Offline-Schalten, Dateiinventarwechsel, ursprüngliche Zugriffsmodi, Container-
und Datenbank-Identitätswechsel, Resume, Fehler beim Journalschreiben und
Payload-Cleanup sowie die gesonderte Offline-Sperre nach Bibliotheksübergabe.
Dieser checkt den in `.ai/repo_map.yaml` gebundenen Foundation-Quellcommit aus
und führt den Foundation-Validator mit den projektspezifisch ausgewählten
Adaptern und Capabilities aus. Sein Ergebnis fließt in den geschützten
Abschlusscheck `PR Gate` ein. Auf einen Merge nach `main` folgt keine zweite
Vollmatrix.
Die vollständige statische und native Regression läuft täglich gebündelt als
`Nightly Regression`; eine frische Hyper-V-/SQL-Installation läuft wöchentlich
oder manuell. Nightly-Fehler werden über ein dauerhaftes Tracking-Issue sichtbar.
Die reservierten gemeinsamen SQL-Testumgebungen sind davon ausgeschlossen:
Schedule autorisiert weder Reaktivierung noch SQL-Schreibtests. Nur ein
`workflow_dispatch` desselben Repositorys mit der separaten, standardmäßig
falschen Bestätigung `confirm_shared_mutation` erlaubt die Shared-Abnahme.
Das gilt auch für den Hyper-V-Modus `shared-environments`, dessen Modusauswahl
allein keine Freigabe ist. Vor Recover beziehungsweise SQL gilt dieselbe
Autorisierungsgrenze; rohe Ausgaben bleiben ohne Upload im lokalen Runnerlog.
Der Nightlyreport wertet ausschließlich den belegten Autorisierungsausschluss
als neutral: `NOT_EXECUTED` / `NOT_AUTHORIZED`, niemals als `VALIDATED`.
Fehler, Abbrüche und unerwartete Skips aller Pflichtprüfungen bleiben Fehler.
`CiStrategyNightlyAuthorizationChecks.ps1` führt extrahierte Guard-, Prozess-
und Reportblöcke mit synthetischen Grenzen aus. Eine reale Shared-Abnahme
wird dadurch weder ausgeführt noch nachgewiesen. CI-Infrastrukturänderungen
behalten die vollständige bestehende Providermatrix.

Die Image-Menüprüfung durchläuft die realen Menüdaten und Dispatcher von
`templates` beziehungsweise Shortcut `3` über Hyper-V zu `Image`, einschließlich
Zurück, Abbruch und Nichtverfügbarkeit. Beide Menüquellen selektieren diese
Prüfung einzeln und unabhängig von der Pfadschreibweise.

### Ressourcen-Reconcile aus einem Windows-Slot

Der manuelle Main-Modus `resource-reconcile-acceptance` akzeptiert optional
`clone_source_run_id` statt `image_artifact_id`. Die GUID bezeichnet einen
explizit ausgewaehlten gestoppten, eigenen Windows-2025-Slot ohne SQL-Plan oder
Checkpoints. Beide Ziel-Runs werden als unabhaengige Kopien erstellt; Quelle,
Gastsecret und Quellidentitaet werden nur gelesen. SQL 2025 wird mit den
hashregistrierten Medien aus `media_root` und `media_edition` im Clone installiert.
Die Windows-Lizenz muss dort `VerifyOnly` bestehen; es gibt keinen Online-
Aktivierungsfallback. Eine fehlende Aktivierung ist ein fehlgeschlagener Nachweis.

`Invoke-HyperVResourceReconcileCiAcceptance.ps1` uebergibt `CloneSourceRunId`,
`MediaRoot` und `MediaEdition` an den begrenzten Kindprozess. Der CI-Medienroot
bleibt auf den Standardroot begrenzt. Der Parent bereinigt ausschliesslich seine
beiden Operations-IDs, auch bei Kopierfehler vor der ersten VM. Timeout mit
unbestaetigter Prozessterminierung bleibt `RECOVERY_REQUIRED`.

Die fokussierte Ressourcen-Acceptance-Suite fuehrt eine synthetische Clone-
Transaktion aus und prueft ungueltige Quellen, Cleanup vor Kopie, eigene Lease,
Desired State, VerifyOnly, Abbruch bei Kopierfehler und Freigabe der Quelllocks.
Ein abgewiesener SQL- oder anderer nicht geeigneter Quell-Run bleibt ein
Provisionierungsfehler ohne Aktivierungscode; nur ein tatsaechlich erkannter,
allowlistgebundener Windows-Aktivierungsfehler wird als solcher in der kleinen
CI-Receipt ausgewiesen.
Bei einem Provisionierungsfehler darf die Receipt zusaetzlich ausschliesslich den allowlistgebundenen Mediengrund
`HYPERV_SQL_MEDIA_DIRECTORY_NOT_FOUND` oder einen der neun festen `HYPERV_RESOURCE_SLOT_SOURCE_*`-Vorbedingungsgründe transportieren. Pfade, Rohfehler und weitere Details bleiben ausgeschlossen.
Die native Clone-Abnahme bestand am 2026-09-14 mit einem expliziten gestoppten
Windows-2025-Quellslot und SQL Server 2025 Enterprise aus dem konfigurierten
Medienroot. Sie prüfte `VerifyOnly` mit aktiver Evaluation im Clone, dynamische
Live-/Restart- sowie statische Restart-Reconcile-Pfade, SQL-Readiness,
Shutdown-Integration, persistenten Datenmarker und vollständigen Cleanup der
beiden Test-Runs. Der Nachweis gilt nur für diesen Scope; weitere SQL-/Windows-
Versionen und Ressourcenklassen bleiben getrennt nachweispflichtig.

Der getrennte manuelle Modus `resource-reconcile-own-run-acceptance` bindet
statt einer Clone-Quelle ein explizites SQL-2025-Prepared-Artifact, denselben
Repositorykontext und den tatsächlich ausgecheckten Commit. Der native Lauf
`35564131935` vom 2026-09-21 bestand auf `a4510f5c`: dynamischer Live-/Restart-
und statischer Restart-Abgleich, `WhatIf`, VM-ID-gebundener einmaliger
Pre-Start-Fehler, Wrapper-Entfernung und Wiederaufnahme mit persistentem
SQL-Marker. Die beiden eigenen Windows-2025-/SQL-2025-Developer-Runs wurden
jeweils mit drei Cleanup-Schritten und null Fehlern entfernt. Der frühere
Aktivierungsfehler `35562372061` bleibt erhalten; der spätere Erfolg erklärt
seine Ursache nicht. Ein realer Hyper-V-Plattformfehler wird damit nicht belegt.

### Storage-Reconcile aus einem Windows-Slot

Der manuelle Main-Modus `storage-reconcile-acceptance` akzeptiert dieselbe
explizite `clone_source_run_id`-Quelle. `Invoke-HyperVStorageReconcileAcceptance.ps1`
prüft für HV-603 ausschließlich zwei manifestgebundene Host-SCSI-Lanes,
Add-Reconcile, das unveränderte `WhatIf`, den VHDX-/Attachment- und
Gast-Receipt, SQL-Readiness nach VM-Neustart, No-op und operationseigenes
Cleanup. Der Clone erhält SQL 2025 aus hashregistrierten Medien und nutzt
`VerifyOnly`; SQL-Dateipfad-Relocation oder -Rebinding gehört nicht zu diesem
Runner (HV-603A). Die lokale native Abnahme vom 2026-09-19 bestand mit
vollständigem Cleanup; der genaue Nachweisumfang steht unten. Grow-only sowie die kontrollierte Unterbrechung nach
`HOST_APPLIED` und Resume ohne doppelte Hostmutation werden weiterhin durch den
vorhandenen synthetischen Storage-Reconcile-Vertrag belegt, bis ein
produktionssicherer nativer Fault-Injection-Punkt ausdrücklich autorisiert ist.

### SQL-Storage-Reconcile aus einem Windows-Slot

Der manuelle Main-Modus `sql-storage-reconcile-acceptance` verlangt einen
expliziten gestoppten Windows-2025-Clone-Source-Run. Der Runner
`Invoke-HyperVSqlStorageReconcileAcceptance.ps1` verwendet ausschließlich
hashregistrierte SQL-2025-Medien mit `VerifyOnly` und verweigertem Egress. Er
stellt zuerst die gebundene HV-603-SCSI-Lane her und verlangt deren No-op, bevor er
die receiptgebundenen SQL-Default-, Backup- und TempDB-Pfade plant. `WhatIf`
ändert weder SQL noch Receipt; die Reparatur verifiziert Receipt und
dateigenaue SQL-Postconditions nach einem SQL-Dienstrestart ohne VM-Neustart,
anschließend No-op und operationseigenes Cleanup. Fault/Resume bleibt der
synthetische HV-603A-Vertrag. Der lokale erhöhte Lauf vom 2026-09-17 bestand
auf Windows Server 2025 mit SQL Server 2025 Enterprise (Exitcode 0):
verifizierter Runtime-Receipt, drei Default-/Backup-Verzeichnisse, vier
TempDB-Datendateien und eine TempDB-Logdatei, SQL-Dienstrestart bei unverändertem
Gast-Bootzeitpunkt, anschließender No-op und vollständiges operationseigenes
Cleanup mit fünf Schritten ohne Fehler. Der geprüfte Runnerstand ist Commit
`43bdb819`; die Abnahme erfolgte lokal, nicht als GitHub-Actions-Lauf.
SQL-Verzeichniswerte werden ohne abschließenden Pfadtrenner verglichen,
TempDB-Dateipfade weiterhin exakt und ohne Beachtung der Groß-/Kleinschreibung.
Die ausführbare Offline-Regression prüft zusätzlich falsche und leere
Default-Verzeichnisse sowie fehlende, doppelte und falsch platzierte
TempDB-Dateien. Andere Versionskombinationen und natives Fault/Resume sind
damit nicht belegt.

Nachträgliche Sicherheitshärtung: Der größenbasierte RAW-Fallback wurde
entfernt. `Invoke-HyperVProviderChecks.ps1` führt die tatsächliche Gast-
Auswahllogik ohne Diskmutation mit synthetischen IDs aus und prüft fremde,
fehlende, mehrdeutige und bereits beanspruchte Disks sowie zwei gleich große
Disks mit passenden IDs. Der native Erfolg auf `43bdb819` darf nicht auf diese
Änderung übertragen werden. Der integrierte Parser liest die vollständige GUID
aus binären Microsoft-T10-Geräteidentifikatoren. Seine synthetischen Tests
prüfen auch ungültige Längen und Verweise sowie fremde Vendor-, Port-, Codeset-
und NAA-Kennungen. Boot-/Systemplatten und Fehler in späteren Planeinträgen
werden vor dem Schreibabschnitt abgefangen. Ein separater rein lesender
Windows-2025-Gastprobe bestätigte die vollständige Host-GUID. Am 2026-09-19
bestand auch der lokale native `Invoke-HyperVStorageReconcileAcceptance.ps1`-
Lauf mit dem integrierten Stand: zwei neue Datenplatten, Add-WhatIf ohne Mutation,
Gast-Receipts, SQL-Bereitschaft nach VM-Neustart und No-op. Alle sechs
Cleanup-Schritte sowie die zusätzliche operationseigene Restprüfung waren
erfolgreich. Dies ist kein GitHub-Actions- oder nativer Fault-Injection-Nachweis.

Beide Storage-Acceptance-Runner lehnen bereits belegte Operation-IDs vor dem
Clone ab. Schlägt der Clone vor Rückgabe des Runs fehl, wird ausschließlich der
eindeutig zu dieser Operation gehörende Run für Cleanup oder `KeepOnFailure`
wiederaufgenommen. Die gemeinsame Offline-Fixture prüft erfolgreiche,
fehlende und mehrdeutige Zuordnung sowie fehlende Ownership und bestehende Runs.

### Ein-Datenbank-Containertransfer

`Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1` prüft offline den
neuen Executor mit Fehlern an Ownership-, Endpunkt-, Journal-, Restore- und
Cleanupgrenzen einschließlich verlorener Antworten und Wiederaufnahme ohne
zweiten Restore. `Invoke-RelationalCoreComparisonChecks.ps1` bewahrt den
bestehenden Inhaltsvertrag. Der CI-Selektor wählt die neue Suite separat.
Für Änderungen an diesem Executorpfad wählt er Docker und Podman; eine Änderung
am Selektor selbst bleibt dagegen CI-Infrastruktur und aktiviert die bestehende
vollständige Provider-Matrix einschließlich Hyper-V.
Die native Abnahme ist `Tests/Integration/Invoke-PortableContainerTransferAcceptance.ps1`
mit jeweils `-Provider docker` und `-Provider podman`. Sie verwendet ausschließlich
eigene SQL-2025-Linux-Runs und synthetische Daten. Quelle und Ziel werden
vollständig scopegebunden bereinigt; erhaltene Recovery-Reste sind kein PASS.
Die fokussierte Offlineprüfung bestand am 2026-09-20 mit 32 Assertions. Die
lokalen Docker- und Podman-Referenzabnahmen bestanden getrennt am selben Tag
mit jeweils zwölf Assertions,
einschließlich unveränderter read-only Quelle, Replay, Inhaltsabweichung und
vollständiger Restprüfung. Native Prozessabbrüche sind dadurch nicht belegt;
verlorene Antworten und Journalfehler bleiben getrennte Offline-Evidence.
Hyper-V gehört nicht zu diesem Änderungsscope.

### SQL-Gast-Editionscapture

`Tests/Static/Invoke-SqlGuestEvaluationCaptureChecks.ps1` prüft Receiptkette,
Drift, Credentialgrenze, Lock, Reparse-Root, Fehlererhaltung sowie echte
SqlClient-Builder und sequenzielle Reader. `Invoke-HyperVGuestProgressChecks.ps1`
prüft den optionalen VM-ID-Pfad ohne WinRM-Fallback. CI-Auswahl und Workflowmodus
sind durch `Invoke-CiStrategyChecks.ps1` gebunden.

Die native Abnahme `Tests/Integration/Invoke-SqlGuestEvaluationCaptureAcceptance.ps1`
benötigt eine explizite vorhandene SQL-2025-Developer-Prepared-Artifact-ID und
Administratorrechte. Der Hyper-V-Modus `sql-guest-evaluation-capture-acceptance`
verwendet diesen Runner ohne Image-Bootstrap. Lauf `35563036235` auf Commit
`00742f14` bestand am 2026-09-21 mit elf Assertions einschließlich Developer-
Capture, Receiptkette, unverändertem Run-/Connection-State und Parent sowie
vollständigem Cleanup (drei Schritte, keine Fehler, keine VM-/Diskreste).
Positive Evaluation und echte Deadline bleiben eigene offene Nachweise.
Die Abnahme erstellt und bereinigt ausschließlich ihren eigenen Run.

### llama.cpp-Discovery

`Invoke-LlamaCppInstallerChecks.ps1` führt synthetische echte Plan-/Apply-/No-op-/
Drift-/Cleanup-, HTTPS-/Redirect-/Bytegrenzen-, ZIP-/Dateimengen-, importierte
HTTP-Handler und Cursor-/Fallback-/Direktaktionspfade aus. Native Probe bleibt
eine abgegrenzte synthetische Boundary. Der tatsächliche Worker-Copier wird mit
MemoryStreams auf kumulativ64KiB geprüft; sein Windows-Environmentzweig wird
ohne Prozessstart ausgeführt. Die DOM-Fixture in `Invoke-WorkflowUiChecks.ps1`
prüft Auswahl, Vorschau, explizite Bestätigung, Abbruch, No-op, UNKNOWN/Fehler
und verzögerte Antworten am echten Browserhandler. Diese Evidenz ist kein
Download oder nativer Start. Der initiale eigene Windows-x64-CPU-`--version`-
Nachweis benötigt einen separaten konkreten Own-Vertrag. Am 2026-09-29
bestand der neue eigene Windows-x64-CPU-Pfad neun Prüfungen einschließlich
Plan/Cancel/Apply, exakter Buildidentität, vollständiger Dateimenge, No-op,
Stale-/Drift-Abweisung und bestätigtem Fixture-/Prozess-Cleanup. Zwei ältere
Fehlversuche bleiben getrennte Historie; der dabei belegte Readerfehler ist
am echten Post-Exit-Zweig mit realen synthetischen Dateihandles geprüft.
Der native Erfolg ist nur `BINARY_PROBE_PASSED`; Compute/SQL/Modelle bleiben offen.

`Invoke-LlamaCppRuntimeChecks.ps1` prüft synthetische Windows-Paketbäume:
Hashfreiheit, Backendmehrdeutigkeit, NPU-Filter, Suchgrenzen, isolierte explizite
Wurzeln und Schema. Die Prüfung startet weder llama-server noch SQL-Provider.

`Invoke-LlamaCppModelCatalogChecks.ps1` validiert Katalog und Schema sowie die
unveränderliche HTTPS-/Revisions-/Größen-/SHA-256-/Lizenzbindung. Synthetische
kleine Dateien prüfen Download-on-demand, Cache-Revalidierung, atomare
Veröffentlichung, Teilstandbereinigung, GGUF-Magic, Quellen-Allowlist und
`WhatIf`; die Suite lädt keine realen Modelle und startet keine Runtime.

`Invoke-AiComputeSelectionChecks.ps1` prüft Auto als Default, vollständige
vergleichbare Coverage, Mehr-GPU- und gemischte Gerätesätze, stabile
Eingabereihenfolge, Throughput-/P95-Tie-Breaks, Pinned-Override und negative
Binding-, Eligibility-, Duplikat-, Teilfehler- und NaN-Fälle. Die Suite erzeugt
nur synthetische Receipts und greift auf keine Hosthardware zu.

`Invoke-AiComputeBenchmarkChecks.ps1` prüft den `llama-bench`-Producer mit einem
synthetischen Prozessadapter: vollständige CPU-/Einzel-/Mehr-GPU-Coverage,
automatisch eindeutige und explizite Geräteselektoren, blockierte identische
Teilgruppen, identische Profilbindung, GGUF-Magic, Backend- und
Runtimehashbindung, P95-/Durchsatzableitung, Auto-Übergabe sowie negative
Ausgabe-, Duplikat- und Manipulationsfälle. Sie prüft außerdem den getrennten
Embeddingmodus mit Prompttokens ohne Generationsausgabe und verhindert eine
falsche Wiederverwendung des Embedding-Workloadschlüssels. Die gleiche Suite
prüft die vollständige Mengensmessung, Runtimehash-Zuordnung, direkte
Schnellstauswahl und fail-closed fehlende Pakete oder Teilreceipts. Diese Offline-Suite führt kein echtes
Modell aus; ein nativer Lauf bleibt ein getrennter Nachweis.

`Invoke-AiComputeBenchmarkAcceptanceChecks.ps1` bindet den opt-in Runner an die
öffentliche Inventar-, Runtimefähigkeits-, Kandidaten- und Mengensmesspipeline,
prüft dessen fail-closed Postconditions, das eigenständige Receipt-Schema und
den frühen mutationsfreien `WhatIf`-Pfad. Der getrennte
`Invoke-AiComputeBenchmarkAcceptance.ps1` führt auf ausdrücklich freigegebener
Hardware alle geeigneten Kandidaten real aus und schreibt optional pfadfreie
Evidence. Ein solcher nativer Lauf wurde auf dem aktuellen Entwicklungsstand
noch nicht ausgeführt.

`Invoke-AiComputeInventoryChecks.ps1` prüft synthetische Windows-/Linux-nahe
CPU-, GPU- und NPU-Probes, stabile datenschutzbegrenzte Inventarhashes sowie die
vollständige Potenzmengenbildung innerhalb expliziter Runtimegrenzen. Sie prüft
Mehr-GPU- und gemischte Sets, Manipulation, fehlende Coverage und die
fail-closed 64-Kandidaten-Grenze ohne echten Geräte- oder Runtimezugriff.

`Invoke-AiRuntimeCapabilityChecks.ps1` bindet synthetische llama.cpp-Pakete
einschließlich Supportbibliotheken an Inhaltsdigests und leitet daraus CPU-,
CUDA-, ROCm-, Vulkan-, SYCL- und OpenVINO-Lanes mit Herstellerfiltern ab. Die
Suite prüft Pfadfreiheit, Duplikate, Binärdrift, fehlende Backenddateien und die
Übergabe an die Kandidatenbildung, startet aber keine Runtime.

### Eigener llama.cpp-Lifecycle

`Invoke-LlamaCppOwnedRuntimeChecks.ps1` prüft Accelerator-Evidence, negative
Ownership, restriktive Windows-/Linux-Rechte, Linux-Socketzuordnung sowie die
hashgebundene Übergabe einer Auto-/Pinned-Auswahl an CPU-,
CUDA-, OpenVINO-, ROCm-, Vulkan-, SYCL- und Mehr-GPU-Startparameter. Die Suite
verwendet synthetische Pakete, Geräte und Prozessausgaben.
`Invoke-LlamaCppOwnershipAcceptance.ps1` führt echte Windows-Kinder
für Ownerverlust, Lease-Ende und Worker-Kill aus. Eine entsprechende echte
Linux-Akzeptanz sowie ROCm-Hardwareevidence bleibt offen. Die getrennte
`Invoke-LlamaCppSqlAcceptance.ps1 -RuntimeDirectory <Paket> -ModelPath <GGUF>`
benötigt Windows, CUDA, ein passendes 768-dimensionales Nomic-Embeddingmodell
und Docker. Sie legt eigene Testzertifikate und einen eigenen SQL-2025-Run an,
prüft Auth, External Model und SQLrestart und bereinigt ausschließlich eigene
Ressourcen. Beide Acceptances sind opt-in und laden keine Modelle herunter.

## Hostspeicher nach Stop

Die fokussierte Suite `Tests/Static/Invoke-StoppedHostMemoryChecks.ps1`
prüft die Entscheidung und Backendbindung mit synthetischen Messungen.
Der zusätzliche Providervertrag führt den tatsächlichen Helper, öffentlichen
Stop und Lifecycle-Reconcile mit isolierten Provider-/Host-Spies aus:
Hyper-V, unbekannte und gemischte Nicht-Containerbindungen sind ohne Skip
`NOT_APPLICABLE`; Skip ist `DISABLED`. Beide Wege dürfen keine Hostmessung
oder gemeinsame Cachefreigabe auslösen. Reine Containerbindungen behalten
ihre vorhandene Wartungsentscheidung.
Native Abnahmen müssen Docker und Podman getrennt betrachten: eigener
Lab-Stop, unverändert laufender Nachbar, Cache vor/nach Freigabe sowie
Windows-RAM-Rückgabe als getrennte Beobachtung. Eine injizierte Druckmessung
ist als solche zu benennen; sie ist kein Nachweis realen Host-Speicherdrucks.
[Vertrag](../Architecture/STOP_HOST_MEMORY.md).

Die getrennten nativen Windows-Abnahmen am 2026-09-27 bestanden für Docker
und Podman: öffentlicher Stop eines eigenen SQL-2025-Labs, echte Cacheabnahme,
beobachtete Windows-RAM-Zunahme, erhaltene laufende Nachbarcontainer, No-op
beim zweiten Stop und vollständiger Container-/Volume-Cleanup. Die
Druckentscheidung wurde durch eine synthetisch erhöhte Gesamtkapazität
aktiviert; der Host wurde nicht künstlich ausgelastet. Die erste Docker-
Cachefixture auf der kleinen WSL-Systempartition wurde vor dem Stop verworfen
und bereinigt; der erfolgreiche Runner nutzt ausschließlich sein eigenes
Lab-Volume. Die fokussierte Suite bestand 20 Assertions einschließlich des
öffentlichen WhatIf-, Teilfehler- und Gruppen-Koordinatorverhaltens.

## Slotreservepolicy und Kandidatensicht

Neue Windows-Poolmitglieder verwenden zusätzlich den gekoppelten Vertrag
`Documentation/Architecture/WINDOWS_POOL_MEMBERSHIP_AND_CLAIMS.md`.
`Invoke-WindowsPoolClaimChecks.ps1` führt kanonische Member-CAS und Whole-Run-
Writer, Notes-/Root-/Reparsegrenzen, Preview/Cancel/Revalidierung, 24-Stunden-
Evidence, gehaltenen Recovery-Stop und Consume unter injizierten CPU/RAM-,
Connectionpersistenz-, Journal- und Postconditionfehlern aus. Getrennte echte
PowerShell-Prozesse prüfen konkurrierende Claims einschließlich Rootalias,
identischen Operationsresume und Claim-Erhaltung nach Workercrash. Die
Fixtures liegen ausschließlich lokal unter `.artifacts/windows-pool-checks`.
Die Suite prüft außerdem die echten Workflowparameter `RunId`/`StateRoot`
und feste feldbezogene Capturecodes samt Allowlist und Deduplizierung. Der
fehlgeschlagene Native-Captureversuch bleibt als fehlender Gesamtbeleg erhalten;
eine OOBE-Localequittung ersetzt keine frische Poolcapture.
Der echte Guest-Scriptblock wird mit einem synthetischen Datum vor 1970
geprüft: positive frische Grace liefert ein Ende, fehlende Grace und ungültige
Lizenz bleiben gesperrt. Ein echtes abgelaufenes oder unlesbares Enddatum darf
durch positive Grace nicht ersetzt werden. Diese Änderung betrifft nur
Hyper-V-Gastcapture. Der vom Selektor ausgewählte Docker-Fallback bleibt
ein Pflichtnachweis für den stabilen Stand; frühere Docker-Evidence deckt
dessen neuen Quelldigest nicht ab.
Echte öffentliche Start-/Stopaufrufe werden am synthetischen geclaimten
Mitglied geprüft: Die Sperre greift vor Runtime-Abgleich und No-op-Rückgabe,
Statebytes bleiben unverändert. Der Native-Versuch mit frischer Guestcapture
erreichte den Direktaufrufcheck, lieferte dort aber noch keinen Gesamt-PASS.
Der fokussierte Migrationsvertrag blockiert StateRoot-verschiebende
DataRoot-Migrationen mit Poolmitgliedern auch nach Consume, lässt eine
Migration ohne Rootwechsel und entfernte Tombstones ohne live VM zu und
verweigert unbekannte oder widersprüchliche Bindungen vor Copy/Mutation.
Die Pool-Fixture injiziert außerdem einen nichtterminierenden Fehler am echten
nativen Inventarlesepfad und prüft gespeicherte IDs mit fehlenden bzw. fremden
Notes, fremde gleiche Namen sowie ein erfolgreich leeres Inventar. Migration,
Cleanup und Erstellung bleiben bei unbekanntem Inventar gesperrt.

`Tests/Integration/Invoke-WindowsPoolClaimAcceptance.ps1` ist der separate
native Windows-2025-Desktop-Harness. Er verlangt einen explizit ausgewählten
integritäts- und Childboot-verifizierten Parent, eine erhöhte freigegebene
Lane, ein ausgewähltes lokales SQL-Medium sowie ausdrückliche Ausführungs-
und Cleanupbestätigung. Er erstellt genau ein eigenes Poolmitglied,
prüft Gastcapture/Off-Verfügbarkeit, gebundenen Resume, Cancel, Guard,
Release und vollständigen Consume. Nur beim Erfolg wird dieses eigene
Mitglied über den bestehenden Cleanupvertrag entfernt; Fehler versuchen
einen eigenen Stop und bewahren State/Child mit getrennten Fehlerkategorien.
`Tests/Common/WindowsPoolNativeAcceptance.ps1` enthält die testinternen
Bindings- und Nachbedingungsprüfungen. Die fokussierte Suite reproduziert
fehlenden Marker bei anderem DefaultRoot, exakte Nicht-Pool-VM-Bindung,
unbekannte Reserveabdeckung, Rename/Missing-Discovery und Parentdrift.
Native Erfolg verlangt erhaltene Originalidentitäten und unabhängigen
Parentvergleich sowie VM-/Child-/Adapter-/IPAM-/Secret-Absence; fehlende
State-/Discoverydaten verhindern PASS und automatischen Cleanup.
Ein vorbereiteter Harness ist kein ausgeführter Providerbeleg. Er benötigt
eine eigene Evidence und bestätigt weder SQL-Reserve noch automatische Auffüllung.

`Invoke-SlotReserveChecks.ps1` prüft synthetisch denselben Preferences-Writer
mit vier getrennten PowerShell-Prozessen, Mergeerhaltung, ungültigem JSON,
Authority-/Vorgängerdrift, expliziter Nullreserve und injiziertem Schreibabbruch.
Die echten CLI-Fallback-, Refresh-, Vorschau-, Abbruch- und Bestätigungswege
sowie der HTTP-Handler werden ohne Provider ausgeführt. Die JavaScript-Fixture
prüft beide Einstiege, Vorschauinvalidierung, Apply, Fehler und verspätete Antworten.
Registrierte gestoppte Kandidaten, aktive Vorgangsbindung und unbekannte/frische
SQL-Evidence bleiben getrennte Verträge; diese Prüfung erstellt keine Slots
und belegt keine native Slotreserve oder Reservierungsrace. WindowsSlotPool-
und Batch-Suites sichern die vorhandenen Erstellungs-/Resumeverträge separat.
Die fokussierte Prüfung bestand 38 Assertions; der JS-Handlerstand bestand
51 Assertions. `Invoke-SlotReserveMigrationChecks.ps1` bestand 21 Assertions:
echte getrennte Writerprozesse warten über synthetisches Copy/Rewrite/Cleanup,
Quellpreferences werden danach nicht neu angelegt, Zielmerges erhalten fremde
Felder, Teilakquisitionen geben Locks frei und ungültige Preferences stoppen
Legacy-Root-/Storage-Setter einschließlich `Set-LabDataRootDefault` vor ihrer
ersten Mutation. Journalgebundene Resumezustände erlauben den gespeicherten
Defaultwechsel und bereits bereinigte Quellpreferences; fremde Zieländerungen
und falsche Pläne werden abgelehnt. Die vorhandene Storage-Migrationssuite
bestand 26 Prüfungen einschließlich der tatsächlichen Checkpointpersistenz
vor Bindingcommit und Cleanup. Diese Filesystemfixtures migrieren
keine reale Umgebung. Der ausgewählte Docker-Core-Smoke mit SQL Server 2025
bestand am 2026-09-29 isoliert 34/34 Prüfungen. Eigene Runs wurden entfernt;
Container, Volumes und Netzwerke des eigenen Scopes waren danach abwesend.
Persistierte Benutzerdefaults blieben unverändert, Rohdiagnosen und die
synthetische Dateifixture bleiben ausschließlich lokal. Das belegt den
Docker-Core, keine Slotreserve, Claims, Hyper-V oder reale Storage-Migration.

## Lokale Bootstrapperquellen

`Tests/Static/Invoke-MediaSourceGuidanceChecks.ps1` führt den gemeinsamen
Quellen-Core, den echten CLI-Fallback und den extrahierten HTTP-Handler mit
isolierten synthetischen Preferences und Katalogdaten aus. Geprüft werden
Read/Preview/Cancel/No-op, Bestätigung, gezielter Reset, fremde Felder,
veralteter Katalog/Vorgänger, Writerlock-Revalidierung, ungültige URLs und
unveränderte Größen-/Hashbindung für alle sechs SQL-2022/2025-Bootstrapper.
Falsche Version, Edition, Art, Architektur, Sprache, Dateiname und Integritätswerte
werden vor der Quellenzuordnung abgelehnt. Der SQL-2022-Evaluation-Default
behält seine vorhandene Vendorquery, während alternative Adressen queryfrei
bleiben. Der echte Save-Pfad wird an eine eigene
Loopback-Transportfixture gebunden: 301/302/303/307/308 dürfen weder eine
Folgeanfrage noch eine publizierte Datei erzeugen. Die Tests erlauben keinen
produktiven Loopback-Override. Microsoft-Endpunkte werden nicht kontaktiert.

Die echten Browserhandler werden in `WorkflowSqlTargetChecks.cjs` mit einem
minimalen DOM geprüft: ausgewählte ID, Edit-/Resetvorschau, explizites Apply,
Planinvalidierung, Fehler, No-op, Abbruch und verspätete Antworten. Dazu kommen
die betroffenen statischen Gates und die vorhandenen Medienbuilder-,
ArtifactResolver-/Trust- und ResourceSet-Regressionen. Diese Evidence ist
keine Aussage über aktuelle Herstellerdateien oder Downloadverfügbarkeit.
Ein vom unveränderten Selektor geforderter Providergate bleibt separat nötig.

## Resource Watch: fokussierte Validierung

`Invoke-VersionCatalogChecks.ps1` führt zusätzlich
`Fixtures/ResourceWatchChecks.ps1` aus: CU-Core plus SqlPackage, Cache/TTL,
Alt/Neu, Quellenfehler, Dedupe, echte lokale HTTP-Transportgrenzen,
CLI-Fallbackauswahl und den extrahierten echten HTTP-Handler. Katalogdrift wird
nur in einer eigenen GUID-Fixture erzeugt; deren begrenzter Cleanup prüft
kanonischen Parent, Leaf und Reparsepoints. Keine reale Quelle wird verändert.
`Invoke-WorkflowUiChecks.ps1` führt die echten JS-Handler über die bestehende
DOM-Fixture aus, einschließlich explizitem Refresh, Fehler und verspäteter Antwort.
Loopbacknachweise ersetzen keine Live-Quellen-/Runtime- oder Schedulerabnahme.

Am 2026-09-29 lief zusätzlich ein ausdrücklich ausgelöster Live-Metadatencheck
über den neuen Watchpfad: CU 2019/2022/2025 `NO_CHANGE`; SqlPackage `NEW`,
Katalog `170.4.83.3`, beobachtet `170.5.96.0`. Ein zunächst erkannter Parserfehler
am formatierten Herstellerlabel wurde eng korrigiert und unabhängig nachgeprüft;
der anschließende Livecheck war erfolgreich. Es wurden keine Pakete bezogen,
Kataloge geändert oder Installations-/Kompatibilitätsfreigaben abgeleitet.
Rohantworten und lokale Runtime-Diagnosen bleiben außerhalb des Repository.

Der stabile Offline-Scope bestand 23 ausgewählte statische Suites. Nach dem
engen Parserdelta bestanden VersionCatalog 106 Prüfungen; echte JS-Handler 75,
Dokumentation 1543 und Privacy 3 Prüfungen wurden im jeweiligen stabilen Scope
bestätigt. Separat bestand ein eigener isolierter Docker-SQL-2025-Core-Smoke
34/34 mit geprüftem Runtime-Cleanup und unveränderten Benutzerdefaults.
Dieser Docker-Nachweis belegt den gemeinsamen Core, keine Resource-Watch-
Dauerüberwachung und keinen anderen Provider.

### Resource-Watch-Automationslane

`Fixtures/VersionCatalogResourceWatchAutomationChecks.ps1` wird über die
bestehende VersionCatalog-Suite ausgeführt. Reale pure Projektion, kompletter
Issue-APIvertrag, Runner und extrahierte Workflow-PowerShell laufen mit
synthetischen Daten. Geprüft werden Scope-/Quellen-/Versions-/Fehlergrenzen,
Monatsunabhängigkeit, WhatIf, frische Revalidierung, POST/PATCH plus Nachlesen,
Lost-response-Recovery, globale/individuelle Erholung und fremde Bodybytes.
Die Issue-HTTP-Fixture ersetzt ausschließlich den URIresolver mit eigenem
Loopback, verwendet einen synthetischen Token und führt den echten begrenzten
Streamreader aus: 3xx ohne Folgeanfrage, HTTPfehler, Encoding-/Byte-/JSONgrenzen
und Timeout. Sie belegt weder GitHub-TLS noch Berechtigungen oder Zustellung.

Die eigene Namespacefixture prüft getrennte Marker/Receipts, fehlerhafte
Dispatchinputs, Schutz regulärer Issues und den receipt-/scopegebundenen
Close-Cleanup einschließlich Vorschau, Drift, ungültiger Bindung und No-op.
Die begrenzte Own-Projektion wird am tatsächlichen Helper mit vollständigem
Vier-Ressourcenbefund und synthetischem API-Adapter geprüft: explizite Auswahl,
ein unterschiedliches Issue, ein Write, vollständige vorhandene Own-Inventur,
globale Fehler/Recovery, null Kandidaten sowie UNKNOWN-Continuation mit fehlendem
und später gefundenem Marker. Fremde Scope-/Head-/Befund-/Bodyhashbindungen
blockieren vor Write; ein veralteter UNKNOWN-Befund gewährt keine neue Authority.
Es werden keine echten Issues erstellt, keine reguläre Task aktiviert und keine
Provider gestartet. Die echte Abnahme bleibt gemäß
[Automationsvertrag](../Architecture/RESOURCE_WATCH_AUTOMATION.md) separat:
exakter Workflowhead, echter Dispatch, nachgelesener Issue-Receipt, Dedupe und
eigener Cleanup. Ein konfigurierter Cron oder erfolgreicher Dispatch ersetzt
keinen tatsächlich durch den Cron ausgelösten Lauf.

## Geführter eigener llama.cpp-Sitzungsstop

`Tests/Static/Invoke-LlamaCppSessionGuidanceChecks.ps1` führt Core, den echten
UI-Modulimport, HTTP- und CLI-Grenzen mit synthetischen Sitzungen aus.
`WorkflowSqlTargetChecks.cjs` führt die echten Browserhandler aus. Scope:
Cancel/WhatIf, Objekt-/Portbindung, ablaufende und verbrauchte Vorschau,
geänderte deklarierte Verbraucher und Schutzregistrierung. Die separate native
Windows-Abnahme `Invoke-LlamaCppOwnershipAcceptance.ps1 -Case GuidedStop`
bestand am 2026-09-30 in einem neuen NoProfile-Prozess mit Exitcode 0:
Workflow-Preview/Cancel/Stale/Apply/Replay, eigenes Worker-/Kindende und
Keyabwesenheit, Nachbarkind während Stop aktiv und danach separat own-cleaned,
vollständiger eigener Testroot-Cleanup. Ausschließlich synthetische native
Prozesse und isolierte Registry; keine bestehende Shared-Umgebung,
SQL-/Modell-/Compute-/Providerprobe. Browser-/CLI-Bedienung bleibt durch echte
synthetische Handlerchecks belegt; der Nativefall ist keine manuelle UI-Abnahme.

Die eigene Guidance und der Shared-Gateway-Registrar teilen eine kanonische
StateRoot-Lifecyclesperre vor ihren bisherigen Gateway-/Testgruppen-Sperren.
Der Fokustest führt einen echten konkurrierenden Registrar sowie einen echten
Guidance-Stop in getrennten synthetischen PowerShell-Prozessen aus und injiziert
Publikation nach der letzten Observation. Port-/Workerdrift, Directory-,
Reparse- und unlesbare Registrypfade sowie reguläre null-RunIds sind getrennt
geprüft. Der Nativeharness bewahrt Fehlerursache und Cleanupfehler getrennt und
löscht sein Testroot nur nach bestätigter Abwesenheit seiner eigenen Aktivität.

Der stabile breite lokale Lauf führte 34 betroffene Suites aus: 33 bestanden;
PSScriptAnalyzer scheiterte an gemischten Zeilenenden und blieb danach ohne
Prozessaktivität hängen. Ausschließlich das exakt gebundene eigene Analyzerkind
wurde kontrolliert beendet; der breite Lauf bleibt deshalb FAIL. Nach der
notwendigen Korrektur bestand der abschließende Analyzer auf dem unveränderten
Produktfreeze ohne neue Error-Fundmeldungen. Der zusätzliche terminierende
Stagingcleanup-Fehlerpfad wurde separat geprüft: ursprüngliche Fehlersignatur
bleibt erhalten und ein anderer Prozess kann beide Registrar-Sperren erneut
erwerben, während der ursprüngliche Writer weiterlebt (Storage-Suite 16 PASS).
Der unabhängige Nachreview schloss beide Lifecycle-/Cleanup-Korrekturen ohne
weitere Findings. Rohlogs und Prozess-/Hostdaten bleiben ausschließlich lokal.

## Optionaler CMS-Readonly-Inspektor

Die Fixture CmsInspectionChecks wird durch Invoke-ConnectionCenterCmsChecks entdeckt. Notwendig sind tatsächliche PRE_SECRET_BARRIER-Fälle mit unverändertem Run/Runtime/Labels und verändertem Host/Port (SecretReads=0, SqlOpens=0), nullable/zero/feste DTO-Felder, aktuelle Bindung, eigener endlicher Worker, HTTP-Parametergrenzen, echter CLI-Einstieg/Cancel und JavaScript-Late-Response-/Cancel-Grenzen. Synthetische Grenzen führen keine Providerabfrage aus. Ausgewählte statische Suites und die tatsächlich gewählten Provider-Core-Gates bleiben erforderlich; vergangene B-/Capacity-Smokes decken diesen Source-Digest nicht ab. Eine allgemeine Docker-Core-Abnahme ist kein echter CMS-SQL-/SSMS-/Mitgliedsnachweis. Weitere Details im [CMS-Vertrag](../Architecture/CMS_READONLY_INSPECTION.md).

## Bewusster lokaler Operator-Handoff

Der [kanonische Handoff](../HowTo/OPERATOR_DIAGNOSTIC_HANDOFF.md) bindet die bestehenden Skills und den Operator an diese unveränderte API. Standard ist SkipReadiness für genau ein ausdrücklich ausgewähltes Ziel; zusätzliche Providerreadiness bleibt eine bewusste Entscheidung. Keine automatische Sammlung, Datei, Upload, zusätzliche Reader, Shellfreigabe oder Mutationsautorität. Historische Evidence, unbekannte Befunde und fehlende SQL-/Skillloader-Nachweise bleiben getrennt. Die ausführbare Rezeptfixture wird durch Invoke-SkillChecks entdeckt; ein Rezepttest ist kein Modelldispatch- oder Skillloadernachweis.

## Reine eigene llama.cpp-Startvorschau

`Tests/Static/Invoke-LlamaCppStartPlanChecks.ps1` führt den echten öffentlichen
Core und die bestehenden Files-only-Reader in einem isolierten Modul mit
synthetischen lokalen Dateien aus. Grenzen: exakte Installation, Backends,
CUDA-NPU, Dateimengen/Reparsepfade, GGUF-Magic, Metadatendrift, skalare Grenzen,
Pfadfreiheit, NOT_CHECKED und unverändertes Start-WhatIf. Gesperrte Start-,
Compute-, HTTP-, Secret- und Defaultgrenzen dürfen nicht erreicht werden.
Der Nachweis ist keine Geräte-, TLS-, Modell-, SQL- oder Providerabnahme.
Die tatsächliche Diffauswahl bleibt maßgeblich; ausgewählte, nicht ausgeführte
Provider-Smokes bleiben ausdrücklich NOT_EXECUTED.

### Geführte reine llama.cpp-Startvorschau

`Invoke-LlamaCppStartPlanConsoleChecks.ps1` führt den tatsächlichen Menü-/
Dialogpfad bis in Public-Core und bestehende Files-only-Reader auf synthetischen
Dateien aus. Console-Menüleaves werden gespeist; die echte Texteingabeleaf wird
mit isolierter Fallbackeingabe geprüft. Cancel an allen Schritten, MaskInput-
Semantik, exakte zehn Argumente/Defaults, skalare Grenzen, fremde Menü-IDs,
strikte sichere DTOs/Fehler sowie sichtbarer Drift und Reparse/GGUF-Vetos sind
erforderlich. Start/Stop, Compute, HTTP, Secrets und Defaults sind gesperrt.
Eigene Fixturedateien werden bereinigt. Keine empirische Tastatur-, Runtime-
oder Providerabnahme; die selektierten Pflichtgates bleiben separat.

### Geführte reine llama.cpp-Dateivorschau im Browser

`Invoke-LlamaCppStartPlanBrowserChecks.ps1` führt den tatsächlichen engen
HTTP-Handler bis Public-Core und bestehende Files-only-Reader sowie die
extrahierte echte UI-Route auf synthetischen Dateien aus. Erforderlich sind
strikte zehn Eingaben, UTF-8-Byte-/Zeichen-/JSON-Grenzen, Duplicate-/Case- und
Origin-Vetos, fehlende/unbekannte/coerced Parameter, sichere DTOs und feste
Fehlercodes, echte sichtbare Drift-, Reparse- und GGUF-Abweisung. Jobs,
Start/Stop, Runtime, Compute, Secrets und Defaults sind gesperrte Grenzen.
Die echte neue JavaScript-Datei prüft RAM-Eingaben, bewusste Vorschau, Cancel,
Busy-/Revision- und verspätete Erfolgs-/Fehlerantworten über DOM-/Fetch-Fixtures.
Das ist keine physische Browser-, Tastatur-, Modell- oder Nativeabnahme.
Eigene Fixturedateien werden bereinigt; alle tatsächlichen Diffselektor-Gates
und fehlenden Provider-Nachweise bleiben separat und unverändert verpflichtend.

### Geführter eigener llama.cpp-Start (CLI)

Invoke-LlamaCppStartConsoleChecks.ps1 prüft actual Menü, Handler, Public-ShouldProcess, isolierten Runtime-Leaf, SecureString-Consoleleaf und SessionView. Cancel vor jedem Schritt/Bestätigung startet nichts; WhatIf ist keine Bereitschaft. Strikte DTO-/Sessionbindung, unbestätigtes Ergebnis und compound Recovery zeigen keine Rohwerte und lösen keinen AutoStop/Retry aus. Nur synthetisch, keine physische Tastatur-, Prozess-, Modell-, TLS-, SQL- oder Providerabnahme. Tatsächliche Diff-Auswahl und ausgewählte Native-Gates bleiben maßgeblich; nicht ausgeführt ist kein PASS.

### Geführter eigener llama.cpp-Start (Browser)

Invoke-LlamaCppStartBrowserChecks.ps1 prüft tatsächlichen dedizierten HTTP-Handler,
unveränderten Public-ShouldProcess und isolierten privaten Runtime-Leaf sowie
extrahierte echte UI-Route im selben Modul. Pflichtfälle: Loopback-/Originbindung,
strict UTF-8/JSON/aggregierte Grenzen, fünfzehn explizite Scalars, bewusster START
versus WhatIf, effektive ConfirmPreference, Schlüsselentsorgung, strikte eigene
Session-/Port-/DTO-Bindung und feste unbestätigte/Recovery-Ergebnisse. Dateien,
Prozesse, Runtime und Netzwerk sind gesperrte Leaves. Die echte JS-Fixture prüft
RAM-Eingaben, Cancel vor/nach Versand, Busy und verspätete Erfolge/Fehler, noRetry,
Schlüsselclearing und feste textContent-Anzeigen. Keine echte Browser-/Tastatur-
oder Nativeabnahme; tatsächliche Diffselektion und fehlende Providerpflichten
bleiben separat. Bestehende Public-/Core-/CLI-/Preview-/Stopbytes bleiben erhalten.

Das optionale CORE-102-Identitätsmapping verwendet den bestehenden Indexvertrag
1.1; Legacyrecords bleiben unbekannt und unverändert. Public
`Get-SqlServerLabExternalRuntimeCapability -IncludeRecordedEvidence` liefert
Version 1.1 ohne aktuelle Evidence-Aufwertung. Das Tool verlangt beide Schalter
`-IncludeRecordedAcceptanceMatrix -IncludeRecordedIdentityMatrix` und liefert
Version 1.2 ausschließlich als begrenzte historische Identitätsmatrix, ohne
Quellinventar/Modulimport. Maximal 128 Records und 256 KiB UTF-8 für die komplette
neue Antwort; Überlauf bleibt leer/UNAVAILABLE. Referenzen sind NOT_VERIFIED,
aktuelle Ausführung NOT_EXECUTED und Readiness NOT_CHECKED. Alte Public-/Browser-
und Manifestdefaults bleiben unverändert. Reale neue Producerrecords, Native-/SQL-
Abnahme und vollständige Kombinationenmatrix bleiben offen.

Invoke-CapabilityEvidenceIdentityChecks.ps1 prüft den tatsächlichen Reader, Schema, Public/Resolver und die neue reine Toolmatrix: typisierte Identität, Capabilitybindung, Konflikthistorie, doppelte/falsch geschriebene JSON-Felder, Reparsegrenzen sowie vollständige UTF-8-Ausgabegrenze. Die synthetischen Dateien bleiben ignored lokal; keine neue Runtime-Abnahme.
## Eigener CI-Scope auf einem gemeinsam genutzten Windows-Host

`Invoke-OwnedHostIntegrationChecks.ps1` prüft typisierte Policy-/Runreferenzen,
geschützte eigene Dateirechte, Carrier, FullCID-/Volume-/Image-Originbindung,
Routingoverrides und Timeout-/Ausgabegrenzen mit synthetischen Ressourcen und
eigenen PowerShell-Kindern. Provider- und Taskeffekte sind gesperrt.
Die gekoppelte Schema-, RuntimeScope-, Doku- und CI-Auswahlprüfung bleibt
erforderlich. Native Docker-, Podman-, Mixed-, Hyper-V- und Adaptergates müssen
den stabilen Head getrennt belegen; Readiness und historische Evidence gelten
nicht als aktuelle Abnahme. Vor-/Nachschutz erfasst alle vorbestehenden
Ressourcen; Rohdiagnosen bleiben lokal. [Vertrag](../Architecture/OWNED_HOST_CI_ISOLATION.md).
## Eigene native Portvorschau-Abnahme – begrenzt bestanden

`Tests/Integration/Invoke-ContainerPortPreviewAcceptance.ps1` ist ein eigener,
owned-host-only Harness für je einen frischen Docker-/Podman-SQL-2025-Run.
`ContainerPortPreviewAcceptanceChecks.ps1` wird von ContainerReconcile ausgeführt:
actual Core/Console/HTTP-AST, synthetischer pinned NativeProcess-Leaf,
Statebytes und Instrument-Restoration auch nach Core-Veto; Cleanup-Drift muss
vor PublicRemove blockieren. Diese Offlinebelege sind keine native Abnahme.
Frische Parent-/State-Policies und Registration bleiben zusammen erhalten,
wenn Creation nicht zurückkehrt oder Cleanup/Absence nicht bestätigt ist.
Am 2026-10-05 auf `bee35c5d` bestanden getrennte frische Docker- und
Podman-Runs die reale Previewform: je fünf öffentliche Aufrufe für geänderten
Wunsch, No-op, Wiederholung, Console-Menüroute und in-process HTTP. Installation
war OWN_RUNNING_RUN_OBSERVED, Ressourcenbereitschaft RESOURCE_OK; dies ist
keine SQL- oder Endpointprüfung während der Preview. Je fünf Contextcaptures
und 18 pinned Reads schließen eigene Ownership-Revalidierungen ein; die
Statebytes blieben unverändert. Beide Runs endeten REMOVED, beide Cleanuppläne
COMPLETED mit je zwei Schritten und null Fehlern; gebundene terminale
Bytekopien, Ressourcenabwesenheit und Parententfernung wurden geprüft.
Der gleiche Vorher-/Nachher-ObservationRoot bestätigte unveränderte geschützte
sechs Umgebungen, Providerinventare, VMs, Aufgaben, Defaults, Registry und
eigene Autostarts; Schutzvergleich PASS ohne Findings oder Beobachtungen.
Die privaten Fehlerbelege früherer Wellen werden nicht umgewertet. Dieser
Nachweis ersetzt keinen kanonischen Provider-Gate. Browserrendering und
HTTP-Netztransport sind nicht Bestandteil; Preview-SQL/Endpoint bleiben
NOT_CHECKED, Port-Apply ist NOT_IMPLEMENTED.
Der Harness behauptet keinen einzelnen globalen Inspect: origin-/labelgebundene
Revalidierungen bleiben erhalten. Ein abgeschlossener Dialogrequest ruft die
öffentliche Preview einmal auf. Es gibt kein Apply und keinen Scope-A-Abschluss.
