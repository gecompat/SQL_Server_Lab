# Native Abnahme der expliziten TLS-Live-API vom 2026-10-23 (UTC)

## Ergebnis und Geltungsbereich

`Test-SqlServerLabTlsQualification` bestand an sechs neuen eigenen operativen
Windows-/Docker-/Podman-Labs. Der [API-Vertrag](../Architecture/AUTHENTICATED_TLS_LIVE_QUALIFICATION.md)
beschreibt Voraussetzungen, Aufruf, geschlossene Ausgabe und Aussagegrenze.
Beide echten strikten Stacks sind `System.Data.SqlClient` und das registrierte
ODBC-`sqlcmd` mit `-N` ohne `-C`. Positive Verbindungen bestätigen den erwarteten
SQL-Build und `encrypt_option=TRUE` der eigenen Sitzung.

| Provider | SQL-Profil | Tatsächlich geprüfter Build | Fälle | Direkte strikte API-Clientresultate | Ergebnis |
|---|---|---|---|---|---|
| Docker | 2019 CU32 | `15.0.4430.1` | 7 | 4 | PASS |
| Podman | 2019 CU32 | `15.0.4430.1` | 7 | 4 | PASS |
| Docker | 2022 CU27 | `16.0.4295.3` | 7 | 4 | PASS |
| Podman | 2022 CU27 | `16.0.4295.3` | 7 | 4 | PASS |
| Docker | 2025 CU9 | `17.0.5005.3` | 7 | 4 | PASS |
| Podman | 2025 CU9 | `17.0.5005.3` | 7 | 4 | PASS |

Insgesamt sind das 42 Fälle und 24 direkte API-Clientresultate. Je Zelle
kommen zwei strikte Clientresultate der nötigen eigenen Erstellung und zwei
der expliziten Wiederbindung hinzu: zusammen zwölf Arrange- und zwölf
Rebind-Resultate. Diese zusätzlichen Resultate werden nicht als direkte
API-Aufrufe gezählt. Keine frühere bestandene Native-Matrix wurde wiederholt.

## Tatsächlich ausgeführter Ablauf

Der bestehende eigene Acceptance-Harness lief ausschließlich mit
`-ExerciseLiveQualification`. Sein unabhängiges Oracle erwartet das exakte
Provider-/SQL-Profil und eine geschlossene aktuelle API-Beobachtung.

| Fall je Zelle | Tatsächlich geprüfte Aussage |
|---|---|
| Eigene Erstellung | Operatives False-Lab mit beiden strikten Stacks als notwendiges Arrange |
| Explizite Live-API | Zwei neue strikte Verbindungen; gebundenes Ergebnis ohne Credentials, Endpoint, Hostpfad oder private Digests |
| Falscher Run | Feste öffentliche Ablehnung ohne Fallback auf das vorhandene eigene Ziel |
| Falsche Instanz | Feste öffentliche Ablehnung ohne Ersatzinstanz |
| Echter Containerneustart | Alte gespeicherte Startbindung wird abgewiesen; kein positives Cacheergebnis |
| Explizite Wiederbindung und neue Live-API | Öffentliche Wiederbindung, anschließend beide API-Stacks erneut; neuer Qualifikationszeitpunkt |
| Entferntes Ziel | Nach tatsächlichem eigenen Remove wird die API abgewiesen |

Alle sechs Zellen verwendeten denselben unveränderten geprüften Produktstand.
Nach Abschluss änderte sich nur die Nachweisdokumentation. Jede Zelle bestätigte
`REMOVED`, Container- und Volumeabwesenheit am ursprünglichen Runtime-Pin,
Abwesenheit der festen Exporte, Erhalt des vorbestehenden Inventars und der
ursprünglichen Authority-/Key-/Trustbindung sowie terminales Workerende mit
leerem gebundenem Windows-Job. Keine Zelle benötigte einen Hardstop.

Der erste Docker-Einstieg endete vor Reservierung und Nativeaktion wegen
beendeter Docker-Desktop-Runtime. Er ist kein fehlgeschlagener SQL-Fall und
wurde nicht blind wiederholt. Nach ausdrücklicher Startfreigabe wurde Docker
Desktop regulär gestartet, `READY` frisch bestätigt und ausschließlich die
drei noch fehlenden Docker-Zellen ausgeführt. Die drei Podman-Zellen liefen
vorher separat; ihre erfolgreichen Ergebnisse wurden nicht wiederholt.

## Statische Prüfung und verbleibende Grenzen

Die fokussierte Suite bestand mit 45/0. Der erste betroffene statische Lauf
enthielt zwei fehlgeschlagene Suites: eine falsche Fehlercodeerwartung im
Acceptance-Oracle-Test und die veraltete API-Anzahl im Index. Nach gezielter
Korrektur bestanden alle neun vom Delta ausgewählten Suites einschließlich
des vollständigen Analyzers. Ursprüngliche Fehlerbelege bleiben erhalten;
unveränderte erfolgreiche Prüfungen wurden nicht als frische Läufe ausgegeben.

Das öffentliche Ergebnis gilt ausschließlich am Beobachtungszeitpunkt. Es
wird nicht gespeichert, reserviert keine Runtime und ist kein wiederverwendbares
Authoritytoken. Drift invalidiert es auch vor seiner maximalen Frist.
`WireCertificateFingerprint=NOT_OBSERVED` bleibt wahr; es wurde kein zusätzlicher
Wire-Fingerprint mitgeschnitten.

Eine dedizierte Liveaktion am SQL-Ziel mit gerenderter Frische-/Driftanzeige,
False-Creationdialog und Clipboardpfade, öffentliche Linux- und Hyper-V-Lanes,
operatives Renewal/Recovery, weitere Trustkontexte und weitere Consumer bleiben
getrennte Scopes. Die [Linux-Kryptomatrix](TLS_LINUX_CLIENT_MATRIX_ACCEPTANCE_2026-10-22.md)
und der [Windows-V2-Consumer-Cutover](TLS_V2_CONSUMER_CUTOVER_ACCEPTANCE_2026-10-22.md)
sind eigene Nachweise. Dieser Teilabschluss schließt nicht die gesamte TLS-001-Matrix.
Rohdaten, Secrets, konkrete Zielbindungen und vollständige Logs bleiben lokal
außerhalb Git. Erforderliche PR-/CI-Gates und eigener Branch-/Worktreecleanup
sind gesonderte Integrationsbedingungen.
