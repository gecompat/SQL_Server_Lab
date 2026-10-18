# Lesende Rootbindung der privaten TLS-Registry

| Merkmal | Wert |
|---|---|
| Status | `REGISTERED_ROOT_METADATA_MATCH`; keine Registrierung oder Ausführungsautorität |
| Stand | 2026-10-16 |
| Implementierung | [`AuthenticatedTlsRegistryRoot.ps1`](../../Private/AuthenticatedTlsRegistryRoot.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsRegistryRootChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsRegistryRootChecks.ps1) |
| Abhängigkeiten | [Gesamtform](AUTHENTICATED_TLS_REGISTRY_DOCUMENT.md), bestehender `DiagnosticBundleReader`, `StorageContract` als Produzent von Marker/Katalog |

`Get-LabAuthenticatedTlsRegistryRoot` erhält ausdrücklich `DataRoot`,
`ControllerId` und `LocationId`. Nur Windows ist in dieser ersten Lane
unterstützt, ermittelt durch CLR-Plattformmetadaten. Ein aktueller lokaler
Fixed-Drive-Root und kanonische Referenzen sind erforderlich. UNC, relative
Pfade, Volumewurzel, Traversal, ADS, Geräteprefixe, ungültige Windowszeichen,
abschließende Punkte/Leerzeichen und vorhandene Reparse-Komponenten sperren.
Es gibt keine Defaultsuche, freie Dateiauswahl oder Legacyadoption.

Gelesen werden ausschließlich `.sql-server-lab-root.json`,
`Catalog/storage-locations.json` und `State/authenticated-tls/registry.json`
unter diesem Root. Marker und Katalog verwenden den bestehenden begrenzten
JSON-Reader mit Duplicate-/Casealias-Prüfung: höchstens 16 KiB/Tiefe acht
beziehungsweise 64 KiB/Tiefe zwölf. Die bestehenden Produzentenfelder bleiben
erhalten; es entsteht kein zweiter Storagevertrag oder neuer Rootallocator.
Marker müssen `SqlServerLab.DataRoot/2.0`, `ManagedBy=SQL_Server_Lab`,
ausgewählten Controller und denselben Root benennen. Der Katalog verlangt
`SqlServerLab.Storage/2.0`, denselben Controller, 1 bis 32 Locations und genau
einen passenden Root und eine eindeutige ausgewählte LocationId. Controller,
Location und gespeicherte Volumeangabe des ausgewählten Records müssen passen.
Die Volumeangabe bleibt ein Metadatenclaim, keine frische native Volumeidentität.

Die Registrydatei ist ein reguläres File mit 1 bis 4194304 Bytes. Der Reader
öffnet sie nur lesend mit `FileShare.Read`, liest höchstens das Limit plus
ein Sentinelbyte und prüft die [vollständige Dokumentform](AUTHENTICATED_TLS_REGISTRY_DOCUMENT.md).
Controller und Location des geprüften Index müssen mit der ausgewählten
Rootregistrierung übereinstimmen. Fehlende oder ungültige Dateien sperren;
auch ein leerer Ausgangsstand muss ausdrücklich als vollständiges Dokument
existieren. Kein Verzeichnis oder Dokument wird angelegt oder übernommen.

Ein zweiter begrenzter Read von Marker, Katalog und Registry erkennt
beobachtete Drift. Marker/Katalog werden als vollständige JSON-Projektionen
verglichen, die Registry über ihren Originalbyte-SHA256. Das ist kein atomarer
Snapshot, Lock, Compare-and-swap, Schutz vor ABA oder sicherer handlebasierter
Rootanker gegen nicht kooperierende Schreiber. Spätere Änderungen können
den Befund sofort veralten lassen. Ein Writer muss alles unter eigener
Sperre neu lesen und die geplanten nativen Bindungen zusätzlich prüfen.

