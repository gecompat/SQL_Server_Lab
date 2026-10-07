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

Die sieben direkten Routen für Service-Secret-Prüfung, Batches, Operations,
Retained-/Run-Storage-Entfernungsplan, Actions und Commands verwenden
`Tools/WorkflowUiJsonBody.ps1` vor JSON-Verarbeitung und Fachaufrufen. Ein
deklarierter Body über 1 MiB wird vor der Pufferanlage mit 413 abgewiesen.
Auch bei unbekannter Länge/Chunked gilt die Bytegrenze: maximal ein Sentinelbyte
über dem Limit wird gelesen und nicht gepuffert. UTF-8 wird strikt decodiert;
ungültige Bytes ergeben 400. Alle Reads teilen eine absolute Frist von fünf
Sekunden; Timeout ergibt 408. Ein abgewiesener Requeststream wird geschlossen.
Feste Codes enthalten keine Bodywerte. Bestehende JSON-Tiefen und fachliche
Guards gelten nach erfolgreicher Transportlesung weiterhin.

Spezifische Adapter/Handler mit eigenen Readern erhalten dadurch keine neue
Deadline. Headerannahme, Dispatcher-Parallelität, Authentifizierung, Quotas und
vollständige JSON-Komplexitätsgrenzen bleiben separate offene Arbeit. Der
Cloud-Fund zu synchronen UI-Bodys bleibt deshalb offen; die neue Prüfung
belegt den begrenzten direkten Reader-Scope.

## Offene Autorisierungsgrenze

Diese HTTP-Prüfung ist keine Operatorauthentifizierung. Lokale JSON-Clients
ohne Origin-/Fetch-Site-Header bleiben kompatibel; GET ist nicht authentifiziert.
Ein lokaler Client kann Header selbst setzen. Es entsteht weder eine
per Start gebundene Operator-Capability noch eine einmalige servergebundene
Aktionsfreigabe. Bestehende fachliche Guards und Bestätigungen bleiben nötig.
Die vorgelagerte Headerprüfung selbst führt keine Bodylimits ein; der
separate direkte JSON-Reader ist oben beschrieben.

Der vom Benutzer priorisierte Security-Cloud-Scan vom 2026-10-07 auf
`f82976735c94d869e425d7082c04748ee97ddf65` meldete zwölf offene Findings
(drei mittel, neun niedrig). Der Loopback-Autorisierungsfund bleibt offen:
dieser Slice schließt die HTTP-Umschlaggrenze, nicht den gesamten Fund.
Der ältere Scan attestiert keinen späteren Repositoryhead. Neue Integrationen
müssen Findings und Scan-Scope/Freshness weiterhin getrennt bewerten.
Reale Diagnose- und Runtime-Rohdaten werden nicht in die Cloud hochgeladen.

## Nachweis

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
