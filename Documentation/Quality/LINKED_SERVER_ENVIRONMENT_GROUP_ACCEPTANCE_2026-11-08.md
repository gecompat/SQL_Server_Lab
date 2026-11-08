# Native Abnahme der Linked-Server-Umgebungsgruppe vom 2026-11-08

## Umfang

Die getrennte Container-Lane wurde einmal mit Docker und einmal mit Podman auf
SQL Server 2025 CU9 ausgeführt. Beide Läufe verwendeten den öffentlichen
Harness
[`Invoke-LinkedServerEnvironmentGroupAcceptance.ps1`](../../Tests/Integration/Invoke-LinkedServerEnvironmentGroupAcceptance.ps1).
Der geprüfte Harness hatte SHA-256
`7AC7433CF23FDC47460C7D346946EAB1D6DBB4601F0E61361B61005387AC388A`.

Jeder Lauf erstellte zwei unabhängige SQL-Runs auf einem nur für diesen Lauf
erzeugten gemeinsamen Providernetz. Beide Runs wurden derselben Gruppe
zugeordnet; der Ziel-Run wurde zusätzlich einer zweiten Gruppe zugeordnet. Der
Harness legte auf dem Ziel einen synthetischen SQL-Endpunkt an und prüfte eine
read-only `OPENQUERY`-Abfrage über `MSOLEDBSQL`. Eine absichtlich mit zwei
verschiedenen expliziten Collations ausgewertete Vergleichsabfrage muss mit
SQL-Fehler 468 abgewiesen werden. Derselbe Marker wird anschließend mit auf
beiden Seiten vereinheitlichter Collation erfolgreich gelesen.

## Ergebnisse

| Provider | SQL-Version | `OPENQUERY` | Collation-Konflikt ergibt 468 | explizite Auflösung | gemeinsamer Run bleibt nach erstem Gruppen-Stop aktiv | eigener Cleanup |
|---|---|---|---|---|---|---|
| Docker | 2025 CU9 | PASS | PASS | PASS | PASS | PASS |
| Podman | 2025 CU9 | PASS | PASS | PASS | PASS | PASS |

Beide Läufe bestätigten, dass der gemeinsame Ziel-Run weiterläuft, solange die
zweite Gruppe ihn beansprucht, und nach Auflösung des letzten Gruppenanspruchs
stoppt. Pro Lauf wurden beide eigenen Runs, Gruppen, Container und Volumes sowie
das eigene Providernetz entfernt. Die Harness-Belege bestätigten außerdem die
Bindung der neuen Evidence- und State-Verzeichnisse sowie die Abwesenheit der
eigenen Ressourcen nach dem Cleanup. Es gab keine Cleanup- oder Fixturefehler.

Die beiden erweiterten Laufbelege bestätigen außerdem die Fehlernummer 468
für die kontrollierte inkompatible Collation. Die privaten Laufbelege bleiben
außerhalb des Repositories. Dieser Bericht enthält keine Run- oder
Gruppen-IDs, Zugangsdaten, Hostpfade, Netzwerkinventare oder Rohdiagnosen.

## Grenzen

Der Nachweis gilt für die beiden ausgeführten Provider, SQL Server 2025 CU9 und
die beschriebene synthetische Abfrage samt kontrolliertem Collation-Konflikt
und expliziter Auflösung. Er qualifiziert keine beliebigen Datenbank-
Collations, TLS-Identitätsprüfung, Kerberos-Delegierung, MSDTC oder andere
SQL-Versionen. Docker- und Podman-Ergebnisse bleiben getrennte Provider-Evidence.
