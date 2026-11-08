# Native Abnahme der Linked-Server-Umgebungsgruppe vom 2026-11-08

## Umfang

Die getrennte Container-Lane wurde einmal mit Docker und einmal mit Podman auf
SQL Server 2025 CU9 ausgeführt. Beide Läufe verwendeten den öffentlichen
Harness
[`Invoke-LinkedServerEnvironmentGroupAcceptance.ps1`](../../Tests/Integration/Invoke-LinkedServerEnvironmentGroupAcceptance.ps1).
Der geprüfte Harness hatte SHA-256
`1434F1EA093F0F1185B941A1A4168138E68CAAC8B9646635B2E8CF30B6CF8DA6`.

Jeder Lauf erstellte zwei unabhängige SQL-Runs auf einem nur für diesen Lauf
erzeugten gemeinsamen Providernetz. Beide Runs wurden derselben Gruppe
zugeordnet; der Ziel-Run wurde zusätzlich einer zweiten Gruppe zugeordnet. Der
Harness legte auf dem Ziel einen synthetischen SQL-Endpunkt an und prüfte eine
read-only `OPENQUERY`-Abfrage über `MSOLEDBSQL`.

## Ergebnisse

| Provider | SQL-Version | `OPENQUERY` | Gemeinsamer Run bleibt nach erstem Gruppen-Stop aktiv | eigener Cleanup |
|---|---|---|---|---|
| Docker | 2025 CU9 | PASS | PASS | PASS |
| Podman | 2025 CU9 | PASS | PASS | PASS |

Beide Läufe bestätigten, dass der gemeinsame Ziel-Run weiterläuft, solange die
zweite Gruppe ihn beansprucht, und nach Auflösung des letzten Gruppenanspruchs
stoppt. Pro Lauf wurden beide eigenen Runs, Gruppen, Container und Volumes sowie
das eigene Providernetz entfernt. Die Harness-Belege bestätigten außerdem die
Bindung der neuen Evidence- und State-Verzeichnisse sowie die Abwesenheit der
eigenen Ressourcen nach dem Cleanup. Es gab keine Cleanup- oder Fixturefehler.

Die privaten Laufbelege bleiben außerhalb des Repositories. Dieser Bericht
enthält keine Run- oder Gruppen-IDs, Zugangsdaten, Hostpfade, Netzwerkinventare
oder Rohdiagnosen.

## Grenzen

Der Nachweis gilt für die beiden ausgeführten Provider, SQL Server 2025 CU9 und
die beschriebene synthetische Abfrage. Er belegt weder Collation-Konflikte noch
TLS-Identitätsprüfung, Kerberos-Delegierung, MSDTC oder andere SQL-Versionen.
Docker- und Podman-Ergebnisse bleiben getrennte Provider-Evidence.
