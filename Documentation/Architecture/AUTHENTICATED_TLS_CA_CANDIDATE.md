# Privater Windows-CA-Kandidat und lesende Trust-Vorschau

| Merkmal | Wert |
|---|---|
| Slice | `TLS001-CA-CANDIDATE-01` |
| Status | `PRIVATE`; Kandidat bleibt `UNREGISTERED_UNQUALIFIED` |
| Implementierung | [`AuthenticatedTlsCaCandidate.ps1`](../../Private/AuthenticatedTlsCaCandidate.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsCaCandidateChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsCaCandidateChecks.ps1) |
| Fachlicher Zweck | Reviewbare isolierte CA und konkrete Client-Trust-Freigabe für spätere authentifizierte SQL-Labverbindungen |

## Auswahl und Bindung

`New-LabAuthenticatedTlsCaCandidate` verlangt ausdrücklich `DataRoot`,
`ControllerId`, `LocationId`, `Context=CURRENT_WINDOWS_PROCESS` und
`ValidityDays` als natives `int` zwischen 2 und 365. Keine Defaults, freien
Schlüsselpfade, Caller-SIDs, Subjectvorgaben oder Übernahme bestehender CAs.
Referenzen sind die kleinen, nicht leeren D-UUIDs des Anfragevertrags.
Typen und Werte werden vor I/O geprüft; fremde Casts und ETS-Getter bilden
keinen Eingabepfad. Der interne Rootreader prüft anschließend die Pfadform.

Die erste Lane ist ausschließlich Windows mit PowerShell ab 7.5. Der
Engineguard verwendet die native `PSVersionInfo`, vor Verzeichnis-, Key- und
Store-I/O. Ein ungültiges öffentliches PKCS8-Canary prüft zusätzlich die
tatsächliche Span-Methodenbindung ohne persistenten Key. Lokal tatsächlich
geprüft ist PowerShell 7.6.6. 7.5 ist noch kein eigener nativer Nachweis.
Die Datei behält `#Requires -Version 7.2`, damit das bestehende Modul unter
der allgemeinen Mindestversion importierbar bleibt. Die neue Fähigkeit liefert
unter älterer Engine oder Nicht-Windows `TLS_CA_CANDIDATE_NOT_SUPPORTED`;
es gibt keine C#-/Add-Type-Brücke oder Backendausweichwahl.

Der gemeinsame `Get-LabAuthenticatedTlsRootMetadata` prüft frisch ausschließlich
den festen Rootmarker und Storagekatalog nach dem
[Rootvertrag](AUTHENTICATED_TLS_REGISTRY_ROOT.md). Er verlangt keine
TLS-Registrydatei und legt sie nicht an. Der unveränderte Registry-Dateireader
verlangt weiterhin ein vollständiges vorhandenes Dokument. Ein zweiter
Metadatenread vor Fertigstellung beziehungsweise Preview erkennt beobachtete
Drift. Sein gerahmter Digest bindet Pfad und vollständige Marker-/Katalog-
Projektionen; er ist kein atomarer Anker oder nativer Volume-/Hostnachweis.

Die [native Kontextbeobachtung](AUTHENTICATED_TLS_CONTEXT_PREVIEW.md) bindet
intern frisch den nicht impersonierenden Benutzer, Hostmarker und Profilpfad.
Purpose, Kandidaten-ID, Controller, Location, Rootmetadatendigest und
Actor-Digest bilden die Entropie der DPAPI-Bindung. Diese lokal beobachteten
Metadaten sind keine Hostattestation oder Registry-/Ausstellungsautorität.
Der Kandidat erhält intern eine neue UUIDv4; er reserviert keine Registry-
Referenz, AuthorityRef oder menschliche Sequenznummer.

## CA-Profil und private Ablage

Das feste Kandidatenprofil verwendet einen neuen RSA-3072-Schlüssel,
SHA-256 mit PKCS#1-v1.5-Signatur, kritische BasicConstraints `CA=true`,
`pathLen=0` und ausschließlich kritische KeyUsage `KeyCertSign|CrlSign`.
Der synthetische CN enthält nur Projektbezeichnung und Kandidaten-UUID.
Keine SANs, Wildcards, EKUs oder Übernahme fremder Identitäten. UTC-Beginn
ist fünf Minuten rückdatiert; das Ende liegt exakt `ValidityDays` nach diesem
Beginn. Die gesamte Zeitspanne einschließlich Rückdatierung bleibt höchstens
365 Tage. Das Profil ist noch keine SQL-Leaf- oder Clientkompatibilitätsabnahme.

