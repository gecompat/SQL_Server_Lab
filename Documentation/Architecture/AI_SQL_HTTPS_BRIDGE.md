# SQL-seitige Embeddings über einen eigenen HTTPS-Gateway

Stand: 2026-09-21. Interner Docker-only-Referenzslice mit vorbereiteter nativer
Abnahme; SQL-/TLS-Nachweis nach der Eingabereaderkorrektur `NOT_EXECUTED`.
Vorherige native Versuche endeten im SQL-Timeout, während der Gateway noch vor
seiner Verarbeitungsschleife blockierte. Keine neue öffentliche Gateway-API.
Die reine Docker-Netzprobe erreichte bereits einen ausschließlich an
`127.0.0.1` gebundenen Hostlistener über `host.docker.internal`. Eigener
kurzlebiger Container und Listener wurden vollständig entfernt. Dieser
TCP-Nachweis belegt weder TLS noch SQL-Vertrauen.

## Datenweg

```text
eigener SQL-2025-Docker-Run
  -> HTTPS host.docker.internal:flüchtiger-Port/api/embed
  -> eigener Hostprozess, TcpListener ausschließlich 127.0.0.1
  -> HTTP 127.0.0.1:11434/api/embed, bestehendes embeddinggemma:latest
```

`CREATE EXTERNAL MODEL` verwendet `API_FORMAT='Ollama'`,
`MODEL_TYPE=EMBEDDINGS` und `retry_count=0`. Drei feste synthetische Dokumente
und zwei feste Fragen stehen in `Get-LabAiSqlHttpsFixture`. SQL erzeugt und
speichert `VECTOR(768)` selbst. Exakte Cosine-Suche muss beide erwarteten Top-IDs
vor und nach SQLrestart liefern; sieben Embeddingrequests sind vorgesehen.
Golden v1, Cloud, Podman, Hyper-V, beliebige Dokumente, Modellwechsel und ein
allgemeiner Gatewaybetrieb bleiben außerhalb dieses Referenzvertrags.

## Besitz, Authentisierung und Grenzen

- Ein operationgebundener neuer SQL-Run besitzt genau ein eigenes Volume.
  Run, Scope, Operation, Container-ID, Runtime, Loopback-SQL-Port und
  Volume-Labels/Attachments werden live geprüft. Keine Adoption bestehender Runs.
- Der Gateway startet verborgen mit Prozessobjekt und Startzeitbindung nach
  lokalem Startrecord. Authentisierung und Modellbindung gelangen über stdin
  zum Kindprozess, niemals über Prozessargumente. Ein gemeinsamer eigener
  `StreamReader` auf `Console.OpenStandardInput()` liest Konfiguration und
  asynchron das Stoppsignal; er erhält gepufferte Eingaben zwischen beiden
  Phasen. Stoppsignal oder EOF beendet die Annahmeschleife kooperativ.
- Eine flüchtige CA signiert den gültigen Servernamen. Nur ihr öffentlicher
  Anteil wird nach `/var/opt/mssql/security/ca-certificates` im eigenen
  SQL-Volume kopiert; kein privater CA-Key und kein Hosttrust-Import.
  Anschließend startet ausschließlich der eigene SQL-Run neu.
- Der Authheader liegt in einer eigenen `DATABASE SCOPED CREDENTIAL` mit
  `IDENTITY='HTTPEndpointHeaders'`. Token und Masterkey-Passwort werden über
  kurzlebige ADO-Kommandoparameter übergeben. Keine Rohfehler, Header oder Texte
  in Receipts.
- Nur `POST /api/embed`, JSON mit genau `model` und einem einzelnen festen
  `input`. Doppelte JSON-/HTTP-Felder, Transfer-Encoding und fremde Inhalte
  blockieren. Header maximal 8 KiB, Body maximal 4 KiB; gemeinsames
  Requestread-Budget fünf Sekunden.
- Fester Loopback-Upstream ohne Proxy, Redirects oder Retries. Version,
  Capability, lokaler Modellstatus und Digest werden vor und nach jeder Inferenz
  gebunden. Exakt 768 endliche Werte sind Pflicht. Dienstmeldungen sind keine
  Modellattestierung.
- Höchstens acht Embeddingversuche und zwanzig Gatewayverbindungen. Upstream
  einschließlich Metadaten: 24 Sekunden; TLS-Handshake: fünf Sekunden;
  SQL-Kommandos: 45 Sekunden. Nach 15 Minuten nimmt der Gateway keine weiteren
  Requests an; ein bereits laufender begrenzter Request kann noch abschließen.
  Cleanup wartet höchstens 55 Sekunden auf kooperatives Prozessende, danach
  kontrollierter Abbruch mit sichtbarem Fehler.

