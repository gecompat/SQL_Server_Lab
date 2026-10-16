# Privater Windows-Trustimport mit Intent und Commit

| Merkmal | Wert |
|---|---|
| Slice | `TLS001-TRUST-IMPORT-01` |
| Status | `PRIVATE`; nativer Versuch `RECOVERY_REQUIRED`, kein bestätigter Import |
| Implementierung | [`AuthenticatedTlsTrustImport.ps1`](../../Private/AuthenticatedTlsTrustImport.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsTrustImportChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsTrustImportChecks.ps1) |
| Fachlicher Zweck | Explizit genehmigter öffentlicher CA-Trust für spätere authentifizierte SQL-Labverbindungen |

## Private Einstiegspunkte und menschliche Freigabe

Die Funktionen sind nicht exportiert. Alle drei verlangen ausdrücklich
`DataRoot`, `ControllerId`, `LocationId`, `Context=CURRENT_WINDOWS_PROCESS`
und `CandidateId`. Es gelten die geschlossenen Typ-/UUID-/ETS-Grenzen und
die Windows-/PowerShell-Fähigkeiten des
[CA-Kandidaten](AUTHENTICATED_TLS_CA_CANDIDATE.md). IDs werden als frische
CLR-D-UUIDs normalisiert. Kein freier Store- oder Journalpfad, keine Caller-SID,
kein Schlüssel oder Zertifikat als frei übergebener Importinhalt.

| Funktion | Zusätzliche Eingabe | Ergebnis |
|---|---|---|
| `New-LabAuthenticatedTlsTrustImportPreview` | keine | Neue intern erzeugte Preview-ID, gerahmter Digest, fünf Minuten Gültigkeit und konkrete private Trustprojektion; schreibt nur geschützte Previewmetadaten |
| `Invoke-LabAuthenticatedTlsTrustImport` | `Approval` | Einmaliger Importversuch nach exakter Bindungsprüfung oder geschlossene Ablehnung; vorhandenes Intent verhindert blindes Wiederholen |
| `Get-LabAuthenticatedTlsTrustImportStatus` | keine | Ausschließlich lesender Journal-/Storebefund, auch nach unterbrochener Operation |

`Approval` ist ein natives `PSCustomObject` mit exakt fünf NoteProperties:

| Feld | Zulässiger Wert |
|---|---|
| `ContractVersion` | `SqlServerLab.TlsTrustApproval/0.1` |
| `ApprovalId` | Kleine, nicht leere D-UUID des lokalen Freigabe-/Auditvorgangs |
| `PreviewId` | Exakte intern erzeugte Preview-D-UUID |
| `PreviewDigest` | Exakter kleiner SHA-256-Hexstring der genehmigten Preview |
| `Decision` | `APPROVE_CURRENT_USER_ROOT_PUBLIC_DER` |

Die Form ist kein kryptographischer Beweis einer menschlichen Entscheidung.
Der vertrauenswürdige aufrufende Adapter muss eine tatsächlich vorhandene
menschliche Freigabe dieser konkreten CA-, Identitäts- und Storeprojektion
belegen. Eine frisch erzeugte Preview darf gegen eine bereits gesicherte
vollständige Freigabe auf Äquivalenz geprüft werden; eine neue interne Nonce
erfordert keine erfundene zusätzliche menschliche Bestätigung. Die Funktion
erzeugt selbst keine Ausführungsautorität. Eine alleinige syntaktisch richtige
ApprovalId ersetzt weder den exakten Previewdigest noch die aktuelle Bindung.

Die private Preview liefert `PreviewId`, `PreviewDigest`, `ExpiresUtc`,
`CandidateId`, `CertificateSha256`, `NotBeforeUtc`, `NotAfterUtc`, `UserSid`,
`HostMarker`, `ProfilePath`, festen `Store`, `Prestate` und `ApprovalEffect`.
Status ist `AWAITING_EXPLICIT_APPROVAL`; Registrierung und TLS sind
`NOT_EXECUTED`, `Ready` und `MutationAllowed` false. Der Wirkungshinweis
benennt andere Anwendungen desselben Windows-Benutzers.

## Frische Quellen und exakte Bindung

Jeder Vorgang liest den Kandidaten durch die bestehende lesende Trustvorschau,
frische native Benutzer-/Hostmarker-/Profilmetadaten, registrierte Rootmarker-/
Katalogmetadaten und die vier geschützten Kandidatendateien. Der gerahmte
Bindingdigest bindet Controller, Location, Kandidaten-ID, festen Store,
Root- und Actor-Digest, öffentliche DER-Bytes sowie Receipt-, Intent- und
verschlüsselte Keybytes. Der private Key wird nur als Ciphertext gehasht und
niemals entschlüsselt, signierend geöffnet oder in einen Store übertragen.

