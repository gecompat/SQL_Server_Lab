# Private einmalige Trust-Recovery

| Merkmal | Wert |
|---|---|
| Slice | `TLS001-TRUST-RECOVERY-01` |
| Status | `PRIVATE`; native Ausführung dieser Recovery `NOT_EXECUTED` |
| Implementierung | [`AuthenticatedTlsTrustRecovery.ps1`](../../Private/AuthenticatedTlsTrustRecovery.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsTrustRecoveryChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsTrustRecoveryChecks.ps1) |

Die Lane ergänzt den [Trustimport](AUTHENTICATED_TLS_TRUST_IMPORT.md) für
genau einen vollständig gültigen ursprünglichen Intent ohne normalen Commit.
Owner, ursprüngliche Preview, Intent und vier Kandidatendateien bleiben
bytegenau erhalten. Keine Löschung, Rearm, Überschreibung, erfundener normaler
Commit oder allgemeine Registryreparatur. Private Windows-Lane ab PowerShell
7.5, lokal 7.6.6; allgemeine Modul-Mindestversion und `#Requires` bleiben 7.2.

## Explizite Auswahl, Freigabe und Frische

`New-LabAuthenticatedTlsTrustRecoveryPreview` und
`Invoke-LabAuthenticatedTlsTrustRecovery` verlangen ausdrücklich `DataRoot`,
`ControllerId`, `LocationId`, `Context=CURRENT_WINDOWS_PROCESS`, `CandidateId`.
Der Aufruf verlangt zusätzlich `Approval`. Die bestehenden nativen Skalar-,
UUID-, ETS-, Pfad-, ACL- und Fähigkeitsgrenzen gelten vor Mutation. Die
öffentliche CA wird ausschließlich durch den festen bestehenden Binder
gelesen; keine freien Zertifikat-/Store-/Keypfade und kein Keyöffnen oder
DPAPI-Unprotect in dieser Lane.

Das ursprüngliche Journal wird einschließlich Owner und referenzierter Preview
vollständig geprüft. Deren Ausgabezeit darf historisch abgelaufen sein, aber
nicht in der Zukunft liegen; die ursprünglichen Zeitwerte werden nicht geändert.
Ein gerahmter Originaldigest bindet aktuelle vollständige Root-/Actor-/CA-/
Storebindung, Ownerbytehash, Originalintentbytehash, Originalpreviewbytehash
und ursprüngliche Approval-/Previewreferenzen. Jede neue Recoverypreview bindet
diesen Originaldigest, ursprüngliche Approval-/Previewbindung, vollständige
aktuelle Bindung, Storevorzustand und genau fünf Minuten UTC-Gültigkeit.
Neue Previews erhalten intern eine UUID; sie zählen keinen Ausführungsversuch.

Die private konkrete Vorschau liefert diese Digests und Referenzen sowie
CA-Digest/Gültigkeit, tatsächlichen Benutzer, Hostmarker, Profil, festen
`CURRENT_USER_ROOT`-Store und Vorzustand. `QuiescenceStatus=NOT_ATTESTED`,
`Ready=false`, `MutationAllowed=false`; sie erzeugt keine Ausführungsautorität.
Der Trusthinweis benennt Auswirkungen auf andere Anwendungen desselben Benutzers.

`Approval` ist genau ein natives PSCustomObject mit acht NoteProperties:

| Feld | Wert |
|---|---|
| `ContractVersion` | `SqlServerLab.TlsTrustRecoveryApproval/0.1` |
| `ApprovalId` | Kleine nicht leere D-UUID des neuen Auditvorgangs |
| `PreviewId` | Exakte D-UUID der frischen Recoverypreview |
| `PreviewDigest` | Exakter kleiner SHA-256-Hexstring der Recoverypreview |
| `OriginalApprovalId` | Exakte ursprüngliche D-UUID |
| `OriginalIntentByteSha256` | Exakter Originalintentbytehash |
| `AdapterEvidenceId` | Kleine nicht leere D-UUID der separat gesicherten Adapterevidence |
| `Decision` | `APPROVE_ONE_VISIBLE_CURRENT_USER_ROOT_RECOVERY` |

Diese Felder sind Auditclaims, kein Beweis menschlicher Zustimmung, sichtbarer
Fensterwahl oder beendeter Worker. Der vertrauenswürdige Adapter muss die
bereits vorhandene konkrete CA-/Benutzer-/Host-/Profil-/Storefreigabe, die
neue tatsächliche UI-Auswahl und die Beendigung früherer eigener Worker
prüfen und die frische Preview auf Äquivalenz binden. Eine neue Previewnonce
verlangt keine erfundene zusätzliche menschliche Freigabe. Ein fehlender
passender Prozess ist kein globaler Quieszenz- oder Fremdprozessbeweis.

## Unveränderliche Records und ein Versuch

Neue feste Records liegen im bestehenden geschützten Kandidatenjournal,
außerhalb der vier Kandidatendateien:

