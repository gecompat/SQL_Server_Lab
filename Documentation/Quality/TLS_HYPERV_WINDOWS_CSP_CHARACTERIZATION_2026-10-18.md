# Hyper-V: Windows-Aktivierung und CSP-/CSR-Charakterisierung

| Merkmal | Ausgeführter Scope |
|---|---|
| Datum | 2026-10-18, UTC |
| Native Produktquelle | `b10967a3bb43b8087c6d8ba36d6f5f30d73c03b9` |
| Gast | Eigene Windows Server 2025 Standard Evaluation, SQL-Prepared-Klon |
| SQL-Medium | SQL Server 2025 RTM, 17.0.1000.7; kein CU9 |
| Abschluss | Aktivierung und CSP-Charakterisierung bestanden, eigene VM gestoppt und erhalten |
| Nicht abgenommen | SQL CompleteImage, Zertifikatannahme, SQL-ServiceACL, SQL-TLS, qualifizierter Export |

Dies sind zwei getrennte tatsächlich ausgeführte Abschnitte mit geschützten
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
im nativen Lauf ausgeführt. Ein neuer fester CSR aus dem vorhandenen Schlüssel
mit `SMIME=FALSE` bleibt eine gesondert zu prüfende Fortsetzung. Kein Replay der
Keyanlage oder Umschreiben der signierten CSR-Bytes. Hyper-V-TLS-Gesamtabnahme
und SC-2026-045 bleiben gesperrt.

Microsoft-Primärquellen, geprüft am 2026-10-18:
[certreq und SMIME](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1),
[SQL-Zertifikatsanforderungen](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/certificate-requirements?view=sql-server-ver17).
Herstelleranforderungen und die oben ausgeführte lokale Evidence bleiben getrennt.
