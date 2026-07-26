# Gate-B-Review – Validierte Pilotdemos

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Gate | B |
| Pull Request | `#9` |
| Validierter Workflowlauf | `30108023315` |
| Framework-Regressionsläufe | `30108023339`, `30108023316` |
| Zielplattformen | SQL Server 2019, 2022 und 2025 |
| Compatibility Levels | 150, 160 und 170 |

## 1. Abnahmeumfang

Gate B verlangt vier vollständige Pilotdemos, die den gemeinsamen Frameworkvertrag unter realer SQL-Server-Ausführung nachweisen. Abgenommen wurden:

| Demo-ID | Sicherheitsstufe | Primäre Kompetenz | Claim-Bezug | Ergebnis |
|---|---|---|---|---|
| `QRY-001` | `GREEN` | SARGability, Zugriffspfad und statementbezogene Reads | `CLM-037` | `VALIDATED` |
| `OPT-002` | `GREEN` | Statistikheader, Histogramm und Density Vector | `CLM-023`, `CLM-024` | `VALIDATED` |
| `CON-004` | `YELLOW` | Blocking Chain, unmittelbarer Blocker und Head Blocker | `CLM-066` | `VALIDATED` |
| `OPT-013` | `YELLOW` | Sort-Spill, Grant-Evidenz und Kardinalitätssicht | `CLM-030` | `VALIDATED` |

Jede Demo besitzt Preflight, markergeprüftes Setup, Baseline, kontrollierten Problemzustand, technische Evidenz, Gegenmaßnahme, Vergleich und markergeprüften Cleanup. Gelbe Demos benötigen die technische Isolated-Lab-Bestätigung und besitzen positive Laufzeitgrenzen.

## 2. Testmatrix

Der Workflow `Gate B pilot demos` startete je Version einen getrennten ephemeren offiziellen Microsoft-Linux-Container. Jede Demo wurde in jeder Version zweimal vollständig über `FWK-010` ausgeführt.

| SQL Server | Compatibility Level | Piloten | Wiederholungen je Pilot | vollständige Läufe | Ergebnis |
|---|---:|---:|---:|---:|---|
| 2019 | 150 | 4 | 2 | 8 | `PASS` |
| 2022 | 160 | 4 | 2 | 8 | `PASS` |
| 2025 | 170 | 4 | 2 | 8 | `PASS` |
| **Gesamt** | – | **4** | – | **24** | **`PASS`** |

Nach jedem der 24 Läufe wurde unabhängig über `master` geprüft, dass die jeweilige `SQLPERF_LAB_<DEMO>_LOCAL`-Datenbank nicht mehr vorhanden war. Ein verbleibendes Objekt oder ein Cleanup-Fehler hätte den Matrixjob fehlschlagen lassen.

## 3. Statische Abnahme

`Tests/Static/validate_gate_b_pilots.py` prüfte:

- vollständige README-Struktur und Traceability,
- kanonische Demo-IDs und Sicherheitsstufen,
- alle Pflichtphasen und repositorylokale Manifestpfade,
- T-SQL-Lexik,
- vollständige Eigentumsmarker vor `DROP DATABASE`,
- Ausschluss globaler Cache-, Serverkonfigurations-, `KILL`-, `NOLOCK`- und Event-File-Pfade,
- Ausschluss von Verbindungs- und Secretfeldern in Manifesten.

Die statische Abnahme war im Workflowlauf `30108023315` erfolgreich.

## 4. Runtime-Evidenz

### 4.1 QRY-001

Der SARGable Datumsbereich und die fachlich äquivalente Stringkonvertierung lieferten denselben Ergebniswert. Der Bereichspfad verwendete einen Index Seek und weniger `last_logical_reads`; die Funktion auf der Indexspalte verwendete im kontrollierten Datenmodell einen Index Scan. Die Reads wurden aus demselben statementbezogenen `sys.dm_exec_query_stats`-Datensatz wie der Textplan gelesen.

### 4.2 OPT-002

Die tatsächliche Verteilung betrug 100.000 Zeilen mit 50.000 Zeilen für Kategorie 1. Die Ausgangsstatistik verwendete eine explizite 1.000-Zeilen-Stichprobe. Das Histogramm bezog sich auf `CategoryId`, die erste Statistikschlüsselspalte. Nach `FULLSCAN` entsprachen `rows_sampled` und `rows` einander; das 101-Werte-Histogramm enthielt für Kategorie 1 `equal_rows = 50000`.

