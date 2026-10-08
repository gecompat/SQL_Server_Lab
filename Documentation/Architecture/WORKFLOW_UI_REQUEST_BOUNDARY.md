# Gemeinsame HTTP-Grenze der Workflow-Oberfläche

`Tools/WorkflowUiRequestBoundary.ps1` prüft jeden Request des lokalen Servers
vor Routing, Bodylesung und Job-/Batchanlage. Der Listener ist an
`http://127.0.0.1:<Port>/` mit Port 1025–65535 gebunden. Request-URI und
Hostheader müssen exakt dessen Authority verwenden; der Peer muss Loopback
sein. Mehrdeutige Host-, Origin-, Sec-Fetch-Site- und Content-Type-Header
werden abgewiesen.

Ein vorhandener Originheader muss exakt die Listener-Origin enthalten.
`null`, andere Ports, localhost und fremde Origins sind unzulässig. Ein
vorhandener Sec-Fetch-Site-Header erlaubt nur `same-origin` oder `none`.
GET und POST sind zulässig; andere Methoden erhalten 405. POST verlangt
`application/json`, optional ausschließlich `charset=utf-8` (auch quoted).
Andere Medientypen oder Zeichensätze erhalten 415. Authority-, Origin- und
Fetch-Site-Verstöße erhalten 403. Feste Fehlercodes spiegeln keine Eingaben;
der Server erteilt keine CORS-Freigabe.

## Begrenzte direkte JSON-POST-Routen

Die acht direkten Routen für Service-Secret-Prüfung, Batches, Operations,
Retained-/Run-Storage-Entfernungsplan, Actions, Command-Grants und Commands verwenden
`Tools/WorkflowUiJsonBody.ps1` vor JSON-Verarbeitung und Fachaufrufen. Ein
deklarierter Body über 1 MiB wird vor der Pufferanlage mit 413 abgewiesen.
Auch bei unbekannter Länge/Chunked gilt die Bytegrenze: maximal ein Sentinelbyte
über dem Limit wird gelesen und nicht gepuffert. UTF-8 wird strikt decodiert;
ungültige Bytes ergeben 400. Alle Reads teilen eine absolute Frist von fünf
Sekunden; Timeout ergibt 408. Ein abgewiesener Requeststream wird geschlossen.
Feste Codes enthalten keine Bodywerte. Bestehende JSON-Tiefen und fachliche
Guards gelten nach erfolgreicher Transportlesung weiterhin.

## Acht interne Fachreader

CMS-Inspection, Initial Setup, Slotreserve, Resource Watch, llama.cpp-Installer,
llama.cpp-Sitzungsstop, Wartungsreparatur und Medienoverrides verwenden nun
denselben Transportreader. Ihre bisherigen UTF-16-Zeichenlimits bleiben bei
4096 (CMS), 16384 (Setup, Slots, Medienoverrides) beziehungsweise 1024 Zeichen
(übrige vier Handler). Vor der Decodierung gilt zusätzlich eine Bytegrenze von
viermal diesem Zeichenlimit und eine absolute Lesefrist von fünf Sekunden.
Eine führende UTF-8-BOM wird wie bisher vor der Zeichenprüfung entfernt;
ihre Bytes zählen gegen die Transportgrenze.
Transportüberlänge ergibt 413, Timeout 408 und ungültiges UTF-8 400 mit festen
bodyfreien Codes. Zeichenüberlänge und fachliche Fehler behalten die bestehenden
Fehlercodes und 400-Antworten. Auch erfolgreiche Requeststreams werden geschlossen.
GET und alle vorhandenen fachlichen Bindungen und Bestätigungen bleiben erhalten.

Übrige spezifische Adapter/Handler erhalten dadurch keine neue Deadline.
Headerannahme, Dispatcher-Parallelität, Action-/Replayfreigaben, Quotas und
vollständige JSON-Komplexitätsgrenzen bleiben separate offene Arbeit. Der
Cloud-Fund zu synchronen UI-Bodys bleibt deshalb offen; die neue Prüfung
belegt den begrenzten direkten Reader-Scope.

## Startgebundene Operator-Capability

