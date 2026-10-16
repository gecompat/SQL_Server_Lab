# Native Podman-TLS-Probe mit Windowsclients

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-16 (UTC) |
| Ergebnis | Acht Clientfälle an einem eigenen Podman-Run bestanden; vollständige TLS-001-Abnahme offen |
| SQL-Ziel | Linux/Podman, SQL Server 2025 CU9; tatsächlich `ProductVersion=17.0.5005.3` |
| Clients | Windows System.Data.SqlClient und tatsächlich ausgewähltes Windows-sqlcmd |
| Quelle | `7b0c771bad60a3691647b7c275a94b453b114b5d`, integriert mit [PR772](https://github.com/gecompat/SQL_Server_Lab/pull/772) |
| Quellen-Pflichtgate | [Run 38975746943](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38975746943): erforderliche Windows-, Ubuntu- und PR-Gates erfolgreich am exakten PR-Head |

Dieser eigene Run ist getrennte Podman-Evidence. Der vorherige
[Docker-Nachweis](TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md) wurde nicht
auf Podman übertragen. Das passende Linux/amd64-Image war bereits lokal
vorhanden; der Lauf benötigte weder Download noch Start einer Host-Runtime.
Die schon freigegebene CA blieb im ausgewählten Windows-Benutzertrust;
kein zusätzlicher Truststore wurde verändert.

## Tatsächliche Clientfälle

| Fall | System.Data.SqlClient | Windows-sqlcmd |
|---|---|---|
| Unvertraute ursprüngliche Serverkette | Vor SQL-Abfragen abgelehnt, `SEC_E_UNTRUSTED_ROOT` | Nichtnull-Exit mit passender SSL-Provider-Kettenablehnung |
| Echt abgelaufenes korrektes IP-Leaf | Vor SQL-Abfragen abgelehnt, `SEC_E_CERT_EXPIRED` | Nichtnull-Exit mit passender SSL-Provider-Ablaufablehnung |
| Erneuertes korrektes IP-Leaf und neuer Key | SQL-Abfrage bestanden, `encrypt_option=TRUE` | Exit 0, SQL-Abfrage bestanden, `encrypt_option=TRUE` |
| Drittes Leaf mit falschem IP-SAN am unveränderten IPv4-Endpunkt | Vor SQL-Abfragen abgelehnt, `SEC_E_WRONG_PRINCIPAL` | Nichtnull-Exit mit passender SSL-Provider-Identitätsablehnung |

Das kurze Leaf hatte 120 Sekunden tatsächliche UTC-Laufzeit. Der Prüflauf
wartete bis mehr als zwei Sekunden nach seinem Ende; keine Uhränderung.
Sein erster Windows-Hostkontakt zu diesem Leaf erfolgte erst danach. Vorher
prüfte ausschließlich eine begrenzte interne Containerabfrage SQL-Bereitschaft;
ihr Zertifikatsbypass zählt nicht als authentifizierte TLS-Evidence.

Die Windows-Probes nutzten `Encrypt=True`, `TrustServerCertificate=False`
und `Pooling=False` beziehungsweise `-N` ohne `-C`. Negative Fälle führten
keine SQL-Abfrage aus; die CLI erhielt nur einen SQL-Kommentar. Unerwarteter
Verbindungserfolg, TCP-, DNS- oder Authentisierungsfehler galten nicht als
TLS-Ablehnung. Das Passwort stand nicht in CLI-Argumenten. Erste Anwendung
und Dateibytes waren frisch gebunden; während der positiven Abfrage wurde
`msodbcsql17.dll`, Dateiversion `2017.1711.0001.01`, tatsächlich beobachtet.
Schnelle Gegenfälle behaupten keinen gesonderten geladenen Treiber.

## Bindung und Rücknahme

Run-, Scope-, Workflow-, Instanz-, Container- und Imagebindung wurden vor
eigenen nativen Aktionen frisch geprüft. Die tatsächlich beobachtete öffentliche
Loopback-Resolverroute war vorab gebunden; abweichende Hostbedingungen sperrten
vor dem Ausführungsintent. Die schon laufende Podman-WSL-Runtime blieb erhalten;
ein Guard sperrt vorab die Verwendung einer abweichenden registrierten
Resolverdistribution. Keine ungenutzte Linux-Distribution wurde gestartet.

Drei verschiedene RSA-3072-Keys und CSRs entstanden ausschließlich im eigenen
Container. Private Serverkeys wurden nicht exportiert. Öffentliche Leafs,
SQL-TLS-Konfiguration und native Ladebelege der eigenen Datei-/Keypfade passten
in allen drei Fällen. Ein Zertifikatthumbprint im Log oder Wirefingerprint
wird nicht behauptet.

Der unabhängig geprüfte feste Harness und Supervisor endeten mit Exit 0 und
`Completed=true`. PID-/Startzeitbindung, begrenzte Laufzeit und Recovery erst
nach bestätigtem Workerende blieben erhalten. Öffentlicher Cleanup lieferte
`REMOVED`; eigene Container und Volumes waren nicht mehr vorhanden. Alle vorher
erfassten Run-, Root-, Katalog- und Exportdateien blieben bytegleich; nach
Workerende erneut lesend bestätigt. Das endliche gemeinsame Budget erlaubte
einen neuen Run und höchstens drei Keys/Leafs mit drei eigenen Neustarts.
Genau ein Implementierer, unabhängiger Review; Kosten und Tokenverbrauch unbekannt.

## Verbleibende Grenze

Der Nachweis gilt für diese Windowsclients, Podman und SQL Server 2025 CU9.
Linuxclients, Hyper-V, weitere SQL-Versionen, Trustdrift und TLS-Abbruch/Resume
bleiben eigene Nachweise. Operative Registry, frische Qualifikationsrecords,
V2-Export, koordinierter Consumer-Cutover und tatsächlicher Toolbelt-Labpreflight
fehlen weiterhin. Toolbelt SC-2026-045 bleibt gesperrt.

Reale Runtimewerte, Endpunkte, Zertifikatsdigests, Benutzer-/Hostdaten,
geschützte Harnessquellen und Rohdiagnosen bleiben lokal und ignoriert.
Die sechs geschützten Toolbelt-Umgebungen, die erhaltene SSISDB-Quelle und
fremde Ressourcen bleiben erhalten.
