# Gerenderte TLS-Verbindungsanzeige unter Windows vom 2026-10-21

## Belegter Umfang

Die vollständige lokale Produktseite zeigt die gespeicherten Connection
Settings und den Connection String an je einem eigenen, zuvor strikt
qualifizierten Windows-/Docker-/SQL-2025-CU9- und Windows-/Podman-/SQL-2025-CU9-Lab
konsistent an. Beide getrennten Abnahmen bestanden auf Build `17.0.5005.3`,
Recordform `0.2` ohne `SqlProfileId`, am unveränderten Produktstand
`d1821d7062d5e6d8fcb3923d98dae757f048aa92`.

| Eigener Lauf | Native Fälle | Bezeichnete strikte Clientergebnisse | Frischer abgeschlossener Workflow-Snapshot | Browser | Cleanup und Bestandsvergleich |
|---|---:|---:|---:|---|---|
| Docker, korrigierter zweiter Lauf | 5 PASS | 6 PASS | 1 | PASS | PASS |
| Podman, erster Lauf | 5 PASS | 6 PASS | 1 | PASS | PASS |

Der unveränderte öffentliche
[`Invoke-AuthenticatedTlsLabAcceptance.ps1`](../../Tests/Integration/Invoke-AuthenticatedTlsLabAcceptance.ps1)
erzeugte mit `-Version 2025-CU9 -KeepLab` je ein neues eigenes False-Lab.
Die drei positiven Zweistackgruppen sind Erstellung, qualifizierter Export
und Verwendung seiner Zugangsdaten mit System.Data.SqlClient und nativem
ODBC/sqlcmd. Die fünf Fälle enthalten außerdem die tatsächliche CLI-/Workflow-
Projektion und die abgelehnten, anschließend exakt zurückgesetzten veralteten
Bindungs-/Exportmanipulationen. Die sechs Ergebnisse sind bezeichnete
Clientresultate, keine instrumentierte Gesamtzahl aller Netzwerkverbindungen
oder TLS-Handshakes. Der Harnessstatus mit absichtlich behaltenem Lab war
nur ein Zwischenstand; die anschließende Entfernung ist separat bestätigt.

## Tatsächlicher Browserpfad

Der echte `Start-SqlServerLabUi.ps1` lief mit unveränderten Produktassets und
seinem wirklichen `/api/workflow`. Ein eigener flüchtiger Browserkontext
verwendete die startgebundene Operator-Capability. Die Automation ließ nur
fest begrenzte lesende Requests an die genaue eigene Loopback-Origin zu;
es gab keine ersetzten HTTP-Antworten, unerwarteten Requests oder JavaScript-
Seitenfehler. Node, Playwright-Paketmetadaten und Browserprogramm waren über
lokale Datei-/Größen-/Hashbindungen geprüft.

Der Prozess verwendete ausschließlich den eigenen StateRoot, den tatsächlich
registrierten DataRoot sowie eigene leere Media-/TestDataRoots. Die effektiven
Getter wurden im Eltern- und UI-Prozess bestätigt. Dadurch wurden keine
fremden Runzustände oder Medien als Testziele übernommen.

Je Provider wurde ein tatsächlicher Snapshot mit `Refreshing=false` an den
genauen Run, Namen, `primary`, Provider und Endpoint gebunden. Der native
Connection-String-Parser prüfte unabhängig `Encrypt=True`,
`TrustServerCertificate=False` und denselben Endpoint. Die sichtbare Labkarte
enthielt exakt den gespeicherten Connection String. Unter **Verbindungen und
CMS** stimmten Ziel und TLS-Werte; die Übersicht zeigte keine Zugangsdaten.
Auch der bestehende Hinweis, dass die Anzeige kein Verbindungs- oder
Zertifikatsnachweis ist, war sichtbar. Die echte SQL-/Zertifikatsqualifikation
stammt aus den vorhergehenden beiden strikten Clientstacks.

Browserkontext und Browser wurden unabhängig geschlossen. Ein tatsächlicher
Closed-Beleg, der terminale Nodeprozess und der regulär beendete eigene
UI-Prozess gingen der Labbereinigung voraus. Danach bestätigten öffentliche
Entfernung, ursprüngliche Runtimebindung, Container-/Volumeabwesenheit,
Entfernung des festen Exports und Bestandsvergleich den Cleanup.

## Reproduzierter Fehler und erhaltene Fehlschläge

Ein vorbereitender Adapteraufruf scheiterte vor Reservierung und Provideraktion
am vererbten StrictMode. Die eng begrenzte Adapterkorrektur wurde unabhängig
geprüft; der ursprüngliche Fehlerbeleg bleibt lokal erhalten.

