# Erste native Windows-SQL-TLS-Probe

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-16 |
| Ergebnis | Begrenzter nativer Docker-/Windows-Nachweis bestanden; keine vollständige TLS-001-Abnahme |
| SQL | SQL Server 2025 CU9, tatsächliche `ProductVersion=17.0.5005.3` |
| Quelle | Commit `77b4c62b9f3626156d946c6b05e81208002c8b22`, integriert mit [PR770](https://github.com/gecompat/SQL_Server_Lab/pull/770) |
| Pflichtgate | [Run 38967289100](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38967289100): Windows, Ubuntu und PR Gate erfolgreich am exakten Head |

Die [konkrete native CA-Trust-Recovery](TLS_CA_TRUST_ACCEPTANCE_2026-10-16.md)
ist ein eigener vorheriger Nachweis. Der folgende Lauf verwendete ausschließlich
einen neuen eigenen Run, vorhandene öffentliche Lifecyclefunktionen und die
bereits ausdrücklich freigegebene CA. Bestehende geschützte Ziele erhielten
keine Zertifikats-, DNS-, Trust- oder Neustartänderung.

## Tatsächlich ausgeführt

| Fall | Ergebnis |
|---|---|
| Unvertraute ursprüngliche Serverkette, System.Data.SqlClient | Vor SQL-Abfragen abgelehnt: `SEC_E_UNTRUSTED_ROOT` |
| Korrektes Leaf, System.Data.SqlClient | SQL-Verbindung und Abfrage bestanden; `encrypt_option=TRUE` |
| Korrektes Leaf, tatsächliche erste sqlcmd-Anwendung | Exit 0; SQL-Verbindung und Abfrage bestanden; `encrypt_option=TRUE` |
| Neues falsches IP-SAN, System.Data.SqlClient, gleicher IPv4-Endpunkt | Vor SQL-Abfragen abgelehnt: `SEC_E_WRONG_PRINCIPAL` |
| Eigener Cleanup | `REMOVED`, keine eigenen Container oder Volumes verblieben |
| Vorher erfasste Run-, Root-, Katalog- und Exportdateien | Bytegleich erhalten |

Der .NET-Client nutzte `Encrypt=True`, `TrustServerCertificate=False` und
`Pooling=False`. Sqlcmd nutzte `-N` ohne `-C`; das Passwort stand nicht in den
Argumenten. Geerbte SQLCMD-Startvariablen wurden nur im neuen Prozess entfernt.
Die frisch aufgelöste erste Anwendung und ihre Datei waren exakt gebunden.
Während der echten SQL-Abfrage wurde `msodbcsql17.dll` beobachtet,
Dateiversion `2017.1711.0001.01`. Dies ist kein ODBC-18-Nachweis.

Beide Zertifikatsfälle erhielten getrennte neue RSA-3072-Keys und OpenSSL-CSRs
im eigenen Container. Private Serverkeys wurden nicht exportiert. Die bestehende
geschlossene CSR-/DPAPI-Signierlane prüfte Signatur, SAN und CA-Bindung; das
öffentliche Leaf wurde kopiert und bytegenau rückgelesen. Die drei SQL-TLS-
Konfigurationswerte und beide eigenen Neustartergebnisse waren passend.

Das lokal gesicherte native SQL-Log bestätigt jeweils die erwarteten eigenen
Zertifikats- und Keydateipfade als geladen. Es enthält in diesem Lauf keinen
Zertifikatthumbprint; TLS-Ciphernamen sind kein Zertifikatdigest. Ein
Wirefingerprint wurde nicht beobachtet und wird nicht behauptet.

Eine frühere Probe über einen anderen DNS-Namen scheiterte bereits an TCP.
Sie wurde nicht als Identitätsablehnung gewertet. Der erfolgreiche Gegenfall
tauschte stattdessen das Leaf am unveränderten IPv4-Endpunkt aus.

## Offene Abnahme und private Evidence

In diesem ersten Lauf waren CLI-Gegenfälle und Ablauf/Renewal noch offen.
Die [spätere eigene Ablauf-/Erneuerungsprobe](TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md)
bestand für beide Windows-Stacks mit unvertrauter Kette, echtem Ablauf,
falscher Identität und Erneuerung mit neuem Key. Trustdrift, Abbruch/Resume,
weitere SQL-Versionen, Podman und Hyper-V bleiben offen; Linuxclients separat.
Operative Registry, AuthorityRef, qualifizierter V2-Export und Bereitschaft
werden durch diesen Lauf nicht hergestellt. Toolbelt SC-2026-045 bleibt gesperrt.

Reale Run-/Scope-/Containerwerte, Endpunkte, CA-/Leafdigests, Benutzer-/Hostdaten,
geschützte Harnessquellen und Rohdiagnosen bleiben ausschließlich lokal und
ignoriert. Die Ausführung verwendete genau einen Implementierer, unabhängigen
Review am exakten Harness und ein endliches Budget von einem neuen Run und
höchstens zwei Keys/Leafs mit zwei eigenen TLS-Neustarts. Tatsächliche Kosten
und Tokenverbrauch sind unbekannt. Die sechs geschützten Toolbelt-Umgebungen,
die erhaltene SSISDB-Quelle und fremde Ressourcen bleiben erhalten.
