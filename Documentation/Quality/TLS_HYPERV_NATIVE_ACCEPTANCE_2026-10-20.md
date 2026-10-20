# Native Hyper-V-TLS-Referenzabnahme

| Merkmal | Tatsächlicher Nachweis |
|---|---|
| Stand | 2026-10-20 UTC |
| Ergebnis | Private Windows-/Hyper-V-Referenz bestanden; neun Fälle, 18 Clientergebnisse |
| SQL | SQL Server 2025 RTM, tatsächlicher Build `17.0.1000.7`, vier Systemdatenbanken online |
| Clients | Windows `System.Data.SqlClient` und tatsächliches ODBC-sqlcmd |
| Native Abschlussquelle | Stabile 1.558 Quellpfade, SourceDigest `b912993297097d4aa27762787d2f6b53845f967690c599d4c898462554b4895d` |
| Review | Unabhängiger Agent prüfte Implementierung, konkrete Fortsetzungen und Konfigurations-/Gatebindung; Findings behoben |
| Grenze | [Privater Referenzvertrag](../Architecture/AUTHENTICATED_TLS_HYPERV_NATIVE_ACCEPTANCE.md); keine öffentliche Hyper-V-False-/Exportqualifikation |

## Ausgeführte Fälle

| Fall | SqlClient | ODBC-sqlcmd | Effektiver Clientmodus |
|---|---|---|---|
| Gültige Kette und korrekter IP-SAN | PASS | PASS | Encrypt=True, TrustServerCertificate=False |
| Untrusted-True-Kontrolle | PASS | PASS | Encrypt=True, TrustServerCertificate=True |
| Unvertraute CA | UNTRUSTED | UNTRUSTED | Encrypt=True, TrustServerCertificate=False |
| Falscher IP-SAN | WRONG_SAN | WRONG_SAN | Encrypt=True, TrustServerCertificate=False |
| Neues kurzlebiges Leaf vor Ablauf | PASS | PASS | Encrypt=True, TrustServerCertificate=False |
| Dasselbe Leaf nach echtem Ablauf | EXPIRED | EXPIRED | Encrypt=True, TrustServerCertificate=False |
| Erneuertes Leaf mit neuem Gastkey | PASS | PASS | Encrypt=True, TrustServerCertificate=False |
| Erneuertes Leaf nach Windows-Neustart | PASS | PASS | Encrypt=True, TrustServerCertificate=False |
| Wiederhergestellte Defaultbindung | PASS | PASS | Encrypt=True, TrustServerCertificate=True |

Jede erfolgreiche Probe fragte den tatsächlichen Build und
`encrypt_option=TRUE` ab. Striktes sqlcmd verwendete `-N` ohne `-C`;
Hostname-/Resolveroverride wurde nicht verwendet. Positive sqlcmd-Proben
beobachteten und hashten den tatsächlich geladenen ODBC-Treiber. Die neuen
.NET-Proben laufen in eigenen NoProfile-Prozessen und prüfen tatsächliche
Assembly-MVID und Diskhash. Passworttransport erfolgt ausschließlich über
begrenztes stdin. Die echte Ablaufzeit wurde ohne Uhränderung abgewartet;
Positiv- und Ablaufbeleg binden denselben Leafdigest.

## Zusammengesetzte Ausführung und erhaltene Fehlschläge

Genau ein SQL-CompleteImage wurde tatsächlich gestartet und endete mit Exit 0.
Frisches Setup-Summary, Installer-Ruhe, dauerhafter Neustartintent und ein
streng jüngerer Gastboot wurden nachgewiesen. Der erste Versuch hielt danach
an einer SQL-Nachbedingung an; dieser Fehler bleibt erhalten. Eine unabhängig
geprüfte Fortsetzung bewies denselben ruhigen Boot, SQL-Bereitschaft und den
erhaltenen Originalkey und schloss die SQL-Metadaten ab. Setup und erster
Neustart wurden nicht wiederholt.

Ein vorgelagerter Quellinventarfehler lag noch vor Native-Effekten. Danach
scheiterte ExistingKey-certreq an Keyerstellungsattributen im INF; der erhaltene
Fehlbeleg wurde durch einen ausdrücklich gebundenen korrigierten Request
ergänzt. Originalkeyanlage und private Keyausfuhr fanden nicht statt.
Die nachfolgende erfolgreiche CSR-/Leafinstallation hielt an einem
Connection-String-Builderfehler vor der Clientverbindung an. Auch dieser
Fehlversuch wurde erhalten und vor der Fortsetzung unabhängig geprüft.