| Datei | Inhalt |
|---|---|
| `recovery-previews/<PreviewId>.json` | Geschlossene frische Recoverypreview |
| `recovery-intent.json` | Einziger dauerhafter Recoveryintent mit Original-/Approval-/Adapter-/Previewbindung und Vorzustand |
| `recovery-commit.json` | Exakter Recoveryintentbytehash, Originaldigest, CA-/Approvalbindung, tatsächliches Writerergebnis und Ausgang |

Die bestehenden geschützten ACL-/CreateNew-/Flush-/Rücklesehelfer gelten.
Keine Anpassung fremder Eltern. Es werden nur feste begrenzte Records und
jeweils genau referenzierte Previews gelesen, keine Verzeichnissammlung.
Der bestehende einzelne nicht wartende kooperative Lock wird wiederverwendet.
Unter ihm wird der Originalzustand nochmals geprüft und vor Add ein eigener
Intent dauerhaft geschrieben und rückgelesen. Vor und nach der Storegrenze
werden Binding, Originalbytes, Recoverypreview und Intentbytehash frisch
verglichen; nach Add muss auch die Preview noch gültig sein.
Der interne Uhrleser verwendet nativ `DateTime.UtcNow`; es gibt keinen
öffentlichen Caller-Zeitparameter. Die Ablaufregression verschiebt nur dessen
Testuhr nach Add, bei unveränderten Original-/Preview-/Intentbytes und Digests.

Nur die bereits vorhandene feste Public-DER-/CurrentUser/Root-Grenze darf
höchstens einmal aufgerufen werden. `ADD_RETURNED`, exakte aktuelle
Nachbeobachtung und ein dauerhaft rückgelesener passender Recoverycommit
ergeben `RECOVERY_IMPORT_RECORDED`. Ein schon vorher oder am Writeboundary
vorhandener Anker ergibt ausschließlich `RECOVERY_PREEXISTING_UNATTRIBUTED`.
Eine verlorene ursprüngliche Add-Rückgabe wird niemals nachträglich als eigene
Importausführung attribuiert. Der normale ursprüngliche Commit wird nie erzeugt.

Ein vorhandener Recoveryintent ohne vollständig bestätigten passenden Commit
ist terminal `RECOVERY_REQUIRED`; kein zweiter Versuch, keine neue Preview
zur Umgehung. Derselbe vollständig bestätigte Aufruf kann ausschließlich
lesend ohne Lockanlage oder zweiten Add zurückkehren. Andere Freigabebindungen
werden nicht übernommen. Der normale Import bleibt nach Recoveryrecords gesperrt.
Der zentrale `Get-LabAuthenticatedTlsTrustImportStatus` liest Recoveryabschluss,
Drift und unvollständige Records konsistent. Fehlender/abweichender Trust oder
geänderte Original-/Root-/Actor-/CA-/Journalbytes invalidieren den Befund.

## Grenzen und tatsächlicher Stand

Alle Ergebnisse verwenden den geschlossenen `Success/Value/ErrorCode`-
Umschlag ohne rohe Fehler oder Teildaten. Fehler sind Preview-/Approvalinvalid,
`TLS_TRUST_JOURNAL_BUSY` oder `TLS_TRUST_RECOVERY_REQUIRED`. Jeder bestätigte
Befund behält `RemovalAuthority=NONE`, `StoreAtomicity=COOPERATIVE_ONLY`,
Registrierung/TLS `NOT_EXECUTED`, `Ready=false` und `MutationAllowed=false`.
Ein kooperativer Lock und Add-Rückgabe belegen weder globale Store-Atomizität
noch exklusive Nutzung oder spätere Löschautorität. Synchrone Add-Laufzeit,
Policy und UI bleiben ohne Garantie; ein unterbrochener Versuch bleibt unklar.
Keine LocalMachine-, Policy-, C#- oder Protection-Ausweichlane.

Der tatsächlich einmal gestartete ursprüngliche Importworker wurde nach
60 Sekunden beendet. Frische lesende Beobachtung danach: CA `ABSENT`, gültiger
passender Originalintent, kein Commit/Lock, Status `RECOVERY_REQUIRED` und
kein passender alter Worker beobachtet. Der Benutzer meldet keinen sichtbaren
Dialog und wählt ein sichtbares Fenster nach geprüfter Recovery für dieselbe
bereits freigegebene CA. Diese neue Recovery wurde noch nicht ausgeführt.
Der spätere geschützte sichtbare Adapter ist ein eigener reviewpflichtiger
Ausführungsscope nach Integration. Die Implementierungsprüfung verwendet nur
eigene synthetische geschützte Datei-/ACL-/Lockfixtures mit injizierter
Storegrenze; kein realer Kandidat, Journal oder Store wird dabei gelesen.
Registrierung, SQL-Bindung, native Client-/Provider- und TLS-Abnahme bleiben offen.
