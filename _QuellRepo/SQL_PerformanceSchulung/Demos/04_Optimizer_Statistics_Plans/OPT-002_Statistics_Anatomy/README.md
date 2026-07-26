# OPT-002 – Statistikheader, Histogramm und Density Vector

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Sicherheitsstufe | `GREEN` |
| Primäre Zielversion | SQL Server 2025 |
| Unterstützte Versionen | SQL Server 2019, 2022 und 2025 |
| Compatibility Level | 150, 160 und 170 |
| Edition / Plattform | Database Engine; Windows oder Linux |
| Sessions | 1 |
| Laufzeitklasse | S |
| Testprofil | `TP-RUN` |

## 1. Lernziel

Nach Abschluss kann die lernende Person Statistikheader, Histogramm und Density Vector fachlich voneinander abgrenzen und erklären, warum ein Histogramm nur die erste Schlüsselspalte eines Statistikobjekts beschreibt.

## 2. Fachliche Kernaussage

**Evidenzklasse:** `DOKUMENTIERT` und `EMPIRISCH`

Statistikobjekte enthalten mehrere Evidenzarten. Headerwerte beschreiben unter anderem Zeilen, Stichprobenumfang, Schritte und Änderungsstand. Das Histogramm modelliert die Verteilung der ersten Schlüsselspalte mit höchstens 200 Schritten. Der Density Vector enthält Dichten für Schlüsselpräfixe und ist nicht mit einzelnen Histogrammgrenzen gleichzusetzen.

## 3. Nichtziel

Die Demo leitet aus einer einzelnen Statistik keine vollständige Erklärung für jede Kardinalitätsschätzung ab. Sie bewertet weder alle CE-Modelle noch mehrspaltige Korrelationen außerhalb der dokumentierten Präfixdichten.

## 4. Voraussetzungen

SQL Server 2019 bis 2025. Für den automatisierten Lauf werden `CREATE DATABASE`, `SHOWPLAN` und Leserechte auf die synthetischen Objekte benötigt. Mindestens 2 logische CPU-Kerne, 2 GB RAM und 200 MB freier Datenträgerspeicher sind erforderlich.

## 5. Sicherheits- und Abbruchrahmen

Die Demo ist grün. Sie erzeugt 100.000 synthetische Zeilen und verändert ausschließlich eine eigene markierte Testdatenbank. Das Harness-Zeitbudget beträgt 240 Sekunden. Cleanup erfolgt markergeprüft über den lokalen, dem `FWK-002`-Vertrag entsprechenden Pfad.

## 6. Synthetisches Datenmodell

`lab.StatisticsData` enthält 101 Kategorien. Kategorie 1 besitzt 50.000 Zeilen; die Kategorien 2 bis 101 besitzen jeweils 500 Zeilen. `RegionId` verteilt sich deterministisch auf zehn Werte. Die Zeilenbreite sorgt dafür, dass eine explizite Stichprobe von 1.000 Zeilen vom vollständigen Tabellenumfang unterscheidbar bleibt. Das mehrspaltige Statistikobjekt `ST_StatisticsData_Category_Region` wird zunächst mit `SAMPLE 1000 ROWS` und später mit `FULLSCAN` aufgebaut.

## 7. Ablauf

| Phase | Datei | Zweck |
|---|---|---|
| Preflight | `00_Preflight.sql` | Version, Rechte und Zielkennung prüfen |
| Setup | `10_Setup.sql` | Testdatenbank, Verteilung und Sample-Statistik anlegen |
| Baseline | `20_Baseline.sql` | tatsächliche Zeilenverteilung erfassen |
| Demonstration | `30_Demonstration.sql` | Header, Histogramm und Density Vector der Sample-Statistik ausgeben |
| Observation | `40_Observation.sql` | Stichprobenstatus, erste Schlüsselspalte und Histogrammgrenzen prüfen |
| Mitigation | `50_Mitigation.sql` | Statistik kontrolliert mit `FULLSCAN` aktualisieren |
| Comparison | `60_Comparison.sql` | vollständigen Stichprobenumfang und exakte Hot-Key-Frequenz prüfen |
| Cleanup | `90_Cleanup.sql` | markierte Testdatenbank entfernen |

## 8. Erwartete Beobachtung

Vor `FULLSCAN` ist `rows_sampled` kleiner als `rows`. Das Histogramm bezieht sich auf `CategoryId`, nicht auf `RegionId`. Nach `FULLSCAN` entspricht `rows_sampled` der Tabellenzeilenzahl. Da nur 101 verschiedene Kategorien vorhanden sind, wird die häufige Kategorie 1 als Histogrammgrenze mit einer `equal_rows`-Frequenz von 50.000 sichtbar.

## 9. Interpretation

Eine größere Stichprobe macht die Statistik nicht automatisch für jede Abfrage ausreichend. `FULLSCAN` beseitigt in dieser Demo die Stichprobenunsicherheit, ändert aber weder die Begrenzung auf höchstens 200 Histogrammschritte noch die Tatsache, dass nur die erste Schlüsselspalte ein Histogramm besitzt. Der Density Vector ergänzt Präfixinformationen, ersetzt jedoch keine mehrdimensionale Verteilungsbeschreibung.

## 10. Cleanup und Wiederherstellung

Der Cleanup entfernt nur die Datenbank, deren Projekt-, Vertrags-, Demo- und Run-Marker vollständig mit `OPT-002` übereinstimmen. Bei fehlender Datenbank ist der Cleanup idempotent erfolgreich.

## 11. Tests

Die Runtime-Matrix führte die Demo im Lauf `30108023315` pro Version zweimal aus. Sie prüfte 100.000 tatsächliche Zeilen, 50.000 Hot-Key-Zeilen, `rows_sampled < rows` vor `FULLSCAN`, `rows_sampled = rows` danach, die erste Statistikschlüsselspalte, höchstens 200 Histogrammschritte sowie die exakte `equal_rows`-Frequenz der Kategorie 1.

## 12. Bekannte Grenzen

Sampling-Ergebnisse können zwischen Engine-Builds variieren. Deshalb wird vor `FULLSCAN` keine feste Schätzabweichung verlangt. Die Abnahme prüft nur den kleineren Stichprobenumfang und nach `FULLSCAN` deterministische Invarianten.

## 13. Quellen

| Quellen-ID | Aussagebezug | Gültigkeitsbereich | Abrufdatum |
|---|---|---|---|
| `SRC-005` | Statistikheader, Histogramm, Sampling | SQL Server 2019–2025 | 2026-07-24 |
| `SRC-006` | Kardinalitätsschätzung und Statistikgrenzen | versions- und CL-abhängig | 2026-07-24 |
| Microsoft Learn: `DBCC SHOW_STATISTICS` | Header, Histogramm und Density Vector | SQL Server | 2026-07-24 |

## 14. Traceability

| Element | Zuordnung |
|---|---|
| Lernziel | `LO-M02-02` |
| Folie / Claim | `CLM-023`, `CLM-024`, Folien 23 und 24 |
| Demo-ID | `OPT-002` |
| Testprofil | `TP-RUN` |
