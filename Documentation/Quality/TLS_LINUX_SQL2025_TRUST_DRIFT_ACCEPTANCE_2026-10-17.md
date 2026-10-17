# Strikte Linux-TLS-Verbindungen und begrenzter Trustdriftnachweis

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-17 |
| Ergebnis | Sechs native Clientfälle bestanden; eigener Runtime-Cleanup frisch bestätigt |
| Produktquelle | `9f603e165c91d6588b576db18df554f950f22707` |
| Plattform | Docker, Linux amd64, SQL Server 2025 CU9; eigener isolierter Client |
| Aussagegrenze | DNS-SAN `localhost`, beide ausgewählten Clientstacks; keine vollständige TLS-Lab-/Exportqualifikation |

## Ausgangspunkt und korrigierte Auswertung

Der frühere [localhost-Versuch](TLS_LINUX_LOCALHOST_PRETRUST_ATTEMPT_2026-10-17.md)
scheiterte vor TLS am PowerShell-Startkontext. Die vorbereitete Korrektur setzt
auch für die zusätzliche .NET-Auflösung prozesslokal `HOME=/tmp` und schaltet
Telemetrie ab. Zwei anschließende Zulassungsversuche erreichten wegen der
belegten gemeinsamen Runtime-Sperre keine Ressourcenanlage. Ihre bestätigten
Workerenden, exakten Quellen und fehlenden Ausführungsintents wurden vor dem
Nachfolger geprüft; die noch ungenutzte Ein-Client-Ressourcenfreigabe wurde
nicht durch einen wiederholten Ressourcenlauf ersetzt.

Nach freier Runtime-Sperre bestanden erstmals beide strikten positiven
Linux-Verbindungen. Der anschließende CLR-Trustentzug scheiterte vor jeder
SQL-Abfrage an einer Zertifikatsablehnung, wurde aber vom bisherigen Textfilter
nicht als erwarteter Gegenfall erkannt. Die reale Exceptionkette enthielt
`SqlException`, `AuthenticationException` und die Ablehnung durch den
`RemoteCertificateValidationCallback`, ohne den erwarteten spezifischen
Kettenfehlertext. Dieser Lauf bleibt als Harness-FAIL erhalten; sein eigener
Client, SQL-Ziel und temporärer Secreteingang wurden vollständig entfernt.

Der korrigierte Filter verlangt weiterhin eine vorherige erfolgreiche
CLR-Kontrollverbindung zum unveränderten eigenen Ziel, fehlende Trust-Overrides,
fehlgeschlagene Verbindungsöffnung und null SQL-Abfragen. Die generische
Callbackmeldung genügt nur zusammen mit der typisierten
`AuthenticationException`/`SqlException`-Kette. Login- und Netzwerkfehler,
fehlende Positivkontrolle, SQL-Arbeit, verbleibender Trust-Override und fehlende
Authentifizierungsexception wurden in sechs Gegenfällen abgewiesen; die echte
erhaltene Fehlerbeobachtung bestand als Regression. Dies interpretiert einen
kontrollierten Trustentzug, keinen beliebigen Zertifikatsfehler als Kettenursache.

## Tatsächliche Abnahme

Der Benutzer gab genau einen frischen eigenen SQL-2025-CU9-Run, einen neuen
isolierten Client und ein Leaf für die korrigierte Abnahme frei. Die Grenzen
betrugen 20 Minuten einschließlich Cleanup und 160 Docker-Kommandos.
Der Worker reservierte fünf Minuten für Cleanup. Er schloss nach 65 eigenen
Kommandos mit Exitcode 0 ab; Workerende wurde vom Supervisor bestätigt.

Schlüssel und CSR entstanden ausschließlich im eigenen SQL-Ziel. Der bestehende
Issuer signierte genau ein Leaf mit `DNS localhost`; SQL-Bindung und geladene
Zertifikats-/Keypfade wurden gelesen. Der eigene Client verwendete UID 10001,
schreibgeschütztes Root-Dateisystem, eigene begrenzte tmpfs, `cap-drop ALL`,
`no-new-privileges` und den eigenen SQL-Netzwerk-Namespace. Alle drei nativen
Namensprüfungen erlaubten vor der Trustdatei ausschließlich Loopback.
Keine Hostmounts, Resolveränderungen, Systemstoreänderungen oder Zusatzrechte.

Die gleiche öffentliche CA lag nur im eigenen Client-tmpfs. `SSL_CERT_FILE`
und `SSL_CERT_DIR` galten ausschließlich für die ausgewählten Kindprozesse.
SqlClient verwendete `Encrypt=True;TrustServerCertificate=False`; sqlcmd
verwendete `-N` ohne `-C`. Ziel blieb `tcp:localhost,1433`.

| Fall | System.Data.SqlClient | ODBC-sqlcmd |
|---|---|---|
| CA für den ausgewählten Kindprozess gesetzt | Verbindungsöffnung und Abfrage PASS | Verbindungsöffnung und Abfrage PASS |
| CA-Overrides entfernt | Zertifikatsablehnung, null SQL-Abfragen PASS | Zertifikatsablehnung ohne fachliche SQL-Arbeit PASS |
| Dieselben CA-Overrides wiederhergestellt | Neue Verbindungsöffnung und Abfrage PASS | Neue Verbindungsöffnung und Abfrage PASS |

Die positiven Abfragen bestätigten SQL-Build `17.0.5005.3` und
`encrypt_option=TRUE`. Verwendet wurden PowerShell 7.6.6 und .NET 10.0.12.
Der tatsächlich geladene ODBC-18-Treiber wurde in beiden positiven
sqlcmd-Kindprozessen über deren native Prozessabbildungen beobachtet.
Es gab keinen Trustbypass und keine globale Trustentfernung/-wiederherstellung.

## Cleanup und verbleibender Scope

Eigener Client vor eigenem SQL-Run entfernt; die temporäre private
Host-Eingabedatei ist abwesend. Nach bestätigtem Workerende wurden beide
zurückgegebenen Container-IDs sowie run-/scopegebundene Volumes und Netzwerke
erneut nativ abgefragt: alle abwesend. Geschützte vorbestehende Dateien blieben
bytegleich; der vorhandene Windows-CA-Trust blieb erhalten. Keine unbekannten
Teilressourcen oder unbestätigten CLI-Prozesse, kein Runtime-Recoverybedarf.
Lokale Quellen, Intents und Rohreceipts bleiben geschützt und unversioniert.

Diese Abnahme qualifiziert ausschließlich die beschriebenen sechs Fälle.
Andere Linux-Provider-/SQL-Versionen, echte Ablauf-/Renewal-/Wrong-SAN-Fälle
unter Linux, Hyper-V-Zertifikatsbindung, TLS-Abbruch/Resume, operative Registry,
öffentliche Moduswahl und qualifizierter Export bleiben separat offen.
Die vorhandenen Windows-Clientnachweise bleiben erhalten.
Toolbelt SC-2026-045 ist dadurch noch nicht freigegeben.
