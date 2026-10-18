# Hyper-V: Windows-Aktivierung und CSP-/CSR-Charakterisierung

| Merkmal | Ausgeführter Scope |
|---|---|
| Datum | 2026-10-18, UTC |
| Native Produktquelle | `b10967a3bb43b8087c6d8ba36d6f5f30d73c03b9` |
| Gast | Eigene Windows Server 2025 Standard Evaluation, SQL-Prepared-Klon |
| SQL-Medium | SQL Server 2025 RTM, 17.0.1000.7; kein CU9 |
| Abschluss | Aktivierung und ursprüngliche CSP-Charakterisierung bestanden; späterer vorhandene-Key-CSR nativ erstellt, ursprünglicher Hostabschluss fehlgeschlagen; VM gestoppt und erhalten |
| Nicht abgenommen | SQL CompleteImage, Zertifikatannahme, SQL-ServiceACL, SQL-TLS, qualifizierter Export |

Dies sind getrennte tatsächlich ausgeführte Abschnitte mit geschützten
Quellen, festen Supervisoren, Einversuchsgrenzen und dauerhaften Journalen.
Quell-/Manifestbindungen, Autorisierung, native Identitäten, öffentlicher CSR,
Prozessbindungen und vollständige Ergebnisse bleiben privat außerhalb von Git.
Es gab keine Entfernung des erfolgreichen Runs und keinen Removal-Cleanup-Pass.

## Onlineaktivierung nach konkreter menschlicher Freigabe

Die vorhandene eigene Off-VM wurde einmal über den öffentlichen Reparaturpfad
gestartet. Der normale Windows-Actor verwendete seinen Hyper-V-Administratortoken,
keinen UAC-/RunAs-Start. `EvaluationOnline/AllowTemporary` erlaubte genau einen
Gastaktivierungsblock mit höchstens zwei API-Anfragen innerhalb dieses Blocks.
Die tatsächliche Antwort war `EVALUATION_ACTIVE`, `LicenseStatus=1`, `NoOp=false`.
Zwei ist eine Obergrenze, keine Behauptung zweier ausgeführter Anfragen.

Der bestehende externe Switch wurde zeitweilig über eine eigene NIC genutzt.
Dieser Zugang war keine Ziel-/Portallowlist; Hintergrunddienste konnten ihn
nutzen. Ein harter Netz-Cutoff bei unbekanntem Controllerende war nicht zugesagt.
Tatsächlich wurden Verbraucherende und ursprüngliches Adapterset nachgewiesen.
Die temporäre NIC war danach nativ abwesend; der gebundene `CLEANED`-Journal
blieb erhalten. Die ursprüngliche Policy `VerifyOnly/Denied` wurde wieder
gespeichert und der eigene Run öffentlich gestoppt. Worker-Exitcode 0, Ende
beider Controller, native VM `Off` und Run `STOPPED` wurden frisch bestätigt.
Die einmalige Freigabe ist verbraucht; keine weitere Aktivierungs-/Egress- oder
UAC-Autorität daraus.

## Getrennte isolierte CSP-Fortsetzung

Die zweite Ausführung setzte dieselbe eigene VM mit `VerifyOnly/Denied` fort:
aktive Evaluation erneut gelesen, keine Aktivierungsanfrage oder externe NIC.
Die gebundene Gastvorprüfung bestätigte tatsächliche MAC/IP, keine IPv4-
Defaultroute, PowerShell 5 im 64-Bit-Prozess, fehlende eigene Schlüsselnamespace
und die native `certreq.exe`-Binärbindung. Genau ein mutierender Gastblock
erzeugte Schlüssel und öffentlichen CSR:

- nicht exportierbarer Machine-RSA-Schlüssel, 3072 Bit, Exponent 65537;
- `Microsoft RSA SChannel Cryptographic Provider`, Providertyp 12;
- tatsächlich gelesenes `KeySpec=1` / `AT_KEYEXCHANGE`;
- PKCS#10-DER, SHA-256/PKCS#1-v1.5-Signatur, einzelner Maschinen-CN;
- genau der erwartete nichtkritische IP-SAN.

Der Host prüfte echte CSR-Signatur, exakten CN, Übereinstimmung mit dem
tatsächlich öffentlichen CSP-Schlüssel sowie SAN und vollständiges DER.
Der private Schlüssel wurde nicht exportiert. Der öffentliche CSR enthält
zusätzlich die nichtkritische S/MIME-Capabilities-Erweiterung. Der vorhandene
enge Reader lehnte ihn korrekt als `REJECTED_CURRENT_FIXED_PROFILE` ab.
Ergebnis: `PASS_CSP_CSR_CHARACTERIZATION_ONLY`, keine erfolgreiche CA-Ausstellung.

Verbraucherende und beide Controllerenden sind belegt, Worker-Exitcode 0.
Der eigene Run wurde öffentlich gestoppt und frisch als `Off` / `STOPPED`
beobachtet. Originaladapter, `VerifyOnly/Denied`, erhaltener `CLEANED`-Journal,
33 geschützte Bestandsdateien und bestehender CurrentUser-Roottrust waren
unverändert. VM, Disks und eigener Gastschlüssel bleiben zweckgebunden erhalten.

