# Review – Welle-1-Orchestrierung, Telemetrie und Runtime

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Stand | 2026-07-24 |
| Basis-Commit | `0ce614a39285619c1bc9830382770c9f4822baf4` |
| Arbeitspakete | `FWK-006`, `FWK-007`, `FWK-010` |
| Runtime-Validierung | offen; derzeit steht kein SQL-Server-Host zur Verfügung |

## 1. Umfang

Diese Stufe schließt die Framework-Implementierung mit folgenden Komponenten ab:

- datenbankinterne Signale und externer Multi-Session-Prozess-Orchestrator,
- Query-Store-Baseline, Enable, Status, Clear und Restore,
- begrenzter Extended-Events-Lifecycle mit `ring_buffer`,
- sequenzieller Runtime-Harness mit globalem Zeitbudget, Summary-Auswertung und garantiertem Cleanup.

## 2. Toolklassifikation

| Klasse | Bestandteile |
|---|---|
| Systemobjekte | SQL-Server-DMVs, Katalogsichten, Query Store und Extended Events |
| User-defined Tools | `fwk`-Tabellen/Prozeduren, SQL-Lifecycle-Skripte und Python-Module dieses Repositories |
| Externes Microsoft-Tool | `sqlcmd`; wird vorausgesetzt, nicht installiert |

## 3. Sicherheits- und Datenschutzprüfung

- Multi-Session-Manifeste enthalten keine Verbindungs- oder Zugangsdaten.
- SQL-Passwörter sind ausschließlich über `SQLCMDPASSWORD` zulässig.
- Prozessaufrufe verwenden kein Shell-Parsing.
- Rohoutput wird nur interaktiv auf ausdrückliche Anforderung gezeigt und nicht persistiert.
- Query Store wird nur in der markierten Testdatenbank verändert und besitzt einen Restore-Pfad.
- Die XE-Session verwendet keinen Autostart und keine Event-Datei.
- Der `ring_buffer` ist auf 1024 KB Target-Speicher begrenzt.
- Die Repository-Artefakte enthalten ausschließlich synthetische Kennungen und Werte.

## 4. SQL-Server-unabhängige Prüfungen

Die Prozess-Selbsttests simulieren `sqlcmd` und prüfen:

- erfolgreiche parallele Sessions,
- Fail-fast und Beendigung verbleibender Prozesse,
- globalen Multi-Session-Timeout,
- erfolgreichen sequenziellen Demolauf,
- erforderlichen Preflight-Skip ohne Zustandsänderung,
- optionalen Evidenz-Skip mit Fortsetzung,
- gelbe Safety-Bestätigung,
- Cleanup-Ausführung und Dominanz von `FAIL_CLEANUP`.

Die statische Prüfung kontrolliert zusätzlich:

- T-SQL-Lexik und Pflichtmarker,
- read-only Query-Store-Statuspfad,
- Query-Store-Baseline/Restore-Syntax,
- XE-Berechtigungen und Lifecycle,
- Ausschluss von `event_file` und `STARTUP_STATE = ON`,
- passwortfreie Manifeste,
- Python-Syntax und Prozessgruppenbehandlung.

## 5. Nicht ausgeführte Prüfungen

Mangels SQL-Server-Host wurden nicht ausgeführt:

- Installation und Ausführung der Signalobjekte,
- reale parallele SQL-Sessions und Blocking-Abläufe,
- Query-Store-Enable, Clear und Restore,
- XE-Create, Start, Status, Stop und Drop,
- vollständiger Demo-Harness auf SQL Server 2019, 2022 und 2025.

Der Status lautet deshalb `IMPLEMENTED`, nicht `VALIDATED`.

## 6. Folgearbeit

Die Framework-Arbeitspakete `FWK-001` bis `FWK-012` sind implementiert. Der nächste kritische Pfad besteht aus:

1. SQL-Server-2019/2022/2025-Parse-, Installations- und Lifecycle-Matrix,
2. zwei grünen Pilotdemos,
3. einer gelben Multi-Session-Blocking-Demo,
4. einer gelben Ressourcen-Demo,
5. formaler Gate-B-Abnahme.

Gate B ist mit diesem Stand noch nicht erreicht.
