# Linux-Teilnachweis mit direkter UID-Dateianlage

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-17 (UTC) |
| Ergebnis | Native UID-Dateianlage und strikte CLR-Verbindung bestanden; Gesamtversuch wegen ODBC-Namensablehnung `FAIL` |
| Produktquelle | `0350445dcbb427eae6acb5a265b97ba43163fb17`, integriert mit [PR777](https://github.com/gecompat/SQL_Server_Lab/pull/777) |
| Quellen-Pflichtgate | [Run 39017888625](https://github.com/gecompat/SQL_Server_Lab/actions/runs/39017888625): vier erforderliche Checks am exakten PR-Head erfolgreich |

Dieser eigene Docker-Versuch folgt auf den
[vor den TLS-Probes gescheiterten Erstversuch](TLS_LINUX_TRUST_ATTEMPT_2026-10-17.md).
Eine neue konkrete menschliche Freigabe deckte genau den neuen Client,
höchstens ein neues eigenes SQL-2025-CU9-Ziel, dieselbe öffentliche CA-Datei
im eigenen tmpfs, die ausgewählten Prozess-Trustvorgaben und eigenen Cleanup.
Die frühere verbrauchte Freigabe wurde nicht wiederverwendet.

## Tatsächliche Beobachtungen

| Bereich | Befund und Aussagegrenze |
|---|---|
| Laufzeit | PowerShell 7.6.6, .NET 10.0.12 und Ubuntu 24.04.4 LTS im eigenen Client |
| Private Eingabe | UID 10001 erzeugte das frische eigene Verzeichnis mit 0700 und die reguläre Datei mit 0600 direkt über begrenztes STDIN. Besitzer, Modi, numerische Dateitypen und Payloaddigest wurden als UID 10001 tatsächlich geprüft. Kein `chown` oder zusätzliche Capability im Client. |
| CA-Datei | Öffentliche CA im eigenen tmpfs übertragen und remote dateigenau rückgeprüft; eigener Trust-Commit aufgezeichnet. Keine CA-Keys oder Systemstoreänderungen. |
| System.Data.SqlClient | Assemblymetadaten 4.6.1.6 und erwartete Dateibindung beobachtet. Verbindung mit `Encrypt=True`, `TrustServerCertificate=False`, `Pooling=False` und den beiden ausgewählten Prozess-Trustvorgaben erfolgreich; eine Abfrage lieferte `17.0.5005.3` und `encrypt_option=TRUE`. |
| ODBC/sqlcmd | Erstes erwartetes sqlcmd-Application-Ziel dateigebunden und ausgeführt. Der als positiv geplante Aufruf endete mit Exit 1 und der präzisen SSL-Namensablehnung `subject name does not match host name`; keine erfolgreiche SQL-Abfrage. |
| Geladener Linux-ODBC-Treiber | `NOT_OBSERVED`: keine tatsächlich geladene Treiberdatei aus dem Kindprozess beobachtet. Der Produktname in einer Fehlermeldung ersetzt keinen solchen Nachweis. |
| Trustentzug und Wiederherstellung | `NOT_EXECUTED`: nach dem ersten fehlgeschlagenen positiven ODBC-Orakel abgebrochen. |

Das eigene SQL-Ziel verwendete einen ausschließlich dort erzeugten privaten
RSA-Schlüssel und ein öffentliches Leaf mit genau dem angeforderten IP-SAN.
Zertifikatsdatei und SQL-TLS-Konfiguration wurden rückgelesen; der native
SQL-Logbefund bestätigte die geladenen eigenen Zertifikats-/Keypfade.
Ein Wire-Fingerprint wird nicht behauptet. Beide Clientaufrufe verwendeten
denselben numerischen Loopback-Endpunkt im frisch verglichenen eigenen
SQL-Netzwerk-Namespace. Der Client behielt schreibgeschütztes Root-Dateisystem,
zwei eigene tmpfs-Pfade, `cap-drop ALL`, `no-new-privileges`, UID 10001 und
begrenzte Ressourcen. Keine Hostmounts oder Resolveränderungen.

Die Namensablehnung ist ein tatsächlicher Befund dieser konkreten Kombination.
Sie beweist weder eine allgemeine ODBC-Unfähigkeit für IP-SANs noch die genaue
interne Ursache. Sie gilt auch nicht als bestandener absichtlicher Wrong-SAN-
Gegenfall, weil dieser Aufruf als gültiger positiver Fall vorgesehen war.
Die CLR-Verbindung allein qualifiziert weder beide Stacks noch den wirksamen
Trustentzug oder die vollständige Linux-TLS-Matrix.

## Fehler und Cleanup bleiben getrennt

Die vorab korrigierte begrenzte Teilevidence erhielt den erfolgreichen CLR-Fall,
den fehlgeschlagenen ODBC-Fall und den geschlossenen Fehlerstatus. Der Supervisor
bestätigte Workerende und Exitcode 1; kein automatischer Retry oder Bypass.
Der eigene Client wurde vor dem eigenen SQL-Ziel entfernt. Frisch nach dem
Workerende bestätigt:

- eigener Client, SQL-Container und eigene Volumes tatsächlich abwesend;
- temporäre private Host-Eingabedatei entfernt;
- geschützte vorbestehende Dateien bytegleich;
- bestehender Windows-CA-Trust identisch vorbestehend erhalten;
- ausgeführte Quellen und Intents unverändert ausschließlich lokal aufbewahrt.

Zwölf neue synthetische Guardfälle prüften UID-, Modus-, Dateityp-, Digest-
und Transfergrenzen. Fünfzehn übernommene Helfer waren bytegleich; ihre grünen
Prozess-/Cleanupprüfungen wurden nicht wiederholt. Beide `PLAN_ONLY`-Einstiege
blieben ohne native Aktionen. Unabhängiger Quellenreview lief vor der einmaligen
Ausführung ohne offene P1/P2-Befunde. Der erfolgreiche Cleanup macht den
Gesamtversuch nicht zu einem bestandenen TLS-Nachweis.

## Nächste konkrete Vorschau

Die [ODBC-Dokumentation](https://learn.microsoft.com/en-us/sql/connect/odbc/dsn-connection-string-attribute?view=sql-server-ver17#hostnameincertificate)
beschreibt den erwarteten Zertifikatsnamen, der standardmäßig aus dem Serverziel
abgeleitet wird. Daraus wird als nächster Versuch eine ausdrücklich gewählte
DNS-Identität `localhost` mit genau einem passenden DNS-SAN und demselben
Verbindungszielnamen in beiden Clientaufrufen geplant. Dies ist eine Hypothese für
den nächsten Nachweis, keine belegte Behebung der beobachteten ODBC-Ablehnung.
Die bestehende reine Identitätsformprüfung akzeptiert `DNS localhost`;
native Auflösung, Zertifikats-/Clientkompatibilität und beide Stacks sind damit
nicht geprüft.

Ein neuer eigener Client muss vor der Trustdateianlage tatsächlich ausschließlich
Loopback-Adressen für `localhost` beobachten; andernfalls bleibt der Versuch
gesperrt. Keine Hosts-/DNS-/Resolveränderung, kein CN-Fallback, freier Nameoverride
oder Zertifikatpin anstelle der normalen Ketten-/Namensprüfung. Die
[dokumentierte ServerCertificate-Option](https://learn.microsoft.com/en-us/sql/connect/odbc/dsn-connection-string-attribute?view=sql-server-ver17#servercertificate)
ersetzt die normale Prüfung und wird für diesen geplanten Versuch nicht benutzt.

Die neue konkrete lokale Vorschau benötigt eine neue ausdrückliche Freigabe,
einen neuen endlichen Abschnitt sowie separat geprüfte gebundene Quellen und
Intents. Die aktuelle Freigabe für genau einen Client ist verbraucht.
Linux-TLS beider Stacks, geladener ODBC, Trustdrift-/Abbruch-/Resumeabnahme,
Hyper-V, operative Registry/AuthorityRef, frische Qualifikation, qualifizierter
Export und tatsächlicher Toolbelt-Preflight bleiben offen. SC-2026-045 bleibt
gesperrt. Kosten und Tokenverbrauch sind unbekannt.