Drei unterschiedliche Listenerports mit gültigem Zertifikat, falscher CA und
falschem SAN erzwingen frische TLS-Verbindungen. SQL-Negativtests müssen sowohl
die neuen Verbindungen und TLS-Ablehnungen vor HTTP im Receipt als auch
SQL-Verbindungsfehler nachweisen.
Auth-/Payload-Negative dürfen den Embeddingzähler nicht erhöhen.

Cleanup stoppt den eigenen Gatewayprozess, entfernt den vollständig gebundenen
SQL-Run und bestätigt Container-/Volume-Abwesenheit. Erst danach werden eigene
temporäre Dateien entfernt und `PASS` erlaubt. Unbestätigte Bindung oder
Cleanupfehler behalten State für Recovery. Auch nach einem Gatewaystartfehler
vor Rückgabe erlaubt nur bestätigtes Prozessende das Dateicleanup.
Lokale ignorierte SQL-Diagnose enthält ausschließlich Phase und numerische
Fehlerfelder `Number`, `Class`, `State`, die numerische SQL-Fehlerliste und
`NativeErrorCode`, keine SQL- oder Fehlermeldung.
Keine Wiederholung ungewisser
Inferenz, Name-only-Löschung, Prune, Modell-Pull oder Hostdienständerung.

## Primärquellen und offene SQLPAL-Annahme

Microsoft dokumentiert HTTPS, Ollama, Credentialbindung und Retryoptionen unter
[CREATE EXTERNAL MODEL](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-external-model-transact-sql?view=sql-server-ver17).
Aktivierung `external rest endpoint enabled`, Header-Credentials, Timeouts und
Redirectablehnung stehen im
[REST-Vertrag](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-invoke-external-rest-endpoint-transact-sql?view=sql-server-ver17).
Die [Embeddingfunktion](https://learn.microsoft.com/en-us/sql/t-sql/functions/ai-generate-embeddings-transact-sql?view=sql-server-ver17)
bindet das Modell innerhalb der SQL-Abfrage.

SQLPAL-CA-Pfad und Einlesen beim SQLstart sind für
[S3-Backup über HTTPS](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/sql-server-backup-to-url-s3-compatible-object-storage?view=sql-server-ver17)
dokumentiert. Ihre Übertragung auf External Models ist bis zum tatsächlichen
SQL-Positivnachweis samt WrongCA/WrongSAN-Negativen eine **unbestätigte Annahme**.
.NET-TLS oder Betriebssystem-Trust genügen nicht als SQL-Nachweis. Die Hostadresse
steht im [Docker-Desktop-Netzwerkvertrag](https://docs.docker.com/desktop/features/networking/networking-how-tos/);
die lokale Loopbackroute wurde zusätzlich direkt geprüft.

Microsoft beschreibt, dass
[`Console.In.ReadLineAsync()` synchron liest](https://learn.microsoft.com/en-us/dotnet/api/system.console.readline).
Damit darf dieser Reader nicht vor der Gateway-Verarbeitungsschleife auf STOP
warten. Ein bereits gestarteter Socket und veröffentlichter Readyrecord beweisen
noch keine laufende Requestverarbeitung; auch der Verbindungszähler wird erst
innerhalb dieser Schleife erhöht.

## Abnahme

```powershell
./Tests/Static/Invoke-AiSqlHttpsBridgeChecks.ps1
./Tests/Integration/Invoke-AiSqlHttpsBridgeAcceptance.ps1 -LocalPort 11434
```

Statisch: Requestbytes, Vektoren, Doppelbindung und eigener Zertifikat-/Prozess-
zyklus ohne SQL oder Modellrequests. Der echte Loopbacktest prüft vor STOP einen
TCP-Abbruch und einen per eigener CA und SAN validierten TLS-Request ohne
Authheader: HTTP 401, erhöhte Verbindungs-/Request-/Ablehnungszähler und weiterhin
kein Upstreamrequest. Ein separater EOF-Fall bestätigt kooperatives Prozessende.
Diese Prüfung belegt den Hostgateway, nicht den SQLPAL-Trust.
Nativ erforderlich: vorhandenes Hostmodell,
Docker, globaler Runtime-Mutex über Arrange und Cleanup, SQL-Embeddings,
Negativfälle, Ranking, SQLrestart und vollständiges Cleanup.

Die eng benannten Bridge-Dateien wählen Docker. Änderungen am gemeinsamen
AI-Core behalten dessen Providerbreite. Änderungen am Selector selbst aktivieren
unverändert die breiteren CI-Infrastruktur-Gates; Nachweise bleiben getrennt.
