# Native Windows-TLS-Matrix für Container-SQL-Versionen

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-16 (UTC) |
| Ergebnis | Vier zusätzliche eigene Provider-/Versionsläufe mit je acht Windows-Clientfällen bestanden; vollständige TLS-001-Abnahme offen |
| Produktquelle | `49b08051eb8748a27f7ceb135514f6bc35f9fc9a`, integriert mit [PR773](https://github.com/gecompat/SQL_Server_Lab/pull/773) |
| Quellen-Pflichtgate | [Run 38977665496](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38977665496): erforderliche Windows-, Ubuntu- und PR-Gates erfolgreich am exakten PR-Head |

Die bereits getrennt belegten SQL-2025-CU9-Läufe für
[Docker](TLS_WINDOWS_SQL2025_EXPIRY_RENEWAL_2026-10-16.md) und
[Podman](TLS_PODMAN_WINDOWS_SQL2025_ACCEPTANCE_2026-10-16.md) werden hier
nicht erneut ausgeführt. Vier neue eigene Runs ergänzen SQL 2019 und 2022.
Eine Provider-Evidence wurde nicht auf den anderen Provider übertragen.

| SQL-Version | Docker, tatsächlich abgefragter Build | Podman, tatsächlich abgefragter Build | Clients je Run |
|---|---|---|---|
| SQL Server 2019 CU32 | `15.0.4430.1` | `15.0.4430.1` | Windows System.Data.SqlClient und Windows-sqlcmd |
| SQL Server 2022 CU27 | `16.0.4295.3` | `16.0.4295.3` | Windows System.Data.SqlClient und Windows-sqlcmd |
| SQL Server 2025 CU9, vorherige Einzelbelege | `17.0.5005.3` | `17.0.5005.3` | Windows System.Data.SqlClient und Windows-sqlcmd |

## Tatsächlich ausgeführte Fälle je neuem Run

| Fall | System.Data.SqlClient | Tatsächlich ausgewähltes Windows-sqlcmd |
|---|---|---|
| Unvertraute ursprüngliche Serverkette | Vor SQL-Abfragen abgelehnt, `SEC_E_UNTRUSTED_ROOT` | Nichtnull-Exit und passende SSL-Provider-Kettenablehnung |
| Echt abgelaufenes korrektes IP-Leaf | Vor SQL-Abfragen abgelehnt, `SEC_E_CERT_EXPIRED` | Nichtnull-Exit und passende SSL-Provider-Ablaufablehnung |
| Erneuertes korrektes IP-Leaf mit neuem Key | SQL-Abfrage mit obigem tatsächlichem Build und `encrypt_option=TRUE` | Exit 0, SQL-Abfrage mit obigem tatsächlichem Build und `encrypt_option=TRUE` |
| Drittes Leaf mit falschem IP-SAN am unveränderten IPv4-Endpunkt | Vor SQL-Abfragen abgelehnt, `SEC_E_WRONG_PRINCIPAL` | Nichtnull-Exit und passende SSL-Provider-Identitätsablehnung |

Die Prüfungen verwendeten `Encrypt=True`, `TrustServerCertificate=False`
und `Pooling=False` beziehungsweise `-N` ohne `-C`. Negative .NET-Fälle
öffneten nur die Verbindung; die CLI erhielt ausschließlich einen SQL-Kommentar.
DNS-, TCP-, Authentisierungsfehler und unerwarteter Verbindungserfolg zählten
nicht als TLS-Ablehnung. Erste Anwendung und Dateibytes waren frisch gebunden;
geerbte SQLCMD-Startvariablen wurden nur im neuen Prozess entfernt. Während
der positiven SQL-Abfrage wurde `msodbcsql17.dll`, Dateiversion
`2017.1711.0001.01`, tatsächlich beobachtet. Schnelle Gegenfälle behaupten
keine gesonderte Treiberbeobachtung. Passwörter standen nicht in CLI-Argumenten.

Jedes kurze Leaf galt 120 Sekunden ab tatsächlichem UTC-Beginn. Der erste
Windows-Hostkontakt zu diesem Leaf erfolgte erst mehr als zwei Sekunden
nach seinem tatsächlichen Ende. Keine Uhränderung. Vorher prüfte nur eine
begrenzte Abfrage im eigenen Container SQL-Bereitschaft; ihr Zertifikatsbypass
zählt ausschließlich als interne Readiness, nicht als authentifizierte TLS-Evidence.

## Bindungen, Vorbereitung und Cleanup

Jeder Lauf hatte eigene Audit-, Run-, Scope-, Workflow-, Instanz-, Container-
und exakte Imagebindung. Diese wurden vor eigenen nativen Aktionen frisch
geprüft. Die Podman-Route war zusätzlich an die bereits laufende eigene
Runtime und tatsächliche öffentliche Loopback-Auflösung gebunden. Eine
abweichende registrierte Resolverdistribution sperrte vor dem Intent;
keine ungenutzte WSL-Distribution oder Host-Runtime wurde gestartet.

Die SQL-2022-Images waren bereits als geprüfte Inhalte im Cache vorhanden.
Für die beiden fehlenden SQL-2019-CU32-Caches wurden die offiziellen festen
MCR-Manifest-Digests lesend geprüft, dann zwei zeitlich begrenzte Pulls per
unveränderlichem Digest ausgeführt. Drei vorher fehlende Katalogreferenzen
wurden ergänzt. Bestehende Referenzen wurden nicht wissentlich ersetzt oder
entfernt. Die sofortige Nachkontrolle des gemeinsamen Caches ist kooperativ;
globale atomare Tagreservierung wird nicht behauptet. Vorbereitungsintent,
PID-/Startzeitrecords und Inhaltsprüfungen bleiben lokal erhalten.

Je Run entstanden drei verschiedene RSA-3072-Keys und CSRs ausschließlich im
eigenen Container. Private Serverkeys wurden nicht exportiert. Alle drei
öffentlichen Leafs wurden bytegenau rückgelesen; SQL-Zertifikats-, Key- und
ForceEncryption-Konfiguration passten. Die SQL-Logs bestätigten das Laden
der eigenen Datei-/Keypfade. Kein Zertifikatthumbprint oder Wirefingerprint
wird behauptet. Die bereits freigegebene CA blieb im ausgewählten
Windows-Benutzertrust; kein weiterer Truststore wurde verändert.

Alle vier Worker und Supervisoren endeten erfolgreich mit bestätigtem
Workerende, Exit 0 und `Completed=true`. Öffentlicher Cleanup lieferte je
`REMOVED`; eigene Container und Volumes waren nicht mehr vorhanden. Vorher
erfasste Run-, Root-, Katalog- und Exportdateien blieben bytegleich; nach jedem
Workerende erneut lesend bestätigt. Alte Intents wurden nicht wiederholt.

Der erste Docker-SQL-2022-Lauf hatte einen eigenen begrenzten Abschnitt.
Das anschließende gemeinsame Budget umfasste drei weitere getrennte Runs,
höchstens neun Zielkeys/Leafs mit neun eigenen Neustarts und eine gemeinsame
konsistente Dokumentationsintegration. Pro Run blieb der Runtime-Mutex
exklusiv; genau ein Implementierer je atomarem Scope. Stabile Adapterpaare
und abschließender Diff wurden unabhängig geprüft. Die native Provider-/
Versionsevidence blieb getrennt; das gemeinsame Dokumentationsgate vermeidet
vier gleiche Integrationsketten ohne Auslassen der notwendigen Nachweise.
Tatsächliche Kosten und Tokenverbrauch sind unbekannt.

## Verbleibende Abnahmegrenze

Dies belegt die beschriebenen Windows-Clientfälle auf den ausgewählten
Container-SQL-Builds. Linuxclients und Hyper-V bleiben separat. Trustdrift,
TLS-Abbruch/Resume, operative Registry und AuthorityRef, frische gebundene
Qualifikationsrecords, V2-Export, koordinierter Consumer-Cutover und der
tatsächliche Toolbelt-Labpreflight fehlen weiterhin. Toolbelt SC-2026-045
bleibt gesperrt. Die bestehende Metadatenreader-Grenze für CU-Aliase wird
hierdurch nicht behoben oder als qualifizierter Export ausgegeben.

Reale Runtimewerte, Endpunkte, Zertifikatsdigests, Benutzer-/Hostdaten,
geschützte Harnessquellen und Rohdiagnosen bleiben lokal und ignoriert.
Die sechs geschützten Toolbelt-Umgebungen, die erhaltene SSISDB-Quelle,
fremde Ressourcen und frühere Löschsperren bleiben erhalten.
