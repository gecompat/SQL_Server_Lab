# Private Registry-Gesamtform für TLS-Metadaten

| Merkmal | Wert |
|---|---|
| Status | `OFFLINE_REGISTRY_ONLY`; keine persistente Registry oder Registrierung |
| Stand | 2026-10-16 |
| Implementierung | [`AuthenticatedTlsRegistryDocument.ps1`](../../Private/AuthenticatedTlsRegistryDocument.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsRegistryDocumentChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsRegistryDocumentChecks.ps1) |
| Teilverträge | [Referenzindex](AUTHENTICATED_TLS_REGISTRY_INDEX.md), [Payloadformen und Digests](AUTHENTICATED_TLS_REGISTRY_PAYLOAD.md) |

## Geschlossenes Dokument

`Read-LabAuthenticatedTlsRegistryDocument` akzeptiert nur ein natives `Byte[]`
mit 1 bis 4194304 Bytes, striktem UTF-8 ohne BOM und JSON-Tiefe höchstens acht.
Vor dem Parsen wird die CLR-Länge geprüft und eine eigene begrenzte Bytekopie
erzeugt. Keine Callergetter, Stringcasts, Kommentare oder abschließenden Kommas.
Die Wurzel enthält exakt `ContractVersion`, `Index`, `Payloads` mit
`ContractVersion=SqlServerLab.AuthenticatedTlsContextRegistry/0.1`.
Die bereits vorgeschlagene Contractkennung wird jetzt ausschließlich für
Metadaten vor der Keyanlage konkretisiert; spätere Key-/Zertifikatsrecords
und ihr Speichervertrag sind nicht Teil dieser Form.

`Index` wird vollständig durch den vorhandenen Indexreader geprüft. `Payloads`
ist ein Array mit höchstens 256 Einträgen; jeder Eintrag wird durch den
vorhandenen Payloadreader geprüft. Dabei gelten auch die eigenen Grenzen
der ursprünglichen JSON-Teilstücke: Index höchstens 128 KiB, jede Payload
höchstens 32 KiB und jeweils Tiefe sechs. Es gibt keine Lockerung durch die
größere Gesamthülle. Fehlende, zusätzliche, doppelte und anders geschriebene
Schlüssel einschließlich escapeter Duplicate Keys bleiben gesperrt.

Payload- und Indexanzahl müssen übereinstimmen. Zu jeder Indexreferenz gehört
exakt eine Payload mit derselben Referenz, Rolle, Generation, Status und
Controller/Location. Ihre neu abgeleiteten Identitäts-/Revisionsdigests müssen
ordinal mit den Indexwerten übereinstimmen. Bei CAs müssen zusätzlich
SignerContextRef und SignerGeneration exakt passen. Doppelte, fehlende,
fremde oder verwaiste Payloads sowie geänderte Daten unter einem alten
Digest sperren den gesamten Befund. Die bestehende Index-Kantenprüfung
verlangt für aktive CAs den aktiven Signierkontext in der aktuellen Generation.

Der leere Ausgangsstand besteht aus Revision null, null Indexrecords und
null Payloads. Bei positiver Revision bleibt der Index nicht leer. Tombstones
erhalten vollständige aktuelle Metadaten und Referenzen. Eine retirierte CA
darf ihre frühere Signiergeneration referenzieren, wie im Indexvertrag
beschrieben. Das löst keine historische Signiererpayload auf und berechtigt
nicht zur Entfernung tatsächlicher Keys, Trustanker oder gemeinsam genutzter
Ressourcen. Diese Form ist kein Journal aller früheren Revisionen.

Erfolg liefert genau `Success`, `Value`, `ErrorCode` mit frischer
`RegistryDocument`-Projektion, `ContentDigest`, `Status=OFFLINE_REGISTRY_ONLY`,
`RootBindingStatus=NOT_EVALUATED`, `NativeBindingStatus=NOT_EXECUTED`,
Registrierung und Qualifikation `NOT_EXECUTED`, `Ready=false` und
`MutationAllowed=false`. Ablehnung liefert nur `TLS_REGISTRY_DOCUMENT_INVALID`
und `Value=null`; keine Eingabewerte, Exceptions oder Teilrecords.
Weder Dateinamen noch freie Objektgraphen werden als Eingabe akzeptiert.

## Kanonischer Dokumentinhalt

