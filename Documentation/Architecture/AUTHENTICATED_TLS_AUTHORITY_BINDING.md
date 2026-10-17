# Private CA-/Client-Trustbindung

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-17 |
| Status | `METADATA_BOUND_NOT_TLS_QUALIFIED`; `Ready=false`, `MutationAllowed=false` |
| Implementierung | [AuthenticatedTlsAuthorityBinding.ps1](../../Private/AuthenticatedTlsAuthorityBinding.ps1) |
| Prüfung | [Invoke-AuthenticatedTlsAuthorityBindingChecks.ps1](../../Tests/Static/Invoke-AuthenticatedTlsAuthorityBindingChecks.ps1) |

Diese private Windows-Lane verbindet einen vorhandenen geschützten CA-Kandidaten
mit genau einem aktuellen Client-/Signierkontext und einem logischen Trustscope.
Sie schreibt ausschließlich Metadaten über den vorhandenen
[Registrywriter](AUTHENTICATED_TLS_REGISTRY_WRITER.md). Ein konkreter Auftrag muss
die tatsächliche Registrierung auswählen; eine gültige Payload autorisiert sie
nicht. Diese Implementierung adoptiert keine bestehende Lab-CA, öffnet keinen
privaten Key, importiert oder entfernt keinen Trust und verändert keinen
SQL-Server. Öffentlicher Export und TLS-Modus bleiben unverändert.

## Geschlossene Form und Referenzen

Nur `AUTHORITY` ergänzt `SqlServerLab.AuthenticatedTlsRegistryPayload/0.2`.
Client-/Signierpayloads, Index und Gesamtdokument bleiben `0.1`.
Die bisherigen Authorityfelder bleiben erforderlich. Zusätzlich gelten:

| Feld | Bedeutung |
|---|---|
| `CandidateId`, `ClientRef` | Nichtleere kleine D-UUIDs |
| `ClientGeneration` | Positiver JSON-Integer, exakte aktive Clientgeneration |
| `CandidateBindingDigest`, `CertificateSha256`, `EncryptedKeySha256` | Je 64 kleine Hexzeichen; geschützte Kandidatenbindung, DER und Ciphertext |
| `NotBeforeUtc`, `NotAfterUtc` | UTC-Roundtripformat mit sieben Nachkommastellen und `Z`; positive Dauer höchstens 365 Tage |
| `Store` | Genau `CURRENT_USER_ROOT` |
| `TrustStatus` | Genau `IDENTICAL_PREEXISTING_NOT_OWNED`; keine Eigentums-/Entfernungsautorität |
| `KeyStatus` | Genau `CIPHERTEXT_BOUND_NOT_OPENED` |
| `CertificateStatus` | Genau `PROFILE_BOUND_NOT_QUALIFIED` |

Byte-/Tiefen-/Duplicate-Key-Grenzen des Payloadreaders bleiben erhalten.
Die `0.1`-Authorityform bleibt offline lesbar, wird aber nicht schreibend
promoviert. Der alte signer-only Preview lehnt `0.2` ab.

Die Identitätsatome verwenden `SqlServerLab.TlsPayloadIdentity/0.2`, Kind,
ControllerId, LocationId, TrustScopeRef, SignerContextRef, ClientRef, CandidateId.
Kandidat und Kontextreferenzen können unter derselben AuthorityRef nicht
ausgetauscht werden. Die Revisionsatome verwenden
`SqlServerLab.TlsPayloadRevision/0.2`, SignerGeneration, KeyStatus,
CertificateStatus, danach Namen und invariante Werte von ContractVersion,
CandidateId, ClientRef, ClientGeneration, CandidateBindingDigest,
CertificateSha256, EncryptedKeySha256, NotBeforeUtc, NotAfterUtc, Store,
TrustStatus und zuletzt IdentityDigest. Längenrahmung und SHA-256 bleiben gleich.
Alle neuen Bindungsfelder gehen damit in den Indexdigest ein.

Das Gesamtdokument fordert zusätzlich zur Signierkante eine passende
Clientpayload. Aktiv bedeutet exakt aktive Generation; retirierte Offlineformen
dürfen eine frühere Generation referenzieren. Aktive `0.2`-Authorities dürfen
weder TrustScopeRef noch CandidateId noch CertificateSha256 doppelt belegen.
Retirement und eine Erweiterung auf mehrere Clients sind hier nicht schreibbar.

