# Privater Offline-Index für TLS-Referenzen und Revisionen

| Merkmal | Wert |
|---|---|
| Status | `OFFLINE_FORM_ONLY`; keine persistente Registry oder Registrierung |
| Stand | 2026-10-16 |
| Implementierung | [`AuthenticatedTlsRegistryIndex.ps1`](../../Private/AuthenticatedTlsRegistryIndex.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsRegistryIndexChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsRegistryIndexChecks.ps1) |
| Weiterer Vertrag | [Kontextregistrierung und Writergrenze](../Project_Planning/TLS_001_CONTEXT_REGISTRATION_DESIGN.md) |

## Abgrenzung zur nativen Registry

Der Index konkretisiert ausschließlich Referenz-, Rollen-, Revisions- und
Tombstoneinvarianten für die geplante Lab-CA. Er enthält keine SID, Profile,
Pfade, Binaries, Keys oder Zertifikate. Die vollständigen privaten Client-,
Signierer- und CA-Payloads vor der Keyanlage samt kanonischer Digestbildung
stehen jetzt im [gekoppelten Payloadvertrag](AUTHENTICATED_TLS_REGISTRY_PAYLOAD.md).
Der Index selbst akzeptiert weiterhin ungeprüfte Digestangaben;
es wird weder ein natives Objekt aufgelöst noch ein Digest dafür berechnet.
Auch formal passende IDs und Digests beweisen keine Herkunft, Qualifikation,
Ownership oder Autorisierung. Ein späterer Writer darf diesen Index nicht
ohne frisch gebundene native Payloads als vollständige Registry persistieren.

Der Produktvertrag verwendet die bestehenden kleinen D-UUIDs und getrennte
logische Referenzen und Revisionen. Er führt keine Foundation-Planungsregistry,
neue Referenzpräfixe oder Umbenennung bestehender Artefakte ein.

## Geschlossene UTF-8-Form

`Read-LabAuthenticatedTlsRegistryIndex` akzeptiert nur ein natives `Byte[]`
mit 1 bis 131072 Bytes. Die Länge wird über den CLR-Getter geprüft; danach
wird eine eigene begrenzte Bytekopie erzeugt. Keine fremden Stringcasts oder
ETS-Längengetter werden aufgerufen. Striktes UTF-8 ohne BOM, JSON-Tiefe
höchstens sechs, keine Kommentare oder abschließenden Kommas. Objektfelder
sind exakt und ordinal; fehlende, zusätzliche, doppelte oder anders
geschriebene Felder einschließlich JSON-escapeter Aliasnamen werden abgelehnt.
Keine Dateinamen, freien Objektgraphen oder impliziten I/O-Quellen als Eingabe.

Die Wurzel enthält genau diese Felder:

| Feld | Grenze |
|---|---|
| `ContractVersion` | `SqlServerLab.AuthenticatedTlsRegistryIndex/0.1` |
| `ControllerId`, `LocationId` | Nicht leere kleine D-UUIDs; unaufgelöste Angaben aus dem bestehenden Storage-Domänenmodell |
| `Revision` | JSON-Integer von 0 bis Int32.MaxValue; keine Strings, Brüche oder Exponenten |
| `Records` | Array mit höchstens 256 Records; Revision 0 hat genau null Records, jede positive Revision mindestens einen |

Jeder Record enthält genau `Kind`, `Ref`, `Generation`, `Status`,
`IdentityDigest`, `RevisionDigest`. `Kind` ist `CLIENT_CONTEXT`,
`SIGNER_CONTEXT` oder `AUTHORITY`; `Status` ist `ACTIVE` oder `RETIRED`.
`Ref` ist eine nicht leere kleine D-UUID und innerhalb des gesamten Index
über alle drei Rollen eindeutig. `Generation` ist ein JSON-Integer von 1
bis Int32.MaxValue. Beide Digestangaben bestehen aus genau 64 kleinen
Hexzeichen. Referenzen sind logische Objektidentitäten; Digestgleichheit
vereinigt keine Records und erzeugt keine Aliasbeziehung.

Nur `AUTHORITY` hat zusätzlich `SignerContextRef` und `SignerGeneration` mit
denselben UUID-/positiven Integergrenzen. Der Verweis muss einen vorhandenen
`SIGNER_CONTEXT` treffen. Eine aktive CA verlangt einen aktiven Signierkontext
und dessen exakte aktuelle Generation. Ein CA-Tombstone darf seine frühere,
höchstens aktuelle Signiergeneration erhalten; dies löst keine historische
Payload auf und erteilt keine Key-/Trustentfernungsfreigabe. Unbekannte oder
falsch typisierte Kanten sperren den gesamten Index, unabhängig von der
Reihenfolge der Records.

Das Ergebnis enthält genau `Success`, `Value`, `ErrorCode`. Erfolg liefert
eine neue native Projektion dieser fünf Wurzelfelder und frische Records,
ohne `JsonElement`- oder Callerbyte-Abhängigkeit. Ablehnung liefert
`Success=false`, `Value=null`, `TLS_REGISTRY_INDEX_INVALID`. Exceptions und
Eingabewerte werden nicht ausgegeben. Eine gültige Form wird nicht registriert;
es existiert weder ein Diskreader noch ein Writer oder eine öffentliche API.

