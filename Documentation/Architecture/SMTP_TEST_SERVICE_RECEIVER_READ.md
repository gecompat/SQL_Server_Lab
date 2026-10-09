# Privater SMTP-Receiver-Lesetransport

## Geltungsbereich

`Private/SmtpTestServiceReceiverRead.ps1` implementiert einen privaten Raw-MIME-
Lesetransport für die spätere lokale SMTP-Testkomponente eines SQL-Labs. Er ist
keine öffentliche Funktion und provisioniert keinen Receiver. Die
[Manifestzulassung](MANIFEST_AND_INTERFACE_ARCHITECTURE.md#aktueller-smtp-manifest-zulassungsvertrag)
lehnt aktiviertes SMTP weiterhin mit `SMTP_TEST_BACKEND_UNADMITTED` ab.

Typisierte Eingaben sind kein Eigentumsnachweis. Ein zukünftiger Core-Aufrufer
muss vor Credentialöffnung die echte Komponentenidentität, vollständige native
Container-ID, Runtimebindung und genaue Loopback-Portzuordnung prüfen und nach
dem Read erneut gegen Drift validieren. Dieser Resolver und die öffentliche
API-/CLI-/GUI-Anbindung sind noch nicht implementiert. Mailinhalte dürfen nur
auf ausdrücklichen lokalen Leseauftrag weitergegeben werden; sie gehören nicht
in Logs, Jobs, Transcripts oder Diagnose-DTOs.

## Fester Request und Antwortvertrag

`Read-LabSmtpTestServiceReceiverRaw` akzeptiert ausschließlich eine tatsächliche
numerische Loopback-`IPAddress`, einen ganzzahligen Port und eine opake ID aus
genau 22 ASCII-Zeichen `[0-9A-Za-z]`. Der einzige Request ist
`GET /api/v1/message/{id}/raw`; freie URLs, DNS, Queryparameter und `latest`
werden nicht angenommen. Ein explizites transient übergebenes `PSCredential`
ist nur für den zukünftigen vertrauenswürdigen Core-Aufrufer vorgesehen.

Eine numerische TCP-Verbindung und die tatsächliche Peerprüfung erfolgen vor
Credentialöffnung. Ein frischer HTTP/1.1-Handler übernimmt den Stream genau
einmal über einen atomaren CLR-Handoff. Eine weitere ConnectCallback-Anforderung
wird abgelehnt; sie eröffnet keine zweite TCP-Verbindung. Der Request verwendet
HTTP/1.1 exakt, `Connection: close` und `Accept-Encoding: identity`. Proxy,
Cookies, Standardcredentials, Redirects und automatische Dekompression sind
deaktiviert.

Nur Status `200` und `Content-Type: text/plain` werden angenommen. Eine andere
Content-Encoding als `identity` wird abgelehnt. Der Body bleibt bytegenau,
einschließlich leerer und nicht UTF-8-dekodierbarer Inhalte; ein deklarierter
Charset bewirkt keine Textkonvertierung. Nicht erfolgreiche Antworten werden
nicht durch Anwendungscode als Inhalt gelesen oder ausgegeben. Der HTTP-Parser
kann bereits Netzwerkbytes gepuffert haben; dies ist kein Versprechen, dass
keine Bodybytes empfangen werden. Automatisches Response-Draining ist abgeschaltet.

Der Vertrag folgt den gepinnten Mailpit-Quellen am Commit
`ccb524a62b3a14b6a3fd55c1275a16945d10e36b`: [Raw-Handler](https://github.com/axllent/mailpit/blob/ccb524a62b3a14b6a3fd55c1275a16945d10e36b/server/apiv1/message.go)
und [Storage-Leseweg](https://github.com/axllent/mailpit/blob/ccb524a62b3a14b6a3fd55c1275a16945d10e36b/internal/storage/messages.go).
Raw-Lesen setzt keinen Read-Marker, aktualisiert aber `dbLastAction`; es ist
damit keine Zusage eines vollständig unveränderten Backendzustands.

## Grenzen, Fehler und Custody

Die gemeinsame kooperative Deadline beträgt zehn Sekunden für Preconnect,
Credentialöffnung, Request, Header und Body. Sie wird zwischen den Stufen nicht
erneuert. Header sind auf 16 KiB, Raw-MIME auf 8 MiB und einzelne Bodyreads auf
64 KiB begrenzt. Die Raw-Grenze ist unabhängig von der SMTP-DATA-Konfiguration.
Deklarierte Übergröße wird vor Inhaltslesen abgelehnt; unbekannte Länge und
Chunked werden während des Reads begrenzt. Übergröße, widersprüchliche Länge
und verspätete Completion liefern keinen Teilinhalt und keine Truncation.

Scratch- und Akkumulationsbuffer werden vor Freigabe geleert. Die erfolgreiche
Rückgabe ist ein eigener `byte[]`, dessen Custody der private Aufrufer übernimmt.
Während der finalen Kopie bestehen Akkumulationsbuffer und Rückgabe gleichzeitig;
dies ist keine harte RSS-, CPU- oder physische Löschgarantie. Alle eigenen
Streams, HTTP-Objekte, Socket und Tokenquelle werden unabhängig entsorgt.
Unbestätigter Cleanup vetoisiert die Ausgabe. Fehler enthalten feste Codes;
best-effort `Exception.Data` trennt Cleanupbestätigung und Recoverybedarf.
Fehlende Metadaten bedeuten unbekannten Cleanupstatus.

## Prüfung und offene Abnahme

Die [Receiver-Suite](../../Tests/Static/Invoke-SmtpTestServiceReceiverReadChecks.ps1)
verwendet die echte private Funktion mit eigenen synthetischen Loopback-Servern.
Sie prüft Inputvetos, binäre Identität, Leerinhalt, Größen-/Headergrenzen,
Framing, Status-/Encodingvetos, Deadline, fehlenden Replay und eigenen Cleanup.
Der [lokale Nachweis](../Quality/LOCAL_VALIDATION_STRATEGY.md#privater-smtp-receiver-lesetransport)
enthält 27 bestandene Fälle und einen getrennten Canceled-Connect-Kontrollfall.
Native Mailpit-/SMTP-, Docker-/Podman-, SQL- und Browserabnahme sowie die
Mindestlaufzeit PowerShell 7.2/.NET 6 bleiben offen. Der Transport begründet
weder öffentliche SMTP-Bereitschaft noch eine Provisionierungsfreigabe.