Die Umschlagprüfung bleibt von `Tools/WorkflowUiOperator.ps1` getrennt.
Der Server erzeugt je Start 32 kryptografisch zufällige Bytes und verlangt nach
der Umschlagprüfung vor jedem `/api/`-Dispatch den Header
`X-SqlServerLab-Operator` mit dieser Capability. GET, Statuspolling, Preview und
POST sind gleichermaßen geschützt. Fehlende, falsche oder mehrdeutige Werte,
inaktive Sitzungen und andere Listenerbindungen erhalten 403 mit
`UI_OPERATOR_REQUIRED`, ohne Bodylesung oder Fach-/Jobzugriff. Statische
Produktassets enthalten keine Capability und bleiben lesbar. Origin- und
Fetch-Site-Vetos gelten auch bei gültiger Capability; keine CORS-Freigabe.

Der Handoff liegt in einem frisch erzeugten privaten Runtimeverzeichnis
außerhalb des Repositorys. Windows setzt bereits bei Verzeichnisanlage eine
geschützte Owner-ACL; Unix verwendet 0700, die Datei 0600. Bestehende Reparse-/
Symlinkpfade werden abgewiesen. `operator.json` entsteht mit `CreateNew`,
enthält Listener, Startlink und Capability und bleibt unter einem Read-Handle
ohne Write-/Delete-Sharing. Startupausgaben enthalten nur die öffentliche
BasisURL und den privaten Dateilokator. Automatischer Browserstart verwendet
den Startlink; `-NoBrowser`, HTTP-CLI, weiterer Tab und Reload lesen dieselbe
Datei ausschließlich lokal. Kein Überschreiben, alter Startscope oder globaler
Credentialstore wird übernommen.

Windows behält den PowerShell-7.2-Mindeststand. Unter Unix benötigt allein der
UI-Handoff die atomaren UnixFileMode-APIs von .NET 7 oder neuer. Ein reflektierter
Featurecheck prüft die drei benötigten Create/Get/Set-Overloads, ohne auf .NET 6
den fehlenden Enumtyp aufzulösen. Fehlen sie, endet der Start vor Pfadauflösung,
Verzeichnisanlage oder Credentialerzeugung mit `UI_OPERATOR_UNIX_MODE_UNAVAILABLE`.
Ein engerer UI-Prerequisite ersetzt keinen Unix-Rechte-/Runtimebeweis.

`Ui/operator-transport.js` lädt vor allen Komponenten, übernimmt nur das exakte
Capabilityfragment, entfernt es sofort aus der Adress-/Historydarstellung und
hält den Wert in einer Closure. Kein DOM-, Log- oder Browserstorage-Export und
kein globales Fetch-Monkeypatch. Der benannte Transport authentifiziert nur
die eigene numerische Loopback-Origin und `/api/`-URLs, blockiert Redirects und
behält Header, Requestbody und AbortSignal. Reload ohne erneuten privaten
Startlink bleibt gesperrt. Lokale JSON-Clients ohne Origin-/Fetch-Site-Header
benötigen jetzt ebenfalls die Capability; die PowerShell-Cmdlet-/Konsolen-API
bleibt unverändert.

Beim Serverende wird die Capability inaktiv. Der Cleanup schließt den eigenen
Handle und entfernt nur das bestätigte unveränderte eigene Credentialartefakt
und sein leeres Verzeichnis, ohne rekursive Traversierung. Unbestätigte oder
veränderte Artefakte bleiben mit lokalem `UI_OPERATOR_CLEANUP_UNCONFIRMED`
für Recovery erhalten. Nach Prozessabbruch wird kein alter Temp-Scope gesucht
oder automatisch gelöscht; ein neuer Server erzeugt eine neue Capability.

Capabilitybesitz authentifiziert den Operator, keine menschliche Zustimmung
zu einer konkreten Aktion. Der folgende Einmalgrant schützt ausschließlich
HTTP-Commandannahme; die übrigen Action-/Replayfreigaben bleiben offen.
Fachliche Ownership-, Plan-, Secret-, Consent-, Elevations- und
Cleanupguards sowie vorhandene Bestätigungen bleiben nötig. Zugriff desselben
OS-Benutzers auf Browser-/Prozessspeicher oder den privaten Startkanal, XSS und
kompromittierte Assets sind dadurch nicht ausgeschlossen. Headerannahme,
übrige Reader und Statequotas bleiben separat.