Erfolg hat die geschlossene Hülle `Success`, `Value`, `ErrorCode`. `Value`
enthält genau 16 Felder: Status, DataRoot, ControllerId, LocationId, RegistryPath,
RegistryDocument, RegistryByteSha256, ContentDigest, RootMetadataDigest,
RootBindingStatus, NativeBindingStatus, RegistrationStatus, QualificationStatus,
SnapshotStatus, Ready und MutationAllowed. Status ist
`REGISTERED_ROOT_METADATA_MATCH`, RootBindingStatus `REGISTERED_METADATA_MATCH`,
SnapshotStatus `NON_ATOMIC_READ`. Native Bindung, Registrierung und Qualifikation
bleiben `NOT_EXECUTED`, Ready und MutationAllowed false. Ablehnung liefert
`TLS_REGISTRY_ROOT_INVALID` mit `Value=null`, ohne Pfade, Exceptions oder
Teilbefund. Erfolg enthält private Metadaten und bleibt ausschließlich lokal.

RegistryByteSha256 bindet die tatsächlich gelesenen Dateibytes; ContentDigest
behält die normalisierte Dokumentsemantik. RootMetadataDigest verwendet die
Längenrahmung des Payloadvertrags über `SqlServerLab.TlsRegistryRootMetadata/0.1`,
normalisierten Rootpfad, serialisierte Marker-/Katalogprojektionen und
RegistryByteSha256. Er ist weder Signatur noch Attestation oder Autorisierung.
Caller-ETS-Getter und fremde Stringcasts werden vor Datei-I/O nicht ausgeführt.

Die Windows-Suite prüft nur eigene synthetische Tempfixtures, geschlossene
Ablehnung, Root-/Indexzuordnung, leere und nichtleere Dokumente, Bytegrenzen,
fehlende/gesperrte Dateien, Junctions, beobachtete Drift und unveränderte Files.
Nicht-Windows prüft ausdrücklich nur die gesperrte Lane; Windows-Dateifälle
bleiben dort `NOT_EXECUTED`. Cleanup entfernt ausschließlich den vorher
verifizierten eigenen Tempbereich. Native Kontext-, Key-, Store-, SQL- und
Providerproben werden nicht aufgerufen. AST-Prüfung begrenzt den Commandgraph.

Die exakte Produktdatei erhält eine Offline-Ausnahme im CI-Selektor; ihre
direkten Parser-/Pathguardabhängigkeiten wählen die neue Suite zusätzlich aus.
Ähnliche Pfade und gemischte Runtimeänderungen behalten ihre breite Auswahl.
Nightly und unabhängiger stabiler Review sowie das Pflichtgate am exakten Head
bleiben erhalten. Eine kleine Suite ersetzt keine Providerabnahme.

Die getrennte [private Registrytransaktion](AUTHENTICATED_TLS_REGISTRY_WRITER.md)
ergänzt inzwischen aktive Client-/Signiermetadaten vor Keyanlage mit frischer
Actor-/Volumeprüfung, privater Ablage, kooperativen Sperren, Intent, atomarem
Ersatz, Rücklesung und expliziter Recovery. Der hier beschriebene Reader
behält seinen nicht atomaren Vertrag. Operative CA-/Trustscopezuordnung,
Retirement und authentifizierte TLS-Lab-Abnahme bleiben offen.
Toolbelt SC-2026-045 bleibt blockiert.

Der vorgezogene [CA-Kandidat](AUTHENTICATED_TLS_CA_CANDIDATE.md) verwendet
jetzt den extrahierten privaten `Get-LabAuthenticatedTlsRootMetadata` für
dieselbe Marker-/Katalogprüfung ohne Registrydatei. Die geschlossene interne
Hülle liefert Root, Controller, Location, beide vollständigen JSON-Projektionen
und einen getrennten `SqlServerLab.TlsRootMetadata/0.1`-Digest. Sie liest einmal;
der jeweilige Aufrufer prüft erneut auf beobachtete Drift. Die bestehende
Registryfunktion behält ihre 16 Ergebnisfelder, vollständige Dokumentpflicht,
Originalbytebindung und bisherigen Digestvertrag. Eine fehlende Registry
wird durch den neuen Helper weder adoptiert noch angelegt. Die allgemeine
Registrytransaktion ist im getrennten Writervertrag begrenzt implementiert.