Der feste Bereich ist
`LocalApplicationData/SQL_Server_Lab_AuthenticatedTls/<ControllerId>/<LocationId>/<CandidateId>`.
LocalApplicationData muss unter dem frisch beobachteten Benutzerprofil auf
einem festen lokalen Laufwerk liegen. Reparse-Komponenten und Git-Checkouts
werden gesperrt. Es gibt keine freie private Pfadauswahl. Der eigenständige
Namespace und neue Controller-, Location- und Kandidatenverzeichnisse erhalten ihre geschützte
ACL bei der Erstellung, vor privaten Bytes. Owner ist die aktuelle SID,
Vererbung ist aus, ausschließlich diese SID und SYSTEM erhalten FullControl.
Jede tatsächliche ACL wird rückgelesen und exakt geprüft. Bereits vorhandene
Eltern innerhalb dieses Namespace müssen diesen Vertrag schon erfüllen;
ihre ACLs werden nicht geändert. LocalApplicationData selbst und ein eventuell
vorhandener allgemeiner `SQL_Server_Lab`-Ordner sind keine anzupassenden oder
zu adoptierenden Projekteltern. Deren vorhandene ACLs und Bytes bleiben erhalten.
Ein schon vorhandenes Kandidatenverzeichnis wird abgelehnt. Dateien werden
mit geschützter ACL und `CreateNew` erstellt und niemals überschrieben.

Vier feste Dateien gehören zum Kandidaten:

| Datei | Inhalt |
|---|---|
| `intent.json` | Geschlossener Besitz-/Bindungsclaim mit UUID, Actor-/Rootdigest und explizitem Teilzustands-/Recoverystatus |
| `ca.der` | Ausschließlich öffentliches DER-Zertifikat |
| `key.dpapi` | Ausschließlich DPAPI-CurrentUser-verschlüsseltes PKCS8 |
| `receipt.json` | Geschlossene Fertigstellungsmetadaten mit Bindungen, Gültigkeit und SHA-256 der öffentlichen und verschlüsselten Bytes |

PKCS8-Klartext existiert nur kurz in Bytearrays und wird im `finally` gelöscht;
RSA-, Zertifikats- und Storeobjekte werden freigegeben. Keine Klartext-PEM-,
PFX-, Passwort- oder privaten Keybytes in Dateien, Streams, Ergebnissen oder
Fehlern. Ciphertext und öffentliche Dateien werden rückgelesen. DER muss
vollständig konsumiert sein, das exakte Profil und eine echte Selbstsignatur
haben. DPAPI-Wiedereröffnung, vollständiger PKCS8-Verbrauch und eine zufällige
Signatur mit öffentlicher Prüfung belegen, dass der persistierte verschlüsselte
Key zum öffentlichen Zertifikat passt. Receiptbytes werden ebenfalls rückgelesen.
Erfolg meldet `KeyMatchStatus=REOPEN_SIGN_VERIFY`.

DPAPI ersetzt weder Backups noch Wiederherstellbarkeit bei Profil-/Keyverlust.
Es wird keine Hardware- oder Nicht-Exportierbarkeit behauptet. Der Schutz
grenzt andere reguläre Benutzer ab; Administratoren und feindlicher Code mit
derselben SID liegen außerhalb dieses Schutzversprechens. Pfad- und ACL-
Prüfungen sind keine handlebasierte atomare Abwehr nicht kooperierender
Umbenennung oder ABA. Die allgemeine Registry-/Crashtransaktion bleibt offen.

## Lesende konkrete Trust-Vorschau

Der gemeinsame interne `Get-LabTlsCaCandidateBinding` kapselt jetzt die
frische Root-/Actor-/ACL-/Datei-/DER-Prüfung ohne Store- oder Keyöffnung.
Sein gerahmter Digest bindet Root, Actor, DER, Intent, Receipt und Ciphertext.
Die bestehende Trustvorschau ergänzt weiterhin ausschließlich den lesenden
Storevergleich und wiederholt die Bindungsprüfung. Die
[CSR-Lane](AUTHENTICATED_TLS_LEAF_CSR.md) verwendet dieselbe Bindung ohne
Storezugriff. `Open-LabTlsCaSigningKey` teilt den bisherigen DPAPI-Reopen-/
PKCS8-/Sign/Verify-Code; der Kandidatenchecker entsorgt dessen RSA unmittelbar,
die CSR-Lane nach Signierung im `finally`. Keine neue Registryautorität.

`Get-LabAuthenticatedTlsCaTrustPreview` verlangt dieselben ausdrücklichen
Root-/Kontextangaben und eine vorhandene `CandidateId`. Es prüft alle privaten
ACLs, die vier festen Dateinamen, geschlossene Intent-/Receiptformen,
Root-/Actorbindung, DER-Profil/Selbstsignatur und beide Bytehashes frisch.
JSON-Strings bleiben Strings; Schlüsselmenge, Identitäts-/Status-/Datumswerte,
Digests, Subject und Issuer werden ordinal verglichen. Kulturvergleiche dürfen
weder Zero Width Space noch Soft Hyphen als unveränderte Metadaten akzeptieren.
Duplicate-/Casealias-, Zusatz-, Array- und Objektwerte sind gesperrt.
Der verschlüsselte Key wird nur gehasht, niemals
entschlüsselt oder zum Signieren geöffnet. Erneute Datei-/Bindungsreads
erkennen beobachtete Drift; Snapshotstatus bleibt `NON_ATOMIC_READ`.