Im ersten Docker-Lab bestanden die fünf nativen Fälle und sechs bezeichneten
Clientresultate. Der Browserlauf blieb jedoch FAIL: Innerhalb seiner Frist
erschien kein abgeschlossener Inventursnapshot. Browser und UI-Prozess waren
terminal, eigener Cleanup und Bestandsvergleich PASS. Dieser ursprüngliche
FAIL am vorherigen Produktstand bleibt unverändert erhalten.

Die tatsächlichen Cachefunktionen reproduzierten den Produktfehler mit
synthetischen Jobblättern: Eine länger als fünf Sekunden laufende erfolgreiche
Inventur startete im selben Poll sofort die nächste Inventur, weil ihre
Frische bereits ab Jobstart gemessen wurde. Die fokussierte Reproduktion war
6 PASS / 3 FAIL. Nach Übernahme eines erfolgreichen, nichtleeren Ergebnisses
beginnt nun die fünfsekündige Frische erneut: 9 PASS / 0 FAIL. Die ergänzten
Gegenfälle für vorhandene alte Snapshots bei Failed, Stopped und leerer
Completion bestanden abschließend mit insgesamt 15 PASS / 0 FAIL.
Die Fixture führt nur die echten Cachefunktionen aus; Jobblätter und Zeit
sind synthetisch, ohne Listener, Inventur oder Provideraktion.

Der erste betroffene statische Lauf bestand mit 14 Suites; nach der gezielten
Oraclekorrektur bestanden die sieben betroffenen Suites. Produkt, Oracle und
der feste Nachfolgeadapter wurden unabhängig ohne offene Findings geprüft.
Der einzige neue Docker-Nachlauf verlangte den tatsächlichen terminalen
Vorgänger, dessen unveränderte Fehlerbelege und die ursprüngliche Runtime-
Inkarnation vor und nach frischen Abwesenheitsproben. Beide anschließenden
nativen Produktseitenabnahmen sind die oben getrennt ausgewiesenen PASSs.

Alle drei neuen eigenen Labs dieser Welle sind entfernt. Rohantworten,
Zugangsdaten und vollständige lokale Logs bleiben geschützt außerhalb Git;
Screenshots, DOM-Dumps und Browsertraces wurden nicht veröffentlicht.

## Noch offene TLS-001-Schritte

Die gesamte Matrix bleibt `partial`. Die abgeschlossenen Windows-Container-
Wiederbindungen für SQL 2019 CU32, SQL 2022 CU27 und SQL 2025 CU9 sowie die
private Hyper-V-/SQL-2025-RTM-Referenz werden dadurch nicht neu ausgeführt oder
zu anderen Kombinationen erweitert.

- Weitere konkrete SQL-/Patch-/Provider-/Clientkombinationen; unter Linux
  insbesondere Namens-/Ablauf-/Renewal-Gegenfälle und die operativen
  Registry-/False-/Exportpfade. Die getrennten positiven Linux- und
  Trustentzug-/Wiederherstellungsbelege bleiben erhalten.
- Öffentliche Hyper-V-False-Erstellung und qualifizierter V2-Export sowie
  weitere Hyper-V-SQL-/OS-Kombinationen. Die private Referenz ersetzt diese
  öffentlichen Pfade nicht.
- Durchgängige operative Erneuerung und Requalifikation mit Abbruch, Resume,
  Recovery und Rollback. Die explizite Container-Wiederbindung nach Neustart
  ist ein bereits separat geschlossener Teilscope.
- V2-Consumer-Cutover einschließlich Toolbelt `SC-2026-045` mit Frische- und
  Driftprüfung und echter authentifizierter Consumer-Verbindung.
- Weitere CA-/Trust-Zuordnungen für Benutzer-, Dienst- und Hostkontexte sowie
  der vollständige Wechsel-/Stilllegungslebenszyklus.
- Browser-False-Erstellung, gesonderte Qualifikationsstatusanzeige,
  Zwischenablage-/kopierter-Connection-String-Nachweis sowie weitere Modi,
  Fehlzustände und Exportformen. Diese Welle prüfte die gespeicherte Anzeige
  der beiden eigenen False-Labs.
- Der zusätzliche Wire-Fingerprint bleibt `NOT_OBSERVED`.

Der [P1-Backlog](../Project_Planning/NEW_SQL_LAB_USE_CASES_BACKLOG.md#tls-001--authentifizierte-tls-verbindungen-der-testumgebungen)
und die [bekannten Grenzen](KNOWN_LIMITATIONS.md) führen den verbleibenden Scope.
