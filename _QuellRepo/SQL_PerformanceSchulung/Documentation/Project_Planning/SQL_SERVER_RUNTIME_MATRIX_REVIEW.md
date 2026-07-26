# Review – SQL-Server-Runtime-Matrix

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Prüfdatum | 2026-07-24 |
| GitHub-Actions-Lauf | `30099942191` |
| Geprüfter Commit | `e3f37e0c96a6d9a0c02c4e89181ceef564e1ae57` |
| Zielplattform | offizielle Microsoft-SQL-Server-Linux-Container |

## 1. Matrixergebnis

| SQL Server | Container-Tag | Major Version | Compatibility Level | Ergebnis |
|---|---|---:|---:|---|
| 2019 | `mcr.microsoft.com/mssql/server:2019-latest` | 15 | 150 | `PASS` |
| 2022 | `mcr.microsoft.com/mssql/server:2022-latest` | 16 | 160 | `PASS` |
| 2025 | `mcr.microsoft.com/mssql/server:2025-latest` | 17 | 170 | `PASS` |

Alle drei Jobs haben Containerstart, Frameworklauf, Diagnoseupload und Containerentfernung erfolgreich abgeschlossen. Der Fehlerpfad zur Ausgabe der SQL-Server-Containerlogs wurde nicht benötigt.

## 2. Laufzeitabdeckung

Je Version wurden tatsächlich ausgeführt:

1. Engine-Major-Version und Engine Edition prüfen,
2. vier synthetische Testdatenbanken über `FWK-002` erstellen,
3. `FWK-001` gegen die markierte Testdatenbank ausführen,
4. `FWK-003` installieren und mit identischen Parametern zweimal ausführen,
5. Datenfingerprints beider Generatorläufe vergleichen,
6. `FWK-004` installieren sowie Begin/End-Messung in derselben Session ausführen,
7. `FWK-005` für Statistikproperties, Histogramm und Actual Showplan XML ausführen,
8. `FWK-006` installieren und zwei reale parallele `sqlcmd`-Sessions koordinieren,
9. Query Store über `FWK-007` lesen, aktivieren und in den Ausgangszustand zurückführen,
10. Extended Events über `FWK-007` erstellen, starten, lesen, stoppen und entfernen,
11. `FWK-010` mit einem realen SQL-Server-Ziel über den containerinternen `sqlcmd`-Proxy ausführen,
12. alle markierten Testdatenbanken im Abschlussblock über `FWK-002` entfernen.

## 3. Durch die Matrix gefundene Frameworkfehler

Die Runtimeprüfung identifizierte zwei Fehler, die durch die vorherige lexikalische Prüfung nicht erkennbar waren:

- Die Manifestspalte `RowCount` kollidierte ungequotet mit dem T-SQL-Schlüsselwort `ROWCOUNT`. Die Spalte wird nun als `[RowCount]` referenziert.
- Die Query-Store-Baseline verwendete `data_flush_interval_seconds` als Katalogspalte. Dokumentiert und versionsübergreifend vorhanden ist `flush_interval_seconds`; `DATA_FLUSH_INTERVAL_SECONDS` bleibt ausschließlich der Name der `ALTER DATABASE`-Option.

Zusätzlich wurde die Matrixauswertung präzisiert: Bei `sqlcmd -r 1` können `PRINT`-Meldungen auf Standard Error erscheinen. Summarymarker werden deshalb aus beiden Ausgabeströmen gelesen, während der Prozess-Returncode weiterhin das Ausführungsfehlersignal bleibt.

## 4. Datenschutz und Cleanup

Die Container besitzen keine veröffentlichte Host-Portzuordnung und kein persistentes Volume. Das SA-Kennwort wurde pro Job erzeugt, maskiert und ausschließlich über Umgebungsvariablen übergeben. Repository, Manifeste, Prozessargumente und Diagnoseartefakte enthalten keine Zugangsdaten.

Die Matrixdiagnosen enthalten nur Teststufen und gekürzte Fehlerkontexte. Alle Testdatenbanken wurden über vollständige `FWK-002`-Marker entfernt. Ein Cleanup-Fehler hätte den betreffenden Job fehlschlagen lassen.

## 5. Gültigkeitsgrenze

Validiert sind SQL Server 2019, 2022 und 2025 in den zum Prüfzeitpunkt ausgelieferten offiziellen `*-latest`-Linux-Containern mit Developer Edition und den Compatibility Levels 150, 160 und 170. Die Prüfung bestätigt Syntax, Installation, Laufzeitverträge und Cleanup des gemeinsamen Frameworks.

Nicht abgedeckt sind Windows-spezifische Funktionen, andere Editionen, abweichende Betriebssystemmetriken sowie ein dauerhaft festgeschriebener CU- oder Image-Digest. Für einen Release werden die tatsächlich verwendeten Containerdigests oder CU-Stände zusätzlich dokumentiert.

## 6. Freigabe

Die Runtime-Matrix ist validiert. `FWK-001` bis `FWK-012` können für die vier Gate-B-Pilotdemos verwendet werden. Gate B selbst ist noch nicht erfüllt, weil die Pilotdemos noch implementiert und fachlich abgenommen werden müssen.