### 4.3 CON-004

Die Problemsessions erzeugten die Kette Head → Middle → Leaf. Die Beobachtersession bestätigte zwei exakte `blocking_session_id`-Beziehungen, zwei positive `LCK_M_%`-Waits und Chain Depth 2. Nach dem kontrollierten Commit endeten alle Prozesse ohne `KILL`. Der Vergleich erreichte dieselben Endwerte mit Commit vor Sessionübergabe und ohne verbleibendes Blocking.

### 4.4 OPT-013

Baseline, Problem und Vergleich sortierten dieselben 300.000 breiten Zeilen und lieferten denselben Checksum-Wert. Die Basistabelle besaß keinen Spill. Die Table Variable mit querylokal deaktivierter Deferred Compilation erhielt einen kleineren Grant und erzeugte `last_spills > 0`. Die statistisch sichtbare Staging-Tabelle beseitigte den Spill bei unveränderter Sortieranforderung.

## 5. Durch Runtime-Tests erkannte und korrigierte Annahmen

| Finding | Technische Ursache | Korrektur |
|---|---|---|
| Sessionzähler lieferten für QRY-001 im aktiven Batch kein belastbares Statementdelta. | `sys.dm_exec_sessions.logical_reads` ist nicht die geeignete abgeschlossene Statement-Evidenz innerhalb desselben Batchs. | Plan und `last_logical_reads` werden aus demselben statementbezogenen Query-Stats-Datensatz gelesen. |
| `SAMPLE 1 PERCENT` wurde bei der kleinen Ausgangstabelle als vollständiger Scan ausgeführt. | SQL Server kann bei kleinen Statistikobjekten trotz Prozentangabe die vollständige Tabelle lesen. | Breiteres Datenmodell und explizites `SAMPLE 1000 ROWS`. |
| `MAX_GRANT_PERCENT = 0.1` erzeugte keinen Spill. | Der Hint unterschreitet den intern erforderlichen Mindestgrant nicht zuverlässig. | Kontrollierter Undergrant über `DISABLE_DEFERRED_COMPILATION_TV`; Mitigation durch statistisch sichtbare Materialisierung. |
| Markerbasierte Query-Stats-Suchen konnten den Diagnose-SELECT selbst treffen. | Der vollständige Marker stand auch im auswertenden Statementtext. | Suchmarker werden aus Teilstrings zusammengesetzt und existieren vollständig nur im Workloadstatement. |

## 6. Datenschutz und Sicherheitsabnahme

Alle Daten, Namen, Signale, Datenbanken und Resultate sind synthetisch. Die Container besitzen keine Host-Portfreigabe und kein persistentes Volume. Kennwörter werden ausschließlich zur Laufzeit erzeugt und maskiert. Diagnoseartefakte werden höchstens drei Tage gespeichert und enthalten ausschließlich synthetische Phasen- und Fehlerausgaben.

Keine Pilotdemo leert globale Caches, verändert Serverkonfigurationen, beendet fremde Sessions oder erzeugt persistente Extended-Events-Dateien.

## 7. Grenzen der Abnahme

Die Matrix validiert offizielle SQL-Server-Linux-Container mit aktuellen `*-latest`-Tags. Sie ersetzt keine Windows-spezifische, editionsspezifische oder releasefest auf Image-Digests beziehungsweise konkrete CU-Stände bezogene Prüfung. Konkrete Laufzeiten, Spill-Seitenzahlen und Lock-Wartezeiten sind nicht als universelle Schwellenwerte freigegeben.

Query Store und Extended Events sind im gemeinsamen Framework runtime-validiert, aber noch nicht als zentrale Evidenzpfade innerhalb dieser vier Pilotdemos abgenommen. Dieser Punkt bleibt im Backlog offen.

## 8. Gate-Entscheidung

Gate B ist `VALIDATED`. Der gemeinsame Frameworkvertrag ist durch zwei grüne und zwei gelbe, fachlich unterschiedliche Pilotdemos auf SQL Server 2019, 2022 und 2025 nachgewiesen.

Der nächste kritische Pfad ist Welle 2. Dazu gehören die inhaltliche Umsetzung der Curriculum-Artefakte, die Korrektur der vier aktiven `REFINE`-Claims in `W2-007`, die Synchronisierung von Folien, Sprecherhinweisen und Teilnehmerunterlagen sowie der Ausbau weiterer Demos auf Basis der validierten Piloten.