## Frische Beobachtung und Transaktion

`Get-LabAuthenticatedTlsAuthorityPreview` verlangt Root, Controller, Location,
explizit `CURRENT_WINDOWS_PROCESS` und drei geschlossene Payloadbytearrays.
Der bestehende Kandidatenreader prüft die festen privaten ACL-geschützten Dateien,
Root-/Actor-/Receipt-/DER-/Ciphertextbindung und das öffentliche CA-Profil.
Er öffnet kein verschlüsseltes PKCS8. SID, Hostmarker und Profil beider Kontexte
werden ordinal gegen die native Kandidatenidentität verglichen. Die Hashdomains
von Kandidatenactor und Registryactor sind verschieden und werden nicht direkt
gleichgesetzt. Beide Kontextpayloads werden intern frisch beobachtet, auch bei
unveränderter Generation. Binärbelege behalten ihre bisherigen Aussagegrenzen.
Der Frischevergleich verwendet ausschließlich neu serialisierte validierte
Kontextsnapshots; eine spätere Änderung übergebener Callerarrays wird nicht
als Ersatz für deren ursprünglichen Inhalt geprüft.

Der Binder verlangt aktuell gültige exakte DER-/Ciphertext-/Kandidatenwerte und
identischen Trust in der festen ReadOnly-CurrentUser-Root-Lesung. Kandidat und
Trust werden nochmals gelesen. Das bleibt `NON_ATOMIC_READ`: kein gehaltener
Storehandle, keine spätere Frischegarantie, keine Administrator-/ABA-Sicherheit
und kein handlebasierter Rootanker. Fehler geben ausschließlich
`TLS_AUTHORITY_BINDING_INVALID` und `Value=null` zurück.

Der Writer prüft jede aktive `0.2`-Authority samt beiden Kontexten vor Intent,
unmittelbar vor Ersatz und vor Commit. Unveränderte Generationen werden hier
nicht übersprungen. Drift vor Intent hinterlässt keine Transaktion; Drift nach
Installation erhält den Kandidaten ohne falschen Commit. `RECOVER_COMMIT`
verlangt dieselbe frische Gesamtbindung, bevor es ausschließlich die Quittung
schreibt. `RECOVER_ABORT`, Journalreservierung, Locks, Quell-CAS, ACLs und
Originalsicherung bleiben erhalten. Ausgeführte Aktionen werden nie wiederholt.

## Nachweis und Aufwand

Die Suite verwendet eine eigene kurzlebige echte Windows-CA mit DPAPI und
NTFS-ACLs, native Actor-/Rootprüfung und echte Registrytransaktionen. Fehlender
Trust wird tatsächlich read-only gelesen. Positive Storewerte und
Clientbinarymetadaten sind injiziert; kein Storeimport oder SQL-Aufruf.
Sie prüft Inhaltsbindung, Clientkante, Duplikate, Drift bei unveränderten
Generationen, Kandidateninstallation ohne Commit und frische Recovery.
Keyopen-Tripwire und eigener Cleanup begrenzen den Effekt. Die Writersuite
behält ihre separaten tatsächlichen Prozessabbruch-/Konkurrenzfälle.

Die CI-Auswahl ergänzt die neue Suite für ihre konkreten transitiven Quellen,
beide Writer-/Bindungssuites im Nightly und genau eine neue Dateiausnahme für
lokale Metadatenarbeit. Ähnliche Pfade und gemischte Runtimeänderungen bleiben
konservativ. Unbeteiligte Providerstarts entfallen; notwendige statische Checks,
unabhängiger stabiler Review und exakte Headgates bleiben erforderlich.

Tatsächliche bestehende CA-/Trustscopeadoption, private Keyqualifikation,
handlebasierte Rootanker, vollständige native TLS-Matrix, öffentliche Moduswahl,
qualifizierter Export und Toolbelt-Preflight fehlen weiterhin. SC-2026-045 bleibt
gesperrt. [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md) und
[Grenzen](../Quality/KNOWN_LIMITATIONS.md) trennen diese Nachweise.
