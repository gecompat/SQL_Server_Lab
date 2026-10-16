# Private TLS-Metadatenpayload und Prozessbindung vor Keyanlage

| Merkmal | Wert |
|---|---|
| Status | `PRE_KEY_METADATA_ONLY`; keine Registrierung, CA oder Keyablage |
| Stand | 2026-10-16 |
| Implementierung | [`AuthenticatedTlsRegistryPayload.ps1`](../../Private/AuthenticatedTlsRegistryPayload.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsRegistryPayloadChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsRegistryPayloadChecks.ps1) |
| Gekoppelt | [Referenzindex](AUTHENTICATED_TLS_REGISTRY_INDEX.md), [Windows-Vorschau](AUTHENTICATED_TLS_CONTEXT_PREVIEW.md), [Registrierungsentwurf](../Project_Planning/TLS_001_CONTEXT_REGISTRATION_DESIGN.md) |

## Geschlossene private Metadaten

`Read-LabAuthenticatedTlsRegistryPayload` akzeptiert ein natives `Byte[]`
mit 1 bis 32768 Bytes, striktem UTF-8 ohne BOM und JSON-Tiefe höchstens sechs.
Die CLR-Länge wird vor einer eigenen Bytekopie geprüft. Keine Callergetter,
Stringcasts, Kommentare oder abschließenden Kommas. Die bestehenden strikten
Indexhelper prüfen jede Objektform ordinal mit genau den vorgesehenen Feldern;
Duplicate Keys, Casevarianten und escapete doppelte Namen werden abgelehnt.
Die Form ist privat und vor der Keyanlage vollständig; sie beschreibt noch
keine späteren Keyhandles, Zertifikate, Gültigkeiten oder qualifizierten Stores.

Gemeinsam sind `ContractVersion=SqlServerLab.AuthenticatedTlsRegistryPayload/0.1`,
`ControllerId`, `LocationId`, `Kind`, `Ref`, `Generation`, `Status`. Die drei
IDs sind nicht leere kleine D-UUIDs. `Generation` ist ein JSON-Integer von 1
bis Int32.MaxValue, `Status` ist `ACTIVE` oder `RETIRED`. Controller/Location
werden hier nur formal geprüft, nicht gegen einen registrierten Root aufgelöst.

| Kind | Zusätzliche geschlossene Felder |
|---|---|
| `CLIENT_CONTEXT` | `Context=CURRENT_WINDOWS_PROCESS`, `Actor`, `Details` für beide fest ausgewählten Clientstacks |
| `SIGNER_CONTEXT` | derselbe Context und Actor, `Details` für die vorhandenen .NET-API-Metadaten |
| `AUTHORITY` | `TrustScopeRef`, `SignerContextRef`, positiver Integer `SignerGeneration`, `KeyStatus=NOT_CREATED`, `CertificateStatus=NOT_CREATED` |

`Actor` enthält genau `UserSid`, `HostMarker`, `ProfilePath`. SID und Marker
folgen den Formen des Windows-Readers; die SIDform allein beweist keine
Anmeldung oder Benutzerrolle. Profil-/Binärpfade sind begrenzte syntaktische
Windows-Lokatoren mit Laufwerk und Backslashes: keine relativen Pfade, UNC,
ADS, Steuerzeichen, Wildcards, leeren/`.`/`..`-Segmente oder abschließenden
Backslashes. Profile enthalten keine `%`-Expansion. Diese Formprüfung liest
keinen Pfad und behauptet keine Existenz oder atomare Pfadreservierung.

