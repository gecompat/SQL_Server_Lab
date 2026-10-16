# Private CSR-zu-Serverleaf-Kryptolane

| Merkmal | Wert |
|---|---|
| Slice | `TLS001-LEAF-CSR-01` |
| Status | `PRIVATE`; `UNREGISTERED_UNQUALIFIED` |
| Implementierung | [`AuthenticatedTlsLeafCsr.ps1`](../../Private/AuthenticatedTlsLeafCsr.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsLeafCsrChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsLeafCsrChecks.ps1) |

`New-LabAuthenticatedTlsServerLeaf` erzeugt ausschließlich ein öffentliches
Serverleaf aus einem geprüften öffentlichen CSR und dem ausdrücklich gewählten
[CA-Kandidaten](AUTHENTICATED_TLS_CA_CANDIDATE.md). Es schreibt keine Dateien,
öffnet keinen Zertifikatstore und verändert weder Kandidat noch Trustjournal.
Ein Erfolg belegt Kryptographie, keine native Target-, SQL-, CSP-/KeySpec-,
Dienst- oder Clientqualifikation. Die separat ausgeführte begrenzte
[Windows-Probe](../Quality/TLS_WINDOWS_SQL2025_PARTIAL_ACCEPTANCE_2026-10-16.md)
ersetzt nicht die vollständige Matrix. Das feste synthetische Subject und
enge Attributset sind kein bereits passender Windows-certreq-/SQL-Request.

## Expliziter Aufruf und geschlossene Eingabe

Die gemeinsamen Parameter sind ausdrücklich zu setzen: `DataRoot`, `ControllerId`,
`LocationId`, `Context=CURRENT_WINDOWS_PROCESS`, `CandidateId`, `CsrDer`,
`Identity` und die ausgewählte Laufzeit. Root-/UUID-/Kontextformen entsprechen dem
Kandidatenvertrag. Keine freien Keypfade, Caller-SIDs oder AuthorityRefs.
`CsrDer` ist ein natives `byte[]` von 1 bis 16384 Bytes; die Funktion kopiert
die nativen Bytes ohne ETS-Getter oder überschreibbare Clone-Methode.
Der bestehende Pfad verlangt `ValidityDays` als natives `int` von 1 bis 30
und `ValiditySeconds=null`. Für echte Ablaufgegenfälle gibt es alternativ
`ValidityDays=null` und `ValiditySeconds` als natives `int` von 30 bis 300.
Beide gleichzeitig, fehlende Laufzeit, fremde Typen und Werte außerhalb der
Grenzen werden vor Kandidat-/Key-I/O abgelehnt. Beginn bleibt ausschließlich
die tatsächliche auf Sekunden abgerundete UTC-Zeit, Ende liegt innerhalb der
CA-Frist. Keine Rückdatierung, Caller-Uhr oder automatische Kürzung.
Die kurze Laufzeit ist keine Registry-, Provider- oder TLS-Qualifikation;
die späteren [echten Windows-Ablaufgegenfälle](../Quality/TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md)
bestanden mit beiden Stacks. Weitere Client-/Providerkombinationen bleiben offen.
`Identity` ist genau die
geschlossene native Objektform `{Kind,Value}` des
[Anfragevertrags](AUTHENTICATED_TLS_REQUEST.md): kanonische IP oder expliziter
kleingeschriebener ASCII-DNS-Name. Keine Wildcard, numerische DNS-Ausweichform,
CN-, Hostname- oder Resolverersetzung. Diese Eingaben werden vor Datei-/Key-I/O
geprüft; der CSR wird vor dem Lesen des Kandidaten validiert.

Die bestehende Windows-/PowerShell-ab-7.5-Fähigkeitssperre läuft vor I/O.
Tatsächlich lokal geprüft ist 7.6.6. Die Datei bleibt unter der allgemeinen
Mindestversion 7.2 importierbar; Nicht-Windows oder ältere Engine liefert
`TLS_LEAF_NOT_SUPPORTED`. Keine C#-/Add-Type-Brücke oder Backendfallback.

## CSR-Proof-of-Possession und festes Zertifikatprofil

DER muss vollständig konsumiert sein. Akzeptiert werden ausschließlich
PKCS#10 Version 0, Subject `CN=SQL_Server_Lab Server Leaf` als genau ein CN
in der bisherigen BCL-DER-Form oder der kanonischen UTF8-DER-Form von OpenSSL,
RSA-3072 mit Exponent 65537 und SHA-256/PKCS#1-v1.5-Signatur. Beide erlaubten
Subjectformen werden vollständig gegen konstruiertes DER verglichen; andere
Namen, zusätzliche RDNs und Signaturdrift bleiben vor Kandidat-/Key-I/O gesperrt.
Der öffentliche SPKI wird vor der Signaturprüfung importiert und auf Größe
und Exponent begrenzt. Es entsteht dadurch kein privater Leafkey auf dem Host.
Auch der enthaltene PKCS1-RSAPublicKey im SPKI-BITSTRING muss vollständig DER
sein: genau zwei positive INTEGER, keine Restbytes oder BER-Längenform. Der
BCL-Import allein ist dafür kein Nachweis.
Nach frischer Kandidatenbindung wird der validierte CSR-SPKI bytegenau über
ordinale Base64-Gleichheit mit dem öffentlichen CA-SPKI verglichen. Derselbe
Schlüssel ist als Leaf gesperrt, bevor der private CA-Key geöffnet wird.
Der BCL-Loader verwendet `Default`, prüft also die echte CSR-Signatur;
`SkipSignatureValidation` und `UnsafeLoadCertificateExtensions` sind gesperrt.