Der nächste Lauf speicherte die ersten vier Fälle direkt, hielt aber bei der
Ablaufprüfung im langlebigen .NET-Prozess an einer unerwarteten Kategorie an.
Die Ursache ist nicht bewiesen; Sitzungswiederaufnahme bleibt eine Vermutung.
Frische Prozesse lehnten das unverändert gebundene abgelaufene Leaf korrekt
ab. Die korrigierte Fortsetzung übernahm die vier gespeicherten Fälle und
prüfte die fünf verbleibenden Fälle neu. Dafür wurde genau ein zusätzliches
kurzlebiges Leaf am vorhandenen CSR/Originalkey ausgestellt. Frühere
Short-Positivwerte wurden nicht als gespeicherte Ergebnisdaten übernommen.

Der letzte Worker und sein Supervisor endeten mit Exit 0 beziehungsweise PASS,
COMPLETED und bekanntem Verbraucherende. Beide geordneten Neustarts betreffen
getrennte Zwecke: einmal Setupabschluss, einmal Erneuerungspersistenz. Das
ursprüngliche 180-Minuten-Gesamtbudget wurde nicht zurückgesetzt. Dies ist
kein frischer durchgehender Lauf des abschließenden Entrypoints und keine
allgemeine Recovery-Apply-Freigabe. Das Journal-Lesemodell bleibt konservativ.

## Cleanup und Integrität

Sechs verschiedene eigene Leafs und die neu erfassten eigenen Requestrecords
wurden anhand ihrer Digests entfernt. Der eigene neue Renewalkey wurde
entfernt; ursprünglicher nicht exportierbarer Machine-CSP-/RSA3072-/SChannel12-/
KeySpec1-Key, seine ACL und die ursprüngliche SQL-Bindung wurden erhalten
beziehungsweise restauriert. Der Default-Kontrollfall funktionierte danach.
Eigene Firewallregel und DVD wurden entfernt. Die vorher bereits vorhandene
VM, Child-/Parentdisks und der ursprüngliche CSP-Key bleiben zweckgebunden
gestoppt erhalten. Journale und öffentliche Requestdateien bleiben privat.

Gehaltene Lesebindungen und erneute vollständige Hashprüfung bestätigten die
geschützten Root-/CA-/Registry-/Medien-/Parentdateien. Der vorhandene
Host-Roottrust blieb unverändert. Das konkrete SQL-Log bestätigte den geladenen
Leaf; ein unabhängiges Wire-Zertifikat bleibt `NOT_OBSERVED`. Rohe Host-,
Runtime-, Zertifikats- und Diagnosedaten liegen ausschließlich lokal geschützt.

## Prüfbreite und verbleibende Scopes

Die native Zulassung bestand aus sechs frisch ausgeführten statischen Suites
mit unveränderten Quellen. Guard 72/0, Boundaryfixture 37/0, Writerfixture 10/0,
Pester 23/0 und Privacy 3/0 waren grün; CI-Strategie, Dokumentation und Analyzer
bestanden. Ein während Änderungen gestarteter Lauf wurde wegen veränderter
Quellen verworfen. Vor jeder konkreten Native-Fortsetzung lagen neue stabile
Gates und unabhängiger Review vor. Das abschließende Integrationsgate und die
Required Checks werden im zugehörigen Pull Request ausgewiesen.

Docker- und Podman-Lifecycle bestanden getrennt mit jeweils 2/0, Mixed-Lifecycle
bestand, Adapter mit 10/0 und synthetischer Hyper-V-Lifecycle mit Exit 0 und
jeweils eigenem Cleanup. Diese Regressionen ersetzen keine TLS-Matrix.
PowerShell 7.2 wurde lokal nicht ausgeführt; Native-Ausführung benötigt 7.5.
Token- und Geldkosten sind unbekannt; derselbe Implementierer und unabhängige
Reviewer bearbeiteten nur konkrete neue Findings und Laufzeitgrenzen.

SQL 2019/2022 und weitere Hyper-V-/Clientkontexte, öffentliche
Hyper-V-False-Erstellung, qualifizierter Hyper-V-Export sowie Toolbelt
SC-2026-045 bleiben eigenständige offene Scopes. Der allgemeine TLS-001-Status
bleibt deshalb `partial`; diese native SQL-2025-RTM-Referenz ist abgeschlossen.