Client-`Details` haben genau diese Felder: `Store=CURRENT_USER_ROOT`,
`ClientStacks=[SYSTEM_DATA_SQLCLIENT,ODBC_SQLCMD]` in dieser Reihenfolge,
`SqlClientPath`, `SqlClientDiskSha256`, `SqlClientDiskBytes`,
`SqlClientAssembly`, `SqlClientLoadedMvid`, `SqlcmdPath`, `SqlcmdDiskSha256`,
`SqlcmdDiskBytes`, `BinaryEvidence=ON_DISK_BYTES_ONLY`,
`LoadedImageDigestStatus=NOT_MEASURED`, `SqlcmdFlavorStatus=NOT_QUALIFIED`,
`LoadedOdbcDriverStatus=NOT_EXECUTED`. Digests sind 64 kleine Hexzeichen,
Byteanzahlen positive Integer bis 64 MiB, die MVID eine kleine D-UUID.
Die Dateinamen müssen `System.Data.SqlClient.dll` beziehungsweise `sqlcmd.exe`
sein. Die begrenzte Assemblyanzeige beginnt mit `System.Data.SqlClient, `;
sie ist keine geprüfte Signatur oder Codeherkunft.

Signierer-`Details` haben genau `Backend=DOTNET_X509`, `RuntimeVersion`,
`ApiStatus`, `Apis`, `KeyProtectionStatus=NOT_EVALUATED`. Die numerische
Laufzeitanzeige und sechs geordnete API-IDs entsprechen dem
[Backendvertrag](AUTHENTICATED_TLS_BACKEND_METADATA.md). Jedes APIobjekt hat
genau `Id` und einen echten Boolean `Present`. `COMPLETE` verlangt alle sechs,
sonst muss `INCOMPLETE` vorliegen. Auch dieser Befund erlaubt keine Keyaktion.

Erfolg liefert die geschlossene Hülle `Success`, `Value`, `ErrorCode` mit
`Value.Status=OFFLINE_PAYLOAD_ONLY`, frischer `Payload` und abgeleitetem
`IndexRecord`. `RootBindingStatus=NOT_EVALUATED`, Registrierung und Qualifikation
bleiben `NOT_EXECUTED`, `Ready=false`, `MutationAllowed=false`. Ablehnung liefert
`TLS_REGISTRY_PAYLOAD_INVALID` und `Value=null`, ohne Eingabe- oder Exceptiontext.

## Kanonische Inhaltsdigests

Jedes Atom wird als acht kleine ASCII-Hexziffern seiner UTF-8-Byteanzahl,
gefolgt von seinen UTF-8-Bytes ohne BOM, eingerahmt. SHA-256 über die Folge
liefert kleine Hexzeichen. Keine Konkatenationsmehrdeutigkeit, JSON-Feldordnung,
Whitespace-, Kultur- oder JSON-Escapingabhängigkeit. Es gibt keine Unicode-
oder Pfadnormalisierung; native Zeichenrepräsentationen werden exakt gebunden.
Zahlen werden invariant dezimal, APIbooleans als `1` oder `0` dargestellt.

`IdentityDigest` beginnt mit `SqlServerLab.TlsPayloadIdentity/0.1`, Kind,
ControllerId, LocationId. Bei Kontexten folgen Context, UserSid, HostMarker;
bei einer CA TrustScopeRef und SignerContextRef. Profil- oder Binärwechsel
sind Revisionen, ein anderer nativer Actor erfordert eine neue logische Referenz.

`RevisionDigest` beginnt mit `SqlServerLab.TlsPayloadRevision/0.1`. Kontexte
fügen ProfilePath an. Clients fügen Namen/Werte für Store, SqlClientPath,
SqlClientDiskSha256, SqlClientDiskBytes, SqlClientAssembly, SqlClientLoadedMvid,
SqlcmdPath, SqlcmdDiskSha256, SqlcmdDiskBytes, BinaryEvidence,
LoadedImageDigestStatus, SqlcmdFlavorStatus und LoadedOdbcDriverStatus genau
in dieser Reihenfolge an, danach die beiden Stack-IDs. Signierer fügen Backend,
RuntimeVersion, ApiStatus, KeyProtectionStatus und je API Id/Boolean an. Eine
CA fügt SignerGeneration, KeyStatus und CertificateStatus an. Zuletzt wird immer
IdentityDigest angefügt. Ref, Generation, Retirementstatus, PID, Prozessstart
und Prozesspfad sind keine Inhaltsatome. Eine neue Verwaltungsnummer allein
erzeugt daher keinen geänderten Inhalt. Der abgeleitete Indexrecord enthält
weiterhin Referenz, Rolle, Generation, Status und bei CAs die Signierkante.

