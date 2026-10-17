# Isolierter Linux-Trustversuch vor den TLS-Probes

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-17 (UTC) |
| Ergebnis | `FAIL` vor dem ersten Linux-TLS-Probeprozess; eigener Cleanup erfolgreich |
| Produktquelle | `bb8e310fdb24020bf6c353a9499323b5c3599a74`, integriert mit [PR776](https://github.com/gecompat/SQL_Server_Lab/pull/776) |
| Quellen-Pflichtgate | [Run 38988869202](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38988869202): vier erforderliche Checks am exakten PR-Head erfolgreich |

Dieser tatsächliche Versuch folgt auf die
[Linux-Clientvorbereitung](TLS_LINUX_CLIENT_CAPABILITY_2026-10-16.md).
Die konkrete menschliche Freigabe galt für genau einen neuen eigenen
Docker-Linuxclient, eine öffentliche Lab-CA-Datei in dessen flüchtigem
Dateisystem, ausschließlich ausgewählte Prozess-Trustvorgaben und eigenen
Cleanup. Die Windows-CurrentUser-Freigabe wurde dafür nicht wiederverwendet.

## Ausführung und Fehlergrenze

Ein neues eigenes SQL-2025-CU9-Ziel wurde durch den öffentlichen Lifecycle
angelegt. Sein privater RSA-Schlüssel entstand ausschließlich im Zielcontainer.
Der gebundene Windows-Signierkontext stellte ein öffentliches Serverleaf aus;
Rücklesen von Zertifikatsdatei und SQL-TLS-Konfiguration sowie der tatsächliche
SQL-Logbefund bestätigten die geladenen eigenen Zertifikats-/Keypfade.
Das ist kein Wire-Fingerprint- oder Linux-Clientnachweis.

Der neue Client verwendete das feste bereits vorhandene SQL-2025-CU9-Stockimage
mit Sleep-Entrypoint, UID 10001, schreibgeschütztem Root-Dateisystem, zwei eigenen
tmpfs-Pfaden, `cap-drop ALL`, `no-new-privileges` und begrenzten Ressourcen.
Er teilte den frisch gebundenen Netzwerk-Namespace des eigenen SQL-Ziels;
die Namespaceidentität wurde tatsächlich verglichen. Keine Hostmounts,
Systemstoreänderung, DNS-Änderung oder zusätzliche Runtime wurde angelegt.

Die öffentliche CA-Datei und die Clientbausteine wurden in die eigene
flüchtige Ablage übertragen. Bei der anschließenden Vorbereitung der privaten
Passwortdatei scheiterte `chown`: Root besitzt unter `cap-drop ALL` nicht die
dafür erforderliche Capability. Der begrenzte Docker-Befehl endete ungleich
null. Der Trust-Intent blieb ohne Trust-Commit; der Worker brach vor dem
ersten ausgewählten CLR-/sqlcmd-Probeprozess ab. Es gab keinen Retry,
Capability-Zusatz, Systemstore-Fallback oder Zertifikatsprüfungs-Bypass.

| Nachweis | Tatsächlicher Stand |
|---|---|
| Linux-PowerShell-/SqlClient-/sqlcmd-Vorbereitung | Frühere getrennte [Clientprobe](TLS_LINUX_CLIENT_CAPABILITY_2026-10-16.md); kein neuer TLS-Nachweis |
| Strikte positive und negative Linux-SQL-Fälle | `NOT_EXECUTED` |
| Wirksame Prozess-Trustvorgaben beider Stacks | `NOT_QUALIFIED` |
| Tatsächlich geladener Linux-ODBC-Treiber | `NOT_OBSERVED` |
| Eigener Client und flüchtige Trust-/Secretdateien | Entfernt; tatsächliche Abwesenheit frisch geprüft |
| Eigenes SQL-Ziel und eigene Volumes | Über den öffentlichen Lifecycle entfernt; tatsächliche Abwesenheit frisch geprüft |
| Temporäre private Host-Passwortdatei | Entfernt; Abwesenheit frisch geprüft |
| Geschützte vorbestehende Dateien | Nach bestätigtem Workerende frisch bytegleich geprüft |
| Bestehender Windows-CA-Trust | Frisch identisch vorbestehend beobachtet; nicht entfernt |

Der Supervisor bestätigte Workerende und Exitcode 1. Fehler und erfolgreicher
Cleanup bleiben getrennte Befunde; Cleanup macht den fehlgeschlagenen Versuch
nicht zu einer TLS-Abnahme. Quellen, Ausführungsintents und begrenzte Rohbelege
bleiben unverändert ausschließlich lokal und außerhalb der Versionskontrolle.

## Prüfung und nächster begrenzter Schritt

Die stabilen Workerquellen wurden unabhängig geprüft. Ein P2-Befund zur
verlorenen Teilevidence bei einem Probe-Orakelfehler wurde vor dem ersten
Versuch korrigiert und unabhängig geschlossen. Die tatsächlichen
Catch-/Finally-Statements wurden mit injiziertem Fehler geprüft: vorherige
und fehlgeschlagene Fälle, vorhandene ODBC-Beobachtung und begrenzter Fehlercode
bleiben erhalten; private Eingaben werden nicht ausgegeben. Dieser Probe-Code
wurde im tatsächlichen Linuxversuch noch nicht erreicht.

Fokussiert bestanden 33 synthetische Isolations-/Ownership-/Budgetguards,
zwei Prüfungen des gebundenen STDIN-Transfers mit einem eigenen lokalen
PowerShell-Kindprozess und ein Fehlerausgabe-Regressionsfall. Beide
`PLAN_ONLY`-Einstiege führten keine Provider- oder Trustaktionen aus.
Unveränderte frühere Windows-/Linuxnachweise wurden nicht wiederholt.

Ein möglicher Nachfolger lässt UID 10001 die eigene private Eingabedatei
direkt in einem frischen privaten Verzeichnis im eigenen `/tmp`-tmpfs
erzeugen. Er prüft Besitzer, Modi und Payloaddigest als diese UID und
benötigt weder `chown` noch zusätzliche Capabilities. Dies ist ein Plan,
kein ausgeführter Berechtigungsnachweis. Die konkrete neue lokale Vorschau
benennt einen neuen Client und einen neuen Aktionsdigest. Die vorherige
Freigabe für einen Client ist verbraucht; eine neue ausdrückliche Freigabe,
ein neuer endlicher Abschnitt sowie separat geprüfte, gebundene Quellen
und frische Intents sind vor einer weiteren Ausführung erforderlich.

Linux-TLS, dessen Versions-/Providermatrix, Hyper-V, vollständige Trustdrift-/
Abbruch-/Resumeabnahme, operative Registry/AuthorityRef, frische Qualifikation,
qualifizierter Export und tatsächlicher Toolbelt-Preflight bleiben offen.
SC-2026-045 bleibt gesperrt. Kosten und Tokenverbrauch sind unbekannt.