## Einmalige HTTP-Commandannahme

Alle Requests an `POST /api/commands` benötigen zusätzlich einen frischen
Grant aus dem authentifizierten `POST /api/command-grants`. Der Issuer liest
dieselben exakten UTF-8-Bodybytes mit der bestehenden 1-MiB-/Fünfsekundengrenze.
Er validiert ausschließlich die JSON-Form, eindeutige Propertynamen, exportierten
Befehlsnamen, echten Parametersatz und Boolean-`confirmed`. Für einen laut
Katalog bestätigungspflichtigen Befehl muss `confirmed` tatsächlich `true` sein;
Strings werden nicht in Zustimmung umgewandelt. Kein Issuer führt den Befehl,
legt einen Job an oder ersetzt dessen Parameter-/Ownership-/Plan-/Consentguards.

Der neue `Tools/WorkflowUiCommandGrants.ps1` hält ausschließlich flüchtigen
Sitzungsstate: frische 256-Bit-Granttokens, getrennte Receipt-IDs, einen zufälligen
HMAC-Key und begrenzte Records. Im Store liegt nur der Tokenhash, die Bodylänge
und ein serverseitig geheim gekeyter Digest, niemals Body, Commandparameter oder
Grantklartext. Die Bindung umfasst dieselbe aktive Operatorobjektidentität und
Capability, Listener-Origin sowie kanonisch `POST /api/commands`. Wie bestehendes
PowerShell-Routing sind Pfadvergleiche case-insensitive; `/API/Commands` ist dieselbe
Route. Querys, andere Methoden, Issuer-/Fremdrouten und andere Listener werden
abgewiesen. Bodybindung gilt einschließlich Whitespace, BOM, Escapeform,
Ziel-, Plan-, Consent- und Secretwerten. Der Reader liefert Rawbytes nur per
internem Opt-in; beide Caller nullen sie im `finally` nach Erfolg und Fehler.
Das bestehende ReaderDTO ohne Opt-in bleibt unverändert.

Der Issuer antwortet mit `{grant,receiptId,expiresInMilliseconds}`. Der Client
sendet den Grant ausschließlich als einzelnen `X-SqlServerLab-Action-Grant`-
Header und dieselben Bytes an Commands. Unter einer gemeinsamen Monitor-Sperre
prüft der Server die monotone 60-Sekunden-Frist nach vollständiger Bodylesung
und nochmals unmittelbar vor Verbrauch. `ISSUED` wird vor Threadjobanlage
unwiderruflich `CONSUMED`; der Bodydigest wird dabei genullt. Jobanlage ergibt
`ACCEPTED` mit Job-ID oder bei ungeklärtem Fehler `UNCONFIRMED`. Eine verlorene
HTTP-Antwort stellt den Grant nicht wieder her. Doppelverbrauch, fremde Bindung
und abgelaufene Grants erhalten den festen 403-Code `UI_COMMAND_GRANT_REQUIRED`.
Ungültige Commandform erhält 400 `UI_COMMAND_REQUEST_INVALID`; sonstige Fehler
bleiben bodyfrei `UI_COMMAND_UNCONFIRMED`.

Authentifiziertes `GET /api/command-grants/<receiptId>` liefert ausschließlich
`{receiptId,state,jobId}`. `POST /api/command-grants/<receiptId>/cancel` mit exakt
`{}` (maximal 1024 Bytes, fünf Sekunden) widerruft nur ein noch gültiges `ISSUED`
Record zu `CANCELLED`. Abgelaufene Records werden `EXPIRED`; angenommene oder
unbestätigte Records bleiben unverändert. Widerruf oder Fetch-Abbruch stoppt
keinen angenommenen Fachjob. Alle Grantendpunkte verwenden feste Fehler ohne
Body-/Parameter-/Digest-/Capabilityreflexion und bleiben hinter beiden zentralen
Header-/Operatorgrenzen.

