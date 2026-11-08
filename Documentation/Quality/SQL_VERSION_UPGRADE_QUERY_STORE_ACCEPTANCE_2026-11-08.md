# SQL-Version-Upgrade: aktuelle Query-Store-Abnahme

## Quellbindung und Ausführung

Am 2026-11-08 wurde die Query-Store-Ergänzung der festen SQL-2022-zu-SQL-2025-
Referenz getrennt mit Docker und Podman ausgeführt. Beide Läufe verwendeten
`origin/main` bei `35a1abc06bf8a16d11c34a35d4dbf7a790551daf` und denselben
Abnahmerunner mit SHA-256
`1E751C343030C2146C87A19E0927A35EE1ADCA9F1F5D31CD0C06CBAFA92C3C70`.

| Provider | Akzeptanzreceipt | Query-Store-Receipt | Eigener Cleanup |
|---|---|---|---|
| Docker | `COMPLETED` | `VERIFIED` | `COMPLETED` |
| Podman | `COMPLETED` | `VERIFIED` | `COMPLETED` |

Jeder Lauf verwendete eine eigene SQL-2022-Quelle (Major 16) und ein eigenes
SQL-2025-Ziel (Major 17). Das Restore erhielt Compatibility Level 160; erst
danach wurde das Ziel ausdrücklich auf 170 gesetzt. Die Quelle blieb auf Major
16 und Level 160. Für die fest markierte Abfrage meldete jede Query-Store-
Beobachtung `OBSERVED` und fünf Ausführungen: Quellenbaseline, Ziel mit Level
160 und Ziel mit Level 170. Das belegt die Ausführung der Beobachtung, keine
allgemeine Performance- oder Anwendungsregression.

Die getrennte Ausführung hielt die Providergrenzen ein. Beide Runner bestätigten
ihren eigenen Cleanup als `COMPLETED`; ihre lokalen privaten Receipts und
Rohstreams bleiben außerhalb des Repositories. Es werden keine Run- oder
Operation-IDs, Hostpfade, Zugangsdaten oder Rohlogs veröffentlicht.

## Geltungsbereich

Diese Abnahme schließt den aktualisierten Query-Store-Nachweis für genau diese
SQL-2022-/SQL-2025-Referenz unter Docker und Podman. Sie ist kein Benchmark und
belegt weder stabile Performance noch eine allgemeine Anwendungs- oder
Planregression. Weitere Versionspaare, Hyper-V, In-place-Upgrade und
fehlgeschlagene Deployment-Releases bleiben getrennte Backlogarbeit.