Genau ein `extensionRequest`-Attribut mit genau einem nichtkritischen SAN
ist zulässig. Dieser enthält genau den angeforderten typisierten IP- oder
DNS-Wert. Weitere Attribute, SANs, Erweiterungen, andere Signaturverfahren,
schwache/andere Keys, Zusatzbytes und kaputte Signaturen sperren die Anfrage.
CSR-Erweiterungen werden nicht übernommen. Eine neue CertificateRequest aus
dem geprüften öffentlichen Schlüssel erhält ausschließlich:

- kritische BasicConstraints `CA=false`, ohne PathLength;
- kritische KeyUsage `DigitalSignature|KeyEncipherment`;
- nichtkritische EKU ausschließlich `ServerAuthentication`;
- genau den nichtkritischen angeforderten SAN.

Beginn ist die aktuelle UTC-Sekunde, Ende exakt die ausgewählten
`ValidityDays` oder `ValiditySeconds` später.
Die vollständige Frist muss in der CA-Gültigkeit liegen; kein stilles Kürzen
oder Profilwechsel. Ein neuer zufälliger positiver 16-Byte-Serial wird erzeugt.
Öffentliches DER, Identität, SPKI, Subject/Issuer, alle vier Erweiterungen,
Gültigkeit und tatsächliche CA-Signatur werden danach unabhängig rückgeprüft.

## Bindung und private Schlüsselöffnung

Der gemeinsame `Get-LabTlsCaCandidateBinding` liest feste Rootmarker/Katalog,
intern frische native SID-/Host-/Profilbindung, geschützte Pfade/ACLs und alle
vier unveränderten Kandidatendateien. Er benötigt keine Registrydatei und
öffnet keinen Store oder privaten Schlüssel. Sein gerahmter Digest bindet
Root, Actor, öffentliches DER, Intent, Receipt und Ciphertext. Wiederholte
Reads vor der Schlüsselöffnung und nach Signierung sperren beobachtete Drift.
Diese Prüfungen sind kein atomarer Snapshot oder Hostattestationsnachweis.

Erst danach öffnet `Open-LabTlsCaSigningKey` das exakt persistierte PKCS8 mit
der bestehenden purpose-/kandidaten-/Root-/Actor-gebundenen DPAPI-CurrentUser-
Entropie. Vollständiger PKCS8-Verbrauch und zufälliges Sign/Verify gegen das
öffentliche CA-Zertifikat beweisen den Match. Klartextarrays werden im
`finally` gelöscht; RSA- und Zertifikatsressourcen werden freigegeben.
Der bisherige Kandidatenchecker verwendet denselben Helper mit unmittelbarem
Dispose. Keine private CA-/Leafkeyausgabe, PEM, PFX oder Passwörter.

## Ergebnis und nachfolgende Autoritätsgrenze

Der geschlossene Umschlag lautet `{Success,Value,ErrorCode}`. Fehler liefern
`Value=null` und `TLS_LEAF_CSR_INVALID` beziehungsweise die Fähigkeitssperre,
ohne Teilzertifikate oder rohe Ausnahmedaten. Erfolg liefert ausschließlich
öffentliches `CertificateDer`, dessen SHA-256, CSR-/CA-Digests, angeforderte
Identität, UTC-Fristen, `KeyMatchStatus=DPAPI_REOPEN_SIGN_VERIFY` und
`SignatureStatus=VERIFIED`. Status bleibt `UNREGISTERED_UNQUALIFIED`,
`Ready=false`, `MutationAllowed=false`; NativeTarget, Registrierung und TLS
bleiben ausdrücklich `NOT_EXECUTED`.

Der CSR ist ein kryptographischer Key-/Identitätsclaim, keine Run-, Target-,
Runtimebesitz-, Windows-CSP-/KeySpec- oder SQL-Dienstrechteautorität. Spätere
eigene Runtimeproben müssen targetlokale Keyerzeugung, Transport, native
SQL-Anforderungen, exakte Clientidentität und beide tatsächlichen Clientstacks
getrennt qualifizieren. Es gibt keinen Export- oder Provider-Cutover. Auch
ein tatsächlicher Trustimport würde diese Lücken nicht schließen.

Microsoft-Primärquellen:
[LoadSigningRequest](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequest.loadsigningrequest?view=net-10.0),
[Loaderoptionen](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequestloadoptions?view=net-10.0),
[ImportSubjectPublicKeyInfo](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.importsubjectpublickeyinfo?view=net-10.0),
[CertificateRequest.Create](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequest.create?view=net-10.0)
und [SQL-Zertifikatsanforderungen](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/certificate-requirements?view=sql-server-ver17).