Die Sitzung besitzt ein hartes Gesamtbudget von 256 Receipt-Slots. Auch
abgelaufene, widerrufene und terminale Records bleiben bis zum Serverende belegt;
es gibt keine Eviction aktiver oder alter Receipts. Die 60-Sekunden-Frist gilt
nur für unverbrauchte Grants. Volles Budget ergibt 429 `UI_COMMAND_GRANT_CAPACITY`
und eine klare Browsermeldung; keine automatische Wiederholung oder Neustart.
Vor einem bewusst gewählten Serverende sind laufende Jobs und Recovery zu prüfen.
Der begrenzte Servercleanup nullt den HMAC-Key und alle verbliebenen Bodydigests,
leert beide Indizes und löst die Operatorbindung.

`submitUiAction` serialisiert Commandeingaben einmal. Beide begrenzten Browser-
POSTs verwenden dieselbe String-/UTF-8-Darstellung; Grant und Body bleiben im RAM.
Ein bekanntes Receipt mit unbrauchbarem Grant wird vor Commandübermittlung
widerrufen. Nach begonnener Übermittlung gibt es weder Replay, Regrant noch
automatischen Widerruf. Bei unbekannter Annahme behält nur die sichere Receipt-ID
in der Meldungskarte die explizite Statusabfrage bei; Grant und Body werden nicht
gerendert. HTTP-CLI benutzt denselben Zweischritt; native
PowerShell-/Konsolenbefehle behalten ihre bisherige fachliche Semantik.

Dieser Vertrag verhindert Wiederannahme desselben Grants innerhalb einer
Serversitzung. Ein neuer ausdrücklich gewünschter Grant ist eine neue
Anforderung, keine persistente Bodyidempotenz. Andere Aktionsrouten, generische
Batch-/Operationspfade, harte Prozessunterbrechung, tatsächliche menschliche
Zustimmung, Zugriff desselben OS-Benutzers und XSS bleiben ausdrücklich offen.

Der vom Benutzer priorisierte Security-Cloud-Scan vom 2026-10-07 auf
`f82976735c94d869e425d7082c04748ee97ddf65` meldete zwölf offene Findings
(drei mittel, neun niedrig). Der Loopback-Autorisierungsfund bleibt offen:
Umschlaggrenze und Operatorbindung schließen nicht den gesamten Fund.
Der ältere Scan attestiert keinen späteren Repositoryhead. Neue Integrationen
müssen Findings und Scan-Scope/Freshness weiterhin getrennt bewerten.
Reale Diagnose- und Runtime-Rohdaten werden nicht in die Cloud hochgeladen.

## Nachweis

Die Characterization am integrierten `46bdd994` nahm denselben Commandbody
zweimal am tatsächlichen Routeblock an und wandelte `confirmed:"false"` in
Zustimmung um. Nur ein synthetischer Jobsink wurde ausgeführt. Danach bestand
`WorkflowUiCommandGrantsChecks.ps1` mit 61 Prüfungen, darunter 23 echte HTTP-
Requests über den vollständigen Produktrequestblock. Zwei echte Threadconsumer
erzeugen genau einen Verbrauch; langsame Bodylesung lässt einen Grant vor
Consume ablaufen. Ziel-/Plan-/Consent-/Transient-/Whitespace-/Escape-/BOMdrift,
fremde Bindungen, Mehrdeutigkeit, Jobfault, Widerruf, sichere Receipts, Quota und
genullte tatsächliche Rawbytebuffer sind geprüft. Die Commandausführung wurde
dreimal ausschließlich als synthetischer Jobversuch erreicht, immer nach Consume.
Eigener Listener und Threadjobs wurden entfernt; Produktmodul, State, Provider
und SQL wurden nicht ausgeführt.

`WorkflowUiCommandGrantsChecks.cjs` bestand mit 30 Prüfungen am tatsächlichen
Browsercode: einmalige Serialisierung, gleiche Bodies, separater Header,
Timeout/Abort, verlorene Issue-/Annahmeantwort ohne Replay, Widerruf vor Annahme
und klare Quotaantwort. Null-/Array-/Objekt-DTOs und nichtstringförmige Grant-/
Receipt-/Jobfelder werden ohne Typkoerzierung abgewiesen; neun missgebildete
Issuerantworten erzeugen keinen Command-POST, sieben missgebildete Annahmeantworten
bleiben ohne Replay unbestätigt. Synthetischer Transport/DOM sind kein gerenderter Beweis.
Die gekoppelten Operator-/Boundary-/Body-Fixtures bestanden mit 50/48/37 Checks
und nun 14/14/15 HTTPrequests einschließlich echter Grantissuance für erlaubte
Commandrequests. Der Jobstatus-JS-Vertrag bestand mit 30 Checks. Historische
Nachweise darunter behalten ihren früheren Scope; breitere Gates bleiben bis
zur tatsächlichen Ausführung offen.