## Frischer CSR aus dem vorhandenen Schlüssel

Eine weitere feste Ausführung auf Produktquelle
`1d59368e30aa458dac0f913fb3b711e33a0688fc` setzte dieselbe eigene VM mit
`VerifyOnly/Denied` fort. Der vorherige begrenzte Mutex-Wait endete ohne Start;
erst nach frisch verfügbarer Sperre und erneuten vollständigen Bindungen
startete genau ein Supervisor mit genau einem Gast-CSR-Block. Keine neue
Schlüsselanlage, Aktivierungsanfrage, externe NIC, CA-/Trust-/SQL-Aktion.

Die native Vorprüfung und der CSR-Block bestanden: tatsächliches CSP-Profil,
öffentlicher Modulus und UniqueContainerName blieben gleich. `UseExistingKeySet`
und fester Container verwendeten den bereits vorhandenen nicht exportierbaren
Machine-RSA3072-/SChannel12-/KeySpec1-Schlüssel. Der neue Request setzte
`SMIME=FALSE`; eigene Requestdateien und Requestmetadaten bleiben erhalten.
Host-Proof-of-Possession, öffentlicher Original-SPKI und exakter IP-SAN bestanden.

Die anschließende enge Hostprüfung endete mit `FAIL_EFFECT_ENTERED` und
`CSP_WORKER_FAILURE`, Worker-Exitcode 1. Die rein lokale Diagnose der erhaltenen
öffentlichen CSR-Bytes präzisierte `TLS_LEAF_CSR_INVALID` am Subject-DER-Vergleich:
Der tatsächliche einzelne ASCII-Maschinen-CN war UTF8String (Tag 12), während
`UseUTF8Encoding` für die Erwartung weiterhin PrintableString konstruierte.
`ForceUTF8Encoding` konstruiert aus dem unabhängig gebundenen erwarteten Namen
exakt dieselben Subjectbytes. Der originale Lauf bleibt fehlgeschlagen; kein
Replay, kein Umschreiben des signierten CSR und keine zweite Schlüsselanlage.

Beide Controller sind beendet, Verbraucherende und eigener öffentlicher Stop
sind belegt. Frisch bestätigt: native VM `Off`, Run `STOPPED`, Originaladapter,
`VerifyOnly/Denied`, erhaltener `CLEANED`-Journalhash, 37 geschützte Dateien und
CurrentUser-Roottrust unverändert. VM, Disks, Schlüssel und Requestmetadaten
bleiben erhalten; kein Removal-Cleanup-Pass. Die spätere Readerkorrektur und
Prüfung desselben öffentlichen CSR sind ein getrennter Produkt-/Hostnachweis,
keine nachträgliche Änderung dieses nativen Ergebnisses.

Die anschließende rein lokale Prüfung desselben unveränderten öffentlichen
CSR mit der korrigierten Readerquelle bestand: vollständiges enges CSR-Profil,
echtes Proof-of-Possession und identischer ursprünglicher SPKI. Ergebnis
`PASS_RETAINED_NATIVE_CSR_ACCEPTED_OFFLINE`. Es gab dabei keinen Gastaufruf,
keine Keyanlage, CA-Signierung, Storeannahme oder SQL-/TLS-Probe. Dieser spätere
Hostnachweis qualifiziert die Readerkorrektur für genau diese erhaltenen Bytes;
er ersetzt den Worker-Exitcode 1 des ursprünglichen nativen Laufs nicht.

## Erhaltene Vorfehler und offene Grenze

Ein vorheriger CSP-Controller stoppte vor VM-Start, Gasttransport und Keyanlage:
Ein Guard verglich den identischen Parent-SHA-256-Hextext irrtümlich abhängig
von Groß-/Kleinschreibung. Nach bestätigtem Ende und tatsächlich identischem
Digest wurde eine neue Quellenform unabhängig geprüft. Nur feste Rootbindung
und Hexvergleich änderten sich; ReadOnly-/Reparsegrenzen blieben bestehen.
Alte Quellen, Intents und Fehlerergebnisse wurden weder geändert noch replayed.
Der Fehlversuch hatte null Gast-CSP-Fälle, der Nachfolger genau einen.

Der additive [CSR-Vertrag](../Architecture/AUTHENTICATED_TLS_LEAF_CSR.md)
unterstützt inzwischen einen ausdrücklich erwarteten Maschinen-CN bei
unverändertem SAN-/Attributlimit. Diese Produktänderung wurde nicht rückwirkend
im ursprünglichen nativen Lauf ausgeführt. Der spätere CSR aus demselben Schlüssel
und die getrennte DER-Korrektur sind oben abgegrenzt. Kein Replay der
Keyanlage oder Umschreiben der signierten CSR-Bytes. Hyper-V-TLS-Gesamtabnahme
und SC-2026-045 bleiben gesperrt.

Microsoft-Primärquellen, geprüft am 2026-10-18:
[certreq und SMIME](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1),
[SQL-Zertifikatsanforderungen](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/certificate-requirements?view=sql-server-ver17).
Herstelleranforderungen und die oben ausgeführte lokale Evidence bleiben getrennt.
