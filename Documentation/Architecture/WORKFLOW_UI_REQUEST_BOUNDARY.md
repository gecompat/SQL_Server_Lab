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

## Offene Autorisierungsgrenze

Diese HTTP-Prüfung ist keine Operatorauthentifizierung. Lokale JSON-Clients
ohne Origin-/Fetch-Site-Header bleiben kompatibel; GET ist nicht authentifiziert.
Ein lokaler Client kann Header selbst setzen. Es entsteht weder eine
per Start gebundene Operator-Capability noch eine einmalige servergebundene
Aktionsfreigabe. Bestehende fachliche Guards und Bestätigungen bleiben nötig.
Auch Request-Bodylimits werden durch diese Prüfung nicht eingeführt.

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