## Reiner Übergangsvalidator

`Test-LabAuthenticatedTlsRegistryTransition` erhält zwei solche Bytearrays.
Beide werden unabhängig geprüft. Für den vorgeschlagenen Folgestand gelten:

1. Controller und Location bleiben unverändert. Die Indexrevision steigt
   genau um eins; die Berechnung verhindert Int32-Überlauf.
2. Kein vorhandener Record wird entfernt. Rolle und `IdentityDigest` bleiben
   für jede Referenz unverändert. Die erste Lane bindet eine CA während ihrer
   gesamten logischen Lebensdauer an denselben `SignerContextRef`. Ein Wechsel
   dieser logischen Signieridentität braucht eine neue CA-Referenz; eine spätere
   Migration benötigt einen eigenen Vertrag. Keine stille Wiederbelegung.
3. Neue Records beginnen aktiv mit Generation eins. Bestehende aktive Records
   dürfen unverändert bleiben oder ihre Generation genau um eins erhöhen;
   dazu muss sich `RevisionDigest` ändern. Eine Änderung von Digest oder
   Signiergeneration ohne neue Generation wird abgelehnt. Eine CA darf ihre
   Signiergeneration nicht zurücksetzen. Die Snapshot-Kantenprüfung gilt weiter.
4. Retirement erhält Generation, Digests und Signierkante unverändert.
   Bereits retirierte Records bleiben vollständig unveränderliche Tombstones.
   Sie werden weder wiederbelebt noch gelöscht oder neu belegt. Das ist nur
   eine Indexinvariante, keine ausgeführte Entfernung von Ressourcen.
5. Mindestens eine echte Ergänzung, Revision oder Retirierung ist erforderlich.
   Eine reine Umordnung, Whitespaceänderung oder leere Revision wird abgelehnt.

Erfolg liefert `Status=OFFLINE_TRANSITION_ONLY`, Controller/Location,
`BaseRevision`, `NextRevision` und ordinal sortierte Arrays `AddedRefs`,
`UpdatedRefs`, `RetiredRefs`. `RegistrationStatus=NOT_EXECUTED`,
`QualificationStatus=NOT_EXECUTED`, `Ready=false`, `MutationAllowed=false`
gelten immer. Die Hüllform bleibt `Success`, `Value`, `ErrorCode`;
`ContractVersion=SqlServerLab.AuthenticatedTlsRegistryTransition/0.1` bezeichnet
die Deltaform. Fehler liefern nur `TLS_REGISTRY_TRANSITION_INVALID` und
`Value=null`. Die Reihenfolge der Records ist keine semantische Bindung.

Der Validator ist weder Lock noch Compare-and-swap oder Replayfreigabe.
Zwei Kandidaten gegen dieselbe Ausgangsrevision können beide formal passen.
Nach Annahme eines Kandidaten scheitert der andere gegen den fortgeschriebenen
Stand; ohne einen echten serialisierten Writer wird damit aber kein Race
verhindert. Alle Zustände und Digestangaben stammen vom Aufrufer. Es gibt keine
Frischegarantie, Zeitprüfung oder Kontrolle realer Backend-/Trustzustände.

## Prüf- und Folgescope

Die synthetische Suite prüft geschlossene Formen, StrictMode, UTF-8-/Byte-/
Record-/Tiefengrenzen, doppelte und escapete Schlüssel, Kultur-/ETS-Grenzen,
referenzierte Signiergenerationen, Tombstones, verbotene Reinterpretationen,
Int32-Grenzen, sortierte Deltas und konkurrierende veraltete Kandidaten.
Quell-AST-Prüfungen begrenzen den In-Memory-Commandgraph und schließen
I/O-/Prozess-/SQL-/PKI-Typen aus. Es gibt keine nativen Proben oder Ressourcen.
Das ist kein ausgeführter Lock-, Crash-, Dateisystem- oder Recoverynachweis.

Nur die exakte Produktdatei erhält die Offline-Ausnahme; die neue Suite und
die bestehende Referenz-/Enumhelperquelle wählen die Prüfung aus. Ähnliche
Pfade und gemischte Runtimeänderungen behalten ihre konservative Auswahl.
Nightly registriert die Suite. Eine kleine Offline-Suite ergänzt bestehende
Gates; unabhängiger Review und Pflichtgate am exakten Head bleiben erforderlich.
Keine zusätzliche Provider- oder Modellrunde entsteht aus diesem Index.

Vor einem Writer sind die Gesamtform und exakte Zuordnung aller privaten
Payloads zu Indexrecords und Digests sowie Rootbindung festzulegen. Die
vorhandenen Payloadformen beschreiben nur Metadaten vor Keyanlage, keine
späteren Key-/Zertifikatsrecords oder Nativevidence. Journal, Lock,
atomarer Dateiersatz und Crash-/Parallelitätsabnahme bleiben eigene folgende
Schritte. [Ausgeführte Nachweise](../Quality/LOCAL_VALIDATION_STRATEGY.md) und
[Grenzen](../Quality/KNOWN_LIMITATIONS.md) unterscheiden dies ausdrücklich.