`ContentDigest` verwendet dieselbe UTF-8-Längenrahmung und SHA-256 wie der
Payloadvertrag. Die Atome beginnen mit `SqlServerLab.TlsRegistryDocument/0.1`,
ControllerId, LocationId und invariant dezimaler Indexrevision. Danach folgen
die Records ordinal nach Ref sortiert, jeweils Kind, Ref, Generation, Status,
IdentityDigest und RevisionDigest. CAs ergänzen SignerContextRef und
SignerGeneration. Payloads sind bereits exakt gegen diese Inhaltsdigests
geprüft. Damit bindet der Dokumentdigest auch logische IDs, Generationen und
Retirement, die absichtlich nicht zu den Payload-Inhaltsatomen gehören.

JSON-Whitespace, Feldordnung und die Reihenfolge von Indexrecords oder
Payloads ändern diesen Digest nicht. Er ist ein Digest normalisierter
Metadatenangaben, kein Hash der Originaldatei, keine Signatur, Attestation,
Herkunftsprüfung oder Frischegarantie. Ein späterer Writer muss die echten
Ausgangsbytes und Root-/Actorbindung separat unter Lock prüfen; der
semantische Digest ersetzt weder diese Bindung noch Compare-and-swap.
Auch ein vollständig in sich konsistenter Callerbefund ist keine Registrierung.

## Vollständige Dokumentübergänge

`Test-LabAuthenticatedTlsRegistryDocumentTransition` prüft beide Bytearrays
zuerst als vollständige Dokumente. Danach wendet er den unveränderten
Index-Übergangsvertrag auf ihre geprüften Indexprojektionen an. Entfernte
Records, Wiederbelegung, Rollen-/Identitätswechsel, Generationensprünge,
inkonsistente Revisionen, geänderte Tombstones und leere Fortschreibungen
bleiben gesperrt. Geänderte Payloaddaten müssen zum neuen Indexdigest passen;
ein isoliert gefälschter Index kann keinen gültigen Übergang vortäuschen.

Erfolg liefert `Status=OFFLINE_REGISTRY_TRANSITION_ONLY`,
`CurrentContentDigest`, `NextContentDigest`, das vorhandene `Delta` sowie
dieselben unqualifizierten Root-/Native-/Registrierungs-/Qualifikationsstatus
und false-Flags. Fehler liefern `TLS_REGISTRY_DOCUMENT_TRANSITION_INVALID`
und `Value=null`. Die Hülle bleibt `Success`, `Value`, `ErrorCode`.
Konkurrierende Vorschläge können gegen denselben Ausgangsstand beide formal
passen; ein veralteter Vorschlag scheitert erst gegen den fortgeschriebenen
Stand. Es gibt weiterhin keinen tatsächlichen Lock, Writer oder Crashproof.

## Tests, Integration und fehlende Abnahmen

Die Suite verwendet ausschließlich synthetische Bytes im Speicher. Sie prüft
geschlossene Formen, UTF-8-/Byte-/Tiefen-/Recordgrenzen, genaue Mengen- und
Digestzuordnung, Rootangaben, CA-Kanten, Tombstones, Semantikdigests unter
drei Kulturen, Umordnung und Whitespace sowie vollständige Übergänge und
veraltete konkurrierende Vorschläge. Native Tripwire und AST-Prüfungen
begrenzen den Aufrufgraph auf Parser, Digests und Indexübergänge. Kein Host,
Pfad, Binary, Store, Key, SQL oder Provider wird dafür gelesen oder verändert.

Die kleine Suite ergänzt exakt Produkt-/Testdatei und betroffene Index-/
Payload-/Referenzhelper. Nur die exakte neue Produktdatei erhält die Offline-
Ausnahme; gemischte Runtimeänderungen und ähnliche Pfade behalten ihre Auswahl.
Nightly, unabhängiger Review und Pflichtgate am exakten Head bleiben erhalten.
Eine zusätzliche Provider- oder Modellrunde ist für diese Byteform nicht nötig.

Die authentifizierte TLS-Lab-Abnahme ist dadurch nicht erledigt. Insbesondere
bleibt Toolbelt SC-2026-045 bis zu seinem echten TLS-/Clientnachweis blockiert.
Root-/Trustscopeauflösung, Dateileser, Registrywriter, persistente Registrierung,
Keyschutz, Trustimport und SQL-/TLS-Matrix sind weiterhin offen. Nächster
begrenzter Scope ist der private lesende Resolver für die ausdrücklich
registrierte Controller-/Location-/Rootbindung mit dieser Gesamtform;
kein automatisches Anlegen oder Adoptieren einer Registrydatei.
[Nachweise](../Quality/LOCAL_VALIDATION_STRATEGY.md) und
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md) erhalten diese Grenzen.
