# Private TLS-Registrytransaktion unter Windows

| Merkmal | Wert |
|---|---|
| Status | Private Metadatenlane mit additiver Authority-Registrierung, historischer Digestauflösung und nutzungsgebundener Retirement-Transaktion; keine TLS-Qualifikation |
| Stand | 2026-11-11 |
| Implementierung | [AuthenticatedTlsRegistryWriter.ps1](../../Private/AuthenticatedTlsRegistryWriter.ps1) |
| Prüfung | [Invoke-AuthenticatedTlsRegistryWriterChecks.ps1](../../Tests/Static/Invoke-AuthenticatedTlsRegistryWriterChecks.ps1) |

Der Writer ergänzt die [lesende Rootbindung](AUTHENTICATED_TLS_REGISTRY_ROOT.md)
und die [vollständige Dokumentform](AUTHENTICATED_TLS_REGISTRY_DOCUMENT.md).
Er registriert ausdrücklich ausgewählte aktive Client- und Signiermetadaten
und die begrenzte [CA-/Trustscope-Metadatenform](AUTHENTICATED_TLS_AUTHORITY_BINDING.md).
Eine private Retirement-Transaktion darf eine exakt ausgewählte aktive
Authority nur nach geschlossenem Nutzungsnachweis als unveränderlichen
`RETIRED`-Tombstone fortschreiben. Sie entfernt weder Payloads noch historische
Referenzen, CA-Schlüssel oder Trust. Unklare Allocation-/Windows-Journale,
nicht terminal entfernte Runs, erreichbare Container oder VMs und ein geänderter
Registryhead sperren die Mutation. Alte `AuthenticatedTlsLab/0.1`-Records sind
Docker-only, binden aber die ursprüngliche Docker-Runtime nicht dauerhaft.
Deshalb bleibt ihr Retirement mit `TLS_AUTHORITY_USE_UNCONFIRMED` gesperrt;
Run-Desired-State und Connection-Info allein beweisen keine Abwesenheit auf dem
ursprünglichen Daemon.
Generische Updates und Recovery dürfen keine neuen Tombstones erzeugen; eine
Recovery eines bereits installierten Retirement-Kandidaten wiederholt denselben
Nutzungsnachweis. Die bestehende CA wird durch
diese Implementierung weder adoptiert noch qualifiziert.
Keine öffentliche API, Keyöffnung, Zertifikats-, Truststore-, SQL- oder
Provideraktion entsteht. `QualificationStatus=NOT_EXECUTED`, `Ready=false`
und `MutationAllowed=false` bleiben erhalten.

Eine neue Authority kann über `APPEND_AUTHORITY` neben vorhandenen Einträgen
registriert werden. Der Übergang verlangt exakt drei neue Records: eine aktive
`0.2`-Authority sowie eigene aktive Signer- und Clientkontexte. Bestehende
Records müssen vollständig vorhanden und in Identitäts-, Revisionsdigest und
Status unverändert bleiben. Die neue Dreiergruppe wird frisch gegen Kandidat,
Actor, Rootmetadaten, Kontexte und ReadOnly-Trust geprüft. Alte Authorities
werden bei diesem eng begrenzten Übergang nicht als betriebsbereit bewertet.
Bei `UPDATE` werden unveränderte Authorityrecords anhand ihrer vollständigen
Indexbindung (Generation, Status, Identitäts- und Revisionsdigest sowie
Signerreferenz/-generation) erhalten, ohne ihre Kandidatendateien erneut zu
qualifizieren. Geänderte Authorityrecords und geänderte Kontextpayloads werden
weiter frisch validiert. Dadurch blockiert fehlendes Material einer anderen,
unverändert erhaltenen Authority keine Aktualisierung der ausgewählten CA.
Diese alte Authority wird dadurch weder wiederhergestellt noch qualifiziert;
ihre Verwendung prüft ihre Bindung weiterhin frisch und bleibt bei fehlendem
Kandidatenmaterial gesperrt. `UPDATE` und
`APPEND_AUTHORITY` dürfen keine Tombstones anlegen. Retirement bleibt an die
unveränderte vollständige Nutzungsprüfung gebunden.

Runrecords können eine frühere Registrydatei über ihren gespeicherten
`RegistrySha256` anfordern. Der Reader löst sie nur aus einer abgeschlossenen,
validierten Commitkette auf: aus der zugehörigen Originalsicherung oder den im
Commitintent gespeicherten, exakt gehashten Kandidatenbytes. Offene, abgebrochene,
abgetrennte oder mehrdeutige Historie genügt nicht. Diese Auflösung bewahrt die
alte Metadatenbindung; sie stellt keine fehlenden CA-Dateien oder Schlüssel
wieder her. Fehlt das alte Kandidatenmaterial, scheitern dessen frische
Besitz-/Trustprüfungen weiterhin fail-closed. Neue Runs binden den aktuellen
Head.

## Bindung und Ownership