Die einzige Storeoperation öffnet den tatsächlich aktuellen
`CurrentUser/Root` mit `ReadOnly|OpenExistingOnly`. Der Vergleich verwendet
die vollständigen öffentlichen Zertifikatsbytes, keine Namen oder alleinige
Thumbprints. Ergebnis ist `ABSENT` oder `IDENTICAL_PREEXISTING_NOT_OWNED`.
Identischer vorhandener Trust wird niemals zum eigenen Cleanupobjekt.
Eine künftige Einfuhr kann andere Anwendungen desselben Windows-Benutzers
beeinflussen; dieser Effekt steht ausdrücklich in der Preview.

Die private Preview enthält Kandidaten-ID, öffentlichen SHA-256, UTC-Gültigkeit,
gewählten Benutzer, Hostmarker, Profil, Store und Vorzustandsklassifikation.
Sie bleibt lokal und enthält keine Schlüsselbytes. `Ready` und
`MutationAllowed` sind false; Registrierung, Qualifikation und TLS bleiben
`NOT_EXECUTED`. Die tatsächlichen Toolbelt-Clientbinaries werden ausschließlich
über die bestehende Kontextvorschau beobachtet; installierte oder dort gelesene
Bytes beweisen keinen geladenen ODBC-Treiber und keine SQL-Verbindung.

## Fehler, Recovery und nächste Grenze

Alle Operationen liefern nur `Success`, `Value`, `ErrorCode`; Fehler enthalten
keinen Teilbefund, Pfad, Key oder rohe Exception. Sobald eigene Verzeichnisse
oder Kandidatenartefakte entstanden sein können, liefert die Anlage
`TLS_CA_CANDIDATE_RECOVERY_REQUIRED`. Eigene Teilzustände bleiben absichtlich
erhalten; es gibt keine allgemeine Löschung oder stille Wiederaufnahme.
`intent.json` ist keine allgemeine Writer-/Crashjournalimplementierung.
Auch ein leerer, nach fehlgeschlagener Erstanlage verbleibender privater
Elternbereich kann Recovery erfordern. Tests entfernen nur ihre zuvor
verifizierte eigene Tempgrenze und prüfen deren vollständigen Abbau.

Inzwischen ist eine eigene dauerhafte CA außerhalb der Tests lokal angelegt;
DPAPI-Reopen/Sign/Verify und frische lesende Trustvorschau bestanden.
Die konkrete menschliche Freigabe ist gesichert. Die getrennte
[Trust-Importtransaktion](AUTHENTICATED_TLS_TRUST_IMPORT.md) implementiert jetzt
geschützte Preview-/Intent-/Commitmetadaten, kooperativen Lock und lesenden
Recoverybefund. Die vier Kandidatendateien bleiben unverändert; reale
Storemutation wird von deren Tests nicht ausgeführt. Der separat geprüfte
echte Worker wurde einmal nach 60 Sekunden beendet: frisch lesend CA `ABSENT`,
Journal `RECOVERY_REQUIRED`, passender gültiger Intent, kein Commit/Lock und
kein bestätigter Import. UI-Wahl: kein Dialog sichtbar, sichtbares Fenster nach geprüfter Recovery gewünscht; kein automatischer Retry oder Journalremove.
Separate Removalfreigabe,
neue eigene SQL-Fixtures und vollständige TLS-Abnahme bleiben offen. Geschützte sechs
Toolbelt-Ziele, erhaltene SSISDB-Quelle, fremde Ressourcen und frühere
Löschsperren bleiben unverändert. Der
[Registry-Writer-/Crashvertrag](../Project_Planning/TLS_001_CONTEXT_REGISTRATION_DESIGN.md)
bleibt offen. Keine CA-Registrierung, Leafausstellung, SQL-Bindung, Runtime-
oder authentifizierte TLS-Abnahme durch diesen Slice; Toolbelt SC-2026-045
bleibt bis zur echten Lab-Abnahme blockiert.

Die geprüften Microsoft-Primärquellen sind
[ProtectedData.Protect](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.protecteddata.protect?view=windowsdesktop-10.0),
[FileSystemAclExtensions.Create](https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemaclextensions.create?view=net-10.0),
[CertificateRequest.CreateSelfSigned](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.certificaterequest.createselfsigned?view=net-10.0)
und [RSA.ImportPkcs8PrivateKey](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.importpkcs8privatekey?view=net-10.0).