Diese Digests binden die vorliegenden Angaben. Sie sind keine Attestation,
keine Rootauflösung und keine Herkunfts- oder Autorisierungsprüfung.

## Frische lesende Prozessbindung

`Get-LabAuthenticatedTlsPayloadPreview` prüft die Payload vor Hostlesung und
akzeptiert nur aktive Metadaten. Für eine CA ist zusätzlich die geschlossene
aktive Signiererpayload mit exakter Referenz, Generation und gleichem
Controller/Location erforderlich. Eine CA-ID wird nie zur Prozessidentität.
Andere Rollen akzeptieren keine zusätzliche Signiererpayload.

Der Binder ruft intern die vorhandene Windows-Vorschau mit einer neuen
Anfrage-ID und genau dem ausgewählten Kontext auf. Er akzeptiert keinen
Caller-Previewparameter. Die Antwort muss Anfrage-ID, Rolle, Context und
gültige Prozessmetadaten treffen. Er baut die erwartete Payload aus frisch
gelesenem Actor und Client-/Backendbefund neu auf, validiert sie erneut und
vergleicht beide Inhaltsdigests ordinal. Payloadpfade werden nicht geöffnet;
die NativeReader wählen Profil und Binaries selbst. Bei CAs wird so nur die
Signierkontext-Metadatenbindung geprüft, keine CA oder Trustscope aufgelöst.

Erfolg liefert `FRESH_PROCESS_METADATA_MATCH`, private Payload, Indexrecord,
PID, Startticks und Prozesspfad. Root und AuthorityTrustScope bleiben
`NOT_EVALUATED`; Registrierung und Qualifikation bleiben `NOT_EXECUTED`,
Ready und MutationAllowed false. Fehler liefern ausschließlich
`TLS_REGISTRY_PAYLOAD_BINDING_MISMATCH` oder bei fehlendem nativen Befund
`TLS_REGISTRY_PAYLOAD_PREVIEW_UNAVAILABLE`, ohne Teilbefund. Ungültige erste
Payloads behalten `TLS_REGISTRY_PAYLOAD_INVALID`. Ergebnisse sind flüchtig:
keine spätere Frischegarantie, Registrierung, Replayfreigabe oder Sicherheit
gegen einen manipulierten eigenen Prozess beziehungsweise Administratoren.

SIDs, Hostmarker, Profile, Pfade und ihre Digests bleiben ausschließlich privat
und lokal. Die neue Suite verwendet nur synthetische Bytes und gemockte native
Vorschauen. Eine separate direkte Windows-Beobachtung traf danach beide
Kontexte und die CA-Signiermetadaten mit synthetischen Referenzen; reale
Metadaten blieben lokal. Das ist keine vollständige Binderqualifikation:
Mindestlaufzeit, Rootbindung, Keyschutz, Trust, SQL und TLS bleiben getrennte
fehlende Nachweise. Die kleine
Suite ergänzt selektiv ihre Parser-/Vorschauabhängigkeiten und Nightly; nur
die exakte Produktdatei erhält die Offline-Ausnahme. Gemischte Runtimeänderungen
behalten ihre Auswahl. Unabhängiger Review und exakter CI-Pflichtgate bleiben.

Nächster Scope ist die geschlossene Registry-Gesamtform mit exakter Zuordnung
aller Payloads zu Indexrecords und deren Digests. Der Writer-/Crashvertrag und
sämtliche echten Registrierungs-, Key-, Trust- oder Provideraktionen bleiben
nachgelagert. [Nachweise](../Quality/LOCAL_VALIDATION_STRATEGY.md) und
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md) erhalten diese Trennung.