Der Previewdigest bindet Bindingdigest, intern erzeugte Preview-ID,
Vorzustandsklassifikation und invariant gespeicherte UTC-Ticks. Die Frist
beträgt exakt fünf Minuten; zukünftige, abgelaufene oder strukturell abweichende
Zeitwerte sperren. Alle Stringgleichheiten sind ordinal. JSON ist begrenzt
und geschlossen; Casealiases, Zusatzfelder, Unicode-Äquivalenz, fremde Getter
oder konvertierbare Objekte dürfen keine Identität ersetzen.

Unter der kooperativen Sperre werden Freigabe und aktuelle Quellen geprüft.
Nach dauerhaft geschriebenem Intent werden Quelle, Preview und Intentbytes
vor Add erneut geprüft. Auch die native Schreibgrenze prüft die Frist vor
Storeöffnung und unmittelbar vor Add. Nach Add müssen exakt dieselben öffentlichen Bytes
im tatsächlichen CurrentUser/Root beobachtet werden und die übrigen Bindungen
weiter passen. Ein anderer Benutzer, ein anderer Hostmarker, geänderte
Root-/Kandidatenbytes oder unbekannte Aktualität ergeben keinen Importbeweis.
PID und Prozessstart sind keine persistente Reopenbindung.

## Feste private Ablage und Ablauf

Das Journal liegt außerhalb des abgeschlossenen Kandidaten unter
`LocalApplicationData/SQL_Server_Lab_AuthenticatedTls/<ControllerId>/<LocationId>/trust-imports/<CandidateId>/`.
Die vier Kandidatendateien werden nicht verändert. Eltern ab dem privaten
Namespace müssen bereits geschützte ACLs haben; neue Journalverzeichnisse und
Dateien verwenden vor Bytes dieselben Owner-/SID-/SYSTEM-/Vererbungsgrenzen
wie der Kandidat. Fremde oder breite Eltern werden nicht angepasst. Ein
vorhandenes Journal ohne passenden geschützten `owner.json`-Claim wird nicht
adoptiert. Reparse-/Git-/Remotegrenzen bleiben erhalten.

| Datei | Bedeutung |
|---|---|
| `owner.json` | Geschlossener lokaler Journalclaim an Kandidat, Controller, Location, Root- und Actor-Digest |
| `previews/<PreviewId>.json` | Unveränderliche fünf Minuten gültige Preview; kein Storeintent |
| `intent.json` | Ein fester dauerhafter Importintent je Kandidat, vor dem ersten Storeversuch |
| `commit.json` | Exakter Intentbytehash, Freigabe-/Previewbindung, Zertifikatsdigest und bestätigter Ausgang |

Dateien verwenden `CreateNew`, geschützte ACLs, `Flush(true)` und geprüfte
Rücklesung; keine Überschreibung oder automatische Adoption. Status und
Recovery lesen ausschließlich diese festen begrenzten Dateien und die genau
referenzierte Preview. Es gibt keinen unbeschränkten Journal-/Verzeichnis-
oder Fremddiagnosescan. Ältere nicht verwendete Previews werden nicht automatisch
gelöscht; eine Retention-/Removalfunktion gehört nicht zu diesem Slice.

Die Sperre ist ein einzelner `CreateNew`-/`FileShare.None`-/`DeleteOnClose`-
Versuch auf `<CandidateId>.lock` im gemeinsamen `trust-imports`-Elternordner.
Die tatsächliche ACL wird am offenen Handle geprüft. Ein konkurrierendes,
verwaistes oder fremdes Lock wird nicht übernommen oder entfernt. Es gibt
keine Warteschleife oder wiederholten Storeversuch; Lockbelegung liefert
`TLS_TRUST_JOURNAL_BUSY`. Der lesende Status legt kein Lock an.

Ein schon vorher identischer Trustanker ergibt `PREEXISTING_NOT_OWNED`,
ohne Intent oder Add. Die feste native Schreibgrenze öffnet ausschließlich
`CurrentUser/Root` mit `ReadWrite|OpenExistingOnly`, prüft öffentliche DER und
frische Actorbindung und vergleicht erneut vollständige vorhandene Bytes.
Findet sie den Anker dort bereits, erfolgt kein Add; ein anschließendes
Commit markiert ebenfalls `PREEXISTING_NOT_OWNED`. Nur `ADD_RETURNED` plus
exakte Nachbeobachtung und rückgelesenes Commit ergeben `OWNED_IMPORT_RECORDED`.
Der feste Writer begrenzt die lokal beobachtete Storekollektion auf 8192
Zertifikate und gibt keine Fremdzertifikate aus.

