# Linux-localhost-Versuch vor der Trustdateianlage

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-17 (UTC) |
| Ergebnis | `FAIL` vor Trustdateianlage und TLS-Probes; eigener Cleanup frisch bestätigt |
| Produktquelle | `88c0f8ca6cdb97222926aaeceeea083962f01338`, integriert mit [PR778](https://github.com/gecompat/SQL_Server_Lab/pull/778) |
| Quellen-Pflichtgate | [Run 39029450508](https://github.com/gecompat/SQL_Server_Lab/actions/runs/39029450508): vier erforderliche Checks am exakten PR-Head erfolgreich |

Nach dem [UID-Teilnachweis](TLS_LINUX_DIRECT_UID_PARTIAL_ACCEPTANCE_2026-10-17.md)
gab der Benutzer einen neuen eigenen Client und höchstens ein neues eigenes
SQL-2025-CU9-Ziel konkret frei. Geplant waren genau ein DNS-SAN `localhost`,
beide strikten Clientstacks am Ziel `tcp:localhost,1433`, dieselbe öffentliche
CA ausschließlich im eigenen tmpfs sowie Trustentzug und Wiederherstellung.
Vor jeder Trustdateianlage mussten native `getent`- und .NET-Auflösung
nichtleer und ausschließlich `127.0.0.1` oder `::1` liefern.

## Tatsächlicher Ablauf

Der Worker erzeugte genau ein eigenes SQL-Ziel und einen eigenen Client auf
dem fest gebundenen SQL-2025-CU9-Image. CSR und privater RSA-Schlüssel entstanden
ausschließlich im eigenen SQL-Ziel. Der vorhandene Issuer prüfte und signierte
genau `DNS localhost`; öffentliche Zertifikatsdatei und SQL-TLS-Konfiguration
wurden rückgelesen. Der native SQL-Logbefund bestätigte die geladenen eigenen
Zertifikats-/Keypfade. Das ist kein Wire-Fingerprint und kein Client-TLS-Nachweis.

Der Client behielt UID 10001, schreibgeschütztes Root-Dateisystem, eigene
begrenzte tmpfs-Pfade, `cap-drop ALL`, `no-new-privileges` und den frisch
gebundenen eigenen SQL-Netzwerk-Namespace. Keine Hostmounts, Hosts-/DNS-/
Resolveränderungen oder zusätzlichen Capabilities. Nur das gebundene öffentliche
PowerShell-Paket und der Probequelltext wurden zunächst im eigenen tmpfs
bereitgestellt; noch keine CA-Datei.

| Auflösungsschritt | Tatsächlicher Befund |
|---|---|
| `getent ahosts localhost` | ausschließlich `127.0.0.1` beobachtet und vom neuen Guard akzeptiert |
| `getent hosts localhost` | ausschließlich `::1` beobachtet und vom neuen Guard akzeptiert |
| .NET-DNS-Auflösung | `NOT_OBSERVED`: der zusätzliche PowerShell-Prozess scheiterte bereits beim Start mit einer Typeinitialisierungsausnahme wegen des schreibgeschützten `/home/mssql` |

Der neue Auflösungsaufruf übergab kein prozesslokales `HOME=/tmp`. Der bereits
vorhandene spätere TLS-Harnessaufruf setzt diesen Wert, wurde aber nicht erreicht.
Die Fehlermeldung bezeichnet eine PowerShell-Konfigurationsverzeichnisanlage,
keinen DNS- oder Zertifikatsfehler. Ein Abschlussrecord für die vollständige
Auflösung, Client-Trustintent/-commit, private Client-Eingabedatei und TLS-Probes
wurden nicht angelegt beziehungsweise nicht ausgeführt. Die beiden `getent`-
Beobachtungen ersetzen den fehlenden .NET-Auflösungsbefund nicht.

## Fehler, Prüfungen und Cleanup

Der Supervisor bestätigte Workerende und Exitcode 1. Der Worker führte 43
begrenzte Docker-Kommandos aus und stoppte ohne Retry oder Bypass. Eigener Client
vor eigenem SQL-Ziel bereinigt; frisch nach bestätigtem Workerende geprüft:

- eigener Client, SQL-Container und eigene Volumes tatsächlich abwesend;
- temporäre private Host-Eingabedatei entfernt;
- geschützte vorbestehende Dateien bytegleich;
- vorhandener Windows-CA-Trust identisch vorbestehend erhalten;
- ausgeführte Quellen, Approval und Intents unverändert lokal erhalten.

Vor der Ausführung bestanden 31 fokussierte synthetische Prüfungen für die neue
Auflösungsauswertung und deren Ablaufgrenzen; 14 übernommene Helfer waren
bytegleich. Ein dabei und im unabhängigen Review erkanntes Singleton-Arrayproblem
im .NET-JSON-Reader wurde vor Ausführung korrigiert und für IPv4/IPv6 geprüft.
Beide `PLAN_ONLY`-Einstiege blieben ohne native Aktionen. Der unabhängige
Quellenreview schloss ohne offene P1/P2-Befunde. Diese Offlineprüfungen
deckten den fehlenden nativen PowerShell-Startkontext nicht ab. Erfolgreicher
Cleanup macht den fehlgeschlagenen Versuch nicht zu einem TLS-Nachweis.

## Neue konkrete Vorschau

Eine neue rein planende Vorschau sieht einen weiteren eigenen Client mit
demselben engen DNS-/CA-/Prozess-Trustumfang vor. Nur der zusätzliche native
.NET-Auflösungsprozess soll `HOME=/tmp` und die bereits im TLS-Harness verwendete
Telemetrieabschaltung erhalten. `/tmp` bleibt das eigene begrenzte tmpfs;
keine Erweiterung des Dateisystems, keine Capability, kein Resolver- oder
Systemstoreeingriff. Weiterhin müssen alle drei Auflösungsschritte vor der
Trustdatei ausschließlich die freigegebenen Loopback-Adressen ergeben.

Diese Variante ist noch nicht nativ geprüft. Die verbrauchte Ein-Client-
Freigabe wird nicht wiederverwendet. Neue konkrete menschliche Freigabe,
endliches gemeinsames Budget, separat geprüfte neue Quellen und gebundene
Intents bleiben erforderlich. Keine neue Workeranlage oder Ausführung gehört
zu dieser Vorschau. Linux-TLS beider Stacks, geladener ODBC, Trustentzug und
Wiederherstellung, weitere Provider-/Versionsfälle, Hyper-V, TLS-Abbruch/Resume,
operative Registry/AuthorityRef, frische Qualifikation, qualifizierter Export
und tatsächlicher Toolbelt-Preflight bleiben offen. SC-2026-045 bleibt gesperrt.
Kosten und Tokenverbrauch sind unbekannt.