Die private Vorschau verlangt `DataRoot`, `ControllerId`, `LocationId` und
ausdrücklich `CURRENT_WINDOWS_PROCESS`. Sie liest dieselben begrenzten
Rootmarker-/Katalogmetadaten wie der vorhandene Reader. Zusätzlich werden
Token, geladenes Profil, lokaler Hostmarker und native Volumeidentität frisch
ermittelt. Nur Windows, lokales Fixed Drive und NTFS sind ausgewählt. Ein
Volume-GUID-Pfad muss tatsächlich aufgelöst werden und zum gespeicherten
Volume passen; der Drive-Root-Fallback des bestehenden Storagehelpers reicht
nicht. Ein vorhandenes `State`-Verzeichnis ist erforderlich. Andere
Dateisysteme und Linux bleiben für diesen Writer gesperrt.

Operationsnamen werden ausschließlich durch feste ordinale Enumvergleiche
ausgewertet. Auch an einen gültigen String angehängte PowerShell-ETS-Methoden
werden nicht aufgerufen und dürfen `UPDATE` nicht in Recovery umdeuten.

Der Aufrufer bindet jede Mutation an die beobachteten Root-/Actor-Digests und
den exakten SHA-256 der bisherigen Registrybytes. Diese Werte ersetzen weder
die native Neubeobachtung noch die Autorität des konkreten Auftrags. Unter
Sperre und unmittelbar vor Dateiersatz und Commit wird erneut geprüft.
Geänderte aktive Payloads müssen den bestehenden intern frischen
Prozess-/Binary-/Backendvergleich bestehen. Nicht geänderte Kontextgenerationen
werden durch den vollständigen Dokumentübergang erhalten. Jede aktive `0.2`-CA
prüft trotzdem Kandidat, beide Kontextgenerationen und ReadOnly-Trust frisch,
vor Intent, Ersatz und Commit sowie bei `RECOVER_COMMIT`. Diskdigests
bleiben Diskbeobachtungen; ein Registrycommit qualifiziert keine Clients.

Genau `State/authenticated-tls` unter dem ausgewählten Root ist zulässig.
`INITIALIZE` verlangt dessen Abwesenheit und ein vollständiges leeres
Registrydokument mit Revision null. Keine Adoption bestehender Dateien oder
Verzeichnisse. Die neue Ablage, der Owner, der Filelock und alle Journale
haben geschützte ACLs mit ausschließlich aktuellem Benutzer und SYSTEM.
`owner.json` bindet Registry-ID, Controller, Location, Root- und Actor-Digest.
Fehlender Owner, unbekannte Artefakte oder aufgeweichte ACLs sperren.

## Serialisierung und Dateiersatz

Ein rootpfadgebundener `Global`-Lifecycle-Mutex serialisiert Registrywrites,
TLS-Lab-Anlage und Authority-Retirement über Windows-Sitzungen hinweg. Darin
serialisiert ein weiterer rootpfadgebundener Writer-Mutex auch die erstmalige Anlage.
Der zusätzliche persistente `writer.lock`
wird mit `FileShare.None` geöffnet. Beide Erwerbe warten nicht auf einen
anderen Writer. Beim Prozessende werden die Handles frei; die Lockdatei
bleibt als eigener regulärer Bestandteil erhalten. Ein verwaister Mutex
erlaubt keine automatische Wiederholung eines vorhandenen Intents.

Der geordnete Ablauf ist:

1. Frische Root-/Actor-/Volume- und Quellprüfung unter Sperre.
2. Vollständigen Übergang und geänderte native Payloadbindungen prüfen.
3. Eigenen geschützten Intent mit Transaktions-ID, Quell-/Kandidatdigest und
   vollständigen ursprünglichen Kandidatbytes schreiben und `Flush(true)`.
4. Eigene Kandidatdatei im selben Verzeichnis schreiben, flushen, unabhängig
   zurücklesen und erneut vollständig validieren.
5. Bindung und exakte Quellbytes erneut prüfen. Bei Initialisierung erfolgt
   ein `File.Move` ohne Overwrite; bei Update `File.Replace` mit eigener
   `<Transaktions-ID>.source.json` als Originalsicherung. Kein Copy-, Append-
   oder Overwrite-Fallback. ACL-Mergefehler werden nicht ignoriert.
6. Installierte Datei unabhängig lesen, Byte-SHA und Dokumentform prüfen,
   Bindung erneut prüfen, geschützten Commit schreiben/flushen/zurücklesen.
7. Commitkette und tatsächlichen Registryhead prüfen; erst dann Erfolg.

