# Native Windows-TLS-Ablauf- und Erneuerungsprobe

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-16 (UTC) |
| Ergebnis | Windows-Clientgegenfälle und Erneuerung an einem eigenen Docker-SQL-2025-Run bestanden; vollständige TLS-001-Abnahme offen |
| SQL | SQL Server 2025 CU9; tatsächlich `ProductVersion=17.0.5005.3` |
| Produktquelle | `4d3b1110611eb2a4f238749a24066f72182965e6`, integriert mit [PR771](https://github.com/gecompat/SQL_Server_Lab/pull/771) |
| Produkt-Pflichtgate | [Run 38971671976](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38971671976): erforderliche Windows-, Ubuntu- und PR-Gates am exakten Head erfolgreich |

Die Probe ergänzt die [erste Windows-Probe](TLS_WINDOWS_SQL2025_PARTIAL_ACCEPTANCE_2026-10-16.md)
und verwendet die bereits ausdrücklich freigegebene öffentliche Lab-CA im
ausgewählten Windows-Benutzerkontext. Sie verändert keinen weiteren Truststore.

## Tatsächlich ausgeführt

| Fall | System.Data.SqlClient | Tatsächliches Windows-sqlcmd |
|---|---|---|
| Unvertraute ursprüngliche Serverkette | Vor SQL-Abfragen abgelehnt, `SEC_E_UNTRUSTED_ROOT` | Nichtnull-Exit und passende SSL-Provider-Kettenablehnung |
| Tatsächlich abgelaufenes korrektes IP-Leaf | Vor SQL-Abfragen abgelehnt, `SEC_E_CERT_EXPIRED` | Nichtnull-Exit und passende SSL-Provider-Ablaufablehnung |
| Erneuertes korrektes IP-Leaf mit neuem Key | SQL-Abfrage bestanden, `encrypt_option=TRUE` | Exit 0, SQL-Abfrage bestanden, `encrypt_option=TRUE` |
| Drittes neues Leaf mit falschem IP-SAN am gleichen IPv4-Endpunkt | Vor SQL-Abfragen abgelehnt, `SEC_E_WRONG_PRINCIPAL` | Nichtnull-Exit und passende SSL-Provider-Identitätsablehnung |

Das kurzlebige Leaf galt ab tatsächlichem UTC-Beginn 120 Sekunden. Der Lauf
wartete ohne Uhränderung bis mehr als zwei Sekunden nach dem echten Ende.
Im Prüflauf gab es vorher keine Windows-Hostverbindung zu diesem Leaf: Der öffentliche
Start übersprang seine normale Hostreadiness; ausschließlich eine begrenzte
Abfrage im eigenen Container prüfte SQL-Bereitschaft. Deren Zertifikatsbypass
ist ausdrücklich nur interne Readiness und keine authentifizierte TLS-Evidence.

Die eigentlichen Windows-Probes nutzten durchgehend `Encrypt=True` und
`TrustServerCertificate=False` beziehungsweise `-N` ohne `-C`. Die .NET-
Verbindungen hatten `Pooling=False`. Negative .NET-Fälle öffneten nur die
Verbindung; die CLI-Gegenfälle enthielten ausschließlich einen SQL-Kommentar.
Ein unerwarteter Verbindungserfolg wurde nicht als bestandener Gegenfall
gewertet. DNS-, TCP- und Authentisierungsfehler ersetzten keinen TLS-Befund.

Die frisch ausgewählte erste sqlcmd-Anwendung war dateigebunden; geerbte
SQLCMD-Startvariablen wurden nur im neuen Prozess entfernt. Das Passwort
stand nicht in den Argumenten. Während der erfolgreichen SQL-Abfrage war
`msodbcsql17.dll`, Dateiversion `2017.1711.0001.01`, tatsächlich geladen.
Für schnell endende Gegenfälle wird kein geladener Treiber behauptet.

## Zertifikatsbindung, Überwachung und Cleanup

Alle drei RSA-3072-Keys und OpenSSL-CSRs entstanden ausschließlich im eigenen
Container; alle drei öffentlichen Schlüssel waren verschieden. Der private
Issuer signierte nach den bestehenden DER-/Proof-/SAN-/CA-Prüfungen. Private
Serverkeys wurden nicht exportiert. Jede öffentliche Leafdatei wurde bytegenau
rückgelesen; Zertifikats-, Key- und ForceEncryption-Konfiguration passten exakt.
Das jeweilige SQL-Log bestätigte das Laden der eigenen Datei-/Keypfade.
Zertifikatthumbprints waren dort nicht enthalten; ein Wirefingerprint wurde
nicht beobachtet und wird nicht behauptet.

Der unabhängig geprüfte feste Harness lief unter einem zeitlich begrenzten
Supervisor mit tatsächlicher PID-/Startzeitbindung. Ein Workerabbruch hätte
eine Recovery erst nach bestätigtem Prozessende und erneuter Bindung genau
des zurückgegebenen eigenen Runs erlaubt. Der erfolgreiche Lauf endete mit
Exit 0, `Completed=true`, `REMOVED` und ohne eigene Container oder Volumes.
Vorher erfasste Run-, Root-, Katalog- und Exportdateien blieben bytegleich;
dies wurde nach Workerende erneut lesend bestätigt.

Zwei vorherige begrenzte Versuche endeten vor der Ablaufprobe an lokal
reproduzierbaren PowerShell-Arraypräzedenzfehlern im privaten Harness. Beide
wurden vollständig bereinigt; ihre Intents und lokalen Fehlerbelege bleiben
erhalten. Die Korrekturen wurden vor dem Nachfolger offline und unabhängig
geprüft. Kein alter Intent wurde wiederholt. Der erfolgreiche Abschnitt hatte
ein endliches Budget von einem neuen Run und höchstens drei Keys/Leafs mit
drei eigenen Neustarts; genau ein Implementierer und unabhängiger Review.
Tatsächliche Kosten und Tokenverbrauch sind unbekannt.

## Verbleibende Abnahmegrenze

Dies qualifiziert die beschriebenen Windows-Clientfälle für diesen eigenen
Docker-SQL-2025-CU9-Scope. Operative Registry, AuthorityRef, gebundene frische
Qualifikationsrecords, V2-Export und koordinierter Consumer-Cutover fehlen
weiterhin. Trustdrift, Abbruch/Resume des TLS-Lifecycles, Linuxclients,
Hyper-V bleibt separat. Die spätere [Container-Versionsmatrix](TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md)
bestand dieselben acht Windows-Clientfälle separat für SQL 2019 CU32 und
SQL 2022 CU27 mit Docker und Podman, jeweils mit eigenem Cleanup. Die spätere
[Podman-Probe](TLS_PODMAN_WINDOWS_SQL2025_ACCEPTANCE_2026-10-16.md) bestand
separat dieselben acht Windows-Clientfälle für SQL 2025 CU9.
Toolbelt SC-2026-045 bleibt bis zum policykonformen Export und tatsächlichen
Toolbelt-Labpreflight gesperrt.

Reale Run-/Scope-/Containerwerte, Endpunkte, Zertifikatsdigests, Benutzer- und
Hostdaten, geschützte Harnessquellen sowie Rohdiagnosen bleiben lokal und
ignoriert. Die sechs geschützten Toolbelt-Umgebungen, die erhaltene
SSISDB-Quelle und fremde Ressourcen bleiben erhalten.