Die separate gerenderte Commandabnahme vom 2026-10-08 am eingefrorenen ersten
19-Dateien-Stand bestand (`run-ba748315d069443e82dd054fa909669d`): alle 13
Produktassets und der vollständige Produktrequestblock, zwei ausschließlich
synthetische Commands nach tatsächlichem Consume, sechs HTTP-Negativfälle und
ein realer Verlust der 202-Antwort ohne automatische Wiederholung. Eigener
Grantstore, Operatorsitzung, Browser und Listener wurden geschlossen. Produktmodul,
State, SQL, Provider und vollständige Fachcoreausführung blieben `NOT_EXECUTED`.
Der anschließende enge JS-DTO-Fix ist durch die 30 JS-Prüfungen belegt. Sein
gezielter gerenderter Nachlauf bestand ebenfalls
(`run-9b0bdefc634a4f459ca319ae68a8ae3b`): 13 Produktassets, zwei synthetische
Commands mit zweimal nachgewiesenem Consume vor Jobanlage, sechs HTTP-Negativfälle,
zwei sichere Receipts und ein tatsächlicher Verlust der 202-Antwort ohne Replay.
Keine Seitenfehler oder instrumentierten verbotenen Effekte wurden beobachtet;
eigener Browser, Listener, Operatorsitzung und Grantstore wurden geschlossen.
Alle 19 Quellen blieben während des Nachlaufs unverändert. Produktmodul, State,
SQL, Provider und vollständiger Fachcore bleiben `NOT_EXECUTED`. Unabhängiger
Review, breitere betroffene Prüfungen und Pflichtgate am exakten PR-Head vor
Integration bleiben die erforderlichen nächsten Gates.

Der Operator-Slice wurde am 2026-10-08 zunächst charakterisiert: ein lokaler
headerloser APIrequest passierte die vorhandene Umschlaggrenze, ohne einen
geschlossenen Body zu lesen. `WorkflowUiOperatorChecks.ps1` bestand danach
mit 50 Checks, darunter zwölf echte Loopback-HTTP-Requests am vollständigen
Produktrequestblock: unautorisierte GETs/POSTs einschließlich Groß-/
Mischschreibungen und `/api` erreichen keine Fachaktion; eine gültige
Capability umgeht keinen fremden Origin. Nur drei autorisierte Reads/Commands
erreichen synthetische Sinks. Eigene Windows-Handoffartefakte, Listener und
Threadjob wurden geschlossen/entfernt. Keine Produktmodule, State-, Provider-
oder SQL-Operationen. Deterministische Plattform-/Featureentscheidungen und
frühe Preflightreihenfolge sind geprüft; Unix-Rechte bleiben bis zur Ausführung separat.

`WorkflowUiOperatorTransportChecks.cjs` bestand mit 38 Checks am tatsächlichen
JS-Transport, mit synthetischem Native-Fetch: sofortiger History-Scrub,
fehlende/missgebildete Capability, andere Origins/Ports, kein Redirect,
unveränderte Body-/Header-/Abortsemantik, kein Browserstorage-/DOM-/Logzugriff
und Migration aller zehn aktiven Komponenten. Dies ist kein gerenderter
Browsernachweis. Die vorhandenen Boundary-/Body-Fixtures wurden mit gültigem
synthetischem Credentialbootstrap erneut ausgeführt; ihre Header-, Byte-,
UTF-8- und Timeoutvetos bleiben wirksam. Historische Nachweise darunter behalten
ihren ursprünglichen Scope.

Die echten NoBrowser-SA-/AutoStart-Driver lesen künftig nur den privaten
Dateilokator aus ihrem gebundenen Readyrecord und den Handoff lokal im
Driverprozess. Ihre Raw-Requests senden denselben Credentialheader. Isolierte
CMS-/Collation-/External-Languages-/Port-Dialoglistener verwenden dagegen einen
ausdrücklich synthetischen Fragmentbootstrap für den tatsächlichen Transport;
dies belegt keine zentrale Operatorauthentifizierung. Neue gerenderte/nativ
mutierende Driverabnahmen und der Pflichtgate am veröffentlichten Head bleiben
bis zu ihrer tatsächlichen Ausführung offen.