Die verwendeten .NET-APIs sind [File.Replace](https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace),
[FileStream.Flush](https://learn.microsoft.com/en-us/dotnet/api/system.io.filestream.flush)
und [benannte Mutexes](https://learn.microsoft.com/en-us/dotnet/standard/threading/mutexes).
Diese Lane prüft echte Prozessabbrüche und Sichtbarkeit unter NTFS. Sie
behauptet keine Stromausfallfestigkeit von Verzeichniseinträgen, kein
unveränderliches Hardware-Hostattest und keinen Schutz gegen Administratoren
oder nicht kooperierende Schreiber desselben Sicherheitskontexts. Die
pfadbasierten Prüfungen sind kein handlebasierter Rootanker gegen ABA.

## Journal, Grenzen und Recovery

Intents, Originalsicherungen und Terminalbelege bleiben erhalten. Alle aus
Intents bekannten Referenzen bleiben reserviert, auch nach `RECOVER_ABORT`.
Maximal 256 Intents und 1028 Verzeichniseinträge werden gelesen; die Registry
behält ihre Grenze von 4 MiB und 256 Records. Ein Intent ist auf 5611520
Bytes begrenzt, enthält einen streng geprüften Base64-Kandidaten und nur die
geschlossenen Metadatenfelder. Terminal- und Ownerrecords sind auf 16 KiB
begrenzt. Volle Journale sperren weitere Writes; kein automatisches Kürzen
oder Freigeben alter Referenzen. Größenlimits sind Obergrenzen, keine
Vorbelegung. Nach jeder Intentprüfung bleiben im Arbeitsspeicher nur die
kleinen Bindungen und reservierten Referenzen erhalten, keine vollständigen
Base64-/Payloadkopien aller früheren Revisionen. Sämtliche tatsächlichen
Metadaten bleiben lokal.

Der Reader rekonstruiert die eindeutige Commitkette von `ABSENT` bis zum
letzten Head. Verzweigungen, losgelöste Commits, kollidierende Terminalbelege,
unbekannte Dateien, korrupte Originalsicherungen oder ein zurückgespieltes
altes Registryfile sperren. Ohne Commit gibt es keinen positiven
Registrierungsbefund. Höchstens ein offener Intent ist zulässig.

| Frischer Zustand mit offenem Intent | Zulässige explizite Recovery |
|---|---|
| `SOURCE_UNCHANGED` | `RECOVER_ABORT` für exakt diese Transaktions-ID |
| `CANDIDATE_INSTALLED` | `RECOVER_COMMIT` für exakt diese Transaktions-ID |
| `UNKNOWN` oder unlesbare/ungültige Records | Keine automatische Recovery |

Recovery ersetzt keine Datei und startet keine frühere Aktion neu. Sie
schreibt ausschließlich den passenden eigenen Terminalbeleg nach erneuter
Bindungsprüfung. Eine neue normale Mutation bleibt bis dahin gesperrt.
Ein Abbruch während der erstmaligen Anlage vor vollständigem Intent oder
ein abgebrochener initialer Intent ohne installierte Registry bleibt
gesperrt und benötigt eine gesonderte eigene Cleanup-/Recoveryentscheidung;
kein stiller Bootstrap-Replay. Run-Removal entfernt diese gemeinsame Ablage
nicht. Die private Retirementtransaktion ändert ausschließlich Status und
Indexrevision. Produktiv registrierte Kontexte, CA-Zuordnung,
Key-/Trustentfernung und TLS-Qualifikation bleiben getrennte Operationen.

## Prüfung und Aufwand

Die Suite verwendet ausschließlich eigene kurzlebige Tempbäume. Sie prüft
native ACLs, Volumeabgleich, tatsächliche Initialisierung und `File.Replace`,
Originalbytes, Quellkonflikte, Journal-Replay, vier echte Prozessabbrüche,
expliziten Commit/Abort, Referenzreservierung, unbekannte Ersatzbytes und
zwei konkurrierende Prozesse. Mutex und Filelock werden getrennt gehalten.
Eigene Childprozesse werden begrenzt beendet und alle Tempdateien entfernt.
Nicht-Windows prüft die gesperrte Lane; native Windows-Fälle bleiben dort
`NOT_EXECUTED`. Keine Rootstore-, Key-, SQL- oder Providerprobe.

Die CI-Auswahl ergänzt genau diese Datei und ihre direkten/transitiven
Helper um die Writersuite. Nur die exakte Produktdatei erhält die Ausnahme
von Provider-Smokes: Ihre Effekte sind private lokale Metadaten, nicht
Runtimekonfiguration. Ähnliche Pfade und gemischte produktive Änderungen
behalten die konservative Providerauswahl. Statische Gates, Nightly und
unabhängiger stabiler Review bleiben erforderlich. Vollständige Logs bleiben
lokal; ein zweiter Modell-/Providerlauf entsteht daraus nicht. Der
selektorbezogene Aufwand ist in dieser begrenzten Entscheidung berücksichtigt;
die tatsächliche volle Analyzersuite bleibt bei Testdateiänderungen erhalten.

## Operativer Nachfolger und ReFS

Der [operative TLS-Pfad](AUTHENTICATED_TLS_OPERATIONAL_LAB.md) verwendet die vorhandene Authority-Metadatenbindung und ergänzt die separate private Keybesitzprüfung. Der Writer unterstützt jetzt lokale feste NTFS- und ReFS-Volumes mit unveränderten ACL-, Lock-, CAS-, Intent-, Replace- und Recoverygrenzen. Die ReFS-Erweiterung ist separat durch alle 45 nativen Writerfälle einschließlich Prozessabbruch, Konkurrenz und Cleanup geprüft. Trustscope-Referenzen bleiben auch in abgebrochenen Intents reserviert. Ein Writercommit allein qualifiziert weiterhin keine SQL-Verbindung.