## Status, Recovery und Aussagegrenzen

Alle Funktionen liefern nur `Success`, `Value`, `ErrorCode`. Fehler enthalten
keinen Teilbefund, Pfad, Key oder rohe Exception. Unbekannte oder geänderte
Freigaben sperren vor Storewrite. Sobald ein Intent begonnen wurde, ergeben
unbestätigte Fehler `TLS_TRUST_RECOVERY_REQUIRED`. Intent ohne bestätigtes
Commit bleibt lesend `RECOVERY_REQUIRED`, unabhängig davon, ob die CA gerade
im Store sichtbar ist. Es gibt keinen blinden Retry, automatische Löschung,
Rücknahme, Besitzübernahme oder allgemeine Registryreparatur.

Der Status unterscheidet `NO_TRANSACTION`, `AWAITING_APPROVAL`, `BUSY`,
`RECOVERY_REQUIRED`, `OWNED_IMPORT_RECORDED` und `PREEXISTING_NOT_OWNED`.
Ein vollständig persistiertes gültiges Commit kann nach verlorenem Aufrufer-
Ergebnis lesend wieder bestätigt werden. Identische genehmigte Wiederholung
liefert den Befund ohne zweiten Add; andere Freigaben werden nicht übernommen.
Eine fehlende oder abweichende Nachbeobachtung sowie unlesbare/ungültige
Journal- oder Kandidatenbindung sperren die Aussage und verlangen Recovery.
Der Befund ist ein nicht atomarer Snapshot; ein späterer Wechsel kann ihn
sofort veralten lassen.

Jeder Erfolgs-/Statusbefund enthält `RemovalAuthority=NONE` und
`StoreAtomicity=COOPERATIVE_ONLY`. Der Lock serialisiert nur kooperierende
Aufrufer dieses Journals. Add und Nachbeobachtung beweisen weder globale
Store-Atomizität noch ausschließliche Nutzung durch das Lab. Administrative
oder externe Storeänderungen sowie feindlicher Code derselben SID werden
nicht ausgeschlossen. Auch ein eigener Importreceipt erlaubt keinen späteren
ungeprüften Removal; dafür bleiben separate Vorschau, Verbraucherprüfung
und ausdrückliche Freigabe erforderlich.

`X509Store.Add` ist synchron und hat keinen eigenen Timeout. Nicht interaktive
Ausführung, Provider-/Policy-/UI-Verhalten und begrenzte native Laufzeit sind
hier nicht belegt. Der vertrauenswürdige Ausführungsadapter kann einen eigenen
begrenzten Worker verwenden. Timeout/Abbruch nach Intent bleibt unklar und
erfordert ausschließlich lesende Recovery; kein Policy-, Protection- oder
LocalMachine-Bypass. Ein tatsächlicher nativer Versuch bleibt von den
injizierten Suiteprüfungen getrennt; Nachbeobachtung entscheidet über Erfolg.

Es existiert inzwischen ein eigener dauerhafter CA-Kandidat außerhalb der
Testfixtures; seine DPAPI-Wiedereröffnung und frische lesende Trustvorschau
wurden lokal erfolgreich ausgeführt. Die konkrete menschliche Importfreigabe
ist gesichert. Der separat geprüfte Worker wurde genau einmal ausgeführt und
nach 60 Sekunden beendet. Frisch lesend: CA `ABSENT`, Journal
`RECOVERY_REQUIRED`, gültiger passender Intent, kein Commit und kein Lock.
Kein bestätigter Import; die konkrete UI-Rückfrage bleibt offen. Kein Retry,
Journalremove oder Storewrite aus diesem Befund. Reale Identitäten, Pfade und Digests bleiben ausschließlich
lokal. Native Storemutation wird von dieser Testsuite nicht ausgeführt oder
qualifiziert. Die CA bleibt unregistriert; ein Trustimport ist keine Leaf-,
SQL-, Provider- oder authentifizierte TLS-Lab-Abnahme. Toolbelt SC-2026-045
bleibt bis zu dieser echten Abnahme blockiert.

Microsoft-Primärquellen:
[X509Store.Add](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.x509store.add?view=net-10.0),
[OpenFlags](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.openflags?view=net-10.0)
und [FileOptions](https://learn.microsoft.com/en-us/dotnet/api/system.io.fileoptions?view=net-10.0).