Ein separat quellgebundener lokaler Edgeharness bestand am 2026-10-08 mit
dem vollständigen Produktrequestblock, den tatsächlichen Helpers und allen
13 Produktassets. Sieben authentifizierte APIresponses belegen Bootstrap,
Jobpolling und gerendertes CMS-GET/POST gegen ausschließlich synthetische
Fachsinks. Fehlendes Fragment erzeugt keinen APItransport; fünf Requests mit
falschem Fragment und acht direkte unautorisierte HTTP-Requests erhalten 403.
Fragment, Capability und Startlink bleiben aus DOM, Storage und Responses
entfernt; keine Scriptfehler. Quellhashes sind vor/nach der Abnahme identisch.
Eigener Browser, Listener und Credentialscope wurden geschlossen. Produktmodul,
State, SQL und Provider wurden nicht ausgeführt. Dieser zentrale Guardnachweis
ersetzt keine native Abnahme der angepassten SA-/AutoStart-Driver.

`Tests/Static/Fixtures/WorkflowUiRequestBoundaryChecks.ps1` ist in die
WorkflowUI-Suite eingebunden. Die fokussierte Prüfung bestand am 2026-10-07
mit 48 Checks: zwölf echte Loopback-HTTP-Requests über die aus dem Server-AST
extrahierten unveränderten Gate-/Routinganweisungen, neun POST-Vetos vor dem
Parsen eines absichtlich ungültigen Bodys, ein OPTIONS-Veto ohne Body und zwei erlaubte Requests
an einen ausschließlich synthetischen Job-Sink. Header-/Authority-Grenzen
werden zusätzlich mit einem bereits geschlossenen Body-Stream geprüft.
Produktmodul, State, SQL und Provider werden dabei nicht ausgeführt. Der eigene
Listener und Threadjob werden geschlossen/entfernt. Ein gerenderter Browser,
Operatorauthentifizierung und native Provideraktionen sind damit nicht geprüft.

`WorkflowUiJsonBodyChecks.ps1` bestand mit 35 Checks und 13 echten HTTP-Requests
über den vollständigen gemeinsamen Produkt-Requestblock mit synthetischen
Fach-Sinks. Sieben Überlängenheaders ohne Body, Chunked-Überlänge, ungültiges
UTF-8 und ein tatsächlicher Trickle-Body erreichen keine Fachaktion. Nach dem
Timeout erreichen drei gültige Requests ausschließlich synthetische Command-,
Refresh- und Batch-Sinks. Der eigene Listener und Threadjob werden entfernt;
Produktmodul, State, Provider und SQL sind NOT_EXECUTED. Hinzu kommen
Sentinel-, exakte Byte-, UTF-8- und absolute Deadlineprüfungen mit eigenen
synthetischen Streams. Das ist kein gerenderter Browser- oder Providernachweis.

`WorkflowUiSpecializedBodyChecks.ps1` prüft den vollständigen gemeinsamen
Produkt-Requestblock und die acht tatsächlichen Fachadapter über einen eigenen
Loopback-Listener. 58 Prüfungen mit 36 HTTP-Requests bestanden: deklarierte und
Chunked- und Zeichenübergröße für jeden Handler, gültige fachliche Requests, ungültiges UTF-8,
ein echter Trickle-Timeout und ein gültiger Folgeaufruf. Mehrbyteige Texte am
exakten Zeichenlimit, führende UTF-8-BOM und Zeichenüberlauf sind separat geprüft. Alle Fach-Sinks
sind synthetisch, das Produktmodul, State, Provider und SQL nicht ausgeführt.
Listener und Threadjob wurden geschlossen. Der selektierte SQL-Lifecycle-Smoke
bestand getrennt für Docker und Podman mit jeweils 32/32 Prüfungen und eigenem
Cleanup. Die sechs geschützten Umgebungen liefen weiter; ihre gelesenen State-,
Bindungs- und nativen Inventarwerte blieben im Vorher-/Nachhervergleich gleich.
Der Vergleich ist kein atomarer Snapshot oder hostweiter Invarianznachweis.
