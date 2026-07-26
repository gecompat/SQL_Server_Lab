# SQL-Server-Runtime-Matrix

## Status

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Prüfdatum | 2026-07-24 |
| Validierter GitHub-Actions-Lauf | `30099942191` |
| Geprüfter Commit | `e3f37e0c96a6d9a0c02c4e89181ceef564e1ae57` |

## Zweck

Dieser Bereich validiert die implementierten Framework-Komponenten gegen reale, ephemere SQL-Server-Instanzen. Die GitHub-Actions-Matrix verwendet getrennte Container für SQL Server 2019, 2022 und 2025. Pro Job läuft genau eine SQL-Server-Version.

## Matrix

| SQL Server | Container-Tag | erwartete Major Version | Compatibility Level | Ergebnis |
|---|---|---:|---:|---|
| 2019 | `mcr.microsoft.com/mssql/server:2019-latest` | 15 | 150 | `PASS` |
| 2022 | `mcr.microsoft.com/mssql/server:2022-latest` | 16 | 160 | `PASS` |
| 2025 | `mcr.microsoft.com/mssql/server:2025-latest` | 17 | 170 | `PASS` |

Die Tags werden vor jeder Ausführung neu aus der Microsoft Container Registry bezogen. Das Ergebnis bezieht sich deshalb auf den zum Laufzeitpunkt ausgelieferten aktuellen Containerstand und nicht auf ein dauerhaft festgeschriebenes CU.

## Ausgeführte Prüfungen

Der stufenberichtende Matrix-Entry-Point prüft je Version:

1. Engine-Major-Version und unterstützte Engine Edition,
2. `FWK-002` mit `CREATE`, Markerprüfung und `DROP`,
3. `FWK-001` gegen die erzeugte Testdatenbank,
4. Installation und zweimalige deterministische Ausführung von `FWK-003`,
5. Installation sowie Begin/End-Messung von `FWK-004`,
6. Statistikproperties, Histogramm und Actual-Plan-Ausgabe aus `FWK-005`,
7. Installation und reale parallele Sessions aus `FWK-006`,
8. Query-Store-Status, Enable und Restore aus `FWK-007`,
9. XE-Status, Create, Start, Stop und Drop aus `FWK-007`,
10. einen realen `FWK-010`-Harness-Lauf über den containerinternen `sqlcmd`-Proxy.

Alle Testdatenbanken verwenden die FWK-002-Marker und werden im `finally`-Pfad entfernt. Ein Cleanup-Finding lässt den Matrixjob fehlschlagen.

## Zugangsdaten und Datenschutz

Das SA-Kennwort wird ausschließlich zur Laufzeit aus GitHub-Run-Kennungen erzeugt, sofort maskiert und über Umgebungsvariablen an Container und `sqlcmd` übergeben. Es wird nicht im Repository gespeichert. Der Container besitzt keine veröffentlichte Host-Portzuordnung und kein persistentes Volume.

Der Proxy `docker_sqlcmd_proxy.py` legt kein Kennwort auf die Kommandozeile. Er liest repositorylokale SQL-Dateien und überträgt sie über Standard Input an das im Container enthaltene Microsoft-Tool `sqlcmd`.

Die kurzlebigen Matrixdiagnosen enthalten nur Teststufen, Summarycodes und gekürzte Fehlerkontexte. Sie werden drei Tage aufbewahrt und enthalten keine Zugangsdaten oder vollständigen SQL-Resultsets.

## Durch die Matrix identifizierte Korrekturen

- Die Manifestspalte `[RowCount]` muss wegen des Schlüsselworts `ROWCOUNT` gequotet werden.
- Die Query-Store-Katalogsicht verwendet `flush_interval_seconds`; `DATA_FLUSH_INTERVAL_SECONDS` ist der Name der `ALTER DATABASE`-Option.
- Bei `sqlcmd -r 1` können Informationsmeldungen auf Standard Error erscheinen. Die Matrix wertet deshalb beide Streams aus, während der Prozess-Returncode das Ausführungsfehlersignal bleibt.

## Grenzen

Die Matrix validiert SQL Server auf Linux in offiziellen Microsoft-Containern. Sie ersetzt keine separate Prüfung Windows-spezifischer Funktionen, Editionen oder OS-Metriken. Die `latest`-Tags eignen sich zur laufenden Kompatibilitätsprüfung; ein späterer Release benötigt zusätzlich dokumentierte konkrete Image-Digests oder CU-Stände.
