# SMTP-Testservice: private Offline-MIME-Projektion

Status: `PRIVATE_OFFLINE_IMPLEMENTATION`. Dieser Vertrag beschreibt die
vorhandene MIME-Projektion für explizit übergebene lokale Bytes. Er aktiviert
keinen SMTP-Receiver und eröffnet keine öffentliche Core-, CLI- oder GUI-API.
Die [Manifestzulassung](MANIFEST_AND_INTERFACE_ARCHITECTURE.md#aktueller-smtp-manifest-zulassungsvertrag)
blockiert aktive Konfiguration weiterhin mit `SMTP_TEST_BACKEND_UNADMITTED`.

## Eingaben und Ausgabe

`Invoke-LabSmtpTestServiceMimeProjection` akzeptiert ausschließlich den exakten
Selektor `Decoded` oder `Mime` und ein tatsächliches `byte[]`. Ungültige Typen
und zu große Eingaben werden vor Pythonauflösung und Prozessstart abgewiesen.
`Mime` erhält die Originalbytes bis einschließlich 8 MiB ohne Dekodierung,
Normalisierung oder erneute Serialisierung. `Decoded` akzeptiert höchstens
1 MiB MIME-Eingabe; ein größerer Raw-Read ist dadurch nicht automatisch als
dekodierbarer Inhalt zugelassen.

Die dekodierte Antwort besitzt genau elf Felder: `SchemaVersion`, `Subject`,
`From`, `To`, `MissingHeaders`, `BodyKind`, `BodyStatus`, `Body`, `SelectionRule`,
`PartCount` und `IgnoredPartCount`. Der PowerShellreader prüft striktes UTF-8,
geschlossene JSON-Schlüssel, Duplikate, tatsächliche Typen und semantisch
konsistente Feldpaare. Fehlende Header bleiben ausdrücklich `null` mit
zugehöriger Kennzeichnung; ungültige Inhalte werden nicht ersetzt.

Plaintext wird bevorzugt. `multipart/alternative` verwendet den letzten
geeigneten Plaintext, sonst den letzten geeigneten HTML-Teil; `related` bindet
seinen angegebenen Root, `mixed` den ersten geeigneten Body. Dateiname und
Attachment-Disposition schließen einen Teil als Body aus. HTML bleibt
`HTML_SOURCE`, also wörtlicher Text. Es gibt weder Rendering noch externe
Fetches. Unbekannte Multipartformen liefern einen ausdrücklichen Status.

## Feste Grenzen

| Grenze | Wert |
|---|---|
| Raw-MIME | 8 MiB |
| Decoded-Eingabe | 1 MiB |
| Decoded-JSON | 512 KiB |
| Body, UTF-8 | 256 KiB |
| Einzelner projizierter Header, UTF-8 | 4096 Byte |
| Parts / Verschachtelung | 64 / 8 |
| Python-Cooperative-Deadline | 5 Sekunden |
| Prozessoperation | 10 Sekunden |
| Unabhängiges Wait / Pipe-Drain | je 5 Sekunden |
| Stderr | 256 Byte |

Der Pythonparser begrenzt zusätzlich Zeilen, Headerbytes und Feldzahlen vor
weiterer Verarbeitung. Ressourcen werden nicht als harte RSS-/CPU-Quote
beworben. Python kann interne unveränderliche Kopien besitzen; Buffer-Clear ist
kein Beleg physischer Speicherlöschung.

## Prozess- und Fehlervertrag

Jeder neue PowerShellprozess löst Python über
`Initialize-SqlServerLabHostTools.ps1 -Name python` auf und verwendet den
absoluten `Invocation`-Pfad. Der eigene Prozess erhält feste Argumente
`-I -B`, den Repositorydecoder und den Selektor. Mailbytes liegen ausschließlich
auf stdin; Shellargumente, Dateien und Diagnostik enthalten keine Mailinhalte.
Die Umgebung wird geleert und nur die drei vorhandenen Windows-Prozesswerte
`SystemRoot`, `WINDIR` und `ComSpec` übernommen. Persistierter PATH bleibt
unverändert; der aufrufende Testentry stellt seinen Prozess-PATH wieder her.

Ein Erfolg verlangt Exit 0, leeres stderr, vollständige begrenzte stdout-Bytes
und bestätigte Custody. Teilstdout bei einem Fehler wird nicht geliefert.
Ein Nichtnull-Exit darf nur einen vollständigen festen Fehlercode mit LF oder
CRLF transportieren. Der Vergleich ist ordinal und verwirft auch eingebettetes
NUL, zusätzliche Zeichen und kulturell ähnliche Strings.

Inputabschluss, Kill, Wait, Drain und Dispose werden unabhängig geprüft.
Unbestätigter Abschluss liefert keine Payload und bleibt Recoverybedarf. Eine
einzige RAM-Custody kann noch laufende IO-Buffers halten; erneute Ausführung ist
bis ihrer belegten Auflösung gesperrt. Kein automatischer Reaper oder Retry
übernimmt fremde Prozesse. Diagnostics enthalten feste Codes und Custody,
keine MIME-Bytes, rohen Exceptions oder Stacks.

## Reguläre Offlineprüfung

`Tests/Static/Invoke-SmtpTestServiceMimeParentChecks.ps1` startet zuerst die
unveränderte Pythonfixture mit ihren 63 festen Fällen über denselben begrenzten
Bytetransport. Ihr stdout ist auf 16 KiB begrenzt; der Entry prüft 63 geordnete
PASS-Zeilen und eine geschlossene Summary mit passenden Zählern und
`SourceStable=true`. Danach läuft die Parentfixture mit 13 Fällen,
einschließlich tatsächlichem Pythontransport, Timeout und synthetischen
Custody-/Recoverygrenzen. Die Parentfixture erhält eigene erzeugte Dateien zur
lokalen Evidence-Erhaltung; sie entfernt keine fremden oder historischen Roots.
Unter Windows setzt sie für jede neu exklusiv erzeugte Pythondatei vor
Hashregistrierung und Kindstart den aktuellen Benutzer als Eigentümer. Die
vorhandene DACL und die abschließenden Eigentums- und Inventarprüfungen bleiben
erhalten; ein ACL-Fehler bleibt ein Fehler des Pakets.

Vor und nach dem Paket werden die sieben direkten Quellen erneut gehasht.
Die fünf MIME-Pfade wählen exakt diese Suite. Der bestehende Docker-Fallback
für unbekannte Produktdateien und alle fünf Infrastruktur-Gates bleiben
unverändert. Eine solche CI-Auswahl beweist keinen SMTP-Providerbetrieb.

Frühere einzelne 63-, MP10-, Ordinal- und Bytetransportnachweise bleiben mit
ihrem damaligen Sourceumfang erhalten. Sie werden nicht als vollständiger
13-Fall-Erfolg dieses neuen Pakets zusammengesetzt. Ausgeführte Nachweise und
offene Runtimegrenzen stehen in der
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md#private-smtp-offline-mime-projektion)
und den [Known Limitations](../Quality/KNOWN_LIMITATIONS.md#smtp-private-offline-mime-projektion).

Die erste vollständige Prüfung des regulären Offlinepakets bestand am
2026-10-09 separat mit 63 Python- und 13 Parentfällen unter Python 3.14.7 sowie
PowerShell 7.6.6/.NET 10.0.12. Die danach bytegleich zusammengesetzte synthetische
Adresse in MP07 verändert weder MIME noch Assertions. Für diese neue
Quellrevision wird daraus keine erneute Paket-Ausführung abgeleitet; die
geänderten Dokumentations- und Privacychecks bestanden mit 1853/0 und 3/0.

## Offene Integration

Ein zukünftiger Inhaltcaller muss vor Secret-/Inhaltslesen die tatsächliche
eigene Receiveridentität, Runtime, vollständige Container-ID und numerische
Loopback-Portbindung revalidieren und nach dem Lesen Drift verwerfen.
Eingabebytes beweisen weder Ownership noch einen zugelassenen Receiver.
Öffentliche Inhalt-API, CLI-/GUI-Parität, expliziter Export und Receiver-/SQL-
Lebenszyklus gehören nicht zu diesem Paket. Getrennte native Docker-/Podman-,
SQL-, Browser-, Egress- und Quotanachweise bleiben offen. PowerShell 7.2/.NET 6
und eine minimale Pythonversion sind durch historische neuere Runtimechecks
nicht bestätigt.
